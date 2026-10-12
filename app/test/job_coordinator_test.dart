import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/data/demo_store.dart';
import 'package:ustc_assistant_m0/data/import_contract.dart';
import 'package:ustc_assistant_m0/jobs/coordinator_contract.dart';
import 'package:ustc_assistant_m0/jobs/job_coordinator.dart';
import 'package:ustc_assistant_m0/source/source_contract.dart';
import 'package:ustc_assistant_m0/source/synthetic_source.dart';

final _clock = FixedClock(DateTime.utc(2026, 10, 9, 12));
const _timeout = Duration(seconds: 5);

void main() {
  test(
    'observation and synthetic work share a lease through failed cleanup',
    () async {
      final leases = WorkLeasePool();
      final source = _ObservedSource();
      final harness = await _harness(source: source, leases: leases);
      final observation = leases.acquire();
      await expectLater(
        harness.coordinator.run(DemoScenario.normal),
        throwsA(_failure(FailureCode.busy)),
      );
      await expectLater(
        harness.coordinator.retryFollowUps(),
        throwsA(_failure(FailureCode.busy)),
      );
      expect(source.opens, 0);
      observation.release();
      await harness.coordinator.run(DemoScenario.cleanupFailure);
      expect(leases.isBusy, isTrue);
      expect(leases.acquire, throwsA(_failure(FailureCode.busy)));
      await harness.coordinator.retryRecovery();
      expect(leases.isBusy, isFalse);
    },
  );
  test(
    'a lease is acquired synchronously and a second run cannot open a source',
    () async {
      final gate = _Gate();
      final source = _ObservedSource(beforeSeal: gate.wait);
      final harness = await _harness(source: source);
      addTearDown(gate.release);

      final first = harness.coordinator.run(DemoScenario.normal);
      expect(harness.coordinator.view.phase, JobPhase.collecting);
      expect(harness.coordinator.view.isBusy, isTrue);
      await expectLater(
        harness.coordinator.run(DemoScenario.normal),
        throwsA(_failure(FailureCode.busy)),
      );
      await gate.entered.future.timeout(_timeout);
      expect(source.opens, 1);
      _expectNoImport(await harness.store.readView());

      gate.release();
      final outcome = await first.timeout(_timeout);
      expect(outcome.kind, OutcomeKind.committed);
      expect(outcome.followUpPending, isFalse);
      expect(harness.coordinator.view.phase, JobPhase.idle);
      expect(source.closeAttempts, 1);
      expect(source.closedSessions, 1);
      _expectCommitted(await harness.store.readView(), pending: 0);
    },
  );

  test(
    'cancel accepted before sealing prevents import and repeated cancel agrees',
    () async {
      final gate = _Gate();
      final source = _ObservedSource(beforeSeal: gate.wait);
      final harness = await _harness(source: source);
      addTearDown(gate.release);
      final running = harness.coordinator.run(DemoScenario.normal);
      await gate.entered.future.timeout(_timeout);

      final first = harness.coordinator.cancel();
      final repeated = harness.coordinator.cancel();
      expect(await first.timeout(_timeout), CancellationDisposition.cancelled);
      expect(
        await repeated.timeout(_timeout),
        CancellationDisposition.cancelled,
      );
      expect(harness.coordinator.view.cancelRequested, isTrue);
      _expectNoImport(await harness.store.readView());
      gate.release();

      final outcome = await running.timeout(_timeout);
      expect(outcome.kind, OutcomeKind.cancelled);
      expect(outcome.failure, isNull);
      expect(harness.coordinator.view.phase, JobPhase.idle);
      expect(source.closedSessions, 1);
      _expectNoImport(await harness.store.readView());
      expect(
        await harness.coordinator.cancel(),
        CancellationDisposition.notActive,
      );
      final next = await harness.coordinator.run(DemoScenario.normal);
      expect(next.kind, OutcomeKind.committed);
      _expectCommitted(await harness.store.readView(), pending: 0);
    },
  );

  test(
    'cancel after commit preserves the receipt and a stored follow-up survives coordinator replacement',
    () async {
      final gate = _Gate();
      final source = _ObservedSource();
      final harness = await _harness(source: source, afterCommit: gate.wait);
      addTearDown(gate.release);
      final running = harness.coordinator.run(DemoScenario.normal);
      await gate.entered.future.timeout(_timeout);
      expect(source.closedSessions, 1);
      _expectCommitted(await harness.store.readView(), pending: 1);

      expect(
        await harness.coordinator.cancel(),
        CancellationDisposition.alreadyCommitted,
      );
      expect(
        await harness.coordinator.cancel(),
        CancellationDisposition.alreadyCommitted,
      );
      gate.release();
      final outcome = await running.timeout(_timeout);
      expect(outcome.kind, OutcomeKind.committed);
      expect(outcome.recordCount, 3);
      expect(outcome.followUpPending, isTrue);
      expect(outcome.failure, FailureCode.followUpPending);
      expect(harness.coordinator.view.phase, JobPhase.idle);
      _expectCommitted(await harness.store.readView(), pending: 1);

      await harness.coordinator.close();
      final replacement = JobCoordinator(
        store: harness.store,
        source: source,
        followUpDelay: Duration.zero,
      );
      addTearDown(replacement.close);
      await replacement.retryFollowUps();
      expect(replacement.view.phase, JobPhase.idle);
      _expectCommitted(await harness.store.readView(), pending: 0);
    },
  );

  test(
    'a failed cleanup retains the lease and retries before any import',
    () async {
      final source = _ObservedSource();
      final harness = await _harness(source: source);
      final failed = await harness.coordinator.run(DemoScenario.cleanupFailure);
      expect(failed.kind, OutcomeKind.failed);
      expect(failed.failure, FailureCode.cleanupPending);
      expect(harness.coordinator.view.phase, JobPhase.recovery);
      expect(harness.coordinator.view.isBusy, isTrue);
      expect(source.closeAttempts, 1);
      expect(source.closedSessions, 0);
      final busyDuringRecovery = expectLater(
        harness.coordinator.run(DemoScenario.normal),
        throwsA(_failure(FailureCode.busy)),
      );
      // Queue a database read before retry without yielding; it observes the
      // recovery state before a retry can enqueue its first import transaction.
      final beforeRetry = harness.store.readView();
      // Retry is a public action available as soon as run exposes recovery.
      final recovering = harness.coordinator.retryRecovery();
      _expectNoImport(await beforeRetry);
      await busyDuringRecovery;
      final recovered = await recovering.timeout(_timeout);
      expect(recovered.kind, OutcomeKind.committed);
      expect(source.closeAttempts, 2);
      expect(source.closedSessions, 1);
      expect(harness.coordinator.view.phase, JobPhase.idle);
      _expectCommitted(await harness.store.readView(), pending: 0);
    },
  );

  test(
    'source, incomplete and real SQL failures return idle with zero imported projections',
    () async {
      final source = _ObservedSource();
      final harness = await _harness(source: source);
      for (final entry in {
        DemoScenario.sourceFailure: FailureCode.sourceFailed,
        DemoScenario.incomplete: FailureCode.incompleteSnapshot,
        DemoScenario.storageFailure: FailureCode.storageFailed,
      }.entries) {
        final outcome = await harness.coordinator
            .run(entry.key)
            .timeout(_timeout);
        expect(outcome.kind, OutcomeKind.failed);
        expect(outcome.failure, entry.value);
        expect(outcome.followUpPending, isFalse);
        expect(harness.coordinator.view.phase, JobPhase.idle);
        _expectNoImport(await harness.store.readView());
      }
      expect(source.opens, 3);
      expect(source.closeAttempts, 3);
      expect(source.closedSessions, 3);
      final recovered = await harness.coordinator.run(DemoScenario.normal);
      expect(recovered.kind, OutcomeKind.committed);
      _expectCommitted(await harness.store.readView(), pending: 0);
    },
  );

  test(
    'follow-up failure keeps a committed import and retry clears only its pending work',
    () async {
      final harness = await _harness();
      final outcome = await harness.coordinator.run(
        DemoScenario.followUpFailure,
      );
      expect(outcome.kind, OutcomeKind.committed);
      expect(outcome.recordCount, 3);
      expect(outcome.followUpPending, isTrue);
      expect(outcome.failure, FailureCode.followUpPending);
      expect(harness.coordinator.view.phase, JobPhase.idle);
      final before = await harness.store.readView();
      _expectCommitted(before, pending: 1);

      await harness.coordinator.retryFollowUps();
      expect(harness.coordinator.view.phase, JobPhase.idle);
      expect(harness.coordinator.view.outcome!.kind, OutcomeKind.committed);
      expect(harness.coordinator.view.outcome!.followUpPending, isFalse);
      final after = await harness.store.readView();
      _expectCommitted(after, pending: 0);
      expect(
        after.events.map((event) => event.localId),
        before.events.map((event) => event.localId),
      );
      await harness.coordinator.retryFollowUps();
      _expectCommitted(await harness.store.readView(), pending: 0);
    },
  );
}

