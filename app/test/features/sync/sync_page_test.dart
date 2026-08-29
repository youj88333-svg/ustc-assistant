import 'dart:async';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/security/credential_protector.dart';
import 'package:ustc_assistant_app/features/accounts/application/account_service.dart';
import 'package:ustc_assistant_app/features/import/domain/import_result.dart';
import 'package:ustc_assistant_app/features/sync/application/sync_coordinator.dart';
import 'package:ustc_assistant_app/features/sync/data/bridge_client.dart';
import 'package:ustc_assistant_app/features/sync/domain/sync_state.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_web_session.dart';
import 'package:ustc_assistant_app/features/sync/native/native_jw_gateway.dart';
import 'package:ustc_assistant_app/features/sync/presentation/sync_page.dart';

class _TestProtector implements CredentialProtector {
  @override
  Future<ProtectedSecret> protect(Uint8List plaintext) async =>
      ProtectedSecret(bytes: plaintext, scheme: 'test', version: 1);

  @override
  Future<Uint8List> unprotect(ProtectedSecret protected) async =>
      protected.bytes;
}

class _UnusedBridge implements BridgeGateway {
  @override
  Future<BridgeCapabilities> capabilities() => throw UnimplementedError();

  @override
  Future<void> cancel(String jobId) => throw UnimplementedError();

  @override
  Future<BridgeJobPoll> poll(String jobId, int after) =>
      throw UnimplementedError();

  @override
  Future<void> resumeLogin(String jobId, {String? password}) =>
      throw UnimplementedError();

  @override
  Future<void> shutdown() async {}

  @override
  Future<BridgeJob> startCollection({
    required SyncSource source,
    required String accountId,
    required String expectedUsername,
    required BridgeSemesterCapability jwSemester,
  }) => throw UnimplementedError();
}

class _InteractiveBridge implements BridgeGateway {
  final starts = <SyncSource>[];
  final resumed = <String>[];
  final cancelled = <String>[];
  final polls = <String, List<BridgeJobPoll>>{};

  @override
  Future<BridgeCapabilities> capabilities() async => const BridgeCapabilities(
    jwSemester: BridgeSemesterCapability(
      semesterId: 421,
      semesterKey: '2026spring',
      displayName: '2026 春季学期',
    ),
  );

  @override
  Future<BridgeJob> startCollection({
    required SyncSource source,
    required String accountId,
    required String expectedUsername,
    required BridgeSemesterCapability jwSemester,
  }) async {
    starts.add(source);
    return BridgeJob(id: source.name, phase: 'starting');
  }

  @override
  Future<BridgeJobPoll> poll(String jobId, int after) async =>
      polls[jobId]!.removeAt(0);

  @override
  Future<void> resumeLogin(String jobId, {String? password}) async {
    resumed.add(jobId);
  }

  @override
  Future<void> cancel(String jobId) async => cancelled.add(jobId);

  @override
  Future<void> shutdown() async {}
}

/// A keyed no-op controller lets the page test exercise the gateway's stable
/// host without requiring a platform WebView implementation.
class _PageSurfaceController implements JwWebviewController {
  @override
  Stream<String> get urlChanges => const Stream<String>.empty();

  @override
  String? get currentUrlSnapshot => null;

  @override
  Stream<JwLoadingState> get loadingStateChanges =>
      const Stream<JwLoadingState>.empty();

  @override
  Stream<Object?> get webMessages => const Stream<Object?>.empty();

  @override
  Future<void> awaitEventStreamReady() async {}

  @override
  Widget get surface => const SizedBox(key: Key('jw-webview-page-surface'));

  @override
  Future<void> loadUrl(String url) async {}

  @override
  Future<Object?> executeScript(String source) async => null;

  @override
  Future<void> dispatchPrimaryClick(Offset position) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> clearBrowsingDataAll() async {}

  @override
  Future<void> dispose() async {}
}

