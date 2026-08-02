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
import 'package:ustc_assistant_app/features/schedule/domain/jw_day_move.dart';

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

/// move_jw_course_day 专用假网关：只实现 preview/move/clear 三个新方法。
class _MoveGateway implements AgentWriteGateway {
  JwDayMovePreview? preview;
  /// jwDayMove 在 commit 阶段抛错（模拟重检失败：课程消失/日期非法等）。
  Object? moveError;
  /// jwDayMoveClear 在 commit 阶段抛 MissingJwDayMove（记录已被删除）。
  bool clearMissing = false;
  /// jwDayMove 返回 true 表示重定向（原记录已存在）。
  bool retarget = false;
  ({String sourceDate, String targetDate})? moved;
  String? cleared;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();

  @override
  Future<JwDayMovePreview> jwDayMovePreview(String sourceDate) async => preview!;

  @override
  Future<bool> jwDayMove(String sourceDate, String targetDate) async {
    final error = moveError;
    if (error != null) throw error;
    moved = (sourceDate: sourceDate, targetDate: targetDate);
    return retarget;
  }

  @override
  Future<void> jwDayMoveClear(String sourceDate) async {
    if (clearMissing) throw MissingJwDayMove(sourceDate);
    cleared = sourceDate;
  }
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
    MoveJwCourseDayTool(gateway: gateway, policy: policy, confirmationStore: store, unitOfWork: unitOfWork),
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

