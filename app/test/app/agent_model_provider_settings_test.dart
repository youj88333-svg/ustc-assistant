import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/agent_settings_panel.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets('provider switch resets drafts and isolates visible settings', (
    tester,
  ) async {
    final port = _ProviderSettingsPort();
    final refreshGate = Completer<void>();
    final selectGate = Completer<void>();
    port.refreshGate = refreshGate;
    port.selectGate = selectGate;
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(AgentSettingsPanel(controller: port)));
    await tester.pump();
    expect(port.refreshCalls, 1);

    await tester.enterText(
      find.byKey(const ValueKey('agent-settings-key')),
      'synthetic-school-key',
    );
    await tester.tap(find.byKey(const ValueKey('agent-settings-consent')));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('agent-settings-key')))
          .controller!
          .text,
      'synthetic-school-key',
    );

    await tester.tap(
      find.byKey(const ValueKey('agent-settings-provider-school')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('DeepSeek 官方'));
    await tester.pump();

    expect(port.selectedProviders, [ModelProvider.deepseek]);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('agent-settings-key')))
          .controller!
          .text,
      isEmpty,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('agent-settings-key')))
          .enabled,
      isFalse,
    );
    expect(find.text('固定目的地：https://api.deepseek.com/'), findsOneWidget);
    expect(find.text('直答模式：减少等待，工具调用照常使用。'), findsOneWidget);
    expect(find.text('我已了解并同意按上述说明发送必要内容'), findsOneWidget);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey('agent-settings-consent')),
          )
          .value,
      isFalse,
    );

    selectGate.complete();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('agent-settings-provider-deepseek')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('agent-settings-model-deepseek')),
      findsOneWidget,
    );
    expect(find.text('school-model-synthetic'), findsNothing);
    expect(find.textContaining('DeepSeek 官方账号独立计费'), findsWidgets);
    expect(find.textContaining('api.deepseek.com'), findsWidgets);

    refreshGate.completeError(StateError('synthetic stale refresh failure'));
    await tester.pumpAndSettle();
    expect(find.text('暂时无法读取 Agent 设置，请稍后重试。'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy workspace ports do not show provider selection', (
    tester,
  ) async {
    final port = _LegacySettingsPort();
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(AgentSettingsPanel(controller: port)));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('agent-settings-provider-school')),
      findsNothing,
    );
    expect(find.text('学校模型服务'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('external provider publication clears all provider drafts', (
    tester,
  ) async {
    final port = _ProviderSettingsPort();
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(AgentSettingsPanel(controller: port)));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('agent-settings-key')),
      'synthetic-school-key',
    );
    await tester.tap(find.byTooltip('显示 Key'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('agent-settings-consent')));
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const ValueKey('agent-settings-model-school')),
    );
    await tester.tap(find.byKey(const ValueKey('agent-settings-model-school')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('school-model-draft'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('agent-settings-key')))
          .obscureText,
      isFalse,
    );
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey('agent-settings-consent')),
          )
          .value,
      isTrue,
    );

    port.publishProvider(
      ModelProvider.deepseek,
      models: const ['deepseek-model-external-synthetic'],
      configRevision: 2,
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('agent-settings-provider-deepseek')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('agent-settings-key')))
          .controller!
          .text,
      isEmpty,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('agent-settings-key')))
          .obscureText,
      isTrue,
    );
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey('agent-settings-consent')),
          )
          .value,
      isFalse,
    );
    expect(find.text('school-model-synthetic'), findsNothing);
    expect(find.text('school-model-draft'), findsNothing);
    expect(port.loadCalls, 0);
    expect(port.verifyCalls, 0);

    await tester.ensureVisible(
      find.byKey(const ValueKey('agent-settings-model-deepseek')),
    );
    await tester.tap(
      find.byKey(const ValueKey('agent-settings-model-deepseek')),
    );
    await tester.pumpAndSettle();
    expect(find.text('deepseek-model-external-synthetic'), findsOneWidget);
    expect(find.text('school-model-draft'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('provider and key controls remain usable on compact layouts', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const scenarios = <({String name, Size size, TextScaler? textScaler})>[
      (name: 'portrait', size: Size(375, 812), textScaler: null),
      (name: 'landscape', size: Size(812, 375), textScaler: null),
      (
        name: 'large text',
        size: Size(375, 812),
        textScaler: TextScaler.linear(2),
      ),
    ];

    for (final scenario in scenarios) {
      tester.view.physicalSize = scenario.size;
      final port = _ProviderSettingsPort();
      addTearDown(port.dispose);
      await tester.pumpWidget(
        _host(
          AgentSettingsPanel(controller: port),
          textScaler: scenario.textScaler,
        ),
      );
      await tester.pumpAndSettle();

      final settings = find.byKey(const ValueKey('agent-settings-panel'));
      final scrollable = find
          .descendant(of: settings, matching: find.byType(Scrollable))
          .first;
      final provider = find.byKey(
        const ValueKey('agent-settings-provider-school'),
      );
      await tester.scrollUntilVisible(provider, 180, scrollable: scrollable);
      await tester.pumpAndSettle();
      _expectFullyVisible(tester, provider, scrollable, scenario.name);
      expect(
        tester
            .widget<DropdownButtonFormField<ModelProvider>>(provider)
            .onChanged,
        isNotNull,
        reason: '${scenario.name}: provider selection should be enabled',
      );

      await tester.tap(provider);
      await tester.pumpAndSettle();
      expect(find.text('DeepSeek 官方'), findsOneWidget);
      await tester.tap(find.text('学校模型服务').last);
      await tester.pumpAndSettle();

      final keyField = find.byKey(const ValueKey('agent-settings-key'));
      await tester.scrollUntilVisible(keyField, 180, scrollable: scrollable);
      await tester.pumpAndSettle();
      _expectFullyVisible(tester, keyField, scrollable, scenario.name);
      expect(
        tester.widget<TextField>(keyField).enabled,
        isTrue,
        reason: '${scenario.name}: model key input should be enabled',
      );
      final syntheticKey = 'synthetic-${scenario.name.replaceAll(' ', '-')}';
      await tester.enterText(keyField, syntheticKey);
      await tester.pump();
      expect(tester.widget<TextField>(keyField).controller!.text, syntheticKey);
      expect(tester.takeException(), isNull, reason: scenario.name);
    }
  });
}

