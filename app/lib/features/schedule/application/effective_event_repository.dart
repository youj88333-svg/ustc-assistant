import 'package:drift/drift.dart';

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
  });

  final CalendarEvent source;
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

  Stream<List<EffectiveEvent>> watchDisplayEvents() => database
      .customSelect(
        '''
SELECT
  e.id,
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
        },
      )
      .watch()
      .asyncMap((rows) async {
        final visibleRows = rows
            .where((row) => row.read<int>('hidden') == 0)
            .toList(growable: false);
        final conflictIds = await _resolvedConflictIds(visibleRows);
        return visibleRows
            .map(
              (row) => _displayEvent(
                row,
                hasConfirmedConflict: conflictIds.contains(
                  row.read<String>('id'),
                ),
              ),
            )
            .toList(growable: false);
      });

  Future<List<EffectiveEventRecord>> overlappingRecords(String eventId) async {
    final target = await byId(eventId);
    if (!await _isPresent(target.source)) return const [];
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
      if (!_overlaps(target.source, candidate)) continue;
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

    return EffectiveEventRecord(
      source: event,
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
    return EffectiveEvent.timed(
      id: id,
      title: title,
      startAt: _beijingDateTime(row.read<int>('start_at')),
      endAt: _beijingDateTime(row.read<int>('end_at')),
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

  /// Resolves every pair (events + approved plan blocks) through the shared
  /// conflict projection and returns the ids of items involved in a conflict.
  ///
  /// This replaces the old event-level SQL `has_confirmed_conflict` as the
  /// authority: overlaps default to conflict and explicit
  /// `conflict`/`no_conflict` relations override. Derived pairs are never
  /// persisted.
  Future<Set<String>> _resolvedConflictIds(List<QueryRow> visibleRows) async {
    final items = <ScheduleGridItem>[
      for (final row in visibleRows)
        ScheduleGridItem.fromEvent(
          _displayEvent(row, hasConfirmedConflict: false),
        ),
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

    final snapshot =
        await ConflictService(database: database, accountId: accountId)
            .relationSnapshot();
    final pairs = ScheduleConflictProjection.resolve(items, snapshot);
    return {
      for (final pair in pairs)
        if (pair.state == ConflictPairState.conflict)
          ...{pair.left.id, pair.right.id},
    };
  }

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

  bool _overlaps(CalendarEvent target, CalendarEvent candidate) {
    final targetBounds = _localBounds(target);
    final candidateBounds = _localBounds(candidate);
    return candidateBounds.$1.isBefore(targetBounds.$2) &&
        candidateBounds.$2.isAfter(targetBounds.$1);
  }

  (DateTime, DateTime) _localBounds(CalendarEvent event) {
    if (event.allDay) {
      return (
        DateTime.parse(event.startDate!),
        DateTime.parse(event.endDateExclusive!),
      );
    }
    return (_beijingDateTime(event.startAt!), _beijingDateTime(event.endAt!));
  }

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
