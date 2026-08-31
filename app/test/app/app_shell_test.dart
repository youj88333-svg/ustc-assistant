import 'dart:async';
import 'dart:ui' show AppExitResponse;

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
import 'package:ustc_assistant_app/features/import/domain/import_result.dart';
import 'package:ustc_assistant_app/features/settings/application/minimal_reset_coordinator.dart';
import 'package:ustc_assistant_app/features/settings/application/settings_service.dart';
import 'package:ustc_assistant_app/features/settings/presentation/official_websites_page.dart';
import 'package:ustc_assistant_app/features/settings/presentation/settings_page.dart';
import 'package:ustc_assistant_app/features/sync/domain/sync_state.dart';
import 'package:ustc_assistant_app/features/sync/application/sync_coordinator.dart';
import 'package:ustc_assistant_app/features/sync/data/bridge_client.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_browser_session_admin.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_webview_surface_host.dart';
import 'package:ustc_assistant_app/features/sync/runtime/jw_job_arbiter.dart';
import 'package:ustc_assistant_app/features/sync/runtime/minimal_jw_runtime.dart';
import 'package:ustc_assistant_app/features/sync/runtime/source_job_gateway.dart';

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

final class _AppShellGateway
    implements SourceJobGateway, SourceJobStateReader, SourceJobImportReader {
  final StreamController<SourceJobSnapshot> _states =
      StreamController<SourceJobSnapshot>.broadcast();
  var shutdownCalls = 0;

  @override
  Stream<SourceJobSnapshot> get states => _states.stream;

  @override
  Future<SyncOutcome> firstLogin(FirstLoginCommand command) async =>
      const SyncFailed(SyncSource.jw, code: 'test');

  @override
  Future<SyncOutcome> sync({
    required String accountId,
    required SyncTrigger trigger,
  }) async => const SyncFailed(SyncSource.jw, code: 'test');

  @override
  Future<void> cancelCurrent() async {}

  @override
  Future<void> shutdown() async {
    shutdownCalls++;
    await _states.close();
  }

  @override
  Future<SyncSourceState> stateFor(String accountId) async =>
      const SyncSourceState(source: SyncSource.jw, phase: SyncPhase.idle);

  @override
  BundleImport get importBundle =>
      (bytes, {required accountId, required origin}) async =>
          const ImportResult(
            status: ImportStatus.imported,
            bundleId: 'test',
            source: 'ustc_jw',
            importedEntityCount: 0,
          );
}

final class _AppShellSessionAdmin implements JwBrowserSessionAdmin {
  final JwWebViewSurfaceHost _surfaceHost = JwWebViewSurfaceHost();
  var shutdownCalls = 0;

  @override
  JwWebViewSurfaceHost get surfaceHost => _surfaceHost;

  @override
  Future<JwBrowserSessionHandle> open(String accountId) =>
      throw UnimplementedError();

  @override
  Future<void> clearAllPartitions() async {}

  @override
  Future<void> shutdown() async {
    shutdownCalls++;
  }
}

final class _ExitGatedGateway implements SourceJobGateway {
  _ExitGatedGateway(this.events, this.shutdownGate);

  final List<String> events;
  final Completer<void> shutdownGate;
  var shutdownCalls = 0;

  @override
  Stream<SourceJobSnapshot> get states => const Stream.empty();

  @override
  Future<SyncOutcome> firstLogin(FirstLoginCommand command) async =>
      const SyncFailed(SyncSource.jw, code: 'test');

  @override
  Future<SyncOutcome> sync({
    required String accountId,
    required SyncTrigger trigger,
  }) async => const SyncFailed(SyncSource.jw, code: 'test');

  @override
  Future<void> cancelCurrent() async {}

  @override
  Future<void> shutdown() async {
    shutdownCalls++;
    events.add('runtime-shutdown-start');
    await shutdownGate.future;
    events.add('runtime-shutdown-end');
  }
}

