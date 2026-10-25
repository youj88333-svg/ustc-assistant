import '../core/agent_contract.dart';
import 'model_gateway_contract.dart';
import 'ustc_model_gateway.dart';

/// The C3-issued lease selects one fixed service, never a model name or URL.
/// Failure stays at that provider: there is no cross-provider retry/fallback.
final class ConfiguredModelGateway implements ModelGatewayPort {
  ConfiguredModelGateway({
    Duration requestTimeout = const Duration(seconds: 180),
  }) : _school = UstcModelGateway(requestTimeout: requestTimeout),
       _deepseek = UstcModelGateway.deepseekOfficial(
         requestTimeout: requestTimeout,
       );

  ConfiguredModelGateway.forTesting({
    required ModelGatewayPort school,
    required ModelGatewayPort deepseek,
  }) : // Keep named test services explicit at the assembly boundary.
       // ignore: prefer_initializing_formals
       _school = school,
       // ignore: prefer_initializing_formals
       _deepseek = deepseek;

  final ModelGatewayPort _school, _deepseek;
  bool _closed = false;
  ModelGatewayPort _target(ModelSecretLease secret) =>
      switch (secret.provider) {
        ModelProvider.school => _school,
        ModelProvider.deepseek => _deepseek,
      };

  @override
  Future<List<String>> listModels(ModelSecretLease secret) {
    if (_closed) {
      secret.revoke();
      return Future.error(const AgentFailure(AgentFailureCode.closed));
    }
    return _target(secret).listModels(secret);
  }

  @override
  Stream<ModelEvent> generate(ModelRequest request, ModelSecretLease secret) {
    if (_closed) {
      secret.revoke();
      return Stream.error(const AgentFailure(AgentFailureCode.closed));
    }
    return _target(secret).generate(request, secret);
  }

  @override
  Future<void> cancelAndDrain() async {
    await Future.wait([_school.cancelAndDrain(), _deepseek.cancelAndDrain()]);
  }

  @override
  Future<void> close() async {
    _closed = true;
    await Future.wait([_school.close(), _deepseek.close()]);
  }
}
