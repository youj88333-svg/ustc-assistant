import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show QueryExecutor, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:ustc_assistant_m0/agent/agent_context.dart';
import 'package:ustc_assistant_m0/agent/agent_invocation_fingerprint.dart';
import 'package:ustc_assistant_m0/core/agent_action_contract.dart';
import 'package:ustc_assistant_m0/core/agent_context_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/agent_permission_contract.dart';
import 'package:ustc_assistant_m0/core/agent_source_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/settings_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';

final _clock = FixedClock(DateTime.utc(2026, 10, 14, 1));
final _syntheticKey = Uint8List.fromList(
  'synthetic-context-test-key'.codeUnits,
);

void main() {
  test(
    'basic policy is empty and the daily opt-in grants only its 17 categories',
    () async {
      final store = await _open();
      final initial = await store.agent.readAgentUsePolicy();
      expect(initial.configured, isFalse);
      expect(initial.personalContentAllowed, isFalse);
      expect(initial.dailyOperationsAllowed, isFalse);
      expect(initial.granted, isEmpty);

      for (final invalidOptions in [
        AgentContextOptions(inputTokens: 4095),
        AgentContextOptions(outputTokens: 8193),
        AgentContextOptions(modelCalls: 0),
        AgentContextOptions(toolCalls: 257),
        AgentContextOptions(activeSeconds: 3601),
      ]) {
        await _agentFailure(
          store.agent.saveAgentUsePolicy(
            initial,
            personalContentAllowed: false,
            dailyOperationsAllowed: false,
            contextOptions: invalidOptions,
          ),
          AgentFailureCode.invalidInput,
        );
      }
      final stillInitial = await store.agent.readAgentUsePolicy();
      expect(stillInitial.revision, initial.revision);
      expect(stillInitial.configured, isFalse);

      await _establishTaskGrant(store);
      final singleGrant = (await store.agent.readActionPermissions()).single;
      expect(singleGrant.category, AgentPermissionCategory.createTask);

      final beforePackage = await store.agent.readAgentUsePolicy();
      await store.agent.saveAgentUsePolicy(
        beforePackage,
        personalContentAllowed: true,
        dailyOperationsAllowed: true,
      );
      final enabled = await store.agent.readAgentUsePolicy();
      expect(enabled.configured, isTrue);
      expect(enabled.personalContentAllowed, isTrue);
      expect(enabled.dailyOperationsAllowed, isTrue);
      expect(enabled.granted, agentDailyPermissionCategories);
      expect(enabled.granted, hasLength(17));
      expect(
        enabled.granted.intersection({
          AgentPermissionCategory.deletePersonal,
          AgentPermissionCategory.deleteTask,
          AgentPermissionCategory.deleteBlock,
          AgentPermissionCategory.refreshJw,
          AgentPermissionCategory.refreshYoung,
        }),
        isEmpty,
      );
      expect(
        (await store.agent.readActionPermissions())
            .singleWhere(
              (grant) => grant.category == AgentPermissionCategory.createTask,
            )
            .revision,
        singleGrant.revision,
      );

      final forged = AgentUsePolicySnapshot(
        configured: enabled.configured,
        personalContentAllowed: enabled.personalContentAllowed,
        revision: enabled.revision,
        granted: enabled.granted,
      );
      await _agentFailure(
        store.agent.saveAgentUsePolicy(
          forged,
          personalContentAllowed: false,
          dailyOperationsAllowed: false,
        ),
        AgentFailureCode.staleContext,
      );
      expect(
        (await store.agent.readAgentUsePolicy()).revision,
        enabled.revision,
      );
    },
  );

  test(
    'package revoke and regrant do not revive old proof; advice runs cannot authorize writes',
    () async {
      final store = await _open();
      var policy = await store.agent.readAgentUsePolicy();
      await store.agent.saveAgentUsePolicy(
        policy,
        personalContentAllowed: true,
        dailyOperationsAllowed: true,
      );
      policy = await store.agent.readAgentUsePolicy();

      final ticket = await _ticket(store);
      final plan = await _taskPlan(store, ticket, '撤销前的合成授权任务');
      final approval = await (store.localCalendar as AgentLocalPermissionPort)
          .authorizeLocalPlan(plan, mode: AgentAuthorizationMode.remembered);
      expect(approval, isNotNull);

      await store.agent.saveAgentUsePolicy(
        policy,
        personalContentAllowed: true,
        dailyOperationsAllowed: false,
      );
      policy = await store.agent.readAgentUsePolicy();
      expect(policy.dailyOperationsAllowed, isFalse);
      await store.agent.saveAgentUsePolicy(
        policy,
        personalContentAllowed: true,
        dailyOperationsAllowed: true,
      );
      await _agentFailure(
        (store.localCalendar as AgentLocalPlanPort).commitLocalPlan(approval!),
        AgentFailureCode.consentRequired,
      );
      expect(await _tasks(store), isEmpty);
      expect(await _count(store, 'agenda_plan_receipts'), 0);
      await store.agent.finishRun(ticket, AgentMessageStatus.complete);

      final adviceTicket = await _ticket(store, question: '仅建议模式的合成任务');
      store.agent.constrainAgentRunToAdvice(adviceTicket);
      final advicePlan = await _taskPlan(store, adviceTicket, '仅建议不得提交的任务');
      await _agentFailure(
        (store.localCalendar as AgentLocalPermissionPort).authorizeLocalPlan(
          advicePlan,
          mode: AgentAuthorizationMode.remembered,
        ),
        AgentFailureCode.consentRequired,
      );
      expect(await _tasks(store), isEmpty);
      expect(await _count(store, 'agenda_plan_receipts'), 0);
    },
  );

  test(
    'policy options, daily grants, and an existing single grant survive restart',
    () async {
      final file = await _temporaryDatabase();
      var store = await _openAt(file);
      await _establishTaskGrant(store);
      final singleGrant = (await store.agent.readActionPermissions()).single;
      final before = await store.agent.readAgentUsePolicy();
      const options = AgentContextOptions(
        inputTokens: 24000,
        outputTokens: 1024,
        modelCalls: 8,
        toolCalls: 32,
        activeSeconds: 240,
      );
      await store.agent.saveAgentUsePolicy(
        before,
        personalContentAllowed: true,
        dailyOperationsAllowed: true,
        contextOptions: options,
      );
      final enabled = await store.agent.readAgentUsePolicy();
      expect(enabled.granted, agentDailyPermissionCategories);
      expect(enabled.granted, hasLength(17));
      expect(
        (await store.agent.readActionPermissions())
            .singleWhere(
              (grant) => grant.category == AgentPermissionCategory.createTask,
            )
            .revision,
        singleGrant.revision,
      );
      await store.close();

      store = await _openAt(file, configure: false);
      final resumed = await store.agent.readAgentUsePolicy();
      expect(resumed.configured, isTrue);
      expect(resumed.personalContentAllowed, isTrue);
      expect(resumed.granted, agentDailyPermissionCategories);
      expect(resumed.granted, hasLength(17));
      expect(resumed.contextOptions.canonical, options.canonical);
      expect(
        (await store.agent.readActionPermissions())
            .singleWhere(
              (grant) => grant.category == AgentPermissionCategory.createTask,
            )
            .revision,
        singleGrant.revision,
      );
    },
  );

  test(
    'receipt recovery survives deleted transcripts and long history',
    () async {
      final store = await _open();
      final failedTicket = await _ticket(store, question: '已提交后终答失败的合成任务');
      const arguments = <String, Object?>{
        'changes': [
          {
            'type': 'create_task',
            'local_key': 'context-task',
            'title': '合成可恢复任务',
          },
        ],
      };
      final invocationFingerprint = agentLocalInvocationFingerprint(arguments);
      final plan = await _taskPlan(store, failedTicket, '合成可恢复任务');
      await (store.localCalendar as AgentLocalInvocationPort)
          .bindLocalInvocation(plan, invocationFingerprint);
      final approval = await (store.localCalendar as AgentLocalPermissionPort)
          .authorizeLocalPlan(plan, mode: AgentAuthorizationMode.confirmed);
      expect(approval, isNotNull);
      await (store.localCalendar as AgentLocalPlanPort).commitLocalPlan(
        approval!,
      );
      await store.agent.saveAssistant(failedTicket, '合成提交回执已写入');
      final policy = await store.agent.readAgentUsePolicy();
      await store.agent.saveAgentTurn(
        failedTicket,
        items: [
          AgentContextItem(
            role: 'assistant',
            calls: [
              AgentContextCall(
                id: 'recoverable-context-call',
                name: 'propose_local_changes',
                argumentsJson: jsonEncode(arguments),
              ),
            ],
          ),
          AgentContextItem(
            role: 'tool',
            toolCallId: 'recoverable-context-call',
            text: jsonEncode({
              'status': 'committed',
              'data': {'count': 1, 'receipt_status': 'committed'},
            }),
          ),
        ],
        includesPersonalContent: false,
        policyRevision: policy.revision,
      );
      await store.agent.finishRun(failedTicket, AgentMessageStatus.failed);
      expect(await _count(store, 'agenda_plan_receipts'), 1);

      final AgentReceiptRecoveryPort recovery =
          store.agent as AgentReceiptRecoveryPort;
      final currentTicket = await _ticket(store, question: '恢复同一对话中的合成回执');
      expect(
        await recovery.hasRecoverableAgentLocalReceipt(
          currentTicket,
          failedTicket.assistantMessageId,
        ),
        isTrue,
      );
      final initialRecovery = await recovery.findUnfinishedAgentLocalReceipt(
        currentTicket,
        invocationFingerprint,
      );
      expect(initialRecovery.state, AgentLocalReceiptRecoveryState.committed);
      expect(initialRecovery.committedCount, 1);
      final forgedTicket = AgentRunTicket(
        authority: currentTicket.authority,
        runId: currentTicket.runId,
        conversationId: currentTicket.conversationId,
        conversationGeneration: currentTicket.conversationGeneration,
        runGeneration: currentTicket.runGeneration,
        assistantMessageId: currentTicket.assistantMessageId,
      );
      await _agentFailure(
        recovery.hasRecoverableAgentLocalReceipt(
          forgedTicket,
          failedTicket.assistantMessageId,
        ),
        AgentFailureCode.staleContext,
      );
      await _agentFailure(
        recovery.findUnfinishedAgentLocalReceipt(
          forgedTicket,
          invocationFingerprint,
        ),
        AgentFailureCode.staleContext,
      );
      expect(
        await _count(store, 'agent_context_turns'),
        greaterThanOrEqualTo(1),
      );
      await store.customStatement(
        'DELETE FROM agent_context_turns WHERE assistant_message_id=?',
        [failedTicket.assistantMessageId],
      );
      expect(await _count(store, 'agent_context_turns'), 0);
      await store.agent.cancelRun(currentTicket);

      for (var index = 0; index < 251; index++) {
        final emptyFailedTurn = await _ticket(
          store,
          question: '合成未完成空回合 $index',
        );
        await store.agent.finishRun(emptyFailedTurn, AgentMessageStatus.failed);
      }
      final afterLongHistoryTicket = await _ticket(
        store,
        question: '长历史后继续恢复合成回执',
      );
      expect(await _count(store, 'agent_messages'), greaterThan(500));
      final afterLongHistory = await recovery.findUnfinishedAgentLocalReceipt(
        afterLongHistoryTicket,
        invocationFingerprint,
      );
      expect(afterLongHistory.state, AgentLocalReceiptRecoveryState.committed);
      expect(afterLongHistory.committedCount, 1);
      await store.agent.cancelRun(afterLongHistoryTicket);

      final otherConversation = await store.agent.createConversation();
      final authority = (await store.agent.inspectAgent()).authority;
      final otherTicket = await store.agent.beginRun(
        authority,
        otherConversation,
        '另一合成对话不得复用旧回执',
      );
      expect(
        await recovery.hasRecoverableAgentLocalReceipt(
          otherTicket,
          failedTicket.assistantMessageId,
        ),
        isFalse,
      );
      final otherConversationRecovery = await recovery
          .findUnfinishedAgentLocalReceipt(otherTicket, invocationFingerprint);
      expect(
        otherConversationRecovery.state,
        AgentLocalReceiptRecoveryState.absent,
      );
      await store.agent.cancelRun(otherTicket);

      final legacyConversation = await store.agent.createConversation();
      final legacyTicket = await store.agent.beginRun(
        authority,
        legacyConversation,
        '没有调用指纹的旧式合成回执',
      );
      final legacyPlan = await _taskPlan(store, legacyTicket, '未分类旧式合成任务');
      final legacyApproval =
          await (store.localCalendar as AgentLocalPermissionPort)
              .authorizeLocalPlan(
                legacyPlan,
                mode: AgentAuthorizationMode.confirmed,
              );
      expect(legacyApproval, isNotNull);
      await (store.localCalendar as AgentLocalPlanPort).commitLocalPlan(
        legacyApproval!,
      );
      await store.agent.saveAssistant(legacyTicket, '旧式合成回执已提交');
      await store.agent.finishRun(legacyTicket, AgentMessageStatus.failed);
      final legacyLookupTicket = await store.agent.beginRun(
        authority,
        legacyConversation,
        '确认旧回执不可猜测重试',
      );
      final unclassified = await recovery.findUnfinishedAgentLocalReceipt(
        legacyLookupTicket,
        invocationFingerprint,
      );
      expect(unclassified.state, AgentLocalReceiptRecoveryState.unknown);
      expect(unclassified.committedCount, 0);
      await store.agent.cancelRun(legacyLookupTicket);

      await _clearAgenda(store);
      expect(await _tasks(store), isEmpty);
      expect(await _count(store, 'agenda_plan_receipts'), 0);
      final afterClearTicket = await _ticket(store, question: '清除业务数据后不复活合成回执');
      expect(
        await recovery.hasRecoverableAgentLocalReceipt(
          afterClearTicket,
          failedTicket.assistantMessageId,
        ),
        isFalse,
      );
      final afterClear = await recovery.findUnfinishedAgentLocalReceipt(
        afterClearTicket,
        invocationFingerprint,
      );
      expect(afterClear.state, AgentLocalReceiptRecoveryState.absent);
      await store.agent.finishRun(
        afterClearTicket,
        AgentMessageStatus.complete,
      );
    },
  );

  test(
    'policy SQL checkpoint failure rolls back the policy and package grants',
    () async {
      var failCheckpoint = false;
      final store = await _open(
        onAgentCheckpoint: () async {
          if (failCheckpoint) {
            throw StateError('synthetic policy checkpoint failure');
          }
        },
      );
      final before = await store.agent.readAgentUsePolicy();
      failCheckpoint = true;
      await expectLater(
        store.agent.saveAgentUsePolicy(
          before,
          personalContentAllowed: true,
          dailyOperationsAllowed: true,
        ),
        throwsA(anything),
      );
      failCheckpoint = false;

      final after = await store.agent.readAgentUsePolicy();
      expect(after.configured, isFalse);
      expect(after.revision, before.revision);
      expect(after.personalContentAllowed, isFalse);
      expect(after.granted, isEmpty);
      expect(await _count(store, 'agent_use_policy'), 0);
      expect(await store.agent.readActionPermissions(), isEmpty);

      final ticket = await _ticket(store, question: '合成转录回滚');
      await store.agent.saveAssistant(ticket, '回滚时保留的合成答复');
      failCheckpoint = true;
      await expectLater(
        store.agent.saveAgentTurn(
          ticket,
          items: [AgentContextItem(role: 'assistant', text: '回滚时保留的合成答复')],
          includesPersonalContent: false,
          policyRevision: before.revision,
        ),
        throwsA(anything),
      );
      failCheckpoint = false;
      expect(await _count(store, 'agent_context_turns'), 0);
      final message = await store
          .customSelect(
            'SELECT context_private FROM agent_messages WHERE message_id=?',
            variables: [Variable.withInt(ticket.assistantMessageId)],
          )
          .getSingle();
      expect(message.read<int>('context_private'), 0);
      await store.agent.finishRun(ticket, AgentMessageStatus.complete);
    },
  );

  test(
    'private transcript and summary survive restart, then revoke withholds the whole assistant turn',
    () async {
      final file = await _temporaryDatabase();
      var store = await _openAt(file);
      var policy = await store.agent.readAgentUsePolicy();
      await store.agent.saveAgentUsePolicy(
        policy,
        personalContentAllowed: true,
        dailyOperationsAllowed: false,
        contextOptions: const AgentContextOptions(
          inputTokens: 20000,
          outputTokens: 1500,
          modelCalls: 10,
          toolCalls: 40,
          activeSeconds: 280,
        ),
      );
      policy = await store.agent.readAgentUsePolicy();
      final ticket = await _ticket(store, question: '查看这个合成任务的备注');
      const privateAnswer = '合成私人备注内容：周五前完成';
      await store.agent.saveAssistant(ticket, privateAnswer);
      await store.agent.saveAgentTurn(
        ticket,
        items: [
          AgentContextItem(
            role: 'assistant',
            calls: [
              AgentContextCall(
                id: 'private-call-1',
                name: 'read_task',
                argumentsJson: '{"task":"r_00000000000000000000000000000000"}',
              ),
            ],
          ),
          AgentContextItem(
            role: 'tool',
            toolCallId: 'private-call-1',
            text: '合成允许读取的任务备注',
          ),
          AgentContextItem(role: 'assistant', text: privateAnswer),
        ],
        includesPersonalContent: true,
        policyRevision: policy.revision,
        applicationSelection: '合成应用选中的文本片段',
      );
      await store.agent.finishRun(ticket, AgentMessageStatus.complete);
      var context = await store.agent.readConversationContext();
      const privateSummary = '合成历史摘要：任务备注要求周五前完成';
      await store.agent.saveConversationSummary(context, privateSummary);
      context = await store.agent.readConversationContext();
      expect(context.summary, privateSummary);
      expect(context.turns, hasLength(1));
      expect(context.turns.single.items.map((item) => item.role), [
        'assistant',
        'tool',
        'assistant',
      ]);
      expect(context.includesPersonalContent, isTrue);
      final assistantId = ticket.assistantMessageId;
      await store.close();

      store = await _openAt(file, configure: false);
      context = await store.agent.readConversationContext();
      expect(context.summary, privateSummary);
      expect(
        context.messages.map((message) => message.text),
        contains('查看这个合成任务的备注'),
      );
      expect(context.turns.single.assistantMessageId, assistantId);
      expect(context.turns.single.items.last.text, privateAnswer);
      expect(context.turns.single.applicationSelection, '合成应用选中的文本片段');
      final resumedPolicy = await store.agent.readAgentUsePolicy();
      expect(resumedPolicy.personalContentAllowed, isTrue);
      expect(
        resumedPolicy.contextOptions.canonical,
        const AgentContextOptions(
          inputTokens: 20000,
          outputTokens: 1500,
          modelCalls: 10,
          toolCalls: 40,
          activeSeconds: 280,
        ).canonical,
      );

      await store.agent.saveAgentUsePolicy(
        resumedPolicy,
        personalContentAllowed: false,
        dailyOperationsAllowed: false,
      );
      context = await store.agent.readConversationContext();
      expect(context.summary, isEmpty);
      expect(context.withheldAssistantMessageIds, contains(assistantId));
      expect(context.turns, isEmpty);
      final outgoing = buildAgentConversationGroups(context)
          .expand((group) => group)
          .map((message) => message.content ?? '')
          .join('\n');
      expect(outgoing, isNot(contains(privateAnswer)));
      expect(outgoing, isNot(contains(privateSummary)));
      expect(outgoing, contains('查看这个合成任务的备注'));
      expect(context.messages.last.text, privateAnswer);
    },
  );

  test(
    'account-scope change withholds old private context and rejects its issued policy',
    () async {
      final store = await _open();
      await _setSyntheticAccountScope(store, 'SYNTHACCOUNT01');
      final basic = await store.agent.readAgentUsePolicy();
      await store.agent.saveAgentUsePolicy(
        basic,
        personalContentAllowed: true,
        dailyOperationsAllowed: false,
      );
      final privatePolicy = await store.agent.readAgentUsePolicy();
      final privateTicket = await _ticket(store, question: '查看合成账号一的私人任务备注');
      await store.agent.bindAgentRunPolicy(privateTicket, privatePolicy);
      const privateAnswer = '合成账号一私人派生结果';
      await store.agent.saveAssistant(privateTicket, privateAnswer);
      await store.agent.saveAgentTurn(
        privateTicket,
        items: [
          AgentContextItem(
            role: 'assistant',
            calls: [
              AgentContextCall(
                id: 'scope-private-call',
                name: 'read_task',
                argumentsJson: '{}',
              ),
            ],
          ),
          AgentContextItem(
            role: 'tool',
            toolCallId: 'scope-private-call',
            text: '合成账号一的私人工具结果',
          ),
          AgentContextItem(role: 'assistant', text: privateAnswer),
        ],
        includesPersonalContent: true,
        policyRevision: privatePolicy.revision,
      );
      await store.agent.finishRun(privateTicket, AgentMessageStatus.complete);
      var context = await store.agent.readConversationContext();
      const privateSummary = '合成账号一历史私人摘要';
      await store.agent.saveConversationSummary(context, privateSummary);

      final unboundRun = await _ticket(store, question: '合成账号二的新范围运行');
      await _setSyntheticAccountScope(store, 'SYNTHACCOUNT02');
      context = await store.agent.readConversationContext();
      expect(context.summary, isEmpty);
      expect(context.coveredMessageId, 0);
      expect(context.includesPersonalContent, isFalse);
      expect(
        context.withheldAssistantMessageIds,
        contains(privateTicket.assistantMessageId),
      );
      expect(context.turns, isEmpty);
      final projected = buildAgentConversationGroups(context)
          .expand((group) => group)
          .map((message) => message.content ?? '')
          .join('\n');
      expect(projected, isNot(contains(privateAnswer)));
      expect(projected, isNot(contains('合成账号一的私人工具结果')));
      expect(projected, isNot(contains(privateSummary)));
      expect(projected, contains('查看合成账号一的私人任务备注'));

      await _agentFailure(
        store.agent.bindAgentRunPolicy(unboundRun, privatePolicy),
        AgentFailureCode.staleContext,
      );
      await store.agent.cancelRun(unboundRun);
    },
  );

  test(
    'an in-flight run stays bound to its original scope when revisions collide',
    () async {
      final store = await _open();
      await _setSyntheticAccountScope(store, 'SYNTHACCOUNT11');
      final basic = await store.agent.readAgentUsePolicy();
      await store.agent.saveAgentUsePolicy(
        basic,
        personalContentAllowed: true,
        dailyOperationsAllowed: false,
      );
      final oldScopePolicy = await store.agent.readAgentUsePolicy();
      final ticket = await _ticket(store, question: '绑定旧scope的合成在途运行');
      await store.agent.bindAgentRunPolicy(ticket, oldScopePolicy);

      await _setSyntheticAccountScope(store, 'SYNTHACCOUNT12');
      var newScopePolicy = await store.agent.readAgentUsePolicy();
      await store.agent.saveAgentUsePolicy(
        newScopePolicy,
        personalContentAllowed: true,
        dailyOperationsAllowed: false,
      );
      newScopePolicy = await store.agent.readAgentUsePolicy();
      expect(newScopePolicy.revision, oldScopePolicy.revision);
      expect(newScopePolicy.personalContentAllowed, isTrue);
      await _agentFailure(
        store.agent.ensureAgentUsePolicy(ticket, oldScopePolicy.revision),
        AgentFailureCode.staleContext,
      );
      await store.agent.cancelRun(ticket);
    },
  );

  test(
    'failed personal revoke withholds immediately while basic projection and compaction remain available',
    () async {
      var failCheckpoint = false;
      final store = await _open(
        onAgentCheckpoint: () async {
          if (failCheckpoint) {
            throw StateError('synthetic personal revoke checkpoint failure');
          }
        },
      );
      final basic = await store.agent.readAgentUsePolicy();
      await store.agent.saveAgentUsePolicy(
        basic,
        personalContentAllowed: true,
        dailyOperationsAllowed: false,
      );
      final optedIn = await store.agent.readAgentUsePolicy();
      final privateTicket = await _ticket(store, question: '读取合成私人备注后撤销授权');
      await store.agent.bindAgentRunPolicy(privateTicket, optedIn);
      const privateAnswer = '合成撤销前的私人派生内容';
      await store.agent.saveAssistant(privateTicket, privateAnswer);
      await store.agent.saveAgentTurn(
        privateTicket,
        items: [AgentContextItem(role: 'assistant', text: privateAnswer)],
        includesPersonalContent: true,
        policyRevision: optedIn.revision,
      );
      await store.agent.finishRun(privateTicket, AgentMessageStatus.complete);
      var context = await store.agent.readConversationContext();
      const privateSummary = '合成撤销前的摘要';
      await store.agent.saveConversationSummary(context, privateSummary);

      failCheckpoint = true;
      await expectLater(
        store.agent.saveAgentUsePolicy(
          optedIn,
          personalContentAllowed: false,
          dailyOperationsAllowed: false,
        ),
        throwsA(anything),
      );
      failCheckpoint = false;

      final revokedInMemory = await store.agent.readAgentUsePolicy();
      expect(revokedInMemory.personalContentAllowed, isFalse);
      expect(revokedInMemory.revision, optedIn.revision);
      context = await store.agent.readConversationContext();
      expect(context.summary, isEmpty);
      expect(context.coveredMessageId, 0);
      expect(context.includesPersonalContent, isFalse);
      expect(
        context.withheldAssistantMessageIds,
        contains(privateTicket.assistantMessageId),
      );

      final basicTicket = await _ticket(store, question: '合成普通上下文仍可读取和压缩');
      await store.agent.bindAgentRunPolicy(basicTicket, revokedInMemory);
      const basicAnswer = '合成普通答复';
      await store.agent.saveAssistant(basicTicket, basicAnswer);
      await store.agent.saveAgentTurn(
        basicTicket,
        items: [AgentContextItem(role: 'assistant', text: basicAnswer)],
        includesPersonalContent: false,
        policyRevision: revokedInMemory.revision,
      );
      await store.agent.finishRun(basicTicket, AgentMessageStatus.complete);
      context = await store.agent.readConversationContext();
      expect(context.turns, hasLength(1));
      expect(context.turns.single.items.single.text, basicAnswer);
      expect(context.includesPersonalContent, isFalse);
      final projected = buildAgentConversationGroups(context)
          .expand((group) => group)
          .map((message) => message.content ?? '')
          .join('\n');
      expect(projected, isNot(contains(privateAnswer)));
      expect(projected, isNot(contains(privateSummary)));
      expect(projected, contains(basicAnswer));

      await store.agent.saveConversationSummary(context, '合成基本权限摘要');
      context = await store.agent.readConversationContext();
      expect(context.summary, '合成基本权限摘要');
      expect(context.includesPersonalContent, isFalse);
    },
  );

  test(
    'advice-only source proposals remain preparable but C3 rejects approvals',
    () async {
      final store = await _open();
      final ticket = await _ticket(store, question: '仅建议来源操作的合成请求');
      store.agent.constrainAgentRunToAdvice(ticket);

      final sourceRecord = await store.agent.prepareSourceAction(
        ticket,
        const AgentSourceRequest(AgentRefreshSource.jw),
        '合成教务同步提案',
        const ['合成fixture来源，不访问学校'],
      );
      expect(sourceRecord.status, AgentActionStatus.proposed);
      await _agentFailure(
        store.agent.approveSourceAction(ticket, sourceRecord),
        AgentFailureCode.consentRequired,
      );
      await _agentFailure(
        store.agent.authorizeAction(
          ticket,
          sourceRecord,
          mode: AgentAuthorizationMode.confirmed,
        ),
        AgentFailureCode.consentRequired,
      );

      final legacyRecord = await store.agent.prepareActionRecord(
        ticket,
        AgentActionKind.sourceRefresh,
        '合成旧接口来源同步提案',
        const ['合成fixture来源，不访问学校'],
      );
      expect(legacyRecord.status, AgentActionStatus.proposed);
      await _agentFailure(
        store.agent.approveSourceAction(ticket, legacyRecord),
        AgentFailureCode.consentRequired,
      );
      await _agentFailure(
        store.agent.authorizeAction(
          ticket,
          legacyRecord,
          mode: AgentAuthorizationMode.confirmed,
        ),
        AgentFailureCode.consentRequired,
      );

      expect(await _count(store, 'jw_imports'), 0);
      expect((await store.readView()).importCount, 0);
      await store.agent.cancelRun(ticket);
    },
  );

  test(
    'transcript rejects orphan results and incomplete calls, then stores complete groups',
    () async {
      final store = await _open();
      final policy = await store.agent.readAgentUsePolicy();
      final ticket = await _ticket(store, question: '合成协议校验');

      await _agentFailure(
        store.agent.saveAgentTurn(
          ticket,
          items: [AgentContextItem(role: 'user', text: '伪造的用户项')],
          includesPersonalContent: false,
          policyRevision: policy.revision,
        ),
        AgentFailureCode.invalidInput,
      );
      await _agentFailure(
        store.agent.saveAgentTurn(
          ticket,
          items: [
            AgentContextItem(
              role: 'tool',
              toolCallId: 'orphan-result',
              text: '孤立结果',
            ),
          ],
          includesPersonalContent: false,
          policyRevision: policy.revision,
        ),
        AgentFailureCode.invalidInput,
      );
      await _agentFailure(
        store.agent.saveAgentTurn(
          ticket,
          items: [
            AgentContextItem(
              role: 'assistant',
              calls: [
                AgentContextCall(
                  id: 'missing-result',
                  name: 'read_task',
                  argumentsJson: '{}',
                ),
              ],
            ),
          ],
          includesPersonalContent: false,
          policyRevision: policy.revision,
        ),
        AgentFailureCode.invalidInput,
      );
      expect(await _count(store, 'agent_context_turns'), 0);

      await store.agent.saveAssistant(ticket, '合成协议校验完成');
      await store.agent.saveAgentTurn(
        ticket,
        items: [
          AgentContextItem(
            role: 'assistant',
            calls: [
              AgentContextCall(
                id: 'paired-call',
                name: 'read_task',
                argumentsJson: '{}',
              ),
            ],
          ),
          AgentContextItem(
            role: 'tool',
            toolCallId: 'paired-call',
            text: '合成任务结果',
          ),
          AgentContextItem(role: 'assistant', text: '合成协议校验完成'),
        ],
        includesPersonalContent: false,
        policyRevision: policy.revision,
      );
      await store.agent.finishRun(ticket, AgentMessageStatus.complete);
      final context = await store.agent.readConversationContext();
      expect(context.turns, hasLength(1));
      expect(
        context.messages.map((message) => message.text),
        contains('合成协议校验'),
      );
      expect(context.turns.single.items.map((item) => item.role), [
        'assistant',
        'tool',
        'assistant',
      ]);
      final projected = buildAgentConversationGroups(context).single;
      expect(projected.map((message) => message.role), [
        'user',
        'assistant',
        'tool',
        'assistant',
      ]);
      expect(projected[1].toolCalls.single.name, 'read_task');
      expect(projected[2].toolCallId, projected[1].toolCalls.single.id);
    },
  );

  test(
    'event aliases resolve current versions, stale on scope changes, and never revive after clear or reset',
    () async {
      final store = await _open();
      final event = await _seedEvent(store, '合成别名日程');
      const alias = 'r_11111111111111111111111111111111';
      var ticket = await _ticket(store, question: '记录合成日程别名');
      await store.agent.rememberAgentEvent(
        ticket,
        alias,
        event.reference,
        event.startsAtUtc,
        event.endsAtUtc,
      );
      await store.agent.finishRun(ticket, AgentMessageStatus.complete);

      await _seedEvent(store, '无关业务修订');
      ticket = await _ticket(store, question: '跨轮定位合成日程');
      var resolved = await store.agent.resolveAgentEvent(ticket, alias);
      expect(resolved.$1.identity, event.reference.identity);
      expect(resolved.$1.version, event.reference.version);
      await store.agent.finishRun(ticket, AgentMessageStatus.complete);

      final sameDayUpdate = await _updateEvent(
        store,
        resolved.$1,
        PersonalEventDraft(
          title: event.title,
          start: event.startsAtUtc,
          end: event.endsAtUtc,
          location: '合成新地点',
        ),
      );
      ticket = await _ticket(store, question: '读取别名当前版本');
      resolved = await store.agent.resolveAgentEvent(ticket, alias);
      expect(resolved.$1.version, sameDayUpdate.reference.version);
      expect(resolved.$1.version, isNot(event.reference.version));
      await store.agent.finishRun(ticket, AgentMessageStatus.complete);

      final movedStart = DateTime.utc(2026, 10, 15, 10);
      final movedEnd = DateTime.utc(2026, 10, 15, 11);
      final moved = await _updateEvent(
        store,
        sameDayUpdate.reference,
        PersonalEventDraft(
          title: event.title,
          start: movedStart,
          end: movedEnd,
          location: '合成新地点',
        ),
      );
      final receiptCount = await _count(store, 'agenda_plan_receipts');
      ticket = await _ticket(store, question: '原日期范围的合成安排');
      await _calendarFailure(
        store.agent.resolveAgentEvent(ticket, alias),
        CalendarFailureCode.staleReference,
      );
      final movedWindow = await _calendarWindow(store);
      expect(
        movedWindow.items
            .singleWhere((item) => item.reference == moved.reference)
            .startsAtUtc,
        movedStart,
      );
      expect(await _count(store, 'agenda_plan_receipts'), receiptCount);
      await store.agent.finishRun(ticket, AgentMessageStatus.complete);

      await _clearAgenda(store);
      await _seedEvent(store, event.title);
      ticket = await _ticket(store, question: '同名但不同对象');
      await _calendarFailure(
        store.agent.resolveAgentEvent(ticket, alias),
        CalendarFailureCode.staleReference,
      );
      await store.agent.finishRun(ticket, AgentMessageStatus.complete);

      final conversationToClear = ticket.conversationId;
      final agentSettings = await store.agent.inspectAgent();
      final clear = await store.agent.beginClearHistory(
        agentSettings.authority,
        conversationId: conversationToClear,
      );
      await store.agent.completeClearHistory(clear);

      const resetAlias = 'r_22222222222222222222222222222222';
      final resetEvent = await _calendarWindow(store).then(
        (window) =>
            window.items.singleWhere((item) => item.title == event.title),
      );
      ticket = await _ticket(store, question: '重置前记录另一别名');
      await store.agent.rememberAgentEvent(
        ticket,
        resetAlias,
        resetEvent.reference,
        resetEvent.startsAtUtc,
        resetEvent.endsAtUtc,
      );
      await store.agent.finishRun(ticket, AgentMessageStatus.complete);

      final beforeReset = await store.applicationSettings.inspectSettings();
      final resetRequest = await store.applicationSettings.prepareMaintenance(
        beforeReset.context,
        MaintenanceKind.reset,
        confirmed: true,
      );
      final resetIntent = await store.applicationSettings.beginMaintenance(
        resetRequest,
      );
      await store.applicationSettings.completeMaintenance(resetIntent);
      await _configure(store);
      await _seedEvent(store, event.title);
      ticket = await _ticket(store, question: '确认旧别名没有复活');
      await _calendarFailure(
        store.agent.resolveAgentEvent(ticket, resetAlias),
        CalendarFailureCode.staleReference,
      );
      await store.agent.finishRun(ticket, AgentMessageStatus.complete);
    },
  );

  test(
    'schema 14 upgrade preserves old chat, agenda, and grant without inventing calls',
    () async {
      final file = await _temporaryDatabase();
      var store = await _openAt(file);
      final event = await _seedEvent(store, 'schema14 保留的合成日程');
      await _establishTaskGrant(store);
      final conversation = await store.agent.ensurePrimaryConversation();
      final ticket = await _ticket(store, question: 'schema14 旧任务正文');
      await store.agent.saveAssistant(ticket, 'schema14 旧回答含任务正文');
      await store.agent.finishRun(ticket, AgentMessageStatus.complete);
      await store.customStatement(
        "UPDATE agent_messages SET steps_json='[{\"tool\":\"read_task\",\"status\":\"success\"}]' WHERE message_id=?",
        [ticket.assistantMessageId],
      );
      final legacyContext = await store.agent.readConversationContext();
      await store.agent.saveConversationSummary(
        legacyContext,
        'schema14 保留的合成摘要',
      );
      await store.close();

      final raw = sqlite3.sqlite3.open(file.path);
      try {
        raw.execute('BEGIN');
        _removeSchema15ObjectsForLegacyFixture(raw);
        raw.execute('PRAGMA user_version=14');
        raw.execute('COMMIT');
      } finally {
        raw.close();
      }

      store = await _openAt(file, configure: false);
      expect(await _count(store, 'agent_context_turns'), 0);
      expect(await _count(store, 'agent_target_aliases'), 0);
      final legacyPolicy = await store.agent.readAgentUsePolicy();
      expect(legacyPolicy.configured, isFalse);
      expect(legacyPolicy.personalContentAllowed, isFalse);
      expect(legacyPolicy.dailyOperationsAllowed, isFalse);
      expect(await _count(store, 'personal_events'), 1);
      final retainedEvent = await _calendarWindow(store);
      expect(retainedEvent.items.single.title, event.title);
      final grants = await store.agent.readActionPermissions();
      expect(grants.map((grant) => grant.category), [
        AgentPermissionCategory.createTask,
      ]);
      final context = await store.agent.readConversationContext();
      expect(context.conversationId, conversation);
      expect(context.summary, 'schema14 保留的合成摘要');
      expect(
        context.messages.map((message) => message.text),
        containsAll(['schema14 旧任务正文', 'schema14 旧回答含任务正文']),
      );
      expect(context.turns, isEmpty);
      expect(
        context.withheldAssistantMessageIds,
        contains(ticket.assistantMessageId),
      );
      final projected = buildAgentConversationGroups(context)
          .expand((group) => group)
          .map((message) => message.content ?? '')
          .join('\n');
      expect(projected, contains('schema14 旧任务正文'));
      expect(projected, isNot(contains('schema14 旧回答含任务正文')));
      expect(
        buildAgentConversationGroups(
          context,
        ).expand((group) => group).expand((message) => message.toolCalls),
        isEmpty,
      );
    },
  );
}

