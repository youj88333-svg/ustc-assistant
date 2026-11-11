// I4 / 07-12, 09 K-08/K-09: run only on a fresh job-owned Simulator.
// Native ownership, SQLite, Keychain, UserNotifications and PHPicker are real.
// Model HTTP/SSE and all business values are synthetic and stay on loopback.
// Fixed native lifecycle injection is consumer evidence, not physical background
// or human Photos selection evidence. No school browser is opened by this test.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/agent/ustc_model_gateway.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_page.dart';
import 'package:ustc_assistant_m0/app/calendar_workspace_contract.dart';
import 'package:ustc_assistant_m0/app/calendar_workspace_page.dart';
import 'package:ustc_assistant_m0/app/demo_runtime.dart';
import 'package:ustc_assistant_m0/app/diagnostics_panel.dart';
import 'package:ustc_assistant_m0/app/m0_app.dart';
import 'package:ustc_assistant_m0/app/onboarding_page.dart';
import 'package:ustc_assistant_m0/app/task_workspace_page.dart';
import 'package:ustc_assistant_m0/core/agenda_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/agent_context_contract.dart';
import 'package:ustc_assistant_m0/core/agent_conversation_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/ios_i4_entry.dart';
import 'package:ustc_assistant_m0/platform/agent_image_picker.dart';
import 'package:ustc_assistant_m0/platform/ios_agent_image_picker.dart';
import 'package:ustc_assistant_m0/platform/ios_runtime_platform_factory.dart';

const _platform = MethodChannel('ustc_assistant/platform_v1');
const _images = MethodChannel('ustc_assistant/images_v1');
const _notifications = MethodChannel('ustc_assistant/ios_notifications_v1');
const _operationTimeout = Duration(seconds: 40);
const _key = 'i4-synthetic-loopback-key';
const _model = 'i4-synthetic-model';
const _reasoning = 'I4_TRANSIENT_REASONING_ONLY';
const _eventTitle = 'I4 合成日程';
const _seedTaskTitle = 'I4 合成已有任务';
const _approvedTaskTitle = 'I4 已批准任务';
const _newerTaskTitle = 'I4 本地较新版本';
const _fixedTools = {
  'query_agenda',
  'read_event',
  'query_tasks',
  'read_task',
  'inspect_conflicts',
  'search_knowledge',
  'read_knowledge',
  'search_courses',
  'read_course',
  'read_reviews',
  'browse_campus',
  'read_campus_article',
  'propose_local_changes',
  'propose_undo',
  'find_free_slots',
  'propose_planning_preferences',
  'query_source_options',
  'request_source_refresh',
  'query_young_activities',
  'query_reminders',
};

