import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../../core/time/beijing_clock.dart';
import '../domain/agent_permission_policy.dart';

/// 单一动作注册表中的一条：动作键、target、默认风险、默认模式、是否允许在设置页
/// 放宽、中文标签。所有写工具 allowlist、设置页、`update_permission_policy` 与
/// [AgentPermissionPolicyService] 的默认值查询都消费同一份 [kPermissionActions]，
/// 不再维护平行 enum/list。
class AgentPermissionAction {
  const AgentPermissionAction({
    required this.key,
    required this.targetType,
    required this.defaultMode,
    required this.defaultRisk,
    required this.relaxable,
    required this.label,
  });

  final String key;
  final String targetType;
  final ConfirmationMode defaultMode;
  final RiskLevel defaultRisk;

  /// 该动作是否允许在设置页/`update_permission_policy` 被放宽。
  /// critical 动作（update_permission_policy、reset_permission_policy、
  /// move_jw_course_day）恒为 false，不能自动允许。
  final bool relaxable;
  final String label;
}

/// 写操作确认策略的查询、决议与变更。
///
/// 默认策略按数据模型 §10.5 与设计 §17.2/§17.3 映射惰性生效（无行时用默认值，
/// 不物理播种）。任何权限变更写 `ActionLog`。
class AgentPermissionPolicyService {
  AgentPermissionPolicyService({required this.database, required this.clock});

  final AppDatabase database;
  final BeijingClock clock;
  static const _uuid = Uuid();