Future<JwStore> _open({Future<void> Function()? onAgentCheckpoint}) =>
    _openWithExecutor(
      NativeDatabase.memory(),
      onAgentCheckpoint: onAgentCheckpoint,
    );

Future<JwStore> _openAt(File file, {bool configure = true}) =>
    _openWithExecutor(NativeDatabase(file), configure: configure);

Future<JwStore> _openWithExecutor(
  QueryExecutor executor, {
  bool configure = true,
  Future<void> Function()? onAgentCheckpoint,
}) async {
  final store = JwStore(
    executor,
    ownership: _TestOwnership(),
    clock: _clock,
    modelCredentialProtector: _SyntheticProtector(),
    onAgentCheckpoint: onAgentCheckpoint,
  );
  addTearDown(store.close);
  await store.initialize();
  await store.agent.initializeAgent();
  if (configure) await _configure(store);
  return store;
}

Future<void> _configure(JwStore store) async {
  final settings = await store.agent.inspectAgent();
  await store.agent.saveModelConfiguration(
    settings.authority,
    modelId: 'synthetic-context-model',
    modelIds: const ['synthetic-context-model'],
    report: const AgentCapabilityReport(text: true, streaming: true),
    consent: true,
    key: _syntheticKey,
  );
}

Future<AgentRunTicket> _ticket(
  JwStore store, {
  String question = '合成上下文测试',
}) async {
  final settings = await store.agent.inspectAgent();
  final conversation = await store.agent.ensurePrimaryConversation();
  return store.agent.beginRun(settings.authority, conversation, question);
}

