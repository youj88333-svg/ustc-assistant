import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../data/drift_chat_repository.dart';
import '../data/protected_agent_secret_store.dart';

/// Snapshot of an account's agent settings row, with the same defaults as the
/// `agent_settings` table schema.
class AgentSettingsSnapshot {
  const AgentSettingsSnapshot({
    required this.accountId,
    required this.model,
    required this.enabled,
    required this.icourseConsent,
    required this.systemPromptVersion,
    required this.updatedAt,
  });

  final String accountId;
  final String model;
  final bool enabled;
  final bool icourseConsent;
  final int systemPromptVersion;
  final int? updatedAt;
}

/// Per-account Agent configuration: model selection, icourse consent, the
/// enabled flag, and conversation/summary clearing. Conversation and summary
/// clearing delegate to [DriftChatRepository] so the Agent layer has a single
/// owner for those tables.
class AgentConfigurationService {
  AgentConfigurationService({
    required this._database,
    required this._chatRepository,
    int Function()? now,
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  static const defaultModel = 'deepseek-v4-flash';
  static const defaultEnabled = false;
  static const defaultIcourseConsent = false;
  static const defaultSystemPromptVersion = 2;

  final AppDatabase _database;
  final DriftChatRepository _chatRepository;
  final int Function() now;

  /// Loads the settings for [accountId], applying schema defaults when no row
  /// exists yet.
  Future<AgentSettingsSnapshot> load(String accountId) async {
    final row = await (_database.select(
      _database.agentSettings,
    )..where((row) => row.accountId.equals(accountId))).getSingleOrNull();
    return _snapshot(accountId, row);
  }

  Stream<AgentSettingsSnapshot> watch(String accountId) => _database
      .agentSettingsChanges
      .where((changedAccountId) => changedAccountId == accountId)
      .asyncMap((_) => load(accountId));

  /// Upserts the model field for exactly one account, preserving the other
  /// fields (or their defaults if the row does not yet exist).
  Future<void> setModel(String accountId, String model) =>
      _upsert(accountId, model: model);

  /// Upserts the icourse-consent flag for exactly one account.
  Future<void> setIcourseConsent(String accountId, bool consent) =>
      _upsert(accountId, consent: consent);

  /// Upserts the enabled flag for exactly one account.
  Future<void> enable(String accountId, bool enabled) =>
      _upsert(accountId, enabled: enabled);

  Future<void> configureWithKey({
    required String accountId,
    required String apiKey,
    required String model,
    required AgentSecretStore secrets,
  }) async {
    await _database.transaction(() async {
      await secrets.saveKey(accountId, apiKey);
      await _upsertRow(accountId, model: model, enabled: true);
    });
    _database.notifyAgentSettingsChanged(accountId);
  }

  Future<void> deleteKeyAndDisable({
    required String accountId,
    required AgentSecretStore secrets,
  }) async {
    await _database.transaction(() async {
      await secrets.deleteKey(accountId);
      await _upsertRow(accountId, enabled: false);
    });
    _database.notifyAgentSettingsChanged(accountId);
  }

  /// Reads the existing row once and writes a single
  /// `insertOnConflictUpdate`, applying each provided override and falling
  /// back to `existing?.X ?? defaultX` for the rest. Centralizing this keeps
  /// the three public upserts in lockstep when the schema grows a new column.
  Future<void> _upsert(
    String accountId, {
    String? model,
    bool? enabled,
    bool? consent,
    int? systemPromptVersion,
  }) async {
    await _database.transaction(
      () => _upsertRow(
        accountId,
        model: model,
        enabled: enabled,
        consent: consent,
        systemPromptVersion: systemPromptVersion,
      ),
    );
    _database.notifyAgentSettingsChanged(accountId);
  }

  Future<void> _upsertRow(
    String accountId, {
    String? model,
    bool? enabled,
    bool? consent,
    int? systemPromptVersion,
  }) async {
    final existing = await _row(accountId);
    await _database
        .into(_database.agentSettings)
        .insertOnConflictUpdate(
          AgentSettingsCompanion.insert(
            accountId: accountId,
            model: Value(model ?? existing?.model ?? defaultModel),
            enabled: Value(enabled ?? existing?.enabled ?? defaultEnabled),
            icourseConsent: Value(
              consent ?? existing?.icourseConsent ?? defaultIcourseConsent,
            ),
            systemPromptVersion: Value(
              systemPromptVersion ??
                  existing?.systemPromptVersion ??
                  defaultSystemPromptVersion,
            ),
            updatedAt: now(),
          ),
        );
  }

  /// Clears the account's conversation summary, delegating to the chat
  /// repository so it remains the single owner of `conversation_summaries`.
  Future<void> clearSummary(String accountId) =>
      _chatRepository.clearSummary(accountId);

  /// Clears the account's entire conversation (messages, runs, tool
  /// invocations, summary), delegating to the chat repository so FK-safe
  /// delete order is shared with the rest of the Agent layer.
  Future<void> clearConversation(String accountId) =>
      _chatRepository.clearConversation(accountId);

  Future<AgentSetting?> _row(String accountId) => (_database.select(
    _database.agentSettings,
  )..where((row) => row.accountId.equals(accountId))).getSingleOrNull();

  AgentSettingsSnapshot _snapshot(String accountId, AgentSetting? row) {
    if (row == null) {
      return AgentSettingsSnapshot(
        accountId: accountId,
        model: defaultModel,
        enabled: defaultEnabled,
        icourseConsent: defaultIcourseConsent,
        systemPromptVersion: defaultSystemPromptVersion,
        updatedAt: null,
      );
    }
    return AgentSettingsSnapshot(
      accountId: row.accountId,
      model: row.model,
      enabled: row.enabled,
      icourseConsent: row.icourseConsent,
      systemPromptVersion: row.systemPromptVersion,
      updatedAt: row.updatedAt,
    );
  }
}
