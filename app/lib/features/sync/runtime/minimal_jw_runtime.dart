// Constructor seams intentionally keep private ownership fields explicit.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import '../native/jw_webview_surface_host.dart';
import '../native/jw_browser_session_admin.dart';
import '../native/windows_jw_udf_store.dart';
import '../application/sync_coordinator.dart';
import 'source_job_gateway.dart';

/// The app-owned JW runtime bundle.  Routes borrow these ports; they never
/// create or dispose browser/controller resources themselves.
final class MinimalJwRuntime {
  MinimalJwRuntime({
    required this.gateway,
    required this.browserSessions,
    this.syncCoordinator,
    this.udfStore,
    this.udfStoreLoader,
    void Function(String)? safeDiagnostic,
  }) : _safeDiagnostic = safeDiagnostic;

  final SourceJobGateway gateway;
  final JwBrowserSessionAdmin browserSessions;
  final SyncCoordinator? syncCoordinator;
  final WindowsJwUdfStore? udfStore;
  final Future<WindowsJwUdfStore> Function()? udfStoreLoader;
  final void Function(String)? _safeDiagnostic;
  Future<void>? _shutdownFuture;
  Future<WindowsJwUdfStore>? _udfStoreFuture;

  JwWebViewSurfaceHost get surfaceHost => browserSessions.surfaceHost;

