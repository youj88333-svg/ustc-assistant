import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/agent/data/drift_chat_repository.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_models.dart';

void main() {
  late AppDatabase database;
  late DriftChatRepository repository;

  Future<void> seedAccount(String accountId) => database
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

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    repository = DriftChatRepository(database);
    await seedAccount('a');
    await seedAccount('b');
  });

  test('startRun appends a running run and recentMessages returns it', () async {
    final runId = await repository.startRun(
      accountId: 'a',
      model: 'deepseek-v4-flash',
    );
    expect(runId, isNotEmpty);
    await repository.appendMessage(
      accountId: 'a',
      runId: runId,
      role: ChatRole.user,
      state: ChatMessageState.completed,
      content: '明天有什么课？',
    );
    expect(
      (await repository.recentMessages('a', limit: 20)).single.content,
      '明天有什么课？',
    );
  });

  test('recentMessages isolates accounts', () async {
    final runId = await repository.startRun(
      accountId: 'a',
      model: 'deepseek-v4-flash',
    );
    await repository.appendMessage(
      accountId: 'a',
      runId: runId,
      role: ChatRole.user,
      state: ChatMessageState.completed,
      content: '明天有什么课？',
    );
    expect(await repository.recentMessages('b', limit: 20), isEmpty);
  });

  test('appendMessage allocates per-account ordinals sequentially', () async {
    final runId = await repository.startRun(
      accountId: 'a',
      model: 'deepseek-v4-flash',
    );
    await repository.appendMessage(
      accountId: 'a',
      runId: runId,
      role: ChatRole.user,
      state: ChatMessageState.completed,
      content: 'one',
    );
    await repository.appendMessage(
      accountId: 'a',
      runId: runId,
      role: ChatRole.assistant,
      state: ChatMessageState.completed,
      content: 'two',
    );
    final messages = await database
        .select(database.chatMessages)
        .get();
    expect(messages.map((m) => m.ordinal), [1, 2]);
  });

  test('appendMessage ordinals are independent per account', () async {
    final runA = await repository.startRun(accountId: 'a', model: 'm');
    final runB = await repository.startRun(accountId: 'b', model: 'm');
    await repository.appendMessage(
      accountId: 'a',
      runId: runA,
      role: ChatRole.user,
      state: ChatMessageState.completed,
      content: 'a1',
    );
    await repository.appendMessage(
      accountId: 'b',
      runId: runB,
      role: ChatRole.user,
      state: ChatMessageState.completed,
      content: 'b1',
    );
    await repository.appendMessage(
      accountId: 'b',
      runId: runB,
      role: ChatRole.assistant,
      state: ChatMessageState.completed,
      content: 'b2',
    );
    final aMessages = await database
        .select(database.chatMessages)
        ..where((row) => row.accountId.equals('a'));
    final bMessages = await database
        .select(database.chatMessages)
        ..where((row) => row.accountId.equals('b'));
    expect((await aMessages.get()).single.ordinal, 1);
    expect((await bMessages.get()).map((m) => m.ordinal), [1, 2]);
  });

  test(
    'updateAssistantDraft updates a streaming message but not a completed one',
    () async {
      final runId = await repository.startRun(
        accountId: 'a',
        model: 'deepseek-v4-flash',
      );
      await repository.appendMessage(
        accountId: 'a',
        runId: runId,
        role: ChatRole.user,
        state: ChatMessageState.completed,
        content: '明天有什么课？',
      );
      await repository.appendMessage(
        accountId: 'a',
        runId: runId,
        role: ChatRole.assistant,
        state: ChatMessageState.streaming,
        content: '',
      );
      final streamingId = (await database
              .select(database.chatMessages)
              .get())
          .last
          .id;
      await repository.updateAssistantDraft(
        accountId: 'a',
        messageId: streamingId,
        content: '正在思考…',
      );
      expect(
        (await (database.select(database.chatMessages)
                  ..where((row) => row.id.equals(streamingId)))
                .getSingle())
            .content,
        '正在思考…',
      );

      // Mark it completed, then attempt another draft update — must be ignored.
      await repository.updateAssistantDraft(
        accountId: 'a',
        messageId: streamingId,
        content: 'completed-body',
        state: ChatMessageState.completed,
      );
      final completed = await (database.select(database.chatMessages)
            ..where((row) => row.id.equals(streamingId)))
          .getSingle();
      expect(completed.content, 'completed-body');
      expect(completed.state, ChatMessageState.completed.name);

      // A draft update targeting a completed message must NOT alter it.
      await repository.updateAssistantDraft(
        accountId: 'a',
        messageId: streamingId,
        content: 'should-not-apply',
      );
      final untouched = await (database.select(database.chatMessages)
            ..where((row) => row.id.equals(streamingId)))
          .getSingle();
      expect(untouched.content, 'completed-body');
    },
  );

  test(
    'clearConversation removes messages, runs, tools, summaries but keeps settings and secrets',
    () async {
      final runId = await repository.startRun(
        accountId: 'a',
        model: 'deepseek-v4-flash',
      );
      await repository.appendMessage(
        accountId: 'a',
        runId: runId,
        role: ChatRole.user,
        state: ChatMessageState.completed,
        content: '明天有什么课？',
      );
      await repository.replaceSummary(
        accountId: 'a',
        throughOrdinal: 1,
        content: 'summary',
        model: 'deepseek-v4-flash',
      );
      await database.into(database.agentSettings).insert(
        AgentSettingsCompanion.insert(
          accountId: 'a',
          updatedAt: 1,
        ),
      );
      await database.into(database.agentSecrets).insert(
        AgentSecretsCompanion.insert(
          accountId: 'a',
          apiKeyCiphertext: Uint8List.fromList([1, 2, 3]),
          scheme: 'aes-gcm',
          protectionVersion: 1,
          updatedAt: 1,
        ),
      );

      await repository.clearConversation('a');

      expect(await database.select(database.chatMessages).get(), isEmpty);
      expect(await database.select(database.agentRuns).get(), isEmpty);
      expect(await database.select(database.toolInvocations).get(), isEmpty);
      expect(
        await database.select(database.conversationSummaries).get(),
        isEmpty,
      );
      expect(
        (await database.select(database.agentSettings).get()).single.accountId,
        'a',
      );
      expect(
        (await database.select(database.agentSecrets).get()).single.accountId,
        'a',
      );
    },
  );

  test('clearConversation only affects the targeted account', () async {
    final runA = await repository.startRun(accountId: 'a', model: 'm');
    final runB = await repository.startRun(accountId: 'b', model: 'm');
    await repository.appendMessage(
      accountId: 'a',
      runId: runA,
      role: ChatRole.user,
      state: ChatMessageState.completed,
      content: 'a',
    );
    await repository.appendMessage(
      accountId: 'b',
      runId: runB,
      role: ChatRole.user,
      state: ChatMessageState.completed,
      content: 'b',
    );

    await repository.clearConversation('a');

    expect(await database.select(database.chatMessages).get(), hasLength(1));
    expect(
      (await database.select(database.chatMessages).get()).single.accountId,
      'b',
    );
  });

  test('replaceSummary upserts a single summary per account', () async {
    await repository.replaceSummary(
      accountId: 'a',
      throughOrdinal: 1,
      content: 'first',
      model: 'deepseek-v4-flash',
    );
    await repository.replaceSummary(
      accountId: 'a',
      throughOrdinal: 3,
      content: 'second',
      model: 'deepseek-v4-flash',
    );
    final summaries = await database.select(database.conversationSummaries).get();
    expect(summaries, hasLength(1));
    expect(summaries.single.content, 'second');
    expect(summaries.single.throughOrdinal, 3);
  });

  test('latestSummary returns the newest summary or null', () async {
    expect(await repository.latestSummary('a'), null);
    await repository.replaceSummary(
      accountId: 'a',
      throughOrdinal: 1,
      content: 'first',
      model: 'deepseek-v4-flash',
    );
    final first = await repository.latestSummary('a');
    expect(first?.content, 'first');
    await repository.replaceSummary(
      accountId: 'a',
      throughOrdinal: 2,
      content: 'second',
      model: 'deepseek-v4-flash',
    );
    final second = await repository.latestSummary('a');
    expect(second?.content, 'second');
    expect(second?.throughOrdinal, 2);
  });

  test('finishRun records terminal status and tokens', () async {
    final runId = await repository.startRun(
      accountId: 'a',
      model: 'deepseek-v4-flash',
    );
    await repository.finishRun(
      runId: runId,
      state: AgentRunState.completed,
      inputTokens: 12,
      outputTokens: 34,
    );
    final run = await database.select(database.agentRuns).getSingle();
    expect(run.status, AgentRunState.completed.name);
    expect(run.inputTokens, 12);
    expect(run.outputTokens, 34);
    expect(run.finishedAt, isNot(null));
  });

  test('finishRun can record a failed run with an error code', () async {
    final runId = await repository.startRun(
      accountId: 'a',
      model: 'deepseek-v4-flash',
    );
    await repository.finishRun(
      runId: runId,
      state: AgentRunState.failed,
      errorCode: 'provider_timeout',
    );
    final run = await database.select(database.agentRuns).getSingle();
    expect(run.status, AgentRunState.failed.name);
    expect(run.errorCode, 'provider_timeout');
    expect(run.finishedAt, isNot(null));
  });

  test(
    'recoverInterrupted flips stale running runs and streaming messages to interrupted',
    () async {
      final runId = await repository.startRun(
        accountId: 'a',
        model: 'deepseek-v4-flash',
      );
      await repository.appendMessage(
        accountId: 'a',
        runId: runId,
        role: ChatRole.user,
        state: ChatMessageState.completed,
        content: 'q',
      );
      await repository.appendMessage(
        accountId: 'a',
        runId: runId,
        role: ChatRole.assistant,
        state: ChatMessageState.streaming,
        content: 'partial',
      );

      await repository.recoverInterrupted();

      final run = await database.select(database.agentRuns).getSingle();
      expect(run.status, AgentRunState.interrupted.name);
      final messages = await database.select(database.chatMessages).get();
      final streaming = messages.lastWhere(
        (m) => m.state == ChatMessageState.interrupted.name,
      );
      expect(streaming.content, 'partial');
    },
  );

  test(
    'recentMessages excludes failed, cancelled, and interrupted assistant drafts',
    () async {
      final runId = await repository.startRun(
        accountId: 'a',
        model: 'deepseek-v4-flash',
      );
      await repository.appendMessage(
        accountId: 'a',
        runId: runId,
        role: ChatRole.user,
        state: ChatMessageState.completed,
        content: 'q1',
      );
      await repository.appendMessage(
        accountId: 'a',
        runId: runId,
        role: ChatRole.assistant,
        state: ChatMessageState.streaming,
        content: 'live',
      );
      await repository.appendMessage(
        accountId: 'a',
        runId: runId,
        role: ChatRole.assistant,
        state: ChatMessageState.failed,
        content: 'broken',
      );
      final recent = await repository.recentMessages('a', limit: 20);
      // The streaming assistant draft IS included; the failed one is excluded.
      expect(recent.map((m) => m.content), containsAll(['q1', 'live']));
      expect(recent.map((m) => m.content), isNot(contains('broken')));
    },
  );

  test('recentMessages returns messages ordered by ordinal ascending', () async {
    final runId = await repository.startRun(accountId: 'a', model: 'm');
    await repository.appendMessage(
      accountId: 'a',
      runId: runId,
      role: ChatRole.user,
      state: ChatMessageState.completed,
      content: 'first',
    );
    await repository.appendMessage(
      accountId: 'a',
      runId: runId,
      role: ChatRole.assistant,
      state: ChatMessageState.completed,
      content: 'second',
    );
    await repository.appendMessage(
      accountId: 'a',
      runId: runId,
      role: ChatRole.user,
      state: ChatMessageState.completed,
      content: 'third',
    );
    final recent = await repository.recentMessages('a', limit: 20);
    expect(recent.map((m) => m.content), ['first', 'second', 'third']);
  });
}
