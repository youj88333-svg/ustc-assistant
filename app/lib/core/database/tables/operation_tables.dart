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
  TextColumn get riskLevel => text().nullable()();   // 新增
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
  TextColumn get targetType => text().withDefault(const Constant('*'))();
  TextColumn get confirmationMode => text()();
  TextColumn get riskLevel => text().withDefault(const Constant('medium'))();
  TextColumn get scope => text().withDefault(const Constant('user_default'))();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  IntColumn get firstConfirmedAt => integer().nullable()();
  IntColumn get lastConfirmedAt => integer().nullable()();
  IntColumn get expiresAt => integer().nullable()();
  TextColumn get updatedBy => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  String get tableName => 'agent_permission_policies';

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {accountId, actionType, targetType},
  ];
}