  /// Resolves the app-owned UDF store without forcing platform path lookup
  /// during ordinary shell/runtime startup. The reset boundary invokes this
  /// explicit port when a store was not needed by an earlier browser job.
  Future<WindowsJwUdfStore> resolveUdfStore() {
    final existingStore = udfStore;
    if (existingStore != null) {
      return Future<WindowsJwUdfStore>.value(existingStore);
    }
    final existing = _udfStoreFuture;
    if (existing != null) return existing;
    final loader = udfStoreLoader;
    if (loader == null) {
      return Future<WindowsJwUdfStore>.error(
        StateError('UDF store is unavailable'),
      );
    }
    final operation = Future<WindowsJwUdfStore>.sync(loader);
    _udfStoreFuture = operation;
    unawaited(
      operation.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(_udfStoreFuture, operation)) _udfStoreFuture = null;
        },
      ),
    );
    return operation;
  }

  /// Shuts down the gateway (job cancellation/settlement) and then the
  /// session admin (surface/controller/environment release).  Both stages are
  /// attempted even if the first reports an error, with the first error
  /// normalized to a privacy-safe code.
  Future<void> shutdown() {
    final existing = _shutdownFuture;
    if (existing != null) return existing;
    final operation = _shutdownImpl();
    _shutdownFuture = operation;
    unawaited(
      operation.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          // Keep the gateway/session owners alive for a later reset retry;
          // caching a failed Future would make recovery impossible.
          if (identical(_shutdownFuture, operation)) _shutdownFuture = null;
        },
      ),
    );
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
  Future<void>? _terminalShutdownFuture;
  Future<MinimalJwRuntime>? _shutdownTarget;
  Future<void>? _replacementFuture;
  bool _shutdownRequested = false;
  bool _terminalShutdownRequested = false;

  Future<MinimalJwRuntime> get current {
    if (_shutdownRequested || _terminalShutdownRequested) {
      return Future<MinimalJwRuntime>.error(
        StateError('JW runtime owner is shutting down'),
      );
    }
    final existing = _currentFuture;
    if (existing != null) return existing;
    final loaded = Future<MinimalJwRuntime>.sync(_loader);
    _currentFuture = loaded;
    // A failed construction owns no runtime to release. Observe it here so
    // the failed Future cannot become a permanent retry poison or surface as
    // an unhandled error when shutdown joins a late loader.
    unawaited(
      loaded.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(_currentFuture, loaded)) _currentFuture = null;
        },
      ),
    );
    return loaded;
  }

  /// Starts exactly one observable shutdown operation.  If the loader is
  /// already in flight, its late runtime is immediately shut down before this
  /// future settles.
  Future<void> beginShutdown() {
    final existing = _terminalShutdownFuture;
    if (existing != null) return existing;
    _terminalShutdownRequested = true;
    _shutdownRequested = true;
    final operation = _terminalShutdownImpl();
    _terminalShutdownFuture = operation;
    unawaited(
      operation.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(_terminalShutdownFuture, operation)) {
            _terminalShutdownFuture = null;
          }
        },
      ),
    );
    return operation;
  }

  /// Awaits the non-terminal teardown used by complete-reset. The next
  /// [replaceAfterReset] call may install one fresh runtime after this
  /// boundary; process exit must use [beginShutdown] instead.
  Future<void> prepareForReset() => _startShutdown();

  Future<void> _startShutdown() {
    final existing = _shutdownFuture;
    if (existing != null) return existing;
    _shutdownRequested = true;
    final target = _currentFuture;
    _shutdownTarget = target;
    final operation = _shutdownCurrent(target);
    _shutdownFuture = operation;
    unawaited(
      operation.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(_shutdownFuture, operation)) _shutdownFuture = null;
        },
      ),
    );
    return operation;
  }

  Future<void> _shutdownCurrent(Future<MinimalJwRuntime>? target) async {
    final loaded = target;
    if (loaded == null) return;
    late final MinimalJwRuntime runtime;
    try {
      runtime = await loaded;
    } on Object {
      // The construction future failed before producing an owned runtime.
      // Clear only that exact failed generation; a newer generation, if any,
      // remains owned by its caller and is not admitted during shutdown.
      if (identical(_currentFuture, loaded)) _currentFuture = null;
      return;
    }
    await runtime.shutdown();
  }

  Future<void> _terminalShutdownImpl() async {
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

    // A reset already in progress must reach its terminal decision before
    // app exit returns. Its expected "owner terminated" rejection is not a
    // teardown failure; the old runtime shutdown itself is observed below.
    final replacement = _replacementFuture;
    if (replacement != null) {
      try {
        await replacement;
      } on Object {
        // Terminal shutdown deliberately wins reset replacement.
      }
    }
    final priorShutdown = _shutdownFuture;
    if (priorShutdown != null) {
      await attempt(() => priorShutdown);
    }

    // If replacement had crossed the old-shutdown await before terminal state
    // was requested, it may have created a fresh loader future. It must be
    // drained and shut down as part of this same terminal operation. The
    // identity check avoids invoking shutdown twice for the old target.
    final target = _currentFuture;
    if (target != null && !identical(target, _shutdownTarget)) {
      await attempt(() => _shutdownCurrent(target));
    }

    final error = firstError;
    if (error != null) {
      Error.throwWithStackTrace(error, firstStack ?? StackTrace.current);
    }
  }

  /// Replaces the runtime after a caller has completed reset cleanup.  The
  /// old runtime is always fully shut down before the loader is invoked again.
  /// Concurrent replacement calls share one future and cannot create a second
  /// runtime.
  Future<void> replaceAfterReset() {
    if (_terminalShutdownRequested) {
      return Future<void>.error(StateError('JW runtime owner has terminated'));
    }
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
    await _startShutdown();
    // A process-exit/dispose shutdown may have joined the old teardown while
    // reset was waiting. It is terminal and must prevent a fresh load.
    if (_terminalShutdownRequested) {
      throw StateError('JW runtime owner has terminated');
    }
    _currentFuture = null;
    _shutdownFuture = null;
    _shutdownRequested = false;
    // Trigger exactly one fresh load and await it before returning.  Keeping
    // the future in [_currentFuture] makes callers of [current] share it.
    final fresh = await current;
    // Terminal shutdown can begin after the fresh loader has been admitted
    // but before it completes. Do not let this reset future report success or
    // leave that newly created runtime alive in a disposed app.
    if (_terminalShutdownRequested) {
      await fresh.shutdown();
      throw StateError('JW runtime owner has terminated');
    }
  }
}
