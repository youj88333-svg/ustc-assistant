import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../../calendar/domain/personal_event.dart';
import '../domain/agent_permission_policy.dart';
import '../domain/agent_tool.dart';
import '../domain/agent_write_gateway.dart';
import '../domain/agent_write_proposal.dart';
import '../domain/agent_write_unit_of_work.dart';
import 'agent_permission_policy_service.dart';

/// 业务 commit 返回非成功结果时抛出，使整个事务回滚并原样返回其安全结果。
///
/// 这是"原子写"的预期中断：提交本身没有成功，无需业务回滚，但必须立刻中止
/// 事务（避免后续审计/权限变更在未提交状态上继续）。在事务外捕获。
class AgentWriteAborted implements Exception {
  AgentWriteAborted(this.result);
  final AgentToolResult result;
}

/// 写工具基类：`propose` 产提案（不碰库），`commit` 经网关写库。
///
/// `execute` 统一实现"审批门"：提案 → 策略决议 → 直接提交 / 拒绝 /
/// 暂停等待用户（复用 needsUserAction 机制）。
///
/// `_commitAndLog` 是直接放行路径与已确认批准路径共享的原子操作：业务提交、
/// `source='agent'` 审计日志与提交成功后的权限变更（首确认/放宽）全部装进
/// 同一个 [AgentWriteUnitOfWork]。其中任何一步失败，其余全部回滚。
abstract class AgentWriteTool implements AgentTool {
  AgentWriteTool({
    required this.gateway,
    required this.policy,
    required this.confirmationStore,
    required this.unitOfWork,
  });

  // 非 final：子类/测试可通过 attachGateway 注入假网关。
  AgentWriteGateway gateway;
  final AgentPermissionPolicyService policy;
  final WriteConfirmationStore confirmationStore;
  final AgentWriteUnitOfWork unitOfWork;

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
    } on FormatException {
      // 参数校验失败（标题缺失/未知 ref/非法日期等）→ 让模型修正参数。
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'invalid_write_arguments',
      );
    } on CalendarValidationError {
      // 日程构造校验（如全天的开始日期不晚于结束日期）同样属于参数错误。
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'invalid_write_arguments',
      );
    }
    // 其余异常不在此吞掉：交由 registry 兜底为 tool_execution_failed，避免把
    // 真正的 bug 伪装成"参数不合法"而难以排查。

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
        // 确认卡的解放在 resolve 里统一走一次共享原子提交（业务 commit -> 用户
        // 确认日志 -> agent 业务日志 -> afterSuccessfulCommit）。这里注册的是原始
        // 业务 commit，而不是 _commitAndLog，避免把整个原子流程嵌套进另一个原子
        // 流程，造成业务审计重复落两行。
        final handle = confirmationStore.register(
          proposal: proposal,
          context: context,
          commit: (p, c) => commit(p, c),
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

  /// 直接放行路径的原子提交（与已确认批准路径共享同一实现）。
  ///
  /// 业务 commit → 审计（source='agent', success）→ 提交成功后权限变更，全部
  /// 落在同一个 [unitOfWork] 事务里；任何一步失败整个回滚。
  Future<AgentToolResult> _commitAndLog(AgentWriteProposal proposal, AgentToolContext context) {
    return commitAgentWriteAtomically(
      proposal: proposal,
      context: context,
      policy: policy,
      unitOfWork: unitOfWork,
      businessCommit: (p, c) => commit(p, c),
      remember: false,
      userConfirmed: false,
    );
  }
}

/// 待确认提案暂存：run 内有效，`handle` 是确认卡与恢复回调之间的不透明句柄。
class WriteConfirmationStore {
  WriteConfirmationStore({required this.policy, required this.unitOfWork});

