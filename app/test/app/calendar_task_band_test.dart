import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/calendar_task_band.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';

const _context = CalendarContext(
  owner: 'synthetic',
  resetEpoch: 0,
  agendaEpoch: 0,
);
final _today = DateTime.utc(2026, 10, 12);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('UTC deadlines use the Beijing calendar day at midnight boundary', () {
    final midnightBeijing = _task(
      1,
      '零点截止',
      deadline: DateTime.utc(2026, 10, 11, 16),
    );
    final beforeMidnight = projectCalendarTasks(
      tasks: [midnightBeijing],
      days: [_today],
      nowUtc: DateTime.utc(2026, 10, 11, 15, 59, 59),
    );
    expect(beforeMidnight.byDay[_today], [midnightBeijing]);
    expect(
      calendarTaskDeadlineWarning(
        midnightBeijing,
        DateTime.utc(2026, 10, 11, 15, 59, 59),
      ),
      CalendarTaskDeadlineWarning.none,
    );
    expect(
      calendarTaskDeadlineWarning(
        midnightBeijing,
        DateTime.utc(2026, 10, 11, 16),
      ),
      CalendarTaskDeadlineWarning.overdue,
    );
  });

  test(
    'due today, expired, completed, cancelled, and future warnings differ',
    () {
      final now = DateTime.utc(2026, 10, 12, 2); // Beijing 10:00.
      final dueLaterToday = _task(
        2,
        '今天稍后截止',
        deadline: DateTime.utc(2026, 10, 12, 3),
      );
      final expired = _task(
        3,
        '刚刚过期',
        deadline: DateTime.utc(2026, 10, 12, 1, 59, 59),
      );
      final completed = _task(
        4,
        '已经完成',
        status: TaskStatus.completed,
        deadline: DateTime.utc(2026, 10, 11, 3),
      );
      final cancelled = _task(
        5,
        '已经取消',
        status: TaskStatus.cancelled,
        deadline: DateTime.utc(2026, 10, 11, 3),
      );
      final tomorrow = _task(
        6,
        '明天截止',
        deadline: DateTime.utc(2026, 10, 13, 3),
      );

      expect(
        calendarTaskDeadlineWarning(dueLaterToday, now),
        CalendarTaskDeadlineWarning.dueToday,
      );
      expect(
        calendarTaskDeadlineWarning(expired, now),
        CalendarTaskDeadlineWarning.overdue,
      );
      expect(
        calendarTaskDeadlineWarning(completed, now),
        CalendarTaskDeadlineWarning.none,
      );
      expect(
        calendarTaskDeadlineWarning(cancelled, now),
        CalendarTaskDeadlineWarning.none,
      );
      expect(
        calendarTaskDeadlineWarning(tomorrow, now),
        CalendarTaskDeadlineWarning.none,
      );
    },
  );

  test(
    'overdue tasks move to today, keep actual deadline, and stay out of other weeks',
    () {
      final overdue = _task(7, '跨日逾期', deadline: DateTime.utc(2026, 10, 11, 4));
      final noDeadline = _task(8, '待安排');
      final nextWeek = _task(
        9,
        '下周任务',
        deadline: DateTime.utc(2026, 10, 19, 16),
      );
      final projection = projectCalendarTasks(
        tasks: [overdue, noDeadline, nextWeek],
        days: List.generate(7, (index) => DateTime.utc(2026, 10, 12 + index)),
        nowUtc: DateTime.utc(2026, 10, 12, 2),
      );

      expect(projection.byDay[_today], [overdue]);
      expect(overdue.draft.deadlineAtUtc, DateTime.utc(2026, 10, 11, 4));
      expect(projection.unscheduled, [noDeadline]);
      expect(
        projection.byDay.values.expand((items) => items),
        isNot(contains(nextWeek)),
      );
      expect(projection.hasVisibleTasks, isTrue);
    },
  );

  testWidgets(
    'dense band expands every task and keeps a compact unscheduled entry',
    (tester) async {
      final tasks = [
        _task(10, '第一项', deadline: DateTime.utc(2026, 10, 12, 3)),
        _task(11, '第二项', deadline: DateTime.utc(2026, 10, 12, 4)),
        _task(12, '第三项', deadline: DateTime.utc(2026, 10, 12, 5)),
        _task(13, '待安排事项'),
      ];
      List<TaskRecord>? overflow;
      final selected = <TaskRecord>[];
      tester.view.physicalSize = const Size(320, 560);
      tester.view.devicePixelRatio = 1;
      await tester.pump();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 68,
              child: CalendarTaskBand(
                days: [_today],
                tasks: tasks,
                nowUtc: DateTime.utc(2026, 10, 12, 2),
                height: 68,
                gutterWidth: 62,
                onSelectTask: selected.add,
                onOpenUnscheduledTasks: () {},
                onOverflow: (_, items) => overflow = items,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('待安排'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('calendar-task-unscheduled')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('calendar-task-overflow-2026-10-12')),
      );
      expect(overflow, hasLength(3));
      await tester.tap(
        find.byKey(const ValueKey('calendar-task-2026-10-12-10')),
      );
      expect(selected.single.reference.localId, 10);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );

  testWidgets('large text remains contained in a narrow task band', (
    tester,
  ) async {
    final tasks = [
      _task(
        20,
        '非常长的合成任务名称用于检查窄屏大字布局',
        deadline: DateTime.utc(2026, 10, 12, 3),
      ),
      _task(21, '无截止任务'),
    ];
    tester.view.physicalSize = const Size(320, 560);
    tester.view.devicePixelRatio = 1;
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: SizedBox(
              width: 320,
              height: 72,
              child: CalendarTaskBand(
                days: [_today],
                tasks: tasks,
                nowUtc: DateTime.utc(2026, 10, 12, 2),
                height: 72,
                gutterWidth: 62,
                onSelectTask: (_) {},
                onOpenUnscheduledTasks: () {},
                onOverflow: (_, _) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

TaskRecord _task(
  int id,
  String title, {
  DateTime? deadline,
  TaskStatus status = TaskStatus.active,
}) => TaskRecord(
  reference: TaskReference(_context, id, 1),
  draft: TaskDraft(title: title, deadlineAtUtc: deadline),
  status: status,
  createdAtUtc: DateTime.utc(2026, 10, 1),
  updatedAtUtc: DateTime.utc(2026, 10, 12),
  blockCount: 0,
);
