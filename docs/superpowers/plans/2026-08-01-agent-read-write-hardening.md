# Agent Read/Write Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 加固十个 Agent 本地写工具的输入、确认、事务与审计边界，并把教务默认学期收敛为一份手工配置源。

**Architecture:** 保留现有 `AgentWriteTool -> AgentWriteGateway -> Application Service` 结构，在工具入口增加严格参数读取器，在提案阶段读取账户隔离的目标快照，并用 `AgentWriteUnitOfWork` 把业务变更、成功日志、确认决策和权限变化放入同一 Drift 事务。`config/source-defaults.json` 继续作为唯一手写学期配置，由 Python 统一 CLI 生成 Flutter 常量并用一致性测试防止过期。

**Tech Stack:** Dart/Flutter 3.44.5、Drift/SQLite、Python 3.10+、`unittest`、现有 `ustc_assistant` Conda 环境；不新增第三方依赖。

## Global Constraints

- 设计依据：`docs/superpowers/specs/2026-08-01-agent-read-write-hardening-design.md`。
- 只在 `feature/write-tools` 工作树实施；开始前确认 HEAD 至少包含 spec 提交 `a126c90`。
- 不修改或提交现有脏文件 `app/windows/flutter/generated_plugin_registrant.*`、`generated_plugins.cmake` 和用户文件 `docs/agent-testing.md`。
- Python 只能使用 Conda 环境 `ustc_assistant`，禁止 `pip install`，禁止修改 base 环境。
- 时间统一为 `Asia/Shanghai`；不得根据年份推算教务内部 semesterId。
- 写目标只允许本地个人数据或本地 overlay；二课报名、取消报名和学校/外部系统写操作永久禁止。
- 模型不得接触 DB 主键、完整学校账号、姓名、Cookie、Token、教务上下文 ID 或完整原始课表。
- `ref_*` 只在当前 run 内解析；所有最终读取和写入继续按学校账号隔离。
- 自动测试不得访问学校网站、学校 LLM API 或真实 Edge 会话。
- 每个 Task 先运行新增测试确认失败，再写实现；每个 Task 单独提交，不能把七个 Task 压成一个提交。

## File Map

- Create `app/lib/features/agent/application/write_argument_reader.dart`: 十个写工具共享的严格参数读取器。
- Create `app/lib/features/agent/domain/agent_write_unit_of_work.dart`: 平台无关事务边界接口。
- Create `app/lib/features/agent/data/drift_agent_write_unit_of_work.dart`: Drift 外层事务实现。
- Modify `app/lib/features/agent/domain/agent_write_gateway.dart`: 目标快照查询契约。
- Modify `app/lib/features/agent/data/drift_agent_write_gateway.dart`: 账户隔离的事件/任务/执行块快照。
- Modify `app/lib/features/agent/application/agent_write_tools.dart`: 严格校验、预检和目标化预览。
- Modify `app/lib/features/agent/application/agent_write_tool.dart`: 原子提交与确认仓恢复语义。
- Modify `app/lib/features/agent/application/agent_permission_policy_service.dart`: 固定审计类型与权限历史。
- Modify `app/lib/features/agent/application/agent_session_service.dart`: 确认恢复结果与缺失 handle 处理。
- Modify `app/lib/features/agent/application/agent_composition.dart`: 注入事务边界和返回确认结果。
- Modify `app/lib/features/agent/presentation/agent_write_confirmation_card.dart`: 单次提交状态和错误显示。
- Modify `app/lib/features/agent/presentation/agent_chat_page.dart`: await 确认恢复并传播失败。
- Create `app/lib/core/config/generated_source_defaults.dart`: 由 Python 生成、不得手改的 Flutter 默认配置。
- Modify `src/ustc_assistant/config.py` and `src/ustc_assistant/cli.py`: 生成器与统一 CLI 子命令。
- Modify `app/lib/features/settings/application/settings_service.dart` and `settings_page.dart`: 使用生成配置。

---

### Task 1: Strict Runtime Arguments And Schema Alignment

**Files:**
- Create: `app/lib/features/agent/application/write_argument_reader.dart`
- Create: `app/test/features/agent/write_argument_reader_test.dart`
- Modify: `app/lib/features/agent/application/agent_write_tools.dart`
- Modify: `app/test/features/agent/write_tools_test.dart`

