import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_permission_policy_service.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_permission_policy.dart';

class _FixedClock implements BeijingClock {
  _FixedClock(this._epochMs);
  int _epochMs;
  @override
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(_epochMs);
  void advance(int ms) => _epochMs += ms;
}

void main() {
  late AppDatabase db;
  late AgentPermissionPolicyService service;
  late _FixedClock clock;

  Future<void> seedAccount(String accountId) => db
      .into(db.localAccounts)
      .insert(
        LocalAccountsCompanion.insert(
          id: accountId,
          maskedHint: 'PB****0000',
          isActive: const Value(true),
          createdAt: 1,
          updatedAt: 1,
        ),
      );

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    clock = _FixedClock(1_700_000_000_000);
    service = AgentPermissionPolicyService(database: db, clock: clock);
    await seedAccount('a1');
  });

  tearDown(() => db.close());

  test('create_event default ask_first_time confirms then allows after first', () async {
    expect(await service.resolve(accountId: 'a1', actionType: 'create_event',
        targetType: 'event', riskLevel: RiskLevel.medium), PermissionDecision.confirm);
    await service.recordFirstConfirmation(accountId: 'a1', actionType: 'create_event', targetType: 'event');
    expect(await service.resolve(accountId: 'a1', actionType: 'create_event',
        targetType: 'event', riskLevel: RiskLevel.medium), PermissionDecision.allow);
  });

  test('update_event and update_permission_policy always confirm', () async {
    expect(await service.resolve(accountId: 'a1', actionType: 'update_event',
        targetType: 'event', riskLevel: RiskLevel.high), PermissionDecision.confirm);
    expect(await service.resolve(accountId: 'a1', actionType: 'update_permission_policy',
        targetType: 'create_event', riskLevel: RiskLevel.critical), PermissionDecision.confirm);
  });

  test('always_allow and always_deny are honored', () async {
    await service.updatePolicy(accountId: 'a1', actionType: 'create_event',
        targetType: 'event', mode: ConfirmationMode.alwaysAllow,
        riskLevel: RiskLevel.medium, enabled: true, updatedBy: 'user');
    expect(await service.resolve(accountId: 'a1', actionType: 'create_event',
        targetType: 'event', riskLevel: RiskLevel.medium), PermissionDecision.allow);
    await service.updatePolicy(accountId: 'a1', actionType: 'create_event',
        targetType: 'event', mode: ConfirmationMode.alwaysDeny,
        riskLevel: RiskLevel.medium, enabled: true, updatedBy: 'user');
    expect(await service.resolve(accountId: 'a1', actionType: 'create_event',
        targetType: 'event', riskLevel: RiskLevel.medium), PermissionDecision.deny);
  });

  test('markAlwaysAllow refuses critical and writes action log', () async {
    await expectLater(service.markAlwaysAllow(accountId: 'a1', actionType: 'update_permission_policy',
        targetType: 'create_event'), throwsStateError);
    await service.markAlwaysAllow(accountId: 'a1', actionType: 'create_event', targetType: 'event');
    final logs = await db.actionLogsRepository.selectAll();
    expect(logs.any((l) => l.source == 'user' && l.actionType == 'update_permission_policy'), isTrue);
  });

  test('listPolicies and resetDefaults', () async {
    await service.updatePolicy(accountId: 'a1', actionType: 'create_event',
        targetType: 'event', mode: ConfirmationMode.alwaysAllow,
        riskLevel: RiskLevel.medium, enabled: true, updatedBy: 'user');
    expect((await service.listPolicies('a1')).length, 1);
    await service.resetDefaults('a1');
    expect(await service.listPolicies('a1'), isEmpty);
  });

  test('logAgentWrite appends an agent action log with risk level', () async {
    await service.logAgentWrite(accountId: 'a1', actionType: 'create_event',
        riskLevel: 'medium', result: 'success', safeSummary: '新建日程 明天 15:00 健身');
    final logs = await db.actionLogsRepository.selectAll();
    expect(logs.single.source, 'agent');
    expect(logs.single.riskLevel, 'medium');
    expect(logs.single.actionType, 'create_event');
  });

  test('agent-initiated updatePolicy writes no user log (agent log covers it)', () async {
    // Agent 发起的策略变更由 AgentWriteTool 基类统一写 source='agent' 日志，
    // updatePolicy 不重复写 source='user'，避免「最近权限变更」出现双条（findings 3）。
    await service.updatePolicy(accountId: 'a1', actionType: 'create_event',
        targetType: 'event', mode: ConfirmationMode.alwaysAllow,
        riskLevel: RiskLevel.medium, enabled: true, updatedBy: 'agent');
    expect(await db.actionLogsRepository.selectAll(), isEmpty);
  });

  test('resetDefaults writes a reset action log', () async {
    await service.updatePolicy(accountId: 'a1', actionType: 'create_event',
        targetType: 'event', mode: ConfirmationMode.alwaysAllow,
        riskLevel: RiskLevel.medium, enabled: true, updatedBy: 'user');
    await service.resetDefaults('a1');
    final logs = await db.actionLogsRepository.selectAll();
    expect(logs.any((l) => l.actionType == 'reset_permission_policy'), isTrue);
    expect(logs.last.source, 'user');
  });
}
