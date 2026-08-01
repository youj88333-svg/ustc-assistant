import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/schedule/presentation/overlap_expansion.dart';
import 'package:ustc_assistant_app/features/schedule/presentation/schedule_page.dart';
import 'package:ustc_assistant_app/features/tasks/domain/plan_block.dart';

Future<void> seedAccount(AppDatabase database) async {
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
}

Future<void> seedTask(AppDatabase database, String id, String title) async {
  await database
      .into(database.tasks)
      .insert(
        TasksCompanion.insert(
          id: id,
          accountId: 'account',
          title: title,
          state: 'active',
          importance: 'normal',
          tagsJson: '[]',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
}

Future<void> seedPlanBlock(
  AppDatabase database, {
  required String id,
  required String taskId,
  required DateTime startAt,
  required DateTime endAt,
  required String status,
}) async {
  await database
      .into(database.planBlocks)
      .insert(
        PlanBlocksCompanion.insert(
          id: id,
          accountId: 'account',
          taskId: taskId,
          startAt: startAt.millisecondsSinceEpoch,
          endAt: endAt.millisecondsSinceEpoch,
          status: status,
          createdAt: 1,
          updatedAt: 1,
        ),
      );
}

void main() {
  testWidgets('week controls navigate, persist, and return to current week', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SchedulePage(database: database)),
      ),
    );
    await tester.pumpAndSettle();

    final initial = tester
        .widget<Text>(find.byKey(const Key('week-range-label')))
        .data;
    await tester.tap(find.byTooltip('下一周'));
    await tester.pumpAndSettle();
    final following = tester
        .widget<Text>(find.byKey(const Key('week-range-label')))
        .data;
    expect(following, isNot(initial));

    await tester.tap(find.text('任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('周视图'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('week-range-label'))).data,
      following,
    );

    await tester.tap(find.byTooltip('回到本周'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('week-range-label'))).data,
      initial,
    );
  });

  testWidgets('imported events appear in the selected week', (tester) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
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
    await database
        .into(database.calendarEvents)
        .insert(
          CalendarEventsCompanion.insert(
            id: 'future-event',
            accountId: 'account',
            source: 'ustc_young_my_schedule',
            title: '未来二课活动',
            type: 'second_class',
            startAt: Value(DateTime.utc(2026, 8, 3, 2).millisecondsSinceEpoch),
            endAt: Value(
              DateTime.utc(2026, 8, 3, 3, 30).millisecondsSinceEpoch,
            ),
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
            id: 'future-source',
            accountId: 'account',
            source: 'ustc_young_my_schedule',
            entityType: 'calendar_event',
            externalId: 'future-event',
            localEntityId: 'future-event',
            sourceStatus: 'active',
            presence: 'observed',
            scopeKey: 'window',
            firstObservedAt: 1,
            lastObservedAt: 1,
          ),
        );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SchedulePage(
            database: database,
            clock: FixedBeijingClock(DateTime(2026, 7, 27)),
          ),
        ),
      ),
    );
    for (var index = 0; index < 5; index++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.text('未来二课活动'), findsNothing);
    await tester.tap(find.byTooltip('下一周'));
    for (var index = 0; index < 5; index++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('未来二课活动'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('event selection exposes the stable event id', (tester) async {
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
    await database
        .into(database.calendarEvents)
        .insert(
          CalendarEventsCompanion.insert(
            id: 'personal-event',
            accountId: 'account',
            source: 'user',
            title: '晚间安排',
            type: 'personal',
            startAt: Value(DateTime.utc(2026, 7, 27).millisecondsSinceEpoch),
            endAt: Value(DateTime.utc(2026, 7, 27, 1).millisecondsSinceEpoch),
            allDay: false,
            timezone: 'Asia/Shanghai',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    String? selectedId;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SchedulePage(
            database: database,
            clock: FixedBeijingClock(DateTime(2026, 7, 27)),
            onEventSelected: (value) => selectedId = value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('event-personal-event')));
    await tester.pumpAndSettle();
    expect(selectedId, 'personal-event');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await database.close();
  });

  // Task 4: route-driven section selection.
  // `initialSection` defaults to week, so a bare SchedulePage opens the week
  // view (the app's default). Before the Task 4 fix there was no such param.
  testWidgets('initialSection defaults to week', (tester) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SchedulePage(database: database))),
    );
    await tester.pumpAndSettle();

    final seg = tester.widget<SegmentedButton<ScheduleSection>>(
      find.byType(SegmentedButton<ScheduleSection>),
    );
    expect(seg.selected, {ScheduleSection.week});
    expect(find.byKey(const Key('week-range-label')), findsOneWidget);
  });

  // Passing `initialSection: tasks` must open the tasks section (the fix for
  // "查看任务" landing on the week view).
  testWidgets('initialSection tasks opens the tasks section', (tester) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SchedulePage(
            database: database,
            initialSection: ScheduleSection.tasks,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final seg = tester.widget<SegmentedButton<ScheduleSection>>(
      find.byType(SegmentedButton<ScheduleSection>),
    );
    expect(seg.selected, {ScheduleSection.tasks});
    expect(find.byKey(const Key('week-range-label')), findsNothing);
  });

  // A change in `initialSection` (e.g. a route rebuild from ?section=week to
  // ?section=tasks) MUST update the visible section even though the StatefulShell
  // keeps the SchedulePage State alive — it must not preserve stale shell state.
  testWidgets('initialSection change updates the selected section', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SchedulePage(database: database, key: const Key('schedule')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    SegmentedButton<ScheduleSection> seg() => tester.widget<
        SegmentedButton<ScheduleSection>>(
      find.byType(SegmentedButton<ScheduleSection>),
    );
    expect(seg().selected, {ScheduleSection.week});

    // Route rebuild with a new initialSection (same key => State preserved).
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SchedulePage(
            database: database,
            key: const Key('schedule'),
            initialSection: ScheduleSection.tasks,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(seg().selected, {ScheduleSection.tasks});

    // And back to week.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SchedulePage(
            database: database,
            key: const Key('schedule'),
            initialSection: ScheduleSection.week,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(seg().selected, {ScheduleSection.week});
  });

  // Task 5: accepted plan blocks from the DB appear in the week grid and tap
  // through to the parent task.
  testWidgets('accepted plan block appears in week grid and taps to parent task', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    await seedAccount(database);
    await seedTask(database, 'task-x', '完成实验报告');
    await seedPlanBlock(
      database,
      id: 'block-x',
      taskId: 'task-x',
      startAt: DateTime(2026, 7, 27, 10),
      endAt: DateTime(2026, 7, 27, 11),
      status: PlanBlockStatus.accepted.storage,
    );

    String? selectedTaskId;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SchedulePage(
            database: database,
            clock: FixedBeijingClock(DateTime(2026, 7, 27)),
            onTaskSelected: (id) => selectedTaskId = id,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('plan-block-block-x')), findsOneWidget);
    await tester.tap(find.byKey(const Key('plan-block-block-x')));
    await tester.pumpAndSettle();
    expect(selectedTaskId, 'task-x');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('non-accepted plan block stays out of the week grid', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    await seedAccount(database);
    await seedTask(database, 'task-y', '仅建议');
    await seedPlanBlock(
      database,
      id: 'block-y',
      taskId: 'task-y',
      startAt: DateTime(2026, 7, 27, 10),
      endAt: DateTime(2026, 7, 27, 11),
      status: PlanBlockStatus.suggested.storage,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SchedulePage(
            database: database,
            clock: FixedBeijingClock(DateTime(2026, 7, 27)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('plan-block-block-y')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  // Task 5: an event and a plan block in the same slot share one overlap
  // expansion; the second tap routes to the event or the parent task.
  testWidgets('event and plan block overlap expand then route to right target', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    await seedAccount(database);
    await seedTask(database, 'task-x', '完成实验报告');
    await database
        .into(database.calendarEvents)
        .insert(
          CalendarEventsCompanion.insert(
            id: 'overlap-event',
            accountId: 'account',
            source: 'user',
            title: '晚间安排',
            type: 'personal',
            startAt: Value(DateTime.utc(2026, 7, 27, 1).millisecondsSinceEpoch),
            endAt: Value(
              DateTime.utc(2026, 7, 27, 2, 30).millisecondsSinceEpoch,
            ),
            allDay: false,
            timezone: 'Asia/Shanghai',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await seedPlanBlock(
      database,
      id: 'block-x',
      taskId: 'task-x',
      startAt: DateTime(2026, 7, 27, 9, 30),
      endAt: DateTime(2026, 7, 27, 10, 45),
      status: PlanBlockStatus.accepted.storage,
    );

    String? selectedEventId;
    String? selectedTaskId;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SchedulePage(
            database: database,
            clock: FixedBeijingClock(DateTime(2026, 7, 27)),
            onEventSelected: (id) => selectedEventId = id,
            onTaskSelected: (id) => selectedTaskId = id,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final overlapKey = const Key('overlap-group-overlap-event|block-x');
    expect(find.byKey(overlapKey), findsOneWidget);
    await tester.tap(find.byKey(overlapKey));
    await tester.pumpAndSettle();
    expect(find.byType(OverlapExpansion), findsOneWidget);

    // Second tap on the event routes to the event detail.
    await tester.tap(find.text('晚间安排').last);
    await tester.pumpAndSettle();
    expect(selectedEventId, 'overlap-event');

    // Reopen and tap the plan block: routes to the parent task.
    await tester.tap(find.byKey(overlapKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成实验报告').last);
    await tester.pumpAndSettle();
    expect(selectedTaskId, 'task-x');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