**Interfaces:**
- Produces: `WriteArgumentReader(Map<String, Object?> values, Set<String> allowedKeys)` with `requiredString`, `optionalString`, `optionalBool`, `optionalInt`, `requiredStringList`, `requiredIntList`, `optionalStringList`, `requiredEnum`, `optionalEnum`, `contains`, and `rejectUnknownKeys`.
- Produces: all validation failures as `FormatException`, which existing `AgentWriteTool.execute` maps to `invalid_write_arguments`.
- Consumes: no code from later tasks.

- [ ] **Step 1: Add focused reader tests**

Cover exact required/optional types, booleans not accepted as integers, blank required strings, list element types, strict enums and unknown keys:

```dart
test('rejects unknown keys and enum fallback', () {
  final reader = WriteArgumentReader(
    {'mode': 'silent', 'extra': true},
    {'mode'},
  );
  expect(reader.rejectUnknownKeys, throwsFormatException);

  final enumReader = WriteArgumentReader({'mode': 'silent'}, {'mode'});
  expect(
    () => enumReader.requiredEnum('mode', const {'listen', 'not_listen'}),
    throwsFormatException,
  );
});
```

- [ ] **Step 2: Run the reader test and verify failure**

Run:

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/write_argument_reader_test.dart
Pop-Location
```

Expected: FAIL because `write_argument_reader.dart` does not exist.

- [ ] **Step 3: Implement `WriteArgumentReader`**

Use explicit `Object?` checks; do not use permissive `as` casts or enum fallback:

```dart
final class WriteArgumentReader {
  WriteArgumentReader(this._values, Set<String> allowedKeys)
      : _allowedKeys = Set.unmodifiable(allowedKeys);

  final Map<String, Object?> _values;
  final Set<String> _allowedKeys;

  bool contains(String key) => _values.containsKey(key);

  void rejectUnknownKeys() {
    final unknown = _values.keys.toSet().difference(_allowedKeys);
    if (unknown.isNotEmpty) throw FormatException('unknown keys: $unknown');
  }

  String requiredString(String key) {
    final value = _values[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$key must be non-blank text');
    }
    return value.trim();
  }

  String requiredEnum(String key, Set<String> values) {
    final value = requiredString(key);
    if (!values.contains(value)) throw FormatException('$key has invalid value');
    return value;
  }
}
```

Implement the remaining methods with the same strictness. Optional methods return null only when the key is absent or explicitly null; a present wrong type throws.

- [ ] **Step 4: Add failing tool-level argument tests**

Invoke tools through `execute`, not just schema inspection. Add table-driven cases for:

| Tool | Invalid cases that must return `invalid_write_arguments` |
|---|---|
| `create_event` | timed pair missing; all-day pair missing; timed/all-day fields mixed; unknown type; extra key |
| `create_task` | unknown importance; zero/negative estimated minutes; non-string tag |
| `plan_task` | unknown status; end not after start; blank optional title |
| `update_event` | no-op; unknown scope/status/type/importance; delete plus status/edit; only one end of a time pair |
| `create_user_overlay` | no mutation; unknown scope/attendance/listening/importance |
| `record_attendance_decision` | unknown decision instead of falling back to undecided |
| `record_listening_mode` | unknown mode instead of falling back to listen |
| `create_schedule_relation` | unknown conflict state; same ref on both sides |
| `set_reminder` | negative, non-integer or duplicate-only malformed offsets |
| `update_permission_policy` | unknown action/target combination or mode |

Also assert every schema has `additionalProperties: false`, `create_event` declares `importance`, and `update_event` both declares and implements `type` and `importance`.

- [ ] **Step 5: Replace raw casts and fallback parsing in all ten tools**

At the beginning of each `propose`, instantiate a reader with that tool's exact schema keys and call `rejectUnknownKeys`. Apply these non-negotiable rules:

```dart
if (allDay) {
  if (!r.contains('start_date') || !r.contains('end_date_exclusive') ||
      r.contains('start_at') || r.contains('end_at')) {
    throw const FormatException('invalid all-day field set');
  }
} else if (!r.contains('start_at') || !r.contains('end_at') ||
    r.contains('start_date') || r.contains('end_date_exclusive')) {
  throw const FormatException('invalid timed field set');
}
```

For `update_event`, reject zero changed fields and enforce `delete`, `status`, and field edits as mutually exclusive modes. Convert `type` with an exhaustive switch and carry it through `_replacementEvent`; add `importance` to schema and keep its existing replacement behavior. Sort and deduplicate reminder offsets before proposal creation.

- [ ] **Step 6: Run focused tests**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/write_argument_reader_test.dart test/features/agent/write_tools_test.dart
Pop-Location
```

Expected: PASS; no invalid enum silently becomes a default.

- [ ] **Step 7: Commit Task 1**

