import 'package:flutter/material.dart';

import '../application/plan_block_lifecycle_port.dart';
import '../domain/task.dart';
import '../domain/task_projection.dart';

class TaskDetailPage extends StatelessWidget {
  const TaskDetailPage({
    required this.task,
    required this.projection,
    required this.planImpact,
    required this.onComplete,
    required this.onSchedule,
    super.key,
  });

  final TaskItem task;
  final TaskProjection projection;
  final PlanBlockImpact planImpact;
  final Future<void> Function(bool cancelFutureBlocks) onComplete;
  final VoidCallback onSchedule;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(task.title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(task.description ?? '无描述'),
          const SizedBox(height: 12),
          Text('状态：${task.state.name}'),
          Text('规划：${projection.planning.name}'),
          Text('截止：${projection.deadline.name}'),
          Text('待确认：${projection.confirmation.name}'),
          Text(
            '未来计划：${planImpact.futureAcceptedCount} 个，'
            '${planImpact.futureAcceptedMinutes} 分钟',
          ),
          if (task.userNotes != null) Text('备注：${task.userNotes}'),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: onSchedule,
            icon: const Icon(Icons.add_alarm),
            label: const Text('安排时间'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('complete-task'),
            onPressed: task.isTerminal ? null : () => _confirmComplete(context),
            icon: const Icon(Icons.task_alt),
            label: const Text('完成任务'),
          ),
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
}