class _BlockingSyncCoordinator extends SyncCoordinator {
  _BlockingSyncCoordinator({
    required super.database,
    required super.accounts,
    required this.loginResult,
  }) : super(
         bridgeFactory: () async => _UnusedBridge(),
         importBundle: (bytes, {required accountId, required origin}) async =>
             const ImportResult(
               status: ImportStatus.imported,
               bundleId: 'unused',
               source: 'ustc_jw',
               importedEntityCount: 0,
             ),
       );

  final Future<SyncOutcome> loginResult;

  @override
  Future<SyncOutcome> firstLoginSync(
    SyncSource source, {
    required String username,
    String? password,
    bool savePassword = false,
    BridgeSemesterCapability? semesterOverride,
  }) => loginResult;
}

class _ShutdownTrackingGateway extends NativeJwGateway {
  _ShutdownTrackingGateway()
    : super(controllerFactory: () async => _PageSurfaceController());

  var shutdownCalls = 0;

  @override
  Future<void> shutdown() async {
    shutdownCalls++;
  }
}

class _OrderedShutdownGateway extends NativeJwGateway {
  _OrderedShutdownGateway(this.events)
    : super(controllerFactory: () async => _PageSurfaceController());

  final List<String> events;

  @override
  Future<void> shutdown() async {
    events.add('shutdown');
  }
}

class _AwaitableShutdownGateway extends NativeJwGateway {
  _AwaitableShutdownGateway(this.shutdownGate)
    : super(controllerFactory: () async => _PageSurfaceController());

  final Completer<void> shutdownGate;
  var shutdownCalls = 0;

  @override
  Future<void> shutdown() async {
    shutdownCalls++;
    await shutdownGate.future;
  }
}

class _GatewayUseTrackingGateway extends _ShutdownTrackingGateway {
  var diagnosticsSubscriptions = 0;
  var methodCalls = 0;

  @override
  Stream<String> get diagnostics {
    diagnosticsSubscriptions++;
    return super.diagnostics;
  }

  void _recordMethodCall() {
    methodCalls++;
  }

  @override
  Future<BridgeCapabilities> capabilities() async {
    _recordMethodCall();
    return super.capabilities();
  }

  @override
  Future<BridgeJob> startCollection({
    required SyncSource source,
    required String accountId,
    required String expectedUsername,
    required BridgeSemesterCapability jwSemester,
  }) async {
    _recordMethodCall();
    return super.startCollection(
      source: source,
      accountId: accountId,
      expectedUsername: expectedUsername,
      jwSemester: jwSemester,
    );
  }

  @override
  Future<BridgeJobPoll> poll(String jobId, int after) async {
    _recordMethodCall();
    return super.poll(jobId, after);
  }

  @override
  Future<void> resumeLogin(String jobId, {String? password}) async {
    _recordMethodCall();
    return super.resumeLogin(jobId, password: password);
  }

  @override
  Future<void> cancel(String jobId) async {
    _recordMethodCall();
    return super.cancel(jobId);
  }
}

Widget _syncPageFixture({
  required AccountService accounts,
  required SyncCoordinator coordinator,
  NativeJwGateway? nativeGateway,
}) => MaterialApp(
  home: SyncPage(
    accounts: accounts,
    coordinator: coordinator,
    nativeGateway: nativeGateway,
  ),
);

BridgeJobPoll _needsLogin() => const BridgeJobPoll(
  events: [
    {'sequence': 1, 'phase': 'needs_user_login'},
  ],
  nextSequence: 1,
  terminal: false,
);

BridgeJobPoll _success() => const BridgeJobPoll(
  events: [
    {'sequence': 2, 'phase': 'complete'},
  ],
  nextSequence: 2,
  terminal: true,
  result: {'schemaVersion': '1.0'},
);