  /// 唯一动作注册表（设计 §17.3 动作键 + 现有 11 个写工具动作 + 兼容/预留键）。
  /// target、默认风险、默认模式、是否可放宽、中文标签都只在这里定义一份。
  static const Map<String, AgentPermissionAction> kPermissionActions = {
    // ---- 现有写工具动作（§17.2 映射等价） ----
    'create_event': AgentPermissionAction(
        key: 'create_event',
        targetType: 'event',
        defaultMode: ConfirmationMode.askFirstTime,
        defaultRisk: RiskLevel.medium,
        relaxable: true,
        label: '新建日程'),
    'event_edit': AgentPermissionAction(
        key: 'event_edit',
        targetType: 'event',
        defaultMode: ConfirmationMode.alwaysAsk,
        defaultRisk: RiskLevel.high,
        relaxable: true,
        label: '修改/删除日程'),
    'create_task': AgentPermissionAction(
        key: 'create_task',
        targetType: 'task',
        defaultMode: ConfirmationMode.askFirstTime,
        defaultRisk: RiskLevel.medium,
        relaxable: true,
        label: '新建任务'),
    'plan_task': AgentPermissionAction(
        key: 'plan_task',
        targetType: 'plan_block',
        defaultMode: ConfirmationMode.askFirstTime,
        defaultRisk: RiskLevel.medium,
        relaxable: true,
        label: '安排任务时间段'),
    'create_user_overlay': AgentPermissionAction(
        key: 'create_user_overlay',
        targetType: 'overlay',
        defaultMode: ConfirmationMode.askFirstTime,
        defaultRisk: RiskLevel.medium,
        relaxable: true,
        label: '设置个人标注'),
    'record_attendance_decision': AgentPermissionAction(
        key: 'record_attendance_decision',
        targetType: 'event',
        defaultMode: ConfirmationMode.askFirstTime,
        defaultRisk: RiskLevel.medium,
        relaxable: true,
        label: '记录出勤决定'),
    'record_listening_mode': AgentPermissionAction(
        key: 'record_listening_mode',
        targetType: 'event',
        defaultMode: ConfirmationMode.askFirstTime,
        defaultRisk: RiskLevel.medium,
        relaxable: true,
        label: '设置听讲模式'),
    'create_schedule_relation': AgentPermissionAction(
        key: 'create_schedule_relation',
        targetType: 'relation',
        defaultMode: ConfirmationMode.askFirstTime,
        defaultRisk: RiskLevel.medium,
        relaxable: true,
        label: '记录日程关系'),
    'set_reminder': AgentPermissionAction(
        key: 'set_reminder',
        targetType: 'event',
        defaultMode: ConfirmationMode.askFirstTime,
        defaultRisk: RiskLevel.medium,
        relaxable: true,
        label: '设置提醒'),
    // ---- critical 动作：永远人工确认，不可放宽 ----
    'update_permission_policy': AgentPermissionAction(
        key: 'update_permission_policy',
        targetType: 'permission',
        defaultMode: ConfirmationMode.alwaysAsk,
        defaultRisk: RiskLevel.critical,
        relaxable: false,
        label: '调整确认策略'),
    'move_jw_course_day': AgentPermissionAction(
        key: 'move_jw_course_day',
        targetType: 'jw_day_move',
        defaultMode: ConfirmationMode.alwaysAsk,
        defaultRisk: RiskLevel.critical,
        relaxable: false,
        label: '整日移动教务课程'),
    // ---- 兼容/预留 ----
    'update_event': AgentPermissionAction(
        key: 'update_event',
        targetType: 'event',
        defaultMode: ConfirmationMode.alwaysAsk,
        defaultRisk: RiskLevel.high,
        relaxable: false,
        label: '修改/删除日程'),
    'move_plan_block': AgentPermissionAction(
        key: 'move_plan_block',
        targetType: 'plan_block',
        defaultMode: ConfirmationMode.alwaysAsk,
        defaultRisk: RiskLevel.medium,
        relaxable: true,
        label: '移动计划块'),
    // ---- Spec §17.3 新动作键（供后续 Task 工具使用；本轮先注册） ----
    'event_cancel': AgentPermissionAction(
        key: 'event_cancel',
        targetType: 'event',
        defaultMode: ConfirmationMode.alwaysAsk,
        defaultRisk: RiskLevel.high,
        relaxable: true,
        label: '取消日程'),
    'event_delete': AgentPermissionAction(
        key: 'event_delete',
        targetType: 'event',
        defaultMode: ConfirmationMode.alwaysAsk,
        defaultRisk: RiskLevel.high,
        relaxable: true,
        label: '删除日程'),
    'event_restore': AgentPermissionAction(
        key: 'event_restore',
        targetType: 'event',
        defaultMode: ConfirmationMode.askFirstTime,
        defaultRisk: RiskLevel.medium,
        relaxable: true,
        label: '恢复日程'),
    'task_cancel': AgentPermissionAction(
        key: 'task_cancel',
        targetType: 'task',
        defaultMode: ConfirmationMode.alwaysAsk,
        defaultRisk: RiskLevel.high,
        relaxable: true,
        label: '取消任务'),
    'task_delete': AgentPermissionAction(
        key: 'task_delete',
        targetType: 'task',
        defaultMode: ConfirmationMode.alwaysAsk,
        defaultRisk: RiskLevel.high,
        relaxable: true,
        label: '删除任务'),
    'task_restore': AgentPermissionAction(
        key: 'task_restore',
        targetType: 'task',
        defaultMode: ConfirmationMode.askFirstTime,
        defaultRisk: RiskLevel.medium,
        relaxable: true,
        label: '恢复任务'),
    'task_complete': AgentPermissionAction(
        key: 'task_complete',
        targetType: 'task',
        defaultMode: ConfirmationMode.askFirstTime,
        defaultRisk: RiskLevel.medium,
        relaxable: true,
        label: '完成任务'),
    'plan_block_cancel': AgentPermissionAction(
        key: 'plan_block_cancel',
        targetType: 'plan_block',
        defaultMode: ConfirmationMode.alwaysAsk,
        defaultRisk: RiskLevel.high,
        relaxable: true,
        label: '取消计划块'),
    'plan_block_delete': AgentPermissionAction(
        key: 'plan_block_delete',
        targetType: 'plan_block',
        defaultMode: ConfirmationMode.alwaysAsk,
        defaultRisk: RiskLevel.high,
        relaxable: true,
        label: '删除计划块'),
    'plan_block_restore': AgentPermissionAction(
        key: 'plan_block_restore',
        targetType: 'plan_block',
        defaultMode: ConfirmationMode.askFirstTime,
        defaultRisk: RiskLevel.medium,
        relaxable: true,
        label: '恢复计划块'),
    'delete_schedule_relation': AgentPermissionAction(
        key: 'delete_schedule_relation',
        targetType: 'relation',
        defaultMode: ConfirmationMode.alwaysAsk,
        defaultRisk: RiskLevel.high,
        relaxable: true,
        label: '删除日程关系'),
    'delete_schedule_relation_rule': AgentPermissionAction(
        key: 'delete_schedule_relation_rule',
        targetType: 'relation',
        defaultMode: ConfirmationMode.alwaysAsk,
        defaultRisk: RiskLevel.high,
        relaxable: true,
        label: '删除关系规则'),
    'clear_reminder_offsets': AgentPermissionAction(
        key: 'clear_reminder_offsets',
        targetType: 'event',
        defaultMode: ConfirmationMode.askFirstTime,
        defaultRisk: RiskLevel.medium,
        relaxable: true,
        label: '清除提醒偏移'),
    'clear_all_reminders': AgentPermissionAction(
        key: 'clear_all_reminders',
        targetType: 'event',
        defaultMode: ConfirmationMode.alwaysAsk,
        defaultRisk: RiskLevel.high,
        relaxable: true,
        label: '清除全部提醒'),
    'clear_event_overlay_fields': AgentPermissionAction(
        key: 'clear_event_overlay_fields',
        targetType: 'overlay',
        defaultMode: ConfirmationMode.askFirstTime,
        defaultRisk: RiskLevel.medium,
        relaxable: true,
        label: '清除日程标注字段'),
    'clear_all_event_overlay': AgentPermissionAction(
        key: 'clear_all_event_overlay',
        targetType: 'overlay',
        defaultMode: ConfirmationMode.alwaysAsk,
        defaultRisk: RiskLevel.high,
        relaxable: true,
        label: '清除全部日程标注'),
    'clear_course_overlay': AgentPermissionAction(
        key: 'clear_course_overlay',
        targetType: 'overlay',
        defaultMode: ConfirmationMode.alwaysAsk,
        defaultRisk: RiskLevel.high,
        relaxable: true,
        label: '清除课程标注'),
    'unlink_task_event': AgentPermissionAction(
        key: 'unlink_task_event',
        targetType: 'task',
        defaultMode: ConfirmationMode.alwaysAsk,
        defaultRisk: RiskLevel.high,
        relaxable: true,
        label: '解除任务-日程关联'),
    'reset_permission_policy': AgentPermissionAction(
        key: 'reset_permission_policy',
        targetType: 'permission',
        defaultMode: ConfirmationMode.alwaysAsk,
        defaultRisk: RiskLevel.critical,
        relaxable: false,
        label: '重置确认策略'),
    'undo_last_action': AgentPermissionAction(
        key: 'undo_last_action',
        targetType: 'undo',
        defaultMode: ConfirmationMode.askFirstTime,
        defaultRisk: RiskLevel.medium,
        relaxable: true,
        label: '撤回上一步'),
  };

