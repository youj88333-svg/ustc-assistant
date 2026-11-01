import Darwin
import Foundation

@_silgen_name("sandbox_init")
private func iosSchoolSandboxInit(
  _ profile: UnsafePointer<CChar>,
  _ flags: UInt64,
  _ errorBuffer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

private enum LedgerTestFailure: Error {
  case assertion(String)
}

private func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
  if !condition() { throw LedgerTestFailure.assertion(name) }
}

private func rejects(_ name: String, _ action: () throws -> Any?) throws {
  do {
    _ = try action()
  } catch is IOSSchoolFailure {
    return
  }
  throw LedgerTestFailure.assertion(name)
}

private func expectFailure(
  _ expected: IOSSchoolFailure,
  _ name: String,
  _ action: () throws -> Void
) throws {
  do {
    try action()
  } catch let error as IOSSchoolFailure {
    try check(error.rawValue == expected.rawValue, name)
    return
  }
  throw LedgerTestFailure.assertion(name)
}

private final class Fixture {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("ustc-ios-i2-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
  }

  deinit { try? FileManager.default.removeItem(at: root) }

  func profile(_ source: String, suffix: String = "00000000000000000000000000000001", fixture: Bool = false) throws -> URL {
    let components: [String]
    if fixture {
      components = source == "jw"
        ? ["demo_v1", "observation_v1", "obs-\(suffix)"]
        : ["demo_v1", "young_observation_v1", "obs-\(suffix)"]
    } else {
      components = source == "jw"
        ? ["local_v1", "jw_partitions_v1", "jwp-\(suffix)"]
        : ["local_v1", "young_partitions_v1", "yp-\(suffix)"]
    }
    var directory = root
    for component in components {
      directory.appendPathComponent(component, isDirectory: true)
      if !FileManager.default.fileExists(atPath: directory.path) {
        try FileManager.default.createDirectory(
          at: directory,
          withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700]
        )
      }
    }
    return directory
  }
}

@main
private enum IOSSchoolLedgerTests {
  static func main() throws {
    let arguments = CommandLine.arguments
    if arguments.count == 5 && arguments[1] == "--ios-school-ledger-sandbox" {
      try sandboxedLedgerChild(
        rootPath: arguments[2],
        profilePath: arguments[3],
        deniedParentPath: arguments[4]
      )
      return
    }

    var count = 0
    func test(_ body: () throws -> Void) throws {
      try body()
      count += 1
    }

    try test { try policyProductionContracts() }
    try test { try policyFixtureBounds() }
    try test { try separateStoresAndDurableState() }
    try test { try fixtureStorePathsAndFlags() }
    try test { try missingRegistrationDoesNotCreate() }
    try test { try malformedAndCrossSourceRecordsReject() }
    try test { try hardLinkMetadataRejects() }
    try test { try profileSymlinkRejects() }
    try test { try ancestorSymlinkRejects() }
    try test { try profileReplacementRejectsOldToken() }
    try test { try processSandboxAllowsOnlyAnchoredRootOperations() }
    try test { try postSwapFailureRetriesSameRecord() }
    try test { try postSwapDidRemoveFailureRetriesSameRecord() }
    try test { try postSwapRecoveryRejectsOtherUUID() }
    try test { try postSwapRecoveryRejectsReplacementDirectory() }
    print("ios-i2-ledger-tests: \(count) passed")
  }

