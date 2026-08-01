# Agent 人工验收修复交接

日期：2026-08-01  
工作树：`E:\107\.worktrees\write-tools`  
分支：`feature/write-tools`  
交接基线 HEAD：`998a556`  
状态：设计与实施计划已完成，生产代码尚未开始修改

## 1. 交接目标

下一位 Agent 只在当前隔离工作树执行：

- Spec：`docs/superpowers/specs/2026-08-01-agent-manual-acceptance-debug-design.md`
- Plan：`docs/superpowers/plans/2026-08-01-agent-manual-acceptance-debug.md`

Spec 提交：`aaef1cf`  
Plan 提交：`998a556`

执行 Plan 的 Task 1 到 Task 10，每个 Task 独立红灯测试、最小实现、绿灯、review 和提交。
完成后停止，不自行合并到 `main`。若 Plan 与 Spec 发生冲突，以 Spec 为准，并在修改前报告用户。

## 2. 用户人工测试输入

真实结果位于未跟踪文件：

```text
E:\107\.worktrees\write-tools\docs\agent-testing.md
```

该文件由用户填写，只能读取。不得修改、格式化、暂存、提交，也不得把失败项替用户改为成功。

主要结果：

- 正常：日程、事件详情、空闲、任务、任务详情、同步、历史、二课开放活动以及多数写工具；
- 漏调用：待确认事件、待确认 PlanBlock、校园目录首次请求；
- 输出污染：assistant 模仿 `[2026-08-01T19:42]`，并在 overlay 流程直接打印 `ref_*`；
- 幻觉：第二次 `plan_task` 未调用工具却声称成功；
- UI 缺口：已写入 PlanBlock 不显示在周视图；
- 循环：`create_schedule_relation` 前反复查“具体事件引用”；
- 规则变更：时间重叠现在应默认冲突，显式 `conflict/no_conflict` 仍优先；
- 来源问题：校园搜索未找到 2026 秋选课通知、校园详情校验失败、公开引用 chip 不可点；
- 新功能：只支持把某天全部教务课程移动到另一天，目标日原安排保留。

## 3. 已证实根因

### 3.1 会话直接接受无工具回答

`app/lib/features/agent/application/agent_session_service.dart` 在模型 turn 没有 `tool_use` 时直接
结束。提示词只有行为建议，没有运行时落地验证；`LlmRequest` 也没有 `tool_choice`。因此明确的
事实查询和写请求可能被普通模型文本提前结束。

### 3.2 UI/历史直接接收模型原始流文本

历史上下文在 `agent_context_builder.dart` 添加时间戳前缀；模型虽被提示不要模仿，但没有
确定性过滤。`ref_*` 同样只靠提示词阻止复述。Session 把 delta 直接写入 view state 与
ChatRepository，导致时间戳和 ref 可见并持久化。

### 3.3 没有相同工具参数熔断

会话只有总模型/工具预算，没有 fingerprint。`get_conflicts` 又只返回已经判定为冲突的事件，
用它寻找一个准备新建的冲突关系参与者是循环依赖。

### 3.4 `get_schedule` 不能按标题跨历史定位

工具以日期范围为中心，`course_summary` 故意不绑定 occurrence ref。模型面对上学期课程时缺少
安全事件查找能力，容易反复调用或错误依赖当前默认学期。

### 3.5 PlanBlock 没有进入周视图数据流

`schedule_page.dart` 周视图只监听 `EffectiveEventRepository.watchDisplayEvents()`；PlanBlock 只在
任务中心加载。落库和 Task 详情正常，周网格为空是确定的实现缺口。

### 3.6 当前冲突只认显式关系

`effective_event_repository.dart` 的 SQL 仅把显式 `conflict` 标成警告；普通重叠不算冲突。
用户已批准改为“重叠默认冲突，显式 conflict/no_conflict 覆盖”，实现不得继续沿用旧提示词和
旧 SQL 语义。

### 3.7 Chip 审查

- 本地“查看日程”可点击；
- 本地“查看任务”也可点击，但同样跳 `/schedule`，默认落在周视图，需显式 section 路由；
- 校园公开引用是故意写死的普通 `Chip`，确实不可点，但本轮暂缓；
- 模型 Markdown 链接有意不可点；
- 其他 InputChip/FilterChip/Task ActionChip 均有回调。

### 3.8 校园链路根因（只记录，不实施）

