import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../../core/time/beijing_clock.dart';
import '../domain/agent_permission_policy.dart';

/// 写操作确认策略的查询、决议与变更。
///
/// 默认策略按数据模型 §10.5 与设计 §3 映射惰性生效（无行时用默认值，不物理
/// 播种）。任何权限变更写 `ActionLog`。
class AgentPermissionPolicyService {
  AgentPermissionPolicyService({required this.database, required this.clock});

  final AppDatabase database;
  final BeijingClock clock;
  static const _uuid = Uuid();

  /// actionType -> targetType 的单一映射。设置页策略行与权限工具的 target_type
  /// 校验都消费这一份，避免两处各自维护一份 action/target 清单。
  static const Map<String, String> kPolicyTargetMap = {
    'create_event': 'event',
    'update_event': 'event',
    'create_task': 'task',
    'plan_task': 'plan_block',
    'create_user_overlay': 'overlay',
    'record_attendance_decision': 'event',
    'record_listening_mode': 'event',
    'create_schedule_relation': 'relation',
    'set_reminder': 'event',
    'update_permission_policy': 'permission',
  };

  /// 权限工具允许调整的 action_type（可改的确认策略目标；不含
  /// update_permission_policy 自身——它恒为 critical，永远人工确认）。
  static const Set<String> kAgentPolicyActionTypes = {
    'create_event', 'update_event', 'create_task', 'plan_task',
    'create_user_overlay', 'record_attendance_decision', 'record_listening_mode',
    'create_schedule_relation', 'set_reminder',
  };

  /// 某动作对应的唯一 target_type（策略行键的一部分）。
  static String targetTypeFor(String actionType) => kPolicyTargetMap[actionType] ??
      (throw ArgumentError('no policy target type for actionType $actionType'));

  /// actionType -> (默认确认模式, 默认风险等级)。
  static const Map<String, ConfirmationMode> _defaultModes = {
    'create_event': ConfirmationMode.askFirstTime,
    'create_task': ConfirmationMode.askFirstTime,
    'plan_task': ConfirmationMode.askFirstTime,
    'create_schedule_relation': ConfirmationMode.askFirstTime,
    'set_reminder': ConfirmationMode.askFirstTime,
    'record_attendance_decision': ConfirmationMode.askFirstTime,
    'record_listening_mode': ConfirmationMode.askFirstTime,
    'create_user_overlay': ConfirmationMode.askFirstTime,
    'update_event': ConfirmationMode.alwaysAsk, // 含删除/整系列（大范围修改）
    'update_permission_policy': ConfirmationMode.alwaysAsk,
    'move_plan_block': ConfirmationMode.alwaysAsk, // 预留默认（本轮无工具）
  };

  static const Map<String, RiskLevel> _defaultRisks = {
    'create_event': RiskLevel.medium,
    'create_task': RiskLevel.medium,
    'plan_task': RiskLevel.medium,
    'create_schedule_relation': RiskLevel.medium,
    'set_reminder': RiskLevel.medium,
    'record_attendance_decision': RiskLevel.medium,
    'record_listening_mode': RiskLevel.medium,
    'create_user_overlay': RiskLevel.medium,
    'update_event': RiskLevel.high,
    'update_permission_policy': RiskLevel.critical,
    'move_plan_block': RiskLevel.medium,
  };

  static ConfirmationMode defaultMode(String actionType) =>
      _defaultModes[actionType] ?? ConfirmationMode.askFirstTime;

  static RiskLevel defaultRisk(String actionType) =>
      _defaultRisks[actionType] ?? RiskLevel.medium;

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
    final row = await _find(accountId, actionType, targetType);
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
    final row = await _find(accountId, actionType, targetType);
    return row?.confirmationMode ?? defaultMode(actionType);
  }

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

  /// 「此类型以后不再确认」：放宽为 always_allow。critical 风险拒绝。
  Future<void> markAlwaysAllow({
    required String accountId,
    required String actionType,
    required String targetType,
  }) async {
    if (defaultRisk(actionType) == RiskLevel.critical) {
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
