import 'dart:async';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/security/credential_protector.dart';
import 'package:ustc_assistant_app/features/accounts/application/account_service.dart';
import 'package:ustc_assistant_app/features/import/domain/import_result.dart';
import 'package:ustc_assistant_app/features/sync/application/sync_coordinator.dart';
import 'package:ustc_assistant_app/features/sync/data/bridge_client.dart';
import 'package:ustc_assistant_app/features/sync/domain/sync_state.dart';
import 'package:ustc_assistant_app/features/sync/runtime/jw_job_arbiter.dart';
import 'package:ustc_assistant_app/features/sync/runtime/source_job_gateway.dart';

void main() {
  late AppDatabase database;
  late AccountService accounts;

  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
    accounts = AccountService(database: database, protector: _NoopProtector());
  });

  tearDown(() => database.close());

  test(
    'shared arbiter blocks a native job while python fallback is active',
    () async {
      final firstGate = Completer<SyncOutcome>();
      final firstCoordinator = _ScriptedCoordinator(
        database: database,
        accounts: accounts,
        syncResult: firstGate.future,
      );
      final secondCoordinator = _ScriptedCoordinator(
        database: database,
        accounts: accounts,
        syncResult: Future.value(
          const SyncSucceeded(SyncSource.jw, importedEntityCount: 1),
        ),
      );
      final arbiter = JwJobArbiter();
      final native = SourceJobGatewayAdapter(
        coordinator: firstCoordinator,
        arbiter: arbiter,
        selectedKind: JwJobKind.sync,
      );
      final python = SourceJobGatewayAdapter(
        coordinator: secondCoordinator,
        arbiter: arbiter,
        selectedKind: JwJobKind.pythonFallback,
      );

      final first = native.sync(
        accountId: 'account-a',
        trigger: SyncTrigger.manual,
      );
      await Future<void>.microtask(() {});
      final overlapping = await python.sync(
        accountId: 'account-b',
        trigger: SyncTrigger.manual,
      );
      expect(overlapping, isA<SyncFailed>());
      expect((overlapping as SyncFailed).code, 'bridge_busy');

      firstGate.complete(
        const SyncSucceeded(SyncSource.jw, importedEntityCount: 1),
      );
      expect(await first, isA<SyncSucceeded>());
      await native.shutdown();
      await python.shutdown();
    },
  );

  test(
    'overlapping login and sync return bridge_busy without invoking coordinator',
    () async {
      final gate = Completer<SyncOutcome>();
      final coordinator = _ScriptedCoordinator(
        database: database,
        accounts: accounts,
        syncResult: gate.future,
        loginResult: Future.value(
          const SyncSucceeded(SyncSource.jw, importedEntityCount: 1),
        ),
      );
      final gateway = SourceJobGatewayAdapter(
        coordinator: coordinator,
        arbiter: JwJobArbiter(),
      );

      final running = gateway.sync(
        accountId: 'opaque-account',
        trigger: SyncTrigger.manual,
      );
      await Future<void>.microtask(() {});
      final overlapping = await gateway.firstLogin(
        const FirstLoginCommand(username: 'PB00000000', password: 'secret'),
      );
      expect(overlapping, isA<SyncFailed>());
      expect((overlapping as SyncFailed).code, 'bridge_busy');
      expect(coordinator.loginCalls, 0);

      gate.complete(const SyncCancelled(SyncSource.jw));
      await running;
      await gateway.shutdown();
    },
  );

  test(
    'cancelCurrent waits for terminal settlement before releasing the lease',
    () async {
      final gate = Completer<SyncOutcome>();
      final coordinator = _ScriptedCoordinator(
        database: database,
        accounts: accounts,
        syncResult: gate.future,
      );
      final gateway = SourceJobGatewayAdapter(
        coordinator: coordinator,
        arbiter: JwJobArbiter(),
      );

      final running = gateway.sync(
        accountId: 'opaque-account',
        trigger: SyncTrigger.manual,
      );
      await Future<void>.microtask(() {});
      final cancel = gateway.cancelCurrent();
      expect(coordinator.cancelCalls, 1);
      var settled = false;
      unawaited(cancel.then<void>((_) => settled = true));
      await Future<void>.microtask(() {});
      expect(settled, isFalse);

      gate.complete(const SyncCancelled(SyncSource.jw));
      await cancel;
      expect(await running, isA<SyncCancelled>());
      expect(gateway.arbiter.isBusy, isFalse);
      await gateway.shutdown();
    },
  );

  test(
    'shutdown still closes the selected bridge after cancellation reports an error',
    () async {
      final gate = Completer<SyncOutcome>();
      final bridge = _TrackingBridge(
        throwOnCancel: true,
        throwOnShutdown: true,
      );
      final coordinator = _ScriptedCoordinator(
        database: database,
        accounts: accounts,
        syncResult: gate.future,
        cancelError: const BridgeProtocolError('bridge_busy'),
      );
      final gateway = SourceJobGatewayAdapter(
        coordinator: coordinator,
        arbiter: JwJobArbiter(),
        bridge: bridge,
      );

      final running = gateway.sync(
        accountId: 'account-a',
        trigger: SyncTrigger.manual,
      );
      await Future<void>.microtask(() {});
      final shutdown = gateway.shutdown();
      await Future<void>.microtask(() {});
      expect(coordinator.cancelCalls, 1);
      expect(bridge.shutdownCalls, 0);

      gate.complete(const SyncCancelled(SyncSource.jw));
      await running;
      await expectLater(shutdown, throwsA(anything));
      expect(bridge.cancelCalls, 0);
      expect(bridge.shutdownCalls, 1);
    },
  );

  test(
    'shutdown closes a bridge selected by a late factory completion',
    () async {
      final bridgeReady = Completer<BridgeGateway>();
      final bridge = _TrackingBridge();
      final coordinator = _ScriptedCoordinator(
        database: database,
        accounts: accounts,
        syncResult: Future.value(
          const SyncSucceeded(SyncSource.jw, importedEntityCount: 1),
        ),
      );
      final gateway = SourceJobGatewayAdapter(
        coordinator: coordinator,
        arbiter: JwJobArbiter(),
        bridgeFactory: () => bridgeReady.future,
      );

      final running = gateway.sync(
        accountId: 'account-a',
        trigger: SyncTrigger.manual,
      );
      await Future<void>.microtask(() {});
      final shutdown = gateway.shutdown();
      await Future<void>.microtask(() {});
      expect(bridge.shutdownCalls, 0);

      bridgeReady.complete(bridge);
      final outcome = await running;
      expect(outcome, isA<SyncFailed>());
      expect((outcome as SyncFailed).code, 'runtime_shutdown');
      await shutdown;
      expect(bridge.shutdownCalls, 1);
      expect(coordinator.syncCalls, 0);
    },
  );

  test('snapshots expose only safe phase/code/count fields', () async {
    final snapshots = <SourceJobSnapshot>[];
    final gateway = SourceJobGatewayAdapter(
      coordinator: _ScriptedCoordinator(
        database: database,
        accounts: accounts,
        loginResult: Future.value(
          const SyncFailed(SyncSource.jw, code: 'raw-secret-PB00000000'),
        ),
      ),
      arbiter: JwJobArbiter(),
    );
    final subscription = gateway.states.listen(snapshots.add);

    await gateway.firstLogin(
      const FirstLoginCommand(username: 'PB00000000', password: 'secret-value'),
    );
    await Future<void>.microtask(() {});
    await subscription.cancel();

    expect(snapshots, isNotEmpty);
    for (final snapshot in snapshots) {
      expect(snapshot.aggregateCount, greaterThanOrEqualTo(0));
      final encoded = snapshot.toJson().toString();
      expect(encoded, isNot(contains('PB00000000')));
      expect(encoded, isNot(contains('secret-value')));
      expect(encoded, isNot(contains('raw-secret')));
    }
    await gateway.shutdown();
  });

  test('snapshot construction also clamps raw phase and code values', () {
    const snapshot = SourceJobSnapshot(
      phase: 'raw-account-name',
      safeCode: 'raw-password',
      aggregateCount: -7,
    );

    expect(snapshot.phase, 'failed');
    expect(snapshot.safeCode, 'sync_failed');
    expect(snapshot.aggregateCount, 0);
    expect(snapshot.toJson(), {
      'phase': 'failed',
      'code': 'sync_failed',
      'aggregateCount': 0,
    });
  });

  test(
    'resumeInteractive is single-flight and retains the lease to terminal',
    () async {
      final resumeGate = Completer<SyncOutcome>();
      final coordinator = _ScriptedCoordinator(
        database: database,
        accounts: accounts,
        syncResult: Future.value(
          const SyncNeedsUserAction(SyncSource.jw, jobId: 'paused-job'),
        ),
        resumeResult: resumeGate.future,
      );
      final gateway = SourceJobGatewayAdapter(
        coordinator: coordinator,
        arbiter: JwJobArbiter(),
      );

      expect(
        await gateway.sync(accountId: 'account-a', trigger: SyncTrigger.manual),
        isA<SyncNeedsUserAction>(),
      );
      final firstResume = gateway.resumeInteractive(
        'paused-job',
        userConfirmed: true,
      );
      await Future<void>.microtask(() {});
      final secondResume = gateway.resumeInteractive(
        'paused-job',
        userConfirmed: false,
      );

      expect(identical(firstResume, secondResume), isTrue);
      expect(coordinator.resumeCalls, 1);
      expect(gateway.arbiter.isBusy, isTrue);

      resumeGate.complete(
        const SyncSucceeded(SyncSource.jw, importedEntityCount: 1),
      );
      await firstResume;
      expect(gateway.arbiter.isBusy, isFalse);
      await gateway.shutdown();
    },
  );

  test(
    'cancelCurrent joins an in-flight resume instead of releasing early',
    () async {
      final resumeGate = Completer<SyncOutcome>();
      final coordinator = _ScriptedCoordinator(
        database: database,
        accounts: accounts,
        syncResult: Future.value(
          const SyncNeedsUserAction(SyncSource.jw, jobId: 'paused-job'),
        ),
        resumeResult: resumeGate.future,
      );
      final gateway = SourceJobGatewayAdapter(
        coordinator: coordinator,
        arbiter: JwJobArbiter(),
      );
      await gateway.sync(accountId: 'account-a', trigger: SyncTrigger.manual);

      final resume = gateway.resumeInteractive(
        'paused-job',
        userConfirmed: true,
      );
      await Future<void>.microtask(() {});
      final cancel = gateway.cancelCurrent();
      await Future<void>.microtask(() {});

      expect(coordinator.resumeCalls, 1);
      expect(coordinator.cancelCalls, 1);
      expect(gateway.arbiter.isBusy, isTrue);

      resumeGate.complete(const SyncCancelled(SyncSource.jw));
      await cancel;
      await resume;
      expect(gateway.arbiter.isBusy, isFalse);
      await gateway.shutdown();
    },
  );

  test(
    'cancel-first serializes a real paused resume until cancellation settles',
    () async {
      final fixture = await _realInteractiveFixture(database, accounts);
      final paused = await fixture.gateway.sync(
        accountId: fixture.accountId,
        trigger: SyncTrigger.manual,
      );
      expect(paused, isA<SyncNeedsUserAction>());

      final cancellation = fixture.gateway.cancelCurrent();
      await Future<void>.microtask(() {});
      expect(fixture.bridge.cancelCalls, 1);
      expect(fixture.gateway.arbiter.isBusy, isTrue);

      final resume = fixture.gateway.resumeInteractive(
        'gated-job',
        userConfirmed: true,
      );
      var resumeSettled = false;
      unawaited(resume.then<void>((_) => resumeSettled = true));
      await Future<void>.microtask(() {});
      expect(resumeSettled, isFalse);
      expect(fixture.bridge.resumeCalls, 0);
      expect(fixture.gateway.arbiter.isBusy, isTrue);

      fixture.bridge.cancelGate.complete();
      await cancellation;
      expect(await resume, isA<SyncCancelled>());
      expect(fixture.gateway.arbiter.isBusy, isFalse);
      await fixture.gateway.shutdown();
    },
  );

  test(
    'resume-first and cancel remain one real coordinator operation',
    () async {
      final fixture = await _realInteractiveFixture(database, accounts);
      final paused = await fixture.gateway.sync(
        accountId: fixture.accountId,
        trigger: SyncTrigger.manual,
      );
      expect(paused, isA<SyncNeedsUserAction>());

      final resume = fixture.gateway.resumeInteractive(
        'gated-job',
        userConfirmed: true,
      );
      await fixture.bridge.resumeStarted.future;
      expect(fixture.bridge.resumeCalls, 1);
      final duplicate = fixture.gateway.resumeInteractive(
        'gated-job',
        userConfirmed: false,
      );
      expect(identical(resume, duplicate), isTrue);

      final cancellation = fixture.gateway.cancelCurrent();
      await Future<void>.microtask(() {});
      expect(fixture.bridge.cancelCalls, 1);
      expect(fixture.gateway.arbiter.isBusy, isTrue);

      fixture.bridge.cancelGate.complete();
      expect(await resume, isA<SyncCancelled>());
      await cancellation;
      expect(fixture.gateway.arbiter.isBusy, isFalse);
      await fixture.gateway.shutdown();
    },
  );

  test('shutdown closes diagnostics even when bridge cleanup fails', () async {
    final gateway = SourceJobGatewayAdapter(
      coordinator: _ScriptedCoordinator(database: database, accounts: accounts),
      arbiter: JwJobArbiter(),
      bridge: _TrackingBridge(throwOnShutdown: true),
    );
    final diagnosticsDone = expectLater(gateway.diagnostics, emitsDone);

    await expectLater(gateway.shutdown(), throwsA(anything));
    await diagnosticsDone.timeout(const Duration(seconds: 1));
  });

  test(
    'direct file import is admitted, drained, and refused across gateway quiesce',
    () async {
      final importGate = Completer<ImportResult>();
      var importCalls = 0;
      final coordinator = SyncCoordinator(
        database: database,
        accounts: accounts,
        bridgeFactory: () async => _TrackingBridge(),
        importBundle: (bytes, {required accountId, required origin}) {
          importCalls++;
          if (importCalls == 1) return importGate.future;
          return Future<ImportResult>.value(
            const ImportResult(
              status: ImportStatus.imported,
              bundleId: 'file-import',
              source: 'ustc_jw',
              importedEntityCount: 1,
            ),
          );
        },
      );
      final gateway = SourceJobGatewayAdapter(
        coordinator: coordinator,
        arbiter: JwJobArbiter(),
      );

      final admitted = gateway.importBundle(
        Uint8List.fromList(<int>[1]),
        accountId: 'opaque-account',
        origin: ImportOrigin.file,
      );
      expect(importCalls, 1);
      final quiescing = gateway.quiesce();
      var quiesced = false;
      unawaited(quiescing.then<void>((_) => quiesced = true));
      await Future<void>.microtask(() {});
      expect(quiesced, isFalse);

      await expectLater(
        gateway.importBundle(
          Uint8List.fromList(<int>[2]),
          accountId: 'opaque-account',
          origin: ImportOrigin.file,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.toString(),
            'message',
            contains('maintenance_in_progress'),
          ),
        ),
      );

      importGate.complete(
        const ImportResult(
          status: ImportStatus.imported,
          bundleId: 'file-import',
          source: 'ustc_jw',
          importedEntityCount: 1,
        ),
      );
      await admitted;
      await quiescing;
      expect(quiesced, isTrue);
      await gateway.resume();
      expect(
        await gateway.importBundle(
          Uint8List.fromList(<int>[3]),
          accountId: 'opaque-account',
          origin: ImportOrigin.file,
        ),
        isA<ImportResult>(),
      );
      expect(importCalls, 2);
      await gateway.shutdown();
    },
  );

  test(
    'cancelCurrent covers bridge admission before a coordinator job exists',
    () async {
      final bridgeReady = Completer<BridgeGateway>();
      final bridge = _AdmissionTrackingBridge();
      final coordinator = _ScriptedCoordinator(
        database: database,
        accounts: accounts,
        syncResult: Future.value(
          const SyncSucceeded(SyncSource.jw, importedEntityCount: 1),
        ),
      );
      final gateway = SourceJobGatewayAdapter(
        coordinator: coordinator,
        arbiter: JwJobArbiter(),
        bridgeFactory: () => bridgeReady.future,
      );

      final running = gateway.sync(
        accountId: 'account-a',
        trigger: SyncTrigger.manual,
      );
      await Future<void>.microtask(() {});
      final cancellation = gateway.cancelCurrent();
      await Future<void>.microtask(() {});
      expect(gateway.arbiter.isBusy, isTrue);

      bridgeReady.complete(bridge);
      final outcome = await running;
      await cancellation;
      expect(outcome, isA<SyncCancelled>());
      expect(bridge.cancelAdmissionCalls, 1);
      expect(bridge.shutdownCalls, 1);
      expect(coordinator.syncCalls, 0);
      expect(gateway.arbiter.isBusy, isFalse);
    },
  );

  test(
    'gateway holds its lease while coordinator admits a gated account lookup',
    () async {
      final accountId = await accounts.persistVerifiedAccount(
        username: 'PB00000000',
        password: 'saved-password',
        savePassword: true,
      );
      final credentialsGate = Completer<bool>();
      final credentialsStarted = Completer<void>();
      final gatedAccounts = _GatedCredentialsAccountService(
        database: database,
        protector: _NoopProtector(),
        credentialsGate: credentialsGate,
        started: credentialsStarted,
      );
      final bridge = _SuccessfulBridge();
      var importCalls = 0;
      final coordinator = SyncCoordinator(
        database: database,
        accounts: gatedAccounts,
        bridgeFactory: () async => bridge,
        importBundle: (bytes, {required accountId, required origin}) async {
          importCalls++;
          return const ImportResult(
            status: ImportStatus.imported,
            bundleId: 'test',
            source: 'ustc_jw',
            importedEntityCount: 1,
          );
        },
      );
      final gateway = SourceJobGatewayAdapter(
        coordinator: coordinator,
        arbiter: JwJobArbiter(),
        bridge: bridge,
      );

      final running = gateway.sync(
        accountId: accountId,
        trigger: SyncTrigger.manual,
      );
      await credentialsStarted.future;
      final cancellation = gateway.cancelCurrent();
      var cancellationSettled = false;
      unawaited(cancellation.then<void>((_) => cancellationSettled = true));
      await Future<void>.microtask(() {});
      expect(cancellationSettled, isFalse);
      expect(gateway.arbiter.isBusy, isTrue);

      credentialsGate.complete(true);
      expect(await running, isA<SyncCancelled>());
      await cancellation;
      expect(bridge.starts, isEmpty);
      expect(importCalls, 0);
      expect(gateway.arbiter.isBusy, isFalse);
      await gateway.shutdown();
    },
  );

  test(
    'coordinator admission cancellation invalidates both fallback bridge caches',
    () async {
      final accountId = await accounts.persistVerifiedAccount(
        username: 'PB00000000',
        password: 'saved-password',
        savePassword: true,
      );
      final credentialsGate = Completer<bool>();
      final credentialsStarted = Completer<void>();
      final gatedAccounts = _GatedCredentialsAccountService(
        database: database,
        protector: _NoopProtector(),
        credentialsGate: credentialsGate,
        started: credentialsStarted,
      );
      final first = _ClosedFallbackBridge();
      final second = _SuccessfulBridge();
      BridgeGateway? selected;
      var factoryCalls = 0;
      var firstCreated = false;
      Future<BridgeGateway> selectBridge() async {
        factoryCalls++;
        if (selected != null) return selected!;
        selected = firstCreated ? second : first;
        firstCreated = true;
        return selected!;
      }

      late SourceJobGatewayAdapter gateway;
      void invalidateBridge(BridgeGateway bridge) {
        if (identical(selected, bridge)) selected = null;
        gateway.invalidateCachedBridge(bridge);
      }

      final coordinator = SyncCoordinator(
        database: database,
        accounts: gatedAccounts,
        bridgeFactory: selectBridge,
        invalidateBridge: invalidateBridge,
        importBundle: (bytes, {required accountId, required origin}) async =>
            const ImportResult(
              status: ImportStatus.imported,
              bundleId: 'test',
              source: 'ustc_jw',
              importedEntityCount: 1,
            ),
      );
      gateway = SourceJobGatewayAdapter(
        coordinator: coordinator,
        arbiter: JwJobArbiter(),
        selectedKind: JwJobKind.pythonFallback,
        bridgeFactory: selectBridge,
        invalidateBridge: invalidateBridge,
      );

      final running = gateway.sync(
        accountId: accountId,
        trigger: SyncTrigger.manual,
      );
      await credentialsStarted.future;
      final cancellation = gateway.cancelCurrent();
      await Future<void>.microtask(() {});
      expect(gateway.arbiter.isBusy, isTrue);
      credentialsGate.complete(true);
      expect(await running, isA<SyncCancelled>());
      await cancellation;
      expect(first.shutdownCalls, 1);
      await expectLater(first.capabilities(), throwsA(anything));

      final retry = await gateway.sync(
        accountId: accountId,
        trigger: SyncTrigger.manual,
      );
      expect(retry, isA<SyncSucceeded>());
      expect(factoryCalls, 3);
      await gateway.shutdown();
    },
  );

  test(
    'fallback admission cancellation invalidates its cached bridge before retry',
    () async {
      final first = _ClosedFallbackBridge();
      final second = _ClosedFallbackBridge();
      final firstReady = Completer<BridgeGateway>();
      BridgeGateway? selected;
      var factoryCalls = 0;
      Future<BridgeGateway> selectBridge() async {
        factoryCalls++;
        if (factoryCalls == 1) {
          final bridge = await firstReady.future;
          selected = bridge;
          return bridge;
        }
        return selected ??= second;
      }

      final gateway = SourceJobGatewayAdapter(
        coordinator: _ScriptedCoordinator(
          database: database,
          accounts: accounts,
          syncResult: Future.value(
            const SyncSucceeded(SyncSource.jw, importedEntityCount: 1),
          ),
        ),
        arbiter: JwJobArbiter(),
        selectedKind: JwJobKind.pythonFallback,
        bridgeFactory: selectBridge,
        invalidateBridge: (bridge) {
          if (identical(selected, bridge)) selected = null;
        },
      );

      final running = gateway.sync(
        accountId: 'account-a',
        trigger: SyncTrigger.manual,
      );
      await Future<void>.microtask(() {});
      final cancellation = gateway.cancelCurrent();
      firstReady.complete(first);
      expect(await running, isA<SyncCancelled>());
      await cancellation;
      expect(first.shutdownCalls, 1);
      expect(factoryCalls, 1);
      await expectLater(first.capabilities(), throwsA(anything));

      final retry = await gateway.sync(
        accountId: 'account-a',
        trigger: SyncTrigger.manual,
      );
      expect(retry, isA<SyncSucceeded>());
      expect(factoryCalls, 2);
      expect(second.shutdownCalls, 0);
      await gateway.shutdown();
    },
  );

  test('cancellation keeps the lease through gated fallback cleanup', () async {
    final firstSync = Completer<SyncOutcome>();
    final firstBridge = _GatedShutdownBridge();
    final secondBridge = _SuccessfulBridge();
    var factoryCalls = 0;
    BridgeGateway? selected;
    late SourceJobGatewayAdapter gateway;
    Future<BridgeGateway> selectBridge() async {
      factoryCalls++;
      return selected ??= factoryCalls == 1 ? firstBridge : secondBridge;
    }

    void invalidateBridge(BridgeGateway bridge) {
      if (identical(selected, bridge)) selected = null;
      gateway.invalidateCachedBridge(bridge);
    }

    final coordinator = _PostOperationCoordinator(
      database: database,
      accounts: accounts,
      firstSync: firstSync,
    );
    gateway = SourceJobGatewayAdapter(
      coordinator: coordinator,
      arbiter: JwJobArbiter(),
      selectedKind: JwJobKind.pythonFallback,
      bridgeFactory: selectBridge,
      invalidateBridge: invalidateBridge,
    );

    final running = gateway.sync(
      accountId: 'account-a',
      trigger: SyncTrigger.manual,
    );
    await Future<void>.microtask(() {});
    expect(coordinator.syncCalls, 1);

    final cancellation = gateway.cancelCurrent();
    firstSync.complete(const SyncCancelled(SyncSource.jw));
    expect(await running, isA<SyncCancelled>());
    await firstBridge.shutdownStarted.future;
    var cancellationSettled = false;
    unawaited(
      cancellation.then<void>(
        (_) => cancellationSettled = true,
        onError: (Object _, StackTrace _) => cancellationSettled = true,
      ),
    );
    await Future<void>.microtask(() {});
    expect(cancellationSettled, isFalse);

    final blockedSync = await gateway.sync(
      accountId: 'account-a',
      trigger: SyncTrigger.manual,
    );
    final blockedLogin = await gateway.firstLogin(
      const FirstLoginCommand(username: 'PB00000000'),
    );
    expect(blockedSync, isA<SyncFailed>());
    expect((blockedSync as SyncFailed).code, 'bridge_busy');
    expect(blockedLogin, isA<SyncFailed>());
    expect((blockedLogin as SyncFailed).code, 'bridge_busy');
    expect(factoryCalls, 1);
    expect(coordinator.syncCalls, 1);
    expect(coordinator.loginCalls, 0);

    firstBridge.shutdownGate.complete();
    await cancellation;
    final retry = await gateway.sync(
      accountId: 'account-a',
      trigger: SyncTrigger.manual,
    );
    expect(retry, isA<SyncSucceeded>());
    expect(factoryCalls, 2);
    expect(coordinator.syncCalls, 2);
    await gateway.shutdown();
  });

  test(
    'cleanup errors still release only after settlement and permit retry',
    () async {
      final firstSync = Completer<SyncOutcome>();
      final firstBridge = _GatedShutdownBridge(throwOnShutdown: true);
      final secondBridge = _SuccessfulBridge();
      var factoryCalls = 0;
      BridgeGateway? selected;
      late SourceJobGatewayAdapter gateway;
      Future<BridgeGateway> selectBridge() async {
        factoryCalls++;
        return selected ??= factoryCalls == 1 ? firstBridge : secondBridge;
      }

      void invalidateBridge(BridgeGateway bridge) {
        if (identical(selected, bridge)) selected = null;
        gateway.invalidateCachedBridge(bridge);
      }

      final coordinator = _PostOperationCoordinator(
        database: database,
        accounts: accounts,
        firstSync: firstSync,
      );
      gateway = SourceJobGatewayAdapter(
        coordinator: coordinator,
        arbiter: JwJobArbiter(),
        selectedKind: JwJobKind.pythonFallback,
        bridgeFactory: selectBridge,
        invalidateBridge: invalidateBridge,
      );

      final running = gateway.sync(
        accountId: 'account-a',
        trigger: SyncTrigger.manual,
      );
      await Future<void>.microtask(() {});
      final cancellation = gateway.cancelCurrent();
      firstSync.complete(const SyncCancelled(SyncSource.jw));
      expect(await running, isA<SyncCancelled>());
      await firstBridge.shutdownStarted.future;
      var cancellationSettled = false;
      unawaited(
        cancellation.then<void>(
          (_) => cancellationSettled = true,
          onError: (Object _, StackTrace _) => cancellationSettled = true,
        ),
      );
      await Future<void>.microtask(() {});
      expect(cancellationSettled, isFalse);

      final blockedSync = await gateway.sync(
        accountId: 'account-a',
        trigger: SyncTrigger.manual,
      );
      final blockedLogin = await gateway.firstLogin(
        const FirstLoginCommand(username: 'PB00000000'),
      );
      expect(blockedSync, isA<SyncFailed>());
      expect((blockedSync as SyncFailed).code, 'bridge_busy');
      expect(blockedLogin, isA<SyncFailed>());
      expect((blockedLogin as SyncFailed).code, 'bridge_busy');
      expect(factoryCalls, 1);
      expect(coordinator.syncCalls, 1);
      expect(coordinator.loginCalls, 0);

      firstBridge.shutdownGate.complete();
      await expectLater(cancellation, throwsA(isA<BridgeProtocolError>()));
      final retry = await gateway.sync(
        accountId: 'account-a',
        trigger: SyncTrigger.manual,
      );
      expect(retry, isA<SyncSucceeded>());
      expect(factoryCalls, 2);
      expect(coordinator.syncCalls, 2);
      await gateway.shutdown();
    },
  );
}

