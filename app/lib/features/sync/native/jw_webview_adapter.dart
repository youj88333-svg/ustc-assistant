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
  String? _pendingExpectedUsername;

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
  Future<void> gotoCasEntry() async {
    final controller = await _ensureController();
    await _converge(
      target: portalLoginTarget,
      timeout: _loginTimeout,
      command: () => controller.loadUrl(portalLoginTarget.url),
    );
  }

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
  // `fillLogin` performs only the side-effecting portal -> CAS transition,
  // credential fill, and one submit. The collector deliberately calls
  // `waitForAuthenticatedHome` afterwards; that method owns the bounded home
  // convergence and identity proof so its timeout maps to login_timeout.

  @override
  Future<void> fillLogin(LoginCredentials credentials) async {
    final username = credentials.username.trim();
    if (username.isEmpty) {
      throw const JwAccountMismatchException('username is required');
    }
    // A pending credential attempt cannot be replayed in place: a second call
    // would otherwise dispatch another native click or CAS submit. The guard
    // is cleared only when waitForAuthenticatedHome settles the attempt.
    final alreadyInFlight = _loginConsumed;
    _loginConsumed = true;
    if (alreadyInFlight) {
      _diag('login_already_in_flight');
      throw const JwCollectionException('login attempt is already in flight');
    }

    final controller = await _ensureController();
    final current = controller.currentUrlSnapshot ?? '';

    // Prepare the exact portal login target before the one native primary
    // click. An already prepared target is only revalidated; a different
    // document is navigated to the trusted `/login` entry first.
    final onPortalLogin = portalLoginTarget.urlMatches(current);
    if (!onPortalLogin) {
      // Navigate to the trusted `/login` entry when the current document is
      // not already in the exact portal target family.
      _diag('attempt:jw.portal.login');
      await _converge(
        target: portalLoginTarget,
        timeout: _loginTimeout,
        command: () => controller.loadUrl(portalLoginTarget.url),
      );
    } else {
      await _converge(target: portalLoginTarget, timeout: _loginTimeout);
    }

    _diag('waiting_for_cas_form');
    await _converge(
      target: casLoginTarget,
      timeout: _casFormWaitTimeout,
      command: _clickSsoEntry,
    );

    // Fill username (always) and password (when provided).
    await _fillSecret(controller, 'jw.cas.fillUsername', username);
    final password = credentials.password;
    if (password != null && password.isNotEmpty) {
      await _fillSecret(controller, 'jw.cas.fillPassword', password);
    }

    // Submit the form once; never replay a side-effecting authentication
    // action in this attempt.
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
    // The browser follows the CAS callback naturally. Do not wait for a home
    // URL here: retaining the expected identity makes the later wait the only
    // owner of home convergence and identity cleanup.
    _pendingExpectedUsername = username;
  }

  /// Fills a CAS field with [secret] bytes. Selector polling may retry while
  /// a document is being replaced, but this side-effecting credential action
  /// itself is never replayed.
  Future<void> _fillSecret(
    JwWebviewController controller,
    String scriptId,
    String secret,
  ) async {
    final bytes = Uint8List.fromList(utf8.encode(secret));
    try {
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
      if (!row.verified) {
        // Booleans only — never account text (red line).
        _diag(
          'identity_verification_conflicted'
          ':auth=${row.authoritativeMatched}'
          '/authConflict=${row.authoritativeConflicted}'
          '/dom=${row.domMatched}'
          '/storage=${row.storageMatched}'
          '/domConflict=${row.domConflicted}'
          '/storageConflict=${row.storageConflicted}',
        );
        throw JwAccountMismatchException(
          'authenticated account does not match the expected username',
        );
      }
    } finally {
      expectedBytes.fillRange(0, expectedBytes.length, 0);
    }
  }

  @override
  Future<void> waitForAuthenticatedHome(Duration timeout) async {
    final expectedUsername = _pendingExpectedUsername;
    try {
      await _converge(
        target: portalHomeTarget,
        timeout: timeout,
        onTimeout: () => throw JwLoginTimeoutException(
          'USTC JW login was not completed before timeout',
        ),
      );
      if (expectedUsername == null || expectedUsername.isEmpty) {
        throw const JwCollectionException('login identity is not pending');
      }
      // Identity proof is authoritative and boolean-only. Any missing or
      // conflicting evidence fails closed as account_mismatch.
      final controller = await _ensureController();
      await _verifyIdentity(controller, expectedUsername);
    } finally {
      // Both successful and final failed waits consume the pending identity;
      // callers must begin a fresh trusted portal flow before retrying.
      _pendingExpectedUsername = null;
      _loginConsumed = false;
    }
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
      target: courseHomeTarget,
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
      target: examListTarget,
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
  // The wrapper is the only trusted portal activation target. Do not select
  // broad text/links/buttons: a different login-like element must never
  // receive a native click.
  const element = document.querySelector('#login-unified-wrapper');
  if (!element || element.id !== 'login-unified-wrapper' ||
      !element.isConnected) return null;
  const style = window.getComputedStyle(element);
  if (style.display === 'none' || style.visibility === 'hidden' ||
      Number(style.opacity) <= 0) return null;
  element.scrollIntoView({block: 'center', inline: 'center'});
  const rect = element.getBoundingClientRect();
  const x = rect.left + rect.width / 2;
  const y = rect.top + rect.height / 2;
  if (rect.width <= 0 || rect.height <= 0 ||
      rect.left < 0 || rect.top < 0 ||
      rect.right > window.innerWidth || rect.bottom > window.innerHeight ||
      x < 0 || y < 0 || x > window.innerWidth || y > window.innerHeight)
    return null;
  const hit = document.elementFromPoint(x, y);
  return {
    x,
    y,
    width: rect.width,
    height: rect.height,
    viewportWidth: window.innerWidth,
    viewportHeight: window.innerHeight,
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
    final viewportWidth = value['viewportWidth'];
    final viewportHeight = value['viewportHeight'];
    if (viewportWidth is num &&
        viewportHeight is num &&
        (viewportWidth <= 0 ||
            viewportHeight <= 0 ||
            dx > viewportWidth.toDouble() ||
            dy > viewportHeight.toDouble())) {
      throw const JwCollectionException('login entry geometry is invalid');
    }
    return Offset(dx, dy);
  }

  @override
  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    _pendingExpectedUsername = null;
    _loginConsumed = false;
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

  bool get verified =>
      authoritativeMatched &&
      !authoritativeConflicted &&
      !domConflicted &&
      !storageConflicted;
}
