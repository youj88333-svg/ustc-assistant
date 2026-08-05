# Agent 完整删除工具交接（2026-08-03）

## 1. 目标与入口

在隔离工作树执行：

```text
E:/107/.worktrees/delete-tools-plan
```

分支：

```text
feature/delete-tools
```

设计权威：

```text
docs/superpowers/specs/2026-08-03-agent-complete-delete-tools-design.md
```

实施计划：

```text
docs/superpowers/plans/2026-08-03-agent-complete-delete-tools.md
```

推荐使用 `superpowers:subagent-driven-development`，每个 Task 使用新的实现子 Agent，并在 Task 后分别执行 spec compliance 与 code quality review。若不用子 Agent，使用 `superpowers:executing-plans` 严格按序执行。不要跳过计划中的 RED/GREEN 证据。

## 2. 起始状态

- `main` 在规划时为 `be8b8ee docs: record owner manual acceptance results in relation closure retest`。
- Burst 完整实现已经合并到 `main`，核心提交包括 `c909952`、`245856f`、`b154506`、`9cfc63a`、`01b4a70`。
- 已确认删除工具 Spec 由 `125a330 docs: design complete agent delete tools` 纳入本分支。
- Plan/交接提交哈希在本轮文档提交后记录；实施开始前以 `git rev-parse HEAD` 为准。
- 本工作树在规划开始时干净；未修改任何生产代码。

开始前执行：

```powershell
git branch --show-current
git rev-parse HEAD
git status --short
git log -8 --oneline --decorate
```

如果 `main` 后续有新提交，先审查差异并把功能分支更新到最新主线；不要盲目 rebase/merge 覆盖本地修改。

## 3. 分支与受保护状态

本地分支已精简为：

```text
main
feature/delete-tools
```

旧的重复 `spec/delete-tools` 工作树/分支已确认内容等价并删除。不要再为同一工作创建平行 spec/plan 分支。

根工作树 `E:/107` 在规划时有以下主人/生成器改动，本分支不得暂存、覆盖、删除或格式化它们：

```text
 M app/windows/flutter/generated_plugin_registrant.cc
 M app/windows/flutter/generated_plugin_registrant.h
 M app/windows/flutter/generated_plugins.cmake
?? _merge-pending-docs/
```

本功能工作树不包含这些脏文件。始终使用精确 `git add <paths>`，禁止 `git add .`。

远端 `origin/refactor/project-cleanup` 已是 `main` 的祖先，但本轮没有删除远端分支；不要把远端清理混入功能实现。

## 4. 已完成能力与不可回归项

- Windows Flutter 首版、Drift 本地模型、五条 Python 只读来源、SourceBundle 和 Windows Bridge 已完成。
- Agent 已有本地/外部只读工具、11 个写工具、run-local refs、权限确认卡、ActionLog、tool invocation 持久化、一步纠正和确定性终态。
- `get_schedule(query=...)` 支持跨保留历史按标题找事件；大范围详细查询会以 `schedule_summary_required` 要求 course summary。
- 显式 conflict/no_conflict 关系支持 event/event、event/PlanBlock 和 PlanBlock/PlanBlock；普通 overlap 默认 conflict。
- 教务整日移动只影响某一天全部教务课程，支持 clear；考试、二课和个人事件不受影响。
- `create_task` Burst 仅为高置信度多 Task 请求提供一次最多 32 个纯 create_task blocks；普通工具额度仍为 12，模型调用额度仍为 8。
- 真实学校模型人工验收结果与自动测试分开记录。

删除工具实现不得破坏以上行为。

## 5. 规划审查发现的关键实现事实

### 5.1 动态风险尚未真正生效

`AgentWriteProposal` 已带 `actionType/riskLevel/targetType`，但 `AgentWriteTool.execute` 仍用工具静态 getter 做权限决议。同一 `update_event` 的 edit/cancel/delete/restore 因此无法安全采用不同策略。Task 1 必须先修此基础，并用工具 allowlist 防止 proposal 注入任意策略键。

### 5.2 Agent Gateway 当前不记录业务 Undo

