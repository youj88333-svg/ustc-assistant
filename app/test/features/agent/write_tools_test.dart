import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_permission_policy_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_write_tool.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_write_tools.dart';
import 'package:ustc_assistant_app/features/agent/application/cancellation_signal.dart';
import 'package:ustc_assistant_app/features/agent/data/drift_agent_write_unit_of_work.dart';
import 'package:ustc_assistant_app/features/agent/application/run_reference_store.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_permission_policy.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_tool.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_write_gateway.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_write_proposal.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_write_unit_of_work.dart';
import 'package:ustc_assistant_app/features/calendar/application/recurrence_service.dart';
import 'package:ustc_assistant_app/features/calendar/domain/personal_event.dart';
import 'package:ustc_assistant_app/features/tasks/domain/plan_block.dart';
import 'package:ustc_assistant_app/features/tasks/domain/task.dart';
import 'package:ustc_assistant_app/features/schedule/application/effective_event_repository.dart';
import 'package:ustc_assistant_app/features/schedule/application/overlay_service.dart';

class _FixedClock implements BeijingClock {
  @override
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);
}

/// 记录被调用方法的假网关；未覆盖方法抛错。
class _RecordingGateway implements AgentWriteGateway {
  final List<PersonalEvent> createdEvents = [];
  final List<Map<String, Object?>> createdTasks = [];
  final List<Map<String, Object?>> plannedBlocks = [];
  /// 模拟目标在提案后被删除：taskById 在 propose 通过后抛错，触发 commit 的
  /// TOCTOU 守卫。
  bool taskMissing = false;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();

  @override
  Future<TaskItem> taskById(String taskId) async {
    if (taskMissing) throw StateError('task not found');
    return TaskItem(
      id: taskId,
      title: '准备考试',
      state: TaskState.active,
      importance: TaskImportance.normal,
      createdAt: 1,
      updatedAt: 1,
    );
  }

  @override
  Future<String> createEvent(PersonalEvent event, {List<int>? reminderOffsetsMinutes}) async {
    createdEvents.add(event);
    return 'ev-created';
  }

  @override
  Future<String> createTask({
    required String title,
    String? description,
    String? userNotes,
    DateTime? deadlineAt,
    int? estimatedMinutes,
    List<String> tags = const [],
    TaskImportance importance = TaskImportance.normal,
  }) async {
    createdTasks.add({
      'title': title,
      'description': description,
      'deadlineAt': deadlineAt,
      'estimatedMinutes': estimatedMinutes,
      'importance': importance,
    });
    return 'task-created';
  }

  @override
  Future<String> planTask({
    required String taskId,
    required DateTime startAt,
    required DateTime endAt,
    String? title,
    PlanBlockStatus status = PlanBlockStatus.accepted,
  }) async {
    plannedBlocks.add({
      'taskId': taskId,
      'startAt': startAt,
      'endAt': endAt,
      'title': title,
      'status': status,
    });
    return 'block-created';
  }
}

/// update_event 专用假网关：记录被调方法。
class _UpdateGateway implements AgentWriteGateway {
  final Map<String, EventWriteSnapshot> snapshots = {};
  final Map<String, PersonalEvent> events = {};
  String? softDeletedId;
  String? cancelledId;
  String? completedId;
  String? skippedId;
  String? editedId;
  PersonalEvent? editedReplacement;
  ({String seriesId, String key, OccurrenceOverride override})? occurrenceEdit;
  ({String seriesId, PersonalEvent anchor})? wholeSeriesEdit;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();

  @override
  Future<EventWriteSnapshot> eventSnapshot(String eventId) async =>
      snapshots[eventId]!;

  @override
  Future<PersonalEvent> personalEvent(String eventId) async =>
      events[eventId]!;

  @override
  Future<PersonalEvent> seriesAnchor(String seriesId) async =>
      events['anchor:$seriesId']!;

  @override
  Future<void> softDeleteEvent(String eventId) async => softDeletedId = eventId;

  @override
  Future<void> cancelEvent(String eventId) async => cancelledId = eventId;

  @override
  Future<void> completeEvent(String eventId) async => completedId = eventId;

  @override
  Future<void> skipEvent(String eventId) async => skippedId = eventId;

  @override
  Future<void> editPersonalEvent(String eventId, PersonalEvent replacement, {List<int>? reminderOffsetsMinutes}) async {
    editedId = eventId;
    editedReplacement = replacement;
  }

  @override
  Future<void> editOccurrenceOnly(String seriesId, String occurrenceKey, OccurrenceOverride override) async {
    occurrenceEdit = (seriesId: seriesId, key: occurrenceKey, override: override);
  }

  @override
  Future<SeriesEditImpact> editWholeSeries(String seriesId, {required PersonalEvent anchor}) async {
    wholeSeriesEdit = (seriesId: seriesId, anchor: anchor);
    return const SeriesEditImpact(affectedOccurrences: 8, newlyOrphaned: 0, continuesBeyondHorizon: true);
  }
}

/// 标注类工具假网关。
class _OverlayGateway implements AgentWriteGateway {
  OverlayMutation? eventOverlay;
  OverlayMutation? seriesOverlay;
  AttendanceDecision? decision;
  ({ListeningMode mode, String? note})? listening;
  String? seriesFor;
  String? courseSeriesResult;
  bool personal = true;
  String? courseSeriesId;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();

  @override
  Future<EventWriteSnapshot> eventSnapshot(String eventId) async =>
      EventWriteSnapshot(
        id: eventId,
        source: personal ? 'user' : 'ustc_jw',
        type: personal ? 'personal' : 'course',
        title: '课程A',
        allDay: false,
        startAt: DateTime(2026, 8, 1, 9),
        endAt: DateTime(2026, 8, 1, 10),
        courseSeriesId: courseSeriesId,
      );

  @override
  Future<void> setEventOverlay(String eventId, OverlayMutation mutation) async => eventOverlay = mutation;

  @override
  Future<void> setSeriesOverlay(String seriesId, OverlayMutation mutation) async => seriesOverlay = mutation;

  @override
  Future<void> recordAttendanceDecision(String eventId, AttendanceDecision decision) async => this.decision = decision;

