import 'dart:async';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/security/credential_protector.dart';
import 'package:ustc_assistant_app/features/accounts/application/account_service.dart';
import 'package:ustc_assistant_app/features/import/domain/import_result.dart';
import 'package:ustc_assistant_app/features/sync/application/sync_coordinator.dart';
import 'package:ustc_assistant_app/features/sync/data/bridge_client.dart';
import 'package:ustc_assistant_app/features/sync/domain/sync_state.dart';

class CountingProtector implements CredentialProtector {
  var unprotectCalls = 0;

  @override
  Future<ProtectedSecret> protect(Uint8List plaintext) async => ProtectedSecret(
    bytes: Uint8List.fromList(plaintext.map((value) => value ^ 0x33).toList()),
    scheme: 'test',
    version: 1,
  );

  @override
  Future<Uint8List> unprotect(ProtectedSecret protected) async {
    unprotectCalls++;
    return Uint8List.fromList(
      protected.bytes.map((value) => value ^ 0x33).toList(),
    );
  }
}

class FakeBridge implements BridgeGateway {
  final starts = <SyncSource>[];
  final resumedPasswords = <String?>[];
  final cancelled = <String>[];
  final polls = <String, List<BridgeJobPoll>>{};
  var shutdowns = 0;

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
  }) async {
    starts.add(source);
    return BridgeJob(id: source.name, phase: 'starting');
  }

  @override
  Future<BridgeJobPoll> poll(String jobId, int after) async =>
      polls[jobId]!.removeAt(0);

  @override
  Future<void> resumeLogin(String jobId, {String? password}) async {
    resumedPasswords.add(password);
  }

  @override
  Future<void> cancel(String jobId) async => cancelled.add(jobId);

  @override
  Future<void> shutdown() async => shutdowns++;
}

final class _AdmissionFakeBridge extends FakeBridge
    implements BridgeAdmissionCancellation {
  var admissionCancelCalls = 0;

  @override
  Future<void> cancelAdmission() async {
    admissionCancelCalls++;
    await shutdown();
  }
}

final class _GatedPreflightAccountService extends AccountService {
  _GatedPreflightAccountService({
    required super.database,
    required super.protector,
    this.activeAccountGate,
  });

  final Completer<LocalAccount?>? activeAccountGate;

  @override
  Future<LocalAccount?> activeAccount() =>
      activeAccountGate?.future ?? super.activeAccount();
}

class AwaitingEventBridge extends FakeBridge {
  final secondPollStarted = Completer<void>();
  final terminalPoll = Completer<BridgeJobPoll>();
  var emptyPolls = 0;
  var _firstPoll = true;

  @override
  Future<BridgeJobPoll> poll(String jobId, int after) async {
    if (_firstPoll) {
      _firstPoll = false;
      emptyPolls++;
      return const BridgeJobPoll(events: [], nextSequence: 0, terminal: false);
    }
    if (!secondPollStarted.isCompleted) secondPollStarted.complete();
    return terminalPoll.future;
  }
}

class PollProtocolErrorBridge extends FakeBridge {
  PollProtocolErrorBridge(this.code);

  final String code;

  @override
  Future<BridgeJobPoll> poll(String jobId, int after) async {
    throw BridgeProtocolError(code);
  }
}

BridgeJobPoll successPoll() => const BridgeJobPoll(
  events: [
    {'sequence': 1, 'phase': 'complete'},
  ],
  nextSequence: 1,
  terminal: true,
  result: {'schemaVersion': '1.0'},
);

Future<(AppDatabase, AccountService, String)> fixture({
  required CountingProtector protector,
  int Function()? now,
}) async {
  final database = AppDatabase(NativeDatabase.memory());
  final accounts = AccountService(
    database: database,
    protector: protector,
    now: now,
  );
  final accountId = await accounts.persistVerifiedAccount(
    username: 'PB00000000',
    password: 'saved-password',
    savePassword: true,
  );
  return (database, accounts, accountId);
}

SyncCoordinator coordinator({
  required AppDatabase database,
  required AccountService accounts,
  required FakeBridge bridge,
  required int Function() now,
}) => SyncCoordinator(
  database: database,
  accounts: accounts,
  bridgeFactory: () async => bridge,
  now: now,
  importBundle: (bytes, {required accountId, required origin}) async =>
      const ImportResult(
        status: ImportStatus.imported,
        bundleId: 'bundle',
        source: 'ustc_jw',
        importedEntityCount: 3,
      ),
);