`DriftAgentWriteGateway` 明确构造 `NoopUndoRecorder`。删除/清除工具若照抄现有 gateway，会出现“操作成功但 undo_last_action 无法恢复”。新生命周期和配置删除必须写真实 UndoSlot；同时避免 Application Service 的 source=user 日志与外层 source=agent 日志重复。

### 5.3 现有只读工具看不到删除对象

`DriftAgentLocalDataGateway.tasks/taskById/planBlocks*` 都过滤 `deletedAt`；普通 `get_schedule` 使用有效投影，也过滤取消/隐藏/删除项。必须先补管理态查询，恢复工具不能依赖历史 run 的旧 ref。

### 5.4 Reminder sentinel 与历史保留存在冲突

当前 reconcile 仅在“该目标所有 reminder 行都是 cancelled 且全部无 offset”时视为明确禁用。保留 delivered/missed/failed 历史后这个条件永远不成立，默认提醒会重建。Task 7 必须改为明确 sentinel 识别，并覆盖有历史行的回归测试。

### 5.5 OverlayMutation 无法表示 clear

当前 `null` 表示“参数未提供”，`_upsert` 使用 `mutation.value ?? existing.value`，无法把字段清空。必须引入 absent/set/clear 三态，不能在 Agent Gateway 直接更新 Drift 行绕过服务。

### 5.6 重复个人日程有生产可达性风险

代码中存在 `CalendarEventSeries`、occurrence exception、`RecurrenceService` 和编辑测试，但规划审查没有发现生产 `EffectiveEventRepository`/周课表消费 `calendar_event_series` 的路径；现有 Agent recurring 分支依赖 `calendar_events.personalSeriesId/occurrenceKey`，在测试中主要由 fake snapshot 覆盖。

Task 6 必须先写生产组合测试证明 occurrence 可查询并得到 ref。若不能用现有契约稳定接通，停止并请求主人审核；不要把重复范围悄悄降级成 only_this，也不要擅自迁移 schema。

### 5.7 配置清除缺少读取身份

目前没有 relation ref、Reminder 配置查询、Overlay 分层查询、TaskEventLink event refs 或 Undo preview。所有清除写之前必须由本轮只读工具产生 ref，禁止模型用标题或数据库身份猜测。

### 5.8 多对象终态不能只看工具名成功集合

当前 grounding 主要用 `succeededTools` 判断 terminal tool 是否成功。同一个删除工具调用一次成功，不足以证明多个候选都已处理。Task 10 要增加不含标题/ref 的顺序 mutation ledger，准确汇总实际发出调用的成功/拒绝/失败/未处理数量，但不能扩大普通 12 次额度。

## 6. 已确认且不得重开的问题

1. Cancel 保留 cancelled 状态与历史，可 reopen；Delete 使用 `deletedAt`，可 restore。
2. Event/Task/PlanBlock/系列不物理删除；配置记录可清除但必须可一步 Undo。
3. 重复事件 scope 只有 `only_this`、`this_and_future`、`whole_series`；不得默认猜 scope。
4. Task delete 只抑制父项，子 PlanBlock、Link、关系保留；restore 后按原状态重新显露。
5. Restore/reopen 不自动恢复 Reminder；只有一步 Undo 恢复完整删除前提醒快照。
6. 删除显式 no_conflict 关系后，若仍时间重叠，会回退为派生 conflict；这不是删除失败。
7. 派生 overlap 不可删除；应创建显式 no_conflict。导入 `exam_for_course` 不可删除。
8. Reminder clear-all 必须留下禁用 sentinel；历史 delivered/missed/failed 保留。
9. Overlay 支持精确字段、字段组和 all；清除单节层后允许课程系列层回退。
10. TaskEventLink 用 task ref + event ref 解除，不新建 link ref。
11. 权限 reset 只移除一个自定义覆盖，critical + always_ask，不能重置自己的保护。
12. Undo 必须先 `get_last_undoable_action`，只撤回一步；指定较早对象使用 restore。
13. 多对象逐项执行，无 batch/delete-all；超过普通额度由用户拆分。
14. 课程、考试、二课删除请求不能静默变成 hide；必须解释并取得明确选择。
15. 工具调用过程默认折叠；不新建统一回收站。

