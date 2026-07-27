import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/tasks/application/plan_block_service.dart';
import 'package:ustc_assistant_app/features/tasks/application/task_lifecycle_service.dart';
import 'package:ustc_assistant_app/features/tasks/application/undo_service.dart';
import 'package:ustc_assistant_app/features/tasks/domain/plan_block.dart';

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

void main() {
  test('elapsed accepted block awaits review without status write', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final taskService = TaskLifecycleService(
      database: database,
      accountId: 'a',
      now: () => 1,
    );
    final taskId = await taskService.create(title: 'Task');
    final service = PlanBlockService(
      database: database,
      accountId: 'a',
      now: () => 2,
    );
    final id = await service.create(
      taskId: taskId,
      startAt: DateTime(2026, 7, 27, 9),
      endAt: DateTime(2026, 7, 27, 10),
    );
    final block = await service.byId(id);

    expect(
      projectPlanBlock(block, DateTime(2026, 7, 27, 11)).awaitingReview,
      isTrue,
    );
    expect((await service.byId(id)).status, PlanBlockStatus.accepted);
  });

  test('move resize lock split and review transitions are durable', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    var clock = 10;
    final taskService = TaskLifecycleService(
      database: database,
      accountId: 'a',
      now: () => ++clock,
    );
    final taskId = await taskService.create(title: 'Task');
    final service = PlanBlockService(
      database: database,
      accountId: 'a',
      now: () => ++clock,
    );
    final id = await service.create(
      taskId: taskId,
      startAt: DateTime(2026, 7, 27, 9),
      endAt: DateTime(2026, 7, 27, 11),
    );
    var block = await service.byId(id);
    await service.move(
      id,
      startAt: DateTime(2026, 7, 27, 10),
      endAt: DateTime(2026, 7, 27, 12),
      expectedUpdatedAt: block.updatedAt,
    );
    block = await service.byId(id);
    await service.setLocked(id, true, expectedUpdatedAt: block.updatedAt);
    block = await service.byId(id);
    expect(
      service.move(
        id,
        startAt: DateTime(2026, 7, 27, 11),
        endAt: DateTime(2026, 7, 27, 13),
        expectedUpdatedAt: block.updatedAt,
      ),
      throwsA(isA<LockedPlanBlockError>()),
    );
    await service.setLocked(id, false, expectedUpdatedAt: block.updatedAt);
    block = await service.byId(id);
    final second = await service.split(
      id,
      DateTime(2026, 7, 27, 11),
      expectedUpdatedAt: block.updatedAt,
    );
    expect((await service.byId(id)).endAt.hour, 11);
    expect((await service.byId(second)).startAt.hour, 11);
    await service.markDone(
      id,
      expectedUpdatedAt: (await service.byId(id)).updatedAt,
    );
    expect((await service.byId(id)).status, PlanBlockStatus.done);
  });

  test(
    'reschedule atomically links old block to accepted replacement',
    () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      var clock = 20;
      final taskId = await TaskLifecycleService(
        database: database,
        accountId: 'a',
        now: () => ++clock,
      ).create(title: 'Task');
      final service = PlanBlockService(
        database: database,
        accountId: 'a',
        now: () => ++clock,
      );
      final id = await service.create(
        taskId: taskId,
        startAt: DateTime(2026, 7, 27, 9),
        endAt: DateTime(2026, 7, 27, 10),
      );
      final replacement = await service.reschedule(
        id,
        startAt: DateTime(2026, 7, 28, 9),
        endAt: DateTime(2026, 7, 28, 10),
        expectedUpdatedAt: (await service.byId(id)).updatedAt,
      );
      expect((await service.byId(id)).status, PlanBlockStatus.rescheduled);
      expect((await service.byId(id)).rescheduledToPlanBlockId, replacement);
      expect(
        (await service.byId(replacement)).status,
        PlanBlockStatus.accepted,
      );
    },
  );

  test('task terminal commands update only future accepted blocks', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    var clock = DateTime(2026, 7, 27, 12).millisecondsSinceEpoch;
    late PlanBlockService blocks;
    final tasks = TaskLifecycleService(
      database: database,
      accountId: 'a',
      now: () => ++clock,
      planBlocks: blocks = PlanBlockService(
        database: database,
        accountId: 'a',
        now: () => ++clock,
      ),
    );
    final taskId = await tasks.create(title: 'Task');
    final future = await blocks.create(
      taskId: taskId,
      startAt: DateTime(2026, 7, 28, 9),
      endAt: DateTime(2026, 7, 28, 10),
    );
    final elapsed = await blocks.create(
      taskId: taskId,
      startAt: DateTime(2026, 7, 27, 9),
      endAt: DateTime(2026, 7, 27, 10),
    );
    final impact = await tasks.terminalImpact(taskId);
    expect(impact.futureAcceptedCount, 1);
    await tasks.cancel(
      taskId,
      expectedUpdatedAt: (await tasks.byId(taskId)).updatedAt,
    );
    expect((await blocks.byId(future)).status, PlanBlockStatus.cancelled);
    expect((await blocks.byId(elapsed)).status, PlanBlockStatus.accepted);
  });

  test('new reversible action replaces previous undo', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    var clock = 100;
    final undo = UndoService(
      database: database,
      accountId: 'a',
      now: () => ++clock,
    );
    final tasks = TaskLifecycleService(
      database: database,
      accountId: 'a',
      now: () => ++clock,
      undoRecorder: undo,
    );
    final taskId = await tasks.create(title: 'Original');
    var task = await tasks.byId(taskId);
    await tasks.rename(taskId, 'One', expectedUpdatedAt: task.updatedAt);
    task = await tasks.byId(taskId);
    await tasks.rename(taskId, 'Two', expectedUpdatedAt: task.updatedAt);

    await undo.undo();

    expect((await tasks.byId(taskId)).title, 'One');
    expect(await undo.canUndo(), isFalse);
    expect(
      (await database.actionLogsRepository.selectAll()).map(
        (entry) => entry.actionType,
      ),
      contains('undo_task_rename'),
    );
  });

  test(
    'undoing task cancellation restores atomically cancelled blocks',
    () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      var clock = DateTime(2026, 7, 27, 12).millisecondsSinceEpoch;
      final undo = UndoService(
        database: database,
        accountId: 'a',
        now: () => ++clock,
      );
      final blocks = PlanBlockService(
        database: database,
        accountId: 'a',
        now: () => ++clock,
        undoRecorder: undo,
      );
      final tasks = TaskLifecycleService(
        database: database,
        accountId: 'a',
        now: () => ++clock,
        undoRecorder: undo,
        planBlocks: blocks,
      );
      final taskId = await tasks.create(title: 'Task');
      final blockId = await blocks.create(
        taskId: taskId,
        startAt: DateTime(2026, 7, 28, 9),
        endAt: DateTime(2026, 7, 28, 10),
      );
      await tasks.cancel(
        taskId,
        expectedUpdatedAt: (await tasks.byId(taskId)).updatedAt,
      );

      await undo.undo();

      expect((await tasks.byId(taskId)).state.name, 'active');
      expect((await blocks.byId(blockId)).status, PlanBlockStatus.accepted);
    },
  );

  test('undo slot clears on startup and failed undo preserves data', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final undo = UndoService(database: database, accountId: 'a');
    await database.replaceUndoSlot(commandId: 'bad', payload: '{"version":9}');
    await expectLater(undo.undo(), throwsA(isA<InvalidUndoCommand>()));
    expect(await database.select(database.tasks).get(), isEmpty);
    expect(await undo.canUndo(), isFalse);

    await database.replaceUndoSlot(commandId: 'old', payload: '{}');
    await undo.clearAtStartup();
    expect(await undo.canUndo(), isFalse);
  });
}