  private static func policyProductionContracts() throws {
    let jwOrigins = [
      "https://jw.ustc.edu.cn",
      "https://passport.ustc.edu.cn",
      "https://id.ustc.edu.cn",
      "https://analytics.ustc.edu.cn",
    ]
    let jw = try IOSSchoolPolicy(arguments: [
      "source": "jw",
      "initialUrl": "https://jw.ustc.edu.cn/",
      "allowedOrigins": jwOrigins,
      "testMode": false,
    ], allowFixtures: false)
    let jwCourseTarget = try jw.target(page: "courseTable")
    let jwExamTarget = try jw.target(page: "examArrange")
    try check(jwCourseTarget.absoluteString == "https://jw.ustc.edu.cn/for-std/course-table", "jw-course-target")
    try check(jwExamTarget.absoluteString == "https://jw.ustc.edu.cn/for-std/exam-arrange", "jw-exam-target")
    try check(jw.allows(URL(string: "https://id.ustc.edu.cn/cas/login")!), "jw-id-origin")
    try check(!jw.allows(URL(string: "https://attacker.invalid/")!), "jw-unknown-origin")
    try check(!jw.allows(URL(string: "https://user@jw.ustc.edu.cn/")!), "jw-userinfo")
    try rejects("jw-arbitrary-initial-url") {
      try IOSSchoolPolicy(arguments: [
        "source": "jw",
        "initialUrl": "https://jw.ustc.edu.cn/other",
        "allowedOrigins": jwOrigins,
        "testMode": false,
      ], allowFixtures: false)
    }
    try rejects("jw-extra-origin") {
      try IOSSchoolPolicy(arguments: [
        "source": "jw",
        "initialUrl": "https://jw.ustc.edu.cn/",
        "allowedOrigins": jwOrigins + ["https://other.ustc.edu.cn"],
        "testMode": false,
      ], allowFixtures: false)
    }

    let young = try IOSSchoolPolicy(arguments: [
      "source": "young",
      "initialUrl": "https://young.ustc.edu.cn/login/",
      "allowedOrigins": [
        "https://young.ustc.edu.cn",
        "https://passport.ustc.edu.cn",
        "https://ucas.ustc.edu.cn",
        "https://id.ustc.edu.cn",
        "https://analytics.ustc.edu.cn",
      ],
      "testMode": false,
    ], allowFixtures: false)
    let youngActivitiesTarget = try young.target(page: "activities")
    let youngCalendarTarget = try young.target(page: "calendar")
    try check(youngActivitiesTarget.absoluteString == "https://young.ustc.edu.cn/login/sc-wisdom-group-learning/myproject/SignUp", "young-activities-target")
    try check(youngCalendarTarget.absoluteString == "https://young.ustc.edu.cn/login/sc-wisdom-group-learning/personalInformation/mySchedule", "young-calendar-target")
    try rejects("no-android-trust-exception") { try jw.target(page: "arbitraryScript") }
  }

  private static func policyFixtureBounds() throws {
    let args: [String: Any] = [
      "source": "jw",
      "initialUrl": "http://127.0.0.1:49152/index.html",
      "allowedOrigins": ["http://127.0.0.1:49152", "https://127.0.0.1:49153"],
      "testMode": true,
    ]
    let fixture = try IOSSchoolPolicy(arguments: args, allowFixtures: true)
    let fixtureTarget = try fixture.target(page: "courseTable")
    try check(fixture.isFixture, "fixture-marked")
    try check(fixture.allows(URL(string: "https://127.0.0.1:49153/read")!), "fixture-second-origin")
    try check(!fixture.allows(URL(string: "https://127.0.0.1:49154/read")!), "fixture-unregistered-origin")
    try check(fixtureTarget.absoluteString == "http://127.0.0.1:49152/for-std/course-table", "fixture-target-on-loopback")

    try rejects("fixture-release-disabled") {
      try IOSSchoolPolicy(arguments: args, allowFixtures: false)
    }
    for bad in [
      "http://127.0.0.1/index.html",
      "http://127.0.0.2:49152/index.html",
      "http://user@127.0.0.1:49152/index.html",
      "http://127.0.0.1:49152/index.html?token=x",
      "http://127.0.0.1:49152/index.html#fragment",
    ] {
      var modified = args
      modified["initialUrl"] = bad
      try rejects("fixture-reject-\(bad)") {
        try IOSSchoolPolicy(arguments: modified, allowFixtures: true)
      }
    }
    var tooMany = args
    tooMany["allowedOrigins"] = [
      "http://127.0.0.1:49152", "https://127.0.0.1:49153",
      "http://127.0.0.1:49154", "https://127.0.0.1:49155",
      "http://127.0.0.1:49156",
    ]
    try rejects("fixture-five-origins") {
      try IOSSchoolPolicy(arguments: tooMany, allowFixtures: true)
    }
    var originWithPath = args
    originWithPath["allowedOrigins"] = ["http://127.0.0.1:49152/path"]
    try rejects("fixture-origin-path") {
      try IOSSchoolPolicy(arguments: originWithPath, allowFixtures: true)
    }
  }