final class _NoopProtector implements CredentialProtector {
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

final class _ScriptedCoordinator extends SyncCoordinator {
  _ScriptedCoordinator({
    required super.database,
    required super.accounts,
    this.syncResult,
    this.loginResult,
    this.cancelError,
    this.resumeResult,
  }) : super(
         bridgeFactory: () async => _TrackingBridge(),
         importBundle: (bytes, {required accountId, required origin}) async =>
             const ImportResult(
               status: ImportStatus.imported,
               bundleId: 'test',
               source: 'ustc_jw',
               importedEntityCount: 1,
             ),
       );

  final Future<SyncOutcome>? syncResult;
  final Future<SyncOutcome>? loginResult;
  final Object? cancelError;
  final Future<SyncOutcome>? resumeResult;
  var syncCalls = 0;
  var loginCalls = 0;
  var cancelCalls = 0;
  var resumeCalls = 0;

  @override
  Future<SyncOutcome> sync(
    SyncSource source, {
    required SyncTrigger trigger,
    String? accountId,
    BridgeSemesterCapability? semesterOverride,
  }) {
    syncCalls++;
    return syncResult ??
        Future.value(
          const SyncSucceeded(SyncSource.jw, importedEntityCount: 1),
        );
  }

  @override
  Future<SyncOutcome> firstLoginSync(
    SyncSource source, {
    required String username,
    String? password,
    bool savePassword = false,
    BridgeSemesterCapability? semesterOverride,
  }) {
    loginCalls++;
    return loginResult ??
        syncResult ??
        Future.value(
          const SyncSucceeded(SyncSource.jw, importedEntityCount: 1),
        );
  }

