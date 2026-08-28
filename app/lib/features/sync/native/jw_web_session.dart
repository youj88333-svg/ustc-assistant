// M7: `JwWebSession` — the minimal WebView2 session driver for the JW
// collector.
//
// This file is intentionally platform-local: it owns the closed vocabulary of
// USTC JW/CAS scripts, the compile-time navigation allowlist, and the
// three-signal convergence logic (URL + DOM + ready handshake, any order)
// distilled from the full rewrite branch's `WebSessionEngine` / `NavigationAttempt`
// but WITHOUT the C1/C2/C3 container layering (see
// `docs/plan-webview-minimal-m7-webview2.md` §2, "明确的取舍").
//
// Privacy rules (red lines, AGENTS.md §安全红线):
//   - Scripts return only normalized booleans/data (e.g. `matched`/`conflicted`
//     booleans, JSON text, HTML text). They NEVER return account plaintext,
//     cookies, query strings, CAS tickets, or raw DOM.
//   - Diagnostics/events only use stage names (`attempt`, `urlMatched`,
//     `domReady`, `readyHandshake`, `ready`, ...) and stable error codes; never
//     full URLs, query parameters, tickets, or account text.
//   - Secret bytes (username/password) are passed to scripts as `Uint8List` in
//     `args` and zeroed after use by the wrapper layer.
//
// The actual `WebviewController` plumbing lives in `jw_webview_adapter.dart`;
// this file stays testable with a faked controller seam (see the unit tests in
// `app/test/features/sync/native/jw_webview_adapter_test.dart`).

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';

import 'jw_web_page.dart';

// --- Navigation allowlist (compile-time, fail-closed) ----------------------
//
// Mirrors the full branch's `JwEndpointPolicy`. Host + allowed path prefixes.
// Unknown hosts/paths are rejected by the plugin's native synchronous policy
// (`setNavigationPolicy`), and this Dart side performs the same check for any
// URL it navigates to on its own (defense in depth).

/// The exact HTTPS origins the WebView is allowed to navigate to (top-level).
const List<String> jwAllowedOrigins = <String>[
  'https://jw.ustc.edu.cn',
  'https://passport.ustc.edu.cn',
  'https://analytics.ustc.edu.cn',
  'https://id.ustc.edu.cn',
];

/// Path prefixes allowed per origin. A navigation to a URL whose host is in
/// [jwAllowedOrigins] and whose path (or path prefix) is in this map is
/// allowed; everything else fails closed at the native policy layer and again
/// here when the Dart side initiates a navigation.
const Map<String, List<String>> jwAllowedPathPrefixes = <String, List<String>>{
  'https://jw.ustc.edu.cn': <String>[
    '/',
    '/home',
    '/login',
    '/ucas-sso',
    '/for-std/course-table',
    '/for-std/exam-arrange',
  ],
  'https://passport.ustc.edu.cn': <String>['/login'],
  'https://analytics.ustc.edu.cn': <String>['/.isg/gateway'],
  'https://id.ustc.edu.cn': <String>['/cas', '/.isg/gateway'],
};

/// True iff [url] is allowed by the compile-time navigation policy (host +
/// path prefix). Returns false for non-HTTPS, unknown hosts, or unknown paths.
///
/// The `/` prefix in [jwAllowedPathPrefixes] means "the origin root page
/// itself" (`https://jw.ustc.edu.cn/`), not a blanket allow-everything — this
/// predicate matches `/` only when the path is exactly `/` (or empty). The
/// plugin's native policy applies the prefixes at the navigation boundary; this
/// Dart-side predicate is a defensive stricter re-check (the native layer may
/// permit the `/` breadth for top-level preamble, but Dart navigation only
/// issues against known paths).
bool isJwNavigationAllowed(String url) {
  final Uri? parsed = Uri.tryParse(url);
  if (parsed == null ||
      parsed.scheme != 'https' ||
      parsed.host.isEmpty ||
      url.startsWith('http://')) {
    return false;
  }
  final origin = 'https://${parsed.host}';
  final prefixes = jwAllowedPathPrefixes[origin];
  if (prefixes == null) return false;
  final path = parsed.path;
  for (final prefix in prefixes) {
    if (prefix == '/') {
      // The `/` prefix only authorizes the exact origin root.
      if (path == '/' || path.isEmpty) return true;
      continue;
    }
    if (path == prefix || path.startsWith('$prefix/')) return true;
  }
  return false;
}

