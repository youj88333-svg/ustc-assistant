// M4 回归固化：8 个生命周期/清除/撤回写工具 + update_event 学校课程事件删除拒绝。
//
// 本文件自包含：定义自己的 harness（_FixedClock / _Harness / _LifecycleGateway），
// 不跨文件 import 其他测试的私有 helper（write_tools_test / composition_flow 的
// 私有 seeding helper 不可 import）。每个用例断言一条**已被代码锁定、容易在重构
// 中丢失的契约**，全部经 propose→approve 真实提交路径（fake gateway 记录调用 +
// WriteConfirmationStore 批准）；学校事件拒绝删除用真实 Drift DB。
//
// 详见 docs/plan-webview-minimal-m4.md §3。

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_permission_policy_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_write_tool.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_write_tools.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_lifecycle_tools.dart';
import 'package:ustc_assistant_app/features/agent/application/cancellation_signal.dart';
import 'package:ustc_assistant_app/features/agent/application/run_reference_store.dart';
import 'package:ustc_assistant_app/features/agent/data/drift_agent_write_gateway.dart';
import 'package:ustc_assistant_app/features/agent/data/drift_agent_write_unit_of_work.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_tool.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_write_gateway.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_write_unit_of_work.dart';
import 'package:ustc_assistant_app/features/reminders/application/reminder_override_service.dart';
import 'package:ustc_assistant_app/features/schedule/application/conflict_service.dart'
    show ConflictNotDeletableError;
import 'package:ustc_assistant_app/features/tasks/application/plan_block_service.dart'
    show NotDeletedError, PlanBlockNotFoundError;
import 'package:ustc_assistant_app/features/tasks/application/task_event_link_service.dart'
    show StaleTaskEventLinkCommand;
import 'package:ustc_assistant_app/features/tasks/application/task_lifecycle_service.dart'
    show TaskNotFoundError;
import 'package:ustc_assistant_app/features/tasks/domain/plan_block.dart';
import 'package:ustc_assistant_app/features/tasks/domain/task.dart';

/// 固定时间钟：now() 永远返回同一时刻，保证测试确定性。
class _FixedClock implements BeijingClock {
  @override
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);
}

/// 生命周期/清除/撤回工具的假网关：记录每个被调方法的参数，可注入异常。
///
/// 必须显式覆盖 8 个工具在 propose 与 commit 阶段调用的全部方法；未覆盖方法经
/// `noSuchMethod` 抛 `UnimplementedError`（设计：未用到的方法不实现，用到的方法
/// 漏覆盖会立即失败而非静默通过）。
class _LifecycleGateway implements AgentWriteGateway {
  // ---- task lifecycle（commit） ----
  String? completedTaskId;
  Object? completeTaskThrows;
  String? cancelledTaskId;
  Object? cancelTaskThrows;
  String? reopenedTaskId;
  String? softDeletedTaskId;
  Object? softDeleteTaskThrows;
  String? restoredTaskId;
  Object? restoreTaskThrows;

  // ---- task propose 读取（I4 软删除过滤） ----
  final Set<String> deletedTaskIds = {};
  final Map<String, int> taskUpdatedAt = {};
  int taskByIdUpdatedAt = 1;

  void markTaskDeleted(String taskId, {int? updatedAt}) {
    deletedTaskIds.add(taskId);
    if (updatedAt != null) taskUpdatedAt[taskId] = updatedAt;
  }

  @override
  Future<TaskItem> taskById(String taskId) async {
    if (deletedTaskIds.contains(taskId)) throw TaskNotFoundError();
    return TaskItem(
      id: taskId,
      title: '准备考试',
      state: TaskState.active,
      importance: TaskImportance.normal,
      createdAt: 1,
      updatedAt: taskUpdatedAt[taskId] ?? taskByIdUpdatedAt,
    );
  }

  @override
  Future<TaskItem> taskByIdIncludeDeleted(String taskId) async => TaskItem(
        id: taskId,
        title: '准备考试',
        state: TaskState.active,
        importance: TaskImportance.normal,
        createdAt: 1,
        updatedAt: taskUpdatedAt[taskId] ?? taskByIdUpdatedAt,
      );

  @override
  Future<void> completeTask(String id, {required int expectedUpdatedAt}) async {
    final e = completeTaskThrows;
    if (e != null) throw e;
    completedTaskId = id;
  }

  @override
  Future<void> cancelTask(String id, {required int expectedUpdatedAt}) async {
    final e = cancelTaskThrows;
    if (e != null) throw e;
    cancelledTaskId = id;
  }

  @override
  Future<void> reopenTask(String id, {required int expectedUpdatedAt}) async =>
      reopenedTaskId = id;

  @override
  Future<void> softDeleteTask(String id,
      {required int expectedUpdatedAt}) async {
    final e = softDeleteTaskThrows;
    if (e != null) throw e;
    softDeletedTaskId = id;
    deletedTaskIds.add(id); // 模拟真实服务：软删除后 taskById 过滤
  }

  @override
  Future<void> restoreTask(String id, {required int expectedUpdatedAt}) async {
    final e = restoreTaskThrows;
    if (e != null) throw e;
    deletedTaskIds.remove(id); // 模拟真实服务：恢复后清除软删除标记
    restoredTaskId = id;
  }

  // ---- plan_block lifecycle（commit） ----
  String? doneBlockId;
  String? doneNote;
  String? skippedBlockId;
  String? skippedNote;
  String? cancelledBlockId;
  Object? cancelBlockThrows;
  String? softDeletedBlockId;
  Object? softDeleteBlockThrows;
  String? restoredBlockId;
  Object? restorePlanBlockThrows;

  final Set<String> deletedPlanBlockIds = {};
  final Map<String, int> planBlockUpdatedAt = {};
  int planBlockByIdUpdatedAt = 1;

  void markPlanBlockDeleted(String blockId, {int? updatedAt}) {
    deletedPlanBlockIds.add(blockId);
    if (updatedAt != null) planBlockUpdatedAt[blockId] = updatedAt;
  }