  @override
  Future<void> cancelCurrent() async {
    cancelCalls++;
    final error = cancelError;
    if (error != null) throw error;
  }

  @override
  Future<SyncOutcome> resumeInteractive(
    String jobId, {
    required bool userConfirmed,
  }) {
    resumeCalls++;
    return resumeResult ??
        super.resumeInteractive(jobId, userConfirmed: userConfirmed);
  }
}

final class _PostOperationCoordinator extends SyncCoordinator {
  _PostOperationCoordinator({
    required super.database,
    required super.accounts,
    required this.firstSync,
  }) : super(
         bridgeFactory: () async => _TrackingBridge(),
         importBundle: (bytes, {required accountId, required origin}) async =>
             const ImportResult(
               status: ImportStatus.imported,
               bundleId: 'test',
               source: 'ustc_jw',
               importedEntityCount: 1,
             ),
       );

  final Completer<SyncOutcome> firstSync;
  var syncCalls = 0;
  var loginCalls = 0;

  @override
  Future<SyncOutcome> sync(
    SyncSource source, {
    required SyncTrigger trigger,
    String? accountId,
    BridgeSemesterCapability? semesterOverride,
  }) {
    syncCalls++;
    if (syncCalls == 1) return firstSync.future;
    return Future.value(
      const SyncSucceeded(SyncSource.jw, importedEntityCount: 1),
    );
  }

