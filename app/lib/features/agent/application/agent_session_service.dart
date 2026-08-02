import 'dart:async';
import 'dart:convert';

import '../../../core/database/app_database.dart';
import '../../../core/time/beijing_clock.dart';
import '../data/drift_chat_repository.dart';
import '../domain/agent_models.dart';
import '../domain/agent_tool.dart';
import '../domain/llm_protocol.dart';
import 'agent_context_builder.dart';
import 'agent_grounding_policy.dart';
import 'agent_tool_invocation_summary.dart';
import 'agent_tool_registry.dart';
import 'assistant_text_filter.dart';
import 'cancellation_signal.dart';
import 'outbound_privacy_filter.dart';
import 'run_reference_store.dart';
import 'tool_call_fingerprint.dart';

/// Returns the last element matching [test], or `null` if none match.
extension _LastWhereOrNull<T> on Iterable<T> {
  T? lastWhereOrNull(bool Function(T element) test) {
    T? result;
    var found = false;
    for (final element in this) {
      if (test(element)) {
        result = element;
        found = true;
      }
    }
    return found ? result : null;
  }
}

typedef AgentUserActionResumeCallback =
    Future<void> Function({
      required String accountId,
      required AgentUserAction action,
    });

typedef WriteConfirmationResumerCallback =
    Future<AgentToolResult> Function({
      required String handle,
      required bool approve,
      required bool remember,
    });

class _PausedRun {
  _PausedRun({
    required this.accountId,
    required this.runId,
    required this.action,
    required this.pendingInvocation,
    required this.conversation,
    required this.toolUseId,
    required this.references,
    required this.signal,
  });

  final String accountId;
  final String runId;
  final AgentUserAction action;
  final AgentPendingToolInvocation pendingInvocation;
  final List<LlmMessage> conversation;
  final String toolUseId;
  final RunReferenceStore references;
  final CancellationSignal signal;
  bool resumeStarted = false;
}

class _ActiveRun {
  _ActiveRun({required this.signal});

  final CancellationSignal signal;
  String? runId;
}

/// Orchestrates the bounded, read-only Agent run loop.
///
/// The session service sits between the user and the LLM. For each [send] it:
/// 1. Inspects the user text through the privacy filter (rejects secrets
///    before any persistence or network I/O).
/// 2. Persists the run and the user message (in that order, before network).
/// 3. Builds the outbound request from history + summary + current text +
///    tool declarations.
/// 4. Streams the model response, persisting an assistant draft and emitting
///    view states.
/// 5. Collects complete `tool_use` blocks; for each, validates the tool is
///    registered, executes it via the registry (which sanitizes the payload),
///    and appends a `tool_result` block for the next turn.
/// 6. Continues until the model emits a final text turn with no tool calls, or
///    a budget/stop/error boundary is hit.
/// 7. Attempts exactly one aggregated `ActionLog` (source `agent`, action type
///    `read_only_run`) with a tool-category count and no user text. A log write
///    failure cannot rewrite an already-published business result.
/// 8. After a successful run, schedules a tool-disabled summary request when
///    `AgentContextBuilder.needsSummary` is true; summary failure is swallowed.
///
/// Hard limits (per run): 8 model calls, 12 tool calls. Exceeding either
/// hard-stops the run in a safe terminal state — a new call is never started
/// past the limit.
///
/// Stop semantics: once [cancel] fires mid-loop, the in-flight stream is
/// allowed to drain, but no new model call is started; the run is marked
/// `cancelled` and streamed draft text is preserved.
class AgentSessionService {
  AgentSessionService({
    required this._chatRepository,
    required this._database,
    required this._provider,
    required this._contextBuilder,
    required this._privacyFilter,
    required this._registry,
    required this._clock,
    required this._model,
    required this._apiKeyProvider,
    this.userActionResumer,
    this.writeConfirmationResumer,
    this._groundingPolicy = const AgentGroundingPolicy(),
  });

  final DriftChatRepository _chatRepository;
  final AppDatabase _database;
  final LlmProvider _provider;
  final AgentContextBuilder _contextBuilder;
  final OutboundPrivacyFilter _privacyFilter;
  final AgentToolRegistry _registry;
  final BeijingClock _clock;
  final String _model;
  final Future<String> Function({required String accountId}) _apiKeyProvider;
  final AgentUserActionResumeCallback? userActionResumer;
  final WriteConfirmationResumerCallback? writeConfirmationResumer;

  /// Conservative classifier that decides whether the current user text is an
  /// explicit operation that must be backed by real tool calls.
  final AgentGroundingPolicy _groundingPolicy;

  /// Hard limit on model calls per run.
  static const int maxModelCalls = 8;

  /// Hard limit on tool calls per run.
  static const int maxToolCalls = 12;

  /// Active user runs keyed by account. Cleanup compares the exact run object
  /// so a late summary from an older run cannot clear a newer run.
  final Map<String, _ActiveRun> _activeRuns = {};
  bool _disposed = false;
  final Map<({String accountId, String runId}), _PausedRun> _pausedRuns = {};

  /// Sends [userText] as a new user turn and runs the Agent loop.
  ///
  /// Emits [AgentRunViewState]s as the run progresses. The stream completes
  /// when the run reaches a terminal state (completed, failed, or cancelled).
  Stream<AgentRunViewState> send({
    required String accountId,
    required String userText,
  }) {
    final controller = StreamController<AgentRunViewState>(sync: true);
    final signal = CancellationSignal();
    final active = _ActiveRun(signal: signal);
    var terminalEmitted = false;

    () async {
      try {
        if (_disposed) {
          controller.add(
            const AgentRunViewState(
              runId: '',
              state: AgentRunState.failed,
              errorCode: 'service_disposed',
            ),
          );
          terminalEmitted = true;
          return;
        }
        if (_activeRuns.containsKey(accountId)) {
          controller.add(
            const AgentRunViewState(
              runId: '',
              state: AgentRunState.failed,
              errorCode: 'run_already_active',
            ),
          );
          terminalEmitted = true;
          return;
        }
        _activeRuns[accountId] = active;
        await _runLoop(
          controller: controller,
          accountId: accountId,
          userText: userText,
          signal: signal,
          onRunStarted: (runId) => active.runId = runId,
          onTerminalEmitted: () {
            terminalEmitted = true;
            _releaseActive(accountId, active);
          },
        );
      } catch (_) {
        if (!terminalEmitted && !controller.isClosed) {
          controller.add(
            const AgentRunViewState(
              runId: '',
              state: AgentRunState.failed,
              errorCode: 'runtime_error',
            ),
          );
        }
      } finally {
        _releaseActive(accountId, active);
        await controller.close();
      }
    }();
    return controller.stream;
  }

  /// Cancels the in-flight run for [accountId], if any.
  ///
  /// The in-flight model stream is allowed to drain, but no new model call is
  /// started; the run terminates as `cancelled` with any streamed draft text
  /// preserved.
  Future<void> cancel({required String accountId}) async {
    _activeRuns[accountId]?.signal.cancel();
    await _cancelPausedRuns((paused) => paused.accountId == accountId);
  }

  /// Retries the last user turn as a brand-new run.
  ///
  /// The failed run's record is never overwritten; a new run is created and
  /// linked only through local metadata (history). The most recent completed
  /// user message is reused as the prompt.
  Stream<AgentRunViewState> retryLast({required String accountId}) {
    final controller = StreamController<AgentRunViewState>(sync: true);
    final signal = CancellationSignal();
    final active = _ActiveRun(signal: signal);
    var terminalEmitted = false;
    () async {
      try {
        if (_disposed) {
          controller.add(
            const AgentRunViewState(
              runId: '',
              state: AgentRunState.failed,
              errorCode: 'service_disposed',
            ),
          );
          terminalEmitted = true;
          return;
        }
        if (_activeRuns.containsKey(accountId)) {
          controller.add(
            const AgentRunViewState(
              runId: '',
              state: AgentRunState.failed,
              errorCode: 'run_already_active',
            ),
          );
          terminalEmitted = true;
          return;
        }
        _activeRuns[accountId] = active;
        // Find the most recent completed user message to replay.
        final history = await _chatRepository.recentMessages(
          accountId,
          limit: 200,
        );
        final lastUser = history.lastWhereOrNull(
          (m) =>
              m.role == ChatRole.user && m.state == ChatMessageState.completed,
        );
        if (lastUser == null) {
          controller.add(
            const AgentRunViewState(
              runId: '',
              state: AgentRunState.failed,
              errorCode: 'nothing_to_retry',
            ),
          );
          terminalEmitted = true;
          return;
        }
        await _runLoop(
          controller: controller,
          accountId: accountId,
          userText: lastUser.content,
          signal: signal,
          excludeHistoryMessageId: lastUser.id,
          onRunStarted: (runId) => active.runId = runId,
          onTerminalEmitted: () {
            terminalEmitted = true;
            _releaseActive(accountId, active);
          },
        );
      } catch (_) {
        if (!terminalEmitted && !controller.isClosed) {
          controller.add(
            const AgentRunViewState(
              runId: '',
              state: AgentRunState.failed,
              errorCode: 'runtime_error',
            ),
          );
        }
      } finally {
        _releaseActive(accountId, active);
        await controller.close();
      }
    }();
    return controller.stream;
  }

