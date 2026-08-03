import 'dart:async';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'tables/account_tables.dart';
import 'tables/agent_tables.dart';
import 'tables/operation_tables.dart';
import 'tables/schedule_tables.dart';
import 'tables/source_tables.dart';
import 'tables/task_tables.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [
    LocalAccounts,
    CredentialAccounts,
    SourceConfigs,
    ImportBatches,
    SourceRecords,
    SyncRuns,
    ActionLogs,
    AgentPermissionPolicies,
    AgentSettings,
    AgentSecrets,
    AgentRuns,
    ChatMessages,
    ToolInvocations,
    ConversationSummaries,
    CourseSeries,
    CalendarEventSeries,
    CalendarEvents,
    CalendarEventOccurrenceExceptions,
    UserOverlays,
    Tasks,
    PlanBlocks,
    TaskEventLinks,
    ScheduleRelations,
    ScheduleRelationRules,
    Reminders,
    JwDayMoves,
    UndoSlot,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  final StreamController<void> _activeAccountChanges =
      StreamController<void>.broadcast(sync: true);
  final StreamController<String> _agentSettingsChanges =
      StreamController<String>.broadcast(sync: true);

  Stream<void> get activeAccountChanges => _activeAccountChanges.stream;

  void notifyActiveAccountChanged() {
    if (!_activeAccountChanges.isClosed) _activeAccountChanges.add(null);
  }

  Stream<String> get agentSettingsChanges => _agentSettingsChanges.stream;

  void notifyAgentSettingsChanged(String accountId) {
    if (!_agentSettingsChanges.isClosed) {
      _agentSettingsChanges.add(accountId);
    }
  }

  @override
  int get schemaVersion => 7;

  late final ActionLogRepository actionLogsRepository = ActionLogRepository(
    this,
  );

  @override
  Future<void> close() async {
    await _activeAccountChanges.close();
    await _agentSettingsChanges.close();
    await super.close();
  }

  Future<void> replaceUndoSlot({
    required String commandId,
    required String payload,
    int? expiresAt,
  }) => into(undoSlot).insertOnConflictUpdate(
    UndoSlotCompanion.insert(
      slot: const Value(1),
      commandId: commandId,
      payload: payload,
      expiresAt: Value(expiresAt),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ),
  );

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) async {
      await migrator.createAll();
    },
    onUpgrade: (migrator, from, to) async {
      if (from < 2) {
        await migrator.addColumn(localAccounts, localAccounts.identityDigest);
      }
      if (from < 3) {
        await migrator.createTable(agentSettings);
        await migrator.createTable(agentSecrets);
        await migrator.createTable(agentRuns);
        await migrator.createTable(chatMessages);
        await migrator.createTable(toolInvocations);
        await migrator.createTable(conversationSummaries);
      }
      if (from < 4) {
        await migrator.addColumn(actionLogs, actionLogs.riskLevel);
        // v3 占位表从未被使用（无行、无读取）；直接重建为完整 schema。
        await migrator.drop(agentPermissionPolicies);
        await migrator.createTable(agentPermissionPolicies);
      }
      if (from < 5) {
        await migrator.createTable(jwDayMoves);
      }
      // Schema six adds tool_invocations.error_code. The `from >= 3` guard is
      // required: when upgrading from a pre-v3 schema, the `from < 3` branch
      // above creates tool_invocations with the CURRENT (v6) definition, which
      // already includes error_code -- so addColumn would duplicate it. Only
      // databases where tool_invocations existed since v3 as the v5 definition
      // (from = 3, 4, 5) need the new column added.
      if (from >= 3 && from < 6) {
        await migrator.addColumn(toolInvocations, toolInvocations.errorCode);
      }
      // Schema seven adds recurring-occurrence targets to the dependent
      // tables: a series default reminder offset, a nullable
      // occurrence-exception FK on reminders / Task links, and nullable
      // left/right occurrence-exception FKs on schedule relations. The
      // task_event_links primary key changes from (account_id, task_id,
      // event_id) to (account_id, task_id, target_id), so that table must be
      // rebuilt; schedule_relations and reminders are rebuilt to install their
      // updated CHECK constraints. Existing rows are preserved losslessly:
      // task_event_links.target_id takes the old event_id, series default
      // offsets are [15] for timed and [] for all-day, and every new
      // occurrence-exception column is left NULL.
      if (from >= 6 && from < 7) {
        await migrator.addColumn(
          calendarEventSeries,
          calendarEventSeries.reminderOffsetsJson,
        );
        await customStatement(
          "UPDATE calendar_event_series SET reminder_offsets_json = "
          "CASE all_day WHEN 1 THEN '[]' ELSE '[15]' END",
        );
        await migrator.alterTable(
          TableMigration(
            taskEventLinks,
            newColumns: [taskEventLinks.occurrenceExceptionId],
            columnTransformer: {
              taskEventLinks.targetId: taskEventLinks.eventId,
            },
          ),
        );
        await migrator.alterTable(
          TableMigration(
            scheduleRelations,
            newColumns: [
              scheduleRelations.leftOccurrenceExceptionId,
              scheduleRelations.rightOccurrenceExceptionId,
            ],
          ),
        );
        await migrator.alterTable(
          TableMigration(
            reminders,
            newColumns: [reminders.occurrenceExceptionId],
          ),
        );
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}

class ActionLogRepository {
  ActionLogRepository(this._database);

  final AppDatabase _database;
  static const _uuid = Uuid();

  Future<void> append({
    required String? accountId,
    required String source,
    required String actionType,
    required String result,
    required String safeSummary,
    String? riskLevel,
    required int occurredAt,
  }) async {
    await _database
        .into(_database.actionLogs)
        .insert(
          ActionLogsCompanion.insert(
            id: _uuid.v4(),
            accountId: Value(accountId),
            source: source,
            actionType: actionType,
            result: result,
            safeSummary: safeSummary,
            riskLevel: Value(riskLevel),
            occurredAt: occurredAt,
          ),
        );
  }

  Future<List<ActionLog>> selectAll() => (_database.select(
    _database.actionLogs,
  )..orderBy([(row) => OrderingTerm.desc(row.occurredAt)])).get();
}
