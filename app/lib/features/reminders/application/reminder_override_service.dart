import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../tasks/application/undo_recorder.dart';

class ReminderOverrideService {
  ReminderOverrideService({
    required this.database,
    required this.accountId,
    required this.undoRecorder,
    int Function()? now,
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final AppDatabase database;
  final String accountId;
  final UndoRecorder undoRecorder;
  final int Function() now;

  Future<void> setEventOffsets(String eventId, List<int> offsets) async {
    if (offsets.any((value) => value < 0) ||
        offsets.toSet().length != offsets.length) {
      throw ArgumentError.value(offsets, 'offsets');
    }
    await database.transaction(() async {
      final event =
          await (database.select(database.calendarEvents)..where(
                (row) =>
                    row.id.equals(eventId) & row.accountId.equals(accountId),
              ))
              .getSingle();
      if (event.allDay || event.startAt == null) {
        throw StateError('timed event required');
      }
      final before = await (database.select(
        database.reminders,
      )..where((row) => row.eventId.equals(eventId))).get();
      await (database.delete(
        database.reminders,
      )..where((row) => row.eventId.equals(eventId))).go();
      final timestamp = now();
      if (offsets.isEmpty) {
        await database
            .into(database.reminders)
            .insert(
              RemindersCompanion.insert(
                id: 'reminder:event:$eventId:disabled',
                accountId: accountId,
                targetType: 'event',
                targetId: eventId,
                eventId: Value(eventId),
                triggerAt: event.startAt!,
                state: 'cancelled',
                createdAt: timestamp,
                updatedAt: timestamp,
              ),
            );
      } else {
        for (final offset in offsets) {
          final trigger =
              event.startAt! - Duration(minutes: offset).inMilliseconds;
          await database
              .into(database.reminders)
              .insert(
                RemindersCompanion.insert(
                  id: 'reminder:event:$eventId:$trigger',
                  accountId: accountId,
                  targetType: 'event',
                  targetId: eventId,
                  eventId: Value(eventId),
                  offsetMinutes: Value(offset),
                  triggerAt: trigger,
                  state: trigger <= timestamp ? 'missed' : 'desired',
                  createdAt: timestamp,
                  updatedAt: timestamp,
                ),
              );
        }
      }
      await undoRecorder.record(
        UndoCommand(
          kind: 'reminder_override',
          accountId: accountId,
          payload: {
            'entity': 'reminder_override',
            'targetType': 'event',
            'targetId': eventId,
            'before': before.map(_snapshot).toList(),
          },
        ),
      );
    });
  }

  Map<String, Object?> _snapshot(Reminder row) => {
    'id': row.id,
    'targetType': row.targetType,
    'targetId': row.targetId,
    'eventId': row.eventId,
    'taskId': row.taskId,
    'planBlockId': row.planBlockId,
    'offsetMinutes': row.offsetMinutes,
    'triggerAt': row.triggerAt,
    'state': row.state,
    'failureCode': row.failureCode,
    'deliveredAt': row.deliveredAt,
    'createdAt': row.createdAt,
    'updatedAt': row.updatedAt,
  };
}
