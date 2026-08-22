# M4 详细实施计划：Agent 删除/生命周期工具回归固化

> 分支：`refactor/webview-minimal`（M3 已完成）
> 依据：`docs/plan-webview-minimal.md` §6（M4 目标）与 §3 里程碑表
> 目标（M4 门）：M1 已删外部工具并收敛系统提示/grounding/registry；M4 只增补
> `agent_delete_tools_test.dart` 回归固化本地删除/恢复/清项目/撤回与学校课程考试
> 拒绝删除，全部经 propose→approve 真实提交路径。`flutter analyze` 无 error、
> `flutter test` 除 7 项基线已知失败外全绿。

## 0. 范围与非范围

### 0.1 做

- 新增**一个**测试文件：`app/test/features/agent/agent_delete_tools_test.dart`。
- 覆盖 8 个生命周期/清除/撤回工具（`update_task`、`update_plan_block`、
  `delete_schedule_relation`、`clear_reminder`、`clear_user_overlay`、
  `unlink_task_event`、`reset_permission_policy`、`undo_last_action`）的关键契约，
  以及 `update_event` 对学校课程/考试事件的删除拒绝。
- 全部测试经 propose→approve 真实提交路径（fake gateway 记录调用 + `WriteConfirmationStore`
  批准），不绕过审批门。
- 聚焦回归固化：每个测试断言一条**已被代码锁定、容易在重构中丢失的契约**，
  不复现已有广泛覆盖的细节（如 write_tools_test 的 68 处引用与 composition_flow
  Task 12 的 13 场景）。

### 0.2 不做

- 不新增/修改任何 `lib/` 生产代码。M4 纯测试固化（生产逻辑已在写工具里程碑实现）。
- 不删除/重构已有测试（write_tools_test.dart、agent_composition_flow_test.dart 的
  Task 12 group 保持原样）。
- 不改 schema、不改系统提示词、不改 grounding policy、不改 registry（M1 已收敛）。
- 不动 Python 代码、不动 sync/采集器（M2/M3 产物）。
- 不做真实人工验收（本 VM 无外网；M6 在外部机器做）。

## 1. 关键 code-truth 事实（已核对代码，本计划据此设计断言）

### 1.1 8 个生命周期工具的契约矩阵

| 工具 | 动作 | 风险 | rememberAllowed | 关键契约 |
|---|---|---|---|---|
| `update_task` | complete/cancel/reopen/delete/restore | medium(high for cancel/delete) | 默认 true | 软删除(deletedAt)可恢复；restore 走 includeDeleted 查找；非 restore 动作对已删除行返回 target_not_found |
| `update_plan_block` | done/skip/cancel/delete/restore | medium(high for cancel/delete) | 默认 true | 删除不级联父任务；note 仅 done/skip 可用；restore 走 includeDeleted |
| `delete_schedule_relation` | delete | high | **false**(永远确认) | 单次关系物理删除；系列规则显示 366 天影响；学校来源 `relation_not_deletable` |
| `clear_reminder` | selected_offsets/all | medium(high for all) | 默认 true | **无 source guard**：对任何已解析目标操作；学校事件无 reminder 行→no-op |
| `clear_user_overlay` | clear fields | medium(high for course_series/all) | 默认 true | single_event 清单次层；course_series 解析 seriesId 后清系列层；无 series→target_not_found |
| `unlink_task_event` | unlink | high | **false** | 唯一(task,event)关联物理删除；TOCTOU 用 task+event 版本快照 |
| `reset_permission_policy` | reset | **critical** | **false**+forceConfirmation | 无覆盖→already_default；非可重置动作拒绝；自身不可重置 |
| `undo_last_action` | undo | medium | 默认 true | 一步消费槽；无槽→no_undo_available/invalid_write_arguments；二次 undo 失败 |

### 1.2 source guard 分布（最易在重构中错位）

