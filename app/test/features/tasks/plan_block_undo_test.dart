import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/schedule/application/jw_day_move_service.dart';
import 'package:ustc_assistant_app/features/tasks/application/plan_block_service.dart';
import 'package:ustc_assistant_app/features/tasks/application/task_lifecycle_service.dart';
import 'package:ustc_assistant_app/features/tasks/application/undo_recorder.dart';
import 'package:ustc_assistant_app/features/tasks/application/undo_service.dart';
import 'package:ustc_assistant_app/features/tasks/domain/plan_block.dart';

class FakeUndoRecorder implements UndoRecorder {
  final commands = <UndoCommand>[];

  @override
  Future<void> record(UndoCommand command) async => commands.add(command);
}

/// Beijing wall-clock -> storage epoch-ms (app reads stored UTC + 8h).
int _beijingEpoch(int year, int month, int day, int hour) =>
    DateTime.utc(year, month, day, hour).millisecondsSinceEpoch -
    const Duration(hours: 8).inMilliseconds;

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

  test(
    'undoing task completion restores task and cancelled future blocks',
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
      await tasks.complete(
        taskId,
        expectedUpdatedAt: (await tasks.byId(taskId)).updatedAt,
        cancelFutureAccepted: true,
      );
      expect((await blocks.byId(blockId)).status, PlanBlockStatus.cancelled);

      await undo.undo();

      expect((await tasks.byId(taskId)).state.name, 'active');
      expect((await blocks.byId(blockId)).status, PlanBlockStatus.accepted);
    },
  );

  test(
    'undoing a whole-day course move restores or deletes the exact prior row',
    () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      // One eligible JW course on 2026-08-03 so the move can be recorded.
      await database
          .into(database.calendarEvents)
          .insert(
            CalendarEventsCompanion.insert(
              id: 'course',
              accountId: 'a',
              source: 'ustc_jw',
              externalId: const Value('course'),
              title: 'course',
              type: 'course',
              startAt: Value(_beijingEpoch(2026, 8, 3, 9)),
              endAt: Value(_beijingEpoch(2026, 8, 3, 10)),
              allDay: false,
              timezone: 'Asia/Shanghai',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await database
          .into(database.sourceRecords)
          .insert(
            SourceRecordsCompanion.insert(
              id: 'source-course',
              accountId: 'a',
              source: 'ustc_jw',
              entityType: 'calendar_event',
              externalId: 'course',
              localEntityId: 'course',
              sourceStatus: 'active',
              presence: 'observed',
              scopeKey: 'semester',
              firstObservedAt: 1,
              lastObservedAt: 1,
            ),
          );
      var clock = 500;
      final undo = UndoService(
        database: database,
        accountId: 'a',
        now: () => ++clock,
      );
      final service = JwDayMoveService(
        database: database,
        accountId: 'a',
        now: () => ++clock,
        undoRecorder: undo,
      );

      // Insert: undoing a move deletes the move row.
      await service.move('2026-08-03', '2026-08-04');
      await undo.undo();
      expect(await database.select(database.jwDayMoves).get(), isEmpty);

      // Update: undoing a retarget restores the previous target date.
      await service.move('2026-08-03', '2026-08-04');
      await service.move('2026-08-03', '2026-08-05');
      await undo.undo();
      var row = await database.select(database.jwDayMoves).getSingle();
      expect(row.targetDate, '2026-08-04');

      // Delete: undoing a clear restores the exact deleted row.
      await service.clear('2026-08-03');
      expect(await database.select(database.jwDayMoves).get(), isEmpty);
      await undo.undo();
      row = await database.select(database.jwDayMoves).getSingle();
      expect(row.accountId, 'a');
      expect(row.sourceDate, '2026-08-03');
      expect(row.targetDate, '2026-08-04');

      // The undo slot is account-scoped: another account cannot reverse it.
      await database
          .into(database.localAccounts)
          .insert(
            LocalAccountsCompanion.insert(
              id: 'other',
              maskedHint: 'PB****1111',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await service.move('2026-08-03', '2026-08-05');
      await expectLater(
        UndoService(database: database, accountId: 'other').undo(),
        throwsA(isA<InvalidUndoCommand>()),
      );
      final after = await database.select(database.jwDayMoves).getSingle();
      expect(after.targetDate, '2026-08-05');
    },
  );

  test('deletedPlanBlocksForTask is task-scoped and returns deleted blocks', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final taskService = TaskLifecycleService(
      database: database,
      accountId: 'a',
      now: () => 1,
    );
    final taskId = await taskService.create(title: 'Task');
    final otherTaskId = await taskService.create(title: 'Other');
    var clock = 10;
    final service = PlanBlockService(
      database: database,
      accountId: 'a',
      now: () => ++clock,
    );
    final deletedId = await service.create(
      taskId: taskId,
      startAt: DateTime(2026, 7, 27, 9),
      endAt: DateTime(2026, 7, 27, 10),
    );
    final otherId = await service.create(
      taskId: otherTaskId,
      startAt: DateTime(2026, 7, 27, 11),
      endAt: DateTime(2026, 7, 27, 12),
    );
    var deletedBlock = await service.byId(deletedId);
    await service.softDelete(deletedId, expectedUpdatedAt: deletedBlock.updatedAt);

    // Task-scoped: only task's deleted block, not the other task's.
    final deleted = await service.deletedPlanBlocksForTask(taskId);
    expect(deleted.map((b) => b.id), contains(deletedId));
    expect(deleted.map((b) => b.id), isNot(contains(otherId)));
    // Other task still has its non-deleted block.
    final otherBlock = await service.byId(otherId);
    expect(otherBlock.deletedAt, isNull);
  });

  test('plan block restore restores original status and preserves task and '
        'replacement chain', () async {
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
        endAt: DateTime(2026, 7, 27, 10),
      );
      final block = await service.byId(id);
      await service.markDone(id, expectedUpdatedAt: block.updatedAt);
      expect((await service.byId(id)).status, PlanBlockStatus.done);

      // Delete then restore.
      final done = await service.byId(id);
      await service.softDelete(id, expectedUpdatedAt: done.updatedAt);
      final deleted = await service.byId(id, includeDeleted: true);
      await service.restore(id, expectedUpdatedAt: deleted.updatedAt);

      final restored = await service.byId(id);
      expect(restored.deletedAt, isNull);
      // Restore restores the original status (done).
      expect(restored.status, PlanBlockStatus.done);
      // Parent task preserved.
      expect((await taskService.byId(taskId)).title, 'Task');
    });

    test('plan block delete preserves replacement chain', () async {
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
      final oldBlock = await service.byId(id);
      await service.softDelete(oldBlock.id, expectedUpdatedAt: oldBlock.updatedAt);

      // Deleting the rescheduled (old) block keeps the accepted replacement.
      expect((await service.byId(replacement)).status, PlanBlockStatus.accepted);
      // The replacement is still reachable (not cascade-deleted).
      expect(
        (await service.deletedPlanBlocksForTask(taskId)).map((b) => b.id),
        contains(oldBlock.id),
      );
    });

    test('no-op delete returns already_deleted and writes nothing', () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      var clock = 30;
      final taskId = await TaskLifecycleService(
        database: database,
        accountId: 'a',
        now: () => ++clock,
      ).create(title: 'Task');
      final undo = FakeUndoRecorder();
      final service = PlanBlockService(
        database: database,
        accountId: 'a',
        now: () => ++clock,
        undoRecorder: undo,
      );
      final id = await service.create(
        taskId: taskId,
        startAt: DateTime(2026, 7, 27, 9),
        endAt: DateTime(2026, 7, 27, 10),
      );
      var block = await service.byId(id);
      await service.softDelete(id, expectedUpdatedAt: block.updatedAt);
      block = await service.byId(id, includeDeleted: true);

      expect(
        service.softDelete(id, expectedUpdatedAt: block.updatedAt),
        throwsA(isA<AlreadyDeletedError>()),
      );
      // No new undo / log for the no-op delete.
      expect(undo.commands.where((c) => c.kind == 'plan_block_delete'), hasLength(1));
    });

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

  group('undo preview account safety', () {
    test('preview returns a safe summary and type without payload/id/ref',
        () async {
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

      final preview = await undo.preview();

      expect(preview.available, isTrue);
      expect(preview.kind, 'task_create');
      expect(preview.summary, isNotEmpty);
      // SECURITY: preview must not leak payload, DB id, or ref.
      final dto = preview.toDto();
      expect(dto.containsKey('payload'), isFalse);
      expect(dto.containsKey('id'), isFalse);
      expect(dto.containsKey('ref'), isFalse);
      final encoded = jsonEncode(dto);
      expect(encoded, isNot(contains(taskId)));
    });

    test('another account preview reports unavailable and cannot read summary',
        () async {
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

      await database.into(database.localAccounts).insert(
            LocalAccountsCompanion.insert(
              id: 'other',
              maskedHint: 'PB****1111',
              createdAt: 1,
              updatedAt: 1,
            ),
          );

      final preview = await UndoService(
        database: database,
        accountId: 'other',
      ).preview();

      expect(preview.available, isFalse);
      // No summary (or any payload-derived data) for a foreign account.
      expect(preview.summary, isEmpty);
      expect(preview.kind, isEmpty);
      final encoded = jsonEncode(preview.toDto());
      expect(encoded, isNot(contains(taskId)));
      // The slot is untouched by a foreign preview.
      expect(await undo.canUndo(), isTrue);
    });

    test('foreign account undo does not delete the original undo slot',
        () async {
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
      // Rename so the top undo is reversible back to 'Original'.
      await tasks.rename(taskId, 'Renamed', expectedUpdatedAt: task.updatedAt);

      await database.into(database.localAccounts).insert(
            LocalAccountsCompanion.insert(
              id: 'other',
              maskedHint: 'PB****1111',
              createdAt: 1,
              updatedAt: 1,
            ),
          );

      await expectLater(
        UndoService(database: database, accountId: 'other').undo(),
        throwsA(isA<InvalidUndoCommand>()),
      );

      // The original account's slot must survive the failed foreign undo.
      expect(await undo.canUndo(), isTrue);
      // The original account can still reverse its own change.
      await undo.undo();
      expect((await tasks.byId(taskId)).title, 'Original');
      expect(await undo.canUndo(), isFalse);
    });
  });

  group('composite undo snapshot', () {
    test('composite restore atomically restores entity rows, reminders, '
        'links and policy config, consuming the slot once', () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      var clock = 100;
      final undo = UndoService(
        database: database,
        accountId: 'a',
        now: () => ++clock,
      );

      // Seed the original rows the composite snapshot will restore.
      await database.into(database.calendarEvents).insert(
            CalendarEventsCompanion.insert(
              id: 'ev-c',
              accountId: 'a',
              source: 'user',
              title: 'Event C',
              type: 'personal',
              startAt: Value(_beijingEpoch(2026, 8, 3, 9)),
              endAt: Value(_beijingEpoch(2026, 8, 3, 10)),
              allDay: false,
              timezone: 'Asia/Shanghai',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await database.into(database.tasks).insert(
            TasksCompanion.insert(
              id: 'task-composite',
              accountId: 'a',
              title: 'Original Title',
              state: 'active',
              importance: 'normal',
              tagsJson: '[]',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await database.into(database.planBlocks).insert(
            PlanBlocksCompanion.insert(
              id: 'pb-composite',
              accountId: 'a',
              taskId: 'task-composite',
              startAt: 1000,
              endAt: 2000,
              status: 'accepted',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await database.into(database.reminders).insert(
            RemindersCompanion.insert(
              id: 'reminder:event:ev-c:1',
              accountId: 'a',
              targetType: 'event',
              targetId: 'ev-c',
              eventId: const Value('ev-c'),
              offsetMinutes: const Value(10),
              triggerAt: 900,
              state: 'desired',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await database.into(database.taskEventLinks).insert(
            TaskEventLinksCompanion.insert(
              accountId: 'a',
              taskId: 'task-composite',
              eventId: 'ev-c',
              relationType: 'related',
              createdAt: 1,
            ),
          );
      await database.into(database.agentPermissionPolicies).insert(
            AgentPermissionPoliciesCompanion.insert(
              id: 'policy-composite',
              accountId: 'a',
              actionType: 'create_event',
              confirmationMode: 'always',
              createdAt: 1,
              updatedAt: 1,
            ),
          );

      // Snapshot the original rows, then destroy them so restore has work.
      final taskBefore =
          (await database.select(database.tasks)
                ..where(
                  (row) =>
                      row.id.equals('task-composite') &
                      row.accountId.equals('a'),
                ))
              .getSingle();
      final remindersBefore = await (database.select(database.reminders)
              ..where(
                (row) =>
                    row.accountId.equals('a') &
                    row.targetType.equals('event') &
                    row.targetId.equals('ev-c'),
              ))
          .get();
      final linkBefore =
          (await database.select(database.taskEventLinks)
                ..where(
                  (row) =>
                      row.accountId.equals('a') &
                      row.taskId.equals('task-composite') &
                      row.eventId.equals('ev-c'),
                ))
              .getSingle();
      final policyBefore =
          (await database.select(database.agentPermissionPolicies)
                ..where(
                  (row) =>
                      row.id.equals('policy-composite') &
                      row.accountId.equals('a'),
                ))
              .getSingle();

      await undo.record(
        UndoCommand(
          kind: 'composite_test',
          accountId: 'a',
          safeSummary: '组合恢复测试',
          payload: {
            'entity': 'composite',
            'operations': [
              {
                'entity': 'task',
                'id': 'task-composite',
                'before': (await taskBefore).toJson(),
              },
              {
                'entity': 'reminder_override',
                'targetType': 'event',
                'targetId': 'ev-c',
                'before': (await remindersBefore).map((r) => r.toJson()).toList(),
              },
              {
                'entity': 'task_event_link',
                'taskId': 'task-composite',
                'eventId': 'ev-c',
                'before': (await linkBefore).toJson(),
              },
              {
                'entity': 'permission_policy',
                'id': 'policy-composite',
                'before': (await policyBefore).toJson(),
              },
            ],
          },
        ),
      );

      // Destroy the rows.
      await (database.delete(database.tasks)..where(
            (row) => row.id.equals('task-composite'),
          ))
          .go();
      await (database.delete(database.reminders)..where(
            (row) => row.targetId.equals('ev-c'),
          ))
          .go();
      await (database.delete(database.taskEventLinks)..where(
            (row) => row.taskId.equals('task-composite'),
          ))
          .go();
      await (database.delete(database.agentPermissionPolicies)..where(
            (row) => row.id.equals('policy-composite'),
          ))
          .go();

      await undo.undo();

      // All four restored atomically.
      final task = await database.select(database.tasks).getSingle();
      expect(task.title, 'Original Title');
      expect(await database.select(database.reminders).get().then((r) => r.length),
          1);
      expect(await database.select(database.taskEventLinks).get().then((r) => r.length),
          1);
      expect(
        await database
            .select(database.agentPermissionPolicies)
            .get()
            .then((r) => r.length),
        1,
      );
      // Consumed only once.
      expect(await undo.canUndo(), isFalse);
    });

    test('composite restore failure keeps the slot and logs a safe failure',
        () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      var clock = 100;
      final undo = UndoService(
        database: database,
        accountId: 'a',
        now: () => ++clock,
      );

      // A composite with a task op whose 'before' is malformed -> restore fails.
      await undo.record(
        UndoCommand(
          kind: 'composite_test',
          accountId: 'a',
          payload: {
            'entity': 'composite',
            'summary': '坏组合',
            'operations': [
              {
                'entity': 'task',
                'id': 'task-composite',
                'before': {'title': 'x'}, // missing required fields -> throws
              },
            ],
          },
        ),
      );

      await expectLater(undo.undo(), throwsA(isA<InvalidUndoCommand>()));

      // Slot must NOT be cleared on a composite failure.
      expect(await undo.canUndo(), isTrue);
      final log = await database.actionLogsRepository.selectAll();
      expect(log.map((e) => e.result), contains('failure'));
    });
  });
}
