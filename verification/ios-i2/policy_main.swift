import Foundation
import Darwin

private enum PolicyTestFailure: Error {
  case assertion(String)
}

private func check(_ condition: Bool, _ name: String) throws {
  if !condition { throw PolicyTestFailure.assertion(name) }
}

private func rejects(_ name: String, _ action: () throws -> Void) throws {
  do {
    try action()
  } catch is IOSSchoolFailure {
    return
  }
  throw PolicyTestFailure.assertion(name)
}

private func makeURL(_ value: String) throws -> URL {
  guard let url = URL(string: value) else {
    throw PolicyTestFailure.assertion("invalid-test-url-\(value)")
  }
  return url
}

@main
private enum IOSSchoolPolicyTests {
  static func main() throws {
    setbuf(stdout, nil)
    var count = 0
    func test(_ body: () throws -> Void) throws {
      try body()
      count += 1
    }

    try test { try productionOriginsStayExact() }
    try test { try productionTopNavigationBounds() }
    try test { try productionSubframeBounds() }
    try test { try fixtureNavigationUsesOnlyDeclaredOrigins() }
    try test { try fixtureNavigationFieldIsStrictAndDebugOnly() }
    try test { try fixtureNavigationDefaultsToOriginalOrigins() }
    print("ios-i2-policy-tests: \(count) passed")
  }

  private static func productionOriginsStayExact() throws {
    let jwOrigins = [
      "https://jw.ustc.edu.cn",
      "https://passport.ustc.edu.cn",
      "https://id.ustc.edu.cn",
      "https://analytics.ustc.edu.cn",
    ]
    let jw = try IOSSchoolPolicy(arguments: [
      "source": "jw",
      "initialUrl": "https://jw.ustc.edu.cn/",
      "allowedOrigins": jwOrigins,
      "testMode": false,
    ], allowFixtures: false)
    try check(jw.origins == Set(jwOrigins), "jw-exact-origin-set")
    try check(jw.allows(try makeURL("https://id.ustc.edu.cn/cas/login")), "jw-known-origin")
    try check(!jw.allows(try makeURL("https://login.ustc.edu.cn/cas")), "jw-campus-not-business-origin")
    try check(!jw.allows(try makeURL("https://user@jw.ustc.edu.cn/")), "jw-userinfo-denied")
    try check(jw.allowsNavigation(try makeURL("https://login.ustc.edu.cn/cas")), "jw-manual-campus-navigation")

    let youngOrigins = [
      "https://young.ustc.edu.cn",
      "https://passport.ustc.edu.cn",
      "https://ucas.ustc.edu.cn",
      "https://id.ustc.edu.cn",
      "https://analytics.ustc.edu.cn",
    ]
    let young = try IOSSchoolPolicy(arguments: [
      "source": "young",
      "initialUrl": "https://young.ustc.edu.cn/login/",
      "allowedOrigins": youngOrigins,
      "testMode": false,
    ], allowFixtures: false)
    try check(young.origins == Set(youngOrigins), "young-exact-origin-set")
    try check(young.allows(try makeURL("https://young.ustc.edu.cn/login/")), "young-known-origin")
    try check(!young.allows(try makeURL("https://sso.ustc.edu.cn/cas")), "young-campus-not-business-origin")
    try check(young.allowsNavigation(try makeURL("https://sso.ustc.edu.cn/cas")), "young-manual-campus-navigation")

    try rejects("jw-production-origin-expansion-rejected") {
      _ = try IOSSchoolPolicy(arguments: [
        "source": "jw",
        "initialUrl": "https://jw.ustc.edu.cn/",
        "allowedOrigins": jwOrigins + ["https://login.ustc.edu.cn"],
        "testMode": false,
      ], allowFixtures: false)
    }
    try rejects("young-production-origin-expansion-rejected") {
      _ = try IOSSchoolPolicy(arguments: [
        "source": "young",
        "initialUrl": "https://young.ustc.edu.cn/login/",
        "allowedOrigins": youngOrigins + ["https://sso.ustc.edu.cn"],
        "testMode": false,
      ], allowFixtures: false)
    }
  }

  private static func productionTopNavigationBounds() throws {
    let policy = try productionPolicy("jw")
    for allowed in [
      "https://ustc.edu.cn/",
      "HTTPS://WWW.USTC.EDU.CN/login",
      "https://passport.ustc.edu.cn/cas/login?service=x",
      "https://ustc.edu.cn:443/path",
      "https://xn--9ca.ustc.edu.cn/login",
    ] {
      try check(policy.allowsNavigation(try makeURL(allowed)), "top-campus-\(allowed)")
    }
    for denied in [
      "http://passport.ustc.edu.cn/login",
      "https://passport.ustc.edu.cn:444/login",
      "https://user@passport.ustc.edu.cn/login",
      "https://passport.ustc.edu.cn./login",
      "https://bad..ustc.edu.cn/login",
      "https://-bad.ustc.edu.cn/login",
      "https://bad-.ustc.edu.cn/login",
      "https://bad_name.ustc.edu.cn/login",
      "https://ustc.edu.cn.evil.example/login",
      "https://evilustc.edu.cn/login",
      "https://bad%2Eustc.edu.cn/login",
    ] {
      if let candidate = URL(string: denied) {
        try check(!policy.allowsNavigation(candidate), "top-denied-\(denied)")
      }
    }
    try check(!policy.allowsNavigation(try makeURL("about:blank")), "top-about-blank-denied")
  }

