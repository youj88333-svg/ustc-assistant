import 'agent_permission_policy.dart';

/// 一次写操作的草稿：由写工具 propose 产出，不触碰数据库。
///
/// [commitParams] 是规范化后的提交参数，只被写工具 commit 消费，绝不进入
/// 工具结果或模型请求；[targetId] 是解析后的本地 id，同样不出领域层。
class AgentWriteProposal {
  const AgentWriteProposal({
    required this.toolName,
    required this.actionType,
    required this.riskLevel,
    required this.targetType,
    required this.operationLabel,
    required this.previewLines,
    required this.commitParams,
    required this.safeLogSummary,
    this.targetRef,
    this.targetId,
    this.rememberAllowed = true,
    this.forceConfirmation = false,
  });

  final String toolName;
  final String actionType;
  final RiskLevel riskLevel;
  final String targetType;
  final String operationLabel;
  final List<String> previewLines;
  final Map<String, Object?> commitParams;
  final String safeLogSummary;
  final String? targetRef;
  final String? targetId;
  final bool rememberAllowed;
  final bool forceConfirmation;

  AgentWriteProposalView toView() => AgentWriteProposalView(
        operationLabel: operationLabel,
        riskLevel: riskLevel,
        actionType: actionType,
        targetType: targetType,
        previewLines: previewLines,
        rememberAllowed: rememberAllowed,
      );

  AgentWriteProposal copyWith({bool? rememberAllowed, bool? forceConfirmation}) =>
      AgentWriteProposal(
        toolName: toolName,
        actionType: actionType,
        riskLevel: riskLevel,
        targetType: targetType,
        operationLabel: operationLabel,
        previewLines: previewLines,
        commitParams: commitParams,
        safeLogSummary: safeLogSummary,
        targetRef: targetRef,
        targetId: targetId,
        rememberAllowed: rememberAllowed ?? this.rememberAllowed,
        forceConfirmation: forceConfirmation ?? this.forceConfirmation,
      );
}

/// 给确认卡/UI 的模型安全视图：无本地 id、无 commitParams、无原始参数。
class AgentWriteProposalView {
  const AgentWriteProposalView({
    required this.operationLabel,
    required this.riskLevel,
    required this.actionType,
    required this.targetType,
    required this.previewLines,
    required this.rememberAllowed,
  });

  final String operationLabel;
  final RiskLevel riskLevel;
  final String actionType;
  final String targetType;
  final List<String> previewLines;
  final bool rememberAllowed;
}
