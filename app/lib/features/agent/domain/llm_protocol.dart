import '../application/cancellation_signal.dart';

/// A single streaming event produced by [LlmProvider.stream].
///
/// The hierarchy is sealed so the compiler guarantees that consumers handle
/// every variant. The provider emits exactly one terminal event
/// ([CompletedEvent] or [ErrorEvent]) and then closes the stream.
sealed class LlmEvent {
  const LlmEvent();
}

/// A chunk of assistant text. Concatenating [text] across all
/// [TextDeltaEvent]s in order reconstructs the full assistant message text.
final class TextDeltaEvent extends LlmEvent {
  const TextDeltaEvent(this.text);

  final String text;

  @override
  String toString() => 'TextDeltaEvent(${text.length} chars)';
}

/// Emitted once a `tool_use` content block is fully streamed: the partial
/// `input_json_delta` fragments have been reassembled and parsed into
/// [input].
final class ToolUseCompletedEvent extends LlmEvent {
  const ToolUseCompletedEvent({
    required this.id,
    required this.name,
    required this.input,
  });

  final String id;
  final String name;
  final Map<String, Object?> input;

  @override
  String toString() => 'ToolUseCompletedEvent($name)';
}

/// Usage accounting reported by the gateway. Either token count may be
/// absent if the gateway reports only one side.
final class UsageEvent extends LlmEvent {
  const UsageEvent({this.inputTokens, this.outputTokens});

  final int? inputTokens;
  final int? outputTokens;

  @override
  String toString() => 'UsageEvent(in=$inputTokens, out=$outputTokens)';
}

/// Terminal success: the stream completed without error. Carries nothing
/// beyond signalling end-of-stream.
final class CompletedEvent extends LlmEvent {
  const CompletedEvent();

  @override
  String toString() => 'CompletedEvent';
}

/// Terminal failure. [code] is an opaque, safe string (never contains the
/// API key, request body, or remote response text). [retryable] is true for
/// errors the caller could plausibly retry (transport, rate limit, server),
/// though the provider has already exhausted its own retry budget by the
/// time this is emitted.
final class ErrorEvent extends LlmEvent {
  const ErrorEvent(this.code, {this.retryable = false});

  final String code;
  final bool retryable;

  @override
  String toString() => 'ErrorEvent($code)';
}

/// A content block within an [LlmMessage]. Mirrors the Anthropic Messages
/// content-block shapes (text, tool_use, tool_result) but as pure, immutable
/// Dart types so the protocol layer stays free of JSON drudgery at the call
/// site.
sealed class LlmContentBlock {
  const LlmContentBlock();

  Map<String, Object?> toJson();
}

/// A plain-text content block.
final class LlmTextBlock extends LlmContentBlock {
  const LlmTextBlock(this.text);

  final String text;

  @override
  Map<String, Object?> toJson() => {'type': 'text', 'text': text};
}

/// A tool call issued by the assistant. Serialized into the request as a
/// `tool_use` block when replaying prior turns.
final class LlmToolUseBlock extends LlmContentBlock {
  const LlmToolUseBlock({
    required this.id,
    required this.name,
    required this.input,
  });

  final String id;
  final String name;
  final Map<String, Object?> input;

  @override
  Map<String, Object?> toJson() => {
    'type': 'tool_use',
    'id': id,
    'name': name,
    'input': input,
  };
}

/// A tool result returned to the assistant in a subsequent turn.
final class LlmToolResultBlock extends LlmContentBlock {
  const LlmToolResultBlock({
    required this.toolUseId,
    required this.content,
    this.isError = false,
  });

  final String toolUseId;

  /// The result content. The Anthropic API accepts either a string or a
  /// list of content blocks here; we keep it as an [Object] so callers can
  /// pass either shape.
  final Object content;
  final bool isError;

  @override
  Map<String, Object?> toJson() => {
    'type': 'tool_result',
    'tool_use_id': toolUseId,
    'content': content,
    if (isError) 'is_error': true,
  };
}

/// A single message in a conversation. [role] is either `'user'` or
/// `'assistant'`. The [content] is the structured list of blocks; for the
/// common text-only case use [LlmMessage.user] / [LlmMessage.assistant].
final class LlmMessage {
  const LlmMessage({required this.role, required this.content});

  /// Convenience constructor for a user turn carrying a single text block.
  LlmMessage.user({required String text})
    : role = 'user',
      content = [LlmTextBlock(text)];

  /// Convenience constructor for an assistant turn carrying a single text
  /// block.
  LlmMessage.assistant({required String text})
    : role = 'assistant',
      content = [LlmTextBlock(text)];

  final String role;
  final List<LlmContentBlock> content;

  Map<String, Object?> toJson() => {
    'role': role,
    'content': content.map((b) => b.toJson()).toList(),
  };
}

/// A tool declaration passed to the model. The schema is a JSON Schema
/// object describing the tool's arguments.
final class LlmToolDeclaration {
  const LlmToolDeclaration({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  final String name;
  final String description;
  final Map<String, Object?> inputSchema;

  Map<String, Object?> toJson() => {
    'name': name,
    'description': description,
    'input_schema': inputSchema,
  };
}

/// A complete streaming request to the gateway.
final class LlmRequest {
  const LlmRequest({
    required this.model,
    required this.messages,
    this.system,
    this.tools = const [],
    this.temperature = 0.2,
    this.maxTokens = 4096,
  });

  final String model;
  final List<LlmMessage> messages;

  /// Optional system prompt. Sent as the top-level `system` field per the
  /// Anthropic Messages schema.
  final String? system;
  final List<LlmToolDeclaration> tools;
  final double temperature;
  final int maxTokens;

  Map<String, Object?> toJson() => {
    'model': model,
    'messages': messages.map((m) => m.toJson()).toList(),
    if (system != null) 'system': system,
    if (tools.isNotEmpty) 'tools': tools.map((t) => t.toJson()).toList(),
    'temperature': temperature,
    'max_tokens': maxTokens,
    'stream': true,
  };
}

/// The LLM gateway contract. Implementations drive the Anthropic Messages
/// API over `package:http` and emit [LlmEvent]s. The API key is an ephemeral
/// per-call parameter; implementations MUST NOT retain it beyond the call.
abstract interface class LlmProvider {
  /// Lists model ids available at the gateway (`GET /v1/models`).
  Future<List<String>> listModels({
    required String apiKey,
    required CancellationSignal cancellation,
  });

  /// Opens a streaming `POST /v1/messages` request and emits [LlmEvent]s.
  /// The stream emits exactly one terminal event ([CompletedEvent] or
  /// [ErrorEvent]) and then closes.
  Stream<LlmEvent> stream({
    required String apiKey,
    required LlmRequest request,
    required CancellationSignal cancellation,
  });

  /// Sends a minimal non-personal text request and succeeds only if the
  /// stream completes with at least one [TextDeltaEvent] and ends in
  /// [CompletedEvent]. Throws on [ErrorEvent].
  Future<void> probeText({
    required String apiKey,
    required String model,
    required CancellationSignal cancellation,
  });

  /// Sends a request declaring exactly one tool
  /// (`ustc_agent_capability_probe`) and succeeds only if the model emits a
  /// `tool_use` for that exact name with a provided input. Throws otherwise.
  Future<void> probeTools({
    required String apiKey,
    required String model,
    required CancellationSignal cancellation,
  });
}