/// Independently check the native journey's actual HTTP fixture on the host.
/// This does not exercise UIKit, credentials, or the product activity gate.
@visibleForTesting
Future<void> checkIOSI4LoopbackDirectoryForTesting() async {
  final service = _LoopbackService();
  await service.start();
  final http = _LoopbackOnlyHttpOverrides(service.baseUri);
  final gateway = UstcModelGateway.loopbackForTesting(service.baseUri);
  try {
    final models = await HttpOverrides.runWithHttpOverrides(
      () => gateway.listModels(
        ModelSecretLease(Uint8List.fromList(utf8.encode(_key))),
      ),
      http,
    ).timeout(const Duration(seconds: 10));
    expectSync(models, [_model]);
    expectSync(service.modelRequests, 1);
    expectSync(service.failures, isEmpty);
    expectSync(http.socketCreations, 1);
    expectSync(http.deniedConnections, 0);
  } on Object {
    debugPrint(
      'I4 fixture failure facts: ${jsonEncode({'serverFailureTypes': service.failures, 'serverFailureStage': service.failureStage, 'serverAuthorizationMatches': service.authorizationMatches, 'serverModelsRoute': service.modelsRoute, 'directoryRequests': service.modelRequests, 'socketCreations': http.socketCreations, 'deniedConnections': http.deniedConnections})}',
    );
    rethrow;
  } finally {
    await gateway.close();
    await service.close();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'I4 native product, loopback tools, current approval and picker cancellation',
    (tester) async {
      expect(Platform.isIOS, isTrue);
      expect(kDebugMode, isTrue);
      final storage = await _platform
          .invokeMapMethod<String, Object?>('storageProtectionStatus')
          .timeout(_operationTimeout);
      expect(storage?['isSimulator'], isTrue);
      final metadata = await _platform
          .invokeMapMethod<String, Object?>('i4BuildInfo')
          .timeout(_operationTimeout);
      expect(metadata?.keys.toSet(), {
        'revision',
        'bundleId',
        'version',
        'buildNumber',
        'authentication',
        'notificationBackend',
        'imagePicker',
      });
      expect(
        metadata?['revision'],
        const String.fromEnvironment('USTC_BUILD_REVISION'),
      );
      expect(metadata?['bundleId'], 'cn.ustcassistant.ios.private');
      expect(metadata?['authentication'], 'manual');
      expect(metadata?['notificationBackend'], 'user-notifications-v1');
      expect(metadata?['imagePicker'], 'photosui-imageio-v1');
      await checkIOSI4LoopbackDirectoryForTesting();
      debugPrint('I4 native loopback fixture: real gateway directory accepted');

      final previousHttpOverrides = HttpOverrides.current;
      final service = _LoopbackService();
      final morning = _NoNetworkMorningGateway();
      RuntimeBootstrap? bootstrap;
      var openCount = 0;
      var startupStage = 'entryMetadata';
      String? startupFailure;
      final captureKey = GlobalKey();
      final inputWasRegistered = binding.testTextInput.isRegistered;
      final ratio = tester.view.devicePixelRatio;
      tester.view.physicalSize = Size(393 * ratio, 852 * ratio);
      tester.platformDispatcher.textScaleFactorTestValue = 1;
      try {
        // This journey injects text and keyboard insets; it does not claim
        // physical iOS keyboard evidence. Avoid racing that injected text
        // with a second, real platform IME connection in IntegrationTest.
        binding.testTextInput.register();
        await tester.runAsync(service.start);
        final http = _LoopbackOnlyHttpOverrides(service.baseUri);
        HttpOverrides.global = http;
        await tester.pumpWidget(
          RepaintBoundary(
            key: captureKey,
            child: IOSI4App(
              openBootstrap: (factory) async {
                openCount++;
                startupStage = 'opening';
                late final RuntimeBootstrap opened;
                try {
                  opened = await HttpOverrides.runWithHttpOverrides(
                    () => RuntimeBootstrap.open(
                      platformFactory: IOSRuntimePlatformFactory(
                        onStartupStage: (stage) => startupStage = stage,
                      ),
                      modelGateway: UstcModelGateway.loopbackForTesting(
                        service.baseUri,
                        connectTimeout: const Duration(seconds: 5),
                        requestTimeout: const Duration(seconds: 35),
                        idleTimeout: const Duration(seconds: 25),
                      ),
                      morningGateway: morning,
                      diagnosticApplicationVersion: '0.4.0',
                    ),
                    http,
                  ).timeout(_operationTimeout);
                } on AppFailure catch (error) {
                  startupFailure = error.code.name;
                  rethrow;
                } on Object {
                  startupFailure = 'unexpected';
                  rethrow;
                }
                bootstrap = opened;
                startupStage = 'checkingFreshStore';
                expectSync(opened.directory.isHeld, isTrue);
                expectSync(opened.jwDirectory.isHeld, isTrue);
                final runtime = opened.runtime!;
                expectSync(runtime.agent.view.settings!.keySaved, isFalse);
                expectSync(
                  (await runtime.jwStore.localCalendar.queryTasks(
                    const TaskQuery(filter: TaskFilter.all),
                  )).items,
                  isEmpty,
                );
                expectSync(runtime.agent.view.messages, isEmpty);
                await _seedBusiness(
                  runtime,
                  onStage: (stage) => startupStage = stage,
                );
                startupStage = 'ready';
                return opened;
              },
            ),
          ),
        );
        try {
          await _pumpUntil(
            tester,
            () =>
                find.byType(AgentWorkspacePage).evaluate().isNotEmpty ||
                find.byType(M0StartupFailureApp).evaluate().isNotEmpty,
            reason: 'validated I4 entry must open the actual product Agent',
          );
          expect(find.byType(AgentWorkspacePage), findsOneWidget);
        } on Object {
          final failures = find.byType(M0StartupFailureApp);
          final facts = {
            'stage': startupStage,
            'failure': startupFailure,
            'entryFailure': failures.evaluate().isEmpty
                ? null
                : tester.widget<M0StartupFailureApp>(failures).code.name,
            'openCount': openCount,
            'bootstrapOpened': bootstrap != null,
            'runtimePresent': bootstrap?.runtime != null,
            'maintenancePhase':
                bootstrap?.settings.settingsView.maintenance.phase.name,
            'maintenanceFailure':
                bootstrap?.settings.settingsView.maintenance.failure?.name,
            'nativeHost': await _platform.invokeMethod<String>(
              'i4HostFixtureInspect',
            ),
          };
          debugPrint('I4 startup failure facts: ${jsonEncode(facts)}');
          rethrow;
        }
        final opened = bootstrap!;
        final runtime = opened.runtime!;
        expect(openCount, 1);
        expect(find.byType(OnboardingPage), findsNothing);
        expect(find.byType(NavigationDestination), findsNWidgets(2));
        expect(
          find.byKey(const ValueKey('shell-phone-navigation')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('agent-speech-toggle')), findsNothing);
        expect(find.byIcon(Icons.mic_none_rounded), findsNothing);
        expect(find.byType(DiagnosticsExportButton), findsNothing);
        expect(find.byKey(const ValueKey('agent-page-title')), findsNothing);
        expect(service.bodies, isEmpty);
        debugPrint('I4 native product: one fresh owned product runtime opened');

        await _configureFromProduct(tester, runtime, service, http);
        expect(service.modelRequests, 2);
        expect(service.probeProof, startsWith('ustc-result-'));
        expect(service.probeResultBody, isNotNull);
        final probe = service.probeResultBody!;
        final probeResult = _lastToolResult(probe, 'i4:probe');
        expect(probeResult['value'], 'ustc_probe');
        expect(probeResult['proof'], service.probeProof);
        expect(runtime.agent.view.report.capability, ModelCapability.toolReady);
        expect(
          (await tester.runAsync(runtime.jwStore.agent.inspectAgent))!.keySaved,
          isTrue,
        );
        expect(runtime.agent.view.conversations, hasLength(1));
        // Keep this bounded, deliberately long acceptance conversation away
        // from automatic compaction. The explicit compact operation below
        // still travels through the actual model gateway and C3 summary port.
        await tester.runAsync(
          () => runtime.agent.saveContextOptions(
            const AgentContextOptions(
              inputTokens: 65536,
              outputTokens: 2048,
              modelCalls: 8,
              toolCalls: 20,
              activeSeconds: 120,
            ),
          ),
        );
        debugPrint(
          'I4 native product: native Keychain and loopback probes verified',
        );

        // Observe a genuinely incomplete SSE response through the product.
        // Reasoning uses the provider's explicit field, never content heuristics.
        final streaming = service.enqueueHeld(
          text: 'I4 合成流式正文',
          reasoning: _reasoning,
          tail: '，已完成。',
        );
        await _sendFromProduct(tester, '只测试合成流式正文');
        await _pumpUntil(
          tester,
          () => runtime.agent.view.reasoningByMessage.values.any(
            (v) => v.text == _reasoning,
          ),
          reason: 'explicit provider reasoning must appear while SSE is open',
        );
        expect(runtime.agent.view.phase, AgentPhase.generating);
        expect(
          find.byKey(const ValueKey('agent-stop')).hitTestable(),
          findsOneWidget,
        );
        expect(find.textContaining('I4 合成流式正文'), findsWidgets);
        await tester.runAsync(streaming.finish);
        await _waitIdle(tester, runtime);
        expect(runtime.agent.view.messages.last.text, 'I4 合成流式正文，已完成。');
        expect(
          runtime.agent.view.messages.last.status,
          AgentMessageStatus.complete,
        );
        final persisted = await tester.runAsync(
          () => runtime.jwStore.agent.messages(
            runtime.agent.view.conversationId!,
          ),
        );
        expect(
          persisted!.map((message) => message.text).join(),
          isNot(contains(_reasoning)),
        );
        await _saveScreen(tester, captureKey, runtime, 'i4-agent.png');

        // These result checks are against actual HTTP tool-result messages from
        // the native SQLite store, rather than a stub's execution counters.
        final day = beijingDay(runtime.clock.nowUtc);
        service.enqueueTool('i4.agenda', 'query_agenda', {
          'first_day': _day(day),
          'end_day_exclusive': _day(day.add(const Duration(days: 2))),
        });
        service.enqueue((response, body) async {
          final result = _lastToolResult(body, 'i4.agenda');
          expectSync(result['status'], 'success');
          final rows = (result['data'] as Map)['items'] as List;
          expectSync(
            rows.map((row) => (row as Map)['title']),
            contains(_eventTitle),
          );
          await _writeTool(response, 'i4.tasks', 'query_tasks', const {});
        });
        service.enqueue((response, body) async {
          final result = _lastToolResult(body, 'i4.tasks');
          expectSync(result['status'], 'success');
          final rows = (result['data'] as Map)['items'] as List;
          expectSync(rows, hasLength(1));
          expectSync((rows.single as Map)['title'], _seedTaskTitle);
          expectSync((rows.single as Map).containsKey('description'), isFalse);
          expectSync((rows.single as Map).containsKey('note'), isFalse);
          await _writeText(response, '已读取本机合成日程和任务。');
        });
        await _sendFromProduct(tester, '查询我的本地日程和任务列表');
        await _waitIdle(tester, runtime);
        expect(runtime.agent.view.failure, isNull);
        expect(runtime.agent.view.messages.last.text, '已读取本机合成日程和任务。');
        tester.platformDispatcher.textScaleFactorTestValue = 1.6;
        await _frames(tester);
        expect(tester.takeException(), isNull);
        await _saveScreen(
          tester,
          captureKey,
          runtime,
          'i4-agent-large-text.png',
        );
        tester.view.viewInsets = FakeViewPadding(bottom: 300 * ratio);
        final composer = find.byKey(const ValueKey('agent-composer'));
        await tester.enterText(composer, 'I4 大字与键盘合成草稿');
        await tester.ensureVisible(composer);
        await _frames(tester);
        expect(tester.getRect(composer).bottom, lessThanOrEqualTo(553));
        expect(composer.hitTestable(), findsOneWidget);
        expect(
          find.byKey(const ValueKey('shell-phone-navigation')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.enterText(composer, '');
        FocusManager.instance.primaryFocus?.unfocus();
        tester.view.resetViewInsets();
        tester.platformDispatcher.textScaleFactorTestValue = 1;
        await _frames(tester);
        debugPrint(
          'I4 native product: SSE, local query pairing and phone composer verified',
        );

        // Rejection is a real phone-sheet decision and writes no business row.
        service.enqueueTool(
          'i4.reject',
          'propose_local_changes',
          _createTask('I4 拒绝任务'),
        );
        service.enqueue((response, body) async {
          expectSync(_lastToolResult(body, 'i4.reject')['status'], 'rejected');
          await _writeText(response, '已拒绝合成方案。');
        });
        await _sendFromProduct(tester, '创建一个标题为 I4 拒绝任务的本地任务，交给我确认');
        final rejectedId = await _waitApproval(tester, runtime);
        await _tapCurrentDecision(tester, runtime, rejectedId, approve: false);
        await _waitIdle(tester, runtime);
        expect((await _tasks(tester, runtime)).items, hasLength(1));

        final deadline = DateTime.fromMillisecondsSinceEpoch(
          DateTime.now()
                  .toUtc()
                  .add(const Duration(hours: 3))
                  .millisecondsSinceEpoch ~/
              1000 *
              1000,
          isUtc: true,
        );
        service.enqueueTool(
          'i4.approve',
          'propose_local_changes',
          _createTask(_approvedTaskTitle, deadline: deadline),
        );
        service.enqueue((response, body) async {
          final result = _lastToolResult(body, 'i4.approve');
          expectSync(result['status'], 'committed');
          expectSync((result['data'] as Map)['count'], 1);
          await _writeText(response, '已按本次确认保存合成任务。');
        });
        await _sendFromProduct(
          tester,
          '创建 $_approvedTaskTitle，截止 ${_beijing(deadline)}，交给我确认',
        );
        final approvedId = await _waitApproval(tester, runtime);
        expect(approvedId, isNot(rejectedId));
        await tester.runAsync(() => runtime.agent.approveAction(rejectedId));
        expect(runtime.agent.view.pendingAction?.id, approvedId);
        expect((await _tasks(tester, runtime)).items, hasLength(1));

        tester.platformDispatcher.textScaleFactorTestValue = 1.4;
        tester.view.viewInsets = FakeViewPadding(bottom: 300 * ratio);
        await _frames(tester);
        await _openCurrentSheet(tester, approvedId);
        final approveButton = find.byKey(
          ValueKey('agent-action-approve-$approvedId'),
        );
        await tester.ensureVisible(approveButton);
        await _frames(tester);
        expect(approveButton.hitTestable(), findsOneWidget);
        expect(tester.getRect(approveButton).bottom, lessThanOrEqualTo(553));
        await _saveScreen(
          tester,
          captureKey,
          runtime,
          'i4-approval-keyboard.png',
        );
        await tester.tap(approveButton);
        await _waitIdle(tester, runtime);
        await _dismissSheetIfPresent(tester);
        tester.view.resetViewInsets();
        tester.platformDispatcher.textScaleFactorTestValue = 1;
        FocusManager.instance.primaryFocus?.unfocus();
        await _frames(tester);
        var tasks = await _tasks(tester, runtime);
        expect(tasks.items, hasLength(2));
        expect(
          tasks.items
              .singleWhere((t) => t.draft.title == _approvedTaskTitle)
              .draft
              .deadlineAtUtc,
          deadline,
        );
        final committed = runtime.agent.view.messages
            .expand((m) => m.actions)
            .singleWhere((a) => a.id == approvedId);
        expect(committed.status, AgentActionStatus.committed);
        expect(committed.committedCount, 1);
        expect(committed.authorization, AgentActionAuthorization.confirmed);
        await tester.runAsync(() => runtime.agent.approveAction(approvedId));
        expect((await _tasks(tester, runtime)).items, hasLength(2));
        await _expectNativeReminders(tester, runtime);
        debugPrint(
          'I4 native product: current approval committed and OS reminders matched',
        );

        // The target is read through the wire, then changes locally after the
        // proposal. Its former version cannot overwrite the newer C3 fact.
        service.enqueueTool('i4.version.read', 'query_tasks', {
          'keywords': _seedTaskTitle,
        });
        service.enqueue((response, body) async {
          final result = _lastToolResult(body, 'i4.version.read');
          final rows = (result['data'] as Map)['items'] as List;
          expectSync(rows, hasLength(1));
          await _writeTool(
            response,
            'i4.version.write',
            'propose_local_changes',
            {
              'changes': [
                {
                  'type': 'update_task',
                  'task_ref': (rows.single as Map)['task_ref'],
                  'title': 'I4 过期覆盖',
                },
              ],
            },
          );
        });
        service.enqueue((response, body) async {
          final result = _lastToolResult(body, 'i4.version.write');
          expectSync(result['status'], 'stale');
          await _writeText(response, '目标已变化，旧方案没有覆盖本地修改。');
        });
        await _sendFromProduct(tester, '把 $_seedTaskTitle 改名为 I4 过期覆盖，先让我确认');
        final staleId = await _waitApproval(tester, runtime);
        await _openCurrentSheet(tester, staleId);
        final staleButton = find.byKey(
          ValueKey('agent-action-approve-$staleId'),
        );
        await tester.ensureVisible(staleButton);
        final staleDecision = tester
            .widget<FilledButton>(staleButton)
            .onPressed!;
        await tester.runAsync(() async {
          final snapshot = await runtime.jwStore.localCalendar.queryTasks(
            const TaskQuery(filter: TaskFilter.all),
          );
          final target = snapshot.items.singleWhere(
            (t) => t.draft.title == _seedTaskTitle,
          );
          await runtime.jwStore.localCalendar.commit(
            await runtime.jwStore.localCalendar.prepare(
              snapshot.context,
              UpdateTask(
                target.reference,
                const TaskDraft(title: _newerTaskTitle),
              ),
            ),
          );
        });
        // This is the callback captured from the displayed current card; it
        // must revalidate after a concurrent local edit, even before repaint.
        staleDecision();
        await _waitIdle(tester, runtime);
        await _dismissSheetIfPresent(tester);
        tasks = await _tasks(tester, runtime);
        expect(tasks.items.map((t) => t.draft.title).toSet(), {
          _newerTaskTitle,
          _approvedTaskTitle,
        });

        final stopped = service.enqueueHeld(
          text: 'I4 停止前正文',
          tail: 'I4_STOP_LATE',
        );
        await _sendFromProduct(tester, '测试停止合成请求');
        await _pumpUntil(
          tester,
          () => runtime.agent.view.messages.last.text.contains('I4 停止前正文'),
          reason: 'held stop stream',
        );
        await _tap(tester, 'agent-stop');
        await _waitIdle(tester, runtime, allowCancelled: true);
        expect(
          runtime.agent.view.messages.last.status,
          AgentMessageStatus.cancelled,
        );
        await tester.runAsync(stopped.finish);
        await _frames(tester);
        expect(
          runtime.agent.view.messages.map((m) => m.text).join(),
          isNot(contains('I4_STOP_LATE')),
        );

        final suspended = service.enqueueHeld(
          text: 'I4 后台前正文',
          tail: 'I4_BACKGROUND_LATE',
        );
        await _sendFromProduct(tester, '测试宿主撤销合成请求');
        await _pumpUntil(
          tester,
          () => runtime.agent.view.messages.last.text.contains('I4 后台前正文'),
          reason: 'held background stream',
        );
        await tester.runAsync(
          () => _platform
              .invokeMethod<void>('i4HostFixtureSuspend')
              .timeout(_operationTimeout),
        );
        await _pumpUntil(
          tester,
          () =>
              !runtime.agent.view.busy &&
              runtime.agent.view.messages.last.status ==
                  AgentMessageStatus.cancelled,
          reason: 'native EventChannel revokes C4 admission',
        );
        expect(
          runtime.agent.view.messages.last.status,
          AgentMessageStatus.cancelled,
        );
        final suspendedRequestCount = service.bodies.length;
        await tester.runAsync(() => runtime.agent.send('宿主撤销时不得发出此消息'));
        expect(runtime.agent.view.failure, AgentFailureCode.cancelled);
        expect(service.bodies, hasLength(suspendedRequestCount));
        await tester.runAsync(suspended.finish);
        await _resumeHost(tester, runtime);
        await _frames(tester, count: 10);
        expect(service.bodies, hasLength(suspendedRequestCount));
        expect(
          runtime.agent.view.messages.map((m) => m.text).join(),
          isNot(contains('I4_BACKGROUND_LATE')),
        );
        expect(openCount, 1);
        expect(identical(opened.runtime, runtime), isTrue);

        // A native host revocation also invalidates a waiting approval. Resume
        // does not replay the proposal or grant a previously displayed button.
        service.enqueueTool(
          'i4.revoked',
          'propose_local_changes',
          _createTask('I4 后台旧方案'),
        );
        await _sendFromProduct(tester, '创建 I4 后台旧方案，先让我确认');
        final revokedId = await _waitApproval(tester, runtime);
        await tester.runAsync(
          () => _platform
              .invokeMethod<void>('i4HostFixtureSuspend')
              .timeout(_operationTimeout),
        );
        await _pumpUntil(
          tester,
          () =>
              runtime.agent.view.pendingAction == null &&
              !runtime.agent.view.busy,
          reason: 'native revoke drains pending approval',
        );
        await tester.runAsync(() => runtime.agent.approveAction(revokedId));
        await _resumeHost(tester, runtime);
        await _dismissSheetIfPresent(tester);
        expect((await _tasks(tester, runtime)).items, hasLength(2));
        debugPrint(
          'I4 native product: stale version, stop and native host revocation verified',
        );

        // A tiny programmatically drawn PNG tests the actual model wire. This
        // intentionally does not pretend to be a user's native Photos choice.
        final syntheticImage = (await tester.runAsync(_makeImage))!;
        service.enqueue((response, body) async {
          expectSync(_imageParts(body), hasLength(1));
          expectSync(
            (_messages(body).last['content'] as List).whereType<Map>().where(
              (part) => part['type'] == 'image_url',
            ),
            hasLength(1),
          );
          final url =
              ((_imageParts(body).single['image_url'] as Map)['url'] as String);
          expectSync(
            url,
            'data:image/png;base64,${base64Encode(syntheticImage.bytes)}',
          );
          await _writeText(response, '本轮合成图已收到。');
        });
        await tester.runAsync(
          () => runtime.agent
              .send('本轮合成图片测试', images: [syntheticImage])
              .timeout(_operationTimeout),
        );
        await _waitIdle(tester, runtime);
        expect(
          runtime.agent.view.messages
              .where((m) => m.role == AgentMessageRole.user)
              .last
              .imageCount,
          1,
        );
        service.enqueue((response, body) async {
          expectSync(_imageParts(body), isEmpty);
          expectSync(jsonEncode(body), isNot(contains(_reasoning)));
          await _writeText(response, '后续轮次没有重发原图。');
        });
        await _sendFromProduct(tester, '继续本地合成对话，不附图');
        await _waitIdle(tester, runtime);
        syntheticImage.bytes.fillRange(0, syntheticImage.bytes.length, 0);

        final conversation = runtime.agent.view.conversationId!;
        final historyIds = runtime.agent.view.messages
            .map((m) => m.id)
            .toList();
        service.enqueue((response, body) async {
          expectSync((body['tools'] as List? ?? const []), isEmpty);
          expectSync(
            (_messages(body).first['content'] as String),
            contains('TASK CONTEXT_SUMMARY'),
          );
          expectSync(_imageParts(body), isEmpty);
          expectSync(jsonEncode(body), isNot(contains(_reasoning)));
          await _writeText(response, '合成历史：一项任务已确认保存；拒绝、停止和撤销均未新增任务。');
        }, summary: true);
        await _sendFromProduct(tester, '/compact');
        await _pumpUntil(
          tester,
          () => runtime.agent.view.contextCompacted && !runtime.agent.view.busy,
          reason: 'real loopback compact completes',
        );
        expect(
          runtime.agent.view.messages.map((m) => m.id).toList(),
          historyIds,
        );
        final context = await tester.runAsync(
          () => (runtime.jwStore.agent as AgentConversationControlPort)
              .readConversationContext(),
        );
        expect(context!.summary, contains('一项任务已确认保存'));
        expect((await _tasks(tester, runtime)).items, hasLength(2));
        final beforeClearRequests = service.bodies.length;
        await _sendFromProduct(tester, '/clear');
        await _pumpUntil(
          tester,
          () =>
              runtime.agent.view.conversationId != conversation &&
              runtime.agent.view.messages.isEmpty &&
              !runtime.agent.view.busy,
          reason: 'clear creates a clean current conversation',
        );
        expect(runtime.agent.view.pendingAction, isNull);
        expect(runtime.agent.view.reasoningByMessage, isEmpty);
        expect(runtime.agent.view.contextCompacted, isFalse);
        expect(service.bodies, hasLength(beforeClearRequests));
        expect(
          (await _tasks(
            tester,
            runtime,
          )).items.map((t) => t.draft.title).toSet(),
          {_newerTaskTitle, _approvedTaskTitle},
        );
        await _expectNativeReminders(tester, runtime);

        await _exerciseNativePicker(tester, runtime, service);
        debugPrint(
          'I4 native product: compact, clear and actual PHPicker cancellation verified',
        );

        await _tap(tester, 'shell-nav-agenda');
        expect(find.byType(CalendarWorkspacePage), findsOneWidget);
        await tester.runAsync(
          () => runtime.calendar.load(
            day: day.add(const Duration(days: 1)),
            mode: CalendarViewMode.week,
          ),
        );
        await _frames(tester);
        final weekViewport = find.byKey(
          const ValueKey('calendar-week-horizontal-scroll'),
        );
        final weekScroll = tester.state<ScrollableState>(
          find
              .descendant(of: weekViewport, matching: find.byType(Scrollable))
              .first,
        );
        expect(weekScroll.position.maxScrollExtent, 0);
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget.key ==
                    const ValueKey('calendar-workspace-date-picker') &&
                widget is IconButton,
          ),
          findsOneWidget,
        );
        await _saveScreen(tester, captureKey, runtime, 'i4-calendar.png');
        await _tap(tester, 'calendar-workspace-tab-tasks');
        expect(find.byType(TaskWorkspacePage), findsOneWidget);
        expect(find.text(_approvedTaskTitle), findsWidgets);
        expect(find.text(_newerTaskTitle), findsWidgets);
        await _tap(tester, 'shell-nav-settings');
        await _tap(tester, 'settings-section-about');
        expect(find.textContaining('图片：系统照片选择器'), findsWidgets);
        expect(find.byType(DiagnosticsExportButton), findsWidgets);

        final safeLog = (await tester.runAsync(
          opened.diagnostics.exportRecent,
        ))!;
        expect(safeLog, isNot(contains(_key)));
        expect(safeLog, isNot(contains(_reasoning)));
        expect(safeLog, isNot(contains(_approvedTaskTitle)));
        expect(safeLog, isNot(contains('data:image')));
        expect(jsonEncode(service.bodies), isNot(contains(_reasoning)));
        expect(service.failures, isEmpty);
        expect(service.remainingReplies, 0);
        expect(morning.calls, 0);
        expect(runtime.jwSync.syncView.busy, isFalse);
        expect(runtime.youngSync.syncView.busy, isFalse);
        expect(openCount, 1);
        expect(tester.takeException(), isNull);
        binding.reportData = <String, Object>{
          'i4ActualProductSingleOwner': true,
          'i4NativeSQLiteAndKeychain': true,
          'i4LoopbackDirectoryCapabilityAndSSE': true,
          'i4Exact20FixedToolsAndLocalResults': true,
          'i4PhoneCurrentApprovalRejectAndVersionGuard': true,
          'i4ApprovedTaskActualOSReminderReadback': true,
          'i4StopAndNativeEventChannelRevocationNoReplay': true,
          'i4CompactClearPreserveBusiness': true,
          'i4ReasoningTransientAndImageCurrentRoundOnly': true,
          'i4ActualPHPickerPresentationSingleFlightCancelAndReopen': true,
          'phoneLogicalWidth': 393,
          'largeTextScale': 1.6,
          'approvalKeyboardInset': 300,
          'bootstrapOpenCount': openCount,
          'physicalBackgroundAndProtectionRequireDevice': true,
          'humanPhotosSelectionAndProviderVisionRequireDevice': true,
          'humanKeyConsentSchoolLoginAndFilesSaveRequireDevice': true,
        };
      } finally {
        try {
          await tester.runAsync(() async {
            await _images
                .invokeMethod<void>('cancel')
                .timeout(_operationTimeout);
            await _platform
                .invokeMethod<void>('i4HostFixtureResume')
                .timeout(_operationTimeout);
          });
          await _waitForFlutterFrames(tester);
          final owned = bootstrap;
          if (owned != null) {
            // Start file/isolate shutdown in a real async zone before entry
            // disposal can create the shared closing future in widget time.
            await _closeBootstrap(tester, owned);
          }
          if (tester.binding.framesEnabled) {
            await tester.pumpWidget(const SizedBox.shrink());
          }
        } finally {
          await tester.runAsync(service.close);
          tester.view.resetViewInsets();
          tester.view.resetPhysicalSize();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
          HttpOverrides.global = previousHttpOverrides;
          if (!inputWasRegistered) binding.testTextInput.unregister();
        }
      }
    },
    skip: !Platform.isIOS || !kDebugMode,
    timeout: const Timeout(Duration(minutes: 9)),
  );
}

