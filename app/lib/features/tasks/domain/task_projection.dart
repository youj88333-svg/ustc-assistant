import 'task.dart';

enum PlanningState { unplanned, planned }

enum DeadlineState { notApplicable, noDeadline, upcoming, dueToday, overdue }

enum ConfirmationState { clear, awaitingPlanBlockReview }

enum PlanBlockProjectionState {
  suggested,
  accepted,
  done,
  skipped,
  rescheduled,
  cancelled,
}

class PlanBlockSnapshot {
  const PlanBlockSnapshot({required this.state, required this.endAt});

  final PlanBlockProjectionState state;
  final DateTime endAt;
}

class TaskProjection {
  const TaskProjection({
    required this.planning,
    required this.deadline,
    required this.confirmation,
  });

  final PlanningState planning;
  final DeadlineState deadline;
  final ConfirmationState confirmation;
}

TaskProjection projectTask(
  TaskItem task,
  DateTime now, {
  List<PlanBlockSnapshot> planBlocks = const [],
}) {
  if (task.isTerminal) {
    return const TaskProjection(
      planning: PlanningState.unplanned,
      deadline: DeadlineState.notApplicable,
      confirmation: ConfirmationState.clear,
    );
  }

  final accepted = planBlocks.where(
    (block) => block.state == PlanBlockProjectionState.accepted,
  );
  final hasFutureAccepted = accepted.any((block) => block.endAt.isAfter(now));
  final hasElapsedAccepted = accepted.any((block) => !block.endAt.isAfter(now));

  return TaskProjection(
    planning: hasFutureAccepted
        ? PlanningState.planned
        : PlanningState.unplanned,
    deadline: _deadlineState(task.deadlineAt, now),
    confirmation: hasElapsedAccepted
        ? ConfirmationState.awaitingPlanBlockReview
        : ConfirmationState.clear,
  );
}

DeadlineState _deadlineState(DateTime? deadline, DateTime now) {
  if (deadline == null) return DeadlineState.noDeadline;
  if (now.isAfter(deadline)) return DeadlineState.overdue;
  if (deadline.year == now.year &&
      deadline.month == now.month &&
      deadline.day == now.day) {
    return DeadlineState.dueToday;
  }
  return DeadlineState.upcoming;
}
