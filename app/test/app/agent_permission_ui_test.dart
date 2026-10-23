import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/agent_settings_panel.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/agent_permission_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets(
    'settings reads and revokes one fixed permission without clearing key or history',
    (tester) async {
      final createTask = AgentPermissionReference(
        AgentPermissionCategory.createTask,
        7,
      );
      final updateTask = AgentPermissionReference(
        AgentPermissionCategory.updateTask,
        4,
      );
      final port = _PermissionSettingsPort([createTask, updateTask]);
      addTearDown(port.dispose);

      await tester.pumpWidget(_host(AgentSettingsPanel(controller: port)));
      await tester.pumpAndSettle();

      expect(port.permissionReadCalls, 1);
      await _scrollSettingsTo(tester, find.text('已记住的操作授权'));
      expect(find.text('创建任务'), findsOneWidget);
      expect(find.text('修改任务'), findsOneWidget);
      expect(port.clearHistoryCalls, 0);

      await _tap(tester, 'agent-settings-delete-key');
      await tester.pumpAndSettle();
      await _tap(tester, 'agent-settings-delete-key-confirm');
      await tester.pumpAndSettle();
      expect(port.deleteKeyCalls, 1);
      expect(port.view.settings?.keySaved, isFalse);
      expect(port.actionPermissions, [createTask, updateTask]);
      await _scrollSettingsTo(tester, find.text('已记住的操作授权'));
      expect(find.text('创建任务'), findsOneWidget);
      expect(find.text('修改任务'), findsOneWidget);

      await _scrollSettingsTo(
        tester,
        find.byKey(const ValueKey('agent-permission-revoke-updateTask:4')),
      );
      await _tap(tester, 'agent-permission-revoke-updateTask:4');
      await tester.pumpAndSettle();

      expect(port.revokedPermissions, [updateTask]);
      expect(port.permissionReadCalls, 2);
      expect(port.actionPermissions, [createTask]);
      expect(find.text('创建任务'), findsOneWidget);
      expect(find.text('修改任务'), findsNothing);
      expect(port.clearHistoryCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('permission loading failure stays bounded and can be retried', (
    tester,
  ) async {
    final permission = AgentPermissionReference(
      AgentPermissionCategory.createTask,
      2,
    );
    final port = _PermissionSettingsPort([permission])
      ..readFailuresRemaining = 1;
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(AgentSettingsPanel(controller: port)));
    await tester.pumpAndSettle();

    expect(port.permissionReadCalls, 1);
    await _scrollSettingsTo(tester, find.text('已记住的操作授权'));
    expect(find.text('无法读取已记住的操作授权，请重试。'), findsOneWidget);
    expect(find.textContaining('private fixture detail'), findsNothing);
    await _tap(tester, 'agent-permissions-reload');
    await tester.pumpAndSettle();

    expect(port.permissionReadCalls, 2);
    await _scrollSettingsTo(tester, find.text('已记住的操作授权'));
    expect(find.text('创建任务'), findsOneWidget);
    expect(find.byKey(const ValueKey('agent-permissions-error')), findsNothing);
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

Future<void> _scrollSettingsTo(WidgetTester tester, Finder target) async {
  final settings = find.byKey(const ValueKey('agent-settings-panel'));
  final scrollable = find
      .descendant(of: settings, matching: find.byType(Scrollable))
      .first;
  await tester.scrollUntilVisible(target, 240, scrollable: scrollable);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

final class _PermissionSettingsPort extends ChangeNotifier
    implements AgentWorkspacePort, AgentPermissionWorkspacePort {
  _PermissionSettingsPort(List<AgentPermissionReference> permissions)
    : actionPermissions = [...permissions],
      _view = AgentRuntimeView(
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
          report: const AgentCapabilityReport(text: true, streaming: true),
        ),
      );

  final List<AgentPermissionReference> actionPermissions;
  AgentRuntimeView _view;
  final List<AgentPermissionReference> revokedPermissions = [];
  int permissionReadCalls = 0;
  int deleteKeyCalls = 0;
  int clearHistoryCalls = 0;
  int readFailuresRemaining = 0;

  @override
  AgentRuntimeView get view => _view;

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
  Future<void> deleteKey({required bool confirmed}) async {
    deleteKeyCalls++;
    final previous = _view.settings!;
    _view = AgentRuntimeView(
      settings: AgentSettingsSnapshot(
        authority: previous.authority,
        keySaved: false,
        consent: previous.consent,
        modelId: previous.modelId,
        modelIds: previous.modelIds,
        report: previous.report,
      ),
    );
    notifyListeners();
  }

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
  Future<void> approveAndRememberAction(String actionId) async {}

  @override
  Future<List<AgentPermissionReference>> readActionPermissions() async {
    permissionReadCalls++;
    if (readFailuresRemaining > 0) {
      readFailuresRemaining--;
      throw StateError('private fixture detail');
    }
    return List.unmodifiable(actionPermissions);
  }

  @override
  Future<void> revokeActionPermission(
    AgentPermissionReference reference,
  ) async {
    revokedPermissions.add(reference);
    actionPermissions.removeWhere(
      (permission) =>
          permission.category == reference.category &&
          permission.revision == reference.revision,
    );
  }
}
