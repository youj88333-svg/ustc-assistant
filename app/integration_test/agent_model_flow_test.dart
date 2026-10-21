import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/app/demo_runtime.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_page.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_controller.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/settings_contract.dart';
import 'package:ustc_assistant_m0/m0_entry.dart';
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/platform/agent_image_picker.dart';

import 'support/diagnostic_cleanup.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets(
    'default Agent configures a synthetic model, stops a stream, and reopens without resuming it',
    (tester) async {
      final workspace = await _createWorkspace();
      final bootstraps = <RuntimeBootstrap>[];
      try {
        final firstGateway = _SyntheticGateway();
        final first = await _openBootstrap(
          tester,
          workspace,
          gateway: firstGateway,
        );
        bootstraps.add(first);
        expect(first.runtime, isNotNull);
        expect(first.directory.isHeld, isTrue);
        expect(first.jwDirectory.isHeld, isTrue);

        await tester.pumpWidget(_application(first));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('agent-page-title')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('agent-model-setup-prompt')),
          findsOneWidget,
        );
        expect(first.runtime!.agent.view.settings!.keySaved, isFalse);
        expect(firstGateway.requestCount, 0);

        await _tapKey(tester, 'agent-settings-open');
        await _tapKey(tester, 'agent-use-policy-full-settings');
        expect(find.text('Agent 设置'), findsOneWidget);
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const ValueKey('agent-settings-load-models')),
              )
              .onPressed,
          isNull,
          reason: 'Consent and a synthetic key are required before requests.',
        );
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('agent-settings-verify-save')),
              )
              .onPressed,
          isNull,
        );
        expect(firstGateway.requestCount, 0);

        await tester.tap(find.byKey(const ValueKey('agent-settings-consent')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const ValueKey('agent-settings-load-models')),
              )
              .onPressed,
          isNull,
          reason: 'Consent alone cannot make a model request without a Key.',
        );
        await tester.enterText(
          find.byKey(const ValueKey('agent-settings-key')),
          'm51-synthetic-only-key',
        );
        await _tapKey(tester, 'agent-settings-load-models');
        expect(firstGateway.listModelCalls, 1);
        expect(firstGateway.sawSyntheticKey, isTrue);
        expect(first.runtime!.agent.view.pendingKeyProvided, isTrue);
        expect(
          tester
              .widget<TextField>(
                find.byKey(const ValueKey('agent-settings-key')),
              )
              .controller!
              .text,
          isEmpty,
          reason: 'The widget clears the temporary Key after the request.',
        );
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('agent-settings-verify-save')),
              )
              .onPressed,
          isNull,
          reason: 'Choose a returned model before verification is enabled.',
        );

        await tester.tap(find.byKey(const ValueKey('agent-settings-model')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('synthetic-chat-model').last);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('agent-settings-verify-save')),
              )
              .onPressed,
          isNotNull,
          reason: 'The selected model can use the bounded candidate Key.',
        );
        await _tapKey(tester, 'agent-settings-verify-save');
        expect(firstGateway.listModelCalls, 2);
        expect(firstGateway.verificationCalls, 3);
        expect(firstGateway.chatRequests, isEmpty);
        var saved = first.runtime!.agent.view.settings!;
        expect(saved.keySaved, isTrue);
        expect(saved.consent, isTrue);
        expect(saved.modelId, 'synthetic-chat-model');
        expect(first.runtime!.agent.view.canSend, isTrue);
        expect(first.runtime!.agent.view.report.text, isTrue);
        expect(first.runtime!.agent.view.report.streaming, isTrue);
        expect(first.runtime!.agent.view.report.toolCall, isTrue);
        expect(first.runtime!.agent.view.report.toolResult, isTrue);
        expect(
          tester
              .widget<TextField>(
                find.byKey(const ValueKey('agent-settings-key')),
              )
              .controller!
              .text,
          isEmpty,
        );
        expect(find.text('m51-synthetic-only-key'), findsNothing);

        await _returnFromAgentSettings(tester);
        expect(
          find.byKey(const ValueKey('agent-empty-new-conversation')),
          findsNothing,
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('agent-composer')),
          '只测试合成流式对话',
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<IconButton>(find.byKey(const ValueKey('agent-send')))
              .onPressed,
          isNotNull,
          reason: 'The non-empty draft should enable the send control.',
        );
        firstGateway.holdNextChat = true;
        await tester.tap(find.byKey(const ValueKey('agent-send')));
        await _pumpUntil(
          tester,
          () => find.byKey(const ValueKey('agent-stop')).evaluate().isNotEmpty,
          reason: 'The synthetic chat should remain in its streaming phase.',
        );
        expect(find.textContaining('合成流式片段'), findsOneWidget);
        expect(firstGateway.chatRequests, hasLength(1));
        expect(
          firstGateway.chatRequests.single.tools
              .map((tool) => tool.name)
              .toSet(),
          hasLength(20),
          reason:
              'The configured tool registry stays stable for ordinary chat.',
        );
        expect(firstGateway.chatRequests.single.toolChoice, isNull);
        await _tapKey(tester, 'agent-stop');
        expect(first.runtime!.agent.view.phase, AgentPhase.idle);
        expect(first.runtime!.agent.view.messages, hasLength(2));
        expect(
          first.runtime!.agent.view.messages.last.status,
          AgentMessageStatus.cancelled,
        );
        expect(firstGateway.cancelCount, 1);

        final oldConversation = first.runtime!.agent.view.conversationId;
        expect(oldConversation, isNotNull);
        await _unmountAndClose(tester, first);

        final reopenedGateway = _SyntheticGateway();
        final reopened = await _openBootstrap(
          tester,
          workspace,
          gateway: reopenedGateway,
        );
        bootstraps.add(reopened);
        expect(reopened.runtime, isNotNull);
        saved = reopened.runtime!.agent.view.settings!;
        expect(saved.keySaved, isTrue);
        expect(saved.consent, isTrue);
        expect(saved.modelId, 'synthetic-chat-model');
        expect(reopened.runtime!.agent.view.phase, AgentPhase.idle);
        expect(reopened.runtime!.agent.view.conversationId, oldConversation);
        expect(reopened.runtime!.agent.view.messages, hasLength(2));
        expect(
          reopened.runtime!.agent.view.messages.last.status,
          AgentMessageStatus.cancelled,
        );
        expect(reopened.runtime!.agent.view.messages.last.text, '合成流式片段');
        expect(reopenedGateway.requestCount, 0);

        await tester.pumpWidget(_application(reopened));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 1));
        expect(find.byKey(const ValueKey('agent-stop')), findsNothing);
        expect(reopened.runtime!.agent.view.phase, AgentPhase.idle);
        expect(reopenedGateway.requestCount, 0);
        await _tapKey(tester, 'agent-settings-open');
        await _tapKey(tester, 'agent-use-policy-full-settings');
        expect(
          tester
              .widget<TextField>(
                find.byKey(const ValueKey('agent-settings-key')),
              )
              .controller!
              .text,
          isEmpty,
        );
        expect(find.text('m51-synthetic-only-key'), findsNothing);
        expect(reopenedGateway.requestCount, 0);
      } finally {
        await _disposeAndClean(tester, workspace, bootstraps);
      }
    },
  );

  testWidgets(
    'agenda clear retains Agent data, full reset removes it, and activation retry releases maintenance state',
    (tester) async {
      final workspace = await _createWorkspace();
      final bootstraps = <RuntimeBootstrap>[];
      try {
        final firstGateway = _SyntheticGateway();
        final first = await _openBootstrap(
          tester,
          workspace,
          gateway: firstGateway,
        );
        bootstraps.add(first);
        await _configureAgent(tester, first, key: 'm51-synthetic-retained-key');
        await _completeSyntheticTurn(tester, first, '重置前的合成历史');
        final originalConversation = first.runtime!.agent.view.conversationId;
        expect(first.runtime!.agent.view.messages, hasLength(2));

        await _seedSyntheticPersonalEvent(tester, first.runtime!);
        await tester.pumpWidget(_application(first));
        await tester.pumpAndSettle();
        await _openSettings(tester);
        await _openDataPrivacy(tester);
        await _confirmMaintenance(
          tester,
          buttonKey: 'settings-clear-agenda',
          finalAction: '确认清空日程与任务',
        );
        await _waitSettled(tester, first);
        expect(first.runtime!.agentCoordinator.view.phase, AgentPhase.idle);
        expect(first.runtime!.agent.view.settings!.keySaved, isTrue);
        expect(first.runtime!.agent.view.conversationId, originalConversation);
        expect(first.runtime!.agent.view.messages, hasLength(2));

        await _openSettings(tester);
        await _openDataPrivacy(tester);
        await _confirmMaintenance(
          tester,
          buttonKey: 'settings-reset',
          finalAction: '确认完全重置',
        );
        await _waitSettled(tester, first);
        expect(first.runtime!.agentCoordinator.view.phase, AgentPhase.idle);
        expect(first.runtime!.agent.view.settings!.keySaved, isFalse);
        expect(first.runtime!.agent.view.settings!.consent, isFalse);
        expect(first.runtime!.agent.view.settings!.modelId, isNull);
        expect(first.runtime!.agent.view.conversations, hasLength(1));
        expect(
          first.runtime!.agent.view.conversationId,
          isNot(originalConversation),
        );
        expect(first.runtime!.agent.view.messages, isEmpty);
        expect(first.runtime!.agent.view.canSend, isFalse);
        expect(
          find.byKey(const ValueKey('agent-model-setup-prompt')),
          findsOneWidget,
        );

        // Recreate only synthetic Agent state to verify a failed product
        // activation can retry without leaving C3 in its maintenance phase.
        await _configureAgent(tester, first, key: 'm51-synthetic-retry-key');
        await _completeSyntheticTurn(tester, first, '恢复重试合成历史');
        await _unmountAndClose(tester, first);

        var checkpointCalls = 0;
        Future<void> failOneActivationCheckpoint() async {
          checkpointCalls++;
          if (checkpointCalls == 1) {
            throw StateError('synthetic activation checkpoint failure');
          }
        }

        final retryGateway = _SyntheticGateway();
        final recovered = await _openBootstrap(
          tester,
          workspace,
          gateway: retryGateway,
          onActivationCheckpoint: failOneActivationCheckpoint,
        );
        bootstraps.add(recovered);
        expect(recovered.runtime, isNull);
        expect(recovered.directory.isHeld, isTrue);
        expect(recovered.jwDirectory.isHeld, isTrue);
        expect(recovered.agent.view.phase, AgentPhase.idle);
        expect(retryGateway.requestCount, 0);

        await tester.pumpWidget(_application(recovered));
        await tester.pumpAndSettle();
        expect(find.text('正在恢复本机数据'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('maintenance-recovery-retry')),
          findsOneWidget,
        );
        final retryButton = find.byKey(
          const ValueKey('maintenance-recovery-retry'),
        );
        await tester.ensureVisible(retryButton);
        await tester.tap(retryButton);
        await tester.pump();
        await _waitSettled(tester, recovered);
        expect(recovered.runtime, isNotNull);
        expect(checkpointCalls, 2);
        expect(recovered.runtime!.agent.view.phase, AgentPhase.idle);
        expect(recovered.runtime!.agent.view.settings!.keySaved, isTrue);
        expect(
          recovered.runtime!.agent.view.settings!.modelId,
          'synthetic-chat-model',
        );
        expect(recovered.runtime!.agent.view.conversations, hasLength(1));
        expect(recovered.runtime!.agent.view.messages, hasLength(2));
        expect(retryGateway.requestCount, 0);
      } finally {
        await _disposeAndClean(tester, workspace, bootstraps);
      }
    },
  );

  testWidgets(
    'a failed exit cancels its old run and preserves ownership for retry',
    (tester) async {
      final workspace = await _createWorkspace();
      final bootstraps = <RuntimeBootstrap>[];
      try {
        final gateway = _SyntheticGateway()..failNextClose = true;
        final bootstrap = await _openBootstrap(
          tester,
          workspace,
          gateway: gateway,
        );
        bootstraps.add(bootstrap);
        await _configureAgent(tester, bootstrap, key: 'm51-synthetic-exit-key');
        await _runNative(tester, bootstrap.runtime!.agent.newConversation);
        await tester.pumpWidget(_application(bootstrap));
        await tester.pumpAndSettle();

        late Future<void> oldSend;
        gateway.holdNextChat = true;
        await tester.runAsync(() async {
          oldSend = bootstrap.runtime!.agent.send('关闭期间的合成问题');
          await gateway.waitForHeldChat.timeout(const Duration(seconds: 10));
        });
        expect(bootstrap.runtime!.agent.view.phase, AgentPhase.generating);

        await expectLater(
          _runNative(tester, bootstrap.close),
          throwsA(isA<StateError>()),
        );
        await _runNative(tester, () async => oldSend);
        expect(bootstrap.directory.isHeld, isTrue);
        expect(bootstrap.jwDirectory.isHeld, isTrue);
        expect(gateway.cancelCount, greaterThanOrEqualTo(1));
        expect(bootstrap.runtime!.agent.view.phase, AgentPhase.recovery);
        expect(bootstrap.runtime!.agent.view.canSend, isFalse);
        expect(bootstrap.runtime!.agent.view.messages, hasLength(2));
        expect(
          bootstrap.runtime!.agent.view.messages.last.status,
          AgentMessageStatus.cancelled,
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await _closeBootstrap(tester, bootstrap);
        expect(bootstrap.directory.isHeld, isFalse);
        expect(bootstrap.jwDirectory.isHeld, isFalse);
        expect(gateway.closeCount, 2);
      } finally {
        await _disposeAndClean(tester, workspace, bootstraps);
      }
    },
  );
  testWidgets(
    'readonly business and knowledge evidence plus active image input survive native integration',
    (tester) async {
      final workspace = await _createWorkspace();
      final bootstraps = <RuntimeBootstrap>[];
      try {
        final gateway = _SyntheticGateway();
        final first = await _openBootstrap(tester, workspace, gateway: gateway);
        bootstraps.add(first);
        await _configureAgent(tester, first, key: 'm51-synthetic-only-key');
        await _seedSyntheticPersonalEvent(tester, first.runtime!);
        await _runNative(tester, first.agent.newConversation);
        await tester.pumpWidget(_application(first));
        await tester.pumpAndSettle();
        gateway.readScenario = 'agenda';
        await _runNative(tester, () => first.agent.send('M52 合成日程查询'));
        await tester.pumpAndSettle();
        expect(first.agent.view.failure, isNull);
        expect(
          first.agent.view.messages.last.evidence.single.title,
          'M51 合成个人安排',
        );
        expect(
          first.agent.view.messages.last.steps.single.tool,
          'query_agenda',
        );
        expect(
          gateway.chatRequests.last.messages.last.content,
          contains('2026-10-13T10:00:00+08:00'),
        );
        expect(
          gateway.chatRequests.last.messages.last.content,
          isNot(contains('仅供本机集成测试')),
        );
        expect(
          find.byKey(
            ValueKey(
              'agent-evidence-${first.agent.view.messages.last.evidence.single.id}',
            ),
          ),
          findsNothing,
        );
        final message = first.agent.view.messages.last;
        await _tapKey(
          tester,
          'agent-query-details-toggle-${first.agent.view.conversationId}:${message.id}',
        );
        expect(
          find.byKey(ValueKey('agent-evidence-${message.evidence.single.id}')),
          findsOneWidget,
        );

        await _runNative(tester, () async {
          final outcome = await first.knowledge.loadBundledEdition();
          expect(outcome.failure, isNull);
        });
        gateway.readScenario = 'knowledge';
        await _runNative(tester, () => first.agent.send('M52 合成缓考流程查询'));
        await tester.pumpAndSettle();
        expect(first.agent.view.failure, isNull);
        expect(first.agent.view.messages.last.steps.map((s) => s.tool), [
          'search_knowledge',
          'read_knowledge',
        ]);
        expect(first.agent.view.messages.last.evidence, hasLength(2));
        expect(
          first.agent.view.messages.last.evidence.last.articleUrl,
          startsWith('https://www.teach.ustc.edu.cn/'),
        );

        final image = await _runNative(tester, () async {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          canvas.drawRect(
            const Rect.fromLTWH(0, 0, 8, 8),
            Paint()..color = Colors.blue,
          );
          final picture = recorder.endRecording();
          final encoded = await picture.toImage(8, 8);
          try {
            final bytes = await encoded.toByteData(
              format: ui.ImageByteFormat.png,
            );
            return await normalizeAgentImage(Uint8List.sublistView(bytes!));
          } finally {
            encoded.dispose();
            picture.dispose();
          }
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AgentWorkspacePage(
                controller: first.agent,
                onSettings: () {},
                pickImages: () async => [image],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _tapKey(tester, 'agent-attach-image');
        expect(
          find.byKey(const ValueKey('agent-image-preview-0')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('agent-send')));
        await tester.pump();
        await _pumpUntil(
          tester,
          () => first.agent.view.phase == AgentPhase.idle,
          reason: 'Synthetic image turn did not finish',
        );
        await tester.pumpAndSettle();
        expect(first.agent.view.failure, isNull);
        expect(
          first
              .agent
              .view
              .messages[first.agent.view.messages.length - 2]
              .imageCount,
          1,
        );
        expect(
          find.byKey(const ValueKey('agent-image-preview-0')),
          findsNothing,
        );
        final beforeMessages = first.agent.view.messages.length;
        final beforeRequests = gateway.requestCount;
        await _unmountAndClose(tester, first);
        final nextGateway = _SyntheticGateway();
        final reopened = await _openBootstrap(
          tester,
          workspace,
          gateway: nextGateway,
        );
        bootstraps.add(reopened);
        expect(reopened.agent.view.messages, hasLength(beforeMessages));
        expect(
          reopened.agent.view.messages.where((m) => m.evidence.isNotEmpty),
          hasLength(2),
        );
        expect(
          reopened
              .agent
              .view
              .messages[reopened.agent.view.messages.length - 2]
              .imageCount,
          1,
        );
        expect(nextGateway.requestCount, 0);
        expect(beforeRequests, greaterThan(0));
      } finally {
        await _disposeAndClean(tester, workspace, bootstraps);
      }
    },
  );

  testWidgets(
    'native local plan reject, atomic commit, group undo, and restart stay bound to current cards',
    (tester) async {
      final workspace = await _createWorkspace();
      final bootstraps = <RuntimeBootstrap>[];
      try {
        final gateway = _SyntheticGateway()..scriptLocalActions = true;
        final first = await _openBootstrap(tester, workspace, gateway: gateway);
        bootstraps.add(first);
        await _configureAgent(tester, first, key: 'm51-synthetic-only-key');
        await _runNative(tester, first.runtime!.agent.newConversation);
        await tester.pumpWidget(_application(first));
        await tester.pumpAndSettle();

        final localCalendar = first.runtime!.jwStore.localCalendar;
        Future<TaskWindow> tasks() => _runNative(
          tester,
          () =>
              localCalendar.queryTasks(const TaskQuery(filter: TaskFilter.all)),
        );
        expect((await tasks()).items, isEmpty);

        final rejectedRun = await _sendUntilApproval(
          tester,
          first.agent,
          '创建M5合成学习任务，并于2026-10-13 14:00至16:00安排两个连续时间块，各一小时，避开冲突。',
        );
        final rejectedProposal = first.agent.view.pendingAction!;
        final rejectedId = rejectedProposal.id;
        expect(rejectedProposal.kind, AgentActionKind.localPlan);
        expect(rejectedProposal.status, AgentActionStatus.proposed);
        expect(gateway.actionCalls.single.name, 'propose_local_changes');
        expect(
          gateway.actionCalls.single.argumentsJson,
          isNot(contains('approved')),
        );
        expect(
          find.byKey(ValueKey('agent-action-reject-$rejectedId')),
          findsOneWidget,
        );

        expect(
          await _tapCurrentAction(tester, first.agent, approve: false),
          rejectedId,
        );
        await _runNative(tester, () => rejectedRun.completion);
        await tester.pumpAndSettle();
        expect(first.agent.view.phase, AgentPhase.idle);
        expect(first.agent.view.failure, isNull);
        expect((await tasks()).items, isEmpty);
        final rejectedHistory = first.agent.view.messages
            .expand((message) => message.actions)
            .singleWhere((action) => action.id == rejectedId);
        expect(rejectedHistory.status, AgentActionStatus.rejected);
        expect(
          find.byKey(ValueKey('agent-action-approve-$rejectedId')),
          findsNothing,
        );

        final acceptedRun = await _sendUntilApproval(
          tester,
          first.agent,
          '请再次创建M5合成学习任务，并于2026-10-13 14:00至16:00安排两个连续时间块，各一小时，避开冲突。',
        );
        final acceptedProposal = first.agent.view.pendingAction!;
        final acceptedId = acceptedProposal.id;
        expect(acceptedId, isNot(rejectedId));
        expect(acceptedProposal.kind, AgentActionKind.localPlan);
        expect((await tasks()).items, isEmpty);
        expect(
          gateway.actionCalls[1].argumentsJson,
          isNot(contains('approved')),
        );
        expect(
          find.byKey(ValueKey('agent-action-approve-$acceptedId')),
          findsOneWidget,
        );

        expect(
          await _tapCurrentAction(tester, first.agent, approve: true),
          acceptedId,
        );
        await _runNative(tester, () => acceptedRun.completion);
        await tester.pumpAndSettle();
        await _scrollAgentToLatest(tester);
        expect(first.agent.view.phase, AgentPhase.idle);
        expect(first.agent.view.failure, isNull);
        final committedPlan = first.agent.view.messages
            .expand((message) => message.actions)
            .singleWhere((action) => action.id == acceptedId);
        expect(committedPlan.status, AgentActionStatus.committed);
        expect(committedPlan.committedCount, 3);
        expect(
          find.byKey(ValueKey('agent-action-committed-$acceptedId')),
          findsNothing,
        );
        await _expandLatestProcessingDetails(tester, first.agent);
        expect(
          find.byKey(ValueKey('agent-action-committed-$acceptedId')),
          findsOneWidget,
        );

        final committedTasks = (await tasks()).items;
        expect(committedTasks, hasLength(1));
        expect(committedTasks.single.draft.title, 'M5合成学习任务');
        expect(committedTasks.single.blockCount, 2);
        final committedDetail = await _runNative(
          tester,
          () => localCalendar.taskDetail(committedTasks.single.reference),
        );
        expect(committedDetail.blocks, hasLength(2));
        expect(
          committedDetail.blocks
              .map((block) => block.draft.startsAtUtc)
              .toSet(),
          {DateTime.utc(2026, 10, 13, 6), DateTime.utc(2026, 10, 13, 7)},
        );
        expect(
          committedDetail.blocks.map((block) => block.draft.endsAtUtc).toSet(),
          {DateTime.utc(2026, 10, 13, 7), DateTime.utc(2026, 10, 13, 8)},
        );

        final undoRun = await _sendUntilApproval(
          tester,
          first.agent,
          '请撤销这次创建的M5合成学习任务和两个时间块。',
        );
        final undoProposal = first.agent.view.pendingAction!;
        final undoId = undoProposal.id;
        expect(undoProposal.kind, AgentActionKind.undo);
        expect(undoProposal.status, AgentActionStatus.proposed);
        expect(gateway.actionCalls.last.name, 'propose_undo');
        expect(jsonDecode(gateway.actionCalls.last.argumentsJson), {
          'scope': 'latest_local_change',
        });
        expect(
          find.byKey(ValueKey('agent-action-approve-$undoId')),
          findsOneWidget,
        );

        expect(
          await _tapCurrentAction(tester, first.agent, approve: true),
          undoId,
        );
        await _runNative(tester, () => undoRun.completion);
        await tester.pumpAndSettle();
        await _scrollAgentToLatest(tester);
        expect(first.agent.view.phase, AgentPhase.idle);
        expect(first.agent.view.failure, isNull);
        expect((await tasks()).items, isEmpty);
        final committedUndo = first.agent.view.messages
            .expand((message) => message.actions)
            .singleWhere((action) => action.id == undoId);
        expect(committedUndo.status, AgentActionStatus.committed);
        expect(committedUndo.committedCount, 1);
        expect(
          find.byKey(ValueKey('agent-action-committed-$undoId')),
          findsNothing,
        );
        await _expandLatestProcessingDetails(tester, first.agent);
        expect(
          find.byKey(ValueKey('agent-action-committed-$undoId')),
          findsOneWidget,
        );

        await _unmountAndClose(tester, first);
        final reopenedGateway = _SyntheticGateway();
        final reopened = await _openBootstrap(
          tester,
          workspace,
          gateway: reopenedGateway,
        );
        bootstraps.add(reopened);
        expect(reopened.runtime, isNotNull);
        expect(reopened.agent.view.phase, AgentPhase.idle);
        expect(reopened.agent.view.pendingAction, isNull);
        expect(reopenedGateway.requestCount, 0);
        final reopenedTasks = await _runNative(
          tester,
          () => reopened.runtime!.jwStore.localCalendar.queryTasks(
            const TaskQuery(filter: TaskFilter.all),
          ),
        );
        expect(reopenedTasks.items, isEmpty);
        final persistedActions = reopened.agent.view.messages
            .expand((message) => message.actions)
            .toList();
        expect(
          persistedActions.any(
            (action) =>
                action.id == acceptedId &&
                action.status == AgentActionStatus.committed &&
                action.committedCount == 3,
          ),
          isTrue,
        );
        expect(
          persistedActions.any(
            (action) =>
                action.id == undoId &&
                action.kind == AgentActionKind.undo &&
                action.status == AgentActionStatus.committed,
          ),
          isTrue,
        );

        await tester.pumpWidget(_application(reopened));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 1));
        await _scrollAgentToLatest(tester);
        expect(reopenedGateway.requestCount, 0);
        expect(reopened.agent.view.phase, AgentPhase.idle);
        expect(find.byKey(const ValueKey('agent-stop')), findsNothing);
        expect(
          find.byKey(ValueKey('agent-action-status-$undoId')),
          findsNothing,
        );
        await _expandLatestProcessingDetails(tester, reopened.agent);
        expect(
          find.byKey(ValueKey('agent-action-status-$undoId')),
          findsOneWidget,
        );
        expect(
          find.byKey(ValueKey('agent-action-approve-$undoId')),
          findsNothing,
        );
      } finally {
        await _disposeAndClean(tester, workspace, bootstraps);
      }
    },
  );
}

// This suite also covers the real C4 -> C3 read adaptation and the native
// image codec, using synthetic TEMP data and a synthetic model only.
Future<RuntimeBootstrap> _openBootstrap(
  WidgetTester tester,
  _OwnedWorkspace workspace, {
  required _SyntheticGateway gateway,
  Future<void> Function()? onActivationCheckpoint,
}) => _runNative(
  tester,
  () => RuntimeBootstrap.open(
    directoryPath: workspace.demoPath,
    jwDirectoryPath: workspace.formalPath,
    clock: FixedClock(DateTime.utc(2026, 10, 13, 4)),
    modelGateway: gateway,
    onActivationCheckpoint: onActivationCheckpoint,
  ),
);

Future<void> _configureAgent(
  WidgetTester tester,
  RuntimeBootstrap bootstrap, {
  required String key,
}) async {
  final agent = bootstrap.runtime!.agent;
  await _runNative(tester, () => agent.loadModels(key: key, consent: true));
  expect(agent.view.pendingKeyProvided, isTrue);
  await _runNative(
    tester,
    () => agent.verifyAndSave(modelId: 'synthetic-chat-model', consent: true),
  );
  expect(agent.view.settings!.keySaved, isTrue);
  expect(agent.view.canSend, isTrue);
}

Future<void> _completeSyntheticTurn(
  WidgetTester tester,
  RuntimeBootstrap bootstrap,
  String question,
) async {
  final agent = bootstrap.runtime!.agent;
  await _runNative(tester, agent.newConversation);
  await _runNative(tester, () => agent.send(question));
  expect(agent.view.messages, hasLength(2));
  expect(agent.view.messages.last.status, AgentMessageStatus.complete);
}

Future<void> _seedSyntheticPersonalEvent(
  WidgetTester tester,
  DemoRuntime runtime,
) async {
  final context = runtime.calendar.view.window!.context;
  await _runNative(
    tester,
    () => runtime.calendar.execute(
      CreatePersonalEvent(
        PersonalEventDraft(
          title: 'M51 合成个人安排',
          start: DateTime.utc(2026, 10, 13, 2),
          end: DateTime.utc(2026, 10, 13, 2, 30),
          note: '仅供本机集成测试',
        ),
      ),
      expectedContext: context,
    ),
  );
}

Future<void> _openSettings(WidgetTester tester) async {
  await _tapKey(tester, 'shell-nav-settings');
}

Future<void> _returnFromAgentSettings(WidgetTester tester) async {
  final title = find.text('Agent 设置');
  expect(title, findsOneWidget);
  final context = tester.element(title);
  expect(
    Navigator.of(context).canPop(),
    isTrue,
    reason: 'Agent settings must remain a pushed route above the Agent page.',
  );
  expect(
    ModalRoute.of(context)?.isCurrent,
    isTrue,
    reason: 'The visible settings route must still be the active route.',
  );
  final backButton = find.byTooltip('返回');
  expect(
    backButton,
    findsOneWidget,
    reason: 'Agent settings must expose its visible localized back control.',
  );
  await tester.tap(backButton);
  await tester.pumpAndSettle();
}

Future<void> _openDataPrivacy(WidgetTester tester) async {
  await _tapKey(tester, 'settings-section-dataPrivacy');
}

Future<void> _confirmMaintenance(
  WidgetTester tester, {
  required String buttonKey,
  required String finalAction,
}) async {
  await _tapKey(tester, buttonKey);
  await _tapText(tester, '继续确认');
  expect(find.text(finalAction), findsOneWidget);
  await _tapText(tester, finalAction);
}

Future<void> _waitSettled(
  WidgetTester tester,
  RuntimeBootstrap bootstrap,
) async {
  final watch = Stopwatch()..start();
  while (bootstrap.settings.settingsView.actionPending ||
      bootstrap.settings.settingsView.loading ||
      bootstrap.settings.settingsView.maintenance.blocksProduct) {
    if (watch.elapsed > const Duration(seconds: 50)) {
      throw StateError(
        'Synthetic Agent maintenance did not settle: ${bootstrap.settings.settingsView.maintenance.phase.name}',
      );
    }
    if (bootstrap.settings.settingsView.maintenance.phase ==
            MaintenancePhase.recovery &&
        !bootstrap.settings.settingsView.actionPending) {
      throw StateError(
        'Synthetic Agent maintenance recovery: ${bootstrap.settings.settingsView.maintenance.failure?.name}',
      );
    }
    await _runNative(
      tester,
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey<String>(key));
  expect(finder, findsOneWidget, reason: 'Missing UI key: $key');
  await tester.ensureVisible(finder);
  if (key == 'agent-stop') {
    await tester.pump(const Duration(milliseconds: 100));
  } else {
    await tester.pumpAndSettle();
  }
  await tester.tap(finder);
  await tester.pump();
  await tester.pumpAndSettle();
}

Future<void> _tapText(WidgetTester tester, String label) async {
  final finder = find.text(label);
  expect(finder, findsOneWidget, reason: 'Missing UI label: $label');
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pump();
  await tester.pumpAndSettle();
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 10)) {
      fail(reason);
    }
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _scrollAgentToLatest(WidgetTester tester) async {
  final list = find.byKey(const ValueKey('agent-message-list'));
  if (list.evaluate().isEmpty) return;
  await tester.drag(list, const Offset(0, -4000));
  await tester.pumpAndSettle();
}

Future<void> _expandLatestProcessingDetails(
  WidgetTester tester,
  AgentWorkspaceController agent,
) async {
  final message = agent.view.messages.last;
  await _tapKey(
    tester,
    'agent-query-details-toggle-${agent.view.conversationId}:${message.id}',
  );
}

Future<_PendingAgentRun> _sendUntilApproval(
  WidgetTester tester,
  AgentWorkspaceController agent,
  String question,
) async {
  late Future<void> completion;
  await tester.runAsync(() async {
    completion = agent.send(question);
    await _waitNativeUntil(
      () =>
          agent.view.phase == AgentPhase.waitingForApproval ||
          (agent.view.phase == AgentPhase.idle && agent.view.failure != null),
      reason:
          'Synthetic plan did not reach approval: '
          'phase=${agent.view.phase}, failure=${agent.view.failure}',
    );
  });
  await tester.pumpAndSettle();
  expect(
    agent.view.phase,
    AgentPhase.waitingForApproval,
    reason: 'A native proposal must wait for an application decision.',
  );
  return _PendingAgentRun(completion);
}

Future<String> _tapCurrentAction(
  WidgetTester tester,
  AgentWorkspaceController agent, {
  required bool approve,
}) async {
  expect(agent.view.phase, AgentPhase.waitingForApproval);
  final action = agent.view.pendingAction;
  expect(action, isNotNull);
  final actionId = action!.id;
  final button = find.byKey(
    ValueKey('agent-action-${approve ? 'approve' : 'reject'}-$actionId'),
  );
  expect(button, findsOneWidget);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  expect(agent.view.pendingAction?.id, actionId);
  await tester.tap(button);
  await tester.pump();
  return actionId;
}

Future<void> _waitNativeUntil(
  bool Function() condition, {
  required String reason,
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 20)) {
      throw StateError(reason);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Widget _application(RuntimeBootstrap bootstrap) =>
    OwnedApplication(bootstrap: bootstrap);

Future<void> _unmountAndClose(
  WidgetTester tester,
  RuntimeBootstrap bootstrap,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await _closeBootstrap(tester, bootstrap);
}

Future<void> _closeBootstrap(
  WidgetTester tester,
  RuntimeBootstrap bootstrap,
) async {
  if (!bootstrap.directory.isHeld && !bootstrap.jwDirectory.isHeld) return;
  await _runNative(tester, bootstrap.close);
  expect(bootstrap.directory.isHeld, isFalse);
  expect(bootstrap.jwDirectory.isHeld, isFalse);
}

Future<void> _disposeAndClean(
  WidgetTester tester,
  _OwnedWorkspace workspace,
  List<RuntimeBootstrap> bootstraps,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  for (final bootstrap in bootstraps.reversed) {
    await _closeBootstrap(tester, bootstrap);
  }
  await _deleteOwnedWorkspace(workspace);
}

Future<_OwnedWorkspace> _createWorkspace() async {
  const prefix = 'ustc_m51_agent_';
  final root = await Directory.systemTemp.createTemp(prefix);
  final rootPath = _normal(root.path);
  final tempPath = _normal(await Directory.systemTemp.resolveSymbolicLinks());
  final rootName = p.windows.basename(rootPath);
  if (!p.windows.equals(p.windows.dirname(rootPath), tempPath) ||
      !rootName.startsWith(prefix) ||
      rootName.length == prefix.length ||
      !RegExp(
        r'^[A-Za-z0-9_-]+$',
      ).hasMatch(rootName.substring(prefix.length)) ||
      !p.windows.equals(rootPath, _normal(await root.resolveSymbolicLinks())) ||
      await FileSystemEntity.type(rootPath, followLinks: false) !=
          FileSystemEntityType.directory) {
    throw StateError('Refusing a TEMP root without a plain nonce directory.');
  }
  final nonce = _nonce();
  final markerName = '.m51-owner-$nonce.marker';
  final marker = File(p.windows.join(rootPath, markerName));
  final handle = await marker.open(mode: FileMode.writeOnly);
  try {
    await handle.writeString('$nonce\n');
    await handle.flush();
  } finally {
    await handle.close();
  }
  return _OwnedWorkspace(
    root: root,
    prefix: prefix,
    nonce: nonce,
    markerName: markerName,
    demoPath: p.windows.join(rootPath, 'demo-$nonce'),
    formalPath: p.windows.join(rootPath, 'formal-$nonce'),
  );
}

Future<void> _deleteOwnedWorkspace(_OwnedWorkspace workspace) async {
  final tempPath = _normal(await Directory.systemTemp.resolveSymbolicLinks());
  final rootPath = _normal(workspace.root.path);
  final rootName = p.windows.basename(rootPath);
  if (!p.windows.equals(p.windows.dirname(rootPath), tempPath) ||
      !rootName.startsWith(workspace.prefix) ||
      rootName.length == workspace.prefix.length ||
      !RegExp(
        r'^[A-Za-z0-9_-]+$',
      ).hasMatch(rootName.substring(workspace.prefix.length)) ||
      !p.windows.equals(
        rootPath,
        _normal(await workspace.root.resolveSymbolicLinks()),
      ) ||
      await FileSystemEntity.type(rootPath, followLinks: false) !=
          FileSystemEntityType.directory) {
    throw StateError('Refusing to remove a path outside the nonce TEMP root.');
  }

  final markerPath = p.windows.join(rootPath, workspace.markerName);
  if (await FileSystemEntity.type(markerPath, followLinks: false) !=
      FileSystemEntityType.file) {
    throw StateError(
      'Refusing to remove a TEMP root without its owner marker.',
    );
  }
  if (await File(markerPath).readAsString() != '${workspace.nonce}\n') {
    throw StateError(
      'Refusing to remove a TEMP root with a mismatched marker.',
    );
  }

  final expectedDemo = _normal(workspace.demoPath);
  final expectedFormal = _normal(workspace.formalPath);
  if (!p.windows.equals(p.windows.dirname(expectedDemo), rootPath) ||
      !p.windows.equals(p.windows.dirname(expectedFormal), rootPath) ||
      p.windows.basename(expectedDemo) != 'demo-${workspace.nonce}' ||
      p.windows.basename(expectedFormal) != 'formal-${workspace.nonce}') {
    throw StateError('Refusing an unrecognized TEMP child path.');
  }

  await _assertNoLinks(workspace.root, rootPath);
  final children = await workspace.root.list(followLinks: false).toList();
  final expectedNames = {
    workspace.markerName,
    p.windows.basename(expectedDemo),
    p.windows.basename(expectedFormal),
  };
  if (children.isEmpty ||
      children.map((entry) => p.windows.basename(entry.path)).toSet().length !=
          children.length ||
      children.any(
        (entry) => !expectedNames.contains(p.windows.basename(entry.path)),
      )) {
    throw StateError('Refusing to remove an unknown TEMP child.');
  }
  for (final child in children) {
    final path = _normal(child.path);
    if (p.windows.equals(path, markerPath)) {
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw StateError('The owner marker changed during cleanup.');
      }
      continue;
    }
    final formal = p.windows.equals(path, expectedFormal);
    if (!formal && !p.windows.equals(path, expectedDemo)) {
      throw StateError('Refusing to remove an unrecognized TEMP child.');
    }
    if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.directory ||
        !p.windows.equals(
          path,
          _normal(await Directory(path).resolveSymbolicLinks()),
        )) {
      throw StateError('A known TEMP child is not a plain owned directory.');
    }
    await _assertKnownDatabaseFiles(Directory(path), formal: formal);
  }
  await _assertNoLinks(workspace.root, rootPath);
  if (!p.windows.equals(
        rootPath,
        _normal(await workspace.root.resolveSymbolicLinks()),
      ) ||
      await FileSystemEntity.type(rootPath, followLinks: false) !=
          FileSystemEntityType.directory) {
    throw StateError('TEMP root changed during ownership validation.');
  }
  await workspace.root.delete(recursive: true);
}

