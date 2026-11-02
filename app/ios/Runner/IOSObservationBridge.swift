import Flutter
import UIKit
import WebKit
import CoreFoundation

/// Fixed school operations. WebKit credentials and response bodies have no
/// native export API. A native session owns one view and one registered store.
@available(iOS 27.0, *)
@MainActor final class IOSObservationBridge: NSObject, WKNavigationDelegate, WKUIDelegate {
  private static weak var slot: IOSObservationBridge?
  private let channel: FlutterMethodChannel
  private let presenter: () -> UIViewController?
  private var active: Session?
  private var closing: Session?
  private var closedID: Int?
  private var closeFailure: IOSSchoolFailure?
  private var pending: [UUID: Pending] = [:]
  private var observers: [NSObjectProtocol] = []
  private var retired = false
  // Closed, value-free diagnostics. Never retain NSError/userInfo, URLs,
  // requests, page text, account values or WebKit authentication assets.
  private var diagnosticSource = "none", diagnosticEvent = "none"
  private var failureStage = "none", failureDomain = "none"
  private var failureCode: Int?
  private var cleanupStage = "none", cleanupReason = "none", cleanupDomain = "none"
  private var cleanupCode: Int?
  private var policyAction = "none", policyTarget = "none"
#if DEBUG
  // Test correlation only, never a partition/open authority. Retain the
  // verified UUID so removal can still be measured after Dart removes metadata.
  private var fixtureStoreIDs: [String: UUID] = [:]
#endif

  private final class Session {
    let id: Int, policy: IOSSchoolPolicy, ledger: IOSSchoolStoreLedger
    let record: IOSSchoolStoreRecord?, scripts: IOSSchoolScripts
    let recovery: Bool
    var view: WKWebView?
    weak var releasedView: WKWebView?
    var host: SchoolHostController?
    var navigation: UINavigationController?
    var urlObserver: NSKeyValueObservation?
    var activeLoad: WKNavigation?
    var document = 0
    var ready = false, finished = false, isClosing = false
    var storeRemoved = false
    var manualLoadFailed = false
    var displayedHost: String?
    var dialog: SchoolDialog?
    var isHiding = false
    var hideCompletions: [() -> Void] = []
    var uiCloseAttempt = 0
#if DEBUG
    var fixtureRetiredLoad: WKNavigation?
    var fixtureDialogTrace: [String] = []
    var fixtureCancelDuringPresentation = false
#endif
    var guardValue: String?, lastURL: URL?
    init(id: Int, policy: IOSSchoolPolicy, ledger: IOSSchoolStoreLedger,
         record: IOSSchoolStoreRecord?, scripts: IOSSchoolScripts, recovery: Bool) {
      self.id = id; self.policy = policy; self.ledger = ledger
      self.record = record; self.scripts = scripts; self.recovery = recovery
    }
  }

  private final class SchoolDialog {
    let alert: UIAlertController
    let kind: String
    var presented = false, dismissing = false
    var requestedAcceptance: Bool?
    var afterDismiss: [() -> Void] = []
    private var reply: ((Bool) -> Void)?
    init(alert: UIAlertController, kind: String, reply: @escaping (Bool) -> Void) {
      self.alert = alert; self.kind = kind; self.reply = reply
    }
    func finish(_ accepted: Bool) {
      let completion = reply; reply = nil; completion?(accepted)
    }
  }

  private final class Pending {
    let reply: FlutterResult
    var timer: DispatchWorkItem?
    init(_ reply: @escaping FlutterResult) { self.reply = reply }
  }

