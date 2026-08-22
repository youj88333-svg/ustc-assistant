import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/security/credential_protector.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_configuration_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_permission_policy_service.dart';
import 'package:ustc_assistant_app/features/agent/application/cancellation_signal.dart';
import 'package:ustc_assistant_app/features/agent/data/drift_chat_repository.dart';
import 'package:ustc_assistant_app/features/agent/data/protected_agent_secret_store.dart';
import 'package:ustc_assistant_app/features/agent/domain/llm_protocol.dart';
import 'package:ustc_assistant_app/features/agent/presentation/agent_settings_page.dart';

/// Fake [CredentialProtector] mirroring the agent_configuration_service_test
/// pattern: the ciphertext is observably not the raw key, yet invertible.
class _ReversingFakeProtector implements CredentialProtector {
  static const scheme = 'fake-reverse';

  @override
  Future<ProtectedSecret> protect(Uint8List plaintext) async {
    final marker = utf8.encode('protected:');
    final reversed = plaintext.reversed;
    return ProtectedSecret(
      bytes: Uint8List.fromList([...marker, ...reversed]),
      scheme: scheme,
      version: 1,
      metadata: const {'scope': 'test'},
    );
  }

  @override
  Future<Uint8List> unprotect(ProtectedSecret protected) async {
    final marker = utf8.encode('protected:');
    final payload = protected.bytes.skip(marker.length).toList();
    return Uint8List.fromList(payload.reversed.toList());
  }
}

/// A controllable fake of [LlmProvider] whose probe outcomes are scripted per
/// test. It never touches the network, satisfying the rule that automated
/// tests must not access the school API.
class _FakeLlmProvider implements LlmProvider {
  _FakeLlmProvider({
    this.textShouldThrow,
    this.toolsShouldThrow,
    this.availableModels = models,
  });

  static const models = ['deepseek-v4-flash', 'deepseek-v4-pro'];
  final Object? textShouldThrow;
  final Object? toolsShouldThrow;
  final List<String> availableModels;
  final callOrder = <String>[];
  var listModelsCalls = 0;
  var probeTextCalls = 0;
  var probeToolsCalls = 0;
  String? lastProbeApiKey;
  String? lastProbeModel;

  @override
  Future<List<String>> listModels({
    required String apiKey,
    required CancellationSignal cancellation,
  }) async {
    listModelsCalls++;
    callOrder.add('list');
    lastProbeApiKey = apiKey;
    return List<String>.from(availableModels);
  }

  @override
  Future<void> probeText({
    required String apiKey,
    required String model,
    required CancellationSignal cancellation,
  }) async {
    probeTextCalls++;
    callOrder.add('text');
    lastProbeApiKey = apiKey;
    lastProbeModel = model;
    final error = textShouldThrow;
    if (error != null) throw error;
  }

  @override
  Future<void> probeTools({
    required String apiKey,
    required String model,
    required CancellationSignal cancellation,
  }) async {
    probeToolsCalls++;
    callOrder.add('tools');
    lastProbeApiKey = apiKey;
    lastProbeModel = model;
    final error = toolsShouldThrow;
    if (error != null) throw error;
  }

