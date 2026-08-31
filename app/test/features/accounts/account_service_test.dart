import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/security/credential_protector.dart';
import 'package:ustc_assistant_app/features/accounts/application/account_service.dart';

class FakeProtector implements CredentialProtector {
  @override
  Future<ProtectedSecret> protect(Uint8List plaintext) async => ProtectedSecret(
    bytes: Uint8List.fromList([
      0xA5,
      for (final value in plaintext.reversed) value ^ 0x5A,
    ]),
    scheme: 'fake-test',
    version: 1,
  );

  @override
  Future<Uint8List> unprotect(ProtectedSecret protected) async {
    if (protected.scheme != 'fake-test' || protected.version != 1) {
      throw const CredentialProtectionException('unsupported_scheme');
    }
    return Uint8List.fromList(
      protected.bytes
          .skip(1)
          .map((value) => value ^ 0x5A)
          .toList()
          .reversed
          .toList(),
    );
  }
}

Future<AppDatabase> fixtureDatabase() async =>
    AppDatabase(NativeDatabase.memory());

void main() {
  test('switching account preserves the old partition', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = AccountService(
      database: database,
      protector: FakeProtector(),
    );
    final first = await service.persistVerifiedAccount(username: 'first');
    await database
        .into(database.calendarEvents)
        .insert(
          CalendarEventsCompanion.insert(
            id: 'old-event',
            accountId: first,
            source: 'user',
            title: 'Old schedule',
            type: 'personal',
            startAt: Value(DateTime(2026, 7, 27, 9).millisecondsSinceEpoch),
            endAt: Value(DateTime(2026, 7, 27, 10).millisecondsSinceEpoch),
            allDay: false,
            timezone: 'Asia/Shanghai',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    final second = await service.persistVerifiedAccount(username: 'second');

    expect((await service.activeAccount())?.id, second);
    expect(await service.eventsFor(second), isEmpty);
    expect(await service.eventsFor(first), hasLength(1));
  });

  test('password is stored only after successful school login', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = AccountService(
      database: database,
      protector: FakeProtector(),
    );
    await service.stageLogin(
      username: 'PB00000000',
      password: 'secret',
      savePassword: true,
    );
    expect(await database.select(database.credentialAccounts).get(), isEmpty);

    await service.confirmSuccessfulLogin(verifiedUsername: 'PB00000000');

    expect(
      (await database.select(database.credentialAccounts).getSingle())
          .passwordCiphertext,
      isNotNull,
    );
  });

  test('first login keeps a provisional account out of SQLite', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = AccountService(
      database: database,
      protector: FakeProtector(),
    );
    final provisional = service.beginFirstLogin();
    expect(provisional.accountId, isNotEmpty);
    expect(await database.select(database.localAccounts).get(), isEmpty);
    service.cancelFirstLogin(provisional);
    expect(await database.select(database.localAccounts).get(), isEmpty);
  });

  test(
    'staged first login preserves save-password intent in its provisional',
    () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = AccountService(
        database: database,
        protector: FakeProtector(),
      );

      final provisional = await service.stageFirstLogin(
        username: 'PB00000000',
        password: 'secret',
        savePassword: true,
      );

      expect(provisional.savePassword, isTrue);
      expect(service.stagedPasswordForInteractiveLogin(provisional), 'secret');
      service.cancelFirstLogin(provisional);
      expect(provisional.passwordBytes, isNull);
      expect(await database.select(database.localAccounts).get(), isEmpty);
    },
  );

  test('username mismatch persists neither account nor credentials', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = AccountService(
      database: database,
      protector: FakeProtector(),
    );
    await service.stageLogin(username: 'PB00000000', password: 'secret');
    expect(
      service.confirmSuccessfulLogin(verifiedUsername: 'PB11111111'),
      throwsA(isA<AccountVerificationError>()),
    );
    expect(await database.select(database.localAccounts).get(), isEmpty);
    expect(await database.select(database.credentialAccounts).get(), isEmpty);
  });

  test('username and password are absent from copied SQLite bytes', () async {
    final directory = await Directory.systemTemp.createTemp(
      'ustc-account-test',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = p.join(directory.path, 'account.sqlite');
    final database = AppDatabase(NativeDatabase(File(path)));
    final service = AccountService(
      database: database,
      protector: FakeProtector(),
    );
    await service.persistVerifiedAccount(
      username: 'PB00000000',
      password: 'adversarial-secret',
      savePassword: true,
    );
    await database.close();
    final bytes = await File(path).readAsBytes();
    final text = utf8.decode(bytes, allowMalformed: true);
    expect(text, isNot(contains('PB00000000')));
    expect(text, isNot(contains('adversarial-secret')));
  });

  test(
    'credential deletion preserves account and browser clearing is separate',
    () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      var browserClears = 0;
      final service = AccountService(
        database: database,
        protector: FakeProtector(),
        clearBrowserSession: () async => browserClears++,
      );
      final id = await service.persistVerifiedAccount(
        username: 'PB00000000',
        password: 'secret',
        savePassword: true,
      );
      await service.deleteCredentials(id);
      expect(await database.select(database.localAccounts).get(), hasLength(1));
      expect(await database.select(database.credentialAccounts).get(), isEmpty);
      expect(await service.hasCredentials(id), isFalse);
      final summary = (await service.summaries()).single;
      expect(summary.hasCredentials, isFalse);
      expect(
        (await database.select(database.localAccounts).getSingle())
            .identityDigest,
        isNotNull,
      );
      expect(
        service.usernameForSync(id),
        throwsA(
          isA<AccountVerificationError>().having(
            (error) => error.code,
            'code',
            'credentials_not_found',
          ),
        ),
      );
      expect(browserClears, 0);
      await service.clearDedicatedBrowserSession();
      expect(browserClears, 1);
    },
  );

  test('reauthentication restores credentials in the same partition', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = AccountService(
      database: database,
      protector: FakeProtector(),
    );
    final id = await service.persistVerifiedAccount(
      username: 'PB00000000',
      password: 'old-secret',
      savePassword: true,
    );
    await service.deleteCredentials(id);

    final provisional = await service.stageReauthentication(
      accountId: id,
      username: 'PB00000000',
      password: 'new-secret',
      savePassword: true,
    );
    expect(provisional.accountId, id);
    expect(
      await service.confirmSuccessfulLogin(verifiedUsername: 'PB00000000'),
      id,
    );
    expect(await service.hasCredentials(id), isTrue);
    expect(await database.select(database.localAccounts).get(), hasLength(1));
    expect(await service.passwordForInteractiveLogin(id), 'new-secret');
  });

  test('reauthentication rejects a different school account', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = AccountService(
      database: database,
      protector: FakeProtector(),
    );
    final id = await service.persistVerifiedAccount(username: 'PB00000000');
    await service.deleteCredentials(id);

    expect(
      service.stageReauthentication(accountId: id, username: 'PB11111111'),
      throwsA(
        isA<AccountVerificationError>().having(
          (error) => error.code,
          'code',
          'identity_mismatch',
        ),
      ),
    );
    expect(await database.select(database.credentialAccounts).get(), isEmpty);
    expect(await database.select(database.localAccounts).get(), hasLength(1));
  });
}
