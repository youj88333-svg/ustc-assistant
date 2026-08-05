# Agent 完整删除与生命周期工具实施计划

> **执行者要求：** 优先使用 `superpowers:subagent-driven-development` 按 Task 执行；若改为单 Agent，则使用 `superpowers:executing-plans`。每个行为改动先使用 `superpowers:test-driven-development`，最终声明完成前使用 `superpowers:verification-before-completion`。

**目标：** 按已确认 Spec 一次性补齐 Agent 对个人日程、重复个人日程、Task、PlanBlock、显式日程关系、Reminder、UserOverlay、TaskEventLink 和自定义权限策略的取消、删除、恢复、清除、解除关联与一步撤回能力，同时保持学校来源事实只读、账号隔离和确定性终态。

**架构：** 继续使用“本轮只读查询绑定短期 ref -> 写工具无副作用 propose -> 动态风险审批 -> Application Service 事务提交 -> Agent ActionLog + UndoSlot”的现有结构。删除工具不直接操作 Drift 表，不引入批量删除工具，也不借用 `create_task` Burst Lease。已有 SourceBundle、Python Bridge 和五条数据来源链路不变。

**技术栈：** Flutter/Dart、Drift/SQLite、Anthropic 兼容 SSE tool-use、现有 Agent registry/grounding/runtime、`flutter_test`。

## 全局约束

- 设计权威为 `docs/superpowers/specs/2026-08-03-agent-complete-delete-tools-design.md`；本计划不得重新解释已经确认的产品决定。
- 当前实现基线必须包含 `01b4a70 test(agent): close create task burst workflow` 与之后的主人验收文档提交；开始前重新核对 `main`，不要以本计划编写时的哈希覆盖更新代码。
- 个人 `CalendarEvent`、`Task`、`PlanBlock`、重复系列和 occurrence 只软删除；学校课程、考试、二课、SourceRecord、账号、凭据、聊天、ActionLog、同步记录和缓存不可由这些工具删除。
- 二课报名与取消报名始终由用户在学校官方页面完成。本地 `hidden` 不代表取消报名。
- 配置型记录（Reminder 配置、Overlay 字段、TaskEventLink、用户冲突关系/规则、自定义权限覆盖）可以物理清除，但必须在同一事务写安全 Agent ActionLog 和完整 Undo 快照。
- 每个写工具调用只处理一个目标；禁止 `delete_many`、`delete_all`、数组 refs、万能删除工具、无界扫描或批量事务。
- 多对象请求按项调用，允许部分成功；普通工具额度仍为每 run 12 次。超过额度时要求用户拆分，不增加删除 Burst，也不复用 `create_task` Burst Lease。
- `create_task` Burst 的 32 次一次性 Lease、普通 12 次额度、模型 8 次调用、重复 fingerprint 和确定性聚合必须保持原行为。
- 所有写目标必须来自当前 run、当前账号、类型匹配的 `ref_*`；确认后在事务内重读版本/内容，拒绝 stale target。
- 时间统一使用 `Asia/Shanghai`。不得硬编码 `semesterId=421/461`、`2026spring/2026fall` 或根据年份推导默认学期。
- 不修改 Python、Bridge、SourceBundle、移动端来源适配器或学校接口。
- 预计无需 Drift schema 迁移。若实现 `this_and_future` 的显式恢复无法用现有系列分段稳定表达，必须停止 Task 6 并返回主人审核，不能临时增加表/列或把恢复降级成仅 Undo。
- 使用 TDD：每个行为先写失败测试并确认失败原因，再写最小生产实现；每个 Task 单独提交。
- 不改写主人填写的任何 `完成：` 内容。新人工验收文件的 `完成：` 必须保持空白。
- 只显式暂存当前 Task 文件，禁止 `git add .`，禁止回滚或暂存根工作树受保护改动。

## 文件职责图

