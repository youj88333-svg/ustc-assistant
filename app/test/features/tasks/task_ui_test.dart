import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/features/schedule/domain/schedule_projection.dart';
import 'package:ustc_assistant_app/features/schedule/presentation/week_timetable.dart';
import 'package:ustc_assistant_app/features/tasks/application/plan_block_lifecycle_port.dart';
import 'package:ustc_assistant_app/features/tasks/domain/plan_block.dart';
import 'package:ustc_assistant_app/features/tasks/domain/task.dart';
import 'package:ustc_assistant_app/features/tasks/domain/task_projection.dart';
import 'package:ustc_assistant_app/features/tasks/presentation/pending_review_list.dart';
import 'package:ustc_assistant_app/features/tasks/presentation/task_center_page.dart';
import 'package:ustc_assistant_app/features/tasks/presentation/task_detail_page.dart';
import 'package:ustc_assistant_app/features/tasks/presentation/task_form.dart';

TaskItem task(
  String id, {
  DateTime? deadline,
  TaskState state = TaskState.active,
  int? deletedAt,
}) => TaskItem(
  id: id,
  title: id,
  state: state,
  importance: TaskImportance.normal,
  deadlineAt: deadline,
  completedAt: state == TaskState.completed ? 2 : null,
  cancelledAt: state == TaskState.cancelled ? 2 : null,
  createdAt: 1,
  updatedAt: 1,
  deletedAt: deletedAt,
);

Widget scheduleWithTasks(List<TaskItem> tasks, {bool hideCompleted = false}) =>
    MaterialApp(
      home: Scaffold(
        body: WeekTimetable(
          projection: buildWeek(
            ScheduleQuery(
              selectedDate: DateTime(2026, 7, 27),
              events: const [],
            ),
          ),
          tasks: tasks,
          now: DateTime(2026, 7, 29, 10),
          hideCompletedTasks: hideCompleted,
          onEventSelected: (_) {},
        ),
      ),
    );

void main() {
  testWidgets('undated band hides when empty', (tester) async {
    await tester.pumpWidget(scheduleWithTasks([]));
    expect(find.text('未定截止'), findsNothing);
    expect(find.text('截止事项'), findsOneWidget);
  });

  testWidgets('due today and overdue use distinct warning semantics', (
    tester,
  ) async {
    await tester.pumpWidget(
      scheduleWithTasks([
        task('due', deadline: DateTime(2026, 7, 29, 18)),
        task('overdue', deadline: DateTime(2026, 7, 28, 18)),
      ]),
    );
    expect(find.bySemanticsLabel('今天截止'), findsOneWidget);
    expect(find.bySemanticsLabel('已逾期'), findsOneWidget);
  });

  testWidgets('undated and planned tasks remain visible with dark labels', (
    tester,
  ) async {
    await tester.pumpWidget(scheduleWithTasks([task('planned')]));
    expect(find.byKey(const Key('undated-task-band')), findsOneWidget);
    expect(find.text('planned'), findsOneWidget);
    final label = tester.widget<Text>(find.text('未定截止'));
    expect(label.style?.color, const Color(0xFF202124));
  });

  testWidgets('completed deadline history obeys hide-completed filter', (
    tester,
  ) async {
    final completed = task(
      'done',
      deadline: DateTime(2026, 7, 30, 18),
      state: TaskState.completed,
    );
    await tester.pumpWidget(scheduleWithTasks([completed]));
    expect(find.text('done'), findsOneWidget);
    await tester.pumpWidget(
      scheduleWithTasks([completed], hideCompleted: true),
    );
    expect(find.text('done'), findsNothing);
  });

  testWidgets('task form requires only a title and validates estimate', (
    tester,
  ) async {
    TaskFormSubmission? submitted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskForm(onSubmit: (value) async => submitted = value),
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('task-estimate')), '0');
    await tester.tap(find.byKey(const Key('save-task')));
    await tester.pump();
    expect(find.text('请输入标题'), findsOneWidget);
    expect(find.text('预计分钟必须大于 0'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('task-title')), 'Write report');
    await tester.enterText(find.byKey(const Key('task-estimate')), '45');
    await tester.tap(find.byKey(const Key('save-task')));
    await tester.pump();
    expect(submitted?.title, 'Write report');
    expect(submitted?.estimatedMinutes, 45);
    expect(submitted?.deadlineAt, isNull);
  });

  testWidgets('pending review exposes done skipped and reschedule actions', (
    tester,
  ) async {
    final actions = <String>[];
    final block = PlanBlockItem(
      id: 'p',
      taskId: 't',
      title: 'Review',
      startAt: DateTime(2026, 7, 27, 9),
      endAt: DateTime(2026, 7, 27, 10),
      status: PlanBlockStatus.accepted,
      locked: false,
      createdAt: 1,
      updatedAt: 1,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PendingReviewList(
            blocks: [block],
            onDone: (_) => actions.add('done'),
            onSkipped: (_) => actions.add('skipped'),
            onReschedule: (_) => actions.add('reschedule'),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('复核计划时段'));
    await tester.pumpAndSettle();
    expect(find.text('已执行'), findsOneWidget);
    expect(find.text('已跳过'), findsOneWidget);
    expect(find.text('重新安排'), findsOneWidget);
    await tester.tap(find.text('已执行'));
    await tester.pumpAndSettle();
    expect(actions, ['done']);
  });

  testWidgets('task completion uses future-block summary then confirmation', (
    tester,
  ) async {
    bool? cancelFuture;
    final item = task('Two-stage');
    await tester.pumpWidget(
      MaterialApp(
        home: TaskDetailPage(
          task: item,
          projection: projectTask(item, DateTime(2026, 7, 27)),
          planImpact: const PlanBlockImpact(
            futureAcceptedCount: 2,
            futureAcceptedMinutes: 90,
          ),
          onComplete: (value) async => cancelFuture = value,
          onSchedule: () {},
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('complete-task')));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 个未来计划'), findsOneWidget);
    await tester.tap(find.text('全部取消'));
    await tester.pumpAndSettle();
    expect(find.text('确认完成任务？'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-task-complete')));
    await tester.pumpAndSettle();
    expect(cancelFuture, isTrue);
  });

  testWidgets('task center exposes filters undo and deleted restore', (
    tester,
  ) async {
    var undo = 0;
    TaskItem? restored;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskCenterPage(
            tasks: [
              task('active'),
              task('blocked', state: TaskState.blocked),
              task('deleted', deletedAt: 3),
            ],
            undoAvailable: true,
            onUndo: () => undo++,
            onRestore: (value) => restored = value,
          ),
        ),
      ),
    );
    expect(find.text('active'), findsOneWidget);
    await tester.tap(find.byKey(const Key('task-undo')));
    expect(undo, 1);
    await tester.tap(find.byTooltip('恢复任务'));
    expect(restored?.id, 'deleted');
    await tester.tap(find.text('受阻'));
    await tester.pumpAndSettle();
    expect(find.text('blocked'), findsOneWidget);
    expect(find.text('active'), findsNothing);
  });
}
