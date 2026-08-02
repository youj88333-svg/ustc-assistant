import '../domain/schedule_grid_item.dart';

/// A stable, kind-scoped identity for a schedule grid item. `kind` reuses the
/// storage token produced by [ScheduleGridItem.relationKind] (`event` or
/// `plan_block`) so it matches `schedule_relations` rows and never mixes bare
/// CalendarEvent ids with PlanBlock ids.
typedef ScheduleItemKey = ({String kind, String id});

/// The parsed halves of a canonical `kind:id|kind:id` pair key.
typedef _ParsedPairKey = ({String leftKind, String leftId, String rightKind, String rightId});

/// The keyed outcome of one bounded conflict projection.
///
/// [pairs] holds one entry per *candidate* pair that could be in conflict
/// (timed overlap, explicit occurrence relation, or a series-rule member
/// combination). Unrelated historical items never produce a `noConflict` pair,
/// so [candidatePairCount] is observable and stays small relative to the full
/// `n*(n-1)/2` match.
class ConflictProjectionResult {
  const ConflictProjectionResult({
    required this.pairs,
    required this.candidatePairCount,
    required this.conflictKeys,
  });

  /// Resolved candidate pairs (deterministically sorted).
  final List<ResolvedConflictPair> pairs;

  /// The number of candidate pairs the projection actually constructed. Equal
  /// to [pairs].length; exposed so callers and tests can assert the projection
  /// is bounded to the consumer's range rather than the full match.
  final int candidatePairCount;

  /// The [ScheduleItemKey] of every item involved in a conflict pair.
  final Set<ScheduleItemKey> conflictKeys;

  /// Whether the item identified by [kind]/[id] participates in a conflict.
  bool isConflict(String kind, String id) =>
      conflictKeys.contains((kind: kind, id: id));
}

/// Why a [ResolvedConflictPair] has its state.
enum ConflictPairOrigin {
  /// Derived purely from a timed overlap (or its absence) — no explicit user
  /// relation was in effect.
  derivedOverlap,

  /// An explicit occurrence-level relation (`schedule_relations` row) decided
  /// the pair.
  explicitOccurrence,

  /// An explicit series rule (`schedule_relation_rules` row) effective at the
  /// pair's occurrence date decided the pair.
  explicitSeries,
}

/// The resolved state of a pair.
enum ConflictPairState { conflict, noConflict }

/// A single resolved unordered pair of schedule grid items.
///
/// [left] and [right] keep their original identities so callers can derive
/// per-item conflict flags ("any resolved pair involving an item is conflict").
class ResolvedConflictPair {
  const ResolvedConflictPair({
    required this.left,
    required this.right,
    required this.state,
    required this.origin,
  });

  final ScheduleGridItem left;
  final ScheduleGridItem right;
  final ConflictPairState state;
  final ConflictPairOrigin origin;
}

/// One explicit series conflict rule with an effective date window.
class SeriesConflictRule {
  const SeriesConflictRule({
    required this.effectiveFrom,
    required this.state,
    this.effectiveThrough,
  });

  /// Inclusive start date, 'YYYY-MM-DD' (Asia/Shanghai).
  final String effectiveFrom;

  /// Inclusive end date, 'YYYY-MM-DD', or null for unbounded.
  final String? effectiveThrough;

  final ConflictPairState state;
}

/// An account-scoped, immutable snapshot of the user's explicit conflict
/// relations and series rules.
///
/// Produced by the data layer (e.g. `ConflictService.relationSnapshot`) and
/// consumed by [ScheduleConflictProjection.resolve]. The resolver never
/// persists derived pairs — it only reads this snapshot.
class ScheduleConflictRelationSnapshot {
  const ScheduleConflictRelationSnapshot({
    this.occurrenceByPair = const {},
    this.seriesByPair = const {},
  });

  /// Occurrence relations keyed by canonical pair key
  /// (see [ScheduleConflictProjection.occurrenceKey]).
  final Map<String, ConflictPairState> occurrenceByPair;

  /// Series rules keyed by canonical series pair key
  /// (see [ScheduleConflictProjection.seriesKey]), each entry carrying its
  /// effective date window.
  final Map<String, List<SeriesConflictRule>> seriesByPair;
}

