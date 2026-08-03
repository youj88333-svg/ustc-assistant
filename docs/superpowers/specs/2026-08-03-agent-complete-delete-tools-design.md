# Agent 完整删除与生命周期工具设计

> 日期：2026-08-03
>
> 状态：主人已逐项确认，待整体审核
>
> 范围：一次性补齐 Agent 对全部本地业务对象的取消、软删除、恢复、配置清除和一步撤回能力；不删除学校来源事实，不执行外部平台写操作，不提供无界批量删除。

## 1. 背景

当前 Agent 写能力已经覆盖个人日程创建/修改、Task 创建与规划、个人标注、出勤/听讲、关系、Reminder、教务整日移动和权限策略，但删除能力不完整：

- 只有 `update_event(delete:true)` 可以软删除单个个人日程，取消与删除共用模糊的 `update_event` 权限项；
- AgentWriteGateway 已有 `softDeleteTask`，但模型没有 `update_task`；
- PlanBlock 服务支持取消和软删除，但 Agent 没有相应工具；
- 显式关系、Reminder、Overlay、TaskEventLink 和自定义权限策略没有清除工具；
- 已删除对象通常被现有只读查询过滤，模型无法取得恢复所需 ref；
- Agent 不能调用现有一步撤回；普通 `restore` 又不会恢复 Reminder 等附属快照；
- 取消个人日程不会进入周课表，但当前管理页也不显示它，缺少重新打开入口；
- 重复日程的取消/删除尚未完整覆盖 `only_this`、`this_and_future`、`whole_series`。

本设计一次性补齐上述闭环。实施 Plan 必须等待
`docs/superpowers/plans/2026-08-03-agent-create-task-burst-budget.md` 完成并稳定后再编写，避免并行修改 Agent Grounding、Prompt、Session 与测试造成冲突。

## 2. 目标

1. 覆盖 Agent 当前能够创建或修改的全部本地业务对象。
2. 严格区分“取消”和“删除”。
3. 业务实体软删除；附加配置安全移除或清空，并可一步撤回。
4. 所有写操作先通过本轮只读查询取得短期 ref，不接受模型猜测数据库身份。
5. 重复日程支持单次、本次及未来、整个系列三种明确范围。
6. 删除与恢复不破坏历史、来源事实、用户覆盖边界和账号隔离。
7. 每个动作具有独立的风险、确认策略、ActionLog 和确定性终态。
8. 删除后的对象可以通过管理态查询、最小 UI 和恢复工具重新找回。
9. 多对象请求逐项执行并准确汇总，不新增批量删除工具。
10. 不根据默认学期、年份或 `semesterId` 推导任何删除目标。

## 3. 非目标

- 不物理删除个人日程、Task、PlanBlock 或重复系列历史。
- 不删除课程、考试、已报名二课、SourceRecord、CourseSeries 或其他学校来源事实。
- 不自动报名或取消二课，不向学校平台提交任何写操作。
- 不允许 Agent 删除账号、凭据、聊天、摘要、ActionLog、同步记录、浏览器 Profile、缓存或数据库。
- 不新增 `delete_many`、`delete_all`、万能 `delete_local_item` 或无界遍历。
- 不把删除工具加入 `create_task` Burst Lease，也不在本轮设计新的删除 Burst。
- 不改变 SourceBundle、Python Bridge、移动端来源契约或默认学期配置。
- 不自动恢复被删除/取消时停用的 Reminder；完整回滚使用一步 Undo。
- 不把运行时 ref、数据库 ID、学校账号或原始异常写入聊天和日志。

## 4. 核心术语

### 4.1 取消

取消表示对象仍存在，但进入 `cancelled` 生命周期状态：

- 周课表和普通活动列表不显示；
- 历史和管理筛选可以查看；
- 可以显式重新打开；
- 不设置 `deletedAt`；
- 已取消对象保留标题、时间、关联和审计历史。

“这件事不做了”“取消这次安排”映射为取消，不映射为删除。

### 4.2 删除

删除表示业务实体设置 `deletedAt`：

- 从普通查询、周课表和常规详情入口隐藏；
- 在管理视图可查询和恢复；
- 关联历史保留但停止参与派生行为；
- 不物理删除实体行。

“删掉”“移入已删除”“从本地移除”才映射为删除。

### 4.3 附加配置清除

