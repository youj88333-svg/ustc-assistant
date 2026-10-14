import 'dart:async';
import 'package:flutter/foundation.dart';
import '../agent/agent_coordinator.dart';
import '../core/agent_contract.dart';
import '../core/agent_context_contract.dart';
import '../core/agent_action_contract.dart';
import '../core/agent_discussion_contract.dart';
import '../core/agent_permission_contract.dart';
import 'agent_workspace_contract.dart';
import 'agent_behavior_validation.dart';

/// C5 adapts the pure-Dart C4 projection. Runtime, not a page, owns lifecycle.
final class AgentWorkspaceController extends ChangeNotifier
    implements
        AgentWorkspacePort,
        AgentActionWorkspacePort,
        AgentPreferencesWorkspacePort,
        AgentDiscussionWorkspacePort,
        AgentHistoryWorkspacePort,
        AgentConversationCommandsWorkspacePort,
        AgentPermissionWorkspacePort,
        AgentWorkspaceUsePolicyPort,
        AgentContextOptionsWorkspacePort {
  AgentWorkspaceController(this.coordinator) {
    _subscription = coordinator.changes.listen((_) {
      if (!_disposed) notifyListeners();
    });
  }
  final AgentCoordinator coordinator;
  late final StreamSubscription<Object?> _subscription;
  bool _disposed = false;
  AgentBehaviorValidationRunner? _behaviorValidation;

  /// This runner has its own synthetic store and model client. Opening the
  /// review panel never starts requests; only its explicit start button does.
  Future<AgentBehaviorValidationRunner> openBehaviorValidation() async {
    if (_disposed) throw const AgentFailure(AgentFailureCode.closed);
    await coordinator.stop();
    if (_disposed) throw const AgentFailure(AgentFailureCode.closed);
    return _behaviorValidation ??= AgentBehaviorValidationRunner(
      modelConfiguration: coordinator.data,
    );
  }

  Future<void> drainBehaviorValidation() async {
    await _behaviorValidation?.stop();
  }

  Future<void> closeBehaviorValidation() async {
    final runner = _behaviorValidation;
    await runner?.close();
    if (identical(_behaviorValidation, runner)) _behaviorValidation = null;
  }

  @override
  AgentWorkspaceView get view => coordinator.view;
  @override
  Future<void> refresh() => coordinator.refresh();
  @override
  Future<void> loadModels({String key = '', required bool consent}) async {
    await drainBehaviorValidation();
    await coordinator.loadModels(key: key, consent: consent);
  }

  @override
  Future<void> verifyAndSave({
    String key = '',
    required String modelId,
    required bool consent,
  }) async {
    await drainBehaviorValidation();
    await coordinator.verifyAndSave(
      key: key,
      modelId: modelId,
      consent: consent,
    );
  }

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
  Future<void> saveUsePolicy({
    required bool personalContentAllowed,
    required bool dailyOperationsAllowed,
  }) => coordinator.saveUsePolicy(
    personalContentAllowed: personalContentAllowed,
    dailyOperationsAllowed: dailyOperationsAllowed,
  );
  @override
  Future<void> setAdviceOnly(bool value) => coordinator.setAdviceOnly(value);
  @override
  Future<AgentContextOptions> readContextOptions() =>
      coordinator.readContextOptions();
  @override
  Future<void> saveContextOptions(AgentContextOptions options) =>
      coordinator.saveContextOptions(options);
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
  Future<void> deleteKey({required bool confirmed}) async {
    if (confirmed) await drainBehaviorValidation();
    await coordinator.deleteKey(confirmed: confirmed);
  }

  @override
  Future<void> setModelConsent(bool consent) async {
    await drainBehaviorValidation();
    await coordinator.setModelConsent(consent);
  }

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
