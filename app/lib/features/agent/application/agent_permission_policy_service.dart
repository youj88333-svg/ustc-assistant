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

  Future<void> updatePolicy({
    required String accountId,
    required String actionType,
    required String targetType,
    required ConfirmationMode mode,
    required RiskLevel riskLevel,
    required bool enabled,
    required String updatedBy,
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
    await database.actionLogsRepository.append(
      accountId: accountId,
      source: 'user',
      actionType: 'update_permission_policy',
      result: 'success',
      safeSummary: '权限更新 $actionType($targetType) → ${mode.storage}',
      riskLevel: riskLevel.storage,
      occurredAt: now,
    );
  }

  /// ask_first_time 首次确认后调用：记录 firstConfirmedAt，之后自动放行。
  Future<void> recordFirstConfirmation({
    required String accountId,
    required String actionType,
    required String targetType,
  }) async {
    final now = clock.now().millisecondsSinceEpoch;
    final existing = await _find(accountId, actionType, targetType);
    if (existing != null && existing.firstConfirmedAt != null) return;
    final id = existing?.id ?? _uuid.v4();
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
  }

  /// 最近的权限变更记录（update_permission_policy 的 ActionLog）。
  Future<List<ActionLog>> recentPermissionChanges(
    String accountId, {
    int limit = 5,
  }) => (database.select(database.actionLogs)
        ..where(
          (row) =>
              row.accountId.equals(accountId) &
              row.actionType.equals('update_permission_policy'),
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
