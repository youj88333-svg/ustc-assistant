import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/agent/ustc_model_gateway.dart';
import 'package:ustc_assistant_m0/app/demo_runtime.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/diagnostics_contract.dart';
import 'package:ustc_assistant_m0/core/jw_credentials.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/core/speech_input_contract.dart';
import 'package:ustc_assistant_m0/m0_entry.dart';
import 'package:ustc_assistant_m0/platform/android_directory.dart';
import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';
import 'package:ustc_assistant_m0/platform/runtime_platform_factory.dart';

import 'support/a3_model_fixture.dart';

const _platform = MethodChannel('ustc_assistant/platform_v1');
final _clock = FixedClock(DateTime.utc(2026, 10, 16, 1));
final _query = CalendarQuery(
  firstDay: DateTime.utc(2026, 10, 16),
  endDayExclusive: DateTime.utc(2026, 10, 17),
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final results = <String, Object>{
    'kind': 'android-a3-validation-v1',
    'realDevice': false,
    'realModelVerified': false,
  };
  tearDown(() => binding.reportData = Map<String, Object>.from(results));

  testWidgets(
    'Android Keystore, SSE, planning, approval, receipts and history share the production runtime',
    (tester) async {
      await tester.runAsync(() async {
        final fixture = await _fixture();
        final model = await A3ModelFixture.start();
        RuntimeBootstrap? bootstrap;
        try {
          bootstrap = await _open(fixture, model);
          var runtime = bootstrap.runtime!;
          var agent = runtime.agentCoordinator;
          expect(model.listRequests, 0);
          expect(model.chatRequests, isEmpty);
          await agent.loadModels(
            key: A3ModelFixture.syntheticKey,
            consent: true,
          );
          expect(agent.view.availableModels, ['a3-synthetic-model']);
          await agent.verifyAndSave(
            modelId: 'a3-synthetic-model',
            consent: true,
          );
          expect(agent.view.report.capability, ModelCapability.toolReady);
          expect(agent.view.settings!.keySaved, isTrue);
          expect(agent.view.businessToolsEnabled, isTrue);
          await agent.saveUsePolicy(
            personalContentAllowed: false,
            dailyOperationsAllowed: false,
          );

          final context =
              (await runtime.jwStore.localCalendar.readPlanContext()).$1;
          final seed = await runtime.jwStore.localCalendar.prepare(
            context,
            CreatePersonalEvent(
              PersonalEventDraft(
                title: 'A3合成课程',
                start: DateTime.utc(2026, 10, 16, 6),
                end: DateTime.utc(2026, 10, 16, 7),
                location: 'QA-101',
                note: 'A3默认不出站的个人备注',
              ),
            ),
          );
          await runtime.jwStore.localCalendar.commit(seed);
          model.replies.add(
            (request, body) => A3ModelFixture.tool(request, 'query_agenda', {
              'first_day': '2026-10-16',
              'end_day_exclusive': '2026-10-17',
            }, id: 'a3-read'),
          );
          model.replies.add((request, body) async {
            expect(_lastResult(body)['status'], 'success');
            expect(jsonEncode(_lastResult(body)), contains('A3合成课程'));
            expect(jsonEncode(body), isNot(contains('A3默认不出站的个人备注')));
            await A3ModelFixture.text(
              request,
              '今天下午有一节合成课程。',
              reasoning: 'A7_REASONING_DISPLAY_ONLY',
            );
          });
          await agent.send('今天有什么安排？');
          expect(agent.view.failure, isNull);
          expect(agent.view.messages.last.evidence, isNotEmpty);
          final thinking =
              agent.view.reasoningByMessage[agent.view.messages.last.id]!;
          expect(thinking.text, 'A7_REASONING_DISPLAY_ONLY');
          expect(thinking.active, isFalse);
          final conversation = agent.view.conversationId;

          Map<String, Object?>? proposal;
          model.replies.add((request, body) {
            expect(
              jsonEncode(body),
              isNot(contains('A7_REASONING_DISPLAY_ONLY')),
            );
            return A3ModelFixture.tool(request, 'find_free_slots', {
              'first_day': '2026-10-16',
              'end_day_exclusive': '2026-10-17',
              'block_minutes': 60,
              'start_minute': 780,
              'end_minute': 840,
            }, id: 'a3-free');
          });
          model.replies.add((request, body) async {
            final result = _lastResult(body);
            expect(result['status'], 'success');
            final slots = (result['data'] as Map)['candidates'] as List;
            expect(slots, isNotEmpty);
            proposal = {
              'changes': [
                {
                  'type': 'create_task',
                  'local_key': 'a3-review',
                  'title': 'A3合成复习',
                },
                {
                  'type': 'create_block',
                  'task_key': 'a3-review',
                  'slot_ref': (slots.first as Map)['slot_ref'],
                },
              ],
            };
            await A3ModelFixture.tool(
              request,
              'propose_local_changes',
              proposal!,
              id: 'a3-write',
            );
          });
          Map<String, dynamic>? commitResult;
          model.replies.add((request, body) async {
            commitResult = _lastResult(body);
            // Deliberately fail after the actual C3 commit, before a final model
            // answer, to exercise receipt recovery in a later user turn.
            request.response.statusCode = 503;
            await request.response.close();
          });
          final sending = agent.send('帮我下午一点安排一小时复习，并建一个任务。');
          await _until(() => agent.view.phase == AgentPhase.waitingForApproval);
          final card = agent.view.pendingAction!.id;
          expect(
            (await runtime.jwStore.localCalendar.queryTasks(
              const TaskQuery(),
            )).items,
            isEmpty,
          );
          await agent.send('好的');
          await sending;
          expect(commitResult?['status'], 'committed');
          expect(agent.view.failure, AgentFailureCode.networkFailed);
          expect(agent.view.pendingAction, isNull);
          expect(
            (await runtime.jwStore.localCalendar.queryTasks(
              const TaskQuery(),
            )).items,
            hasLength(1),
          );
          expect(
            (await runtime.jwStore.localCalendar.query(_query)).items,
            hasLength(2),
          );
          await agent.approveAction(card);

          model.replies.add(
            (request, body) => A3ModelFixture.tool(
              request,
              'propose_local_changes',
              proposal!,
              id: 'a3-retry',
            ),
          );
          Map<String, dynamic>? recoveredResult;
          model.replies.add((request, body) async {
            recoveredResult = _lastResult(body);
            await A3ModelFixture.text(request, '刚才已经安排好了，没有重复创建。');
          });
          await agent.send('继续刚才的安排');
          expect(agent.view.failure, isNull);
          expect(recoveredResult?['status'], 'success');
          expect(
            (recoveredResult!['data'] as Map)['historical_receipt'],
            isTrue,
          );
          expect(
            (recoveredResult!['data'] as Map)['submitted_this_run'],
            isFalse,
          );
          expect(
            (await runtime.jwStore.localCalendar.queryTasks(
              const TaskQuery(),
            )).items,
            hasLength(1),
          );
          expect(
            (await runtime.jwStore.localCalendar.query(_query)).items,
            hasLength(2),
          );

          for (final request in model.chatRequests) {
            expect((request['tools'] as List).length, 20);
            _expectPairedHistory(request);
          }
          results['keystoreToolReady'] = true;
          results['twentyTools'] = true;
          results['approvalAndPlanningCommitted'] = true;
          results['failedAnswerReceiptRecoveredWithoutDuplicate'] = true;

          await bootstrap.close();
          bootstrap = null;
          final oldRequestCount = model.chatRequests.length;
          bootstrap = await _open(fixture, model);
          runtime = bootstrap.runtime!;
          agent = runtime.agentCoordinator;
          expect(agent.view.settings!.keySaved, isTrue);
          expect(agent.view.report.capability, ModelCapability.toolReady);
          expect(agent.view.conversationId, conversation);
          expect(model.chatRequests.length, oldRequestCount);
          expect(
            (await runtime.jwStore.localCalendar.queryTasks(
              const TaskQuery(),
            )).items,
            hasLength(1),
          );
          expect(
            (await runtime.jwStore.localCalendar.query(_query)).items,
            hasLength(2),
          );

          // A fresh HTTP request consumes the C3 ciphertext through the actual
          // Keystore, not an in-memory candidate left from verification.
          await agent.send('/compact');
          expect(agent.view.failure, isNull);
          expect(agent.view.contextCompacted, isTrue);
          expect(model.summaryRequests, greaterThan(0));

          // Exercise the Agent adapters against the packaged public texts,
          // rather than only testing the C2/C3 services in isolation.
          expect((await runtime.knowledge.loadBundledEdition()).accepted, 7);
          model.replies.add(
            (request, body) => A3ModelFixture.tool(
              request,
              'search_knowledge',
              {'keywords': '缓考'},
              id: 'a3-knowledge-search',
            ),
          );
          model.replies.add((request, body) async {
            final result = _lastResult(body);
            final items = (result['data'] as Map)['items'] as List;
            expect(items, isNotEmpty);
            await A3ModelFixture.tool(request, 'read_knowledge', {
              'material_ref': (items.first as Map)['material_ref'],
              'max_characters': 1200,
            }, id: 'a3-knowledge-read');
          });
          model.replies.add((request, body) async {
            final result = _lastResult(body);
            expect(['success', 'partial'], contains(result['status']));
            expect((result['data'] as Map)['content'], contains('缓考'));
            expect(
              (result['evidence_metadata'] as List).single['applicability'],
              'unknown',
            );
            await A3ModelFixture.text(request, '查到缓考办事说明了，是否适用还需按当前规定核对。');
          });
          await agent.send('缓考要怎么办？');
          expect(agent.view.failure, isNull);
          expect(agent.view.messages.last.evidence, isNotEmpty);
          results['agentKnowledgeReadWithUnknownApplicability'] = true;
          await agent.send('/clear');
          expect(agent.view.messages, isEmpty);
          expect(agent.view.settings!.keySaved, isTrue);
          expect(
            (await runtime.jwStore.localCalendar.queryTasks(
              const TaskQuery(),
            )).items,
            hasLength(1),
          );
          results['reopenAndCompactClearRetainBusiness'] = true;
          expect(model.unexpectedRequest, isFalse);
          expect(model.replies, isEmpty);
        } finally {
          await bootstrap?.close();
          await model.close();
          await _remove(fixture);
        }
      });
    },
    skip: !Platform.isAndroid,
  );

  testWidgets(
    'Android lifecycle withdraws a streaming request and an unsubmitted approval',
    (tester) async {
      final fixture = await tester.runAsync(_fixture);
      final model = await tester.runAsync(A3ModelFixture.start);
      RuntimeBootstrap? bootstrap;
      final held = Completer<void>();
      try {
        bootstrap = await tester.runAsync(() => _open(fixture!, model!));
        final agent = bootstrap!.runtime!.agentCoordinator;
        await tester.runAsync(
          () => agent.verifyAndSave(
            key: A3ModelFixture.syntheticKey,
            modelId: 'a3-synthetic-model',
            consent: true,
          ),
        );
        await tester.runAsync(
          () => agent.saveUsePolicy(
            personalContentAllowed: false,
            dailyOperationsAllowed: false,
          ),
        );
        // Use the real OwnedApplication lifecycle listener with sufficient
        // canvas; phone layout and keyboard checks belong to A4.
        tester.view.physicalSize = const Size(1200, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        _foreground(tester.binding);
        await tester.pumpWidget(OwnedApplication(bootstrap: bootstrap));
        await tester.pumpAndSettle();
        model!.replies.add((request, body) async {
          request.response.bufferOutput = false;
          request.response.headers.chunkedTransferEncoding = true;
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          request.response.write(
            'data: ${jsonEncode({
              'choices': [
                {
                  'index': 0,
                  'delta': {'content': 'A3合成流式片段'},
                  'finish_reason': null,
                },
              ],
            })}\n\n',
          );
          await request.response.flush();
          await held.future;
        });
        late Future<void> sending;
        await tester.runAsync(() async {
          sending = agent.send('合成后台停止问题');
          await Future.any([
            _until(
              () => agent.view.messages.any((m) => m.text.contains('A3合成流式片段')),
            ),
            sending.then(
              (_) => throw StateError(
                'Synthetic stream ended before its first delta: phase=${agent.view.phase.name}, '
                'failure=${agent.view.failure?.name}, requests=${model.chatRequests.length}, '
                'unexpected=${model.unexpectedRequest}',
              ),
            ),
          ]);
        });
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        expect(agent.view.phase, AgentPhase.generating);
        _background(tester.binding);
        await tester.runAsync(() async {
          await sending.timeout(const Duration(seconds: 20));
          await _until(() => agent.view.phase == AgentPhase.idle);
        });
        expect(agent.view.messages.last.status, AgentMessageStatus.cancelled);
        final count = model.chatRequests.length;
        await tester.runAsync(() => agent.send('后台拒绝新请求'));
        expect(model.chatRequests.length, count);
        _foreground(tester.binding);
        await tester.pump();
        expect(model.chatRequests.length, count);
        held.complete();

        model.replies.add(
          (request, body) =>
              A3ModelFixture.tool(request, 'propose_local_changes', {
                'changes': [
                  {
                    'type': 'create_task',
                    'title': 'A3不能暗中提交',
                    'local_key': 'hidden-task',
                  },
                ],
              }, id: 'a3-hidden-card'),
        );
        await tester.runAsync(() async {
          sending = agent.send('创建合成测试任务');
          await _until(() => agent.view.phase == AgentPhase.waitingForApproval);
        });
        final card = agent.view.pendingAction!.id;
        _background(tester.binding);
        await tester.runAsync(() async {
          await sending.timeout(const Duration(seconds: 20));
          await _until(() => agent.view.phase == AgentPhase.idle);
        });
        _foreground(tester.binding);
        await tester.pump();
        await tester.runAsync(() => agent.approveAction(card));
        final tasks = await tester.runAsync(
          () => bootstrap!.runtime!.jwStore.localCalendar.queryTasks(
            const TaskQuery(),
          ),
        );
        expect(tasks!.items, isEmpty);
        results['backgroundStreamCancelled'] = true;
        results['inactivePreservesWork'] = true;
        results['backgroundApprovalRevoked'] = true;
        results['foregroundDoesNotReplay'] = true;
        expect(model.unexpectedRequest, isFalse);
      } finally {
        if (!held.isCompleted) held.complete();
        _foreground(tester.binding);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await bootstrap?.close();
          await model?.close();
          if (fixture != null) await _remove(fixture);
        });
      }
    },
    skip: !Platform.isAndroid,
  );
}

