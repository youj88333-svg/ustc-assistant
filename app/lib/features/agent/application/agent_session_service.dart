import 'dart:async';
import 'dart:convert';

import '../../../core/database/app_database.dart';
import '../../../core/time/beijing_clock.dart';
import '../data/drift_chat_repository.dart';
import '../domain/agent_models.dart';
import '../domain/agent_tool.dart';
import '../domain/llm_protocol.dart';
import 'agent_context_builder.dart';
import 'agent_tool_registry.dart';
import 'cancellation_signal.dart';
import 'outbound_privacy_filter.dart';
import 'run_reference_store.dart';

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

    // 3. Build the initial request from prior history + summary + current text.
    final declarations = _registry.schemas;

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
    // A single streaming assistant draft accumulates all text deltas across
    // the run. It is created lazily on the first text delta so tool-only turns
    // do not leave empty completed messages behind. The per-turn conversation
    // reconstruction (text + tool_use blocks) is separate from this draft.
    var assistantText = '';
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

        try {
          final apiKey = await _apiKeyProvider(accountId: accountId);
          await for (final event in _provider.stream(
            apiKey: apiKey,
            request: LlmRequest(
              model: _model,
              messages: List<LlmMessage>.of(conversation),
              system: systemPrompt,
              tools: declarations,
            ),
            cancellation: signal,
          )) {
            switch (event) {
              case TextDeltaEvent(:final text):
                turnText.write(text);
                assistantText += text;
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
          terminalState = AgentRunState.failed;
          errorCode = streamErrorCode ?? 'upstream_error';
          break;
        }

        // If the model emitted no tool uses, this is a final text turn.
        // (Either CompletedEvent or a cancel-break ended the stream.)
        if (toolUses.isEmpty) {
          terminalState = signal.isCancelled
              ? AgentRunState.cancelled
              : AgentRunState.completed;
          break;
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
          if (signal.isCancelled) {
            terminalState = AgentRunState.cancelled;
            for (final unstarted in toolUses.skip(toolIndex)) {
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
          // Budget: never execute a tool past the limit.
          if (totalToolCalls >= maxToolCalls) {
            terminalState = AgentRunState.failed;
            errorCode = 'tool_call_budget_exceeded';
            // Append an error tool_result so the model's turn is well-formed.
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

          var result = await _registry.execute(
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
            } else if (signal.isCancelled) {
              await _cancelPendingInvocation(pendingInvocation);
              result = const AgentToolResult(
                status: AgentToolStatus.error,
                errorCode: 'cancelled',
              );
            } else {
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
            }
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
          newToolSummaries.add(
            AgentToolSummary(toolName: tu.name, status: result.status),
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
}
