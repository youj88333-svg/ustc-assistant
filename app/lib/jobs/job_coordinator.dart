import 'dart:async';

import '../core/contracts.dart';
import '../core/work_lease.dart';
import '../data/demo_store.dart';
import '../data/import_contract.dart';
import '../source/source_contract.dart';
import 'coordinator_contract.dart';

/// One active lease across collection, cleanup, commit and optional follow-up.
final class JobCoordinator implements CoordinatorPort {
  JobCoordinator({
    required this.store,
    required this.source,
    this.followUpDelay = const Duration(milliseconds: 250),
    this.afterCommit,
    WorkLeasePool? leases,
  }) : leases = leases ?? WorkLeasePool();

  final DemoStore store;
  final SourcePort source;
  final Duration followUpDelay;
  final Future<void> Function()? afterCommit;
  final WorkLeasePool leases;
  WorkLease? _lease;
  final _changes = StreamController<CoordinatorView>.broadcast();
  CoordinatorView _view = const CoordinatorView(
    phase: JobPhase.idle,
    sequence: 0,
  );
  _ActiveJob? _active;
  Future<void>? _work;
  Future<void>? _closeFuture;
  bool _closing = false;

  @override
  CoordinatorView get view => _view;
  @override
  Stream<CoordinatorView> get changes => _changes.stream;

  void _publish(JobPhase phase, {JobOutcome? outcome}) {
    _view = CoordinatorView(
      phase: phase,
      sequence: _view.sequence + 1,
      cancelRequested: _active?.cancelRequested ?? false,
      outcome: outcome,
    );
    _changes.add(_view);
  }

  void _requireIdle() {
    if (_closing || view.phase == JobPhase.closed) {
      throw const AppFailure(FailureCode.closed);
    }
    if (view.phase != JobPhase.idle) throw const AppFailure(FailureCode.busy);
  }

  @override
  Future<JobOutcome> run(DemoScenario scenario) {
    try {
      _requireIdle();
      _lease = leases.acquire();
    } on AppFailure catch (failure) {
      return Future.error(failure);
    }
    final job = _ActiveJob(scenario);
    _active = job;
    // Acquire before the first await, including before the database is opened.
    _publish(JobPhase.collecting);
    return _launch(() => _collect(job));
  }

  Future<JobOutcome> _launch(Future<JobOutcome> Function() action) {
    final done = Completer<void>();
    _work = done.future;
    return () async {
      try {
        return await action();
      } finally {
        if (identical(_work, done.future)) _work = null;
        done.complete();
      }
    }();
  }

  Future<JobOutcome> _collect(_ActiveJob job) async {
    try {
      job.stamp = await store.beginJob();
      job.ready.complete(job.stamp);
      if (job.cancelRequested) await _cancel(job);
      if (job.cancelResult != CancellationDisposition.cancelled &&
          job.scenario != DemoScenario.replay) {
        job.session = await source.open(job.stamp!, job.scenario);
        job.artifact = await job.session!.collect();
      }
    } catch (error) {
      if (!job.ready.isCompleted) job.ready.complete(null);
      job.failure = error is AppFailure ? error.code : FailureCode.sourceFailed;
    }
    return _settle(job);
  }