void main() {
  testWidgets(
    'native surface host stays mounted when busy visibility changes',
    (tester) async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final accounts = AccountService(
        database: database,
        protector: _TestProtector(),
      );
      final loginResult = Completer<SyncOutcome>();
      final coordinator = _BlockingSyncCoordinator(
        database: database,
        accounts: accounts,
        loginResult: loginResult.future,
      );
      final gateway = NativeJwGateway(
        controllerFactory: () async => _PageSurfaceController(),
      );

      await tester.pumpWidget(
        _syncPageFixture(
          accounts: accounts,
          coordinator: coordinator,
          nativeGateway: gateway,
        ),
      );
      await tester.pumpAndSettle();

      final hostFinder = find.byKey(
        const Key('jw-webview-surface-host'),
        skipOffstage: false,
      );
      expect(hostFinder, findsOneWidget);
      expect(
        find.byKey(
          const Key('jw-webview-surface-placeholder'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      final hostElement = tester.element(hostFinder);
      final visibilityFinder = find.byKey(
        const Key('jw-webview-surface-visibility'),
        skipOffstage: false,
      );
      final visibilityElement = tester.element(visibilityFinder);
      expect(tester.widget<Offstage>(visibilityFinder).offstage, isTrue);

      await gateway.surfaceHost.attach(_PageSurfaceController());
      await tester.pump();
      expect(
        find.byKey(const Key('jw-webview-page-surface'), skipOffstage: false),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const Key('first-login-username')),
        'PB00000000',
      );
      await tester.tap(find.byKey(const Key('first-login-submit')));
      await tester.pump();

      expect(hostFinder, findsOneWidget);
      expect(tester.widget<Offstage>(visibilityFinder).offstage, isFalse);
      expect(
        find.byKey(const Key('first-login-submit'), skipOffstage: false),
        findsOneWidget,
      );
      expect(identical(hostElement, tester.element(hostFinder)), isTrue);
      expect(
        identical(visibilityElement, tester.element(visibilityFinder)),
        isTrue,
      );

      loginResult.complete(const SyncCancelled(SyncSource.jw));
      await tester.pumpAndSettle();

      expect(tester.widget<Offstage>(visibilityFinder).offstage, isTrue);
      expect(
        identical(visibilityElement, tester.element(visibilityFinder)),
        isTrue,
      );
    },
  );

  testWidgets('loader shuts down its owned gateway exactly once', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final gateway = _ShutdownTrackingGateway();

    await tester.pumpWidget(
      MaterialApp(
        home: SyncPageLoader(database: database, nativeGateway: gateway),
      ),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    expect(gateway.shutdownCalls, 1);
  });

  testWidgets(
    'loader shuts down a gateway that resolves after early unmount once',
    (tester) async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final creation = Completer<NativeJwGateway>();
      var factoryCalls = 0;
      final gateway = _ShutdownTrackingGateway();

      await tester.pumpWidget(
        MaterialApp(
          home: SyncPageLoader(
            database: database,
            nativeGatewayFactory: () {
              factoryCalls++;
              return creation.future;
            },
          ),
        ),
      );
      await tester.pump();
      expect(factoryCalls, 1);

      await tester.pumpWidget(const SizedBox());
      creation.complete(gateway);
      for (var i = 0; i < 4; i++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>(() {}));
      }

      expect(gateway.shutdownCalls, 1);
    },
  );

  testWidgets(
    'loader claims a gateway completed before a later dependency await',
    (tester) async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final creation = Completer<NativeJwGateway>();
      final schema = Completer<String>();
      var factoryCalls = 0;
      final gateway = _GatewayUseTrackingGateway();

      await tester.pumpWidget(
        MaterialApp(
          home: SyncPageLoader(
            database: database,
            nativeGatewayFactory: () {
              factoryCalls++;
              return creation.future;
            },
            schemaLoader: () => schema.future,
          ),
        ),
      );
      await tester.pump();
      expect(factoryCalls, 1);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      creation.complete(gateway);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(gateway.shutdownCalls, 0);

      await tester.pumpWidget(const SizedBox());
      // The factory result completed while State was alive, but _build is
      // still waiting on schema. Ownership must already be registered here.
      expect(gateway.shutdownCalls, 1);

      schema.complete('{}');
      for (var i = 0; i < 4; i++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>(() {}));
      }

      expect(gateway.shutdownCalls, 1);
      expect(gateway.diagnosticsSubscriptions, 0);
      expect(gateway.methodCalls, 0);
    },
  );

  testWidgets('first launch offers a school account login form', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final accounts = AccountService(
      database: database,
      protector: _TestProtector(),
    );
    final coordinator = SyncCoordinator(
      database: database,
      accounts: accounts,
      bridgeFactory: () async => _UnusedBridge(),
      importBundle: (bytes, {required accountId, required origin}) async =>
          const ImportResult(
            status: ImportStatus.imported,
            bundleId: 'unused',
            source: 'ustc_jw',
            importedEntityCount: 0,
          ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SyncPage(accounts: accounts, coordinator: coordinator),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('first-login-username')), findsOneWidget);
    expect(find.byKey(const Key('first-login-password')), findsOneWidget);
    expect(find.text('保存密码'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '登录并同步教务'), findsOneWidget);
  });

  testWidgets('reauthentication mode targets an existing local account', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final accounts = AccountService(
      database: database,
      protector: _TestProtector(),
    );
    final accountId = await accounts.persistVerifiedAccount(
      username: 'PB00000000',
    );
    await accounts.deleteCredentials(accountId);
    final bridge = _InteractiveBridge();
    final coordinator = SyncCoordinator(
      database: database,
      accounts: accounts,
      bridgeFactory: () async => bridge,
      importBundle: (bytes, {required accountId, required origin}) async =>
          const ImportResult(
            status: ImportStatus.imported,
            bundleId: 'unused',
            source: 'ustc_jw',
            importedEntityCount: 0,
          ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SyncPage(
          accounts: accounts,
          coordinator: coordinator,
          reauthenticateAccountId: accountId,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('PB****0000'), findsOneWidget);
    expect(find.byKey(const Key('reauth-username')), findsOneWidget);
    expect(find.byKey(const Key('reauth-password')), findsOneWidget);
    expect(find.byKey(const Key('first-login-username')), findsNothing);

    await tester.enterText(
      find.byKey(const Key('reauth-username')),
      'PB11111111',
    );
    await tester.tap(find.byKey(const Key('submit-reauthentication')));
    await tester.pumpAndSettle();
    expect(bridge.starts, isEmpty);
    expect(find.textContaining('identity_mismatch'), findsOneWidget);
  });

  testWidgets(
    'reauthentication shuts down then clears all local data before replacement',
    (tester) async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final events = <String>[];
      final accounts = AccountService(
        database: database,
        protector: _TestProtector(),
        clearBrowserSession: () async => events.add('browser-clear'),
      );
      final accountId = await accounts.persistVerifiedAccount(
        username: 'PB00000000',
        password: 'old-secret',
        savePassword: true,
      );
      await accounts.deleteCredentials(accountId);
      await database
          .into(database.sourceConfigs)
          .insert(
            SourceConfigsCompanion.insert(
              id: '$accountId:ustc_jw',
              accountId: accountId,
              source: 'ustc_jw',
              updatedAt: 100,
            ),
          );
      final gateway = _OrderedShutdownGateway(events);
      final coordinator = SyncCoordinator(
        database: database,
        accounts: accounts,
        bridgeFactory: () async => _UnusedBridge(),
        importBundle: (bytes, {required accountId, required origin}) async =>
            throw StateError('must not import'),
      );
      var replacementRouted = false;

      await tester.pumpWidget(
        MaterialApp(
          home: SyncPage(
            accounts: accounts,
            coordinator: coordinator,
            nativeGateway: gateway,
            reauthenticateAccountId: accountId,
            onReauthenticated: () {
              events.add('new-loader');
              replacementRouted = true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('reauth-username')),
        'PB00000000',
      );
      await tester.tap(find.byKey(const Key('submit-reauthentication')));
      // The page intentionally keeps its busy spinner alive while the first
      // destructive-confirmation dialog is open, so pump one frame instead of
      // waiting for all animations to settle.
      await tester.pump();
      expect(find.text('完全重置本地数据？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '确认'));
      await tester.pump();
      expect(find.text('再次确认：此操作不可撤回'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '确认'));
      await tester.pump();

      expect(replacementRouted, isTrue);
      expect(events, ['shutdown', 'browser-clear', 'new-loader']);
      expect(await (database.select(database.localAccounts)).get(), isEmpty);
      expect(
        await (database.select(database.credentialAccounts)).get(),
        isEmpty,
      );
      expect(await (database.select(database.sourceConfigs)).get(), isEmpty);
    },
  );

  testWidgets(
    'loader awaits gateway shutdown before routing to reauthentication',
    (tester) async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final accounts = AccountService(
        database: database,
        protector: _TestProtector(),
      );
      final accountId = await accounts.persistVerifiedAccount(
        username: 'PB00000000',
      );
      await accounts.deleteCredentials(accountId);
      await database
          .into(database.syncRuns)
          .insert(
            SyncRunsCompanion.insert(
              id: 'reauth-run',
              accountId: accountId,
              source: 'ustc_jw',
              trigger: 'manual',
              state: 'failed',
              resultCode: const Value('reauthentication_required'),
              startedAt: 1,
              finishedAt: const Value(2),
            ),
          );
      await database
          .into(database.sourceConfigs)
          .insert(
            SourceConfigsCompanion.insert(
              id: '$accountId:ustc_jw',
              accountId: accountId,
              source: 'ustc_jw',
              retryAfter: Value(DateTime.now().millisecondsSinceEpoch + 600000),
              updatedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
      final shutdownGate = Completer<void>();
      final gateway = _AwaitableShutdownGateway(shutdownGate);
      var routed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: SyncPageLoader(
            database: database,
            nativeGateway: gateway,
            schemaLoader: () async => '{}',
            onReauthenticationRequired: (_) => routed = true,
          ),
        ),
      );
      await tester.runAsync(() async {});
      for (
        var i = 0;
        i < 100 &&
            find.byKey(const Key('sync-reauthenticate')).evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(() async {});
      }
      expect(find.byKey(const Key('sync-reauthenticate')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sync-reauthenticate')));
      await tester.pump();
      expect(gateway.shutdownCalls, 1);
      expect(routed, isFalse);

      shutdownGate.complete();
      await tester.pumpAndSettle();
      expect(routed, isTrue);
    },
  );

  testWidgets(
    'reauthentication loader defers native environment until fresh route',
    (tester) async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final accounts = AccountService(
        database: database,
        protector: _TestProtector(),
      );
      final accountId = await accounts.persistVerifiedAccount(
        username: 'PB00000000',
      );
      await accounts.deleteCredentials(accountId);
      var factoryCalls = 0;
      var routed = false;

      await tester.pumpWidget(
        MaterialApp(
          home: SyncPageLoader(
            database: database,
            reauthenticateAccountId: accountId,
            createNativeGateway: false,
            nativeGatewayFactory: () async {
              factoryCalls++;
              return _ShutdownTrackingGateway();
            },
            schemaLoader: () async => '{}',
            onReauthenticated: () => routed = true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(factoryCalls, 0);

      await tester.enterText(
        find.byKey(const Key('reauth-username')),
        'PB00000000',
      );
      await tester.tap(find.byKey(const Key('submit-reauthentication')));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '确认'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '确认'));
      await tester.pump();

      expect(routed, isTrue);
      expect(factoryCalls, 0);
      expect(await database.select(database.localAccounts).get(), isEmpty);
    },
  );

  testWidgets('sync all resolves login before starting the next source', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final accounts = AccountService(
      database: database,
      protector: _TestProtector(),
      now: () => 100,
    );
    final accountId = await accounts.persistVerifiedAccount(
      username: 'PB00000000',
      password: 'secret',
      savePassword: true,
    );
    for (final source in SyncSource.values) {
      await database
          .into(database.sourceConfigs)
          .insert(
            SourceConfigsCompanion.insert(
              id: '$accountId:${source.storage}',
              accountId: accountId,
              source: source.storage,
              lastSuccessAt: const Value(100),
              updatedAt: 100,
            ),
          );
    }
    final bridge = _InteractiveBridge()
      ..polls['jw'] = [_needsLogin(), _success()];
    final coordinator = SyncCoordinator(
      database: database,
      accounts: accounts,
      bridgeFactory: () async => bridge,
      now: () => 100,
      importBundle: (bytes, {required accountId, required origin}) async =>
          const ImportResult(
            status: ImportStatus.imported,
            bundleId: 'bundle',
            source: 'ustc_jw',
            importedEntityCount: 1,
          ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SyncPage(accounts: accounts, coordinator: coordinator),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sync-all')));
    await tester.pumpAndSettle();

    expect(bridge.starts, [SyncSource.jw]);
    await tester.tap(find.byKey(const Key('continue-interactive-login')));
    await tester.pumpAndSettle();

    expect(bridge.resumed, ['jw']);
    expect(
      tester.widget<Text>(find.byKey(const Key('sync-state-jw'))).data,
      contains('同步成功'),
    );
  });

  testWidgets('missing credentials offer an explicit reauthentication action', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final accounts = AccountService(
      database: database,
      protector: _TestProtector(),
      now: () => 100,
    );
    final accountId = await accounts.persistVerifiedAccount(
      username: 'PB00000000',
    );
    await accounts.deleteCredentials(accountId);
    final coordinator = SyncCoordinator(
      database: database,
      accounts: accounts,
      bridgeFactory: () async => _UnusedBridge(),
      now: () => 100,
      importBundle: (bytes, {required accountId, required origin}) async =>
          throw StateError('must not import'),
    );
    String? requestedAccountId;

    await tester.pumpWidget(
      MaterialApp(
        home: SyncPage(
          accounts: accounts,
          coordinator: coordinator,
          onReauthenticationRequired: (value) {
            requestedAccountId = value;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('请先重新登录'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sync-reauthenticate')));
    expect(requestedAccountId, accountId);
  });

  testWidgets('debug diagnostics panel renders privacy-safe stage log', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final accounts = AccountService(
      database: database,
      protector: _TestProtector(),
    );
    final coordinator = SyncCoordinator(
      database: database,
      accounts: accounts,
      bridgeFactory: () async => _UnusedBridge(),
      importBundle: (bytes, {required accountId, required origin}) async =>
          const ImportResult(
            status: ImportStatus.imported,
            bundleId: 'unused',
            source: 'ustc_jw',
            importedEntityCount: 0,
          ),
    );
    final diagnostics = ValueNotifier<List<String>>([
      'attempt:jw.portal.login',
      'activationDispatched',
      'urlMatched:jw.course.home',
      'domReady:jw.course.home',
      'ready:jw.course.home',
      'course_context_read',
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: SyncPage(
          accounts: accounts,
          coordinator: coordinator,
          diagnostics: diagnostics,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('调试日志'), findsOneWidget);
    expect(find.textContaining('attempt:jw.portal.login'), findsOneWidget);
    expect(find.textContaining('activationDispatched'), findsOneWidget);
    expect(find.textContaining('course_context_read'), findsOneWidget);
    expect(find.text('6 条'), findsOneWidget);

    // The panel is transparent and reactive: it renders whatever the
    // diagnostics value holds (privacy is enforced upstream by the adapter /
    // gateway, not by this presentation layer).
    diagnostics.value = [...diagnostics.value, 'ready:jw.exam.list'];
    await tester.pump();
    expect(find.textContaining('ready:jw.exam.list'), findsOneWidget);
    expect(find.text('7 条'), findsOneWidget);

    addTearDown(diagnostics.dispose);
  });
}
