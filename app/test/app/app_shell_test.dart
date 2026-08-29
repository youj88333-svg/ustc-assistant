import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:ustc_assistant_app/app/app.dart';
import 'package:ustc_assistant_app/app/router.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/security/credential_protector.dart';
import 'package:ustc_assistant_app/features/accounts/application/account_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_composition.dart';
import 'package:ustc_assistant_app/features/agent/data/protected_agent_secret_store.dart';
import 'package:ustc_assistant_app/features/import/application/reminder_reconciler.dart';
import 'package:ustc_assistant_app/features/settings/application/settings_service.dart';
import 'package:ustc_assistant_app/features/settings/presentation/official_websites_page.dart';
import 'package:ustc_assistant_app/features/settings/presentation/settings_page.dart';

class FakeWebsiteLauncher implements OfficialWebsiteLauncher {
  final launched = <Uri>[];

  @override
  Future<bool> launch(Uri uri) async {
    launched.add(uri);
    return true;
  }
}

class _NoopProtector implements CredentialProtector {
  @override
  Future<ProtectedSecret> protect(Uint8List plaintext) async => ProtectedSecret(
    bytes: Uint8List.fromList(plaintext),
    scheme: 'test',
    version: 1,
  );

  @override
  Future<Uint8List> unprotect(ProtectedSecret protected) async =>
      Uint8List.fromList(protected.bytes);
}

