import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/agent_settings_panel.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_contract.dart';
import 'package:ustc_assistant_m0/core/agent_action_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/agent_permission_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets(
    'setup mode shows only model setup and makes no automatic calls',
    (tester) async {
      final port = _SetupPort(keySaved: true, consent: true);
      addTearDown(port.dispose);

      await tester.pumpWidget(
        _setupHost(AgentSettingsPanel(controller: port, setupMode: true)),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('agent-settings-provider-school')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('agent-settings-key')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('agent-settings-consent')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('agent-settings-load-models')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('agent-settings-model-school')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('agent-settings-verify-save')),
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
        find.byKey(const ValueKey('agent-settings-delete-key')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('agent-planning-preferences-panel')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('agent-permissions-empty')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('agent-settings-capability-details')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('agent-settings-copy-summary')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('agent-settings-reasoning-policy')),
        findsNothing,
      );
      expect(port.refreshCalls, 1);
      expect(port.permissionReadCalls, 0);
      expect(port.planningReadCalls, 0);
      expect(port.loadCalls, 0);
      expect(port.verifyCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'setup actions require consent and provider changes clear drafts',
    (tester) async {
      final port = _SetupPort()..refreshGate = Completer<void>();
      addTearDown(port.dispose);

      final busyChanges = <bool>[];
      await tester.pumpWidget(_busySetupHost(port, busyChanges));
      await tester.pumpAndSettle();
      expect(find.text('配置操作进行中'), findsOneWidget);
      expect(busyChanges, contains(true));
      port.refreshGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('配置操作空闲'), findsOneWidget);
      expect(busyChanges.last, isFalse);
      port.refreshGate = null;

      final keyField = find.byKey(const ValueKey('agent-settings-key'));
      final consent = find.byKey(const ValueKey('agent-settings-consent'));
      final load = find.byKey(const ValueKey('agent-settings-load-models'));
      final verify = find.byKey(const ValueKey('agent-settings-verify-save'));

      await tester.enterText(keyField, 'synthetic-setup-key');
      await tester.pump();
      expect(tester.widget<OutlinedButton>(load).onPressed, isNull);
      expect(tester.widget<FilledButton>(verify).onPressed, isNull);
      expect(port.loadCalls, 0);
      expect(port.verifyCalls, 0);

      await tester.tap(consent);
      await tester.pump();
      expect(port.modelConsentChanges, isEmpty);
      expect(tester.widget<OutlinedButton>(load).onPressed, isNotNull);
      expect(tester.widget<FilledButton>(verify).onPressed, isNotNull);

      port.loadGate = Completer<void>();
      await tester.tap(load);
      await tester.pump();
      expect(find.text('配置操作进行中'), findsOneWidget);
      expect(busyChanges, contains(true));
      expect(port.loadCalls, 1);
      port.loadGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('配置操作空闲'), findsOneWidget);
      expect(busyChanges.last, isFalse);
      expect(port.lastLoadedKey, 'synthetic-setup-key');
      expect(port.lastLoadConsent, isTrue);
      expect(tester.widget<TextField>(keyField).controller!.text, isEmpty);
      expect(find.text('模型列表已更新。'), findsOneWidget);

      final model = find.byKey(const ValueKey('agent-settings-model-school'));
      await tester.ensureVisible(model);
      await tester.tap(model);
      await tester.pumpAndSettle();
      await tester.tap(find.text('school-model-loaded'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(keyField);
      await tester.enterText(keyField, 'synthetic-verify-key');
      await tester.pump();
      await tester.ensureVisible(verify);
      await tester.tap(verify);
      await tester.pumpAndSettle();
      expect(port.verifyCalls, 1);
      expect(port.lastVerifiedKey, 'synthetic-verify-key');
      expect(port.lastVerifiedModel, 'school-model-loaded');
      expect(port.lastVerifyConsent, isTrue);
      expect(tester.widget<TextField>(keyField).controller!.text, isEmpty);
      expect(find.text('模型验证与设置已完成。'), findsOneWidget);

      await tester.ensureVisible(keyField);
      await tester.enterText(keyField, 'synthetic-provider-draft');
      final provider = find.byKey(
        const ValueKey('agent-settings-provider-school'),
      );
      await tester.ensureVisible(provider);
      await tester.tap(provider);
      await tester.pumpAndSettle();
      await tester.tap(find.text('DeepSeek 官方').last);
      await tester.pumpAndSettle();

      expect(port.selectedProviders, [ModelProvider.deepseek]);
      expect(tester.widget<TextField>(keyField).controller!.text, isEmpty);
      expect(tester.widget<CheckboxListTile>(consent).value, isFalse);
      expect(port.loadCalls, 1);
      expect(port.verifyCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('default mode retains the existing settings sections', (
    tester,
  ) async {
    final port = _SetupPort(keySaved: true, consent: true);
    addTearDown(port.dispose);

    await tester.pumpWidget(_normalHost(AgentSettingsPanel(controller: port)));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('agent-settings-delete-key')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('agent-settings-reasoning-policy')),
      findsOneWidget,
    );
    final panel = find.byKey(const ValueKey('agent-settings-panel'));
    final scrollable = find
        .descendant(of: panel, matching: find.byType(Scrollable))
        .first;
    final planning = find.byKey(
      const ValueKey('agent-planning-preferences-panel'),
    );
    await tester.scrollUntilVisible(planning, 180, scrollable: scrollable);
    expect(planning, findsOneWidget);
    final emptyPermissions = find.byKey(
      const ValueKey('agent-permissions-empty'),
    );
    await tester.scrollUntilVisible(
      emptyPermissions,
      180,
      scrollable: scrollable,
    );
    expect(
      find.byKey(const ValueKey('agent-permissions-empty')),
      findsOneWidget,
    );
    final capabilities = find.byKey(
      const ValueKey('agent-settings-capability-details'),
    );
    await tester.scrollUntilVisible(capabilities, 180, scrollable: scrollable);
    expect(capabilities, findsOneWidget);
    expect(port.refreshCalls, 1);
    expect(port.permissionReadCalls, 1);
    expect(port.planningReadCalls, 1);
    expect(port.loadCalls, 0);
    expect(port.verifyCalls, 0);
    expect(tester.takeException(), isNull);
  });
}

