import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_contract.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_page.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/speech_input_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets('stop inserts a local transcript at the captured cursor', (
    tester,
  ) async {
    final agent = _FakeAgentPort();
    final speech = _FakeSpeechInputPort();
    addTearDown(agent.dispose);
    addTearDown(speech.dispose);
    await _mount(
      tester,
      agent,
      speech,
      pickImages: () async => [AgentImage(_testPng())],
    );
    await tester.tap(find.byKey(const ValueKey('agent-attach-image')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('agent-image-preview-0')), findsOneWidget);

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('agent-composer')),
    );
    field.controller!.value = const TextEditingValue(
      text: 'ABCxyz',
      selection: TextSelection.collapsed(offset: 3),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('agent-speech-toggle')));
    await tester.pump();
    expect(speech.startCalls, 1);
    expect(find.textContaining('正在录音'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('agent-speech-toggle')));
    await tester.pump();
    expect(speech.finishCalls, 1);
    expect(find.text('正在识别…'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('agent-send')))
          .onPressed,
      isNull,
    );

    speech.complete('听写');
    await tester.pumpAndSettle();
    expect(field.controller!.text, 'ABC听写xyz');
    expect(agent.sent, isEmpty);
    expect(find.byKey(const ValueKey('agent-image-preview-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('agent-speech-status')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('agent-send')));
    await tester.pumpAndSettle();
    expect(agent.sent, ['ABC听写xyz']);
    expect(agent.sentImageCounts, [1]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('local dictation starts without an Agent key and never sends', (
    tester,
  ) async {
    final agent = _FakeAgentPort(keySaved: false, consent: false);
    final speech = _FakeSpeechInputPort();
    addTearDown(agent.dispose);
    addTearDown(speech.dispose);
    await _mount(tester, agent, speech);

    await tester.tap(find.byKey(const ValueKey('agent-speech-toggle')));
    await tester.pump();
    expect(speech.startCalls, 1);
    expect(agent.sent, isEmpty);
    speech.complete('本地听写内容');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('agent-composer')))
          .controller!
          .text,
      '本地听写内容',
    );
    expect(agent.sent, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('30 second auto-stop recognizes without a second stop tap', (
    tester,
  ) async {
    final agent = _FakeAgentPort();
    final speech = _FakeSpeechInputPort();
    addTearDown(agent.dispose);
    addTearDown(speech.dispose);
    await _mount(tester, agent, speech);

    await tester.tap(find.byKey(const ValueKey('agent-speech-toggle')));
    await tester.pump();
    speech.autoStopAtLimit();
    await tester.pump();
    expect(find.textContaining('00:30'), findsOneWidget);
    speech.enterRecognition();
    await tester.pump();
    expect(find.text('正在识别…'), findsOneWidget);
    expect(speech.finishCalls, 0);
    speech.complete('三十秒结果');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('agent-composer')))
          .controller!
          .text,
      '三十秒结果',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'editing the draft cancels recognition and rejects a late result',
    (tester) async {
      final agent = _FakeAgentPort();
      final speech = _FakeSpeechInputPort();
      addTearDown(agent.dispose);
      addTearDown(speech.dispose);
      await _mount(tester, agent, speech);

      await _startRecording(tester);
      await tester.enterText(
        find.byKey(const ValueKey('agent-composer')),
        '新的键盘文字',
      );
      await tester.pump();
      expect(speech.cancelCalls, 1);
      speech.lateResult('迟到文字');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('agent-composer')))
            .controller!
            .text,
        '新的键盘文字',
      );
      expect(agent.sent, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancel control revokes delivery before a late result', (
    tester,
  ) async {
    final agent = _FakeAgentPort();
    final speech = _FakeSpeechInputPort();
    addTearDown(agent.dispose);
    addTearDown(speech.dispose);
    await _mount(tester, agent, speech);
    await _startRecording(tester);

    await tester.tap(find.byKey(const ValueKey('agent-speech-cancel')));
    await tester.pumpAndSettle();
    expect(speech.cancelCalls, 1);
    speech.lateResult('已取消的结果');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('agent-composer')))
          .controller!
          .text,
      isEmpty,
    );
    expect(agent.sent, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'conversation, history, and maintenance changes cancel the capture',
    (tester) async {
      final agent = _FakeAgentPort();
      final speech = _FakeSpeechInputPort();
      addTearDown(agent.dispose);
      addTearDown(speech.dispose);
      await _mount(tester, agent, speech);
      await _startRecording(tester);

      agent.replace(
        agent.view.copyWithForTest(conversationId: 'conversation-b'),
      );
      await tester.pump();
      expect(speech.cancelCalls, 1);
      speech.lateResult('旧对话转写');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('agent-composer')))
            .controller!
            .text,
        isEmpty,
      );

      await _startRecording(tester);
      agent.replace(
        agent.view.copyWithForTest(settings: _settings(historyEpoch: 2)),
      );
      await tester.pump();
      expect(speech.cancelCalls, 2);
      speech.lateResult('旧历史转写');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('agent-composer')))
            .controller!
            .text,
        isEmpty,
      );

      await _startRecording(tester);
      agent.replace(agent.view.copyWithForTest(phase: AgentPhase.maintenance));
      await tester.pump();
      expect(speech.cancelCalls, 3);
      speech.lateResult('维护期间的旧转写');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('agent-composer')))
            .controller!
            .text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('replacing the speech port revokes the old result', (
    tester,
  ) async {
    final agent = _FakeAgentPort();
    final oldSpeech = _FakeSpeechInputPort();
    final newSpeech = _FakeSpeechInputPort();
    addTearDown(agent.dispose);
    addTearDown(oldSpeech.dispose);
    addTearDown(newSpeech.dispose);
    await _mount(tester, agent, oldSpeech);
    await _startRecording(tester);

    await tester.pumpWidget(_host(agent, newSpeech));
    await tester.pumpAndSettle();
    expect(oldSpeech.cancelCalls, 1);
    oldSpeech.lateResult('旧端口结果');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('agent-composer')))
          .controller!
          .text,
      isEmpty,
    );
    expect(oldSpeech.closeCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('replacing the Agent controller revokes the old result', (
    tester,
  ) async {
    final oldAgent = _FakeAgentPort();
    final newAgent = _FakeAgentPort();
    final speech = _FakeSpeechInputPort();
    addTearDown(oldAgent.dispose);
    addTearDown(newAgent.dispose);
    addTearDown(speech.dispose);
    await _mount(tester, oldAgent, speech);
    await _startRecording(tester);

    await tester.pumpWidget(_host(newAgent, speech));
    await tester.pumpAndSettle();
    expect(speech.cancelCalls, 1);
    speech.lateResult('旧控制器结果');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('agent-composer')))
          .controller!
          .text,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('dispose cancels without closing the caller-owned port', (
    tester,
  ) async {
    final agent = _FakeAgentPort();
    final speech = _FakeSpeechInputPort();
    addTearDown(agent.dispose);
    addTearDown(speech.dispose);
    await _mount(tester, agent, speech);
    await _startRecording(tester);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(speech.cancelCalls, 1);
    speech.lateResult('页面已离开');
    await tester.pump();
    expect(speech.closeCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inactive lifecycle cancels and rejects late dictation', (
    tester,
  ) async {
    final agent = _FakeAgentPort();
    final speech = _FakeSpeechInputPort();
    addTearDown(agent.dispose);
    addTearDown(speech.dispose);
    await _mount(tester, agent, speech);
    await _startRecording(tester);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(speech.cancelCalls, 1);
    speech.lateResult('切到后台后的旧结果');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('agent-composer')))
          .controller!
          .text,
      isEmpty,
    );
    expect(speech.closeCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recognition failure preserves the draft and keyboard sending', (
    tester,
  ) async {
    final agent = _FakeAgentPort();
    final speech = _FakeSpeechInputPort();
    addTearDown(agent.dispose);
    addTearDown(speech.dispose);
    await _mount(tester, agent, speech);
    await tester.enterText(
      find.byKey(const ValueKey('agent-composer')),
      '原有草稿',
    );
    await tester.pump();

    await _startRecording(tester);
    speech.fail(SpeechInputFailureCode.permissionDenied);
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('agent-composer')),
    );
    expect(field.controller!.text, '原有草稿');
    expect(find.text('未获得麦克风权限，可继续键盘输入。'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('agent-send')));
    await tester.pumpAndSettle();
    expect(agent.sent, ['原有草稿']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('320 pixel composer has no overflow with speech enabled', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final agent = _FakeAgentPort();
    final speech = _FakeSpeechInputPort();
    addTearDown(agent.dispose);
    addTearDown(speech.dispose);
    await _mount(tester, agent, speech);
    expect(find.byKey(const ValueKey('agent-speech-toggle')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('agent-composer')),
      '窄屏输入',
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

Future<void> _mount(
  WidgetTester tester,
  _FakeAgentPort agent,
  _FakeSpeechInputPort speech, {
  Future<List<AgentImage>> Function()? pickImages,
}) async {
  await tester.pumpWidget(_host(agent, speech, pickImages: pickImages));
  await tester.pumpAndSettle();
}

Future<void> _startRecording(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('agent-speech-toggle')));
  await tester.pump();
  expect(find.textContaining('正在录音'), findsOneWidget);
}

Widget _host(
  _FakeAgentPort agent,
  _FakeSpeechInputPort speech, {
  Future<List<AgentImage>> Function()? pickImages,
}) => MaterialApp(
  home: Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: AgentWorkspacePage(
          controller: agent,
          speechInput: speech,
          pickImages: pickImages,
          onSettings: () {},
        ),
      ),
    ),
  ),
);

