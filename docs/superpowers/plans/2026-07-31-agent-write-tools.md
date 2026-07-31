# Agent 写工具（审批门）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为校园 Agent 增加 10 个受控本地写工具，全部写操作经"审批门"按风险分级确认，确认交互为聊天内联确认卡，权限策略可在设置页管理。

**Architecture:** 写工具实现 `AgentWriteTool` 抽象基类（`propose` 产提案不碰库 / `commit` 经 `AgentWriteGateway` 写库）；基类的 `execute` 统一执行"提案 → `AgentPermissionPolicyService.resolve` → 直接提交 / 拒绝 / 暂停等待用户"，暂停复用现有 `needsUserAction` 机制（`waitingForUser` 状态 + `AgentUserActionType.writeConfirmation`）。`AgentWriteGateway` 包装现有 `CalendarEventService` / `TaskLifecycleService` / `PlanBlockService` / `OverlayService` / `RecurrenceService` / `ReminderOverrideService`。

**Tech Stack:** Flutter / Dart, Drift。数据库迁移 schemaVersion 3→4。沿用只读 Agent 分层（domain 平台无关 / application 编排 / data 持久化 / presentation UI）。

## Global Constraints

- 实现使用 **conda 环境 `ustc_assistant`**，不得修改 base 环境；时间统一 `Asia/Shanghai`，工具一律用 `AgentToolContext.clock`。
- **写网关只包装本地业务 Service，不新增任何学校/外部写通道**；二课报名边界、prompt-injection 防御、工具白名单不变。
- 模型永远接触不到 DB 主键：写目标一律用 `ref_*`，`RunReferenceStore` 在 run 内解析；`AgentWriteProposal.targetId` 只在 run 内网关侧使用，绝不出现在工具结果或模型请求。
- 写操作目标只允许个人数据：个人事件（`source='user'`）、账户内 Task/PlanBlock、个人 overlay。`update_event` 对 `course`/`exam`/`second_class` 事件返回引导错误（引导使用 overlay 工具），不直接改。
- 每个写提交写一条 `source='agent'` 的 `ActionLog`（含 `riskLevel` + 安全预览）；底层 Service 自身 `source='user'` 日志保留。权限放宽（`remember` 或设置页变更）必须写 `ActionLog`。
- 待确认提案只存活于当前 run，不跨 run 持久化；一次运行最多一个待确认提案，`writeConfirmation` 与 `youngLogin` 天然互斥（共用同一 `_PausedRun` 槽）。
- **Drift 表变更必须重新生成代码**（`app/` 下运行 `dart run build_runner build --delete-conflicting-outputs`），且只在 worktree 内运行；不要在主工作区直接跑代码生成。
- 完成各 Task 前先读 `AGENTS.md`、`docs/schedule-data-model.md` §10/§11/§15、`docs/superpowers/specs/2026-07-31-agent-write-tools-design.md`。
- 每个 Task 结束前跑聚焦测试（本 Task 的新测试 + 相邻既有测试）并单独提交；提交信息遵循项目风格。

### 相对 spec 的实现级细化（最小实现取舍）

1. **审批门复用 `needsUserAction` 机制**：暂停用 `AgentRunState.waitingForUser` + `AgentUserActionType.writeConfirmation`，而不是新增独立状态。这与 spec §5 的状态机目标一致（互斥、暂停不发新请求、停止作废提案），实现上少一套状态机。
2. **`set_reminder` 本轮仅支持 event 目标**（经 `ReminderOverrideService.setEventOffsets`）；task/plan_block 目标返回 `unsupported_target` 错误。
3. **`create_schedule_relation` 本轮仅支持一对 event/plan_block 的 `conflict` 关系**（现有 `schedule_relations` 表 CHECK 只允许 `conflict` / `exam_for_course` 形态）；`conflictState`（`conflict`/`no_conflict`）+ `reason` 表达用户意图。数据模型的其他 relation_type 因表约束暂不暴露。
4. **写网关默认用 `NoopUndoRecorder`**（Agent 写入不占用一步撤回槽）。
5. **`update_event` 的 only_this / whole_series 只对个人重复系列有意义**（`personalSeriesId != null`）；非重复个人事件直接 `CalendarEventService.edit`；对 `course_series`（课程）出勤/听讲标注走 `create_user_overlay` 而非 `update_event`。
6. **低风险创建类（ask_first_time 放行后）直接执行，不出现确认卡**；确认卡只在需要确认时出现。

---
---

### Task 1: AgentPermissionPolicy 领域模型 + AgentWriteProposal + 表迁移（schema 4）

**Files:**
- Create: `app/lib/features/agent/domain/agent_permission_policy.dart`
- Create: `app/lib/features/agent/domain/agent_write_proposal.dart`
- Modify: `app/lib/core/database/tables/operation_tables.dart`（`ActionLogs` 加 `riskLevel`；`AgentPermissionPolicies` 扩展为完整 schema）
- Modify: `app/lib/core/database/app_database.dart`（`schemaVersion` 3→4、migration、`ActionLogRepository.append` 加 `riskLevel`）
- Modify: `app/lib/core/database/app_database.g.dart`（由 codegen 重新生成）
- Test: `app/test/features/agent/agent_write_permission_domain_test.dart`

**Interfaces:**
- Consumes: 现有 `AppDatabase`、`LocalAccounts`。
- Produces: `ConfirmationMode`、`RiskLevel`、`PermissionDecision`、`AgentPermissionPolicyRecord`（供 Task 2 策略服务）；`AgentWriteProposal` / `AgentWriteProposalView`（供 Task 3+ 写工具与 UI）。

- [ ] **Step 1: 写失败的领域模型测试**

`app/test/features/agent/agent_write_permission_domain_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_permission_policy.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_write_proposal.dart';

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
}
```

- [ ] **Step 2: 运行测试确认失败**

Run（在 `app/` 下）：`flutter test test/features/agent/agent_write_permission_domain_test.dart`
Expected: FAIL，`ConfirmationMode` 等符号未定义。

- [ ] **Step 3: 创建领域模型**

`app/lib/features/agent/domain/agent_permission_policy.dart`：

```dart
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
```

`app/lib/features/agent/domain/agent_write_proposal.dart`：

```dart
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
```

- [ ] **Step 4: 运行测试确认通过**

Run（在 `app/` 下）：`flutter test test/features/agent/agent_write_permission_domain_test.dart`
Expected: PASS

- [ ] **Step 5: 迁移表结构（operation_tables.dart + app_database.dart）**

`app/lib/core/database/tables/operation_tables.dart` 的 `ActionLogs`：

```dart
class ActionLogs extends Table {
  TextColumn get id => text()();
  TextColumn get accountId => text().nullable().references(
    LocalAccounts, #id, onDelete: KeyAction.setNull)();
  TextColumn get source => text()();
  TextColumn get actionType => text()();
  TextColumn get result => text()();
  TextColumn get safeSummary => text()();
  TextColumn get riskLevel => text().nullable()();   // 新增
  IntColumn get occurredAt => integer()();

  @override
  String get tableName => 'action_logs';
  @override
  Set<Column<Object>> get primaryKey => {id};
}
```

`AgentPermissionPolicies`（完整 schema，替换原 `policy` 列）：

```dart
class AgentPermissionPolicies extends Table {
  TextColumn get id => text()();
  TextColumn get accountId =>
      text().references(LocalAccounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get actionType => text()();
  TextColumn get targetType => text().withDefault(const Constant('*'))();
  TextColumn get confirmationMode => text()();
  TextColumn get riskLevel => text().withDefault(const Constant('medium'))();
  TextColumn get scope => text().withDefault(const Constant('user_default'))();
  TextColumn get enabled => boolean().withDefault(const Constant(true))();
  IntColumn get firstConfirmedAt => integer().nullable()();
  IntColumn get lastConfirmedAt => integer().nullable()();
  IntColumn get expiresAt => integer().nullable()();
  TextColumn get updatedBy => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  String get tableName => 'agent_permission_policies';
  @override
  Set<Column<Object>> get primaryKey => {id};
  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {accountId, actionType, targetType},
  ];
}
```

`app/lib/core/database/app_database.dart`：

```dart
@override
int get schemaVersion => 4;
```

onUpgrade 追加（在 `from < 3` 块之后）：

```dart
if (from < 4) {
  await migrator.addColumn(actionLogs, actionLogs.riskLevel);
  // v3 占位表从未被使用（无行、无读取）；直接重建为完整 schema。
  await migrator.dropTable(agentPermissionPolicies);
  await migrator.createTable(agentPermissionPolicies);
}
```

`ActionLogRepository.append` 增加 `String? riskLevel` 参数，`ActionLogsCompanion.insert(...)` 里加 `riskLevel: Value(riskLevel)`（放在 `safeSummary` 之后）。

然后运行 codegen：

```bash
cd app
dart run build_runner build --delete-conflicting-outputs
```

- [ ] **Step 6: 写并跑迁移测试（v3 旧表 → v4 升级）**

在 `app/test/features/agent/agent_write_permission_domain_test.dart` 追加 import 与测试：

```dart
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';

test('schema v4 migrates the v3 policy/action_log tables', () async {
  final executor = NativeDatabase.memory();
  await executor.ensureOpen(QueryExecutorUser.forOpen());
  await executor.runCustom('''
    CREATE TABLE local_accounts (id TEXT NOT NULL PRIMARY KEY);
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
  final db = AppDatabase(executor);
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
  final logRow = (await db.select(db.actionLogs)).getSingle();
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
  final policyRow = (await db.select(db.agentPermissionPolicies)).getSingle();
  expect(policyRow.confirmationMode, 'always_ask');
  expect(policyRow.targetType, 'event');
  await db.close();
});
```

Run：`flutter test test/features/agent/agent_write_permission_domain_test.dart`
Expected: PASS（migration 后新列可读写）。

- [ ] **Step 7: 提交**

```bash
git add app/lib/features/agent/domain/agent_permission_policy.dart \
        app/lib/features/agent/domain/agent_write_proposal.dart \
        app/lib/core/database/tables/operation_tables.dart \
        app/lib/core/database/app_database.dart \
        app/lib/core/database/app_database.g.dart \
        app/test/features/agent/agent_write_permission_domain_test.dart
git commit -m "feat(agent): add write policy domain model and schema v4 migration"
```
---

### Task 2: AgentPermissionPolicyService（策略查询/决议/变更）

**Files:**
- Create: `app/lib/features/agent/application/agent_permission_policy_service.dart`
- Test: `app/test/features/agent/agent_permission_policy_service_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `ConfirmationMode`/`RiskLevel`/`PermissionDecision`/`AgentPermissionPolicyRecord`，`AppDatabase`，`BeijingClock`。
- Produces（供 Task 3+ 的审批门、写工具、设置页、组合接线使用）：
  - `Future<PermissionDecision> resolve({required String accountId, required String actionType, required String targetType, required RiskLevel riskLevel})`
  - `Future<void> updatePolicy({required String accountId, required String actionType, required String targetType, required ConfirmationMode mode, required RiskLevel riskLevel, required bool enabled, required String updatedBy})`
  - `Future<void> recordFirstConfirmation({required String accountId, required String actionType, required String targetType})`
  - `Future<void> markAlwaysAllow({required String accountId, required String actionType, required String targetType})`（拒绝 critical）
  - `Future<void> logAgentWrite({required String accountId, required String actionType, required String riskLevel, required String result, required String safeSummary})`
  - `Future<List<AgentPermissionPolicyRecord>> listPolicies(String accountId)`
  - `Future<void> resetDefaults(String accountId)`
  - `static ConfirmationMode defaultMode(String actionType)` / `static RiskLevel defaultRisk(String actionType)`

- [ ] **Step 1: 写失败的策略服务测试**

`app/test/features/agent/agent_permission_policy_service_test.dart`：

```dart
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

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    clock = _FixedClock(1_700_000_000_000);
    service = AgentPermissionPolicyService(database: db, clock: clock);
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
}
```

- [ ] **Step 2: 运行测试确认失败**

Run（在 `app/` 下）：`flutter test test/features/agent/agent_permission_policy_service_test.dart`
Expected: FAIL，`AgentPermissionPolicyService` 未定义。

- [ ] **Step 3: 实现策略服务**

`app/lib/features/agent/application/agent_permission_policy_service.dart`：

```dart
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../../core/time/beijing_clock.dart';
import '../domain/agent_permission_policy.dart';
import '../domain/agent_write_proposal.dart';

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
            targetType: const Value(targetType),
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
            targetType: const Value(targetType),
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
```

- [ ] **Step 4: 运行测试确认通过**

Run（在 `app/` 下）：`flutter test test/features/agent/agent_permission_policy_service_test.dart`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add app/lib/features/agent/application/agent_permission_policy_service.dart \
        app/test/features/agent/agent_permission_policy_service_test.dart
git commit -m "feat(agent): add permission policy service with lazy defaults and action log"
```
---

### Task 3: AgentWriteGateway 接口 + AgentWriteTool 基类（审批门）+ WriteConfirmationStore

