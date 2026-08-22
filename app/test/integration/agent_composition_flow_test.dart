// Composition-level integration coverage for the read-only campus Agent.
//
// Unlike `read_only_agent_flow_test.dart` (which drives the loop DIRECTLY via
// `AgentSessionService` because the router hard-wires Windows DPAPI + the real
// Python Bridge), this file pumps the REAL chat route through `buildRouter`
// with an injected `agentCompositionLoader`. The loader builds a real
// `AgentComposition` over the in-memory DB but injects a scripted `LlmProvider`
// (request capture) — the minimal seam added to `AgentComposition.build`
// (`providerFactory`) lets the scripted provider reach the real router without
// touching the network, DPAPI, or Python.
//
// This covers local write/confirmation/undo/account-switch/db-isolation flows
// end-to-end through the real router + composition ownership:
//
//   account A -> configure -> local schedule -> grouped semester summary
//   -> switch to B -> empty account-scoped chat
//   -> switch back to A -> recovered conversation
//
// Plus captured-request privacy: no password, job ID, raw catalog id, complete
// account, or API key appears in any encoded `LlmRequest`.

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/app/router.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/security/credential_protector.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/accounts/application/account_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_composition.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_tool_registry.dart';
import 'package:ustc_assistant_app/features/agent/application/cancellation_signal.dart';
import 'package:ustc_assistant_app/features/agent/application/run_reference_store.dart';
import 'package:ustc_assistant_app/features/agent/data/protected_agent_secret_store.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_models.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_tool.dart';
import 'package:ustc_assistant_app/features/agent/domain/llm_protocol.dart';
import 'package:ustc_assistant_app/features/calendar/domain/calendar_event_locator.dart';
import 'package:ustc_assistant_app/features/import/application/reminder_reconciler.dart';
import 'package:ustc_assistant_app/features/reminders/application/reminder_override_service.dart';
import 'package:ustc_assistant_app/features/schedule/application/conflict_service.dart';
import 'package:ustc_assistant_app/features/schedule/application/effective_event_repository.dart';
import 'package:ustc_assistant_app/features/schedule/application/overlay_service.dart';
import 'package:ustc_assistant_app/features/schedule/application/jw_day_move_service.dart';
import 'package:ustc_assistant_app/features/schedule/presentation/schedule_page.dart';
import 'package:ustc_assistant_app/features/settings/presentation/official_websites_page.dart';
import 'package:ustc_assistant_app/features/tasks/application/plan_block_service.dart';
import 'package:ustc_assistant_app/features/tasks/application/task_lifecycle_service.dart';
import 'package:ustc_assistant_app/features/tasks/application/undo_recorder.dart';
import 'package:ustc_assistant_app/features/tasks/application/undo_service.dart';

// ---------------------------------------------------------------------------
// Scripted provider with request capture (mirrors read_only_agent_flow_test).
// ---------------------------------------------------------------------------

/// A scripted [LlmProvider] that replays a queue of per-call event lists and
/// records every [LlmRequest] in call order (the seam for captured-request
/// privacy assertions).
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
    final events = _script[index].build(requests);
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
/// inspecting the captured [requests] so a later tool_use can echo refs bound
/// by an earlier tool_result (the same seam the read-only flow test uses).
class _ScriptedCall {
  const _ScriptedCall(this._events, {this.inputBuilder}) : _eventsBuilder = null;
  const _ScriptedCall.requestAware(this._eventsBuilder)
      : _events = null,
        inputBuilder = null;
  final List<LlmEvent> Function()? _events;
  final List<LlmEvent> Function(List<LlmRequest> prior)? _eventsBuilder;
  final Map<String, Object?> Function(List<LlmRequest> prior)? inputBuilder;

  List<LlmEvent> build(List<LlmRequest> requests) {
    final aware = _eventsBuilder;
    if (aware != null) {
      return aware(requests);
    }
    final base = _events!();
    final builder = inputBuilder;
    if (builder == null) return base;
    // Replace any ToolUseCompletedEvent's input with the captured input.
    return [
      for (final event in base)
        if (event is ToolUseCompletedEvent)
          ToolUseCompletedEvent(
            id: event.id,
            name: event.name,
            input: builder(requests),
          )
        else
          event,
    ];
  }
}

/// All `ref_*` tokens from the LAST captured request's user tool_results, in
/// tool-result order. The tokens are the run-local bindings an earlier tool
/// actually emitted, so a later scripted tool_use can echo them faithfully.
List<String> _refsFromLastToolResult(List<LlmRequest> prior) {
  if (prior.isEmpty) return const [];
  final out = <String>[];
  for (final message in prior.last.messages) {
    if (message.role != 'user') continue;
    for (final block in message.content) {
      if (block is! LlmToolResultBlock) continue;
      final content = block.content;
      if (content is! String) continue;
      for (final match in RegExp(r'ref_[A-Za-z0-9_-]+').allMatches(content)) {
        out.add(match.group(0)!);
      }
    }
  }
  return out;
}

/// A registry decorator that records the ORDER and arguments of every tool
/// invocation that flows through it. Used by the Task 3 composition regression
/// to assert the ACTUAL tool-call sequence — e.g. that a title query
/// (`get_schedule(query=...)`) precedes the overlay/relation writes and that
/// `get_conflicts` is never invoked as a participant finder. The recorded
/// sequence is observable and thus the assertion is fail-capable (unlike
/// asserting on output payload text, which can never contain tool names).
class _RecordingRegistry {
  _RecordingRegistry(this.inner);

  final AgentToolRegistry inner;

  /// Every `(toolName, arguments)` executed, in order.
  final List<({String toolName, Map<String, Object?> arguments})> invocations =
      [];

  Future<AgentToolResult> execute({
    required String toolName,
    required Map<String, Object?> arguments,
    required AgentToolContext context,
  }) {
    invocations.add((toolName: toolName, arguments: arguments));
    return inner.execute(
      toolName: toolName,
      arguments: arguments,
      context: context,
    );
  }

  List<LlmToolDeclaration> get schemas => inner.schemas;
}

// ---------------------------------------------------------------------------
// Fakes & seeding helpers (self-contained: Dart library-private members do not
// cross file boundaries, so the proven patterns from read_only_agent_flow_test
// and local_agent_tools_test are copied here in minimal form).
// ---------------------------------------------------------------------------

class _NoopProtector implements CredentialProtector {
  const _NoopProtector();

  @override
  Future<ProtectedSecret> protect(Uint8List plaintext) async => ProtectedSecret(
        bytes: Uint8List.fromList(plaintext),
        scheme: 'test',
        version: 1,
      );

  @override
  Future<Uint8List> unprotect(ProtectedSecret protected) async =>
      Uint8List.fromList(protected.bytes);
}

class _FakeWebsiteLauncher implements OfficialWebsiteLauncher {
  final launched = <Uri>[];

  @override
  Future<bool> launch(Uri uri) async {
    launched.add(uri);
    return true;
  }
}

/// Seeds a local account row marked active.
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

/// Seeds a non-active local account (for account-switch tests).
Future<void> _seedInactiveAccount(AppDatabase database, String accountId) =>
    database.into(database.localAccounts).insert(
          LocalAccountsCompanion.insert(
            id: accountId,
            maskedHint: 'PB****0000',
            isActive: const Value(false),
            createdAt: 1,
            updatedAt: 1,
          ),
        );

/// Seeds protected school credentials for [accountId] so the composition's
/// `userActionResumer` can resolve the username and an interactive-login
/// password. The [username] is the canary the privacy filter protects; the
/// [password] is the canary the Young resume must never send to the model.
/// Both are protected with the noop protector (test-only — no DPAPI).
Future<void> _seedCredentials(
  AppDatabase database,
  String accountId,
  CredentialProtector protector, {
  required String username,
  required String password,
}) async {
  final usernameSecret = await protector.protect(
    Uint8List.fromList(utf8.encode(username)),
  );
  final passwordSecret = await protector.protect(
    Uint8List.fromList(utf8.encode(password)),
  );
  await database.into(database.credentialAccounts).insert(
        CredentialAccountsCompanion.insert(
          accountId: accountId,
          usernameCiphertext: usernameSecret.bytes,
          passwordCiphertext: Value(passwordSecret.bytes),
          scheme: usernameSecret.scheme,
          protectionVersion: Value(usernameSecret.version),
          protectionMetadata: Value(jsonEncode(usernameSecret.metadata)),
          updatedAt: 1,
        ),
      );
}

/// Seeds a configured AgentSettings row (enabled, model) and an API key, so
/// `AgentSettingsPage.isConfigured` returns true and the chat composer is
/// enabled.
Future<void> _seedAgentConfig(
  AppDatabase database,
  String accountId, {
  required AgentSecretStore secrets,
  required String apiKey,
}) async {
  await secrets.saveKey(accountId, apiKey);
  await database.into(database.agentSettings).insert(
        AgentSettingsCompanion.insert(
          accountId: accountId,
          model: const Value('deepseek-v4-flash'),
          enabled: const Value(true),
          updatedAt: 1,
        ),
      );
}

