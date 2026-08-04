import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_permission_policy_service.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_permission_policy.dart';
import 'package:ustc_assistant_app/features/tasks/application/undo_service.dart';

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

  test('ask_first_time first confirmation writes a permission-change log', () async {
    // ask_first_time 首次确认从「每次确认」放宽为「首次确认后放行」，是真实权限
    // 模式变更，必须写 update_permission_policy 日志（与 firstConfirmedAt 同事务）。
    await service.recordFirstConfirmation(accountId: 'a1', actionType: 'create_event', targetType: 'event');
    final logs = await db.actionLogsRepository.selectAll();
    expect(
      logs.any((l) =>
          l.source == 'user' &&
          l.actionType == 'update_permission_policy' &&
          l.result == 'success'),
      isTrue,
    );
  });

  test('markAlwaysAllow logs safe summary action(target) -> always_allow', () async {
    await service.markAlwaysAllow(accountId: 'a1', actionType: 'create_event', targetType: 'event');
    final logs = await db.actionLogsRepository.selectAll();
    expect(
      logs.any((l) =>
          l.actionType == 'update_permission_policy' &&
          l.safeSummary == 'create_event(event) -> always_allow'),
      isTrue,
    );
  });

  test('kPolicyTargetMap and kAgentPolicyActionTypes are consistent', () {
    // 每个可调整动作都有唯一的 target_type 映射，且都在可调整集合内。
    for (final action in AgentPermissionPolicyService.kAgentPolicyActionTypes) {
      expect(AgentPermissionPolicyService.kPolicyTargetMap.containsKey(action), isTrue,
          reason: '$action must have a policy target type');
      expect(AgentPermissionPolicyService.targetTypeFor(action), isNotEmpty);
    }
    // update_permission_policy 自身不可被调整（critical 恒人工确认）。
    expect(AgentPermissionPolicyService.kAgentPolicyActionTypes.contains('update_permission_policy'), isFalse);
  });

  test('kPermissionActions covers Spec §17.3 action keys and shared registry', () {
    const requiredKeys = {
      'event_cancel', 'event_delete', 'event_restore',
      'task_cancel', 'task_delete', 'task_restore', 'task_complete',
      'plan_block_cancel', 'plan_block_delete', 'plan_block_restore',
      'delete_schedule_relation', 'delete_schedule_relation_rule',
      'clear_reminder_offsets', 'clear_all_reminders',
      'clear_event_overlay_fields', 'clear_all_event_overlay', 'clear_course_overlay',
      'unlink_task_event', 'reset_permission_policy', 'undo_last_action',
      'event_edit', 'create_event', 'create_task', 'plan_task',
      'create_user_overlay', 'record_attendance_decision', 'record_listening_mode',
      'create_schedule_relation', 'set_reminder', 'move_jw_course_day',
      'update_permission_policy',
    };
    for (final key in requiredKeys) {
      expect(AgentPermissionPolicyService.kPermissionActions.containsKey(key), isTrue,
          reason: 'registry must register $key');
      final a = AgentPermissionPolicyService.kPermissionActions[key]!;
      expect(a.key, key);
      expect(a.targetType, isNotEmpty);
    }
    // 每个注册动作的 defaultMode/defaultRisk/label 都可由单个查询消费（无平行 list）。
    expect(AgentPermissionPolicyService.defaultMode('event_cancel'), ConfirmationMode.alwaysAsk);
    expect(AgentPermissionPolicyService.defaultRisk('event_delete'), RiskLevel.high);
    expect(AgentPermissionPolicyService.defaultRisk('event_restore'), RiskLevel.medium);
    expect(AgentPermissionPolicyService.defaultMode('event_restore'), ConfirmationMode.askFirstTime);
    expect(AgentPermissionPolicyService.labelFor('event_cancel'), isNotEmpty);
    // 兼容/预留键保留：旧 update_event 与 move_plan_block 仍在注册表中。
    expect(AgentPermissionPolicyService.targetTypeFor('update_event'), 'event');
    expect(AgentPermissionPolicyService.targetTypeFor('move_plan_block'), 'plan_block');
  });

  test('non-relaxable actions reject markAlwaysAllow and are excluded from the tool', () async {
    // critical / 锁定动作（reset_permission_policy、move_jw_course_day、event_edit？
    // 不——event_edit 是 relaxable）不在可调整动作集合，且 markAlwaysAllow 拒绝。
    for (final key in const ['reset_permission_policy', 'move_jw_course_day', 'update_permission_policy']) {
      expect(AgentPermissionPolicyService.kPermissionActions[key]!.relaxable, isFalse,
          reason: '$key must not be relaxable');
      await expectLater(
        service.markAlwaysAllow(accountId: 'a1', actionType: key,
            targetType: AgentPermissionPolicyService.targetTypeFor(key)),
        throwsStateError,
        reason: '$key must refuse auto-allow',
      );
    }
    expect(AgentPermissionPolicyService.kPermissionActions['event_edit']!.relaxable, isTrue);
  });

  test('event_edit resolves new-style row and falls back to legacy update_event row only for event_edit',
      () async {
    // 新键 event_edit 优先：先写一条 event_edit 行，其模式生效。
    await service.updatePolicy(accountId: 'a1', actionType: 'event_edit', targetType: 'event',
        mode: ConfirmationMode.alwaysAllow, riskLevel: RiskLevel.high, enabled: true, updatedBy: 'user');
    expect(await service.resolve(accountId: 'a1', actionType: 'event_edit',
        targetType: 'event', riskLevel: RiskLevel.high), PermissionDecision.allow);

    // 清空后再写旧键 update_event：event_edit 作为兼容 fallback 读取它。
    await service.resetDefaults('a1');
    await service.updatePolicy(accountId: 'a1', actionType: 'update_event', targetType: 'event',
        mode: ConfirmationMode.alwaysAllow, riskLevel: RiskLevel.high, enabled: true, updatedBy: 'user');
    expect(await service.resolve(accountId: 'a1', actionType: 'event_edit',
        targetType: 'event', riskLevel: RiskLevel.high), PermissionDecision.allow,
        reason: '旧 update_event 行仅作为 event_edit 的兼容 fallback');

    // 关键：该兼容行绝不能泄漏到 event_delete / event_cancel / event_restore。
    for (final key in const ['event_delete', 'event_cancel', 'event_restore']) {
      expect(await service.resolve(accountId: 'a1', actionType: key,
          targetType: 'event', riskLevel: AgentPermissionPolicyService.defaultRisk(key)),
          PermissionDecision.confirm,
          reason: '$key must not inherit the legacy update_event override');
    }
  });

  test('recentPermissionChanges includes update and reset, newest first, honors limit',
      () async {
    await service.updatePolicy(accountId: 'a1', actionType: 'create_event',
        targetType: 'event', mode: ConfirmationMode.alwaysAllow,
        riskLevel: RiskLevel.medium, enabled: true, updatedBy: 'user');
    expect((await service.recentPermissionChanges('a1')).length, 1);
    clock.advance(1000); // 保证 reset 的 occurredAt 严格晚于 update
    await service.resetDefaults('a1');
    final recent = await service.recentPermissionChanges('a1');
    expect(recent.length, 2);
    expect(recent.map((l) => l.actionType).toSet(),
        {'update_permission_policy', 'reset_permission_policy'});
    // 最新优先：reset 在 update 之后发生。
    expect(recent.first.actionType, 'reset_permission_policy');
    expect(recent.first.occurredAt, greaterThanOrEqualTo(recent.last.occurredAt));
    // limit 生效。
    expect((await service.recentPermissionChanges('a1', limit: 1)).length, 1);
  });

  test('recentPermissionChanges is account-scoped', () async {
    await db.into(db.localAccounts).insert(
      LocalAccountsCompanion.insert(
        id: 'a2', maskedHint: 'PB****0001', isActive: const Value(true),
        createdAt: 1, updatedAt: 1,
      ),
    );
    await service.updatePolicy(accountId: 'a1', actionType: 'create_event',
        targetType: 'event', mode: ConfirmationMode.alwaysAllow,
        riskLevel: RiskLevel.medium, enabled: true, updatedBy: 'user');
    await (AgentPermissionPolicyService(database: db, clock: clock).updatePolicy(
      accountId: 'a2', actionType: 'create_event',
      targetType: 'event', mode: ConfirmationMode.alwaysAllow,
      riskLevel: RiskLevel.medium, enabled: true, updatedBy: 'user',
    ));
    expect((await service.recentPermissionChanges('a1')).every((l) => l.accountId == 'a1'), isTrue);
    expect((await service.recentPermissionChanges('a2')).length, 1);
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

  group('resetPolicy single override restore', () {
    test('removes exactly one override and clears first-confirmation, '
        'returning the action to its default', () async {
      // Create an override that also carries a first-confirmation timestamp.
      await service.updatePolicy(accountId: 'a1', actionType: 'create_event',
          targetType: 'event', mode: ConfirmationMode.askFirstTime,
          riskLevel: RiskLevel.medium, enabled: true, updatedBy: 'user');
      await service.recordFirstConfirmation(
          accountId: 'a1', actionType: 'create_event', targetType: 'event');

      // Another unrelated override must survive.
      await service.updatePolicy(accountId: 'a1', actionType: 'set_reminder',
          targetType: 'event', mode: ConfirmationMode.alwaysAllow,
          riskLevel: RiskLevel.medium, enabled: true, updatedBy: 'user');

      final outcome = await service.resetPolicy(
          accountId: 'a1', actionType: 'create_event', targetType: 'event');
      expect(outcome, ResetPolicyOutcome.reset);

      final remaining = await service.listPolicies('a1');
      expect(remaining, hasLength(1));
      expect(remaining.single.actionType, 'set_reminder');
      // The removed action now resolves to its default (ask_first_time asks).
      expect(await service.resolve(accountId: 'a1', actionType: 'create_event',
          targetType: 'event', riskLevel: RiskLevel.medium), PermissionDecision.confirm);
      // A reset action-log entry was written.
      final logs = await db.actionLogsRepository.selectAll();
      expect(logs.any((l) => l.actionType == 'reset_permission_policy'), isTrue);
    });

    test('no override -> already_default with no log and no undo', () async {
      final undo = UndoService(database: db, accountId: 'a1');
      final svc = AgentPermissionPolicyService(database: db, clock: clock,
          undoRecorder: undo);
      expect(await db.actionLogsRepository.selectAll(), isEmpty);
      final outcome = await svc.resetPolicy(
          accountId: 'a1', actionType: 'create_event', targetType: 'event');
      expect(outcome, ResetPolicyOutcome.alreadyDefault);
      // No ActionLog, no undo slot.
      expect(await db.actionLogsRepository.selectAll(), isEmpty);
      expect(await undo.canUndo(), isFalse);
    });

    test('resetPolicy atomic consistency: composite undo restores the row',
        () async {
      await service.updatePolicy(accountId: 'a1', actionType: 'create_event',
          targetType: 'event', mode: ConfirmationMode.alwaysAllow,
          riskLevel: RiskLevel.medium, enabled: true, updatedBy: 'user');
      final undo = UndoService(database: db, accountId: 'a1');
      final svc = AgentPermissionPolicyService(database: db, clock: clock,
          undoRecorder: undo);
      await svc.resetPolicy(
          accountId: 'a1', actionType: 'create_event', targetType: 'event');
      expect(await svc.listPolicies('a1'), isEmpty);

      await undo.undo();

      expect((await svc.listPolicies('a1')).single.actionType, 'create_event');
    });

    test('cannot reset the tool\'s own critical guard', () async {
      for (final key in const ['reset_permission_policy', 'update_permission_policy', 'move_jw_course_day']) {
        await expectLater(
          service.resetPolicy(accountId: 'a1', actionType: key,
              targetType: AgentPermissionPolicyService.targetTypeFor(key)),
          throwsStateError,
          reason: '$key must not be reset',
        );
      }
      expect(kNonResetableActions,
          containsAll(const ['reset_permission_policy', 'update_permission_policy', 'move_jw_course_day']));
    });

    test('resetPolicy is account-scoped', () async {
      await service.updatePolicy(accountId: 'a1', actionType: 'create_event',
          targetType: 'event', mode: ConfirmationMode.alwaysAllow,
          riskLevel: RiskLevel.medium, enabled: true, updatedBy: 'user');
      await db.into(db.localAccounts).insert(
        LocalAccountsCompanion.insert(
          id: 'a2', maskedHint: 'PB****0001', isActive: const Value(true),
          createdAt: 1, updatedAt: 1,
        ),
      );
      final other = AgentPermissionPolicyService(database: db, clock: clock);
      // a2 has no override -> already default; a1's row is untouched.
      expect(await other.resetPolicy(accountId: 'a2', actionType: 'create_event',
          targetType: 'event'), ResetPolicyOutcome.alreadyDefault);
      expect((await service.listPolicies('a1')).single.actionType, 'create_event');
    });
  });
}
