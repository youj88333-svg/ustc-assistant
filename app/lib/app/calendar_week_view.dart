import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/calendar_contract.dart';

final class CalendarWeekView extends StatelessWidget {
  const CalendarWeekView({
    super.key,
    required this.window,
    required this.today,
    required this.onSelect,
  });

  final CalendarWindow window;
  final DateTime today;
  final ValueChanged<CalendarOccurrence> onSelect;

  static const double _timeGutter = 46;
  static const double _minimumDayWidth = 124;
  static const double _hourHeight = 58;
  static const int _hours = 24;

  @override
  Widget build(BuildContext context) {
    final firstDay = window.query.firstDay;
    final days = List.generate(
      7,
      (index) =>
          DateTime.utc(firstDay.year, firstDay.month, firstDay.day + index),
    );
    final boardWidth = _timeGutter + _minimumDayWidth * days.length;
    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = math
            .max(boardWidth, constraints.maxWidth)
            .toDouble();
        final dayWidth = (contentWidth - _timeGutter) / days.length;
        final compact = constraints.maxHeight < 220;
        return SingleChildScrollView(
          key: const ValueKey('calendar-week-horizontal-scroll'),
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: contentWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _dayHeadings(
                  context,
                  days,
                  compact: compact,
                  dayWidth: dayWidth,
                ),
                _allDayRow(days, compact: compact, dayWidth: dayWidth),
                const Divider(height: 1),
                Expanded(
                  child: _CalendarTimeScroll(
                    key: const ValueKey('calendar-week-time-scroll'),
                    initialMinute: window.segments
                        .where((segment) => !segment.occurrence.allDay)
                        .fold<double>(
                          480,
                          (minute, segment) =>
                              math.min(minute, segment.startMinute),
                        ),
                    child: SizedBox(
                      height: _hourHeight * _hours,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _hourLabels(),
                          for (final day in days) _dayTimeline(day, dayWidth),
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

  Widget _dayHeadings(
    BuildContext context,
    List<DateTime> days, {
    required bool compact,
    required double dayWidth,
  }) => SizedBox(
    height: compact ? 40 : 48,
    child: Row(
      children: [
        const SizedBox(width: _timeGutter),
        for (final day in days)
          SizedBox(
            width: dayWidth,
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _sameDay(day, today)
                    ? const Color(0xFFE5F1E9)
                    : Colors.white,
                border: const Border(
                  right: BorderSide(color: Color(0xFFE3E9E5)),
                ),
              ),
              child: Text(
                '${_weekday(day.weekday)}  ${_date(day)}',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: _sameDay(day, today)
                      ? const Color(0xFF1F6B45)
                      : const Color(0xFF1D2922),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _allDayRow(
    List<DateTime> days, {
    required bool compact,
    required double dayWidth,
  }) => SizedBox(
    height: compact ? 68 : 88,
    child: Row(
      children: [
        const SizedBox(
          width: _timeGutter,
          child: Center(
            child: Text(
              '全天',
              style: TextStyle(fontSize: 11, color: Color(0xFF66736C)),
            ),
          ),
        ),
        for (final day in days)
          SizedBox(
            width: dayWidth,
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(right: BorderSide(color: Color(0xFFE3E9E5))),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final segment in _segments(day, allDay: true))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: _eventTile(segment, compact: true),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _hourLabels() => SizedBox(
    width: _timeGutter,
    child: Column(
      children: [
        for (var hour = 0; hour < _hours; hour++)
          SizedBox(
            height: _hourHeight,
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '${hour.toString().padLeft(2, '0')}:00',
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFF66736C),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _dayTimeline(DateTime day, double dayWidth) {
    final scheduled = _segments(day, allDay: false);
    final lanes = _assignLanes(scheduled);
    var laneCount = 1;
    for (final entry in lanes) {
      if (entry.lane + 1 > laneCount) laneCount = entry.lane + 1;
    }
    return SizedBox(
      width: dayWidth,
      height: _hourHeight * _hours,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(right: BorderSide(color: Color(0xFFE3E9E5))),
        ),
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            for (var hour = 0; hour <= _hours; hour++)
              Positioned(
                top: hour * _hourHeight,
                left: 0,
                right: 0,
                child: const Divider(height: 1, thickness: 1),
              ),
            for (final entry in lanes)
              Positioned(
                top:
                    (entry.segment.startMinute.clamp(0, 1439) / 60) *
                    _hourHeight,
                height: math
                    .max(
                      23.0,
                      ((entry.segment.endMinute - entry.segment.startMinute)
                                  .clamp(0, 1440) /
                              60) *
                          _hourHeight,
                    )
                    .toDouble(),
                left: 3 + (entry.lane * (dayWidth - 6) / laneCount),
                width: (dayWidth - 6) / laneCount - 2,
                child: _eventTile(entry.segment),
              ),
          ],
        ),
      ),
    );
  }

  List<CalendarDaySegment> _segments(DateTime day, {required bool allDay}) =>
      window.segments
          .where(
            (segment) =>
                _sameDay(segment.day, day) &&
                segment.occurrence.allDay == allDay,
          )
          .toList()
        ..sort((left, right) => left.startMinute.compareTo(right.startMinute));

  List<_SegmentLane> _assignLanes(List<CalendarDaySegment> segments) {
    final ends = <double>[];
    final result = <_SegmentLane>[];
    for (final segment in segments) {
      var lane = ends.indexWhere((end) => end <= segment.startMinute);
      if (lane < 0) {
        lane = ends.length;
        ends.add(segment.endMinute);
      } else {
        ends[lane] = segment.endMinute;
      }
      result.add(_SegmentLane(segment, lane));
    }
    return result;
  }

  Widget _eventTile(CalendarDaySegment segment, {bool compact = false}) {
    final occurrence = segment.occurrence;
    final colors = _kindColor(occurrence.reference.identity.kind);
    final prefix = segment.continuesBefore ? '← ' : '';
    final suffix = segment.continuesAfter ? ' →' : '';
    final durationText = occurrence.allDay
        ? ''
        : ' ${_minute(segment.startMinute)}';
    return Material(
      color: colors.background,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        key: ValueKey<CalendarReference>(occurrence.reference),
        borderRadius: BorderRadius.circular(7),
        onTap: () => onSelect(occurrence),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 5 : 4,
            vertical: compact ? 3 : 2,
          ),
          child: Align(
            alignment: Alignment.topLeft,
            child: Text(
              '$prefix${occurrence.title}$suffix$durationText',
              maxLines: compact ? 2 : 3,
              overflow: TextOverflow.ellipsis,
              softWrap: true,
              style: TextStyle(
                color: colors.foreground,
                fontSize: 12,
                height: 1.2,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _CalendarTimeScroll extends StatefulWidget {
  const _CalendarTimeScroll({
    super.key,
    required this.initialMinute,
    required this.child,
  });
  final double initialMinute;
  final Widget child;
  @override
  State<_CalendarTimeScroll> createState() => _CalendarTimeScrollState();
}

final class _CalendarTimeScrollState extends State<_CalendarTimeScroll> {
  late final ScrollController _scroll = ScrollController(
    initialScrollOffset:
        widget.initialMinute.clamp(0, 480) / 60 * CalendarWeekView._hourHeight,
  );
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SingleChildScrollView(controller: _scroll, child: widget.child);
}

final class _SegmentLane {
  const _SegmentLane(this.segment, this.lane);
  final CalendarDaySegment segment;
  final int lane;
}

({Color background, Color foreground}) _kindColor(CalendarKind kind) =>
    switch (kind) {
      CalendarKind.course => (
        background: const Color(0xFFE9F1FA),
        foreground: const Color(0xFF234D78),
      ),
      CalendarKind.exam => (
        background: const Color(0xFFFFF0E3),
        foreground: const Color(0xFF8A4A10),
      ),
      CalendarKind.young => (
        background: const Color(0xFFE4F1E8),
        foreground: const Color(0xFF1F6B45),
      ),
      CalendarKind.personal => (
        background: const Color(0xFFF0EAF8),
        foreground: const Color(0xFF5D4380),
      ),
    };

bool _sameDay(DateTime left, DateTime right) =>
    left.year == right.year &&
    left.month == right.month &&
    left.day == right.day;

String _weekday(int weekday) => switch (weekday) {
  DateTime.monday => '周一',
  DateTime.tuesday => '周二',
  DateTime.wednesday => '周三',
  DateTime.thursday => '周四',
  DateTime.friday => '周五',
  DateTime.saturday => '周六',
  _ => '周日',
};

String _date(DateTime day) =>
    '${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

String _minute(double minute) {
  final normalized = minute.floor().clamp(0, 1439);
  return '${(normalized ~/ 60).toString().padLeft(2, '0')}:'
      '${(normalized % 60).toString().padLeft(2, '0')}';
}