## 7. 执行顺序与审查门

严格按计划 Task 1-12 执行：

1. 动态审批权威与权限目录。
2. 实体管理态查询。
3. 配置态查询与关系 refs。
4. Undo 预览与组合快照。
5. 单次 Event/Task/PlanBlock 生命周期。
6. 重复事件三 scope（含生产可达性硬门）。
7. Reminder/Overlay 清除。
8. Relation/Link/Policy 清除。
9. 写工具 Schema/Gateway/错误映射。
10. Grounding/Prompt/顺序汇总/额度。
11. 最小 UI。
12. 组合回归、人工验收文档和最终交接。

每个 Task 完成后立即向主人同步：

```text
Task N complete
Changed: <高信号摘要>
Tests: <实际命令与准确结果>
Commit: <hash>
Next: Task N+1
```

不得静默执行多个 Task。Task 6 硬门、任何数据库迁移、Python/SourceBundle 修改、普通额度放宽、业务实体物理删除或学校平台写操作都必须停下请求确认。

## 8. 验证要求

每个 Task 使用计划内聚焦测试。最终必须运行：

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

自动测试不得联网。涉及真实模型、校园网/iWAN、确认卡、Windows Release UI 和学校登录的部分由主人按新 retest 文档验收；执行 Agent 不得代填 `完成：`。

## 9. 最终交还内容

Task 12 已完成。以下为本轮最终交还事实（自动测试通过，人工验收未执行）。

### 9.1 最终 HEAD 与本轮 Task 12 commit

- 最终 HEAD：`78f10db fix(agent): restore deleted tasks and plan blocks through the agent gateway`
  （Task 12 及其后全量综合审查修复批收尾，2026-08-05）。
- Task 12 首个 commit：`9bc81cf test(agent): close complete deletion workflows`
  （组合回归 13 场景 + 只读来源回归；首个 commit `685cb86` 为其前驱）。
- Tasks 1–11 commit 见 `git log --oneline feature/delete-tools`（逐 Task 提交，各自独立审查）。

### 9.2 组合测试覆盖

新增组合级回归（真实 composition registry + Drift gateway + unit-of-work），位于
`app/test/integration/agent_composition_flow_test.dart` 的 `Task 12 lifecycle composite
regression` 组，覆盖 brief 13 个场景：

1. 查询 -> 取消/重开个人事件（`update_event` cancel/reopen）；
2. 单次事件 delete/restore + 重复 scope_required 守卫；
3. Task delete 抑制子块、restore 重新显露、Agent 写入不占 Undo 槽（restore 经管理 UI
   授权的 `TaskLifecycleService` 路径，与生产管理 UI 一致）；
4. PlanBlock delete 保留父 Task + replacement 链，restore 经管理 UI 路径恢复；
5. `delete_schedule_relation` 物理删除显式关系；
6. `clear_reminder(all)` 写禁用 sentinel；
7. `clear_user_overlay(single_event)` 清除字段后系列层回退；
8. `unlink_task_event` 物理删除单条 link；
9. `reset_permission_policy` 强制确认（未批准前不删除覆盖）；非可重置动作拒绝；
10. `get_last_undoable_action` 预览 -> `undo_last_action` 一次性消费；
11. 课程（来源）事件 delete 被拒绝，不静默隐藏；
12. 12 个普通 delete 调用成功，第 13 个被预算阻止；删除工具不消耗 Burst；
13. 跨账号 ref 不可解析、stale target 拒绝、不泄漏原始 id、账号隔离。

只读来源回归（`app/test/integration/read_only_agent_flow_test.dart` 的 `Task 12
read-only source regression` 组）确认 catalog/二课来源在生命周期工具族加入后仍可执行。

既有覆盖（未重复）：`agent_management_tools_test.dart`（管理态/配置态只读工具）、
`write_tools_test.dart` Task 9 组（生命周期写工具 schema/commit）、
`task_lifecycle_test.dart`/`plan_block_undo_test.dart`/`reminder_override_undo_test.dart`
（服务级生命周期与 Undo）、`agent_tool_budget_test.dart`（额度/Burst/ledger 边界）、
`agent_grounding_policy_test.dart`（grounding lifecycle 分类）、组合级 Burst（`agent_composition_flow_test.dart`
13 周/32 上限/聚合文案）、Task 9 重复生产可达性硬门。

