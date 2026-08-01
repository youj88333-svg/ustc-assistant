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
import 'package:ustc_assistant_app/core/security/credential_protector.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/accounts/application/account_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_composition.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_configuration_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_context_builder.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_local_data_gateway.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_session_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_tool_registry.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_tools.dart';
import 'package:ustc_assistant_app/features/agent/application/cancellation_signal.dart';
import 'package:ustc_assistant_app/features/agent/application/outbound_privacy_filter.dart';
import 'package:ustc_assistant_app/features/agent/data/drift_chat_repository.dart';
import 'package:ustc_assistant_app/features/agent/data/protected_agent_secret_store.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_models.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_tool.dart';
import 'package:ustc_assistant_app/features/agent/domain/llm_protocol.dart';
import 'package:ustc_assistant_app/features/agent/domain/query_source.dart';
import 'package:ustc_assistant_app/features/sync/data/bridge_client.dart';

// Reuse the battle-tested fakes from the external tools test (single source of
// truth for the FakeQueryGateway scripting surface).
import '../features/agent/external_agent_tools_test.dart' show FakeQueryGateway;

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
    const jobId = 'blocked-1';
    yield SourceQueryProgress(jobId: jobId, phase: 'fetching');
    // Faithfully model WindowsPythonQueryGateway.execute: it subscribes to
    // cancellation.onCancel and, when cancellation fires mid-query, calls
    // _safeCancel(jobId) (POSTing /cancel to the Bridge) before yielding
    // SourceQueryFailed and returning. This fake's cancel(jobId) records into
    // cancelCalls so the test can assert the gateway-level cancel was invoked
    // — the property the brief calls "gateway.cancelCalls recorded". Without
    // this, the fake would only observe the CancellationSignal flag but never
    // record a gateway-level cancel, diverging from the production gateway.
    final cancelled = Completer<void>();
    final cancelSub = cancellation.onCancel.listen((_) {
      if (!cancelled.isCompleted) cancelled.complete();
    });
    try {
      // Wait until released or cancelled (flag/event-based, not a wall-clock
      // race: onCancel fires synchronously when the signal is cancelled).
      while (!release.isCompleted && !cancelled.isCompleted) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      if (cancellation.isCancelled) {
        await cancel(jobId);
        yield SourceQueryFailed(jobId: jobId, code: 'cancelled');
        return;
      }
      yield SourceQueryCompleted(jobId: jobId, result: _emptySearch());
    } finally {
      await cancelSub.cancel();
    }
  }
}

/// A Young gateway that keeps one query stream open across a login pause.
class _ResumableYoungQueryGateway implements QuerySourceGateway {
  _ResumableYoungQueryGateway({
    this.rejectDuplicateCancel = false,
    this.failResume = false,
  });

  final bool rejectDuplicateCancel;
  final bool failResume;
  final List<SourceQuery> requests = [];
  final List<String> resumedJobIds = [];
  final List<String> cancelCalls = [];
  final Completer<void> paused = Completer<void>();
  bool passwordWasProvided = false;
  int effectiveCancelCount = 0;

  StreamController<SourceQueryEvent>? _controller;
  StreamSubscription<void>? _cancelSubscription;
  int startedJobs = 0;

  @override
  Stream<SourceQueryEvent> execute(
    SourceQuery request, {
    required CancellationSignal cancellation,
  }) {
    requests.add(request);
    startedJobs++;
    const jobId = 'young-1';
    final controller = StreamController<SourceQueryEvent>(sync: true);
    _controller = controller;
    Future<void>? signalCancelFuture;
    _cancelSubscription = cancellation.onCancel.listen((_) {
      // Production wakes its async polling loop before POSTing the signal-owned
      // cancel. Delay one microtask so a second direct cancel is deterministic.
      signalCancelFuture =
          Future<void>.delayed(Duration.zero).then((_) => cancel(jobId));
    });
    controller.onCancel = () async {
      await signalCancelFuture;
      await _cancelSubscription?.cancel();
      _cancelSubscription = null;
    };
    scheduleMicrotask(() {
      if (controller.isClosed) return;
      controller.add(
        const SourceQueryProgress(jobId: jobId, phase: 'starting'),
      );
      controller.add(const SourceQueryNeedsLogin(jobId: jobId));
      if (!paused.isCompleted) paused.complete();
    });
    return controller.stream;
  }

