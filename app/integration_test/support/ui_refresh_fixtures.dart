import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_contract.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_page.dart';
import 'package:ustc_assistant_m0/app/app_shell_contract.dart';
import 'package:ustc_assistant_m0/app/calendar_workspace_contract.dart';
import 'package:ustc_assistant_m0/app/calendar_workspace_page.dart';
import 'package:ustc_assistant_m0/app/product_app.dart';
import 'package:ustc_assistant_m0/app/source_settings_page.dart';
import 'package:ustc_assistant_m0/app/task_workspace_contract.dart';
import 'package:ustc_assistant_m0/core/agenda_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/jw_academic_details.dart';
import 'package:ustc_assistant_m0/core/morning_brief_contract.dart';
import 'package:ustc_assistant_m0/core/morning_notice_contract.dart';
import 'package:ustc_assistant_m0/core/public_query_contract.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/core/speech_input_contract.dart';
import 'package:ustc_assistant_m0/jobs/jw_sync_port.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_port.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';

final uiRefreshToday = DateTime.utc(2026, 10, 12);
final uiRefreshNowUtc = DateTime.utc(2026, 10, 12, 4);

const uiRefreshContext = CalendarContext(
  owner: 'ui-refresh-synthetic-owner',
  resetEpoch: 1,
  agendaEpoch: 1,
);

/// Wires the production shell and production workspaces to bounded synthetic
/// ports. No runtime bootstrap, local database, credential or service is used.
final class UiRefreshGalleryFixture {
  UiRefreshGalleryFixture({bool startWithApproval = true})
    : shell = UiRefreshShellPort(),
      agent = UiRefreshAgentPort(startWithApproval: startWithApproval),
      calendar = UiRefreshCalendarPort(),
      reminders = UiRefreshReminderPort();

  final UiRefreshShellPort shell;
  final UiRefreshAgentPort agent;
  final UiRefreshCalendarPort calendar;
  final UiRefreshReminderPort reminders;
  final speech = UiRefreshSpeechPort();
  final ValueNotifier<ShellDestination> destination = ValueNotifier(
    ShellDestination.agent,
  );

  Widget buildApp() => RepaintBoundary(
    key: const ValueKey('ui-refresh-gallery-capture'),
    child: ProductApp(
      controller: shell,
      destination: destination,
      onDestinationChanged: (next) => destination.value = next,
      agentBuilder: (context) => AgentWorkspacePage(
        controller: agent,
        speechInput: speech,
        onSettings: () => destination.value = ShellDestination.settings,
        morningView: uiRefreshMorningView,
        morningChanges: const Stream<MorningRuntimeView>.empty(),
        morningNowUtc: () => uiRefreshNowUtc,
        onMorningRetry: () async {
          agent.morningRetryCalls++;
        },
        openMorningSource: (uri) async => agent.openedMorningSources.add(uri),
      ),
      agendaBuilder: (context) => CalendarWorkspacePage(
        controller: calendar,
        tasks: calendar,
        reminders: reminders,
        calendarTaskNowUtc: uiRefreshNowUtc,
      ),
      settingsBuilder: (context) => SourceSettingsPage(controller: shell),
    ),
  );

  List<String> get unexpectedCalls => [
    ...shell.unexpectedCalls,
    ...shell.jw.unexpectedCalls,
    ...shell.young.unexpectedCalls,
    ...agent.unexpectedCalls,
    ...calendar.unexpectedCalls,
    ...reminders.unexpectedCalls,
    ...speech.unexpectedCalls,
  ];

  void dispose() {
    destination.dispose();
    shell.dispose();
    calendar.dispose();
    agent.dispose();
  }
}

