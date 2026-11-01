import Foundation

private enum ScriptTestFailure: Error {
  case assertion(String)
}

private func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
  if !condition() { throw ScriptTestFailure.assertion(name) }
}

private func rejects(_ name: String, _ expected: IOSSchoolFailure, _ body: () throws -> Void) throws {
  do {
    try body()
  } catch let failure as IOSSchoolFailure {
    try check(failure.rawValue == expected.rawValue, "\(name)-wrong-error-\(failure.rawValue)")
    return
  }
  throw ScriptTestFailure.assertion("\(name)-accepted")
}

@main
private enum IOSSchoolScriptTests {
  static func main() throws {
    let repository = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
      ?? FileManager.default.currentDirectoryPath, isDirectory: true).standardizedFileURL
    let resources = repository.appendingPathComponent(
      "app/android/app/src/main/assets/ustc", isDirectory: true
    )

    let jw = try fixturePolicy("jw")
    let young = try fixturePolicy("young")
    let jwScripts = try IOSSchoolScripts(policy: jw, resourceDirectory: resources)
    let youngScripts = try IOSSchoolScripts(policy: young, resourceDirectory: resources)
    let jwInstall = try jwScripts.install(document: 7)
    let youngInstall = try youngScripts.install(document: 4)
    let jwMarker = try replyMarker(in: jwInstall)
    let youngMarker = try replyMarker(in: youngInstall)

    var count = 0
    func test(_ body: () throws -> Void) throws {
      try body()
      count += 1
    }

    try test {
      let bootstrap = IOSSchoolScripts.guardBootstrap
      try check(bootstrap.contains("__ustcIOSDocumentGuardV1"), "guard-name")
      try check(bootstrap.contains("popstate") && bootstrap.contains("hashchange") &&
        bootstrap.contains("pagehide"), "guard-revision-events")
      try check(bootstrap.contains("crypto.getRandomValues"), "guard-random-nonce")
      try check(IOSSchoolScripts.readGuard.contains("JSON.stringify(value)"), "guard-read-json")
    }

    try test {
      for path in ["/login", "/login/", "/cas/login", "/ucas-sso/login?ticket=synthetic"] {
        try check(jw.isAuthenticationPage(URL(string: jw.businessOrigin + path)!), "jw-auth-route")
      }
      for path in ["/home", "/for-std/course-table", "/for-std/exam-arrange"] {
        try check(!jw.isAuthenticationPage(URL(string: jw.businessOrigin + path)!), "jw-business-route")
      }
      let outside = URL(string: "https://outside.invalid/cas/login")!
      try check(jw.isAuthenticationPage(outside) && !jw.allows(outside), "classification-never-admits-origin")
      let youngCalendar = try young.target(page: "calendar")
      try check(!young.isAuthenticationPage(youngCalendar), "young-business-route")
    }

    try test {
      try check(jwInstall.contains("jw_probe.js") == false, "jw-source-inlined")
      try check(jwInstall.contains("Reflect.apply(factory, root"), "jw-factory-this")
      try check(jwInstall.contains("const factory = (function("), "jw-factory-is-expression")
      try check(!jwInstall.contains("const factory = \"(function"), "jw-factory-is-not-string")
      try check(jwInstall.contains("__ustcJwProbeV1"), "jw-fixed-probe")
      try check(jwInstall.contains("const selfRouteId = match ? match[1] : null;"), "jw-self-route")
      try check(jwInstall.contains("nativeGeneration === holder.document"), "jw-document-association")
      try check(!jwInstall.contains("nativeGeneration === holder.document && nativeGeneration === generation"),
        "jw-rebindable-generation")
      try check(jwInstall.contains("if (generationChanged && this.activeOperation !== null)"),
        "jw-only-cancel-on-new-generation")
    }

    try test {
      let call = try jwScripts.call([
        "method": "probe", "document": 7, "action": "start", "operation": 11,
        "selfRouteId": NSNull(),
      ])
      try check(call.contains("\"action\":\"start\""), "jw-start-request")
      try check(call.contains("replyCapability"), "jw-closed-envelope")
    }