Future<void> _setSyntheticAccountScope(
  JwStore store,
  String accountCode,
) async {
  await store.customStatement(
    'INSERT INTO jw_account(account_id,expected_account_code) VALUES (1,?) '
    'ON CONFLICT(account_id) DO UPDATE SET expected_account_code=excluded.expected_account_code',
    [accountCode],
  );
}

Future<AgentLocalPlan> _taskPlan(
  JwStore store,
  AgentRunTicket ticket,
  String title,
) async {
  final plans = store.localCalendar as AgentLocalPlanPort;
  final (context, revision) = await plans.readPlanContext();
  return plans.prepareLocalPlan(ticket, context, revision, [
    AgentCreateTask('context-task', TaskDraft(title: title)),
  ]);
}

Future<void> _establishTaskGrant(JwStore store) async {
  final ticket = await _ticket(store);
  final plan = await _taskPlan(store, ticket, '已存在的合成单类别许可');
  final approval = await (store.localCalendar as AgentLocalPermissionPort)
      .authorizeLocalPlan(
        plan,
        mode: AgentAuthorizationMode.confirmed,
        remember: true,
      );
  if (approval == null) throw StateError('Expected the synthetic task grant');
  await (store.localCalendar as AgentLocalPlanPort).commitLocalPlan(approval);
  await store.agent.finishRun(ticket, AgentMessageStatus.complete);
}

