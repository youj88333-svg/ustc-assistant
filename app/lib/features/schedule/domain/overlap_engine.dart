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
}

class OverlapGroup {
  const OverlapGroup({
    required this.id,
    required this.events,
    required this.foreground,
  });

  final String id;
  final List<EffectiveEvent> events;
  final EffectiveEvent foreground;

  bool get hasConfirmedConflict =>
      events.any((event) => event.hasConfirmedConflict);
}

List<OverlapGroup> groupOverlaps(List<EffectiveEvent> input) {
  final events =
      input
          .where((event) => !event.allDay && !event.isInactivePreview)
          .toList()
        ..sort((a, b) {
          final byStart = a.startAt!.compareTo(b.startAt!);
          return byStart != 0 ? byStart : a.id.compareTo(b.id);
        });
  final groups = <OverlapGroup>[];
  var current = <EffectiveEvent>[];
  DateTime? groupEnd;

  void finish() {
    if (current.length > 1) {
      final frozen = List<EffectiveEvent>.unmodifiable(current);
      groups.add(
        OverlapGroup(
          id: frozen.map((event) => event.id).join('|'),
          events: frozen,
          foreground: _foreground(frozen),
        ),
      );
    }
    current = [];
    groupEnd = null;
  }

  for (final event in events) {
    final sameDay =
        current.isEmpty ||
        _dateKey(current.first.startAt!) == _dateKey(event.startAt!);
    if (current.isEmpty ||
        (sameDay && event.startAt!.isBefore(groupEnd!))) {
      current.add(event);
      if (groupEnd == null || event.endAt!.isAfter(groupEnd!)) {
        groupEnd = event.endAt;
      }
    } else {
      finish();
      current.add(event);
      groupEnd = event.endAt;
    }
  }
  finish();
  return List.unmodifiable(groups);
}

EffectiveEvent _foreground(List<EffectiveEvent> events) {
  final ordered = [...events]..sort((a, b) {
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