void main() {
  test(
    'immediate cancel owns a gated account lookup before bridge admission',
    () async {
      final protector = CountingProtector();
      final (database, accounts, _) = await fixture(protector: protector);
      addTearDown(database.close);
      final account = await database.select(database.localAccounts).getSingle();
      final accountGate = Completer<LocalAccount?>();
      final gatedAccounts = _GatedPreflightAccountService(
        database: database,
        protector: protector,
        activeAccountGate: accountGate,
      );
      final bridge = FakeBridge();
      var importCalls = 0;
      final service = SyncCoordinator(
        database: database,
        accounts: gatedAccounts,
        bridgeFactory: () async => bridge,
        importBundle: (bytes, {required accountId, required origin}) async {
          importCalls++;
          return const ImportResult(
            status: ImportStatus.imported,
            bundleId: 'bundle',
            source: 'ustc_jw',
            importedEntityCount: 1,
          );
        },
      );

      final syncing = service.sync(SyncSource.jw, trigger: SyncTrigger.manual);
      await Future<void>.microtask(() {});
      final cancellation = service.cancelCurrent();
      var cancellationSettled = false;
      unawaited(cancellation.then<void>((_) => cancellationSettled = true));
      await Future<void>.microtask(() {});
      expect(cancellationSettled, isFalse);
      expect(bridge.starts, isEmpty);

      accountGate.complete(account);
      expect(await syncing, isA<SyncCancelled>());
      await cancellation;
      expect(bridge.starts, isEmpty);
      expect(importCalls, 0);
    },
  );

  test('cancelled terminal result never reaches the import callback', () async {
    final protector = CountingProtector();
    final (database, accounts, accountId) = await fixture(protector: protector);
    addTearDown(database.close);
    final bridge = FakeBridge()
      ..polls['jw'] = [
        const BridgeJobPoll(
          events: [
            {'sequence': 0, 'phase': 'cancelled'},
          ],
          nextSequence: 1,
          terminal: true,
          result: {'schemaVersion': '1.0'},
          errorCode: 'cancelled',
        ),
      ];
    var importCalls = 0;
    final service = SyncCoordinator(
      database: database,
      accounts: accounts,
      bridgeFactory: () async => bridge,
      now: () => 100,
      importBundle: (bytes, {required accountId, required origin}) async {
        importCalls++;
        return const ImportResult(
          status: ImportStatus.imported,
          bundleId: 'bundle',
          source: 'ustc_jw',
          importedEntityCount: 1,
        );
      },
    );

    final outcome = await service.sync(
      SyncSource.jw,
      trigger: SyncTrigger.manual,
      accountId: accountId,
    );

    expect(outcome, isA<SyncCancelled>());
    expect(importCalls, 0);
  });

  test(
    'cancelCurrent joins bridge admission and cleans a late bridge before release',
    () async {
      final protector = CountingProtector();
      final (database, accounts, accountId) = await fixture(
        protector: protector,
      );
      addTearDown(database.close);
      final bridgeReady = Completer<BridgeGateway>();
      final factoryStarted = Completer<void>();
      final bridge = _AdmissionFakeBridge();
      final service = SyncCoordinator(
        database: database,
        accounts: accounts,
        bridgeFactory: () {
          if (!factoryStarted.isCompleted) factoryStarted.complete();
          return bridgeReady.future;
        },
        now: () => 100,
        importBundle: (bytes, {required accountId, required origin}) async =>
            throw StateError('must not import'),
      );

      final syncing = service.sync(
        SyncSource.jw,
        trigger: SyncTrigger.manual,
        accountId: accountId,
      );
      await factoryStarted.future;
      final cancellation = service.cancelCurrent();
      bridgeReady.complete(bridge);

      expect(await syncing, isA<SyncCancelled>());
      await cancellation;
      expect(bridge.admissionCancelCalls, 1);
      expect(bridge.shutdowns, 1);
      expect(bridge.starts, isEmpty);
    },
  );

  test('coordinator waits on the gateway without a fixed-delay spin', () async {
    final protector = CountingProtector();
    final (database, accounts, accountId) = await fixture(protector: protector);
    addTearDown(database.close);
    final bridge = AwaitingEventBridge();
    final service = coordinator(
      database: database,
      accounts: accounts,
      bridge: bridge,
      now: () => 100,
    );

    final syncing = service.sync(
      SyncSource.jw,
      trigger: SyncTrigger.manual,
      accountId: accountId,
    );
    await bridge.secondPollStarted.future.timeout(
      const Duration(milliseconds: 100),
    );
    expect(bridge.emptyPolls, 1);
    bridge.terminalPoll.complete(successPoll());
    expect(await syncing, isA<SyncSucceeded>());
  });

  test(
    'normal poll protocol errors retain their stable bridge mapping',
    () async {
      final protector = CountingProtector();
      final (database, accounts, accountId) = await fixture(
        protector: protector,
      );
      addTearDown(database.close);
      final bridge = PollProtocolErrorBridge('request_failed');
      final service = coordinator(
        database: database,
        accounts: accounts,
        bridge: bridge,
        now: () => 100,
      );

      final outcome = await service.sync(
        SyncSource.jw,
        trigger: SyncTrigger.manual,
        accountId: accountId,
      );

      expect(
        outcome,
        isA<SyncFailed>().having(
          (value) => value.code,
          'code',
          'request_failed',
        ),
      );
    },
  );

  test(
    'first-login poll protocol errors use first_login_failed mapping',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final accounts = AccountService(
        database: database,
        protector: CountingProtector(),
      );
      final bridge = PollProtocolErrorBridge('query_job_not_found');
      final service = SyncCoordinator(
        database: database,
        accounts: accounts,
        bridgeFactory: () async => bridge,
        now: () => 100,
        importBundle: (bytes, {required accountId, required origin}) async =>
            throw StateError('must not import'),
      );

      final outcome = await service.firstLoginSync(
        SyncSource.jw,
        username: 'PB00000000',
        password: 'saved-password',
      );

      expect(
        outcome,
        isA<SyncFailed>().having(
          (value) => value.code,
          'code',
          'first_login_failed',
        ),
      );
      expect(await database.select(database.localAccounts).get(), isEmpty);
    },
  );

  test('manual sync bypasses automatic backoff', () async {
    var clock = DateTime(2026, 7, 27, 9).millisecondsSinceEpoch;
    final protector = CountingProtector();
    final (database, accounts, accountId) = await fixture(
      protector: protector,
      now: () => clock,
    );
    addTearDown(database.close);
    final bridge = FakeBridge()..polls['jw'] = [successPoll()];
    final service = coordinator(
      database: database,
      accounts: accounts,
      bridge: bridge,
      now: () => clock,
    );
    await service.recordFailure(SyncSource.jw, accountId);
    expect(await service.isAutomaticDue(SyncSource.jw, accountId), isFalse);

    final outcome = await service.sync(
      SyncSource.jw,
      trigger: SyncTrigger.manual,
      accountId: accountId,
    );

    expect(outcome, isA<SyncSucceeded>());
  });

  test('12-hour freshness is per source and exact at the boundary', () async {
    var clock = DateTime(2026, 7, 27, 9).millisecondsSinceEpoch;
    final protector = CountingProtector();
    final (database, accounts, accountId) = await fixture(
      protector: protector,
      now: () => clock,
    );
    addTearDown(database.close);
    final bridge = FakeBridge()..polls['jw'] = [successPoll()];
    final service = coordinator(
      database: database,
      accounts: accounts,
      bridge: bridge,
      now: () => clock,
    );
    await service.sync(
      SyncSource.jw,
      trigger: SyncTrigger.manual,
      accountId: accountId,
    );
    clock += const Duration(hours: 11, minutes: 59).inMilliseconds;
    expect(await service.isAutomaticDue(SyncSource.jw, accountId), isFalse);
    clock += const Duration(minutes: 1).inMilliseconds;
    expect(await service.isAutomaticDue(SyncSource.jw, accountId), isTrue);
  });

  test(
    'sync all is sequential and source failures remain independent',
    () async {
      final protector = CountingProtector();
      final (database, accounts, accountId) = await fixture(
        protector: protector,
      );
      addTearDown(database.close);
      final bridge = FakeBridge()..polls['jw'] = [successPoll()];
      final service = coordinator(
        database: database,
        accounts: accounts,
        bridge: bridge,
        now: () => 100,
      );

      final outcomes = await service.syncAll(
        trigger: SyncTrigger.manual,
        accountId: accountId,
        resolveUserAction: (_) async => false,
      );

      expect(bridge.starts, [SyncSource.jw]);
      expect(outcomes.single, isA<SyncSucceeded>());
    },
  );

  test(
    'sync all resolves each interactive source before starting next',
    () async {
      final protector = CountingProtector();
      final (database, accounts, accountId) = await fixture(
        protector: protector,
      );
      addTearDown(database.close);
      final bridge = FakeBridge()
        ..polls['jw'] = [
          const BridgeJobPoll(
            events: [
              {'sequence': 1, 'phase': 'needs_user_login'},
            ],
            nextSequence: 1,
            terminal: false,
          ),
          successPoll(),
        ];
      final service = coordinator(
        database: database,
        accounts: accounts,
        bridge: bridge,
        now: () => 100,
      );
      final resolved = <SyncSource>[];

      final outcomes = await service.syncAll(
        trigger: SyncTrigger.manual,
        accountId: accountId,
        resolveUserAction: (action) async {
          resolved.add(action.source);
          expect(bridge.starts, [SyncSource.jw]);
          return true;
        },
      );

      expect(resolved, [SyncSource.jw]);
      expect(bridge.resumedPasswords, ['saved-password']);
      expect(outcomes, everyElement(isA<SyncSucceeded>()));
    },
  );

  test('cancelling an interactive source cancels that job', () async {
    final protector = CountingProtector();
    final (database, accounts, accountId) = await fixture(protector: protector);
    addTearDown(database.close);
    final bridge = FakeBridge()
      ..polls['jw'] = [
        const BridgeJobPoll(
          events: [
            {'sequence': 1, 'phase': 'needs_user_login'},
          ],
          nextSequence: 1,
          terminal: false,
        ),
      ];
    final service = coordinator(
      database: database,
      accounts: accounts,
      bridge: bridge,
      now: () => 100,
    );

    final outcomes = await service.syncAll(
      trigger: SyncTrigger.manual,
      accountId: accountId,
      resolveUserAction: (_) async => false,
    );

    expect(outcomes.single, isA<SyncCancelled>());
    expect(bridge.cancelled, ['jw']);
    expect(bridge.starts, [SyncSource.jw]);
  });

  test('sync without credentials fails before bridge startup', () async {
    final protector = CountingProtector();
    final (database, accounts, accountId) = await fixture(protector: protector);
    addTearDown(database.close);
    await accounts.deleteCredentials(accountId);
    var bridgeFactoryCalls = 0;
    final bridge = FakeBridge();
    final service = SyncCoordinator(
      database: database,
      accounts: accounts,
      bridgeFactory: () async {
        bridgeFactoryCalls++;
        return bridge;
      },
      now: () => 100,
      importBundle: (bytes, {required accountId, required origin}) async =>
          throw StateError('must not import'),
    );

    final outcome = await service.sync(
      SyncSource.jw,
      trigger: SyncTrigger.manual,
      accountId: accountId,
    );

    expect(
      outcome,
      isA<SyncFailed>().having(
        (value) => value.code,
        'code',
        'reauthentication_required',
      ),
    );
    expect(bridgeFactoryCalls, 0);
    final state = await service.stateFor(SyncSource.jw, accountId);
    expect(state.phase, SyncPhase.failed);
    expect(state.resultCode, 'reauthentication_required');
  });

  test(
    'password decrypts only after user confirms interactive resume',
    () async {
      final protector = CountingProtector();
      final (database, accounts, accountId) = await fixture(
        protector: protector,
      );
      addTearDown(database.close);
      final before = protector.unprotectCalls;
      final bridge = FakeBridge()
        ..polls['jw'] = [
          const BridgeJobPoll(
            events: [
              {'sequence': 1, 'phase': 'needs_user_login'},
            ],
            nextSequence: 1,
            terminal: false,
          ),
          successPoll(),
        ];
      final service = coordinator(
        database: database,
        accounts: accounts,
        bridge: bridge,
        now: () => 100,
      );

      final paused = await service.sync(
        SyncSource.jw,
        trigger: SyncTrigger.manual,
        accountId: accountId,
      );
      expect(paused, isA<SyncNeedsUserAction>());
      expect(protector.unprotectCalls, before + 1);
      expect(bridge.resumedPasswords, isEmpty);

      final completed = await service.resumeInteractive(
        'jw',
        userConfirmed: true,
      );
      expect(completed, isA<SyncSucceeded>());
      expect(protector.unprotectCalls, before + 2);
      expect(bridge.resumedPasswords, ['saved-password']);
    },
  );

  test('capability is persisted and interrupted runs recover safely', () async {
    final protector = CountingProtector();
    final (database, accounts, accountId) = await fixture(protector: protector);
    addTearDown(database.close);
    await database
        .into(database.syncRuns)
        .insert(
          SyncRunsCompanion.insert(
            id: 'abandoned',
            accountId: accountId,
            source: 'ustc_jw',
            trigger: 'automatic',
            state: 'running',
            startedAt: 1,
          ),
        );
    final bridge = FakeBridge()..polls['jw'] = [successPoll()];
    final service = coordinator(
      database: database,
      accounts: accounts,
      bridge: bridge,
      now: () => 100,
    );
    await service.recoverInterruptedRuns();
    expect(
      (await (database.select(
        database.syncRuns,
      )..where((row) => row.id.equals('abandoned'))).getSingle()).state,
      'interrupted',
    );
    await service.sync(
      SyncSource.jw,
      trigger: SyncTrigger.manual,
      accountId: accountId,
    );
    final config = await (database.select(
      database.sourceConfigs,
    )..where((row) => row.source.equals('ustc_jw'))).getSingle();
    expect(config.configJson, contains('"semesterId":461'));
  });

  test(
    'first login persists only after verified collection succeeds',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final accounts = AccountService(
        database: database,
        protector: CountingProtector(),
      );
      final bridge = FakeBridge()..polls['jw'] = [successPoll()];
      String? importedAccount;
      final service = SyncCoordinator(
        database: database,
        accounts: accounts,
        bridgeFactory: () async => bridge,
        now: () => 100,
        importBundle: (bytes, {required accountId, required origin}) async {
          importedAccount = accountId;
          return const ImportResult(
            status: ImportStatus.imported,
            bundleId: 'bundle',
            source: 'ustc_jw',
            importedEntityCount: 1,
          );
        },
      );

      final outcome = await service.firstLoginSync(
        SyncSource.jw,
        username: 'PB00000000',
        password: 'saved-password',
        savePassword: true,
      );

      expect(outcome, isA<SyncSucceeded>());
      final persisted = await database
          .select(database.localAccounts)
          .getSingle();
      expect(importedAccount, persisted.id);
      expect(bridge.starts, [SyncSource.jw]);
    },
  );

  test(
    'failed or cancelled first login discards provisional identity',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final accounts = AccountService(
        database: database,
        protector: CountingProtector(),
      );
      final bridge = FakeBridge()
        ..polls['jw'] = [
          const BridgeJobPoll(
            events: [
              {'sequence': 1, 'phase': 'failed'},
            ],
            nextSequence: 1,
            terminal: true,
            errorCode: 'collection_failed',
          ),
        ];
      final service = SyncCoordinator(
        database: database,
        accounts: accounts,
        bridgeFactory: () async => bridge,
        now: () => 100,
        importBundle: (bytes, {required accountId, required origin}) async =>
            throw StateError('must not import'),
      );
      expect(
        await service.firstLoginSync(SyncSource.jw, username: 'PB00000000'),
        isA<SyncFailed>(),
      );
      expect(await database.select(database.localAccounts).get(), isEmpty);

      bridge.polls['jw'] = [
        const BridgeJobPoll(
          events: [
            {'sequence': 1, 'phase': 'needs_user_login'},
          ],
          nextSequence: 1,
          terminal: false,
        ),
      ];
      final paused = await service.firstLoginSync(
        SyncSource.jw,
        username: 'PB00000000',
      );
      expect(paused, isA<SyncNeedsUserAction>());
      expect(
        await service.resumeInteractive(
          (paused as SyncNeedsUserAction).jobId,
          userConfirmed: false,
        ),
        isA<SyncCancelled>(),
      );
      expect(await database.select(database.localAccounts).get(), isEmpty);
    },
  );

  test('reauthentication sync restores the original account', () async {
    final protector = CountingProtector();
    final (database, accounts, accountId) = await fixture(protector: protector);
    addTearDown(database.close);
    await accounts.deleteCredentials(accountId);
    final bridge = FakeBridge()..polls['jw'] = [successPoll()];
    final service = coordinator(
      database: database,
      accounts: accounts,
      bridge: bridge,
      now: () => 100,
    );

    final outcome = await service.reauthenticate(
      SyncSource.jw,
      accountId: accountId,
      username: 'PB00000000',
      password: 'new-secret',
      savePassword: true,
    );

    expect(outcome, isA<SyncSucceeded>());
    expect(await database.select(database.localAccounts).get(), hasLength(1));
    expect(await accounts.hasCredentials(accountId), isTrue);
    expect(await accounts.passwordForInteractiveLogin(accountId), 'new-secret');
  });

  test('reauthentication rejects a different identity before bridge', () async {
    final protector = CountingProtector();
    final (database, accounts, accountId) = await fixture(protector: protector);
    addTearDown(database.close);
    await accounts.deleteCredentials(accountId);
    final bridge = FakeBridge();
    final service = coordinator(
      database: database,
      accounts: accounts,
      bridge: bridge,
      now: () => 100,
    );

    final outcome = await service.reauthenticate(
      SyncSource.jw,
      accountId: accountId,
      username: 'PB11111111',
    );

    expect(
      outcome,
      isA<SyncFailed>().having(
        (value) => value.code,
        'code',
        'identity_mismatch',
      ),
    );
    expect(bridge.starts, isEmpty);
    expect(await accounts.hasCredentials(accountId), isFalse);
  });
}
