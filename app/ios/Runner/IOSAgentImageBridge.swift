import Flutter
import Foundation
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// One user-mediated PHPicker operation. Only normalized PNG bytes cross to
/// Dart; provider URLs and asset identifiers stay inside this bridge.
public final class IOSAgentImageBridge: NSObject, PHPickerViewControllerDelegate,
  UIAdaptivePresentationControllerDelegate {
  private static let channelName = "ustc_assistant/images_v1"
  // Engine replacement must not open a second picker while the old bridge is
  // still dismissing its UIKit controller or draining an ImageIO callback.
  private static var processHasFlight = false // main-thread only

  private let channel: FlutterMethodChannel
  private let presenter: () -> UIViewController?
  private var flight: IOSAgentImageFlight?
  private var shutdownSelfRetain: IOSAgentImageBridge?
  private var observers: [NSObjectProtocol] = []
  private var isShutdown = false

  public init(
    messenger: FlutterBinaryMessenger,
    presenter: @escaping () -> UIViewController?
  ) {
    self.presenter = presenter
    channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, reply in
      guard let self else { reply(Self.failure("closed")); return }
      self.onMain { self.handle(call, reply: reply) }
    }
    installLifecycleObservers()
  }

  public func shutdown() {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { self.shutdown() }
      return
    }
    guard !isShutdown else { return }
    isShutdown = true
    channel.setMethodCallHandler(nil)
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
    if let flight {
      shutdownSelfRetain = self
      beginCancellation(flight)
    }
  }

  deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

  private func installLifecycleObservers() {
    let center = NotificationCenter.default
    observers.append(center.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in self?.cancelForLifecycle() })
    observers.append(center.addObserver(
      forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in self?.cancelForLifecycle() })
    observers.append(center.addObserver(
      forName: UIApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in self?.cancelForLifecycle() })
  }

  private func cancelForLifecycle() {
    guard let flight else { return }
    beginCancellation(flight)
  }

  private func handle(_ call: FlutterMethodCall, reply: @escaping FlutterResult) {
    guard !isShutdown else { reply(Self.failure("closed")); return }
    switch call.method {
    case "pickImages":
      guard noArguments(call) else { reply(Self.failure("invalid_request")); return }
      pick(reply: reply)
    case "cancel":
      guard noArguments(call) else { reply(Self.failure("invalid_request")); return }
      guard let flight else { reply(nil); return }
      beginCancellation(flight, cancelReply: reply)
    #if DEBUG && targetEnvironment(simulator)
    case "i4ImageFixtureInspect":
      guard noArguments(call) else { reply(Self.failure("invalid_request")); return }
      reply(fixtureState())
    case "i4ImageFixtureCancel":
      guard noArguments(call) else { reply(Self.failure("invalid_request")); return }
      guard let flight, let picker = flight.picker else { reply(nil); return }
      flight.cancelReplies.append(reply)
      self.picker(picker, didFinishPicking: [])
    #endif
    default:
      reply(FlutterMethodNotImplemented)
    }
  }

  private func pick(reply: @escaping FlutterResult) {
    guard flight == nil, !Self.processHasFlight else { reply(Self.failure("busy")); return }
    guard UIApplication.shared.applicationState == .active,
          let host = presenter(),
          host.viewIfLoaded?.window != nil,
          host.presentedViewController == nil else {
      reply(Self.failure("unavailable"))
      return
    }

    var configuration = PHPickerConfiguration()
    configuration.filter = .images
    configuration.selectionLimit = 3
    configuration.preferredAssetRepresentationMode = .current
    configuration.selection = .ordered

    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    let next = IOSAgentImageFlight(reply: reply, picker: picker)
    Self.processHasFlight = true
    flight = next
    next.stage = .presenting
    // A full-screen native controller can pause Flutter's surface. Match the
    // school/Files bridges: no handoff depends on that surface animating.
    host.present(picker, animated: false) { [weak self, weak next, weak picker] in
      guard let self, let next, let picker else { return }
      guard self.flight === next else { return }
      next.presentationResolved = true
      if next.isRevoked {
        self.dismissPicker(next)
        return
      }
      guard picker.presentingViewController != nil else {
        self.finish(next, result: .failure("unavailable"))
        return
      }
      next.stage = .presented
      picker.presentationController?.delegate = self
    }
    picker.presentationController?.delegate = self
  }

  public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    guard let flight, flight.picker === picker,
          !flight.isRevoked, !flight.resultCallbackHandled else { return }
    flight.presentationResolved = true
    flight.resultCallbackHandled = true
    guard results.count <= 3 else {
      dismissPicker(flight) { [weak self, weak flight] in
        guard let self, let flight else { return }
        self.finish(flight, result: .failure("resource_limit"))
      }
      return
    }
    if results.isEmpty {
      flight.stage = .dismissing
      dismissPicker(flight) { [weak self, weak flight] in
        guard let self, let flight else { return }
        guard !flight.isRevoked else { self.finishCancelled(flight); return }
        self.finish(flight, result: .success([]))
      }
      return
    }

    flight.providers = results.map(\.itemProvider)
    flight.stage = .dismissing
    dismissPicker(flight) { [weak self, weak flight] in
      guard let self, let flight else { return }
      guard !flight.isRevoked else { self.finishCancelled(flight); return }
      self.loadNextProvider(flight)
    }
  }

  public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    guard let flight, flight.picker?.presentationController === presentationController else { return }
    flight.presentationResolved = true
    if !flight.resultCallbackHandled {
      flight.resultCallbackHandled = true
      flight.afterDismissal.append { [weak self, weak flight] in
        guard let self, let flight else { return }
        guard !flight.isRevoked else { self.finishCancelled(flight); return }
        self.finish(flight, result: .success([]))
      }
    }
    finishDismissalWait(flight)
  }

  private func loadNextProvider(_ active: IOSAgentImageFlight) {
    guard flight === active else { return }
    guard !active.isRevoked else { finishCancelled(active); return }
    guard active.nextProviderIndex < active.providers.count else {
      finish(active, result: .success(active.images))
      return
    }

    active.stage = .loading
    let index = active.nextProviderIndex
    let provider = active.providers[index]
    guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
      finish(active, result: .failure("image_rejected"))
      return
    }

    let progress = provider.loadFileRepresentation(
      forTypeIdentifier: UTType.image.identifier
    ) { [weak self, active] url, error in
      let report: (NSMutableData?, String?) -> Void = { [weak self, active] data, code in
        DispatchQueue.main.async {
          active.endProcessing()
          guard let self else {
            data.map(IOSAgentImageBridge.wipe)
            return
          }
          self.providerFinished(active, index: index, data: data, code: code)
        }
      }
      // The URL is owned by NSItemProvider and expires when this callback
      // returns. Consume it here; only a bounded normalized PNG survives.
      guard active.beginProcessing() else {
        report(nil, "cancelled")
        return
      }
      guard error == nil, let url else {
        report(nil, "image_rejected")
        return
      }
      let data: NSMutableData
      do {
        data = try IOSAgentImagePolicy.normalizeOwned(fileAt: url)
      } catch let failure as IOSAgentImagePolicyFailure {
        let code: String
        if case .resourceLimit = failure { code = "resource_limit" }
        else { code = "image_rejected" }
        report(nil, code)
        return
      } catch {
        report(nil, "image_rejected")
        return
      }
      report(data, nil)
    }
    if flight === active, active.nextProviderIndex == index,
       active.stage == .loading, !active.isRevoked {
      active.progress = progress
    } else {
      // The provider may complete inline. Do not let its returned Progress
      // overwrite a later provider's handle or a completed flight's state.
      progress.cancel()
    }
  }

  private func providerFinished(
    _ active: IOSAgentImageFlight,
    index: Int,
    data: NSMutableData?,
    code: String?
  ) {
    guard flight === active else {
      data.map(Self.wipe)
      return
    }
    active.progress = nil
    guard !active.isRevoked else {
      data.map(Self.wipe)
      finishCancelled(active)
      return
    }
    guard index == active.nextProviderIndex else {
      data.map(Self.wipe)
      finish(active, result: .failure("image_rejected"))
      return
    }
    if let code {
      data.map(Self.wipe)
      finish(active, result: .failure(code))
      return
    }
    guard let data, data.length > 0,
          data.length <= IOSAgentImagePolicy.maximumNormalizedBytes,
          active.images.count < 3,
          active.imageBytes <= AgentImageLimits.maximumTotalBytes - data.length else {
      data.map(Self.wipe)
      finish(active, result: .failure("resource_limit"))
      return
    }
    active.imageBytes += data.length
    active.images.append(data)
    active.nextProviderIndex += 1
    loadNextProvider(active)
  }

  private func beginCancellation(
    _ active: IOSAgentImageFlight,
    cancelReply: FlutterResult? = nil
  ) {
    if let cancelReply { active.cancelReplies.append(cancelReply) }
    guard flight === active else {
      resolveCancelReplies(active)
      return
    }
    active.revoke()
    active.stage = .cancelling
    active.progress?.cancel()
    active.progress = nil
    active.providers.removeAll()
    active.wipeImages()
    dismissPicker(active)
  }

  private func dismissPicker(_ active: IOSAgentImageFlight, completion: (() -> Void)? = nil) {
    if let completion { active.afterDismissal.append(completion) }
    guard active.presentationResolved else { return }
    if active.dismissalFinished {
      runDismissalCallbacks(active)
      return
    }
    guard !active.dismissalStarted else { return }
    active.dismissalStarted = true
    guard let picker = active.picker else {
      active.dismissalFinished = true
      runDismissalCallbacks(active)
      return
    }
    if picker.presentingViewController != nil && !picker.isBeingDismissed {
      picker.dismiss(animated: false) { [self, active] in
        finishDismissalWait(active)
      }
    } else {
      finishDismissalWait(active)
    }
  }

  private func finishDismissalWait(_ active: IOSAgentImageFlight) {
    guard flight === active, !active.dismissalFinished else { return }
    guard let picker = active.picker else {
      active.dismissalFinished = true
      runDismissalCallbacks(active)
      return
    }
    if picker.isBeingDismissed {
      // An interactive dismissal can be rolled back. Recheck the actual
      // controller after the transition instead of waiting only for DidDismiss.
      let recheck = { [self, active] in
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [self, active] in
          finishDismissalWait(active)
        }
      }
      if let transition = picker.transitionCoordinator {
        if !transition.animate(alongsideTransition: nil, completion: { _ in recheck() }) {
          recheck()
        }
      } else {
        recheck()
      }
    } else if picker.presentingViewController != nil {
      picker.dismiss(animated: false) { [self, active] in finishDismissalWait(active) }
    } else if picker.viewIfLoaded?.window != nil {
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [self, active] in
        finishDismissalWait(active)
      }
    } else {
      active.dismissalFinished = true
      runDismissalCallbacks(active)
    }
  }

  private func runDismissalCallbacks(_ active: IOSAgentImageFlight) {
    guard active.dismissalFinished else { return }
    let callbacks = active.afterDismissal
    active.afterDismissal.removeAll()
    callbacks.forEach { $0() }
    if active.isRevoked { finishCancelled(active) }
  }

  private func finishCancelled(_ active: IOSAgentImageFlight) {
    guard flight === active else {
      resolveCancelReplies(active)
      return
    }
    // A pending provider that has not entered its callback is isolated by the
    // revoked lease. A callback already decoding must return and wipe first.
    guard active.dismissalFinished, !active.isProcessing else { return }
    finish(active, result: .failure("cancelled"))
  }

  private func finish(_ active: IOSAgentImageFlight, result: IOSAgentImageResult) {
    guard flight === active, !active.pickReplyCompleted else {
      if case .success(let images) = result { images.forEach(Self.wipe) }
      return
    }
    let resolved: IOSAgentImageResult
    if active.isRevoked {
      if case .success(let images) = result { images.forEach(Self.wipe) }
      guard active.dismissalFinished, !active.isProcessing else { return }
      // Revocation wins over every late success/error path, including a
      // user-started interactive dismissal that finishes during shutdown.
      resolved = .failure("cancelled")
    } else {
      resolved = result
    }
    active.pickReplyCompleted = true
    flight = nil
    Self.processHasFlight = false
    active.progress?.cancel()
    active.progress = nil
    active.providers.removeAll()
    switch resolved {
    case .success(let images):
      // Give the codec independent byte storage before wiping our mutable
      // normalization buffers. OS/codec copies are outside this ownership.
      let typed = images.map { FlutterStandardTypedData(bytes: Data(bytes: $0.bytes, count: $0.length)) }
      active.reply(typed)
    case .failure(let code):
      active.reply(Self.failure(code))
    }
    active.wipeImages()
    resolveCancelReplies(active)
    if isShutdown { shutdownSelfRetain = nil }
  }

  private func resolveCancelReplies(_ active: IOSAgentImageFlight) {
    let callbacks = active.cancelReplies
    active.cancelReplies.removeAll()
    callbacks.forEach { $0(nil) }
  }

  #if DEBUG && targetEnvironment(simulator)
  private func fixtureState() -> [String: Any] {
    let active = flight
    let picker = active?.picker
    return [
      "fixture": "i4-image-fixture",
      "busy": active != nil,
      "presented": picker?.presentingViewController != nil
        && picker?.viewIfLoaded?.window != nil,
      "stage": active?.stage.rawValue ?? "idle",
    ]
  }
  #endif

  private func noArguments(_ call: FlutterMethodCall) -> Bool {
    call.arguments == nil || call.arguments is NSNull
  }

  private func onMain(_ action: @escaping () -> Void) {
    if Thread.isMainThread { action() }
    else { DispatchQueue.main.async(execute: action) }
  }

  private static func failure(_ code: String) -> FlutterError {
    FlutterError(code: code, message: nil, details: nil)
  }

  fileprivate static func wipe(_ data: NSMutableData) {
    data.resetBytes(in: NSRange(location: 0, length: data.length))
  }
}

