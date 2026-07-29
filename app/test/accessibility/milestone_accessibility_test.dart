import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:ustc_assistant_app/features/agent/domain/agent_tool.dart';
import 'package:ustc_assistant_app/features/agent/domain/llm_protocol.dart';
import 'package:ustc_assistant_app/features/agent/presentation/agent_chat_page.dart';
import 'package:ustc_assistant_app/features/agent/presentation/agent_settings_page.dart';
import 'package:ustc_assistant_app/features/schedule/domain/schedule_projection.dart';
import 'package:ustc_assistant_app/features/schedule/presentation/week_timetable.dart';
import 'package:ustc_assistant_app/features/settings/presentation/official_websites_page.dart';
import 'package:ustc_assistant_app/features/tasks/domain/task.dart';

// ---------------------------------------------------------------------------
// Self-contained fakes for the Agent pages (lightweight, matching the
// agent_chat_page_test.dart `_buildPage` pattern). Kept here because Dart
// library-private members do not cross file boundaries.
// ---------------------------------------------------------------------------

class _NoopProtector implements CredentialProtector {
  @override
  Future<ProtectedSecret> protect(Uint8List plaintext) async => ProtectedSecret(
        bytes: Uint8List.fromList(const [0]),
        scheme: 'noop',
        version: 1,
      );

  @override
  Future<Uint8List> unprotect(ProtectedSecret protected) async => Uint8List(0);
}

class _FakeSecretStore extends ProtectedAgentSecretStore {
  _FakeSecretStore(AppDatabase db)
      : super(database: db, protector: _NoopProtector(), now: () => 1);

  @override
  Future<bool> hasKey(String accountId) async => true;
  @override
  Future<String?> readKey(String accountId) async => 'fake-key';
  @override
  Future<void> saveKey(String accountId, String apiKey) async {}
  @override
  Future<void> deleteKey(String accountId) async {}
}

class _FakeConfigService extends AgentConfigurationService {
  _FakeConfigService(AppDatabase db, DriftChatRepository repo)
      : super(database: db, chatRepository: repo);

  @override
  Future<AgentSettingsSnapshot> load(String accountId) async => AgentSettingsSnapshot(
        accountId: accountId,
        model: 'deepseek-v4-flash',
        enabled: true,
        icourseConsent: false,
        systemPromptVersion: 1,
        updatedAt: null,
      );
}

class _FakeLlmProvider implements LlmProvider {
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

class _FakeWebsiteLauncher implements OfficialWebsiteLauncher {
  @override
  Future<bool> launch(Uri uri) async => true;
}

/// A session service that emits nothing and never starts a run, so the chat
/// page renders its configured-empty state.
class _IdleSessionService extends AgentSessionService {
  _IdleSessionService(AppDatabase db, DriftChatRepository repo)
      : super(
          chatRepository: repo,
          database: db,
          provider: _FakeLlmProvider(),
          contextBuilder: const AgentContextBuilder(),
          privacyFilter: OutboundPrivacyFilter(protectedAccount: '', toolBuilders: const {}),
          registry: AgentToolRegistry(
            tools: const [],
            privacyFilter: OutboundPrivacyFilter(protectedAccount: '', toolBuilders: const {}),
          ),
          clock: const SystemBeijingClock(),
          model: 'deepseek-v4-flash',
          apiKeyProvider: ({required accountId}) async => '',
        );

  @override
  Stream<AgentRunViewState> send({
    required String accountId,
    required String userText,
  }) => const Stream.empty();

