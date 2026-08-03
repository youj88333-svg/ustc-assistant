import '../domain/agent_tool.dart';

/// The classification of a preflighted tool turn.
enum AgentToolTurnBudgetKind { normal, createTaskBurst, rejected }

/// The result of [AgentRunToolBudget.preflightTurn].
class AgentToolTurnBudgetDecision {
  const AgentToolTurnBudgetDecision._({
    required this.kind,
    this.errorCode,
    this.leasedCallCount = 0,
  });

  final AgentToolTurnBudgetKind kind;
  final String? errorCode;
  final int leasedCallCount;

  bool get isRejected => kind == AgentToolTurnBudgetKind.rejected;
}

/// A cheap, in-memory tool-turn budget for a single agent run.
///
/// There are two independent budgets:
///
/// * a **normal** per-run allowance of [normalLimit] calls shared by all tools,
///   drawn down one at a time via [tryConsumeNormalCall]; and
/// * a **create-task burst** lease: ONE dedicated turn of pure `create_task`
///   calls (up to [createTaskBurstLimit]) that is granted a single time per run
///   via [preflightTurn] and does not consume the normal allowance.
///
/// [preflightTurn] classifies a whole turn up front from its tool names, BEFORE
/// any call actually runs, and is side-effect free for every rejected turn.
/// This keeps the budget pure Dart and in-memory — no database, no providers,
/// no model-call constant.
class AgentRunToolBudget {
  /// The per-run allowance of ordinary tool calls.
  static const int normalLimit = 12;

  /// The per-run cap for a single create-task burst turn.
  static const int createTaskBurstLimit = 32;

  int _normalCallsUsed = 0;
  bool _createTaskBurstUsed = false;

  /// The number of ordinary calls consumed so far this run.
  int get normalCallsUsed => _normalCallsUsed;

  /// The number of ordinary calls still available this run.
  int get normalCallsRemaining => normalLimit - _normalCallsUsed;

  /// Whether the one allowed create-task burst has already been granted.
  bool get createTaskBurstUsed => _createTaskBurstUsed;

  /// Classifies a whole turn of [toolNames].
  ///
  /// * A pure `create_task` turn with [allowedCreateTaskBurstLimit] non-null is
  ///   an eligible burst: rejected when there are more calls than the allowance
  ///   (`create_task_burst_too_large`), rejected when the burst lease was
  ///   already used (`create_task_burst_already_used`), otherwise the single
  ///   lease is marked used and `createTaskBurst` is returned.
  /// * A mixed turn containing `create_task` is rejected with
  ///   `create_task_burst_requires_dedicated_turn` only when it would not fit
  ///   the remaining normal quota; otherwise it is normal.
  /// * A pure `create_task` turn with a null allowance is normal (each call
  ///   draws on the normal budget).
  /// * Every other turn (empty, non-`create_task`) is normal.
  ///
  /// Rejected turns are side-effect free: they mutate nothing.
  AgentToolTurnBudgetDecision preflightTurn({
    required List<String> toolNames,
    required int? allowedCreateTaskBurstLimit,
  }) {
    final isCreateTaskTurn =
        toolNames.isNotEmpty && toolNames.every((n) => n == 'create_task');

    if (isCreateTaskTurn) {
      if (allowedCreateTaskBurstLimit != null) {
        if (toolNames.length > allowedCreateTaskBurstLimit) {
          return const AgentToolTurnBudgetDecision._(
            kind: AgentToolTurnBudgetKind.rejected,
            errorCode: 'create_task_burst_too_large',
          );
        }
        // A single create_task is a normal, low-footprint turn, even after a
        // burst lease has been granted: it still consumes the ordinary quota.
        if (toolNames.length == 1) {
          return const AgentToolTurnBudgetDecision._(
            kind: AgentToolTurnBudgetKind.normal,
          );
        }
        if (_createTaskBurstUsed) {
          return const AgentToolTurnBudgetDecision._(
            kind: AgentToolTurnBudgetKind.rejected,
            errorCode: 'create_task_burst_already_used',
          );
        }
        _createTaskBurstUsed = true;
        return AgentToolTurnBudgetDecision._(
          kind: AgentToolTurnBudgetKind.createTaskBurst,
          leasedCallCount: toolNames.length,
        );
      }
      // Pure create_task with a null allowance is a normal turn; each call
      // draws on the normal budget.
      return const AgentToolTurnBudgetDecision._(
        kind: AgentToolTurnBudgetKind.normal,
      );
    }

    // Any mixed turn (create_task plus other tools) must fit the remaining
    // normal quota, otherwise it needs a dedicated burst turn.
    if (toolNames.contains('create_task') &&
        toolNames.length > normalCallsRemaining) {
      return const AgentToolTurnBudgetDecision._(
        kind: AgentToolTurnBudgetKind.rejected,
        errorCode: 'create_task_burst_requires_dedicated_turn',
      );
    }

    return const AgentToolTurnBudgetDecision._(
      kind: AgentToolTurnBudgetKind.normal,
    );
  }

  /// Draws one ordinary call off the normal budget.
  ///
  /// Returns `false` (with no effect) when the normal budget is exhausted.
  bool tryConsumeNormalCall() {
    if (_normalCallsUsed >= normalLimit) {
      return false;
    }
    _normalCallsUsed += 1;
    return true;
  }
}

