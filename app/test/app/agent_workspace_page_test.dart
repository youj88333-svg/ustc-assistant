import 'dart:async';

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
    expect(find.text('正在生成回复'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('agent-stop')));
    await tester.pump();
    expect(port.stopCalls, 1);
    port.sendGate!.complete();
    await tester.pumpAndSettle();
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
);

final class _FakeAgentPort extends ChangeNotifier
    implements AgentWorkspacePort {
  _FakeAgentPort({AgentWorkspaceView? view}) : _view = view ?? _viewDefault();

  AgentWorkspaceView _view;
  @override
  AgentWorkspaceView get view => _view;

  final List<String> sent = [];
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
  Future<void> send(String text) async {
    sent.add(text);
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
