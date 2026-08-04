import '../domain/agent_tool.dart';

/// Aggregates the terminal results of a single Agent run's lifecycle
/// mutation write tools (cancel/delete/restore/clear/unlink/reset/undo) into a
/// sequential 成功/拒绝/失败/未处理 count.
///
/// Unlike [CreateTaskBurstLease] (which is create_task-specific and pre-plans a
/// fixed [CreateTaskBurstLease.plannedCount] of writes), this ledger records
/// each lifecycle terminal result IN ORDER as it is actually issued — there is
/// no upfront planned count. A run whose grounding is a lifecycle mutation
/// records each issued terminal result here and the ledger produces a single
/// safe terminal summary when the run settles.
///
/// Hard rules (Task 10 brief §3):
/// * It ONLY summarizes calls already issued. It never expands the budget, so
///   the session service still draws every call through [AgentRunToolBudget];
///   the ledger observes outcomes but grants nothing.
/// * It NEVER saves titles, refs, ids, or raw error text. Only disjoint counts
///   and allowlisted safe error codes are carried.
/// * It NEVER auto-continues to a next run. Producing [terminalMessage] /
///   [terminalErrorCode] is a pure read; the caller decides whether to surface
///   it as the run's terminal text.
/// * Unknown error codes (and null) fold to the safe generic `tool_error` so
///   raw provider/database text never surfaces.
class MutationLedger {
  /// The lifecycle write-tool family this ledger aggregates. A terminal result
  /// whose tool name is in this set is recorded; any other tool result is
  /// ignored. This keeps the ledger focused on the cancel/delete/restore/clear
  /// /unlink/reset/undo family and prevents a read tool or a create_task call
  /// from polluting the counts.
  static const Set<String> lifecycleWriteTools = {
    'update_event',
    'update_task',
    'update_plan_block',
    'delete_schedule_relation',
    'clear_reminder',
    'clear_user_overlay',
    'unlink_task_event',
    'reset_permission_policy',
    'undo_last_action',
  };

  /// Whether [toolName] is a lifecycle write tool this ledger aggregates.
  static bool isLifecycleWriteTool(String toolName) =>
      lifecycleWriteTools.contains(toolName);

  /// The number of terminal results recorded so far.
  int processedCount = 0;

  /// How many lifecycle writes succeeded.
  int successCount = 0;

  /// How many lifecycle writes the user explicitly declined (`user_declined`).
  int declinedCount = 0;

  /// How many lifecycle writes failed with a technical error (non-declined,
  /// non-success, non-cancelled). Unknown codes fold to `tool_error`.
  int failedCount = 0;

  /// How many lifecycle writes were cancelled/interrupted before reaching a
  /// decisive success/decline/failure — e.g. `cancelled`, a stale target that
  /// could not be acted on, or any outcome that is neither a success nor a
  /// clear user decision nor a concrete technical failure.
  int unhandledCount = 0;

  /// Counts of technical errors keyed by allowlisted safe code. Never contains
  /// `user_declined` or `cancelled`; unknown/null codes collapse to `tool_error`.
  final Map<String, int> safeErrorCounts = {};

  /// Whether at least one lifecycle write succeeded.
  bool get hasAnySuccess => successCount > 0;

  /// The safe terminal override code, or `null` when every recorded write
  /// succeeded (or nothing was recorded).
  ///
  /// * `mutation_partial` — at least one write succeeded but not all.
  /// * `mutation_failed` — no write succeeded and at least one technical
  ///   failure occurred (with no unhandled-only outcome).
  /// * `mutation_declined` — no write succeeded and every non-success was a
  ///   user decline.
  /// * `mutation_unhandled` — no write succeeded and every non-success was an
  ///   unhandled/cancelled outcome.
  /// * `null` — nothing was recorded, or every recorded write succeeded.
  String? get terminalErrorCode {
    if (processedCount == 0) return null;
    if (successCount == processedCount) return null;
    if (hasAnySuccess) return 'mutation_partial';
    // No success: classify by the dominant non-success bucket, with a stable
    // precedence (failed > declined > unhandled) so a mixed no-success ledger
    // reports the most actionable reason.
    if (failedCount > 0) return 'mutation_failed';
    if (declinedCount > 0) return 'mutation_declined';
    return 'mutation_unhandled';
  }