  private static func productionSubframeBounds() throws {
    let policy = try productionPolicy("jw")
    let external = try makeURL("https://login.example.net/cas/frame")
    try check(policy.allowsSubframeNavigation(external), "subframe-external-https")
    if #available(macOS 13.0, *) {
      try check(policy.allowsSubframeNavigation(try makeURL("https://xn--9ca.example.net/frame")), "subframe-idna-host")
    }
    try check(policy.allowsSubframeNavigation(try makeURL("https://192.0.2.1/frame")), "subframe-canonical-ipv4")
    try check(!policy.allowsNavigation(external), "subframe-external-not-top-navigation")
    try check(policy.allowsSubframeNavigation(try makeURL("about:blank")), "subframe-exact-about-blank")
    try check(policy.allowsSubframeNavigation(try makeURL("about:srcdoc")), "subframe-exact-about-srcdoc")
    try check(!policy.allowsNavigation(try makeURL("about:srcdoc")), "about-srcdoc-not-top-navigation")

    for denied in [
      "http://login.example.net/frame",
      "data:text/html,login",
      "file:///tmp/login.html",
      "about:blank#fragment",
      "about:srcdoc?query=x",
      "https://frame..example.net/",
      "https://-frame.example.net/",
      "https://frame_.example.net/",
      "https://frame.example.net./",
      "https://user:secret@frame.example.net/",
      "https://frame.example.net:444/",
      "https://frame.example.net:/",
    ] {
      if let candidate = URL(string: denied) {
        try check(!policy.allowsSubframeNavigation(candidate), "subframe-denied-\(denied)")
      }
    }
  }

  private static func fixtureNavigationUsesOnlyDeclaredOrigins() throws {
    let fixture = try IOSSchoolPolicy(arguments: fixtureArguments(
      navigationOrigins: ["HTTPS://127.0.0.1:49154"]
    ), allowFixtures: true)
    let original = try makeURL("http://127.0.0.1:49152/page")
    let extended = try makeURL("https://127.0.0.1:49154/cas/bridge")
    try check(fixture.isFixture, "fixture-marked")
    try check(fixture.allows(original), "fixture-original-origin-still-admitted")
    try check(fixture.allowsNavigation(original), "fixture-original-navigation")
    try check(fixture.allowsNavigation(extended), "fixture-explicit-navigation-extension")
    try check(fixture.allowsSubframeNavigation(extended), "fixture-explicit-subframe-extension")
    try check(!fixture.allows(extended), "fixture-extension-not-business-origin")
    try check(!fixture.allowsNavigation(try makeURL("http://127.0.0.1:49155/page")), "fixture-unregistered-loopback-denied")
    try check(!fixture.allowsSubframeNavigation(try makeURL("https://public.example.net/frame")), "fixture-public-host-denied")
    try check(!fixture.allowsNavigation(try makeURL("https://auth.ustc.edu.cn/login")), "fixture-campus-host-denied")
    try check(!fixture.allowsSubframeNavigation(try makeURL("https://auth.ustc.edu.cn/frame")), "fixture-campus-subframe-denied")
    try check(fixture.allowsSubframeNavigation(try makeURL("about:blank")), "fixture-about-blank")
    try check(fixture.allowsSubframeNavigation(try makeURL("about:srcdoc")), "fixture-about-srcdoc")
    try check(fixture.allowsNavigation(extended.appendingPathComponent("other")), "fixture-appended-path-retains-explicit-origin")
  }

  private static func fixtureNavigationFieldIsStrictAndDebugOnly() throws {
    for bad in [
      "https://127.0.0.1:443",
      "http://127.0.0.1:80",
      "https://127.0.0.1:0",
      "https://127.0.0.1:65536",
      "https://127.0.0.1:49154/",
      "https://127.0.0.1:49154?x=1",
      "https://127.0.0.1:49154#fragment",
      "https://user@127.0.0.1:49154",
      "https://127.0.0.2:49154",
      "https://public.example.net:49154",
    ] {
      var arguments = fixtureArguments(navigationOrigins: [bad])
      arguments["testNavigationOrigins"] = [bad]
      try rejects("fixture-navigation-bad-origin-\(bad)") {
        _ = try IOSSchoolPolicy(arguments: arguments, allowFixtures: true)
      }
    }

    var overlap = fixtureArguments(navigationOrigins: ["http://127.0.0.1:49152"])
    overlap["testNavigationOrigins"] = ["http://127.0.0.1:49152"]
    try rejects("fixture-navigation-overlap-rejected") {
      _ = try IOSSchoolPolicy(arguments: overlap, allowFixtures: true)
    }

    var duplicate = fixtureArguments(navigationOrigins: [
      "https://127.0.0.1:49154", "https://127.0.0.1:49154",
    ])
    duplicate["testNavigationOrigins"] = [
      "https://127.0.0.1:49154", "https://127.0.0.1:49154",
    ]
    try rejects("fixture-navigation-duplicate-rejected") {
      _ = try IOSSchoolPolicy(arguments: duplicate, allowFixtures: true)
    }

    let rejectedLists: [[String]] = [
      [],
      ["https://127.0.0.1:49154", "https://127.0.0.1:49155", "https://127.0.0.1:49156"],
      ["https://127.0.0.1:49154", "https://127.0.0.1:49155", "https://127.0.0.1:49156", "https://127.0.0.1:49157"],
      ["https://127.0.0.1:49154", "https://127.0.0.1:49155", "https://127.0.0.1:49156", "https://127.0.0.1:49157", "https://127.0.0.1:49158"],
    ]
    for badList in rejectedLists {
      var arguments = fixtureArguments()
      arguments["testNavigationOrigins"] = badList
      try rejects("fixture-navigation-size-rejected-\(badList.count)") {
        _ = try IOSSchoolPolicy(arguments: arguments, allowFixtures: true)
      }
    }

    var wrongType = fixtureArguments()
    wrongType["testNavigationOrigins"] = "https://127.0.0.1:49154"
    try rejects("fixture-navigation-wrong-type-rejected") {
      _ = try IOSSchoolPolicy(arguments: wrongType, allowFixtures: true)
    }

    var productionWithField: [String: Any] = [
      "source": "jw",
      "initialUrl": "https://jw.ustc.edu.cn/",
      "allowedOrigins": [
        "https://jw.ustc.edu.cn",
        "https://passport.ustc.edu.cn",
        "https://id.ustc.edu.cn",
        "https://analytics.ustc.edu.cn",
      ],
      "testMode": false,
      "testNavigationOrigins": ["https://127.0.0.1:49154"],
    ]
    try rejects("production-test-navigation-field-rejected") {
      _ = try IOSSchoolPolicy(arguments: productionWithField, allowFixtures: true)
    }
    productionWithField["testNavigationOrigins"] = ["https://127.0.0.1:49154"]
    try rejects("release-test-navigation-field-rejected") {
      _ = try IOSSchoolPolicy(arguments: productionWithField, allowFixtures: false)
    }

    var releaseFixture = fixtureArguments(navigationOrigins: ["https://127.0.0.1:49154"])
    releaseFixture["testNavigationOrigins"] = ["https://127.0.0.1:49154"]
    try rejects("release-fixture-navigation-field-rejected") {
      _ = try IOSSchoolPolicy(arguments: releaseFixture, allowFixtures: false)
    }
  }

  private static func fixtureNavigationDefaultsToOriginalOrigins() throws {
    let fixture = try IOSSchoolPolicy(arguments: fixtureArguments(), allowFixtures: true)
    try check(fixture.allowsNavigation(try makeURL("https://127.0.0.1:49153/page")), "fixture-no-extension-keeps-original-https-origin")
    try check(!fixture.allowsNavigation(try makeURL("https://127.0.0.1:49154/page")), "fixture-no-extension-denies-unregistered-origin")
    try check(!fixture.allowsNavigation(try makeURL("https://public.example.net/page")), "fixture-no-extension-denies-public")
    if let invalidPort = URL(string: "https://127.0.0.1:49153:/page") {
      try check(!fixture.allowsNavigation(invalidPort), "fixture-empty-port-denied")
    }
  }

  private static func productionPolicy(_ source: String) throws -> IOSSchoolPolicy {
    let jwOrigins = [
      "https://jw.ustc.edu.cn",
      "https://passport.ustc.edu.cn",
      "https://id.ustc.edu.cn",
      "https://analytics.ustc.edu.cn",
    ]
    let youngOrigins = [
      "https://young.ustc.edu.cn",
      "https://passport.ustc.edu.cn",
      "https://ucas.ustc.edu.cn",
      "https://id.ustc.edu.cn",
      "https://analytics.ustc.edu.cn",
    ]
    return try IOSSchoolPolicy(arguments: [
      "source": source,
      "initialUrl": source == "jw" ? "https://jw.ustc.edu.cn/" : "https://young.ustc.edu.cn/login/",
      "allowedOrigins": source == "jw" ? jwOrigins : youngOrigins,
      "testMode": false,
    ], allowFixtures: false)
  }

  private static func fixtureArguments(navigationOrigins: [String]? = nil) -> [String: Any] {
    var arguments: [String: Any] = [
      "source": "jw",
      "initialUrl": "http://127.0.0.1:49152/index.html",
      "allowedOrigins": ["http://127.0.0.1:49152", "https://127.0.0.1:49153"],
      "testMode": true,
    ]
    if let navigationOrigins {
      arguments["testNavigationOrigins"] = navigationOrigins
    }
    return arguments
  }
}
