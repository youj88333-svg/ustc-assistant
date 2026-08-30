import 'dart:async';
import 'dart:io';

import '../data/bridge_client.dart';
import 'jw_browser_session_admin.dart';
import 'jw_web_page.dart';
import 'jw_web_session.dart';
import 'jw_webview_adapter.dart';
import 'jw_webview_surface_host.dart';
import 'windows_jw_udf_store.dart';

// Public constructor names intentionally stay readable while the owned
// fields remain private; the lint cannot express that pairing.
// ignore_for_file: prefer_initializing_formals

/// A path-aware controller factory for callers that need to bind native
/// WebView2 to the account's opaque UDF partition.
typedef JwBrowserControllerFactory =
    Future<JwWebviewController> Function({required String userDataPath});

/// Builds a page around an already-created controller. The default wraps it
/// in [JwWebViewAdapter]; the seam is useful to tests and future platform
/// adapters without exposing controller ownership to presentation.
typedef JwBrowserPageFactory =
    JwWebPage Function(JwWebviewController controller);

/// Windows implementation of [JwBrowserSessionAdmin].
///
/// There is at most one live handle. The admin owns the controller from the
/// moment the factory returns it through the native environment-release
/// barrier; only then may its UDF be cleared. A failed cleanup keeps the exact
/// handle in [_live] for a later retry.
final class WindowsJwBrowserSessionAdmin implements JwBrowserSessionAdmin {
  WindowsJwBrowserSessionAdmin({
    required WindowsJwUdfStore udfStore,
    JwWebviewControllerFactory? controllerFactory,
    JwBrowserControllerFactory? controllerFactoryWithUserDataPath,
    ProductionJwControllerFactory? productionControllerFactory,
    JwWebViewSurfaceHost? surfaceHost,
    JwBrowserPageFactory? pageFactory,
    Duration surfaceUnmountTimeout = const Duration(seconds: 5),
    void Function(String)? safeDiagnostic,
  }) : _udfStore = udfStore,
       _controllerFactory = controllerFactory,
       _controllerFactoryWithUserDataPath = controllerFactoryWithUserDataPath,
       _productionControllerFactory = productionControllerFactory,
       _surfaceHost = surfaceHost ?? JwWebViewSurfaceHost(),
       _pageFactory = pageFactory,
       _surfaceUnmountTimeout = surfaceUnmountTimeout,
       _safeDiagnostic = safeDiagnostic;

  final WindowsJwUdfStore _udfStore;
  final JwWebviewControllerFactory? _controllerFactory;
  final JwBrowserControllerFactory? _controllerFactoryWithUserDataPath;
  final ProductionJwControllerFactory? _productionControllerFactory;
  final JwWebViewSurfaceHost _surfaceHost;
  final JwBrowserPageFactory? _pageFactory;
  final Duration _surfaceUnmountTimeout;
  final void Function(String)? _safeDiagnostic;

  _WindowsJwBrowserSessionHandle? _live;
  final Set<String> _quarantinedTokens = <String>{};
  bool _openInFlight = false;
  bool _clearInFlight = false;
  Completer<void>? _openCompletion;
  bool _shutdown = false;
  Future<void>? _shutdownFuture;

  @override
  JwWebViewSurfaceHost get surfaceHost => _surfaceHost;