**Files:**
- Create: `app/lib/features/agent/domain/agent_write_gateway.dart`（接口 + `EventWriteIdentity`）
- Create: `app/lib/features/agent/application/agent_write_tool.dart`（基类 + `WriteConfirmationStore`）
- Modify: `app/lib/features/agent/domain/agent_write_proposal.dart`（加 `copyWith`）
- Modify: `app/lib/features/agent/domain/agent_tool.dart`（`AgentUserActionType.writeConfirmation`、`AgentUserAction.writeProposal`、`AgentUserActionMetadata.writeProposal`）
- Test: `app/test/features/agent/agent_write_tool_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `AgentWriteProposal`，Task 2 的 `AgentPermissionPolicyService`，现有 `AgentTool`/`AgentToolContext`/`AgentToolResult`/`AgentUserAction`/`AgentPendingToolInvocation`、`RunReferenceStore`，现有业务领域类型（`PersonalEvent`、`RecurrenceRule`、`OccurrenceOverride`、`SeriesEditImpact`、`TaskItem`、`PlanBlockItem`、`OverlayMutation`、`AttendanceDecision`、`ListeningMode`、`TaskImportance`、`PlanBlockStatus`）。
- Produces（供 Task 4-9 的网关实现与写工具使用）：
  - `AgentWriteGateway` 接口方法与 `EventWriteIdentity`；
  - `AgentWriteTool` 抽象基类（子类只需实现 `propose`/`commit` + 工具元数据 getter）；
  - `WriteConfirmationStore`（`register` / `resolve(handle,{approve,remember})` / `cancel`）。

- [ ] **Step 1: 写失败的基类审批门测试**

`app/test/features/agent/agent_write_tool_test.dart`：

```dart
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_permission_policy_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_write_tool.dart';
import 'package:ustc_assistant_app/features/agent/application/cancellation_signal.dart';
import 'package:ustc_assistant_app/features/agent/application/run_reference_store.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_permission_policy.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_tool.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_write_gateway.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_write_proposal.dart';

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
  _FakeWriteTool({required super.gateway, required super.policy, required super.confirmationStore});

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
  _ForceConfirmTool({required super.gateway, required super.policy, required super.confirmationStore});
  @override
  bool get forceConfirmation => true;
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

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    policy = AgentPermissionPolicyService(database: db, clock: _FixedClock());
    store = WriteConfirmationStore(policy: policy);
    gateway = _NoopGateway();
  });

  tearDown(() => db.close());

  test('allow decision commits directly and logs agent action', () async {
    // create_event 默认 ask_first_time 首次需要确认；先记录首次确认使其放行。
    await policy.recordFirstConfirmation(accountId: 'a1', actionType: 'create_event', targetType: 'event');
    final tool = _FakeWriteTool(gateway: gateway, policy: policy, confirmationStore: store);
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
    final tool = _FakeWriteTool(gateway: gateway, policy: policy, confirmationStore: store);
    final result = await tool.execute(const {}, _ctx('a1', 'r1'));
    expect(result.status, AgentToolStatus.error);
    expect(result.errorCode, 'permission_denied');
    expect(tool.commitCalled, isFalse);
  });

  test('confirm decision suspends and commits on resolve(approve)', () async {
    final tool = _FakeWriteTool(gateway: gateway, policy: policy, confirmationStore: store);
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
    final tool = _FakeWriteTool(gateway: gateway, policy: policy, confirmationStore: store);
    final result = await tool.execute(const {}, _ctx('a1', 'r1'));
    final resumed = await store.resolve(result.userAction!.opaqueHandle, approve: false, remember: false);
    expect(resumed.status, AgentToolStatus.error);
    expect(resumed.errorCode, 'user_declined');
    expect(tool.commitCalled, isFalse);
  });

  test('remember relaxes the policy to always_allow', () async {
    final tool = _FakeWriteTool(gateway: gateway, policy: policy, confirmationStore: store);
    final result = await tool.execute(const {}, _ctx('a1', 'r1'));
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: true);
    expect(await policy.resolve(accountId: 'a1', actionType: 'create_event',
        targetType: 'event', riskLevel: RiskLevel.medium), PermissionDecision.allow);
  });

  test('forceConfirmation tool always confirms even when policy allows', () async {
    await policy.recordFirstConfirmation(accountId: 'a1', actionType: 'create_event', targetType: 'event');
    final tool = _ForceConfirmTool(gateway: gateway, policy: policy, confirmationStore: store);
    final result = await tool.execute(const {}, _ctx('a1', 'r1'));
    expect(result.status, AgentToolStatus.needsUserAction);
    expect(tool.commitCalled, isFalse);
  });

  test('cancel completes the pending invocation as cancelled', () async {
    final tool = _FakeWriteTool(gateway: gateway, policy: policy, confirmationStore: store);
    final result = await tool.execute(const {}, _ctx('a1', 'r1'));
    await result.pendingInvocation!.cancel();
    final resumed = await result.pendingInvocation!.result;
    expect(resumed.errorCode, 'cancelled');
    expect(tool.commitCalled, isFalse);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run（在 `app/` 下）：`flutter test test/features/agent/agent_write_tool_test.dart`
Expected: FAIL，`AgentWriteGateway` / `AgentWriteTool` / `WriteConfirmationStore` 未定义。

- [ ] **Step 3: 实现接口与基类**

`app/lib/features/agent/domain/agent_write_gateway.dart`：

```dart
import 'package:drift/drift.dart' show Value; // 仅类型空间，实际不引用

import '../../../core/database/app_database.dart';
import '../../calendar/domain/personal_event.dart';
import '../../schedule/application/overlay_service.dart';
import '../../schedule/domain/recurrence.dart';
import '../../tasks/domain/plan_block.dart';
import '../../tasks/domain/task.dart';
import 'agent_permission_policy.dart';

/// 一个事件的写身份（是否个人、是否重复系列、occurrence 位置）。
class EventWriteIdentity {
  const EventWriteIdentity({
    required this.id,
    required this.source,
    required this.type,
    this.personalSeriesId,
    this.occurrenceKey,
  });

  final String id;
  final String source;
  final String type;
  final String? personalSeriesId;
  final String? occurrenceKey;

  bool get isPersonal => source == 'user';
  bool get isRecurring => personalSeriesId != null && occurrenceKey != null;
}

/// 本地写网关：纯写方法，包装现有 Application Service。
///
/// 不含确认/策略逻辑（那是 `AgentWriteTool` 基类的事）；实现按账户构造
/// （类似 `CalendarEventService`），不接收 `accountId` 参数。
abstract interface class AgentWriteGateway {
  Future<String> createEvent(PersonalEvent event, {List<int>? reminderOffsetsMinutes});
  Future<void> editPersonalEvent(String eventId, PersonalEvent replacement, {List<int>? reminderOffsetsMinutes});
  Future<void> editOccurrenceOnly(String seriesId, String occurrenceKey, OccurrenceOverride override);
  Future<SeriesEditImpact> editWholeSeries(String seriesId, {required PersonalEvent anchor});
  Future<PersonalEvent> seriesAnchor(String seriesId);
  Future<void> cancelEvent(String eventId);
  Future<void> completeEvent(String eventId);
  Future<void> skipEvent(String eventId);
  Future<void> softDeleteEvent(String eventId);
  Future<String> createTask({required String title, String? description, String? userNotes, DateTime? deadlineAt, int? estimatedMinutes, List<String> tags, TaskImportance importance});
  Future<void> renameTask(String id, String title, {required int expectedUpdatedAt});
  Future<void> completeTask(String id, {required int expectedUpdatedAt});
  Future<void> cancelTask(String id, {required int expectedUpdatedAt});
  Future<void> softDeleteTask(String id, {required int expectedUpdatedAt});
  Future<String> planTask({required String taskId, required DateTime startAt, required DateTime endAt, String? title, PlanBlockStatus status});
  Future<void> setEventOverlay(String eventId, OverlayMutation mutation);
  Future<void> setSeriesOverlay(String seriesId, OverlayMutation mutation);
  Future<void> recordAttendanceDecision(String eventId, AttendanceDecision decision);
  Future<void> recordListeningMode(String eventId, ListeningMode mode, {String? note});
  Future<void> createConflictRelation({required String leftKind, required String leftId, required String rightKind, required String rightId, required String conflictState, String? reason});
  Future<void> setReminder(String eventId, List<int> offsetsMinutes);
  Future<EventWriteIdentity> eventIdentity(String eventId);
  Future<PersonalEvent> personalEvent(String eventId);
  Future<String?> courseSeriesIdForEvent(String eventId);
  Future<TaskItem> taskById(String taskId);
  Future<PlanBlockItem> planBlockById(String planBlockId);
  Future<void> updatePermissionPolicy({required String actionType, required String targetType, required ConfirmationMode mode, required RiskLevel riskLevel, required bool enabled, required String updatedBy});
}
```

（`OccurrenceOverride`/`RecurrenceRule`/`SeriesEditImpact` 的实际定义在
`app/lib/features/calendar/domain/recurrence_expander.dart` / `recurrence_service.dart`，
import 以实际为准；若路径不符，用 `Grep` 修正 import。）

`app/lib/features/agent/domain/agent_write_proposal.dart` 追加 `copyWith`：

```dart
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
```

`app/lib/features/agent/domain/agent_tool.dart` 修改：

```dart
enum AgentUserActionType { youngLogin, writeConfirmation }

class AgentUserAction {
  const AgentUserAction({
    required this.type,
    required this.opaqueHandle,
    this.writeProposal,
  });

  final AgentUserActionType type;
  final String opaqueHandle;
  final AgentWriteProposalView? writeProposal;

  AgentUserActionMetadata get metadata =>
      AgentUserActionMetadata(type: type, writeProposal: writeProposal);
}

class AgentUserActionMetadata {
  const AgentUserActionMetadata({required this.type, this.writeProposal});

  final AgentUserActionType type;
  final AgentWriteProposalView? writeProposal;
}
```

（文件头部加 `import 'agent_write_proposal.dart';`。）

`app/lib/features/agent/application/agent_write_tool.dart`：

```dart
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

  final AgentWriteGateway gateway;
  final AgentPermissionPolicyService policy;
  final WriteConfirmationStore confirmationStore;

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
  }) {
    final handle = _generateHandle();
    _pending[handle] = _PendingWrite(
      proposal: proposal,
      context: context,
      commit: commit,
      completer: Completer<AgentToolResult>(),
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
```

- [ ] **Step 4: 运行测试确认通过**

Run（在 `app/` 下）：`flutter test test/features/agent/agent_write_tool_test.dart`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add app/lib/features/agent/domain/agent_write_gateway.dart \
        app/lib/features/agent/application/agent_write_tool.dart \
        app/lib/features/agent/domain/agent_write_proposal.dart \
        app/lib/features/agent/domain/agent_tool.dart \
        app/test/features/agent/agent_write_tool_test.dart
git commit -m "feat(agent): add write tool base class with approval gate"
```
---

### Task 4: DriftAgentWriteGateway（写网关实现）

**Files:**
- Create: `app/lib/features/agent/data/drift_agent_write_gateway.dart`
- Test: `app/test/features/agent/drift_agent_write_gateway_test.dart`

**Interfaces:**
- Consumes: Task 3 的 `AgentWriteGateway`/`EventWriteIdentity`，现有业务 Service（`CalendarEventService`/`TaskLifecycleService`/`PlanBlockService`/`OverlayService`/`RecurrenceService`/`ReminderOverrideService`）、`NoopUndoRecorder`、`AgentPermissionPolicyService`、`AppDatabase`。
- Produces（供 Task 5-9 的写工具使用）：`DriftAgentWriteGateway` 实例（按账户构造）。

- [ ] **Step 1: 写失败的网关测试**

`app/test/features/agent/drift_agent_write_gateway_test.dart`：

```dart
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_permission_policy_service.dart';
import 'package:ustc_assistant_app/features/agent/data/drift_agent_write_gateway.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_permission_policy.dart';
import 'package:ustc_assistant_app/features/calendar/domain/personal_event.dart';
import 'package:ustc_assistant_app/features/schedule/application/effective_event_repository.dart';
import 'package:ustc_assistant_app/features/schedule/application/overlay_service.dart';
import 'package:ustc_assistant_app/features/tasks/domain/plan_block.dart';
import 'package:ustc_assistant_app/features/tasks/domain/task.dart';

class _FixedClock implements BeijingClock {
  @override
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);
}

void main() {
  late AppDatabase db;
  late AgentPermissionPolicyService policy;
  late DriftAgentWriteGateway gateway;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db.customStatement('PRAGMA foreign_keys = OFF');
    policy = AgentPermissionPolicyService(database: db, clock: _FixedClock());
    gateway = DriftAgentWriteGateway(
      database: db,
      accountId: 'acc-1',
      policy: policy,
      now: () => 1_700_000_000_000,
    );
  });

  tearDown(() => db.close());

  test('createEvent inserts a personal event', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    final row = (await db.select(db.calendarEvents)..where((r) => r.id.equals('ev-1'))).getSingle();
    expect(row.title, '健身');
    expect(row.source, 'user');
  });

  test('createTask and planTask insert rows', () async {
    final taskId = await gateway.createTask(title: '写作业', estimatedMinutes: 60);
    expect(await gateway.taskById(taskId).then((t) => t.title), '写作业');
    final blockId = await gateway.planTask(
      taskId: taskId,
      startAt: DateTime(2026, 8, 2, 20),
      endAt: DateTime(2026, 8, 2, 21),
      status: PlanBlockStatus.accepted,
    );
    expect((await gateway.planBlockById(blockId)).taskId, taskId);
  });

  test('editPersonalEvent updates and cancel/softDelete transition', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    await gateway.editPersonalEvent('ev-1', PersonalEvent.timed(
      id: 'ev-1',
      title: '健身改五点',
      startAt: DateTime(2026, 8, 1, 17),
      endAt: DateTime(2026, 8, 1, 18),
    ));
    var row = (await db.select(db.calendarEvents)..where((r) => r.id.equals('ev-1'))).getSingle();
    expect(row.title, '健身改五点');

    await gateway.cancelEvent('ev-1');
    row = (await db.select(db.calendarEvents)..where((r) => r.id.equals('ev-1'))).getSingle();
    expect(row.status, 'cancelled');

    await gateway.softDeleteEvent('ev-1');
    row = (await db.select(db.calendarEvents)..where((r) => r.id.equals('ev-1'))).getSingle();
    expect(row.deletedAt, isNotNull);
  });

  test('eventIdentity reports personal/recurring', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    final identity = await gateway.eventIdentity('ev-1');
    expect(identity.isPersonal, isTrue);
    expect(identity.isRecurring, isFalse);
  });

  test('recordAttendanceDecision and setEventOverlay write overlays', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    await gateway.recordAttendanceDecision('ev-1', AttendanceDecision.go);
    await gateway.setEventOverlay('ev-1', const OverlayMutation(
      attendancePolicy: AttendancePolicy.mustGo,
      listeningNote: '去占座补作业',
    ));
    final overlay = (await db.select(db.userOverlays)).getSingle();
    expect(overlay.attendanceDecision, 'go');
    expect(overlay.attendancePolicy, 'must_go');
  });

  test('createConflictRelation writes a conflict relation row', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '课程A',
      startAt: DateTime(2026, 8, 1, 9),
      endAt: DateTime(2026, 8, 1, 10),
    ));
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-2',
      title: '课程B',
      startAt: DateTime(2026, 8, 1, 9),
      endAt: DateTime(2026, 8, 1, 10),
    ));
    await gateway.createConflictRelation(
      leftKind: 'event',
      leftId: 'ev-1',
      rightKind: 'event',
      rightId: 'ev-2',
      conflictState: 'no_conflict',
      reason: '二选一，用户已决定',
    );
    final relation = (await db.select(db.scheduleRelations)).getSingle();
    expect(relation.relationType, 'conflict');
    expect(relation.conflictState, 'no_conflict');
  });

  test('setReminder writes reminder rows via override service', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    await gateway.setReminder('ev-1', const [15]);
    final reminders = (await db.select(db.reminders)).get();
    expect(reminders.single.eventId, 'ev-1');
    expect(reminders.single.offsetMinutes, 15);
  });

  test('updatePermissionPolicy delegates to policy service', () async {
    await gateway.updatePermissionPolicy(
      actionType: 'create_event',
      targetType: 'event',
      mode: ConfirmationMode.alwaysAllow,
      riskLevel: RiskLevel.medium,
      enabled: true,
      updatedBy: 'user',
    );
    expect(await policy.resolve(accountId: 'acc-1', actionType: 'create_event',
        targetType: 'event', riskLevel: RiskLevel.medium), PermissionDecision.allow);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run（在 `app/` 下）：`flutter test test/features/agent/drift_agent_write_gateway_test.dart`
Expected: FAIL，`DriftAgentWriteGateway` 未定义。

- [ ] **Step 3: 实现网关**

`app/lib/features/agent/data/drift_agent_write_gateway.dart`：

```dart
import 'package:drift/drift.dart' show Value;
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../calendar/application/calendar_event_service.dart';
import '../../calendar/application/recurrence_service.dart';
import '../../calendar/domain/personal_event.dart';
import '../../reminders/application/reminder_override_service.dart';
import '../../schedule/application/effective_event_repository.dart';
import '../../schedule/application/overlay_service.dart';
import '../../tasks/application/plan_block_service.dart';
import '../../tasks/application/task_lifecycle_service.dart';
import '../../tasks/application/undo_recorder.dart';
import '../../tasks/domain/plan_block.dart';
import '../../tasks/domain/task.dart';
import '../application/agent_permission_policy_service.dart';
import '../domain/agent_permission_policy.dart';
import '../domain/agent_write_gateway.dart';

/// 按账户构造的写网关实现：每个方法构造对应账户的现有 Service 并委托。
///
/// 使用 `NoopUndoRecorder`（Agent 写入不占用一步撤回槽）。写操作成功后由
/// `AgentWriteTool` 基类统一写 `source='agent'` 的 ActionLog，这里不重复写。
class DriftAgentWriteGateway implements AgentWriteGateway {
  DriftAgentWriteGateway({
    required this.database,
    required this.accountId,
    required this.policy,
    int Function()? now,
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final AppDatabase database;
  final String accountId;
  final AgentPermissionPolicyService policy;
  final int Function() now;
  static const _noopUndo = NoopUndoRecorder();
  static const _uuid = Uuid();

  CalendarEventService get _events =>
      CalendarEventService(database: database, accountId: accountId, now: now, undoRecorder: _noopUndo);
  TaskLifecycleService get _tasks =>
      TaskLifecycleService(database: database, accountId: accountId, now: now, undoRecorder: _noopUndo);
  PlanBlockService get _planBlocks =>
      PlanBlockService(database: database, accountId: accountId, now: now, undoRecorder: _noopUndo);
  OverlayService get _overlays =>
      OverlayService(database: database, accountId: accountId, now: now, undoRecorder: _noopUndo);
  RecurrenceService get _recurrence =>
      RecurrenceService(database: database, accountId: accountId, now: now);
  ReminderOverrideService get _reminders =>
      ReminderOverrideService(database: database, accountId: accountId, undoRecorder: _noopUndo, now: now);

  @override
  Future<String> createEvent(PersonalEvent event, {List<int>? reminderOffsetsMinutes}) =>
      _events.create(event, reminderOffsetsMinutes: reminderOffsetsMinutes);

  @override
  Future<void> editPersonalEvent(String eventId, PersonalEvent replacement, {List<int>? reminderOffsetsMinutes}) =>
      _events.edit(eventId, replacement, reminderOffsetsMinutes: reminderOffsetsMinutes);

  @override
  Future<void> editOccurrenceOnly(String seriesId, String occurrenceKey, OccurrenceOverride override) =>
      _recurrence.editOnlyThis(seriesId, occurrenceKey, override);

  @override
  Future<SeriesEditImpact> editWholeSeries(String seriesId, {required PersonalEvent anchor}) async {
    final series = await _recurrence.seriesRow(seriesId);
    final rule = RecurrenceRule.decode(series.recurrenceJson);
    return _recurrence.editWholeSeries(seriesId, anchor: anchor, rule: rule);
  }

  @override
  Future<PersonalEvent> seriesAnchor(String seriesId) async {
    final series = await _recurrence.seriesRow(seriesId);
    if (series.allDay == true) {
      final startDate = DateTime.parse(series.anchorStartDate!);
      return PersonalEvent.allDay(
        title: series.title,
        startDate: startDate,
        endDateExclusive: startDate.add(Duration(days: series.durationDays ?? 1)),
        description: series.description,
        locationName: series.locationName,
        type: personalEventTypeFromStorage(series.eventType),
        importance: series.importance,
      );
    }
    final startAt = DateTime.fromMillisecondsSinceEpoch(series.startAt!);
    return PersonalEvent.timed(
      title: series.title,
      startAt: startAt,
      endAt: startAt.add(Duration(minutes: series.durationMinutes ?? 0)),
      description: series.description,
      locationName: series.locationName,
      type: personalEventTypeFromStorage(series.eventType),
      importance: series.importance,
    );
  }

  @override
  Future<void> cancelEvent(String eventId) => _events.cancel(eventId);

  @override
  Future<void> completeEvent(String eventId) => _events.complete(eventId);

  @override
  Future<void> skipEvent(String eventId) => _events.skip(eventId);

  @override
  Future<void> softDeleteEvent(String eventId) => _events.softDelete(eventId);

  @override
  Future<String> createTask({
    required String title,
    String? description,
    String? userNotes,
    DateTime? deadlineAt,
    int? estimatedMinutes,
    List<String> tags = const [],
    TaskImportance importance = TaskImportance.normal,
  }) => _tasks.create(
    title: title,
    description: description,
    userNotes: userNotes,
    importance: importance,
    deadlineAt: deadlineAt,
    estimatedMinutes: estimatedMinutes,
    tags: tags,
  );

  @override
  Future<void> renameTask(String id, String title, {required int expectedUpdatedAt}) =>
      _tasks.rename(id, title, expectedUpdatedAt: expectedUpdatedAt);

  @override
  Future<void> completeTask(String id, {required int expectedUpdatedAt}) =>
      _tasks.complete(id, expectedUpdatedAt: expectedUpdatedAt);

  @override
  Future<void> cancelTask(String id, {required int expectedUpdatedAt}) =>
      _tasks.cancel(id, expectedUpdatedAt: expectedUpdatedAt);

  @override
  Future<void> softDeleteTask(String id, {required int expectedUpdatedAt}) =>
      _tasks.softDelete(id, expectedUpdatedAt: expectedUpdatedAt);

  @override
  Future<String> planTask({
    required String taskId,
    required DateTime startAt,
    required DateTime endAt,
    String? title,
    PlanBlockStatus status = PlanBlockStatus.accepted,
  }) => _planBlocks.create(taskId: taskId, startAt: startAt, endAt: endAt, title: title, status: status);

  @override
  Future<void> setEventOverlay(String eventId, OverlayMutation mutation) =>
      _overlays.setEventOverlay(eventId, mutation);

  @override
  Future<void> setSeriesOverlay(String seriesId, OverlayMutation mutation) =>
      _overlays.setSeriesOverlay(seriesId, mutation);

  @override
  Future<void> recordAttendanceDecision(String eventId, AttendanceDecision decision) =>
      _overlays.recordAttendanceDecision(eventId, decision);

  @override
  Future<void> recordListeningMode(String eventId, ListeningMode mode, {String? note}) =>
      _overlays.setEventOverlay(eventId, OverlayMutation(listeningMode: mode, listeningNote: note));

  @override
  Future<void> createConflictRelation({
    required String leftKind,
    required String leftId,
    required String rightKind,
    required String rightId,
    required String conflictState,
    String? reason,
  }) async {
    final timestamp = now();
    final existing = await (database.select(database.scheduleRelations)
          ..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.leftKind.equals(leftKind) &
                row.leftId.equals(leftId) &
                row.rightKind.equals(rightKind) &
                row.rightId.equals(rightId),
          ))
        .getSingleOrNull();
    final id = existing?.id ?? _uuid.v4();
    await database.into(database.scheduleRelations).insertOnConflictUpdate(
      ScheduleRelationsCompanion.insert(
        id: id,
        accountId: accountId,
        relationType: 'conflict',
        leftKind: Value(leftKind),
        leftId: Value(leftId),
        rightKind: Value(rightKind),
        rightId: Value(rightId),
        leftEventId: Value(leftKind == 'event' ? leftId : null),
        leftPlanBlockId: Value(leftKind == 'plan_block' ? leftId : null),
        rightEventId: Value(rightKind == 'event' ? rightId : null),
        rightPlanBlockId: Value(rightKind == 'plan_block' ? rightId : null),
        conflictState: Value(conflictState),
        reason: Value(reason),
        createdAt: existing?.createdAt ?? timestamp,
        updatedAt: timestamp,
      ),
    );
    await database.actionLogsRepository.append(
      accountId: accountId,
      source: 'user',
      actionType: 'schedule_relation_create',
      result: 'success',
      safeSummary: 'Updated a conflict relation.',
      occurredAt: timestamp,
    );
  }

  @override
  Future<void> setReminder(String eventId, List<int> offsetsMinutes) =>
      _reminders.setEventOffsets(eventId, offsetsMinutes);

  @override
  Future<EventWriteIdentity> eventIdentity(String eventId) async {
    final row = await (database.select(database.calendarEvents)
          ..where((r) => r.id.equals(eventId) & r.accountId.equals(accountId)))
        .getSingleOrNull();
    if (row == null) throw StateError('event not found for account');
    return EventWriteIdentity(
      id: row.id,
      source: row.source,
      type: row.type,
      personalSeriesId: row.personalSeriesId,
      occurrenceKey: row.occurrenceKey,
    );
  }

  @override
  Future<PersonalEvent> personalEvent(String eventId) => _events.byId(eventId);

  @override
  Future<String?> courseSeriesIdForEvent(String eventId) async {
    final record = await EffectiveEventRepository(
      database,
      accountId: accountId,
    ).byId(eventId);
    return record.courseSeriesId;
  }

  @override
  Future<TaskItem> taskById(String taskId) => _tasks.byId(taskId);

  @override
  Future<PlanBlockItem> planBlockById(String planBlockId) => _planBlocks.byId(planBlockId);

  @override
  Future<void> updatePermissionPolicy({
    required String actionType,
    required String targetType,
    required ConfirmationMode mode,
    required RiskLevel riskLevel,
    required bool enabled,
    required String updatedBy,
  }) => policy.updatePolicy(
    accountId: accountId,
    actionType: actionType,
    targetType: targetType,
    mode: mode,
    riskLevel: riskLevel,
    enabled: enabled,
    updatedBy: updatedBy,
  );
}
```

注：`OccurrenceOverride`/`RecurrenceRule`/`SeriesEditImpact` 的实际定义位置在
`app/lib/features/calendar/domain/` 下，import 以实际为准（用 Grep 修正）。

- [ ] **Step 4: 运行测试确认通过**

Run（在 `app/` 下）：`flutter test test/features/agent/drift_agent_write_gateway_test.dart`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add app/lib/features/agent/data/drift_agent_write_gateway.dart \
        app/test/features/agent/drift_agent_write_gateway_test.dart
git commit -m "feat(agent): add drift agent write gateway wrapping local services"
```
---

### Task 5: 创建类写工具（create_event / create_task / plan_task）

**Files:**
- Create: `app/lib/features/agent/application/agent_write_tools.dart`
- Test: `app/test/features/agent/write_tools_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `AgentWriteProposal`，Task 2 的策略服务，Task 3 的 `AgentWriteTool` 基类 + `WriteConfirmationStore`，Task 4 的 `AgentWriteGateway`；`PersonalEvent`/`TaskImportance`/`PlanBlockStatus` 领域类型；`RunReferenceStore`（ref 解析）。
- Produces: `CreateEventTool`、`CreateTaskTool`、`PlanTaskTool` 三个写工具类（供 Task 9 组合接线注册）。

**工具目标 kind 说明**：ref 的 kind 字符串以现有只读工具实际绑定为准——`event`→`'event'`、`task`→`'task'`、`plan_block`→`'planblock'`。动手前用 Grep 确认 `agent_tools.dart` 里 `GetTaskDetailsTool`/`GetPlanBlocksTool` 实际 bind 的 kind。

- [ ] **Step 1: 写失败的三个工具测试**

`app/test/features/agent/write_tools_test.dart`：

```dart
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_permission_policy_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_write_tool.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_write_tools.dart';
import 'package:ustc_assistant_app/features/agent/application/cancellation_signal.dart';
import 'package:ustc_assistant_app/features/agent/application/run_reference_store.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_tool.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_write_gateway.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_write_proposal.dart';
import 'package:ustc_assistant_app/features/calendar/domain/personal_event.dart';
import 'package:ustc_assistant_app/features/tasks/domain/plan_block.dart';
import 'package:ustc_assistant_app/features/tasks/domain/task.dart';

class _FixedClock implements BeijingClock {
  @override
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);
}

/// 记录被调用方法的假网关；未覆盖方法抛错。
class _RecordingGateway implements AgentWriteGateway {
  final List<PersonalEvent> createdEvents = [];
  final List<Map<String, Object?>> createdTasks = [];
  final List<Map<String, Object?>> plannedBlocks = [];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();

  @override
  Future<String> createEvent(PersonalEvent event, {List<int>? reminderOffsetsMinutes}) async {
    createdEvents.add(event);
    return 'ev-created';
  }

  @override
  Future<String> createTask({
    required String title,
    String? description,
    String? userNotes,
    DateTime? deadlineAt,
    int? estimatedMinutes,
    List<String> tags = const [],
    TaskImportance importance = TaskImportance.normal,
  }) async {
    createdTasks.add({
      'title': title,
      'description': description,
      'deadlineAt': deadlineAt,
      'estimatedMinutes': estimatedMinutes,
      'importance': importance,
    });
    return 'task-created';
  }

  @override
  Future<String> planTask({
    required String taskId,
    required DateTime startAt,
    required DateTime endAt,
    String? title,
    PlanBlockStatus status = PlanBlockStatus.accepted,
  }) async {
    plannedBlocks.add({
      'taskId': taskId,
      'startAt': startAt,
      'endAt': endAt,
      'title': title,
      'status': status,
    });
    return 'block-created';
  }
}

AgentToolContext _ctx(String runId, {String accountId = 'a1'}) =>
    AgentToolContext(
      accountId: accountId,
      runId: runId,
      clock: _FixedClock(),
      cancellation: CancellationSignal(),
      references: RunReferenceStore(runId: runId),
    );

/// 记录 ref 绑定，方便测试 plan_task 的 ref 解析。
class _Harness {
  _Harness(this.tools);
  final List<AgentWriteTool> tools;
  late final RunReferenceStore refs;
  AgentWriteTool tool(String name) => tools.firstWhere((t) => t.name == name);
}

void main() {
  late AppDatabase db;
  late AgentPermissionPolicyService policy;
  late WriteConfirmationStore store;
  late _RecordingGateway gateway;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    policy = AgentPermissionPolicyService(database: db, clock: _FixedClock());
    store = WriteConfirmationStore(policy: policy);
    gateway = _RecordingGateway();
  });

  tearDown(() => db.close());

  List<AgentWriteTool> tools() => [
    CreateEventTool(gateway: gateway, policy: policy, confirmationStore: store),
    CreateTaskTool(gateway: gateway, policy: policy, confirmationStore: store),
    PlanTaskTool(gateway: gateway, policy: policy, confirmationStore: store),
  ];

  test('schemas declare required args', () {
    final t = tools();
    final createEventSchema = t.firstWhere((x) => x.name == 'create_event').inputSchema;
    expect((createEventSchema['required'] as List).contains('title'), isTrue);
    expect((t.firstWhere((x) => x.name == 'create_task').inputSchema['required'] as List).contains('title'), isTrue);
    expect((t.firstWhere((x) => x.name == 'plan_task').inputSchema['required'] as List).contains('ref_task'), isTrue);
  });

  test('create_event propose builds a timed proposal and commits on approval', () async {
    final h = _Harness(tools());
    final result = await h.tool('create_event').execute({
      'title': '健身',
      'start_at': '2026-08-01T15:00:00+08:00',
      'end_at': '2026-08-01T16:00:00+08:00',
      'location': '健身房',
    }, _ctx('r1'));
    expect(result.status, AgentToolStatus.needsUserAction);
    expect(result.userAction?.writeProposal?.operationLabel, '新建日程');
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gateway.createdEvents.single.title, '健身');
    expect(gateway.createdEvents.single.startAt, DateTime.parse('2026-08-01T15:00:00+08:00'));
  });

  test('create_event rejects invalid all-day range in propose', () async {
    final h = _Harness(tools());
    final result = await h.tool('create_event').execute({
      'title': '全天',
      'all_day': true,
      'start_date': '2026-08-02',
      'end_date_exclusive': '2026-08-02', // 不晚于开始 → 非法
    }, _ctx('r1'));
    expect(result.status, AgentToolStatus.error);
    expect(result.errorCode, 'invalid_write_arguments');
  });

  test('create_task propose and commit', () async {
    final h = _Harness(tools());
    final result = await h.tool('create_task').execute({
      'title': '写作业',
      'deadline_at': '2026-08-05T23:59:00+08:00',
      'estimated_minutes': 120,
    }, _ctx('r1'));
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gateway.createdTasks.single['title'], '写作业');
    expect(gateway.createdTasks.single['estimatedMinutes'], 120);
  });

  test('plan_task resolves the task ref and commits', () async {
    final h = _Harness(tools());
    // 先绑定一个 task ref（模拟模型之前通过 get_tasks 读到）
    final taskRef = h.refs.bind(kind: 'task', localId: 'task-1');
    final result = await h.tool('plan_task').execute({
      'ref_task': taskRef,
      'start_at': '2026-08-03T20:00:00+08:00',
      'end_at': '2026-08-03T21:00:00+08:00',
      'status': 'accepted',
    }, _ctx('r1'));
    expect(result.status, AgentToolStatus.needsUserAction);
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gateway.plannedBlocks.single['taskId'], 'task-1');
    expect(gateway.plannedBlocks.single['status'], PlanBlockStatus.accepted);
  });

  test('plan_task with an unknown ref is rejected before approval', () async {
    final h = _Harness(tools());
    final result = await h.tool('plan_task').execute({
      'ref_task': 'ref_unknown',
      'start_at': '2026-08-03T20:00:00+08:00',
      'end_at': '2026-08-03T21:00:00+08:00',
    }, _ctx('r1'));
    expect(result.status, AgentToolStatus.error);
    expect(result.errorCode, 'invalid_write_arguments');
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run（在 `app/` 下）：`flutter test test/features/agent/write_tools_test.dart`
Expected: FAIL，`CreateEventTool` 等未定义。

- [ ] **Step 3: 实现三个创建类工具**

`app/lib/features/agent/application/agent_write_tools.dart`（本 Task 含前三个；Task 6-8 会在此文件继续追加）：

```dart
import 'package:ustc_assistant_app/features/calendar/domain/personal_event.dart';
import 'package:ustc_assistant_app/features/tasks/domain/plan_block.dart';
import 'package:ustc_assistant_app/features/tasks/domain/task.dart';

import '../domain/agent_permission_policy.dart';
import '../domain/agent_tool.dart';
import '../domain/agent_write_gateway.dart';
import '../domain/agent_write_proposal.dart';
import 'agent_permission_policy_service.dart';
import 'agent_write_tool.dart';

/// 把 ISO-8601 字符串解析为本地时间（模型传带 +08:00 偏移）。
DateTime _parseDateTime(String value) => DateTime.parse(value);

String _fmtRange(PersonalEvent event) => event.allDay
    ? '${event.startDate!.toIso8601String().substring(0, 10)} 至 '
          '${event.endDateExclusive!.toIso8601String().substring(0, 10)}'
    : '${event.startAt!.toIso8601String()} 至 ${event.endAt!.toIso8601String()}';

String _fmtTaskRange(DateTime? start, DateTime? end) =>
    '${start?.toIso8601String()} 至 ${end?.toIso8601String()}';

/// 新建个人日程。
class CreateEventTool extends AgentWriteTool {
  CreateEventTool({required super.gateway, required super.policy, required super.confirmationStore});

  @override
  String get name => 'create_event';
  @override
  String get description =>
      '新建一个个人日程事件。课程/考试/二课等来源事件不可新建，用 create_user_overlay 标注。';
  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'properties': {
      'title': {'type': 'string'},
      'start_at': {'type': 'string', 'description': '开始时间 ISO-8601，如 2026-08-01T15:00:00+08:00'},
      'end_at': {'type': 'string', 'description': '结束时间 ISO-8601'},
      'all_day': {'type': 'boolean', 'description': '全天事件传 true 并用 start_date/end_date_exclusive'},
      'start_date': {'type': 'string', 'description': '全天事件开始日期 YYYY-MM-DD'},
      'end_date_exclusive': {'type': 'string', 'description': '全天事件结束日期（不含）YYYY-MM-DD'},
      'location': {'type': 'string'},
      'type': {'type': 'string', 'enum': ['personal', 'entertainment', 'meal', 'campus_affair', 'travel', 'study']},
      'description': {'type': 'string'},
      'tags': {'type': 'array', 'items': {'type': 'string'}},
      'reminder_offsets_minutes': {'type': 'array', 'items': {'type': 'integer'}},
    },
    'required': ['title'],
  };

  @override
  String get actionType => 'create_event';
  @override
  RiskLevel get riskLevel => RiskLevel.medium;
  @override
  String get targetType => 'event';
  @override
  String get operationLabel => '新建日程';

  @override
  Future<AgentWriteProposal> propose(Map<String, Object?> a, AgentToolContext ctx) async {
    final title = (a['title'] as String).trim();
    if (title.isEmpty) throw const FormatException('title required');
    final allDay = a['all_day'] == true;
    final type = personalEventTypeFromStorage((a['type'] as String?) ?? 'personal');
    final importance = (a['importance'] as String?) ?? 'normal';
    final tags = (a['tags'] as List?)?.cast<String>() ?? const <String>[];
    final offsets = (a['reminder_offsets_minutes'] as List?)?.cast<int>();
    final location = a['location'] as String?;
    final description = a['description'] as String?;

    final PersonalEvent event;
    if (allDay) {
      final startDate = _parseDateTime(a['start_date'] as String);
      final endDate = _parseDateTime(a['end_date_exclusive'] as String);
      event = PersonalEvent.allDay(
        title: title,
        startDate: startDate,
        endDateExclusive: endDate,
        description: description,
        locationName: location,
        type: type,
        importance: importance,
        tags: tags,
      );
    } else {
      final startAt = _parseDateTime(a['start_at'] as String);
      final endAt = _parseDateTime(a['end_at'] as String);
      event = PersonalEvent.timed(
        title: title,
        startAt: startAt,
        endAt: endAt,
        description: description,
        locationName: location,
        type: type,
        importance: importance,
        tags: tags,
      );
    }

    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: [
        '标题：$title',
        '时间：${_fmtRange(event)}',
        if (location != null && location.isNotEmpty) '地点：$location',
      ],
      commitParams: {'event': event, 'reminderOffsetsMinutes': offsets},
      safeLogSummary: '新建日程 $title ${_fmtRange(event)}',
    );
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext ctx) async {
    final event = proposal.commitParams['event'] as PersonalEvent;
    final offsets = proposal.commitParams['reminderOffsetsMinutes'] as List<int>?;
    await gateway.createEvent(event, reminderOffsetsMinutes: offsets);
    return AgentToolResult(payload: {'result': 'created_event', 'title': event.title});
  }
}

