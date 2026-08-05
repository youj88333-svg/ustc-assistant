import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import 'undo_recorder.dart';

class InvalidUndoCommand implements Exception {
  const InvalidUndoCommand();
}

class UndoService implements UndoRecorder {
  UndoService({
    required this.database,
    required this.accountId,
    int Function()? now,
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final AppDatabase database;
  final String accountId;
  final int Function() now;
  static const _uuid = Uuid();

  @override
  Future<void> record(UndoCommand command) async {
    if (command.accountId != accountId || command.version != 1) {
      throw const InvalidUndoCommand();
    }
    await database.replaceUndoSlot(
      commandId: _uuid.v4(),
      payload: jsonEncode({
        'version': command.version,
        'kind': command.kind,
        'accountId': command.accountId,
        'safeSummary': command.safeSummary,
        'payload': command.payload,
      }),
    );
  }

  /// Account-safe preview of the most recent undoable action.
  ///
  /// Returns [UndoPreview.disabled] when no slot exists OR the slot belongs to
  /// another account. The preview carries ONLY the safe Chinese summary, the
  /// action kind, and a Beijing wall-clock timestamp — never the payload, a DB
  /// id, a ref, or an account identity. It never mutates the slot.
  Future<UndoPreview> preview() async {
    final slot = await database.select(database.undoSlot).getSingleOrNull();
    if (slot == null) return const UndoPreview.disabled();
    final decoded = _decodeValidated(slot.payload);
    // ACCOUNT SAFETY: a slot owned by another account must look identical to a
    // missing slot — unavailable with no summary, kind, or timestamp. Only when
    // the slot belongs to THIS account is any preview content read.
    if (decoded == null || decoded['accountId'] != accountId) {
      return const UndoPreview.disabled();
    }
    String storedSummary;
    final rawSummary = decoded['safeSummary'] as String?;
    if (rawSummary != null && rawSummary.isNotEmpty) {
      storedSummary = rawSummary;
    } else {
      // A v1 slot has no safe summary; fall back to a safe kind-derived label
      // (never derived from the payload).
      storedSummary = _summaryForKind(decoded['kind'] as String?);
    }
    return UndoPreview(
      available: true,
      kind: decoded['kind'] as String? ?? '',
      summary: storedSummary,
      beijingAt: _formatBeijing(now()),
    );
  }

  Future<bool> canUndo() async =>
      (await database.select(database.undoSlot).getSingleOrNull()) != null;

  Future<void> clearAtStartup() => database.delete(database.undoSlot).go();

  Future<void> undo() async {
    final slot = await database.select(database.undoSlot).getSingleOrNull();
    if (slot == null) throw const InvalidUndoCommand();

    final decoded = _decodeValidated(slot.payload);

    // A malformed (non-v1 / structurally invalid) slot belonging to this
    // account: the legacy behavior cleared it and recorded a failure so a bad
    // slot can never block a later undo. Deleting a malformed slot does not
    // violate account isolation (there is no legitimate foreign payload to
    // destroy — it has no account ownership).
    if (decoded == null) {
      await database.delete(database.undoSlot).go();
      await database.actionLogsRepository.append(
        accountId: accountId,
        source: 'user',
        actionType: 'undo',
        result: 'failure',
        safeSummary: 'Could not reverse the most recent local change.',
        occurredAt: now(),
      );
      throw const InvalidUndoCommand();
    }

    // ACCOUNT SAFETY: a valid v1 slot owned by another account must be rejected
    // WITHOUT deleting, mutating, or reverse-applying its payload. Foreign
    // undo/preview must leave the original slot untouched.
    if (decoded['accountId'] != accountId) {
      throw const InvalidUndoCommand();
    }

    final kind = decoded['kind'] as String;
    final payload = decoded['payload'] as Map<String, dynamic>;
    try {
      await database.transaction(() async {
        await _apply(payload);
        await database.actionLogsRepository.append(
          accountId: accountId,
          source: 'user',
          actionType: 'undo_$kind',
          result: 'success',
          safeSummary: 'Reversed the most recent local change.',
          occurredAt: now(),
        );
        await database.delete(database.undoSlot).go();
      });
    } catch (error) {
      // Failure while applying (e.g. a composite restore step threw): KEEP the
      // slot so the change is not silently lost, and log a SAFE failure (no
      // payload / id / raw exception in the summary).
      await database.actionLogsRepository.append(
        accountId: accountId,
        source: 'user',
        actionType: 'undo',
        result: 'failure',
        safeSummary: 'Could not reverse the most recent local change.',
        occurredAt: now(),
      );
      if (error is InvalidUndoCommand) rethrow;
      throw const InvalidUndoCommand();
    }
  }

  Future<void> _apply(Map<String, dynamic> payload) async {
    switch (payload['entity']) {
      case 'task':
        await _restoreTask(payload);
      case 'plan_block':
        await _restorePlanBlock(payload);
      case 'plan_block_split':
        await _restorePlanBlock(payload);
        await (database.delete(
          database.planBlocks,
        )..where((row) => row.id.equals(payload['createdId'] as String))).go();
      case 'calendar_event':
        await _restoreCalendarEvent(payload);
      case 'user_overlay':
        await _restoreOverlay(payload);
      case 'schedule_relation':
        await _restoreScheduleRelation(payload);
      case 'schedule_relation_rule':
        await _restoreScheduleRelationRule(payload);
      case 'reminder_override':
        await _restoreReminderOverride(payload);
      case 'jw_day_move':
        await _restoreJwDayMove(payload);
      case 'recurring_lifecycle':
        await _restoreRecurringLifecycle(payload);
      case 'composite':
        await _restoreComposite(payload);
      default:
        throw const InvalidUndoCommand();
    }
  }

  /// Restores a composite snapshot atomically: a sequence of typed restore
  /// operations covering entity rows, Reminder snapshots, TaskEventLinks, and
  /// Agent permission-policy config. Every operation reuses the existing
  /// single-entity restore helpers (no re-implementation of rollback). If ANY
  /// step throws, the whole transaction rolls back and the slot survives
  /// (handled by [undo]).
  Future<void> _restoreComposite(Map<String, dynamic> payload) async {
    final operations = payload['operations'];
    if (operations is! List) throw const InvalidUndoCommand();
    for (final raw in operations) {
      if (raw is! Map<String, dynamic>) throw const InvalidUndoCommand();
      switch (raw['entity']) {
        case 'task':
          await _restoreTask(raw);
        case 'plan_block':
          await _restorePlanBlock(raw);
        case 'plan_block_split':
          await _restorePlanBlock(raw);
          await (database.delete(
            database.planBlocks,
          )..where((row) => row.id.equals(raw['createdId'] as String))).go();
        case 'calendar_event':
          await _restoreCalendarEvent(raw);
        case 'user_overlay':
          await _restoreOverlay(raw);
        case 'schedule_relation':
          await _restoreScheduleRelation(raw);
        case 'schedule_relation_rule':
          await _restoreScheduleRelationRule(raw);
        case 'reminder_override':
          await _restoreReminderOverride(raw);
        case 'task_event_link':
          await _restoreTaskEventLink(raw);
        case 'permission_policy':
          await _restorePermissionPolicy(raw);
        case 'jw_day_move':
          await _restoreJwDayMove(raw);
        default:
          throw const InvalidUndoCommand();
      }
    }
  }

  Future<void> _restoreTaskEventLink(Map<String, dynamic> payload) async {
    final taskId = payload['taskId'] as String;
    final eventId = payload['eventId'] as String;
    final before = payload['before'];
    await (database.delete(database.taskEventLinks)
          ..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.taskId.equals(taskId) &
                row.eventId.equals(eventId),
          ))
        .go();
    if (before == null) return;
    final row = before as Map<String, dynamic>;
    await database
        .into(database.taskEventLinks)
        .insert(
          TaskEventLinksCompanion.insert(
            accountId: accountId,
            taskId: taskId,
            targetId: eventId,
            eventId: Value(eventId),
            relationType: (row['relationType'] as String?) ?? 'related',
            createdAt: (row['createdAt'] as int?) ?? now(),
          ),
        );
  }

  Future<void> _restorePermissionPolicy(Map<String, dynamic> payload) async {
    final id = payload['id'] as String;
    final before = payload['before'];
    await (database.delete(database.agentPermissionPolicies)
          ..where((row) => row.id.equals(id) & row.accountId.equals(accountId)))
        .go();
    if (before == null) return;
    final row = before as Map<String, dynamic>;
    await database
        .into(database.agentPermissionPolicies)
        .insert(
          AgentPermissionPoliciesCompanion.insert(
            id: id,
            accountId: accountId,
            actionType: (row['actionType'] as String?) ?? 'unknown',
            targetType: Value((row['targetType'] as String?) ?? '*'),
            confirmationMode: (row['confirmationMode'] as String?) ??
                'always',
            riskLevel: Value((row['riskLevel'] as String?) ?? 'medium'),
            scope: Value((row['scope'] as String?) ?? 'user_default'),
            enabled: Value((row['enabled'] as bool?) ?? true),
            firstConfirmedAt: Value(row['firstConfirmedAt'] as int?),
            lastConfirmedAt: Value(row['lastConfirmedAt'] as int?),
            expiresAt: Value(row['expiresAt'] as int?),
            updatedBy: Value(row['updatedBy'] as String?),
            createdAt: (row['createdAt'] as int?) ?? now(),
            updatedAt: (row['updatedAt'] as int?) ?? now(),
          ),
        );
  }

  Future<void> _restoreJwDayMove(Map<String, dynamic> payload) async {
    final before = payload['before'];
    final id = payload['id'] as String;
    if (before == null) {
      await (database.delete(database.jwDayMoves)..where(
            (row) => row.id.equals(id) & row.accountId.equals(accountId),
          ))
          .go();
      return;
    }
    // Restore the exact prior row, account-scoped.
    final row = before as Map<String, dynamic>;
    await database
        .into(database.jwDayMoves)
        .insertOnConflictUpdate(
          JwDayMovesCompanion.insert(
            id: id,
            accountId: accountId,
            sourceDate: row['sourceDate'] as String,
            targetDate: row['targetDate'] as String,
            createdAt: row['createdAt'] as int,
            updatedAt: row['updatedAt'] as int,
          ),
        );
  }

  /// Reverses a recurring lifecycle action (cancel/delete/reopen/restore across
  /// only_this / this_and_future / whole_series). The sub-path is selected from
  /// `payload['scope']` and `payload['action']`:
  ///
  /// - `this_and_future` cancel/delete: a split created a new segment. Delete
  ///   that segment row, restore the old segment's `effectiveThrough` /
  ///   `effectiveFrom` / `updatedAt` from `before['series']`, and migrate each
  ///   captured exception back to its original `seriesId` / `occurrenceKey`
  ///   (reversing `editThisAndFuture`'s re-keying and orphaning).
  /// - `this_and_future` reopen/restore (no split): restore the segment's
  ///   `status` / `deletedAt` from `before['series']`.
  /// - `only_this`: restore the captured exception row from `before['exception']`
  ///   (reverse status / deletedAt / overrides). When the action created an
  ///   exception row that did not exist before (`before['exception'] == null`),
  ///   delete that row.
  /// - `whole_series`: restore the series `status` / `deletedAt` from
  ///   `before['series']`.
  ///
  /// The slot is consumed only if the whole restore succeeds (see [undo]); a
  /// partial failure rolls back the transaction and preserves the slot.
  Future<void> _restoreRecurringLifecycle(Map<String, dynamic> payload) async {
    final scope = payload['scope'] as String?;
    final action = payload['action'] as String?;
    final before = payload['before'];
    if (before is! Map<String, dynamic>) throw const InvalidUndoCommand();
    switch (scope) {
      case 'this_and_future':
        final newSeriesId = payload['newSeriesId'] as String?;
        if (newSeriesId != null) {
          // cancel/delete split: migrate exceptions back to their original
          // series/key FIRST (the new segment's FK cascades on delete, so the
          // migrated rows must be moved before the new segment is removed),
          // then delete the new segment, then restore the old segment's
          // truncated effectiveThrough/updatedAt boundary.
          final migrated = payload['migratedExceptions'];
          if (migrated is List) {
            for (final raw in migrated) {
              if (raw is! Map<String, dynamic>) {
                throw const InvalidUndoCommand();
              }
              await _restoreMigratedException(raw);
            }
          }
          await (database.delete(database.calendarEventSeries)..where(
                (row) =>
                    row.id.equals(newSeriesId) &
                    row.accountId.equals(accountId),
              ))
              .go();
          await _restoreSeriesFromSnapshot(before['series']);
        } else {
          // reopen/restore acted on the segment directly (no split): restore
          // the segment status/deletedAt from the series snapshot.
          await _restoreSeriesFromSnapshot(before['series']);
        }
      case 'only_this':
        await _restoreOnlyThisException(
          payload['seriesId'] as String,
          payload['occurrenceKey'] as String,
          before['exception'],
        );
      case 'whole_series':
        await _restoreSeriesFromSnapshot(before['series']);
      default:
        throw const InvalidUndoCommand();
    }
    // `action` is intentionally not branched on here: the scope + presence of
    // newSeriesId fully determine the restore path, and the snapshots already
    // capture the pre-action state for each.
    if (action == null) throw const InvalidUndoCommand();
  }

  /// Restores the lifecycle-relevant columns of a `calendar_event_series`
  /// row from a JSON snapshot via a targeted UPDATE. Only the columns a
  /// recurring lifecycle action can mutate (`status`, `deletedAt`,
  /// `effectiveFrom`, `effectiveThrough`, `updatedAt`) are rewritten, so the
  /// segment's title/recurrence/anchor/etc. are preserved. A targeted update
  /// (rather than insertOnConflictUpdate) avoids re-validating the series'
  /// all-day/timed CHECK constraints with a partial row.
  Future<void> _restoreSeriesFromSnapshot(Object? seriesSnapshot) async {
    if (seriesSnapshot is! Map<String, dynamic>) {
      throw const InvalidUndoCommand();
    }
    final id = seriesSnapshot['id'] as String;
    await (database.update(database.calendarEventSeries)
          ..where(
            (row) => row.id.equals(id) & row.accountId.equals(accountId),
          ))
        .write(
          CalendarEventSeriesCompanion(
            status: Value(seriesSnapshot['status'] as String),
            effectiveFrom: Value(seriesSnapshot['effectiveFrom'] as String?),
            effectiveThrough: Value(
              seriesSnapshot['effectiveThrough'] as String?,
            ),
            deletedAt: Value(seriesSnapshot['deletedAt'] as int?),
            updatedAt: Value(seriesSnapshot['updatedAt'] as int),
          ),
        );
  }

  /// Moves a single exception row back to its original `seriesId` /
  /// `occurrenceKey` and clears any orphaning that `editThisAndFuture`
  /// applied, restoring the full prior row state from the snapshot. Uses an
  /// explicit UPDATE by primary key (rather than insertOnConflictUpdate) so
  /// the row is relocated across series without re-validating the
  /// `{accountId, seriesId, occurrenceKey}` unique key on an INSERT.
  Future<void> _restoreMigratedException(Map<String, dynamic> migrated) async {
    final before = migrated['before'];
    if (before is! Map<String, dynamic>) throw const InvalidUndoCommand();
    final id = before['id'] as String;
    final originalSeriesId = migrated['originalSeriesId'] as String;
    final originalOccurrenceKey = migrated['originalOccurrenceKey'] as String;
    await (database.update(database.calendarEventOccurrenceExceptions)
          ..where((row) => row.id.equals(id) & row.accountId.equals(accountId)))
        .write(
          CalendarEventOccurrenceExceptionsCompanion(
            seriesId: Value(originalSeriesId),
            occurrenceKey: Value(originalOccurrenceKey),
            originalStartAt: Value(before['originalStartAt'] as int?),
            originalStartDate: Value(before['originalStartDate'] as String?),
            overriddenFieldsJson: Value(
              before['overriddenFieldsJson'] as String? ?? '[]',
            ),
            overrideJson: Value(before['overrideJson'] as String),
            status: Value(before['status'] as String?),
            orphaned: Value(before['orphaned'] as bool? ?? false),
            deletedAt: Value(before['deletedAt'] as int?),
            updatedAt: Value(before['updatedAt'] as int),
          ),
        );
  }

  /// Restores a single occurrence exception for an `only_this` lifecycle
  /// action. When [exceptionSnapshot] is null, the action created an exception
  /// row that did not exist before (e.g. a cancel/delete tombstone), so the
  /// row is deleted. Otherwise the row is restored to its prior state.
  Future<void> _restoreOnlyThisException(
    String seriesId,
    String occurrenceKey,
    Object? exceptionSnapshot,
  ) async {
    if (exceptionSnapshot == null) {
      await (database.delete(database.calendarEventOccurrenceExceptions)
            ..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.seriesId.equals(seriesId) &
                  row.occurrenceKey.equals(occurrenceKey),
            ))
          .go();
      return;
    }
    if (exceptionSnapshot is! Map<String, dynamic>) {
      throw const InvalidUndoCommand();
    }
    final row = exceptionSnapshot;
    await database
        .into(database.calendarEventOccurrenceExceptions)
        .insertOnConflictUpdate(
          CalendarEventOccurrenceExceptionsCompanion.insert(
            id: row['id'] as String,
            accountId: accountId,
            seriesId: row['seriesId'] as String,
            occurrenceKey: row['occurrenceKey'] as String,
            originalStartAt: Value(row['originalStartAt'] as int?),
            originalStartDate: Value(row['originalStartDate'] as String?),
            kind: row['kind'] as String,
            overriddenFieldsJson: Value(
              row['overriddenFieldsJson'] as String? ?? '[]',
            ),
            overrideJson: row['overrideJson'] as String,
            status: Value(row['status'] as String?),
            orphaned: Value(row['orphaned'] as bool? ?? false),
            deletedAt: Value(row['deletedAt'] as int?),
            createdAt: row['createdAt'] as int,
            updatedAt: row['updatedAt'] as int,
          ),
        );
  }

