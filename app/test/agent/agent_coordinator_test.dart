import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/agent/agent_coordinator.dart';
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/agent/agent_tool_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/settings_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';

void main() {
  group('AgentCoordinator M5.2 bounded reads', () {
    test(
      'read-session admission failure settles its newly issued C3 run',
      () async {
        final tools = _ReadTools()..failOpen = true;
        final rig = await _rig(configured: true, readTools: tools);
        await rig.coordinator.send('合成日程问题');
        expect(rig.coordinator.view.failure, AgentFailureCode.closed);
        expect(rig.gateway.generations, isEmpty);
        expect(await _activeRun(rig.store), isNull);
        expect(
          rig.coordinator.view.messages.last.status,
          AgentMessageStatus.failed,
        );
      },
    );
    test(
      'ordinary dated class questions expose local agenda while public reviews do not',
      () async {
        final tools = _ReadTools()..catalogue = true;
        final rig = await _rig(configured: true, readTools: tools);
        for (final question in [
          '我明天有哪些课？',
          '明天几点上第一节课？',
          '明天的课程是什么？',
          '下午有什么课？',
        ]) {
          rig.gateway.enqueueEvents([
            const ModelTextDelta('合成路由回答'),
            ModelCompleted(finishReason: 'stop'),
          ]);
          await rig.coordinator.send(question);
          final names = rig.gateway.generations.last.request.tools.map(
            (t) => t.name,
          );
          expect(names, contains('query_agenda'));
          expect(names, isNot(contains('search_courses')));
        }
        await rig.coordinator.newConversation();
        rig.gateway.enqueueEvents([
          const ModelTextDelta('合成课程评价回答'),
          ModelCompleted(finishReason: 'stop'),
        ]);
        await rig.coordinator.send('公开课程评价查询');
        final names = rig.gateway.generations.last.request.tools.map(
          (t) => t.name,
        );
        expect(names, contains('search_courses'));
        expect(names, isNot(contains('query_agenda')));
      },
    );

    test(
      'an explicit public-only request excludes local reads and follow-up scope',
      () async {
        for (final question in ['不要读取我的日程，只查询公开课程评价', '继续说，但只查评课，老师评价怎么样？']) {
          final tools = _ReadTools()..catalogue = true;
          final rig = await _rig(configured: true, readTools: tools);
          rig.gateway.enqueueEvents([
            const ModelTextDelta('合成日程回答'),
            ModelCompleted(finishReason: 'stop'),
          ]);
          await rig.coordinator.send('我明天有哪些课？');
          rig.gateway.enqueueEvents([
            const ModelTextDelta('合成公开回答'),
            ModelCompleted(finishReason: 'stop'),
          ]);
          await rig.coordinator.send(question);
          final names = rig.gateway.generations.last.request.tools.map(
            (t) => t.name,
          );
          expect(names, contains('search_courses'));
          expect(names, isNot(contains('query_agenda')));
        }
      },
    );

    test(
      'storage and cleanup failures end before another model request or tool',
      () async {
        for (final failure in [
          'storageFailed',
          'cleanupPending',
          'cancelled',
          'closed',
        ]) {
          final tools = _ReadTools()..resultFailure = failure;
          final rig = await _rig(configured: true, readTools: tools);
          rig.gateway.enqueueEvents([_readCall('fatal', '{}')]);
          await rig.coordinator.send('故障合成日程问题');
          expect(rig.gateway.generations, hasLength(1));
          expect(tools.executed, 1);
          expect(rig.coordinator.view.failure, isNotNull);
          expect(
            rig.coordinator.view.messages.last.steps.single.status,
            'failure',
          );
          expect(await _activeRun(rig.store), isNull);
        }
      },
    );

    test(
      'journal write failure blocks delivery and preserves empty previous journal',
      () async {
        var failing = false;
        final tools = _ReadTools()
          ..afterExecute = () async {
            failing = true;
          };
        final rig = await _rig(
          configured: true,
          readTools: tools,
          checkpoint: () async {
            if (failing) throw StateError('synthetic journal checkpoint');
          },
        );
        rig.gateway.enqueueEvents([_readCall('sql', '{}')]);
        await rig.coordinator.send('事务合成日程问题');
        expect(rig.gateway.generations, hasLength(1));
        expect(rig.coordinator.view.failure, AgentFailureCode.storageFailed);
        expect(rig.coordinator.view.messages.last.evidence, isEmpty);
        expect(rig.coordinator.view.messages.last.steps, isEmpty);
        expect(await _activeRun(rig.store), isNull);
      },
    );
    test(
      'native calls continue with paired results and durable display evidence',
      () async {
        final tools = _ReadTools();
        final rig = await _rig(configured: true, readTools: tools);
        rig.gateway.enqueueEvents([
          _readCall('read-1', '{"first_day":"2026-10-13"}'),
        ]);
        rig.gateway.enqueue((generation) async {
          final messages = generation.request.messages;
          expect(messages.last.role, 'tool');
          expect(messages.last.toolCallId, 'read-1');
          expect(
            messages[messages.length - 2].toolCalls.single.name,
            'query_agenda',
          );
          final result = jsonDecode(messages.last.content!) as Map;
          expect(result['trust'], 'untrusted_source_data');
          expect(result['status'], 'success');
          expect(result['evidence'], ['e_0123456789abcdef']);
          generation.emit(const ModelTextDelta('查询结果 [[e_0123456789abcdef]]'));
          generation.emit(ModelCompleted(finishReason: 'stop'));
          await generation.finish();
        });
        await rig.coordinator.send('合成日程问题');
        expect(rig.coordinator.view.failure, isNull);
        expect(rig.coordinator.view.businessToolsEnabled, isTrue);
        expect(rig.coordinator.view.modelCalls, 2);
        expect(rig.coordinator.view.toolCalls, 1);
        final messages = rig.coordinator.view.messages;
        expect(messages.last.status, AgentMessageStatus.complete);
        expect(messages.last.evidence.single.title, '合成本地窗口');
        expect(messages.last.steps.single.tool, 'query_agenda');
        expect(tools.executed, 1);
        expect(await _activeRun(rig.store), isNull);
      },
    );

    test(
      'a truncated tool call never executes and unknown names never acquire tools',
      () async {
        for (final completion in [
          ModelCompleted(
            finishReason: 'length',
            toolCalls: const [
              ModelToolCall(
                id: 'half',
                name: 'query_agenda',
                argumentsJson: '{}',
              ),
            ],
          ),
          ModelCompleted(
            finishReason: 'tool_calls',
            toolCalls: const [
              ModelToolCall(
                id: 'unknown',
                name: 'execute_sql',
                argumentsJson: '{}',
              ),
            ],
          ),
        ]) {
          final tools = _ReadTools();
          final rig = await _rig(configured: true, readTools: tools);
          rig.gateway.enqueueEvents([completion]);
          await rig.coordinator.send('只读合成问题');
          expect(
            rig.coordinator.view.failure,
            AgentFailureCode.toolUnavailable,
          );
          expect(tools.executed, 0);
          expect(await _activeRun(rig.store), isNull);
        }
      },
    );

    test(
      'revoking consent after a read prevents delivery and the next model request',
      () async {
        final tools = _ReadTools();
        final rig = await _rig(configured: true, readTools: tools);
        tools.afterExecute = () async {
          final settings = await rig.store.agent.inspectAgent();
          await rig.store.agent.setModelConsent(settings.authority, false);
        };
        rig.gateway.enqueueEvents([_readCall('revoked', '{}')]);
        await rig.coordinator.send('权限撤销合成日程问题');
        expect(rig.gateway.generations, hasLength(1));
        expect(rig.coordinator.view.failure, AgentFailureCode.staleContext);
        expect(rig.coordinator.view.messages.last.text, isEmpty);
        expect(rig.coordinator.view.messages.last.evidence, isEmpty);
        expect(await _activeRun(rig.store), isNull);
      },
    );

    test('reordered identical arguments stop without another read', () async {
      final tools = _ReadTools();
      final rig = await _rig(configured: true, readTools: tools);
      rig.gateway.enqueueEvents([_readCall('first', '{"a":1,"b":2}')]);
      rig.gateway.enqueueEvents([_readCall('repeat', '{"b":2,"a":1}')]);
      await rig.coordinator.send('循环合成日程问题');
      expect(tools.executed, 1);
      expect(rig.gateway.generations, hasLength(2));
      expect(rig.coordinator.view.failure, AgentFailureCode.resourceLimit);
      expect(await _activeRun(rig.store), isNull);
    });

    test(
      'model round budget terminates at eight without new outbound work',
      () async {
        final tools = _ReadTools();
        final rig = await _rig(configured: true, readTools: tools);
        for (var i = 0; i < 9; i++) {
          rig.gateway.enqueueEvents([_readCall('step-$i', '{"page":$i}')]);
        }
        await rig.coordinator.send('预算合成日程问题');
        expect(rig.gateway.generations, hasLength(8));
        expect(tools.executed, 8);
        expect(rig.coordinator.view.failure, AgentFailureCode.resourceLimit);
        expect(rig.coordinator.view.messages.last.steps, hasLength(8));
      },
    );

    test(
      'stop revokes an awaited source result and drains only the owned reader',
      () async {
        final tools = _ReadTools()..hold = Completer<void>();
        final rig = await _rig(configured: true, readTools: tools);
        rig.gateway.enqueueEvents([_readCall('held', '{}')]);
        final send = rig.coordinator.send('等待来源合成日程问题');
        await _until(() => tools.executed == 1);
        expect(rig.coordinator.view.phase, AgentPhase.executingRead);
        await rig.coordinator.stop();
        await send;
        expect(tools.cancelCount, greaterThanOrEqualTo(1));
        expect(rig.gateway.generations, hasLength(1));
        expect(rig.coordinator.view.messages.last.evidence, isEmpty);
        expect(await _activeRun(rig.store), isNull);
        expect(rig.coordinator.view.phase, AgentPhase.idle);
      },
    );

    test(
      'active-time timeout uses resourceLimit and drains its unfinished read',
      () async {
        final tools = _ReadTools()..hold = Completer<void>();
        final rig = await _rig(
          configured: true,
          readTools: tools,
          runTimeout: const Duration(milliseconds: 100),
        );
        rig.gateway.enqueueEvents([_readCall('time', '{}')]);
        await rig.coordinator.send('超时合成日程问题');
        await _until(() => rig.coordinator.view.phase == AgentPhase.idle);
        expect(rig.coordinator.view.failure, AgentFailureCode.resourceLimit);
        expect(await _activeRun(rig.store), isNull);
      },
    );

    test(
      'selected images are sent once, journal stores only count, and old interpretation is not context',
      () async {
        final tools = _ReadTools();
        final rig = await _rig(configured: true, readTools: tools);
        final image = AgentImage(
          Uint8List.fromList(base64Decode(_onePixelPng)),
        );
        rig.gateway.enqueue((generation) async {
          expect(
            generation.request.messages.last.images.single.bytes,
            image.bytes,
          );
          generation.emit(const ModelTextDelta('合成图片旧描述'));
          generation.emit(ModelCompleted(finishReason: 'stop'));
          await generation.finish();
        });
        await rig.coordinator.send('', images: [image]);
        expect(rig.coordinator.view.failure, isNull);
        expect(rig.coordinator.view.messages.first.imageCount, 1);
        expect(rig.coordinator.view.messages.first.text, '请根据本次附图回答。');
        final stored = await rig.store
            .customSelect('SELECT * FROM agent_messages')
            .get();
        expect(
          jsonEncode(stored.map((row) => row.data).toList()),
          isNot(contains(_onePixelPng)),
        );
        expect(
          image.bytes,
          isNot(everyElement(0)),
          reason: 'C4 does not erase the caller-owned preview',
        );
        rig.gateway.enqueue((generation) async {
          expect(
            generation.request.messages.any((m) => m.images.isNotEmpty),
            isFalse,
          );
          expect(
            generation.request.messages.map((m) => m.content).join(),
            isNot(contains('合成图片旧描述')),
          );
          generation.emit(const ModelTextDelta('新的合成回答'));
          generation.emit(ModelCompleted(finishReason: 'stop'));
          await generation.finish();
        });
        await rig.coordinator.send('新的问题');
        expect(rig.coordinator.view.failure, isNull);
      },
    );
  });
  group('AgentCoordinator M5.1', () {
    test(
      'verification requires text, fixed echo call, and returned proof',
      () async {
        final rig = await _rig();
        rig.gateway.enqueueEvents([
          const ModelTextDelta('USTC_TEXT_PROBE'),
          ModelCompleted(finishReason: 'stop'),
        ]);
        rig.gateway.enqueueEvents([
          ModelCompleted(
            finishReason: 'tool_calls',
            toolCalls: [
              ModelToolCall(
                id: 'call_echo_probe',
                name: 'echo_probe',
                argumentsJson: '{"value":"ustc_probe"}',
              ),
            ],
          ),
        ]);
        rig.gateway.enqueue((call) async {
          final result = jsonDecode(call.request.messages.last.content!) as Map;
          final proof = result['proof'] as String;
          call.emit(ModelTextDelta('confirmed:$proof'));
          call.emit(ModelCompleted(finishReason: 'stop'));
          await call.finish();
        });

        await rig.coordinator.verifyAndSave(
          key: 'synthetic-candidate-key',
          modelId: 'synthetic-chat-model',
          consent: true,
        );

        expect(rig.coordinator.view.failure, isNull);
        expect(rig.coordinator.view.pendingKeyProvided, isFalse);
        expect(
          rig.coordinator.view.report.capability,
          ModelCapability.toolReady,
        );
        expect(rig.coordinator.view.report.toolCall, isTrue);
        expect(rig.coordinator.view.report.toolResult, isTrue);
        expect(rig.gateway.listModelCalls, 1);
        expect(rig.gateway.generations, hasLength(3));
        expect(rig.gateway.keyBuffers, everyElement(everyElement(0)));
        expect(
          rig.gateway.consumedKeyTexts,
          everyElement('synthetic-candidate-key'),
        );

        final textProbe = rig.gateway.generations[0].request;
        expect(textProbe.tools, isEmpty);
        expect(textProbe.messages.single.content, contains('USTC_TEXT_PROBE'));
        final callProbe = rig.gateway.generations[1].request;
        expect(callProbe.toolChoice, 'echo_probe');
        expect(callProbe.tools.map((tool) => tool.name), ['echo_probe']);
        expect(callProbe.messages.single.role, 'user');
        final proofProbe = rig.gateway.generations[2].request;
        expect(proofProbe.toolChoice, 'none');
        expect(proofProbe.messages.last.role, 'tool');
        expect(
          jsonDecode(proofProbe.messages.last.content!)['value'],
          'ustc_probe',
        );
        expect(
          rig.coordinator.safeValidationSummary(),
          isNot(contains('synthetic-candidate-key')),
        );

        final saved = await rig.store.agent.inspectAgent();
        expect(saved.keySaved, isTrue);
        expect(saved.modelId, 'synthetic-chat-model');
        expect(saved.modelIds, ['synthetic-chat-model']);
        expect(saved.report.capability, ModelCapability.toolReady);
        final lease = await rig.store.agent.leaseModelKey(saved.authority);
        final bytes = lease.take();
        expect(utf8.decode(bytes), 'synthetic-candidate-key');
        bytes.fillRange(0, bytes.length, 0);
        expect(bytes, everyElement(0));
      },
    );

    test('unsupported echo probe saves only chatOnly capability', () async {
      final rig = await _rig();
      rig.gateway.enqueueEvents([
        const ModelTextDelta('USTC_TEXT_PROBE'),
        ModelCompleted(finishReason: 'stop'),
      ]);
      rig.gateway.enqueueEvents([
        const ModelTextDelta('This model did not call the tool.'),
        ModelCompleted(finishReason: 'stop'),
      ]);

      await rig.coordinator.verifyAndSave(
        key: 'synthetic-candidate-key',
        modelId: 'synthetic-chat-model',
        consent: true,
      );

      expect(rig.coordinator.view.failure, isNull);
      expect(rig.coordinator.view.pendingKeyProvided, isFalse);
      expect(rig.coordinator.view.report.capability, ModelCapability.chatOnly);
      expect(rig.coordinator.view.report.text, isTrue);
      expect(rig.coordinator.view.report.streaming, isTrue);
      expect(rig.coordinator.view.report.toolCall, isFalse);
      expect(rig.coordinator.view.report.toolResult, isFalse);
      expect(rig.coordinator.view.report.failure, AgentFailureCode.protocol);
      expect(rig.gateway.generations, hasLength(2));
      expect(
        (await rig.store.agent.inspectAgent()).report.capability,
        ModelCapability.chatOnly,
      );
    });

    test(
      'authentication failure clears candidate key and preserves old configuration',
      () async {
        final rig = await _rig(
          configured: true,
          modelId: 'old-synthetic-model',
          key: 'synthetic-old-key',
        );
        rig.gateway.listFailure = AgentFailureCode.unauthorized;

        await rig.coordinator.verifyAndSave(
          key: 'synthetic-replacement-key',
          modelId: 'replacement-model',
          consent: true,
        );

        expect(rig.coordinator.view.failure, AgentFailureCode.unauthorized);
        expect(rig.coordinator.view.pendingKeyProvided, isFalse);
        expect(rig.gateway.listModelCalls, 1);
        expect(rig.gateway.generations, isEmpty);
        expect(rig.gateway.keyBuffers, everyElement(everyElement(0)));
        final saved = await rig.store.agent.inspectAgent();
        expect(saved.modelId, 'old-synthetic-model');
        expect(saved.modelIds, ['old-synthetic-model']);
        expect(saved.report.capability, ModelCapability.chatOnly);
        final lease = await rig.store.agent.leaseModelKey(saved.authority);
        final bytes = lease.take();
        expect(utf8.decode(bytes), 'synthetic-old-key');
        bytes.fillRange(0, bytes.length, 0);
      },
    );

    test('complete streaming chat sends only safe completed history', () async {
      final rig = await _rig(configured: true);
      final conversation = await rig.store.agent.createConversation();
      final settings = await rig.store.agent.inspectAgent();
      await _completeRun(
        rig.store,
        settings.authority,
        conversation,
        '旧的安全问题',
        '旧的安全回答',
      );
      final partial = await rig.store.agent.beginRun(
        settings.authority,
        conversation,
        '中断的问题',
      );
      await rig.store.agent.saveAssistant(partial, '必须从上下文排除的部分回答');
      await rig.store.agent.finishRun(partial, AgentMessageStatus.interrupted);
      await rig.coordinator.selectConversation(conversation);
      rig.gateway.enqueueEvents([
        const ModelTextDelta('新的'),
        const ModelTextDelta('回答'),
        ModelCompleted(finishReason: 'stop'),
      ]);

      await rig.coordinator.send('当前安全问题');

      expect(rig.gateway.generations, hasLength(1));
      final request = rig.gateway.generations.single.request;
      final outbound = request.messages
          .map((message) => message.content ?? '')
          .join('\n');
      expect(outbound, contains('旧的安全问题'));
      expect(outbound, contains('旧的安全回答'));
      expect(outbound, contains('当前安全问题'));
      expect(outbound, isNot(contains('必须从上下文排除的部分回答')));
      expect(outbound, isNot(contains('synthetic-chat-key')));
      final messages = await rig.store.agent.messages(conversation);
      expect(messages.last.role, AgentMessageRole.assistant);
      expect(messages.last.status, AgentMessageStatus.complete);
      expect(messages.last.text, '新的回答');
    });

    test(
      'incomplete stream records the partial answer and reports the gateway failure',
      () async {
        final rig = await _rig(configured: true);
        final conversation = await rig.store.agent.createConversation();
        await rig.coordinator.selectConversation(conversation);
        rig.gateway.enqueue((call) async {
          call.emit(const ModelTextDelta('已收到的部分回答'));
          await call.fail(const AgentFailure(AgentFailureCode.rateLimited));
        });

        await rig.coordinator.send('合成问题');

        final messages = await rig.store.agent.messages(conversation);
        expect(messages.last.status, AgentMessageStatus.interrupted);
        expect(messages.last.text, '已收到的部分回答');
        expect(rig.coordinator.view.failure, AgentFailureCode.rateLimited);
        expect(rig.gateway.generations.single.isClosed, isTrue);
      },
    );

    test(
      'recognizable secret input is rejected before it is saved or sent',
      () async {
        final rig = await _rig(configured: true);
        final messagesBefore = await _count(rig.store, 'agent_messages');
        final runsBefore = await _count(rig.store, 'agent_runs');

        await rig.coordinator.send('请使用 Bearer syntheticSecretValue123');

        expect(rig.coordinator.view.failure, AgentFailureCode.secretDetected);
        expect(rig.gateway.requestCount, 0);
        expect(await _count(rig.store, 'agent_messages'), messagesBefore);
        expect(await _count(rig.store, 'agent_runs'), runsBefore);
        expect(rig.coordinator.view.conversations, isEmpty);
      },
    );

    test(
      'missing key and missing consent both block outbound model requests',
      () async {
        final noKey = await _rig();
        await noKey.coordinator.send('无 Key 时的合成问题');
        expect(noKey.coordinator.view.failure, AgentFailureCode.keyRequired);
        expect(noKey.gateway.requestCount, 0);

        final noConsent = await _rig(configured: true);
        await noConsent.store.customStatement(
          'UPDATE agent_config SET consent=0 WHERE singleton=1',
        );
        await noConsent.coordinator.refresh();
        await noConsent.coordinator.send('无同意时的合成问题');
        expect(
          noConsent.coordinator.view.failure,
          AgentFailureCode.consentRequired,
        );
        expect(noConsent.gateway.requestCount, 0);
        expect((await noConsent.store.agent.inspectAgent()).keySaved, isTrue);
      },
    );

    test(
      'stop cancels the active stream, rejects late output, and permits a new run',
      () async {
        final rig = await _rig(configured: true);
        final conversation = await rig.store.agent.createConversation();
        await rig.coordinator.selectConversation(conversation);
        final firstSend = rig.coordinator.send('第一轮问题');
        final first = await rig.gateway.nextGeneration();
        await first.started.future.timeout(const Duration(seconds: 2));
        first.emit(const ModelTextDelta('停止前的部分回答'));
        await _until(
          () => rig.coordinator.view.messages.any(
            (message) => message.text == '停止前的部分回答',
          ),
        );

        await rig.coordinator.stop().timeout(const Duration(seconds: 3));
        await firstSend.timeout(const Duration(seconds: 3));

        expect(first.isClosed, isTrue);
        expect(first.emit(const ModelTextDelta('停止后的迟到回答')), isFalse);
        var messages = await rig.store.agent.messages(conversation);
        expect(messages.last.status, AgentMessageStatus.cancelled);
        expect(messages.last.text, '停止前的部分回答');

        final secondSend = rig.coordinator.send('第二轮问题');
        final second = await rig.gateway.nextGeneration();
        await second.started.future.timeout(const Duration(seconds: 2));
        second.emit(const ModelTextDelta('新的回答'));
        second.emit(ModelCompleted(finishReason: 'stop'));
        await second.finish();
        await secondSend.timeout(const Duration(seconds: 3));

        messages = await rig.store.agent.messages(conversation);
        expect(messages.last.status, AgentMessageStatus.complete);
        expect(messages.last.text, '新的回答');
        expect(rig.coordinator.view.phase, AgentPhase.idle);
        expect(rig.gateway.cancelCount, 1);
      },
    );

    test(
      'stop drains a run whose C3 ticket committed before beginRun returned',
      () async {
        final dataGate = _PausingAgentData();
        final rig = await _rig(configured: true, wrapData: dataGate.attach);
        final conversation = await rig.store.agent.createConversation();
        await rig.coordinator.selectConversation(conversation);
        final beginPause = _Pause();
        dataGate.pauseBeginRun = beginPause;

        final firstSend = rig.coordinator.send('ticket 返回前暂停的问题');
        await beginPause.reached.future.timeout(const Duration(seconds: 2));
        final activeWhileTicketHeld = await _activeRun(rig.store);

        final stopping = rig.coordinator.stop().timeout(
          const Duration(seconds: 3),
        );
        try {
          await dataGate.invalidated.future.timeout(const Duration(seconds: 2));
        } finally {
          beginPause.release();
        }
        await Future.wait([firstSend, stopping]);

        expect(activeWhileTicketHeld, isNotNull);
        expect(await _activeRun(rig.store), isNull);
        expect(rig.gateway.requestCount, 0);
        expect(rig.coordinator.view.phase, AgentPhase.idle);

        rig.gateway.enqueueEvents([
          const ModelTextDelta('停止后重新开始的回答'),
          ModelCompleted(finishReason: 'stop'),
        ]);
        final secondSend = rig.coordinator.send('第二轮问题');
        final generation = await rig.gateway.nextGeneration();
        await generation.started.future.timeout(const Duration(seconds: 2));
        await secondSend.timeout(const Duration(seconds: 3));
        expect(rig.gateway.requestCount, 1);
        expect(await _activeRun(rig.store), isNull);
        expect(
          (await rig.store.agent.messages(conversation)).last.status,
          AgentMessageStatus.complete,
        );
      },
    );

    test(
      'stop invalidates a successful verification paused inside credential protection',
      () async {
        final protector = _SyntheticProtector();
        final dataGate = _PausingAgentData();
        final rig = await _rig(
          configured: true,
          modelId: 'old-synthetic-model',
          key: 'synthetic-old-key',
          protector: protector,
          wrapData: dataGate.attach,
        );
        rig.gateway.models = ['synthetic-chat-model', 'replacement-model'];
        final oldSettings = await rig.store.agent.inspectAgent();
        final oldSecret = await rig.store.agent.leaseModelKey(
          oldSettings.authority,
        );
        final oldBytes = oldSecret.take();
        final oldKey = utf8.decode(oldBytes);
        oldBytes.fillRange(0, oldBytes.length, 0);

        rig.gateway.enqueueEvents([
          const ModelTextDelta('USTC_TEXT_PROBE'),
          ModelCompleted(finishReason: 'stop'),
        ]);
        rig.gateway.enqueueEvents([
          ModelCompleted(
            finishReason: 'tool_calls',
            toolCalls: [
              ModelToolCall(
                id: 'call_echo_probe',
                name: 'echo_probe',
                argumentsJson: '{"value":"ustc_probe"}',
              ),
            ],
          ),
        ]);
        rig.gateway.enqueue((call) async {
          final result = jsonDecode(call.request.messages.last.content!) as Map;
          call.emit(ModelTextDelta('confirmed:${result['proof']}'));
          call.emit(ModelCompleted(finishReason: 'stop'));
          await call.finish();
        });
        final protectPause = _Pause();
        protector.pauseNextProtect = protectPause;

        final verification = rig.coordinator.verifyAndSave(
          key: 'synthetic-replacement-key',
          modelId: 'replacement-model',
          consent: true,
        );
        await protectPause.reached.future.timeout(const Duration(seconds: 3));

        final stopping = rig.coordinator.stop().timeout(
          const Duration(seconds: 3),
        );
        AgentSettingsSnapshot invalidated;
        try {
          await dataGate.invalidated.future.timeout(const Duration(seconds: 2));
          invalidated = await rig.store.agent.inspectAgent();
        } finally {
          protectPause.release();
        }
        await Future.wait([verification, stopping]);

        expect(dataGate.savedConfigurationModelId, 'replacement-model');
        expect(
          dataGate.savedConfigurationReport?.capability,
          ModelCapability.toolReady,
        );
        expect(
          invalidated.authority.requestEpoch,
          greaterThan(oldSettings.authority.requestEpoch),
        );

        final after = await rig.store.agent.inspectAgent();
        expect(
          after.authority.configRevision,
          oldSettings.authority.configRevision,
        );
        expect(
          after.authority.requestEpoch,
          invalidated.authority.requestEpoch,
        );
        expect(after.modelId, 'old-synthetic-model');
        expect(after.modelIds, ['old-synthetic-model']);
        expect(after.report.capability, ModelCapability.chatOnly);
        expect(after.report.failure, isNull);
        expect(after.consent, isTrue);
        final retainedLease = await rig.store.agent.leaseModelKey(
          after.authority,
        );
        final retainedBytes = retainedLease.take();
        expect(utf8.decode(retainedBytes), oldKey);
        retainedBytes.fillRange(0, retainedBytes.length, 0);
        expect(rig.coordinator.view.pendingKeyProvided, isFalse);
        expect(rig.gateway.generations, hasLength(3));
        expect(rig.gateway.keyBuffers, everyElement(everyElement(0)));
      },
    );

    test(
      'stop revokes a key lease paused before it can reach the gateway',
      () async {
        final dataGate = _PausingAgentData();
        final rig = await _rig(configured: true, wrapData: dataGate.attach);
        final conversation = await rig.store.agent.createConversation();
        await rig.coordinator.selectConversation(conversation);
        final leasePause = _Pause();
        dataGate.pauseLease = leasePause;

        final sending = rig.coordinator.send('租约返回前暂停的问题');
        await leasePause.reached.future.timeout(const Duration(seconds: 2));
        final pausedLease = dataGate.pausedLease;
        final leaseWasAvailable = pausedLease?.isAvailable;

        final stopping = rig.coordinator.stop().timeout(
          const Duration(seconds: 3),
        );
        try {
          await dataGate.invalidated.future.timeout(const Duration(seconds: 2));
        } finally {
          leasePause.release();
        }
        await Future.wait([sending, stopping]);

        expect(leaseWasAvailable, isTrue);
        expect(pausedLease, isNotNull);
        final secret = pausedLease!;
        expect(rig.gateway.requestCount, 0);
        expect(secret.isAvailable, isFalse);
        expect(
          () => secret.take(),
          throwsA(
            isA<AgentFailure>().having(
              (failure) => failure.code,
              'code',
              AgentFailureCode.keyRequired,
            ),
          ),
        );
        expect(await _activeRun(rig.store), isNull);
        expect(
          (await rig.store.agent.messages(conversation)).last.status,
          AgentMessageStatus.cancelled,
        );
      },
    );

    test(
      'clear history persists intent, drains the model, and cannot revive its old output',
      () async {
        final rig = await _rig(configured: true);
        final conversation = await rig.store.agent.createConversation();
        await rig.coordinator.selectConversation(conversation);
        final send = rig.coordinator.send('清理历史前的问题');
        final generation = await rig.gateway.nextGeneration();
        await generation.started.future.timeout(const Duration(seconds: 2));
        generation.emit(const ModelTextDelta('清理前的部分回答'));
        await _until(
          () => rig.coordinator.view.messages.any(
            (message) => message.text == '清理前的部分回答',
          ),
        );

        await rig.coordinator
            .clearHistory(confirmed: true)
            .timeout(const Duration(seconds: 3));
        await send.timeout(const Duration(seconds: 3));

        expect(generation.isClosed, isTrue);
        expect(generation.emit(const ModelTextDelta('清理后的迟到内容')), isFalse);
        expect(await rig.store.agent.conversations(), isEmpty);
        expect(await rig.store.agent.messages(conversation), isEmpty);
        expect(rig.coordinator.view.messages, isEmpty);
        expect(rig.coordinator.view.conversationId, isNull);
      },
    );

    test(
      'persistent C3 maintenance intent can quiesce the Agent channel without read deadlock',
      () async {
        final rig = await _rig(configured: true);
        final conversation = await rig.store.agent.createConversation();
        await rig.coordinator.selectConversation(conversation);
        final send = rig.coordinator.send('维护前的问题');
        final generation = await rig.gateway.nextGeneration();
        await generation.started.future.timeout(const Duration(seconds: 2));
        generation.emit(const ModelTextDelta('维护前的部分回答'));
        await _until(
          () => rig.coordinator.view.messages.any(
            (message) => message.text == '维护前的部分回答',
          ),
        );

        final settings = await rig.store.applicationSettings.inspectSettings();
        final request = await rig.store.applicationSettings.prepareMaintenance(
          settings.context,
          MaintenanceKind.agenda,
          confirmed: true,
        );
        final intent = await rig.store.applicationSettings.beginMaintenance(
          request,
        );
        await expectLater(
          rig.store.agent.inspectAgent(),
          throwsA(
            isA<AgentFailure>().having(
              (failure) => failure.code,
              'code',
              AgentFailureCode.maintenance,
            ),
          ),
        );

        await rig.coordinator.quiesceForMaintenance().timeout(
          const Duration(seconds: 3),
        );
        await send.timeout(const Duration(seconds: 3));
        expect(generation.isClosed, isTrue);
        expect(rig.coordinator.view.phase, AgentPhase.maintenance);
        await rig.store.applicationSettings.completeMaintenance(intent);
        await rig.coordinator.refreshAfterMaintenance();

        final retained = await rig.store.agent.inspectAgent();
        expect(retained.keySaved, isTrue);
        expect(retained.modelId, 'synthetic-chat-model');
        expect((await rig.store.agent.conversations()).map((item) => item.id), [
          conversation,
        ]);
        expect(rig.coordinator.view.phase, AgentPhase.idle);
        expect(rig.gateway.cancelCount, 1);
      },
    );
  });
}

