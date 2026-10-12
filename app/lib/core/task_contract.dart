part of 'calendar_contract.dart';

enum TaskStatus { active, blocked, completed, cancelled }

enum TaskPriority { low, normal, high }

enum TaskFilter { open, all, active, blocked, completed, cancelled }

enum PlanBlockStatus { planned, done, skipped }

final class TaskReference {
  const TaskReference(this.context, this.localId, this.version);
  final CalendarContext context;
  final int localId;
  final int version;
  List<Object> get canonical => [
    context.owner,
    context.resetEpoch,
    context.agendaEpoch,
    localId,
    version,
  ];
  @override
  String toString() => 'TaskReference';
}

final class TaskDraft {
  const TaskDraft({
    required this.title,
    this.description = '',
    this.note = '',
    this.deadlineAtUtc,
    this.estimatedMinutes,
    this.priority = TaskPriority.normal,
  });
  final String title;
  final String description;
  final String note;
  final DateTime? deadlineAtUtc;
  final int? estimatedMinutes;
  final TaskPriority priority;
  List<Object?> get canonical => [
    title,
    description,
    note,
    deadlineAtUtc?.microsecondsSinceEpoch,
    estimatedMinutes,
    priority.name,
  ];
  @override
  String toString() => 'TaskDraft';
}

final class TaskRecord {
  const TaskRecord({
    required this.reference,
    required this.draft,
    required this.status,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    required this.blockCount,
  });
  final TaskReference reference;
  final TaskDraft draft;
  final TaskStatus status;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;
  final int blockCount;
  @override
  String toString() => 'TaskRecord';
}

final class PlanBlockDraft {
  const PlanBlockDraft({
    required this.startsAtUtc,
    required this.endsAtUtc,
    this.location = '',
    this.note = '',
  });
  final DateTime startsAtUtc;
  final DateTime endsAtUtc;
  final String location;
  final String note;
  List<Object> get canonical => [
    startsAtUtc.microsecondsSinceEpoch,
    endsAtUtc.microsecondsSinceEpoch,
    location,
    note,
  ];
  @override
  String toString() => 'PlanBlockDraft';
}

final class PlanBlockRecord {
  const PlanBlockRecord({
    required this.reference,
    required this.task,
    required this.taskTitle,
    required this.taskStatus,
    required this.draft,
    required this.status,
  });

  /// The version is the owning Task aggregate version, not a clock or hash.
  final CalendarReference reference;
  final TaskReference task;
  final String taskTitle;
  final TaskStatus taskStatus;
  final PlanBlockDraft draft;
  final PlanBlockStatus status;
  bool awaitingReview(DateTime nowUtc) =>
      status == PlanBlockStatus.planned && !draft.endsAtUtc.isAfter(nowUtc);
  @override
  String toString() => 'PlanBlockRecord';
}

final class TaskQuery {
  const TaskQuery({
    this.filter = TaskFilter.open,
    this.keyword = '',
    this.limit = 100,
  });
  final TaskFilter filter;
  final String keyword;
  final int limit;
}

final class TaskWindow {
  TaskWindow({
    required this.context,
    required this.revision,
    required this.query,
    required List<TaskRecord> items,
    required this.matched,
    required this.truncated,
  }) : items = List.unmodifiable(items);
  final String version = 'local-task-v1';
  final CalendarContext context;
  final int revision;
  final TaskQuery query;
  final List<TaskRecord> items;
  final int matched;
  final bool truncated;
}

final class TaskDetail {
  TaskDetail({
    required this.task,
    required List<PlanBlockRecord> blocks,
    required this.nowUtc,
  }) : blocks = List.unmodifiable(blocks);
  final TaskRecord task;
  final List<PlanBlockRecord> blocks;
  final DateTime nowUtc;
}

final class CalendarUndoReference {
  const CalendarUndoReference(this.context, this.undoId);
  final CalendarContext context;
  final String undoId;
  List<Object> get canonical => [
    context.owner,
    context.resetEpoch,
    context.agendaEpoch,
    undoId,
  ];
  @override
  String toString() => 'CalendarUndoReference';
}

final class CalendarUndoView {
  const CalendarUndoView({
    this.reference,
    this.action,
    this.createdAtUtc,
    this.expiresAtUtc,
    this.failure,
  });
  final CalendarUndoReference? reference;
  final String? action;
  final DateTime? createdAtUtc;
  final DateTime? expiresAtUtc;
  final CalendarFailureCode? failure;
  bool get canUndo => reference != null && failure == null;
}

abstract interface class LocalTaskPort {
  Future<TaskWindow> queryTasks(TaskQuery query);
  Future<TaskDetail> taskDetail(TaskReference reference);
  Future<CalendarUndoView> queryUndo(CalendarContext context);
}

final class CreateTask extends CalendarIntent {
  const CreateTask(this.draft);
  final TaskDraft draft;
  @override
  List<Object?> get canonical => ['task-create', draft.canonical];
}

final class UpdateTask extends CalendarIntent {
  const UpdateTask(this.target, this.draft);
  final TaskReference target;
  final TaskDraft draft;
  @override
  List<Object?> get canonical => [
    'task-update',
    target.canonical,
    draft.canonical,
  ];
}

final class SetTaskStatus extends CalendarIntent {
  const SetTaskStatus(this.target, this.status);
  final TaskReference target;
  final TaskStatus status;
  @override
  List<Object?> get canonical => ['task-status', target.canonical, status.name];
}

final class DeleteTask extends CalendarIntent {
  const DeleteTask(this.target, {required this.confirmed});
  final TaskReference target;
  final bool confirmed;
  @override
  List<Object?> get canonical => ['task-delete', target.canonical, confirmed];
}

final class CreatePlanBlock extends CalendarIntent {
  const CreatePlanBlock(this.task, this.draft);
  final TaskReference task;
  final PlanBlockDraft draft;
  @override
  List<Object?> get canonical => [
    'block-create',
    task.canonical,
    draft.canonical,
  ];
}

final class UpdatePlanBlock extends CalendarIntent {
  const UpdatePlanBlock(this.target, this.draft);
  final CalendarReference target;
  final PlanBlockDraft draft;
  @override
  List<Object?> get canonical => [
    'block-update',
    target.canonical,
    draft.canonical,
  ];
}

final class SetPlanBlockStatus extends CalendarIntent {
  const SetPlanBlockStatus(this.target, this.status);
  final CalendarReference target;
  final PlanBlockStatus status;
  @override
  List<Object?> get canonical => [
    'block-status',
    target.canonical,
    status.name,
  ];
}

final class DeletePlanBlock extends CalendarIntent {
  const DeletePlanBlock(this.target, {required this.confirmed});
  final CalendarReference target;
  final bool confirmed;
  @override
  List<Object?> get canonical => ['block-delete', target.canonical, confirmed];
}

final class UndoCalendarWrite extends CalendarIntent {
  const UndoCalendarWrite(this.target);
  final CalendarUndoReference target;
  @override
  List<Object?> get canonical => ['undo', target.canonical];
}