final class UiRefreshAgentPort extends ChangeNotifier
    implements
        AgentWorkspacePort,
        AgentActionWorkspacePort,
        AgentWorkspaceUsePolicyPort {
  UiRefreshAgentPort({bool startWithApproval = true})
    : _pendingAction = startWithApproval ? _action('gallery-approval') : null,
      _phase = startWithApproval
          ? AgentPhase.waitingForApproval
          : AgentPhase.idle {
    _messages = _baseMessages();
    _view = _buildView();
  }

  static const _conversationId = 'ui-refresh-synthetic-conversation';
  static const _authority = AgentAuthority(
    owner: 'ui-refresh-synthetic-agent',
    resetEpoch: 1,
    historyEpoch: 1,
    configRevision: 1,
  );

  final List<String> unexpectedCalls = [];
  final List<String> approvedActionIds = [];
  final List<String> rejectedActionIds = [];
  final List<Uri> openedMorningSources = [];
  int refreshCalls = 0;
  int morningRetryCalls = 0;
  int _nextMessageId = 10;
  int _historyEpoch = 1;
  bool _adviceOnly = false;
  bool _personalContentAllowed = true;
  bool _dailyOperationsAllowed = false;
  AgentPhase _phase;
  AgentActionView? _pendingAction;
  List<AgentMessage> _messages = [];
  AgentRuntimeView _view = AgentRuntimeView();

  @override
  AgentWorkspaceView get view => _view;

  void offerApproval(String id) {
    _pendingAction = _action(id);
    _phase = AgentPhase.waitingForApproval;
    _publish();
  }

  void invalidateApprovalByHistoryEpoch() {
    _historyEpoch++;
    _pendingAction = null;
    _phase = AgentPhase.idle;
    _publish();
  }

  void _publish() {
    _view = _buildView();
    notifyListeners();
  }

  AgentRuntimeView _buildView() {
    final settings = AgentSettingsSnapshot(
      authority: AgentAuthority(
        owner: _authority.owner,
        resetEpoch: _authority.resetEpoch,
        historyEpoch: _historyEpoch,
        configRevision: _authority.configRevision,
      ),
      keySaved: true,
      consent: true,
      modelId: 'ui-refresh-synthetic-model',
      modelIds: const ['ui-refresh-synthetic-model'],
      report: const AgentCapabilityReport(
        text: true,
        streaming: true,
        toolCall: true,
        toolResult: true,
      ),
    );
    return AgentRuntimeView(
      phase: _phase,
      settings: settings,
      availableModels: const ['ui-refresh-synthetic-model'],
      conversations: [
        AgentConversation(
          id: _conversationId,
          title: '合成周表与任务安排',
          updatedAtUtc: uiRefreshNowUtc,
        ),
      ],
      messages: _messages,
      reasoningByMessage: const {
        2: AgentReasoningView(text: '先读取本地周表，再核对重叠时段和任务截止日期；引用只说明展示出处。'),
      },
      conversationId: _conversationId,
      pendingAction: _pendingAction,
      businessToolsEnabled: true,
      modelCalls: 1,
      toolCalls: 2,
      usePolicyConfigured: true,
      personalContentAllowed: _personalContentAllowed,
      dailyOperationsAllowed: _dailyOperationsAllowed,
      adviceOnly: _adviceOnly,
    );
  }

  @override
  Future<void> setAdviceOnly(bool value) async {
    _adviceOnly = value;
    _publish();
  }

  @override
  Future<void> saveUsePolicy({
    required bool personalContentAllowed,
    required bool dailyOperationsAllowed,
  }) async {
    _personalContentAllowed = personalContentAllowed;
    _dailyOperationsAllowed = dailyOperationsAllowed;
    _publish();
  }

  @override
  Future<void> refresh() async {
    refreshCalls++;
  }

  @override
  Future<void> loadModels({String key = '', required bool consent}) async {
    if (key.isNotEmpty) _unexpected('AgentWorkspacePort.loadModels:key');
    _unexpected('AgentWorkspacePort.loadModels');
  }

  @override
  Future<void> verifyAndSave({
    String key = '',
    required String modelId,
    required bool consent,
  }) async => _unexpected('AgentWorkspacePort.verifyAndSave');

  @override
  Future<void> newConversation() async {
    _messages = [];
    _pendingAction = null;
    _phase = AgentPhase.idle;
    _historyEpoch++;
    _publish();
  }

  @override
  Future<void> selectConversation(String id) async {
    if (id != _conversationId) {
      _unexpected('AgentWorkspacePort.selectConversation:$id');
    }
    _messages = _baseMessages();
    _pendingAction = null;
    _phase = AgentPhase.idle;
    _publish();
  }

  @override
  Future<void> send(String text, {List<AgentImage> images = const []}) async {
    if (!view.canSend || text.trim().isEmpty || images.isNotEmpty) {
      _unexpected('AgentWorkspacePort.send:unsupported synthetic request');
    }
    _messages = [
      ..._messages,
      AgentMessage(
        id: _nextMessageId++,
        role: AgentMessageRole.user,
        text: text.trim(),
        status: AgentMessageStatus.complete,
        createdAtUtc: uiRefreshNowUtc,
      ),
      AgentMessage(
        id: _nextMessageId++,
        role: AgentMessageRole.assistant,
        text: '这是由合成端口返回的界面验收回复。',
        status: AgentMessageStatus.complete,
        createdAtUtc: uiRefreshNowUtc,
      ),
    ];
    _publish();
  }

  @override
  Future<void> stop() async {
    if (_phase != AgentPhase.generating) {
      _unexpected('AgentWorkspacePort.stop:idle');
    }
    _phase = AgentPhase.idle;
    _publish();
  }

  @override
  Future<void> deleteKey({required bool confirmed}) async =>
      _unexpected('AgentWorkspacePort.deleteKey');

  @override
  Future<void> setModelConsent(bool consent) async =>
      _unexpected('AgentWorkspacePort.setModelConsent');

  @override
  Future<void> clearHistory({
    String? conversationId,
    required bool confirmed,
  }) async {
    if (!confirmed ||
        (conversationId != null && conversationId != _conversationId)) {
      _unexpected('AgentWorkspacePort.clearHistory:invalid confirmation');
    }
    _messages = [];
    _pendingAction = null;
    _phase = AgentPhase.idle;
    _historyEpoch++;
    _publish();
  }

  @override
  String safeValidationSummary() => 'synthetic-ui-refresh';

  @override
  Future<void> approveAction(String actionId) async {
    final action = _currentAction(actionId);
    approvedActionIds.add(actionId);
    _finishAction(action, AgentActionStatus.committed);
  }

  @override
  Future<void> rejectAction(String actionId) async {
    final action = _currentAction(actionId);
    rejectedActionIds.add(actionId);
    _finishAction(action, AgentActionStatus.rejected);
  }

  @override
  Future<void> continueSchool() async =>
      _unexpected('AgentActionWorkspacePort.continueSchool');

  AgentActionView _currentAction(String id) {
    final action = _pendingAction;
    if (action == null ||
        action.id != id ||
        _phase != AgentPhase.waitingForApproval) {
      _unexpected('AgentActionWorkspacePort.staleAction:$id');
    }
    return action;
  }

  void _finishAction(AgentActionView action, AgentActionStatus status) {
    _messages = [
      ..._messages,
      AgentMessage(
        id: _nextMessageId++,
        role: AgentMessageRole.assistant,
        text: status == AgentActionStatus.committed ? '合成方案已提交。' : '合成方案已拒绝。',
        status: AgentMessageStatus.complete,
        createdAtUtc: uiRefreshNowUtc,
        actions: [
          AgentActionView(
            id: action.id,
            kind: action.kind,
            status: status,
            title: action.title,
            details: action.details,
            warning: action.warning,
            committedCount: status == AgentActionStatus.committed ? 1 : 0,
            authorization: AgentActionAuthorization.confirmed,
          ),
        ],
      ),
    ];
    _pendingAction = null;
    _phase = AgentPhase.idle;
    _publish();
  }

  List<AgentMessage> _baseMessages() => [
    AgentMessage(
      id: 1,
      role: AgentMessageRole.user,
      text: '请核对这周的课程、冲突和报告截止时间。',
      status: AgentMessageStatus.complete,
      createdAtUtc: DateTime.utc(2026, 10, 12, 3, 30),
    ),
    AgentMessage(
      id: 2,
      role: AgentMessageRole.assistant,
      text: '周一上午有两项日程重叠，报告截止时间是今天 17:00。[[ui-refresh-evidence]]',
      status: AgentMessageStatus.complete,
      createdAtUtc: uiRefreshNowUtc,
      steps: const [
        AgentToolStep(tool: 'query_agenda', status: 'success'),
        AgentToolStep(tool: 'query_tasks', status: 'success'),
      ],
      evidence: [
        AgentEvidence(
          id: 'ui-refresh-evidence',
          provider: 'local',
          title: '合成周表与任务投影',
          observedAtUtc: uiRefreshNowUtc,
          scope: '本地合成周表',
          complete: true,
          snippet: '课程地点：合成教学楼 · 合成教室 5304。',
        ),
      ],
    ),
  ];

  static AgentActionView _action(String id) => AgentActionView(
    id: id,
    kind: AgentActionKind.localPlan,
    status: AgentActionStatus.proposed,
    title: '把报告整理安排加入任务清单？',
    details: const ['仅新增一条本地合成任务。', '不访问学校或模型服务。'],
    warning: '提交前仍会重新核对当前本地状态。',
  );

  Never _unexpected(String method) {
    unexpectedCalls.add(method);
    throw StateError('Unexpected synthetic Agent port call: $method');
  }
}