/// 新建任务。
class CreateTaskTool extends AgentWriteTool {
  CreateTaskTool({required super.gateway, required super.policy, required super.confirmationStore});

  @override
  String get name => 'create_task';
  @override
  String get description => '新建一个任务（作业/复习/事务等），可带截止时间和预计工时。';
  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'properties': {
      'title': {'type': 'string'},
      'description': {'type': 'string'},
      'deadline_at': {'type': 'string', 'description': '截止时间 ISO-8601，可空'},
      'estimated_minutes': {'type': 'integer', 'description': '预计工时（分钟）'},
      'importance': {'type': 'string', 'enum': ['low', 'normal', 'high', 'critical']},
      'tags': {'type': 'array', 'items': {'type': 'string'}},
    },
    'required': ['title'],
  };

  @override
  String get actionType => 'create_task';
  @override
  RiskLevel get riskLevel => RiskLevel.medium;
  @override
  String get targetType => 'task';
  @override
  String get operationLabel => '新建任务';

  @override
  Future<AgentWriteProposal> propose(Map<String, Object?> a, AgentToolContext ctx) async {
    final title = (a['title'] as String).trim();
    if (title.isEmpty) throw const FormatException('title required');
    final deadlineAt = a['deadline_at'] == null ? null : _parseDateTime(a['deadline_at'] as String);
    final estimatedMinutes = a['estimated_minutes'] as int?;
    final importanceValue = (a['importance'] as String?) ?? 'normal';
    final importance = TaskImportance.values.firstWhere(
      (v) => v.name == importanceValue,
      orElse: () => TaskImportance.normal,
    );
    final tags = (a['tags'] as List?)?.cast<String>() ?? const <String>[];

    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: [
        '标题：$title',
        if (deadlineAt != null) '截止：${deadlineAt.toIso8601String()}',
        if (estimatedMinutes != null) '预计：$estimatedMinutes 分钟',
      ],
      commitParams: {
        'title': title,
        'description': a['description'],
        'deadlineAt': deadlineAt,
        'estimatedMinutes': estimatedMinutes,
        'tags': tags,
        'importance': importance,
      },
      safeLogSummary: '新建任务 $title',
    );
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext ctx) async {
    final params = proposal.commitParams;
    await gateway.createTask(
      title: params['title'] as String,
      description: params['description'] as String?,
      deadlineAt: params['deadlineAt'] as DateTime?,
      estimatedMinutes: params['estimatedMinutes'] as int?,
      tags: (params['tags'] as List<String>),
      importance: params['importance'] as TaskImportance,
    );
    return AgentToolResult(payload: {'result': 'created_task', 'title': params['title']});
  }
}