- **`set_reminder`**：propose + commit **双检** `EventWriteSnapshot.isPersonal`（`source == 'user'`），
  非个人事件拒绝（`FormatException('only personal events can set reminders')`）。
  → 学校课程/考试事件**永远没有 reminder 行**（set_reminder 拒绝创建）。
- **`clear_reminder`**：**无** source guard。对学校事件 propose→approve 通过，
  但 commit 调 `clearReminders` 找不到 reminder 行→no-op（写 disabled sentinel 或不动）。
  → **个人-only 提醒由系统提示词约束，非工具代码**。M4 测试必须断言这个 no-op 语义，
  而非"clear 被拒绝"。
- **`update_event` delete**：学校课程/考试事件删除在 **propose 阶段即拒绝**
  （`UpdateEventTool.propose` 检 `EventWriteSnapshot.isPersonal`，非个人事件抛
  `FormatException('source event cannot be edited with update_event')`，基类 `execute`
  映射为 `invalid_write_arguments`）。commit 路径的 `source_event_not_editable`
  （`agent_write_tools.dart` commit 内 `!identity.isPersonal` 分支）仅在 propose→commit
  之间 source 翻转（TOCTOU）时可达，普通课程事件不会走到。→ 删除拒绝是
  code-enforced，M4 断言 propose 即 `errorCode == 'invalid_write_arguments'` 且事件行
  `deletedAt` 仍为 null（从不进审批门）。
- **`delete_schedule_relation`**：学校来源关系删除服务层抛
  `ConflictNotDeletableError` → `relation_not_deletable`（带 guidance）。

### 1.3 错误码映射（`mapLifecycleError` / `guardCommit`，agent_lifecycle_tools.dart:43-171）

> 下表列出 M4 测试直接断言的映射。`mapLifecycleError` 还含 recurring/foreign-link 路径
> （`AlreadyLifecycleDeleted`→`already_deleted`、`StaleRecurringTarget`→`stale_target`、
> `InvalidRecurringTransition`→`invalid_lifecycle_transition`、
> `TaskEventLinkTargetNotFoundError`→`target_not_found`），M4 不直接测这些但实现者应知晓全集。

| 领域异常 | 错误码 |
|---|---|
| TaskNotFound/PlanBlockNotFound | target_not_found |
| StaleTaskCommand/StalePlanBlockCommand | stale_target |
| AlreadyDeletedError | already_deleted |
| IllegalTaskTransition/IllegalPlanBlockTransition/InvalidLifecycleTransition | already_active / invalid_lifecycle_transition |
| NotDeletedError(restore 未删除块) | already_active |
| ConflictNotDeletableError | relation_not_deletable(+guidance) |
| ConflictRelationNotFoundError | relation_not_found |
| TaskEventLinkNotFoundError | link_not_found |
| StaleTaskEventLinkCommand/StaleReminderTargetCommand/StaleOverlayCommand | stale_target |
| InvalidUndoCommand | no_undo_available |

### 1.4 非可重置动作（`kNonResetableActions`，agent_permission_policy_service.dart:13）

```dart
const Set<String> kNonResetableActions = {
  'update_permission_policy',
  'reset_permission_policy',
  'move_jw_course_day',
};
```

## 2. 测试文件架构

### 2.1 文件与职责

```
app/test/features/agent/agent_delete_tools_test.dart   (新建)
  └─ 职责：8 工具 + update_event 学校拒绝 的回归固化；fake gateway + propose→approve 路径
```

### 2.2 harness 复用模式

**镜像 `write_tools_test.dart` 的 harness**（不发明新 harness）：
- `_Harness`：持有 `List<AgentWriteTool> tools` + `RunReferenceStore refs` + `ctx()` 构造 `AgentToolContext`。
- `tools()`：装配全部写工具（`CreateEventTool` 等 + `...agentLifecycleTools(gateway, policy, store, unitOfWork)`）。
- `_LifecycleGateway`：`implements AgentWriteGateway`，记录每个被调方法的参数/异常；`noSuchMethod` 抛 `UnimplementedError`。
- `store = WriteConfirmationStore(policy: policy, unitOfWork: unitOfWork)`；批准用
  `store.resolve(handle, approve: true, remember: false)`。