    try test {
      _ = try jwScripts.call([
        "method": "probe", "document": 7, "action": "data", "operation": 12,
        "semesterId": 3, "selfRouteId": "123456",
      ])
      _ = try jwScripts.call([
        "method": "probe", "document": 7, "action": "collect", "operation": 13,
        "semesterId": 3,
      ])
      _ = try jwScripts.call([
        "method": "probe", "document": 7, "action": "poll", "operation": 13,
      ])
      _ = try jwScripts.call([
        "method": "probe", "document": 7, "action": "cancel", "operation": 13,
      ])
    }

    try test {
      try rejects("jw-wrong-document", .staleResult) {
        _ = try jwScripts.call([
          "method": "probe", "document": 8, "action": "start", "operation": 21,
        ])
      }
      try rejects("jw-credential-field", .invalidSnapshot) {
        _ = try jwScripts.call([
          "method": "probe", "document": 7, "action": "start", "operation": 21,
          "credentialBytes": "synthetic-forbidden",
        ])
      }
      try rejects("jw-arbitrary-script", .invalidSnapshot) {
        _ = try jwScripts.call([
          "method": "evaluateJavaScript", "document": 7, "script": "location.href='x'",
        ])
      }
      try rejects("jw-unknown-action", .invalidSnapshot) {
        _ = try jwScripts.call([
          "method": "probe", "document": 7, "action": "click", "operation": 21,
        ])
      }
      try rejects("jw-invalid-semester", .invalidSnapshot) {
        _ = try jwScripts.call([
          "method": "probe", "document": 7, "action": "data", "operation": 21,
          "semesterId": 0,
        ])
      }
      try rejects("jw-self-route-quote", .invalidSnapshot) {
        _ = try jwScripts.call([
          "method": "probe", "document": 7, "action": "data", "operation": 21,
          "semesterId": 2, "selfRouteId": "123' ; alert(1)",
        ])
      }
    }

    try test {
      try check(youngInstall.contains("Reflect.apply(factory, root"), "young-factory-context")
      try check(youngInstall.contains("const factory = (function("), "young-factory-is-expression")
      try check(!youngInstall.contains("const factory = \"(function"), "young-factory-is-not-string")
      try check(!youngInstall.contains("__ustcIOSDocumentGuardV1"), "young-page-does-not-read-isolated-guard")
      try check(youngInstall.contains("this.api.finish(this.activeOperation)"), "young-rebind-finishes-active")
      try check(youngInstall.contains("if (generationChanged && this.activeOperation !== null)"),
        "young-only-finish-on-new-generation")
      try check(youngInstall.contains("documentObject: doc") && youngInstall.contains("href: href"),
        "young-local-document-binding")
    }

    try test {
      for method in ["navigationReady", "start"] {
        var args: [String: Any] = ["method": method, "document": 4]
        if method == "start" { args["operation"] = 31 }
        _ = try youngScripts.call(args)
      }
      _ = try youngScripts.call(["method": "prepare", "document": 4, "page": "activities"])
      _ = try youngScripts.call([
        "method": "dispatch", "document": 4, "operation": 31, "step": 1,
        "endpoint": "activities", "page": 1,
      ])
      let scheduleCall = try youngScripts.call([
        "method": "dispatch", "document": 4, "operation": 31, "step": 2,
        "endpoint": "schedule", "page": 1, "day": "2024-02-29",
      ])
      try check(scheduleCall.contains("\"day\":\"2024-02-29\""), "young-day-json-quoting")
      _ = try youngScripts.call([
        "method": "poll", "document": 4, "operation": 31, "step": 2,
      ])
      _ = try youngScripts.call(["method": "finish", "document": 4, "operation": 31])
    }