  /// The human-readable Chinese terminal report, or `null` when every recorded
  /// write succeeded (or nothing was recorded).
  ///
  /// Grammar (only counts + allowlisted codes; never titles/refs/ids):
  /// * `成功 S 个，拒绝 D 个，失败 F 个，未处理 U 个。`
  /// * when [failedCount] > 0, append `失败原因：code N 个，…。` (codes sorted
  ///   lexically).
  String? get terminalMessage {
    final code = terminalErrorCode;
    if (code == null) return null;
    final buffer = StringBuffer();
    buffer.write(
      '成功 $successCount 个，'
      '拒绝 $declinedCount 个，'
      '失败 $failedCount 个，'
      '未处理 $unhandledCount 个。',
    );
    if (failedCount > 0) {
      final codes = safeErrorCounts.keys.toList()..sort();
      final parts = codes.map((c) => '$c ${safeErrorCounts[c]} 个');
      buffer.write('失败原因：${parts.join('，')}。');
    }
    return buffer.toString();
  }

  /// Records one terminal [result] of a lifecycle write tool named [toolName].
  ///
  /// The [toolName] MUST be a member of [lifecycleWriteTools]; a caller that
  /// passes any other tool name is a programming error (use
  /// [isLifecycleWriteTool] to gate before calling). This keeps the ledger
  /// focused and prevents a read or create_task result from polluting the
  /// counts.
  ///
  /// Bucketing:
  /// * success -> [successCount].
  /// * `user_declined` -> [declinedCount] (a distinct "declined" bucket, not a
  ///   technical error).
  /// * `cancelled` -> [unhandledCount] (an interrupted write, neither a
  ///   success nor a decisive technical failure).
  /// * every other non-success -> [failedCount], code preserved only if
  ///   allowlisted (see [_safeErrorCodes]), otherwise collapsed to `tool_error`.
  void record(String toolName, AgentToolResult result) {
    if (result.status == AgentToolStatus.success) {
      processedCount += 1;
      successCount += 1;
      return;
    }

    // A non-success result. Bucket by the safe error code.
    final code = result.errorCode;
    processedCount += 1;
    if (code == 'user_declined') {
      declinedCount += 1;
      return;
    }
    if (code == 'cancelled') {
      unhandledCount += 1;
      return;
    }
    // Technical error: fold unknown/null to tool_error.
    failedCount += 1;
    final safe = code != null && _safeErrorCodes.contains(code)
        ? code
        : 'tool_error';
    safeErrorCounts.update(safe, (v) => v + 1, ifAbsent: () => 1);
  }
}

/// The safe set of terminal error codes that the mutation ledger preserves
/// unchanged when bucketing a technical failure. Anything else (unknown
/// strings, null) is collapsed to `tool_error` so raw provider/database text
/// never surfaces in a terminal message. `user_declined` and `cancelled` are
/// deliberately NOT here — they are distinct "declined" / "unhandled" buckets,
/// not technical errors.
///
/// This is the union of the write-tool safe codes (from `agent_tool_budget`
/// `_safeErrorCodes`) and the Task 9 lifecycle error codes (`already_active`,
/// `already_deleted`, `stale_target`, `invalid_lifecycle_transition`,
/// `scope_required`, `source_event_not_editable`, `tool_execution_failed`).
const Set<String> _safeErrorCodes = {
  'permission_denied',
  'invalid_arguments',
  'invalid_write_arguments',
  'reference_not_found',
  'target_not_found',
  'tool_not_allowed',
  'repeated_tool_call',
  'write_failed',
  // Task 9 lifecycle error codes.
  'already_active',
  'already_deleted',
  'stale_target',
  'invalid_lifecycle_transition',
  'scope_required',
  'source_event_not_editable',
  'tool_execution_failed',
};
