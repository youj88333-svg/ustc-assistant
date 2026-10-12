import '../core/calendar_contract.dart';
import '../core/agenda_contract.dart';
import '../core/calendar_validation.dart';

/// Pure, bounded projection of one consistent C3 calendar snapshot.
final class CalendarProjection {
  const CalendarProjection();

  static const int _maxInputRows = 5000;
  static const int _maxExpandedCandidates = 20000;
  static const int _maxConflicts = 200;
  static const int _maxOrdinal = 521700;
  static const Duration _beijingOffset = Duration(hours: 8);
  static const int _weekMicros = 7 * 24 * 60 * 60 * 1000000;

  CalendarWindow query(CalendarSnapshot snapshot, CalendarQuery query) {
    validateCalendarQuery(query);
    final index = _indexSnapshot(snapshot);
    final windowStart = _beijingMidnight(query.firstDay);
    final windowEnd = _beijingMidnight(query.endDayExclusive);
    final candidates = <CalendarIdentity, CalendarOccurrence>{};
    var expanded = 0;

    void countCandidate() {
      expanded++;
      if (expanded > _maxExpandedCandidates) {
        throw const CalendarFailure(CalendarFailureCode.limitExceeded);
      }
    }

    void keepIfInWindow(CalendarOccurrence occurrence) {
      if (_intersects(occurrence, windowStart, windowEnd)) {
        candidates.putIfAbsent(occurrence.reference.identity, () => occurrence);
      }
    }

    for (final item in snapshot.school) {
      if (_intersects(item, windowStart, windowEnd)) {
        countCandidate();
        candidates.putIfAbsent(item.reference.identity, () => item);
      }
    }

    for (final series in snapshot.personal) {
      final ordinalRange = _nearbyOrdinals(
        series.draft,
        windowStart,
        windowEnd,
      );
      if (ordinalRange == null) continue;
      for (
        var ordinal = ordinalRange.first;
        ordinal < ordinalRange.endExclusive;
        ordinal++
      ) {
        if (!isActiveOrdinal(series, ordinal)) continue;
        countCandidate();
        final identity = CalendarIdentity(
          CalendarKind.personal,
          series.localId,
          ordinal: ordinal,
        );
        final occurrence = _personalOccurrence(
          snapshot.context,
          series,
          ordinal,
          index.overrides[identity],
        );
        keepIfInWindow(occurrence);
      }
    }

    // A replacement can move a stable ordinal into this window from anywhere.
    // Include it independently of the base occurrence's original date range.
    for (final override in snapshot.overrides) {
      final replacement = override.replacement;
      if (replacement == null) continue;
      final series = index.series[override.localId];
      if (series == null || !isActiveOrdinal(series, override.ordinal)) {
        continue;
      }
      final identity = CalendarIdentity(
        CalendarKind.personal,
        series.localId,
        ordinal: override.ordinal,
      );
      if (candidates.containsKey(identity) ||
          !_draftIntersects(replacement, windowStart, windowEnd)) {
        continue;
      }
      countCandidate();
      candidates.putIfAbsent(
        identity,
        () => _personalOccurrence(
          snapshot.context,
          series,
          override.ordinal,
          override,
        ),
      );
    }

    final allWindowItems = candidates.values.toList()
      ..sort(_compareOccurrences);
    final visible = allWindowItems.where((item) {
      return _matchesFilter(item, query.filter) &&
          (query.includeHidden || !item.hidden) &&
          (query.includeSkipped || !item.skipped);
    }).toList()..sort(_compareOccurrences);
    final matched = visible.length;
    final truncated = matched > query.limit;
    final items = truncated ? visible.take(query.limit).toList() : visible;
    final segments = <CalendarDaySegment>[];
    for (final item in items) {
      segments.addAll(_segmentsFor(item, query));
    }

    final conflictResult = _conflicts(allWindowItems, index.relations);
    return CalendarWindow(
      context: snapshot.context,
      revision: snapshot.revision,
      query: query,
      items: items,
      segments: segments,
      conflicts: conflictResult.conflicts,
      matched: matched,
      truncated: truncated,
      conflictsTruncated: conflictResult.truncated,
    );
  }

