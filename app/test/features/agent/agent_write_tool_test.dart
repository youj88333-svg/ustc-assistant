import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_permission_policy_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_write_tool.dart';
import 'package:ustc_assistant_app/features/agent/application/cancellation_signal.dart';
import 'package:ustc_assistant_app/features/agent/application/run_reference_store.dart';
import 'package:ustc_assistant_app/features/agent/data/drift_agent_write_unit_of_work.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_permission_policy.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_tool.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_write_gateway.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_write_proposal.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_write_unit_of_work.dart';

class _NoopGateway implements AgentWriteGateway {
  @override
  Future<dynamic> noSuchMethod(Invocation invocation) async =>
      throw UnimplementedError();
}

class _FixedClock implements BeijingClock {
  @override
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);
}

class _FakeWriteTool extends AgentWriteTool {
  _FakeWriteTool({required super.gateway, required super.policy, required super.confirmationStore, required super.unitOfWork});

  @override
  String get name => 'create_event';
  @override
  String get description => '新建个人日程';
  @override
  Map<String, Object?> get inputSchema => const {};
  @override
  String get actionType => 'create_event';
  @override
  RiskLevel get riskLevel => RiskLevel.medium;
  @override
  String get targetType => 'event';
  @override
  String get operationLabel => '新建日程';
  @override
  List<AgentWriteAllowance> get agentWriteAllowances =>
      const [AgentWriteAllowance('create_event', 'event', RiskLevel.medium)];

  bool commitCalled = false;
  bool proposeCalled = false;

  @override
  Future<AgentWriteProposal> propose(Map<String, Object?> arguments, AgentToolContext context) async {
    proposeCalled = true;
    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: const ['明天 15:00 健身'],
      commitParams: const {'title': '健身'},
      safeLogSummary: '新建日程 明天 15:00 健身',
    );
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext context) async {
    commitCalled = true;
    return const AgentToolResult(payload: {'result': 'created_event'});
  }
}

class _ForceConfirmTool extends _FakeWriteTool {
  _ForceConfirmTool({required super.gateway, required super.policy, required super.confirmationStore, required super.unitOfWork});
  @override
  bool get forceConfirmation => true;
}

/// 模拟 event_edit（原 update_event）：默认 always_ask（首次确认后仍每次确认）。
class _AlwaysAskTool extends _FakeWriteTool {
  _AlwaysAskTool({required super.gateway, required super.policy, required super.confirmationStore, required super.unitOfWork});
  @override
  String get actionType => 'event_edit';
  @override
  RiskLevel get riskLevel => RiskLevel.high;
  @override
  List<AgentWriteAllowance> get agentWriteAllowances =>
      const [AgentWriteAllowance('event_edit', 'event', RiskLevel.high)];
}

/// 可变 action/risk 的假工具，用于验证决议读取 proposal 动态字段而非静态 getter。
/// 静态 getter 恒为旧键 update_event / event，proposal 用 [actionTypeOverride]
/// 动态覆盖；通过 observable 行为断言（event_edit 首次确认后放行、event_delete 仍
/// 需确认）验证 execute 实际按 proposal 的动态键决议。
class _DynamicActionTool extends _FakeWriteTool {
  _DynamicActionTool({required super.gateway, required super.policy, required super.confirmationStore, required super.unitOfWork});
  String actionTypeOverride = 'event_edit';
  @override
  String get actionType => 'update_event'; // 静态 getter 是旧键；proposal 动态覆盖
  @override
  RiskLevel get riskLevel => RiskLevel.high;
  @override
  List<AgentWriteAllowance> get agentWriteAllowances => const [
    AgentWriteAllowance('event_edit', 'event', RiskLevel.high),
    AgentWriteAllowance('event_delete', 'event', RiskLevel.high),
  ];

  @override
  Future<AgentWriteProposal> propose(Map<String, Object?> arguments, AgentToolContext context) async {
    proposeCalled = true;
    return AgentWriteProposal(
      toolName: name,
      actionType: actionTypeOverride,
      riskLevel: RiskLevel.high,
      targetType: 'event',
      operationLabel: operationLabel,
      previewLines: const ['变更日程'],
      commitParams: const {'k': 'v'},
      safeLogSummary: '修改日程',
    );
  }
}

