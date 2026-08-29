// M7: `NativeJwGateway` — a `BridgeGateway`-compatible shell over the native
// WebView2 JW collection pipeline.
//
// The minimal sync coordinator (SyncCoordinator) speaks the Bridge protocol
// shape (capabilities / startCollection / poll / resumeLogin / cancel /
// shutdown). This gateway implements that same surface but drives the native
// `JwCollector` over the real `JwWebViewAdapter` instead of a Python Bridge
// child process. The sync layer above is untouched (`SyncCoordinator` /
// `SyncSource` stay identical).
//
// Semantics:
//   - `capabilities()` returns the fixed configured semester
//     (`461 / 2026fall / 2026 秋季学期`, from `generated_source_defaults.dart`).
//     No dynamic semester discovery in minimal (documented boundary).
//   - `startCollection` starts a `JwCollector` job (one collector per job so
//     the gateway-side jobId matches the collector's event stream) and buffers
//     its `SourceCollectionEvent`s in the Bridge poll shape.
//   - `poll` returns new events since `after`, plus the terminal `result`
//     (the SourceBundle map) / `errorCode`.
//   - `resumeLogin` / `cancel` forward to the owning collector; `shutdown`
//     closes the active adapter/page.
//
// Concurrency: the `SyncCoordinator` serializes all sync entry points through
// its `_busy` flag, so this gateway never runs two jobs concurrently in
// practice; `bridge_busy` semantics are preserved at the coordinator layer.

import 'dart:async';

import '../../../core/config/generated_source_defaults.dart';
import '../data/bridge_client.dart'
    show
        BridgeCapabilities,
        BridgeJob,
        BridgeJobPoll,
        BridgeProtocolError,
        BridgeSemesterCapability,
        BridgeGateway;
import '../domain/sync_state.dart' show SyncSource;
import 'jw_collector.dart';
import 'jw_web_page.dart' show defaultLoginTimeout;
import 'jw_source_bundle_builder.dart' show defaultDartProducer;
import 'jw_web_session.dart' show JwWebviewController;
import 'jw_webview_adapter.dart';
import 'jw_webview_surface_host.dart';
import 'source_collection_gateway.dart';

// Constructor parameters keep public-facing names (not private-field
// initializing formals); the lint is cosmetic only.
// ignore_for_file: prefer_initializing_formals

/// The configured default semester triple (from
/// `core/config/generated_source_defaults.dart`; cannot be derived from the
/// calendar year — red line).
const BridgeSemesterCapability kDefaultJwSemester = BridgeSemesterCapability(
  semesterId: kDefaultJwSemesterId,
  semesterKey: kDefaultJwSemesterKey,
  displayName: kDefaultJwSemesterDisplayName,
);

/// Whether the minimal sync page uses the Python Bridge fallback instead of
/// the native WebView2 channel. Kept at false so the native channel is the
/// default and the Bridge remains switchable for emergency fallback (red line:
/// 一源一通道, never both at once).
const bool kUsePythonBridgeFallback = false;

typedef JwCollectorFactory = JwCollector Function(String jobId);

/// Implements the Bridge gateway surface over the native WebView2 collector.
class NativeJwGateway implements BridgeGateway {
  NativeJwGateway({
    JwWebviewControllerFactory? controllerFactory,
    BridgeSemesterCapability semester = kDefaultJwSemester,
    Future<String?> Function(String accountId)? userDataPathForAccount,
    ProductionJwControllerFactory? productionControllerFactory,
    JwCollectorFactory? collectorFactory,
    // Keep the pre-Task-2 seam source-compatible while callers migrate to
    // the account-bound resolver. It is only consulted when the new resolver
    // is absent.
    Future<String> Function()? userDataPath,
    Duration controllerCreationTimeout = defaultLoginTimeout,
    void Function(String)? safeDiagnostic,
  }) : _controllerFactory = controllerFactory,
       _semester = semester,
       _userDataPathForAccount = userDataPathForAccount,
       _productionControllerFactory = productionControllerFactory,
       _collectorFactory = collectorFactory,
       _legacyUserDataPath = userDataPath,
       _controllerCreationTimeout = controllerCreationTimeout,
       _externalDiagnostic = safeDiagnostic;