  @override
  Future<PlanBlockItem> planBlockById(String planBlockId) async {
    if (deletedPlanBlockIds.contains(planBlockId)) {
      throw PlanBlockNotFoundError();
    }
    return PlanBlockItem(
      id: planBlockId,
      taskId: 't1',
      startAt: DateTime(2026, 8, 4, 9),
      endAt: DateTime(2026, 8, 4, 10),
      status: PlanBlockStatus.accepted,
      locked: false,
      createdAt: 1,
      updatedAt: planBlockUpdatedAt[planBlockId] ?? planBlockByIdUpdatedAt,
    );
  }

  @override
  Future<PlanBlockItem> planBlockByIdIncludeDeleted(String planBlockId) async =>
      PlanBlockItem(
        id: planBlockId,
        taskId: 't1',
        startAt: DateTime(2026, 8, 4, 9),
        endAt: DateTime(2026, 8, 4, 10),
        status: PlanBlockStatus.accepted,
        locked: false,
        createdAt: 1,
        updatedAt: planBlockUpdatedAt[planBlockId] ?? planBlockByIdUpdatedAt,
      );

  @override
  Future<void> markPlanBlockDone(String id,
      {required int expectedUpdatedAt, String? note}) async {
    doneBlockId = id;
    doneNote = note;
  }

  @override
  Future<void> markPlanBlockSkipped(String id,
      {required int expectedUpdatedAt, String? note}) async {
    skippedBlockId = id;
    skippedNote = note;
  }

  @override
  Future<void> cancelPlanBlock(String id,
      {required int expectedUpdatedAt}) async {
    final e = cancelBlockThrows;
    if (e != null) throw e;
    cancelledBlockId = id;
  }

  @override
  Future<void> softDeletePlanBlock(String id,
      {required int expectedUpdatedAt}) async {
    final e = softDeleteBlockThrows;
    if (e != null) throw e;
    softDeletedBlockId = id;
    deletedPlanBlockIds.add(id);
  }

  @override
  Future<void> restorePlanBlock(String id,
      {required int expectedUpdatedAt}) async {
    final e = restorePlanBlockThrows;
    if (e != null) throw e;
    restoredBlockId = id;
  }

  // ---- event snapshot（clear_reminder / unlink propose 读取版本） ----
  int eventSnapshotUpdatedAt = 1;

  @override
  Future<EventWriteSnapshot> eventSnapshot(String eventId) async =>
      EventWriteSnapshot(
        id: eventId,
        source: 'user',
        type: 'personal',
        title: '日程',
        allDay: false,
        startAt: DateTime(2026, 8, 4, 9),
        endAt: DateTime(2026, 8, 4, 10),
        updatedAt: eventSnapshotUpdatedAt,
      );

  // ---- reminder（clear_reminder） ----
  List<int> reminderDesiredOffsets = const [15, 30];

  @override
  Future<ReminderConfiguration> reminderConfiguration({
    required String targetType,
    required String targetId,
  }) async =>
      ReminderConfiguration(
        futureDesiredOffsets: reminderDesiredOffsets,
        hasExplicitDisable: false,
        deliveredCount: 0,
        missedCount: 0,
        failedCount: 0,
      );

  ({String targetType, String targetId, String scope, List<int>? offsets,
      int? expectedTargetUpdatedAt, List<int>? expectedOffsetsSnapshot})?
      clearedReminders;
  Object? clearRemindersThrows;

  @override
  Future<void> clearReminders({
    required String targetType,
    required String targetId,
    required String scope,
    List<int>? offsets,
    int? expectedTargetUpdatedAt,
    List<int>? expectedOffsetsSnapshot,
  }) async {
    clearedReminders = (
      targetType: targetType,
      targetId: targetId,
      scope: scope,
      offsets: offsets,
      expectedTargetUpdatedAt: expectedTargetUpdatedAt,
      expectedOffsetsSnapshot: expectedOffsetsSnapshot,
    );
    final e = clearRemindersThrows;
    if (e != null) throw e;
  }

  // ---- overlay（clear_user_overlay） ----
  int? overlayRowUpdatedAt;
  Map<String, Object?> overlayFieldValues = const {};
  String? courseSeriesIdForEventResult;

  @override
  Future<({int? updatedAt, Map<String, Object?> fieldValues})>
      overlayRowSnapshot({
    String? eventId,
    String? courseSeriesId,
  }) async =>
          (updatedAt: overlayRowUpdatedAt, fieldValues: overlayFieldValues);

  ({String? eventId, String? courseSeriesId, List<String> fields,
      int? expectedOverlayUpdatedAt})? clearedOverlayFields;
  Object? clearOverlayFieldsThrows;

  @override
  Future<void> clearOverlayFields({
    String? eventId,
    String? courseSeriesId,
    required List<String> fields,
    int? expectedOverlayUpdatedAt,
  }) async {
    clearedOverlayFields = (
      eventId: eventId,
      courseSeriesId: courseSeriesId,
      fields: fields,
      expectedOverlayUpdatedAt: expectedOverlayUpdatedAt,
    );
    final e = clearOverlayFieldsThrows;
    if (e != null) throw e;
  }

  @override
  Future<String?> courseSeriesIdForEvent(String eventId) async =>
      courseSeriesIdForEventResult;

  // ---- unlink_task_event ----
  ({String taskId, String eventId, int? expectedTaskUpdatedAt,
      int? expectedEventUpdatedAt})? unlinked;
  Object? unlinkThrows;

  @override
  Future<void> unlinkTaskEvent({
    required String taskId,
    required String eventId,
    int? expectedTaskUpdatedAt,
    int? expectedEventUpdatedAt,
  }) async {
    unlinked = (
      taskId: taskId,
      eventId: eventId,
      expectedTaskUpdatedAt: expectedTaskUpdatedAt,
      expectedEventUpdatedAt: expectedEventUpdatedAt,
    );
    final e = unlinkThrows;
    if (e != null) throw e;
  }

  // ---- reset_permission_policy ----
  bool resetPolicyRemoved = true;

  @override
  Future<bool> resetPermissionPolicy({
    required String actionType,
    required String targetType,
  }) async =>
      resetPolicyRemoved;

  // ---- delete_schedule_relation ----
  String? deletedRelationId;
  Object? deleteRelationThrows;
  String? deletedRuleId;
  ({int affectedDays, bool over366Days, bool infinite})? ruleImpact;

