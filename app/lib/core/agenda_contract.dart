/// Date-only UTC components represent Beijing calendar dates, not instants.
DateTime beijingDay(DateTime instant) {
  final shifted = instant.toUtc().add(const Duration(hours: 8));
  return DateTime.utc(shifted.year, shifted.month, shifted.day);
}

DateTime calendarDay(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);

String formatAgendaDay(DateTime day) =>
    '${day.year}-${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

enum AgendaSource { course, exam, young }

enum AgendaFilter { all, course, exam, young }

enum AgendaPresence { observed, outsideScope, missingWithinScope }

/// An internal local write reference, never a model parameter or audit value.
final class AgendaReference {
  const AgendaReference({
    required this.source,
    required this.localId,
    required this.version,
  });
  final AgendaSource source;
  final int localId;
  final int version;

  @override
  bool operator ==(Object other) =>
      other is AgendaReference &&
      source == other.source &&
      localId == other.localId &&
      version == other.version;

  @override
  int get hashCode => Object.hash(source, localId, version);

  @override
  String toString() => 'AgendaReference';
}

final class AgendaItem {
  const AgendaItem({
    required this.reference,
    required this.title,
    required this.startsAtUtc,
    required this.endsAtUtc,
    required this.presence,
    required this.hidden,
    this.location,
  });
  final AgendaReference reference;
  final String title;
  final DateTime startsAtUtc;
  final DateTime endsAtUtc;
  final AgendaPresence presence;
  final bool hidden;
  final String? location;

  @override
  String toString() => 'AgendaItem';
}

/// Coverage is for accepted local records; it makes no freshness claim about
/// school data. Hidden records and date/source filtering are explicit.
final class AgendaSlice {
  AgendaSlice({
    required this.day,
    required this.filter,
    required this.includeHidden,
    required List<AgendaItem> items,
    required this.matched,
    required this.totalStored,
    required this.ready,
    required this.truncated,
  }) : items = List<AgendaItem>.unmodifiable(items);

  final String version = 'local-agenda-v1';
  final DateTime day;
  final AgendaFilter filter;
  final bool includeHidden;
  final List<AgendaItem> items;
  final int matched;
  final int totalStored;
  final bool ready;
  final bool truncated;
}
