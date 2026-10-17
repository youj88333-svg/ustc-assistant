import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/settings_contract.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/jobs/application_maintenance_coordinator.dart';

const _context = SettingsContext(
  owner: 'synthetic-owner',
  resetEpoch: 3,
  agendaEpoch: 4,
  revision: 2,
);

void main() {
  test(
    'retired browser cleanup is independent and acquires the C2 lease',
    () async {
      final data = _Data();
      final leases = WorkLeasePool();
      var pendingCount = 2;
      var retries = 0;
      final runner = ApplicationMaintenanceCoordinator(
        data: data,
        leases: leases,
        cleanProfiles: (_) async {},
        drainForExit: () async {},
        readBrowserCleanupPendingCount: () async => pendingCount,
        retryBrowserCleanup: (lease) async {
          expect(lease.isHeld, isTrue);
          expect(lease.belongsTo(leases), isTrue);
          retries++;
          pendingCount = 0;
          return pendingCount;
        },
      );

      expect(await runner.browserCleanupPendingCount(), 2);
      final schoolOrModelWork = leases.acquire();
      await expectLater(
        runner.retryRetiredBrowserCleanup(),
        throwsA(_failure(SettingsFailureCode.busy)),
      );
      expect(retries, 0);
      schoolOrModelWork.release();

      expect(await runner.retryRetiredBrowserCleanup(), 0);
      expect(retries, 1);
      expect(runner.view.phase, MaintenancePhase.idle);
      expect(leases.isBusy, isFalse);
      await runner.close();
    },
  );

  test(
    'Android durable block precedes intent and remains through cleanup',
    () async {
      final data = _Data();
      final runner = _runner(data, WorkLeasePool());
      var blocked = false;
      runner.prepareReminders = () async {
        expect(data.begins, 0);
        blocked = true;
      };
      data.beforeBegin = () {
        expect(blocked, isTrue);
      };
      runner.drainReminders = () async {
        expect(blocked, isTrue);
        expect(data.pending, isNotNull);
      };
      runner.onRefresh = (_) async {
        expect(data.pending, isNull);
        blocked = false;
      };
      await runner.start(_context, MaintenanceKind.agenda, confirmed: true);
      expect(runner.view.phase, MaintenancePhase.idle);
      expect(blocked, isFalse);
      await runner.close();
    },
  );
  test(
    'failed preblock never starts intent and confirmed abort rebinds C3',
    () async {
      final data = _Data();
      final leases = WorkLeasePool();
      final runner = _runner(data, leases);
      var restored = 0;
      runner.prepareReminders = () async {
        throw const AppFailure(FailureCode.cleanupPending);
      };
      runner.resumeRemindersAfterAbort = () async {
        expect(data.pending, isNull);
        restored++;
      };
      await expectLater(
        runner.start(_context, MaintenanceKind.agenda, confirmed: true),
        throwsA(isA<SettingsFailure>()),
      );
      expect(data.begins, 0);
      expect(restored, 1);
      expect(leases.isBusy, isFalse);
      await runner.close();
    },
  );
  test(
    'unknown intent outcome stays blocked until no-intent retry restores',
    () async {
      final data = _Data();
      final leases = WorkLeasePool();
      final runner = _runner(data, leases);
      var restored = 0;
      runner.prepareReminders = () async {};
      runner.resumeRemindersAfterAbort = () async {
        restored++;
      };
      data.beforeBegin = () {
        data.badMetadata = true;
        throw const SettingsFailure(SettingsFailureCode.storageFailed);
      };
      await runner.start(_context, MaintenanceKind.agenda, confirmed: true);
      expect(runner.view.phase, MaintenancePhase.recovery);
      expect(restored, 0);
      expect(leases.isBusy, isTrue);
      data.badMetadata = false;
      await runner.retry();
      expect(restored, 1);
      expect(runner.view.phase, MaintenancePhase.idle);
      expect(leases.isBusy, isFalse);
      await runner.close();
    },
  );
  test(
    'abort rebind failure preserves recovery and retries without deletion',
    () async {
      final data = _Data();
      final leases = WorkLeasePool();
      final runner = _runner(data, leases);
      var attempts = 0;
      runner.prepareReminders = () async {};
      runner.resumeRemindersAfterAbort = () async {
        if (++attempts == 1) {
          throw const SettingsFailure(SettingsFailureCode.cleanupPending);
        }
      };
      data.beforeBegin = () {
        throw const SettingsFailure(SettingsFailureCode.storageFailed);
      };
      await runner.start(_context, MaintenanceKind.agenda, confirmed: true);
      expect(runner.view.phase, MaintenancePhase.recovery);
      expect(leases.isBusy, isTrue);
      await runner.retry();
      expect(attempts, 2);
      expect(data.completes, 0);
      expect(runner.view.phase, MaintenancePhase.idle);
      await runner.close();
    },
  );
  test(
    'source busy and rejected confirmation cannot prepare durable intent',
    () async {
      final data = _Data();
      final leases = WorkLeasePool();
      final source = leases.acquire();
      final runner = _runner(data, leases);
      await expectLater(
        runner.start(_context, MaintenanceKind.reset, confirmed: true),
        throwsA(_failure(SettingsFailureCode.busy)),
      );
      expect(data.prepares, 0);
      expect(data.begins, 0);
      expect(runner.view.phase, MaintenancePhase.idle);
      expect(source.isHeld, isTrue);
      expect(
        () => runner.start(_context, MaintenanceKind.reset, confirmed: false),
        throwsA(_failure(SettingsFailureCode.confirmationRequired)),
      );
      source.release();
      await runner.close();
    },
  );

  test(
    'cleanup failure retains same intent and lease until retry commits',
    () async {
      final data = _Data();
      final leases = WorkLeasePool();
      var cleans = 0;
      final runner = _runner(
        data,
        leases,
        clean: (lease) async {
          expect(lease.isHeld, isTrue);
          expect(lease.belongsTo(leases), isTrue);
          if (++cleans == 1) {
            throw const AppFailure(FailureCode.cleanupPending);
          }
        },
      );
      await runner.start(_context, MaintenanceKind.reset, confirmed: true);
      final pending = data.pending!;
      expect(runner.view.phase, MaintenancePhase.recovery);
      expect(runner.view.failure, SettingsFailureCode.cleanupPending);
      expect(leases.isBusy, isTrue);
      expect(data.completes, 0);
      await runner.retry();
      expect(data.prepares, 1);
      expect(data.begins, 1);
      expect(data.completes, 1);
      expect(data.lastCompleted, same(pending));
      expect(cleans, 2);
      expect(runner.view.phase, MaintenancePhase.idle);
      expect(leases.isBusy, isFalse);
      await runner.close();
    },
  );

  test(
    'final SQL failure retries the same epochs and agenda never cleans profiles',
    () async {
      final data = _Data()..failComplete = true;
      final leases = WorkLeasePool();
      var cleans = 0;
      final runner = _runner(
        data,
        leases,
        clean: (_) async {
          cleans++;
        },
      );
      await runner.start(_context, MaintenanceKind.agenda, confirmed: true);
      final target = data.pending!.targetContext;
      expect(runner.view.phase, MaintenancePhase.recovery);
      expect(data.pending, isNotNull);
      data.failComplete = false;
      await runner.retry();
      expect(data.begins, 1);
      expect(data.completes, 2);
      expect(cleans, 0);
      expect(data.context.resetEpoch, _context.resetEpoch);
      expect(data.context.agendaEpoch, target.agendaEpoch);
      await runner.close();
    },
  );

  test(
    'postcommit refresh failure retries only reads and releases after refresh',
    () async {
      final data = _Data();
      final leases = WorkLeasePool();
      var reads = 0, cleans = 0;
      final runner = _runner(
        data,
        leases,
        clean: (_) async {
          cleans++;
        },
      );
      runner.onRefresh = (kind) async {
        expect(kind, MaintenanceKind.reset);
        if (++reads == 1) {
          throw StateError('synthetic refresh fault');
        }
      };
      await runner.start(_context, MaintenanceKind.reset, confirmed: true);
      expect(data.pending, isNull);
      expect(data.completes, 1);
      expect(cleans, 1);
      expect(runner.view.committed, isTrue);
      final committed = data.context;
      expect(runner.view.phase, MaintenancePhase.recovery);
      expect(leases.isBusy, isTrue);
      await runner.retry();
      expect(reads, 2);
      expect(cleans, 1);
      expect(data.completes, 1);
      expect(data.context, committed);
      expect(runner.view.phase, MaintenancePhase.idle);
      expect(leases.isBusy, isFalse);
      await runner.close();
    },
  );

  test(
    'checked exit retains disk intent for next bootstrap but fails on undrained native resources',
    () async {
      final data = _Data();
      final firstLeases = WorkLeasePool();
      var drains = 0;
      final first = _runner(
        data,
        firstLeases,
        clean: (_) async {
          throw const AppFailure(FailureCode.cleanupPending);
        },
        drain: () async {
          if (++drains == 1) {
            throw const AppFailure(FailureCode.cleanupPending);
          }
        },
      );
      await first.start(_context, MaintenanceKind.reset, confirmed: true);
      final pending = data.pending!;
      await expectLater(first.close(), throwsA(isA<AppFailure>()));
      expect(first.isClosed, isFalse);
      expect(firstLeases.isBusy, isTrue);
      expect(data.pending, same(pending));
      await first.close();
      await first.close();
      expect(firstLeases.isBusy, isFalse);
      expect(data.pending, same(pending));
      expect(drains, 2, reason: 'Successful close is idempotent.');
      final secondLeases = WorkLeasePool();
      final second = _runner(data, secondLeases);
      await second.restorePending();
      expect(data.begins, 1);
      expect(data.completes, 1);
      expect(data.lastCompleted, same(pending));
      expect(second.view.phase, MaintenancePhase.idle);
      await second.close();
    },
  );

  test(
    'unknown bootstrap state stays gated and never invokes deletion',
    () async {
      final data = _Data()..badMetadata = true;
      final leases = WorkLeasePool();
      var cleans = 0;
      final runner = _runner(
        data,
        leases,
        clean: (_) async {
          cleans++;
        },
      );
      await runner.restorePending();
      await runner.retry();
      expect(runner.view.phase, MaintenancePhase.recovery);
      expect(runner.view.failure, SettingsFailureCode.invalidIntent);
      expect(data.begins, 0);
      expect(data.completes, 0);
      expect(cleans, 0);
      expect(leases.isBusy, isTrue);
      await runner.close();
    },
  );

  test(
    'concurrent retry and exit cannot admit new maintenance before drain',
    () async {
      final data = _Data();
      final leases = WorkLeasePool();
      final entered = Completer<void>(), drained = Completer<void>();
      final runner = _runner(
        data,
        leases,
        drain: () async {
          entered.complete();
          await drained.future;
        },
      );
      final closing = runner.close();
      await entered.future;
      expect(
        () => runner.start(_context, MaintenanceKind.agenda, confirmed: true),
        throwsA(_failure(SettingsFailureCode.closed)),
      );
      expect(data.begins, 0);
      drained.complete();
      await closing;
    },
  );
}

