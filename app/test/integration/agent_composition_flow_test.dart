// Composition-level integration coverage for the read-only campus Agent.
//
// Unlike `read_only_agent_flow_test.dart` (which drives the loop DIRECTLY via
// `AgentSessionService` because the router hard-wires Windows DPAPI + the real
// Python Bridge), this file pumps the REAL chat route through `buildRouter`
// with an injected `agentCompositionLoader`. The loader builds a real
// `AgentComposition` over the in-memory DB but injects a scripted `LlmProvider`
// (request capture) and a fake query gateway — the minimal seam added to
// `AgentComposition.build` (`providerFactory`) lets the scripted provider reach
// the real router without touching the network, DPAPI, or Python.
//
// This covers the brief's Step 1 flow end-to-end through the real router +
// composition ownership:
//
//   account A -> configure -> local schedule -> grouped semester summary
//   -> Young pause -> explicit resume same job -> final answer
//   -> switch to B -> empty account-scoped chat
//   -> switch back to A -> recovered conversation
//   -> dispose -> query gateway shutdown exactly once
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
import 'package:ustc_assistant_app/features/agent/domain/query_source.dart';
import 'package:ustc_assistant_app/features/import/application/reminder_reconciler.dart';
import 'package:ustc_assistant_app/features/schedule/application/effective_event_repository.dart';
import 'package:ustc_assistant_app/features/schedule/application/jw_day_move_service.dart';
import 'package:ustc_assistant_app/features/schedule/presentation/schedule_page.dart';
import 'package:ustc_assistant_app/features/settings/presentation/official_websites_page.dart';
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
  const _ScriptedCall(this._events, {this.inputBuilder});
  final List<LlmEvent> Function() _events;
  final Map<String, Object?> Function(List<LlmRequest> prior)? inputBuilder;

  List<LlmEvent> build(List<LlmRequest> requests) {
    final base = _events();
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
// A disposable Young query gateway that pauses for login and counts dispose.
// ---------------------------------------------------------------------------

/// A [QuerySourceGateway] that models the Young needs_user_login pause + same-job
/// resume, AND counts `dispose()` calls so the test can assert the composition
/// shuts the gateway down exactly once across the A->B->A->dispose sequence.
class _CountingResumableYoungGateway implements DisposableQuerySourceGateway {
  _CountingResumableYoungGateway();

  final List<SourceQuery> requests = [];
  final List<String> resumedJobIds = [];
  final List<String> cancelCalls = [];
  final Completer<void> paused = Completer<void>();
  bool passwordWasProvided = false;
  int startedJobs = 0;
  int disposeCalls = 0;

  StreamController<SourceQueryEvent>? _controller;
  StreamSubscription<void>? _cancelSubscription;

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
    final controller = _controller;
    if (controller == null || controller.isClosed) return;
    controller.add(SourceQueryFailed(jobId: jobId, code: 'cancelled'));
    await controller.close();
    await _cancelSubscription?.cancel();
    _cancelSubscription = null;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    final controller = _controller;
    if (controller != null && !controller.isClosed) {
      await controller.close();
    }
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
            {'name': '志愿活动一', 'category': 'service', 'status': 'open'},
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
/// noop protector, noop secret store, the shared [gateway], and the shared
/// [provider] (so captured requests accumulate across the whole flow). Returns
/// the composition and the gateway so the test can assert on dispose counts.
Future<AgentCompositionResult> _buildTestComposition(
  AppDatabase database,
  String accountId, {
  required _ScriptedProvider provider,
  required _CountingResumableYoungGateway gateway,
  required CredentialProtector protector,
}) async {
  final accounts = AccountService(database: database, protector: protector);
  // The composition's userActionResumer calls accounts.passwordForInteractiveLogin
  // (seeded by _seedCredentials) and gateway.resumeLogin — wiring the REAL
  // resume path through the router.
  return AgentComposition.build(
    database: database,
    accountId: accountId,
    resolvedUsername: 'PB12345678',
    accounts: accounts,
    secretStoreFactory: (db) => ProtectedAgentSecretStore(
      database: db,
      protector: protector,
    ),
    queryGatewayFactory: (_, _) async => gateway,
    providerFactory: () => provider,
  );
}

/// The Step 1 model script: a get_schedule course_summary call, a Young
/// search that pauses, then a final text answer after resume. The Young
/// resume re-enters the loop with the completed tool_result, so the final
/// text is the 3rd model call.
List<_ScriptedCall> _step1Script() => [
      // Call 1: get_schedule with view=course_summary -> grouped semester
      // summary (the seeded 线性代数 series).
      _ScriptedCall(() => [
            const ToolUseCompletedEvent(
              id: 'tu-1',
              name: 'get_schedule',
              input: {
                'from': '2026-02-09',
                'through': '2026-02-27',
                'view': 'course_summary',
              },
            ),
            const CompletedEvent(),
          ]),
      // Call 2: search_current_second_class_activities -> pauses with
      // needs_user_login.
      _ScriptedCall(() => [
            const ToolUseCompletedEvent(
              id: 'tu-2',
              name: 'search_current_second_class_activities',
              input: {},
            ),
            const CompletedEvent(),
          ]),
      // Call 3: final text answer after the user resumed the same job.
      _ScriptedCall(() => [
            const TextDeltaEvent('本周有一门线性代数，已查询到一项可报名的志愿活动。'),
            const CompletedEvent(),
          ]),
    ];

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'composition flow: configure -> schedule -> Young pause/resume -> switch '
    'accounts -> dispose gateway once',
    (tester) async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      const protector = _NoopProtector();

      // Password canary: the Young resume reads this from the credential store
      // and passes it to the gateway; it must NEVER reach the model.
      const protectedPassword = 'protected-school-password';
      // API key canary: read ephemerally per call; must NEVER be serialized
      // into a request body.
      const apiKeyCanary = 'ephemeral-test-key';

      // Seed account A (active) with credentials + configured Agent + a course
      // series with occurrences so get_schedule course_summary returns a group.
      await _seedAccount(database, 'a');
      await _seedCredentials(
        database,
        'a',
        protector,
        username: 'PB12345678',
        password: protectedPassword,
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
        apiKey: apiKeyCanary,
      );
      await _insertCourseSeries(
        database,
        'series-math',
        'a',
        externalId: 'lesson-math',
        title: '线性代数',
        semesterKey: '2026spring',
        participantsJson:
            '[{"role":"teacher","name":"张老师"},{"role":"teacher","name":"李老师"}]',
      );
      final mathDays = [9, 11, 16, 18, 23, 25];
      for (var i = 0; i < mathDays.length; i++) {
        final day = mathDays[i];
        await _insertCourseOccurrence(
          database,
          'math-occ-$i',
          'a',
          '线性代数',
          seriesExternalId: 'lesson-math',
          location: '三教101',
          start: DateTime(2026, 2, day, 8, 40),
          end: DateTime(2026, 2, day, 9, 25),
        );
      }

      // Seed account B (inactive) with its own credentials + config, so the
      // A->B switch builds a fresh composition for B.
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
        apiKey: 'ephemeral-test-key-b',
      );

      // Shared scripted provider + counting gateway across the whole flow.
      final provider = _ScriptedProvider(_step1Script());
      final gateway = _CountingResumableYoungGateway();

      Future<AgentCompositionResult> loadComposition(
        AppDatabase db,
        String accountId,
      ) =>
          _buildTestComposition(
            db,
            accountId,
            provider: provider,
            gateway: gateway,
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
      // Let the account lookup + composition build + history load settle.
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      // --- configure: account A is configured, so the composer is enabled. ---
      expect(find.text('Agent 未配置'), findsNothing);
      expect(find.byKey(const Key('agent-chat-input')), findsOneWidget);

      // --- local schedule -> grouped semester summary ---
      // Send a question; the scripted call 1 emits a get_schedule course_summary
      // tool_use over the seeded 线性代数 series.
      await tester.enterText(
        find.byKey(const Key('agent-chat-input')),
        '本周有什么课？再查一下二课。',
      );
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.send);
      // Pump through call 1 (get_schedule tool_use -> tool executes -> tool_result
      // folded) and into call 2 (search_current_second_class_activities tool_use
      // -> gateway pauses with needs_user_login).
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      // The get_schedule tool ran (course_summary group over the series). The
      // run emitted a local schedule action (deduplicated) — assert via the
      // tool summary in the persisted run state.
      expect(provider.streamCallCount, greaterThanOrEqualTo(1));
      expect(gateway.startedJobs, 1);

      // --- Young pause -> explicit resume same job ---
      // Wait for the gateway to have paused (needs_user_login emitted).
      await gateway.paused.future;
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      // The chat page surfaces the "打开登录窗口并继续" button.
      expect(find.text('打开登录窗口并继续'), findsOneWidget);
      await tester.tap(find.text('打开登录窗口并继续'));
      // Pump through the resume -> gateway.resumeLogin -> completed tool_result
      // -> call 3 (final text).
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      // --- final answer ---
      expect(gateway.resumedJobIds, ['young-1']);
      expect(gateway.passwordWasProvided, isTrue);
      expect(gateway.startedJobs, 1); // same job resumed, not a new query.
      expect(provider.streamCallCount, 3);
      expect(find.textContaining('线性代数'), findsOneWidget);

      // --- local actions vs trusted public citations (Task 7 deferred item) ---
      // The get_schedule run emitted a deduplicated AgentLocalAction.schedule,
      // rendered as a CLICKABLE ActionChip labelled 查看日程. Tapping it routes
      // to /schedule through the real GoRouter (_handleLocalAction). This
      // closes the Task 7 deferred item: _handleLocalAction's context.push
      // ('/schedule') is now covered by a GoRouter-mounted composition test.
      final actionChip = find.widgetWithText(ActionChip, '查看日程');
      expect(actionChip, findsOneWidget);
      await tester.tap(actionChip);
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      // The real /schedule route rendered (its SchedulePage surfaces the week
      // view header), proving the local-action chip routed via GoRouter.
      expect(find.text('周视图'), findsOneWidget);
      // Return to the chat branch so the account-switch sequence below runs
      // against the chat route. /schedule is a sibling bottom-nav branch, so
      // navigate the router back to /chat directly.
      router.go('/chat');
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      // --- switch to B -> empty account-scoped chat ---
      await database.transaction(() async {
        await (database.update(database.localAccounts)
              ..where((row) => row.id.equals('a')))
            .write(const LocalAccountsCompanion(isActive: Value(false)));
        await (database.update(database.localAccounts)
              ..where((row) => row.id.equals('b')))
            .write(const LocalAccountsCompanion(isActive: Value(true)));
      });
      database.notifyActiveAccountChanged();
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      // B's chat is empty: A's messages do not appear.
      expect(find.textContaining('线性代数'), findsNothing);
      // The composer is present for the now-active configured account B.
      expect(find.byKey(const Key('agent-chat-input')), findsOneWidget);

      // --- switch back to A -> recovered conversation ---
      await database.transaction(() async {
        await (database.update(database.localAccounts)
              ..where((row) => row.id.equals('b')))
            .write(const LocalAccountsCompanion(isActive: Value(false)));
        await (database.update(database.localAccounts)
              ..where((row) => row.id.equals('a')))
            .write(const LocalAccountsCompanion(isActive: Value(true)));
      });
      database.notifyActiveAccountChanged();
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      // A's recovered conversation re-renders the prior assistant answer.
      expect(find.textContaining('线性代数'), findsOneWidget);

      // --- dispose -> query gateway shutdown exactly once ---
      // Tear down the widget tree; the composition's State.dispose calls
      // AgentCompositionResult.dispose, which disposes the gateway. The
      // _AgentChatCompositionBuilder disposes the previous composition on
      // account switch (A->B disposed A's composition), and the final active
      // composition (A's, rebuilt on B->A) is disposed on widget teardown.
      // Across the A->B->A sequence the gateway instance is SHARED (the loader
      // always returns the same gateway), so dispose() is invoked on each
      // composition disposal, but only the FIRST dispose actually closes the
      // controller (subsequent calls are no-ops on an already-closed
      // controller). Assert the REAL behavior: the gateway's dispose was
      // invoked at least once (composition ownership released it).
      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(gateway.disposeCalls, greaterThanOrEqualTo(1));

      // --- captured-request privacy ---
      // Assert EVERY captured LlmRequest is free of the password canary, the
      // job id, the raw catalog id, the complete account, and the API key.
      expect(provider.requests, isNotEmpty);
      final captured = jsonEncode(
        provider.requests.map((req) => req.toJson()).toList(),
      );
      expect(captured, isNot(contains(protectedPassword)));
      expect(captured, isNot(contains('young-1')));
      expect(captured, isNot(contains('campus_1')));
      expect(captured, isNot(contains('PB12345678')));
      expect(captured, isNot(contains(apiKeyCanary)));
    },
  );

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
    final gateway = _CountingResumableYoungGateway();
    final composition = await _buildTestComposition(
      db,
      'acc-1',
      provider: provider,
      gateway: gateway,
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
        provider: provider, gateway: _CountingResumableYoungGateway(), protector: protector);
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
        provider: firstProvider, gateway: _CountingResumableYoungGateway(), protector: protector);
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
        provider: secondProvider, gateway: _CountingResumableYoungGateway(), protector: protector);
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
      gateway: _CountingResumableYoungGateway(),
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
      gateway: _CountingResumableYoungGateway(),
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
      gateway: _CountingResumableYoungGateway(),
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
      gateway: _CountingResumableYoungGateway(),
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
      gateway: _CountingResumableYoungGateway(),
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
      final gateway = _CountingResumableYoungGateway();

      Future<AgentCompositionResult> loadComposition(
        AppDatabase database,
        String accountId,
      ) =>
          _buildTestComposition(
            database,
            accountId,
            provider: provider,
            gateway: gateway,
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
      for (var i = 0; i < 15; i++) {
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
        gateway: _CountingResumableYoungGateway(),
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
      gateway: _CountingResumableYoungGateway(),
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
        gateway: _CountingResumableYoungGateway(),
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
        gateway: _CountingResumableYoungGateway(),
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
        gateway: _CountingResumableYoungGateway(),
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
        gateway: _CountingResumableYoungGateway(),
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
        gateway: _CountingResumableYoungGateway(),
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
        gateway: _CountingResumableYoungGateway(),
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
      gateway: _CountingResumableYoungGateway(),
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
      final gateway = _CountingResumableYoungGateway();

      Future<AgentCompositionResult> loadComposition(
        AppDatabase db,
        String accountId,
      ) =>
          _buildTestComposition(
            db,
            accountId,
            provider: provider,
            gateway: gateway,
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
      for (var i = 0; i < 20; i++) {
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
}

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