```powershell
git add app/lib/features/agent/application/write_argument_reader.dart app/lib/features/agent/application/agent_write_tools.dart app/test/features/agent/write_argument_reader_test.dart app/test/features/agent/write_tools_test.dart
git commit -m "fix(agent): validate write tool arguments at runtime"
```

---

### Task 2: Account-Scoped Target Snapshots And Preflight

**Files:**
- Modify: `app/lib/features/agent/domain/agent_write_gateway.dart`
- Modify: `app/lib/features/agent/data/drift_agent_write_gateway.dart`
- Modify: `app/lib/features/agent/application/agent_write_tools.dart`
- Modify: `app/test/features/agent/drift_agent_write_gateway_test.dart`
- Modify: `app/test/features/agent/write_tools_test.dart`

**Interfaces:**
- Produces: immutable `EventWriteSnapshot` with identity plus title/time/location fields.
- Produces: `AgentWriteGateway.eventSnapshot(String eventId)`; retains `taskById` and `planBlockById` for task/block summaries.
- Consumes: strict arguments from Task 1.

- [ ] **Step 1: Write failing gateway snapshot tests**

Seed two accounts. Assert account A can read its event snapshot and cannot read account B's event. Verify source events preserve title, start/end, location, source and course series identity without exposing the row outside the gateway test.

```dart
final snapshot = await gatewayA.eventSnapshot('event-a');
expect(snapshot.title, '量子物理 B');
expect(snapshot.location, '5101');
expect(snapshot.source, 'ustc_jw');
await expectLater(gatewayA.eventSnapshot('event-b'), throwsStateError);
```

- [ ] **Step 2: Run snapshot tests and verify failure**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/drift_agent_write_gateway_test.dart
Pop-Location
```

Expected: FAIL because `eventSnapshot` and snapshot fields do not exist.

- [ ] **Step 3: Add snapshot contract and Drift implementation**

Replace `EventWriteIdentity` with:

```dart
final class EventWriteSnapshot {
  const EventWriteSnapshot({
    required this.id,
    required this.source,
    required this.type,
    required this.title,
    required this.allDay,
    this.startAt,
    this.endAt,
    this.startDate,
    this.endDateExclusive,
    this.location,
    this.personalSeriesId,
    this.occurrenceKey,
    this.courseSeriesId,
  });
  // Fields exactly match constructor arguments.
  bool get isPersonal => source == 'user';
}
```

Implement `eventSnapshot` with an account-filtered calendar event query plus `EffectiveEventRepository` only for course series identity. Keep DB IDs inside `commitParams`; only formatted fields enter preview/log text.

- [ ] **Step 4: Write failing target preview and preflight tests**

For every existing-object tool assert proposal previews identify the target:

- `plan_task`: task title;
- `update_event`, overlay, attendance, listening and reminder: event title and current time;
- relation: left and right title/time;
- permission: target action, target type, current mode and new mode.

Assert `previewLines`, `safeLogSummary` and `toView()` contain no seeded DB ID and no original `ref_*`. Add preflight cases proving a source event reminder/update is rejected before confirmation and `course_series` overlay without a series returns an error before confirmation.

- [ ] **Step 5: Build previews from account-scoped snapshots**

Add private formatters in `agent_write_tools.dart` for event, task and plan block summaries. Required preview shapes are:

```text
目标：量子物理 B
当前时间：2026-03-17 09:45-11:20
地点：5101
变更：状态改为 completed
```

and for relations:

```text
日程 A：电路基本理论 / 2026-03-17 09:45-11:20
日程 B：量子物理 B / 2026-03-17 09:45-11:20
关系：conflict
```

Move personal-source, course-series and target-existence checks into `propose`; keep the same checks in `commit` for time-of-check/time-of-use safety.

- [ ] **Step 6: Run focused tests**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/drift_agent_write_gateway_test.dart test/features/agent/write_tools_test.dart test/features/agent/agent_write_permission_domain_test.dart
Pop-Location
```

Expected: PASS; existing-target confirmations are identifiable and contain no IDs/refs.

- [ ] **Step 7: Commit Task 2**

```powershell
git add app/lib/features/agent/domain/agent_write_gateway.dart app/lib/features/agent/data/drift_agent_write_gateway.dart app/lib/features/agent/application/agent_write_tools.dart app/test/features/agent/drift_agent_write_gateway_test.dart app/test/features/agent/write_tools_test.dart
git commit -m "fix(agent): identify write targets before confirmation"
```

---

### Task 3: Atomic Agent Write Unit Of Work

