import CryptoKit
import Darwin
import Foundation
import Security

enum IOSVaultFailure: String, Error {
  case invalidRequest = "invalid_request"
  case unavailable
  case invalidCredential = "invalid_credential"
  case protectionFailed = "protection_failed"
}

protocol IOSCredentialKeyStore {
  func load(account: String) throws -> Data?
  func insert(_ key: Data, account: String) throws -> Bool
}

final class IOSKeychainKeyStore: IOSCredentialKeyStore {
  private let service: String
  init(service: String = "cn.ustcassistant.credential-keys.v1") { self.service = service }

  private func query(_ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service, kSecAttrAccount as String: account,
     kSecAttrSynchronizable as String: false]
  }

  func load(account: String) throws -> Data? {
    var request = query(account)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let key = item as? Data, key.count == 32 else {
      throw IOSVaultFailure.unavailable
    }
    return key
  }

  func insert(_ key: Data, account: String) throws -> Bool {
    guard key.count == 32 else { throw IOSVaultFailure.protectionFailed }
    var request = query(account)
    request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    request[kSecValueData as String] = key
    let status = SecItemAdd(request as CFDictionary, nil)
    if status == errSecDuplicateItem { return false }
    guard status == errSecSuccess else { throw IOSVaultFailure.unavailable }
    return true
  }
}

/// Keys only live in Keychain; credential ciphertext remains owned by C3.
/// The disk generation prevents accidental reuse of leftover uninstall keys.
final class IOSCredentialVault {
  private let root: URL
  private let keys: IOSCredentialKeyStore
  private let available: () -> Bool
  private static let maximumPlaintext = 16 * 1024
  private static let maximumEnvelope = 64 * 1024
  private static let markerName = ".key-generation-v1"

  init(root: URL, keys: IOSCredentialKeyStore = IOSKeychainKeyStore(),
       available: @escaping () -> Bool) {
    self.root = root; self.keys = keys; self.available = available
  }