Widget _setupHost(Widget child) => MaterialApp(
  theme: ThemeData(useMaterial3: true),
  home: Scaffold(
    body: SafeArea(child: SingleChildScrollView(child: child)),
  ),
);

Widget _busySetupHost(_SetupPort port, List<bool> busyChanges) {
  var busy = false;
  return MaterialApp(
    theme: ThemeData(useMaterial3: true),
    home: StatefulBuilder(
      builder: (context, setState) => Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  busy ? '配置操作进行中' : '配置操作空闲',
                  key: const ValueKey('setup-parent-busy-state'),
                ),
                AgentSettingsPanel(
                  controller: port,
                  setupMode: true,
                  onBusyChanged: (value) {
                    busyChanges.add(value);
                    if (busy != value) setState(() => busy = value);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _normalHost(Widget child) => MaterialApp(
  theme: ThemeData(useMaterial3: true),
  home: Scaffold(body: SafeArea(child: child)),
);

final class _SetupPort extends ChangeNotifier
    implements
        AgentWorkspacePort,
        AgentModelProviderWorkspacePort,
        AgentPermissionWorkspacePort,
        AgentPreferencesWorkspacePort {
  _SetupPort({bool keySaved = false, bool consent = false})
    // Preserve the public synthetic fixture names used by these tests.
    // ignore: prefer_initializing_formals
    : _keySaved = keySaved,
      // ignore: prefer_initializing_formals
      _consent = consent {
    _publish();
  }

  ModelProvider _provider = ModelProvider.school;
  bool _keySaved;
  bool _consent;
  bool _pendingKeyProvided = false;
  int _configRevision = 1;
  List<String> _models = const ['school-model-initial'];
  String? _modelId = 'school-model-initial';
  late AgentWorkspaceView _view;

  int refreshCalls = 0;
  int permissionReadCalls = 0;
  int planningReadCalls = 0;
  int loadCalls = 0;
  int verifyCalls = 0;
  final List<bool> modelConsentChanges = [];
  final List<ModelProvider> selectedProviders = [];
  String? lastLoadedKey;
  bool? lastLoadConsent;
  String? lastVerifiedKey;
  String? lastVerifiedModel;
  bool? lastVerifyConsent;
  Completer<void>? refreshGate;
  Completer<void>? loadGate;

  @override
  AgentWorkspaceView get view => _view;

  void _publish() {
    _view = AgentRuntimeView(
      settings: AgentSettingsSnapshot(
        authority: AgentAuthority(
          owner: 'synthetic-setup-owner',
          resetEpoch: 1,
          historyEpoch: 1,
          configRevision: _configRevision,
        ),
        provider: _provider,
        modelIds: _models,
        modelId: _modelId,
        keySaved: _keySaved,
        consent: _consent,
      ),
      availableModels: _models,
      pendingKeyProvided: _pendingKeyProvided,
    );
    notifyListeners();
  }

  @override
  Future<void> refresh() async {
    refreshCalls++;
    await refreshGate?.future;
  }

  @override
  Future<void> loadModels({String key = '', required bool consent}) async {
    loadCalls++;
    lastLoadedKey = key;
    lastLoadConsent = consent;
    await loadGate?.future;
    _models = const ['school-model-initial', 'school-model-loaded'];
    _pendingKeyProvided = true;
    _publish();
  }

  @override
  Future<void> verifyAndSave({
    String key = '',
    required String modelId,
    required bool consent,
  }) async {
    verifyCalls++;
    lastVerifiedKey = key;
    lastVerifiedModel = modelId;
    lastVerifyConsent = consent;
    _keySaved = true;
    _consent = consent;
    _modelId = modelId;
    _pendingKeyProvided = false;
    _configRevision++;
    _publish();
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
  Future<void> setModelConsent(bool consent) async {
    modelConsentChanges.add(consent);
    _consent = consent;
    _configRevision++;
    _publish();
  }

  @override
  Future<void> clearHistory({
    String? conversationId,
    required bool confirmed,
  }) async {}

  @override
  String safeValidationSummary() => '{}';

  @override
  Future<void> selectModelProvider(ModelProvider provider) async {
    selectedProviders.add(provider);
    _provider = provider;
    _models = provider == ModelProvider.deepseek
        ? const ['deepseek-model-synthetic']
        : const ['school-model-initial'];
    _modelId = null;
    _keySaved = false;
    _consent = false;
    _pendingKeyProvided = false;
    _configRevision++;
    _publish();
  }

  @override
  Future<List<AgentPermissionReference>> readActionPermissions() async {
    permissionReadCalls++;
    return const [];
  }

  @override
  Future<void> approveAndRememberAction(String actionId) async {}

  @override
  Future<void> revokeActionPermission(
    AgentPermissionReference reference,
  ) async {}

  @override
  Future<AgentPlanningPreferences> readPlanningPreferences() async {
    planningReadCalls++;
    return AgentPlanningPreferences();
  }

  @override
  Future<void> savePlanningPreferences(
    AgentPlanningPreferences preferences,
  ) async {}
}