Future<void> _configureFromProduct(
  WidgetTester tester,
  DemoRuntime runtime,
  _LoopbackService service,
  _LoopbackOnlyHttpOverrides http,
) async {
  await _tap(tester, 'agent-settings-open');
  await _tap(tester, 'agent-use-policy-full-settings');
  final load = find.byKey(const ValueKey('agent-settings-load-models'));
  await tester.ensureVisible(load);
  expect(tester.widget<OutlinedButton>(load).onPressed, isNull);
  await _tap(tester, 'agent-settings-consent');
  expect(
    tester
        .widget<CheckboxListTile>(
          find.byKey(const ValueKey('agent-settings-consent')),
        )
        .value,
    isTrue,
  );
  await _pumpUntil(
    tester,
    () => !runtime.agent.view.busy,
    reason: 'local consent update settles before entering a candidate Key',
  );
  final key = find.byKey(const ValueKey('agent-settings-key'));
  await tester.ensureVisible(key);
  await tester.enterText(key, _key);
  expect(tester.widget<TextField>(key).controller!.text, _key);
  await _tap(tester, 'agent-settings-load-models');
  try {
    await _pumpUntil(
      tester,
      () =>
          !runtime.agent.view.busy &&
          (runtime.agent.view.availableModels.contains(_model) ||
              runtime.agent.view.failure != null),
      reason: 'actual loopback directory response',
    );
    expect(
      runtime.agent.view.availableModels,
      contains(_model),
      reason: 'directory configuration must succeed',
    );
  } on Object {
    final host = await tester.runAsync(
      () => _platform.invokeMethod<String>('i4HostFixtureInspect'),
    );
    final view = runtime.agent.view;
    debugPrint(
      'I4 directory failure facts: ${jsonEncode({
        'phase': view.phase.name,
        'failure': view.failure?.name,
        'busy': view.busy,
        'models': view.availableModels.length,
        'pendingCandidate': view.pendingKeyProvided,
        'provider': view.settings?.provider.name,
        'nativeHost': const {'active', 'inactive', 'revoked'}.contains(host) ? host : 'invalid',
        'directoryRequests': service.modelRequests,
        'bodyRequests': service.bodies.length,
        'serverFailureCount': service.failures.length,
        'serverFailureTypes': service.failures.toList(),
        'serverFailureStage': service.failureStage,
        'serverAuthorizationMatches': service.authorizationMatches,
        'serverModelsRoute': service.modelsRoute,
        'clientCreations': http.clientCreations,
        'socketCreations': http.socketCreations,
        'deniedConnections': http.deniedConnections,
      })}',
    );
    rethrow;
  }
  expect(tester.widget<TextField>(key).controller!.text, isEmpty);
  await _tap(tester, 'agent-settings-model-school');
  await tester.tap(find.text(_model).last);
  await _frames(tester);
  await _tap(tester, 'agent-settings-verify-save');
  await _pumpUntil(
    tester,
    () =>
        !runtime.agent.view.busy &&
        runtime.agent.view.report.capability == ModelCapability.toolReady,
    reason: 'native Keychain save and text/tool-result verification',
  );
  expect(runtime.agent.view.settings!.consent, isTrue);
  expect(tester.widget<TextField>(key).controller!.text, isEmpty);
  FocusManager.instance.primaryFocus?.unfocus();
  final back = find.byTooltip('返回');
  expect(back, findsOneWidget);
  await tester.tap(back);
  await _frames(tester);
  await _pumpUntil(
    tester,
    () => runtime.agent.view.canSend,
    reason: 'active native host enables configured Agent',
  );
}

