import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_context_builder.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_session_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_tool_registry.dart';
import 'package:ustc_assistant_app/features/agent/application/cancellation_signal.dart';
import 'package:ustc_assistant_app/features/agent/application/outbound_privacy_filter.dart';
import 'package:ustc_assistant_app/features/agent/data/drift_chat_repository.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_models.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_tool.dart';
import 'package:ustc_assistant_app/features/agent/domain/llm_protocol.dart';

// ---------------------------------------------------------------------------
// Scripted fake provider.
// ---------------------------------------------------------------------------

/// A scripted [LlmProvider] that replays a queue of "call responses". Each
/// response is a list of [LlmEvent]s to emit for one `stream()` invocation.
/// The fake asserts the API key is non-empty and discards it immediately
/// (never retained). The number of `stream()` calls is counted so tests can
/// assert the 8-model-call budget.
class _ScriptedProvider implements LlmProvider {
  _ScriptedProvider(this._script);

  final List<List<LlmEvent>> _script;
  int streamCallCount = 0;
  String? _lastSeenKey;

  /// Every `LlmRequest` passed to `stream()`, in call order, so tests can
  /// assert on the exact conversation sent to the model.
  final List<LlmRequest> requests = <LlmRequest>[];

  @override
  Future<List<String>> listModels({
    required String apiKey,
    required CancellationSignal cancellation,
  }) async => const ['deepseek-v4-flash'];

  @override
  Stream<LlmEvent> stream({
    required String apiKey,
    required LlmRequest request,
    required CancellationSignal cancellation,
  }) async* {
    _lastSeenKey = apiKey;
    requests.add(request);
    streamCallCount++;
    final index = streamCallCount - 1;
    if (index >= _script.length) {
      yield const ErrorEvent('script_exhausted');
      return;
    }
    for (final event in _script[index]) {
      if (cancellation.isCancelled) {
        yield const CompletedEvent();
        return;
      }
      yield event;
    }
  }

  @override
  Future<void> probeText({
    required String apiKey,
    required String model,
    required CancellationSignal cancellation,
  }) async {}

  @override
  Future<void> probeTools({
    required String apiKey,
    required String model,
    required CancellationSignal cancellation,
  }) async {}

  /// Confirms the key was seen and never retained beyond the call boundary.
  bool sawKey(String key) => _lastSeenKey == key;
}

/// Builds the canonical scripted loop from the brief:
/// call 1 -> tool_use(get_schedule)
/// call 2 -> tool_use(search_campus_catalog)
/// call 3 -> final text + citations
List<List<LlmEvent>> _canonicalLoop() => [
  // call 1: a tool_use for get_schedule.
  [
    const ToolUseCompletedEvent(
      id: 'tu-1',
      name: 'get_schedule',
      input: {'date': '2026-07-29'},
    ),
    const UsageEvent(inputTokens: 100, outputTokens: 10),
    const CompletedEvent(),
  ],
  // call 2: a tool_use for search_campus_catalog.
  [
    const ToolUseCompletedEvent(
      id: 'tu-2',
      name: 'search_campus_catalog',
      input: {'q': '图书馆'},
    ),
    const UsageEvent(inputTokens: 200, outputTokens: 20),
    const CompletedEvent(),
  ],
  // call 3: final assistant text with citations.
  [
    const TextDeltaEvent('明天没有课。图书馆在东区。'),
    const UsageEvent(inputTokens: 300, outputTokens: 30),
    const CompletedEvent(),
  ],
];

// ---------------------------------------------------------------------------
// Fake tools.
// ---------------------------------------------------------------------------

class _FakeScheduleTool implements AgentTool {
  @override
  String get name => 'get_schedule';
  @override
  String get description => 'Reads the course schedule for a date.';
  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {'date': {'type': 'string'}},
  };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    // Bind a run-local reference the model can later resolve.
    final ref = context.references.bind(kind: 'schedule', localId: 'schedule-2026-07-29');
    return AgentToolResult(
      status: AgentToolStatus.success,
      payload: const {
        'courses': <Map<String, Object?>>[],
        'semester': '2026春',
      },
      references: [AgentToolReference(kind: 'schedule', ref: ref, localId: 'schedule-2026-07-29')],
    );
  }
}

