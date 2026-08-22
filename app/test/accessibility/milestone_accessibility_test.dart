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
import 'package:ustc_assistant_app/features/agent/application/agent_permission_policy_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_session_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_tool_registry.dart';
import 'package:ustc_assistant_app/features/agent/application/cancellation_signal.dart';
import 'package:ustc_assistant_app/features/agent/application/outbound_privacy_filter.dart';
import 'package:ustc_assistant_app/features/agent/data/drift_chat_repository.dart';
import 'package:ustc_assistant_app/features/agent/data/protected_agent_secret_store.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_permission_policy.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_tool.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_write_proposal.dart';
import 'package:ustc_assistant_app/features/agent/domain/llm_protocol.dart';
import 'package:ustc_assistant_app/features/agent/presentation/agent_chat_page.dart';
import 'package:ustc_assistant_app/features/agent/presentation/agent_settings_page.dart';
import 'package:ustc_assistant_app/features/agent/presentation/agent_write_confirmation_card.dart';
import 'package:ustc_assistant_app/features/agent/presentation/safe_markdown_message.dart';
import 'package:ustc_assistant_app/features/schedule/application/conflict_service.dart';
import 'package:ustc_assistant_app/features/schedule/domain/schedule_projection.dart';
import 'package:ustc_assistant_app/features/schedule/presentation/conflict_editor.dart';
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

  // Task 7/8: the local-action chip (rendered when a schedule/task tool ran)
  // exposes an accessible label via its ActionChip text, so assistive tech
  // announces the navigation target. Minimal semantics assertion matching the
  // existing lightweight style.
  testWidgets('local action chip exposes an accessible label', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SafeMarkdownMessage(
            text: '查询结果',
            localActions: const [AgentLocalAction.schedule],
            onLocalAction: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    // The chip's label text is the accessible name (ActionChip surfaces its
    // Text label as semantics).
    expect(find.bySemanticsLabel('查看日程'), findsOneWidget);
    expect(find.byType(ActionChip), findsOneWidget);
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
            policyService: AgentPermissionPolicyService(
              database: database,
              clock: FixedBeijingClock(DateTime.fromMillisecondsSinceEpoch(1)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The school model-service section title is rendered as accessible text
    // (the iCourse-consent switch was retired in the v9 minimal convergence).
    expect(
      find.text('学校模型服务'),
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

  // Task 10: the write confirmation card (the approval gate of every write
  // tool) exposes its operation label, its safe preview lines and the
  // approve/reject actions as text semantics; a critical card never offers
  // the "以后不再确认" action.
  testWidgets('write confirmation card exposes approve action and safe preview semantics', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentWriteConfirmationCard(
            proposal: const AgentWriteProposalView(
              operationLabel: '安排任务时间段',
              riskLevel: RiskLevel.medium,
              actionType: 'plan_task',
              targetType: 'task',
              previewLines: ['目标：复习算法', '时间：2026-08-06 14:00-16:00'],
              rememberAllowed: true,
            ),
            onApprove: () async {},
            onReject: () async {},
            onRemember: () async {},
            onGoToSettings: () async {},
          ),
        ),
      ),
    );
    await tester.pump();
    // Operation label, safe preview and both actions are plain text semantics.
    expect(find.text('安排任务时间段'), findsOneWidget);
    expect(find.text('目标：复习算法'), findsOneWidget);
    expect(find.bySemanticsLabel('确认本次'), findsOneWidget);
    expect(find.bySemanticsLabel('取消'), findsOneWidget);

    // A critical card (whole-day course move) never offers the remember
    // action — assistive tech must not announce it either.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentWriteConfirmationCard(
            proposal: const AgentWriteProposalView(
              operationLabel: '整日移动教务课程',
              riskLevel: RiskLevel.critical,
              actionType: 'move_jw_course_day',
              targetType: 'course_day',
              previewLines: ['源日期：2026-08-03', '目标日期：2026-08-09', '课程数：1'],
              rememberAllowed: false,
            ),
            onApprove: () async {},
            onReject: () async {},
            onRemember: () async {},
            onGoToSettings: () async {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('整日移动教务课程'), findsOneWidget);
    expect(find.text('课程数：1'), findsOneWidget);
    expect(find.bySemanticsLabel('此类型以后不再确认'), findsNothing);
  });

  // Task 5/8: the mixed relation editor (event + PlanBlock pair) exposes the
  // pair as accessible text (both participant titles), keeps the conflict-state
  // control reachable, and — because a PlanBlock participant has no overlay
  // foreground priority — never announces a "优先显示" foreground radio. This
  // is the accessibility face of the event/PlanBlock no_conflict UI relation.
  testWidgets('mixed relation editor exposes pair titles and state, no foreground radio', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final course = ScheduleConflictParticipant(
      kind: 'event',
      id: 'ev-1',
      title: '电路基本理论',
      occurrenceDate: DateTime(2026, 3, 3),
      startAt: DateTime(2026, 3, 3, 8, 0),
      endAt: DateTime(2026, 3, 3, 9, 40),
      seriesType: 'course_series',
      seriesId: 'series-circuit',
    );
    final block = ScheduleConflictParticipant(
      kind: 'plan_block',
      id: 'block-1',
      title: '复习电路',
      occurrenceDate: DateTime(2026, 3, 3),
      startAt: DateTime(2026, 3, 3, 8, 30),
      endAt: DateTime(2026, 3, 3, 10, 0),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConflictEditor(
            pairs: [
              ConflictPairDraft(
                id: 'ev-1|block-1',
                left: course,
                right: block,
                leftTitle: '电路基本理论',
                rightTitle: '复习电路',
              ),
            ],
            onClassify: (_, _, _, {required scope, reason}) async {},
          ),
        ),
      ),
    );
    await tester.pump();

    // Both participant titles are plain accessible text for the pair.
    expect(find.text('电路基本理论 / 复习电路'), findsOneWidget);
    // The conflict-state control is reachable and offers the categories.
    expect(find.byKey(const Key('conflict-state-ev-1|block-1')), findsOneWidget);
    // No "优先显示" foreground radio exists for a pair containing a PlanBlock.
    expect(find.text('优先显示'), findsNothing);
  });
}