Future<CalendarOccurrence> _seedEvent(
  JwStore store,
  String title, {
  DateTime? start,
}) async {
  final window = await _calendarWindow(store);
  final eventStart = start ?? DateTime.utc(2026, 10, 14, 10);
  final command = await store.localCalendar.prepare(
    window.context,
    CreatePersonalEvent(
      PersonalEventDraft(
        title: title,
        start: eventStart,
        end: eventStart.add(const Duration(hours: 1)),
      ),
    ),
  );
  await store.localCalendar.commit(command);
  return _calendarWindow(
    store,
  ).then((next) => next.items.singleWhere((item) => item.title == title));
}

Future<CalendarOccurrence> _updateEvent(
  JwStore store,
  CalendarReference reference,
  PersonalEventDraft draft,
) async {
  final window = await _calendarWindow(store);
  final command = await store.localCalendar.prepare(
    window.context,
    UpdatePersonalSeries(reference, draft),
  );
  await store.localCalendar.commit(command);
  return _calendarWindow(
    store,
  ).then((next) => next.items.singleWhere((item) => item.title == draft.title));
}

Future<CalendarWindow> _calendarWindow(JwStore store) =>
    store.localCalendar.query(
      CalendarQuery(
        firstDay: DateTime.utc(2026, 10, 1),
        endDayExclusive: DateTime.utc(2026, 11, 1),
        filter: CalendarFilter.personal,
      ),
    );

