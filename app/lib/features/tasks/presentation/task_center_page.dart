import 'package:flutter/material.dart';

import '../domain/plan_block.dart';
import '../domain/task.dart';
import 'pending_review_list.dart';
import 'task_filters.dart';

class TaskCenterPage extends StatefulWidget {
  const TaskCenterPage({
    this.tasks = const [],
    this.pendingReview = const [],
    this.undoAvailable = false,
    this.onUndo,
    this.onTaskSelected,
    this.onRestore,
    this.onReviewDone,
    this.onReviewSkipped,
    this.onReviewReschedule,
    super.key,
  });

  final List<TaskItem> tasks;
  final List<PlanBlockItem> pendingReview;
  final bool undoAvailable;
  final VoidCallback? onUndo;
  final ValueChanged<TaskItem>? onTaskSelected;
  final ValueChanged<TaskItem>? onRestore;
  final ValueChanged<PlanBlockItem>? onReviewDone;
  final ValueChanged<PlanBlockItem>? onReviewSkipped;
  final ValueChanged<PlanBlockItem>? onReviewReschedule;

  @override
  State<TaskCenterPage> createState() => _TaskCenterPageState();
}

class _TaskCenterPageState extends State<TaskCenterPage> {
  TaskFilter filter = TaskFilter.active;

  @override
  Widget build(BuildContext context) {
    final visible = filterTasks(widget.tasks, filter);
    final deleted = widget.tasks.where((task) => task.deletedAt != null);
    return Column(
      children: [
        PendingReviewList(
          blocks: widget.pendingReview,
          onDone: widget.onReviewDone ?? (_) {},
          onSkipped: widget.onReviewSkipped ?? (_) {},
          onReschedule: widget.onReviewReschedule ?? (_) {},
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<TaskFilter>(
                    segments: [
                      for (final value in TaskFilter.values)
                        ButtonSegment(value: value, label: Text(value.label)),
                    ],
                    selected: {filter},
                    onSelectionChanged: (value) {
                      setState(() => filter = value.single);
                    },
                  ),
                ),
              ),
              IconButton(
                key: const Key('task-undo'),
                tooltip: '撤回上一步',
                onPressed: widget.undoAvailable ? widget.onUndo : null,
                icon: const Icon(Icons.undo),
              ),
            ],
          ),
        ),
        Expanded(
          child: visible.isEmpty && deleted.isEmpty
              ? const Center(
                  child: Text('暂无任务', style: TextStyle(fontSize: 16)),
                )
              : ListView(
                  children: [
                    for (final task in visible)
                      ListTile(
                        key: Key('task-${task.id}'),
                        leading: Icon(_stateIcon(task.state)),
                        title: Text(task.title),
                        subtitle: task.deadlineAt == null
                            ? const Text('未定截止')
                            : Text('截止 ${task.deadlineAt}'),
                        onTap: () => widget.onTaskSelected?.call(task),
                      ),
                    if (deleted.isNotEmpty)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                        child: Text(
                          '最近删除',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    for (final task in deleted)
                      ListTile(
                        title: Text(task.title),
                        trailing: IconButton(
                          tooltip: '恢复任务',
                          onPressed: () => widget.onRestore?.call(task),
                          icon: const Icon(Icons.restore),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  IconData _stateIcon(TaskState state) => switch (state) {
    TaskState.active => Icons.radio_button_unchecked,
    TaskState.blocked => Icons.block,
    TaskState.completed => Icons.check_circle_outline,
    TaskState.cancelled => Icons.cancel_outlined,
  };
}