  Future<void> _restoreReminderOverride(Map<String, dynamic> payload) async {
    final targetType = payload['targetType'] as String;
    final targetId = payload['targetId'] as String;
    await (database.delete(database.reminders)..where(
          (row) =>
              row.accountId.equals(accountId) &
              row.targetType.equals(targetType) &
              row.targetId.equals(targetId),
        ))
        .go();
    for (final value in payload['before'] as List<dynamic>) {
      final row = value as Map<String, dynamic>;
      await database
          .into(database.reminders)
          .insert(
            RemindersCompanion.insert(
              id: row['id'] as String,
              accountId: accountId,
              targetType: row['targetType'] as String,
              targetId: row['targetId'] as String,
              eventId: Value(row['eventId'] as String?),
              taskId: Value(row['taskId'] as String?),
              planBlockId: Value(row['planBlockId'] as String?),
              offsetMinutes: Value(row['offsetMinutes'] as int?),
              triggerAt: row['triggerAt'] as int,
              state: row['state'] as String,
              failureCode: Value(row['failureCode'] as String?),
              deliveredAt: Value(row['deliveredAt'] as int?),
              createdAt: row['createdAt'] as int,
              updatedAt: row['updatedAt'] as int,
            ),
          );
    }
  }

  Future<void> _restoreTask(Map<String, dynamic> payload) async {
    final before = payload['before'];
    final id = payload['id'] as String;
    if (before == null) {
      await (database.delete(database.tasks)..where(
            (row) => row.id.equals(id) & row.accountId.equals(accountId),
          ))
          .go();
      return;
    }
    final row = before as Map<String, dynamic>;
    await database
        .into(database.tasks)
        .insertOnConflictUpdate(
          TasksCompanion.insert(
            id: id,
            accountId: accountId,
            title: row['title'] as String,
            description: Value(row['description'] as String?),
            userNotes: Value(row['userNotes'] as String?),
            state: row['state'] as String,
            blockedReason: Value(row['blockedReason'] as String?),
            importance: row['importance'] as String,
            deadlineAt: Value(row['deadlineAt'] as int?),
            estimatedMinutes: Value(row['estimatedMinutes'] as int?),
            tagsJson: row['tagsJson'] as String,
            completedAt: Value(row['completedAt'] as int?),
            cancelledAt: Value(row['cancelledAt'] as int?),
            createdAt: row['createdAt'] as int,
            updatedAt: row['updatedAt'] as int,
            deletedAt: Value(row['deletedAt'] as int?),
          ),
        );
    if (payload['restorePlanBlocks'] == true) {
      await (database.update(database.planBlocks)..where(
            (block) =>
                block.accountId.equals(accountId) &
                block.taskId.equals(id) &
                block.status.equals('cancelled') &
                block.reviewedAt.equals(payload['transitionAt'] as int),
          ))
          .write(
            const PlanBlocksCompanion(
              status: Value('accepted'),
              reviewedAt: Value(null),
            ),
          );
    }
  }