// --- Registered scripts (closed vocabulary) ---------------------------------
//
// Trimmed from the full branch's `jw_registered_scripts.dart`. Each script
// takes `args` (JSON) plus secret-bearing `Uint8List` arguments that are zeroed
// by the caller after execution. Scripts post results to
// `window.chrome.webview.postMessage` as `{kind, requestId, result|reason}`;
// the Dart side keys on `requestId` so results never depend on
// `executeScript`'s return value (which WebView2 can drop during document
// switches).

/// The safe script-failure reasons the wrapper accepts (any other failure
/// reason is mapped to `script_failed` and the result rejected). Kept in the
/// same closed set as the full branch.
const Set<String> safeScriptFailureReasons = <String>{
  'page_contract_changed',
  'missing_selector',
  'not_actionable',
  'wrong_target',
  'missing_semester_runtime',
  'invalid_semester_options',
  'missing_course_data_context',
  'response_too_large',
  'request_failed',
  'script_failed',
};

const String _casInspectScript = r'''
const deadline = Date.now() + 30000;
return new Promise((resolve, reject) => {
  const inspect = () => {
    if (document.readyState === 'complete') {
      const onCas = location.origin === 'https://id.ustc.edu.cn' &&
        location.pathname === '/cas/login';
      resolve({sessionHealthy: !onCas, needsUserLogin: onCas});
      return;
    }
    if (Date.now() >= deadline) {
      reject(new Error('page_contract_changed'));
      return;
    }
    setTimeout(inspect, 25);
  };
  inspect();
});
''';

const String _casFillUsernameScript = r'''
if (location.origin !== 'https://id.ustc.edu.cn' || location.pathname !== '/cas/login')
  throw new Error('wrong_target');
const field = document.querySelector('input[name="username"], #username');
if (!field) throw new Error('missing_selector');
field.value = new TextDecoder('utf-8', {fatal: true}).decode(Uint8Array.from(args.secretBytes));
field.dispatchEvent(new Event('input', {bubbles: true}));
field.dispatchEvent(new Event('change', {bubbles: true}));
return {filled: true};
''';

const String _casFillPasswordScript = r'''
if (location.origin !== 'https://id.ustc.edu.cn' || location.pathname !== '/cas/login')
  throw new Error('wrong_target');
const field = document.querySelector('input[type="password"]');
if (!field) throw new Error('missing_selector');
field.value = new TextDecoder('utf-8', {fatal: true}).decode(Uint8Array.from(args.secretBytes));
field.dispatchEvent(new Event('input', {bubbles: true}));
field.dispatchEvent(new Event('change', {bubbles: true}));
return {filled: true};
''';

const String _casSubmitScript = r'''
if (location.origin !== 'https://id.ustc.edu.cn' || location.pathname !== '/cas/login')
  throw new Error('wrong_target');
const submit = document.querySelector("#submitBtn, button.login-button");
if (!submit) throw new Error('missing_selector');
if (submit.disabled || submit.classList.contains('disabled'))
  throw new Error('not_actionable');
submit.click();
return {submitted: true};
''';