```text
app/lib/features/agent/application/agent_write_tool.dart
  用 proposal 的动态 action/risk/target 决议权限，并校验每个工具的 proposal allowlist。

app/lib/features/agent/application/agent_write_tools.dart
  保留并改造 update_event；现有创建/标注工具同步到新权限注册表。

app/lib/features/agent/application/agent_lifecycle_tools.dart             [NEW]
  update_task、update_plan_block、关系/提醒/Overlay/Link/权限清除、Undo 写工具。

app/lib/features/agent/application/agent_management_tools.dart            [NEW]
  管理态和配置态只读工具；全部返回安全 DTO 与当前 run refs。

app/lib/features/agent/application/agent_local_data_gateway.dart
  账号内管理态读取接口；不得把 Drift 行或数据库 ID 暴露给工具层。

app/lib/features/agent/domain/agent_write_gateway.dart
app/lib/features/agent/data/drift_agent_write_gateway.dart
  领域快照、影响预览和 Application Service 委托；不得新增表级业务写。

app/lib/features/calendar/application/calendar_event_service.dart
app/lib/features/calendar/application/recurrence_service.dart
app/lib/features/calendar/application/recurrence_lifecycle_service.dart    [NEW]
  单次及重复个人日程生命周期、版本重检、366 天影响预览。

app/lib/features/tasks/application/task_lifecycle_service.dart
app/lib/features/tasks/application/plan_block_service.dart
app/lib/features/tasks/application/task_event_link_service.dart            [NEW]
  Task/PlanBlock 生命周期、父项抑制、Link 解除与恢复。

app/lib/features/reminders/application/reminder_override_service.dart
app/lib/features/reminders/application/reminder_service.dart
  event/task/plan_block 统一提醒清除、禁用 sentinel 与历史保留。

app/lib/features/schedule/application/overlay_service.dart
app/lib/features/schedule/application/conflict_service.dart
  Overlay 三态清除、显式关系/规则查询删除与 fallback 预览。

app/lib/features/tasks/application/undo_service.dart
app/lib/features/tasks/application/undo_recorder.dart
  账号安全预览、组合快照和一次性消费；兼容全部旧 v1 payload。

app/lib/features/agent/application/agent_grounding_policy.dart
app/lib/features/agent/application/agent_system_prompt.dart
app/lib/features/agent/application/agent_session_service.dart
app/lib/features/agent/application/agent_tool_budget.dart
  明确操作 grounding、Prompt v8、顺序多对象真实汇总和普通额度边界。

app/lib/features/calendar/presentation/personal_event_management_page.dart
app/lib/features/tasks/presentation/task_center_page.dart
app/lib/features/tasks/presentation/task_detail_loader.dart
app/lib/features/tasks/presentation/task_detail_page.dart
app/lib/features/agent/presentation/agent_permission_section.dart
  最小恢复入口；不新建统一回收站。
```

---

## Task 1：动态 Proposal 审批权威与权限注册表

**文件：**
- 修改：`app/lib/features/agent/application/agent_write_tool.dart`
- 修改：`app/lib/features/agent/domain/agent_write_proposal.dart`
- 修改：`app/lib/features/agent/application/agent_permission_policy_service.dart`
- 修改：`app/lib/features/agent/presentation/agent_permission_section.dart`
- 修改：`app/test/features/agent/agent_write_tool_test.dart`
- 修改：`app/test/features/agent/agent_permission_policy_service_test.dart`
- 修改：`app/test/features/agent/agent_permission_section_test.dart`

- [ ] **步骤 1：为动态审批写失败测试**

覆盖同一工具产生 `event_edit`、`event_cancel`、`event_delete`、`event_restore` 时分别使用 proposal 的 `actionType/riskLevel/targetType`，并验证旧的静态 `update_event` 策略不能放宽删除。伪造不在工具 allowlist 内的 proposal 必须在审批前以安全错误拒绝，不能触发策略查询或业务提交。

- [ ] **步骤 2：确认 RED**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_write_tool_test.dart test/features/agent/agent_permission_policy_service_test.dart
Pop-Location
```

- [ ] **步骤 3：让 proposal 成为唯一审批权威**

将 `AgentWriteTool.execute` 的策略决议改为读取 `proposal.actionType`、`proposal.riskLevel`、`proposal.targetType`。每个工具声明不可变的允许组合（action + target + 最大/精确 risk），同时验证 `proposal.toolName == tool.name`。工具级 `rememberAllowed/forceConfirmation` 只能进一步收紧 proposal，不能降低风险或放宽 critical。

- [ ] **步骤 4：集中定义权限动作目录**

在 `AgentPermissionPolicyService` 建立单一动作注册表，至少包含 Spec §17.3 的动作键、target、默认风险、默认模式、是否允许设置页放宽、中文标签。设置页、`update_permission_policy`、`reset_permission_policy` 和写工具 allowlist 均消费同一注册表，不再维护平行 enum/list。

- [ ] **步骤 5：保持已有工具行为并验证 GREEN**

现有 11 个写工具先注册为与当前行为等价的 proposal 组合；`move_jw_course_day` 和权限工具继续 critical + always_ask + 不允许记住。运行步骤 2 命令及：

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_permission_section_test.dart test/features/agent/write_tools_test.dart
Pop-Location
git diff --check
```

- [ ] **步骤 6：提交 Task 1**

```powershell
git add <Task 1 精确文件>
git commit -m "refactor(agent): authorize writes from dynamic proposals"
```

## Task 2：实体管理态查询与可恢复 refs

**文件：**
- 修改：`app/lib/features/agent/application/agent_tools.dart`
- 修改：`app/lib/features/agent/application/agent_local_data_gateway.dart`
- 修改：`app/lib/features/calendar/application/calendar_event_service.dart`
- 修改：`app/lib/features/tasks/application/task_lifecycle_service.dart`
- 修改：`app/lib/features/tasks/application/plan_block_service.dart`
- 修改：`app/test/features/agent/local_agent_tools_test.dart`
- 修改：`app/test/features/calendar/calendar_event_service_test.dart`
- 修改：`app/test/features/tasks/task_lifecycle_test.dart`
- 修改：`app/test/features/tasks/plan_block_undo_test.dart`

- [ ] **步骤 1：写 `get_schedule(view=management)` 失败测试**

