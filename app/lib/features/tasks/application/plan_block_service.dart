import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../domain/plan_block.dart';
import 'plan_block_lifecycle_port.dart';
import 'undo_recorder.dart';

class PlanBlockNotFoundError implements Exception {
  const PlanBlockNotFoundError();
}

class StalePlanBlockCommand implements Exception {
  const StalePlanBlockCommand();
}

class LockedPlanBlockError implements Exception {
  const LockedPlanBlockError();
}

class IllegalPlanBlockTransition implements Exception {
  const IllegalPlanBlockTransition(this.message);

  final String message;
}

class PlanBlockService implements PlanBlockLifecyclePort {
  PlanBlockService({
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
  static const _uuid = Uuid();

  Future<String> create({
    required String taskId,
    required DateTime startAt,
    required DateTime endAt,
    String? title,
    PlanBlockStatus status = PlanBlockStatus.accepted,
  }) async {
    _validateRange(startAt, endAt);
    if (status != PlanBlockStatus.accepted &&
        status != PlanBlockStatus.suggested) {
      throw const PlanBlockValidationError(
        'new blocks must be accepted or suggested',
      );
    }
    final id = _uuid.v4();
    final timestamp = now();
    await database.transaction(() async {
      await _requireTask(taskId);
      await database
          .into(database.planBlocks)
          .insert(
            PlanBlocksCompanion.insert(
              id: id,
              accountId: accountId,
              taskId: taskId,
              title: Value(_blankToNull(title)),
              startAt: startAt.millisecondsSinceEpoch,
              endAt: endAt.millisecondsSinceEpoch,
              status: status.storage,
              createdAt: timestamp,
              updatedAt: timestamp,
            ),
          );
      await _log('plan_block_create', 'Created a planning block.', timestamp);
      await undoRecorder.record(
        UndoCommand(
          kind: 'plan_block_create',
          accountId: accountId,
          payload: {'entity': 'plan_block', 'id': id, 'before': null},
        ),
      );
    });
    return id;
  }

  Future<PlanBlockItem> byId(String id, {bool includeDeleted = false}) async {
    final row = await _find(id, includeDeleted: includeDeleted);
    if (row == null) throw const PlanBlockNotFoundError();
    return PlanBlockItem.fromRow(row);
  }

  /// All soft-deleted (restorable) plan blocks for [taskId], for the read-only
  /// management queries. Account- and task-scoped inside the DB so a caller
  /// cannot fetch the whole account's deleted blocks without a task scope.
  Future<List<PlanBlockItem>> deletedPlanBlocksForTask(String taskId) async {
    final rows =
        await (database.select(database.planBlocks)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.taskId.equals(taskId) &
                  row.deletedAt.isNotNull(),
            ))
            .get();
    return rows.map(PlanBlockItem.fromRow).toList(growable: false);
  }

  Future<void> move(
    String id, {
    required DateTime startAt,
    required DateTime endAt,
    required int expectedUpdatedAt,
  }) {
    _validateRange(startAt, endAt);
    return _mutate(
      id,
      expectedUpdatedAt: expectedUpdatedAt,
      actionType: 'plan_block_move',
      changes: (row, timestamp) {
        if (row.locked) throw const LockedPlanBlockError();
        return PlanBlocksCompanion(
          startAt: Value(startAt.millisecondsSinceEpoch),
          endAt: Value(endAt.millisecondsSinceEpoch),
        );
      },
    );
  }

  Future<void> resize(
    String id, {
    required DateTime startAt,
    required DateTime endAt,
    required int expectedUpdatedAt,
  }) => move(
    id,
    startAt: startAt,
    endAt: endAt,
    expectedUpdatedAt: expectedUpdatedAt,
  );

  Future<void> setLocked(
    String id,
    bool locked, {
    required int expectedUpdatedAt,
  }) => _mutate(
    id,
    expectedUpdatedAt: expectedUpdatedAt,
    actionType: 'plan_block_lock',
    changes: (row, timestamp) => PlanBlocksCompanion(locked: Value(locked)),
  );

  Future<String> split(
    String id,
    DateTime splitAt, {
    required int expectedUpdatedAt,
  }) async {
    final replacementId = _uuid.v4();
    final timestamp = now();
    late PlanBlock before;
    await database.transaction(() async {
      final row = await _checked(id, expectedUpdatedAt);
      before = row;
      if (row.locked) throw const LockedPlanBlockError();
      final split = splitAt.millisecondsSinceEpoch;
      if (split <= row.startAt || split >= row.endAt) {
        throw const PlanBlockValidationError(
          'split must be inside the planning block',
        );
      }
      await (database.update(
        database.planBlocks,
      )..where((table) => table.id.equals(id))).write(
        PlanBlocksCompanion(endAt: Value(split), updatedAt: Value(timestamp)),
      );
      await database
          .into(database.planBlocks)
          .insert(
            PlanBlocksCompanion.insert(
              id: replacementId,
              accountId: accountId,
              taskId: row.taskId,
              title: Value(row.title),
              startAt: split,
              endAt: row.endAt,
              status: row.status,
              locked: Value(row.locked),
              createdAt: timestamp,
              updatedAt: timestamp,
            ),
          );
      await _log('plan_block_split', 'Split a planning block.', timestamp);
      await undoRecorder.record(
        UndoCommand(
          kind: 'plan_block_split',
          accountId: accountId,
          payload: {
            'entity': 'plan_block_split',
            'id': id,
            'createdId': replacementId,
            'before': _snapshot(before),
          },
        ),
      );
    });
    return replacementId;
  }

  Future<void> markDone(
    String id, {
    required int expectedUpdatedAt,
    String? note,
  }) => _review(
    id,
    PlanBlockStatus.done,
    expectedUpdatedAt: expectedUpdatedAt,
    note: note,
  );

  Future<void> markSkipped(
    String id, {
    required int expectedUpdatedAt,
    String? note,
  }) => _review(
    id,
    PlanBlockStatus.skipped,
    expectedUpdatedAt: expectedUpdatedAt,
    note: note,
  );

  Future<void> cancel(String id, {required int expectedUpdatedAt}) => _review(
    id,
    PlanBlockStatus.cancelled,
    expectedUpdatedAt: expectedUpdatedAt,
  );

  Future<String> reschedule(
    String id, {
    required DateTime startAt,
    required DateTime endAt,
    required int expectedUpdatedAt,
    String? note,
  }) async {
    _validateRange(startAt, endAt);
    final replacementId = _uuid.v4();
    final timestamp = now();
    late PlanBlock before;
    await database.transaction(() async {
      final row = await _checked(id, expectedUpdatedAt);
      before = row;
      if (row.status != PlanBlockStatus.accepted.storage) {
        throw const IllegalPlanBlockTransition(
          'only accepted blocks can be rescheduled',
        );
      }
      await database
          .into(database.planBlocks)
          .insert(
            PlanBlocksCompanion.insert(
              id: replacementId,
              accountId: accountId,
              taskId: row.taskId,
              title: Value(row.title),
              startAt: startAt.millisecondsSinceEpoch,
              endAt: endAt.millisecondsSinceEpoch,
              status: PlanBlockStatus.accepted.storage,
              createdAt: timestamp,
              updatedAt: timestamp,
            ),
          );
      await (database.update(
        database.planBlocks,
      )..where((table) => table.id.equals(id))).write(
        PlanBlocksCompanion(
          status: Value(PlanBlockStatus.rescheduled.storage),
          reviewNote: Value(_blankToNull(note)),
          reviewedAt: Value(timestamp),
          rescheduledToPlanBlockId: Value(replacementId),
          updatedAt: Value(timestamp),
        ),
      );
      await _log(
        'plan_block_reschedule',
        'Rescheduled a planning block.',
        timestamp,
      );
      await undoRecorder.record(
        UndoCommand(
          kind: 'plan_block_reschedule',
          accountId: accountId,
          payload: {
            'entity': 'plan_block_split',
            'id': id,
            'createdId': replacementId,
            'before': _snapshot(before),
          },
        ),
      );
    });
    return replacementId;
  }

  Future<void> softDelete(String id, {required int expectedUpdatedAt}) =>
      _mutate(
        id,
        expectedUpdatedAt: expectedUpdatedAt,
        actionType: 'plan_block_delete',
        changes: (row, timestamp) =>
            PlanBlocksCompanion(deletedAt: Value(timestamp)),
      );

  @override
  Future<PlanBlockImpact> summarize(String taskId, DateTime now) async {
    final rows = await _futureAccepted(taskId, now);
    return PlanBlockImpact(
      futureAcceptedCount: rows.length,
      futureAcceptedMinutes: rows.fold(
        0,
        (sum, row) => sum + ((row.endAt - row.startAt) ~/ 60000),
      ),
    );
  }

  @override
  Future<void> taskCancelled(String taskId, DateTime now) =>
      _cancelFuture(taskId, now);

  @override
  Future<void> taskCompleted(
    String taskId,
    DateTime now, {
    required bool cancelFutureAccepted,
  }) async {
    if (cancelFutureAccepted) await _cancelFuture(taskId, now);
  }

  Future<void> _cancelFuture(String taskId, DateTime instant) async {
    final timestamp = instant.millisecondsSinceEpoch;
    await (database.update(database.planBlocks)..where(
          (row) =>
              row.accountId.equals(accountId) &
              row.taskId.equals(taskId) &
              row.status.equals(PlanBlockStatus.accepted.storage) &
              row.startAt.isBiggerOrEqualValue(instant.millisecondsSinceEpoch) &
              row.deletedAt.isNull(),
        ))
        .write(
          PlanBlocksCompanion(
            status: Value(PlanBlockStatus.cancelled.storage),
            reviewedAt: Value(timestamp),
            updatedAt: Value(timestamp),
          ),
        );
  }

  Future<List<PlanBlock>> _futureAccepted(String taskId, DateTime instant) =>
      (database.select(database.planBlocks)..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.taskId.equals(taskId) &
                row.status.equals(PlanBlockStatus.accepted.storage) &
                row.endAt.isBiggerThanValue(instant.millisecondsSinceEpoch) &
                row.deletedAt.isNull(),
          ))
          .get();