Widget _host(Widget child, {TextScaler? textScaler}) => MaterialApp(
  theme: ThemeData(useMaterial3: true),
  builder: textScaler == null
      ? null
      : (context, routedChild) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: routedChild!,
        ),
  home: Scaffold(body: SafeArea(child: child)),
);

void _expectFullyVisible(
  WidgetTester tester,
  Finder target,
  Finder scrollable,
  String scenario,
) {
  final viewport = tester.getRect(scrollable);
  final control = tester.getRect(target);
  expect(
    control.top,
    greaterThanOrEqualTo(viewport.top - 1),
    reason: '$scenario: control should be inside the settings viewport',
  );
  expect(
    control.bottom,
    lessThanOrEqualTo(viewport.bottom + 1),
    reason: '$scenario: control should be inside the settings viewport',
  );
}

AgentWorkspaceView _viewFor(
  ModelProvider provider, {
  List<String> models = const [],
  String? modelId,
  bool keySaved = false,
  bool consent = false,
  String owner = 'synthetic-owner',
  int resetEpoch = 1,
  int configRevision = 1,
}) => AgentWorkspaceView(
  settings: AgentSettingsSnapshot(
    authority: AgentAuthority(
      owner: owner,
      resetEpoch: resetEpoch,
      historyEpoch: 1,
      configRevision: configRevision,
    ),
    provider: provider,
    modelIds: models,
    modelId: modelId,
    keySaved: keySaved,
    consent: consent,
  ),
  availableModels: models,
);

class _LegacySettingsPort extends ChangeNotifier implements AgentWorkspacePort {
  AgentWorkspaceView _view = _viewFor(
    ModelProvider.school,
    models: const ['school-model-synthetic', 'school-model-draft'],
    modelId: 'school-model-synthetic',
  );

  @override
  AgentWorkspaceView get view => _view;

  @override
  Future<void> refresh() async {}
  @override
  Future<void> loadModels({String key = '', required bool consent}) async {
    loadCalls++;
  }

  int loadCalls = 0;
  int verifyCalls = 0;

  @override
  Future<void> verifyAndSave({
    String key = '',
    required String modelId,
    required bool consent,
  }) async {
    verifyCalls++;
  }

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
  String safeValidationSummary() => '{}';
}

final class _ProviderSettingsPort extends _LegacySettingsPort
    implements AgentModelProviderWorkspacePort {
  Completer<void>? refreshGate;
  Completer<void>? selectGate;
  int refreshCalls = 0;
  final List<ModelProvider> selectedProviders = [];

  @override
  Future<void> refresh() async {
    refreshCalls++;
    await refreshGate?.future;
  }

  @override
  Future<void> selectModelProvider(ModelProvider provider) async {
    selectedProviders.add(provider);
    await selectGate?.future;
    _view = _viewFor(
      provider,
      models: provider == ModelProvider.deepseek
          ? const ['deepseek-model-synthetic']
          : const ['school-model-synthetic'],
      modelId: null,
    );
    notifyListeners();
  }

  void publishProvider(
    ModelProvider provider, {
    List<String> models = const [],
    int configRevision = 1,
  }) {
    _view = _viewFor(provider, models: models, configRevision: configRevision);
    notifyListeners();
  }
}