- setUp 播种 `localAccounts('a1')` + `AgentPermissionPolicyService` + `DriftAgentWriteUnitOfWork`。

**学校事件拒绝删除**用真实 Drift DB（与 composition_flow Task 12 scenario 11 同模式）：
`AppDatabase(NativeDatabase.memory())` + `_insertCourseSeries`/`_insertCourseOccurrence` 等价 seeding +
`writeRegistry(db, accountId)` 真实 registry。

### 2.3 fake gateway 设计要点

`_LifecycleGateway` 必须能驱动所有 8 工具的 propose→approve→commit。
**注意**：直接镜像 write_tools_test 的 `_LifecycleGateway` 会**缺失** `update_task`/
`update_plan_block` 的 commit 方法（原 fake 只覆盖了 propose 路径读取的
`taskById`/`planBlockById`，未覆盖 commit 调用的 `softDeleteTask`/`cancelTask`/
`reopenTask`/`restoreTask`/`completeTask` 及 plan_block 对应方法）。**必须显式新增以下覆盖**，
否则 commit 命中 `noSuchMethod`→`UnimplementedError`（`guardCommit` 不捕获→`write_commit_failed`）：

commit 路径必须覆盖的方法（记录调用参数 + 可注入异常）：
- **task**：`completeTask`、`cancelTask`、`reopenTask`、`softDeleteTask`、`restoreTask`
  （各设 `String? xxxTaskId` 记录字段 + `Object? xxxTaskThrows`）
- **plan_block**：`markPlanBlockDone`（带 note）、`markPlanBlockSkipped`（带 note）、
  `cancelPlanBlock`、`softDeletePlanBlock`、`restorePlanBlock`
- `eventSnapshot`（返回 `EventWriteSnapshot`，`source: 'user'` 让 set/clear 通过）
- `reminderConfiguration` + `clearReminders`（记录调用 + 可注入异常）
- `overlayRowSnapshot` + `clearOverlayFields`（单次层/系列层两参）+ `courseSeriesIdForEvent`
- `unlinkTaskEvent` + `taskById`/`eventSnapshot` 版本
- `resetPermissionPolicy`（返回 bool removed）
- `undoPreview` + `undoLastAction`（可注入 available/summary + 异常）
- `conflictRuleRemovalImpact`（系列规则影响天数）
- `deleteConflictRelation` / `deleteConflictRule`

propose 路径读取（镜像原 fake）：`taskById`/`taskByIdIncludeDeleted`（restore 走后者；
I4 软删除过滤）、`planBlockById`/`planBlockByIdIncludeDeleted`、`eventSnapshot`。

## 3. 测试用例清单（22 个 test）

> 每个用例断言**一条契约**，用 reason 说明为什么这条契约易在重构中丢失。
> 全部经 propose→approve 路径；学校事件拒绝删除用真实 DB。

### group A: update_task 生命周期（4）

1. **`update_task delete 软删除后 restore 复原；deletedAt 翻转`**
   - fake: `softDeleteTask` 设标记，`restoreTask` 清标记（模拟真实服务）
   - 断言：delete 后 task 标记软删除；restore 后清空；两条都 success
   - 契约：删除是软删除（可恢复），不是物理删除

2. **`update_task complete 映射到 completeTask 调用`**
   - 断言：approve 后 `completedTaskId == 't1'`；result payload `action == 'complete'`
   - 契约：5 动作各路由到正确 gateway 方法

3. **`update_task reject unknown action 返回 invalid_write_arguments`**
   - 断言：未 approve 即 error，`errorCode == 'invalid_write_arguments'`
   - 契约：`WriteArgumentReader.requiredEnum` 在 propose 即拒绝非法枚举