### 9.3 全量验证结果

- Python：`conda run -n ustc_assistant python -m unittest discover -s tests` →
  **394 项测试全部通过**（OK）。Conda editable install 仍指向主工作树 `E:\107\src`，
  运行时把当前 worktree `src` 置于 `PYTHONPATH` 首位（未重装/改环境）。
- Python 编译：`python -m compileall -q src tests` → 退出码 0。
- Flutter analyze：`flutter analyze` → 13 项既有 info/warning（均位于本轮未改动的
  `event_detail_loader_test.dart`/`schedule_page_test.dart`/`schedule_projection_test.dart`/
  `plan_block_undo_test.dart`，无 error）；本轮改动的两个集成测试文件 analyze 无问题。
- Flutter 全量测试：`flutter test` → **1291 项测试全部通过**（All tests passed!）。
- Windows Release：`flutter build windows --release` → 构建成功，exe 路径
  `app/build/windows/x64/runner/Release/ustc_assistant_app.exe`。
- `git diff --check`：仅 `app/windows/flutter/generated_plugin_registrant.*` /
  `generated_plugins.cmake` 的 LF→CRLF 提示（受保护的 regenerated 文件，本分支未暂存）。

### 9.4 人工验收文档与未执行状态

- 新建人工验收文档：`docs/agent-complete-delete-tools-retest-2026-08-03.md`。
- 该文档每个 `完成：` 均留空，未由执行 Agent 代填。
- 本轮自动测试通过不等同于人工验收通过；真实 Key + 校园网/iWAN + Windows Release UI +
  学校登录的人工验收尚未执行，由主人按该文档逐项填写。

### 9.5 重复日程生产可达性结论

Task 6A 硬门已通过（组合级 `Task 9 hard gate` 测试）：生产 `create_event` 重复系列只写
一条 `CalendarEventSeries`，`RecurringEventProjector` 在有界范围内投影 occurrence，
查询/写入均不向 `calendar_events` 物化 occurrence 行；locator/seriesId/occurrenceKey/
DB id 不泄漏给模型。本轮未改动该路径。

### 9.6 残余限制

- Agent `update_task(action=restore)` / `update_plan_block(action=restore)` 的 propose
  现经 `taskByIdIncludeDeleted`/`planBlockByIdIncludeDeleted`（含软删行）可达，commit
  仍由 `TaskLifecycleService.restore`/`PlanBlockService.restore` 重检
  `expectedUpdatedAt` + 未删状态（`already_active`/`stale_target`）；非 restore 动作
  （complete/cancel/reopen/delete 与 done/skip/cancel/delete）保持过滤查找，已删目标
  仍 `target_not_found`。I4 修复后 Agent 工具与管理 UI 两条恢复路径均可达。
- Agent 写入使用 `NoopUndoRecorder`，故 `undo_last_action` 只撤回用户最近一次可撤回操作，
  不撤回 Agent 写入（设计意图，非缺陷）。
- 既有 13 项 `flutter analyze` info/warning 未在本轮清理（位于未改动文件，避免无关扩散）。

### 9.7 最终工作树状态

`git status --short`（本功能工作树）：

```text
 M AGENTS.md
 M docs/architecture.md
?? docs/agent-complete-delete-tools-retest-2026-08-03.md
?? .flutter-test-output.txt（临时验证输出，不提交）
 M app/windows/flutter/generated_plugin_registrant.cc    （受保护，不暂存）
 M app/windows/flutter/generated_plugin_registrant.h     （受保护，不暂存）
 M app/windows/flutter/generated_plugins.cmake            （受保护，不暂存）
```

根工作树 `E:/107` 的受保护 regenerated 文件与本分支无关，本分支始终使用精确
`git add <paths>`，未 `git add .`，未暂存或覆盖根工作树改动。

不要在实现完成前把本交接写成“人工验收通过”。
