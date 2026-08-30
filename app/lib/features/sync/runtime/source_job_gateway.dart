// Constructor seams intentionally keep private ownership fields explicit.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import '../application/sync_coordinator.dart';
import '../data/bridge_client.dart';
import '../domain/sync_state.dart';
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
        SourceJobSessionOwner {
  SourceJobGatewayAdapter({
    required SyncCoordinator coordinator,
    required JwJobArbiter arbiter,
    JwJobKind selectedKind = JwJobKind.sync,
    Future<BridgeGateway> Function()? bridgeFactory,
    BridgeGateway? bridge,
    bool ownsBrowserSessions = false,
    void Function(String)? safeDiagnostic,
  }) : _coordinator = coordinator,
       _arbiter = arbiter,
       _selectedKind = selectedKind,
       _bridgeFactory = bridgeFactory,
       _bridge = bridge,
       _ownsBrowserSessions = ownsBrowserSessions,
       _safeDiagnostic = safeDiagnostic;

  final SyncCoordinator _coordinator;
  final JwJobArbiter _arbiter;
  final JwJobKind _selectedKind;
  final Future<BridgeGateway> Function()? _bridgeFactory;
  BridgeGateway? _bridge;
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
  String? _pausedJobId;
  Future<void>? _shutdownFuture;
  Future<void>? _cancelFuture;
  bool _shutdownStarted = false;
  int _nextJobNumber = 0;

  /// Exposed only for focused tests/composition diagnostics; callers should
  /// use the interface's [states] stream for UI state.
  JwJobArbiter get arbiter => _arbiter;

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
  BundleImport get importBundle => _coordinator.importBundle;

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
    if (_shutdownStarted) {
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
    if (_shutdownStarted) {
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
            return SyncFailed(SyncSource.jw, code: _safeCode(error.code));
          } on Object {
            if (_shutdownStarted) {
              return const SyncFailed(SyncSource.jw, code: 'runtime_shutdown');
            }
            return const SyncFailed(SyncSource.jw, code: 'sync_failed');
          }
        }
        if (_shutdownStarted) {
          return const SyncFailed(SyncSource.jw, code: 'runtime_shutdown');
        }
        return operation();
      });
      tracked = _track(pending, lease);
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
      _release(lease);
      return outcome;
    } on Object {
      _emit(const SourceJobSnapshot(phase: 'failed', safeCode: 'sync_failed'));
      _release(lease);
      rethrow;
    } finally {
      if (_pausedJobId == null) {
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
  }) async {
    if (_shutdownStarted) {
      return const SyncFailed(SyncSource.jw, code: 'runtime_shutdown');
    }
    final lease = _lease;
    if (lease == null || _pausedJobId != jobId) {
      return const SyncFailed(SyncSource.jw, code: 'job_not_found');
    }
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
      _release(lease);
      _operation = null;
      return outcome;
    } on Object catch (error) {
      _pausedJobId = null;
      final safe = _safeError(error, fallback: 'sync_failed');
      _emit(SourceJobSnapshot(phase: 'failed', safeCode: safe.code));
      _release(lease);
      _operation = null;
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

    final paused = _pausedJobId;
    if (paused != null) {
      await attempt(() async {
        await _coordinator.resumeInteractive(paused, userConfirmed: false);
      });
      _pausedJobId = null;
    } else {
      await attempt(_coordinator.cancelCurrent);
    }
    final operation = _operation;
    if (operation != null) {
      await attempt(() async {
        await operation;
      });
    }
    _emit(const SourceJobSnapshot(phase: 'cancelled', safeCode: 'cancelled'));
    _release(lease);
    _operation = null;
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
    return _bridge!;
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
