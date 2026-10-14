import 'dart:convert';

import 'model_gateway_contract.dart';

/// Immutable soft input and per-run execution budget for Agent context work.
///
/// Token estimates are deliberately approximate. They do not prove a model's
/// context capacity and must not decide business scope or permissions.
final class AgentContextBudget {
  AgentContextBudget({
    this.maximumInputTokens = 16000,
    this.maximumOutputTokens = 2048,
    this.maximumModelCalls = 16,
    this.maximumToolCalls = 48,
    this.activeTimeout = const Duration(seconds: 300),
    this.softFraction = 0.75,
  }) {
    _requireRange(
      maximumInputTokens,
      'maximumInputTokens',
      minimumInputTokens,
      maximumInputTokensLimit,
    );
    _requireRange(
      maximumOutputTokens,
      'maximumOutputTokens',
      minimumOutputTokens,
      maximumOutputTokensLimit,
    );
    _requireRange(
      maximumModelCalls,
      'maximumModelCalls',
      minimumModelCalls,
      maximumModelCallsLimit,
    );
    _requireRange(
      maximumToolCalls,
      'maximumToolCalls',
      minimumToolCalls,
      maximumToolCallsLimit,
    );
    if (activeTimeout < minimumActiveTimeout ||
        activeTimeout > maximumActiveTimeout) {
      throw ArgumentError.value(
        activeTimeout,
        'activeTimeout',
        'must be between one second and one hour',
      );
    }
    if (!softFraction.isFinite || softFraction <= 0 || softFraction >= 1) {
      throw ArgumentError.value(
        softFraction,
        'softFraction',
        'must be finite and greater than zero and less than one',
      );
    }
  }

  static const minimumInputTokens = 4096;
  static const maximumInputTokensLimit = 65536;
  static const minimumOutputTokens = 1;
  static const maximumOutputTokensLimit = 8192;
  static const minimumModelCalls = 1;
  static const maximumModelCallsLimit = 64;
  static const minimumToolCalls = 1;
  static const maximumToolCallsLimit = 256;
  static const minimumMessages = 1;
  static const maximumMessagesLimit = 512;
  static const imageTokenReservePerImage = 4096;

  static const minimumActiveTimeout = Duration(seconds: 1);
  static const maximumActiveTimeout = Duration(hours: 1);

  final int maximumInputTokens;
  final int maximumOutputTokens;
  final int maximumModelCalls;
  final int maximumToolCalls;
  final Duration activeTimeout;
  final double softFraction;

  /// Estimates text, roles, tool calls, schemas, and a separate image reserve.
  ///
  /// ASCII runs use about three characters per token, Han characters use 1.5
  /// tokens each, and other Unicode characters use two tokens each. Each image
  /// gets a fixed reserve; its actual token cost remains provider/model-specific
  /// and unknown until usage is reported.
  AgentContextEstimate estimateMessages(
    List<ModelChatMessage> messages,
    List<ModelToolDefinition> tools,
  ) {
    var textTokens = 0;
    var imageCount = 0;
    for (final message in messages) {
      textTokens += _messageOverheadTokens;
      textTokens += _estimateTextTokens(message.role);
      final content = message.content;
      if (content != null) textTokens += _estimateTextTokens(content);
      final toolCallId = message.toolCallId;
      if (toolCallId != null) textTokens += _estimateTextTokens(toolCallId);
      for (final call in message.toolCalls) {
        textTokens += _toolCallOverheadTokens;
        textTokens += _estimateTextTokens(call.id);
        textTokens += _estimateTextTokens(call.name);
        textTokens += _estimateTextTokens(call.argumentsJson);
      }
      imageCount += message.images.length;
    }

    for (final tool in tools) {
      textTokens += _toolDefinitionOverheadTokens;
      textTokens += _estimateTextTokens(tool.name);
      textTokens += _estimateTextTokens(tool.description);
      textTokens += _estimateTextTokens(_encodeParameters(tool.parameters));
    }

    return AgentContextEstimate(
      textTokens: textTokens,
      imageCount: imageCount,
      estimatedImageTokens: imageCount * imageTokenReservePerImage,
    );
  }

  /// Signals compression at the soft fraction of the configured input budget.
  bool shouldCompact(AgentContextEstimate estimate) =>
      estimate.estimatedInputTokens >=
      (maximumInputTokens * softFraction).ceil();

