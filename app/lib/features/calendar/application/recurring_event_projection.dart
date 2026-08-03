import '../../../core/database/app_database.dart';
import '../domain/calendar_event_locator.dart';
import '../domain/recurrence_expander.dart';
import '../domain/recurrence_rule.dart';
import 'recurrence_service.dart';

/// How a range projection is consumed.
///
/// - [display] is the normal read view used by `get_schedule` / the weekly
///   timetable: it excludes cancelled, hidden, skipped and deleted targets.
/// - [management] is the explicit administrative read that surfaces
///   lifecycle-managed targets, filtered to the requested [lifecycleStates].
enum RecurringProjectionMode { display, management }

/// A projected, reachable recurring personal-schedule target.
///
/// Each target carries an opaque local [locator] bound into the model-facing
/// layers, a safe [title] and [lifecycleState], and the [availableScopes]
/// that a caller may operate on. The locator never leaks the raw series id,
/// occurrence key, or DB id.
sealed class ProjectedRecurringTarget {
  const ProjectedRecurringTarget({
    required this.locator,
    required this.title,
    required this.lifecycleState,
    required this.availableScopes,
  });

  final CalendarEventLocator locator;
  final String title;
  final String lifecycleState;
  final List<String> availableScopes;

  bool get isOccurrence => this is ProjectedRecurringOccurrence;
  bool get isSeries => this is ProjectedRecurringSeries;

  RecurringSeriesLocator get seriesLocator =>
      locator is RecurringSeriesLocator
      ? locator as RecurringSeriesLocator
      : RecurringSeriesLocator(
          seriesId: (locator as RecurringOccurrenceLocator).seriesId,
        );
}

/// One concrete, range-expanded occurrence of a recurring series.
///
/// [occurrence] carries the composed (override-aware) occurrence value. The
/// original recurrence identity is retained even when a time override moved the
/// occurrence to a different effective time. [deletedAt] is set when the
/// occurrence's exception row was soft-deleted.
class ProjectedRecurringOccurrence extends ProjectedRecurringTarget {
  const ProjectedRecurringOccurrence({
    required this.occurrence,
    required super.locator,
    required super.title,
    required super.lifecycleState,
    required super.availableScopes,
    this.deletedAt,
  });

  final RecurringOccurrence occurrence;
  final int? deletedAt;

  String get seriesId => occurrence.seriesId;
  String get occurrenceKey => occurrence.occurrenceKey;
}

/// A whole recurring series returned from query-only management search.
///
/// Carries the series row and has no fabricated occurrence time — a caller
/// never gets an arbitrary occurrence when no date was supplied.
class ProjectedRecurringSeries extends ProjectedRecurringTarget {
  const ProjectedRecurringSeries({
    required this.series,
    required super.locator,
    required super.title,
    required super.lifecycleState,
    required super.availableScopes,
  });

  final CalendarEventSery series;

  String get seriesId => series.id;
}

/// Names for the lifecycle states a projection may emit. `deleted` refers to a
/// soft-deleted series (series.deletedAt != null) or a soft-deleted occurrence
/// exception (exception.deletedAt != null).
const Set<String> _displayExcluded = {'cancelled', 'hidden', 'skipped', 'deleted'};

/// Read-only, account-scoped projection of recurring personal series.
///
/// This class NEVER writes to `calendar_events` or any other table. It expands
/// recurrence ranges in memory, merges stored exceptions, and returns
/// occurrence/series targets bound to reversible local locators.
class RecurringEventProjector {
  RecurringEventProjector({required this.service});

  final RecurrenceService service;

  /// Projects all occurrences of the bound account's recurring series that
  /// fall within the inclusive [from]..[through] range.
  ///
  /// Bounds are delegated to [expandRecurrence], so a reversed range, a range
  /// spanning more than 366 inclusive days, or a range generating more than
  /// 1000 occurrences throws [RecurrenceLimitError] instead of returning a
  /// partial list.
  ///
  /// - [display]: excludes cancelled, hidden, skipped and deleted occurrences.
  /// - [management]: keeps only the requested [lifecycleStates] (all states
  ///   when [lifecycleStates] is empty) and retains the original occurrence
  ///   identity after a time override.
  Future<List<ProjectedRecurringOccurrence>> projectRange({
    required DateTime from,
    required DateTime through,
    required RecurringProjectionMode mode,
    Set<String> lifecycleStates = const {},
  }) async {
    final seriesRows = await service.allSeries();
    final stateFilter = _stateFilterFor(mode, lifecycleStates);
    final projected = <ProjectedRecurringOccurrence>[];

    // The entire query must succeed atomically: if expanding every intersecting
    // series would generate more than 1000 occurrence targets, fail rather than
    // return a partial list. Single series are already bounded to 366 days by
    // the expander, so this aggregate guard is the cross-series occurrence cap.
    final originalsRaw = _expandOriginals(seriesRows, from, through);
    if (originalsRaw.length > 1000) {
      throw const RecurrenceLimitError('query exceeds occurrence limit');
    }

    for (final series in seriesRows) {
      if (!_seriesBoundsCouldIntersect(series, from, through)) continue;

      final rule = RecurrenceRule.decode(series.recurrenceJson);
      final originals = expandRecurrence(
        rule,
        from: from,
        through: through,
      ).where((value) => service.withinSeriesBounds(series, value)).toList();
      if (originals.isEmpty) continue;

      final exceptions = {
        for (final row in await service.exceptionRows(series.id))
          row.occurrenceKey: row,
      };
      for (final original in originals) {
        final exception = exceptions[occurrenceKey(series.id, original)];
        if (exception?.orphaned == true) continue;

        final composed = service.composeOccurrence(series, original, exception);
        final state = _occurrenceState(series, exception);
        if (!stateFilter(state)) continue;

        projected.add(
          ProjectedRecurringOccurrence(
            occurrence: composed,
            locator: RecurringOccurrenceLocator(
              seriesId: series.id,
              occurrenceKey: occurrenceKey(series.id, original),
            ),
            title: composed.title,
            lifecycleState: state,
            availableScopes: const ['only_this', 'this_and_future', 'whole_series'],
            deletedAt: exception?.deletedAt,
          ),
        );
      }
    }

    projected.sort((a, b) {
      final byTime = a.occurrence.originalStart.compareTo(b.occurrence.originalStart);
      if (byTime != 0) return byTime;
      return a.title.compareTo(b.title);
    });
    return projected;
  }