**Files:**
- Create: `app/lib/features/agent/domain/agent_write_unit_of_work.dart`
- Create: `app/lib/features/agent/data/drift_agent_write_unit_of_work.dart`
- Modify: `app/lib/features/agent/application/agent_write_tool.dart`
- Modify: `app/lib/features/agent/application/agent_composition.dart`
- Modify: `app/lib/features/agent/application/agent_write_tools.dart`
- Modify: `app/test/features/agent/agent_write_tool_test.dart`
- Modify: `app/test/integration/agent_composition_flow_test.dart`

**Interfaces:**
- Produces: `AgentWriteUnitOfWork.run<T>(Future<T> Function() body)`.
- Produces: `DriftAgentWriteUnitOfWork(AppDatabase database)` using `database.transaction(body)`.
- Produces: one shared atomic commit path used by direct allow and confirmed approval.
- Consumes: existing gateway/services and Task 2 proposal snapshots.

- [ ] **Step 1: Add real-Drift rollback tests**

In the composition integration test, set `create_event` to `always_allow`, install a SQLite trigger that aborts `source='agent'` ActionLog insertion, invoke `create_event`, and assert no event and no service ActionLog remains:

```dart
await db.customStatement('''
CREATE TRIGGER fail_agent_log BEFORE INSERT ON action_logs
WHEN NEW.source = 'agent'
BEGIN SELECT RAISE(ABORT, 'forced agent audit failure'); END;
''');
final result = await registry.execute(
  toolName: 'create_event',
  arguments: validTimedEventArguments,
  context: context,
);
expect(result.status, AgentToolStatus.error);
expect(await db.select(db.calendarEvents).get(), isEmpty);
expect(await db.select(db.actionLogs).get(), isEmpty);
```

Add a confirmed `remember=true` case with a trigger aborting permission-policy insertion; assert event, all logs and policy row roll back. Remove triggers in `addTearDown`.

- [ ] **Step 2: Run integration test and prove current partial commit**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/integration/agent_composition_flow_test.dart --plain-name "agent write rolls back when audit persistence fails"
Pop-Location
```

Expected: FAIL because the calendar event survives the later audit failure.

- [ ] **Step 3: Add the unit-of-work interface and Drift adapter**

```dart
abstract interface class AgentWriteUnitOfWork {
  Future<T> run<T>(Future<T> Function() body);
}

final class DriftAgentWriteUnitOfWork implements AgentWriteUnitOfWork {
  DriftAgentWriteUnitOfWork(this.database);
  final AppDatabase database;

  @override
  Future<T> run<T>(Future<T> Function() body) => database.transaction(body);
}
```

Add an immediate fake implementation in unit tests. Do not import Drift from application/domain files.

- [ ] **Step 4: Refactor direct and confirmed commits through one transaction path**

Inject `AgentWriteUnitOfWork` into `AgentWriteTool`, `WriteConfirmationStore`, the ten-tool factory and `AgentComposition`. The atomic operation must:

```dart
return unitOfWork.run(() async {
  final result = await businessCommit(proposal, context);
  if (result.status != AgentToolStatus.success) {
    throw AgentWriteAborted(result);
  }
  await policy.logAgentWrite(/* actual action, success */);
  await afterSuccessfulCommit(); // first-confirm/remember policy mutation; Task 4 adds its audit events
  return result;
});
```

Catch `AgentWriteAborted` outside the transaction and return its original safe result. Catch other failures, attempt one separate `failed` audit without retrying `businessCommit`, then return `write_commit_failed`. Both direct and confirmed paths must call this same helper. Move the existing `markAlwaysAllow` and `recordFirstConfirmation` calls into `afterSuccessfulCommit` now, so Task 3 already makes the permission mutation atomic; Task 4 only adds the final audit taxonomy.

- [ ] **Step 5: Prove nested service transactions obey the outer rollback**

Run rollback tests for one single-write service (`create_task`) and one multi-write service (`create_event` with reminders). Assert all business tables and service logs remain unchanged after forced Agent log failure.

- [ ] **Step 6: Run focused atomicity tests**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_write_tool_test.dart test/integration/agent_composition_flow_test.dart
Pop-Location
```

Expected: PASS; rerunning the failed invocation leaves zero duplicate rows.

- [ ] **Step 7: Commit Task 3**

```powershell
git add app/lib/features/agent/domain/agent_write_unit_of_work.dart app/lib/features/agent/data/drift_agent_write_unit_of_work.dart app/lib/features/agent/application/agent_write_tool.dart app/lib/features/agent/application/agent_composition.dart app/lib/features/agent/application/agent_write_tools.dart app/test/features/agent/agent_write_tool_test.dart app/test/integration/agent_composition_flow_test.dart
git commit -m "fix(agent): make local writes and audits atomic"
```

