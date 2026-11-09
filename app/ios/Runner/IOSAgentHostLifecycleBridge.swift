import Flutter
import UIKit

/// Only application activity leaves this bridge, never scene or file details.
/// Native school and system-picker view transitions do not themselves revoke
/// the application; real resignation/background/protection loss does.
final class IOSAgentHostLifecycleBridge: NSObject, FlutterStreamHandler {
  private let channel: FlutterEventChannel
  private var sink: FlutterEventSink?
  private var observers: [NSObjectProtocol] = []
  private var closed = false
  #if DEBUG && targetEnvironment(simulator)
  private var fixtureState: String?
  #endif

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterEventChannel(name: "ustc_assistant/ios_host_lifecycle_v1", binaryMessenger: messenger)
    super.init()
    channel.setStreamHandler(self)
    observers.append(NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.emitCurrent() })
    observers.append(NotificationCenter.default.addObserver(
      forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.emitCurrent() })
    observers.append(NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.sink?("inactive") })
    for name in [UIApplication.didEnterBackgroundNotification,
                 UIApplication.protectedDataWillBecomeUnavailableNotification,
                 UIApplication.willTerminateNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
        [weak self] _ in self?.sink?("revoked")
      })
    }
  }

  private func emitCurrent() {
    guard !closed else { return }
    #if DEBUG && targetEnvironment(simulator)
    if let value = fixtureState { sink?(value); return }
    #endif
    let application = UIApplication.shared
    if !application.isProtectedDataAvailable || application.applicationState == .background {
      sink?("revoked")
    } else {
      sink?(application.applicationState == .active ? "active" : "inactive")
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    guard arguments == nil || arguments is NSNull, !closed, sink == nil else {
      return FlutterError(code: "unavailable", message: nil, details: nil)
    }
    sink = events
    emitCurrent()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  func shutdown() {
    guard !closed else { return }
    closed = true
    sink?("revoked")
    sink?(FlutterEndOfEventStream)
    sink = nil
    channel.setStreamHandler(nil)
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
  }

  deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

  #if DEBUG && targetEnvironment(simulator)
  func i4HostFixtureSuspend() { fixtureState = "revoked"; emitCurrent() }
  func i4HostFixtureResume() { fixtureState = nil; emitCurrent() }
  #endif
}
