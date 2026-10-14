import 'agent_contract.dart';
import 'agent_permission_contract.dart';
import 'calendar_contract.dart';

/// Durable conversational data, not a model SDK type or a write capability.
/// Images, credentials, system prompts and raw source responses are excluded.
final class AgentContextCall {
  const AgentContextCall({
    required this.id,
    required this.name,
    required this.argumentsJson,
  });
  final String id, name, argumentsJson;
}

final class AgentContextItem {
  AgentContextItem({
    required this.role,
    this.text,
    this.toolCallId,
    List<AgentContextCall> calls = const [],
  }) : calls = List.unmodifiable(calls);
  final String role;
  final String? text, toolCallId;
  final List<AgentContextCall> calls;
}

/// A completed protocol prefix of an actual assistant turn. Visible message
/// and run journals supply terminal state; this copy never replays operations.
final class AgentConversationTurn {
  AgentConversationTurn({
    required this.assistantMessageId,
    required this.receivedAtUtc,
    required this.includesPersonalContent,
    required List<AgentContextItem> items,
    this.applicationSelection = '',
  }) : items = List.unmodifiable(items);
  final int assistantMessageId;
  final DateTime receivedAtUtc;
  final bool includesPersonalContent;
  final String applicationSelection;
  final List<AgentContextItem> items;
}

/// Issued by C3. A caller-constructed instance cannot change permissions.
final class AgentUsePolicySnapshot {
  AgentUsePolicySnapshot({
    this.configured = false,
    this.personalContentAllowed = false,
    this.revision = 0,
    this.contextOptions = const AgentContextOptions(),
    Set<AgentPermissionCategory> granted = const {},
  }) : granted = Set.unmodifiable(granted);
  final bool configured, personalContentAllowed;
  final int revision;
  final AgentContextOptions contextOptions;
  final Set<AgentPermissionCategory> granted;
  bool get dailyOperationsAllowed =>
      agentDailyPermissionCategories.every(granted.contains);
  @override
  String toString() => 'AgentUsePolicySnapshot';
}

/// User configuration is an estimate, not verified provider capacity.
final class AgentContextOptions {
  const AgentContextOptions({
    this.inputTokens = 16000,
    this.outputTokens = 2048,
    this.modelCalls = 16,
    this.toolCalls = 48,
    this.activeSeconds = 300,
  });
  final int inputTokens, outputTokens, modelCalls, toolCalls, activeSeconds;
  List<int> get canonical => [
    inputTokens,
    outputTokens,
    modelCalls,
    toolCalls,
    activeSeconds,
  ];
  void validate() {
    if (inputTokens < 4096 ||
        inputTokens > 65536 ||
        outputTokens < 1 ||
        outputTokens > 8192 ||
        modelCalls < 1 ||
        modelCalls > 64 ||
        toolCalls < 1 ||
        toolCalls > 256 ||
        activeSeconds < 1 ||
        activeSeconds > 3600) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
  }
}

/// Existing categories; record deletion and school refresh stay separate.
const agentDailyPermissionCategories = {
  AgentPermissionCategory.createPersonal,
  AgentPermissionCategory.updatePersonal,
  AgentPermissionCategory.statePersonal,
  AgentPermissionCategory.createTask,
  AgentPermissionCategory.updateTask,
  AgentPermissionCategory.stateTask,
  AgentPermissionCategory.createBlock,
  AgentPermissionCategory.updateBlock,
  AgentPermissionCategory.stateBlock,
  AgentPermissionCategory.attendance,
  AgentPermissionCategory.listening,
  AgentPermissionCategory.note,
  AgentPermissionCategory.visibility,
  AgentPermissionCategory.saveRelation,
  AgentPermissionCategory.deleteRelation,
  AgentPermissionCategory.undo,
  AgentPermissionCategory.preferences,
};

abstract interface class AgentUsePolicyPort {
  Future<AgentUsePolicySnapshot> readAgentUsePolicy();
  Future<void> ensureAgentUsePolicySnapshot(AgentUsePolicySnapshot expected);
  Future<void> saveAgentUsePolicy(
    AgentUsePolicySnapshot expected, {
    required bool personalContentAllowed,
    required bool dailyOperationsAllowed,
    AgentContextOptions? contextOptions,
  });
  Future<void> bindAgentRunPolicy(
    AgentRunTicket ticket,
    AgentUsePolicySnapshot expected,
  );
  Future<void> ensureAgentUsePolicy(AgentRunTicket ticket, int revision);

  /// One-way constraint on this actual run; a tool cannot remove it.
  void constrainAgentRunToAdvice(AgentRunTicket ticket);
}

abstract interface class AgentTranscriptPort {
  Future<void> saveAgentTurn(
    AgentRunTicket ticket, {
    required List<AgentContextItem> items,
    required bool includesPersonalContent,
    required int policyRevision,
    String applicationSelection = '',
  });
}

/// Resolves an interrupted turn's actual local receipt. This is history, not
/// permission to execute its original operation again in a new run.
abstract interface class AgentReceiptRecoveryPort {
  /// Queries actual unfinished operation receipts independently of the model
  /// history window or evicted protocol copies. No private values are returned.
  Future<AgentLocalReceiptRecovery> findUnfinishedAgentLocalReceipt(
    AgentRunTicket current,
    String invocationFingerprint,
  );

  Future<bool> hasRecoverableAgentLocalReceipt(
    AgentRunTicket current,
    int assistantMessageId,
  );
}

enum AgentLocalReceiptRecoveryState { absent, committed, unknown }

final class AgentLocalReceiptRecovery {
  const AgentLocalReceiptRecovery(this.state, {this.committedCount = 0});
  final AgentLocalReceiptRecoveryState state;
  final int committedCount;
}

/// Conversation-local locators, not authority or IDs exposed to tools.
/// Resolution obtains current versions and rejects changed calendar scope.
abstract interface class AgentTargetAliasPort {
  Future<void> rememberAgentEvent(
    AgentRunTicket ticket,
    String alias,
    CalendarReference reference,
    DateTime startsAtUtc,
    DateTime endsAtUtc,
  );
  Future<void> rememberAgentTask(
    AgentRunTicket ticket,
    String alias,
    TaskReference reference,
  );
  Future<(CalendarReference, int)> resolveAgentEvent(
    AgentRunTicket ticket,
    String alias,
  );
  Future<(TaskReference, int)> resolveAgentTask(
    AgentRunTicket ticket,
    String alias,
  );
}