  @override
  Future<SyncOutcome> firstLoginSync(
    SyncSource source, {
    required String username,
    String? password,
    bool savePassword = false,
    BridgeSemesterCapability? semesterOverride,
  }) {
    loginCalls++;
    return Future.value(
      const SyncSucceeded(SyncSource.jw, importedEntityCount: 1),
    );
  }

  @override
  Future<void> cancelCurrent() async {}
}

final class _RealInteractiveFixture {
  _RealInteractiveFixture({
    required this.database,
    required this.accountId,
    required this.bridge,
    required this.gateway,
  });

  final AppDatabase database;
  final String accountId;
  final _GatedInteractiveBridge bridge;
  final SourceJobGatewayAdapter gateway;
}

final class _GatedCredentialsAccountService extends AccountService {
  _GatedCredentialsAccountService({
    required super.database,
    required super.protector,
    required this.credentialsGate,
    required this.started,
  });

  final Completer<bool> credentialsGate;
  final Completer<void> started;

  @override
  Future<bool> hasCredentials(String accountId) {
    if (!started.isCompleted) started.complete();
    return credentialsGate.future;
  }
}

final class _SuccessfulBridge implements BridgeGateway {
  final starts = <SyncSource>[];

  @override
  Future<BridgeCapabilities> capabilities() async {
    return const BridgeCapabilities(
      jwSemester: BridgeSemesterCapability(
        semesterId: 461,
        semesterKey: '2026fall',
        displayName: '2026 秋季学期',
      ),
    );
  }

