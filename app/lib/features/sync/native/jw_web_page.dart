// M3: `JwWebPage` — the platform-agnostic injection seam the collector drives
// its navigation/readiness state machine against. Mirrors the Python
// `collector.py` Playwright surface (`_ensure_authenticated`,
// `_collect_from_authenticated_context`) but abstracts away the concrete
// browser: a real WebView adapter (M5) implements this, and tests inject a
// scripted fake.
//
// No `dart:io`, no `webview_flutter`, no platform plugins here — pure
// interface + ported URL/dataId helpers shared by the fake and the real
// adapter.

import 'dart:convert';

/// Credentials for the USTC CAS login form. Mirrors Python `LoginCredentials`
/// (`common/auth.py`): [username] is required and non-blank; [password] is
/// optional (the user may submit manually after the username is filled).
class LoginCredentials {
  const LoginCredentials({required this.username, this.password});

  final String username;
  final String? password;

  LoginCredentials copyWith({String? password}) =>
      LoginCredentials(username: username, password: password ?? this.password);
}

// --- URL constants mirroring `collector.py` ---------------------------------

/// `jw.ustc.edu.cn`.
const String jwHost = 'jw.ustc.edu.cn';

/// `https://jw.ustc.edu.cn/`.
const String jwRootUrl = 'https://jw.ustc.edu.cn/';

/// `https://jw.ustc.edu.cn/ucas-sso/login`.
const String casEntryUrl = 'https://jw.ustc.edu.cn/ucas-sso/login';

/// `https://jw.ustc.edu.cn/for-std/course-table`.
const String courseEntryUrl = 'https://jw.ustc.edu.cn/for-std/course-table';

/// `/for-std/course-table/get-data`.
const String courseGetDataPath = '/for-std/course-table/get-data';

/// `https://jw.ustc.edu.cn/for-std/course-table/datum`.
const String courseDatumUrl =
    'https://jw.ustc.edu.cn/for-std/course-table/datum';

/// `https://jw.ustc.edu.cn/for-std/exam-arrange`.
const String examEntryUrl = 'https://jw.ustc.edu.cn/for-std/exam-arrange';

/// Matches `^https://jw\.ustc\.edu\.cn/home(?:[/?#].*)?$` (Python
/// `AUTHENTICATED_HOME_PATTERN`). The JW app home page URL.
final RegExp authenticatedHomePattern = RegExp(
  r'^https://jw\.ustc\.edu\.cn/home(?:[/?#].*)?$',
);

/// Default login wait (Python `DEFAULT_LOGIN_TIMEOUT_MS` = 5 min).
const Duration defaultLoginTimeout = Duration(minutes: 5);

/// Default response wait (Python `DEFAULT_RESPONSE_TIMEOUT_MS` = 30 s).
const Duration defaultResponseTimeout = Duration(seconds: 30);

// --- Ported helpers (collector.py) -----------------------------------------

/// Port of `collector._is_authenticated_home`.
bool isAuthenticatedHomeUrl(String url) =>
    authenticatedHomePattern.hasMatch(url);

/// Port of `collector.build_get_data_url(semester_id, data_id)`:
/// `https://jw.ustc.edu.cn/for-std/course-table/get-data?bizTypeId=2&semesterId={id}&dataId={dataId}`.
///
/// Throws [ArgumentError] if [dataId] is empty (mirrors Python
/// `CollectionError("cannot build course request without dataId")`).
String buildGetDataUrl(int semesterId, String dataId) {
  if (dataId.isEmpty) {
    throw ArgumentError('cannot build course request without dataId');
  }
  final query = Uri(
    queryParameters: <String, String>{
      'bizTypeId': '2',
      'semesterId': semesterId.toString(),
      'dataId': dataId,
    },
  ).query;
  return Uri.https(jwHost, courseGetDataPath).replace(query: query).toString();
}

/// Port of `collector.extract_data_id(url)`: validate the URL points at the
/// get-data endpoint and return the single `dataId` query parameter.
///
/// Throws [ArgumentError] (mirrors Python `CollectionError`) if the URL is
/// not the get-data endpoint, has no `dataId`, or has multiple.
String extractDataId(String url) {
  final parsed = Uri.tryParse(url);
  if (parsed == null ||
      parsed.scheme != 'https' ||
      parsed.host != jwHost ||
      parsed.path != courseGetDataPath) {
    throw ArgumentError('unexpected course get-data endpoint');
  }
  final values = parsed.queryParametersAll['dataId'] ?? const <String>[];
  if (values.length != 1 || values.first.isEmpty) {
    throw ArgumentError('course get-data request is missing dataId');
  }
  return values.first;
}

/// Port of `collector.is_get_data_url(url)`: true iff [url] is the get-data
/// endpoint (swallows the validation error).
bool isGetDataUrl(String url) {
  try {
    extractDataId(url);
    return true;
  } on ArgumentError {
    return false;
  }
}

/// Thrown by `JwWebPage` implementations to signal a login wait timed out
/// (mirrors Python `PlaywrightTimeoutError` → `CollectionError("USTC JW login
/// was not completed before timeout")`). The collector maps this to
/// `login_timeout`.
class JwLoginTimeoutException implements Exception {
  const JwLoginTimeoutException([this.message]);
  final String? message;
  @override
  String toString() =>
      'JwLoginTimeoutException: ${message ?? 'login wait timed out'}';
}

