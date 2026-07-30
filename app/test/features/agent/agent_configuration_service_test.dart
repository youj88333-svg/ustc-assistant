import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/security/credential_protector.dart';
import 'package:ustc_assistant_app/features/accounts/application/account_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_configuration_service.dart';
import 'package:ustc_assistant_app/features/agent/data/drift_chat_repository.dart';
import 'package:ustc_assistant_app/features/agent/data/protected_agent_secret_store.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_models.dart';
import 'package:ustc_assistant_app/features/settings/application/settings_service.dart';

/// Fake [CredentialProtector] whose ciphertext starts with `protected:` but
/// does not contain the raw plaintext. The transform reverses the plaintext
/// bytes before prefixing the marker, so `protect('school-secret')` yields the
/// bytes of `'protected:terces-loohcs'` — observably not the raw key while
/// remaining a faithful, invertible protection scheme.
class _ReversingFakeProtector implements CredentialProtector {
  static const scheme = 'fake-reverse';

  @override
  Future<ProtectedSecret> protect(Uint8List plaintext) async {
    final marker = utf8.encode('protected:');
    final reversed = plaintext.reversed;
    final bytes = Uint8List.fromList([...marker, ...reversed]);
    return ProtectedSecret(
      bytes: bytes,
      scheme: scheme,
      version: 1,
      metadata: const {'scope': 'test'},
    );
  }

  @override
  Future<Uint8List> unprotect(ProtectedSecret protected) async {
    if (protected.scheme != scheme || protected.version != 1) {
      throw const CredentialProtectionException('unsupported_scheme');
    }
    final marker = utf8.encode('protected:');
    if (protected.bytes.length < marker.length) {
      throw const CredentialProtectionException('corrupted_ciphertext');
    }
    for (var i = 0; i < marker.length; i++) {
      if (protected.bytes[i] != marker[i]) {
        throw const CredentialProtectionException('corrupted_ciphertext');
      }
    }
    final payload = protected.bytes.skip(marker.length).toList();
    return Uint8List.fromList(payload.reversed.toList());
  }
}

Future<AppDatabase> _fixtureDatabase() async =>
    AppDatabase(NativeDatabase.memory());

Future<void> _seedAccount(AppDatabase database, String accountId) => database
    .into(database.localAccounts)
    .insert(
      LocalAccountsCompanion.insert(
        id: accountId,
        maskedHint: 'PB****0000',
        isActive: const Value(true),
        createdAt: 1,
        updatedAt: 1,
      ),
    );