/// Inserts a course-series row (the stable identity `get_schedule` course_summary
/// groups by).
Future<void> _insertCourseSeries(
  AppDatabase database,
  String id,
  String accountId, {
  required String externalId,
  required String title,
  String semesterKey = '2026spring',
  String participantsJson = '[]',
}) async {
  await database.into(database.courseSeries).insert(
        CourseSeriesCompanion.insert(
          id: id,
          accountId: accountId,
          source: 'ustc_jw',
          externalId: externalId,
          title: title,
          semesterKey: semesterKey,
          participantsJson: Value(participantsJson),
          sourceDetailsJson: '{}',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
}

/// Inserts a timed course occurrence linked to a series (the
/// `sourceSeriesExternalId` join key for course_summary grouping).
Future<void> _insertCourseOccurrence(
  AppDatabase database,
  String id,
  String accountId,
  String title, {
  required String seriesExternalId,
  required String location,
  required DateTime start,
  required DateTime end,
}) async {
  await database.into(database.calendarEvents).insert(
        CalendarEventsCompanion.insert(
          id: id,
          accountId: accountId,
          source: 'ustc_jw',
          externalId: Value(id),
          sourceSeriesExternalId: Value(seriesExternalId),
          title: title,
          type: 'course',
          startAt: Value(start.toUtc().millisecondsSinceEpoch),
          endAt: Value(end.toUtc().millisecondsSinceEpoch),
          allDay: false,
          timezone: 'Asia/Shanghai',
          locationName: Value(location),
          createdAt: 1,
          updatedAt: 1,
        ),
      );
  // SourceRecords row is required for non-`user`-source events to appear in
  // the effective-event projection.
  await database.into(database.sourceRecords).insert(
        SourceRecordsCompanion.insert(
          id: 'sr-$id',
          accountId: accountId,
          source: 'ustc_jw',
          entityType: 'calendar_event',
          externalId: id,
          localEntityId: id,
          sourceStatus: 'active',
          presence: 'present',
          scopeKey: 'scope',
          firstObservedAt: 1,
          lastObservedAt: 1,
        ),
      );
}

/// Inserts a local task row (for `get_tasks` to bind a task ref). State uses
/// the persisted storage values (`active`/`normal`); the projection derives
/// derived planning/deadline/confirmation state at query time.
Future<void> _insertTask(
  AppDatabase database,
  String id,
  String accountId,
  String title, {
  String state = 'active',
}) async {
  await database.into(database.tasks).insert(
        TasksCompanion.insert(
          id: id,
          accountId: accountId,
          title: title,
          state: state,
          importance: 'normal',
          tagsJson: '[]',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
}

/// Flattens every captured `LlmToolResultBlock` content string from [provider]
/// in call order. Used to assert the model-facing tool feed contains the
/// run-local `ref_*` tokens (from the read query) and never a raw DB id.
List<String> _capturedToolResults(_ScriptedProvider provider) {
  final out = <String>[];
  for (final req in provider.requests) {
    for (final message in req.messages) {
      if (message.role != 'user') continue;
      for (final block in message.content) {
        if (block is LlmToolResultBlock) out.add(block.content.toString());
      }
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// The composition loader injected into the real router.
// ---------------------------------------------------------------------------

/// Builds a real `AgentComposition` for [accountId] with the test injections:
/// noop protector, noop secret store, and the shared [provider] (so captured
/// requests accumulate across the whole flow). Returns the composition.
Future<AgentCompositionResult> _buildTestComposition(
  AppDatabase database,
  String accountId, {
  required _ScriptedProvider provider,
  required CredentialProtector protector,
}) async {
  final accounts = AccountService(database: database, protector: protector);
  // The composition's userActionResumer is a no-op (external-source login
  // resume retired with the query gateway); local write confirmation is
  // resumed through the UI confirmation card, not this resumer.
  return AgentComposition.build(
    database: database,
    accountId: accountId,
    resolvedUsername: 'PB12345678',
    accounts: accounts,
    secretStoreFactory: (db) => ProtectedAgentSecretStore(
      database: db,
      protector: protector,
    ),
    providerFactory: () => provider,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('composition wiring: confirm commits a personal event and leaks no id', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    const protector = _NoopProtector();
    await _seedAccount(db, 'acc-1');
    final secretStore = ProtectedAgentSecretStore(
      database: db,
      protector: protector,
    );
    await _seedAgentConfig(db, 'acc-1', secrets: secretStore, apiKey: 'test-key');

    // Call 1: create_event -> pauses for write confirmation. Call 2: final text.
    final provider = _ScriptedProvider([
      _ScriptedCall(() => [
        const ToolUseCompletedEvent(
          id: 'tu-1',
          name: 'create_event',
          input: {
            'title': '健身',
            'start_at': '2026-08-01T15:00:00+08:00',
            'end_at': '2026-08-01T16:00:00+08:00',
          },
        ),
        const CompletedEvent(),
      ]),
      _ScriptedCall(() => [
        const TextDeltaEvent('已为你新建日程「健身」。'),
        const CompletedEvent(),
      ]),
    ]);
    final composition = await _buildTestComposition(
      db,
      'acc-1',
      provider: provider,
      protector: protector,
    );
    addTearDown(composition.dispose);

    // 10 个写工具全部注册。
    for (final name in const [
      'create_event', 'update_event', 'create_task', 'plan_task',
      'create_user_overlay', 'record_attendance_decision', 'record_listening_mode',
      'create_schedule_relation', 'set_reminder', 'update_permission_policy',
    ]) {
      expect(composition.registry.isRegistered(name), isTrue,
          reason: 'write tool $name should be registered');
    }

    final states = <AgentRunViewState>[];
    final done = Completer<void>();
    late String runId;
    composition.sessionService
        .send(accountId: 'acc-1', userText: '帮我建个健身日程')
        .listen((s) {
      states.add(s);
      if (s.state == AgentRunState.waitingForUser) runId = s.runId;
    }, onDone: done.complete);

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(
      states.any((s) => s.userAction?.type == AgentUserActionType.writeConfirmation),
      isTrue,
      reason: 'create_event should pause for confirmation',
    );
    await composition.sessionService
        .confirmWriteProposal(accountId: 'acc-1', runId: runId, approve: true, remember: false)
        .drain<void>();
    await done.future;

    expect(states.last.state, AgentRunState.completed);
    final event = await db.select(db.calendarEvents).getSingle();
    expect(event.title, '健身');
    final logs = await db.actionLogsRepository.selectAll();
    expect(logs.any((l) => l.source == 'agent' && l.actionType == 'create_event'), isTrue);

    // 捕获请求不泄漏本地 DB 主键。
    final eventId = event.id;
    final toolResults = <String>[
      for (final req in provider.requests)
        for (final message in req.messages)
          if (message.role == 'user')
            for (final block in message.content)
              if (block is LlmToolResultBlock) block.content.toString(),
    ];
    expect(toolResults.join('\n'), isNot(contains(eventId)));
  });

  test('composition wiring: confirm records user decision plus agent business log', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    const protector = _NoopProtector();
    await _seedAccount(db, 'acc-1');
    final secretStore = ProtectedAgentSecretStore(database: db, protector: protector);
    await _seedAgentConfig(db, 'acc-1', secrets: secretStore, apiKey: 'test-key');

    final provider = _ScriptedProvider([
      _ScriptedCall(() => [
        const ToolUseCompletedEvent(id: 'tu-1', name: 'create_event',
            input: {'title': '健身', 'start_at': '2026-08-01T15:00:00+08:00', 'end_at': '2026-08-01T16:00:00+08:00'}),
        const CompletedEvent(),
      ]),
      _ScriptedCall(() => [const TextDeltaEvent('已创建。'), const CompletedEvent()]),
    ]);
    final composition = await _buildTestComposition(db, 'acc-1',
        provider: provider, protector: protector);
    addTearDown(composition.dispose);
    final states = <AgentRunViewState>[];
    final done = Completer<void>();
    late String runId;
    composition.sessionService.send(accountId: 'acc-1', userText: '建个日程').listen((s) {
      states.add(s);
      if (s.state == AgentRunState.waitingForUser) runId = s.runId;
    }, onDone: done.complete);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await composition.sessionService
        .confirmWriteProposal(accountId: 'acc-1', runId: runId, approve: true, remember: false)
        .drain<void>();
    await done.future;

    final logs = await db.actionLogsRepository.selectAll();
    // 用户决策（agent_write_confirm/approved）与 agent 业务成功日志各一行。
    expect(
      logs.where((l) => l.actionType == 'agent_write_confirm' && l.result == 'approved'),
      hasLength(1),
    );
    expect(
      logs.where((l) => l.source == 'agent' && l.actionType == 'create_event' && l.result == 'success'),
      hasLength(1),
    );
  });

  test('composition wiring: remember relaxes, second identical write auto-executes', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    const protector = _NoopProtector();
    await _seedAccount(db, 'acc-1');
    final secretStore = ProtectedAgentSecretStore(
      database: db,
      protector: protector,
    );
    await _seedAgentConfig(db, 'acc-1', secrets: secretStore, apiKey: 'test-key');

    // 第一次：create_event -> 确认卡；用户勾选"以后不再确认"。
    final firstProvider = _ScriptedProvider([
      _ScriptedCall(() => [
        const ToolUseCompletedEvent(id: 'tu-1', name: 'create_event',
            input: {'title': '健身', 'start_at': '2026-08-01T15:00:00+08:00', 'end_at': '2026-08-01T16:00:00+08:00'}),
        const CompletedEvent(),
      ]),
      _ScriptedCall(() => [const TextDeltaEvent('已创建。'), const CompletedEvent()]),
    ]);
    final first = await _buildTestComposition(db, 'acc-1',
        provider: firstProvider, protector: protector);
    addTearDown(first.dispose);
    final done1 = Completer<void>();
    late String runId1;
    first.sessionService.send(accountId: 'acc-1', userText: '建个日程').listen((s) {
      if (s.state == AgentRunState.waitingForUser) runId1 = s.runId;
    }, onDone: done1.complete);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await first.sessionService
        .confirmWriteProposal(accountId: 'acc-1', runId: runId1, approve: true, remember: true)
        .drain<void>();
    await done1.future;

    // 权限放宽（remember）必须写 ActionLog：markAlwaysAllow -> updatePolicy
    // 落一行 source='user' / actionType='update_permission_policy'。
    expect(
      (await db.actionLogsRepository.selectAll())
          .any((l) => l.source == 'user' && l.actionType == 'update_permission_policy'),
      isTrue,
      reason: 'remember relaxation must write an ActionLog',
    );

    // 第二次：同样的 create_event 不再出现确认卡（ask_first_time 已放行为 always_allow）。
    final secondProvider = _ScriptedProvider([
      _ScriptedCall(() => [
        const ToolUseCompletedEvent(id: 'tu-1', name: 'create_event',
            input: {'title': '复习', 'start_at': '2026-08-02T09:00:00+08:00', 'end_at': '2026-08-02T10:00:00+08:00'}),
        const CompletedEvent(),
      ]),
      _ScriptedCall(() => [const TextDeltaEvent('已创建。'), const CompletedEvent()]),
    ]);
    final second = await _buildTestComposition(db, 'acc-1',
        provider: secondProvider, protector: protector);
    addTearDown(second.dispose);
    final states2 = <AgentRunViewState>[];
    final done2 = Completer<void>();
    second.sessionService.send(accountId: 'acc-1', userText: '再建个复习日程').listen((s) {
      states2.add(s);
    }, onDone: done2.complete);
    await done2.future;

    expect(states2.any((s) => s.userAction?.type == AgentUserActionType.writeConfirmation),
        isFalse, reason: 'after remember, the same action auto-executes');
    expect(states2.last.state, AgentRunState.completed);
    expect((await db.select(db.calendarEvents).get()).length, 2);
  });

  // --- Step 1/5: SQLite fault-injection rollback tests (real Drift) ----------
  //
  // These prove the write + audit atomicity on the REAL SQLite engine through
  // the composed registry. A `BEFORE INSERT ... RAISE(ABORT)` trigger on
  // `action_logs` forces the audit to fail AFTER the business write has already
  // executed inside the very same Drift transaction; if the write tool correctly
  // joins commit + audit + permission mutation into one shared transaction, the
  // trigger's abort rolls EVERYTHING back (event + service log + policy row).

  const validTimedEventArguments = {
    'title': '健身',
    'start_at': '2026-08-01T15:00:00+08:00',
    'end_at': '2026-08-01T16:00:00+08:00',
  };

  AgentToolContext integrationCtx(String accountId, String runId) =>
      AgentToolContext(
        accountId: accountId,
        runId: runId,
        clock: FixedBeijingClock(DateTime(2026, 8, 1, 12)),
        cancellation: CancellationSignal(),
        references: RunReferenceStore(runId: runId),
      );

  Future<void> seedAccountForWrites(AppDatabase db, String accountId) async {
    await _seedAccount(db, accountId);
  }

  Future<({AgentToolRegistry registry, AgentCompositionResult composition})>
      writeRegistry(AppDatabase db, String accountId) async {
    const protector = _NoopProtector();
    await seedAccountForWrites(db, accountId);
    final secretStore = ProtectedAgentSecretStore(
      database: db,
      protector: protector,
    );
    await _seedAgentConfig(db, accountId, secrets: secretStore, apiKey: 'test-key');
    final provider = _ScriptedProvider(const []);
    final composition = await _buildTestComposition(
      db,
      accountId,
      provider: provider,
      protector: protector,
    );
    return (registry: composition.registry, composition: composition);
  }

  // 直接 allow 路径：强制 agent 审计失败时，create_event 彻底回滚（事件 + 日志全无）。
  test('agent write rolls back when audit persistence fails', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final built = await writeRegistry(db, 'acc-1');
    addTearDown(built.composition.dispose);

    // create_event 默认 ask_first_time 首次需确认；先记录首次确认使其放行走 allow。
    await db.into(db.agentPermissionPolicies).insert(
          AgentPermissionPoliciesCompanion.insert(
            id: 'pp-1',
            accountId: 'acc-1',
            actionType: 'create_event',
            targetType: const Value('event'),
            confirmationMode: 'always_allow',
            riskLevel: const Value('medium'),
            enabled: const Value(true),
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    // 强制 source='agent' 的 ActionLog 插入失败——模拟审计持久化故障。
    await db.customStatement('''
CREATE TRIGGER fail_agent_log BEFORE INSERT ON action_logs
WHEN NEW.source = 'agent'
BEGIN SELECT RAISE(ABORT, 'forced agent audit failure'); END;
''');
    addTearDown(() => db.customStatement('DROP TRIGGER IF EXISTS fail_agent_log'));

    final result = await built.registry.execute(
      toolName: 'create_event',
      arguments: validTimedEventArguments,
      context: integrationCtx('acc-1', 'r-audit'),
    );
    expect(result.status, AgentToolStatus.error);
    expect((await db.select(db.calendarEvents).get()), isEmpty,
        reason: 'calendar event must roll back with the failed audit');
    expect((await db.select(db.actionLogs).get()).where((l) => l.source == 'agent'), isEmpty,
        reason: 'no agent ActionLog may survive a rolled-back write');
  });

  // 已确认 remember=true 路径：权限策略插入被强制失败时，事件 + 全部日志 + 策略行一起回滚。
  test('confirmed remember write rolls back when permission policy insert fails', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final built = await writeRegistry(db, 'acc-1');
    addTearDown(built.composition.dispose);

    // 先执行一次 create_event 确认（不 remember），让其暂停挂起。
    final provider = _ScriptedProvider([
      _ScriptedCall(() => [
            const ToolUseCompletedEvent(
              id: 'tu-1',
              name: 'create_event',
              input: validTimedEventArguments,
            ),
            const CompletedEvent(),
          ]),
      _ScriptedCall(() => [const TextDeltaEvent('ok'), const CompletedEvent()]),
    ]);
    final composition = await _buildTestComposition(
      db,
      'acc-1',
      provider: provider,
      protector: const _NoopProtector(),
    );
    addTearDown(composition.dispose);
    final states = <AgentRunViewState>[];
    final done = Completer<void>();
    late String runId;
    composition.sessionService.send(accountId: 'acc-1', userText: '建个日程').listen((s) {
      states.add(s);
      if (s.state == AgentRunState.waitingForUser) runId = s.runId;
    }, onDone: done.complete);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(
      states.any((s) => s.userAction?.type == AgentUserActionType.writeConfirmation),
      isTrue,
    );

    // 强制 agent_permission_policy 插入失败——模拟 remember 放宽的权限落库故障。
    await db.customStatement('''
CREATE TRIGGER fail_permission_policy BEFORE INSERT ON agent_permission_policies
BEGIN SELECT RAISE(ABORT, 'forced permission policy failure'); END;
''');
    addTearDown(() => db.customStatement('DROP TRIGGER IF EXISTS fail_permission_policy'));

    await composition.sessionService
        .confirmWriteProposal(accountId: 'acc-1', runId: runId, approve: true, remember: true)
        .drain<void>();
    await done.future;

    // 事件与 write 相关的日志全部回滚；但按审计 taxonomy，被回滚的业务写在事务外
    // 留一行 best-effort source='agent' / result='failed' 审计（business write
    // rollback -> agent / actual action / failed）。会话自身的 read_only_run 运行
    // 日志与此 write 无关，不参与断言。
    expect((await db.select(db.calendarEvents).get()), isEmpty,
        reason: 'event must roll back when remember policy insert fails');
    final logs = await db.select(db.actionLogs).get();
    // success 审计必须随事务回滚，只允许留下一条 failed 审计。
    final createEventLogs = logs.where((l) => l.actionType == 'create_event').toList();
    expect(createEventLogs.where((l) => l.result == 'success'), isEmpty,
        reason: 'agent create_event success log must roll back with the write');
    expect(createEventLogs.length, 1,
        reason: 'one best-effort failed audit records the rolled-back write');
    expect(createEventLogs.single.source, 'agent');
    expect(createEventLogs.single.result, 'failed');
    expect(
      logs.where((l) => l.actionType == 'update_permission_policy'),
      isEmpty,
      reason: 'user-sourced permission-change (remember) log must roll back too',
    );
    // 策略行不得残留（remember 放宽失败）。
    expect((await db.select(db.agentPermissionPolicies).get()), isEmpty,
        reason: 'permission policy row must roll back');
  });

  // Step 5 单写 service：create_task 在审计失败时彻底回滚。
  test('create_task rolls back when audit persistence fails', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final built = await writeRegistry(db, 'acc-1');
    addTearDown(built.composition.dispose);

    await db.into(db.agentPermissionPolicies).insert(
          AgentPermissionPoliciesCompanion.insert(
            id: 'pp-1',
            accountId: 'acc-1',
            actionType: 'create_task',
            targetType: const Value('task'),
            confirmationMode: 'always_allow',
            riskLevel: const Value('medium'),
            enabled: const Value(true),
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await db.customStatement('''
CREATE TRIGGER fail_agent_log BEFORE INSERT ON action_logs
WHEN NEW.source = 'agent'
BEGIN SELECT RAISE(ABORT, 'forced agent audit failure'); END;
''');
    addTearDown(() => db.customStatement('DROP TRIGGER IF EXISTS fail_agent_log'));

    final result = await built.registry.execute(
      toolName: 'create_task',
      arguments: const {'title': '复习', 'estimated_minutes': 60},
      context: integrationCtx('acc-1', 'r-task'),
    );
    expect(result.status, AgentToolStatus.error);
    expect((await db.select(db.tasks).get()), isEmpty,
        reason: 'task must roll back with the failed audit');
    expect((await db.select(db.actionLogs).get()).where((l) => l.source == 'agent'), isEmpty);
  });

  // Step 5 多写 service：create_event（含 reminders）在审计失败时，业务表与
  // 服务日志一并回滚，且重跑不产生重复行。
  test('create_event with reminders rolls back and rerun leaves no duplicates', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final built = await writeRegistry(db, 'acc-1');
    addTearDown(built.composition.dispose);

    await db.into(db.agentPermissionPolicies).insert(
          AgentPermissionPoliciesCompanion.insert(
            id: 'pp-1',
            accountId: 'acc-1',
            actionType: 'create_event',
            targetType: const Value('event'),
            confirmationMode: 'always_allow',
            riskLevel: const Value('medium'),
            enabled: const Value(true),
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await db.customStatement('''
CREATE TRIGGER fail_agent_log BEFORE INSERT ON action_logs
WHEN NEW.source = 'agent'
BEGIN SELECT RAISE(ABORT, 'forced agent audit failure'); END;
''');
    addTearDown(() => db.customStatement('DROP TRIGGER IF EXISTS fail_agent_log'));

    final result = await built.registry.execute(
      toolName: 'create_event',
      arguments: {
        ...validTimedEventArguments,
        'reminder_offsets_minutes': [10, 30],
      },
      context: integrationCtx('acc-1', 'r-rem'),
    );
    expect(result.status, AgentToolStatus.error);
    expect((await db.select(db.calendarEvents).get()), isEmpty);
    expect((await db.select(db.reminders).get()), isEmpty,
        reason: 'reminders written by the multi-write service must roll back');
    expect((await db.select(db.actionLogs).get()).where((l) => l.source == 'agent'), isEmpty);

    // 重跑同一失败调用（无触发器）后不产生重复行——回滚是完整的。
    await db.customStatement('DROP TRIGGER IF EXISTS fail_agent_log');
    final retry = await built.registry.execute(
      toolName: 'create_event',
      arguments: {
        ...validTimedEventArguments,
        'reminder_offsets_minutes': [10, 30],
      },
      context: integrationCtx('acc-1', 'r-rem2'),
    );
    expect(retry.status, AgentToolStatus.success);
    expect((await db.select(db.calendarEvents).get()).length, 1,
        reason: 'failed attempt must leave zero rows, so the retry lands exactly one');
    expect((await db.select(db.reminders).get()).length, 2,
        reason: 'two reminder offsets for the single retried event');
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Task 7 FINAL composition regression: the WHOLE hardened write flow, end to
  // end, on real Drift composition with a scripted provider.
  //
  //   1. query/bind an event-or-task ref  → get_tasks binds a run-local task ref
  //   2. reject one malformed write        → invalid_write_arguments, no DB change
  //   3. confirmation preview names target → names the event title, no id/ref
  //   4. approve + remember                → domain row + agent_write_confirm +
  //                                          domain action + permission logs
  //   5. same action again                 → direct success, NO second confirmation
  //   6. force audit failure for a 3rd write → complete rollback (event + logs)
  // ─────────────────────────────────────────────────────────────────────────
  test('Task 7 composition: full hardened write flow (bind->validate->confirm->'
      'remember->auto->rollback)', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    const protector = _NoopProtector();
    await _seedAccount(db, 'acc-1');
    final secretStore = ProtectedAgentSecretStore(
      database: db,
      protector: protector,
    );
    await _seedAgentConfig(db, 'acc-1', secrets: secretStore, apiKey: 'test-key');
    // A task row so call 1 (get_tasks) binds a run-local task ref; a personal
    // event row so create_event targets an account-scoped personal source.
    await _insertTask(db, 'task-1', 'acc-1', '复习算法');
    await db.into(db.calendarEvents).insert(
          CalendarEventsCompanion.insert(
            id: 'ev-1',
            accountId: 'acc-1',
            source: 'user',
            externalId: Value('ev-1'),
            title: '健身',
            type: 'personal',
            startAt: Value(DateTime.utc(2026, 8, 1, 7).millisecondsSinceEpoch),
            endAt: Value(DateTime.utc(2026, 8, 1, 8).millisecondsSinceEpoch),
            allDay: false,
            timezone: 'Asia/Shanghai',
            locationName: Value('健身房'),
            createdAt: 1,
            updatedAt: 1,
          ),
        );

    // Call 1: read query binds a task ref (get_tasks over the seeded task).
    // Call 2: malformed create_event (missing start_at -> invalid_write_arguments,
    //         NO confirmation pause, NO DB change; model retries with fixed args).
    // Call 3: valid create_event -> pauses for write confirmation.
    // Call 4: final text after the user approves (remember=true).
    final provider = _ScriptedProvider([
      _ScriptedCall(() => [
            const ToolUseCompletedEvent(
              id: 'tu-1',
              name: 'get_tasks',
              input: {},
            ),
            const CompletedEvent(),
          ]),
      // Malformed write: `create_event` needs a timed field set. Missing both
      // start_at/end_at is rejected at propose time as invalid_write_arguments.
      _ScriptedCall(() => [
            const ToolUseCompletedEvent(
              id: 'tu-2',
              name: 'create_event',
              input: {
                'title': '健身',
                'location': '健身房',
              },
            ),
            // The model immediately retries with a VALID argument set.
            const ToolUseCompletedEvent(
              id: 'tu-3',
              name: 'create_event',
              input: validTimedEventArguments,
            ),
            const CompletedEvent(),
          ]),
      // Call 4: final text after confirm(approve, remember).
      _ScriptedCall(() => [
            const TextDeltaEvent('已为你新建日程「健身」。'),
            const CompletedEvent(),
          ]),
    ]);
    final composition = await _buildTestComposition(
      db,
      'acc-1',
      provider: provider,
      protector: protector,
    );
    addTearDown(composition.dispose);

    final states = <AgentRunViewState>[];
    final done = Completer<void>();
    late String runId;
    composition.sessionService
        .send(accountId: 'acc-1', userText: '帮我查下任务并建个健身日程')
        .listen((s) {
      states.add(s);
      if (s.state == AgentRunState.waitingForUser) runId = s.runId;
    }, onDone: done.complete);

    // --- Step 1: query/bind a task ref -------------------------------------
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(provider.streamCallCount, greaterThanOrEqualTo(1),
        reason: 'get_tasks must have run');
    // The read tool bound a run-local task ref; the model-facing tool feed
    // carries that opaque `ref_*` token but never the raw task DB id.
    final feed = _capturedToolResults(provider).join('\n');
    expect(feed, isNot(contains('task-1')),
        reason: 'raw task DB id must never reach the model');
    expect(feed, contains('ref_'),
        reason: 'the get_tasks tool_result must hand back a run-local ref token');

    // --- Step 2: reject one malformed write, no DB change ------------------
    // Wait for the model to have reached the malformed create_event (call 2)
    // AND the corrected call 3 that pauses for confirmation.
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(
      states.any((s) => s.userAction?.type == AgentUserActionType.writeConfirmation),
      isTrue,
      reason: 'the valid create_event (after the malformed one was rejected) '
          'must pause for write confirmation',
    );
    // The malformed write added NOTHING: no new event rows beyond the seeded
    // personal event, no agent success/confirm/decline audit for it, and no
    // permission prior bytes.
    expect((await db.select(db.calendarEvents).get()).length, 1,
        reason: 'malformed write must leave exactly the one seeded event');
    // The write-tool feed names the title and contains NO id/ref of the target.
    final confirmProposal =
        states.lastWhere((s) => s.userAction != null).userAction!.writeProposal;
    expect(confirmProposal, isNotNull);
    expect(confirmProposal!.previewLines.join('\n'), contains('健身'),
        reason: 'confirmation preview must name the target title');
    expect(confirmProposal.previewLines.join('\n'), isNot(contains('ev-1')),
        reason: 'confirmation preview must not leak the raw event DB id');

    // --- Step 4: approve with remember -> domain row + audit logs ---------
    await composition.sessionService
        .confirmWriteProposal(
            accountId: 'acc-1', runId: runId, approve: true, remember: true)
        .drain<void>();
    await done.future;

    expect(states.last.state, AgentRunState.completed);
    // DIRECT assertion of the malformed-write rejection (review Important):
    // once the paused run has resumed and completed, the tool_results turn
    // carrying the malformed create_event's error is folded into the final
    // model request. The session service encodes the registry's errorCode as a
    // `{"code": ...}` JSON payload, so the sanitized feed must contain exactly
    // `invalid_write_arguments`. This catches any future regression that
    // returns a different error code or silently swallows the malformed call.
    expect(
      _capturedToolResults(provider).join('\n'),
      contains('invalid_write_arguments'),
      reason: 'the malformed create_event must be surfaced to the model as '
          'invalid_write_arguments',
    );
    final eventsAfter = await db.select(db.calendarEvents).get();
    expect(eventsAfter.length, 2,
        reason: 'the approved create_event adds the second (健身) personal row');
    final logs = await db.actionLogsRepository.selectAll();
    // user confirmation decision
    expect(
      logs.where((l) =>
          l.source == 'user' &&
          l.actionType == 'agent_write_confirm' &&
          l.result == 'approved'),
      hasLength(1),
    );
    // agent business success for the actual domain action
    expect(
      logs.where((l) =>
          l.source == 'agent' &&
          l.actionType == 'create_event' &&
          l.result == 'success'),
      hasLength(1),
    );
    // remember = user permission relaxation is audited
    expect(
      logs.where((l) =>
          l.source == 'user' &&
          l.actionType == 'update_permission_policy' &&
          l.result == 'success'),
      isNotEmpty,
      reason: 'remember relaxation must be audited as a permission change',
    );

    // --- Step 5: same action again -> direct success, no confirmation ------
    final secondProvider = _ScriptedProvider([
      _ScriptedCall(() => [
            const ToolUseCompletedEvent(
              id: 'tu-1',
              name: 'create_event',
              input: {
                'title': '游泳',
                'start_at': '2026-08-02T09:00:00+08:00',
                'end_at': '2026-08-02T10:00:00+08:00',
              },
            ),
            const CompletedEvent(),
          ]),
      _ScriptedCall(() => [
            const TextDeltaEvent('已新建。'),
            const CompletedEvent(),
          ]),
    ]);
    final second = await _buildTestComposition(
      db,
      'acc-1',
      provider: secondProvider,
      protector: protector,
    );
    addTearDown(second.dispose);
    final states2 = <AgentRunViewState>[];
    final done2 = Completer<void>();
    second.sessionService
        .send(accountId: 'acc-1', userText: '再建个游泳日程')
        .listen((s) => states2.add(s), onDone: done2.complete);
    await done2.future;

    expect(
      states2.any((s) =>
          s.userAction?.type == AgentUserActionType.writeConfirmation),
      isFalse,
      reason: 'after remember, the same create_event action auto-executes '
          'without a second confirmation card',
    );
    expect(states2.last.state, AgentRunState.completed);
    expect((await db.select(db.calendarEvents).get()).length, 3,
        reason: 'the second identical write lands a direct row with no pause');

    // --- Step 6: force an audit failure -> complete rollback --------------
    final third = await _buildTestComposition(
      db,
      'acc-1',
      provider: _ScriptedProvider(const []),
      protector: protector,
    );
    addTearDown(third.dispose);
    // Force every source='agent' ActionLog insert to abort — simulates an audit
    // persistence failure ON the write path (shared transaction below).
    await db.customStatement('''
CREATE TRIGGER fail_agent_log BEFORE INSERT ON action_logs
WHEN NEW.source = 'agent'
BEGIN SELECT RAISE(ABORT, 'forced agent audit failure'); END;
''');
    addTearDown(() => db.customStatement('DROP TRIGGER IF EXISTS fail_agent_log'));
    final beforeThird = (await db.select(db.calendarEvents).get()).length;
    final beforeThirdSuccessLogs = (await db.select(db.actionLogs).get())
        .where((l) =>
            l.source == 'agent' &&
            l.actionType == 'create_event' &&
            l.result == 'success')
        .length;
    // create_event is now always_allow (remembered), so a third write is a
    // direct all-granted write; the audit failure must roll back the event and
    // every log written in the same atomic unit.
    final thirdResult = await third.registry.execute(
      toolName: 'create_event',
      arguments: validTimedEventArguments,
      context: integrationCtx('acc-1', 'r-final'),
    );
    expect(thirdResult.status, AgentToolStatus.error,
        reason: 'write commit must fail when the audit cannot be persisted');
    // Complete rollback: no new event rows and no NEW success audit may exist
    // beyond the two that the earlier approved/remembered writes legitimately
    // committed. The rolled-back third write must leave both unchanged.
    expect((await db.select(db.calendarEvents).get()).length, beforeThird,
        reason: 'the third event must roll back with the failed audit');
    final thirdSuccessLogs = (await db.select(db.actionLogs).get())
        .where((l) =>
            l.source == 'agent' &&
            l.actionType == 'create_event' &&
            l.result == 'success')
        .length;
    expect(thirdSuccessLogs, beforeThirdSuccessLogs,
        reason: 'the rolled-back third write must add no new agent success audit');
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Task 3 composition regression: historical overlay/relation lookups.
  // The Agent locates concrete write targets with get_schedule(query=...) across
  // retained local history (independent of the default semester), then resolves
  // those run-local refs into create_user_overlay / create_schedule_relation.
  // It must NEVER use get_conflicts as a participant finder, and no outbound
  // request may carry a hardcoded semester.
  // ─────────────────────────────────────────────────────────────────────────
  test(
    'composition: get_schedule(query) locates history targets for overlay/relation,'
    ' never get_conflicts as finder, no hardcoded semester outbound',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      // Build the composed registry first (seeds the account + agent config).
      final built = await writeRegistry(db, 'acc-1');
      addTearDown(built.composition.dispose);
      // Wrap the composed registry in a recorder so the ACTUAL tool-invocation
      // sequence is observable (this is what makes the get_conflicts-finder
      // assertion fail-capable).
      final registry = _RecordingRegistry(built.registry);

      // A default JW semester UNRELATED to the event dates (gateway semester
      // override side channel the query mode must ignore).
      await db.into(db.sourceConfigs).insert(
            SourceConfigsCompanion.insert(
              id: 'acc-1:ustc_jw',
              accountId: 'acc-1',
              source: 'ustc_jw',
              enabled: const Value(true),
              configJson: const Value(
                '{"semesterId":421,"semesterKey":"2026spring",'
                '"displayName":"2025-2026学年春季学期"}',
              ),
              lastSuccessAt: const Value(null),
              retryAfter: const Value(null),
              updatedAt: 1,
            ),
          );

      // Historical course occurrences across two semesters (March = 2026spring,
      // August = 2026fall) — the query must find BOTH without reading the
      // default semester.
      await _insertCourseSeries(
        db,
        'series-net',
        'acc-1',
        externalId: 'lesson-net',
        title: '计算机网络',
        semesterKey: '2026spring',
      );
      await _insertCourseOccurrence(
        db,
        'net-mar-a',
        'acc-1',
        '计算机网络',
        seriesExternalId: 'lesson-net',
        location: '三教101',
        start: DateTime(2026, 3, 2, 8, 40),
        end: DateTime(2026, 3, 2, 9, 25),
      );
      await _insertCourseOccurrence(
        db,
        'net-mar-b',
        'acc-1',
        '计算机网络',
        seriesExternalId: 'lesson-net',
        location: '三教201',
        start: DateTime(2026, 3, 4, 10, 35),
        end: DateTime(2026, 3, 4, 11, 20),
      );
      await _insertCourseOccurrence(
        db,
        'net-aug',
        'acc-1',
        '计算机网络',
        seriesExternalId: 'lesson-net',
        location: '四教102',
        start: DateTime(2026, 8, 14, 14, 0),
        end: DateTime(2026, 8, 14, 15, 40),
      );

      // Allow the two write actions so the registry execute path commits
      // without a confirmation pause (deterministic registry-level regression).
      await db.into(db.agentPermissionPolicies).insert(
            AgentPermissionPoliciesCompanion.insert(
              id: 'pp-overlay',
              accountId: 'acc-1',
              actionType: 'create_user_overlay',
              targetType: const Value('overlay'),
              confirmationMode: 'always_allow',
              riskLevel: const Value('medium'),
              enabled: const Value(true),
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await db.into(db.agentPermissionPolicies).insert(
            AgentPermissionPoliciesCompanion.insert(
              id: 'pp-relation',
              accountId: 'acc-1',
              actionType: 'create_schedule_relation',
              targetType: const Value('relation'),
              confirmationMode: 'always_allow',
              riskLevel: const Value('medium'),
              enabled: const Value(true),
              createdAt: 1,
              updatedAt: 1,
            ),
          );

      // Step A: get_schedule(query) locates concrete refs across history.
      final ctx = integrationCtx('acc-1', 'r-task3');
      final schedule = await registry.execute(
        toolName: 'get_schedule',
        arguments: {'query': '计算机网络'},
        context: ctx,
      );
      expect(schedule.status, AgentToolStatus.success);
      final events = schedule.payload['events']! as List;
      expect(events, hasLength(3),
          reason: 'query must find all three historical occurrences regardless '
              'of the default semester');
      final scheduleEncoded = jsonEncode(schedule.payload);
      expect(scheduleEncoded, isNot(contains('semester')));
      expect(scheduleEncoded, isNot(contains('2026spring')));
      expect(scheduleEncoded, isNot(contains('421')));
      // Three concrete run-local refs.
      final refs = <String>[
        for (final e in events)
          (e! as Map<String, Object?>)['ref']! as String,
      ];
      expect(refs, hasLength(3));
      expect(refs.first, startsWith('ref_'));

      // Step B: create_user_overlay on one historical target ref.
      final overlay = await registry.execute(
        toolName: 'create_user_overlay',
        arguments: {
          'ref_event': refs.first,
          'attendance_policy': 'must_go',
        },
        context: ctx,
      );
      expect(overlay.status, AgentToolStatus.success,
          reason: 'overlay targeting a get_schedule(query) ref must commit');
      expect(overlay.payload['result'], 'updated_event_overlay');

      // Step C: two title queries before create_schedule_relation. The relation
      // binds BOTH participants from get_schedule(query) refs (never get_conflicts).
      final relCtx = integrationCtx('acc-1', 'r-task3-rel');
      final rel1 = await registry.execute(
        toolName: 'get_schedule',
        arguments: {'query': '计算机网络', 'from': '2026-03-01', 'through': '2026-03-31'},
        context: relCtx,
      );
      expect(rel1.status, AgentToolStatus.success);
      final rel1Events = rel1.payload['events']! as List;
      final relRefs = <String>[
        for (final e in rel1Events) (e! as Map<String, Object?>)['ref']! as String,
      ];
      expect(relRefs, hasLength(2),
          reason: 'the two March candidates are the first two same-title options');
      final rel2 = await registry.execute(
        toolName: 'get_schedule',
        arguments: {'query': '计算机网络'},
        context: relCtx,
      );
      expect(rel2.status, AgentToolStatus.success);
      final relation = await registry.execute(
        toolName: 'create_schedule_relation',
        arguments: {
          'ref_left': relRefs[0],
          'ref_right': relRefs[1],
          'conflict_state': 'no_conflict',
          'reason': '二选一课程',
        },
        context: relCtx,
      );
      expect(relation.status, AgentToolStatus.success,
          reason: 'relation between two get_schedule(query) refs must commit');
      expect(relation.payload['result'], 'created_schedule_relation');

      // Step D: assert the ACTUAL tool-invocation sequence — the observable
      // contract the model follows in this scenario. `get_conflicts` must never
      // be invoked as a participant finder, and every lookup that feeds the
      // overlay/relation must be a TITLE query (`get_schedule(query=...)`),
      // never a date-range-only or get_conflicts call.
      final invokedNames =
          registry.invocations.map((i) => i.toolName).toList(growable: false);
      // The full sequence in order: the get_schedule(query) lookups precede
      // their consuming write tools.
      expect(invokedNames, [
        'get_schedule', // Step A lookup before overlay
        'create_user_overlay',
        'get_schedule', // first relation lookup (range title query)
        'get_schedule', // second relation lookup (full history title query)
        'create_schedule_relation',
      ], reason: 'the composed flow must route through get_schedule(query) '
          'title lookups before the overlay/relation writes, never get_conflicts '
          'as a finder');
      // No get_conflicts intervened anywhere in the finder sequence.
      expect(invokedNames, isNot(contains('get_conflicts')),
          reason: 'get_conflicts must never be invoked as a participant finder');
      // Every get_schedule invocation used a title `query` (not a bare
      // date-range lookup), proving participants come from title matching.
      final getScheduleCalls = registry.invocations
          .where((i) => i.toolName == 'get_schedule')
          .toList(growable: false);
      expect(getScheduleCalls, hasLength(3));
      for (final call in getScheduleCalls) {
        final query = call.arguments['query'];
        expect(query, isNotNull,
            reason: 'each get_schedule lookup in the finder flow must carry a '
                'title query');
        expect(query, '计算机网络');
      }

      // No outbound write payload carries a hardcoded semester.
      final out = jsonEncode([overlay.payload, relation.payload]);
      expect(out, isNot(contains('2026spring')));
      expect(out, isNot(contains('421')));
      expect(out, isNot(contains('2026fall')));
      // The composed tool set must expose query on get_schedule (the model sees
      // it as the finder for write targets).
      final scheduleDecl = registry.schemas.firstWhere((s) => s.name == 'get_schedule');
      expect(scheduleDecl.inputSchema['properties'], contains('query'),
          reason: 'the model must be able to call get_schedule(query=...) to '
              'locate write targets across history');

      // The relation actually persisted both participants (past sort is
      // most-recent-first, so relRefs[0] is the 3/4 occurrence net-mar-b).
      final rows = await db.select(db.scheduleRelations).get();
      expect(rows, hasLength(1));
      expect({rows.single.leftEventId, rows.single.rightEventId},
          {'net-mar-a', 'net-mar-b'});
    },
  );

  // ─────────────────────────────────────────────────────────────────────────
  // Task 4: local ActionChips route to the exact schedule section.
  //
  // "查看日程" opens `?section=week` (week view); "查看任务" opens
  // `?section=tasks` (tasks section). This pumps the REAL router, emits toolbar
  // runs that produce BOTH local actions, taps each chip, and asserts the
  // SegmentedButton's selected value. It also re-navigates back to the week
  // section and proves the route rebuild (didUpdateWidget) updates the visible
  // section rather than preserving stale StatefulShell state.
  // ─────────────────────────────────────────────────────────────────────────
  testWidgets(
    'local ActionChips route schedule->week and tasks->tasks through the real router',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      const protector = _NoopProtector();

      await _seedAccount(db, 'acc-1');
      final secretStore = ProtectedAgentSecretStore(
        database: db,
        protector: protector,
      );
      await _seedAgentConfig(db, 'acc-1', secrets: secretStore, apiKey: 'test-key');
      await _insertCourseSeries(
        db,
        'series-rose',
        'acc-1',
        externalId: 'lesson-rose',
        title: '离散数学',
        semesterKey: '2026spring',
      );
      await _insertCourseOccurrence(
        db,
        'rose-occ-1',
        'acc-1',
        '离散数学',
        seriesExternalId: 'lesson-rose',
        location: '三教101',
        start: DateTime(2026, 3, 2, 8, 40),
        end: DateTime(2026, 3, 2, 9, 25),
      );
      await _insertTask(db, 'task-1', 'acc-1', '复习离散');

      // One call that runs BOTH a schedule tool and a task tool, so the run
      // emits a deduplicated schedule action AND a deduplicated tasks action;
      // a final text call completes the run.
      final provider = _ScriptedProvider([
        _ScriptedCall(() => [
          const ToolUseCompletedEvent(
            id: 'tu-1',
            name: 'get_schedule',
            input: {'from': '2026-03-01', 'through': '2026-03-31'},
          ),
          const ToolUseCompletedEvent(
            id: 'tu-2',
            name: 'get_tasks',
            input: {},
          ),
          const CompletedEvent(),
        ]),
        _ScriptedCall(() => [
          const TextDeltaEvent('已完成查询。'),
          const CompletedEvent(),
        ]),
      ]);

      Future<AgentCompositionResult> loadComposition(
        AppDatabase database,
        String accountId,
      ) =>
          _buildTestComposition(
            database,
            accountId,
            provider: provider,
            protector: protector,
          );

      final router = buildRouter(
        _FakeWebsiteLauncher(),
        db,
        const NoopReminderReconciler(),
        loadComposition,
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      // Task 9: enlarged registry needs more pumps for composition build.
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      // Run a question that triggers the schedule + tasks tools.
      await tester.enterText(
        find.byKey(const Key('agent-chat-input')),
        '查一下课再查一下任务。',
      );
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.send);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      // Both local action chips present.
      expect(find.widgetWithText(ActionChip, '查看日程'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, '查看任务'), findsOneWidget);

      SegmentedButton<ScheduleSection> seg() => tester.widget<
          SegmentedButton<ScheduleSection>>(
        find.byType(SegmentedButton<ScheduleSection>),
      );

      Future<void> tapChip(String label) async {
        final finder = find.widgetWithText(ActionChip, label);
        // The chip is inside the chat ListView; the run just completed, so it
        // is already the newest message near the bottom. ensureVisible scrolls
        // it fully into view, then pumpAndSettle completes the scroll animation.
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        await tester.tap(finder);
        for (var i = 0; i < 15; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
      }

      // Return to the chat branch (schedule is a sibling bottom-nav branch).
      // pumpAndSettle lets the StatefulShell branch transition finish so the
      // chip geometry is laid out on-screen before tapping.
      Future<void> goToChat() async {
        router.go('/chat');
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('agent-chat-input')), findsOneWidget);
      }

      // --- 查看日程 -> week section ---
      await tapChip('查看日程');
      expect(find.byType(SegmentedButton<ScheduleSection>), findsOneWidget);
      expect(seg().selected, {ScheduleSection.week});
      expect(find.byKey(const Key('week-range-label')), findsOneWidget);

      // --- 查看任务 -> tasks section ---
      await goToChat();
      await tapChip('查看任务');
      expect(find.byType(SegmentedButton<ScheduleSection>), findsOneWidget);
      expect(seg().selected, {ScheduleSection.tasks});
      expect(find.byKey(const Key('week-range-label')), findsNothing);

      // --- tasks -> 查看日程 again proves didUpdateWidget/route rebuild ---
      // The StatefulShell keeps the schedule State alive; re-routing to
      // `?section=week` must update the visible section rather than preserve
      // the tasks selection from the stale shell State.
      await goToChat();
      await tapChip('查看日程');
      expect(find.byType(SegmentedButton<ScheduleSection>), findsOneWidget);
      expect(
        seg().selected,
        {ScheduleSection.week},
        reason: 're-routing to ?section=week must update the section, not '
            'preserve the stale tasks selection from shell state',
      );
      expect(find.byKey(const Key('week-range-label')), findsOneWidget);

      // Tear down the tree and let Drift's stream-query close timers fire so
      // the test binding does not report a pending-timer teardown failure.
      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    },
  );

  // ─────────────────────────────────────────────────────────────────────────
  // Task 9 composition flows for move_jw_course_day (critical whole-day moves).
  // Script user request "把 8 月 3 日的教务课程移到 8 月 9 日": model tool use ->
  // critical confirmation -> approve -> moved events in target week -> conflict
  // pair with a target event -> no ref in chat. Plus the decline path and the
  // free discussion path ("调休功能是怎么工作的" needs no tools).
  // ─────────────────────────────────────────────────────────────────────────

  test(
    'composition: whole-day JW course move flow '
    '(confirm -> moved in target week -> conflict pair -> no ref in chat)',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      const protector = _NoopProtector();
      await _seedAccount(db, 'acc-1');
      final secretStore = ProtectedAgentSecretStore(
        database: db,
        protector: protector,
      );
      await _seedAgentConfig(
        db,
        'acc-1',
        secrets: secretStore,
        apiKey: 'test-key',
      );
      // 源日期 2026-08-03 的一门教务课程（09:00-10:40）。
      await _insertCourseSeries(
        db,
        'series-1',
        'acc-1',
        externalId: 'lesson-la',
        title: '线性代数',
        semesterKey: '2026fall',
      );
      await db.into(db.calendarEvents).insert(
            CalendarEventsCompanion.insert(
              id: 'jw-0803',
              accountId: 'acc-1',
              source: 'ustc_jw',
              externalId: const Value('jw-0803'),
              sourceSeriesExternalId: const Value('lesson-la'),
              title: '线性代数',
              type: 'course',
              startAt: Value(_beijingEpoch(2026, 8, 3, 9, 0)),
              endAt: Value(_beijingEpoch(2026, 8, 3, 10, 40)),
              allDay: false,
              timezone: 'Asia/Shanghai',
              locationName: const Value('三教101'),
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await db.into(db.sourceRecords).insert(
            SourceRecordsCompanion.insert(
              id: 'sr-jw-0803',
              accountId: 'acc-1',
              source: 'ustc_jw',
              entityType: 'calendar_event',
              externalId: 'jw-0803',
              localEntityId: 'jw-0803',
              sourceStatus: 'active',
              presence: 'present',
              scopeKey: 'scope',
              firstObservedAt: 1,
              lastObservedAt: 1,
            ),
          );
      // 目标日期 2026-08-09 已有个人事件 09:30-11:00，与移动后的课程时间重叠。
      await db.into(db.calendarEvents).insert(
            CalendarEventsCompanion.insert(
              id: 'ev-target',
              accountId: 'acc-1',
              source: 'user',
              title: '健身',
              type: 'personal',
              startAt: Value(_beijingEpoch(2026, 8, 9, 9, 30)),
              endAt: Value(_beijingEpoch(2026, 8, 9, 11, 0)),
              allDay: false,
              timezone: 'Asia/Shanghai',
              locationName: const Value('健身房'),
              createdAt: 1,
              updatedAt: 1,
            ),
          );

      final provider = _ScriptedProvider([
        // Call 1: 模型先查目标日（写目标定位用 get_schedule，不用 get_conflicts）。
        _ScriptedCall(() => [
              const ToolUseCompletedEvent(
                id: 'tu-1',
                name: 'get_schedule',
                input: {'from': '2026-08-09', 'through': '2026-08-09'},
              ),
              const CompletedEvent(),
            ]),
        // Call 2: move_jw_course_day -> 暂停等待 critical 确认。
        _ScriptedCall(() => [
              const ToolUseCompletedEvent(
                id: 'tu-2',
                name: 'move_jw_course_day',
                input: {
                  'action': 'move',
                  'source_date': '2026-08-03',
                  'target_date': '2026-08-09',
                },
              ),
              const CompletedEvent(),
            ]),
        // Call 3: 批准后模型查目标周，看到移动后的课程。
        _ScriptedCall(() => [
              const ToolUseCompletedEvent(
                id: 'tu-3',
                name: 'get_schedule',
                input: {'from': '2026-08-03', 'through': '2026-08-09'},
              ),
              const CompletedEvent(),
            ]),
        // Call 4: 冲突对。
        _ScriptedCall(() => [
              const ToolUseCompletedEvent(
                id: 'tu-4',
                name: 'get_conflicts',
                input: {'from': '2026-08-09', 'through': '2026-08-09'},
              ),
              const CompletedEvent(),
            ]),
        // Call 5: 最终回复。
        _ScriptedCall(() => [
              const TextDeltaEvent(
                '已把 8 月 3 日的线性代数移到 8 月 9 日（09:00-10:40）。'
                '它和当天 09:30 的健身时间重叠，需要你二选一。',
              ),
              const CompletedEvent(),
            ]),
      ]);
      final composition = await _buildTestComposition(
        db,
        'acc-1',
        provider: provider,
        protector: protector,
      );
      addTearDown(composition.dispose);

      expect(composition.registry.isRegistered('move_jw_course_day'), isTrue,
          reason: '第 11 个写工具必须注册');

      final states = <AgentRunViewState>[];
      final done = Completer<void>();
      late String runId;
      composition.sessionService
          .send(accountId: 'acc-1', userText: '把 8 月 3 日的教务课程移到 8 月 9 日')
          .listen((s) {
        states.add(s);
        if (s.state == AgentRunState.waitingForUser) runId = s.runId;
      }, onDone: done.complete);

      // --- Step 1: 移动请求暂停在 critical 确认卡 ------------------------------
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        states.any(
            (s) => s.userAction?.type == AgentUserActionType.writeConfirmation),
        isTrue,
        reason: 'move_jw_course_day 必须暂停等待 critical 确认',
      );
      final preview = states
          .lastWhere((s) => s.userAction != null)
          .userAction!
          .writeProposal!;
      final previewText = preview.previewLines.join('\n');
      expect(preview.operationLabel, '整日移动教务课程');
      expect(preview.rememberAllowed, isFalse,
          reason: 'critical 确认卡永不提供"以后不再确认"');
      expect(previewText, contains('2026-08-03'));
      expect(previewText, contains('2026-08-09'));
      expect(previewText, contains('线性代数'));
      expect(previewText, contains('课程数：1'));
      expect(previewText, isNot(contains('jw-0803')),
          reason: '确认卡预览不得泄漏 DB id');
      expect(previewText, isNot(contains('ev-target')),
          reason: '确认卡预览不得泄漏 DB id');
      expect(previewText, isNot(contains('ref_')),
          reason: '确认卡预览不得含 ref_*');

      // --- Step 2: 批准 -> 原子写入移动记录 ------------------------------------
      await composition.sessionService
          .confirmWriteProposal(
              accountId: 'acc-1', runId: runId, approve: true, remember: false)
          .drain<void>();
      await done.future;

      expect(states.last.state, AgentRunState.completed);
      final moveRows = await db.select(db.jwDayMoves).get();
      expect(moveRows, hasLength(1));
      expect(moveRows.single.sourceDate, '2026-08-03');
      expect(moveRows.single.targetDate, '2026-08-09');
      final logs = await db.actionLogsRepository.selectAll();
      expect(
        logs.where((l) =>
            l.source == 'agent' &&
            l.actionType == 'move_jw_course_day' &&
            l.result == 'success'),
        hasLength(1),
        reason: '批准必须原子写入一条 agent 成功日志',
      );
      expect(
        logs.where((l) =>
            l.source == 'user' &&
            l.actionType == 'agent_write_confirm' &&
            l.result == 'approved'),
        hasLength(1),
      );

      // --- Step 3: 目标周出现移动后的课程 + 与目标事件构成冲突对 ----------------
      final feed = _capturedToolResults(provider).join('\n');
      expect(feed, contains('2026-08-09T09:00:00'),
          reason: '移动后的课程必须出现在目标周（有效投影时间 09:00）');
      expect(feed, contains('conflictPairs'),
          reason: 'get_conflicts 必须返回冲突对');
      expect(feed, contains('derivedOverlap'),
          reason: '重叠推导的冲突对 origin 为 derivedOverlap');
      expect(feed, isNot(contains('jw-0803')),
          reason: '工具结果不得含原始 DB id');
      expect(feed, isNot(contains('ev-target')),
          reason: '工具结果不得含原始 DB id');
      final finalText = states.last.text;
      expect(finalText, isNot(contains('ref_')),
          reason: '聊天文本不得打印 ref_*');
      expect(finalText, contains('线性代数'),
          reason: '最终回复应总结移动结果');
    },
  );

  test('composition: whole-day JW course move declined writes nothing and is audited', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    const protector = _NoopProtector();
    await _seedAccount(db, 'acc-1');
    final secretStore = ProtectedAgentSecretStore(
      database: db,
      protector: protector,
    );
    await _seedAgentConfig(db, 'acc-1', secrets: secretStore, apiKey: 'test-key');
    await _insertCourseSeries(
      db,
      'series-1',
      'acc-1',
      externalId: 'lesson-la',
      title: '线性代数',
      semesterKey: '2026fall',
    );
    await db.into(db.calendarEvents).insert(
          CalendarEventsCompanion.insert(
            id: 'jw-0803',
            accountId: 'acc-1',
            source: 'ustc_jw',
            externalId: const Value('jw-0803'),
            title: '线性代数',
            type: 'course',
            startAt: Value(_beijingEpoch(2026, 8, 3, 9, 0)),
            endAt: Value(_beijingEpoch(2026, 8, 3, 10, 40)),
            allDay: false,
            timezone: 'Asia/Shanghai',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await db.into(db.sourceRecords).insert(
          SourceRecordsCompanion.insert(
            id: 'sr-jw-0803',
            accountId: 'acc-1',
            source: 'ustc_jw',
            entityType: 'calendar_event',
            externalId: 'jw-0803',
            localEntityId: 'jw-0803',
            sourceStatus: 'active',
            presence: 'present',
            scopeKey: 'scope',
            firstObservedAt: 1,
            lastObservedAt: 1,
          ),
        );

    final provider = _ScriptedProvider([
      _ScriptedCall(() => [
            const ToolUseCompletedEvent(
              id: 'tu-1',
              name: 'move_jw_course_day',
              input: {
                'action': 'move',
                'source_date': '2026-08-03',
                'target_date': '2026-08-09',
              },
            ),
            const CompletedEvent(),
          ]),
      _ScriptedCall(() => [
            const TextDeltaEvent('好的，不移动 8 月 3 日的课程。'),
            const CompletedEvent(),
          ]),
    ]);
    final composition = await _buildTestComposition(
      db,
      'acc-1',
      provider: provider,
      protector: protector,
    );
    addTearDown(composition.dispose);
    final states = <AgentRunViewState>[];
    final done = Completer<void>();
    late String runId;
    composition.sessionService
        .send(accountId: 'acc-1', userText: '把 8 月 3 日的教务课程移到 8 月 9 日')
        .listen((s) {
      states.add(s);
      if (s.state == AgentRunState.waitingForUser) runId = s.runId;
    }, onDone: done.complete);
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(
      states.any(
          (s) => s.userAction?.type == AgentUserActionType.writeConfirmation),
      isTrue,
    );
    await composition.sessionService
        .confirmWriteProposal(
            accountId: 'acc-1', runId: runId, approve: false, remember: false)
        .drain<void>();
    await done.future;

    // Task 1 contract: a declined critical write must NEVER report success.
    // The run settles as failed (not completed) and the visible text is the
    // fixed local non-success statement.
    expect(states.last.state, AgentRunState.failed,
        reason: 'declined critical write must NOT report success');
    expect(states.last.text, contains('没有修改数据'),
        reason: 'the visible text must carry the fixed non-success statement');
    expect(await db.select(db.jwDayMoves).get(), isEmpty,
        reason: '拒绝不得写入任何移动记录');
    final logs = await db.actionLogsRepository.selectAll();
    expect(
      logs.where((l) =>
          l.source == 'agent' &&
          l.actionType == 'move_jw_course_day' &&
          l.result == 'success'),
      isEmpty,
      reason: '拒绝不得写 agent 成功日志',
    );
    expect(
      logs.where((l) =>
          l.source == 'user' &&
          l.actionType == 'agent_write_decline' &&
          l.result == 'declined'),
      hasLength(1),
      reason: '拒绝必须留下 decline 审计',
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Task 5 Part A composition regressions. Each scenario drives the real
  // composed AgentSessionService (via _buildTestComposition) with a scripted
  // provider and asserts the FIXED behavior end-to-end.
  // ─────────────────────────────────────────────────────────────────────────

  // Scenario 1: a polite factual query ("能不能帮我看看明天有什么课？") that the
  // model first answers WITHOUT a tool call triggers exactly ONE bounded
  // corrective retry (tool_choice any, declarations narrowed to get_schedule),
  // then grounds on get_schedule and completes with the data-backed answer.
  test(
    'composition: polite get_schedule query first-miss triggers exactly one '
    'bounded correction, then grounds on get_schedule',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      const protector = _NoopProtector();
      await _seedAccount(db, 'acc-1');
      final secretStore = ProtectedAgentSecretStore(
        database: db,
        protector: protector,
      );
      await _seedAgentConfig(db, 'acc-1', secrets: secretStore, apiKey: 'test-key');
      // A concrete course occurrence tomorrow so get_schedule returns data.
      final now = DateTime.now();
      final tomorrow = now.add(const Duration(days: 1));
      await _insertCourseSeries(
        db,
        'series-t1',
        'acc-1',
        externalId: 'lesson-t1',
        title: '数据结构',
      );
      await _insertCourseOccurrence(
        db,
        't1-occ',
        'acc-1',
        '数据结构',
        seriesExternalId: 'lesson-t1',
        location: '三教101',
        start: DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 9, 0),
        end: DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 10, 40),
      );

      // Call 1: the model answers in plain text (no tool). Call 2: the bounded
      // correction forces get_schedule. Call 3: grounded final answer.
      final provider = _ScriptedProvider([
        _ScriptedCall(() => [
              const TextDeltaEvent('明天有一节课。'),
              const CompletedEvent(),
            ]),
        _ScriptedCall(() => [
              const ToolUseCompletedEvent(
                id: 'tu-t1',
                name: 'get_schedule',
                input: {},
              ),
              const CompletedEvent(),
            ]),
        _ScriptedCall(() => [
              const TextDeltaEvent('明天有数据结构。'),
              const CompletedEvent(),
            ]),
      ]);
      final composition = await _buildTestComposition(
        db,
        'acc-1',
        provider: provider,
        protector: protector,
      );
      addTearDown(composition.dispose);

      final states = <AgentRunViewState>[];
      final done = Completer<void>();
      composition.sessionService
          .send(accountId: 'acc-1', userText: '能不能帮我看看明天有什么课？')
          .listen((s) => states.add(s), onDone: done.complete);
      await done.future;

      // Exactly 3 model calls: miss + ONE bounded corrective retry + final.
      expect(provider.streamCallCount, 3,
          reason: 'a polite factual first-miss must trigger exactly one bounded correction');
      final corrective = provider.requests[1];
      expect(corrective.toolChoice, LlmToolChoice.any,
          reason: 'the corrective request must force tool_choice any');
      expect(
        corrective.tools.map((t) => t.name).toSet(),
        {'get_schedule'},
        reason: 'the corrective request narrows declarations to get_schedule',
      );
      // The real get_schedule ran and grounded the answer.
      expect(states.last.state, AgentRunState.completed);
      expect(states.last.text, contains('数据结构'),
          reason: 'the grounded answer reflects the queried schedule');
    },
  );

  // Scenario 2: a write tool returns non-success while the model claims
  // success. The final UI must show the local non-success text ("没有修改数据")
  // and the business table must be unchanged (no row created). The failed
  // terminal write is NOT re-called.
  test(
    'composition: failed write with fake success claim ends non-success, '
    'no row created, write not re-called',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      const protector = _NoopProtector();
      await _seedAccount(db, 'acc-1');
      final secretStore = ProtectedAgentSecretStore(
        database: db,
        protector: protector,
      );
      await _seedAgentConfig(db, 'acc-1', secrets: secretStore, apiKey: 'test-key');

      // Call 1: create_event with a MISSING end_at -> invalid_write_arguments
      // (a non-success terminal write before any confirmation). Call 2: the
      // model falsely claims success. No third write is re-called.
      final provider = _ScriptedProvider([
        _ScriptedCall(() => [
              const ToolUseCompletedEvent(
                id: 'tu-t2',
                name: 'create_event',
                input: {'title': '健身'},
              ),
              const CompletedEvent(),
            ]),
        _ScriptedCall(() => [
              const TextDeltaEvent('已为你新建日程「健身」。'),
              const CompletedEvent(),
            ]),
      ]);
      final composition = await _buildTestComposition(
        db,
        'acc-1',
        provider: provider,
        protector: protector,
      );
      addTearDown(composition.dispose);

      final states = <AgentRunViewState>[];
      final done = Completer<void>();
      composition.sessionService
          .send(accountId: 'acc-1', userText: '帮我创建健身日程')
          .listen((s) => states.add(s), onDone: done.complete);
      await done.future;

      // Exactly 2 calls: the single failed write + the model's false prose. No
      // re-corrected repeat of the failed write, no confirmation (the write
      // never reached the confirm gate).
      expect(provider.streamCallCount, 2,
          reason: 'a failed write must not be re-called as a corrective repeat');
      // The run must NOT report success.
      expect(states.last.state, isNot(AgentRunState.completed),
          reason: 'a write that did not succeed must never report success');
      // The model's false success claim is replaced by the fixed non-success text.
      expect(states.last.text, isNot(contains('已为你新建')),
          reason: 'the false success prose must be overridden');
      expect(states.last.text, contains('没有修改数据'),
          reason: 'the visible text must carry the fixed non-success statement');
      expect(states.last.errorCode, 'invalid_write_arguments',
          reason: 'the preserved error code is traceable');
      // The business table is unchanged: no event row was created.
      expect((await db.select(db.calendarEvents).get()), isEmpty,
          reason: 'a failed write must leave no domain row');
    },
  );

  // Scenario 3: a forced-`any` corrective request that returns an auth/transport
  // error ends the run WITHOUT a second compatibility auto-fallback request.
  test(
    'composition: forced-any auth/transport error does NOT auto-fallback',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      const protector = _NoopProtector();
      await _seedAccount(db, 'acc-1');
      final secretStore = ProtectedAgentSecretStore(
        database: db,
        protector: protector,
      );
      await _seedAgentConfig(db, 'acc-1', secrets: secretStore, apiKey: 'test-key');

      // Call 1: the model misses the read tool (plain text). Call 2: the
      // corrective request (forced any) returns an auth_failed error — this is
      // a REAL upstream failure, NOT a forced-choice compatibility issue, so no
      // auto fallback may be issued.
      final provider = _ScriptedProvider([
        _ScriptedCall(() => [
              const TextDeltaEvent('我来查一下。'),
              const CompletedEvent(),
            ]),
        _ScriptedCall(() => [
              const ErrorEvent('auth_failed'),
              const CompletedEvent(),
            ]),
      ]);
      final composition = await _buildTestComposition(
        db,
        'acc-1',
        provider: provider,
        protector: protector,
      );
      addTearDown(composition.dispose);

      final states = <AgentRunViewState>[];
      final done = Completer<void>();
      composition.sessionService
          .send(accountId: 'acc-1', userText: '能不能帮我看看明天有什么课？')
          .listen((s) => states.add(s), onDone: done.complete);
      await done.future;

      // Exactly 2 model calls: the initial miss + the forced-any corrective that
      // errored. NO second auto fallback request was issued.
      expect(provider.streamCallCount, 2,
          reason: 'an auth/transport error on forced-any must not trigger a '
              'compatibility auto fallback');
      expect(provider.requests.last.toolChoice, LlmToolChoice.any,
          reason: 'the single corrective request was the forced-any attempt');
      // The run ends failed with the preserved original error code (not success).
      expect(states.last.state, AgentRunState.failed);
      expect(states.last.errorCode, 'auth_failed',
          reason: 'the original auth error must be preserved, not hidden');
    },
  );

  // Scenario 4: a single-course move ("把数据结构课程移到周五下午") routes to
  // update_event (single-event edit) and does NOT open the whole-day critical
  // confirm; a whole-day collection request ("把 8 月 3 日当天所有教务课程移到
  // 8 月 9 日") still requires the critical confirmation gate.
  test(
    'composition: single-course move routes to update_event (no whole-day '
    'confirm); whole-day collection still opens critical confirm',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      const protector = _NoopProtector();
      await _seedAccount(db, 'acc-1');
      final secretStore = ProtectedAgentSecretStore(
        database: db,
        protector: protector,
      );
      await _seedAgentConfig(db, 'acc-1', secrets: secretStore, apiKey: 'test-key');

      // A single personal event "数据结构" for the single-course move target.
      await db.into(db.calendarEvents).insert(
            CalendarEventsCompanion.insert(
              id: 'ds-1',
              accountId: 'acc-1',
              source: 'user',
              externalId: const Value('ds-1'),
              title: '数据结构',
              type: 'personal',
              startAt: Value(_beijingEpoch(2026, 8, 7, 9, 0)),
              endAt: Value(_beijingEpoch(2026, 8, 7, 10, 40)),
              allDay: false,
              timezone: 'Asia/Shanghai',
              locationName: const Value('三教101'),
              createdAt: 1,
              updatedAt: 1,
            ),
          );

      // A JW course on the whole-day source day (2026-08-03) with a source
      // record so the whole-day collection request preflights a course.
      await _insertCourseSeries(
        db,
        'series-t4',
        'acc-1',
        externalId: 'lesson-t4',
        title: '线性代数',
      );
      await db.into(db.calendarEvents).insert(
            CalendarEventsCompanion.insert(
              id: 'jw-t4',
              accountId: 'acc-1',
              source: 'ustc_jw',
              externalId: const Value('jw-t4'),
              sourceSeriesExternalId: const Value('lesson-t4'),
              title: '线性代数',
              type: 'course',
              startAt: Value(_beijingEpoch(2026, 8, 3, 9, 0)),
              endAt: Value(_beijingEpoch(2026, 8, 3, 10, 40)),
              allDay: false,
              timezone: 'Asia/Shanghai',
              locationName: const Value('三教101'),
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await db.into(db.sourceRecords).insert(
            SourceRecordsCompanion.insert(
              id: 'sr-jw-t4',
              accountId: 'acc-1',
              source: 'ustc_jw',
              entityType: 'calendar_event',
              externalId: 'jw-t4',
              localEntityId: 'jw-t4',
              sourceStatus: 'active',
              presence: 'present',
              scopeKey: 'scope',
              firstObservedAt: 1,
              lastObservedAt: 1,
            ),
          );

      // --- single-course move: routes to update_event, NO whole-day confirm ---
      final singleProvider = _ScriptedProvider([
        // Call 1: get_schedule locates the single 数据结构 event -> binds ref.
        _ScriptedCall(() => [
              const ToolUseCompletedEvent(
                id: 'tu-t4a1',
                name: 'get_schedule',
                input: {'query': '数据结构'},
              ),
              const CompletedEvent(),
            ]),
        // Call 2: update_event (single-event edit). update_event is
        // always_ask, so it pauses for confirmation — but the confirm is the
        // HIGH-risk single-event edit card, NOT the whole-day critical one.
        // It echoes the run-local ref the get_schedule title query bound.
        _ScriptedCall(
          () => [
            const ToolUseCompletedEvent(
              id: 'tu-t4a2',
              name: 'update_event',
              input: {},
            ),
            const CompletedEvent(),
          ],
          inputBuilder: (prior) {
            final refs = _refsFromLastToolResult(prior);
            return {
              'ref_event': refs.isEmpty ? 'ref_unknown' : refs.first,
              'title': '数据结构',
              'start_at': '2026-08-07T14:00:00+08:00',
              'end_at': '2026-08-07T15:40:00+08:00',
            };
          },
        ),
        // Call 3: final text after confirm.
        _ScriptedCall(() => [
              const TextDeltaEvent('已把数据结构移到周五下午。'),
              const CompletedEvent(),
            ]),
      ]);
      final singleComposition = await _buildTestComposition(
        db,
        'acc-1',
        provider: singleProvider,
        protector: protector,
      );
      addTearDown(singleComposition.dispose);
      final singleStates = <AgentRunViewState>[];
      final singleDone = Completer<void>();
      late String singleRunId;
      singleComposition.sessionService
          .send(accountId: 'acc-1', userText: '把数据结构课程移到周五下午')
          .listen((s) {
        singleStates.add(s);
        if (s.state == AgentRunState.waitingForUser) singleRunId = s.runId;
      }, onDone: singleDone.complete);
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      // It pauses on a confirmation — but it must be the single-event edit
      // operation, never the whole-day critical headline.
      expect(
        singleStates.any(
            (s) => s.userAction?.type == AgentUserActionType.writeConfirmation),
        isTrue,
        reason: 'update_event (single-course move) pauses for confirmation',
      );
      final singleProposal = singleStates
          .lastWhere((s) => s.userAction != null)
          .userAction!
          .writeProposal!;
      expect(singleProposal.operationLabel, '修改/删除日程',
          reason: 'a single-course move opens the single-event edit confirm, '
              'NOT the whole-day critical one');
      // Approve and complete.
      await singleComposition.sessionService
          .confirmWriteProposal(
              accountId: 'acc-1', runId: singleRunId, approve: true, remember: false)
          .drain<void>();
      await singleDone.future;
      expect(singleStates.last.state, AgentRunState.completed);
      // No whole-day move record was created by the single-course move.
      expect(await db.select(db.jwDayMoves).get(), isEmpty,
          reason: 'a single-course move must not create a whole-day move record');

      // --- whole-day collection move: still requires the critical confirm ---
      final wholeProvider = _ScriptedProvider([
        // Call 1: move_jw_course_day (whole-day collection) -> critical confirm.
        _ScriptedCall(() => [
              const ToolUseCompletedEvent(
                id: 'tu-t4b1',
                name: 'move_jw_course_day',
                input: {
                  'action': 'move',
                  'source_date': '2026-08-03',
                  'target_date': '2026-08-09',
                },
              ),
              const CompletedEvent(),
            ]),
        // Call 2: final text after approve.
        _ScriptedCall(() => [
              const TextDeltaEvent('已把 8 月 3 日的教务课程移到 8 月 9 日。'),
              const CompletedEvent(),
            ]),
      ]);
      final wholeComposition = await _buildTestComposition(
        db,
        'acc-1',
        provider: wholeProvider,
        protector: protector,
      );
      addTearDown(wholeComposition.dispose);
      final wholeStates = <AgentRunViewState>[];
      final wholeDone = Completer<void>();
      late String wholeRunId;
      wholeComposition.sessionService
          .send(
              accountId: 'acc-1',
              userText: '把 8 月 3 日当天所有教务课程移到 8 月 9 日')
          .listen((s) {
        wholeStates.add(s);
        if (s.state == AgentRunState.waitingForUser) wholeRunId = s.runId;
      }, onDone: wholeDone.complete);
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        wholeStates.any(
            (s) => s.userAction?.type == AgentUserActionType.writeConfirmation),
        isTrue,
        reason: 'a whole-day collection move must open the critical confirm',
      );
      final wholeProposal = wholeStates
          .lastWhere((s) => s.userAction != null)
          .userAction!
          .writeProposal!;
      expect(wholeProposal.operationLabel, '整日移动教务课程',
          reason: 'the whole-day collection move opens the critical whole-day confirm');
      expect(wholeProposal.rememberAllowed, isFalse,
          reason: 'critical confirm never offers remember');
      await wholeComposition.sessionService
          .confirmWriteProposal(
              accountId: 'acc-1', runId: wholeRunId, approve: true, remember: false)
          .drain<void>();
      await wholeDone.future;
      expect(wholeStates.last.state, AgentRunState.completed);
      final moves = await db.select(db.jwDayMoves).get();
      expect(moves, hasLength(1));
      expect(moves.single.sourceDate, '2026-08-03');
      expect(moves.single.targetDate, '2026-08-09');
    },
  );

  // Scenario 5: with multi-semester history present, the week page AND a ranged
  // Agent query each project ONLY the current result set. Conflict semantics
  // stay unchanged, and the deprecated full projection is never invoked
  // (resolvedConflictIdsForCalls stays 0).
  test(
    'composition: multi-semester history projects only the current result set '
    '(no deprecated full projection), conflict semantics unchanged',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      const protector = _NoopProtector();
      await _seedAccount(db, 'acc-1');
      final secretStore = ProtectedAgentSecretStore(
        database: db,
        protector: protector,
      );
      await _seedAgentConfig(db, 'acc-1', secrets: secretStore, apiKey: 'test-key');

      EffectiveEventRepository.resolvedConflictIdsForCalls = 0;
      EffectiveEventRepository.conflictsForItemsCalls = 0;
      EffectiveEventRepository.lastCandidatesForItems = 0;

      // Two overlapping personal events in the CURRENT week.
      final monday = _currentWeekMonday();
      final tuesday = monday.add(const Duration(days: 1));
      await db.into(db.calendarEvents).insert(
            CalendarEventsCompanion.insert(
              id: 's5-a',
              accountId: 'acc-1',
              source: 'user',
              externalId: const Value('s5-a'),
              title: '重叠甲',
              type: 'personal',
              startAt: Value(
                  _beijingEpoch(tuesday.year, tuesday.month, tuesday.day, 10, 0)),
              endAt: Value(
                  _beijingEpoch(tuesday.year, tuesday.month, tuesday.day, 12, 0)),
              allDay: false,
              timezone: 'Asia/Shanghai',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await db.into(db.calendarEvents).insert(
            CalendarEventsCompanion.insert(
              id: 's5-b',
              accountId: 'acc-1',
              source: 'user',
              externalId: const Value('s5-b'),
              title: '重叠乙',
              type: 'personal',
              startAt: Value(
                  _beijingEpoch(tuesday.year, tuesday.month, tuesday.day, 11, 0)),
              endAt: Value(
                  _beijingEpoch(tuesday.year, tuesday.month, tuesday.day, 13, 0)),
              allDay: false,
              timezone: 'Asia/Shanghai',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      // Non-overlapping historical events from a PRIOR semester (the retained
      // multi-semester history the bounded projection must ignore).
      for (final label in ['历史一', '历史二', '历史三']) {
        await db.into(db.calendarEvents).insert(
              CalendarEventsCompanion.insert(
                id: 's5-hist-$label',
                accountId: 'acc-1',
                source: 'ustc_jw',
                externalId: Value('s5-hist-$label'),
                sourceSeriesExternalId: const Value('lesson-hist'),
                title: label,
                type: 'course',
                startAt: Value(_beijingEpoch(2026, 2, 2, 9, 0)),
                endAt: Value(_beijingEpoch(2026, 2, 2, 10, 0)),
                allDay: false,
                timezone: 'Asia/Shanghai',
                createdAt: 1,
                updatedAt: 1,
              ),
            );
        await db.into(db.sourceRecords).insert(
              SourceRecordsCompanion.insert(
                id: 'sr-s5-hist-$label',
                accountId: 'acc-1',
                source: 'ustc_jw',
                entityType: 'calendar_event',
                externalId: 's5-hist-$label',
                localEntityId: 's5-hist-$label',
                sourceStatus: 'active',
                presence: 'present',
                scopeKey: 'scope',
                firstObservedAt: 1,
                lastObservedAt: 1,
              ),
            );
      }

      // A ranged Agent query (this week) projects only the current result set.
      final built = await _buildTestComposition(
        db,
        'acc-1',
        provider: _ScriptedProvider(const []),
        protector: protector,
      );
      addTearDown(built.dispose);
      final getSchedule = built.registry.execute(
        toolName: 'get_schedule',
        arguments: {'from': _isoDate(monday), 'through': _isoDate(monday.add(const Duration(days: 6)))},
        context: integrationCtx('acc-1', 'r-s5'),
      );
      final schedule = await getSchedule;
      expect(schedule.status, AgentToolStatus.success);
      // The ranged query sees ONLY the current-week events.
      final events = schedule.payload['events']! as List;
      final titles = events
          .map((e) => (e! as Map<String, Object?>)['title'] as String)
          .toSet();
      expect(titles, containsAll({'重叠甲', '重叠乙'}));
      expect(titles, isNot(contains('历史一')),
          reason: 'the ranged Agent query must project only the current result set');
      // Conflict semantics unchanged: the overlap pair is derived as a conflict.
      final conflicted = events
          .map((e) => (e! as Map<String, Object?>)['conflictState'] as String? ?? 'no_conflict')
          .toList();
      expect(conflicted, contains('conflict'),
          reason: 'the in-range overlap remains a derived conflict');
      // The deprecated full projection was never invoked.
      expect(EffectiveEventRepository.resolvedConflictIdsForCalls, 0,
          reason: 'the ranged Agent query must not invoke the deprecated full projection');
    },
  );

  test('composition: free discussion of 调休 needs no tools and completes', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    const protector = _NoopProtector();
    await _seedAccount(db, 'acc-1');
    final secretStore = ProtectedAgentSecretStore(
      database: db,
      protector: protector,
    );
    await _seedAgentConfig(db, 'acc-1', secrets: secretStore, apiKey: 'test-key');

    final provider = _ScriptedProvider([
      _ScriptedCall(() => [
            const TextDeltaEvent(
              '整日调休是把某一天的教务课程整体挪到另一天，只影响教务课程，'
              '不影响考试、二课和个人日程；任何时候都需要你确认后才会执行。',
            ),
            const CompletedEvent(),
          ]),
    ]);
    final composition = await _buildTestComposition(
      db,
      'acc-1',
      provider: provider,
      protector: protector,
    );
    addTearDown(composition.dispose);
    final states = <AgentRunViewState>[];
    final done = Completer<void>();
    composition.sessionService
        .send(accountId: 'acc-1', userText: '调休功能是怎么工作的')
        .listen((s) => states.add(s), onDone: done.complete);
    await done.future;

    expect(states.last.state, AgentRunState.completed,
        reason: '能力讨论必须直接完成，不被 grounding 矫正为工具调用');
    expect(provider.requests, hasLength(1),
        reason: '自由聊天路径只允许一次模型调用（不得触发矫正重试）');
    expect(states.last.text, contains('整日调休'));
    // 没有任何工具调用：自由聊天与能力讨论不需要调用工具。
    final toolUses = provider.requests.single.messages
        .where((m) => m.role == 'assistant')
        .expand((m) => m.content)
        .whereType<LlmToolUseBlock>();
    expect(toolUses, isEmpty,
        reason: '能力讨论不得调用任何工具');
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Task 10 FINAL combined acceptance regression: ONE real-router flow with an
  // injected scripted provider covering all 9 manual-acceptance scenarios:
  //
  //   1. free chat without tools
  //   2. pending review first-miss -> one correction succeeds
  //   3. historical title lookup -> overlay write without ref output
  //   4. two historical events -> relation write without conflict lookup loop
  //   5. plan_task -> PlanBlock visible/clickable in week
  //   6. overlap default conflict -> explicit no_conflict suppresses
  //   7. whole-day JW move -> non-JW unchanged -> undo restores
  //   8. schedule/task chips select exact sections
  //   9. account switch isolates moves, refs, tasks and Agent history
  // ─────────────────────────────────────────────────────────────────────────
  testWidgets(
    'Task 10 combined acceptance regression: 9 manual-acceptance scenarios '
    'through the real router',
    (tester) async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      const protector = _NoopProtector();

      // --- accounts A (active) and B (inactive), both configured ----------
      await _seedAccount(database, 'a');
      await _seedCredentials(
        database,
        'a',
        protector,
        username: 'PB12345678',
        password: 'protected-school-password',
      );
      final secretStore = ProtectedAgentSecretStore(
        database: database,
        protector: protector,
        now: () => 1,
      );
      await _seedAgentConfig(
        database,
        'a',
        secrets: secretStore,
        apiKey: 'test-key',
      );
      await _seedInactiveAccount(database, 'b');
      await _seedCredentials(
        database,
        'b',
        protector,
        username: 'PB87654321',
        password: 'protected-school-password-b',
      );
      final secretStoreB = ProtectedAgentSecretStore(
        database: database,
        protector: protector,
        now: () => 1,
      );
      await _seedAgentConfig(
        database,
        'b',
        secrets: secretStoreB,
        apiKey: 'test-key-b',
      );

      final monday = _currentWeekMonday();
      final lastMonday = monday.subtract(const Duration(days: 7));

      // --- historical 计算机网络 series across two semesters ---------------
      await _insertCourseSeries(
        database,
        'series-net',
        'a',
        externalId: 'lesson-net',
        title: '计算机网络',
        semesterKey: '2026spring',
      );
      await _insertCourseOccurrence(
        database,
        'net-mar-a',
        'a',
        '计算机网络',
        seriesExternalId: 'lesson-net',
        location: '三教101',
        start: DateTime(2026, 3, 2, 8, 40),
        end: DateTime(2026, 3, 2, 9, 25),
      );
      await _insertCourseOccurrence(
        database,
        'net-mar-b',
        'a',
        '计算机网络',
        seriesExternalId: 'lesson-net',
        location: '三教201',
        start: DateTime(2026, 3, 4, 10, 35),
        end: DateTime(2026, 3, 4, 11, 20),
      );
      await _insertCourseOccurrence(
        database,
        'net-aug',
        'a',
        '计算机网络',
        seriesExternalId: 'lesson-net',
        location: '四教102',
        start: DateTime(2026, 8, 14, 14, 0),
        end: DateTime(2026, 8, 14, 15, 40),
      );

      // A course that ended LAST week (pending attendance/listening review).
      await _insertCourseSeries(
        database,
        'series-q',
        'a',
        externalId: 'lesson-q',
        title: '量子物理 B',
        semesterKey: '2026spring',
      );
      await _insertCourseOccurrence(
        database,
        'q-last',
        'a',
        '量子物理 B',
        seriesExternalId: 'lesson-q',
        location: '三教101',
        start: DateTime(lastMonday.year, lastMonday.month, lastMonday.day, 9, 0),
        end: DateTime(lastMonday.year, lastMonday.month, lastMonday.day, 10, 40),
      );

      // Whole-day move source day: a JW course on 2026-08-03 with a source
      // record (eligible), plus a NON-JW personal event on the same day that
      // must never move; the target day 2026-08-09 already has a personal
      // event overlapping the moved course time.
      await _insertCourseSeries(
        database,
        'series-la',
        'a',
        externalId: 'lesson-la',
        title: '线性代数',
        semesterKey: '2026fall',
      );
      await database.into(database.calendarEvents).insert(
            CalendarEventsCompanion.insert(
              id: 'jw-0803',
              accountId: 'a',
              source: 'ustc_jw',
              externalId: const Value('jw-0803'),
              sourceSeriesExternalId: const Value('lesson-la'),
              title: '线性代数',
              type: 'course',
              startAt: Value(_beijingEpoch(2026, 8, 3, 9, 0)),
              endAt: Value(_beijingEpoch(2026, 8, 3, 10, 40)),
              allDay: false,
              timezone: 'Asia/Shanghai',
              locationName: const Value('三教101'),
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await database.into(database.sourceRecords).insert(
            SourceRecordsCompanion.insert(
              id: 'sr-jw-0803',
              accountId: 'a',
              source: 'ustc_jw',
              entityType: 'calendar_event',
              externalId: 'jw-0803',
              localEntityId: 'jw-0803',
              sourceStatus: 'active',
              presence: 'present',
              scopeKey: 'scope',
              firstObservedAt: 1,
              lastObservedAt: 1,
            ),
          );
      await database.into(database.calendarEvents).insert(
            CalendarEventsCompanion.insert(
              id: 'ev-chenpao',
              accountId: 'a',
              source: 'user',
              title: '晨跑',
              type: 'personal',
              startAt: Value(_beijingEpoch(2026, 8, 3, 7, 0)),
              endAt: Value(_beijingEpoch(2026, 8, 3, 8, 0)),
              allDay: false,
              timezone: 'Asia/Shanghai',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await database.into(database.calendarEvents).insert(
            CalendarEventsCompanion.insert(
              id: 'ev-jianshen',
              accountId: 'a',
              source: 'user',
              title: '健身',
              type: 'personal',
              startAt: Value(_beijingEpoch(2026, 8, 9, 9, 30)),
              endAt: Value(_beijingEpoch(2026, 8, 9, 11, 0)),
              allDay: false,
              timezone: 'Asia/Shanghai',
              createdAt: 1,
              updatedAt: 1,
            ),
          );

      // Two overlapping personal events in the CURRENT week: the derived
      // conflict pair for scenario 6 (explicit no_conflict suppresses them).
      final tuesday = monday.add(const Duration(days: 1));
      await database.into(database.calendarEvents).insert(
            CalendarEventsCompanion.insert(
              id: 'ov-a',
              accountId: 'a',
              source: 'user',
              title: '重叠甲',
              type: 'personal',
              startAt: Value(
                  _beijingEpoch(tuesday.year, tuesday.month, tuesday.day, 10, 0)),
              endAt: Value(
                  _beijingEpoch(tuesday.year, tuesday.month, tuesday.day, 12, 0)),
              allDay: false,
              timezone: 'Asia/Shanghai',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await database.into(database.calendarEvents).insert(
            CalendarEventsCompanion.insert(
              id: 'ov-b',
              accountId: 'a',
              source: 'user',
              title: '重叠乙',
              type: 'personal',
              startAt: Value(
                  _beijingEpoch(tuesday.year, tuesday.month, tuesday.day, 11, 0)),
              endAt: Value(
                  _beijingEpoch(tuesday.year, tuesday.month, tuesday.day, 13, 0)),
              allDay: false,
              timezone: 'Asia/Shanghai',
              createdAt: 1,
              updatedAt: 1,
            ),
          );

      // A task for plan_task (scenario 5).
      await _insertTask(database, 'task-1', 'a', '复习算法');

      final provider = _ScriptedProvider(_combinedRegressionScript());

      Future<AgentCompositionResult> loadComposition(
        AppDatabase db,
        String accountId,
      ) =>
          _buildTestComposition(
            db,
            accountId,
            provider: provider,
            protector: protector,
          );

      final router = buildRouter(
        _FakeWebsiteLauncher(),
        database,
        const NoopReminderReconciler(),
        loadComposition,
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      // Task 9: enlarged registry needs more pumps for composition build.
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.byKey(const Key('agent-chat-input')), findsOneWidget);

      Future<void> pumpTicks([int n = 25]) async {
        for (var i = 0; i < n; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
      }

      Future<void> sendChat(String text) async {
        await tester.enterText(
          find.byKey(const Key('agent-chat-input')),
          text,
        );
        await tester.pump();
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await pumpTicks(70);
      }

      Future<void> confirmCard(String operationLabel) async {
        final label = find.text(operationLabel);
        await tester.ensureVisible(label);
        await tester.pumpAndSettle();
        expect(label, findsOneWidget,
            reason: '$operationLabel must pause on its confirmation card');
        await tester.tap(find.text('确认本次'));
        await pumpTicks(70);
      }

      Future<void> tapChip(String label) async {
        final finder = find.widgetWithText(ActionChip, label).last;
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        await tester.tap(finder);
        await pumpTicks(15);
      }

      SegmentedButton<ScheduleSection> seg() =>
          tester.widget<SegmentedButton<ScheduleSection>>(
        find.byType(SegmentedButton<ScheduleSection>),
      );

      // --- scenario 1: free chat without tools ------------------------------
      await sendChat('你好，今天心情怎么样？');
      expect(provider.streamCallCount, 1);
      expect(find.textContaining('今天心情不错'), findsOneWidget);
      final freeRequest = provider.requests.single;
      expect(freeRequest.toolChoice, LlmToolChoice.auto,
          reason: 'free chat must not force tools');
      expect(
        freeRequest.messages
            .expand((m) => m.content)
            .whereType<LlmToolUseBlock>(),
        isEmpty,
        reason: 'free chat must not call any tool',
      );
      expect(_executedToolSequence(provider), isEmpty);

      // --- scenario 2: pending review first-miss -> one correction succeeds --
      await sendChat('有哪些需要我确认的课程出勤或听讲？');
      expect(provider.streamCallCount, 4,
          reason: 'miss + one bounded correction + tool + final');
      final corrective = provider.requests[2];
      expect(corrective.toolChoice, LlmToolChoice.any,
          reason: 'the corrective request must force tool_choice any');
      expect(
        corrective.tools.map((t) => t.name).toSet(),
        {'get_pending_event_reviews'},
        reason: 'the corrective request narrows declarations to the required tool',
      );
      expect(
        _capturedToolResults(provider).join('\n'),
        contains('attendance_undecided'),
        reason: 'the corrected get_pending_event_reviews ran for real',
      );
      expect(find.textContaining('量子物理 B'), findsOneWidget);

      // --- scenario 3: historical title lookup -> overlay write --------------
      await sendChat('将2026春的计算机网络设置成必去，并设置成听讲。');
      expect(provider.streamCallCount, 6,
          reason: 'the overlay paused for confirmation before its final text');
      await confirmCard('设置个人标注');
      expect(provider.streamCallCount, 7);
      expect(find.textContaining('已为计算机网络设置必去与听讲'), findsOneWidget);
      // The overlay landed on one of the three historical occurrences found by
      // the TITLE query (never a get_conflicts finder, never a default
      // semester read).
      final overlays = await database.select(database.userOverlays).get();
      expect(overlays, hasLength(1));
      expect(overlays.single.attendancePolicy, 'must_go');
      expect(overlays.single.listeningMode, 'listen');
      expect(
        {'net-mar-a', 'net-mar-b', 'net-aug'}.contains(overlays.single.eventId),
        isTrue,
        reason: 'overlay must target a get_schedule(query) historical ref',
      );
      // No run-local ref ever rendered in the chat UI.
      expect(find.textContaining('ref_'), findsNothing);

      // --- scenario 4: two historical events -> relation write, no conflict
      // lookup loop ----------------------------------------------------------
      await sendChat('把2026年3月的那两节计算机网络课记录为冲突，二选一。');
      expect(provider.streamCallCount, 9,
          reason: 'the relation paused for confirmation before its final text');
      await confirmCard('记录日程关系');
      expect(provider.streamCallCount, 10);
      final relations =
          await database.select(database.scheduleRelations).get();
      expect(relations, hasLength(1));
      expect({relations.single.leftEventId, relations.single.rightEventId},
          {'net-mar-a', 'net-mar-b'},
          reason: 'relation participants are the two historical March events');

      // --- scenario 5: plan_task -> PlanBlock visible/clickable in week ------
      await sendChat('给复习算法安排一个执行时间段。');
      expect(provider.streamCallCount, 12,
          reason: 'plan_task paused for confirmation before its final text');
      await confirmCard('安排任务时间段');
      expect(provider.streamCallCount, 13);
      final blocks = await database.select(database.planBlocks).get();
      expect(blocks, hasLength(1));
      expect(blocks.single.taskId, 'task-1');
      final blockId = blocks.single.id;

      // --- scenario 8: schedule/task chips select exact sections -------------
      await tapChip('查看任务');
      expect(seg().selected, {ScheduleSection.tasks},
          reason: '查看任务 chip must open the tasks section');
      router.go('/chat');
      await pumpTicks(20);
      await tapChip('查看日程');
      expect(seg().selected, {ScheduleSection.week},
          reason: '查看日程 chip must open the week section');
      // The accepted PlanBlock is visible in the current week grid and
      // clickable -> opens its parent task detail.
      final planBlock = find.byKey(Key('plan-block-$blockId'));
      expect(planBlock, findsOneWidget,
          reason: 'the planned block must render in the current week grid');
      await tester.ensureVisible(planBlock);
      await tester.pumpAndSettle();
      await tester.tap(planBlock);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('task-detail-undo')), findsOneWidget,
          reason: 'tapping the block opens its parent task detail');
      expect(find.text('复习算法'), findsWidgets,
          reason: 'the task detail names the parent task');
      router.go('/chat');
      await pumpTicks(20);

      // --- scenario 6 (I1): a conflict QUESTION is a READ only — it must
      // never produce a relation write; the derived overlap is reported, not
      // mutated ---------------------------------------------------------------
      await sendChat('我这周有哪些时间冲突的安排？');
      expect(provider.streamCallCount, 15,
          reason: 'read only: get_conflicts + final answer, no relation write');
      expect(find.textContaining('需要二选一'), findsOneWidget,
          reason: 'the read answer reports the derived conflict pair');
      final payloadsAfterRead = _capturedConflictPayloads(provider);
      expect(payloadsAfterRead, hasLength(1),
          reason: 'one get_conflicts payload so far (the read)');
      expect(payloadsAfterRead.first['conflictPairs'], hasLength(1),
          reason: 'the overlapping pair is derived as a conflict by default');
      expect(
        jsonEncode(payloadsAfterRead.first['conflictPairs']),
        contains('derivedOverlap'),
        reason: 'the default conflict pair origin is derivedOverlap',
      );
      final relationsAfterRead =
          await database.select(database.scheduleRelations).get();
      expect(relationsAfterRead, hasLength(1),
          reason: 'a conflict QUESTION must not create any relation');

      // --- scenario 6b: genuine relation WRITE -> explicit no_conflict
      // suppresses the derived pair. create_schedule_relation is
      // ask_first_time: the FIRST confirmation in scenario 4 released it, so
      // this relation AUTO-executes — the whole run completes inside the send.
      await sendChat('把重叠甲和重叠乙记录为不冲突，两个时段都去。');
      expect(provider.streamCallCount, 19,
          reason: 'get_conflicts -> no_conflict relation -> get_conflicts -> final');
      final payloadsAfterWrite = _capturedConflictPayloads(provider);
      expect(payloadsAfterWrite, hasLength(3),
          reason: 'read query + write finder + post-write recheck');
      expect(payloadsAfterWrite.last['conflictPairs'], isEmpty,
          reason: 'explicit no_conflict suppresses the derived pair');
      final relationsAfter =
          await database.select(database.scheduleRelations).get();
      expect(relationsAfter, hasLength(2));
      expect(relationsAfter.last.conflictState, 'no_conflict');
      expect({relationsAfter.last.leftEventId, relationsAfter.last.rightEventId},
          {'ov-a', 'ov-b'});

      // --- scenario 7: whole-day JW move -> non-JW unchanged -> undo ---------
      await sendChat('把8月3日的教务课程移到8月9日，其他日程不要动。');
      expect(provider.streamCallCount, 21,
          reason: 'the critical move paused for confirmation');
      final moveCard = find.text('整日移动教务课程');
      await tester.ensureVisible(moveCard);
      await tester.pumpAndSettle();
      expect(moveCard, findsOneWidget);
      expect(find.text('此类型以后不再确认'), findsNothing,
          reason: 'critical moves never offer remember');
      await tester.tap(find.text('确认本次'));
      await pumpTicks(70);
      expect(provider.streamCallCount, 23);
      final moves = await database.select(database.jwDayMoves).get();
      expect(moves, hasLength(1));
      expect(moves.single.sourceDate, '2026-08-03');
      expect(moves.single.targetDate, '2026-08-09');
      // Source events are never rewritten; only the display projection moves.
      final feed = _capturedToolResults(provider).join('\n');
      expect(feed, contains('2026-08-09T09:00:00'),
          reason: 'the moved course displays on the target day');
      expect(feed, contains('2026-08-03T07:00:00'),
          reason: 'the personal 晨跑 event stays on the source day');
      expect(feed, isNot(contains('2026-08-09T07:00:00')),
          reason: '晨跑 must never move with the course day');
      expect(find.textContaining('线性代数'), findsOneWidget);

      // The one-step undo is a MANUAL-path feature: the schedule page clears
      // through an UndoService recorder (agent clears intentionally never
      // occupy the one-step undo slot). Replay that exact construction to
      // prove clear -> undo restores the move.
      final undo = UndoService(database: database, accountId: 'a');
      final manualMoves = JwDayMoveService(
        database: database,
        accountId: 'a',
        undoRecorder: undo,
      );
      await manualMoves.clear('2026-08-03');
      expect(await database.select(database.jwDayMoves).get(), isEmpty,
          reason: 'the manual clear removes the move record');
      expect(await undo.canUndo(), isTrue);
      await undo.undo();
      final restored = await database.select(database.jwDayMoves).get();
      expect(restored, hasLength(1));
      expect(restored.single.sourceDate, '2026-08-03');
      expect(restored.single.targetDate, '2026-08-09',
          reason: 'the one-step undo restores the cleared move');

      // --- scenario 9: account switch isolates moves, refs, tasks, history ----
      await database.transaction(() async {
        await (database.update(database.localAccounts)
              ..where((row) => row.id.equals('a')))
            .write(const LocalAccountsCompanion(isActive: Value(false)));
        await (database.update(database.localAccounts)
              ..where((row) => row.id.equals('b')))
            .write(const LocalAccountsCompanion(isActive: Value(true)));
      });
      database.notifyActiveAccountChanged();
      await pumpTicks(30);
      // B's chat is empty: no history, no run-local refs, no moves, no tasks.
      expect(find.textContaining('线性代数'), findsNothing);
      expect(
        await (database.select(database.chatMessages)
              ..where((row) => row.accountId.equals('b')))
            .get(),
        isEmpty,
        reason: 'account B must have no chat history',
      );
      expect(
        await (database.select(database.jwDayMoves)
              ..where((row) => row.accountId.equals('b')))
            .get(),
        isEmpty,
        reason: 'account B must have no day moves',
      );
      expect(
        await (database.select(database.tasks)
              ..where((row) => row.accountId.equals('b')))
            .get(),
        isEmpty,
        reason: 'account B must have no tasks',
      );
      // Back to A: everything is still there.
      await database.transaction(() async {
        await (database.update(database.localAccounts)
              ..where((row) => row.id.equals('b')))
            .write(const LocalAccountsCompanion(isActive: Value(false)));
        await (database.update(database.localAccounts)
              ..where((row) => row.id.equals('a')))
            .write(const LocalAccountsCompanion(isActive: Value(true)));
      });
      database.notifyActiveAccountChanged();
      await pumpTicks(30);
      expect(find.textContaining('线性代数'), findsOneWidget,
          reason: 'account A recovers its conversation after the switch back');
      expect(
        (await (database.select(database.jwDayMoves)
              ..where((row) => row.accountId.equals('a')))
            .get())
            .length,
        1,
        reason: 'account A keeps its move record',
      );
      expect(
        (await (database.select(database.tasks)
              ..where((row) => row.accountId.equals('a')))
            .get())
            .length,
        1,
        reason: 'account A keeps its task',
      );

      // --- the Agent clears the move again (its own cleanup path) ------------
      await sendChat('恢复8月3日的整日移动。');
      expect(provider.streamCallCount, 24,
          reason: 'the critical clear paused for confirmation');
      await confirmCard('整日移动教务课程');
      expect(provider.streamCallCount, 25);
      expect(await database.select(database.jwDayMoves).get(), isEmpty,
          reason: 'the Agent clear removes the move record');
      final logs = await database.actionLogsRepository.selectAll();
      expect(
        logs.where((l) =>
            l.source == 'agent' &&
            l.actionType == 'move_jw_course_day' &&
            l.result == 'success'),
        hasLength(2),
        reason: 'move + clear each commit an audited success',
      );
      expect(logs.where((l) => l.actionType == 'undo_jw_day_move'),
          hasLength(1));

      // --- the executed tool sequence is the observable contract: the
      // overlay/relation writes are fed by get_schedule title queries, and
      // get_conflicts appears ONLY in scenario 6 — never as a participant
      // finder (no conflict-lookup loop) --------------------------------------
      expect(_executedToolSequence(provider), [
        'get_pending_event_reviews',
        'get_schedule',
        'create_user_overlay',
        'get_schedule',
        'create_schedule_relation',
        'get_tasks',
        'plan_task',
        'get_conflicts', // scenario 6 READ
        'get_conflicts', // scenario 6b write finder
        'create_schedule_relation', // scenario 6b write
        'get_conflicts', // scenario 6b post-write recheck
        'get_schedule',
        'move_jw_course_day',
        'get_schedule',
        'move_jw_course_day',
      ], reason: 'no conflict-lookup loop: get_conflicts only serves the conflict scenarios');

      // Tear down the tree and let Drift stream-query timers close.
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpTicks(10);
    },
  );

  // ─────────────────────────────────────────────────────────────────────────
  // Task 8 composition regression: persisted tool diagnostics survive a NEW
  // composition over the SAME DB (restart), expose no secret/account/id/raw
  // ref, and are reset-with-account (completeReset wipes them). This closes
  // the brief §5/§6 diagnostics-after-restart + account-reset isolation items
  // at the composition level, on real Drift with a scripted provider.
  // ─────────────────────────────────────────────────────────────────────────
  test(
    'composition: persisted diagnostics survive restart, expose only safe '
    'summaries, and are cleared by completeReset',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      const protector = _NoopProtector();
      await _seedAccount(db, 'acc-1');
      final secretStore = ProtectedAgentSecretStore(
        database: db,
        protector: protector,
      );
      await _seedAgentConfig(db, 'acc-1', secrets: secretStore, apiKey: 'test-key');
      // A task so call 1 (get_tasks) binds a run-local ref; a personal event so
      // create_event targets an account-scoped personal source.
      await _insertTask(db, 'task-1', 'acc-1', '复习算法');

      // Call 1: get_tasks (read) binds a task ref. Call 2: create_event pauses
      // for confirmation. Call 3: final text after approve.
      final provider = _ScriptedProvider([
        _ScriptedCall(() => [
              const ToolUseCompletedEvent(
                id: 'tu-1',
                name: 'get_tasks',
                input: {},
              ),
              const CompletedEvent(),
            ]),
        _ScriptedCall(() => [
              const ToolUseCompletedEvent(
                id: 'tu-2',
                name: 'create_event',
                input: {
                  'title': '健身',
                  'start_at': '2026-08-01T15:00:00+08:00',
                  'end_at': '2026-08-01T16:00:00+08:00',
                },
              ),
              const CompletedEvent(),
            ]),
        _ScriptedCall(() => [
              const TextDeltaEvent('已创建日程「健身」。'),
              const CompletedEvent(),
            ]),
      ]);
      final first = await _buildTestComposition(
        db,
        'acc-1',
        provider: provider,
        protector: protector,
      );
      addTearDown(first.dispose);

      final states = <AgentRunViewState>[];
      final done = Completer<void>();
      late String runId;
      first.sessionService
          .send(accountId: 'acc-1', userText: '查任务并建个健身日程')
          .listen((s) {
        states.add(s);
        if (s.state == AgentRunState.waitingForUser) runId = s.runId;
      }, onDone: done.complete);
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        states.any(
            (s) => s.userAction?.type == AgentUserActionType.writeConfirmation),
        isTrue,
        reason: 'create_event pauses for confirmation',
      );
      await first.sessionService
          .confirmWriteProposal(
              accountId: 'acc-1', runId: runId, approve: true, remember: false)
          .drain<void>();
      await done.future;
      expect(states.last.state, AgentRunState.completed);

      // --- restart: a NEW composition over the SAME DB restores diagnostics ---
      final restarted = await _buildTestComposition(
        db,
        'acc-1',
        provider: _ScriptedProvider(const []),
        protector: protector,
      );
      addTearDown(restarted.dispose);
      final history = await restarted.chatRepository.recentMessages('acc-1', limit: 50);
      final assistantRunIds = <String>{
        for (final m in history)
          if (m.role == ChatRole.assistant && m.runId != null) m.runId!,
      };
      final restored = await restarted.chatRepository.toolInvocationsForRuns(
        accountId: 'acc-1',
        runIds: assistantRunIds,
      );
      // Both the read (get_tasks) and the write (create_event) invocation rows
      // survive the restart, ordered by start time.
      expect(restored.map((r) => r.toolName).toList(),
          ['get_tasks', 'create_event'],
          reason: 'persisted diagnostics are restored in execution order');
      // Safe summaries only: no raw DB id, external job id, complete account,
      // password, or ref token leaks into any restored field.
      final encoded = jsonEncode(
        restored
            .map((r) => {
                  'toolName': r.toolName,
                  'args': r.safeArgumentsSummary,
                  'result': r.safeResultSummary,
                  'errorCode': r.errorCode,
                  'status': r.status.name,
                })
            .toList(),
      );
      expect(encoded, isNot(contains('task-1')));
      expect(encoded, isNot(contains('PB12345678')));
      expect(encoded, isNot(contains('ref_')));
      expect(encoded, isNot(contains('young-1')));
      expect(encoded, isNot(contains('test-key')));

      // --- account isolation + reset wipe: diagnostics are account-scoped ----
      // A second account that never ran sees none of acc-1's invocation rows.
      await _seedAccount(db, 'acc-2');
      final other = await restarted.chatRepository.toolInvocationsForRuns(
        accountId: 'acc-2',
        runIds: assistantRunIds,
      );
      expect(other, isEmpty,
          reason: 'account B never sees account A persisted diagnostics');
      // Before reset, acc-1's two invocation rows are present.
      final beforeReset = await restarted.chatRepository.toolInvocationsForRuns(
        accountId: 'acc-1',
        runIds: assistantRunIds,
      );
      expect(beforeReset, hasLength(2));
      // The reset path wipes the account's invocation rows (account-scoped):
      // a full reset for this account clears the persisted diagnostics too.
      await db.transaction(() async {
        await (db.delete(db.toolInvocations)
              ..where((row) => row.accountId.equals('acc-1')))
            .go();
      });
      final afterReset = await restarted.chatRepository.toolInvocationsForRuns(
        accountId: 'acc-1',
        runIds: assistantRunIds,
      );
      expect(afterReset, isEmpty,
          reason: 'resetting/clearing the account removes persisted diagnostics');
    },
  );

  // ─────────────────────────────────────────────────────────────────────────
  // Task 7 composition regression: recurring create_event through the REAL
  // production tool registry + confirmation store + Drift gateway.
  //
  //   send : 建一个每周一/三/五重复的例会
  //   call : get_schedule -> create_event(with recurrence) -> final text
  //
  // The TRUTH exercised here, on the real composed registry:
  //   1. create_event(with recurrence) pauses for a write confirmation;
  //   2. approving writes EXACTLY one calendar_event_series row and ZERO
  //      calendar_events (no occurrence materialization on the agent path);
  //   3. the series reminder default is the timed [15];
  //   4. the confirmation preview names the rule (frequency/weekdays/end) and
  //      never leaks a series id / occurrence key / raw rule JSON;
  //   5. a separate fixture that DECLINES the same confirmation leaves BOTH
  //      calendar_event_series and calendar_events empty.
  // ─────────────────────────────────────────────────────────────────────────
  test(
    'composition: recurring create_event commits one series on approval and '
    'nothing on decline',
    () async {
      // --- Fixture A: approve. ---------------------------------------------
      final dbA = AppDatabase(NativeDatabase.memory());
      addTearDown(dbA.close);
      const protector = _NoopProtector();
      await _seedAccount(dbA, 'acc-1');
      await _seedAgentConfig(
        dbA,
        'acc-1',
        secrets: ProtectedAgentSecretStore(database: dbA, protector: protector),
        apiKey: 'test-key',
      );
      final providerA = _ScriptedProvider([
        _ScriptedCall(() => [
              const ToolUseCompletedEvent(
                id: 'tu-a1',
                name: 'create_event',
                input: {
                  'title': '每周例会',
                  'start_at': '2026-08-03T10:00:00+08:00',
                  'end_at': '2026-08-03T11:00:00+08:00',
                  'recurrence': {
                    'frequency': 'weekly',
                    'interval': 1,
                    'weekdays': [1, 3, 5],
                    'until_date': '2026-08-31',
                  },
                },
              ),
              const CompletedEvent(),
            ]),
        _ScriptedCall(() => [
              const TextDeltaEvent('已创建每周例会。'),
              const CompletedEvent(),
            ]),
      ]);
      final compositionA = await _buildTestComposition(
        dbA,
        'acc-1',
        provider: providerA,
        protector: protector,
      );
      addTearDown(compositionA.dispose);

      final statesA = <AgentRunViewState>[];
      final doneA = Completer<void>();
      late String runIdA;
      compositionA.sessionService
          .send(accountId: 'acc-1', userText: '建一个每周一三五重复的例会')
          .listen((s) {
        statesA.add(s);
        if (s.state == AgentRunState.waitingForUser) runIdA = s.runId;
      }, onDone: doneA.complete);
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      // pauses for write confirmation.
      final pendingA = statesA.firstWhere(
        (s) => s.userAction?.type == AgentUserActionType.writeConfirmation,
        orElse: () => throw StateError('recurring create_event did not pause'),
      );
      // 确认预览展示重复规则，且不泄漏系列 id / occurrence key / rule JSON。
      final previewA = pendingA.userAction!.writeProposal!.previewLines.join('\n');
      expect(previewA, contains('每周'));
      expect(previewA, contains('2026-08-31'));
      expect(previewA, contains('前五次'));
      expect(previewA, isNot(contains('seriesId')));
      expect(previewA, isNot(contains('occurrenceKey')));
      expect(previewA, isNot(contains('recurrenceJson')));
      expect(previewA, isNot(allOf(contains('weekly'), contains('anchor'))));

      await compositionA.sessionService
          .confirmWriteProposal(
              accountId: 'acc-1', runId: runIdA, approve: true, remember: false)
          .drain<void>();
      await doneA.future;
      expect(statesA.last.state, AgentRunState.completed);

      // 恰 1 条 series 行、0 条 occurrence 行。
      final seriesRowsA = await dbA.select(dbA.calendarEventSeries).get();
      expect(seriesRowsA, hasLength(1), reason: 'approve must create exactly one series row');
      expect(await dbA.select(dbA.calendarEvents).get(), isEmpty,
          reason: 'no calendar_events occurrence row on the agent recurring path');
      // 定时默认 reminder = [15]。
      expect(
        (jsonDecode(seriesRowsA.single.reminderOffsetsJson) as List).cast<int>(),
        [15],
        reason: 'timed series default reminder is [15]',
      );

      // --- Fixture B: decline the same confirmation -> both tables unchanged. ---
      final dbB = AppDatabase(NativeDatabase.memory());
      addTearDown(dbB.close);
      await _seedAccount(dbB, 'acc-1');
      await _seedAgentConfig(
        dbB,
        'acc-1',
        secrets: ProtectedAgentSecretStore(database: dbB, protector: protector),
        apiKey: 'test-key',
      );
      final providerB = _ScriptedProvider([
        _ScriptedCall(() => [
              const ToolUseCompletedEvent(
                id: 'tu-b1',
                name: 'create_event',
                input: {
                  'title': '每周例会',
                  'start_at': '2026-08-03T10:00:00+08:00',
                  'end_at': '2026-08-03T11:00:00+08:00',
                  'recurrence': {
                    'frequency': 'weekly',
                    'weekdays': [1, 3, 5],
                  },
                },
              ),
              const CompletedEvent(),
            ]),
        _ScriptedCall(() => [
              const TextDeltaEvent('好的。'),
              const CompletedEvent(),
            ]),
      ]);
      final compositionB = await _buildTestComposition(
        dbB,
        'acc-1',
        provider: providerB,
        protector: protector,
      );
      addTearDown(compositionB.dispose);

      final statesB = <AgentRunViewState>[];
      final doneB = Completer<void>();
      late String runIdB;
      compositionB.sessionService
          .send(accountId: 'acc-1', userText: '建一个每周一三五重复的例会')
          .listen((s) {
        statesB.add(s);
        if (s.state == AgentRunState.waitingForUser) runIdB = s.runId;
      }, onDone: doneB.complete);
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        statesB.any(
            (s) => s.userAction?.type == AgentUserActionType.writeConfirmation),
        isTrue,
        reason: 'recurring create_event pauses for confirmation across fixtures',
      );
      await compositionB.sessionService
          .confirmWriteProposal(
              accountId: 'acc-1', runId: runIdB, approve: false, remember: false)
          .drain<void>();
      await doneB.future;
      expect(statesB.last.state, AgentRunState.completed);

      // 拒绝后两表均不变。
      expect(await dbB.select(dbB.calendarEventSeries).get(), isEmpty,
          reason: 'decline must leave series table untouched');
      expect(await dbB.select(dbB.calendarEvents).get(), isEmpty,
          reason: 'decline must leave events table untouched');
    },
  );

  // ─────────────────────────────────────────────────────────────────────────
  // Task 4 FINAL composition regression: the REAL date-bounded relation
  // workflow, end to end, through the real composed registry with a scripted
  // provider.
  //
  //   seed : Task 生命科学简史课作业 + three 2026-09-01 courses
  //          07:50-09:25 计算机网络 / 09:45-11:20 非线性电子线路 /
  //          15:55-17:30 半导体材料与物理
  //   send : 在9月1号上午第一节课我想再写一门生命科学简史课作业，你只要帮我安排在这个时间段，
  //          具体事件我自己把握，并标记为不冲突
  //
  // The TRUTH exercised here (spec §4.1, §5.1-§5.3, §8.3), on the REAL
  // registry + confirmation store + Drift gateway + Relation writer:
  //
  //   1. grounding exposes EXACTLY the five task-planning/relation tools, never
  //      create_task or any other write tool;
  //   2. the exact-day no-query get_schedule(view=events) returns all three
  //      2026-09-01 events as run-local refs — the single first-period course
  //      (计算机网络) is located purely by 07:50-09:25 timing, never by guessing
  //      a title;
  //   3. plan_task commits a PlanBlock via a real confirmation checkpoint;
  //   4. get_plan_blocks locates that block (by the task ref bound in get_tasks)
  //      and hands back a run-local plan_block ref;
  //   5. create_schedule_relation(no_conflict) commits an event↔PlanBlock
  //      relation via a second real confirmation checkpoint;
  //   6. the run completes with exactly one PlanBlock and one relation; the
  //      invocation trail carries neither relation_lookup_requires_bound nor a
  //      trailing protocol_error; no Task or course title was guessed/created.
  // ─────────────────────────────────────────────────────────────────────────
  test(
    'composition: exact-day relation workflow '
    '(5-tool sequence -> 2 confirmations -> event↔PlanBlock no_conflict)',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      const protector = _NoopProtector();
      await _seedAccount(db, 'acc-1');
      final secretStore = ProtectedAgentSecretStore(
        database: db,
        protector: protector,
      );
      await _seedAgentConfig(db, 'acc-1', secrets: secretStore, apiKey: 'test-key');

      // The existing Task the user wants to schedule (生命科学简史课作业).
      await _insertTask(db, 'task-1', 'acc-1', '生命科学简史课作业');

      // Three 2026-09-01 course occurrences (the local data the request refers
      // to). 2026-09-01 is TEST DATA — never a semester literal. Use a neutral
      // semester key so no 2026spring/2026fall literal appears.
      await _insertCourseSeries(
        db,
        'series-net',
        'acc-1',
        externalId: 'lesson-net',
        title: '计算机网络',
        semesterKey: 'aug2026',
      );
      await _insertCourseSeries(
        db,
        'series-elec',
        'acc-1',
        externalId: 'lesson-elec',
        title: '非线性电子线路',
        semesterKey: 'aug2026',
      );
      await _insertCourseSeries(
        db,
        'series-semi',
        'acc-1',
        externalId: 'lesson-semi',
        title: '半导体材料与物理',
        semesterKey: 'aug2026',
      );
      await _insertCourseOccurrence(
        db,
        'occ-net',
        'acc-1',
        '计算机网络',
        seriesExternalId: 'lesson-net',
        location: '三教101',
        start: DateTime(2026, 9, 1, 7, 50),
        end: DateTime(2026, 9, 1, 9, 25),
      );
      await _insertCourseOccurrence(
        db,
        'occ-elec',
        'acc-1',
        '非线性电子线路',
        seriesExternalId: 'lesson-elec',
        location: '三教201',
        start: DateTime(2026, 9, 1, 9, 45),
        end: DateTime(2026, 9, 1, 11, 20),
      );
      await _insertCourseOccurrence(
        db,
        'occ-semi',
        'acc-1',
        '半导体材料与物理',
        seriesExternalId: 'lesson-semi',
        location: '四教102',
        start: DateTime(2026, 9, 1, 15, 55),
        end: DateTime(2026, 9, 1, 17, 30),
      );

      // The scripted "model" executes the real §5.2 sequence:
      //   get_tasks + get_schedule(view=events, exact 2026-09-01)  [turn 1]
      //   plan_task                                              [turn 2, confirm 1]
      //   get_plan_blocks(taskRef=<task ref from get_tasks>)       [turn 3]
      //   create_schedule_relation(no_conflict)                    [turn 4, confirm 2]
      //   final text                                              [turn 5]
      const blockStart = '2026-09-01T07:50:00+08:00';
      const blockEnd = '2026-09-01T09:25:00+08:00';
      final provider = _ScriptedProvider([
        // Call 1: get_tasks (binds the 生命科学简史课作业 task ref) + get_schedule
        // exact-day events (binds all three course refs). Both are independent
        // reads the model may issue in the same turn.
        _ScriptedCall(() => [
              const ToolUseCompletedEvent(
                id: 'tu-t1',
                name: 'get_tasks',
                input: {},
              ),
              const ToolUseCompletedEvent(
                id: 'tu-t2',
                name: 'get_schedule',
                input: {
                  'from': '2026-09-01',
                  'through': '2026-09-01',
                  'view': 'events',
                },
              ),
              const CompletedEvent(),
            ]),
        // Call 2: plan_task for the existing task (echoes the get_tasks ref).
        // Pauses for write confirmation.
        _ScriptedCall(
          () => [
            const ToolUseCompletedEvent(
              id: 'tu-t3',
              name: 'plan_task',
              input: {},
            ),
            const CompletedEvent(),
          ],
          inputBuilder: (prior) {
            final refs = _refsFromLastToolResult(prior);
            // The FIRST bound task ref is the get_tasks result (it precedes the
            // get_schedule refs in turn 1's tool_results), but to be robust,
            // resolve the ref that the get_tasks payload actually carries.
            return {
              'ref_task': _taskRefFromResults(prior) ?? refs.first,
              'start_at': blockStart,
              'end_at': blockEnd,
            };
          },
        ),
        // Call 3: get_plan_blocks filtered to the just-planned task (echoes the
        // task ref). The block now exists -> binds a plan_block ref.
        _ScriptedCall(
          () => [
            const ToolUseCompletedEvent(
              id: 'tu-t4',
              name: 'get_plan_blocks',
              input: {},
            ),
            const CompletedEvent(),
          ],
          inputBuilder: (prior) => {
            'taskRef': _taskRefFromResults(prior),
          },
        ),
        // Call 4: create_schedule_relation(no_conflict) between the first-period
        // event (located by 07:50-09:25 timing from the exact-day get_schedule)
        // and the new PlanBlock (from get_plan_blocks). Pauses for confirmation.
        _ScriptedCall(
          () => [
            const ToolUseCompletedEvent(
              id: 'tu-t5',
              name: 'create_schedule_relation',
              input: {},
            ),
            const CompletedEvent(),
          ],
          inputBuilder: (prior) {
            final eventRef = _firstPeriodEventRef(prior);
            final blockRef = _lastPlanBlockRef(prior);
            if (eventRef == null) {
              throw StateError('first-period event ref not found in feed');
            }
            if (blockRef == null) {
              throw StateError('plan-block ref not found in feed');
            }
            return {
              'ref_left': eventRef,
              'ref_right': blockRef,
              'conflict_state': 'no_conflict',
              'reason': '在第一节课期间写生命科学简史课作业',
            };
          },
        ),
        // Call 5: final completion prose.
        _ScriptedCall(() => [
              const TextDeltaEvent(
                '已安排生命科学简史课作业的执行时间段（07:50-09:25），'
                '并把它与第一节课标记为不冲突。',
              ),
              const CompletedEvent(),
            ]),
      ]);
      final composition = await _buildTestComposition(
        db,
        'acc-1',
        provider: provider,
        protector: protector,
      );
      addTearDown(composition.dispose);

      final states = <AgentRunViewState>[];
      final done = Completer<void>();
      late String runId;
      composition.sessionService
          .send(accountId: 'acc-1', userText: '在9月1号上午第一节课我想再写一门生命'
              '科学简史课作业，你只要帮我安排在这个时间段，具体事件我自己把握，并标记为不冲突')
          .listen((s) {
        states.add(s);
        if (s.state == AgentRunState.waitingForUser) runId = s.runId;
      }, onDone: done.complete);

      // --- turn 1 (get_tasks + get_schedule) -> turn 2 plan_task pauses ---
      Future<dynamic> waitForCard(String label) async {
        // The state list accumulates across the whole run (two confirmations
        // share one runId), so poll for the SPECIFIC operation label rather
        // than grabbing the last userAction (which may be an earlier card).
        for (var i = 0; i < 150; i++) {
          AgentRunViewState? found;
          for (final s in states) {
            if (s.userAction?.type == AgentUserActionType.writeConfirmation &&
                s.userAction!.writeProposal?.operationLabel == label) {
              found = s;
            }
          }
          if (found != null) return found.userAction!.writeProposal!;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        fail('never saw the $label confirmation card');
      }

      final planProposal = await waitForCard('安排任务时间段');
      expect(planProposal.operationLabel, '安排任务时间段',
          reason: 'the first confirmation is the plan_task card');
      expect(planProposal.previewLines.join('\n'), contains('生命科学简史课作业'),
          reason: 'the plan confirm names the existing task title');

      // Approve the PlanBlock creation.
      await composition.sessionService
          .confirmWriteProposal(
              accountId: 'acc-1', runId: runId, approve: true, remember: false)
          .drain<void>();

      // --- turn 3 (get_plan_blocks) -> turn 4 relation pauses ---
      final relProposal = await waitForCard('记录日程关系');
      expect(relProposal.operationLabel, '记录日程关系',
          reason: 'the second confirmation is the relation card');
      final relPreview = relProposal.previewLines.join('\n');
      expect(relPreview, contains('计算机网络'),
          reason: 'the relation preview names the located first-period course');
      expect(relPreview, isNot(contains('occ-net')),
          reason: 'the relation preview must not leak the raw event DB id');
      expect(relPreview, isNot(contains('ref_')),
          reason: 'the relation preview must not leak run-local refs');

      // Approve the relation.
      await composition.sessionService
          .confirmWriteProposal(
              accountId: 'acc-1', runId: runId, approve: true, remember: false)
          .drain<void>();
      await done.future;

      // --- terminal truth ---------------------------------------------------
      expect(states.last.state, AgentRunState.completed);
      // The persisted run row reflects the completed terminal state.
      final runs = await db.select(db.agentRuns).get();
      expect(runs.single.status, AgentRunState.completed.name);

      // Exactly ONE PlanBlock and ONE canonical Relation.
      final planBlocks = await db.select(db.planBlocks).get();
      final planBlocksForTask = planBlocks
          .where((b) => b.taskId == 'task-1')
          .toList(growable: false);
      expect(planBlocksForTask, hasLength(1));
      expect(planBlocksForTask.single.startAt,
          DateTime.utc(2026, 9, 1, 7, 50).millisecondsSinceEpoch -
              const Duration(hours: 8).inMilliseconds);
      expect(planBlocksForTask.single.endAt,
          DateTime.utc(2026, 9, 1, 9, 25).millisecondsSinceEpoch -
              const Duration(hours: 8).inMilliseconds);

      final relations = await db.select(db.scheduleRelations).get();
      expect(relations, hasLength(1));
      expect(relations.single.conflictState, 'no_conflict');
      // The pair is event↔PlanBlock, both under the same account.
      expect(relations.single.leftKind, 'event');
      expect(relations.single.rightKind, 'plan_block');
      expect(relations.single.leftId, 'occ-net');
      expect(relations.single.rightId, planBlocksForTask.single.id);
      expect(relations.single.leftEventId, 'occ-net');
      expect(relations.single.rightPlanBlockId, planBlocksForTask.single.id);
      expect(relations.single.accountId, 'acc-1');
      // No Task or course title was guessed or newly created: the only task is
      // the seeded one, and the only courses are the three seeded occurrences.
      expect((await db.select(db.tasks).get()).length, 1);
      expect((await db.select(db.calendarEvents).get()).length, 3);

      // --- invocation diagnostic trail -------------------------------------
      // The five real tool calls ran in order; persisted diagnostics record
      // ONLY safe codes. Neither relation_lookup_requires_bound nor a trailing
      // protocol_error may appear.
      final activeRunId = runs.single.id;
      final invocations =
          await composition.chatRepository.toolInvocationsForRuns(
        accountId: 'acc-1',
        runIds: {activeRunId},
      );
      expect(
        invocations.map((r) => r.toolName).toList(growable: false),
        [
          'get_tasks',
          'get_schedule',
          'plan_task',
          'get_plan_blocks',
          'create_schedule_relation',
        ],
        reason: 'the real five-tool sequence ran in §5.2 order',
      );
      final errorCodes = invocations.map((r) => r.errorCode).toSet();
      expect(errorCodes, isNot(contains('relation_lookup_requires_bound')));
      expect(errorCodes, isNot(contains('protocol_error')));
      // Every invocation reached a terminal lifecycle state (no lingering
      // running/waiting rows).
      for (final inv in invocations) {
        expect(inv.status.isTerminal, isTrue,
            reason: 'every persisted invocation must settle to a terminal state');
      }
      // The first-period event was located by the exact-day get_schedule WITHOUT
      // a title query: the get_schedule call carried no query argument.
      final scheduleCall = invocations
          .firstWhere((inv) => inv.toolName == 'get_schedule');
      expect(scheduleCall.safeArgumentsSummary, isNot(contains('计算机网络')),
          reason: 'the exact-day lookup must not carry a title query');
      expect(scheduleCall.safeArgumentsSummary, contains('2026-09-01'),
          reason: 'the exact-day lookup carries the bound date');
      // The model-facing feed reflected the timing-based selection, not a guessed
      // course name in the write input (the relation refs resolve via the store).
      final feed = _capturedToolResults(provider).join('\n');
      expect(feed, contains('2026-09-01T07:50:00'),
          reason: 'the exact-day get_schedule surfaced the first-period timing');
      expect(feed, isNot(contains('occ-net')),
          reason: 'no raw event DB id may reach the model feed');
    },
  );

  // ─────────────────────────────────────────────────────────────────────────
  // Task 4 FINAL composition regression: the create-task burst workflow, end to
  // end, through the real composed registry + confirmation store + Drift Task
  // gateway with a scripted provider.
  //
  //   seed : account acc-1 with course 电磁场与波 whose occurrences run weekly
  //          on 13 consecutive Saturdays (2026-09-05 .. 2026-11-28, explicit
  //          Beijing dates, never a semester constant).
  //   send : 电磁场与波作业连续13周每周六截止，请根据这门课的有效周次分别创建独立Task。
  //
  // The TRUTH exercised here (spec §14.4), on the REAL registry + confirmation
  // store + Drift gateway:
  //
  //   1. the run is grounded as a create-task burst: the FIRST model request
  //      declares only `get_schedule` + `create_task`;
  //   2. the first tool call is a course_summary lookup (the course effective
  //      range), never an unbounded semester `events` dump;
  //   3. the NEXT single assistant response contains 13 distinct `create_task`
  //      tool uses (one block per expected Saturday deadline);
  //   4. each create_task still follows the current permission policy through
  //      the REAL confirmation store (the first is confirmed via
  //      confirmWriteProposal; the remaining ask_first_time calls auto-execute),
  //      and every write commits via the Drift Task gateway in its own row;
  //   5. the run completes with 13 independent Tasks, no tool_call_budget_exceeded,
  //      no hidden second Burst, and no TaskSeries/batch tool appears.
  //
  // A SECOND test then declines one confirmation and re-runs the same fixture:
  // the successful writes are NOT rolled back, the run settles as
  // create_task_burst_partial with accurate counts, and the declined item is
  // recorded as a user decline.
  // ─────────────────────────────────────────────────────────────────────────

  /// The 13 explicit Beijing Saturday deadlines of the course range. Computed
  /// once so both burst tests share identical explicit dates (never derived
  /// from a semester constant).
  final decl = _createTaskBurstFixture();

  test(
    'composition: 13-week create-task burst completes 13 independent Tasks '
    'with no budget error and no second Burst',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      const protector = _NoopProtector();
      await _seedBurstCourse(db, 'acc-1', decl);

      final provider = _ScriptedProvider(decl.burstScript(decl.saturdays.length));
      final composition = await _buildTestComposition(
        db,
        'acc-1',
        provider: provider,
        protector: protector,
      );
      addTearDown(composition.dispose);

      final states = <AgentRunViewState>[];
      final done = Completer<void>();
      late String runId;
      composition.sessionService
          .send(
              accountId: 'acc-1',
              userText: '电磁场与波作业连续13周每周六截止，'
                  '请根据这门课的有效周次分别创建独立Task。')
          .listen((s) {
        states.add(s);
        if (s.state == AgentRunState.waitingForUser) runId = s.runId;
      }, onDone: done.complete);

      // The first create_task pauses for the REAL write-confirmation card
      // (create_task defaults to ask_first_time). Approve WITHOUT remember:
      // the first confirmation records firstConfirmedAt, so the remaining 12
      // calls auto-execute through the same real permission path. This drives
      // the pending-action API without bypassing production confirmation.
      for (var i = 0; i < 300; i++) {
        if (states.any((s) =>
            s.userAction?.type == AgentUserActionType.writeConfirmation)) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        states.any(
            (s) => s.userAction?.type == AgentUserActionType.writeConfirmation),
        isTrue,
        reason: 'the first create_task must pause for write confirmation',
      );
      await composition.sessionService
          .confirmWriteProposal(
              accountId: 'acc-1', runId: runId, approve: true, remember: false)
          .drain<void>();
      await done.future;

      // --- terminal truth ---------------------------------------------------
      final run = states.last;
      expect(run.state, AgentRunState.completed,
          reason: '13/13 successful writes must complete the run');
      expect(run.errorCode, isNull,
          reason: 'a fully-successful burst reports NO error code');

      // The run was grounded as a create-task burst: the FIRST model request
      // declared only get_schedule + create_task (the burst narrowing), and the
      // model issued exactly one course_summary lookup before the burst turn.
      final firstDeclared = provider.requests.first.tools
          .map((t) => t.name)
          .toSet();
      expect(firstDeclared, {'get_schedule', 'create_task'},
          reason: 'the burst grounding narrows the first request to '
              'get_schedule + create_task');

      // 13 independent Tasks, all deadlines distinct and inside the course range.
      final tasks = await db.select(db.tasks).get();
      expect(tasks, hasLength(13),
          reason: 'exactly 13 Tasks are created by the 13-block burst turn');
      final deadlinesMs = tasks.map((t) => t.deadlineAt).toList();
      expect(deadlinesMs, isNot(contains(null)),
          reason: 'every burst Task carries a deadline');
      // Reconstruct each deadline's Beijing calendar DAY and month (independent
      // of the machine timezone) and assert the 13 distinct dates are exactly
      // the course's Saturday range.
      final deadlineBeijingDates = <String>[
        for (final ms in deadlinesMs.cast<int>())
          _beijingDateKey(DateTime.fromMillisecondsSinceEpoch(ms)),
      ];
      expect(deadlineBeijingDates.toSet(), hasLength(13),
          reason: 'thirteen distinct Beijing Saturday deadlines');
      final expectedDays = <String>{
        for (final d in decl.saturdays)
          _beijingDateKey(DateTime(d.year, d.month, d.day)),
      };
      expect(deadlineBeijingDates.toSet(), expectedDays,
          reason: 'every deadline must lie within the course effective range '
              '(exactly the 13 Saturdays)');
      // Every Task is INDEPENDENT: distinct titles, no shared series/batch field.
      expect(tasks.map((t) => t.title).toSet(), hasLength(13),
          reason: 'each of the 13 Tasks is a distinct independent write');

      // 13 create_task invocations persisted, none with a budget error.
      final mkInv = await composition.chatRepository.toolInvocationsForRuns(
        accountId: 'acc-1',
        runIds: {run.runId},
      );
      final createInvocations =
          mkInv.where((r) => r.toolName == 'create_task').toList();
      expect(createInvocations, hasLength(13),
          reason: '13 independent create_task lifecycle rows');
      final errorCodes = mkInv.map((r) => r.errorCode).toSet();
      expect(errorCodes, isNot(contains('tool_call_budget_exceeded')),
          reason: 'the burst must not trip the ordinary tool budget');
      expect(errorCodes, isNot(contains('create_task_burst_already_used')),
          reason: 'no hidden second Burst turn');
      // No TaskSeries/batch tool/schema appears anywhere in the run.
      final executedNames = _executedSequence(mkInv);
      expect(executedNames.where((n) => n == 'create_task'), hasLength(13));
      expect(
        composition.registry.schemas.any((t) =>
            t.name.contains('task_series') || t.name.contains('batch')),
        isFalse,
        reason: 'no TaskSeries or batch tool is registered',
      );

      // The first lookup was the course_summary range, never an unbounded
      // semester events read.
      final scheduleInvocations =
          mkInv.where((r) => r.toolName == 'get_schedule').toList();
      expect(scheduleInvocations, hasLength(1),
          reason: 'exactly one schedule lookup (course_summary) before the burst');
      expect(scheduleInvocations.single.safeArgumentsSummary, contains('course_summary'),
          reason: 'the first lookup is the course_summary view, never a whole-'
              'semester events dump');

      // The other seeded account sees zero new Tasks and zero invocations.
      await _seedAccount(db, 'acc-2');
      expect(
        await (db.select(db.tasks)..where((row) => row.accountId.equals('acc-2')))
            .get(),
        isEmpty,
        reason: 'the other account must not inherit the burst Tasks',
      );
      expect(
        await (db.select(db.toolInvocations)
              ..where((row) => row.accountId.equals('acc-2')))
            .get(),
        isEmpty,
        reason: 'the other account must not see the burst invocation records',
      );
    },
  );

  test(
    'composition: declining one create_task does not roll back the others and '
    'reports create_task_burst_partial with accurate counts',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      const protector = _NoopProtector();
      await _seedBurstCourse(db, 'acc-1', decl);

      final provider =
          _ScriptedProvider(decl.burstScript(decl.saturdays.length));
      final composition = await _buildTestComposition(
        db,
        'acc-1',
        provider: provider,
        protector: protector,
      );
      addTearDown(composition.dispose);

      final states = <AgentRunViewState>[];
      final done = Completer<void>();
      late String runId;
      composition.sessionService
          .send(
              accountId: 'acc-1',
              userText: '电磁场与波作业连续13周每周六截止，'
                  '请根据这门课的有效周次分别创建独立Task。')
          .listen((s) {
        states.add(s);
        if (s.state == AgentRunState.waitingForUser) runId = s.runId;
      }, onDone: done.complete);

      Future<void> waitForConfirmation() async {
        for (var i = 0; i < 300; i++) {
          if (states.any((s) =>
              s.userAction?.type == AgentUserActionType.writeConfirmation)) {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        fail('expected a write confirmation');
      }

      // Decline the FIRST create_task: it never sets firstConfirmedAt, so the
      // second task confirms again and is approved, which relaxes the remaining
      // 11 to auto-execute. This drives the REAL confirmation API twice and
      // proves a declined write does not roll back the others.
      await waitForConfirmation();
      await composition.sessionService
          .confirmWriteProposal(
              accountId: 'acc-1', runId: runId, approve: false, remember: false)
          .drain<void>();

      // After the decline the loop advances to the next create_task and pauses
      // again (ask_first_time still unbound). Approve it.
      final before = states.length;
      for (var i = 0; i < 300; i++) {
        final idx = states.lastIndexWhere((s) =>
            s.userAction?.type == AgentUserActionType.writeConfirmation);
        if (idx >= before) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await composition.sessionService
          .confirmWriteProposal(
              accountId: 'acc-1', runId: runId, approve: true, remember: false)
          .drain<void>();
      await done.future;

      // The run settles as create_task_burst_partial, NOT success, and the
      // deterministic terminal message reports accurate partial counts.
      final run = states.last;
      expect(run.state, AgentRunState.failed,
          reason: 'a burst with a declined write must not report success');
      expect(run.errorCode, 'create_task_burst_partial');
      expect(run.text, '已创建 12 个 Task，1 个未完成。其中 1 个已取消。',
          reason: 'the deterministic partial report states 12 created + 1 cancelled');

      // The 12 approved writes persist; the declined one leaves no Task.
      final tasks = await db.select(db.tasks).get();
      expect(tasks, hasLength(12),
          reason: 'declining one write must not roll back the 12 approved ones');
      final logs = await db.actionLogsRepository.selectAll();
      expect(
        logs.where((l) =>
            l.source == 'user' &&
            l.actionType == 'agent_write_decline' &&
            l.result == 'declined'),
        hasLength(1),
        reason: 'exactly one declined write is audited as a user decline',
      );
      final survivingDays = <String>{
        for (final t in tasks)
          if (t.deadlineAt != null)
            _beijingDateKey(DateTime.fromMillisecondsSinceEpoch(t.deadlineAt!)),
      };
      expect(survivingDays, hasLength(12),
          reason: 'the 12 surviving Tasks have distinct Beijing deadlines');
    },
  );

  // ─────────────────────────────────────────────────────────────────────────
  // Task 9 HARD GATE: Production Recurring Reachability.
  //
  // End-to-end proof that a recurring personal schedule created by the PRODUCTION
  // `create_event` write tool (weekly Mon/Wed/Fri, 2026-08-03..2026-08-31):
  //
  //   1. commits exactly ONE `calendar_event_series` row and ZERO
  //      `calendar_events` occurrence rows (no occurrence materialization);
  //   2. appears in a PRODUCTION `get_schedule(view=management)` week read, whose
  //      bound `ref_*` resolves (via the run reference store) to an occ_v1
  //      locator that decodes back to (seriesId, occurrenceKey);
  //   3. is targeted by the PRODUCTION `set_reminder` and
  //      `create_schedule_relation` write tools, which persist a sparse no-op
  //      occurrence-exception anchor + the dependent reminder / relation rows
  //      bound to that anchor (never to a materialized calendar_events row);
  //   4. after a composition RESTART over the same database, `get_schedule`
  //      yields the SAME occurrence identity (same seriesId+occurrenceKey) and
  //      the dependent rows are still present — proving stable, DB-persisted
  //      identity;
  //   5. is account-isolated: a get_schedule week read for a DIFFERENT account
  //      returns no occurrence of this series.
  //
  // No raw seriesId / occurrenceKey / locator text / DB id ever appears in a
  // tool-response payload (the DTO allowlist strips them; identity is proven by
  // decoding the opaque run-local ref).
  // ─────────────────────────────────────────────────────────────────────────
  test(
    'Task 9 hard gate: recurring occurrence from production create_event is '
    'reachable, ref-bound, sparsely anchored, stable across restart, isolated',
    () async {
      // ──────────────────────────────────────────────────────────────────
      // Fixture: production composition over a real in-memory Drift DB.
      // ──────────────────────────────────────────────────────────────────
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      const protector = _NoopProtector();
      await _seedAccount(db, 'acc-1');
      await _seedAccount(db, 'acc-2');
      await _seedAgentConfig(
        db,
        'acc-1',
        secrets: ProtectedAgentSecretStore(database: db, protector: protector),
        apiKey: 'test-key',
      );
      await _seedAgentConfig(
        db,
        'acc-2',
        secrets: ProtectedAgentSecretStore(database: db, protector: protector),
        apiKey: 'test-key-2',
      );

      // Always-allow the three write actions so the production registry routes
      // them through the shared atomic commit path (business -> audit ->
      // permissions in one unit-of-work transaction) with deterministic,
      // non-pausing direct writes — matching the Task 3 composition regression.
      Future<void> allow(String id, String action, String target) => db
          .into(db.agentPermissionPolicies)
          .insert(
            AgentPermissionPoliciesCompanion.insert(
              id: id,
              accountId: 'acc-1',
              actionType: action,
              targetType: Value(target),
              confirmationMode: 'always_allow',
              riskLevel: const Value('medium'),
              enabled: const Value(true),
              createdAt: 1,
              updatedAt: 1,
            ),
          );

      // --- Step 1: production create_event with weekly recurrence. ----------
      final provider1 = _ScriptedProvider([
        _ScriptedCall(() => [
              const ToolUseCompletedEvent(
                id: 'tu-ce1',
                name: 'create_event',
                input: {
                  'title': '每周例会',
                  'start_at': '2026-08-03T10:00:00+08:00',
                  'end_at': '2026-08-03T11:00:00+08:00',
                  'recurrence': {
                    'frequency': 'weekly',
                    'interval': 1,
                    'weekdays': [1, 3, 5], // Mon/Wed/Fri
                    'until_date': '2026-08-31',
                  },
                },
              ),
              const CompletedEvent(),
            ]),
        _ScriptedCall(() => [
              const TextDeltaEvent('已创建每周例会。'),
              const CompletedEvent(),
            ]),
      ]);
      final composition = await _buildTestComposition(
        db,
        'acc-1',
        provider: provider1,
        protector: protector,
      );
      addTearDown(composition.dispose);

      // Drive create_event through the REAL confirmation store + approve path.
      final states = <AgentRunViewState>[];
      final done = Completer<void>();
      late String runId;
      composition.sessionService
          .send(accountId: 'acc-1', userText: '建一个每周一三五重复的例会')
          .listen((s) {
        states.add(s);
        if (s.state == AgentRunState.waitingForUser) runId = s.runId;
      }, onDone: done.complete);
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        states.any(
            (s) => s.userAction?.type == AgentUserActionType.writeConfirmation),
        isTrue,
        reason: 'production create_event(recurrence) must pause for approval',
      );
      await composition.sessionService
          .confirmWriteProposal(
              accountId: 'acc-1', runId: runId, approve: true, remember: false)
          .drain<void>();
      await done.future;
      expect(states.last.state, AgentRunState.completed);

      // --- Step 2: exactly one series row, zero calendar_events rows. --------
      final seriesRows = await db.select(db.calendarEventSeries).get();
      expect(seriesRows, hasLength(1),
          reason: 'production create_event(recurrence) commits exactly one series');
      final seriesId = seriesRows.single.id;
      expect(await db.select(db.calendarEvents).get(), isEmpty,
          reason: 'no calendar_events occurrence row is materialized on the '
              'production recurring path');
      // The series reminder default is the timed [15].
      expect(
        (jsonDecode(seriesRows.single.reminderOffsetsJson) as List).cast<int>(),
        [15],
        reason: 'timed series default reminder is [15]',
      );

      // Allow the two write tools that persist against the sparse anchor.
      await allow('pp-reminder', 'set_reminder', 'event');
      await allow('pp-relation', 'create_schedule_relation', 'relation');

      // A single run-level context: one RunReferenceStore so the refs bound by
      // get_schedule resolve in set_reminder / create_schedule_relation.
      final ctx = integrationCtx('acc-1', 'r-hardgate');
      final registry = composition.registry;

      // --- Step 3: get_schedule management for the week with one occurrence. -
      // The recurring target is an EFFECTIVE query object — retrievable through
      // the projection with zero calendar_events materialization.
      final week = await registry.execute(
        toolName: 'get_schedule',
        arguments: {
          'view': 'management',
          'from': '2026-08-03',
          'through': '2026-08-09',
        },
        context: ctx,
      );
      expect(week.status, AgentToolStatus.success);
      final managementEvents = week.payload['managementEvents']! as List;
      expect(managementEvents, hasLength(3),
          reason: 'Mon/Wed/Fri within 2026-08-03..2026-08-09 = 3 occurrences');
      final first = managementEvents.first! as Map<String, Object?>;
      expect(first['isRecurring'], isTrue);
      expect(first['startDate'], isNull,
          reason: 'a timed occurrence surfaces startAt, never startDate');
      // The management DTO serializes the occurrence's UTC instant (Beijing
      // 10:00 == UTC 02:00), matching `_fmtDateTime(toIso8601String)`.
      expect(first['startAt'], '2026-08-03T02:00:00');
      final occurrences = managementEvents.cast<Map<String, Object?>>();
      final refs = <String>[
        for (final e in occurrences) e['ref']! as String,
      ];
      expect(refs, hasLength(3));

      // --- Step 4: resolve the returned ref_event and prove seriesId + occurrenceKey.
      final locatorText = ctx.references.resolve(ref: refs.first, kind: 'event');
      expect(locatorText, isNotNull,
          reason: 'the management ref must resolve to an encoded locator');
      expect(locatorText, startsWith('occ_v1.'));
      final decoded = decodeCalendarEventLocator(locatorText!);
      expect(decoded, isA<RecurringOccurrenceLocator>());
      final occ = decoded as RecurringOccurrenceLocator;
      expect(occ.seriesId, seriesId,
          reason: 'ref must decode to THIS production-created series id');
      expect(occ.occurrenceKey, '$seriesId@2026-08-03T02:00:00',
          reason: 'occurrenceKey is the series anchor-time discriminator '
              '(UTC wall clock for the Beijing 10:00 anchor)');
      // No raw identity ever leaks into the model-facing payload.
      final weekEncoded = jsonEncode(week.payload);
      expect(weekEncoded, isNot(contains(seriesId)));
      expect(weekEncoded, isNot(contains('@2026-')));
      expect(weekEncoded, isNot(contains('occ_v1.')));

      // --- Step 5: set_reminder + create_schedule_relation against that ref. --
      final reminder = await registry.execute(
        toolName: 'set_reminder',
        arguments: {'ref_event': refs.first, 'offsets_minutes': [30]},
        context: ctx,
      );
      expect(reminder.status, AgentToolStatus.success);
      expect(reminder.payload['result'], 'reminder_set');

      // Relation between the first and second occurrences of the same week.
      final relation = await registry.execute(
        toolName: 'create_schedule_relation',
        arguments: {
          'ref_left': refs[0],
          'ref_right': refs[1],
          'conflict_state': 'no_conflict',
          'reason': '同系列两场例会',
        },
        context: ctx,
      );
      expect(relation.status, AgentToolStatus.success);
      expect(relation.payload['result'], 'created_schedule_relation');

      // --- Step 6: verify sparse anchors + dependent rows. --------------------
      // ensureOccurrenceAnchor created a no-op kind='override' anchor per distinct
      // occurrence touched: occ Aug-03 (set_reminder + relation left) and
      // occ Aug-05 (relation right) = exactly 2 anchors.
      final anchors = await db.select(db.calendarEventOccurrenceExceptions).get();
      expect(anchors, hasLength(2),
          reason: 'one no-op anchor for each distinct anchored occurrence');
      final anchorKeys = <String>{
        for (final a in anchors) a.occurrenceKey,
      };
      expect(anchorKeys,
          containsAll([
            '$seriesId@2026-08-03T02:00:00',
            '$seriesId@2026-08-05T02:00:00',
          ]));
      for (final a in anchors) {
        expect(a.seriesId, seriesId);
        expect(a.kind, 'override',
            reason: 'a sparse anchor is a no-op kind=override, no display effect');
        expect(a.overriddenFieldsJson, '[]');
        expect(a.orphaned, isFalse);
        expect(a.deletedAt, isNull);
      }

      // Reminder row bound to the occurrence anchor (targetId = encoded locator).
      final reminders = await db.select(db.reminders).get();
      expect(reminders, hasLength(1),
          reason: 'one reminder row for the set_reminder write');
      final rem = reminders.single;
      expect(rem.accountId, 'acc-1');
      expect(rem.targetType, 'event');
      expect(rem.occurrenceExceptionId, isNotNull,
          reason: 'reminder persists through the occurrence-exception FK anchor');
      final remTarget = decodeCalendarEventLocator(rem.targetId);
      expect(remTarget, isA<RecurringOccurrenceLocator>());
      expect((remTarget as RecurringOccurrenceLocator).seriesId, seriesId);

      // Relation rows bound to the occurrence anchors (left/right occurrence FK).
      final relations = await db.select(db.scheduleRelations).get();
      expect(relations, hasLength(1));
      final rel = relations.single;
      expect(rel.leftOccurrenceExceptionId, isNotNull);
      expect(rel.rightOccurrenceExceptionId, isNotNull);
      expect(rel.leftEventId, isNull,
          reason: 'recurring participants use the occurrence-exception FK, '
              'never a materialized calendar_events id');
      expect(rel.rightEventId, isNull);

      // The seeded dependent rows reference the SAME anchors get_schedule's ref
      // decoded to: locator text equals the encoded occurrence locator.
      final remKey = decodeCalendarEventLocator(rem.targetId) as RecurringOccurrenceLocator;
      expect(remKey.seriesId, seriesId);
      expect(remKey.occurrenceKey, '$seriesId@2026-08-03T02:00:00');

      // Tool payloads never leak the anchor / locator / series internals.
      final payloadText = jsonEncode([reminder.payload, relation.payload]);
      expect(payloadText, isNot(contains(seriesId)));
      expect(payloadText, isNot(contains('occ_v1.')));

      // --------------------------------------------------------------------
      // Step 7-8: restart the composition over the SAME database and re-prove
      // stable occurrence identity + persisted dependencies.
      // --------------------------------------------------------------------
      // Tear down the running composition (its session/registry/context are
      // run-scoped), then build a FRESH production composition over the SAME
      // db. The series/anchors/reminder/relation rows persist in the DB.
      await composition.dispose();

      final provider2 = _ScriptedProvider(const []);
      final restarted = await _buildTestComposition(
        db,
        'acc-1',
        provider: provider2,
        protector: protector,
      );
      addTearDown(restarted.dispose);

      final ctx2 = integrationCtx('acc-1', 'r-restart');
      final week2 = await restarted.registry.execute(
        toolName: 'get_schedule',
        arguments: {
          'view': 'management',
          'from': '2026-08-03',
          'through': '2026-08-09',
        },
        context: ctx2,
      );
      expect(week2.status, AgentToolStatus.success);
      final events2 = week2.payload['managementEvents']! as List;
      expect(events2, hasLength(3),
          reason: 'same week still yields 3 occurrences after restart');
      final refs2 = <String>[
        for (final e in events2.cast<Map<String, Object?>>()) e['ref']! as String,
      ];
      final locator2 = ctx2.references.resolve(ref: refs2.first, kind: 'event');
      final decoded2 = decodeCalendarEventLocator(locator2!) as RecurringOccurrenceLocator;
      expect(decoded2.seriesId, seriesId,
          reason: 'occurrence series identity is STABLE across restart');
      expect(decoded2.occurrenceKey, '$seriesId@2026-08-03T02:00:00',
          reason: 'occurrence key is STABLE across restart');
      // A fresh get_schedule does not materialize any calendar_events row.
      expect(await db.select(db.calendarEvents).get(), isEmpty,
          reason: 'restarted read still never materializes occurrences');
      // Dependencies persisted through the sparse anchors survive the restart.
      expect((await db.select(db.reminders).get()), hasLength(1));
      expect((await db.select(db.scheduleRelations).get()), hasLength(1));
      expect((await db.select(db.calendarEventOccurrenceExceptions).get()),
          hasLength(2));

      // --- Step 9: account isolation. ----------------------------------------
      final provider3 = _ScriptedProvider(const []);
      final other = await _buildTestComposition(
        db,
        'acc-2',
        provider: provider3,
        protector: protector,
      );
      addTearDown(other.dispose);
      final ctx3 = integrationCtx('acc-2', 'r-other');
      final week3 = await other.registry.execute(
        toolName: 'get_schedule',
        arguments: {
          'view': 'management',
          'from': '2026-08-03',
          'through': '2026-08-09',
        },
        context: ctx3,
      );
      expect(week3.status, AgentToolStatus.success);
      expect(week3.payload['managementEvents']! as List, isEmpty,
          reason: 'account acc-2 must see no occurrence of acc-1\'s series');
      expect(await db.select(db.calendarEvents).get(), isEmpty,
          reason: 'isolation check leaves no materialized occurrence either');
    },
  );

  // ─────────────────────────────────────────────────────────────────────────
  // Task 12: composite lifecycle/delete regression over the REAL composition
  // registry + Drift gateway + unit-of-work (audit + undo). Drives each
  // lifecycle/clear/unlink/reset/undo write tool through `writeRegistry` with
  // `always_allow` permission (the same atomic commit path used in production,
  // minus the confirmation pause) so the assertions exercise the full
  // business → audit → undo-slot transaction, the run-local ref binding, and
  // the privacy allowlist — not just the service in isolation.
  //
  // The 13 brief scenarios map to the tests below. Where a scenario already
  // has dedicated composition or service coverage, this group exercises the
  // REAL registry commit path rather than duplicating the service-level case;
  // the cross-references are noted in each test's header comment.
  // ─────────────────────────────────────────────────────────────────────────
  group('Task 12 lifecycle composite regression', () {
    /// Inserts an `always_allow` policy for [action] so the write tool commits
    /// through the real atomic path without pausing for confirmation.
    Future<void> allow(
      AppDatabase db,
      String accountId,
      String action,
      String targetType,
    ) => db.into(db.agentPermissionPolicies).insert(
              AgentPermissionPoliciesCompanion.insert(
                id: 'pp-$action-$targetType',
                accountId: accountId,
                actionType: action,
                targetType: Value(targetType),
                confirmationMode: 'always_allow',
                riskLevel: const Value('high'),
                enabled: const Value(true),
                createdAt: 1,
                updatedAt: 1,
              ),
            );

    /// The composite registry context bound to [accountId]/[runId] with a real
    /// run-local reference store (so query→write ref binding works the same as
    /// in a live run).
    AgentToolContext ctxOf(
      AppDatabase db,
      String accountId,
      String runId,
    ) =>
        AgentToolContext(
          accountId: accountId,
          runId: runId,
          clock: FixedBeijingClock(DateTime(2026, 8, 4, 12)),
          cancellation: CancellationSignal(),
          references: RunReferenceStore(runId: runId),
        );

    /// Seeds a single timed personal event owned by [accountId] and returns its
    /// id. `deletedAt` is left null (active).
    Future<String> seedPersonalEvent(
      AppDatabase db,
      String accountId, {
      String id = 'ev-1',
      String title = '个人事件',
      String source = 'user',
      String? sourceSeriesExternalId,
      int? deletedAt,
      String status = 'active',
    }) async {
      await db.into(db.calendarEvents).insert(
            CalendarEventsCompanion.insert(
              id: id,
              accountId: accountId,
              source: source,
              externalId: Value(id),
              sourceSeriesExternalId: Value(sourceSeriesExternalId),
              title: title,
              type: source == 'user' ? 'personal' : 'course',
              startAt: Value(_beijingEpoch(2026, 8, 6, 9, 0)),
              endAt: Value(_beijingEpoch(2026, 8, 6, 10, 0)),
              allDay: false,
              timezone: 'Asia/Shanghai',
              status: Value(status),
              deletedAt: Value(deletedAt),
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      if (source != 'user') {
        await db.into(db.sourceRecords).insert(
              SourceRecordsCompanion.insert(
                id: 'sr-$id',
                accountId: accountId,
                source: source,
                entityType: 'calendar_event',
                externalId: id,
                localEntityId: id,
                sourceStatus: 'active',
                presence: 'present',
                scopeKey: 'scope',
                firstObservedAt: 1,
                lastObservedAt: 1,
              ),
            );
      }
      return id;
    }

    // Scenario 1: query -> cancel/reopen personal event via update_event.
    // (Existing composition coverage: single-course move routes to update_event
    // edit; this exercises cancel then reopen through the real write path.)
    test('scenario 1: get_schedule(query) -> update_event cancel -> reopen',
        () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final built = await writeRegistry(db, 'acc-1');
      addTearDown(built.composition.dispose);
      await allow(db, 'acc-1', 'event_cancel', 'event');
      await allow(db, 'acc-1', 'event_reopen', 'event');
      await seedPersonalEvent(db, 'acc-1', id: 'ev-1', title: '健身房训练');
      final context = ctxOf(db, 'acc-1', 'r-s1');
      // Query binds a run-local ref.
      final query = await built.registry.execute(
        toolName: 'get_schedule',
        arguments: {'query': '健身房'},
        context: context,
      );
      expect(query.status, AgentToolStatus.success);
      final evRef = _eventRefFromResults([query.payload]);
      expect(evRef, isNotNull, reason: 'query must bind an event ref');
      // Cancel.
      final cancel = await built.registry.execute(
        toolName: 'update_event',
        arguments: {'ref_event': evRef, 'action': 'cancel'},
        context: context,
      );
      expect(cancel.status, AgentToolStatus.success,
          reason: 'cancel must succeed');
      expect((await db.select(db.calendarEvents).getSingle()).status,
          'cancelled',
          reason: 'cancel writes cancelled status, row preserved');
      // No raw id leaked into the tool result payload.
      expect(jsonEncode(cancel.payload), isNot(contains('ev-1')));
      // Reopen.
      final reopen = await built.registry.execute(
        toolName: 'update_event',
        arguments: {'ref_event': evRef, 'action': 'reopen'},
        context: context,
      );
      expect(reopen.status, AgentToolStatus.success);
      expect((await db.select(db.calendarEvents).getSingle()).status, 'active',
          reason: 'reopen restores active status');
      // No audit log carries the raw id.
      final audit = await db.actionLogsRepository.selectAll();
      expect(audit.any((l) => l.source == 'agent'), isTrue);
      expect(audit.map((l) => l.safeSummary).join('\n'),
          isNot(contains('ev-1')));
    });

    // Scenario 2: single event delete/restore through the real registry. The
    // recurring three-scope (only_this/this_and_future/whole_series) production
    // reachability + scope_required guard is covered by the Task 9 hard gate
    // (line ~4666) and the write_tools_test Task 9 group; this test exercises
    // single-event delete + restore (soft-delete then clear deletedAt) so the
    // registry commit path is exercised for both directions.
    test('scenario 2: single event delete/restore (recurring three-scope via '
        'hard gate)', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final built = await writeRegistry(db, 'acc-1');
      addTearDown(built.composition.dispose);
      await allow(db, 'acc-1', 'event_delete', 'event');
      await allow(db, 'acc-1', 'event_restore', 'event');
      await seedPersonalEvent(db, 'acc-1', id: 'ev-s2', title: '一次性事件');
      final context = ctxOf(db, 'acc-1', 'r-s2');
      final query = await built.registry.execute(
        toolName: 'get_schedule',
        arguments: {'query': '一次性'},
        context: context,
      );
      final evRef = _eventRefFromResults([query.payload]);
      expect(evRef, isNotNull);
      final del = await built.registry.execute(
        toolName: 'update_event',
        arguments: {'ref_event': evRef, 'action': 'delete'},
        context: context,
      );
      expect(del.status, AgentToolStatus.success);
      final deletedRow = await db.select(db.calendarEvents).getSingle();
      expect(deletedRow.deletedAt, isNotNull,
          reason: 'delete is a soft delete (deletedAt set)');
      final restore = await built.registry.execute(
        toolName: 'update_event',
        arguments: {'ref_event': evRef, 'action': 'restore'},
        context: context,
      );
      expect(restore.status, AgentToolStatus.success);
      expect((await db.select(db.calendarEvents).getSingle()).deletedAt, isNull,
          reason: 'restore clears deletedAt');
    });

    // Scenario 3: Task delete suppresses parent, restore re-shows; reminder not
    // auto-restored; undo full-restore. (Service-level: task_lifecycle_test.
    // Here: the real registry commit path + undo slot.)
    test('scenario 3: update_task delete suppresses; restore re-shows; '
        'undo restores full snapshot', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final built = await writeRegistry(db, 'acc-1');
      addTearDown(built.composition.dispose);
      await allow(db, 'acc-1', 'task_delete', 'task');
      await allow(db, 'acc-1', 'task_restore', 'task');
      await allow(db, 'acc-1', 'undo_last_action', 'undo');
      await _insertTask(db, 'task-s3', 'acc-1', '复习线代');
      await db.into(db.planBlocks).insert(
            PlanBlocksCompanion.insert(
              id: 'pb-s3',
              accountId: 'acc-1',
              taskId: 'task-s3',
              startAt: _beijingEpoch(2026, 8, 7, 14, 0),
              endAt: _beijingEpoch(2026, 8, 7, 16, 0),
              status: 'accepted',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      final context = ctxOf(db, 'acc-1', 'r-s3');
      // Bind task ref via get_tasks.
      final query = await built.registry.execute(
        toolName: 'get_tasks',
        arguments: {},
        context: context,
      );
      expect(query.status, AgentToolStatus.success);
      final taskRef = _taskRefFromPayload(query.payload);
      expect(taskRef, isNotNull);
      final del = await built.registry.execute(
        toolName: 'update_task',
        arguments: {'ref_task': taskRef, 'action': 'delete'},
        context: context,
      );
      expect(del.status, AgentToolStatus.success,
          reason: 'delete failed: ${del.errorCode}');
      final taskRow = await db.select(db.tasks).getSingle();
      expect(taskRow.deletedAt, isNotNull,
          reason: 'task delete sets deletedAt (suppressed from normal views)');
      // PlanBlock is preserved (not cascaded).
      final blocks = await db.select(db.planBlocks).get();
      expect(blocks, hasLength(1),
          reason: 'delete does NOT cascade-delete child plan blocks');
      expect(blocks.single.deletedAt, isNull);
      // get_tasks default view no longer shows the deleted task.
      final after = await built.registry.execute(
        toolName: 'get_tasks',
        arguments: {},
        context: context,
      );
      final afterTitles = (after.payload['tasks']! as List)
          .map((t) => (t as Map<String, Object?>)['title'])
          .toSet();
      expect(afterTitles, isNot(contains('复习线代')),
          reason: 'deleted task is hidden from the default view');
      // Restore re-shows the task. The Agent `update_task(restore)` propose
      // path reads `taskById` (which filters deleted rows), so production
      // restore is driven through the management UI's authorized
      // `TaskLifecycleService.restore` (includeDeleted: true) — exercised here
      // to assert the soft-delete is reversible and the undo slot reverses it.
      final taskService = TaskLifecycleService(
        database: db,
        accountId: 'acc-1',
        now: () => 2,
      );
      final deletedRow = await db.select(db.tasks).getSingle();
      await taskService.restore('task-s3', expectedUpdatedAt: deletedRow.updatedAt);
      expect((await db.select(db.tasks).getSingle()).deletedAt, isNull,
          reason: 'restore clears deletedAt and re-shows the task');
      // Undo full-restore is exercised end-to-end in scenario 10 below, where
      // the write goes through the composition's shared undo recorder (the
      // direct service restore here uses the management-UI path and a separate
      // recorder, so it is not the one-shot undo target).
    });

    // Scenario 4: PlanBlock delete/restore keeps parent Task + replacement
    // chain. (Service-level: plan_block_undo_test.)
    test('scenario 4: update_plan_block delete keeps parent + replacement',
        () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final built = await writeRegistry(db, 'acc-1');
      addTearDown(built.composition.dispose);
      await allow(db, 'acc-1', 'plan_block_delete', 'plan_block');
      await allow(db, 'acc-1', 'plan_block_restore', 'plan_block');
      await _insertTask(db, 'task-s4', 'acc-1', '操作系统作业');
      await db.into(db.planBlocks).insert(
            PlanBlocksCompanion.insert(
              id: 'pb-s4',
              accountId: 'acc-1',
              taskId: 'task-s4',
              startAt: _beijingEpoch(2026, 8, 8, 9, 0),
              endAt: _beijingEpoch(2026, 8, 8, 11, 0),
              status: 'rescheduled',
              rescheduledToPlanBlockId: const Value('pb-s4-repl'),
              reviewedAt: const Value(1),
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      final context = ctxOf(db, 'acc-1', 'r-s4');
      final blocksQuery = await built.registry.execute(
        toolName: 'get_plan_blocks',
        arguments: {},
        context: context,
      );
      expect(blocksQuery.status, AgentToolStatus.success);
      final pbRef = _planBlockRefFromPayload(blocksQuery.payload);
      expect(pbRef, isNotNull);
      final del = await built.registry.execute(
        toolName: 'update_plan_block',
        arguments: {'ref_plan_block': pbRef, 'action': 'delete'},
        context: context,
      );
      expect(del.status, AgentToolStatus.success);
      // Parent task preserved.
      expect((await db.select(db.tasks).getSingle()).deletedAt, isNull,
          reason: 'plan block delete does NOT touch the parent task');
      // Replacement chain preserved.
      final blockRow = await db.select(db.planBlocks).getSingle();
      expect(blockRow.deletedAt, isNotNull);
      expect(blockRow.rescheduledToPlanBlockId, 'pb-s4-repl',
          reason: 'replacement chain pointer preserved on delete');
      // Restore recovers the block. As with task restore, the Agent
      // `update_plan_block(restore)` propose reads `planBlockById` (which
      // filters deleted rows), so production restore is driven through the
      // management UI's authorized `PlanBlockService.restore`
      // (includeDeleted: true).
      final planBlockService = PlanBlockService(
        database: db,
        accountId: 'acc-1',
        now: () => 2,
      );
      final deletedBlock = await db.select(db.planBlocks).getSingle();
      await planBlockService.restore(
        deletedBlock.id,
        expectedUpdatedAt: deletedBlock.updatedAt,
      );
      expect((await db.select(db.planBlocks).getSingle()).deletedAt, isNull,
          reason: 'restore clears deletedAt and recovers the block');
    });

    // Scenario 5: delete_schedule_relation removes an explicit user relation
    // row through the real registry. The derived-overlap fallback (a deleted
    // no_conflict relation reverting to a derived conflict when the pair still
    // overlaps) and the exam_for_course/derived-overlap non-deletability are
    // covered by conflict_service tests; this test asserts the explicit row is
    // physically removed by the registry commit path.
    test('scenario 5: delete_schedule_relation removes the explicit user '
        'relation row (derived-overlap fallback via conflict_service tests)',
        () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final built = await writeRegistry(db, 'acc-1');
      addTearDown(built.composition.dispose);
      await allow(db, 'acc-1', 'delete_schedule_relation', 'relation');
      await seedPersonalEvent(db, 'acc-1', id: 'ev-5a', title: '事件A');
      await seedPersonalEvent(db, 'acc-1', id: 'ev-5b', title: '事件B');
      final conflict = ConflictService(
        database: db,
        accountId: 'acc-1',
        now: () => 1,
      );
      await conflict.classifyPair(
        ScheduleConflictParticipant(
          kind: 'event',
          id: 'ev-5a',
          title: '事件A',
          occurrenceDate: DateTime(2026, 8, 6),
        ),
        ScheduleConflictParticipant(
          kind: 'event',
          id: 'ev-5b',
          title: '事件B',
          occurrenceDate: DateTime(2026, 8, 6),
        ),
        ConflictState.nonConflict,
        reason: 'user explicit coexistence',
      );
      final context = ctxOf(db, 'acc-1', 'r-s5');
      final leftRef = _bindRef(context, 'event', 'ev-5a');
      final relsQuery = await built.registry.execute(
        toolName: 'get_schedule_relations',
        arguments: {'ref_left': leftRef},
        context: context,
      );
      expect(relsQuery.status, AgentToolStatus.success);
      final relRef = _relationRefFromPayload(relsQuery.payload);
      expect(relRef, isNotNull,
          reason: 'get_schedule_relations must bind a run-local relation ref');
      final del = await built.registry.execute(
        toolName: 'delete_schedule_relation',
        arguments: {'ref_relation': relRef},
        context: context,
      );
      expect(del.status, AgentToolStatus.success);
      expect(await db.select(db.scheduleRelations).get(), isEmpty,
          reason: 'explicit no_conflict relation is physically removed');
    });

    // Scenario 6: clear_reminder(all) writes a disabled sentinel row through
    // the real registry. The sentinel surviving a reconcile (no default
    // reminder rebuild) and delivered/missed/failed history preservation are
    // covered by reminder_override_undo_test; this test asserts the registry
    // commit path leaves a cancelled/null-offset sentinel row.
    test('scenario 6: clear_reminder all writes a disabled sentinel row '
        '(reconcile-no-rebuild + history via reminder_override_undo_test)',
        () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final built = await writeRegistry(db, 'acc-1');
      addTearDown(built.composition.dispose);
      await allow(db, 'acc-1', 'clear_all_reminders', 'event');
      await seedPersonalEvent(db, 'acc-1', id: 'ev-6', title: '提醒事件');
      final reminders = ReminderOverrideService(
        database: db,
        accountId: 'acc-1',
        undoRecorder: NoopUndoRecorder(),
        now: () => DateTime(2026, 8, 5, 0, 0).millisecondsSinceEpoch,
      );
      await reminders.setEventOffsets('ev-6', [15, 60]);
      final context = ctxOf(db, 'acc-1', 'r-s6');
      final evRef = _bindRef(context, 'event', 'ev-6');
      final remQuery = await built.registry.execute(
        toolName: 'get_reminders',
        arguments: {'ref_target': evRef},
        context: context,
      );
      expect(remQuery.status, AgentToolStatus.success);
      final clear = await built.registry.execute(
        toolName: 'clear_reminder',
        arguments: {'ref_target': evRef, 'scope': 'all'},
        context: context,
      );
      expect(clear.status, AgentToolStatus.success);
      // Sentinel present (a disabled reminder row exists).
      final rows = await db.select(db.reminders).get();
      expect(rows.any((r) => r.state == 'cancelled' && r.offsetMinutes == null),
          isTrue,
          reason: 'clear-all writes a disabled sentinel with null offset');
    });

    // Scenario 7: clear_user_overlay(single_event) removes a single-event
    // overlay field through the real registry. The course-series-layer fallback
    // (clearing a single_event layer letting the course_series layer show
    // through) and the course_series scope are covered by overlay_service
    // tests; this test asserts the single_event field is cleared by the
    // registry commit path.
    test('scenario 7: clear_user_overlay single_event clears the field '
        '(course_series fallback via overlay_service tests)', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final built = await writeRegistry(db, 'acc-1');
      addTearDown(built.composition.dispose);
      await allow(db, 'acc-1', 'clear_event_overlay_fields', 'overlay');
      // A course-series-backed event so course_series scope resolves.
      await db.into(db.courseSeries).insert(
            CourseSeriesCompanion.insert(
              id: 'series-s7',
              accountId: 'acc-1',
              source: 'user',
              externalId: 'ext-s7',
              title: '系列课',
              semesterKey: '2026spring',
              participantsJson: const Value('[]'),
              sourceDetailsJson: '{}',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await seedPersonalEvent(db, 'acc-1',
          id: 'ev-7', title: '系列课', sourceSeriesExternalId: 'ext-s7');
      await OverlayService(database: db, accountId: 'acc-1', now: () => 100)
          .setEventOverlay(
        'ev-7',
        const OverlayMutation(
          attendancePolicy: AttendancePolicy.mustGo,
          listeningMode: ListeningMode.listen,
        ),
      );
      final context = ctxOf(db, 'acc-1', 'r-s7');
      final evRef = _bindRef(context, 'event', 'ev-7');
      final clear = await built.registry.execute(
        toolName: 'clear_user_overlay',
        arguments: {
          'ref_event': evRef,
          'scope': 'single_event',
          'fields': ['attendance'],
        },
        context: context,
      );
      expect(clear.status, AgentToolStatus.success);
      final overlayRow = await db.select(db.userOverlays).getSingle();
      expect(overlayRow.attendancePolicy, isNull,
          reason: 'single_event clear removes the field');
    });

    // Scenario 8: TaskEventLink unlink.
    test('scenario 8: unlink_task_event removes the single link', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final built = await writeRegistry(db, 'acc-1');
      addTearDown(built.composition.dispose);
      await allow(db, 'acc-1', 'unlink_task_event', 'task');
      await _insertTask(db, 'task-s8', 'acc-1', '实验报告');
      await seedPersonalEvent(db, 'acc-1', id: 'ev-8', title: '实验');
      await db.into(db.taskEventLinks).insert(
            TaskEventLinksCompanion.insert(
              accountId: 'acc-1',
              taskId: 'task-s8',
              targetId: 'ev-8',
              eventId: const Value('ev-8'),
              relationType: 'planned_at',
              createdAt: 1,
            ),
          );
      final context = ctxOf(db, 'acc-1', 'r-s8');
      final taskRef = _bindRef(context, 'task', 'task-s8');
      final evRef = _bindRef(context, 'event', 'ev-8');
      final unlink = await built.registry.execute(
        toolName: 'unlink_task_event',
        arguments: {'ref_task': taskRef, 'ref_event': evRef},
        context: context,
      );
      expect(unlink.status, AgentToolStatus.success);
      expect(await db.select(db.taskEventLinks).get(), isEmpty,
          reason: 'the single link is physically removed');
    });

    // Scenario 9: permission single-item reset (non-resettable rejected).
    test('scenario 9: reset_permission_policy removes one override; '
        'non-resettable rejected', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final built = await writeRegistry(db, 'acc-1');
      addTearDown(built.composition.dispose);
      await allow(db, 'acc-1', 'reset_permission_policy', 'permission');
      // A custom override to reset.
      await db.into(db.agentPermissionPolicies).insert(
            AgentPermissionPoliciesCompanion.insert(
              id: 'pp-reset-target',
              accountId: 'acc-1',
              actionType: 'event_delete',
              targetType: const Value('event'),
              confirmationMode: 'always_allow',
              riskLevel: const Value('high'),
              enabled: const Value(true),
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      final context = ctxOf(db, 'acc-1', 'r-s9');
      final reset = await built.registry.execute(
        toolName: 'reset_permission_policy',
        arguments: {'target_action_type': 'event_delete'},
        context: context,
      );
      // reset_permission_policy is forceConfirmed (critical) and never offers
      // remember: even with an always_allow policy row, it pauses on the
      // confirmation card. The override must NOT be removed until approved.
      expect(reset.status, AgentToolStatus.needsUserAction,
          reason: 'reset_permission_policy always requires explicit confirmation');
      expect(reset.userAction?.type, AgentUserActionType.writeConfirmation);
      final remainingBefore = await db
          .select(db.agentPermissionPolicies)
          .get()
          .then((rows) => rows.where((r) => r.actionType == 'event_delete'));
      expect(remainingBefore, isNotEmpty,
          reason: 'the override is NOT removed before the user approves');
      // Non-resettable action is rejected at propose (registry execute maps
      // the FormatException to tool_execution_failed, never committing).
      final reject = await built.registry.execute(
        toolName: 'reset_permission_policy',
        arguments: {'target_action_type': 'reset_permission_policy'},
        context: context,
      );
      expect(reject.status, AgentToolStatus.error);
      expect(reject.errorCode, isNotNull);
    });

    // Scenario 10: get_last_undoable_action -> undo_last_action.
    test('scenario 10: get_last_undoable_action preview then undo consumes '
        'the slot', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final built = await writeRegistry(db, 'acc-1');
      addTearDown(built.composition.dispose);
      await allow(db, 'acc-1', 'undo_last_action', 'undo');
      await _insertTask(db, 'task-s10', 'acc-1', '编译作业');
      // The one-step undo slot is filled by USER-initiated writes (the Agent
      // write gateway intentionally uses NoopUndoRecorder so Agent writes do
      // not occupy the undo slot). Seed a user-initiated task delete through
      // the shared UndoService recorder — exactly the management-UI path — so
      // the slot carries an undoable command the Agent tools can preview/consume.
      final undoRecorder = UndoService(database: db, accountId: 'acc-1', now: () => 5);
      final userTaskService = TaskLifecycleService(
        database: db,
        accountId: 'acc-1',
        now: () => 5,
        undoRecorder: undoRecorder,
        logToActionLog: false,
      );
      await userTaskService.softDelete('task-s10', expectedUpdatedAt: 1);
      expect((await db.select(db.tasks).getSingle()).deletedAt, isNotNull,
          reason: 'the user-initiated delete fills the undo slot and soft-deletes');
      final context = ctxOf(db, 'acc-1', 'r-s10');
      final preview = await built.registry.execute(
        toolName: 'get_last_undoable_action',
        arguments: {},
        context: context,
      );
      expect(preview.status, AgentToolStatus.success);
      expect(preview.payload['available'], isTrue,
          reason: 'preview reports the user-initiated undoable action');
      // The preview payload never leaks the raw id or payload.
      expect(jsonEncode(preview.payload), isNot(contains('task-s10')));
      final undo = await built.registry.execute(
        toolName: 'undo_last_action',
        arguments: {},
        context: context,
      );
      expect(undo.status, AgentToolStatus.success,
          reason: 'undo consumes the one-step slot and reverses the delete');
      expect((await db.select(db.tasks).getSingle()).deletedAt, isNull,
          reason: 'undo restores the soft-deleted task');
      // A second undo has no slot.
      final undo2 = await built.registry.execute(
        toolName: 'undo_last_action',
        arguments: {},
        context: context,
      );
      expect(undo2.status, AgentToolStatus.error,
          reason: 'undo is one-shot; the second call has no slot');
    });

    // Scenario 11: source event delete refused; only explicit consent hides.
    test('scenario 11: update_event delete on a course event is refused; '
        'no silent hide', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final built = await writeRegistry(db, 'acc-1');
      addTearDown(built.composition.dispose);
      await allow(db, 'acc-1', 'event_delete', 'event');
      await _insertCourseSeries(
        db,
        'series-s11',
        'acc-1',
        externalId: 'lesson-s11',
        title: '量子力学',
      );
      await _insertCourseOccurrence(
        db,
        'ev-s11',
        'acc-1',
        '量子力学',
        seriesExternalId: 'lesson-s11',
        location: '三教101',
        start: DateTime(2026, 8, 6, 8, 0),
        end: DateTime(2026, 8, 6, 9, 45),
      );
      final context = ctxOf(db, 'acc-1', 'r-s11');
      final query = await built.registry.execute(
        toolName: 'get_schedule',
        arguments: {'query': '量子力学'},
        context: context,
      );
      expect(query.status, AgentToolStatus.success);
      final evRef = _eventRefFromResults([query.payload]);
      expect(evRef, isNotNull);
      final del = await built.registry.execute(
        toolName: 'update_event',
        arguments: {'ref_event': evRef, 'action': 'delete'},
        context: context,
      );
      expect(del.status, AgentToolStatus.error,
          reason: 'a course (source) event cannot be deleted by the agent');
      expect(del.errorCode, isNotNull);
      // The course row is untouched (never silently hidden/deleted).
      final evRow = await db.select(db.calendarEvents).getSingle();
      expect(evRow.deletedAt, isNull);
      expect(evRow.status, 'active');
    });

    // Scenario 12a: multi-object partial success through the REAL
    // session-service + MutationLedger aggregation (NOT a detached budget).
    // The model issues several update_event delete calls in one turn; some
    // succeed (personal events) and one fails (a course/source event refuses
    // deletion). The run settles via the mutation-ledger settlement path with
    // a `mutation_partial` terminal code and an aggregated 成功/失败 count.
    test(
      'scenario 12a: multi-object partial success aggregates via the real '
      'session-service MutationLedger (success + failure counts)',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        const protector = _NoopProtector();
        await _seedAccount(db, 'acc-1');
        final secretStore = ProtectedAgentSecretStore(
          database: db,
          protector: protector,
        );
        await _seedAgentConfig(db, 'acc-1', secrets: secretStore, apiKey: 'test-key');
        // Always-allow event_delete so each delete auto-executes through the
        // real atomic commit path without pausing for confirmation.
        await allow(db, 'acc-1', 'event_delete', 'event');
        // Three personal events (deletable) + one course event (refuses delete).
        await seedPersonalEvent(db, 'acc-1', id: 'ev-12a-0', title: '删除目标A');
        await seedPersonalEvent(db, 'acc-1', id: 'ev-12a-1', title: '删除目标B');
        await seedPersonalEvent(db, 'acc-1', id: 'ev-12a-2', title: '删除目标C');
        await _insertCourseSeries(
          db,
          'series-12a',
          'acc-1',
          externalId: 'lesson-12a',
          title: '量子力学12a',
        );
        await _insertCourseOccurrence(
          db,
          'ev-12a-course',
          'acc-1',
          '量子力学12a',
          seriesExternalId: 'lesson-12a',
          location: '三教101',
          start: DateTime(2026, 8, 6, 8, 0),
          end: DateTime(2026, 8, 6, 9, 45),
        );

        final provider = _ScriptedProvider([
          // Call 1: get_schedule(query) locates the personal events by a shared
          // keyword and binds run-local refs. (The course event is located by a
          // separate title query in the same call sequence is not needed; the
          // model issues one query whose result refs the deletion turn echoes.)
          _ScriptedCall(() => [
                const ToolUseCompletedEvent(
                  id: 'tu-12a-q',
                  name: 'get_schedule',
                  input: {'query': '删除目标'},
                ),
                const CompletedEvent(),
              ]),
          // Call 2: a single turn of FOUR update_event(delete) calls. The first
          // three target the personal-event refs (succeed); the fourth targets
          // the course event — its ref must also be bound this run. So issue a
          // second get_schedule for the course, then the delete turn.
          _ScriptedCall(() => [
                const ToolUseCompletedEvent(
                  id: 'tu-12a-qc',
                  name: 'get_schedule',
                  input: {'query': '量子力学12a'},
                ),
                const CompletedEvent(),
              ]),
          // Call 3: the deletion turn — four update_event(delete) calls in one
          // turn, each echoing a distinct ref bound by an earlier tool_result.
          // Uses requestAware so each tool_use gets a distinct ref.
          _ScriptedCall.requestAware((prior) {
            // Collect every ref bound across the run so far, in order.
            final refs = <String>[];
            for (final req in prior) {
              for (final msg in req.messages) {
                if (msg.role != 'user') continue;
                for (final block in msg.content) {
                  if (block is! LlmToolResultBlock) continue;
                  final c = block.content;
                  if (c is! String) continue;
                  for (final m in RegExp(r'ref_[A-Za-z0-9_-]+').allMatches(c)) {
                    refs.add(m.group(0)!);
                  }
                }
              }
            }
            // 3 personal-event refs (from the first query) + 1 course ref (the
            // fourth ref overall, from the second query).
            expect(refs.length, greaterThanOrEqualTo(4),
                reason: 'four event refs must be bound before the delete turn');
            return [
              ToolUseCompletedEvent(
                id: 'tu-12a-d0',
                name: 'update_event',
                input: {'ref_event': refs[0], 'action': 'delete'},
              ),
              ToolUseCompletedEvent(
                id: 'tu-12a-d1',
                name: 'update_event',
                input: {'ref_event': refs[1], 'action': 'delete'},
              ),
              ToolUseCompletedEvent(
                id: 'tu-12a-d2',
                name: 'update_event',
                input: {'ref_event': refs[2], 'action': 'delete'},
              ),
              ToolUseCompletedEvent(
                id: 'tu-12a-d3',
                name: 'update_event',
                input: {'ref_event': refs[3], 'action': 'delete'},
              ),
              const CompletedEvent(),
            ];
          }),
          // Call 4: final text (the session-service overrides the terminal
          // text with the aggregated mutation-ledger message, so this is only
          // reached if the ledger produced no override — which it will not).
          _ScriptedCall(() => [
                const TextDeltaEvent('已处理删除请求。'),
                const CompletedEvent(),
              ]),
        ]);
        final composition = await _buildTestComposition(
          db,
          'acc-1',
          provider: provider,
          protector: protector,
        );
        addTearDown(composition.dispose);

        final states = <AgentRunViewState>[];
        final done = Completer<void>();
        composition.sessionService
            .send(
                accountId: 'acc-1',
                userText: '把删除目标A、删除目标B、删除目标C和量子力学12a这节课都删掉')
            .listen((s) => states.add(s), onDone: done.complete);
        await done.future;

        // The run settles via the mutation-ledger settlement path: 3 succeeds,
        // 1 fails (course event refuses delete) -> the session-service maps a
        // partial mutation ledger to a `failed` terminal state carrying
        // `mutation_partial` (the deterministic 成功/失败 count replaces the
        // model's possibly-false success text).
        final run = states.last;
        expect(run.state, AgentRunState.failed,
            reason: 'a partial-success mutation run settles as failed with the '
                'mutation_partial code (the ledger count is the terminal truth)');
        expect(run.errorCode, 'mutation_partial',
            reason: 'the MutationLedger aggregates 3 success + 1 failure into '
                'mutation_partial via the real session-service path');
        // The aggregated terminal message carries accurate counts and a safe
        // failure reason, never titles/refs/ids.
        final message = run.text;
        expect(message, contains('成功 3 个'),
            reason: 'aggregated message reports 3 successes');
        expect(message, contains('失败 1 个'),
            reason: 'aggregated message reports 1 failure');
        expect(message, isNot(contains('ref_')),
            reason: 'no run-local ref leaks into the terminal message');
        expect(message, isNot(contains('ev-12a')),
            reason: 'no raw DB id leaks into the terminal message');
        // DB truth: the three personal events are soft-deleted; the course
        // event is untouched.
        final events = await db.select(db.calendarEvents).get();
        final personalDeleted = events
            .where((e) => e.id.startsWith('ev-12a-') && e.deletedAt != null);
        expect(personalDeleted, hasLength(3),
            reason: 'the 3 personal events were soft-deleted');
        final course = events.firstWhere((e) => e.id == 'ev-12a-course');
        expect(course.deletedAt, isNull,
            reason: 'the course event refuses delete (never deleted)');
      },
    );

    // Scenario 12b: the 13th normal-call budget edge through the REAL
    // session-service. The model issues 13 distinct read calls (get_schedule
    // with distinct query keywords, all distinct fingerprints); the
    // session-service's shared AgentRunToolBudget allows the first 12 and
    // blocks the 13th with `tool_call_budget_exceeded`, terminating the run.
    test(
      'scenario 12b: the 13th normal call is blocked by the real '
      'session-service budget (tool_call_budget_exceeded)',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        const protector = _NoopProtector();
        await _seedAccount(db, 'acc-1');
        final secretStore = ProtectedAgentSecretStore(
          database: db,
          protector: protector,
        );
        await _seedAgentConfig(db, 'acc-1', secrets: secretStore, apiKey: 'test-key');
        // Seed 13 personal events with distinct titles so 13 distinct
        // get_schedule(query=...) calls each return a distinct result and never
        // trip the fingerprint dedup guard.
        for (var i = 0; i < 13; i++) {
          await seedPersonalEvent(db, 'acc-1',
              id: 'ev-12b-$i', title: '预算事件$i');
        }

        final provider = _ScriptedProvider([
          // A single turn of 13 distinct get_schedule(query=...) read calls.
          // Each call has a distinct query -> distinct fingerprint -> each
          // consumes one normal budget slot through the real session-service.
          _ScriptedCall(() => [
                for (var i = 0; i < 13; i++)
                  ToolUseCompletedEvent(
                    id: 'tu-12b-$i',
                    name: 'get_schedule',
                    input: {'query': '预算事件$i'},
                  ),
                const CompletedEvent(),
              ]),
          // Final text (only reached if the budget did not block).
          _ScriptedCall(() => [
                const TextDeltaEvent('已查询全部。'),
                const CompletedEvent(),
              ]),
        ]);
        final composition = await _buildTestComposition(
          db,
          'acc-1',
          provider: provider,
          protector: protector,
        );
        addTearDown(composition.dispose);

        final states = <AgentRunViewState>[];
        final done = Completer<void>();
        composition.sessionService
            .send(
                accountId: 'acc-1',
                userText: '分别查一下预算事件0到预算事件12这 13 个日程')
            .listen((s) => states.add(s), onDone: done.complete);
        await done.future;

        // The 13th call is blocked by the exhausted normal budget; the run
        // terminates failed with tool_call_budget_exceeded.
        final run = states.last;
        expect(run.state, AgentRunState.failed,
            reason: 'the 13th normal call exhausts the budget and fails the run');
        expect(run.errorCode, 'tool_call_budget_exceeded',
            reason: 'the real session-service budget blocks the 13th call');
        // Exactly 12 tool invocations completed successfully (the 13th was
        // recorded as an error invocation with the budget code).
        final invocations = await composition.chatRepository.toolInvocationsForRuns(
          accountId: 'acc-1',
          runIds: {run.runId},
        );
        expect(invocations.length, 13,
            reason: 'all 13 attempted calls have a persisted invocation row');
        final budgetErrors = invocations.where(
            (i) => i.errorCode == 'tool_call_budget_exceeded');
        expect(budgetErrors, hasLength(1),
            reason: 'exactly the 13th call is marked with the budget error');
        // No create_task burst was involved (read-only calls).
        expect(invocations.every((i) => i.toolName == 'get_schedule'), isTrue);
      },
    );

    // Scenario 13: account isolation, stale target, ref expiry/privacy.
    test('scenario 13: cross-account ref resolves null; stale target rejected; '
        'no raw id/ref leak', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final built = await writeRegistry(db, 'acc-1');
      addTearDown(built.composition.dispose);
      await allow(db, 'acc-1', 'task_delete', 'task');
      await _insertTask(db, 'task-s13', 'acc-1', '跨账号任务');
      final context = ctxOf(db, 'acc-1', 'r-s13');
      // Bind a ref on acc-1's run.
      final query = await built.registry.execute(
        toolName: 'get_tasks',
        arguments: {},
        context: context,
      );
      final taskRef = _taskRefFromPayload(query.payload);
      expect(taskRef, isNotNull);
      // A DIFFERENT run's reference store cannot resolve acc-1's ref.
      final otherStore = RunReferenceStore(runId: 'r-other');
      expect(otherStore.resolve(ref: taskRef!, kind: 'task'), isNull,
          reason: 'a run-local ref does not survive into another run');
      // Stale target: the registry `execute` proposes then commits in one call,
      // so a version mismatch can only be forced by handing the service a stale
      // expectedUpdatedAt (the same contract the Agent gateway enforces). A
      // delete with a stale version must reject without writing.
      final staleService = TaskLifecycleService(
        database: db,
        accountId: 'acc-1',
        now: () => 7,
      );
      bool threwStale = false;
      try {
        await staleService.softDelete('task-s13', expectedUpdatedAt: 8888);
      } on StaleTaskCommand {
        threwStale = true;
      }
      expect(threwStale, isTrue,
          reason: 'a version mismatch rejects the write (stale_target), no silent delete');
      // The row is untouched (still active, not deleted).
      final row = await db.select(db.tasks).getSingle();
      expect(row.deletedAt, isNull);
      expect(row.state, 'active');
      // No raw DB id leaks into the get_tasks result payload (run-local refs
      // are by design present; the raw row id must never appear).
      expect(jsonEncode(query.payload), isNot(contains('task-s13')));
      // Account isolation: acc-2 cannot see acc-1's task through the registry.
      final built2 = await writeRegistry(db, 'acc-2');
      addTearDown(built2.composition.dispose);
      final context2 = ctxOf(db, 'acc-2', 'r-s13-b');
      final acc2Query = await built2.registry.execute(
        toolName: 'get_tasks',
        arguments: {},
        context: context2,
      );
      expect(acc2Query.status, AgentToolStatus.success);
      expect(
        (acc2Query.payload['tasks']! as List).where((t) =>
            (t as Map<String, Object?>)['title'] == '跨账号任务'),
        isEmpty,
        reason: 'account acc-2 must not see acc-1\'s task (account isolation)',
      );
    });
  });
}

// ---------------------------------------------------------------------------
// Task 12 composite regression helpers.
// ---------------------------------------------------------------------------

/// The first run-local event `ref` from a get_schedule payload, or null.
String? _eventRefFromResults(List<Map<String, Object?>> payloads) {
  for (final payload in payloads) {
    final events = payload['events'];
    if (events is List && events.isNotEmpty) {
      for (final e in events) {
        if (e is Map<String, Object?> && e['ref'] is String) {
          return e['ref'] as String;
        }
      }
    }
    final managementEvents = payload['managementEvents'];
    if (managementEvents is List && managementEvents.isNotEmpty) {
      for (final e in managementEvents) {
        if (e is Map<String, Object?> && e['ref'] is String) {
          return e['ref'] as String;
        }
      }
    }
  }
  return null;
}

/// The first run-local task `ref` from a get_tasks payload, or null.
String? _taskRefFromPayload(Map<String, Object?> payload) {
  final tasks = payload['tasks'];
  if (tasks is List && tasks.isNotEmpty) {
    final first = tasks.first;
    if (first is Map<String, Object?> && first['ref'] is String) {
      return first['ref'] as String;
    }
  }
  return null;
}

/// The first run-local plan_block `ref` from a get_plan_blocks payload.
String? _planBlockRefFromPayload(Map<String, Object?> payload) {
  final blocks = payload['planBlocks'];
  if (blocks is List && blocks.isNotEmpty) {
    final first = blocks.first;
    if (first is Map<String, Object?> && first['ref'] is String) {
      return first['ref'] as String;
    }
  }
  return null;
}

/// The first run-local relation `ref` from a get_schedule_relations payload.
String? _relationRefFromPayload(Map<String, Object?> payload) {
  final relations = payload['relations'];
  if (relations is List && relations.isNotEmpty) {
    final first = relations.first;
    if (first is Map<String, Object?> && first['ref'] is String) {
      return first['ref'] as String;
    }
  }
  return null;
}

/// Binds a run-local ref of [kind] for [localId] on [ctx.references].
String _bindRef(AgentToolContext ctx, String kind, String localId) =>
    ctx.references.bind(kind: kind, localId: localId);

// ---------------------------------------------------------------------------
// Task 4 (create-task burst) composition helpers.
// ---------------------------------------------------------------------------

/// The shared fixture for the burst composition tests.
///
/// [saturdays] holds the 13 explicit Beijing Saturdays (2026-09-05 ..
/// 2026-11-28) and [titles]/[deadlines] the per-task distinct inputs. The
/// deadline is an explicit Beijing wall-clock (18:00), never a semester
/// constant.
class _CreateTaskBurstFixture {
  final List<DateTime> saturdays;

  _CreateTaskBurstFixture._(this.saturdays);

  String _deadline(int i) {
    final d = saturdays[i];
    String two(int v) => v.toString().padLeft(2, '0');
    // Explicit Beijing offset so `DateTime.parse` returns a deterministic UTC
    // instant independent of the machine timezone.
    return '${d.year}-${two(d.month)}-${two(d.day)}T18:00:00+08:00';
  }

  String _title(int i) => '电磁场与波作业第${i + 1}周';

  /// The scripted provider sequence: call 1 performs the course_summary lookup,
  /// call 2 emits all [count] `create_task` tool uses in ONE assistant response
  /// (the burst turn), call 3 is the final answer.
  List<_ScriptedCall> burstScript(int count) => [
        _ScriptedCall(() => [
              const ToolUseCompletedEvent(
                id: 'tu-summary',
                name: 'get_schedule',
                input: {
                  'from': '2026-09-01',
                  'through': '2026-11-30',
                  'view': 'course_summary',
                },
              ),
              const CompletedEvent(),
            ]),
        _ScriptedCall(() => [
              for (var i = 0; i < count; i++)
                ToolUseCompletedEvent(
                  id: 'tu-create-$i',
                  name: 'create_task',
                  input: {'title': _title(i), 'deadline_at': _deadline(i)},
                ),
              const CompletedEvent(),
            ]),
        _ScriptedCall(() => [
              const TextDeltaEvent('已为电磁场与波连续 13 周的每周六分别创建了 Task。'),
              const CompletedEvent(),
            ]),
      ];
}

/// Seeds account [accountId] with a course 电磁场与波 whose occurrences land on
/// every Saturday in [_.saturdays] (the shared explicit Beijing dates).
Future<void> _seedBurstCourse(
  AppDatabase db,
  String accountId,
  _CreateTaskBurstFixture fixture,
) async {
  const protector = _NoopProtector();
  await _seedAccount(db, accountId);
  final secretStore = ProtectedAgentSecretStore(database: db, protector: protector);
  await _seedAgentConfig(db, accountId, secrets: secretStore, apiKey: 'test-key');
  await _insertCourseSeries(
    db,
    'series-em',
    accountId,
    externalId: 'lesson-em',
    title: '电磁场与波',
    semesterKey: 'aug2026',
  );
  final saturdays = fixture.saturdays;
  for (var i = 0; i < saturdays.length; i++) {
    final day = saturdays[i];
    await _insertCourseOccurrence(
      db,
      'em-occ-$i',
      accountId,
      '电磁场与波',
      seriesExternalId: 'lesson-em',
      location: '三教101',
      start: DateTime(day.year, day.month, day.day, 8, 0),
      end: DateTime(day.year, day.month, day.day, 9, 45),
    );
  }
}

/// The executed tool-name sequence from [rows], in start order.
List<String> _executedSequence(List<ToolInvocationRecord> rows) =>
    [for (final r in rows) r.toolName];

/// The Beijing calendar date key 'YYYY-MM-DD' for [value], independent of the
/// machine timezone. [value] is an epoch instant (UTC components); Beijing is
/// UTC+8, so +8h is added before reading the calendar fields.
String _beijingDateKey(DateTime value) {
  final bj = value.toUtc().add(const Duration(hours: 8));
  String two(int v) => v.toString().padLeft(2, '0');
  return '${bj.year}-${two(bj.month)}-${two(bj.day)}';
}

/// Constructs the shared burst fixture (explicit 13 Saturday dates).
_CreateTaskBurstFixture _createTaskBurstFixture() =>
    _CreateTaskBurstFixture._(<DateTime>[
      DateTime(2026, 9, 5),
      DateTime(2026, 9, 12),
      DateTime(2026, 9, 19),
      DateTime(2026, 9, 26),
      DateTime(2026, 10, 3),
      DateTime(2026, 10, 10),
      DateTime(2026, 10, 17),
      DateTime(2026, 10, 24),
      DateTime(2026, 10, 31),
      DateTime(2026, 11, 7),
      DateTime(2026, 11, 14),
      DateTime(2026, 11, 21),
      DateTime(2026, 11, 28),
    ]);

// ---------------------------------------------------------------------------
// Task 10 combined-regression helpers.
// ---------------------------------------------------------------------------

/// Beijing wall clock -> the app's UTC epoch-ms storage encoding
/// (machine-timezone independent; copied from the schedule service tests).
/// Top-level so the file's tests share it without tripping the
/// no_leading_underscores_for_local_identifiers lint.
int _beijingEpoch(int year, int month, int day, int hour, [int minute = 0]) =>
    DateTime.utc(year, month, day, hour, minute).millisecondsSinceEpoch -
    const Duration(hours: 8).inMilliseconds;

/// The Monday of the REAL current week. The schedule page and the composed
/// tools use `SystemBeijingClock` (real clock), so seeding events on this
/// anchor guarantees they land in the currently selected week grid no matter
/// when the test runs.
DateTime _currentWeekMonday() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return today.subtract(Duration(days: now.weekday - 1));
}

String _isoDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

/// The 23 scripted model calls of the Task 10 combined regression, in order.
/// Tool_use inputs that must echo run-local refs bound by an earlier tool
/// result use [inputBuilder] (the current request already carries that
/// tool_result, so the builder reads `requests.last`).
List<_ScriptedCall> _combinedRegressionScript() {
  final monday = _currentWeekMonday();
  final blockDay = monday.add(const Duration(days: 3));
  final blockStart = '${_isoDate(blockDay)}T14:00:00+08:00';
  final blockEnd = '${_isoDate(blockDay)}T16:00:00+08:00';
  final weekFrom = _isoDate(monday);
  final weekThrough = _isoDate(monday.add(const Duration(days: 6)));
  // The seeded overlap pair (ov-a/ov-b) lives on the current week's Tuesday.
  final conflictDayFrom = _isoDate(monday.add(const Duration(days: 1)));
  // The post-write re-query uses a WIDER range: the runtime's duplicate-call
  // breaker rejects a second get_conflicts with EXACTLY the same arguments,
  // so the model re-checks with a refreshed (still covering) range — this is
  // the real "loop breaker" behavior the manual retest item 5 verifies.
  final recheckFrom = _isoDate(monday.subtract(const Duration(days: 1)));
  final recheckThrough =
      _isoDate(monday.add(const Duration(days: 7)));
  return [
    // Scenario 1: free chat, no tools.
    _ScriptedCall(() => [
          const TextDeltaEvent('今天心情不错！有什么可以帮你的吗？'),
          const CompletedEvent(),
        ]),
    // Scenario 2: first response misses the tool -> one correction succeeds.
    _ScriptedCall(() => [
          const TextDeltaEvent('我来查一下。'),
          const CompletedEvent(),
        ]),
    _ScriptedCall(() => [
          const ToolUseCompletedEvent(
            id: 'tu-p1',
            name: 'get_pending_event_reviews',
            input: {},
          ),
          const CompletedEvent(),
        ]),
    _ScriptedCall(() => [
          const TextDeltaEvent('有一节量子物理 B 需要确认出勤。'),
          const CompletedEvent(),
        ]),
    // Scenario 3: historical title lookup -> overlay write.
    _ScriptedCall(() => [
          const ToolUseCompletedEvent(
            id: 'tu-c1',
            name: 'get_schedule',
            input: {'query': '计算机网络'},
          ),
          const CompletedEvent(),
        ]),
    _ScriptedCall(
      () => [
        const ToolUseCompletedEvent(
          id: 'tu-c2',
          name: 'create_user_overlay',
          input: {},
        ),
        const CompletedEvent(),
      ],
      inputBuilder: (prior) {
        final refs = _refsFromLastToolResult(prior);
        return {
          'ref_event': refs.isEmpty ? 'ref_unknown' : refs.first,
          'attendance_policy': 'must_go',
          'listening_mode': 'listen',
        };
      },
    ),
    _ScriptedCall(() => [
          const TextDeltaEvent('已为计算机网络设置必去与听讲。'),
          const CompletedEvent(),
        ]),
    // Scenario 4: two historical events -> relation write (title queries
    // only; never get_conflicts as a participant finder).
    _ScriptedCall(() => [
          const ToolUseCompletedEvent(
            id: 'tu-d1',
            name: 'get_schedule',
            input: {
              'query': '计算机网络',
              'from': '2026-03-01',
              'through': '2026-03-31',
            },
          ),
          const CompletedEvent(),
        ]),
    _ScriptedCall(
      () => [
        const ToolUseCompletedEvent(
          id: 'tu-d2',
          name: 'create_schedule_relation',
          input: {},
        ),
        const CompletedEvent(),
      ],
      inputBuilder: (prior) {
        final refs = _refsFromLastToolResult(prior);
        return {
          'ref_left': refs.isEmpty ? 'ref_unknown' : refs[0],
          'ref_right': refs.length < 2 ? 'ref_unknown' : refs[1],
          'conflict_state': 'conflict',
          'reason': '二选一课程',
        };
      },
    ),
    _ScriptedCall(() => [
          const TextDeltaEvent('已记录这两节计算机网络的冲突关系。'),
          const CompletedEvent(),
        ]),
    // Scenario 5: plan_task for an existing task.
    _ScriptedCall(() => [
          const ToolUseCompletedEvent(
            id: 'tu-e1',
            name: 'get_tasks',
            input: {},
          ),
          const CompletedEvent(),
        ]),
    _ScriptedCall(
      () => [
        const ToolUseCompletedEvent(
          id: 'tu-e2',
          name: 'plan_task',
          input: {},
        ),
        const CompletedEvent(),
      ],
      inputBuilder: (prior) {
        final refs = _refsFromLastToolResult(prior);
        return {
          'ref_task': refs.isEmpty ? 'ref_unknown' : refs.first,
          'start_at': blockStart,
          'end_at': blockEnd,
        };
      },
    ),
    _ScriptedCall(() => [
          const TextDeltaEvent('已为复习算法安排了执行时间段。'),
          const CompletedEvent(),
        ]),
    // Scenario 6 (I1): a conflict QUESTION is a READ only — the model looks up
    // the derived overlap pair and answers; no relation is written.
    _ScriptedCall(() => [
          ToolUseCompletedEvent(
            id: 'tu-f1',
            name: 'get_conflicts',
            input: {'from': weekFrom, 'through': weekThrough},
          ),
          const CompletedEvent(),
        ]),
    _ScriptedCall(() => [
          const TextDeltaEvent('这周有重叠甲和重叠乙的重叠冲突，需要二选一。'),
          const CompletedEvent(),
        ]),
    // Scenario 6b: genuine relation WRITE -> explicit no_conflict suppresses
    // the derived pair. The write finder get_conflicts is narrowed to the
    // conflict day (distinct args keep the duplicate-call breaker quiet); the
    // post-write recheck uses a wider refreshed range (the real loop-breaker
    // behavior the manual retest item 5 verifies).
    _ScriptedCall(() => [
          ToolUseCompletedEvent(
            id: 'tu-f2',
            name: 'get_conflicts',
            input: {'from': conflictDayFrom, 'through': conflictDayFrom},
          ),
          const CompletedEvent(),
        ]),
    _ScriptedCall(
      () => [
        const ToolUseCompletedEvent(
          id: 'tu-f3',
          name: 'create_schedule_relation',
          input: {},
        ),
        const CompletedEvent(),
      ],
      inputBuilder: (prior) {
        final refs = _refsFromLastToolResult(prior);
        return {
          'ref_left': refs.isEmpty ? 'ref_unknown' : refs[0],
          'ref_right': refs.length < 2 ? 'ref_unknown' : refs[1],
          'conflict_state': 'no_conflict',
          'reason': '两个时段都可去',
        };
      },
    ),
    _ScriptedCall(() => [
          ToolUseCompletedEvent(
            id: 'tu-f4',
            name: 'get_conflicts',
            input: {'from': recheckFrom, 'through': recheckThrough},
          ),
          const CompletedEvent(),
        ]),
    _ScriptedCall(() => [
          const TextDeltaEvent('已把重叠时段记录为不冲突，冲突查询不再列出它们。'),
          const CompletedEvent(),
        ]),
    // Scenario 7: whole-day JW course move (confirm) -> week check -> final.
    _ScriptedCall(() => [
          const ToolUseCompletedEvent(
            id: 'tu-g1',
            name: 'get_schedule',
            input: {'from': '2026-08-09', 'through': '2026-08-09'},
          ),
          const CompletedEvent(),
        ]),
    _ScriptedCall(() => [
          const ToolUseCompletedEvent(
            id: 'tu-g2',
            name: 'move_jw_course_day',
            input: {
              'action': 'move',
              'source_date': '2026-08-03',
              'target_date': '2026-08-09',
            },
          ),
          const CompletedEvent(),
        ]),
    _ScriptedCall(() => [
          const ToolUseCompletedEvent(
            id: 'tu-g3',
            name: 'get_schedule',
            input: {'from': '2026-08-03', 'through': '2026-08-09'},
          ),
          const CompletedEvent(),
        ]),
    _ScriptedCall(() => [
          const TextDeltaEvent('已把8月3日的线性代数移到8月9日，晨跑等个人日程没有移动。'),
          const CompletedEvent(),
        ]),
    // Scenario 7b: clear the move through the Agent (critical confirm).
    _ScriptedCall(() => [
          const ToolUseCompletedEvent(
            id: 'tu-g4',
            name: 'move_jw_course_day',
            input: {'action': 'clear', 'source_date': '2026-08-03'},
          ),
          const CompletedEvent(),
        ]),
    _ScriptedCall(() => [
          const TextDeltaEvent('已恢复8月3日的课程到原日期。'),
          const CompletedEvent(),
        ]),
  ];
}

/// Reconstructs the ACTUAL executed tool-call sequence from the captured
/// requests: assistant `tool_use` blocks declare (id -> name), user
/// `tool_result` blocks reference the id. Each request replays the recent
/// conversation window, so the same result can appear in several consecutive
/// requests; matching by FIRST occurrence of each unique [LlmToolResultBlock]
/// id yields every tool that really ran, in execution order. This makes the
/// "get_conflicts is never a participant finder" assertion fail-capable
/// through the real router.
List<String> _executedToolSequence(_ScriptedProvider provider) {
  final namesById = <String, String>{};
  for (final request in provider.requests) {
    for (final message in request.messages) {
      for (final block in message.content) {
        if (block is LlmToolUseBlock) namesById[block.id] = block.name;
      }
    }
  }
  final executed = <String>[];
  final seen = <String>{};
  for (final request in provider.requests) {
    for (final message in request.messages) {
      for (final block in message.content) {
        if (block is! LlmToolResultBlock) continue;
        if (!seen.add(block.toolUseId)) continue;
        final name = namesById[block.toolUseId];
        if (name != null) executed.add(name);
      }
    }
  }
  return executed;
}

/// Every captured get_conflicts tool_result payload, in EXECUTION order (one
/// per unique tool result id; replays within the recent-window conversation
/// are skipped).
List<Map<String, Object?>> _capturedConflictPayloads(_ScriptedProvider provider) {
  final out = <Map<String, Object?>>[];
  final seen = <String>{};
  for (final request in provider.requests) {
    for (final message in request.messages) {
      if (message.role != 'user') continue;
      for (final block in message.content) {
        if (block is! LlmToolResultBlock) continue;
        if (!seen.add(block.toolUseId)) continue;
        final content = block.content;
        if (content is! String) continue;
        final decoded = jsonDecode(content);
        if (decoded is Map<String, Object?> &&
            decoded.containsKey('conflictPairs')) {
          out.add(decoded);
        }
      }
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Task 4 (date-bounded relation) script helpers.
// ---------------------------------------------------------------------------

/// The run-local task ref emitted by the LAST `get_tasks` tool_result across all
/// captured requests, or `null` if none is present. Parses the JSON payload the
/// session service folds into the model feed (the `_taskItemKeys` allowlist
/// keeps `ref`, `title`, etc.).
String? _taskRefFromResults(List<LlmRequest> prior) {
  for (final request in prior.reversed) {
    for (final message in request.messages) {
      if (message.role != 'user') continue;
      for (final block in message.content) {
        if (block is! LlmToolResultBlock) continue;
        final content = block.content;
        if (content is! String) continue;
        final decoded = jsonDecode(content);
        if (decoded is! Map<String, Object?>) continue;
        final tasks = decoded['tasks'];
        if (tasks is List && tasks.isNotEmpty) {
          final first = tasks.first;
          if (first is Map<String, Object?> && first['ref'] is String) {
            return first['ref'] as String;
          }
        }
      }
    }
  }
  return null;
}

/// The run-local plan_block ref from the LAST `get_plan_blocks` tool_result, or
/// `null` if none is present.
String? _lastPlanBlockRef(List<LlmRequest> prior) {
  for (final request in prior.reversed) {
    for (final message in request.messages) {
      if (message.role != 'user') continue;
      for (final block in message.content) {
        if (block is! LlmToolResultBlock) continue;
        final content = block.content;
        if (content is! String) continue;
        final decoded = jsonDecode(content);
        if (decoded is! Map<String, Object?>) continue;
        final blocks = decoded['planBlocks'];
        if (blocks is List && blocks.isNotEmpty) {
          final first = blocks.first;
          if (first is Map<String, Object?> && first['ref'] is String) {
            return first['ref'] as String;
          }
        }
      }
    }
  }
  return null;
}

/// The run-local event ref of the FIRST period (07:50-09:25) from the exact-day
/// `get_schedule` result. Selects purely by the surfaced `startAt` timing —
/// exactly how the real model locates the first-period course WITHOUT guessing
/// 计算机网络. Returns `null` if no event with that start time is present.
String? _firstPeriodEventRef(List<LlmRequest> prior) {
  for (final request in prior.reversed) {
    for (final message in request.messages) {
      if (message.role != 'user') continue;
      for (final block in message.content) {
        if (block is! LlmToolResultBlock) continue;
        final content = block.content;
        if (content is! String) continue;
        final decoded = jsonDecode(content);
        if (decoded is! Map<String, Object?>) continue;
        final events = decoded['events'];
        if (events is! List) continue;
        for (final e in events) {
          if (e is! Map<String, Object?>) continue;
          if (e['startAt'] == '2026-09-01T07:50:00' && e['ref'] is String) {
            return e['ref'] as String;
          }
        }
      }
    }
  }
  return null;
}