  final JwWebviewControllerFactory? _controllerFactory;
  final BridgeSemesterCapability _semester;
  final Future<String?> Function(String accountId)? _userDataPathForAccount;
  final ProductionJwControllerFactory? _productionControllerFactory;
  final JwCollectorFactory? _collectorFactory;
  final Future<String> Function()? _legacyUserDataPath;
  final Duration _controllerCreationTimeout;

  /// Optional caller-supplied privacy-safe diagnostic sink (stage names and
  /// stable error codes only — never URL/account/query/DOM). Wired through to
  /// the adapter's `safeDiagnostic`.
  final void Function(String)? _externalDiagnostic;

  /// Broadcast stream of privacy-safe stage diagnostics emitted by the active
  /// adapter (e.g. `attempt:jw.portal.login`, `activationDispatched`,
  /// `urlMatched:target`, `domReady:target`, …). Zero listeners is safe.
  late final StreamController<String> _diagnosticsController =
      StreamController<String>.broadcast();

  /// Stream of privacy-safe stage diagnostics (see [_externalDiagnostic]).
  Stream<String> get diagnostics => _diagnosticsController.stream;

  /// Forwards a privacy-safe stage to the caller sink and the diagnostics
  /// stream. Never mutates collection behavior; a throwing consumer is safe.
  void _emitDiagnostic(String event) {
    try {
      _externalDiagnostic?.call(event);
      if (!_diagnosticsController.isClosed) {
        _diagnosticsController.add(event);
      }
    } on Object {
      // Diagnostics must never break collection.
    }
  }

  /// The sole stable surface host for this gateway's controller generation.
  /// The page mounts [surfaceHost.widget] once; it never receives a raw
  /// WebView widget or controller.
  final JwWebViewSurfaceHost surfaceHost = JwWebViewSurfaceHost();

  final Map<String, JwCollector> _collectors = <String, JwCollector>{};
  final Map<String, StreamSubscription<SourceCollectionEvent>>
  _collectorSubscriptions =
      <String, StreamSubscription<SourceCollectionEvent>>{};
  final Map<String, List<Map<String, dynamic>>> _eventBuffers =
      <String, List<Map<String, dynamic>>>{};
  final Map<String, bool> _terminal = <String, bool>{};
  final Map<String, Map<String, dynamic>?> _results =
      <String, Map<String, dynamic>?>{};
  final Map<String, String?> _errorCodes = <String, String?>{};
  final Map<String, Completer<void>> _settlements = <String, Completer<void>>{};
  final Map<String, Completer<void>> _changes = <String, Completer<void>>{};
  final Map<String, bool> _cancelRequested = <String, bool>{};
  String? _controllerAccountId;
  bool _shutdown = false;

  static const _pollWait = Duration(milliseconds: 250);

  /// Concurrent calls share one shutdown future, so callers can safely await
  /// the same ordered teardown exactly once.
  Future<void>? _shutdownFuture;

  /// The WebView2 environment is configured ONCE per gateway (the plugin's
  /// `initializeEnvironment` blocks the platform thread and must not race a
  /// previous environment/UDF teardown — observed as an AppHang when called
  /// again while the previous browser process was still draining). All jobs
  /// of this gateway reuse one controller, which also preserves the login
  /// session across jobs on the same UDF (full-branch semantics).
  JwWebviewController? _sharedController;
  Future<JwWebviewController>? _controllerCreation;

  /// Releases a controller that finished creating after this gateway had
  /// already entered shutdown. It was never stored or attached, so the
  /// gateway owns this one best-effort cleanup sequence exclusively.
  Future<void> _disposeControllerAfterShutdown(
    JwWebviewController controller,
  ) async {
    Object? firstError;
    StackTrace? firstStack;

    Future<void> attempt(Future<void> Function() operation) async {
      try {
        await operation();
      } on Object catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }

    await attempt(controller.stop);
    await attempt(controller.clearBrowsingDataAll);
    await attempt(controller.dispose);

    final error = firstError;
    if (error != null) {
      Error.throwWithStackTrace(error, firstStack ?? StackTrace.current);
    }
  }