  @override
  Future<BridgeJob> startCollection({
    required SyncSource source,
    required String accountId,
    required String expectedUsername,
    required BridgeSemesterCapability jwSemester,
  }) async {
    starts.add(source);
    return const BridgeJob(id: 'successful-job', phase: 'starting');
  }

  @override
  Future<BridgeJobPoll> poll(String jobId, int after) async {
    return const BridgeJobPoll(
      events: [
        {'sequence': 1, 'phase': 'complete'},
      ],
      nextSequence: 1,
      terminal: true,
      result: {'schemaVersion': '1.0'},
    );
  }

  @override
  Future<void> resumeLogin(String jobId, {String? password}) async {}

  @override
  Future<void> cancel(String jobId) async {}

  @override
  Future<void> shutdown() async {}
}

Future<_RealInteractiveFixture> _realInteractiveFixture(
  AppDatabase database,
  AccountService accounts,
) async {
  final accountId = await accounts.persistVerifiedAccount(
    username: 'PB00000000',
    password: 'saved-password',
    savePassword: true,
  );
  final bridge = _GatedInteractiveBridge();
  final coordinator = SyncCoordinator(
    database: database,
    accounts: accounts,
    bridgeFactory: () async => bridge,
    importBundle: (bytes, {required accountId, required origin}) async =>
        const ImportResult(
          status: ImportStatus.imported,
          bundleId: 'test',
          source: 'ustc_jw',
          importedEntityCount: 1,
        ),
  );
  return _RealInteractiveFixture(
    database: database,
    accountId: accountId,
    bridge: bridge,
    gateway: SourceJobGatewayAdapter(
      coordinator: coordinator,
      arbiter: JwJobArbiter(),
      bridge: bridge,
    ),
  );
}

final class _GatedInteractiveBridge implements BridgeGateway {
  final cancelGate = Completer<void>();
  final resumePollGate = Completer<void>();
  final resumeStarted = Completer<void>();
  var _pausedPollReturned = false;
  var cancelCalls = 0;
  var resumeCalls = 0;

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
  }) async => const BridgeJob(id: 'gated-job', phase: 'starting');

  @override
  Future<BridgeJobPoll> poll(String jobId, int after) async {
    if (!_pausedPollReturned) {
      _pausedPollReturned = true;
      return const BridgeJobPoll(
        events: [
          {'sequence': 1, 'phase': 'needs_user_login'},
        ],
        nextSequence: 1,
        terminal: false,
      );
    }
    await resumePollGate.future;
    return const BridgeJobPoll(
      events: [
        {'sequence': 2, 'phase': 'cancelled'},
      ],
      nextSequence: 2,
      terminal: true,
      errorCode: 'cancelled',
    );
  }

  @override
  Future<void> resumeLogin(String jobId, {String? password}) async {
    resumeCalls++;
    if (!resumeStarted.isCompleted) resumeStarted.complete();
  }

  @override
  Future<void> cancel(String jobId) async {
    cancelCalls++;
    if (!resumePollGate.isCompleted) resumePollGate.complete();
    await cancelGate.future;
  }

  @override
  Future<void> shutdown() async {}
}

