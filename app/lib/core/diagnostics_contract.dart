// Wire vocabulary deliberately uses the fixed tool spellings.
// ignore_for_file: constant_identifier_names

import 'dart:convert';

import 'agent_parameter_issue.dart';

const diagnosticProtocolVersion = 'ustc-diagnostics-v1';
const diagnosticMaximumRecordBytes = 2048;
const diagnosticRetentionDays = 7;
const diagnosticSegmentBytes = 256 * 1024;
const diagnosticSegmentCount = 4;
const diagnosticMaximumExportRecords = 1000;
const diagnosticQueueLimit = 128;

enum DiagnosticsFailureCode { unavailable, closed, exportFailed }

final class DiagnosticsFailure implements Exception {
  const DiagnosticsFailure(this.code);
  final DiagnosticsFailureCode code;
  @override
  String toString() => 'DiagnosticsFailure(${code.name})';
}

enum DiagnosticEventName {
  applicationStart,
  applicationReady,
  applicationFailed,
  applicationClosing,
  applicationClosed,
  agentRunStarted,
  agentRunFinished,
  agentRunFailed,
  agentStopRequested,
  modelRequestStarted,
  modelRequestFinished,
  modelRequestFailed,
  toolStarted,
  toolFinished,
  toolRejected,
  approvalRequested,
  approvalDecided,
  historyMaintenance,
  modelConfiguration,
  sourceStage,
  maintenanceStarted,
  maintenanceFinished,
  maintenanceFailed,
  unexpectedFailure,
  logsExported,
  logsCleared,
}

enum DiagnosticTool {
  query_agenda,
  read_event,
  query_tasks,
  read_task,
  inspect_conflicts,
  search_knowledge,
  read_knowledge,
  search_courses,
  read_course,
  read_reviews,
  browse_campus,
  read_campus_article,
  propose_local_changes,
  propose_undo,
  find_free_slots,
  propose_planning_preferences,
  query_source_options,
  request_source_refresh,
  query_young_activities,
}

enum DiagnosticOutcome {
  started,
  complete,
  empty,
  truncated,
  unavailable,
  invalidRequest,
  stale,
  busy,
  failure,
  waitingForApproval,
  waitingForSchool,
  committed,
  rejected,
  cancelled,
  cleanupPending,
  interrupted,
  closed,
  recovery,
}

enum DiagnosticOperation {
  loadModels,
  verifyModel,
  deleteModelKey,
  changeModelConsent,
  clearHistory,
}

/// Fixed codes, shared vocabulary only; no exception strings or raw statuses.
enum DiagnosticCode {
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
  invalidRequest,
  staleReference,
  unavailable,
  cleanupPending,
  staleResult,
  incompleteSnapshot,
  invalidSnapshot,
  idempotencyConflict,
  sourceFailed,
  followUpPending,
  ownerConflict,
  unsafeDirectory,
  unsupportedPlatform,
  confirmationRequired,
  invalidIntent,
  manualRequired,
  pageStructureChanged,
  challengeRequired,
  contextUnavailable,
  noCredentials,
  alreadySubmitted,
  timedOut,
  projectionInvalid,
  proofInvalid,
  selfRouteUnbound,
  snapshotShape,
  eventCount,
  courseFields,
  duplicateCourseKey,
  examFields,
  duplicateExamKey,
  sealMetadataMismatch,
  identityUnverified,
  evidenceConflict,
  accountMismatch,
  identityMismatch,
  invalidCredential,
  studentContextMissing,
  identityHttp,
  identityMime,
  identityTooLarge,
  identitySchema,
  courseHttp,
  courseMime,
  courseTooLarge,
  courseSchema,
  indexHttp,
  indexMime,
  indexTooLarge,
  indexSchema,
  datumHttp,
  datumMime,
  datumTooLarge,
  datumSchema,
  examsHttp,
  examsMime,
  examsTooLarge,
  examsSchema,
  helperUnavailable,
  serviceWorkerControlled,
  semesterUnknown,
  identityChanged,
  stampChanged,
  nativeContext,
  mainRoute,
  contextLost,
  compiledScript,
  preparationTimedOut,
  unknown,
}

