/// Pure domain models for the read-only campus Agent chat layer.
///
/// These types intentionally avoid Drift and I/O dependencies so later
/// shared-core tasks can import them without pulling the database stack.
enum AgentRunState {
  running,
  completed,
  failed,
  cancelled,
  interrupted;

  static AgentRunState fromName(String name) =>
      AgentRunState.values.firstWhere((value) => value.name == name);
}

enum ChatRole {
  user,
  assistant;

  static ChatRole fromName(String name) =>
      ChatRole.values.firstWhere((value) => value.name == name);
}

enum ChatMessageState {
  streaming,
  completed,
  failed,
  cancelled,
  interrupted;

  static ChatMessageState fromName(String name) =>
      ChatMessageState.values.firstWhere((value) => value.name == name);
}

/// A single chat message persisted in `chat_messages`.
class ChatMessageRecord {
  const ChatMessageRecord({
    required this.id,
    required this.accountId,
    required this.runId,
    required this.ordinal,
    required this.role,
    required this.state,
    required this.content,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String accountId;
  final String? runId;
  final int ordinal;
  final ChatRole role;
  final ChatMessageState state;
  final String content;
  final int createdAt;
  final int updatedAt;
}

/// A completed or in-flight agent run persisted in `agent_runs`.
class AgentRunRecord {
  const AgentRunRecord({
    required this.id,
    required this.accountId,
    required this.model,
    required this.status,
    required this.errorCode,
    required this.inputTokens,
    required this.outputTokens,
    required this.startedAt,
    required this.finishedAt,
  });

  final String id;
  final String accountId;
  final String model;
  final AgentRunState status;
  final String? errorCode;
  final int? inputTokens;
  final int? outputTokens;
  final int startedAt;
  final int? finishedAt;
}

/// The current conversation summary persisted in `conversation_summaries`.
class ConversationSummaryRecord {
  const ConversationSummaryRecord({
    required this.id,
    required this.accountId,
    required this.throughOrdinal,
    required this.content,
    required this.model,
    required this.createdAt,
  });

  final String id;
  final String accountId;
  final int throughOrdinal;
  final String content;
  final String model;
  final int createdAt;
}