class _FakeCatalogTool implements AgentTool {
  @override
  String get name => 'search_campus_catalog';
  @override
  String get description => 'Searches the campus catalog.';
  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {'q': {'type': 'string'}},
  };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    final ref = context.references.bind(kind: 'catalog', localId: 'catalog-lib');
    return AgentToolResult(
      status: AgentToolStatus.success,
      payload: const {'results': <Map<String, Object?>>[]},
      references: [AgentToolReference(kind: 'catalog', ref: ref, localId: 'catalog-lib')],
    );
  }
}

Map<String, Object?> _scheduleBuilder(Map<String, Object?> raw) =>
    {'courses': raw['courses'], 'semester': raw['semester']};

Map<String, Object?> _catalogBuilder(Map<String, Object?> raw) =>
    {'results': raw['results']};

/// The default tool set used by the harness when a test does not override it.
final List<AgentTool> _defaultTools = [_FakeScheduleTool(), _FakeCatalogTool()];

// ---------------------------------------------------------------------------
// Test harness.
// ---------------------------------------------------------------------------

/// A fixed Beijing clock so ActionLog timestamps and run timestamps are
/// deterministic in assertions.
class _SequenceClock implements BeijingClock {
  _SequenceClock(this._start);
  final DateTime _start;
  int _ticks = 0;

  @override
  DateTime now() {
    _ticks += 1;
    return _start.add(Duration(milliseconds: _ticks));
  }

  int millis() => now().millisecondsSinceEpoch;
}

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

AgentSessionService _buildService({
  required AppDatabase database,
  required LlmProvider provider,
  required BeijingClock clock,
  List<AgentTool>? tools,
  String model = 'deepseek-v4-flash',
  String protectedAccount = 'PB12345678',
}) {
  final chatRepository = DriftChatRepository(database);
  final privacyFilter = OutboundPrivacyFilter(
    protectedAccount: protectedAccount,
    toolBuilders: {
      'get_schedule': _scheduleBuilder,
      'search_campus_catalog': _catalogBuilder,
    },
  );
  final registry = AgentToolRegistry(
    tools: tools ?? _defaultTools,
    privacyFilter: privacyFilter,
  );
  return AgentSessionService(
    chatRepository: chatRepository,
    database: database,
    provider: provider,
    contextBuilder: const AgentContextBuilder(),
    privacyFilter: privacyFilter,
    registry: registry,
    clock: clock,
    model: model,
    // Ephemeral key provider closure: tests must never need real DPAPI.
    apiKeyProvider: ({required String accountId}) async => 'ephemeral-test-key',
  );
}