Future<void> _seedBusiness(
  DemoRuntime runtime, {
  required void Function(String) onStage,
}) async {
  onStage('seedEvent');
  final local = runtime.jwStore.localCalendar;
  final day = beijingDay(runtime.clock.nowUtc).add(const Duration(days: 1));
  // Exact seconds match the native millisecond wire and keep the calendar
  // screenshot useful even when the cloud job starts close to Beijing midnight.
  final start = DateTime.utc(day.year, day.month, day.day, 2);
  final window = await local.query(
    CalendarQuery(
      firstDay: day,
      endDayExclusive: day.add(const Duration(days: 1)),
    ),
  );
  expectSync(
    window.items,
    isEmpty,
    reason: 'I4 requires a fresh synthetic Simulator installation',
  );
  await local.commit(
    await local.prepare(
      window.context,
      CreatePersonalEvent(
        PersonalEventDraft(
          title: _eventTitle,
          start: start,
          end: start.add(const Duration(minutes: 30)),
          location: 'TEST-I4',
        ),
      ),
    ),
  );
  final tasks = await local.queryTasks(const TaskQuery());
  onStage('seedTask');
  await local.commit(
    await local.prepare(
      tasks.context,
      const CreateTask(
        TaskDraft(
          title: _seedTaskTitle,
          description: 'I4_PRIVATE_DESCRIPTION_NOT_FOR_LISTS',
        ),
      ),
    ),
  );
  onStage('nativeNotificationPermission');
  await _notifications
      .invokeMethod<void>('i3Fixture', {'action': 'provisional'})
      .timeout(_operationTimeout);
  onStage('seedReminderPreferences');
  final reminders = await runtime.jwStore.features.inspectReminders();
  await runtime.jwStore.features.saveReminderPreferences(
    reminders,
    reminders.preferences.copyWith(enabled: true, morningEnabled: false),
  );
  onStage('nativeReminderRefresh');
  await runtime.reminders.refresh().timeout(_operationTimeout);
}