  final AgentPermissionPolicyService policy;
  final AgentWriteUnitOfWork unitOfWork;
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
    if (!approve) {
      // 拒绝不会产生业务写，无需共享原子性；记录
      // source='user'/actionType='agent_write_decline'/result='declined' 后返回。
      final declined = const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'user_declined',
        payload: {'guidance': '用户未批准本次操作。'},
      );
      try {
        await policy.logAudit(
          accountId: pending.context.accountId,
          source: 'user',
          actionType: 'agent_write_decline',
          riskLevel: pending.proposal.riskLevel,
          result: 'declined',
          safeSummary: pending.proposal.safeLogSummary,
        );
      } catch (_) {
        // 拒绝审计失败不改变决策结果，仍返回 user_declined。
      }
      pending.completer.complete(declined);
      return declined;
    }
    // 批准：走与直接放行共享的原子提交（commit -> user 确认日志 -> agent 业务日志
    // -> afterSuccessfulCommit）。用户决策、业务提交与权限变更在同一事务，任一
    // 失败全部回滚，不会留下"放宽成功但提交失败"的错位状态。userConfirmed=true
    // 表示这是一次用户在确认卡上的批准，须落 agent_write_confirm/approved。
    final result = await commitAgentWriteAtomically(
      proposal: pending.proposal,
      context: pending.context,
      policy: policy,
      unitOfWork: unitOfWork,
      businessCommit: pending.commit,
      remember: remember,
      userConfirmed: true,
    );
    pending.completer.complete(result);
    return result;
  }

  Future<void> cancel(String handle, Completer<AgentToolResult> completer) async {
    final pending = _pending.remove(handle);
    if (pending == null || pending.completer.isCompleted) return;
    // run 停止使挂起的提案作废：best-effort 追加
    // source='agent'/actionType='agent_write_cancel'/result='cancelled'，审计失败
    // 不阻断取消；随后完成挂起的 pendingInvocation，使会话循环恢复。
    try {
      await policy.logAudit(
        accountId: pending.context.accountId,
        source: 'agent',
        actionType: 'agent_write_cancel',
        riskLevel: pending.proposal.riskLevel,
        result: 'cancelled',
        safeSummary: pending.proposal.safeLogSummary,
      );
    } catch (_) {
      // 取消审计失败不改变取消结果。
    }
    pending.completer.complete(const AgentToolResult(status: AgentToolStatus.error, errorCode: 'cancelled'));
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

/// 写工具直接放行路径与确认批准路径共享的单个原子提交实现。
///
/// 在一个 [unitOfWork] 事务里依次：业务 [businessCommit] → 审计
/// (source='agent', success) → [afterSuccessfulCommit]（首确认/放宽的权限
/// 变更）。任何一步失败整个事务回滚：
/// - 业务 commit 返回非 success → 抛 [AgentWriteAborted]，事务外原样返回其
///   安全结果。
/// - 其余失败（审计/权限写入等）→ 不重试 businessCommit，尝试一次独立的
///   best-effort 'failed' 审计，然后返回 `write_commit_failed`。
Future<AgentToolResult> commitAgentWriteAtomically({
  required AgentWriteProposal proposal,
  required AgentToolContext context,
  required AgentPermissionPolicyService policy,
  required AgentWriteUnitOfWork unitOfWork,
  required Future<AgentToolResult> Function(AgentWriteProposal, AgentToolContext) businessCommit,
  required bool remember,
  bool userConfirmed = false,
}) async {
  try {
    return await unitOfWork.run(() async {
      final result = await businessCommit(proposal, context);
      if (result.status != AgentToolStatus.success) {
        // 提交未成功：不带结果回滚（无业务写需要恢复），抛出让事务回滚并在
        // 事务外原样返回该安全结果。
        throw AgentWriteAborted(result);
      }
      // 用户在确认卡上的批准：先落 agent_write_confirm/approved（用户决策本身）。
      // 只有确认卡批准（userConfirmed=true）才写这一行；直接放行路径不加。
      if (userConfirmed) {
        await policy.logAudit(
          accountId: context.accountId,
          source: 'user',
          actionType: 'agent_write_confirm',
          riskLevel: proposal.riskLevel,
          result: 'approved',
          safeSummary: proposal.safeLogSummary,
        );
      }
      // 业务写本身的 Agent 审计（source='agent'，actual tool action 或
      // update_permission_policy）。
      await policy.logAgentWrite(
        accountId: context.accountId,
        actionType: proposal.actionType,
        riskLevel: proposal.riskLevel.storage,
        result: 'success',
        safeSummary: proposal.safeLogSummary,
      );
      await afterSuccessfulCommit(
        proposal: proposal,
        context: context,
        policy: policy,
        remember: remember,
      );
      return result;
    });
  } on AgentWriteAborted catch (e) {
    // 提交未成功的安全结果：原样返回。
    return e.result;
  } catch (_) {
    // 事务真实失败（审计/权限写入失败等），不重试 businessCommit：
    // 尝试一次独立的 best-effort 'failed' 审计，然后返回 write_commit_failed。
    try {
      await policy.logAgentWrite(
        accountId: context.accountId,
        actionType: proposal.actionType,
        riskLevel: proposal.riskLevel.storage,
        result: 'failed',
        safeSummary: proposal.safeLogSummary,
      );
    } catch (_) {
      // 审计也失败则静默：不掩盖原始失败。
    }
    return const AgentToolResult(status: AgentToolStatus.error, errorCode: 'write_commit_failed');
  }
}

/// 提交成功后已原子完成的权限变更：remember 放宽为 always_allow，否则
/// ask_first_time 首次确认则记录 firstConfirmedAt。Task 4 将在此追加审计
/// taxonomy；此处已把现有策略变更移进共享事务。
Future<void> afterSuccessfulCommit({
  required AgentWriteProposal proposal,
  required AgentToolContext context,
  required AgentPermissionPolicyService policy,
  required bool remember,
}) async {
  if (proposal.forceConfirmation ||
      proposal.riskLevel == RiskLevel.critical) {
    return;
  }
  if (remember) {
    await policy.markAlwaysAllow(
      accountId: context.accountId,
      actionType: proposal.actionType,
      targetType: proposal.targetType,
    );
    return;
  }
  final mode = await policy.effectiveMode(
    accountId: context.accountId,
    actionType: proposal.actionType,
    targetType: proposal.targetType,
  );
  if (mode == ConfirmationMode.askFirstTime) {
    await policy.recordFirstConfirmation(
      accountId: context.accountId,
      actionType: proposal.actionType,
      targetType: proposal.targetType,
    );
  }
}