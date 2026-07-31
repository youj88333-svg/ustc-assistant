import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/security/credential_protector.dart';
import 'package:ustc_assistant_app/features/accounts/application/account_service.dart';
import 'package:ustc_assistant_app/features/settings/application/settings_service.dart';
import 'package:ustc_assistant_app/features/settings/presentation/settings_page.dart';

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
    browserClears = 0;
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

  test('complete reset removes the whole account partition', () async {
    await database
        .into(database.calendarEvents)
        .insert(
          CalendarEventsCompanion.insert(
            id: 'event',
            accountId: accountId,
            source: 'ustc_jw',
            externalId: const Value('event'),
            title: 'course',
            type: 'course',
            startAt: const Value(1000),
            endAt: const Value(2000),
            allDay: false,
            timezone: 'Asia/Shanghai',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await database
        .into(database.sourceRecords)
        .insert(
          SourceRecordsCompanion.insert(
            id: 'source-record',
            accountId: accountId,
            source: 'ustc_jw',
            entityType: 'calendar_event',
            externalId: 'event',
            localEntityId: 'event',
            sourceStatus: 'active',
            presence: 'observed',
            scopeKey: 'semester',
            firstObservedAt: 1,
            lastObservedAt: 1,
          ),
        );
    await database
        .into(database.userOverlays)
        .insert(
          UserOverlaysCompanion.insert(
            id: 'overlay',
            accountId: accountId,
            eventId: const Value('event'),
            createdAt: 1,
            updatedAt: 1,
          ),
        );
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
    await database
        .into(database.planBlocks)
        .insert(
          PlanBlocksCompanion.insert(
            id: 'block',
            accountId: accountId,
            taskId: 'task',
            startAt: 1000,
            endAt: 2000,
            status: 'accepted',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await database
        .into(database.reminders)
        .insert(
          RemindersCompanion.insert(
            id: 'reminder',
            accountId: accountId,
            targetType: 'task',
            targetId: 'task',
            taskId: const Value('task'),
            triggerAt: 900,
            state: 'desired',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await settings.setPythonPath(r'E:\python.exe');
    await database.replaceUndoSlot(
      commandId: 'undo',
      payload: '{"accountId":"$accountId"}',
    );

    await settings.completeReset(
      firstConfirmation: true,
      secondConfirmation: false,
    );
    expect(await database.select(database.localAccounts).get(), hasLength(1));
    expect(await database.select(database.tasks).get(), hasLength(1));
    expect(browserClears, 0);

    await settings.completeReset(
      firstConfirmation: true,
      secondConfirmation: true,
    );

    expect(await database.select(database.localAccounts).get(), isEmpty);
    expect(await database.select(database.credentialAccounts).get(), isEmpty);
    expect(await database.select(database.calendarEvents).get(), isEmpty);
    expect(await database.select(database.sourceRecords).get(), isEmpty);
    expect(await database.select(database.userOverlays).get(), isEmpty);
    expect(await database.select(database.tasks).get(), isEmpty);
    expect(await database.select(database.planBlocks).get(), isEmpty);
    expect(await database.select(database.reminders).get(), isEmpty);
    expect(await database.select(database.sourceConfigs).get(), isEmpty);
    expect(await database.select(database.undoSlot).get(), isEmpty);
    expect(
      await (database.select(
        database.actionLogs,
      )..where((row) => row.accountId.equals(accountId))).get(),
      isEmpty,
    );
    expect(browserClears, 1);
  });

  test('browser cleanup failure does not restore a deleted account', () async {
    final failingAccounts = AccountService(
      database: database,
      protector: FakeProtector(),
      clearBrowserSession: () async => throw StateError('browser locked'),
      now: () => 300,
    );
    final failingSettings = SettingsService(
      database: database,
      accounts: failingAccounts,
      accountId: accountId,
      now: () => 400,
    );

    await expectLater(
      failingSettings.completeReset(
        firstConfirmation: true,
        secondConfirmation: true,
      ),
      throwsA(isA<BrowserSessionClearAfterResetError>()),
    );

    expect(await database.select(database.localAccounts).get(), isEmpty);
    expect(await database.select(database.credentialAccounts).get(), isEmpty);
  });

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
      expect(config.configJson, contains('"semesterId":461'));
      expect(config.configJson, contains('2026fall'));
      expect(
        await database.select(database.agentPermissionPolicies).get(),
        isEmpty,
      );
    },
  );

  testWidgets('模型服务 ListTile navigates to /settings/agent', (tester) async {
    final goRouter = GoRouter(
      initialLocation: '/settings',
      routes: [
        GoRoute(
          path: '/settings',
          builder: (context, state) => SettingsPage(service: settings),
        ),
        GoRoute(
          path: '/settings/agent',
          builder: (context, state) =>
              const Scaffold(body: Center(child: Text('agent-settings-stub'))),
        ),
      ],
    );
    addTearDown(goRouter.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: goRouter));
    await tester.pumpAndSettle();

    expect(find.text('模型服务'), findsOneWidget);
    await tester.tap(find.text('模型服务'));
    await tester.pumpAndSettle();
    expect(find.text('agent-settings-stub'), findsOneWidget);
  });
}