Future<void> _clearAgenda(JwStore store) async {
  final before = await store.applicationSettings.inspectSettings();
  final request = await store.applicationSettings.prepareMaintenance(
    before.context,
    MaintenanceKind.agenda,
    confirmed: true,
  );
  final intent = await store.applicationSettings.beginMaintenance(request);
  await store.applicationSettings.completeMaintenance(intent);
}

Future<List<TaskRecord>> _tasks(JwStore store) async =>
    (await store.localCalendar.queryTasks(
      const TaskQuery(filter: TaskFilter.all),
    )).items;

Future<int> _count(JwStore store, String table) async =>
    (await store
            .customSelect('SELECT COUNT(*) AS count FROM $table')
            .getSingle())
        .read<int>('count');

Future<void> _agentFailure(Future<dynamic> call, AgentFailureCode code) =>
    expectLater(
      call,
      throwsA(
        isA<AgentFailure>().having((failure) => failure.code, 'code', code),
      ),
    );

Future<void> _calendarFailure(Future<dynamic> call, CalendarFailureCode code) =>
    expectLater(
      call,
      throwsA(
        isA<CalendarFailure>().having((failure) => failure.code, 'code', code),
      ),
    );

Future<File> _temporaryDatabase() async {
  final directory = await Directory.systemTemp.createTemp(
    'agent-context-test-',
  );
  addTearDown(() async {
    final tempRoot =
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}';
    if (!directory.absolute.path.toLowerCase().startsWith(
          tempRoot.toLowerCase(),
        ) ||
        !directory.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('agent-context-test-')) {
      throw StateError('Unexpected synthetic temporary root');
    }
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File ||
          !const {
            'agent.sqlite',
            'agent.sqlite-wal',
            'agent.sqlite-shm',
            'agent.sqlite-journal',
          }.contains(entry.uri.pathSegments.last)) {
        throw StateError('Unexpected synthetic temporary entry');
      }
      await entry.delete();
    }
    await directory.delete();
  });
  return File('${directory.path}${Platform.pathSeparator}agent.sqlite');
}