  @override
  Future<void> deleteConflictRelation(String relationId) async {
    final e = deleteRelationThrows;
    if (e != null) throw e;
    deletedRelationId = relationId;
  }

  @override
  Future<void> deleteConflictRule(String ruleId) async =>
      deletedRuleId = ruleId;

  @override
  Future<({int affectedDays, bool over366Days, bool infinite})>
      conflictRuleRemovalImpact(String ruleId) async =>
          ruleImpact ?? (affectedDays: 0, over366Days: false, infinite: false);

  // ---- undo_last_action ----
  ({bool available, String summary, String kind, String beijingAt})
      undoPreviewResult = (available: false, summary: '', kind: '', beijingAt: '');
  bool undoCalled = false;
  Object? undoThrows;

  @override
  Future<({bool available, String summary, String kind, String beijingAt})>
      undoPreview() async => undoPreviewResult;

  @override
  Future<void> undoLastAction() async {
    undoCalled = true;
    final e = undoThrows;
    if (e != null) throw e;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// 轻量 harness：持有工具列表 + 共享 ref 存储 + ctx 构造。
class _Harness {
  _Harness(this.tools) : refs = RunReferenceStore(runId: 'r1');
  final List<AgentWriteTool> tools;
  final RunReferenceStore refs;

  AgentToolContext ctx({String accountId = 'a1'}) => AgentToolContext(
        accountId: accountId,
        runId: refs.runId,
        clock: _FixedClock(),
        cancellation: CancellationSignal(),
        references: refs,
      );

  AgentWriteTool tool(String name) => tools.firstWhere((t) => t.name == name);
}

/// 内联课程事件播种 helper（不跨文件 import composition_flow 的私有 helper）。
/// 播种课程系列 + 课程 occurrence + SourceRecords 行（非 user 源事件出现在
/// effective projection 的前提）。
Future<void> _seedCourseEvent(
  AppDatabase db,
  String accountId, {
  required String eventId,
  required String seriesExternalId,
  required String title,
  required DateTime start,
  required DateTime end,
}) async {
  await db.into(db.courseSeries).insert(CourseSeriesCompanion.insert(
        id: 'series-$eventId',
        accountId: accountId,
        source: 'ustc_jw',
        externalId: seriesExternalId,
        title: title,
        semesterKey: '2026spring',
        participantsJson: const Value('[]'),
        sourceDetailsJson: '{}',
        createdAt: 1,
        updatedAt: 1,
      ));
  await db.into(db.calendarEvents).insert(CalendarEventsCompanion.insert(
        id: eventId,
        accountId: accountId,
        source: 'ustc_jw',
        externalId: Value(eventId),
        sourceSeriesExternalId: Value(seriesExternalId),
        title: title,
        type: 'course',
        startAt: Value(start.toUtc().millisecondsSinceEpoch),
        endAt: Value(end.toUtc().millisecondsSinceEpoch),
        allDay: false,
        timezone: 'Asia/Shanghai',
        createdAt: 1,
        updatedAt: 1,
      ));
  await db.into(db.sourceRecords).insert(SourceRecordsCompanion.insert(
        id: 'sr-$eventId',
        accountId: accountId,
        source: 'ustc_jw',
        entityType: 'calendar_event',
        externalId: eventId,
        localEntityId: eventId,
        sourceStatus: 'active',
        presence: 'present',
        scopeKey: 'scope',
        firstObservedAt: 1,
        lastObservedAt: 1,
      ));
}

void main() {
  late AppDatabase db;
  late AgentPermissionPolicyService policy;
  late WriteConfirmationStore store;
  late AgentWriteUnitOfWork unitOfWork;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    // agent_permission_policies.account_id 外键指向 local_accounts，需先播种账户。
    await db.into(db.localAccounts).insert(LocalAccountsCompanion.insert(
          id: 'a1',
          maskedHint: 'PB****0000',
          isActive: const Value(true),
          createdAt: 1,
          updatedAt: 1,
        ));
    policy = AgentPermissionPolicyService(database: db, clock: _FixedClock());
    unitOfWork = DriftAgentWriteUnitOfWork(db);
    store = WriteConfirmationStore(policy: policy, unitOfWork: unitOfWork);
  });

  tearDown(() => db.close());

  /// 装配全部写工具（用共享 gateway 占位；测试时通过 attachGateway 换入专属 fake）。
  List<AgentWriteTool> tools(AgentWriteGateway gateway) => [
        CreateEventTool(
            gateway: gateway,
            policy: policy,
            confirmationStore: store,
            unitOfWork: unitOfWork),
        CreateTaskTool(
            gateway: gateway,
            policy: policy,
            confirmationStore: store,
            unitOfWork: unitOfWork),
        PlanTaskTool(
            gateway: gateway,
            policy: policy,
            confirmationStore: store,
            unitOfWork: unitOfWork),
        UpdateEventTool(
            gateway: gateway,
            policy: policy,
            confirmationStore: store,
            unitOfWork: unitOfWork),
        CreateUserOverlayTool(
            gateway: gateway,
            policy: policy,
            confirmationStore: store,
            unitOfWork: unitOfWork),
        RecordAttendanceDecisionTool(
            gateway: gateway,
            policy: policy,
            confirmationStore: store,
            unitOfWork: unitOfWork),
        RecordListeningModeTool(
            gateway: gateway,
            policy: policy,
            confirmationStore: store,
            unitOfWork: unitOfWork),
        CreateScheduleRelationTool(
            gateway: gateway,
            policy: policy,
            confirmationStore: store,
            unitOfWork: unitOfWork),
        SetReminderTool(
            gateway: gateway,
            policy: policy,
            confirmationStore: store,
            unitOfWork: unitOfWork),
        MoveJwCourseDayTool(
            gateway: gateway,
            policy: policy,
            confirmationStore: store,
            unitOfWork: unitOfWork),
        UpdatePermissionPolicyTool(
            gateway: gateway,
            policy: policy,
            confirmationStore: store,
            unitOfWork: unitOfWork),
        ...agentLifecycleTools(gateway, policy, store, unitOfWork),
      ];

  // ===========================================================================
  // Group A: update_task 生命周期（4）
  // ===========================================================================

