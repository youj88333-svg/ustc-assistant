import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/agent/agent_action_tools.dart';
import 'package:ustc_assistant_m0/agent/agent_coordinator.dart';
import 'package:ustc_assistant_m0/agent/agent_read_tools.dart';
import 'package:ustc_assistant_m0/agent/agent_tool_contract.dart';
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/agent_discussion_contract.dart';
import 'package:ustc_assistant_m0/core/agent_parameter_issue.dart';
import 'package:ustc_assistant_m0/core/agent_source_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/diagnostics_contract.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/jobs/public_query_coordinator.dart';

void main() {
  group('Agent parameter diagnostics regressions', () {
    test(
      'native task proposal reports a safe repair, waits for approval, then commits once',
      () async {
        final diagnostics = _FakeDiagnostics();
        final rig = await _open(diagnostics: diagnostics);
        const question =
            '请新增任务，并添加一个一小时的任务时间块，截止日期是 2026-10-20。DIAG_QUESTION_SENTINEL';

        rig.gateway.enqueueEvents(
          _toolCall(
            _proposal([
              {
                'type': 'create_task',
                'title': 'DIAG_TITLE_SENTINEL',
                'description': '截止日期 2026-10-20',
              },
            ], id: 'missing-local-key'),
          ),
        );
        rig.gateway.enqueueEvents(
          _toolCall(
            _proposal([
              {
                'type': 'create_task',
                'local_key': 'review_task',
                'title': 'DIAG_TITLE_SENTINEL',
                'description': '截止日期 2026-10-20',
              },
              {
                'type': 'create_block',
                'task_key': 'review_task',
                'start': '2026-10-19T13:00+08:00',
                'end': '2026-10-19T14:00+08:00',
              },
            ], id: 'valid-task-and-block'),
          ),
        );
        rig.gateway.enqueueEvents(_answer('已准备任务和一小时安排。'));

        final running = rig.coordinator.send(question);
        await _until(
          () => rig.coordinator.view.phase == AgentPhase.waitingForApproval,
        );

        final pending = rig.coordinator.view.pendingAction!;
        expect(pending.status, AgentActionStatus.proposed);
        expect(await _count(rig.store, 'local_tasks'), 0);
        expect(await _count(rig.store, 'local_plan_blocks'), 0);
        expect(await _count(rig.store, 'agenda_plan_receipts'), 0);

        final correctionRequest = rig.gateway.generations[1].request;
        final rejected = _toolResult(correctionRequest);
        expect(rejected['status'], 'invalidRequest');
        expect(rejected['validation'], {
          'reason': 'missingField',
          'field': 'local_key',
          'action': 'create_task',
          'changeIndex': 0,
        });
        expect(
          ((rejected['data'] as Map)['action_rules'] as String),
          contains('local_key'),
        );
        expect(
          _completion(rig.gateway.generations[1]).toolCalls.single.name,
          'propose_local_changes',
        );
        final corrected =
            jsonDecode(
                  _completion(
                    rig.gateway.generations[1],
                  ).toolCalls.single.argumentsJson,
                )
                as Map<String, dynamic>;
        final changes = corrected['changes'] as List;
        expect((changes[0] as Map)['local_key'], 'review_task');
        expect((changes[1] as Map)['task_key'], 'review_task');
        expect(
          _toolNames(rig.gateway.generations.first.request),
          contains('propose_local_changes'),
        );

        await rig.coordinator.approveAction(pending.id);
        await running.timeout(const Duration(seconds: 3));
        await rig.coordinator.approveAction(pending.id);

        final tasks = await rig.store.localCalendar.queryTasks(
          const TaskQuery(filter: TaskFilter.all),
        );
        expect(tasks.items, hasLength(1));
        expect(tasks.items.single.draft.title, 'DIAG_TITLE_SENTINEL');
        expect(tasks.items.single.draft.description, '截止日期 2026-10-20');
        expect(tasks.items.single.draft.deadlineAtUtc, isNull);
        final detail = await rig.store.localCalendar.taskDetail(
          tasks.items.single.reference,
        );
        expect(detail.blocks, hasLength(1));
        expect(
          detail.blocks.single.draft.endsAtUtc.difference(
            detail.blocks.single.draft.startsAtUtc,
          ),
          const Duration(hours: 1),
        );
        expect(await _count(rig.store, 'agenda_plan_receipts'), 1);
        final savedAction = rig.coordinator.view.messages
            .expand((message) => message.actions)
            .singleWhere((action) => action.id == pending.id);
        expect(savedAction.status, AgentActionStatus.committed);

        final rejectedEvents = diagnostics.events
            .where((event) => event.name == DiagnosticEventName.toolRejected)
            .toList();
        expect(rejectedEvents, hasLength(1));
        expect(
          rejectedEvents.single.issue?.reason,
          AgentParameterReason.missingField,
        );
        expect(
          rejectedEvents.single.issue?.field,
          AgentParameterField.local_key,
        );
        expect(
          rejectedEvents.single.issue?.action,
          AgentChangeType.create_task,
        );
        expect(rejectedEvents.single.issue?.changeIndex, 0);
        expect(
          diagnostics.events.any(
            (event) =>
                event.name == DiagnosticEventName.approvalRequested &&
                event.outcome == DiagnosticOutcome.waitingForApproval,
          ),
          isTrue,
        );
        expect(
          diagnostics.events.any(
            (event) =>
                event.name == DiagnosticEventName.approvalDecided &&
                event.outcome == DiagnosticOutcome.complete,
          ),
          isTrue,
        );
        expect(
          diagnostics.events.any(
            (event) =>
                event.name == DiagnosticEventName.toolFinished &&
                event.outcome == DiagnosticOutcome.committed,
          ),
          isTrue,
        );
        _expectOneRunTrace(diagnostics.events);
        final exported = await diagnostics.exportRecent();
        expect(exported, contains(diagnosticProtocolVersion));
        for (final privateValue in const [
          'DIAG_QUESTION_SENTINEL',
          'DIAG_TITLE_SENTINEL',
          '2026-10-19',
          '2026-10-20',
          'review_task',
          'DIAGNOSTIC_KEY_SENTINEL_7d1a',
        ]) {
          expect(exported, isNot(contains(privateValue)), reason: privateValue);
        }
        final exportMap = jsonDecode(exported) as Map<String, dynamic>;
        expect(exportMap.keys.toSet(), {'version', 'records'});
      },
    );

    test(
      'date-only deadline gets a typed timestamp repair and remains in the approved task description',
      () async {
        final diagnostics = _FakeDiagnostics();
        final rig = await _open(diagnostics: diagnostics);
        rig.gateway.enqueueEvents(
          _toolCall(
            _proposal([
              {
                'type': 'create_task',
                'local_key': 'due_task',
                'title': '日期截止回归',
                'deadline': '2026-10-20',
              },
            ], id: 'date-only-deadline'),
          ),
        );
        rig.gateway.enqueueEvents(
          _toolCall(
            _proposal([
              {
                'type': 'create_task',
                'local_key': 'due_task',
                'title': '日期截止回归',
                'description': '用户给出的截止日期：2026-10-20',
              },
              {
                'type': 'create_block',
                'task_key': 'due_task',
                'start': '2026-10-19T09:00+08:00',
                'end': '2026-10-19T10:00+08:00',
              },
            ], id: 'date-preserving-correction'),
          ),
        );
        rig.gateway.enqueueEvents(_answer('已准备日期截止任务。'));

        final running = rig.coordinator.send(
          '请新增一个任务并添加一小时任务时间块，截止日期是 2026-10-20。',
        );
        await _until(
          () => rig.coordinator.view.phase == AgentPhase.waitingForApproval,
        );
        final action = rig.coordinator.view.pendingAction!;
        expect(action.status, AgentActionStatus.proposed);
        expect(await _count(rig.store, 'local_tasks'), 0);
        expect(await _count(rig.store, 'local_plan_blocks'), 0);

        final correctionRequest = rig.gateway.generations[1].request;
        final rejected = _toolResult(correctionRequest);
        expect(rejected['validation'], {
          'reason': 'invalidTimestamp',
          'field': 'deadline',
          'action': 'create_task',
          'changeIndex': 0,
        });
        expect(
          ((rejected['data'] as Map)['repair'] as String),
          contains('不猜时刻'),
        );
        expect(
          ((rejected['data'] as Map)['action_rules'] as String),
          contains('只知日期则省略deadline'),
        );
        final correctedCall = _completion(
          rig.gateway.generations[1],
        ).toolCalls.single;
        final corrected = jsonDecode(correctedCall.argumentsJson) as Map;
        final taskChange = (corrected['changes'] as List).first as Map;
        expect(taskChange.containsKey('deadline'), isFalse);
        expect(taskChange['description'], contains('2026-10-20'));
        expect(
          _toolNames(rig.gateway.generations.first.request),
          contains('propose_local_changes'),
        );

        await rig.coordinator.approveAction(action.id);
        await running.timeout(const Duration(seconds: 3));
        final tasks = await rig.store.localCalendar.queryTasks(
          const TaskQuery(filter: TaskFilter.all),
        );
        expect(tasks.items, hasLength(1));
        expect(tasks.items.single.draft.description, contains('2026-10-20'));
        expect(tasks.items.single.draft.deadlineAtUtc, isNull);
        final detail = await rig.store.localCalendar.taskDetail(
          tasks.items.single.reference,
        );
        expect(detail.blocks, hasLength(1));
        expect(
          detail.blocks.single.draft.endsAtUtc.difference(
            detail.blocks.single.draft.startsAtUtc,
          ),
          const Duration(hours: 1),
        );
        expect(await _count(rig.store, 'agenda_plan_receipts'), 1);
        expect(
          diagnostics.events.any(
            (event) =>
                event.name == DiagnosticEventName.toolRejected &&
                event.issue?.reason == AgentParameterReason.invalidTimestamp &&
                event.issue?.field == AgentParameterField.deadline,
          ),
          isTrue,
        );
      },
    );

    test(
      'two different invalid proposals finish as invalidInput without an action or business write',
      () async {
        final diagnostics = _FakeDiagnostics();
        final rig = await _open(diagnostics: diagnostics);
        rig.gateway.enqueueEvents(
          _toolCall(
            _proposal([
              {'type': 'create_task', 'title': '未完成参数'},
            ], id: 'first-invalid-proposal'),
          ),
        );
        rig.gateway.enqueueEvents(
          _toolCall(
            _proposal([
              {
                'type': 'create_task',
                'local_key': 'bad_date',
                'title': '第二种无效参数',
                'deadline': 'not-a-timestamp',
              },
            ], id: 'second-invalid-proposal'),
          ),
        );

        await rig.coordinator.send('请新增一个任务，并设置截止时间。');

        expect(rig.coordinator.view.failure, AgentFailureCode.invalidInput);
        expect(
          rig.coordinator.view.parameterIssue?.reason,
          AgentParameterReason.invalidTimestamp,
        );
        expect(
          rig.coordinator.view.parameterIssue?.field,
          AgentParameterField.deadline,
        );
        expect(
          rig.coordinator.view.parameterIssue?.action,
          AgentChangeType.create_task,
        );
        expect(rig.coordinator.view.parameterIssue?.changeIndex, 0);
        expect(rig.coordinator.view.pendingAction, isNull);
        expect(rig.gateway.generations, hasLength(2));
        expect(
          _toolResult(rig.gateway.generations[1].request)['status'],
          'invalidRequest',
        );
        expect(await _count(rig.store, 'local_tasks'), 0);
        expect(await _count(rig.store, 'local_plan_blocks'), 0);
        expect(await _count(rig.store, 'agenda_plan_receipts'), 0);

        final rejected = diagnostics.events
            .where((event) => event.name == DiagnosticEventName.toolRejected)
            .toList();
        expect(rejected, hasLength(2));
        expect(rejected[0].issue?.reason, AgentParameterReason.missingField);
        expect(
          rejected[1].issue?.reason,
          AgentParameterReason.invalidTimestamp,
        );
        expect(
          diagnostics.events.any(
            (event) =>
                event.name == DiagnosticEventName.agentRunFailed &&
                event.code == DiagnosticCode.invalidInput,
          ),
          isTrue,
        );
        _expectOneRunTrace(diagnostics.events);
      },
    );

    test(
      'public-only model requests and a short follow-up omit personal/source tools; direct source calls stay unavailable',
      () async {
        final sources = _SpySourcePort();
        final rig = await _open(sources: sources);
        expect(
          rig.actionTools.definitions.map((tool) => tool.name),
          containsAll(const [
            'query_source_options',
            'request_source_refresh',
            'query_young_activities',
          ]),
        );

        final questions = const [
          '只查公开资料，解释教务课表同步流程。',
          '只查公开资料，看看二课有哪些活动。',
          '继续详细',
          '你好',
        ];
        for (var index = 0; index < questions.length; index++) {
          rig.gateway.enqueueEvents(_answer('合成公开答复 $index。'));
          await rig.coordinator.send(questions[index]);
          final names = _toolNames(rig.gateway.generations.last.request);
          expect(
            names.intersection(_forbiddenPublicOnlyTools),
            isEmpty,
            reason: questions[index],
          );
        }
        expect(sources.operationCalls, 0);

        final direct = rig.actionTools.openSession();
        final interactive = direct as AgentInteractiveToolSession;
        interactive.bindRun(_testTicket(), '只查公开资料，看看二课有哪些活动。');
        final result = await direct.execute(
          const ModelToolCall(
            id: 'direct-public-source-attempt',
            name: 'query_young_activities',
            argumentsJson: '{}',
          ),
        );
        expect(result.status, 'unavailable');
        expect(result.failure, 'unavailable');
        expect(sources.operationCalls, 0);
        direct.revoke();
      },
    );

    test(
      'same primary chat keeps history and clears a real task discussion selection',
      () async {
        final rig = await _open();
        final snapshot = await rig.store.localCalendar.query(
          CalendarQuery(
            firstDay: DateTime.utc(2026, 10, 13),
            endDayExclusive: DateTime.utc(2026, 10, 14),
          ),
        );
        final command = await rig.store.localCalendar.prepare(
          snapshot.context,
          const CreateTask(TaskDraft(title: '合成讨论任务')),
        );
        await rig.store.localCalendar.commit(command);
        final task = (await rig.store.localCalendar.queryTasks(
          const TaskQuery(filter: TaskFilter.all),
        )).items.single;

        rig.gateway.enqueueEvents(_answer('此前普通回答。'));
        await rig.coordinator.send('此前普通问题');
        final discussionConversation = rig.coordinator.view.conversationId!;
        final historyBeforeDiscussion = await rig.store.agent.messages(
          discussionConversation,
        );

        await rig.coordinator.prepareDiscussion(
          AgentDiscussionSelection.task(task.reference),
        );
        expect(rig.coordinator.view.conversationId, discussionConversation);
        expect(rig.coordinator.view.discussionDraft, isNotNull);
        expect(rig.coordinator.view.discussionId, isNotNull);

        await rig.coordinator.newConversation();
        expect(rig.coordinator.view.conversationId, discussionConversation);
        expect(rig.coordinator.view.discussionDraft, isNull);
        expect(rig.coordinator.view.discussionId, isNull);
        final historyAfterNewConversation = await rig.store.agent.messages(
          discussionConversation,
        );
        expect(
          historyAfterNewConversation
              .map(
                (message) =>
                    (message.id, message.role, message.text, message.status),
              )
              .toList(),
          historyBeforeDiscussion
              .map(
                (message) =>
                    (message.id, message.role, message.text, message.status),
              )
              .toList(),
        );

        rig.gateway.enqueueEvents(_answer('你好。'));
        await rig.coordinator.send('你好');
        final request = rig.gateway.generations.last.request;
        expect(request.messages.last.content, '你好');
        expect(
          request.messages.map((message) => message.content ?? '').join('\n'),
          contains('此前普通问题'),
        );
        expect(
          request.messages.map((message) => message.content ?? '').join('\n'),
          contains('此前普通回答。'),
        );
        expect(request.messages.last.content, isNot(contains('[应用选择]')));
        expect(_toolNames(request), isEmpty);
        expect(
          request.tools.map((tool) => tool.name),
          isNot(contains('read_task')),
        );
      },
    );

    test(
      'call:1 and call.1 complete paired scripted rounds while a repeated id fails protocol',
      () async {
        final rig = await _open();
        rig.gateway.enqueueEvents([
          ..._toolCall(
            const ModelToolCall(
              id: 'call:1',
              name: 'query_tasks',
              argumentsJson: '{"limit":1}',
            ),
          ),
        ]);
        rig.gateway.enqueueEvents([
          ..._toolCall(
            const ModelToolCall(
              id: 'call.1',
              name: 'query_tasks',
              argumentsJson: '{"limit":2}',
            ),
          ),
        ]);
        rig.gateway.enqueueEvents(_answer('已完成两轮合成任务查询。'));

        await rig.coordinator.send('查询任务');

        expect(rig.coordinator.view.failure, isNull);
        expect(rig.gateway.generations, hasLength(3));
        final pairedRequest = rig.gateway.generations.last.request;
        final assistantCalls = pairedRequest.messages
            .where((message) => message.role == 'assistant')
            .expand((message) => message.toolCalls)
            .toList();
        expect(assistantCalls.map((call) => call.id), ['call:1', 'call.1']);
        final toolResults = pairedRequest.messages
            .where((message) => message.role == 'tool')
            .toList();
        expect(toolResults.map((message) => message.toolCallId), [
          'call:1',
          'call.1',
        ]);
      },
    );

    test('a repeated tool id fails the scripted loop as protocol', () async {
      final rig = await _open();
      rig.gateway.enqueueEvents(
        _toolCall(
          const ModelToolCall(
            id: 'call:1',
            name: 'query_tasks',
            argumentsJson: '{"limit":1}',
          ),
        ),
      );
      rig.gateway.enqueueEvents(
        _toolCall(
          const ModelToolCall(
            id: 'call:1',
            name: 'query_tasks',
            argumentsJson: '{"limit":2}',
          ),
        ),
      );

      await rig.coordinator.send('查询任务');

      expect(rig.coordinator.view.failure, AgentFailureCode.protocol);
      expect(rig.gateway.generations, hasLength(2));
    });

    test(
      'a model failure after approval keeps the committed C3 action and terminal diagnostics',
      () async {
        final diagnostics = _FakeDiagnostics();
        final rig = await _open(diagnostics: diagnostics);
        rig.gateway.enqueueEvents(
          _toolCall(_proposal(_taskAndBlock('failure_task'))),
        );
        rig.gateway.enqueueFailure(
          const AgentFailure(AgentFailureCode.networkFailed),
        );

        final running = rig.coordinator.send('请新增任务并添加一个一小时任务时间块。');
        await _until(
          () => rig.coordinator.view.phase == AgentPhase.waitingForApproval,
        );
        final action = rig.coordinator.view.pendingAction!;
        await rig.coordinator.approveAction(action.id);
        await running.timeout(const Duration(seconds: 3));

        expect(rig.coordinator.view.failure, AgentFailureCode.networkFailed);
        expect(await _count(rig.store, 'agenda_plan_receipts'), 1);
        expect(await _count(rig.store, 'local_tasks'), 1);
        expect(await _count(rig.store, 'local_plan_blocks'), 1);
        expect(
          _savedAction(rig, action.id).status,
          AgentActionStatus.committed,
        );
        expect(
          diagnostics.events.any(
            (event) =>
                event.name == DiagnosticEventName.toolFinished &&
                event.outcome == DiagnosticOutcome.committed,
          ),
          isTrue,
        );
        expect(
          diagnostics.events.any(
            (event) =>
                event.name == DiagnosticEventName.agentRunFailed &&
                event.code == DiagnosticCode.networkFailed,
          ),
          isTrue,
        );
        _expectOneRunTrace(diagnostics.events);
      },
    );

    test(
      'stopping the model after approval preserves the committed action and reports cancellation separately',
      () async {
        final diagnostics = _FakeDiagnostics();
        final rig = await _open(diagnostics: diagnostics);
        rig.gateway.enqueueEvents(
          _toolCall(_proposal(_taskAndBlock('stop_task'))),
        );

        final running = rig.coordinator.send('请新增任务并添加一个一小时任务时间块。');
        await _until(
          () => rig.coordinator.view.phase == AgentPhase.waitingForApproval,
        );
        final action = rig.coordinator.view.pendingAction!;
        await rig.coordinator.approveAction(action.id);
        await _until(() => rig.gateway.generations.length == 2);
        await rig.gateway.generations[1].started.future.timeout(
          const Duration(seconds: 2),
        );

        await rig.coordinator.stop().timeout(const Duration(seconds: 3));
        await running.timeout(const Duration(seconds: 3));

        expect(await _count(rig.store, 'agenda_plan_receipts'), 1);
        expect(await _count(rig.store, 'local_tasks'), 1);
        expect(await _count(rig.store, 'local_plan_blocks'), 1);
        expect(
          _savedAction(rig, action.id).status,
          AgentActionStatus.committed,
        );
        expect(
          diagnostics.events.any(
            (event) =>
                event.name == DiagnosticEventName.agentStopRequested &&
                event.outcome == DiagnosticOutcome.cancelled,
          ),
          isTrue,
        );
        expect(
          diagnostics.events.any(
            (event) =>
                event.name == DiagnosticEventName.toolFinished &&
                event.outcome == DiagnosticOutcome.committed,
          ),
          isTrue,
        );
        _expectOneRunTrace(diagnostics.events);
      },
    );

    test(
      'configuration and non-current history maintenance have safe terminal diagnostics',
      () async {
        const keySentinel = 'DIAGNOSTIC_KEY_SENTINEL_7d1a';
        const bodySentinel = 'HISTORY_BODY_SENTINEL_1c4f';
        const storageErrorSentinel = 'DIAGNOSTIC_FAILURE_SENTINEL';
        final diagnostics = _FakeDiagnostics();
        final rig = await _open(diagnostics: diagnostics);

        final historyConversation = await rig.store.agent.createConversation();
        await _completeSyntheticRun(
          rig.store,
          historyConversation,
          '归档合成问题',
          '归档合成回答',
        );
        final currentConversation = rig.coordinator.view.conversationId!;
        expect(historyConversation, isNot(currentConversation));
        rig.gateway.enqueueEvents(_answer('合成历史答复。'));
        await rig.coordinator.send(bodySentinel);
        final originalMessages = await rig.store.agent.messages(
          historyConversation,
        );
        expect(originalMessages, hasLength(2));

        expect(rig.coordinator.view.conversationId, currentConversation);

        final settingsBeforeRejectedClear = await rig.store.agent
            .inspectAgent();
        await rig.coordinator.clearHistory(
          conversationId: historyConversation,
          confirmed: false,
        );
        final messagesAfterRejectedClear = await rig.store.agent.messages(
          historyConversation,
        );
        expect(
          messagesAfterRejectedClear
              .map(
                (message) =>
                    (message.id, message.role, message.text, message.status),
              )
              .toList(),
          originalMessages
              .map(
                (message) =>
                    (message.id, message.role, message.text, message.status),
              )
              .toList(),
        );
        expect(
          (await rig.store.agent.conversations()).any(
            (conversation) => conversation.id == historyConversation,
          ),
          isTrue,
        );
        expect(
          (await rig.store.agent.inspectAgent()).authority.historyEpoch,
          settingsBeforeRejectedClear.authority.historyEpoch,
        );
        expect(rig.coordinator.view.conversationId, currentConversation);

        final rejectedClear = diagnostics.events
            .where(
              (event) =>
                  event.name == DiagnosticEventName.historyMaintenance &&
                  event.operation == DiagnosticOperation.clearHistory &&
                  event.outcome != null,
            )
            .toList();
        expect(rejectedClear, hasLength(2));
        expect(rejectedClear.map((event) => event.outcome), [
          DiagnosticOutcome.started,
          DiagnosticOutcome.rejected,
        ]);
        expect(rejectedClear.last.stage, DiagnosticStage.history);
        expect(rejectedClear.last.code, isNotNull);
        expect(
          rejectedClear.last.trace!.value,
          rejectedClear.first.trace!.value,
        );

        await rig.store.customStatement('''
          CREATE TRIGGER synthetic_agent_consent_failure
          BEFORE UPDATE OF consent ON agent_config
          BEGIN
            SELECT RAISE(ABORT, '$storageErrorSentinel');
          END
        ''');
        await rig.coordinator.setModelConsent(false);
        final consentAfterFailure = await rig.store.agent.inspectAgent();
        expect(consentAfterFailure.consent, isTrue);
        expect(consentAfterFailure.keySaved, isTrue);

        final consentFailures = diagnostics.events
            .where(
              (event) =>
                  event.name == DiagnosticEventName.modelConfiguration &&
                  event.operation == DiagnosticOperation.changeModelConsent,
            )
            .toList();
        expect(consentFailures, hasLength(2));
        expect(consentFailures.first.stage, DiagnosticStage.configuration);
        expect(consentFailures.first.outcome, DiagnosticOutcome.started);
        expect(consentFailures.last.stage, DiagnosticStage.configuration);
        expect(consentFailures.last.outcome, DiagnosticOutcome.failure);
        expect(consentFailures.last.code, isNotNull);
        expect(
          consentFailures.last.trace!.value,
          consentFailures.first.trace!.value,
        );

        await rig.store.customStatement(
          'DROP TRIGGER synthetic_agent_consent_failure',
        );
        await rig.coordinator.deleteKey(confirmed: true);
        await rig.coordinator.setModelConsent(false);
        final settingsAfterConfiguration = await rig.store.agent.inspectAgent();
        expect(settingsAfterConfiguration.keySaved, isFalse);
        expect(settingsAfterConfiguration.consent, isFalse);

        await rig.coordinator.clearHistory(
          conversationId: historyConversation,
          confirmed: true,
        );
        expect(await rig.store.agent.messages(historyConversation), isEmpty);
        expect(
          (await rig.store.agent.conversations()).any(
            (conversation) => conversation.id == historyConversation,
          ),
          isFalse,
        );
        expect(rig.coordinator.view.conversationId, currentConversation);

        _expectOperationPairs(
          diagnostics.events,
          name: DiagnosticEventName.modelConfiguration,
          operation: DiagnosticOperation.deleteModelKey,
          stage: DiagnosticStage.configuration,
          terminalOutcomes: const [DiagnosticOutcome.committed],
        );
        _expectOperationPairs(
          diagnostics.events,
          name: DiagnosticEventName.modelConfiguration,
          operation: DiagnosticOperation.changeModelConsent,
          stage: DiagnosticStage.configuration,
          terminalOutcomes: const [
            DiagnosticOutcome.failure,
            DiagnosticOutcome.committed,
          ],
        );
        final successfulHistoryTrace = diagnostics.events
            .singleWhere(
              (event) =>
                  event.name == DiagnosticEventName.historyMaintenance &&
                  event.operation == DiagnosticOperation.clearHistory &&
                  event.outcome == DiagnosticOutcome.committed,
            )
            .trace!
            .value;
        final successfulHistoryEvents = diagnostics.events
            .where(
              (event) =>
                  event.name == DiagnosticEventName.historyMaintenance &&
                  event.operation == DiagnosticOperation.clearHistory &&
                  event.trace?.value == successfulHistoryTrace,
            )
            .toList();
        _expectOperationPairs(
          successfulHistoryEvents,
          name: DiagnosticEventName.historyMaintenance,
          operation: DiagnosticOperation.clearHistory,
          stage: DiagnosticStage.history,
          terminalOutcomes: const [DiagnosticOutcome.committed],
        );

        final runTrace = diagnostics.events
            .singleWhere(
              (event) => event.name == DiagnosticEventName.agentRunStarted,
            )
            .trace!
            .value;
        final operationEvents = diagnostics.events.where(
          (event) => event.operation != null,
        );
        for (final event in operationEvents) {
          expect(event.trace, isNotNull);
          expect(event.trace!.value, matches(RegExp(r'^[a-f0-9]{32}$')));
          expect(event.trace!.value, isNot(runTrace));
          expect(event.phase, isNull);
          expect(event.tool, isNull);
          expect(event.issue, isNull);
          expect(event.modelCalls, isNull);
          expect(event.toolCalls, isNull);
          expect(event.count, isNull);
          expect(event.httpStatus, isNull);
        }

        final exported = await diagnostics.exportRecent();
        for (final privateValue in [
          keySentinel,
          bodySentinel,
          storageErrorSentinel,
          'synthetic-agent-diagnostics-model',
          historyConversation,
          currentConversation,
          'synthetic-diagnostics-owner',
          'synthetic-diagnostics-conversation',
        ]) {
          expect(exported, isNot(contains(privateValue)), reason: privateValue);
        }
      },
    );
  });
}

