import 'dart:async';

import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../import/application/reminder_reconciler.dart';
import '../../settings/application/minimal_reset_coordinator.dart';
import '../data/foreground_notification_adapter.dart';
import 'reminder_service.dart';

abstract interface class ReminderTimerScheduler {
  void cancelAll();

  void schedule(String id, Duration delay, Future<void> Function() callback);
}

class ProcessTimerScheduler implements ReminderTimerScheduler {
  final Map<String, Timer> _timers = {};

  @override
  void cancelAll() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }

  @override
  void schedule(String id, Duration delay, Future<void> Function() callback) {
    _timers[id]?.cancel();
    _timers[id] = Timer(delay, () => unawaited(callback()));
  }
}

class WindowsReminderReconciler implements ReminderReconciler, ResetWriterPort {
  WindowsReminderReconciler({
    required this.database,
    required this.reminderService,
    required this.notifications,
    ReminderTimerScheduler? timers,
    int Function()? now,
  }) : timers = timers ?? ProcessTimerScheduler(),
       now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final AppDatabase database;
  final ReminderService reminderService;
  final ForegroundNotificationPort notifications;
  final ReminderTimerScheduler timers;
  final int Function() now;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _refreshingDomain = false;
  bool _refreshAgain = false;
  final Set<Future<void>> _operations = <Future<void>>{};
  bool _quiescing = false;
  bool _disposed = false;
  int _generation = 0;
  Future<void>? _quiesceFuture;

  @override
  Future<void> quiesce() {
    final existing = _quiesceFuture;
    if (existing != null) return existing;
    // This synchronous assignment is the admission barrier for timer
    // callbacks, watcher callbacks, direct reconcile calls and late starts.
    _quiescing = true;
    _generation++;
    timers.cancelAll();
    final operation = _quiesceImpl();
    _quiesceFuture = operation;
    unawaited(
      operation.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          // Retain maintenance admission, but make failed cleanup retryable.
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
      await _cancelSubscriptions();
    } on Object catch (error, stack) {
      firstError ??= error;
      firstStack ??= stack;
    }
    final operations = _operations.toList(growable: false);
    for (final operation in operations) {
      try {
        await operation;
      } on Object catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(
        StateError('reminder_quiesce_failed'),
        firstStack ?? StackTrace.current,
      );
    }
  }

  @override
  Future<void> resume() async {
    if (_disposed) return;
    _quiescing = false;
    _generation++;
    _quiesceFuture = null;
    // A reset must never resurrect old-account timers. A later account-aware
    // start() creates a new generation and schedules only fresh rows.
    timers.cancelAll();
  }

  Future<void> start(String accountId) {
    if (_quiescing || _disposed) {
      return Future<void>.error(StateError('maintenance_in_progress'));
    }
    final generation = ++_generation;
    timers.cancelAll();
    final priorOperations = _operations.toList(growable: false);
    return _track(() async {
      await _cancelSubscriptions();
      await _settleOperations(priorOperations);
      if (!_isCurrent(generation)) return;
      await _reconcileAllInternal(accountId, generation);
      if (!_isCurrent(generation)) return;
      _subscriptions.addAll([
        (database.select(database.calendarEvents)
              ..where((row) => row.accountId.equals(accountId)))
            .watch()
            .listen((_) => _observe(_domainChanged(accountId, generation))),
        // Recurring-series reminder defaults and their occurrence-exception
        // anchors also drive reminder reconciliation; watch both so a recurring
        // create / anchor write re-reconciles series reminders.
        (database.select(database.calendarEventSeries)
              ..where((row) => row.accountId.equals(accountId)))
            .watch()
            .listen((_) => _observe(_domainChanged(accountId, generation))),
        (database.select(database.calendarEventOccurrenceExceptions)
              ..where((row) => row.accountId.equals(accountId)))
            .watch()
            .listen((_) => _observe(_domainChanged(accountId, generation))),
        (database.select(database.tasks)
              ..where((row) => row.accountId.equals(accountId)))
            .watch()
            .listen((_) => _observe(_domainChanged(accountId, generation))),
        (database.select(database.planBlocks)
              ..where((row) => row.accountId.equals(accountId)))
            .watch()
            .listen((_) => _observe(_domainChanged(accountId, generation))),
        (database.select(database.reminders)
              ..where((row) => row.accountId.equals(accountId)))
            .watch()
            .listen((_) => _observe(rebuild(accountId))),
      ]);
    });
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _quiescing = true;
    _generation++;
    timers.cancelAll();
    await _cancelSubscriptions();
    await _settleOperations(_operations.toList(growable: false));
  }

