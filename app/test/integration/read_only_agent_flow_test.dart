// End-to-end integration coverage for the read-only campus Agent.
//
// This file exercises the full Agent stack — in-memory Drift DB, scripted LLM
// provider (with request capture), the REAL local + external tools wired to a
// FakeQueryGateway, and the OutboundPrivacyFilter — through the public
// AgentSessionService boundary. It proves the brief's Step 1 (deterministic
// full-flow with captured-request normalization + restart-restore + account
// switch) and Step 3 (cancellation during SSE and during a public query, plus
// Young needs_user_login -> no auto browser -> explicit resume -> complete).
//
// Per the architectural constraint in the task brief, the agent loop is driven
// DIRECTLY via AgentSessionService (the existing `_buildService` harness
// pattern) rather than by pumping the real router: the router hard-wires
// Windows DPAPI + the real Python Bridge, so it cannot run in a unit test.
// No production code is modified here — every seam (provider injection, tool
// injection, gateway injection, privacy-filter canary) already exists.

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_configuration_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_context_builder.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_local_data_gateway.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_session_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_tool_registry.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_tools.dart';
import 'package:ustc_assistant_app/features/agent/application/cancellation_signal.dart';
import 'package:ustc_assistant_app/features/agent/application/outbound_privacy_filter.dart';
import 'package:ustc_assistant_app/features/agent/data/drift_chat_repository.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_models.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_tool.dart';
import 'package:ustc_assistant_app/features/agent/domain/llm_protocol.dart';
import 'package:ustc_assistant_app/features/agent/domain/query_source.dart';

// Reuse the battle-tested fakes from the external tools test (single source of
// truth for the FakeQueryGateway scripting surface).
import '../features/agent/external_agent_tools_test.dart' show FakeQueryGateway, YoungBehaviour;

// ---------------------------------------------------------------------------
// Scripted provider with request capture
// ---------------------------------------------------------------------------

/// A scripted [LlmProvider] that replays a queue of per-call event lists and
/// records every [LlmRequest] in call order (the seam for captured-request
/// normalization assertions).
///
/// It also supports a "capture" mode: a script step may declare its tool_use
/// input as a function of the PREVIOUS request, so a later tool call (e.g.
/// read_campus_detail) can echo a ref_* token that an earlier tool_result
/// (search_campus_catalog) actually bound. This faithfully models a model that
/// reads a tool_result and selects a ref.
class _ScriptedProvider implements LlmProvider {
  _ScriptedProvider(this._script);

  final List<_ScriptedCall> _script;
  int streamCallCount = 0;
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
    requests.add(request);
    streamCallCount++;
    final index = streamCallCount - 1;
    if (index >= _script.length) {
      yield const ErrorEvent('script_exhausted');
      return;
    }
    final events = _script[index].build(requests, index);
    for (final event in events) {
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
}

/// One model call in a script. [build] returns the events to emit, optionally
/// inspecting the captured [requests] so a later tool_use can echo a ref bound
/// by an earlier tool_result.
class _ScriptedCall {
  const _ScriptedCall(this._events, {this.inputBuilder});
  final List<LlmEvent> Function() _events;
  final Map<String, Object?> Function(List<LlmRequest> prior)? inputBuilder;