验证：只返回 `source=user`；必须有非空 query 或不超过 31 天的 from/through；状态只允许 cancelled/hidden/deleted/completed/skipped；普通 `events` 仍排除这些项；返回标题、时间、状态、重复提示、可用 scope 和 `ref_event`，不返回 series/occurrence/数据库 ID。

- [ ] **步骤 2：写 Task/PlanBlock 管理态失败测试**

`get_tasks` 增加 `query` 和 `state=deleted`；`get_plan_blocks` 增加 `status/include_deleted`，查询删除项时强制 `taskRef`；`get_task_details.linkedEvents` 返回安全字段和 event refs。所有 refs 必须当前 run + 当前账号。

- [ ] **步骤 3：确认 RED 后实现账号内查询 API**

不要复用会过滤取消/删除项的 `EffectiveEventRepository.watchDisplayEvents()`。在 Application Service/Local Gateway 中提供明确管理态读取，所有 SQL 先按 account 过滤，再构造领域快照。

- [ ] **步骤 4：更新工具 Schema 与 payload allowlist**

所有新增对象列表逐项重建白名单 DTO；`additionalProperties:false`；异常使用 `invalid_arguments`、`result_too_large` 或 `reference_not_found`，不透出原始异常。

- [ ] **步骤 5：运行聚焦测试并提交**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/local_agent_tools_test.dart test/features/calendar/calendar_event_service_test.dart test/features/tasks/task_lifecycle_test.dart test/features/tasks/plan_block_undo_test.dart
Pop-Location
git diff --check
git add <Task 2 精确文件>
git commit -m "feat(agent): query lifecycle management state"
```

## Task 3：配置态只读查询与关系 refs

**文件：**
- 新建：`app/lib/features/agent/application/agent_management_tools.dart`
- 修改：`app/lib/features/agent/application/agent_local_data_gateway.dart`
- 修改：`app/lib/features/agent/application/run_reference_store.dart`
- 修改：`app/lib/features/agent/application/agent_tools.dart`
- 修改：`app/lib/features/schedule/application/conflict_service.dart`
- 修改：`app/lib/features/reminders/application/reminder_override_service.dart`
- 修改：`app/lib/features/schedule/application/overlay_service.dart`
- 修改：`app/test/features/agent/local_agent_tools_test.dart`
- 新建：`app/test/features/agent/agent_management_tools_test.dart`
- 修改：`app/test/features/agent/outbound_privacy_filter_test.dart`

- [ ] **步骤 1：为 ref 类型解析写失败测试**

给 `RunReferenceStore` 增加只返回内部 `(kind, localId)` 的安全解析 API，使 `ref_target` 能接收 event/task/planblock，同时保持跨 run、错 kind 和未知 ref 全部失败。不得把该内部结果加入模型 payload。

- [ ] **步骤 2：实现 `get_schedule_relations`**

输入一个必填参与方 ref 和可选第二 ref，只返回 `source=user` 的 occurrence relation 或匹配系列 rule；绑定 `ref_relation`，返回 scope、双方安全摘要、conflictState、reason、有效范围和删除后 fallback。派生 overlap 不生成 ref，`exam_for_course` 不返回。

- [ ] **步骤 3：实现 `get_reminders` 与 `get_user_overlay`**

Reminder 返回未来 desired offsets、明确禁用标记及 delivered/missed/failed 计数；Overlay 分别返回 single_event/course_series 显式层和清除后有效值，不能只返回 EffectiveEvent 合并值。

- [ ] **步骤 4：注册工具与隐私白名单**

将新工具加入 `localAgentTools`，每个 Schema `additionalProperties:false`，关系/提醒/Overlay 嵌套 DTO 均逐字段 allowlist。测试注入 `db_id/cookie/profilePath` 被剔除或拒绝。

- [ ] **步骤 5：运行测试并提交**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_management_tools_test.dart test/features/agent/local_agent_tools_test.dart test/features/agent/outbound_privacy_filter_test.dart
Pop-Location
git diff --check
git add <Task 3 精确文件>
git commit -m "feat(agent): inspect removable local configuration"
```

## Task 4：账号安全 Undo 预览与组合快照

**文件：**
- 修改：`app/lib/features/tasks/application/undo_recorder.dart`
- 修改：`app/lib/features/tasks/application/undo_service.dart`
- 修改：`app/lib/features/agent/application/agent_management_tools.dart`
- 修改：`app/lib/features/agent/application/agent_local_data_gateway.dart`
- 修改：`app/test/features/tasks/plan_block_undo_test.dart`
- 修改：`app/test/features/agent/agent_management_tools_test.dart`

- [ ] **步骤 1：写旧 payload 兼容与账号隔离失败测试**

验证现有 v1 Task/Event/PlanBlock/Overlay/Relation/Reminder/JW move Undo 全部仍可执行；另一账号的 preview 返回不可撤回且不能读取摘要，另一账号调用 undo 不能删除原账号 UndoSlot。

- [ ] **步骤 2：扩展 Undo envelope 和组合恢复**

