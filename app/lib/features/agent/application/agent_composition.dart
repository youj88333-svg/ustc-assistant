import '../../../core/database/app_database.dart';
import '../../../core/time/beijing_clock.dart';
import '../../accounts/application/account_service.dart';
import '../data/anthropic_llm_provider.dart';
import '../data/drift_chat_repository.dart';
import '../data/protected_agent_secret_store.dart';
import '../domain/agent_tool.dart';
import '../domain/llm_protocol.dart';
import '../domain/query_source.dart';
import 'agent_configuration_service.dart';
import 'agent_context_builder.dart';
import 'agent_local_data_gateway.dart';
import 'agent_session_service.dart';
import 'agent_tool_registry.dart';
import 'agent_tools.dart';
import 'outbound_privacy_filter.dart';

/// Platform-injected factory for a protected [AgentSecretStore].
///
/// Windows: `ProtectedAgentSecretStore(database: db, protector:
/// WindowsDpapiProtector())`. Android/iOS: inject an in-memory or
/// flutter_secure_storage-backed implementation.
typedef SecretStoreFactory = AgentSecretStore Function(AppDatabase database);

/// Platform-injected factory for a [QuerySourceGateway] backed by the Bridge.
///
/// Windows: `WindowsPythonQueryGateway.start(...)`. Android/iOS: inject a
/// no-op or mock stub — the gateway is Windows-only for Task 5.
typedef QueryGatewayFactory = Future<QuerySourceGateway> Function(
  AppDatabase database,
  String accountId,
);

/// Composed Agent services for the active account.
///
/// All wiring is done through injected platform factories; this class imports
/// only pure-Dart agent interfaces and keeps no `dart:io`, DPAPI, or Win32
/// references. The [_AgentChatLoader] in `router.dart` supplies the Windows
/// factories; Android/iOS tests inject their own.
class AgentComposition {
  /// Builds the full composition for [accountId] with the resolved
  /// [resolvedUsername].
  ///
  /// [secretStoreFactory] and [queryGatewayFactory] are the platform-specific
  /// injections. The query gateway factory is used on Windows; other platforms
  /// inject a no-op or mock.
  static Future<AgentCompositionResult> build({
    required AppDatabase database,
    required String accountId,
    required String resolvedUsername,
    required AccountService accounts,
    required SecretStoreFactory secretStoreFactory,
    required QueryGatewayFactory queryGatewayFactory,
  }) async {
    final clock = const SystemBeijingClock();
    final chatRepository = DriftChatRepository(database);
    final secretStore = secretStoreFactory(database);
    final provider = AnthropicLlmProvider();
    final localGateway = DriftAgentLocalDataGateway(database);
    final queryGateway = await queryGatewayFactory(database, accountId);
    final configService = AgentConfigurationService(
      database: database,
      chatRepository: chatRepository,
    );
    final snapshot = await configService.load(accountId);
    final model = snapshot.model;

    // Build all tools.
    final local = localAgentTools(localGateway);

    // Resolve the username once and close over it in the resolver.
    String usernameResolverFn(AgentToolContext _) => resolvedUsername;
    final external = externalAgentTools(
      gateway: queryGateway,
      config: configService,
      usernameResolver: usernameResolverFn,
    );
    final allTools = [...local, ...external];

    // Payload builders and privacy filter.
    final payloadBuilders = agentToolPayloadBuilders();
    final privacyFilter = OutboundPrivacyFilter(
      protectedAccount: resolvedUsername,
      toolBuilders: payloadBuilders,
    );

    // Registry and context builder.
    final registry = AgentToolRegistry(
      tools: allTools,
      privacyFilter: privacyFilter,
    );
    final contextBuilder = const AgentContextBuilder();

    // Session service: apiKeyProvider reads the key ephemerally from the store.
    final sessionService = AgentSessionService(
      chatRepository: chatRepository,
      database: database,
      provider: provider,
      contextBuilder: contextBuilder,
      privacyFilter: privacyFilter,
      registry: registry,
      clock: clock,
      model: model,
      apiKeyProvider: ({required String accountId}) async =>
          (await secretStore.readKey(accountId)) ?? '',
      userActionResumer: ({
        required String accountId,
        required AgentUserAction action,
      }) async {
        switch (action.type) {
          case AgentUserActionType.youngLogin:
            final password = await accounts.passwordForInteractiveLogin(
              accountId,
            );
            await queryGateway.resumeLogin(
              action.opaqueHandle,
              password: password,
            );
        }
      },
    );

    return AgentCompositionResult(
      chatRepository: chatRepository,
      secretStore: secretStore,
      provider: provider,
      localGateway: localGateway,
      queryGateway: queryGateway,
      configService: configService,
      registry: registry,
      privacyFilter: privacyFilter,
      contextBuilder: contextBuilder,
      sessionService: sessionService,
      clock: clock,
      accountId: accountId,
      model: model,
    );
  }
}

/// The composed result, exposing all services needed by [AgentChatPage] and
/// the [_AgentChatLoader].
class AgentCompositionResult {
  const AgentCompositionResult({
    required this.chatRepository,
    required this.secretStore,
    required this.provider,
    required this.localGateway,
    required this.queryGateway,
    required this.configService,
    required this.registry,
    required this.privacyFilter,
    required this.contextBuilder,
    required this.sessionService,
    required this.clock,
    required this.accountId,
    required this.model,
  });

  final DriftChatRepository chatRepository;
  final AgentSecretStore secretStore;
  final LlmProvider provider;
  final AgentLocalDataGateway localGateway;
  final QuerySourceGateway queryGateway;
  final AgentConfigurationService configService;
  final AgentToolRegistry registry;
  final OutboundPrivacyFilter privacyFilter;
  final AgentContextBuilder contextBuilder;
  final AgentSessionService sessionService;
  final BeijingClock clock;
  final String accountId;
  final String model;

  /// Shorthand to load the account's agent settings snapshot.
  Future<AgentSettingsSnapshot> loadSettings() => configService.load(accountId);
}
