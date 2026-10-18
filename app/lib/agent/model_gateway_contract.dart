import '../core/agent_contract.dart';

final modelToolCallIdPattern = RegExp(r'^[A-Za-z0-9_.:-]{1,128}$');

final class ModelToolCall {
  const ModelToolCall({
    required this.id,
    required this.name,
    required this.argumentsJson,
  });
  final String id, name, argumentsJson;
  @override
  String toString() => 'ModelToolCall';
}

final class ModelChatMessage {
  ModelChatMessage({
    required this.role,
    this.content,
    this.toolCallId,
    List<ModelToolCall> toolCalls = const [],
    List<AgentImage> images = const [],
  }) : toolCalls = List.unmodifiable(toolCalls),
       images = List.unmodifiable(images);
  final String role;
  final String? content, toolCallId;
  final List<ModelToolCall> toolCalls;
  final List<AgentImage> images;
  @override
  String toString() => 'ModelChatMessage';
}

final class ModelToolDefinition {
  ModelToolDefinition({
    required this.name,
    required this.description,
    required Map<String, Object?> parameters,
  }) : parameters = Map.unmodifiable(parameters);
  final String name, description;
  final Map<String, Object?> parameters;
}

final class ModelRequest {
  ModelRequest({
    required this.modelId,
    required List<ModelChatMessage> messages,
    List<ModelToolDefinition> tools = const [],
    this.toolChoice,
    this.maxTokens = 2048,
  }) : messages = List.unmodifiable(messages),
       tools = List.unmodifiable(tools);
  final String modelId;
  final List<ModelChatMessage> messages;
  final List<ModelToolDefinition> tools;

  /// Only 'none'/'auto' or an explicitly supplied tool's name. No other JSON.
  final String? toolChoice;
  final int maxTokens;
  @override
  String toString() => 'ModelRequest';
}

sealed class ModelEvent {
  const ModelEvent();
}

final class ModelTextDelta extends ModelEvent {
  const ModelTextDelta(this.text);
  final String text;
  @override
  String toString() => 'ModelTextDelta';
}

/// Optional text explicitly supplied by the configured provider. Display only:
/// never a conversation message, tool argument, action or reusable model input.
final class ModelReasoningDelta extends ModelEvent {
  const ModelReasoningDelta(this.text);
  final String text;
  @override
  String toString() => 'ModelReasoningDelta';
}

final class ModelCompleted extends ModelEvent {
  ModelCompleted({
    required this.finishReason,
    List<ModelToolCall> toolCalls = const [],
    this.inputTokens,
    this.outputTokens,
  }) : toolCalls = List.unmodifiable(toolCalls);
  final String finishReason;
  final List<ModelToolCall> toolCalls;
  final int? inputTokens, outputTokens;
}

abstract interface class ModelGatewayPort {
  Future<List<String>> listModels(ModelSecretLease secret);
  Stream<ModelEvent> generate(ModelRequest request, ModelSecretLease secret);

  /// Cancels all owned in-flight requests, drains and retains reusable client.
  Future<void> cancelAndDrain();
  Future<void> close();
}
