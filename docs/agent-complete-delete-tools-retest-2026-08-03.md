# Agent 完整删除与生命周期工具人工复测清单 (2026-08-03)

> 更新日期：2026-08-03
>
> 适用范围：`feature/delete-tools` 分支完成后
> `2026-08-03-agent-complete-delete-tools`（Tasks 1–12）的 Windows Release App。
>
> 本清单只记录真实人工验收结果。自动测试通过不能代替本清单；未执行项目的“完成：”必须留
> 空。主人填写“完成：”时，请如实记录“通过”或“失败：现象 + 可复现步骤”，不要改写其他
> 项目的既有结果。

## 0. 测试前准备

- 使用实现完成后新构建的 Windows Release App（见交接文档第 9 节 Release 路径），不要
  沿用旧进程。
- 配置真实学校 API Key，并处于校园网或可访问学校模型的 iWAN 路由环境。
- 登录一个包含课程、考试、二课与个人日程的学校账号；当前默认学期可以是任意学期
  （本表不依赖默认学期，也不依赖 `semesterId`/`2026spring`/`2026fall`）。
- 涉及 Agent 写工具时观察确认卡并如实记录工具名、次数和错误码；不记录 API Key、Cookie、
  完整学号或 `ref_*` 原值。
- 重复日程场景需要先通过 Agent 或界面创建一个每周重复的个人日程（至少 3 次），再用 Agent
  对其执行删除/恢复操作。

记录本测试账号的个人信息范围（用于核对重复日程的 `activeFrom`～`activeThrough`）：

- 重复日程名：____________
- `activeFrom`：____________
- `activeThrough`：____________

完成：

---

## 1. 查询后取消/重开个人事件

**目的：** 验证 Agent 先用 `get_schedule(query=...)` 定位一个个人事件并绑定 ref，再用
`update_event(action=cancel)` 取消、随后 `update_event(action=reopen)` 重开，行保留、状态正确、
不泄漏原始 id。

**操作步骤（Windows Release）：**

1. 向 Agent 发送：“帮我取消掉【个人事件名】这个日程，之后再重开它。”
2. 观察确认卡：工具名应为 `update_event`，预览只显示标题与变更，不显示 `ref_*` 或数据库 id。
3. 点击“确认本次”执行取消；再次发送“重开它”并确认重开。

**预期结果：**

- 取消后日程状态为 `cancelled`，行保留（不物理删除）。
- 重开后状态恢复为 `active`，周课表重新显示该事件。
- 确认卡与诊断中不出现 `ref_*` 原值、数据库主键、API Key 或完整学号。
- 取消/重开各自只处理这一个目标，不级联其他日程。

**记录字段：**

- 首次查询工具名/参数（应为 `get_schedule` + `query`）：____________
- `update_event` 调用次数与 action：____________
- 安全错误码（若有）：____________
- 取消后/重开后状态：____________

完成：

---

## 2. 单次与三个重复 scope 删除/恢复

**目的：** 验证单次个人事件 `update_event(action=delete/restore)` 软删除/恢复；重复日程在
未指定 scope 时返回 `scope_required`，指定 `only_this` / `this_and_future` / `whole_series`
后按范围软删除并可恢复。

**操作步骤（Windows Release）：**

1. 对一个单次个人事件发送：“删除这个日程。”并确认；再“恢复它”并确认。
2. 对一个重复日程发送：“删除这个重复日程。”应先收到 `scope_required` 引导。
3. 分别用“只删除这次 / 从这次以后都删 / 删除整个系列”三种范围各执行一次删除并确认。

**预期结果：**

- 单次事件：删除后 `deletedAt` 置位，默认视图不可见；恢复后 `deletedAt` 清空。
- 重复日程无 scope：返回 `scope_required`，不静默默认 `only_this`。
- 三个 scope 各自按范围软删除，不物理删除系列；可经恢复或一步 Undo 回退。
- 不出现 `ref_*`、系列 id、occurrence key 泄漏。

**记录字段：**

- 单次删除/恢复结果：____________
- `scope_required` 是否出现：____________
- `only_this` 结果：____________
- `this_and_future` 结果：____________
- `whole_series` 结果：____________

完成：

---

## 3. Task 删除抑制子块、恢复显露、Reminder 不自动恢复、Undo 完整恢复

**目的：** 验证 `update_task(action=delete)` 软删除父任务并从默认视图抑制，子执行块/关联/关系
保留；`restore` 后按原状态重新显露；Restore/reopen 不自动恢复提醒；一步 Undo 恢复完整删除前
提醒快照。

**操作步骤（Windows Release）：**

1. 准备一个有执行块和提醒的任务。
2. 发送：“删除任务【任务名】。”并确认。
3. 在任务中心确认该任务进入已删除区，执行块仍在。
4. 发送：“恢复这个任务。”（或经任务中心恢复入口）。
5. 再发送：“撤回上一步操作。”（`undo_last_action`）。