  group('A: update_task lifecycle', () {
    test('1. update_task delete 软删除后 restore 复原；deletedAt 翻转', () async {
      // 契约：删除是软删除（可恢复），不是物理删除。softDeleteTask 设标记，
      // restoreTask 清标记——模拟真实 TaskLifecycleService 的软删除/恢复语义。
      final h = _Harness(tools(_LifecycleGateway()));
      final tool = h.tool('update_task') as UpdateTaskTool;
      final gw = _LifecycleGateway();
      tool.attachGateway(gw);
      final ref = h.refs.bind(kind: 'task', localId: 't1');

      // delete：软删除
      final del = await tool.execute(
          {'ref_task': ref, 'action': 'delete'}, h.ctx());
      expect(del.status, AgentToolStatus.needsUserAction);
      final delCommit =
          await store.resolve(del.userAction!.opaqueHandle, approve: true, remember: false);
      expect(delCommit.status, AgentToolStatus.success);
      expect(gw.softDeletedTaskId, 't1');
      expect(gw.deletedTaskIds.contains('t1'), isTrue,
          reason: '软删除后 taskById 应过滤该任务（标记翻转）');

      // restore：恢复（走 taskByIdIncludeDeleted 查找已软删除行）
      final restore = await tool.execute(
          {'ref_task': ref, 'action': 'restore'}, h.ctx());
      expect(restore.status, AgentToolStatus.needsUserAction);
      final restoreCommit = await store.resolve(
          restore.userAction!.opaqueHandle, approve: true, remember: false);
      expect(restoreCommit.status, AgentToolStatus.success);
      expect(gw.restoredTaskId, 't1');
      expect(gw.deletedTaskIds.contains('t1'), isFalse,
          reason: '恢复后软删除标记应清除');
    });

    test('2. update_task complete 映射到 completeTask 调用', () async {
      // 契约：5 个动作各路由到正确 gateway 方法；complete→completeTask。
      final h = _Harness(tools(_LifecycleGateway()));
      final tool = h.tool('update_task') as UpdateTaskTool;
      final gw = _LifecycleGateway();
      tool.attachGateway(gw);
      final ref = h.refs.bind(kind: 'task', localId: 't1');
      final result =
          await tool.execute({'ref_task': ref, 'action': 'complete'}, h.ctx());
      expect(result.status, AgentToolStatus.needsUserAction);
      final commit = await store.resolve(
          result.userAction!.opaqueHandle, approve: true, remember: false);
      expect(commit.status, AgentToolStatus.success);
      expect(gw.completedTaskId, 't1');
      expect(commit.payload['action'], 'complete');
    });

    test('3. update_task reject unknown action 返回 invalid_write_arguments',
        () async {
      // 契约：WriteArgumentReader.requiredEnum 在 propose 即拒绝非法枚举，
      // 未进入审批门。
      final h = _Harness(tools(_LifecycleGateway()));
      final tool = h.tool('update_task');
      final ref = h.refs.bind(kind: 'task', localId: 't1');
      final result =
          await tool.execute({'ref_task': ref, 'action': 'bogus'}, h.ctx());
      expect(result.status, AgentToolStatus.error);
      expect(result.errorCode, 'invalid_write_arguments');
      expect(result.userAction, isNull, reason: 'propose 拒绝不产审批卡');
    });

    test('4. update_task cancel 需要确认（高风险）后映射到 cancelTask', () async {
      // 契约：cancel/delete 是 high 风险，审批门不跳过（rememberAllowed 默认 true
      // 但仍需首确认）。cancel 必须先返回 needsUserAction，批准后路由到 cancelTask。
      final h = _Harness(tools(_LifecycleGateway()));
      final tool = h.tool('update_task') as UpdateTaskTool;
      final gw = _LifecycleGateway();
      tool.attachGateway(gw);
      final ref = h.refs.bind(kind: 'task', localId: 't1');
      final result =
          await tool.execute({'ref_task': ref, 'action': 'cancel'}, h.ctx());
      expect(result.status, AgentToolStatus.needsUserAction,
          reason: 'cancel 是 high 风险，审批门不跳过');
      final commit = await store.resolve(
          result.userAction!.opaqueHandle, approve: true, remember: false);
      expect(commit.status, AgentToolStatus.success);
      expect(gw.cancelledTaskId, 't1');
    });
  });

  // ===========================================================================
  // Group B: update_plan_block 生命周期（3）
  // ===========================================================================

  group('B: update_plan_block lifecycle', () {
    test('5. update_plan_block delete 不级联父任务', () async {
      // 契约：块删除是独立软删除，不级联删除父任务。fake 的 taskById 仍返回
      // active task；softDeletePlanBlock 只标记块，不被调任何 task 删除方法。
      final h = _Harness(tools(_LifecycleGateway()));
      final tool = h.tool('update_plan_block') as UpdatePlanBlockTool;
      final gw = _LifecycleGateway();
      tool.attachGateway(gw);
      final ref = h.refs.bind(kind: 'planblock', localId: 'pb1');
      final result = await tool.execute(
          {'ref_plan_block': ref, 'action': 'delete'}, h.ctx());
      expect(result.status, AgentToolStatus.needsUserAction);
      final commit = await store.resolve(
          result.userAction!.opaqueHandle, approve: true, remember: false);
      expect(commit.status, AgentToolStatus.success);
      expect(gw.softDeletedBlockId, 'pb1');
      expect(gw.deletedPlanBlockIds.contains('pb1'), isTrue);
      // 块删除绝不级联：未调任何 task 删除方法。
      expect(gw.softDeletedTaskId, isNull);
      expect(gw.cancelledTaskId, isNull);
    });

    test('6. update_plan_block cancel+note 拒绝且不产审批卡', () async {
      // 契约：note 字段约束在 propose 即校验（仅 done/skip 可用），cancel+note
      // 拒绝为 invalid_write_arguments 且 result.userAction == null（propose 拒绝，
      // 从不进入审批门——无 opaqueHandle 产生）。现有 write_tools_test 只断言 error
      // 码；本测试额外锁定"无审批卡"。
      final h = _Harness(tools(_LifecycleGateway()));
      final tool = h.tool('update_plan_block');
      final ref = h.refs.bind(kind: 'planblock', localId: 'pb1');
      final result = await tool.execute(
          {'ref_plan_block': ref, 'action': 'cancel', 'note': 'x'}, h.ctx());
      expect(result.status, AgentToolStatus.error);
      expect(result.errorCode, 'invalid_write_arguments');
      expect(result.userAction, isNull,
          reason: 'propose 拒绝不产生可确认的副作用入口（无审批卡）');
    });

    test('7. update_plan_block restore 未删除块映射 already_active', () async {
      // 契约：restore 未删除块抛 NotDeletedError → 确定性错误码 already_active
      // （不外泄内部文本）。
      final h = _Harness(tools(_LifecycleGateway()));
      final tool = h.tool('update_plan_block') as UpdatePlanBlockTool;
      final gw = _LifecycleGateway();
      gw.restorePlanBlockThrows = const NotDeletedError();
      tool.attachGateway(gw);
      final ref = h.refs.bind(kind: 'planblock', localId: 'pb1');
      final result = await tool.execute(
          {'ref_plan_block': ref, 'action': 'restore'}, h.ctx());
      expect(result.status, AgentToolStatus.needsUserAction);
      final commit = await store.resolve(
          result.userAction!.opaqueHandle, approve: true, remember: false);
      expect(commit.status, AgentToolStatus.error);
      expect(commit.errorCode, 'already_active');
    });
  });