/// 为已有任务安排一个执行时间段（PlanBlock）。
class PlanTaskTool extends AgentWriteTool {
  PlanTaskTool({required super.gateway, required super.policy, required super.confirmationStore});

  @override
  String get name => 'plan_task';
  @override
  String get description => '为一个已存在的任务安排一个执行时间段（PlanBlock）。ref_task 来自之前的任务查询。';
  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'properties': {
      'ref_task': {'type': 'string', 'description': '任务的 ref_* 引用'},
      'start_at': {'type': 'string'},
      'end_at': {'type': 'string'},
      'title': {'type': 'string', 'description': '可空，块标题'},
      'status': {'type': 'string', 'enum': ['accepted', 'suggested'], 'default': 'accepted'},
    },
    'required': ['ref_task', 'start_at', 'end_at'],
  };

  @override
  String get actionType => 'plan_task';
  @override
  RiskLevel get riskLevel => RiskLevel.medium;
  @override
  String get targetType => 'plan_block';
  @override
  String get operationLabel => '安排任务时间段';

  @override
  Future<AgentWriteProposal> propose(Map<String, Object?> a, AgentToolContext ctx) async {
    final ref = a['ref_task'] as String;
    final taskId = ctx.references.resolve(ref: ref, kind: 'task');
    if (taskId == null) throw const FormatException('unknown task ref');
    final startAt = _parseDateTime(a['start_at'] as String);
    final endAt = _parseDateTime(a['end_at'] as String);
    final title = a['title'] as String?;
    final statusValue = (a['status'] as String?) ?? 'accepted';
    final status = PlanBlockStatus.values.firstWhere(
      (v) => v.name == statusValue,
      orElse: () => PlanBlockStatus.accepted,
    );

    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: [
        if (title != null && title.isNotEmpty) '标题：$title',
        '时间：$_fmtTaskRange(startAt, endAt)',
      ],
      commitParams: {'taskId': taskId, 'startAt': startAt, 'endAt': endAt, 'title': title, 'status': status},
      safeLogSummary: '安排任务时间段 ${_fmtTaskRange(startAt, endAt)}',
    );
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext ctx) async {
    final p = proposal.commitParams;
    await gateway.planTask(
      taskId: p['taskId'] as String,
      startAt: p['startAt'] as DateTime,
      endAt: p['endAt'] as DateTime,
      title: p['title'] as String?,
      status: p['status'] as PlanBlockStatus,
    );
    return AgentToolResult(payload: {'result': 'planned_task', 'start_at': p['startAt'].toIso8601String()});
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run（在 `app/` 下）：`flutter test test/features/agent/write_tools_test.dart`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add app/lib/features/agent/application/agent_write_tools.dart \
        app/test/features/agent/write_tools_test.dart
git commit -m "feat(agent): add create_event/create_task/plan_task write tools"
```
---

### Task 6: 修改/删除类写工具（update_event）

**Files:**
- Modify: `app/lib/features/agent/application/agent_write_tools.dart`（追加 `UpdateEventTool`）
- Test: `app/test/features/agent/write_tools_test.dart`（追加用例）

**Interfaces:**
- Consumes: Task 3/4 网关的 `eventIdentity`/`personalEvent`/`seriesAnchor`/`editOccurrenceOnly`/`editWholeSeries`/`cancelEvent`/`completeEvent`/`skipEvent`/`softDeleteEvent`/`editPersonalEvent`；`OccurrenceOverride`/`OverrideValue`（`recurrence_service.dart`）。
- Produces: `UpdateEventTool`。

**行为约定（与 spec §2 一致）：**
- `delete: true` → 软删除（`deletedAt`），高风险始终确认。
- `status` ∈ `cancelled/completed/skipped` → 对应终态过渡。
- 字段修改：非重复个人事件 → `editPersonalEvent`（先读当前合并）；重复系列 `scope=only_this` → `editOccurrenceOnly`；重复系列 `scope=whole_series` → 保留规则改 anchor（时间字段不支持整系列变更，返回引导）。
- 目标为 `course/exam/second_class` 事件 → 返回 `source_event_not_editable` 引导用 overlay 工具。

- [ ] **Step 1: 追加失败的 update_event 测试**

在 `app/test/features/agent/write_tools_test.dart` 追加 import 与假网关、用例：

```dart
import 'package:ustc_assistant_app/features/calendar/application/recurrence_service.dart';
import 'package:ustc_assistant_app/features/calendar/domain/recurrence_rule.dart';

/// update_event 专用假网关：记录被调方法。
class _UpdateGateway implements AgentWriteGateway {
  final Map<String, EventWriteIdentity> identities = {};
  final Map<String, PersonalEvent> events = {};
  String? softDeletedId;
  String? cancelledId;
  String? completedId;
  String? skippedId;
  String? editedId;
  PersonalEvent? editedReplacement;
  ({String seriesId, String key, OccurrenceOverride override})? occurrenceEdit;
  ({String seriesId, PersonalEvent anchor})? wholeSeriesEdit;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();

  @override
  Future<EventWriteIdentity> eventIdentity(String eventId) async =>
      identities[eventId]!;

  @override
  Future<PersonalEvent> personalEvent(String eventId) async =>
      events[eventId]!;

  @override
  Future<PersonalEvent> seriesAnchor(String seriesId) async =>
      events['anchor:$seriesId']!;

  @override
  Future<void> softDeleteEvent(String eventId) async => softDeletedId = eventId;

  @override
  Future<void> cancelEvent(String eventId) async => cancelledId = eventId;

  @override
  Future<void> completeEvent(String eventId) async => completedId = eventId;

  @override
  Future<void> skipEvent(String eventId) async => skippedId = eventId;

  @override
  Future<void> editPersonalEvent(String eventId, PersonalEvent replacement, {List<int>? reminderOffsetsMinutes}) async {
    editedId = eventId;
    editedReplacement = replacement;
  }

  @override
  Future<void> editOccurrenceOnly(String seriesId, String occurrenceKey, OccurrenceOverride override) async {
    occurrenceEdit = (seriesId: seriesId, key: occurrenceKey, override: override);
  }

  @override
  Future<SeriesEditImpact> editWholeSeries(String seriesId, {required PersonalEvent anchor}) async {
    wholeSeriesEdit = (seriesId: seriesId, anchor: anchor);
    return const SeriesEditImpact(affectedOccurrences: 8, newlyOrphaned: 0, continuesBeyondHorizon: true);
  }
}
```

用例（`main()` 内追加）：

```dart
  test('update_event rejects an unknown ref', () async {
    final h = _Harness(tools());
    final result = await h.tool('update_event').execute({'ref_event': 'ref_nope'}, _ctx('r1'));
    expect(result.status, AgentToolStatus.error);
    expect(result.errorCode, 'invalid_write_arguments');
  });

  test('update_event delete soft-deletes after approval', () async {
    final h = _Harness(tools());
    final update = h.tool('update_event') as UpdateEventTool;
    final gw = _UpdateGateway();
    update.attachGateway(gw); // 见 Step 3 说明
    // 直接测 propose + commit 路径：用真实 store 走确认
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    gw.identities['ev-1'] = const EventWriteIdentity(id: 'ev-1', source: 'user', type: 'personal');
    final result = await update.execute({'ref_event': ref, 'delete': true}, _ctx('r1'));
    expect(result.status, AgentToolStatus.needsUserAction);
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gw.softDeletedId, 'ev-1');
  });

  test('update_event single edit merges into the current event', () async {
    final h = _Harness(tools());
    final update = h.tool('update_event') as UpdateEventTool;
    final gw = _UpdateGateway();
    update.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    gw.identities['ev-1'] = const EventWriteIdentity(id: 'ev-1', source: 'user', type: 'personal');
    gw.events['ev-1'] = PersonalEvent.timed(
      title: '健身', startAt: DateTime(2026, 8, 1, 15), endAt: DateTime(2026, 8, 1, 16));
    final result = await update.execute({'ref_event': ref, 'title': '健身改五点'}, _ctx('r1'));
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gw.editedId, 'ev-1');
    expect(gw.editedReplacement!.title, '健身改五点');
    expect(gw.editedReplacement!.startAt, DateTime(2026, 8, 1, 15)); // 未变字段保留
  });

  test('update_event only_this on a recurring series writes an override', () async {
    final h = _Harness(tools());
    final update = h.tool('update_event') as UpdateEventTool;
    final gw = _UpdateGateway();
    update.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    gw.identities['ev-1'] = const EventWriteIdentity(
      id: 'ev-1', source: 'user', type: 'personal',
      personalSeriesId: 'ser-1', occurrenceKey: 'ser-1@2026-08-05T15:00:00');
    final result = await update.execute({'ref_event': ref, 'scope': 'only_this', 'title': '本周例会改主题'}, _ctx('r1'));
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gw.occurrenceEdit!.seriesId, 'ser-1');
    expect(gw.occurrenceEdit!.override.title.value, '本周例会改主题');
  });

  test('update_event whole_series preserves the rule and changes anchor fields', () async {
    final h = _Harness(tools());
    final update = h.tool('update_event') as UpdateEventTool;
    final gw = _UpdateGateway();
    update.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    gw.identities['ev-1'] = const EventWriteIdentity(
      id: 'ev-1', source: 'user', type: 'personal',
      personalSeriesId: 'ser-1', occurrenceKey: 'ser-1@2026-08-05T15:00:00');
    gw.events['anchor:ser-1'] = PersonalEvent.timed(
      title: '例会', startAt: DateTime(2026, 8, 5, 15), endAt: DateTime(2026, 8, 5, 16));
    final result = await update.execute({'ref_event': ref, 'scope': 'whole_series', 'title': '例会（改）'}, _ctx('r1'));
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gw.wholeSeriesEdit!.seriesId, 'ser-1');
    expect(gw.wholeSeriesEdit!.anchor.title, '例会（改）');
  });

  test('update_event rejects whole_series time changes', () async {
    final h = _Harness(tools());
    final update = h.tool('update_event') as UpdateEventTool;
    final gw = _UpdateGateway();
    update.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    gw.identities['ev-1'] = const EventWriteIdentity(
      id: 'ev-1', source: 'user', type: 'personal',
      personalSeriesId: 'ser-1', occurrenceKey: 'k');
    final result = await update.execute({
      'ref_event': ref, 'scope': 'whole_series', 'start_at': '2026-08-05T17:00:00+08:00',
    }, _ctx('r1'));
    expect(result.status, AgentToolStatus.error);
    expect(result.errorCode, 'whole_series_time_change_not_supported');
  });

  test('update_event refuses to edit a course event', () async {
    final h = _Harness(tools());
    final update = h.tool('update_event') as UpdateEventTool;
    final gw = _UpdateGateway();
    update.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    gw.identities['ev-1'] = const EventWriteIdentity(id: 'ev-1', source: 'ustc_jw', type: 'course');
    final result = await update.execute({'ref_event': ref, 'title': 'x'}, _ctx('r1'));
    expect(result.status, AgentToolStatus.error);
    expect(result.errorCode, 'source_event_not_editable');
  });
```

注：`UpdateEventTool.attachGateway` 是测试用注入点（把运行时网关替换为假网关）。实现时给
`UpdateEventTool` 加 `void attachGateway(AgentWriteGateway value) { gateway = value; }`，
并把基类的 `gateway` 字段改为非 final 或提供 setter（基类 `gateway` 改为可写，或 UpdateEventTool
内部持有自己的 `gateway` 引用并调用）。推荐：基类 `AgentWriteTool.gateway` 保留 final，子类
`UpdateEventTool` 另加 `@override AgentWriteGateway get gateway => _gateway;` 与 setter 不太干净；
更简单的做法是基类字段改 `AgentWriteGateway gateway`（非 final），子类测试直接赋值。

- [ ] **Step 2: 运行测试确认失败**

Run（在 `app/` 下）：`flutter test test/features/agent/write_tools_test.dart`
Expected: FAIL，`UpdateEventTool` 未定义。

- [ ] **Step 3: 实现 UpdateEventTool**

把基类 `AgentWriteTool.gateway` 从 `final` 改为可变（`AgentWriteGateway gateway;`，删除
构造函数里的 `required this.gateway` 的 final 语义），然后实现：

```dart
/// 修改/删除已有日程。
class UpdateEventTool extends AgentWriteTool {
  UpdateEventTool({required super.gateway, required super.policy, required super.confirmationStore});

