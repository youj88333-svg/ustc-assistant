import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../domain/task.dart';
import 'plan_block_lifecycle_port.dart';
import 'undo_recorder.dart';

class TaskNotFoundError implements Exception {
  const TaskNotFoundError();

  @override
  String toString() => 'TaskNotFoundError';
}

class StaleTaskCommand implements Exception {
  const StaleTaskCommand();

  @override
  String toString() => 'StaleTaskCommand';
}

class IllegalTaskTransition implements Exception {
  const IllegalTaskTransition(this.message);

  final String message;

  @override
  String toString() => 'IllegalTaskTransition: $message';
}

class TaskLifecycleService {
  TaskLifecycleService({
    required this.database,
    required this.accountId,
    int Function()? now,
    UndoRecorder? undoRecorder,
    PlanBlockLifecyclePort? planBlocks,
    this.logToActionLog = true,
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       undoRecorder = undoRecorder ?? const NoopUndoRecorder(),
       planBlocks = planBlocks ?? const NoopPlanBlockLifecyclePort();

  final AppDatabase database;
  final String accountId;
  final int Function() now;
  final UndoRecorder undoRecorder;
  final PlanBlockLifecyclePort planBlocks;

  /// When false, the service-internal `source=user` ActionLog is suppressed so
  /// an Agent Gateway call can own the single `source=agent` business log
  /// (written by the outer atomic commit). UI user operations keep `true`.
  /// Undo snapshots are ALWAYS recorded regardless of this flag.
  final bool logToActionLog;
  static const _uuid = Uuid();

  Future<String> create({
    required String title,
    String? description,
    String? userNotes,
    TaskImportance importance = TaskImportance.normal,
    DateTime? deadlineAt,
    int? estimatedMinutes,
    List<String> tags = const [],
    List<String> eventIds = const [],
  }) async {
    final normalized = TaskItem(
      id: 'validation',
      title: title,
      description: description,
      userNotes: userNotes,
      state: TaskState.active,
      importance: importance,
      deadlineAt: deadlineAt,
      estimatedMinutes: estimatedMinutes,
      tags: tags,
      createdAt: 0,
      updatedAt: 0,
    );
    final id = _uuid.v4();
    final timestamp = now();
    await database.transaction(() async {
      for (final eventId in eventIds) {
        final event =
            await (database.select(database.calendarEvents)..where(
                  (row) =>
                      row.id.equals(eventId) &
                      row.accountId.equals(accountId) &
                      row.deletedAt.isNull(),
                ))
                .getSingleOrNull();
        if (event == null) throw StateError('linked event not found');
      }
      await database
          .into(database.tasks)
          .insert(
            TasksCompanion.insert(
              id: id,
              accountId: accountId,
              title: normalized.title,
              description: Value(description),
              userNotes: Value(userNotes),
              state: TaskState.active.storage,
              blockedReason: const Value(null),
              importance: importance.storage,
              deadlineAt: Value(deadlineAt?.millisecondsSinceEpoch),
              estimatedMinutes: Value(estimatedMinutes),
              tagsJson: jsonEncode(tags),
              completedAt: const Value(null),
              cancelledAt: const Value(null),
              createdAt: timestamp,
              updatedAt: timestamp,
            ),
          );
      for (final eventId in eventIds) {
        await database
            .into(database.taskEventLinks)
            .insert(
              TaskEventLinksCompanion.insert(
                accountId: accountId,
                taskId: id,
                eventId: eventId,
                relationType: 'related',
                createdAt: timestamp,
              ),
            );
      }
      await _log('task_create', 'Created a task.', timestamp);
      await undoRecorder.record(
        UndoCommand(
          kind: 'task_create',
          accountId: accountId,
          payload: {'entity': 'task', 'id': id, 'before': null},
        ),
      );
    });
    return id;
  }

  Future<TaskItem> byId(String id, {bool includeDeleted = false}) async {
    final row = await _find(id, includeDeleted: includeDeleted);
    if (row == null) throw const TaskNotFoundError();
    return TaskItem.fromRow(row);
  }

  /// All soft-deleted (restorable) tasks for the account, for the read-only
  /// management queries. Account-scoped inside the DB.
  Future<List<TaskItem>> deletedTasks() async {
    final rows =
        await (database.select(database.tasks)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.deletedAt.isNotNull(),
            ))
            .get();
    return rows.map(TaskItem.fromRow).toList(growable: false);
  }

  Future<void> rename(
    String id,
    String title, {
    required int expectedUpdatedAt,
  }) {
    final normalized = title.trim();
    if (normalized.isEmpty) {
      throw const TaskValidationError('title must not be blank');
    }
    return _mutate(
      id,
      expectedUpdatedAt: expectedUpdatedAt,
      actionType: 'task_rename',
      summary: 'Renamed a task.',
      companion: (row, timestamp) => TasksCompanion(title: Value(normalized)),
    );
  }

  Future<void> block(
    String id, {
    required int expectedUpdatedAt,
    String? reason,
  }) => _mutate(
    id,
    expectedUpdatedAt: expectedUpdatedAt,
    actionType: 'task_block',
    summary: 'Blocked a task.',
    companion: (row, timestamp) {
      if (row.state != TaskState.active.storage) {
        throw const IllegalTaskTransition('only active tasks can be blocked');
      }
      return TasksCompanion(
        state: Value(TaskState.blocked.storage),
        blockedReason: Value(_blankToNull(reason)),
      );
    },
  );

  Future<void> unblock(String id, {required int expectedUpdatedAt}) => _mutate(
    id,
    expectedUpdatedAt: expectedUpdatedAt,
    actionType: 'task_unblock',
    summary: 'Unblocked a task.',
    companion: (row, timestamp) {
      if (row.state != TaskState.blocked.storage) {
        throw const IllegalTaskTransition(
          'only blocked tasks can be unblocked',
        );
      }
      return TasksCompanion(
        state: Value(TaskState.active.storage),
        blockedReason: const Value(null),
      );
    },
  );

  Future<void> complete(
    String id, {
    required int expectedUpdatedAt,
    bool cancelFutureAccepted = false,
  }) => _mutate(
    id,
    expectedUpdatedAt: expectedUpdatedAt,
    actionType: 'task_complete',
    summary: 'Completed a task.',
    companion: (row, timestamp) {
      if (row.state == TaskState.completed.storage ||
          row.state == TaskState.cancelled.storage) {
        throw const IllegalTaskTransition(
          'terminal tasks must be reopened first',
        );
      }
      return TasksCompanion(
        state: Value(TaskState.completed.storage),
        blockedReason: const Value(null),
        completedAt: Value(timestamp),
        cancelledAt: const Value(null),
      );
    },
    afterWrite: (timestamp) => planBlocks.taskCompleted(
      id,
      DateTime.fromMillisecondsSinceEpoch(timestamp),
      cancelFutureAccepted: cancelFutureAccepted,
    ),
    restorePlanBlocksOnUndo: cancelFutureAccepted,
  );

  Future<void> cancel(String id, {required int expectedUpdatedAt}) => _mutate(
    id,
    expectedUpdatedAt: expectedUpdatedAt,
    actionType: 'task_cancel',
    summary: 'Cancelled a task.',
    companion: (row, timestamp) {
      if (row.state == TaskState.completed.storage ||
          row.state == TaskState.cancelled.storage) {
        throw const IllegalTaskTransition(
          'terminal tasks must be reopened first',
        );
      }
      return TasksCompanion(
        state: Value(TaskState.cancelled.storage),
        blockedReason: const Value(null),
        completedAt: const Value(null),
        cancelledAt: Value(timestamp),
      );
    },
    afterWrite: (timestamp) => planBlocks.taskCancelled(
      id,
      DateTime.fromMillisecondsSinceEpoch(timestamp),
    ),
    restorePlanBlocksOnUndo: true,
  );

  Future<void> reopen(String id, {required int expectedUpdatedAt}) => _mutate(
    id,
    expectedUpdatedAt: expectedUpdatedAt,
    actionType: 'task_reopen',
    summary: 'Reopened a task.',
    companion: (row, timestamp) {
      if (row.state != TaskState.completed.storage &&
          row.state != TaskState.cancelled.storage) {
        throw const IllegalTaskTransition(
          'only terminal tasks can be reopened',
        );
      }
      return TasksCompanion(
        state: Value(TaskState.active.storage),
        blockedReason: const Value(null),
        completedAt: const Value(null),
        cancelledAt: const Value(null),
      );
    },
  );

  Future<void> softDelete(String id, {required int expectedUpdatedAt}) =>
      _mutate(
        id,
        expectedUpdatedAt: expectedUpdatedAt,
        actionType: 'task_delete',
        summary: 'Deleted a task.',
        companion: (row, timestamp) =>
            TasksCompanion(deletedAt: Value(timestamp)),
      );

  Future<void> restore(String id, {required int expectedUpdatedAt}) => _mutate(
    id,
    expectedUpdatedAt: expectedUpdatedAt,
    actionType: 'task_restore',
    summary: 'Restored a task.',
    companion: (row, timestamp) {
      if (row.deletedAt == null) {
        throw const IllegalTaskTransition('task is not deleted');
      }
      return const TasksCompanion(deletedAt: Value(null));
    },
    includeDeleted: true,
  );

  Future<PlanBlockImpact> terminalImpact(String id) async {
    await byId(id);
    final timestamp = now();
    return planBlocks.summarize(
      id,
      DateTime.fromMillisecondsSinceEpoch(timestamp),
    );
  }

  Future<void> _mutate(
    String id, {
    required int expectedUpdatedAt,
    required String actionType,
    required String summary,
    required TasksCompanion Function(Task row, int timestamp) companion,
    Future<void> Function(int timestamp)? afterWrite,
    bool restorePlanBlocksOnUndo = false,
    bool includeDeleted = false,
  }) async {
    late Task before;
    final timestamp = now();
    await database.transaction(() async {
      final row = await _find(id, includeDeleted: includeDeleted);
      if (row == null) throw const TaskNotFoundError();
      if (row.updatedAt != expectedUpdatedAt) throw const StaleTaskCommand();
      before = row;
      final changes = companion(
        row,
        timestamp,
      ).copyWith(updatedAt: Value(timestamp));
      await (database.update(database.tasks)..where(
            (table) =>
                table.id.equals(id) &
                table.accountId.equals(accountId) &
                table.updatedAt.equals(expectedUpdatedAt) &
                (includeDeleted
                    ? const Constant(true)
                    : table.deletedAt.isNull()),
          ))
          .write(changes);
      if (afterWrite != null) await afterWrite(timestamp);
      await _log(actionType, summary, timestamp);
      await undoRecorder.record(
        UndoCommand(
          kind: actionType,
          accountId: accountId,
          payload: {
            'entity': 'task',
            'id': id,
            'before': _safeBeforeState(before),
            'transitionAt': timestamp,
            'restorePlanBlocks': restorePlanBlocksOnUndo,
          },
        ),
      );
    });
  }

  Future<Task?> _find(String id, {bool includeDeleted = false}) =>
      (database.select(database.tasks)..where(
            (row) =>
                row.id.equals(id) &
                row.accountId.equals(accountId) &
                (includeDeleted
                    ? const Constant(true)
                    : row.deletedAt.isNull()),
          ))
          .getSingleOrNull();

  Future<void> _log(String actionType, String summary, int timestamp) async {
    if (!logToActionLog) return;
    await database.actionLogsRepository.append(
      accountId: accountId,
      source: 'user',
      actionType: actionType,
      result: 'success',
      safeSummary: summary,
      occurredAt: timestamp,
    );
  }

  Map<String, Object?> _safeBeforeState(Task task) => {
    'id': task.id,
    'accountId': task.accountId,
    'title': task.title,
    'description': task.description,
    'userNotes': task.userNotes,
    'state': task.state,
    'blockedReason': task.blockedReason,
    'importance': task.importance,
    'deadlineAt': task.deadlineAt,
    'estimatedMinutes': task.estimatedMinutes,
    'tagsJson': task.tagsJson,
    'completedAt': task.completedAt,
    'cancelledAt': task.cancelledAt,
    'createdAt': task.createdAt,
    'updatedAt': task.updatedAt,
    'deletedAt': task.deletedAt,
  };

  static String? _blankToNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
