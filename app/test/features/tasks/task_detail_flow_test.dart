import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/tasks/application/plan_block_service.dart';
import 'package:ustc_assistant_app/features/tasks/application/task_lifecycle_service.dart';
import 'package:ustc_assistant_app/features/tasks/domain/plan_block.dart';
import 'package:ustc_assistant_app/features/tasks/presentation/plan_block_editor.dart';
import 'package:ustc_assistant_app/features/tasks/presentation/task_detail_loader.dart';

Future<AppDatabase> _database() async {
  final database = AppDatabase(NativeDatabase.memory());
  await database
      .into(database.localAccounts)
      .insert(
        LocalAccountsCompanion.insert(
          id: 'account',
          maskedHint: 'PB****0000',
          isActive: const Value(true),
          createdAt: 1,
          updatedAt: 1,
        ),
      );
  return database;
}

void main() {
  testWidgets('task detail creates a plan block and one-step undo removes it', (
    tester,
  ) async {
    final database = await _database();
    addTearDown(database.close);
    final taskId =
        await TaskLifecycleService(
          database: database,
          accountId: 'account',
          now: () => 10,
        ).create(
          title: '完成实验报告',
          userNotes: '先处理数据',
          deadlineAt: DateTime(2026, 7, 30, 18, 45),
        );
    await tester.pumpWidget(
      MaterialApp(
        home: TaskDetailLoader(
          database: database,
          taskId: taskId,
          initialNow: DateTime(2026, 7, 27, 10),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('完成实验报告'), findsWidgets);
    expect(find.textContaining('2026-07-30 18:45'), findsOneWidget);
    expect(find.textContaining('先处理数据'), findsOneWidget);
    await tester.tap(find.byKey(const Key('schedule-task')));
    await tester.pumpAndSettle();
    expect(find.byType(PlanBlockEditor), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('plan-start')),
      '2026-07-28 09:00',
    );
    await tester.enterText(find.byKey(const Key('plan-duration')), '60');
    await tester.tap(find.byKey(const Key('save-plan-block')));
    await tester.pumpAndSettle();

    expect(await database.select(database.planBlocks).get(), hasLength(1));
    expect(find.textContaining('2026-07-28 09:00'), findsOneWidget);
    await tester.tap(find.byKey(const Key('task-detail-undo')));
    await tester.pumpAndSettle();
    expect(await database.select(database.planBlocks).get(), isEmpty);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('task-detail-undo')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('deleted task route has an explicit missing state', (
    tester,
  ) async {
    final database = await _database();
    addTearDown(database.close);
    final service = TaskLifecycleService(
      database: database,
      accountId: 'account',
      now: () => 10,
    );
    final taskId = await service.create(title: '将被删除');
    final task = await service.byId(taskId);
    await service.softDelete(taskId, expectedUpdatedAt: task.updatedAt);

    await tester.pumpWidget(
      MaterialApp(
        home: TaskDetailLoader(database: database, taskId: taskId),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('记录已不存在'), findsOneWidget);
    expect(find.byKey(const Key('missing-task-back')), findsOneWidget);
  });

  testWidgets('task state and plan-block review actions are connected', (
    tester,
  ) async {
    final database = await _database();
    addTearDown(database.close);
    var clock = DateTime(2026, 7, 27, 12).millisecondsSinceEpoch;
    final tasks = TaskLifecycleService(
      database: database,
      accountId: 'account',
      now: () => ++clock,
    );
    final taskId = await tasks.create(title: '复习期末');
    final blocks = PlanBlockService(
      database: database,
      accountId: 'account',
      now: () => ++clock,
    );
    final doneId = await blocks.create(
      taskId: taskId,
      startAt: DateTime(2026, 7, 27, 8),
      endAt: DateTime(2026, 7, 27, 9),
    );
    final skippedId = await blocks.create(
      taskId: taskId,
      startAt: DateTime(2026, 7, 27, 9),
      endAt: DateTime(2026, 7, 27, 10),
    );
    final rescheduledId = await blocks.create(
      taskId: taskId,
      startAt: DateTime(2026, 7, 27, 10),
      endAt: DateTime(2026, 7, 27, 11),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: TaskDetailLoader(
          database: database,
          taskId: taskId,
          initialNow: DateTime(2026, 7, 27, 12),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('toggle-task-blocked')));
    await tester.pumpAndSettle();
    expect(find.text('状态：受阻'), findsOneWidget);
    await tester.tap(find.byKey(const Key('toggle-task-blocked')));
    await tester.pumpAndSettle();
    expect(find.text('状态：进行中'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(Key('done-plan-block-$doneId')),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(Key('done-plan-block-$doneId')));
    await tester.pumpAndSettle();
    expect((await blocks.byId(doneId)).status, PlanBlockStatus.done);

    await tester.scrollUntilVisible(
      find.byKey(Key('skip-plan-block-$skippedId')),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -140));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('skip-plan-block-$skippedId')));
    await tester.pumpAndSettle();
    expect((await blocks.byId(skippedId)).status, PlanBlockStatus.skipped);

    await tester.scrollUntilVisible(
      find.byKey(Key('reschedule-plan-block-$rescheduledId')),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -140));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('reschedule-plan-block-$rescheduledId')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('plan-start')),
      '2026-07-28 09:00',
    );
    await tester.tap(find.byKey(const Key('save-plan-block')));
    await tester.pumpAndSettle();
    expect(
      (await blocks.byId(rescheduledId)).status,
      PlanBlockStatus.rescheduled,
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('cancel-task')),
      -120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('cancel-task')));
    await tester.pumpAndSettle();
    expect(find.text('状态：已取消'), findsOneWidget);
    await tester.tap(find.byKey(const Key('reopen-task')));
    await tester.pumpAndSettle();
    expect(find.text('状态：进行中'), findsOneWidget);
  });

  testWidgets('deleted plan blocks surface in a collapsed recovery section '
      'and restore re-shows them by original status', (tester) async {
    final database = await _database();
    addTearDown(database.close);
    var clock = DateTime(2026, 7, 27, 12).millisecondsSinceEpoch;
    final tasks = TaskLifecycleService(
      database: database,
      accountId: 'account',
      now: () => ++clock,
    );
    final taskId = await tasks.create(title: '恢复计划块');
    final blocks = PlanBlockService(
      database: database,
      accountId: 'account',
      now: () => ++clock,
    );
    final doneId = await blocks.create(
      taskId: taskId,
      title: '已完成块',
      startAt: DateTime(2026, 7, 27, 8),
      endAt: DateTime(2026, 7, 27, 9),
    );
    // Mark the block done, then soft-delete it. The recovery section must
    // surface it collapsed; restore returns it to its pre-delete (done) status.
    final doneBlock = await blocks.byId(doneId);
    await blocks.markDone(doneId, expectedUpdatedAt: doneBlock.updatedAt);
    final doneBlock2 = await blocks.byId(doneId);
    await blocks.softDelete(doneId, expectedUpdatedAt: doneBlock2.updatedAt);

    await tester.pumpWidget(
      MaterialApp(
        home: TaskDetailLoader(
          database: database,
          taskId: taskId,
          initialNow: DateTime(2026, 7, 27, 12),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The recovery section header renders collapsed by default.
    expect(find.byKey(const Key('deleted-plan-blocks-header')), findsOneWidget);
    // The deleted block is NOT shown expanded yet.
    expect(find.byKey(Key('restore-plan-block-$doneId')), findsNothing);

    // Expand the recovery section.
    await tester.tap(find.byKey(const Key('deleted-plan-blocks-header')));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('restore-plan-block-$doneId')), findsOneWidget);

    // Restore the block: it leaves the recovery section and re-appears in the
    // active plan-block list by its original (done) status.
    await tester.tap(find.byKey(Key('restore-plan-block-$doneId')));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('restore-plan-block-$doneId')), findsNothing);
    final restored = await blocks.byId(doneId);
    expect(restored.deletedAt, isNull);
    expect(restored.status, PlanBlockStatus.done);
  });
}
