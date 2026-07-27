import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../tasks/application/undo_recorder.dart';
import 'effective_event_repository.dart';

class OverlayMutation {
  const OverlayMutation({
    this.displayTitle,
    this.displayLocation,
    this.attendancePolicy,
    this.attendanceNote,
    this.listeningMode,
    this.listeningNote,
    this.importance,
    this.color,
    this.foregroundPriority,
    this.hidden,
    this.userNotes,
    this.tagsJson,
  });

  final String? displayTitle;
  final String? displayLocation;
  final AttendancePolicy? attendancePolicy;
  final String? attendanceNote;
  final ListeningMode? listeningMode;
  final String? listeningNote;
  final String? importance;
  final String? color;
  final int? foregroundPriority;
  final bool? hidden;
  final String? userNotes;
  final String? tagsJson;
}

class OverlayService {
  OverlayService({
    required this.database,
    required this.accountId,
    int Function()? now,
    UndoRecorder? undoRecorder,
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       undoRecorder = undoRecorder ?? const NoopUndoRecorder();

  final AppDatabase database;
  final String accountId;
  final int Function() now;
  final UndoRecorder undoRecorder;
  static const _uuid = Uuid();

  Future<void> setEventAttendance(String eventId, AttendancePolicy policy) =>
      setEventOverlay(eventId, OverlayMutation(attendancePolicy: policy));

  Future<void> setSeriesAttendance(
    String courseSeriesId,
    AttendancePolicy policy,
  ) => setSeriesOverlay(
    courseSeriesId,
    OverlayMutation(attendancePolicy: policy),
  );

  Future<void> setEventOverlay(String eventId, OverlayMutation mutation) =>
      _upsert(eventId: eventId, mutation: mutation);

  Future<void> setSeriesOverlay(
    String courseSeriesId,
    OverlayMutation mutation,
  ) => _upsert(courseSeriesId: courseSeriesId, mutation: mutation);

  Future<void> recordAttendanceDecision(
    String eventId,
    AttendanceDecision decision,
  ) => _upsert(
    eventId: eventId,
    mutation: const OverlayMutation(),
    attendanceDecision: decision.storage,
    attendanceDecisionAt: now(),
  );

  Future<void> recordAttendanceOutcome(
    String eventId,
    AttendanceOutcome outcome,
  ) => _upsert(
    eventId: eventId,
    mutation: const OverlayMutation(),
    attendanceOutcome: outcome.storage,
  );

  Future<void> setForegroundPreference(String eventId, int priority) =>
      setEventOverlay(eventId, OverlayMutation(foregroundPriority: priority));

  Future<void> _upsert({
    String? eventId,
    String? courseSeriesId,
    required OverlayMutation mutation,
    String? attendanceDecision,
    int? attendanceDecisionAt,
    String? attendanceOutcome,
  }) async {
    if ((eventId == null) == (courseSeriesId == null)) {
      throw ArgumentError('exactly one overlay target is required');
    }
    await database.transaction(() async {
      await _requireOwnedTarget(
        eventId: eventId,
        courseSeriesId: courseSeriesId,
      );
      final existing =
          await (database.select(database.userOverlays)..where(
                (row) =>
                    row.accountId.equals(accountId) &
                    (eventId != null
                        ? row.eventId.equals(eventId)
                        : row.courseSeriesId.equals(courseSeriesId!)),
              ))
              .getSingleOrNull();
      final timestamp = now();
      final overlayId = existing?.id ?? _uuid.v4();
      await database
          .into(database.userOverlays)
          .insertOnConflictUpdate(
            UserOverlaysCompanion.insert(
              id: overlayId,
              accountId: accountId,
              eventId: Value(eventId),
              courseSeriesId: Value(courseSeriesId),
              displayTitle: Value(
                mutation.displayTitle ?? existing?.displayTitle,
              ),
              displayLocation: Value(
                mutation.displayLocation ?? existing?.displayLocation,
              ),
              attendancePolicy: Value(
                mutation.attendancePolicy?.storage ??
                    existing?.attendancePolicy,
              ),
              attendanceDecision: Value(
                attendanceDecision ?? existing?.attendanceDecision,
              ),
              attendanceDecisionAt: Value(
                attendanceDecisionAt ?? existing?.attendanceDecisionAt,
              ),
              attendanceNote: Value(
                mutation.attendanceNote ?? existing?.attendanceNote,
              ),
              attendanceOutcome: Value(
                attendanceOutcome ?? existing?.attendanceOutcome,
              ),
              listeningMode: Value(
                mutation.listeningMode?.storage ?? existing?.listeningMode,
              ),
              listeningNote: Value(
                mutation.listeningNote ?? existing?.listeningNote,
              ),
              importance: Value(mutation.importance ?? existing?.importance),
              color: Value(mutation.color ?? existing?.color),
              foregroundPriority: Value(
                mutation.foregroundPriority ?? existing?.foregroundPriority,
              ),
              hidden: Value(mutation.hidden ?? existing?.hidden),
              userNotes: Value(mutation.userNotes ?? existing?.userNotes),
              tagsJson: Value(mutation.tagsJson ?? existing?.tagsJson),
              createdAt: existing?.createdAt ?? timestamp,
              updatedAt: timestamp,
            ),
          );
      await database.actionLogsRepository.append(
        accountId: accountId,
        source: 'user',
        actionType: 'user_overlay_update',
        result: 'success',
        safeSummary: eventId == null
            ? 'Updated course preferences.'
            : 'Updated event preferences.',
        occurredAt: timestamp,
      );
      await undoRecorder.record(
        UndoCommand(
          kind: 'user_overlay_update',
          accountId: accountId,
          payload: {
            'entity': 'user_overlay',
            'id': overlayId,
            'before': existing == null ? null : _snapshot(existing),
          },
        ),
      );
    });
  }

  Future<void> _requireOwnedTarget({
    String? eventId,
    String? courseSeriesId,
  }) async {
    final exists = eventId != null
        ? await (database.select(database.calendarEvents)..where(
                (row) =>
                    row.id.equals(eventId) & row.accountId.equals(accountId),
              ))
              .getSingleOrNull()
        : await (database.select(database.courseSeries)..where(
                (row) =>
                    row.id.equals(courseSeriesId!) &
                    row.accountId.equals(accountId),
              ))
              .getSingleOrNull();
    if (exists == null) {
      throw StateError('overlay target not found');
    }
  }

  Map<String, Object?> _snapshot(UserOverlay row) => {
    'id': row.id,
    'eventId': row.eventId,
    'courseSeriesId': row.courseSeriesId,
    'displayTitle': row.displayTitle,
    'displayLocation': row.displayLocation,
    'attendancePolicy': row.attendancePolicy,
    'attendanceDecision': row.attendanceDecision,
    'attendanceDecisionAt': row.attendanceDecisionAt,
    'attendanceNote': row.attendanceNote,
    'attendanceOutcome': row.attendanceOutcome,
    'listeningMode': row.listeningMode,
    'listeningNote': row.listeningNote,
    'importance': row.importance,
    'color': row.color,
    'foregroundPriority': row.foregroundPriority,
    'hidden': row.hidden,
    'userNotes': row.userNotes,
    'tagsJson': row.tagsJson,
    'createdAt': row.createdAt,
    'updatedAt': row.updatedAt,
  };
}