/// Gives the real composer its microphone control without recording sound.
final class UiRefreshSpeechPort implements SpeechInputPort {
  final List<String> unexpectedCalls = [];
  @override
  SpeechInputView get view => const SpeechInputView();
  @override
  Stream<SpeechInputView> get changes => const Stream.empty();
  @override
  Future<void> start() async {
    unexpectedCalls.add('speech.start');
    throw StateError('The synthetic gallery does not record audio.');
  }

  @override
  Future<void> finish() async {
    unexpectedCalls.add('speech.finish');
    throw StateError('The synthetic gallery has no recorded audio.');
  }

  @override
  Future<void> cancel() async {}
  @override
  Future<void> close() async {}
}

final class UiRefreshShellPort extends ChangeNotifier implements AppShellPort {
  UiRefreshShellPort()
    : jw = UiRefreshJwSyncPort(),
      young = UiRefreshYoungSyncPort();

  @override
  final UiRefreshJwSyncPort jw;

  @override
  final UiRefreshYoungSyncPort young;

  final List<String> unexpectedCalls = [];

  @override
  AppShellView get view =>
      AppShellView(jw: jw.syncView, young: young.syncView, globallyBusy: false);

  @override
  DateTime get today => uiRefreshToday;

  @override
  AgendaSlice readAgenda({
    required DateTime day,
    AgendaFilter filter = AgendaFilter.all,
    bool includeHidden = false,
  }) => AgendaSlice(
    day: day,
    filter: filter,
    includeHidden: includeHidden,
    items: const [],
    matched: 0,
    totalStored: 0,
    ready: true,
    truncated: false,
  );

