import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var channels: [FlutterMethodChannel] = []
  private let credentialQueue = DispatchQueue(label: "cn.ustcassistant.credentials.v1")
  private var credentialEpoch: UInt64 = 0
  private var engineGeneration: UInt64 = 0
  private var hasBeenActive = false
  private var lifetimeObservers: [NSObjectProtocol] = []
  private var schoolBridge: AnyObject?
  private let notificationBridge = IOSNotificationBridge()
  private var diagnosticExportBridge: IOSDiagnosticExportBridge?
  private var imageBridge: IOSAgentImageBridge?
  private var agentHostBridge: IOSAgentHostLifecycleBridge?

  override func application(_ application: UIApplication,
                            didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    // Install before launch finishes so a notification tap may be retained even
    // before Flutter has initialized its channel or subscribed to activations.
    notificationBridge.installDelegate()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func installLifetimeObservers() {
    guard lifetimeObservers.isEmpty else { return }
    hasBeenActive = UIApplication.shared.applicationState == .active
    lifetimeObservers.append(NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.hasBeenActive = true })
    for name in [UIApplication.willResignActiveNotification,
                 UIApplication.didEnterBackgroundNotification,
                 UIApplication.protectedDataWillBecomeUnavailableNotification,
                 UIApplication.willTerminateNotification] {
      lifetimeObservers.append(NotificationCenter.default.addObserver(
        forName: name, object: nil, queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        self.credentialEpoch &+= 1
      })
    }
  }

  private func leaseValid(_ epoch: UInt64) -> Bool {
    let state = UIApplication.shared.applicationState
    return credentialEpoch == epoch && UIApplication.shared.isProtectedDataAvailable
      && (state == .active || (!hasBeenActive && state == .inactive))
  }

  deinit { lifetimeObservers.forEach { NotificationCenter.default.removeObserver($0) } }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    agentHostBridge?.shutdown()
    channels.forEach { $0.setMethodCallHandler(nil) }
    channels.removeAll()
    engineGeneration &+= 1
    let boundEngine = engineGeneration
    credentialEpoch &+= 1
    installLifetimeObservers()
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    agentHostBridge = IOSAgentHostLifecycleBridge(messenger: messenger)
    notificationBridge.attach(messenger: messenger)
    diagnosticExportBridge?.shutdown()
    diagnosticExportBridge = IOSDiagnosticExportBridge(messenger: messenger, presenter: { [weak self] in
      self?.window?.rootViewController ?? UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        .first(where: \.isKeyWindow)?.rootViewController
    })
    imageBridge?.shutdown()
    imageBridge = IOSAgentImageBridge(messenger: messenger, presenter: { [weak self] in
      self?.window?.rootViewController ?? UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        .first(where: \.isKeyWindow)?.rootViewController
    })
    if #available(iOS 27.0, *) {
      (schoolBridge as? IOSObservationBridge)?.shutdown()
      schoolBridge = IOSObservationBridge(messenger: messenger, presenter: { [weak self] in
        self?.window?.rootViewController ?? UIApplication.shared.connectedScenes
          .compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
          .first(where: \.isKeyWindow)?.rootViewController
      })
    } else {
      let unavailable = FlutterMethodChannel(name: "ustc_assistant/observation_v1", binaryMessenger: messenger)
      unavailable.setMethodCallHandler { _, reply in
        reply(FlutterError(code: "app_failure", message: nil, details: "unsupportedPlatform"))
      }
      schoolBridge = unavailable
    }
    let platform = FlutterMethodChannel(name: "ustc_assistant/platform_v1", binaryMessenger: messenger)
    platform.setMethodCallHandler { [weak self] call, reply in
      guard let self, self.engineGeneration == boundEngine else {
        reply(FlutterError(code: "unavailable", message: nil, details: nil)); return
      }
      guard call.arguments == nil || call.arguments is NSNull else {
        reply(FlutterError(code: "invalid_request", message: nil, details: nil)); return
      }
      do {
        switch call.method {
        case "privateDataRoot": reply(try IOSPrivateStorage.root().path)
        case "storageProtectionStatus": reply(try IOSPrivateStorage.protectionStatus())
        case "i1BuildInfo": reply([
          "revision": Bundle.main.object(forInfoDictionaryKey: "I1SourceRevision") as? String ?? "unknown",
          "bundleId": Bundle.main.bundleIdentifier ?? "unknown"
        ])
        case "i2BuildInfo": reply([
          "revision": Bundle.main.object(forInfoDictionaryKey: "I2SourceRevision") as? String ?? "unknown",
          "bundleId": Bundle.main.bundleIdentifier ?? "unknown",
          "authentication": "manual", "schoolStore": "wk-uuid-v1"
        ])
        case "i3BuildInfo": reply([
          "revision": Bundle.main.object(forInfoDictionaryKey: "I3SourceRevision") as? String ?? "unknown",
          "bundleId": Bundle.main.bundleIdentifier ?? "unknown",
          "authentication": "manual", "notificationBackend": "user-notifications-v1"
        ])
        case "i4BuildInfo": reply([
          "revision": Bundle.main.object(forInfoDictionaryKey: "I4SourceRevision") as? String ?? "unknown",
          "bundleId": Bundle.main.bundleIdentifier ?? "unknown",
          "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
          "buildNumber": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
          "authentication": "manual", "notificationBackend": "user-notifications-v1",
          "imagePicker": "photosui-imageio-v1"
        ])
        #if DEBUG && targetEnvironment(simulator)
        case "i4HostFixtureInspect":
          reply(self.agentHostBridge?.i4HostFixtureInspect() ?? "revoked")
        case "i4HostFixtureSuspend":
          self.agentHostBridge?.i4HostFixtureSuspend(); reply(nil)
        case "i4HostFixtureResume":
          self.agentHostBridge?.i4HostFixtureResume(); reply(nil)
        #endif
        case "i2BrowserDiagnostics":
          if #available(iOS 27.0, *), let bridge = self.schoolBridge as? IOSObservationBridge {
            reply(bridge.diagnostics())
          } else { reply(FlutterError(code: "unsupported_platform", message: nil, details: nil)) }
        default: reply(FlutterMethodNotImplemented)
        }
      } catch let error as IOSStorageFailure {
        reply(FlutterError(code: error.rawValue, message: nil, details: nil))
      } catch { reply(FlutterError(code: "storage_failed", message: nil, details: nil)) }
    }
    let credentials = FlutterMethodChannel(name: "ustc_assistant/credentials_v1", binaryMessenger: messenger)
    credentials.setMethodCallHandler { [weak self] call, reply in
      guard call.method == "protect" || call.method == "unprotect" else {
        reply(FlutterMethodNotImplemented); return
      }
      guard let self, self.engineGeneration == boundEngine else {
        reply(FlutterError(code: "unavailable", message: nil, details: nil)); return
      }
      guard let arguments = call.arguments as? [String: Any],
            Set(arguments.keys) == Set(["purpose", "data"]),
            let purpose = arguments["purpose"] as? String,
            let data = arguments["data"] as? FlutterStandardTypedData else {
        reply(FlutterError(code: "invalid_request", message: nil, details: nil)); return
      }
      guard self.engineGeneration == boundEngine, self.leaseValid(self.credentialEpoch) else {
        reply(FlutterError(code: "unavailable", message: nil, details: nil)); return
      }
      let root: URL
      do { root = try IOSPrivateStorage.root() }
      catch { reply(FlutterError(code: "unavailable", message: nil, details: nil)); return }
      let epoch = self.credentialEpoch
      self.credentialQueue.async {
        do {
          let vault = IOSCredentialVault(root: root, available: {
            DispatchQueue.main.sync {
              self.engineGeneration == boundEngine && self.leaseValid(epoch)
            }
          })
          let output = call.method == "protect"
            ? try vault.protect(data.data, purpose: purpose)
            : try vault.unprotect(data.data, purpose: purpose)
          DispatchQueue.main.async {
            var deliverable = output
            defer { deliverable.resetBytes(in: 0..<deliverable.count) }
            guard self.engineGeneration == boundEngine, self.leaseValid(epoch) else {
              reply(FlutterError(code: "unavailable", message: nil, details: nil)); return
            }
            reply(FlutterStandardTypedData(bytes: deliverable))
          }
        } catch let error as IOSVaultFailure {
          DispatchQueue.main.async { reply(FlutterError(code: error.rawValue, message: nil, details: nil)) }
        } catch {
          DispatchQueue.main.async { reply(FlutterError(code: "protection_failed", message: nil, details: nil)) }
        }
      }
    }
    channels = [platform, credentials]
  }
}
