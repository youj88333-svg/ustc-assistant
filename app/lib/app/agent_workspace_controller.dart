import 'dart:async';
import 'package:flutter/foundation.dart';
import '../agent/agent_coordinator.dart';
import '../core/agent_contract.dart';
import '../core/agent_action_contract.dart';
import '../core/agent_discussion_contract.dart';
import '../core/agent_permission_contract.dart';
import 'agent_workspace_contract.dart';

/// C5 adapts the pure-Dart C4 projection. Runtime, not a page, owns lifecycle.
final class AgentWorkspaceController extends ChangeNotifier
    implements
        AgentWorkspacePort,
        AgentActionWorkspacePort,
        AgentPreferencesWorkspacePort,
        AgentDiscussionWorkspacePort,
        AgentHistoryWorkspacePort,
        AgentConversationCommandsWorkspacePort,
        AgentPermissionWorkspacePort {
  AgentWorkspaceController(this.coordinator) {
    _subscription = coordinator.changes.listen((_) {
      if (!_disposed) notifyListeners();
    });
  }
  final AgentCoordinator coordinator;
  late final StreamSubscription<Object?> _subscription;
  bool _disposed = false;
  @override
  AgentWorkspaceView get view => coordinator.view;
  @override
  Future<void> refresh() => coordinator.refresh();
  @override
  Future<void> loadModels({String key = '', required bool consent}) =>
      coordinator.loadModels(key: key, consent: consent);
  @override
  Future<void> verifyAndSave({
    String key = '',
    required String modelId,
    required bool consent,
  }) => coordinator.verifyAndSave(key: key, modelId: modelId, consent: consent);
  @override
  Future<void> newConversation() => coordinator.newConversation();
  @override
  Future<void> selectConversation(String id) =>
      coordinator.selectConversation(id);
  @override
  Future<void> send(String text, {List<AgentImage> images = const []}) =>
      coordinator.send(text, images: images);
  @override
  Future<void> stop() => coordinator.stop();
  @override
  Future<void> prepareDiscussion(AgentDiscussionSelection selection) =>
      coordinator.prepareDiscussion(selection);
  @override
  Future<void> loadOlderMessages() => coordinator.loadOlderMessages();
  @override
  Future<void> approveAction(String id) => coordinator.approveAction(id);
  @override
  Future<void> approveAndRememberAction(String id) =>
      coordinator.approveAndRememberAction(id);
  @override
  Future<List<AgentPermissionReference>> readActionPermissions() =>
      coordinator.readActionPermissions();
  @override
  Future<void> revokeActionPermission(AgentPermissionReference reference) =>
      coordinator.revokeActionPermission(reference);
  @override
  Future<void> compactConversation() => coordinator.compactConversation();
  @override
  Future<void> clearConversation() => coordinator.clearConversation();
  @override
  Future<void> rejectAction(String id) => coordinator.rejectAction(id);
  @override
  Future<void> continueSchool() => coordinator.continueSchool();
  @override
  Future<AgentPlanningPreferences> readPlanningPreferences() =>
      coordinator.readPlanningPreferences();
  @override
  Future<void> savePlanningPreferences(AgentPlanningPreferences preferences) =>
      coordinator.savePlanningPreferences(preferences);
  @override
  Future<void> deleteKey({required bool confirmed}) =>
      coordinator.deleteKey(confirmed: confirmed);
  @override
  Future<void> setModelConsent(bool consent) =>
      coordinator.setModelConsent(consent);
  @override
  Future<void> clearHistory({
    String? conversationId,
    required bool confirmed,
  }) => coordinator.clearHistory(
    conversationId: conversationId,
    confirmed: confirmed,
  );
  @override
  String safeValidationSummary() => coordinator.safeValidationSummary();
  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
