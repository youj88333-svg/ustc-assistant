import 'dart:async';

import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../import/application/reminder_reconciler.dart';
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

class WindowsReminderReconciler implements ReminderReconciler {
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

  Future<void> start(String accountId) async {
    await _cancelSubscriptions();
    await reconcileAll(accountId);
    _subscriptions.addAll([
      (database.select(database.calendarEvents)
            ..where((row) => row.accountId.equals(accountId)))
          .watch()
          .listen((_) => unawaited(_domainChanged(accountId))),
      // Recurring-series reminder defaults and their occurrence-exception
      // anchors also drive reminder reconciliation; watch both so a recurring
      // create / anchor write re-reconciles series reminders.
      (database.select(database.calendarEventSeries)
            ..where((row) => row.accountId.equals(accountId)))
          .watch()
          .listen((_) => unawaited(_domainChanged(accountId))),
      (database.select(database.calendarEventOccurrenceExceptions)
            ..where((row) => row.accountId.equals(accountId)))
          .watch()
          .listen((_) => unawaited(_domainChanged(accountId))),
      (database.select(database.tasks)
            ..where((row) => row.accountId.equals(accountId)))
          .watch()
          .listen((_) => unawaited(_domainChanged(accountId))),
      (database.select(database.planBlocks)
            ..where((row) => row.accountId.equals(accountId)))
          .watch()
          .listen((_) => unawaited(_domainChanged(accountId))),
      (database.select(database.reminders)
            ..where((row) => row.accountId.equals(accountId)))
          .watch()
          .listen((_) => unawaited(rebuild(accountId))),
    ]);
  }

  Future<void> dispose() async {
    await _cancelSubscriptions();
    timers.cancelAll();
  }

  Future<void> _cancelSubscriptions() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
  }

  Future<void> _domainChanged(String accountId) async {
    if (_refreshingDomain) {
      _refreshAgain = true;
      return;
    }
    _refreshingDomain = true;
    try {
      do {
        _refreshAgain = false;
        await reconcileAll(accountId);
      } while (_refreshAgain);
    } finally {
      _refreshingDomain = false;
    }
  }

  @override
  Future<void> reconcile({
    required String accountId,
    required String source,
  }) async {
    await reminderService.reconcileSource(accountId, source);
    await rebuild(accountId);
  }

  Future<void> reconcileAll(String accountId) async {
    await reminderService.reconcileAll(accountId);
    await rebuild(accountId);
  }

  Future<void> rebuild(String accountId) async {
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
        () => _deliver(reminder.id),
      );
    }
  }

  Future<void> _deliver(String id) async {
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
}