/// Pair-level conflict derivation shared by the week grid, the conflict
/// editor, and the Agent `get_conflicts` tool.
///
/// Precedence (high → low):
///
/// 1. Explicit occurrence relation (`conflict`/`no_conflict`) in the snapshot.
/// 2. Explicit series rule effective at the pair's occurrence date.
/// 3. Timed overlap → derived `conflict`.
/// 4. Otherwise → derived `no_conflict`.
///
/// Consequences:
/// - A plain timed overlap defaults to conflict.
/// - An explicit `no_conflict` suppresses a derived overlap.
/// - An explicit `conflict` stays valid even without an overlap.
/// - All-day items never auto-conflict just from sharing a date.
/// - CalendarEvent and PlanBlock pairs use the same rules.
/// - With three overlapping items each pair resolves independently; one
///   `no_conflict` pair does not affect the other two.
///
/// Derived overlap lives only in this query/display-layer projection: no
/// `schedule_relations` rows are ever inserted here. Removing an explicit
/// relation returns the pair to derived behavior.
class ScheduleConflictProjection {
  const ScheduleConflictProjection._();

  /// Resolves every unordered pair of [items] against [snapshot].
  ///
  /// The result is deterministic (sorted by pair) and contains one entry per
  /// distinct pair of items (a pair of an item with itself is skipped).
  /// This full-pair form is retained for the two-item editor-preview and unit
  /// tests; range-bounded consumers should use [resolveCandidates].
  static List<ResolvedConflictPair> resolve(
    List<ScheduleGridItem> items,
    ScheduleConflictRelationSnapshot snapshot,
  ) {
    final pairs = <ResolvedConflictPair>[];
    for (var i = 0; i < items.length; i++) {
      for (var j = i + 1; j < items.length; j++) {
        final a = items[i];
        final b = items[j];
        if (a.id == b.id) continue;
        pairs.add(_resolvePair(a, b, snapshot));
      }
    }
    return _sorted(pairs);
  }

  /// Resolves the pair formed by exactly two items, or null when they share an
  /// id. Unit-test and editor-preview entry point for a single pair.
  static ResolvedConflictPair? resolvePair(
    ScheduleGridItem a,
    ScheduleGridItem b,
    ScheduleConflictRelationSnapshot snapshot,
  ) {
    if (a.id == b.id) return null;
    return _resolvePair(a, b, snapshot);
  }

