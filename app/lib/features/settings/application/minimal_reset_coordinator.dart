import 'dart:async';

import '../../sync/native/windows_jw_udf_store.dart';
import '../../sync/runtime/minimal_jw_runtime.dart';
import 'settings_service.dart';

/// Fixed reset writer boundary used by the minimal application.
///
/// Implementations must close admission synchronously when [quiesce] is
/// called, before their returned future reaches its first asynchronous wait.
/// This is deliberately a small, explicit port rather than a participant
/// registry: the coordinator owns the complete minimal writer list.
abstract interface class ResetWriterPort {
  Future<void> quiesce();

  Future<void> resume();
}

enum MinimalResetPhase {
  idle,
  quiescing,
  clearingDatabase,
  clearingBrowser,
  failed,
}

/// Serializes complete account reset over every writer and both persistent
/// stores.  A failed reset remains in maintenance and can be retried without
/// dropping ownership of an incompletely released runtime or UDF partition.
final class MinimalResetCoordinator {
  MinimalResetCoordinator({
    required this.runtime,
    required this.sync,
    required this.agent,
    required this.reminders,
    required this.settings,
    required this.udfStore,
    required this.recomposeRuntime,
  });

  final MinimalJwRuntime runtime;
  final ResetWriterPort sync;
  final ResetWriterPort agent;
  final ResetWriterPort reminders;
  final SettingsService settings;
  final WindowsJwUdfStore udfStore;
  final Future<void> Function() recomposeRuntime;

  final StreamController<MinimalResetPhase> _phasesController =
      StreamController<MinimalResetPhase>.broadcast(sync: true);
  MinimalResetPhase _phase = MinimalResetPhase.idle;
  Future<void>? _resetFuture;

  Stream<MinimalResetPhase> get phases => _phasesController.stream;

  MinimalResetPhase get phase => _phase;

  /// Starts one complete reset. Concurrent callers join the same operation;
  /// after a failure, calling this method is equivalent to [retryReset].
  Future<void> completeReset() {
    final existing = _resetFuture;
    if (existing != null) return existing;
    if (_phase == MinimalResetPhase.failed) return retryReset();
    return _startReset();
  }

  /// Repeats the reset boundary after a failed maintenance attempt. Database
  /// deletion is intentionally idempotent, while UDF cleanup re-enumerates
  /// persisted partitions so an empty database does not hide stale browser
  /// state.
  Future<void> retryReset() {
    final existing = _resetFuture;
    if (existing != null) return existing;
    return _startReset();
  }

  Future<void> _startReset() {
    final operation = _runReset();
    _resetFuture = operation;
    unawaited(
      operation.then<void>(
        (_) {
          if (identical(_resetFuture, operation)) _resetFuture = null;
        },
        onError: (Object _, StackTrace _) {
          if (identical(_resetFuture, operation)) _resetFuture = null;
        },
      ),
    );
    return operation;
  }

  Future<void> _runReset() async {
    _setPhase(MinimalResetPhase.quiescing);

    // Invoke every quiesce method before the first await. Each concrete
    // writer closes its own admission in the synchronous prefix of quiesce,
    // so a late job/import/reminder cannot slip between these calls.
    final runtimeShutdown = _invoke(runtime.shutdown);
    final syncQuiesce = _invoke(sync.quiesce);
    final agentQuiesce = _invoke(agent.quiesce);
    final reminderQuiesce = _invoke(reminders.quiesce);

    Object? firstFailure;
    StackTrace? firstStack;

    Future<void> settle(Future<void> future) async {
      try {
        await future;
      } on Object catch (error, stack) {
        firstFailure ??= error;
        firstStack ??= stack;
      }
    }

    // The declared order is also the audit order. Every already-admitted
    // writer is awaited even if an earlier stage reports failure.
    await settle(runtimeShutdown);
    await settle(syncQuiesce);
    await settle(agentQuiesce);
    await settle(reminderQuiesce);
    if (firstFailure != null) {
      _setPhase(MinimalResetPhase.failed);
      _throwFailed(firstStack);
    }

    _setPhase(MinimalResetPhase.clearingDatabase);
    await settle(_invoke(settings.clearAllLocalData));

    _setPhase(MinimalResetPhase.clearingBrowser);
    // The UDF store enumerates all persisted partitions, including orphaned
    // entries from earlier launches. It also attempts every partition and
    // retains the first safe failure.
    await settle(_invoke(udfStore.clearAllPartitions));
    if (firstFailure != null) {
      _setPhase(MinimalResetPhase.failed);
      _throwFailed(firstStack);
    }

    // Recomposition must install the fresh runtime while all writer gates
    // remain closed. Only after this callback succeeds may admission reopen.
    try {
      await recomposeRuntime();
    } on Object catch (error, stack) {
      _setPhase(MinimalResetPhase.failed);
      Error.throwWithStackTrace(StateError('reset_failed'), stack);
    }

    final syncResume = _invoke(sync.resume);
    final agentResume = _invoke(agent.resume);
    final reminderResume = _invoke(reminders.resume);
    await settle(syncResume);
    await settle(agentResume);
    await settle(reminderResume);
    if (firstFailure != null) {
      await _closeAdmissionAfterResumeFailure();
      _setPhase(MinimalResetPhase.failed);
      _throwFailed(firstStack);
    }
    _setPhase(MinimalResetPhase.idle);
  }

  /// Resume is the last stage, but it is still part of the reset boundary.
  /// If one writer cannot reopen, close every gate again before surfacing the
  /// failure so a partially resumed app cannot write into a reset account.
  Future<void> _closeAdmissionAfterResumeFailure() async {
    final syncQuiesce = _invoke(sync.quiesce);
    final agentQuiesce = _invoke(agent.quiesce);
    final reminderQuiesce = _invoke(reminders.quiesce);
    for (final future in <Future<void>>[
      syncQuiesce,
      agentQuiesce,
      reminderQuiesce,
    ]) {
      try {
        await future;
      } on Object {
        // Preserve the original resume failure and remain fail-closed even
        // when a secondary writer cleanup also cannot settle.
      }
    }
  }

  Future<void> _invoke(Future<void> Function() action) {
    try {
      final future = action();
      // Attach an immediate observer before invoking the next fixed writer;
      // otherwise a synchronously failed Future could surface as an unhandled
      // error while the coordinator is still closing admission.
      unawaited(future.catchError((_) {}));
      return future;
    } on Object catch (error, stack) {
      final future = Future<void>.error(error, stack);
      unawaited(future.catchError((_) {}));
      return future;
    }
  }

  Never _throwFailed(StackTrace? stack) {
    Error.throwWithStackTrace(
      StateError('reset_failed'),
      stack ?? StackTrace.current,
    );
  }

  void _setPhase(MinimalResetPhase next) {
    _phase = next;
    if (!_phasesController.isClosed) _phasesController.add(next);
  }
}