以下记录不是独立业务实体，缺失即表示恢复默认：

- Reminder 配置；
- UserOverlay 字段；
- TaskEventLink；
- ScheduleRelation / ScheduleRelationRule；
- AgentPermissionPolicy 自定义行。

它们可以在事务内物理移除或清空字段，但必须同时写 ActionLog 和 Undo 快照。已投递 Reminder 等历史记录按本设计保留。

## 5. 能力总表

| 对象 | 工具 | 动作 | 持久化 |
|---|---|---|---|
| 个人日程 | `update_event` | edit/complete/skip/cancel/reopen/delete/restore | 状态或软删除 |
| 重复个人日程 | `update_event` | 上述动作 + 三种 scope | 系列/例外/软删除 |
| Task | `update_task` | complete/cancel/reopen/delete/restore | 状态或软删除 |
| PlanBlock | `update_plan_block` | done/skip/cancel/delete/restore | 状态或软删除 |
| 显式日程关系 | `delete_schedule_relation` | 删除单次关系或系列规则 | 物理移除配置 |
| Reminder | `clear_reminder` | 清除指定偏移或全部未来提醒 | 移除配置 + 禁用标记 |
| UserOverlay | `clear_user_overlay` | 清除字段/字段组/全部 | 置空或移除行 |
| TaskEventLink | `unlink_task_event` | 解除一对关联 | 物理移除配置 |
| 权限策略 | `reset_permission_policy` | 恢复动作默认策略 | 物理移除覆盖行 |
| 一步撤回 | `undo_last_action` | 撤回最新可撤回操作 | 复用 UndoSlot |
| 教务整日移动 | 现有 `move_jw_course_day` | `action=clear` | 清除本地移动记录 |

## 6. 只读前置工具

### 6.1 `get_schedule(view=management)`

在现有 `events/course_summary` 之外增加 `management`：

```text
输入：
  view = management
  query?                  标题关键词
  from?/through?          北京日期，最长 31 天
  lifecycle_states?       cancelled/hidden/deleted/completed/skipped

约束：
  query 非空，或 from/through 构成不超过 31 天的范围；两者至少一个成立
  只返回 source=user 的个人日程/重复 occurrence
  默认不进入普通 get_schedule 结果
```

返回安全标题、时间、生命周期状态、重复身份提示、可用 scope 和 `ref_event`。不得返回 series ID、occurrence key 或数据库 ID。

### 6.2 `get_tasks`

增加：

```text
query?                    标题关键词
state = active|blocked|completed|cancelled|deleted
```

未指定 `state=deleted` 时继续排除已删除 Task。`state=deleted` 返回可恢复 Task 并绑定 `ref_task`。查询仍受现有数量上限保护。

### 6.3 `get_plan_blocks`

增加状态筛选与 `include_deleted`。查询已删除 PlanBlock 时必须提供 `taskRef`；禁止无界返回整个账号的已删除执行块。返回 `ref_plan_block`，沿用内部 ref kind `planblock`。

### 6.4 `get_schedule_relations`

新增只读工具：

```text
输入：
  ref_left               必填，event 或 planblock ref
  ref_right?             可选，限定另一参与方
```

只返回 `source=user` 的显式 `ScheduleRelation` 和匹配的 `ScheduleRelationRule`。每项包含：

- `ref_relation`；
- `scope=occurrence|current_and_future`；
- 两侧安全标题与时间/系列说明；
- `conflictState` 与低敏感 reason；
- 有效日期范围；
- 删除后预计回退为系列规则、派生 overlap 或 unclassified 的结果。

派生 overlap 没有关系 ref，不能删除。

### 6.5 `get_reminders`

必须提供一个 event、Task 或 PlanBlock ref。返回该目标的：

- 当前未来 `desired` 偏移；
- 是否存在明确禁用标记；
- delivered/missed/failed 历史计数；
- 不返回 Reminder 数据库 ID。

### 6.6 `get_user_overlay`

必须提供 `ref_event`。分别返回：

- `single_event` 层显式设置的字段；
- `course_series` 层显式设置的字段；
- 清除任一层后会生效的安全预览值。

不能只返回 EffectiveEvent 合并值，否则模型无法判断字段属于哪一层。

### 6.7 `get_task_details`

在现有 PlanBlock 详情之外增加：

```text
linkedEvents: [{ref, title, source, eventType, startAt/startDate}]
```