final class _ExitFailingGateway implements SourceJobGateway {
  var shutdownCalls = 0;

  @override
  Stream<SourceJobSnapshot> get states =>
      const Stream<SourceJobSnapshot>.empty();

  @override
  Future<SyncOutcome> firstLogin(FirstLoginCommand command) async =>
      const SyncFailed(SyncSource.jw, code: 'test');

  @override
  Future<SyncOutcome> sync({
    required String accountId,
    required SyncTrigger trigger,
  }) async => const SyncFailed(SyncSource.jw, code: 'test');

  @override
  Future<void> cancelCurrent() async {}

  @override
  Future<void> shutdown() async {
    shutdownCalls++;
    throw StateError('private-cleanup-failure');
  }
}

final class _ExitTrackingDatabase extends AppDatabase {
  _ExitTrackingDatabase(this.events) : super(NativeDatabase.memory());

  final List<String> events;
  var closeCalls = 0;

  @override
  Future<void> close() async {
    closeCalls++;
    events.add('database-close');
    await super.close();
  }
}

final class _AppShellResetGateway implements SourceJobGateway {
  bool admitted = true;
  var quiesceCalls = 0;
  var resumeCalls = 0;
  var shutdownCalls = 0;

  @override
  Stream<SourceJobSnapshot> get states => const Stream<SourceJobSnapshot>.empty();

  @override
  Future<SyncOutcome> firstLogin(FirstLoginCommand command) async {
    if (!admitted) {
      return const SyncFailed(SyncSource.jw, code: 'maintenance_in_progress');
    }
    return const SyncSucceeded(SyncSource.jw, importedEntityCount: 0);
  }

  @override
  Future<SyncOutcome> sync({
    required String accountId,
    required SyncTrigger trigger,
  }) async {
    if (!admitted) {
      return const SyncFailed(SyncSource.jw, code: 'maintenance_in_progress');
    }
    return const SyncSucceeded(SyncSource.jw, importedEntityCount: 0);
  }

  @override
  Future<void> cancelCurrent() async {}

  @override
  Future<void> shutdown() async {
    shutdownCalls++;
    admitted = false;
  }

  Future<void> quiesce() {
    quiesceCalls++;
    admitted = false;
    return Future<void>.value();
  }

  Future<void> resume() {
    resumeCalls++;
    admitted = true;
    return Future<void>.value();
  }
}

final class _AppShellResetWriter implements ResetWriterPort {
  _AppShellResetWriter({this.gateway});

  final _AppShellResetGateway? gateway;
  var quiesceCalls = 0;
  var resumeCalls = 0;

  @override
  Future<void> quiesce() async {
    quiesceCalls++;
    await gateway?.quiesce();
  }

  @override
  Future<void> resume() async {
    resumeCalls++;
    await gateway?.resume();
  }
}

final class _ImmediateResetUdf implements ResetUdfPort {
  var clearCalls = 0;

  @override
  Future<void> clearAllPartitions() async {
    clearCalls++;
  }
}

final class _GatedResetUdf implements ResetUdfPort {
  _GatedResetUdf({required this.started, required this.release});

  final Completer<void> started;
  final Completer<void> release;
  var clearCalls = 0;

  @override
  Future<void> clearAllPartitions() async {
    clearCalls++;
    if (!started.isCompleted) started.complete();
    await release.future;
  }
}

final class _AppShellEmptyBridge implements BridgeGateway {
  var shutdownCalls = 0;

  @override
  Future<BridgeCapabilities> capabilities() async => const BridgeCapabilities(
    jwSemester: BridgeSemesterCapability(
      semesterId: 461,
      semesterKey: '2026fall',
      displayName: '2026 秋季学期',
    ),
  );

  @override
  Future<BridgeJob> startCollection({
    required SyncSource source,
    required String accountId,
    required String expectedUsername,
    required BridgeSemesterCapability jwSemester,
  }) async => const BridgeJob(id: 'app-shell-job', phase: 'starting');