AgentSettingsSnapshot _settings({
  int historyEpoch = 1,
  bool keySaved = true,
  bool consent = true,
}) => AgentSettingsSnapshot(
  authority: AgentAuthority(
    owner: 'owner',
    resetEpoch: 1,
    historyEpoch: historyEpoch,
    configRevision: 1,
  ),
  keySaved: keySaved,
  consent: consent,
  modelId: keySaved ? 'model-a' : null,
  report: const AgentCapabilityReport(text: true, streaming: true),
);

AgentRuntimeView _agentView({
  AgentPhase phase = AgentPhase.idle,
  String conversationId = 'conversation-a',
  int historyEpoch = 1,
  bool keySaved = true,
  bool consent = true,
}) => AgentRuntimeView(
  phase: phase,
  settings: _settings(
    historyEpoch: historyEpoch,
    keySaved: keySaved,
    consent: consent,
  ),
  conversationId: conversationId,
  conversations: [
    AgentConversation(
      id: conversationId,
      title: '当前对话',
      updatedAtUtc: DateTime.utc(2026, 10, 14),
    ),
  ],
);

class _FakeAgentPort extends ChangeNotifier implements AgentWorkspacePort {
  _FakeAgentPort({bool keySaved = true, bool consent = true})
    : _view = _agentView(keySaved: keySaved, consent: consent);