4. **`update_task cancel 风险为 high（审批门不跳过）`**
   - 断言：cancel 返回 needsUserAction（非直接 success）；approve 后 `cancelledTaskId`
   - 契约：cancel/delete 的高风险语义保留（rememberAllowed 默认 true 但仍需首确认）

### group B: update_plan_block 生命周期（3）

5. **`update_plan_block delete 不级联父任务`**
   - fake: `softDeletePlanBlock` 标记块；`taskById` 仍返回 active task
   - 断言：块标记软删除；gateway 未被调任何 task 删除方法
   - 契约：块删除不级联（独立软删除）

6. **`update_plan_block note 仅 done/skip 可用；cancel+note 拒绝且不产审批卡`**
   - 断言：`cancel` + `note` → error `invalid_write_arguments`；且 `result.userAction == null`
     （propose 拒绝，从不进入审批门——无 opaqueHandle 产生）
   - 契约：note 字段约束在 propose 即校验，拒绝时不产生可确认的副作用入口
     （现有 write_tools_test:2564 只断言 error 码；本测试额外锁定"无审批卡"）

7. **`update_plan_block restore 映射 already_active（对未删除块）`**
   - fake: `restorePlanBlock` 抛 `NotDeletedError`
   - 断言：approve 后 commit result `errorCode == 'already_active'`
   - 契约：restore 未删除块的确定性错误码（不外泄内部文本）

### group C: delete_schedule_relation（2）

8. **`delete_schedule_relation 单次关系物理删除（success）`**
   - fake: `deleteConflictRelation` 记录 id
   - 断言：approve 后 `deletedRelationId == 'rel-1'`；payload `result == 'deleted_schedule_relation'`
   - 契约：单次关系是物理删除（非软删除）

9. **`delete_schedule_relation 学校来源关系映射 relation_not_deletable + guidance`**
   - fake: `deleteConflictRelation` 抛 `ConflictNotDeletableError`
   - 断言：approve 后 commit result `errorCode == 'relation_not_deletable'`；
     `payload['guidance']` 非空（含中文说明）
   - 契约：学校来源关系不可删除 + 带用户可读 guidance

### group D: clear_reminder no-op 语义（2）⭐ 关键 code-truth

10. **`clear_reminder 对学校课程事件是 no-op（无 source guard；无 reminder 行）`** ⭐
    - **真实 DB**（非 fake）：seed course series + occurrence（source='ustc_jw'）；
      真实 `DriftAgentWriteGateway`（不注入 fake——fake 只证明 fake 行为）
    - 断言：propose→approve **通过**（不拒绝）；result **success**；
      学校事件**无 desired-offset reminder 行**（set_reminder 的 source guard 保证学校事件
      永远不会被设提醒→无 reminder 行可清）。clear 可能写一个 disabled sentinel 行（这是
      ReminderOverrideService 的实现细节），但断言重点：**无活跃/期望偏移提醒被创建或清除**，
      学校事件的提醒状态保持为"无提醒"
    - **契约说明（必须在测试注释里写清）**：clear_reminder 无 source guard，对学校事件是合法但
      空操作。个人-only 提醒由**系统提示词**约束（set_reminder 有 source guard 拒绝学校事件→
      学校事件永远无 reminder 行→clear 无可清）。M4 测试固化的是**工具行为真相**，而非提示词约束。

11. **`clear_reminder selected_offsets 捕获 offset+版本快照（TOCTOU）`**
    - fake: `reminderConfiguration` 返回 `[15, 30]`；记录 `clearReminders` 参数
    - 断言：commitParams 含 `expectedTargetUpdatedAt` + `expectedOffsetsSnapshot`；
      透传到 `clearReminders`
    - 契约：I2 TOCTOU 快照在 propose 捕获、commit 重检（Spec §20）

### group E: clear_user_overlay（2）