  @override
  Future<void> setHidden(
    AgendaReference reference, {
    required bool hidden,
  }) async {
    unexpectedCalls.add('AppShellPort.setHidden');
    throw StateError('Unexpected synthetic shell write.');
  }
}

final class UiRefreshJwSyncPort implements JwSyncPort {
  final List<String> unexpectedCalls = [];

  @override
  JwSyncView get syncView => JwSyncView(
    phase: JwSyncPhase.recovery,
    ready: true,
    failure: FailureCode.cleanupPending,
    failureStage: JwSyncPhase.committing,
    courseCount: 3,
    importCommitted: true,
  );

  @override
  Stream<JwSyncView> get syncChanges => const Stream<JwSyncView>.empty();

  @override
  Future<void> open({String? expectedAccountCode}) async => _unexpected('open');

  @override
  Future<void> startSync({
    String? expectedAccountCode,
    String? password,
    bool savePassword = false,
    int? semesterId,
  }) async => _unexpected('startSync');

  @override
  Future<void> continueSync() async => _unexpected('continueSync');

  @override
  Future<void> deleteSavedCredential() async =>
      _unexpected('deleteSavedCredential');

  @override
  Future<void> navigateJwPage(JwObservationPage page) async =>
      _unexpected('navigateJwPage');

  @override
  Future<void> verifyDirectory() async => _unexpected('verifyDirectory');

  @override
  Future<void> collect(int semesterId) async => _unexpected('collect');

  @override
  Future<void> cancel() async => _unexpected('cancel');

  @override
  Future<void> retryRecovery() async => _unexpected('retryRecovery');

  @override
  Future<void> clearSession() async => _unexpected('clearSession');