  test('create_schedule_relation guidance states concrete choices are no_conflict',
      () {
    final t = tools();
    final tool = t.firstWhere((x) => x.name == 'create_schedule_relation');
    final desc = tool.description;
    // 用户已选择一项 / 允许共存 / 课上完成另一任务 -> no_conflict。
    expect(desc, contains('另一任务'));
    expect(desc, contains('no_conflict'));
    expect(desc, contains('尚未决定'));
    expect(desc, contains('先询问'));
    final props =
        (tool.inputSchema['properties'] as Map<String, Object?>)['conflict_state']
            as Map<String, Object?>;
    final stateDesc = props['description'] as String;
    expect(stateDesc, contains('no_conflict'));
    expect(stateDesc, contains('不能仅因为'));
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

  Future<List<ActionLog>> actionLogsFor(String accountId) async =>
      (await db.actionLogsRepository.selectAll())
          .where((l) => l.accountId == accountId)
          .toList();

  test('update_permission_policy proposal does not shadow actionType (High 2)',
      () async {
    // 修复影子覆盖：调整 create_event 的策略时，proposal.actionType 必须恒为
    // update_permission_policy，而目标动作只作为 targetActionType。
    final h = _Harness(tools());
    final gw = _RelationGateway();
    final tool = h.tool('update_permission_policy');
    tool.attachGateway(gw);
    final proposal = await tool.propose({
      'action_type': 'create_event',
      'target_type': 'event',
      'confirmation_mode': 'always_allow',
    }, h.ctx());
    expect(proposal.actionType, 'update_permission_policy');
    expect(proposal.commitParams['targetActionType'], 'create_event');
    expect(proposal.targetType, 'event');
  });

  test('update_permission_policy approval logs agent action not target action',
      () async {
    // 确认一个把 create_event 放宽为 always_allow 的提案后，Agent 审计必须记
    // update_permission_policy（业务写本身的 action），而不是把它记成 create_event。
    final h = _Harness(tools());
    final gw = _RelationGateway();
    final tool = h.tool('update_permission_policy');
    tool.attachGateway(gw);
    final result = await tool.execute({
      'action_type': 'create_event',
      'target_type': 'event',
      'confirmation_mode': 'always_allow',
    }, h.ctx());
    expect(result.status, AgentToolStatus.needsUserAction);
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);

    final agentLogs = await actionLogsFor('a1');
    expect(
      agentLogs.any((log) =>
          log.source == 'agent' && log.actionType == 'update_permission_policy'),
      isTrue,
    );
    expect(
      agentLogs.where((log) => log.source == 'agent' && log.actionType == 'create_event'),
      isEmpty,
    );
    // 用户确认决策本身也留一行（agent_write_confirm/approved）。
    expect(
      agentLogs.any((log) =>
          log.source == 'user' &&
          log.actionType == 'agent_write_confirm' &&
          log.result == 'approved'),
      isTrue,
    );
  });

  test('decline writes agent_write_decline/declined and never commits', () async {
    final h = _Harness(tools());
    final tool = h.tool('create_event');
    final result = await tool.execute({
      'title': '健身',
      'start_at': '2026-08-01T15:00:00+08:00',
      'end_at': '2026-08-01T16:00:00+08:00',
    }, h.ctx());
    final resumed = await store.resolve(result.userAction!.opaqueHandle, approve: false, remember: false);
    expect(resumed.errorCode, 'user_declined');
    expect(gateway.createdEvents, isEmpty); // 未发生业务写
    final logs = await actionLogsFor('a1');
    expect(
      logs.any((l) =>
          l.source == 'user' && l.actionType == 'agent_write_decline' && l.result == 'declined'),
      isTrue,
    );
  });

  test('cancel writes agent_write_cancel/cancelled best-effort', () async {
    final h = _Harness(tools());
    final tool = h.tool('create_event');
    final result = await tool.execute({
      'title': '健身',
      'start_at': '2026-08-01T15:00:00+08:00',
      'end_at': '2026-08-01T16:00:00+08:00',
    }, h.ctx());
    await result.pendingInvocation!.cancel();
    final resumed = await result.pendingInvocation!.result;
    expect(resumed.errorCode, 'cancelled');
    final logs = await actionLogsFor('a1');
    expect(
      logs.any((l) =>
          l.source == 'agent' && l.actionType == 'agent_write_cancel' && l.result == 'cancelled'),
      isTrue,
    );
  });

  test('approval writes user confirm plus one agent business log', () async {
    final h = _Harness(tools());
    final gw = _RelationGateway();
    final tool = h.tool('set_reminder');
    tool.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    final result = await tool.execute({'ref_event': ref, 'offsets_minutes': [15]}, h.ctx());
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    final logs = await actionLogsFor('a1');
    // 恰好一条用户确认 + 一条 agent 业务日志（set_reminder）。
    final userConfirm = logs.where((l) => l.actionType == 'agent_write_confirm');
    expect(userConfirm.length, 1);
    expect(userConfirm.single.result, 'approved');
    final agentBusiness = logs.where((l) => l.source == 'agent' && l.actionType == 'set_reminder');
    expect(agentBusiness.length, 1);
    expect(agentBusiness.single.result, 'success');
  });

  test('remember relaxes create_event and logs update_permission_policy with safe summary', () async {
    final h = _Harness(tools());
    final tool = h.tool('create_event');
    final result = await tool.execute({
      'title': '健身',
      'start_at': '2026-08-01T15:00:00+08:00',
      'end_at': '2026-08-01T16:00:00+08:00',
    }, h.ctx());
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: true);
    final logs = await actionLogsFor('a1');
    expect(
      logs.any((l) =>
          l.source == 'user' &&
          l.actionType == 'update_permission_policy' &&
          l.safeSummary == 'create_event(event) -> always_allow'),
      isTrue,
    );
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

  // ========== Task 9: move_jw_course_day（critical 整日移动）==========

  test('move_jw_course_day requires action/source and move requires target', () async {
    final h = _Harness(tools());
    final gw = _MoveGateway();
    gw.preview = const JwDayMovePreview(
        sourceDate: '2026-08-03', targetDate: null, courses: ['线性代数']);
    final tool = h.tool('move_jw_course_day');
    tool.attachGateway(gw);
    // 缺 action
    var result = await tool.execute({
      'source_date': '2026-08-03', 'target_date': '2026-08-09',
    }, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // 缺 source_date
    result = await tool.execute({
      'action': 'move', 'target_date': '2026-08-09',
    }, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // move 缺 target_date
    result = await tool.execute({
      'action': 'move', 'source_date': '2026-08-03',
    }, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // clear 不允许 target_date
    result = await tool.execute({
      'action': 'clear', 'source_date': '2026-08-03', 'target_date': '2026-08-09',
    }, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // 未知 action
    result = await tool.execute({
      'action': 'swap', 'source_date': '2026-08-03', 'target_date': '2026-08-09',
    }, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
  });

  test('move_jw_course_day rejects unknown fields, wrong types, malformed and same dates', () async {
    final h = _Harness(tools());
    final gw = _MoveGateway();
    gw.preview = const JwDayMovePreview(
        sourceDate: '2026-08-03', targetDate: null, courses: ['线性代数']);
    final tool = h.tool('move_jw_course_day');
    tool.attachGateway(gw);
    // 未知字段
    var result = await tool.execute({
      'action': 'move', 'source_date': '2026-08-03', 'target_date': '2026-08-09',
      'sneaky': true,
    }, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // action 非字符串
    result = await tool.execute({
      'action': 1, 'source_date': '2026-08-03', 'target_date': '2026-08-09',
    }, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // source_date 非字符串
    result = await tool.execute({
      'action': 'move', 'source_date': 20260803, 'target_date': '2026-08-09',
    }, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // 畸形日期
    result = await tool.execute({
      'action': 'move', 'source_date': '2026-13-40', 'target_date': '2026-08-09',
    }, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    result = await tool.execute({
      'action': 'move', 'source_date': '2026-02-31', 'target_date': '2026-08-09',
    }, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    result = await tool.execute({
      'action': 'move', 'source_date': '08-03', 'target_date': '2026-08-09',
    }, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
    // 相同日期
    result = await tool.execute({
      'action': 'move', 'source_date': '2026-08-03', 'target_date': '2026-08-03',
    }, h.ctx());
    expect(result.errorCode, 'invalid_write_arguments');
  });

  test('move_jw_course_day with no eligible courses fails before confirmation', () async {
    final h = _Harness(tools());
    final gw = _MoveGateway();
    gw.preview = const JwDayMovePreview(
        sourceDate: '2026-08-03', targetDate: null, courses: []);
    final tool = h.tool('move_jw_course_day');
    tool.attachGateway(gw);
    final result = await tool.execute({
      'action': 'move', 'source_date': '2026-08-03', 'target_date': '2026-08-09',
    }, h.ctx());
    expect(result.status, AgentToolStatus.error);
    expect(result.errorCode, 'no_eligible_jw_courses');
    expect(result.userAction, isNull,
        reason: '空预览不得产生可批准的确认卡');
    expect(gw.moved, isNull);
  });

  test('move_jw_course_day preview shows source/target/count/titles, no ids or refs', () async {
    final h = _Harness(tools());
    final gw = _MoveGateway();
    gw.preview = const JwDayMovePreview(
        sourceDate: '2026-08-03', targetDate: null,
        courses: ['线性代数', '大学物理']);
    final tool = h.tool('move_jw_course_day');
    tool.attachGateway(gw);
    final proposal = await tool.propose({
      'action': 'move', 'source_date': '2026-08-03', 'target_date': '2026-08-09',
    }, h.ctx());
    final lines = proposal.previewLines.join('\n');
    expect(lines, contains('2026-08-03'), reason: '预览必须包含源日期');
    expect(lines, contains('2026-08-09'), reason: '预览必须包含目标日期');
    expect(lines, contains('2'), reason: '预览必须包含课程数');
    expect(lines, contains('线性代数'));
    expect(lines, contains('大学物理'));
    expectNoIdsOrRefs(proposal, const []);
    expect(proposal.rememberAllowed, isFalse,
        reason: 'critical 动作的确认卡永不提供"以后不再确认"');
    expect(proposal.forceConfirmation, isTrue);
  });

  test('move_jw_course_day commit rechecks eligibility and returns safe errors', () async {
    final h = _Harness(tools());
    final gw = _MoveGateway();
    gw.preview = const JwDayMovePreview(
        sourceDate: '2026-08-03', targetDate: null, courses: ['线性代数']);
    final tool = h.tool('move_jw_course_day');
    tool.attachGateway(gw);
    final result = await tool.execute({
      'action': 'move', 'source_date': '2026-08-03', 'target_date': '2026-08-09',
    }, h.ctx());
    expect(result.status, AgentToolStatus.needsUserAction);
    // 提案后课程不再可移动：commit 必须重检并安全拒绝。
    gw.moveError = const NoEligibleJwCourses('2026-08-03');
    final committed = await store.resolve(
        result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(committed.status, AgentToolStatus.error);
    expect(committed.errorCode, 'no_eligible_jw_courses');
    expect(gw.moved, isNull, reason: '重检失败不得产生任何写');
  });

  test('move_jw_course_day clear rechecks the record and returns target_not_found', () async {
    final h = _Harness(tools());
    final gw = _MoveGateway();
    gw.preview = const JwDayMovePreview(
        sourceDate: '2026-08-03', targetDate: '2026-08-09', courses: ['线性代数']);
    final tool = h.tool('move_jw_course_day');
    tool.attachGateway(gw);
    final result = await tool.execute({'action': 'clear', 'source_date': '2026-08-03'}, h.ctx());
    expect(result.status, AgentToolStatus.needsUserAction);
    // 提案后移动记录被清除：commit 必须重检并安全拒绝。
    gw.clearMissing = true;
    final committed = await store.resolve(
        result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(committed.status, AgentToolStatus.error);
    expect(committed.errorCode, 'target_not_found');
    expect(gw.cleared, isNull);
  });

  test('move_jw_course_day clear with no record fails before confirmation', () async {
    final h = _Harness(tools());
    final gw = _MoveGateway();
    gw.preview = const JwDayMovePreview(
        sourceDate: '2026-08-03', targetDate: null, courses: []);
    final tool = h.tool('move_jw_course_day');
    tool.attachGateway(gw);
    final result = await tool.execute({'action': 'clear', 'source_date': '2026-08-03'}, h.ctx());
    expect(result.status, AgentToolStatus.error);
    expect(result.errorCode, 'target_not_found');
    expect(result.userAction, isNull);
    expect(gw.cleared, isNull);
  });

  test('move_jw_course_day approval commits atomically, never offers remember and logs success', () async {
    final h = _Harness(tools());
    final gw = _MoveGateway();
    gw.preview = const JwDayMovePreview(
        sourceDate: '2026-08-03', targetDate: null, courses: ['线性代数']);
    final tool = h.tool('move_jw_course_day');
    tool.attachGateway(gw);
    final result = await tool.execute({
      'action': 'move', 'source_date': '2026-08-03', 'target_date': '2026-08-09',
    }, h.ctx());
    expect(result.status, AgentToolStatus.needsUserAction);
    expect(result.userAction!.writeProposal!.rememberAllowed, isFalse,
        reason: 'critical 确认卡永不提供"以后不再确认"');
    final committed = await store.resolve(
        result.userAction!.opaqueHandle, approve: true, remember: true);
    expect(committed.payload['result'], 'moved_jw_course_day');
    expect(gw.moved, (sourceDate: '2026-08-03', targetDate: '2026-08-09'));
    final logs = await actionLogsFor('a1');
    expect(
      logs.where((l) =>
          l.source == 'agent' &&
          l.actionType == 'move_jw_course_day' &&
          l.result == 'success'),
      hasLength(1),
      reason: '批准必须原子写入一条 agent 成功日志',
    );
    // remember=true 也无法放宽 critical 动作：策略决议仍是 confirm。
    expect(
      await policy.resolve(
          accountId: 'a1',
          actionType: 'move_jw_course_day',
          targetType: 'jw_day_move',
          riskLevel: RiskLevel.critical),
      PermissionDecision.confirm,
    );
  });

  test('move_jw_course_day returns retargeted and cleared result values', () async {
    final h = _Harness(tools());
    final gw = _MoveGateway();
    final tool = h.tool('move_jw_course_day');
    tool.attachGateway(gw);
    // 重定向：原记录已存在 → retargeted_jw_course_day。
    gw.preview = const JwDayMovePreview(
        sourceDate: '2026-08-03', targetDate: '2026-08-09', courses: ['线性代数']);
    gw.retarget = true;
    var result = await tool.execute({
      'action': 'move', 'source_date': '2026-08-03', 'target_date': '2026-08-10',
    }, h.ctx());
    expect(result.status, AgentToolStatus.needsUserAction);
    expect(result.userAction!.writeProposal!.previewLines,
        anyElement(contains('已有移动记录')),
        reason: '重定向时确认卡必须提示已有移动记录');
    var committed = await store.resolve(
        result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(committed.payload['result'], 'retargeted_jw_course_day');
    // clear → cleared_jw_course_day_move。
    gw.preview = const JwDayMovePreview(
        sourceDate: '2026-08-03', targetDate: '2026-08-09', courses: ['线性代数']);
    result = await tool.execute({'action': 'clear', 'source_date': '2026-08-03'}, h.ctx());
    committed = await store.resolve(
        result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(committed.payload['result'], 'cleared_jw_course_day_move');
    expect(gw.cleared, '2026-08-03');
  });

  test('move_jw_course_day decline and cancel write nothing', () async {
    final h = _Harness(tools());
    final gw = _MoveGateway();
    gw.preview = const JwDayMovePreview(
        sourceDate: '2026-08-03', targetDate: null, courses: ['线性代数']);
    final tool = h.tool('move_jw_course_day');
    tool.attachGateway(gw);
    // decline
    var result = await tool.execute({
      'action': 'move', 'source_date': '2026-08-03', 'target_date': '2026-08-09',
    }, h.ctx());
    var resumed = await store.resolve(
        result.userAction!.opaqueHandle, approve: false, remember: false);
    expect(resumed.errorCode, 'user_declined');
    expect(gw.moved, isNull, reason: '拒绝不得产生任何写');
    final logs = await actionLogsFor('a1');
    expect(
      logs.any((l) =>
          l.source == 'user' &&
          l.actionType == 'agent_write_decline' &&
          l.result == 'declined'),
      isTrue,
    );
    // cancel
    result = await tool.execute({
      'action': 'move', 'source_date': '2026-08-03', 'target_date': '2026-08-09',
    }, h.ctx());
    await result.pendingInvocation!.cancel();
    resumed = await result.pendingInvocation!.result;
    expect(resumed.errorCode, 'cancelled');
    expect(gw.moved, isNull, reason: '取消不得产生任何写');
  });

  test('update_permission_policy cannot relax move_jw_course_day', () async {
    final h = _Harness(tools());
    final gw = _RelationGateway();
    final tool = h.tool('update_permission_policy');
    tool.attachGateway(gw);
    final result = await tool.execute({
      'action_type': 'move_jw_course_day',
      'target_type': 'jw_day_move',
      'confirmation_mode': 'always_allow',
    }, h.ctx());
    expect(result.status, AgentToolStatus.error);
    expect(result.errorCode, 'invalid_write_arguments');
    expect(gw.policyUpdate, isNull,
        reason: 'critical 整日移动不可被权限工具放宽');
  });
}