enum DiagnosticStage {
  startup,
  activation,
  shutdown,
  model,
  tools,
  approval,
  history,
  configuration,
  maintenance,
  jw,
  young,
  publicQuery,
  ui,
  export,
}

enum DiagnosticPhase {
  idle,
  opening,
  login,
  verifying,
  collecting,
  closing,
  committing,
  recovery,
  closed,
  preparing,
  cleaning,
  refreshing,
  loadingModels,
  generating,
  executingRead,
  waitingForApproval,
  waitingForSchool,
  settling,
  maintenance,
}

final class DiagnosticVersions {
  const DiagnosticVersions({
    this.application = 'unknown',
    this.schema = 0,
    this.tools = 'unknown',
    this.prompt = 'unknown',
    this.revision = 'unknown',
  });
  final String application, tools, prompt, revision;
  final int schema;
  Map<String, Object?> toSafeMap() => {
    'application':
        RegExp(r'^\d+\.\d+\.\d+(?:\+\d+)?$').hasMatch(application) &&
            application.length <= 32
        ? application
        : 'unknown',
    'schema': schema >= 0 && schema <= 1000 ? schema : 0,
    'tools': RegExp(r'^agent-tools-v\d{1,4}$').hasMatch(tools)
        ? tools
        : 'unknown',
    'prompt': RegExp(r'^ustc-student-agent-v\d{1,4}$').hasMatch(prompt)
        ? prompt
        : 'unknown',
    'revision': RegExp(r'^[a-f0-9]{40}$').hasMatch(revision)
        ? revision
        : 'unknown',
  };
}

/// A random diagnostic-only correlation ID, never a C3 owner/run/business ID.
final class DiagnosticTrace {
  DiagnosticTrace(this.value) {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(value)) {
      throw const FormatException('diagnostic_trace');
    }
  }
  final String value;
  @override
  String toString() => 'DiagnosticTrace';
}

final class DiagnosticEvent {
  const DiagnosticEvent({
    required this.name,
    this.trace,
    this.stage,
    this.phase,
    this.tool,
    this.operation,
    this.outcome,
    this.code,
    this.issue,
    this.elapsedMilliseconds,
    this.modelCalls,
    this.toolCalls,
    this.count,
    this.httpStatus,
  });
  final DiagnosticEventName name;
  final DiagnosticTrace? trace;
  final DiagnosticStage? stage;
  final DiagnosticPhase? phase;
  final DiagnosticTool? tool;
  final DiagnosticOperation? operation;
  final DiagnosticOutcome? outcome;
  final DiagnosticCode? code;
  final AgentParameterIssue? issue;
  final int? elapsedMilliseconds, modelCalls, toolCalls, count, httpStatus;
}