  @override
  Future<void> setHidden({
    required int localId,
    required int expectedVersion,
    required bool hidden,
  }) async => _unexpected('setHidden');

  Never _unexpected(String method) {
    unexpectedCalls.add('JwSyncPort.$method');
    throw StateError('Unexpected synthetic JW source call: $method');
  }
}

final class UiRefreshYoungSyncPort implements YoungSyncPort {
  final List<String> unexpectedCalls = [];

  @override
  YoungSyncView get syncView => YoungSyncView();

  @override
  Stream<YoungSyncView> get syncChanges => const Stream<YoungSyncView>.empty();

  @override
  Future<void> startCalendar({
    String? expectedAccountCode,
    required DateTime firstDay,
    required DateTime lastDay,
    String? password,
    bool savePassword = false,
  }) async => _unexpected('startCalendar');

  @override
  Future<void> startActivities({
    String? expectedAccountCode,
    String? password,
    bool savePassword = false,
  }) async => _unexpected('startActivities');

  @override
  Future<void> continueAfterLogin() async => _unexpected('continueAfterLogin');

  @override
  Future<void> cancel() async => _unexpected('cancel');

  @override
  Future<void> retryRecovery() async => _unexpected('retryRecovery');

  @override
  Future<void> clearSession() async => _unexpected('clearSession');

  @override
  Future<void> deleteSavedCredential() async =>
      _unexpected('deleteSavedCredential');

  @override
  Future<void> setHidden({
    required int localId,
    required int expectedVersion,
    required bool hidden,
  }) async => _unexpected('setHidden');

  Never _unexpected(String method) {
    unexpectedCalls.add('YoungSyncPort.$method');
    throw StateError('Unexpected synthetic Young source call: $method');
  }
}

