import 'package:flutter/foundation.dart';
import '../core/agent_contract.dart';
import '../core/agent_context_contract.dart';
import '../core/agent_action_contract.dart';
import '../core/agent_discussion_contract.dart';
import '../core/agent_permission_contract.dart';

abstract interface class AgentConversationCommandsWorkspacePort {
  Future<void> compactConversation();
  Future<void> clearConversation();
}

abstract interface class AgentPermissionWorkspacePort {
  Future<void> approveAndRememberAction(String actionId);
  Future<List<AgentPermissionReference>> readActionPermissions();
  Future<void> revokeActionPermission(AgentPermissionReference reference);
}

/// Optional app-owned switches for personal-content and daily-operation policy.
/// Kept separate from per-action remembered permissions for compatibility.
abstract interface class AgentWorkspaceUsePolicyPort {
  Future<void> saveUsePolicy({
    required bool personalContentAllowed,
    required bool dailyOperationsAllowed,
  });
  Future<void> setAdviceOnly(bool value);
}

/// Optional advanced controls for the per-run context estimate.
abstract interface class AgentContextOptionsWorkspacePort {
  Future<AgentContextOptions> readContextOptions();
  Future<void> saveContextOptions(AgentContextOptions options);
}

/// C5 human buttons only. None of these methods are a model-callable tool.
abstract interface class AgentActionWorkspacePort {
  Future<void> approveAction(String actionId);
  Future<void> rejectAction(String actionId);
  Future<void> continueSchool();
}

abstract interface class AgentPreferencesWorkspacePort {
  Future<AgentPlanningPreferences> readPlanningPreferences();
  Future<void> savePlanningPreferences(AgentPlanningPreferences preferences);
}

typedef AgentWorkspaceView = AgentRuntimeView;

abstract interface class AgentDiscussionWorkspacePort {
  Future<void> prepareDiscussion(AgentDiscussionSelection selection);
}

abstract interface class AgentHistoryWorkspacePort {
  Future<void> loadOlderMessages();
}

abstract interface class AgentWorkspacePort implements Listenable {
  AgentWorkspaceView get view;
  Future<void> refresh();
  Future<void> loadModels({String key = '', required bool consent});
  Future<void> verifyAndSave({
    String key = '',
    required String modelId,
    required bool consent,
  });
  Future<void> newConversation();
  Future<void> selectConversation(String id);
  Future<void> send(String text, {List<AgentImage> images = const []});
  Future<void> stop();
  Future<void> deleteKey({required bool confirmed});
  Future<void> setModelConsent(bool consent);
  Future<void> clearHistory({String? conversationId, required bool confirmed});
  String safeValidationSummary();
}

/// Optional switch for selecting one of the app's fixed model providers.
/// Kept separate so existing workspace fakes and adapters remain compatible.
abstract interface class AgentModelProviderWorkspacePort {
  Future<void> selectModelProvider(ModelProvider provider);
}
