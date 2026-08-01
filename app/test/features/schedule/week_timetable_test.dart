import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/features/schedule/domain/overlap_engine.dart';
import 'package:ustc_assistant_app/features/schedule/domain/schedule_grid_item.dart';
import 'package:ustc_assistant_app/features/schedule/domain/schedule_projection.dart';
import 'package:ustc_assistant_app/features/schedule/presentation/event_block.dart';
import 'package:ustc_assistant_app/features/schedule/presentation/overlap_expansion.dart';
import 'package:ustc_assistant_app/features/schedule/presentation/week_timetable.dart';
import 'package:ustc_assistant_app/features/tasks/domain/plan_block.dart';
import 'package:ustc_assistant_app/features/tasks/domain/task.dart';

EffectiveEvent timed(
  String id,
  int day,
  int startHour,
  int startMinute,
  int endHour,
  int endMinute, {
  String? location,
  bool conflict = false,
  bool preview = false,
  int foregroundPriority = 0,
}) => EffectiveEvent.timed(
  id: id,
  title: id,
  location: location,
  startAt: DateTime(2026, 7, 20 + day, startHour, startMinute),
  endAt: DateTime(2026, 7, 20 + day, endHour, endMinute),
  hasConfirmedConflict: conflict,
  isInactivePreview: preview,
  foregroundPriority: foregroundPriority,
);

TaskItem taskItem(String id, {String title = ''}) => TaskItem(
  id: id,
  title: title.isEmpty ? id : title,
  state: TaskState.active,
  importance: TaskImportance.normal,
  createdAt: 1,
  updatedAt: 1,
);

PlanBlockItem blockItem(
  String id,
  String taskId,
  DateTime start,
  DateTime end,
  PlanBlockStatus status,
) => PlanBlockItem(
  id: id,
  taskId: taskId,
  startAt: start,
  endAt: end,
  status: status,
  locked: false,
  createdAt: 1,
  updatedAt: 1,
);

Widget fixture(
  List<EffectiveEvent> events, {
  List<PlanBlockItem> planBlocks = const [],
  List<TaskItem> tasks = const [],
  ValueChanged<ScheduleGridItem>? onSelected,
}) {
  final items = <ScheduleGridItem>[
    for (final event in events) ScheduleGridItem.fromEvent(event),
    for (final block in planBlocks)
      ScheduleGridItem.fromPlanBlock(
        block,
        tasks.firstWhere((task) => task.id == block.taskId),
      ),
  ];
  return MaterialApp(
    home: Scaffold(
      body: WeekTimetable(
        projection: buildWeek(
          ScheduleQuery(selectedDate: DateTime(2026, 7, 20), items: items),
        ),
        tasks: tasks,
        onEventSelected: onSelected ?? (_) {},
      ),
    ),
  );
}

