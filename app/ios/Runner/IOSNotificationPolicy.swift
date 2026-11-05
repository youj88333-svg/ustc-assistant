import Foundation
import CoreFoundation

enum IOSNotificationFailure: String, Error {
  case invalidInput = "invalid_input"
  case stale, busy
  case maintenance
  case disabledBySystem = "disabled_by_system"
  case publishFailed = "publish_failed"
  case cancelFailed = "cancel_failed"
  case cleanupPending = "cleanup_pending"
  case closed
}

/// A notification carries no school credentials or executable navigation.
/// The opaque activation still has to be revalidated against C3 in Dart.
struct IOSNotificationIdentity: Equatable {
  let id: String
  let deliveryAtUnixMs: Int64
  let digest: String
  let token: String

  init(_ raw: [String: Any]) throws {
    try IOSNotificationPolicy.keys(raw, ["id", "deliveryAtUnixMs", "digest", "token"])
    id = try IOSNotificationPolicy.opaque(raw["id"], min: 1, max: 16)
    deliveryAtUnixMs = try IOSNotificationPolicy.integer(raw["deliveryAtUnixMs"])
    digest = try IOSNotificationPolicy.opaque(raw["digest"], min: 64, max: 64)
    token = try IOSNotificationPolicy.opaque(raw["token"], min: 16, max: 64)
  }

  var wire: [String: Any] {
    ["id": id, "deliveryAtUnixMs": deliveryAtUnixMs, "digest": digest, "token": token]
  }
  var activation: [String: Any] { ["id": id, "digest": digest, "token": token] }
  var date: Date { Date(timeIntervalSince1970: Double(deliveryAtUnixMs) / 1000) }
  var systemID: String { IOSNotificationPolicy.prefix + id }
}

struct IOSNotificationRequest {
  let identity: IOSNotificationIdentity
  let title: String
  let detail: String
  let location: String

  init(_ raw: [String: Any]) throws {
    try IOSNotificationPolicy.keys(raw, ["id", "deliveryAtUnixMs", "digest", "token", "title", "detail", "location"])
    var identityFields = raw
    identityFields.removeValue(forKey: "title")
    identityFields.removeValue(forKey: "detail")
    identityFields.removeValue(forKey: "location")
    identity = try IOSNotificationIdentity(identityFields)
    title = try IOSNotificationPolicy.text(raw["title"], max: 160, required: true)
    detail = try IOSNotificationPolicy.text(raw["detail"], max: 240)
    location = try IOSNotificationPolicy.text(raw["location"], max: 160)
  }

  var wire: [String: Any] {
    identity.wire.merging(["title": title, "detail": detail, "location": location]) { _, new in new }
  }
}

struct IOSNotificationAuthority: Equatable {
  let owner: String
  let resetEpoch: Int64
  let agendaEpoch: Int64
  let revision: Int64
  let enabled: Bool

  init(_ raw: [String: Any]) throws {
    try IOSNotificationPolicy.keys(raw, ["owner", "resetEpoch", "agendaEpoch", "revision", "enabled"])
    owner = try IOSNotificationPolicy.opaque(raw["owner"], min: 1, max: 96)
    resetEpoch = try IOSNotificationPolicy.integer(raw["resetEpoch"])
    agendaEpoch = try IOSNotificationPolicy.integer(raw["agendaEpoch"])
    revision = try IOSNotificationPolicy.integer(raw["revision"])
    enabled = try IOSNotificationPolicy.boolean(raw["enabled"])
  }

  func sameContext(_ other: IOSNotificationAuthority) -> Bool {
    owner == other.owner && resetEpoch == other.resetEpoch && agendaEpoch == other.agendaEpoch
  }
}

struct IOSNotificationPublication {
  let authority: IOSNotificationAuthority
  let allowed: [String: IOSNotificationIdentity]

  init(_ raw: [String: Any]) throws {
    try IOSNotificationPolicy.keys(raw, ["authority", "allowed"])
    guard let authority = raw["authority"] as? [String: Any],
          let rows = raw["allowed"] as? [[String: Any]], rows.count <= 2048 else {
      throw IOSNotificationFailure.invalidInput
    }
    self.authority = try IOSNotificationAuthority(authority)
    var parsed: [String: IOSNotificationIdentity] = [:]
    for row in rows {
      let identity = try IOSNotificationIdentity(row)
      guard parsed.updateValue(identity, forKey: identity.id) == nil else {
        throw IOSNotificationFailure.invalidInput
      }
    }
    guard self.authority.enabled || parsed.isEmpty else { throw IOSNotificationFailure.invalidInput }
    allowed = parsed
  }

  func authorizes(_ request: IOSNotificationIdentity, now: Date) -> Bool {
    guard authority.enabled else { return false }
    if request.id == "m6-check" {
      // The explicit test is a short-lived notification without a C3 target.
      return request.date > now && request.date.timeIntervalSince(now) <= 15
    }
    return allowed[request.id] == request
  }
}

enum IOSNotificationPolicy {
  static let maximumPending = 60
  static let prefix = "ustc.i3."
  static let kind = "ustc-reminder-v1"

  static func keys(_ raw: [String: Any], _ expected: Set<String>) throws {
    guard Set(raw.keys) == expected else { throw IOSNotificationFailure.invalidInput }
  }

  static func integer(_ value: Any?, maximum: Int64 = 8_640_000_000_000_000) throws -> Int64 {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          !["f", "d"].contains(String(cString: number.objCType)),
          number.doubleValue >= 0, number.doubleValue <= Double(maximum),
          number.doubleValue == Double(number.int64Value) else {
      throw IOSNotificationFailure.invalidInput
    }
    return number.int64Value
  }

  static func boolean(_ value: Any?) throws -> Bool {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
      throw IOSNotificationFailure.invalidInput
    }
    return number.boolValue
  }

  static func opaque(_ value: Any?, min: Int, max: Int) throws -> String {
    guard let text = value as? String, text.utf8.count >= min, text.utf8.count <= max,
          text.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
            || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
      throw IOSNotificationFailure.invalidInput
    }
    return text
  }

  static func text(_ value: Any?, max: Int, required: Bool = false) throws -> String {
    guard let text = value as? String, text.unicodeScalars.count <= max,
          !required || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          text.unicodeScalars.allSatisfy({ $0.value >= 32 && !(127...159).contains($0.value)
            && !(0xd800...0xdfff).contains($0.value) }) else {
      throw IOSNotificationFailure.invalidInput
    }
    return text
  }

  static func utcComponents(_ identity: IOSNotificationIdentity) -> DateComponents {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: identity.date)
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    components.nanosecond = Int(identity.deliveryAtUnixMs % 1000) * 1_000_000
    return components
  }
}