const String _identityProofScript = r'''
const expected = new TextDecoder('utf-8', {fatal: true})
  .decode(Uint8Array.from(args.expectedIdentityBytes)).trim().toLowerCase();
const exact = (candidate) => {
  if (typeof candidate !== 'string') return false;
  const text = candidate.trim().toLowerCase();
  if (text === expected) return true;
  try {
    const parsed = JSON.parse(candidate);
    const visit = (value, depth = 0) => {
      if (depth > 8) return false;
      if (typeof value === 'string') return value.trim().toLowerCase() === expected;
      if (Array.isArray(value)) return value.some((item) => visit(item, depth + 1));
      if (value && typeof value === 'object')
        return Object.values(value).some((item) => visit(item, depth + 1));
      return false;
    };
    return visit(parsed);
  } catch (_) { return false; }
};
const readEvidence = () => {
  const classify = (candidates) => ({
    matched: candidates.some((candidate) => exact(candidate)),
    conflicted: candidates.some((candidate) =>
      typeof candidate === 'string' && candidate.trim() !== '' && !exact(candidate)),
  });
  const domCandidates = Array.from(document.querySelectorAll(
    '[data-ustc-account], input[name="fine_username"], input[name="username"]'))
    .map((node) => node.dataset?.ustcAccount || node.value || node.textContent)
    .filter((value) => typeof value === 'string' && value.trim() !== '');
  const authoritativeCandidates = [];
  for (const entry of performance.getEntriesByType('resource')) {
    try {
      const parsed = new URL(entry.name);
      if (parsed.origin !== location.origin) continue;
      for (const key of ['fine_username', 'username']) {
        const value = parsed.searchParams.get(key);
        if (typeof value === 'string' && value.trim() !== '')
          authoritativeCandidates.push(value);
      }
    } catch (_) {}
  }
  const storageCandidates = [];
  const directIdentityKey = (key) =>
    /^(fine_username|username|account|account_?id|student_?(id|no)|user_?code)$/i.test(key);
  const structuredIdentityValues = (raw) => {
    let parsed;
    try { parsed = JSON.parse(raw); } catch (_) { return []; }
    const values = [];
    const visit = (value, depth = 0) => {
      if (depth > 8 || value === null || typeof value !== 'object') return;
      if (Array.isArray(value)) {
        for (const item of value) visit(item, depth + 1);
        return;
      }
      for (const [key, item] of Object.entries(value)) {
        if (directIdentityKey(key) && typeof item === 'string' && item.trim() !== '')
          values.push(item);
        else if (item && typeof item === 'object')
          visit(item, depth + 1);
      }
    };
    visit(parsed);
    return values;
  };
  for (const storage of [localStorage, sessionStorage]) {
    for (let index = 0; index < storage.length; index++) {
      const key = storage.key(index);
      if (!key) continue;
      const value = storage.getItem(key);
      if (typeof value !== 'string' || value.trim() === '') continue;
      const structured = structuredIdentityValues(value);
      if (structured.length > 0) storageCandidates.push(...structured);
      else if (directIdentityKey(key) && !/^[\[{]/.test(value.trim()))
        storageCandidates.push(value);
    }
  }
  const authoritative = classify(authoritativeCandidates);
  const dom = classify(domCandidates);
  const storage = classify(storageCandidates);
  return {
    authoritativeMatched: authoritative.matched,
    authoritativeConflicted: authoritative.conflicted,
    domMatched: dom.matched,
    domConflicted: dom.conflicted,
    storageMatched: storage.matched,
    storageConflicted: storage.conflicted,
  };
};
const deadline = Date.now() + 30000;
return new Promise((resolve, reject) => {
  const inspect = () => {
    if (document.readyState === 'complete') {
      resolve(readEvidence());
      return;
    }
    if (Date.now() >= deadline) {
      reject(new Error('page_contract_changed'));
      return;
    }
    setTimeout(inspect, 25);
  };
  inspect();
});
''';

const String _courseReadContextScript = r'''
const readDataId = () => {
  for (const entry of performance.getEntriesByType('resource').slice(0, 4096)) {
    let resource;
    try { resource = new URL(entry.name); } catch (_) { continue; }
    if (resource.origin !== location.origin ||
        resource.pathname !== '/for-std/course-table/get-data') continue;
    const keys = Array.from(resource.searchParams.keys()).sort();
    if (keys.join(',') !== 'bizTypeId,dataId,semesterId') continue;
    const candidate = resource.searchParams.get('dataId');
    if (typeof candidate === 'string' && candidate.length > 0) return candidate;
  }
  return null;
};
const deadline = Date.now() + 30000;
return new Promise((resolve, reject) => {
  const inspect = () => {
    const dataId = readDataId();
    if (typeof dataId === 'string' && dataId.length > 0) {
      resolve({dataId});
      return;
    }
    if (Date.now() >= deadline) {
      reject(new Error('missing_course_data_context'));
      return;
    }
    setTimeout(inspect, 25);
  };
  inspect();
});
''';