  Future<JwWebviewController> _controller() async {
    if (_shutdown) throw StateError('gateway is shut down');
    final existing = _sharedController;
    if (existing != null) return existing;
    // Join an in-flight creation instead of racing a second environment.
    final inFlight = _controllerCreation;
    if (inFlight != null) return inFlight;
    final creation = () async {
      try {
        final factory = _controllerFactory;
        final controller = factory != null
            ? await factory()
            : await _createProductionController();
        if (_shutdown) {
          await _disposeControllerAfterShutdown(controller);
          throw StateError('gateway is shut down');
        }
        // Store first so the host and shutdown always observe the exact
        // controller whose environment was initialized.
        _sharedController = controller;
        await surfaceHost.attach(controller);
        return controller;
      } finally {
        _controllerCreation = null;
      }
    }();
    _controllerCreation = creation;
    return creation;
  }

  Future<JwWebviewController> _createProductionController() async {
    final accountId = _controllerAccountId;
    if (accountId == null) {
      throw StateError('controller account is not bound');
    }
    final userDataPath = _userDataPathForAccount != null
        ? await _userDataPathForAccount!(accountId)
        : _legacyUserDataPath == null
        ? null
        : await _legacyUserDataPath!();
    final productionFactory = _productionControllerFactory;
    if (productionFactory != null) {
      return productionFactory(
        userDataPath: userDataPath,
        safeDiagnostic: _emitDiagnostic,
      );
    }
    return createProductionJwWebviewController(
      userDataPath: userDataPath,
      safeDiagnostic: _emitDiagnostic,
    );
  }

  /// One shared adapter per gateway. Jobs reuse it so (a) the visible
  /// WebView surface stays stable across jobs and (b) the login session on
  /// the shared UDF survives between jobs (the CAS cookie is one-shot per
  /// submit but the JW session cookie persists). Controller ownership stays
  /// with the gateway; the adapter only stops navigation on close.
  JwWebViewAdapter? _sharedAdapter;

  JwWebViewAdapter _makeAdapter() {
    final existing = _sharedAdapter;
    if (existing != null) return existing;
    final adapter = _GatewayOwnedJwWebViewAdapter(
      controllerFactory: _controller,
      safeDiagnostic: _emitDiagnostic,
    );
    _sharedAdapter = adapter;
    return adapter;
  }

  @override
  Future<BridgeCapabilities> capabilities() async =>
      BridgeCapabilities(jwSemester: _semester);