/// 伪造不在 allowlist 内的 proposal（actionType 是未知/未声明键）。
class _ForgedProposalTool extends _FakeWriteTool {
  _ForgedProposalTool({required super.gateway, required super.policy, required super.confirmationStore, required super.unitOfWork});
  @override
  Future<AgentWriteProposal> propose(Map<String, Object?> arguments, AgentToolContext context) async {
    proposeCalled = true;
    return AgentWriteProposal(
      toolName: name,
      actionType: 'event_delete', // 未在 allowlist（本工具只声明 create_event）
      riskLevel: RiskLevel.high,
      targetType: 'event',
      operationLabel: operationLabel,
      previewLines: const ['伪造'],
      commitParams: const {'k': 'v'},
      safeLogSummary: '伪造删除',
    );
  }
}

/// proposal.riskLevel 超出工具 allowlist 最大 risk 的假工具。
class _EscalatedRiskTool extends _FakeWriteTool {
  _EscalatedRiskTool({required super.gateway, required super.policy, required super.confirmationStore, required super.unitOfWork});
  @override
  Future<AgentWriteProposal> propose(Map<String, Object?> arguments, AgentToolContext context) async {
    proposeCalled = true;
    return AgentWriteProposal(
      toolName: name,
      actionType: 'create_event',
      riskLevel: RiskLevel.critical, // allowlist 最大为 medium
      targetType: 'event',
      operationLabel: operationLabel,
      previewLines: const ['升级'],
      commitParams: const {'k': 'v'},
      safeLogSummary: '伪造升级',
    );
  }
}

/// 模拟提交失败：用于验证"先提交、成功后才放宽"的次序。
class _FailingCommitTool extends _FakeWriteTool {
  _FailingCommitTool({required super.gateway, required super.policy, required super.confirmationStore, required super.unitOfWork});
  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext context) async {
    commitCalled = true;
    return const AgentToolResult(status: AgentToolStatus.error, errorCode: 'commit_boom');
  }
}

AgentToolContext _ctx(String accountId, String runId) => AgentToolContext(
  accountId: accountId,
  runId: runId,
  clock: _FixedClock(),
  cancellation: CancellationSignal(),
  references: RunReferenceStore(runId: runId),
);

