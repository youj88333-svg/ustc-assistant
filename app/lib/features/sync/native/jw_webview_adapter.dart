// M7: `JwWebViewAdapter` — the real Windows WebView2 implementation of the
// JW collector's `JwWebPage`, replacing the M5 stub.
//
// It drives a `WebviewController` (via the self-contained
// `webview_flutter_windows_secure` plugin) through the navigation policy,
// three-signal convergence, registered-script extraction, and the CAS login
// flow — distilling the full rewrite branch's `WindowsBrowserAutomation` /
// `WebSessionEngine` lessons into a single minimal adapter (see
// `docs/plan-webview-minimal-m7-webview2.md`).
//
// Privacy rules (AGENTS.md red lines):
//   - Scripts only return normalized booleans/data; never account plaintext,
//     cookies, query, tickets, or raw DOM.
//   - Secret bytes are zeroed by the registered-script wrapper.
//   - Diagnostics use stage names + stable error codes only.
//
// The controller seam (`JwWebviewControllerFactory`) keeps this file testable
// without a real WebView (see `app/test/features/sync/native/jw_webview_adapter_test.dart`).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:webview_flutter_windows_secure/webview_flutter_windows.dart';

import 'jw_web_page.dart';
import 'jw_web_session.dart';

// Constructor parameters keep public-facing names (not private-field
// initializing formals) for a leaner API; the lint is cosmetic only.
// ignore_for_file: prefer_initializing_formals

/// Produces a fresh initialized [JwWebviewController] (the platform seam).
typedef JwWebviewControllerFactory = Future<JwWebviewController> Function();

/// Creates the gateway-owned production controller for one account UDF.
///
/// [userDataPath] is intentionally nullable so the production implementation
/// can use the plugin default profile when no account partition resolver is
/// configured. [safeDiagnostic] receives stage names only; implementations
/// must never report the physical UDF path or account identity.
typedef ProductionJwControllerFactory =
    Future<JwWebviewController> Function({
      required String? userDataPath,
      required void Function(String) safeDiagnostic,
    });

/// Production seam over the plugin's `WebviewController`. Configures the
/// native navigation policy (allowlist + deny downloads/windows/permissions)
/// and owns the URL snapshot subscription.
class ProductionJwWebviewController implements JwWebviewController {
  ProductionJwWebviewController(this._controller);

  final WebviewController _controller;
  StreamSubscription<String>? _urlSub;
  String? _currentUrl;

  @override
  Stream<String> get urlChanges => _controller.url;

  @override
  String? get currentUrlSnapshot => _currentUrl;

  @override
  Stream<JwLoadingState> get loadingStateChanges =>
      _controller.loadingState.map(_mapLoading);

  @override
  Stream<Object?> get webMessages => _controller.webMessage;

  @override
  Widget get surface => Webview(_controller);

  @override
  Future<void> awaitEventStreamReady() => _controller.awaitEventStreamReady();

  @override
  Future<void> loadUrl(String url) => _controller.loadUrl(url);

  @override
  Future<Object?> executeScript(String source) =>
      _controller.executeScript(source);

  @override
  Future<void> dispatchPrimaryClick(Offset position) =>
      _controller.dispatchPrimaryClick(position);

  @override
  Future<void> stop() => _controller.stop();

  @override
  Future<void> clearBrowsingDataAll() => _controller.clearBrowsingDataAll();

  @override
  Future<void> dispose() async {
    await _urlSub?.cancel();
    _urlSub = null;
    await _controller.dispose();
  }

  /// Must be called after initialization to start the URL snapshot.
  Future<void> beginUrlSnapshot() async {
    _urlSub ??= _controller.url.listen((url) => _currentUrl = url);
    await _controller.awaitEventStreamReady().timeout(
      const Duration(seconds: 5),
    );
  }

