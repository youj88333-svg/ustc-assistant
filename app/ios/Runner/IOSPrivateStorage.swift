import Foundation
import UIKit

enum IOSStorageFailure: String, Error {
  case unsafeDirectory = "unsafe_directory"
  case storageFailed = "storage_failed"
  case unavailable
}

enum IOSPrivateStorage {
  static func root() throws -> URL {
    guard UIApplication.shared.isProtectedDataAvailable else { throw IOSStorageFailure.unavailable }
    let manager = FileManager.default
    let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath()
    let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                  appropriateFor: nil, create: true).resolvingSymlinksInPath()
    guard support.path == home.appendingPathComponent("Library/Application Support").path else {
      throw IOSStorageFailure.unsafeDirectory
    }
    let root = support.appendingPathComponent("ustc_assistant_v1", isDirectory: true)
    if manager.fileExists(atPath: root.path) {
      try checkPlain(root, directory: true)
    } else {
      try manager.createDirectory(at: root, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700,
                                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    }
    try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                               ofItemAtPath: root.path)
    var markedRoot = root
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try markedRoot.setResourceValues(values)
    guard try markedRoot.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else {
      throw IOSStorageFailure.storageFailed
    }
    return root
  }

  /// Fixed owned locations only; no path arguments or user-file enumeration.
  static func protectionStatus() throws -> [String: Any] {
    let root = try self.root()
    #if targetEnvironment(simulator)
    let isSimulator = true
    #else
    let isSimulator = false
    #endif
    var inspected = 0
    var protected = true
    let names = ["demo_v1/m0_demo.sqlite", "local_v1/jw.sqlite"]
    for name in names {
      for suffix in ["", "-wal", "-shm"] {
        let file = root.appendingPathComponent(name + suffix)
        guard FileManager.default.fileExists(atPath: file.path) else { continue }
        try checkPlain(file, directory: false)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let protection = (attributes[.protectionKey] as? String)
          ?? (attributes[.protectionKey] as? FileProtectionType)?.rawValue
        protected = protected && protection == FileProtectionType.completeUntilFirstUserAuthentication.rawValue
        inspected += 1
      }
    }
    return ["kind": "ios-storage-protection-v1", "excludedFromBackup": true,
            "filesInspected": inspected, "filesProtected": protected && inspected >= 2,
            "isSimulator": isSimulator]
  }

  private static func checkPlain(_ url: URL, directory: Bool) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeRegular),
          url.resolvingSymlinksInPath().path == url.path else {
      throw IOSStorageFailure.unsafeDirectory
    }
  }
}
