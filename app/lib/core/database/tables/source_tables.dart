import 'package:drift/drift.dart';

import 'account_tables.dart';

class SourceConfigs extends Table {
  TextColumn get id => text()();
  TextColumn get accountId =>
      text().references(LocalAccounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get source => text()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  TextColumn get configJson => text().withDefault(const Constant('{}'))();
  IntColumn get lastSuccessAt => integer().nullable()();
  IntColumn get retryAfter => integer().nullable()();
  IntColumn get updatedAt => integer()();

  @override
  String get tableName => 'source_configs';

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {accountId, source},
  ];
}

@DataClassName('ImportBatch')
class ImportBatches extends Table {
  TextColumn get id => text()();
  TextColumn get accountId =>
      text().references(LocalAccounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get bundleId => text()();
  TextColumn get digest => text()();
  TextColumn get source => text()();
  TextColumn get scopeKey => text()();
  IntColumn get importedAt => integer()();
  TextColumn get origin => text()();

  @override
  String get tableName => 'import_batches';

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {accountId, bundleId},
    {accountId, digest},
  ];
}

class SourceRecords extends Table {
  TextColumn get id => text()();
  TextColumn get accountId =>
      text().references(LocalAccounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get source => text()();
  TextColumn get entityType => text()();
  TextColumn get externalId => text()();
  TextColumn get localEntityId => text()();
  TextColumn get sourceStatus => text()();
  TextColumn get presence => text()();
  TextColumn get scopeKey => text()();
  TextColumn get importBatchId =>
      text().nullable().references(ImportBatches, #id, onDelete: KeyAction.restrict)();
  IntColumn get sourceUpdatedAt => integer().nullable()();
  IntColumn get firstObservedAt => integer()();
  IntColumn get lastObservedAt => integer()();

  @override
  String get tableName => 'source_records';

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {accountId, source, entityType, externalId},
  ];
}

class SyncRuns extends Table {
  TextColumn get id => text()();
  TextColumn get accountId =>
      text().references(LocalAccounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get source => text()();
  TextColumn get trigger => text()();
  TextColumn get state => text()();
  TextColumn get resultCode => text().nullable()();
  IntColumn get startedAt => integer()();
  IntColumn get finishedAt => integer().nullable()();
  TextColumn get importBatchId =>
      text().nullable().references(ImportBatches, #id, onDelete: KeyAction.setNull)();

  @override
  String get tableName => 'sync_runs';

  @override
  Set<Column<Object>> get primaryKey => {id};
}
