import 'package:flutter/foundation.dart';
import '../core/agent_contract.dart';

typedef AgentWorkspaceView = AgentRuntimeView;

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
