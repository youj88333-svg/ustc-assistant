import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../domain/agent_permission_policy.dart';
import '../domain/agent_tool.dart';
import '../domain/agent_write_gateway.dart';
import '../domain/agent_write_proposal.dart';
import 'agent_permission_policy_service.dart';

/// 写工具基类：`propose` 产提案（不碰库），`commit` 经网关写库。
///
/// `execute` 统一实现"审批门"：提案 → 策略决议 → 直接提交 / 拒绝 /
/// 暂停等待用户（复用 needsUserAction 机制）。
abstract class AgentWriteTool implements AgentTool {
  AgentWriteTool({
    required this.gateway,
    required this.policy,
    required this.confirmationStore,
  });

  // 非 final：子类/测试可通过 attachGateway 注入假网关。
  AgentWriteGateway gateway;
  final AgentPermissionPolicyService policy;
  final WriteConfirmationStore confirmationStore;

  /// 运行时/测试注入点：替换底层网关（网关字段可变）。
  void attachGateway(AgentWriteGateway value) => gateway = value;

  /// 策略按 (actionType, targetType) 查；写工具声明自己的组合。
  String get actionType;
  RiskLevel get riskLevel;
  String get targetType;
  String get operationLabel;

  /// 确认卡是否提供「此类型以后不再确认」。critical 动作覆盖为 false。
  bool get rememberAllowed => true;

  /// 强制确认（update_permission_policy）。永远走确认卡，不自动放行。
  bool get forceConfirmation => false;

  Future<AgentWriteProposal> propose(Map<String, Object?> arguments, AgentToolContext context);
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext context);

  @override
  Future<AgentToolResult> execute(Map<String, Object?> arguments, AgentToolContext context) async {
    final AgentWriteProposal proposal;
    try {
      final raw = await propose(arguments, context);
      proposal = raw.copyWith(
        rememberAllowed: rememberAllowed && raw.rememberAllowed,
        forceConfirmation: forceConfirmation || raw.forceConfirmation,
      );
    } catch (_) {
      return const AgentToolResult(status: AgentToolStatus.error, errorCode: 'invalid_write_arguments');
    }

    final decision = proposal.forceConfirmation
        ? PermissionDecision.confirm
        : await policy.resolve(
            accountId: context.accountId,
            actionType: actionType,
            targetType: targetType,
            riskLevel: riskLevel,
          );

    switch (decision) {
      case PermissionDecision.deny:
        return const AgentToolResult(status: AgentToolStatus.error, errorCode: 'permission_denied');
      case PermissionDecision.allow:
        return _commitAndLog(proposal, context);
      case PermissionDecision.confirm:
        final completer = Completer<AgentToolResult>();
        final handle = confirmationStore.register(
          proposal: proposal,
          context: context,
          commit: _commitAndLog,
          completer: completer,
        );
        return AgentToolResult(
          status: AgentToolStatus.needsUserAction,
          userAction: AgentUserAction(
            type: AgentUserActionType.writeConfirmation,
            opaqueHandle: handle,
            writeProposal: proposal.toView(),
          ),
          pendingInvocation: AgentPendingToolInvocation(
            result: completer.future,
            cancel: () => confirmationStore.cancel(handle, completer),
          ),
        );
    }
  }

  Future<AgentToolResult> _commitAndLog(AgentWriteProposal proposal, AgentToolContext context) async {
    final result = await commit(proposal, context);
    if (result.status == AgentToolStatus.success) {
      await policy.logAgentWrite(
        accountId: context.accountId,
        actionType: proposal.actionType,
        riskLevel: proposal.riskLevel.storage,
        result: 'success',
        safeSummary: proposal.safeLogSummary,
      );
    }
    return result;
  }
}

/// 待确认提案暂存：run 内有效，`handle` 是确认卡与恢复回调之间的不透明句柄。
class WriteConfirmationStore {
  WriteConfirmationStore({required this.policy});

  final AgentPermissionPolicyService policy;
  final Map<String, _PendingWrite> _pending = {};
  static const _handlePrefix = 'wc';
  static final _random = Random.secure();

  String register({
    required AgentWriteProposal proposal,
    required AgentToolContext context,
    required Future<AgentToolResult> Function(AgentWriteProposal, AgentToolContext) commit,
    Completer<AgentToolResult>? completer,
  }) {
    final handle = _generateHandle();
    _pending[handle] = _PendingWrite(
      proposal: proposal,
      context: context,
      commit: commit,
      completer: completer ?? Completer<AgentToolResult>(),
    );
    return handle;
  }

  /// 用户确认/取消/放宽。完成挂起的 pendingInvocation.result，使会话循环恢复。
  Future<AgentToolResult> resolve(String handle, {required bool approve, required bool remember}) async {
    final pending = _pending.remove(handle);
    if (pending == null) {
      return const AgentToolResult(status: AgentToolStatus.error, errorCode: 'confirmation_not_found');
    }
    try {
      if (!approve) {
        await policy.logAgentWrite(
          accountId: pending.context.accountId,
          actionType: pending.proposal.actionType,
          riskLevel: pending.proposal.riskLevel.storage,
          result: 'declined',
          safeSummary: pending.proposal.safeLogSummary,
        );
        final declined = const AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'user_declined',
          payload: {'guidance': '用户未批准本次操作。'},
        );
        pending.completer.complete(declined);
        return declined;
      }
      if (remember && !pending.proposal.forceConfirmation &&
          pending.proposal.riskLevel != RiskLevel.critical) {
        await policy.markAlwaysAllow(
          accountId: pending.context.accountId,
          actionType: pending.proposal.actionType,
          targetType: pending.proposal.targetType,
        );
      } else if (!pending.proposal.forceConfirmation) {
        await policy.recordFirstConfirmation(
          accountId: pending.context.accountId,
          actionType: pending.proposal.actionType,
          targetType: pending.proposal.targetType,
        );
      }
      final result = await pending.commit(pending.proposal, pending.context);
      pending.completer.complete(result);
      return result;
    } catch (_) {
      final failed = const AgentToolResult(status: AgentToolStatus.error, errorCode: 'write_commit_failed');
      pending.completer.complete(failed);
      return failed;
    }
  }

  Future<void> cancel(String handle, Completer<AgentToolResult> completer) async {
    final pending = _pending.remove(handle);
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.complete(const AgentToolResult(status: AgentToolStatus.error, errorCode: 'cancelled'));
    }
  }

  String _generateHandle() {
    final bytes = List<int>.generate(12, (_) => _random.nextInt(256));
    final ref = base64Url.encode(bytes).replaceAll('=', '');
    final handle = '${_handlePrefix}_$ref';
    if (_pending.containsKey(handle)) return _generateHandle();
    return handle;
  }
}

class _PendingWrite {
  _PendingWrite({
    required this.proposal,
    required this.context,
    required this.commit,
    required this.completer,
  });

  final AgentWriteProposal proposal;
  final AgentToolContext context;
  final Future<AgentToolResult> Function(AgentWriteProposal, AgentToolContext) commit;
  final Completer<AgentToolResult> completer;
}