final class DiagnosticRecord {
  DiagnosticRecord({
    required this.atUtc,
    required this.event,
    this.sequence = 0,
    this.versions = const DiagnosticVersions(),
  }) {
    if (!atUtc.isUtc ||
        atUtc.year < 1 ||
        atUtc.year > 9998 ||
        sequence < 0 ||
        sequence > 9007199254740991) {
      throw const FormatException('diagnostic_time');
    }
    for (final n in [event.elapsedMilliseconds, event.count]) {
      if (n != null && (n < 0 || n > 2147483647)) {
        throw const FormatException('diagnostic_count');
      }
    }
    if (event.modelCalls != null &&
            (event.modelCalls! < 0 || event.modelCalls! > 1000000) ||
        event.toolCalls != null &&
            (event.toolCalls! < 0 || event.toolCalls! > 1000000) ||
        event.httpStatus != null &&
            (event.httpStatus! < 100 || event.httpStatus! > 599) ||
        event.issue?.changeIndex != null &&
            (event.issue!.changeIndex! < 0 || event.issue!.changeIndex! > 19)) {
      throw const FormatException('diagnostic_range');
    }
  }
  final DateTime atUtc;
  final DiagnosticEvent event;
  final int sequence;
  final DiagnosticVersions versions;
  Map<String, Object?> toMap() => {
    'version': diagnosticProtocolVersion,
    'atUtc': atUtc.toIso8601String(),
    'event': event.name.name,
    'sequence': sequence,
    'versions': versions.toSafeMap(),
    if (event.trace != null) 'trace': event.trace!.value,
    if (event.stage != null) 'stage': event.stage!.name,
    if (event.phase != null) 'phase': event.phase!.name,
    if (event.tool != null) 'tool': event.tool!.name,
    if (event.operation != null) 'operation': event.operation!.name,
    if (event.outcome != null) 'outcome': event.outcome!.name,
    if (event.code != null) 'code': event.code!.name,
    if (event.issue != null) 'validation': event.issue!.toSafeMap(),
    if (event.elapsedMilliseconds != null)
      'elapsedMs': event.elapsedMilliseconds,
    if (event.modelCalls != null) 'modelCalls': event.modelCalls,
    if (event.toolCalls != null) 'toolCalls': event.toolCalls,
    if (event.count != null) 'count': event.count,
    if (event.httpStatus != null) 'httpStatus': event.httpStatus,
  };

  String encode() {
    final text = jsonEncode(toMap());
    if (utf8.encode(text).length > diagnosticMaximumRecordBytes) {
      throw const FormatException('diagnostic_size');
    }
    return text;
  }

