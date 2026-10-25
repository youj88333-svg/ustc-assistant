import 'agent_contract.dart';

/// Conservative preflight; ordinary text stays usable, identifiable secrets do
/// not become durable conversation content. This is not a universal detector.
abstract final class AgentText {
  static final _secret = RegExp(
    r'\bsk-[A-Za-z0-9_-]{8,}|\bBearer\s+\S{6,}|\b(?:api[_ -]?key|token|password)\s*[:=]\s*\S{4,}|(?:密码|口令|密钥)\s*[:：=]\s*\S{3,}',
    caseSensitive: false,
  );
  static void requireSafe(String text, {int maxCharacters = 24000}) {
    if (text.length > maxCharacters || text.contains('\u0000')) {
      throw const AgentFailure(AgentFailureCode.resourceLimit);
    }
    if (_secret.hasMatch(text)) {
      throw const AgentFailure(AgentFailureCode.secretDetected);
    }
  }

  static bool validModelId(String value) =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$').hasMatch(value);
}