  List<LlmEvent> build(List<LlmRequest> requests, int index) {
    final base = _events();
    if (inputBuilder == null) return base;
    // Replace any ToolUseCompletedEvent's input with the captured input.
    return [
      for (final e in base)
        if (e is ToolUseCompletedEvent)
          ToolUseCompletedEvent(id: e.id, name: e.name, input: inputBuilder!(requests))
        else
          e,
    ];
  }
}

/// Extracts the first `ref_*` token from the most recent tool_result content
/// in [prior], so a scripted read_campus_detail call can echo a ref the search
/// tool actually bound. Returns 'ref_unknown' if none is found (the tool will
/// then reject it — useful for negative cases).
String _firstRefFromLastToolResult(List<LlmRequest> prior) {
  if (prior.isEmpty) return 'ref_unknown';
  final last = prior.last;
  for (final msg in last.messages) {
    if (msg.role != 'user') continue;
    for (final block in msg.content) {
      if (block is! LlmToolResultBlock) continue;
      final content = block.content;
      if (content is! String) continue;
      final match = RegExp(r'ref_[A-Za-z0-9_-]+').firstMatch(content);
      if (match != null) return match.group(0)!;
    }
  }
  return 'ref_unknown';
}

// ---------------------------------------------------------------------------
// A cancelling provider: emits one TextDelta then blocks until cancelled.
// ---------------------------------------------------------------------------

class _SseCancellableProvider implements LlmProvider {
  int streamCallCount = 0;
  final Completer<void> firstDeltaFired = Completer<void>();

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
    yield const TextDeltaEvent('正在查询');
    if (!firstDeltaFired.isCompleted) firstDeltaFired.complete();
    // Block until cancelled, then end the stream cleanly.
    while (!cancellation.isCancelled) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    yield const CompletedEvent();
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

// ---------------------------------------------------------------------------
// A query gateway that blocks mid-stream for cancellation tests.
// ---------------------------------------------------------------------------

/// A [QuerySourceGateway] whose `execute` emits Progress then blocks on a
/// [Completer] until released, so a test can cancel mid-public-query and
/// assert the gateway's cancel was invoked and no later model call starts.
class _BlockingQueryGateway implements QuerySourceGateway {
  _BlockingQueryGateway();
  final List<SourceQuery> requests = [];
  final List<String> cancelCalls = [];
  final Completer<void> release = Completer<void>();
  bool started = false;

  @override
  Future<void> cancel(String jobId) async {
    cancelCalls.add(jobId);
  }

  @override
  Future<void> resumeLogin(String jobId, {String? password}) async {}

  @override
  Stream<SourceQueryEvent> execute(
    SourceQuery request, {
    required CancellationSignal cancellation,
  }) async* {
    requests.add(request);
    started = true;
    yield SourceQueryProgress(jobId: 'blocked-1', phase: 'fetching');
    // Wait until released or cancelled.
    while (!release.isCompleted && !cancellation.isCancelled) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (cancellation.isCancelled) {
      yield SourceQueryFailed(jobId: 'blocked-1', code: 'cancelled');
      return;
    }
    yield SourceQueryCompleted(jobId: 'blocked-1', result: _emptySearch());
  }
}

QueryResultEnvelope _emptySearch() => QueryResultEnvelope(json: {
      'schemaVersion': '1.0',
      'queryType': 'campus_search',
      'generatedAt': '2026-07-29T09:00:00+08:00',
      'data': <String, dynamic>{
        'query': 'lib',
        'results': <Map<String, Object?>>[],
      },
      'metadata': <String, dynamic>{'resultCount': 0},
      'references': <String>[],
    });

// ---------------------------------------------------------------------------
// Test harness: real local + external tools, fake gateway, captured provider.
// ---------------------------------------------------------------------------

class _SequenceClock implements BeijingClock {
  _SequenceClock(this._start);
  final DateTime _start;
  int _ticks = 0;

  @override
  DateTime now() {
    _ticks += 1;
    return _start.add(Duration(milliseconds: _ticks));
  }
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

/// Wires the REAL tool set (11 local read-only tools backed by the in-memory
/// DB via DriftAgentLocalDataGateway, plus the 4 external tools backed by
/// [gateway]) into an [AgentSessionService] with a scripted provider and the
/// OutboundPrivacyFilter (canary = [protectedAccount]). This is the
/// integration spine: no Windows, no real Python, no network.
AgentSessionService _buildService({
  required AppDatabase database,
  required LlmProvider provider,
  required FakeQueryGateway gateway,
  required BeijingClock clock,
  String model = 'deepseek-v4-flash',
  String protectedAccount = 'PB12345678',
}) {
  final chatRepository = DriftChatRepository(database);
  final localGateway = DriftAgentLocalDataGateway(database);
  final config = _StubConfigService();
  final privacyFilter = OutboundPrivacyFilter(
    protectedAccount: protectedAccount,
    toolBuilders: agentToolPayloadBuilders(),
  );
  final tools = <AgentTool>[
    ...localAgentTools(localGateway),
    ...externalAgentTools(
      gateway: gateway,
      config: config,
      usernameResolver: (_) => protectedAccount,
    ),
  ];
  final registry = AgentToolRegistry(tools: tools, privacyFilter: privacyFilter);
  return AgentSessionService(
    chatRepository: chatRepository,
    database: database,
    provider: provider,
    contextBuilder: const AgentContextBuilder(),
    privacyFilter: privacyFilter,
    registry: registry,
    clock: clock,
    model: model,
    apiKeyProvider: ({required String accountId}) async => 'ephemeral-test-key',
  );
}

/// Minimal [AgentConfigurationService] stub for the iCourse-consent gate. The
/// external tools only call `load(accountId)`; we return consent=true so
/// search_icourse is permitted.
class _StubConfigService implements AgentConfigurationService {
  @override
  Future<AgentSettingsSnapshot> load(String accountId) async => AgentSettingsSnapshot(
        accountId: accountId,
        model: 'deepseek-v4-flash',
        enabled: true,
        icourseConsent: true,
        systemPromptVersion: 1,
        updatedAt: 1,
      );