const String _courseFetchGetDataScript = r'''
const semesterId = args.semesterId;
const dataId = args.dataId;
if (!Number.isInteger(semesterId) || semesterId < 1 ||
    typeof dataId !== 'string' || dataId.length === 0)
  throw new Error('page_contract_changed');
const endpoint = new URL('/for-std/course-table/get-data', location.origin);
endpoint.searchParams.set('bizTypeId', '2');
endpoint.searchParams.set('semesterId', String(semesterId));
endpoint.searchParams.set('dataId', dataId);
return fetch(endpoint.toString(), {
  method: 'GET',
  credentials: 'same-origin',
  headers: {'X-Requested-With': 'XMLHttpRequest'},
}).then((response) => {
  if (!response.ok) throw new Error('request_failed');
  return response.text();
}).then((text) => {
  if (new TextEncoder().encode(text).length > 8 * 1024 * 1024)
    throw new Error('response_too_large');
  return {text};
});
''';

const String _courseFetchDatumScript = r'''
const lessonIds = args.lessonIds;
if (!Array.isArray(lessonIds) || lessonIds.length > 20000 ||
    lessonIds.some((id) => !Number.isInteger(id) || id < 1) ||
    new Set(lessonIds).size !== lessonIds.length)
  throw new Error('page_contract_changed');
if (lessonIds.length === 0) return Promise.resolve({text: null});
return fetch('/for-std/course-table/datum', {
  method: 'POST',
  credentials: 'same-origin',
  headers: {
    'Content-Type': 'application/json',
    'X-Requested-With': 'XMLHttpRequest',
  },
  body: JSON.stringify({lessonIds}),
}).then((response) => {
  if (!response.ok) throw new Error('request_failed');
  return response.text();
}).then((text) => {
  if (new TextEncoder().encode(text).length > 16 * 1024 * 1024)
    throw new Error('response_too_large');
  return {text};
});
''';

const String _examReadTableScript = r'''
const tables = document.querySelectorAll('table#exams');
if (tables.length !== 1) throw new Error('page_contract_changed');
const html = tables[0].outerHTML;
if (new TextEncoder().encode(html).length > 4 * 1024 * 1024)
  throw new Error('response_too_large');
return {html};
''';

/// Closed script registry: id -> source. Registering a script means the caller
/// is allowed to execute exactly this source; arbitrary caller source is
/// rejected by [JwWebSession.executeExtraction] (fail-closed).
const Map<String, String> jwRegisteredScripts = <String, String>{
  'jw.cas.inspect': _casInspectScript,
  'jw.cas.fillUsername': _casFillUsernameScript,
  'jw.cas.fillPassword': _casFillPasswordScript,
  'jw.cas.submit': _casSubmitScript,
  'jw.identity.verifyExpected': _identityProofScript,
  'jw.course.readContext': _courseReadContextScript,
  'jw.course.fetchGetData': _courseFetchGetDataScript,
  'jw.course.fetchDatum': _courseFetchDatumScript,
  'jw.exam.readTable': _examReadTableScript,
};

// --- Platform-agnostic controller seam --------------------------------------
//
// The adapter drives this seam; the production implementation wraps a
// `WebviewController` and tests inject a fake. Lean enough to cover the exact
// operations the minimal adapter needs (URL/loading/webMessage streams,
// loadUrl, executeScript, dispatchPrimaryClick, stop, clearBrowsingDataAll,
// awaitEventStreamReady).

/// A stream value for the navigation loading state (typed locally so the
/// adapter does not import the plugin when testing).
enum JwLoadingState { none, loading, navigationCompleted }

/// Contract mirroring the plugin's `WebviewController` surface used by the
/// adapter.
abstract interface class JwWebviewController {
  Stream<String> get urlChanges;

  /// Latest URL observed by the always-on subscription.
  String? get currentUrlSnapshot;

  Stream<JwLoadingState> get loadingStateChanges;

  Stream<Object?> get webMessages;

  /// Completes after the native event-channel listener is installed.
  Future<void> awaitEventStreamReady();

  /// The visible Flutter widget for this controller. The WebView surface MUST
  /// be embedded in the UI so the user can interact with the login / CAPTCHA
  /// forms (a background-only page would make clicks invalid — full-branch
  /// lesson B). Production returns a real `Webview`; fakes may return a
  /// placeholder.
  Widget get surface;

  Future<void> loadUrl(String url);

  Future<Object?> executeScript(String source);

  Future<void> dispatchPrimaryClick(Offset position);

  Future<void> stop();

  Future<void> clearBrowsingDataAll();

  Future<void> dispose();
}

/// Result of a registered-script extraction.
typedef ExtractionResult = Map<String, Object?>;

// --- Three-signal convergence helpers ---------------------------------------

