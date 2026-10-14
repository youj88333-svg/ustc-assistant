import 'agent_contract.dart';
import 'agent_context_contract.dart';

/// C3-issued snapshot. A constructor alone cannot authorize a context update.
final class AgentConversationContext {
  AgentConversationContext({
    required this.conversationId,
    required this.revision,
    required this.coveredMessageId,
    required this.lastMessageId,
    required this.summary,
    required List<AgentMessage> messages,
    List<AgentConversationTurn> turns = const [],
    Set<int> withheldAssistantMessageIds = const {},
    this.includesPersonalContent = false,
  }) : messages = List.unmodifiable(messages),
       turns = List.unmodifiable(turns),
       withheldAssistantMessageIds = Set.unmodifiable(
         withheldAssistantMessageIds,
       );
  final String conversationId, summary;
  final int revision, coveredMessageId, lastMessageId;
  final List<AgentMessage> messages;
  final List<AgentConversationTurn> turns;
  final Set<int> withheldAssistantMessageIds;
  final bool includesPersonalContent;
  @override
  String toString() => 'AgentConversationContext';
}

/// Optional single-chat extension; history remains separate from model context.
abstract interface class AgentConversationControlPort {
  void revokeConversationContext();
  Future<String> ensurePrimaryConversation();
  Future<AgentConversationContext> readConversationContext();
  Future<void> saveConversationSummary(
    AgentConversationContext expected,
    String summary,
  );
}
