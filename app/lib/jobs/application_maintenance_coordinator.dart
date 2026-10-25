import 'dart:async';

import '../core/contracts.dart';
import '../core/settings_contract.dart';
import '../core/public_query_contract.dart';
import '../core/work_lease.dart';

/// Fixed maintenance runner, separate from normal school/session operations.
/// A committed deletion can only be followed by a refresh, never another clear.
final class ApplicationMaintenanceCoordinator {
  ApplicationMaintenanceCoordinator({
    required this.data,
    required this.leases,
    required this.cleanProfiles,
    required this.drainForExit,
    this.readBrowserCleanupPendingCount,
    this.retryBrowserCleanup,
  });
  final ApplicationSettingsDataPort data;
  final WorkLeasePool leases;
  final Future<void> Function(WorkLease) cleanProfiles;
  final Future<void> Function() drainForExit;
  final Future<int?> Function()? readBrowserCleanupPendingCount;
  final Future<int?> Function(WorkLease)? retryBrowserCleanup;
  Future<void> Function()? drainAgent;
  Future<void> Function()? drainReminders;
  Future<void> Function()? prepareReminders;
  Future<void> Function()? resumeRemindersAfterAbort;
  Future<void> Function(MaintenanceKind)? onRefresh;
  final _changes = StreamController<MaintenanceProgress>.broadcast();
  MaintenanceProgress _view = const MaintenanceProgress();
  MaintenanceProgress get view => _view;
  Stream<MaintenanceProgress> get changes => _changes.stream;
  WorkLease? _lease;
  MaintenanceIntent? _intent;
  SettingsWriteReceipt? _receipt;
  MaintenanceKind? _kind;
  Future<void>? _work;
  bool _closed = false;
  bool _remindersPrepared = false;
  bool get isClosed => _closed;
  Future<void>? _closing;

  static SettingsFailureCode failureCode(Object error) {
    if (error is SettingsFailure) {
      return error.code;
    }
    if (error is AppFailure) {
      return switch (error.code) {
        FailureCode.busy => SettingsFailureCode.busy,
        FailureCode.closed => SettingsFailureCode.closed,
        FailureCode.ownershipLost ||
        FailureCode.ownerConflict => SettingsFailureCode.ownershipLost,
        FailureCode.cleanupPending => SettingsFailureCode.cleanupPending,
        _ => SettingsFailureCode.storageFailed,
      };
    }
    if (error is PublicFailure) {
      return switch (error.code) {
        PublicFailureCode.busy => SettingsFailureCode.busy,
        PublicFailureCode.closed => SettingsFailureCode.closed,
        PublicFailureCode.staleReference => SettingsFailureCode.staleContext,
        _ => SettingsFailureCode.storageFailed,
      };
    }
    return SettingsFailureCode.storageFailed;
  }

  void _publish(MaintenancePhase phase, {SettingsFailureCode? failure}) {
    _view = MaintenanceProgress(
      phase: phase,
      kind: _kind,
      failure: failure,
      committed: _receipt != null,
    );
    if (!_closed) {
      _changes.add(_view);
    }
  }

  Future<T> _track<T>(Future<T> Function() body) {
    if (_closed || _closing != null) {
      throw const SettingsFailure(SettingsFailureCode.closed);
    }
    if (_work != null) {
      throw const SettingsFailure(SettingsFailureCode.busy);
    }
    final done = Completer<void>();
    _work = done.future;
    return () async {
      try {
        return await body();
      } finally {
        _work = null;
        done.complete();
      }
    }();
  }

  Future<int?> browserCleanupPendingCount() async {
    final read = readBrowserCleanupPendingCount;
    if (read == null) return null;
    return read();
  }

  /// This maintenance is independent of C3 reset state. Its private C2 lease
  /// prevents a cleanup retry from competing with school, Agent, or model work.
  Future<int?> retryRetiredBrowserCleanup() {
    if (_closed || _closing != null) {
      throw const SettingsFailure(SettingsFailureCode.closed);
    }
    final retry = retryBrowserCleanup;
    if (retry == null) {
      throw const SettingsFailure(SettingsFailureCode.busy);
    }
    if (_view.blocksProduct || _work != null || _lease != null) {
      throw const SettingsFailure(SettingsFailureCode.busy);
    }
    return _track<int?>(() async {
      try {
        _lease = leases.acquire();
      } on AppFailure catch (error) {
        throw SettingsFailure(failureCode(error));
      }
      try {
        return await retry(_lease!);
      } finally {
        _release();
      }
    });
  }