---

### Task 4: Stable Audit Taxonomy And Permission History

**Files:**
- Modify: `app/lib/features/agent/application/agent_permission_policy_service.dart`
- Modify: `app/lib/features/agent/application/agent_write_tool.dart`
- Modify: `app/lib/features/agent/application/agent_write_tools.dart`
- Modify: `app/lib/features/agent/presentation/agent_permission_section.dart`
- Modify: `app/test/features/agent/agent_permission_policy_service_test.dart`
- Modify: `app/test/features/agent/agent_write_tool_test.dart`
- Modify: `app/test/features/agent/write_tools_test.dart`
- Modify: `app/test/features/agent/agent_permission_section_test.dart`
- Modify: `app/test/integration/agent_composition_flow_test.dart`

**Interfaces:**
- Produces: `logAudit({accountId, source, actionType, riskLevel, result, safeSummary})` as the single ActionLog append method for Agent approval flows.
- Produces exact action types `agent_write_confirm`, `agent_write_decline`, `agent_write_cancel`, `update_permission_policy`, `reset_permission_policy`.
- Consumes: Task 3 atomic callback `afterSuccessfulCommit`.

- [ ] **Step 1: Add failing permission-tool shadowing regression test**

Confirm an `update_permission_policy` proposal targeting `create_event`, then assert:

```dart
final agentLogs = await db.actionLogsRepository.listForAccount('a1');
expect(
  agentLogs.any((log) =>
      log.source == 'agent' &&
      log.actionType == 'update_permission_policy'),
  isTrue,
);
expect(
  agentLogs.where((log) => log.source == 'agent' && log.actionType == 'create_event'),
  isEmpty,
);
```

Expected current failure: proposal.actionType is overwritten with the target action.

- [ ] **Step 2: Add failing audit matrix tests**

Assert exact source/action/result for approve, decline, stop/cancel, ask-first-time transition, remember, settings change, Agent policy tool and reset. Assert `recentPermissionChanges` includes both update and reset, sorted newest first and honoring `limit`.

- [ ] **Step 3: Fix permission proposal field names and whitelist combinations**

In `UpdatePermissionPolicyTool.propose` use:

```dart
final targetActionType = r.requiredEnum('action_type', kAgentPolicyActionTypes);
final targetType = r.requiredEnum(
  'target_type',
  {AgentPermissionPolicyService.targetTypeFor(targetActionType)},
);
return AgentWriteProposal(
  toolName: name,
  actionType: actionType, // always update_permission_policy
  targetType: targetType,
  commitParams: {
    'targetActionType': targetActionType,
    'targetType': targetType,
    'mode': mode,
  },
  // remaining safe fields unchanged
);
```

Define the action/target mapping once in `AgentPermissionPolicyService`; settings rows and tool validation must consume it instead of maintaining independent lists.

- [ ] **Step 4: Implement fixed audit events inside Task 3 transaction**

- On approval, append `source=user/actionType=agent_write_confirm/result=approved`.
- On decline, append `source=user/actionType=agent_write_decline/result=declined`; perform no business commit.
- On pending run cancellation, append `source=agent/actionType=agent_write_cancel/result=cancelled` best-effort, then complete the pending invocation.
- On ask-first-time, append `source=user/actionType=update_permission_policy/result=success` in the same transaction that writes `firstConfirmedAt`.
- On remember, append the same permission action with safe summary `action(target) -> always_allow`.
- On the policy tool, append `source=agent/actionType=update_permission_policy/result=success`; the separate user confirm log remains.

Do not encode local IDs or refs in any summary.

- [ ] **Step 5: Include reset in recent permission history**

Change the Drift predicate to include both action types:

```dart
row.actionType.isIn(const [
  'update_permission_policy',
  'reset_permission_policy',
])
```

Keep account filter, descending `occurredAt`, and limit. Update the permission section widget test to render the reset record.