`UndoCommand` 增加可选安全摘要；`UndoService` 增加账号安全 `preview()`；新增版本兼容的组合 payload，能原子恢复实体行、Reminder 快照、关系/Link/权限配置。组合恢复任一失败时不清空 slot，并写安全 failure 日志；成功后只消费一次。

- [ ] **步骤 3：实现 `get_last_undoable_action`**

无参数，返回存在性、中文安全摘要、动作类型和北京时间；不返回 payload、ID 或 ref。该工具仅预览，不消费 slot。

- [ ] **步骤 4：验证并提交**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/tasks/plan_block_undo_test.dart test/features/agent/agent_management_tools_test.dart
Pop-Location
git diff --check
git add <Task 4 精确文件>
git commit -m "feat(agent): preview and restore composite undo snapshots"
```

## Task 5：单次 Event、Task 与 PlanBlock 生命周期

**文件：**
- 修改：`app/lib/features/calendar/application/calendar_event_service.dart`
- 修改：`app/lib/features/tasks/application/task_lifecycle_service.dart`
- 修改：`app/lib/features/tasks/application/plan_block_service.dart`
- 修改：`app/lib/features/tasks/application/plan_block_lifecycle_port.dart`
- 修改：`app/lib/features/reminders/application/reminder_service.dart`
- 修改：`app/test/features/calendar/calendar_event_service_test.dart`
- 修改：`app/test/features/tasks/task_lifecycle_test.dart`
- 修改：`app/test/features/tasks/plan_block_undo_test.dart`
- 修改：`app/test/features/reminders/reminder_service_test.dart`

- [ ] **步骤 1：为确定性状态机写失败测试**

覆盖 Event complete/skip/cancel/reopen/delete/restore，Task complete/cancel/reopen/delete/restore，PlanBlock done/skip/cancel/delete/restore；重复动作返回 already_* 或 invalid_lifecycle_transition；每个修改检查 expectedUpdatedAt。

- [ ] **步骤 2：实现 Task 父项抑制规则**

Task cancel 继续取消未来 accepted PlanBlock，reopen 不恢复；Task delete 只设父 `deletedAt`，子块、Link、关系保留但不投影；restore 重新显露原状态。确认预览可读取未来块、提醒、关联事件和关系数量。

- [ ] **步骤 3：实现 PlanBlock 与 Reminder 规则**

PlanBlock delete 保留父 Task 和 replacement 链；restore 恢复原 status。实体 cancel/delete 只取消 future desired Reminder，保留历史；restore/reopen 不自动恢复 Reminder；Undo 恢复完整删除前快照。

- [ ] **步骤 4：避免 Agent 双重日志**

Application Service 默认仍按 UI 用户操作写日志；Agent Gateway 调用必须能关闭服务内 user ActionLog，由外层 `commitAgentWriteAtomically` 写唯一 source=agent 业务日志。不要用 `NoopUndoRecorder` 跳过本 Task 的生命周期 Undo。

- [ ] **步骤 5：验证并提交**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/calendar/calendar_event_service_test.dart test/features/tasks/task_lifecycle_test.dart test/features/tasks/plan_block_undo_test.dart test/features/reminders/reminder_service_test.dart
Pop-Location
git diff --check
git add <Task 5 精确文件>
git commit -m "feat(schedule): complete local lifecycle transitions"
```

## Task 6：重复个人日程三种 scope

> **前置阻塞（2026-08-04，已由 Task 6A 前置计划满足）：** 生产查询现在会展开
> `CalendarEventSeries`，重复 occurrence 已能通过生产组合路径可达。必须完整执行并验证
> `docs/superpowers/plans/2026-08-04-recurring-occurrence-production-reachability.md`
> （Schema 7、范围投影、稳定 ref、稀疏 exception 锚点及生产创建入口）；
> **在本 Task 的生命周期实现前必须通过该前置计划的 Task 9 硬门组合测试**，否则
> 不得继续本 Task 的实现，也不得用手工插入
> `calendar_events.personalSeriesId/occurrenceKey` 的测试冒充生产可达性。

**文件：**
- 新建：`app/lib/features/calendar/application/recurrence_lifecycle_service.dart`
- 修改：`app/lib/features/calendar/application/recurrence_service.dart`
- 修改：`app/lib/features/schedule/application/effective_event_repository.dart`
- 修改：`app/lib/features/agent/application/agent_local_data_gateway.dart`
- 修改：`app/test/features/calendar/recurrence_test.dart`
- 修改：`app/test/features/agent/local_agent_tools_test.dart`
- 修改：`app/test/features/schedule/schedule_projection_test.dart`

- [ ] **步骤 1：要求 Task 6A 生产可达性硬门测试后继续**

执行并确认 `2026-08-04-recurring-occurrence-production-reachability.md` 的 Task 9
硬门组合测试已经通过，然后继续本 Task（不再无谓停止）：一个由生产 `create_event`
创建的 `CalendarEventSeries` occurrence 能出现在生产日程/管理查询中并绑定
`ref_event`，ref 能解析出 seriesId + occurrenceKey，关系/Reminder/TaskEventLink 能
通过稀疏 exception 锚点持久引用，且未向 `calendar_events` 物化 occurrence。若任一
断言失败，立即停止并回报主人，不得继续步骤 2。本 Task 不标记为完成——Task 6A 的
硬门属于前置计划 Task 9 的验收，本 Task 仍需实现剩余生命周期。