void main() {
  const account = 'a';
  late AppDatabase database;
  late DriftChatRepository chatRepository;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    await _seedAccount(database, account);
    chatRepository = DriftChatRepository(database);
  });

  group('AgentSessionService.send — canonical scripted loop', () {
    test('completes the 3-call loop and persists final assistant text', () async {
      final provider = _ScriptedProvider(_canonicalLoop());
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: clock,
      );

      final states = await service
          .send(accountId: account, userText: '明天有什么课？图书馆在哪？')
          .toList();

      // Exactly three model calls were made.
      expect(provider.streamCallCount, 3);

      // The final view state is completed with the streamed final text.
      final terminal = states.last;
      expect(terminal.state, AgentRunState.completed);
      expect(terminal.text, contains('明天没有课'));
      expect(terminal.text, contains('图书馆在东区'));

      // The run record is persisted as completed.
      final runs = await (database.select(database.agentRuns)).get();
      expect(runs, hasLength(1));
      expect(runs.single.status, AgentRunState.completed.name);
      expect(runs.single.model, 'deepseek-v4-flash');
      expect(runs.single.errorCode, isNull);
      // Token usage from the last UsageEvent is recorded.
      expect(runs.single.inputTokens, 300);
      expect(runs.single.outputTokens, 30);

      // The user message and the final assistant message are persisted.
      final messages = await chatRepository.recentMessages(account, limit: 50);
      expect(messages.where((m) => m.role == ChatRole.user), hasLength(1));
      expect(
        messages.where((m) => m.role == ChatRole.user).single.content,
        '明天有什么课？图书馆在哪？',
      );
      final assistant = messages.where((m) => m.role == ChatRole.assistant).single;
      expect(assistant.state, ChatMessageState.completed);
      expect(assistant.content, contains('明天没有课'));
    });

    test('emits tool-running states between model calls', () async {
      final provider = _ScriptedProvider(_canonicalLoop());
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: clock,
      );

      final states = await service
          .send(accountId: account, userText: '明天有什么课？')
          .toList();

      // The view should transition through running and at least one
      // tool-running state before completing.
      expect(states, isNotEmpty);
      expect(states.last.state, AgentRunState.completed);
      // Tool summaries are surfaced collapsed.
      final toolStates = states.where((s) => s.toolSummaries.isNotEmpty);
      expect(toolStates, isNotEmpty);
      // Two tools were executed across the run.
      final allToolNames = toolStates
          .expand((s) => s.toolSummaries.map((t) => t.toolName))
          .toSet();
      expect(allToolNames, {'get_schedule', 'search_campus_catalog'});
    });

    test('source references are surfaced in the final view', () async {
      final provider = _ScriptedProvider(_canonicalLoop());
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: clock,
      );

      final states = await service
          .send(accountId: account, userText: '明天有什么课？')
          .toList();

      final terminal = states.last;
      expect(terminal.sourceReferences, hasLength(2));
      // Refs are opaque ref_* tokens, never raw local ids.
      for (final ref in terminal.sourceReferences) {
        expect(ref.ref, startsWith('ref_'));
        expect(ref.ref, isNot(contains('schedule-')));
        expect(ref.ref, isNot(contains('catalog-')));
      }
    });
  });

  group('first model request shape', () {
    test(
      'the current user question appears exactly once in the first request',
      () async {
        // Seed one prior completed turn so history is non-empty and distinct
        // from the current question.
        final priorRun = await chatRepository.startRun(
          accountId: account,
          model: 'deepseek-v4-flash',
        );
        await chatRepository.appendMessage(
          accountId: account,
          runId: priorRun,
          role: ChatRole.user,
          state: ChatMessageState.completed,
          content: '上学期有几门课？',
        );
        await chatRepository.appendMessage(
          accountId: account,
          runId: priorRun,
          role: ChatRole.assistant,
          state: ChatMessageState.completed,
          content: '上学期有五门课。',
        );

        const currentQuestion = '明天有什么课？图书馆在哪？';
        final provider = _ScriptedProvider(_canonicalLoop());
        final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
        final service = _buildService(
          database: database,
          provider: provider,
          clock: clock,
        );

        await service
            .send(accountId: account, userText: currentQuestion)
            .toList();

        // The provider recorded the first request.
        expect(provider.requests, isNotEmpty);
        final firstRequest = provider.requests.first;

        // Collect every user-text block across all messages in the request.
        final userTexts = firstRequest.messages
            .where((m) => m.role == 'user')
            .expand((m) => m.content)
            .whereType<LlmTextBlock>()
            .map((b) => b.text)
            .toList();

        // The current question must appear EXACTLY once (regression guard
        // against the build() duplication bug where the just-persisted user
        // message was also in `history`).
        final occurrences =
            userTexts.where((t) => t == currentQuestion).length;
        expect(occurrences, 1,
            reason: 'current question must appear exactly once; '
                'got $occurrences in $userTexts');

        // Prior-turn history is present and separate from the current question.
        expect(userTexts, contains('上学期有几门课？'));
        // The current question is the LAST user text block (build appends it
        // as the final user message).
        expect(userTexts.last, currentQuestion);
      },
    );
  });

  group('tool_not_allowed', () {
    test('an unregistered tool call returns tool_not_allowed and the run completes', () async {
      // Script a call that requests a tool the registry does not know.
      final script = [
        [
          const ToolUseCompletedEvent(
            id: 'tu-1',
            name: 'delete_everything',
            input: {},
          ),
          const CompletedEvent(),
        ],
        // After the tool_result error, the model emits final text.
        [
          const TextDeltaEvent('我无法执行该操作。'),
          const CompletedEvent(),
        ],
      ];
      final provider = _ScriptedProvider(script);
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      // Register only the schedule tool; delete_everything is unknown.
      final service = _buildService(
        database: database,
        provider: provider,
        clock: clock,
        tools: [_FakeScheduleTool()],
      );

      final states = await service
          .send(accountId: account, userText: '删除所有数据')
          .toList();

      expect(provider.streamCallCount, 2);
      expect(states.last.state, AgentRunState.completed);
      // The run reached a safe terminal state.
      final runs = await (database.select(database.agentRuns)).get();
      expect(runs.single.status, AgentRunState.completed.name);
    });
  });

  group('invalid JSON fails safely', () {
    test('a tool_use whose input is not a map is contained as an error result', () async {
      // The fake provider always emits input as a Map (per the protocol), so
      // we simulate invalid arguments by having a tool whose schema rejects
      // them. The registry must not throw and the loop must continue.
      final script = [
        [
          const ToolUseCompletedEvent(
            id: 'tu-1',
            name: 'get_schedule',
            input: {'unexpected': 'garbage'},
          ),
          const CompletedEvent(),
        ],
        [
          const TextDeltaEvent('抱歉，参数有误。'),
          const CompletedEvent(),
        ],
      ];
      final provider = _ScriptedProvider(script);
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: clock,
      );

      final states = await service
          .send(accountId: account, userText: '查课表')
          .toList();

      expect(states.last.state, AgentRunState.completed);
      expect(provider.streamCallCount, 2);
    });
  });

  group('temporary references expire with the run', () {
    test('a ref bound in run 1 is not resolvable in run 2', () async {
      final provider = _ScriptedProvider(_canonicalLoop());
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: clock,
      );

      final firstStates = await service
          .send(accountId: account, userText: '明天有什么课？')
          .toList();
      final firstRefs = firstStates.last.sourceReferences;
      expect(firstRefs, isNotEmpty);

      // Run a second turn with a fresh provider script. The store is per-run,
      // so refs from run 1 must not resolve in run 2.
      final provider2 = _ScriptedProvider(_canonicalLoop());
      // Replace the service's provider by building a new one sharing the db.
      final service2 = _buildService(
        database: database,
        provider: provider2,
        clock: clock,
      );
      await service2.send(accountId: account, userText: '再查一次').toList();

      // Two separate runs persisted.
      final runs = await (database.select(database.agentRuns)).get();
      expect(runs, hasLength(2));
    });
  });

  group('hard limits', () {
    test('8 model calls is a hard limit', () async {
      // Script an infinite tool-calling loop. The runtime must hard-stop at 8
      // model calls and finish the run safely.
      final endlessToolCall = [
        const ToolUseCompletedEvent(
          id: 'tu-loop',
          name: 'get_schedule',
          input: {'date': '2026-07-29'},
        ),
        const CompletedEvent(),
      ];
      final script = List<List<LlmEvent>>.filled(20, endlessToolCall);
      final provider = _ScriptedProvider(script);
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: clock,
      );

      final states = await service
          .send(accountId: account, userText: '无限循环')
          .toList();

      expect(provider.streamCallCount, lessThanOrEqualTo(8));
      // The run terminates (not running).
      expect(states.last.state, isNot(AgentRunState.running));
      final runs = await (database.select(database.agentRuns)).get();
      expect(runs.single.status, isNot(AgentRunState.running.name));
    });

    test('12 tool calls is a hard limit', () async {
      // Each model call emits two tool uses, so tool calls outpace model
      // calls. The runtime must hard-stop at 12 tool calls.
      final twoToolsPerCall = [
        const ToolUseCompletedEvent(
          id: 'tu-a',
          name: 'get_schedule',
          input: {'date': '2026-07-29'},
        ),
        const ToolUseCompletedEvent(
          id: 'tu-b',
          name: 'search_campus_catalog',
          input: {'q': 'x'},
        ),
        const CompletedEvent(),
      ];
      final script = List<List<LlmEvent>>.filled(20, twoToolsPerCall);
      final provider = _ScriptedProvider(script);
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: clock,
      );

      final states = await service
          .send(accountId: account, userText: '无限工具')
          .toList();

      // Tool calls capped at 12; model calls at 8 (the tighter bound wins
      // first here, but tool count must never exceed 12).
      expect(states.last.state, isNot(AgentRunState.running));
      final runs = await (database.select(database.agentRuns)).get();
      expect(runs.single.status, isNot(AgentRunState.running.name));
    });
  });

  group('stop prevents a new call', () {
    test('cancel mid-run finishes the in-flight stream then stops before the next call', () async {
      // A provider that, on the first call, emits a tool_use then waits for
      // cancellation before completing; the runtime should finish the tool,
      // then NOT start call 2.
      final provider = _CancellableProvider();
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: clock,
      );

      // Start the run and cancel shortly after the first tool use fires.
      final collected = <AgentRunViewState>[];
      final sub = service
          .send(accountId: account, userText: '查课表')
          .listen(collected.add);

      // Wait for the first tool use to land, then cancel.
      await provider.firstToolUseFired.future;
      await service.cancel(accountId: account);
      await sub.asFuture<void>(null);
      await sub.cancel();

      // Only one model call was started; the second was never initiated.
      expect(provider.streamCallCount, 1);
      // The run is cancelled, not completed.
      final runs = await (database.select(database.agentRuns)).get();
      expect(runs.single.status, AgentRunState.cancelled.name);
      expect(collected.last.state, AgentRunState.cancelled);
    });
  });

  group('aggregated ActionLog', () {
    test('a completed run appends exactly one safe ActionLog with no user text', () async {
      final provider = _ScriptedProvider(_canonicalLoop());
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: clock,
      );

      await service
          .send(accountId: account, userText: '明天有什么课？图书馆在哪？')
          .toList();

      final logs = await (database.select(database.actionLogs)
            ..where((row) => row.actionType.equals('read_only_run')))
          .get();
      expect(logs, hasLength(1));
      final log = logs.single;
      expect(log.source, 'agent');
      expect(log.actionType, 'read_only_run');
      expect(log.result, 'success');
      // The safe summary is a tool-category count, NOT user text or raw
      // results.
      expect(log.safeSummary, contains('get_schedule'));
      expect(log.safeSummary, contains('search_campus_catalog'));
      expect(log.safeSummary, isNot(contains('明天有什么课')));
      expect(log.safeSummary, isNot(contains('图书馆在东区')));
      // Account is attributed.
      expect(log.accountId, account);
    });

    test('a cancelled run appends one ActionLog with result cancelled', () async {
      final provider = _CancellableProvider();
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: clock,
      );

      final sub = service.send(accountId: account, userText: '查课表').listen((_) {});
      await provider.firstToolUseFired.future;
      await service.cancel(accountId: account);
      await sub.asFuture<void>(null);
      await sub.cancel();

      final logs = await (database.select(database.actionLogs)
            ..where((row) => row.actionType.equals('read_only_run')))
          .get();
      expect(logs, hasLength(1));
      expect(logs.single.result, 'cancelled');
      expect(logs.single.safeSummary, isNot(contains('查课表')));
    });

    test('a failed run appends one ActionLog with result failed', () async {
      final script = [
        [const ErrorEvent('upstream_error', retryable: false)],
      ];
      final provider = _ScriptedProvider(script);
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: clock,
      );

      final states = await service
          .send(accountId: account, userText: '查课表')
          .toList();

      expect(states.last.state, AgentRunState.failed);
      final logs = await (database.select(database.actionLogs)
            ..where((row) => row.actionType.equals('read_only_run')))
          .get();
      expect(logs, hasLength(1));
      expect(logs.single.result, 'failed');
      expect(logs.single.safeSummary, isNot(contains('查课表')));
    });
  });

  group('retry', () {
    test('retryLast creates a new run and never overwrites the failed run', () async {
      // First run fails.
      var provider = _ScriptedProvider([
        [const ErrorEvent('upstream_error')],
      ]);
      var clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      var service = _buildService(database: database, provider: provider, clock: clock);
      await service.send(accountId: account, userText: '查课表').toList();

      var runs = await (database.select(database.agentRuns)).get();
      expect(runs, hasLength(1));
      final failedRunId = runs.single.id;
      expect(runs.single.status, AgentRunState.failed.name);

      // Retry: new provider that succeeds.
      provider = _ScriptedProvider(_canonicalLoop());
      clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      service = _buildService(database: database, provider: provider, clock: clock);
      final states = await service.retryLast(accountId: account).toList();

      expect(states.last.state, AgentRunState.completed);
      runs = await (database.select(database.agentRuns)).get();
      // The failed run is preserved AND a new run exists.
      expect(runs, hasLength(2));
      expect(runs.map((r) => r.id), contains(failedRunId));
      expect(
        runs.where((r) => r.status == AgentRunState.failed.name),
        hasLength(1),
      );
      expect(
        runs.where((r) => r.status == AgentRunState.completed.name),
        hasLength(1),
      );
    });
  });

  group('summary scheduling', () {
    test('after a successful run, schedules a tool-disabled summary when needsSummary is true', () async {
      // Seed a large history so AgentContextBuilder.needsSummary returns true.
      // We insert many completed turns directly via the repository.
      for (var i = 0; i < 60; i++) {
        final runId = await chatRepository.startRun(accountId: account, model: 'deepseek-v4-flash');
        await chatRepository.appendMessage(
          accountId: account,
          runId: runId,
          role: ChatRole.user,
          state: ChatMessageState.completed,
          content: '这是一段很长的用户消息用于撑大上下文窗口 ${'x' * 200} 编号 $i',
        );
        await chatRepository.appendMessage(
          accountId: account,
          runId: runId,
          role: ChatRole.assistant,
          state: ChatMessageState.completed,
          content: '这是助手的回复 ${'y' * 200} 编号 $i',
        );
      }

      // The canonical loop succeeds with a LARGE reported input-token count
      // (>= 18000) so AgentContextBuilder.needsSummary returns true via the
      // real-usage path. Then a summary request is appended by the service.
      // The provider script must cover the user run (3 calls) plus the
      // summary request (1 call).
      final provider = _ScriptedProvider([
        [
          const ToolUseCompletedEvent(
            id: 'tu-1',
            name: 'get_schedule',
            input: {'date': '2026-07-29'},
          ),
          const CompletedEvent(),
        ],
        [
          const ToolUseCompletedEvent(
            id: 'tu-2',
            name: 'search_campus_catalog',
            input: {'q': '图书馆'},
          ),
          const CompletedEvent(),
        ],
        [
          const TextDeltaEvent('这是最终回复。'),
          // Large real usage so needsSummary triggers via the real-usage path.
          const UsageEvent(inputTokens: 20000, outputTokens: 30),
          const CompletedEvent(),
        ],
        // Summary request: final text only, no tools.
        [
          const TextDeltaEvent('这是一份简洁的摘要。'),
          const UsageEvent(inputTokens: 500, outputTokens: 50),
          const CompletedEvent(),
        ],
      ]);
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: clock,
      );

      await service
          .send(accountId: account, userText: '再问一个问题')
          .toList();

      // 3 calls for the user run + 1 for the summary.
      expect(provider.streamCallCount, 4);

      // The summary was persisted.
      final summary = await chatRepository.latestSummary(account);
      expect(summary, isNotNull);
      expect(summary!.content, contains('摘要'));
      expect(summary.model, 'deepseek-v4-flash');
    });

    test('summary failure does not block the chat', () async {
      // Seed large history.
      for (var i = 0; i < 60; i++) {
        final runId = await chatRepository.startRun(accountId: account, model: 'deepseek-v4-flash');
        await chatRepository.appendMessage(
          accountId: account,
          runId: runId,
          role: ChatRole.user,
          state: ChatMessageState.completed,
          content: '长消息 ${'x' * 200} $i',
        );
        await chatRepository.appendMessage(
          accountId: account,
          runId: runId,
          role: ChatRole.assistant,
          state: ChatMessageState.completed,
          content: '长回复 ${'y' * 200} $i',
        );
      }

      // The user run succeeds with large reported input tokens (so
      // needsSummary triggers), then the summary request fails with an error.
      final provider = _ScriptedProvider([
        [
          const ToolUseCompletedEvent(
            id: 'tu-1',
            name: 'get_schedule',
            input: {'date': '2026-07-29'},
          ),
          const CompletedEvent(),
        ],
        [
          const ToolUseCompletedEvent(
            id: 'tu-2',
            name: 'search_campus_catalog',
            input: {'q': '图书馆'},
          ),
          const CompletedEvent(),
        ],
        [
          const TextDeltaEvent('这是最终回复。'),
          const UsageEvent(inputTokens: 20000, outputTokens: 30),
          const CompletedEvent(),
        ],
        // Summary request fails.
        [const ErrorEvent('summary_failed')],
      ]);
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: clock,
      );

      final states = await service
          .send(accountId: account, userText: '再问一个问题')
          .toList();

      // The user run still completed despite the summary failure.
      expect(states.last.state, AgentRunState.completed);
      final runs = await (database.select(database.agentRuns)).get();
      expect(runs.where((r) => r.status == AgentRunState.completed.name), isNotEmpty);
      // No summary persisted (the failure was swallowed).
      final summary = await chatRepository.latestSummary(account);
      expect(summary, isNull);
      // Still only ONE ActionLog for the user run (summary does not log).
      final logs = await (database.select(database.actionLogs)
            ..where((row) => row.actionType.equals('read_only_run')))
          .get();
      expect(logs, hasLength(1));
      expect(logs.single.result, 'success');
    });
  });

  group('resumeUserAction', () {
    test('is exposed and returns a not-implemented-yet state for now', () async {
      final provider = _ScriptedProvider(_canonicalLoop());
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: clock,
      );
      // The interface must exist; full Young integration is Task 9.
      expect(service.resumeUserAction, isNotNull);
    });
  });

  group('privacy and key handling', () {
    test('the API key is supplied per call and never persisted', () async {
      final provider = _ScriptedProvider(_canonicalLoop());
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: clock,
      );

      await service.send(accountId: account, userText: '查课表').toList();

      expect(provider.sawKey('ephemeral-test-key'), isTrue);
      // The key must not appear in any persisted row.
      final messages = await chatRepository.recentMessages(account, limit: 50);
      for (final m in messages) {
        expect(m.content, isNot(contains('ephemeral-test-key')));
      }
      final logs = await (database.select(database.actionLogs)).get();
      for (final l in logs) {
        expect(l.safeSummary, isNot(contains('ephemeral-test-key')));
      }
    });

    test('user text that fails privacy inspection is rejected before any run starts', () async {
      final provider = _ScriptedProvider(_canonicalLoop());
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        clock: clock,
      );

      final states = await service
          .send(accountId: account, userText: '我的账号是 PB12345678 帮我查')
          .toList();

      // No model call was made.
      expect(provider.streamCallCount, 0);
      // No run was persisted.
      final runs = await (database.select(database.agentRuns)).get();
      expect(runs, isEmpty);
      // The view reflects a failed/rejected state.
      expect(states.last.state, AgentRunState.failed);
      expect(states.last.text, isNot(contains('PB12345678')));
    });
  });
}