void _expectOperationPairs(
  List<DiagnosticEvent> source, {
  required DiagnosticEventName name,
  required DiagnosticOperation operation,
  required DiagnosticStage stage,
  required List<DiagnosticOutcome> terminalOutcomes,
}) {
  final events = source
      .where((event) => event.name == name && event.operation == operation)
      .toList();
  expect(events, hasLength(terminalOutcomes.length * 2));
  for (var index = 0; index < terminalOutcomes.length; index++) {
    final started = events[index * 2];
    final terminal = events[index * 2 + 1];
    expect(started.stage, stage);
    expect(started.outcome, DiagnosticOutcome.started);
    expect(terminal.stage, stage);
    expect(terminal.outcome, terminalOutcomes[index]);
    expect(started.trace, isNotNull);
    expect(terminal.trace!.value, started.trace!.value);
    if (terminalOutcomes[index] == DiagnosticOutcome.committed) {
      expect(terminal.code, isNull);
    } else {
      expect(terminal.code, isNotNull);
    }
  }
}

const _forbiddenPublicOnlyTools = <String>{
  'query_agenda',
  'read_event',
  'query_tasks',
  'read_task',
  'inspect_conflicts',
  'propose_local_changes',
  'propose_undo',
  'find_free_slots',
  'propose_planning_preferences',
  'query_source_options',
  'request_source_refresh',
  'query_young_activities',
};

