import Foundation

enum IOSSchoolFailure: String, Error {
  case invalidSnapshot
  case unsafeDirectory
  case storageFailed
  case cleanupPending
  case staleResult
  case busy
  case closed
  case sourceFailed
  case unsupportedPlatform
  case ownershipLost
}

/// Fixed iOS school destinations. This describes navigations the host may
/// admit; it is not an allowlist for ordinary page subresources or background
/// network requests.
struct IOSSchoolPolicy {
  let source: String
  let initialURL: URL
  let origins: Set<String>
  let isFixture: Bool
  let businessOrigin: String

  private static let jwInitial = "https://jw.ustc.edu.cn/"
  private static let youngInitial = "https://young.ustc.edu.cn/login/"
  private static let jwOrigins = [
    "https://jw.ustc.edu.cn",
    "https://passport.ustc.edu.cn",
    "https://id.ustc.edu.cn",
    "https://analytics.ustc.edu.cn",
  ]
  private static let youngOrigins = [
    "https://young.ustc.edu.cn",
    "https://passport.ustc.edu.cn",
    "https://ucas.ustc.edu.cn",
    "https://id.ustc.edu.cn",
    "https://analytics.ustc.edu.cn",
  ]

  init(arguments: [String: Any], allowFixtures: Bool) throws {
    guard let source = arguments["source"] as? String,
          source == "jw" || source == "young",
          let initialText = arguments["initialUrl"] as? String,
          let initialURL = URL(string: initialText),
          initialURL.baseURL == nil,
          let rawOrigins = arguments["allowedOrigins"] as? [String],
          let testMode = arguments["testMode"] as? Bool else {
      throw IOSSchoolFailure.invalidSnapshot
    }

    if testMode {
      guard allowFixtures else { throw IOSSchoolFailure.unsupportedPlatform }
      let initialOrigin = try Self.fixtureOrigin(of: initialURL)
      guard initialURL.user == nil,
            initialURL.password == nil,
            initialURL.query == nil,
            initialURL.fragment == nil,
            rawOrigins.count <= 4,
            !rawOrigins.isEmpty else {
        throw IOSSchoolFailure.invalidSnapshot
      }

      var parsedOrigins = Set<String>()
      for rawOrigin in rawOrigins {
        let normalized = try Self.fixtureOriginString(rawOrigin)
        guard parsedOrigins.insert(normalized).inserted else {
          throw IOSSchoolFailure.invalidSnapshot
        }
      }
      guard parsedOrigins.contains(initialOrigin) else {
        throw IOSSchoolFailure.invalidSnapshot
      }

      self.source = source
      self.initialURL = initialURL
      self.origins = parsedOrigins
      self.isFixture = true
      self.businessOrigin = initialOrigin
      return
    }

    let expectedURL = source == "jw" ? Self.jwInitial : Self.youngInitial
    let expectedOrigins = source == "jw" ? Self.jwOrigins : Self.youngOrigins
    guard initialText == expectedURL,
          rawOrigins == expectedOrigins,
          let canonicalInitial = URL(string: expectedURL) else {
      throw IOSSchoolFailure.invalidSnapshot
    }
    self.source = source
    self.initialURL = canonicalInitial
    self.origins = Set(expectedOrigins)
    self.isFixture = false
    self.businessOrigin = source == "jw"
      ? "https://jw.ustc.edu.cn"
      : "https://young.ustc.edu.cn"
  }

  /// Returns a normalized HTTP(S) origin, excluding URL credentials.
  func origin(_ url: URL) -> String? {
    guard url.user == nil, url.password == nil,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let schemeText = components.scheme,
          let hostText = components.host,
          !hostText.isEmpty else {
      return nil
    }
    let scheme = schemeText.lowercased()
    guard scheme == "http" || scheme == "https" else { return nil }
    if let port = components.port, !(1...65535).contains(port) { return nil }

    let host = hostText.lowercased()
    let formattedHost = host.contains(":") && !host.hasPrefix("[")
      ? "[\(host)]" : host
    let defaultPort = scheme == "https" ? 443 : 80
    let portPart = components.port.flatMap { $0 == defaultPort ? nil : $0 }
      .map { ":\($0)" } ?? ""
    return "\(scheme)://\(formattedHost)\(portPart)"
  }

  func allows(_ url: URL) -> Bool {
    guard let candidate = origin(url) else { return false }
    return origins.contains(candidate)
  }

  func target(page: String) throws -> URL {
    let path: String
    switch (source, page) {
    case ("jw", "courseTable"):
      path = "/for-std/course-table"
    case ("jw", "examArrange"):
      path = "/for-std/exam-arrange"
    case ("young", "activities"):
      path = "/login/sc-wisdom-group-learning/myproject/SignUp"
    case ("young", "calendar"):
      path = "/login/sc-wisdom-group-learning/personalInformation/mySchedule"
    default:
      throw IOSSchoolFailure.invalidSnapshot
    }
    guard let url = URL(string: businessOrigin + path), allows(url) else {
      throw IOSSchoolFailure.invalidSnapshot
    }
    return url
  }

  private static func fixtureOrigin(of url: URL) throws -> String {
    guard url.user == nil,
          url.password == nil,
          url.query == nil,
          url.fragment == nil,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.host == "127.0.0.1",
          let port = components.port,
          (1...65535).contains(port) else {
      throw IOSSchoolFailure.invalidSnapshot
    }
    guard let schemeText = components.scheme else {
      throw IOSSchoolFailure.invalidSnapshot
    }
    let scheme = schemeText.lowercased()
    guard scheme == "http" || scheme == "https" else {
      throw IOSSchoolFailure.invalidSnapshot
    }
    let defaultPort = scheme == "https" ? 443 : 80
    let portPart = port == defaultPort ? "" : ":\(port)"
    return "\(scheme)://127.0.0.1\(portPart)"
  }

  private static func fixtureOriginString(_ raw: String) throws -> String {
    guard let components = URLComponents(string: raw),
          components.path.isEmpty,
          components.query == nil,
          components.fragment == nil,
          components.user == nil,
          components.password == nil,
          components.host == "127.0.0.1",
          let port = components.port,
          (1...65535).contains(port),
          let schemeText = components.scheme else {
      throw IOSSchoolFailure.invalidSnapshot
    }
    let scheme = schemeText.lowercased()
    guard scheme == "http" || scheme == "https" else {
      throw IOSSchoolFailure.invalidSnapshot
    }
    let defaultPort = scheme == "https" ? 443 : 80
    let portPart = port == defaultPort ? "" : ":\(port)"
    return "\(scheme)://127.0.0.1\(portPart)"
  }
}
