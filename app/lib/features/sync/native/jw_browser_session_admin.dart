import 'jw_web_page.dart';
import 'jw_webview_surface_host.dart';
import 'windows_jw_udf_store.dart';

/// Public handle for one account-bound browser session.
///
/// The handle intentionally exposes only the collector page and opaque
/// partition capability. Controller objects, UDF paths and native release
/// details remain owned by the platform session admin.
abstract interface class JwBrowserSessionHandle {
  JwWebPage get page;

  JwSessionPartitionRef get partition;

  Future<void> close();
}

/// Owns the one live WebView2 session and its stable visible surface.
abstract interface class JwBrowserSessionAdmin {
  JwWebViewSurfaceHost get surfaceHost;

  Future<JwBrowserSessionHandle> open(String accountId);

  Future<void> clearAllPartitions();

  Future<void> shutdown();
}
