import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../calendar/application/recurrence_service.dart';
import '../../calendar/domain/calendar_event_locator.dart';
import '../../tasks/application/undo_recorder.dart';

/// The scope of a Reminder clear operation.
///
/// `all` clears every future `desired` offset for the target. `selectedOffsets`
/// clears only the listed offsets (and requires every listed offset to already
/// be a future `desired` offset — otherwise the whole call fails atomically).
enum ReminderClearScope { all, selectedOffsets }

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
  ///
  /// Generalized to targetType/targetId — see [setOffsets].
  Future<void> setEventOffsets(String eventId, List<int> offsets) =>
      setOffsets(targetType: 'event', targetId: eventId, offsets: offsets);

  /// Sets the reminder offsets for a generic target (`event` / `task` /
  /// `plan_block`), replacing the target's entire reminder configuration:
  /// future `desired` triggers for the given offsets are (re)written and any
  /// prior rows are removed. An empty [offsets] list writes the no-offset
  /// cancelled sentinel that suppresses default-rule rebuild.
  ///
  /// This is the full-configuration write; for safe subset clearing use
  /// [clearReminders].
  Future<void> setOffsets({
    required String targetType,
    required String targetId,
    required List<int> offsets,
  }) async {
    if (offsets.any((value) => value < 0) ||
        offsets.toSet().length != offsets.length) {
      throw ArgumentError.value(offsets, 'offsets');
    }
    await database.transaction(() async {
      final resolved = await _resolveTarget(targetType, targetId);
      final startAt = resolved.startAt;
      if (startAt == null) {
        throw StateError('timed target required');
      }
      final token = _tokenOf(targetType, targetId, resolved);
      final before = await _loadReminders(targetType, targetId);
      await _deleteReminders(targetType, targetId);
      final timestamp = now();
      if (offsets.isEmpty) {
        await _insertSentinel(token: token, startAt: startAt, timestamp: timestamp);
      } else {
        for (final offset in offsets) {
          final trigger = startAt - Duration(minutes: offset).inMilliseconds;
          await _insert(
            token: token,
            trigger: trigger,
            offset: offset,
            state: trigger <= timestamp ? 'missed' : 'desired',
            timestamp: timestamp,
          );
        }
      }
      await undoRecorder.record(
        UndoCommand(
          kind: 'reminder_override',
          accountId: accountId,
          payload: {
            'entity': 'reminder_override',
            'targetType': targetType,
            'targetId': targetId,
            'before': before.map(_snapshot).toList(),
          },
        ),
      );
    });
  }

  /// Safely clears the target's future `desired` reminders without touching its
  /// delivered / missed / failed history.
  ///
  /// - [ReminderClearScope.all]: clears every future `desired` offset.
  /// - [ReminderClearScope.selectedOffsets]: clears only [offsets]; every listed
  ///   offset must already be a future `desired` offset, otherwise the whole
  ///   call throws atomically and nothing is written.
  ///
  /// When the target ends up with no remaining future `desired` offset, a
  /// no-offset cancelled sentinel is written so reconcile never rebuilds the
  /// default reminders. The complete before-row snapshot is recorded for Undo.
  Future<void> clearReminders({
    required String targetType,
    required String targetId,
    required ReminderClearScope scope,
    List<int>? offsets,
  }) async {
    if (scope == ReminderClearScope.all && offsets != null) {
      throw ArgumentError.value(offsets, 'offsets',
          'all scope must not specify offsets');
    }
    if (scope == ReminderClearScope.selectedOffsets) {
      if (offsets == null || offsets.isEmpty) {
        throw ArgumentError.value(offsets, 'offsets',
            'selectedOffsets scope requires non-empty offsets');
      }
      if (offsets.any((value) => value < 0) ||
          offsets.toSet().length != offsets.length) {
        throw ArgumentError.value(offsets, 'offsets');
      }
    }
    await database.transaction(() async {
      final resolved = await _resolveTarget(targetType, targetId);
      final startAt = resolved.startAt;
      if (startAt == null) {
        throw StateError('timed target required');
      }
      final token = _tokenOf(targetType, targetId, resolved);
      final before = await _loadReminders(targetType, targetId);
      final timestamp = now();

      final futureDesired = {
        for (final row in before)
          if (row.state == 'desired' && row.offsetMinutes != null)
            row.id: row.offsetMinutes!,
      };
      final existingOffsets = futureDesired.values.toSet();
      final Set<int> toClear;
      if (scope == ReminderClearScope.all) {
        toClear = existingOffsets.toSet();
      } else {
        final selected = offsets!.toSet();
        // Atomic failure: every requested offset must already be a future
        // desired offset. Nothing is written on mismatch.
        for (final offset in selected) {
          if (!existingOffsets.contains(offset)) {
            throw StateError('reminder offset not found');
          }
        }
        toClear = selected;
      }

      // Cancel only the targeted future desired rows (history is preserved).
      for (final row in before) {
        if (row.state == 'desired' &&
            row.offsetMinutes != null &&
            toClear.contains(row.offsetMinutes)) {
          await _cancelRow(row.id, timestamp);
        }
      }

      // If no future desired offsets remain, write the disable sentinel so
      // reconcile does not rebuild defaults. Skip if it already exists.
      final remaining =
          existingOffsets.difference(toClear);
      final hasSentinel = before.any(
        (row) => row.state == 'cancelled' && row.offsetMinutes == null,
      );
      if (remaining.isEmpty && !hasSentinel) {
        await _insertSentinel(token: token, startAt: startAt, timestamp: timestamp);
      }

      await undoRecorder.record(
        UndoCommand(
          kind: 'reminder_override',
          accountId: accountId,
          payload: {
            'entity': 'reminder_override',
            'targetType': targetType,
            'targetId': targetId,
            'before': before.map(_snapshot).toList(),
          },
        ),
      );
    });
  }

  /// Resolves a generic target to its backing FK columns and effective anchor
  /// time (epoch-ms). An `event` target may be a plain stored event id or an
  /// encoded recurring occurrence locator (resolved via
  /// [RecurrenceService.ensureOccurrenceAnchor]); `task` and `plan_block`
  /// targets resolve to their own FK columns. Rejects non-timed targets.
  /// [startAt] is null when the target is non-timed, which the caller rejects.
  Future<({String? eventId, String? occurrenceExceptionId, String? taskId, String? planBlockId, int? startAt})>
      _resolveTarget(String targetType, String targetId) async {
    switch (targetType) {
      case 'event':
        final resolved = await _resolveEventTarget(targetId);
        return (
          eventId: resolved.eventId,
          occurrenceExceptionId: resolved.occurrenceExceptionId,
          taskId: null,
          planBlockId: null,
          startAt: resolved.startAt,
        );
      case 'task':
        final task = await (database.select(database.tasks)
              ..where(
                (row) =>
                    row.id.equals(targetId) & row.accountId.equals(accountId),
              ))
            .getSingle();
        return (
          eventId: null,
          occurrenceExceptionId: null,
          taskId: targetId,
          planBlockId: null,
          startAt: task.deadlineAt,
        );
      case 'plan_block':
        final block = await (database.select(database.planBlocks)
              ..where(
                (row) =>
                    row.id.equals(targetId) & row.accountId.equals(accountId),
              ))
            .getSingle();
        return (
          eventId: null,
          occurrenceExceptionId: null,
          taskId: null,
          planBlockId: targetId,
          startAt: block.startAt,
        );
      default:
        throw StateError('unsupported target type');
    }
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
        throw StateError('timed target required');
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
      throw StateError('timed target required');
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
    final rows = await _loadReminders(targetType, targetId);
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

  Future<List<Reminder>> _loadReminders(String targetType, String targetId) =>
      (database.select(database.reminders)..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.targetType.equals(targetType) &
                row.targetId.equals(targetId),
          ))
          .get();

  Future<void> _deleteReminders(String targetType, String targetId) async {
    await (database.delete(database.reminders)..where(
          (row) =>
              row.accountId.equals(accountId) &
              row.targetType.equals(targetType) &
              row.targetId.equals(targetId),
        ))
        .go();
  }

  _TargetToken _tokenOf(
    String targetType,
    String targetId,
    ({String? eventId, String? occurrenceExceptionId, String? taskId, String? planBlockId, int? startAt})
        resolved,
  ) => _TargetToken(
    targetType: targetType,
    targetId: targetId,
    eventId: resolved.eventId,
    occurrenceExceptionId: resolved.occurrenceExceptionId,
    taskId: resolved.taskId,
    planBlockId: resolved.planBlockId,
  );

  Future<void> _cancelRow(String id, int timestamp) =>
      (database.update(database.reminders)
            ..where((row) => row.id.equals(id)))
          .write(
            RemindersCompanion(
              state: const Value('cancelled'),
              updatedAt: Value(timestamp),
            ),
          );

  Future<void> _insert({
    required _TargetToken token,
    required int trigger,
    required int offset,
    required String state,
    required int timestamp,
  }) =>
      database
          .into(database.reminders)
          .insert(
            RemindersCompanion.insert(
              id: 'reminder:${token.targetType}:${token.targetId}:$trigger',
              accountId: accountId,
              targetType: token.targetType,
              targetId: token.targetId,
              eventId: Value(token.eventId),
              occurrenceExceptionId: Value(token.occurrenceExceptionId),
              taskId: Value(token.taskId),
              planBlockId: Value(token.planBlockId),
              offsetMinutes: Value(offset),
              triggerAt: trigger,
              state: state,
              createdAt: timestamp,
              updatedAt: timestamp,
            ),
          );

  /// Writes the no-offset cancelled sentinel that marks the target as
  /// explicitly disabled so [ReminderService] does not rebuild defaults.
  Future<void> _insertSentinel({
    required _TargetToken token,
    required int startAt,
    required int timestamp,
  }) =>
      database
          .into(database.reminders)
          .insert(
            RemindersCompanion.insert(
              id: 'reminder:${token.targetType}:${token.targetId}:disabled',
              accountId: accountId,
              targetType: token.targetType,
              targetId: token.targetId,
              eventId: Value(token.eventId),
              occurrenceExceptionId: Value(token.occurrenceExceptionId),
              taskId: Value(token.taskId),
              planBlockId: Value(token.planBlockId),
              triggerAt: startAt,
              state: 'cancelled',
              createdAt: timestamp,
              updatedAt: timestamp,
            ),
          );

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

/// Resolved FK/target identity for a generic Reminder write.
class _TargetToken {
  const _TargetToken({
    required this.targetType,
    required this.targetId,
    this.eventId,
    this.occurrenceExceptionId,
    this.taskId,
    this.planBlockId,
  });

  final String targetType;
  final String targetId;
  final String? eventId;
  final String? occurrenceExceptionId;
  final String? taskId;
  final String? planBlockId;
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