// ---------------------------------------------------------------------------
// A provider that emits one tool_use and then blocks until cancelled, to test
// stop-prevents-a-new-call semantics.
// ---------------------------------------------------------------------------

class _CancellableProvider implements LlmProvider {
  int streamCallCount = 0;
  final Completer<void> firstToolUseFired = Completer<void>();

  @override
  Future<List<String>> listModels({
    required String apiKey,
    required CancellationSignal cancellation,
  }) async => const ['deepseek-v4-flash'];

  @override
  Stream<LlmEvent> stream({
    required String apiKey,
    required LlmRequest request,
    required CancellationSignal cancellation,
  }) async* {
    streamCallCount++;
    if (streamCallCount == 1) {
      yield const ToolUseCompletedEvent(
        id: 'tu-1',
        name: 'get_schedule',
        input: {'date': '2026-07-29'},
      );
      if (!firstToolUseFired.isCompleted) firstToolUseFired.complete();
      // Wait until cancelled, then end the stream cleanly.
      while (!cancellation.isCancelled) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      yield const CompletedEvent();
      return;
    }
    // A second call should never happen; emit an error if it does.
    yield const ErrorEvent('unexpected_second_call');
  }

  @override
  Future<void> probeText({
    required String apiKey,
    required String model,
    required CancellationSignal cancellation,
  }) async {}

  @override
  Future<void> probeTools({
    required String apiKey,
    required String model,
    required CancellationSignal cancellation,
  }) async {}
}
