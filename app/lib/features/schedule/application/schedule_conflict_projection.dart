import '../domain/schedule_grid_item.dart';

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
    pairs.sort((x, y) {
      final byLeft = x.left.id.compareTo(y.left.id);
      return byLeft != 0 ? byLeft : x.right.id.compareTo(y.right.id);
    });
    return List.unmodifiable(pairs);
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
