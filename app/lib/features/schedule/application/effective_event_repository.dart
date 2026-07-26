import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';

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

  Future<EffectiveEventRecord> byId(String eventId) async {
    final event = await (database.select(database.calendarEvents)..where(
          (row) => row.id.equals(eventId) & row.accountId.equals(accountId),
        ))
        .getSingleOrNull();
    if (event == null) {
      throw StateError('calendar event not found');
    }

    final eventOverlay = await (database.select(database.userOverlays)..where(
          (row) =>
              row.accountId.equals(accountId) & row.eventId.equals(eventId),
        ))
        .getSingleOrNull();
    CourseSery? series;
    UserOverlay? seriesOverlay;
    if (event.sourceSeriesExternalId != null) {
      series = await (database.select(database.courseSeries)..where(
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

    T? choose<T>(T? Function(UserOverlay overlay) read) =>
        eventOverlay == null
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
      displayTitle:
          choose((overlay) => overlay.displayTitle) ?? event.title,
      displayLocation:
          choose((overlay) => overlay.displayLocation) ?? event.locationName,
      importance:
          choose((overlay) => overlay.importance) ?? event.importance,
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
}