  // ===========================================================================
  // Group C: delete_schedule_relation（2）
  // ===========================================================================

  group('C: delete_schedule_relation', () {
    test('8. delete_schedule_relation 单次关系物理删除', () async {
      // 契约：单次关系是物理删除（非软删除）。
      final h = _Harness(tools(_LifecycleGateway()));
      final tool =
          h.tool('delete_schedule_relation') as DeleteScheduleRelationTool;
      final gw = _LifecycleGateway();
      tool.attachGateway(gw);
      final ref = h.refs.bind(kind: 'schedule_relation', localId: 'rel-1');
      final result = await tool.execute({'ref_relation': ref}, h.ctx());
      expect(result.status, AgentToolStatus.needsUserAction);
      final commit = await store.resolve(
          result.userAction!.opaqueHandle, approve: true, remember: false);
      expect(commit.status, AgentToolStatus.success);
      expect(gw.deletedRelationId, 'rel-1');
      expect(commit.payload['result'], 'deleted_schedule_relation');
    });

    test('9. delete_schedule_relation 学校来源 relation_not_deletable + guidance',
        () async {
      // 契约：学校来源关系不可删除；服务层抛 ConflictNotDeletableError →
      // relation_not_deletable，payload 带 guidance（用户可读说明）。
      final h = _Harness(tools(_LifecycleGateway()));
      final tool =
          h.tool('delete_schedule_relation') as DeleteScheduleRelationTool;
      final gw = _LifecycleGateway();
      gw.deleteRelationThrows = const ConflictNotDeletableError('derived_overlap');
      tool.attachGateway(gw);
      final ref = h.refs.bind(kind: 'schedule_relation', localId: 'rel-1');
      final result = await tool.execute({'ref_relation': ref}, h.ctx());
      expect(result.status, AgentToolStatus.needsUserAction);
      final commit = await store.resolve(
          result.userAction!.opaqueHandle, approve: true, remember: false);
      expect(commit.status, AgentToolStatus.error);
      expect(commit.errorCode, 'relation_not_deletable');
      final guidance = commit.payload['guidance'];
      expect(guidance, isA<String>());
      expect((guidance as String).isNotEmpty, isTrue,
          reason: 'guidance 非空（含中文说明）');
    });
  });

  // ===========================================================================
  // Group D: clear_reminder no-op 语义（2）⭐ 关键 code-truth
  // ===========================================================================