  /// Builds a bounded, keyed conflict projection over [items] intersected with
  /// the inclusive-exclusive display range `[from, throughExclusive)`.
  ///
  /// Only *meaningful* candidate pairs are materialized:
  /// 1. timed interval overlap (via a start-sorted sweep — O(n log n) rather
  ///    than O(n²) pair construction), always bounded to the range window;
  /// 2. explicit occurrence relations (added even when the items do not
  ///    overlap, so a non-overlapping explicit `conflict` still surfaces);
  /// 3. member combinations that may hit an explicit series rule.
  ///
  /// The timed-overlap sweep is ALWAYS range-bounded. The explicit relation /
  /// series-rule tiers never emit a `noConflict` pair for unrelated historical
  /// items. When [includeExplicitOutOfWindow] is true (conflict-reporting
  /// consumers: get_conflicts, get_schedule conflict state), an explicit
  /// occurrence/series relation is NOT discarded solely because one member's
  /// occurrence lies outside the `[from, throughExclusive)` window — so an
  /// explicit conflict between an in-window item and an out-of-window item is
  /// still reported. When false (the week grid's "selected-week only" stance),
  /// only in-window items are considered even for explicit relations.
  ///
  /// All-day items follow the existing product rules (never auto-conflict from
  /// a shared date). Each candidate resolves with the established precedence:
  /// occurrence override > series rule > derived overlap > no conflict.
  static ConflictProjectionResult resolveCandidates(
    List<ScheduleGridItem> items,
    ScheduleConflictRelationSnapshot snapshot, {
    required DateTime from,
    required DateTime throughExclusive,
    bool includeExplicitOutOfWindow = false,
  }) {
    // Build the full, deduped item pool AND the in-window subset.
    final allKeyed = <ScheduleItemKey, ScheduleGridItem>{};
    final inWindowKeyed = <ScheduleItemKey, ScheduleGridItem>{};
    for (final item in items) {
      final key = (kind: item.relationKind, id: item.id);
      if (allKeyed.containsKey(key)) continue;
      allKeyed[key] = item;
      if (_intersects(item, from, throughExclusive)) {
        inWindowKeyed[key] = item;
      }
    }
    // The lookup pool for explicit-relation tiers: all items when reporting
    // cross-window relations, or only in-window items for the week grid.
    final lookupPool = includeExplicitOutOfWindow ? allKeyed : inWindowKeyed;
    final sorted = <ScheduleGridItem>[...lookupPool.values];

    final candidateKeys = <({int a, int b})>{};
    // Tier 1: timed interval overlap — start-sorted active-window sweep over
    // ONLY in-window timed items (indices are into [sorted], which — for the
    // non-reporting week grid — equals the in-window pool).
    final timed = inWindowKeyed.values.where((item) => !item.allDay).toList()
      ..sort((a, b) {
        final byStart = a.startAt!.compareTo(b.startAt!);
        return byStart != 0 ? byStart : a.id.compareTo(b.id);
      });
    var windowStart = 0;
    for (var i = 0; i < timed.length; i++) {
      final current = timed[i];
      while (windowStart < i &&
          !timed[windowStart].endAt!.isAfter(current.startAt!)) {
        windowStart++;
      }
      for (var j = windowStart; j < i; j++) {
        if (_timedOverlap(timed[j], current)) {
          candidateKeys.add((
            a: sorted.indexOf(timed[j]),
            b: sorted.indexOf(current),
          ));
        }
      }
    }

    // Tier 2 + 3: explicit occurrence relations and series-rule member pairs
    // (added even when the members do not overlap, and — when reporting — even
    // when one member is out-of-window).
    for (final ruleKey in snapshot.occurrenceByPair.keys) {
      final parsed = _parsePairKey(ruleKey);
      if (parsed == null) continue;
      final a = lookupPool[(kind: parsed.leftKind, id: parsed.leftId)];
      final b = lookupPool[(kind: parsed.rightKind, id: parsed.rightId)];
      if (a == null || b == null) continue;
      // A relation is a candidate only when at least one member is in-window.
      // When reporting (includeExplicitOutOfWindow), this permits an explicit
      // conflict between an in-window item and an out-of-window partner; when
      // not reporting, both are in-window already. Pairs where both members are
      // out-of-window are never reported (matches get_conflicts' range scope).
      if (!_intersects(a, from, throughExclusive) &&
          !_intersects(b, from, throughExclusive)) {
        continue;
      }
      candidateKeys.add((a: sorted.indexOf(a), b: sorted.indexOf(b)));
    }
    for (final ruleKey in snapshot.seriesByPair.keys) {
      final parsed = _parsePairKey(ruleKey);
      if (parsed == null) continue;
      final a = _seriesMember(lookupPool, parsed.leftKind, parsed.leftId);
      final b = _seriesMember(lookupPool, parsed.rightKind, parsed.rightId);
      if (a == null || b == null) continue;
      if (!_intersects(a, from, throughExclusive) &&
          !_intersects(b, from, throughExclusive)) {
        continue;
      }
      candidateKeys.add((a: sorted.indexOf(a), b: sorted.indexOf(b)));
    }

    // Resolve each candidate pair with the shared precedence.
    final pairs = <ResolvedConflictPair>[];
    for (final key in candidateKeys) {
      pairs.add(_resolvePair(sorted[key.a], sorted[key.b], snapshot));
    }
    pairs.sort((x, y) {
      final byLeft = _itemKey(x.left).id.compareTo(_itemKey(y.left).id);
      return byLeft != 0 ? byLeft : _itemKey(x.right).id.compareTo(_itemKey(y.right).id);
    });
    return ConflictProjectionResult(
      pairs: List.unmodifiable(pairs),
      candidatePairCount: pairs.length,
      conflictKeys: {
        for (final pair in pairs)
          if (pair.state == ConflictPairState.conflict)
            ...{_itemKey(pair.left), _itemKey(pair.right)},
      },
    );
  }

  static List<ResolvedConflictPair> _sorted(List<ResolvedConflictPair> pairs) {
    pairs.sort((x, y) {
      final byLeft = x.left.id.compareTo(y.left.id);
      return byLeft != 0 ? byLeft : x.right.id.compareTo(y.right.id);
    });
    return List.unmodifiable(pairs);
  }

  static ScheduleItemKey _itemKey(ScheduleGridItem item) =>
      (kind: item.relationKind, id: item.id);

  static ScheduleGridItem? _seriesMember(
    Map<ScheduleItemKey, ScheduleGridItem> keyed,
    String seriesType,
    String seriesId,
  ) {
    // A series rule references `course_series:<id>` for events. Find any
    // in-range item whose series identity matches.
    for (final item in keyed.values) {
      if (item.seriesType == seriesType && item.seriesId == seriesId) {
        return item;
      }
    }
    return null;
  }

