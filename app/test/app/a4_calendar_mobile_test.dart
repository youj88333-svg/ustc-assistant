import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/calendar_task_band.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';

const _context = CalendarContext(
  owner: 'synthetic',
  resetEpoch: 0,
  agendaEpoch: 0,
);
final _day = DateTime.utc(2026, 10, 12);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('deadline band keeps all phone actions at least 48dp tall', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final dueToday = _task(1, '今天到期', deadline: DateTime.utc(2026, 10, 12, 3));
    final secondToday = _task(
      2,
      '同日第二项',
      deadline: DateTime.utc(2026, 10, 12, 4),
    );
    final overdue = _task(
      3,
      '已过期',
      deadline: DateTime.utc(2026, 10, 12, 1, 59),
    );
    final unscheduled = _task(4, '待安排');
    TaskRecord? selectedTask;
    var openedUnscheduled = false;
    List<TaskRecord>? overflow;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 218,
              height: 49,
              child: CalendarTaskBand(
                days: [_day],
                tasks: [dueToday, secondToday, overdue, unscheduled],
                nowUtc: DateTime.utc(2026, 10, 12, 2),
                height: 49,
                gutterWidth: 62,
                onSelectTask: (task) => selectedTask = task,
                onOpenUnscheduledTasks: () => openedUnscheduled = true,
                onOverflow: (_, tasks) => overflow = tasks,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final key in const [
      'calendar-task-unscheduled',
      'calendar-task-2026-10-12-3',
      'calendar-task-overflow-2026-10-12',
    ]) {
      final finder = find.byKey(ValueKey(key));
      expect(finder, findsOneWidget, reason: key);
      final size = tester.getSize(finder);
      expect(size.height, greaterThanOrEqualTo(48), reason: key);
    }
    expect(
      find.byKey(const ValueKey('calendar-task-warning-3')),
      findsOneWidget,
      reason: 'the visible overdue deadline keeps its warning indicator',
    );
    await tester.tap(find.byKey(const ValueKey('calendar-task-unscheduled')));
    expect(openedUnscheduled, isTrue);
    await tester.tap(find.byKey(const ValueKey('calendar-task-2026-10-12-3')));
    expect(selectedTask, same(overdue));
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey('calendar-task-overflow-2026-10-12')),
          )
          .width,
      greaterThanOrEqualTo(48),
    );

    await tester.tap(
      find.byKey(const ValueKey('calendar-task-overflow-2026-10-12')),
    );
    expect(overflow, hasLength(3));
    expect(overflow, contains(overdue));
    expect(tester.takeException(), isNull);
  });
}

TaskRecord _task(int id, String title, {DateTime? deadline}) => TaskRecord(
  reference: TaskReference(_context, id, 1),
  draft: TaskDraft(title: title, deadlineAtUtc: deadline),
  status: TaskStatus.active,
  createdAtUtc: DateTime.utc(2026, 10, 1),
  updatedAtUtc: DateTime.utc(2026, 10, 12),
  blockCount: 0,
);