  group('D: clear_reminder', () {
    test('10. clear_reminder 对学校课程事件是 no-op（无 source guard）⭐', () async {
      // ⭐ 关键 code-truth：clear_reminder 无 source guard。对学校事件 propose→approve
      // 通过（不拒绝），但学校事件永远没有 reminder 行——因为 set_reminder 有 source
      // guard（propose + commit 双检 isPersonal），拒绝为学校事件创建 reminder。
      // 因此 clear_reminder 对学校事件是合法但空操作：无可清的 desired-offset 行。
      //
      // 个人-only 提醒由**系统提示词**约束（set_reminder 有 source guard 拒绝学校事件→
      // 学校事件永远无 reminder 行→clear 无可清）。M4 固化的是**工具行为真相**：
      // clear_reminder 不拒绝学校事件，而是 no-op；拒绝职责在 set_reminder + 提示词。
      final realDb = AppDatabase(NativeDatabase.memory());
      addTearDown(realDb.close);
      await realDb.into(realDb.localAccounts).insert(LocalAccountsCompanion.insert(
            id: 'acc-1',
            maskedHint: 'x',
            isActive: const Value(true),
            createdAt: 1,
            updatedAt: 1,
          ));
      final realPolicy =
          AgentPermissionPolicyService(database: realDb, clock: _FixedClock());
      final realGateway = DriftAgentWriteGateway(
          database: realDb, accountId: 'acc-1', policy: realPolicy);
      final realUnitOfWork = DriftAgentWriteUnitOfWork(realDb);
      final realStore =
          WriteConfirmationStore(policy: realPolicy, unitOfWork: realUnitOfWork);
      final tool = ClearReminderTool(
          gateway: realGateway,
          policy: realPolicy,
          confirmationStore: realStore,
          unitOfWork: realUnitOfWork);

      await _seedCourseEvent(realDb, 'acc-1',
          eventId: 'course-1',
          seriesExternalId: 'lesson-1',
          title: '线性代数',
          start: DateTime(2026, 8, 4, 8),
          end: DateTime(2026, 8, 4, 9, 40));

      final refs = RunReferenceStore(runId: 'r1');
      final ref = refs.bind(kind: 'event', localId: 'course-1');
      final ctx = AgentToolContext(
        accountId: 'acc-1',
        runId: 'r1',
        clock: _FixedClock(),
        cancellation: CancellationSignal(),
        references: refs,
      );

      final result = await tool.execute(
          {'ref_target': ref, 'scope': 'all'}, ctx);
      // 无 source guard：propose 通过 → needsUserAction（或 allow 直接提交）。
      // clear_all_reminders 是 high 风险 → 默认 ask_first_time → 需确认。
      expect(result.status, AgentToolStatus.needsUserAction,
          reason: 'clear_reminder 无 source guard，propose 应通过进入审批门');
      final commit = await realStore.resolve(
          result.userAction!.opaqueHandle, approve: true, remember: false);
      expect(commit.status, AgentToolStatus.success,
          reason: '对学校事件 clear 是合法 no-op，commit 成功');

      // 断言：学校事件无 desired-offset reminder 行（set_reminder 的 source guard
      // 保证学校事件永远不会被设提醒→无 reminder 行可清）。clear 可能写一个 disabled
      // sentinel（state='cancelled', offsetMinutes=null），那是实现细节；重点是
      // 无活跃/期望偏移提醒被创建或清除——学校事件的提醒状态保持"无提醒"。
      final reminderRows =
          await (realDb.select(realDb.reminders)
                ..where((r) => r.targetId.equals('course-1')))
              .get();
      final desiredRows = reminderRows
          .where((r) => r.state == 'desired' && r.offsetMinutes != null)
          .toList();
      expect(desiredRows, isEmpty,
          reason: '学校课程事件永远没有 desired-offset reminder 行');
    });

    test('11. clear_reminder selected_offsets 捕获 offset+版本快照（TOCTOU）',
        () async {
      // 契约：I2 TOCTOU 快照在 propose 捕获 target 版本 + 当前 desired offsets，
      // commit 透传到 clearReminders 重检。
      final h = _Harness(tools(_LifecycleGateway()));
      final tool = h.tool('clear_reminder') as ClearReminderTool;
      final gw = _LifecycleGateway();
      gw.reminderDesiredOffsets = const [15, 30];
      tool.attachGateway(gw);
      final ref = h.refs.bind(kind: 'event', localId: 'ev1');
      final result = await tool.execute({
        'ref_target': ref,
        'scope': 'selected_offsets',
        'offsets_minutes': [15, 30],
      }, h.ctx());
      expect(result.status, AgentToolStatus.needsUserAction);
      final commit = await store.resolve(
          result.userAction!.opaqueHandle, approve: true, remember: false);
      expect(commit.status, AgentToolStatus.success);
      expect(gw.clearedReminders, isNot(isNull));
      // I2: target 版本 + offset 快照透传到 clearReminders。
      expect(gw.clearedReminders!.expectedTargetUpdatedAt, isNot(isNull));
      expect(gw.clearedReminders!.expectedOffsetsSnapshot, isNot(isNull));
      expect(gw.clearedReminders!.expectedOffsetsSnapshot, [15, 30]);
    });
  });

  // ===========================================================================
  // Group E: clear_user_overlay（2）
  // ===========================================================================