void main() {
  group('ProtectedAgentSecretStore', () {
    late AppDatabase database;
    late AgentSecretStore store;

    setUp(() async {
      database = await _fixtureDatabase();
      addTearDown(database.close);
      await _seedAccount(database, 'account-a');
      store = ProtectedAgentSecretStore(
        database: database,
        protector: _ReversingFakeProtector(),
      );
    });

    test('saveKey / readKey round-trip and hasKey isolates accounts', () async {
      await store.saveKey('account-a', 'school-secret');
      expect(await store.readKey('account-a'), 'school-secret');
      expect(await store.hasKey('account-b'), isFalse);

      final row = await database.select(database.agentSecrets).getSingle();
      expect(row.accountId, 'account-a');
      expect(row.scheme, 'fake-reverse');
      expect(row.protectionVersion, 1);
      expect(row.protectionMetadata, jsonEncode({'scope': 'test'}));
      // The stored ciphertext must start with `protected:` and must NOT
      // contain the raw key material — a non-identity transform is required.
      expect(utf8.decode(row.apiKeyCiphertext), startsWith('protected:'));
      expect(
        utf8.decode(row.apiKeyCiphertext),
        isNot(contains('school-secret')),
      );
    });

    test('deleteKey removes the secret', () async {
      await store.saveKey('account-a', 'school-secret');
      expect(await store.hasKey('account-a'), isTrue);
      await store.deleteKey('account-a');
      expect(await store.hasKey('account-a'), isFalse);
      expect(await database.select(database.agentSecrets).get(), isEmpty);
    });

    test('readKey returns null when no key is stored', () async {
      expect(await store.readKey('account-a'), isNull);
    });

    test('saveKey overwrites the previous protected bytes', () async {
      await store.saveKey('account-a', 'school-secret');
      await store.saveKey('account-a', 'rotated-secret');
      expect(await store.readKey('account-a'), 'rotated-secret');
      expect(await database.select(database.agentSecrets).get(), hasLength(1));
      final row = await database.select(database.agentSecrets).getSingle();
      expect(
        utf8.decode(row.apiKeyCiphertext),
        isNot(contains('rotated-secret')),
      );
    });
  });

  group('AgentConfigurationService', () {
    late AppDatabase database;
    late AgentConfigurationService service;
    late DriftChatRepository chatRepository;

    setUp(() async {
      database = await _fixtureDatabase();
      addTearDown(database.close);
      await _seedAccount(database, 'account-a');
      chatRepository = DriftChatRepository(database);
      service = AgentConfigurationService(
        database: database,
        chatRepository: chatRepository,
      );
    });

    test('load returns defaults when no row exists', () async {
      final settings = await service.load('account-a');
      expect(settings.model, 'deepseek-v4-flash');
      expect(settings.enabled, isFalse);
      expect(settings.icourseConsent, isFalse);
      expect(settings.systemPromptVersion, 2);
    });

    test(
      'setModel upserts the model field and preserves other defaults',
      () async {
        await service.setModel('account-a', 'deepseek-v4-pro');
        final settings = await service.load('account-a');
        expect(settings.model, 'deepseek-v4-pro');
        expect(settings.enabled, isFalse);
        expect(settings.icourseConsent, isFalse);
      },
    );

    test('setIcourseConsent toggles only the consent flag', () async {
      await service.setIcourseConsent('account-a', true);
      final settings = await service.load('account-a');
      expect(settings.icourseConsent, isTrue);
      expect(settings.enabled, isFalse);
      expect(settings.model, 'deepseek-v4-flash');
    });

    test('enable toggles only the enabled flag', () async {
      await service.enable('account-a', true);
      final settings = await service.load('account-a');
      expect(settings.enabled, isTrue);
      expect(settings.icourseConsent, isFalse);
    });

    test(
      'configureWithKey saves key model and enabled state atomically',
      () async {
        final secrets = ProtectedAgentSecretStore(
          database: database,
          protector: _ReversingFakeProtector(),
        );

        await service.configureWithKey(
          accountId: 'account-a',
          apiKey: 'school-key',
          model: 'available-model',
          secrets: secrets,
        );

        expect(await secrets.readKey('account-a'), 'school-key');
        final settings = await service.load('account-a');
        expect(settings.model, 'available-model');
        expect(settings.enabled, isTrue);
      },
    );

    test(
      'configureWithKey rolls back the key when settings write fails',
      () async {
        final secrets = ProtectedAgentSecretStore(
          database: database,
          protector: _ReversingFakeProtector(),
        );
        await database.customStatement('''
CREATE TRIGGER fail_agent_settings_insert
BEFORE INSERT ON agent_settings
BEGIN
  SELECT RAISE(FAIL, 'settings failure');
END
''');

        await expectLater(
          service.configureWithKey(
            accountId: 'account-a',
            apiKey: 'must-rollback',
            model: 'available-model',
            secrets: secrets,
          ),
          throwsA(anything),
        );

        expect(await secrets.hasKey('account-a'), isFalse);
        expect((await service.load('account-a')).enabled, isFalse);
      },
    );

    test('clearSummary delegates to the chat repository', () async {
      await chatRepository.replaceSummary(
        accountId: 'account-a',
        throughOrdinal: 1,
        content: 'first summary',
        model: 'deepseek-v4-flash',
      );
      expect(await chatRepository.latestSummary('account-a'), isNotNull);
      await service.clearSummary('account-a');
      expect(await chatRepository.latestSummary('account-a'), isNull);
    });

    test('clearConversation delegates to the chat repository', () async {
      final runId = await chatRepository.startRun(
        accountId: 'account-a',
        model: 'deepseek-v4-flash',
      );
      await chatRepository.appendMessage(
        accountId: 'account-a',
        runId: runId,
        role: ChatRole.user,
        state: ChatMessageState.completed,
        content: 'hi',
      );
      await service.clearConversation('account-a');
      expect(await database.select(database.chatMessages).get(), isEmpty);
      expect(await database.select(database.agentRuns).get(), isEmpty);
    });
  });

  group('SettingsService reset behavior for Agent rows', () {
    late AppDatabase database;
    late AccountService accounts;
    late SettingsService settings;
    late DriftChatRepository chatRepository;
    late AgentSecretStore secretStore;
    late AgentConfigurationService agentConfig;
    late String accountId;

    setUp(() async {
      database = await _fixtureDatabase();
      addTearDown(database.close);
      accounts = AccountService(
        database: database,
        protector: _ReversingFakeProtector(),
      );
      // Persist a real account so the FK target exists and the account-id
      // matches the live credential row the SettingsService will reset.
      accountId = await accounts.persistVerifiedAccount(
        username: 'PB00000000',
        password: 'school-password',
        savePassword: true,
      );
      settings = SettingsService(
        database: database,
        accounts: accounts,
        accountId: accountId,
      );
      chatRepository = DriftChatRepository(database);
      secretStore = ProtectedAgentSecretStore(
        database: database,
        protector: _ReversingFakeProtector(),
      );
      agentConfig = AgentConfigurationService(
        database: database,
        chatRepository: chatRepository,
      );

      // Seed Agent rows for this account.
      await secretStore.saveKey(accountId, 'school-secret');
      await agentConfig.enable(accountId, true);
      await agentConfig.setIcourseConsent(accountId, true);
      final runId = await chatRepository.startRun(
        accountId: accountId,
        model: 'deepseek-v4-flash',
      );
      await chatRepository.appendMessage(
        accountId: accountId,
        runId: runId,
        role: ChatRole.user,
        state: ChatMessageState.completed,
        content: 'hello',
      );
      await chatRepository.replaceSummary(
        accountId: accountId,
        throughOrdinal: 1,
        content: 'summary',
        model: 'deepseek-v4-flash',
      );
    });

    test(
      'clearBusinessData preserves Agent conversation, summary, settings, and key',
      () async {
        // Pre-condition: agent rows ARE present.
        expect(
          await database.select(database.agentSecrets).get(),
          hasLength(1),
        );
        expect(
          await database.select(database.agentSettings).get(),
          hasLength(1),
        );
        expect(
          await database.select(database.chatMessages).get(),
          hasLength(1),
        );
        expect(await database.select(database.agentRuns).get(), hasLength(1));
        expect(
          await database.select(database.conversationSummaries).get(),
          hasLength(1),
        );

        await settings.clearBusinessData(confirmed: true);

        // Business data clearing must NOT touch any agent table.
        expect(
          await database.select(database.agentSecrets).get(),
          hasLength(1),
        );
        expect(
          await database.select(database.agentSettings).get(),
          hasLength(1),
        );
        expect(
          await database.select(database.chatMessages).get(),
          hasLength(1),
        );
        expect(await database.select(database.agentRuns).get(), hasLength(1));
        expect(
          await database.select(database.conversationSummaries).get(),
          hasLength(1),
        );
        // The key is still readable.
        expect(await secretStore.readKey(accountId), 'school-secret');
      },
    );

    test(
      'completeReset cascades and removes Agent secrets, settings, chat, runs, summaries',
      () async {
        // Pre-condition: agent rows ARE present.
        expect(
          await database.select(database.agentSecrets).get(),
          hasLength(1),
        );
        expect(
          await database.select(database.agentSettings).get(),
          hasLength(1),
        );
        expect(
          await database.select(database.chatMessages).get(),
          hasLength(1),
        );
        expect(await database.select(database.agentRuns).get(), hasLength(1));
        expect(
          await database.select(database.conversationSummaries).get(),
          hasLength(1),
        );

        await settings.completeReset(
          firstConfirmation: true,
          secondConfirmation: true,
        );

        // Cascading FK delete removes every agent row for the account.
        expect(await database.select(database.agentSecrets).get(), isEmpty);
        expect(await database.select(database.agentSettings).get(), isEmpty);
        expect(await database.select(database.chatMessages).get(), isEmpty);
        expect(await database.select(database.agentRuns).get(), isEmpty);
        expect(
          await database.select(database.conversationSummaries).get(),
          isEmpty,
        );
        expect(await database.select(database.toolInvocations).get(), isEmpty);
        // And the account itself is gone, which is what drove the cascade.
        expect(await database.select(database.localAccounts).get(), isEmpty);
      },
    );
  });
}
