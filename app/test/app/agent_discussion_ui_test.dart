import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_contract.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_page.dart';
import 'package:ustc_assistant_m0/app/app_shell_contract.dart';
import 'package:ustc_assistant_m0/app/calendar_workspace_contract.dart';
import 'package:ustc_assistant_m0/app/calendar_workspace_page.dart';
import 'package:ustc_assistant_m0/app/product_app.dart';
import 'package:ustc_assistant_m0/app/task_workspace_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/agent_discussion_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'calendar discussion callback receives only the typed reference',
    (tester) async {
      await _setSize(tester, const Size(1280, 900));
      final occurrence = _occurrence();
      final port = _CalendarPort(occurrence);
      addTearDown(port.dispose);
      AgentDiscussionSelection? selection;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CalendarWorkspacePage(
              controller: port,
              onDiscuss: (value) => selection = value,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey<CalendarReference>(occurrence.reference)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('calendar-detail-discuss')));

      expect(selection?.event, occurrence.reference);
      expect(selection?.task, isNull);
      expect(selection.toString(), 'AgentDiscussionSelection');
    },
  );

  testWidgets('calendar task tab forwards its typed task selection', (
    tester,
  ) async {
    await _setSize(tester, const Size(1280, 900));
    final calendarPort = _CalendarPort(_occurrence());
    final taskPort = _TaskPort();
    addTearDown(calendarPort.dispose);
    addTearDown(taskPort.dispose);
    AgentDiscussionSelection? selection;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CalendarWorkspacePage(
            controller: calendarPort,
            tasks: taskPort,
            onDiscuss: (value) => selection = value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('calendar-workspace-tab-tasks')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('task-detail-discuss')));

    expect(selection?.task, taskPort.task.reference);
    expect(selection?.event, isNull);
  });

  testWidgets(
    'prepared discussion prefills without sending or overwriting edits',
    (tester) async {
      final port = _AgentPort();
      addTearDown(port.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentWorkspacePage(controller: port, onSettings: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final reference = _occurrence().reference;
      await port.prepareDiscussion(AgentDiscussionSelection.event(reference));
      await tester.pumpAndSettle();
      final composer = tester.widget<TextField>(
        find.byKey(const ValueKey('agent-composer')),
      );
      expect(composer.controller!.text, '请帮我讨论这条已选择的日程。');
      expect(port.sent, isEmpty);

      await tester.enterText(
        find.byKey(const ValueKey('agent-composer')),
        '这是我正在修改的草稿。',
      );
      port.updateDiscussionDraft('不能覆盖用户正在编辑的内容。');
      await tester.pumpAndSettle();

      expect(composer.controller!.text, '这是我正在修改的草稿。');
      expect(port.sent, isEmpty);
    },
  );

  testWidgets(
    'external shell destination changes navigation and listener source',
    (tester) async {
      final shell = _UnusedShellPort();
      addTearDown(shell.dispose);
      final first = ValueNotifier(ShellDestination.settings);
      final replacement = ValueNotifier(ShellDestination.agenda);
      addTearDown(first.dispose);
      addTearDown(replacement.dispose);

      Widget app(ValueListenable<ShellDestination> destination) => ProductApp(
        controller: shell,
        destination: destination,
        settingsBuilder: (_) => const Text('设置视图'),
        agendaBuilder: (_) => const Text('日程视图'),
        agentBuilder: (_) => const Text('Agent 视图'),
      );

      await tester.pumpWidget(app(first));
      expect(find.text('设置视图'), findsOneWidget);

      first.value = ShellDestination.agent;
      await tester.pumpAndSettle();
      expect(find.text('Agent 视图'), findsOneWidget);

      await tester.pumpWidget(app(replacement));
      await tester.pumpAndSettle();
      expect(find.text('日程视图'), findsOneWidget);
      first.value = ShellDestination.settings;
      await tester.pumpAndSettle();
      expect(find.text('日程视图'), findsOneWidget);
      replacement.value = ShellDestination.settings;
      await tester.pumpAndSettle();
      expect(find.text('设置视图'), findsOneWidget);
    },
  );

  testWidgets(
    'local evidence exposes only typed current or historical navigation',
    (tester) async {
      final occurrence = _occurrence();
      final taskReference = TaskReference(_context, 77, 1);
      final historicalEvent = _evidence(
        'e_aaaaaaaaaaaaaaaa',
        provider: 'local',
        eventReference: occurrence.reference,
      );
      final historicalWithoutReference = _evidence(
        'e_bbbbbbbbbbbbbbbb',
        provider: 'local',
      );
      final localTask = _evidence(
        'e_cccccccccccccccc',
        provider: 'local',
        taskReference: taskReference,
      );
      final localWithoutReference = _evidence(
        'e_dddddddddddddddd',
        provider: 'local',
      );
      final publicWithReference = _evidence(
        'e_eeeeeeeeeeeeeeee',
        provider: 'finance',
        eventReference: occurrence.reference,
      );
      final ambiguousLocal = _evidence(
        'e_ffffffffffffffff',
        provider: 'local',
        eventReference: occurrence.reference,
        taskReference: taskReference,
      );
      final port = _AgentPort(
        messages: [
          AgentMessage(
            id: 1,
            role: AgentMessageRole.assistant,
            text: '历史回复',
            status: AgentMessageStatus.complete,
            createdAtUtc: DateTime.utc(2026, 10, 12),
            evidence: [historicalEvent, historicalWithoutReference],
          ),
          _message(2, '后续问题'),
          AgentMessage(
            id: 3,
            role: AgentMessageRole.assistant,
            text: '当前回复',
            status: AgentMessageStatus.complete,
            createdAtUtc: DateTime.utc(2026, 10, 13),
            evidence: [
              localTask,
              localWithoutReference,
              publicWithReference,
              ambiguousLocal,
            ],
          ),
        ],
      );
      addTearDown(port.dispose);
      final opened = <AgentEvidence>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentWorkspacePage(
              controller: port,
              onSettings: () {},
              onOpenLocalEvidence: opened.add,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(
          const ValueKey('agent-query-details-toggle-synthetic-conversation:1'),
        ),
      );
      await tester.pumpAndSettle();
      final historicalButton = find.byKey(
        ValueKey('agent-evidence-open-local-${historicalEvent.id}'),
      );
      expect(historicalButton, findsOneWidget);
      await tester.ensureVisible(historicalButton);
      await tester.tap(historicalButton);
      expect(opened, [historicalEvent]);

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('agent-message-3')),
        300,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('agent-message-list')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(
        find.byKey(
          const ValueKey('agent-query-details-toggle-synthetic-conversation:3'),
        ),
      );
      await tester.pumpAndSettle();
      final taskButton = find.byKey(
        ValueKey('agent-evidence-open-local-${localTask.id}'),
      );
      expect(taskButton, findsOneWidget);
      await tester.ensureVisible(taskButton);
      await tester.pumpAndSettle();
      await tester.tap(taskButton);
      expect(opened, [historicalEvent, localTask]);
      for (final evidence in [
        historicalWithoutReference,
        localWithoutReference,
        publicWithReference,
        ambiguousLocal,
      ]) {
        expect(
          find.byKey(ValueKey('agent-evidence-open-local-${evidence.id}')),
          findsNothing,
        );
      }
      expect(port.sent, isEmpty);
    },
  );

  testWidgets(
    'calendar initial selection follows load then C3 detail validation',
    (tester) async {
      await _setSize(tester, const Size(1280, 900));
      final occurrence = _occurrence();
      final port = _CalendarPort(occurrence);
      addTearDown(port.dispose);
      var consumed = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CalendarWorkspacePage(
              controller: port,
              initialSelection: occurrence.reference,
              onInitialNavigationConsumed: () => consumed++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(port.operations, ['select-null', 'load', 'select-reference']);
      expect(
        find.byKey(const ValueKey('calendar-detail-content')),
        findsOneWidget,
      );
      expect(find.text('合成日程'), findsWidgets);
      expect(consumed, 1);
    },
  );

  testWidgets(
    'calendar rejects stale initial selection without showing success',
    (tester) async {
      await _setSize(tester, const Size(1280, 900));
      final occurrence = _occurrence();
      final staleReference = CalendarReference(
        occurrence.reference.context,
        occurrence.reference.identity,
        occurrence.reference.version + 1,
      );
      final port = _CalendarPort(occurrence);
      addTearDown(port.dispose);
      var consumed = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CalendarWorkspacePage(
              controller: port,
              initialSelection: staleReference,
              onInitialNavigationConsumed: () => consumed++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(port.operations, ['select-null', 'load', 'select-reference']);
      expect(find.text('这条日程已更新或当前未能验证，请重新查询后再选择。'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('calendar-detail-content')),
        findsNothing,
      );
      expect(consumed, 1);
    },
  );

  testWidgets(
    'calendar applies a changed external selection to the existing query',
    (tester) async {
      await _setSize(tester, const Size(1280, 900));
      final occurrence = _occurrence();
      final port = _CalendarPort(occurrence);
      addTearDown(port.dispose);
      var consumed = 0;

      Widget page({CalendarReference? selection}) => MaterialApp(
        home: Scaffold(
          body: CalendarWorkspacePage(
            key: const ValueKey('calendar-with-external-selection'),
            controller: port,
            initialSelection: selection,
            onInitialNavigationConsumed: () => consumed++,
          ),
        ),
      );

      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(port.operations, ['select-null', 'load']);

      await tester.pumpWidget(page(selection: occurrence.reference));
      await tester.pumpAndSettle();

      expect(port.operations, ['select-null', 'load', 'select-reference']);
      expect(
        find.byKey(const ValueKey('calendar-detail-content')),
        findsOneWidget,
      );
      expect(consumed, 1);

      await tester.pumpWidget(page(selection: occurrence.reference));
      await tester.pumpAndSettle();
      expect(port.operations, ['select-null', 'load', 'select-reference']);
      expect(consumed, 1);
    },
  );

  testWidgets(
    'calendar task tab updates once and keeps later user navigation',
    (tester) async {
      await _setSize(tester, const Size(1280, 900));
      final calendarPort = _CalendarPort(_occurrence());
      final taskPort = _TaskPort();
      addTearDown(calendarPort.dispose);
      addTearDown(taskPort.dispose);
      var consumed = 0;

      Widget page({required bool initialTasks}) => MaterialApp(
        home: Scaffold(
          body: CalendarWorkspacePage(
            key: const ValueKey('calendar-initial-task-tab'),
            controller: calendarPort,
            tasks: taskPort,
            initialTasks: initialTasks,
            onInitialNavigationConsumed: () => consumed++,
          ),
        ),
      );

      await tester.pumpWidget(page(initialTasks: false));
      await tester.pumpAndSettle();
      await tester.pumpWidget(page(initialTasks: true));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(const ValueKey('calendar-workspace-tab-tasks')),
            )
            .selected,
        isTrue,
      );
      expect(
        find.byKey(const ValueKey('task-workspace-detail-content')),
        findsOneWidget,
      );
      expect(find.text('合成任务'), findsWidgets);
      expect(consumed, 1);

      await tester.pumpWidget(page(initialTasks: false));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(const ValueKey('calendar-workspace-tab-tasks')),
            )
            .selected,
        isTrue,
      );

      await tester.tap(
        find.byKey(const ValueKey('calendar-workspace-tab-schedule')),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(page(initialTasks: true));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(const ValueKey('calendar-workspace-tab-tasks')),
            )
            .selected,
        isTrue,
      );
      expect(consumed, 2);
      await tester.tap(
        find.byKey(const ValueKey('calendar-workspace-tab-schedule')),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(page(initialTasks: true));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(const ValueKey('calendar-workspace-tab-schedule')),
            )
            .selected,
        isTrue,
      );
      expect(consumed, 2);
    },
  );

  testWidgets(
    'older-history button is conditional and keeps existing messages',
    (tester) async {
      final recentMessage = _message(2, '最近的合成消息');
      final port = _AgentPort(
        historyTruncated: true,
        messages: [recentMessage],
      );
      addTearDown(port.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentWorkspacePage(controller: port, onSettings: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('agent-history-load-older')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('agent-history-load-older')));
      await tester.pumpAndSettle();

      expect(port.loadOlderCalls, 1);
      expect(find.text('较早的合成消息'), findsOneWidget);
      expect(find.text('最近的合成消息'), findsOneWidget);
    },
  );
}