private enum IOSAgentImageResult {
  case success([NSMutableData])
  case failure(String)
}

private enum IOSAgentImageStage: String {
  case presenting, presented, dismissing, loading, cancelling
}

private final class IOSAgentImageFlight {
  let reply: FlutterResult
  let picker: PHPickerViewController?
  var providers: [NSItemProvider] = []
  var images: [NSMutableData] = []
  var imageBytes = 0
  var nextProviderIndex = 0
  var progress: Progress?
  var stage: IOSAgentImageStage = .presenting
  var presentationResolved = false
  var dismissalStarted = false
  var dismissalFinished = false
  var resultCallbackHandled = false
  var pickReplyCompleted = false
  var cancelReplies: [FlutterResult] = []
  var afterDismissal: [() -> Void] = []

  private let lock = NSLock()
  private var revoked = false
  private var processing = false

  init(reply: @escaping FlutterResult, picker: PHPickerViewController) {
    self.reply = reply
    self.picker = picker
  }

  var isRevoked: Bool {
    lock.lock()
    defer { lock.unlock() }
    return revoked
  }

  func revoke() {
    lock.lock()
    revoked = true
    lock.unlock()
  }

  var isProcessing: Bool {
    lock.lock()
    defer { lock.unlock() }
    return processing
  }

  func beginProcessing() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !revoked, !processing else { return false }
    processing = true
    return true
  }

  func endProcessing() {
    lock.lock()
    processing = false
    lock.unlock()
  }

  func wipeImages() {
    images.forEach(IOSAgentImageBridge.wipe)
    images.removeAll()
    imageBytes = 0
  }
}

private enum AgentImageLimits {
  static let maximumTotalBytes = 6 * 1024 * 1024
}
