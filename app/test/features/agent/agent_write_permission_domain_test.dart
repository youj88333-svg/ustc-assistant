import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_permission_policy_service.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_permission_policy.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_write_proposal.dart';

class _FixedClock implements BeijingClock {
  @override
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);
}

void main() {
  test('ConfirmationMode/RiskLevel storage round-trips snake_case', () {
    expect(ConfirmationMode.alwaysAsk.storage, 'always_ask');
    expect(ConfirmationMode.askFirstTime.storage, 'ask_first_time');
    expect(ConfirmationMode.alwaysAllow.storage, 'always_allow');
    expect(ConfirmationMode.alwaysDeny.storage, 'always_deny');
    expect(RiskLevel.low.storage, 'low');
    expect(RiskLevel.critical.storage, 'critical');
    expect(ConfirmationModeStorage.fromStorage('ask_first_time'), ConfirmationMode.askFirstTime);
    expect(RiskLevelStorage.fromStorage('high'), RiskLevel.high);
  });

  test('AgentWriteProposal view strips commit params and local id', () {
    final proposal = AgentWriteProposal(
      toolName: 'create_event',
      actionType: 'create_event',
      riskLevel: RiskLevel.medium,
      targetType: 'event',
      operationLabel: '新建日程',
      previewLines: const ['明天 15:00 健身'],
      commitParams: const {'title': '健身'},
      targetId: 'local-9',
      safeLogSummary: '新建日程 明天 15:00 健身',
    );
    final view = proposal.toView();
    expect(view.operationLabel, '新建日程');
    expect(view.riskLevel, RiskLevel.medium);
    expect(view.rememberAllowed, isTrue);
    expect(view.previewLines, contains('明天 15:00 健身'));
  });

  test('schema v4 migrates the v3 policy/action_log tables', () async {
    final directory = await Directory.systemTemp.createTemp(
      'ustc-write-tools-v3-test',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = p.join(directory.path, 'legacy-v3.sqlite');
    final legacy = sqlite.sqlite3.open(path);
    legacy.execute('PRAGMA foreign_keys = ON');
    legacy.execute('''
      CREATE TABLE local_accounts (id TEXT NOT NULL PRIMARY KEY);
      INSERT INTO local_accounts VALUES ('acc-1');
      CREATE TABLE action_logs (
        id TEXT NOT NULL PRIMARY KEY,
        account_id TEXT,
        source TEXT NOT NULL,
        action_type TEXT NOT NULL,
        result TEXT NOT NULL,
        safe_summary TEXT NOT NULL,
        occurred_at INTEGER NOT NULL
      );
      CREATE TABLE agent_permission_policies (
        id TEXT NOT NULL PRIMARY KEY,
        account_id TEXT,
        action_type TEXT NOT NULL,
        policy TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      );
      PRAGMA user_version = 3;
    ''');
    legacy.close();

    final db = AppDatabase(NativeDatabase(File(path)));
    await db.customStatement('SELECT 1'); // 触发 onUpgrade

    await db.actionLogsRepository.append(
      accountId: null,
      source: 'agent',
      actionType: 'create_event',
      result: 'success',
      safeSummary: '新建日程',
      riskLevel: 'medium',
      occurredAt: 1,
    );
    final logRow = await db.select(db.actionLogs).getSingle();
    expect(logRow.riskLevel, 'medium');

    await db.into(db.agentPermissionPolicies).insert(
          AgentPermissionPoliciesCompanion.insert(
            id: 'p-1',
            accountId: 'acc-1',
            actionType: 'create_event',
            targetType: const Value('event'),
            confirmationMode: 'always_ask',
            riskLevel: const Value('medium'),
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    final policyRow = await db.select(db.agentPermissionPolicies).getSingle();
    expect(policyRow.confirmationMode, 'always_ask');
    expect(policyRow.targetType, 'event');
    await db.close();
  });

  test('move_jw_course_day policy is critical, always-ask, and not relaxable', () {
    // 单一映射：策略行键与权限工具共用同一份清单。
    expect(AgentPermissionPolicyService.kPolicyTargetMap['move_jw_course_day'],
        'jw_day_move');
    expect(AgentPermissionPolicyService.targetTypeFor('move_jw_course_day'),
        'jw_day_move');
    // 用户/模型不可放宽：不在可调整动作集合里。
    expect(AgentPermissionPolicyService.kAgentPolicyActionTypes,
        isNot(contains('move_jw_course_day')),
        reason: 'critical 整日移动不可通过 update_permission_policy 放宽');
    // 默认 always_ask + critical。
    expect(AgentPermissionPolicyService.defaultMode('move_jw_course_day'),
        ConfirmationMode.alwaysAsk);
    expect(AgentPermissionPolicyService.defaultRisk('move_jw_course_day'),
        RiskLevel.critical);
  });

  test('markAlwaysAllow refuses the critical move action before touching the DB', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final service =
        AgentPermissionPolicyService(database: db, clock: _FixedClock());
    await expectLater(
      service.markAlwaysAllow(
          accountId: 'acc-1',
          actionType: 'move_jw_course_day',
          targetType: 'jw_day_move'),
      throwsStateError,
      reason: 'critical 动作拒绝放宽为 always_allow（「以后不再确认」）',
    );
    // 未写任何策略行。
    expect(await db.select(db.agentPermissionPolicies).get(), isEmpty);
  });
}
