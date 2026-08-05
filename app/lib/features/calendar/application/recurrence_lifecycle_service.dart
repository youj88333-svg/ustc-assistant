import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../tasks/application/undo_recorder.dart';
import '../domain/personal_event.dart';
import '../domain/recurrence_expander.dart';
import '../domain/recurrence_rule.dart';
import 'recurrence_service.dart';

/// The scope of a recurring delete / cancel / reopen / restore action.
enum RecurringActionScope {
  /// Only the selected occurrence.
  onlyThis('only_this'),

  /// The selected occurrence and every later occurrence (a split segment).
  thisAndFuture('this_and_future'),

  /// Every occurrence in the whole series.
  wholeSeries('whole_series');

  const RecurringActionScope(this.label);

  final String label;

  static RecurringActionScope fromLabel(String label) => switch (label) {
        'only_this' => RecurringActionScope.onlyThis,
        'this_and_future' => RecurringActionScope.thisAndFuture,
        'whole_series' => RecurringActionScope.wholeSeries,
        _ => throw const ScopeRequiredError(),
      };
}

/// A recurring lifecycle action.
enum RecurringLifecycleAction { cancel, delete, reopen, restore }

/// Thrown when a repeating cancel / delete / restore is requested without an
/// explicit scope. The caller must ask the user to pick between
/// `only_this` / `this_and_future` / `whole_series` before mutating anything.
class ScopeRequiredError implements Exception {
  const ScopeRequiredError();

  @override
  String toString() => 'ScopeRequiredError';
}

/// The series or occurrence exception changed since the caller's preflight.
class StaleRecurringTarget implements Exception {
  const StaleRecurringTarget();

  @override
  String toString() => 'StaleRecurringTarget';
}

/// The occurrence / series is already soft-deleted.
class AlreadyLifecycleDeleted implements Exception {
  const AlreadyLifecycleDeleted();

  @override
  String toString() => 'AlreadyLifecycleDeleted';
}

/// The requested lifecycle transition is not valid for the current state.
class InvalidRecurringTransition implements Exception {
  const InvalidRecurringTransition(this.message);

  final String message;

  @override
  String toString() => 'InvalidRecurringTransition: $message';
}

/// The read-only impact of an action on a recurring target, computed without
/// any write. Used by the write preflight to decide whether a scope is required
/// and to surface the affected counts and the 366-day / infinite flags.
class RecurringImpactPreview {
  const RecurringImpactPreview({
    required this.title,
    required this.occurrenceStart,
    required this.affectedOccurrences,
    required this.over366Days,
    required this.infinite,
    required this.affectedReminders,
    required this.affectedExceptions,
    required this.affectedRelations,
    required this.availableScopes,
    this.scopeRequired = false,
  });

  final String title;
  final DateTime? occurrenceStart;
  final int affectedOccurrences;
  final bool over366Days;
  final bool infinite;
  final int affectedReminders;
  final int affectedExceptions;
  final int affectedRelations;
  final List<String> availableScopes;

  /// Whether the caller MUST supply an explicit scope for a repeat action
  /// (`only_this` / `this_and_future` / `whole_series`) because it was omitted
  /// on an ambiguous (infinite / beyond-horizon) occurrence. Set only when an
  /// unscoped repeat action was requested without a scope.
  final bool scopeRequired;

  /// Whether this target is ambiguous (infinite / beyond the 366-day horizon)
  /// and therefore demands an explicit scope on a repeat action.
  bool get requiresScope => over366Days || infinite;
}