  /// Configures the native navigation/deny policies.
  Future<void> configurePolicies() async {
    await _controller.setNavigationPolicy(
      allowedOrigins: jwAllowedOrigins,
      allowedPathPrefixes: jwAllowedPathPrefixes,
    );
    await _controller.denyDownloads();
    await _controller.denyNewWindows();
    await _controller.denyPermissions();
  }

  static JwLoadingState _mapLoading(LoadingState state) => switch (state) {
    LoadingState.none => JwLoadingState.none,
    LoadingState.loading => JwLoadingState.loading,
    LoadingState.navigationCompleted => JwLoadingState.navigationCompleted,
  };
}

/// Production controller factory: create + initialize a `WebviewController`,
/// start the URL snapshot, and configure the native policies.
///
/// Mirrors the full-branch controller factory's ordering (configure the user
/// data folder BEFORE controller creation; subscribe before use). Each step
/// emits a privacy-safe stage via [safeDiagnostic] so a freeze or failure in
/// the native creation path is attributable by "last successful stage".
Future<JwWebviewController> createProductionJwWebviewController({
  String? userDataPath,
  void Function(String)? safeDiagnostic,
}) async {
  void diag(String stage) {
    try {
      safeDiagnostic?.call(stage);
    } on Object {
      // Diagnostics must never break creation.
    }
  }

  diag('controller_factory:start');
  if (userDataPath != null && userDataPath.isNotEmpty) {
    diag('controller_factory:environment_configure');
    await WebviewController.initializeEnvironment(userDataPath: userDataPath);
  }
  final raw = WebviewController();
  var handedOff = false;
  try {
    diag('controller_factory:controller_initialize');
    await raw.initialize();
    final controller = ProductionJwWebviewController(raw);
    // Start the URL snapshot subscription before any navigation so a fast
    // landing page cannot be missed (lesson 3.2 / three-signal convergence).
    diag('controller_factory:url_snapshot');
    await controller.beginUrlSnapshot();
    diag('controller_factory:policies');
    await controller.configurePolicies();
    diag('controller_factory:ready');
    handedOff = true;
    return controller;
  } finally {
    if (!handedOff) {
      diag('controller_factory:aborted');
      await raw.dispose();
    }
  }
}

/// The real Windows WebView2 `JwWebPage`.
///
/// One adapter owns one initialized controller (created lazily on first
/// navigation). `close()` disposes the controller and clears browsing data so
/// a cold restart starts from a clean login (session persistence is not
/// supported — the documented minimal boundary). The WebView surface is always
/// visible so the user can complete CAPTCHA/MFA or review the login progress.
class JwWebViewAdapter implements JwWebPage {
  JwWebViewAdapter({
    required JwWebviewControllerFactory controllerFactory,
    Duration loginTimeout = defaultLoginTimeout,
    Duration responseTimeout = defaultResponseTimeout,
    Duration casFormWaitTimeout = const Duration(seconds: 45),
    void Function(String)? safeDiagnostic,
  }) : _loginTimeout = loginTimeout,
       _responseTimeout = responseTimeout,
       _casFormWaitTimeout = casFormWaitTimeout,
       _safeDiagnostic = safeDiagnostic,
       _controllerFactory = controllerFactory;

  final JwWebviewControllerFactory _controllerFactory;
  final Duration _loginTimeout;
  final Duration _responseTimeout;
  final Duration _casFormWaitTimeout;
  final void Function(String)? _safeDiagnostic;

  JwWebviewController? _controller;
  bool _disposed = false;
  bool _loginConsumed = false;

  /// True after [close]. A closed shared-mode adapter must not be reused.
  bool get isDisposed => _disposed;

  /// The visible WebView surface (or a placeholder before the controller is
  /// created). The caller embeds this into the sync page.
  Widget? get surface => _controller?.surface;

  void _diag(String event) {
    try {
      _safeDiagnostic?.call(event);
    } on Object {
      // Diagnostics must never break collection.
    }
  }