  /// Resumes a run that paused awaiting a user action.
  ///
  /// This is the hook for the Young-enrolment login-pause flow (Task 9). For
  /// Task 5 it provides a minimal correct behavior: if there is no paused run,
  /// it returns a failed state. The full Young integration lands in Task 9.
  Stream<AgentRunViewState> resumeUserAction({
    required String accountId,
    required String runId,
    Map<String, Object?>? userActionPayload,
  }) {
    final controller = StreamController<AgentRunViewState>(sync: true);
    () async {
      try {
        final key = (accountId: accountId, runId: runId);
        final paused = _pausedRuns[key];
        if (paused == null) {
          controller.add(
            AgentRunViewState(
              runId: runId,
              state: AgentRunState.failed,
              errorCode: 'paused_run_not_found',
            ),
          );
          return;
        }
        if (paused.resumeStarted) {
          controller.add(
            AgentRunViewState(
              runId: runId,
              state: AgentRunState.failed,
              errorCode: 'resume_already_started',
            ),
          );
          return;
        }
        paused.resumeStarted = true;
        final resume = userActionResumer;
        if (resume == null) {
          await _cancelPausedRun(paused);
          controller.add(
            AgentRunViewState(
              runId: runId,
              state: AgentRunState.failed,
              errorCode: 'resume_unavailable',
            ),
          );
          return;
        }
        try {
          await resume(accountId: accountId, action: paused.action);
          await paused.pendingInvocation.result;
        } catch (_) {
          await _cancelPausedRun(paused);
        }
      } finally {
        await controller.close();
      }
    }();
    return controller.stream;
  }