  init(messenger: FlutterBinaryMessenger, presenter: @escaping () -> UIViewController?) {
    self.channel = FlutterMethodChannel(name: "ustc_assistant/observation_v1", binaryMessenger: messenger)
    self.presenter = presenter
    super.init()
    channel.setMethodCallHandler { [weak self] call, reply in
      guard let self else { reply(Self.error(.closed)); return }
      self.handle(call, reply)
    }
    observers.append(NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self, let session = self.active else { return }
      self.recordFailure("background", event: "background")
      self.event(session, "failed")
      self.beginClose(session)
    })
  }

  func shutdown() {
    retired = true
    channel.setMethodCallHandler(nil)
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
    if let session = active { beginClose(session) }
  }

  private static func error(_ code: IOSSchoolFailure) -> FlutterError {
    FlutterError(code: "app_failure", message: nil, details: code.rawValue)
  }
  func diagnostics() -> [String: Any] {
    let state = closeFailure != nil ? "cleanupPending" : closing != nil ? "closing"
      : active != nil ? "open" : closedID != nil ? "closed" : "idle"
    return [
      "kind": "ios-i2-browser-diagnostics-v2", "source": diagnosticSource, "state": state,
      "lastEvent": diagnosticEvent, "failureStage": failureStage, "errorDomain": failureDomain,
      "errorCode": failureCode.map { $0 as Any } ?? NSNull(), "cleanupStage": cleanupStage,
      "cleanupFailure": cleanupReason, "cleanupErrorDomain": cleanupDomain,
      "cleanupErrorCode": cleanupCode.map { $0 as Any } ?? NSNull(),
      "policyAction": policyAction, "policyTarget": policyTarget
    ]
  }
  private static func safeError(_ error: Error?) -> (String, Int?) {
    guard let error else { return ("none", nil) }
    if let error = error as? IOSSchoolFailure {
      let code: Int
      switch error {
      case .invalidSnapshot: code = 1
      case .unsafeDirectory: code = 2
      case .storageFailed: code = 3
      case .cleanupPending: code = 4
      case .staleResult: code = 5
      case .busy: code = 6
      case .closed: code = 7
      case .sourceFailed: code = 8
      case .unsupportedPlatform: code = 9
      case .ownershipLost: code = 10
      }
      return ("app", code)
    }
    let value = error as NSError
    let domain: String
    switch value.domain {
    case NSURLErrorDomain: domain = "urlLoading"
    case "WKErrorDomain", "WebKitErrorDomain": domain = "webKit"
    case NSPOSIXErrorDomain: domain = "posix"
    default: domain = "other"
    }
    return (domain, (-100000...100000).contains(value.code) ? value.code : nil)
  }
  private func recordFailure(_ stage: String, event: String, error: Error? = nil) {
    // Preserve the initiating failure when cleanup/automatic recovery follows.
    if failureStage == "none" {
      failureStage = stage
      (failureDomain, failureCode) = Self.safeError(error)
    }
    diagnosticEvent = event
  }
  private func cleanupFailed(_ reason: String, error: Error? = nil, ioCode: Int32? = nil) {
    closeFailure = .cleanupPending; cleanupReason = reason
    if let ioCode, (-100000...100000).contains(Int(ioCode)) {
      cleanupDomain = "posix"; cleanupCode = Int(ioCode)
    } else { (cleanupDomain, cleanupCode) = Self.safeError(error) }
  }
  private static func integer(_ a: [String: Any], _ key: String,
                              minimum: Int = 1, maximum: Int = Int.max) throws -> Int {
    guard let number = a[key] as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
          number.doubleValue >= Double(minimum), number.doubleValue < Double(Int.max),
          number.intValue >= minimum, number.intValue <= maximum else { throw IOSSchoolFailure.invalidSnapshot }
    return number.intValue
  }
  private func fields(_ a: [String: Any], _ allowed: Set<String>, optional: Set<String> = []) throws {
    guard Set(a.keys).isSubset(of: allowed), allowed.subtracting(optional).isSubset(of: Set(a.keys)) else {
      throw IOSSchoolFailure.invalidSnapshot
    }
  }
  private func current(_ a: [String: Any], document: Bool = true) throws -> Session {
    let id = try Self.integer(a, "session")
    guard let s = active, !s.isClosing, s.id == id else {
      throw IOSSchoolFailure.staleResult
    }
    if document {
      let expected = try Self.integer(a, "document", minimum: 0)
      guard s.document == expected else { throw IOSSchoolFailure.staleResult }
    }
    return s
  }
  private func isCurrent(_ s: Session, _ document: Int) -> Bool {
    !retired && active === s && !s.isClosing && s.document == document
  }

  private func handle(_ call: FlutterMethodCall, _ reply: @escaping FlutterResult) {
    do {
      guard !retired else { throw IOSSchoolFailure.closed }
      guard let a = call.arguments as? [String: Any] else { throw IOSSchoolFailure.invalidSnapshot }
      let method = call.method
      if method == "checkSupport" { try fields(a, []); reply(nil); return }
      if method == "open" { try open(a); reply(nil); return }
      if method == "close" || method == "drained" {
        try fields(a, ["session"])
        let id = try Self.integer(a, "session")
        if method == "close", let s = active, s.id == id { beginClose(s) }
        else if method == "close", let s = closing, s.id == id, closeFailure != nil { retryClose(s) }
        else if active?.id != id && closing?.id != id && closedID != id { throw IOSSchoolFailure.staleResult }
        if let failure = closeFailure { throw failure }
        reply(method == "drained" ? (closedID == id && closing == nil) : nil)
        return
      }
#if DEBUG
      if method == "i2StoreExists" { try storeExists(a, reply); return }
#endif
      let s = try current(a, document: method != "navigateInitial")
      if method == "navigateInitial" {
        try fields(a, ["session"]); navigate(s, s.policy.initialURL); reply(nil); return
      }
      if method == "inspect" {
        try fields(a, ["session", "document"])
        reply(["session": s.id, "document": s.document, "ready": s.ready,
               "origin": exportedOrigin(s) as Any? ?? NSNull(),
               "windowVisible": s.navigation?.presentingViewController != nil,
               "windowForeground": UIApplication.shared.applicationState == .active])
        return
      }
      if method == "navigateJwPage" || method == "navigateYoungBusinessPage" {
        try fields(a, ["session", "document", "page"])
        guard s.policy.source == (method == "navigateJwPage" ? "jw" : "young"),
              let page = a["page"] as? String else { throw IOSSchoolFailure.invalidSnapshot }
        // Young's namespace bootstrap, including a ticket, must finish before
        // navigating to a fixed business page. No early landing-page jump.
        if s.policy.source == "young" && (!s.ready || s.view?.url?.query != nil) { throw IOSSchoolFailure.busy }
        navigate(s, try s.policy.target(page: page)); reply(nil); return
      }
      if method == "advanceJwLogin" || method == "advanceYoungLogin" {
        try fields(a, ["session", "document", "operation"])
        _ = try Self.integer(a, "operation")
        guard s.policy.source == (method == "advanceJwLogin" ? "jw" : "young") else { throw IOSSchoolFailure.invalidSnapshot }
        if let url = s.view?.url, !s.policy.allows(url), s.policy.allowsNavigation(url),
            s.finished, s.view?.isLoading == false {
          guard show(s) else { throw IOSSchoolFailure.busy }
          reply("manualRequired"); return
        }
        guard s.ready else {
          if s.manualLoadFailed {
            guard show(s) else { throw IOSSchoolFailure.busy }
            reply("manualRequired")
          } else { reply("waiting") }
          return
        }
        let business = s.view?.url.map { !s.policy.isAuthenticationPage($0) } == true
        let youngReady = s.view?.url?.path.hasPrefix("/login/sc-wisdom-group-learning/") == true
          && s.view?.url?.query == nil
        if business && s.finished &&
            s.view?.isLoading == false && (s.policy.source == "jw" || youngReady) { reply("businessReady") }
        else {
          guard show(s) else { throw IOSSchoolFailure.busy }
          reply("manualRequired")
        }
        return
      }
      if method == "submitJwLogin" || method == "submitYoungLogin" {
        // No decoding, logging, script interpolation or native use of bytes.
        throw IOSSchoolFailure.unsupportedPlatform
      }
#if DEBUG
      if method == "i2Fixture" { try fixture(s, a, reply); return }
      if method == "exerciseFixture" { try exercise(s, a, reply); return }
#endif
      if method == "inspectYoungPage" {
        // The legacy passive-observation DTO is not implemented by I2. Never
        // fabricate zero DOM counts; production sync uses the fixed reader.
        throw IOSSchoolFailure.unsupportedPlatform
      }
      if method == "prepareYoungBusinessPage" {
        try fields(a, ["session", "document", "page"])
        guard s.policy.source == "young", let page = a["page"] as? String else { throw IOSSchoolFailure.invalidSnapshot }
        _ = try s.policy.target(page: page)
        try script(s, ["method": "prepare", "document": s.document, "page": page], reply: reply) { envelope in
          guard let value = envelope["value"] as? Bool else { throw IOSSchoolFailure.invalidSnapshot }
          return value
        }
        return
      }
      if method.hasPrefix("readJw") || method.hasPrefix("pollJw") || method.hasPrefix("cancelJw") {
        guard s.policy.source == "jw" else { throw IOSSchoolFailure.invalidSnapshot }
        let actions = ["readJwProbe": "start", "readJwDataProbe": "data", "readJwCollection": "collect",
                       "pollJwProbe": "poll", "pollJwDataProbe": "poll", "pollJwCollection": "poll",
                       "cancelJwProbe": "cancel", "cancelJwDataProbe": "cancel", "cancelJwCollection": "cancel"]
        guard let action = actions[method] else { throw IOSSchoolFailure.unsupportedPlatform }
        var keys: Set<String> = ["session", "document", "operation"]
        if action == "collect" || action == "data" { keys.insert("semesterId") }
        try fields(a, keys)
        var args: [String: Any] = ["method": "probe", "document": s.document,
                                 "operation": try Self.integer(a, "operation"), "action": action]
        if keys.contains("semesterId") { args["semesterId"] = try Self.integer(a, "semesterId", maximum: Int(Int32.max)) }
        try script(s, args, reply: reply) { try s.scripts.jwPayload($0) }
        return
      }
      let young = ["startYoungBusiness": "start", "dispatchYoungBusinessStep": "dispatch",
                   "pollYoungBusinessStep": "poll", "finishYoungBusiness": "finish"]
      if let action = young[method] {
        guard s.policy.source == "young" else { throw IOSSchoolFailure.invalidSnapshot }
        var keys: Set<String> = ["session", "document", "operation"]
        if action == "dispatch" { keys.formUnion(["step", "endpoint", "page", "day"]) }
        if action == "poll" { keys.insert("step") }
        try fields(a, keys, optional: ["day"])
        let operation = try Self.integer(a, "operation")
        var args: [String: Any] = ["method": action, "document": s.document, "operation": operation]
        if keys.contains("step") { args["step"] = try Self.integer(a, "step", maximum: 64000) }
        if action == "dispatch" {
          guard let endpoint = a["endpoint"] as? String, ["profile", "schedule", "activities"].contains(endpoint) else { throw IOSSchoolFailure.invalidSnapshot }
          let page = try Self.integer(a, "page", minimum: 0, maximum: 1000)
          let day = a["day"] as? String
          guard endpoint == "profile" ? (page == 0 && day == nil) : (page > 0),
                endpoint == "schedule" ? Self.validDay(day) : day == nil else { throw IOSSchoolFailure.invalidSnapshot }
          args["endpoint"] = endpoint; args["page"] = page
          if let day { args["day"] = day }
        }
        try script(s, args, reply: reply) { envelope in
          if action != "poll" { return nil }
          guard let value = envelope["value"] as? [String: Any], let complete = value["complete"] as? Bool else { throw IOSSchoolFailure.invalidSnapshot }
          var response: [String: Any] = ["session": s.id, "document": s.document,
                                        "operation": operation, "step": args["step"]!, "complete": complete]
          if complete {
            guard let text = value["projectedJson"] as? String, text.utf8.count <= 1024 * 1024 else { throw IOSSchoolFailure.invalidSnapshot }
            response["projectedJson"] = text
          }
          return response
        }
        return
      }
      throw IOSSchoolFailure.unsupportedPlatform
    } catch let failure as IOSSchoolFailure { reply(Self.error(failure)) }
    catch { reply(Self.error(.sourceFailed)) }
  }

  private static func validDay(_ value: String?) -> Bool {
    guard let value, value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else { return false }
    let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
    formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
    guard let date = formatter.date(from: value) else { return false }
    return formatter.string(from: date) == value
  }

  private func open(_ a: [String: Any]) throws {
    var keys: Set<String> = ["session", "profilePath", "initialUrl", "source", "allowedOrigins", "testMode", "recoveryOnly", "background"]
    var optional: Set<String> = []
#if DEBUG
    keys.insert("testNavigationOrigins"); optional.insert("testNavigationOrigins")
#endif
    try fields(a, keys, optional: optional)
    guard active == nil, closing == nil,
          Self.slot == nil || Self.slot === self else { throw IOSSchoolFailure.busy }
    let id = try Self.integer(a, "session")
    // Dart must drain even an open that failed before constructing WebKit.
    // This terminal ID carries no store/view authority and never replaces
    // another active host or a pending deletion.
    closedID = id; closeFailure = nil
    guard let recovery = a["recoveryOnly"] as? Bool, let background = a["background"] as? Bool,
          let profile = a["profilePath"] as? String else { throw IOSSchoolFailure.invalidSnapshot }
    guard !background else { throw IOSSchoolFailure.unsupportedPlatform }
    let fixtureAllowed: Bool
#if DEBUG
    fixtureAllowed = true
#else
    fixtureAllowed = false
#endif
    let policy = try IOSSchoolPolicy(arguments: a, allowFixtures: fixtureAllowed)
    if recovery && diagnosticSource == "none" { diagnosticSource = policy.source }
    if !recovery {
      diagnosticSource = policy.source; diagnosticEvent = "open"
      failureStage = "none"; failureDomain = "none"; failureCode = nil
      cleanupStage = "none"; cleanupReason = "none"; cleanupDomain = "none"; cleanupCode = nil
      policyAction = "none"; policyTarget = "none"
    }
    let root = try IOSPrivateStorage.root()
    let ledger = IOSSchoolStoreLedger(root: root)
    let record = try ledger.admit(profilePath: profile, source: policy.source, create: !recovery)
    guard recovery || record != nil else { throw IOSSchoolFailure.storageFailed }
    let s = Session(id: id, policy: policy, ledger: ledger,
                    record: record, scripts: try IOSSchoolScripts(policy: policy), recovery: recovery)
#if DEBUG
    if policy.isFixture, let record { fixtureStoreIDs[policy.source + "|" + profile] = record.id }
#endif
    active = s; Self.slot = self; closedID = nil; closeFailure = nil
    if recovery { return }
    let config = WKWebViewConfiguration()
    config.websiteDataStore = WKWebsiteDataStore(forIdentifier: record!.id)
    config.userContentController.addUserScript(WKUserScript(
      source: IOSSchoolScripts.guardBootstrap, injectionTime: .atDocumentStart,
      forMainFrameOnly: true, in: .defaultClient))
    if policy.source == "jw" {
      config.userContentController.add(
        NavigationNotice(bridge: self), contentWorld: .page, name: "ustcI2Revoke")
      config.userContentController.addUserScript(WKUserScript(
        source: try Self.jwNavigationNotices(for: policy.businessOrigin), injectionTime: .atDocumentStart,
        forMainFrameOnly: true, in: .page))
    }
    config.mediaTypesRequiringUserActionForPlayback = .all
    let view = WKWebView(frame: .zero, configuration: config)
    view.navigationDelegate = self; view.uiDelegate = self
    view.allowsBackForwardNavigationGestures = false
    s.view = view
    s.urlObserver = view.observe(\.url, options: [.new]) { [weak self, weak s] view, _ in
      guard let self, let s, self.active === s, view.url != s.lastURL else { return }
      s.lastURL = view.url
      self.invalidate(s)
      if !view.isLoading && s.finished { self.establish(s) }
    }
    guard show(s) else {
      recordFailure("presentation", event: "navigationFailed")
      beginClose(s); throw IOSSchoolFailure.sourceFailed
    }
    navigate(s, policy.initialURL)
  }

  private func event(_ s: Session, _ kind: String, diagnostic: [String: String]? = nil) {
    guard !retired else { return }
    var value: [String: Any] = ["session": s.id, "document": s.document, "kind": kind]
    if let origin = exportedOrigin(s) { value["origin"] = origin }
    if let diagnostic { value["diagnostic"] = diagnostic }
    channel.invokeMethod("event", arguments: value)
  }
  private func exportedOrigin(_ s: Session) -> String? {
    guard let origin = s.view?.url.flatMap(s.policy.origin), s.policy.origins.contains(origin) else { return nil }
    return origin
  }
  private func diagnostic(_ s: Session, _ code: String, _ url: URL?, action: String? = nil) {
    diagnosticEvent = "policyBlocked"
    policyAction = action ?? code
    let scheme = url?.scheme?.lowercased()
    if scheme != "http" && scheme != "https" { policyTarget = "otherScheme" }
    else if let url, s.policy.allows(url) { policyTarget = "registered" }
    else if url?.host == "127.0.0.1" { policyTarget = "localFixture" }
    else if let host = url?.host?.lowercased(), host == "ustc.edu.cn" || host.hasSuffix(".ustc.edu.cn") { policyTarget = "campus" }
    else { policyTarget = "external" }
    let site: String
    if s.policy.isFixture { site = "fixture" }
    else { site = ["jw.ustc.edu.cn": "jw", "young.ustc.edu.cn": "young", "passport.ustc.edu.cn": "passport",
                   "id.ustc.edu.cn": "identity", "ucas.ustc.edu.cn": "ucas"][url?.host ?? ""] ?? "unknown" }
    let safeScheme = ["http", "https"].contains(scheme ?? "") ? scheme! : "other"
    event(s, "diagnostic", diagnostic: ["code": code, "site": site, "scheme": safeScheme])
  }
  private func invalidate(_ s: Session) {
    s.document += 1; s.ready = false; s.guardValue = nil
    diagnosticEvent = "navigating"
    rejectPending(.staleResult)
    event(s, "navigating")
  }
  private func navigate(_ s: Session, _ url: URL) {
    guard active === s, s.policy.allows(url) else { return }
    let document = s.document
    finishDialog(s, accepted: false) { [weak self, weak s] in
      guard let self, let s, self.isCurrent(s, document), let view = s.view else { return }
      s.finished = false
      self.invalidate(s)
      s.activeLoad = nil
#if DEBUG
      s.fixtureRetiredLoad = nil
#endif
      s.activeLoad = view.load(URLRequest(url: url))
    }
  }
  @discardableResult private func show(_ s: Session) -> Bool {
    guard active === s, !s.isClosing, !s.isHiding, let view = s.view,
          UIApplication.shared.applicationState != .background else { return false }
    if let navigation = s.navigation { return navigation.presentingViewController != nil }
    guard var controller = presenter() else { return false }
    while let presented = controller.presentedViewController { controller = presented }
    guard !controller.isBeingDismissed, !controller.isBeingPresented else { return false }
    let host = SchoolHostController(webView: view, source: s.policy.source,
      onReturn: { [weak self, weak s] in if let s { self?.hide(s) } },
      onRetry: { [weak self, weak s] in
        guard let self, let s, self.active === s else { return }
        // A fixed GET, never reload/resubmit a school login POST or its body.
        self.navigate(s, s.policy.initialURL)
      },
      onCancel: { [weak self, weak s] in
        guard let self, let s else { return }
        self.diagnosticEvent = "userClosed"
        self.event(s, "userClosed"); self.beginClose(s)
      })
    let navigation = UINavigationController(rootViewController: host)
    navigation.modalPresentationStyle = .fullScreen; navigation.isModalInPresentation = true
    s.host = host; s.navigation = navigation
    controller.present(navigation, animated: false)
    guard navigation.presentingViewController != nil else {
      host.detachView(); s.host = nil; s.navigation = nil
      return false
    }
    host.setHost(s.displayedHost); host.setLoadFailure(s.manualLoadFailed)
    return true
  }
  private func hide(_ s: Session, completion: @escaping () -> Void = {}) {
    s.hideCompletions.append(completion)
    guard !s.isHiding else { return }
    s.isHiding = true
    finishDialog(s, accepted: false) { [self, s] in dismissHost(s) }
  }
  private func dismissHost(_ s: Session) {
    guard s.isHiding else { return }
    s.host?.detachView()
    let complete = { [s] in
      guard s.isHiding else { return }
      s.host = nil; s.navigation = nil; s.isHiding = false
      let completions = s.hideCompletions; s.hideCompletions.removeAll()
      completions.forEach { $0() }
    }
    guard let navigation = s.navigation else { complete(); return }
    if navigation.isBeingDismissed, let transition = navigation.transitionCoordinator,
        transition.animate(alongsideTransition: nil, completion: { _ in complete() }) { return }
    if navigation.presentingViewController != nil {
      navigation.dismiss(animated: false, completion: complete)
    } else { complete() }
  }

  private func raw(_ s: Session, _ script: String, world: WKContentWorld,
                   completion: @escaping (Result<Any, Error>) -> Void) {
    guard let view = s.view else { completion(.failure(IOSSchoolFailure.closed)); return }
    view.evaluateJavaScript(script, in: nil, in: world, completionHandler: completion)
  }
  private func guardText(_ result: Result<Any, Error>, _ s: Session) -> String? {
    guard case let .success(value) = result, let text = value as? String,
          text.utf8.count <= 8192, let data = text.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(dict.keys) == Set(["nonce", "revision", "href", "ready"]),
          let nonce = dict["nonce"] as? String, nonce.count <= 128, !nonce.isEmpty,
          let rev = dict["revision"] as? NSNumber, rev.intValue >= 0,
          let href = dict["href"] as? String, let url = URL(string: href),
          dict["ready"] as? Bool == true, s.view?.url == url, s.policy.allows(url) else { return nil }
    return text
  }
  private func establish(_ s: Session) {
    guard active === s, !s.isClosing, !s.ready, s.finished, s.view?.isLoading == false,
          let url = s.view?.url, s.policy.allowsNavigation(url) else { return }
    if !s.policy.allows(url) {
      // Navigation-only school pages are visible, never a business document.
      s.guardValue = nil; s.ready = false; s.manualLoadFailed = false
      s.host?.setLoadFailure(false); diagnosticEvent = "ready"; event(s, "ready")
      return
    }
    let document = s.document
    raw(s, IOSSchoolScripts.readGuard, world: .defaultClient) { [weak self, weak s] result in
      guard let self, let s, self.isCurrent(s, document), let stamp = self.guardText(result, s) else { return }
      let finish: () -> Void = { [weak self, weak s] in
        guard let self, let s, self.isCurrent(s, document) else { return }
        self.raw(s, IOSSchoolScripts.readGuard, world: .defaultClient) { [weak self, weak s] last in
          guard let self, let s, self.isCurrent(s, document), self.guardText(last, s) == stamp else { return }
          guard s.finished, s.view?.isLoading == false else { return }
          s.guardValue = stamp; s.ready = true; s.manualLoadFailed = false
          s.host?.setLoadFailure(false); self.diagnosticEvent = "ready"; self.event(s, "ready")
        }
      }
      let business = s.policy.origin(url) == s.policy.businessOrigin
      let youngContext = url.path.hasPrefix("/login/sc-wisdom-group-learning/")
      if business && !s.policy.isAuthenticationPage(url) && (s.policy.source == "jw" || youngContext) {
        do {
          self.raw(s, try s.scripts.install(document: document), world: s.policy.source == "jw" ? .defaultClient : .page) { result in
            guard case let .success(value) = result, value as? Bool == true else {
              if self.isCurrent(s, document), s.view?.isLoading == false {
                let error: Error? = { if case let .failure(error) = result { return error }; return nil }()
                self.recordFailure("readerInstall", event: "readerInstallFailed", error: error)
                self.recoverableLoadFailure(s)
              }
              return
            }
            finish()
          }
        } catch {
          self.recordFailure("readerInstall", event: "readerInstallFailed", error: error)
          self.recoverableLoadFailure(s)
        }
      } else { finish() }
    }
  }
  private func complete(_ id: UUID, _ value: Any? = nil, error: FlutterError? = nil) {
    guard let entry = pending.removeValue(forKey: id) else { return }
    entry.timer?.cancel()
    if let error { entry.reply(error) } else { entry.reply(value) }
  }
  private func rejectPending(_ failure: IOSSchoolFailure) {
    let entries = pending; pending.removeAll()
    for entry in entries.values { entry.timer?.cancel(); entry.reply(Self.error(failure)) }
  }
  private func script(_ s: Session, _ args: [String: Any], reply: @escaping FlutterResult,
                      consume: @escaping ([String: Any]) throws -> Any?) throws {
    guard s.ready, let stamp = s.guardValue else { throw IOSSchoolFailure.busy }
    let source = try s.scripts.call(args)
    let id = UUID(), document = s.document
    let entry = Pending(reply); pending[id] = entry
    let timer = DispatchWorkItem { [weak self] in self?.complete(id, error: Self.error(.sourceFailed)) }
    entry.timer = timer; DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timer)
    raw(s, IOSSchoolScripts.readGuard, world: .defaultClient) { [weak self, weak s] before in
      guard let self, let s, self.pending[id] != nil else { return }
      guard self.isCurrent(s, document), self.guardText(before, s) == stamp else { self.complete(id, error: Self.error(.staleResult)); return }
      self.raw(s, source, world: s.policy.source == "jw" ? .defaultClient : .page) { [weak self, weak s] result in
        guard let self, let s, self.pending[id] != nil else { return }
        guard self.isCurrent(s, document) else { self.complete(id, error: Self.error(.staleResult)); return }
        guard case let .success(raw) = result else { self.complete(id, error: Self.error(.sourceFailed)); return }
        self.raw(s, IOSSchoolScripts.readGuard, world: .defaultClient) { [weak self, weak s] after in
          guard let self, let s, self.pending[id] != nil else { return }
          guard self.isCurrent(s, document), self.guardText(after, s) == stamp else { self.complete(id, error: Self.error(.staleResult)); return }
          do {
            let envelope = try s.scripts.decode(raw)
            if let failure = envelope["error"] as? [String: Any] {
              let code = (failure["code"] as? String).flatMap(IOSSchoolFailure.init(rawValue:)) ?? .sourceFailed
              // decode has already checked the closed code/reason vocabulary.
              // Preserve that value-free diagnostic for the Young coordinator.
              let error: FlutterError
              if s.policy.source == "young", let reason = failure["reason"] as? String {
                error = FlutterError(code: "app_failure", message: nil,
                                     details: ["code": code.rawValue, "reason": reason])
              } else { error = Self.error(code) }
              self.complete(id, error: error); return
            }
            self.complete(id, try consume(envelope))
          } catch let failure as IOSSchoolFailure { self.complete(id, error: Self.error(failure)) }
          catch { self.complete(id, error: Self.error(.invalidSnapshot)) }
        }
      }
    }
  }

  private func beginClose(_ s: Session) {
    guard !s.isClosing else { return }
    s.isClosing = true; s.ready = false; s.guardValue = nil
    rejectPending(.staleResult)
    closeFailure = nil; closing = s; active = nil
    cleanupReason = "none"; cleanupDomain = "none"; cleanupCode = nil
    s.activeLoad = nil
#if DEBUG
    s.fixtureRetiredLoad = nil
#endif
    // Browser bytes remain opaque. The durable marker precedes UUID removal.
    do {
      if let record = s.record, s.recovery || record.disposable {
        cleanupStage = "metadataDeletePending"; try s.ledger.markDeleting(record)
      }
    } catch { cleanupFailed("metadataWrite", error: error, ioCode: s.ledger.lastFailureErrno) }
    s.view?.stopLoading(); s.view?.navigationDelegate = nil; s.view?.uiDelegate = nil
    s.view?.configuration.userContentController.removeScriptMessageHandler(forName: "ustcI2Revoke", contentWorld: .page)
    s.urlObserver?.invalidate(); s.urlObserver = nil
    closeView(s)
  }
  private func retryClose(_ s: Session) {
    closeFailure = nil
    cleanupReason = "none"; cleanupDomain = "none"; cleanupCode = nil
    // Once WebKit acknowledged removal, retry only the durable completion.
    // Rewriting deletePending here would conflict with an interrupted swap
    // that has already installed removed on disk.
    do {
      if let record = s.record, !s.storeRemoved && (s.recovery || record.disposable) {
        cleanupStage = "metadataDeletePending"; try s.ledger.markDeleting(record)
      }
    } catch { cleanupFailed("metadataWrite", error: error, ioCode: s.ledger.lastFailureErrno); return }
    if s.view != nil { closeView(s) }
    else { finishClose(s, attempts: 0) }
  }
  private func closeView(_ s: Session) {
    // Recovery-only sessions reconcile the registered store without creating
    // a WebView or presenting UIKit. They must still enter the store drain.
    if s.view == nil { finishClose(s, attempts: 0); return }
    s.uiCloseAttempt += 1
    let attempt = s.uiCloseAttempt
    cleanupStage = "waitingForView"
    // UIKit presentation/dismissal is asynchronous too. Keep its failure
    // bounded and retryable before starting the existing WebView release drain.
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self, s] in
      guard closing === s, s.uiCloseAttempt == attempt, s.view != nil else { return }
      cleanupFailed("viewRetained")
    }
    let wasHiding = s.isHiding
    hide(s) { [self, s] in
      guard closing === s, let view = s.view else { return }
      s.releasedView = view; s.view = nil
      cleanupStage = "waitingForView"
      finishClose(s, attempts: 0)
    }
    if wasHiding {
      if let dialog = s.dialog {
        if !dialog.alert.isBeingPresented && !dialog.alert.isBeingDismissed {
          dialog.dismissing = false
          finishDialog(s, accepted: false)
        }
      } else { dismissHost(s) }
    }
  }
  private func finishClose(_ s: Session, attempts: Int) {
    guard closing === s else { return }
    if s.releasedView != nil {
      cleanupStage = "waitingForView"
      // Keyboard/presentation and outstanding WebKit callbacks can outlive
      // the old 1.5s window. Leave budget within Dart's 12s drain for official
      // deletion; slow WebKit callbacks still remain a reported pending drain.
      guard attempts < 100 else { cleanupFailed("viewRetained"); return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in finishClose(s, attempts: attempts + 1) }
      return
    }
    guard closeFailure == nil else { return }
    if let record = s.record, s.recovery || record.disposable {
      if s.storeRemoved {
        cleanupStage = "metadataRemoved"
        do { try s.ledger.didRemove(record); endClose(s) }
        catch { cleanupFailed("metadataCompletion", error: error, ioCode: s.ledger.lastFailureErrno) }
        return
      }
      // WebKit profile removal needs the data-store subsystem initialized.
      // Never give this default store to a school view.
      _ = WKWebsiteDataStore.default()
      WKWebsiteDataStore.fetchAllDataStoreIdentifiers { [self] identifiers in
        guard closing === s else { return }
        if !identifiers.contains(record.id) {
          verifyRemoved(s, record, attempts: 0, absentSamples: 0, retries: 1)
          return
        }
        removeStore(s, record, retries: 1)
      }
    } else { endClose(s) }
  }
  private func removeStore(_ s: Session, _ record: IOSSchoolStoreRecord, retries: Int) {
    cleanupStage = "removeStore"
    WKWebsiteDataStore.remove(forIdentifier: record.id) { [self] error in
      guard closing === s else { return }
      if let error {
        if retries > 0 {
          // Retry only the same revoked UUID; never switch stores or bypass
          // the durable deletePending/official absence checks.
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            guard closing === s else { return }
            removeStore(s, record, retries: retries - 1)
          }
        } else { cleanupFailed("removeRejected", error: error) }
        return
      }
      verifyRemoved(s, record, attempts: 0, absentSamples: 0, retries: retries)
    }
  }
  private func verifyRemoved(_ s: Session, _ record: IOSSchoolStoreRecord,
                             attempts: Int, absentSamples: Int, retries: Int) {
    cleanupStage = "verifyStoreAbsent"
    WKWebsiteDataStore.fetchAllDataStoreIdentifiers { [self] identifiers in
      guard closing === s else { return }
      let absent = !identifiers.contains(record.id)
      if absent && absentSamples >= 4 { confirmRemoved(s, record); return }
      guard attempts < 50 else { cleanupFailed("storePresent"); return }
      if !absent && attempts >= 10 {
        guard retries > 0 else { cleanupFailed("storePresent"); return }
        // A closed storage manager may finish work after the deletion call.
        // Retry only this already-revoked UUID through the official API once.
        removeStore(s, record, retries: retries - 1)
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
        verifyRemoved(s, record, attempts: attempts + 1,
                      absentSamples: absent ? absentSamples + 1 : 0, retries: retries)
      }
    }
  }
  private func confirmRemoved(_ s: Session, _ record: IOSSchoolStoreRecord) {
    // Verify the observable postcondition instead of inferring physical erase
    // or the OS's internal ordering from a completion callback alone.
    s.storeRemoved = true
    cleanupStage = "metadataRemoved"
    do { try s.ledger.didRemove(record); endClose(s) }
    catch { cleanupFailed("metadataCompletion", error: error, ioCode: s.ledger.lastFailureErrno) }
  }
  private func endClose(_ s: Session) {
    closedID = s.id; closing = nil; closeFailure = nil
    cleanupStage = "complete"; cleanupReason = "none"; cleanupDomain = "none"; cleanupCode = nil
    if Self.slot === self { Self.slot = nil }
  }

  private func traceDialog(_ s: Session, _ value: String) {
#if DEBUG
    if s.policy.isFixture {
      s.fixtureDialogTrace.append(value)
      if s.fixtureDialogTrace.count > 32 { s.fixtureDialogTrace.removeFirst() }
    }
#endif
  }
  private func finishDialog(_ s: Session, accepted: Bool,
                            completion: @escaping () -> Void = {}) {
    guard let dialog = s.dialog else { completion(); return }
    dialog.afterDismiss.append(completion)
    if dialog.requestedAcceptance == nil { dialog.requestedAcceptance = accepted }
    guard !dialog.dismissing else { return }
    // Closing while UIKit is still presenting must wait for that transition.
    if !dialog.presented && dialog.alert.presentingViewController != nil {
      traceDialog(s, "dismissWaitingForPresentation"); return
    }
    dialog.dismissing = true
    traceDialog(s, "dismissRequested")
    let complete = { [self, s, dialog] in
      guard s.dialog === dialog else { return }
      s.dialog = nil
      traceDialog(s, "dismissCompleted")
      // WebKit resumes only after UIKit has actually dismissed the panel.
      dialog.finish(dialog.requestedAcceptance ?? false)
      traceDialog(s, "completionDelivered")
      let completions = dialog.afterDismiss; dialog.afterDismiss.removeAll()
      completions.forEach { $0() }
    }
    if dialog.alert.isBeingDismissed, let transition = dialog.alert.transitionCoordinator,
        transition.animate(alongsideTransition: nil, completion: { _ in complete() }) { return }
    if dialog.alert.presentingViewController != nil {
      dialog.alert.dismiss(animated: false, completion: complete)
    } else { complete() }
  }
  private func presentDialog(_ view: WKWebView, message: String, frame: WKFrameInfo,
                             kind: String, reply: @escaping (Bool) -> Void) {
    guard let s = active, s.view === view else { reply(false); return }
    traceDialog(s, kind == "confirm" ? "confirmRequested" : "alertRequested")
    guard !s.isClosing, !s.isHiding,
          UIApplication.shared.applicationState == .active,
          let navigation = s.navigation, navigation.presentingViewController != nil,
          navigation.presentedViewController == nil, s.dialog == nil else {
      let reason = s.isClosing ? "closing" : s.isHiding ? "hiding"
        : UIApplication.shared.applicationState != .active ? "inactive"
        : s.navigation?.presentingViewController == nil ? "missingPresenter"
        : s.navigation?.presentedViewController != nil ? "existingModal" : "existingDialog"
      traceDialog(s, reason)
      diagnostic(s, "permissionBlocked", frame.request.url, action: "dialogBlocked")
      reply(false); return
    }
    let host = String((frame.request.url?.host ?? "学校网页").prefix(253))
    // Page text is only displayed here. It is never copied to a diagnostic,
    // persisted, inspected for credentials, or treated as an app instruction.
    let alert = UIAlertController(title: "网页提示 · \(host)", message: String(message.prefix(2000)), preferredStyle: .alert)
    let dialog = SchoolDialog(alert: alert, kind: kind, reply: reply)
    s.dialog = dialog
    if kind == "confirm" {
      alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self, weak s] _ in
        if let s { self?.finishDialog(s, accepted: false) }
      })
    }
    let accept = UIAlertAction(title: "确定", style: .default) { [weak self, weak s] _ in
      if let s { self?.finishDialog(s, accepted: true) }
    }
    alert.addAction(accept); alert.preferredAction = accept
    var cancelDuringPresentation = false
