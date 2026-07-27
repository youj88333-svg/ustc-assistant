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
        'payload': command.payload,
      }),
    );
  }

  Future<bool> canUndo() async =>
      (await database.select(database.undoSlot).getSingleOrNull()) != null;

  Future<void> clearAtStartup() => database.delete(database.undoSlot).go();

  Future<void> undo() async {
    final slot = await database.select(database.undoSlot).getSingleOrNull();
    if (slot == null) throw const InvalidUndoCommand();
    try {
      final decoded = jsonDecode(slot.payload);
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != 1 ||
          decoded['accountId'] != accountId ||
          decoded['kind'] is! String ||
          decoded['payload'] is! Map<String, dynamic>) {
        throw const InvalidUndoCommand();
      }
      final kind = decoded['kind'] as String;
      final payload = decoded['payload'] as Map<String, dynamic>;
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
      await database.delete(database.undoSlot).go();
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
      default:
        throw const InvalidUndoCommand();
    }
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
            rightEventId: Value(row['rightEventId'] as String?),
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
}