  Future<void> _review(
    String id,
    PlanBlockStatus status, {
    required int expectedUpdatedAt,
    String? note,
  }) => _mutate(
    id,
    expectedUpdatedAt: expectedUpdatedAt,
    actionType: 'plan_block_${status.storage}',
    changes: (row, timestamp) {
      if (row.status != PlanBlockStatus.accepted.storage) {
        throw const IllegalPlanBlockTransition(
          'only accepted blocks can be reviewed',
        );
      }
      return PlanBlocksCompanion(
        status: Value(status.storage),
        reviewNote: Value(_blankToNull(note)),
        reviewedAt: Value(timestamp),
      );
    },
  );

  Future<void> _mutate(
    String id, {
    required int expectedUpdatedAt,
    required String actionType,
    required PlanBlocksCompanion Function(PlanBlock row, int timestamp) changes,
  }) async {
    final timestamp = now();
    await database.transaction(() async {
      final row = await _checked(id, expectedUpdatedAt);
      final companion = changes(
        row,
        timestamp,
      ).copyWith(updatedAt: Value(timestamp));
      await (database.update(
        database.planBlocks,
      )..where((table) => table.id.equals(id))).write(companion);
      await _log(actionType, 'Updated a planning block.', timestamp);
      await undoRecorder.record(
        UndoCommand(
          kind: actionType,
          accountId: accountId,
          payload: {'entity': 'plan_block', 'id': id, 'before': _snapshot(row)},
        ),
      );
    });
  }