  @override
  String get name => 'update_event';
  @override
  String get description =>
      '修改或删除一个个人日程（标题/时间/地点/状态/删除）。课程/考试/二课事件不可改，请用 create_user_overlay。';
  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'properties': {
      'ref_event': {'type': 'string', 'description': '来自 get_schedule 的 ref_*'},
      'scope': {'type': 'string', 'enum': ['only_this', 'whole_series'], 'default': 'only_this',
          'description': '重复系列编辑范围；非重复事件忽略此字段'},
      'title': {'type': 'string'},
      'start_at': {'type': 'string'},
      'end_at': {'type': 'string'},
      'all_day': {'type': 'boolean'},
      'start_date': {'type': 'string'},
      'end_date_exclusive': {'type': 'string'},
      'location': {'type': 'string'},
      'type': {'type': 'string', 'enum': ['personal', 'entertainment', 'meal', 'campus_affair', 'travel', 'study']},
      'description': {'type': 'string'},
      'tags': {'type': 'array', 'items': {'type': 'string'}},
      'status': {'type': 'string', 'enum': ['cancelled', 'completed', 'skipped']},
      'delete': {'type': 'boolean'},
    },
    'required': ['ref_event'],
  };

  @override
  String get actionType => 'update_event';
  @override
  RiskLevel get riskLevel => RiskLevel.high;
  @override
  String get targetType => 'event';
  @override
  String get operationLabel => '修改/删除日程';

  @override
  Future<AgentWriteProposal> propose(Map<String, Object?> a, AgentToolContext ctx) async {
    final ref = a['ref_event'] as String;
    final eventId = ctx.references.resolve(ref: ref, kind: 'event');
    if (eventId == null) throw const FormatException('unknown event ref');
    final scope = (a['scope'] as String?) ?? 'only_this';
    final fields = <String, Object?>{
      if (a.containsKey('title')) 'title': (a['title'] as String).trim(),
      if (a.containsKey('start_at')) 'start_at': _parseDateTime(a['start_at'] as String),
      if (a.containsKey('end_at')) 'end_at': _parseDateTime(a['end_at'] as String),
      if (a.containsKey('all_day')) 'all_day': a['all_day'],
      if (a.containsKey('start_date')) 'start_date': _parseDateTime(a['start_date'] as String),
      if (a.containsKey('end_date_exclusive')) 'end_date_exclusive': _parseDateTime(a['end_date_exclusive'] as String),
      if (a.containsKey('location')) 'location': a['location'],
      if (a.containsKey('description')) 'description': a['description'],
      if (a.containsKey('importance')) 'importance': a['importance'],
      if (a.containsKey('tags')) 'tags': (a['tags'] as List).cast<String>(),
    };
    final status = a['status'] as String?;
    final delete = a['delete'] == true;

    final lines = <String>[];
    if (delete) {
      lines.add('删除该日程（软删除，可从管理页恢复）');
    } else if (status != null) {
      lines.add('状态改为：$status');
    } else {
      if (a.containsKey('title')) lines.add('标题：${a['title']}');
      if (a.containsKey('start_at') || a.containsKey('end_at')) lines.add('时间有改动');
      lines.add(scope == 'whole_series' ? '影响：整个重复系列' : '影响：仅本次');
    }

    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: lines,
      commitParams: {'eventId': eventId, 'scope': scope, 'fields': fields, 'status': status, 'delete': delete},
      safeLogSummary: delete ? '删除日程' : (status != null ? '修改日程状态 $status' : '修改日程'),
    );
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext ctx) async {
    final p = proposal.commitParams;
    final eventId = p['eventId'] as String;
    final scope = p['scope'] as String;
    final fields = p['fields'] as Map<String, Object?>;
    final status = p['status'] as String?;
    final delete = p['delete'] == true;

    final identity = await gateway.eventIdentity(eventId);
    if (!identity.isPersonal) {
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'source_event_not_editable',
        payload: {'guidance': '课程/考试/二课事件请用 create_user_overlay 标注，不直接修改。'},
      );
    }

    if (delete) {
      await gateway.softDeleteEvent(eventId);
      return AgentToolResult(payload: {'result': 'deleted_event'});
    }
    if (status != null) {
      switch (status) {
        case 'cancelled':
          await gateway.cancelEvent(eventId);
        case 'completed':
          await gateway.completeEvent(eventId);
        case 'skipped':
          await gateway.skipEvent(eventId);
      }
      return AgentToolResult(payload: {'result': 'updated_event', 'status': status});
    }

    // 字段修改
    if (identity.isRecurring && scope == 'whole_series') {
      final hasTimeChange = fields.containsKey('start_at') ||
          fields.containsKey('end_at') ||
          fields.containsKey('all_day');
      if (hasTimeChange) {
        return const AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'whole_series_time_change_not_supported',
          payload: {'guidance': '整系列时间变更暂不支持，可先用 only_this 只改本次，或在日程 UI 中整系列调整。'},
        );
      }
      final current = await gateway.seriesAnchor(identity.personalSeriesId!);
      final newAnchor = _applyToEvent(current, fields);
      final impact = await gateway.editWholeSeries(identity.personalSeriesId!, anchor: newAnchor);
      return AgentToolResult(payload: {
        'result': 'updated_whole_series',
        'affected_occurrences': impact.affectedOccurrences,
      });
    }
    if (identity.isRecurring) {
      final override = _buildOverride(fields);
      await gateway.editOccurrenceOnly(identity.personalSeriesId!, identity.occurrenceKey!, override);
      return AgentToolResult(payload: {'result': 'updated_occurrence'});
    }

    final current = await gateway.personalEvent(eventId);
    final replacement = _applyToEvent(current, fields);
    await gateway.editPersonalEvent(eventId, replacement);
    return AgentToolResult(payload: {'result': 'updated_event'});
  }

  static PersonalEvent _applyToEvent(PersonalEvent current, Map<String, Object?> fields) {
    if (fields.containsKey('all_day')) {
      // 显式切换全天语义：用 start_date/end_date_exclusive
      final startDate = (fields['start_date'] ?? current.startDate) as DateTime;
      final endDate = (fields['end_date_exclusive'] ?? current.endDateExclusive) as DateTime;
      return PersonalEvent.allDay(
        title: (fields['title'] as String?) ?? current.title,
        startDate: startDate,
        endDateExclusive: endDate,
        description: (fields['description'] as String?) ?? current.description,
        locationName: (fields['location'] as String?) ?? current.locationName,
        type: current.type,
        importance: (fields['importance'] as String?) ?? current.importance,
        tags: (fields['tags'] as List<String>?) ?? current.tags,
      );
    }
    final allDay = current.allDay;
    final title = (fields['title'] as String?) ?? current.title;
    final description = (fields['description'] as String?) ?? current.description;
    final location = (fields['location'] as String?) ?? current.locationName;
    final importance = (fields['importance'] as String?) ?? current.importance;
    final tags = (fields['tags'] as List<String>?) ?? current.tags;
    if (allDay) {
      final startDate = (fields['start_date'] as DateTime?) ?? current.startDate!;
      final endDate = (fields['end_date_exclusive'] as DateTime?) ?? current.endDateExclusive!;
      return PersonalEvent.allDay(
        title: title, startDate: startDate, endDateExclusive: endDate,
        description: description, locationName: location, type: current.type,
        importance: importance, tags: tags,
      );
    }
    final startAt = (fields['start_at'] as DateTime?) ?? current.startAt!;
    final endAt = (fields['end_at'] as DateTime?) ?? current.endAt!;
    return PersonalEvent.timed(
      title: title, startAt: startAt, endAt: endAt,
      description: description, locationName: location, type: current.type,
      importance: importance, tags: tags,
    );
  }

  static OccurrenceOverride _buildOverride(Map<String, Object?> fields) => OccurrenceOverride(
    title: fields.containsKey('title') ? OverrideValue.set(fields['title'] as String) : const OverrideValue.absent(),
    description: fields.containsKey('description')
        ? OverrideValue.set(fields['description'] as String?)
        : const OverrideValue.absent(),
    locationName: fields.containsKey('location')
        ? OverrideValue.set(fields['location'] as String?)
        : const OverrideValue.absent(),
    startAt: fields.containsKey('start_at')
        ? OverrideValue.set(fields['start_at'] as DateTime)
        : const OverrideValue.absent(),
    endAt: fields.containsKey('end_at')
        ? OverrideValue.set(fields['end_at'] as DateTime)
        : const OverrideValue.absent(),
    startDate: fields.containsKey('start_date')
        ? OverrideValue.set(fields['start_date'] as DateTime)
        : const OverrideValue.absent(),
    endDateExclusive: fields.containsKey('end_date_exclusive')
        ? OverrideValue.set(fields['end_date_exclusive'] as DateTime)
        : const OverrideValue.absent(),
    status: fields.containsKey('status')
        ? OverrideValue.set(eventStatusFromStorage(fields['status'] as String))
        : const OverrideValue.absent(),
    importance: fields.containsKey('importance')
        ? OverrideValue.set(fields['importance'] as String)
        : const OverrideValue.absent(),
    tags: fields.containsKey('tags')
        ? OverrideValue.set(fields['tags'] as List<String>)
        : const OverrideValue.absent(),
  );
}
```

注意：`switch` 的 `case` 无 break 会编译告警（Dart 3 允许非空 case 隐式 fallthrough 报错）。
把三个状态分别用 `if/else if` 或 `switch` + 立即 `return` 改写：

```dart
    if (status != null) {
      if (status == 'cancelled') {
        await gateway.cancelEvent(eventId);
      } else if (status == 'completed') {
        await gateway.completeEvent(eventId);
      } else {
        await gateway.skipEvent(eventId);
      }
      return AgentToolResult(payload: {'result': 'updated_event', 'status': status});
    }
```

（实现时用上面这个 if/else 版本替换 plan 里的 switch 版本。）

- [ ] **Step 4: 运行测试确认通过**

Run（在 `app/` 下）：`flutter test test/features/agent/write_tools_test.dart`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add app/lib/features/agent/application/agent_write_tools.dart \
        app/test/features/agent/write_tools_test.dart
git commit -m "feat(agent): add update_event write tool with delete/status/series edits"
```
---

### Task 7: 标注类写工具（create_user_overlay / record_attendance_decision / record_listening_mode）

**Files:**
- Modify: `app/lib/features/agent/application/agent_write_tools.dart`（追加三个工具）
- Test: `app/test/features/agent/write_tools_test.dart`（追加用例）

**Interfaces:**
- Consumes: Task 4 网关的 `setEventOverlay`/`setSeriesOverlay`/`recordAttendanceDecision`/`recordListeningMode`/`courseSeriesIdForEvent`；`OverlayMutation`/`AttendancePolicy`/`AttendanceDecision`/`ListeningMode`（`overlay_service.dart`/`effective_event_repository.dart`）。
- Produces: `CreateUserOverlayTool`、`RecordAttendanceDecisionTool`、`RecordListeningModeTool`。

**行为约定：** 课程系列没有独立 ref（只读工具只 bind `event/task/planblock/campus_entry`），所以"整门课标成 X"用 `ref_event` + `scope=course_series`，由网关把事件解析到其课程系列；事件不属于任何课程系列时报 `no_course_series`。出勤/听讲标注默认 `ask_first_time`（已确认调整项），首次确认后自动放行。

- [ ] **Step 1: 追加失败的标注工具测试**

在 `app/test/features/agent/write_tools_test.dart` 追加 import、假网关与用例：

```dart
import 'package:ustc_assistant_app/features/schedule/application/overlay_service.dart';

/// 标注类工具假网关。
class _OverlayGateway implements AgentWriteGateway {
  OverlayMutation? eventOverlay;
  OverlayMutation? seriesOverlay;
  AttendanceDecision? decision;
  ({ListeningMode mode, String? note})? listening;
  String? seriesFor;
  String? courseSeriesResult;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();

  @override
  Future<void> setEventOverlay(String eventId, OverlayMutation mutation) async => eventOverlay = mutation;

  @override
  Future<void> setSeriesOverlay(String seriesId, OverlayMutation mutation) async => seriesOverlay = mutation;

  @override
  Future<void> recordAttendanceDecision(String eventId, AttendanceDecision decision) async => this.decision = decision;

  @override
  Future<void> recordListeningMode(String eventId, ListeningMode mode, {String? note}) async => listening = (mode: mode, note: note);

  @override
  Future<String?> courseSeriesIdForEvent(String eventId) async => courseSeriesResult;
}
```

用例（`main()` 内追加）：

```dart
  test('create_user_overlay single_event sets an event overlay', () async {
    final h = _Harness(tools());
    final gw = _OverlayGateway();
    final tool = h.tool('create_user_overlay');
    tool.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    final result = await tool.execute({
      'ref_event': ref,
      'attendance_policy': 'must_go',
      'attendance_note': '小测',
    }, _ctx('r1'));
    expect(result.status, AgentToolStatus.needsUserAction);
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gw.eventOverlay?.attendancePolicy, AttendancePolicy.mustGo);
    expect(gw.eventOverlay?.attendanceNote, '小测');
  });

  test('create_user_overlay course_series resolves the event series', () async {
    final h = _Harness(tools());
    final gw = _OverlayGateway();
    gw.courseSeriesResult = 'cs-1';
    final tool = h.tool('create_user_overlay');
    tool.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    final result = await tool.execute({
      'ref_event': ref,
      'scope': 'course_series',
      'attendance_policy': 'skip',
    }, _ctx('r1'));
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gw.seriesOverlay?.attendancePolicy, AttendancePolicy.skip);
  });

  test('create_user_overlay course_series without a series errors', () async {
    final h = _Harness(tools());
    final gw = _OverlayGateway();
    final tool = h.tool('create_user_overlay');
    tool.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    final result = await tool.execute({'ref_event': ref, 'scope': 'course_series'}, _ctx('r1'));
    // 需要确认后才 commit；commit 里解析失败返回 no_course_series
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gw.seriesOverlay, isNull);
  });

  test('record_attendance_decision maps go/skip/undecided', () async {
    final h = _Harness(tools());
    final gw = _OverlayGateway();
    final tool = h.tool('record_attendance_decision');
    tool.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    final result = await tool.execute({'ref_event': ref, 'decision': 'go'}, _ctx('r1'));
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gw.decision, AttendanceDecision.go);
  });

  test('record_listening_mode maps not_listen with a note', () async {
    final h = _Harness(tools());
    final gw = _OverlayGateway();
    final tool = h.tool('record_listening_mode');
    tool.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    final result = await tool.execute({
      'ref_event': ref, 'mode': 'not_listen', 'note': '适合写作业',
    }, _ctx('r1'));
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gw.listening!.mode, ListeningMode.notListen);
    expect(gw.listening!.note, '适合写作业');
  });
```

注：`attachGateway` 需要基类 `AgentWriteTool.gateway` 非 final（Task 6 已改为可变）。若个别工具测试仍需注入，继续用同 setter。

- [ ] **Step 2: 运行测试确认失败**

Run（在 `app/` 下）：`flutter test test/features/agent/write_tools_test.dart`
Expected: FAIL，三个标注工具未定义。

- [ ] **Step 3: 实现三个标注工具**

在 `agent_write_tools.dart` 追加（`tools()` 组装处也要把三个新工具加入列表）：

```dart
/// 为用户对某个事件或整门课设置个人标注（出勤/听讲/显示名/重要性/隐藏）。
class CreateUserOverlayTool extends AgentWriteTool {
  CreateUserOverlayTool({required super.gateway, required super.policy, required super.confirmationStore});

  @override
  String get name => 'create_user_overlay';
  @override
  String get description =>
      '设置事件或整门课程的个人标注：必去/可以赌/不去、听讲/不听讲、显示名、重要性、隐藏。ref_event 来自日程查询。';
  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'properties': {
      'ref_event': {'type': 'string'},
      'scope': {'type': 'string', 'enum': ['single_event', 'course_series'], 'default': 'single_event'},
      'attendance_policy': {'type': 'string', 'enum': ['must_go', 'gamble', 'skip']},
      'attendance_note': {'type': 'string'},
      'listening_mode': {'type': 'string', 'enum': ['listen', 'not_listen']},
      'listening_note': {'type': 'string'},
      'display_title': {'type': 'string'},
      'importance': {'type': 'string', 'enum': ['low', 'normal', 'high', 'critical']},
      'hidden': {'type': 'boolean'},
    },
    'required': ['ref_event'],
  };

  @override
  String get actionType => 'create_user_overlay';
  @override
  RiskLevel get riskLevel => RiskLevel.medium;
  @override
  String get targetType => 'overlay';
  @override
  String get operationLabel => '设置个人标注';

  static AttendancePolicy? _attendance(String? value) => switch (value) {
    'must_go' => AttendancePolicy.mustGo,
    'gamble' => AttendancePolicy.gamble,
    'skip' => AttendancePolicy.skip,
    _ => null,
  };

  static ListeningMode? _listening(String? value) => switch (value) {
    'listen' => ListeningMode.listen,
    'not_listen' => ListeningMode.notListen,
    _ => null,
  };

  @override
  Future<AgentWriteProposal> propose(Map<String, Object?> a, AgentToolContext ctx) async {
    final ref = a['ref_event'] as String;
    final eventId = ctx.references.resolve(ref: ref, kind: 'event');
    if (eventId == null) throw const FormatException('unknown event ref');
    final scope = (a['scope'] as String?) ?? 'single_event';
    final lines = <String>[];
    if (a['attendance_policy'] != null) lines.add('出勤：${a['attendance_policy']}');
    if (a['listening_mode'] != null) lines.add('听讲：${a['listening_mode']}');
    if (lines.isEmpty && a['display_title'] != null) lines.add('显示名：${a['display_title']}');
    lines.add(scope == 'course_series' ? '作用：整门课' : '作用：仅该事件');

    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: lines,
      commitParams: {'eventId': eventId, 'scope': scope, 'args': Map<String, Object?>.from(a)},
      safeLogSummary: '设置个人标注 ${lines.join('、')}',
    );
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext ctx) async {
    final p = proposal.commitParams;
    final eventId = p['eventId'] as String;
    final scope = p['scope'] as String;
    final a = p['args'] as Map<String, Object?>;
    final mutation = OverlayMutation(
      displayTitle: a['display_title'] as String?,
      attendancePolicy: _attendance(a['attendance_policy'] as String?),
      attendanceNote: a['attendance_note'] as String?,
      listeningMode: _listening(a['listening_mode'] as String?),
      listeningNote: a['listening_note'] as String?,
      importance: a['importance'] as String?,
      hidden: a['hidden'] as bool?,
    );
    if (scope == 'course_series') {
      final seriesId = await gateway.courseSeriesIdForEvent(eventId);
      if (seriesId == null) {
        return const AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'no_course_series',
          payload: {'guidance': '该事件不属于任何课程系列，无法整门课标注。'},
        );
      }
      await gateway.setSeriesOverlay(seriesId, mutation);
      return AgentToolResult(payload: {'result': 'updated_course_overlay'});
    }
    await gateway.setEventOverlay(eventId, mutation);
    return AgentToolResult(payload: {'result': 'updated_event_overlay'});
  }
}

/// 记录"可以赌"课程的本次出勤决定（去/不去/未定）。
class RecordAttendanceDecisionTool extends AgentWriteTool {
  RecordAttendanceDecisionTool({required super.gateway, required super.policy, required super.confirmationStore});

  @override
  String get name => 'record_attendance_decision';
  @override
  String get description => '记录某节课本次去不去（用于"可以赌"课程）。ref_event 来自日程查询。';
  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'properties': {
      'ref_event': {'type': 'string'},
      'decision': {'type': 'string', 'enum': ['go', 'skip', 'undecided']},
    },
    'required': ['ref_event', 'decision'],
  };

  @override
  String get actionType => 'record_attendance_decision';
  @override
  RiskLevel get riskLevel => RiskLevel.medium;
  @override
  String get targetType => 'event';
  @override
  String get operationLabel => '记录出勤决定';

  @override
  Future<AgentWriteProposal> propose(Map<String, Object?> a, AgentToolContext ctx) async {
    final ref = a['ref_event'] as String;
    final eventId = ctx.references.resolve(ref: ref, kind: 'event');
    if (eventId == null) throw const FormatException('unknown event ref');
    final decision = (a['decision'] as String?) ?? 'undecided';
    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: ['出勤决定：$decision'],
      commitParams: {'eventId': eventId, 'decision': decision},
      safeLogSummary: '记录出勤决定 $decision',
    );
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext ctx) async {
    final p = proposal.commitParams;
    final eventId = p['eventId'] as String;
    final decision = switch (p['decision']) {
      'go' => AttendanceDecision.go,
      'skip' => AttendanceDecision.skip,
      _ => AttendanceDecision.undecided,
    };
    await gateway.recordAttendanceDecision(eventId, decision);
    return AgentToolResult(payload: {'result': 'recorded_attendance_decision', 'decision': decision.name});
  }
}

/// 设置某节课的听讲/不听讲模式。
class RecordListeningModeTool extends AgentWriteTool {
  RecordListeningModeTool({required super.gateway, required super.policy, required super.confirmationStore});

  @override
  String get name => 'record_listening_mode';
  @override
  String get description => '设置某节课听讲或不听讲，可附原因备注。ref_event 来自日程查询。';
  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'properties': {
      'ref_event': {'type': 'string'},
      'mode': {'type': 'string', 'enum': ['listen', 'not_listen']},
      'note': {'type': 'string'},
    },
    'required': ['ref_event', 'mode'],
  };

  @override
  String get actionType => 'record_listening_mode';
  @override
  RiskLevel get riskLevel => RiskLevel.medium;
  @override
  String get targetType => 'event';
  @override
  String get operationLabel => '设置听讲模式';

  @override
  Future<AgentWriteProposal> propose(Map<String, Object?> a, AgentToolContext ctx) async {
    final ref = a['ref_event'] as String;
    final eventId = ctx.references.resolve(ref: ref, kind: 'event');
    if (eventId == null) throw const FormatException('unknown event ref');
    final mode = (a['mode'] as String?) ?? 'listen';
    final note = a['note'] as String?;
    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: ['听讲：$mode', if (note != null && note.isNotEmpty) '备注：$note'],
      commitParams: {'eventId': eventId, 'mode': mode, 'note': note},
      safeLogSummary: '设置听讲模式 $mode',
    );
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext ctx) async {
    final p = proposal.commitParams;
    final eventId = p['eventId'] as String;
    final mode = p['mode'] == 'not_listen' ? ListeningMode.notListen : ListeningMode.listen;
    await gateway.recordListeningMode(eventId, mode, note: p['note'] as String?);
    return AgentToolResult(payload: {'result': 'recorded_listening_mode'});
  }
}
```

