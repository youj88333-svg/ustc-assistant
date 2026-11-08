import Flutter
import Foundation
import UIKit
import Darwin

/// Presents one user-directed JSON export at a time. The bridge never receives
/// a destination path and removes its private temporary file after dismissal.
final class IOSDiagnosticExportBridge: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
  private static let channelName = "ustc_assistant/diagnostics_v1"
  private static let temporaryDirectoryName = "ustc_assistant_diagnostics_export_v1"
  private static let temporaryFilename = IOSDiagnosticExportPolicy.filename

  private static let flightLock = NSLock()
  private static var processHasFlight = false

  private let channel: FlutterMethodChannel
  private let presenter: () -> UIViewController?
  private var flight: ExportFlight?
  private var isShutdown = false

  init(messenger: FlutterBinaryMessenger, presenter: @escaping () -> UIViewController?) {
    self.presenter = presenter
    channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, reply in
      guard let self else { reply(Self.failure("closed")); return }
      self.onMain { self.handle(call, reply: reply) }
    }
  }

  func shutdown() {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in self?.shutdown() }
      return
    }
    guard !isShutdown else { return }
    isShutdown = true
    channel.setMethodCallHandler(nil)
    if let flight {
      finish(flight, response: .failure("closed"))
    }
  }

  private func handle(_ call: FlutterMethodCall, reply: @escaping FlutterResult) {
    guard !isShutdown else { reply(Self.failure("closed")); return }
    switch call.method {
    case "saveDiagnosticLog":
      save(call.arguments, reply: reply)
    #if DEBUG && targetEnvironment(simulator)
    case "i3ExportFixture":
      fixture(call.arguments, reply: reply)
    #endif
    default:
      reply(FlutterMethodNotImplemented)
    }
  }

  private func save(_ arguments: Any?, reply: @escaping FlutterResult) {
    guard let raw = arguments as? [String: Any],
          Set(raw.keys) == Set(["contents"]),
          let contents = raw["contents"] as? String else {
      reply(Self.failure("invalid_input"))
      return
    }

    let data: Data
    do {
      data = try IOSDiagnosticExportPolicy.canonicalJSON(contents)
    } catch {
      reply(Self.failure("invalid_input"))
      return
    }

    guard #available(iOS 14.0, *) else {
      reply(Self.failure("closed"))
      return
    }
    guard Self.claimFlight() else {
      reply(Self.failure("closed"))
      return
    }
    guard UIApplication.shared.applicationState == .active,
          let host = presenter(),
          host.viewIfLoaded?.window != nil,
          host.presentedViewController == nil else {
      Self.releaseFlight()
      reply(Self.failure("closed"))
      return
    }

    let artifact: ExportArtifact
    do {
      artifact = try stage(data)
    } catch {
      Self.releaseFlight()
      reply(Self.failure("export_failed"))
      return
    }

    let picker = UIDocumentPickerViewController(forExporting: [artifact.url], asCopy: true)
    picker.delegate = self
    picker.modalPresentationStyle = .formSheet
    let next = ExportFlight(reply: reply, artifact: artifact, picker: picker)
    flight = next
    host.present(picker, animated: true) { [weak self, weak next, weak picker] in
      guard let self, let next, let picker, self.flight === next else { return }
      guard picker.presentingViewController === host,
            picker.viewIfLoaded?.window != nil else {
        self.finish(next, response: .failure("closed"))
        return
      }
      next.presented = true
      picker.presentationController?.delegate = self
    }
  }

  private func onMain(_ action: @escaping () -> Void) {
    if Thread.isMainThread { action() }
    else { DispatchQueue.main.async(execute: action) }
  }

  private func finish(_ active: ExportFlight, response: ExportResponse) {
    guard flight === active, !active.finishing else { return }
    active.finishing = true

    // Engine replacement releases AppDelegate's old bridge immediately after
    // shutdown. Retain this one completion until dismissal so its private file
    // and process-wide flight lock are always released.
    let dismissed = { [self, active] in
      completeAfterDismissal(active, response: response)
    }

    guard let picker = active.picker else {
      dismissed()
      return
    }
    if picker.presentingViewController != nil && !picker.isBeingDismissed {
      picker.dismiss(animated: true, completion: dismissed)
      return
    }
    if picker.isBeingDismissed, let transition = picker.transitionCoordinator {
      transition.animate(alongsideTransition: nil) { _ in dismissed() }
      return
    }
    if picker.isBeingDismissed {
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [self, active] in
        guard flight === active else { return }
        finishDismissalWait(active, response: response)
      }
      return
    }
    dismissed()
  }

  private func finishDismissalWait(_ active: ExportFlight, response: ExportResponse) {
    guard flight === active, let picker = active.picker else { return }
    if picker.isBeingDismissed {
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [self, active] in
        finishDismissalWait(active, response: response)
      }
    } else if picker.presentingViewController != nil {
      picker.dismiss(animated: true) { [self, active] in
        completeAfterDismissal(active, response: response)
      }
    } else {
      completeAfterDismissal(active, response: response)
    }
  }

  private func completeAfterDismissal(_ active: ExportFlight, response: ExportResponse) {
    guard flight === active, !active.completed else { return }
    active.completed = true
    let cleaned = cleanup(active.artifact)
    flight = nil
    Self.releaseFlight()

    if !cleaned {
      active.reply(Self.failure("export_failed"))
    } else {
      switch response {
      case .value(let value): active.reply(value)
      case .failure(let code): active.reply(Self.failure(code))
      }
    }
    let afterDismissal = active.afterDismissal
    active.afterDismissal.removeAll()
    afterDismissal.forEach { $0() }
  }

  private static func failure(_ code: String) -> FlutterError {
    FlutterError(code: code, message: nil, details: nil)
  }

  private static func claimFlight() -> Bool {
    flightLock.lock()
    defer { flightLock.unlock() }
    guard !processHasFlight else { return false }
    processHasFlight = true
    return true
  }

  private static func releaseFlight() {
    flightLock.lock()
    processHasFlight = false
    flightLock.unlock()
  }

  // Uses only Foundation's app tmp directory, one fixed child, and one fixed
  // filename. openat/O_NOFOLLOW and inode checks keep cleanup scoped to our file.
  private func stage(_ data: Data) throws -> ExportArtifact {
    let root = FileManager.default.temporaryDirectory.standardizedFileURL
    let expectedRoot = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent("tmp", isDirectory: true).standardizedFileURL
    guard root.isFileURL, expectedRoot.isFileURL else {
      throw IOSDiagnosticExportFailure.exportFailed
    }

    let rootFD = Darwin.open(root.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
    guard rootFD >= 0 else { throw IOSDiagnosticExportFailure.exportFailed }
    defer { _ = Darwin.close(rootFD) }
    let expectedRootFD = Darwin.open(
      expectedRoot.path,
      O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
    )
    guard expectedRootFD >= 0 else { throw IOSDiagnosticExportFailure.exportFailed }
    defer { _ = Darwin.close(expectedRootFD) }

    var rootStat = stat()
    var expectedRootStat = stat()
    guard fstat(rootFD, &rootStat) == 0,
          fstat(expectedRootFD, &expectedRootStat) == 0,
          isDirectory(rootStat),
          rootStat.st_uid == geteuid(),
          (rootStat.st_mode & mode_t(0o077)) == 0,
          isDirectory(expectedRootStat),
          expectedRootStat.st_uid == geteuid(),
          (expectedRootStat.st_mode & mode_t(0o077)) == 0,
          rootStat.st_dev == expectedRootStat.st_dev,
          rootStat.st_ino == expectedRootStat.st_ino else {
      throw IOSDiagnosticExportFailure.exportFailed
    }

    let madeDirectory = Self.temporaryDirectoryName.withCString {
      Darwin.mkdirat(rootFD, $0, mode_t(0o700))
    }
    if madeDirectory != 0 && errno != EEXIST {
      throw IOSDiagnosticExportFailure.exportFailed
    }

    let directoryFD = Self.temporaryDirectoryName.withCString {
      Darwin.openat(rootFD, $0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
    }
    guard directoryFD >= 0 else { throw IOSDiagnosticExportFailure.exportFailed }
    var keepDirectory = false
    defer { if !keepDirectory { _ = Darwin.close(directoryFD) } }

    var directoryStat = stat()
    guard fstat(directoryFD, &directoryStat) == 0,
          isDirectory(directoryStat),
          directoryStat.st_uid == geteuid(),
          (directoryStat.st_mode & mode_t(0o077)) == 0 else {
      throw IOSDiagnosticExportFailure.exportFailed
    }
    if fchmod(directoryFD, mode_t(0o700)) != 0 {
      throw IOSDiagnosticExportFailure.exportFailed
    }

    let directoryURL = root.appendingPathComponent(Self.temporaryDirectoryName, isDirectory: true)
    do {
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: directoryURL.path
      )
      guard hasClassCProtection(directoryURL) else {
        throw IOSDiagnosticExportFailure.exportFailed
      }
      let entries = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
      guard entries.allSatisfy({ $0 == Self.temporaryFilename }) else {
        throw IOSDiagnosticExportFailure.exportFailed
      }
    } catch {
      throw IOSDiagnosticExportFailure.exportFailed
    }

    var previous = stat()
    let priorState = Self.temporaryFilename.withCString {
      fstatat(directoryFD, $0, &previous, AT_SYMLINK_NOFOLLOW)
    }
    if priorState == 0 {
      guard isPrivateRegularFile(previous), previous.st_nlink == 1,
            previous.st_size >= 0,
            previous.st_size <= off_t(IOSDiagnosticExportPolicy.maximumBytes) else {
        throw IOSDiagnosticExportFailure.exportFailed
      }
      guard Self.temporaryFilename.withCString({ unlinkat(directoryFD, $0, 0) }) == 0 else {
        throw IOSDiagnosticExportFailure.exportFailed
      }
    } else if errno != ENOENT {
      throw IOSDiagnosticExportFailure.exportFailed
    }

    let fileFD = Self.temporaryFilename.withCString {
      Darwin.openat(
        directoryFD,
        $0,
        O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        mode_t(0o600)
      )
    }
    guard fileFD >= 0 else { throw IOSDiagnosticExportFailure.exportFailed }
    var keepFile = false
    var fileDevice: dev_t = 0
    var fileInode: ino_t = 0
    defer {
      if !keepFile {
        if fileInode != 0 {
          _ = unlinkIfMatching(
            directoryFD: directoryFD,
            device: fileDevice,
            inode: fileInode
          )
        } else {
          _ = unlinkNewlyCreatedRegularFile(directoryFD: directoryFD)
        }
        _ = Darwin.close(fileFD)
      }
    }

    var fileStat = stat()
    guard fstat(fileFD, &fileStat) == 0,
          isOwnedRegularFile(fileStat),
          fileStat.st_nlink == 1 else {
      throw IOSDiagnosticExportFailure.exportFailed
    }
    fileDevice = fileStat.st_dev
    fileInode = fileStat.st_ino
    guard fchmod(fileFD, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
      throw IOSDiagnosticExportFailure.exportFailed
    }
    guard fstat(fileFD, &fileStat) == 0,
          isPrivateRegularFile(fileStat),
          fileStat.st_dev == fileDevice,
          fileStat.st_ino == fileInode,
          fileStat.st_nlink == 1 else {
      throw IOSDiagnosticExportFailure.exportFailed
    }

    try writeAll(data, to: fileFD)
    guard fsync(fileFD) == 0, lseek(fileFD, 0, SEEK_SET) == 0 else {
      throw IOSDiagnosticExportFailure.exportFailed
    }

    let fileURL = directoryURL.appendingPathComponent(Self.temporaryFilename, isDirectory: false)
    do {
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: fileURL.path
      )
      guard hasClassCProtection(fileURL) else {
        throw IOSDiagnosticExportFailure.exportFailed
      }
    } catch {
      throw IOSDiagnosticExportFailure.exportFailed
    }

    var finalStat = stat()
    var namedStat = stat()
    guard fstat(fileFD, &finalStat) == 0,
          isPrivateRegularFile(finalStat),
          finalStat.st_dev == fileDevice,
          finalStat.st_ino == fileInode,
          finalStat.st_nlink == 1,
          finalStat.st_size == off_t(data.count),
          Self.temporaryFilename.withCString({
            fstatat(directoryFD, $0, &namedStat, AT_SYMLINK_NOFOLLOW)
          }) == 0,
          isPrivateRegularFile(namedStat),
          namedStat.st_dev == fileDevice,
          namedStat.st_ino == fileInode,
          namedStat.st_nlink == 1 else {
      throw IOSDiagnosticExportFailure.exportFailed
    }

    keepDirectory = true
    keepFile = true
    return ExportArtifact(
      url: fileURL,
      directoryFD: directoryFD,
      fileFD: fileFD,
      device: fileDevice,
      inode: fileInode
    )
  }

  private func cleanup(_ artifact: ExportArtifact) -> Bool {
    var current = stat()
    let result = Self.temporaryFilename.withCString {
      fstatat(artifact.directoryFD, $0, &current, AT_SYMLINK_NOFOLLOW)
    }
    var removed = false
    if result == 0,
       isPrivateRegularFile(current),
       current.st_nlink == 1,
       current.st_dev == artifact.device,
       current.st_ino == artifact.inode {
      removed = Self.temporaryFilename.withCString {
        unlinkat(artifact.directoryFD, $0, 0) == 0
      }
    } else if result != 0 && errno == ENOENT {
      removed = true
    }
    _ = Darwin.close(artifact.fileFD)
    _ = Darwin.close(artifact.directoryFD)
    return removed
  }

  private func temporaryFilePresent(_ artifact: ExportArtifact) -> Bool {
    var current = stat()
    let result = Self.temporaryFilename.withCString {
      fstatat(artifact.directoryFD, $0, &current, AT_SYMLINK_NOFOLLOW)
    }
    return result == 0 && isPrivateRegularFile(current) && current.st_nlink == 1
      && current.st_dev == artifact.device && current.st_ino == artifact.inode
  }

  private func hasClassCProtection(_ url: URL) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
      return false
    }
    let protection = (attributes[.protectionKey] as? String)
      ?? (attributes[.protectionKey] as? FileProtectionType)?.rawValue
    return protection == FileProtectionType.completeUntilFirstUserAuthentication.rawValue
  }

  private func unlinkIfMatching(directoryFD: Int32, device: dev_t, inode: ino_t) -> Bool {
    var current = stat()
    let result = Self.temporaryFilename.withCString {
      fstatat(directoryFD, $0, &current, AT_SYMLINK_NOFOLLOW)
    }
    guard result == 0, isPrivateRegularFile(current), current.st_nlink == 1,
          current.st_dev == device, current.st_ino == inode else { return false }
    return Self.temporaryFilename.withCString { unlinkat(directoryFD, $0, 0) == 0 }
  }

  private func unlinkNewlyCreatedRegularFile(directoryFD: Int32) -> Bool {
    var current = stat()
    let result = Self.temporaryFilename.withCString {
      fstatat(directoryFD, $0, &current, AT_SYMLINK_NOFOLLOW)
    }
    guard result == 0, isOwnedRegularFile(current), current.st_nlink == 1 else { return false }
    return Self.temporaryFilename.withCString { unlinkat(directoryFD, $0, 0) == 0 }
  }

  private func isDirectory(_ value: stat) -> Bool {
    value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
  }

  private func isPrivateRegularFile(_ value: stat) -> Bool {
    isOwnedRegularFile(value)
      && (value.st_mode & mode_t(0o777)) == mode_t(0o600)
  }

  private func isOwnedRegularFile(_ value: stat) -> Bool {
    (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
      && value.st_uid == geteuid()
      && (value.st_mode & mode_t(0o077)) == 0
  }

  private func writeAll(_ data: Data, to fileFD: Int32) throws {
    var written = 0
    try data.withUnsafeBytes { rawBuffer in
      guard let base = rawBuffer.baseAddress else {
        throw IOSDiagnosticExportFailure.exportFailed
      }
      while written < rawBuffer.count {
        let amount = Darwin.write(fileFD, base.advanced(by: written), rawBuffer.count - written)
        if amount < 0 && errno == EINTR { continue }
        guard amount > 0 else { throw IOSDiagnosticExportFailure.exportFailed }
        written += amount
      }
    }
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let active = flight, active.picker === controller else { return }
    finish(active, response: urls.isEmpty ? .failure("export_failed") : .value(true))
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    guard let active = flight, active.picker === controller else { return }
    finish(active, response: .value(false))
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    guard let picker = presentationController.presentedViewController as? UIDocumentPickerViewController,
          let active = flight, active.picker === picker else { return }
    finish(active, response: .value(false))
  }

  #if DEBUG && targetEnvironment(simulator)
  private func fixture(_ arguments: Any?, reply: @escaping FlutterResult) {
    guard let raw = arguments as? [String: Any],
          Set(raw.keys) == Set(["action"]),
          let action = raw["action"] as? String else {
      reply(Self.failure("closed"))
      return
    }
    switch action {
    case "inspect":
      let active = flight
      reply([
        "presented": active?.presented == true,
        "tempFilePresent": active.map { temporaryFilePresent($0.artifact) } ?? false,
        "busy": active != nil
      ])
    case "cancel":
      guard let active = flight, let picker = active.picker else {
        reply(nil)
        return
      }
      active.afterDismissal.append { reply(nil) }
      documentPickerWasCancelled(picker)
    default:
      reply(Self.failure("closed"))
    }
  }
  #endif
}

private enum ExportResponse {
  case value(Any?)
  case failure(String)
}

private final class ExportFlight {
  let reply: FlutterResult
  let artifact: ExportArtifact
  let picker: UIDocumentPickerViewController?
  var presented = false
  var finishing = false
  var completed = false
  var afterDismissal: [() -> Void] = []

  init(reply: @escaping FlutterResult, artifact: ExportArtifact, picker: UIDocumentPickerViewController) {
    self.reply = reply
    self.artifact = artifact
    self.picker = picker
  }
}

private struct ExportArtifact {
  let url: URL
  let directoryFD: Int32
  let fileFD: Int32
  let device: dev_t
  let inode: ino_t
}
