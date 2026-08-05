import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../tasks/application/undo_recorder.dart';
import 'effective_event_repository.dart';

/// Overlay field-key vocabulary and group expansion.
///
/// Individual keys map 1:1 to a storage column; group keys (`attendance`,
/// `listening`, `display`, `appearance`, `all`) expand to the union of their
/// member columns. Unknown keys throw so an invalid field aborts the whole
/// (atomic) call.
abstract final class OverlayFieldKeys {
  static const displayTitle = 'display_title';
  static const displayLocation = 'display_location';
  static const attendancePolicy = 'attendance_policy';
  static const attendanceNote = 'attendance_note';
  static const attendanceDecision = 'attendance_decision';
  static const attendanceOutcome = 'attendance_outcome';
  static const listeningMode = 'listening_mode';
  static const listeningNote = 'listening_note';
  static const importance = 'importance';
  static const color = 'color';
  static const foregroundPriority = 'foreground_priority';
  static const hidden = 'hidden';
  static const userNotes = 'user_notes';
  static const tags = 'tags';

  static const attendance = 'attendance';
  static const listening = 'listening';
  static const display = 'display';
  static const appearance = 'appearance';
  static const all = 'all';

  /// Expands [key] (which may be a group) into the set of individual field
  /// keys it covers. Throws [ArgumentError] for an unknown key.
  static Set<String> expand(String key) => switch (key) {
    displayTitle || displayLocation || attendancePolicy || attendanceNote ||
    attendanceDecision || attendanceOutcome || listeningMode || listeningNote ||
    importance || color || foregroundPriority || hidden || userNotes || tags =>
      {key},
    attendance => {
      attendancePolicy,
      attendanceNote,
      attendanceDecision,
      attendanceOutcome,
    },
    listening => {listeningMode, listeningNote},
    display => {displayTitle, displayLocation},
    appearance => {importance, color, foregroundPriority},
    all => {
      displayTitle,
      displayLocation,
      attendancePolicy,
      attendanceNote,
      attendanceDecision,
      attendanceOutcome,
      listeningMode,
      listeningNote,
      importance,
      color,
      foregroundPriority,
      hidden,
      userNotes,
      tags,
    },
    _ => throw ArgumentError.value(key, 'field', 'unknown overlay field'),
  };
}

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
    this.logToActionLog = true,
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       undoRecorder = undoRecorder ?? const NoopUndoRecorder();

  final AppDatabase database;
  final String accountId;
  final int Function() now;
  final UndoRecorder undoRecorder;

  /// When false, the service-internal `source=user` ActionLog is suppressed so
  /// an Agent Gateway call can own the single `source=agent` business log
  /// (written by the outer atomic commit). UI user operations keep the default
  /// `true`. Undo snapshots are ALWAYS recorded regardless of this flag.
  final bool logToActionLog;
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

  /// Clears the given [fields] from an overlay layer atomically.
  ///
  /// [courseSeriesId] selects the `course_series` overlay layer; otherwise
  /// [eventId] selects the `single_event` layer; exactly one is required. Each
  /// element of [fields] is an individual field key or a group key (expanded by
  /// [OverlayFieldKeys]). Every key must be valid, the target must exist and be
  /// owned by the account, and the requested scope must be resolvable —
  /// otherwise the whole call throws and nothing is written.
  ///
  /// Rules:
  /// - `attendance_decision` clearing also clears `attendance_decision_at`.
  /// - Partial clearing preserves the other fields on the row.
  /// - If every field on the row ends up null/empty, the overlay row is
  ///   physically deleted (restoring pure source defaults).
  /// - A single_event layer clear re-exposes the course_series layer; a
  ///   course_series clear re-exposes source defaults.
  ///
  /// The write, the `user_overlay_update` ActionLog, and the one-step Undo
  /// snapshot all land in the same Drift transaction.
  Future<void> clearOverlayFields({
    String? eventId,
    String? courseSeriesId,
    required List<String> fields,
  }) async {
    if (fields.isEmpty) {
      throw ArgumentError.value(fields, 'fields', 'at least one field required');
    }
    if ((eventId == null) == (courseSeriesId == null)) {
      throw ArgumentError('exactly one overlay target is required');
    }
    // Expand groups up-front so an invalid key aborts before any write.
    final targets = <String>{};
    for (final field in fields) {
      targets.addAll(OverlayFieldKeys.expand(field));
    }
    // Resolving `course_series_id` needs the event's source series; when the
    // caller passes an event id but a field implies the series layer they must
    // pass courseSeriesId explicitly. We only support clearing one layer per
    // call via the explicit target argument.
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
      // Clearing attendance_decision always clears its paired timestamp too.
      final mutableFields = {...targets};
      if (targets.contains(OverlayFieldKeys.attendanceDecision)) {
        mutableFields.add('attendance_decision_at');
      }

      // No overlay row means the target is already at pure defaults — there is
      // nothing to clear. A successful no-op (absent == default).
      if (existing == null) {
        await _logOverlay(eventId == null, timestamp);
        return;
      }

      final before = _snapshot(existing);
      final after = _applyClears(existing, mutableFields);

      if (_isEmptyOverlay(after)) {
        // Every field cleared -> physically delete the row so pure source
        // defaults (or the series layer) take over.
        await (database.delete(database.userOverlays)
              ..where(
                (row) =>
                    row.id.equals(existing.id) & row.accountId.equals(accountId),
              ))
            .go();
      } else {
        await _updateOverlayRow(existing, after, timestamp);
      }

      await _logOverlay(eventId == null, timestamp);
      // Undo captures the complete before row; restoring it reproduces the
      // pre-clear state even when the row was physically deleted.
      await undoRecorder.record(
        UndoCommand(
          kind: 'user_overlay_update',
          accountId: accountId,
          payload: {
            'entity': 'user_overlay',
            'id': existing.id,
            'before': before,
          },
        ),
      );
    });
  }

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
      await _logOverlay(eventId == null, timestamp);
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

  Future<void> _logOverlay(bool isSeriesTarget, int timestamp) {
    if (!logToActionLog) return Future<void>.value();
    return database.actionLogsRepository.append(
      accountId: accountId,
      source: 'user',
      actionType: 'user_overlay_update',
      result: 'success',
      safeSummary: isSeriesTarget
          ? 'Updated course preferences.'
          : 'Updated event preferences.',
      occurredAt: timestamp,
    );
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

  /// Returns a copy of [row] with every field in [fields] (storage-column
  /// names) set to null. Unlisted fields are preserved.
  UserOverlay _applyClears(UserOverlay row, Set<String> fields) {
    String? n(String? v, String field) => fields.contains(field) ? null : v;
    int? ni(int? v, String field) => fields.contains(field) ? null : v;
    bool? nb(bool? v, String field) => fields.contains(field) ? null : v;
    return UserOverlay(
      id: row.id,
      accountId: row.accountId,
      eventId: row.eventId,
      courseSeriesId: row.courseSeriesId,
      displayTitle: n(row.displayTitle, OverlayFieldKeys.displayTitle),
      displayLocation: n(row.displayLocation, OverlayFieldKeys.displayLocation),
      attendancePolicy: n(
        row.attendancePolicy,
        OverlayFieldKeys.attendancePolicy,
      ),
      attendanceDecision: n(
        row.attendanceDecision,
        OverlayFieldKeys.attendanceDecision,
      ),
      attendanceDecisionAt: ni(
        row.attendanceDecisionAt,
        'attendance_decision_at',
      ),
      attendanceNote: n(row.attendanceNote, OverlayFieldKeys.attendanceNote),
      attendanceOutcome: n(
        row.attendanceOutcome,
        OverlayFieldKeys.attendanceOutcome,
      ),
      listeningMode: n(row.listeningMode, OverlayFieldKeys.listeningMode),
      listeningNote: n(row.listeningNote, OverlayFieldKeys.listeningNote),
      importance: n(row.importance, OverlayFieldKeys.importance),
      color: n(row.color, OverlayFieldKeys.color),
      foregroundPriority: ni(
        row.foregroundPriority,
        OverlayFieldKeys.foregroundPriority,
      ),
      hidden: nb(row.hidden, OverlayFieldKeys.hidden),
      userNotes: n(row.userNotes, OverlayFieldKeys.userNotes),
      tagsJson: n(row.tagsJson, OverlayFieldKeys.tags),
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }

  /// True when no user-facing field on [row] is set (pure defaults / empty).
  bool _isEmptyOverlay(UserOverlay row) =>
      row.displayTitle == null &&
      row.displayLocation == null &&
      row.attendancePolicy == null &&
      row.attendanceDecision == null &&
      row.attendanceDecisionAt == null &&
      row.attendanceNote == null &&
      row.attendanceOutcome == null &&
      row.listeningMode == null &&
      row.listeningNote == null &&
      row.importance == null &&
      row.color == null &&
      row.foregroundPriority == null &&
      row.hidden == null &&
      row.userNotes == null &&
      row.tagsJson == null;

  /// Persists [updated] (already carrying the post-clear values) over [previous]
  /// on the existing overlay row.
  Future<void> _updateOverlayRow(
    UserOverlay previous,
    UserOverlay updated,
    int timestamp,
  ) =>
      (database.update(database.userOverlays)
            ..where((row) => row.id.equals(previous.id)))
          .write(
            UserOverlaysCompanion(
              displayTitle: Value(updated.displayTitle),
              displayLocation: Value(updated.displayLocation),
              attendancePolicy: Value(updated.attendancePolicy),
              attendanceDecision: Value(updated.attendanceDecision),
              attendanceDecisionAt: Value(updated.attendanceDecisionAt),
              attendanceNote: Value(updated.attendanceNote),
              attendanceOutcome: Value(updated.attendanceOutcome),
              listeningMode: Value(updated.listeningMode),
              listeningNote: Value(updated.listeningNote),
              importance: Value(updated.importance),
              color: Value(updated.color),
              foregroundPriority: Value(updated.foregroundPriority),
              hidden: Value(updated.hidden),
              userNotes: Value(updated.userNotes),
              tagsJson: Value(updated.tagsJson),
              updatedAt: Value(timestamp),
            ),
          );

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