- [ ] **步骤 2：实现 366 天影响预览**

预览返回当前 occurrence、影响数量、是否超出 366 天/无限、受影响 Reminder、exception 和关系数。任何未明确 scope 的重复 cancel/delete/restore 返回 `scope_required`。

- [ ] **步骤 3：实现 `only_this`**

取消写 occurrence status override；删除设置 exception `deletedAt`，无 exception 时建立空 override tombstone；reopen/restore 恢复原 override。所有动作版本重检、同事务 Undo。

- [ ] **步骤 4：实现 `this_and_future`**

复用系列分段：截断旧段、创建新段、迁移兼容 exception/Reminder/关系规则；cancel/delete 作用于新段，reopen/restore 只作用该段。不得影响旧历史。

- [ ] **步骤 5：实现 `whole_series`**

只改系列 status/deletedAt，不逐项物化；保留历史 exception。无限系列确认预览明确标记。所有 this-and-future/whole-series 至少 high + always_ask。

- [ ] **步骤 6：验证并提交**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/calendar/recurrence_test.dart test/features/agent/local_agent_tools_test.dart test/features/schedule/schedule_projection_test.dart
Pop-Location
git diff --check
git add <Task 6 精确文件>
git commit -m "feat(calendar): add scoped recurring lifecycle actions"
```

## Task 7：Reminder 与 Overlay 清除服务

**文件：**
- 修改：`app/lib/features/reminders/application/reminder_override_service.dart`
- 修改：`app/lib/features/reminders/application/reminder_service.dart`
- 修改：`app/lib/features/schedule/application/overlay_service.dart`
- 修改：`app/test/features/reminders/reminder_override_undo_test.dart`
- 修改：`app/test/features/reminders/reminder_service_test.dart`
- 修改：`app/test/features/schedule/overlay_conflict_test.dart`

- [ ] **步骤 1：写 Reminder 历史 + sentinel 失败测试**

覆盖 event/task/plan_block，selected_offsets/all，缺失 offset 原子失败，delivered/missed/failed 历史保留，以及存在历史行时 sentinel 仍能阻止 reconcile 重建默认提醒。修正当前 `existing.every(cancelled)` 判定，改为显式识别禁用 sentinel。

- [ ] **步骤 2：泛化 ReminderOverrideService**

按 targetType/targetId 统一读取和清除，只移除/取消未来 desired 配置；`all` 写无 offset cancelled sentinel；selected 清除后无剩余 offset 同样写 sentinel。Undo 保存完整 before rows。

- [ ] **步骤 3：写 Overlay 三态失败测试**

明确区分 absent/set/clear；支持 Spec 字段与字段组；清除 attendance_decision 同时清除时间戳；部分清除保持其他字段；全空物理删除行；single 层清除后 series fallback、series 层清除后来源默认正确。

- [ ] **步骤 4：实现三态 API 与原子清除**

不得用 `null` 同时表示“未提供”和“清空”。无效字段、目标变化或 scope 不可用时整项回滚；确认预览展示清除后的有效值。

- [ ] **步骤 5：验证并提交**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/reminders/reminder_override_undo_test.dart test/features/reminders/reminder_service_test.dart test/features/schedule/overlay_conflict_test.dart
Pop-Location
git diff --check
git add <Task 7 精确文件>
git commit -m "feat(schedule): clear reminders and overlay fields safely"
```

## Task 8：关系、TaskEventLink 与权限覆盖清除

**文件：**
- 修改：`app/lib/features/schedule/application/conflict_service.dart`
- 新建：`app/lib/features/tasks/application/task_event_link_service.dart`
- 修改：`app/lib/features/agent/application/agent_permission_policy_service.dart`
- 修改：`app/test/features/schedule/overlay_conflict_test.dart`
- 修改：`app/test/features/tasks/task_lifecycle_test.dart`
- 修改：`app/test/features/agent/agent_permission_policy_service_test.dart`

- [ ] **步骤 1：实现显式关系/规则删除**

只接受账号内、`source=user`、`relationType=conflict` occurrence 行或用户系列规则；删除后用共享投影计算 occurrence -> series -> overlap -> no_conflict fallback。`exam_for_course` 和派生 overlap 返回不可删除错误。规则确认预览统计未来 366 天影响。

- [ ] **步骤 2：实现 TaskEventLink 解除**

服务接受 taskId/eventId + 双方版本/存在性快照，同账号、未删除、link 存在才删除；学校来源 event 可解除本地 link；不修改其他对象；写组合 Undo。

- [ ] **步骤 3：实现单项权限恢复默认**

`resetPolicy(account, action, target)` 只删除一个覆盖行并清除首次确认时间；无覆盖返回 `already_default` 且不写日志/Undo。不能重置 `reset_permission_policy` 自身保护；工具最终为 critical + always_ask。

