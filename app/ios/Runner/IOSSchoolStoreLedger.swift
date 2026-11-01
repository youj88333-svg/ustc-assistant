import CoreFoundation
import CryptoKit
import Darwin
import Foundation

fileprivate enum IOSSchoolStoreState: String, Hashable {
  case active
  case deletePending
  case removed
}

fileprivate struct IOSSchoolDirectoryIdentity: Equatable {
  let device: dev_t
  let inode: ino_t

  init(_ value: stat) {
    device = value.st_dev
    inode = value.st_ino
  }
}

fileprivate struct IOSSchoolFileIdentity: Equatable {
  let device: dev_t
  let inode: ino_t

  init(_ value: stat) {
    device = value.st_dev
    inode = value.st_ino
  }
}

fileprivate struct IOSSchoolStoreMetadata: Equatable {
  let backend: String
  let source: String
  let id: String
  let disposable: Bool
  let state: IOSSchoolStoreState

  static let backendName = "wk-uuid-v1"
  static let fieldNames: Set<String> = [
    "backend", "source", "id", "disposable", "state",
  ]

  var dictionary: [String: Any] {
    [
      "backend": backend,
      "source": source,
      "id": id,
      "disposable": disposable,
      "state": state.rawValue,
    ]
  }

  static func decode(_ data: Data) throws -> IOSSchoolStoreMetadata {
    guard data.count <= IOSSchoolStoreLedger.maximumMetadataBytes,
          let value = try? JSONSerialization.jsonObject(with: data),
          let dictionary = value as? [String: Any],
          Set(dictionary.keys) == fieldNames,
          let backend = dictionary["backend"] as? String,
          backend == backendName,
          let source = dictionary["source"] as? String,
          source == "jw" || source == "young",
          let id = dictionary["id"] as? String,
          let uuid = UUID(uuidString: id),
          uuid.uuidString.lowercased() == id,
          id != "00000000-0000-0000-0000-000000000000",
          let disposableValue = dictionary["disposable"] as? NSNumber,
          CFGetTypeID(disposableValue) == CFBooleanGetTypeID(),
          let stateText = dictionary["state"] as? String,
          let state = IOSSchoolStoreState(rawValue: stateText) else {
      throw IOSSchoolFailure.invalidSnapshot
    }
    return IOSSchoolStoreMetadata(
      backend: backend,
      source: source,
      id: id,
      disposable: disposableValue.boolValue,
      state: state
    )
  }

  func encode() throws -> Data {
    do {
      return try JSONSerialization.data(
        withJSONObject: dictionary,
        options: [.sortedKeys, .withoutEscapingSlashes]
      )
    } catch {
      throw IOSSchoolFailure.storageFailed
    }
  }
}

fileprivate struct IOSSchoolPendingInstall {
  fileprivate let priorMetadata: IOSSchoolStoreMetadata
  fileprivate let priorIdentity: IOSSchoolFileIdentity
  fileprivate let priorDigest: Data
  fileprivate let nextMetadata: IOSSchoolStoreMetadata
  fileprivate let nextIdentity: IOSSchoolFileIdentity
  fileprivate let nextDigest: Data
}

fileprivate final class IOSSchoolStoreRecordToken {
  fileprivate var pendingInstall: IOSSchoolPendingInstall?
  fileprivate let ledgerNonce: UUID
  fileprivate let directoryIdentities: [IOSSchoolDirectoryIdentity]
  fileprivate var metadataIdentity: IOSSchoolFileIdentity
  fileprivate var metadataDigest: Data
  fileprivate var state: IOSSchoolStoreState

  init(
    ledgerNonce: UUID,
    directoryIdentities: [IOSSchoolDirectoryIdentity],
    metadataIdentity: IOSSchoolFileIdentity,
    metadataDigest: Data,
    state: IOSSchoolStoreState,
    pendingInstall: IOSSchoolPendingInstall? = nil
  ) {
    self.ledgerNonce = ledgerNonce
    self.directoryIdentities = directoryIdentities
    self.metadataIdentity = metadataIdentity
    self.metadataDigest = metadataDigest
    self.state = state
    self.pendingInstall = pendingInstall
  }
}

struct IOSSchoolStoreRecord {
  let source: String
  let id: UUID
  let profilePath: String
  let disposable: Bool
  fileprivate let token: IOSSchoolStoreRecordToken
}