final class UiRefreshCalendarPort extends ChangeNotifier
    implements
        CalendarWorkspacePort,
        TaskWorkspacePort,
        CalendarTaskWorkspacePort {
  UiRefreshCalendarPort() {
    _selectedTask = _task.reference;
    _taskWindow = _buildTaskWindow(const TaskQuery());
    _taskView = _buildTaskView(const TaskQuery(), selected: _task.reference);
    _calendarView = CalendarWorkspaceView(
      day: uiRefreshToday,
      mode: CalendarViewMode.week,
      filter: CalendarFilter.all,
      includeInactive: false,
      window: _buildCalendarWindow(uiRefreshToday, CalendarViewMode.week),
    );
  }

  final List<String> unexpectedCalls = [];
  final CalendarOccurrence course = CalendarOccurrence(
    reference: const CalendarReference(
      uiRefreshContext,
      CalendarIdentity(CalendarKind.course, 501),
      1,
    ),
    title: '合成高等数学',
    startsAtUtc: DateTime.utc(2026, 10, 12, 2),
    endsAtUtc: DateTime.utc(2026, 10, 12, 3),
    location: '5304 · 合成教学楼',
    academicDetails: JwAcademicDetails(
      campus: '合成校区',
      building: '合成教学楼',
      room: '5304',
      teachers: const ['合成教师甲'],
      courseCode: 'SYN-101',
      courseType: '合成课程',
      semesterName: '合成 2026 秋',
      lessonId: 501,
      groupId: 601,
      weekIndex: 6,
      weekday: 1,
      periods: 2,
    ),
  );
  final CalendarOccurrence young = CalendarOccurrence(
    reference: const CalendarReference(
      uiRefreshContext,
      CalendarIdentity(CalendarKind.young, 502),
      1,
    ),
    title: '合成志愿活动',
    startsAtUtc: DateTime.utc(2026, 10, 12, 2, 30),
    endsAtUtc: DateTime.utc(2026, 10, 12, 3, 30),
    location: '合成活动室',
  );
  final CalendarOccurrence allDay = CalendarOccurrence(
    reference: const CalendarReference(
      uiRefreshContext,
      CalendarIdentity(CalendarKind.personal, 503),
      1,
    ),
    title: '合成全天安排',
    startsAtUtc: DateTime.utc(2026, 10, 13),
    endsAtUtc: DateTime.utc(2026, 10, 14),
    allDay: true,
    location: '本地合成事项',
  );

  late CalendarWorkspaceView _calendarView;
  late TaskWorkspaceView _taskView;
  late TaskWindow _taskWindow;
  TaskReference? _selectedTask;

  TaskRecord get _task => TaskRecord(
    reference: const TaskReference(uiRefreshContext, 701, 1),
    draft: TaskDraft(
      title: '整理实验报告',
      description: '完成数据核对与结论段落。',
      note: '合成任务备注：先整理原始测量记录。',
      deadlineAtUtc: DateTime.utc(2026, 10, 12, 9),
      estimatedMinutes: 90,
      priority: TaskPriority.high,
    ),
    status: TaskStatus.active,
    createdAtUtc: DateTime.utc(2026, 10, 11, 4),
    updatedAtUtc: DateTime.utc(2026, 10, 12, 4),
    blockCount: 1,
  );

  List<PlanBlockRecord> get _blocks => [
    PlanBlockRecord(
      reference: const CalendarReference(
        uiRefreshContext,
        CalendarIdentity(CalendarKind.planBlock, 801),
        1,
      ),
      task: _task.reference,
      taskTitle: _task.draft.title,
      taskStatus: _task.status,
      draft: PlanBlockDraft(
        startsAtUtc: DateTime.utc(2026, 10, 13, 6),
        endsAtUtc: DateTime.utc(2026, 10, 13, 7),
        location: '合成图书馆',
        note: '整理提纲',
      ),
      status: PlanBlockStatus.planned,
    ),
  ];

  CalendarWindow _buildCalendarWindow(DateTime day, CalendarViewMode mode) {
    final firstDay = mode == CalendarViewMode.week
        ? calendarDay(day.subtract(Duration(days: day.weekday - 1)))
        : calendarDay(day);
    final dayCount = mode == CalendarViewMode.week ? 7 : 1;
    final query = CalendarQuery(
      firstDay: firstDay,
      endDayExclusive: firstDay.add(Duration(days: dayCount)),
    );
    final items = [course, young, allDay];
    return CalendarWindow(
      context: uiRefreshContext,
      revision: 1,
      query: query,
      items: items,
      segments: [
        CalendarDaySegment(
          occurrence: course,
          day: DateTime.utc(2026, 10, 12),
          startMinute: 10 * 60,
          endMinute: 11 * 60,
          continuesBefore: false,
          continuesAfter: false,
        ),
        CalendarDaySegment(
          occurrence: young,
          day: DateTime.utc(2026, 10, 12),
          startMinute: 10 * 60 + 30,
          endMinute: 11 * 60 + 30,
          continuesBefore: false,
          continuesAfter: false,
        ),
        CalendarDaySegment(
          occurrence: allDay,
          day: DateTime.utc(2026, 10, 13),
          startMinute: 0,
          endMinute: 1440,
          continuesBefore: false,
          continuesAfter: false,
        ),
      ],
      conflicts: [CalendarConflict(course, young)],
      matched: items.length,
      truncated: false,
      conflictsTruncated: false,
    );
  }

  TaskWindow _buildTaskWindow(TaskQuery query) {
    final tasks = [_task];
    return TaskWindow(
      context: uiRefreshContext,
      revision: 1,
      query: query,
      items: tasks,
      matched: tasks.length,
      truncated: false,
    );
  }

  TaskWorkspaceView _buildTaskView(TaskQuery query, {TaskReference? selected}) {
    _taskWindow = _buildTaskWindow(query);
    final detail = selected?.localId == _task.reference.localId
        ? TaskDetail(task: _task, blocks: _blocks, nowUtc: uiRefreshNowUtc)
        : null;
    return TaskWorkspaceView(
      window: _taskWindow,
      detail: detail,
      query: query,
      undo: const CalendarUndoView(),
    );
  }

  @override
  CalendarWorkspaceView get view => _calendarView;

  @override
  TaskWorkspaceView get taskView => _taskView;

  @override
  TaskWindow? get calendarTasks => _taskWindow;

  @override
  DateTime get today => uiRefreshToday;

  @override
  DateTime get nowUtc => uiRefreshNowUtc;

  @override
  bool get calendarTasksLoading => false;

  @override
  CalendarFailureCode? get calendarTasksFailure => null;

  @override
  Future<void> load({
    DateTime? day,
    CalendarViewMode? mode,
    CalendarFilter? filter,
    bool? includeInactive,
  }) async {
    final nextDay = day ?? _calendarView.day;
    final nextMode = mode ?? _calendarView.mode;
    _calendarView = CalendarWorkspaceView(
      day: nextDay,
      mode: nextMode,
      filter: filter ?? _calendarView.filter,
      includeInactive: includeInactive ?? _calendarView.includeInactive,
      window: _buildCalendarWindow(nextDay, nextMode),
    );
    notifyListeners();
  }

  @override
  Future<void> select(CalendarReference? reference) async {
    CalendarOccurrence? occurrence;
    if (reference != null) {
      for (final item
          in _calendarView.window?.items ?? const <CalendarOccurrence>[]) {
        if (item.reference == reference) {
          occurrence = item;
          break;
        }
      }
    }
    if (reference != null && occurrence == null) {
      _unexpected('CalendarWorkspacePort.select:stale reference');
    }
    _calendarView = CalendarWorkspaceView(
      day: _calendarView.day,
      mode: _calendarView.mode,
      filter: _calendarView.filter,
      includeInactive: _calendarView.includeInactive,
      window: _calendarView.window,
      detail: occurrence == null
          ? null
          : CalendarDetail(
              occurrence: occurrence,
              personalDraft:
                  occurrence.reference.identity.kind == CalendarKind.personal
                  ? PersonalEventDraft(
                      title: occurrence.title,
                      start: occurrence.startsAtUtc,
                      end: occurrence.endsAtUtc,
                      allDay: occurrence.allDay,
                      location: occurrence.location,
                    )
                  : null,
              relations: const [],
            ),
    );
    notifyListeners();
  }

  @override
  Future<CalendarWriteReceipt> execute(
    CalendarIntent intent, {
    required CalendarContext expectedContext,
  }) async => _unexpected('CalendarWorkspacePort.execute');

  @override
  Future<void> loadTasks({TaskQuery? query}) async {
    final nextQuery = query ?? _taskView.query;
    _taskView = _buildTaskView(nextQuery, selected: _selectedTask);
    notifyListeners();
  }

  @override
  Future<void> selectTask(TaskReference? reference) async {
    _selectedTask = reference;
    _taskView = _buildTaskView(_taskView.query, selected: reference);
    notifyListeners();
  }

  @override
  Future<CalendarWriteReceipt> executeTask(
    CalendarIntent intent, {
    required CalendarContext expectedContext,
  }) async => _unexpected('TaskWorkspacePort.executeTask');

  @override
  Future<void> loadCalendarTasks() async {
    _taskWindow = _buildTaskWindow(_taskView.query);
    notifyListeners();
  }

  Never _unexpected(String method) {
    unexpectedCalls.add(method);
    throw StateError('Unexpected synthetic calendar/task call: $method');
  }
}