  Future<JwWebviewController> _ensureController() async {
    if (_disposed) {
      throw const JwCollectionException('webview adapter is closed');
    }
    final existing = _controller;
    if (existing != null) return existing;
    final created = await _controllerFactory();
    _controller = created;
    return created;
  }

  /// Navigates [url] and waits for the native loading state to complete.
  /// Validates the URL against the compile-time allowlist first (defense in
  /// depth; the native policy is the primary guard).
  Future<void> _navigate(String url) async {
    final controller = await _ensureController();
    if (!isJwNavigationAllowed(url)) {
      _diag('navigation_rejected');
      throw const JwCollectionException('navigation policy rejected');
    }
    final done = Completer<void>();
    late final StreamSubscription<JwLoadingState> loadingSub;
    loadingSub = controller.loadingStateChanges.listen((state) {
      if (state == JwLoadingState.navigationCompleted && !done.isCompleted) {
        done.complete();
      }
    });
    try {
      await controller.loadUrl(url);
      await done.future.timeout(
        _responseTimeout,
        onTimeout: () =>
            throw const JwCollectionException('navigation did not complete'),
      );
    } finally {
      await loadingSub.cancel();
    }
  }

  @override
  Future<String> get currentUrl async {
    final controller = await _ensureController();
    return controller.currentUrlSnapshot ?? '';
  }

  @override
  Future<void> gotoRoot() => _navigate(jwRootUrl);

  @override
  Future<void> gotoCasEntry() => _navigate(casEntryUrl);

  @override
  Future<void> gotoCourseTable() => _navigate(courseEntryUrl);

  @override
  Future<void> gotoExamArrange() => _navigate(examEntryUrl);

  @override
  Future<bool> get isAuthenticatedHome async {
    final url = await currentUrl;
    return isAuthenticatedHomeUrl(url);
  }

  // --- CAS login ------------------------------------------------------------
  //
  // The collector drives: gotoRoot -> (not home) gotoCasEntry -> (not home)
  // emit needsUserLogin -> resumeLogin -> fillLogin -> waitForAuthenticatedHome.
  //
  // `fillLogin` is the single place that can surface `account_mismatch` (the
  // collector only catches `JwAccountMismatchException` around fillLogin), so
  // it performs the complete login: activate the SSO entry, wait for the CAS
  // form, fill username (+password), submit, await the natural /home return,
  // then run the identity proof. Secrets are zeroed by the script wrapper.