Future<_Harness> _harness({
  WorkLeasePool? leases,
  _ObservedSource? source,
  Future<void> Function()? afterCommit,
}) async {
  final observed = source ?? _ObservedSource();
  final store = DemoStore(
    NativeDatabase.memory(),
    ownership: const _HeldOwnership(),
    clock: _clock,
    onCheckpoint: (checkpoint) async {
      if (checkpoint == ImportCheckpoint.afterFirstWrite) {
        // Imported writes require a successfully closed collection session.
        expect(observed.closedSessions, observed.opens);
      }
    },
  );
  addTearDown(store.close);
  await store.initialize();
  final coordinator = JobCoordinator(
    store: store,
    source: observed,
    followUpDelay: Duration.zero,
    afterCommit: afterCommit,
    leases: leases,
  );
  addTearDown(coordinator.close);
  return _Harness(store, coordinator);
}

final class _Harness {
  const _Harness(this.store, this.coordinator);
  final DemoStore store;
  final JobCoordinator coordinator;
}

final class _HeldOwnership implements AssetOwnership {
  const _HeldOwnership();
  @override
  bool get isHeld => true;
  @override
  void ensureHeld() {}
}

final class _Gate {
  final entered = Completer<void>();
  final _released = Completer<void>();
  Future<void> wait() async {
    if (!entered.isCompleted) entered.complete();
    await _released.future;
  }

