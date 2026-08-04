import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../calendar/application/recurrence_service.dart';
import '../../calendar/domain/calendar_event_locator.dart';
import '../../tasks/application/undo_recorder.dart';
import '../../tasks/domain/plan_block.dart';
import '../../tasks/domain/task.dart';
import '../domain/overlap_engine.dart';
import '../domain/schedule_grid_item.dart';
import 'schedule_conflict_projection.dart';

enum ConflictState { unclassified, conflict, nonConflict }

enum ConflictScope { occurrence, currentAndFuture }

class ConflictValidationError implements Exception {
  const ConflictValidationError(this.message);

  final String message;

  @override
  String toString() => 'ConflictValidationError: $message';
}

/// A unified relation participant. `kind` is `event` (a CalendarEvent) or
/// `plan_block` (a PlanBlock). PlanBlock participants never carry a fake series
/// identity, so their series fields (`seriesType`, `seriesId`,
/// `finiteSeriesEnd`) must stay null and [hasStableSeriesIdentity] is always
/// false — current-and-future scope is therefore rejected for them.
class ScheduleConflictParticipant {
  const ScheduleConflictParticipant({
    required this.kind,
    required this.id,
    required this.title,
    required this.occurrenceDate,
    this.startAt,
    this.endAt,
    this.seriesType,
    this.seriesId,
    this.finiteSeriesEnd,
  });

  /// `event` or `plan_block` (matches `schedule_relations.leftKind/rightKind`).
  final String kind;

  final String id;

  /// Safe display title (never an id/ref).
  final String title;

  final DateTime occurrenceDate;
  final DateTime? startAt;
  final DateTime? endAt;
  final String? seriesType;
  final String? seriesId;
  final DateTime? finiteSeriesEnd;

  bool get hasStableSeriesIdentity =>
      seriesId != null &&
      seriesType != null &&
      (seriesType == 'course_series' || seriesType == 'calendar_event_series');

  /// Canonical key for pair ordering and dedup: `kind:id`.
  String get canonicalKey => '$kind:$id';
}

