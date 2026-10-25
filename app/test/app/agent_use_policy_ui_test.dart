import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_contract.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_page.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets('policy opt-ins take effect only after explicit save', (
    tester,
  ) async {
    final port = _UsePolicyPort();
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.pumpAndSettle();
    await _tap(tester, 'agent-settings-open');

    expect(find.text('Agent 使用权限'), findsOneWidget);
    expect(find.text('当前为基础模式。勾选所需范围并点击保存后才会启用。'), findsOneWidget);
    expect(find.textContaining('个人记录删除与学校同步/刷新不包含在内。'), findsOneWidget);
    expect(find.textContaining('聊天记录不会删除。'), findsOneWidget);
    expect(port.saveCalls, 0);

    await _tap(tester, 'agent-use-policy-personal-content');
    await _tap(tester, 'agent-use-policy-daily-operations');
    expect(port.saveCalls, 0);

    await _tap(tester, 'agent-use-policy-save');
    await tester.pumpAndSettle();

    expect(port.saveCalls, 1);
    expect(port.personalContent, isTrue);
    expect(port.dailyOperations, isTrue);
    expect(port.view.usePolicyConfigured, isTrue);
    expect(port.clearHistoryCalls, 0);
    expect(find.text('Agent 使用权限'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('waiting approval keeps text continuation usable', (
    tester,
  ) async {
    final port = _UsePolicyPort(phase: AgentPhase.waitingForApproval);
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.pumpAndSettle();

    final composer = tester.widget<TextField>(
      find.byKey(const ValueKey('agent-composer')),
    );
    expect(composer.enabled, isTrue);
    expect(composer.decoration?.hintText, contains('确认 / approve / 取消'));
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('agent-send')))
          .onPressed,
      isNull,
    );
    expect(find.byKey(const ValueKey('agent-stop')), findsOneWidget);

    await _enter(tester, 'agent-composer', '确认');
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('agent-send')))
          .onPressed,
      isNotNull,
    );
    await _tap(tester, 'agent-send');
    expect(port.sentTexts, ['确认']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('waiting reply reaches the still-pending original run', (
    tester,
  ) async {
    final port = _UsePolicyPort(holdFirstSend: true);
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.pumpAndSettle();
    await _enter(tester, 'agent-composer', '安排周五复习');
    await _tap(tester, 'agent-send');

    expect(port.phase, AgentPhase.waitingForApproval);
    expect(port.firstSend?.isCompleted, isFalse);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('agent-composer')))
          .enabled,
      isTrue,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('agent-composer')))
          .controller!
          .text,
      isEmpty,
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('agent-send')))
          .onPressed,
      isNull,
    );

    await _enter(tester, 'agent-composer', '确认');
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('agent-send')))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const ValueKey('agent-send')));
    await tester.pump();

    expect(port.sentTexts, ['安排周五复习', '确认']);
    expect(port.firstSendWasPendingWhenReplyArrived, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('advice-only switch shows the current hard execution policy', (
    tester,
  ) async {
    final port = _UsePolicyPort();
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.pumpAndSettle();
    await _tap(tester, 'agent-advice-only-toggle');

    expect(port.adviceOnly, isTrue);
    expect(find.text('只展示方案，不提交本地操作或刷新学校资料。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Widget _host(_UsePolicyPort port) => MaterialApp(
  home: Scaffold(
    body: SafeArea(
      child: SizedBox.expand(
        child: AgentWorkspacePage(controller: port, onSettings: () {}),
      ),
    ),
  ),
);

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String text) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.enterText(target, text);
  await tester.pumpAndSettle();
}

final class _UsePolicyPort extends ChangeNotifier
    implements AgentWorkspacePort, AgentWorkspaceUsePolicyPort {
  _UsePolicyPort({this.phase = AgentPhase.idle, this.holdFirstSend = false});

  AgentPhase phase;
  final bool holdFirstSend;
  Completer<void>? firstSend;
  bool firstSendWasPendingWhenReplyArrived = false;
  bool usePolicyConfigured = false;
  bool personalContent = false;
  bool dailyOperations = false;
  bool adviceOnly = false;
  final List<String> sentTexts = [];
  int saveCalls = 0;
  int clearHistoryCalls = 0;

  @override
  AgentRuntimeView get view => AgentRuntimeView(
    phase: phase,
    settings: AgentSettingsSnapshot(
      authority: const AgentAuthority(
        owner: 'synthetic-owner',
        resetEpoch: 1,
        historyEpoch: 1,
        configRevision: 1,
      ),
      keySaved: true,
      consent: true,
      modelId: 'synthetic-model',
      report: const AgentCapabilityReport(
        text: true,
        streaming: true,
        toolCall: true,
        toolResult: true,
      ),
    ),
    conversationId: 'synthetic-conversation',
    usePolicyConfigured: usePolicyConfigured,
    personalContentAllowed: personalContent,
    dailyOperationsAllowed: dailyOperations,
    adviceOnly: adviceOnly,
  );

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
  Future<void> send(String text, {List<AgentImage> images = const []}) {
    sentTexts.add(text);
    if (!holdFirstSend) return Future<void>.value();
    if (sentTexts.length == 1) {
      firstSend = Completer<void>();
      phase = AgentPhase.waitingForApproval;
      notifyListeners();
      return firstSend!.future;
    }
    if (sentTexts.length == 2) {
      firstSendWasPendingWhenReplyArrived =
          firstSend != null && !firstSend!.isCompleted;
      phase = AgentPhase.generating;
      notifyListeners();
      firstSend!.complete();
    }
    return Future<void>.value();
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
  }) async {
    clearHistoryCalls++;
  }

  @override
  String safeValidationSummary() => 'synthetic summary';

  @override
  Future<void> saveUsePolicy({
    required bool personalContentAllowed,
    required bool dailyOperationsAllowed,
  }) async {
    saveCalls++;
    usePolicyConfigured = true;
    personalContent = personalContentAllowed;
    dailyOperations = dailyOperationsAllowed;
    notifyListeners();
  }

  @override
  Future<void> setAdviceOnly(bool value) async {
    adviceOnly = value;
    notifyListeners();
  }
}
