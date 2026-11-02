import Foundation
import Darwin

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
  private let navigationOrigins: Set<String>

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

    let hasTestNavigationOrigins = arguments.keys.contains("testNavigationOrigins")
    if hasTestNavigationOrigins && (!testMode || !allowFixtures) {
      throw testMode ? IOSSchoolFailure.unsupportedPlatform : IOSSchoolFailure.invalidSnapshot
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

      var parsedNavigationOrigins = parsedOrigins
      if hasTestNavigationOrigins {
        guard let rawNavigationOrigins = arguments["testNavigationOrigins"] as? [String],
              !rawNavigationOrigins.isEmpty,
              rawNavigationOrigins.count <= 4 else {
          throw IOSSchoolFailure.invalidSnapshot
        }
        var additionalOrigins = Set<String>()
        for rawOrigin in rawNavigationOrigins {
          let normalized = try Self.fixtureNavigationOriginString(rawOrigin)
          guard !parsedOrigins.contains(normalized),
                additionalOrigins.insert(normalized).inserted else {
            throw IOSSchoolFailure.invalidSnapshot
          }
        }
        guard parsedOrigins.count + additionalOrigins.count <= 4 else {
          throw IOSSchoolFailure.invalidSnapshot
        }
        parsedNavigationOrigins.formUnion(additionalOrigins)
      }

      self.source = source
      self.initialURL = initialURL
      self.origins = parsedOrigins
      self.isFixture = true
      self.businessOrigin = initialOrigin
      self.navigationOrigins = parsedNavigationOrigins
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
    self.navigationOrigins = Set(expectedOrigins)
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

  /// Allows a user-driven top-level browser destination. This is intentionally
  /// separate from `allows`, which remains the exact source/data-origin check.
  func allowsNavigation(_ url: URL) -> Bool {
    if isFixture {
      guard let candidate = Self.fixtureNavigationOrigin(of: url) else { return false }
      return navigationOrigins.contains(candidate)
    }
    guard let host = Self.canonicalHTTPSHost(of: url) else { return false }
    return host == "ustc.edu.cn" || host.hasSuffix(".ustc.edu.cn")
  }

  /// Allows ordinary HTTPS subframes without granting them business-read
  /// authority. Only the exact about:blank/srcdoc documents bypass HTTPS.
  func allowsSubframeNavigation(_ url: URL) -> Bool {
    if Self.isExactAboutDocument(url) { return true }
    if isFixture {
      guard let candidate = Self.fixtureNavigationOrigin(of: url) else { return false }
      return navigationOrigins.contains(candidate)
    }
    return Self.canonicalHTTPSHost(of: url) != nil
  }

  /// Readiness for fixed business operations must not interrupt a login
  /// callback document before its own redirect has completed.
  func isAuthenticationPage(_ url: URL) -> Bool {
    guard origin(url) == businessOrigin else { return true }
    let path = url.path
    return path == "/login" || path == "/login/" || path.hasPrefix("/cas/") ||
      (source == "jw" && path.hasPrefix("/ucas-sso/"))
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

  private static func fixtureNavigationOriginString(_ raw: String) throws -> String {
    let normalized = try fixtureOriginString(raw)
    guard let components = URLComponents(string: raw),
          let scheme = components.scheme?.lowercased(),
          let port = components.port,
          port != (scheme == "https" ? 443 : 80) else {
      throw IOSSchoolFailure.invalidSnapshot
    }
    return normalized
  }

  private static func fixtureNavigationOrigin(of url: URL) -> String? {
    guard url.baseURL == nil,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let schemeText = components.scheme,
          let host = components.host,
          host == "127.0.0.1",
          components.percentEncodedHost == host,
          components.user == nil,
          components.password == nil,
          let port = components.port,
          (1...65535).contains(port),
          !hasEmptyExplicitPort(url) else {
      return nil
    }
    let scheme = schemeText.lowercased()
    guard scheme == "http" || scheme == "https" else { return nil }
    let defaultPort = scheme == "https" ? 443 : 80
    let portPart = port == defaultPort ? "" : ":\(port)"
    return "\(scheme)://127.0.0.1\(portPart)"
  }

  private static func canonicalHTTPSHost(of url: URL) -> String? {
    guard url.baseURL == nil,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.scheme?.lowercased() == "https",
          components.user == nil,
          components.password == nil,
          components.port == nil || components.port == 443,
          let host = encodedHTTPSHost(components),
          !host.isEmpty,
          !host.contains("%"),
          !hasEmptyExplicitPort(url),
          host.utf8.count <= 253,
          host.unicodeScalars.allSatisfy({ $0.value < 128 }) else {
      return nil
    }

    let normalized = host.lowercased()
    if normalized.hasPrefix("[") || normalized.hasSuffix("]") {
      guard normalized.hasPrefix("["), normalized.hasSuffix("]"),
            normalized.count > 2 else {
        return nil
      }
      let address = String(normalized.dropFirst().dropLast())
      var parsedAddress = in6_addr()
      guard address.withCString({ inet_pton(AF_INET6, $0, &parsedAddress) }) == 1 else {
        return nil
      }
      return normalized
    }

    if normalized.allSatisfy({ $0.isNumber || $0 == "." }) {
      guard isCanonicalIPv4(normalized) else { return nil }
      return normalized
    }

    guard !normalized.hasPrefix("."), !normalized.hasSuffix(".") else { return nil }
    let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
    guard !labels.isEmpty else { return nil }
    for label in labels {
      guard !label.isEmpty, label.utf8.count <= 63,
            let first = label.utf8.first,
            let last = label.utf8.last,
            isASCIILetterOrDigit(first), isASCIILetterOrDigit(last),
            label.utf8.allSatisfy({ isASCIILetterOrDigit($0) || $0 == 45 }) else {
        return nil
      }
    }
    return normalized
  }

  private static func encodedHTTPSHost(_ components: URLComponents) -> String? {
    // Modern Foundation decodes IDNA in `host` and percent-encodes the decoded
    // value in `percentEncodedHost`. Use the actual ASCII DNS representation.
    if #available(iOS 16.0, macOS 13.0, *) {
      return components.encodedHost
    }
    // The older fallback admits ordinary ASCII hosts; non-ASCII/percent-encoded
    // hosts are rejected by the caller rather than guessed or re-encoded.
    return components.percentEncodedHost
  }

  private static func isCanonicalIPv4(_ host: String) -> Bool {
    let octets = host.split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4 else { return false }
    for octet in octets {
      guard !octet.isEmpty,
            octet.count == 1 || octet.first != "0",
            let value = Int(octet),
            (0...255).contains(value) else {
        return false
      }
    }
    return true
  }

  private static func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
    (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
  }

  private static func isExactAboutDocument(_ url: URL) -> Bool {
    url.baseURL == nil &&
      (url.absoluteString == "about:blank" || url.absoluteString == "about:srcdoc")
  }

  private static func hasEmptyExplicitPort(_ url: URL) -> Bool {
    guard let schemeEnd = url.absoluteString.range(of: "://") else { return false }
    let remainder = url.absoluteString[schemeEnd.upperBound...]
    let authorityEnd = remainder.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" })
      ?? remainder.endIndex
    let authority = remainder[..<authorityEnd]
    let hostPort = authority.split(separator: "@", omittingEmptySubsequences: false).last ?? ""
    return hostPort.hasSuffix(":")
  }
}
