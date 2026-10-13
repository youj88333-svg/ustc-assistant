import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/agent_settings_panel.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_contract.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_page.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets('unconfigured workspace guides to settings and cannot send', (
    tester,
  ) async {
    final port = _FakeAgentPort();
    addTearDown(port.dispose);
    var settingsOpened = false;

    await tester.pumpWidget(
      _host(
        AgentWorkspacePage(
          controller: port,
          onSettings: () => settingsOpened = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('agent-model-setup-prompt')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('agent-send')), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('agent-send')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('agent-settings-open')));
    expect(settingsOpened, isTrue);
    expect(port.sent, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('canSend submits and a generating request can be stopped', (
    tester,
  ) async {
    final port = _FakeAgentPort(
      view: _view(
        settings: _settings(
          keySaved: true,
          consent: true,
          modelId: 'model-a',
          report: const AgentCapabilityReport(text: true, streaming: true),
        ),
        conversationId: 'conversation-a',
        conversations: [_conversation('conversation-a', '实验计划')],
      ),
    );
    port.sendGate = Completer<void>();
    addTearDown(port.dispose);

    await tester.pumpWidget(
      _host(AgentWorkspacePage(controller: port, onSettings: () {})),
    );
    await tester.pumpAndSettle();
    await _enter(tester, 'agent-composer', '帮我整理实验计划');
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('agent-send')))
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.byKey(const ValueKey('agent-send')));
    await tester.pump();
    await tester.pump();
    expect(port.sent, ['帮我整理实验计划']);
    expect(find.byKey(const ValueKey('agent-stop')), findsOneWidget);
    expect(find.text('正在生成回复'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('agent-stop')));
    await tester.pump();
    expect(port.stopCalls, 1);
    port.sendGate!.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('image attachments can be removed and sent without text', (
    tester,
  ) async {
    final port = _configuredPort();
    addTearDown(port.dispose);
    final png = _testPng1x1();
    AgentImage? lastPicked;

    await tester.pumpWidget(
      _host(
        AgentWorkspacePage(
          controller: port,
          onSettings: () {},
          pickImages: () async {
            lastPicked = AgentImage(Uint8List.fromList(png));
            return [lastPicked!];
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _tap(tester, 'agent-attach-image');
    expect(find.byKey(const ValueKey('agent-image-preview-0')), findsOneWidget);
    expect(find.textContaining('附图 1 张 · 还可选 2 张'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('agent-send')))
          .onPressed,
      isNotNull,
    );

    await _tap(tester, 'agent-image-remove-0');
    expect(find.byKey(const ValueKey('agent-image-preview-0')), findsNothing);
    expect(lastPicked!.bytes.every((byte) => byte == 0), isTrue);

    await _tap(tester, 'agent-attach-image');
    await _tap(tester, 'agent-send');
    expect(port.sent, ['请根据本次附图回答。']);
    expect(port.sentImageCounts, [1]);
    expect(port.lastSentImages.single.bytes.every((byte) => byte == 0), isTrue);
    expect(find.textContaining('附图 1 张 · 原图未保留'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a late image pick is wiped when model consent is revoked', (
    tester,
  ) async {
    final port = _configuredPort();
    addTearDown(port.dispose);
    final pickGate = Completer<List<AgentImage>>();
    final selected = AgentImage(Uint8List.fromList(_testPng1x1()));

    await tester.pumpWidget(
      _host(
        AgentWorkspacePage(
          controller: port,
          onSettings: () {},
          pickImages: () => pickGate.future,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('agent-attach-image')));
    await tester.pump();

    port.replace(
      port.view.copyWithForTest(
        settings: _settings(
          keySaved: true,
          consent: false,
          modelId: 'model-a',
          report: const AgentCapabilityReport(text: true, streaming: true),
        ),
      ),
    );
    pickGate.complete([selected]);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('agent-image-preview-0')), findsNothing);
    expect(selected.bytes.every((byte) => byte == 0), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stopping a run invalidates a pending image pick', (
    tester,
  ) async {
    final port = _configuredPort();
    addTearDown(port.dispose);
    final pickGate = Completer<List<AgentImage>>();
    final selected = AgentImage(Uint8List.fromList(_testPng1x1()));

    await tester.pumpWidget(
      _host(
        AgentWorkspacePage(
          controller: port,
          onSettings: () {},
          pickImages: () => pickGate.future,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('agent-attach-image')));
    await tester.pump();
    port.replace(port.view.copyWithForTest(phase: AgentPhase.executingRead));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('agent-stop')));
    await tester.pumpAndSettle();
    expect(port.stopCalls, 1);

    pickGate.complete([selected]);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('agent-image-preview-0')), findsNothing);
    expect(selected.bytes.every((byte) => byte == 0), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clearing history invalidates a pending image pick', (
    tester,
  ) async {
    final port = _configuredPort();
    addTearDown(port.dispose);
    final pickGate = Completer<List<AgentImage>>();
    final selected = AgentImage(Uint8List.fromList(_testPng1x1()));

    await tester.pumpWidget(
      _host(
        AgentWorkspacePage(
          controller: port,
          onSettings: () {},
          pickImages: () => pickGate.future,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('agent-attach-image')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('agent-history-menu')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('清除全部对话…'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.byKey(const ValueKey('agent-history-clear-first-confirm')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.byKey(const ValueKey('agent-history-clear-final-confirm')),
    );
    await tester.pumpAndSettle();

    pickGate.complete([selected]);
    await tester.pumpAndSettle();
    expect(port.clearCalls.single.confirmed, isTrue);
    expect(find.byKey(const ValueKey('agent-image-preview-0')), findsNothing);
    expect(selected.bytes.every((byte) => byte == 0), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a late image pick cannot return after the controller changes', (
    tester,
  ) async {
    final firstPort = _configuredPort();
    final nextPort = _configuredPort();
    final portNotifier = ValueNotifier<AgentWorkspacePort>(firstPort);
    final pickGate = Completer<List<AgentImage>>();
    final selected = AgentImage(Uint8List.fromList(_testPng1x1()));
    addTearDown(firstPort.dispose);
    addTearDown(nextPort.dispose);
    addTearDown(portNotifier.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<AgentWorkspacePort>(
            valueListenable: portNotifier,
            builder: (context, port, _) => AgentWorkspacePage(
              controller: port,
              onSettings: () {},
              pickImages: () => pickGate.future,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('agent-attach-image')));
    await tester.pump();
    portNotifier.value = nextPort;
    await tester.pumpAndSettle();
    pickGate.complete([selected]);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('agent-image-preview-0')), findsNothing);
    expect(selected.bytes.every((byte) => byte == 0), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders interrupted assistant messages with partial status', (
    tester,
  ) async {
    final port = _FakeAgentPort(
      view: _view(
        settings: _settings(
          keySaved: true,
          consent: true,
          modelId: 'model-a',
          report: const AgentCapabilityReport(text: true, streaming: true),
        ),
        conversationId: 'conversation-a',
        conversations: [_conversation('conversation-a', '讨论')],
        messages: [
          AgentMessage(
            id: 3,
            role: AgentMessageRole.assistant,
            text:
                '已整理出两点：\n\n- 范围\n- 时间\n\n'
                '[安全链接](https://example.invalid) '
                '![图](https://example.invalid/a.png) <img src=x>',
            status: AgentMessageStatus.interrupted,
            createdAtUtc: DateTime.utc(2026, 10, 13),
          ),
        ],
      ),
    );
    addTearDown(port.dispose);

    await tester.pumpWidget(
      _host(AgentWorkspacePage(controller: port, onSettings: () {})),
    );
    await tester.pumpAndSettle();

    expect(find.text('部分回复 · 已中断'), findsOneWidget);
    expect(find.text('已整理出两点：'), findsOneWidget);
    expect(find.text('安全链接'), findsOneWidget);
    expect(find.textContaining('图片已隐藏：图'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'shows verified evidence, unverified references, steps, and live counters',
    (tester) async {
      final evidence = AgentEvidence(
        id: 'e_0123456789abcdef',
        provider: 'teach',
        title: '本科教学安排',
        observedAtUtc: DateTime.utc(2026, 10, 13, 2, 30),
        scope: '指定栏目，返回 1 项',
        complete: false,
        articleUrl: 'https://www.teach.ustc.edu.cn/example',
        publishedOn: '2026-10-10',
        locator: '正文第 2 段',
        sourceVersion: '2026-10-13',
        snippet: '这是一段仅在用户展开后显示的合成出处片段。',
      );
      final port = _FakeAgentPort(
        view: _view(
          phase: AgentPhase.executingRead,
          settings: _settings(
            keySaved: true,
            consent: true,
            modelId: 'model-a',
            report: const AgentCapabilityReport(text: true, streaming: true),
          ),
          conversationId: 'conversation-a',
          conversations: [_conversation('conversation-a', '资料查询')],
          businessToolsEnabled: true,
          activeTool: 'query_agenda',
          toolCalls: 2,
          modelCalls: 3,
          messages: [
            AgentMessage(
              id: 8,
              role: AgentMessageRole.assistant,
              text:
                  '已读取 [[e_0123456789abcdef]]，另有 [[e_ffffffffffffffff]]。'
                  '\n\n[外部链接](https://example.invalid) '
                  '![不加载](https://example.invalid/image.png)',
              status: AgentMessageStatus.complete,
              createdAtUtc: DateTime.utc(2026, 10, 13),
              evidence: [evidence],
              steps: const [
                AgentToolStep(tool: 'query_agenda', status: 'success'),
                AgentToolStep(tool: 'browse_campus', status: 'partial'),
              ],
            ),
          ],
        ),
      );
      addTearDown(port.dispose);

      await tester.pumpWidget(
        _host(AgentWorkspacePage(controller: port, onSettings: () {})),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('正在查询日程'), findsWidgets);
      expect(find.text('模型请求 3 次 · 工具调用 2 次'), findsOneWidget);
      expect(find.textContaining('【出处 1】', findRichText: true), findsOneWidget);
      expect(find.text('e_0123456789abcdef'), findsNothing);
      expect(find.textContaining('【引用未验证', findRichText: true), findsOneWidget);
      expect(find.textContaining('历史材料，下轮须重新查询'), findsOneWidget);
      expect(find.text('日程 · 已完成'), findsOneWidget);
      expect(find.text('校园公开资料 · 部分结果'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('agent-evidence-copy-e_0123456789abcdef')),
        findsOneWidget,
      );
      expect(find.text('这是一段仅在用户展开后显示的合成出处片段。'), findsNothing);
      expect(find.textContaining('不加载'), findsOneWidget);
      expect(find.byType(Image), findsNothing);

      final expand = find.byKey(
        const ValueKey('agent-evidence-expand-e_0123456789abcdef'),
      );
      await tester.ensureVisible(expand);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(expand);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('这是一段仅在用户展开后显示的合成出处片段。'), findsOneWidget);
      port.replace(port.view.copyWithForTest(phase: AgentPhase.idle));
      await tester.pumpAndSettle();
      expect(find.textContaining('本次回答读取，下轮须重新查询'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'historical image messages show count without restoring originals',
    (tester) async {
      final port = _FakeAgentPort(
        view: _view(
          settings: _settings(
            keySaved: true,
            consent: true,
            modelId: 'model-a',
          ),
          conversationId: 'conversation-a',
          conversations: [_conversation('conversation-a', '历史对话')],
          messages: [
            AgentMessage(
              id: 12,
              role: AgentMessageRole.user,
              text: '请看附件',
              status: AgentMessageStatus.complete,
              createdAtUtc: DateTime.utc(2026, 10, 13),
              imageCount: 2,
            ),
          ],
        ),
      );
      addTearDown(port.dispose);

      await tester.pumpWidget(
        _host(AgentWorkspacePage(controller: port, onSettings: () {})),
      );
      await tester.pumpAndSettle();

      expect(find.text('附图 2 张 · 原图未保留'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'send errors use fixed copy and do not expose exception details',
    (tester) async {
      final port = _FakeAgentPort(
        view: _view(
          settings: _settings(
            keySaved: true,
            consent: true,
            modelId: 'model-a',
            report: const AgentCapabilityReport(text: true, streaming: true),
          ),
          conversationId: 'conversation-a',
          conversations: [_conversation('conversation-a', '当前对话')],
        ),
      );
      port.sendError = StateError('private key detail');
      addTearDown(port.dispose);

      await tester.pumpWidget(
        _host(AgentWorkspacePage(controller: port, onSettings: () {})),
      );
      await tester.pumpAndSettle();
      await _enter(tester, 'agent-composer', '测试错误提示');
      await _tap(tester, 'agent-send');

      expect(find.text('消息未能发送，请稍后重试。'), findsOneWidget);
      expect(find.textContaining('private key detail'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('settings never fills a saved key and clears typed keys on use', (
    tester,
  ) async {
    final port = _FakeAgentPort(
      view: _view(
        settings: _settings(
          keySaved: true,
          consent: true,
          modelId: 'model-a',
          modelIds: const ['model-a'],
          report: const AgentCapabilityReport(text: true, streaming: true),
        ),
      ),
    );
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(AgentSettingsPanel(controller: port)));
    await tester.pumpAndSettle();
    expect(_keyField(tester).controller!.text, isEmpty);

    await _tap(tester, 'agent-settings-load-models');
    expect(port.loadCalls.single.key, isEmpty);
    expect(port.loadCalls.single.consent, isTrue);
    expect(_keyField(tester).controller!.text, isEmpty);

    await _enter(tester, 'agent-settings-key', 'typed-key-for-this-request');
    await _tap(tester, 'agent-settings-verify-save');
    expect(port.verifyCalls.single.key, 'typed-key-for-this-request');
    expect(port.verifyCalls.single.modelId, 'model-a');
    expect(port.verifyCalls.single.consent, isTrue);
    expect(_keyField(tester).controller!.text, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('model actions stay disabled until consent is checked', (
    tester,
  ) async {
    final port = _FakeAgentPort(
      view: _view(
        settings: _settings(
          keySaved: true,
          consent: false,
          modelId: 'model-a',
          modelIds: const ['model-a'],
        ),
      ),
    );
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(AgentSettingsPanel(controller: port)));
    await tester.pumpAndSettle();
    expect(_button(tester, 'agent-settings-load-models').onPressed, isNull);
    expect(_button(tester, 'agent-settings-verify-save').onPressed, isNull);
    expect(port.loadCalls, isEmpty);

    await _tap(tester, 'agent-settings-consent');
    expect(_button(tester, 'agent-settings-load-models').onPressed, isNotNull);
    await _tap(tester, 'agent-settings-load-models');
    expect(port.loadCalls.single.consent, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a candidate key can be verified after model lookup clears input',
    (tester) async {
      final port = _FakeAgentPort(
        view: _view(settings: _settings(keySaved: false, consent: true)),
      );
      addTearDown(port.dispose);

      await tester.pumpWidget(_host(AgentSettingsPanel(controller: port)));
      await tester.pumpAndSettle();
      await _enter(tester, 'agent-settings-key', 'one-time-model-key');
      await _tap(tester, 'agent-settings-load-models');
      expect(port.loadCalls.single.key, 'one-time-model-key');
      expect(_keyField(tester).controller!.text, isEmpty);

      await _tap(tester, 'agent-settings-model');
      await tester.tap(find.text('model-a').last);
      await tester.pumpAndSettle();
      expect(
        _button(tester, 'agent-settings-verify-save').onPressed,
        isNotNull,
      );
      await _tap(tester, 'agent-settings-verify-save');
      expect(port.verifyCalls.single.key, isEmpty);
      expect(port.verifyCalls.single.modelId, 'model-a');
      expect(port.verifyCalls.single.consent, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'clearing history does not continue after the page is unmounted',
    (tester) async {
      final port = _FakeAgentPort(
        view: _view(
          conversations: [_conversation('conversation-a', '当前对话')],
          conversationId: 'conversation-a',
        ),
      );
      final pageVisible = ValueNotifier(true);
      addTearDown(port.dispose);
      addTearDown(pageVisible.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: pageVisible,
              builder: (context, visible, _) => visible
                  ? AgentWorkspacePage(controller: port, onSettings: () {})
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('agent-history-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清除当前对话…'));
      await tester.pumpAndSettle();
      expect(find.text('清除当前对话？'), findsOneWidget);

      pageVisible.value = false;
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('agent-history-clear-first-confirm')),
      );
      await tester.pumpAndSettle();

      expect(find.text('再确认一次'), findsNothing);
      expect(port.clearCalls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'saved model consent can be revoked and renewed without deleting its key',
    (tester) async {
      final port = _FakeAgentPort(
        view: _view(
          settings: _settings(
            keySaved: true,
            consent: true,
            modelId: 'model-a',
            report: const AgentCapabilityReport(text: true, streaming: true),
          ),
        ),
      );
      addTearDown(port.dispose);
      await tester.pumpWidget(_host(AgentSettingsPanel(controller: port)));
      await tester.pumpAndSettle();
      await _tap(tester, 'agent-settings-consent');
      expect(port.consentCalls, [false]);
      expect(port.view.canSend, isFalse);
      expect(port.view.settings!.keySaved, isTrue);
      await _tap(tester, 'agent-settings-consent');
      expect(port.consentCalls, [false, true]);
      expect(port.view.canSend, isTrue);
      expect(port.deleteKeyCalls, 0);
    },
  );

  testWidgets('narrow chat and settings layouts remain within the viewport', (
    tester,
  ) async {
    await _setSize(tester, const Size(360, 720));
    final port = _FakeAgentPort(
      view: _view(
        settings: _settings(keySaved: true, consent: true, modelId: 'model-a'),
        conversationId: 'conversation-a',
        conversations: [
          _conversation('conversation-a', '当前对话'),
          _conversation('conversation-b', '另一个对话'),
        ],
      ),
    );
    addTearDown(port.dispose);

    await tester.pumpWidget(
      _host(AgentWorkspacePage(controller: port, onSettings: () {})),
    );
    await tester.pumpAndSettle();
    await _tap(tester, 'agent-sessions-toggle');
    expect(
      find.byKey(const ValueKey('agent-conversation-list')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(_host(AgentSettingsPanel(controller: port)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('agent-settings-panel')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(
    body: SafeArea(
      child: Padding(padding: const EdgeInsets.all(12), child: child),
    ),
  ),
);

AgentSettingsSnapshot _settings({
  required bool keySaved,
  required bool consent,
  String? modelId,
  List<String> modelIds = const [],
  AgentCapabilityReport report = const AgentCapabilityReport(),
}) => AgentSettingsSnapshot(
  authority: const AgentAuthority(
    owner: 'owner',
    resetEpoch: 1,
    historyEpoch: 1,
    configRevision: 1,
  ),
  keySaved: keySaved,
  consent: consent,
  modelId: modelId,
  modelIds: modelIds,
  report: report,
);

AgentConversation _conversation(String id, String title) => AgentConversation(
  id: id,
  title: title,
  updatedAtUtc: DateTime.utc(2026, 10, 13),
);

AgentWorkspaceView _view({
  AgentPhase phase = AgentPhase.idle,
  AgentSettingsSnapshot? settings,
  List<String> availableModels = const [],
  List<AgentConversation> conversations = const [],
  List<AgentMessage> messages = const [],
  String? conversationId,
  AgentFailureCode? failure,
  AgentCapabilityReport report = const AgentCapabilityReport(),
  bool historyTruncated = false,
  bool pendingKeyProvided = false,
  bool businessToolsEnabled = false,
  String? activeTool,
  int toolCalls = 0,
  int modelCalls = 0,
}) => AgentWorkspaceView(
  phase: phase,
  settings: settings,
  availableModels: availableModels,
  conversations: conversations,
  messages: messages,
  conversationId: conversationId,
  failure: failure,
  report: report,
  historyTruncated: historyTruncated,
  pendingKeyProvided: pendingKeyProvided,
  businessToolsEnabled: businessToolsEnabled,
  activeTool: activeTool,
  toolCalls: toolCalls,
  modelCalls: modelCalls,
);

final class _FakeAgentPort extends ChangeNotifier
    implements AgentWorkspacePort {
  _FakeAgentPort({AgentWorkspaceView? view}) : _view = view ?? _viewDefault();

  AgentWorkspaceView _view;
  @override
  AgentWorkspaceView get view => _view;

  final List<String> sent = [];
  final List<int> sentImageCounts = [];
  List<AgentImage> lastSentImages = const [];
  final List<({String key, bool consent})> loadCalls = [];
  final List<({String key, String modelId, bool consent})> verifyCalls = [];
  Completer<void>? sendGate;
  Object? sendError;
  int stopCalls = 0;
  int deleteKeyCalls = 0;
  final List<bool> consentCalls = [];
  final List<({String? conversationId, bool confirmed})> clearCalls = [];

  void replace(AgentWorkspaceView next) {
    _view = next;
    notifyListeners();
  }

  @override
  Future<void> refresh() async {}

  @override
  Future<void> loadModels({String key = '', required bool consent}) async {
    loadCalls.add((key: key, consent: consent));
    replace(
      _view.copyWithForTest(
        availableModels: const ['model-a'],
        pendingKeyProvided: key.isNotEmpty || _view.pendingKeyProvided,
      ),
    );
  }

  @override
  Future<void> verifyAndSave({
    String key = '',
    required String modelId,
    required bool consent,
  }) async {
    verifyCalls.add((key: key, modelId: modelId, consent: consent));
  }

  @override
  Future<void> newConversation() async {
    const id = 'new-conversation';
    replace(
      _view.copyWithForTest(
        conversationId: id,
        conversations: [..._view.conversations, _conversation(id, '新对话')],
      ),
    );
  }

  @override
  Future<void> selectConversation(String id) async {
    replace(_view.copyWithForTest(conversationId: id));
  }

  @override
  Future<void> send(String text, {List<AgentImage> images = const []}) async {
    sent.add(text);
    sentImageCounts.add(images.length);
    lastSentImages = images;
    if (sendError != null) throw sendError!;
    if (sendGate != null) {
      replace(
        _view.copyWithForTest(
          phase: AgentPhase.generating,
          messages: [
            ..._view.messages,
            AgentMessage(
              id: 99,
              role: AgentMessageRole.assistant,
              text: '',
              status: AgentMessageStatus.streaming,
              createdAtUtc: DateTime.utc(2026, 10, 13),
            ),
          ],
        ),
      );
      await sendGate!.future;
    }
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    replace(_view.copyWithForTest(phase: AgentPhase.idle));
  }

  @override
  Future<void> deleteKey({required bool confirmed}) async {
    if (confirmed) deleteKeyCalls++;
  }

  @override
  Future<void> setModelConsent(bool consent) async {
    consentCalls.add(consent);
    final current = _view.settings!;
    replace(
      _view.copyWithForTest(
        settings: AgentSettingsSnapshot(
          authority: current.authority,
          keySaved: current.keySaved,
          consent: consent,
          modelId: current.modelId,
          modelIds: current.modelIds,
          report: current.report,
        ),
      ),
    );
  }

  @override
  Future<void> clearHistory({
    String? conversationId,
    required bool confirmed,
  }) async {
    clearCalls.add((conversationId: conversationId, confirmed: confirmed));
  }

  @override
  String safeValidationSummary() => 'safe-summary-only';
}

extension on AgentWorkspaceView {
  AgentWorkspaceView copyWithForTest({
    AgentPhase? phase,
    AgentSettingsSnapshot? settings,
    List<String>? availableModels,
    List<AgentConversation>? conversations,
    List<AgentMessage>? messages,
    String? conversationId,
    AgentFailureCode? failure,
    AgentCapabilityReport? report,
    bool? historyTruncated,
    bool? pendingKeyProvided,
    bool? businessToolsEnabled,
    String? activeTool,
    int? toolCalls,
    int? modelCalls,
  }) => AgentWorkspaceView(
    phase: phase ?? this.phase,
    settings: settings ?? this.settings,
    availableModels: availableModels ?? this.availableModels,
    conversations: conversations ?? this.conversations,
    messages: messages ?? this.messages,
    conversationId: conversationId ?? this.conversationId,
    failure: failure ?? this.failure,
    report: report ?? this.report,
    historyTruncated: historyTruncated ?? this.historyTruncated,
    pendingKeyProvided: pendingKeyProvided ?? this.pendingKeyProvided,
    businessToolsEnabled: businessToolsEnabled ?? this.businessToolsEnabled,
    activeTool: activeTool ?? this.activeTool,
    toolCalls: toolCalls ?? this.toolCalls,
    modelCalls: modelCalls ?? this.modelCalls,
  );
}

TextField _keyField(WidgetTester tester) =>
    tester.widget(find.byKey(const ValueKey('agent-settings-key')));

ButtonStyleButton _button(WidgetTester tester, String key) =>
    tester.widget(find.byKey(ValueKey(key)));

Future<void> _setSize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _enter(WidgetTester tester, String key, String value) async {
  final field = find.byKey(ValueKey(key));
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  await tester.enterText(field, value);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

AgentWorkspaceView _viewDefault() => AgentWorkspaceView();

_FakeAgentPort _configuredPort() => _FakeAgentPort(
  view: _view(
    settings: _settings(
      keySaved: true,
      consent: true,
      modelId: 'model-a',
      report: const AgentCapabilityReport(text: true, streaming: true),
    ),
    conversationId: 'conversation-a',
    conversations: [_conversation('conversation-a', '当前对话')],
  ),
);

Uint8List _testPng1x1() => base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL+XwAAAABJRU5ErkJggg==',
);
