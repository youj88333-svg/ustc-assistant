/// 写操作确认模式。
enum ConfirmationMode { alwaysAsk, askFirstTime, alwaysAllow, alwaysDeny }

/// 写操作风险等级（数据模型 §10.3）。
enum RiskLevel { low, medium, high, critical }

/// 审批门决议：直接执行 / 需要用户确认 / 拒绝。
enum PermissionDecision { allow, confirm, deny }

extension ConfirmationModeStorage on ConfirmationMode {
  String get storage => switch (this) {
    ConfirmationMode.alwaysAsk => 'always_ask',
    ConfirmationMode.askFirstTime => 'ask_first_time',
    ConfirmationMode.alwaysAllow => 'always_allow',
    ConfirmationMode.alwaysDeny => 'always_deny',
  };
  static ConfirmationMode fromStorage(String value) => switch (value) {
    'ask_first_time' => ConfirmationMode.askFirstTime,
    'always_allow' => ConfirmationMode.alwaysAllow,
    'always_deny' => ConfirmationMode.alwaysDeny,
    _ => ConfirmationMode.alwaysAsk,
  };
}

extension RiskLevelStorage on RiskLevel {
  String get storage => switch (this) {
    RiskLevel.low => 'low',
    RiskLevel.medium => 'medium',
    RiskLevel.high => 'high',
    RiskLevel.critical => 'critical',
  };
  static RiskLevel fromStorage(String value) => switch (value) {
    'low' => RiskLevel.low,
    'high' => RiskLevel.high,
    'critical' => RiskLevel.critical,
    _ => RiskLevel.medium,
  };
}

/// 一条策略记录（对应 agent_permission_policies 表行）。
class AgentPermissionPolicyRecord {
  const AgentPermissionPolicyRecord({
    required this.id,
    required this.accountId,
    required this.actionType,
    required this.targetType,
    required this.confirmationMode,
    required this.riskLevel,
    required this.enabled,
    required this.createdAt,
    required this.updatedAt,
    this.firstConfirmedAt,
    this.lastConfirmedAt,
    this.expiresAt,
    this.updatedBy,
  });

  final String id;
  final String accountId;
  final String actionType;
  final String targetType;
  final ConfirmationMode confirmationMode;
  final RiskLevel riskLevel;
  final bool enabled;
  final int? firstConfirmedAt;
  final int? lastConfirmedAt;
  final int? expiresAt;
  final String? updatedBy;
  final int createdAt;
  final int updatedAt;

  static AgentPermissionPolicyRecord fromRow(dynamic row) =>
      AgentPermissionPolicyRecord(
        id: row.id,
        accountId: row.accountId,
        actionType: row.actionType,
        targetType: row.targetType,
        confirmationMode: ConfirmationModeStorage.fromStorage(row.confirmationMode),
        riskLevel: RiskLevelStorage.fromStorage(row.riskLevel),
        enabled: row.enabled,
        firstConfirmedAt: row.firstConfirmedAt,
        lastConfirmedAt: row.lastConfirmedAt,
        expiresAt: row.expiresAt,
        updatedBy: row.updatedBy,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
      );
}
