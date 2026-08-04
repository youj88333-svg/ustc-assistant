import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../calendar/application/recurrence_service.dart';
import '../../calendar/domain/calendar_event_locator.dart';
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

  /// Sets the reminder offsets for an event target. [eventId] is either a plain
  /// stored event id (an event-backed reminder) or an encoded recurring
  /// occurrence locator. For a recurring occurrence the service resolves the
  /// backing no-op exception anchor via [RecurrenceService.ensureOccurrenceAnchor]
  /// and computes triggers from the occurrence's effective (override-aware)
  /// start time.
  Future<void> setEventOffsets(String eventId, List<int> offsets) async {
    if (offsets.any((value) => value < 0) ||
        offsets.toSet().length != offsets.length) {
      throw ArgumentError.value(offsets, 'offsets');
    }
    await database.transaction(() async {
      final resolved = await _resolveEventTarget(eventId);
      final startAt = resolved.startAt;
      if (startAt == null) {
        throw StateError('timed event required');
      }
      final before =
          await (database.select(database.reminders)..where(
                (row) =>
                    row.accountId.equals(accountId) &
                    row.targetType.equals('event') &
                    row.targetId.equals(eventId),
              )).get();
      await (database.delete(database.reminders)..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.targetType.equals('event') &
                row.targetId.equals(eventId),
          )).go();
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
                eventId: Value(resolved.eventId),
                occurrenceExceptionId: Value(resolved.occurrenceExceptionId),
                triggerAt: startAt,
                state: 'cancelled',
                createdAt: timestamp,
                updatedAt: timestamp,
              ),
            );
      } else {
        for (final offset in offsets) {
          final trigger = startAt - Duration(minutes: offset).inMilliseconds;
          await database
              .into(database.reminders)
              .insert(
                RemindersCompanion.insert(
                  id: 'reminder:event:$eventId:$trigger',
                  accountId: accountId,
                  targetType: 'event',
                  targetId: eventId,
                  eventId: Value(resolved.eventId),
                  occurrenceExceptionId: Value(resolved.occurrenceExceptionId),
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

  /// Resolves an event target to its backing FK columns and effective start
  /// time (epoch-ms). A recurring occurrence locator maps to the occurrence
  /// exception anchor (created/reused) and uses the composed occurrence's
  /// effective start; a plain stored event id maps to the event FK and its
  /// stored startAt. Rejects non-timed (all-day / missing start) targets.
  Future<({String? eventId, String? occurrenceExceptionId, int? startAt})>
      _resolveEventTarget(String targetId) async {
    final recurrence =
        RecurrenceService(database: database, accountId: accountId, now: now);
    if (targetId.startsWith('occ_v1.')) {
      final decoded = decodeCalendarEventLocator(targetId);
      if (decoded is! RecurringOccurrenceLocator) {
        throw StateError('unsupported event locator');
      }
      if (await recurrence.seriesRowOrNull(decoded.seriesId) == null) {
        throw StateError('recurring occurrence not found');
      }
      final occurrence =
          await recurrence.occurrence(decoded.seriesId, decoded.occurrenceKey);
      if (occurrence.allDay || occurrence.startAt == null) {
        throw StateError('timed event required');
      }
      final anchor = await recurrence.ensureOccurrenceAnchor(
        decoded.seriesId,
        decoded.occurrenceKey,
      );
      return (
        eventId: null,
        occurrenceExceptionId: anchor.id,
        startAt: occurrence.startAt!.millisecondsSinceEpoch,
      );
    }
    if (targetId.startsWith('event_v1.') ||
        targetId.startsWith('series_v1.')) {
      throw StateError('unsupported event locator');
    }
    final event = await (database.select(database.calendarEvents)..where(
          (row) =>
              row.id.equals(targetId) & row.accountId.equals(accountId),
        )).getSingle();
    if (event.allDay || event.startAt == null) {
      throw StateError('timed event required');
    }
    return (
      eventId: targetId,
      occurrenceExceptionId: null,
      startAt: event.startAt,
    );
  }

  /// Loads the target's future desired offsets, whether an explicit-disable
  /// sentinel is present, and the delivered/missed/failed history counts.
  ///
  /// [targetType] is one of `event` / `task` / `plan_block`; [targetId] is the
  /// underlying local id. Account-scoped and read-only — never returns the
  /// Reminder DB id.
  Future<ReminderConfiguration> configurationFor({
    required String targetType,
    required String targetId,
  }) async {
    final rows =
        await (database.select(database.reminders)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.targetType.equals(targetType) &
                  row.targetId.equals(targetId),
            ))
            .get();
    final desiredOffsets = <int>{};
    var hasExplicitDisable = false;
    var delivered = 0;
    var missed = 0;
    var failed = 0;
    for (final row in rows) {
      final offset = row.offsetMinutes;
      if (row.state == 'desired' && offset != null) {
        desiredOffsets.add(offset);
      } else if (row.state == 'cancelled' && offset == null) {
        // The no-offset cancelled sentinel written when the target's remaining
        // offsets ran out — an explicit disable marker that suppresses default
        // rule rebuild.
        hasExplicitDisable = true;
      } else if (row.state == 'delivered') {
        delivered++;
      } else if (row.state == 'missed') {
        missed++;
      } else if (row.state == 'failed') {
        failed++;
      }
    }
    final future = <int>[
      ...desiredOffsets,
    ]..sort();
    return ReminderConfiguration(
      futureDesiredOffsets: List.unmodifiable(future),
      hasExplicitDisable: hasExplicitDisable,
      deliveredCount: delivered,
      missedCount: missed,
      failedCount: failed,
    );
  }

  Map<String, Object?> _snapshot(Reminder row) => {
    'id': row.id,
    'targetType': row.targetType,
    'targetId': row.targetId,
    'eventId': row.eventId,
    'occurrenceExceptionId': row.occurrenceExceptionId,
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

/// A read-only snapshot of a target's Reminder configuration, for the Agent
/// `get_reminders` tool. Carries no Reminder DB id.
class ReminderConfiguration {
  const ReminderConfiguration({
    required this.futureDesiredOffsets,
    required this.hasExplicitDisable,
    required this.deliveredCount,
    required this.missedCount,
    required this.failedCount,
  });

  /// Distinct, ascending future `desired` offsets (minutes before the target).
  final List<int> futureDesiredOffsets;

  /// Whether an explicit no-offset cancelled sentinel is present (i.e. the
  /// user disabled the target's reminders so reconcile must not rebuild them).
  final bool hasExplicitDisable;

  final int deliveredCount;
  final int missedCount;
  final int failedCount;
}
