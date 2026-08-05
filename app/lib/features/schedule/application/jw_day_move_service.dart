import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../tasks/application/undo_recorder.dart';
import '../domain/jw_day_move.dart';

/// Account-scoped whole-day JW course moves (Spec section 10).
///
/// A move from A to B makes A's eligible courses stop showing on A and appear
/// on B with the same Beijing time, duration, location, title, source identity
/// and user overlay; B's existing events are all retained. It is a MOVE, not
/// a swap. Exams, second-class, personal and all-day events, and PlanBlocks
/// never move.
///
/// `preview` queries the ORIGINAL CalendarEvent timestamps and source records
/// — it never consumes an already-shifted projection. `move`/`clear` recheck
/// eligibility and the target at commit time inside one transaction that also
/// writes the ActionLog and the `UndoCommand(kind: 'jw_day_move')` snapshot
/// (caller-supplied [UndoRecorder], matching the caller's transaction
/// pattern). Source events are never modified.
class JwDayMoveService {
  JwDayMoveService({
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

  /// The eligible course titles for [sourceDate] plus the existing move target
  /// (when a move record is already present). Never contains ids.
  Future<JwDayMovePreview> preview(String sourceDate) async {
    final courses = await _eligibleCourses(sourceDate);
    final existing = await _moveFor(sourceDate);
    return JwDayMovePreview(
      sourceDate: sourceDate,
      targetDate: existing?.targetDate,
      courses: [for (final event in courses) event.title],
    );
  }

  /// Moves the eligible courses of [sourceDate] to [targetDate], or updates
  /// the existing record when the source date is moved again (retarget).
  Future<void> move(String sourceDate, String targetDate) async {
    if (sourceDate == targetDate) throw const InvalidDayMoveDates();
    await database.transaction(() async {
      final eligible = await _eligibleCourses(sourceDate);
      if (eligible.isEmpty) throw NoEligibleJwCourses(sourceDate);
      final existing = await _moveFor(sourceDate);
      final timestamp = now();
      final id = existing?.id ?? _uuid.v4();
      await database
          .into(database.jwDayMoves)
          .insertOnConflictUpdate(
            JwDayMovesCompanion.insert(
              id: id,
              accountId: accountId,
              sourceDate: sourceDate,
              targetDate: targetDate,
              createdAt: existing?.createdAt ?? timestamp,
              updatedAt: timestamp,
            ),
          );
      await _logMove(existing == null, timestamp);
      await undoRecorder.record(
        UndoCommand(
          kind: 'jw_day_move',
          accountId: accountId,
          payload: {
            'entity': 'jw_day_move',
            'id': id,
            'before': existing == null ? null : _snapshot(existing),
          },
        ),
      );
    });
  }

  /// Deletes the move record for [sourceDate], restoring the original dates.
  Future<void> clear(String sourceDate) async {
    await database.transaction(() async {
      final existing = await _moveFor(sourceDate);
      if (existing == null) throw MissingJwDayMove(sourceDate);
      await (database.delete(
        database.jwDayMoves,
      )..where(
          (row) => row.id.equals(existing.id) & row.accountId.equals(accountId),
        ))
        .go();
      final timestamp = now();
      await _logClear(timestamp);
      await undoRecorder.record(
        UndoCommand(
          kind: 'jw_day_move',
          accountId: accountId,
          payload: {
            'entity': 'jw_day_move',
            'id': existing.id,
            'before': _snapshot(existing),
          },
        ),
      );
    });
  }

  Future<void> _logMove(bool isNew, int timestamp) {
    if (!logToActionLog) return Future<void>.value();
    return database.actionLogsRepository.append(
      accountId: accountId,
      source: 'user',
      actionType: isNew ? 'jw_day_move' : 'jw_day_move_retarget',
      result: 'success',
      safeSummary: isNew
          ? 'Moved the whole day of JW courses.'
          : 'Retargeted a whole-day JW course move.',
      occurredAt: timestamp,
    );
  }

  Future<void> _logClear(int timestamp) {
    if (!logToActionLog) return Future<void>.value();
    return database.actionLogsRepository.append(
      accountId: accountId,
      source: 'user',
      actionType: 'jw_day_move_clear',
      result: 'success',
      safeSummary: 'Cleared a whole-day JW course move.',
      occurredAt: timestamp,
    );
  }

  /// The eligible courses of [sourceDate]: `source == ustc_jw`, timed
  /// `course` events whose raw Beijing calendar date equals [sourceDate] and
  /// whose source record is currently valid (present within the snapshot
  /// scope). Queries the ORIGINAL CalendarEvent rows, never the shifted
  /// display projection.
  Future<List<CalendarEvent>> _eligibleCourses(String sourceDate) async {
    final rows = await (database.select(database.calendarEvents)..where(
          (row) =>
              row.accountId.equals(accountId) &
              row.source.equals('ustc_jw') &
              row.type.equals('course') &
              row.allDay.equals(false) &
              row.deletedAt.isNull() &
              row.status.isNotIn(['cancelled', 'hidden', 'skipped']),
        ))
        .get();
    final eligible = <CalendarEvent>[];
    for (final event in rows) {
      if (_beijingDateKey(_beijingDateTime(event.startAt!)) != sourceDate) {
        continue;
      }
      if (!await _isPresent(event)) continue;
      eligible.add(event);
    }
    eligible.sort((a, b) => a.startAt!.compareTo(b.startAt!));
    return eligible;
  }

  Future<JwDayMoveRecord?> _moveFor(String sourceDate) async =>
      (database.select(database.jwDayMoves)..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.sourceDate.equals(sourceDate),
          ))
          .getSingleOrNull();

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

  Map<String, Object?> _snapshot(JwDayMoveRecord row) => {
    'id': row.id,
    'sourceDate': row.sourceDate,
    'targetDate': row.targetDate,
    'createdAt': row.createdAt,
    'updatedAt': row.updatedAt,
  };

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

  String _beijingDateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