  Future<PlanBlock> _checked(String id, int expectedUpdatedAt) async {
    final row = await _find(id);
    if (row == null) throw const PlanBlockNotFoundError();
    if (row.updatedAt != expectedUpdatedAt) {
      throw const StalePlanBlockCommand();
    }
    return row;
  }

  Future<PlanBlock?> _find(String id, {bool includeDeleted = false}) =>
      (database.select(database.planBlocks)..where(
            (row) =>
                row.id.equals(id) &
                row.accountId.equals(accountId) &
                (includeDeleted
                    ? const Constant(true)
                    : row.deletedAt.isNull()),
          ))
          .getSingleOrNull();

  Future<void> _requireTask(String id) async {
    final row =
        await (database.select(database.tasks)..where(
              (task) =>
                  task.id.equals(id) &
                  task.accountId.equals(accountId) &
                  task.deletedAt.isNull(),
            ))
            .getSingleOrNull();
    if (row == null) throw StateError('parent task not found');
  }

  Future<void> _log(String actionType, String summary, int timestamp) =>
      database.actionLogsRepository.append(
        accountId: accountId,
        source: 'user',
        actionType: actionType,
        result: 'success',
        safeSummary: summary,
        occurredAt: timestamp,
      );

  static Map<String, Object?> _snapshot(PlanBlock row) => {
    'id': row.id,
    'accountId': row.accountId,
    'taskId': row.taskId,
    'title': row.title,
    'startAt': row.startAt,
    'endAt': row.endAt,
    'status': row.status,
    'locked': row.locked,
    'reviewNote': row.reviewNote,
    'reviewedAt': row.reviewedAt,
    'rescheduledToPlanBlockId': row.rescheduledToPlanBlockId,
    'createdAt': row.createdAt,
    'updatedAt': row.updatedAt,
    'deletedAt': row.deletedAt,
  };

  static void _validateRange(DateTime startAt, DateTime endAt) {
    if (!endAt.isAfter(startAt)) {
      throw const PlanBlockValidationError('end must be after start');
    }
  }

  static String? _blankToNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
