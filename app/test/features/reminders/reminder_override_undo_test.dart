import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
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
}
