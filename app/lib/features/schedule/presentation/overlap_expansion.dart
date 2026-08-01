import 'package:flutter/material.dart';

import '../domain/overlap_engine.dart';
import '../domain/schedule_grid_item.dart';

class OverlapExpansion extends StatelessWidget {
  const OverlapExpansion({
    required this.group,
    required this.onSelected,
    super.key,
  });

  final OverlapGroup group;
  final ValueChanged<ScheduleGridItem> onSelected;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重叠日程'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in group.items)
              ListTile(
                title: Text(item.title),
                subtitle: item.location == null ? null : Text(item.location!),
                trailing: item.hasConfirmedConflict
                    ? const Icon(Icons.error_outline, color: Colors.red)
                    : null,
                onTap: () {
                  Navigator.of(context).pop();
                  onSelected(item);
                },
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
