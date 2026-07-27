import 'overlap_engine.dart';
import 'ustc_periods.dart';
import 'week_range.dart';

class ScheduleQuery {
  const ScheduleQuery({required this.selectedDate, required this.events});

  final DateTime selectedDate;
  final List<EffectiveEvent> events;
}

class ProjectedEvent {
  const ProjectedEvent({
    required this.event,
    required this.topMinutes,
    required this.heightMinutes,
  });

  final EffectiveEvent event;
  final int topMinutes;
  final int heightMinutes;
}

class ScheduleProjection {
  const ScheduleProjection({
    required this.week,
    required this.timedByDay,
    required this.allDayByDay,
    required this.previews,
    required this.overlapGroups,
  });

  final WeekRange week;
  final Map<int, List<ProjectedEvent>> timedByDay;
  final Map<int, List<EffectiveEvent>> allDayByDay;
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
  final previews = <ProjectedEvent>[];
  final activeTimed = <EffectiveEvent>[];

  for (final event in query.events) {
    if (event.allDay) {
      for (final day in week.days) {
        if (!day.isBefore(event.startDate!) &&
            day.isBefore(event.endDateExclusive!)) {
          allDay[day.weekday]!.add(event);
        }
      }
      continue;
    }
    if (!week.contains(event.startAt!)) continue;
    final projected = ProjectedEvent(
      event: event,
      topMinutes:
          event.startAt!.hour * 60 +
          event.startAt!.minute -
          UstcPeriods.dayStartMinutes,
      heightMinutes: event.endAt!.difference(event.startAt!).inMinutes,
    );
    timed[event.startAt!.weekday]!.add(projected);
    if (event.isInactivePreview) {
      previews.add(projected);
    } else {
      activeTimed.add(event);
    }
  }
  for (final values in timed.values) {
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
    previews: List.unmodifiable(previews),
    overlapGroups: groupOverlaps(activeTimed),
  );
}