**预期结果：**

- 删除后任务 `deletedAt` 置位，子执行块 `deletedAt` 不变（不级联）。
- 恢复后任务按原状态重新显露，但提醒不自动恢复。
- `undo_last_action` 撤回最近一次可撤回操作；撤回前应能用 `get_last_undoable_action` 预览。
- 不出现跨账号 ref 或原始 id 泄漏。

**记录字段：**

- 删除后子块是否保留：____________
- 恢复后任务是否显露：____________
- 提醒是否自动恢复（应为否）：____________
- Undo 是否恢复完整快照：____________

完成：

---

## 4. PlanBlock 删除/恢复与父 Task/replacement 保留

**目的：** 验证 `update_plan_block(action=delete)` 软删除执行块，不影响父任务；replacement
链指针保留；`restore` 恢复原状态。

**操作步骤（Windows Release）：**

1. 对一个已安排的执行块发送：“删除这个执行时间段。”并确认。
2. 在任务详情确认该块进入已删除区，父任务仍在。
3. 发送：“恢复这个执行时间段。”并确认。

**预期结果：**

- 删除后块 `deletedAt` 置位，父任务 `deletedAt` 不变。
- replacement 链指针（`rescheduledToPlanBlockId`）保留。
- 恢复后块 `deletedAt` 清空，回到原状态。

**记录字段：**

- 删除后父任务是否保留：____________
- replacement 链是否保留：____________
- 恢复后状态：____________

完成：

---

## 5. relation/rule 删除后的 fallback

**目的：** 验证 `delete_schedule_relation` 删除一个显式 `no_conflict` 关系；删除后若仍时间重叠，
回退为派生 `conflict`（这不是删除失败）；派生 overlap 与 `exam_for_course` 关系不可删除。

**操作步骤（Windows Release）：**

1. 对两个重叠事件先记录为“不冲突”。
2. 发送：“删除这两个事件的不冲突关系。”并确认。
3. 观察删除后是否回退为派生冲突。

**预期结果：**

- 显式 `no_conflict` 关系被物理删除。
- 删除后若仍重叠，回退为派生 `conflict`，不报删除失败。
- 派生 overlap 与导入 `exam_for_course` 关系删除请求被拒绝（`relation_not_deletable`）。

**记录字段：**

- 删除是否成功：____________
- 删除后冲突回退状态：____________
- 派生/exam 删除是否被拒：____________

完成：

---

## 6. Reminder sentinel 经 reconcile 不重建且历史保留

**目的：** 验证 `clear_reminder(scope=all)` 写禁用 sentinel，reconcile 后默认提醒不重建；
delivered/missed/failed 历史保留。

**操作步骤（Windows Release）：**

1. 对一个有提醒的事件发送：“清除这个日程的全部提醒。”并确认。
2. 触发一次 reconcile（如重启 App 或导入刷新）。
3. 观察该事件的提醒是否重建。

**预期结果：**

- 清除后存在禁用 sentinel，未来不再触发默认提醒。
- reconcile 后默认提醒不重建（sentinel 生效）。
- 已 delivered/missed/failed 的历史提醒行保留。

**记录字段：**

- 清除后 sentinel 是否存在：____________
- reconcile 后默认提醒是否重建（应为否）：____________
- 历史提醒是否保留：____________

完成：

---

## 7. Overlay single/series 清除 fallback

**目的：** 验证 `clear_user_overlay(scope=single_event)` 清除单次层字段；清除课程系列层后允许
课程系列层回退；任一字段无效整项不写。

**操作步骤（Windows Release）：**

1. 对一个有个人标注的事件发送：“清除这个日程的出勤标注。”并确认（single_event）。
2. 对一个课程系列事件发送：“清除整个系列的显示标题。”并确认（course_series）。

**预期结果：**

- single_event 清除后对应字段为空，单次层被移除。
- 清除单次层后课程系列层字段回退生效。
- course_series 清除后系列层字段为空。
- 无效字段名在 propose 即被拒绝。

**记录字段：**

- single_event 清除结果：____________
- 系列层回退是否生效：____________
- course_series 清除结果：____________

完成：

---

## 8. TaskEventLink unlink

**目的：** 验证 `unlink_task_event` 解除一对 (task, event) 关联，只删除唯一 link，不修改任务、
日程或其他配置。

**操作步骤（Windows Release）：**

1. 对一个已关联日程的任务发送：“解除【任务名】与【日程名】的关联。”并确认。

**预期结果：**

- 该 (task, event) link 被物理删除。
- 任务与日程本身不变。
- 不存在 link 时返回 `link_not_found`，不写。

**记录字段：**

- 解除后 link 是否删除：____________
- 任务/日程是否不变：____________

完成：

---

## 9. permission 单项 reset

**目的：** 验证 `reset_permission_policy` 删除一个自定义覆盖，恢复默认；无覆盖时返回
`already_default`；`reset_permission_policy` 自身与 `move_jw_course_day` 等不可重置动作被拒。