只返回仍存在且属于当前账号的关联事件。

### 6.8 `get_last_undoable_action`

新增只读工具，无参数。返回：

- 是否存在可撤回操作；
- 安全中文摘要；
- 动作类型；
- 北京时间；
- 不返回 Undo payload、实体 ID 或 ref。

## 7. 写工具 Schema

### 7.1 `update_event`

```text
ref_event   required
action      edit|complete|skip|cancel|reopen|delete|restore
scope       only_this|this_and_future|whole_series

仅 action=edit 可用：
title/start_at/end_at/all_day/start_date/end_date_exclusive/location/
type/importance/description/tags
```

规则：

- 非重复事件不接受 `this_and_future/whole_series`；
- 重复事件执行 cancel/delete/restore 时 `scope` 必填；
- 生命周期动作与字段编辑互斥；
- `source!=user` 返回 `source_event_not_editable`；
- 现有 `delete:true` 和 `status=...` 保留一个兼容周期的内部解析，但从公开 Schema 和 Prompt 移除；旧参数与 `action` 混用返回 `invalid_write_arguments`。

### 7.2 `update_task`

```text
ref_task    required
action      complete|cancel|reopen|delete|restore
```

本轮不把标题/描述编辑混入该 Schema。完成 Task 是否取消未来 accepted PlanBlock 沿用现有确认流程；取消 Task 固定取消未来 accepted PlanBlock。

### 7.3 `update_plan_block`

```text
ref_plan_block  required
action          done|skip|cancel|delete|restore
note?           仅 done/skip 可用
```

删除或取消 PlanBlock 不删除父 Task，也不级联删除 reschedule replacement。

### 7.4 `delete_schedule_relation`

```text
ref_relation required
```

只接受 `get_schedule_relations` 当前 run 产生的关系 ref。不得用两侧标题或事件 ref 直接猜测关系行。

### 7.5 `clear_reminder`

```text
ref_target       required，event/task/planblock
scope            selected_offsets|all
offsets_minutes  selected_offsets 时必填，非空、非负、去重
```

`all` 不接受 offsets；`selected_offsets` 中任一偏移不存在则整项不写。

### 7.6 `clear_user_overlay`

```text
ref_event  required
scope      single_event|course_series
fields     non-empty array
```

字段枚举：

```text
display_title display_location
attendance_policy attendance_note attendance_decision attendance_outcome
listening_mode listening_note
importance color foreground_priority hidden user_notes tags
attendance listening display appearance all
```

字段组展开：

- `attendance`：四个 attendance 字段；
- `listening`：mode + note；
- `display`：title + location；
- `appearance`：importance + color + foreground priority；
- `all`：该层全部字段。

`attendance_decision` 清除时同时清除 `attendanceDecisionAt`。

### 7.7 `unlink_task_event`

```text
ref_task   required
ref_event  required
```

只解除唯一 `(account, task, event)` 的 `related` 关联。

### 7.8 `reset_permission_policy`

```text
target_action_type required，必须来自正式注册且允许用户配置的 action
```

工具不接受任意 `target_type/risk/mode`，这些均由注册表确定。

### 7.9 `undo_last_action`

无参数。必须在当前 run 先成功调用 `get_last_undoable_action`。UndoSlot 在成功后清空。

## 8. 重复个人日程

### 8.1 范围

```text
only_this       只处理当前 occurrence
this_and_future 当前 occurrence 及以后，保留之前历史
whole_series    整个系列
```

模型不得为重复日程默认 scope。确认卡必须显示：

- scope 中文含义；
- 当前 occurrence；
- 未来 366 天预计影响数量；
- 系列是否超出 366 天或无限延续；
- 受影响 Reminder、例外和关系数量。

### 8.2 `only_this`

- 取消：使用 occurrence exception `kind=cancelled`，保留原 override payload；
- 重新打开：恢复原 override，若原来没有覆盖则恢复为空覆盖；
- 删除：在 occurrence exception 上设置 `deletedAt`；无原例外时建立空 override tombstone；
- 恢复：清除该 exception 的 `deletedAt`，恢复其原 override/状态。

### 8.3 `this_and_future`

复用系列分段语义：