12. **`clear_user_overlay course_series 无 series 映射 target_not_found + guidance`**
    - fake: `courseSeriesIdForEvent` 返回 null
    - 断言：approve 后 commit result `errorCode == 'target_not_found'`；payload['guidance'] 非空
    - 契约：course_series scope 在无 series 时的确定性拒绝

13. **`clear_user_overlay invalid field 直接抛 ArgumentError（无 registry 兜底）`**
    - 参数 `fields: ['bogus_field']`
    - 断言：`expect(() => tool.execute({'ref_event': ref, 'scope': 'single_event',
      'fields': ['bogus_field']}, h.ctx()), throwsA(isA<ArgumentError>()))`
      （`OverlayFieldKeys.expand` 抛 `ArgumentError`，基类 `execute` 只 catch
      `FormatException`/`CalendarValidationError`，`ArgumentError` 未捕获→**直接抛出**，
      因为 M4 harness 调 `tool.execute` 直连、不经 `AgentToolRegistry`，故无
      `tool_execution_failed` 兜底）
    - 契约：非法字段名在 propose 即失败，但因为是 `ArgumentError`（非 `FormatException`），
      直连 harness 下表现为抛异常而非返回 error 结果。M4 §0.2 禁止改 lib，固化的是**现状行为**
      （M4 的 22 个测试中此为唯一断言抛异常而非返回 error 的用例，因 harness 不经 registry）

### group F: unlink_task_event（2）

14. **`unlink_task_event 唯一关联物理删除 + 版本快照透传`**
    - fake: 记录 `unlinked` record
    - 断言：approve 后 `unlinked.taskId/eventId` 正确；`expectedTaskUpdatedAt`/`expectedEventUpdatedAt` 非空
    - 契约：物理删除 + I2 TOCTOU 版本快照

15. **`unlink_task_event StaleTaskEventLinkCommand 映射 stale_target`**
    - fake: `unlinkThrows = StaleTaskEventLinkCommand()`
    - 断言：approve 后 commit result `errorCode == 'stale_target'`
    - 契约：版本不匹配的确定性错误码

### group G: reset_permission_policy（3）

16. **`reset_permission_policy 无覆盖返回 already_default`**
    - fake: `resetPolicyRemoved = false`
    - 断言：critical+forceConfirmation→needsUserAction；approve 后 result success +
      `payload['result'] == 'already_default'`
    - 契约：幂等性——重置已默认策略是成功但无副作用

17. **`reset_permission_policy 非可重置动作（reset_permission_policy 自身）拒绝`**
    - 断言：`target_action_type: 'reset_permission_policy'` → error `invalid_write_arguments`，未 approve
    - 契约：`kNonResetableActions` 自我保护

18. **`reset_permission_policy unknown action 拒绝`**
    - 断言：`target_action_type: 'bogus'` → error `invalid_write_arguments`
    - 契约：动作键必须已注册

### group H: undo_last_action（2）

19. **`undo_last_action 一步消费槽（success 后 preview 翻转为 unavailable）`**
    - fake: `undoPreviewResult.available = true`；`undoLastAction` 设 `undoCalled` 且
      把 `undoPreviewResult.available` 翻为 `false`（模拟真实 UndoService 消费后清槽）
    - 断言：第一次 approve 后 success + `undoCalled == true`；再次 `execute` 时
      `undoPreviewResult.available == false` → error（无槽）
    - 契约：一步撤回消费语义——消费后槽清空，不可连续撤回更早操作

20. **`undo_last_action 无槽返回 invalid_write_arguments`**
    - fake: `undoPreviewResult.available = false`
    - 断言：error `invalid_write_arguments`（propose 阶段 `FormatException` 被映射）
    - 契约：无可撤回操作的确定性拒绝（propose 即拒，不进审批门）

### group I: update_event 学校事件拒绝删除（2，真实 DB）