  @override
  Future<BridgeJob> startCollection({
    required SyncSource source,
    required String accountId,
    required String expectedUsername,
    required BridgeSemesterCapability jwSemester,
  }) async {
    if (_shutdown) throw StateError('gateway is shut down');
    if (source != SyncSource.jw) {
      throw ArgumentError('NativeJwGateway only supports SyncSource.jw');
    }
    final boundAccount = _controllerAccountId;
    if (boundAccount != null && boundAccount != accountId) {
      // Never reuse a controller/UDF for another local account. Keep the
      // failure text opaque; account IDs and physical profile paths must not
      // enter diagnostics or UI exceptions.
      throw StateError('gateway controller is bound to another account');
    }
    _controllerAccountId ??= accountId;

    final jobId = 'native:${DateTime.now().microsecondsSinceEpoch}';
    final adapter = _makeAdapter();

    final collector =
        _collectorFactory?.call(jobId) ??
        JwCollector(
          pageFactory: () => adapter,
          producer: defaultDartProducer,
          jobId: jobId,
        );
    _collectors[jobId] = collector;
    final buffer = <Map<String, dynamic>>[];
    _eventBuffers[jobId] = buffer;
    _terminal[jobId] = false;
    _results[jobId] = null;
    _errorCodes[jobId] = null;
    _settlements[jobId] = Completer<void>();
    _changes[jobId] = Completer<void>();
    _cancelRequested[jobId] = false;

    final subscription = collector
        .startJwCollection(
          accountId: accountId,
          expectedUsername: expectedUsername,
          semester: jwSemester.toJwSemesterConfig(),
        )
        .listen(
          (event) {
            if (!_eventBuffers.containsKey(jobId) || _terminal[jobId] == true) {
              return;
            }
            // Cancellation starts a new terminal generation. A late result
            // from the cancelled generation must not reach the poll result,
            // even if the page had already completed before the cancellation
            // callback was delivered.
            if (_cancelRequested[jobId] == true &&
                (event is CollectionComplete || event is CollectionFailed)) {
              // Preserve the gap-free progress history that preceded the
              // terminal event, but replace a late result/failure with the
              // cancellation terminal for this generation.
              _bufferCancelled(jobId, _nextSequence(jobId));
              return;
            }
            switch (event) {
              case CollectionStarting():
              case CollectionStatus():
              case CollectionNeedsUserLogin():
                _buffer(jobId, <String, dynamic>{
                  'sequence': event.sequence,
                  'phase': event.phase,
                  'jobId': jobId,
                  if (event is CollectionStatus) 'message': event.message,
                });
              case CollectionComplete():
                _buffer(jobId, <String, dynamic>{
                  'sequence': event.sequence,
                  'phase': 'complete',
                  'jobId': jobId,
                });
                _results[jobId] = event.bundle;
                _terminal[jobId] = true;
                _settlements[jobId]?.complete();
              case CollectionFailed():
                _buffer(jobId, <String, dynamic>{
                  'sequence': event.sequence,
                  'phase': 'failed',
                  'jobId': jobId,
                });
                _errorCodes[jobId] = event.errorCode;
                _terminal[jobId] = true;
                _settlements[jobId]?.complete();
              case CollectionCancelled():
                _bufferCancelled(jobId, event.sequence);
            }
          },
          onError: (Object _) {
            if (!_eventBuffers.containsKey(jobId) || _terminal[jobId] == true) {
              return;
            }
            if (_cancelRequested[jobId] == true) {
              _bufferCancelled(jobId, _nextSequence(jobId));
              return;
            }
            _buffer(jobId, <String, dynamic>{
              'sequence': _nextSequence(jobId),
              'phase': 'failed',
              'jobId': jobId,
            });
            _errorCodes[jobId] = 'collection_failed';
            _terminal[jobId] = true;
            _settlements[jobId]?.complete();
          },
          onDone: () {
            // JwCollector normally emits one terminal event before closing. If a
            // broken implementation closes early, still settle the job with a
            // buffered terminal failure so shutdown cannot release its controller
            // while a job remains logically live.
            if (!_eventBuffers.containsKey(jobId) || _terminal[jobId] == true) {
              return;
            }
            if (_cancelRequested[jobId] == true) {
              _bufferCancelled(jobId, _nextSequence(jobId));
              return;
            }
            _buffer(jobId, <String, dynamic>{
              'sequence': _nextSequence(jobId),
              'phase': 'failed',
              'jobId': jobId,
            });
            _errorCodes[jobId] = 'collection_failed';
            _terminal[jobId] = true;
            _settlements[jobId]?.complete();
          },
        );
    // Keep the subscription referenced so it is not collected early. The
    // collector stream closes itself on a terminal event.
    _collectorSubscriptions[jobId] = subscription;

    return BridgeJob(id: jobId, phase: 'starting');
  }

  /// Buffer a non-terminal event and wake waiters. Replacing the completer
  /// before completing the old one closes the snapshot/register race: a poll
  /// that captured the old signal cannot consume a notification intended for
  /// the next poll.
  void _buffer(String jobId, Map<String, dynamic> event) {
    final buffer = _eventBuffers[jobId];
    if (buffer == null || _terminal[jobId] == true) return;
    buffer.add(event);
    _signalChange(jobId);
  }