Future<void> _assertKnownDatabaseFiles(
  Directory directory, {
  required bool formal,
}) async {
  final directoryPath = _normal(directory.path);
  final base = formal ? 'jw.sqlite' : 'm0_demo.sqlite';
  final allowedFiles = {base, '$base-wal', '$base-shm', '$base-journal'};
  final emptyRoots = formal
      ? {'jw_partitions_v1', 'young_partitions_v1'}
      : {'observation_v1', 'young_observation_v1'};
  await for (final entry in directory.list(followLinks: false)) {
    final path = _normal(entry.path);
    if (!p.windows.isWithin(directoryPath, path)) {
      throw StateError(
        'Refusing to remove an entry outside the owned directory.',
      );
    }
    final name = p.windows.basename(path);
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (allowedFiles.contains(name) && type == FileSystemEntityType.file) {
      continue;
    }
    if (formal &&
        name == 'diagnostics' &&
        type == FileSystemEntityType.directory) {
      await assertKnownFormalDiagnosticsDirectory(directory);
      continue;
    }
    if (emptyRoots.contains(name) && type == FileSystemEntityType.directory) {
      final root = Directory(path);
      if (!p.windows.equals(path, _normal(await root.resolveSymbolicLinks())) ||
          (await root.list(followLinks: false).take(1).toList()).isNotEmpty) {
        throw StateError(
          'Refusing to remove a populated or linked source root.',
        );
      }
      continue;
    }
    throw StateError('Refusing to remove an unknown TEMP database entry.');
  }
}

