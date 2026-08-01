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

/// 模拟 update_event：默认 always_ask（首次确认后仍每次确认）。
class _AlwaysAskTool extends _FakeWriteTool {
  _AlwaysAskTool({required super.gateway, required super.policy, required super.confirmationStore, required super.unitOfWork});
  @override
  String get actionType => 'update_event';
  @override
  RiskLevel get riskLevel => RiskLevel.high;
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
    // update_event 默认 always_ask：首次确认后仍每次确认，记录 firstConfirmedAt
    // 无意义，不应写策略行（findings 5）。
    final tool = _AlwaysAskTool(gateway: gateway, policy: policy, confirmationStore: store, unitOfWork: unitOfWork);
    final result = await tool.execute(const {}, _ctx('a1', 'r1'));
    expect(result.status, AgentToolStatus.needsUserAction);
    final resumed = await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(resumed.status, AgentToolStatus.success);
    expect(
      (await policy.listPolicies('a1')).where((r) => r.actionType == 'update_event'),
      isEmpty,
    );
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