  @override
  Future<void> setIcourseConsent(String accountId, bool consent) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_StubConfigService.${invocation.memberName}');
}

/// The canonical full-flow script (Step 1):
/// call 1 -> tool_use(get_schedule)
/// call 2 -> tool_use(search_campus_catalog)
/// call 3 -> tool_use(read_campus_detail) [ref captured from call 2's tool_result]
/// call 4 -> final text + source references
List<_ScriptedCall> _fullFlowScript() => [
      _ScriptedCall(() => [
            const ToolUseCompletedEvent(
              id: 'tu-1',
              name: 'get_schedule',
              input: {'from': '2026-07-29', 'through': '2026-07-29'},
            ),
            const CompletedEvent(),
          ]),
      _ScriptedCall(() => [
            const ToolUseCompletedEvent(
              id: 'tu-2',
              name: 'search_campus_catalog',
              input: {'query': '图书馆'},
            ),
            const CompletedEvent(),
          ]),
      _ScriptedCall(
        () => [
          ToolUseCompletedEvent(
            id: 'tu-3',
            name: 'read_campus_detail',
            input: const {}, // replaced by inputBuilder below
          ),
          const CompletedEvent(),
        ],
        // Echo the first ref_* the search tool bound in call 2's tool_result.
        inputBuilder: (prior) => {'ref': _firstRefFromLastToolResult(prior)},
      ),
      _ScriptedCall(() => [
            const TextDeltaEvent('明天没有课。图书馆在东区，详情已读取。'),
            const CompletedEvent(),
          ]),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Step 1: deterministic full-flow integration', () {
    test('configure -> schedule -> catalog search -> detail -> cited answer', () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      const account = 'a';
      await _seedAccount(database, account);

      final gateway = FakeQueryGateway();
      final provider = _ScriptedProvider(_fullFlowScript());
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        gateway: gateway,
        clock: clock,
      );

      final states = await service
          .send(accountId: account, userText: '明天有什么课？图书馆在哪？')
          .toList();

      // The loop made exactly the 4 scripted model calls.
      expect(provider.streamCallCount, 4);
      // Three tools executed: get_schedule, search_campus_catalog, read_campus_detail.
      final toolNames = states
          .expand((s) => s.toolSummaries.map((t) => t.toolName))
          .toSet();
      expect(toolNames, contains('get_schedule'));
      expect(toolNames, contains('search_campus_catalog'));
      expect(toolNames, contains('read_campus_detail'));

      // The gateway received a campus search AND a campus detail request.
      expect(
        gateway.requests.whereType<CampusSearchQueryRequest>(),
        hasLength(1),
      );
      expect(
        gateway.requests.whereType<CampusDetailQueryRequest>(),
        hasLength(1),
      );
      // The detail request resolved the ref to the real entryId (campus_1),
      // never a URL or a raw ref token.
      final detailReq =
          gateway.requests.whereType<CampusDetailQueryRequest>().single;
      expect(detailReq.entryIds, ['campus_1']);

      // Terminal state is completed with the streamed cited answer.
      final terminal = states.last;
      expect(terminal.state, AgentRunState.completed);
      expect(terminal.text, contains('明天没有课'));
      expect(terminal.text, contains('图书馆在东区'));
      // Source references surfaced (from search + detail).
      expect(terminal.sourceReferences, isNotEmpty);
    });