同时更新测试里 `tools()` 函数，把三个新工具加入列表：

```dart
  List<AgentWriteTool> tools() => [
    CreateEventTool(gateway: gateway, policy: policy, confirmationStore: store),
    CreateTaskTool(gateway: gateway, policy: policy, confirmationStore: store),
    PlanTaskTool(gateway: gateway, policy: policy, confirmationStore: store),
    UpdateEventTool(gateway: gateway, policy: policy, confirmationStore: store),
    CreateUserOverlayTool(gateway: gateway, policy: policy, confirmationStore: store),
    RecordAttendanceDecisionTool(gateway: gateway, policy: policy, confirmationStore: store),
    RecordListeningModeTool(gateway: gateway, policy: policy, confirmationStore: store),
  ];
```

- [ ] **Step 4: 运行测试确认通过**

Run（在 `app/` 下）：`flutter test test/features/agent/write_tools_test.dart`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add app/lib/features/agent/application/agent_write_tools.dart \
        app/test/features/agent/write_tools_test.dart
git commit -m "feat(agent): add overlay/attendance/listening write tools"
```
---

### Task 8: 关系/提醒/权限写工具（create_schedule_relation / set_reminder / update_permission_policy）

**Files:**
- Modify: `app/lib/features/agent/application/agent_write_tools.dart`（追加三个工具）
- Test: `app/test/features/agent/write_tools_test.dart`（追加用例）

**Interfaces:**
- Consumes: Task 4 网关的 `createConflictRelation`/`setReminder`/`updatePermissionPolicy`；`AgentPermissionPolicyService.defaultRisk`。
- Produces: `CreateScheduleRelationTool`、`SetReminderTool`、`UpdatePermissionPolicyTool`。

**行为约定：**
- `create_schedule_relation`：只支持一对 event/plan_block 的 `conflict` 关系（现有表 CHECK 约束），`conflict_state` ∈ `conflict`/`no_conflict`，`reason` 记用户意图。左右 ref 先按 `event` 解析，再回退 `planblock`。
- `set_reminder`：本轮仅 event 目标；`offsets_minutes` 必须非负。
- `update_permission_policy`：`forceConfirmation=true`（永远走确认卡）、`rememberAllowed=false`（卡上无"以后不再确认"）；即使已放宽也强制确认。

- [ ] **Step 1: 追加失败的三个工具测试**

在 `app/test/features/agent/write_tools_test.dart` 追加 import、假网关与用例：

```dart
import 'package:ustc_assistant_app/features/agent/domain/agent_permission_policy.dart';

/// 关系/提醒/权限工具假网关。
class _RelationGateway implements AgentWriteGateway {
  ({String leftKind, String leftId, String rightKind, String rightId, String conflictState, String? reason})? relation;
  ({String eventId, List<int> offsets})? reminder;
  Map<String, Object?>? policyUpdate;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();

  @override
  Future<void> createConflictRelation({
    required String leftKind,
    required String leftId,
    required String rightKind,
    required String rightId,
    required String conflictState,
    String? reason,
  }) async {
    relation = (leftKind: leftKind, leftId: leftId, rightKind: rightKind, rightId: rightId, conflictState: conflictState, reason: reason);
  }

  @override
  Future<void> setReminder(String eventId, List<int> offsetsMinutes) async =>
      reminder = (eventId: eventId, offsets: offsetsMinutes);

  @override
  Future<void> updatePermissionPolicy({
    required String actionType,
    required String targetType,
    required ConfirmationMode mode,
    required RiskLevel riskLevel,
    required bool enabled,
    required String updatedBy,
  }) async {
    policyUpdate = {'actionType': actionType, 'targetType': targetType, 'mode': mode, 'riskLevel': riskLevel, 'updatedBy': updatedBy};
  }
}
```

用例（`main()` 内追加）：

```dart
  test('create_schedule_relation resolves event refs and commits', () async {
    final h = _Harness(tools());
    final gw = _RelationGateway();
    final tool = h.tool('create_schedule_relation');
    tool.attachGateway(gw);
    final left = h.refs.bind(kind: 'event', localId: 'ev-1');
    final right = h.refs.bind(kind: 'event', localId: 'ev-2');
    final result = await tool.execute({
      'ref_left': left,
      'ref_right': right,
      'conflict_state': 'no_conflict',
      'reason': '两门课重叠，用户已决定去 A',
    }, _ctx('r1'));
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gw.relation!.leftKind, 'event');
    expect(gw.relation!.leftId, 'ev-1');
    expect(gw.relation!.conflictState, 'no_conflict');
  });

  test('set_reminder sets offsets for an event', () async {
    final h = _Harness(tools());
    final gw = _RelationGateway();
    final tool = h.tool('set_reminder');
    tool.attachGateway(gw);
    final ref = h.refs.bind(kind: 'event', localId: 'ev-1');
    final result = await tool.execute({'ref_event': ref, 'offsets_minutes': [15, 120]}, _ctx('r1'));
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gw.reminder!.eventId, 'ev-1');
    expect(gw.reminder!.offsets, [15, 120]);
  });

  test('update_permission_policy always confirms even when already relaxed', () async {
    final h = _Harness(tools());
    final gw = _RelationGateway();
    final tool = h.tool('update_permission_policy');
    tool.attachGateway(gw);
    // 先把 update_permission_policy 策略设成 always_allow，基类仍必须强制确认
    await policy.updatePolicy(accountId: 'a1', actionType: 'update_permission_policy',
        targetType: 'create_event', mode: ConfirmationMode.alwaysAllow,
        riskLevel: RiskLevel.critical, enabled: true, updatedBy: 'user');
    final result = await tool.execute({
      'action_type': 'create_event',
      'target_type': 'event',
      'confirmation_mode': 'always_allow',
    }, _ctx('r1'));
    expect(result.status, AgentToolStatus.needsUserAction);
    expect(result.userAction?.writeProposal?.rememberAllowed, isFalse);
    await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
    expect(gw.policyUpdate!['actionType'], 'create_event');
    expect(gw.policyUpdate!['mode'], ConfirmationMode.alwaysAllow);
  });
```

- [ ] **Step 2: 运行测试确认失败**

Run（在 `app/` 下）：`flutter test test/features/agent/write_tools_test.dart`
Expected: FAIL，三个工具未定义。

- [ ] **Step 3: 实现三个工具**

在 `agent_write_tools.dart` 追加（同时把三个新工具加入 `tools()` 列表）：

```dart
/// 记录两个安排之间的关系与用户决策（仅支持 conflict 形态）。
class CreateScheduleRelationTool extends AgentWriteTool {
  CreateScheduleRelationTool({required super.gateway, required super.policy, required super.confirmationStore});

  @override
  String get name => 'create_schedule_relation';
  @override
  String get description =>
      '记录一对日程/执行块之间的关系与冲突决策（如二选一、课上写作业、翘课去二课）。ref_left/ref_right 来自日程或任务查询。';
  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'properties': {
      'ref_left': {'type': 'string'},
      'ref_right': {'type': 'string'},
      'conflict_state': {'type': 'string', 'enum': ['conflict', 'no_conflict']},
      'reason': {'type': 'string', 'description': '用户意图/备注'},
    },
    'required': ['ref_left', 'ref_right', 'conflict_state'],
  };

  @override
  String get actionType => 'create_schedule_relation';
  @override
  RiskLevel get riskLevel => RiskLevel.medium;
  @override
  String get targetType => 'relation';
  @override
  String get operationLabel => '记录日程关系';

  /// 先按 event 解析，再回退 planblock（与只读工具绑定 kind 一致）。
  static ({String kind, String id}) _resolveRef(RunReferenceStore refs, String ref) {
    final eventId = refs.resolve(ref: ref, kind: 'event');
    if (eventId != null) return (kind: 'event', id: eventId);
    final blockId = refs.resolve(ref: ref, kind: 'planblock');
    if (blockId != null) return (kind: 'plan_block', id: blockId);
    throw const FormatException('unknown relation ref');
  }

  @override
  Future<AgentWriteProposal> propose(Map<String, Object?> a, AgentToolContext ctx) async {
    final left = _resolveRef(ctx.references, a['ref_left'] as String);
    final right = _resolveRef(ctx.references, a['ref_right'] as String);
    final conflictState = a['conflict_state'] as String;
    final reason = a['reason'] as String?;
    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: [
        '关系：$conflictState',
        if (reason != null && reason.isNotEmpty) '理由：$reason',
      ],
      commitParams: {
        'left': left,
        'right': right,
        'conflictState': conflictState,
        'reason': reason,
      },
      safeLogSummary: '记录日程关系 $conflictState',
    );
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext ctx) async {
    final p = proposal.commitParams;
    final left = p['left'] as ({String kind, String id});
    final right = p['right'] as ({String kind, String id});
    await gateway.createConflictRelation(
      leftKind: left.kind,
      leftId: left.id,
      rightKind: right.kind,
      rightId: right.id,
      conflictState: p['conflictState'] as String,
      reason: p['reason'] as String?,
    );
    return AgentToolResult(payload: {'result': 'created_schedule_relation'});
  }
}

/// 为个人日程设置提醒偏移。
class SetReminderTool extends AgentWriteTool {
  SetReminderTool({required super.gateway, required super.policy, required super.confirmationStore});

  @override
  String get name => 'set_reminder';
  @override
  String get description => '为个人日程设置提醒（开始前 N 分钟）。ref_event 来自日程查询。本轮仅支持日程事件。';
  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'properties': {
      'ref_event': {'type': 'string'},
      'offsets_minutes': {'type': 'array', 'items': {'type': 'integer'},
          'description': '开始前提醒偏移（分钟），全部非负'},
    },
    'required': ['ref_event', 'offsets_minutes'],
  };

  @override
  String get actionType => 'set_reminder';
  @override
  RiskLevel get riskLevel => RiskLevel.medium;
  @override
  String get targetType => 'event';
  @override
  String get operationLabel => '设置提醒';

  @override
  Future<AgentWriteProposal> propose(Map<String, Object?> a, AgentToolContext ctx) async {
    final ref = a['ref_event'] as String;
    final eventId = ctx.references.resolve(ref: ref, kind: 'event');
    if (eventId == null) throw const FormatException('unknown event ref');
    final offsets = (a['offsets_minutes'] as List).cast<int>();
    if (offsets.any((o) => o < 0)) throw const FormatException('negative offset');
    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: ['开始前 $offsets 分钟提醒'],
      commitParams: {'eventId': eventId, 'offsets': offsets},
      safeLogSummary: '设置提醒 ${offsets.join(",")} 分钟',
    );
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext ctx) async {
    final p = proposal.commitParams;
    await gateway.setReminder(p['eventId'] as String, (p['offsets'] as List).cast<int>());
    return AgentToolResult(payload: {'result': 'reminder_set'});
  }
}

/// 调整某类操作的确认策略。永远需要用户确认，且无"以后不再确认"。
class UpdatePermissionPolicyTool extends AgentWriteTool {
  UpdatePermissionPolicyTool({required super.gateway, required super.policy, required super.confirmationStore});

  @override
  String get name => 'update_permission_policy';
  @override
  String get description =>
      '调整某类操作的确认策略（如"以后新建日程不要再问我"）。所有权限变更都需要用户在确认卡上亲手批准，不会自动放行。';
  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'properties': {
      'action_type': {'type': 'string',
          'enum': ['create_event', 'create_task', 'plan_task', 'create_schedule_relation',
              'set_reminder', 'record_attendance_decision', 'record_listening_mode',
              'create_user_overlay', 'update_event']},
      'target_type': {'type': 'string', 'default': 'event'},
      'confirmation_mode': {'type': 'string', 'enum': ['always_ask', 'ask_first_time', 'always_allow', 'always_deny']},
    },
    'required': ['action_type', 'confirmation_mode'],
  };

  @override
  String get actionType => 'update_permission_policy';
  @override
  RiskLevel get riskLevel => RiskLevel.critical;
  @override
  String get targetType => 'permission';
  @override
  String get operationLabel => '调整确认策略';
  @override
  bool get rememberAllowed => false;
  @override
  bool get forceConfirmation => true;

  @override
  Future<AgentWriteProposal> propose(Map<String, Object?> a, AgentToolContext ctx) async {
    final actionType = a['action_type'] as String;
    final targetType = (a['target_type'] as String?) ?? 'event';
    final mode = ConfirmationModeStorage.fromStorage(a['confirmation_mode'] as String);
    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: ['动作：$actionType', '改为：${mode.storage}'],
      commitParams: {'actionType': actionType, 'targetType': targetType, 'mode': mode},
      safeLogSummary: '调整确认策略 $actionType → ${mode.storage}',
      rememberAllowed: false,
      forceConfirmation: true,
    );
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext ctx) async {
    final p = proposal.commitParams;
    final actionType = p['actionType'] as String;
    final targetType = p['targetType'] as String;
    final mode = p['mode'] as ConfirmationMode;
    await gateway.updatePermissionPolicy(
      actionType: actionType,
      targetType: targetType,
      mode: mode,
      riskLevel: AgentPermissionPolicyService.defaultRisk(actionType),
      enabled: true,
      updatedBy: 'agent',
    );
    return AgentToolResult(payload: {'result': 'permission_updated', 'action_type': actionType});
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run（在 `app/` 下）：`flutter test test/features/agent/write_tools_test.dart`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add app/lib/features/agent/application/agent_write_tools.dart \
        app/test/features/agent/write_tools_test.dart
git commit -m "feat(agent): add schedule-relation/reminder/permission write tools"
```
---

### Task 9: 会话接线（confirmWriteProposal）+ 组合装配 + payload 白名单

**Files:**
- Modify: `app/lib/features/agent/application/agent_session_service.dart`（加 `confirmWriteProposal` + `writeConfirmationResumer` 字段）
- Modify: `app/lib/features/agent/application/agent_composition.dart`（构造策略服务/写网关/确认仓/写工具；注入 resumer；`AgentCompositionResult` 暴露 `policyService`）
- Modify: `app/lib/features/agent/application/agent_write_tools.dart`（加 `agentWriteTools(...)` 工厂）
- Modify: `app/lib/features/agent/application/agent_tools.dart`（`agentToolPayloadBuilders()` 加写工具 allowlist）
- Test: `app/test/features/agent/agent_write_session_test.dart`

**Interfaces:**
- Consumes: Task 1-8 全部写工具与基础设施。
- Produces: 会话层 `confirmWriteProposal` 公共方法（供 Task 10 确认卡调用）；组合结果暴露 `policyService`（供 Task 11 设置页）。

- [ ] **Step 1: 写失败的会话接线测试**

`app/test/features/agent/agent_write_session_test.dart`：

```dart
import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_context_builder.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_permission_policy_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_session_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_tool_registry.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_write_tool.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_write_tools.dart';
import 'package:ustc_assistant_app/features/agent/application/cancellation_signal.dart';
import 'package:ustc_assistant_app/features/agent/application/outbound_privacy_filter.dart';
import 'package:ustc_assistant_app/features/agent/data/drift_agent_write_gateway.dart';
import 'package:ustc_assistant_app/features/agent/data/drift_chat_repository.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_models.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_tool.dart';
import 'package:ustc_assistant_app/features/agent/domain/llm_protocol.dart';

class _ScriptedProvider implements LlmProvider {
  _ScriptedProvider(this._script);
  final List<List<LlmEvent>> _script;
  int streamCallCount = 0;
  @override
  Future<List<String>> listModels({required String apiKey, required CancellationSignal cancellation}) async =>
      const ['deepseek-v4-flash'];
  @override
  Stream<LlmEvent> stream({required String apiKey, required LlmRequest request, required CancellationSignal cancellation}) async* {
    final index = streamCallCount++;
    if (index >= _script.length) {
      yield const ErrorEvent('script_exhausted');
      return;
    }
    for (final e in _script[index]) {
      if (cancellation.isCancelled) {
        yield const CompletedEvent();
        return;
      }
      yield e;
    }
  }
  @override
  Future<void> probeText({required String apiKey, required String model, required CancellationSignal cancellation}) async {}
  @override
  Future<void> probeTools({required String apiKey, required String model, required CancellationSignal cancellation}) async {}
}

class _FixedClock implements BeijingClock {
  @override
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);
}

List<LlmEvent> _confirmCardScript() => [
  const ToolUseCompletedEvent(id: 'tu-1', name: 'create_event',
      input: {'title': '健身', 'start_at': '2026-08-01T15:00:00+08:00', 'end_at': '2026-08-01T16:00:00+08:00'}),
  const UsageEvent(inputTokens: 100, outputTokens: 10),
  const CompletedEvent(),
];

List<LlmEvent> _finalTextScript() => [
  const TextDeltaEvent('已为你新建日程「健身」。'),
  const UsageEvent(inputTokens: 50, outputTokens: 10),
  const CompletedEvent(),
];