  int _nextSequence(String jobId) {
    final buffer = _eventBuffers[jobId];
    if (buffer == null || buffer.isEmpty) return 0;
    return (buffer.last['sequence'] as int) + 1;
  }

  void _bufferCancelled(String jobId, int sequence) {
    final buffer = _eventBuffers[jobId];
    if (buffer == null || _terminal[jobId] == true) return;
    buffer.add(<String, dynamic>{
      'sequence': sequence,
      'phase': 'cancelled',
      'jobId': jobId,
    });
    _results[jobId] = null;
    _errorCodes[jobId] = 'cancelled';
    _terminal[jobId] = true;
    _settlements[jobId]?.complete();
    _signalChange(jobId);
  }

  void _signalChange(String jobId) {
    final signal = _changes[jobId];
    if (signal == null) return;
    _changes[jobId] = Completer<void>();
    if (!signal.isCompleted) signal.complete();
  }

  BridgeJobPoll _snapshot(String jobId, int after) {
    final buffer = _eventBuffers[jobId];
    if (buffer == null) {
      throw const BridgeProtocolError('job_not_found');
    }
    final events = buffer
        .where((event) => (event['sequence'] as int) >= after)
        .toList(growable: false);
    final nextSequence = buffer.isEmpty
        ? after
        : (buffer.last['sequence'] as int) + 1;
    return BridgeJobPoll(
      events: events,
      nextSequence: nextSequence,
      terminal: _terminal[jobId] ?? false,
      result: _results[jobId],
      errorCode: _errorCodes[jobId],
    );
  }

  @override
  Future<BridgeJobPoll> poll(String jobId, int after) async {
    // Snapshot before selecting the signal so already-buffered events always
    // return without waiting. The second snapshot closes the only possible
    // synchronous notification gap before the first await.
    final snapshot = _snapshot(jobId, after);
    if (snapshot.events.isNotEmpty || snapshot.terminal) return snapshot;

    final signal = _changes[jobId];
    if (signal == null) throw const BridgeProtocolError('job_not_found');
    final recheck = _snapshot(jobId, after);
    if (recheck.events.isNotEmpty || recheck.terminal) return recheck;

    final timeout = Completer<void>();
    final timer = Timer(_pollWait, timeout.complete);
    try {
      await Future.any<void>(<Future<void>>[signal.future, timeout.future]);
    } finally {
      // A signal normally wins before the timeout. Cancel its timer so
      // fake-async/widget tests and callers do not retain a late timer after
      // the poll has already settled.
      timer.cancel();
    }
    return _snapshot(jobId, after);
  }

  @override
  Future<void> resumeLogin(String jobId, {String? password}) async {
    final collector = _collectors[jobId];
    if (collector == null) throw const BridgeProtocolError('job_not_found');
    await collector.resumeLogin(jobId, password: password);
  }

  @override
  Future<void> cancel(String jobId) async {
    final collector = _collectors[jobId];
    if (collector == null) return;
    if (_terminal[jobId] == true) return;
    _cancelRequested[jobId] = true;
    await collector.cancel(jobId);
  }

  @override
  Future<void> shutdown() async {
    final existing = _shutdownFuture;
    if (existing != null) return existing;
    _shutdown = true;
    final future = _shutdownImpl();
    _shutdownFuture = future;
    return future;
  }

