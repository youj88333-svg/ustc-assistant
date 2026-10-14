import 'agent_contract.dart';
import 'calendar_contract.dart';

/// Local identifiers and canonical intents never leave C3/C4 as model fields.
sealed class AgentLocalChange {
  const AgentLocalChange();
  List<Object?> get canonical;
}

final class AgentCalendarChange extends AgentLocalChange {
  const AgentCalendarChange(this.intent);
  final CalendarIntent intent;
  @override
  List<Object?> get canonical => ['calendar', intent.canonical];
}

final class AgentCreateTask extends AgentLocalChange {
  const AgentCreateTask(this.localKey, this.draft);
  final String localKey;
  final TaskDraft draft;
  @override
  List<Object?> get canonical => ['new-task', localKey, draft.canonical];
}

final class AgentDependentBlock extends AgentLocalChange {
  const AgentDependentBlock(this.taskKey, this.draft);
  final String taskKey;
  final PlanBlockDraft draft;
  @override
  List<Object?> get canonical => ['dependent-block', taskKey, draft.canonical];
}

/// C3 preserves omitted private fields; a model patch never reads them first.
final class AgentTaskPatch extends AgentLocalChange {
  const AgentTaskPatch(
    this.target, {
    this.title,
    this.description,
    this.note,
    this.deadlineUtc,
    this.clearDeadline = false,
    this.estimatedMinutes,
    this.clearEstimate = false,
    this.priority,
  });
  final TaskReference target;
  final String? title, description, note;
  final DateTime? deadlineUtc;
  final bool clearDeadline, clearEstimate;
  final int? estimatedMinutes;
  final TaskPriority? priority;
  @override
  List<Object?> get canonical => [
    'task-patch',
    target.canonical,
    title,
    description,
    note,
    deadlineUtc?.microsecondsSinceEpoch,
    clearDeadline,
    estimatedMinutes,
    clearEstimate,
    priority?.name,
  ];
}

final class AgentPersonalPatch extends AgentLocalChange {
  const AgentPersonalPatch(
    this.target, {
    required this.entireSeries,
    this.title,
    this.start,
    this.end,
    this.allDay,
    this.weekly,
    this.untilDay,
    this.clearUntil = false,
    this.location,
    this.note,
  });
  final CalendarReference target;
  final bool entireSeries, clearUntil;
  final String? title, location, note;
  final DateTime? start, end, untilDay;
  final bool? allDay, weekly;
  @override
  List<Object?> get canonical => [
    'personal-patch',
    target.canonical,
    entireSeries,
    title,
    start?.microsecondsSinceEpoch,
    end?.microsecondsSinceEpoch,
    allDay,
    weekly,
    untilDay?.microsecondsSinceEpoch,
    clearUntil,
    location,
    note,
  ];
}

final class AgentBlockPatch extends AgentLocalChange {
  const AgentBlockPatch(
    this.target, {
    this.startUtc,
    this.endUtc,
    this.location,
    this.note,
  });
  final CalendarReference target;
  final DateTime? startUtc, endUtc;
  final String? location, note;
  @override
  List<Object?> get canonical => [
    'block-patch',
    target.canonical,
    startUtc?.microsecondsSinceEpoch,
    endUtc?.microsecondsSinceEpoch,
    location,
    note,
  ];
}

/// Immutable proposal, issued and checked by C3 using exact object identity.
final class AgentLocalPlan {
  AgentLocalPlan({
    required this.id,
    required this.ticket,
    required this.context,
    required this.revision,
    required this.expiresAtUtc,
    required List<AgentLocalChange> changes,
    required this.view,
    this.requireFree = false,
    this.preferencesRevision,
  }) : changes = List.unmodifiable(changes);
  final String id;
  final AgentRunTicket ticket;
  final CalendarContext context;
  final int revision;
  final DateTime expiresAtUtc;
  final List<AgentLocalChange> changes;
  final AgentActionView view;
  final bool requireFree;
  final int? preferencesRevision;
  @override
  String toString() => 'AgentLocalPlan';
}

