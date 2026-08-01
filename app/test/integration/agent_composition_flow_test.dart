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
import 'package:ustc_assistant_app/features/settings/presentation/official_websites_page.dart';

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
    final events = _script[index].build();
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

/// One model call in a script. [build] returns the events to emit.
class _ScriptedCall {
  const _ScriptedCall(this._events);
  final List<LlmEvent> Function() _events;

  List<LlmEvent> build() => _events();
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
}
