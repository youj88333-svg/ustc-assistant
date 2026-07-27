import 'package:flutter/material.dart';

import '../domain/schedule_projection.dart';
import '../domain/overlap_engine.dart' show EffectiveEvent;

/// 0:00 至网格下界（7:00）之间定时事件的横向展示带，与全天带同构。
/// 任一天有凌晨事件时按天分列、最多展示 3 条并显示 +N 溢出；全周无事件时
/// 返回 SizedBox.shrink()，不占用任何纵向空间。
class EarlyMorningBand extends StatelessWidget {
  const EarlyMorningBand({
    required this.eventsByDay,
    required this.dayWidth,
    required this.axisWidth,
    super.key,
  });

  final Map<int, List<EarlyMorningEvent>> eventsByDay;
  final double dayWidth;
  final double axisWidth;

  @override
  Widget build(BuildContext context) {
    final visibleRows = eventsByDay.values
        .map((events) => events.length.clamp(0, 3))
        .fold(0, (maximum, count) => count > maximum ? count : maximum);
    if (visibleRows == 0) return const SizedBox.shrink();
    return SizedBox(
      height: visibleRows * 25 + 8,
      child: Row(
        children: [
          SizedBox(
            width: axisWidth,
            child: const Center(child: Text('凌晨')),
          ),
          for (var day = DateTime.monday; day <= DateTime.sunday; day++)
            _EarlyMorningColumn(
              events: eventsByDay[day] ?? const [],
              width: dayWidth,
            ),
        ],
      ),
    );
  }
}

class _EarlyMorningColumn extends StatelessWidget {
  const _EarlyMorningColumn({required this.events, required this.width});

  final List<EarlyMorningEvent> events;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Column(
        children: [
          for (final item in events.take(3))
            Container(
              height: 22,
              margin: const EdgeInsets.fromLTRB(2, 1, 2, 1),
              padding: const EdgeInsets.symmetric(horizontal: 5),
              alignment: Alignment.centerLeft,
              color: Theme.of(context).colorScheme.tertiaryContainer,
              child: Text(
                _label(item.event),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
            ),
          if (events.length > 3)
            Text(
              '+${events.length - 3}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
        ],
      ),
    );
  }

  String _label(EffectiveEvent event) {
    final start = event.startAt!;
    final hh = start.hour.toString().padLeft(2, '0');
    final mm = start.minute.toString().padLeft(2, '0');
    return '$hh:$mm ${event.title}';
  }
}