final class _ClosedFallbackBridge implements BridgeGateway {
  var shutdownCalls = 0;
  var _closed = false;

  @override
  Future<BridgeCapabilities> capabilities() async {
    _checkOpen();
    throw UnimplementedError();
  }

  @override
  Future<BridgeJob> startCollection({
    required SyncSource source,
    required String accountId,
    required String expectedUsername,
    required BridgeSemesterCapability jwSemester,
  }) async {
    _checkOpen();
    throw UnimplementedError();
  }

  @override
  Future<BridgeJobPoll> poll(String jobId, int after) async {
    _checkOpen();
    throw UnimplementedError();
  }

  @override
  Future<void> resumeLogin(String jobId, {String? password}) async {
    _checkOpen();
    throw UnimplementedError();
  }

  @override
  Future<void> cancel(String jobId) async {
    _checkOpen();
    throw UnimplementedError();
  }

  @override
  Future<void> shutdown() async {
    shutdownCalls++;
    _closed = true;
  }

  void _checkOpen() {
    if (_closed) throw StateError('bridge is closed');
  }
}

final class _GatedShutdownBridge implements BridgeGateway {
  _GatedShutdownBridge({this.throwOnShutdown = false});

  final bool throwOnShutdown;
  final shutdownGate = Completer<void>();
  final shutdownStarted = Completer<void>();
  var shutdownCalls = 0;
  var _closed = false;

