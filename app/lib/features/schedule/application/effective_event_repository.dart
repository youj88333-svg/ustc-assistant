import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../domain/overlap_engine.dart';

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
        },
      )
      .watch()
      .map(
        (rows) => rows
            .where((row) => row.read<int>('hidden') == 0)
            .map(_displayEvent)
            .toList(growable: false),
      );

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

  EffectiveEvent _displayEvent(QueryRow row) {
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
    );
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