  AgentRuntimeView _view;
  @override
  AgentRuntimeView get view => _view;
  final List<String> sent = [];
  final List<int> sentImageCounts = [];

  void replace(AgentRuntimeView view) {
    _view = view;
    notifyListeners();
  }

  @override
  Future<void> refresh() async {}
  @override
  Future<void> loadModels({String key = '', required bool consent}) async {}
  @override
  Future<void> verifyAndSave({
    String key = '',
    required String modelId,
    required bool consent,
  }) async {}
  @override
  Future<void> newConversation() async {}
  @override
  Future<void> selectConversation(String id) async {}
  @override
  Future<void> send(String text, {List<AgentImage> images = const []}) async {
    sent.add(text);
    sentImageCounts.add(images.length);
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> deleteKey({required bool confirmed}) async {}
  @override
  Future<void> setModelConsent(bool consent) async {}
  @override
  Future<void> clearHistory({
    String? conversationId,
    required bool confirmed,
  }) async {}
  @override
  String safeValidationSummary() => 'safe';
}

extension on AgentRuntimeView {
  AgentRuntimeView copyWithForTest({
    AgentPhase? phase,
    AgentSettingsSnapshot? settings,
    String? conversationId,
  }) => AgentRuntimeView(
    phase: phase ?? this.phase,
    settings: settings ?? this.settings,
    conversations: conversationId == null
        ? conversations
        : [
            AgentConversation(
              id: conversationId,
              title: '切换后的对话',
              updatedAtUtc: DateTime.utc(2026, 10, 14),
            ),
          ],
    conversationId: conversationId ?? this.conversationId,
  );
}

class _FakeSpeechInputPort implements SpeechInputPort {
  final StreamController<SpeechInputView> _changes =
      StreamController<SpeechInputView>.broadcast(sync: true);
  SpeechInputView _view = const SpeechInputView();
  int _revision = 0;
  int _startedRevision = 0;
  int startCalls = 0;
  int finishCalls = 0;
  int cancelCalls = 0;
  int closeCalls = 0;

