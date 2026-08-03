import 'package:flutter_test/flutter_test.dart';

import 'package:ustc_assistant_app/features/agent/domain/agent_tool.dart';
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
}
