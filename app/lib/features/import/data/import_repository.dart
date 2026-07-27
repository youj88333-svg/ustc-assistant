import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';

class ImportRepository {
  const ImportRepository(this.database);

  final AppDatabase database;

  Future<ImportBatch?> batchByBundleId(String accountId, String bundleId) {
    return (database.select(database.importBatches)..where(
          (row) =>
              row.accountId.equals(accountId) & row.bundleId.equals(bundleId),
        ))
        .getSingleOrNull();
  }

  Future<SourceRecord?> sourceRecordByExternalId({
    required String accountId,
    required String source,
    required String externalId,
  }) {
    return (database.select(database.sourceRecords)..where(
          (row) =>
              row.accountId.equals(accountId) &
              row.source.equals(source) &
              row.externalId.equals(externalId),
        ))
        .getSingleOrNull();
  }

  Future<List<SourceRecord>> sourceRecordsFor({
    required String accountId,
    required String source,
  }) {
    return (database.select(database.sourceRecords)..where(
          (row) => row.accountId.equals(accountId) & row.source.equals(source),
        ))
        .get();
  }
}