  /// Rebuild the whitelist projection; never copy arbitrary parsed log data.
  factory DiagnosticRecord.decode(String text) {
    if (utf8.encode(text).length > diagnosticMaximumRecordBytes) {
      throw const FormatException('diagnostic_size');
    }
    final raw = jsonDecode(text);
    if (raw is! Map<String, dynamic> ||
        raw['version'] != diagnosticProtocolVersion ||
        raw.keys.any(
          (k) => !const {
            'version',
            'sequence',
            'versions',
            'phase',
            'atUtc',
            'event',
            'trace',
            'stage',
            'tool',
            'operation',
            'outcome',
            'code',
            'validation',
            'elapsedMs',
            'modelCalls',
            'toolCalls',
            'count',
            'httpStatus',
          }.contains(k),
        ) ||
        raw['atUtc'] is! String) {
      throw const FormatException('diagnostic_shape');
    }
    T? optionalEnum<T extends Enum>(String key, List<T> values) {
      if (!raw.containsKey(key)) return null;
      final match = values.where((v) => v.name == raw[key]).firstOrNull;
      if (match == null) throw const FormatException('diagnostic_enum');
      return match;
    }

    int? number(String key) {
      if (!raw.containsKey(key)) return null;
      if (raw[key] is! int) throw const FormatException('diagnostic_number');
      return raw[key] as int;
    }

    AgentParameterIssue? issue;
    if (raw.containsKey('validation')) {
      final v = raw['validation'];
      if (v is! Map<String, dynamic> ||
          v.keys.any(
            (k) =>
                !const {'reason', 'field', 'action', 'changeIndex'}.contains(k),
          )) {
        throw const FormatException('diagnostic_validation');
      }
      final reason = AgentParameterReason.values
          .where((e) => e.name == v['reason'])
          .firstOrNull;
      final field = AgentParameterField.values
          .where((e) => e.name == v['field'])
          .firstOrNull;
      final action = AgentChangeType.values
          .where((e) => e.name == v['action'])
          .firstOrNull;
      if (reason == null ||
          field == null ||
          v.containsKey('action') && action == null ||
          v.containsKey('changeIndex') && v['changeIndex'] is! int) {
        throw const FormatException('diagnostic_validation');
      }
      issue = AgentParameterIssue(
        reason: reason,
        field: field,
        action: action,
        changeIndex: v['changeIndex'] as int?,
      );
    }
    final name = optionalEnum('event', DiagnosticEventName.values);
    if (name == null || raw.containsKey('trace') && raw['trace'] is! String) {
      throw const FormatException('diagnostic_event');
    }
    final parsedTime = DateTime.parse(raw['atUtc'] as String);
    if (!parsedTime.isUtc || parsedTime.toIso8601String() != raw['atUtc']) {
      throw const FormatException('diagnostic_time');
    }
    final versionMap = raw['versions'];
    DiagnosticVersions versions = const DiagnosticVersions();
    if (versionMap != null) {
      if (versionMap is! Map<String, dynamic> ||
          versionMap.keys.any(
            (k) => !const {
              'application',
              'schema',
              'tools',
              'prompt',
              'revision',
            }.contains(k),
          )) {
        throw const FormatException('diagnostic_versions');
      }
      versions = DiagnosticVersions(
        application: versionMap['application'] is String
            ? versionMap['application'] as String
            : 'unknown',
        schema: versionMap['schema'] is int ? versionMap['schema'] as int : 0,
        tools: versionMap['tools'] is String
            ? versionMap['tools'] as String
            : 'unknown',
        prompt: versionMap['prompt'] is String
            ? versionMap['prompt'] as String
            : 'unknown',
        revision: versionMap['revision'] is String
            ? versionMap['revision'] as String
            : 'unknown',
      );
    }
    return DiagnosticRecord(
      atUtc: parsedTime,
      sequence: number('sequence') ?? 0,
      versions: versions,
      event: DiagnosticEvent(
        name: name,
        trace: raw.containsKey('trace')
            ? DiagnosticTrace(raw['trace'] as String)
            : null,
        stage: optionalEnum('stage', DiagnosticStage.values),
        phase: optionalEnum('phase', DiagnosticPhase.values),
        tool: optionalEnum('tool', DiagnosticTool.values),
        operation: optionalEnum('operation', DiagnosticOperation.values),
        outcome: optionalEnum('outcome', DiagnosticOutcome.values),
        code: optionalEnum('code', DiagnosticCode.values),
        issue: issue,
        elapsedMilliseconds: number('elapsedMs'),
        modelCalls: number('modelCalls'),
        toolCalls: number('toolCalls'),
        count: number('count'),
        httpStatus: number('httpStatus'),
      ),
    );
  }
}

final class DiagnosticsView {
  const DiagnosticsView({
    this.available = false,
    this.dropped = 0,
    this.invalid = 0,
  });
  final bool available;
  final int dropped, invalid;
}

abstract interface class DiagnosticsPort {
  DiagnosticsView get diagnosticsView;
  DiagnosticTrace newTrace();

  /// Non-blocking, bounded, best-effort. Logging never changes a C3 result.
  void record(DiagnosticEvent event);
  Future<void> flush();

  /// Closed JSON bundle of validated recent records, never raw file bytes.
  Future<String> exportRecent();
  Future<void> clear();
  Future<void> close();
}

DiagnosticTool? diagnosticTool(String name) =>
    DiagnosticTool.values.where((v) => v.name == name).firstOrNull;
DiagnosticOutcome diagnosticOutcome(String value) => value == 'success'
    ? DiagnosticOutcome.complete
    : value == 'partial'
    ? DiagnosticOutcome.truncated
    : DiagnosticOutcome.values.where((v) => v.name == value).firstOrNull ??
          DiagnosticOutcome.failure;
DiagnosticCode diagnosticCode(String? value) =>
    DiagnosticCode.values.where((v) => v.name == value).firstOrNull ??
    DiagnosticCode.unknown;

DiagnosticPhase? diagnosticPhase(String value) =>
    DiagnosticPhase.values.where((v) => v.name == value).firstOrNull;
