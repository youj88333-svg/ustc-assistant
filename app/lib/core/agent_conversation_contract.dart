import 'agent_contract.dart';

/// C3-issued snapshot. A constructor alone cannot authorize a context update.
final class AgentConversationContext {
  AgentConversationContext({
    required this.conversationId,
    required this.revision,
    required this.coveredMessageId,
    required this.lastMessageId,
    required this.summary,
    required List<AgentMessage> messages,
  }) : messages = List.unmodifiable(messages);
  final String conversationId, summary;
  final int revision, coveredMessageId, lastMessageId;
  final List<AgentMessage> messages;
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