Future<void> _assertNoLinks(Directory root, String rootPath) async {
  final pending = <Directory>[root];
  while (pending.isNotEmpty) {
    final directory = pending.removeLast();
    await for (final entity in directory.list(followLinks: false)) {
      final path = _normal(entity.path);
      if (!p.windows.isWithin(rootPath, path)) {
        throw StateError('Refusing to remove an entry outside TEMP ownership.');
      }
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.link ||
          type == FileSystemEntityType.notFound) {
        throw StateError('Refusing to remove a link or changing TEMP entry.');
      }
      if (type == FileSystemEntityType.directory) {
        pending.add(Directory(path));
      } else if (type != FileSystemEntityType.file) {
        throw StateError('Refusing to remove an unknown TEMP entry type.');
      }
    }
  }
}

Future<T> _runNative<T>(
  WidgetTester tester,
  Future<T> Function() action,
) async {
  late T result;
  Object? failure;
  StackTrace? failureStack;
  try {
    await tester.runAsync(() async {
      try {
        result = await action();
      } catch (error, stack) {
        failure = error;
        failureStack = stack;
      }
    });
  } catch (error, stack) {
    // Preserve runAsync failures too, but rethrow only after leaving its zone
    // so expected failures can be asserted by the calling test.
    failure ??= error;
    failureStack ??= stack;
  }
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  return result;
}

