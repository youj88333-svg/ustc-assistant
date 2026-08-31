import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
}