  group('E: clear_user_overlay', () {
    test('12. clear_user_overlay course_series 无 series target_not_found + guidance',
        () async {
      // 契约：course_series scope 在无 series 时的确定性拒绝——commit 阶段
      // courseSeriesIdForEvent 返回 null → target_not_found + guidance。
      final h = _Harness(tools(_LifecycleGateway()));
      final tool = h.tool('clear_user_overlay') as ClearUserOverlayTool;
      final gw = _LifecycleGateway();
      gw.courseSeriesIdForEventResult = null; // 无 series
      tool.attachGateway(gw);
      final ref = h.refs.bind(kind: 'event', localId: 'ev1');
      final result = await tool.execute({
        'ref_event': ref,
        'scope': 'course_series',
        'fields': ['attendance'],
      }, h.ctx());
      expect(result.status, AgentToolStatus.needsUserAction);
      final commit = await store.resolve(
          result.userAction!.opaqueHandle, approve: true, remember: false);
      expect(commit.status, AgentToolStatus.error);
      expect(commit.errorCode, 'target_not_found');
      final guidance = commit.payload['guidance'];
      expect(guidance, isA<String>());
      expect((guidance as String).isNotEmpty, isTrue);
    });

    test('13. clear_user_overlay invalid field 抛 ArgumentError（无 registry 兜底）',
        () async {
      // 契约：非法字段名在 propose 即失败，但因 OverlayFieldKeys.expand 抛
      // ArgumentError（非 FormatException），基类 execute 只 catch
      // FormatException/CalendarValidationError，ArgumentError 未捕获→直接抛出。
      // M4 harness 调 tool.execute 直连、不经 AgentToolRegistry，故无
      // tool_execution_failed 兜底，表现为抛异常而非返回 error 结果。
      // （M4 §0.2 禁止改 lib，固化的是现状行为；22 个测试中唯一断言抛异常的用例。）
      final h = _Harness(tools(_LifecycleGateway()));
      final tool = h.tool('clear_user_overlay') as ClearUserOverlayTool;
      final gw = _LifecycleGateway();
      tool.attachGateway(gw);
      final ref = h.refs.bind(kind: 'event', localId: 'ev1');
      expect(
        () => tool.execute({
          'ref_event': ref,
          'scope': 'single_event',
          'fields': ['bogus_field'],
        }, h.ctx()),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  // ===========================================================================
  // Group F: unlink_task_event（2）
  // ===========================================================================

  group('F: unlink_task_event', () {
    test('14. unlink_task_event 物理删除 + 版本快照透传', () async {
      // 契约：唯一 (task,event) 关联物理删除 + I2 TOCTOU 版本快照（task+event 各自
      // updatedAt 在 propose 捕获、commit 透传）。
      final h = _Harness(tools(_LifecycleGateway()));
      final tool = h.tool('unlink_task_event') as UnlinkTaskEventTool;
      final gw = _LifecycleGateway();
      tool.attachGateway(gw);
      final taskRef = h.refs.bind(kind: 'task', localId: 't1');
      final eventRef = h.refs.bind(kind: 'event', localId: 'ev1');
      final result = await tool.execute(
          {'ref_task': taskRef, 'ref_event': eventRef}, h.ctx());
      expect(result.status, AgentToolStatus.needsUserAction);
      final commit = await store.resolve(
          result.userAction!.opaqueHandle, approve: true, remember: false);
      expect(commit.status, AgentToolStatus.success);
      expect(gw.unlinked, isNot(isNull));
      expect(gw.unlinked!.taskId, 't1');
      expect(gw.unlinked!.eventId, 'ev1');
      expect(gw.unlinked!.expectedTaskUpdatedAt, isNot(isNull));
      expect(gw.unlinked!.expectedEventUpdatedAt, isNot(isNull));
    });

    test('15. unlink_task_event StaleTaskEventLinkCommand → stale_target', () async {
      // 契约：版本不匹配的确定性错误码——commit 抛 StaleTaskEventLinkCommand →
      // stale_target。
      final h = _Harness(tools(_LifecycleGateway()));
      final tool = h.tool('unlink_task_event') as UnlinkTaskEventTool;
      final gw = _LifecycleGateway();
      gw.unlinkThrows = const StaleTaskEventLinkCommand();
      tool.attachGateway(gw);
      final taskRef = h.refs.bind(kind: 'task', localId: 't1');
      final eventRef = h.refs.bind(kind: 'event', localId: 'ev1');
      final result = await tool.execute(
          {'ref_task': taskRef, 'ref_event': eventRef}, h.ctx());
      final commit = await store.resolve(
          result.userAction!.opaqueHandle, approve: true, remember: false);
      expect(commit.status, AgentToolStatus.error);
      expect(commit.errorCode, 'stale_target');
    });
  });

  // ===========================================================================
  // Group G: reset_permission_policy（3）
  // ===========================================================================

  group('G: reset_permission_policy', () {
    test('16. reset_permission_policy 无覆盖返回 already_default', () async {
      // 契约：幂等性——重置已默认策略是成功但无副作用。critical + forceConfirmation
      // → needsUserAction；approve 后 success + payload['result'] == 'already_default'。
      final h = _Harness(tools(_LifecycleGateway()));
      final tool =
          h.tool('reset_permission_policy') as ResetPermissionPolicyTool;
      final gw = _LifecycleGateway();
      gw.resetPolicyRemoved = false; // 无覆盖行
      tool.attachGateway(gw);
      final result = await tool.execute(
          {'target_action_type': 'event_delete'}, h.ctx());
      expect(result.status, AgentToolStatus.needsUserAction,
          reason: 'critical + forceConfirmation → 需确认');
      final commit = await store.resolve(
          result.userAction!.opaqueHandle, approve: true, remember: false);
      expect(commit.status, AgentToolStatus.success);
      expect(commit.payload['result'], 'already_default');
    });

    test('17. reset_permission_policy 非可重置动作（自身）拒绝', () async {
      // 契约：kNonResetableActions 自我保护——reset_permission_policy 不可重置自身。
      final h = _Harness(tools(_LifecycleGateway()));
      final tool = h.tool('reset_permission_policy');
      final result = await tool.execute(
          {'target_action_type': 'reset_permission_policy'}, h.ctx());
      expect(result.status, AgentToolStatus.error);
      expect(result.errorCode, 'invalid_write_arguments');
      expect(result.userAction, isNull);
    });

    test('18. reset_permission_policy unknown action 拒绝', () async {
      // 契约：动作键必须已注册（kPermissionActions）。
      final h = _Harness(tools(_LifecycleGateway()));
      final tool = h.tool('reset_permission_policy');
      final result =
          await tool.execute({'target_action_type': 'bogus'}, h.ctx());
      expect(result.status, AgentToolStatus.error);
      expect(result.errorCode, 'invalid_write_arguments');
      expect(result.userAction, isNull);
    });
  });

  // ===========================================================================
  // Group H: undo_last_action（2）
  // ===========================================================================

  group('H: undo_last_action', () {
    test('19. undo_last_action 一步消费槽（success 后 preview 翻转为 unavailable）',
        () async {
      // 契约：一步撤回消费语义——消费后槽清空，不可连续撤回更早操作。fake 的
      // undoLastAction 设 undoCalled 并把 undoPreviewResult.available 翻为 false
      // （模拟真实 UndoService 消费后清槽）。
      final h = _Harness(tools(_LifecycleGateway()));
      final tool = h.tool('undo_last_action') as UndoLastActionTool;
      final gw = _LifecycleGateway();
      gw.undoPreviewResult = (
        available: true,
        summary: '删除日程 健身',
        kind: 'calendar_event_delete',
        beijingAt: '2026-08-04T15:00',
      );
      tool.attachGateway(gw);
      final result = await tool.execute({}, h.ctx());
      expect(result.status, AgentToolStatus.needsUserAction);
      final commit = await store.resolve(
          result.userAction!.opaqueHandle, approve: true, remember: false);
      expect(commit.status, AgentToolStatus.success);
      expect(gw.undoCalled, isTrue);
      // 消费后槽清空：undoLastAction 翻转 preview.available = false。
      gw.undoCalled = false;
      gw.undoPreviewResult = (
        available: false,
        summary: '',
        kind: '',
        beijingAt: '',
      );
      final again = await tool.execute({}, h.ctx());
      expect(again.status, AgentToolStatus.error);
      expect(again.errorCode, 'invalid_write_arguments',
          reason: '槽已清空，无 undoable action');
      expect(gw.undoCalled, isFalse, reason: '无槽时不应调 undoLastAction');
    });

    test('20. undo_last_action 无槽返回 invalid_write_arguments', () async {
      // 契约：无可撤回操作的确定性拒绝——propose 阶段 preview.available = false
      // 抛 FormatException → 基类映射 invalid_write_arguments（不进审批门）。
      final h = _Harness(tools(_LifecycleGateway()));
      final tool = h.tool('undo_last_action') as UndoLastActionTool;
      final gw = _LifecycleGateway();
      gw.undoPreviewResult = (
        available: false,
        summary: '',
        kind: '',
        beijingAt: '',
      );
      tool.attachGateway(gw);
      final result = await tool.execute({}, h.ctx());
      expect(result.status, AgentToolStatus.error);
      expect(result.errorCode, 'invalid_write_arguments');
      expect(result.userAction, isNull);
    });
  });

  // ===========================================================================
  // Group I: update_event 学校事件拒绝删除（2，真实 DB）
  // ===========================================================================

  group('I: update_event 学校事件拒绝删除（真实 DB）', () {
    test('21. update_event delete 对学校课程事件在 propose 即拒绝；行不被删除 ⭐',
        () async {
      // ⭐ 契约：学校课程事件删除是 code-enforced 拒绝（propose 即拒，非 commit/非
      // 服务层）。UpdateEventTool.propose 检 !snapshot.isPersonal 抛 FormatException →
      // 基类映射 invalid_write_arguments。错误码是 invalid_write_arguments（非
      // source_event_not_editable——后者仅在 propose→commit source 翻转 TOCTOU 时
      // 可达）。事件行 deletedAt == null 且 status == 'active'（从未被碰，未进审批门）。
      final realDb = AppDatabase(NativeDatabase.memory());
      addTearDown(realDb.close);
      await realDb.into(realDb.localAccounts).insert(LocalAccountsCompanion.insert(
            id: 'acc-1',
            maskedHint: 'x',
            isActive: const Value(true),
            createdAt: 1,
            updatedAt: 1,
          ));
      final realPolicy =
          AgentPermissionPolicyService(database: realDb, clock: _FixedClock());
      final realGateway = DriftAgentWriteGateway(
          database: realDb, accountId: 'acc-1', policy: realPolicy);
      final realUnitOfWork = DriftAgentWriteUnitOfWork(realDb);
      final realStore =
          WriteConfirmationStore(policy: realPolicy, unitOfWork: realUnitOfWork);
      final tool = UpdateEventTool(
          gateway: realGateway,
          policy: realPolicy,
          confirmationStore: realStore,
          unitOfWork: realUnitOfWork);

      // 允许 event_delete 策略（让 approve 后能直接 commit，不停在确认卡）。
      await realDb.into(realDb.agentPermissionPolicies).insert(
            AgentPermissionPoliciesCompanion.insert(
              id: 'pp-1',
              accountId: 'acc-1',
              actionType: 'event_delete',
              targetType: const Value('event'),
              confirmationMode: 'always_allow',
              riskLevel: const Value('high'),
              enabled: const Value(true),
              createdAt: 1,
              updatedAt: 1,
            ),
          );

      await _seedCourseEvent(realDb, 'acc-1',
          eventId: 'course-del',
          seriesExternalId: 'lesson-del',
          title: '线性代数',
          start: DateTime(2026, 8, 4, 8),
          end: DateTime(2026, 8, 4, 9, 40));

      final refs = RunReferenceStore(runId: 'r1');
      final ref = refs.bind(kind: 'event', localId: 'course-del');
      final ctx = AgentToolContext(
        accountId: 'acc-1',
        runId: 'r1',
        clock: _FixedClock(),
        cancellation: CancellationSignal(),
        references: refs,
      );

      final del = await tool.execute(
          {'ref_event': ref, 'action': 'delete'}, ctx);
      expect(del.status, AgentToolStatus.error);
      expect(del.errorCode, 'invalid_write_arguments',
          reason: '学校课程事件删除在 propose 即拒（source guard），'
              '错误码是 invalid_write_arguments 而非 source_event_not_editable');
      expect(del.userAction, isNull, reason: 'propose 拒绝不进审批门');

      // 事件行从未被碰：deletedAt 仍为 null，status 仍为 active。
      final row = await (realDb.select(realDb.calendarEvents)
            ..where((r) => r.id.equals('course-del')))
          .getSingle();
      expect(row.deletedAt, isNull);
      expect(row.status, 'active');
    });

    test('22. update_event delete 对个人事件成功软删除（对照）', () async {
      // 契约：个人事件可删除（与学校事件拒绝形成对照，证明拒绝是 source 特异）。
      final realDb = AppDatabase(NativeDatabase.memory());
      addTearDown(realDb.close);
      await realDb.into(realDb.localAccounts).insert(LocalAccountsCompanion.insert(
            id: 'acc-1',
            maskedHint: 'x',
            isActive: const Value(true),
            createdAt: 1,
            updatedAt: 1,
          ));
      final realPolicy =
          AgentPermissionPolicyService(database: realDb, clock: _FixedClock());
      final realGateway = DriftAgentWriteGateway(
          database: realDb, accountId: 'acc-1', policy: realPolicy);
      final realUnitOfWork = DriftAgentWriteUnitOfWork(realDb);
      final realStore =
          WriteConfirmationStore(policy: realPolicy, unitOfWork: realUnitOfWork);
      final tool = UpdateEventTool(
          gateway: realGateway,
          policy: realPolicy,
          confirmationStore: realStore,
          unitOfWork: realUnitOfWork);

      await realDb.into(realDb.agentPermissionPolicies).insert(
            AgentPermissionPoliciesCompanion.insert(
              id: 'pp-1',
              accountId: 'acc-1',
              actionType: 'event_delete',
              targetType: const Value('event'),
              confirmationMode: 'always_allow',
              riskLevel: const Value('high'),
              enabled: const Value(true),
              createdAt: 1,
              updatedAt: 1,
            ),
          );

      // 个人事件（source='user'）。
      await realDb.into(realDb.calendarEvents).insert(
            CalendarEventsCompanion.insert(
              id: 'personal-1',
              accountId: 'acc-1',
              source: 'user',
              title: '健身',
              type: 'personal',
              startAt: Value(DateTime(2026, 8, 4, 15).toUtc().millisecondsSinceEpoch),
              endAt: Value(DateTime(2026, 8, 4, 16).toUtc().millisecondsSinceEpoch),
              allDay: false,
              timezone: 'Asia/Shanghai',
              createdAt: 1,
              updatedAt: 1,
            ),
          );

      final refs = RunReferenceStore(runId: 'r1');
      final ref = refs.bind(kind: 'event', localId: 'personal-1');
      final ctx = AgentToolContext(
        accountId: 'acc-1',
        runId: 'r1',
        clock: _FixedClock(),
        cancellation: CancellationSignal(),
        references: refs,
      );

      final del = await tool.execute(
          {'ref_event': ref, 'action': 'delete'}, ctx);
      // always_allow 策略 → 直接提交（不走确认卡）。
      expect(del.status, AgentToolStatus.success);
      final row = await (realDb.select(realDb.calendarEvents)
            ..where((r) => r.id.equals('personal-1')))
          .getSingle();
      expect(row.deletedAt, isNotNull,
          reason: '个人事件软删除后 deletedAt 非空');
    });
  });
}
