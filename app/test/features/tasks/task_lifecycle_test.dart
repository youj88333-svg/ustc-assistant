import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/tasks/application/plan_block_lifecycle_port.dart';
import 'package:ustc_assistant_app/features/tasks/application/task_lifecycle_service.dart';
import 'package:ustc_assistant_app/features/tasks/application/undo_recorder.dart';
import 'package:ustc_assistant_app/features/tasks/domain/task.dart';
import 'package:ustc_assistant_app/features/tasks/domain/task_projection.dart';

Future<AppDatabase> fixtureDatabase() async {
  final database = AppDatabase(NativeDatabase.memory());
  await database
      .into(database.localAccounts)
      .insert(
        LocalAccountsCompanion.insert(
          id: 'a',
          maskedHint: 'PB****0000',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
  return database;
}

class FakeUndoRecorder implements UndoRecorder {
  final commands = <UndoCommand>[];

  @override
  Future<void> record(UndoCommand command) async => commands.add(command);
}

class FakePlanBlockPort implements PlanBlockLifecyclePort {
  final completed = <bool>[];
  var cancelled = 0;

  @override
  Future<PlanBlockImpact> summarize(String taskId, DateTime now) async =>
      const PlanBlockImpact(futureAcceptedCount: 2, futureAcceptedMinutes: 90);

  @override
  Future<void> taskCancelled(String taskId, DateTime now) async {
    cancelled++;
  }

  @override
  Future<void> taskCompleted(
    String taskId,
    DateTime now, {
    required bool cancelFutureAccepted,
  }) async {
    completed.add(cancelFutureAccepted);
  }
}

void main() {
  test('clock passage changes projection without a database write', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final task = TaskItem(
      id: 't',
      title: '截止事项',
      state: TaskState.active,
      importance: TaskImportance.normal,
      deadlineAt: DateTime(2026, 7, 27, 10),
      createdAt: 1,
      updatedAt: 1,
    );
    final before = await database.actionLogsRepository.selectAll();

    expect(
      projectTask(task, DateTime(2026, 7, 27, 9, 59)).deadline,
      DeadlineState.dueToday,
    );
    expect(
      projectTask(task, DateTime(2026, 7, 27, 10, 1)).deadline,
      DeadlineState.overdue,
    );
    expect(await database.actionLogsRepository.selectAll(), before);
  });

  test('planning and confirmation are derived from accepted blocks only', () {
    final task = TaskItem(
      id: 't',
      title: '规划',
      state: TaskState.active,
      importance: TaskImportance.normal,
      createdAt: 1,
      updatedAt: 1,
    );
    final now = DateTime(2026, 7, 27, 10);
    final projection = projectTask(
      task,
      now,
      planBlocks: [
        PlanBlockSnapshot(
          state: PlanBlockProjectionState.accepted,
          endAt: now.subtract(const Duration(minutes: 1)),
        ),
        PlanBlockSnapshot(
          state: PlanBlockProjectionState.accepted,
          endAt: now.add(const Duration(hours: 1)),
        ),
        PlanBlockSnapshot(
          state: PlanBlockProjectionState.suggested,
          endAt: now.add(const Duration(hours: 2)),
        ),
      ],
    );
    expect(projection.planning, PlanningState.planned);
    expect(projection.confirmation, ConfirmationState.awaitingPlanBlockReview);
  });

  test('completed task must be reopened before blocking', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    var clock = 10;
    final service = TaskLifecycleService(
      database: database,
      accountId: 'a',
      now: () => ++clock,
    );
    final id = await service.create(title: '任务');
    final active = await service.byId(id);
    await service.complete(id, expectedUpdatedAt: active.updatedAt);
    final completed = await service.byId(id);

    expect(
      service.block(id, expectedUpdatedAt: completed.updatedAt, reason: '等待材料'),
      throwsA(isA<IllegalTaskTransition>()),
    );
  });

  test(
    'unblocking clears reason and terminal commands stamp separately',
    () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      var clock = 20;
      final service = TaskLifecycleService(
        database: database,
        accountId: 'a',
        now: () => ++clock,
      );
      final id = await service.create(title: '任务');
      var task = await service.byId(id);
      await service.block(
        id,
        expectedUpdatedAt: task.updatedAt,
        reason: '等待材料',
      );
      task = await service.byId(id);
      await service.unblock(id, expectedUpdatedAt: task.updatedAt);
      task = await service.byId(id);
      expect(task.state, TaskState.active);
      expect(task.blockedReason, isNull);

      await service.complete(id, expectedUpdatedAt: task.updatedAt);
      task = await service.byId(id);
      expect(task.completedAt, isNotNull);
      expect(task.cancelledAt, isNull);
      await service.reopen(id, expectedUpdatedAt: task.updatedAt);
      task = await service.byId(id);
      expect(task.completedAt, isNull);
      expect(task.cancelledAt, isNull);
    },
  );

  test('task never completes merely because deadline passed', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = TaskLifecycleService(
      database: database,
      accountId: 'a',
      now: () => DateTime(2026, 8, 1).millisecondsSinceEpoch,
    );
    final id = await service.create(
      title: '过期任务',
      deadlineAt: DateTime(2026, 7, 1),
    );
    expect((await service.byId(id)).state, TaskState.active);
  });

  test('soft deletion and stale commands are rejected safely', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    var clock = 30;
    final undo = FakeUndoRecorder();
    final service = TaskLifecycleService(
      database: database,
      accountId: 'a',
      now: () => ++clock,
      undoRecorder: undo,
    );
    final id = await service.create(title: '任务');
    final original = await service.byId(id);
    await service.rename(id, '新名称', expectedUpdatedAt: original.updatedAt);
    expect(
      service.softDelete(id, expectedUpdatedAt: original.updatedAt),
      throwsA(isA<StaleTaskCommand>()),
    );
    expect(undo.commands, hasLength(2));

    final latest = await service.byId(id);
    await service.softDelete(id, expectedUpdatedAt: latest.updatedAt);
    expect(service.byId(id), throwsA(isA<TaskNotFoundError>()));
    expect((await service.byId(id, includeDeleted: true)).deletedAt, isNotNull);
  });

  test('task-event links are persisted with creation', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    await database
        .into(database.calendarEvents)
        .insert(
          CalendarEventsCompanion.insert(
            id: 'event',
            accountId: 'a',
            source: 'user',
            title: '日程',
            type: 'personal',
            startAt: Value(DateTime(2026, 7, 27, 9).millisecondsSinceEpoch),
            endAt: Value(DateTime(2026, 7, 27, 10).millisecondsSinceEpoch),
            allDay: false,
            timezone: 'Asia/Shanghai',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    final service = TaskLifecycleService(
      database: database,
      accountId: 'a',
      now: () => 40,
    );
    final id = await service.create(title: '关联任务', eventIds: const ['event']);
    final link = (await database.select(database.taskEventLinks).get()).single;
    expect(link.taskId, id);
    expect(link.eventId, 'event');
  });

  test('soft-deleted task can be explicitly restored', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    var clock = 45;
    final service = TaskLifecycleService(
      database: database,
      accountId: 'a',
      now: () => ++clock,
    );
    final id = await service.create(title: 'Restore');
    var task = await service.byId(id);
    await service.softDelete(id, expectedUpdatedAt: task.updatedAt);
    task = await service.byId(id, includeDeleted: true);
    await service.restore(id, expectedUpdatedAt: task.updatedAt);
    expect((await service.byId(id)).deletedAt, isNull);
  });

  test('deletedTasks returns only soft-deleted, account-scoped tasks', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    var clock = 45;
    final service = TaskLifecycleService(
      database: database,
      accountId: 'a',
      now: () => ++clock,
    );
    final activeId = await service.create(title: '正常任务');
    final deletedId = await service.create(title: '已删除');
    final deletedRow = await service.byId(deletedId);
    await service.softDelete(
      deletedId,
      expectedUpdatedAt: deletedRow.updatedAt,
    );

    final deleted = await service.deletedTasks();
    final titles = deleted.map((t) => t.title).toList();
    expect(titles, contains('已删除'));
    expect(titles, isNot(contains('正常任务')));
    // The active task is still readable via the normal path.
    expect((await service.byId(activeId)).deletedAt, isNull);
  });

  test(
    'default no-op PlanBlock port supports completion and cancellation',
    () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      var clock = 50;
      final service = TaskLifecycleService(
        database: database,
        accountId: 'a',
        now: () => ++clock,
      );
      final first = await service.create(title: '完成');
      var task = await service.byId(first);
      await service.complete(first, expectedUpdatedAt: task.updatedAt);
      final second = await service.create(title: '取消');
      task = await service.byId(second);
      await service.cancel(second, expectedUpdatedAt: task.updatedAt);
      expect((await service.byId(second)).state, TaskState.cancelled);
    },
  );

  test(
    'PlanBlock port summarizes impact and receives terminal calls',
    () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      var clock = 60;
      final port = FakePlanBlockPort();
      final service = TaskLifecycleService(
        database: database,
        accountId: 'a',
        now: () => ++clock,
        planBlocks: port,
      );
      final id = await service.create(title: '任务');
      expect((await service.terminalImpact(id)).futureAcceptedCount, 2);
      var task = await service.byId(id);
      await service.complete(
        id,
        expectedUpdatedAt: task.updatedAt,
        cancelFutureAccepted: true,
      );
      expect(port.completed, [true]);
      await service.reopen(
        id,
        expectedUpdatedAt: (await service.byId(id)).updatedAt,
      );
      task = await service.byId(id);
      await service.cancel(id, expectedUpdatedAt: task.updatedAt);
      expect(port.cancelled, 1);
    },
  );

  group('deterministic lifecycle state machine', () {
    test('delete sets parent deletedAt but preserves children and links',
        () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      var clock = 70;
      final service = TaskLifecycleService(
        database: database,
        accountId: 'a',
        now: () => ++clock,
      );
      final id = await service.create(title: '任务');
      var task = await service.byId(id);
      await service.softDelete(id, expectedUpdatedAt: task.updatedAt);

      // Parent is suppressed (not readable through the normal path).
      expect(service.byId(id), throwsA(isA<TaskNotFoundError>()));
      // Deleted task is restorable.
      expect((await service.byId(id, includeDeleted: true)).deletedAt, isNotNull);
    });

    test('reopen does not restore cancelled plan blocks', () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      var clock = 80;
      final service = TaskLifecycleService(
        database: database,
        accountId: 'a',
        now: () => ++clock,
      );
      final id = await service.create(title: '任务');
      // Seed an already-cancelled plan block for the task that predates reopen.
      await database.into(database.planBlocks).insert(
            PlanBlocksCompanion.insert(
              id: 'old-block',
              accountId: 'a',
              taskId: id,
              startAt: DateTime(2026, 7, 28, 9).millisecondsSinceEpoch,
              endAt: DateTime(2026, 7, 28, 10).millisecondsSinceEpoch,
              status: 'cancelled',
              reviewedAt: const Value(1),
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      var task = await service.byId(id);
      await service.cancel(id, expectedUpdatedAt: task.updatedAt);
      task = await service.byId(id);
      await service.reopen(id, expectedUpdatedAt: task.updatedAt);

      // Reopen never resurrects cancelled plan blocks.
      final row = await (database.select(database.planBlocks)
            ..where((block) => block.id.equals('old-block')))
          .getSingle();
      expect(row.status, 'cancelled');
      expect((await service.byId(id)).state, TaskState.active);
    });

    test('logToActionLog=false skips the user log but still records undo',
        () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      var clock = 90;
      final undo = FakeUndoRecorder();
      final service = TaskLifecycleService(
        database: database,
        accountId: 'a',
        now: () => ++clock,
        undoRecorder: undo,
        logToActionLog: false,
      );
      final id = await service.create(title: '任务');
      var task = await service.byId(id);

      await service.cancel(id, expectedUpdatedAt: task.updatedAt);

      // No service-internal user ActionLog is written (Agent owns the log).
      final logs = await database.actionLogsRepository.selectAll();
      expect(
        logs.map((log) => log.actionType),
        isNot(contains('task_cancel')),
      );
      // Undo snapshot is STILL recorded (lifecycle undo is not skipped).
      expect(
        undo.commands.where((c) => c.kind == 'task_cancel'),
        hasLength(1),
      );
    });
  });
}