1. 旧系列截断在目标 occurrence 之前；
2. 从目标 occurrence 建立新系列段；
3. 兼容的未来例外、Reminder 和关系规则在事务内迁移到新系列段；
4. cancel 将新系列段状态设为 cancelled；
5. delete 将新系列段设置 `deletedAt`；
6. reopen/restore 只处理该系列段，不影响旧系列历史。

新系列段本身就是持久化 tombstone，因此 UndoSlot 被后续操作覆盖后仍能显式恢复。

### 8.4 `whole_series`

- cancel/reopen 修改系列状态；
- delete/restore 设置或清除系列 `deletedAt`；
- 不逐条物化 occurrence；
- 历史 exception 保留；
- 任何 whole-series 操作至少为 high + always_ask。

## 9. Task 级联

### 9.1 取消

沿用现有语义：

- Task 进入 cancelled；
- 未来 accepted PlanBlock 进入 cancelled；
- Task 重新打开时不自动恢复这些 PlanBlock；
- 待触发 Reminder 被取消。

### 9.2 删除

采用“父项抑制、子项保留”：

- 只设置 Task `deletedAt`；
- PlanBlock、TaskEventLink、ScheduleRelation 保留原状态；
- 由于父 Task 已删除，它们不进入周课表、冲突投影和普通详情；
- 待触发 Reminder 取消；
- 确认卡显示未来 PlanBlock、Reminder、关联事件和关系数量。

### 9.3 恢复

- 清除 Task `deletedAt`；
- 原 PlanBlock、关联和关系重新可见，状态保持原值；
- Reminder 不自动恢复；
- 一步 Undo 才恢复删除事务前的完整 Reminder 快照。

## 10. PlanBlock 级联

- cancel：改为 cancelled，保留 Task 历史，不进入周课表；
- delete：设置 `deletedAt`；
- restore：清除 `deletedAt`，恢复删除前状态；原状态为 accepted 时重新进入周课表；
- 删除/取消时取消待触发 Reminder；
- 关系与 reschedule 链保留，在对象不可见期间不生效；
- 不删除父 Task，不删除 replacement PlanBlock；
- 恢复不自动重启 Reminder，Undo 可恢复完整快照。

## 11. 关系删除

- 只能删除 `source=user`、`relationType=conflict` 的显式关系；
- 不允许删除导入的 `exam_for_course` 等来源关系；
- 单次关系物理移除后，投影重新按“单次关系 > 系列规则 > 派生 overlap”计算；
- 系列规则物理移除后，影响有效日期范围内的当前和未来 occurrence；
- 确认卡必须显示删除后的预计有效状态；
- 系列规则始终 high + always_ask，并显示未来 366 天影响；
- ActionLog 与 Undo snapshot 和业务删除处于同一事务。

## 12. Reminder 清除

- `selected_offsets` 只移除指定未来偏移，其余保留；
- `all` 清除目标全部 future desired Reminder；
- 当目标没有剩余偏移时写入无 offset 的 cancelled sentinel，防止 reconcile 用默认规则重建；
- delivered/missed/failed 历史保留；
- 删除/取消实体只取消其 desired Reminder，不删除历史；
- restore/reopen 不自动恢复 Reminder；
- Undo 恢复清除前完整 Reminder 配置。

现有 `ReminderOverrideService` 必须泛化为 event/task/plan_block target，不能在 Agent Gateway 中直接触表。

## 13. Overlay 清除

OverlayService 需要新增显式三态清除 API；当前 `null=未提供` 的 `OverlayMutation` 不能表示“把字段设回 null”。实现必须区分：

```text
absent  不修改
set     设置值
clear   清空为 null
```

规则：

- 只清除用户明确指定字段；
- 清除 occurrence 层后，系列层可能重新生效；
- 清除 series 层后，来源默认值重新生效；
- 确认卡展示清除后的有效值，而不只说“字段已删除”；
- 所有字段均空后物理删除 Overlay 行；
- 任一字段名无效、scope 不可用或目标变化时整项不写；
- 一次工具调用的全部字段原子完成。

## 14. TaskEventLink

- `get_task_details` 提供关联事件 refs；
- `unlink_task_event` 使用 `(ref_task, ref_event)`，不新增 link ref；
- Task 和 event 必须同账号、未删除且关联存在；
- 学校来源 event 可以解除本地关联；
- 不修改 Task、事件、PlanBlock、Reminder 或 ScheduleRelation；
- 关联行物理移除，写 ActionLog 和 Undo 快照。