/// A target the adapter must become "ready" for: a URL pattern (exact or
/// prefix), a DOM-ready CSS selector, and a registered ready handshake script.
class JwReadyTarget {
  const JwReadyTarget({
    required this.id,
    required this.url,
    this.urlPattern,
    this.readySelector,
    this.handshakeScriptId,
  });

  final String id;

  /// Exact URL (or the prefix portion of [urlPattern] if it ends with `*`).
  final String url;

  /// Optional prefix pattern ending in `*` (e.g. `https://jw.ustc.edu.cn/home*`).
  /// When null, the readiness URL comparison is exact.
  final String? urlPattern;

  /// CSS selector whose presence means the DOM is ready.
  final String? readySelector;

  /// Registered script id executed as the ready handshake once URL + DOM
  /// converge. When null, the convergence is URL + DOM only.
  final String? handshakeScriptId;

  bool urlMatches(String candidate) {
    final pattern = urlPattern;
    if (pattern == null || !pattern.endsWith('*')) {
      return candidate == url;
    }
    return candidate.startsWith(pattern.substring(0, pattern.length - 1));
  }
}

/// Trusted portal login target. The `/login` page is the only page from which
/// this adapter may activate the native SSO click; the CAS credential form is
/// reached only by that one side-effecting transition.
const JwReadyTarget portalLoginTarget = JwReadyTarget(
  id: 'jw.portal.login',
  url: 'https://jw.ustc.edu.cn/login',
  urlPattern: 'https://jw.ustc.edu.cn/login*',
  readySelector: '#login-unified-wrapper',
  handshakeScriptId: 'jw.cas.inspect',
);

/// Trusted CAS credential-form target reached by the portal's native click.
const JwReadyTarget casLoginTarget = JwReadyTarget(
  id: 'jw.cas.login',
  url: 'https://id.ustc.edu.cn/cas/login',
  urlPattern: 'https://id.ustc.edu.cn/cas/login*',
  readySelector:
      'form:has(input[name="username"], #username):has(input[type="password"])',
  handshakeScriptId: 'jw.cas.inspect',
);

/// Trusted authenticated portal target. Home readiness intentionally requires
/// a body DOM probe in addition to the URL and registered handshake.
const JwReadyTarget portalHomeTarget = JwReadyTarget(
  id: 'jw.portal.home',
  url: 'https://jw.ustc.edu.cn/home',
  urlPattern: 'https://jw.ustc.edu.cn/home*',
  readySelector: 'body',
  handshakeScriptId: 'jw.cas.inspect',
);

