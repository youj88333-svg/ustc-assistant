import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/knowledge_contract.dart';
import '../core/work_lease.dart';
import '../data/knowledge_service.dart';
import '../jobs/application_maintenance_coordinator.dart';
import '../jobs/public_query_coordinator.dart';
import 'app_shell_contract.dart';
import 'settings_contract.dart';

/// Owns presentation generations, never deletion rules or credential values.
final class ApplicationSettingsController extends ChangeNotifier
    implements ApplicationSettingsPort {
  ApplicationSettingsController({
    required this.data,
    required this.maintenance,
    required this.knowledge,
    required this.queries,
    required this.leases,
    required this.applyPreferences,
  }) {
    _subscribe();
  }
  final ApplicationSettingsDataPort data;
  final ApplicationMaintenanceCoordinator maintenance;
  final KnowledgeService knowledge;
  final PublicQueryCoordinator queries;
  final WorkLeasePool leases;
  final Future<void> Function(DisplayPreferences) applyPreferences;
  Future<void> Function()? onRecovered;
  late StreamSubscription<int> _dataSubscription;
  late StreamSubscription<MaintenanceProgress> _maintenanceSubscription;
  bool _subscriptionsActive = false;
  AppShellPort? _shell;
  Object? _lastJw, _lastYoung;
  SettingsSnapshot? _snapshot;
  SettingsFailureCode? _failure;
  bool _loading = false,
      _pending = false,
      _disposed = false,
      _closing = false,
      _refreshQueued = false;
  bool _progressUnavailable = false;
  int _readGeneration = 0;
  Future<void>? _action;
  KnowledgeLoadOutcome? _loadOutcome;
  MaintenanceProgress? _readiness;
  int? _browserCleanupPendingCount;

  void _subscribe() {
    if (_subscriptionsActive) {
      return;
    }
    _dataSubscription = data.changes.listen(
      (_) => _scheduleRefresh(),
      onError: _progressFailed,
    );
    _maintenanceSubscription = maintenance.changes.listen(
      (_) => _notify(),
      onError: _progressFailed,
    );
    _subscriptionsActive = true;
  }

  /// Cancelling an OS exit after undrained maintenance leaves the same runtime
  /// alive. Its progress subscriptions must also stay usable for recovery.
  void resumeAfterFailedExit({AppShellPort? shell}) {
    if (_disposed || maintenance.isClosed) {
      return;
    }
    _closing = false;
    _loading = false;
    _subscribe();
    if (shell != null) {
      attachShell(shell);
    }
    _notify();
  }

  void setReadiness({bool busy = false, SettingsFailureCode? failure}) {
    _readiness = busy || failure != null
        ? MaintenanceProgress(
            phase: busy
                ? MaintenancePhase.refreshing
                : MaintenancePhase.recovery,
            failure: failure,
            activating: true,
          )
        : null;
    _notify();
  }

  @override
  ApplicationSettingsView get settingsView => ApplicationSettingsView(
    snapshot: _snapshot,
    loading: _loading,
    actionPending: _pending,
    knowledgeLoading: knowledge.isLoading,
    maintenance: _readiness ?? maintenance.view,
    browserCleanupPendingCount: _browserCleanupPendingCount,
    failure: _failure,
    loadOutcome: _loadOutcome,
    progressUnavailable: _progressUnavailable || _closing,
  );

  void attachShell(AppShellPort shell) {
    _shell?.removeListener(_sourceChanged);
    _shell = shell;
    _lastJw = shell.view.jw.data;
    _lastYoung = shell.view.young.data;
    shell.addListener(_sourceChanged);
  }

  void _sourceChanged() {
    final shell = _shell;
    if (shell == null) {
      return;
    }
    final changed =
        !identical(_lastJw, shell.view.jw.data) ||
        !identical(_lastYoung, shell.view.young.data);
    _lastJw = shell.view.jw.data;
    _lastYoung = shell.view.young.data;
    if (changed) {
      _scheduleRefresh();
    }
  }

  void _progressFailed(Object error) {
    if (!_closing) {
      _progressUnavailable = true;
      _failure = SettingsFailureCode.storageFailed;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _scheduleRefresh() {
    if (_closing || _pending || _refreshQueued) {
      return;
    }
    _refreshQueued = true;
    scheduleMicrotask(() {
      _refreshQueued = false;
      if (!_closing && !_pending) {
        unawaited(refreshSettings().catchError((Object _) {}));
      }
    });
  }

  @override
  Future<void> refreshSettings() async {
    if (_closing) {
      throw const SettingsFailure(SettingsFailureCode.closed);
    }
    final generation = ++_readGeneration;
    _loading = true;
    _notify();
    final cleanupCountRead = _readBrowserCleanupPendingCount();
    unawaited(
      cleanupCountRead.then((count) {
        if (!_closing && generation == _readGeneration) {
          _browserCleanupPendingCount = count;
          _notify();
        }
      }),
    );
    try {
      final snapshot = await data.inspectSettings();
      if (_closing || generation != _readGeneration) {
        return;
      }
      final cleanupPendingCount = await cleanupCountRead;
      if (_closing || generation != _readGeneration) {
        return;
      }
      if (_snapshot?.context.resetEpoch != snapshot.context.resetEpoch) {
        _loadOutcome = null;
      }
      _snapshot = snapshot;
      _browserCleanupPendingCount = cleanupPendingCount;
    } catch (error) {
      if (!_closing && generation == _readGeneration) {
        _failure = ApplicationMaintenanceCoordinator.failureCode(error);
      }
      rethrow;
    } finally {
      if (!_closing && generation == _readGeneration) {
        _loading = false;
        _notify();
      }
    }
  }

  Future<int?> _readBrowserCleanupPendingCount() async {
    try {
      return await maintenance.browserCleanupPendingCount();
    } catch (_) {
      // Keep the last known count; a status-read failure does not clear it.
      return _browserCleanupPendingCount;
    }
  }

  void _ready() {
    if (_closing) {
      throw const SettingsFailure(SettingsFailureCode.closed);
    }
    if (_pending || settingsView.maintenance.blocksProduct) {
      throw const SettingsFailure(SettingsFailureCode.busy);
    }
    if (_progressUnavailable || _shell?.view.progressUnavailable == true) {
      throw const SettingsFailure(SettingsFailureCode.storageFailed);
    }
  }

  Future<void> _localAction(Future<void> Function() body) {
    _ready();
    late final WorkLease lease;
    try {
      lease = leases.acquire();
    } catch (error) {
      throw SettingsFailure(
        ApplicationMaintenanceCoordinator.failureCode(error),
      );
    }
    _pending = true;
    _failure = null;
    _notify();
    final done = Completer<void>();
    _action = done.future;
    return () async {
      try {
        await body();
        await refreshSettings();
      } catch (error) {
        _failure = ApplicationMaintenanceCoordinator.failureCode(error);
        throw SettingsFailure(_failure!);
      } finally {
        lease.release();
        _pending = false;
        _action = null;
        done.complete();
        _notify();
      }
    }();
  }

  String _id() {
    final random = Random.secure();
    return 'preferences-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  }

  @override
  Future<void> saveDisplayPreferences(
    SettingsContext context,
    DisplayPreferences preferences,
  ) => _localAction(() async {
    await data.savePreferences(
      PreferencesWrite(
        operationId: _id(),
        context: context,
        preferences: preferences,
      ),
    );
    await applyPreferences(preferences);
  });

  @override
  Future<void> runMaintenance(
    SettingsContext context,
    MaintenanceKind kind, {
    required bool confirmed,
  }) {
    _ready();
    return _maintenanceAction(
      () => maintenance.start(context, kind, confirmed: confirmed),
    );
  }

  @override
  Future<void> retryMaintenance() {
    if (_pending || _closing) {
      throw const SettingsFailure(SettingsFailureCode.busy);
    }
    return _maintenanceAction(() async {
      if (maintenance.view.phase == MaintenancePhase.recovery) {
        await maintenance.retry();
      }
      if (!maintenance.view.blocksProduct) {
        await onRecovered?.call();
      }
    });
  }

  @override
  Future<void> retryBrowserCleanup() {
    _ready();
    return _maintenanceAction(() async {
      _browserCleanupPendingCount = await maintenance
          .retryRetiredBrowserCleanup();
    });
  }

  Future<void> _maintenanceAction(Future<void> Function() body) {
    _pending = true;
    _failure = null;
    _notify();
    final done = Completer<void>();
    _action = done.future;
    return () async {
      try {
        await body();
        _failure = settingsView.maintenance.failure;
        await refreshSettings();
      } catch (error) {
        _failure = ApplicationMaintenanceCoordinator.failureCode(error);
        throw SettingsFailure(_failure!);
      } finally {
        _pending = false;
        _action = null;
        done.complete();
        _notify();
      }
    }();
  }

  @override
  Future<void> loadKnowledge() => _localAction(() async {
    _loadOutcome = await knowledge.loadBundledEdition();
  });
  @override
  Future<void> cancelKnowledgeLoad() async {
    if (!knowledge.isLoading || _closing) {
      throw const SettingsFailure(SettingsFailureCode.busy);
    }
    await knowledge.cancelKnowledgeLoad();
    await _action;
  }

  @override
  Future<void> clearKnowledge(
    SettingsContext context, {
    required bool confirmed,
  }) => _localAction(() async {
    await knowledge.clearKnowledge(
      confirmed: confirmed,
      expectedSettingsContext: context,
    );
    _loadOutcome = null;
  });
  @override
  Future<void> setIcourseConsent(
    SettingsContext context, {
    required bool allowed,
    required bool confirmed,
  }) => _localAction(() async {
    if (!confirmed) {
      throw const SettingsFailure(SettingsFailureCode.confirmationRequired);
    }
    await queries.setIcourseConsent(allowed, expectedSettingsContext: context);
  });

  Future<void> shutdown() async {
    _closing = true;
    ++_readGeneration;
    _loading = false;
    await _action;
    _shell?.removeListener(_sourceChanged);
    _shell = null;
    if (_subscriptionsActive) {
      _subscriptionsActive = false;
      await _dataSubscription.cancel();
      await _maintenanceSubscription.cancel();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