void _removeSchema15ObjectsForLegacyFixture(sqlite3.Database database) {
  final tables = database
      .select("SELECT name FROM sqlite_master WHERE type='table'")
      .map((row) => row['name'] as String)
      .toSet();
  final indexes = database
      .select("SELECT name FROM sqlite_master WHERE type='index'")
      .map((row) => row['name'] as String)
      .toSet();
  if (indexes.contains('agent_action_invocation')) {
    database.execute('DROP INDEX agent_action_invocation');
  }
  if (tables.contains('agent_actions')) {
    final columns = database
        .select('PRAGMA table_info(agent_actions)')
        .map((row) => row['name'] as String)
        .toSet();
    if (columns.contains('invocation_fingerprint')) {
      database.execute(
        'ALTER TABLE agent_actions DROP COLUMN invocation_fingerprint',
      );
    }
  }
  for (final table in const [
    'agent_context_turns',
    'agent_target_aliases',
    'agent_use_policy',
  ]) {
    if (tables.contains(table)) database.execute('DROP TABLE $table');
  }
  if (tables.contains('agent_messages')) {
    final columns = database
        .select('PRAGMA table_info(agent_messages)')
        .map((row) => row['name'] as String)
        .toSet();
    if (columns.contains('context_private')) {
      database.execute(
        'ALTER TABLE agent_messages DROP COLUMN context_private',
      );
    }
  }
  if (tables.contains('agent_chat_state')) {
    final columns = database
        .select('PRAGMA table_info(agent_chat_state)')
        .map((row) => row['name'] as String)
        .toSet();
    if (columns.contains('summary_private')) {
      database.execute(
        'ALTER TABLE agent_chat_state DROP COLUMN summary_private',
      );
    }
  }
}

final class _SyntheticProtector implements ModelCredentialProtector {
  @override
  String get mechanism => 'synthetic-agent-context-protector/v1';

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
  }) async => Uint8List.fromList(
    ciphertext.skip(1).map((byte) => byte ^ 0x5A).toList(),
  );
}

final class _TestOwnership implements AssetOwnership {
  @override
  bool get isHeld => true;

  @override
  void ensureHeld() {}
}