final class UiRefreshReminderPort
    implements ReminderDataPort, ReminderEditingPort {
  UiRefreshReminderPort();

  final List<String> unexpectedCalls = [];
  int inspectedTargets = 0;
  int savedTargets = 0;
  ReminderPair? lastSavedPair;

  ReminderSettings get _settings => const ReminderSettings(
    context: uiRefreshContext,
    revision: 1,
    briefEpoch: 1,
    preferences: ReminderPreferences(enabled: true),
  );

  @override
  Stream<int> get changes => const Stream<int>.empty();

  @override
  Future<ReminderSettings> inspectReminders() async =>
      _unexpected('ReminderDataPort.inspectReminders');

  @override
  Future<void> saveReminderPreferences(
    ReminderSettings expected,
    ReminderPreferences preferences,
  ) async => _unexpected('ReminderDataPort.saveReminderPreferences');

  @override
  Future<ReminderPair?> readReminderPair(
    ReminderTarget target, {
    bool series = false,
  }) async => _unexpected('ReminderDataPort.readReminderPair');

  @override
  Future<void> saveReminderPair(
    ReminderTarget target,
    ReminderPair? pair, {
    bool series = false,
  }) async => _unexpected('ReminderDataPort.saveReminderPair');

  @override
  Future<ReminderPublication> prepareReminderPublication() async =>
      _unexpected('ReminderDataPort.prepareReminderPublication');

  @override
  Future<bool> reminderPublicationCurrent(
    ReminderPublication publication,
  ) async => _unexpected('ReminderDataPort.reminderPublicationCurrent');

  @override
  Future<void> recordReminderAccepted(
    ReminderPublication publication,
    String id,
  ) async => _unexpected('ReminderDataPort.recordReminderAccepted');

  @override
  Future<void> recordReminderCancelled(String id) async =>
      _unexpected('ReminderDataPort.recordReminderCancelled');

  @override
  Future<ReminderTarget?> resolveNotification(
    NotificationActivation activation,
  ) async => _unexpected('ReminderDataPort.resolveNotification');

  @override
  Future<ReminderInspection> inspectReminder(
    ReminderTarget target, {
    bool series = false,
  }) async {
    inspectedTargets++;
    return ReminderInspection(
      settings: _settings,
      target: target,
      allDay: target.kind == ReminderKind.personal && target.localId == 503,
      pair: target.kind == ReminderKind.personal && target.localId == 503
          ? ReminderPair.allDay
          : ReminderPair.timed,
      origin: ReminderPairOrigin.target,
      eligible: true,
      reason: '合成日程支持提醒',
      hasTime: true,
      acceptedSlots: const [],
      series: series,
    );
  }

  @override
  Future<void> saveInspectedReminder(
    ReminderInspection expected,
    ReminderPair? pair,
  ) async {
    savedTargets++;
    lastSavedPair = pair;
  }

  Never _unexpected(String method) {
    unexpectedCalls.add(method);
    throw StateError('Unexpected synthetic reminder call: $method');
  }
}