## 15. 权限重置

- 删除指定 `(account, actionType, targetType)` 自定义策略行；
- 默认策略惰性重新生效；
- `firstConfirmedAt/lastConfirmedAt` 随覆盖行移除；
- 默认 ask_first_time 的动作会在下一次重新询问；
- 当前没有覆盖行时返回 `already_default`，不生成确认卡、ActionLog 或 Undo；
- 工具自身 critical + always_ask、`rememberAllowed=false`，不能重置自身保护。

## 16. 一步撤回

- `get_last_undoable_action` 只读 UndoSlot 安全预览；
- `undo_last_action` 必须消费同一 run 的预览证据；
- 成功后 UndoSlot 清空；
- 不支持连续撤回更早操作；
- 用户说“撤回刚才的删除”优先使用 Undo；
- 用户指定某个更早已删除对象时使用管理态查询 + restore；
- Undo 复用现有 UndoService，不能在 Agent 工具中重新实现各实体回滚；
- Undo medium + ask_first_time，确认卡显示安全摘要。

## 17. 动态风险与权限

### 17.1 Proposal 是审批权威

现有 `AgentWriteTool.execute` 使用工具静态 getter 的 action/risk/target 查询权限，无法支持同一 `update_*` 工具的不同生命周期动作。本轮改为：

1. `propose` 先完成无副作用校验并返回具体 `AgentWriteProposal`；
2. Runtime 使用 `proposal.actionType`、`proposal.riskLevel`、`proposal.targetType` 决议权限；
3. 每个工具维护允许产生的 action allowlist，禁止子类/输入注入任意策略键；
4. 确认卡、ActionLog 和权限记录均使用同一 proposal 字段。

### 17.2 风险矩阵

| 动作 | 默认策略 |
|---|---|
| 单项 complete/skip/reopen/restore | medium + ask_first_time |
| 单项 cancel | high + always_ask |
| 任意实体 delete | high + always_ask |
| this_and_future / whole_series | 至少 high + always_ask |
| 删除关系 / unlink | high + always_ask |
| 清除部分 Reminder / 单节 Overlay 字段 | medium + ask_first_time |
| 清除全部 Reminder / 全部 Overlay / 课程系列 Overlay | high + always_ask |
| undo_last_action | medium + ask_first_time |
| reset_permission_policy | critical + always_ask |

删除与大范围操作的确认卡不显示“此类型以后不再确认”。用户仍可在设置页显式调整非 critical 动作；critical 永远不能自动允许。

### 17.3 动作键

权限与日志按具体动作区分，例如：

```text
event_cancel event_delete event_restore
task_cancel task_delete task_restore task_complete
plan_block_cancel plan_block_delete plan_block_restore
delete_schedule_relation delete_schedule_relation_rule
clear_reminder_offsets clear_all_reminders
clear_event_overlay_fields clear_all_event_overlay clear_course_overlay
unlink_task_event reset_permission_policy undo_last_action
```

旧 `update_event` 策略覆盖最多只作为 `event_edit` 的一版兼容 fallback，绝不能自动扩展到 cancel/delete/restore。新设置保存使用新动作键。

## 18. Agent Grounding 与 Prompt

### 18.1 自由聊天

以下不强制工具：

- “怎么删除 Task？”
- “删除后还能恢复吗？”
- “你能不能取消日程？”
- 对产品能力、风险和取消/删除区别的讨论。

### 18.2 明确操作

明确删除、取消、恢复、清除、解除关联或撤回时，Grounding 只开放相关工具族：

```text
个人日程：get_schedule + get_event_details + update_event
Task：get_tasks + get_task_details + update_task
PlanBlock：get_tasks/get_plan_blocks + update_plan_block
关系：参与方查询 + get_schedule_relations + delete_schedule_relation
Reminder：目标查询 + get_reminders + clear_reminder
Overlay：get_schedule/get_user_overlay + clear_user_overlay
TaskEventLink：get_tasks/get_task_details + unlink_task_event
权限：权限只读状态 + reset_permission_policy
Undo：get_last_undoable_action + undo_last_action
```

目标不唯一、重复范围不明确、Overlay scope 不明确时必须询问。首次没有调用所需工具时，沿用 Runtime 单次强制纠正；自由聊天不受影响。

### 18.3 成功权威