  Future<JobOutcome> _settle(_ActiveJob job) async {
    _publish(JobPhase.settling);
    try {
      await job.session?.close();
      job.session = null;
    } catch (_) {
      final outcome = const JobOutcome(
        kind: OutcomeKind.failed,
        failure: FailureCode.cleanupPending,
      );
      // Keep session and lease. No import can occur before successful drain.
      _publish(JobPhase.recovery, outcome: outcome);
      return outcome;
    }

    ImportReceipt? receipt;
    try {
      if (job.cancelRequested) await _cancel(job);
      if (job.cancelResult == CancellationDisposition.cancelled) {
        return _finish(const JobOutcome(kind: OutcomeKind.cancelled));
      }
      if (job.failure != null) throw AppFailure(job.failure!);
      if (job.scenario == DemoScenario.replay) {
        receipt = await store.replayLatest(job.stamp!);
      } else {
        final artifact = job.artifact!;
        receipt = await store.importSnapshot(
          ImportRequest(
            stamp: artifact.stamp,
            operationId: job.stamp!.jobId,
            rangeStartUtc: artifact.rangeStartUtc,
            rangeEndUtc: artifact.rangeEndUtc,
            collectedAtUtc: artifact.collectedAtUtc,
            contentFingerprint: artifact.contentFingerprint,
            events: artifact.events
                .map(
                  (event) => EventDraft(
                    externalId: event.externalId,
                    title: event.title,
                    startsAtUtc: event.startsAtUtc,
                    endsAtUtc: event.endsAtUtc,
                  ),
                )
                .toList(),
          ),
          simulateSqlFailure: job.scenario == DemoScenario.storageFailure,
        );
      }
      // From here onward failure or cancellation cannot undo the receipt.
      await afterCommit?.call();
      await Future<void>.delayed(followUpDelay);
      if (job.cancelRequested) await _cancel(job);
      if (job.scenario == DemoScenario.followUpFailure || job.cancelRequested) {
        return _finish(_committed(receipt, receipt.followUpPending));
      }
      await store.completeFollowUp(receipt.operationId);
      return _finish(_committed(receipt, false));
    } catch (error) {
      if (receipt != null) return _finish(_committed(receipt, true));
      final code = error is AppFailure ? error.code : FailureCode.storageFailed;
      if (job.stamp != null) {
        try {
          await store.finishFailed(job.stamp!);
        } catch (_) {
          return _finish(
            const JobOutcome(
              kind: OutcomeKind.failed,
              failure: FailureCode.storageFailed,
            ),
          );
        }
      }
      return _finish(
        JobOutcome(
          kind: code == FailureCode.cancelled
              ? OutcomeKind.cancelled
              : OutcomeKind.failed,
          failure: code == FailureCode.cancelled ? null : code,
        ),
      );
    }
  }

  JobOutcome _committed(ImportReceipt receipt, bool pending) => JobOutcome(
    kind: OutcomeKind.committed,
    recordCount: receipt.recordCount,
    replayed: receipt.replayed,
    followUpPending: pending,
    failure: pending ? FailureCode.followUpPending : null,
  );

  JobOutcome _finish(JobOutcome outcome) {
    _active = null;
    _lease?.release();
    _lease = null;
    _publish(JobPhase.idle, outcome: outcome);
    return outcome;
  }

  Future<CancellationDisposition> _cancel(_ActiveJob job) =>
      job.cancellation ??= () async {
        final stamp = await job.ready.future;
        final result = stamp == null
            ? CancellationDisposition.notActive
            : await store.cancelJob(stamp);
        job.cancelResult = result;
        return result;
      }();

  @override
  Future<CancellationDisposition> cancel() {
    final job = _active;
    if (job == null) return Future.value(CancellationDisposition.notActive);
    job.cancelRequested = true;
    _publish(view.phase, outcome: view.outcome);
    return _cancel(job);
  }

  @override
  Future<JobOutcome> retryRecovery() {
    if (view.phase != JobPhase.recovery || _active == null || _work != null) {
      return Future.error(const AppFailure(FailureCode.busy));
    }
    return _launch(() => _settle(_active!));
  }

  @override
  Future<void> retryFollowUps() async {
    _requireIdle();
    _lease = leases.acquire();
    _publish(JobPhase.settling);
    final work = store.completePendingFollowUps();
    _work = work.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    try {
      await work;
      _publish(
        JobPhase.idle,
        outcome: const JobOutcome(kind: OutcomeKind.committed),
      );
    } catch (_) {
      _publish(
        JobPhase.idle,
        outcome: const JobOutcome(
          kind: OutcomeKind.committed,
          followUpPending: true,
          failure: FailureCode.followUpPending,
        ),
      );
      throw const AppFailure(FailureCode.followUpPending);
    } finally {
      _work = null;
      _lease?.release();
      _lease = null;
    }
  }

  @override
  Future<void> close() => _closeFuture ??= _close().catchError((Object error) {
    _closeFuture = null;
    _closing = false;
    throw error;
  });

  Future<void> _close() async {
    _closing = true;
    if (_active != null) await cancel();
    await _work;
    if (view.phase == JobPhase.recovery) await retryRecovery();
    if (view.phase == JobPhase.recovery) {
      throw const AppFailure(FailureCode.cleanupPending);
    }
    _publish(JobPhase.closed);
    await _changes.close();
  }
}

final class _ActiveJob {
  _ActiveJob(this.scenario);
  final DemoScenario scenario;
  final ready = Completer<JobStamp?>();
  JobStamp? stamp;
  SourceSession? session;
  CollectionArtifact? artifact;
  FailureCode? failure;
  bool cancelRequested = false;
  CancellationDisposition? cancelResult;
  Future<CancellationDisposition>? cancellation;
}
