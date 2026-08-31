// Constructor seams intentionally keep private ownership fields explicit.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import '../application/sync_coordinator.dart';
import '../data/bridge_client.dart';
import '../domain/sync_state.dart';
import '../../settings/application/minimal_reset_coordinator.dart';
import '../../import/domain/import_result.dart';
import 'jw_job_arbiter.dart';

/// Explicit composition switch. Native WebView2 is the default; setting this
/// to true selects the Python Bridge fallback for the whole runtime, never
/// both channels for one source at once.
const bool kUsePythonBridgeFallback = false;

/// The only login request shape accepted by the UI-facing source gateway.
///
/// The command is intentionally an in-memory value.  A gateway never stores
/// it, publishes it, or includes it in a diagnostic/snapshot payload.
final class FirstLoginCommand {
  const FirstLoginCommand({
    required this.username,
    this.password,
    this.savePassword = false,
  });

  final String username;
  final String? password;
  final bool savePassword;
}

/// Privacy-safe aggregate state exposed to UI and acceptance tooling.
///
/// [phase] and [safeCode] are closed, stable values.  No job/account id,
/// request parameter, URL, DOM or response body is represented here.
final class SourceJobSnapshot {
  const SourceJobSnapshot({
    required String phase,
    String? safeCode,
    int aggregateCount = 0,
  }) : _phase = phase,
       _safeCode = safeCode,
       aggregateCount = aggregateCount < 0 ? 0 : aggregateCount;

  final String _phase;
  final String? _safeCode;
  final int aggregateCount;

  /// Normalize at read time as well as at adapter emission sites. This keeps
  /// the public snapshot a privacy boundary even when a host accidentally
  /// constructs one with a raw phase or transport error code.
  String get phase => _safeSnapshotPhases.contains(_phase) ? _phase : 'failed';

  String? get safeCode => _safeCode == null
      ? null
      : _safeSnapshotCodes.contains(_safeCode)
      ? _safeCode
      : 'sync_failed';

  /// Alias useful to callers that use the shorter persisted-state spelling.
  String? get code => safeCode;

  /// Alias for acceptance code that calls the aggregate a count.
  int get count => aggregateCount;

  Map<String, Object?> toJson() => <String, Object?>{
    'phase': phase,
    if (safeCode != null) 'code': safeCode,
    'aggregateCount': aggregateCount,
  };
}

/// UI-facing source job contract.  Implementations must keep credentials,
/// account identifiers, transport details and raw source payloads private.
abstract interface class SourceJobGateway {
  Stream<SourceJobSnapshot> get states;

  Future<SyncOutcome> firstLogin(FirstLoginCommand command);

  Future<SyncOutcome> sync({
    required String accountId,
    required SyncTrigger trigger,
  });

  Future<void> cancelCurrent();

  Future<void> shutdown();
}

/// Optional ownership marker for gateways that delegate browser-session
/// teardown to the exact session admin they were constructed with. The app
/// runtime uses it to avoid invoking that admin a second time while still
/// closing independent gateway implementations and test doubles normally.
abstract interface class SourceJobSessionOwner {
  bool get ownsBrowserSessions;
}

/// Optional state reader used by the presentation loader.  It is kept
/// separate from [SourceJobGateway] so small host/test implementations only
/// need to satisfy the frozen UI contract.
abstract interface class SourceJobStateReader {
  Future<SyncSourceState> stateFor(String accountId);
}

/// Optional interactive continuation seam.  Interactive login remains owned
/// by the gateway; the page only supplies the user's yes/no decision.
abstract interface class InteractiveSourceJobGateway {
  Future<SyncOutcome> resumeInteractive(
    String jobId, {
    required bool userConfirmed,
  });
}

/// Optional import seam used by the file-import action.  It does not expose
/// the coordinator itself to presentation code.
abstract interface class SourceJobImportReader {
  BundleImport get importBundle;
}

