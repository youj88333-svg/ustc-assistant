import CryptoKit
import Darwin
import Foundation

private final class MemoryKeys: IOSCredentialKeyStore {
  var values: [String: Data] = [:]
  var fail = false
  var onRead: (() -> Void)?
  func load(account: String) throws -> Data? {
    if fail { throw IOSVaultFailure.unavailable }
    let action = onRead; onRead = nil; action?()
    return values[account]
  }
  func insert(_ key: Data, account: String) throws -> Bool {
    if fail { throw IOSVaultFailure.unavailable }
    if values[account] != nil { return false }
    values[account] = key
    return true
  }
}

private final class Fixture {
  let root: URL
  let keys = MemoryKeys()
  var available = true
  init() throws {
    root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("ustc-i1-vault-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
  }
  var marker: URL { root.appendingPathComponent(".key-generation-v1") }
  var vault: IOSCredentialVault {
    IOSCredentialVault(root: root, keys: keys, available: { [unowned self] in self.available })
  }
  deinit { try? FileManager.default.removeItem(at: root) }
}

private enum TestFailure: Error { case assertion(String) }
private func check(_ condition: Bool, _ name: String) throws {
  if !condition { throw TestFailure.assertion(name) }
}
private func rejects(_ name: String, _ action: () throws -> Void) throws {
  do { try action() } catch is IOSVaultFailure { return }
  throw TestFailure.assertion(name)
}

@main
private enum VaultTests {
  static func main() throws {
    let owner = String(repeating: "1", count: 32)
    let school = "ustc-assistant/jw/login/v1:jw-owner-\(owner):" + String(repeating: "a", count: 64)
    let model = "ustc-model-key/v1/jw-owner-\(owner)"
    let otherModel = "deepseek-model-key/v1/jw-owner-\(owner)"
    let plain = Data("synthetic-only-i1".utf8)
    var count = 0
    func test(_ body: () throws -> Void) throws { try body(); count += 1 }

    try test {
      let f = try Fixture()
      let sealed = try f.vault.protect(plain, purpose: school)
      try check(sealed.count == plain.count + 29 && sealed.first == 1, "envelope")
      let reopened = try f.vault.unprotect(sealed, purpose: school)
      try check(reopened == plain, "reopen-roundtrip")
    }
    try test {
      let f = try Fixture()
      let sealed = try f.vault.protect(plain, purpose: model)
      try rejects("provider-purpose") { _ = try f.vault.unprotect(sealed, purpose: otherModel) }
      try rejects("school-purpose") { _ = try f.vault.unprotect(sealed, purpose: school) }
      _ = try f.vault.protect(plain, purpose: school)
      try check(f.keys.values.count == 2, "separate-key-families")
    }
    try test {
      let f = try Fixture()
      var sealed = try f.vault.protect(plain, purpose: model)
      sealed[sealed.count - 1] ^= 1
      try rejects("tamper") { _ = try f.vault.unprotect(sealed, purpose: model) }
      try rejects("invalid-purpose") { _ = try f.vault.protect(plain, purpose: model + "\n") }
      try rejects("empty") { _ = try f.vault.protect(Data(), purpose: model) }
      try rejects("oversize") { _ = try f.vault.protect(Data(count: 16385), purpose: model) }
    }
    try test {
      let f = try Fixture()
      let sealed = try f.vault.protect(plain, purpose: school)
      f.available = false
      try rejects("background") { _ = try f.vault.unprotect(sealed, purpose: school) }
      f.available = true; f.keys.fail = true
      try rejects("keychain-unavailable") { _ = try f.vault.unprotect(sealed, purpose: school) }
    }
    try test {
      let f = try Fixture()
      let sealed = try f.vault.protect(plain, purpose: school)
      f.keys.onRead = { f.available = false }
      try rejects("revoked-during-key-read") { _ = try f.vault.unprotect(sealed, purpose: school) }
    }
    try test {
      let f = try Fixture()
      let sealed = try f.vault.protect(plain, purpose: school)
      f.keys.values.removeAll()
      try rejects("missing-key") { _ = try f.vault.unprotect(sealed, purpose: school) }
      try check(f.keys.values.isEmpty, "decrypt-created-key")
    }
    try test {
      let f = try Fixture()
      let sealed = try f.vault.protect(plain, purpose: school)
      try FileManager.default.removeItem(at: f.marker)
      try rejects("missing-generation") { _ = try f.vault.unprotect(sealed, purpose: school) }
      try check(!FileManager.default.fileExists(atPath: f.marker.path), "decrypt-created-marker")
      _ = try f.vault.protect(plain, purpose: school)
      try rejects("new-install-generation") { _ = try f.vault.unprotect(sealed, purpose: school) }
    }
    try test {
      let f = try Fixture()
      _ = try f.vault.protect(plain, purpose: school)
      f.keys.onRead = {
        try! FileManager.default.moveItem(at: f.marker, to: f.root.appendingPathComponent("old-marker"))
        try! Data(UUID().uuidString.lowercased().utf8).write(to: f.marker)
      }
      try rejects("marker-replaced-during-protect") { _ = try f.vault.protect(plain, purpose: school) }
    }
    try test {
      let f = try Fixture()
      _ = try f.vault.protect(plain, purpose: school)
      f.keys.onRead = {
        try! Data(UUID().uuidString.lowercased().utf8).write(to: f.marker, options: [])
      }
      try rejects("marker-content-changed") { _ = try f.vault.protect(plain, purpose: school) }
    }
    try test {
      let f = try Fixture()
      try check(mkfifo(f.marker.path, 0o600) == 0, "fifo-create")
      let start = Date()
      try rejects("fifo-must-not-block") { _ = try f.vault.protect(plain, purpose: model) }
      try check(Date().timeIntervalSince(start) < 2, "fifo-time-bound")
    }
    try test {
      let f = try Fixture()
      let target = f.root.appendingPathComponent("target")
      try Data(UUID().uuidString.lowercased().utf8).write(to: target)
      try FileManager.default.createSymbolicLink(at: f.marker, withDestinationURL: target)
      try rejects("marker-symlink") { _ = try f.vault.protect(plain, purpose: model) }
    }
    try test {
      let f = try Fixture()
      _ = try f.vault.protect(plain, purpose: model)
      try check(link(f.marker.path, f.root.appendingPathComponent("hardlink").path) == 0, "link-create")
      try rejects("marker-hardlink") { _ = try f.vault.protect(plain, purpose: model) }
    }
    print("i1-vault-tests: \(count) passed (synthetic store / real CryptoKit / Darwin IO)")
  }
}