- [ ] **步骤 4：验证并提交**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/schedule/overlay_conflict_test.dart test/features/tasks/task_lifecycle_test.dart test/features/agent/agent_permission_policy_service_test.dart
Pop-Location
git diff --check
git add <Task 8 精确文件>
git commit -m "feat(agent): remove local relation link and policy overrides"
```

## Task 9：完整写工具 Schema、Gateway 与错误映射

**文件：**
- 修改：`app/lib/features/agent/application/agent_write_tools.dart`
- 新建：`app/lib/features/agent/application/agent_lifecycle_tools.dart`
- 修改：`app/lib/features/agent/domain/agent_write_gateway.dart`
- 修改：`app/lib/features/agent/data/drift_agent_write_gateway.dart`
- 修改：`app/lib/features/agent/application/agent_tools.dart`
- 修改：`app/lib/features/agent/application/agent_composition.dart`
- 修改：`app/test/features/agent/write_tools_test.dart`
- 修改：`app/test/features/agent/drift_agent_write_gateway_test.dart`
- 修改：`app/test/features/agent/agent_tool_registry_test.dart`
- 修改：`app/test/features/agent/outbound_privacy_filter_test.dart`

- [ ] **步骤 1：锁定所有公开 Schema**

逐项实现 Spec §7 的 `update_event`、`update_task`、`update_plan_block`、`delete_schedule_relation`、`clear_reminder`、`clear_user_overlay`、`unlink_task_event`、`reset_permission_policy`、`undo_last_action`。全部 `additionalProperties:false`，一调用一目标。

- [ ] **步骤 2：改造 `update_event` 兼容层**

公开 Schema/Prompt 只含 `action`。内部保留一版 `delete:true/status` 解析并映射到 action；legacy 与 action 混用返回 `invalid_write_arguments`。字段 edit 与生命周期 action 互斥；重复生命周期 scope 必填；source 非 user 返回 `source_event_not_editable`。

- [ ] **步骤 3：实现 propose 快照和 commit TOCTOU**

每个 propose 保存版本/内容快照和影响预览；确认后网关 Application Service 重新比较。普通 no-op 返回 already_*，不写 ActionLog/Undo；stale 返回 `stale_target`。

- [ ] **步骤 4：实现确定性错误映射**

只返回 Spec §20 的安全错误码。不得让 `StateError`/Drift 异常落为带文本结果；registry 仍作为最后 `tool_execution_failed` 防线。

- [ ] **步骤 5：注册工具和结果白名单**

将所有新工具加入 composition/registry；结果只允许 result/status/action/count/guidance 等规范化字段，绝不含 ID/ref/账号/原始异常。关系/Undo refs 只存在读取结果中。

- [ ] **步骤 6：验证并提交**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/write_tools_test.dart test/features/agent/drift_agent_write_gateway_test.dart test/features/agent/agent_tool_registry_test.dart test/features/agent/outbound_privacy_filter_test.dart
Pop-Location
git diff --check
git add <Task 9 精确文件>
git commit -m "feat(agent): expose complete lifecycle deletion tools"
```

## Task 10：Grounding、Prompt v8、顺序汇总与额度边界

**文件：**
- 修改：`app/lib/features/agent/application/agent_grounding_policy.dart`
- 修改：`app/lib/features/agent/application/agent_system_prompt.dart`
- 修改：`app/lib/features/agent/application/agent_context_builder.dart`
- 修改：`app/lib/features/agent/application/agent_session_service.dart`
- 修改：`app/lib/features/agent/application/agent_tool_budget.dart`
- 新建：`app/lib/features/agent/application/agent_mutation_ledger.dart`
- 修改：`app/test/features/agent/agent_grounding_policy_test.dart`
- 修改：`app/test/features/agent/agent_context_builder_test.dart`
- 修改：`app/test/features/agent/agent_session_service_test.dart`
- 修改：`app/test/features/agent/agent_tool_budget_test.dart`

- [ ] **步骤 1：写自由聊天与明确操作分类失败测试**

能力/风险/“怎么删除”继续自由聊天。明确取消、删除、恢复、清除、解除关联、撤回只开放对应查询 + 写工具族；对象/scope/字段不明确时允许模型先追问。来源事件“删除”不得直接开放 update_event 删除。

- [ ] **步骤 2：升级 Prompt v8**

`version8` 仅追加 v7，保留全部 Burst 规则。明确：查询后写、当前 run refs、一个调用一个目标、先列候选、多对象逐项、不能重试同一删除、没有终端 success 不得声称完成、课程/考试/二课只能经用户明确选择后本地隐藏、Undo 必须先预览。

- [ ] **步骤 3：实现顺序 mutation ledger**

对本轮取消/删除/恢复/清除工具记录每个实际发出的终端结果，最终给出成功/拒绝/失败/未处理计数；未知错误折叠为安全码。它只汇总已发出的调用，不扩大额度、不保存标题/ref、不自动继续下一 run。

- [ ] **步骤 4：保护普通额度和 Burst**

测试 12 个普通删除调用可执行，第 13 个按既有额度阻止并要求拆分；任何删除工具集合都不能获得 createTask Burst；已有 13/32 个纯 create_task Burst、第二 Burst 拒绝和单个后续 create_task 正常的测试全部保持 GREEN。

