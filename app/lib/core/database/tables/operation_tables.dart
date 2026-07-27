import 'package:drift/drift.dart';

import 'account_tables.dart';

class ActionLogs extends Table {
  TextColumn get id => text()();
  TextColumn get accountId => text().nullable().references(
    LocalAccounts,
    #id,
    onDelete: KeyAction.setNull,
  )();
  TextColumn get source => text()();
  TextColumn get actionType => text()();
  TextColumn get result => text()();
  TextColumn get safeSummary => text()();
  IntColumn get occurredAt => integer()();

  @override
  String get tableName => 'action_logs';

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class AgentPermissionPolicies extends Table {
  TextColumn get id => text()();
  TextColumn get accountId =>
      text().references(LocalAccounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get actionType => text()();
  TextColumn get policy => text()();
  IntColumn get updatedAt => integer()();

  @override
  String get tableName => 'agent_permission_policies';

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {accountId, actionType},
  ];
}
