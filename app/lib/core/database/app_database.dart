import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'tables/account_tables.dart';
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
    UndoSlot,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  @override
  int get schemaVersion => 1;

  late final ActionLogRepository actionLogsRepository = ActionLogRepository(
    this,
  );

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
    required int occurredAt,
  }) async {
    await _database.into(_database.actionLogs).insert(
      ActionLogsCompanion.insert(
        id: _uuid.v4(),
        accountId: Value(accountId),
        source: source,
        actionType: actionType,
        result: result,
        safeSummary: safeSummary,
        occurredAt: occurredAt,
      ),
    );
  }

  Future<List<ActionLog>> selectAll() =>
      (_database.select(_database.actionLogs)
            ..orderBy([(row) => OrderingTerm.desc(row.occurredAt)]))
          .get();
}
