import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/security/credential_protector.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_configuration_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_context_builder.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_session_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_tool_registry.dart';
import 'package:ustc_assistant_app/features/agent/application/cancellation_signal.dart';
import 'package:ustc_assistant_app/features/agent/application/outbound_privacy_filter.dart';
import 'package:ustc_assistant_app/features/agent/data/drift_chat_repository.dart';
import 'package:ustc_assistant_app/features/agent/data/protected_agent_secret_store.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_models.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_tool.dart';
import 'package:ustc_assistant_app/features/agent/domain/llm_protocol.dart';
import 'package:ustc_assistant_app/features/agent/presentation/agent_chat_page.dart';
import 'package:ustc_assistant_app/features/agent/presentation/agent_setup_panel.dart';
import 'package:ustc_assistant_app/features/agent/presentation/agent_tool_run_tile.dart';
import 'package:ustc_assistant_app/features/agent/presentation/safe_markdown_message.dart';
import 'package:ustc_assistant_app/features/settings/presentation/official_websites_page.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeWebsiteLauncher implements OfficialWebsiteLauncher {
  final launched = <Uri>[];

  @override
  Future<bool> launch(Uri uri) async {
    launched.add(uri);
    return true;
  }
}

class _FakeLlmProvider implements LlmProvider {
  @override
  Future<List<String>> listModels({
    required String apiKey,
    required CancellationSignal cancellation,
  }) async => ['deepseek-v4-flash'];

  @override
  Stream<LlmEvent> stream({
    required String apiKey,
    required LlmRequest request,
    required CancellationSignal cancellation,
  }) => const Stream.empty();

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

class _NoopProtector implements CredentialProtector {
  @override
  Future<ProtectedSecret> protect(Uint8List plaintext) async {
    return ProtectedSecret(
      bytes: Uint8List.fromList([0]),
      scheme: 'noop',
      version: 1,
      metadata: const {},
    );
  }

  @override
  Future<Uint8List> unprotect(ProtectedSecret protected) async => Uint8List(0);
}

class _FakeConfigService extends AgentConfigurationService {
  _FakeConfigService(AppDatabase db, DriftChatRepository repo) : super(
    database: db,
    chatRepository: repo,
  );

  AgentSettingsSnapshot? _override;

  void setConfigured() {
    _override = AgentSettingsSnapshot(
      accountId: 'test',
      model: 'deepseek-v4-flash',
      enabled: true,
      icourseConsent: false,
      systemPromptVersion: 1,
      updatedAt: null,
    );
  }

  void setUnconfigured() {
    _override = AgentSettingsSnapshot(
      accountId: 'test',
      model: 'deepseek-v4-flash',
      enabled: false,
      icourseConsent: false,
      systemPromptVersion: 1,
      updatedAt: null,
    );
  }

  @override
  Future<AgentSettingsSnapshot> load(String accountId) async {
    return _override ?? await super.load(accountId);
  }
}

/// Scripted session service using a persistent StreamController.
/// The controller stays open so the widget observes intermediate states
/// without immediately triggering onStreamDone.
class _ScriptedSessionService extends AgentSessionService {
  _ScriptedSessionService(AppDatabase db, DriftChatRepository repo)
    : super(
        chatRepository: repo,
        database: db,
        provider: _FakeLlmProvider(),
        contextBuilder: const AgentContextBuilder(),
        privacyFilter: OutboundPrivacyFilter(protectedAccount: '', toolBuilders: const {}),
        registry: AgentToolRegistry(tools: [], privacyFilter: OutboundPrivacyFilter(protectedAccount: '', toolBuilders: const {})),
        clock: const SystemBeijingClock(),
        model: 'deepseek-v4-flash',
        apiKeyProvider: ({required accountId}) async => '',
      ) {
    _controller = StreamController<AgentRunViewState>();
  }

  late final StreamController<AgentRunViewState> _controller;
  final List<({String accountId, String runId})> resumeCalls = [];

  void addState(AgentRunViewState state) => _controller.add(state);
  void closeStream() { if (!_controller.isClosed) _controller.close(); }

