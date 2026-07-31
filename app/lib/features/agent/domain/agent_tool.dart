import '../../../core/time/beijing_clock.dart';
import '../application/cancellation_signal.dart';
import '../application/run_reference_store.dart';
import 'agent_models.dart';

/// The outcome of a single read-only tool execution.
///
/// Tools produce raw payloads; the registry (not the tool) is responsible for
/// running the payload through `OutboundPrivacyFilter.sanitizeToolPayload`
/// before constructing the [AgentToolResult] that reaches the model. This keeps
/// the allowlist boundary in one place and ensures tools never have to know
/// about the protected account.
///
/// [references] are run-local references the tool bound during execution (e.g.
/// a schedule it fetched). They are surfaced to the UI as source references
/// and resolvable within the same run only; the model receives opaque `ref_*`
/// tokens, never raw local ids.
class AgentToolResult {
  const AgentToolResult({
    this.status = AgentToolStatus.success,
    this.payload = const <String, Object?>{},
    this.references = const <AgentToolReference>[],
    this.errorCode,
    this.userAction,
    this.pendingInvocation,
  });

  /// Whether the tool call succeeded. Error results are still folded into the
  /// conversation as `tool_result` blocks (with `is_error: true`) so the model
  /// can react, but they carry no raw payload.
  final AgentToolStatus status;

  /// The sanitized, model-safe payload. For a successful call this is the
  /// allowlisted DTO; for an error call this is empty.
  final Map<String, Object?> payload;

  /// Run-local references bound by the tool. Surfaced to the UI as source
  /// references; never persisted with the raw local id attached.
  final List<AgentToolReference> references;

  /// A short, safe error code for error results (e.g. `tool_not_allowed`,
  /// `tool_execution_failed`). `null` on success.
  final String? errorCode;

  /// Local-only metadata for a tool invocation that is waiting on the user.
  /// The opaque handle is never encoded into an LLM tool result.
  final AgentUserAction? userAction;

  /// The still-active invocation that will produce the terminal tool result.
  /// It owns the source stream while the run is paused.
  final AgentPendingToolInvocation? pendingInvocation;
}

/// The status of a tool execution outcome.
enum AgentToolStatus { success, error, needsUserAction }

enum AgentUserActionType { youngLogin }

class AgentUserAction {
  const AgentUserAction({
    required this.type,
    required this.opaqueHandle,
  });

  final AgentUserActionType type;
  final String opaqueHandle;

  AgentUserActionMetadata get metadata =>
      AgentUserActionMetadata(type: type);
}

class AgentUserActionMetadata {
  const AgentUserActionMetadata({required this.type});

  final AgentUserActionType type;
}

class AgentPendingToolInvocation {
  const AgentPendingToolInvocation({
    required this.result,
    required this.cancel,
  });

  final Future<AgentToolResult> result;
  final Future<void> Function() cancel;
}

/// A run-local reference bound by a tool, pairing the opaque `ref_*` token
/// (what the model sees) with the underlying kind and local id (what the tool
/// resolves internally). The [localId] is kept here so the UI can render a
/// source citation, but it is never sent to the model in this shape: only the
/// [ref] token crosses that boundary.
class AgentToolReference {
  const AgentToolReference({
    required this.kind,
    required this.ref,
    required this.localId,
  });

  /// The reference category, e.g. `schedule`, `event`, `catalog`. Resolution
  /// checks both the run and the kind, so a `ref` bound for `schedule` cannot
  /// be resolved as `event`.
  final String kind;

  /// The opaque, unguessable run-local token (`ref_*`) handed to the model.
  final String ref;

  /// The underlying local id (e.g. a DB row id). Never sent to the model.
  final String localId;
}

/// A read-only tool the Agent can call.
///
/// Concrete tools arrive in later tasks (6, 9). The registry holds tool
/// instances injected by the caller; this class defines only the contract.
/// Implementations MUST be pure Dart (no `dart:io`, no DPAPI, no Windows APIs)
/// and MUST NOT retain the API key — they never receive one.
abstract interface class AgentTool {
  /// The tool name, as declared to the model and used for dispatch.
  String get name;

