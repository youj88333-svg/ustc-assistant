import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:ustc_assistant_app/app/router.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/agent/data/drift_chat_repository.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_models.dart';
import 'package:ustc_assistant_app/features/settings/presentation/official_websites_page.dart';

class _Launcher implements OfficialWebsiteLauncher {
  @override
  Future<bool> launch(Uri uri) async => true;
}

void main() {
  testWidgets('complete reset returns to the first-login sync route', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    await database
        .into(database.localAccounts)
        .insert(
          LocalAccountsCompanion.insert(
            id: 'account',
            maskedHint: 'PB****0000',
            isActive: const Value(true),
            createdAt: 1,
            updatedAt: 1,
          ),
        );

    // Seed Agent rows for this account so the cascade assertions below are
    // meaningful: every agent table has FKs with `onDelete: KeyAction.cascade`
    // on `local_accounts.id`, so deleting the account must remove them all.
    final chatRepository = DriftChatRepository(database);
    await database
        .into(database.agentSettings)
        .insert(
          AgentSettingsCompanion.insert(accountId: 'account', updatedAt: 1),
        );
    await database
        .into(database.agentSecrets)
        .insert(
          AgentSecretsCompanion.insert(
            accountId: 'account',
            apiKeyCiphertext: Uint8List.fromList([1, 2, 3]),
            scheme: 'fake-test',
            protectionVersion: 1,
            updatedAt: 1,
          ),
        );
    final runId = await chatRepository.startRun(
      accountId: 'account',
      model: 'deepseek-v4-flash',
    );
    await chatRepository.appendMessage(
      accountId: 'account',
      runId: runId,
      role: ChatRole.user,
      state: ChatMessageState.completed,
      content: 'hi',
    );
    await chatRepository.replaceSummary(
      accountId: 'account',
      throughOrdinal: 1,
      content: 'summary',
      model: 'deepseek-v4-flash',
    );

    // Pre-condition: the agent rows ARE present before the reset.
    expect(await database.select(database.agentSecrets).get(), hasLength(1));
    expect(await database.select(database.agentSettings).get(), hasLength(1));
    expect(await database.select(database.chatMessages).get(), hasLength(1));
    expect(await database.select(database.agentRuns).get(), hasLength(1));
    expect(
      await database.select(database.conversationSummaries).get(),
      hasLength(1),
    );

    final GoRouter router = buildRouter(_Launcher(), database);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    router.go('/settings');
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('complete-reset')),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('complete-reset')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认').last);
    await tester.pumpAndSettle();

    expect(router.routeInformationProvider.value.uri.path, '/sync');
    expect(find.byKey(const Key('first-login-username')), findsOneWidget);
    expect(await database.select(database.localAccounts).get(), isEmpty);

    // Cascading FK delete removes every agent row for the account.
    expect(await database.select(database.agentSecrets).get(), isEmpty);
    expect(await database.select(database.agentSettings).get(), isEmpty);
    expect(await database.select(database.chatMessages).get(), isEmpty);
    expect(await database.select(database.agentRuns).get(), isEmpty);
    expect(await database.select(database.toolInvocations).get(), isEmpty);
    expect(
      await database.select(database.conversationSummaries).get(),
      isEmpty,
    );

    await tester.tap(find.byKey(const Key('exit-sync')));
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/chat');

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
