import '../../../core/database/app_database.dart';
import '../../../core/time/beijing_clock.dart';
import '../../accounts/application/account_service.dart';
import '../data/anthropic_llm_provider.dart';
import '../data/drift_agent_write_gateway.dart';
import '../data/drift_agent_write_unit_of_work.dart';
import '../data/drift_chat_repository.dart';
import '../data/protected_agent_secret_store.dart';
import '../domain/agent_tool.dart';
import '../domain/llm_protocol.dart';
import 'agent_configuration_service.dart';
import 'agent_context_builder.dart';
import 'agent_local_data_gateway.dart';
import 'agent_permission_policy_service.dart';
import 'agent_session_service.dart';
import 'agent_tool_registry.dart';
import 'agent_tools.dart';
import 'agent_write_tool.dart';
import 'agent_write_tools.dart';
import 'outbound_privacy_filter.dart';

/// Platform-injected factory for a protected [AgentSecretStore].
///
/// Windows: `ProtectedAgentSecretStore(database: db, protector:
/// defaultCredentialProtector())` (DPAPI). Android/iOS: inject an in-memory or
/// flutter_secure_storage-backed implementation.
typedef SecretStoreFactory = AgentSecretStore Function(AppDatabase database);

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
  /// [secretStoreFactory] is the platform-specific injection.
  static Future<AgentCompositionResult> build({
    required AppDatabase database,
    required String accountId,
    required String resolvedUsername,
    required AccountService accounts,
    required SecretStoreFactory secretStoreFactory,
    LlmProvider Function()? providerFactory,
  }) async {
    final clock = const SystemBeijingClock();
    final chatRepository = DriftChatRepository(database);
    await chatRepository.recoverInterrupted();
    final secretStore = secretStoreFactory(database);
    // Production constructs the real Anthropic gateway. The optional factory is
    // the test-injection seam: composition-level tests pump the real router with
    // a scripted provider (capturing requests) without touching the network.
    final provider = providerFactory == null
        ? AnthropicLlmProvider()
        : providerFactory();
    final localGateway = DriftAgentLocalDataGateway(database);
    final configService = AgentConfigurationService(
      database: database,
      chatRepository: chatRepository,
    );
    final snapshot = await configService.load(accountId);
    final model = snapshot.model;

    // Build all tools (local read + local write; external source tools retired).
    final local = localAgentTools(localGateway);

    // Write tools: shared permission policy, per-account write gateway, and the
    // confirmation store that backs the pause/resume cycle for the write card.
    final policyService = AgentPermissionPolicyService(database: database, clock: clock);
    final writeGateway = DriftAgentWriteGateway(
      database: database,
      accountId: accountId,
      policy: policyService,
      now: () => clock.now().millisecondsSinceEpoch,
    );
    final unitOfWork = DriftAgentWriteUnitOfWork(database);
    final confirmationStore = WriteConfirmationStore(
      policy: policyService,
      unitOfWork: unitOfWork,
    );
    final write = agentWriteTools(
      writeGateway,
      policyService,
      confirmationStore,
      unitOfWork,
    );
    final allTools = [...local, ...write];

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
      // writeConfirmation 的恢复由确认卡在 UI 层完成（Task 9/10 接线），
      // 不经过此会话级 resumer。外部来源登录恢复已随 query gateway 退役移除。
      userActionResumer:
          ({required String accountId, required AgentUserAction action}) async {},
      writeConfirmationResumer:
          ({required String handle, required bool approve, required bool remember}) =>
              confirmationStore.resolve(handle, approve: approve, remember: remember),
    );

    return AgentCompositionResult(
      chatRepository: chatRepository,
      secretStore: secretStore,
      provider: provider,
      localGateway: localGateway,
      configService: configService,
      registry: registry,
      privacyFilter: privacyFilter,
      contextBuilder: contextBuilder,
      sessionService: sessionService,
      policyService: policyService,
      clock: clock,
      accountId: accountId,
      model: model,
    );
  }
}

/// The composed result, exposing all services needed by [AgentChatPage] and
/// the [_AgentChatLoader].
class AgentCompositionResult {
  AgentCompositionResult({
    required this.chatRepository,
    required this.secretStore,
    required this.provider,
    required this.localGateway,
    required this.configService,
    required this.registry,
    required this.privacyFilter,
    required this.contextBuilder,
    required this.sessionService,
    required this.policyService,
    required this.clock,
    required this.accountId,
    required this.model,
  });

  final DriftChatRepository chatRepository;
  final AgentSecretStore secretStore;
  final LlmProvider provider;
  final AgentLocalDataGateway localGateway;
  final AgentConfigurationService configService;
  final AgentToolRegistry registry;
  final OutboundPrivacyFilter privacyFilter;
  final AgentContextBuilder contextBuilder;
  final AgentSessionService sessionService;
  final AgentPermissionPolicyService policyService;
  final BeijingClock clock;
  final String accountId;
  final String model;
  bool _disposed = false;

  /// Shorthand to load the account's agent settings snapshot.
  Future<AgentSettingsSnapshot> loadSettings() => configService.load(accountId);

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await sessionService.dispose();
  }
}
