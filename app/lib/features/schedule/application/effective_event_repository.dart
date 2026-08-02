import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../../core/database/app_database.dart';
import '../../tasks/domain/plan_block.dart';
import '../../tasks/domain/task.dart';
import '../domain/overlap_engine.dart';
import '../domain/schedule_grid_item.dart';
import 'conflict_service.dart';
import 'schedule_conflict_projection.dart';

enum AttendancePolicy { unknown, mustGo, gamble, skip }

enum AttendanceDecision { undecided, go, skip }

enum AttendanceOutcome { unknown, attended, skipped }

enum ListeningMode { unknown, listen, notListen }

extension AttendancePolicyStorage on AttendancePolicy {
  String get storage => switch (this) {
    AttendancePolicy.unknown => 'unknown',
    AttendancePolicy.mustGo => 'must_go',
    AttendancePolicy.gamble => 'gamble',
    AttendancePolicy.skip => 'skip',
  };
}

extension AttendanceDecisionStorage on AttendanceDecision {
  String get storage => name;
}

extension AttendanceOutcomeStorage on AttendanceOutcome {
  String get storage => name;
}

extension ListeningModeStorage on ListeningMode {
  String get storage => switch (this) {
    ListeningMode.unknown => 'unknown',
    ListeningMode.listen => 'listen',
    ListeningMode.notListen => 'not_listen',
  };
}

AttendancePolicy attendancePolicyFromStorage(String? value) => switch (value) {
  'must_go' => AttendancePolicy.mustGo,
  'gamble' => AttendancePolicy.gamble,
  'skip' => AttendancePolicy.skip,
  _ => AttendancePolicy.unknown,
};

AttendanceDecision attendanceDecisionFromStorage(String? value) =>
    switch (value) {
      'go' => AttendanceDecision.go,
      'skip' => AttendanceDecision.skip,
      _ => AttendanceDecision.undecided,
    };

AttendanceOutcome attendanceOutcomeFromStorage(String? value) =>
    switch (value) {
      'attended' => AttendanceOutcome.attended,
      'skipped' => AttendanceOutcome.skipped,
      _ => AttendanceOutcome.unknown,
    };

ListeningMode listeningModeFromStorage(String? value) => switch (value) {
  'listen' => ListeningMode.listen,
  'not_listen' => ListeningMode.notListen,
  _ => ListeningMode.unknown,
};

class EffectiveEventRecord {
  const EffectiveEventRecord({
    required this.source,
    required this.attendance,
    required this.attendanceDecision,
    required this.attendanceOutcome,
    required this.listeningMode,
    required this.displayTitle,
    required this.displayLocation,
    required this.importance,
    required this.hidden,
    this.courseSeries,
    this.attendanceNote,
    this.listeningNote,
    this.color,
    this.foregroundPriority,
    this.userNotes,
    this.tagsJson,
    this.effectiveStartAt,
    this.effectiveEndAt,
  });

  /// The immutable imported row; a whole-day move never rewrites it. When
  /// [effectiveStartAt]/[effectiveEndAt] are present, display and Agent
  /// detail should show those instead of `source.startAt`/`source.endAt`.
  final CalendarEvent source;

  /// The moved display start (Beijing local) when a whole-day JW course move
  /// applies to [source]; null when the event is not moved. Hour/minute/second
  /// and duration are unchanged; only the Beijing calendar date is shifted.
  final DateTime? effectiveStartAt;

  /// The moved display end (Beijing local), shifted by the same calendar-date
  /// delta as [effectiveStartAt].
  final DateTime? effectiveEndAt;
  final CourseSery? courseSeries;
  final AttendancePolicy attendance;
  final AttendanceDecision attendanceDecision;
  final AttendanceOutcome attendanceOutcome;
  final ListeningMode listeningMode;
  final String displayTitle;
  final String? displayLocation;
  final String importance;
  final bool hidden;
  final String? attendanceNote;
  final String? listeningNote;
  final String? color;
  final int? foregroundPriority;
  final String? userNotes;
  final String? tagsJson;
}

class EffectiveEventRepository {
  EffectiveEventRepository(this.database, {required this.accountId});