#if DEBUG
    cancelDuringPresentation = s.policy.isFixture && s.fixtureCancelDuringPresentation
    s.fixtureCancelDuringPresentation = false
#endif
    navigation.present(alert, animated: cancelDuringPresentation) { [weak self, weak s, weak dialog] in
      guard let self, let s, let dialog, s.dialog === dialog, !dialog.dismissing else { return }
      dialog.presented = true; self.traceDialog(s, "presentCompleted")
      if let accepted = dialog.requestedAcceptance { self.finishDialog(s, accepted: accepted) }
    }
    if cancelDuringPresentation { finishDialog(s, accepted: false) }
    DispatchQueue.main.async { [weak self, weak s, weak dialog] in
      guard let self, let s, let dialog, s.dialog === dialog, !dialog.dismissing,
            alert.presentingViewController == nil else { return }
      self.traceDialog(s, "presentationFailed")
      self.diagnostic(s, "permissionBlocked", frame.request.url, action: "dialogBlocked")
      self.finishDialog(s, accepted: false)
    }
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    guard let s = active, s.view === webView else { return }
    s.activeLoad = navigation; s.manualLoadFailed = false; s.host?.setLoadFailure(false)
    s.finished = false; invalidate(s)
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard let s = active, s.view === webView, currentLoad(s, navigation) else { return }
    s.finished = true; establish(s)
  }
  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    guard let s = active, s.view === webView, currentLoad(s, navigation) else { return }
    s.displayedHost = webView.url?.host; s.host?.setHost(s.displayedHost)
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    failed(webView, navigation: navigation, error: error, stage: "navigation")
  }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    failed(webView, navigation: navigation, error: error, stage: "provisionalNavigation")
  }
  private func currentLoad(_ s: Session, _ navigation: WKNavigation?) -> Bool {
    if let navigation, let current = s.activeLoad { return navigation === current }
    return navigation == nil && s.activeLoad == nil && !s.manualLoadFailed
  }
  private func failed(_ view: WKWebView, navigation: WKNavigation?, error: Error, stage: String) {
    guard let s = active, s.view === view, currentLoad(s, navigation) else { return }
    let value = error as NSError
    if (value.domain == NSURLErrorDomain && value.code == NSURLErrorCancelled) ||
        (value.domain == "WebKitErrorDomain" && value.code == 102) { return }
    recordFailure(stage, event: "navigationFailed", error: error)
    recoverableLoadFailure(s)
  }
  private func recoverableLoadFailure(_ s: Session) {
    guard active === s, !s.isClosing else { return }
    let failureEvent = diagnosticEvent
    s.finished = false; s.manualLoadFailed = true; s.activeLoad = nil
    invalidate(s) // Any active business operation still closes via C1.
    diagnosticEvent = failureEvent
    s.host?.setLoadFailure(true)
    // While the user is signing in, a load failure leaves the host visible.
    // Retrying uses the registered initial GET; it cannot replay a login POST.
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard let s = active, s.view === webView else { return }
    recordFailure("process", event: "processTerminated")
    event(s, "failed"); beginClose(s)
  }
  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let s = active, s.view === webView, !s.isClosing, let url = action.request.url else { decisionHandler(.cancel); return }
    if action.shouldPerformDownload { diagnostic(s, "downloadBlocked", url); decisionHandler(.cancel); return }
    if action.targetFrame == nil {
      if action.sourceFrame.isMainFrame, action.navigationType == .linkActivated,
          action.request.httpMethod == "GET", action.request.httpBody == nil,
          action.request.httpBodyStream == nil, s.policy.allowsNavigation(url) {
        let document = s.document
        decisionHandler(.cancel)
        DispatchQueue.main.async { [weak self, weak s] in
          guard let self, let s, self.isCurrent(s, document), let view = s.view else { return }
          self.finishDialog(s, accepted: false) { [weak self, weak s, weak view] in
            guard let self, let s, let view, self.isCurrent(s, document), s.view === view else { return }
            s.finished = false; self.invalidate(s)
            s.activeLoad = view.load(URLRequest(url: url))
          }
        }
      } else { diagnostic(s, "popupBlocked", url); decisionHandler(.cancel) }
      return
    }
    let main = action.targetFrame?.isMainFrame == true
    guard (main ? s.policy.allowsNavigation(url) : s.policy.allowsSubframeNavigation(url)) else {
      diagnostic(s, !["https", "http"].contains(url.scheme ?? "") ? "externalProtocolBlocked" : main ? "topNavigationBlocked" : "frameNavigationBlocked", url)
      if main { invalidate(s); event(s, "blocked") }
      decisionHandler(.cancel); return
    }
    decisionHandler(.allow)
  }
  func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
               decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    guard let s = active, s.view === webView, let url = response.response.url else { decisionHandler(.cancel); return }
    guard (response.isForMainFrame ? s.policy.allowsNavigation(url) : s.policy.allowsSubframeNavigation(url)) else {
      diagnostic(s, response.isForMainFrame ? "topNavigationBlocked" : "frameNavigationBlocked", url, action: "responseOriginBlocked")
      if response.isForMainFrame { invalidate(s); event(s, "blocked") }
      decisionHandler(.cancel); return
    }
    let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
    if disposition.lowercased().contains("attachment") || !response.canShowMIMEType {
      diagnostic(s, "downloadBlocked", url); decisionHandler(.cancel); return
    }
    decisionHandler(.allow)
  }
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if let s = active { diagnostic(s, "popupBlocked", action.request.url) }
    return nil
  }
  func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.cancel { _ in } }
  func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.cancel { _ in } }
  func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
               initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
               decisionHandler: @escaping (WKPermissionDecision) -> Void) {
    if let s = active { diagnostic(s, "permissionBlocked", webView.url) }; decisionHandler(.deny)
  }
  func webView(_ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
               initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
    if let s = active { diagnostic(s, "permissionBlocked", webView.url) }; decisionHandler(.deny)
  }
  func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
               initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
    if let s = active { diagnostic(s, "permissionBlocked", webView.url) }; decisionHandler(.deny)
  }
  func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
    presentDialog(webView, message: message, frame: frame, kind: "alert") { _ in completionHandler() }
  }
  func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
    presentDialog(webView, message: message, frame: frame, kind: "confirm", reply: completionHandler)
  }
  func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
               defaultText: String?, initiatedByFrame frame: WKFrameInfo,
               completionHandler: @escaping (String?) -> Void) {
    if let s = active, s.view === webView { diagnostic(s, "permissionBlocked", frame.request.url, action: "textPromptBlocked") }
    completionHandler(nil)
  }
  func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
    if let s = active { diagnostic(s, "permissionBlocked", webView.url) }
    completionHandler(nil)
  }

  // Page-originated notices only revoke work. They cannot mark a document
  // ready, supply identity/data, authorize an operation or request a URL.
  private final class NavigationNotice: NSObject, WKScriptMessageHandler {
    weak var bridge: IOSObservationBridge?
    init(bridge: IOSObservationBridge) { self.bridge = bridge }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
      bridge?.navigationNotice(message)
    }
  }
  private func navigationNotice(_ message: WKScriptMessage) {
    guard let s = active, s.policy.source == "jw", message.body as? String == "history",
          message.webView === s.view, message.frameInfo.isMainFrame,
          let url = message.frameInfo.request.url, s.policy.origin(url) == s.policy.businessOrigin else { return }
    invalidate(s)
    if s.finished && s.view?.isLoading == false { establish(s) }
  }
  private static func jwNavigationNotices(for origin: String) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: origin, options: [.fragmentsAllowed])
    guard let literal = String(data: data, encoding: .utf8) else { throw IOSSchoolFailure.invalidSnapshot }
    return """
    (()=>{'use strict'; if(window!==window.top || location.origin!==\(literal))return;
      const send=()=>{try{window.webkit.messageHandlers.ustcI2Revoke.postMessage('history');}catch(_){}};
      for(const name of ['pushState','replaceState']) {
        const original=History.prototype[name];
        try{Object.defineProperty(History.prototype,name,{configurable:true,writable:true,
          value:function(){try{return Reflect.apply(original,this,arguments);}finally{send();}}});}catch(_){send();}
      }
    })();
    """
  }

