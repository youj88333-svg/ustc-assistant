import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ustc_assistant_m0/app/calendar_week_view.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('portrait week keeps all dates inside common phone widths', (
    tester,
  ) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final fixture = _fixture();
    for (final width in [320.0, 360.0, 412.0]) {
      for (final textScale in [1.0, 1.5, 2.0]) {
        await _pumpWeek(tester, fixture, width: width, textScale: textScale);

        final viewport = find.byKey(
          const ValueKey('calendar-week-horizontal-scroll'),
        );
        final horizontalScrollable = find
            .descendant(of: viewport, matching: find.byType(Scrollable))
            .first;
        final position = tester
            .state<ScrollableState>(horizontalScrollable)
            .position;
        final viewportRect = tester.getRect(viewport);
        final expectedToFit = textScale < 2 || width >= 400;
        expect(
          position.maxScrollExtent,
          expectedToFit ? 0 : greaterThan(0),
          reason: '$width dp at text scale $textScale should degrade safely',
        );
        for (var offset = 0; offset < 7; offset++) {
          final day = DateTime.utc(2026, 10, 12 + offset);
          final heading = find.byKey(
            ValueKey('calendar-week-heading-${_dayKey(day)}'),
          );
          expect(heading, findsOneWidget);
          expect(find.text(_compactDate(day)), findsOneWidget);
          if (expectedToFit) {
            final rect = tester.getRect(heading);
            expect(rect.left, greaterThanOrEqualTo(viewportRect.left - .1));
            expect(rect.right, lessThanOrEqualTo(viewportRect.right + .1));
          }
        }
        if (!expectedToFit) {
          final firstHeading = find.byKey(
            const ValueKey('calendar-week-heading-2026-10-12'),
          );
          expect(
            tester.getRect(firstHeading).right,
            lessThanOrEqualTo(viewportRect.right + .1),
            reason: 'the first date starts visible before horizontal scrolling',
          );
          position.jumpTo(position.maxScrollExtent);
          await tester.pumpAndSettle();
          final lastHeading = find.byKey(
            const ValueKey('calendar-week-heading-2026-10-18'),
          );
          expect(
            tester.getRect(lastHeading).left,
            greaterThanOrEqualTo(tester.getRect(viewport).left - .1),
          );
        }
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('narrow week keeps date, event, conflict, and task actions open', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final fixture = _fixture();
    CalendarOccurrence? selectedOccurrence;
    List<CalendarOccurrence>? overflowOccurrences;
    String? overflowHeading;
    TaskRecord? selectedTask;
    List<TaskRecord>? overflowTasks;

    await _pumpWeek(
      tester,
      fixture,
      width: 320,
      textScale: 1,
      onSelect: (value) => selectedOccurrence = value,
      onOverflow: (heading, values) {
        overflowHeading = heading;
        overflowOccurrences = values;
      },
      onSelectTask: (value) => selectedTask = value,
      onTaskOverflow: (_, values) => overflowTasks = values,
    );

    final allDayTile = find.byKey(
      ValueKey<CalendarReference>(fixture.allDay.reference),
    );
    expect(allDayTile, findsOneWidget);
    await tester.tap(allDayTile);
    expect(overflowHeading, contains('全天'));
    expect(overflowOccurrences, contains(fixture.allDay));
    expect(overflowOccurrences, contains(fixture.secondAllDay));

    final courseTile = find.byKey(
      ValueKey<CalendarReference>(fixture.course.reference),
    );
    await tester.ensureVisible(courseTile);
    await tester.pumpAndSettle();
    expect(
      find.byTooltip('存在时间冲突，点按查看日程详情'),
      findsWidgets,
      reason: 'the condensed overlapping tiles retain a visible conflict mark',
    );
    expect(
      find.byTooltip(
        '同名课程\n时间（北京时间）：09:00–10:00\n'
        '地点：教学楼 A 101\n尚未采集教务信息，重新同步补充',
      ),
      findsOneWidget,
      reason:
          'the narrow course tile keeps its complete title and location tooltip',
    );
    await tester.tap(courseTile);
    expect(selectedOccurrence, same(fixture.course));

    final dayList = find.byKey(const ValueKey('calendar-week-day-2026-10-14'));
    await tester.tap(dayList);
    expect(overflowHeading, contains('10-14'));
    expect(overflowOccurrences, contains(fixture.course));
    expect(overflowOccurrences, contains(fixture.overlappingPersonal));
    expect(
      overflowOccurrences!
          .singleWhere((item) => item == fixture.course)
          .location,
      '教学楼 A 101',
    );

    final earlyTile = find.byKey(
      ValueKey<CalendarReference>(fixture.earlyMorning.reference),
    );
    expect(earlyTile, findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('calendar-task-compact-2026-10-15')),
    );
    expect(overflowTasks, hasLength(2));
    expect(overflowTasks, contains(fixture.dueToday));
    expect(overflowTasks, contains(fixture.overdue));

    await tester.tap(
      find.byKey(
        ValueKey(
          'calendar-task-2026-10-16-${fixture.singleTask.reference.localId}',
        ),
      ),
    );
    expect(selectedTask, same(fixture.singleTask));
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop week keeps its wider columns and avoids overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final fixture = _fixture();
    await _pumpWeek(tester, fixture, width: 1280, textScale: 1);

    final viewport = find.byKey(
      const ValueKey('calendar-week-horizontal-scroll'),
    );
    final horizontalScrollable = find
        .descendant(of: viewport, matching: find.byType(Scrollable))
        .first;
    expect(
      tester
          .state<ScrollableState>(horizontalScrollable)
          .position
          .maxScrollExtent,
      0,
    );
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey('calendar-week-heading-2026-10-12')),
          )
          .width,
      greaterThan(100),
    );
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpWeek(
  WidgetTester tester,
  _Fixture fixture, {
  required double width,
  required double textScale,
  ValueChanged<CalendarOccurrence>? onSelect,
  void Function(String heading, List<CalendarOccurrence> occurrences)?
  onOverflow,
  ValueChanged<TaskRecord>? onSelectTask,
  void Function(DateTime day, List<TaskRecord> tasks)? onTaskOverflow,
}) async {
  tester.view.physicalSize = Size(width, 700);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 700),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: CalendarWeekView(
            window: fixture.window,
            today: DateTime.utc(2026, 10, 14),
            tasks: fixture.tasks,
            nowUtc: DateTime.utc(2026, 10, 15, 1),
            onSelect: onSelect ?? (_) {},
            onOverflow: onOverflow ?? (_, _) {},
            onSelectTask: onSelectTask ?? (_) {},
            onOpenUnscheduledTasks: () {},
            onTaskOverflow: onTaskOverflow ?? (_, _) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

_Fixture _fixture() {
  final allDay = _occurrence(
    id: 1,
    kind: CalendarKind.personal,
    title: '全天个人安排',
    startsAtUtc: DateTime.utc(2026, 10, 11, 16),
    endsAtUtc: DateTime.utc(2026, 10, 12, 16),
    allDay: true,
  );
  final secondAllDay = _occurrence(
    id: 2,
    kind: CalendarKind.young,
    title: '第二条全天安排',
    startsAtUtc: DateTime.utc(2026, 10, 11, 16),
    endsAtUtc: DateTime.utc(2026, 10, 12, 16),
    allDay: true,
  );
  final earlyMorning = _occurrence(
    id: 3,
    kind: CalendarKind.personal,
    title: '凌晨复习',
    startsAtUtc: DateTime.utc(2026, 10, 12, 18),
    endsAtUtc: DateTime.utc(2026, 10, 12, 18, 30),
  );
  final course = _occurrence(
    id: 4,
    kind: CalendarKind.course,
    title: '同名课程',
    startsAtUtc: DateTime.utc(2026, 10, 14, 1),
    endsAtUtc: DateTime.utc(2026, 10, 14, 2),
    location: '教学楼 A 101',
  );
  final overlappingPersonal = _occurrence(
    id: 5,
    kind: CalendarKind.personal,
    title: '个人复习安排',
    startsAtUtc: DateTime.utc(2026, 10, 14, 1),
    endsAtUtc: DateTime.utc(2026, 10, 14, 2),
    location: '图书馆',
  );
  final segments = [
    _segment(allDay, DateTime.utc(2026, 10, 12), 0, 1440),
    _segment(secondAllDay, DateTime.utc(2026, 10, 12), 0, 1440),
    _segment(earlyMorning, DateTime.utc(2026, 10, 13), 120, 150),
    _segment(course, DateTime.utc(2026, 10, 14), 540, 600),
    _segment(overlappingPersonal, DateTime.utc(2026, 10, 14), 540, 600),
  ];
  final tasks = [
    _task(1, '今天要交的任务', DateTime.utc(2026, 10, 15, 3)),
    _task(2, '已经逾期的任务', DateTime.utc(2026, 10, 14, 17)),
    _task(3, '周五的单项任务', DateTime.utc(2026, 10, 16, 9)),
  ];
  final window = CalendarWindow(
    context: _context,
    revision: 1,
    query: CalendarQuery(
      firstDay: DateTime.utc(2026, 10, 12),
      endDayExclusive: DateTime.utc(2026, 10, 19),
    ),
    items: [allDay, secondAllDay, earlyMorning, course, overlappingPersonal],
    segments: segments,
    conflicts: [CalendarConflict(course, overlappingPersonal)],
    matched: 5,
    truncated: false,
    conflictsTruncated: false,
  );
  return _Fixture(
    window: window,
    allDay: allDay,
    secondAllDay: secondAllDay,
    earlyMorning: earlyMorning,
    course: course,
    overlappingPersonal: overlappingPersonal,
    tasks: tasks,
    dueToday: tasks[0],
    overdue: tasks[1],
    singleTask: tasks[2],
  );
}

CalendarOccurrence _occurrence({
  required int id,
  required CalendarKind kind,
  required String title,
  required DateTime startsAtUtc,
  required DateTime endsAtUtc,
  String location = '',
  bool allDay = false,
}) => CalendarOccurrence(
  reference: CalendarReference(_context, CalendarIdentity(kind, id), 1),
  title: title,
  startsAtUtc: startsAtUtc,
  endsAtUtc: endsAtUtc,
  location: location,
  allDay: allDay,
);

CalendarDaySegment _segment(
  CalendarOccurrence occurrence,
  DateTime day,
  double startMinute,
  double endMinute,
) => CalendarDaySegment(
  occurrence: occurrence,
  day: day,
  startMinute: startMinute,
  endMinute: endMinute,
  continuesBefore: false,
  continuesAfter: false,
);

TaskRecord _task(int id, String title, DateTime deadline) => TaskRecord(
  reference: TaskReference(_context, id, 1),
  draft: TaskDraft(title: title, deadlineAtUtc: deadline),
  status: TaskStatus.active,
  createdAtUtc: DateTime.utc(2026, 10, 1),
  updatedAtUtc: DateTime.utc(2026, 10, 12),
  blockCount: 0,
);

String _dayKey(DateTime day) =>
    '${day.year}-${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

String _compactDate(DateTime day) =>
    '${day.month.toString().padLeft(2, '0')}/${day.day.toString().padLeft(2, '0')}';

const _context = CalendarContext(
  owner: 'portrait-test',
  resetEpoch: 1,
  agendaEpoch: 1,
);

final class _Fixture {
  const _Fixture({
    required this.window,
    required this.allDay,
    required this.secondAllDay,
    required this.earlyMorning,
    required this.course,
    required this.overlappingPersonal,
    required this.tasks,
    required this.dueToday,
    required this.overdue,
    required this.singleTask,
  });

  final CalendarWindow window;
  final CalendarOccurrence allDay;
  final CalendarOccurrence secondAllDay;
  final CalendarOccurrence earlyMorning;
  final CalendarOccurrence course;
  final CalendarOccurrence overlappingPersonal;
  final List<TaskRecord> tasks;
  final TaskRecord dueToday;
  final TaskRecord overdue;
  final TaskRecord singleTask;
}
