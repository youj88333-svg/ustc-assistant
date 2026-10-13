import 'dart:typed_data';

enum AgentFailureCode {
  invalidInput,
  secretDetected,
  consentRequired,
  keyRequired,
  modelRequired,
  busy,
  staleContext,
  maintenance,
  ownershipLost,
  storageFailed,
  protectionFailed,
  unauthorized,
  forbidden,
  rateLimited,
  networkFailed,
  timeout,
  protocol,
  redirectRejected,
  resourceLimit,
  cancelled,
  closed,
  toolUnavailable,
}

final class AgentFailure implements Exception {
  const AgentFailure(this.code);
  final AgentFailureCode code;
  @override
  String toString() => 'AgentFailure(${code.name})';
}

enum ModelCapability { unverified, chatOnly, toolReady }

enum AgentPhase {
  idle,
  loadingModels,
  verifying,
  generating,
  settling,
  recovery,
  maintenance,
  closed,
}

enum AgentMessageRole { user, assistant }

enum AgentMessageStatus { streaming, complete, interrupted, cancelled, failed }

/// Local C3 authority. Never serialized as model input or diagnostics.
final class AgentAuthority {
  const AgentAuthority({
    required this.owner,
    required this.resetEpoch,
    required this.historyEpoch,
    required this.configRevision,
    this.requestEpoch = 0,
  });
  final String owner;
  final int resetEpoch, historyEpoch, configRevision, requestEpoch;
  @override
  bool operator ==(Object other) =>
      other is AgentAuthority &&
      owner == other.owner &&
      resetEpoch == other.resetEpoch &&
      historyEpoch == other.historyEpoch &&
      configRevision == other.configRevision &&
      requestEpoch == other.requestEpoch;
  @override
  int get hashCode => Object.hash(
    owner,
    resetEpoch,
    historyEpoch,
    configRevision,
    requestEpoch,
  );
  @override
  String toString() => 'AgentAuthority';
}

final class AgentCapabilityReport {
  const AgentCapabilityReport({
    this.text = false,
    this.streaming = false,
    this.toolCall = false,
    this.toolResult = false,
    this.failure,
  });
  final bool text, streaming, toolCall, toolResult;
  final AgentFailureCode? failure;
  ModelCapability get capability => text && streaming
      ? (toolCall && toolResult
            ? ModelCapability.toolReady
            : ModelCapability.chatOnly)
      : ModelCapability.unverified;
}

final class AgentSettingsSnapshot {
  AgentSettingsSnapshot({
    required this.authority,
    this.keySaved = false,
    this.consent = false,
    this.modelId,
    List<String> modelIds = const [],
    this.report = const AgentCapabilityReport(),
  }) : modelIds = List.unmodifiable(modelIds);
  final AgentAuthority authority;
  final bool keySaved, consent;
  final String? modelId;
  final List<String> modelIds;
  final AgentCapabilityReport report;
  @override
  String toString() => 'AgentSettingsSnapshot';
}

abstract interface class ModelCredentialProtector {
  String get mechanism;
  Future<Uint8List> protect(Uint8List plaintext, {required String purpose});
  Future<Uint8List> unprotect(Uint8List ciphertext, {required String purpose});
}

/// Single-consumption, non-serializable model request outlet; consumer wipes.
final class ModelSecretLease {
  ModelSecretLease(Uint8List bytes) : _bytes = bytes;
  Uint8List? _bytes;
  bool get isAvailable => _bytes != null;
  Uint8List take() {
    final bytes = _bytes;
    if (bytes == null) throw const AgentFailure(AgentFailureCode.keyRequired);
    _bytes = null;
    return bytes;
  }

  void revoke() {
    _bytes?.fillRange(0, _bytes!.length, 0);
    _bytes = null;
  }

  @override
  String toString() => 'ModelSecretLease';
}

final class AgentConversation {
  const AgentConversation({
    required this.id,
    required this.title,
    required this.updatedAtUtc,
  });
  final String id, title;
  final DateTime updatedAtUtc;
  @override
  String toString() => 'AgentConversation';
}

final class AgentMessage {
  const AgentMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.status,
    required this.createdAtUtc,
  });
  final int id;
  final AgentMessageRole role;
  final String text;
  final AgentMessageStatus status;
  final DateTime createdAtUtc;
  @override
  String toString() => 'AgentMessage';
}

final class AgentRunTicket {
  const AgentRunTicket({
    required this.authority,
    required this.runId,
    required this.conversationId,
    required this.conversationGeneration,
    required this.runGeneration,
    required this.assistantMessageId,
  });
  final AgentAuthority authority;
  final String runId, conversationId;
  final int conversationGeneration, runGeneration, assistantMessageId;
  @override
  String toString() => 'AgentRunTicket';
}

final class AgentHistoryIntent {
  const AgentHistoryIntent({required this.operationId, this.conversationId});
  final String operationId;
  final String? conversationId;
  @override
  String toString() => 'AgentHistoryIntent';
}

abstract interface class AgentDataPort {
  Stream<int> get changes;
  Future<void> initializeAgent();
  Future<AgentSettingsSnapshot> inspectAgent();
  Future<void> saveModelConfiguration(
    AgentAuthority expected, {
    required String modelId,
    required List<String> modelIds,
    required AgentCapabilityReport report,
    required bool consent,
    Uint8List? key,
  });
  Future<ModelSecretLease> leaseModelKey(AgentAuthority expected);
  Future<void> invalidateModelWork(AgentAuthority expected);
  Future<void> deleteModelKey(AgentAuthority expected);
  Future<void> setModelConsent(AgentAuthority expected, bool consent);
  Future<List<AgentConversation>> conversations();
  Future<String> createConversation();
  Future<List<AgentMessage>> messages(String conversationId);
  Future<AgentRunTicket> beginRun(
    AgentAuthority expected,
    String conversationId,
    String text,
  );
  Future<void> saveAssistant(AgentRunTicket ticket, String text);
  Future<void> finishRun(AgentRunTicket ticket, AgentMessageStatus status);
  Future<void> cancelRun(AgentRunTicket ticket);
  Future<AgentHistoryIntent> beginClearHistory(
    AgentAuthority expected, {
    String? conversationId,
  });
  Future<void> completeClearHistory(AgentHistoryIntent intent);
}

/// Safe UI projection, shared without Flutter dependencies in C4.
final class AgentRuntimeView {
  AgentRuntimeView({
    this.phase = AgentPhase.idle,
    this.settings,
    List<String> availableModels = const [],
    List<AgentConversation> conversations = const [],
    List<AgentMessage> messages = const [],
    this.conversationId,
    this.failure,
    this.report = const AgentCapabilityReport(),
    this.historyTruncated = false,
    this.pendingKeyProvided = false,
  }) : availableModels = List.unmodifiable(availableModels),
       conversations = List.unmodifiable(conversations),
       messages = List.unmodifiable(messages);
  final AgentPhase phase;
  final AgentSettingsSnapshot? settings;
  final List<String> availableModels;
  final List<AgentConversation> conversations;
  final List<AgentMessage> messages;
  final String? conversationId;
  final AgentFailureCode? failure;
  final AgentCapabilityReport report;
  final bool historyTruncated, pendingKeyProvided;
  bool get busy => phase != AgentPhase.idle && phase != AgentPhase.closed;
  bool get canSend =>
      phase == AgentPhase.idle &&
      settings?.keySaved == true &&
      settings?.consent == true &&
      settings?.modelId != null &&
      settings?.report.capability != ModelCapability.unverified;
  @override
  String toString() => 'AgentRuntimeView';
}
