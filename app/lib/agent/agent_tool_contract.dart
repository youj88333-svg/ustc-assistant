import '../core/agent_contract.dart';
import 'model_gateway_contract.dart';

const agentToolRegistryVersion = 'agent-read-tools-v1';

/// Each result is data, never instructions. No underlying authority is JSON.
final class AgentToolResult {
  AgentToolResult({
    required this.status,
    this.failure,
    Map<String, Object?> data = const {},
    List<String> evidenceIds = const [],
  }) : data = Map.unmodifiable(data),
       evidenceIds = List.unmodifiable(evidenceIds);
  final String status;
  final String? failure;
  final Map<String, Object?> data;
  final List<String> evidenceIds;
  Map<String, Object?> toMap() => {
    'version': agentToolRegistryVersion,
    'status': status,
    if (failure != null) 'failure': failure,
    'data': data,
    'evidence': evidenceIds,
    'trust': 'untrusted_source_data',
  };
}

abstract interface class AgentToolSession {
  List<AgentEvidence> get evidence;
  Future<AgentToolResult> execute(ModelToolCall call);

  /// Revalidate every previously delivered snapshot before another outbound.
  Future<void> validateDelivery();
  void revoke();
}

abstract interface class AgentReadToolsPort {
  List<ModelToolDefinition> get definitions;
  AgentToolSession openSession();

  /// Only this port's C2 instance; it cannot cancel independent manual work.
  Future<void> cancelAndDrain();
  Future<void> close();
}
