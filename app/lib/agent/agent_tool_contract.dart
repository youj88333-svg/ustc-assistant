import '../core/agent_contract.dart';
import '../core/agent_parameter_issue.dart';
import '../core/calendar_contract.dart';
import '../core/agent_discussion_contract.dart';
import '../core/agent_context_contract.dart';
import 'model_gateway_contract.dart';

const agentToolRegistryVersion = 'agent-tools-v4';

const agentPersonalToolNames = {
  'query_agenda',
  'read_event',
  'query_tasks',
  'read_task',
  'inspect_conflicts',
  'propose_local_changes',
  'propose_undo',
  'find_free_slots',
  'propose_planning_preferences',
  'query_source_options',
  'request_source_refresh',
  'query_young_activities',
};

abstract interface class AgentToolScopeSession {
  /// App-owned human scope. Can only narrow a bound run, never widen it.
  void restrictPersonalData();
}

abstract interface class AgentPersonalReadScopeSession {
  /// Only human text establishes the opt-in; source/model text cannot do so.
  void bindHumanReadScope(String question);
}

/// App-owned policy, installed once on the actual run. Natural language and
/// source content cannot widen this data scope or execution mode.
abstract interface class AgentToolPolicySession {
  void bindToolPolicy(
    AgentRunTicket ticket, {
    required bool personalContentAllowed,
    required bool adviceOnly,
    AgentTargetAliasPort? aliases,
  });
  bool get personalContentUsed;
}

/// Each result is data, never instructions. No underlying authority is JSON.
final class AgentToolResult {
  AgentToolResult({
    required this.status,
    this.failure,
    this.validation,
    Map<String, Object?> data = const {},
    List<String> evidenceIds = const [],
  }) : data = Map.unmodifiable(data),
       evidenceIds = List.unmodifiable(evidenceIds);
  final String status;
  final String? failure;
  final AgentParameterIssue? validation;
  final Map<String, Object?> data;
  final List<String> evidenceIds;
  Map<String, Object?> toMap() => {
    'version': agentToolRegistryVersion,
    'status': status,
    if (failure != null) 'failure': failure,
    if (validation != null) 'validation': validation!.toSafeMap(),
    'data': data,
    'evidence': evidenceIds,
    'trust': 'untrusted_source_data',
  };
}

abstract interface class AgentToolSession {
  List<AgentEvidence> get evidence;
  Future<AgentToolResult> execute(ModelToolCall call);

  /// Revalidate lifecycle/consent. Old snapshots remain labelled history;
  /// current object versions are checked when reading/preparing a mutation.
  Future<void> validateDelivery();
  void revoke();
}

/// Internal reference mapping, never a schema accepting raw business IDs.
abstract interface class AgentLocalReferenceSession {
  Future<(CalendarReference, int)> resolveEventReference(String token);
  Future<(TaskReference, int)> resolveTaskReference(String token);
}

abstract interface class AgentDiscussionToolSession {
  Future<String> selectForDiscussion(AgentDiscussionSelection selection);
}

abstract interface class AgentInteractiveToolSession {
  void bindRun(AgentRunTicket ticket, String humanQuestion);
  AgentActionView? get pendingAction;
  bool get waitingForSchool;
  Stream<void> get interactiveChanges;
  Future<AgentToolResult> decidePending(bool approved);
  Future<void> continueSchool();

  /// Current facts must be queried again after an accepted business mutation.
  bool get contextInvalidated;
  void acknowledgeContextInvalidated();
}

abstract interface class AgentRememberedToolSession {
  Future<AgentToolResult?> tryRememberedDecision();
  Future<AgentToolResult> approveAndRememberPending();
}

abstract interface class AgentReadToolsPort {
  List<ModelToolDefinition> get definitions;
  AgentToolSession openSession();

  /// Only this port's C2 instance; it cannot cancel independent manual work.
  Future<void> cancelAndDrain();
  Future<void> close();
}