- [ ] **步骤 5：保持单次强制纠正边界**

明确 mutation 第一次完全不调用工具时，Runtime 仅用相关工具 + `tool_choice=any` 强制纠正一次；自由聊天不纠正。拒绝、stale、取消或技术错误后不自动重试同一删除。

- [ ] **步骤 6：验证并提交**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_grounding_policy_test.dart test/features/agent/agent_context_builder_test.dart test/features/agent/agent_session_service_test.dart test/features/agent/agent_tool_budget_test.dart
Pop-Location
git diff --check
git add <Task 10 精确文件>
git commit -m "feat(agent): ground and settle lifecycle mutations"
```

## Task 11：最小管理 UI 与导航闭环

**文件：**
- 修改：`app/lib/features/calendar/presentation/personal_event_management_page.dart`
- 修改：`app/lib/features/tasks/presentation/task_center_page.dart`
- 修改：`app/lib/features/tasks/presentation/task_detail_loader.dart`
- 修改：`app/lib/features/tasks/presentation/task_detail_page.dart`
- 修改：`app/lib/features/agent/presentation/agent_permission_section.dart`
- 修改：`app/lib/features/agent/presentation/agent_chat_page.dart`
- 修改：相关 GoRouter/App Shell 组合文件（实施时以当前路由为准）
- 修改：`app/test/features/calendar/calendar_event_form_test.dart` 或新增管理页测试
- 修改：`app/test/features/tasks/task_ui_test.dart`
- 修改：`app/test/features/tasks/task_detail_flow_test.dart`
- 修改：`app/test/features/agent/agent_permission_section_test.dart`
- 修改：`app/test/features/agent/agent_chat_page_test.dart`

- [ ] **步骤 1：个人日程管理分类**

增加“已取消/已隐藏/已删除”可见筛选；取消项 reopen，删除项 restore；状态文字满足浅色背景对比度；不改变周课表对取消/隐藏/删除的过滤。

- [ ] **步骤 2：Task/PlanBlock 恢复入口**

Task 中心已删除项继续展示并可恢复；Task 详情增加已删除 PlanBlock 折叠区及恢复按钮；父 Task 删除时子块不进入周课表，恢复后按原状态重现。

- [ ] **步骤 3：权限默认/自定义状态**

每行显示当前是否为自定义覆盖，并提供单项恢复默认；critical 行仍不可放宽。保留现有全局恢复默认入口，但 Agent 工具只重置单项。

- [ ] **步骤 4：Agent 导航与折叠工具过程**

成功结果按对象产生可点击“查看日程/查看任务” chip；配置清除不产生无意义 chip；工具调用仍默认折叠；UI 不显示 ref/ID。Undo 成功后刷新对应页面。

- [ ] **步骤 5：Widget/无障碍测试并提交**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/tasks/task_ui_test.dart test/features/tasks/task_detail_flow_test.dart test/features/agent/agent_permission_section_test.dart test/features/agent/agent_chat_page_test.dart test/accessibility/milestone_accessibility_test.dart
Pop-Location
git diff --check
git add <Task 11 精确文件>
git commit -m "feat(app): expose lifecycle recovery controls"
```

## Task 12：组合回归、人工验收与最终交接

**文件：**
- 修改：`app/test/integration/agent_composition_flow_test.dart`
- 修改：`app/test/integration/read_only_agent_flow_test.dart`
- 新建：`docs/agent-complete-delete-tools-retest-2026-08-03.md`
- 修改：`docs/agent-complete-delete-tools-handoff-2026-08-03.md`
- 修改：`docs/read-only-agent-handoff.md`
- 修改：`docs/architecture.md`
- 修改：`AGENTS.md`
- 修改：本计划的执行证据区

- [ ] **步骤 1：增加真实 registry + Drift 组合测试**

至少覆盖：

1. 查询 -> 取消/重开个人事件；
2. 单次与三个重复 scope 删除/恢复；
3. Task 删除抑制子块、恢复显露、Reminder 不自动恢复、Undo 完整恢复；
4. PlanBlock 删除/恢复与父 Task/replacement 保留；
5. relation/rule 删除后的 fallback；
6. Reminder sentinel 经 reconcile 不重建且历史保留；
7. Overlay single/series 清除 fallback；
8. TaskEventLink unlink；
9. permission 单项 reset；
10. get_last_undoable_action -> undo_last_action；
11. 来源事件删除拒绝并仅在明确同意后隐藏；
12. 多对象部分成功与第 13 个普通调用额度边界；
13. 账号切换、stale target、ref 过期、隐私白名单。

- [ ] **步骤 2：回归 create_task Burst 与只读来源**

运行 Burst 组合测试，确认 13 周 Task 用例、32 上限、单 Burst 和聚合文案不变；只读 Agent、二课、校园、评课查询相关组合测试保持通过。自动测试禁止联网。

- [ ] **步骤 3：创建主人填写的人工验收文档**

仿照现有 retest 文档逐项给出 Windows Release 操作、预期结果、日志检查和末尾 `完成：`。不得代填。