  @override
  Future<void> resumeLogin(String jobId, {String? password}) async {
    resumedJobIds.add(jobId);
    passwordWasProvided = password != null;
    if (failResume) {
      throw const BridgeProtocolError('request_failed');
    }
    final controller = _controller;
    if (controller == null || controller.isClosed) return;
    controller.add(
      SourceQueryCompleted(jobId: jobId, result: _resumedYoungEnvelope()),
    );
    await controller.close();
    await _cancelSubscription?.cancel();
    _cancelSubscription = null;
  }

  @override
  Future<void> cancel(String jobId) async {
    cancelCalls.add(jobId);
    if (rejectDuplicateCancel && cancelCalls.length > 1) {
      // Mirrors Bridge HTTP 409 -> BridgeProtocolError(invalid_job_state).
      throw const BridgeProtocolError('invalid_job_state');
    }
    effectiveCancelCount++;
    final controller = _controller;
    if (controller == null || controller.isClosed) return;
    controller.add(SourceQueryFailed(jobId: jobId, code: 'cancelled'));
    await controller.close();
    await _cancelSubscription?.cancel();
    _cancelSubscription = null;
  }
}

QueryResultEnvelope _resumedYoungEnvelope() => QueryResultEnvelope(
      json: {
        'schemaVersion': '1.0',
        'queryType': 'young_enrolment',
        'generatedAt': '2026-07-29T09:00:00+08:00',
        'data': <String, dynamic>{
          'activities': <Map<String, Object?>>[
            {
              'name': '志愿活动一',
              'category': 'service',
              'status': 'open',
            },
          ],
        },
        'metadata': <String, dynamic>{
          'activityCount': 1,
          'reportedTotal': 1,
          'pages': 1,
        },
        'references': <String>[],
      },
    );

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

class _NoopProtector implements CredentialProtector {
  @override
  Future<ProtectedSecret> protect(Uint8List plaintext) async =>
      ProtectedSecret(
        bytes: Uint8List.fromList(plaintext),
        scheme: 'test',
        version: 1,
      );

  @override
  Future<Uint8List> unprotect(ProtectedSecret protected) async =>
      Uint8List.fromList(protected.bytes);
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

/// Beijing wall clock -> the app's UTC epoch-ms storage encoding
/// (machine-timezone independent; same helper the schedule service tests use).
int _beijingEpoch(int year, int month, int day, int hour, [int minute = 0]) =>
    DateTime.utc(year, month, day, hour, minute).millisecondsSinceEpoch -
    const Duration(hours: 8).inMilliseconds;

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
    test(
      'composition recovers interrupted runs before loading history',
      () async {
        final database = AppDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        const account = 'a';
        await _seedAccount(database, account);
        final repository = DriftChatRepository(database);
        final runId = await repository.startRun(
          accountId: account,
          model: 'deepseek-v4-flash',
        );
        await repository.appendMessage(
          accountId: account,
          runId: runId,
          role: ChatRole.assistant,
          state: ChatMessageState.streaming,
          content: 'partial answer',
        );

        final composition = await AgentComposition.build(
          database: database,
          accountId: account,
          resolvedUsername: 'PB12345678',
          accounts: AccountService(
            database: database,
            protector: _NoopProtector(),
          ),
          secretStoreFactory: (database) => ProtectedAgentSecretStore(
            database: database,
            protector: _NoopProtector(),
          ),
          queryGatewayFactory: (_, _) async => FakeQueryGateway(),
        );
        addTearDown(composition.sessionService.dispose);

        final run = await (database.select(
          database.agentRuns,
        )..where((row) => row.id.equals(runId))).getSingle();
        final history = await composition.chatRepository.recentMessages(
          account,
          limit: 20,
        );

        expect(run.status, AgentRunState.interrupted.name);
        expect(history.single.state, ChatMessageState.interrupted);
        expect(history.single.content, 'partial answer');
      },
    );

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

