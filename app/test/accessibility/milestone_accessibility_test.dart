import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/features/schedule/domain/schedule_projection.dart';
import 'package:ustc_assistant_app/features/schedule/presentation/week_timetable.dart';
import 'package:ustc_assistant_app/features/tasks/domain/task.dart';

void main() {
  testWidgets('deadline warning exposes text semantics in addition to color', (
    tester,
  ) async {
    final now = DateTime(2026, 7, 27, 10);
    final task = TaskItem(
      id: 'due',
      title: 'Due task',
      state: TaskState.active,
      importance: TaskImportance.normal,
      deadlineAt: DateTime(2026, 7, 27, 18),
      tags: const [],
      createdAt: now.millisecondsSinceEpoch,
      updatedAt: now.millisecondsSinceEpoch,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WeekTimetable(
            projection: buildWeek(
              ScheduleQuery(selectedDate: now, events: const []),
            ),
            tasks: [task],
            now: now,
            onEventSelected: (_) {},
          ),
        ),
      ),
    );
    expect(find.bySemanticsLabel('今天截止'), findsOneWidget);
    expect(find.text('Due task'), findsOneWidget);
  });

  testWidgets('keyboard focus reaches icon controls', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FocusTraversalGroup(
            child: Row(
              children: [
                IconButton(
                  tooltip: '同步',
                  onPressed: () {},
                  icon: const Icon(Icons.sync),
                ),
                IconButton(
                  tooltip: '导入',
                  onPressed: () {},
                  icon: const Icon(Icons.file_open),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, isNotNull);
  });
}