  /// Startup never enters ordinary initialize until this returns ready.
  Future<void> restorePending() => _track(() async {
    try {
      _intent = await data.bootstrapMaintenance();
      if (_intent == null) {
        _publish(MaintenancePhase.idle);
        return;
      }
      _kind = _intent!.kind;
      _lease ??= leases.acquire();
      await _settle();
    } catch (error) {
      // Retain the same runtime/lease even when metadata cannot be interpreted.
      if (_lease == null && !leases.isBusy) {
        _lease = leases.acquire();
      }
      _publish(MaintenancePhase.recovery, failure: failureCode(error));
    }
  });

  Future<void> start(
    SettingsContext context,
    MaintenanceKind kind, {
    required bool confirmed,
  }) {
    if (!confirmed) {
      throw const SettingsFailure(SettingsFailureCode.confirmationRequired);
    }
    if (_view.blocksProduct || _work != null) {
      throw const SettingsFailure(SettingsFailureCode.busy);
    }
    return _track(() async {
      // Atomic source admission precedes any persisted deletion intent.
      try {
        _lease = leases.acquire();
      } on AppFailure catch (error) {
        throw SettingsFailure(failureCode(error));
      }
      _kind = kind;
      _receipt = null;
      _intent = null;
      _publish(MaintenancePhase.preparing);
      try {
        final request = await data.prepareMaintenance(
          context,
          kind,
          confirmed: true,
        );
        if (prepareReminders != null) {
          _remindersPrepared = true;
          await prepareReminders!();
        }
        _intent = await data.beginMaintenance(request);
        await _settle();
      } catch (error) {
        if (_intent != null || _receipt != null) {
          _publish(MaintenancePhase.recovery, failure: failureCode(error));
          return;
        }
        // A post-commit delivery error can still have a durable intent.
        try {
          _intent = await data.bootstrapMaintenance();
        } catch (_) {
          _publish(MaintenancePhase.recovery, failure: failureCode(error));
          return;
        }
        if (_intent != null) {
          _kind = _intent!.kind;
          _publish(MaintenancePhase.recovery, failure: failureCode(error));
          return;
        }
        try {
          await _resumeAfterAbort();
        } catch (restoreError) {
          _publish(
            MaintenancePhase.recovery,
            failure: failureCode(restoreError),
          );
          return;
        }
        _release();
        _publish(MaintenancePhase.idle);
        throw SettingsFailure(failureCode(error));
      }
    });
  }

  Future<void> retry() {
    if (_view.phase != MaintenancePhase.recovery) {
      throw const SettingsFailure(SettingsFailureCode.busy);
    }
    return _track(() async {
      try {
        _lease ??= leases.acquire();
        if (_receipt == null && _intent == null) {
          _intent = await data.bootstrapMaintenance();
          if (_intent == null) {
            await _resumeAfterAbort();
            _release();
            _publish(MaintenancePhase.idle);
            return;
          }
          _kind = _intent!.kind;
        }
        await _settle();
      } catch (error) {
        _publish(MaintenancePhase.recovery, failure: failureCode(error));
      }
    });
  }

  Future<void> _settle() async {
    if (_receipt == null) {
      final intent = _intent;
      if (intent == null || _lease?.isHeld != true) {
        throw const SettingsFailure(SettingsFailureCode.invalidIntent);
      }
      // C3 has already invalidated Agent tickets in the durable intent. Its
      // separate model channel must be drained before any deletion begins.
      await drainAgent?.call();
      await drainReminders?.call();
      if (intent.kind == MaintenanceKind.reset) {
        _publish(MaintenancePhase.cleaning);
        await cleanProfiles(_lease!);
      }
      _publish(MaintenancePhase.committing);
      _receipt = await data.completeMaintenance(intent);
      _intent = null;
    }
    _publish(MaintenancePhase.refreshing);
    await onRefresh?.call(_kind!);
    _remindersPrepared = false;
    _release();
    _publish(MaintenancePhase.idle);
  }

  Future<void> _resumeAfterAbort() async {
    if (_remindersPrepared) {
      await resumeRemindersAfterAbort?.call();
      _remindersPrepared = false;
    }
  }

  void _release() {
    _lease?.release();
    _lease = null;
  }

  Future<void> close() => _closing ??= () async {
    try {
      await _work;
      // A disk deletion failure is not a native drain failure. Pending intent
      // and ledgers survive exit; ownership is released only after native drain.
      await drainForExit();
      _closed = true;
      _release();
      await _changes.close();
    } catch (_) {
      _closing = null;
      rethrow;
    }
  }();
}