Future<_Rig> _open({
  DiagnosticsPort? diagnostics,
  _SpySourcePort? sources,
}) async {
  final clock = FixedClock(DateTime.utc(2026, 10, 13, 8));
  final store = JwStore(
    NativeDatabase.memory(),
    ownership: _TestOwnership(),
    clock: clock,
    modelCredentialProtector: _SyntheticProtector(),
  );
  addTearDown(store.close);
  await store.initialize();
  await store.agent.initializeAgent();
  await store.agent.ensurePrimaryConversation();
  final settings = await store.agent.inspectAgent();
  await store.agent.saveModelConfiguration(
    settings.authority,
    modelId: 'synthetic-agent-diagnostics-model',
    modelIds: const ['synthetic-agent-diagnostics-model'],
    report: const AgentCapabilityReport(
      text: true,
      streaming: true,
      toolCall: true,
      toolResult: true,
    ),
    consent: true,
    key: Uint8List.fromList('DIAGNOSTIC_KEY_SENTINEL_7d1a'.codeUnits),
  );

  final publicQueries = PublicQueryCoordinator(
    store: store.publicStore,
    leases: WorkLeasePool(),
    clock: clock,
    sessionFactory: (source) => throw StateError('synthetic HTTP disabled'),
  );
  final readTools = AgentReadTools(
    calendar: store.localCalendar,
    tasks: store.localCalendar,
    calendarGuard: store.localCalendar,
    knowledge: store.publicStore,
    knowledgeGuard: store.publicStore,
    publicQueries: publicQueries,
    publicGuard: publicQueries,
    clock: clock,
  );
  final actionTools = AgentActionTools(
    readTools: readTools,
    plans: store.localCalendar,
    calendar: store.localCalendar,
    tasks: store.localCalendar,
    preferences: store.agent,
    preferenceProposals: store.agent,
    sources: sources,
    actionRecords: sources == null ? null : store.agent,
    clock: clock,
  );
  final gateway = _ScriptedGateway();
  final coordinator = AgentCoordinator(
    data: store.agent,
    gateway: gateway,
    readTools: actionTools,
    clock: clock,
    diagnostics: diagnostics,
  );
  addTearDown(coordinator.close);
  await coordinator.initialize();
  return _Rig(store, actionTools, gateway, coordinator);
}