/// Constructor alone does not grant permission: C3 checks its issued identity.
final class AgentPlanApproval {
  const AgentPlanApproval(this.plan);
  final AgentLocalPlan plan;
  @override
  String toString() => 'AgentPlanApproval';
}

/// Associates an issued, unmodified plan with the invocation that prepared it.
/// This does not approve or execute the plan; normal transaction guards apply.
abstract interface class AgentLocalInvocationPort {
  Future<void> bindLocalInvocation(
    AgentLocalPlan plan,
    String invocationFingerprint,
  );
}

final class AgentLocalPlanReceipt {
  AgentLocalPlanReceipt({
    required this.planId,
    required this.revision,
    required this.committedCount,
    required this.committedAtUtc,
    required this.replayed,
    required this.view,
    this.undo,
  });
  final String planId;
  final int revision, committedCount;
  final DateTime committedAtUtc;
  final bool replayed;
  final CalendarUndoReference? undo;
  final AgentActionView view;
  @override
  String toString() => 'AgentLocalPlanReceipt';
}

abstract interface class AgentLocalPlanPort {
  Future<(CalendarContext, int)> readPlanContext();
  Future<AgentLocalPlan> prepareLocalPlan(
    AgentRunTicket ticket,
    CalendarContext context,
    int revision,
    List<AgentLocalChange> changes, {
    bool requireFree = false,
    int? preferencesRevision,
  });
  Future<AgentPlanApproval> approveLocalPlan(AgentLocalPlan plan);
  Future<void> rejectLocalPlan(AgentLocalPlan plan);
  Future<AgentLocalPlanReceipt> commitLocalPlan(AgentPlanApproval approval);

  /// Synchronous cancellation precedes queued cancellation and SQL checkpoints.
  void revokeLocalPlans(AgentRunTicket ticket);
}

abstract interface class AgentActionRecordPort {
  Future<AgentActionView> prepareActionRecord(
    AgentRunTicket ticket,
    AgentActionKind kind,
    String title,
    List<String> details, {
    String warning = '',
  });
  Future<void> settleActionRecord(
    AgentRunTicket ticket,
    AgentActionView record,
    AgentActionStatus status, {
    int committedCount = 0,
  });
}

/// Application decision only; this method is absent from the model registry.
abstract interface class AgentSourceApprovalPort {
  Future<void> approveSourceAction(
    AgentRunTicket ticket,
    AgentActionView record,
  );
}

final class AgentPlanningPreferences {
  AgentPlanningPreferences({
    this.revision = 0,
    List<int> weekdays = const [1, 2, 3, 4, 5, 6, 7],
    this.startMinute = 7 * 60,
    this.endMinute = 23 * 60 + 59,
    this.blockMinutes = 60,
    this.breakMinutes = 10,
    List<(int, int)> avoid = const [],
  }) : weekdays = List.unmodifiable(weekdays),
       avoid = List.unmodifiable(avoid);
  final int revision, startMinute, endMinute, blockMinutes, breakMinutes;
  final List<int> weekdays;
  final List<(int, int)> avoid;
  List<Object> get canonical => [
    weekdays,
    startMinute,
    endMinute,
    blockMinutes,
    breakMinutes,
    avoid.map((r) => [r.$1, r.$2]).toList(),
  ];
  @override
  String toString() => 'AgentPlanningPreferences';
}

abstract interface class AgentPreferencesPort {
  Future<AgentPlanningPreferences> readPlanningPreferences();
  Future<void> savePlanningPreferences(AgentPlanningPreferences expected);
}

abstract interface class AgentPreferencesProposalPort {
  Future<AgentActionView> preparePreferencesPlan(
    AgentRunTicket ticket,
    AgentPlanningPreferences preferences,
  );
  Future<void> commitPreferencesPlan(
    AgentRunTicket ticket,
    AgentActionView record,
  );
  Future<void> rejectPreferencesPlan(
    AgentRunTicket ticket,
    AgentActionView record,
  );
}
