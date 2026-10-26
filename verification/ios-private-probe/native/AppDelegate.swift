import Flutter
import UIKit
import WidgetKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private static let channelName = "ustc_assistant/ios_i0_v1"

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, reply in
      guard call.method == "inspect" || call.method == "writeSyntheticMarker" else {
        reply(FlutterMethodNotImplemented)
        return
      }
      guard call.arguments == nil || call.arguments is NSNull else {
        reply(FlutterError(code: "invalid_arguments", message: nil, details: nil))
        return
      }

      let snapshot = call.method == "inspect"
        ? I0SharedSnapshot.inspect()
        : I0SharedSnapshot.writeSyntheticMarker()
      if call.method == "writeSyntheticMarker",
        snapshot.groupAvailable,
        snapshot.failure == nil,
        snapshot.marker != nil
      {
        WidgetCenter.shared.reloadTimelines(ofKind: "I0ProbeWidget")
      }
      reply(Self.responseMap(for: snapshot))
    }
  }

  private static func responseMap(for snapshot: I0SharedSnapshot.Result) -> [String: Any] {
    let sourceRevision = Bundle.main.object(forInfoDictionaryKey: "I0SourceRevision") as? String
    return [
      "kind": "ios-i0-probe-v1",
      "sourceRevision": sourceRevision.map { $0 as Any } ?? NSNull(),
      "bundleId": Bundle.main.bundleIdentifier ?? "unknown",
      "groupAvailable": snapshot.groupAvailable,
      "groupDigest": snapshot.groupDigest.map { $0 as Any } ?? NSNull(),
      "marker": snapshot.marker.map { $0 as Any } ?? NSNull(),
      "markerCreatedAt": snapshot.markerCreatedAt.map { $0 as Any } ?? NSNull(),
      "failure": snapshot.failure.map { $0 as Any } ?? NSNull(),
    ]
  }
}
