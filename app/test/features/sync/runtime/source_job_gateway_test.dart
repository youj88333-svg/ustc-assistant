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
