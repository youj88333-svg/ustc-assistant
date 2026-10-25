import '../core/contracts.dart';
import '../data/import_contract.dart';
import '../source/source_contract.dart';

enum JobPhase { idle, collecting, settling, recovery, closed }

enum OutcomeKind { committed, cancelled, failed }

final class JobOutcome {
  const JobOutcome({
    required this.kind,
    this.failure,
    this.recordCount = 0,
    this.replayed = false,
    this.followUpPending = false,
  });

  final OutcomeKind kind;
  final FailureCode? failure;
  final int recordCount;
  final bool replayed;
  final bool followUpPending;
}

final class CoordinatorView {
  const CoordinatorView({
    required this.phase,
    required this.sequence,
    this.cancelRequested = false,
    this.outcome,
  });

  final JobPhase phase;
  final int sequence;
  final bool cancelRequested;
  final JobOutcome? outcome;

  bool get isBusy => phase != JobPhase.idle && phase != JobPhase.closed;
}

abstract interface class CoordinatorPort {
  CoordinatorView get view;
  Stream<CoordinatorView> get changes;
  Future<JobOutcome> run(DemoScenario scenario);
  Future<CancellationDisposition> cancel();
  Future<JobOutcome> retryRecovery();
  Future<void> retryFollowUps();
  Future<void> close();
}