ModelToolCall _proposal(
  List<Map<String, Object?>> changes, {
  String id = 'native-proposal',
}) => ModelToolCall(
  id: id,
  name: 'propose_local_changes',
  argumentsJson: jsonEncode({'changes': changes}),
);

List<Map<String, Object?>> _taskAndBlock(String key) => [
  {
    'type': 'create_task',
    'local_key': key,
    'title': '提交后的合成任务',
    'description': '仅用于本地 C3 回归。',
  },
  {
    'type': 'create_block',
    'task_key': key,
    'start': '2026-10-19T13:00+08:00',
    'end': '2026-10-19T14:00+08:00',
  },
];

List<ModelEvent> _answer(String text) => [
  ModelTextDelta(text),
  ModelCompleted(finishReason: 'stop'),
];

Future<void> _completeSyntheticRun(
  JwStore store,
  String conversationId,
  String question,
  String answer,
) async {
  final settings = await store.agent.inspectAgent();
  final ticket = await store.agent.beginRun(
    settings.authority,
    conversationId,
    question,
  );
  await store.agent.saveAssistant(ticket, answer);
  await store.agent.finishRun(ticket, AgentMessageStatus.complete);
}

List<ModelEvent> _toolCall(ModelToolCall call) => [
  ModelCompleted(finishReason: 'tool_calls', toolCalls: [call]),
];