    try test {
      try rejects("young-credential-field", .invalidSnapshot) {
        _ = try youngScripts.call([
          "method": "prepare", "document": 4, "page": "calendar",
          "password": "synthetic-forbidden",
        ])
      }
      try rejects("young-arbitrary-url", .invalidSnapshot) {
        _ = try youngScripts.call([
          "method": "dispatch", "document": 4, "operation": 31, "step": 1,
          "endpoint": "https://attacker.invalid/", "page": 1,
        ])
      }
      try rejects("young-day-injection", .invalidSnapshot) {
        _ = try youngScripts.call([
          "method": "dispatch", "document": 4, "operation": 31, "step": 1,
          "endpoint": "schedule", "page": 1, "day": "2024-02-29&x=1",
        ])
      }
      try rejects("young-invalid-calendar-day", .invalidSnapshot) {
        _ = try youngScripts.call([
          "method": "dispatch", "document": 4, "operation": 31, "step": 1,
          "endpoint": "schedule", "page": 1, "day": "2023-02-29",
        ])
      }
      try rejects("young-page-injection", .invalidSnapshot) {
        _ = try youngScripts.call([
          "method": "prepare", "document": 4, "page": "calendar');alert(1)//",
        ])
      }
      try rejects("young-wrong-document", .staleResult) {
        _ = try youngScripts.call(["method": "navigationReady", "document": 5])
      }
    }

    try test {
      try rejects("jw-decode-unmarked", .invalidSnapshot) {
        _ = try jwScripts.decode("{\"value\":{}}")
      }
      let pending = try jwScripts.decode(
        "{\"replyCapability\":\"\(jwMarker)\",\"value\":[false,\"\(jwMarker)\",{}]}"
      )
      let pendingPayload = try jwScripts.jwPayload(pending)
      try check(pendingPayload == "{}", "jw-pending-tuple")
      let youngValue = try youngScripts.decode(
        "{\"replyCapability\":\"\(youngMarker)\",\"value\":{\"complete\":false}}"
      )
      try check((youngValue["value"] as? [String: Any])?["complete"] as? Bool == false,
        "young-closed-value-envelope")
      let closedError = try youngScripts.decode(
        "{\"replyCapability\":\"\(youngMarker)\",\"error\":{\"code\":\"sourceFailed\",\"reason\":\"helperUnavailable\"}}"
      )
      try check((closedError["error"] as? [String: String])?["reason"] == "helperUnavailable",
        "young-closed-error-envelope")
      try rejects("young-decode-non-dictionary", .invalidSnapshot) {
        _ = try youngScripts.decode("[]")
      }
      try rejects("young-decode-extra-field", .invalidSnapshot) {
        _ = try youngScripts.decode(
          "{\"replyCapability\":\"\(youngMarker)\",\"value\":null,\"extra\":true}"
        )
      }
      try rejects("jw-decode-over-limit", .invalidSnapshot) {
        _ = try jwScripts.decode(String(repeating: "x", count: 2 * 1024 * 1024 + 1))
      }
      try rejects("jw-payload-not-a-tuple", .invalidSnapshot) {
        _ = try jwScripts.jwPayload(["value": [:]])
      }
    }

    try test {
      let production = try IOSSchoolPolicy(arguments: [
        "source": "jw",
        "initialUrl": "https://jw.ustc.edu.cn/",
        "allowedOrigins": [
          "https://jw.ustc.edu.cn", "https://passport.ustc.edu.cn",
          "https://id.ustc.edu.cn", "https://analytics.ustc.edu.cn",
        ],
        "testMode": false,
      ], allowFixtures: false)
      try rejects("production-resource-override", .unsupportedPlatform) {
        _ = try IOSSchoolScripts(policy: production, resourceDirectory: resources)
      }
    }

    print("ios-i2-script-tests: \(count) passed")
  }

  private static func fixturePolicy(_ source: String) throws -> IOSSchoolPolicy {
    let initialURL = "http://127.0.0.1:49152/"
    return try IOSSchoolPolicy(arguments: [
      "source": source,
      "initialUrl": initialURL,
      "allowedOrigins": ["http://127.0.0.1:49152"],
      "testMode": true,
    ], allowFixtures: true)
  }

  private static func replyMarker(in script: String) throws -> String {
    let prefix = "const replyCapability = \""
    guard let start = script.range(of: prefix),
          let end = script[start.upperBound...].range(of: "\"") else {
      throw ScriptTestFailure.assertion("reply-marker-not-generated")
    }
    let marker = String(script[start.upperBound..<end.lowerBound])
    guard marker.count == 48, marker.allSatisfy({ $0.isHexDigit }) else {
      throw ScriptTestFailure.assertion("reply-marker-shape")
    }
    return marker
  }
}