/// Runs a registered script by posting a `window.chrome.webview.postMessage`
/// request and awaiting the matching `webMessage` reply. Does NOT rely on
/// [JwWebviewController.executeScript]'s future result (the page may switch
/// documents during the await).
Future<ExtractionResult> executeRegisteredScript(
  JwWebviewController controller, {
  required String scriptId,
  required Map<String, Object?> args,
  Duration timeout = const Duration(seconds: 30),
  void Function(String)? safeDiagnostic,
}) async {
  final source = jwRegisteredScripts[scriptId];
  if (source == null) {
    safeDiagnostic?.call('registered_script_unknown:$scriptId');
    throw const JwCollectionException('collections script is not registered');
  }
  late final String encodedArgs;
  try {
    encodedArgs = jsonEncode(args);
  } on Object {
    safeDiagnostic?.call('registered_script_args_unencodable');
    throw const JwCollectionException('registered script arguments invalid');
  }
  final requestId = _newRequestId();
  final encodedRequestId = jsonEncode(requestId);
  final completer = Completer<ExtractionResult>();

  void signal(String stage) {
    try {
      safeDiagnostic?.call(stage);
    } on Object {
      // diagnostics must never break collection.
    }
  }

  late final StreamSubscription<Object?> subscription;
  subscription = controller.webMessages.listen(
    (message) {
      if (message is! Map<Object?, Object?>) return;
      if (message['requestId'] != requestId) return;
      if (completer.isCompleted) return;
      final kind = message['kind'];
      final result = message['result'];
      final reason = message['reason'];
      if (kind == 'registeredScriptError') {
        final safeReason = reason is String
            ? _safeScriptReason(reason)
            : 'script_failed';
        signal('registered_script_error:$scriptId:$safeReason');
        completer.completeError(
          JwCollectionException('collection script failed: $safeReason'),
        );
        return;
      }
      if (kind != 'registeredScriptResult' ||
          result is! Map ||
          result.keys.any((key) => key is! String)) {
        safeDiagnostic?.call('registered_script_malformed_reply');
        completer.completeError(
          JwCollectionException('collection script returned invalid data'),
        );
        return;
      }
      completer.complete(<String, Object?>{
        for (final entry in result.entries) entry.key as String: entry.value,
      });
    },
    onError: (Object _) {
      if (!completer.isCompleted) {
        completer.completeError(
          const JwCollectionException('web message stream failed'),
        );
      }
    },
  );
  final wrapper =
      '''
(function() {
  const requestId = $encodedRequestId;
  const payload = $encodedArgs;
  const send = (payload) => window.chrome.webview.postMessage(payload);
  const safeReason = (error) => {
    const reason = error && typeof error.message === 'string'
      ? error.message : 'script_failed';
    return ${jsonEncode(safeScriptFailureReasons.toList())}.includes(reason)
      ? reason : 'script_failed';
  };
  try {
    Promise.resolve((function(args) {$source})(payload)).then(
      (result) => send({kind: 'registeredScriptResult', requestId, result}),
      (error) => send({
        kind: 'registeredScriptError',
        requestId,
        reason: safeReason(error)
      })
    );
  } catch (error) {
    send({
      kind: 'registeredScriptError',
      requestId,
      reason: safeReason(error)
    });
  }
  return true;
})()
''';
  try {
    signal('script_execute:$scriptId');
    await controller
        .executeScript(wrapper)
        .timeout(
          timeout,
          onTimeout: () =>
              throw const JwCollectionException('collection script timed out'),
        );
    signal('script_await:$scriptId');
    return await completer.future.timeout(
      timeout,
      onTimeout: () =>
          throw const JwCollectionException('collection script timed out'),
    );
  } finally {
    await subscription.cancel();
  }
}

/// Maps an unknown script-failure reason to the closed `script_failed` value
/// (never forwards raw page error text).
String _safeScriptReason(String reason) =>
    safeScriptFailureReasons.contains(reason) ? reason : 'script_failed';

final Random _secureRandom = Random.secure();

String _newRequestId() {
  final bytes = List<int>.generate(
    18,
    (_) => _secureRandom.nextInt(256),
    growable: false,
  );
  return 'jw-${base64UrlEncode(bytes).replaceAll('=', '')}';
}

/// A convergence attempt token. Signals from a timed-out or completed
/// attempt must never complete its readiness futures after the attempt has
/// been invalidated.
final class _JwAttemptToken {
  bool active = true;

  void invalidate() {
    active = false;
  }
}