> Group I 用**轻量真实 gateway 模式**（镜像 `drift_agent_write_gateway_test.dart`），
> 而非 composition_flow 的重量级 `writeRegistry`（后者需要 `_buildTestComposition`/
> `_seedAgentConfig`/secret-store 等 wiring，过度）。
> 轻量模式：`AppDatabase(NativeDatabase.memory())` + `DriftAgentWriteGateway(db, accountId)` +
> `AgentPermissionPolicyService` + `DriftAgentWriteUnitOfWork` + `WriteConfirmationStore` +
> 直接装配 `UpdateEventTool(gateway, policy, store, unitOfWork)` + `tool.execute`。
> 需先播种 `localAccounts` + 一条 `always_allow` 的 `agentPermissionPolicies` 行
> （让 approve 后直接 commit，不停在确认卡）。

21. **`update_event delete 对学校课程事件在 propose 即拒绝（invalid_write_arguments）；行不被删除`** ⭐
    - 真实 DB：seed course series + occurrence（source='ustc_jw', type='course',
      sourceSeriesExternalId + SourceRecords 行）；轻量真实 gateway + allow `event_delete`
    - 断言：`del.status == error`；`del.errorCode == 'invalid_write_arguments'`（propose 阶段
      `UpdateEventTool.propose` 检 `!snapshot.isPersonal` 抛 `FormatException`→基类映射）；
      事件行 `deletedAt == null` 且 `status == 'active'`（从未被碰，未进审批门）
    - 契约：学校课程事件删除是 code-enforced 拒绝（propose 即拒，非 commit/非服务层），
      错误码是 `invalid_write_arguments`（非 `source_event_not_editable`——后者仅在
      propose→commit source 翻转 TOCTOU 时可达）

22. **`update_event delete 对个人事件成功软删除（对照）`**
    - 真实 DB：seed personal event（source='user'）；轻量真实 gateway + allow `event_delete`
    - 断言：success（needsUserAction→approve→success）；事件行 `deletedAt != null`
    - 契约：个人事件可删除（与学校事件拒绝形成对照，证明拒绝是 source 特异）

## 4. 实现约束

### 4.1 fake gateway 必须 `implements AgentWriteGateway`（非 extends）

`AgentWriteGateway` 是 `abstract interface class`。`noSuchMethod` 抛 `UnimplementedError`
保证未覆盖方法立即失败（与 write_tools_test `_LifecycleGateway` 同模式）。

### 4.2 真实 DB 测试（group I 与 group D test 10）的 seeding

内联私有 seeding helper（**不跨文件 import** `composition_flow` 的 `_insertCourseSeries`/
`_insertCourseOccurrence`——它们是文件私有、不可 import；保持测试自包含）。course occurrence 必须：
- `source: 'ustc_jw'`, `type: 'course'`
- 关联 `sourceSeriesExternalId`
- 插入 `SourceRecords` 行（非 user 源事件出现在 effective projection 的前提）

轻量真实 gateway 装配（非 `writeRegistry`）：
```dart
final db = AppDatabase(NativeDatabase.memory());
final policy = AgentPermissionPolicyService(database: db, clock: _FixedClock());
final gateway = DriftAgentWriteGateway(database: db, accountId: 'acc-1', policy: policy);
final unitOfWork = DriftAgentWriteUnitOfWork(db);
final store = WriteConfirmationStore(policy: policy, unitOfWork: unitOfWork);
final tool = UpdateEventTool(gateway: gateway, policy: policy,
    confirmationStore: store, unitOfWork: unitOfWork);
// 播种 localAccounts('acc-1') + always_allow 策略行（event_delete）
```
group D test 10 同理用真实 `DriftAgentWriteGateway` + `ClearReminderTool` 装配。

### 4.3 批准路径