Future<void> _expectNativeReminders(
  WidgetTester tester,
  DemoRuntime runtime,
) async {
  await tester.runAsync(() async {
    await runtime.reminders.refresh().timeout(_operationTimeout);
    final publication = await runtime.jwStore.features
        .prepareReminderPublication();
    final pending = await runtime.reminders.platform.pending().timeout(
      _operationTimeout,
    );
    expect(
      runtime.reminders.view.capability?.queueEvidence,
      NotificationQueueEvidence.operatingSystem,
    );
    expect(
      runtime.reminders.view.capability?.authorizationStatus,
      NotificationAuthorizationStatus.provisional,
    );
    expect(publication.desired, hasLength(2));
    expect(pending, hasLength(2));
    expect(
      pending.map((p) => p.id).toSet(),
      publication.desired.map((d) => d.request.id).toSet(),
    );
    for (final item in pending) {
      expect(
        item.matches(
          publication.desired
              .singleWhere((d) => d.request.id == item.id)
              .request,
        ),
        isTrue,
      );
    }
    expect(pending.map((p) => p.title), contains(_approvedTaskTitle));
  });
}

Future<void> _exerciseNativePicker(
  WidgetTester tester,
  DemoRuntime runtime,
  _LoopbackService service,
) async {
  final requestCount = service.bodies.length;
  const draft = '取消选图仍保留的合成草稿';
  await tester.enterText(find.byKey(const ValueKey('agent-composer')), draft);
  FocusManager.instance.primaryFocus?.unfocus();
  await _frames(tester);
  final attach = find.byKey(const ValueKey('agent-attach-image'));
  await tester.ensureVisible(attach);
  await _frames(tester, count: 2);
  expect(attach.hitTestable(), findsOneWidget);
  // Do not request a Flutter frame after presenting a native controller.
  await tester.tap(attach);
  await tester.runAsync(() async {
    await _waitNativePicker(presented: true);
    await expectLater(
      IOSAgentImagePicker().pickImages(),
      throwsA(
        isA<AgentFailure>().having(
          (f) => f.code,
          'code',
          AgentFailureCode.busy,
        ),
      ),
    );
    // The fixed Debug action calls the real delegate's empty-selection path;
    // its reply waits for actual UIKit dismissal. No touch is claimed here.
    await _images
        .invokeMethod<void>('i4ImageFixtureCancel')
        .timeout(_operationTimeout);
    await _waitNativePicker(presented: false);
  });
  await _waitForFlutterFrames(tester);
  await _frames(tester);
  expect(
    tester
        .widget<TextField>(find.byKey(const ValueKey('agent-composer')))
        .controller!
        .text,
    draft,
  );
  expect(find.byKey(const ValueKey('agent-image-preview-0')), findsNothing);

  final picker = IOSAgentImagePicker();
  await tester.runAsync(() async {
    final picked = picker.pickImages();
    // Attach the error handler before native cancellation can complete.
    final cancelled = expectLater(
      picked,
      throwsA(
        isA<AgentFailure>().having(
          (f) => f.code,
          'code',
          AgentFailureCode.cancelled,
        ),
      ),
    );
    await _waitNativePicker(presented: true);
    await _platform
        .invokeMethod<void>('i4HostFixtureSuspend')
        .timeout(_operationTimeout);
    await cancelled.timeout(_operationTimeout);
    await _waitNativePicker(presented: false);
    await picker.cancel().timeout(_operationTimeout);
    await picker.cancel().timeout(_operationTimeout);
    await _platform
        .invokeMethod<void>('i4HostFixtureResume')
        .timeout(_operationTimeout);
  });
  await _waitForFlutterFrames(tester);
  await _pumpUntil(
    tester,
    () => runtime.agent.view.canSend,
    reason: 'actual host resumes after picker revocation',
  );

  // A subsequent operation must have its own result after the cancelled flight.
  await tester.runAsync(() async {
    final picked = picker.pickImages();
    await _waitNativePicker(presented: true);
    await _images
        .invokeMethod<void>('i4ImageFixtureCancel')
        .timeout(_operationTimeout);
    expect(await picked.timeout(_operationTimeout), isEmpty);
    await _waitNativePicker(presented: false);
  });
  await _waitForFlutterFrames(tester);
  await _frames(tester);
  expect(service.bodies, hasLength(requestCount));
  expect(
    tester
        .widget<TextField>(find.byKey(const ValueKey('agent-composer')))
        .controller!
        .text,
    draft,
  );
  await tester.enterText(find.byKey(const ValueKey('agent-composer')), '');
  FocusManager.instance.primaryFocus?.unfocus();
  await _frames(tester);
}