class ConflictService {
  ConflictService({
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

  Future<void> classifyPair(
    ScheduleConflictParticipant a,
    ScheduleConflictParticipant b,
    ConflictState state, {
    ConflictScope scope = ConflictScope.occurrence,
    String? reason,
  }) {
    if (a.canonicalKey == b.canonicalKey) {
      throw const ConflictValidationError(
        'a conflict pair requires two distinct participants',
      );
    }
    if (a.kind != 'event' && a.kind != 'plan_block') {
      throw ConflictValidationError('unsupported participant kind: ${a.kind}');
    }
    if (b.kind != 'event' && b.kind != 'plan_block') {
      throw ConflictValidationError('unsupported participant kind: ${b.kind}');
    }
    if (scope == ConflictScope.currentAndFuture &&
        (a.kind != 'event' || b.kind != 'event')) {
      throw const ConflictValidationError(
        'current-and-future scope is only valid between two stable events',
      );
    }
    return scope == ConflictScope.occurrence
        ? _classifyOccurrence(a, b, state, reason)
        : _classifyCurrentAndFuture(a, b, state, reason);
  }

  /// Re-validates that both participants still resolve to account-owned,
  /// nondeleted rows before an occurrence write. Throws
  /// [ConflictValidationError] for a missing/deleted/foreign target so no
  /// dangling relation row is ever written.
  Future<void> _validateOccurrenceTargets(
    ScheduleConflictParticipant a,
    ScheduleConflictParticipant b,
  ) async {
    final okA = await _participantExists(a);
    if (!okA) throw ConflictValidationError('relation target not found: ${a.kind}:${a.id}');
    final okB = await _participantExists(b);
    if (!okB) throw ConflictValidationError('relation target not found: ${b.kind}:${b.id}');
  }

  Future<bool> _participantExists(ScheduleConflictParticipant p) async {
    if (p.kind == 'event') {
      final decoded = _tryDecodeLocator(p.id);
      if (decoded is RecurringOccurrenceLocator) {
        final recurrence =
            RecurrenceService(database: database, accountId: accountId);
        if (await recurrence.seriesRowOrNull(decoded.seriesId) == null) {
          return false;
        }
        try {
          await recurrence.occurrence(decoded.seriesId, decoded.occurrenceKey);
          return true;
        } on OccurrenceNotFoundError {
          return false;
        }
      }
      if (decoded is RecurringSeriesLocator) return false;
      final event = await (database.select(database.calendarEvents)..where(
            (row) =>
                row.id.equals(p.id) & row.accountId.equals(accountId),
          ))
          .getSingleOrNull();
      return event != null;
    }
    if (p.kind == 'plan_block') {
      final block = await (database.select(database.planBlocks)..where(
            (row) =>
                row.id.equals(p.id) &
                row.accountId.equals(accountId) &
                row.deletedAt.isNull(),
          ))
          .getSingleOrNull();
      if (block == null) return false;
      final task = await (database.select(database.tasks)..where(
            (row) =>
                row.id.equals(block.taskId) &
                row.accountId.equals(accountId) &
                row.deletedAt.isNull(),
          ))
          .getSingleOrNull();
      return task != null;
    }
    return false;
  }

  /// Loads the account-scoped conflict relation snapshot (occurrence
  /// relations + series rules) consumed by [ScheduleConflictProjection].
  ///
  /// Read-only: never mutates the database.
  Future<ScheduleConflictRelationSnapshot> relationSnapshot() async {
    final occurrenceRows =
        await (database.select(database.scheduleRelations)..where(
              (row) => row.accountId.equals(accountId),
            ))
            .get();
    final occurrenceByPair = <String, ConflictPairState>{};
    for (final row in occurrenceRows) {
      final leftKind = row.leftKind;
      final leftId = row.leftId;
      final rightKind = row.rightKind;
      final rightId = row.rightId;
      if (leftKind == null ||
          leftId == null ||
          rightKind == null ||
          rightId == null) {
        continue;
      }
      final state = _conflictPairState(row.conflictState);
      if (state == null) continue;
      occurrenceByPair[
          ScheduleConflictProjection.occurrenceKey(
            leftKind,
            leftId,
            rightKind,
            rightId,
          )] = state;
    }

    final ruleRows =
        await (database.select(database.scheduleRelationRules)..where(
              (row) => row.accountId.equals(accountId),
            ))
            .get();
    final seriesByPair = <String, List<SeriesConflictRule>>{};
    for (final row in ruleRows) {
      final state = _conflictPairState(row.conflictState);
      if (state == null) continue;
      final key = ScheduleConflictProjection.seriesKey(
        row.leftSeriesType,
        row.leftSeriesId,
        row.rightSeriesType,
        row.rightSeriesId,
      );
      seriesByPair.putIfAbsent(key, () => []).add(
            SeriesConflictRule(
              effectiveFrom: row.effectiveFrom,
              effectiveThrough: row.effectiveThrough,
              state: state,
            ),
          );
    }
    return ScheduleConflictRelationSnapshot(
      occurrenceByPair: Map.unmodifiable(occurrenceByPair),
      seriesByPair: Map.unmodifiable(seriesByPair),
    );
  }

  /// The current state of a pair under the shared conflict projection.
  ///
  /// Derives from the same precedence as the week grid / `get_conflicts`:
  /// explicit occurrence → explicit series → timed overlap → no conflict.
  Future<ConflictState> stateForPair(
    ScheduleConflictParticipant a,
    ScheduleConflictParticipant b,
  ) async {
    final itemA = await _gridItemFor(a);
    final itemB = await _gridItemFor(b);
    if (itemA == null || itemB == null) return ConflictState.unclassified;
    final snapshot = await relationSnapshot();
    final pairs = ScheduleConflictProjection.resolve([itemA, itemB], snapshot);
    if (pairs.isEmpty) return ConflictState.unclassified;
    final pair = pairs.first;
    return pair.state == ConflictPairState.conflict
        ? ConflictState.conflict
        : ConflictState.nonConflict;
  }

  /// Builds a [ScheduleGridItem] for a [ScheduleConflictParticipant] from the
  /// underlying account-owned row so the shared projection can resolve overlap
  /// and series identity. For `event` this is the CalendarEvent row; for
  /// `plan_block` it is the (nondeleted) PlanBlock plus its nondeleted parent
  /// Task. Returns null when the participant is missing, deleted, or
  /// unaccounted.
  Future<ScheduleGridItem?> _gridItemFor(
    ScheduleConflictParticipant participant,
  ) async {
    if (participant.kind == 'event') {
      // A recurring occurrence participant is identified by its encoded locator
      // (logical id); it is not a stored `calendar_events` row. Load the series
      // plus the composed occurrence so overlap and series-identity resolution
      // still work.
      final decoded = _tryDecodeLocator(participant.id);
      if (decoded is RecurringOccurrenceLocator) {
        return _occurrenceGridItem(decoded);
      }
      final event =
          await (database.select(database.calendarEvents)..where(
                (row) =>
                    row.id.equals(participant.id) &
                    row.accountId.equals(accountId),
              ))
              .getSingleOrNull();
      if (event == null) return null;
      if (event.allDay) {
        return ScheduleGridItem.fromEvent(
          EffectiveEvent.allDay(
            id: event.id,
            title: event.title,
            startDate: DateTime.parse(event.startDate!),
            endDateExclusive: DateTime.parse(event.endDateExclusive!),
            courseSeriesId: participant.seriesId,
            eventType: event.type,
          ),
        );
      }
      final startAt = event.startAt;
      final endAt = event.endAt;
      if (startAt == null || endAt == null) return null;
      return ScheduleGridItem.fromEvent(
        EffectiveEvent.timed(
          id: event.id,
          title: event.title,
          startAt: _beijingDateTime(startAt),
          endAt: _beijingDateTime(endAt),
          courseSeriesId: participant.seriesId,
          eventType: event.type,
        ),
      );
    }
    // PlanBlock: must be nondeleted and owned by this account, and its parent
    // Task must be nondeleted too (a deleted plan block / task no longer
    // participates in the week grid's time conflicts).
    final block = await (database.select(database.planBlocks)..where(
          (row) =>
              row.id.equals(participant.id) &
              row.accountId.equals(accountId) &
              row.deletedAt.isNull(),
        ))
        .getSingleOrNull();
    if (block == null) return null;
    final task = await (database.select(database.tasks)..where(
          (row) =>
              row.id.equals(block.taskId) &
              row.accountId.equals(accountId) &
              row.deletedAt.isNull(),
        ))
        .getSingleOrNull();
    if (task == null) return null;
    return ScheduleGridItem.fromPlanBlock(
      PlanBlockItem.fromRow(block),
      TaskItem.fromRow(task),
    );
  }

  Future<bool> showConflictWarning(
    ScheduleConflictParticipant a,
    ScheduleConflictParticipant b,
  ) async => await stateForPair(a, b) == ConflictState.conflict;

  /// The loadable grid-item view of a participant (reads the account-owned,
  /// nondeleted event / plan-block + task rows). Public so the Agent read tool
  /// can feed the shared projection for fallback previews. Returns null for a
  /// missing / deleted / unaccounted participant.
  Future<ScheduleGridItem?> gridItemForParticipant(
    ScheduleConflictParticipant participant,
  ) => _gridItemFor(participant);

  /// The account-scoped, `source=user`, `relationType=conflict` occurrence
  /// relations involving [participant] as either side. Read-only.
  Future<List<ScheduleRelation>> userConflictRelationsFor(
    ScheduleConflictParticipant participant,
  ) =>
      (database.select(database.scheduleRelations)..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.source.equals('user') &
                row.relationType.equals('conflict') &
                ((row.leftKind.equals(participant.kind) &
                            row.leftId.equals(participant.id)) |
                        (row.rightKind.equals(participant.kind) &
                            row.rightId.equals(participant.id))),
          ))
          .get();

  /// The account-scoped series conflict rules involving [participant]'s series
  /// as either side. Empty when the participant has no stable series identity.
  /// Read-only.
  Future<List<ScheduleRelationRule>> userConflictRulesFor(
    ScheduleConflictParticipant participant,
  ) async {
    final seriesType = participant.seriesType;
    final seriesId = participant.seriesId;
    if (seriesType == null || seriesId == null) return const [];
    return (database.select(database.scheduleRelationRules)..where(
          (row) =>
              row.accountId.equals(accountId) &
              ((row.leftSeriesType.equals(seriesType) &
                          row.leftSeriesId.equals(seriesId)) |
                      (row.rightSeriesType.equals(seriesType) &
                          row.rightSeriesId.equals(seriesId))),
        ))
        .get();
  }

  /// Resolves the current state of the (a, b) pair via the shared projection.
  /// Returns null when either participant's grid item does not resolve (e.g.
  /// deleted/foreign), in which case the pair is `unclassified`. Read-only.
  Future<ResolvedConflictPair?> resolvePairBetween(
    ScheduleConflictParticipant a,
    ScheduleConflictParticipant b,
  ) async {
    final itemA = await _gridItemFor(a);
    final itemB = await _gridItemFor(b);
    if (itemA == null || itemB == null) return null;
    final snapshot = await relationSnapshot();
    return ScheduleConflictProjection.resolvePair(itemA, itemB, snapshot);
  }

  /// The would-be state of the (a, b) pair if the occurrence relation
  /// [ignoredOccurrenceKey] were removed: series rule → derived overlap → no
  /// conflict. Used to preview a single-relation deletion. Returns null when
  /// either participant's grid item does not resolve.
  Future<ResolvedConflictPair?> resolvePairIgnoringOccurrence(
    ScheduleConflictParticipant a,
    ScheduleConflictParticipant b,
    String ignoredOccurrenceKey,
  ) async {
    final itemA = await _gridItemFor(a);
    final itemB = await _gridItemFor(b);
    if (itemA == null || itemB == null) return null;
    final snapshot = await relationSnapshot();
    final filtered = ScheduleConflictRelationSnapshot(
      occurrenceByPair: Map.of(snapshot.occurrenceByPair)
        ..remove(ignoredOccurrenceKey),
      seriesByPair: snapshot.seriesByPair,
    );
    return ScheduleConflictProjection.resolvePair(itemA, itemB, filtered);
  }

  /// The would-be state of the (a, b) pair if the series rules for their series
  /// pair were removed: occurrence relation → derived overlap → no conflict.
  /// Used to preview a series-rule deletion. Returns null when either
  /// participant's grid item does not resolve.
  Future<ResolvedConflictPair?> resolvePairIgnoringSeries(
    ScheduleConflictParticipant a,
    ScheduleConflictParticipant b,
  ) async {
    final itemA = await _gridItemFor(a);
    final itemB = await _gridItemFor(b);
    if (itemA == null || itemB == null) return null;
    final snapshot = await relationSnapshot();
    final filtered = ScheduleConflictRelationSnapshot(
      occurrenceByPair: snapshot.occurrenceByPair,
      seriesByPair: Map.of(snapshot.seriesByPair),
    );
    // Remove the two canonical series-pair keys involving a and b's series.
    if (a.seriesType != null &&
        a.seriesId != null &&
        b.seriesType != null &&
        b.seriesId != null) {
      final key = ScheduleConflictProjection.seriesKey(
        a.seriesType!,
        a.seriesId!,
        b.seriesType!,
        b.seriesId!,
      );
      filtered.seriesByPair.remove(key);
    }
    return ScheduleConflictProjection.resolvePair(itemA, itemB, filtered);
  }

  Future<void> _classifyOccurrence(
    ScheduleConflictParticipant a,
    ScheduleConflictParticipant b,
    ConflictState state,
    String? reason,
  ) async {
    // Canonicalize by `kind:id` so a reverse insertion lands on the same row.
    final pair = _canonicalParticipants(a, b);
    await database.transaction(() async {
      // Re-validate both targets inside the same unit of work (TOCTOU-safe):
      // a participant deleted between build and commit must not be referenced.
      await _validateOccurrenceTargets(pair.$1, pair.$2);
      // Resolve the backing FK for each event participant: a stored event id
      // populates left/rightEventId; a recurring occurrence locator calls
      // ensureOccurrenceAnchor (inside this approved write transaction) and
      // populates the occurrence-exception FK. A plan_block participant always
      // populates left/rightPlanBlockId.
      final (leftEventId, leftOccurrenceExceptionId) =
          await _eventBacking(pair.$1);
      final (rightEventId, rightOccurrenceExceptionId) =
          await _eventBacking(pair.$2);
      final existing =
          await (database.select(database.scheduleRelations)..where(
                (row) =>
                    row.accountId.equals(accountId) &
                    row.leftKind.equals(pair.$1.kind) &
                    row.leftId.equals(pair.$1.id) &
                    row.rightKind.equals(pair.$2.kind) &
                    row.rightId.equals(pair.$2.id),
              ))
              .getSingleOrNull();
      final relationId = existing?.id ?? _uuid.v4();
      final query = database.delete(database.scheduleRelations)
        ..where(
          (row) =>
              row.accountId.equals(accountId) &
              row.leftKind.equals(pair.$1.kind) &
              row.leftId.equals(pair.$1.id) &
              row.rightKind.equals(pair.$2.kind) &
              row.rightId.equals(pair.$2.id),
        );
      if (state == ConflictState.unclassified) {
        await query.go();
      } else {
        final timestamp = now();
        await database
            .into(database.scheduleRelations)
            .insertOnConflictUpdate(
              ScheduleRelationsCompanion.insert(
                id: relationId,
                accountId: accountId,
                leftKind: Value(pair.$1.kind),
                leftId: Value(pair.$1.id),
                leftEventId: Value(leftEventId),
                leftPlanBlockId: Value(
                  pair.$1.kind == 'plan_block' ? pair.$1.id : null,
                ),
                leftOccurrenceExceptionId: Value(leftOccurrenceExceptionId),
                rightKind: Value(pair.$2.kind),
                rightId: Value(pair.$2.id),
                rightEventId: Value(rightEventId),
                rightPlanBlockId: Value(
                  pair.$2.kind == 'plan_block' ? pair.$2.id : null,
                ),
                rightOccurrenceExceptionId: Value(rightOccurrenceExceptionId),
                conflictState: Value(_stateStorage(state)),
                reason: Value(reason),
                createdAt: existing?.createdAt ?? timestamp,
                updatedAt: timestamp,
              ),
            );
      }
      await _logClassification(state);
      await undoRecorder.record(
        UndoCommand(
          kind: 'conflict_classification',
          accountId: accountId,
          payload: {
            'entity': 'schedule_relation',
            'id': relationId,
            'before': existing == null ? null : _relationSnapshot(existing),
          },
        ),
      );
    });
  }

  /// Resolves an event-kind participant's backing FK columns. A plain stored
  /// event id maps to `leftEventId`/`rightEventId`; a recurring occurrence
  /// locator maps to the occurrence exception anchor (created/reused via
  /// [RecurrenceService.ensureOccurrenceAnchor]) on the occurrence-exception FK.
  /// Plan-block kinds return nulls for both event columns.
  Future<(String?, String?)> _eventBacking(
    ScheduleConflictParticipant participant,
  ) async {
    if (participant.kind != 'event') return (null, null);
    final decoded = _tryDecodeLocator(participant.id);
    if (decoded is RecurringOccurrenceLocator) {
      final recurrence =
          RecurrenceService(database: database, accountId: accountId);
      final anchor = await recurrence.ensureOccurrenceAnchor(
        decoded.seriesId,
        decoded.occurrenceKey,
      );
      return (null, anchor.id);
    }
    return (participant.id, null);
  }

  Future<void> _classifyCurrentAndFuture(
    ScheduleConflictParticipant a,
    ScheduleConflictParticipant b,
    ConflictState state,
    String? reason,
  ) async {
    if (!a.hasStableSeriesIdentity || !b.hasStableSeriesIdentity) {
      throw const ConflictValidationError(
        'current-and-future scope requires stable series identities',
      );
    }
    final series = _canonicalSeries(a, b);
    final effectiveFrom = _date(a.occurrenceDate);
    final ends = [
      a.finiteSeriesEnd,
      b.finiteSeriesEnd,
    ].whereType<DateTime>().toList()..sort();
    final effectiveThrough = ends.isEmpty ? null : _date(ends.first);
    await database.transaction(() async {
      final existing =
          await (database.select(database.scheduleRelationRules)..where(
                (row) =>
                    row.accountId.equals(accountId) &
                    row.leftSeriesType.equals(series.$1.seriesType!) &
                    row.leftSeriesId.equals(series.$1.seriesId!) &
                    row.rightSeriesType.equals(series.$2.seriesType!) &
                    row.rightSeriesId.equals(series.$2.seriesId!) &
                    row.effectiveFrom.equals(effectiveFrom),
              ))
              .getSingleOrNull();
      final ruleId = existing?.id ?? _uuid.v4();
      final matching = database.delete(database.scheduleRelationRules)
        ..where(
          (row) =>
              row.accountId.equals(accountId) &
              row.leftSeriesType.equals(series.$1.seriesType!) &
              row.leftSeriesId.equals(series.$1.seriesId!) &
              row.rightSeriesType.equals(series.$2.seriesType!) &
              row.rightSeriesId.equals(series.$2.seriesId!) &
              row.effectiveFrom.equals(effectiveFrom),
        );
      if (state == ConflictState.unclassified) {
        await matching.go();
      } else {
        final timestamp = now();
        await database
            .into(database.scheduleRelationRules)
            .insertOnConflictUpdate(
              ScheduleRelationRulesCompanion.insert(
                id: ruleId,
                accountId: accountId,
                leftSeriesType: series.$1.seriesType!,
                leftSeriesId: series.$1.seriesId!,
                rightSeriesType: series.$2.seriesType!,
                rightSeriesId: series.$2.seriesId!,
                conflictState: _stateStorage(state),
                reason: Value(reason),
                effectiveFrom: effectiveFrom,
                effectiveThrough: Value(effectiveThrough),
                createdAt: existing?.createdAt ?? timestamp,
                updatedAt: timestamp,
              ),
            );
      }
      await _logClassification(state);
      await undoRecorder.record(
        UndoCommand(
          kind: 'conflict_classification',
          accountId: accountId,
          payload: {
            'entity': 'schedule_relation_rule',
            'id': ruleId,
            'before': existing == null ? null : _ruleSnapshot(existing),
          },
        ),
      );
    });
  }

  Future<void> _logClassification(ConflictState state) =>
      database.actionLogsRepository.append(
        accountId: accountId,
        source: 'user',
        actionType: 'conflict_classification',
        result: 'success',
        safeSummary: 'Updated an event-pair classification to ${state.name}.',
        occurredAt: now(),
      );

  (ScheduleConflictParticipant, ScheduleConflictParticipant)
      _canonicalParticipants(
    ScheduleConflictParticipant a,
    ScheduleConflictParticipant b,
  ) =>
          a.canonicalKey.compareTo(b.canonicalKey) <= 0 ? (a, b) : (b, a);

  (ScheduleConflictParticipant, ScheduleConflictParticipant) _canonicalSeries(
    ScheduleConflictParticipant a,
    ScheduleConflictParticipant b,
  ) {
    final aKey = '${a.seriesType}:${a.seriesId}';
    final bKey = '${b.seriesType}:${b.seriesId}';
    return aKey.compareTo(bKey) <= 0 ? (a, b) : (b, a);
  }

  String _stateStorage(ConflictState state) => switch (state) {
    ConflictState.conflict => 'conflict',
    ConflictState.nonConflict => 'no_conflict',
    ConflictState.unclassified => throw StateError(
      'unclassified is represented by no row',
    ),
  };

  ConflictPairState? _conflictPairState(String? value) => switch (value) {
    'conflict' => ConflictPairState.conflict,
    'no_conflict' => ConflictPairState.noConflict,
    _ => null,
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

  String _date(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  Map<String, Object?> _relationSnapshot(ScheduleRelation row) => {
    'leftKind': row.leftKind,
    'leftId': row.leftId,
    'rightKind': row.rightKind,
    'rightId': row.rightId,
    'leftEventId': row.leftEventId,
    'leftPlanBlockId': row.leftPlanBlockId,
    'rightEventId': row.rightEventId,
    'rightPlanBlockId': row.rightPlanBlockId,
    'conflictState': row.conflictState,
    'reason': row.reason,
    'createdAt': row.createdAt,
    'updatedAt': row.updatedAt,
  };

  Map<String, Object?> _ruleSnapshot(ScheduleRelationRule row) => {
    'leftSeriesType': row.leftSeriesType,
    'leftSeriesId': row.leftSeriesId,
    'rightSeriesType': row.rightSeriesType,
    'rightSeriesId': row.rightSeriesId,
    'conflictState': row.conflictState,
    'reason': row.reason,
    'effectiveFrom': row.effectiveFrom,
    'effectiveThrough': row.effectiveThrough,
    'createdAt': row.createdAt,
    'updatedAt': row.updatedAt,
  };

  CalendarEventLocator? _tryDecodeLocator(String id) {
    if (!id.startsWith('occ_v1.') &&
        !id.startsWith('event_v1.') &&
        !id.startsWith('series_v1.')) {
      return null;
    }
    try {
      return decodeCalendarEventLocator(id);
    } on FormatException {
      return null;
    }
  }

  /// Builds a [ScheduleGridItem] for a recurring occurrence from its series +
  /// composed occurrence so the shared conflict projection can resolve timed
  /// overlap and series identity. The item id stays the encoded locator; the
  /// raw series id / occurrence key never surface.
  Future<ScheduleGridItem?> _occurrenceGridItem(
    RecurringOccurrenceLocator locator,
  ) async {
    final service = RecurrenceService(database: database, accountId: accountId);
    final series = await service.seriesRowOrNull(locator.seriesId);
    if (series == null) return null;
    final RecurringOccurrence occurrence;
    try {
      occurrence = await service.occurrence(
        locator.seriesId,
        locator.occurrenceKey,
      );
    } on OccurrenceNotFoundError {
      return null;
    }
    final locatorText = encodeCalendarEventLocator(locator);
    if (occurrence.allDay) {
      return ScheduleGridItem.fromEvent(
        EffectiveEvent.allDay(
          id: locatorText,
          title: occurrence.title,
          startDate: occurrence.startDate!,
          endDateExclusive: occurrence.endDateExclusive!,
          courseSeriesId: series.id,
          recurringSeries: true,
          eventType: 'personal',
        ),
      );
    }
    return ScheduleGridItem.fromEvent(
      EffectiveEvent.timed(
        id: locatorText,
        title: occurrence.title,
        startAt: occurrence.startAt!,
        endAt: occurrence.endAt!,
        courseSeriesId: series.id,
        recurringSeries: true,
        eventType: 'personal',
      ),
    );
  }
}