- [ ] **Step 6: Run focused audit tests**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_permission_policy_service_test.dart test/features/agent/agent_write_tool_test.dart test/features/agent/write_tools_test.dart test/features/agent/agent_permission_section_test.dart test/integration/agent_composition_flow_test.dart
Pop-Location
```

Expected: PASS with one domain success log plus separate user decision/policy logs where applicable.

- [ ] **Step 7: Commit Task 4**

```powershell
git add app/lib/features/agent/application/agent_permission_policy_service.dart app/lib/features/agent/application/agent_write_tool.dart app/lib/features/agent/application/agent_write_tools.dart app/lib/features/agent/presentation/agent_permission_section.dart app/test/features/agent/agent_permission_policy_service_test.dart app/test/features/agent/agent_write_tool_test.dart app/test/features/agent/write_tools_test.dart app/test/features/agent/agent_permission_section_test.dart app/test/integration/agent_composition_flow_test.dart
git commit -m "fix(agent): record write approvals and permission changes accurately"
```

---

### Task 5: Single-Submit Confirmation UI And Resume Recovery

**Files:**
- Modify: `app/lib/features/agent/application/agent_write_tool.dart`
- Modify: `app/lib/features/agent/application/agent_session_service.dart`
- Modify: `app/lib/features/agent/application/agent_composition.dart`
- Modify: `app/lib/features/agent/presentation/agent_write_confirmation_card.dart`
- Modify: `app/lib/features/agent/presentation/agent_chat_page.dart`
- Modify: `app/test/features/agent/agent_write_confirmation_card_test.dart`
- Modify: `app/test/features/agent/agent_write_session_test.dart`
- Modify: `app/test/features/agent/agent_chat_page_test.dart`

**Interfaces:**
- Changes: `WriteConfirmationResumerCallback` returns `Future<AgentToolResult>` instead of `Future<void>`.
- Changes: confirmation-card callbacks return `Future<void>` and are internally guarded by `_submitting`.
- Consumes: Task 4 cancel/decline audit semantics.

- [ ] **Step 1: Add failing completer recovery test**

Register a pending confirmation, remove its store entry to simulate lost handle, call the session resumer, and assert the session emits `confirmation_not_found`, closes, and the pending invocation completes rather than hanging. Wrap with a one-second test timeout.

- [ ] **Step 2: Add failing widget double-click and failure tests**

Use a callback controlled by a `Completer<void>`. Tap approve once, assert all four actions are disabled and “处理中” appears; tap again and assert invocation count remains one. Complete with an error and assert an inline failure message appears and controls become usable again.

- [ ] **Step 3: Make store cancellation complete the supplied completer**

Fix `WriteConfirmationStore.cancel` so a missing map entry still completes the `completer` argument:

```dart
final pending = _pending.remove(handle);
final target = pending?.completer ?? completer;
if (!target.isCompleted) {
  target.complete(const AgentToolResult(
    status: AgentToolStatus.error,
    errorCode: 'cancelled',
  ));
}
```

- [ ] **Step 4: Return and inspect resumer results**

Change the callback typedef and composition closure to return `confirmationStore.resolve(...)`. In `confirmWriteProposal`, if the returned result is `confirmation_not_found`, cancel the paused invocation, remove the paused run through existing cleanup, emit a failed view state with that code, and return without awaiting the orphaned future.

- [ ] **Step 5: Convert the confirmation card to guarded state**

Make `AgentWriteConfirmationCard` stateful with:

```dart
bool _submitting = false;
String? _error;

Future<void> _submit(Future<void> Function() action) async {
  if (_submitting) return;
  setState(() { _submitting = true; _error = null; });
  try {
    await action();
  } catch (_) {
    if (mounted) setState(() => _error = '操作未完成，请重试。');
  } finally {
    if (mounted) setState(() => _submitting = false);
  }
}
```

Disable every card action while submitting. Keep risk label and proposal text visible. Do not expose internal exception text.

- [ ] **Step 6: Await session streams from chat page**

Add `_resolveWriteProposal` that awaits the stream, remembers any `AgentRunState.failed`, and throws a local UI exception after the stream closes. Wire approve/reject/remember to return this Future instead of calling `.drain<void>()` without observing states.

- [ ] **Step 7: Run focused session/UI tests**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_write_confirmation_card_test.dart test/features/agent/agent_write_session_test.dart test/features/agent/agent_chat_page_test.dart
Pop-Location
```

Expected: PASS; double action invokes once and missing handles never leave a waiting run.

- [ ] **Step 8: Commit Task 5**

```powershell
git add app/lib/features/agent/application/agent_write_tool.dart app/lib/features/agent/application/agent_session_service.dart app/lib/features/agent/application/agent_composition.dart app/lib/features/agent/presentation/agent_write_confirmation_card.dart app/lib/features/agent/presentation/agent_chat_page.dart app/test/features/agent/agent_write_confirmation_card_test.dart app/test/features/agent/agent_write_session_test.dart app/test/features/agent/agent_chat_page_test.dart
git commit -m "fix(agent): make write confirmation recovery single-shot"
```