Future<void> _waitNativePicker({required bool presented}) async {
  final elapsed = Stopwatch()..start();
  Map<String, Object?>? state;
  while (elapsed.elapsed < _operationTimeout) {
    state = await _images
        .invokeMapMethod<String, Object?>('i4ImageFixtureInspect')
        .timeout(_operationTimeout);
    expect(state?.keys.toSet(), {'fixture', 'busy', 'presented', 'stage'});
    expect(state?['fixture'], 'i4-image-fixture');
    if (state?['presented'] == presented &&
        state?['busy'] == presented &&
        state?['stage'] == (presented ? 'presented' : 'idle')) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail(
    'native picker did not reach ${presented ? 'presented' : 'idle'}: $state',
  );
}

Future<void> _resumeHost(WidgetTester tester, DemoRuntime runtime) async {
  await tester.runAsync(
    () => _platform
        .invokeMethod<void>('i4HostFixtureResume')
        .timeout(_operationTimeout),
  );
  await _pumpUntil(
    tester,
    () => runtime.agent.view.canSend && !runtime.agent.view.busy,
    reason: 'native host reopens current admission without replay',
  );
}

Future<void> _openCurrentSheet(WidgetTester tester, String id) async {
  if (find
      .byKey(const ValueKey('agent-current-approval-panel'))
      .evaluate()
      .isEmpty) {
    await _tap(tester, 'agent-current-approval-open');
  }
  await _pumpUntil(
    tester,
    () =>
        find.byKey(ValueKey('agent-action-approve-$id')).evaluate().isNotEmpty,
    reason: 'phone sheet must show the current approval',
  );
}

Future<void> _tapCurrentDecision(
  WidgetTester tester,
  DemoRuntime runtime,
  String id, {
  required bool approve,
}) async {
  expect(runtime.agent.view.pendingAction?.id, id);
  await _openCurrentSheet(tester, id);
  await _tap(tester, 'agent-action-${approve ? 'approve' : 'reject'}-$id');
  await _dismissSheetIfPresent(tester);
}

Future<void> _dismissSheetIfPresent(WidgetTester tester) async {
  await _frames(tester);
  final close = find.byKey(const ValueKey('agent-approval-sheet-close'));
  if (close.evaluate().isNotEmpty) {
    await tester.tap(close);
    await _frames(tester);
  }
}

Future<String> _waitApproval(WidgetTester tester, DemoRuntime runtime) async {
  await _pumpUntil(
    tester,
    () =>
        runtime.agent.view.phase == AgentPhase.waitingForApproval &&
        runtime.agent.view.pendingAction != null,
    reason: 'synthetic tool must wait for a real current-card approval',
  );
  expect(runtime.agent.view.pendingAction!.status, AgentActionStatus.proposed);
  await _frames(tester);
  return runtime.agent.view.pendingAction!.id;
}

Future<void> _sendFromProduct(WidgetTester tester, String text) async {
  await _dismissSheetIfPresent(tester);
  final composer = find.byKey(const ValueKey('agent-composer'));
  await tester.ensureVisible(composer);
  await _pumpUntil(
    tester,
    () => tester.widget<TextField>(composer).enabled != false,
    reason: 'product composer finishes its previous UI operation',
  );
  await tester.enterText(composer, text);
  await _frames(tester, count: 2);
  final send = find.byKey(const ValueKey('agent-send'));
  await tester.ensureVisible(send);
  try {
    await _pumpUntil(
      tester,
      () => tester.widget<IconButton>(send).onPressed != null,
      reason: 'product send control accepts the current synthetic draft',
    );
  } on Object {
    final view = tester
        .widget<AgentWorkspacePage>(find.byType(AgentWorkspacePage))
        .controller
        .view;
    final field = tester.widget<TextField>(composer);
    debugPrint(
      'I4 composer failure facts: ${jsonEncode({'phase': view.phase.name, 'failure': view.failure?.name, 'busy': view.busy, 'canSend': view.canSend, 'fieldEnabled': field.enabled, 'draftMatches': field.controller!.text == text, 'draftEmpty': field.controller!.text.isEmpty})}',
    );
    rethrow;
  }
  expect(tester.widget<TextField>(composer).controller!.text, text);
  await tester.tap(send);
  FocusManager.instance.primaryFocus?.unfocus();
  await _frames(tester, count: 2);
}

Future<void> _waitIdle(
  WidgetTester tester,
  DemoRuntime runtime, {
  bool allowCancelled = false,
}) async {
  await _pumpUntil(
    tester,
    () =>
        !runtime.agent.view.busy && runtime.agent.view.phase == AgentPhase.idle,
    reason: 'Agent must settle its actual native/wire work',
  );
  if (!allowCancelled) expect(runtime.agent.view.failure, isNull);
  await _frames(tester);
}

Future<TaskWindow> _tasks(WidgetTester tester, DemoRuntime runtime) async =>
    (await tester.runAsync(
      () => runtime.jwStore.localCalendar.queryTasks(
        const TaskQuery(filter: TaskFilter.all),
      ),
    ))!;

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  FocusManager.instance.primaryFocus?.unfocus();
  await _pumpUntil(tester, () {
    if (target.evaluate().length != 1) return false;
    final widget = tester.widget(target);
    if (widget is ButtonStyleButton) return widget.onPressed != null;
    if (widget is IconButton) return widget.onPressed != null;
    if (widget is SwitchListTile) return widget.onChanged != null;
    return true;
  }, reason: '$key becomes available');
  await tester.ensureVisible(target);
  await _frames(tester, count: 2);
  expect(
    target.hitTestable(),
    findsOneWidget,
    reason: '$key must be reachable',
  );
  await tester.tap(target);
  await _frames(tester);
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
}) async {
  final elapsed = Stopwatch()..start();
  while (!condition() && elapsed.elapsed < _operationTimeout) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
  expect(condition(), isTrue, reason: reason);
}