  @override
  Future<void> recordListeningMode(String eventId, ListeningMode mode, {String? note}) async => listening = (mode: mode, note: note);

  @override
  Future<String?> courseSeriesIdForEvent(String eventId) async => courseSeriesResult;
}

/// 关系/提醒/权限工具假网关。
class _RelationGateway implements AgentWriteGateway {
  ({String leftKind, String leftId, String rightKind, String rightId, String conflictState, String? reason})? relation;
  ({String eventId, List<int> offsets})? reminder;
  Map<String, Object?>? policyUpdate;
  EventWriteSnapshot? identity;
  /// 模拟参与方在提案后被删除：eventSnapshot 抛错，触发 commit 的 TOCTOU 守卫。
  bool participantMissing = false;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();

  @override
  Future<EventWriteSnapshot> eventSnapshot(String eventId) async {
    if (participantMissing) throw StateError('event not found');
    return identity ??
        EventWriteSnapshot(id: eventId, source: 'user', type: 'personal',
            title: '健身', allDay: false,
            startAt: DateTime(2026, 8, 1, 9), endAt: DateTime(2026, 8, 1, 10));
  }

  @override
  Future<PlanBlockItem> planBlockById(String planBlockId) async => PlanBlockItem(
        id: planBlockId,
        taskId: 'task-1',
        startAt: DateTime(2026, 8, 1, 9),
        endAt: DateTime(2026, 8, 1, 10),
        status: PlanBlockStatus.accepted,
        locked: false,
        createdAt: 1,
        updatedAt: 1,
      );

  @override
  Future<void> createConflictRelation({
    required String leftKind,
    required String leftId,
    required String rightKind,
    required String rightId,
    required String conflictState,
    String? reason,
  }) async {
    relation = (leftKind: leftKind, leftId: leftId, rightKind: rightKind, rightId: rightId, conflictState: conflictState, reason: reason);
  }

  @override
  Future<void> setReminder(String eventId, List<int> offsetsMinutes) async =>
      reminder = (eventId: eventId, offsets: offsetsMinutes);

  @override
  Future<void> updatePermissionPolicy({
    required String actionType,
    required String targetType,
    required ConfirmationMode mode,
    required RiskLevel riskLevel,
    required bool enabled,
    required String updatedBy,
  }) async {
    policyUpdate = {'actionType': actionType, 'targetType': targetType, 'mode': mode, 'riskLevel': riskLevel, 'updatedBy': updatedBy};
  }
}

AgentToolContext _ctx(String runId, {String accountId = 'a1'}) =>
    AgentToolContext(
      accountId: accountId,
      runId: runId,
      clock: _FixedClock(),
      cancellation: CancellationSignal(),
      references: RunReferenceStore(runId: runId),
    );

/// 记录 ref 绑定，方便测试 plan_task 的 ref 解析。
class _Harness {
  _Harness(this.tools) : refs = RunReferenceStore(runId: 'r1');
  final List<AgentWriteTool> tools;
  final RunReferenceStore refs;

  /// 与 [refs] 共享同一个 ref 存储，使 plan_task 的绑定能解析。
  AgentToolContext ctx({String accountId = 'a1'}) => AgentToolContext(
        accountId: accountId,
        runId: refs.runId,
        clock: _FixedClock(),
        cancellation: CancellationSignal(),
        references: refs,
      );

  AgentWriteTool tool(String name) => tools.firstWhere((t) => t.name == name);
}