  @override
  Future<BridgeCapabilities> capabilities() async {
    _checkOpen();
    return const BridgeCapabilities(
      jwSemester: BridgeSemesterCapability(
        semesterId: 461,
        semesterKey: '2026fall',
        displayName: '2026 秋季学期',
      ),
    );
  }

  @override
  Future<BridgeJob> startCollection({
    required SyncSource source,
    required String accountId,
    required String expectedUsername,
    required BridgeSemesterCapability jwSemester,
  }) async {
    _checkOpen();
    return const BridgeJob(id: 'gated-shutdown-job', phase: 'starting');
  }

  @override
  Future<BridgeJobPoll> poll(String jobId, int after) async {
    _checkOpen();
    return const BridgeJobPoll(
      events: [
        {'sequence': 1, 'phase': 'complete'},
      ],
      nextSequence: 1,
      terminal: true,
      result: {'schemaVersion': '1.0'},
    );
  }

  @override
  Future<void> resumeLogin(String jobId, {String? password}) async {
    _checkOpen();
  }

  @override
  Future<void> cancel(String jobId) async {
    _checkOpen();
  }

  @override
  Future<void> shutdown() async {
    shutdownCalls++;
    if (!shutdownStarted.isCompleted) shutdownStarted.complete();
    await shutdownGate.future;
    _closed = true;
    if (throwOnShutdown) throw StateError('private-cleanup-failure');
  }

