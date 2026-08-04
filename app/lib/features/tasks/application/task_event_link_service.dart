import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import 'undo_recorder.dart';

/// Deterministic error returned when unlink targets are missing, deleted, or
/// belong to another account.
class TaskEventLinkTargetNotFoundError implements Exception {
  const TaskEventLinkTargetNotFoundError();

  @override
  String toString() => 'TaskEventLinkTargetNotFoundError';
}

/// Deterministic error returned when no `(account, task, event)` link exists.
class TaskEventLinkNotFoundError implements Exception {
  const TaskEventLinkNotFoundError();

  @override
  String toString() => 'TaskEventLinkNotFoundError';
}

/// Builds and removes Task<->Event links.
///
/// [unlink] removes the single `(taskId, eventId)` link under the bound
/// account. The two targets must be account-owned and not deleted, the link
/// must exist, and (when supplied) the expected `updatedAt` / existence
/// snapshots must match — otherwise a deterministic error is raised and
/// nothing is written. An event with `source != user` (school-sourced) is
/// still a valid unlink target: the local `related` link is a user-owned
/// configuration and may be removed regardless of the event's origin. No other
/// object (task, event, plan block, reminder, relation) is touched. The link
/// delete, ActionLog and a composite Undo snapshot share one transaction.
class TaskEventLinkService {
  TaskEventLinkService({
    required this.database,
    required this.accountId,
    int Function()? now,
    UndoRecorder? undoRecorder,
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       undoRecorder = undoRecorder ?? const NoopUndoRecorder();

  final AppDatabase database;
  final String accountId;
  final int Function() now;
  final UndoRecorder undoRecorder;

  /// Removes the `(taskId, eventId)` `related` link for the account.
  ///
  /// Optional [expectedTaskUpdatedAt] / [expectedEventUpdatedAt] snapshots
  /// force a TOCTOU re-check: when supplied and mismatched, a
  /// [TaskEventLinkTargetNotFoundError] (foreign/missing/deleted target) or
  /// stale-state error is raised. The deletion is idempotent per the standard
  /// — a missing link yields [TaskEventLinkNotFoundError] with no write.
  Future<void> unlink({
    required String taskId,
    required String eventId,
    int? expectedTaskUpdatedAt,
    int? expectedEventUpdatedAt,
  }) async {
    await database.transaction(() async {
      final task = await _taskRow(taskId);
      if (task == null) throw const TaskEventLinkTargetNotFoundError();
      if (expectedTaskUpdatedAt != null &&
          task.updatedAt != expectedTaskUpdatedAt) {
        throw const TaskEventLinkTargetNotFoundError();
      }

      final event = await _eventRow(eventId);
      if (event == null) throw const TaskEventLinkTargetNotFoundError();
      if (expectedEventUpdatedAt != null &&
          event.updatedAt != expectedEventUpdatedAt) {
        throw const TaskEventLinkTargetNotFoundError();
      }

      final link = await _linkRow(taskId, eventId);
      if (link == null) throw const TaskEventLinkNotFoundError();

      await (database.delete(database.taskEventLinks)..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.taskId.equals(taskId) &
                row.eventId.equals(eventId),
          ))
          .go();
      await database.actionLogsRepository.append(
        accountId: accountId,
        source: 'user',
        actionType: 'unlink_task_event',
        result: 'success',
        safeSummary: 'Unlinked a task from an event.',
        occurredAt: now(),
      );
      await undoRecorder.record(
        UndoCommand(
          kind: 'unlink_task_event',
          accountId: accountId,
          safeSummary: 'Unlinked a task from an event.',
          payload: {
            'entity': 'composite',
            'operations': [
              {
                'entity': 'task_event_link',
                'taskId': taskId,
                'eventId': eventId,
                'before': _linkSnapshot(link),
              },
            ],
          },
        ),
      );
    });
  }

  Future<CalendarEvent?> _eventRow(String eventId) =>
      (database.select(database.calendarEvents)..where(
            (row) =>
                row.id.equals(eventId) &
                row.accountId.equals(accountId) &
                row.deletedAt.isNull(),
          ))
          .getSingleOrNull();

  Future<Task?> _taskRow(String taskId) =>
      (database.select(database.tasks)..where(
            (row) =>
                row.id.equals(taskId) &
                row.accountId.equals(accountId) &
                row.deletedAt.isNull(),
          ))
          .getSingleOrNull();

  Future<TaskEventLink?> _linkRow(String taskId, String eventId) =>
      (database.select(database.taskEventLinks)..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.taskId.equals(taskId) &
                row.eventId.equals(eventId),
          ))
          .getSingleOrNull();

  Map<String, Object?> _linkSnapshot(TaskEventLink link) => {
    'targetId': link.targetId,
    'eventId': link.eventId,
    'occurrenceExceptionId': link.occurrenceExceptionId,
    'relationType': link.relationType,
    'createdAt': link.createdAt,
  };
}