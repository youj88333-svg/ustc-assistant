import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/app/agent_behavior_validation.dart';
import 'package:ustc_assistant_m0/app/agent_behavior_validation_panel.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_contract.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_page.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';

const _authority = AgentAuthority(
  owner: 'synthetic-panel-owner',
  resetEpoch: 1,
  historyEpoch: 1,
  configRevision: 1,
);
const _modelId = 'synthetic-panel-model';
const _syntheticKey = 'SYNTHETIC_PANEL_KEY';
const _syntheticReply = '合成回复供人工审查。';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets('panel stays idle until asked and copies only a safe summary', (
    tester,
  ) async {
    final configuration = _ValidationConfiguration(keySaved: false);
    var gatewayFactories = 0;
    final runner = AgentBehaviorValidationRunner(
      modelConfiguration: configuration,
      gatewayFactory: () {
        gatewayFactories++;
        return _SyntheticGateway();
      },
    );
    addTearDown(runner.close);

    String? copiedText;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copiedText =
            (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(_validationHost(runner));
    await _tap(tester, 'open-validation');

    expect(configuration.inspectCalls, 0);
    expect(gatewayFactories, 0);
    expect(find.textContaining('14 个场景'), findsOneWidget);
    expect(find.textContaining('最多 96 次模型请求'), findsOneWidget);
    expect(find.textContaining('只操作内存中的合成课程、日程和任务'), findsOneWidget);
    expect(find.textContaining('产生真实模型用量'), findsOneWidget);
    expect(find.text('用量未知'), findsOneWidget);

    await _tap(tester, 'agent-validation-start');
    await _pumpUntilIdle(tester, runner);
    expect(configuration.inspectCalls, 1);
    expect(gatewayFactories, 0);
    expect(find.text('累计输入 0 · 输出 0 tokens'), findsOneWidget);
    expect(find.textContaining('模型配置或密钥不可用'), findsOneWidget);

    await _tap(tester, 'agent-validation-copy');
    expect(copiedText, runner.safeSummary());
    expect(copiedText, isNot(contains(_syntheticKey)));
    expect(find.text('已复制安全摘要。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'exiting waits for stop to drain and leaves runner caller-owned',
    (tester) async {
      final inspectionGate = Completer<void>();
      final configuration = _ValidationConfiguration(
        inspectionGate: inspectionGate,
      );
      var gatewayFactories = 0;
      final runner = AgentBehaviorValidationRunner(
        modelConfiguration: configuration,
        gatewayFactory: () {
          gatewayFactories++;
          return _SyntheticGateway();
        },
      );
      addTearDown(runner.close);

      await tester.pumpWidget(_validationHost(runner));
      await _tap(tester, 'open-validation');
      await _tap(tester, 'agent-validation-start');
      await configuration.inspectionStarted.future;
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('agent-validation-exit')));
      await tester.pump();
      expect(find.byType(AgentBehaviorValidationPanel), findsOneWidget);

      inspectionGate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(AgentBehaviorValidationPanel), findsNothing);
      expect(runner.view.failure, AgentFailureCode.cancelled);
      expect(gatewayFactories, 0);

      configuration.keySaved = false;
      await runner.start();
      expect(runner.view.failure, AgentFailureCode.keyRequired);
      expect(gatewayFactories, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('completed synthetic results separate checks from reply review', (
    tester,
  ) async {
    final configuration = _ValidationConfiguration();
    final runner = AgentBehaviorValidationRunner(
      modelConfiguration: configuration,
      gatewayFactory: _SyntheticGateway.new,
    );
    addTearDown(runner.close);

    await tester.pumpWidget(_validationHost(runner));
    await _tap(tester, 'open-validation');
    // NativeDatabase.memory performs real asynchronous work. Keep the model
    // fake, but let the runner finish outside testWidgets' fake-time zone.
    await tester.runAsync(
      () => runner.start().timeout(const Duration(seconds: 30)),
    );
    await tester.pump();

    expect(runner.view.busy, isFalse);
    expect(
      runner.view.results,
      hasLength(AgentBehaviorValidationRunner.caseCount),
    );
    expect(runner.view.inputTokens, isNotNull);
    expect(runner.view.outputTokens, isNotNull);
    final personalRead = runner.view.results.singleWhere(
      (result) => result.scenario == AgentBehaviorCase.personalRead,
    );
    expect(personalRead.businessPassed, isFalse);
    expect(personalRead.constraintPassed, isTrue);
    expect(find.textContaining('业务结果：'), findsWidgets);
    expect(find.textContaining('约束结果：'), findsWidgets);
    expect(find.textContaining('合成回复（供人工判断）'), findsWidgets);
    expect(find.textContaining(_syntheticReply), findsWidgets);
    expect(find.textContaining('回复质量需人工判断'), findsWidgets);
    expect(find.textContaining('累计输入'), findsOneWidget);
    final safeSummary = runner.safeSummary();
    expect(safeSummary, contains('"syntheticOnly":true'));
    expect(safeSummary, isNot(contains(_syntheticReply)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('workspace entry only invokes its explicit open callback', (
    tester,
  ) async {
    final workspace = _WorkspaceStub();
    addTearDown(workspace.dispose);
    var callbackCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: SizedBox.expand(
              child: AgentWorkspacePage(
                controller: workspace,
                onSettings: () {},
                onModelValidation: () => callbackCalls++,
              ),
            ),
          ),
        ),
      ),
    );
    await _tap(tester, 'agent-settings-open');
    await _tap(tester, 'agent-model-validation-expand');

    expect(callbackCalls, 0);
    await _tap(tester, 'agent-model-validation-open');

    expect(callbackCalls, 1);
    expect(tester.takeException(), isNull);
  });
}

Widget _validationHost(AgentBehaviorValidationRunner runner) => MaterialApp(
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: TextButton(
          key: const ValueKey('open-validation'),
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => Scaffold(
                body: SafeArea(
                  child: AgentBehaviorValidationPanel(runner: runner),
                ),
              ),
            ),
          ),
          child: const Text('打开核验'),
        ),
      ),
    ),
  ),
);

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  if (key == 'agent-validation-start') {
    await tester.pump();
  } else {
    await tester.pumpAndSettle();
  }
}