  private static func separateStoresAndDurableState() throws {
    let fixture = try Fixture()
    let jwPath = try fixture.profile("jw").path
    let youngPath = try fixture.profile("young").path
    var ledger = IOSSchoolStoreLedger(root: fixture.root)
    let jw = try ledger.admit(profilePath: jwPath, source: "jw", create: true)!
    let young = try ledger.admit(profilePath: youngPath, source: "young", create: true)!
    try check(jw.id != young.id, "source-uuids-distinct")
    try check(!jw.disposable && young.source == "young", "jw-production-nondisposable")
    let jwJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: jwPath).appendingPathComponent(IOSSchoolStoreLedger.metadataName))) as! [String: Any]
    try check(Set(jwJSON.keys) == Set(["backend", "source", "id", "disposable", "state"]), "metadata-exact-fields")
    try check(jwJSON["backend"] as? String == "wk-uuid-v1", "metadata-backend")
    try check(jwJSON["state"] as? String == "active", "metadata-active-before-webkit")

    ledger = IOSSchoolStoreLedger(root: fixture.root)
    let reopened = try ledger.admit(profilePath: jwPath, source: "jw", create: false)!
    try check(reopened.id == jw.id, "reopen-same-uuid")
    try ledger.markDeleting(reopened)
    let afterPending = IOSSchoolStoreLedger(root: fixture.root)
    let pending = try afterPending.admit(profilePath: jwPath, source: "jw", create: false)!
    try check(pending.id == jw.id, "pending-keeps-uuid")
    try rejects("pending-not-admissible") {
      try afterPending.admit(profilePath: jwPath, source: "jw", create: true)
    }
    try afterPending.markDeleting(pending)
    try afterPending.didRemove(pending)
    let removed = IOSSchoolStoreLedger(root: fixture.root)
    let removedRecord = try removed.admit(profilePath: jwPath, source: "jw", create: false)!
    try removed.markDeleting(removedRecord)
    try removed.didRemove(removedRecord)
    try rejects("removed-not-reusable") {
      try removed.admit(profilePath: jwPath, source: "jw", create: true)
    }
    let youngAgain = try removed.admit(profilePath: youngPath, source: "young", create: true)!
    try check(youngAgain.id == young.id, "single-store-removal-preserves-other")
  }

  private static func missingRegistrationDoesNotCreate() throws {
    let fixture = try Fixture()
    let path = try fixture.profile("jw").path
    let ledger = IOSSchoolStoreLedger(root: fixture.root)
    let missing = try ledger.admit(profilePath: path, source: "jw", create: false)
    try check(missing == nil, "missing-record-nil")
    try check(!FileManager.default.fileExists(
      atPath: URL(fileURLWithPath: path).appendingPathComponent(IOSSchoolStoreLedger.metadataName).path
    ), "missing-record-no-file")
    try rejects("cross-source-profile") {
      try ledger.admit(profilePath: path, source: "young", create: true)
    }
    try rejects("relative-profile-path") {
      try ledger.admit(profilePath: "local_v1/jw_partitions_v1/jwp-00000000000000000000000000000001", source: "jw", create: true)
    }
  }

  private static func fixtureStorePathsAndFlags() throws {
    let fixture = try Fixture()
    let jwPath = try fixture.profile("jw", fixture: true).path
    let youngPath = try fixture.profile("young", fixture: true).path
    let ledger = IOSSchoolStoreLedger(root: fixture.root)
    let jw = try ledger.admit(profilePath: jwPath, source: "jw", create: true)!
    let young = try ledger.admit(profilePath: youngPath, source: "young", create: true)!
    try check(jw.disposable && young.disposable, "fixture-stores-disposable")
    try check(jw.id != young.id, "fixture-source-uuids-distinct")
    try rejects("fixture-path-source-crossing") {
      try ledger.admit(profilePath: jwPath, source: "young", create: true)
    }
  }

  private static func malformedAndCrossSourceRecordsReject() throws {
    let fixture = try Fixture()
    let path = try fixture.profile("jw").path
    let ledger = IOSSchoolStoreLedger(root: fixture.root)
    let admitted = try ledger.admit(profilePath: path, source: "jw", create: true)!
    let metadataURL = URL(fileURLWithPath: path).appendingPathComponent(IOSSchoolStoreLedger.metadataName)
    let value: [String: Any] = [
      "backend": "wk-uuid-v1",
      "source": "jw",
      "id": admitted.id.uuidString.lowercased(),
      "disposable": false,
      "state": "active",
      "extra": "reject-me",
    ]
    try JSONSerialization.data(withJSONObject: value).write(to: metadataURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
    try rejects("metadata-extra-field") {
      try ledger.admit(profilePath: path, source: "jw", create: false)
    }

    let other = try Fixture()
    let otherPath = try other.profile("jw").path
    let otherLedger = IOSSchoolStoreLedger(root: other.root)
    let otherRecord = try otherLedger.admit(profilePath: otherPath, source: "jw", create: true)!
    let otherMetadataURL = URL(fileURLWithPath: otherPath)
      .appendingPathComponent(IOSSchoolStoreLedger.metadataName)
    let crossed: [String: Any] = [
      "backend": "wk-uuid-v1",
      "source": "young",
      "id": otherRecord.id.uuidString.lowercased(),
      "disposable": false,
      "state": "active",
    ]
    try JSONSerialization.data(withJSONObject: crossed).write(to: otherMetadataURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: otherMetadataURL.path)
    try rejects("metadata-cross-source") {
      try otherLedger.admit(profilePath: otherPath, source: "jw", create: false)
    }
  }

  private static func hardLinkMetadataRejects() throws {
    let fixture = try Fixture()
    let path = try fixture.profile("jw").path
    let ledger = IOSSchoolStoreLedger(root: fixture.root)
    _ = try ledger.admit(profilePath: path, source: "jw", create: true)
    let metadata = URL(fileURLWithPath: path).appendingPathComponent(IOSSchoolStoreLedger.metadataName)
    let other = fixture.root.appendingPathComponent("linked-metadata")
    let result = metadata.path.withCString { oldPath in
      other.path.withCString { newPath in link(oldPath, newPath) }
    }
    try check(result == 0, "hard-link-created")
    try rejects("hard-link-refused") {
      try ledger.admit(profilePath: path, source: "jw", create: false)
    }
  }

  private static func profileSymlinkRejects() throws {
    let fixture = try Fixture()
    let expected = try fixture.profile("jw").path
    let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(
      at: outside,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let moved = fixture.root.appendingPathComponent("moved-profile", isDirectory: true)
    try FileManager.default.moveItem(atPath: expected, toPath: moved.path)
    try FileManager.default.createSymbolicLink(atPath: expected, withDestinationPath: outside.path)
    let ledger = IOSSchoolStoreLedger(root: fixture.root)
    try rejects("profile-symlink-refused") {
      try ledger.admit(profilePath: expected, source: "jw", create: true)
    }
  }

  private static func profileReplacementRejectsOldToken() throws {
    let fixture = try Fixture()
    let path = try fixture.profile("jw").path
    let ledger = IOSSchoolStoreLedger(root: fixture.root)
    let record = try ledger.admit(profilePath: path, source: "jw", create: true)!
    let moved = fixture.root.appendingPathComponent("old-profile", isDirectory: true)
    try FileManager.default.moveItem(atPath: path, toPath: moved.path)
    try FileManager.default.createDirectory(
      atPath: path,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    try rejects("profile-identity-changed") { try ledger.markDeleting(record) }
  }

  private static func ancestorSymlinkRejects() throws {
    let fixture = try Fixture()
    let path = try fixture.profile("jw").path
    let originalParent = URL(fileURLWithPath: path).deletingLastPathComponent()
    let movedParent = fixture.root.appendingPathComponent("moved-jw-partitions", isDirectory: true)
    try FileManager.default.moveItem(at: originalParent, to: movedParent)
    let outside = fixture.root.appendingPathComponent("outside-jw-partitions", isDirectory: true)
    try FileManager.default.createDirectory(
      at: outside,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.createSymbolicLink(atPath: originalParent.path, withDestinationPath: outside.path)
    let ledger = IOSSchoolStoreLedger(root: fixture.root)
    try rejects("ancestor-symlink-refused") {
      try ledger.admit(profilePath: path, source: "jw", create: true)
    }
  }

  private static func processSandboxAllowsOnlyAnchoredRootOperations() throws {
    let fixture = try Fixture()
    // Deny a newly created synthetic parent, not the process TMPDIR, for
    // which Foundation/the launcher may already hold sandbox extensions.
    let anchor = fixture.root.appendingPathComponent("container", isDirectory: true)
    var profileURL = fixture.root
    for component in ["container", "local_v1", "jw_partitions_v1", "jwp-00000000000000000000000000000001"] {
      profileURL.appendPathComponent(component, isDirectory: true)
      try FileManager.default.createDirectory(
        at: profileURL, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
    }
    let profilePath = profileURL.path
    let deniedParentPath = fixture.root.path
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = [
      "--ios-school-ledger-sandbox",
      anchor.path,
      profilePath,
      deniedParentPath,
    ]
    try process.run()
    process.waitUntilExit()
    try check(process.terminationStatus == 0, "sandboxed-ledger-child-success")
  }

  private static func postSwapFailureRetriesSameRecord() throws {
    let fixture = try Fixture()
    let profilePath = try fixture.profile("jw").path
    var failNextSwap = true
    let ledger = IOSSchoolStoreLedger(root: fixture.root) {
      if failNextSwap {
        failNextSwap = false
        throw IOSSchoolFailure.storageFailed
      }
    }
    let record = try ledger.admit(profilePath: profilePath, source: "jw", create: true)!
    try expectFailure(.storageFailed, "post-swap-failure-is-reported") {
      try ledger.markDeleting(record)
    }
    try ledger.markDeleting(record)
    try ledger.didRemove(record)
    let reopened = try ledger.admit(profilePath: profilePath, source: "jw", create: false)!
    try check(reopened.id == record.id, "post-swap-retry-keeps-same-uuid")
    try rejects("post-swap-removed-record-not-reusable") {
      try ledger.admit(profilePath: profilePath, source: "jw", create: true)
    }
  }

  private static func postSwapRecoveryRejectsOtherUUID() throws {
    let fixture = try Fixture()
    let profilePath = try fixture.profile("jw").path
    var failNextSwap = true
    let ledger = IOSSchoolStoreLedger(root: fixture.root) {
      if failNextSwap {
        failNextSwap = false
        throw IOSSchoolFailure.storageFailed
      }
    }
    let record = try ledger.admit(profilePath: profilePath, source: "jw", create: true)!
    try expectFailure(.storageFailed, "foreign-uuid-setup-fails-after-swap") {
      try ledger.markDeleting(record)
    }

    let metadataURL = URL(fileURLWithPath: profilePath)
      .appendingPathComponent(IOSSchoolStoreLedger.metadataName)
    var metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as! [String: Any]
    var otherID = UUID()
    while otherID == record.id { otherID = UUID() }
    metadata["id"] = otherID.uuidString.lowercased()
    let handle = try FileHandle(forWritingTo: metadataURL)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: JSONSerialization.data(withJSONObject: metadata))
    try handle.synchronize()
    try handle.close()
    try expectFailure(.staleResult, "pending-recovery-rejects-other-uuid") {
      try ledger.markDeleting(record)
    }
  }

  private static func postSwapDidRemoveFailureRetriesSameRecord() throws {
    let fixture = try Fixture()
    let profilePath = try fixture.profile("jw").path
    var swaps = 0
    let ledger = IOSSchoolStoreLedger(root: fixture.root) {
      swaps += 1
      if swaps == 2 { throw IOSSchoolFailure.storageFailed }
    }
    let record = try ledger.admit(profilePath: profilePath, source: "jw", create: true)!
    try ledger.markDeleting(record)
    try expectFailure(.storageFailed, "did-remove-post-swap-failure-is-reported") {
      try ledger.didRemove(record)
    }
    try ledger.didRemove(record)
    let reopened = try ledger.admit(profilePath: profilePath, source: "jw", create: false)!
    try check(reopened.id == record.id, "did-remove-retry-keeps-same-uuid")
    try rejects("did-remove-tombstone-not-reusable") {
      try ledger.admit(profilePath: profilePath, source: "jw", create: true)
    }
  }

  private static func postSwapRecoveryRejectsReplacementDirectory() throws {
    let fixture = try Fixture()
    let profilePath = try fixture.profile("jw").path
    var failNextSwap = true
    let ledger = IOSSchoolStoreLedger(root: fixture.root) {
      if failNextSwap {
        failNextSwap = false
        throw IOSSchoolFailure.storageFailed
      }
    }
    let record = try ledger.admit(profilePath: profilePath, source: "jw", create: true)!
    try expectFailure(.storageFailed, "replacement-setup-fails-after-swap") {
      try ledger.markDeleting(record)
    }
    let moved = fixture.root.appendingPathComponent("old-profile", isDirectory: true)
    try FileManager.default.moveItem(atPath: profilePath, toPath: moved.path)
    try FileManager.default.createDirectory(
      atPath: profilePath,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    try expectFailure(.ownershipLost, "pending-recovery-rejects-replacement-directory") {
      try ledger.markDeleting(record)
    }
  }

  private static func sandboxedLedgerChild(
    rootPath: String,
    profilePath: String,
    deniedParentPath: String
  ) throws {
    let root = URL(fileURLWithPath: rootPath, isDirectory: true)
    let expectedParent = root.deletingLastPathComponent().path
    guard root.path == rootPath,
          deniedParentPath == expectedParent,
          !deniedParentPath.contains("\""),
          !deniedParentPath.contains("\\") else {
      throw LedgerTestFailure.assertion("sandbox-fixture-path")
    }
    let profile = "(version 1)\n(allow default)\n(deny file-read* (literal \"\(deniedParentPath)\"))\n"
    let canonicalParent = deniedParentPath.withCString { realpath($0, nil) }
    let canonicalParentMatches = canonicalParent.map { String(cString: $0) == deniedParentPath } ?? false
    if let canonicalParent { free(canonicalParent) }
    let sandboxResult = profile.withCString { iosSchoolSandboxInit($0, 0, nil) }
    try check(sandboxResult == 0, "sandbox-profile-installed")

    var openError: Int32 = 0
    let readFD = deniedParentPath.withCString { path -> Int32 in
      let descriptor = open(path, O_RDONLY | O_CLOEXEC)
      if descriptor < 0 { openError = errno }
      return descriptor
    }
    if readFD >= 0 { _ = close(readFD) }

    var parentMetadata = stat()
    var metadataError: Int32 = 0
    let metadataResult = deniedParentPath.withCString { path -> Int32 in
      let result = fstatat(AT_FDCWD, path, &parentMetadata, AT_SYMLINK_NOFOLLOW)
      if result != 0 { metadataError = errno }
      return result
    }
    print("i2-sandbox-probe: canonical=\(canonicalParentMatches) trailingSlash=\(deniedParentPath.hasSuffix("/")) readDenied=\(readFD < 0) openErrno=\(openError) metadataDenied=\(metadataResult != 0) metadataErrno=\(metadataError)")
    try check(readFD < 0 && (openError == EPERM || openError == EACCES), "sandbox-parent-read-denied")
    try check(
      metadataResult != 0 && (metadataError == EPERM || metadataError == EACCES),
      "sandbox-parent-metadata-denied"
    )

    // O_SEARCH may be allowed by macOS sandbox policy; the required denial is
    // the outside-parent metadata operation above, not this descriptor mode.
    let ledger = IOSSchoolStoreLedger(root: root)
    let record = try ledger.admit(profilePath: profilePath, source: "jw", create: true)!
    try ledger.markDeleting(record)
    // This harness supplies only a synthetic successful-remove acknowledgement.
    try ledger.didRemove(record)
    let reopened = try ledger.admit(profilePath: profilePath, source: "jw", create: false)!
    try check(reopened.id == record.id, "sandbox-ledger-reopen-id")
    try rejects("sandbox-removed-record-not-reused") {
      try ledger.admit(profilePath: profilePath, source: "jw", create: true)
    }
  }
}