  @override
  Future<BridgeJobPoll> poll(String jobId, int after) async =>
      const BridgeJobPoll(
        events: [
          {'sequence': 1, 'phase': 'complete'},
        ],
        nextSequence: 1,
        terminal: true,
        result: {'schemaVersion': '1.0'},
      );

  @override
  Future<void> resumeLogin(String jobId, {String? password}) async {}

  @override
  Future<void> cancel(String jobId) async {}

  @override
  Future<void> shutdown() async {
    shutdownCalls++;
  }
}

final class _AppShellFailingResumeCoordinator extends SyncCoordinator {
  _AppShellFailingResumeCoordinator({
    required super.database,
    required super.accounts,
    required super.bridgeFactory,
    required super.importBundle,
    required super.gatewayQuiesce,
    required super.gatewayResume,
  });

  @override
  Future<void> resume() =>
      Future<void>.error(StateError('replacement resume failed'));
}

final class _AppShellRuntimeBundle {
  _AppShellRuntimeBundle({
    required this.runtime,
    required this.gateway,
    required this.coordinator,
    required this.bridge,
  });

  final MinimalJwRuntime runtime;
  final SourceJobGatewayAdapter gateway;
  final SyncCoordinator coordinator;
  final _AppShellEmptyBridge bridge;
}

