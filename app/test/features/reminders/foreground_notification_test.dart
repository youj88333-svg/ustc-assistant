import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/reminders/application/reminder_service.dart';
import 'package:ustc_assistant_app/features/reminders/application/windows_reminder_reconciler.dart';
import 'package:ustc_assistant_app/features/reminders/data/foreground_notification_adapter.dart';

class FakeNotifications implements ForegroundNotificationPort {
  FakeNotifications({this.fail = false});

  final bool fail;
  final delivered = <String>[];

  @override
  Future<void> deliver(ReminderNotification notification) async {
    if (fail) throw const NotificationDeliveryError('unavailable');
    delivered.add(notification.reminderId);
  }
}

class FakeTimerScheduler implements ReminderTimerScheduler {
  final callbacks = <String, Future<void> Function()>{};

  @override
  void cancelAll() => callbacks.clear();

  @override
  void schedule(String id, Duration delay, Future<void> Function() callback) {
    callbacks[id] = callback;
  }
}

void main() {
  late AppDatabase database;
  const accountId = 'account';
  final now = DateTime.utc(2026, 7, 27).millisecondsSinceEpoch;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    await database
        .into(database.localAccounts)
        .insert(
          LocalAccountsCompanion.insert(
            id: accountId,
            maskedHint: 'PB****0000',
            createdAt: now,
            updatedAt: now,
          ),
        );
    final start = now + const Duration(hours: 3).inMilliseconds;
    await database
        .into(database.calendarEvents)
        .insert(
          CalendarEventsCompanion.insert(
            id: 'event',
            accountId: accountId,
            source: 'user',
            title: 'event',
            type: 'personal',
            startAt: Value(start),
            endAt: Value(start + 3600000),
            allDay: false,
            timezone: 'Asia/Shanghai',
            createdAt: now,
            updatedAt: now,
          ),
        );
  });
  tearDown(() => database.close());

  test(
    'future reminder is delivered and persisted while process runs',
    () async {
      final notifications = FakeNotifications();
      final timers = FakeTimerScheduler();
      final reconciler = WindowsReminderReconciler(
        database: database,
        reminderService: ReminderService(database: database, now: () => now),
        notifications: notifications,
        timers: timers,
        now: () => now,
      );
      await reconciler.reconcile(accountId: accountId, source: 'user');
      final reminder = await database.select(database.reminders).getSingle();

      await timers.callbacks[reminder.id]!();

      expect(notifications.delivered, [reminder.id]);
      expect(
        (await database.select(database.reminders).getSingle()).state,
        'delivered',
      );
    },
  );

  test('adapter failure leaves in-app row failed with a safe code', () async {
    final timers = FakeTimerScheduler();
    final reconciler = WindowsReminderReconciler(
      database: database,
      reminderService: ReminderService(database: database, now: () => now),
      notifications: FakeNotifications(fail: true),
      timers: timers,
      now: () => now,
    );
    await reconciler.reconcile(accountId: accountId, source: 'user');
    final reminder = await database.select(database.reminders).getSingle();

    await timers.callbacks[reminder.id]!();

    final failed = await database.select(database.reminders).getSingle();
    expect(failed.state, 'failed');
    expect(failed.failureCode, 'notification_unavailable');
  });

  test('running reconciler observes newly created task targets', () async {
    final reconciler = WindowsReminderReconciler(
      database: database,
      reminderService: ReminderService(database: database, now: () => now),
      notifications: FakeNotifications(),
      timers: FakeTimerScheduler(),
      now: () => now,
    );
    addTearDown(reconciler.dispose);
    await reconciler.start(accountId);
    await database
        .into(database.tasks)
        .insert(
          TasksCompanion.insert(
            id: 'new-task',
            accountId: accountId,
            title: 'new-task',
            state: 'active',
            importance: 'normal',
            deadlineAt: Value(now + const Duration(days: 3).inMilliseconds),
            tagsJson: '[]',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      (await database.select(database.reminders).get()).where(
        (row) => row.taskId == 'new-task',
      ),
      hasLength(2),
    );
  });
}