  @override
  Future<void> fillLogin(LoginCredentials credentials) async {
    final username = credentials.username.trim();
    if (username.isEmpty) {
      throw const JwAccountMismatchException('username is required');
    }
    // Full-branch semantics (jw_login_flow.dart): one-shot protection guards
    // the in-flight ticket, not the login ACTION. Each collector attempt may
    // start a fresh fill; the guard re-arms on entry and re-arms again after
    // a completed waitForAuthenticatedHome.
    final alreadyInFlight = _loginConsumed;
    _loginConsumed = true;
    if (alreadyInFlight) {
      _diag('login_restarted');
    }

    final controller = await _ensureController();
    var current = controller.currentUrlSnapshot ?? '';

    // 1. Are we already on the real CAS form (id.ustc.edu.cn)? The collector's
    //    gotoCasEntry navigates to jw.ustc.edu.cn/ucas-sso/login; after a
    //    previous activation we may already be on CAS.
    var onCasForm = _isCasFormHost(current);
    if (!onCasForm) {
      // 2. Ensure we are on the JW SSO login entry. The collector usually
      //    already landed on `/ucas-sso/login`; only navigate (fresh) when we
      //    are not on the jw.ustc.edu.cn login family.
      final onJwLoginEntry = _isJwLoginEntryUrl(current);
      if (!onJwLoginEntry) {
        _diag('attempt:jw.portal.login');
        await _converge(
          target: const JwReadyTarget(
            id: 'jw.portal.login',
            url: casEntryUrl,
            urlPattern: 'https://jw.ustc.edu.cn/ucas-sso*',
            readySelector: 'button, a[href*="sso"], a[href*="cas"]',
          ),
          timeout: _loginTimeout,
          command: () => controller.loadUrl(casEntryUrl),
        );
      } else {
        // Already on the entry (either /ucas-sso or /login); the SSO trigger
        // is present and we can go straight to activation.
        _diag('attempt:jw.portal.login');
      }

      // 3+4. Arm the CAS-form readiness, then activate the SSO transition by
      //      clicking the visible entry trigger (listen-before-navigate). The
      //      real credential form only lives at id.ustc.edu.cn/cas/login — the
      //      login entry page merely hosts the 统一身份认证 button.
      _diag('waiting_for_cas_form');
      await _converge(
        target: const JwReadyTarget(
          id: 'jw.cas.login',
          url: 'https://id.ustc.edu.cn/cas/login',
          urlPattern: 'https://id.ustc.edu.cn/cas/login*',
          readySelector: 'input[name="username"], input[type="password"]',
        ),
        timeout: _loginTimeout,
        command: _clickSsoEntry,
      );
      current = controller.currentUrlSnapshot ?? '';
      onCasForm = _isCasFormHost(current);
    } else {
      _diag('reusing_cas_form');
    }

    // 5. Stale-form guard (evidence only, never fail-closed — the full-branch
    //    flow has no pre-submit rejection; fillUsername OVERWRITES whatever
    //    the form remembers, and the real account check is the post-login
    //    identity proof). A missing probe (null) or a non-empty stale value
    //    both mean the current document is NOT a usable credential form
    //    (bare /cas/login redirects to a form-less page; CAS may also
    //    remember the last account). Recovery ALWAYS reruns the SSO entry
    //    activation (entry page → 统一身份认证 click → CAS form with the
    //    service param) — never a bare /cas/login reload, whose converge
    //    would fire on stale signals of the old document.
    final preSet = await _readPreselectedAccount(controller);
    // Privacy-safe evidence only: presence + lengths, never the text.
    _diag(
      preSet == null
          ? 'preselect_absent'
          : 'preselect_present:${preSet.trim().length}'
                '/expected:${username.trim().length}'
                '/equal:${preSet.trim().isNotEmpty && _accountsEqual(preSet, username)}',
    );
    final staleOrBroken =
        onCasForm &&
        (preSet == null ||
            (preSet.trim().isNotEmpty && !_accountsEqual(preSet, username)));
    if (staleOrBroken) {
      _diag('stale_cas_form_reloading');
      await _activateSsoEntryAndAwaitForm(controller);
    }

    // 6. Fill username (always) and password (when provided).
    await _fillSecret(controller, 'jw.cas.fillUsername', username);
    final password = credentials.password;
    if (password != null && password.isNotEmpty) {
      await _fillSecret(controller, 'jw.cas.fillPassword', password);
    }

    // 7. Submit the form (single CAS activation; never replay).
    _diag('activationDispatched');
    final submitResult = await executeRegisteredScript(
      controller,
      scriptId: 'jw.cas.submit',
      args: const <String, Object?>{},
      timeout: _loginTimeout,
      safeDiagnostic: _safeDiagnostic,
    );
    if (submitResult['submitted'] != true) {
      throw const JwCollectionException('CAS submit was not acknowledged');
    }

    // 8. Await the natural /home return (the browser redirects on its own;
    //    we never re-navigate to a CAS callback ourselves).
    await _converge(
      target: const JwReadyTarget(
        id: 'jw.portal.home',
        url: 'https://jw.ustc.edu.cn/home',
        urlPattern: 'https://jw.ustc.edu.cn/home*',
        handshakeScriptId: 'jw.cas.inspect',
      ),
      timeout: _loginTimeout,
    );

    // 9. Identity proof: scripts only return matched/conflicted booleans; any
    //    authoritative conflict fails closed as account_mismatch.
    await _verifyIdentity(controller, username);
  }

