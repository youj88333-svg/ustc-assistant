import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';

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
      (seriesType == 'course_series' ||
          seriesType == 'calendar_event_series');
}

class ConflictService {
  ConflictService({
    required this.database,
    required this.accountId,
    int Function()? now,
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final AppDatabase database;
  final String accountId;
  final int Function() now;
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

  Future<ConflictState> stateForPair(
    EventConflictParticipant a,
    EventConflictParticipant b,
  ) async {
    final events = _canonicalEvents(a.eventId, b.eventId);
    final occurrence =
        await (database.select(database.scheduleRelations)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.leftKind.equals('event') &
                  row.leftId.equals(events.$1) &
                  row.rightKind.equals('event') &
                  row.rightId.equals(events.$2),
            ))
            .getSingleOrNull();
    if (occurrence != null) {
      return _stateFromStorage(occurrence.conflictState);
    }
    if (!a.hasStableSeriesIdentity || !b.hasStableSeriesIdentity) {
      return ConflictState.unclassified;
    }
    final series = _canonicalSeries(a, b);
    final date = _date(a.occurrenceDate);
    final rules = await (database.select(database.scheduleRelationRules)..where(
          (row) =>
              row.accountId.equals(accountId) &
              row.leftSeriesType.equals(series.$1.seriesType!) &
              row.leftSeriesId.equals(series.$1.seriesId!) &
              row.rightSeriesType.equals(series.$2.seriesType!) &
              row.rightSeriesId.equals(series.$2.seriesId!) &
              row.effectiveFrom.isSmallerOrEqualValue(date),
        ))
        .get();
    for (final rule in rules) {
      if (rule.effectiveThrough == null ||
          rule.effectiveThrough!.compareTo(date) >= 0) {
        return _stateFromStorage(rule.conflictState);
      }
    }
    return ConflictState.unclassified;
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
        final timestamp = now();
        await database.into(database.scheduleRelations).insertOnConflictUpdate(
          ScheduleRelationsCompanion.insert(
            id: existing?.id ?? _uuid.v4(),
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
    final ends = [a.finiteSeriesEnd, b.finiteSeriesEnd]
        .whereType<DateTime>()
        .toList()
      ..sort();
    final effectiveThrough = ends.isEmpty ? null : _date(ends.first);
    await database.transaction(() async {
      final matching =
          database.delete(database.scheduleRelationRules)
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
        final timestamp = now();
        await database
            .into(database.scheduleRelationRules)
            .insertOnConflictUpdate(
              ScheduleRelationRulesCompanion.insert(
                id: existing?.id ?? _uuid.v4(),
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

  ConflictState _stateFromStorage(String? value) => switch (value) {
    'conflict' => ConflictState.conflict,
    'no_conflict' => ConflictState.nonConflict,
    _ => ConflictState.unclassified,
  };

  String _date(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