void main() {
  late AppDatabase db;
  late AgentPermissionPolicyService policy;
  late WriteConfirmationStore store;
  late _RecordingGateway gateway;
  late AgentWriteUnitOfWork unitOfWork;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    // agent_permission_policies.account_id 外键指向 local_accounts，需先播种账户。
    await db.into(db.localAccounts).insert(
      LocalAccountsCompanion.insert(
        id: 'a1',
        maskedHint: 'PB****0000',
        isActive: const Value(true),
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    policy = AgentPermissionPolicyService(database: db, clock: _FixedClock());
    unitOfWork = DriftAgentWriteUnitOfWork(db);
    store = WriteConfirmationStore(policy: policy, unitOfWork: unitOfWork);
    gateway = _RecordingGateway();
  });

  tearDown(() => db.close());

  List<AgentWriteTool> tools() => [
    CreateEventTool(gateway: gateway, policy: policy, confirmationStore: store, unitOfWork: unitOfWork),
    CreateTaskTool(gateway: gateway, policy: policy, confirmationStore: store, unitOfWork: unitOfWork),
    PlanTaskTool(gateway: gateway, policy: policy, confirmationStore: store, unitOfWork: unitOfWork),
    UpdateEventTool(gateway: gateway, policy: policy, confirmationStore: store, unitOfWork: unitOfWork),
    CreateUserOverlayTool(gateway: gateway, policy: policy, confirmationStore: store, unitOfWork: unitOfWork),
    RecordAttendanceDecisionTool(gateway: gateway, policy: policy, confirmationStore: store, unitOfWork: unitOfWork),
    RecordListeningModeTool(gateway: gateway, policy: policy, confirmationStore: store, unitOfWork: unitOfWork),
    CreateScheduleRelationTool(gateway: gateway, policy: policy, confirmationStore: store, unitOfWork: unitOfWork),
    SetReminderTool(gateway: gateway, policy: policy, confirmationStore: store, unitOfWork: unitOfWork),
    UpdatePermissionPolicyTool(gateway: gateway, policy: policy, confirmationStore: store, unitOfWork: unitOfWork),
  ];

  test('schemas declare required args', () {
    final t = tools();
    final createEventSchema = t.firstWhere((x) => x.name == 'create_event').inputSchema;
    expect((createEventSchema['required'] as List).contains('title'), isTrue);
    expect((t.firstWhere((x) => x.name == 'create_task').inputSchema['required'] as List).contains('title'), isTrue);
    expect((t.firstWhere((x) => x.name == 'plan_task').inputSchema['required'] as List).contains('ref_task'), isTrue);
  });

  test('create_event propose builds a timed proposal and commits on approval', () async {
    final h = _Harness(tools());
    final result = await h.tool('create_event').execute({
      'title': '健身',
      'start_at': '2026-08-01T15:00:00+08:00',
      'end_at': '2026-08-01T16:00:00+08:00',
      'location': '健身房',
    }, _ctx('r1'));
    expect(result.status, AgentToolStatus.needsUserAction);
    expect(result.userAction?.writeProposal?.operationLabel, '新建日程');
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gateway.createdEvents.single.title, '健身');
    expect(gateway.createdEvents.single.startAt, DateTime.parse('2026-08-01T15:00:00+08:00'));
  });

  test('create_event rejects invalid all-day range in propose', () async {
    final h = _Harness(tools());
    final result = await h.tool('create_event').execute({
      'title': '全天',
      'all_day': true,
      'start_date': '2026-08-02',
      'end_date_exclusive': '2026-08-02', // 不晚于开始 → 非法
    }, _ctx('r1'));
    expect(result.status, AgentToolStatus.error);
    expect(result.errorCode, 'invalid_write_arguments');
  });

  test('create_task propose and commit', () async {
    final h = _Harness(tools());
    final result = await h.tool('create_task').execute({
      'title': '写作业',
      'deadline_at': '2026-08-05T23:59:00+08:00',
      'estimated_minutes': 120,
    }, _ctx('r1'));
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gateway.createdTasks.single['title'], '写作业');
    expect(gateway.createdTasks.single['estimatedMinutes'], 120);
  });

  test('plan_task resolves the task ref and commits', () async {
    final h = _Harness(tools());
    // 先绑定一个 task ref（模拟模型之前通过 get_tasks 读到）
    final taskRef = h.refs.bind(kind: 'task', localId: 'task-1');
    final result = await h.tool('plan_task').execute({
      'ref_task': taskRef,
      'start_at': '2026-08-03T20:00:00+08:00',
      'end_at': '2026-08-03T21:00:00+08:00',
      'status': 'accepted',
    }, h.ctx());
    expect(result.status, AgentToolStatus.needsUserAction);
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gateway.plannedBlocks.single['taskId'], 'task-1');
    expect(gateway.plannedBlocks.single['status'], PlanBlockStatus.accepted);
  });

  test('plan_task with an unknown ref is rejected before approval', () async {
    final h = _Harness(tools());
    final result = await h.tool('plan_task').execute({
      'ref_task': 'ref_unknown',
      'start_at': '2026-08-03T20:00:00+08:00',
      'end_at': '2026-08-03T21:00:00+08:00',
    }, _ctx('r1'));
    expect(result.status, AgentToolStatus.error);
    expect(result.errorCode, 'invalid_write_arguments');
  });

  test('update_event rejects an unknown ref', () async {
    final h = _Harness(tools());
    final result = await h.tool('update_event').execute({'ref_event': 'ref_nope'}, h.ctx());
    expect(result.status, AgentToolStatus.error);
    expect(result.errorCode, 'invalid_write_arguments');
  });

  test('update_event delete soft-deletes after approval', () async {
    final h = _Harness(tools());
    final update = h.tool('update_event') as UpdateEventTool;
    final gw = _UpdateGateway();
    update.attachGateway(gw);
    // 直接测 propose + commit 路径：用真实 store 走确认
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    gw.snapshots['ev-1'] = EventWriteSnapshot(id: 'ev-1', source: 'user', type: 'personal', title: '健身', allDay: false,
          startAt: DateTime(2026, 8, 1, 15), endAt: DateTime(2026, 8, 1, 16));
    final result = await update.execute({'ref_event': ref, 'delete': true}, h.ctx());
    expect(result.status, AgentToolStatus.needsUserAction);
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gw.softDeletedId, 'ev-1');
  });

  test('update_event single edit merges into the current event', () async {
    final h = _Harness(tools());
    final update = h.tool('update_event') as UpdateEventTool;
    final gw = _UpdateGateway();
    update.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    gw.snapshots['ev-1'] = EventWriteSnapshot(id: 'ev-1', source: 'user', type: 'personal', title: '健身', allDay: false,
          startAt: DateTime(2026, 8, 1, 15), endAt: DateTime(2026, 8, 1, 16));
    gw.events['ev-1'] = PersonalEvent.timed(
      title: '健身', startAt: DateTime(2026, 8, 1, 15), endAt: DateTime(2026, 8, 1, 16));
    final result = await update.execute({'ref_event': ref, 'title': '健身改五点'}, h.ctx());
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gw.editedId, 'ev-1');
    expect(gw.editedReplacement!.title, '健身改五点');
    expect(gw.editedReplacement!.startAt, DateTime(2026, 8, 1, 15)); // 未变字段保留
  });

  test('update_event only_this on a recurring series writes an override', () async {
    final h = _Harness(tools());
    final update = h.tool('update_event') as UpdateEventTool;
    final gw = _UpdateGateway();
    update.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    gw.snapshots['ev-1'] = EventWriteSnapshot(
      id: 'ev-1', source: 'user', type: 'personal', title: '例会', allDay: false,
      startAt: DateTime(2026, 8, 5, 15), endAt: DateTime(2026, 8, 5, 16),
      personalSeriesId: 'ser-1', occurrenceKey: 'ser-1@2026-08-05T15:00:00');
    final result = await update.execute({'ref_event': ref, 'scope': 'only_this', 'title': '本周例会改主题'}, h.ctx());
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gw.occurrenceEdit!.seriesId, 'ser-1');
    expect(gw.occurrenceEdit!.override.title.value, '本周例会改主题');
  });

  test('update_event whole_series preserves the rule and changes anchor fields', () async {
    final h = _Harness(tools());
    final update = h.tool('update_event') as UpdateEventTool;
    final gw = _UpdateGateway();
    update.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    gw.snapshots['ev-1'] = EventWriteSnapshot(
      id: 'ev-1', source: 'user', type: 'personal', title: '例会', allDay: false,
      startAt: DateTime(2026, 8, 5, 15), endAt: DateTime(2026, 8, 5, 16),
      personalSeriesId: 'ser-1', occurrenceKey: 'ser-1@2026-08-05T15:00:00');
    gw.events['anchor:ser-1'] = PersonalEvent.timed(
      title: '例会', startAt: DateTime(2026, 8, 5, 15), endAt: DateTime(2026, 8, 5, 16));
    final result = await update.execute({'ref_event': ref, 'scope': 'whole_series', 'title': '例会（改）'}, h.ctx());
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gw.wholeSeriesEdit!.seriesId, 'ser-1');
    expect(gw.wholeSeriesEdit!.anchor.title, '例会（改）');
  });

  test('update_event rejects whole_series time changes', () async {
    final h = _Harness(tools());
    final update = h.tool('update_event') as UpdateEventTool;
    final gw = _UpdateGateway();
    update.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    gw.snapshots['ev-1'] = EventWriteSnapshot(
      id: 'ev-1', source: 'user', type: 'personal', title: '例会', allDay: false,
      startAt: DateTime(2026, 8, 5, 15), endAt: DateTime(2026, 8, 5, 16),
      personalSeriesId: 'ser-1', occurrenceKey: 'k');
    // 整系列时间变更在 commit 阶段拒绝；update_event 恒走确认，先批准再断言。
    final result = await update.execute({
      'ref_event': ref, 'scope': 'whole_series',
      'start_at': '2026-08-05T17:00:00+08:00',
      'end_at': '2026-08-05T18:00:00+08:00',
    }, h.ctx());
    expect(result.status, AgentToolStatus.needsUserAction);
    final committed = await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(committed.status, AgentToolStatus.error);
    expect(committed.errorCode, 'whole_series_time_change_not_supported');
  });

  test('update_event refuses to edit a course event', () async {
    final h = _Harness(tools());
    final update = h.tool('update_event') as UpdateEventTool;
    final gw = _UpdateGateway();
    update.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    gw.snapshots['ev-1'] = const EventWriteSnapshot(id: 'ev-1', source: 'ustc_jw', type: 'course', title: '健身', allDay: false);
    // 来源校验在 propose 阶段即被拒（preflight），不产生可批准提案。
    final result = await update.execute({'ref_event': ref, 'title': 'x'}, h.ctx());
    expect(result.status, AgentToolStatus.error);
    expect(result.errorCode, 'invalid_write_arguments');
  });

  test('update_event all_day:true on a timed event without dates makes an all-day event', () async {
    final h = _Harness(tools());
    final update = h.tool('update_event') as UpdateEventTool;
    final gw = _UpdateGateway();
    update.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    gw.snapshots['ev-1'] = EventWriteSnapshot(id: 'ev-1', source: 'user', type: 'personal', title: '健身', allDay: false,
          startAt: DateTime(2026, 8, 1, 15), endAt: DateTime(2026, 8, 1, 16));
    gw.events['ev-1'] = PersonalEvent.timed(
      title: '健身', startAt: DateTime(2026, 8, 1, 15), endAt: DateTime(2026, 8, 1, 16));
    final result = await update.execute({'ref_event': ref, 'all_day': true}, h.ctx());
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gw.editedReplacement!.allDay, isTrue);
    expect(gw.editedReplacement!.startDate, DateTime(2026, 8, 1)); // 从 startAt 取日期
    expect(gw.editedReplacement!.endDateExclusive, DateTime(2026, 8, 2)); // 缺省 +1 天
  });

  test('update_event all_day:false on an all-day event converts to timed', () async {
    final h = _Harness(tools());
    final update = h.tool('update_event') as UpdateEventTool;
    final gw = _UpdateGateway();
    update.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    gw.snapshots['ev-1'] = EventWriteSnapshot(id: 'ev-1', source: 'user', type: 'personal', title: '健身', allDay: false,
          startAt: DateTime(2026, 8, 1, 15), endAt: DateTime(2026, 8, 1, 16));
    gw.events['ev-1'] = PersonalEvent.allDay(
      title: '全天', startDate: DateTime(2026, 8, 1), endDateExclusive: DateTime(2026, 8, 2));
    final result = await update.execute({
      'ref_event': ref, 'all_day': false,
      'start_at': '2026-08-01T09:00:00+08:00',
      'end_at': '2026-08-01T10:00:00+08:00',
    }, h.ctx());
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gw.editedReplacement!.allDay, isFalse);
    expect(gw.editedReplacement!.startAt, DateTime.parse('2026-08-01T09:00:00+08:00'));
    expect(gw.editedReplacement!.endAt, DateTime.parse('2026-08-01T10:00:00+08:00'));
  });

  test('update_event rejects whole_series all-day date changes', () async {
    final h = _Harness(tools());
    final update = h.tool('update_event') as UpdateEventTool;
    final gw = _UpdateGateway();
    update.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    gw.snapshots['ev-1'] = EventWriteSnapshot(
      id: 'ev-1', source: 'user', type: 'personal', title: '例会', allDay: false,
      startAt: DateTime(2026, 8, 5, 15), endAt: DateTime(2026, 8, 5, 16),
      personalSeriesId: 'ser-1', occurrenceKey: 'k');
    final result = await update.execute({
      'ref_event': ref, 'scope': 'whole_series', 'start_date': '2026-08-06',
    }, h.ctx());
    expect(result.status, AgentToolStatus.needsUserAction);
    final committed = await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(committed.status, AgentToolStatus.error);
    expect(committed.errorCode, 'whole_series_time_change_not_supported');
  });

  test('create_user_overlay single_event sets an event overlay', () async {
    final h = _Harness(tools());
    final gw = _OverlayGateway();
    final tool = h.tool('create_user_overlay');
    tool.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    final result = await tool.execute({
      'ref_event': ref,
      'attendance_policy': 'must_go',
      'attendance_note': '小测',
    }, h.ctx());
    expect(result.status, AgentToolStatus.needsUserAction);
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gw.eventOverlay?.attendancePolicy, AttendancePolicy.mustGo);
    expect(gw.eventOverlay?.attendanceNote, '小测');
  });

  test('create_user_overlay course_series resolves the event series', () async {
    final h = _Harness(tools());
    final gw = _OverlayGateway();
    gw.courseSeriesResult = 'cs-1';
    gw.courseSeriesId = 'cs-1';
    gw.personal = false;
    final tool = h.tool('create_user_overlay');
    tool.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    final result = await tool.execute({
      'ref_event': ref,
      'scope': 'course_series',
      'attendance_policy': 'skip',
    }, h.ctx());
    expect(result.status, AgentToolStatus.needsUserAction);
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gw.seriesOverlay?.attendancePolicy, AttendancePolicy.skip);
  });

  test('create_user_overlay course_series without a series errors before confirmation', () async {
    final h = _Harness(tools());
    final gw = _OverlayGateway();
    final tool = h.tool('create_user_overlay');
    tool.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    final result = await tool.execute({
      'ref_event': ref, 'scope': 'course_series', 'attendance_policy': 'must_go',
    }, h.ctx());
    // preflight：无课程系列在 propose 阶段即被拒。
    expect(result.status, AgentToolStatus.error);
    expect(result.errorCode, 'invalid_write_arguments');
    expect(gw.seriesOverlay, isNull);
  });

  test('record_attendance_decision maps go/skip/undecided', () async {
    final h = _Harness(tools());
    final gw = _OverlayGateway();
    final tool = h.tool('record_attendance_decision');
    tool.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    final result = await tool.execute({'ref_event': ref, 'decision': 'go'}, h.ctx());
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gw.decision, AttendanceDecision.go);
  });

  test('record_listening_mode maps not_listen with a note', () async {
    final h = _Harness(tools());
    final gw = _OverlayGateway();
    final tool = h.tool('record_listening_mode');
    tool.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    final result = await tool.execute({
      'ref_event': ref, 'mode': 'not_listen', 'note': '适合写作业',
    }, h.ctx());
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gw.listening!.mode, ListeningMode.notListen);
    expect(gw.listening!.note, '适合写作业');
  });

  test('create_schedule_relation resolves event refs and commits', () async {
    final h = _Harness(tools());
    final gw = _RelationGateway();
    final tool = h.tool('create_schedule_relation');
    tool.attachGateway(gw);
    final left = h.refs.bind(kind: 'event', localId: 'ev-1');
    final right = h.refs.bind(kind: 'event', localId: 'ev-2');
    final result = await tool.execute({
      'ref_left': left,
      'ref_right': right,
      'conflict_state': 'no_conflict',
      'reason': '两门课重叠，用户已决定去 A',
    }, h.ctx());
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gw.relation!.leftKind, 'event');
    expect(gw.relation!.leftId, 'ev-1');
    expect(gw.relation!.conflictState, 'no_conflict');
  });

  test('set_reminder sets offsets for an event', () async {
    final h = _Harness(tools());
    final gw = _RelationGateway();
    final tool = h.tool('set_reminder');
    tool.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    final result = await tool.execute({'ref_event': ref, 'offsets_minutes': [15, 120]}, h.ctx());
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gw.reminder!.eventId, 'ev-1');
    expect(gw.reminder!.offsets, [15, 120]);
  });

  test('update_permission_policy always confirms even when already relaxed', () async {
    final h = _Harness(tools());
    final gw = _RelationGateway();
    final tool = h.tool('update_permission_policy');
    tool.attachGateway(gw);
    // 先把 update_permission_policy 自身（targetType=permission）的策略设成 always_allow，
    // 基类仍必须强制确认。审批门用工具 getter 的 (actionType,targetType) 查行，
    // 该键若命中 always_allow 而 forceConfirmation 失效，测试就会失败——真正保护此安全属性。
    await policy.updatePolicy(accountId: 'a1', actionType: 'update_permission_policy',
        targetType: 'permission', mode: ConfirmationMode.alwaysAllow,
        riskLevel: RiskLevel.critical, enabled: true, updatedBy: 'user');
    final result = await tool.execute({
      'action_type': 'create_event',
      'target_type': 'event',
      'confirmation_mode': 'always_allow',
    }, h.ctx());
    expect(result.status, AgentToolStatus.needsUserAction);
    expect(result.userAction?.writeProposal?.rememberAllowed, isFalse);
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gw.policyUpdate!['actionType'], 'create_event');
    expect(gw.policyUpdate!['mode'], ConfirmationMode.alwaysAllow);
    expect(gw.policyUpdate!['riskLevel'], AgentPermissionPolicyService.defaultRisk('create_event'));
  });

  test('create_schedule_relation falls back to plan_block refs', () async {
    final h = _Harness(tools());
    final gw = _RelationGateway();
    final tool = h.tool('create_schedule_relation');
    tool.attachGateway(gw);
    final left = h.refs.bind(kind: 'event', localId: 'ev-1');
    final right = h.refs.bind(kind: 'planblock', localId: 'pb-1');
    final result = await tool.execute({
      'ref_left': left,
      'ref_right': right,
      'conflict_state': 'conflict',
    }, h.ctx());
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gw.relation!.leftKind, 'event');
    expect(gw.relation!.leftId, 'ev-1');
    expect(gw.relation!.rightKind, 'plan_block');
    expect(gw.relation!.rightId, 'pb-1');
  });

  test('create_schedule_relation rejects an unknown ref before approval', () async {
    final h = _Harness(tools());
    final gw = _RelationGateway();
    final tool = h.tool('create_schedule_relation');
    tool.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    final result = await tool.execute({
      'ref_left': ref,
      'ref_right': 'ref_nope',
      'conflict_state': 'no_conflict',
    }, h.ctx());
    expect(result.status, AgentToolStatus.error);
    expect(result.errorCode, 'invalid_write_arguments');
  });

  test('set_reminder rejects an unknown event ref', () async {
    final h = _Harness(tools());
    final gw = _RelationGateway();
    final tool = h.tool('set_reminder');
    tool.attachGateway(gw);
    final result = await tool.execute({'ref_event': 'ref_nope', 'offsets_minutes': [15]}, h.ctx());
    expect(result.status, AgentToolStatus.error);
    expect(result.errorCode, 'invalid_write_arguments');
  });

  test('set_reminder rejects negative offsets', () async {
    final h = _Harness(tools());
    final gw = _RelationGateway();
    final tool = h.tool('set_reminder');
    tool.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    final result = await tool.execute({'ref_event': ref, 'offsets_minutes': [-5]}, h.ctx());
    expect(result.status, AgentToolStatus.error);
    expect(result.errorCode, 'invalid_write_arguments');
  });

  test('set_reminder rejects a non-personal event before confirmation', () async {
    // 提醒仅支持个人日程：课程/考试/二课事件在 propose 阶段即被拒（preflight）。
    final h = _Harness(tools());
    final gw = _RelationGateway();
    gw.identity = const EventWriteSnapshot(id: 'ev-1', source: 'ustc_jw', type: 'course', title: '健身', allDay: false);
    final tool = h.tool('set_reminder');
    tool.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    final result = await tool.execute({'ref_event': ref, 'offsets_minutes': [15]}, h.ctx());
    expect(result.status, AgentToolStatus.error);
    expect(result.errorCode, 'invalid_write_arguments');
    expect(gw.reminder, isNull);
  });

  // ========== Task 1: strict runtime argument validation ==========

  test('schemas all declare additionalProperties:false', () {
    final t = tools();
    for (final tool in t) {
      final schema = tool.inputSchema;
      expect(schema['additionalProperties'], isFalse,
          reason: '${tool.name} schema must be closed');
    }
  });

  test('create_event declares importance in schema', () {
    final t = tools();
    final schema = t.firstWhere((x) => x.name == 'create_event').inputSchema;
    final props = schema['properties'] as Map<String, Object?>;
    expect(props.containsKey('importance'), isTrue);
  });

  test('update_event declares and implements type and importance', () {
    final t = tools();
    final schema = t.firstWhere((x) => x.name == 'update_event').inputSchema;
    final props = schema['properties'] as Map<String, Object?>;
    expect(props.containsKey('type'), isTrue);
    expect(props.containsKey('importance'), isTrue);
  });

  test('create_event rejects invalid field combinations', () async {
    final h = _Harness(tools());
    // 定时无时间对
    var result = await h.tool('create_event').execute({'title': 'x'}, _ctx('r1'));
    expect(result.errorCode, 'invalid_write_arguments');
    // 全天无日期对
    result = await h.tool('create_event').execute({'title': 'x', 'all_day': true}, _ctx('r1'));
    expect(result.errorCode, 'invalid_write_arguments');
    // 全天字段与定时字段混用
    result = await h.tool('create_event').execute({
      'title': 'x', 'all_day': true, 'start_at': '2026-08-01T15:00:00+08:00',
      'start_date': '2026-08-01', 'end_date_exclusive': '2026-08-02',
    }, _ctx('r1'));
    expect(result.errorCode, 'invalid_write_arguments');
    // 未知 type
    result = await h.tool('create_event').execute({
      'title': 'x', 'start_at': '2026-08-01T15:00:00+08:00', 'end_at': '2026-08-01T16:00:00+08:00',
      'type': 'lecture',
    }, _ctx('r1'));
    expect(result.errorCode, 'invalid_write_arguments');
    // 额外键
    result = await h.tool('create_event').execute({
      'title': 'x', 'start_at': '2026-08-01T15:00:00+08:00', 'end_at': '2026-08-01T16:00:00+08:00',
      'sneaky': true,
    }, _ctx('r1'));
    expect(result.errorCode, 'invalid_write_arguments');
  });

  test('create_task rejects invalid estimated minutes and importance', () async {
    final h = _Harness(tools());
    // 未知 importance
    var result = await h.tool('create_task').execute(
        {'title': 'x', 'importance': 'urgent'}, _ctx('r1'));
    expect(result.errorCode, 'invalid_write_arguments');
    // 零分钟
    result = await h.tool('create_task').execute({'title': 'x', 'estimated_minutes': 0}, _ctx('r1'));
    expect(result.errorCode, 'invalid_write_arguments');
    // 负分钟
    result = await h.tool('create_task').execute({'title': 'x', 'estimated_minutes': -5}, _ctx('r1'));
    expect(result.errorCode, 'invalid_write_arguments');
    // 非字符串 tag
    result = await h.tool('create_task').execute(
        {'title': 'x', 'tags': ['ok', 3]}, _ctx('r1'));
    expect(result.errorCode, 'invalid_write_arguments');
  });

  test('plan_task rejects unknown status, bad range and blank title', () async {
    final h = _Harness(tools());
    final taskRef = h.refs.bind(kind: 'task', localId: 'task-1');
    // 未知 status
    var result = await h.tool('plan_task').execute({
      'ref_task': taskRef, 'start_at': '2026-08-03T20:00:00+08:00',
      'end_at': '2026-08-03T21:00:00+08:00', 'status': 'done_maybe',
    }, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // end 不晚于 start
    result = await h.tool('plan_task').execute({
      'ref_task': taskRef, 'start_at': '2026-08-03T21:00:00+08:00',
      'end_at': '2026-08-03T20:00:00+08:00',
    }, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // 空白可选 title
    result = await h.tool('plan_task').execute({
      'ref_task': taskRef, 'start_at': '2026-08-03T20:00:00+08:00',
      'end_at': '2026-08-03T21:00:00+08:00', 'title': '   ',
    }, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
  });

  test('update_event rejects no-op, bad enums, mixed modes and one-ended time', () async {
    final h = _Harness(tools());
    final update = h.tool('update_event') as UpdateEventTool;
    final gw = _UpdateGateway();
    update.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    gw.snapshots['ev-1'] = EventWriteSnapshot(id: 'ev-1', source: 'user', type: 'personal', title: '健身', allDay: false,
          startAt: DateTime(2026, 8, 1, 15), endAt: DateTime(2026, 8, 1, 16));
    gw.events['ev-1'] = PersonalEvent.timed(
        title: '健身', startAt: DateTime(2026, 8, 1, 15), endAt: DateTime(2026, 8, 1, 16));
    // no-op
    var result = await update.execute({'ref_event': ref}, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // 未知 scope
    result = await update.execute({'ref_event': ref, 'title': 'x', 'scope': 'all'}, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // 未知 status
    result = await update.execute({'ref_event': ref, 'status': 'postponed'}, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // 未知 type
    result = await update.execute({'ref_event': ref, 'type': 'lecture'}, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // 未知 importance
    result = await update.execute({'ref_event': ref, 'importance': 'urgent'}, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // delete 与 status 混用
    result = await update.execute({'ref_event': ref, 'delete': true, 'status': 'cancelled'}, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // delete 与字段编辑混用
    result = await update.execute({'ref_event': ref, 'delete': true, 'title': 'x'}, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // 只给时间对一端
    result = await update.execute({
      'ref_event': ref, 'start_at': '2026-08-01T17:00:00+08:00',
    }, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
  });

  test('create_user_overlay rejects no mutation and unknown enums', () async {
    final h = _Harness(tools());
    final gw = _OverlayGateway();
    final tool = h.tool('create_user_overlay');
    tool.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    // 无任何标注字段
    var result = await tool.execute({'ref_event': ref}, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // 未知 scope
    result = await tool.execute({'ref_event': ref, 'scope': 'big', 'display_title': 'x'}, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // 未知 attendance
    result = await tool.execute({'ref_event': ref, 'attendance_policy': 'maybe'}, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // 未知 listening
    result = await tool.execute({'ref_event': ref, 'listening_mode': 'probably'}, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // 未知 importance
    result = await tool.execute({'ref_event': ref, 'importance': 'urgent'}, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
  });

  test('create_user_overlay rejects wrong-typed notes/display_title even alongside a policy', () async {
    final h = _Harness(tools());
    final gw = _OverlayGateway();
    final tool = h.tool('create_user_overlay');
    tool.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    // attendance_policy 在场使 previewLines 非空，错误类型的 attendance_note 仍须被拒。
    var result = await tool.execute({
      'ref_event': ref, 'attendance_policy': 'must_go', 'attendance_note': 123,
    }, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // listening_mode 在场时，错误类型的 listening_note 仍须被拒。
    result = await tool.execute({
      'ref_event': ref, 'listening_mode': 'listen', 'listening_note': true,
    }, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // attendance_policy 在场时，错误类型的 display_title 仍须被拒。
    result = await tool.execute({
      'ref_event': ref, 'attendance_policy': 'must_go', 'display_title': 42,
    }, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // display_title 单独在场（无 policy）时错误类型也须被拒。
    result = await tool.execute({'ref_event': ref, 'display_title': 42}, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
  });

  test('record_attendance_decision rejects unknown decision, no undecided fallback', () async {
    final h = _Harness(tools());
    final gw = _OverlayGateway();
    final tool = h.tool('record_attendance_decision');
    tool.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    final result = await tool.execute({'ref_event': ref, 'decision': 'maybe'}, h.ctx());
    expect(result.status, AgentToolStatus.error);
    expect(result.errorCode, 'invalid_write_arguments');
  });

  test('record_listening_mode rejects unknown mode, no listen fallback', () async {
    final h = _Harness(tools());
    final gw = _OverlayGateway();
    final tool = h.tool('record_listening_mode');
    tool.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    final result = await tool.execute({'ref_event': ref, 'mode': 'ofcourse'}, h.ctx());
    expect(result.status, AgentToolStatus.error);
    expect(result.errorCode, 'invalid_write_arguments');
  });

  test('create_schedule_relation rejects unknown conflict state and same ref', () async {
    final h = _Harness(tools());
    final gw = _RelationGateway();
    final tool = h.tool('create_schedule_relation');
    tool.attachGateway(gw);
    final left = h.refs.bind(kind: 'event', localId: 'ev-1');
    final right = h.refs.bind(kind: 'event', localId: 'ev-2');
    // 未知 conflict_state
    var result = await tool.execute({
      'ref_left': left, 'ref_right': right, 'conflict_state': 'maybe',
    }, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // 同一 ref 两侧（字符串相同先被拒）
    result = await tool.execute({
      'ref_left': left, 'ref_right': left, 'conflict_state': 'no_conflict',
    }, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
  });

  test('set_reminder rejects negative, non-integer and empty offsets', () async {
    final h = _Harness(tools());
    final gw = _RelationGateway();
    final tool = h.tool('set_reminder');
    tool.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    // 负偏移
    var result = await tool.execute({'ref_event': ref, 'offsets_minutes': [-5]}, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // 非整数元素
    result = await tool.execute({'ref_event': ref, 'offsets_minutes': ['10']}, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // 空列表
    result = await tool.execute({'ref_event': ref, 'offsets_minutes': []}, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
  });

  test('set_reminder sorts and dedups offsets before committing', () async {
    final h = _Harness(tools());
    final gw = _RelationGateway();
    final tool = h.tool('set_reminder');
    tool.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    final result = await tool.execute({
      'ref_event': ref, 'offsets_minutes': [30, 15, 30, 120],
    }, h.ctx());
    expect(result.status, AgentToolStatus.needsUserAction);
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gw.reminder!.offsets, [15, 30, 120]);
  });

  test('update_permission_policy rejects unknown action/target/mode', () async {
    final h = _Harness(tools());
    final gw = _RelationGateway();
    final tool = h.tool('update_permission_policy');
    tool.attachGateway(gw);
    // 未知 action_type
    var result = await tool.execute({
      'action_type': 'smash_everything', 'confirmation_mode': 'always_ask',
    }, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // 未知 confirmation_mode
    result = await tool.execute({
      'action_type': 'create_event', 'confirmation_mode': 'sometimes',
    }, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // 未知 target_type（显式传错值）
    result = await tool.execute({
      'action_type': 'create_event', 'target_type': 'galaxy', 'confirmation_mode': 'always_ask',
    }, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
  });

  // ========== Task 2: target previews identify the target ==========

  void expectNoIdsOrRefs(AgentWriteProposal proposal, List<String> seededIds) {
    final view = proposal.toView();
    final lines = view.previewLines.join('\n');
    final log = proposal.safeLogSummary;
    for (final id in seededIds) {
      expect(lines, isNot(contains(id)), reason: 'preview must not leak $id');
      expect(log, isNot(contains(id)), reason: 'log must not leak $id');
    }
    expect(lines, isNot(contains('ref_')), reason: 'preview must not leak ref_*');
    expect(log, isNot(contains('ref_')), reason: 'log must not leak ref_*');
  }

  test('plan_task preview identifies the task title', () async {
    final h = _Harness(tools());
    final taskRef = h.refs.bind(kind: 'task', localId: 'task-secret');
    final proposal = await h.tool('plan_task').propose({
      'ref_task': taskRef,
      'start_at': '2026-08-03T20:00:00+08:00',
      'end_at': '2026-08-03T21:00:00+08:00',
    }, h.ctx());
    expect(proposal.previewLines, contains('目标：准备考试'));
    expectNoIdsOrRefs(proposal, ['task-secret']);
  });

  test('update_event preview identifies event title, current time and change',
      () async {
    final h = _Harness(tools());
    final update = h.tool('update_event') as UpdateEventTool;
    final gw = _UpdateGateway();
    update.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-secret');
    gw.snapshots['ev-secret'] = EventWriteSnapshot(
      id: 'ev-secret', source: 'user', type: 'personal', title: '健身',
      allDay: false,
      startAt: DateTime(2026, 8, 1, 15), endAt: DateTime(2026, 8, 1, 16),
      location: '健身房',
    );
    final proposal = await update.propose({'ref_event': ref, 'status': 'completed'}, h.ctx());
    expect(proposal.previewLines, contains('目标：健身'));
    expect(proposal.previewLines, contains('当前时间：2026-08-01 15:00-16:00'));
    expect(proposal.previewLines, contains('地点：健身房'));
    expect(proposal.previewLines, contains('变更：状态改为 completed'));
    expectNoIdsOrRefs(proposal, ['ev-secret']);
  });

  test('create_user_overlay preview identifies the target event', () async {
    final h = _Harness(tools());
    final gw = _OverlayGateway();
    final tool = h.tool('create_user_overlay');
    tool.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-secret');
    final proposal = await tool.propose({
      'ref_event': ref, 'attendance_policy': 'must_go', 'attendance_note': '小测',
    }, h.ctx());
    expect(proposal.previewLines, contains('目标：课程A'));
    expectNoIdsOrRefs(proposal, ['ev-secret']);
  });

  test('record_attendance_decision preview identifies the target event', () async {
    final h = _Harness(tools());
    final gw = _OverlayGateway();
    final tool = h.tool('record_attendance_decision');
    tool.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-secret');
    final proposal = await tool.propose({'ref_event': ref, 'decision': 'go'}, h.ctx());
    expect(proposal.previewLines, contains('目标：课程A'));
    expect(proposal.previewLines, contains('出勤决定：go'));
    expectNoIdsOrRefs(proposal, ['ev-secret']);
  });

  test('record_listening_mode preview identifies the target event', () async {
    final h = _Harness(tools());
    final gw = _OverlayGateway();
    final tool = h.tool('record_listening_mode');
    tool.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-secret');
    final proposal = await tool.propose({
      'ref_event': ref, 'mode': 'not_listen', 'note': '适合写作业',
    }, h.ctx());
    expect(proposal.previewLines, contains('目标：课程A'));
    expect(proposal.previewLines, contains('听讲：not_listen'));
    expectNoIdsOrRefs(proposal, ['ev-secret']);
  });

  test('set_reminder preview identifies the target event', () async {
    final h = _Harness(tools());
    final gw = _RelationGateway();
    final tool = h.tool('set_reminder');
    tool.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-secret');
    final proposal = await tool.propose({'ref_event': ref, 'offsets_minutes': [15]}, h.ctx());
    expect(proposal.previewLines, contains('目标：健身'));
    expect(proposal.previewLines, contains('开始前 [15] 分钟提醒'));
    expectNoIdsOrRefs(proposal, ['ev-secret']);
  });

  test('create_schedule_relation preview identifies both participants', () async {
    final h = _Harness(tools());
    final gw = _RelationGateway();
    final tool = h.tool('create_schedule_relation');
    tool.attachGateway(gw);
    final left = h.refs.bind(kind: 'event', localId: 'ev-left');
    final right = h.refs.bind(kind: 'event', localId: 'ev-right');
    final proposal = await tool.propose({
      'ref_left': left,
      'ref_right': right,
      'conflict_state': 'conflict',
      'reason': '重叠',
    }, h.ctx());
    expect(proposal.previewLines, contains('日程 A：健身 / 2026-08-01 09:00-10:00'));
    expect(proposal.previewLines, contains('日程 B：健身 / 2026-08-01 09:00-10:00'));
    expect(proposal.previewLines, contains('关系：conflict'));
    expectNoIdsOrRefs(proposal, ['ev-left', 'ev-right']);
  });

  test('update_permission_policy preview shows target action/type/modes', () async {
    final h = _Harness(tools());
    final gw = _RelationGateway();
    final tool = h.tool('update_permission_policy');
    tool.attachGateway(gw);
    final proposal = await tool.propose({
      'action_type': 'create_event',
      'target_type': 'event',
      'confirmation_mode': 'always_allow',
    }, h.ctx());
    expect(proposal.previewLines, contains('目标动作：create_event'));
    expect(proposal.previewLines, contains('目标类型：event'));
    expect(proposal.previewLines, contains('当前模式：ask_first_time'));
    expect(proposal.previewLines, contains('改为：always_allow'));
    expectNoIdsOrRefs(proposal, const []);
  });

  test('plan_task rejects a task deleted between propose and commit', () async {
    final h = _Harness(tools());
    final taskRef = h.refs.bind(kind: 'task', localId: 'task-gone');
    final result = await h.tool('plan_task').execute({
      'ref_task': taskRef,
      'start_at': '2026-08-03T20:00:00+08:00',
      'end_at': '2026-08-03T21:00:00+08:00',
    }, h.ctx());
    expect(result.status, AgentToolStatus.needsUserAction);
    // 提案通过后任务被删除：commit 阶段必须重新校验并拒绝。
    gateway.taskMissing = true;
    final committed = await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(committed.status, AgentToolStatus.error);
    expect(committed.errorCode, 'target_not_found');
    expect(gateway.plannedBlocks, isEmpty);
  });

  test('create_schedule_relation rejects a participant deleted before commit',
      () async {
    final h = _Harness(tools());
    final gw = _RelationGateway();
    final tool = h.tool('create_schedule_relation');
    tool.attachGateway(gw);
    final left = h.refs.bind(kind: 'event', localId: 'ev-left');
    final right = h.refs.bind(kind: 'event', localId: 'ev-right');
    final result = await tool.execute({
      'ref_left': left,
      'ref_right': right,
      'conflict_state': 'conflict',
      'reason': '重叠',
    }, h.ctx());
    expect(result.status, AgentToolStatus.needsUserAction);
    // 提案通过后其中一个参与方被删除：commit 阶段必须重新校验并拒绝。
    gw.participantMissing = true;
    final committed = await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(committed.status, AgentToolStatus.error);
    expect(committed.errorCode, 'target_not_found');
    expect(gw.relation, isNull);
  });
}