  /// A human-readable description, surfaced to the model as the tool's
  /// purpose.
  String get description;

  /// The JSON Schema describing the tool's arguments.
  Map<String, Object?> get inputSchema;

  /// Executes the tool with the parsed [arguments] and the scoped [context].
  ///
  /// The tool returns a raw payload; the registry sanitizes it before it
  /// reaches the model. Tools MUST NOT throw for ordinary failure paths —
  /// return an [AgentToolResult] with [AgentToolStatus.error] instead — but
  /// the registry contains any thrown exception as a `tool_execution_failed`
  /// error so a buggy tool can never crash the run.
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  );
}

/// The scoped context handed to each tool execution.
///
/// Carries everything a read-only tool needs and nothing it must not have: the
/// account id and run id for ownership scoping, a Beijing clock for
/// timestamps, the cancellation signal so a long tool can abort gracefully,
/// and the run-local reference store. There is deliberately NO API key field
/// — tools never see credentials.
class AgentToolContext {
  const AgentToolContext({
    required this.accountId,
    required this.runId,
    required this.clock,
    required this.cancellation,
    required this.references,
  });

  /// The account owning this run. Tools must scope any DB access to this
  /// account.
  final String accountId;

  /// The id of the current run. Used to bind run-local references.
  final String runId;

  /// The Beijing clock for all timestamps. Tools MUST use this rather than
  /// `DateTime.now()` so timestamps stay testable and timezone-correct.
  final BeijingClock clock;

  /// The cancellation signal for the owning run. Long-running tools should
  /// poll [CancellationSignal.isCancelled] and abort gracefully when set.
  final CancellationSignal cancellation;

  /// The run-local reference store. Tools bind raw local ids here to obtain
  /// opaque `ref_*` tokens for the model.
  final RunReferenceStore references;
}

// ---------------------------------------------------------------------------
// View state emitted to the UI.
// ---------------------------------------------------------------------------

/// A collapsed, model-safe summary of a single tool invocation within a run,
/// surfaced to the UI.
class AgentToolSummary {
  const AgentToolSummary({
    required this.toolName,
    required this.status,
    this.safeLabel,
  });

  /// The tool's registered name.
  final String toolName;

  /// The outcome of the tool call.
  final AgentToolStatus status;

  /// A short, safe, human-readable label for the call (no user text, no raw
  /// results). May be null.
  final String? safeLabel;
}

/// A source reference surfaced in the final run view, derived from the
/// [AgentToolReference]s tools bound during the run.
///
/// NOTE: as of Task 7 this is reserved for PUBLIC citations only — references
/// to external data the tools surfaced (e.g. `campus_entry` from
/// `search_campus_catalog`/`read_campus_detail`). Local event/task refs are
/// NOT forwarded here: they would spam the UI with one inert chip per event.
/// Local navigation is instead surfaced via [AgentLocalAction] (one per data
/// domain, deduplicated), which the chat page renders as a clickable
/// `ActionChip` routing to the relevant management screen.
class AgentSourceReference {
  const AgentSourceReference({required this.kind, required this.ref});

  /// The reference category (e.g. `campus_entry`). Local kinds (`event`,
  /// `task`, `planblock`, `schedule`) are no longer forwarded here by the
  /// session service.
  final String kind;

  /// The opaque `ref_*` token. The raw local id is intentionally NOT carried
  /// here — the UI shows the citation, the run resolves the ref.
  final String ref;
}

/// A local navigation action the UI can route to a management screen.
///
/// The session service builds a DEDUPLICATED set of these from which local
/// data-domain tools actually ran and returned data during a run — one
/// [AgentLocalAction.schedule] when any schedule tool produced data, one
/// [AgentLocalAction.tasks] when any task tool produced data. The chat page
/// renders these as `ActionChip`s (clickable) that push the corresponding
/// route via GoRouter, in contrast to [AgentSourceReference] citations which
/// remain inert `Chip`s.
///
/// Carries NO raw local ids and NO `ref_*` tokens: it is a pure navigation
/// intent, so it is always safe to surface to the UI and never leaks a local
/// id across the model boundary.
class AgentLocalAction {
  const AgentLocalAction({required this.kind});

