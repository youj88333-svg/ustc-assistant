import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/calendar/application/recurrence_service.dart';
import 'package:ustc_assistant_app/features/calendar/domain/calendar_event_locator.dart';
import 'package:ustc_assistant_app/features/calendar/domain/personal_event.dart';
import 'package:ustc_assistant_app/features/calendar/domain/recurrence_rule.dart';
import 'package:ustc_assistant_app/features/reminders/application/reminder_override_service.dart';
import 'package:ustc_assistant_app/features/tasks/application/undo_recorder.dart';
import 'package:ustc_assistant_app/features/tasks/application/undo_service.dart';

class ThrowingUndoRecorder implements UndoRecorder {
  @override
  Future<void> record(UndoCommand command) => throw StateError('undo failed');
}

void main() {
  late AppDatabase database;
  const accountId = 'account';
  final start = DateTime.utc(2026, 8, 1, 2).millisecondsSinceEpoch;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    await database
        .into(database.localAccounts)
        .insert(
          LocalAccountsCompanion.insert(
            id: accountId,
            maskedHint: 'PB****0000',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
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
            createdAt: 1,
            updatedAt: 1,
          ),
        );
  });
  tearDown(() => database.close());

  test(
    'override replaces global one-step undo slot and can be undone',
    () async {
      final undo = UndoService(database: database, accountId: accountId);
      await database.replaceUndoSlot(commandId: 'old', payload: '{}');
      final service = ReminderOverrideService(
        database: database,
        accountId: accountId,
        undoRecorder: undo,
        now: () => 10,
      );

      await service.setEventOffsets('event', [30, 5]);
      expect(await database.select(database.reminders).get(), hasLength(2));
      expect(
        (await database.select(database.undoSlot).getSingle()).payload,
        contains('reminder_override'),
      );

      await undo.undo();
      expect(await database.select(database.reminders).get(), isEmpty);
    },
  );

  test(
    'undo recording failure rolls back override and reconciliation',
    () async {
      final service = ReminderOverrideService(
        database: database,
        accountId: accountId,
        undoRecorder: ThrowingUndoRecorder(),
        now: () => 10,
      );

      expect(service.setEventOffsets('event', [30]), throwsStateError);
      expect(await database.select(database.reminders).get(), isEmpty);
    },
  );

  group('recurring occurrence reminder override', () {
    test('setting offsets on an occurrence creates/reuses one anchor and '
        'schedules triggers from the effective start', () async {
      final service = RecurrenceService(
        database: database,
        accountId: accountId,
        now: () => 100,
      );
      final seriesId = await service.createSeries(
        anchor: PersonalEvent.timed(
          title: '每日站会',
          startAt: DateTime(2026, 8, 1, 9, 0),
          endAt: DateTime(2026, 8, 1, 9, 30),
        ),
        rule: RecurrenceRule.daily(anchor: DateTime(2026, 8, 1, 9, 0)),
      );
      final occ = (await service.occurrences(
        seriesId,
        from: DateTime(2026, 8, 1, 9),
        through: DateTime(2026, 8, 1, 9),
      )).single;
      final locator = encodeCalendarEventLocator(
        RecurringOccurrenceLocator(
          seriesId: seriesId,
          occurrenceKey: occ.occurrenceKey,
        ),
      );

      final override = ReminderOverrideService(
        database: database,
        accountId: accountId,
        undoRecorder: NullUndoRecorder(),
        now: () => 100,
      );
      await override.setEventOffsets(locator, [30, 5]);
      await override.setEventOffsets(locator, [30, 5]);

      final rows = await database.select(database.reminders).get();
      final anchors =
          await database.select(database.calendarEventOccurrenceExceptions).get();
      // A single reused no-op anchor for the occurrence.
      expect(anchors, hasLength(1));
      expect(anchors.single.kind, 'override');
      expect(anchors.single.overriddenFieldsJson, '[]');
      // Exactly two distinct triggers (offsets 30 and 5), no duplicates, all
      // occurrence-exception backed (never the stored event FK).
      expect(rows, hasLength(2));
      expect(rows.every((r) => r.occurrenceExceptionId == anchors.single.id), isTrue);
      expect(rows.every((r) => r.eventId == null), isTrue);
      expect(rows.every((r) => r.targetId == locator), isTrue);
      final start = DateTime(2026, 8, 1, 9, 0).millisecondsSinceEpoch;
      expect(
        rows.map((r) => r.triggerAt).toSet(),
        {
          start - const Duration(minutes: 30).inMilliseconds,
          start - const Duration(minutes: 5).inMilliseconds,
        },
      );
    });
  });

  group('generalized clear across target types', () {
    // Each test seeds the target + a reminder via the public service API.
    Future<ReminderOverrideService> seedService({UndoRecorder? undo}) async {
      final service = ReminderOverrideService(
        database: database,
        accountId: accountId,
        undoRecorder: undo ?? NullUndoRecorder(),
        now: () => 1,
      );
      return service;
    }

    Future<void> seedTask(String id) async {
      await database.into(database.tasks).insert(
            TasksCompanion.insert(
              id: id,
              accountId: accountId,
              title: id,
              state: 'active',
              importance: 'normal',
              deadlineAt: Value(start),
              tagsJson: '[]',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
    }

    Future<void> seedBlock(String id) async {
      await seedTask('task-$id');
      await database.into(database.planBlocks).insert(
            PlanBlocksCompanion.insert(
              id: id,
              accountId: accountId,
              taskId: 'task-$id',
              startAt: start,
              endAt: start + 3600000,
              status: 'accepted',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
    }

    test('setOffsets/clearReminders work across event/task/plan_block', () async {
      await seedTask('task');
      await seedBlock('block');
      final service = await seedService();

      await service.setOffsets(
        targetType: 'event',
        targetId: 'event',
        offsets: [30, 5],
      );
      await service.setOffsets(
        targetType: 'task',
        targetId: 'task',
        offsets: [60, 10],
      );
      await service.setOffsets(
        targetType: 'plan_block',
        targetId: 'block',
        offsets: [10],
      );

      var rows = await database.select(database.reminders).get();
      expect(rows.where((r) => r.targetType == 'event'), hasLength(2));
      expect(rows.where((r) => r.targetType == 'task'), hasLength(2));
      expect(rows.where((r) => r.targetType == 'plan_block'), hasLength(1));
      // FKs are populated per target.
      expect(
        rows.where((r) => r.targetType == 'event').every((r) => r.eventId == 'event'),
        isTrue,
      );
      expect(
        rows.where((r) => r.targetType == 'task').every((r) => r.taskId == 'task'),
        isTrue,
      );
      expect(
        rows
            .where((r) => r.targetType == 'plan_block')
            .every((r) => r.planBlockId == 'block'),
        isTrue,
      );

      // Clear one offset from the task.
      await service.clearReminders(
        targetType: 'task',
        targetId: 'task',
        scope: ReminderClearScope.selectedOffsets,
        offsets: [60],
      );
      rows = await database.select(database.reminders).get();
      expect(
        rows
            .where((r) => r.targetType == 'task' && r.state == 'desired')
            .map((r) => r.offsetMinutes),
        [10],
      );
      // The cancelled 60-min row is preserved as history (cancelled).
      expect(
        rows.where(
          (r) => r.targetType == 'task' && r.offsetMinutes == 60,
        ).single.state,
        'cancelled',
      );
    });

    test('clear all writes sentinel and preserves delivered/missed/failed',
        () async {
      await seedTask('task');
      final service = await seedService();
      await service.setOffsets(
        targetType: 'task',
        targetId: 'task',
        offsets: [30],
      );
      // Add two history rows with distinct trigger/window so they cannot collide
      // with the sole future desired row or with each other on the unique key
      // (account, targetType, targetId, triggerAt).
      await database.into(database.reminders).insert(
            RemindersCompanion.insert(
              id: 'hist-delivered',
              accountId: accountId,
              targetType: 'task',
              targetId: 'task',
              taskId: const Value('task'),
              offsetMinutes: const Value(30),
              triggerAt: start - 2000,
              state: 'delivered',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await database.into(database.reminders).insert(
            RemindersCompanion.insert(
              id: 'hist-missed',
              accountId: accountId,
              targetType: 'task',
              targetId: 'task',
              taskId: const Value('task'),
              offsetMinutes: const Value(30),
              triggerAt: start - 3000,
              state: 'missed',
              createdAt: 1,
              updatedAt: 1,
            ),
          );

      await service.clearReminders(
        targetType: 'task',
        targetId: 'task',
        scope: ReminderClearScope.all,
      );

      final rows = await database.select(database.reminders).get();
      // A sentinel (no-offset cancelled) now marks the target disabled.
      expect(
        rows.any((r) => r.state == 'cancelled' && r.offsetMinutes == null),
        isTrue,
      );
      // History preserved.
      expect(rows.singleWhere((r) => r.id == 'hist-delivered').state, 'delivered');
      expect(rows.singleWhere((r) => r.id == 'hist-missed').state, 'missed');
      // No future desired reminders remain.
      expect(rows.where((r) => r.state == 'desired'), isEmpty);
      // configurationFor reflects the sentinel + history.
      final config = await service.configurationFor(
        targetType: 'task',
        targetId: 'task',
      );
      expect(config.hasExplicitDisable, isTrue);
      expect(config.deliveredCount, 1);
      expect(config.missedCount, 1);
    });

    test('missing offset fails atomically and writes nothing', () async {
      final service = await seedService();
      await service.setOffsets(
        targetType: 'event',
        targetId: 'event',
        offsets: [30],
      );

      await expectLater(
        service.clearReminders(
          targetType: 'event',
          targetId: 'event',
          scope: ReminderClearScope.selectedOffsets,
          offsets: [60],
        ),
        throwsStateError,
      );
      // Neither the requested (absent) offset nor anything else changed.
      final rows = await database.select(database.reminders).get();
      expect(rows.single.state, 'desired');
      expect(rows.single.offsetMinutes, 30);
    });

    test('selected clear that empties the target writes a sentinel', () async {
      final service = await seedService();
      await service.setOffsets(
        targetType: 'event',
        targetId: 'event',
        offsets: [30],
      );

      await service.clearReminders(
        targetType: 'event',
        targetId: 'event',
        scope: ReminderClearScope.selectedOffsets,
        offsets: [30],
      );

      final rows = await database.select(database.reminders).get();
      expect(
        rows.any((r) => r.state == 'cancelled' && r.offsetMinutes == null),
        isTrue,
      );
      expect(rows.where((r) => r.state == 'desired'), isEmpty);
    });

    test('clearReminders undo restores complete before rows', () async {
      await seedTask('task');
      final undo = UndoService(database: database, accountId: accountId);
      final service = ReminderOverrideService(
        database: database,
        accountId: accountId,
        undoRecorder: undo,
        now: () => 1,
      );
      await service.setOffsets(
        targetType: 'task',
        targetId: 'task',
        offsets: [30, 10],
      );

      await service.clearReminders(
        targetType: 'task',
        targetId: 'task',
        scope: ReminderClearScope.all,
      );
      // After clear: sentinel only.
      expect(
        (await database.select(database.reminders).get())
            .where((r) => r.state == 'desired'),
        isEmpty,
      );

      await undo.undo();

      // The full before-rows (including the cancelled state of the to-be-cleared
      // rows) are restored via the reminder_override snapshot.
      final rows = await database.select(database.reminders).get();
      expect(
        rows.where((r) => r.state == 'desired').map((r) => r.offsetMinutes).toSet(),
        {30, 10},
      );
    });
  });
}

/// A no-op UndoRecorder for tests that exercise persistence without undo.
class NullUndoRecorder implements UndoRecorder {
  @override
  Future<void> record(UndoCommand command) async {}
}