  func protect(_ plaintext: Data, purpose: String) throws -> Data {
    let family = try Self.family(purpose)
    guard !plaintext.isEmpty, plaintext.count <= Self.maximumPlaintext else {
      throw IOSVaultFailure.invalidRequest
    }
    guard available() else { throw IOSVaultFailure.unavailable }
    let generation = try GenerationLease(root: root, create: true)
    let account = generation.value + "." + family
    var material = try keys.load(account: account)
    if material == nil {
      var fresh = Data(count: 32)
      let status = fresh.withUnsafeMutableBytes { buffer in
        SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
      }
      guard status == errSecSuccess else { throw IOSVaultFailure.protectionFailed }
      _ = try keys.insert(fresh, account: account)
      fresh.resetBytes(in: 0..<fresh.count)
      material = try keys.load(account: account)
    }
    guard var key = material, key.count == 32 else { throw IOSVaultFailure.unavailable }
    defer { key.resetBytes(in: 0..<key.count) }
    try generation.verify()
    guard available() else { throw IOSVaultFailure.unavailable }
    do {
      let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key),
                                 authenticating: Data(purpose.utf8))
      guard let combined = box.combined, combined.count == plaintext.count + 28 else {
        throw IOSVaultFailure.protectionFailed
      }
      try generation.verify()
      guard available() else { throw IOSVaultFailure.unavailable }
      return Data([1]) + combined
    } catch let error as IOSVaultFailure { throw error
    } catch { throw IOSVaultFailure.protectionFailed }
  }

  func unprotect(_ envelope: Data, purpose: String) throws -> Data {
    let family = try Self.family(purpose)
    guard envelope.count > 29, envelope.count <= Self.maximumEnvelope,
          envelope.first == 1 else { throw IOSVaultFailure.invalidCredential }
    guard available() else { throw IOSVaultFailure.unavailable }
    // Decryption must never recreate a missing generation or encryption key.
    let generation = try GenerationLease(root: root, create: false)
    let account = generation.value + "." + family
    guard var key = try keys.load(account: account), key.count == 32 else {
      throw IOSVaultFailure.invalidCredential
    }
    defer { key.resetBytes(in: 0..<key.count) }
    try generation.verify()
    guard available() else { throw IOSVaultFailure.unavailable }
    do {
      let box = try AES.GCM.SealedBox(combined: Data(envelope.dropFirst()))
      let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key),
                                       authenticating: Data(purpose.utf8))
      guard !plaintext.isEmpty, plaintext.count <= Self.maximumPlaintext else {
        throw IOSVaultFailure.invalidCredential
      }
      try generation.verify()
      guard available() else { throw IOSVaultFailure.unavailable }
      return plaintext
    } catch let error as IOSVaultFailure { throw error
    } catch { throw IOSVaultFailure.invalidCredential }
  }

  private static func family(_ purpose: String) throws -> String {
    guard purpose.utf8.count <= 256 else { throw IOSVaultFailure.invalidRequest }
    let patterns = [
      ("school", "^ustc-assistant/jw/login/v1:jw-owner-[0-9a-f]{32}:[0-9a-f]{64}$"),
      ("model", "^(?:ustc|deepseek)-model-key/v1/jw-owner-[0-9a-f]{32}$")
    ]
    let full = NSRange(purpose.startIndex..<purpose.endIndex, in: purpose)
    for (name, pattern) in patterns {
      let expression = try NSRegularExpression(pattern: pattern)
      if expression.firstMatch(in: purpose, range: full)?.range == full { return name }
    }
    throw IOSVaultFailure.invalidRequest
  }

  private final class GenerationLease {
    private var rootFD: Int32 = -1
    private var descriptor: Int32 = -1
    private let rootPath: String
    private var rootMetadata = stat()
    private var metadata = stat()
    private(set) var value = ""

    init(root: URL, create: Bool) throws {
      rootPath = root.path
      rootFD = open(root.path, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
      guard rootFD >= 0, fstat(rootFD, &rootMetadata) == 0,
            rootMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            rootMetadata.st_uid == geteuid() else {
        if rootFD >= 0 { _ = close(rootFD); rootFD = -1 }
        throw IOSVaultFailure.invalidCredential
      }
      do {
        descriptor = openat(rootFD, IOSCredentialVault.markerName,
                            O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT, create {
          let fresh = Array(UUID().uuidString.lowercased().utf8)
          let created = openat(rootFD, IOSCredentialVault.markerName,
                               O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
          if created >= 0 {
            descriptor = created
            var written = 0
            while written < fresh.count {
              let count = fresh.withUnsafeBytes { bytes in
                Darwin.write(created, bytes.baseAddress!.advanced(by: written), fresh.count - written)
              }
              if count < 0, errno == EINTR { continue }
              if count <= 0 { throw IOSVaultFailure.protectionFailed }
              written += count
            }
            guard fsync(created) == 0 else { throw IOSVaultFailure.protectionFailed }
          } else if errno != EEXIST { throw IOSVaultFailure.protectionFailed }
          if descriptor < 0 {
            descriptor = openat(rootFD, IOSCredentialVault.markerName,
                                O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
          }
        }
        guard descriptor >= 0 else { throw IOSVaultFailure.invalidCredential }
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == geteuid(), metadata.st_nlink == 1,
              metadata.st_mode & 0o077 == 0, metadata.st_size == 36 else {
          throw IOSVaultFailure.invalidCredential
        }
        var bytes = [UInt8](repeating: 0, count: 37)
        let count = bytes.withUnsafeMutableBytes { Darwin.pread(descriptor, $0.baseAddress, 37, 0) }
        guard count == 36, let parsed = String(bytes: bytes.prefix(36), encoding: .utf8),
              UUID(uuidString: parsed)?.uuidString.lowercased() == parsed else {
          throw IOSVaultFailure.invalidCredential
        }
        value = parsed
        try verify()
      } catch {
        if descriptor >= 0 { _ = close(descriptor); descriptor = -1 }
        _ = close(rootFD); rootFD = -1
        throw error
      }
    }

    deinit {
      if descriptor >= 0 { _ = close(descriptor) }
      if rootFD >= 0 { _ = close(rootFD) }
    }

    func verify() throws {
      var namedRoot = stat(), heldRoot = stat(), named = stat(), held = stat()
      guard fstat(rootFD, &heldRoot) == 0, lstat(rootPath, &namedRoot) == 0,
            heldRoot.st_dev == rootMetadata.st_dev, heldRoot.st_ino == rootMetadata.st_ino,
            namedRoot.st_dev == rootMetadata.st_dev, namedRoot.st_ino == rootMetadata.st_ino,
            namedRoot.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            fstat(descriptor, &held) == 0,
            fstatat(rootFD, IOSCredentialVault.markerName, &named, AT_SYMLINK_NOFOLLOW) == 0,
            held.st_dev == metadata.st_dev, held.st_ino == metadata.st_ino,
            named.st_dev == metadata.st_dev, named.st_ino == metadata.st_ino,
            held.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            named.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            held.st_nlink == 1, named.st_nlink == 1,
            held.st_uid == geteuid(), named.st_uid == geteuid(),
            held.st_mode & 0o077 == 0, named.st_mode & 0o077 == 0,
            held.st_size == 36, named.st_size == 36 else {
        throw IOSVaultFailure.invalidCredential
      }
      var bytes = [UInt8](repeating: 0, count: 37)
      let count = bytes.withUnsafeMutableBytes { Darwin.pread(descriptor, $0.baseAddress, 37, 0) }
      guard count == 36, Array(bytes.prefix(36)) == Array(value.utf8) else {
        throw IOSVaultFailure.invalidCredential
      }
    }
  }
}