/// Maps an already-owned Dart partition directory to one persistent WebKit UUID.
/// This ledger never creates a profile directory and never reads browser data.
final class IOSSchoolStoreLedger {
  static let metadataName = ".ios-webkit-store-v1.json"
  static let maximumMetadataBytes = 2048
  private static let temporaryName = ".ios-webkit-store-v1.tmp"
  private static let serializationLock = NSLock()

  private let root: URL
  private let ledgerNonce = UUID()
  private var rootIdentity: IOSSchoolDirectoryIdentity?
  private(set) var lastFailureErrno: Int32?
#if os(macOS)
  /// Synthetic CLI only. The iOS target does not compile this fault-injection
  /// initializer or carry a runtime hook.
  private let syntheticAfterSwap: (() throws -> Void)?
#endif

  init(root: URL) {
    self.root = root
#if os(macOS)
    self.syntheticAfterSwap = nil
#endif
  }

#if os(macOS)
  init(root: URL, syntheticAfterSwap: @escaping () throws -> Void) {
    self.root = root
    self.syntheticAfterSwap = syntheticAfterSwap
  }
#endif

  /// Returns nil only when an existing, safe profile has no WebKit ledger and
  /// `create` is false. For creation, metadata is durably installed before the
  /// caller is allowed to instantiate WKWebsiteDataStore(forIdentifier:).
  func admit(
    profilePath: String,
    source: String,
    create: Bool
  ) throws -> IOSSchoolStoreRecord? {
    try Self.serializationLock.iosWithLock {
      lastFailureErrno = nil
      let location = try parseLocation(profilePath: profilePath, source: source)
      return try withProfile(location) { profileFD, directoryIdentities in
        try discardIncompleteTemporary(profileFD: profileFD)
        if let loaded = try readMetadata(profileFD: profileFD, name: Self.metadataName) {
          let metadata = loaded.metadata
          guard metadata.source == source,
                metadata.disposable == location.disposable else {
            throw IOSSchoolFailure.invalidSnapshot
          }
          if create && metadata.state != .active {
            throw IOSSchoolFailure.cleanupPending
          }
          guard let identifier = UUID(uuidString: metadata.id) else {
            throw IOSSchoolFailure.invalidSnapshot
          }
          let token = IOSSchoolStoreRecordToken(
            ledgerNonce: ledgerNonce,
            directoryIdentities: directoryIdentities,
            metadataIdentity: loaded.identity,
            metadataDigest: loaded.digest,
            state: metadata.state
          )
          return IOSSchoolStoreRecord(
            source: source,
            id: identifier,
            profilePath: profilePath,
            disposable: metadata.disposable,
            token: token
          )
        }

        guard create else { return nil }
        let metadata = IOSSchoolStoreMetadata(
          backend: IOSSchoolStoreMetadata.backendName,
          source: source,
          id: Self.newUUID().uuidString.lowercased(),
          disposable: location.disposable,
          state: .active
        )
        let installed = try installMetadata(
          metadata,
          profileFD: profileFD,
          replacing: nil
        )
        let token = IOSSchoolStoreRecordToken(
          ledgerNonce: ledgerNonce,
          directoryIdentities: directoryIdentities,
          metadataIdentity: installed.identity,
          metadataDigest: installed.digest,
          state: .active
        )
        guard let identifier = UUID(uuidString: metadata.id) else {
          throw IOSSchoolFailure.storageFailed
        }
        return IOSSchoolStoreRecord(
          source: source,
          id: identifier,
          profilePath: profilePath,
          disposable: metadata.disposable,
          token: token
        )
      }
    }
  }

  func markDeleting(_ record: IOSSchoolStoreRecord) throws {
    try Self.serializationLock.iosWithLock {
      lastFailureErrno = nil
      if record.token.state == .removed {
        try transition(record, to: .removed, allowedFrom: [.removed])
      } else {
        try transition(record, to: .deletePending, allowedFrom: [.active, .deletePending])
      }
    }
  }

  /// Call only after WKWebsiteDataStore.remove(forIdentifier:) reports success.
  func didRemove(_ record: IOSSchoolStoreRecord) throws {
    try Self.serializationLock.iosWithLock {
      lastFailureErrno = nil
      try transition(record, to: .removed, allowedFrom: [.deletePending, .removed])
    }
  }