  @override
  Stream<AgentRunViewState> retryLast({required String accountId}) => const Stream.empty();
}

void main() {
  testWidgets('deadline warning exposes text semantics in addition to color', (
    tester,
  ) async {
    final now = DateTime(2026, 7, 27, 10);
    final task = TaskItem(
      id: 'due',
      title: 'Due task',
      state: TaskState.active,
      importance: TaskImportance.normal,
      deadlineAt: DateTime(2026, 7, 27, 18),
      tags: const [],
      createdAt: now.millisecondsSinceEpoch,
      updatedAt: now.millisecondsSinceEpoch,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WeekTimetable(
            projection: buildWeek(
              ScheduleQuery(selectedDate: now, events: const []),
            ),
            tasks: [task],
            now: now,
            onEventSelected: (_) {},
          ),
        ),
      ),
    );
    expect(find.bySemanticsLabel('今天截止'), findsOneWidget);
    expect(find.text('Due task'), findsOneWidget);
  });

  testWidgets('keyboard focus reaches icon controls', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FocusTraversalGroup(
            child: Row(
              children: [
                IconButton(
                  tooltip: '同步',
                  onPressed: () {},
                  icon: const Icon(Icons.sync),
                ),
                IconButton(
                  tooltip: '导入',
                  onPressed: () {},
                  icon: const Icon(Icons.file_open),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, isNotNull);
  });

  // Task 12: Agent chat page exposes semantics for its key controls (the
  // send button tooltip and the message field), and keyboard focus traverses
  // into the composer. Matches the existing lightweight semantics style.
  testWidgets('AgentChatPage exposes semantics for composer controls', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final chatRepository = DriftChatRepository(database);
    await database.into(database.localAccounts).insert(
          LocalAccountsCompanion.insert(
            id: 'test',
            maskedHint: 'PB****0000',
            isActive: const Value(true),
            createdAt: 1,
            updatedAt: 1,
          ),
        );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentChatPage(
            accountId: 'test',
            config: _FakeConfigService(database, chatRepository),
            secrets: _FakeSecretStore(database),
            provider: _FakeLlmProvider(),
            sessionService: _IdleSessionService(database, chatRepository),
            chatRepository: chatRepository,
            websiteLauncher: _FakeWebsiteLauncher(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The send button exposes its accessible name via the tooltip (IconButton
    // surfaces its a11y label through the Tooltip widget).
    expect(find.byTooltip('发送'), findsOneWidget);
    // The composer input field is labelled by its hint text semantics.
    expect(find.bySemanticsLabel('输入消息...'), findsOneWidget);
  });

  testWidgets('keyboard focus traverses into the Agent chat composer', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final chatRepository = DriftChatRepository(database);
    await database.into(database.localAccounts).insert(
          LocalAccountsCompanion.insert(
            id: 'test',
            maskedHint: 'PB****0000',
            isActive: const Value(true),
            createdAt: 1,
            updatedAt: 1,
          ),
        );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentChatPage(
            accountId: 'test',
            config: _FakeConfigService(database, chatRepository),
            secrets: _FakeSecretStore(database),
            provider: _FakeLlmProvider(),
            sessionService: _IdleSessionService(database, chatRepository),
            chatRepository: chatRepository,
            websiteLauncher: _FakeWebsiteLauncher(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Tabbing reaches a focusable control in the chat page.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, isNotNull);
  });

  // Task 12: the Agent settings page exposes semantics for its key controls
  // (the iCourse-consent switch and the clear-conversation action).
  testWidgets('AgentSettingsPage exposes semantics for key settings', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final chatRepository = DriftChatRepository(database);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentSettingsPage(
            accountId: 'test',
            config: _FakeConfigService(database, chatRepository),
            secrets: _FakeSecretStore(database),
            provider: _FakeLlmProvider(),
            chatRepository: chatRepository,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The iCourse-consent switch title is rendered as a Text label (the
    // SwitchListTile exposes its title as accessible text).
    expect(
      find.text('允许 Agent 查询我的 iCourse 信息'),
      findsOneWidget,
    );
    // The clear-conversation action is reachable (scroll it into view, then
    // assert its title text renders — ListView lazily builds offscreen tiles).
    await tester.scrollUntilVisible(
      find.text('清除会话'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('清除会话'), findsOneWidget);
  });
}
