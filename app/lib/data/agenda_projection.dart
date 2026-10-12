import '../core/agenda_contract.dart';
import 'jw_import_contract.dart';
import 'young_import_contract.dart';

/// One local interpretation used by the shell; later personal/plan projections
/// extend this service instead of rebuilding date/hidden rules in widgets.
final class AgendaProjection {
  const AgendaProjection();

  static const maximumItems = 500;

  AgendaSlice query({
    required DateTime day,
    required JwDataView? jw,
    required YoungDataView? young,
    AgendaFilter filter = AgendaFilter.all,
    bool includeHidden = false,
  }) {
    final date = calendarDay(day);
    final start = date.subtract(const Duration(hours: 8));
    final end = start.add(const Duration(days: 1));
    final records = <AgendaItem>[
      for (final event in jw?.events ?? const <JwStoredEvent>[])
        AgendaItem(
          reference: AgendaReference(
            source: event.kind == JwEventKind.course
                ? AgendaSource.course
                : AgendaSource.exam,
            localId: event.localId,
            version: event.version,
          ),
          title: event.title,
          startsAtUtc: event.startsAtUtc,
          endsAtUtc: event.endsAtUtc,
          presence: switch (event.presence) {
            JwPresence.observed => AgendaPresence.observed,
            JwPresence.outsideScope => AgendaPresence.outsideScope,
            JwPresence.missingWithinScope => AgendaPresence.missingWithinScope,
          },
          hidden: event.hidden,
        ),
      for (final event in young?.events ?? const <YoungStoredEvent>[])
        AgendaItem(
          reference: AgendaReference(
            source: AgendaSource.young,
            localId: event.localId,
            version: event.version,
          ),
          title: event.title,
          startsAtUtc: event.startsAtUtc,
          endsAtUtc: event.endsAtUtc,
          location: event.place.isEmpty ? null : event.place,
          presence: switch (event.presence) {
            YoungPresence.observed => AgendaPresence.observed,
            YoungPresence.outsideScope => AgendaPresence.outsideScope,
            YoungPresence.missingWithinScope =>
              AgendaPresence.missingWithinScope,
          },
          hidden: event.hidden,
        ),
    ];
    final matching =
        records.where((record) {
          if (!includeHidden && record.hidden) return false;
          if (!record.startsAtUtc.isBefore(end) ||
              !record.endsAtUtc.isAfter(start)) {
            return false;
          }
          return switch (filter) {
            AgendaFilter.all => true,
            AgendaFilter.course =>
              record.reference.source == AgendaSource.course,
            AgendaFilter.exam => record.reference.source == AgendaSource.exam,
            AgendaFilter.young => record.reference.source == AgendaSource.young,
          };
        }).toList()..sort((a, b) {
          var result = a.startsAtUtc.compareTo(b.startsAtUtc);
          if (result != 0) return result;
          result = a.endsAtUtc.compareTo(b.endsAtUtc);
          if (result != 0) return result;
          result = a.reference.source.index.compareTo(b.reference.source.index);
          return result != 0
              ? result
              : a.reference.localId.compareTo(b.reference.localId);
        });
    return AgendaSlice(
      day: date,
      filter: filter,
      includeHidden: includeHidden,
      items: matching.take(maximumItems).toList(),
      matched: matching.length,
      totalStored: records.length,
      ready: jw != null && young != null,
      truncated: matching.length > maximumItems,
    );
  }
}
