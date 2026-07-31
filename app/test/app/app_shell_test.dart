import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/app/app.dart';
import 'package:ustc_assistant_app/app/router.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/security/credential_protector.dart';
import 'package:ustc_assistant_app/features/accounts/application/account_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_composition.dart';
import 'package:ustc_assistant_app/features/agent/application/cancellation_signal.dart';
import 'package:ustc_assistant_app/features/agent/data/protected_agent_secret_store.dart';
import 'package:ustc_assistant_app/features/agent/domain/query_source.dart';
import 'package:ustc_assistant_app/features/import/application/reminder_reconciler.dart';
import 'package:ustc_assistant_app/features/settings/presentation/official_websites_page.dart';

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

class _DisposableGateway implements DisposableQuerySourceGateway {
  bool disposed = false;

  @override
  Future<void> cancel(String jobId) async {}

  @override
  Future<void> dispose() async {
    disposed = true;
  }

  @override
  Stream<SourceQueryEvent> execute(
    SourceQuery request, {
    required CancellationSignal cancellation,
  }) => const Stream.empty();

  @override
  Future<void> resumeLogin(String jobId, {String? password}) async {}
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
      final gateways = <String, _DisposableGateway>{};
      Future<AgentCompositionResult> buildComposition(
        AppDatabase database,
        String accountId,
      ) async {
        final gateway = _DisposableGateway();
        gateways[accountId] = gateway;
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
          queryGatewayFactory: (_, _) async => gateway,
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

      expect(builtAccounts, ['a', 'b']);
      expect(gateways['a']!.disposed, isTrue);
      expect(gateways['b']!.disposed, isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  test('lazy query gateway does not start until an external query', () async {
    var starts = 0;
    final underlying = _DisposableGateway();
    final lazy = LazyQuerySourceGateway(() async {
      starts++;
      return underlying;
    });

    expect(starts, 0);
    await lazy.dispose();
    expect(starts, 0);
    expect(underlying.disposed, isFalse);
  });

  test('lazy query gateway surfaces a bounded startup failure', () async {
    final lazy = LazyQuerySourceGateway(
      () async => throw StateError('sensitive bridge startup detail'),
    );

    final events = await lazy
        .execute(
          const CampusSearchQueryRequest(query: 'library'),
          cancellation: CancellationSignal(),
        )
        .toList();

    expect(events, hasLength(1));
    expect(events.single, isA<SourceQueryFailed>());
    expect((events.single as SourceQueryFailed).code, 'bridge_unavailable');
  });

  test('lazy query gateway retries after a failed startup', () async {
    var starts = 0;
    final underlying = _DisposableGateway();
    final lazy = LazyQuerySourceGateway(() async {
      starts++;
      if (starts == 1) throw StateError('temporary startup failure');
      return underlying;
    });

    final firstAttempt = await lazy
        .execute(
          const CampusSearchQueryRequest(query: 'library'),
          cancellation: CancellationSignal(),
        )
        .toList();
    final secondAttempt = await lazy
        .execute(
          const CampusSearchQueryRequest(query: 'library'),
          cancellation: CancellationSignal(),
        )
        .toList();

    expect(
      (firstAttempt.single as SourceQueryFailed).code,
      'bridge_unavailable',
    );
    expect(secondAttempt, isEmpty);
    expect(starts, 2);
    await lazy.dispose();
    expect(underlying.disposed, isTrue);
  });

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