Matcher _failure(SettingsFailureCode code) =>
    isA<SettingsFailure>().having((e) => e.code, 'code', code);

ApplicationMaintenanceCoordinator _runner(
  _Data data,
  WorkLeasePool leases, {
  Future<void> Function(WorkLease)? clean,
  Future<void> Function()? drain,
}) => ApplicationMaintenanceCoordinator(
  data: data,
  leases: leases,
  cleanProfiles: clean ?? (_) async {},
  drainForExit: drain ?? () async {},
);

final class _Data implements ApplicationSettingsDataPort {
  SettingsContext context = _context;
  MaintenanceIntent? pending, lastCompleted;
  int prepares = 0, begins = 0, completes = 0;
  bool failComplete = false, badMetadata = false;
  void Function()? beforeBegin;
  @override
  Stream<int> get changes => const Stream.empty();
  @override
  Future<MaintenanceIntent?> bootstrapMaintenance() async {
    if (badMetadata) {
      throw const SettingsFailure(SettingsFailureCode.invalidIntent);
    }
    return pending;
  }

  @override
  Future<SettingsSnapshot> inspectSettings() async => SettingsSnapshot(
    context: context,
    preferences: const DisplayPreferences(),
    counts: const LocalDataCounts(),
    accountBound: false,
    credentialSaved: false,
    icourseConsent: false,
  );
  @override
  Future<SettingsWriteReceipt> savePreferences(PreferencesWrite write) async =>
      throw UnimplementedError();
  @override
  Future<MaintenanceRequest> prepareMaintenance(
    SettingsContext expected,
    MaintenanceKind kind, {
    required bool confirmed,
  }) async {
    if (!confirmed || expected != context) {
      throw const SettingsFailure(SettingsFailureCode.staleContext);
    }
    prepares++;
    return MaintenanceRequest(
      operationId: 'synthetic-maintenance-$prepares',
      context: context,
      kind: kind,
      intentFingerprint: 'synthetic-fixed-${kind.name}',
    );
  }

  @override
  Future<MaintenanceIntent> beginMaintenance(MaintenanceRequest request) async {
    begins++;
    beforeBegin?.call();
    context = SettingsContext(
      owner: context.owner,
      resetEpoch:
          context.resetEpoch + (request.kind == MaintenanceKind.reset ? 1 : 0),
      agendaEpoch: context.agendaEpoch + 1,
      revision: context.revision,
    );
    return pending = MaintenanceIntent(
      request: request,
      targetContext: context,
    );
  }

  @override
  Future<SettingsWriteReceipt> completeMaintenance(
    MaintenanceIntent intent,
  ) async {
    completes++;
    if (failComplete) {
      throw const SettingsFailure(SettingsFailureCode.storageFailed);
    }
    lastCompleted = intent;
    pending = null;
    context = SettingsContext(
      owner: context.owner,
      resetEpoch: context.resetEpoch,
      agendaEpoch: context.agendaEpoch,
      revision: context.revision + 1,
    );
    return SettingsWriteReceipt(
      operationId: intent.request.operationId,
      context: context,
    );
  }
}