- 只有终端写工具 success 才能声称完成；
- lookup success 不代表删除完成；
- 用户拒绝、stale target 或技术错误使用结构化结果覆盖模型文案；
- 不允许自动重试同一删除；
- 多对象请求逐项执行，最后报告成功、拒绝、失败和未处理数量。

## 19. 多对象请求与额度

- 每次写工具调用只处理一个目标；
- 不新增数组 refs 或批量事务；
- Agent 先列出候选，再逐项调用；
- 每项独立确认、事务和 ActionLog；部分成功不回滚；
- 一步 Undo 只恢复最近一次成功操作，确认卡提示该限制；
- 超过普通工具额度时先向用户说明拆分范围，由用户发起下一批；
- 不复用 `create_task` Burst Lease；
- “删除全部/清空所有”直接拒绝，要求限定目标。

## 20. TOCTOU 与确定性错误

提案保存目标版本和安全快照；确认后在事务内重新读取并比较。关系、Reminder、Overlay 和 Link 同样需要版本/内容快照，不能只检查存在性。

标准错误码：

```text
scope_required
target_not_found
stale_target
source_event_not_editable
already_cancelled
already_deleted
already_active
invalid_lifecycle_transition
relation_not_found
reminder_not_found
overlay_field_not_set
link_not_found
already_default
no_undo_available
invalid_write_arguments
permission_denied
user_declined
cancelled
```

规则：

- 重复删除不冒充成功，不写 ActionLog/Undo；
- 清除一组字段时任一字段无效则整项不写；
- 未知异常由 registry 映射为安全通用错误，不返回原始异常文本；
- 错误消息不含数据库 ID、账号、ref、Cookie、Token 或内部路径。

## 21. 来源事件边界

- 课程、考试、二课等 `source!=user` 不能 cancel/delete/restore；
- 用户说“删除课程/考试/二课”时先说明来源事实不可删除，不自动等价为隐藏；
- 用户明确选择“仅本地隐藏”后才设置 Overlay `hidden=true`；
- 课程隐藏必须确认 `single_event/course_series`；
- 恢复显示使用 `clear_user_overlay(fields=['hidden'])`；
- 取消二课报名只能由用户在官方平台操作，本地隐藏不代表取消报名；
- 同步 presence 和来源缺失只能由同步链路修改。

## 22. 最小 UI 完整性

不新建统一回收站，扩展现有页面：

- 个人日程管理页增加“已取消 / 已隐藏 / 已删除”筛选；
- 已取消日程支持 reopen，已删除日程支持 restore；
- Task 中心继续展示已删除 Task 并支持恢复；
- Task 详情增加“已删除 PlanBlock”折叠区并支持恢复；
- 关系、Reminder、Overlay、TaskEventLink 删除后从原详情页消失，通过一步 Undo 恢复；
- 权限页标明自定义/默认状态并提供恢复默认；
- Agent 成功后提供合适的“查看日程/查看任务”导航 chip；
- 工具调用过程继续默认折叠；
- UI 不显示 ref 或数据库 ID。

## 23. 数据模型与迁移

预计不新增表或列：

- CalendarEvent、Task、PlanBlock、CalendarEventSeries、OccurrenceException 已有 `deletedAt`；
- 配置对象按已确认规则物理移除/置空；
- this-and-future 使用现有系列分段；
- UndoSlot 和 ActionLog 已存在。

如果实施时发现显式恢复 this-and-future 无法由现有系列段稳定表示，必须先回到 Spec 审核，不能临时增加 schema 或把恢复降级为仅 Undo。

需要新增/扩展 Application Service API，但 Agent Gateway 不得直接操作 Drift 表：

- Recurrence lifecycle service；
- Task/PlanBlock restore and impact preview；
- Conflict relation lookup/delete；
- generalized ReminderOverrideService；
- tri-state Overlay clear；
- TaskEventLink service；
- Permission policy reset；
- Undo preview。

## 24. 事务、日志与撤回

每次成功写入必须在一个事务中完成：

```text
TOCTOU recheck
-> business mutation
-> source=agent ActionLog success
-> UndoSlot snapshot
-> permitted policy post-confirmation update
-> commit
```

任一步失败全部回滚。用户拒绝/取消继续记录安全结果，但不写业务 Undo。ActionLog 摘要可以包含用户可见标题和时间，不包含内部身份。

## 25. 自动测试

### 25.1 领域服务

