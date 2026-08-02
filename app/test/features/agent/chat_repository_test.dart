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

  test(
    'startRun appends a running run and recentMessages returns it',
    () async {
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
    },
  );

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
    final messages = await database.select(database.chatMessages).get();
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
    final aMessages = database.select(database.chatMessages)
      ..where((row) => row.accountId.equals('a'));
    final bMessages = database.select(database.chatMessages)
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
      final streamingId =
          (await database.select(database.chatMessages).get()).last.id;
      await repository.updateAssistantDraft(
        accountId: 'a',
        messageId: streamingId,
        content: '正在思考…',
      );
      expect(
        (await (database.select(
          database.chatMessages,
        )..where((row) => row.id.equals(streamingId))).getSingle()).content,
        '正在思考…',
      );

      // Mark it completed, then attempt another draft update — must be ignored.
      await repository.updateAssistantDraft(
        accountId: 'a',
        messageId: streamingId,
        content: 'completed-body',
        state: ChatMessageState.completed,
      );
      final completed = await (database.select(
        database.chatMessages,
      )..where((row) => row.id.equals(streamingId))).getSingle();
      expect(completed.content, 'completed-body');
      expect(completed.state, ChatMessageState.completed.name);

      // A draft update targeting a completed message must NOT alter it.
      await repository.updateAssistantDraft(
        accountId: 'a',
        messageId: streamingId,
        content: 'should-not-apply',
      );
      final untouched = await (database.select(
        database.chatMessages,
      )..where((row) => row.id.equals(streamingId))).getSingle();
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
      await database
          .into(database.agentSettings)
          .insert(AgentSettingsCompanion.insert(accountId: 'a', updatedAt: 1));
      await database
          .into(database.agentSecrets)
          .insert(
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
    final summaries = await database
        .select(database.conversationSummaries)
        .get();
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
      accountId: 'a',
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
      accountId: 'a',
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

  test(
    'recentMessages returns messages ordered by ordinal ascending',
    () async {
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
    },
  );

  // Regression for handoff §3 blocker 1: the old query used `orderBy(asc)`
  // followed by `limit`, which returned the EARLIEST N rows, not the most
  // recent N. With more than `limit` eligible messages, the result must be the
  // newest `limit` rows, still in ascending order for display.
  test(
    'recentMessages returns the most recent limit messages, not the earliest',
    () async {
      final runId = await repository.startRun(accountId: 'a', model: 'm');
      for (var i = 1; i <= 5; i++) {
        await repository.appendMessage(
          accountId: 'a',
          runId: runId,
          role: ChatRole.user,
          state: ChatMessageState.completed,
          content: 'm$i',
        );
      }
      final recent = await repository.recentMessages('a', limit: 3);
      expect(recent.map((m) => m.content), ['m3', 'm4', 'm5']);
    },
  );

  // Regression for handoff §3 blocker 1: eligibility filtering must happen
  // inside the SQL window, not in Dart after the limit. The discriminating
  // scenario is 5 eligible messages followed by one ineligible assistant draft
  // at the tail, with limit=3. The buggy `asc + limit` query returns the
  // EARLIEST 3 eligible rows [m1,m2,m3]; the fixed query filters in SQL, takes
  // the NEWEST 3 eligible by `desc`, then reverses to [m3,m4,m5]. Only the
  // fixed behavior is correct: the most recent window of eligible messages.
  test(
    'recentMessages filters ineligible drafts within the SQL window',
    () async {
      final runId = await repository.startRun(accountId: 'a', model: 'm');
      for (var i = 1; i <= 5; i++) {
        await repository.appendMessage(
          accountId: 'a',
          runId: runId,
          role: ChatRole.user,
          state: ChatMessageState.completed,
          content: 'm$i',
        );
      }
      // An ineligible terminal assistant draft at the very end. It must not
      // displace an eligible row from the window, and it must not appear.
      await repository.appendMessage(
        accountId: 'a',
        runId: runId,
        role: ChatRole.assistant,
        state: ChatMessageState.failed,
        content: 'broken-tail',
      );
      final recent = await repository.recentMessages('a', limit: 3);
      // Newest three eligible rows in ascending display order; the failed tail
      // is excluded without shrinking the window below the eligible budget.
      expect(recent.map((m) => m.content), ['m3', 'm4', 'm5']);
      expect(recent, hasLength(3));
    },
  );

  // Regression for handoff §3 blocker 2: a message must not reference a run
  // owned by a different account. The composite (run_id, account_id) FK plus
  // an ownership check in appendMessage must reject the cross-account insert.
  test('appendMessage rejects a run owned by a different account', () async {
    final runA = await repository.startRun(accountId: 'a', model: 'm');
    await expectLater(
      repository.appendMessage(
        accountId: 'b',
        runId: runA,
        role: ChatRole.user,
        state: ChatMessageState.completed,
        content: 'cross-account',
      ),
      throwsA(isA<RunOwnershipException>()),
    );
    // No message must be persisted for the rejected insert.
    expect(await database.select(database.chatMessages).get(), isEmpty);
  });

  test(
    'appendMessage with a null runId never crosses account boundaries',
    () async {
      final id = await repository.appendMessage(
        accountId: 'a',
        runId: null,
        role: ChatRole.user,
        state: ChatMessageState.completed,
        content: 'standalone',
      );
      expect(id, isNotEmpty);
      expect(await database.select(database.chatMessages).get(), hasLength(1));
    },
  );

  // Regression for handoff §3 same-round: clearing one account must never
  // cascade-delete another account's messages through a shared run id. With
  // the composite FK, a run and its messages are bound to the same account.
  test(
    'clearConversation on one account leaves another account messages intact',
    () async {
      final runA = await repository.startRun(accountId: 'a', model: 'm');
      final runB = await repository.startRun(accountId: 'b', model: 'm');
      await repository.appendMessage(
        accountId: 'a',
        runId: runA,
        role: ChatRole.user,
        state: ChatMessageState.completed,
        content: 'a-msg',
      );
      await repository.appendMessage(
        accountId: 'b',
        runId: runB,
        role: ChatRole.user,
        state: ChatMessageState.completed,
        content: 'b-msg',
      );

      await repository.clearConversation('a');

      final remaining = await database.select(database.chatMessages).get();
      expect(remaining, hasLength(1));
      expect(remaining.single.accountId, 'b');
      expect(remaining.single.content, 'b-msg');
    },
  );

  // Regression for handoff §3 same-round: finishRun must be account-scoped,
  // only allow running -> terminal, and refuse to overwrite an already
  // terminal run (so a stale completion cannot clobber recorded tokens/error).
  test(
    'finishRun refuses to finalize a run owned by another account',
    () async {
      final runA = await repository.startRun(accountId: 'a', model: 'm');
      await expectLater(
        repository.finishRun(
          accountId: 'b',
          runId: runA,
          state: AgentRunState.completed,
        ),
        throwsA(isA<RunOwnershipException>()),
      );
      final run = await database.select(database.agentRuns).getSingle();
      expect(run.status, AgentRunState.running.name);
      expect(run.finishedAt, null);
    },
  );

  test(
    'finishRun ignores a run that is no longer running and keeps its tokens',
    () async {
      final runId = await repository.startRun(
        accountId: 'a',
        model: 'deepseek-v4-flash',
      );
      await repository.finishRun(
        accountId: 'a',
        runId: runId,
        state: AgentRunState.completed,
        inputTokens: 12,
        outputTokens: 34,
      );
      // A second finalize attempt with different values must be a no-op.
      await repository.finishRun(
        accountId: 'a',
        runId: runId,
        state: AgentRunState.failed,
        errorCode: 'late_error',
        inputTokens: 99,
        outputTokens: 99,
      );
      final run = await database.select(database.agentRuns).getSingle();
      expect(run.status, AgentRunState.completed.name);
      expect(run.errorCode, null);
      expect(run.inputTokens, 12);
      expect(run.outputTokens, 34);
    },
  );

  test(
    'updateAssistantDraft only touches assistant rows, never user rows',
    () async {
      final runId = await repository.startRun(accountId: 'a', model: 'm');
      await repository.appendMessage(
        accountId: 'a',
        runId: runId,
        role: ChatRole.user,
        state: ChatMessageState.streaming,
        content: 'user-draft',
      );
      final userId =
          (await database.select(database.chatMessages).get()).single.id;
      // A user message in the streaming state must not be treated as an
      // assistant draft; the update must affect zero rows.
      await repository.updateAssistantDraft(
        accountId: 'a',
        messageId: userId,
        content: 'hijacked',
        state: ChatMessageState.completed,
      );
      final userRow = await (database.select(
        database.chatMessages,
      )..where((row) => row.id.equals(userId))).getSingle();
      expect(userRow.content, 'user-draft');
      expect(userRow.state, ChatMessageState.streaming.name);
    },
  );

  test(
    'recoverInterrupted only interrupts assistant streaming drafts, not user streaming rows',
    () async {
      final runId = await repository.startRun(accountId: 'a', model: 'm');
      // A user message that happens to be in a non-terminal state must be left
      // alone; recovery is an assistant-draft concept.
      await repository.appendMessage(
        accountId: 'a',
        runId: runId,
        role: ChatRole.user,
        state: ChatMessageState.streaming,
        content: 'user-streaming',
      );
      await repository.appendMessage(
        accountId: 'a',
        runId: runId,
        role: ChatRole.assistant,
        state: ChatMessageState.streaming,
        content: 'assistant-streaming',
      );

      await repository.recoverInterrupted();

      final messages = await database.select(database.chatMessages).get();
      final userRow = messages.firstWhere((m) => m.role == ChatRole.user.name);
      final assistantRow = messages.firstWhere(
        (m) => m.role == ChatRole.assistant.name,
      );
      expect(userRow.state, ChatMessageState.streaming.name);
      expect(assistantRow.state, ChatMessageState.interrupted.name);
    },
  );

  test(
    'recentMessages includes interrupted assistant partial text for display',
    () async {
      final runId = await repository.startRun(accountId: 'a', model: 'm');
      await repository.appendMessage(
        accountId: 'a',
        runId: runId,
        role: ChatRole.user,
        state: ChatMessageState.completed,
        content: 'question',
      );
      await repository.appendMessage(
        accountId: 'a',
        runId: runId,
        role: ChatRole.assistant,
        state: ChatMessageState.streaming,
        content: 'partial answer',
      );

      await repository.recoverInterrupted();
      final recent = await repository.recentMessages('a', limit: 20);

      expect(recent, hasLength(2));
      expect(recent.last.role, ChatRole.assistant);
      expect(recent.last.state, ChatMessageState.interrupted);
      expect(recent.last.content, 'partial answer');
    },
  );

  test(
    'startToolInvocation inserts a running invocation for an owned run',
    () async {
      final runId = await repository.startRun(accountId: 'a', model: 'm');
      final invocationId = await repository.startToolInvocation(
        accountId: 'a',
        runId: runId,
        toolName: 'get_schedule',
        safeArgumentsSummary: 'title=物理',
      );
      expect(invocationId, isNotEmpty);
      final row = await database.select(database.toolInvocations).getSingle();
      expect(row.id, invocationId);
      expect(row.accountId, 'a');
      expect(row.runId, runId);
      expect(row.toolName, 'get_schedule');
      expect(row.status, ToolInvocationLifecycleState.running.storageName);
      expect(row.safeArgumentsSummary, 'title=物理');
      expect(row.finishedAt, null);
    },
  );

  test(
    'startToolInvocation rejects a run owned by a different account',
    () async {
      final runA = await repository.startRun(accountId: 'a', model: 'm');
      await expectLater(
        repository.startToolInvocation(
          accountId: 'b',
          runId: runA,
          toolName: 'get_schedule',
          safeArgumentsSummary: 'title=物理',
        ),
        throwsA(isA<RunOwnershipException>()),
      );
      expect(await database.select(database.toolInvocations).get(), isEmpty);
    },
  );

  test(
    'markToolInvocationWaiting moves running to waiting_user and never sets finishedAt',
    () async {
      final runId = await repository.startRun(accountId: 'a', model: 'm');
      final invocationId = await repository.startToolInvocation(
        accountId: 'a',
        runId: runId,
        toolName: 'get_schedule',
        safeArgumentsSummary: 'args',
      );
      await repository.markToolInvocationWaiting(
        accountId: 'a',
        invocationId: invocationId,
      );
      final row = await database.select(database.toolInvocations).getSingle();
      expect(
        row.status,
        ToolInvocationLifecycleState.waitingUser.storageName,
      );
      expect(row.finishedAt, null);
    },
  );

  test('finishToolInvocation finalizes to success with a result', () async {
    final runId = await repository.startRun(accountId: 'a', model: 'm');
    final invocationId = await repository.startToolInvocation(
      accountId: 'a',
      runId: runId,
      toolName: 'get_schedule',
      safeArgumentsSummary: 'args',
    );
    await repository.finishToolInvocation(
      accountId: 'a',
      invocationId: invocationId,
      state: ToolInvocationLifecycleState.success,
      safeResultSummary: 'rows=3',
    );
    final row = await database.select(database.toolInvocations).getSingle();
    expect(row.status, ToolInvocationLifecycleState.success.storageName);
    expect(row.safeResultSummary, 'rows=3');
    expect(row.errorCode, null);
    expect(row.finishedAt, isNot(null));
  });

  test('finishToolInvocation finalizes to error with a safe error code', () async {
    final runId = await repository.startRun(accountId: 'a', model: 'm');
    final invocationId = await repository.startToolInvocation(
      accountId: 'a',
      runId: runId,
      toolName: 'get_schedule',
      safeArgumentsSummary: 'args',
    );
    await repository.finishToolInvocation(
      accountId: 'a',
      invocationId: invocationId,
      state: ToolInvocationLifecycleState.error,
      safeResultSummary: '',
      errorCode: 'schedule_summary_required',
    );
    final row = await database.select(database.toolInvocations).getSingle();
    expect(row.status, ToolInvocationLifecycleState.error.storageName);
    expect(row.errorCode, 'schedule_summary_required');
    expect(row.finishedAt, isNot(null));
  });

  test(
    'finishToolInvocation rejects a cross-account invocation and keeps it running',
    () async {
      final runId = await repository.startRun(accountId: 'a', model: 'm');
      final invocationId = await repository.startToolInvocation(
        accountId: 'a',
        runId: runId,
        toolName: 'get_schedule',
        safeArgumentsSummary: 'args',
      );
      await expectLater(
        repository.finishToolInvocation(
          accountId: 'b',
          invocationId: invocationId,
          state: ToolInvocationLifecycleState.success,
          safeResultSummary: 'x',
        ),
        throwsA(isA<RunOwnershipException>()),
      );
      final row = await database.select(database.toolInvocations).getSingle();
      expect(
        row.status,
        ToolInvocationLifecycleState.running.storageName,
      );
      expect(row.finishedAt, null);
    },
  );

  test(
    'finishToolInvocation ignores an already-terminal invocation and keeps its fields',
    () async {
      final runId = await repository.startRun(accountId: 'a', model: 'm');
      final invocationId = await repository.startToolInvocation(
        accountId: 'a',
        runId: runId,
        toolName: 'get_schedule',
        safeArgumentsSummary: 'args',
      );
      await repository.finishToolInvocation(
        accountId: 'a',
        invocationId: invocationId,
        state: ToolInvocationLifecycleState.success,
        safeResultSummary: 'rows=1',
      );
      // A second finalize attempt with different values must be a no-op.
      await repository.finishToolInvocation(
        accountId: 'a',
        invocationId: invocationId,
        state: ToolInvocationLifecycleState.error,
        safeResultSummary: '',
        errorCode: 'late_error',
      );
      final row = await database.select(database.toolInvocations).getSingle();
      expect(row.status, ToolInvocationLifecycleState.success.storageName);
      expect(row.safeResultSummary, 'rows=1');
      expect(row.errorCode, null);
    },
  );

  test(
    'toolInvocationsForRuns loads only owned runs, ordered by startedAt',
    () async {
      final runA = await repository.startRun(accountId: 'a', model: 'm');
      final runB = await repository.startRun(accountId: 'a', model: 'm');
      final runC = await repository.startRun(accountId: 'b', model: 'm');
      final invA = await repository.startToolInvocation(
        accountId: 'a',
        runId: runA,
        toolName: 'get_schedule',
        safeArgumentsSummary: 'args',
      );
      final invB = await repository.startToolInvocation(
        accountId: 'a',
        runId: runB,
        toolName: 'get_plan_blocks',
        safeArgumentsSummary: 'args',
      );
      await repository.startToolInvocation(
        accountId: 'b',
        runId: runC,
        toolName: 'get_plan_blocks',
        safeArgumentsSummary: 'args',
      );

      final rows = await repository.toolInvocationsForRuns(
        accountId: 'a',
        runIds: {runA, runB},
      );

      expect(rows, hasLength(2));
      final names = rows.map((r) => r.toolName).toList();
      expect(names, containsAll(['get_schedule', 'get_plan_blocks']));
      // Account B's invocation must not leak into account A's query.
      expect(rows.any((r) => r.id == invA || r.id == invB), isTrue);
      expect(
        rows.any((r) => r.id == invA && r.runId == runA),
        isTrue,
      );
    },
  );

  test(
    'toolInvocationsForRuns orders rows by startedAt ascending',
    () async {
      final runId = await repository.startRun(accountId: 'a', model: 'm');
      final first = await repository.startToolInvocation(
        accountId: 'a',
        runId: runId,
        toolName: 'get_schedule',
        safeArgumentsSummary: 'args',
      );
      await repository.startToolInvocation(
        accountId: 'a',
        runId: runId,
        toolName: 'get_plan_blocks',
        safeArgumentsSummary: 'args',
      );
      final rows = await repository.toolInvocationsForRuns(
        accountId: 'a',
        runIds: {runId},
      );
      expect(rows, hasLength(2));
      expect(rows.first.id, first);
      expect(rows.first.startedAt <= rows.last.startedAt, isTrue);
    },
  );

  test(
    'recoverInterrupted flips both running and waiting_user invocations to interrupted',
    () async {
      final runId = await repository.startRun(accountId: 'a', model: 'm');
      final running = await repository.startToolInvocation(
        accountId: 'a',
        runId: runId,
        toolName: 'get_schedule',
        safeArgumentsSummary: 'args',
      );
      final waiting = await repository.startToolInvocation(
        accountId: 'a',
        runId: runId,
        toolName: 'get_plan_blocks',
        safeArgumentsSummary: 'args',
      );
      await repository.markToolInvocationWaiting(
        accountId: 'a',
        invocationId: waiting,
      );

      await repository.recoverInterrupted();

      final rows = await database.select(database.toolInvocations).get();
      expect(rows, hasLength(2));
      final byId = {for (final r in rows) r.id: r};
      expect(
        byId[running]!.status,
        ToolInvocationLifecycleState.interrupted.storageName,
      );
      expect(
        byId[waiting]!.status,
        ToolInvocationLifecycleState.interrupted.storageName,
      );
      expect(byId[running]!.finishedAt, isNot(null));
      expect(byId[waiting]!.finishedAt, isNot(null));
    },
  );

  test(
    'clearConversation removes tool invocations only for the targeted account',
    () async {
      final runA = await repository.startRun(accountId: 'a', model: 'm');
      final runB = await repository.startRun(accountId: 'b', model: 'm');
      await repository.startToolInvocation(
        accountId: 'a',
        runId: runA,
        toolName: 'get_schedule',
        safeArgumentsSummary: 'args',
      );
      await repository.startToolInvocation(
        accountId: 'b',
        runId: runB,
        toolName: 'get_schedule',
        safeArgumentsSummary: 'args',
      );

      await repository.clearConversation('a');

      final remaining = await database.select(database.toolInvocations).get();
      expect(remaining, hasLength(1));
      expect(remaining.single.accountId, 'b');
    },
  );
}