  Future<void> _restorePlanBlock(Map<String, dynamic> payload) async {
    final before = payload['before'];
    final id = payload['id'] as String;
    if (before == null) {
      await (database.delete(database.planBlocks)..where(
            (row) => row.id.equals(id) & row.accountId.equals(accountId),
          ))
          .go();
      return;
    }
    final row = before as Map<String, dynamic>;
    await database
        .into(database.planBlocks)
        .insertOnConflictUpdate(
          PlanBlocksCompanion.insert(
            id: id,
            accountId: accountId,
            taskId: row['taskId'] as String,
            title: Value(row['title'] as String?),
            startAt: row['startAt'] as int,
            endAt: row['endAt'] as int,
            status: row['status'] as String,
            locked: Value(row['locked'] as bool),
            reviewNote: Value(row['reviewNote'] as String?),
            reviewedAt: Value(row['reviewedAt'] as int?),
            rescheduledToPlanBlockId: Value(
              row['rescheduledToPlanBlockId'] as String?,
            ),
            createdAt: row['createdAt'] as int,
            updatedAt: row['updatedAt'] as int,
            deletedAt: Value(row['deletedAt'] as int?),
          ),
        );
  }

  Future<void> _restoreCalendarEvent(Map<String, dynamic> payload) async {
    final before = payload['before'];
    final id = payload['id'] as String;
    if (before == null) {
      await (database.delete(database.calendarEvents)..where(
            (row) => row.id.equals(id) & row.accountId.equals(accountId),
          ))
          .go();
      return;
    }
    final row = before as Map<String, dynamic>;
    await database
        .into(database.calendarEvents)
        .insertOnConflictUpdate(
          CalendarEventsCompanion.insert(
            id: id,
            accountId: accountId,
            source: row['source'] as String,
            externalId: Value(row['externalId'] as String?),
            sourceSeriesExternalId: Value(
              row['sourceSeriesExternalId'] as String?,
            ),
            personalSeriesId: Value(row['personalSeriesId'] as String?),
            occurrenceKey: Value(row['occurrenceKey'] as String?),
            title: row['title'] as String,
            description: Value(row['description'] as String?),
            type: row['type'] as String,
            status: Value(row['status'] as String),
            startAt: Value(row['startAt'] as int?),
            endAt: Value(row['endAt'] as int?),
            allDay: row['allDay'] as bool,
            startDate: Value(row['startDate'] as String?),
            endDateExclusive: Value(row['endDateExclusive'] as String?),
            timezone: row['timezone'] as String,
            locationName: Value(row['locationName'] as String?),
            buildingName: Value(row['buildingName'] as String?),
            campusName: Value(row['campusName'] as String?),
            participantsJson: Value(
              (row['participantsJson'] as String?) ?? '[]',
            ),
            sourceDetailsJson: Value(
              (row['sourceDetailsJson'] as String?) ?? '{}',
            ),
            importance: Value((row['importance'] as String?) ?? 'normal'),
            completionPolicy: Value(
              (row['completionPolicy'] as String?) ?? 'auto_complete',
            ),
            completedAt: Value(row['completedAt'] as int?),
            color: Value(row['color'] as String?),
            tagsJson: Value((row['tagsJson'] as String?) ?? '[]'),
            createdAt: row['createdAt'] as int,
            updatedAt: row['updatedAt'] as int,
            deletedAt: Value(row['deletedAt'] as int?),
          ),
        );
  }