Set<String> _toolNames(ModelRequest request) =>
    request.tools.map((tool) => tool.name).toSet();

ModelCompleted _completion(_SyntheticGeneration generation) =>
    generation.events.whereType<ModelCompleted>().single;

Map<String, dynamic> _toolResult(ModelRequest request) =>
    jsonDecode(
          request.messages
              .where((message) => message.role == 'tool')
              .last
              .content!,
        )
        as Map<String, dynamic>;

AgentActionView _savedAction(_Rig rig, String id) => rig
    .coordinator
    .view
    .messages
    .expand((message) => message.actions)
    .singleWhere((action) => action.id == id);

Future<int> _count(JwStore store, String table) async =>
    (await store.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
        .read<int>('n');

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Synthetic Agent state was not reached.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void _expectOneRunTrace(List<DiagnosticEvent> events) {
  final traces = events.map((event) => event.trace?.value).toSet();
  expect(traces, hasLength(1));
  expect(traces.single, matches(RegExp(r'^[a-f0-9]{32}$')));
}

AgentRunTicket _testTicket() => AgentRunTicket(
  authority: const AgentAuthority(
    owner: 'synthetic-agent-diagnostics-owner',
    resetEpoch: 1,
    historyEpoch: 1,
    configRevision: 1,
  ),
  runId: 'synthetic-diagnostics-run',
  conversationId: 'synthetic-diagnostics-conversation',
  conversationGeneration: 1,
  runGeneration: 1,
  assistantMessageId: 1,
);

final class _Rig {
  const _Rig(this.store, this.actionTools, this.gateway, this.coordinator);
  final JwStore store;
  final AgentActionTools actionTools;
  final _ScriptedGateway gateway;
  final AgentCoordinator coordinator;
}

final class _FakeDiagnostics implements DiagnosticsPort {
  final Random _random = Random.secure();
  final List<DiagnosticEvent> events = [];

  @override
  DiagnosticsView get diagnosticsView => const DiagnosticsView(available: true);

  @override
  DiagnosticTrace newTrace() => DiagnosticTrace(
    List.generate(
      16,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join(),
  );

  @override
  void record(DiagnosticEvent event) => events.add(event);

  @override
  Future<void> flush() async {}

  @override
  Future<String> exportRecent() async => jsonEncode({
    'version': diagnosticProtocolVersion,
    'records': [
      for (final event in events)
        DiagnosticRecord(
          atUtc: DateTime.utc(2026, 10, 13, 8),
          event: event,
        ).toMap(),
    ],
  });

  @override
  Future<void> clear() async => events.clear();

  @override
  Future<void> close() async {}
}

final class _SpySourcePort implements AgentSourcePort {
  int operationCalls = 0;

  @override
  bool get waitingForSchool => false;

  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  Future<AgentSourceOptions> readOptions(AgentRunTicket ticket) async {
    operationCalls++;
    throw StateError('Synthetic source access must stay closed.');
  }

  @override
  Future<AgentSourceResult> refresh(
    AgentRunTicket ticket,
    AgentActionView approvedRecord,
    AgentSourceRequest request,
  ) async {
    operationCalls++;
    throw StateError('Synthetic source access must stay closed.');
  }

  @override
  Future<AgentSourceResult> queryActivities(AgentRunTicket ticket) async {
    operationCalls++;
    throw StateError('Synthetic source access must stay closed.');
  }

  @override
  Future<void> continueSchool() async {
    operationCalls++;
  }

  @override
  Future<void> cancelAndDrain() async {}

  @override
  Future<void> close() async {}
}

final class _ScriptedGateway implements ModelGatewayPort {
  final Queue<Future<void> Function(_SyntheticGeneration)> _scripts = Queue();
  final List<_SyntheticGeneration> generations = [];
  bool _closed = false;

  void enqueueEvents(List<ModelEvent> events) {
    _scripts.add((generation) async {
      for (final event in events) {
        if (!generation.emit(event)) return;
      }
      await generation.finish();
    });
  }

  void enqueueFailure(Object error) {
    _scripts.add((generation) async {
      await generation.fail(error);
    });
  }

  @override
  Future<List<String>> listModels(ModelSecretLease secret) async {
    _consume(secret);
    return const ['synthetic-agent-diagnostics-model'];
  }

  @override
  Stream<ModelEvent> generate(ModelRequest request, ModelSecretLease secret) {
    _consume(secret);
    if (_closed) {
      return Stream<ModelEvent>.error(
        const AgentFailure(AgentFailureCode.closed),
      );
    }
    final generation = _SyntheticGeneration(request);
    generations.add(generation);
    if (_scripts.isNotEmpty) {
      unawaited(_play(generation, _scripts.removeFirst()));
    }
    return generation.stream;
  }

  void _consume(ModelSecretLease secret) {
    final bytes = secret.take();
    bytes.fillRange(0, bytes.length, 0);
  }

  Future<void> _play(
    _SyntheticGeneration generation,
    Future<void> Function(_SyntheticGeneration) script,
  ) async {
    await generation.started.future;
    try {
      await script(generation);
    } on Object catch (error) {
      if (!generation.isClosed) await generation.fail(error);
    }
  }

  @override
  Future<void> cancelAndDrain() async {
    await Future.wait(
      generations
          .where((generation) => !generation.isClosed)
          .map((generation) => generation.finish()),
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    await cancelAndDrain();
    _closed = true;
  }
}

final class _SyntheticGeneration {
  _SyntheticGeneration(this.request) {
    controller = StreamController<ModelEvent>(
      onListen: () {
        if (!started.isCompleted) started.complete();
      },
    );
  }

  final ModelRequest request;
  final Completer<void> started = Completer<void>();
  final List<ModelEvent> events = [];
  late final StreamController<ModelEvent> controller;
  Future<void>? _closing;
  Stream<ModelEvent> get stream => controller.stream;
  bool get isClosed => controller.isClosed;

  bool emit(ModelEvent event) {
    if (controller.isClosed) return false;
    events.add(event);
    controller.add(event);
    return true;
  }

  Future<bool> fail(Object error) async {
    if (controller.isClosed) return false;
    controller.addError(error);
    await finish();
    return true;
  }

  Future<void> finish() => _closing ??= controller.close();
}

final class _SyntheticProtector implements ModelCredentialProtector {
  @override
  String get mechanism => 'synthetic-agent-diagnostics-key/v1';

  @override
  Future<Uint8List> protect(
    Uint8List plaintext, {
    required String purpose,
  }) async =>
      Uint8List.fromList([0xA7, ...plaintext.map((byte) => byte ^ 0x5A)]);

  @override
  Future<Uint8List> unprotect(
    Uint8List ciphertext, {
    required String purpose,
  }) async {
    if (ciphertext.isEmpty || ciphertext.first != 0xA7) {
      throw StateError('Synthetic ciphertext was invalid.');
    }
    return Uint8List.fromList(
      ciphertext.skip(1).map((byte) => byte ^ 0x5A).toList(),
    );
  }
}

final class _TestOwnership implements AssetOwnership {
  @override
  bool get isHeld => true;

  @override
  void ensureHeld() {}
}