  /// 设置页策略行展示的、有工具背书的 action 集合（kPolicyTargetMap 的来源）。
  /// 不包含纯注册表预留键（event_cancel 等新键在工具出现后由对应 Task 加入）。
  static const Set<String> _toolBackedActions = {
    'create_event', 'event_edit', 'create_task', 'plan_task',
    'create_user_overlay', 'record_attendance_decision', 'record_listening_mode',
    'create_schedule_relation', 'set_reminder',
    'update_permission_policy', 'move_jw_course_day',
  };

  /// actionType -> targetType 的单一映射（由注册表派生）。设置页策略行与权限
  /// 工具的 target_type 校验都消费这一份。
  static final Map<String, String> kPolicyTargetMap = {
    for (final k in _toolBackedActions) k: kPermissionActions[k]!.targetType,
  };

  /// 权限工具允许调整的 action_type（可改的确认策略目标；不含
  /// update_permission_policy 自身——它恒为 critical，永远人工确认）。
  /// move_jw_course_day 同样刻意排除：critical 整日移动用户/模型均不可放宽。
  /// 旧的 update_event 由 event_edit 取代（保留为兼容遗留键，但不再可调）。
  static const Set<String> kAgentPolicyActionTypes = {
    'create_event', 'event_edit', 'create_task', 'plan_task',
    'create_user_overlay', 'record_attendance_decision', 'record_listening_mode',
    'create_schedule_relation', 'set_reminder',
  };