Future<void> _pumpUntilIdle(
  WidgetTester tester,
  AgentBehaviorValidationRunner runner,
) async {
  for (var i = 0; i < 40 && runner.view.busy; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump();
}

final class _ValidationConfiguration implements AgentDataPort {
  _ValidationConfiguration({this.keySaved = true, this.inspectionGate});

  bool keySaved;
  final Completer<void>? inspectionGate;
  final Completer<void> inspectionStarted = Completer<void>();
  int inspectCalls = 0;

  @override
  Future<AgentSettingsSnapshot> inspectAgent() async {
    inspectCalls++;
    if (!inspectionStarted.isCompleted) inspectionStarted.complete();
    await inspectionGate?.future;
    return AgentSettingsSnapshot(
      authority: _authority,
      keySaved: keySaved,
      consent: true,
      modelId: _modelId,
      report: const AgentCapabilityReport(
        text: true,
        streaming: true,
        toolCall: true,
        toolResult: true,
      ),
    );
  }

  @override
  Future<ModelSecretLease> leaseModelKey(AgentAuthority expected) async {
    if (expected != _authority) throw StateError('Unexpected synthetic owner.');
    return ModelSecretLease(Uint8List.fromList(_syntheticKey.codeUnits));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _SyntheticGateway implements ModelGatewayPort {
  @override
  Future<List<String>> listModels(ModelSecretLease secret) async {
    secret.revoke();
    return const [_modelId];
  }

  @override
  Stream<ModelEvent> generate(
    ModelRequest request,
    ModelSecretLease secret,
  ) async* {
    final key = secret.take();
    key.fillRange(0, key.length, 0);
    yield const ModelTextDelta(_syntheticReply);
    yield ModelCompleted(finishReason: 'stop', inputTokens: 8, outputTokens: 5);
  }

  @override
  Future<void> cancelAndDrain() async {}

  @override
  Future<void> close() async {}
}

final class _WorkspaceStub extends ChangeNotifier
    implements AgentWorkspacePort, AgentWorkspaceUsePolicyPort {
  @override
  AgentRuntimeView get view => AgentRuntimeView(
    settings: AgentSettingsSnapshot(
      authority: _authority,
      keySaved: true,
      consent: true,
      modelId: _modelId,
      report: const AgentCapabilityReport(
        text: true,
        streaming: true,
        toolCall: true,
        toolResult: true,
      ),
    ),
    conversationId: 'synthetic-conversation',
  );

  @override
  Future<void> refresh() async {}

  @override
  Future<void> saveUsePolicy({
    required bool personalContentAllowed,
    required bool dailyOperationsAllowed,
  }) async {}

  @override
  Future<void> setAdviceOnly(bool value) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
