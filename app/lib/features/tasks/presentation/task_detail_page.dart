import 'package:flutter/material.dart';

import '../application/plan_block_lifecycle_port.dart';
import '../domain/plan_block.dart';
import '../domain/task.dart';
import '../domain/task_projection.dart';

class TaskDetailPage extends StatelessWidget {
  const TaskDetailPage({
    required this.task,
    required this.projection,
    required this.planImpact,
    required this.onComplete,
    required this.onSchedule,
    this.blocks = const [],
    this.deletedBlocks = const [],
    this.undoAvailable = false,
    this.onUndo,
    this.onCancelTask,
    this.onReopenTask,
    this.onToggleBlocked,
    this.onEditBlock,
    this.onCancelBlock,
    this.onMarkBlockDone,
    this.onMarkBlockSkipped,
    this.onRescheduleBlock,
    this.onRestoreBlock,
    this.now,
    super.key,
  });

  final TaskItem task;
  final TaskProjection projection;
  final PlanBlockImpact planImpact;
  final List<PlanBlockItem> blocks;

  /// Soft-deleted plan blocks for this task, surfaced in a collapsed recovery
  /// section. Each carries a single-target restore control. Restoring never
  /// cascades — the parent Task and any reschedule chain are untouched.
  final List<PlanBlockItem> deletedBlocks;
  final Future<void> Function(bool cancelFutureBlocks) onComplete;
  final VoidCallback onSchedule;
  final bool undoAvailable;
  final Future<void> Function()? onUndo;
  final Future<void> Function()? onCancelTask;
  final Future<void> Function()? onReopenTask;
  final Future<void> Function()? onToggleBlocked;
  final ValueChanged<PlanBlockItem>? onEditBlock;
  final Future<void> Function(PlanBlockItem)? onCancelBlock;
  final Future<void> Function(PlanBlockItem)? onMarkBlockDone;
  final Future<void> Function(PlanBlockItem)? onMarkBlockSkipped;
  final ValueChanged<PlanBlockItem>? onRescheduleBlock;
  final Future<void> Function(PlanBlockItem)? onRestoreBlock;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final current = now ?? DateTime.now();
    return Scaffold(
      appBar: AppBar(
        title: Text(task.title),
        actions: [
          IconButton(
            key: const Key('task-detail-undo'),
            tooltip: '撤回上一步',
            onPressed: undoAvailable && onUndo != null
                ? () => onUndo!.call()
                : null,
            icon: const Icon(Icons.undo),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(task.description ?? '无描述'),
          const SizedBox(height: 12),
          Text('状态：${_stateLabel(task.state)}'),
          Text('规划：${_planningLabel(projection.planning)}'),
          Text('截止风险：${_deadlineLabel(projection.deadline)}'),
          if (task.deadlineAt != null)
            Text('截止：${_dateTime(task.deadlineAt!)}（北京时间）'),
          Text('待确认：${_confirmationLabel(projection.confirmation)}'),
          Text(
            '未来计划：${planImpact.futureAcceptedCount} 个，'
            '${planImpact.futureAcceptedMinutes} 分钟',
          ),
          if (task.blockedReason != null) Text('受阻原因：${task.blockedReason}'),
          if (task.userNotes != null) Text('备注：${task.userNotes}'),
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const Key('schedule-task'),
            onPressed: task.isTerminal ? null : onSchedule,
            icon: const Icon(Icons.add_alarm),
            label: const Text('安排时间'),
          ),
          const SizedBox(height: 8),
          if (!task.isTerminal)
            OutlinedButton.icon(
              key: const Key('complete-task'),
              onPressed: () => _confirmComplete(context),
              icon: const Icon(Icons.task_alt),
              label: const Text('完成任务'),
            ),
          if (!task.isTerminal && onCancelTask != null)
            OutlinedButton.icon(
              key: const Key('cancel-task'),
              onPressed: () => onCancelTask!.call(),
              icon: const Icon(Icons.cancel_outlined),
              label: const Text('取消任务'),
            ),
          if (task.isTerminal && onReopenTask != null)
            OutlinedButton.icon(
              key: const Key('reopen-task'),
              onPressed: () => onReopenTask!.call(),
              icon: const Icon(Icons.restart_alt),
              label: const Text('重新打开'),
            ),
          if (!task.isTerminal && onToggleBlocked != null)
            OutlinedButton.icon(
              key: const Key('toggle-task-blocked'),
              onPressed: () => onToggleBlocked!.call(),
              icon: Icon(
                task.state == TaskState.blocked
                    ? Icons.lock_open_outlined
                    : Icons.block,
              ),
              label: Text(task.state == TaskState.blocked ? '解除受阻' : '标记受阻'),
            ),
          const Divider(height: 32),
          Text('计划时段', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (blocks.isEmpty) const Text('尚未安排计划时段'),
          for (final block in blocks)
            _PlanBlockRow(
              block: block,
              now: current,
              onEdit: onEditBlock,
              onCancel: onCancelBlock,
              onDone: onMarkBlockDone,
              onSkipped: onMarkBlockSkipped,
              onReschedule: onRescheduleBlock,
            ),
          if (deletedBlocks.isNotEmpty && onRestoreBlock != null) ...[
            const SizedBox(height: 16),
            _DeletedBlocksSection(
              blocks: deletedBlocks,
              onRestore: onRestoreBlock!,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmComplete(BuildContext context) async {
    var cancelFuture = false;
    if (planImpact.futureAcceptedCount > 0) {
      final choice = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('处理未来计划时段'),
          content: Text(
            '还有 ${planImpact.futureAcceptedCount} 个未来计划，'
            '共 ${planImpact.futureAcceptedMinutes} 分钟。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('保留'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('全部取消'),
            ),
          ],
        ),
      );
      if (choice == null || !context.mounted) return;
      cancelFuture = choice;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认完成任务？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回'),
          ),
          FilledButton(
            key: const Key('confirm-task-complete'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认完成'),
          ),
        ],
      ),
    );
    if (confirmed == true) await onComplete(cancelFuture);
  }

  String _dateTime(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')} '
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';

  String _stateLabel(TaskState value) => switch (value) {
    TaskState.active => '进行中',
    TaskState.blocked => '受阻',
    TaskState.completed => '已完成',
    TaskState.cancelled => '已取消',
  };

  String _planningLabel(PlanningState value) =>
      value == PlanningState.planned ? '已规划' : '未规划';

  String _deadlineLabel(DeadlineState value) => switch (value) {
    DeadlineState.notApplicable => '不适用',
    DeadlineState.noDeadline => '未定截止',
    DeadlineState.upcoming => '即将截止',
    DeadlineState.dueToday => '今天截止',
    DeadlineState.overdue => '已逾期',
  };

  String _confirmationLabel(ConfirmationState value) =>
      value == ConfirmationState.awaitingPlanBlockReview ? '有待复核时段' : '无';
}

class _PlanBlockRow extends StatelessWidget {
  const _PlanBlockRow({
    required this.block,
    required this.now,
    required this.onEdit,
    required this.onCancel,
    required this.onDone,
    required this.onSkipped,
    required this.onReschedule,
  });

  final PlanBlockItem block;
  final DateTime now;
  final ValueChanged<PlanBlockItem>? onEdit;
  final Future<void> Function(PlanBlockItem)? onCancel;
  final Future<void> Function(PlanBlockItem)? onDone;
  final Future<void> Function(PlanBlockItem)? onSkipped;
  final ValueChanged<PlanBlockItem>? onReschedule;

  @override
  Widget build(BuildContext context) {
    final awaitingReview =
        block.status == PlanBlockStatus.accepted && !block.endAt.isAfter(now);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(block.title ?? '计划时段'),
          Text(
            '${_dateTime(block.startAt)} - ${_dateTime(block.endAt)}'
            '（北京时间）',
          ),
          Text('状态：${block.status.name}'),
          Wrap(
            spacing: 8,
            children: [
              if (block.status == PlanBlockStatus.accepted &&
                  !awaitingReview &&
                  onEdit != null)
                TextButton.icon(
                  key: Key('edit-plan-block-${block.id}'),
                  onPressed: () => onEdit!(block),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('编辑'),
                ),
              if (block.status == PlanBlockStatus.accepted && onCancel != null)
                TextButton.icon(
                  key: Key('cancel-plan-block-${block.id}'),
                  onPressed: () => onCancel!(block),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('删除'),
                ),
              if (awaitingReview && onDone != null)
                TextButton(
                  key: Key('done-plan-block-${block.id}'),
                  onPressed: () => onDone!(block),
                  child: const Text('已执行'),
                ),
              if (awaitingReview && onSkipped != null)
                TextButton(
                  key: Key('skip-plan-block-${block.id}'),
                  onPressed: () => onSkipped!(block),
                  child: const Text('已跳过'),
                ),
              if (awaitingReview && onReschedule != null)
                TextButton(
                  key: Key('reschedule-plan-block-${block.id}'),
                  onPressed: () => onReschedule!(block),
                  child: const Text('重新安排'),
                ),
            ],
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }

  String _dateTime(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')} '
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';
}

/// A collapsed recovery section for soft-deleted plan blocks. Collapsed by
/// default (the deleted blocks are not listed until expanded); each row offers
/// a single-target restore button. Restoring returns the block to its original
/// pre-delete status — the parent Task and any reschedule chain are untouched.
class _DeletedBlocksSection extends StatefulWidget {
  const _DeletedBlocksSection({
    required this.blocks,
    required this.onRestore,
  });

  final List<PlanBlockItem> blocks;
  final Future<void> Function(PlanBlockItem) onRestore;

  @override
  State<_DeletedBlocksSection> createState() => _DeletedBlocksSectionState();
}

class _DeletedBlocksSectionState extends State<_DeletedBlocksSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: const Key('deleted-plan-blocks-header'),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  '已删除计划时段（${widget.blocks.length}）',
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          for (final block in widget.blocks)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          block.title ?? '计划时段',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        Text(
                          '原状态：${block.status.name}',
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: Key('restore-plan-block-${block.id}'),
                    tooltip: '恢复',
                    icon: const Icon(Icons.restore),
                    onPressed: () => widget.onRestore(block),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}