/// The higher-level "three-scope delete / cancel / restore lifecycle" wrapper
/// over [RecurrenceService]. This is what Agent write tools and the management
/// UI call for repeating personal schedules.
///
/// - [RecurringActionScope.onlyThis]: cancel writes a status override on the
///   single occurrence; delete sets that occurrence's exception `deletedAt`
///   (creating an empty override tombstone when none exists); reopen/restore
///   revert the original override.
/// - [RecurringActionScope.thisAndFuture]: split the series at the selected
///   occurrence via [RecurrenceService.editThisAndFuture] (truncating the old
///   segment and inserting a new one), then cancel/delete apply to the new
///   segment; reopen/restore act only on that segment, never on history.
/// - [RecurringActionScope.wholeSeries]: only change the series `status` /
///   `deletedAt`; never materialize occurrences; historical exceptions are
///   preserved.
///
/// Every action re-checks the series / exception version and records an Undo
/// snapshot in the same Drift transaction as the mutation.
class RecurringLifecycleService {
  RecurringLifecycleService({
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

  RecurrenceService get _recurrence => RecurrenceService(
        database: database,
        accountId: accountId,
        now: now,
        logToActionLog: logToActionLog,
      );

  static const int _horizonDays = 366;

  // ---------------------------------------------------------------------------
  // Preview
  // ---------------------------------------------------------------------------

  /// Computes the read-only impact preview for an action on a whole series
  /// (when [occurrenceKey] is null) or on one occurrence at [scope].
  ///
  /// Throws [ScopeRequiredError] when a repeat action (cancel/delete/restore)
  /// is requested on an occurrence without an explicit scope.
  Future<RecurringImpactPreview> previewImpact({
    required String seriesId,
    String? occurrenceKey,
    RecurringActionScope? scope,
    RecurringLifecycleAction? action,
  }) async {
    final series = await _recurrence.seriesRow(seriesId);
    final rule = RecurrenceRule.decode(series.recurrenceJson);
    final infinite = rule.untilDate == null;

    List<String> availableScopes;
    DateTime? occurrenceStart;
    if (occurrenceKey == null) {
      availableScopes = [RecurringActionScope.wholeSeries.label];
    } else {
      final occurrence = await _recurrence.occurrence(seriesId, occurrenceKey);
      occurrenceStart =
          occurrence.allDay ? occurrence.startDate! : occurrence.startAt!;
      availableScopes = [
        RecurringActionScope.onlyThis.label,
        RecurringActionScope.thisAndFuture.label,
        RecurringActionScope.wholeSeries.label,
      ];
    }

    // An unscoped repeat action on an occurrence is ambiguous: flag it so the
    // write preflight can return `scope_required` without any mutation.
    final scopeRequired = scope == null &&
        occurrenceKey != null &&
        action != null &&
        action != RecurringLifecycleAction.reopen;
    final effective = scope ?? RecurringActionScope.wholeSeries;

    final affectedExceptions =
        await _countExceptions(series, rule, occurrenceKey, effective);
    final affectedReminders =
        await _countReminders(series, rule, occurrenceKey, effective);
    final affectedRelations =
        await _countRelations(series, rule, occurrenceKey, effective);
    final (count, over366) =
        _impactCount(series, rule, occurrenceKey, effective);

    return RecurringImpactPreview(
      title: series.title,
      occurrenceStart: occurrenceStart,
      affectedOccurrences: count,
      over366Days: over366,
      infinite: infinite,
      affectedReminders: affectedReminders,
      affectedExceptions: affectedExceptions,
      affectedRelations: affectedRelations,
      availableScopes: availableScopes,
      scopeRequired: scopeRequired,
    );
  }

  (int, bool) _impactCount(
    CalendarEventSery series,
    RecurrenceRule rule,
    String? occurrenceKey,
    RecurringActionScope scope,
  ) {
    final horizonEnd =
        dateOnly(rule.anchor).add(const Duration(days: _horizonDays - 1));
    final over366 = rule.untilDate == null ||
        dateOnly(rule.untilDate!).isAfter(horizonEnd);

    DateTime from;
    switch (scope) {
      case RecurringActionScope.onlyThis:
        return (1, over366);
      case RecurringActionScope.thisAndFuture:
        from = occurrenceKey == null
            ? rule.anchor
            : originalStartFromOccurrenceKey(series.id, occurrenceKey);
      case RecurringActionScope.wholeSeries:
        from = rule.anchor;
    }
    final count = expandRecurrence(
      rule,
      from: from,
      through:
          DateTime(horizonEnd.year, horizonEnd.month, horizonEnd.day, 23, 59, 59),
    ).where((value) => _recurrence.withinSeriesBounds(series, value)).length;
    return (count, over366);
  }

  Future<int> _countExceptions(
    CalendarEventSery series,
    RecurrenceRule rule,
    String? occurrenceKey,
    RecurringActionScope scope,
  ) async {
    final rows = await _recurrence.exceptionRows(series.id);
    if (occurrenceKey == null) return rows.length;
    if (scope == RecurringActionScope.onlyThis) {
      return rows.where((row) => row.occurrenceKey == occurrenceKey).length;
    }
    final from = originalStartFromOccurrenceKey(series.id, occurrenceKey);
    return rows
        .where((row) => !_exceptionOriginal(row).isBefore(from))
        .length;
  }

  Future<int> _countReminders(
    CalendarEventSery series,
    RecurrenceRule rule,
    String? occurrenceKey,
    RecurringActionScope scope,
  ) async {
    final anchors = await _recurrence.exceptionRows(series.id);
    final anchorIds = anchors.map((row) => row.id).toSet();
    if (anchorIds.isEmpty) return 0;
    final rows = await (database.select(database.reminders)..where(
          (row) => row.accountId.equals(accountId) & row.state.equals('desired'),
        ))
        .get();
    return rows
        .where((row) => anchorIds.contains(row.occurrenceExceptionId))
        .length;
  }

  Future<int> _countRelations(
    CalendarEventSery series,
    RecurrenceRule rule,
    String? occurrenceKey,
    RecurringActionScope scope,
  ) async {
    final anchors = await _recurrence.exceptionRows(series.id);
    final anchorIds = anchors.map((row) => row.id).toSet();
    if (anchorIds.isEmpty) return 0;
    final relations = await (database.select(database.scheduleRelations)..where(
          (row) => row.accountId.equals(accountId),
        ))
        .get();
    return relations
        .where((row) =>
            (row.leftOccurrenceExceptionId != null &&
                anchorIds.contains(row.leftOccurrenceExceptionId)) ||
            (row.rightOccurrenceExceptionId != null &&
                anchorIds.contains(row.rightOccurrenceExceptionId)))
        .length;
  }

  DateTime _exceptionOriginal(CalendarEventOccurrenceException exception) =>
      exception.originalStartAt != null
      ? DateTime.fromMillisecondsSinceEpoch(exception.originalStartAt!)
      : DateTime.parse(exception.originalStartDate!);

  // ---------------------------------------------------------------------------
  // Occurrence actions
  // ---------------------------------------------------------------------------

  Future<void> cancel({
    required String seriesId,
    required String occurrenceKey,
    required RecurringActionScope scope,
    int? expectedSeriesUpdatedAt,
    int? expectedExceptionUpdatedAt,
  }) => _run(seriesId, occurrenceKey, scope, RecurringLifecycleAction.cancel,
      expectedSeriesUpdatedAt: expectedSeriesUpdatedAt,
      expectedExceptionUpdatedAt: expectedExceptionUpdatedAt);

  Future<void> delete({
    required String seriesId,
    required String occurrenceKey,
    required RecurringActionScope scope,
    int? expectedSeriesUpdatedAt,
    int? expectedExceptionUpdatedAt,
  }) => _run(seriesId, occurrenceKey, scope, RecurringLifecycleAction.delete,
      expectedSeriesUpdatedAt: expectedSeriesUpdatedAt,
      expectedExceptionUpdatedAt: expectedExceptionUpdatedAt);

  Future<void> reopen({
    required String seriesId,
    required String occurrenceKey,
    required RecurringActionScope scope,
    int? expectedSeriesUpdatedAt,
    int? expectedExceptionUpdatedAt,
  }) => _run(seriesId, occurrenceKey, scope, RecurringLifecycleAction.reopen,
      expectedSeriesUpdatedAt: expectedSeriesUpdatedAt,
      expectedExceptionUpdatedAt: expectedExceptionUpdatedAt);

  Future<void> restore({
    required String seriesId,
    required String occurrenceKey,
    required RecurringActionScope scope,
    int? expectedSeriesUpdatedAt,
    int? expectedExceptionUpdatedAt,
  }) => _run(seriesId, occurrenceKey, scope, RecurringLifecycleAction.restore,
      expectedSeriesUpdatedAt: expectedSeriesUpdatedAt,
      expectedExceptionUpdatedAt: expectedExceptionUpdatedAt);

  // ---------------------------------------------------------------------------
  // Series actions (whole_series)
  // ---------------------------------------------------------------------------

  Future<void> cancelSeries(String seriesId, {int? expectedUpdatedAt}) =>
      _runWholeSeries(seriesId, RecurringLifecycleAction.cancel,
          expectedUpdatedAt: expectedUpdatedAt);

  Future<void> deleteSeries(String seriesId, {int? expectedUpdatedAt}) =>
      _runWholeSeries(seriesId, RecurringLifecycleAction.delete,
          expectedUpdatedAt: expectedUpdatedAt);

  Future<void> reopenSeries(String seriesId, {int? expectedUpdatedAt}) =>
      _runWholeSeries(seriesId, RecurringLifecycleAction.reopen,
          expectedUpdatedAt: expectedUpdatedAt);

  Future<void> restoreSeries(String seriesId, {int? expectedUpdatedAt}) =>
      _runWholeSeries(seriesId, RecurringLifecycleAction.restore,
          expectedUpdatedAt: expectedUpdatedAt);

  Future<void> _runWholeSeries(
    String seriesId,
    RecurringLifecycleAction action, {
    int? expectedUpdatedAt,
  }) async {
    await database.transaction(() async {
      final series = await _requireSeries(seriesId);
      _checkVersion(series.updatedAt, expectedUpdatedAt);
      final before = {'series': _seriesSnapshot(series)};
      final timestamp = now();
      switch (action) {
        case RecurringLifecycleAction.cancel:
          _requireNotDeleted(series);
          if (series.status == 'cancelled') {
            throw const InvalidRecurringTransition('series already cancelled');
          }
          await _writeSeriesStatus(seriesId, 'cancelled', timestamp);
        case RecurringLifecycleAction.delete:
          _requireNotDeleted(series);
          await _writeSeriesDeletedAt(seriesId, timestamp);
        case RecurringLifecycleAction.reopen:
          _requireNotDeleted(series);
          if (series.status != 'cancelled') {
            throw const InvalidRecurringTransition('series is not cancelled');
          }
          await _writeSeriesStatus(seriesId, 'active', timestamp);
        case RecurringLifecycleAction.restore:
          if (series.deletedAt == null) {
            throw const InvalidRecurringTransition('series is not deleted');
          }
          await _writeSeriesDeletedAtNull(seriesId, timestamp);
      }
      await _log(action, RecurringActionScope.wholeSeries);
      await _recordUndo(
        action,
        seriesId,
        scope: RecurringActionScope.wholeSeries,
        occurrenceKey: null,
        before: before,
      );
    });
  }

  Future<CalendarEventSery> _requireSeries(String seriesId) async {
    final series = await _recurrence.seriesRowOrNull(seriesId);
    if (series == null) throw const OccurrenceNotFoundError();
    return series;
  }

  Future<void> _run(
    String seriesId,
    String occurrenceKey,
    RecurringActionScope scope,
    RecurringLifecycleAction action, {
    int? expectedSeriesUpdatedAt,
    int? expectedExceptionUpdatedAt,
  }) async {
    if (scope == RecurringActionScope.wholeSeries) {
      await _runWholeSeries(seriesId, action,
          expectedUpdatedAt: expectedSeriesUpdatedAt);
      return;
    }
    if (scope == RecurringActionScope.thisAndFuture) {
      await _runThisAndFuture(
        seriesId,
        occurrenceKey,
        action,
        expectedSeriesUpdatedAt: expectedSeriesUpdatedAt,
        expectedExceptionUpdatedAt: expectedExceptionUpdatedAt,
      );
      return;
    }
    await database.transaction(() async {
      final series = await _requireSeries(seriesId);
      _checkVersion(series.updatedAt, expectedSeriesUpdatedAt);
      final exception =
          await _recurrence.existingOccurrenceAnchor(seriesId, occurrenceKey);
      _checkVersion(exception?.updatedAt, expectedExceptionUpdatedAt);
      final before = {
        'series': _seriesSnapshot(series),
        'exception': exception == null ? null : _exceptionSnapshot(exception),
      };
      final timestamp = now();

      switch (action) {
        case RecurringLifecycleAction.cancel:
          _requireNotDeleted(series);
          final occurrence = await _recurrence.occurrence(seriesId, occurrenceKey);
          await _cancelOnlyThis(series, occurrence, exception, timestamp);
        case RecurringLifecycleAction.delete:
          _requireNotDeleted(series);
          final occurrence = await _recurrence.occurrence(seriesId, occurrenceKey);
          await _deleteOnlyThis(series, occurrence, exception, timestamp);
        case RecurringLifecycleAction.reopen:
          await _reopenOnlyThis(series, exception, timestamp);
        case RecurringLifecycleAction.restore:
          await _restoreOnlyThis(series, exception, timestamp);
      }
      await _log(action, RecurringActionScope.onlyThis);
      await _recordUndo(
        action,
        seriesId,
        scope: RecurringActionScope.onlyThis,
        occurrenceKey: occurrenceKey,
        before: before,
      );
    });
  }

  // -- only_this --------------------------------------------------------------

  Future<void> _cancelOnlyThis(
    CalendarEventSery series,
    RecurringOccurrence occurrence,
    CalendarEventOccurrenceException? exception,
    int timestamp,
  ) async {
    if (exception?.deletedAt != null) throw const AlreadyLifecycleDeleted();
    if (exception?.status != null) {
      throw const InvalidRecurringTransition('occurrence already has a status');
    }
    if (series.status == 'cancelled') {
      throw const InvalidRecurringTransition('series already cancelled');
    }
    await _writeStatusOverride(series, occurrence, EventStatus.cancelled, timestamp);
  }

  Future<void> _deleteOnlyThis(
    CalendarEventSery series,
    RecurringOccurrence occurrence,
    CalendarEventOccurrenceException? exception,
    int timestamp,
  ) async {
    if (exception?.deletedAt != null) throw const AlreadyLifecycleDeleted();
    if (exception == null) {
      // Create an empty override tombstone carrying only deletedAt.
      await _recurrence.ensureOccurrenceAnchor(series.id, occurrence.occurrenceKey);
      final anchor = (await _recurrence.existingOccurrenceAnchor(
        series.id,
        occurrence.occurrenceKey,
      ))!;
      await (database.update(database.calendarEventOccurrenceExceptions)
            ..where((row) => row.id.equals(anchor.id)))
          .write(
            CalendarEventOccurrenceExceptionsCompanion(
              deletedAt: Value(timestamp),
              updatedAt: Value(timestamp),
            ),
          );
    } else {
      await (database.update(database.calendarEventOccurrenceExceptions)
            ..where((row) => row.id.equals(exception.id)))
          .write(
            CalendarEventOccurrenceExceptionsCompanion(
              deletedAt: Value(timestamp),
              updatedAt: Value(timestamp),
            ),
          );
    }
  }

  Future<void> _reopenOnlyThis(
    CalendarEventSery series,
    CalendarEventOccurrenceException? exception,
    int timestamp,
  ) async {
    if (exception?.deletedAt != null) {
      throw const InvalidRecurringTransition(
        'restore a deleted occurrence instead of reopening',
      );
    }
    await _clearStatusOverride(exception, timestamp);
  }

  Future<void> _restoreOnlyThis(
    CalendarEventSery series,
    CalendarEventOccurrenceException? exception,
    int timestamp,
  ) async {
    if (exception == null || exception.deletedAt == null) {
      throw const InvalidRecurringTransition('occurrence is not deleted');
    }
    await (database.update(database.calendarEventOccurrenceExceptions)
          ..where((row) => row.id.equals(exception.id)))
        .write(
          CalendarEventOccurrenceExceptionsCompanion(
            deletedAt: const Value(null),
            updatedAt: Value(timestamp),
          ),
        );
  }

  Future<void> _writeStatusOverride(
    CalendarEventSery series,
    RecurringOccurrence occurrence,
    EventStatus status,
    int timestamp,
  ) async {
    final existing =
        await _recurrence.existingOccurrenceAnchor(series.id, occurrence.occurrenceKey);
    // When an override row already exists (e.g. the user renamed the occurrence
    // via editOnlyThis before cancelling), MERGE into it instead of replacing
    // the whole override, so non-status fields (title/time/etc.) are preserved.
    final (fields, override) = existing == null
        ? (<String>{'status'}, OccurrenceOverride(status: OverrideValue.set(status)))
        : _mergeStatusIntoOverride(existing, status);
    await database
        .into(database.calendarEventOccurrenceExceptions)
        .insertOnConflictUpdate(
          CalendarEventOccurrenceExceptionsCompanion.insert(
            id: existing?.id ?? _uuid.v4(),
            accountId: accountId,
            seriesId: series.id,
            occurrenceKey: occurrence.occurrenceKey,
            originalStartAt: Value(
              occurrence.allDay
                  ? null
                  : occurrence.originalStart.millisecondsSinceEpoch,
            ),
            originalStartDate: Value(
              occurrence.allDay ? dateText(occurrence.originalStart) : null,
            ),
            kind: 'override',
            overriddenFieldsJson: Value(jsonEncode(fields.toList()..sort())),
            overrideJson: jsonEncode(override.toJson()),
            status: Value(status.storage),
            orphaned: const Value(false),
            createdAt: existing?.createdAt ?? timestamp,
            updatedAt: timestamp,
          ),
        );
  }

  /// Returns the merged (fields, override) that keeps an existing override's
  /// non-status fields and only sets/overwrites the [status] field.
  (Set<String>, OccurrenceOverride) _mergeStatusIntoOverride(
    CalendarEventOccurrenceException existing,
    EventStatus status,
  ) {
    final decoded = OccurrenceOverride.decode(
      existing.overriddenFieldsJson,
      existing.overrideJson,
    );
    final merged = OccurrenceOverride(
      title: decoded.title,
      description: decoded.description,
      locationName: decoded.locationName,
      startAt: decoded.startAt,
      endAt: decoded.endAt,
      startDate: decoded.startDate,
      endDateExclusive: decoded.endDateExclusive,
      status: OverrideValue.set(status),
      completionPolicy: decoded.completionPolicy,
      importance: decoded.importance,
      color: decoded.color,
      tags: decoded.tags,
      reminderOffsetsMinutes: decoded.reminderOffsetsMinutes,
    );
    return (merged.fields, merged);
  }

  Future<void> _clearStatusOverride(
    CalendarEventOccurrenceException? exception,
    int timestamp,
  ) async {
    if (exception == null || exception.status == null) return;
    // If status was the only overridden field, drop the whole exception row.
    final fields = (jsonDecode(exception.overriddenFieldsJson) as List<dynamic>)
        .cast<String>()
        .where((field) => field != 'status')
        .toList();
    if (fields.isEmpty) {
      await (database.delete(database.calendarEventOccurrenceExceptions)
            ..where((row) => row.id.equals(exception.id)))
          .go();
      return;
    }
    final decoded =
        OccurrenceOverride.decode(exception.overriddenFieldsJson, exception.overrideJson);
    final keep = OccurrenceOverride(
      title: decoded.title,
      description: decoded.description,
      locationName: decoded.locationName,
      startAt: decoded.startAt,
      endAt: decoded.endAt,
      startDate: decoded.startDate,
      endDateExclusive: decoded.endDateExclusive,
      status: const OverrideValue.absent(),
      completionPolicy: decoded.completionPolicy,
      importance: decoded.importance,
      color: decoded.color,
      tags: decoded.tags,
      reminderOffsetsMinutes: decoded.reminderOffsetsMinutes,
    );
    await (database.update(database.calendarEventOccurrenceExceptions)
          ..where((row) => row.id.equals(exception.id)))
        .write(
          CalendarEventOccurrenceExceptionsCompanion(
            overriddenFieldsJson: Value(jsonEncode(fields..sort())),
            overrideJson: Value(jsonEncode(keep.toJson())),
            status: const Value(null),
            updatedAt: Value(timestamp),
          ),
        );
  }

  // -- this_and_future --------------------------------------------------------

  Future<void> _runThisAndFuture(
    String seriesId,
    String occurrenceKey,
    RecurringLifecycleAction action, {
    int? expectedSeriesUpdatedAt,
    int? expectedExceptionUpdatedAt,
  }) async {
    await database.transaction(() async {
      final series = await _requireSeries(seriesId);
      _checkVersion(series.updatedAt, expectedSeriesUpdatedAt);
      final occurrence = await _recurrence.occurrence(seriesId, occurrenceKey);
      final before = {
        'series': _seriesSnapshot(series),
        'scoped': true,
      };
      final timestamp = now();

      // reopen/restore act on the current segment directly (no re-split):
      // the caller targets the segment that owns the occurrence.
      if (action == RecurringLifecycleAction.reopen ||
          action == RecurringLifecycleAction.restore) {
        _requireNotDeleted(series);
        if (action == RecurringLifecycleAction.reopen) {
          if (series.status != 'cancelled') {
            throw const InvalidRecurringTransition(
              'this segment is not cancelled; a prior segment owns history',
            );
          }
          await _writeSeriesStatus(seriesId, 'active', timestamp);
        } else {
          if (series.deletedAt == null) {
            throw const InvalidRecurringTransition('this segment is not deleted');
          }
          await _writeSeriesDeletedAtNull(seriesId, timestamp);
        }
        await _log(action, RecurringActionScope.thisAndFuture);
        await _recordUndo(
          action,
          seriesId,
          scope: RecurringActionScope.thisAndFuture,
          occurrenceKey: occurrenceKey,
          before: before,
        );
        return;
      }

      // cancel/delete split the series at the occurrence into a truncated old
      // segment and a new future segment, then apply to the new segment.
      _requireNotDeleted(series);
      // TOCTOU re-check the split-boundary occurrence's exception override row
      // (Spec §25.1): editThisAndFuture migrates this exact row (re-keying it
      // onto the new segment or orphaning it), so a concurrent edit to that
      // override between propose and commit would otherwise be silently
      // overwritten. reopen/restore don't touch the exception row, so the
      // check is scoped to the split branch only. Null skips the check (no
      // anchor yet, or a back-compat no-version caller).
      final boundaryException = await _recurrence.existingOccurrenceAnchor(
        seriesId,
        occurrenceKey,
      );
      _checkVersion(boundaryException?.updatedAt, expectedExceptionUpdatedAt);
      final oldRule = RecurrenceRule.decode(series.recurrenceJson);
      final newAnchor = _occurrenceAsAnchor(series, occurrence);
      final ruleAnchor = occurrence.allDay
          ? occurrence.startDate!
          : (occurrence.startAt ?? occurrence.originalStart);
      // Capture the exception rows BEFORE the split so the undo snapshot can
      // reverse editThisAndFuture's migration (re-keying + orphaning). Each
      // row that editThisAndFuture moves to the new segment (or orphans) is
      // recorded with its original seriesId/occurrenceKey and full prior
      // state, so _restoreRecurringLifecycle can write it back exactly.
      final exceptionsBeforeSplit = await _recurrence.exceptionRows(seriesId);
      final newSeriesId = await _recurrence.editThisAndFuture(
        seriesId,
        occurrenceKey,
        anchor: newAnchor,
        rule: _futureRule(oldRule, ruleAnchor),
      );
      final migratedExceptions = await _migratedExceptions(
        exceptionsBeforeSplit,
        newSeriesId,
      );
      before['newSeriesId'] = newSeriesId;
      before['migratedExceptions'] = migratedExceptions;
      if (action == RecurringLifecycleAction.cancel) {
        await _writeSeriesStatus(newSeriesId, 'cancelled', timestamp);
      } else {
        // delete
        await _writeSeriesDeletedAt(newSeriesId, timestamp);
      }
      await _log(action, RecurringActionScope.thisAndFuture);
      await _recordUndo(
        action,
        seriesId,
        scope: RecurringActionScope.thisAndFuture,
        occurrenceKey: occurrenceKey,
        before: before,
        newSeriesId: newSeriesId,
        migratedExceptions: migratedExceptions,
      );
    });
  }

  /// Diffs the pre-split exception rows against their post-split state and
  /// returns the migration records needed to reverse `editThisAndFuture`.
  ///
  /// `editThisAndFuture` either re-keys a row onto [newSeriesId] (compatible
  /// future exception) or orphans it in place on the old series (incompatible
  /// future exception). For each row whose `seriesId`, `occurrenceKey`, or
  /// `orphaned` flag changed, we capture the ORIGINAL pre-split values plus
  /// the full prior row state so the undo can restore the row verbatim. Rows
  /// that did not move (history before the split boundary) are not recorded.
  Future<List<Map<String, Object?>>> _migratedExceptions(
    List<CalendarEventOccurrenceException> beforeRows,
    String newSeriesId,
  ) async {
    if (beforeRows.isEmpty) return const [];
    final ids = beforeRows.map((row) => row.id).toList();
    final afterRows = await (database.select(
      database.calendarEventOccurrenceExceptions,
    )..where((row) => row.id.isIn(ids)))
        .get();
    final afterById = {for (final row in afterRows) row.id: row};
    final migrated = <Map<String, Object?>>[];
    for (final before in beforeRows) {
      final after = afterById[before.id];
      if (after == null) continue;
      final moved = after.seriesId != before.seriesId ||
          after.occurrenceKey != before.occurrenceKey ||
          after.orphaned != before.orphaned;
      if (!moved) continue;
      migrated.add({
        'id': before.id,
        'originalSeriesId': before.seriesId,
        'originalOccurrenceKey': before.occurrenceKey,
        'newSeriesId': after.seriesId,
        'newOccurrenceKey': after.occurrenceKey,
        'before': _exceptionSnapshot(before),
      });
    }
    return migrated;
  }

  PersonalEvent _occurrenceAsAnchor(
    CalendarEventSery series,
    RecurringOccurrence occurrence,
  ) {
    final type = personalEventTypeFromStorage(series.eventType);
    if (occurrence.allDay) {
      return PersonalEvent.allDay(
        title: occurrence.title,
        startDate: occurrence.startDate!,
        endDateExclusive: occurrence.endDateExclusive!,
        description: occurrence.description,
        locationName: occurrence.locationName,
        type: type,
        status: occurrence.status,
        completionPolicy: occurrence.completionPolicy,
        importance: occurrence.importance,
        tags: occurrence.tags,
      );
    }
    return PersonalEvent.timed(
      title: occurrence.title,
      startAt: occurrence.startAt!,
      endAt: occurrence.endAt!,
      description: occurrence.description,
      locationName: occurrence.locationName,
      type: type,
      status: occurrence.status,
      completionPolicy: occurrence.completionPolicy,
      importance: occurrence.importance,
      tags: occurrence.tags,
    );
  }

  RecurrenceRule _futureRule(RecurrenceRule original, DateTime originalStart) {
    switch (original.frequency) {
      case RecurrenceFrequency.daily:
        return RecurrenceRule.daily(
          anchor: originalStart,
          interval: original.interval,
          untilDate: original.untilDate,
        );
      case RecurrenceFrequency.weekly:
        return RecurrenceRule.weekly(
          anchor: originalStart,
          weekdays: original.weekdays,
          interval: original.interval,
          untilDate: original.untilDate,
        );
      case RecurrenceFrequency.monthly:
        return RecurrenceRule.monthly(
          anchor: originalStart,
          interval: original.interval,
          untilDate: original.untilDate,
        );
    }
  }

  // -- series-level writes ----------------------------------------------------

  Future<void> _writeSeriesStatus(String seriesId, String status, int timestamp) =>
      (database.update(database.calendarEventSeries)
            ..where(
              (row) => row.id.equals(seriesId) & row.accountId.equals(accountId),
            ))
          .write(
            CalendarEventSeriesCompanion(
              status: Value(status),
              updatedAt: Value(timestamp),
            ),
          );

  Future<void> _writeSeriesDeletedAt(String seriesId, int timestamp) =>
      (database.update(database.calendarEventSeries)
            ..where(
              (row) => row.id.equals(seriesId) & row.accountId.equals(accountId),
            ))
          .write(
            CalendarEventSeriesCompanion(
              deletedAt: Value(timestamp),
              updatedAt: Value(timestamp),
            ),
          );

  Future<void> _writeSeriesDeletedAtNull(String seriesId, int timestamp) =>
      (database.update(database.calendarEventSeries)
            ..where(
              (row) => row.id.equals(seriesId) & row.accountId.equals(accountId),
            ))
          .write(
            CalendarEventSeriesCompanion(
              deletedAt: const Value(null),
              updatedAt: Value(timestamp),
            ),
          );

  void _checkVersion(int? current, int? expected) {
    if (expected != null && current != expected) {
      throw const StaleRecurringTarget();
    }
  }

  void _requireNotDeleted(CalendarEventSery series) {
    if (series.deletedAt != null) throw const AlreadyLifecycleDeleted();
  }

  // -- snapshots / undo -------------------------------------------------------

  Map<String, Object?> _seriesSnapshot(CalendarEventSery series) => {
        'id': series.id,
        'accountId': series.accountId,
        'title': series.title,
        'eventType': series.eventType,
        'status': series.status,
        'recurrenceJson': series.recurrenceJson,
        'effectiveFrom': series.effectiveFrom,
        'effectiveThrough': series.effectiveThrough,
        'deletedAt': series.deletedAt,
        'updatedAt': series.updatedAt,
      };

  Map<String, Object?> _exceptionSnapshot(
    CalendarEventOccurrenceException exception,
  ) => {
        'id': exception.id,
        'seriesId': exception.seriesId,
        'occurrenceKey': exception.occurrenceKey,
        'originalStartAt': exception.originalStartAt,
        'originalStartDate': exception.originalStartDate,
        'kind': exception.kind,
        'overriddenFieldsJson': exception.overriddenFieldsJson,
        'overrideJson': exception.overrideJson,
        'status': exception.status,
        'orphaned': exception.orphaned,
        'deletedAt': exception.deletedAt,
        'createdAt': exception.createdAt,
        'updatedAt': exception.updatedAt,
      };

  String _safeSummary(RecurringLifecycleAction action, String scopeLabel) =>
      switch (action) {
        RecurringLifecycleAction.cancel => '取消重复日程（$scopeLabel）',
        RecurringLifecycleAction.delete => '删除重复日程（$scopeLabel）',
        RecurringLifecycleAction.reopen => '重新打开重复日程（$scopeLabel）',
        RecurringLifecycleAction.restore => '恢复重复日程（$scopeLabel）',
      };

  Future<void> _log(
    RecurringLifecycleAction action,
    RecurringActionScope scope,
  ) {
    if (!logToActionLog) return Future<void>.value();
    return database.actionLogsRepository.append(
        accountId: accountId,
        source: 'user',
        actionType: 'calendar_recurring_${action.name}',
        result: 'success',
        safeSummary: _safeSummary(action, scope.label),
        occurredAt: now(),
      );
  }

  Future<void> _recordUndo(
    RecurringLifecycleAction action,
    String seriesId, {
    required RecurringActionScope scope,
    required String? occurrenceKey,
    required Map<String, Object?> before,
    String? newSeriesId,
    List<Map<String, Object?>>? migratedExceptions,
  }) => undoRecorder.record(
        UndoCommand(
          kind: 'recurring_${action.name}',
          accountId: accountId,
          payload: {
            'entity': 'recurring_lifecycle',
            'action': action.name,
            'scope': scope.label,
            'seriesId': seriesId,
            'occurrenceKey': occurrenceKey,
            'before': before,
            if (newSeriesId != null) 'newSeriesId': newSeriesId,
            if (migratedExceptions != null)
              'migratedExceptions': migratedExceptions,
          },
          safeSummary: _safeSummary(action, ''),
        ),
      );
}