  final AppDatabase database;
  final String accountId;

  /// Test-observable instrumentation. The week page and the range-bounded
  /// Agent tools drive [conflictsForItems] once per consumer range; this
  /// proves the projection is bounded and never duplicated repository-wide.
  @visibleForTesting
  static int conflictsForItemsCalls = 0;

  /// The candidate-pair count from the most recent [conflictsForItems] call.
  @visibleForTesting
  static int lastCandidatesForItems = 0;

  /// The number of times the legacy full projection was invoked. The week page
  /// must not call it anymore (the bounded path replaces it); tests assert it
  /// stays 0 so a duplicate repository-wide projection cannot regress.
  @visibleForTesting
  static int resolvedConflictIdsForCalls = 0;

  /// The effective events for the account: overlay-resolved, hidden rows
  /// excluded, whole-day JW course moves projected. This stream is ONLY about
  /// loading effective events — it does NOT run any conflict projection.
  /// Consumers (the week page, Agent tools) filter to their own range and run
  /// ONE bounded projection over that range via [conflictsForItems].
  Stream<List<EffectiveEvent>> watchDisplayEvents() => database
      .customSelect(
        '''
SELECT
  e.id,
  e.source,
  COALESCE(eo.display_title, so.display_title, e.title) AS display_title,
  COALESCE(eo.display_location, so.display_location, e.location_name)
    AS display_location,
  COALESCE(eo.importance, so.importance, e.importance) AS importance,
  COALESCE(eo.hidden, so.hidden, 0) AS hidden,
  COALESCE(eo.color, so.color, e.color) AS color,
  COALESCE(eo.foreground_priority, so.foreground_priority, 0)
    AS foreground_priority,
  -- The conflict warning is derived by ScheduleConflictProjection (Dart),
  -- not by SQL: overlaps default to conflict and explicit relations override.
  0 AS has_confirmed_conflict,
  e.type,
  e.status,
  e.start_at,
  e.end_at,
  e.all_day,
  e.start_date,
  e.end_date_exclusive,
  cs.id AS course_series_id
FROM calendar_events e
LEFT JOIN course_series cs
  ON cs.account_id = e.account_id
  AND cs.source = e.source
  AND cs.external_id = e.source_series_external_id
LEFT JOIN user_overlays eo
  ON eo.account_id = e.account_id AND eo.event_id = e.id
LEFT JOIN user_overlays so
  ON so.account_id = e.account_id AND so.course_series_id = cs.id
WHERE e.account_id = ?
  AND e.deleted_at IS NULL
  AND e.status NOT IN ('cancelled', 'hidden', 'skipped')
  AND (
    e.source = 'user'
    OR EXISTS (
      SELECT 1
      FROM source_records sr
      WHERE sr.account_id = e.account_id
        AND sr.local_entity_id = e.id
        AND sr.presence <> 'missing_within_scope'
    )
  )
ORDER BY COALESCE(e.start_at, 0), COALESCE(e.start_date, ''), e.id
''',
        variables: [Variable.withString(accountId)],
        readsFrom: {
          database.calendarEvents,
          database.userOverlays,
          database.courseSeries,
          database.sourceRecords,
          database.scheduleRelations,
          database.scheduleRelationRules,
          database.planBlocks,
          database.tasks,
          database.jwDayMoves,
        },
      )
      .watch()
      .asyncMap((rows) async {
        final moves = await _movesBySourceDate();
        return [
          for (final row in rows)
            if (row.read<int>('hidden') == 0)
              _displayEvent(row, hasConfirmedConflict: false, moves: moves),
        ];
      });

  /// Whether the single event [eventId] participates in a conflict, derived by
  /// a bounded projection over ONLY the target plus its overlapping candidates
  /// (never all retained history). Used by `get_event_details` to avoid
  /// loading and projecting the full account history.
  Future<bool> eventHasConflict(String eventId) async {
    final target = await byId(eventId);
    var events = [_recordToEffectiveEvent(target)];
    final overlapping = await overlappingRecords(eventId);
    for (final record in overlapping) {
      if (record.source.id == eventId) continue;
      events.add(_recordToEffectiveEvent(record));
    }
    var from = events.expand(_startInstantsOf).reduce(
      (a, b) => a.isBefore(b) ? a : b,
    );
    var through = events.expand(_endInstantsOf).reduce(
      (a, b) => a.isAfter(b) ? a : b,
    );
    final result = await conflictsForItems(
      events,
      from: DateTime(from.year, from.month, from.day),
      throughExclusive: DateTime(through.year, through.month, through.day)
          .add(const Duration(days: 1)),
    );
    return result.isConflict('event', eventId);
  }

