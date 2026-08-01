import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../tasks/application/undo_recorder.dart';
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

class EventConflictParticipant {
  const EventConflictParticipant({
    required this.eventId,
    required this.occurrenceDate,
    this.seriesType,
    this.seriesId,
    this.finiteSeriesEnd,
  });

  final String eventId;
  final DateTime occurrenceDate;
  final String? seriesType;
  final String? seriesId;
  final DateTime? finiteSeriesEnd;

  bool get hasStableSeriesIdentity =>
      seriesId != null &&
      (seriesType == 'course_series' || seriesType == 'calendar_event_series');
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
    EventConflictParticipant a,
    EventConflictParticipant b,
    ConflictState state, {
    ConflictScope scope = ConflictScope.occurrence,
    String? reason,
  }) {
    if (a.eventId == b.eventId) {
      throw const ConflictValidationError(
        'a conflict pair requires two events',
      );
    }
    return scope == ConflictScope.occurrence
        ? _classifyOccurrence(a, b, state, reason)
        : _classifyCurrentAndFuture(a, b, state, reason);
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
    EventConflictParticipant a,
    EventConflictParticipant b,
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

  /// Builds a [ScheduleGridItem] for an [EventConflictParticipant] from the
  /// underlying calendar row so the shared projection can resolve overlap and
  /// series identity. Returns null when the event is missing for this account.
  Future<ScheduleGridItem?> _gridItemFor(EventConflictParticipant participant) async {
    final event =
        await (database.select(database.calendarEvents)..where(
              (row) =>
                  row.id.equals(participant.eventId) &
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

  Future<bool> showConflictWarning(
    EventConflictParticipant a,
    EventConflictParticipant b,
  ) async => await stateForPair(a, b) == ConflictState.conflict;

  Future<void> _classifyOccurrence(
    EventConflictParticipant a,
    EventConflictParticipant b,
    ConflictState state,
    String? reason,
  ) async {
    final events = _canonicalEvents(a.eventId, b.eventId);
    await database.transaction(() async {
      final existing =
          await (database.select(database.scheduleRelations)..where(
                (row) =>
                    row.accountId.equals(accountId) &
                    row.leftKind.equals('event') &
                    row.leftId.equals(events.$1) &
                    row.rightKind.equals('event') &
                    row.rightId.equals(events.$2),
              ))
              .getSingleOrNull();
      final relationId = existing?.id ?? _uuid.v4();
      final query = database.delete(database.scheduleRelations)
        ..where(
          (row) =>
              row.accountId.equals(accountId) &
              row.leftKind.equals('event') &
              row.leftId.equals(events.$1) &
              row.rightKind.equals('event') &
              row.rightId.equals(events.$2),
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
                leftKind: const Value('event'),
                leftId: Value(events.$1),
                leftEventId: Value(events.$1),
                rightKind: const Value('event'),
                rightId: Value(events.$2),
                rightEventId: Value(events.$2),
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

  Future<void> _classifyCurrentAndFuture(
    EventConflictParticipant a,
    EventConflictParticipant b,
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

  (String, String) _canonicalEvents(String a, String b) =>
      a.compareTo(b) <= 0 ? (a, b) : (b, a);

  (EventConflictParticipant, EventConflictParticipant) _canonicalSeries(
    EventConflictParticipant a,
    EventConflictParticipant b,
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
    'rightEventId': row.rightEventId,
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
}