const _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZgdwAAAAASUVORK5CYII=';

ModelCompleted _readCall(String id, String args) => ModelCompleted(
  finishReason: 'tool_calls',
  toolCalls: [ModelToolCall(id: id, name: 'query_agenda', argumentsJson: args)],
);

final class _ReadTools implements AgentReadToolsPort {
  int executed = 0, cancelCount = 0;
  Completer<void>? hold;
  Future<void> Function()? afterExecute;
  bool catalogue = false;
  bool failOpen = false;
  String? resultFailure;
  @override
  List<ModelToolDefinition> get definitions => [
    ModelToolDefinition(
      name: 'query_agenda',
      description: '合成只读',
      parameters: const {'type': 'object'},
    ),
    if (catalogue)
      ModelToolDefinition(
        name: 'search_courses',
        description: '合成评课',
        parameters: const {'type': 'object'},
      ),
  ];
  @override
  AgentToolSession openSession() {
    if (failOpen) throw const AgentFailure(AgentFailureCode.closed);
    return _ReadSession(this);
  }

  @override
  Future<void> cancelAndDrain() async {
    cancelCount++;
    if (hold?.isCompleted == false) hold!.complete();
  }

  @override
  Future<void> close() => cancelAndDrain();
}

final class _ReadSession implements AgentToolSession {
  _ReadSession(this.parent);
  final _ReadTools parent;
  bool revoked = false;
  List<AgentEvidence> _evidence = [];
  @override
  List<AgentEvidence> get evidence => List.unmodifiable(_evidence);
  @override
  Future<AgentToolResult> execute(ModelToolCall call) async {
    parent.executed++;
    await parent.hold?.future;
    if (revoked) throw const AgentFailure(AgentFailureCode.cancelled);
    await parent.afterExecute?.call();
    if (parent.resultFailure != null) {
      return AgentToolResult(status: 'failure', failure: parent.resultFailure);
    }
    _evidence = [
      AgentEvidence(
        id: 'e_0123456789abcdef',
        provider: 'local',
        title: '合成本地窗口',
        observedAtUtc: DateTime.utc(2026, 10, 13),
        scope: 'selectedWindow',
        complete: true,
      ),
    ];
    return AgentToolResult(
      status: 'success',
      data: const {'count': 1},
      evidenceIds: const ['e_0123456789abcdef'],
    );
  }

