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
}

/// A no-op UndoRecorder for tests that exercise persistence without undo.
class NullUndoRecorder implements UndoRecorder {
  @override
  Future<void> record(UndoCommand command) async {}
}