#if DEBUG
  private func storeExists(_ a: [String: Any], _ reply: @escaping FlutterResult) throws {
    try fields(a, ["profilePath", "source"])
    guard let profile = a["profilePath"] as? String, let source = a["source"] as? String else { throw IOSSchoolFailure.invalidSnapshot }
    let identifier: UUID
    let key = source + "|" + profile
    if let known = fixtureStoreIDs[key] { identifier = known }
    else {
      let ledger = IOSSchoolStoreLedger(root: try IOSPrivateStorage.root())
      guard let record = try ledger.admit(profilePath: profile, source: source, create: false) else { reply(false); return }
      identifier = record.id; fixtureStoreIDs[key] = identifier
    }
    _ = WKWebsiteDataStore.default()
    WKWebsiteDataStore.fetchAllDataStoreIdentifiers { identifiers in reply(identifiers.contains(identifier)) }
  }
  private func fixture(_ s: Session, _ a: [String: Any], _ reply: @escaping FlutterResult) throws {
    try fields(a, ["session", "document", "action"])
    guard s.policy.isFixture, let action = a["action"] as? String,
          ["writeSyntheticMarker", "checkSyntheticMarker", "checkNoSyntheticMarker"].contains(action), s.ready else { throw IOSSchoolFailure.unsupportedPlatform }
    let expected = s.policy.source == "jw" ? "i2-jw" : "i2-young"
    // Test-only, fixed marker in a new synthetic store. No arbitrary storage key.
    let body = """
      const key='ustc-i2-synthetic', expected='\(expected)';
      const db=await new Promise((resolve,reject)=>{const r=indexedDB.open('ustc-i2-synthetic',1);r.onupgradeneeded=()=>r.result.createObjectStore('markers');r.onsuccess=()=>resolve(r.result);r.onerror=reject;});
      try {
        if(action==='writeSyntheticMarker') {
          localStorage.setItem(key,expected);document.cookie='ustc-i2-synthetic='+expected+'; path=/; max-age=3600';
          await new Promise((resolve,reject)=>{let t=db.transaction('markers','readwrite');t.objectStore('markers').put(expected,key);t.oncomplete=resolve;t.onerror=reject;});
          const c=await caches.open('ustc-i2-synthetic');await c.put('/i2-marker',new Response(expected));return true;
        }
        const marker=await new Promise((resolve,reject)=>{const r=db.transaction('markers').objectStore('markers').get(key);r.onsuccess=()=>resolve(r.result);r.onerror=reject;});
        const c=await caches.open('ustc-i2-synthetic'), response=await c.match('/i2-marker'), cached=response?await response.text():null;
        const present=localStorage.getItem(key)===expected && document.cookie.split(';').some(x=>x.trim()==='ustc-i2-synthetic='+expected) && marker===expected && cached===expected;
        return action==='checkSyntheticMarker'?present:localStorage.getItem(key)===null && !marker && cached===null && !document.cookie.includes('ustc-i2-synthetic=');
      } finally {db.close();}
      """
    guard let view = s.view else { throw IOSSchoolFailure.closed }
    let document = s.document
    view.callAsyncJavaScript(body, arguments: ["action": action], in: nil, in: .defaultClient) { [weak self, weak s] result in
      guard let self, let s, self.isCurrent(s, document), case let .success(value) = result, let value = value as? Bool else { reply(Self.error(.staleResult)); return }
      reply(value)
    }
  }
  private func exercise(_ s: Session, _ a: [String: Any], _ reply: @escaping FlutterResult) throws {
    try fields(a, ["session", "document", "action"])
    guard s.policy.isFixture, let action = a["action"] as? String else { throw IOSSchoolFailure.unsupportedPlatform }
    let code: String
    switch action {
    case "compatLink", "compatBlankLink", "compatPostBlank", "compatDeniedLink", "compatSubmit":
      let ids = ["compatLink": "compat-link", "compatBlankLink": "compat-blank",
                 "compatPostBlank": "compat-post-blank", "compatDeniedLink": "compat-denied", "compatSubmit": "compat-form"]
      if action == "compatBlankLink" || action == "compatPostBlank" {
        s.view?.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
      }
      let id = ids[action]!
      code = action == "compatSubmit" || action == "compatPostBlank"
        ? "document.getElementById('\(id)').requestSubmit();true"
        : "document.getElementById('\(id)').click();true"
    case "authHistoryUnmodified", "checkConfirmationAccepted", "checkConfirmationRejected":
      let body = action == "authHistoryUnmodified"
        ? "String(History.prototype.pushState).includes('[native code]') && String(History.prototype.replaceState).includes('[native code]')"
        : action == "checkConfirmationAccepted" ? "window.__i2ConfirmResult===true" : "window.__i2ConfirmResult===false"
      let document = s.document
      raw(s, body, world: .page) { [weak self, weak s] result in
        guard let self, let s, self.isCurrent(s, document), case let .success(value) = result,
              let value = value as? Bool else { reply(Self.error(.staleResult)); return }
        reply(value)
      }
      return
    case "compatConfirm": code = "window.__i2ConfirmResult=confirm('Synthetic confirmation');true"
    case "compatConfirmCancelDuringPresentation":
      s.fixtureCancelDuringPresentation = true
      code = "window.__i2ConfirmResult=confirm('Synthetic pending presentation');true"
    case "compatAlert": code = "alert('Synthetic alert');true"
    case "hasSyntheticDialog": reply(s.dialog?.presented == true && s.dialog?.dismissing == false); return
    case "syntheticDialogStatus":
      reply(["trace": s.fixtureDialogTrace,
             "applicationActive": UIApplication.shared.applicationState == .active,
             "webAttached": s.view?.window != nil,
             "navigationVisible": s.navigation?.presentingViewController != nil,
             "modalVisible": s.navigation?.presentedViewController != nil,
             "pending": s.dialog != nil, "hiding": s.isHiding]); return
    case "acceptSyntheticDialog", "dismissSyntheticAlert":
      guard let dialog = s.dialog, dialog.kind == (action == "acceptSyntheticDialog" ? "confirm" : "alert") else {
        reply(false); return
      }
      finishDialog(s, accepted: true) { reply(true) }; return
    case "showSyntheticWindow": reply(show(s)); return
    case "useLightAppearance", "useDarkAppearance":
      s.navigation?.overrideUserInterfaceStyle = action == "useDarkAppearance" ? .dark : .light
      reply(nil); return
    case "authentication":
      guard s.policy.source == "jw", s.view?.url?.path == "/login" else { throw IOSSchoolFailure.invalidSnapshot }
      s.fixtureRetiredLoad = s.activeLoad
      code = "document.querySelector('#login-unified-wrapper').click();true"
    case "submitAuthForm":
      guard s.policy.source == "jw", s.view?.url?.path == "/cas/login" else { throw IOSSchoolFailure.invalidSnapshot }
      code = """
        (()=>{const f=document.querySelector('#normalLoginForm');
        f.querySelector('#nameInput').value='TEST0001';
        f.querySelector('[type=password]').value='synthetic-password';
        f.requestSubmit();return true})()
        """
    case "iosNavigationCancelled", "iosPolicyInterrupted", "iosNavigationFailed", "iosRetiredNavigationFailed":
      guard let view = s.view else { throw IOSSchoolFailure.closed }
      let navigation: WKNavigation?
      if action == "iosRetiredNavigationFailed" {
        guard let retired = s.fixtureRetiredLoad, retired !== s.activeLoad else { throw IOSSchoolFailure.invalidSnapshot }
        navigation = retired
      } else { navigation = s.activeLoad }
      let error = NSError(domain: action == "iosPolicyInterrupted" ? "WebKitErrorDomain" : NSURLErrorDomain,
                          code: action == "iosPolicyInterrupted" ? 102 : action == "iosNavigationCancelled" ? NSURLErrorCancelled : NSURLErrorNotConnectedToInternet,
                          userInfo: [NSLocalizedDescriptionKey: "i2-secret-userinfo-sentinel",
                                     NSURLErrorFailingURLStringErrorKey: "https://example.invalid/?ticket=i2-secret-url-sentinel"])
      failed(view, navigation: navigation, error: error, stage: "provisionalNavigation")
      reply(nil); return
    case "iosRetiredNavigationFinished":
      guard let view = s.view, let retired = s.fixtureRetiredLoad else { throw IOSSchoolFailure.invalidSnapshot }
      webView(view, didFinish: retired); reply(nil); return
    case "iosRetryInitial": navigate(s, s.policy.initialURL); reply(nil); return
    case "iosReturnToApp": hide(s) { reply(nil) }; return
    case "sameDocument", "youngSameUrlPush": code = "history.pushState({},'',location.href);true"
    case "youngSameUrlReplace": code = "history.replaceState({},'',location.href);true"
    case "nextDocument": code = "location.reload();true"
    case "topDenied": code = "location.href='http://127.0.0.1:49151/i2-denied';true"
    case "frameDenied": code = "(()=>{let f=document.createElement('iframe');f.src='http://127.0.0.1:49151/i2-denied';document.body.append(f);return true})()"
    case "popup":
      // Exercise the native popup delegate rather than merely relying on
      // WebKit's default no-user-gesture suppression. Fixture build only.
      s.view?.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
      code = "window.open('http://127.0.0.1:49151/i2-denied','_blank');true"
    case "external": code = "location.href='ustc-i2-fixture://denied';true"
    case "download": code = "location.href=location.origin+'/i2-attachment';true"
    case "userClose": event(s, "userClosed"); beginClose(s); reply(nil); return
    default: throw IOSSchoolFailure.unsupportedPlatform
    }
    raw(s, code, world: .page) { result in
      if ["compatConfirm", "compatConfirmCancelDuringPresentation", "compatAlert"].contains(action), case .failure = result {
        reply(Self.error(.sourceFailed))
      } else { reply(nil) }
    }
  }
