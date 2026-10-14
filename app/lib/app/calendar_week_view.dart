import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/agenda_contract.dart';
import '../core/calendar_contract.dart';
import 'calendar_display_style.dart';
import 'calendar_task_band.dart';
import 'calendar_teaching_axis.dart';

final class CalendarWeekView extends StatelessWidget {
  const CalendarWeekView({
    super.key,
    required this.window,
    required this.today,
    required this.tasks,
    required this.nowUtc,
    required this.onSelect,
    required this.onOverflow,
    required this.onSelectTask,
    required this.onOpenUnscheduledTasks,
    required this.onTaskOverflow,
  });

  final CalendarWindow window;
  final DateTime today;
  final List<TaskRecord> tasks;
  final DateTime nowUtc;
  final ValueChanged<CalendarOccurrence> onSelect;
  final void Function(String heading, List<CalendarOccurrence> occurrences)
  onOverflow;
  final ValueChanged<TaskRecord> onSelectTask;
  final VoidCallback onOpenUnscheduledTasks;
  final void Function(DateTime day, List<TaskRecord> tasks) onTaskOverflow;

  static const double _timeGutter = 62;
  static const double _minimumDayWidth = 124;
  static const double _headingHeight = 34;
  static const int _teachingStart = 420;

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
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : boardWidth;
        final availableHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 680.0;
        final contentWidth = math.max(boardWidth, availableWidth).toDouble();
        final dayWidth = (contentWidth - _timeGutter) / days.length;
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final allDay = _segmentsByDay(days, allDay: true);
        final earlyMorning = _segmentsByDay(days, earlyMorning: true);
        final taskProjection = projectCalendarTasks(
          tasks: tasks,
          days: days,
          nowUtc: nowUtc,
        );
        final showAllDay = allDay.values.any((segments) => segments.isNotEmpty);
        final showEarly = earlyMorning.values.any(
          (segments) => segments.isNotEmpty,
        );
        final showTasks = taskProjection.hasVisibleTasks;
        final compact = availableHeight < 480 || textScale > 1.45;
        final bandLimit = compact
            ? math.min(72.0, availableHeight * .18).toDouble()
            : 92.0;
        final allDayHeight = showAllDay
            ? _bandHeight(textScale, bandLimit)
            : 0.0;
        final earlyHeight = showEarly ? _bandHeight(textScale, bandLimit) : 0.0;
        final taskHeight = showTasks ? _taskBandHeight(textScale) : 0.0;
        final separatorHeight = showAllDay || showEarly || showTasks
            ? 5.0
            : 0.0;
        final axisAvailable = math
            .max(
              0,
              availableHeight -
                  _headingHeight -
                  allDayHeight -
                  taskHeight -
                  earlyHeight -
                  separatorHeight,
            )
            .toDouble();
        final axis = CalendarTeachingAxis.fit(
          axisAvailable,
          textScale: textScale,
        );

