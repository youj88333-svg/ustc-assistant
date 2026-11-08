import Flutter
import Foundation
import UIKit
import UserNotifications

/// Serializes app-owned OS requests; C3 remains the business authority. There
/// is no native database mirror and no notification-time school/model work.
final class IOSNotificationBridge: NSObject, UNUserNotificationCenterDelegate {
  private let center = UNUserNotificationCenter.current()
  private var channel: FlutterMethodChannel?
  private var epoch: UInt64 = 0
  private var publication: IOSNotificationPublication?
  private var operations: [(@escaping () -> Void) -> Void] = []
  private var running = false
  private var activations: [[String: Any]] = []
  private var activationKeys: Set<String> = []
  #if DEBUG && targetEnvironment(simulator)
  private var fixtureDenied = false
  #endif

  func installDelegate() { center.delegate = self }

  func attach(messenger: FlutterBinaryMessenger) {
    epoch &+= 1
    publication = nil
    channel?.setMethodCallHandler(nil)
    let channel = FlutterMethodChannel(name: "ustc_assistant/ios_notifications_v1", binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, reply in
      guard let self else { reply(Self.failure(.closed)); return }
      let generation = self.epoch
      self.enqueue(reply: reply) { finish in
        guard generation == self.epoch else { reply(Self.failure(.closed)); finish(); return }
        self.handle(call, epoch: generation) { value in reply(value); finish() }
      }
    }
  }

  private static func failure(_ failure: IOSNotificationFailure, systemError: Error? = nil) -> FlutterError {
    guard let error = systemError as NSError? else {
      return FlutterError(code: failure.rawValue, message: nil, details: nil)
    }
    let domain: String
    switch error.domain {
    case "UNErrorDomain": domain = "notifications"
    case NSCocoaErrorDomain: domain = "cocoa"
    case NSPOSIXErrorDomain: domain = "posix"
    default: domain = "other"
    }
    let code: Any = (-32768...32767).contains(error.code) ? error.code : NSNull()
    return FlutterError(code: failure.rawValue, message: nil,
      details: ["domain": domain, "code": code])
  }

  private func enqueue(reply: @escaping FlutterResult, operation: @escaping (@escaping () -> Void) -> Void) {
    guard operations.count < 32 else { reply(Self.failure(.busy)); return }
    operations.append(operation)
    drain()
  }

  private func drain() {
    guard !running, !operations.isEmpty else { return }
    running = true
    let operation = operations.removeFirst()
    operation { [weak self] in
      guard let self else { return }
      self.running = false
      DispatchQueue.main.async { self.drain() }
    }
  }