Future<void> _frames(WidgetTester tester, {int count = 6}) async {
  for (var index = 0; index < count; index++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _closeBootstrap(
  WidgetTester tester,
  RuntimeBootstrap bootstrap,
) async {
  // Native files/isolate queues need real time; widget continuations still
  // receive pumps while this caller-owned runtime drains.
  var completed = false;
  Object? failure;
  await tester.runAsync(() async {
    unawaited(
      bootstrap.close().then<void>(
        (_) => completed = true,
        onError: (Object error) {
          failure = error;
          completed = true;
        },
      ),
    );
  });
  await _pumpUntil(
    tester,
    () => completed,
    reason: 'owned native runtime closes',
  );
  expect(failure, isNull, reason: 'native runtime cleanup');
  expect(bootstrap.directory.isHeld, isFalse);
  expect(bootstrap.jwDirectory.isHeld, isFalse);
}

Future<void> _waitForFlutterFrames(WidgetTester tester) async {
  await tester.runAsync(() async {
    final elapsed = Stopwatch()..start();
    while (!tester.binding.framesEnabled &&
        elapsed.elapsed < _operationTimeout) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(
      tester.binding.framesEnabled,
      isTrue,
      reason: 'actual native dismissal must restore Flutter frames before pump',
    );
  });
}

Future<void> _saveScreen(
  WidgetTester tester,
  GlobalKey key,
  DemoRuntime runtime,
  String filename,
) async {
  expect({
    'i4-agent.png',
    'i4-approval-keyboard.png',
    'i4-agent-large-text.png',
    'i4-calendar.png',
  }, contains(filename));
  await tester.pump();
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final data = (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      return await image.toByteData(format: ui.ImageByteFormat.png);
    } finally {
      image.dispose();
    }
  }))!;
  await tester.runAsync(
    () => File(runtime.directory.checkedChildPath(filename, directory: false))
        .writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        ),
  );
}