  private func transition(
    _ record: IOSSchoolStoreRecord,
    to nextState: IOSSchoolStoreState,
    allowedFrom: Set<IOSSchoolStoreState>
  ) throws {
    guard record.token.ledgerNonce == ledgerNonce else {
      throw IOSSchoolFailure.staleResult
    }
    let location = try parseLocation(profilePath: record.profilePath, source: record.source)
    guard location.disposable == record.disposable else {
      throw IOSSchoolFailure.staleResult
    }
    try withProfile(location) { profileFD, directoryIdentities in
      guard directoryIdentities == record.token.directoryIdentities else {
        throw IOSSchoolFailure.ownershipLost
      }
      if let pending = record.token.pendingInstall {
        try recoverPendingInstall(
          pending,
          record: record,
          profileFD: profileFD,
          directoryIdentities: directoryIdentities,
          allowedFrom: allowedFrom,
          nextState: nextState
        )
      } else {
        try discardIncompleteTemporary(profileFD: profileFD)
      }
      guard let current = try readMetadata(profileFD: profileFD, name: Self.metadataName),
            current.identity == record.token.metadataIdentity,
            current.digest == record.token.metadataDigest,
            current.metadata.source == record.source,
            current.metadata.id == record.id.uuidString.lowercased(),
            current.metadata.disposable == record.disposable,
            current.metadata.state == record.token.state,
            allowedFrom.contains(current.metadata.state) else {
        throw IOSSchoolFailure.staleResult
      }
      if current.metadata.state == nextState {
        try syncFile(profileFD)
        return
      }

      let replacement = IOSSchoolStoreMetadata(
        backend: IOSSchoolStoreMetadata.backendName,
        source: record.source,
        id: record.id.uuidString.lowercased(),
        disposable: record.disposable,
        state: nextState
      )
      let installed = try installMetadata(
        replacement,
        profileFD: profileFD,
        replacing: current,
        onSwapped: { record.token.pendingInstall = $0 }
      )
      record.token.metadataIdentity = installed.identity
      record.token.metadataDigest = installed.digest
      record.token.state = nextState
      record.token.pendingInstall = nil
    }
  }

  private func recoverPendingInstall(
    _ pending: IOSSchoolPendingInstall,
    record: IOSSchoolStoreRecord,
    profileFD: Int32,
    directoryIdentities: [IOSSchoolDirectoryIdentity],
    allowedFrom: Set<IOSSchoolStoreState>,
    nextState: IOSSchoolStoreState
  ) throws {
    guard directoryIdentities == record.token.directoryIdentities,
          pending.priorMetadata.backend == IOSSchoolStoreMetadata.backendName,
          pending.priorMetadata.source == record.source,
          pending.priorMetadata.id == record.id.uuidString.lowercased(),
          pending.priorMetadata.disposable == record.disposable,
          pending.priorMetadata.state == record.token.state,
          allowedFrom.contains(pending.priorMetadata.state),
          pending.nextMetadata.backend == IOSSchoolStoreMetadata.backendName,
          pending.nextMetadata.source == record.source,
          pending.nextMetadata.id == record.id.uuidString.lowercased(),
          pending.nextMetadata.disposable == record.disposable,
          pending.nextMetadata.state == nextState,
          pending.nextMetadata.state != pending.priorMetadata.state else {
      throw IOSSchoolFailure.staleResult
    }

    guard let installed = try readMetadata(profileFD: profileFD, name: Self.metadataName),
          installed.identity == pending.nextIdentity,
          installed.digest == pending.nextDigest,
          installed.metadata == pending.nextMetadata else {
      throw IOSSchoolFailure.staleResult
    }

    if let priorAtTemporary = try readMetadata(profileFD: profileFD, name: Self.temporaryName) {
      guard priorAtTemporary.identity == pending.priorIdentity,
            priorAtTemporary.digest == pending.priorDigest,
            priorAtTemporary.metadata == pending.priorMetadata else {
        throw IOSSchoolFailure.staleResult
      }
      var namedTemporary = stat()
      guard Self.temporaryName.withCString({
        fstatat(profileFD, $0, &namedTemporary, AT_SYMLINK_NOFOLLOW)
      }) == 0 else {
        throw pathFailure(errno)
      }
      try validateRegular(namedTemporary)
      guard IOSSchoolFileIdentity(namedTemporary) == pending.priorIdentity else {
        throw IOSSchoolFailure.ownershipLost
      }
      guard Self.temporaryName.withCString({ unlinkat(profileFD, $0, 0) }) == 0 else {
        throw pathFailure(errno)
      }
    }

    try syncFile(profileFD)
    guard let durable = try readMetadata(profileFD: profileFD, name: Self.metadataName),
          durable.identity == pending.nextIdentity,
          durable.digest == pending.nextDigest,
          durable.metadata == pending.nextMetadata else {
      throw IOSSchoolFailure.staleResult
    }
    record.token.metadataIdentity = durable.identity
    record.token.metadataDigest = durable.digest
    record.token.state = durable.metadata.state
    record.token.pendingInstall = nil
  }