  Future<void> _restoreOverlay(Map<String, dynamic> payload) async {
    final before = payload['before'];
    final id = payload['id'] as String;
    if (before == null) {
      await (database.delete(database.userOverlays)..where(
            (row) => row.id.equals(id) & row.accountId.equals(accountId),
          ))
          .go();
      return;
    }
    final row = before as Map<String, dynamic>;
    await database
        .into(database.userOverlays)
        .insertOnConflictUpdate(
          UserOverlaysCompanion.insert(
            id: id,
            accountId: accountId,
            eventId: Value(row['eventId'] as String?),
            courseSeriesId: Value(row['courseSeriesId'] as String?),
            displayTitle: Value(row['displayTitle'] as String?),
            displayLocation: Value(row['displayLocation'] as String?),
            attendancePolicy: Value(row['attendancePolicy'] as String?),
            attendanceDecision: Value(row['attendanceDecision'] as String?),
            attendanceDecisionAt: Value(row['attendanceDecisionAt'] as int?),
            attendanceNote: Value(row['attendanceNote'] as String?),
            attendanceOutcome: Value(row['attendanceOutcome'] as String?),
            listeningMode: Value(row['listeningMode'] as String?),
            listeningNote: Value(row['listeningNote'] as String?),
            importance: Value(row['importance'] as String?),
            color: Value(row['color'] as String?),
            foregroundPriority: Value(row['foregroundPriority'] as int?),
            hidden: Value(row['hidden'] as bool?),
            userNotes: Value(row['userNotes'] as String?),
            tagsJson: Value(row['tagsJson'] as String?),
            createdAt: row['createdAt'] as int,
            updatedAt: row['updatedAt'] as int,
          ),
        );
  }