String _normal(String path) => p.windows.normalize(p.windows.absolute(path));

String _nonce() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

final class _OwnedWorkspace {
  const _OwnedWorkspace({
    required this.root,
    required this.prefix,
    required this.nonce,
    required this.markerName,
    required this.demoPath,
    required this.formalPath,
  });

  final Directory root;
  final String prefix, nonce, markerName, demoPath, formalPath;
}

final class _PendingAgentRun {
  const _PendingAgentRun(this.completion);
  final Future<void> completion;
}

final class _SyntheticGateway implements ModelGatewayPort {
  static const modelId = 'synthetic-chat-model';

  final List<ModelRequest> chatRequests = [];
  final List<StreamController<ModelEvent>> _generations = [];
  final Completer<void> _heldChat = Completer<void>();
  bool holdNextChat = false;
  bool failNextClose = false;
  bool sawSyntheticKey = false;
  bool scriptLocalActions = false;
  int _actionCallSerial = 0;
  final List<ModelToolCall> actionCalls = [];
  String? readScenario;
  int requestCount = 0;
  int listModelCalls = 0;
  int verificationCalls = 0;
  int cancelCount = 0;
  int closeCount = 0;

  Future<void> get waitForHeldChat => _heldChat.future;

  @override
  Future<List<String>> listModels(ModelSecretLease secret) async {
    requestCount++;
    listModelCalls++;
    _consumeSyntheticKey(secret);
    return const [modelId];
  }

