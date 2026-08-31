import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/security/credential_protector.dart';
import 'package:ustc_assistant_app/features/accounts/application/account_service.dart';
import 'package:ustc_assistant_app/features/accounts/application/first_login_commit_service.dart';
import 'package:ustc_assistant_app/features/import/application/import_service.dart';
import 'package:ustc_assistant_app/features/import/application/reminder_reconciler.dart';
import 'package:ustc_assistant_app/features/import/data/source_bundle_decoder.dart';
import 'package:ustc_assistant_app/features/import/domain/import_result.dart';

Uint8List sourceFixture(String name) =>
    File('test/fixtures/source_bundle/positive/$name').readAsBytesSync();

SourceBundleDecoder decoder() => SourceBundleDecoder(
  jsonDecode(
        File(
          'assets/schemas/source-bundle-1.0.draft7.schema.json',
        ).readAsStringSync(),
      )
      as Map<String, dynamic>,
);

final class TestProtector implements CredentialProtector {
  @override
  Future<ProtectedSecret> protect(Uint8List plaintext) async => ProtectedSecret(
    bytes: Uint8List.fromList([
      0xA5,
      for (final value in plaintext) value ^ 0x5A,
    ]),
    scheme: 'fake-test',
    version: 1,
  );

  @override
  Future<Uint8List> unprotect(ProtectedSecret protected) async =>
      Uint8List.fromList(
        protected.bytes.skip(1).map((value) => value ^ 0x5A).toList(),
      );
}

Future<AppDatabase> database() async => AppDatabase(NativeDatabase.memory());

Future<PreparedSourceBundle> prepared(ImportService imports) =>
    imports.prepare(sourceFixture('jw-with-exam.json'));

Uint8List sourceFixtureFor(String accountId) {
  final bundle =
      jsonDecode(utf8.decode(sourceFixture('jw-with-exam.json')))
          as Map<String, dynamic>;
  (bundle['subject'] as Map<String, dynamic>)['accountId'] = accountId;
  return Uint8List.fromList(utf8.encode(jsonEncode(bundle)));
}

Future<PreparedSourceBundle> preparedFor(
  ImportService imports,
  String accountId,
) => imports.prepare(sourceFixtureFor(accountId));

Future<void> seedExistingAccount(
  AppDatabase db, {
  required String accountId,
  required bool active,
}) async {
  await db
      .into(db.localAccounts)
      .insert(
        LocalAccountsCompanion.insert(
          id: accountId,
          maskedHint: 'old****0000',
          identityDigest: const Value('old-identity-digest'),
          isActive: Value(active),
          createdAt: 1,
          updatedAt: 1,
        ),
      );
  await db
      .into(db.credentialAccounts)
      .insert(
        CredentialAccountsCompanion.insert(
          accountId: accountId,
          usernameCiphertext: Uint8List.fromList([1, 2, 3]),
          scheme: 'old-test',
          updatedAt: 1,
        ),
      );
}

Future<void> expectExistingAccountRejected({
  required bool existingActive,
  required String existingId,
  required String targetId,
}) async {
  final db = await database();
  addTearDown(db.close);
  final imports = ImportService(database: db, decoder: decoder());
  await seedExistingAccount(db, accountId: existingId, active: existingActive);
  await imports.importBytes(
    sourceFixtureFor(existingId),
    accountId: existingId,
    origin: ImportOrigin.file,
  );
  final beforeAccounts = await db.select(db.localAccounts).get();
  final beforeCredentials = await db.select(db.credentialAccounts).get();
  final beforeEvents = await db.select(db.calendarEvents).get();
  final beforeBatches = await db.select(db.importBatches).get();
  final beforeRuns = await db.select(db.syncRuns).get();
  final beforeLogs = await db.select(db.actionLogs).get();
  final provisional = ProvisionalFirstLogin(
    accountId: targetId,
    expectedUsername: 'PB00000000',
  );
  final commit = FirstLoginCommitService(
    database: db,
    protector: TestProtector(),
    persistPrepared: imports.persistPrepared,
  );

  expect(
    commit.commit(
      provisional: provisional,
      verifiedUsername: 'PB00000000',
      prepared: await preparedFor(imports, targetId),
    ),
    throwsA(
      isA<AccountVerificationError>().having(
        (error) => error.code,
        'code',
        'account_exists',
      ),
    ),
  );
  expect(await db.select(db.localAccounts).get(), beforeAccounts);
  expect(await db.select(db.credentialAccounts).get(), beforeCredentials);
  expect(await db.select(db.calendarEvents).get(), beforeEvents);
  expect(await db.select(db.importBatches).get(), beforeBatches);
  expect(await db.select(db.syncRuns).get(), beforeRuns);
  expect(await db.select(db.actionLogs).get(), beforeLogs);
}