  Future<void> _restoreScheduleRelation(Map<String, dynamic> payload) async {
    final id = payload['id'] as String;
    final before = payload['before'];
    await (database.delete(database.scheduleRelations)
          ..where((row) => row.id.equals(id) & row.accountId.equals(accountId)))
        .go();
    if (before == null) return;
    final row = before as Map<String, dynamic>;
    await database
        .into(database.scheduleRelations)
        .insert(
          ScheduleRelationsCompanion.insert(
            id: id,
            accountId: accountId,
            leftKind: Value(row['leftKind'] as String?),
            leftId: Value(row['leftId'] as String?),
            rightKind: Value(row['rightKind'] as String?),
            rightId: Value(row['rightId'] as String?),
            leftEventId: Value(row['leftEventId'] as String?),
            leftPlanBlockId: Value(row['leftPlanBlockId'] as String?),
            rightEventId: Value(row['rightEventId'] as String?),
            rightPlanBlockId: Value(row['rightPlanBlockId'] as String?),
            conflictState: Value(row['conflictState'] as String?),
            reason: Value(row['reason'] as String?),
            createdAt: row['createdAt'] as int,
            updatedAt: row['updatedAt'] as int,
          ),
        );
  }

  Future<void> _restoreScheduleRelationRule(
    Map<String, dynamic> payload,
  ) async {
    final id = payload['id'] as String;
    final before = payload['before'];
    await (database.delete(database.scheduleRelationRules)
          ..where((row) => row.id.equals(id) & row.accountId.equals(accountId)))
        .go();
    if (before == null) return;
    final row = before as Map<String, dynamic>;
    await database
        .into(database.scheduleRelationRules)
        .insert(
          ScheduleRelationRulesCompanion.insert(
            id: id,
            accountId: accountId,
            leftSeriesType: row['leftSeriesType'] as String,
            leftSeriesId: row['leftSeriesId'] as String,
            rightSeriesType: row['rightSeriesType'] as String,
            rightSeriesId: row['rightSeriesId'] as String,
            conflictState: row['conflictState'] as String,
            reason: Value(row['reason'] as String?),
            effectiveFrom: row['effectiveFrom'] as String,
            effectiveThrough: Value(row['effectiveThrough'] as String?),
            createdAt: row['createdAt'] as int,
            updatedAt: row['updatedAt'] as int,
          ),
        );
  }

