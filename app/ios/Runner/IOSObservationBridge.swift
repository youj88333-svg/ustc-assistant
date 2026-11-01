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
    var document = 0
    var ready = false, finished = false, isClosing = false
    var storeRemoved = false
    var guardValue: String?, lastURL: URL?
    init(id: Int, policy: IOSSchoolPolicy, ledger: IOSSchoolStoreLedger,
         record: IOSSchoolStoreRecord?, scripts: IOSSchoolScripts, recovery: Bool) {
      self.id = id; self.policy = policy; self.ledger = ledger
      self.record = record; self.scripts = scripts; self.recovery = recovery
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
               "origin": s.view?.url.flatMap(s.policy.origin) as Any? ?? NSNull(),
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
        guard s.ready else { reply("waiting"); return }
        let business = s.view?.url.flatMap(s.policy.origin) == s.policy.businessOrigin
          && !(s.view?.url?.path.hasPrefix("/cas/") ?? false)
          && s.view?.url?.path != "/login"
        let youngReady = s.view?.url?.path.hasPrefix("/login/sc-wisdom-group-learning/") == true
          && s.view?.url?.query == nil
        if business && (s.policy.source == "jw" || youngReady) { reply("businessReady") }
        else { show(s); reply("manualRequired") }
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
    try fields(a, ["session", "profilePath", "initialUrl", "source", "allowedOrigins", "testMode", "recoveryOnly", "background"])
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
        source: Self.jwNavigationNotices, injectionTime: .atDocumentStart,
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
    show(s)
    navigate(s, policy.initialURL)
  }

  private func event(_ s: Session, _ kind: String, diagnostic: [String: String]? = nil) {
    guard !retired else { return }
    var value: [String: Any] = ["session": s.id, "document": s.document, "kind": kind]
    if let origin = s.view?.url.flatMap(s.policy.origin), s.policy.origins.contains(origin) { value["origin"] = origin }
    if let diagnostic { value["diagnostic"] = diagnostic }
    channel.invokeMethod("event", arguments: value)
  }
  private func diagnostic(_ s: Session, _ code: String, _ url: URL?) {
    let site: String
    if s.policy.isFixture { site = "fixture" }
    else { site = ["jw.ustc.edu.cn": "jw", "young.ustc.edu.cn": "young", "passport.ustc.edu.cn": "passport",
                   "id.ustc.edu.cn": "identity", "ucas.ustc.edu.cn": "ucas"][url?.host ?? ""] ?? "unknown" }
    let scheme = ["http", "https"].contains(url?.scheme ?? "") ? url!.scheme! : "other"
    event(s, "diagnostic", diagnostic: ["code": code, "site": site, "scheme": scheme])
  }
  private func invalidate(_ s: Session) {
    s.document += 1; s.ready = false; s.guardValue = nil
    rejectPending(.staleResult)
    event(s, "navigating")
  }
  private func navigate(_ s: Session, _ url: URL) {
    guard active === s, s.policy.allows(url), let view = s.view else { return }
    s.finished = false
    invalidate(s)
    view.load(URLRequest(url: url))
  }
  private func show(_ s: Session) {
    guard active === s, !s.isClosing, s.navigation == nil, let view = s.view,
          UIApplication.shared.applicationState != .background, var controller = presenter() else { return }
    while let presented = controller.presentedViewController { controller = presented }
    let host = SchoolHostController(webView: view, source: s.policy.source,
      onReturn: { [weak self, weak s] in if let s { self?.hide(s) } },
      onCancel: { [weak self, weak s] in
        guard let self, let s else { return }
        self.event(s, "userClosed"); self.beginClose(s)
      })
    let navigation = UINavigationController(rootViewController: host)
    navigation.modalPresentationStyle = .fullScreen; navigation.isModalInPresentation = true
    s.host = host; s.navigation = navigation
    controller.present(navigation, animated: false)
  }
  private func hide(_ s: Session) {
    s.host?.detachView()
    s.navigation?.dismiss(animated: false)
    s.host = nil; s.navigation = nil
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
    guard active === s, !s.isClosing, !s.ready, let url = s.view?.url, s.policy.allows(url) else { return }
    let document = s.document
    raw(s, IOSSchoolScripts.readGuard, world: .defaultClient) { [weak self, weak s] result in
      guard let self, let s, self.isCurrent(s, document), let stamp = self.guardText(result, s) else { return }
      let finish: () -> Void = { [weak self, weak s] in
        guard let self, let s, self.isCurrent(s, document) else { return }
        self.raw(s, IOSSchoolScripts.readGuard, world: .defaultClient) { [weak self, weak s] last in
          guard let self, let s, self.isCurrent(s, document), self.guardText(last, s) == stamp else { return }
          s.guardValue = stamp; s.ready = true; self.event(s, "ready")
        }
      }
      let business = s.policy.origin(url) == s.policy.businessOrigin
      let youngContext = url.path.hasPrefix("/login/sc-wisdom-group-learning/")
      if business && (s.policy.source == "jw" || youngContext) {
        do {
          self.raw(s, try s.scripts.install(document: document), world: s.policy.source == "jw" ? .defaultClient : .page) { result in
            guard case let .success(value) = result, value as? Bool == true else {
              if self.isCurrent(s, document) { self.event(s, "failed") }
              return
            }
            finish()
          }
        } catch { self.event(s, "failed") }
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
    // Browser bytes remain opaque. The durable marker precedes UUID removal.
    do {
      if let record = s.record, s.recovery || record.disposable { try s.ledger.markDeleting(record) }
    } catch { closeFailure = .cleanupPending }
    s.view?.stopLoading(); s.view?.navigationDelegate = nil; s.view?.uiDelegate = nil
    s.view?.configuration.userContentController.removeScriptMessageHandler(forName: "ustcI2Revoke", contentWorld: .page)
    s.urlObserver?.invalidate(); s.urlObserver = nil
    hide(s)
    s.releasedView = s.view; s.view = nil
    finishClose(s, attempts: 0)
  }
  private func retryClose(_ s: Session) {
    closeFailure = nil
    // Once WebKit acknowledged removal, retry only the durable completion.
    // Rewriting deletePending here would conflict with an interrupted swap
    // that has already installed removed on disk.
    do { if let record = s.record, !s.storeRemoved && (s.recovery || record.disposable) { try s.ledger.markDeleting(record) } }
    catch { closeFailure = .cleanupPending; return }
    finishClose(s, attempts: 0)
  }
  private func finishClose(_ s: Session, attempts: Int) {
    guard closing === s else { return }
    if s.releasedView != nil {
      guard attempts < 30 else { closeFailure = .cleanupPending; return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in finishClose(s, attempts: attempts + 1) }
      return
    }
    guard closeFailure == nil else { return }
    if let record = s.record, s.recovery || record.disposable {
      if s.storeRemoved {
        do { try s.ledger.didRemove(record); endClose(s) }
        catch { closeFailure = .cleanupPending }
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
    WKWebsiteDataStore.remove(forIdentifier: record.id) { [self] error in
      guard closing === s else { return }
      guard error == nil else { closeFailure = .cleanupPending; return }
      verifyRemoved(s, record, attempts: 0, absentSamples: 0, retries: retries)
    }
  }
  private func verifyRemoved(_ s: Session, _ record: IOSSchoolStoreRecord,
                             attempts: Int, absentSamples: Int, retries: Int) {
    WKWebsiteDataStore.fetchAllDataStoreIdentifiers { [self] identifiers in
      guard closing === s else { return }
      let absent = !identifiers.contains(record.id)
      if absent && absentSamples >= 4 { confirmRemoved(s, record); return }
      guard attempts < 50 else { closeFailure = .cleanupPending; return }
      if !absent && attempts >= 10 {
        guard retries > 0 else { closeFailure = .cleanupPending; return }
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
    do { try s.ledger.didRemove(record); endClose(s) }
    catch { closeFailure = .cleanupPending }
  }
  private func endClose(_ s: Session) {
    closedID = s.id; closing = nil; closeFailure = nil
    if Self.slot === self { Self.slot = nil }
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    guard let s = active, s.view === webView else { return }
    s.finished = false; invalidate(s)
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard let s = active, s.view === webView else { return }
    s.finished = true; establish(s)
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(webView, error) }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(webView, error) }
  private func failed(_ view: WKWebView, _ error: Error) {
    guard let s = active, s.view === view else { return }
    if (error as NSError).code == NSURLErrorCancelled { return }
    invalidate(s); event(s, "failed"); beginClose(s)
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard let s = active, s.view === webView else { return }
    event(s, "failed"); beginClose(s)
  }
  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let s = active, s.view === webView, !s.isClosing, let url = action.request.url else { decisionHandler(.cancel); return }
    if action.targetFrame == nil { diagnostic(s, "popupBlocked", url); decisionHandler(.cancel); return }
    if action.shouldPerformDownload { diagnostic(s, "downloadBlocked", url); decisionHandler(.cancel); return }
    if action.targetFrame?.isMainFrame == false && url.absoluteString == "about:blank" { decisionHandler(.allow); return }
    guard s.policy.allows(url) else {
      let main = action.targetFrame?.isMainFrame == true
      diagnostic(s, !["https", "http"].contains(url.scheme ?? "") ? "externalProtocolBlocked" : main ? "topNavigationBlocked" : "frameNavigationBlocked", url)
      if main { invalidate(s); event(s, "blocked") }
      decisionHandler(.cancel); return
    }
    decisionHandler(.allow)
  }
  func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
               decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    guard let s = active, s.view === webView, let url = response.response.url,
          s.policy.allows(url) else { decisionHandler(.cancel); return }
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
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
  func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
  func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
               defaultText: String?, initiatedByFrame frame: WKFrameInfo,
               completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }
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
          let url = message.frameInfo.request.url, s.policy.allows(url) else { return }
    invalidate(s)
    if s.finished && s.view?.isLoading == false { establish(s) }
  }
  private static let jwNavigationNotices = #"""
    (()=>{'use strict'; if(window!==window.top)return;
      const send=()=>{try{window.webkit.messageHandlers.ustcI2Revoke.postMessage('history');}catch(_){}};
      for(const name of ['pushState','replaceState']) {
        const original=History.prototype[name];
        try{Object.defineProperty(History.prototype,name,{configurable:true,writable:true,
          value:function(){try{return Reflect.apply(original,this,arguments);}finally{send();}}});}catch(_){send();}
      }
    })();
    """#

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
    raw(s, code, world: .page) { _ in reply(nil) }
  }
#endif
}

@MainActor private final class SchoolHostController: UIViewController {
  private var webView: WKWebView?
  private let onReturn: () -> Void, onCancel: () -> Void
  init(webView: WKWebView, source: String, onReturn: @escaping () -> Void, onCancel: @escaping () -> Void) {
    self.webView = webView; self.onReturn = onReturn; self.onCancel = onCancel
    super.init(nibName: nil, bundle: nil)
    title = source == "jw" ? "教务 · 手动登录" : "二课 · 手动登录"
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func viewDidLoad() {
    super.viewDidLoad(); view.backgroundColor = .systemBackground
    navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消同步", style: .plain, target: self, action: #selector(cancel))
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: "返回应用", style: .done, target: self, action: #selector(back))
    if let webView {
      view.addSubview(webView); webView.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        webView.leadingAnchor.constraint(equalTo: view.leadingAnchor), webView.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
    }
  }
  func detachView() { webView?.removeFromSuperview(); webView = nil }
  @objc private func back() { onReturn() }
  @objc private func cancel() { onCancel() }
}