  /// Query-only title search across the bound account's recurring series.
  ///
  /// Returns one [ProjectedRecurringSeries] per matching title with
  /// `availableScopes == ['whole_series']`. It never fabricates an occurrence
  /// time; when no date was supplied there is no single occurrence to pick, so
  /// the whole series is the only meaningful target.
  Future<List<ProjectedRecurringSeries>> searchSeries({
    required String query,
    Set<String> lifecycleStates = const {},
  }) async {
    final seriesRows = await service.allSeries();
    final folded = query.trim().toLowerCase();
    final stateFilter = _stateFilterFor(
      RecurringProjectionMode.management,
      lifecycleStates,
    );
    final results = <ProjectedRecurringSeries>[];

    for (final series in seriesRows) {
      if (folded.isNotEmpty && !series.title.trim().toLowerCase().contains(folded)) {
        continue;
      }
      final state = _seriesState(series);
      if (!stateFilter(state)) continue;
      results.add(
        ProjectedRecurringSeries(
          series: series,
          locator: RecurringSeriesLocator(seriesId: series.id),
          title: series.title,
          lifecycleState: state,
          availableScopes: const ['whole_series'],
        ),
      );
    }

    results.sort((a, b) {
      final byTitle = a.title.compareTo(b.title);
      return byTitle != 0 ? byTitle : a.seriesId.compareTo(b.seriesId);
    });
    return results;
  }

  /// Expands every intersecting series' originals within [from]..[through],
  /// honoring each series' effective bounds. Throws [RecurrenceLimitError] for
  /// an out-of-bounds range; the caller applies the atom 1000-occurrence guard.
  List<DateTime> _expandOriginals(
    List<CalendarEventSery> seriesRows,
    DateTime from,
    DateTime through,
  ) {
    final all = <DateTime>[];
    for (final series in seriesRows) {
      if (!_seriesBoundsCouldIntersect(series, from, through)) continue;
      final rule = RecurrenceRule.decode(series.recurrenceJson);
      all.addAll(
        expandRecurrence(
          rule,
          from: from,
          through: through,
        ).where((value) => service.withinSeriesBounds(series, value)),
      );
    }
    return all;
  }

  bool Function(String state) _stateFilterFor(
    RecurringProjectionMode mode,
    Set<String> lifecycleStates,
  ) {
    if (mode == RecurringProjectionMode.display) {
      return (state) => !_displayExcluded.contains(state);
    }
    if (lifecycleStates.isEmpty) return (_) => true;
    return lifecycleStates.contains;
  }

  /// Whether the series' stored effective bounds could overlap the inclusive
  /// [from]..[through] range, so we can skip clearly-disjoint series cheaply.
  bool _seriesBoundsCouldIntersect(
    CalendarEventSery series,
    DateTime from,
    DateTime through,
  ) {
    final rangeStart = dateOnly(from);
    final rangeEnd = dateOnly(through);
    final effFrom = series.effectiveFrom == null
        ? null
        : DateTime.parse(series.effectiveFrom!);
    final effThrough = series.effectiveThrough == null
        ? null
        : DateTime.parse(series.effectiveThrough!);
    if (effThrough != null && effThrough.isBefore(rangeStart)) return false;
    if (effFrom != null && effFrom.isAfter(rangeEnd)) return false;
    return true;
  }

  String _occurrenceState(
    CalendarEventSery series,
    CalendarEventOccurrenceException? exception,
  ) {
    if (exception?.deletedAt != null) return 'deleted';
    final overrideStatus = exception?.status;
    if (overrideStatus != null && overrideStatus != series.status) {
      return overrideStatus;
    }
    return _seriesState(series);
  }

  String _seriesState(CalendarEventSery series) {
    if (series.deletedAt != null) return 'deleted';
    return series.status;
  }
}