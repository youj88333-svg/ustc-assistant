// Constructor seams intentionally keep private ownership fields explicit.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import '../native/jw_webview_surface_host.dart';
import '../native/jw_browser_session_admin.dart';
import 'source_job_gateway.dart';

/// The app-owned JW runtime bundle.  Routes borrow these ports; they never
/// create or dispose browser/controller resources themselves.
final class MinimalJwRuntime {
  MinimalJwRuntime({
    required this.gateway,
    required this.browserSessions,
    void Function(String)? safeDiagnostic,
  }) : _safeDiagnostic = safeDiagnostic;

  final SourceJobGateway gateway;
  final JwBrowserSessionAdmin browserSessions;
  final void Function(String)? _safeDiagnostic;
  Future<void>? _shutdownFuture;

  JwWebViewSurfaceHost get surfaceHost => browserSessions.surfaceHost;

  /// Shuts down the gateway (job cancellation/settlement) and then the
  /// session admin (surface/controller/environment release).  Both stages are
  /// attempted even if the first reports an error, with the first error
  /// normalized to a privacy-safe code.
  Future<void> shutdown() {
    final existing = _shutdownFuture;
    if (existing != null) return existing;
    final operation = _shutdownImpl();
    _shutdownFuture = operation;
    return operation;
  }

  Future<void> _shutdownImpl() async {
    Object? firstError;
    StackTrace? firstStack;

    Future<void> attempt(Future<void> Function() action) async {
      try {
        await action();
      } on Object catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }

    await attempt(gateway.shutdown);
    final gatewayOwnsSessions =
        gateway is SourceJobSessionOwner &&
        (gateway as SourceJobSessionOwner).ownsBrowserSessions;
    if (!gatewayOwnsSessions) {
      await attempt(browserSessions.shutdown);
    }

    final error = firstError;
    if (error != null) {
      const safeCode = 'runtime_shutdown_failed';
      try {
        _safeDiagnostic?.call(safeCode);
      } on Object {
        // Observers are not allowed to change teardown behavior.
      }
      Error.throwWithStackTrace(
        StateError(safeCode),
        firstStack ?? StackTrace.current,
      );
    }
  }
}

/// Owns one lazily loaded runtime and serializes replacement/shutdown.
final class MinimalJwRuntimeOwner {
  MinimalJwRuntimeOwner(this._loader);

  final Future<MinimalJwRuntime> Function() _loader;
  Future<MinimalJwRuntime>? _currentFuture;
  Future<void>? _shutdownFuture;
  Future<void>? _replacementFuture;
  bool _shutdownRequested = false;

  Future<MinimalJwRuntime> get current {
    final existing = _currentFuture;
    if (existing != null) return existing;
    if (_shutdownRequested) {
      return Future<MinimalJwRuntime>.error(
        StateError('JW runtime owner is shutting down'),
      );
    }
    final loaded = Future<MinimalJwRuntime>.sync(_loader);
    _currentFuture = loaded;
    return loaded;
  }

  /// Starts exactly one observable shutdown operation.  If the loader is
  /// already in flight, its late runtime is immediately shut down before this
  /// future settles.
  Future<void> beginShutdown() {
    final existing = _shutdownFuture;
    if (existing != null) return existing;
    _shutdownRequested = true;
    final operation = _shutdownCurrent();
    _shutdownFuture = operation;
    return operation;
  }

  Future<void> _shutdownCurrent() async {
    final loaded = _currentFuture;
    if (loaded == null) return;
    final runtime = await loaded;
    await runtime.shutdown();
  }

  /// Replaces the runtime after a caller has completed reset cleanup.  The
  /// old runtime is always fully shut down before the loader is invoked again.
  /// Concurrent replacement calls share one future and cannot create a second
  /// runtime.
  Future<void> replaceAfterReset() {
    final existing = _replacementFuture;
    if (existing != null) return existing;
    final operation = _replaceAfterReset();
    _replacementFuture = operation;
    unawaited(
      operation.then<void>(
        (_) {
          if (identical(_replacementFuture, operation)) {
            _replacementFuture = null;
          }
        },
        onError: (Object _, StackTrace _) {
          if (identical(_replacementFuture, operation)) {
            _replacementFuture = null;
          }
        },
      ),
    );
    return operation;
  }

  Future<void> _replaceAfterReset() async {
    // If reset has not explicitly started shutdown, do it here so a loaded
    // runtime can never overlap the replacement runtime.
    await beginShutdown();
    _currentFuture = null;
    _shutdownFuture = null;
    _shutdownRequested = false;
    // Trigger exactly one fresh load and await it before returning.  Keeping
    // the future in [_currentFuture] makes callers of [current] share it.
    await current;
  }
}