所有 fake-gateway 测试统一（注意 `attachGateway` 交换 fake——`tools()` 用共享 `gateway`
构造，测试时换入专属 `_LifecycleGateway`）：
```dart
final h = _Harness(tools());
final tool = h.tool('update_task') as UpdateTaskTool;
final gw = _LifecycleGateway();
tool.attachGateway(gw);   // ← 必须：换入测试专属 fake（gateway 字段非 final，设计如此）
final ref = h.refs.bind(kind: 'task', localId: 't1');
final result = await tool.execute({'ref_task': ref, 'action': 'complete'}, h.ctx());
expect(result.status, AgentToolStatus.needsUserAction); // 或 error（propose 拒绝）
await store.resolve(result.userAction!.opaqueHandle, approve: true, remember: false);
// 读 fake gateway 记录字段，或 await result.pendingInvocation!.result（commit 结果）
```
真实 DB 测试（group I / group D test 10）不用 `attachGateway`（直接用真实 gateway 构造 tool）。

### 4.4 不引入新依赖

只用现有 import：`drift`、`drift/native`、`flutter_test`、现有 agent/calendar/tasks/reminders/
schedule feature 包。不新增 package。

### 4.5 错误码断言

断言 `errorCode` 字符串字面量（如 `'stale_target'`、`'already_active'`），**不**断言
`errorMessage`（文本可能变；错误码是 Spec §20 契约）。

## 5. 验证步骤（M4 门）

```bash
cd app
/home/ubuntu/flutter/bin/flutter analyze         # 0 error（15 info/warning 基线不变）
/home/ubuntu/flutter/bin/flutter test test/features/agent/agent_delete_tools_test.dart  # 22 全绿
/home/ubuntu/flutter/bin/flutter test             # 全套：1336+22 pass，7 基线 fail 不变
```

## 6. 提交

```
test(webview-minimal): M4 — agent delete/lifecycle tools regression consolidation

Add agent_delete_tools_test.dart: 22 regression tests covering the 8 lifecycle
tools (update_task/update_plan_block/delete_schedule_relation/clear_reminder/
clear_user_overlay/unlink_task_event/reset_permission_policy/undo_last_action)
plus update_event school-event delete refusal. All via propose→approve real
commit path (fake gateway + WriteConfirmationStore; school-event refusal on
real Drift DB). Documents the clear_reminder no-op-on-school-event code-truth
(no source guard; personal-only reminders enforced by system prompt + set_reminder
guard, not by clear_reminder itself).
```

## 7. 与现有测试的关系（不重复原则）

| 已有覆盖 | M4 不复现，只固化契约 |
|---|---|
| write_tools_test Task 9 group（20+ 测试）| 细节性 propose/commit 形状；M4 只取每工具 1-3 条最易丢契约 |
| composition_flow Task 12（13 场景，真实 registry + session-service）| 端到端编排、预算、mutation ledger；M4 是工具级单测 |
| drift_agent_write_gateway_test（真实 gateway）| gateway 实现层；M4 是工具层 |
| 各 service 单测（task_lifecycle/plan_block/reminder_override/...）| 服务层；M4 是 agent 工具层 |

M4 的独立价值：**一份按工具组织的、断言契约而非实现细节的回归清单**，重构时一眼可见
哪些行为被锁定。

## 8. 风险与缓解

- **风险**：fake gateway 接口面大（AgentWriteGateway ~40 方法），漏覆盖方法触发 `noSuchMethod`。
  **缓解**：`noSuchMethod` 抛 UnimplementedError 是设计——未用到的方法不实现，用到的方法
  必须显式覆盖（与 write_tools_test 同模式）。
- **风险**：真实 DB 测试的 seeding helper 与 composition_flow 重复。
  **缓解**：内联私有 helper（不跨文件 import），保持测试自包含；少量重复优于跨文件耦合。
- **风险**：clear_reminder no-op 断言依赖真实 reminder 行为。
  **缓解**：group D test 10 用真实 DB + 真实 `DriftAgentWriteGateway`（不注入 fake），
  断言学校事件无 desired-offset reminder 行（set_reminder 的 source guard 保证），
  而非"无任何行被碰"（clear 可能写 disabled sentinel，属实现细节）。