选课通知 `https://www.teach.ustc.edu.cn/notice/notice-teaching/20425.html` 发布于 2026-07-16。
Python 通知目录只收当天及前 6 天，2026-08-01 刷新不会收录它；本地搜索不访问网站，因此
无法命中。详情失败还来自 Python raw detail 中 `le.ustc.edu.cn` candidate URL 与固定 Query
Result host 校验不一致。

用户决定下一阶段舍弃移动端 Python Bridge 来源实现并迁移到 Flutter，所以这些 Python 问题
本轮不修。迁移强制要求已写入 Spec 第 14 节：简报 7 天、可搜索目录 90 天、逐来源新鲜度、
安全详情投影、可信引用跳转和明确 iCourse 授权。

## 4. 已批准的关键语义

### 4.1 自由聊天与工具纠错

- 自由聊天、能力咨询、假设讨论和明确“不查询”使用 `auto`，无工具也可正常结束；
- 只有高置信度的事实查询或实际写请求才进入 grounding policy；
- 首次漏调用后缩窄工具并最多纠错一次；
- 学校网关支持时使用 `tool_choice=any`；若请求在无内容前 `protocol_error`，只允许一次 auto
  兼容回退；
- 仍无工具则 `grounding_failed`，不得保留查询/操作成功幻觉；
- mutation 必须有终端写工具成功证据，lookup 成功不等于写成功。

### 4.2 PlanBlock 与冲突

- accepted/done PlanBlock 进入周网格，点击进入所属 Task；
- CalendarEvent 和 PlanBlock 使用统一 `ScheduleGridItem`，不得伪造 CalendarEvent；
- 显式 occurrence > 显式 series > 时间重叠派生；
- 重叠默认 conflict，显式 no_conflict 可压制；不重叠显式 conflict 仍成立；
- 全天事项不因同日自动冲突；派生关系不写入数据库。

### 4.3 整日教务课程移动

这是移动，不是交换：A 日符合条件的课程投影到 B 日，B 日原安排保留。

仅匹配：

```text
source == ustc_jw
type == course
allDay == false
source record 当前有效
原始来源日期 == sourceDate
```

不移动考试、二课、个人事件、PlanBlock 或全天事项。课程时间、时长、地点、来源 ID 和用户
overlay 保持；新日期参与冲突。A->B 后再 A->C 是 retarget；再执行 B->C 只移动原生 B 日
课程，不连带从 A 投影来的课程。

`JwDayMoves(accountId, sourceDate)` 唯一，来源同步不能覆盖；clear 删除覆盖；手动 UI 支持现有
一步撤回。Agent 新工具 `move_jw_course_day` 为 critical、始终确认、不可 remember，也不能通过
权限工具放宽。

## 5. Plan 执行顺序与依赖

1. **Task 1 Grounding**：先建立自由聊天/强制查询边界和 tool_choice 协议；不依赖后续日程改动。
2. **Task 2 Text/Loop Guard**：增量过滤与 fingerprint；确保后续测试看不到 refs。
3. **Task 3 Historical Lookup**：扩展 `get_schedule(query)`；关系/overlay 修复依赖它。
4. **Task 4 Local Chips**：小范围路由修复，独立完成。
5. **Task 5 Unified Grid**：PlanBlock 进入周视图；Task 6 依赖统一 grid item。
6. **Task 6 Conflict Projection**：pair-level 规则和 Agent pair 输出；Task 7 移动后复用。
7. **Task 7 JW Day Move Storage**：schema 4->5、Service、有效时间、详情、undo/reset。
8. **Task 8 Manual Move UI**：依赖 Task 7 Service。
9. **Task 9 Agent Move Tool + Prompt v4**：依赖 Task 1/3/6/7；提示词只在此处最终升级一次。
10. **Task 10 Closure**：组合测试、全量验证、文档与人工复测清单。

不要为了并行而同时修改 `agent_session_service.dart`、`schedule_page.dart` 或数据库 schema。
若使用 Subagent-Driven，每个 Task 用新 subagent，并在下一 Task 前做 spec compliance + code quality
两阶段 review。

## 6. 高风险实现提醒

### Grounding

- 不要把所有请求强制成 `any`；这会破坏自由聊天；
- 不要用广泛“查询/帮我”关键词就强制；能力咨询必须是 null requirement；
- forced-choice compatibility fallback 只能在首个强制请求无内容失败时使用一次；
- stop/cancel 后不得继续 model call；
- 写成功的证据是终端工具结果，不是模型措辞分类。