  void _checkOpen() {
    if (_closed) throw StateError('bridge is closed');
  }
}

class _TrackingBridge implements BridgeGateway {
  _TrackingBridge({this.throwOnCancel = false, this.throwOnShutdown = false});

  final bool throwOnCancel;
  final bool throwOnShutdown;
  var cancelCalls = 0;
  var shutdownCalls = 0;

  @override
  Future<BridgeCapabilities> capabilities() => throw UnimplementedError();

  @override
  Future<BridgeJob> startCollection({
    required SyncSource source,
    required String accountId,
    required String expectedUsername,
    required BridgeSemesterCapability jwSemester,
  }) => throw UnimplementedError();

  @override
  Future<BridgeJobPoll> poll(String jobId, int after) =>
      throw UnimplementedError();

  @override
  Future<void> resumeLogin(String jobId, {String? password}) async {}

  @override
  Future<void> cancel(String jobId) async {
    cancelCalls++;
    if (throwOnCancel) throw const BridgeProtocolError('bridge_busy');
  }

  @override
  Future<void> shutdown() async {
    shutdownCalls++;
    if (throwOnShutdown) throw const BridgeProtocolError('request_failed');
  }
}

final class _AdmissionTrackingBridge extends _TrackingBridge
    implements BridgeAdmissionCancellation {
  var cancelAdmissionCalls = 0;

  @override
  Future<void> cancelAdmission() async {
    cancelAdmissionCalls++;
    await shutdown();
  }
}