/// Waits for the [JwReadyTarget] signals (URL match, DOM-ready, ready
/// handshake) in any order inside [timeout].
///
/// The readiness waits are armed BEFORE [command] runs, so a fast navigation
/// triggered by the command cannot be missed (listen-before-navigate, lesson
/// 3.2). [command] is typically the navigation/click that drives the target
/// into readiness; when null the controller is assumed to already be on the
/// target's state and only signal observation is performed.
///
/// DOM-ready semantics:
///   - when [JwReadyTarget.readySelector] is set, the DOM signal is the
///     selector becoming present (polled, tolerating document switches);
///   - when no selector is set, the DOM signal is a completed navigation
///     (loadingState == navigationCompleted) OR, if the URL has already
///     matched (e.g. a `setCurrent`-style restore where no new navigation
///     fires), the URL match itself counts as DOM-ready — the ready handshake
///     (or the caller's subsequent script) revalidates the live DOM.
///
/// Returns the ready handshake result (empty when no handshake script is
/// registered for [target]).
Future<ExtractionResult> convergeTarget(
  JwWebviewController controller,
  JwReadyTarget target, {
  required Duration timeout,
  void Function(String)? safeDiagnostic,
  Future<void> Function()? command,
}) async {
  final token = _JwAttemptToken();
  final deadline = DateTime.now().add(timeout);
  final urlMatch = Completer<void>();
  final domReady = Completer<void>();

  void signal(String stage) {
    try {
      safeDiagnostic?.call(stage);
    } on Object {
      // diagnostics must never break navigation.
    }
  }

  void completeDom() {
    if (token.active && !domReady.isCompleted) {
      signal('domReady:${target.id}');
      domReady.complete();
    }
  }

  void completeUrl() {
    if (token.active && !urlMatch.isCompleted) {
      signal('urlMatched:${target.id}');
      urlMatch.complete();
      // No-selector target: a settled URL is a valid DOM-ready proxy. The
      // handshake (or the caller's revalidation) still checks the live DOM.
      if (target.readySelector == null) completeDom();
    }
  }

  // Arm the readiness waits before any navigation/action.
  late final StreamSubscription<String> urlSub;
  urlSub = controller.urlChanges.listen((url) {
    if (!token.active) return;
    if (target.urlMatches(url)) completeUrl();
  });
  if (controller.currentUrlSnapshot != null &&
      target.urlMatches(controller.currentUrlSnapshot!)) {
    completeUrl();
  }

  late final StreamSubscription<JwLoadingState> loadingSub;
  loadingSub = controller.loadingStateChanges.listen((state) {
    if (!token.active) return;
    if (state == JwLoadingState.navigationCompleted &&
        target.readySelector == null) {
      completeDom();
    }
  });

  // Arm the selector poller (if a DOM selector is required) and the
  // navigation/action command in listen-before-navigate order.
  final selector = target.readySelector;
  if (selector != null) {
    unawaited(
      _waitForSelector(
        controller,
        selector,
        timeout,
        isActive: () => token.active,
      ).then(
        (_) {
          if (token.active) completeDom();
        },
        onError: (Object _, StackTrace _) {
          // Timeout/abort is reported by the bounded readiness wait below.
        },
      ),
    );
  }

  try {
    // Invoke the action only after both stream subscriptions and the selector
    // poller are armed. Include its Future in the same bounded wait so command
    // failures propagate instead of being hidden behind a later timeout.
    final commandFuture = command?.call();
    final waits = <Future<void>>[urlMatch.future, domReady.future];
    if (commandFuture != null) waits.add(commandFuture);
    final remaining = deadline.difference(DateTime.now());
    await Future.wait<void>(
      waits,
      eagerError: true,
    ).timeout(remaining.isNegative ? Duration.zero : remaining);

    // The handshake is the third signal. It is credential-free and
    // registered; a missing reply is a failed attempt, never a degraded
    // two-signal success.
    final handshakeId = target.handshakeScriptId;
    if (handshakeId == null) {
      signal('ready:${target.id}');
      return const <String, Object?>{};
    }
    final handshakeRemaining = deadline.difference(DateTime.now());
    if (handshakeRemaining.isNegative || handshakeRemaining == Duration.zero) {
      throw TimeoutException('ready handshake timed out');
    }
    try {
      final result = await executeRegisteredScript(
        controller,
        scriptId: handshakeId,
        args: const <String, Object?>{},
        timeout: handshakeRemaining,
        safeDiagnostic: safeDiagnostic,
      );
      signal('readyHandshake:${target.id}');
      signal('ready:${target.id}');
      return result;
    } on JwCollectionException catch (error) {
      // executeRegisteredScript uses a collection exception for its bounded
      // reply wait. Preserve all script/contract failures, but expose a
      // timeout distinctly so the adapter can map home convergence to the
      // public login-timeout contract.
      if (error.message == 'collection script timed out') {
        throw TimeoutException('ready handshake timed out');
      }
      rethrow;
    }
  } finally {
    token.invalidate();
    await urlSub.cancel();
    await loadingSub.cancel();
  }
}

/// Polls for a CSS selector to be present in the live DOM until [timeout].
/// ExecuteScript failures during a document switch are expected transient
/// states and are retried within the original bound.
Future<void> _waitForSelector(
  JwWebviewController controller,
  String selector,
  Duration timeout, {
  bool Function()? isActive,
}) async {
  final deadline = DateTime.now().add(timeout);
  final encoded = jsonEncode(selector);
  while (true) {
    if (isActive != null && !isActive()) return;
    Object? present;
    try {
      present = await controller.executeScript(
        'Boolean(document.querySelector($encoded))',
      );
    } on Object {
      // Document switching; keep polling within the bound.
    }
    if (present == true) return;
    if (isActive != null && !isActive()) return;
    if (DateTime.now().isAfter(deadline)) {
      throw const JwCollectionException('DOM ready selector timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}
