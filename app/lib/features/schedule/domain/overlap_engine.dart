import 'schedule_grid_item.dart';

enum EventImportance { low, normal, high, critical }

class EffectiveEvent {
  const EffectiveEvent.timed({
    required this.id,
    required this.title,
    required this.startAt,
    required this.endAt,
    this.courseSeriesId,
    this.location,
    this.hasConfirmedConflict = false,
    this.isInactivePreview = false,
    this.importance = EventImportance.normal,
    this.eventType = 'personal',
    this.foregroundPriority = 0,
    this.color,
  }) : allDay = false,
       startDate = null,
       endDateExclusive = null;

  const EffectiveEvent.allDay({
    required this.id,
    required this.title,
    required this.startDate,
    required this.endDateExclusive,
    this.courseSeriesId,
    this.location,
    this.hasConfirmedConflict = false,
    this.isInactivePreview = false,
    this.importance = EventImportance.normal,
    this.eventType = 'personal',
    this.foregroundPriority = 0,
    this.color,
  }) : allDay = true,
       startAt = null,
       endAt = null;

  final String id;
  final String title;
  final bool allDay;
  final DateTime? startAt;
  final DateTime? endAt;
  final DateTime? startDate;
  final DateTime? endDateExclusive;
  final String? courseSeriesId;
  final String? location;
  final bool hasConfirmedConflict;
  final bool isInactivePreview;
  final EventImportance importance;
  final String eventType;
  final int foregroundPriority;
  final String? color;
}

class OverlapGroup {
  const OverlapGroup({
    required this.id,
    required this.items,
    required this.foreground,
  });

  final String id;
  final List<ScheduleGridItem> items;
  final ScheduleGridItem foreground;

  bool get hasConfirmedConflict =>
      items.any((item) => item.hasConfirmedConflict);
}

List<OverlapGroup> groupOverlaps(List<ScheduleGridItem> input) {
  final items =
      input.where((item) => !item.allDay && !item.isInactivePreview).toList()
        ..sort((a, b) {
          final byStart = a.startAt!.compareTo(b.startAt!);
          return byStart != 0 ? byStart : a.id.compareTo(b.id);
        });
  final groups = <OverlapGroup>[];
  var current = <ScheduleGridItem>[];
  DateTime? groupEnd;

  void finish() {
    if (current.length > 1) {
      final frozen = List<ScheduleGridItem>.unmodifiable(current);
      groups.add(
        OverlapGroup(
          id: frozen.map((item) => item.id).join('|'),
          items: frozen,
          foreground: _foreground(frozen),
        ),
      );
    }
    current = [];
    groupEnd = null;
  }

  for (final item in items) {
    final sameDay =
        current.isEmpty ||
        _dateKey(current.first.startAt!) == _dateKey(item.startAt!);
    if (current.isEmpty || (sameDay && item.startAt!.isBefore(groupEnd!))) {
      current.add(item);
      if (groupEnd == null || item.endAt!.isAfter(groupEnd!)) {
        groupEnd = item.endAt;
      }
    } else {
      finish();
      current.add(item);
      groupEnd = item.endAt;
    }
  }
  finish();
  return List.unmodifiable(groups);
}

ScheduleGridItem _foreground(List<ScheduleGridItem> items) {
  final ordered = [...items]
    ..sort((a, b) {
      final foreground = b.foregroundPriority.compareTo(a.foregroundPriority);
      if (foreground != 0) return foreground;
      final importance = b.importance.index.compareTo(a.importance.index);
      if (importance != 0) return importance;
      final conflict = (b.hasConfirmedConflict ? 1 : 0).compareTo(
        a.hasConfirmedConflict ? 1 : 0,
      );
      if (conflict != 0) return conflict;
      final exam = (b.eventType == 'exam' ? 1 : 0).compareTo(
        a.eventType == 'exam' ? 1 : 0,
      );
      return exam != 0 ? exam : a.id.compareTo(b.id);
    });
  return ordered.first;
}

String _dateKey(DateTime value) => '${value.year}-${value.month}-${value.day}';