  EffectiveEvent _recordToEffectiveEvent(EffectiveEventRecord record) {
    final event = record.source;
    if (event.allDay) {
      return EffectiveEvent.allDay(
        id: event.id,
        title: record.displayTitle,
        startDate: DateTime.parse(event.startDate!),
        endDateExclusive: DateTime.parse(event.endDateExclusive!),
        courseSeriesId: record.courseSeries?.id,
        location: record.displayLocation,
        eventType: event.type,
        hasConfirmedConflict: false,
      );
    }
    final start = record.effectiveStartAt ?? _beijingDateTime(event.startAt!);
    final end = record.effectiveEndAt ?? _beijingDateTime(event.endAt!);
    return EffectiveEvent.timed(
      id: event.id,
      title: record.displayTitle,
      startAt: start,
      endAt: end,
      courseSeriesId: record.courseSeries?.id,
      location: record.displayLocation,
      eventType: event.type,
      hasConfirmedConflict: false,
    );
  }

  static Iterable<DateTime> _startInstantsOf(EffectiveEvent e) sync* {
    if (e.allDay) {
      yield e.startDate!;
    } else if (e.startAt != null) {
      yield e.startAt!;
    }
  }

  static Iterable<DateTime> _endInstantsOf(EffectiveEvent e) sync* {
    if (e.allDay) {
      yield e.endDateExclusive!;
    } else if (e.endAt != null) {
      yield e.endAt!;
    }
  }

