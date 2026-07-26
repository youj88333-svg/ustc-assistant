import 'package:flutter/material.dart';

import '../domain/overlap_engine.dart';

class AllDayBand extends StatelessWidget {
  const AllDayBand({
    required this.eventsByDay,
    required this.dayWidth,
    required this.axisWidth,
    super.key,
  });

  final Map<int, List<EffectiveEvent>> eventsByDay;
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
          SizedBox(width: axisWidth, child: const Center(child: Text('全天'))),
          for (var day = DateTime.monday; day <= DateTime.sunday; day++)
            _AllDayColumn(
              events: eventsByDay[day] ?? const [],
              width: dayWidth,
            ),
        ],
      ),
    );
  }
}

class _AllDayColumn extends StatelessWidget {
  const _AllDayColumn({required this.events, required this.width});

  final List<EffectiveEvent> events;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Column(
        children: [
          for (final event in events.take(3))
            Container(
              height: 22,
              margin: const EdgeInsets.fromLTRB(2, 1, 2, 1),
              padding: const EdgeInsets.symmetric(horizontal: 5),
              alignment: Alignment.centerLeft,
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: Text(
                event.title,
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
}