  void release() {
    if (!_released.isCompleted) _released.complete();
  }
}

/// Controls source timing while keeping real C1 sealing and session cleanup.
final class _ObservedSource implements SourcePort {
  _ObservedSource({Future<void> Function()? beforeSeal})
    : _source = SyntheticSource(
        clock: _clock,
        delay: Duration.zero,
        beforeSeal: beforeSeal,
      );
  final SyntheticSource _source;
  int opens = 0;
  int closeAttempts = 0;
  int closedSessions = 0;
  @override
  Future<SourceSession> open(JobStamp stamp, DemoScenario scenario) async {
    opens++;
    return _ObservedSession(await _source.open(stamp, scenario), this);
  }
}

final class _ObservedSession implements SourceSession {
  _ObservedSession(this._session, this._owner);
  final SourceSession _session;
  final _ObservedSource _owner;
  bool _closed = false;
  @override
  Future<CollectionArtifact> collect() => _session.collect();
  @override
  Future<void> close() async {
    _owner.closeAttempts++;
    await _session.close();
    if (!_closed) {
      _closed = true;
      _owner.closedSessions++;
    }
  }
}

Matcher _failure(FailureCode code) =>
    isA<AppFailure>().having((value) => value.code, 'stable failure', code);

void _expectNoImport(DemoDataView view) {
  expect(view.events, isEmpty);
  expect(view.importCount, 0);
  expect(view.auditCount, 0);
  expect(view.pendingFollowUps, 0);
}

void _expectCommitted(DemoDataView view, {required int pending}) {
  expect(view.events, hasLength(3));
  expect(view.importCount, 1);
  expect(view.auditCount, 1);
  expect(view.pendingFollowUps, pending);
}