  Future<List<EffectiveEventRecord>> overlappingRecords(String eventId) async {
    final target = await byId(eventId);
    if (!await _isPresent(target.source)) return const [];
    final moves = await _movesBySourceDate();
    final candidates =
        await (database.select(database.calendarEvents)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.deletedAt.isNull() &
                  row.status.isNotIn(['cancelled', 'hidden', 'skipped']),
            ))
            .get();
    final visible = <CalendarEvent>[];
    for (final candidate in candidates) {
      if (!_overlaps(target.source, candidate, moves)) continue;
      if (!await _isPresent(candidate)) continue;
      visible.add(candidate);
    }
    visible.sort((a, b) => a.id.compareTo(b.id));
    return Future.wait(visible.map((candidate) => byId(candidate.id)));
  }

  Stream<List<EffectiveEventRecord>> watchAll() => database
      .customSelect(
        'SELECT id FROM calendar_events '
        'WHERE account_id = ? AND deleted_at IS NULL '
        'ORDER BY COALESCE(start_at, 0), COALESCE(start_date, \'\'), id',
        variables: [Variable.withString(accountId)],
        readsFrom: {
          database.calendarEvents,
          database.userOverlays,
          database.courseSeries,
        },
      )
      .watch()
      .asyncMap(
        (rows) => Future.wait(rows.map((row) => byId(row.read<String>('id')))),
      );

  Future<EffectiveEventRecord> byId(String eventId) async {
    final event =
        await (database.select(database.calendarEvents)..where(
              (row) => row.id.equals(eventId) & row.accountId.equals(accountId),
            ))
            .getSingleOrNull();
    if (event == null) {
      throw StateError('calendar event not found');
    }

    final eventOverlay =
        await (database.select(database.userOverlays)..where(
              (row) =>
                  row.accountId.equals(accountId) & row.eventId.equals(eventId),
            ))
            .getSingleOrNull();
    CourseSery? series;
    UserOverlay? seriesOverlay;
    if (event.sourceSeriesExternalId != null) {
      series =
          await (database.select(database.courseSeries)..where(
                (row) =>
                    row.accountId.equals(accountId) &
                    row.source.equals(event.source) &
                    row.externalId.equals(event.sourceSeriesExternalId!),
              ))
              .getSingleOrNull();
      if (series != null) {
        seriesOverlay =
            await (database.select(database.userOverlays)..where(
                  (row) =>
                      row.accountId.equals(accountId) &
                      row.courseSeriesId.equals(series!.id),
                ))
                .getSingleOrNull();
      }
    }

    T? choose<T>(T? Function(UserOverlay overlay) read) => eventOverlay == null
        ? (seriesOverlay == null ? null : read(seriesOverlay))
        : read(eventOverlay) ??
              (seriesOverlay == null ? null : read(seriesOverlay));

    final moves = await _movesBySourceDate();
    final effectiveStartAt = _shiftedStartAt(event, moves);
    return EffectiveEventRecord(
      source: event,
      effectiveStartAt: effectiveStartAt,
      effectiveEndAt: _shiftedEndAt(event, effectiveStartAt),
      courseSeries: series,
      attendance: attendancePolicyFromStorage(
        choose((overlay) => overlay.attendancePolicy) ??
            _defaultAttendance(event.type).storage,
      ),
      attendanceDecision: attendanceDecisionFromStorage(
        eventOverlay?.attendanceDecision,
      ),
      attendanceOutcome: attendanceOutcomeFromStorage(
        eventOverlay?.attendanceOutcome,
      ),
      listeningMode: listeningModeFromStorage(
        choose((overlay) => overlay.listeningMode),
      ),
      displayTitle: choose((overlay) => overlay.displayTitle) ?? event.title,
      displayLocation:
          choose((overlay) => overlay.displayLocation) ?? event.locationName,
      importance: choose((overlay) => overlay.importance) ?? event.importance,
      hidden: choose((overlay) => overlay.hidden) ?? false,
      attendanceNote: choose((overlay) => overlay.attendanceNote),
      listeningNote: choose((overlay) => overlay.listeningNote),
      color: choose((overlay) => overlay.color) ?? event.color,
      foregroundPriority: choose((overlay) => overlay.foregroundPriority),
      userNotes: choose((overlay) => overlay.userNotes),
      tagsJson: choose((overlay) => overlay.tagsJson) ?? event.tagsJson,
    );
  }

  AttendancePolicy _defaultAttendance(String eventType) =>
      eventType == 'exam' || eventType == 'second_class'
      ? AttendancePolicy.mustGo
      : AttendancePolicy.unknown;

  EffectiveEvent _displayEvent(
    QueryRow row, {
    required bool hasConfirmedConflict,
    Map<String, String> moves = const {},
  }) {
    final importance = switch (row.read<String>('importance')) {
      'low' => EventImportance.low,
      'high' => EventImportance.high,
      'critical' => EventImportance.critical,
      _ => EventImportance.normal,
    };
    final id = row.read<String>('id');
    final title = row.read<String>('display_title');
    final location = row.readNullable<String>('display_location');
    final courseSeriesId = row.readNullable<String>('course_series_id');
    final eventType = row.read<String>('type');
    if (row.read<int>('all_day') != 0) {
      return EffectiveEvent.allDay(
        id: id,
        title: title,
        startDate: DateTime.parse(row.read<String>('start_date')),
        endDateExclusive: DateTime.parse(
          row.read<String>('end_date_exclusive'),
        ),
        courseSeriesId: courseSeriesId,
        location: location,
        importance: importance,
        eventType: eventType,
        foregroundPriority: row.read<int>('foreground_priority'),
        color: row.readNullable<String>('color'),
        hasConfirmedConflict: hasConfirmedConflict,
      );
    }
    // Whole-day moves are projected here: when a move record's source date
    // equals the RAW Beijing date of an ELIGIBLE course event (source ==
    // ustc_jw, type == course, timed), the display time shifts to the target
    // date with the same hour/minute/second and duration. Exams, second-class,
    // personal and all-day events never move, and the raw start_at/end_at are
    // never rewritten.
    final startAt = _beijingDateTime(row.read<int>('start_at'));
    final endAt = _beijingDateTime(row.read<int>('end_at'));
    final movable =
        row.read<String>('source') == 'ustc_jw' &&
        row.read<String>('type') == 'course';
    final shiftedStart = movable
        ? (_shifted(startAt, moves) ?? startAt)
        : startAt;
    final shiftedEnd = shiftedStart == startAt
        ? endAt
        : shiftedStart.add(endAt.difference(startAt));
    return EffectiveEvent.timed(
      id: id,
      title: title,
      startAt: shiftedStart,
      endAt: shiftedEnd,
      courseSeriesId: courseSeriesId,
      location: location,
      isInactivePreview: row.read<String>('status') == 'tentative',
      importance: importance,
      eventType: eventType,
      foregroundPriority: row.read<int>('foreground_priority'),
      color: row.readNullable<String>('color'),
      hasConfirmedConflict: hasConfirmedConflict,
    );
  }

  /// Builds the effective [ScheduleGridItem] set for the account: the caller's
  /// [events] (already effective, overlay-resolved) plus the account's approved
  /// non-deleted plan blocks. Only the caller's selected items are combined;
  /// the repository never re-filters history.
  Future<List<ScheduleGridItem>> _effectiveGridItems(
    List<EffectiveEvent> events,
  ) async {
    final items = <ScheduleGridItem>[
      for (final event in events) ScheduleGridItem.fromEvent(event),
    ];
    final planBlocks =
        await (database.select(database.planBlocks)..where(
              (row) =>
                  row.accountId.equals(accountId) & row.deletedAt.isNull(),
            ))
            .get();
    if (planBlocks.isNotEmpty) {
      final tasks = await (database.select(database.tasks)..where(
            (row) =>
                row.accountId.equals(accountId) & row.deletedAt.isNull(),
          ))
          .get();
      final tasksById = {for (final task in tasks) task.id: TaskItem.fromRow(task)};
      for (final blockRow in planBlocks) {
        final block = PlanBlockItem.fromRow(blockRow);
        if (!block.showsInWeekGrid) continue;
        final task = tasksById[block.taskId];
        if (task == null) continue;
        items.add(ScheduleGridItem.fromPlanBlock(block, task));
      }
    }
    return items;
  }

  /// Runs ONE bounded conflict projection over the caller's selected range.
  ///
  /// [events] must already be the consumer's query result (range-filtered or
  /// title-matched) — the repository does NOT load all history. Plan blocks
  /// are combined at the account's effective level by the repository (the
  /// query range is applied by [ScheduleConflictProjection.resolveCandidates]
  /// to the combined item set). Returns the keyed result so callers can stamp
  /// events and plan blocks with the same conflict id set without a second,
  /// duplicate full projection.
  ///
  /// This replaces the old repository-wide `resolvedConflictIdsFor` as the
  /// authority: overlaps default to conflict and explicit relations override.
  /// Derived pairs are never persisted.
  Future<ConflictProjectionResult> conflictsForItems(
    List<EffectiveEvent> events, {
    required DateTime from,
    required DateTime throughExclusive,
  }) async {
    conflictsForItemsCalls++;
    final items = await _effectiveGridItems(events);
    final snapshot =
        await ConflictService(database: database, accountId: accountId)
            .relationSnapshot();
    final result = ScheduleConflictProjection.resolveCandidates(
      items,
      snapshot,
      from: from,
      throughExclusive: throughExclusive,
    );
    lastCandidatesForItems = result.candidatePairCount;
    return result;
  }

  /// The full account-wide conflict projection. Kept for callers that need the
  /// historical pre-range pair set; range-bounded consumers must use
  /// [conflictsForItems] instead so history does not grow the projection.
  @Deprecated('Use conflictsForItems with an explicit display range.')
  Future<Set<String>> resolvedConflictIdsFor(List<EffectiveEvent> events) async {
    resolvedConflictIdsForCalls++;
    final items = await _effectiveGridItems(events);
    final snapshot =
        await ConflictService(database: database, accountId: accountId)
            .relationSnapshot();
    return {
      for (final pair in ScheduleConflictProjection.resolve(items, snapshot))
        if (pair.state == ConflictPairState.conflict)
          ...{_keyOf(pair.left).id, _keyOf(pair.right).id},
    };
  }

  static ScheduleItemKey _keyOf(ScheduleGridItem item) =>
      (kind: item.relationKind, id: item.id);

  Future<bool> _isPresent(CalendarEvent event) async {
    if (event.source == 'user') return true;
    final record =
        await (database.select(database.sourceRecords)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.localEntityId.equals(event.id) &
                  row.presence.equals('missing_within_scope').not(),
            ))
            .getSingleOrNull();
    return record != null;
  }

  bool _overlaps(
    CalendarEvent target,
    CalendarEvent candidate,
    Map<String, String> moves,
  ) {
    final targetBounds = _localBounds(target, moves);
    final candidateBounds = _localBounds(candidate, moves);
    return candidateBounds.$1.isBefore(targetBounds.$2) &&
        candidateBounds.$2.isAfter(targetBounds.$1);
  }

  /// The display bounds of an event: moved courses use their effective
  /// (target-day) times, everything else its raw times.
  (DateTime, DateTime) _localBounds(
    CalendarEvent event,
    Map<String, String> moves,
  ) {
    if (event.allDay) {
      return (
        DateTime.parse(event.startDate!),
        DateTime.parse(event.endDateExclusive!),
      );
    }
    final startAt = _beijingDateTime(event.startAt!);
    final movable = event.source == 'ustc_jw' && event.type == 'course';
    final shiftedStart = movable
        ? (_shifted(startAt, moves) ?? startAt)
        : startAt;
    final endAt = _beijingDateTime(event.endAt!);
    final shiftedEnd = shiftedStart == startAt
        ? endAt
        : shiftedStart.add(endAt.difference(startAt));
    return (shiftedStart, shiftedEnd);
  }

  /// All whole-day move records of the account, keyed by RAW source date.
  Future<Map<String, String>> _movesBySourceDate() async {
    final rows =
        await (database.select(database.jwDayMoves)..where(
              (row) => row.accountId.equals(accountId),
            ))
            .get();
    return {for (final row in rows) row.sourceDate: row.targetDate};
  }

  /// The effective start for [event] when a move applies to its raw Beijing
  /// calendar date; null otherwise. Only eligible `ustc_jw/course` timed
  /// events move. The date delta uses Beijing calendar dates (not 24-hour
  /// epoch arithmetic) and the time of day is unchanged.
  DateTime? _shiftedStartAt(CalendarEvent event, Map<String, String> moves) {
    if (event.allDay ||
        event.startAt == null ||
        event.source != 'ustc_jw' ||
        event.type != 'course') {
      return null;
    }
    final startAt = _beijingDateTime(event.startAt!);
    final target = moves[_dateKey(startAt)];
    if (target == null) return null;
    final targetDate = DateTime.parse(target);
    final rawDate = DateTime(startAt.year, startAt.month, startAt.day);
    return startAt.add(Duration(days: targetDate.difference(rawDate).inDays));
  }

  /// The effective end: the same delta as the start, so the duration is
  /// unchanged.
  DateTime? _shiftedEndAt(
    CalendarEvent event,
    DateTime? effectiveStartAt,
  ) {
    if (event.allDay || event.startAt == null || effectiveStartAt == null) {
      return null;
    }
    final duration = event.endAt! - event.startAt!;
    return effectiveStartAt.add(Duration(milliseconds: duration));
  }

  /// Shifts a raw Beijing wall-clock time by the move delta of its calendar
  /// date; null when no move applies.
  DateTime? _shifted(DateTime value, Map<String, String> moves) {
    final target = moves[_dateKey(value)];
    if (target == null) return null;
    final targetDate = DateTime.parse(target);
    final rawDate = DateTime(value.year, value.month, value.day);
    return value.add(Duration(days: targetDate.difference(rawDate).inDays));
  }

  String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  DateTime _beijingDateTime(int millisecondsSinceEpoch) {
    final shifted = DateTime.fromMillisecondsSinceEpoch(
      millisecondsSinceEpoch,
      isUtc: true,
    ).add(const Duration(hours: 8));
    return DateTime(
      shifted.year,
      shifted.month,
      shifted.day,
      shifted.hour,
      shifted.minute,
      shifted.second,
      shifted.millisecond,
      shifted.microsecond,
    );
  }
}