  Future<void> _shutdownImpl() async {
    Object? firstError;
    StackTrace? firstStack;

    void capture(Object error, StackTrace stack) {
      firstError ??= error;
      firstStack ??= stack;
    }

    Future<void> attempt(Future<void> Function() operation) async {
      try {
        await operation();
      } on Object catch (error, stack) {
        capture(error, stack);
      }
    }

    // Ask every non-terminal collector to stop before touching the shared
    // controller. Cancellation unblocks collectors paused for user login;
    // controller.stop below interrupts navigation/fetches in progress.
    final collectorEntries = _collectors.entries.toList(growable: false);
    for (final entry in collectorEntries) {
      if (_terminal[entry.key] == true) continue;
      _cancelRequested[entry.key] = true;
      await attempt(() => entry.value.cancel(entry.key));
    }

    // If creation is already in flight, wait for it so the controller can be
    // stopped and detached rather than leaking a just-created WebView.
    final creation = _controllerCreation;
    if (creation != null) {
      await attempt(() async {
        await creation.timeout(_controllerCreationTimeout);
      });
    }
    final controller = _sharedController;

    // Stop once before settlement to interrupt a collector blocked in native
    // navigation. The ordered cleanup below repeats stop after Flutter has
    // acknowledged surface detachment; the native operation is idempotent.
    Future<void>? initialStop;
    Future<void>? earlyDetach;
    if (controller != null) {
      try {
        // Invoke stop before the first await so native navigation is
        // interrupted immediately, even when settlement is already complete.
        initialStop = controller.stop();
      } on Object catch (error, stack) {
        capture(error, stack);
      }

      // A terminal job has already satisfied its settlement contract. Start
      // the detach in the same synchronous turn so the caller's next Flutter
      // frame can acknowledge unmount before this future awaits anything.
      if (_settlements.values.every((settlement) => settlement.isCompleted)) {
        try {
          earlyDetach = surfaceHost.detachAndAwaitUnmount(controller);
        } on Object catch (error, stack) {
          capture(error, stack);
        }
      }
    }

    if (initialStop != null) {
      await attempt(() async {
        await initialStop;
      });
    }

    // Every job has a settlement future completed only after its terminal
    // event has been buffered. Bound the wait by the existing login/collection
    // timeout so a broken native stream cannot block controller teardown
    // forever.
    final settlements = _settlements.values.toList(growable: false);
    for (final settlement in settlements) {
      if (settlement.isCompleted) continue;
      await attempt(() async {
        await settlement.future.timeout(defaultLoginTimeout);
      });
    }

    if (controller != null) {
      if (earlyDetach != null) {
        await attempt(() async {
          await earlyDetach;
        });
      } else {
        await attempt(() => surfaceHost.detachAndAwaitUnmount(controller));
      }
      await attempt(controller.stop);
      await attempt(controller.clearBrowsingDataAll);
      await attempt(controller.dispose);
      _sharedController = null;
    }

    // Subscriptions and diagnostics are closed last, after all collector and
    // controller cleanup has had a chance to emit privacy-safe stages.
    final subscriptions = _collectorSubscriptions.values.toList(
      growable: false,
    );
    for (final subscription in subscriptions) {
      await attempt(subscription.cancel);
    }
    _collectorSubscriptions.clear();
    _collectors.clear();
    _eventBuffers.clear();
    _terminal.clear();
    _results.clear();
    _errorCodes.clear();
    _settlements.clear();
    _changes.clear();
    _cancelRequested.clear();
    if (!_diagnosticsController.isClosed) {
      await attempt(_diagnosticsController.close);
    }

    final error = firstError;
    if (error != null) {
      Error.throwWithStackTrace(error, firstStack ?? StackTrace.current);
    }
  }
}

/// The gateway keeps one controller across jobs and is the only owner allowed
/// to dispose it. The gateway-owned adapter therefore keeps its close hook
/// inert if a future collector lifecycle asks the page to close. The normal
/// [JwWebViewAdapter] retains its standalone close behavior for direct adapter
/// tests and callers.
final class _GatewayOwnedJwWebViewAdapter extends JwWebViewAdapter {
  _GatewayOwnedJwWebViewAdapter({
    required JwWebviewControllerFactory controllerFactory,
    void Function(String)? safeDiagnostic,
  }) : super(
         controllerFactory: controllerFactory,
         safeDiagnostic: safeDiagnostic,
       );

  @override
  Future<void> close() async {}
}

extension on BridgeSemesterCapability {
  JwSemesterConfig toJwSemesterConfig() => JwSemesterConfig(
    semesterId: semesterId,
    semesterKey: semesterKey,
    displayName: displayName,
  );
}