        return SingleChildScrollView(
          key: const ValueKey('calendar-week-horizontal-scroll'),
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: contentWidth,
            height: availableHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _dayHeadings(days, dayWidth: dayWidth),
                if (showAllDay)
                  _compactBand(
                    days,
                    allDay,
                    dayWidth: dayWidth,
                    height: allDayHeight,
                    label: '全天',
                    textScale: textScale,
                  ),
                if (showTasks)
                  CalendarTaskBand(
                    days: days,
                    tasks: tasks,
                    nowUtc: nowUtc,
                    height: taskHeight,
                    gutterWidth: _timeGutter,
                    dayWidth: dayWidth,
                    onSelectTask: onSelectTask,
                    onOpenUnscheduledTasks: onOpenUnscheduledTasks,
                    onOverflow: onTaskOverflow,
                  ),
                if (showEarly)
                  _compactBand(
                    days,
                    earlyMorning,
                    dayWidth: dayWidth,
                    height: earlyHeight,
                    label: '凌晨 00:00–07:00',
                    textScale: textScale,
                    earlyMorning: true,
                  ),
                if (separatorHeight > 0) const Divider(height: 5, thickness: 1),
                Expanded(
                  child: SingleChildScrollView(
                    key: const ValueKey('calendar-week-time-scroll'),
                    child: SizedBox(
                      height: axis.height,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _axisLabels(axis),
                          for (final day in days)
                            _dayTimeline(day, dayWidth, axis),
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

  Widget _dayHeadings(List<DateTime> days, {required double dayWidth}) =>
      SizedBox(
        height: _headingHeight,
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
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
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

  double _bandHeight(double textScale, double maximum) =>
      math.min(28 * textScale.clamp(1, 2), maximum).toDouble();

  double _taskBandHeight(double textScale) =>
      math.min(38 * textScale.clamp(1, 2), 72).toDouble();

  Widget _compactBand(
    List<DateTime> days,
    Map<DateTime, List<CalendarDaySegment>> byDay, {
    required double dayWidth,
    required double height,
    required String label,
    required double textScale,
    bool earlyMorning = false,
  }) => SizedBox(
    height: height,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: _timeGutter,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 9, color: const Color(0xFF66736C)),
              ),
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
              child: _bandItems(
                label,
                byDay[day] ?? const [],
                height: height,
                textScale: textScale,
                earlyMorning: earlyMorning,
              ),
            ),
          ),
      ],
    ),
  );

  Widget _bandItems(
    String heading,
    List<CalendarDaySegment> segments, {
    required double height,
    required double textScale,
    required bool earlyMorning,
  }) {
    if (segments.isEmpty) return const SizedBox.shrink();
    final segment = segments.first;
    final remaining = segments.length - 1;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _eventTile(
              segment,
              strip: true,
              stripEndMinute: earlyMorning
                  ? math
                        .min(segment.endMinute, _teachingStart.toDouble())
                        .toDouble()
                  : null,
            ),
          ),
          if (remaining > 0)
            SizedBox(
              width: 28,
              child: TextButton(
                key: ValueKey(
                  'calendar-week-overflow-${earlyMorning ? 'early' : 'all-day'}-${_dayKey(segments.first.day)}',
                ),
                style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => onOverflow(
                  '$heading · ${_date(segments.first.day)}',
                  _distinctOccurrences(segments),
                ),
                child: Tooltip(
                  message: '查看全部 ${segments.length} 条日程',
                  child: Text(
                    '+$remaining',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<CalendarOccurrence> _distinctOccurrences(
    List<CalendarDaySegment> segments,
  ) {
    final occurrences = <CalendarReference, CalendarOccurrence>{};
    for (final segment in segments) {
      occurrences[segment.occurrence.reference] = segment.occurrence;
    }
    return occurrences.values.toList(growable: false);
  }

  Widget _axisLabels(CalendarTeachingAxis axis) => SizedBox(
    width: _timeGutter,
    height: axis.height,
    child: Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        for (final band in axis.bands)
          Positioned(
            top: band.top,
            height: math.max(1, band.height).toDouble(),
            left: 0,
            right: 0,
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 4, top: 1),
                child: Text(
                  key: band.period == null
                      ? ValueKey('calendar-week-band-${band.startMinute}')
                      : ValueKey('calendar-week-period-${band.period}'),
                  _axisLabel(band),
                  textAlign: TextAlign.right,
                  maxLines: band.period == null ? 1 : 2,
                  overflow: TextOverflow.clip,
                  style: TextStyle(
                    fontSize: band.period == null ? 8 : 9,
                    color: band.period == null
                        ? const Color(0xFF758079)
                        : const Color(0xFF405348),
                    fontWeight: band.period == null
                        ? FontWeight.w400
                        : FontWeight.w600,
                    height: 1.05,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  String _axisLabel(TeachingAxisBand band) {
    final start = _minute(band.startMinute.toDouble());
    final end = _minute(band.endMinute.toDouble());
    if (band.period != null) return '第${band.period}节\n$start–$end';
    final duration = band.endMinute - band.startMinute;
    if (duration < 30) return '';
    return '${band.label} $start–$end';
  }

  Widget _dayTimeline(
    DateTime day,
    double dayWidth,
    CalendarTeachingAxis axis,
  ) {
    final scheduled = _segments(day, allDay: false)
        .where((segment) => segment.endMinute > _teachingStart)
        .toList(growable: false);
    final lanes = _assignLanes(scheduled);
    return SizedBox(
      width: dayWidth,
      height: axis.height,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(right: BorderSide(color: Color(0xFFE3E9E5))),
        ),
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            for (final band in axis.bands)
              Positioned(
                top: band.top,
                height: math.max(1, band.height).toDouble(),
                left: 0,
                right: 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: _bandColor(band),
                    border: const Border(
                      bottom: BorderSide(color: Color(0xFFE8ECE9), width: .7),
                    ),
                  ),
                ),
              ),
            for (final entry in lanes) _positionedEvent(entry, dayWidth, axis),
          ],
        ),
      ),
    );
  }

  Widget _positionedEvent(
    _SegmentLane entry,
    double dayWidth,
    CalendarTeachingAxis axis,
  ) {
    final startMinute = math
        .max(_teachingStart.toDouble(), entry.segment.startMinute)
        .toDouble();
    final endMinute = math.min(1440.0, entry.segment.endMinute).toDouble();
    if (endMinute <= startMinute) return const SizedBox.shrink();
    final top = axis.y(startMinute);
    final height = axis.y(endMinute) - top;
    final laneWidth = (dayWidth - 6) / entry.laneCount;
    return Positioned(
      top: top,
      height: height,
      left: 3 + entry.lane * laneWidth,
      width: math.max(12, laneWidth - 2).toDouble(),
      child: _eventTile(
        entry.segment,
        clippedAtTeachingStart: entry.segment.startMinute < _teachingStart,
      ),
    );
  }

  Color _bandColor(TeachingAxisBand band) {
    if (band.period != null) return const Color(0xFFFCFDFC);
    final duration = band.endMinute - band.startMinute;
    return duration >= 30 ? const Color(0xFFF2F5F3) : const Color(0xFFF9FAF9);
  }

  Widget _eventTile(
    CalendarDaySegment segment, {
    bool strip = false,
    double? stripEndMinute,
    bool clippedAtTeachingStart = false,
  }) {
    final occurrence = segment.occurrence;
    final colors = calendarColorsForTitle(occurrence.title);
    final kind = occurrence.reference.identity.kind;
    final academic = occurrence.academicDetails;
    final prefix = segment.continuesBefore || clippedAtTeachingStart
        ? '← '
        : '';
    final suffix = segment.continuesAfter ? ' →' : '';
    final location = occurrence.location.trim();
    final title =
        '$prefix${occurrence.title}$suffix'
        '${strip && location.isNotEmpty ? ' · $location' : ''}';
    final time = strip && stripEndMinute != null
        ? '${_minute(segment.startMinute)}–${_minute(stripEndMinute)}'
              '${segment.endMinute > stripEndMinute ? '…' : ''}'
        : null;
    final actualTime =
        '${_minute(segment.startMinute)}–${_minute(segment.endMinute)}';
    final statusItems = _eventStatusItems(occurrence);
    return Material(
      color: colors.fill,
      borderRadius: BorderRadius.circular(strip ? 5 : 7),
      child: InkWell(
        key: ValueKey<CalendarReference>(occurrence.reference),
        borderRadius: BorderRadius.circular(strip ? 5 : 7),
        onTap: () => onSelect(occurrence),
        child: Tooltip(
          message: _weekTileTooltip(occurrence, actualTime),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: colors.edge.withValues(alpha: .55)),
              borderRadius: BorderRadius.circular(strip ? 5 : 7),
            ),
            padding: EdgeInsets.symmetric(
              horizontal: strip ? 4 : 5,
              vertical: strip ? 2 : 3,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final textScale = MediaQuery.textScalerOf(context).scale(1);
                final detailLineHeight = 14.0 * textScale + 2;
                var remainingHeight = constraints.maxHeight - 18 * textScale;
                final locationAvailable =
                    location.isNotEmpty ||
                    (_isJwAcademicKind(kind) && academic != null);
                final showLocation =
                    !strip &&
                    locationAvailable &&
                    remainingHeight >= detailLineHeight;
                if (showLocation) remainingHeight -= detailLineHeight;
                final teacherSummary = academic?.teachers.join('、') ?? '';
                final teacherAvailable =
                    academic != null &&
                    (kind == CalendarKind.course || teacherSummary.isNotEmpty);
                final showTeachers =
                    !strip &&
                    teacherAvailable &&
                    remainingHeight >= detailLineHeight;
                if (showTeachers) remainingHeight -= detailLineHeight;
                final showTime = !strip && remainingHeight >= detailLineHeight;
                final lineHeight = 16 * textScale;
                final titleHeight =
                    constraints.maxHeight -
                    (showLocation ? detailLineHeight : 0) -
                    (showTeachers ? detailLineHeight : 0) -
                    (showTime ? detailLineHeight : 0);
                final titleLines = strip
                    ? 1
                    : (titleHeight / lineHeight).floor().clamp(1, 3);
                final displayedLocation = location.isNotEmpty
                    ? location
                    : '本次来源未提供';
                final displayedTeachers = teacherSummary.isEmpty
                    ? '本次来源未提供'
                    : teacherSummary;
                final heading = Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final status
                        in kind == CalendarKind.planBlock
                            ? statusItems.take(
                                constraints.maxWidth >= 160 * textScale ? 2 : 1,
                              )
                            : statusItems)
                      Padding(
                        padding: const EdgeInsets.only(right: 2),
                        child: _statusMark(status),
                      ),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: titleLines,
                        overflow: TextOverflow.ellipsis,
                        softWrap: !strip,
                        style: TextStyle(
                          color: colors.ink,
                          fontSize: strip ? 10 : 12,
                          height: 1.1,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (time != null &&
                        constraints.maxWidth >= 100 * textScale) ...[
                      const SizedBox(width: 3),
                      Text(
                        time,
                        style: TextStyle(
                          color: colors.ink.withValues(alpha: .82),
                          fontSize: 8,
                        ),
                      ),
                    ],
                  ],
                );
                if (!showTime && !showLocation && !showTeachers) return heading;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    heading,
                    if (showLocation) ...[
                      const SizedBox(height: 2),
                      Text(
                        '地点：$displayedLocation',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.ink.withValues(alpha: .82),
                          fontSize: 10,
                          height: 1.2,
                        ),
                      ),
                    ],
                    if (showTeachers) ...[
                      const SizedBox(height: 2),
                      Text(
                        '教师：$displayedTeachers',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.ink.withValues(alpha: .82),
                          fontSize: 10,
                          height: 1.2,
                        ),
                      ),
                    ],
                    if (showTime) ...[
                      const SizedBox(height: 2),
                      Text(
                        actualTime,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.ink.withValues(alpha: .82),
                          fontSize: 10,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  List<({String tooltip, String shortLabel, Color color})> _eventStatusItems(
    CalendarOccurrence occurrence,
  ) {
    final conflicts = window.conflicts.where(
      (conflict) =>
          !conflict.left.allDay &&
          !conflict.right.allDay &&
          (conflict.left.reference.identity == occurrence.reference.identity ||
              conflict.right.reference.identity ==
                  occurrence.reference.identity),
    );
    final hasConflict = conflicts.any(
      (conflict) => conflict.status == CalendarConflictStatus.conflict,
    );
    final explicitConflict = conflicts.any(
      (conflict) =>
          conflict.hasExplicitDecision &&
          conflict.status == CalendarConflictStatus.conflict,
    );
    final hasNotConflict = conflicts.any(
      (conflict) => conflict.status == CalendarConflictStatus.notConflict,
    );
    final hasDefaultConflict = conflicts.any(
      (conflict) =>
          conflict.status == CalendarConflictStatus.conflict &&
          !conflict.hasExplicitDecision,
    );
    final hasLegacy = conflicts.any(
      (conflict) =>
          conflict.relation?.kind == CalendarRelationKind.legacyUndecided,
    );
    final statuses = <({String tooltip, String shortLabel, Color color})>[];
    if (hasConflict) {
      final tooltip = explicitConflict && hasDefaultConflict
          ? '含已确认冲突和默认冲突候选'
          : explicitConflict
          ? '已确认冲突'
          : hasLegacy
          ? '默认按冲突展示；旧说明已保留'
          : '默认按冲突展示，尚未确认';
      statuses.add((
        tooltip: tooltip,
        shortLabel: hasDefaultConflict ? '冲*' : '冲',
        color: const Color(0xFF9B2C2C),
      ));
    }
    if (hasNotConflict) {
      statuses.add((
        tooltip: '已判定不冲突',
        shortLabel: '否',
        color: const Color(0xFF2F6848),
      ));
    }
    if (occurrence.presence == AgendaPresence.missingWithinScope) {
      statuses.add((
        tooltip: '来源暂缺，日程仍予以保留',
        shortLabel: '缺',
        color: const Color(0xFF805900),
      ));
    }
    if (occurrence.presence == AgendaPresence.outsideScope) {
      statuses.add((
        tooltip: '当前记录不在来源观察范围内',
        shortLabel: '外',
        color: const Color(0xFF66736C),
      ));
    }
    if (occurrence.reference.identity.kind == CalendarKind.planBlock) {
      statuses.add((
        tooltip: '类别：任务时间块',
        shortLabel: '块',
        color: const Color(0xFF66736C),
      ));
    }
    switch (occurrence.planBlockStatus) {
      case PlanBlockStatus.planned:
        statuses.add((
          tooltip: '时间块状态：待执行',
          shortLabel: '待',
          color: const Color(0xFF66736C),
        ));
        break;
      case PlanBlockStatus.done:
        statuses.add((
          tooltip: '时间块状态：已执行',
          shortLabel: '完',
          color: const Color(0xFF2F6848),
        ));
        break;
      case PlanBlockStatus.skipped:
        statuses.add((
          tooltip: '时间块状态：已跳过',
          shortLabel: '跳',
          color: const Color(0xFF805900),
        ));
        break;
      case null:
        break;
    }
    switch (occurrence.taskStatus) {
      case TaskStatus.active:
        statuses.add((
          tooltip: '关联任务状态：进行中',
          shortLabel: '任',
          color: const Color(0xFF2F6848),
        ));
        break;
      case TaskStatus.blocked:
        statuses.add((
          tooltip: '关联任务状态：受阻',
          shortLabel: '阻',
          color: const Color(0xFF805900),
        ));
        break;
      case TaskStatus.completed:
        statuses.add((
          tooltip: '关联任务状态：已完成',
          shortLabel: '任✓',
          color: const Color(0xFF2F6848),
        ));
        break;
      case TaskStatus.cancelled:
        statuses.add((
          tooltip: '关联任务状态：已取消',
          shortLabel: '销',
          color: const Color(0xFF66736C),
        ));
        break;
      case null:
        break;
    }
    return statuses;
  }

  Widget _statusMark(
    ({String tooltip, String shortLabel, Color color}) status,
  ) => Tooltip(
    message: status.tooltip,
    child: status.shortLabel == '冲' || status.shortLabel == '冲*'
        ? Icon(Icons.error_outline_rounded, color: status.color, size: 13)
        : Text(
            status.shortLabel,
            style: TextStyle(
              color: status.color,
              fontSize: 8,
              fontWeight: FontWeight.w700,
            ),
          ),
  );

  List<CalendarDaySegment> _segments(DateTime day, {required bool allDay}) =>
      window.segments
          .where(
            (segment) =>
                _sameDay(segment.day, day) &&
                segment.occurrence.allDay == allDay &&
                (!allDay || segment.startMinute < 1440),
          )
          .toList()
        ..sort((left, right) => left.startMinute.compareTo(right.startMinute));

  Map<DateTime, List<CalendarDaySegment>> _segmentsByDay(
    List<DateTime> days, {
    bool allDay = false,
    bool earlyMorning = false,
  }) => {
    for (final day in days)
      day:
          window.segments
              .where(
                (segment) =>
                    _sameDay(segment.day, day) &&
                    segment.occurrence.allDay == allDay &&
                    (earlyMorning
                        ? segment.startMinute < _teachingStart
                        : true),
              )
              .toList()
            ..sort(
              (left, right) => left.startMinute.compareTo(right.startMinute),
            ),
  };

  List<_SegmentLane> _assignLanes(List<CalendarDaySegment> segments) {
    if (segments.isEmpty) return const [];
    final ordered = [...segments]
      ..sort((left, right) {
        final start = left.startMinute.compareTo(right.startMinute);
        return start != 0 ? start : left.endMinute.compareTo(right.endMinute);
      });
    final clusters = <List<CalendarDaySegment>>[];
    var cluster = <CalendarDaySegment>[];
    var clusterEnd = double.negativeInfinity;
    for (final segment in ordered) {
      if (cluster.isNotEmpty && segment.startMinute >= clusterEnd) {
        clusters.add(cluster);
        cluster = <CalendarDaySegment>[];
        clusterEnd = double.negativeInfinity;
      }
      cluster.add(segment);
      clusterEnd = math.max(clusterEnd, segment.endMinute).toDouble();
    }
    if (cluster.isNotEmpty) clusters.add(cluster);

    final result = <_SegmentLane>[];
    for (final timeCluster in clusters) {
      final laneEnds = <double>[];
      final clusterEntries = <({CalendarDaySegment segment, int lane})>[];
      for (final segment in timeCluster) {
        final lane = laneEnds.indexWhere((end) => end <= segment.startMinute);
        final assignedLane = lane < 0 ? laneEnds.length : lane;
        if (lane < 0) {
          laneEnds.add(segment.endMinute);
        } else {
          laneEnds[lane] = segment.endMinute;
        }
        clusterEntries.add((segment: segment, lane: assignedLane));
      }
      for (final entry in clusterEntries) {
        result.add(_SegmentLane(entry.segment, entry.lane, laneEnds.length));
      }
    }
    return result;
  }
}

final class _SegmentLane {
  const _SegmentLane(this.segment, this.lane, this.laneCount);
  final CalendarDaySegment segment;
  final int lane;
  final int laneCount;
}

bool _isJwAcademicKind(CalendarKind kind) =>
    kind == CalendarKind.course || kind == CalendarKind.exam;

String _weekTileTooltip(CalendarOccurrence occurrence, String time) {
  final kind = occurrence.reference.identity.kind;
  final lines = <String>[occurrence.title];
  if (!occurrence.allDay) lines.add('时间（北京时间）：$time');
  if (occurrence.planBlockStatus != null) {
    lines.add('时间块状态：${_planBlockStatusLabel(occurrence.planBlockStatus!)}');
  }
  if (occurrence.taskStatus != null) {
    lines.add('关联任务状态：${_taskStatusLabel(occurrence.taskStatus!)}');
  }
  if (!_isJwAcademicKind(kind)) {
    if (occurrence.location.trim().isNotEmpty) {
      lines.add('地点：${occurrence.location.trim()}');
    }
    return lines.join('\n');
  }

  final details = occurrence.academicDetails;
  if (details == null) {
    if (occurrence.location.trim().isNotEmpty) {
      lines.add('地点：${occurrence.location.trim()}');
    }
    lines.add('尚未采集教务信息，重新同步补充');
    return lines.join('\n');
  }

  final location = occurrence.location.trim().isNotEmpty
      ? occurrence.location.trim()
      : details.locationLabel.trim();
  lines.add('地点：${location.isEmpty ? '本次来源未提供' : location}');
  for (final entry in [
    ('校区', details.campus),
    ('楼宇', details.building),
    ('教室', details.room),
    ('教室代码', details.roomCode),
    ('补充地点', details.customPlace),
  ]) {
    if (entry.$2.isNotEmpty) lines.add('${entry.$1}：${entry.$2}');
  }
  if (details.virtual != null) {
    lines.add('虚拟教室：${details.virtual! ? '是' : '否'}');
  }
  if (kind == CalendarKind.course || details.teachers.isNotEmpty) {
    lines.add(
      '教师：${details.teachers.isEmpty ? '本次来源未提供' : details.teachers.join('、')}',
    );
  }
  if (kind == CalendarKind.course) {
    if (details.semesterName.isNotEmpty) {
      lines.add('学期：${details.semesterName}');
    }
  }
  for (final entry in [
    ('课程号', details.courseCode),
    ('课程类别', details.courseType),
  ]) {
    if (entry.$2.isNotEmpty) lines.add('${entry.$1}：${entry.$2}');
  }
  if (details.weekIndex != null) lines.add('周次序号：${details.weekIndex}');
  if (details.weekday != null) lines.add('星期序号：${details.weekday}');
  if (details.periods != null) lines.add('节数：${details.periods}');
  if (details.exerciseClass != null) {
    lines.add('习题课：${details.exerciseClass! ? '是' : '否'}');
  }
  if (kind == CalendarKind.exam) {
    lines.add(
      '考试类型：${details.examType.isEmpty ? '本次来源未提供' : details.examType}',
    );
    if (details.examNote.isNotEmpty) lines.add('考试说明：${details.examNote}');
  }
  return lines.join('\n');
}

String _planBlockStatusLabel(PlanBlockStatus status) => switch (status) {
  PlanBlockStatus.planned => '待执行',
  PlanBlockStatus.done => '已执行',
  PlanBlockStatus.skipped => '已跳过',
};

String _taskStatusLabel(TaskStatus status) => switch (status) {
  TaskStatus.active => '进行中',
  TaskStatus.blocked => '受阻',
  TaskStatus.completed => '已完成',
  TaskStatus.cancelled => '已取消',
};

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

String _dayKey(DateTime day) =>
    '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

String _minute(double minute) {
  final normalized = minute.floor().clamp(0, 1440);
  return '${(normalized ~/ 60).toString().padLeft(2, '0')}:'
      '${(normalized % 60).toString().padLeft(2, '0')}';
}

bool _sameDay(DateTime left, DateTime right) =>
    left.year == right.year &&
    left.month == right.month &&
    left.day == right.day;