  @override
  Future<void> validateDelivery() async {
    if (revoked) throw const AgentFailure(AgentFailureCode.cancelled);
  }

  @override
  void revoke() {
    revoked = true;
  }
}

Future<_Rig> _rig({
  bool configured = false,
  String modelId = 'synthetic-chat-model',
  String key = 'synthetic-chat-key',
  _SyntheticProtector? protector,
  AgentDataPort Function(AgentDataPort data)? wrapData,
  AgentReadToolsPort? readTools,
  Duration runTimeout = const Duration(seconds: 180),
  Future<void> Function()? checkpoint,
}) async {
  final credentialProtector = protector ?? _SyntheticProtector();
  final store = JwStore(
    NativeDatabase.memory(),
    ownership: _TestOwnership(),
    clock: FixedClock(DateTime.utc(2026, 10, 13, 8)),
    modelCredentialProtector: credentialProtector,
    onAgentCheckpoint: checkpoint,
  );
  addTearDown(store.close);
  await store.initialize();
  await store.agent.initializeAgent();
  if (configured) {
    final settings = await store.agent.inspectAgent();
    await store.agent.saveModelConfiguration(
      settings.authority,
      modelId: modelId,
      modelIds: [modelId],
      report: AgentCapabilityReport(
        text: true,
        streaming: true,
        toolCall: readTools != null,
        toolResult: readTools != null,
      ),
      consent: true,
      key: Uint8List.fromList(utf8.encode(key)),
    );
  }
  final gateway = _SyntheticGateway();
  final coordinator = AgentCoordinator(
    data: wrapData?.call(store.agent) ?? store.agent,
    gateway: gateway,
    readTools: readTools,
    runTimeout: runTimeout,
    clock: FixedClock(DateTime.utc(2026, 10, 13, 8)),
  );
  addTearDown(coordinator.close);
  await coordinator.initialize();
  return _Rig(store, gateway, coordinator, credentialProtector);
}