void main() {
  test('send pauses for write confirmation, confirm commits and the run completes', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.customStatement('PRAGMA foreign_keys = OFF');
    final clock = _FixedClock();
    final policy = AgentPermissionPolicyService(database: db, clock: clock);
    final store = WriteConfirmationStore(policy: policy);
    final gateway = DriftAgentWriteGateway(database: db, accountId: 'a1', policy: policy,
        now: () => clock.now().millisecondsSinceEpoch);
    final registry = AgentToolRegistry(
      tools: [CreateEventTool(gateway: gateway, policy: policy, confirmationStore: store)],
      privacyFilter: OutboundPrivacyFilter(protectedAccount: 'student', toolBuilders: agentToolPayloadBuilders()),
    );
    final chatRepo = DriftChatRepository(db);
    final provider = _ScriptedProvider([_confirmCardScript(), _finalTextScript()]);
    final session = AgentSessionService(
      chatRepository: chatRepo,
      database: db,
      provider: provider,
      contextBuilder: const AgentContextBuilder(),
      privacyFilter: OutboundPrivacyFilter(protectedAccount: 'student', toolBuilders: agentToolPayloadBuilders()),
      registry: registry,
      clock: clock,
      model: 'deepseek-v4-flash',
      apiKeyProvider: ({required String accountId}) async => 'k',
      writeConfirmationResumer: ({required String handle, required bool approve, required bool remember}) =>
          store.resolve(handle, approve: approve, remember: remember),
    );

    final states = <AgentRunViewState>[];
    final done = Completer<void>();
    late String runId;
    session.send(accountId: 'a1', userText: '帮我建个健身日程').listen((s) {
      states.add(s);
      if (s.state == AgentRunState.waitingForUser) runId = s.runId;
    }, onDone: done.complete, onError: (_) {});

    // 等待暂停出现确认卡
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(states.any((s) => s.userAction?.type == AgentUserActionType.writeConfirmation), isTrue);
    final paused = states.lastWhere((s) => s.userAction?.type == AgentUserActionType.writeConfirmation);
    expect(paused.userAction?.writeProposal?.operationLabel, '新建日程');

    await session.confirmWriteProposal(accountId: 'a1', runId: runId, approve: true, remember: false).drain<void>();
    await done.future;

    expect(states.last.state, AgentRunState.completed);
    final event = (await db.select(db.calendarEvents)).getSingle();
    expect(event.title, '健身');
    final logs = await db.actionLogsRepository.selectAll();
    expect(logs.any((l) => l.source == 'agent' && l.actionType == 'create_event'), isTrue);
    await db.close();
  });

  test('reject leaves no event and the model gets user_declined', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.customStatement('PRAGMA foreign_keys = OFF');
    final clock = _FixedClock();
    final policy = AgentPermissionPolicyService(database: db, clock: clock);
    final store = WriteConfirmationStore(policy: policy);
    final gateway = DriftAgentWriteGateway(database: db, accountId: 'a1', policy: policy,
        now: () => clock.now().millisecondsSinceEpoch);
    final privacy = OutboundPrivacyFilter(protectedAccount: 'student', toolBuilders: agentToolPayloadBuilders());
    final registry = AgentToolRegistry(
      tools: [CreateEventTool(gateway: gateway, policy: policy, confirmationStore: store)],
      privacyFilter: privacy,
    );
    final chatRepo = DriftChatRepository(db);
    final provider = _ScriptedProvider([_confirmCardScript(), _finalTextScript()]);
    final session = AgentSessionService(
      chatRepository: chatRepo,
      database: db,
      provider: provider,
      contextBuilder: const AgentContextBuilder(),
      privacyFilter: privacy,
      registry: registry,
      clock: clock,
      model: 'deepseek-v4-flash',
      apiKeyProvider: ({required String accountId}) async => 'k',
      writeConfirmationResumer: ({required String handle, required bool approve, required bool remember}) =>
          store.resolve(handle, approve: approve, remember: remember),
    );

    final states = <AgentRunViewState>[];
    final done = Completer<void>();
    late String runId;
    session.send(accountId: 'a1', userText: '帮我建个健身日程').listen((s) {
      states.add(s);
      if (s.state == AgentRunState.waitingForUser) runId = s.runId;
    }, onDone: done.complete);

    await Future<void>.delayed(const Duration(milliseconds: 50));
    await session.confirmWriteProposal(accountId: 'a1', runId: runId, approve: false, remember: false).drain<void>();
    await done.future;

    expect((await db.select(db.calendarEvents)).get(), isEmpty);
    expect(states.last.state, AgentRunState.completed);
    await db.close();
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run（在 `app/` 下）：`flutter test test/features/agent/agent_write_session_test.dart`
Expected: FAIL，`writeConfirmationResumer` 未定义（构造器参数不存在）。

- [ ] **Step 3: 会话层加 confirmWriteProposal**

`app/lib/features/agent/application/agent_session_service.dart`：

```dart
typedef WriteConfirmationResumerCallback =
    Future<void> Function({
      required String handle,
      required bool approve,
      required bool remember,
    });
```

构造器追加字段：

```dart
    this.writeConfirmationResumer,
  });

  final WriteConfirmationResumerCallback? writeConfirmationResumer;
```

新增公共方法（放在 `resumeUserAction` 之后，镜像其结构）：

```dart
  /// 用户对写确认卡做出决定：批准/拒绝 + 是否"此类型以后不再确认"。
  ///
  /// 完成挂起的写提案并恢复会话循环。返回的流在恢复完成时关闭；真正的
  /// 运行状态由 `send` 的流继续发出。
  Stream<AgentRunViewState> confirmWriteProposal({
    required String accountId,
    required String runId,
    required bool approve,
    required bool remember,
  }) {
    final controller = StreamController<AgentRunViewState>(sync: true);
    () async {
      try {
        final key = (accountId: accountId, runId: runId);
        final paused = _pausedRuns[key];
        if (paused == null ||
            paused.action.type != AgentUserActionType.writeConfirmation) {
          controller.add(
            AgentRunViewState(
              runId: runId,
              state: AgentRunState.failed,
              errorCode: 'paused_run_not_found',
            ),
          );
          return;
        }
        if (paused.resumeStarted) {
          controller.add(
            AgentRunViewState(
              runId: runId,
              state: AgentRunState.failed,
              errorCode: 'resume_already_started',
            ),
          );
          return;
        }
        paused.resumeStarted = true;
        final resumer = writeConfirmationResumer;
        if (resumer == null) {
          await _cancelPausedRun(paused);
          controller.add(
            AgentRunViewState(
              runId: runId,
              state: AgentRunState.failed,
              errorCode: 'resume_unavailable',
            ),
          );
          return;
        }
        try {
          await resumer(
            handle: paused.action.opaqueHandle,
            approve: approve,
            remember: remember,
          );
          await paused.pendingInvocation.result;
        } catch (_) {
          await _cancelPausedRun(paused);
        }
      } finally {
        await controller.close();
      }
    }();
    return controller.stream;
  }
```

- [ ] **Step 4: 组合装配 + 写工具工厂 + payload 白名单**

`agent_write_tools.dart` 追加工厂：

```dart
/// 组装全部 10 个写工具。
List<AgentWriteTool> agentWriteTools(
  AgentWriteGateway gateway,
  AgentPermissionPolicyService policy,
  WriteConfirmationStore confirmationStore,
) => [
  CreateEventTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore),
  UpdateEventTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore),
  CreateTaskTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore),
  PlanTaskTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore),
  CreateUserOverlayTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore),
  RecordAttendanceDecisionTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore),
  RecordListeningModeTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore),
  CreateScheduleRelationTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore),
  SetReminderTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore),
  UpdatePermissionPolicyTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore),
];
```

`agent_tools.dart` 的 `agentToolPayloadBuilders()` 追加（写工具结果只含安全摘要字段；统一 allowlist）：

```dart
const _writeResultKeys = {
  'result', 'guidance', 'title', 'status', 'decision',
  'action_type', 'affected_occurrences', 'start_at',
};
```

并在返回的 map 里加：

```dart
    'create_event': (raw) => _pick(raw, _writeResultKeys),
    'update_event': (raw) => _pick(raw, _writeResultKeys),
    'create_task': (raw) => _pick(raw, _writeResultKeys),
    'plan_task': (raw) => _pick(raw, _writeResultKeys),
    'create_user_overlay': (raw) => _pick(raw, _writeResultKeys),
    'record_attendance_decision': (raw) => _pick(raw, _writeResultKeys),
    'record_listening_mode': (raw) => _pick(raw, _writeResultKeys),
    'create_schedule_relation': (raw) => _pick(raw, _writeResultKeys),
    'set_reminder': (raw) => _pick(raw, _writeResultKeys),
    'update_permission_policy': (raw) => _pick(raw, _writeResultKeys),
```

`agent_composition.dart` 的 `build`：

```dart
    final policyService = AgentPermissionPolicyService(database: database, clock: clock);
    final writeGateway = DriftAgentWriteGateway(
      database: database,
      accountId: accountId,
      policy: policyService,
      now: () => clock.now().millisecondsSinceEpoch,
    );
    final confirmationStore = WriteConfirmationStore(policy: policyService);
    final write = agentWriteTools(writeGateway, policyService, confirmationStore);
    final allTools = [...local, ...external, ...write];
```

session 构造器加：

```dart
      writeConfirmationResumer:
          ({required String handle, required bool approve, required bool remember}) =>
              confirmationStore.resolve(handle, approve: approve, remember: remember),
```

`AgentCompositionResult` 加字段并返回 `policyService: policyService`：

```dart
  final AgentPermissionPolicyService policyService;
```

（在构造器与返回列表中加入；`AgentChatPage`/`AgentSettingsPage` 从 `AgentCompositionResult` 取用。）

- [ ] **Step 5: 运行测试确认通过**

Run（在 `app/` 下）：`flutter test test/features/agent/agent_write_session_test.dart`
Expected: PASS

再跑既有会话测试确认不回归：`flutter test test/features/agent/agent_session_service_test.dart`
Expected: PASS

- [ ] **Step 6: 提交**

```bash
git add app/lib/features/agent/application/agent_session_service.dart \
        app/lib/features/agent/application/agent_composition.dart \
        app/lib/features/agent/application/agent_write_tools.dart \
        app/lib/features/agent/application/agent_tools.dart \
        app/test/features/agent/agent_write_session_test.dart
git commit -m "feat(agent): wire write tools into session and composition with payload allowlists"
```
---

### Task 10: 聊天内联确认卡 UI

**Files:**
- Create: `app/lib/features/agent/presentation/agent_write_confirmation_card.dart`
- Modify: `app/lib/features/agent/presentation/agent_chat_page.dart`（追加确认卡尾项）
- Test: `app/test/features/agent/agent_write_confirmation_card_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `AgentWriteProposalView`；`AgentUserActionType.writeConfirmation`；会话 `confirmWriteProposal`。
- Produces: `AgentWriteConfirmationCard` widget（确认/取消/此类型以后不再确认/去权限设置）。

- [ ] **Step 1: 写失败的确认卡测试**

`app/test/features/agent/agent_write_confirmation_card_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_permission_policy.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_write_proposal.dart';
import 'package:ustc_assistant_app/features/agent/presentation/agent_write_confirmation_card.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  AgentWriteProposalView proposal({
    bool rememberAllowed = true,
    RiskLevel risk = RiskLevel.medium,
  }) => AgentWriteProposalView(
    operationLabel: '新建日程',
    riskLevel: risk,
    actionType: 'create_event',
    targetType: 'event',
    previewLines: const ['标题：健身', '时间：2026-08-01T15:00:00 至 2026-08-01T16:00:00'],
    rememberAllowed: rememberAllowed,
  );

  testWidgets('renders preview, risk badge and approve/reject buttons', (tester) async {
    var approved = false;
    var rejected = false;
    await tester.pumpWidget(wrap(AgentWriteConfirmationCard(
      proposal: proposal(),
      onApprove: () => approved = true,
      onReject: () => rejected = true,
      onRemember: () {},
      onGoToSettings: () {},
    )));
    expect(find.text('新建日程'), findsOneWidget);
    expect(find.text('标题：健身'), findsOneWidget);
    expect(find.text('确认本次'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('此类型以后不再确认'), findsOneWidget);

    await tester.tap(find.text('确认本次'));
    expect(approved, isTrue);
    await tester.tap(find.text('取消'));
    expect(rejected, isTrue);
  });

  testWidgets('hides remember option when rememberAllowed is false', (tester) async {
    await tester.pumpWidget(wrap(AgentWriteConfirmationCard(
      proposal: proposal(rememberAllowed: false),
      onApprove: () {},
      onReject: () {},
      onRemember: () {},
      onGoToSettings: () {},
    )));
    expect(find.text('此类型以后不再确认'), findsNothing);
  });

  testWidgets('shows a risk badge label', (tester) async {
    await tester.pumpWidget(wrap(AgentWriteConfirmationCard(
      proposal: proposal(risk: RiskLevel.high),
      onApprove: () {},
      onReject: () {},
      onRemember: () {},
      onGoToSettings: () {},
    )));
    expect(find.text('高'), findsOneWidget); // 风险徽标
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run（在 `app/` 下）：`flutter test test/features/agent/agent_write_confirmation_card_test.dart`
Expected: FAIL，`AgentWriteConfirmationCard` 未定义。

- [ ] **Step 3: 实现确认卡**

`app/lib/features/agent/presentation/agent_write_confirmation_card.dart`：

```dart
import 'package:flutter/material.dart';

import '../domain/agent_permission_policy.dart';
import '../domain/agent_write_proposal.dart';

/// 聊天内联写确认卡：预览写操作 + 风险徽标 + 确认/取消/此类型以后不再确认/去权限设置。
class AgentWriteConfirmationCard extends StatelessWidget {
  const AgentWriteConfirmationCard({
    super.key,
    required this.proposal,
    required this.onApprove,
    required this.onReject,
    required this.onRemember,
    required this.onGoToSettings,
  });

  final AgentWriteProposalView proposal;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onRemember;
  final VoidCallback onGoToSettings;

  static ({String label, Color color}) _riskStyle(RiskLevel risk) => switch (risk) {
    RiskLevel.low => (label: '低', color: Colors.green),
    RiskLevel.medium => (label: '中', color: Colors.amber),
    RiskLevel.high => (label: '高', color: Colors.deepOrange),
    RiskLevel.critical => (label: '关键', color: Colors.red),
  };

  @override
  Widget build(BuildContext context) {
    final risk = _riskStyle(proposal.riskLevel);
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(proposal.operationLabel,
                    style: theme.textTheme.titleSmall),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: risk.color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('风险：${risk.label}',
                    style: TextStyle(color: risk.color, fontSize: 12)),
              ),
            ]),
            const SizedBox(height: 8),
            for (final line in proposal.previewLines)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(line, style: theme.textTheme.bodyMedium),
              ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 4, children: [
              FilledButton(onPressed: onApprove, child: const Text('确认本次')),
              OutlinedButton(onPressed: onReject, child: const Text('取消')),
              if (proposal.rememberAllowed)
                TextButton(onPressed: onRemember, child: const Text('此类型以后不再确认')),
              TextButton(onPressed: onGoToSettings, child: const Text('去权限设置')),
            ]),
          ],
        ),
      ),
    );
  }
}
```

注：`Colors.withValues(alpha:)` 需 Flutter ≥3.27；若项目 SDK 较低，改用
`risk.color.withOpacity(0.15)`（已有代码的用法以仓库为准，用 Grep 确认）。

- [ ] **Step 4: 聊天页接入确认卡**

`agent_chat_page.dart`：

1. 增加判定（在现有 `needsLogin` 附近）：

```dart
  bool get _needsWriteConfirmation {
    final last = _messages.isEmpty ? null : _messages.last;
    return last is _AssistantMessage &&
        last.state == AgentRunState.waitingForUser &&
        last.userAction?.type == AgentUserActionType.writeConfirmation;
  }
```

2. `_buildMessageList` 的 `itemCount` 改为：

```dart
    final extraItems = (needsLogin ? 1 : 0) + (_needsWriteConfirmation ? 1 : 0);
    itemCount: _messages.length + extraItems,
```

并在 itemBuilder 末尾（`index == _messages.length` 处，与 `_buildNeedsLogin()` 并列）返回 `_buildWriteConfirmationCard()`；若两者同时为真，按顺序追加（登录横幅先，确认卡后）。

3. 新增 `_buildWriteConfirmationCard()`：

```dart
  Widget _buildWriteConfirmationCard() {
    final last = _messages.last as _AssistantMessage;
    final view = last.userAction?.writeProposal;
    if (view == null) return const SizedBox.shrink();
    final accountId = widget.accountId;
    final runId = last.runId;
    return AgentWriteConfirmationCard(
      proposal: view,
      onApprove: () => widget.sessionService.confirmWriteProposal(
        accountId: accountId,
        runId: runId,
        approve: true,
        remember: false,
      ).drain<void>(),
      onReject: () => widget.sessionService.confirmWriteProposal(
        accountId: accountId,
        runId: runId,
        approve: false,
        remember: false,
      ).drain<void>(),
      onRemember: () => widget.sessionService.confirmWriteProposal(
        accountId: accountId,
        runId: runId,
        approve: true,
        remember: true,
      ).drain<void>(),
      onGoToSettings: () => context.push('/agent-settings'),
    );
  }
```

（`_AssistantMessage` 的实际字段名以 `agent_chat_page.dart` 为准——若它暴露 `runId`/`userAction`/`state` 的方式不同，用 Grep 对齐；`sessionService` 字段名同样以页面实际为准。）

- [ ] **Step 5: 运行测试确认通过**

Run（在 `app/` 下）：
```
flutter test test/features/agent/agent_write_confirmation_card_test.dart
flutter test test/features/agent/agent_chat_page_test.dart
```
Expected: 全部 PASS（含既有聊天页测试不回归）。

- [ ] **Step 6: 提交**

```bash
git add app/lib/features/agent/presentation/agent_write_confirmation_card.dart \
        app/lib/features/agent/presentation/agent_chat_page.dart \
        app/test/features/agent/agent_write_confirmation_card_test.dart
git commit -m "feat(agent): add inline write confirmation card to chat page"
```
---

### Task 11: 设置页「Agent 权限」区

**Files:**
- Create: `app/lib/features/agent/presentation/agent_permission_section.dart`（独立分区 widget）
- Modify: `app/lib/features/agent/application/agent_permission_policy_service.dart`（加 `recentPermissionChanges`）
- Modify: `app/lib/features/agent/presentation/agent_settings_page.dart`（构造参数加 `policyService`；在配置分支内嵌入分区）
- Modify: `app/lib/app/router.dart`（settings 路由就地构造 `AgentPermissionPolicyService` 并传入）
- Test: `app/test/features/agent/agent_permission_section_test.dart`

**Interfaces:**
- Consumes: Task 2 的 `AgentPermissionPolicyService`（`listPolicies`/`updatePolicy`/`resetDefaults`/`defaultMode`/`defaultRisk`/`recentPermissionChanges`）。
- Produces: `AgentPermissionSection` widget。

- [ ] **Step 1: 写失败的权限分区测试**

`app/test/features/agent/agent_permission_section_test.dart`：

```dart
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_permission_policy_service.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_permission_policy.dart';
import 'package:ustc_assistant_app/features/agent/presentation/agent_permission_section.dart';

class _FixedClock implements BeijingClock {
  @override
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);
}

void main() {
  late AppDatabase db;
  late AgentPermissionPolicyService policy;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    policy = AgentPermissionPolicyService(database: db, clock: _FixedClock());
  });

  tearDown(() => db.close());

  testWidgets('lists policy rows and shows the current mode', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: AgentPermissionSection(accountId: 'a1', policyService: policy))));
    await tester.pumpAndSettle();
    expect(find.text('新建日程'), findsOneWidget);
    expect(find.text('首次确认后放行'), findsWidgets); // create_event 默认 ask_first_time
    // 权限策略行无下拉（critical 锁定）
    expect(find.text('调整确认策略'), findsOneWidget);
    expect(find.text('恢复默认'), findsOneWidget);
  });

  testWidgets('changing a mode calls updatePolicy and persists', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: AgentPermissionSection(accountId: 'a1', policyService: policy))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('perm-create_event')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('总是允许').last);
    await tester.pumpAndSettle();
    expect(await policy.resolve(accountId: 'a1', actionType: 'create_event',
        targetType: 'event', riskLevel: RiskLevel.medium), PermissionDecision.allow);
  });

  testWidgets('restore defaults clears account policies', (tester) async {
    await policy.updatePolicy(accountId: 'a1', actionType: 'create_event',
        targetType: 'event', mode: ConfirmationMode.alwaysAllow,
        riskLevel: RiskLevel.medium, enabled: true, updatedBy: 'user');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: AgentPermissionSection(accountId: 'a1', policyService: policy))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    expect(await policy.listPolicies('a1'), isEmpty);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run（在 `app/` 下）：`flutter test test/features/agent/agent_permission_section_test.dart`
Expected: FAIL，`AgentPermissionSection` 未定义。

- [ ] **Step 3: 策略服务加 recentPermissionChanges**

`agent_permission_policy_service.dart` 追加：

```dart
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
```

- [ ] **Step 4: 实现权限分区 widget**

`app/lib/features/agent/presentation/agent_permission_section.dart`：

```dart
import 'package:flutter/material.dart';

import '../application/agent_permission_policy_service.dart';
import '../domain/agent_permission_policy.dart';

/// 设置页「Agent 权限」分区：列出策略项、切换确认模式、恢复默认、查看最近变更。
class AgentPermissionSection extends StatefulWidget {
  const AgentPermissionSection({
    super.key,
    required this.accountId,
    required this.policyService,
  });

  final String accountId;
  final AgentPermissionPolicyService policyService;

  @override
  State<AgentPermissionSection> createState() => _AgentPermissionSectionState();
}

/// 设置页展示的策略项（含中文标签）。
const kAgentPermissionRows = <(String actionType, String targetType, String label)>[
  ('create_event', 'event', '新建日程'),
  ('update_event', 'event', '修改/删除日程'),
  ('create_task', 'task', '新建任务'),
  ('plan_task', 'plan_block', '安排任务时间段'),
  ('create_user_overlay', 'overlay', '设置个人标注'),
  ('record_attendance_decision', 'event', '记录出勤决定'),
  ('record_listening_mode', 'event', '设置听讲模式'),
  ('create_schedule_relation', 'relation', '记录日程关系'),
  ('set_reminder', 'event', '设置提醒'),
  ('update_permission_policy', 'permission', '调整确认策略'),
];

String _modeLabel(ConfirmationMode mode) => switch (mode) {
  ConfirmationMode.alwaysAsk => '每次都问',
  ConfirmationMode.askFirstTime => '首次确认后放行',
  ConfirmationMode.alwaysAllow => '总是允许',
  ConfirmationMode.alwaysDeny => '总是禁止',
};

class _AgentPermissionSectionState extends State<AgentPermissionSection> {
  Map<String, ConfirmationMode> _modes = {};
  List<ActionLog> _recent = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await widget.policyService.listPolicies(widget.accountId);
    final byKey = {
      for (final r in rows) '${r.actionType}:${r.targetType}': r.confirmationMode,
    };
    final recent = await widget.policyService.recentPermissionChanges(widget.accountId);
    if (!mounted) return;
    setState(() {
      _modes = byKey;
      _recent = recent;
      _loading = false;
    });
  }

  Future<void> _setMode(String actionType, String targetType, ConfirmationMode mode) async {
    await widget.policyService.updatePolicy(
      accountId: widget.accountId,
      actionType: actionType,
      targetType: targetType,
      mode: mode,
      riskLevel: AgentPermissionPolicyService.defaultRisk(actionType),
      enabled: true,
      updatedBy: 'user',
    );
    await _load();
  }

  Future<void> _restoreDefaults() async {
    await widget.policyService.resetDefaults(widget.accountId);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 16, left: 16, right: 16),
          child: Row(children: [
            Text('Agent 权限', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            TextButton(onPressed: _restoreDefaults, child: const Text('恢复默认')),
          ]),
        ),
        for (final (actionType, targetType, label) in kAgentPermissionRows)
          ListTile(
            key: Key('perm-$actionType'),
            title: Text(label),
            subtitle: Text(_modeLabel(_modes['$actionType:$targetType'] ??
                AgentPermissionPolicyService.defaultMode(actionType))),
            trailing: actionType == 'update_permission_policy'
                ? const Text('始终人工确认')
                : DropdownButton<ConfirmationMode>(
                    value: _modes['$actionType:$targetType'] ??
                        AgentPermissionPolicyService.defaultMode(actionType),
                    items: ConfirmationMode.values
                        .map((mode) => DropdownMenuItem(
                            value: mode, child: Text(_modeLabel(mode))))
                        .toList(),
                    onChanged: (mode) {
                      if (mode != null) _setMode(actionType, targetType, mode);
                    },
                  ),
          ),
        if (_recent.isNotEmpty) ...[
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('最近权限变更', style: Theme.of(context).textTheme.titleSmall),
          ),
          for (final log in _recent)
            ListTile(
              dense: true,
              title: Text(log.safeSummary, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${DateTime.fromMillisecondsSinceEpoch(log.occurredAt).toLocal()}'),
            ),
        ],
      ],
    );
  }
}
```

- [ ] **Step 5: 设置页与路由接线**

`agent_settings_page.dart`：`AgentSettingsPage` 构造参数加 `required this.policyService`（类型 `AgentPermissionPolicyService`），字段 `final AgentPermissionPolicyService policyService;`，import 对应服务与分区 widget。在 configured 分支内（iCourse 授权段之后、摘要段之前）嵌入：

```dart
    AgentPermissionSection(
      accountId: widget.accountId,
      policyService: widget.policyService,
    ),