  private func handle(_ call: FlutterMethodCall, epoch generation: UInt64, reply: @escaping FlutterResult) {
    do {
      switch call.method {
      case "initialize", "requestExactAlarms":
        try noArguments(call)
        capability(reply)
      case "requestNotifications":
        try noArguments(call)
        guard UIApplication.shared.applicationState == .active else {
          throw IOSNotificationFailure.maintenance
        }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
          DispatchQueue.main.async {
            guard let self else { reply(Self.failure(.closed)); return }
            guard error == nil else { reply(Self.failure(.publishFailed, systemError: error)); return }
            self.capability(reply)
          }
        }
      case "openSystemSettings":
        try noArguments(call)
        guard UIApplication.shared.applicationState == .active else { throw IOSNotificationFailure.maintenance }
        let text: String
        if #available(iOS 16.0, *) { text = UIApplication.openNotificationSettingsURLString }
        else { text = UIApplication.openSettingsURLString }
        guard let url = URL(string: text) else { throw IOSNotificationFailure.publishFailed }
        UIApplication.shared.open(url, options: [:]) { success in
          DispatchQueue.main.async { reply(success ? nil : Self.failure(.publishFailed)) }
        }
      case "pending":
        try noArguments(call)
        readPending(reply)
      case "bindPublication":
        let next = try IOSNotificationPublication(arguments(call))
        if let prior = publication, prior.authority.sameContext(next.authority),
           next.authority.revision < prior.authority.revision { throw IOSNotificationFailure.stale }
        if let prior = publication, !prior.authority.sameContext(next.authority) {
          publication = nil
          clearOwned { [weak self] failure in
            guard let self else { reply(Self.failure(.closed)); return }
            if let failure { reply(Self.failure(failure)); return }
            guard generation == self.epoch else { reply(Self.failure(.closed)); return }
            self.publication = next
            reply(nil)
          }
        } else { publication = next; reply(nil) }
      case "schedule":
        try schedule(IOSNotificationRequest(arguments(call)), epoch: generation, reply: reply)
      case "cancel":
        let raw = try arguments(call)
        try IOSNotificationPolicy.keys(raw, ["id"])
        let id = try IOSNotificationPolicy.opaque(raw["id"], min: 1, max: 16)
        removeOwned(ids: [IOSNotificationPolicy.prefix + id]) { failure in
          reply(failure == nil ? nil : Self.failure(.cancelFailed))
        }
      case "clear", "blockDelivery":
        try noArguments(call)
        publication = nil
        activations.removeAll(); activationKeys.removeAll()
        clearOwned { failure in reply(failure.map { Self.failure($0) }) }
      case "takeActivations":
        try noArguments(call)
        let result = activations
        activations.removeAll(); activationKeys.removeAll()
        reply(result)
      #if DEBUG && targetEnvironment(simulator)
      case "i3Fixture":
        try fixture(arguments(call), reply: reply)
      #endif
      default: reply(FlutterMethodNotImplemented)
      }
    } catch let failure as IOSNotificationFailure { reply(Self.failure(failure)) }
    catch { reply(Self.failure(.invalidInput)) }
  }

  private func noArguments(_ call: FlutterMethodCall) throws {
    guard call.arguments == nil || call.arguments is NSNull else { throw IOSNotificationFailure.invalidInput }
  }
  private func arguments(_ call: FlutterMethodCall) throws -> [String: Any] {
    guard let raw = call.arguments as? [String: Any] else { throw IOSNotificationFailure.invalidInput }
    return raw
  }

  private func capability(_ reply: @escaping FlutterResult) {
    center.getNotificationSettings { [weak self] settings in
      DispatchQueue.main.async {
        guard let self else { reply(Self.failure(.closed)); return }
        let status: String
        switch settings.authorizationStatus {
        case .notDetermined: status = "notDetermined"
        case .denied: status = "denied"
        case .authorized: status = "authorized"
        case .provisional: status = "provisional"
        case .ephemeral: status = "ephemeral"
        @unknown default: status = "unknown"
        }
        var enabled = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
        #if DEBUG && targetEnvironment(simulator)
        if self.fixtureDenied { enabled = false }
        #endif
        reply(["available": true, "enabledBySystem": enabled, "schedulesAfterExit": true,
          "activationAvailable": true, "exactScheduling": NSNull(),
          "queueEvidence": "operatingSystem", "maximumPending": IOSNotificationPolicy.maximumPending,
          "authorizationStatus": status, "alertsEnabled": Self.setting(settings.alertSetting),
          "soundsEnabled": Self.setting(settings.soundSetting),
          "lockScreenEnabled": Self.setting(settings.lockScreenSetting),
          "scheduledSummaryEnabled": Self.setting(settings.scheduledDeliverySetting)])
      }
    }
  }

  private static func setting(_ setting: UNNotificationSetting) -> Any {
    switch setting { case .enabled: return true; case .disabled: return false
    default: return NSNull() }
  }

  private func schedule(_ request: IOSNotificationRequest, epoch generation: UInt64, reply: @escaping FlutterResult) throws {
    guard let publication, publication.authorizes(request.identity, now: Date()) else {
      throw IOSNotificationFailure.stale
    }
    guard request.identity.date > Date(),
          request.identity.date.timeIntervalSinceNow <= 181 * 86400 else { throw IOSNotificationFailure.stale }
    center.getNotificationSettings { [weak self] settings in
      DispatchQueue.main.async {
        guard let self, generation == self.epoch else { reply(Self.failure(.closed)); return }
        var enabled = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
        #if DEBUG && targetEnvironment(simulator)
        if self.fixtureDenied { enabled = false }
        #endif
        guard enabled else { reply(Self.failure(.disabledBySystem)); return }
        self.center.getPendingNotificationRequests { pending in
          DispatchQueue.main.async {
            guard generation == self.epoch, self.publication?.authorizes(request.identity, now: Date()) == true else {
              reply(Self.failure(.stale)); return
            }
            let own = pending.filter { $0.identifier.hasPrefix(IOSNotificationPolicy.prefix) }
            guard own.count < IOSNotificationPolicy.maximumPending || own.contains(where: { $0.identifier == request.identity.systemID }) else {
              reply(Self.failure(.publishFailed)); return
            }
            let content = UNMutableNotificationContent()
            content.title = request.title; content.body = request.detail; content.subtitle = request.location
            content.sound = .default
            content.userInfo = request.identity.wire.merging(["kind": IOSNotificationPolicy.kind]) { _, new in new }
            content.interruptionLevel = .active
            let trigger = UNCalendarNotificationTrigger(dateMatching: IOSNotificationPolicy.utcComponents(request.identity), repeats: false)
            self.center.add(UNNotificationRequest(identifier: request.identity.systemID, content: content, trigger: trigger)) { error in
              DispatchQueue.main.async {
                guard generation == self.epoch else {
                  self.center.removePendingNotificationRequests(withIdentifiers: [request.identity.systemID])
                  reply(Self.failure(.closed)); return
                }
                reply(error == nil ? nil : Self.failure(.publishFailed, systemError: error))
              }
            }
          }
        }
      }
    }
  }

  private static func identity(_ request: UNNotificationRequest) throws -> IOSNotificationIdentity {
    guard request.identifier.hasPrefix(IOSNotificationPolicy.prefix),
          let info = request.content.userInfo as? [String: Any],
          info["kind"] as? String == IOSNotificationPolicy.kind else { throw IOSNotificationFailure.invalidInput }
    var raw = info
    raw.removeValue(forKey: "kind")
    let identity = try IOSNotificationIdentity(raw)
    guard identity.systemID == request.identifier else { throw IOSNotificationFailure.invalidInput }
    return identity
  }

  private func readPending(_ reply: @escaping FlutterResult) {
    center.getPendingNotificationRequests { pending in
      DispatchQueue.main.async {
        do {
          let own = pending.filter { $0.identifier.hasPrefix(IOSNotificationPolicy.prefix) }
          guard own.count <= 2048 else { throw IOSNotificationFailure.publishFailed }
          let rows = try own.map { item -> [String: Any] in
            let identity = try Self.identity(item)
            guard let trigger = item.trigger as? UNCalendarNotificationTrigger, !trigger.repeats,
                  trigger.dateComponents.timeZone?.secondsFromGMT() == 0,
                  let date = trigger.dateComponents.date,
                  abs(date.timeIntervalSince1970 - identity.date.timeIntervalSince1970) < 0.0001 else {
              throw IOSNotificationFailure.publishFailed
            }
            // Read actual trigger/content, rather than accepting an app mirror
            // or merely trusting the metadata attached at scheduling time.
            return try IOSNotificationRequest(identity.wire.merging([
              "title": item.content.title, "detail": item.content.body, "location": item.content.subtitle
            ]) { _, new in new }).wire
          }
          reply(rows)
        } catch { reply(Self.failure(.publishFailed)) }
      }
    }
  }

  private func clearOwned(_ completion: @escaping (IOSNotificationFailure?) -> Void) {
    center.getPendingNotificationRequests { [weak self] pending in
      guard let self else { DispatchQueue.main.async { completion(.closed) }; return }
      self.center.getDeliveredNotifications { delivered in
        let ids = Set(pending.map(\.identifier).filter { $0.hasPrefix(IOSNotificationPolicy.prefix) })
          .union(delivered.map { $0.request.identifier }.filter { $0.hasPrefix(IOSNotificationPolicy.prefix) })
        DispatchQueue.main.async { self.removeOwned(ids: Array(ids), completion: completion) }
      }
    }
  }

  private func removeOwned(ids: [String], attempt: Int = 0, completion: @escaping (IOSNotificationFailure?) -> Void) {
    guard !ids.isEmpty else { completion(nil); return }
    center.removePendingNotificationRequests(withIdentifiers: ids)
    center.removeDeliveredNotifications(withIdentifiers: ids)
    center.getPendingNotificationRequests { [weak self] pending in
      guard let self else { DispatchQueue.main.async { completion(.closed) }; return }
      self.center.getDeliveredNotifications { delivered in
        let remaining = pending.contains { ids.contains($0.identifier) }
          || delivered.contains { ids.contains($0.request.identifier) }
        DispatchQueue.main.async {
          if !remaining { completion(nil) }
          else if attempt < 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
              self.removeOwned(ids: ids, attempt: attempt + 1, completion: completion)
            }
          } else { completion(.cleanupPending) }
        }
      }
    }
  }

  private func capture(_ identity: IOSNotificationIdentity) {
    let key = identity.id + "/" + identity.digest + "/" + identity.token
    guard activationKeys.insert(key).inserted else { return }
    if activations.count == 32 {
      activations.removeFirst()
      activationKeys = Set(activations.compactMap { item in
        guard let id = item["id"] as? String, let digest = item["digest"] as? String, let token = item["token"] as? String else { return nil }
        return id + "/" + digest + "/" + token
      })
      activationKeys.insert(key)
    }
    activations.append(identity.activation)
    channel?.invokeMethod("activationsChanged", arguments: nil)
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                              withCompletionHandler completionHandler: @escaping () -> Void) {
    DispatchQueue.main.async {
      if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
         let identity = try? Self.identity(response.notification.request) { self.capture(identity) }
      completionHandler()
    }
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                              withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler((try? Self.identity(notification.request)) == nil ? [] : [.banner, .list, .sound])
  }

  #if DEBUG && targetEnvironment(simulator)
  /// Fixed simulator-only actions; never compiled into the private AOT IPA.
  private func fixture(_ raw: [String: Any], reply: @escaping FlutterResult) throws {
    guard let action = raw["action"] as? String else { throw IOSNotificationFailure.invalidInput }
    if action == "activate" {
      try IOSNotificationPolicy.keys(raw, ["action", "id"])
      let id = try IOSNotificationPolicy.opaque(raw["id"], min: 1, max: 16)
      center.getPendingNotificationRequests { pending in
        DispatchQueue.main.async {
          guard let request = pending.first(where: { $0.identifier == IOSNotificationPolicy.prefix + id }),
                let identity = try? Self.identity(request) else { reply(Self.failure(.stale)); return }
          self.capture(identity); reply(nil)
        }
      }
    } else {
      try IOSNotificationPolicy.keys(raw, ["action"])
      switch action {
      case "provisional":
        center.requestAuthorization(options: [.alert, .sound, .provisional]) { _, error in
          DispatchQueue.main.async { reply(error == nil ? nil : Self.failure(.publishFailed)) }
        }
      case "deny": fixtureDenied = true; reply(nil)
      case "restore": fixtureDenied = false; reply(nil)
      default: throw IOSNotificationFailure.invalidInput
      }
    }
  }
  #endif
}