  /// event_edit 的一版兼容回退键：旧的 update_event 策略行若存在，仅作为
  /// event_edit 的默认覆盖；绝不扩展覆盖到 event_cancel/delete/restore。
  static const String kEventEditLegacyKey = 'update_event';

  /// 某动作对应的唯一 target_type（策略行键的一部分）。
  static String targetTypeFor(String actionType) =>
      kPermissionActions[actionType]?.targetType ??
          (throw ArgumentError('no policy target type for actionType $actionType'));

  /// 动作的中文标签（设置页消费注册表）。
  static String labelFor(String actionType) =>
      kPermissionActions[actionType]?.label ?? actionType;

  static ConfirmationMode defaultMode(String actionType) =>
      kPermissionActions[actionType]?.defaultMode ?? ConfirmationMode.askFirstTime;

  static RiskLevel defaultRisk(String actionType) =>
      kPermissionActions[actionType]?.defaultRisk ?? RiskLevel.medium;

  /// 决议：行覆盖（enabled=false -> deny；confirmationMode 决定 allow/confirm）
  /// 或默认模式惰性生效。
  ///
  /// [riskLevel] 目前仅由调用方表达意图、不参与决议：风险语义已经编码进确认模式
  /// （critical 动作默认 always_ask；工具层 forceConfirmation + markAlwaysAllow
  /// 拒绝 critical 放宽），这里不重复判定。保留参数以保持调用点语义清晰，供未来
  /// 若需按风险细分策略时使用。
  Future<PermissionDecision> resolve({
    required String accountId,
    required String actionType,
    required String targetType,
    required RiskLevel riskLevel,
  }) async {
    final row = await _findWithLegacyFallback(accountId, actionType, targetType);
    if (row != null && !row.enabled) return PermissionDecision.deny;
    final mode = row?.confirmationMode ?? defaultMode(actionType);
    return switch (mode) {
      ConfirmationMode.alwaysDeny => PermissionDecision.deny,
      ConfirmationMode.alwaysAllow => PermissionDecision.allow,
      ConfirmationMode.askFirstTime => row?.firstConfirmedAt != null
          ? PermissionDecision.allow
          : PermissionDecision.confirm,
      ConfirmationMode.alwaysAsk => PermissionDecision.confirm,
    };
  }

  /// 当前生效的确认模式（行覆盖优先，缺省回退默认），供写工具在批准后决定
  /// 是否需要记录首次确认（仅 ask_first_time 有意义）。
  Future<ConfirmationMode> effectiveMode({
    required String accountId,
    required String actionType,
    required String targetType,
  }) async {
    final row = await _findWithLegacyFallback(accountId, actionType, targetType);
    return row?.confirmationMode ?? defaultMode(actionType);
  }