  @override
  Stream<LlmEvent> stream({
    required String apiKey,
    required LlmRequest request,
    required CancellationSignal cancellation,
  }) {
    throw UnimplementedError();
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

Future<void> _seedSummary(
  AppDatabase database,
  String accountId, {
  String content = '本周讨论了高等数学',
}) => database
    .into(database.conversationSummaries)
    .insert(
      ConversationSummariesCompanion.insert(
        id: 'summary-1',
        accountId: accountId,
        throughOrdinal: 5,
        content: content,
        model: AgentConfigurationService.defaultModel,
        createdAt: 1000,
      ),
    );

void main() {
  late AppDatabase database;
  late DriftChatRepository chatRepository;
  late AgentConfigurationService config;
  late ProtectedAgentSecretStore secrets;

  setUp(() async {
    database = await _fixtureDatabase();
    addTearDown(database.close);
    await _seedAccount(database, 'account-a');
    chatRepository = DriftChatRepository(database);
    config = AgentConfigurationService(
      database: database,
      chatRepository: chatRepository,
      now: () => 100,
    );
    secrets = ProtectedAgentSecretStore(
      database: database,
      protector: _ReversingFakeProtector(),
      now: () => 200,
    );
  });

  Widget harness(_FakeLlmProvider provider) {
    return MaterialApp(
      home: AgentSettingsPage(
        accountId: 'account-a',
        config: config,
        secrets: secrets,
        provider: provider,
        chatRepository: chatRepository,
        policyService: AgentPermissionPolicyService(
          database: database,
          clock: FixedBeijingClock(DateTime.fromMillisecondsSinceEpoch(100)),
        ),
      ),
    );
  }

  /// Pumps the page inside a tall viewport so every ListView child is built
  /// (Flutter lazily builds off-screen children, which would make bottom
  /// tiles unfindable in the default 800x600 surface).
  Future<void> pumpTall(WidgetTester tester, _FakeLlmProvider provider) async {
    // Task 9 enlarged the Agent permission section (more tool-backed action
    // rows); the taller viewport keeps the summary/clear buttons on-screen.
    tester.view.physicalSize = const Size(800, 4800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness(provider));
    await tester.pumpAndSettle();
  }

  group('AgentSettingsPage masked Key state', () {
    testWidgets('Key field is obscured and never pre-filled with stored key', (
      tester,
    ) async {
      await secrets.saveKey('account-a', 'super-secret');
      await config.enable('account-a', true);
      final provider = _FakeLlmProvider();
      await tester.pumpWidget(harness(provider));
      await tester.pumpAndSettle();

      // Masked indicator reflects hasKey, not the raw key.
      expect(find.text('已设置'), findsOneWidget);
      expect(find.text('未设置'), findsNothing);
      // The raw key must never appear in the tree.
      expect(find.text('super-secret'), findsNothing);
      // The Key entry field starts empty and is obscured.
      final keyField = find.byKey(const Key('agent-api-key-field'));
      expect(keyField, findsOneWidget);
      final textField = tester.widget<TextField>(keyField);
      expect(textField.obscureText, isTrue);
      expect(textField.controller!.text, isEmpty);
    });

    testWidgets('unconfigured state shows the embedded setup panel', (
      tester,
    ) async {
      final provider = _FakeLlmProvider();
      await tester.pumpWidget(harness(provider));
      await tester.pumpAndSettle();
      // Unconfigured => the reusable setup panel is shown (not the full
      // configured UI), and its obscured key field is present and empty.
      expect(find.byKey(const Key('agent-setup-key-field')), findsOneWidget);
      expect(find.byKey(const Key('agent-setup-save')), findsOneWidget);
      expect(find.byKey(const Key('agent-api-key-field')), findsNothing);
      expect(find.byKey(const Key('agent-save-key')), findsNothing);
      final textField = tester.widget<TextField>(
        find.byKey(const Key('agent-setup-key-field')),
      );
      expect(textField.obscureText, isTrue);
      expect(textField.controller!.text, isEmpty);
    });
  });

  group('AgentSettingsPage save/replace/delete Key', () {
    testWidgets('replace updates the stored key', (tester) async {
      await secrets.saveKey('account-a', 'old-key');
      await config.enable('account-a', true);
      final provider = _FakeLlmProvider();
      await tester.pumpWidget(harness(provider));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('agent-api-key-field')),
        'replacement-key',
      );
      await tester.tap(find.byKey(const Key('agent-save-key')));
      await tester.pumpAndSettle();

      expect(provider.probeTextCalls, 1);
      expect(provider.probeToolsCalls, 1);
      expect(provider.lastProbeApiKey, 'replacement-key');
      expect(await secrets.readKey('account-a'), 'replacement-key');
      final snapshot = await config.load('account-a');
      expect(snapshot.enabled, isTrue);
    });

    testWidgets(
      'replace with a bad key blocks overwrite and shows safe error copy',
      (tester) async {
        await secrets.saveKey('account-a', 'good-key');
        await config.enable('account-a', true);
        final provider = _FakeLlmProvider(
          textShouldThrow: const LlmProtocolException('auth_failed'),
        );
        await tester.pumpWidget(harness(provider));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('agent-api-key-field')),
          'bad-replacement',
        );
        await tester.tap(find.byKey(const Key('agent-save-key')));
        await tester.pumpAndSettle();

        // The existing key is preserved; the bad replacement is not saved.
        expect(await secrets.readKey('account-a'), 'good-key');
        expect(find.text('API Key 无效或已过期'), findsOneWidget);
        // No Text widget echoes the raw replacement key.
        expect(
          find.byWidgetPredicate(
            (w) =>
                w is Text &&
                w.data != null &&
                w.data!.contains('bad-replacement'),
          ),
          findsNothing,
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('agent-api-key-field')))
              .obscureText,
          isTrue,
        );
      },
    );

    testWidgets('delete Key leaves chat but disables sending', (tester) async {
      await secrets.saveKey('account-a', 'k');
      // Simulate prior enabled state from a successful save.
      await config.enable('account-a', true);
      final provider = _FakeLlmProvider();
      await tester.pumpWidget(harness(provider));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('agent-delete-key')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();

      expect(await secrets.hasKey('account-a'), isFalse);
      final snapshot = await config.load('account-a');
      expect(snapshot.enabled, isFalse);
      // After delete the page is unconfigured again, so the setup panel
      // reappears (the configured Key section is gone).
      expect(find.byKey(const Key('agent-setup-key-field')), findsOneWidget);
      expect(find.byKey(const Key('agent-delete-key')), findsNothing);
    });
  });

  group('AgentSettingsPage embedded setup panel', () {
    // The page embeds AgentSetupPanel when unconfigured (no key). These tests
    // exercise the panel's own _saveAndEnable flow through the page so its
    // security-critical path (probe-gating, safe error copy, field clear) is
    // covered and would fail if a probe were skipped or the key leaked.

    testWidgets('panel save runs both probes then saves Key and enables', (
      tester,
    ) async {
      // No key stored => unconfigured => panel is shown.
      final provider = _FakeLlmProvider();
      await tester.pumpWidget(harness(provider));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('agent-setup-key-field')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('agent-setup-key-field')),
        'setup-key',
      );
      await tester.tap(find.byKey(const Key('agent-setup-save')));
      await tester.pumpAndSettle();

      expect(provider.probeTextCalls, 1);
      expect(provider.probeToolsCalls, 1);
      expect(provider.lastProbeApiKey, 'setup-key');
      expect(provider.lastProbeModel, AgentConfigurationService.defaultModel);
      expect(await secrets.hasKey('account-a'), isTrue);
      expect(await secrets.readKey('account-a'), 'setup-key');
      expect((await config.load('account-a')).enabled, isTrue);
      // After a successful save the panel is replaced by the configured UI,
      // which means the ephemeral key field (and its controller) is gone.
      expect(find.byKey(const Key('agent-setup-key-field')), findsNothing);
    });

    testWidgets(
      'panel lists models first and selects an available non-default model',
      (tester) async {
        final provider = _FakeLlmProvider(
          availableModels: const ['campus-model'],
        );
        await tester.pumpWidget(harness(provider));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('agent-setup-key-field')),
          'setup-key',
        );
        await tester.tap(find.byKey(const Key('agent-setup-save')));
        await tester.pumpAndSettle();

        expect(provider.callOrder.take(3), ['list', 'text', 'tools']);
        expect(provider.lastProbeModel, 'campus-model');
        final snapshot = await config.load('account-a');
        expect(snapshot.model, 'campus-model');
        expect(snapshot.enabled, isTrue);
      },
    );

    testWidgets('panel failed probe blocks save, shows safe copy, no leak', (
      tester,
    ) async {
      final provider = _FakeLlmProvider(
        textShouldThrow: const LlmProtocolException('auth_failed'),
      );
      await tester.pumpWidget(harness(provider));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('agent-setup-key-field')),
        'leak-check',
      );
      await tester.tap(find.byKey(const Key('agent-setup-save')));
      await tester.pumpAndSettle();

      expect(await secrets.hasKey('account-a'), isFalse);
      expect((await config.load('account-a')).enabled, isFalse);
      expect(find.text('API Key 无效或已过期'), findsOneWidget);
      // No Text widget echoes the raw key (the field stays obscured).
      expect(
        find.byWidgetPredicate(
          (w) => w is Text && w.data != null && w.data!.contains('leak-check'),
        ),
        findsNothing,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('agent-setup-key-field')))
            .obscureText,
        isTrue,
      );
      // Panel remains visible because configuration failed.
      expect(find.byKey(const Key('agent-setup-key-field')), findsOneWidget);
    });

    testWidgets('panel failed tools probe blocks save with safe copy', (
      tester,
    ) async {
      final provider = _FakeLlmProvider(
        toolsShouldThrow: const LlmProtocolException('probe_tool_not_emitted'),
      );
      await tester.pumpWidget(harness(provider));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('agent-setup-key-field')),
        'leak-check',
      );
      await tester.tap(find.byKey(const Key('agent-setup-save')));
      await tester.pumpAndSettle();

      // probeText succeeded but probeTools failed: nothing is persisted.
      expect(provider.probeTextCalls, 1);
      expect(provider.probeToolsCalls, 1);
      expect(await secrets.hasKey('account-a'), isFalse);
      expect((await config.load('account-a')).enabled, isFalse);
      expect(find.textContaining('工具'), findsWidgets);
      expect(
        find.byWidgetPredicate(
          (w) => w is Text && w.data != null && w.data!.contains('leak-check'),
        ),
        findsNothing,
      );
    });
  });

  group('AgentSettingsPage model list', () {
    testWidgets(
      'model dropdown lists models and defaults to deepseek-v4-flash',
      (tester) async {
        await secrets.saveKey('account-a', 'k');
        await config.enable('account-a', true);
        final provider = _FakeLlmProvider();
        await tester.pumpWidget(harness(provider));
        await tester.pumpAndSettle();

        // Default model is shown as the selected value.
        expect(find.text('deepseek-v4-flash'), findsOneWidget);
        // Open the dropdown and confirm both models are listed.
        await tester.tap(find.byKey(const Key('agent-model-dropdown')));
        await tester.pumpAndSettle();
        expect(find.text('deepseek-v4-pro'), findsOneWidget);
      },
    );

    testWidgets('model change requires both probes with existing key', (
      tester,
    ) async {
      await secrets.saveKey('account-a', 'stored-key');
      await config.enable('account-a', true);
      final provider = _FakeLlmProvider();
      await tester.pumpWidget(harness(provider));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('agent-model-dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('deepseek-v4-pro').last);
      await tester.pumpAndSettle();

      expect(provider.probeTextCalls, 1);
      expect(provider.probeToolsCalls, 1);
      expect(provider.lastProbeApiKey, 'stored-key');
      expect(provider.lastProbeModel, 'deepseek-v4-pro');
      expect((await config.load('account-a')).model, 'deepseek-v4-pro');
    });

    testWidgets('failed model-change probe reverts selection', (tester) async {
      await secrets.saveKey('account-a', 'stored-key');
      await config.enable('account-a', true);
      final provider = _FakeLlmProvider(
        textShouldThrow: const LlmProtocolException('server_error'),
      );
      await tester.pumpWidget(harness(provider));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('agent-model-dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('deepseek-v4-pro').last);
      await tester.pumpAndSettle();

      expect(
        (await config.load('account-a')).model,
        AgentConfigurationService.defaultModel,
      );
      expect(find.text('学校模型服务暂时不可用'), findsOneWidget);
    });
  });

  group('AgentSettingsPage probes', () {
    testWidgets('cancelled probe is silently ignored', (tester) async {
      final provider = _FakeLlmProvider(
        textShouldThrow: const LlmProtocolException('cancelled'),
      );
      await tester.pumpWidget(harness(provider));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('agent-setup-key-field')),
        'k',
      );
      await tester.tap(find.byKey(const Key('agent-setup-save')));
      await tester.pumpAndSettle();

      expect(await secrets.hasKey('account-a'), isFalse);
      // No safe-error copy shown for cancelled.
      expect(find.text('API Key 无效或已过期'), findsNothing);
      expect(find.text('学校模型服务暂时不可用'), findsNothing);
    });
  });

  group('AgentSettingsPage safe error copy', () {
    testWidgets('maps rate_limited', (tester) async {
      final provider = _FakeLlmProvider(
        textShouldThrow: const LlmProtocolException('rate_limited'),
      );
      await tester.pumpWidget(harness(provider));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('agent-setup-key-field')),
        'k',
      );
      await tester.tap(find.byKey(const Key('agent-setup-save')));
      await tester.pumpAndSettle();

      expect(find.text('请求过于频繁，请稍后重试'), findsOneWidget);
    });

    testWidgets('maps transport_error', (tester) async {
      final provider = _FakeLlmProvider(
        textShouldThrow: const LlmProtocolException('transport_error'),
      );
      await tester.pumpWidget(harness(provider));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('agent-setup-key-field')),
        'k',
      );
      await tester.tap(find.byKey(const Key('agent-setup-save')));
      await tester.pumpAndSettle();

      expect(find.text('无法连接学校模型服务，请检查校园网或 iWAN'), findsOneWidget);
    });

    testWidgets('maps protocol_error', (tester) async {
      final provider = _FakeLlmProvider(
        textShouldThrow: const LlmProtocolException('protocol_error'),
      );
      await tester.pumpWidget(harness(provider));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('agent-setup-key-field')),
        'k',
      );
      await tester.tap(find.byKey(const Key('agent-setup-save')));
      await tester.pumpAndSettle();

      expect(find.text('学校模型服务返回了非预期的响应'), findsOneWidget);
    });
  });

  group('AgentSettingsPage summary', () {
    testWidgets('current summary displays in a read-only selectable dialog', (
      tester,
    ) async {
      await secrets.saveKey('account-a', 'k');
      await config.enable('account-a', true);
      await _seedSummary(database, 'account-a', content: '本周讨论了高等数学');
      final provider = _FakeLlmProvider();
      await pumpTall(tester, provider);

      await tester.tap(find.byKey(const Key('agent-view-summary')));
      await tester.pumpAndSettle();

      expect(find.text('本周讨论了高等数学'), findsOneWidget);
      // SelectableText is used so users can inspect what will be sent.
      expect(find.byType(SelectableText), findsWidgets);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
    });

    testWidgets('clear summary leaves messages', (tester) async {
      await secrets.saveKey('account-a', 'k');
      await config.enable('account-a', true);
      await _seedSummary(database, 'account-a');
      final provider = _FakeLlmProvider();
      await pumpTall(tester, provider);

      await tester.tap(find.byKey(const Key('agent-clear-summary')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();

      expect(await chatRepository.latestSummary('account-a'), isNull);
    });
  });

  group('AgentSettingsPage conversation clear', () {
    testWidgets('clear conversation requires confirmation', (tester) async {
      await secrets.saveKey('account-a', 'k');
      await config.enable('account-a', true);
      await _seedSummary(database, 'account-a');
      final provider = _FakeLlmProvider();
      await pumpTall(tester, provider);

      await tester.tap(find.byKey(const Key('agent-clear-conversation')));
      await tester.pumpAndSettle();
      // Cancel first.
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(await chatRepository.latestSummary('account-a'), isNotNull);

      await tester.tap(find.byKey(const Key('agent-clear-conversation')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(await chatRepository.latestSummary('account-a'), isNull);
      // Key preserved.
      expect(await secrets.hasKey('account-a'), isTrue);
    });
  });

  group('AgentSettingsPage fixed host and no advanced fields', () {
    testWidgets('shows fixed school Host and iWAN requirement text', (
      tester,
    ) async {
      final provider = _FakeLlmProvider();
      await tester.pumpWidget(harness(provider));
      await tester.pumpAndSettle();

      expect(find.textContaining('https://api.llm.ustc.edu.cn'), findsWidgets);
      expect(find.textContaining('校园网'), findsWidgets);
      expect(find.textContaining('iWAN'), findsWidgets);
    });

    testWidgets(
      'does not expose arbitrary Base URL/temperature/max-token/system-prompt fields',
      (tester) async {
        final provider = _FakeLlmProvider();
        await tester.pumpWidget(harness(provider));
        await tester.pumpAndSettle();

        expect(find.text('Base URL'), findsNothing);
        expect(find.text('Temperature'), findsNothing);
        expect(find.text('Max Tokens'), findsNothing);
        expect(find.text('System Prompt'), findsNothing);
        expect(find.byKey(const Key('agent-base-url-field')), findsNothing);
        expect(find.byKey(const Key('agent-temperature-field')), findsNothing);
        expect(find.byKey(const Key('agent-max-tokens-field')), findsNothing);
        expect(
          find.byKey(const Key('agent-system-prompt-field')),
          findsNothing,
        );
      },
    );
  });
}
