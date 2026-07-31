import '../domain/agent_tool.dart';
import '../domain/llm_protocol.dart';
import 'outbound_privacy_filter.dart';

/// The registry of read-only tools available to the Agent runtime.
///
/// The registry is the single boundary between the model and concrete tools:
/// it owns the tool declarations surfaced to the model ([schemas]) and the
/// dispatch + sanitization path for executions ([execute]). Concrete tools are
/// injected by the caller; the registry holds no tool-specific knowledge.
///
/// Responsibilities:
/// - Expose [LlmToolDeclaration]s for every registered tool.
/// - Dispatch a tool call by name. An unknown name yields a `tool_not_allowed`
///   error result — the model never reaches an unregistered tool.
/// - Run the tool's raw payload through `OutboundPrivacyFilter.sanitizeToolPayload`
///   before constructing the [AgentToolResult] that reaches the model. The
///   allowlist is the primary boundary; the filter's backstop redaction is
///   defense in depth.
/// - Contain any thrown exception as a `tool_execution_failed` error so a
///   buggy tool cannot crash the run.
class AgentToolRegistry {
  AgentToolRegistry({
    required List<AgentTool> tools,
    required this._privacyFilter,
  }) : _tools = {for (final t in tools) t.name: t};

  final Map<String, AgentTool> _tools;
  final OutboundPrivacyFilter _privacyFilter;

  /// The tool declarations to pass to the model, in registration order.
  List<LlmToolDeclaration> get schemas {
    final declarations = <LlmToolDeclaration>[];
    for (final tool in _tools.values) {
      declarations.add(
        LlmToolDeclaration(
          name: tool.name,
          description: tool.description,
          inputSchema: tool.inputSchema,
        ),
      );
    }
    return declarations;
  }

  /// Whether a tool with [name] is registered.
  bool isRegistered(String name) => _tools.containsKey(name);

  /// Executes the tool named [toolName] with [arguments] under [context].
  ///
  /// Contract:
  /// - Unknown tool -> [AgentToolResult] with status `error` and code
  ///   `tool_not_allowed`; the tool is never invoked.
  /// - Registered tool -> invoked; its raw payload is sanitized through the
  ///   privacy filter before reaching the result.
  /// - Any thrown exception -> [AgentToolResult] with status `error` and code
  ///   `tool_execution_failed`; the run is not crashed.
  ///
  /// [arguments] is the parsed tool-use input (already a `Map<String,Object?>`
  /// per the LLM protocol). The registry does not re-parse JSON here — the
  /// session service owns parsing from the model's tool_use block and surfaces
  /// malformed input as an error result before dispatch.
  Future<AgentToolResult> execute({
    required String toolName,
    required Map<String, Object?> arguments,
    required AgentToolContext context,
  }) async {
    final tool = _tools[toolName];
    if (tool == null) {
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'tool_not_allowed',
      );
    }

    try {
      final raw = await tool.execute(arguments, context);
      return _sanitizeResult(toolName, raw);
    } catch (_) {
      // Contain tool failures so the run continues with an error tool_result.
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'tool_execution_failed',
      );
    }
  }

  AgentToolResult _sanitizeResult(String toolName, AgentToolResult raw) {
    final sanitized = _privacyFilter.sanitizeToolPayload(
      toolName: toolName,
      rawPayload: raw.payload,
    );
    final pending = raw.pendingInvocation;
    return AgentToolResult(
      status: raw.status,
      payload: sanitized,
      references: raw.references,
      errorCode: raw.errorCode,
      userAction: raw.userAction,
      pendingInvocation: pending == null
          ? null
          : AgentPendingToolInvocation(
              result: pending.result.then(
                (result) => _sanitizeResult(toolName, result),
              ),
              cancel: pending.cancel,
            ),
    );
  }
}