  /// 查策略行；`event_edit` 无行时回退到旧的 `update_event` 兼容行（设计 §17.3：
  /// 旧策略覆盖最多作为 event_edit 的一版兼容 fallback）。回退只在解析阶段使用，
  /// 绝不会把策略扩展到 event_cancel/event_delete/event_restore 等其它动作。
  Future<AgentPermissionPolicyRecord?> _findWithLegacyFallback(
    String accountId,
    String actionType,
    String targetType,
  ) async {
    var row = await _find(accountId, actionType, targetType);
    if (row == null &&
        actionType == 'event_edit' &&
        _kEventEditTargets.contains(targetType)) {
      row = await _find(accountId, kEventEditLegacyKey, targetType);
    }
    return row;
  }

  static const _kEventEditTargets = {'event'};

  Future<void> updatePolicy({
    required String accountId,
    required String actionType,
    required String targetType,
    required ConfirmationMode mode,
    required RiskLevel riskLevel,
    required bool enabled,
    required String updatedBy,
    String? safeSummary,
  }) async {
    final now = clock.now().millisecondsSinceEpoch;
    final existing = await _find(accountId, actionType, targetType);
    final id = existing?.id ?? _uuid.v4();
    await database.into(database.agentPermissionPolicies).insertOnConflictUpdate(
          AgentPermissionPoliciesCompanion.insert(
            id: id,
            accountId: accountId,
            actionType: actionType,
            targetType: Value(targetType),
            confirmationMode: mode.storage,
            riskLevel: Value(riskLevel.storage),
            enabled: Value(enabled),
            updatedBy: Value(updatedBy),
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
          ),
        );
    // 设置页/用户侧变更（updatedBy != 'agent'）落 source='user' 日志；Agent 发起的
    // 策略变更由 `AgentWriteTool` 基类统一写 source='agent' 日志（_commitAndLog），
    // 这里不重复写，避免「最近权限变更」对同一操作显示两条。
    if (updatedBy != 'agent') {
      await database.actionLogsRepository.append(
        accountId: accountId,
        source: 'user',
        actionType: 'update_permission_policy',
        result: 'success',
        safeSummary: safeSummary ?? '权限更新 $actionType($targetType) → ${mode.storage}',
        riskLevel: riskLevel.storage,
        occurredAt: now,
      );
    }
  }

  /// ask_first_time 首次确认后调用：记录 firstConfirmedAt，之后自动放行。
  ///
  /// 首次确认把该动作从「每次确认」放宽为「首次确认后放行」，是真实的权限模式
  /// 变更，必须在写入 firstConfirmedAt 的同一事务里落一行
  /// source='user'/actionType='update_permission_policy'/result='success'。
  Future<void> recordFirstConfirmation({
    required String accountId,
    required String actionType,
    required String targetType,
  }) async {
    final now = clock.now().millisecondsSinceEpoch;
    final existing = await _find(accountId, actionType, targetType);
    if (existing != null && existing.firstConfirmedAt != null) return;
    final id = existing?.id ?? _uuid.v4();
    await database.transaction(() async {
      await database.into(database.agentPermissionPolicies).insertOnConflictUpdate(
            AgentPermissionPoliciesCompanion.insert(
              id: id,
              accountId: accountId,
              actionType: actionType,
              targetType: Value(targetType),
              confirmationMode: existing?.confirmationMode.storage ?? defaultMode(actionType).storage,
              riskLevel: Value(existing?.riskLevel.storage ?? defaultRisk(actionType).storage),
              firstConfirmedAt: Value(existing?.firstConfirmedAt ?? now),
              lastConfirmedAt: Value(now),
              createdAt: existing?.createdAt ?? now,
              updatedAt: now,
            ),
          );
      await database.actionLogsRepository.append(
        accountId: accountId,
        source: 'user',
        actionType: 'update_permission_policy',
        result: 'success',
        safeSummary: '权限更新 $actionType($targetType) → ask_first_time',
        riskLevel: defaultRisk(actionType).storage,
        occurredAt: now,
      );
    });
  }