  /// Decodes and structurally validates the stored slot payload. Returns null
  /// for a malformed / non-v1 envelope (so it can be treated as a bad slot).
  /// The caller is responsible for the account-ownership check.
  Map<String, dynamic>? _decodeValidated(String payload) {
    final decoded = jsonDecode(payload);
    if (decoded is! Map<String, dynamic> ||
        decoded['version'] != 1 ||
        decoded['accountId'] is! String ||
        decoded['kind'] is! String ||
        decoded['payload'] is! Map<String, dynamic>) {
      return null;
    }
    return decoded;
  }

  /// A safe, Chinese, kind-derived preview label for v1 slots that predate the
  /// optional safe summary. Never reads the payload, so no ids/refs/account
  /// identity can leak.
  static String _summaryForKind(String? kind) => switch (kind) {
        'task_create' => '创建任务',
        'task_rename' => '重命名任务',
        'task_block' => '阻塞任务',
        'task_unblock' => '解除任务阻塞',
        'task_complete' => '完成任务',
        'task_cancel' => '取消任务',
        'task_reopen' => '重新打开任务',
        'task_delete' => '删除任务',
        'task_restore' => '恢复任务',
        'plan_block_create' => '创建计划块',
        'plan_block_move' => '移动计划块',
        'plan_block_lock' => '锁定计划块',
        'plan_block_split' => '拆分计划块',
        'plan_block_reschedule' => '重新排程计划块',
        'plan_block_delete' => '删除计划块',
        'calendar_event_create' => '创建日程事件',
        'calendar_event_edit' => '编辑日程事件',
        'calendar_event_delete' => '删除日程事件',
        'calendar_event_restore' => '恢复日程事件',
        'user_overlay_update' => '修改事件覆盖',
        'reminder_override' => '修改提醒设置',
        'conflict_classification' => '修改冲突关系',
        'jw_day_move' => '移动调休日期',
        'composite' => '组合恢复',
        _ => '本地更改',
      };