  @override
  SpeechInputView get view => _view;
  @override
  Stream<SpeechInputView> get changes => _changes.stream;

  void _emit(SpeechInputView view) {
    _view = view;
    _changes.add(view);
  }

  @override
  Future<void> start() async {
    startCalls++;
    _revision++;
    _startedRevision = _revision;
    _emit(
      SpeechInputView(phase: SpeechInputPhase.preparing, revision: _revision),
    );
    _emit(
      SpeechInputView(phase: SpeechInputPhase.recording, revision: _revision),
    );
  }

  @override
  Future<void> finish() async {
    finishCalls++;
    _emit(
      SpeechInputView(phase: SpeechInputPhase.stopping, revision: _revision),
    );
    _emit(
      SpeechInputView(phase: SpeechInputPhase.recognizing, revision: _revision),
    );
  }

  void autoStopAtLimit() {
    _emit(
      SpeechInputView(
        phase: SpeechInputPhase.stopping,
        revision: _revision,
        elapsedMilliseconds: speechMaximumSeconds * 1000,
      ),
    );
  }

  void enterRecognition() {
    _emit(
      SpeechInputView(
        phase: SpeechInputPhase.recognizing,
        revision: _revision,
        elapsedMilliseconds: speechMaximumSeconds * 1000,
      ),
    );
  }

  void complete(String text) {
    _emit(
      SpeechInputView(
        revision: _revision,
        transcript: SpeechTranscript(revision: _revision, text: text),
      ),
    );
  }

  void lateResult(String text) {
    _emit(
      SpeechInputView(
        revision: _revision,
        transcript: SpeechTranscript(revision: _startedRevision, text: text),
      ),
    );
  }

  void fail(SpeechInputFailureCode failure) =>
      _emit(SpeechInputView(revision: _revision, failure: failure));

  @override
  Future<void> cancel() async {
    cancelCalls++;
    _revision++;
    _emit(
      SpeechInputView(phase: SpeechInputPhase.cancelling, revision: _revision),
    );
    _emit(SpeechInputView(revision: _revision));
  }

  @override
  Future<void> close() async {
    closeCalls++;
    _emit(SpeechInputView(phase: SpeechInputPhase.closed, revision: _revision));
  }

  Future<void> dispose() => _changes.close();
}

Uint8List _testPng() => base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL+XwAAAABJRU5ErkJggg==',
);