  static _ParsedPairKey? _parsePairKey(String key) {
    final parts = key.split('|');
    if (parts.length != 2) return null;
    final a = parts[0].split(':');
    final b = parts[1].split(':');
    if (a.length != 2 || b.length != 2) return null;
    return (
      leftKind: a[0],
      leftId: a[1],
      rightKind: b[0],
      rightId: b[1],
    );
  }

  static bool _intersects(
    ScheduleGridItem item,
    DateTime from,
    DateTime throughExclusive,
  ) {
    if (item.allDay) {
      final start = item.startDate!;
      final end = item.endDateExclusive!;
      return start.isBefore(throughExclusive) && end.isAfter(from);
    }
    final start = item.startAt!;
    final end = item.endAt ?? start;
    return start.isBefore(throughExclusive) && end.isAfter(from);
  }

  static ResolvedConflictPair _resolvePair(
    ScheduleGridItem a,
    ScheduleGridItem b,
    ScheduleConflictRelationSnapshot snapshot,
  ) {
    // 1. Explicit occurrence relation wins.
    final occurrence = snapshot.occurrenceByPair[
        occurrenceKey(a.relationKind, a.id, b.relationKind, b.id)];
    if (occurrence != null) {
      return ResolvedConflictPair(
        left: a,
        right: b,
        state: occurrence,
        origin: ConflictPairOrigin.explicitOccurrence,
      );
    }

    // 2. Effective series rule.
    final seriesState = _effectiveSeriesState(a, b, snapshot);
    if (seriesState != null) {
      return ResolvedConflictPair(
        left: a,
        right: b,
        state: seriesState,
        origin: ConflictPairOrigin.explicitSeries,
      );
    }

    // 3. Timed overlap → derived conflict.
    if (_timedOverlap(a, b)) {
      return ResolvedConflictPair(
        left: a,
        right: b,
        state: ConflictPairState.conflict,
        origin: ConflictPairOrigin.derivedOverlap,
      );
    }

    // 4. Otherwise derived no-conflict.
    return ResolvedConflictPair(
      left: a,
      right: b,
      state: ConflictPairState.noConflict,
      origin: ConflictPairOrigin.derivedOverlap,
    );
  }

  /// The effective series rule state for the pair, or null when either item
  /// lacks a stable series identity or no rule is in effect at the pair's
  /// occurrence date.
  static ConflictPairState? _effectiveSeriesState(
    ScheduleGridItem a,
    ScheduleGridItem b,
    ScheduleConflictRelationSnapshot snapshot,
  ) {
    final aType = a.seriesType;
    final aId = a.seriesId;
    final bType = b.seriesType;
    final bId = b.seriesId;
    if (aType == null || aId == null || bType == null || bId == null) {
      return null;
    }
    final rules = snapshot.seriesByPair[seriesKey(aType, aId, bType, bId)];
    if (rules == null || rules.isEmpty) return null;
    final date = _dateKey(
      _occurrenceDate(a).isBefore(_occurrenceDate(b))
          ? _occurrenceDate(a)
          : _occurrenceDate(b),
    );
    for (final rule in rules) {
      if (rule.effectiveFrom.compareTo(date) <= 0 &&
          (rule.effectiveThrough == null ||
              rule.effectiveThrough!.compareTo(date) >= 0)) {
        return rule.state;
      }
    }
    return null;
  }

  static bool _timedOverlap(ScheduleGridItem a, ScheduleGridItem b) {
    if (a.allDay || b.allDay) return false;
    return a.startAt!.isBefore(b.endAt!) && b.startAt!.isBefore(a.endAt!);
  }

  static DateTime _occurrenceDate(ScheduleGridItem item) {
    if (item.allDay) return item.startDate!;
    final start = item.startAt!;
    return DateTime(start.year, start.month, start.day);
  }

  static String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  static String _pairKey(String aKind, String aId, String bKind, String bId) {
    final a = '$aKind:$aId';
    final b = '$bKind:$bId';
    return a.compareTo(b) <= 0 ? '$a|$b' : '$b|$a';
  }

  /// Canonical occurrence pair key: two `kind:id` tokens joined by `|`, the
  /// smaller first. Kinds use the storage convention (`event`,
  /// `plan_block`) so the key matches `schedule_relations` rows.
  static String occurrenceKey(
    String aKind,
    String aId,
    String bKind,
    String bId,
  ) =>
      _pairKey(aKind, aId, bKind, bId);

  /// Canonical series pair key: two `seriesType:seriesId` tokens joined by
  /// `|`, the smaller first.
  static String seriesKey(
    String aType,
    String aId,
    String bType,
    String bId,
  ) =>
      _pairKey(aType, aId, bType, bId);
}
