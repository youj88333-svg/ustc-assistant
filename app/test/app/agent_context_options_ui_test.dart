import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_contract.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_page.dart';
import 'package:ustc_assistant_m0/core/agent_context_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets('loads default estimates and saves only after an explicit tap', (
    tester,
  ) async {
    final port = _ContextOptionsPort();
    addTearDown(port.dispose);

    await _openAdvancedBudget(tester, port);

    expect(port.contextReadCalls, 1);
    expect(port.contextSaveCalls, 0);
    expect(
      tester
          .widget<DropdownButtonFormField<int>>(
            find.byKey(const ValueKey('agent-context-input-tokens')),
          )
          .initialValue,
      16000,
    );
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey('agent-context-output-tokens')),
          )
          .initialValue,
      '2048',
    );
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey('agent-context-model-calls')),
          )
          .initialValue,
      '16',
    );
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey('agent-context-tool-calls')),
          )
          .initialValue,
      '48',
    );
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey('agent-context-active-seconds')),
          )
          .initialValue,
      '300',
    );
    expect(find.textContaining('配置值，模型容量未核验。'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('agent-context-input-tokens')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('32,000 tokens'));
    await tester.pumpAndSettle();
    await _enter(tester, 'agent-context-output-tokens', '1536');
    await _enter(tester, 'agent-context-model-calls', '12');
    await _enter(tester, 'agent-context-tool-calls', '24');
    await _enter(tester, 'agent-context-active-seconds', '240');

    expect(port.contextSaveCalls, 0);
    expect(port.policySaveCalls, 0);
    await _tap(tester, 'agent-context-options-save');

    expect(port.contextSaveCalls, 1);
    expect(port.policySaveCalls, 0);
    expect(port.savedOptions?.canonical, [32000, 1536, 12, 24, 240]);
    expect(find.text('上下文预算已保存。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rejects an out-of-range estimate without saving', (
    tester,
  ) async {
    final port = _ContextOptionsPort();
    addTearDown(port.dispose);

    await _openAdvancedBudget(tester, port);
    await _enter(tester, 'agent-context-output-tokens', '8193');
    await _tap(tester, 'agent-context-options-save');

    expect(port.contextSaveCalls, 0);
    expect(find.textContaining('超出范围'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _openAdvancedBudget(
  WidgetTester tester,
  _ContextOptionsPort port,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: SizedBox.expand(
            child: AgentWorkspacePage(controller: port, onSettings: () {}),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await _tap(tester, 'agent-settings-open');
  expect(
    find.byKey(const ValueKey('agent-context-options-expand')),
    findsOneWidget,
  );
  await _tap(tester, 'agent-context-options-expand');
  await tester.pumpAndSettle();
}

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

final class _ContextOptionsPort extends ChangeNotifier
    implements
        AgentWorkspacePort,
        AgentWorkspaceUsePolicyPort,
        AgentContextOptionsWorkspacePort {
  AgentContextOptions contextOptions = const AgentContextOptions();
  AgentContextOptions? savedOptions;
  int contextReadCalls = 0;
  int contextSaveCalls = 0;
  int policySaveCalls = 0;
  bool personalContent = false;
  bool dailyOperations = false;

  @override
  AgentRuntimeView get view => AgentRuntimeView(
    phase: AgentPhase.idle,
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
    personalContentAllowed: personalContent,
    dailyOperationsAllowed: dailyOperations,
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
  Future<void> send(String text, {List<AgentImage> images = const []}) async {}

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
  String safeValidationSummary() => 'synthetic summary';

  @override
  Future<void> saveUsePolicy({
    required bool personalContentAllowed,
    required bool dailyOperationsAllowed,
  }) async {
    policySaveCalls++;
    personalContent = personalContentAllowed;
    dailyOperations = dailyOperationsAllowed;
  }

  @override
  Future<void> setAdviceOnly(bool value) async {}

  @override
  Future<AgentContextOptions> readContextOptions() async {
    contextReadCalls++;
    return contextOptions;
  }

  @override
  Future<void> saveContextOptions(AgentContextOptions options) async {
    contextSaveCalls++;
    contextOptions = options;
    savedOptions = options;
  }
}