---

### Task 6: Generate Flutter Semester Defaults From Canonical JSON

**Files:**
- Create: `app/lib/core/config/generated_source_defaults.dart`
- Modify: `src/ustc_assistant/config.py`
- Modify: `src/ustc_assistant/cli.py`
- Modify: `tests/config/test_source_config.py`
- Modify: `tests/test_cli.py`
- Modify: `app/lib/features/settings/application/settings_service.dart`
- Modify: `app/lib/features/settings/presentation/settings_page.dart`
- Modify: `app/test/features/settings/settings_test.dart`
- Modify: `README.md`

**Interfaces:**
- Produces: `render_flutter_source_defaults(JwSemesterConfig) -> str` in Python.
- Produces CLI: `python -m ustc_assistant config generate-flutter-defaults --output <path>`.
- Produces Dart constants `kDefaultJwSemesterId`, `kDefaultJwSemesterKey`, `kDefaultJwSemesterDisplayName`, and `kDefaultJwSemester`.
- Consumes: existing strict `load_default_jw_semester` validation.

- [ ] **Step 1: Add failing deterministic generator tests**

```python
def test_render_flutter_defaults_is_deterministic(self):
    rendered = render_flutter_source_defaults(
        JwSemesterConfig(421, "2026spring", "2026 春季学期")
    )
    self.assertIn("const int kDefaultJwSemesterId = 421;", rendered)
    self.assertIn("const String kDefaultJwSemesterKey = '2026spring';", rendered)
    self.assertIn("DO NOT EDIT", rendered)

def test_checked_in_flutter_defaults_match_json(self):
    expected = render_flutter_source_defaults(load_default_jw_semester())
    actual = FLUTTER_OUTPUT.read_text(encoding="utf-8")
    self.assertEqual(actual, expected)
```

Use a Dart-string escaping helper for backslash, quote, CR/LF and dollar sign; add a direct escaping test.

- [ ] **Step 2: Run Python config tests and verify failure**

```powershell
$env:PYTHONPATH = "E:\107\.worktrees\write-tools\src"
conda run -n ustc_assistant python -m unittest tests.config.test_source_config -v
```

Expected: FAIL because renderer and generated file do not exist.

- [ ] **Step 3: Implement renderer and CLI command**

The generated file has exactly this public shape:

```dart
// GENERATED FILE - DO NOT EDIT.
const int kDefaultJwSemesterId = 461;
const String kDefaultJwSemesterKey = '2026fall';
const String kDefaultJwSemesterDisplayName = '2026 秋季学期';
const Map<String, Object> kDefaultJwSemester = {
  'semesterId': kDefaultJwSemesterId,
  'semesterKey': kDefaultJwSemesterKey,
  'displayName': kDefaultJwSemesterDisplayName,
};
```

The CLI creates the output parent directory and writes UTF-8 with `\n` line endings using existing storage helpers where applicable. It returns exit 0; invalid JSON uses existing `SourceConfigError` handling and returns nonzero without writing partial output.

- [ ] **Step 4: Generate the committed Dart file**

```powershell
$env:PYTHONPATH = "E:\107\.worktrees\write-tools\src"
conda run -n ustc_assistant python -m ustc_assistant config generate-flutter-defaults --output app/lib/core/config/generated_source_defaults.dart
```

Expected: file contains `461 / 2026fall / 2026 秋季学期` from the current canonical JSON.

- [ ] **Step 5: Remove handwritten Flutter semester values**

Import generated constants in `SettingsService`; replace its map literal with `kDefaultJwSemester`. In `settings_page.dart`, interpolate the three generated constants rather than a const handwritten subtitle. Keep scenario-specific test fixtures unchanged.

- [ ] **Step 6: Add stale-generation and Flutter-consumer tests**

The Python test compares canonical JSON to the committed Dart file. Flutter tests assert reset writes `kDefaultJwSemester` and settings UI renders values from generated constants. `rg` must show no production `461`, `2026fall` or display name outside canonical JSON and generated Dart:

```powershell
rg -n "461|2026fall|2026 秋季学期" app/lib src/ustc_assistant config
```

Expected production matches: `config/source-defaults.json` and `app/lib/core/config/generated_source_defaults.dart`; README may document current values.

- [ ] **Step 7: Run config and settings tests**

```powershell
$env:PYTHONPATH = "E:\107\.worktrees\write-tools\src"
conda run -n ustc_assistant python -m unittest tests.config.test_source_config tests.test_cli -v
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/settings/settings_test.dart
Pop-Location
```