void main() {
  late AppDatabase db;
  late AgentPermissionPolicyService policy;
  late WriteConfirmationStore store;
  late _NoopGateway gateway;
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
    store = WriteConfirmationStore(
      policy: policy,
      unitOfWork: unitOfWork,
    );
    gateway = _NoopGateway();
  });

  tearDown(() => db.close());

  test('allow decision commits directly and logs agent action', () async {
    // create_event 默认 ask_first_time 首次需要确认；先记录首次确认使其放行。
    await policy.recordFirstConfirmation(accountId: 'a1', actionType: 'create_event', targetType: 'event');
    final tool = _FakeWriteTool(gateway: gateway, policy: policy, confirmationStore: store, unitOfWork: unitOfWork);
    final result = await tool.execute(const {}, _ctx('a1', 'r1'));
    expect(result.status, AgentToolStatus.success);
    expect(tool.commitCalled, isTrue);
    final logs = await db.actionLogsRepository.selectAll();
    expect(logs.any((l) => l.source == 'agent' && l.actionType == 'create_event'), isTrue);
  });

  test('deny decision returns permission_denied and never commits', () async {
    await policy.updatePolicy(accountId: 'a1', actionType: 'create_event',
        targetType: 'event', mode: ConfirmationMode.alwaysDeny,
        riskLevel: RiskLevel.medium, enabled: true, updatedBy: 'user');
    final tool = _FakeWriteTool(gateway: gateway, policy: policy, confirmationStore: store, unitOfWork: unitOfWork);
    final result = await tool.execute(const {}, _ctx('a1', 'r1'));
    expect(result.status, AgentToolStatus.error);
    expect(result.errorCode, 'permission_denied');
    expect(tool.commitCalled, isFalse);
  });

  test('confirm decision suspends and commits on resolve(approve)', () async {
    final tool = _FakeWriteTool(gateway: gateway, policy: policy, confirmationStore: store, unitOfWork: unitOfWork);
    final result = await tool.execute(const {}, _ctx('a1', 'r1'));
    expect(result.status, AgentToolStatus.needsUserAction);
    expect(result.userAction?.type, AgentUserActionType.writeConfirmation);
    expect(result.userAction?.writeProposal?.operationLabel, '新建日程');
    expect(tool.commitCalled, isFalse);

    final resumed = await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(resumed.status, AgentToolStatus.success);
    expect(tool.commitCalled, isTrue);
  });

  test('reject decision returns user_declined and never commits', () async {
    final tool = _FakeWriteTool(gateway: gateway, policy: policy, confirmationStore: store, unitOfWork: unitOfWork);
    final result = await tool.execute(const {}, _ctx('a1', 'r1'));
    final resumed = await store.resolve(result.userAction!.opaqueHandle, approve: false, remember: false);
    expect(resumed.status, AgentToolStatus.error);
    expect(resumed.errorCode, 'user_declined');
    expect(tool.commitCalled, isFalse);
  });

  test('confirm approval writes user confirm plus one agent business log', () async {
    final tool = _FakeWriteTool(gateway: gateway, policy: policy, confirmationStore: store, unitOfWork: unitOfWork);
    final result = await tool.execute(const {}, _ctx('a1', 'r1'));
    final resumed = await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(resumed.status, AgentToolStatus.success);
    final logs = await db.actionLogsRepository.selectAll();
    // 用户确认决策一行 + agent 业务成功一行。
    final confirm = logs.where((l) => l.actionType == 'agent_write_confirm');
    expect(confirm.length, 1);
    expect(confirm.single.source, 'user');
    expect(confirm.single.result, 'approved');
    final agent = logs.where((l) => l.source == 'agent' && l.actionType == 'create_event');
    expect(agent.length, 1);
    expect(agent.single.result, 'success');
  });

  test('remember relaxes the policy to always_allow', () async {
    final tool = _FakeWriteTool(gateway: gateway, policy: policy, confirmationStore: store, unitOfWork: unitOfWork);
    final result = await tool.execute(const {}, _ctx('a1', 'r1'));
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: true);
    expect(await policy.resolve(accountId: 'a1', actionType: 'create_event',
        targetType: 'event', riskLevel: RiskLevel.medium), PermissionDecision.allow);
  });

  test('forceConfirmation tool always confirms even when policy allows', () async {
    await policy.recordFirstConfirmation(accountId: 'a1', actionType: 'create_event', targetType: 'event');
    final tool = _ForceConfirmTool(gateway: gateway, policy: policy, confirmationStore: store, unitOfWork: unitOfWork);
    final result = await tool.execute(const {}, _ctx('a1', 'r1'));
    expect(result.status, AgentToolStatus.needsUserAction);
    expect(tool.commitCalled, isFalse);
  });

  test('cancel completes the pending invocation as cancelled', () async {
    final tool = _FakeWriteTool(gateway: gateway, policy: policy, confirmationStore: store, unitOfWork: unitOfWork);
    final result = await tool.execute(const {}, _ctx('a1', 'r1'));
    await result.pendingInvocation!.cancel();
    final resumed = await result.pendingInvocation!.result;
    expect(resumed.errorCode, 'cancelled');
    expect(tool.commitCalled, isFalse);
  });

  test('always_ask tool approval does not record a first confirmation', () async {
    // event_edit 默认 always_ask：首次确认后仍每次确认，记录 firstConfirmedAt
    // 无意义，不应写策略行（findings 5）。
    final tool = _AlwaysAskTool(gateway: gateway, policy: policy, confirmationStore: store, unitOfWork: unitOfWork);
    final result = await tool.execute(const {}, _ctx('a1', 'r1'));
    expect(result.status, AgentToolStatus.needsUserAction);
    final resumed = await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(resumed.status, AgentToolStatus.success);
    expect(
      (await policy.listPolicies('a1')).where((r) => r.actionType == 'event_edit'),
      isEmpty,
    );
  });

  test('resolution uses proposal actionType for distinct lifecycle actions', () async {
    // 同一工具产生 event_edit / event_delete 时，策略决议必须读取 proposal 的动态
    // actionType 而非工具静态 getter（静态 getter 恒为旧键 update_event）。
    //
    // 把 event_edit 显式放宽为 always_allow：proposal.actionType=event_edit 应命中
    // 该行而 allow（直接提交）；而 event_delete 无任何记录，默认 always_ask 仍应
    // confirm（暂停等待用户）。若决议误用静态 getter（update_event），则第一条也会
    // 因 update_event 默认 always_ask 而 confirm——从而证明用的是 proposal 动态键。
    await policy.updatePolicy(accountId: 'a1', actionType: 'event_edit', targetType: 'event',
        mode: ConfirmationMode.alwaysAllow, riskLevel: RiskLevel.high, enabled: true, updatedBy: 'user');

    final tool = _DynamicActionTool(gateway: gateway, policy: policy,
        confirmationStore: store, unitOfWork: unitOfWork);

    // event_edit：命中 always_allow 行 -> 直接提交（证明决议用 proposal.actionType）。
    final editResult = await tool.execute(const {}, _ctx('a1', 'r1'));
    expect(editResult.status, AgentToolStatus.success);
    expect(tool.commitCalled, isTrue);

    // event_delete：无行，默认 always_ask -> needsUserAction。
    tool.actionTypeOverride = 'event_delete';
    final delResult = await tool.execute(const {}, _ctx('a1', 'r1'));
    expect(delResult.status, AgentToolStatus.needsUserAction);
    expect(delResult.userAction?.type, AgentUserActionType.writeConfirmation);
  });

  test('old static update_event policy cannot relax the delete action', () async {
    // 旧的 update_event 策略覆盖最多作为 event_edit 的一版兼容 fallback，绝不能
    // 扩展到 event_delete/event_cancel/event_restore。这里把 event_edit 放宽为
    // always_allow，再验证 event_delete 仍凭其自身默认 always_ask 需要确认。
    await policy.updatePolicy(
        accountId: 'a1', actionType: 'event_edit', targetType: 'event',
        mode: ConfirmationMode.alwaysAllow,
        riskLevel: RiskLevel.high, enabled: true, updatedBy: 'user');

    final tool = _DynamicActionTool(gateway: gateway, policy: policy,
        confirmationStore: store, unitOfWork: unitOfWork);
    tool.actionTypeOverride = 'event_delete';
    final delResult = await tool.execute(const {}, _ctx('a1', 'r1'));
    expect(delResult.status, AgentToolStatus.needsUserAction,
        reason: 'event_edit 的放宽不得泄漏到 event_delete');
    // 仍可被这次标记为 event_delete 的首次确认放行（走它自己的键），而非被
    // event_edit 的 always_allow 自动放行。
    expect(tool.commitCalled, isFalse);
  });

  test('forged proposal outside the tool allowlist is rejected before approval', () async {
    // 伪造不在工具 allowlist 内的 proposal（actionType 不在声明组合）必须在审批前
    // 以安全错误拒绝：不触发策略查询、不产生业务提交。
    final tool = _ForgedProposalTool(
        gateway: gateway, policy: policy, confirmationStore: store, unitOfWork: unitOfWork);
    final result = await tool.execute(const {}, _ctx('a1', 'r1'));
    expect(result.status, AgentToolStatus.error);
    expect(result.errorCode, 'invalid_write_arguments');
    expect(tool.commitCalled, isFalse);
    // 未触发策略查询 / 未写任何审计或权限行。
    expect(await db.actionLogsRepository.selectAll(), isEmpty);
  });

  test('risk above the tool allowlist max is rejected before approval', () async {
    // proposal.riskLevel 超过工具声明的最大 risk 也在审批前拒绝（critical 不能被
    // 普通工具伪造）。
    final tool = _EscalatedRiskTool(
        gateway: gateway, policy: policy, confirmationStore: store, unitOfWork: unitOfWork);
    final result = await tool.execute(const {}, _ctx('a1', 'r1'));
    expect(result.status, AgentToolStatus.error);
    expect(result.errorCode, 'invalid_write_arguments');
    expect(tool.commitCalled, isFalse);
    expect(await db.actionLogsRepository.selectAll(), isEmpty);
  });

  test('failed commit does not relax the policy', () async {
    // 提交失败时不得放宽/记录首次确认（findings 4：先提交、成功后才放宽）。
    final tool = _FailingCommitTool(gateway: gateway, policy: policy, confirmationStore: store, unitOfWork: unitOfWork);
    final result = await tool.execute(const {}, _ctx('a1', 'r1'));
    final resumed = await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: true);
    expect(resumed.status, AgentToolStatus.error);
    expect(resumed.errorCode, 'commit_boom');
    // 放宽被跳过：create_event 仍是 ask_first_time，首次仍需确认。
    expect(await policy.resolve(accountId: 'a1', actionType: 'create_event',
        targetType: 'event', riskLevel: RiskLevel.medium), PermissionDecision.confirm);
  });
}
