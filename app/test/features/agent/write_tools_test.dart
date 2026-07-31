import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_permission_policy_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_write_tool.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_write_tools.dart';
import 'package:ustc_assistant_app/features/agent/application/cancellation_signal.dart';
import 'package:ustc_assistant_app/features/agent/application/run_reference_store.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_tool.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_write_gateway.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_write_proposal.dart';
import 'package:ustc_assistant_app/features/calendar/application/recurrence_service.dart';
import 'package:ustc_assistant_app/features/calendar/domain/personal_event.dart';
import 'package:ustc_assistant_app/features/tasks/domain/plan_block.dart';
import 'package:ustc_assistant_app/features/tasks/domain/task.dart';

class _FixedClock implements BeijingClock {
  @override
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);
}

/// 记录被调用方法的假网关；未覆盖方法抛错。
class _RecordingGateway implements AgentWriteGateway {
  final List<PersonalEvent> createdEvents = [];
  final List<Map<String, Object?>> createdTasks = [];
  final List<Map<String, Object?>> plannedBlocks = [];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();

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
  final Map<String, EventWriteIdentity> identities = {};
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
  Future<EventWriteIdentity> eventIdentity(String eventId) async =>
      identities[eventId]!;

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
    store = WriteConfirmationStore(policy: policy);
    gateway = _RecordingGateway();
  });

  tearDown(() => db.close());

  List<AgentWriteTool> tools() => [
    CreateEventTool(gateway: gateway, policy: policy, confirmationStore: store),
    CreateTaskTool(gateway: gateway, policy: policy, confirmationStore: store),
    PlanTaskTool(gateway: gateway, policy: policy, confirmationStore: store),
    UpdateEventTool(gateway: gateway, policy: policy, confirmationStore: store),
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
    gw.identities['ev-1'] = const EventWriteIdentity(id: 'ev-1', source: 'user', type: 'personal');
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
    gw.identities['ev-1'] = const EventWriteIdentity(id: 'ev-1', source: 'user', type: 'personal');
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
    gw.identities['ev-1'] = const EventWriteIdentity(
      id: 'ev-1', source: 'user', type: 'personal',
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
    gw.identities['ev-1'] = const EventWriteIdentity(
      id: 'ev-1', source: 'user', type: 'personal',
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
    gw.identities['ev-1'] = const EventWriteIdentity(
      id: 'ev-1', source: 'user', type: 'personal',
      personalSeriesId: 'ser-1', occurrenceKey: 'k');
    // 整系列时间变更在 commit 阶段拒绝；update_event 恒走确认，先批准再断言。
    final result = await update.execute({
      'ref_event': ref, 'scope': 'whole_series', 'start_at': '2026-08-05T17:00:00+08:00',
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
    gw.identities['ev-1'] = const EventWriteIdentity(id: 'ev-1', source: 'ustc_jw', type: 'course');
    // 来源校验在 commit 阶段；同样先批准。
    final result = await update.execute({'ref_event': ref, 'title': 'x'}, h.ctx());
    expect(result.status, AgentToolStatus.needsUserAction);
    final committed = await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(committed.status, AgentToolStatus.error);
    expect(committed.errorCode, 'source_event_not_editable');
  });
}