  @override
  Future<JwBrowserSessionHandle> open(String accountId) async {
    final ref = _udfStore.referenceFor(accountId);
    // A marker written by this owner is known synchronously, so a retained
    // retry handle cannot normalize the stable quarantine code to bridge_busy.
    if (_clearInFlight) {
      throw const BridgeProtocolError('bridge_busy');
    }
    if (_quarantinedTokens.contains(ref.opaqueToken)) {
      throw const BridgeProtocolError('browser_session_quarantined');
    }
    if (_shutdown || _live != null || _openInFlight || _clearInFlight) {
      throw const BridgeProtocolError('bridge_busy');
    }
    // This assignment occurs before the first await, so concurrent callers
    // and shutdown cannot both pass the one-live-session check.
    _openInFlight = true;
    final openCompletion = Completer<void>();
    _openCompletion = openCompletion;
    try {
      // This asynchronous read covers markers left by an earlier process.
      if (await _udfStore.isQuarantined(ref)) {
        _quarantinedTokens.add(ref.opaqueToken);
        throw const BridgeProtocolError('browser_session_quarantined');
      }
      late final Directory directory;
      try {
        directory = await _udfStore.ensurePartition(ref);
      } on Object catch (error, stackTrace) {
        await _markQuarantined(ref, 'collection_failed');
        Error.throwWithStackTrace(
          _safeError(error, fallback: 'request_failed'),
          stackTrace,
        );
      }

      late final JwWebviewController controller;
      try {
        controller = await _createController(directory.path);
      } on Object catch (error, stackTrace) {
        // Native creation may have touched the UDF without returning a
        // controller/PID. Quarantine it because no release handle exists.
        await _markQuarantined(ref, 'collection_failed');
        Error.throwWithStackTrace(
          _safeError(error, fallback: 'request_failed'),
          stackTrace,
        );
      }

      final handle = _WindowsJwBrowserSessionHandle(
        admin: this,
        partition: ref,
        controller: controller,
      );
      // Store immediately after factory hand-off, before any adapter/page
      // setup can throw. This provisional owner is the exact native release
      // handle for every later setup failure.
      _live = handle;
      try {
        final adapter = JwWebViewAdapter(
          controllerFactory: () async => controller,
          safeDiagnostic: _safeDiagnostic,
          initialController: controller,
        );
        handle._adapter = adapter;
        handle._page = _pageFactory?.call(controller) ?? adapter;
        if (_shutdown) {
          // Shutdown may have started while the native factory was awaiting a
          // controller. Release this late hand-off under the same owner before
          // allowing shutdown to complete.
          await _closeLive(handle);
          throw const BridgeProtocolError('bridge_busy');
        }
        await adapter.beginSubscriptions();
        await _surfaceHost.attach(controller).timeout(_surfaceUnmountTimeout);
      } on Object catch (error, stackTrace) {
        final openingFailure = _safeError(error, fallback: 'request_failed');
        try {
          await _closeLive(handle);
        } on Object {
          // _closeLive already quarantines cleanup failures and retains the
          // live handle. Preserve the original opening failure for this call.
        }
        // If cleanup succeeded, the failed opening still leaves the UDF in a
        // known-bad state until an explicit clear/reset operation.
        await _markQuarantined(ref, 'collection_failed');
        Error.throwWithStackTrace(openingFailure, stackTrace);
      }
      return handle;
    } finally {
      _openInFlight = false;
      _openCompletion = null;
      if (!openCompletion.isCompleted) openCompletion.complete();
    }
  }

  Future<JwWebviewController> _createController(String userDataPath) {
    final pathFactory = _controllerFactoryWithUserDataPath;
    if (pathFactory != null) {
      return pathFactory(userDataPath: userDataPath);
    }
    final productionFactory = _productionControllerFactory;
    if (productionFactory != null) {
      return productionFactory(
        userDataPath: userDataPath,
        safeDiagnostic: _safeDiagnostic ?? (_) {},
      );
    }
    final factory = _controllerFactory;
    if (factory != null) return factory();
    return createProductionJwWebviewController(
      userDataPath: userDataPath,
      safeDiagnostic: _safeDiagnostic,
    );
  }

  @override
  Future<void> clearAllPartitions() async {
    // An in-flight open may have created a native controller before its
    // handle is published. Refuse the destructive operation until it settles.
    if (_live != null || _openInFlight || _clearInFlight) {
      throw const BridgeProtocolError('bridge_busy');
    }
    // Claim maintenance admission synchronously, before the first await, so
    // a concurrent open cannot pass the check while the delete is paused.
    _clearInFlight = true;
    try {
      await _udfStore.clearAllPartitions();
      _quarantinedTokens.clear();
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(
        _safeError(error, fallback: 'browser_cleanup_incomplete'),
        stackTrace,
      );
    } finally {
      _clearInFlight = false;
    }
  }