  /// 「此类型以后不再确认」：放宽为 always_allow。非 relaxable 动作（critical 或
  /// 明确锁定）拒绝。
  Future<void> markAlwaysAllow({
    required String accountId,
    required String actionType,
    required String targetType,
  }) async {
    if (!(kPermissionActions[actionType]?.relaxable ?? false)) {
      throw StateError('critical risk actions cannot be auto-allowed');
    }
    await updatePolicy(
      accountId: accountId,
      actionType: actionType,
      targetType: targetType,
      mode: ConfirmationMode.alwaysAllow,
      riskLevel: defaultRisk(actionType),
      enabled: true,
      updatedBy: 'user',
      safeSummary: '$actionType($targetType) -> always_allow',
    );
  }

  /// Agent 写提交/拒绝/取消的聚合日志（source='agent'）。
  Future<void> logAgentWrite({
    required String accountId,
    required String actionType,
    required String riskLevel,
    required String result,
    required String safeSummary,
  }) => database.actionLogsRepository.append(
    accountId: accountId,
    source: 'agent',
    actionType: actionType,
    result: result,
    safeSummary: safeSummary,
    riskLevel: riskLevel,
    occurredAt: clock.now().millisecondsSinceEpoch,
  );

  /// Agent 审批流的唯一 ActionLog 追加口：approval 决策本身（确认/拒绝/取消）
  /// 与 ask_first_time/remember 的权限变更都从这里追加一行，来源与语义由
  /// [source]/[actionType]/[result] 表达。safesummary 不得含本地 id 或 ref。
  Future<void> logAudit({
    required String accountId,
    required String source,
    required String actionType,
    required RiskLevel riskLevel,
    required String result,
    required String safeSummary,
  }) => database.actionLogsRepository.append(
    accountId: accountId,
    source: source,
    actionType: actionType,
    result: result,
    safeSummary: safeSummary,
    riskLevel: riskLevel.storage,
    occurredAt: clock.now().millisecondsSinceEpoch,
  );

  Future<List<AgentPermissionPolicyRecord>> listPolicies(String accountId) async {
    final rows = await (database.select(database.agentPermissionPolicies)
          ..where((row) => row.accountId.equals(accountId)))
        .get();
    return rows.map(AgentPermissionPolicyRecord.fromRow).toList(growable: false);
  }

  Future<void> resetDefaults(String accountId) async {
    await (database.delete(database.agentPermissionPolicies)
          ..where((row) => row.accountId.equals(accountId)))
        .go();
    // 设置页「恢复默认」同样属于权限变更，必须留痕（放宽此前收紧的策略）。
    await database.actionLogsRepository.append(
      accountId: accountId,
      source: 'user',
      actionType: 'reset_permission_policy',
      result: 'success',
      safeSummary: '重置全部权限策略为默认',
      riskLevel: 'critical',
      occurredAt: clock.now().millisecondsSinceEpoch,
    );
  }

  /// 最近的权限变更记录（update/reset_permission_policy 的 ActionLog）。
  Future<List<ActionLog>> recentPermissionChanges(
    String accountId, {
    int limit = 5,
  }) => (database.select(database.actionLogs)
        ..where(
          (row) =>
              row.accountId.equals(accountId) &
              row.actionType.isIn(const [
                'update_permission_policy',
                'reset_permission_policy',
              ]),
        )
        ..orderBy([(row) => OrderingTerm.desc(row.occurredAt)])
        ..limit(limit))
      .get();

  Future<AgentPermissionPolicyRecord?> _find(
    String accountId,
    String actionType,
    String targetType,
  ) async {
    final rows = await (database.select(database.agentPermissionPolicies)
          ..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.actionType.equals(actionType) &
                row.targetType.equals(targetType),
          ))
        .get();
    if (rows.isEmpty) return null;
    return AgentPermissionPolicyRecord.fromRow(rows.first);
  }
}