void main() {
  late AppDatabase database;

  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() => database.close());

  testWidgets('bottom navigation has exactly chat and schedule', (
    tester,
  ) async {
    await tester.pumpWidget(
      UstcAssistantApp(
        websiteLauncher: FakeWebsiteLauncher(),
        database: database,
      ),
    );

    final navigation = find.byType(NavigationBar);
    expect(
      find.descendant(of: navigation, matching: find.text('聊天')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: navigation, matching: find.text('日程')),
      findsOneWidget,
    );
    expect(find.byType(NavigationDestination), findsNWidgets(2));
  });

  testWidgets('chat shows unconfigured state without active account', (
    tester,
  ) async {
    await tester.pumpWidget(
      UstcAssistantApp(
        websiteLauncher: FakeWebsiteLauncher(),
        database: database,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Without an active account, the chat shows "请先配置学校账号".
    expect(find.text('请先配置学校账号'), findsOneWidget);
  });

  testWidgets('unconfigured chat exposes a reachable first-login action', (
    tester,
  ) async {
    final router = buildRouter(
      FakeWebsiteLauncher(),
      database,
      const NoopReminderReconciler(),
      null,
      () async {},
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('first-login-entry')));
    expect(router.routeInformationProvider.value.uri.path, '/sync');
  });

  testWidgets('unconfigured settings expose complete reset without login', (
    tester,
  ) async {
    await tester.pumpWidget(
      UstcAssistantApp(
        websiteLauncher: FakeWebsiteLauncher(),
        database: database,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('打开侧边栏'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('complete-reset')), findsOneWidget);
    expect(find.text('请先配置学校账号'), findsNothing);
  });

  testWidgets(
    'unconfigured complete reset keeps data when either confirmation is cancelled',
    (tester) async {
      await database
          .into(database.localAccounts)
          .insert(
            LocalAccountsCompanion.insert(
              id: 'stale-account',
              maskedHint: 'PB****0000',
              isActive: const Value(false),
              createdAt: 1,
              updatedAt: 1,
            ),
          );

      await tester.pumpWidget(
        UstcAssistantApp(
          websiteLauncher: FakeWebsiteLauncher(),
          database: database,
          clearBrowserSession: () async {},
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('打开侧边栏'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('complete-reset')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(await database.select(database.localAccounts).get(), hasLength(1));

      await tester.tap(find.byKey(const Key('complete-reset')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(await database.select(database.localAccounts).get(), hasLength(1));
    },
  );

  testWidgets(
    'unconfigured complete reset clears all data and opens first login',
    (tester) async {
      await database
          .into(database.localAccounts)
          .insert(
            LocalAccountsCompanion.insert(
              id: 'stale-account',
              maskedHint: 'PB****0000',
              isActive: const Value(false),
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await database
          .into(database.actionLogs)
          .insert(
            ActionLogsCompanion.insert(
              id: 'stale-log',
              accountId: const Value('stale-account'),
              source: 'system',
              actionType: 'test',
              result: 'success',
              safeSummary: 'test',
              occurredAt: 1,
            ),
          );

      var resetCalled = false;
      final accounts = AccountService(
        database: database,
        protector: _NoopProtector(),
        clearBrowserSession: () async {},
      );
      final router = GoRouter(
        initialLocation: '/settings',
        routes: [
          GoRoute(
            path: '/settings',
            builder: (context, state) => SettingsPage(
              service: SettingsService(
                database: database,
                accounts: accounts,
                accountId: null,
              ),
              onCompleteReset: () {
                resetCalled = true;
                context.go('/sync');
              },
            ),
          ),
          GoRoute(
            path: '/sync',
            builder: (context, state) =>
                const Scaffold(body: Center(child: Text('fresh first login'))),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('complete-reset')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('确认').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(await database.select(database.localAccounts).get(), isEmpty);
      expect(await database.select(database.actionLogs).get(), isEmpty);
      expect(resetCalled, isTrue);
      expect(router.routeInformationProvider.value.uri.path, '/sync');
      expect(find.text('fresh first login'), findsOneWidget);
    },
  );

  testWidgets(
    'chat observes active account changes and disposes the old composition',
    (tester) async {
      for (final entry in [('a', true), ('b', false)]) {
        await database
            .into(database.localAccounts)
            .insert(
              LocalAccountsCompanion.insert(
                id: entry.$1,
                maskedHint: 'PB****0000',
                isActive: Value(entry.$2),
                createdAt: 1,
                updatedAt: 1,
              ),
            );
      }
      final builtAccounts = <String>[];
      Future<AgentCompositionResult> buildComposition(
        AppDatabase database,
        String accountId,
      ) async {
        final composition = await AgentComposition.build(
          database: database,
          accountId: accountId,
          resolvedUsername: 'PB12345678',
          accounts: AccountService(
            database: database,
            protector: _NoopProtector(),
          ),
          secretStoreFactory: (database) => ProtectedAgentSecretStore(
            database: database,
            protector: _NoopProtector(),
          ),
        );
        builtAccounts.add(accountId);
        return composition;
      }

      final router = buildRouter(
        FakeWebsiteLauncher(),
        database,
        const NoopReminderReconciler(),
        buildComposition,
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(builtAccounts, ['a']);

      await database.transaction(() async {
        await database
            .update(database.localAccounts)
            .write(const LocalAccountsCompanion(isActive: Value(false)));
        await (database.update(database.localAccounts)
              ..where((row) => row.id.equals('b')))
            .write(const LocalAccountsCompanion(isActive: Value(true)));
      });
      database.notifyActiveAccountChanged();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      // The active-account switch rebuilds the composition for the new account.
      expect(builtAccounts, ['a', 'b']);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('schedule keeps week and task choices inside one destination', (
    tester,
  ) async {
    await tester.pumpWidget(
      UstcAssistantApp(
        websiteLauncher: FakeWebsiteLauncher(),
        database: database,
      ),
    );
    await tester.tap(find.text('日程'));
    await tester.pumpAndSettle();

    expect(find.text('周视图'), findsOneWidget);
    expect(find.text('任务'), findsOneWidget);
    expect(find.byType(SegmentedButton<ScheduleSection>), findsOneWidget);
  });

  testWidgets('task center selection opens the task detail route', (
    tester,
  ) async {
    await database
        .into(database.localAccounts)
        .insert(
          LocalAccountsCompanion.insert(
            id: 'account',
            maskedHint: 'PB****0000',
            isActive: const Value(true),
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await database
        .into(database.tasks)
        .insert(
          TasksCompanion.insert(
            id: 'task-route',
            accountId: 'account',
            title: '路由测试任务',
            state: 'active',
            importance: 'normal',
            tagsJson: '[]',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await tester.pumpWidget(
      UstcAssistantApp(
        websiteLauncher: FakeWebsiteLauncher(),
        database: database,
      ),
    );
    await tester.tap(find.text('日程'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('路由测试任务'));
    await tester.pumpAndSettle();

    expect(find.text('截止风险：未定截止'), findsOneWidget);
    expect(find.byKey(const Key('schedule-task')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('global add offers task and calendar event', (tester) async {
    await tester.pumpWidget(
      UstcAssistantApp(
        websiteLauncher: FakeWebsiteLauncher(),
        database: database,
      ),
    );
    await tester.tap(find.byKey(const Key('global-add')));
    await tester.pumpAndSettle();
    expect(find.text('Task'), findsOneWidget);
    expect(find.text('Calendar event'), findsOneWidget);
  });

  testWidgets('account reauthentication route keeps the local partition', (
    tester,
  ) async {
    await database
        .into(database.localAccounts)
        .insert(
          LocalAccountsCompanion.insert(
            id: 'account',
            maskedHint: 'PB****0000',
            identityDigest: const Value('digest'),
            isActive: const Value(true),
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await tester.pumpWidget(
      UstcAssistantApp(
        websiteLauncher: FakeWebsiteLauncher(),
        database: database,
      ),
    );
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.badge_outlined).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reauthenticate-account')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('reauth-username')), findsOneWidget);
    expect(find.textContaining('PB****0000'), findsOneWidget);
  });

  testWidgets('official website page exposes only allowlisted HTTPS targets', (
    tester,
  ) async {
    final launcher = FakeWebsiteLauncher();
    await tester.pumpWidget(
      UstcAssistantApp(websiteLauncher: launcher, database: database),
    );
    await tester.tap(find.byTooltip('打开侧边栏'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学校官方网站'));
    await tester.pumpAndSettle();

    expect(find.text('教务系统'), findsOneWidget);
    expect(launcher.launched, isEmpty);
    await tester.tap(find.text('教务系统'));
    await tester.pump();
    expect(launcher.launched.single.scheme, 'https');
    expect(launcher.launched.single.host, 'jw.ustc.edu.cn');
  });

  testWidgets('drawer destinations can return to the originating main page', (
    tester,
  ) async {
    await tester.pumpWidget(
      UstcAssistantApp(
        websiteLauncher: FakeWebsiteLauncher(),
        database: database,
      ),
    );
    await tester.tap(find.text('日程'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('打开侧边栏'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学校官方网站'));
    await tester.pumpAndSettle();

    expect(find.byType(BackButton), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('周视图'), findsOneWidget);
  });
}