**操作步骤（Windows Release）：**

1. 先对某动作放宽过确认策略（remember）。
2. 发送：“恢复【动作名】的确认策略为默认。”并确认。
3. 对 `reset_permission_policy` 自身尝试重置。

**预期结果：**

- 重置后该动作的自定义覆盖被删除，恢复默认模式。
- 无覆盖时返回 `already_default`。
- 不可重置动作（含 `reset_permission_policy`、`move_jw_course_day`）被拒绝。
- reset 始终需要确认（critical，不提供 remember）。

**记录字段：**

- 重置后覆盖是否删除：____________
- `already_default` 是否出现：____________
- 不可重置动作是否被拒：____________

完成：

---

## 10. get_last_undoable_action -> undo_last_action

**目的：** 验证先 `get_last_undoable_action` 预览最近可撤回操作，再 `undo_last_action` 一步
撤回；撤回后槽清空，第二次无槽；指定较早对象应使用 restore 而非 undo。

**操作步骤（Windows Release）：**

1. 执行一次本地写操作（如删除一个个人事件）。
2. 发送：“我上一步做了什么能撤回的？”观察预览。
3. 发送：“撤回上一步。”并确认。

**预期结果：**

- 预览返回安全中文摘要与时间，不返回 payload/id/ref。
- 撤回成功后最近操作被逆转，槽清空。
- 第二次 `undo_last_action` 返回 `no_undo_available`。
- 预览/撤回均账号隔离，不跨账号。

**记录字段：**

- 预览是否返回安全摘要：____________
- 撤回是否成功：____________
- 第二次是否无槽：____________

完成：

---

## 11. 来源事件删除拒绝并仅在明确同意后隐藏

**目的：** 验证课程、考试、二课等学校来源事件删除请求被拒绝（不静默变成 hide）；只在用户明确
选择后才本地隐藏，且隐藏不等于取消报名/删除来源。

**操作步骤（Windows Release）：**

1. 对一门课程发送：“删除这节课。”
2. 观察 Agent 是否解释来源不可删除并询问是否仅本地隐藏。
3. 明确同意隐藏后观察该课程在本地视图的状态。

**预期结果：**

- 课程/考试/二课删除请求被拒绝（`source_event_not_editable` 或同类），不静默 hide。
- Agent 解释后只在用户明确同意才本地隐藏。
- 隐藏后来源事实仍只读，不取消二课报名，不物理删除来源记录。

**记录字段：**

- 删除是否被拒：____________
- 是否征求明确同意：____________
- 隐藏后来源是否仍只读：____________

完成：

---

## 12. 多对象部分成功与第 13 个普通调用额度边界

**目的：** 验证多对象请求逐项执行、允许部分成功；普通工具额度仍为 12，第 13 个普通调用被
`tool_call_budget_exceeded` 阻止；删除工具不借用 `create_task` Burst Lease。

**操作步骤（Windows Release）：**

1. 准备 13 个可删除的个人事件。
2. 发送：“把这 13 个日程都删掉。”
3. 观察前 12 个是否逐项确认/执行，第 13 个是否被额度阻止。

**预期结果：**

- 多对象逐项执行，无 batch/delete-all。
- 前 12 个普通调用额度内可执行；第 13 个返回 `tool_call_budget_exceeded`。
- 删除工具不触发 `create_task` Burst，不放宽额度。
- 部分成功时聚合文案准确给出成功/未完成计数。

**记录字段：**

- 实际删除数量：____________
- 第 13 个是否被阻止（错误码）：____________
- 聚合文案：____________

完成：

---

## 13. 账号切换、stale target、ref 过期、隐私白名单

**目的：** 验证账号切换后另一账号看不到本账号的删除对象/调用记录；run-local ref 不跨 run
复用；stale target 返回 `stale_target` 而非静默写；结果/UI 不泄漏 ref/id/account/raw exception。

**操作步骤（Windows Release）：**

1. 账号 A 执行一次删除操作。
2. 切换到账号 B，确认 B 的任务中心/诊断不出现 A 的删除对象或调用记录。
3. 切回 A，A 的对象仍在。
4. 在确认卡中对一个刚被另一处修改的目标执行删除，观察是否 `stale_target`。

**预期结果：**

- 账号 B 不出现 A 的对象/调用记录；切回 A 仍存在。
- run-local ref 在另一 run 不可解析。
- stale target 返回 `stale_target`，不静默写。
- 确认卡、诊断、UI 不出现 `ref_*` 原值、数据库主键、account、raw exception。

**记录字段：**

- 账号隔离是否成立：____________
- ref 是否跨 run 失效：____________
- stale target 错误码：____________
- 是否泄漏 ref/id/account/raw exception：____________

完成：

---

## 14. 综合观察

**目的：** 汇总本清单各项的最终状态，供主人整体判断。

- 第 1~13 项各项是否全部通过/失败如实记录：____________

完成：