final MorningRuntimeView uiRefreshMorningView = MorningRuntimeView(
  enabled: true,
  phase: MorningBriefPhase.ready,
  facts: MorningFacts(
    context: uiRefreshContext,
    day: uiRefreshToday,
    digest: 'ui-refresh-synthetic-facts',
    agenda: [
      MorningAgendaItem(
        title: '合成高等数学',
        location: '合成教室 5304',
        start: DateTime.utc(2026, 10, 12, 2),
        end: DateTime.utc(2026, 10, 12, 3),
        allDay: false,
        kind: 'course',
        state: 'planned',
      ),
      MorningAgendaItem(
        title: '合成全天安排',
        location: '本地合成事项',
        start: DateTime.utc(2026, 10, 13),
        end: DateTime.utc(2026, 10, 14),
        allDay: true,
        kind: 'personal',
        state: 'planned',
      ),
    ],
    tasks: [MorningTaskItem('整理实验报告', DateTime.utc(2026, 10, 12, 9))],
    conflicts: 1,
    overdueTasks: 0,
    complete: true,
    hasSchoolImports: true,
  ),
  brief: MorningBrief(
    day: uiRefreshToday,
    phase: MorningBriefPhase.ready,
    factDigest: 'ui-refresh-synthetic-facts',
    autoAttempts: 1,
    notices: MorningNoticeBatch(
      day: DateTime.utc(2026, 10, 11),
      notices: [
        MorningNotice(
          provider: PublicProvider.teach,
          title: '合成教务通知',
          articleUrl: Uri.parse('https://example.invalid/ui-refresh-teach'),
          publishedDay: DateTime.utc(2026, 10, 11),
          observedAtUtc: uiRefreshNowUtc,
          excerpt: '仅用于界面验收的合成通知摘要。',
        ),
      ],
      coverage: const [
        MorningNoticeCoverage(
          provider: PublicProvider.teach,
          pages: 1,
          matched: 1,
          unknownDates: 0,
          complete: true,
        ),
        MorningNoticeCoverage(
          provider: PublicProvider.finance,
          pages: 1,
          matched: 0,
          unknownDates: 0,
          complete: true,
        ),
      ],
      operations: 2,
    ),
    summary:
        '{"kind":"morning-summary-v2","today":"今早先去合成教学楼上课，再安排报告整理。","notices":"合成教务通知已列在下方。"}',
  ),
  text:
      '{"kind":"morning-summary-v2","today":"今早先去合成教学楼上课，再安排报告整理。","notices":"合成教务通知已列在下方。"}',
);
