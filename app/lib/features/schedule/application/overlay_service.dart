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

  /// Loads the overlay configuration for [eventId] in two explicit layers:
  /// the `single_event` layer and the `course_series` layer (resolved via the
  /// event's source series). Each layer is the explicit, set-fields-only
  /// overlay row — never the merged EffectiveEvent value. Also computes what
  /// the effective value would be after clearing each layer alone, so the Agent
  /// can preview "if I clear this layer, what takes over?". Account-scoped and
  /// read-only; exposes no DB id.
  ///
  /// [courseSeriesIdOverride] lets a caller that already knows the event's
  /// series id skip the series lookup; when null it is derived from the event's
  /// `sourceSeriesExternalId`.
  Future<EventOverlayLayers> eventOverlayLayers(
    String eventId, {
    String? courseSeriesIdOverride,
  }) async {
    final event =
        await (database.select(database.calendarEvents)..where(
              (row) =>
                  row.id.equals(eventId) & row.accountId.equals(accountId),
            ))
            .getSingleOrNull();
    if (event == null) {
      throw StateError('overlay event not found');
    }
    UserOverlay? seriesRow;
    var seriesId = courseSeriesIdOverride;
    if (seriesId == null && event.sourceSeriesExternalId != null) {
      final series =
          await (database.select(database.courseSeries)..where(
                (row) =>
                    row.accountId.equals(accountId) &
                    row.source.equals(event.source) &
                    row.externalId.equals(event.sourceSeriesExternalId!),
              ))
              .getSingleOrNull();
      seriesId = series?.id;
      seriesRow = series == null ? null : await _overlayBySeriesId(series.id);
    } else if (seriesId != null) {
      seriesRow = await _overlayBySeriesId(seriesId);
    }
    final eventRow =
        await (database.select(database.userOverlays)..where(
              (row) =>
                  row.accountId.equals(accountId) & row.eventId.equals(eventId),
            ))
            .getSingleOrNull();
    return EventOverlayLayers._computed(
      event: event,
      eventRow: eventRow,
      seriesRow: seriesRow,
    );
  }

  Future<UserOverlay?> _overlayBySeriesId(String courseSeriesId) =>
      (database.select(database.userOverlays)..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.courseSeriesId.equals(courseSeriesId),
          ))
          .getSingleOrNull();

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

/// The overlay layer that owns a set of explicit fields.
enum OverlayLayer { singleEvent, courseSeries }

/// A read-only decomposition of an event's overlay configuration into its two
/// explicit layers (`single_event` and `course_series`), plus the effective
/// value that would take over after clearing each layer. Used by the Agent
/// `get_user_overlay` tool. Never exposes a UserOverlay DB id, event id, or
/// series id.
class EventOverlayLayers {
  const EventOverlayLayers._({
    required this.singleEvent,
    required this.courseSeries,
    required this.afterClearingSingle,
    required this.afterClearingSeries,
    required this.hasSingleEventLayer,
    required this.hasCourseSeriesLayer,
  });

  /// Explicitly-set fields on the `single_event` layer (an event-scoped
  /// UserOverlay row). Only allowlisted field keys survive.
  final Map<String, Object?> singleEvent;

  /// Explicitly-set fields on the `course_series` layer (a series-scoped
  /// UserOverlay row). Only allowlisted field keys survive.
  final Map<String, Object?> courseSeries;

  /// The effective field values after clearing the single_event layer (series
  /// layer + source defaults then apply). Only allowlisted field keys.
  final Map<String, Object?> afterClearingSingle;

  /// The effective field values after clearing the course_series layer (source
  /// defaults apply). Only allowlisted field keys.
  final Map<String, Object?> afterClearingSeries;

  final bool hasSingleEventLayer;
  final bool hasCourseSeriesLayer;

  /// Compute the two layers and clear-preview values for [event] given its
  /// event-scoped and series-scoped overlay rows (either may be null).
  factory EventOverlayLayers._computed({
    required CalendarEvent event,
    required UserOverlay? eventRow,
    required UserOverlay? seriesRow,
  }) {
    final single = _allowlistedFields(eventRow);
    final series = _allowlistedFields(seriesRow);

    // After clearing the single_event layer: series + source defaults.
    final afterSingle = _merge(sourceDefaults(event), series);

    // After clearing the course_series layer: single layer + source defaults.
    final afterSeries = _merge(sourceDefaults(event), single);

    return EventOverlayLayers._(
      singleEvent: single,
      courseSeries: series,
      afterClearingSingle: afterSingle,
      afterClearingSeries: afterSeries,
      hasSingleEventLayer: eventRow != null,
      hasCourseSeriesLayer: seriesRow != null,
    );
  }

  /// The default effective values straight from the event row (no overlay).
  static Map<String, Object?> sourceDefaults(CalendarEvent event) => {
    'displayTitle': event.title,
    'displayLocation': event.locationName,
    'attendancePolicy': switch (event.type) {
      'exam' || 'second_class' => 'must_go',
      _ => 'unknown',
    },
    'importance': event.importance,
    'color': event.color,
    'hidden': false,
  };

  static Map<String, Object?> _merge(
    Map<String, Object?> base,
    Map<String, Object?> override,
  ) =>
      {...base, ...override};

  /// Extracts only the model-safe, explicitly-set overlay fields from [row].
  /// Null fields in the overlay row mean "not set" and are omitted. Never
  /// includes the DB id, event id, or series id.
  static Map<String, Object?> _allowlistedFields(UserOverlay? row) {
    if (row == null) return const {};
    final out = <String, Object?>{};
    void add(String key, Object? value) {
      if (value != null) out[key] = value;
    }

    add('displayTitle', row.displayTitle);
    add('displayLocation', row.displayLocation);
    add('attendancePolicy', row.attendancePolicy);
    add('attendanceNote', row.attendanceNote);
    add('attendanceDecision', row.attendanceDecision);
    add('attendanceOutcome', row.attendanceOutcome);
    add('listeningMode', row.listeningMode);
    add('listeningNote', row.listeningNote);
    add('importance', row.importance);
    add('color', row.color);
    add('foregroundPriority', row.foregroundPriority);
    add('hidden', row.hidden);
    add('userNotes', row.userNotes);
    add('tagsJson', row.tagsJson);
    return out;
  }
}
