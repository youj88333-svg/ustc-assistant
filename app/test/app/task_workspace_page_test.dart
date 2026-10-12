import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/task_workspace_contract.dart';
import 'package:ustc_assistant_m0/app/task_workspace_page.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('creates a complete task with no deadline', (tester) async {
    await _setSize(tester, const Size(1100, 820));
    final port = _FakeTaskWorkspacePort();
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('task-workspace-create')));
    await tester.pumpAndSettle();

    await _enter(tester, 'task-editor-title', '整理实验记录');
    await _enter(tester, 'task-editor-description', '核对测量数据和图表。');
    await _enter(tester, 'task-editor-note', '先确认单位。');
    await _enter(tester, 'task-editor-estimate', '95');
    await tester.tap(find.byKey(const ValueKey('task-editor-priority')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('高').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('task-editor-save')));
    await tester.pumpAndSettle();

    final intent = port.intents.single.intent as CreateTask;
    expect(intent.draft.title, '整理实验记录');
    expect(intent.draft.description, '核对测量数据和图表。');
    expect(intent.draft.note, '先确认单位。');
    expect(intent.draft.estimatedMinutes, 95);
    expect(intent.draft.priority, TaskPriority.high);
    expect(intent.draft.deadlineAtUtc, isNull);
    expect(port.intents.single.expectedContext, port.context);
    expect(tester.takeException(), isNull);
  });

  testWidgets('date-only deadline defaults to 23:59 Beijing time', (
    tester,
  ) async {
    await _setSize(tester, const Size(900, 760));
    final port = _FakeTaskWorkspacePort();
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('task-workspace-create')));
    await tester.pumpAndSettle();
    await _enter(tester, 'task-editor-title', '提交作业');
    await tester.tap(find.byKey(const ValueKey('task-editor-has-deadline')));
    await tester.pumpAndSettle();
    await _enter(tester, 'task-editor-deadline-day', '2026-10-13');
    await tester.tap(find.byKey(const ValueKey('task-editor-save')));
    await tester.pumpAndSettle();

    final intent = port.intents.single.intent as CreateTask;
    expect(intent.draft.deadlineAtUtc, DateTime.utc(2026, 10, 13, 15, 59));
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows independent block states and moves the original block', (
    tester,
  ) async {
    await _setSize(tester, const Size(1080, 860));
    final seed = _taskWithBlocks();
    final port = _FakeTaskWorkspacePort(
      tasks: [seed.task],
      blocks: seed.blocks,
    );
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('task-tile-7')));
    await tester.pumpAndSettle();

    expect(find.text('待执行'), findsOneWidget);
    expect(find.text('已执行'), findsOneWidget);
    expect(find.text('已到时间 · 待复核'), findsOneWidget);
    expect(find.text('计划在任务截止后'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('task-detail-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设为已完成'));
    await tester.pumpAndSettle();
    expect(port.intents.last.intent, isA<SetTaskStatus>());

    final original = seed.blocks.first.reference;
    await tester.tap(
      find.byKey(ValueKey('task-block-actions-${original.identity.localId}')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('移动或编辑'));
    await tester.pumpAndSettle();
    await _enter(tester, 'plan-block-start-day', '2026-10-14');
    await _enter(tester, 'plan-block-end-day', '2026-10-14');
    await tester.tap(find.byKey(const ValueKey('plan-block-editor-save')));
    await tester.pumpAndSettle();

    final update = port.intents.last.intent as UpdatePlanBlock;
    expect(update.target, original);
    expect(update.draft.startsAtUtc, DateTime.utc(2026, 10, 14, 2));
    expect(update.draft.endsAtUtc, DateTime.utc(2026, 10, 14, 3));
    expect(
      port.intents.where((write) => write.intent is SetPlanBlockStatus),
      isEmpty,
      reason: 'changing Task status leaves each block state independent',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirmed delete and undo failures stay distinct from success', (
    tester,
  ) async {
    await _setSize(tester, const Size(1000, 820));
    final seed = _taskWithBlocks();
    final port = _FakeTaskWorkspacePort(
      tasks: [seed.task],
      blocks: seed.blocks,
    );
    port.setUndo(CalendarUndoReference(port.context, 'undo-1'));
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('task-tile-7')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('task-detail-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除任务…'));
    await tester.pumpAndSettle();
    port.nextFailure = CalendarFailureCode.staleReference;
    await tester.tap(find.text('删除任务').last);
    await tester.pumpAndSettle();

    expect(port.intents.last.intent, isA<DeleteTask>());
    expect(find.text('任务已被其他修改更新，请重新读取后再操作。'), findsWidgets);
    expect(find.text('已保存。'), findsNothing);

    port.nextFailure = CalendarFailureCode.undoConflict;
    await tester.tap(find.byKey(const ValueKey('task-workspace-undo')));
    await tester.pumpAndSettle();
    final undo = port.intents.last.intent as UndoCalendarWrite;
    expect(undo.target.undoId, 'undo-1');
    expect(undo.target.context, port.context);
    expect(find.text('最近一次修改已无法安全撤销。'), findsWidgets);
    expect(find.text('private-action-label'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow layout and large text remain operable without overflow', (
    tester,
  ) async {
    await _setSize(tester, const Size(360, 620));
    final seed = _taskWithBlocks();
    final port = _FakeTaskWorkspacePort(
      tasks: [seed.task],
      blocks: seed.blocks,
    );
    addTearDown(port.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: TaskWorkspacePage(port: port),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('task-workspace-search')), findsOneWidget);
    expect(find.byKey(const ValueKey('task-workspace-create')), findsOneWidget);
    expect(find.byKey(const ValueKey('task-tile-7')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Widget _host(_FakeTaskWorkspacePort port) => MaterialApp(
  home: Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: TaskWorkspacePage(port: port),
      ),
    ),
  ),
);

Future<void> _setSize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _enter(WidgetTester tester, String key, String value) async {
  await tester.enterText(find.byKey(ValueKey(key)), value);
  await tester.pumpAndSettle();
}

({TaskRecord task, List<PlanBlockRecord> blocks}) _taskWithBlocks() {
  const context = CalendarContext(
    owner: 'synthetic-owner',
    resetEpoch: 1,
    agendaEpoch: 1,
  );
  const taskReference = TaskReference(context, 7, 12);
  final task = TaskRecord(
    reference: taskReference,
    draft: TaskDraft(
      title: '准备项目材料',
      description: '整理两份说明。',
      note: '先完成提纲。',
      deadlineAtUtc: DateTime.utc(2026, 10, 12, 15, 59),
      estimatedMinutes: 120,
      priority: TaskPriority.high,
    ),
    status: TaskStatus.active,
    createdAtUtc: DateTime.utc(2026, 10, 1),
    updatedAtUtc: DateTime.utc(2026, 10, 10),
    blockCount: 2,
  );
  final first = PlanBlockRecord(
    reference: const CalendarReference(
      context,
      CalendarIdentity(CalendarKind.planBlock, 80),
      12,
    ),
    task: taskReference,
    taskTitle: task.draft.title,
    taskStatus: task.status,
    draft: PlanBlockDraft(
      startsAtUtc: DateTime.utc(2026, 10, 11, 2),
      endsAtUtc: DateTime.utc(2026, 10, 11, 3),
      location: '图书馆',
      note: '完成提纲',
    ),
    status: PlanBlockStatus.planned,
  );
  final second = PlanBlockRecord(
    reference: const CalendarReference(
      context,
      CalendarIdentity(CalendarKind.planBlock, 81),
      12,
    ),
    task: taskReference,
    taskTitle: task.draft.title,
    taskStatus: task.status,
    draft: PlanBlockDraft(
      startsAtUtc: DateTime.utc(2026, 10, 13, 2),
      endsAtUtc: DateTime.utc(2026, 10, 13, 3),
    ),
    status: PlanBlockStatus.done,
  );
  return (task: task, blocks: [first, second]);
}

final class _FakeTaskWorkspacePort extends ChangeNotifier
    implements TaskWorkspacePort {
  _FakeTaskWorkspacePort({
    List<TaskRecord> tasks = const [],
    List<PlanBlockRecord> blocks = const [],
  }) : _tasks = List.of(tasks),
       _blocks = List.of(blocks) {
    _view = _buildView(const TaskQuery());
  }

  static const CalendarContext _context = CalendarContext(
    owner: 'synthetic-owner',
    resetEpoch: 1,
    agendaEpoch: 1,
  );
  final List<TaskRecord> _tasks;
  final List<PlanBlockRecord> _blocks;
  final List<({CalendarIntent intent, CalendarContext expectedContext})>
  intents = [];
  CalendarUndoView _undo = const CalendarUndoView();
  TaskWorkspaceView? _view;
  TaskReference? _selected;
  CalendarFailureCode? nextFailure;

  CalendarContext get context => _context;

  void setUndo(CalendarUndoReference reference) {
    _undo = CalendarUndoView(
      reference: reference,
      action: 'private-action-label',
    );
    _view = _buildView(_view!.query);
    notifyListeners();
  }

  @override
  TaskWorkspaceView get taskView => _view!;

  @override
  DateTime get today => DateTime.utc(2026, 10, 12);

  @override
  Future<void> loadTasks({TaskQuery? query}) async {
    _view = _buildView(query ?? taskView.query);
    notifyListeners();
  }

  @override
  Future<void> selectTask(TaskReference? reference) async {
    _selected = reference;
    _view = _buildView(taskView.query);
    notifyListeners();
  }

  @override
  Future<CalendarWriteReceipt> executeTask(
    CalendarIntent intent, {
    required CalendarContext expectedContext,
  }) async {
    intents.add((intent: intent, expectedContext: expectedContext));
    final failure = nextFailure;
    nextFailure = null;
    if (failure != null) throw CalendarFailure(failure);
    notifyListeners();
    return const CalendarWriteReceipt(
      operationId: 'synthetic-operation',
      revision: 3,
      replayed: false,
    );
  }

  TaskWorkspaceView _buildView(TaskQuery query) {
    final filtered = _tasks
        .where((task) {
          final keywordMatch =
              query.keyword.isEmpty ||
              task.draft.title.toLowerCase().contains(
                query.keyword.toLowerCase(),
              );
          final filterMatch = switch (query.filter) {
            TaskFilter.open =>
              task.status == TaskStatus.active ||
                  task.status == TaskStatus.blocked,
            TaskFilter.all => true,
            TaskFilter.active => task.status == TaskStatus.active,
            TaskFilter.blocked => task.status == TaskStatus.blocked,
            TaskFilter.completed => task.status == TaskStatus.completed,
            TaskFilter.cancelled => task.status == TaskStatus.cancelled,
          };
          return keywordMatch && filterMatch;
        })
        .toList(growable: false);
    TaskRecord? selectedTask;
    for (final task in _tasks) {
      if (task.reference.localId == _selected?.localId) {
        selectedTask = task;
        break;
      }
    }
    final selected = selectedTask;
    return TaskWorkspaceView(
      query: query,
      window: TaskWindow(
        context: _context,
        revision: 3,
        query: query,
        items: filtered.take(query.limit).toList(growable: false),
        matched: filtered.length,
        truncated: filtered.length > query.limit,
      ),
      detail: selected == null
          ? null
          : TaskDetail(
              task: selected,
              blocks: _blocks
                  .where(
                    (block) => block.task.localId == selected.reference.localId,
                  )
                  .toList(growable: false),
              nowUtc: DateTime.utc(2026, 10, 12, 4),
            ),
      undo: _undo,
    );
  }
}
