// M5: `JwWebViewAdapter` — the platform-specific WebView implementation seam
// for the JW collector's `JwWebPage` interface.
//
// This is a **stub**: every method throws `UnimplementedError`. It exists so
// that the cross-platform interface contract is statically compilable and so
// M6 can swap in a real `webview_flutter` (or platform channel) wiring on the
// external machine that has the mobile SDKs installed.
//
// `webview_flutter` is intentionally NOT added to pubspec in M5 (it is in the
// offline pub-cache but adding it would churn the lockfile/pub get on a VM
// that cannot build or run a real WebView anyway). M6 wires the real WebView.

import 'jw_web_page.dart';

/// WebView-backed implementation of [JwWebPage].
///
/// All members throw [UnimplementedError] until M6 wires a real WebView on the
/// external machine. The base class [JwWebPage.close] already provides a
/// no-op default, so it is not overridden here.
class JwWebViewAdapter implements JwWebPage {
  @override
  Future<String> get currentUrl =>
      throw UnimplementedError('M6: wire real WebView on external machine');

  @override
  Future<void> gotoRoot() =>
      throw UnimplementedError('M6: wire real WebView on external machine');

  @override
  Future<void> gotoCasEntry() =>
      throw UnimplementedError('M6: wire real WebView on external machine');

  @override
  Future<void> gotoCourseTable() =>
      throw UnimplementedError('M6: wire real WebView on external machine');

  @override
  Future<void> gotoExamArrange() =>
      throw UnimplementedError('M6: wire real WebView on external machine');

  @override
  Future<bool> get isAuthenticatedHome =>
      throw UnimplementedError('M6: wire real WebView on external machine');

  @override
  Future<void> fillLogin(LoginCredentials credentials) =>
      throw UnimplementedError('M6: wire real WebView on external machine');

  @override
  Future<void> waitForAuthenticatedHome(Duration timeout) =>
      throw UnimplementedError('M6: wire real WebView on external machine');

  @override
  Future<String> resolveCourseDataId(Duration timeout) =>
      throw UnimplementedError('M6: wire real WebView on external machine');

  @override
  Future<Map<String, dynamic>> fetchCourseDatum({
    required int semesterId,
    required String dataId,
    required String referer,
  }) =>
      throw UnimplementedError('M6: wire real WebView on external machine');

  @override
  Future<String> fetchExamHtml(Duration timeout) =>
      throw UnimplementedError('M6: wire real WebView on external machine');

  // `JwWebPage.close` has a concrete no-op default, but `implements` requires
  // re-declaring every member. Keep this a no-op so the stub is disposable
  // without touching a (non-existent) real WebView.
  @override
  Future<void> close() async {}
}