/// Optional privacy-safe diagnostic stage stream.  Diagnostics are not part
/// of [SourceJobSnapshot] and must contain stage names/safe codes only.
abstract interface class SourceJobDiagnosticReader {
  Stream<String> get diagnostics;
}

/// Adapter that serializes the existing [SyncCoordinator] behind one UI
/// gateway and one synchronous [JwJobArbiter] lease.
///
/// The selected bridge is injected by composition.  The adapter does not
/// instantiate NativeJwGateway, BridgeClient, a controller, a session admin,
/// or any UDF path.
final class SourceJobGatewayAdapter
    implements
        SourceJobGateway,
        SourceJobStateReader,
        InteractiveSourceJobGateway,
        SourceJobImportReader,
        SourceJobDiagnosticReader,
        SourceJobSessionOwner,
        ResetWriterPort {
  SourceJobGatewayAdapter({
    required SyncCoordinator coordinator,
    required JwJobArbiter arbiter,
    JwJobKind selectedKind = JwJobKind.sync,
    Future<BridgeGateway> Function()? bridgeFactory,
    BridgeGateway? bridge,
    void Function(BridgeGateway bridge)? invalidateBridge,
    bool ownsBrowserSessions = false,
    void Function(String)? safeDiagnostic,
  }) : _coordinator = coordinator,
       _arbiter = arbiter,
       _selectedKind = selectedKind,
       _bridgeFactory = bridgeFactory,
       _bridge = bridge,
       _invalidateBridge = invalidateBridge,
       _ownsBrowserSessions = ownsBrowserSessions,
       _safeDiagnostic = safeDiagnostic;

  final SyncCoordinator _coordinator;
  final JwJobArbiter _arbiter;
  final JwJobKind _selectedKind;
  final Future<BridgeGateway> Function()? _bridgeFactory;
  BridgeGateway? _bridge;
  final void Function(BridgeGateway bridge)? _invalidateBridge;
  final bool _ownsBrowserSessions;
  final void Function(String)? _safeDiagnostic;

  final StreamController<SourceJobSnapshot> _statesController =
      StreamController<SourceJobSnapshot>.broadcast();
  final StreamController<String> _diagnosticsController =
      StreamController<String>.broadcast();
  StreamSubscription<String>? _bridgeDiagnosticsSubscription;
  SourceJobSnapshot _lastSnapshot = const SourceJobSnapshot(phase: 'idle');
  JwJobLease? _lease;
  Future<SyncOutcome>? _operation;
  Future<SyncOutcome>? _resumeOperation;
  String? _resumeJobId;
  String? _pausedJobId;
  Future<void>? _shutdownFuture;
  Future<void>? _cancelFuture;
  bool _shutdownStarted = false;
  bool _cancelRequested = false;
  bool _quiescing = false;
  Future<void>? _quiesceFuture;
  String? _cancelJobId;
  bool _admissionCancellationIssued = false;
  BridgeGateway? _admissionCancelledBridge;
  int _nextJobNumber = 0;
  int _nextOperationGeneration = 0;
  int? _operationGeneration;

  /// Exposed only for focused tests/composition diagnostics; callers should
  /// use the interface's [states] stream for UI state.
  JwJobArbiter get arbiter => _arbiter;

  /// Drops a selected bridge after another owner has closed it during
  /// admission cancellation. The next operation must resolve a fresh bridge
  /// through the composition factory, after the old bridge has settled.
  void invalidateCachedBridge(BridgeGateway bridge) {
    if (identical(_bridge, bridge)) _bridge = null;
  }

  /// Most recent privacy-safe state. This is an in-memory convenience for
  /// hosts that attach after an emission; it carries no request data.
  SourceJobSnapshot get latestSnapshot => _lastSnapshot;

  @override
  Stream<SourceJobSnapshot> get states => _statesController.stream;

  /// A native bridge carries the exact session-admin ownership marker through
  /// this adapter. Once selected, the runtime must not invoke that admin a
  /// second time after the bridge has attempted its own ordered teardown.
  @override
  bool get ownsBrowserSessions =>
      _ownsBrowserSessions ||
      (_bridge is SourceJobSessionOwner &&
          (_bridge! as SourceJobSessionOwner).ownsBrowserSessions);

  @override
  BundleImport
  get importBundle => (bytes, {required accountId, required origin}) {
    // Terminal app shutdown and reset maintenance must cover the presentation
    // import callback too; a picker/confirmation continuation may retain this
    // function after its page has started disposing.
    if (_shutdownStarted || _quiescing) {
      return Future<ImportResult>.error(StateError('maintenance_in_progress'));
    }
    return _coordinator.importBundle(
      bytes,
      accountId: accountId,
      origin: origin,
    );
  };

  /// Closes gateway admission before awaiting coordinator cancellation so the
  /// arbiter lease cannot be released while a late operation is still being
  /// attached to this adapter.
  @override
  Future<void> quiesce() {
    final existing = _quiesceFuture;
    if (existing != null) return existing;
    // This is the synchronous prefix for the real file-import path. The
    // coordinator normally closes this flag before invoking gatewayQuiesce,
    // but direct adapter users (SyncPage's picker continuation) must get the
    // same fixed barrier when they quiesce the gateway itself.
    _coordinator.closeResetAdmission();
    _quiescing = true;
    final operation = _quiesceImpl();
    _quiesceFuture = operation;
    unawaited(
      operation.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(_quiesceFuture, operation)) _quiesceFuture = null;
        },
      ),
    );
    return operation;
  }

  Future<void> _quiesceImpl() async {
    Object? firstError;
    StackTrace? firstStack;
    try {
      await cancelCurrent();
    } on Object catch (error, stack) {
      firstError = error;
      firstStack = stack;
    }
    final operation = _operation;
    if (operation != null) {
      try {
        await operation;
      } on Object catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    // File imports can be admitted without an arbiter lease. They must still
    // settle when native-job cancellation reports a failure.
    try {
      await _coordinator.settleImports();
    } on Object catch (error, stack) {
      firstError ??= error;
      firstStack ??= stack;
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack ?? StackTrace.current);
    }
  }

  @override
  Future<void> resume() async {
    if (_shutdownStarted) return;
    _quiescing = false;
    _quiesceFuture = null;
    _coordinator.openResetAdmission();
  }

  @override
  Stream<String> get diagnostics {
    _attachDiagnostics(_bridge);
    return _diagnosticsController.stream;
  }

  @override
  Future<SyncSourceState> stateFor(String accountId) async {
    return _coordinator.stateFor(SyncSource.jw, accountId);
  }

  @override
  Future<SyncOutcome> firstLogin(FirstLoginCommand command) {
    if (_shutdownStarted || _quiescing) {
      return Future<SyncOutcome>.value(
        const SyncFailed(SyncSource.jw, code: 'runtime_shutdown'),
      );
    }
    final username = command.username.trim();
    if (username.isEmpty) {
      _emit(
        const SourceJobSnapshot(phase: 'failed', safeCode: 'invalid_arguments'),
      );
      return Future<SyncOutcome>.value(
        const SyncFailed(SyncSource.jw, code: 'invalid_arguments'),
      );
    }
    return _start(
      kind: JwJobKind.firstLogin,
      operation: () => _coordinator.firstLoginSync(
        SyncSource.jw,
        username: username,
        password: command.password,
        savePassword: command.savePassword,
      ),
    );
  }

  @override
  Future<SyncOutcome> sync({
    required String accountId,
    required SyncTrigger trigger,
  }) {
    if (_shutdownStarted || _quiescing) {
      return Future<SyncOutcome>.value(
        const SyncFailed(SyncSource.jw, code: 'runtime_shutdown'),
      );
    }
    return _start(
      kind: _selectedKind == JwJobKind.firstLogin
          ? JwJobKind.sync
          : _selectedKind,
      operation: () => _coordinator.sync(
        SyncSource.jw,
        trigger: trigger,
        accountId: accountId,
      ),
    );
  }

  Future<SyncOutcome> _start({
    required JwJobKind kind,
    required Future<SyncOutcome> Function() operation,
  }) {
    if (_quiescing || _shutdownStarted) {
      return Future<SyncOutcome>.value(
        const SyncFailed(SyncSource.jw, code: 'runtime_shutdown'),
      );
    }
    final lease = _tryAcquire(kind);
    if (lease == null) {
      _emit(const SourceJobSnapshot(phase: 'failed', safeCode: 'bridge_busy'));
      return Future<SyncOutcome>.value(
        const SyncFailed(SyncSource.jw, code: 'bridge_busy'),
      );
    }

    // Assign ownership before invoking the coordinator.  Its fake/test
    // implementations may complete synchronously; a second caller must still
    // observe the held lease in that same turn.
    _lease = lease;
    _pausedJobId = null;
    _cancelRequested = false;
    _admissionCancellationIssued = false;
    _admissionCancelledBridge = null;
    final generation = ++_nextOperationGeneration;
    _operationGeneration = generation;
    _emit(const SourceJobSnapshot(phase: 'starting'));
    late final Future<SyncOutcome> tracked;
    try {
      final pending = Future<SyncOutcome>.sync(() async {
        // Composition may supply a lazy Python Bridge factory.  Resolve it
        // here so shutdown can close the exact bridge selected for this
        // runtime; the coordinator receives the same cached factory.
        if (_bridgeFactory != null && _bridge == null) {
          try {
            await _resolveBridge();
          } on BridgeProtocolError catch (error) {
            if (_shutdownStarted) {
              return const SyncFailed(SyncSource.jw, code: 'runtime_shutdown');
            }
            if (_cancelRequested) {
              return const SyncCancelled(SyncSource.jw);
            }
            return SyncFailed(SyncSource.jw, code: _safeCode(error.code));
          } on Object {
            if (_shutdownStarted) {
              return const SyncFailed(SyncSource.jw, code: 'runtime_shutdown');
            }
            if (_cancelRequested) {
              return const SyncCancelled(SyncSource.jw);
            }
            return const SyncFailed(SyncSource.jw, code: 'sync_failed');
          }
        }
        if (_shutdownStarted) {
          return const SyncFailed(SyncSource.jw, code: 'runtime_shutdown');
        }
        if (_cancelRequested) {
          final bridge = _bridge;
          if (bridge != null) await _cancelBridgeAdmission(bridge);
          return const SyncCancelled(SyncSource.jw);
        }
        return operation();
      });
      tracked = _track(pending, lease, generation);
    } on Object catch (error, stack) {
      _release(lease);
      _emit(const SourceJobSnapshot(phase: 'failed', safeCode: 'sync_failed'));
      return Future<SyncOutcome>.error(error, stack);
    }
    _operation = tracked;
    return tracked;
  }

  Future<SyncOutcome> _track(
    Future<SyncOutcome> operation,
    JwJobLease lease,
    int generation,
  ) async {
    try {
      final outcome = await operation;
      if (outcome is SyncNeedsUserAction) {
        _pausedJobId = outcome.jobId;
        _emit(const SourceJobSnapshot(phase: 'needs_user_login'));
        // Keep the lease while the coordinator owns a paused terminal
        // boundary.  Only resume/cancel settlement may release it.
        return outcome;
      }
      _emitSnapshotForOutcome(outcome);
      if (!_cancelRequested && identical(_operationGeneration, generation)) {
        _operation = null;
        _release(lease);
      }
      return outcome;
    } on Object {
      _emit(const SourceJobSnapshot(phase: 'failed', safeCode: 'sync_failed'));
      if (!_cancelRequested && identical(_operationGeneration, generation)) {
        _operation = null;
        _release(lease);
      }
      rethrow;
    } finally {
      if (_pausedJobId == null &&
          !_cancelRequested &&
          identical(_operationGeneration, generation)) {
        _operation = null;
      }
    }
  }

  JwJobLease? _tryAcquire(JwJobKind kind) {
    try {
      return _arbiter.acquire(jobId: 'ui:${++_nextJobNumber}', kind: kind);
    } on BridgeProtocolError catch (error) {
      if (error.code == 'bridge_busy') return null;
      rethrow;
    }
  }

  @override
  Future<SyncOutcome> resumeInteractive(
    String jobId, {
    required bool userConfirmed,
  }) {
    if (_shutdownStarted || _quiescing) {
      return Future<SyncOutcome>.value(
        const SyncFailed(SyncSource.jw, code: 'runtime_shutdown'),
      );
    }
    final existing = _resumeOperation;
    if (existing != null) {
      if (_resumeJobId == jobId) return existing;
      return Future<SyncOutcome>.value(
        const SyncFailed(SyncSource.jw, code: 'bridge_busy'),
      );
    }
    final cancelling = _cancelFuture;
    if (cancelling != null && _cancelRequested && _cancelJobId == jobId) {
      return cancelling.then<SyncOutcome>(
        (_) => const SyncCancelled(SyncSource.jw),
      );
    }
    if (cancelling != null) {
      return Future<SyncOutcome>.value(
        const SyncFailed(SyncSource.jw, code: 'bridge_busy'),
      );
    }
    final lease = _lease;
    if (lease == null || _pausedJobId != jobId) {
      return Future<SyncOutcome>.value(
        const SyncFailed(SyncSource.jw, code: 'job_not_found'),
      );
    }
    final generation = _operationGeneration;
    if (generation == null) {
      return Future<SyncOutcome>.value(
        const SyncFailed(SyncSource.jw, code: 'job_not_found'),
      );
    }
    final operation = _resumeInteractiveImpl(
      jobId,
      userConfirmed: userConfirmed,
      lease: lease,
      generation: generation,
    );
    // Claim the resume before its first asynchronous continuation. Duplicate
    // resume calls now join this exact Future rather than racing the paused
    // marker or releasing the arbiter lease behind the active collection.
    _resumeJobId = jobId;
    _resumeOperation = operation;
    _operation = operation;
    unawaited(
      operation.then<void>(
        (_) {
          if (identical(_resumeOperation, operation)) {
            _resumeOperation = null;
            _resumeJobId = null;
          }
        },
        onError: (Object _, StackTrace _) {
          if (identical(_resumeOperation, operation)) {
            _resumeOperation = null;
            _resumeJobId = null;
          }
        },
      ),
    );
    return operation;
  }

  Future<SyncOutcome> _resumeInteractiveImpl(
    String jobId, {
    required bool userConfirmed,
    required JwJobLease lease,
    required int generation,
  }) async {
    try {
      final outcome = await _coordinator.resumeInteractive(
        jobId,
        userConfirmed: userConfirmed,
      );
      if (outcome is SyncNeedsUserAction) {
        _pausedJobId = outcome.jobId;
        _emit(const SourceJobSnapshot(phase: 'needs_user_login'));
        return outcome;
      }
      _pausedJobId = null;
      _emitSnapshotForOutcome(outcome);
      if (!_cancelRequested && identical(_operationGeneration, generation)) {
        _operation = null;
        _release(lease);
      }
      return outcome;
    } on Object catch (error) {
      _pausedJobId = null;
      final safe = _safeError(error, fallback: 'sync_failed');
      _emit(SourceJobSnapshot(phase: 'failed', safeCode: safe.code));
      if (!_cancelRequested && identical(_operationGeneration, generation)) {
        _operation = null;
        _release(lease);
      }
      return SyncFailed(SyncSource.jw, code: safe.code);
    }
  }

  @override
  Future<void> cancelCurrent() {
    final existing = _cancelFuture;
    if (existing != null) return existing;
    final operation = _cancelCurrentImpl();
    _cancelFuture = operation;
    unawaited(
      operation.then<void>(
        (_) {
          if (identical(_cancelFuture, operation)) _cancelFuture = null;
        },
        onError: (Object _, StackTrace _) {
          if (identical(_cancelFuture, operation)) _cancelFuture = null;
        },
      ),
    );
    return operation;
  }

  Future<void> _cancelCurrentImpl() async {
    final lease = _lease;
    if (lease == null) return;
    final generation = _operationGeneration;
    final operationAtStart = _operation;
    _cancelRequested = true;
    _cancelJobId = _resumeJobId ?? _pausedJobId;
    final coordinatorOwnsBridge =
        _coordinator.hasCurrentJob || _coordinator.hasAdmittedBridge;

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

    final resumed = _resumeOperation;
    final paused = _pausedJobId;
    if (resumed != null) {
      // A resumed collection has already consumed the coordinator's paused
      // marker. Cancel the active job, then join the same resumed Future.
      await attempt(_coordinator.cancelCurrent);
    } else if (paused != null) {
      await attempt(() async {
        await _coordinator.resumeInteractive(paused, userConfirmed: false);
      });
      _pausedJobId = null;
    } else {
      await attempt(_coordinator.cancelCurrent);
    }
    final operation = _operation ?? operationAtStart;
    if (operation != null) {
      await attempt(() async {
        await operation;
      });
    }
    if (!coordinatorOwnsBridge) {
      final bridge = _bridge;
      if (bridge != null && !identical(_admissionCancelledBridge, bridge)) {
        await attempt(() => _cancelBridgeAdmission(bridge));
      }
    }
    _emit(const SourceJobSnapshot(phase: 'cancelled', safeCode: 'cancelled'));
    if (generation != null &&
        identical(_lease, lease) &&
        identical(_operationGeneration, generation)) {
      _operation = null;
      _release(lease);
    }
    final error = firstError;
    if (error != null) {
      Error.throwWithStackTrace(
        _safeError(error, fallback: 'cancelled'),
        firstStack ?? StackTrace.current,
      );
    }
  }

  @override
  Future<void> shutdown() {
    final existing = _shutdownFuture;
    if (existing != null) return existing;
    _shutdownStarted = true;
    _quiescing = true;
    final operation = _shutdownImpl();
    _shutdownFuture = operation;
    unawaited(
      operation.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          // A failed shutdown retains the selected bridge for a real retry;
          // do not cache the failed Future forever or drop ownership.
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

    if (_lease != null) {
      await attempt(cancelCurrent);
    }
    final bridge = _bridge;
    if (bridge != null) {
      await attempt(bridge.shutdown);
    }
    final diagnosticsSubscription = _bridgeDiagnosticsSubscription;
    _bridgeDiagnosticsSubscription = null;
    if (diagnosticsSubscription != null) {
      await attempt(diagnosticsSubscription.cancel);
    }
    if (!_statesController.isClosed) {
      await attempt(_statesController.close);
    }
    if (!_diagnosticsController.isClosed) {
      await attempt(_diagnosticsController.close);
    }
    final error = firstError;
    if (error != null) {
      final safe = _safeError(error, fallback: 'runtime_shutdown_failed');
      try {
        _safeDiagnostic?.call(safe.code);
      } on Object {
        // An observer cannot make teardown fail differently.
      }
      Error.throwWithStackTrace(safe, firstStack ?? StackTrace.current);
    }
  }

  Future<BridgeGateway> _resolveBridge() async {
    final existing = _bridge;
    if (existing != null) return existing;
    final factory = _bridgeFactory;
    if (factory == null) {
      throw const BridgeProtocolError('request_failed');
    }
    final resolved = await factory();
    if (_shutdownStarted) {
      // A lazy fallback process may finish starting after runtime shutdown has
      // already drained its active job. It was never published to callers;
      // close this late result immediately so the shutdown owns no gap.
      await resolved.shutdown();
      throw StateError('source gateway is shut down');
    }
    _bridge ??= resolved;
    if (!identical(_bridge, resolved)) {
      // Another synchronous selection won the cache while this factory was
      // awaiting. Do not leak the duplicate process/bridge.
      await resolved.shutdown();
    }
    _attachDiagnostics(_bridge);
    if (_cancelRequested) {
      final selected = _bridge!;
      await _cancelBridgeAdmission(selected);
      return selected;
    }
    return _bridge!;
  }

  Future<void> _cancelBridgeAdmission(BridgeGateway bridge) async {
    if (_admissionCancellationIssued) return;
    _admissionCancellationIssued = true;
    _admissionCancelledBridge = bridge;
    if (bridge is BridgeAdmissionCancellation) {
      await (bridge as BridgeAdmissionCancellation).cancelAdmission();
      return;
    }
    // A bridge without a pre-job cancellation endpoint is still owned by
    // this gateway. Its shutdown path is the safe admission cleanup fallback.
    try {
      await bridge.shutdown();
    } finally {
      if (identical(_bridge, bridge)) _bridge = null;
      try {
        _invalidateBridge?.call(bridge);
      } on Object {
        // Cache invalidation is best effort after the bridge has been closed;
        // teardown must continue to release the current lease.
      }
    }
  }

  void _attachDiagnostics(BridgeGateway? bridge) {
    if (_diagnosticsController.isClosed ||
        _bridgeDiagnosticsSubscription != null) {
      return;
    }
    final reader = bridge is SourceJobDiagnosticReader
        ? bridge as SourceJobDiagnosticReader
        : null;
    if (reader == null) return;
    _bridgeDiagnosticsSubscription = reader.diagnostics.listen((event) {
      if (!_diagnosticsController.isClosed) _diagnosticsController.add(event);
    });
  }

  void _release(JwJobLease lease) {
    if (!identical(_lease, lease)) return;
    _arbiter.release(lease);
    _lease = null;
    _cancelRequested = false;
    _cancelJobId = null;
    _admissionCancellationIssued = false;
    _operationGeneration = null;
  }

  void _emitSnapshotForOutcome(SyncOutcome outcome) {
    switch (outcome) {
      case SyncSucceeded(:final importedEntityCount):
        _emit(
          SourceJobSnapshot(
            phase: 'succeeded',
            aggregateCount: importedEntityCount,
          ),
        );
      case SyncCancelled():
        _emit(
          const SourceJobSnapshot(phase: 'cancelled', safeCode: 'cancelled'),
        );
      case SyncFailed(:final code):
        _emit(SourceJobSnapshot(phase: 'failed', safeCode: _safeCode(code)));
      case SyncNeedsUserAction():
      case SyncStarted():
        _emit(
          const SourceJobSnapshot(phase: 'failed', safeCode: 'sync_failed'),
        );
      case SyncSkipped(:final reason):
        _emit(SourceJobSnapshot(phase: 'failed', safeCode: _safeCode(reason)));
    }
  }

  void _emit(SourceJobSnapshot snapshot) {
    _lastSnapshot = snapshot;
    if (!_statesController.isClosed) _statesController.add(snapshot);
  }

  BridgeProtocolError _safeError(Object error, {required String fallback}) {
    if (error is BridgeProtocolError) {
      return BridgeProtocolError(_safeCodeWithFallback(error.code, fallback));
    }
    return BridgeProtocolError(fallback);
  }
}

const Set<String> _safeSnapshotCodes = <String>{
  'account_mismatch',
  'bridge_busy',
  'cancelled',
  'collection_failed',
  'first_login_failed',
  'invalid_arguments',
  'job_not_found',
  'login_timeout',
  'no_account',
  'reauthentication_failed',
  'reauthentication_required',
  'runtime_shutdown',
  'runtime_shutdown_failed',
  'sync_failed',
};

const Set<String> _safeSnapshotPhases = <String>{
  'idle',
  'starting',
  'running',
  'needs_user_login',
  'succeeded',
  'complete',
  'failed',
  'cancelled',
};

String _safeCode(String? code) =>
    code != null && _safeSnapshotCodes.contains(code) ? code : 'sync_failed';

String _safeCodeWithFallback(String? code, String fallback) {
  if (code != null && _safeSnapshotCodes.contains(code)) return code;
  return _safeSnapshotCodes.contains(fallback) ? fallback : 'sync_failed';
}