_AppShellRuntimeBundle _buildAppShellRuntime({
  required AppDatabase database,
  required JwBrowserSessionAdmin browserSessions,
  bool failResume = false,
}) {
  final accounts = AccountService(
    database: database,
    protector: _NoopProtector(),
  );
  final bridge = _AppShellEmptyBridge();
  late SourceJobGatewayAdapter gateway;
  Future<BridgeGateway> bridgeFactory() async => bridge;
  Future<ImportResult> importBundle(
    Uint8List bytes, {
    required String accountId,
    required ImportOrigin origin,
  }) async => const ImportResult(
    status: ImportStatus.imported,
    bundleId: 'app-shell-runtime-test',
    source: 'ustc_jw',
    importedEntityCount: 0,
  );
  final SyncCoordinator coordinator = failResume
      ? _AppShellFailingResumeCoordinator(
          database: database,
          accounts: accounts,
          bridgeFactory: bridgeFactory,
          importBundle: importBundle,
          gatewayQuiesce: () => gateway.quiesce(),
          gatewayResume: () => gateway.resume(),
        )
      : SyncCoordinator(
          database: database,
          accounts: accounts,
          bridgeFactory: bridgeFactory,
          importBundle: importBundle,
          gatewayQuiesce: () => gateway.quiesce(),
          gatewayResume: () => gateway.resume(),
        );
  gateway = SourceJobGatewayAdapter(
    coordinator: coordinator,
    arbiter: JwJobArbiter(),
    bridge: bridge,
  );
  return _AppShellRuntimeBundle(
    runtime: MinimalJwRuntime(
      gateway: gateway,
      browserSessions: browserSessions,
      syncCoordinator: coordinator,
    ),
    gateway: gateway,
    coordinator: coordinator,
    bridge: bridge,
  );
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

  testWidgets('sync routes borrow one app-owned runtime identity', (
    tester,
  ) async {
    final gateway = _AppShellGateway();
    final sessions = _AppShellSessionAdmin();
    final runtime = MinimalJwRuntime(
      gateway: gateway,
      browserSessions: sessions,
    );
    var loadCalls = 0;
    await tester.pumpWidget(
      UstcAssistantApp(
        websiteLauncher: FakeWebsiteLauncher(),
        database: database,
        runtimeLoader: () {
          loadCalls++;
          return Future<MinimalJwRuntime>.value(runtime);
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('first-login-entry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('first-login-username')), findsOneWidget);
    expect(loadCalls, 1);

    await tester.tap(find.byKey(const Key('exit-sync')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('first-login-entry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('first-login-username')), findsOneWidget);
    expect(loadCalls, 1);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await runtime.shutdown();
    expect(gateway.shutdownCalls, 1);
    expect(sessions.shutdownCalls, 1);
  });

  testWidgets('reauthentication route reuses the same runtime owner', (
    tester,
  ) async {
    await database
        .into(database.localAccounts)
        .insert(
          LocalAccountsCompanion.insert(
            id: 'runtime-account',
            maskedHint: 'PB****0000',
            identityDigest: const Value('digest'),
            isActive: const Value(true),
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    final gateway = _AppShellGateway();
    final sessions = _AppShellSessionAdmin();
    final runtime = MinimalJwRuntime(
      gateway: gateway,
      browserSessions: sessions,
    );
    var loadCalls = 0;
    await tester.pumpWidget(
      UstcAssistantApp(
        websiteLauncher: FakeWebsiteLauncher(),
        database: database,
        runtimeLoader: () {
          loadCalls++;
          return Future.value(runtime);
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.badge_outlined).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reauthenticate-runtime-account')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('reauth-username')), findsOneWidget);
    expect(loadCalls, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await runtime.shutdown();
    expect(gateway.shutdownCalls, 1);
    expect(sessions.shutdownCalls, 1);
  });

  testWidgets(
    'explicit app exit waits for runtime shutdown before closing its database',
    (tester) async {
      final events = <String>[];
      final database = _ExitTrackingDatabase(events);
      final shutdownGate = Completer<void>();
      final gateway = _ExitGatedGateway(events, shutdownGate);
      final runtime = MinimalJwRuntime(
        gateway: gateway,
        browserSessions: _AppShellSessionAdmin(),
      );
      final appKey = GlobalKey<UstcAssistantAppState>();

      await tester.pumpWidget(
        UstcAssistantApp(
          key: appKey,
          websiteLauncher: FakeWebsiteLauncher(),
          databaseFactory: () => database,
          runtimeLoader: () async => runtime,
        ),
      );
      await tester.pump();

      final exit = appKey.currentState!.prepareForExit();
      await Future<void>.microtask(() {});
      expect(events, ['runtime-shutdown-start']);
      expect(database.closeCalls, 0);

      shutdownGate.complete();
      await exit;
      expect(events, [
        'runtime-shutdown-start',
        'runtime-shutdown-end',
        'database-close',
      ]);
      expect(database.closeCalls, 1);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(gateway.shutdownCalls, 1);
      expect(database.closeCalls, 1);
    },
  );

  testWidgets(
    'app exit joins a reset paused in UDF settlement before closing database',
    (tester) async {
      final events = <String>[];
      final database = _ExitTrackingDatabase(events);
      final udfStarted = Completer<void>();
      final releaseUdf = Completer<void>();
      final udf = _GatedResetUdf(
        started: udfStarted,
        release: releaseUdf,
      );
      final gateway = _AppShellResetGateway();
      final runtime = MinimalJwRuntime(
        gateway: gateway,
        browserSessions: _AppShellSessionAdmin(),
      );
      final coordinator = MinimalResetCoordinator(
        runtime: runtime,
        sync: _AppShellResetWriter(gateway: gateway),
        agent: _AppShellResetWriter(),
        reminders: _AppShellResetWriter(),
        settings: SettingsService(
          database: database,
          accounts: AccountService(
            database: database,
            protector: _NoopProtector(),
          ),
          accountId: null,
        ),
        udfStore: udf,
        recomposeRuntime: () async {},
      );
      final appKey = GlobalKey<UstcAssistantAppState>();

      await tester.pumpWidget(
        UstcAssistantApp(
          key: appKey,
          websiteLauncher: FakeWebsiteLauncher(),
          databaseFactory: () => database,
          runtimeLoader: () async => runtime,
          resetCoordinatorLoader: () async => coordinator,
        ),
      );
      await tester.pump();
      await Future<void>.microtask(() {});
      await tester.tap(find.byTooltip('打开侧边栏'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('complete-reset')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认').last);
      await tester.pump(const Duration(milliseconds: 500));
      await udfStarted.future;

      final exit = appKey.currentState!.prepareForExit();
      await Future<void>.microtask(() {});
      expect(database.closeCalls, 0);

      releaseUdf.complete();
      await exit;
      expect(database.closeCalls, 1);
    },
  );

  testWidgets(
    'app exit joins a reset coordinator loader already in flight',
    (tester) async {
      final database = _ExitTrackingDatabase(<String>[]);
      final runtime = MinimalJwRuntime(
        gateway: _AppShellGateway(),
        browserSessions: _AppShellSessionAdmin(),
      );
      final loaderStarted = Completer<void>();
      final loaderGate = Completer<MinimalResetCoordinator>();
      final coordinator = MinimalResetCoordinator(
        runtime: runtime,
        sync: _AppShellResetWriter(),
        agent: _AppShellResetWriter(),
        reminders: _AppShellResetWriter(),
        settings: SettingsService(
          database: database,
          accounts: AccountService(
            database: database,
            protector: _NoopProtector(),
          ),
          accountId: null,
        ),
        udfStore: _ImmediateResetUdf(),
        recomposeRuntime: () async {},
      );
      final appKey = GlobalKey<UstcAssistantAppState>();

      await tester.pumpWidget(
        UstcAssistantApp(
          key: appKey,
          websiteLauncher: FakeWebsiteLauncher(),
          databaseFactory: () => database,
          runtimeLoader: () async => runtime,
          resetCoordinatorLoader: () {
            if (!loaderStarted.isCompleted) loaderStarted.complete();
            return loaderGate.future;
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('打开侧边栏'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('complete-reset')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认').last);
      await tester.pump();
      await loaderStarted.future;

      final exit = appKey.currentState!.prepareForExit();
      await Future<void>.microtask(() {});
      expect(database.closeCalls, 0);

      loaderGate.complete(coordinator);
      await exit;
      expect(database.closeCalls, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'resume failure closes the actual replacement gateway for recovery',
    (tester) async {
      final database = _ExitTrackingDatabase(<String>[]);
      final first = _buildAppShellRuntime(
        database: database,
        browserSessions: _AppShellSessionAdmin(),
      );
      final replacement = _buildAppShellRuntime(
        database: database,
        browserSessions: _AppShellSessionAdmin(),
        failResume: true,
      );
      var runtimeLoads = 0;
      var resetLoaderCalls = 0;
      final appKey = GlobalKey<UstcAssistantAppState>();
      late final MinimalResetCoordinator coordinator;
      coordinator = MinimalResetCoordinator(
        runtime: first.runtime,
        sync: first.coordinator,
        agent: _AppShellResetWriter(),
        reminders: _AppShellResetWriter(),
        settings: SettingsService(
          database: database,
          accounts: AccountService(
            database: database,
            protector: _NoopProtector(),
          ),
          accountId: null,
        ),
        udfStore: _ImmediateResetUdf(),
        recomposeRuntime: () async {
          await appKey.currentState!.runtimeOwner.replaceAfterReset();
          coordinator.bindReplacementRuntime(
            runtime: replacement.runtime,
            sync: replacement.coordinator,
          );
        },
      );
      await tester.pumpWidget(
        UstcAssistantApp(
          key: appKey,
          websiteLauncher: FakeWebsiteLauncher(),
          databaseFactory: () => database,
          runtimeLoader: () async {
            runtimeLoads++;
            return runtimeLoads == 1 ? first.runtime : replacement.runtime;
          },
          resetCoordinatorLoader: () async {
            resetLoaderCalls++;
            return coordinator;
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('打开侧边栏'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('complete-reset')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认').last);
      await tester.pumpAndSettle();
      expect(runtimeLoads, 2);
      expect(resetLoaderCalls, 1);
      final blocked = await replacement.gateway.sync(
        accountId: 'account-a',
        trigger: SyncTrigger.manual,
      );
      expect(blocked, isA<SyncFailed>());
      // The real gateway uses its terminal-safe code for both shutdown and
      // quiesced admission; either way no replacement write is admitted.
      expect((blocked as SyncFailed).code, 'runtime_shutdown');
      expect(replacement.gateway.arbiter.isBusy, isFalse);
      expect(replacement.bridge.shutdownCalls, 0);

      // The failed boundary remains owned by the app. Retrying from the same
      // settings page must reuse it and therefore continue to target this
      // replacement gateway, not create a detached coordinator.
      await tester.tap(find.byKey(const Key('complete-reset')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认').last);
      await tester.pumpAndSettle();
      expect(resetLoaderCalls, 1);
      expect(replacement.gateway.arbiter.isBusy, isFalse);

      await appKey.currentState!.prepareForExit();
      expect(replacement.bridge.shutdownCalls, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'registered Windows exit request awaits cleanup before acknowledging exit',
    (tester) async {
      final events = <String>[];
      final database = _ExitTrackingDatabase(events);
      final shutdownGate = Completer<void>();
      final gateway = _ExitGatedGateway(events, shutdownGate);
      final runtime = MinimalJwRuntime(
        gateway: gateway,
        browserSessions: _AppShellSessionAdmin(),
      );

      await tester.pumpWidget(
        UstcAssistantApp(
          websiteLauncher: FakeWebsiteLauncher(),
          databaseFactory: () => database,
          runtimeLoader: () async => runtime,
        ),
      );
      await tester.pumpAndSettle();

      final exitRequest = WidgetsBinding.instance.handleRequestAppExit();
      await tester.pump();
      expect(events, ['runtime-shutdown-start']);
      expect(database.closeCalls, 0);

      shutdownGate.complete();
      expect(await exitRequest, AppExitResponse.exit);
      expect(events, [
        'runtime-shutdown-start',
        'runtime-shutdown-end',
        'database-close',
      ]);
      expect(database.closeCalls, 1);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(gateway.shutdownCalls, 1);
      expect(database.closeCalls, 1);
    },
  );

  testWidgets(
    'registered Windows exit acknowledges after attempt-all cleanup failure',
    (tester) async {
      final database = _ExitTrackingDatabase(<String>[]);
      final gateway = _ExitFailingGateway();
      final sessionAdmin = _AppShellSessionAdmin();
      final diagnostics = <String>[];
      final runtime = MinimalJwRuntime(
        gateway: gateway,
        browserSessions: sessionAdmin,
      );

      await tester.pumpWidget(
        UstcAssistantApp(
          websiteLauncher: FakeWebsiteLauncher(),
          databaseFactory: () => database,
          runtimeLoader: () async => runtime,
          runtimeDiagnosticSink: diagnostics.add,
        ),
      );
      await tester.pumpAndSettle();

      final firstExit = WidgetsBinding.instance.handleRequestAppExit();
      await tester.pump();
      expect(await firstExit, AppExitResponse.exit);
      expect(gateway.shutdownCalls, 1);
      expect(sessionAdmin.shutdownCalls, 1);
      expect(database.closeCalls, 1);
      expect(diagnostics, ['runtime_shutdown_failed']);

      final secondExit = WidgetsBinding.instance.handleRequestAppExit();
      await tester.pump();
      expect(await secondExit, AppExitResponse.exit);
      expect(gateway.shutdownCalls, 1);
      expect(sessionAdmin.shutdownCalls, 1);
      expect(database.closeCalls, 1);
      expect(diagnostics, ['runtime_shutdown_failed']);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

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