  private struct Location {
    let profilePath: String
    let components: [String]
    let source: String
    let disposable: Bool
  }

  private struct LoadedMetadata {
    let metadata: IOSSchoolStoreMetadata
    let identity: IOSSchoolFileIdentity
    let digest: Data
  }

  private func parseLocation(profilePath: String, source: String) throws -> Location {
    guard source == "jw" || source == "young",
          root.isFileURL,
          root.path == root.standardizedFileURL.path,
          root.path.hasPrefix("/"),
          !root.path.isEmpty,
          profilePath.hasPrefix(root.path + "/") else {
      throw IOSSchoolFailure.unsafeDirectory
    }
    let relative = String(profilePath.dropFirst(root.path.count + 1))
    let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard components.count == 3,
          components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.utf8.contains(0) }) else {
      throw IOSSchoolFailure.unsafeDirectory
    }

    let id = components[2]
    let isProductionJW = source == "jw" && components[0] == "local_v1"
      && components[1] == "jw_partitions_v1" && Self.matches(id, pattern: #"^jwp-[0-9a-f]{32}$"#)
    let isProductionYoung = source == "young" && components[0] == "local_v1"
      && components[1] == "young_partitions_v1" && Self.matches(id, pattern: #"^yp-[0-9a-f]{32}$"#)
    let isFixtureJW = source == "jw" && components[0] == "demo_v1"
      && components[1] == "observation_v1" && Self.matches(id, pattern: #"^obs-[0-9a-f]{32}$"#)
    let isFixtureYoung = source == "young" && components[0] == "demo_v1"
      && components[1] == "young_observation_v1" && Self.matches(id, pattern: #"^obs-[0-9a-f]{32}$"#)
    guard isProductionJW || isProductionYoung || isFixtureJW || isFixtureYoung else {
      throw IOSSchoolFailure.unsafeDirectory
    }

    var expected = root
    for component in components {
      expected.appendPathComponent(component, isDirectory: true)
    }
    guard expected.path == profilePath else { throw IOSSchoolFailure.unsafeDirectory }
    return Location(
      profilePath: profilePath,
      components: components,
      source: source,
      disposable: isFixtureJW || isFixtureYoung
    )
  }

  private func withProfile<T>(
    _ location: Location,
    _ body: (Int32, [IOSSchoolDirectoryIdentity]) throws -> T
  ) throws -> T {
    let rootFD = try openRoot()
    defer { _ = close(rootFD) }
    var identities = [try checkedDirectoryIdentity(rootFD)]
    var currentFD = rootFD
    var opened = [Int32]()
    defer { for fd in opened.reversed() { _ = close(fd) } }

    for component in location.components {
      let childFD: Int32 = component.withCString { name in
        openat(currentFD, name, O_SEARCH | O_CLOEXEC | O_NOFOLLOW)
      }
      guard childFD >= 0 else { throw pathFailure(errno) }
      opened.append(childFD)
      let childIdentity = try checkedDirectoryIdentity(childFD)
      let namedIdentity = try namedDirectoryIdentity(parentFD: currentFD, name: component)
      guard childIdentity == namedIdentity else { throw IOSSchoolFailure.ownershipLost }
      identities.append(childIdentity)
      currentFD = childFD
    }

    if let captured = rootIdentity {
      guard captured == identities[0] else { throw IOSSchoolFailure.ownershipLost }
    } else {
      rootIdentity = identities[0]
    }
    return try body(currentFD, identities)
  }

  private func openRoot() throws -> Int32 {
    guard root.isFileURL,
          root.path == root.standardizedFileURL.path,
          root.path.hasPrefix("/") else { throw IOSSchoolFailure.unsafeDirectory }
    let rootFD = root.path.withCString { path in
      open(path, O_SEARCH | O_CLOEXEC | O_NOFOLLOW)
    }
    guard rootFD >= 0 else { throw pathFailure(errno) }

    var opened = stat()
    guard fstat(rootFD, &opened) == 0 else {
      _ = close(rootFD)
      throw IOSSchoolFailure.storageFailed
    }
    var named = stat()
    let namedResult = root.path.withCString { path in lstat(path, &named) }
    guard namedResult == 0 else {
      let error = errno
      _ = close(rootFD)
      throw pathFailure(error)
    }
    guard (opened.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
          (named.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
          opened.st_uid == getuid(),
          named.st_uid == getuid(),
          (opened.st_mode & 0o077) == 0,
          (named.st_mode & 0o077) == 0 else {
      _ = close(rootFD)
      throw IOSSchoolFailure.unsafeDirectory
    }
    let openedIdentity = IOSSchoolDirectoryIdentity(opened)
    guard openedIdentity == IOSSchoolDirectoryIdentity(named) else {
      _ = close(rootFD)
      throw IOSSchoolFailure.ownershipLost
    }
    if let captured = rootIdentity, captured != openedIdentity {
      _ = close(rootFD)
      throw IOSSchoolFailure.ownershipLost
    }
    return rootFD
  }

  private func checkedDirectoryIdentity(_ fd: Int32) throws -> IOSSchoolDirectoryIdentity {
    var value = stat()
    guard fstat(fd, &value) == 0 else { throw IOSSchoolFailure.storageFailed }
    guard (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
          value.st_uid == getuid(),
          (value.st_mode & 0o077) == 0 else {
      throw IOSSchoolFailure.unsafeDirectory
    }
    return IOSSchoolDirectoryIdentity(value)
  }

  private func namedDirectoryIdentity(parentFD: Int32, name: String) throws -> IOSSchoolDirectoryIdentity {
    var value = stat()
    let result = name.withCString { fstatat(parentFD, $0, &value, AT_SYMLINK_NOFOLLOW) }
    guard result == 0 else { throw pathFailure(errno) }
    guard (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
          value.st_uid == getuid(),
          (value.st_mode & 0o077) == 0 else {
      throw IOSSchoolFailure.unsafeDirectory
    }
    return IOSSchoolDirectoryIdentity(value)
  }

  private func readMetadata(profileFD: Int32, name: String) throws -> LoadedMetadata? {
    var named = stat()
    let namedResult = name.withCString {
      fstatat(profileFD, $0, &named, AT_SYMLINK_NOFOLLOW)
    }
    if namedResult != 0 {
      if errno == ENOENT { return nil }
      throw pathFailure(errno)
    }
    try validateRegular(named)
    let expectedIdentity = IOSSchoolFileIdentity(named)
    let fd: Int32 = name.withCString {
      openat(profileFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    }
    guard fd >= 0 else { throw pathFailure(errno) }
    defer { _ = close(fd) }
    var opened = stat()
    guard fstat(fd, &opened) == 0 else { throw IOSSchoolFailure.storageFailed }
    try validateRegular(opened)
    guard IOSSchoolFileIdentity(opened) == expectedIdentity else {
      throw IOSSchoolFailure.ownershipLost
    }
    guard opened.st_size >= 0,
          opened.st_size <= off_t(Self.maximumMetadataBytes) else {
      throw IOSSchoolFailure.invalidSnapshot
    }
    var data = Data(count: Int(opened.st_size))
    try data.withUnsafeMutableBytes { buffer in
      guard let base = buffer.baseAddress else {
        if buffer.isEmpty { return }
        throw IOSSchoolFailure.storageFailed
      }
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.read(fd, base.advanced(by: offset), buffer.count - offset)
        if count < 0 {
          if errno == EINTR { continue }
          throw IOSSchoolFailure.storageFailed
        }
        if count == 0 { throw IOSSchoolFailure.invalidSnapshot }
        offset += count
      }
    }
    var openedAfterRead = stat()
    guard fstat(fd, &openedAfterRead) == 0 else { throw IOSSchoolFailure.storageFailed }
    try validateRegular(openedAfterRead)
    guard IOSSchoolFileIdentity(openedAfterRead) == expectedIdentity else {
      throw IOSSchoolFailure.ownershipLost
    }
    guard openedAfterRead.st_size == opened.st_size else {
      throw IOSSchoolFailure.invalidSnapshot
    }
    var after = stat()
    guard name.withCString({ fstatat(profileFD, $0, &after, AT_SYMLINK_NOFOLLOW) }) == 0 else {
      throw pathFailure(errno)
    }
    try validateRegular(after)
    guard IOSSchoolFileIdentity(after) == expectedIdentity else {
      throw IOSSchoolFailure.ownershipLost
    }
    guard after.st_size == opened.st_size else {
      throw IOSSchoolFailure.invalidSnapshot
    }
    let metadata = try IOSSchoolStoreMetadata.decode(data)
    return LoadedMetadata(
      metadata: metadata,
      identity: expectedIdentity,
      digest: Data(SHA256.hash(data: data))
    )
  }

  private func installMetadata(
    _ metadata: IOSSchoolStoreMetadata,
    profileFD: Int32,
    replacing prior: LoadedMetadata?,
    onSwapped: ((IOSSchoolPendingInstall) -> Void)? = nil
  ) throws -> LoadedMetadata {
    let data = try metadata.encode()
    guard data.count <= Self.maximumMetadataBytes else { throw IOSSchoolFailure.storageFailed }
    let digest = Data(SHA256.hash(data: data))
    try discardIncompleteTemporary(profileFD: profileFD)
    let fd: Int32 = Self.temporaryName.withCString {
      openat(profileFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    }
    guard fd >= 0 else {
      if errno == EEXIST { throw IOSSchoolFailure.busy }
      throw pathFailure(errno)
    }
    var needsClose = true
    defer { if needsClose { _ = close(fd) } }
    guard fchmod(fd, 0o600) == 0 else { throw IOSSchoolFailure.storageFailed }
    try writeAll(data, to: fd)
    try syncFile(fd)
    var written = stat()
    guard fstat(fd, &written) == 0 else { throw IOSSchoolFailure.storageFailed }
    try validateRegular(written)
    let temporaryIdentity = IOSSchoolFileIdentity(written)
    guard close(fd) == 0 else {
      needsClose = false
      throw IOSSchoolFailure.storageFailed
    }
    needsClose = false

    var temporary = stat()
    guard Self.temporaryName.withCString({ fstatat(profileFD, $0, &temporary, AT_SYMLINK_NOFOLLOW) }) == 0 else {
      throw pathFailure(errno)
    }
    try validateRegular(temporary)
    guard IOSSchoolFileIdentity(temporary) == temporaryIdentity else {
      throw IOSSchoolFailure.ownershipLost
    }
    if let prior {
      guard let current = try readMetadata(profileFD: profileFD, name: Self.metadataName),
            current.identity == prior.identity,
            current.digest == prior.digest,
            current.metadata == prior.metadata else {
        throw IOSSchoolFailure.staleResult
      }
      let result = Self.temporaryName.withCString { oldName in
        Self.metadataName.withCString { newName in
          renameatx_np(profileFD, oldName, profileFD, newName, UInt32(RENAME_SWAP))
        }
      }
      guard result == 0 else { throw pathFailure(errno) }
      onSwapped?(IOSSchoolPendingInstall(
        priorMetadata: prior.metadata,
        priorIdentity: prior.identity,
        priorDigest: prior.digest,
        nextMetadata: metadata,
        nextIdentity: temporaryIdentity,
        nextDigest: digest
      ))
#if os(macOS)
      try syntheticAfterSwap?()
#endif
      var oldAtTemporary = stat()
      guard Self.temporaryName.withCString({ fstatat(profileFD, $0, &oldAtTemporary, AT_SYMLINK_NOFOLLOW) }) == 0 else {
        throw IOSSchoolFailure.ownershipLost
      }
      try validateRegular(oldAtTemporary)
      guard IOSSchoolFileIdentity(oldAtTemporary) == prior.identity else {
        throw IOSSchoolFailure.ownershipLost
      }
      guard Self.temporaryName.withCString({ unlinkat(profileFD, $0, 0) }) == 0 else {
        throw IOSSchoolFailure.storageFailed
      }
    } else {
      let result = Self.temporaryName.withCString { oldName in
        Self.metadataName.withCString { newName in
          renameatx_np(profileFD, oldName, profileFD, newName, UInt32(RENAME_EXCL))
        }
      }
      guard result == 0 else {
        if errno == EEXIST { throw IOSSchoolFailure.staleResult }
        throw pathFailure(errno)
      }
    }
    try syncFile(profileFD)
    var installed = stat()
    guard Self.metadataName.withCString({ fstatat(profileFD, $0, &installed, AT_SYMLINK_NOFOLLOW) }) == 0 else {
      throw pathFailure(errno)
    }
    try validateRegular(installed)
    guard IOSSchoolFileIdentity(installed) == temporaryIdentity else {
      throw IOSSchoolFailure.ownershipLost
    }
    return LoadedMetadata(
      metadata: metadata,
      identity: temporaryIdentity,
      digest: digest
    )
  }

  private func discardIncompleteTemporary(profileFD: Int32) throws {
    var value = stat()
    let result = Self.temporaryName.withCString {
      fstatat(profileFD, $0, &value, AT_SYMLINK_NOFOLLOW)
    }
    if result != 0 {
      if errno == ENOENT { return }
      throw pathFailure(errno)
    }
    try validateRegular(value)
    guard value.st_size >= 0,
          value.st_size <= off_t(Self.maximumMetadataBytes) else {
      throw IOSSchoolFailure.unsafeDirectory
    }
    let fd: Int32 = Self.temporaryName.withCString {
      openat(profileFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    }
    guard fd >= 0 else { throw pathFailure(errno) }
    defer { _ = close(fd) }
    var opened = stat()
    guard fstat(fd, &opened) == 0 else { throw IOSSchoolFailure.storageFailed }
    try validateRegular(opened)
    guard IOSSchoolFileIdentity(opened) == IOSSchoolFileIdentity(value) else {
      throw IOSSchoolFailure.ownershipLost
    }
    var namedAgain = stat()
    guard Self.temporaryName.withCString({ fstatat(profileFD, $0, &namedAgain, AT_SYMLINK_NOFOLLOW) }) == 0 else {
      throw pathFailure(errno)
    }
    try validateRegular(namedAgain)
    guard IOSSchoolFileIdentity(namedAgain) == IOSSchoolFileIdentity(opened) else {
      throw IOSSchoolFailure.ownershipLost
    }
    guard Self.temporaryName.withCString({ unlinkat(profileFD, $0, 0) }) == 0 else {
      throw pathFailure(errno)
    }
    try syncFile(profileFD)
  }

  private func validateRegular(_ value: stat) throws {
    guard (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
          value.st_uid == getuid(),
          value.st_nlink == 1,
          (value.st_mode & 0o077) == 0 else {
      throw IOSSchoolFailure.unsafeDirectory
    }
  }

  private func writeAll(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
        if count < 0 {
          if errno == EINTR { continue }
          throw IOSSchoolFailure.storageFailed
        }
        if count == 0 { throw IOSSchoolFailure.storageFailed }
        offset += count
      }
    }
  }

  private func pathFailure(_ code: Int32) -> IOSSchoolFailure {
    lastFailureErrno = code
    switch code {
    case ELOOP, ENOTDIR, EACCES, EPERM:
      return .unsafeDirectory
    case ENOENT:
      return .unsafeDirectory
    default:
      return .storageFailed
    }
  }

  private func syncFile(_ fd: Int32) throws {
    guard fsync(fd) == 0 else {
      lastFailureErrno = errno
      throw IOSSchoolFailure.storageFailed
    }
  }

  private static func matches(_ value: String, pattern: String) -> Bool {
    value.range(of: pattern, options: .regularExpression) != nil
  }

  private static func newUUID() -> UUID {
    while true {
      let value = UUID()
      if value.uuidString.lowercased() != "00000000-0000-0000-0000-000000000000" {
        return value
      }
    }
  }
}

private extension NSLock {
  func iosWithLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
