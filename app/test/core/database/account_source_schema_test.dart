import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';

AppDatabase testDatabase() => AppDatabase(NativeDatabase.memory());

LocalAccountsCompanion account(String id) => LocalAccountsCompanion.insert(
  id: id,
  maskedHint: 'PB****0000',
  createdAt: 1,
  updatedAt: 1,
);

SourceRecordsCompanion record({
  required String accountId,
  required String externalId,
}) => SourceRecordsCompanion.insert(
  id: '$accountId-$externalId',
  accountId: accountId,
  source: 'ustc_jw',
  entityType: 'calendar_event',
  externalId: externalId,
  localEntityId: 'local-$externalId',
  sourceStatus: 'active',
  presence: 'observed',
  scopeKey: '2026fall',
  firstObservedAt: 1,
  lastObservedAt: 1,
);

void main() {
  test('source identity is unique inside one account', () async {
    final db = testDatabase();
    addTearDown(db.close);
    await db.into(db.localAccounts).insert(account('a'));
    await db
        .into(db.sourceRecords)
        .insert(record(accountId: 'a', externalId: 'x'));

    expect(
      db
          .into(db.sourceRecords)
          .insert(record(accountId: 'a', externalId: 'x')),
      throwsA(isA<SqliteException>()),
    );
  });

  test('same source identity is allowed in different accounts', () async {
    final db = testDatabase();
    addTearDown(db.close);
    await db.into(db.localAccounts).insert(account('a'));
    await db.into(db.localAccounts).insert(account('b'));

    await db
        .into(db.sourceRecords)
        .insert(record(accountId: 'a', externalId: 'x'));
    await db
        .into(db.sourceRecords)
        .insert(record(accountId: 'b', externalId: 'x'));

    expect(await db.select(db.sourceRecords).get(), hasLength(2));
  });

  test('agent permission table starts empty', () async {
    final db = testDatabase();
    addTearDown(db.close);
    expect(await db.select(db.agentPermissionPolicies).get(), isEmpty);
  });

  test('protected password is nullable', () async {
    final db = testDatabase();
    addTearDown(db.close);
    await db.into(db.localAccounts).insert(account('a'));
    await db.into(db.credentialAccounts).insert(
      CredentialAccountsCompanion.insert(
        accountId: 'a',
        usernameCiphertext: Uint8List.fromList([1, 2, 3]),
        scheme: 'dpapi-current-user-v1',
        updatedAt: 1,
      ),
    );

    expect(
      (await db.select(db.credentialAccounts).getSingle()).passwordCiphertext,
      isNull,
    );
  });

  test('account deletion cascades source and credential rows', () async {
    final db = testDatabase();
    addTearDown(db.close);
    await db.into(db.localAccounts).insert(account('a'));
    await db.into(db.credentialAccounts).insert(
      CredentialAccountsCompanion.insert(
        accountId: 'a',
        usernameCiphertext: Uint8List.fromList([1]),
        scheme: 'dpapi-current-user-v1',
        updatedAt: 1,
      ),
    );
    await db
        .into(db.sourceRecords)
        .insert(record(accountId: 'a', externalId: 'x'));

    await (db.delete(
      db.localAccounts,
    )..where((row) => row.id.equals('a'))).go();

    expect(await db.select(db.credentialAccounts).get(), isEmpty);
    expect(await db.select(db.sourceRecords).get(), isEmpty);
  });

  test('bundle id and digest identities are unique per account', () async {
    final db = testDatabase();
    addTearDown(db.close);
    await db.into(db.localAccounts).insert(account('a'));
    final first = ImportBatchesCompanion.insert(
      id: 'batch-1',
      accountId: 'a',
      bundleId: 'bundle-1',
      digest: 'digest-1',
      source: 'ustc_jw',
      scopeKey: '2026fall',
      importedAt: 1,
      origin: 'file',
    );
    await db.into(db.importBatches).insert(first);

    expect(
      db.into(db.importBatches).insert(first.copyWith(id: const Value('x'))),
      throwsA(isA<SqliteException>()),
    );
    expect(
      db.into(db.importBatches).insert(
        first.copyWith(
          id: const Value('y'),
          bundleId: const Value('bundle-2'),
        ),
      ),
      throwsA(isA<SqliteException>()),
    );
  });

  test('action log repository exposes append and select only', () async {
    final db = testDatabase();
    addTearDown(db.close);
    await db.actionLogsRepository.append(
      accountId: null,
      source: 'system',
      actionType: 'startup',
      result: 'success',
      safeSummary: 'Application started',
      occurredAt: 1,
    );

    final rows = await db.actionLogsRepository.selectAll();
    expect(rows.single.safeSummary, 'Application started');
  });
}