#endif
}

@MainActor private final class SchoolHostController: UIViewController {
  private var webView: WKWebView?
  private var locationHost: String?, loadFailed = false
  private let onReturn: () -> Void, onRetry: () -> Void, onCancel: () -> Void
  init(webView: WKWebView, source: String, onReturn: @escaping () -> Void,
       onRetry: @escaping () -> Void, onCancel: @escaping () -> Void) {
    self.webView = webView; self.onReturn = onReturn; self.onRetry = onRetry; self.onCancel = onCancel
    super.init(nibName: nil, bundle: nil)
    title = source == "jw" ? "教务 · 手动登录" : "二课 · 手动登录"
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func viewDidLoad() {
    super.viewDidLoad(); view.backgroundColor = .systemBackground
    navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消同步", style: .plain, target: self, action: #selector(cancel))
    navigationItem.rightBarButtonItems = [
      UIBarButtonItem(title: "返回应用", style: .done, target: self, action: #selector(back)),
      UIBarButtonItem(title: "重试", style: .plain, target: self, action: #selector(retry))
    ]
    if let webView {
      view.addSubview(webView); webView.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        webView.leadingAnchor.constraint(equalTo: view.leadingAnchor), webView.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
    }
  }
  func detachView() { webView?.endEditing(true); webView?.removeFromSuperview(); webView = nil }
  func setHost(_ host: String?) { locationHost = host; updatePrompt() }
  func setLoadFailure(_ failed: Bool) { loadFailed = failed; updatePrompt() }
  private func updatePrompt() {
    navigationItem.prompt = loadFailed ? "页面未能加载，请重试。" : locationHost.map { "正在访问：\($0)" }
  }
  @objc private func back() { onReturn() }
  @objc private func retry() { onRetry() }
  @objc private func cancel() { onCancel() }
}