  CalendarOccurrence? occurrence(
    CalendarSnapshot snapshot,
    CalendarIdentity identity,
  ) {
    validateCalendarIdentity(identity);
    final index = _indexSnapshot(snapshot);
    if (identity.kind != CalendarKind.personal) {
      for (final item in snapshot.school) {
        if (item.reference.identity == identity) return item;
      }
      return null;
    }

    final series = index.series[identity.localId];
    if (series == null || !isActiveOrdinal(series, identity.ordinal)) {
      return null;
    }
    return _personalOccurrence(
      snapshot.context,
      series,
      identity.ordinal,
      index.overrides[identity],
    );
  }

  /// Whether [ordinal] currently belongs to [series]. Ordinals remain stable
  /// across edits; shortening the series only makes them temporarily inactive.
  bool isActiveOrdinal(PersonalSeries series, int ordinal) {
    if (ordinal < 0 || ordinal > _maxOrdinal) return false;
    validatePersonalDraft(series.draft);
    if (!series.draft.weekly) return ordinal == 0;
    final occurrenceDay = series.draft.anchorDay.add(
      Duration(days: ordinal * 7),
    );
    if (occurrenceDay.year > 9998) return false;
    final untilDay = series.draft.untilDay;
    if (untilDay == null) return true;
    return !occurrenceDay.isAfter(untilDay);
  }

  _SnapshotIndex _indexSnapshot(CalendarSnapshot snapshot) {
    if (snapshot.school.length > _maxInputRows ||
        snapshot.personal.length > _maxInputRows ||
        snapshot.overrides.length > _maxInputRows ||
        snapshot.relations.length > _maxInputRows) {
      throw const CalendarFailure(CalendarFailureCode.limitExceeded);
    }

    for (final item in snapshot.school) {
      final identity = item.reference.identity;
      validateCalendarIdentity(identity);
      if (identity.kind == CalendarKind.personal ||
          item.reference.version < 1 ||
          !item.startsAtUtc.isUtc ||
          !item.endsAtUtc.isUtc ||
          !item.endsAtUtc.isAfter(item.startsAtUtc)) {
        throw const CalendarFailure(CalendarFailureCode.invalidInput);
      }
    }

    final seriesById = <int, PersonalSeries>{};
    for (final series in snapshot.personal) {
      if (series.localId <= 0 ||
          series.version < 1 ||
          seriesById.containsKey(series.localId)) {
        throw const CalendarFailure(CalendarFailureCode.invalidInput);
      }
      validatePersonalDraft(series.draft);
      seriesById[series.localId] = series;
    }

    final overridesByIdentity =
        <CalendarIdentity, PersonalOccurrenceOverride>{};
    for (final override in snapshot.overrides) {
      final identity = CalendarIdentity(
        CalendarKind.personal,
        override.localId,
        ordinal: override.ordinal,
      );
      validateCalendarIdentity(identity);
      if (overridesByIdentity.containsKey(identity)) {
        throw const CalendarFailure(CalendarFailureCode.invalidInput);
      }
      final replacement = override.replacement;
      if (replacement != null) {
        validatePersonalDraft(replacement);
        if (replacement.weekly || replacement.untilDay != null) {
          throw const CalendarFailure(CalendarFailureCode.invalidInput);
        }
      }
      overridesByIdentity[identity] = override;
    }

    final relations = <_IdentityPair, CalendarRelation>{};
    for (final relation in snapshot.relations) {
      validateCalendarIdentity(relation.left);
      validateCalendarIdentity(relation.right);
      if (relation.left == relation.right) {
        throw const CalendarFailure(CalendarFailureCode.invalidInput);
      }
      relations.putIfAbsent(
        _IdentityPair(relation.left, relation.right),
        () => relation,
      );
    }
    return _SnapshotIndex(seriesById, overridesByIdentity, relations);
  }