  @override
  Future<void> shutdown() {
    final existing = _shutdownFuture;
    if (existing != null) return existing;
    _shutdown = true;
    final operation = _shutdownImpl();
    _shutdownFuture = operation;
    unawaited(
      operation.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          // A failed close keeps [_live] and a later shutdown() retries it.
          if (identical(_shutdownFuture, operation)) {
            _shutdownFuture = null;
          }
        },
      ),
    );
    return operation;
  }

  Future<void> _shutdownImpl() async {
    final opening = _openCompletion;
    if (opening != null) await opening.future;
    final handle = _live;
    if (handle != null) await _closeLive(handle);
  }

  Future<void> _closeLive(_WindowsJwBrowserSessionHandle handle) async {
    if (handle._released) return;
    final existing = handle._closeFuture;
    if (existing != null) return existing;
    final operation = _closeLiveImpl(handle);
    handle._closeFuture = operation;
    unawaited(
      operation.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(handle._closeFuture, operation) && !handle._released) {
            // A failed close must be retryable, but concurrent callers of the
            // same attempt still share the original Future above.
            handle._closeFuture = null;
          }
        },
      ),
    );
    return operation;
  }

  Future<void> _closeLiveImpl(_WindowsJwBrowserSessionHandle handle) async {
    if (handle._released) return;
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> attempt(Future<void> Function() operation) async {
      try {
        await operation();
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    // Detach is the first stage. The native texture must no longer be in the
    // Flutter tree before stop/subscription teardown/controller release.
    await attempt(
      () => _surfaceHost
          .detachAndAwaitUnmount(handle.controller)
          .timeout(_surfaceUnmountTimeout),
    );
    await attempt(handle.controller.stop);
    await attempt(handle.disposeSubscriptions);
    var releaseSucceeded = false;
    try {
      await handle.disposeControllerAndAwaitRelease();
      releaseSucceeded = true;
    } on Object catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }

    // Retain ownership on any failure, including a detach error followed by a
    // successful release. This keeps the contract fail-closed and makes the
    // original handle the only authority able to retry cleanup.
    if (releaseSucceeded) handle._page = null;
    if (releaseSucceeded && firstError == null) {
      handle._released = true;
      if (identical(_live, handle)) _live = null;
      return;
    }

    await _markQuarantined(handle.partition, 'browser_cleanup_incomplete');
    final safe = _safeError(
      firstError ?? StateError('browser release did not complete'),
      fallback: 'browser_cleanup_incomplete',
    );
    Error.throwWithStackTrace(safe, firstStackTrace ?? StackTrace.current);
  }

  Future<void> _markQuarantined(JwSessionPartitionRef ref, String code) async {
    _quarantinedTokens.add(ref.opaqueToken);
    try {
      await _udfStore.markQuarantined(ref, code);
    } on Object {
      // The original safe failure remains authoritative. The store itself
      // never accepts an unsafe marker code or exposes the path.
    }
  }

  BridgeProtocolError _safeError(Object error, {required String fallback}) {
    if (error is BridgeProtocolError) {
      return BridgeProtocolError(error.code);
    }
    if (error is JwUdfError) {
      return BridgeProtocolError(error.code);
    }
    return BridgeProtocolError(fallback);
  }
}

final class _WindowsJwBrowserSessionHandle implements JwBrowserSessionHandle {
  _WindowsJwBrowserSessionHandle({
    required this.admin,
    required this.partition,
    required this.controller,
  });

  final WindowsJwBrowserSessionAdmin admin;
  JwWebPage? _page;

  @override
  JwWebPage get page =>
      _page ?? (throw const JwCollectionException('webview session is closed'));

  @override
  final JwSessionPartitionRef partition;
  final JwWebviewController controller;
  JwWebViewAdapter? _adapter;
  bool _released = false;
  Future<void>? _closeFuture;

  Future<void> disposeSubscriptions() async {
    final adapter = _adapter;
    if (adapter != null) {
      await adapter.disposeSubscriptions();
      return;
    }
    final lifecycle = controller;
    if (lifecycle is JwWebviewControllerLifecycle) {
      await (lifecycle as JwWebviewControllerLifecycle).disposeSubscriptions();
    }
  }

  Future<void> disposeControllerAndAwaitRelease() async {
    final adapter = _adapter;
    if (adapter != null) {
      await adapter.disposeControllerAndAwaitRelease();
      return;
    }
    final lifecycle = controller;
    if (lifecycle is! JwWebviewControllerLifecycle) {
      throw const JwCollectionException(
        'webview controller release barrier is unavailable',
      );
    }
    await (lifecycle as JwWebviewControllerLifecycle)
        .disposeControllerAndAwaitRelease();
  }

  @override
  Future<void> close() => admin._closeLive(this);
}
