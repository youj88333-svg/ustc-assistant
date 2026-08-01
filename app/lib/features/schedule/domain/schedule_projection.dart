import 'overlap_engine.dart';
import 'schedule_grid_item.dart';
import 'ustc_periods.dart';
import 'week_range.dart';

class ScheduleQuery {
  const ScheduleQuery({
    required this.selectedDate,
    this.events = const [],
    this.items = const [],
  });

  final DateTime selectedDate;

  /// Legacy events-only input, converted to grid items by [buildWeek]. Kept so
  /// callers that only need calendar events can stay minimal.
  final List<EffectiveEvent> events;

  /// Unified grid items (calendar events and planning blocks).
  final List<ScheduleGridItem> items;
}

/// 0:00 至网格下界（7:00）之间的定时事件。这类事件不落入日网格，
/// 改为像全天/截止事项带一样在网格上方按天横排展示，无事件时不渲染。
class EarlyMorningEvent {
  const EarlyMorningEvent({required this.event, required this.day});

  final EffectiveEvent event;
  final DateTime day;
}

class ProjectedEvent {
  const ProjectedEvent({
    required this.item,
    required this.topMinutes,
    required this.heightMinutes,
  });

  final ScheduleGridItem item;
  final int topMinutes;
  final int heightMinutes;
}

class ScheduleProjection {
  const ScheduleProjection({
    required this.week,
    required this.timedByDay,
    required this.allDayByDay,
    required this.earlyMorningByDay,
    required this.previews,
    required this.overlapGroups,
  });

  final WeekRange week;
  final Map<int, List<ProjectedEvent>> timedByDay;
  final Map<int, List<EffectiveEvent>> allDayByDay;
  final Map<int, List<EarlyMorningEvent>> earlyMorningByDay;
  final List<ProjectedEvent> previews;
  final List<OverlapGroup> overlapGroups;
}

ScheduleProjection buildWeek(ScheduleQuery query) {
  final week = WeekRange.forDate(query.selectedDate);
  final timed = <int, List<ProjectedEvent>>{
    for (var day = DateTime.monday; day <= DateTime.sunday; day++) day: [],
  };
  final allDay = <int, List<EffectiveEvent>>{
    for (var day = DateTime.monday; day <= DateTime.sunday; day++) day: [],
  };
  final earlyMorning = <int, List<EarlyMorningEvent>>{
    for (var day = DateTime.monday; day <= DateTime.sunday; day++) day: [],
  };
  final previews = <ProjectedEvent>[];
  final activeTimed = <ScheduleGridItem>[];

  final allItems = <ScheduleGridItem>[
    ...query.items,
    for (final event in query.events) ScheduleGridItem.fromEvent(event),
  ];

  for (final item in allItems) {
    if (!item.showsInWeekGrid) continue;
    if (item.allDay) {
      final event = item.event!;
      for (final day in week.days) {
        if (!day.isBefore(event.startDate!) &&
            day.isBefore(event.endDateExclusive!)) {
          allDay[day.weekday]!.add(event);
        }
      }
      continue;
    }
    if (!week.contains(item.startAt!)) continue;
    final startMinutes =
        item.startAt!.hour * 60 + item.startAt!.minute;
    // 0:00 至网格下界（7:00）的事件不落入日网格，改为凌晨事项带横排展示。
    // 规划块只进入日网格：网格开启前的时间段不投影到凌晨带。
    if (startMinutes < UstcPeriods.dayStartMinutes) {
      if (item.kind != ScheduleGridItemKind.event) continue;
      final event = item.event!;
      // 取事件所在日对应的周内日期；跨日事件按 startAt 的日期归属。
      final day = week.days.firstWhere(
        (d) => d.year == event.startAt!.year && d.month == event.startAt!.month && d.day == event.startAt!.day,
        orElse: () => week.days.firstWhere(
          (d) => d.weekday == event.startAt!.weekday,
        ),
      );
      earlyMorning[day.weekday]!.add(EarlyMorningEvent(event: event, day: day));
      continue;
    }
    final projected = ProjectedEvent(
      item: item,
      topMinutes: startMinutes - UstcPeriods.dayStartMinutes,
      heightMinutes: item.endAt!.difference(item.startAt!).inMinutes,
    );
    timed[item.startAt!.weekday]!.add(projected);
    if (item.isInactivePreview) {
      previews.add(projected);
    } else {
      activeTimed.add(item);
    }
  }
  for (final values in timed.values) {
    values.sort((a, b) => a.item.startAt!.compareTo(b.item.startAt!));
  }
  for (final values in earlyMorning.values) {
    values.sort((a, b) => a.event.startAt!.compareTo(b.event.startAt!));
  }
  return ScheduleProjection(
    week: week,
    timedByDay: Map<int, List<ProjectedEvent>>.unmodifiable({
      for (final entry in timed.entries)
        entry.key: List<ProjectedEvent>.unmodifiable(entry.value),
    }),
    allDayByDay: Map<int, List<EffectiveEvent>>.unmodifiable({
      for (final entry in allDay.entries)
        entry.key: List<EffectiveEvent>.unmodifiable(entry.value),
    }),
    earlyMorningByDay: Map<int, List<EarlyMorningEvent>>.unmodifiable({
      for (final entry in earlyMorning.entries)
        entry.key: List<EarlyMorningEvent>.unmodifiable(entry.value),
    }),
    previews: List.unmodifiable(previews),
    overlapGroups: groupOverlaps(activeTimed),
  );
}