/// The safe set of terminal error codes that survive aggregation unchanged.
///
/// Anything else (unknown strings, null) is collapsed to `tool_error` so raw
/// provider/database text never surfaces in a terminal message. `user_declined`
/// is deliberately NOT here — it is a distinct "declined" bucket, not a
/// technical error.
const Set<String> _safeErrorCodes = {
  'permission_denied',
  'invalid_arguments',
  'invalid_write_arguments',
  'reference_not_found',
  'target_not_found',
  'tool_not_allowed',
  'repeated_tool_call',
  'write_failed',
  'cancelled',
};

/// Aggregates the results of one create-task burst's `create_task` calls into
/// a single, safe, human-readable terminal summary.
///
/// The lease is created with the total [plannedCount] of calls expected for
/// the turn; [record] is called once per terminal result. Counts stay disjoint:
/// successful writes, user-declined writes, and technical errors never overlap.
/// No input arguments, titles, dates, refs, ids or account identifiers are
/// ever carried here — only counts and allowlisted codes.
class CreateTaskBurstLease {
  CreateTaskBurstLease({required this.plannedCount}) {
    if (plannedCount < 0) {
      throw ArgumentError.value(plannedCount, 'plannedCount', 'must be >= 0');
    }
  }

  /// The total number of `create_task` calls this burst is expected to make.
  final int plannedCount;

  /// The number of results recorded so far (via [record] + [recordInterrupted]).
  int processedCount = 0;

  /// How many writes succeeded.
  int successCount = 0;

  /// How many writes the user explicitly declined (`user_declined`).
  int declinedCount = 0;

  /// How many writes failed with a technical error (non-declined, non-success).
  int errorCount = 0;

  /// Counts of technical errors keyed by allowlisted safe code. Never contains
  /// `user_declined`; unknown/null codes collapse to `tool_error`.
  final Map<String, int> safeErrorCounts = {};

  /// Whether every planned write succeeded.
  bool get allSucceeded =>
      processedCount == plannedCount && errorCount == 0 && declinedCount == 0;

  /// Whether at least one write succeeded.
  bool get hasAnySuccess => successCount > 0;

  /// Whether every planned call has been accounted for.
  bool get isComplete => processedCount == plannedCount;

  /// The safe terminal override, or `null` for a complete all-success burst.
  ///
  /// `create_task_burst_partial` when at least one write succeeded but not all;
  /// `create_task_burst_failed` when no write succeeded.
  String? get terminalErrorCode {
    if (isComplete && allSucceeded) {
      return null;
    }
    return hasAnySuccess
        ? 'create_task_burst_partial'
        : 'create_task_burst_failed';
  }

  /// The human-readable Chinese terminal report.
  ///
  /// Grammar:
  /// * success present: `已创建 S 个 Task，P-S 个未完成。`
  /// * zero success: `未创建任何 Task。`
  /// * append `其中 D 个已取消。` when [declinedCount] > 0.
  /// * append `失败原因：code N 个，code N 个。` when [errorCount] > 0, codes
  ///   sorted lexically.
  ///
  /// Never contains raw error text, titles, dates, refs or ids.
  String? get terminalMessage {
    final buffer = StringBuffer();
    if (hasAnySuccess) {
      buffer.write(
        '已创建 $successCount 个 Task，'
        '${plannedCount - successCount} 个未完成。',
      );
    } else {
      buffer.write('未创建任何 Task。');
    }
    if (declinedCount > 0) {
      buffer.write('其中 $declinedCount 个已取消。');
    }
    if (errorCount > 0) {
      final codes = safeErrorCounts.keys.toList()..sort();
      final parts = codes.map((code) => '$code ${safeErrorCounts[code]} 个');
      buffer.write('失败原因：${parts.join('，')}。');
    }
    return buffer.toString();
  }

  /// Records one terminal [result] from a `create_task` call.
  ///
  /// `user_declined` is bucketed as a decline; `cancelled` is treated as an
  /// interrupted/cancelled write (not a success and not a technical error);
  /// every other non-success is a technical error whose code is preserved only
  /// if allowlisted, otherwise collapsed to `tool_error`.
  ///
  /// Throws [StateError] if this would push [processedCount] past
  /// [plannedCount] — a lease can never silently expand.
  void record(AgentToolResult result) {
    if (processedCount >= plannedCount) {
      throw StateError(
        'CreateTaskBurstLease processed $processedCount of $plannedCount; '
        'refusing to exceed the plan',
      );
    }
    processedCount += 1;

    if (result.status == AgentToolStatus.success) {
      successCount += 1;
      return;
    }

    final code = result.errorCode;
    if (code == 'user_declined') {
      declinedCount += 1;
      return;
    }

    errorCount += 1;
    final safe = code != null && _safeErrorCodes.contains(code)
        ? code
        : 'tool_error';
    safeErrorCounts.update(safe, (v) => v + 1, ifAbsent: () => 1);
  }

  /// Records [count] planned writes that never started (e.g. the run was
  /// cancelled mid-burst), without any replay metadata or Task content.
  void recordInterrupted(int count) {
    final next = processedCount + count;
    if (next > plannedCount) {
      throw StateError(
        'CreateTaskBurstLease recordInterrupted($count) would exceed '
        '$plannedCount (processed $processedCount)',
      );
    }
    processedCount = next;
  }
}