Future<AgentImage> _makeImage() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 8, 8),
    Paint()..color = const Color(0xff338855),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(8, 8);
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return await normalizeAgentImage(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Map<String, Object?> _createTask(String title, {DateTime? deadline}) => {
  'changes': [
    {
      'type': 'create_task',
      'local_key': 'i4task',
      'title': title,
      if (deadline != null) 'deadline': _beijing(deadline),
    },
  ],
};

String _day(DateTime value) => value.toIso8601String().substring(0, 10);
String _beijing(DateTime value) =>
    '${value.toUtc().add(const Duration(hours: 8)).toIso8601String().substring(0, 19)}+08:00';

List<Map<String, dynamic>> _messages(Map<String, dynamic> body) =>
    (body['messages'] as List).cast<Map<String, dynamic>>();

List<Map> _imageParts(Map<String, dynamic> body) => [
  for (final message in _messages(body))
    if (message['content'] is List)
      for (final part in message['content'] as List)
        if (part is Map && part['type'] == 'image_url') part,
];

Map<String, dynamic> _lastToolResult(Map<String, dynamic> body, String id) {
  final messages = _messages(body);
  final tool = messages.last;
  expectSync(tool['role'], 'tool');
  expectSync(tool['tool_call_id'], id);
  final assistant = messages.lastWhere((m) => m['role'] == 'assistant');
  final calls = assistant['tool_calls'] as List;
  expectSync(calls.map((call) => (call as Map)['id']), contains(id));
  return jsonDecode(tool['content'] as String) as Map<String, dynamic>;
}

typedef _Reply =
    Future<void> Function(HttpResponse response, Map<String, dynamic> body);

final class _LoopbackService {
  // Socket callbacks can run while WidgetTester.pump owns an async guard.
  // expectSync keeps every matcher without treating those callbacks as an
  // overlapping WidgetTester operation. Ordinary UI assertions use expect.
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;
  final bodies = <Map<String, dynamic>>[];
  final failures = <String>[];
  final _replies = Queue<({bool summary, _Reply reply})>();
  final _holds = <_HeldReply>[];
  final _handlers = <Future<void>>{};
  var modelRequests = 0;
  String? failureStage;
  bool? authorizationMatches;
  bool? modelsRoute;
  String? probeProof;
  Map<String, dynamic>? probeResultBody;

  Uri get baseUri =>
      Uri(scheme: 'http', host: '127.0.0.1', port: _server!.port);
  int get remainingReplies => _replies.length;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _subscription = _server!.listen((request) {
      final handler = _handle(request);
      _handlers.add(handler);
      unawaited(handler.whenComplete(() => _handlers.remove(handler)));
    });
  }

  void enqueue(_Reply reply, {bool summary = false}) =>
      _replies.add((summary: summary, reply: reply));

  void enqueueTool(String id, String name, Map<String, Object?> args) =>
      enqueue((response, _) => _writeTool(response, id, name, args));

  _HeldReply enqueueHeld({
    required String text,
    String? reasoning,
    required String tail,
  }) {
    final hold = _HeldReply(text, reasoning, tail);
    _holds.add(hold);
    enqueue(hold.reply);
    return hold;
  }

  Future<void> _handle(HttpRequest request) async {
    var stage = 'authorization';
    try {
      authorizationMatches =
          request.headers.value(HttpHeaders.authorizationHeader) ==
          'Bearer $_key';
      modelsRoute = request.method == 'GET' && request.uri.path == '/v1/models';
      expectSync(
        request.headers.value(HttpHeaders.authorizationHeader),
        'Bearer $_key',
      );
      if (request.method == 'GET' && request.uri.path == '/v1/models') {
        stage = 'directoryResponse';
        modelRequests++;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {'id': _model},
            ],
          }),
        );
        await request.response.close();
        return;
      }
      stage = 'chatRoute';
      expectSync(request.method, 'POST');
      expectSync(request.uri.path, '/v1/chat/completions');
      stage = 'chatBody';
      final body =
          jsonDecode(
                await utf8.decoder
                    .bind(request)
                    .join()
                    .timeout(_operationTimeout),
              )
              as Map<String, dynamic>;
      bodies.add(body);
      stage = 'chatProtocol';
      expectSync(body['model'], _model);
      expectSync(body['stream'], isTrue);
      final system = _messages(body).first['content'] as String;
      if (system.contains('TASK CAPABILITY_PROBE')) {
        await _writeText(request.response, 'USTC_TEXT_PROBE');
        return;
      }
      final choice = body['tool_choice'];
      if (choice is Map &&
          (choice['function'] as Map)['name'] == 'echo_probe') {
        await _writeTool(request.response, 'i4:probe', 'echo_probe', {
          'value': 'ustc_probe',
        });
        return;
      }
      if (choice == 'none' && system.contains('TASK TOOL_CAPABILITY_PROBE')) {
        final result = _lastToolResult(body, 'i4:probe');
        expectSync(result['value'], 'ustc_probe');
        probeProof = result['proof'] as String;
        probeResultBody = body;
        await _writeText(request.response, probeProof!);
        return;
      }
      expectSync(
        _replies,
        isNotEmpty,
        reason: 'every model request needs an explicit synthetic script',
      );
      final script = _replies.removeFirst();
      stage = 'toolSet';
      if (!script.summary) {
        expectSync(body['max_tokens'], AgentContextOptions.defaultOutputTokens);
        final tools = body['tools'] as List;
        expectSync(tools, hasLength(20));
        expectSync(
          tools.map((t) => ((t as Map)['function'] as Map)['name']).toSet(),
          _fixedTools,
        );
        expectSync(body.containsKey('tool_choice'), isFalse);
      }
      stage = 'script';
      await script.reply(request.response, body);
    } on Object catch (error) {
      // Only a closed exception category is retained. No headers, request
      // bodies, paths or exception descriptions are emitted into app logs.
      failures.add(error.runtimeType.toString());
      failureStage = stage;
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } on Object {
        // The app can abort a deliberately held synthetic response.
      }
    }
  }

  Future<void> close() async {
    for (final hold in _holds) {
      hold.release();
    }
    await _subscription?.cancel();
    await _server?.close(force: true);
    if (_handlers.isNotEmpty) {
      await Future.wait(_handlers.toList()).timeout(_operationTimeout);
    }
  }
}

final class _HeldReply {
  _HeldReply(this.text, this.reasoning, this.tail);
  final String text, tail;
  final String? reasoning;
  final _release = Completer<void>();
  final _finished = Completer<void>();

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  Future<void> finish() async {
    release();
    await _finished.future.timeout(_operationTimeout);
  }

  Future<void> reply(HttpResponse response, Map<String, dynamic> _) async {
    try {
      _startSse(response);
      if (reasoning != null) {
        await _event(response, {'reasoning_content': reasoning});
      }
      await _event(response, {'content': text});
      await _release.future.timeout(_operationTimeout);
      await _event(response, {'content': tail});
      await _finishSse(response, 'stop');
    } on HttpException {
      // An aborted client is expected in the stop/background cases.
    } on SocketException {
      // Late network writes cannot deliver into the cancelled generation.
    } finally {
      if (!_finished.isCompleted) _finished.complete();
    }
  }
}

void _startSse(HttpResponse response) {
  response.headers.contentType = ContentType(
    'text',
    'event-stream',
    charset: 'utf-8',
  );
  response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
  response.bufferOutput = false;
}

Future<void> _event(
  HttpResponse response,
  Map<String, Object?> delta, {
  String? finish,
}) async {
  response.write(
    'data: ${jsonEncode({
      'choices': [
        {'index': 0, 'delta': delta, 'finish_reason': finish},
      ],
    })}\n\n',
  );
  await response.flush();
}

Future<void> _finishSse(HttpResponse response, String reason) async {
  await _event(response, const {}, finish: reason);
  response.write('data: [DONE]\n\n');
  await response.close();
}

Future<void> _writeText(HttpResponse response, String text) async {
  _startSse(response);
  final middle = text.length ~/ 2;
  await _event(response, {'content': text.substring(0, middle)});
  await _event(response, {'content': text.substring(middle)});
  await _finishSse(response, 'stop');
}

Future<void> _writeTool(
  HttpResponse response,
  String id,
  String name,
  Map<String, Object?> args,
) async {
  _startSse(response);
  final encoded = jsonEncode(args);
  final middle = encoded.length ~/ 2;
  await _event(response, {
    'tool_calls': [
      {
        'index': 0,
        'id': id,
        'type': 'function',
        'function': {'name': name, 'arguments': encoded.substring(0, middle)},
      },
    ],
  });
  await _event(response, {
    'tool_calls': [
      {
        'index': 0,
        'function': {'arguments': encoded.substring(middle)},
      },
    ],
  });
  await _finishSse(response, 'tool_calls');
}

final class _LoopbackOnlyHttpOverrides extends HttpOverrides {
  _LoopbackOnlyHttpOverrides(this.origin);
  final Uri origin;
  var clientCreations = 0;
  var socketCreations = 0;
  var deniedConnections = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    clientCreations++;
    final client = super.createHttpClient(context);
    client.findProxy = (uri) {
      if (uri.scheme != 'http' ||
          uri.host != '127.0.0.1' ||
          uri.port != origin.port ||
          uri.userInfo.isNotEmpty) {
        deniedConnections++;
        throw StateError('i4_non_loopback_http_rejected');
      }
      return 'DIRECT';
    };
    // UstcModelGateway deliberately chooses DIRECT for its test constructor.
    // Keep a second fence at socket creation so overwriting findProxy cannot
    // enable an accidental school/public-service request from another module.
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      if (uri.scheme != 'http' ||
          uri.host != '127.0.0.1' ||
          uri.port != origin.port ||
          uri.userInfo.isNotEmpty ||
          proxyHost != null) {
        deniedConnections++;
        throw StateError('i4_non_loopback_socket_rejected');
      }
      socketCreations++;
      return Socket.startConnect(InternetAddress.loopbackIPv4, origin.port);
    };
    return client;
  }
}

final class _NoNetworkMorningGateway implements ModelGatewayPort {
  var calls = 0;

  @override
  Future<List<String>> listModels(ModelSecretLease secret) async {
    calls++;
    secret.revoke();
    throw StateError('i4_morning_network_disabled');
  }

  @override
  Stream<ModelEvent> generate(ModelRequest request, ModelSecretLease secret) {
    calls++;
    secret.revoke();
    return Stream<ModelEvent>.error(StateError('i4_morning_network_disabled'));
  }

  @override
  Future<void> cancelAndDrain() async {}

  @override
  Future<void> close() async {}
}
