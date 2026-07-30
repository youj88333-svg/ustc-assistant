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
import 'cancellation_signal.dart';
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
typedef QueryGatewayFactory =
    Future<QuerySourceGateway> Function(AppDatabase database, String accountId);

typedef QueryGatewayStarter = Future<QuerySourceGateway> Function();

/// Defers platform Bridge startup until an external source tool is used.
class LazyQuerySourceGateway implements DisposableQuerySourceGateway {
  LazyQuerySourceGateway(this._starter);

  final QueryGatewayStarter _starter;
  Future<QuerySourceGateway>? _gatewayFuture;
  bool _disposed = false;
  bool _underlyingDisposed = false;

  Future<QuerySourceGateway> _gateway() async {
    if (_disposed) throw StateError('bridge_unavailable');
    final starting = _gatewayFuture ??= _starter();
    late final QuerySourceGateway gateway;
    try {
      gateway = await starting;
    } catch (_) {
      if (identical(_gatewayFuture, starting)) {
        _gatewayFuture = null;
      }
      rethrow;
    }
    if (_disposed) {
      await _disposeUnderlying(gateway);
      throw StateError('bridge_unavailable');
    }
    return gateway;
  }

  @override
  Stream<SourceQueryEvent> execute(
    SourceQuery request, {
    required CancellationSignal cancellation,
  }) async* {
    try {
      final gateway = await _gateway();
      yield* gateway.execute(request, cancellation: cancellation);
    } catch (_) {
      yield SourceQueryFailed(jobId: 'bridge', code: 'bridge_unavailable');
    }
  }

  @override
  Future<void> resumeLogin(String jobId, {String? password}) async {
    final gateway = await _gateway();
    await gateway.resumeLogin(jobId, password: password);
  }

  @override
  Future<void> cancel(String jobId) async {
    final gateway = await _gateway();
    await gateway.cancel(jobId);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final started = _gatewayFuture;
    if (started == null) return;
    try {
      await _disposeUnderlying(await started);
    } catch (_) {
      // A failed lazy startup has no resource to release.
    }
  }

  Future<void> _disposeUnderlying(QuerySourceGateway gateway) async {
    if (_underlyingDisposed) return;
    _underlyingDisposed = true;
    if (gateway is DisposableQuerySourceGateway) {
      await gateway.dispose();
    }
  }
}

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
      userActionResumer:
          ({required String accountId, required AgentUserAction action}) async {
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
  AgentCompositionResult({
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
  bool _disposed = false;

  /// Shorthand to load the account's agent settings snapshot.
  Future<AgentSettingsSnapshot> loadSettings() => configService.load(accountId);

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await sessionService.dispose();
    final gateway = queryGateway;
    if (gateway is DisposableQuerySourceGateway) {
      await gateway.dispose();
    }
  }
}
