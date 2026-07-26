import 'package:flutter/material.dart';

import '../domain/overlap_engine.dart';

class OverlapExpansion extends StatelessWidget {
  const OverlapExpansion({
    required this.group,
    required this.onSelected,
    super.key,
  });

  final OverlapGroup group;
  final ValueChanged<EffectiveEvent> onSelected;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重叠日程'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final event in group.events)
              ListTile(
                title: Text(event.title),
                subtitle: event.location == null ? null : Text(event.location!),
                trailing: event.hasConfirmedConflict
                    ? const Icon(Icons.error_outline, color: Colors.red)
                    : null,
                onTap: () {
                  Navigator.of(context).pop();
                  onSelected(event);
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