  @override
  Stream<ModelEvent> generate(ModelRequest request, ModelSecretLease secret) {
    requestCount++;
    _consumeSyntheticKey(secret);
    final controller = StreamController<ModelEvent>();
    _generations.add(controller);
    unawaited(_respond(request, controller));
    return controller.stream;
  }

  void _consumeSyntheticKey(ModelSecretLease secret) {
    final bytes = secret.take();
    try {
      final value = utf8.decode(bytes);
      sawSyntheticKey |=
          value == 'm51-synthetic-only-key' ||
          value == 'm51-synthetic-retained-key' ||
          value == 'm51-synthetic-retry-key' ||
          value == 'm51-synthetic-exit-key';
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<void> _respond(
    ModelRequest request,
    StreamController<ModelEvent> controller,
  ) async {
    await Future<void>.delayed(Duration.zero);
    if (controller.isClosed) return;
    if (request.tools.isNotEmpty && request.toolChoice == 'echo_probe') {
      verificationCalls++;
      controller.add(const ModelTextDelta(''));
      controller.add(
        ModelCompleted(
          finishReason: 'tool_calls',
          toolCalls: const [
            ModelToolCall(
              id: 'synthetic-probe-call',
              name: 'echo_probe',
              argumentsJson: '{"value":"ustc_probe"}',
            ),
          ],
        ),
      );
      await controller.close();
      return;
    }
    if (request.tools.isNotEmpty && request.toolChoice == 'none') {
      verificationCalls++;
      final toolContent = request.messages.last.content!;
      final decoded = jsonDecode(toolContent) as Map<String, Object?>;
      controller.add(ModelTextDelta(decoded['proof']! as String));
      controller.add(ModelCompleted(finishReason: 'stop'));
      await controller.close();
      return;
    }
    final lastMessage = request.messages.last;
    if (lastMessage.role == 'user' &&
        lastMessage.content!.contains('USTC_TEXT_PROBE')) {
      verificationCalls++;
      controller.add(const ModelTextDelta('USTC_TEXT_PROBE'));
      controller.add(ModelCompleted(finishReason: 'stop'));
      await controller.close();
      return;
    }

    chatRequests.add(request);
    if (scriptLocalActions) {
      final last = request.messages.last;
      if (request.toolChoice == 'find_free_slots') {
        controller.add(
          ModelCompleted(
            finishReason: 'tool_calls',
            toolCalls: [
              ModelToolCall(
                id: 'synthetic-free-$requestCount',
                name: 'find_free_slots',
                argumentsJson: jsonEncode({
                  'first_day': '2026-10-13',
                  'end_day_exclusive': '2026-10-14',
                  'start_minute': 14 * 60,
                  'end_minute': 16 * 60,
                  'block_minutes': 60,
                }),
              ),
            ],
          ),
        );
      } else if (last.role == 'user' ||
          last.role == 'tool' &&
              request.messages
                  .expand((message) => message.toolCalls)
                  .any(
                    (call) =>
                        call.id == last.toolCallId &&
                        call.name == 'find_free_slots',
                  )) {
        final undo = (last.content ?? '').contains('撤销');
        final name = undo ? 'propose_undo' : 'propose_local_changes';
        if (!request.tools.any((tool) => tool.name == name)) {
          controller.addError(
            const AgentFailure(AgentFailureCode.toolUnavailable),
          );
          await controller.close();
          return;
        }
        final call = ModelToolCall(
          id: 'synthetic-action-${++_actionCallSerial}',
          name: name,
          argumentsJson: undo
              ? '{"scope":"latest_local_change"}'
              : jsonEncode({
                  'changes': [
                    {
                      'type': 'create_task',
                      'local_key': 'm56-study',
                      'title': 'M5合成学习任务',
                      'estimated_minutes': 120,
                    },
                    {
                      'type': 'create_block',
                      'task_key': 'm56-study',
                      'start': '2026-10-13T14:00+08:00',
                      'end': '2026-10-13T15:00+08:00',
                    },
                    {
                      'type': 'create_block',
                      'task_key': 'm56-study',
                      'start': '2026-10-13T15:00+08:00',
                      'end': '2026-10-13T16:00+08:00',
                    },
                  ],
                }),
        );
        actionCalls.add(call);
        controller.add(
          ModelCompleted(finishReason: 'tool_calls', toolCalls: [call]),
        );
      } else if (last.role == 'tool') {
        final result = jsonDecode(last.content!) as Map<String, Object?>;
        final status = result['status'];
        controller.add(
          ModelTextDelta(status == 'committed' ? '合成方案已按实际回执完成。' : '合成方案已拒绝。'),
        );
        controller.add(ModelCompleted(finishReason: 'stop'));
      } else {
        controller.addError(
          const AgentFailure(AgentFailureCode.toolUnavailable),
        );
        await controller.close();
        return;
      }
      await controller.close();
      return;
    }
    if (readScenario != null) {
      final last = request.messages.last;
      final oldCall = request.messages
          .where((m) => m.toolCalls.isNotEmpty)
          .lastOrNull
          ?.toolCalls
          .single;
      if (last.role == 'user') {
        final tool = readScenario == 'agenda'
            ? 'query_agenda'
            : 'search_knowledge';
        controller.add(
          ModelCompleted(
            finishReason: 'tool_calls',
            toolCalls: [
              ModelToolCall(
                id: 'synthetic-read-1',
                name: tool,
                argumentsJson: tool == 'query_agenda'
                    ? '{"first_day":"2026-10-13","end_day_exclusive":"2026-10-14"}'
                    : '{"keywords":"缓考","limit":1}',
              ),
            ],
          ),
        );
      } else if (oldCall?.name == 'search_knowledge') {
        final data = (jsonDecode(last.content!) as Map)['data'] as Map;
        final ref = (data['items'] as List).first['material_ref'];
        controller.add(
          ModelCompleted(
            finishReason: 'tool_calls',
            toolCalls: [
              ModelToolCall(
                id: 'synthetic-read-2',
                name: 'read_knowledge',
                argumentsJson: jsonEncode({'material_ref': ref}),
              ),
            ],
          ),
        );
      } else {
        final result = jsonDecode(last.content!) as Map;
        final id = (result['evidence'] as List).first;
        controller.add(ModelTextDelta('合成查询完成 [[$id]]'));
        controller.add(ModelCompleted(finishReason: 'stop'));
        readScenario = null;
      }
      await controller.close();
      return;
    }
    if (request.toolChoice != null) {
      controller.addError(const AgentFailure(AgentFailureCode.toolUnavailable));
      await controller.close();
      return;
    }
    controller.add(const ModelTextDelta('合成流式片段'));
    if (holdNextChat) {
      holdNextChat = false;
      if (!_heldChat.isCompleted) _heldChat.complete();
      return;
    }
    controller.add(const ModelTextDelta('，这是完整的本机合成回答。'));
    controller.add(ModelCompleted(finishReason: 'stop'));
    await controller.close();
  }

  @override
  Future<void> cancelAndDrain() async {
    cancelCount++;
    for (final generation in _generations) {
      if (!generation.isClosed) await generation.close();
    }
  }

  @override
  Future<void> close() async {
    closeCount++;
    await cancelAndDrain();
    if (failNextClose) {
      failNextClose = false;
      throw StateError('synthetic one-shot close failure');
    }
  }
}