- [ ] **步骤 4：运行全量验证**

```powershell
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
Push-Location app
E:\flutter\flutter\bin\flutter.bat analyze
E:\flutter\flutter\bin\flutter.bat test
E:\flutter\flutter\bin\flutter.bat build windows --release
Pop-Location
git diff --check
git status --short
```

若 Conda editable install 仍指向主工作树，按现有 Burst 交接说明临时把当前 worktree `src` 放在 `PYTHONPATH` 首位；禁止重装或修改环境。

- [ ] **步骤 5：两阶段最终审查**

先逐条对照 Spec 做 compliance review，再做 code quality/security review。重点检查：无学校来源删除、无跨账号 ref/Undo、无动态权限注入、无删除 Burst、无硬编码学期、无 raw exception、无虚假成功、无 UI ref 泄漏。

- [ ] **步骤 6：刷新交接与提交**

记录每个 Task commit、准确测试数量/输出、Release 路径、人工验收未执行项和最终 `git status`。更新 `AGENTS.md`/architecture 的工具数量与生命周期能力，但不得把自动测试写成人工验收通过。

```powershell
git add <Task 12 精确文件>
git commit -m "test(agent): close complete deletion workflows"
```

---

## 每个 Task 的强制汇报格式

```text
Task N complete
Changed: <高信号摘要>
Tests: <实际命令与准确通过/失败数量>
Commit: <hash>
Next: Task N+1
```

不得连续静默完成多个 Task。遇到以下任一情况立即停止并报告：需要修改 Python/SourceBundle/学校平台写边界、需要新增数据库表/列、重复系列无法稳定恢复、必须提高普通删除额度、必须物理删除业务实体、或发现主人未提交内容与目标文件冲突。

## 执行证据（由 Task 12 更新）

Tasks 1–11 在 `feature/delete-tools` 分支逐 Task 提交并各自独立审查（见
`git log --oneline feature/delete-tools`）。Task 12 为收尾任务，最终验证如下
（worktree `E:/107/.worktrees/delete-tools-plan`，2026-08-05）：

- **最终 HEAD**：`78f10db fix(agent): restore deleted tasks and plan blocks through the agent gateway`
  （Task 12 及其后一次全量综合审查修复批收尾；完整提交序列见
  `git log --oneline feature/delete-tools`）。
- **Task 12 commit**：`9bc81cf test(agent): close complete deletion workflows`
  （组合回归 13 场景 + 只读来源回归；首个 commit `685cb86` 为其前驱）。
- **收尾修复批（2026-08-05 全量审查，C1–C4 / I1–I4 / M1）**：`84d28e8`(C1 迁移守卫)、
  `38963b5`(C2 提醒过滤)、`26415e3`(C3 TOCTOU)、`ef0a42a`(I1 重复生命周期 Undo)、
  `8c42198`(C4 双重日志)、`3bf54a3`(I2 快照重检)、`719627f`(I3 影响预览)、`78f10db`(I4 restore 可达)。
  以上逐项经 TDD 循环并独立复核；最终 HEAD 为 `78f10db`。
- **组合测试**：`agent_composition_flow_test.dart` 的 `Task 12 lifecycle composite
  regression` 组覆盖 brief 13 场景（真实 composition registry + Drift + unit-of-work）；
  `read_only_agent_flow_test.dart` 的 `Task 12 read-only source regression` 组确认
  catalog 来源仍可执行。既有 Burst/管理态/服务级/预算/grounding 覆盖未重复。
- **全量 Python**：`python -m unittest discover -s tests` → 394 项全部通过。
- **Python 编译**：`python -m compileall -q src tests` → 退出码 0。
- **Flutter analyze**：13 项既有 info/warning（本轮未改动文件，无 error）；本轮两个
  集成测试文件 analyze 无问题。
- **Flutter 全量测试**：`flutter test` → 1291 项全部通过。
- **Windows Release**：`flutter build windows --release` → 成功，exe 路径
  `app/build/windows/x64/runner/Release/ustc_assistant_app.exe`。
- **人工验收**：新建 `docs/agent-complete-delete-tools-retest-2026-08-03.md`，每个
  `完成：` 均留空，未代填。自动测试通过 ≠ 人工验收通过；真实人工验收尚未执行。
- **残余限制**：Agent `update_task(restore)`/`update_plan_block(restore)` propose 现经
  `taskByIdIncludeDeleted/planBlockByIdIncludeDeleted`（含软删行）可达，commit 仍由
  `TaskLifecycleService.restore`/`PlanBlockService.restore` 重检 `expectedUpdatedAt` +
  未删状态（`already_active`/`stale_target`），非 restore 动作保持过滤查找；
  Agent 写入用 `NoopUndoRecorder`，`undo_last_action` 只撤回用户最近一次可撤回操作；
  既有 13 项 analyze info/warning 未清理（位于未改动文件）。
- **最终工作树**：`git status --short` 见
  `docs/agent-complete-delete-tools-handoff-2026-08-03.md` 第 9.7 节；受保护 regenerated
  插件文件未暂存，本分支始终精确 `git add <paths>`。