  CalendarOccurrence _personalOccurrence(
    CalendarContext context,
    PersonalSeries series,
    int ordinal,
    PersonalOccurrenceOverride? override,
  ) {
    final base = series.draft;
    final replacement = override?.replacement;
    final delta = Duration(days: ordinal * 7);
    final startsAtUtc =
        replacement?.startsAtUtc ??
        (ordinal == 0 ? base.startsAtUtc : base.startsAtUtc.add(delta));
    final endsAtUtc =
        replacement?.endsAtUtc ??
        (ordinal == 0 ? base.endsAtUtc : base.endsAtUtc.add(delta));
    final effective = replacement ?? base;
    final identity = CalendarIdentity(
      CalendarKind.personal,
      series.localId,
      ordinal: ordinal,
    );
    return CalendarOccurrence(
      reference: CalendarReference(context, identity, series.version),
      title: effective.title,
      startsAtUtc: startsAtUtc,
      endsAtUtc: endsAtUtc,
      allDay: effective.allDay,
      presence: AgendaPresence.observed,
      hidden: false,
      skipped: override?.skipped ?? false,
      completed: override?.completed ?? false,
      location: effective.location,
      note: effective.note,
    );
  }

  _OrdinalRange? _nearbyOrdinals(
    PersonalEventDraft draft,
    DateTime windowStart,
    DateTime windowEnd,
  ) {
    if (!draft.weekly) {
      if (draft.startsAtUtc.isBefore(windowEnd) &&
          draft.endsAtUtc.isAfter(windowStart)) {
        return const _OrdinalRange(0, 1);
      }
      return null;
    }

    final afterEnd = windowStart.difference(draft.endsAtUtc).inMicroseconds;
    final first = afterEnd < 0 ? 0 : afterEnd ~/ _weekMicros + 1;
    final beforeStart = windowEnd.difference(draft.startsAtUtc).inMicroseconds;
    if (beforeStart <= 0) return null;
    final endExclusive = (beforeStart + _weekMicros - 1) ~/ _weekMicros;
    if (endExclusive <= first) return null;
    return _OrdinalRange(first, endExclusive);
  }

  bool _draftIntersects(
    PersonalEventDraft draft,
    DateTime windowStart,
    DateTime windowEnd,
  ) =>
      draft.startsAtUtc.isBefore(windowEnd) &&
      draft.endsAtUtc.isAfter(windowStart);

  bool _intersects(
    CalendarOccurrence occurrence,
    DateTime windowStart,
    DateTime windowEnd,
  ) =>
      occurrence.startsAtUtc.isBefore(windowEnd) &&
      occurrence.endsAtUtc.isAfter(windowStart);

  DateTime _beijingMidnight(DateTime day) =>
      DateTime.utc(day.year, day.month, day.day).subtract(_beijingOffset);

  bool _matchesFilter(
    CalendarOccurrence item,
    CalendarFilter filter,
  ) => switch (filter) {
    CalendarFilter.all => true,
    CalendarFilter.course =>
      item.reference.identity.kind == CalendarKind.course,
    CalendarFilter.exam => item.reference.identity.kind == CalendarKind.exam,
    CalendarFilter.young => item.reference.identity.kind == CalendarKind.young,
    CalendarFilter.personal =>
      item.reference.identity.kind == CalendarKind.personal,
  };

  int _compareOccurrences(CalendarOccurrence left, CalendarOccurrence right) {
    var result = left.startsAtUtc.compareTo(right.startsAtUtc);
    if (result != 0) return result;
    result = left.endsAtUtc.compareTo(right.endsAtUtc);
    if (result != 0) return result;
    result = left.reference.identity.kind.index.compareTo(
      right.reference.identity.kind.index,
    );
    if (result != 0) return result;
    result = left.reference.identity.localId.compareTo(
      right.reference.identity.localId,
    );
    if (result != 0) return result;
    return left.reference.identity.ordinal.compareTo(
      right.reference.identity.ordinal,
    );
  }