Future<void> _completeRun(
  JwStore store,
  AgentAuthority authority,
  String conversationId,
  String question,
  String answer,
) async {
  final ticket = await store.agent.beginRun(
    authority,
    conversationId,
    question,
  );
  await store.agent.saveAssistant(ticket, answer);
  await store.agent.finishRun(ticket, AgentMessageStatus.complete);
}

Future<int> _count(JwStore store, String table) async =>
    (await store.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
        .read<int>('n');

Future<String?> _activeRun(JwStore store) async =>
    (await store.customSelect('SELECT active_run FROM agent_state').getSingle())
        .read<String?>('active_run');

Future<void> _until(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) {
      throw TimeoutException('Expected coordinator state was not reached.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

final class _Rig {
  const _Rig(this.store, this.gateway, this.coordinator, this.protector);
  final JwStore store;
  final _SyntheticGateway gateway;
  final AgentCoordinator coordinator;
  final _SyntheticProtector protector;
}

final class _Pause {
  final Completer<void> reached = Completer<void>();
  final Completer<void> _release = Completer<void>();

  Future<void> wait() async {
    if (!reached.isCompleted) reached.complete();
    await _release.future;
  }

  void release() {
    if (!_release.isCompleted) _release.complete();
  }
}

final class _PausingAgentData implements AgentDataPort {
  AgentDataPort? _delegate;
  _Pause? pauseBeginRun;
  _Pause? pauseLease;
  ModelSecretLease? pausedLease;
  AgentCapabilityReport? savedConfigurationReport;
  String? savedConfigurationModelId;
  final Completer<void> invalidated = Completer<void>();

  AgentDataPort attach(AgentDataPort delegate) {
    _delegate = delegate;
    return this;
  }

  AgentDataPort get _inner => _delegate!;

  @override
  Stream<int> get changes => _inner.changes;

  @override
  Future<void> initializeAgent() => _inner.initializeAgent();

  @override
  Future<AgentSettingsSnapshot> inspectAgent() => _inner.inspectAgent();

  @override
  Future<void> saveModelConfiguration(
    AgentAuthority expected, {
    required String modelId,
    required List<String> modelIds,
    required AgentCapabilityReport report,
    required bool consent,
    Uint8List? key,
  }) => _inner.saveModelConfiguration(
    expected,
    modelId: modelId,
    modelIds: modelIds,
    report: _captureConfiguration(modelId, report),
    consent: consent,
    key: key,
  );

  AgentCapabilityReport _captureConfiguration(
    String modelId,
    AgentCapabilityReport report,
  ) {
    savedConfigurationModelId = modelId;
    savedConfigurationReport = report;
    return report;
  }

  @override
  Future<ModelSecretLease> leaseModelKey(AgentAuthority expected) async {
    final secret = await _inner.leaseModelKey(expected);
    final pause = pauseLease;
    if (pause != null) {
      pauseLease = null;
      pausedLease = secret;
      await pause.wait();
    }
    return secret;
  }

  @override
  Future<void> invalidateModelWork(AgentAuthority expected) async {
    await _inner.invalidateModelWork(expected);
    if (!invalidated.isCompleted) invalidated.complete();
  }

  @override
  Future<void> deleteModelKey(AgentAuthority expected) =>
      _inner.deleteModelKey(expected);

  @override
  Future<void> setModelConsent(AgentAuthority expected, bool consent) =>
      _inner.setModelConsent(expected, consent);

  @override
  Future<List<AgentConversation>> conversations() => _inner.conversations();

  @override
  Future<String> createConversation() => _inner.createConversation();

  @override
  Future<List<AgentMessage>> messages(String conversationId) =>
      _inner.messages(conversationId);

  @override
  Future<AgentRunTicket> beginRun(
    AgentAuthority expected,
    String conversationId,
    String text,
  ) async {
    final ticket = await _inner.beginRun(expected, conversationId, text);
    final pause = pauseBeginRun;
    if (pause != null) {
      pauseBeginRun = null;
      await pause.wait();
    }
    return ticket;
  }

  @override
  Future<void> saveAssistant(AgentRunTicket ticket, String text) =>
      _inner.saveAssistant(ticket, text);

  @override
  Future<void> finishRun(AgentRunTicket ticket, AgentMessageStatus status) =>
      _inner.finishRun(ticket, status);

  @override
  Future<void> cancelRun(AgentRunTicket ticket) => _inner.cancelRun(ticket);

  @override
  Future<AgentHistoryIntent> beginClearHistory(
    AgentAuthority expected, {
    String? conversationId,
  }) => _inner.beginClearHistory(expected, conversationId: conversationId);

  @override
  Future<void> completeClearHistory(AgentHistoryIntent intent) =>
      _inner.completeClearHistory(intent);
}

final class _SyntheticGateway implements ModelGatewayPort {
  final Queue<Future<void> Function(_SyntheticGeneration)> _scripts = Queue();
  final List<_SyntheticGeneration> generations = [];
  final List<Uint8List> keyBuffers = [];
  final List<String> consumedKeyTexts = [];
  final List<Completer<_SyntheticGeneration>> _waiters = [];
  final List<_SyntheticGeneration> _pendingGenerations = [];
  List<String> models = const ['synthetic-chat-model'];
  AgentFailureCode? listFailure;
  int listModelCalls = 0;
  int requestCount = 0;
  int cancelCount = 0;
  bool _closed = false;

  void enqueueEvents(List<ModelEvent> events) {
    enqueue((call) async {
      for (final event in events) {
        if (!call.emit(event)) return;
      }
      await call.finish();
    });
  }

  void enqueue(Future<void> Function(_SyntheticGeneration) script) {
    _scripts.add(script);
  }

  Future<_SyntheticGeneration> nextGeneration() {
    if (_pendingGenerations.isNotEmpty) {
      return Future<_SyntheticGeneration>.value(
        _pendingGenerations.removeAt(0),
      );
    }
    final waiter = Completer<_SyntheticGeneration>();
    _waiters.add(waiter);
    return waiter.future;
  }

  @override
  Future<List<String>> listModels(ModelSecretLease secret) async {
    requestCount++;
    listModelCalls++;
    _consume(secret);
    final failure = listFailure;
    if (failure != null) throw AgentFailure(failure);
    return models;
  }

  @override
  Stream<ModelEvent> generate(ModelRequest request, ModelSecretLease secret) {
    requestCount++;
    _consume(secret);
    if (_closed) {
      return Stream<ModelEvent>.error(
        const AgentFailure(AgentFailureCode.closed),
      );
    }
    final generation = _SyntheticGeneration(request);
    generations.add(generation);
    if (_waiters.isEmpty) {
      _pendingGenerations.add(generation);
    } else {
      _waiters.removeAt(0).complete(generation);
    }
    if (_scripts.isNotEmpty) {
      final script = _scripts.removeFirst();
      unawaited(_play(generation, script));
    }
    return generation.stream;
  }

  void _consume(ModelSecretLease secret) {
    final bytes = secret.take();
    keyBuffers.add(bytes);
    consumedKeyTexts.add(utf8.decode(bytes));
    bytes.fillRange(0, bytes.length, 0);
  }

  Future<void> _play(
    _SyntheticGeneration generation,
    Future<void> Function(_SyntheticGeneration) script,
  ) async {
    try {
      await generation.started.future;
      await script(generation);
    } on Object catch (error, stack) {
      if (!generation.isClosed) {
        await generation.fail(error, stackTrace: stack);
      }
    }
  }

  @override
  Future<void> cancelAndDrain() async {
    cancelCount++;
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
    for (final waiter in _waiters) {
      if (!waiter.isCompleted) {
        waiter.completeError(const AgentFailure(AgentFailureCode.closed));
      }
    }
    _waiters.clear();
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
  late final StreamController<ModelEvent> controller;
  Future<void>? _finish;
  Stream<ModelEvent> get stream => controller.stream;
  bool get isClosed => controller.isClosed;

  bool emit(ModelEvent event) {
    if (controller.isClosed) return false;
    controller.add(event);
    return true;
  }

  Future<bool> fail(Object error, {StackTrace? stackTrace}) async {
    if (controller.isClosed) return false;
    controller.addError(error, stackTrace);
    await finish();
    return true;
  }

  Future<void> finish() => _finish ??= controller.close();
}

final class _SyntheticProtector implements ModelCredentialProtector {
  _Pause? pauseNextProtect;

  @override
  String get mechanism => 'synthetic-dpapi/v1';

  @override
  Future<Uint8List> protect(
    Uint8List plaintext, {
    required String purpose,
  }) async {
    final pause = pauseNextProtect;
    if (pause != null) {
      pauseNextProtect = null;
      await pause.wait();
    }
    return Uint8List.fromList([0xA7, ...plaintext.map((byte) => byte ^ 0x5A)]);
  }

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