  /// Drops only earliest complete groups until token and message limits fit.
  /// Fixed messages are never changed or removed.
  AgentContextTrimResult trimCompleteGroups(
    List<List<ModelChatMessage>> groups, {
    required List<ModelChatMessage> fixedMessages,
    required List<ModelToolDefinition> tools,
    int maximumMessages = 512,
  }) {
    _requireRange(
      maximumMessages,
      'maximumMessages',
      minimumMessages,
      maximumMessagesLimit,
    );
    final retained = groups
        .map((group) => List<ModelChatMessage>.unmodifiable(group))
        .toList();
    if (retained.any((group) => group.isEmpty)) {
      throw ArgumentError.value(
        groups,
        'groups',
        'must not contain empty groups',
      );
    }

    final fixedEstimate = estimateMessages(fixedMessages, tools);
    final fixedOverflow =
        fixedEstimate.estimatedInputTokens > maximumInputTokens ||
        fixedMessages.length > maximumMessages;
    var estimate = _estimateGroups(retained, fixedMessages, tools);
    var messageCount = _messageCount(retained, fixedMessages);
    var removedGroupCount = 0;

    while ((estimate.estimatedInputTokens > maximumInputTokens ||
            messageCount > maximumMessages) &&
        retained.isNotEmpty) {
      retained.removeAt(0);
      removedGroupCount++;
      estimate = _estimateGroups(retained, fixedMessages, tools);
      messageCount = _messageCount(retained, fixedMessages);
    }

    return AgentContextTrimResult(
      retainedGroups: retained,
      removedGroupCount: removedGroupCount,
      estimate: estimate,
      maximumInputTokens: maximumInputTokens,
      messageCount: messageCount,
      maximumMessages: maximumMessages,
      fixedOverflow: fixedOverflow,
    );
  }

  AgentContextEstimate _estimateGroups(
    List<List<ModelChatMessage>> groups,
    List<ModelChatMessage> fixedMessages,
    List<ModelToolDefinition> tools,
  ) => estimateMessages([
    ...fixedMessages,
    for (final group in groups) ...group,
  ], tools);

  static int _messageCount(
    List<List<ModelChatMessage>> groups,
    List<ModelChatMessage> fixedMessages,
  ) =>
      fixedMessages.length +
      groups.fold<int>(0, (count, group) => count + group.length);

  static const _messageOverheadTokens = 4;
  static const _toolCallOverheadTokens = 4;
  static const _toolDefinitionOverheadTokens = 8;

  static void _requireRange(int value, String name, int minimum, int maximum) {
    if (value < minimum || value > maximum) {
      throw ArgumentError.value(
        value,
        name,
        'must be within the supported range',
      );
    }
  }

  static int _estimateTextTokens(String text) {
    var estimated = 0.0;
    var asciiRunLength = 0;

    void flushAsciiRun() {
      if (asciiRunLength == 0) return;
      estimated += asciiRunLength / 3;
      asciiRunLength = 0;
    }

    for (final rune in text.runes) {
      if (rune <= 0x7f) {
        asciiRunLength++;
        continue;
      }
      flushAsciiRun();
      estimated += _isHan(rune) ? 1.5 : 2;
    }
    flushAsciiRun();
    return estimated.ceil();
  }

  static bool _isHan(int rune) =>
      rune >= 0x3400 && rune <= 0x4dbf ||
      rune >= 0x4e00 && rune <= 0x9fff ||
      rune >= 0xf900 && rune <= 0xfaff ||
      rune >= 0x20000 && rune <= 0x2fa1f;

  static String _encodeParameters(Map<String, Object?> parameters) {
    try {
      return jsonEncode(parameters);
    } on Object {
      // Schemas used by the gateway are JSON values. Keep estimation useful if
      // a malformed caller supplies otherwise, while request validation fails.
      return parameters.toString();
    }
  }
}

/// Approximate input accounting with image cost kept visibly separate.
final class AgentContextEstimate {
  const AgentContextEstimate({
    required this.textTokens,
    required this.imageCount,
    required this.estimatedImageTokens,
  });

  final int textTokens;
  final int imageCount;
  final int estimatedImageTokens;

  int get estimatedInputTokens => textTokens + estimatedImageTokens;
  bool get imageTokenCostUnknown => imageCount > 0;
}

/// Result of whole-group context trimming; fixed messages stay caller-owned.
final class AgentContextTrimResult {
  AgentContextTrimResult({
    required List<List<ModelChatMessage>> retainedGroups,
    required this.removedGroupCount,
    required this.estimate,
    required this.maximumInputTokens,
    required this.messageCount,
    required this.maximumMessages,
    required this.fixedOverflow,
  }) : retainedGroups = List.unmodifiable(
         retainedGroups.map(
           (group) => List<ModelChatMessage>.unmodifiable(group),
         ),
       );

  final List<List<ModelChatMessage>> retainedGroups;
  final int removedGroupCount;
  final AgentContextEstimate estimate;
  final int maximumInputTokens;
  final int messageCount;
  final int maximumMessages;
  final bool fixedOverflow;

  bool get overflow =>
      estimate.estimatedInputTokens > maximumInputTokens ||
      messageCount > maximumMessages;
}