  /// The navigation target. `schedule` routes to `/schedule`; `tasks` routes
  /// to the task management screen.
  final AgentLocalActionKind kind;

  /// A schedule-domain action: emitted when any of `get_schedule`,
  /// `get_event_details`, `get_free_time`, `get_conflicts`, or
  /// `get_pending_event_reviews` ran and returned data.
  static const schedule = AgentLocalAction(kind: AgentLocalActionKind.schedule);

  /// A task-domain action: emitted when any of `get_tasks`, `get_task_details`,
  /// `get_plan_blocks`, or `get_pending_planblock_reviews` ran and returned
  /// data.
  static const tasks = AgentLocalAction(kind: AgentLocalActionKind.tasks);

  @override
  bool operator ==(Object other) =>
      other is AgentLocalAction && other.kind == kind;

  @override
  int get hashCode => kind.hashCode;

  @override
  String toString() => 'AgentLocalAction(${kind.name})';
}

/// The navigation target for an [AgentLocalAction].
enum AgentLocalActionKind { schedule, tasks }

/// The immutable run view state emitted by `AgentSessionService.send`.
///
/// This is the view model the UI (Task 11) consumes. It is pure Dart and
/// platform-free so tests can assert state transitions without widgets. The
/// service emits a new instance on every transition: streaming text deltas,
/// tool starts/stops, and the terminal state.
class AgentRunViewState {
  const AgentRunViewState({
    required this.runId,
    required this.state,
    this.text = '',
    this.toolSummaries = const <AgentToolSummary>[],
    this.sourceReferences = const <AgentSourceReference>[],
    this.localActions = const <AgentLocalAction>[],
    this.errorCode,
    this.userAction,
  });

  /// The run this state belongs to.
  final String runId;

  /// The current run state. Transitions: `running` -> (`running` with tool
  /// summaries) -> `completed` | `failed` | `cancelled`.
  final AgentRunState state;

  /// The assistant text streamed so far this run. Accumulated across text
  /// deltas and preserved on cancel/failure.
  final String text;

  /// Collapsed tool summaries, appended as each tool completes.
  final List<AgentToolSummary> toolSummaries;

  /// PUBLIC citations only (e.g. `campus_entry` from external catalog tools).
  /// Local event/task refs are NOT forwarded here — they would spam the UI
  /// with one inert chip per event. Local navigation is via [localActions].
  final List<AgentSourceReference> sourceReferences;

  /// Deduplicated local navigation actions for the run (e.g. one
  /// [AgentLocalAction.schedule] if schedule tools ran, one
  /// [AgentLocalAction.tasks] if task tools ran). The chat page renders these
  /// as clickable `ActionChip`s routing to the relevant management screen.
  final List<AgentLocalAction> localActions;

  /// A safe error code on failure, e.g. `upstream_error`. `null` otherwise.
  final String? errorCode;

  /// Safe UI metadata for a paused action. Opaque source handles stay inside
  /// the session service and are not exposed to widgets or the model.
  final AgentUserActionMetadata? userAction;

  /// Returns a copy with the provided fields overridden.
  AgentRunViewState copyWith({
    AgentRunState? state,
    String? text,
    List<AgentToolSummary>? toolSummaries,
    List<AgentSourceReference>? sourceReferences,
    List<AgentLocalAction>? localActions,
    String? errorCode,
    AgentUserActionMetadata? userAction,
    bool clearUserAction = false,
  }) => AgentRunViewState(
    runId: runId,
    state: state ?? this.state,
    text: text ?? this.text,
    toolSummaries: toolSummaries ?? this.toolSummaries,
    sourceReferences: sourceReferences ?? this.sourceReferences,
    localActions: localActions ?? this.localActions,
    errorCode: errorCode ?? this.errorCode,
    userAction: clearUserAction ? null : userAction ?? this.userAction,
  );
}