Expected: PASS; editing only JSON makes the consistency test fail until the generator is run.

- [ ] **Step 8: Document and commit Task 6**

Add the exact generation command and “do not infer semester ID” warning to README, then:

```powershell
git add config/source-defaults.json src/ustc_assistant/config.py src/ustc_assistant/cli.py tests/config/test_source_config.py tests/test_cli.py app/lib/core/config/generated_source_defaults.dart app/lib/features/settings/application/settings_service.dart app/lib/features/settings/presentation/settings_page.dart app/test/features/settings/settings_test.dart README.md
git commit -m "build(config): generate Flutter semester defaults from JSON"
```

Do not change the current canonical value `461 / 2026fall / 2026 秋季学期` in this Task.

---

### Task 7: Cross-Layer Regression, Documentation And Final Verification

**Files:**
- Modify: `app/test/integration/agent_composition_flow_test.dart`
- Modify: `docs/read-only-agent-handoff.md`
- Modify: `docs/acceptance/read-only-agent.md` only to add unexecuted write-tool/manual cases; never mark them complete
- Modify: `AGENTS.md`
- Modify: `docs/agent-testing.md` only if the user explicitly permits editing the currently untracked file; otherwise leave it untouched and record this in the final handoff

**Interfaces:**
- Consumes: all outputs from Tasks 1-6.
- Produces: one composition regression covering strict input -> target preview -> confirmation -> atomic commit -> accurate audit -> remembered policy -> second direct commit.

- [ ] **Step 1: Add the final composition regression**

Use real Drift composition and scripted provider. The test must:

1. query/bind an event or task ref;
2. reject one malformed write as `invalid_write_arguments` with no DB change;
3. produce a confirmation whose preview names the target and contains no ID/ref;
4. approve with remember and assert domain row plus `agent_write_confirm`, domain action and permission logs;
5. invoke the same action again and assert direct success without a second confirmation;
6. force an audit failure for a third write and assert complete rollback.

- [ ] **Step 2: Run all Agent tests**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent test/integration/agent_composition_flow_test.dart test/integration/read_only_agent_flow_test.dart
Pop-Location
```

Expected: PASS; both original read-only flows and hardened write flow remain covered.

- [ ] **Step 3: Update permanent project status**

In `docs/read-only-agent-handoff.md` and `AGENTS.md` record:

- ten write tools are local-only and transactionally audited;
- confirmation target previews and strict runtime validation are implemented;
- exact final verification counts and HEAD are recorded only after commands pass;
- real school API/manual acceptance remains incomplete unless the user actually performs it;
- semester default is generated from `config/source-defaults.json` and current value remains 461.

Add manual cases to acceptance docs with blank `完成：` fields. Never replace user-entered acceptance text.

- [ ] **Step 4: Run Python full verification**

```powershell
$env:PYTHONPATH = "E:\107\.worktrees\write-tools\src"
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
```

Expected: all tests pass; baseline before implementation was 388 tests.

- [ ] **Step 5: Run Flutter full verification**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat analyze
E:\flutter\flutter\bin\flutter.bat test
E:\flutter\flutter\bin\flutter.bat build windows --release
Pop-Location
```

Expected: `No issues found`, all tests pass, and Release executable builds. If the Flutter wrapper hangs without output, capture process/time evidence, stop only the process started by this verification, run direct Dart analysis for diagnostic value, and report the full test/build as unverified rather than passed.

- [ ] **Step 6: Run repository safety checks**

```powershell
git diff --check a126c90..HEAD
git status --short
git grep -n -E "(sk-|api[_-]?key.*=|password.*=|cookie.*=)" -- app/lib/features/agent src/ustc_assistant
```

Inspect matches manually; fixtures and field names are not secrets. Confirm no `temp.md`, `tmp/`, browser profile, raw response, real key/account or generated Windows noise is staged.

- [ ] **Step 7: Commit Task 7**

```powershell
git add app/test/integration/agent_composition_flow_test.dart docs/read-only-agent-handoff.md docs/acceptance/read-only-agent.md AGENTS.md
git commit -m "test(agent): close read-write hardening milestone"
```

If `docs/agent-testing.md` remained untracked, do not include it in this commit.

- [ ] **Step 8: Review commit scope and stop before merge**

```powershell
git log --oneline a126c90..HEAD
git diff --stat a126c90..HEAD
git status --short --branch
```

Expected: seven implementation commits, no unrelated staged changes, and branch remains `feature/write-tools`. Do not merge to `main`; hand control back to the user for code review and manual acceptance.
