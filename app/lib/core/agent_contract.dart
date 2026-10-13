import 'dart:typed_data';
import 'calendar_contract.dart';
import 'agent_parameter_issue.dart';

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
  imageRejected,
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
  executingRead,
  waitingForApproval,
  waitingForSchool,
  committing,
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
    this.evidence = const [],
    this.steps = const [],
    this.imageCount = 0,
    this.actions = const [],
  });
  final int id;
  final AgentMessageRole role;
  final String text;
  final AgentMessageStatus status;
  final DateTime createdAtUtc;
  final List<AgentEvidence> evidence;
  final List<AgentToolStep> steps;
  final int imageCount;
  final List<AgentActionView> actions;
  @override
  String toString() => 'AgentMessage';
}

enum AgentActionKind { localPlan, undo, sourceRefresh, planningPreferences }

enum AgentActionStatus { proposed, rejected, committed, interrupted, failed }

/// Server-created display record; history confers no approval or live target.
final class AgentActionView {
  AgentActionView({
    required this.id,
    required this.kind,
    required this.status,
    required this.title,
    required List<String> details,
    this.committedCount = 0,
    this.warning = '',
  }) : details = List.unmodifiable(details);
  final String id, title, warning;
  final AgentActionKind kind;
  final AgentActionStatus status;
  final List<String> details;
  final int committedCount;
  @override
  String toString() => 'AgentActionView';
}

/// Display-only provenance. This never grants a read, cursor or write permit.
final class AgentEvidence {
  const AgentEvidence({
    required this.id,
    required this.provider,
    required this.title,
    required this.observedAtUtc,
    required this.scope,
    required this.complete,
    this.articleUrl,
    this.materialUrl,
    this.publishedOn,
    this.updatedOn,
    this.revision,
    this.locator,
    this.sourceVersion,
    this.snippet = '',
    this.applicability = 'unknown',
    this.eventReference,
    this.taskReference,
  });
  final String id, provider, title, scope, snippet, applicability;
  final DateTime observedAtUtc;
  final bool complete;
  final String? articleUrl, materialUrl, publishedOn, updatedOn;
  final String? revision, locator, sourceVersion;

  /// Local navigation only. Excluded from model result metadata; C3 verifies
  /// current owner/epochs/versions again before opening business detail.
  final CalendarReference? eventReference;
  final TaskReference? taskReference;
  @override
  String toString() => 'AgentEvidence';
}

final class AgentToolStep {
  const AgentToolStep({required this.tool, required this.status});
  final String tool, status;
  @override
  String toString() => 'AgentToolStep';
}

/// Already normalized PNG selected by the human; no paths or remote URLs.
/// Bytes only live during the current question and are not conversation data.
final class AgentImage {
  AgentImage(Uint8List bytes) : bytes = Uint8List.fromList(bytes) {
    validate();
  }
  static const maximumCount = 3;
  static const maximumBytes = 3 * 1024 * 1024;
  static const maximumTotalBytes = 6 * 1024 * 1024;
  final Uint8List bytes;
  int get width => ByteData.sublistView(bytes, 16, 20).getUint32(0);
  int get height => ByteData.sublistView(bytes, 20, 24).getUint32(0);
  void validate() {
    const header = [137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length < 33 ||
        bytes.length > maximumBytes ||
        !List.generate(8, (i) => bytes[i] == header[i]).every((v) => v) ||
        bytes[12] != 73 ||
        bytes[13] != 72 ||
        bytes[14] != 68 ||
        bytes[15] != 82 ||
        width < 1 ||
        height < 1 ||
        width > 1536 ||
        height > 1536) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
  }

  @override
  String toString() => 'AgentImage';
}

/// Optional journal extension. M5.1-only fakes can still implement DataPort.
abstract interface class AgentRunJournalPort {
  Future<void> ensureAgentRun(AgentRunTicket ticket);
  Future<void> saveRunJournal(
    AgentRunTicket ticket, {
    required List<AgentEvidence> evidence,
    required List<AgentToolStep> steps,
    required int imageCount,
  });
}

abstract interface class AgentHistoryPagePort {
  Future<List<AgentMessage>> messagesBefore(
    String conversationId,
    int beforeId, {
    int limit = 100,
  });
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
    this.businessToolsEnabled = false,
    this.activeTool,
    this.toolCalls = 0,
    this.modelCalls = 0,
    this.pendingAction,
    this.discussionId,
    this.discussionDraft,
    this.parameterIssue,
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
  final bool businessToolsEnabled;
  final String? activeTool;
  final int toolCalls, modelCalls;
  final AgentActionView? pendingAction;
  final String? discussionId, discussionDraft;
  final AgentParameterIssue? parameterIssue;
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
