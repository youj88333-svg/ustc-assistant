import 'package:drift/drift.dart';
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
}
