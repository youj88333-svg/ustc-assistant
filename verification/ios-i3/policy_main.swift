import Foundation

private enum CheckFailure: Error { case failed(String) }
private func check(_ condition: Bool, _ label: String) throws {
  guard condition else { throw CheckFailure.failed(label) }
}
private func rejects(_ label: String, _ body: () throws -> Void) throws {
  do { try body() } catch is IOSNotificationFailure { return }
  throw CheckFailure.failed(label)
}
private func identity(id: String = "m6-1", ms: Int64 = 1_800_000_000_123) -> [String: Any] {
  ["id": id, "deliveryAtUnixMs": ms, "digest": String(repeating: "a", count: 64),
   "token": String(repeating: "b", count: 64)]
}
private func publication(enabled: Bool = true, allowed: [[String: Any]]) -> [String: Any] {
  ["authority": ["owner": "synthetic-owner", "resetEpoch": 1, "agendaEpoch": 2,
                 "revision": 3, "enabled": enabled], "allowed": allowed]
}

@main struct NotificationPolicyChecks {
  static func main() throws {
    let raw = identity()
    let accepted = try IOSNotificationIdentity(raw)
    try check(accepted.systemID == "ustc.i3.m6-1", "namespaced OS identity")
    try check(accepted.activation.count == 3 && accepted.activation["deliveryAtUnixMs"] == nil, "activation minimizes fields")
    let invalidNumbers: [Any] = [true, 1.0, -1, "1800000000000", NSNumber(value: UInt64.max)]
    for value in invalidNumbers {
      try rejects("invalid time") { var row = raw; row["deliveryAtUnixMs"] = value; _ = try IOSNotificationIdentity(row) }
    }
    for bad in ["../other", "https://school.invalid", "", String(repeating: "x", count: 17)] {
      try rejects("invalid id") { _ = try IOSNotificationIdentity(identity(id: bad)) }
    }
    try rejects("extra URL") { var row = raw; row["url"] = "https://example.invalid"; _ = try IOSNotificationIdentity(row) }
    try rejects("empty token") { var row = raw; row["token"] = ""; _ = try IOSNotificationIdentity(row) }
    try check(try IOSNotificationPolicy.integer(NSNumber(value: 8_640_000_000_000_000 as Int64)) == 8_640_000_000_000_000, "bounded time")
    print("i3 policy: identifiers and wire primitives passed")

    let request = raw.merging(["title": "合成课程", "detail": "即将开始", "location": "TEST-101"]) { _, new in new }
    _ = try IOSNotificationRequest(request)
    for field in ["title", "detail", "location"] {
      try rejects("control text") { var row = request; row[field] = "synthetic\nsecret"; _ = try IOSNotificationRequest(row) }
    }
    try rejects("empty title") { var row = request; row["title"] = "  "; _ = try IOSNotificationRequest(row) }
    try rejects("long title") { var row = request; row["title"] = String(repeating: "中", count: 161); _ = try IOSNotificationRequest(row) }
    print("i3 policy: display limits passed")

    let bound = try IOSNotificationPublication(publication(allowed: [raw]))
    let before = accepted.date.addingTimeInterval(-60)
    try check(bound.authorizes(accepted, now: before), "bound request")
    try check(!bound.authorizes(try IOSNotificationIdentity(identity(id: "m6-2")), now: before), "foreign mapping refused")
    var altered = raw; altered["token"] = String(repeating: "c", count: 64)
    try check(!bound.authorizes(try IOSNotificationIdentity(altered), now: before), "old token refused")
    try rejects("duplicate ids") { _ = try IOSNotificationPublication(publication(allowed: [raw, raw])) }
    try rejects("disabled allowed list") { _ = try IOSNotificationPublication(publication(enabled: false, allowed: [raw])) }
    let disabled = try IOSNotificationPublication(publication(enabled: false, allowed: []))
    try check(!disabled.authorizes(accepted, now: before), "disabled cannot authorize")
    try rejects("fake enabled number") {
      var row = publication(allowed: [raw]); var authority = row["authority"] as! [String: Any]
      authority["enabled"] = 1; row["authority"] = authority; _ = try IOSNotificationPublication(row)
    }
    print("i3 policy: publication and stale identity passed")

    let test = try IOSNotificationIdentity(identity(id: "m6-check"))
    try check(bound.authorizes(test, now: test.date.addingTimeInterval(-5)), "explicit short test")
    try check(!bound.authorizes(test, now: test.date.addingTimeInterval(-60)), "test horizon bounded")
    try check(!bound.authorizes(test, now: test.date), "no catch-up test")
    let components = IOSNotificationPolicy.utcComponents(accepted)
    try check(components.timeZone?.secondsFromGMT() == 0 && components.nanosecond == 123_000_000, "absolute UTC milliseconds")
    try check(abs(components.date!.timeIntervalSince1970 - accepted.date.timeIntervalSince1970) < 0.0001, "date roundtrip")
    try check(IOSNotificationPolicy.maximumPending == 60, "app policy cap")
    print("i3 policy: UTC and bounded explicit test passed")
  }
}