  Future<void> _cancelSubscriptions() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
  }

  Future<void> _domainChanged(String accountId, int generation) {
    if (!_isCurrent(generation)) return Future<void>.value();
    if (_refreshingDomain) {
      _refreshAgain = true;
      return Future<void>.value();
    }
    return _track(() async {
      _refreshingDomain = true;
      try {
        do {
          _refreshAgain = false;
          await _reconcileAllInternal(accountId, generation);
        } while (_refreshAgain && _isCurrent(generation));
      } finally {
        _refreshingDomain = false;
      }
    });
  }

  @override
  Future<void> reconcile({required String accountId, required String source}) {
    final generation = _generation;
    return _track(() async {
      await reminderService.reconcileSource(accountId, source);
      await _rebuildInternal(accountId, generation);
    });
  }

  Future<void> reconcileAll(String accountId) {
    final generation = _generation;
    return _track(() => _reconcileAllInternal(accountId, generation));
  }

  Future<void> rebuild(String accountId) {
    final generation = _generation;
    return _track(() => _rebuildInternal(accountId, generation));
  }

  Future<void> _reconcileAllInternal(String accountId, int generation) async {
    await reminderService.reconcileAll(accountId);
    await _rebuildInternal(accountId, generation);
  }

  Future<void> _rebuildInternal(String accountId, int generation) async {
    timers.cancelAll();
    final timestamp = now();
    await (database.update(database.reminders)..where(
          (row) =>
              row.accountId.equals(accountId) &
              row.state.equals('desired') &
              row.triggerAt.isSmallerOrEqualValue(timestamp),
        ))
        .write(
          RemindersCompanion(
            state: const Value('missed'),
            updatedAt: Value(timestamp),
          ),
        );
    final pending =
        await (database.select(database.reminders)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.state.equals('desired') &
                  row.triggerAt.isBiggerThanValue(timestamp),
            ))
            .get();
    for (final reminder in pending) {
      timers.schedule(
        reminder.id,
        Duration(milliseconds: reminder.triggerAt - timestamp),
        () => _deliver(reminder.id, generation).catchError((_) {}),
      );
    }
  }

  Future<void> _deliver(String id, int generation) {
    if (!_isCurrent(generation)) return Future<void>.value();
    return _track(() => _deliverInternal(id, generation));
  }

  Future<void> _deliverInternal(String id, int generation) async {
    final reminder = await (database.select(
      database.reminders,
    )..where((row) => row.id.equals(id))).getSingleOrNull();
    if (reminder == null || reminder.state != 'desired') return;
    final timestamp = now();
    try {
      await notifications.deliver(
        ReminderNotification(
          reminderId: reminder.id,
          title: '日程提醒',
          body: '一个事项即将开始或截止。',
        ),
      );
      await (database.update(
        database.reminders,
      )..where((row) => row.id.equals(id))).write(
        RemindersCompanion(
          state: const Value('delivered'),
          deliveredAt: Value(timestamp),
          failureCode: const Value(null),
          updatedAt: Value(timestamp),
        ),
      );
    } on Object {
      await (database.update(
        database.reminders,
      )..where((row) => row.id.equals(id))).write(
        RemindersCompanion(
          state: const Value('failed'),
          failureCode: const Value('notification_unavailable'),
          updatedAt: Value(timestamp),
        ),
      );
    }
  }

  bool _isCurrent(int generation) =>
      !_disposed && !_quiescing && generation == _generation;

  Future<void> _track(Future<void> Function() action) {
    if (_quiescing || _disposed) {
      return Future<void>.error(StateError('maintenance_in_progress'));
    }
    final operation = Future<void>.sync(action);
    _operations.add(operation);
    unawaited(
      operation.then<void>(
        (_) => _completeOperation(operation),
        onError: (Object _, StackTrace _) => _completeOperation(operation),
      ),
    );
    return operation;
  }

  void _completeOperation(Future<void> operation) {
    _operations.remove(operation);
  }

  Future<void> _settleOperations(Iterable<Future<void>> operations) async {
    Object? firstError;
    StackTrace? firstStack;
    for (final operation in operations) {
      try {
        await operation;
      } on Object catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack ?? StackTrace.current);
    }
  }

  void _observe(Future<void> operation) {
    unawaited(operation.catchError((_) {}));
  }
}