```

`app/lib/app/router.dart` settings 路由的 `AgentSettingsPage(...)` 加参数：

```dart
          policyService: AgentPermissionPolicyService(
            database: database,
            clock: const SystemBeijingClock(),
          ),
```

（import `agent_permission_policy_service.dart` 与 `core/time/beijing_clock.dart`，以现有 import 为准。）

- [ ] **Step 6: 运行测试确认通过**

Run（在 `app/` 下）：
```
flutter test test/features/agent/agent_permission_section_test.dart
flutter test test/features/agent/agent_settings_page_test.dart
```
Expected: 全部 PASS（既有设置页测试需适配新的构造参数——更新既有测试的构造调用，只加 `policyService:` 一行）。

- [ ] **Step 7: 提交**

```bash
git add app/lib/features/agent/presentation/agent_permission_section.dart \
        app/lib/features/agent/presentation/agent_settings_page.dart \
        app/lib/features/agent/application/agent_permission_policy_service.dart \
        app/lib/app/router.dart \
        app/test/features/agent/agent_permission_section_test.dart \
        app/test/features/agent/agent_settings_page_test.dart
git commit -m "feat(agent): add permission policy management section to settings"
```
---

### Task 12: 组合级集成测试（写流程经 AgentComposition）

**Files:**
- Modify: `app/test/integration/agent_composition_flow_test.dart`（追加两个 `test`）

**Interfaces:**
- Consumes: 该文件已有的 `_seedAccount`/`_seedAgentConfig`/`_buildTestComposition`/`_ScriptedProvider`/`_ScriptedCall`/`_CountingResumableYoungGateway`（helper 名以文件内实际为准，动手前先读该文件确认签名）。
- Produces: 无新生产代码。

- [ ] **Step 1: 追加写流程集成测试**

在 `agent_composition_flow_test.dart` 的 `main()` 内追加（复用文件内已有 helper；`_seedAgentConfig` 的确切签名先读文件确认，若缺参则按实际补齐）：

```dart
  test('composition wiring: confirm commits a personal event and leaks no id', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final protector = _inMemoryProtector(); // 用文件内已有的 in-memory CredentialProtector 实例
    await _seedAccount(db, 'acc-1');
    await _seedAgentConfig(db, 'acc-1');

    final provider = _ScriptedProvider([
      _ScriptedCall(() => [
        const ToolUseCompletedEvent(
          id: 'tu-1',
          name: 'create_event',
          input: {
            'title': '健身',
            'start_at': '2026-08-01T15:00:00+08:00',
            'end_at': '2026-08-01T16:00:00+08:00',
          },
        ),
        const CompletedEvent(),
      ]),
      _ScriptedCall(() => [
        const TextDeltaEvent('已为你新建日程「健身」。'),
        const CompletedEvent(),
      ]),
    ]);
    final gateway = _CountingResumableYoungGateway();
    final composition = await _buildTestComposition(
      db,
      'acc-1',
      provider: provider,
      gateway: gateway,
      protector: protector,
    );
    addTearDown(composition.dispose);

    // 10 个写工具全部注册。
    for (final name in const [
      'create_event', 'update_event', 'create_task', 'plan_task',
      'create_user_overlay', 'record_attendance_decision', 'record_listening_mode',
      'create_schedule_relation', 'set_reminder', 'update_permission_policy',
    ]) {
      expect(composition.registry.isRegistered(name), isTrue,
          reason: 'write tool $name should be registered');
    }

    final states = <AgentRunViewState>[];
    final done = Completer<void>();
    late String runId;
    composition.sessionService
        .send(accountId: 'acc-1', userText: '帮我建个健身日程')
        .listen((s) {
      states.add(s);
      if (s.state == AgentRunState.waitingForUser) runId = s.runId;
    }, onDone: done.complete);

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(
      states.any((s) => s.userAction?.type == AgentUserActionType.writeConfirmation),
      isTrue,
      reason: 'create_event should pause for confirmation',
    );
    await composition.sessionService
        .confirmWriteProposal(accountId: 'acc-1', runId: runId, approve: true, remember: false)
        .drain<void>();
    await done.future;

    expect(states.last.state, AgentRunState.completed);
    final event = (await db.select(db.calendarEvents)).getSingle();
    expect(event.title, '健身');
    final logs = await db.actionLogsRepository.selectAll();
    expect(logs.any((l) => l.source == 'agent' && l.actionType == 'create_event'), isTrue);

    // 捕获请求不泄漏本地 DB 主键。
    final eventId = event.id;
    final toolResults = <String>[
      for (final req in provider.requests)
        for (final message in req.messages)
          if (message.role == 'user')
            for (final block in message.content)
              if (block is LlmToolResultBlock) block.content,
    ];
    expect(toolResults.join('\n'), isNot(contains(eventId)));
  });

  test('composition wiring: remember relaxes, second identical write auto-executes', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final protector = _inMemoryProtector();
    await _seedAccount(db, 'acc-1');
    await _seedAgentConfig(db, 'acc-1');

    // 第一次：create_event -> 确认卡；用户勾选"以后不再确认"。
    final firstProvider = _ScriptedProvider([
      _ScriptedCall(() => [
        const ToolUseCompletedEvent(id: 'tu-1', name: 'create_event',
            input: {'title': '健身', 'start_at': '2026-08-01T15:00:00+08:00', 'end_at': '2026-08-01T16:00:00+08:00'}),
        const CompletedEvent(),
      ]),
      _ScriptedCall(() => [const TextDeltaEvent('已创建。'), const CompletedEvent()]),
    ]);
    final first = await _buildTestComposition(db, 'acc-1',
        provider: firstProvider, gateway: _CountingResumableYoungGateway(), protector: protector);
    addTearDown(first.dispose);
    final done1 = Completer<void>();
    late String runId1;
    first.sessionService.send(accountId: 'acc-1', userText: '建个日程').listen((s) {
      if (s.state == AgentRunState.waitingForUser) runId1 = s.runId;
    }, onDone: done1.complete);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await first.sessionService
        .confirmWriteProposal(accountId: 'acc-1', runId: runId1, approve: true, remember: true)
        .drain<void>();
    await done1.future;

    // 第二次：同样的 create_event 不再出现确认卡（ask_first_time 已放行为 always_allow）。
    final secondProvider = _ScriptedProvider([
      _ScriptedCall(() => [
        const ToolUseCompletedEvent(id: 'tu-1', name: 'create_event',
            input: {'title': '复习', 'start_at': '2026-08-02T09:00:00+08:00', 'end_at': '2026-08-02T10:00:00+08:00'}),
        const CompletedEvent(),
      ]),
      _ScriptedCall(() => [const TextDeltaEvent('已创建。'), const CompletedEvent()]),
    ]);
    final second = await _buildTestComposition(db, 'acc-1',
        provider: secondProvider, gateway: _CountingResumableYoungGateway(), protector: protector);
    addTearDown(second.dispose);
    final states2 = <AgentRunViewState>[];
    final done2 = Completer<void>();
    second.sessionService.send(accountId: 'acc-1', userText: '再建个复习日程').listen((s) {
      states2.add(s);
    }, onDone: done2.complete);
    await done2.future;

    expect(states2.any((s) => s.userAction?.type == AgentUserActionType.writeConfirmation),
        isFalse, reason: 'after remember, the same action auto-executes');
    expect(states2.last.state, AgentRunState.completed);
    expect((await db.select(db.calendarEvents)).get().length, 2);
  });
```

注：`test` 的 import（`AgentRunViewState`/`AgentRunState`/`AgentUserActionType`/`LlmToolResultBlock`）需加到文件头部 import。

- [ ] **Step 2: 运行测试确认通过**

Run（在 `app/` 下）：
```
flutter test test/integration/agent_composition_flow_test.dart
```
Expected: 新增两个用例 + 既有用例全部 PASS。

- [ ] **Step 3: 提交**

```bash
git add app/test/integration/agent_composition_flow_test.dart
git commit -m "test(agent): composition-level write flow with confirmation and remember"
```

---

### Task 13: 全量验证 + 文档同步

**Files:**
- Modify: `AGENTS.md`（能力清单第 7 条追加写工具能力；「强制安全规则」更新）
- Modify: `docs/read-only-agent-handoff.md`（第 0 节与第 9 节：写工具里程碑完成状态）
- 无新测试文件；只跑全量验证。

- [ ] **Step 1: 全量自动验证**

在 worktree 下运行（见 AGENTS.md 验证节；Python 测试必须 `PYTHONPATH` 指向 worktree 的 `src`）：

```bash
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
cd app
flutter analyze
flutter test
flutter build windows --release
```

Expected: Python 全部通过（应不回归既有 382 项以上）、`flutter analyze` 无问题、Flutter 全部测试通过、Windows Release 构建成功。任何失败回到对应 Task 修复并重跑，不要带着失败提交。

- [ ] **Step 2: 边界扫描**

在 worktree 下确认无泄漏：`git grep` 检查 `app/lib/features/agent/` 与 `src/` 无真实密钥/完整账号/cookie 实值新增（沿用修复轮 Task 9 Step 5 的检查项）；写工具结果字段只含 allowlist 键。`git diff --check` 无空白错误。

- [ ] **Step 3: 更新文档**

`AGENTS.md` 第 7 条追加：

```text
   写工具：10 个受控本地写工具（create_event/update_event/create_task/plan_task/
   create_user_overlay/record_attendance_decision/record_listening_mode/
   create_schedule_relation/set_reminder/update_permission_policy），全部经"审批门"
   按风险分级确认（聊天内联确认卡），AgentPermissionPolicy 表迁移并接入运行时决策，
   设置页可管理确认策略；权限变更永远需要用户亲手确认（update_permission_policy）。
   写能力只作用于本地业务数据，不新增任何学校/外部写通道。
```

`docs/read-only-agent-handoff.md` 第 0 节追加一行：写工具里程碑（本计划）已实现并合并
到 `main`；第 9 节"下一阶段"把第 1 项标记为完成，后续顺序变为每日简报等。只读 Agent 的
既有已知限制（本地导航 chip、懒启动网关、默认学期单一数据源、Minor 分类待执行、真实验收
待执行）保持不变；写工具的真实验收清单可并入 `docs/acceptance/read-only-agent.md`（如
需则新增小节，由用户真实验收填写）。

- [ ] **Step 4: 提交**

```bash
git add AGENTS.md docs/read-only-agent-handoff.md
git commit -m "docs: mark agent write-tools milestone complete and sync handoff"
```
