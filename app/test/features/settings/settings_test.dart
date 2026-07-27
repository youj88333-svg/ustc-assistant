import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/security/credential_protector.dart';
import 'package:ustc_assistant_app/features/accounts/application/account_service.dart';
import 'package:ustc_assistant_app/features/settings/application/settings_service.dart';

class FakeProtector implements CredentialProtector {
  @override
  Future<ProtectedSecret> protect(Uint8List plaintext) async => ProtectedSecret(
    bytes: Uint8List.fromList(plaintext),
    scheme: 'fake',
    version: 1,
  );

  @override
  Future<Uint8List> unprotect(ProtectedSecret protected) async =>
      Uint8List.fromList(protected.bytes);
}

void main() {
  late AppDatabase database;
  late AccountService accounts;
  late SettingsService settings;
  late String accountId;
  var browserClears = 0;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    accounts = AccountService(
      database: database,
      protector: FakeProtector(),
      clearBrowserSession: () async => browserClears++,
      now: () => 100,
    );
    accountId = await accounts.persistVerifiedAccount(
      username: 'PB00000000',
      password: 'secret',
      savePassword: true,
    );
    settings = SettingsService(
      database: database,
      accounts: accounts,
      accountId: accountId,
      now: () => 200,
    );
  });
  tearDown(() => database.close());

  test('clear cache preserves schedules and overlays', () async {
    await database
        .into(database.calendarEvents)
        .insert(
          CalendarEventsCompanion.insert(
            id: 'event',
            accountId: accountId,
            source: 'user',
            title: 'event',
            type: 'personal',
            startAt: const Value(1000),
            endAt: const Value(2000),
            allDay: false,
            timezone: 'Asia/Shanghai',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await database
        .into(database.userOverlays)
        .insert(
          UserOverlaysCompanion.insert(
            id: 'overlay',
            accountId: accountId,
            eventId: const Value('event'),
            userNotes: const Value('keep'),
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await settings.clearCache();
    expect(await database.select(database.calendarEvents).get(), hasLength(1));
    expect(await database.select(database.userOverlays).get(), hasLength(1));
  });

  test(
    'source disable and cache clearing preserve operation history',
    () async {
      await database
          .into(database.sourceConfigs)
          .insert(
            SourceConfigsCompanion.insert(
              id: '$accountId:ustc_jw',
              accountId: accountId,
              source: 'ustc_jw',
              updatedAt: 1,
            ),
          );
      final before = (await database.select(database.actionLogs).get()).length;
      await settings.setSourceEnabled('ustc_jw', false);
      await settings.clearCache();
      expect(
        (await database.select(database.actionLogs).get()).length,
        greaterThan(before),
      );
      expect(
        (await database.select(database.sourceConfigs).getSingle()).enabled,
        isFalse,
      );
      expect(await settings.sourceEnabled('ustc_jw'), isFalse);
    },
  );

  test('credentials and browser sessions are separate targets', () async {
    await settings.clearBrowserSession(confirmed: true);
    expect(browserClears, 1);
    expect(
      await database.select(database.credentialAccounts).get(),
      hasLength(1),
    );
    await settings.clearCredentials(confirmed: true);
    expect(await database.select(database.credentialAccounts).get(), isEmpty);
    expect(browserClears, 1);
  });

  test(
    'business clear and complete reset require distinct confirmations',
    () async {
      await database
          .into(database.tasks)
          .insert(
            TasksCompanion.insert(
              id: 'task',
              accountId: accountId,
              title: 'task',
              state: 'active',
              importance: 'normal',
              tagsJson: '[]',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await settings.clearBusinessData(confirmed: false);
      expect(await database.select(database.tasks).get(), hasLength(1));
      await settings.completeReset(
        firstConfirmation: true,
        secondConfirmation: false,
      );
      expect(await database.select(database.tasks).get(), hasLength(1));
      await settings.clearBusinessData(confirmed: true);
      expect(await database.select(database.tasks).get(), isEmpty);
    },
  );

  test(
    'sync interval is fixed and JW override requires complete triple',
    () async {
      expect(SettingsService.automaticSyncInterval, const Duration(hours: 12));
      expect(
        settings.setJwSemesterOverride(semesterId: 421),
        throwsA(isA<SettingsValidationError>()),
      );
      await settings.setJwSemesterOverride(
        semesterId: 421,
        semesterKey: '2026spring',
        displayName: '2026 春季学期',
      );
      var config = await (database.select(
        database.sourceConfigs,
      )..where((row) => row.source.equals('ustc_jw'))).getSingle();
      expect(config.configJson, contains('2026spring'));
      await settings.resetJwSemester();
      config = await (database.select(
        database.sourceConfigs,
      )..where((row) => row.source.equals('ustc_jw'))).getSingle();
      expect(config.configJson, contains('"semesterId":421'));
      expect(config.configJson, contains('2026spring'));
      expect(
        await database.select(database.agentPermissionPolicies).get(),
        isEmpty,
      );
    },
  );
}
