import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var channels: [FlutterMethodChannel] = []
  private let credentialQueue = DispatchQueue(label: "cn.ustcassistant.credentials.v1")
  private var credentialEpoch: UInt64 = 0
  private var hasBeenActive = false
  private var lifetimeObservers: [NSObjectProtocol] = []

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
    credentialEpoch &+= 1
    installLifetimeObservers()
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    let platform = FlutterMethodChannel(name: "ustc_assistant/platform_v1", binaryMessenger: messenger)
    platform.setMethodCallHandler { call, reply in
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
      guard let self, let arguments = call.arguments as? [String: Any],
            Set(arguments.keys) == Set(["purpose", "data"]),
            let purpose = arguments["purpose"] as? String,
            let data = arguments["data"] as? FlutterStandardTypedData else {
        reply(FlutterError(code: "invalid_request", message: nil, details: nil)); return
      }
      guard self.leaseValid(self.credentialEpoch) else {
        reply(FlutterError(code: "unavailable", message: nil, details: nil)); return
      }
      let root: URL
      do { root = try IOSPrivateStorage.root() }
      catch { reply(FlutterError(code: "unavailable", message: nil, details: nil)); return }
      let epoch = self.credentialEpoch
      self.credentialQueue.async {
        do {
          let vault = IOSCredentialVault(root: root, available: {
            DispatchQueue.main.sync { self.leaseValid(epoch) }
          })
          let output = call.method == "protect"
            ? try vault.protect(data.data, purpose: purpose)
            : try vault.unprotect(data.data, purpose: purpose)
          DispatchQueue.main.async {
            var deliverable = output
            defer { deliverable.resetBytes(in: 0..<deliverable.count) }
            guard self.leaseValid(epoch) else {
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