void main() {
  testWidgets('Saturday and Sunday remain reachable on phone width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(fixture([timed('event-sunday', 6, 9, 45, 11, 20)]));

    await tester.drag(
      find.byKey(const Key('week-horizontal-scroll')),
      const Offset(-900, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('周日').hitTestable(), findsOneWidget);
    expect(
      find.byKey(const Key('event-event-sunday')).hitTestable(),
      findsOneWidget,
    );
  });

  testWidgets('first overlap tap expands and second selects one event', (
    tester,
  ) async {
    ScheduleGridItem? selected;
    await tester.pumpWidget(
      fixture([
        timed('电路基本理论', 1, 9, 45, 11, 20),
        timed('量子物理 B', 1, 10, 0, 11, 30),
      ], onSelected: (item) => selected = item),
    );

    await tester.tap(find.byKey(const Key('overlap-group-电路基本理论|量子物理 B')));
    await tester.pumpAndSettle();
    expect(find.byType(OverlapExpansion), findsOneWidget);
    await tester.tap(find.text('量子物理 B').last);
    await tester.pumpAndSettle();
    expect(selected?.id, '量子物理 B');
  });

  testWidgets('overlap expansion shows every event in a three-event group', (
    tester,
  ) async {
    await tester.pumpWidget(
      fixture([
        timed('a', 1, 9, 45, 11, 20),
        timed('b', 1, 10, 0, 11, 30),
        timed('c', 1, 10, 15, 12, 0),
      ]),
    );

    await tester.tap(find.byKey(const Key('overlap-group-a|b|c')));
    await tester.pumpAndSettle();

    expect(find.byType(OverlapExpansion), findsOneWidget);
    expect(find.text('a'), findsWidgets);
    expect(find.text('b'), findsWidgets);
    expect(find.text('c'), findsWidgets);
  });

  testWidgets('foreground is translucent and background events are blurred', (
    tester,
  ) async {
    await tester.pumpWidget(
      fixture([
        timed('a', 0, 9, 45, 11, 20),
        timed('b', 0, 10, 0, 11, 30, conflict: true),
      ]),
    );

    final foreground = tester.widget<Opacity>(
      find.byKey(const Key('event-opacity-b')),
    );
    expect(foreground.opacity, lessThan(1));
    expect(find.byType(ImageFiltered), findsWidgets);
    expect(find.bySemanticsLabel('已确认冲突').evaluate(), isNotEmpty);
  });

  testWidgets('explicit foreground priority wins overlap ordering', (
    tester,
  ) async {
    await tester.pumpWidget(
      fixture([
        timed('important', 0, 9, 45, 11, 20),
        timed('chosen', 0, 10, 0, 11, 30, foregroundPriority: 100),
      ]),
    );

    expect(
      tester
          .widget<Opacity>(find.byKey(const Key('event-opacity-chosen')))
          .opacity,
      greaterThan(
        tester
            .widget<Opacity>(find.byKey(const Key('event-opacity-important')))
            .opacity,
      ),
    );
  });

  testWidgets(
    'event content prioritizes title and location with preview state',
    (tester) async {
      await tester.pumpWidget(
        fixture([
          timed('随机过程', 2, 9, 45, 11, 20, location: '3C203', preview: true),
        ]),
      );

      expect(find.text('随机过程'), findsOneWidget);
      expect(find.text('3C203'), findsOneWidget);
      final block = tester.widget<EventBlock>(find.byType(EventBlock));
      expect(block.item.isInactivePreview, isTrue);
    },
  );

  testWidgets('accepted plan block renders with task title fallback', (
    tester,
  ) async {
    final task = taskItem('task-x', title: '完成实验报告');
    final block = blockItem(
      'block-x',
      task.id,
      DateTime(2026, 7, 21, 9, 45),
      DateTime(2026, 7, 21, 11, 20),
      PlanBlockStatus.accepted,
    );
    await tester.pumpWidget(fixture([], planBlocks: [block], tasks: [task]));

    expect(find.byKey(const Key('plan-block-block-x')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('plan-block-block-x')),
        matching: find.text('完成实验报告'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('plan block accessibility text includes the task time range', (
    tester,
  ) async {
    final task = taskItem('task-x', title: '完成实验报告');
    final block = blockItem(
      'block-x',
      task.id,
      DateTime(2026, 7, 21, 9, 45),
      DateTime(2026, 7, 21, 11, 20),
      PlanBlockStatus.accepted,
    );
    await tester.pumpWidget(fixture([], planBlocks: [block], tasks: [task]));

    expect(find.bySemanticsLabel(RegExp('任务时间段')), findsOneWidget);
  });

  testWidgets('event and plan block overlap expands then selects the right item', (
    tester,
  ) async {
    final task = taskItem('task-x', title: '完成实验报告');
    final block = blockItem(
      'block-x',
      task.id,
      DateTime(2026, 7, 21, 10, 0),
      DateTime(2026, 7, 21, 11, 30),
      PlanBlockStatus.accepted,
    );
    ScheduleGridItem? selected;
    await tester.pumpWidget(
      fixture(
        [timed('event-x', 1, 9, 45, 11, 20)],
        planBlocks: [block],
        tasks: [task],
        onSelected: (item) => selected = item,
      ),
    );

    await tester.tap(find.byKey(const Key('overlap-group-event-x|block-x')));
    await tester.pumpAndSettle();
    expect(find.byType(OverlapExpansion), findsOneWidget);
    await tester.tap(find.text('完成实验报告').last);
    await tester.pumpAndSettle();
    expect(selected?.kind, ScheduleGridItemKind.planBlock);
    expect(selected?.planBlock?.id, 'block-x');
  });
}