Future<void> assertNoLocalRows(AppDatabase db) async {
  expect(await db.select(db.localAccounts).get(), isEmpty);
  expect(await db.select(db.credentialAccounts).get(), isEmpty);
  expect(await db.select(db.calendarEvents).get(), isEmpty);
  expect(await db.select(db.importBatches).get(), isEmpty);
  expect(await db.select(db.syncRuns).get(), isEmpty);
}

final class RecordingReconciler implements ReminderReconciler {
  RecordingReconciler(this.database, {this.fail = false});

  final AppDatabase database;
  final bool fail;
  var sawCommittedRows = false;

  @override
  Future<void> reconcile({
    required String accountId,
    required String source,
  }) async {
    sawCommittedRows =
        (await database.select(database.localAccounts).get()).isNotEmpty;
    if (fail) throw StateError('reminder_unavailable');
  }
}

void main() {
  test('prepare rejects invalid bytes without writing local rows', () async {
    final db = await database();
    addTearDown(db.close);
    final imports = ImportService(database: db, decoder: decoder());

    expect(
      imports.prepare(Uint8List.fromList(utf8.encode('{}'))),
      throwsA(isA<Exception>()),
    );
    await assertNoLocalRows(db);
  });

  test('first login rejects when an active account already exists', () async {
    await expectExistingAccountRejected(
      existingActive: true,
      existingId: 'existing-active',
      targetId: 'new-account',
    );
  });

  test('first login rejects when an inactive account already exists', () async {
    await expectExistingAccountRejected(
      existingActive: false,
      existingId: 'existing-inactive',
      targetId: 'new-account',
    );
  });

  test(
    'first login rejects an existing account id without changing it',
    () async {
      await expectExistingAccountRejected(
        existingActive: true,
        existingId: 'acct_fixture',
        targetId: 'acct_fixture',
      );
    },
  );

  test('overlapping first-login commits admit only one account', () async {
    final db = await database();
    addTearDown(db.close);
    final imports = ImportService(database: db, decoder: decoder());
    final commit = FirstLoginCommitService(
      database: db,
      protector: TestProtector(),
      persistPrepared: imports.persistPrepared,
    );
    final first = ProvisionalFirstLogin(
      accountId: 'overlap-one',
      expectedUsername: 'PB00000000',
    );
    final second = ProvisionalFirstLogin(
      accountId: 'overlap-two',
      expectedUsername: 'PB00000000',
    );
    final firstPrepared = await preparedFor(imports, first.accountId);
    final secondPrepared = await preparedFor(imports, second.accountId);

    Future<Object> capture(Future<FirstLoginCommitResult> operation) async {
      try {
        return await operation;
      } catch (error) {
        return error;
      }
    }

    final outcomes = await Future.wait<Object>([
      capture(
        commit.commit(
          provisional: first,
          verifiedUsername: 'PB00000000',
          prepared: firstPrepared,
        ),
      ),
      capture(
        commit.commit(
          provisional: second,
          verifiedUsername: 'PB00000000',
          prepared: secondPrepared,
        ),
      ),
    ]);

    expect(outcomes.whereType<FirstLoginCommitResult>(), hasLength(1));
    expect(outcomes.whereType<AccountVerificationError>(), hasLength(1));
    expect(await db.select(db.localAccounts).get(), hasLength(1));
  });

  test('identity mismatch discards the provisional password bytes', () async {
    final db = await database();
    addTearDown(db.close);
    final imports = ImportService(database: db, decoder: decoder());
    final password = Uint8List.fromList(utf8.encode('secret'));
    final provisional = ProvisionalFirstLogin(
      accountId: 'acct_fixture',
      expectedUsername: 'PB00000000',
      passwordBytes: password,
      savePassword: true,
    );
    final commit = FirstLoginCommitService(
      database: db,
      protector: TestProtector(),
      persistPrepared: imports.persistPrepared,
    );

    expect(
      commit.commit(
        provisional: provisional,
        verifiedUsername: 'PB11111111',
        prepared: await prepared(imports),
      ),
      throwsA(isA<AccountVerificationError>()),
    );
    expect(password, orderedEquals(List<int>.filled(password.length, 0)));
    await assertNoLocalRows(db);
  });

  test(
    'persistence failure rolls back account and prepared import rows',
    () async {
      final db = await database();
      addTearDown(db.close);
      final imports = ImportService(database: db, decoder: decoder());
      final provisional = ProvisionalFirstLogin(
        accountId: 'acct_fixture',
        expectedUsername: 'PB00000000',
        passwordBytes: Uint8List.fromList(utf8.encode('secret')),
        savePassword: true,
      );
      final commit = FirstLoginCommitService(
        database: db,
        protector: TestProtector(),
        persistPrepared:
            (prepared, {required accountId, required origin}) async {
              expect(await db.select(db.localAccounts).get(), hasLength(1));
              expect(
                await db.select(db.credentialAccounts).get(),
                hasLength(1),
              );
              await imports.persistPrepared(
                prepared,
                accountId: accountId,
                origin: origin,
              );
              throw StateError('persist_failed');
            },
      );

      expect(
        commit.commit(
          provisional: provisional,
          verifiedUsername: 'PB00000000',
          prepared: await prepared(imports),
        ),
        throwsA(isA<StateError>()),
      );
      await assertNoLocalRows(db);
    },
  );

  test(
    'required config failure rolls back the complete first-login commit',
    () async {
      final db = await database();
      addTearDown(db.close);
      final imports = ImportService(database: db, decoder: decoder());
      final commit = FirstLoginCommitService(
        database: db,
        protector: TestProtector(),
        persistPrepared: imports.persistPrepared,
      );
      final provisional = ProvisionalFirstLogin(
        accountId: 'acct_fixture',
        expectedUsername: 'PB00000000',
      );

      expect(
        commit.commit(
          provisional: provisional,
          verifiedUsername: 'PB00000000',
          prepared: await prepared(imports),
          persistRequiredConfig: () async {
            throw StateError('config_failed');
          },
        ),
        throwsA(isA<StateError>()),
      );
      await assertNoLocalRows(db);
      expect(await db.select(db.sourceConfigs).get(), isEmpty);
    },
  );

  test(
    'success stores one account, credential metadata, batch and completed run',
    () async {
      final db = await database();
      addTearDown(db.close);
      final imports = ImportService(database: db, decoder: decoder());
      final password = Uint8List.fromList(utf8.encode('secret'));
      final provisional = ProvisionalFirstLogin(
        accountId: 'acct_fixture',
        expectedUsername: 'PB00000000',
        passwordBytes: password,
        savePassword: true,
      );
      final commit = FirstLoginCommitService(
        database: db,
        protector: TestProtector(),
        persistPrepared: imports.persistPrepared,
      );

      final result = await commit.commit(
        provisional: provisional,
        verifiedUsername: 'PB00000000',
        prepared: await prepared(imports),
      );

      expect(result.accountId, 'acct_fixture');
      expect(result.importResult.status, ImportStatus.imported);
      expect(await db.select(db.localAccounts).get(), hasLength(1));
      expect(await db.select(db.credentialAccounts).get(), hasLength(1));
      expect(await db.select(db.importBatches).get(), hasLength(1));
      expect(await db.select(db.syncRuns).get(), hasLength(1));
      expect((await db.select(db.syncRuns).getSingle()).state, 'success');
      expect(
        (await db.select(db.credentialAccounts).getSingle()).passwordCiphertext,
        isNotNull,
      );
      expect(password, orderedEquals(List<int>.filled(password.length, 0)));
    },
  );

  test(
    'savePassword false leaves password ciphertext absent while zeroing bytes',
    () async {
      final db = await database();
      addTearDown(db.close);
      final imports = ImportService(database: db, decoder: decoder());
      final password = Uint8List.fromList(utf8.encode('secret'));
      final provisional = ProvisionalFirstLogin(
        accountId: 'acct_fixture',
        expectedUsername: 'PB00000000',
        passwordBytes: password,
        savePassword: false,
      );
      final commit = FirstLoginCommitService(
        database: db,
        protector: TestProtector(),
        persistPrepared: imports.persistPrepared,
      );

      await commit.commit(
        provisional: provisional,
        verifiedUsername: 'PB00000000',
        prepared: await prepared(imports),
      );

      expect(
        (await db.select(db.credentialAccounts).getSingle()).passwordCiphertext,
        isNull,
      );
      expect(password, orderedEquals(List<int>.filled(password.length, 0)));
    },
  );

  test('reminder reconciliation is post-commit and retryable', () async {
    final db = await database();
    addTearDown(db.close);
    final imports = ImportService(database: db, decoder: decoder());
    final reconciler = RecordingReconciler(db, fail: true);
    final provisional = ProvisionalFirstLogin(
      accountId: 'acct_fixture',
      expectedUsername: 'PB00000000',
      passwordBytes: Uint8List.fromList(utf8.encode('secret')),
      savePassword: true,
    );
    final commit = FirstLoginCommitService(
      database: db,
      protector: TestProtector(),
      persistPrepared: imports.persistPrepared,
      reminderReconciler: reconciler,
    );

    final result = await commit.commit(
      provisional: provisional,
      verifiedUsername: 'PB00000000',
      prepared: await prepared(imports),
    );

    expect(result.reminderReconciliationPending, isTrue);
    expect(reconciler.sawCommittedRows, isTrue);
    expect(await db.select(db.localAccounts).get(), hasLength(1));
    expect(
      (await db.select(db.actionLogs).get()).where(
        (row) => row.actionType == 'reminder_reconcile',
      ),
      hasLength(1),
    );
  });

  test('reminder marker failure remains a successful pending commit', () async {
    final db = await database();
    addTearDown(db.close);
    final imports = ImportService(database: db, decoder: decoder());
    final reconciler = RecordingReconciler(db, fail: true);
    final commit = FirstLoginCommitService(
      database: db,
      protector: TestProtector(),
      persistPrepared: imports.persistPrepared,
      reminderReconciler: reconciler,
      writeReminderRetryMarker: ({required accountId, required source}) async {
        throw StateError('marker_unavailable');
      },
    );

    final result = await commit.commit(
      provisional: ProvisionalFirstLogin(
        accountId: 'acct_fixture',
        expectedUsername: 'PB00000000',
      ),
      verifiedUsername: 'PB00000000',
      prepared: await prepared(imports),
    );

    expect(result.importResult.status, ImportStatus.imported);
    expect(result.reminderReconciliationPending, isTrue);
    expect(result.safeDiagnostic, 'reminder_retry_marker_unavailable');
    expect(await db.select(db.localAccounts).get(), hasLength(1));
    expect(await db.select(db.importBatches).get(), hasLength(1));
  });
}