  List<CalendarDaySegment> _segmentsFor(
    CalendarOccurrence item,
    CalendarQuery query,
  ) {
    final segments = <CalendarDaySegment>[];
    for (
      var day = query.firstDay;
      day.isBefore(query.endDayExclusive);
      day = day.add(const Duration(days: 1))
    ) {
      final dayStart = _beijingMidnight(day);
      final dayEnd = dayStart.add(const Duration(days: 1));
      final start = item.startsAtUtc.isAfter(dayStart)
          ? item.startsAtUtc
          : dayStart;
      final end = item.endsAtUtc.isBefore(dayEnd) ? item.endsAtUtc : dayEnd;
      if (!end.isAfter(start)) continue;
      segments.add(
        CalendarDaySegment(
          occurrence: item,
          day: day,
          startMinute: start.difference(dayStart).inMicroseconds / 60000000,
          endMinute: end.difference(dayStart).inMicroseconds / 60000000,
          continuesBefore: item.startsAtUtc.isBefore(dayStart),
          continuesAfter: item.endsAtUtc.isAfter(dayEnd),
        ),
      );
    }
    return segments;
  }

  _ConflictResult _conflicts(
    List<CalendarOccurrence> allWindowItems,
    Map<_IdentityPair, CalendarRelation> relations,
  ) {
    final candidates =
        allWindowItems.where((item) => !item.hidden && !item.skipped).toList()
          ..sort(_compareOccurrences);
    final active = <CalendarOccurrence>[];
    final conflicts = <CalendarConflict>[];
    for (final current in candidates) {
      active.removeWhere(
        (prior) => !prior.endsAtUtc.isAfter(current.startsAtUtc),
      );
      for (final prior in active) {
        final leftIdentity = prior.reference.identity;
        final rightIdentity = current.reference.identity;
        if (leftIdentity == rightIdentity) continue;
        final relation = relations[_IdentityPair(leftIdentity, rightIdentity)];
        conflicts.add(CalendarConflict(prior, current, relation: relation));
        if (conflicts.length > _maxConflicts) {
          return _ConflictResult(conflicts.take(_maxConflicts).toList(), true);
        }
      }
      active.add(current);
    }
    return _ConflictResult(conflicts, false);
  }
}

final class _SnapshotIndex {
  const _SnapshotIndex(this.series, this.overrides, this.relations);
  final Map<int, PersonalSeries> series;
  final Map<CalendarIdentity, PersonalOccurrenceOverride> overrides;
  final Map<_IdentityPair, CalendarRelation> relations;
}

final class _OrdinalRange {
  const _OrdinalRange(this.first, this.endExclusive);
  final int first;
  final int endExclusive;
}

final class _ConflictResult {
  const _ConflictResult(this.conflicts, this.truncated);
  final List<CalendarConflict> conflicts;
  final bool truncated;
}

final class _IdentityPair {
  _IdentityPair(CalendarIdentity first, CalendarIdentity second)
    : left = _compareIdentities(first, second) <= 0 ? first : second,
      right = _compareIdentities(first, second) <= 0 ? second : first;

  final CalendarIdentity left;
  final CalendarIdentity right;

  static int _compareIdentities(CalendarIdentity left, CalendarIdentity right) {
    var result = left.kind.index.compareTo(right.kind.index);
    if (result != 0) return result;
    result = left.localId.compareTo(right.localId);
    if (result != 0) return result;
    return left.ordinal.compareTo(right.ordinal);
  }

  @override
  bool operator ==(Object other) =>
      other is _IdentityPair && left == other.left && right == other.right;

  @override
  int get hashCode => Object.hash(left, right);
}
