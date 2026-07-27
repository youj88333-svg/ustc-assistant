import 'package:flutter/material.dart';

import '../domain/plan_block.dart';

class PendingReviewList extends StatelessWidget {
  const PendingReviewList({
    required this.blocks,
    required this.onDone,
    required this.onSkipped,
    required this.onReschedule,
    super.key,
  });

  final List<PlanBlockItem> blocks;
  final ValueChanged<PlanBlockItem> onDone;
  final ValueChanged<PlanBlockItem> onSkipped;
  final ValueChanged<PlanBlockItem> onReschedule;

  @override
  Widget build(BuildContext context) {
    if (blocks.isEmpty) return const SizedBox.shrink();
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('待确认的计划时段', style: Theme.of(context).textTheme.titleSmall),
            for (final block in blocks)
              ListTile(
                dense: true,
                title: Text(block.title ?? '任务计划'),
                subtitle: Text(_range(block)),
                trailing: MenuAnchor(
                  builder: (context, controller, child) => IconButton(
                    tooltip: '复核计划时段',
                    onPressed: controller.open,
                    icon: const Icon(Icons.fact_check_outlined),
                  ),
                  menuChildren: [
                    MenuItemButton(
                      onPressed: () => onDone(block),
                      child: const Text('已执行'),
                    ),
                    MenuItemButton(
                      onPressed: () => onSkipped(block),
                      child: const Text('已跳过'),
                    ),
                    MenuItemButton(
                      onPressed: () => onReschedule(block),
                      child: const Text('重新安排'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _range(PlanBlockItem block) =>
      '${_two(block.startAt.hour)}:${_two(block.startAt.minute)} - '
      '${_two(block.endAt.hour)}:${_two(block.endAt.minute)}';

  String _two(int value) => value.toString().padLeft(2, '0');
}