  /// Simulates a stream that errors mid-flight WITHOUT first emitting a
  /// terminal state, so the page's error/done handlers must produce one.
  void emitError(Object error) {
    if (!_controller.isClosed) _controller.addError(error);
  }

  @override
  Stream<AgentRunViewState> send({
    required String accountId,
    required String userText,
  }) => _controller.stream;

  @override
  Stream<AgentRunViewState> retryLast({required String accountId}) => _controller.stream;

  @override
  Future<void> cancel({required String accountId}) async { closeStream(); }

  @override
  Stream<AgentRunViewState> resumeUserAction({
    required String accountId,
    required String runId,
    Map<String, Object?>? userActionPayload,
  }) async* {
    resumeCalls.add((accountId: accountId, runId: runId));
  }
}

class _FakeSecretStore extends ProtectedAgentSecretStore {
  static final _noop = _NoopProtector();

  _FakeSecretStore(AppDatabase db) : super(
    database: db,
    protector: _noop,
    now: () => 1,
  );

  bool _hasKey = true;

  void setHasKey(bool value) => _hasKey = value;

  @override
  Future<bool> hasKey(String accountId) async => _hasKey;
  @override
  Future<String?> readKey(String accountId) async => 'fake-key';
  @override
  Future<void> saveKey(String accountId, String apiKey) async {}
  @override
  Future<void> deleteKey(String accountId) async {}
}

Widget _buildPage({
  required AgentConfigurationService config,
  required AgentSecretStore secrets,
  required AgentSessionService sessionService,
  required DriftChatRepository chatRepository,
  OfficialWebsiteLauncher? launcher,
}) {
  return MaterialApp(
    home: Scaffold(
      body: AgentChatPage(
        accountId: 'test',
        config: config,
        secrets: secrets,
        provider: _FakeLlmProvider(),
        sessionService: sessionService,
        chatRepository: chatRepository,
        websiteLauncher: launcher ?? _FakeWebsiteLauncher(),
      ),
    ),
  );
}

Future<void> _pump(dynamic tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  late AppDatabase database;
  late DriftChatRepository chatRepository;
  late _FakeConfigService config;
  late _FakeSecretStore secrets;

  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
    chatRepository = DriftChatRepository(database);
    config = _FakeConfigService(database, chatRepository);
    secrets = _FakeSecretStore(database);
  });

  tearDown(() async {
    await database.close();
  });

  group('Step 1: widget state tests', () {
    testWidgets('unconfigured shows setup panel', (tester) async {
      config.setUnconfigured();
      secrets.setHasKey(false);

      await tester.pumpWidget(_buildPage(
        config: config,
        secrets: secrets,
        sessionService: _ScriptedSessionService(database, chatRepository),
        chatRepository: chatRepository,
      ));
      await _pump(tester);

      expect(find.byType(AgentSetupPanel), findsOneWidget);
    });

    testWidgets('ready: configured with empty history shows welcome', (tester) async {
      config.setConfigured();

      await tester.pumpWidget(_buildPage(
        config: config,
        secrets: secrets,
        sessionService: _ScriptedSessionService(database, chatRepository),
        chatRepository: chatRepository,
      ));
      await _pump(tester);

      expect(find.text('有什么可以帮你的？'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    });

    testWidgets('streaming: send button becomes stop icon', (tester) async {
      config.setConfigured();
      final script = _ScriptedSessionService(database, chatRepository);

      await tester.pumpWidget(_buildPage(
        config: config,
        secrets: secrets,
        sessionService: script,
        chatRepository: chatRepository,
      ));
      await _pump(tester);

      await tester.enterText(find.byType(TextField), '你好');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await _pump(tester);

      // Send the running state.
      script.addState(AgentRunViewState(runId: 'r1', state: AgentRunState.running, text: '思考中...'));
      await _pump(tester);

      expect(find.byIcon(Icons.stop), findsOneWidget);
      expect(find.byIcon(Icons.send), findsNothing);

      script.closeStream();
    });

    testWidgets('tool-running: tool tile shown collapsed', (tester) async {
      config.setConfigured();
      final script = _ScriptedSessionService(database, chatRepository);

      await tester.pumpWidget(_buildPage(
        config: config,
        secrets: secrets,
        sessionService: script,
        chatRepository: chatRepository,
      ));
      await _pump(tester);

      await tester.enterText(find.byType(TextField), '查询日程');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await _pump(tester);

      script.addState(AgentRunViewState(
        runId: 'r1', state: AgentRunState.running, text: '查询中...',
        toolSummaries: const [AgentToolSummary(toolName: 'get_schedule', status: AgentToolStatus.success)],
      ));
      await _pump(tester);

      expect(find.byType(AgentToolRunTile), findsOneWidget);
      expect(find.text('get_schedule'), findsNothing);

      script.closeStream();
    });

    testWidgets('tool steps visible when expanded', (tester) async {
      config.setConfigured();
      final script = _ScriptedSessionService(database, chatRepository);

      await tester.pumpWidget(_buildPage(
        config: config,
        secrets: secrets,
        sessionService: script,
        chatRepository: chatRepository,
      ));
      await _pump(tester);

      await tester.enterText(find.byType(TextField), '查询日程');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await _pump(tester);

      script.addState(AgentRunViewState(
        runId: 'r1', state: AgentRunState.running, text: '查询中...',
        toolSummaries: const [AgentToolSummary(toolName: 'get_schedule', status: AgentToolStatus.success)],
      ));
      await _pump(tester);

      await tester.tap(find.byType(AgentToolRunTile));
      await _pump(tester);

      expect(find.text('get_schedule'), findsOneWidget);

      script.closeStream();
    });

    testWidgets('completed state shows answer and copy button', (tester) async {
      config.setConfigured();
      final script = _ScriptedSessionService(database, chatRepository);

      await tester.pumpWidget(_buildPage(
        config: config,
        secrets: secrets,
        sessionService: script,
        chatRepository: chatRepository,
      ));
      await _pump(tester);

      await tester.enterText(find.byType(TextField), '你好');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await _pump(tester);

      script.addState(AgentRunViewState(runId: 'r1', state: AgentRunState.running, text: '你好'));
      await _pump(tester);
      script.addState(AgentRunViewState(runId: 'r1', state: AgentRunState.completed, text: '你好！我是校园助手。'));
      script.closeStream();
      await _pump(tester);

      expect(find.textContaining('校园助手'), findsOneWidget);
      expect(find.byIcon(Icons.copy), findsOneWidget);
    });

    testWidgets('failed state shows retry button', (tester) async {
      config.setConfigured();
      final script = _ScriptedSessionService(database, chatRepository);

      await tester.pumpWidget(_buildPage(
        config: config,
        secrets: secrets,
        sessionService: script,
        chatRepository: chatRepository,
      ));
      await _pump(tester);

      await tester.enterText(find.byType(TextField), '查询');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await _pump(tester);

      script.addState(AgentRunViewState(runId: 'r1', state: AgentRunState.running, text: '查询中...'));
      await _pump(tester);
      script.addState(AgentRunViewState(runId: 'r1', state: AgentRunState.failed, text: '', errorCode: 'upstream_error'));
      script.closeStream();
      await _pump(tester);

      expect(find.byIcon(Icons.refresh), findsOneWidget);
    });

    testWidgets('cancelled state shows retry button', (tester) async {
      config.setConfigured();
      final script = _ScriptedSessionService(database, chatRepository);

      await tester.pumpWidget(_buildPage(
        config: config,
        secrets: secrets,
        sessionService: script,
        chatRepository: chatRepository,
      ));
      await _pump(tester);

      await tester.enterText(find.byType(TextField), '查询');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await _pump(tester);

      script.addState(AgentRunViewState(runId: 'r1', state: AgentRunState.running, text: '查询中...'));
      await _pump(tester);
      script.addState(AgentRunViewState(runId: 'r1', state: AgentRunState.cancelled, text: '部分结果'));
      script.closeStream();
      await _pump(tester);

      expect(find.byIcon(Icons.refresh), findsOneWidget);
    });

    testWidgets('interrupted state shows retry button', (tester) async {
      config.setConfigured();
      final script = _ScriptedSessionService(database, chatRepository);

      await tester.pumpWidget(_buildPage(
        config: config,
        secrets: secrets,
        sessionService: script,
        chatRepository: chatRepository,
      ));
      await _pump(tester);

      await tester.enterText(find.byType(TextField), '查询');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await _pump(tester);

      script.addState(AgentRunViewState(runId: 'r1', state: AgentRunState.running, text: '查询中...'));
      await _pump(tester);
      script.addState(AgentRunViewState(runId: 'r1', state: AgentRunState.interrupted, text: '部分结果'));
      script.closeStream();
      await _pump(tester);

      expect(find.byIcon(Icons.refresh), findsOneWidget);
    });

    testWidgets(
      'copy button shows for any terminal state with non-empty text, '
      'not only completed',
      (tester) async {
        // Regression guard: an interrupted/failed/cancelled run may have
        // substantial partial text the user wants to copy. The copy button
        // must render for ANY terminal state with non-empty text, not only
        // `completed`. A running message, or a terminal message with empty
        // text, must NOT show the copy button.
        config.setConfigured();
        final script = _ScriptedSessionService(database, chatRepository);

        await tester.pumpWidget(_buildPage(
          config: config,
          secrets: secrets,
          sessionService: script,
          chatRepository: chatRepository,
        ));
        await _pump(tester);

        await tester.enterText(find.byType(TextField), '查询');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await _pump(tester);

        // 1. Interrupted with partial text -> copy button visible.
        script.addState(AgentRunViewState(runId: 'r1', state: AgentRunState.running, text: '查询中...'));
        await _pump(tester);
        script.addState(AgentRunViewState(runId: 'r1', state: AgentRunState.interrupted, text: '部分结果文本'));
        script.closeStream();
        await _pump(tester);

        expect(find.byIcon(Icons.copy), findsOneWidget,
            reason: 'interrupted run with partial text should allow copy');
        expect(find.byIcon(Icons.refresh), findsOneWidget);
      },
    );

    testWidgets(
      'copy button hidden for running message and for empty-text terminal message',
      (tester) async {
        config.setConfigured();
        final script = _ScriptedSessionService(database, chatRepository);

        await tester.pumpWidget(_buildPage(
          config: config,
          secrets: secrets,
          sessionService: script,
          chatRepository: chatRepository,
        ));
        await _pump(tester);

        await tester.enterText(find.byType(TextField), '查询');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await _pump(tester);

        // Running (non-terminal) with text -> no copy button.
        script.addState(AgentRunViewState(runId: 'r1', state: AgentRunState.running, text: '正在生成...'));
        await _pump(tester);
        expect(find.byIcon(Icons.copy), findsNothing,
            reason: 'running message must not show copy');

        // Terminal (failed) with EMPTY text -> no copy button (nothing to copy).
        script.addState(AgentRunViewState(runId: 'r1', state: AgentRunState.failed, text: '', errorCode: 'upstream_error'));
        script.closeStream();
        await _pump(tester);
        expect(find.byIcon(Icons.copy), findsNothing,
            reason: 'terminal message with empty text must not show copy');
        expect(find.byIcon(Icons.refresh), findsOneWidget);
      },
    );

    testWidgets(
      'stream erroring mid-flight without a terminal state recovers with retry',
      (tester) async {
        // Regression guard: if the stream errors without emitting a terminal
        // state, the last assistant message MUST reach a terminal state
        // (interrupted/failed) so the retry button appears and the user is
        // not stuck on a "正在思考..." bubble with no recovery path.
        config.setConfigured();
        final script = _ScriptedSessionService(database, chatRepository);

        await tester.pumpWidget(_buildPage(
          config: config,
          secrets: secrets,
          sessionService: script,
          chatRepository: chatRepository,
        ));
        await _pump(tester);

        await tester.enterText(find.byType(TextField), '查询');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await _pump(tester);

        // Only a running state arrives, then the stream errors — no terminal.
        script.addState(
          AgentRunViewState(runId: 'r1', state: AgentRunState.running, text: '查询中...'),
        );
        await _pump(tester);
        script.emitError(StateError('boom'));
        await _pump(tester);

        // No stop button (not running) and a retry button is visible.
        expect(find.byIcon(Icons.stop), findsNothing);
        expect(find.byIcon(Icons.refresh), findsOneWidget);
        // The bubble must not still claim to be thinking.
        expect(find.text('正在思考...'), findsNothing);
      },
    );

    testWidgets(
      'stream completing without a terminal state recovers with retry',
      (tester) async {
        // Regression guard: if the stream completes (onDone) without ever
        // emitting a terminal state, the last assistant message MUST reach a
        // terminal state so the retry button appears.
        config.setConfigured();
        final script = _ScriptedSessionService(database, chatRepository);

        await tester.pumpWidget(_buildPage(
          config: config,
          secrets: secrets,
          sessionService: script,
          chatRepository: chatRepository,
        ));
        await _pump(tester);

        await tester.enterText(find.byType(TextField), '查询');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await _pump(tester);

        script.addState(
          AgentRunViewState(runId: 'r1', state: AgentRunState.running, text: '查询中...'),
        );
        await _pump(tester);
        // Close WITHOUT a terminal state — abnormal empty completion.
        script.closeStream();
        await _pump(tester);

        expect(find.byIcon(Icons.stop), findsNothing);
        expect(find.byIcon(Icons.refresh), findsOneWidget);
        expect(find.text('正在思考...'), findsNothing);
      },
    );

    testWidgets('needs-login shows resume UI', (tester) async {
      config.setConfigured();
      final script = _ScriptedSessionService(database, chatRepository);

      await tester.pumpWidget(_buildPage(
        config: config,
        secrets: secrets,
        sessionService: script,
        chatRepository: chatRepository,
      ));
      await _pump(tester);

      await tester.enterText(find.byType(TextField), '查询二课');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await _pump(tester);

      script.addState(AgentRunViewState(runId: 'r1', state: AgentRunState.running, text: '登录中...'));
      await _pump(tester);
      script.addState(
        const AgentRunViewState(
          runId: 'r1',
          state: AgentRunState.waitingForUser,
          userAction: AgentUserActionMetadata(
            type: AgentUserActionType.youngLogin,
          ),
        ),
      );
      await _pump(tester);

      expect(find.text('需要登录校园账号以继续'), findsOneWidget);
      expect(find.text('打开登录窗口并继续'), findsOneWidget);
      await tester.tap(find.text('打开登录窗口并继续'));
      await _pump(tester);
      expect(
        script.resumeCalls,
        [(accountId: 'test', runId: 'r1')],
      );
      script.closeStream();
    });

    testWidgets(
      'scroll offset survives a _nearBottom flip (no snap back to top)',
      (tester) async {
        // Regression guard for the "drag down -> jumps back to top" bug.
        // Root cause: `build` created a NEW `isConfigured` future every
        // rebuild, so any setState (here the `_nearBottom` flip when the
        // user scrolls up past 200px) reset the FutureBuilder to `waiting`,
        // unmounting the ListView. On remount the ScrollController
        // re-attached at offset 0. The fix caches the configured future in
        // initState so the ListView stays mounted and the offset is kept.
        config.setConfigured();
        final script = _ScriptedSessionService(database, chatRepository);

        // The chat_messages table has a foreign key on account_id, so seed
        // the account row before inserting history.
        await database.into(database.localAccounts).insert(
              LocalAccountsCompanion.insert(
                id: 'test',
                maskedHint: 'PB****0000',
                isActive: const Value(true),
                createdAt: 1,
                updatedAt: 1,
              ),
            );

        // Seed enough history to make the list scrollable.
        for (var i = 0; i < 60; i++) {
          await chatRepository.appendMessage(
            accountId: 'test',
            role: i % 2 == 0 ? ChatRole.user : ChatRole.assistant,
            content: '历史消息 $i，内容稍长以撑高列表便于滚动测试。',
            runId: null,
            state: ChatMessageState.completed,
          );
        }

        await tester.pumpWidget(_buildPage(
          config: config,
          secrets: secrets,
          sessionService: script,
          chatRepository: chatRepository,
        ));
        await _pump(tester);
        await tester.pumpAndSettle();

        final listViewFinder = find.byType(ListView);
        expect(listViewFinder, findsOneWidget);
        // ListView itself is stateless; the scroll state lives on the
        // descendant Scrollable. The first such Scrollable is the list's
        // own viewport (markdown bubbles may nest additional Scrollables).
        final scrollableFinder = find
            .descendant(
              of: listViewFinder,
              matching: find.byType(Scrollable),
            )
            .first;

        // Scroll up by a large amount, well past the 200px nearBottom
        // threshold, to force _nearBottom to flip false -> setState.
        final gesture = await tester.startGesture(
          tester.getCenter(listViewFinder),
        );
        // Drag UP on the list (moves content up = scroll towards bottom) is
        // not what we want; we want to first move down to a non-zero offset,
        // then drag back up past the threshold. Start by scrolling down.
        for (var i = 0; i < 20; i++) {
          await gesture.moveBy(const Offset(0, -40));
          await tester.pump();
        }
        await gesture.up();
        await tester.pumpAndSettle();

        final scrolledOffset = tester
            .state<ScrollableState>(scrollableFinder)
            .position
            .pixels;
        expect(scrolledOffset, greaterThan(300),
            reason: 'list should have scrolled down significantly');

        // Now drag back UP past the 200px nearBottom threshold, which flips
        // _nearBottom to false and triggers setState. The offset must NOT
        // reset to 0 (the bug).
        final gesture2 = await tester.startGesture(
          tester.getCenter(listViewFinder),
        );
        for (var i = 0; i < 8; i++) {
          await gesture2.moveBy(const Offset(0, 40));
          await tester.pump();
        }
        await gesture2.up();
        await tester.pumpAndSettle();

        final offsetAfterNearBottomFlip = tester
            .state<ScrollableState>(scrollableFinder)
            .position
            .pixels;
        expect(offsetAfterNearBottomFlip, greaterThan(200),
            reason: 'scroll position must be preserved across a _nearBottom '
                'flip; snapping back to 0 is the regression');
      },
    );
  });

  group('Step 2: safe markdown and link tests', () {
    testWidgets('raw HTML is inert (no script execution)', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SafeMarkdownMessage(text: '<script>alert("xss")</script>\nsafe text'),
        ),
      ));
      await tester.pump();

      expect(find.textContaining('safe text'), findsOneWidget);
    });

    testWidgets('model-authored URLs are not clickable', (tester) async {
      final launcher = _FakeWebsiteLauncher();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SafeMarkdownMessage(text: '[click me](https://evil.example.com)', launcher: launcher),
        ),
      ));
      await tester.pump();

      final linkFinder = find.text('click me');
      expect(linkFinder, findsOneWidget);

      await tester.tap(linkFinder);
      await tester.pump();
      expect(launcher.launched, isEmpty);
    });

    testWidgets(
      'trusted source reference chips are non-interactive until a real URL is resolvable',
      (tester) async {
        // Until a ref -> real-source-URL resolution path exists at the UI
        // layer, citation chips MUST NOT launch a hardcoded placeholder URL
        // pretending to be the tool-returned source. They render as inert
        // text so clicking never opens a page that is not the actual source.
        final launcher = _FakeWebsiteLauncher();
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SafeMarkdownMessage(
              text: '根据查询结果...',
              sourceReferences: const [
                AgentSourceReference(kind: 'event', ref: 'ref_abc'),
              ],
              launcher: launcher,
            ),
          ),
        ));
        await tester.pump();

        expect(find.text('查看日程'), findsOneWidget);
        // No tappable ActionChip — the citation is plain inert text.
        expect(find.byType(ActionChip), findsNothing);
        // Tapping the label must not launch any URL.
        await tester.tap(find.text('查看日程'));
        await tester.pump();
        expect(launcher.launched, isEmpty);
      },
    );

    testWidgets('empty text and refs renders nothing', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SafeMarkdownMessage(text: '')),
      ));
      await tester.pump();
      expect(find.byType(SafeMarkdownMessage), findsOneWidget);
    });

    testWidgets('source refs without launcher show non-interactive label', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SafeMarkdownMessage(
            text: '查询结果',
            sourceReferences: const [AgentSourceReference(kind: 'event', ref: 'ref_test')],
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('查看日程'), findsOneWidget);
      expect(find.byType(Chip), findsOneWidget);
      expect(find.byType(ActionChip), findsNothing);
    });
  });
}