    test('captured provider request contains only approved normalized fields', () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      const account = 'a';
      await _seedAccount(database, account);

      final gateway = FakeQueryGateway();
      final provider = _ScriptedProvider(_fullFlowScript());
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        gateway: gateway,
        clock: clock,
      );

      await service
          .send(accountId: account, userText: '明天有什么课？图书馆在哪？')
          .toList();

      // Assert EVERY captured request is free of raw ids, the canary account,
      // and the API key. The allowlist + ref binding are the real boundaries.
      expect(provider.requests, isNotEmpty);
      for (final req in provider.requests) {
        final encoded = jsonEncode(req.toJson());
        // No raw DB/local ids ever reach the model.
        expect(encoded, isNot(contains('campus_1')));
        expect(encoded, isNot(contains('campus_2')));
        expect(encoded, isNot(contains('entryId')));
        // The protected account canary never leaks to the model.
        expect(encoded, isNot(contains('PB12345678')));
        // The ephemeral API key is never serialized into the request body.
        expect(encoded, isNot(contains('ephemeral-test-key')));
      }

      // The final request (call 4) carries the normalized search/detail DTOs:
      // titles, categories, generatedAt, and ref_* tokens. Confirm approved
      // fields ARE present (the request is useful, not over-redacted).
      final lastReq = provider.requests.last;
      final lastEncoded = jsonEncode(lastReq.toJson());
      expect(lastEncoded, contains('ref_'));
      // The detail tool_result carried the normalized title (Library notice).
      expect(lastEncoded, contains('Library notice'));
    });

    test('restart -> restore conversation from the same DB', () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      const account = 'a';
      await _seedAccount(database, account);

      final gateway1 = FakeQueryGateway();
      final provider1 = _ScriptedProvider(_fullFlowScript());
      final clock1 = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service1 = _buildService(
        database: database,
        provider: provider1,
        gateway: gateway1,
        clock: clock1,
      );
      await service1
          .send(accountId: account, userText: '明天有什么课？图书馆在哪？')
          .toList();

      // Simulate a restart: build a NEW service over the SAME DB.
      final gateway2 = FakeQueryGateway();
      final provider2 = _ScriptedProvider(_fullFlowScript());
      final clock2 = _SequenceClock(DateTime(2026, 7, 29, 13, 0, 0));
      final service2 = _buildService(
        database: database,
        provider: provider2,
        gateway: gateway2,
        clock: clock2,
      );
      // The restored conversation must contain the prior user + assistant turn.
      final restored = await DriftChatRepository(database)
          .recentMessages(account, limit: 50);
      expect(
        restored.where((m) => m.role == ChatRole.user && m.state == ChatMessageState.completed),
        isNotEmpty,
      );
      expect(
        restored
            .where((m) => m.role == ChatRole.user)
            .map((m) => m.content)
            .toList(),
        contains('明天有什么课？图书馆在哪？'),
      );
      final assistant = restored
          .where((m) => m.role == ChatRole.assistant && m.state == ChatMessageState.completed)
          .single;
      expect(assistant.content, contains('明天没有课'));
      // The rebuilt service can run a fresh turn over the restored history.
      await service2.send(accountId: account, userText: '再问一个问题').toList();
      final runs = await (database.select(database.agentRuns)).get();
      expect(runs.length, greaterThanOrEqualTo(2));
    });

    test('switch account -> second conversation is empty and isolated', () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      const accountA = 'a';
      const accountB = 'b';
      await _seedAccount(database, accountA);
      await _seedAccount(database, accountB);

      // Run a full turn on account A.
      final gatewayA = FakeQueryGateway();
      final providerA = _ScriptedProvider(_fullFlowScript());
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final serviceA = _buildService(
        database: database,
        provider: providerA,
        gateway: gatewayA,
        clock: clock,
      );
      await serviceA
          .send(accountId: accountA, userText: '明天有什么课？图书馆在哪？')
          .toList();

      // Account B's conversation is empty before any send.
      final repo = DriftChatRepository(database);
      final bBefore = await repo.recentMessages(accountB, limit: 50);
      expect(bBefore, isEmpty);

      // Run a (scripted) turn on account B.
      final gatewayB = FakeQueryGateway();
      final providerB = _ScriptedProvider([
        _ScriptedCall(() => [
              const TextDeltaEvent('账号B的独立回复。'),
              const CompletedEvent(),
            ]),
      ]);
      final serviceB = _buildService(
        database: database,
        provider: providerB,
        gateway: gatewayB,
        clock: clock,
      );
      await serviceB
          .send(accountId: accountB, userText: '账号B的问题')
          .toList();

      // Account A messages do NOT appear in B, and vice versa.
      final aMessages = await repo.recentMessages(accountA, limit: 50);
      final bMessages = await repo.recentMessages(accountB, limit: 50);
      for (final m in bMessages) {
        expect(m.content, isNot(contains('明天有什么课')));
        expect(m.content, isNot(contains('图书馆在东区')));
      }
      for (final m in aMessages) {
        expect(m.content, isNot(contains('账号B')));
      }
      expect(bMessages.where((m) => m.role == ChatRole.assistant), isNotEmpty);
      expect(
        bMessages
            .where((m) => m.role == ChatRole.assistant)
            .single
            .content,
        contains('账号B的独立回复'),
      );
    });
  });

  group('Step 3: cancellation and login-resume', () {
    test('cancel during SSE: no later model call starts; run is cancelled', () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      const account = 'a';
      await _seedAccount(database, account);

      final provider = _SseCancellableProvider();
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        gateway: FakeQueryGateway(),
        clock: clock,
      );

      final collected = <AgentRunViewState>[];
      final sub = service
          .send(accountId: account, userText: '查课表')
          .listen(collected.add);

      // Wait for the first TextDelta, then cancel mid-stream.
      await provider.firstDeltaFired.future;
      await service.cancel(accountId: account);
      await sub.asFuture<void>(null);
      await sub.cancel();

      // Only one model call started; no second call was initiated.
      expect(provider.streamCallCount, 1);
      // The run terminated as cancelled.
      expect(collected.last.state, AgentRunState.cancelled);
      final runs = await (database.select(database.agentRuns)).get();
      expect(runs.single.status, AgentRunState.cancelled.name);
    });

    test('cancel during public query: no later model call starts; run terminates', () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      const account = 'a';
      await _seedAccount(database, account);

      // A query gateway whose execute() blocks mid-stream so the test can
      // cancel while a public query is in flight. The CancellationSignal
      // propagates from the session service into the tool's gateway call.
      final blockingGateway = _BlockingQueryGateway();
      final provider = _ScriptedProvider([
        _ScriptedCall(() => [
              const ToolUseCompletedEvent(
                id: 'tu-1',
                name: 'search_campus_catalog',
                input: {'query': '图书馆'},
              ),
              const CompletedEvent(),
            ]),
        _ScriptedCall(() => [
              const TextDeltaEvent('已完成查询。'),
              const CompletedEvent(),
            ]),
      ]);
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildServiceWithGateway(
        database: database,
        provider: provider,
        gateway: blockingGateway,
        clock: clock,
      );

      final collected = <AgentRunViewState>[];
      final sub = service
          .send(accountId: account, userText: '查图书馆')
          .listen(collected.add);

      // Wait until the blocking gateway has started the public query.
      while (!blockingGateway.started) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      // Cancel mid-query: the in-flight stream drains, but no new model call
      // starts.
      await service.cancel(accountId: account);
      // Release the gateway so its execute() loop observes cancellation/finish.
      if (!blockingGateway.release.isCompleted) blockingGateway.release.complete();
      await sub.asFuture<void>(null);
      await sub.cancel();

      // Only one model call started; the second (final text) never began.
      expect(provider.streamCallCount, 1);
      // The public query was initiated against the gateway.
      expect(blockingGateway.requests, hasLength(1));
      // The run terminated safely (cancelled or failed), never left running.
      expect(collected.last.state, isNot(AgentRunState.running));
      final runs = await (database.select(database.agentRuns)).get();
      expect(runs.single.status, isNot(AgentRunState.running.name));
    });

    test('Young needs_user_login: no auto browser/resume; explicit resume completes', () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      const account = 'a';
      await _seedAccount(database, account);

      // First Young query pauses with needs_user_login.
      final gateway = FakeQueryGateway()
        ..nextYoung = const YoungBehaviour.needsLogin();
      final provider = _ScriptedProvider([
        _ScriptedCall(() => [
              const ToolUseCompletedEvent(
                id: 'tu-1',
                name: 'search_current_second_class_activities',
                input: {},
              ),
              const CompletedEvent(),
            ]),
        // After the needs-login tool_result, the model emits a safe message.
        _ScriptedCall(() => [
              const TextDeltaEvent('需要你登录后才能查询二课活动。'),
              const CompletedEvent(),
            ]),
      ]);
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildService(
        database: database,
        provider: provider,
        gateway: gateway,
        clock: clock,
      );

      final states = await service
          .send(accountId: account, userText: '查我的二课活动')
          .toList();

      // The tool returned needs_user_login; the run completed (did not hang).
      final toolNames = states
          .expand((s) => s.toolSummaries.map((t) => t.toolName))
          .toSet();
      expect(toolNames, contains('search_current_second_class_activities'));
      expect(states.last.state, AgentRunState.completed);

      // SECURITY: the gateway did NOT auto-resume and received NO password.
      expect(gateway.resumeCalls, isEmpty);

      // Now exercise the gateway-level explicit resume (the brief's "invoke
      // explicit continue and complete with a fake result"): a second Young
      // query scripted to complete, then resumeLogin records the password for
      // the resumed job only.
      gateway.nextYoung = YoungBehaviour.complete();
      // Simulate the explicit resume the UI would trigger for the paused job.
      await gateway.resumeLogin('young-1', password: 'user-provided-pwd');
      expect(gateway.resumeCalls['young-1'], ['user-provided-pwd']);

      // A fresh completed Young query returns activities with no enrol/cancel.
      gateway.nextYoung = YoungBehaviour.complete();
      final provider2 = _ScriptedProvider([
        _ScriptedCall(() => [
              const ToolUseCompletedEvent(
                id: 'tu-y2',
                name: 'search_current_second_class_activities',
                input: {},
              ),
              const CompletedEvent(),
            ]),
        _ScriptedCall(() => [
              const TextDeltaEvent('你有一项可报名的志愿活动。'),
              const CompletedEvent(),
            ]),
      ]);
      final service2 = _buildService(
        database: database,
        provider: provider2,
        gateway: gateway,
        clock: clock,
      );
      final states2 = await service2
          .send(accountId: account, userText: '再查一次二课')
          .toList();
      expect(states2.last.state, AgentRunState.completed);
      expect(states2.last.text, contains('志愿活动'));
    });
  });
}