/// Thrown by `JwWebPage` implementations to signal the authenticated account
/// does not match the expected username (mirrors Python `AccountMismatch`).
/// The collector maps this to `account_mismatch`.
class JwAccountMismatchException implements Exception {
  const JwAccountMismatchException([this.message]);
  final String? message;
  @override
  String toString() =>
      'JwAccountMismatchException: ${message ?? 'account mismatch'}';
}

/// Thrown by `JwWebPage` implementations to signal a collect-step failure
/// (mirrors Python `CollectionError`). The collector maps this to
/// `collection_failed`.
class JwCollectionException implements Exception {
  const JwCollectionException([this.message]);
  final String? message;
  @override
  String toString() =>
      'JwCollectionException: ${message ?? 'collection failed'}';
}

/// The platform-agnostic browser page the collector drives. A real WebView
/// adapter (M5) implements this; tests inject a scripted fake.
///
/// Method contracts mirror the Python `collector.py` Playwright calls so the
/// collector's event sequence stays comparable to the Python channel.
abstract class JwWebPage {
  /// Current page URL (Playwright `page.url`).
  Future<String> get currentUrl;

  /// Navigate to [jwRootUrl] (Playwright `page.goto(JW_ROOT_URL)`).
  Future<void> gotoRoot();

  /// Navigate to [casEntryUrl] (Playwright `page.goto(CAS_ENTRY_URL)`).
  Future<void> gotoCasEntry();

  /// Navigate to [courseEntryUrl] (Playwright `page.goto(COURSE_ENTRY_URL)`).
  Future<void> gotoCourseTable();

  /// Navigate to [examEntryUrl] (Playwright `page.goto(EXAM_ENTRY_URL)`).
  Future<void> gotoExamArrange();

  /// True iff [currentUrl] matches [authenticatedHomePattern] (Python
  /// `_is_authenticated_home`).
  Future<bool> get isAuthenticatedHome;

  /// Strictly verifies an already authenticated home session for the expected
  /// school account. Implementations that own a real browser must converge the
  /// home URL/DOM/registered handshake and prove the account identity; the
  /// default keeps older scripted fakes source-compatible.
  Future<bool> verifyAuthenticatedHome({
    required String expectedUsername,
    required Duration timeout,
  }) async => isAuthenticatedHome;

  /// Fill the CAS login form with [credentials] (Python `fill_ustc_login`).
  /// Implementations fill the username and, when a non-empty password is
  /// supplied, fill and submit it. An empty password deliberately leaves the
  /// visible form ready for the user to submit manually. Must throw
  /// [JwAccountMismatchException] if, after filling, the rendered account
  /// selector does not match `credentials.username` and the mismatch cannot
  /// be resolved — the collector surfaces this as `account_mismatch`.
  Future<void> fillLogin(LoginCredentials credentials);

  /// Wait for navigation to an authenticated `/home` URL (Python
  /// `page.wait_for_url(AUTHENTICATED_HOME_PATTERN, timeout=...)`). Throws
  /// [JwLoginTimeoutException] on timeout (mirrors `PlaywrightTimeoutError`).
  Future<void> waitForAuthenticatedHome(Duration timeout);

  /// Intercept the course get-data request issued while loading the course
  /// table and return its `dataId` (Python
  /// `page.expect_response(is_get_data_url)` + `extract_data_id`). Throws
  /// [JwCollectionException] on timeout.
  Future<String> resolveCourseDataId(Duration timeout);

  /// Fetch the full course datum for [semesterId] / [dataId] (Python
  /// `fetch_course_datum`: GET get-data for lessonIds, then POST datum).
  /// Returns the `{result:{...}}` datum object. Throws [JwCollectionException]
  /// if lessonIds are missing/empty or the response is invalid.
  Future<Map<String, dynamic>> fetchCourseDatum({
    required int semesterId,
    required String dataId,
    required String referer,
  });

  /// Load the exam arrange page, wait for `table#exams`, and return the page
  /// HTML (Python `page.content()`). Throws [JwCollectionException] if the
  /// table is missing or the wait times out.
  Future<String> fetchExamHtml(Duration timeout);

  /// Clears transient login-attempt state after cancellation or a terminal
  /// failure. Gateway-owned pages may keep their browser controller alive for
  /// the next same-account job, so this hook must not dispose that controller.
  /// Older fakes may inherit the no-op default.
  Future<void> resetLoginAttempt() async {}

  /// Release page resources. Implementations may override; the default is a
  /// no-op so fakes need not bother.
  Future<void> close() async {}
}

/// Helper to parse a JSON HTTP-like body into a `Map<String,dynamic>`. Shared
/// by adapters/fakes that receive string bodies. Throws
/// [JwCollectionException] on invalid JSON or non-object payloads.
Map<String, dynamic> parseJsonObject(String body, {required String endpoint}) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException catch (e) {
    throw JwCollectionException(
      '$endpoint returned invalid JSON: ${e.message}',
    );
  }
  if (decoded is! Map<String, dynamic>) {
    throw JwCollectionException('$endpoint returned invalid JSON');
  }
  return decoded;
}
