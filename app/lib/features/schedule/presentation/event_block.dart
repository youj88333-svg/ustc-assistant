import 'package:flutter/material.dart';

import '../domain/course_color.dart';
import '../domain/schedule_grid_item.dart';

class EventBlock extends StatelessWidget {
  const EventBlock({
    required this.item,
    required this.onTap,
    this.opacity = 0.84,
    super.key,
  });

  final ScheduleGridItem item;
  final VoidCallback onTap;
  final double opacity;

  bool get _isPlanBlock => item.kind == ScheduleGridItemKind.planBlock;

  @override
  Widget build(BuildContext context) {
    final color = item.color == null
        ? Color(courseColorValue(item.colorKey))
        : Color(int.parse(item.color!.substring(1), radix: 16) | 0xFF000000);
    final isPreview = item.isInactivePreview;
    return Semantics(
      button: true,
      label: [
        item.title,
        if (item.location != null) item.location!,
        if (_isPlanBlock) '任务时间段 ${_timeRange(item)}',
        if (item.hasConfirmedConflict) '已确认冲突',
        if (isPreview) '非本周上课预览',
      ].join('，'),
      child: Opacity(
        key: Key(
          _isPlanBlock
              ? 'plan-block-opacity-${item.id}'
              : 'event-opacity-${item.id}',
        ),
        opacity: isPreview ? 0.3 : opacity,
        child: Material(
          color: color,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
            side: isPreview
                ? BorderSide(color: color.withValues(alpha: 0.9), width: 1.5)
                : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: Key(
              _isPlanBlock ? 'plan-block-${item.id}' : 'event-${item.id}',
            ),
            onTap: onTap,
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(7, 6, 22, 5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                      if (item.location != null)
                        Text(
                          item.location!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),
                if (item.hasConfirmedConflict)
                  Positioned(
                    top: 5,
                    right: 5,
                    child: Semantics(
                      container: true,
                      label: '已确认冲突',
                      child: const Icon(
                        Icons.error_outline,
                        color: Color(0xFFFFD4D0),
                        size: 17,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _timeRange(ScheduleGridItem item) {
    final start = item.startAt!;
    final end = item.endAt!;
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(start.hour)}:${two(start.minute)}'
        '-${two(end.hour)}:${two(end.minute)}';
  }
}
