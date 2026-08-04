import 'package:flutter_test/flutter_test.dart';

import 'package:ustc_assistant_app/features/agent/domain/agent_tool.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_mutation_ledger.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_tool_budget.dart';

void main() {
  group('AgentRunToolBudget — preflightTurn', () {
    test('exposes the fixed static limits and no model-call constant', () {
      expect(AgentRunToolBudget.normalLimit, 12);
      expect(AgentRunToolBudget.createTaskBurstLimit, 32);
    });

    test(
      '2, 13 and 32 pure create_task calls with allowance 32 are a burst',
      () {
        for (final count in [2, 13, 32]) {
          final budget = AgentRunToolBudget();
          final decision = budget.preflightTurn(
            toolNames: List.filled(count, 'create_task'),
            allowedCreateTaskBurstLimit: 32,
          );
          expect(
            decision.kind,
            AgentToolTurnBudgetKind.createTaskBurst,
            reason: 'count $count should be a burst',
          );
          expect(budget.createTaskBurstUsed, isTrue);
          expect(budget.normalCallsUsed, 0);
        }
      },
    );

    test('33 pure create_task calls are rejected before any lease is used', () {
      final budget = AgentRunToolBudget();
      final decision = budget.preflightTurn(
        toolNames: List.filled(33, 'create_task'),
        allowedCreateTaskBurstLimit: 32,
      );
      expect(decision.kind, AgentToolTurnBudgetKind.rejected);
      expect(decision.errorCode, 'create_task_burst_too_large');
      expect(decision.isRejected, isTrue);
      // Side-effect free for a rejected turn.
      expect(budget.createTaskBurstUsed, isFalse);
      expect(budget.normalCallsUsed, 0);
    });

    test(
      'a second pure burst turn after one accepted lease is already-used',
      () {
        final budget = AgentRunToolBudget();
        final first = budget.preflightTurn(
          toolNames: List.filled(2, 'create_task'),
          allowedCreateTaskBurstLimit: 32,
        );
        expect(first.kind, AgentToolTurnBudgetKind.createTaskBurst);

        final second = budget.preflightTurn(
          toolNames: List.filled(2, 'create_task'),
          allowedCreateTaskBurstLimit: 32,
        );
        expect(second.kind, AgentToolTurnBudgetKind.rejected);
        expect(second.errorCode, 'create_task_burst_already_used');
        expect(budget.createTaskBurstUsed, isTrue);
      },
    );

    test('a single create_task after an accepted burst stays normal, '
        'while a second 2+ burst is already-used', () {
      final budget = AgentRunToolBudget();
      final first = budget.preflightTurn(
        toolNames: List.filled(3, 'create_task'),
        allowedCreateTaskBurstLimit: 32,
      );
      expect(first.kind, AgentToolTurnBudgetKind.createTaskBurst);
      expect(budget.createTaskBurstUsed, isTrue);

      // A lone create_task AFTER the lease was granted must stay normal and
      // consume ordinary remaining quota, never be rejected as already_used.
      final single = budget.preflightTurn(
        toolNames: ['create_task'],
        allowedCreateTaskBurstLimit: 32,
      );
      expect(single.kind, AgentToolTurnBudgetKind.normal);
      expect(single.isRejected, isFalse);
      expect(budget.tryConsumeNormalCall(), isTrue);
      expect(budget.normalCallsUsed, 1);

      // A second eligible BURST turn (2+) is still rejected as already_used.
      final second = budget.preflightTurn(
        toolNames: List.filled(2, 'create_task'),
        allowedCreateTaskBurstLimit: 32,
      );
      expect(second.kind, AgentToolTurnBudgetKind.rejected);
      expect(second.errorCode, 'create_task_burst_already_used');
    });

    test(
      'a one-call create_task turn is normal even when burst is eligible',
      () {
        final budget = AgentRunToolBudget();
        final decision = budget.preflightTurn(
          toolNames: ['create_task'],
          allowedCreateTaskBurstLimit: 32,
        );
        expect(decision.kind, AgentToolTurnBudgetKind.normal);
        expect(budget.createTaskBurstUsed, isFalse);
        // The single call counts against the normal budget.
        expect(budget.tryConsumeNormalCall(), isTrue);
        expect(budget.normalCallsUsed, 1);
      },
    );

    test('13 pure create_task calls with null allowance stay normal and the '
        '13th normal call returns false', () {
      final budget = AgentRunToolBudget();
      final decision = budget.preflightTurn(
        toolNames: List.filled(13, 'create_task'),
        allowedCreateTaskBurstLimit: null,
      );
      expect(decision.kind, AgentToolTurnBudgetKind.normal);
      expect(budget.createTaskBurstUsed, isFalse);

      for (var i = 0; i < 12; i++) {
        expect(budget.tryConsumeNormalCall(), isTrue, reason: 'call ${i + 1}');
      }
      expect(budget.normalCallsUsed, 12);
      expect(budget.normalCallsRemaining, 0);
      expect(budget.tryConsumeNormalCall(), isFalse, reason: 'the 13th call');
    });

    test('a mixed turn exceeding the remaining normal quota is rejected', () {
      final budget = AgentRunToolBudget();
      // Consume 5 normal calls first.
      for (var i = 0; i < 5; i++) {
        budget.tryConsumeNormalCall();
      }
      expect(budget.normalCallsRemaining, 7);

      // A mixed 8-call turn: more than the 7 remaining normal calls.
      final names = <String>['get_tasks', 'create_task'];
      final mixed8 = List<String>.generate(8, (i) => names[i % 2]);
      final decision = budget.preflightTurn(
        toolNames: mixed8,
        allowedCreateTaskBurstLimit: 32,
      );
      expect(decision.kind, AgentToolTurnBudgetKind.rejected);
      expect(decision.errorCode, 'create_task_burst_requires_dedicated_turn');
      expect(budget.createTaskBurstUsed, isFalse);
      expect(budget.normalCallsUsed, 5);
    });

    test('a mixed turn fitting the remaining normal quota returns normal', () {
      final budget = AgentRunToolBudget();
      for (var i = 0; i < 5; i++) {
        budget.tryConsumeNormalCall();
      }
      final names = <String>['get_tasks', 'create_task'];
      final mixed5 = List<String>.generate(5, (i) => names[i % 2]);
      final decision = budget.preflightTurn(
        toolNames: mixed5,
        allowedCreateTaskBurstLimit: 32,
      );
      expect(decision.kind, AgentToolTurnBudgetKind.normal);
      expect(budget.createTaskBurstUsed, isFalse);
      // Each call is consumed normally.
      for (var i = 0; i < 5; i++) {
        expect(budget.tryConsumeNormalCall(), isTrue);
      }
      expect(budget.normalCallsUsed, 10);
    });

    test('non-create_task turns never consume the burst', () {
      final budget = AgentRunToolBudget();
      final decision = budget.preflightTurn(
        toolNames: const ['get_schedule', 'get_tasks', 'get_free_time'],
        allowedCreateTaskBurstLimit: 32,
      );
      expect(decision.kind, AgentToolTurnBudgetKind.normal);
      expect(budget.createTaskBurstUsed, isFalse);
      for (var i = 0; i < 3; i++) {
        expect(budget.tryConsumeNormalCall(), isTrue);
      }
    });

    test('an empty turn returns normal with no side effect', () {
      final budget = AgentRunToolBudget();
      final decision = budget.preflightTurn(
        toolNames: const [],
        allowedCreateTaskBurstLimit: 32,
      );
      expect(decision.kind, AgentToolTurnBudgetKind.normal);
      expect(budget.createTaskBurstUsed, isFalse);
    });
  });

  group('CreateTaskBurstLease — record', () {
    test('a typical partial burst from the brief', () {
      final lease = CreateTaskBurstLease(plannedCount: 13);
      for (var i = 0; i < 12; i++) {
        lease.record(const AgentToolResult(status: AgentToolStatus.success));
      }
      lease.record(
        const AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'user_declined',
        ),
      );

      expect(lease.processedCount, 13);
      expect(lease.successCount, 12);
      expect(lease.declinedCount, 1);
      expect(lease.errorCount, 0);
      expect(lease.hasAnySuccess, isTrue);
      expect(lease.allSucceeded, isFalse);
      expect(lease.isComplete, isTrue);
      expect(lease.terminalErrorCode, 'create_task_burst_partial');

      expect(lease.terminalMessage, '已创建 12 个 Task，1 个未完成。其中 1 个已取消。');
    });

    test('13/13 success is complete all-success with no override', () {
      final lease = CreateTaskBurstLease(plannedCount: 13);
      for (var i = 0; i < 13; i++) {
        lease.record(const AgentToolResult(status: AgentToolStatus.success));
      }
      expect(lease.successCount, 13);
      expect(lease.allSucceeded, isTrue);
      expect(lease.hasAnySuccess, isTrue);
      expect(lease.isComplete, isTrue);
      expect(lease.terminalErrorCode, isNull);
      expect(lease.terminalMessage, '已创建 13 个 Task，0 个未完成。');
    });

    test('12 success + reference_not_found is partial with one safe error', () {
      final lease = CreateTaskBurstLease(plannedCount: 13);
      for (var i = 0; i < 12; i++) {
        lease.record(const AgentToolResult(status: AgentToolStatus.success));
      }
      lease.record(
        const AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'reference_not_found',
        ),
      );
      expect(lease.successCount, 12);
      expect(lease.errorCount, 1);
      expect(lease.safeErrorCounts, {'reference_not_found': 1});
      expect(lease.terminalErrorCode, 'create_task_burst_partial');
      expect(
        lease.terminalMessage,
        '已创建 12 个 Task，1 个未完成。失败原因：reference_not_found 1 个。',
      );
    });

    test(
      'success, decline and technical error stay disjoint and all reported',
      () {
        final lease = CreateTaskBurstLease(plannedCount: 13);
        for (var i = 0; i < 11; i++) {
          lease.record(const AgentToolResult(status: AgentToolStatus.success));
        }
        lease.record(
          const AgentToolResult(
            status: AgentToolStatus.error,
            errorCode: 'user_declined',
          ),
        );
        lease.record(
          const AgentToolResult(
            status: AgentToolStatus.error,
            errorCode: 'permission_denied',
          ),
        );

        expect(lease.successCount, 11);
        expect(lease.declinedCount, 1);
        expect(lease.errorCount, 1);
        expect(lease.safeErrorCounts, {'permission_denied': 1});
        expect(lease.safeErrorCounts.containsKey('user_declined'), isFalse);
        expect(
          lease.terminalMessage,
          '已创建 11 个 Task，2 个未完成。其中 1 个已取消。'
          '失败原因：permission_denied 1 个。',
        );
      },
    );

    test('0 success + 13 declines is create_task_burst_failed', () {
      final lease = CreateTaskBurstLease(plannedCount: 13);
      for (var i = 0; i < 13; i++) {
        lease.record(
          const AgentToolResult(
            status: AgentToolStatus.error,
            errorCode: 'user_declined',
          ),
        );
      }
      expect(lease.successCount, 0);
      expect(lease.declinedCount, 13);
      expect(lease.hasAnySuccess, isFalse);
      expect(lease.terminalErrorCode, 'create_task_burst_failed');
      expect(lease.terminalMessage, '未创建任何 Task。其中 13 个已取消。');
    });

    test('an unknown arbitrary error string becomes tool_error', () {
      final lease = CreateTaskBurstLease(plannedCount: 1);
      lease.record(
        const AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'SELECT * FROM tasks -- raw db text should not leak',
        ),
      );
      expect(lease.errorCount, 1);
      expect(lease.safeErrorCounts, {'tool_error': 1});
      expect(lease.terminalMessage, '未创建任何 Task。失败原因：tool_error 1 个。');
    });

    test('a null error string becomes tool_error', () {
      final lease = CreateTaskBurstLease(plannedCount: 1);
      lease.record(const AgentToolResult(status: AgentToolStatus.error));
      expect(lease.safeErrorCounts, {'tool_error': 1});
    });

    test('repeated_tool_call is retained as a safe technical code', () {
      final lease = CreateTaskBurstLease(plannedCount: 1);
      lease.record(
        const AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'repeated_tool_call',
        ),
      );
      expect(lease.errorCount, 1);
      expect(lease.safeErrorCounts, {'repeated_tool_call': 1});
      expect(lease.terminalErrorCode, 'create_task_burst_failed');
    });

    test('cancelled is a retained technical safe code, not a success', () {
      final lease = CreateTaskBurstLease(plannedCount: 1);
      lease.record(
        const AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'cancelled',
        ),
      );
      expect(lease.successCount, 0);
      expect(lease.declinedCount, 0);
      expect(lease.errorCount, 1);
      expect(lease.safeErrorCounts, {'cancelled': 1});
      expect(lease.terminalErrorCode, 'create_task_burst_failed');
    });

    test('recording more than plannedCount throws StateError', () {
      final lease = CreateTaskBurstLease(plannedCount: 2);
      lease.record(const AgentToolResult(status: AgentToolStatus.success));
      lease.record(const AgentToolResult(status: AgentToolStatus.success));
      expect(
        () => lease.record(
          const AgentToolResult(status: AgentToolStatus.success),
        ),
        throwsStateError,
      );
      expect(lease.processedCount, 2);
    });

    test('recordInterrupted handles the unstarted remainder', () {
      final lease = CreateTaskBurstLease(plannedCount: 5);
      lease.record(const AgentToolResult(status: AgentToolStatus.success));
      expect(lease.processedCount, 1);

      lease.recordInterrupted(4);
      expect(lease.processedCount, 5);
      expect(lease.isComplete, isTrue);
      // No replay metadata about interrupted tasks beyond the count.
      expect(lease.successCount, 1);
      expect(lease.declinedCount, 0);
    });
  });

  // Task 10 §4: protect the ordinary budget (12) and the createTask Burst.
  // Lifecycle/delete-tool turns must draw on the NORMAL budget (never a
  // createTask Burst), and the 13th normal call must be blocked.
  group('AgentRunToolBudget — lifecycle/delete tools budget edges (Task 10)',
      () {
    test('12 normal delete calls are executable, the 13th is blocked', () {
      final budget = AgentRunToolBudget();
      // A delete-tool turn is a normal turn (never a burst).
      for (var i = 0; i < 12; i++) {
        final decision = budget.preflightTurn(
          toolNames: const ['delete_schedule_relation'],
          allowedCreateTaskBurstLimit: 32,
        );
        expect(decision.kind, AgentToolTurnBudgetKind.normal,
            reason: 'delete call ${i + 1} should be normal');
        expect(budget.tryConsumeNormalCall(), isTrue, reason: 'call ${i + 1}');
      }
      expect(budget.normalCallsUsed, 12);
      expect(budget.normalCallsRemaining, 0);
      // The 13th normal call is blocked by the exhausted budget.
      expect(budget.tryConsumeNormalCall(), isFalse, reason: 'the 13th call');
    });

    test(
      'a delete-tool turn never gets a createTask Burst even with an '
      'allowance',
      () {
        final budget = AgentRunToolBudget();
        // 13 delete calls with an active burst allowance: still normal, never a
        // burst (the burst is create_task-specific).
        final decision = budget.preflightTurn(
          toolNames: List.filled(13, 'delete_schedule_relation'),
          allowedCreateTaskBurstLimit: 32,
        );
        expect(decision.kind, AgentToolTurnBudgetKind.normal);
        expect(budget.createTaskBurstUsed, isFalse);
      },
    );

    test(
      'a mixed turn of lifecycle delete tools and create_task stays normal '
      '(no burst)',
      () {
        final budget = AgentRunToolBudget();
        final names = <String>[
          'delete_schedule_relation',
          'create_task',
        ];
        final mixed = List<String>.generate(4, (i) => names[i % 2]);
        final decision = budget.preflightTurn(
          toolNames: mixed,
          allowedCreateTaskBurstLimit: 32,
        );
        // A mixed turn is never a dedicated burst; it stays normal and draws on
        // the ordinary quota.
        expect(decision.kind, AgentToolTurnBudgetKind.normal);
        expect(budget.createTaskBurstUsed, isFalse);
      },
    );

    test('each lifecycle tool family member is a normal turn', () {
      const lifecycleTools = [
        'update_event',
        'update_task',
        'update_plan_block',
        'delete_schedule_relation',
        'clear_reminder',
        'clear_user_overlay',
        'unlink_task_event',
        'reset_permission_policy',
        'undo_last_action',
      ];
      for (final tool in lifecycleTools) {
        final b = AgentRunToolBudget();
        final decision = b.preflightTurn(
          toolNames: [tool],
          allowedCreateTaskBurstLimit: 32,
        );
        expect(decision.kind, AgentToolTurnBudgetKind.normal,
            reason: '$tool should be a normal turn');
        expect(b.createTaskBurstUsed, isFalse, reason: '$tool must not use burst');
      }
    });
  });

  // Task 10: the sequential mutation ledger aggregates lifecycle write tools'
  // (cancel/delete/restore/clear/unlink/reset/undo) terminal results into a
  // 成功/拒绝/失败/未处理 count. It only summarizes already-issued calls, never
  // expands the budget, never saves titles/refs, and never auto-continues.
  group('MutationLedger — sequential lifecycle aggregation (Task 10)', () {
    test('a single successful delete yields success=1 and no override', () {
      final ledger = MutationLedger();
      ledger.record(
        'delete_schedule_relation',
        const AgentToolResult(status: AgentToolStatus.success),
      );
      expect(ledger.processedCount, 1);
      expect(ledger.successCount, 1);
      expect(ledger.declinedCount, 0);
      expect(ledger.failedCount, 0);
      expect(ledger.unhandledCount, 0);
      expect(ledger.terminalErrorCode, isNull);
      expect(ledger.terminalMessage, isNull);
    });

    test('a declined delete yields declined=1 and a non-success override', () {
      final ledger = MutationLedger();
      ledger.record(
        'delete_schedule_relation',
        const AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'user_declined',
        ),
      );
      expect(ledger.successCount, 0);
      expect(ledger.declinedCount, 1);
      expect(ledger.failedCount, 0);
      expect(ledger.unhandledCount, 0);
      expect(ledger.terminalErrorCode, 'mutation_declined');
    });

    test('a technical error yields failed=1 with a safe error code', () {
      final ledger = MutationLedger();
      ledger.record(
        'clear_reminder',
        const AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'target_not_found',
        ),
      );
      expect(ledger.successCount, 0);
      expect(ledger.declinedCount, 0);
      expect(ledger.failedCount, 1);
      expect(ledger.unhandledCount, 0);
      expect(ledger.safeErrorCounts, {'target_not_found': 1});
      expect(ledger.terminalErrorCode, 'mutation_failed');
    });

    test('a cancelled/interrupted write yields unhandled=1', () {
      final ledger = MutationLedger();
      ledger.record(
        'undo_last_action',
        const AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'cancelled',
        ),
      );
      expect(ledger.successCount, 0);
      expect(ledger.declinedCount, 0);
      expect(ledger.failedCount, 0);
      expect(ledger.unhandledCount, 1);
      expect(ledger.terminalErrorCode, 'mutation_unhandled');
    });

    test(
      'an unknown arbitrary error string folds to tool_error and counts as '
      'failed',
      () {
        final ledger = MutationLedger();
        ledger.record(
          'update_task',
          const AgentToolResult(
            status: AgentToolStatus.error,
            errorCode: 'SELECT * FROM tasks -- raw db text should not leak',
          ),
        );
        expect(ledger.failedCount, 1);
        expect(ledger.safeErrorCounts, {'tool_error': 1});
      },
    );

    test('a null error string folds to tool_error', () {
      final ledger = MutationLedger();
      ledger.record(
        'update_task',
        const AgentToolResult(status: AgentToolStatus.error),
      );
      expect(ledger.safeErrorCounts, {'tool_error': 1});
    });

    test('lifecycle safe codes are retained (already_deleted, stale_target)',
        () {
      final ledger = MutationLedger();
      ledger.record(
        'update_task',
        const AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'already_deleted',
        ),
      );
      ledger.record(
        'delete_schedule_relation',
        const AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'stale_target',
        ),
      );
      expect(ledger.failedCount, 2);
      expect(ledger.safeErrorCounts, {'already_deleted': 1, 'stale_target': 1});
    });

    test('mixed outcomes keep disjoint counts and a terminal message', () {
      final ledger = MutationLedger();
      ledger.record(
        'delete_schedule_relation',
        const AgentToolResult(status: AgentToolStatus.success),
      );
      ledger.record(
        'clear_reminder',
        const AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'user_declined',
        ),
      );
      ledger.record(
        'update_task',
        const AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'permission_denied',
        ),
      );
      ledger.record(
        'clear_user_overlay',
        const AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'cancelled',
        ),
      );
      expect(ledger.processedCount, 4);
      expect(ledger.successCount, 1);
      expect(ledger.declinedCount, 1);
      expect(ledger.failedCount, 1);
      expect(ledger.unhandledCount, 1);
      expect(ledger.hasAnySuccess, isTrue);
      expect(ledger.terminalErrorCode, 'mutation_partial');
      // The terminal message reports the four counts and never leaks titles.
      final msg = ledger.terminalMessage!;
      expect(msg, contains('成功 1'));
      expect(msg, contains('拒绝 1'));
      expect(msg, contains('失败 1'));
      expect(msg, contains('未处理 1'));
      expect(msg, isNot(contains('SELECT')));
    });

    test('all-success ledger has no override', () {
      final ledger = MutationLedger();
      ledger.record(
        'delete_schedule_relation',
        const AgentToolResult(status: AgentToolStatus.success),
      );
      ledger.record(
        'clear_reminder',
        const AgentToolResult(status: AgentToolStatus.success),
      );
      expect(ledger.successCount, 2);
      expect(ledger.terminalErrorCode, isNull);
      expect(ledger.terminalMessage, isNull);
    });

    test('no-success all-failed ledger is mutation_failed', () {
      final ledger = MutationLedger();
      ledger.record(
        'update_task',
        const AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'target_not_found',
        ),
      );
      expect(ledger.hasAnySuccess, isFalse);
      expect(ledger.terminalErrorCode, 'mutation_failed');
    });

    test('the terminal message never contains titles, refs, or ids', () {
      final ledger = MutationLedger();
      ledger.record(
        'delete_schedule_relation',
        const AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'reference_not_found',
          payload: {
            'title': '量子物理 B',
            'ref': 'ref_42',
            'id': 'rel-999',
          },
        ),
      );
      final msg = ledger.terminalMessage!;
      expect(msg, isNot(contains('量子物理')));
      expect(msg, isNot(contains('ref_42')));
      expect(msg, isNot(contains('rel-999')));
    });

    // Guards against _safeErrorCodes drift: every error code the lifecycle
    // write tools actually emit (mapLifecycleError + UpdateEventTool/
    // MoveJwCourseDayTool/CreateUserOverlayTool guards +
    // WriteConfirmationStore.resolve + commitAgentWriteAtomically) must fold
    // to ITSELF, not collapse to tool_error. If a new lifecycle code is added
    // to the tools but not the ledger set, this test fails.
    test('MutationLedger folds each known lifecycle code to itself', () {
      const knownLifecycleCodes = <String>{
        // mapLifecycleError codes.
        'relation_not_deletable',
        'relation_not_found',
        'link_not_found',
        'no_undo_available',
        'already_active',
        'already_deleted',
        'stale_target',
        'invalid_lifecycle_transition',
        // UpdateEventTool commit/propose guards.
        'scope_required',
        'source_event_not_editable',
        'whole_series_time_change_not_supported',
        // CreateUserOverlayTool commit guard.
        'no_course_series',
        // MoveJwCourseDayTool commit/propose guards.
        'no_eligible_jw_courses',
        // WriteConfirmationStore.resolve + commitAgentWriteAtomically.
        'confirmation_not_found',
        'write_commit_failed',
        // Registry fallback.
        'tool_execution_failed',
      };
      for (final code in knownLifecycleCodes) {
        final ledger = MutationLedger();
        ledger.record(
          'update_task',
          AgentToolResult(
            status: AgentToolStatus.error,
            errorCode: code,
          ),
        );
        expect(
          ledger.safeErrorCounts,
          {code: 1},
          reason:
              'lifecycle code "$code" must fold to itself, not tool_error',
        );
      }
    });
  });
}
