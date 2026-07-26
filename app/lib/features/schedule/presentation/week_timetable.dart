import 'dart:ui';

import 'package:flutter/material.dart';

import '../domain/overlap_engine.dart';
import '../domain/schedule_projection.dart';
import '../domain/ustc_periods.dart';
import 'all_day_band.dart';
import 'event_block.dart';
import 'overlap_expansion.dart';
import 'time_axis.dart';

class WeekTimetable extends StatelessWidget {
  const WeekTimetable({
    required this.projection,
    required this.onEventSelected,
    this.onEmptyRangeCreate,
    super.key,
  });

  final ScheduleProjection projection;
  final ValueChanged<EffectiveEvent> onEventSelected;
  final void Function(DateTime day, int minute)? onEmptyRangeCreate;

  static const axisWidth = 56.0;
  static const minimumDayWidth = 142.0;
  static const pixelsPerMinute = 0.72;

  @override
  Widget build(BuildContext context) {
    final groupsByEvent = {
      for (final group in projection.overlapGroups)
        for (final event in group.events) event.id: group,
    };
    return LayoutBuilder(
      builder: (context, constraints) {
        final fitted = (constraints.maxWidth - axisWidth) / 7;
        final dayWidth = fitted > minimumDayWidth ? fitted : minimumDayWidth;
        final totalWidth = axisWidth + dayWidth * 7;
        return SingleChildScrollView(
          key: const Key('week-horizontal-scroll'),
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: totalWidth,
            height: constraints.maxHeight,
            child: Column(
              children: [
                _DayHeaders(
                  days: projection.week.days,
                  dayWidth: dayWidth,
                  axisWidth: axisWidth,
                ),
                AllDayBand(
                  eventsByDay: projection.allDayByDay,
                  dayWidth: dayWidth,
                  axisWidth: axisWidth,
                ),
                const Divider(height: 1),
                Expanded(
                  child: SingleChildScrollView(
                    child: SizedBox(
                      height:
                          (UstcPeriods.dayEndMinutes -
                              UstcPeriods.dayStartMinutes) *
                          pixelsPerMinute,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const TimeAxis(pixelsPerMinute: pixelsPerMinute),
                          for (final day in projection.week.days)
                            _DayColumn(
                              day: day,
                              width: dayWidth,
                              events:
                                  projection.timedByDay[day.weekday] ?? const [],
                              groupsByEvent: groupsByEvent,
                              onEventSelected: onEventSelected,
                              onEmptyRangeCreate: onEmptyRangeCreate,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DayHeaders extends StatelessWidget {
  const _DayHeaders({
    required this.days,
    required this.dayWidth,
    required this.axisWidth,
  });

  final List<DateTime> days;
  final double dayWidth;
  final double axisWidth;

  static const labels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          SizedBox(width: axisWidth),
          for (var index = 0; index < days.length; index++)
            SizedBox(
              width: dayWidth,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    labels[index],
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    '${days[index].month}/${days[index].day}',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _DayColumn extends StatelessWidget {
  const _DayColumn({
    required this.day,
    required this.width,
    required this.events,
    required this.groupsByEvent,
    required this.onEventSelected,
    required this.onEmptyRangeCreate,
  });

  final DateTime day;
  final double width;
  final List<ProjectedEvent> events;
  final Map<String, OverlapGroup> groupsByEvent;
  final ValueChanged<EffectiveEvent> onEventSelected;
  final void Function(DateTime day, int minute)? onEmptyRangeCreate;

  @override
  Widget build(BuildContext context) {
    final ordered = [...events]..sort((a, b) {
      final groupA = groupsByEvent[a.event.id];
      final groupB = groupsByEvent[b.event.id];
      final foregroundA = groupA?.foreground.id == a.event.id ? 1 : 0;
      final foregroundB = groupB?.foreground.id == b.event.id ? 1 : 0;
      return foregroundA.compareTo(foregroundB);
    });
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPressStart: onEmptyRangeCreate == null
          ? null
          : (details) {
              final minute =
                  UstcPeriods.dayStartMinutes +
                  (details.localPosition.dy / WeekTimetable.pixelsPerMinute)
                      .round();
              onEmptyRangeCreate!(day, minute);
            },
      child: Container(
        width: width,
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: Theme.of(context).dividerColor),
          ),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (final period in UstcPeriods.values)
              Positioned(
                top:
                    (period.startMinutes - UstcPeriods.dayStartMinutes) *
                    WeekTimetable.pixelsPerMinute,
                left: 0,
                right: 0,
                child: Divider(
                  height: 1,
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
                ),
              ),
            for (final item in ordered) _eventPosition(context, item),
          ],
        ),
      ),
    );
  }

  Widget _eventPosition(BuildContext context, ProjectedEvent item) {
    final group = groupsByEvent[item.event.id];
    final foreground = group == null || group.foreground.id == item.event.id;
    Widget block = EventBlock(
      event: item.event,
      opacity: foreground ? 0.84 : 0.32,
      onTap: () {
        if (group == null) {
          onEventSelected(item.event);
        } else {
          showDialog<void>(
            context: context,
            builder: (context) => OverlapExpansion(
              group: group,
              onSelected: onEventSelected,
            ),
          );
        }
      },
    );
    if (!foreground) {
      block = Transform.translate(
        offset: const Offset(5, 3),
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 0.8, sigmaY: 0.8),
          child: block,
        ),
      );
    }
    return Positioned(
      key: foreground && group != null ? Key('overlap-group-${group.id}') : null,
      top: item.topMinutes * WeekTimetable.pixelsPerMinute,
      left: 3,
      right: 3,
      height: (item.heightMinutes * WeekTimetable.pixelsPerMinute)
          .clamp(32, double.infinity)
          .toDouble(),
      child: block,
    );
  }
}