  bool _accountsEqual(String a, String b) =>
      a.trim().toLowerCase() == b.trim().toLowerCase();

  Future<String?> _readPreselectedAccount(
    JwWebviewController controller,
  ) async {
    Object? value;
    try {
      value = await controller.executeScript(
        '(document.querySelector("input[name=username], #username")||{value:""}).value;',
      );
    } on Object {
      return null;
    }
    return value is String ? value : null;
  }

  /// Fills a CAS field with [secret] bytes. A `missing_selector` /
  /// `wrong_target` failure usually means the script raced a document switch
  /// (the probe/converge signals fired on the OLD document) — recover by
  /// re-running the SSO entry activation once inside the timeout budget
  /// (full-branch lesson: ExecuteScript failures during document switches are
  /// retried within the timeout, never treated as final).
  Future<void> _fillSecret(
    JwWebviewController controller,
    String scriptId,
    String secret,
  ) async {
    final bytes = Uint8List.fromList(utf8.encode(secret));
    try {
      try {
        await executeRegisteredScript(
          controller,
          scriptId: scriptId,
          args: <String, Object?>{'secretBytes': bytes},
          timeout: _responseTimeout,
          safeDiagnostic: _safeDiagnostic,
        );
        return;
      } on JwCollectionException catch (error) {
        final text = error.message ?? '';
        final recoverable =
            text.contains('missing_selector') || text.contains('wrong_target');
        if (!recoverable) rethrow;
        _diag('fill_race_retry:$scriptId');
      }
      // One recovery attempt: fresh SSO activation → CAS form → fill again.
      await _activateSsoEntryAndAwaitForm(controller);
      await executeRegisteredScript(
        controller,
        scriptId: scriptId,
        args: <String, Object?>{'secretBytes': bytes},
        timeout: _responseTimeout,
        safeDiagnostic: _safeDiagnostic,
      );
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  /// Shared SSO-entry activation used by both the initial CAS-form wait and
  /// the fill-race recovery: entry page → 统一身份认证 click → CAS form.
  Future<void> _activateSsoEntryAndAwaitForm(
    JwWebviewController controller,
  ) async {
    await _converge(
      target: const JwReadyTarget(
        id: 'jw.portal.login',
        url: casEntryUrl,
        urlPattern: 'https://jw.ustc.edu.cn/ucas-sso*',
        readySelector: 'button, a[href*="sso"], a[href*="cas"]',
      ),
      timeout: _loginTimeout,
      command: () => controller.loadUrl(casEntryUrl),
    );
    try {
      await _converge(
        target: const JwReadyTarget(
          id: 'jw.cas.login',
          url: 'https://id.ustc.edu.cn/cas/login',
          urlPattern: 'https://id.ustc.edu.cn/cas/login*',
          readySelector: 'input[name="username"], input[type="password"]',
        ),
        timeout: _casFormWaitTimeout,
        command: _clickSsoEntry,
      );
    } on JwCollectionException {
      // The CAS form never showed the expected inputs. Capture the real DOM
      // shape (privacy-safe: counts/types only) so the contract mismatch is
      // attributable, then rethrow for the caller's retry/failure path.
      await _diagCasFormShape(controller);
      rethrow;
    }
    // Privacy-safe DOM reconnaissance (once, on convergence): shapes only —
    // element counts, input types, iframe presence. Never text/values.
    await _diagCasFormShape(controller);
  }

  /// One-shot privacy-safe DOM shape probe (element counts and input types
  /// only — never values or text). Answers "what does the real CAS page
  /// actually render" without leaking anything.
  Future<void> _diagCasFormShape(JwWebviewController controller) async {
    try {
      final shape = await controller.executeScript('''
(() => {
  const inputs = Array.from(document.querySelectorAll("input"));
  const iframes = document.querySelectorAll("iframe").length;
  return {
    inputCount: inputs.length,
    inputTypes: inputs.map((el) => el.type || "?").join(","),
    inputNames: inputs.map((el) => el.name || el.id || "-").join(","),
    hasUsernameField: !!document.querySelector('input[name="username"], #username'),
    hasPasswordField: !!document.querySelector('input[type="password"]'),
    iframeCount: iframes,
    readyState: document.readyState,
    path: location.pathname
  };
})()
''');
      if (shape is Map) {
        _diag(
          'cas_form_shape:'
          'inputs=${shape['inputCount']}'
          '/names=${shape['inputNames']}'
          '/types=${shape['inputTypes']}'
          '/user=${shape['hasUsernameField']}'
          '/pass=${shape['hasPasswordField']}'
          '/iframes=${shape['iframeCount']}'
          '/rs=${shape['readyState']}'
          '/path=${shape['path']}',
        );
      }
    } on Object {
      // Reconnaissance is best effort.
    }
  }

  Future<void> _verifyIdentity(
    JwWebviewController controller,
    String expectedUsername,
  ) async {
    final expectedBytes = Uint8List.fromList(utf8.encode(expectedUsername));
    try {
      final result = await executeRegisteredScript(
        controller,
        scriptId: 'jw.identity.verifyExpected',
        args: <String, Object?>{'expectedIdentityBytes': expectedBytes},
        timeout: _loginTimeout,
        safeDiagnostic: _safeDiagnostic,
      );
      final row = JwIdentityProof(
        authoritativeMatched: result['authoritativeMatched'] == true,
        authoritativeConflicted: result['authoritativeConflicted'] == true,
        domMatched: result['domMatched'] == true,
        domConflicted: result['domConflicted'] == true,
        storageMatched: result['storageMatched'] == true,
        storageConflicted: result['storageConflicted'] == true,
      );
      if (row.authoritativeConflicted ||
          (!row.authoritativeMatched &&
              (row.domConflicted || row.storageConflicted))) {
        // Booleans only — never account text (red line).
        _diag(
          'identity_verification_conflicted'
          ':auth=${row.authoritativeMatched}'
          '/dom=${row.domMatched}'
          '/storage=${row.storageMatched}'
          '/domConflict=${row.domConflicted}'
          '/storageConflict=${row.storageConflicted}',
        );
        throw JwAccountMismatchException(
          'authenticated account does not match the expected username',
        );
      }
      if (!row.authoritativeMatched) {
        // No authoritative evidence found — the page may still be settling.
        // Only fail closed when it is an explicit conflict (account_mismatch),
        // otherwise the collection proceeds and the collector re-checks home.
        _diag('identity_verification_uncertain');
      }
    } finally {
      expectedBytes.fillRange(0, expectedBytes.length, 0);
    }
  }

  @override
  Future<void> waitForAuthenticatedHome(Duration timeout) async {
    await _converge(
      target: const JwReadyTarget(
        id: 'jw.portal.home',
        url: 'https://jw.ustc.edu.cn/home',
        urlPattern: 'https://jw.ustc.edu.cn/home*',
        handshakeScriptId: 'jw.cas.inspect',
      ),
      timeout: timeout,
      onTimeout: () => throw JwLoginTimeoutException(
        'USTC JW login was not completed before timeout',
      ),
    );
    // The one-shot CAS ticket has been consumed and the session is on /home:
    // allow a future job of the shared controller to log in again (replay
    // protection only guards the in-flight login, not a completed one).
    _loginConsumed = false;
  }

  // --- collection -------------------------------------------------------------

  @override
  Future<String> resolveCourseDataId(Duration timeout) async {
    final controller = await _ensureController();
    // Navigate to the course table (listen-before-navigate); the page issues
    // the get-data request on load, and the registration script reads its
    // dataId from the performance entry (mirrors Python `expect_response` +
    // `extract_data_id`).
    await _converge(
      target: const JwReadyTarget(
        id: 'jw.course.home',
        url: courseEntryUrl,
        urlPattern: 'https://jw.ustc.edu.cn/for-std/course-table*',
        readySelector: 'body',
      ),
      timeout: timeout,
      command: () => controller.loadUrl(courseEntryUrl),
    );
    final result = await executeRegisteredScript(
      controller,
      scriptId: 'jw.course.readContext',
      args: const <String, Object?>{},
      timeout: timeout,
      safeDiagnostic: _safeDiagnostic,
    );
    final dataId = result['dataId'];
    if (dataId is! String || dataId.isEmpty) {
      throw const JwCollectionException(
        'course page did not expose a data context',
      );
    }
    _diag('course_context_read');
    return dataId;
  }

  @override
  Future<Map<String, dynamic>> fetchCourseDatum({
    required int semesterId,
    required String dataId,
    required String referer,
  }) async {
    final controller = await _ensureController();
    // GET get-data for lessonIds (JSON, X-Requested-With), matching the
    // Python `fetch_course_datum` request shape (lesson 3.7).
    final getDataResult = await executeRegisteredScript(
      controller,
      scriptId: 'jw.course.fetchGetData',
      args: <String, Object?>{'semesterId': semesterId, 'dataId': dataId},
      timeout: _responseTimeout,
      safeDiagnostic: _safeDiagnostic,
    );
    final getDataText = getDataResult['text'];
    if (getDataText is! String) {
      throw const JwCollectionException('course get-data returned no text');
    }
    final getData = parseJsonObject(getDataText, endpoint: 'course get-data');
    final lessonIds = getData['lessonIds'];
    if (lessonIds is! List || lessonIds.isEmpty) {
      throw const JwCollectionException(
        'course get-data response is missing lessonIds',
      );
    }
    _diag('get_data_fetched');

    // POST datum (JSON body + X-Requested-With), matching Python (cannot be
    // form-encoded).
    final datumResult = await executeRegisteredScript(
      controller,
      scriptId: 'jw.course.fetchDatum',
      args: <String, Object?>{'lessonIds': lessonIds},
      timeout: _responseTimeout,
      safeDiagnostic: _safeDiagnostic,
    );
    final datumText = datumResult['text'];
    if (datumText is! String || datumText.isEmpty) {
      throw const JwCollectionException('course datum returned no data');
    }
    _diag('datum_fetched');
    return parseJsonObject(datumText, endpoint: 'course datum');
  }

  @override
  Future<String> fetchExamHtml(Duration timeout) async {
    final controller = await _ensureController();
    await _converge(
      target: const JwReadyTarget(
        id: 'jw.exam.list',
        url: examEntryUrl,
        urlPattern: 'https://jw.ustc.edu.cn/for-std/exam-arrange*',
        readySelector: 'table#exams',
      ),
      timeout: timeout,
      command: () => controller.loadUrl(examEntryUrl),
    );
    final result = await executeRegisteredScript(
      controller,
      scriptId: 'jw.exam.readTable',
      args: const <String, Object?>{},
      timeout: timeout,
      safeDiagnostic: _safeDiagnostic,
    );
    final html = result['html'];
    if (html is! String || html.isEmpty) {
      throw const JwCollectionException(
        'exam page did not contain table#exams',
      );
    }
    return html;
  }

  /// Converges [target]'s three signals. Default timeout error is
  /// [JwCollectionException]; [JwReadyTarget.id] `jw.portal.home` maps to
  /// [JwLoginTimeoutException] so the collector reports `login_timeout`.
  Future<void> _converge({
    required JwReadyTarget target,
    required Duration timeout,
    void Function()? onTimeout,
    Future<void> Function()? command,
  }) async {
    final controller = await _ensureController();
    try {
      await convergeTarget(
        controller,
        target,
        timeout: timeout,
        safeDiagnostic: _safeDiagnostic,
        command: command,
      );
    } on TimeoutException {
      onTimeout?.call();
      throw const JwCollectionException('target did not become ready in time');
    }
  }

  /// Clicks the SSO entry (统一身份认证) using the native primary-click path
  /// with a geometry/visibility check (lesson 3.2: not just `element.click()`).
  Future<void> _clickSsoEntry() async {
    final controller = await _ensureController();
    final geometry = await controller.executeScript('''
(() => {
  const candidates = Array.from(document.querySelectorAll(
    'a[href*="/ucas-sso"], a[href*="/cas"], button'
  ));
  const find = () => {
    const visible = candidates.find((el) => {
      if (!el || !el.isConnected) return false;
      const style = window.getComputedStyle(el);
      if (style.display === 'none' || style.visibility === 'hidden' ||
          Number(style.opacity) <= 0) return false;
      const text = (el.textContent || el.getAttribute('aria-label') || '').trim();
      if (!/统一|登录|认证|sso|cas/i.test(text)) return false;
      return true;
    });
    return visible || null;
  };
  const element = find();
  if (!element) return null;
  element.scrollIntoView({block: 'center', inline: 'center'});
  const rect = element.getBoundingClientRect();
  const x = rect.left + rect.width / 2;
  const y = rect.top + rect.height / 2;
  const hit = document.elementFromPoint(x, y);
  return {
    x,
    y,
    width: rect.width,
    height: rect.height,
    visible: true,
    unobscured: hit === element || element.contains(hit)
  };
})()
''');
    final point = _validatedClickPoint(geometry);
    await controller.dispatchPrimaryClick(point);
    _diag('activation_dispatched');
  }

  /// Validates the click geometry script output. Rejects if not visible or
  /// unobscured (mirrors the full branch's `_validatedClickPoint`).
  Offset _validatedClickPoint(Object? value) {
    if (value is! Map ||
        value['visible'] != true ||
        value['unobscured'] != true) {
      throw const JwCollectionException('login entry is not actionable');
    }
    final x = value['x'];
    final y = value['y'];
    final width = value['width'];
    final height = value['height'];
    if (x is! num ||
        y is! num ||
        width is! num ||
        height is! num ||
        x <= 0 ||
        y <= 0 ||
        width <= 0 ||
        height <= 0) {
      throw const JwCollectionException('login entry geometry is invalid');
    }
    final dx = x.toDouble();
    final dy = y.toDouble();
    if (!dx.isFinite || !dy.isFinite || dx < 0 || dy < 0) {
      throw const JwCollectionException('login entry geometry is invalid');
    }
    return Offset(dx, dy);
  }

  /// True iff [url] is on the CAS host (`id.ustc.edu.cn`), where the real
  /// credential form lives.
  bool _isCasFormHost(String url) {
    final parsed = Uri.tryParse(url);
    return parsed != null &&
        parsed.scheme == 'https' &&
        parsed.host == 'id.ustc.edu.cn';
  }

  /// True iff [url] is a jw.ustc.edu.cn SSO login entry path (`/ucas-sso` or
  /// `/login`).
  bool _isJwLoginEntryUrl(String url) {
    final parsed = Uri.tryParse(url);
    return parsed != null &&
        parsed.scheme == 'https' &&
        parsed.host == jwHost &&
        (parsed.path.startsWith('/ucas-sso') ||
            parsed.path.startsWith('/login') ||
            parsed.path == '/');
  }

  @override
  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    try {
      await controller.stop();
      await controller.clearBrowsingDataAll();
    } on Object {
      // Browsing-data cleanup is best effort.
    }
    await controller.dispose();
  }
}

/// Structured identity-proof result (booleans only, no account plaintext).
class JwIdentityProof {
  const JwIdentityProof({
    required this.authoritativeMatched,
    required this.authoritativeConflicted,
    required this.domMatched,
    required this.domConflicted,
    required this.storageMatched,
    required this.storageConflicted,
  });

  final bool authoritativeMatched;
  final bool authoritativeConflicted;
  final bool domMatched;
  final bool domConflicted;
  final bool storageMatched;
  final bool storageConflicted;
}