    // Task 10 scenario 2 at the service level with the REAL local tools: the
    // pending-review question's FIRST model response is plain text (no tool),
    // so the runtime issues its ONE bounded correction — the corrective
    // request forces tool_choice any with narrowed declarations and the real
    // get_pending_event_reviews runs over the seeded ended course.
    test(
      'pending event review: first-miss -> one correction succeeds with real tools',
      () async {
        final database = AppDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        const account = 'a';
        await _seedAccount(database, account);

        // A course that ENDED two days ago with undecided attendance and
        // unknown listening mode -> pending review with real data.
        final now = DateTime.now();
        final ended = DateTime(now.year, now.month, now.day)
            .subtract(const Duration(days: 2));
        await database.into(database.calendarEvents).insert(
              CalendarEventsCompanion.insert(
                id: 'q-1',
                accountId: account,
                source: 'ustc_jw',
                externalId: const Value('q-1'),
                sourceSeriesExternalId: const Value('lesson-q'),
                title: '量子物理 B',
                type: 'course',
                startAt: Value(_beijingEpoch(ended.year, ended.month, ended.day, 9, 0)),
                endAt: Value(
                    _beijingEpoch(ended.year, ended.month, ended.day, 10, 40)),
                allDay: false,
                timezone: 'Asia/Shanghai',
                createdAt: 1,
                updatedAt: 1,
              ),
            );
        await database.into(database.sourceRecords).insert(
              SourceRecordsCompanion.insert(
                id: 'sr-q-1',
                accountId: account,
                source: 'ustc_jw',
                entityType: 'calendar_event',
                externalId: 'q-1',
                localEntityId: 'q-1',
                sourceStatus: 'active',
                presence: 'present',
                scopeKey: 'scope',
                firstObservedAt: 1,
                lastObservedAt: 1,
              ),
            );

        final provider = _ScriptedProvider([
          // Call 1: the model misses the tool and answers in plain text.
          _ScriptedCall(() => [
                const TextDeltaEvent('已列出需要确认的课程。'),
                const CompletedEvent(),
              ]),
          // Call 2 (forced tool_choice any, narrowed): the correction succeeds.
          _ScriptedCall(() => [
                const ToolUseCompletedEvent(
                  id: 'tu-1',
                  name: 'get_pending_event_reviews',
                  input: {},
                ),
                const CompletedEvent(),
              ]),
          // Call 3: grounded final answer.
          _ScriptedCall(() => [
                const TextDeltaEvent('有一节量子物理 B 需要确认出勤。'),
                const CompletedEvent(),
              ]),
        ]);
        final service = _buildService(
          database: database,
          provider: provider,
          gateway: FakeQueryGateway(),
          clock: _SequenceClock(DateTime(now.year, now.month, now.day, 12)),
        );

        final states = await service
            .send(accountId: account, userText: '有哪些需要我确认的课程出勤或听讲？')
            .toList();

        // 3 model calls: miss, one bounded correction, final.
        expect(provider.streamCallCount, 3);
        final corrective = provider.requests[1];
        expect(corrective.toolChoice, LlmToolChoice.any,
            reason: 'the corrective request must force tool_choice any');
        expect(
          corrective.tools.map((t) => t.name).toSet(),
          {'get_pending_event_reviews'},
          reason: 'the corrective request narrows declarations to the required tool',
        );
        // The REAL tool ran over the seeded ended course and grounded the
        // final answer.
        expect(states.last.state, AgentRunState.completed);
        expect(states.last.text, contains('量子物理 B'));
        final executed = states
            .expand((s) => s.toolSummaries.map((t) => t.toolName))
            .toSet();
        expect(executed, {'get_pending_event_reviews'});
      },
    );
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
      // The brief's "gateway.cancelCalls recorded" guarantee: cancellation
      // propagated to a cancellable tool AND triggered a gateway-level cancel
      // (mirroring WindowsPythonQueryGateway calling _safeCancel(jobId) on
      // cancel). The cancel was for the jobId the gateway emitted.
      expect(blockingGateway.cancelCalls, isNotEmpty);
      expect(blockingGateway.cancelCalls.last, 'blocked-1');
      // The run terminated as cancelled (not merely "not running") — matching
      // the SSE-cancel test's explicit terminal-state assertion.
      expect(collected.last.state, AgentRunState.cancelled);
      final runs = await (database.select(database.agentRuns)).get();
      expect(runs.single.status, AgentRunState.cancelled.name);
    });

    test('Young login resumes the same query job and Agent run', () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      const account = 'a';
      await _seedAccount(database, account);

      const protectedPassword = 'protected-school-password';
      final gateway = _ResumableYoungQueryGateway();
      addTearDown(() => gateway.cancel('young-1'));
      final provider = _ScriptedProvider([
        _ScriptedCall(() => [
              const ToolUseCompletedEvent(
                id: 'tu-1',
                name: 'search_current_second_class_activities',
                input: {},
              ),
              const CompletedEvent(),
            ]),
        _ScriptedCall(() => [
              const TextDeltaEvent('已查询到一项可报名的志愿活动。'),
              const CompletedEvent(),
            ]),
      ]);
      final clock = _SequenceClock(DateTime(2026, 7, 29, 12, 0, 0));
      final service = _buildServiceWithGateway(
        database: database,
        provider: provider,
        gateway: gateway,
        clock: clock,
        resumeLogin: (jobId) =>
            gateway.resumeLogin(jobId, password: protectedPassword),
      );

      final states = <AgentRunViewState>[];
      final subscription = service
          .send(accountId: account, userText: '查询报名中的二课')
          .listen(states.add);

      await gateway.paused.future;
      await Future<void>.delayed(Duration.zero);
      expect(states.last.state, AgentRunState.waitingForUser);
      final runId = states.last.runId;

      final resumeDone = service
          .resumeUserAction(accountId: account, runId: runId)
          .drain<void>();
      await resumeDone.timeout(const Duration(seconds: 5));
      await subscription.asFuture<void>().timeout(const Duration(seconds: 5));

      expect(gateway.startedJobs, 1);
      expect(gateway.resumedJobIds, ['young-1']);
      expect(gateway.passwordWasProvided, isTrue);
      expect(states.map((state) => state.runId).toSet(), {runId});
      expect(states.last.state, AgentRunState.completed);
      expect(provider.streamCallCount, 2);
      final resumedToolResults = provider.requests.last.messages
          .expand((message) => message.content)
          .whereType<LlmToolResultBlock>()
          .toList();
      expect(resumedToolResults, hasLength(1));
      expect(resumedToolResults.single.toolUseId, 'tu-1');
      expect(resumedToolResults.single.isError, isFalse);

      final capturedRequests = jsonEncode(
        provider.requests.map((request) => request.toJson()).toList(),
      );
      expect(capturedRequests, isNot(contains(protectedPassword)));
      expect(capturedRequests, isNot(contains('young-1')));
      final safeStateSnapshot = jsonEncode([
        for (final state in states)
          {
            'runId': state.runId,
            'state': state.state.name,
            'text': state.text,
            'errorCode': state.errorCode,
            'userAction': state.userAction?.type.name,
          },
      ]);
      expect(safeStateSnapshot, isNot(contains(protectedPassword)));
      expect(safeStateSnapshot, isNot(contains('young-1')));
      final messages = await DriftChatRepository(
        database,
      ).recentMessages(account, limit: 20);
      final logs = await (database.select(database.actionLogs)).get();
      final persistedSnapshot = jsonEncode({
        'messages': messages.map((message) => message.content).toList(),
        'logs': logs.map((log) => log.safeSummary).toList(),
      });
      expect(persistedSnapshot, isNot(contains(protectedPassword)));
      expect(persistedSnapshot, isNot(contains('young-1')));
    });

    test(
      'paused Young cancel sends one effective remote cancel when duplicate is 409',
      () async {
        final database = AppDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        const account = 'a';
        await _seedAccount(database, account);
        final gateway = _ResumableYoungQueryGateway(
          rejectDuplicateCancel: true,
        );
        final provider = _ScriptedProvider([
          _ScriptedCall(() => [
                const ToolUseCompletedEvent(
                  id: 'tu-1',
                  name: 'search_current_second_class_activities',
                  input: {},
                ),
                const CompletedEvent(),
              ]),
        ]);
        final service = _buildServiceWithGateway(
          database: database,
          provider: provider,
          gateway: gateway,
          clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
        );
        final states = <AgentRunViewState>[];
        final subscription = service
            .send(accountId: account, userText: 'cancel paused query')
            .listen(states.add);
        final done = subscription.asFuture<void>();
        await gateway.paused.future;
        await Future<void>.delayed(Duration.zero);

        await service.cancel(accountId: account);
        await done.timeout(const Duration(seconds: 1));

        expect(gateway.cancelCalls, ['young-1']);
        expect(gateway.effectiveCancelCount, 1);
        expect(states.last.state, AgentRunState.cancelled);
      },
    );

    test('resume callback failure closes the Young job and original run', () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      const account = 'a';
      await _seedAccount(database, account);
      final gateway = _ResumableYoungQueryGateway(
        rejectDuplicateCancel: true,
        failResume: true,
      );
      final provider = _ScriptedProvider([
        _ScriptedCall(() => [
              const ToolUseCompletedEvent(
                id: 'tu-1',
                name: 'search_current_second_class_activities',
                input: {},
              ),
              const CompletedEvent(),
            ]),
      ]);
      final service = _buildServiceWithGateway(
        database: database,
        provider: provider,
        gateway: gateway,
        clock: _SequenceClock(DateTime(2026, 7, 29, 12)),
        resumeLogin: (jobId) => gateway.resumeLogin(
          jobId,
          password: 'protected-school-password',
        ),
      );
      final states = <AgentRunViewState>[];
      final subscription = service
          .send(accountId: account, userText: 'resume paused query')
          .listen(states.add);
      final done = subscription.asFuture<void>();
      await gateway.paused.future;
      await Future<void>.delayed(Duration.zero);
      final runId = states.last.runId;

      await service
          .resumeUserAction(accountId: account, runId: runId)
          .drain<void>()
          .timeout(const Duration(seconds: 1));
      await done.timeout(const Duration(seconds: 1));

      expect(gateway.cancelCalls, ['young-1']);
      expect(gateway.effectiveCancelCount, 1);
      expect(states.last.state, AgentRunState.cancelled);
      final retry = await service
          .resumeUserAction(accountId: account, runId: runId)
          .toList();
      expect(retry.single.errorCode, 'paused_run_not_found');
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
  Future<void> Function(String jobId)? resumeLogin,
  String model = 'deepseek-v4-flash',
  String protectedAccount = 'PB12345678',
}) {
  final AgentUserActionResumeCallback? resumeCallback = resumeLogin == null
      ? null
      : ({
          required String accountId,
          required AgentUserAction action,
        }) => resumeLogin(action.opaqueHandle);
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
    userActionResumer: resumeCallback,
  );
}