  /// Formats an epoch-ms timestamp as a Beijing wall-clock string (the same
  /// +8h wall-clock convention the app uses for display).
  static String _formatBeijing(int epochMs) {
    final utc = DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true);
    final shifted = utc.add(const Duration(hours: 8));
    String two(int v) => v.toString().padLeft(2, '0');
    return '${shifted.year}-${two(shifted.month)}-${two(shifted.day)} '
        '${two(shifted.hour)}:${two(shifted.minute)}:${two(shifted.second)}';
  }
}

/// An account-safe preview of the most recent undoable action, produced by
/// [UndoService.preview]. Carries ONLY safe, model-safe content: availability,
/// the Chinese safe summary, the action kind, and a Beijing wall-clock string.
/// It never carries the payload, a DB id, a ref, or an account identity, and it
/// NEVER consumes (mutates) the undo slot.
class UndoPreview {
  const UndoPreview({
    required this.available,
    this.kind = '',
    this.summary = '',
    this.beijingAt = '',
  });

  const UndoPreview.disabled()
      : available = false,
        kind = '',
        summary = '',
        beijingAt = '';

  final bool available;
  final String kind;
  final String summary;
  final String beijingAt;

  /// The safe DTO exposed to the Agent tool (and thus the model).
  Map<String, Object?> toDto() => {
        'available': available,
        'actionType': kind,
        'summary': summary,
        'beijingAt': beijingAt,
      };
}