  /// 用户对写确认卡做出决定：批准/拒绝 + 是否"此类型以后不再确认"。
  ///
  /// 完成挂起的写提案并恢复会话循环。返回的流在恢复完成时关闭；真正的
  /// 运行状态由 `send` 的流继续发出。
  Stream<AgentRunViewState> confirmWriteProposal({
    required String accountId,
    required String runId,
    required bool approve,
    required bool remember,
  }) {
    final controller = StreamController<AgentRunViewState>(sync: true);
    () async {
      try {
        final key = (accountId: accountId, runId: runId);
        final paused = _pausedRuns[key];
        if (paused == null ||
            paused.action.type != AgentUserActionType.writeConfirmation) {
          controller.add(
            AgentRunViewState(
              runId: runId,
              state: AgentRunState.failed,
              errorCode: 'paused_run_not_found',
            ),
          );
          return;
        }
        if (paused.resumeStarted) {
          controller.add(
            AgentRunViewState(
              runId: runId,
              state: AgentRunState.failed,
              errorCode: 'resume_already_started',
            ),
          );
          return;
        }
        paused.resumeStarted = true;
        final resumer = writeConfirmationResumer;
        if (resumer == null) {
          await _cancelPausedRun(paused);
          controller.add(
            AgentRunViewState(
              runId: runId,
              state: AgentRunState.failed,
              errorCode: 'resume_unavailable',
            ),
          );
          return;
        }
        try {
          final result = await resumer(
            handle: paused.action.opaqueHandle,
            approve: approve,
            remember: remember,
          );
          if (result.errorCode == 'confirmation_not_found') {
            // 句柄已丢失（store 条目已消失）：挂起的 pendingInvocation 是倒挂的
            // orphan，永远无法自行完成。立即取消该暂停运行、发出失败状态，
            // 并且不 await 这个注定挂起的 future。
            await _cancelPausedRun(paused);
            controller.add(
              AgentRunViewState(
                runId: runId,
                state: AgentRunState.failed,
                errorCode: 'confirmation_not_found',
              ),
            );
            return;
          }
          await paused.pendingInvocation.result;
        } catch (_) {
          await _cancelPausedRun(paused);
        }
      } finally {
        await controller.close();
      }
    }();
    return controller.stream;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final active in _activeRuns.values.toList()) {
      active.signal.cancel();
    }
    await _cancelPausedRuns((_) => true);
  }

  void _releaseActive(String accountId, _ActiveRun active) {
    final current = _activeRuns[accountId];
    if (identical(current, active) && current?.runId == active.runId) {
      _activeRuns.remove(accountId);
    }
  }

  Future<void> _cancelPausedRuns(
    bool Function(_PausedRun paused) shouldCancel,
  ) async {
    final matches = _pausedRuns.values.where(shouldCancel).toList();
    for (final paused in matches) {
      await _cancelPausedRun(paused);
    }
  }

  Future<void> _cancelPausedRun(_PausedRun paused) async {
    final key = (accountId: paused.accountId, runId: paused.runId);
    if (identical(_pausedRuns[key], paused)) {
      _pausedRuns.remove(key);
    }
    paused.signal.cancel();
    await _cancelPendingInvocation(paused.pendingInvocation);
  }

  Future<void> _cancelPendingInvocation(
    AgentPendingToolInvocation pendingInvocation,
  ) async {
    try {
      await pendingInvocation.cancel();
    } catch (_) {
      // The owning run receives a bounded terminal result from the invocation.
    }
  }

  // --- The loop ---------------------------------------------------------

  Future<void> _runLoop({
    required StreamController<AgentRunViewState> controller,
    required String accountId,
    required String userText,
    required CancellationSignal signal,
    required void Function(String runId) onRunStarted,
    required void Function() onTerminalEmitted,
    String? excludeHistoryMessageId,
  }) async {
    // 1. Privacy-inspect the user text BEFORE any persistence or I/O.
    final decision = _privacyFilter.inspectUserText(userText);
    if (!decision.accepted) {
      controller.add(
        AgentRunViewState(
          runId: '',
          state: AgentRunState.failed,
          errorCode: 'privacy_rejected',
        ),
      );
      onTerminalEmitted();
      // Rejected text is not persisted and not logged as a read_only_run.
      return;
    }

    // 2. Persist the run before network I/O, then fetch the PRIOR-turn history
    //    BEFORE appending the current user message. AgentContextBuilder.build's
    //    contract is: `history` = prior turns, `currentUserText` = the new
    //    turn (which it appends as the final user message). If we appended the
    //    user message first, recentMessages would include it and build() would
    //    duplicate the current question in the first model request.
    final runId = await _chatRepository.startRun(
      accountId: accountId,
      model: _model,
    );
    onRunStarted(runId);
    final history = (await _chatRepository.recentMessages(
      accountId,
      limit: 200,
    )).where((message) => message.id != excludeHistoryMessageId).toList();
    final summary = await _chatRepository.latestSummary(accountId);
    // Now persist the current user message (still before any network I/O).
    await _chatRepository.appendMessage(
      accountId: accountId,
      runId: runId,
      role: ChatRole.user,
      state: ChatMessageState.completed,
      content: userText,
    );

    var viewState = AgentRunViewState(
      runId: runId,
      state: AgentRunState.running,
    );
    controller.add(viewState);

    // --- Grounding state (Task 1) ----------------------------------------
    // Classify the CURRENT user text once at send() start, BEFORE token
    // estimation or context build. Free chat and capability/advice wording yield
    // `null` and take the normal path; an explicit operation must be backed by
    // a real tool call. For a relation write the requirement also carries the
    // narrowed tool set and (optionally) the user's expected conflict state.
    final grounding = _groundingPolicy.classify(userText);

    // 3. Build the initial request from prior history + summary + current text.
    // For a bounded relation run the FIRST (and every autonomous) request
    // declares ONLY the relation tool family; otherwise the full registry.
    final declarations = _initialDeclarations(grounding);

    // As of Task 7: reject an oversized CURRENT question BEFORE invoking the
    // provider. If the question alone plus the fixed overhead (system prompt +
    // JSON-encoded tool declarations) exceeds the input budget, surface a safe
    // `question_too_large` error rather than sending a request that cannot
    // fit. This is a pure check the context builder exposes for the caller.
    final turnEstimate = _contextBuilder.estimateTurnTokens(
      currentUserText: userText,
      toolDeclarations: declarations,
      clock: _clock,
    );
    if (turnEstimate.isTooLarge) {
      await _chatRepository.finishRun(
        accountId: accountId,
        runId: runId,
        state: AgentRunState.failed,
        errorCode: turnEstimate.code,
        inputTokens: null,
        outputTokens: null,
      );
      controller.add(
        AgentRunViewState(
          runId: runId,
          state: AgentRunState.failed,
          errorCode: turnEstimate.code,
        ),
      );
      onTerminalEmitted();
      return;
    }

    // The conversation accumulates assistant turns (with tool_use) and user
    // turns (with tool_result) across model calls within this run.
    final conversation = <LlmMessage>[];
    final initialRequest = _contextBuilder.build(
      model: _model,
      accountId: accountId,
      history: history,
      summary: summary,
      currentUserText: userText,
      toolDeclarations: declarations,
      clock: _clock,
    );
    conversation.addAll(initialRequest.messages);
    final systemPrompt = initialRequest.system;

    final references = RunReferenceStore(runId: runId);
    final toolCallCount = <String, int>{}; // toolName -> count, for ActionLog
    var totalToolCalls = 0;
    var modelCallCount = 0;
    var lastInputTokens = 0;
    var lastOutputTokens = 0;
    // A single streaming assistant draft accumulates all SAFE, FILTERED text
    // deltas across the run. It is created lazily on the first text delta so
    // tool-only turns do not leave empty completed messages behind. The
    // per-turn conversation reconstruction (text + tool_use blocks) is
    // separate from this draft.
    //
    // `_filter` sanitizes streamed model text incrementally (Task 2): it
    // strips leading history-marker timestamps at the start of an assistant
    // turn and replaces run-local `ref_*` tokens with a safe placeholder,
    // holding back split tokens so they never flash even transiently. The RAW
    // per-turn text (used for `LlmMessage` replay) is kept in `turnText`
    // separately — only UI/persistence text is filtered.
    var assistantText = '';
    final filter = AssistantTextFilter();
    // Fingerprints (tool name + sorted args) whose outcome this run forbids an
    // exact repeat: a duplicate identical tool call is bounded without a second
    // registry execution (Task 2).
    final fingerprintBlocked = <String>{};
    String? assistantMessageId;

    Future<String> ensureDraft() async {
      assistantMessageId ??= await _chatRepository.appendMessage(
        accountId: accountId,
        runId: runId,
        role: ChatRole.assistant,
        state: ChatMessageState.streaming,
        content: '',
      );
      return assistantMessageId!;
    }

    Future<void> persistVisible(String content) async {
      final id = assistantMessageId;
      if (id == null) return;
      await _chatRepository.updateAssistantDraft(
        accountId: accountId,
        messageId: id,
        content: content,
      );
    }

    Future<void> flushDraft(ChatMessageState state) async {
      final id = assistantMessageId;
      if (id == null) return;
      await _chatRepository.updateAssistantDraft(
        accountId: accountId,
        messageId: id,
        content: assistantText,
        state: state,
      );
    }

    // 4. The loop.
    var terminalState = AgentRunState.completed;
    String? errorCode;

    // --- Grounding state (Task 1) ----------------------------------------
    // Tools that completed successfully this run. A mutation is only grounded
    // once its terminal write tool succeeded (after confirmation); a read is
    // grounded once its required lookup tools succeeded.
    final succeededTools = <String>{};
    // Structured outcomes of THIS grounding requirement's terminal write
    // tool(s). Success prose is grounded ONLY by a successful terminal write;
    // a terminal write attempted but not successful deterministically settles
    // the run as a non-success outcome (no repeat attempt, no reliance on the
    // model honestly reporting the failure).
    final terminalAttempts = <String, _TerminalMutationAttempt>{};

    // Expected-state enforcement (Task 3): when the user text carries an
    // expected conflict state for a relation write, a `create_schedule_relation`
    // call whose `conflict_state` disagrees is NEVER executed or silently
    // rewritten — the FIRST mismatch returns `relation_state_mismatch` with
    // fixed guidance so the model can change one call; a SECOND mismatch ends
    // the run safely without a confirmation card.
    var relationStateMismatchCount = 0;
    final expectedConflictState = grounding?.expectedConflictState;

    // Bounded corrective-retry state: at most one forced `any` retry and at
    // most one compat fallback without `tool_choice` per run.
    var correctiveUsed = false; // a corrective request has already been issued
    var correctivePending = false; // the NEXT model call must be the corrective one
    var correctiveToolChoice = LlmToolChoice.auto;
    var correctiveToolNames = <String>{}; // narrowed declarations for the correction
    List<LlmMessage> correctiveMessages = const [];
    // Set once a forced `any` request fails before content: the provider does
    // not support forced choice for this session, so we fall back to `auto`.
    var forcedChoiceUnsupported = false;

    try {
      while (true) {
        // Budget: never start a new model call past the limit.
        if (modelCallCount >= maxModelCalls) {
          terminalState = AgentRunState.failed;
          errorCode = 'model_call_budget_exceeded';
          break;
        }
        // Stop: if cancelled, do NOT start the next model call.
        if (signal.isCancelled) {
          terminalState = AgentRunState.cancelled;
          break;
        }

        modelCallCount++;
        // Text emitted by THIS turn only, used to build the per-turn assistant
        // message (text + tool_use) sent back to the model. The persisted
        // draft accumulates across turns.
        var turnText = StringBuffer();
        final toolUses = <ToolUseCompletedEvent>[];
        var streamError = false;
        String? streamErrorCode;
        // The SAFE, filtered text visible at the START of this turn (before any
        // of its streamed deltas). If this turn later emits a tool use, the
        // visible draft is restored to this point — a collapsed
        // AgentToolRunTile is the only persisted progress for that turn.
        final visibleBeforeTurn = assistantText;

        // Choose the tool declarations and conversation for THIS call. The
        // initial call (and every autonomous tool-loop call) sees the full
        // registry and the live conversation. If this is the single corrective
        // call, narrow to the registered required tools and use the corrective
        // conversation (which ends with a fixed application correction).
        var requestTools = declarations;
        var requestMessages = conversation;
        var requestToolChoice = LlmToolChoice.auto;
        var thisCallWasForcedAny = false;
        if (correctivePending) {
          correctivePending = false;
          correctiveUsed = true;
          requestTools = _registeredDeclarations(
            correctiveToolNames,
            declarations,
          );
          requestMessages = correctiveMessages;
          requestToolChoice = correctiveToolChoice;
          thisCallWasForcedAny =
              correctiveToolChoice == LlmToolChoice.any;
        }

        try {
          final apiKey = await _apiKeyProvider(accountId: accountId);
          await for (final event in _provider.stream(
            apiKey: apiKey,
            request: LlmRequest(
              model: _model,
              messages: List<LlmMessage>.of(requestMessages),
              system: systemPrompt,
              tools: requestTools,
              toolChoice: requestToolChoice,
            ),
            cancellation: signal,
          )) {
            switch (event) {
              case TextDeltaEvent(:final text):
                // RAW per-turn text for `LlmMessage` replay.
                turnText.write(text);
                // Incrementally SAFE text for the UI and the persistence draft.
                final filtered = filter.add(text);
                assistantText += filtered;
                final id = await ensureDraft();
                viewState = viewState.copyWith(text: assistantText);
                controller.add(viewState);
                await _chatRepository.updateAssistantDraft(
                  accountId: accountId,
                  messageId: id,
                  content: assistantText,
                );
              case ToolUseCompletedEvent():
                toolUses.add(event);
              case UsageEvent(:final inputTokens, :final outputTokens):
                if (inputTokens != null) lastInputTokens = inputTokens;
                if (outputTokens != null) lastOutputTokens = outputTokens;
              case CompletedEvent():
                break;
              case ErrorEvent(:final code):
                streamError = true;
                streamErrorCode = code;
            }
            // Stop: drain the in-flight stream but stop processing further
            // events once cancelled. We break out of the event loop and let
            // the outer guard prevent the next model call.
            if (signal.isCancelled) {
              break;
            }
          }
        } catch (_) {
          // A thrown stream is treated as a non-retryable error.
          streamError = true;
          streamErrorCode = 'stream_exception';
        }

        if (streamError) {
          // Step 4 rule 4: a forced `any` request that errors BEFORE any
          // content AND with a recognized compatibility code means the
          // provider likely does not support forced choice for this session.
          // Fall back to a single `auto` retry of the same corrective
          // request, then mark this provider as no-forced-choice.
          //
          // The fallback is STRICTLY gated: auth, rate-limit, server,
          // transport, stream-interrupt, and tool-input errors are real
          // upstream/network failures, NOT a forced-choice compatibility
          // issue — they must preserve the original error and end immediately
          // rather than hide behind an `auto` retry.
          if (thisCallWasForcedAny &&
              correctiveUsed &&
              !forcedChoiceUnsupported &&
              turnText.isEmpty &&
              toolUses.isEmpty &&
              _isForcedChoiceCompatibilityError(streamErrorCode) &&
              !signal.isCancelled) {
            forcedChoiceUnsupported = true;
            correctiveToolChoice = LlmToolChoice.auto;
            correctivePending = true; // repeat the same correction once, auto
            continue;
          }
          terminalState = AgentRunState.failed;
          errorCode = streamErrorCode ?? 'upstream_error';
          break;
        }

        // If the model emitted no tool uses, this is a final text turn.
        // (Either CompletedEvent or a cancel-break ended the stream.)
        if (toolUses.isEmpty) {
          final grounded = _settleNoToolUse(
            requirement: grounding,
            succeededTools: succeededTools,
            terminalAttempts: terminalAttempts,
            isCancelled: signal.isCancelled,
            usedCorrective: correctiveUsed,
          );
          switch (grounded) {
            case _GroundedSettlement.accept:
              // Cases 1 & 2: free chat, or every required tool already
              // succeeded -> accept the final text.
              terminalState = signal.isCancelled
                  ? AgentRunState.cancelled
                  : AgentRunState.completed;
              break;
            case _GroundedSettlement.correct:
              // Case 3: no required tool succeeded and no corrective call used
              // -> issue ONE fixed application correction with narrowed
              // declarations and `any` (or `auto` if this provider was already
              // found unsupported).
              correctiveToolNames = grounding?.requiredTools ?? const {};
              correctiveMessages = _buildCorrectiveMessages(
                conversation,
                systemPrompt,
                turnText.toString(),
              );
              correctiveToolChoice = forcedChoiceUnsupported
                  ? LlmToolChoice.auto
                  : LlmToolChoice.any;
              correctivePending = true;
              continue;
            case _GroundedSettlement.overrideFailure:
              // The terminal write WAS attempted but did not succeed. Do NOT
              // re-correct into a repeat write attempt. Deterministically
              // replace the model's text (which may falsely claim success)
              // with a fixed non-success statement derived from the tool's
              // safe error code. Success is NOT judged from model wording.
              terminalState = _terminalFailureRuntimeState(grounding);
              errorCode = _terminalFailureCode(grounding, terminalAttempts);
              assistantText = _terminalFailureText(errorCode);
              break;
            case _GroundedSettlement.fail:
              // Case 5: no legal required tool after correction/fallback.
              // Replace any unsupported model text with the fixed safe notice.
              terminalState = AgentRunState.failed;
              errorCode = 'grounding_failed';
              assistantText = _groundingFailedText;
              break;
          }
          break;
        }

        // Tool-use turn: the model emitted tool calls, so its streamed text is
        // interstitial chatter, not the final answer. Restore the visible draft
        // to the pre-turn point: a collapsed AgentToolRunTile is the only
        // persisted progress for this turn. The RAW per-turn text is still
        // replayed to the model below; only display/persistence is reverted.
        if (assistantText != visibleBeforeTurn) {
          assistantText = visibleBeforeTurn;
          filter.reset();
          await persistVisible(assistantText);
          viewState = viewState.copyWith(text: assistantText);
          controller.add(viewState);
        }

        // Tool-use turn: append the assistant turn (text + tool_use blocks)
        // to the conversation, then execute each tool and append a user turn
        // with the tool_result blocks.
        final assistantBlocks = <LlmContentBlock>[];
        final turnTextStr = turnText.toString();
        if (turnTextStr.isNotEmpty) {
          assistantBlocks.add(LlmTextBlock(turnTextStr));
        }
        for (final tu in toolUses) {
          assistantBlocks.add(
            LlmToolUseBlock(id: tu.id, name: tu.name, input: tu.input),
          );
        }
        conversation.add(
          LlmMessage(role: 'assistant', content: assistantBlocks),
        );

        // Build the tool context for this run.
        final context = AgentToolContext(
          accountId: accountId,
          runId: runId,
          clock: _clock,
          cancellation: signal,
          references: references,
        );

        final toolResults = <LlmContentBlock>[];
        final newSourceRefs = <AgentSourceReference>[];
        final newToolSummaries = <AgentToolSummary>[];
        // As of Task 7: local data-domain tools emit a deduplicated
        // AgentLocalAction (one per domain) instead of forwarding per-event
        // refs to sourceReferences. This fixes the "一堆查看日程 chip 不可点击"
        // defect where the session service accumulated one ref per event.
        final newLocalActions = <AgentLocalAction>{};

        for (var toolIndex = 0; toolIndex < toolUses.length; toolIndex++) {
          final tu = toolUses[toolIndex];

          // Cancellation boundary: the current and every remaining tool_use in
          // this turn was never executed. Each un-executed block still consumes
          // one lifecycle row (finished `cancelled`) so the chat count matches
          // the persisted invocation count, and the model receives a cancelled
          // tool_result for each.
          if (signal.isCancelled) {
            terminalState = AgentRunState.cancelled;
            for (final unstarted in toolUses.skip(toolIndex)) {
              final invId = await _startInvocation(
                accountId: accountId,
                runId: runId,
                tu: unstarted,
              );
              await _finishInvocation(
                accountId: accountId,
                invocationId: invId,
                state: ToolInvocationLifecycleState.cancelled,
                result: null,
              );
              newToolSummaries.add(
                _toolSummaryBlocked(
                  toolName: unstarted.name,
                  lifecycleState: ToolInvocationLifecycleState.cancelled,
                  errorCode: 'cancelled',
                ),
              );
              toolResults.add(
                LlmToolResultBlock(
                  toolUseId: unstarted.id,
                  content: _encodePayload(const {'code': 'cancelled'}),
                  isError: true,
                ),
              );
            }
            break;
          }

          // Budget: never execute a tool past the limit. The exceeded call
          // itself consumes one lifecycle row finished as an error.
          if (totalToolCalls >= maxToolCalls) {
            terminalState = AgentRunState.failed;
            errorCode = 'tool_call_budget_exceeded';
            // Append an error tool_result so the model's turn is well-formed.
            final invId = await _startInvocation(
              accountId: accountId,
              runId: runId,
              tu: tu,
            );
            await _finishInvocation(
              accountId: accountId,
              invocationId: invId,
              state: ToolInvocationLifecycleState.error,
              result: const AgentToolResult(
                status: AgentToolStatus.error,
                errorCode: 'tool_call_budget_exceeded',
              ),
            );
            newToolSummaries.add(
              _toolSummaryBlocked(
                toolName: tu.name,
                lifecycleState: ToolInvocationLifecycleState.error,
                errorCode: 'tool_call_budget_exceeded',
              ),
            );
            toolResults.add(
              LlmToolResultBlock(
                toolUseId: tu.id,
                content: _encodePayload(const {
                  'code': 'tool_call_budget_exceeded',
                }),
                isError: true,
              ),
            );
            break;
          }
          totalToolCalls++;
          toolCallCount.update(tu.name, (v) => v + 1, ifAbsent: () => 1);

          // The call will actually be processed, so persist a `running` row
          // now (before the fingerprint/registry branches that may block it).
          // The same invocation id moves running -> waiting -> terminal below.
          final invocationStartedAt = _clock.now().millisecondsSinceEpoch;
          final invocationId = await _startInvocation(
            accountId: accountId,
            runId: runId,
            tu: tu,
          );

          // Fingerprint dedup guard (Task 2): an EXACT repeat of a tool call
          // that already produced a bounding outcome this run is not executed
          // again — instead the model receives a `repeated_tool_call` error so
          // it changes arguments or stops. The budget above still COUNTS the
          // model's attempted duplicate (bounded run); a second registry
          // execution does not happen.
          final fp = ToolCallFingerprint.of(tu.name, tu.input);
          AgentToolResult result;
          // Lifecycle override for calls blocked before a normal registry
          // completion: fingerprint dedup and a needsUserAction-cancel finish
          // as a specific terminal state rather than the bare error mapping.
          ToolInvocationLifecycleState? forcedLifecycle;

          // Fingerprint dedup guard (Task 2): an EXACT repeat of a tool call
          // that already produced a bounding outcome this run is not executed
          // again — instead the model receives a `repeated_tool_call` error so
          // it changes arguments or stops. The started `running` row above is
          // finished as an error so the call still counts.
          if (fingerprintBlocked.contains(fp)) {
            result = const AgentToolResult(
              status: AgentToolStatus.error,
              errorCode: 'repeated_tool_call',
              payload: {
                'guidance':
                    '这个完全相同参数的调用已经出现过并被处理。请不要再重复调用该工具，'
                    '请基于已有结果直接回答，或改用不同的参数。',
              },
            );
            forcedLifecycle = ToolInvocationLifecycleState.error;
          } else if (_isRelationLookup(tu.name, grounding) &&
              tu.name == 'get_schedule' &&
              _noNonblankQuery(tu.input)) {
            // Relation-run get_schedule without a title query: return the
            // intent-specific error WITHOUT loading events (Task 3). This
            // prevents a relation request from pulling the whole semester's
            // occurrence just to filter by title later.
            result = const AgentToolResult(
              status: AgentToolStatus.error,
              errorCode: 'relation_lookup_requires_title',
              payload: {
                'guidance': '填写指定日期与标题后重新查询；不要读取整学期事件后再过滤。',
              },
            );
            forcedLifecycle = ToolInvocationLifecycleState.error;
          } else if (tu.name == 'create_schedule_relation' &&
              expectedConflictState != null) {
            // Expected-state enforcement (Task 3): never execute (nor silently
            // rewrite) a relation write whose conflict_state disagrees with the
            // user's expressed choice. First mismatch -> fixed guidance; second
            // -> end safely without a confirmation card.
            final proposed = tu.input['conflict_state'];
            final mismatch = _relationStateMismatches(
              proposed: proposed,
              expected: expectedConflictState,
            );
            if (mismatch) {
              relationStateMismatchCount++;
              if (relationStateMismatchCount >= 2) {
                // Second consecutive mismatch: end safely, no confirmation.
                terminalState = AgentRunState.failed;
                errorCode = 'grounding_failed';
                result = const AgentToolResult(
                  status: AgentToolStatus.error,
                  errorCode: 'relation_state_mismatch',
                  payload: {
                    'guidance': '第二次仍与你的选择不一致，已停止，未写入任何关系。',
                  },
                );
                forcedLifecycle = ToolInvocationLifecycleState.error;
              } else {
                // First mismatch: fixed guidance, allow one changed call.
                result = const AgentToolResult(
                  status: AgentToolStatus.error,
                  errorCode: 'relation_state_mismatch',
                  payload: {
                    'guidance': '用户已经表达了取舍；请把 conflict_state 改为 no_conflict，'
                        '不要记录为 conflict。',
                  },
                );
                forcedLifecycle = ToolInvocationLifecycleState.error;
              }
            } else {
              result = await _registry.execute(
                toolName: tu.name,
                arguments: tu.input,
                context: context,
              );
            }
          } else {
            result = await _registry.execute(
              toolName: tu.name,
              arguments: tu.input,
              context: context,
            );

            if (result.status == AgentToolStatus.needsUserAction) {
              final action = result.userAction;
              final pendingInvocation = result.pendingInvocation;
              if (action == null || pendingInvocation == null) {
                if (pendingInvocation != null) {
                  await _cancelPendingInvocation(pendingInvocation);
                }
                terminalState = AgentRunState.failed;
                errorCode = 'invalid_user_action';
                result = const AgentToolResult(
                  status: AgentToolStatus.error,
                  errorCode: 'invalid_user_action',
                );
                forcedLifecycle = ToolInvocationLifecycleState.error;
              } else if (signal.isCancelled) {
                await _cancelPendingInvocation(pendingInvocation);
                result = const AgentToolResult(
                  status: AgentToolStatus.error,
                  errorCode: 'cancelled',
                );
                forcedLifecycle = ToolInvocationLifecycleState.cancelled;
              } else {
                // Enter the pause flow: mark the started row `waiting_user`,
                // then await the pending invocation's terminal result and
                // finish the SAME row. This is the one place a lifecycle moves
                // running -> waiting_user -> terminal.
                final key = (accountId: accountId, runId: runId);
                final paused = _PausedRun(
                  accountId: accountId,
                  runId: runId,
                  action: action,
                  pendingInvocation: pendingInvocation,
                  conversation: conversation,
                  toolUseId: tu.id,
                  references: references,
                  signal: signal,
                );
                _pausedRuns[key] = paused;
                if (invocationId != null) {
                  await _chatRepository.markToolInvocationWaiting(
                    accountId: accountId,
                    invocationId: invocationId,
                  );
                }
                viewState = viewState.copyWith(
                  state: AgentRunState.waitingForUser,
                  userAction: action.metadata,
                );
                controller.add(viewState);
                try {
                  result = await pendingInvocation.result;
                } finally {
                  if (identical(_pausedRuns[key], paused)) {
                    _pausedRuns.remove(key);
                  }
                }
                viewState = viewState.copyWith(
                  state: AgentRunState.running,
                  clearUserAction: true,
                );
                controller.add(viewState);
                // A pause/resume that ends in a cancellation (the pending
                // invocation completed its terminal result as cancelled)
                // retains the `cancelled` lifecycle on the SAME row rather
                // than collapsing to a generic error.
                if (result.errorCode == 'cancelled') {
                  forcedLifecycle = ToolInvocationLifecycleState.cancelled;
                }
              }
            }

            // Record the fingerprint outcome so an EXACT repeat is bounded.
            // * success -> block repeat;
            // * a terminal argument/reference/permission error
            //   (invalid_arguments, invalid_write_arguments,
            //   reference_not_found, tool_not_allowed) -> block repeat (the
            //   model must change args, not spam the same bad call);
            // * needsUserAction pause/resume is ONE invocation — the result
            //   above is its terminal outcome, so only a final success (or the
            //   listed errors) blocks; the pause itself never triggers a
            //   second execution.
            final outcomeBlocksRepeat =
                result.status == AgentToolStatus.success ||
                    (result.status == AgentToolStatus.error &&
                        _repeatedBlockingErrors.contains(result.errorCode));
            if (outcomeBlocksRepeat) {
              fingerprintBlocked.add(fp);
            }
          }

          // Track which tools actually completed successfully this run. This
          // drives the grounding settlement: a required lookup that succeeded
          // grounds a read; for a mutation, only a successful terminal write
          // after confirmation grounds success prose.
          if (result.status == AgentToolStatus.success) {
            succeededTools.add(tu.name);
          }
          // Record a structured outcome ONLY when this tool is a terminal
          // write of the CURRENT grounding requirement. A read-tool failure or
          // an unrelated tool attempt must NOT be treated as a completed
          // (non-)write. This deterministic outcome is what grounds success
          // prose for a mutation — success never depends on model wording.
          if (grounding != null &&
              grounding.terminalTools.contains(tu.name)) {
            terminalAttempts[tu.name] = _TerminalMutationAttempt(
              toolName: tu.name,
              status: result.status,
              errorCode: result.errorCode,
            );
          }

          // Surface references bound by the tool.
          //
          // As of Task 7: local data-domain tools (get_schedule,
          // get_event_details, get_free_time, get_conflicts,
          // get_pending_event_reviews, get_tasks, get_task_details,
          // get_plan_blocks, get_pending_planblock_reviews) do NOT forward
          // their per-event/per-task refs to sourceReferences — that caused
          // the "一堆查看日程 chip 不可点击" defect (one inert chip per event,
          // accumulating across all tool calls with no dedup). Instead, a
          // successful local tool emits ONE deduplicated AgentLocalAction per
          // data domain (schedule / tasks), which the chat page renders as a
          // clickable ActionChip routing to the management screen.
          //
          // `campus_entry` refs from external catalog tools
          // (search_campus_catalog, read_campus_detail) ARE forwarded to
          // sourceReferences as public citations — these are the only
          // sourceReferences, and they remain inert Chips unless they carry a
          // trusted tool-returned HTTPS URL (URL resolution is NOT implemented
          // now; they stay inert).
          //
          // `result.references` is STILL used for run-local ref resolution
          // within the same run (the model calls get_event_details by ref),
          // so the tool keeps binding them; we just do not forward local ones
          // to the UI as citations.
          final localAction = _localActionForTool(tu.name);
          if (result.status == AgentToolStatus.success && localAction != null) {
            newLocalActions.add(localAction);
          } else if (_forwardsToSourceReferences(tu.name)) {
            for (final ref in result.references) {
              newSourceRefs.add(
                AgentSourceReference(kind: ref.kind, ref: ref.ref),
              );
            }
          }
          // Finish the SAME invocation row started above and surface its live
          // summary. A normal registry completion maps by result status; a
          // forcedLifecycle (fingerprint dedup, invalid_user_action, or
          // needsUserAction-cancel) wins for blocked calls.
          final terminalLifecycle = forcedLifecycle ??
              (result.status == AgentToolStatus.success
                  ? ToolInvocationLifecycleState.success
                  : ToolInvocationLifecycleState.error);
          final runClockMillis = _clock.now().millisecondsSinceEpoch;
          await _finishInvocation(
            accountId: accountId,
            invocationId: invocationId,
            state: terminalLifecycle,
            result: result,
          );
          newToolSummaries.add(
            _toolSummaryFromResult(
              toolName: tu.name,
              result: result,
              startedAt: invocationStartedAt,
              finishedAt: runClockMillis,
              safeArgumentsSummary: summarizeToolArguments(tu.name, tu.input),
            ),
          );

          // Build the tool_result content. On error, send a short safe code.
          // On success, send the sanitized payload as a JSON string.
          final Object content;
          if (result.status == AgentToolStatus.error) {
            final guidance = result.payload['guidance'];
            content = _encodePayload({
              'code': result.errorCode ?? 'tool_error',
              if (guidance is String && guidance.isNotEmpty)
                'guidance': guidance,
            });
          } else {
            content = _encodePayload(result.payload);
          }
          toolResults.add(
            LlmToolResultBlock(
              toolUseId: tu.id,
              content: content,
              isError: result.status == AgentToolStatus.error,
            ),
          );
        }

        // Append the user turn carrying tool_result blocks.
        conversation.add(LlmMessage(role: 'user', content: toolResults));

        // Emit an updated view with the new tool summaries, source refs, and
        // deduplicated local actions.
        viewState = viewState.copyWith(
          toolSummaries: [...viewState.toolSummaries, ...newToolSummaries],
          sourceReferences: [...viewState.sourceReferences, ...newSourceRefs],
          localActions: {
            ...viewState.localActions,
            ...newLocalActions,
          }.toList(growable: false),
        );
        controller.add(viewState);

        // If a budget boundary fired mid-tool, stop now.
        if (terminalState != AgentRunState.completed) break;
      }
    } catch (_) {
      // Any unexpected failure terminates the run safely.
      terminalState = AgentRunState.failed;
      errorCode = errorCode ?? 'runtime_error';
    }

    // 5. Finalize the draft and the run.
    final draftState = terminalState == AgentRunState.completed
        ? ChatMessageState.completed
        : terminalState == AgentRunState.cancelled
        ? ChatMessageState.cancelled
        : ChatMessageState.failed;
    // Finalize the streaming draft. If no text ever arrived (e.g. a tool-only
    // run that was cancelled before any text), there is no draft to finalize.
    // An empty failed/cancelled draft would be excluded by recentMessages
    // anyway, but we avoid creating one in the first place.
    //
    // Flush any decidable trailing filter content first. finish() emits only
    // SAFE trailing content and drops an incomplete `ref_`/marker prefix, so a
    // split timestamp or token is never persisted at stream end.
    assistantText += filter.finish();
    await flushDraft(draftState);

    await _chatRepository.finishRun(
      accountId: accountId,
      runId: runId,
      state: terminalState,
      errorCode: errorCode,
      inputTokens: lastInputTokens == 0 ? null : lastInputTokens,
      outputTokens: lastOutputTokens == 0 ? null : lastOutputTokens,
    );

    // 6. Emit the terminal view state.
    controller.add(
      viewState.copyWith(
        state: terminalState,
        text: assistantText,
        errorCode: errorCode,
        clearUserAction: true,
      ),
    );
    onTerminalEmitted();

    // 7. Attempt exactly one aggregated ActionLog. Logging is ancillary: a
    // local write failure must not replace an already-published run result.
    try {
      await _writeActionLog(
        accountId: accountId,
        state: terminalState,
        toolCallCount: toolCallCount,
      );
    } catch (_) {
      // The persisted run and emitted terminal view remain authoritative.
    }

    // 8. Summary scheduling (success only). Summary failure is swallowed.
    if (terminalState == AgentRunState.completed) {
      await _maybeSummarize(
        accountId: accountId,
        runId: runId,
        history: history,
        previousSummary: summary,
        lastInputTokens: lastInputTokens,
        signal: signal,
      );
    }
  }

  /// Starts a persisted invocation row for the given `tool_use`, moving the
  /// model's run-local `tool_use` block onto a DB lifecycle row so the terminal
  /// transition (and any later restore in chat) uses the SAME id. Logging is
  /// best-effort: a persistence failure never replays or reverses an already
  /// successful write — it is swallowed so the running tool path still proceeds.
  Future<String?> _startInvocation({
    required String accountId,
    required String runId,
    required ToolUseCompletedEvent tu,
  }) async {
    final safeArguments = summarizeToolArguments(tu.name, tu.input);
    try {
      return await _chatRepository.startToolInvocation(
        accountId: accountId,
        runId: runId,
        toolName: tu.name,
        safeArgumentsSummary: safeArguments,
      );
    } catch (_) {
      // Persistence is best-effort; a failure must not abort the tool.
      return null;
    }
  }

  /// Maps a terminal [AgentToolResult] into the [AgentToolSummary] that live
  /// UI consumes. The pause/resume path re-enters here with the terminal result
  /// of the pending invocation. [finishedAt] is the run-clock time the
  /// invocation was finalized; the finished-lifecycle row in the DB and this
  /// in-memory summary agree on the safe result summary.
  static AgentToolSummary _toolSummaryFromResult({
    required String toolName,
    required AgentToolResult result,
    int? startedAt,
    int? finishedAt,
    String? safeArgumentsSummary,
  }) {
    final lifecycle = switch (result.status) {
      AgentToolStatus.success => ToolInvocationLifecycleState.success,
      AgentToolStatus.error => ToolInvocationLifecycleState.error,
      // A pending invocation only reaches this helper through its terminal
      // result, so needsUserAction never escapes here.
      AgentToolStatus.needsUserAction => ToolInvocationLifecycleState.error,
    };
    return AgentToolSummary(
      toolName: toolName,
      lifecycleState: lifecycle,
      status: result.status,
      errorCode: result.status == AgentToolStatus.error
          ? (result.errorCode ?? 'tool_error')
          : null,
      safeArgumentsSummary: safeArgumentsSummary,
      safeResultSummary: summarizeToolResult(result),
      startedAt: startedAt,
      finishedAt: finishedAt,
    );
  }

  /// Builds a [AgentToolSummary] for a `tool_use` that was blocked before its
  /// registry execution: cancellation, budget, fingerprint-dedup, or
  /// registry-not-allowed. Such calls still consume one row, labelled with the
  /// ruling lifecycle state and a safe error code.
  static AgentToolSummary _toolSummaryBlocked({
    required String toolName,
    required ToolInvocationLifecycleState lifecycleState,
    required String errorCode,
    int? startedAt,
  }) => AgentToolSummary.error(
    toolName: toolName,
    lifecycleState: lifecycleState,
    errorCode: errorCode,
    startedAt: startedAt,
  );

  /// Finishes the invocation DB row matching [invocationId] with the terminal
  /// state derived from [result]. Best-effort like [_startInvocation]; a
  /// failure never reverses a successful tool write.
  Future<void> _finishInvocation({
    required String accountId,
    required String? invocationId,
    required ToolInvocationLifecycleState state,
    required AgentToolResult? result,
  }) async {
    if (invocationId == null) return;
    final safeResult = result == null
        ? ''
        : summarizeToolResult(result);
    final errorCode = result?.status == AgentToolStatus.error
        ? (result?.errorCode ?? 'tool_error')
        : null;
    try {
      await _chatRepository.finishToolInvocation(
        accountId: accountId,
        invocationId: invocationId,
        state: state,
        safeResultSummary: safeResult,
        errorCode: state == ToolInvocationLifecycleState.error
            ? errorCode
            : null,
      );
    } catch (_) {
      // Best-effort logging; never disturb the tool outcome.
    }
  }

  Future<void> _writeActionLog({
    required String accountId,
    required AgentRunState state,
    required Map<String, int> toolCallCount,
  }) async {
    final result = switch (state) {
      AgentRunState.completed => 'success',
      AgentRunState.cancelled => 'cancelled',
      AgentRunState.failed => 'failed',
      AgentRunState.interrupted => 'interrupted',
      AgentRunState.running => 'interrupted',
      AgentRunState.waitingForUser => 'interrupted',
    };
    // Build a tool-category count summary with NO user text and NO raw results.
    final parts = <String>[];
    for (final entry in toolCallCount.entries) {
      parts.add('${entry.key} ${entry.value} 次');
    }
    final safeSummary = parts.isEmpty ? '无工具调用' : parts.join('、');
    await _database.actionLogsRepository.append(
      accountId: accountId,
      source: 'agent',
      actionType: 'read_only_run',
      result: result,
      safeSummary: safeSummary,
      occurredAt: _clock.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _maybeSummarize({
    required String accountId,
    required String runId,
    required List<ChatMessageRecord> history,
    required ConversationSummaryRecord? previousSummary,
    required int lastInputTokens,
    required CancellationSignal signal,
  }) async {
    try {
      // Refresh history to include the just-completed turn.
      final freshHistory = await _chatRepository.recentMessages(
        accountId,
        limit: 200,
      );
      // Build a synthetic lastRunUsage from the run's recorded input tokens.
      final lastRunUsage = lastInputTokens > 0
          ? AgentRunRecord(
              id: runId,
              accountId: accountId,
              model: _model,
              status: AgentRunState.completed,
              errorCode: null,
              inputTokens: lastInputTokens,
              outputTokens: null,
              startedAt: 0,
              finishedAt: null,
            )
          : null;

      if (!_contextBuilder.needsSummary(
        accountId: accountId,
        history: freshHistory,
        summary: previousSummary,
        lastRunUsage: lastRunUsage,
      )) {
        return;
      }

      // As of Task 7: the summary request has its own independent input
      // budget. If the history-to-summarize plus the fixed overhead exceeds
      // the budget, trim to the newest turns that fit (rather than sending an
      // oversized request or skipping). If nothing fits, skip the summary.
      var summaryHistory = freshHistory;
      if (!_contextBuilder.summaryHistoryFits(history: freshHistory, clock: _clock)) {
        summaryHistory = _contextBuilder.trimSummaryHistory(
          history: freshHistory,
          clock: _clock,
        );
        if (summaryHistory.isEmpty) return;
      }

      final summaryRequest = _contextBuilder.buildSummaryRequest(
        model: _model,
        accountId: accountId,
        history: summaryHistory,
        previousSummary: previousSummary,
        clock: _clock,
      );

      // Run the summary as a tool-disabled, temperature-0 request. It does NOT
      // count against the user run's 8/12 budget.
      final apiKey = await _apiKeyProvider(accountId: accountId);
      final buffer = StringBuffer();
      var summaryDone = false;
      await for (final event in _provider.stream(
        apiKey: apiKey,
        request: summaryRequest,
        cancellation: signal,
      )) {
        switch (event) {
          case TextDeltaEvent(:final text):
            buffer.write(text);
          case CompletedEvent():
            summaryDone = true;
          case ErrorEvent():
            // Swallow summary errors; do not block the chat.
            return;
          case ToolUseCompletedEvent():
            break; // tool-disabled request; ignore defensively
          case UsageEvent():
            break;
        }
      }
      if (!summaryDone || buffer.isEmpty) return;

      final rawSummary = buffer.toString();
      final safeSummary = _privacyFilter.sanitizeSafeSummary(rawSummary);
      // throughOrdinal = the latest message ordinal we summarized up to.
      final throughOrdinal = freshHistory.isEmpty
          ? 0
          : freshHistory.last.ordinal;
      await _chatRepository.replaceSummary(
        accountId: accountId,
        throughOrdinal: throughOrdinal,
        content: safeSummary,
        model: _model,
      );
    } catch (_) {
      // Summary failure must never block the chat.
    }
  }

  /// Encodes a sanitized payload as a JSON string for the `tool_result`
  /// content field. The payload is already allowlisted by the registry, so
  /// this is a pure transformation.
  String _encodePayload(Map<String, Object?> payload) => jsonEncode(payload);

  /// Maps a local data-domain tool name to its [AgentLocalAction] kind, or
  /// null if the tool is not a local data-domain tool. Used to build the
  /// deduplicated local-actions set: a successful schedule-domain tool emits
  /// one `AgentLocalAction.schedule`; a successful task-domain tool emits one
  /// `AgentLocalAction.tasks`. The mapping is by TOOL NAME (not ref kind) so
  /// the decision is independent of what the tool chose to bind.
  static AgentLocalAction? _localActionForTool(String toolName) {
    if (_scheduleDomainTools.contains(toolName)) {
      return AgentLocalAction.schedule;
    }
    if (_taskDomainTools.contains(toolName)) {
      return AgentLocalAction.tasks;
    }
    return null;
  }

  /// Whether a tool's bound references should be forwarded to
  /// `sourceReferences` as public citations. Only the external catalog tools
  /// (search_campus_catalog, read_campus_detail) forward their `campus_entry`
  /// refs; local data-domain tools do NOT (they emit local actions instead).
  static bool _forwardsToSourceReferences(String toolName) =>
      _catalogTools.contains(toolName);

  /// Schedule-domain local tools: a successful call emits one
  /// `AgentLocalAction.schedule`.
  static const _scheduleDomainTools = <String>{
    'get_schedule',
    'get_event_details',
    'get_free_time',
    'get_conflicts',
    'get_pending_event_reviews',
  };

  /// Task-domain local tools: a successful call emits one
  /// `AgentLocalAction.tasks`.
  static const _taskDomainTools = <String>{
    'get_tasks',
    'get_task_details',
    'get_plan_blocks',
    'get_pending_planblock_reviews',
  };

  /// External catalog tools whose `campus_entry` refs ARE forwarded to
  /// `sourceReferences` as public citations.
  static const _catalogTools = <String>{
    'search_campus_catalog',
    'read_campus_detail',
  };

  /// Error codes whose exact-repeat tool call is also bounded without a second
  /// execution. Repeating a call that failed because of its OWN arguments /
  /// reference / permission is purposeless — the model must change the call
  /// rather than spam the identical bad one.
  static const _repeatedBlockingErrors = <String>{
    'invalid_arguments',
    'invalid_write_arguments',
    'reference_not_found',
    'tool_not_allowed',
  };

  // --- Grounding settlement (Task 1) -------------------------------------

  /// Whether a stream error code is a recognized forced-choice compatibility
  /// failure, for which a single `auto` fallback is warranted. Only a
  /// corrective forced-`any` request that errors BEFORE any content and with
  /// this code may fall back. Auth, rate-limit, server, transport,
  /// stream-interrupt, and tool-input errors are NOT compatibility issues —
  /// they preserve the original error and end immediately.
  static bool _isForcedChoiceCompatibilityError(String? code) =>
      code == 'protocol_error';

  /// The fixed message used when an explicit operation could not be grounded
  /// after the single bounded correction. The model's unsupported text is
  /// REPLACED by this safe notice.
  static const _groundingFailedText = '我还没有实际查询或执行这项操作，请重试。';

  /// Whether a proposed `conflict_state` argument disagrees with the expected
  /// state the user has expressed. Only compares when the expected state is
  /// known; a missing/blank proposed value is a mismatch.
  static bool _relationStateMismatches({
    required Object? proposed,
    required ExpectedConflictState expected,
  }) {
    switch (expected) {
      case ExpectedConflictState.noConflict:
        return proposed != 'no_conflict';
      case ExpectedConflictState.conflict:
        return proposed != 'conflict';
    }
  }

  /// Whether the current run is a relation write (i.e. the grounding
  /// requirement is a `create_schedule_relation` mutation), in which case a
  /// `get_schedule` call is a relation participant lookup subject to the
  /// title-query requirement.
  static bool _isRelationLookup(
    String toolName,
    AgentGroundingRequirement? grounding,
  ) =>
      grounding != null &&
      grounding.terminalTools.contains('create_schedule_relation');

  /// Whether a `get_schedule` call carries no nonblank `query` argument.
  static bool _noNonblankQuery(Map<String, Object?> input) {
    final query = input['query'];
    return query is! String || query.trim().isEmpty;
  }

  /// The fixed application correction appended to the conversation before the
  /// single corrective request. It tells the model (with narrowed tool
  /// declarations) to actually perform the required operation.
  static const _groundingCorrectionText =
      '请使用上面提供的工具实际完成用户刚才要求的查询或操作，不要直接给出答案。';

  /// Given a set of tool names and the full registered declarations, returns
  /// only the declarations whose names are both requested AND actually
  /// registered. This guarantees a corrective request never declares an
  /// unknown tool. Returns an empty list if none are registered.
  List<LlmToolDeclaration> _registeredDeclarations(
    Set<String> names,
    List<LlmToolDeclaration> allDeclarations,
  ) {
    if (names.isEmpty) return const [];
    final byName = <String, LlmToolDeclaration>{
      for (final d in allDeclarations) d.name: d,
    };
    return [
      for (final name in names)
        if (byName[name] != null) byName[name]!,
    ];
  }

  /// The tool declarations declared on the FIRST model request (and reused for
  /// every model request in an autonomous relation run). For a high-confidence
  /// relation write with a narrowed [AgentGroundingRequirement.initialAllowedTools]
  /// set, only those (registered) tools are declared — never unrelated tools
  /// like `get_conflicts`. Free chat and all other intents get the full
  /// registry plus `auto`, so nothing is ever forced.
  List<LlmToolDeclaration> _initialDeclarations(
    AgentGroundingRequirement? grounding,
  ) {
    final all = _registry.schemas;
    final narrowed = grounding?.initialAllowedTools;
    if (narrowed == null || narrowed.isEmpty) return all;
    return _registeredDeclarations(narrowed.toSet(), all);
  }

  /// Builds the message list for the single corrective request: the current
  /// conversation (whose last user turn is the grounded request) plus a fixed
  /// application correction as a new user turn. The model's unsupported text
  /// turn is NOT replayed — the correction is a well-formed continuation.
  List<LlmMessage> _buildCorrectiveMessages(
    List<LlmMessage> conversation,
    String? systemPrompt,
    String unsupportedTurnText,
  ) {
    return [
      ...conversation,
      LlmMessage.user(text: _groundingCorrectionText),
    ];
  }

  /// Decides how a no-tool-use model turn settles under grounding.
  ///
  /// [requirement] is the classification of the CURRENT user text; null means
  /// free chat / capability advice. [succeededTools] holds the tools that
  /// completed successfully this run; [terminalAttempts] holds structured
  /// outcomes for any terminal write tool(s) run this session; [usedCorrective]
  /// reports whether the single corrective request has already been issued.
  _GroundedSettlement _settleNoToolUse({
    required AgentGroundingRequirement? requirement,
    required Set<String> succeededTools,
    required Map<String, _TerminalMutationAttempt> terminalAttempts,
    required bool isCancelled,
    required bool usedCorrective,
  }) {
    // Stop cancels everything; do not issue any further model call.
    if (isCancelled) return _GroundedSettlement.accept;

    // Case 1: free chat / capability / advice — accept the final text.
    final req = requirement;
    if (req == null) return _GroundedSettlement.accept;

    // Case 2: every required terminal tool succeeded AND the lookup requirement
    // is satisfied — accept. (read: no terminal -> lookup success suffices;
    // mutation: terminal write success after confirmation.) The lookup
    // requirement may be an EITHER/OR over groups (e.g. create_schedule_relation:
    // schedule refs OR plan-block refs), so it is checked via
    // [isLookupsSatisfied], not a flat every(). An empty terminalTool set is
    // trivially satisfied (pure read).
    final terminalSucceeded =
        req.terminalTools.every(succeededTools.contains);
    if (terminalSucceeded && req.isLookupsSatisfied(succeededTools)) {
      return _GroundedSettlement.accept;
    }

    // Mutation: the terminal write outcome is the SOLE authority on success.
    // If a terminal write of this requirement was invoked, decide by its
    // structured result — never by the model's wording. A success grounds the
    // model's completion prose; any non-success deterministically overrides
    // the model's (possibly false) text and must NOT be re-called. This does
    // NOT apply when the terminal write was never invoked at all (e.g. a
    // hallucinated success with no tool call ever made).
    if (req.mutationIntent && req.terminalTools.isNotEmpty) {
      for (final terminalTool in req.terminalTools) {
        final attempt = terminalAttempts[terminalTool];
        if (attempt != null) {
          return attempt.succeeded
              ? _GroundedSettlement.accept
              : _GroundedSettlement.overrideFailure;
        }
      }
    }

    // Case 3: a required tool is missing and no corrective call was used —
    // issue the single correction.
    if (!usedCorrective) return _GroundedSettlement.correct;

    // Case 5: correction (and any compat fallback) are exhausted but no legal
    // required tool succeeded — grounding failed.
    return _GroundedSettlement.fail;
  }

  /// The runtime terminal state for a terminal write that was attempted but
  /// did not succeed. Declined / permission-denied / tool-cancelled outcomes
  /// are safe-ended conversations; technical errors follow the existing
  /// failed-run display convention. In every case the run never lands on a
  /// success conclusion, and the safe `errorCode` is preserved.
  static AgentRunState _terminalFailureRuntimeState(
    AgentGroundingRequirement? requirement,
  ) {
    // Kept simple: a non-success terminal write never yields `completed`.
    return AgentRunState.failed;
  }

  /// The preserved safe error code for a non-success terminal write. Falls
  /// back to `write_not_grounded` when the structured outcome carries no code
  /// so a traceable local failure reason always survives.
  static String? _terminalFailureCode(
    AgentGroundingRequirement? requirement,
    Map<String, _TerminalMutationAttempt> terminalAttempts,
  ) {
    if (requirement != null) {
      for (final terminalTool in requirement.terminalTools) {
        final attempt = terminalAttempts[terminalTool];
        if (attempt != null && attempt.errorCode != null) {
          return attempt.errorCode;
        }
      }
    }
    return 'write_not_grounded';
  }

  /// Maps a safe terminal-write error code to a fixed non-success statement.
  /// Every variant explicitly states that no data was modified. The fallback
  /// must at least convey "没有修改数据".
  static String _terminalFailureText(String? code) => switch (code) {
        'user_declined' => '本次操作已取消，没有修改数据。',
        'permission_denied' => '权限策略拒绝了本次操作，没有修改数据。',
        'cancelled' => '本次操作已停止，没有修改数据。',
        _ => '操作未完成，没有修改数据，请检查信息后重试。',
      };
}

/// A structured record of a terminal write attempt during this session run.
///
/// Success of a mutation is grounded ONLY by an [AgentToolStatus.success]
/// terminal write result — never by the model claiming completion. A terminal
/// write that was invoked but did not succeed is recorded here so the
/// settlement can deterministically override false success prose without
/// re-calling the write.
class _TerminalMutationAttempt {
  const _TerminalMutationAttempt({
    required this.toolName,
    required this.status,
    this.errorCode,
  });

  final String toolName;
  final AgentToolStatus status;
  final String? errorCode;

  bool get succeeded => status == AgentToolStatus.success;
}

/// Outcome of settling a no-tool-use model turn under the grounding policy.
enum _GroundedSettlement {
  /// Accept the model's final text (free chat, or all required tools
  /// succeeded, or the run was cancelled).
  accept,
  /// Issue the single bounded corrective request.
  correct,
  /// A terminal write was attempted but did not succeed — deterministically
  /// settle as non-success (override the model's text, never re-call).
  overrideFailure,
  /// No legal required tool after correction/fallback: grounding failed.
  fail,
}