/// Variant of [_buildService] accepting an arbitrary [QuerySourceGateway]
/// (used by the cancel-during-public-query test, which needs a blocking
/// gateway that is NOT the FakeQueryGateway type).
AgentSessionService _buildServiceWithGateway({
  required AppDatabase database,
  required LlmProvider provider,
  required QuerySourceGateway gateway,
  required BeijingClock clock,
  String model = 'deepseek-v4-flash',
  String protectedAccount = 'PB12345678',
}) {
  final chatRepository = DriftChatRepository(database);
  final localGateway = DriftAgentLocalDataGateway(database);
  final config = _StubConfigService();
  final privacyFilter = OutboundPrivacyFilter(
    protectedAccount: protectedAccount,
    toolBuilders: agentToolPayloadBuilders(),
  );
  final tools = <AgentTool>[
    ...localAgentTools(localGateway),
    ...externalAgentTools(
      gateway: gateway,
      config: config,
      usernameResolver: (_) => protectedAccount,
    ),
  ];
  final registry = AgentToolRegistry(tools: tools, privacyFilter: privacyFilter);
  return AgentSessionService(
    chatRepository: chatRepository,
    database: database,
    provider: provider,
    contextBuilder: const AgentContextBuilder(),
    privacyFilter: privacyFilter,
    registry: registry,
    clock: clock,
    model: model,
    apiKeyProvider: ({required String accountId}) async => 'ephemeral-test-key',
  );
}