### 文本过滤

- 必须跨 SSE delta，最终再正则替换不足以避免流式短暂泄露；
- raw text 只供 LLM 结构化 replay，display text 才能持久化；
- tool-use turn 的铺垫最终要从 draft 移除；
- 不要删除正文内部正常时间戳。

### 日程与 PlanBlock

- `ScheduleGridItem` 是 presentation/domain projection，不是新持久化实体；
- 关系表已经支持 event/plan_block occurrence 组合，series rule 只支持现有稳定 series 类型；
- PlanBlock 状态过滤必须与 Spec 完全一致；
- event/PlanBlock overlap expansion 的第二次点击必须分流到正确详情。

### JwDayMove

- Drift schemaVersion 变为 5并运行 build_runner；
- 日期平移按北京日历构造，不能用 epoch 加 `Duration(days:n)` 假设每个时区日固定；
- `EffectiveEventRecord.source` 保持原始行，另加 effective display time；
- `watchDisplayEvents`、byId、overlappingRecords、free time、pending review、Agent detail 都必须统一
  使用移动后的有效时间；
- preview 按原始事件日期查询，不能把已经移动的投影再次移动；
- Agent gateway 延续现有 `NoopUndoRecorder` 规则；手动 UI 才占用一步撤回槽；
- Agent 原子审计由 `AgentWriteTool` 外层完成，避免 Service 再写一份 user 日志。

### 权限与提示词

- 在 policy target/risk/default map 注册 `move_jw_course_day`，但不要加入用户可放宽动作集合；
- 工具同时 `riskLevel=critical`、`forceConfirmation=true`、`rememberAllowed=false`；
- `update_permission_policy` 的 action enum 不允许新动作；
- Prompt 从 3 一次升到 4；不要在多个 Task 反复改版本。

## 7. 工作树保护

交接时已有且必须原样保留：

```text
 M app/windows/flutter/generated_plugin_registrant.cc
 M app/windows/flutter/generated_plugin_registrant.h
 M app/windows/flutter/generated_plugins.cmake
?? docs/agent-testing.md
```

这些不是本次 Spec/Plan 改动。每次提交使用精确路径；生成 Drift 文件时只提交
`app/lib/core/database/app_database.g.dart`，不要误把 Windows plugin registrant 文件带入提交。

## 8. 环境与验证

Python：

```powershell
$env:PYTHONPATH='E:/107/.worktrees/write-tools/src'
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
```

Flutter：

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat analyze
E:\flutter\flutter\bin\flutter.bat test
E:\flutter\flutter\bin\flutter.bat build windows --release
Pop-Location
```

Drift codegen 只在 Task 7 执行：

```powershell
Push-Location app
E:\flutter\flutter\bin\dart.bat run build_runner build --delete-conflicting-outputs
Pop-Location
```

最终必须记录本轮实际测试数量、构建输出和精确 HEAD。历史文档中的 394/648 等数字不能复制为
本轮结果。

## 9. 人工验收边界

自动测试完成后仍要求用户在真实 Release、学校 API Key 和校园网/iWAN 下复测：

- 原测试 4、5、9、W4、W5、W8；
- 未填写的 8、W9；
- 自由聊天不调用工具；
- 学校 Anthropic 接口对 `tool_choice` 的真实兼容性；
- 上学期事件查询/关系创建不受默认学期影响；
- 整日课程 move/retarget/clear/undo 和目标日冲突；
- “查看日程”和“查看任务”进入正确分区。

校园/iCourse 的 13-15 保持待迁移，不得在本轮文档中标成已修复或通过。

## 10. 完成与停止条件

只有以下全部成立才可报告“代码实施完成”：

- 10 个 Task 均有独立提交和实际红绿测试证据；
- 全量 Python/Flutter/analyze/Windows build 本轮实际通过；
- 没有新增学期硬编码、用户可见 ref 或来源外部写能力；
- schema 5 迁移、账号 cascade、业务数据清理和一步撤回均有真实 Drift 测试；
- 用户保护文件未被修改或提交；
- 当前真实人工验收状态被准确记录为待复测；
- 校园 Python 问题仍明确留给 Flutter 来源迁移。

达到后停止在 `feature/write-tools`，向用户报告提交列表、验证证据和人工复测清单。不要 merge、
push 或修改 `main`，等待用户决定。
