import 'package:flutter/material.dart';

import '../domain/course_color.dart';
import '../domain/overlap_engine.dart';

class EventBlock extends StatelessWidget {
  const EventBlock({
    required this.event,
    required this.onTap,
    this.opacity = 0.84,
    super.key,
  });

  final EffectiveEvent event;
  final VoidCallback onTap;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final color = event.color == null
        ? Color(courseColorValue(event.courseSeriesId ?? event.id))
        : Color(int.parse(event.color!.substring(1), radix: 16) | 0xFF000000);
    return Semantics(
      button: true,
      label: [
        event.title,
        if (event.location != null) event.location!,
        if (event.hasConfirmedConflict) '已确认冲突',
        if (event.isInactivePreview) '非本周上课预览',
      ].join('，'),
      child: Opacity(
        key: Key('event-opacity-${event.id}'),
        opacity: event.isInactivePreview ? 0.3 : opacity,
        child: Material(
          color: color,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
            side: event.isInactivePreview
                ? BorderSide(color: color.withValues(alpha: 0.9), width: 1.5)
                : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: Key('event-${event.id}'),
            onTap: onTap,
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(7, 6, 22, 5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        event.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                      if (event.location != null)
                        Text(
                          event.location!,
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
                if (event.hasConfirmedConflict)
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
}
