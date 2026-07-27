class PlanBlockImpact {
  const PlanBlockImpact({
    required this.futureAcceptedCount,
    required this.futureAcceptedMinutes,
  });

  final int futureAcceptedCount;
  final int futureAcceptedMinutes;
}

abstract interface class PlanBlockLifecyclePort {
  Future<PlanBlockImpact> summarize(String taskId, DateTime now);

  Future<void> taskCompleted(
    String taskId,
    DateTime now, {
    required bool cancelFutureAccepted,
  });

  Future<void> taskCancelled(String taskId, DateTime now);
}

class NoopPlanBlockLifecyclePort implements PlanBlockLifecyclePort {
  const NoopPlanBlockLifecyclePort();

  @override
  Future<PlanBlockImpact> summarize(String taskId, DateTime now) async =>
      const PlanBlockImpact(futureAcceptedCount: 0, futureAcceptedMinutes: 0);

  @override
  Future<void> taskCancelled(String taskId, DateTime now) async {}

  @override
  Future<void> taskCompleted(
    String taskId,
    DateTime now, {
    required bool cancelFutureAccepted,
  }) async {}
}