Future<void> _setSize(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

final _context = CalendarContext(
  owner: 'synthetic',
  resetEpoch: 1,
  agendaEpoch: 1,
);

CalendarOccurrence _occurrence() => CalendarOccurrence(
  reference: CalendarReference(
    _context,
    const CalendarIdentity(CalendarKind.course, 41),
    1,
  ),
  title: '合成日程',
  startsAtUtc: DateTime.utc(2026, 10, 13, 1),
  endsAtUtc: DateTime.utc(2026, 10, 13, 2),
);

AgentEvidence _evidence(
  String id, {
  required String provider,
  CalendarReference? eventReference,
  TaskReference? taskReference,
}) => AgentEvidence(
  id: id,
  provider: provider,
  title: '合成出处',
  observedAtUtc: DateTime.utc(2026, 10, 13),
  scope: '合成范围',
  complete: true,
  eventReference: eventReference,
  taskReference: taskReference,
);

AgentMessage _message(int id, String text) => AgentMessage(
  id: id,
  role: AgentMessageRole.user,
  text: text,
  status: AgentMessageStatus.complete,
  createdAtUtc: DateTime.utc(2026, 10, 13, id),
);

final class _CalendarPort extends ChangeNotifier
    implements CalendarWorkspacePort {
  _CalendarPort(this.occurrence)
    : _view = CalendarWorkspaceView(
        day: DateTime.utc(2026, 10, 13),
        mode: CalendarViewMode.day,
        filter: CalendarFilter.all,
        includeInactive: false,
        window: CalendarWindow(
          context: _context,
          revision: 1,
          query: CalendarQuery(
            firstDay: DateTime.utc(2026, 10, 13),
            endDayExclusive: DateTime.utc(2026, 10, 14),
          ),
          items: [occurrence],
          segments: const [],
          conflicts: const [],
          matched: 1,
          truncated: false,
          conflictsTruncated: false,
        ),
      );

  final CalendarOccurrence occurrence;
  CalendarWorkspaceView _view;
  final List<String> operations = [];
  @override
  CalendarWorkspaceView get view => _view;
  @override
  DateTime get today => DateTime.utc(2026, 10, 13);

  @override
  Future<void> load({
    DateTime? day,
    CalendarViewMode? mode,
    CalendarFilter? filter,
    bool? includeInactive,
  }) async {
    operations.add('load');
  }

  @override
  Future<void> select(CalendarReference? reference) async {
    operations.add(reference == null ? 'select-null' : 'select-reference');
    _view = CalendarWorkspaceView(
      day: _view.day,
      mode: _view.mode,
      filter: _view.filter,
      includeInactive: _view.includeInactive,
      window: _view.window,
      detail: reference == occurrence.reference
          ? CalendarDetail(
              occurrence: occurrence,
              personalDraft: null,
              relations: const [],
            )
          : null,
    );
    notifyListeners();
  }

  @override
  Future<CalendarWriteReceipt> execute(
    CalendarIntent intent, {
    required CalendarContext expectedContext,
  }) async => throw UnimplementedError();
}

final class _TaskPort extends ChangeNotifier implements TaskWorkspacePort {
  _TaskPort()
    : task = TaskRecord(
        reference: TaskReference(_context, 62, 1),
        draft: const TaskDraft(title: '合成任务'),
        status: TaskStatus.active,
        createdAtUtc: DateTime.utc(2026, 10, 13),
        updatedAtUtc: DateTime.utc(2026, 10, 13),
        blockCount: 0,
      ) {
    _view = TaskWorkspaceView(
      window: TaskWindow(
        context: _context,
        revision: 1,
        query: const TaskQuery(),
        items: [task],
        matched: 1,
        truncated: false,
      ),
      detail: TaskDetail(
        task: task,
        blocks: const [],
        nowUtc: DateTime.utc(2026, 10, 13),
      ),
    );
  }

  final TaskRecord task;
  late TaskWorkspaceView _view;
  @override
  TaskWorkspaceView get taskView => _view;
  @override
  DateTime get today => DateTime.utc(2026, 10, 13);

  @override
  Future<void> loadTasks({TaskQuery? query}) async {}

  @override
  Future<void> selectTask(TaskReference? reference) async {}

  @override
  Future<CalendarWriteReceipt> executeTask(
    CalendarIntent intent, {
    required CalendarContext expectedContext,
  }) async => throw UnimplementedError();
}

final class _AgentPort extends ChangeNotifier
    implements
        AgentWorkspacePort,
        AgentDiscussionWorkspacePort,
        AgentHistoryWorkspacePort {
  _AgentPort({
    bool historyTruncated = false,
    List<AgentMessage> messages = const [],
  }) : _view = _agentView(
         historyTruncated: historyTruncated,
         messages: messages,
       );

  AgentRuntimeView _view;
  final List<String> sent = [];
  int loadOlderCalls = 0;
  @override
  AgentRuntimeView get view => _view;

  @override
  Future<void> refresh() async {}

  @override
  Future<void> send(String text, {List<AgentImage> images = const []}) async {
    sent.add(text);
  }

  @override
  Future<void> prepareDiscussion(AgentDiscussionSelection selection) async {
    _view = _agentView(
      historyTruncated: _view.historyTruncated,
      messages: _view.messages,
      discussionId: 'synthetic-discussion',
      discussionDraft: '请帮我讨论这条已选择的日程。',
    );
    notifyListeners();
  }

  void updateDiscussionDraft(String draft) {
    _view = _agentView(
      historyTruncated: _view.historyTruncated,
      messages: _view.messages,
      discussionId: _view.discussionId,
      discussionDraft: draft,
    );
    notifyListeners();
  }

  @override
  Future<void> loadOlderMessages() async {
    loadOlderCalls++;
    _view = _agentView(
      messages: [..._view.messages, _message(1, '较早的合成消息')],
      historyTruncated: false,
      discussionId: _view.discussionId,
      discussionDraft: _view.discussionDraft,
    );
    notifyListeners();
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AgentRuntimeView _agentView({
  bool historyTruncated = false,
  List<AgentMessage> messages = const [],
  String? discussionId,
  String? discussionDraft,
}) => AgentRuntimeView(
  settings: AgentSettingsSnapshot(
    authority: const AgentAuthority(
      owner: 'synthetic',
      resetEpoch: 1,
      historyEpoch: 1,
      configRevision: 1,
    ),
    keySaved: true,
    consent: true,
    modelId: 'synthetic-model',
    report: const AgentCapabilityReport(text: true, streaming: true),
  ),
  conversationId: 'synthetic-conversation',
  historyTruncated: historyTruncated,
  messages: messages,
  discussionId: discussionId,
  discussionDraft: discussionDraft,
);

final class _UnusedShellPort extends ChangeNotifier implements AppShellPort {
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