Map<String, dynamic> _lastResult(Map<String, dynamic> body) =>
    jsonDecode(
          ((body['messages'] as List).lastWhere(
                    (m) => (m as Map)['role'] == 'tool',
                  )
                  as Map)['content']
              as String,
        )
        as Map<String, dynamic>;

// Match the intermediate lifecycle states synthesized for an Android pause.
void _background(WidgetsBinding binding) {
  if (binding.lifecycleState == AppLifecycleState.resumed) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  }
  if (binding.lifecycleState == AppLifecycleState.inactive) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  }
  if (binding.lifecycleState == AppLifecycleState.hidden) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  }
}

void _foreground(WidgetsBinding binding) {
  if (binding.lifecycleState == AppLifecycleState.paused) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  }
  if (binding.lifecycleState == AppLifecycleState.hidden) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  }
  if (binding.lifecycleState != AppLifecycleState.resumed) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }
}

void _expectPairedHistory(Map<String, dynamic> body) {
  final calls = <String>{};
  for (final value in body['messages'] as List) {
    final message = value as Map;
    if (message['role'] == 'assistant') {
      for (final call in (message['tool_calls'] as List? ?? [])) {
        calls.add((call as Map)['id'] as String);
      }
    } else if (message['role'] == 'tool') {
      expect(calls.remove(message['tool_call_id']), isTrue);
    }
  }
  expect(calls, isEmpty);
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('A3 synthetic state transition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<String> _qaRoot() async {
  final root = await _platform.invokeMethod<String>('privateDataRoot');
  if (root == null ||
      !root.contains('/cn.ustcassistant.mobile.qa/') ||
      !root.endsWith('/no_backup/ustc_assistant_v1')) {
    throw StateError('A3 requires the isolated Android QA sandbox');
  }
  return root;
}

Future<Directory> _fixture() async =>
    Directory(await _qaRoot()).createTemp('a3_agent_');
Future<void> _remove(Directory fixture) async {
  if (!p.posix.isWithin(await _qaRoot(), fixture.path) ||
      !p.posix.basename(fixture.path).startsWith('a3_agent_')) {
    throw StateError('Unexpected A3 synthetic fixture');
  }
  await fixture.delete(recursive: true);
}

Future<RuntimeBootstrap> _open(Directory directory, A3ModelFixture model) =>
    RuntimeBootstrap.open(
      platformFactory: _FixturePlatform(directory.path),
      modelGateway: UstcModelGateway.loopbackForTesting(model.baseUri),
      clock: _clock,
    );

final class _FixturePlatform implements RuntimePlatformFactory {
  const _FixturePlatform(this.path);
  final String path;
  static const _delegate = AndroidRuntimePlatformFactory();
  @override
  Future<RuntimeDirectories> acquireDirectories({
    String? directoryPath,
    String? jwDirectoryPath,
  }) async {
    final roots = await AndroidDirectories.acquire(path);
    return RuntimeDirectories(demo: roots.demo, formal: roots.formal);
  }

  @override
  JwCredentialProtector get schoolCredentials => _delegate.schoolCredentials;
  @override
  ModelCredentialProtector get modelCredentials => _delegate.modelCredentials;
  @override
  NativeObservationBrowser createBrowser() => _delegate.createBrowser();
  @override
  NotificationPlatformPort createNotifications() =>
      _delegate.createNotifications();
  @override
  SpeechInputPort createSpeech(DiagnosticsPort diagnostics) =>
      _delegate.createSpeech(diagnostics);
}