- Event/Task/PlanBlock cancel/delete/restore 状态机；
- 重复事件三个 scope，包含已有 override、无 override、无限系列和 this-and-future；
- Task 删除保留子项但抑制投影；
- PlanBlock 删除不级联父 Task/replacement；
- Reminder sentinel 防止 reconcile 重建；
- Overlay 单字段/字段组/all 清除与系列 fallback；
- relation/rule 删除后的投影优先序；
- unlink、policy reset、Undo preview/consume；
- 跨账号、stale version 和事务回滚。

### 25.2 Agent 工具

- 每个 Schema `additionalProperties:false`；
- ref 必须来自当前 run 且 kind 正确；
- legacy update_event 参数兼容和混用拒绝；
- 动态 proposal 风险/策略键；
- 确认卡预览不泄露 ID/ref；
- TOCTOU 在确认后拒绝；
- source event 删除拒绝；
- no-op 不写日志/Undo；
- 每个成功工具写一条业务 ActionLog；
- Grounding 自由聊天与明确操作边界；
- 模型虚假成功由 Runtime 覆盖。

### 25.3 UI 与组合测试

- 取消日程不进入周课表但进入管理筛选；
- 已删除日程/Task/PlanBlock 可恢复；
- 删除 Task 后子 PlanBlock 不进入周课表；
- 删除关系后 conflict warning 按 fallback 重新计算；
- 清除 hidden 后系列/来源默认正确生效；
- Undo 恢复完整 Reminder/配置快照；
- 账号切换不泄露对象、refs、Undo 或确认卡；
- 真实 registry + Drift 完成查询、确认、删除、查看、Undo 的组合流程。

## 26. 人工验收

Windows Release 使用真实学校模型逐项验证：

1. 取消个人日程：周课表消失、管理页可见、重新打开成功。
2. 删除并恢复单次个人日程。
3. 删除重复日程 only_this、this_and_future、whole_series，逐项检查影响范围。
4. 取消/删除/恢复 Task，检查 PlanBlock 与 Reminder 规则。
5. 删除/恢复 PlanBlock，检查父 Task 与 reschedule 链。
6. 删除单次关系与系列规则，检查 warning fallback。
7. 清除一个 Reminder 偏移、清除全部、运行 reconcile 后不重建。
8. 清除 event/course overlay 字段，检查继承值。
9. 解除 TaskEventLink。
10. 重置权限策略并确认下一次 ask_first_time 重新出现。
11. 撤回刚才删除，确认完整快照恢复且不能连续撤回第二步。
12. 请求删除课程/考试/二课，确认不会删除来源事实。
13. 请求“删除所有”，确认被拒绝并要求缩小范围。
14. 切换账号，确认查询、删除、Undo 全部隔离。

人工结果文档的每项末尾保留 `完成：`，自动测试不得代填。

## 27. 完成标准

1. 能力总表中的每项都有可运行工具、权限项、Prompt/Grounding、ActionLog、Undo 和测试。
2. 个人实体无物理删除；配置清除符合已确认例外。
3. 取消与删除在状态、UI、查询、恢复和提醒行为上严格区分。
4. 重复日程三个 scope 均可删除和恢复，影响预览准确。
5. 已删除对象可通过管理态查询取得 ref，不依赖历史 ref。
6. 所有写操作只接受当前账号、本轮绑定、类型匹配的 ref。
7. 任何来源事件、外部平台、账号或审计数据均不可由这些工具删除。
8. 多对象请求逐项、可部分成功、准确汇总，不越过普通工具额度。
9. 动态风险决议不会让旧 `update_event` 权限意外放宽删除。
10. 全量 Flutter 测试、analyze 和 Windows Release 构建通过；Python 套件无回归。
11. 真实模型人工验收结果被单独记录，不以自动测试替代。

## 28. 后续实施顺序约束

本文件只定义 Spec，不是实施 Plan。下一步必须：

1. 等待当前 create_task Burst Plan 全部完成并提交；
2. 将本 Spec 合并或 cherry-pick 到包含其最终实现的最新分支；
3. 重新审查 AgentGroundingRequirement、AgentSystemPrompt、AgentSessionService、AgentToolBudget 和最新测试接口；
4. 再使用 writing-plans 编写删除工具实施 Plan；
5. 删除工具实施不得与 Burst Agent 并行修改同一核心文件。
