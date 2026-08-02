# USTC Assistant 只读 Agent 实施交接

更新时间：2026-08-02

## 0. 当前状态（2026-08-02 更新）

**人工验收修复里程碑（2026-08-01-agent-manual-acceptance-debug）已全部完成**：
Tasks 1–9（grounding Policy + tool_choice、文本过滤 + 指纹、get_schedule 标题查询、
本地 chip 分区路由、PlanBlock 周网格、默认冲突推导、JwDayMove schema 4→5 与服务、
手动整日调课 UI、move_jw_course_day 工具 + prompt v4）与 Task 10 收尾（合并验收
回归 + 全量验证 + 文档同步）均在 `feature/write-tools` 分支提交；Task 10 最终
验证见第 7.2 节。

**审查修复轮（2026-08-02-agent-manual-acceptance-review-repairs）已全部完成**：
修复实现审查中发现的四类缺陷——(1) 写工具失败后仍保留模型虚假成功文本、(2)
Grounding 意图误判（礼貌查询被 free-chat 吞掉、整日移动/plan_task 误归类）、
(3) `tool_choice` 兼容回退吞掉真实上游错误、(4) 冲突投影随本地历史增长产生
重复全量二次复杂度计算。其最终精确 HEAD 与完整验证结果见第 7.3 节。**尚未合并到
`main`**，合并时机由 finishing-a-development-branch 流程决定；真实学校模型/API
人工验收尚未执行（见第 7.3 节“真实人工验收待办”）。

**关系收尾修复轮（2026-08-02-agent-relation-closure-repairs）已全部完成**：Tasks
1–8 闭合持久工具调用生命周期与重启诊断恢复、关系落地“用户决策即对错”、统一事件与
PlanBlock 关系、混合关系 UI、本地六秒撤销提示、学期 Task 摘要优先 + 澄清，以及收尾的
集成回归 + 复测文档 + 全量验证。其最终精确 HEAD 与完整验证结果见第 7.4 节。**尚未合并
到 `main`**，合并时机由 finishing-a-development-branch 流程决定；真实学校模型/API 人工
验收尚未执行（见第 7.4 节“真实人工验收待办”与 `docs/agent-relation-closure-retest-2026-08-02.md`）。

修复内容概要：

- Grounding Policy：显式操作必须真实调用工具，首次漏调注入一次受限纠错
  （`tool_choice=any` + 收窄声明），耗尽后 `grounding_failed` 安全结束；自由聊天
  从不强制工具；学校网关不接受 any 时仅回退一次 `auto`。系统提示词版本 4。
- 输出净化：技术时间戳、`ref_*`、过程性话术不进入聊天正文；完全相同参数的重复
  工具调用熔断（`repeated_tool_call`）。
- `get_schedule(query=...)` 按标题跨本地历史定位写目标（不读默认学期、无硬编码
  semesterId）；`get_conflicts` 永不作为参与者查找器（避免"查引用"无限循环）。
- accepted PlanBlock 进入周视图网格并可点击进入父 Task 详情；时间重叠默认推导为
  冲突，显式 conflict/no_conflict 覆盖推导。
- 整日教务课程移动：`JwDayMove`（schema 5）按账号记录，投影只按原始日期匹配、
  不链式搬运、源事件永不改写；`move_jw_course_day`（move|clear）为 critical，
  永远人工确认；手动界面支持清除与一步撤回（Agent 写入不占用撤回槽）。
- 本地 chip：`查看日程`→周视图、`查看任务`→任务分区，重路由正确更新分区。

**自动测试 ≠ 人工验收**：Python 校园（campus）与 iCourse 体验未改变（本轮无任何
`src/` 修改）；`agent-testing.md` 第 13-15 项仍等待 Flutter 来源迁移。

**真实 Release 复测请求（Task 10 Step 5，等待用户执行）**：使用修复完成后新构建的
Windows Release App（`app\build\windows\x64\runner\Release\ustc_assistant_app.exe`）
与真实学校 API Key，在校园网 / Panabit iWAN 下复测 `agent-testing.md` 第 4、5、9
项与 W4、W5、W8 项、补测原空白第 8 项与 W9 项，并执行：自由聊天不强制工具、学校
网关 `tool_choice` 兼容回退、跨学期历史查找（不依赖默认学期）、整日移动/清除/一步
撤回、`查看日程` 与 `查看任务` 两个本地 chip 的精确分区。校园目录第 13-15 项保持
不变（等待 Flutter 来源迁移，本轮不复测）。复测逐项记录见用户文件
`docs/agent-manual-acceptance-retest-2026-08-01.md`（未跟踪用户文件，本里程碑未
修改、未暂存、未提交），修复路径的维护版复测清单见 `docs/acceptance/read-only-agent.md`
第 11 节。

### 0.1 历史状态（2026-08-01，保留作基线）

`feature/read-only-agent` 已合并到 `main`（合并提交 `9bc83c8`，含只读 Agent Tasks
1–8、系统提示词 v2 与 Bridge 目录自动刷新，以及 `2026-07-30-read-only-agent-review-repairs`
修复轮 Tasks 1–9）。修复轮最终修复后的精确 HEAD 与完整自动验证结果记录于本文件
第 7 节（`9935bd6` / `docs: hand off reviewed agent repairs`）。完整只读 Agent
已落地：Agent 数据库表、DPAPI 保护 API Key 与配置、Anthropic SSE Provider、隐私过滤
与上下文构建、工具注册表与会话运行时、15 个只读工具（11 本地 + 4 按需来源）、Python
稳定查询 API、Bridge Query Protocol 1.0 查询作业、Flutter 查询网关与 4 个外部工具、
设置 UI、聊天 UI 与组合、端到端安全测试，以及组合级集成测试（真实路由
+ 注入式组合覆盖配置、本地日程分组摘要、同作业二课暂停/恢复、账号切换、网关释放与
捕获请求隐私断言）。

**写工具里程碑（本计划）已实现，待合并**：10 个受控本地写工具
（create_event/update_event/create_task/plan_task/create_user_overlay/
record_attendance_decision/record_listening_mode/create_schedule_relation/
set_reminder/update_permission_policy）在 `feature/write-tools` 分支上实现，包含风险
分级"审批门"确认（聊天内联确认卡）、AgentPermissionPolicy 表迁移并接入运行时决策、
设置页权限管理区与组合级写流程测试。尚未合并到 `main`，合并时机由本计划 Task 13
完成后的 finishing-a-development-branch 流程决定。写工具只作用于本地业务数据，
不新增任何学校/外部写通道；权限变更永远需要用户亲手确认。

**写工具里程碑（本计划）已完成，待合并**：`feature/write-tools` 分支上的 10 个受控
本地写工具（见上）已完成全部 7 个 Task，包含组合级回归测试（`Task 7 composition: full
hardened write flow`）覆盖严格参数校验 → 目标预览 → 确认提交 → 原子回滚的整条写流程。
十个写工具均为本地-only 且事务性审计（业务提交、用户确认日志、agent 业务日志与权限
变更同一事务；任一失败整体回滚）；确认卡预览只显示目标标题/时间等模型安全信息，
不含任何 DB id/ref；写工具参数经 `WriteArgumentReader` 严格运行时校验（未知键、类型
不匹配、非法字段组合一律拒绝为 `invalid_write_arguments` 且不产生 DB 变更）。本分支
最终验证与精确 HEAD 记录于第 7 节。尚未合并到 `main`，合并时机由本计划 Task 13
完成后的 finishing-a-development-branch 流程决定。

**真实人工验收尚未执行**：下文第 9 节的人工验收清单
（`docs/acceptance/read-only-agent.md`）需由用户在真实校园网 / Panabit iWAN / 真实
API Key 环境下逐项执行。自动测试通过不等于人工验收通过——学校 API 与学校网站从不进入
自动测试，组合级集成测试只验证代码行为。

**Minor 级别发现分类仍待执行**：各 Task 暂缓的 Minor 级别发现等待最终整分支审查
分类，由控制器单独执行，不在本交接范围内；分支已合并不改变这一待办。

以下第 1–9 节保留原始交接基线信息（实施前的状态描述），仅在第 7、8 节追加实际验证
结果与已知边界。历史基线不应被当作“功能未实现”——以本节和代码为准。

## 1. 交接目标

当前 Windows Flutter 第一版已经基本完善。下一位 Agent 的唯一主要开发目标是执行：

- `docs/superpowers/specs/2026-07-28-read-only-agent-design.md`
- `docs/superpowers/plans/2026-07-28-read-only-agent.md`

本轮只实现只读 Agent，不重新设计需求，不提前实现写工具、每日简报、视觉能力或
移动端来源采集。计划包含 13 个 Task，采用 Subagent-Driven Development 逐项实现、
测试、审查和提交。

截至本交接文档编写前，实施尚未开始：没有 Agent 数据库表、Anthropic Provider、
Agent Runtime、只读工具或聊天 UI 实现。不要把已经提交的设计和计划误认为功能已
完成。

## 2. Git 基线与工作区

关键提交：

```text
46af1f8 docs: plan read-only campus agent
9458486 docs: design read-only campus agent
a62ca27 docs: archive first-round manual acceptance results
325a734 feat: align schedule grid with official periods and add early-morning band
b0a311d fix: auto-submit USTC CAS login after filling credentials
```

当前开发基线是本地 `main` 上的 `46af1f8` 及本交接文档提交。`main` 有大量尚未
推送到 `origin/main` 的提交；开始前运行 `git status --short --branch` 和
`git log -8 --oneline --decorate`，不要拉取、重置或改写本地历史。

主工作区存在以下用户保留状态：

```text
M app/windows/flutter/generated_plugin_registrant.cc
M app/windows/flutter/generated_plugin_registrant.h
M app/windows/flutter/generated_plugins.cmake
```

这些文件当前没有可见内容差异，疑似换行符或文件状态变化。不要还原、暂存或提交。
只读 Agent 应在新的 `.worktrees/` 隔离工作区和 `feature/read-only-agent` 分支上
实现。上一次启动执行在创建工作树前已停止，目前没有为本计划创建隔离工作树，也
没有任何 Task 被部分执行。

`temp.md`、`tmp/`、`.superpowers/`、浏览器 Profile 和本地密钥均被 Git 忽略。
不得把它们加入提交。

## 3. 当前已实现能力

### Python 来源

1. 教务课程、考试和 SourceBundle 1.0 完整快照。
2. 当前报名中的二课活动列表。
3. 北京时间滚动窗口内的已报名二课日程。
4. 评课社区公开课程/教师匹配、缓存、排序和代表性点评。
5. 教务处、财务处公开目录、本地检索、按 ID 详情读取和附件缓存。
6. Windows loopback Bridge 的教务/已报名二课同步、登录恢复和取消。

Python 正式入口是 `python -m ustc_assistant`。`scripts/` 没有正式运行入口。

### Flutter Windows App

- Drift/SQLite 本地持久化与学校账号分区；
- Windows DPAPI 保护学校账号和可选密码；
- 教务、已报名二课同步与 SourceBundle 单事务导入；
- 七日周课表、周切换、官方 13 节时间、全天与凌晨事项带；
- 个人 CalendarEvent、重复系列、详情、隐藏和恢复；
- Task、PlanBlock、截止风险、结束后确认和一步撤回；
- 重叠事件、主事件、人工冲突/不冲突关系和用户覆盖；
- Reminder、操作历史、设置、清理与完全重置；
- 只读 Agent：聊天页已替换为校园 Agent，支持学校 Anthropic 模型、SSE 流式回答、
  15 个只读工具（11 本地 + 4 按需来源）、按账号隔离的长期主会话、滚动摘要、工具
  过程默认折叠、停止与重试、重启恢复、设置页模型服务配置。详见
  `docs/architecture.md`“只读 Agent 架构”一节。

Android/iOS 目录只有 Flutter 平台脚手架。共享 Agent 核心、本地模型和 ImportService
可复用，移动端登录、来源采集和安全存储适配尚未实现。

## 4. 已确认的 Agent 范围

### 学校模型服务

```text
Host:          https://api.llm.ustc.edu.cn
Anthropic API: POST /v1/messages
Model list:    GET /v1/models
Default model: deepseek-v4-flash
Streaming:     SSE
Tool calling:  tool_use / tool_result
```

- 用户按学校账号手动填写 API Key；
- Windows 使用 DPAPI 保存 Key，不写入 SQLite 明文字段、源码、日志或提交；
- 校内校园网直接访问；
- 校外由用户自行开启 Panabit iWAN；
- App 不启动或配置 iWAN、系统代理或 TUN；
- 学校 API Host 由 `AnthropicLlmProvider` 固定为 `https://api.llm.ustc.edu.cn`，不在
  App 内提供 Host 配置项；当前外部代理影响校园路由时，由用户在系统层面将该 Host 走
  直连（系统代理或 PAC），App 不管理系统代理；
- 不自动切换到第三方云模型；
- 首版只使用文本模型，不启用 `qwen3.6-chat` 视觉路由。

### 会话

- 每个学校账号只有一个长期主会话；
- 完整消息本地保存；
- 云端请求使用滚动摘要、最近消息和当前问题所需的最小工具结果；
- 摘要不是业务事实来源，日程和 Task 必须重新调用本地工具；
- 首版不自动生成每日简报，也不主动发送消息。

### 只读工具

```text
本地日程：
get_schedule
get_event_details
get_free_time
get_pending_event_reviews
get_conflicts

本地任务：
get_tasks
get_task_details
get_plan_blocks
get_pending_planblock_reviews

本地状态：
get_sync_status
get_safe_action_history

按需来源：
search_current_second_class_activities
search_icourse
search_campus_catalog
read_campus_detail
```

Agent 不能直接启动教务或已报名二课同步。报名中二课需要登录时先暂停，只有用户
点击“打开登录窗口并继续”后才能恢复。评课社区首次联网仍需按账号授权。校园详情
只能按目录临时引用读取，每批最多 3 条，最多跟进一层解析器发现的链接。

### 永久安全边界

- 不向模型发送 API Key、密码、Cookie、Token、验证码、完整学校账号、用户本人
  姓名、远端个人身份、内部数据库 ID、浏览器 Profile 路径或原始响应；
- 只发送回答当前问题所需的规范化字段；
- 远端通知、评课、二课描述和工具结果均是不可信数据，不能成为 Agent 指令；
- Agent 没有通用 HTTP、任意 URL、文件、Shell、SQL、同步或写业务数据工具；
- 二课报名和取消报名永远由用户在学校官方页面执行；
- 单次请求最多 8 轮模型调用、12 次工具调用；
- 工具过程默认折叠，用户可以停止；
- 公开回答链接必须来自工具实际返回的来源。

## 5. 实施架构

```text
Agent Chat UI
  -> AgentSessionService
       -> AnthropicLlmProvider
       -> AgentToolRegistry
       -> DriftChatRepository
       -> AgentSecretStore
       -> LocalDataGateway
       -> QuerySourceGateway
```

Flutter 拥有 Agent 核心。Windows 上查询报名中二课、评课和校园公开信息时，通过
扩展后的临时 Python Bridge 调用现有来源 service。Python 不负责聊天编排，也不
读取 Flutter 数据库。

未来迁移到 Android/iOS 时保持以下部分不变：

- Chat UI 与 AgentSessionService；
- Anthropic Provider 和 Tool Registry；
- 聊天数据库、上下文、隐私过滤和工具契约；
- Flutter 本地日程/Task 工具。

移动端只替换 `AgentSecretStore`、`QuerySourceGateway`、登录会话和少量平台生命
周期适配器。共享 Agent domain/application 代码不得依赖 Windows、Python、DPAPI
或进程 API。

## 6. 新 Agent 执行顺序

1. 阅读 `AGENTS.md`，确认项目安全规则和验证命令。
2. 阅读本文件，确认当前基线和未开始状态。
3. 完整阅读只读 Agent design。
4. 完整阅读 13 Task implementation plan。
5. 使用 `superpowers:using-git-worktrees` 创建隔离工作区。
6. 使用 `superpowers:subagent-driven-development` 执行计划。
7. 为本计划创建独立 SDD ledger；每个 Task 使用新实现者和独立审查者。
8. 每个 Task 完成聚焦测试、审查和单独提交后，才能进入下一 Task。
9. 全部分支完成后运行整分支审查和完整验证。
10. 用户完成人工 API Key、校园网/iWAN和学校登录验收后，再决定合并回 `main`。

不要在主工作区直接运行 Drift/Flutter 代码生成；这会混入当前保留的生成文件状态。
不要跳过 Task 7 的报名中二课账号 Profile 和交互登录回归，也不要把现有同步
`CollectionJob` 的 SourceBundle 校验放宽来兼容查询结果。

## 7. 验证基线

只读 Agent 修复轮（Tasks 1–9）在 `feature/read-only-agent` 分支上推进。Task 9 最终
验证时的精确 HEAD：`9935bd6`（`docs: hand off reviewed agent repairs`，本节即为该提交）；
最后一个代码提交为 `6378be5`（`config: switch default JW semester to 2026 fall`）。
后续若再提交，需重跑本节命令并刷新哈希。

写工具里程碑（Tasks 1–7，`feature/write-tools` 分支）Task 7 最终验证时的精确 HEAD：
`ad49a2b`（`test(agent): close read-write hardening milestone`，本里程碑收尾提交）；前一
代码提交为 `f07dbde`（Task 6，生成 Flutter 学期默认值）。完整验证结果见第 7.1 节。
尚未合并到 `main`，合并时机由计划 Task 13 后的 finishing-a-development-branch 流程决定。

Task 9 实测的完整自动验证结果（2026-07-31，worktree `E:/107/.worktrees/read-only-agent`）：

```text
Python unittest discover -s tests : Ran 382 tests, OK
Python compileall -q src tests    : exit 0
Flutter test test/core test/features/agent test/integration : 315 passed
Flutter test test/features (non-agent dirs)                  : 176 passed
Flutter test test/app test/accessibility test/goldens         : 24 passed
Flutter analyze (whole app)                                  : No issues found
Flutter build windows --release                              : Built build\windows\x64\runner\Release\ustc_assistant_app.exe (exit 0)
```

Task 8 新增的组合级集成测试聚焦命令（仍通过）：

```text
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/integration/agent_composition_flow_test.dart test/integration/read_only_agent_flow_test.dart test/accessibility/milestone_accessibility_test.dart
Pop-Location
```

边界扫描（Task 9 Step 5）：`app/lib` 与 `src` 中无真实密钥/完整账号/cookie 实值泄漏
（`PB12345678` 仅出现在 `outbound_privacy_filter.dart` 文档注释示例；`sk-` 命中均为
Flutter widget `Key('task-...')` 误匹配；`Bearer`/`Cookie:` 仅在注释与脱敏正则中）；
`app/lib/features/agent/domain` 与 `application` 无 `dart:io`/`windows_dpapi`/`Process`
真实导入（仅注释中声明禁止使用）。`git diff --check` 无空白错误。

自动测试只验证代码行为，不代替人工验收。学校 API 和学校网站不能进入自动测试。真实验收
由用户在可见 Edge、校园网或 Panabit iWAN 环境中执行，API Key 只通过 App 设置界面输入。
人工验收清单见 `docs/acceptance/read-only-agent.md`（`完成：` 仍留空，待真实验收填写）。

Python 测试必须在 worktree 下运行（editable install 指向主工作区 `E:/107/src`，
不是 worktree），命令为：

```powershell
$env:PYTHONPATH='E:/107/.worktrees/read-only-agent/src'
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
Push-Location app
E:\flutter\flutter\bin\flutter.bat analyze
E:\flutter\flutter\bin\flutter.bat test
E:\flutter\flutter\bin\flutter.bat build windows --release
Pop-Location
```

实施前的交接基线（保留用于历史对照，早于只读 Agent 实施）为：

```text
Python unittest: 267 passed
Python compileall: passed
Flutter tests: 203 passed
Flutter analyze: no issues
Windows Release build: passed
```

## 7.1 写工具里程碑验证（feature/write-tools，2026-08-01）

写工具里程碑（Tasks 1–7）在 `feature/write-tools` 分支上推进。Task 7 最终验证时的
精确 HEAD 记录见本文件第 7 节末尾（Task 7 提交后刷新）；最后一个代码提交为
`f07dbde`（Task 6，生成 Flutter 学期默认值）。Task 7 提交后若再提交，需重跑本节命令
并刷新哈希。

Task 7 实测的完整自动验证（2026-08-01，worktree `E:/107/.worktrees/write-tools`；
Python 测试在 worktree 下运行，`PYTHONPATH` 指向 worktree 的 `src`）：

```text
Python unittest discover -s tests   : Ran 394 tests, OK   （实施前基线 388；+6）
Python compileall -q src tests      : exit 0
Flutter analyze (whole app)         : No issues found
Flutter test (whole suite)          : 648 passed
Flutter build windows --release     : Built build\windows\x64\runner\Release\ustc_assistant_app.exe
```

Agent 聚焦测试（Step 2）与组合级回归局部命令：

```text
Flutter test test/features/agent test/integration/agent_composition_flow_test.dart
    test/integration/read_only_agent_flow_test.dart : 422 passed
（含 Task 7 最终组合回归：strict input -> target preview -> confirmation ->
  atomic commit -> remembered policy -> second direct commit -> audit-failure rollback）
```

Task 7 精确 HEAD 见第 7 节末尾（Task 7 提交后刷新）；写工具里程碑最终代码提交为
`f07dbde`（Task 6，生成 Flutter 学期默认值）。

写工具里程碑新增能力：

- 十个写工具（create_event/update_event/create_task/plan_task/create_user_overlay/
  record_attendance_decision/record_listening_mode/create_schedule_relation/
  set_reminder/update_permission_policy）全部为本地-only：只作用于本地业务数据，不新增
  任何学校/外部写通道；权限变更永远需要用户亲手确认（update_permission_policy）。
- 写操作事务性审计：业务提交、agent 业务日志、用户确认日志（agent_write_confirm）与
  权限变更（remember 放宽 / ask_first_time 首次确认）落在同一个 Drift 事务；SQLite
  fault-injection（BEFORE INSERT ... RAISE(ABORT) 触发器）验证任一步失败时业务表与日志
  一并回滚，且重跑不产生重复行。
- 确认卡目标预览：只看目标标题/时间/地点等模型安全信息，不含任何 DB id 或 ref_* token。
- 写工具参数严格运行时校验（WriteArgumentReader）：未声明键、类型不匹配、非法字段
  组合在 propose 阶段拒绝为 `invalid_write_arguments`，不产生任何 DB 变更。
- 学期默认值改由 `config/source-defaults.json` 生成（Task 6），当前值保持 `461 /
  2026fall / 2026 秋季学期`；迁移 Android/iOS 时的“统一单一数据源”仍为合并后工作，
  本里程碑仅完成 Flutter 侧默认值从共享 JSON 生成。

**真实人工验收尚未执行**：写工具相关的人工验收（真实 461 语义下询问 Agent 新建日程/
任务并亲手点击确认卡、调整权限策略等）仍需用户在真实校园网 / Panabit iWAN / 真实
API Key 环境下按 `docs/acceptance/read-only-agent.md` 第 10 节手动执行；自动测试不
代替人工验收。

## 7.2 人工验收修复里程碑验证（feature/write-tools，2026-08-02）

> **注意**：本节记录的是 2026-08-01 人工验收修复里程碑（Tasks 1–10）在 HEAD
> `69c7608` 工作树上的验证快照，**不是当前分支最新状态**。随后又完成了
> 2026-08-02 审查修复轮（Tasks 1–5，HEAD `bc1a69b`），其最终精确 HEAD 与最新
> 测试计数见第 7.3 节。以第 7.3 节为准。

人工验收修复里程碑（Tasks 1–10）在 `feature/write-tools` 分支上推进。Task 10 完整
自动验证运行在 HEAD `69c7608`（`feat(agent): add critical whole-day course moves`，
Task 9）之上的工作树（含 Task 10 未提交的合并验收回归与本文档同步）；Task 10 收尾
提交 `test(agent): close manual acceptance repairs` 即携带本节的验证内容。Task 10
之后若再提交，需重跑本节命令并刷新哈希。

Task 10 实测的完整自动验证（2026-08-02，worktree `E:/107/.worktrees/write-tools`；
Python 测试在 worktree 下运行，`PYTHONPATH` 指向 worktree 的 `src`；Python 用
PowerShell 运行）：

```text
Python unittest discover -s tests -v   : Ran 394 tests, OK
Python compileall -q src tests          : exit 0
Flutter analyze (whole app)             : No issues found
Flutter test (whole suite)              : 780 passed（含 Task 10 合并验收回归）
Flutter build windows --release         : Built build\windows\x64\runner\Release\ustc_assistant_app.exe
```

Agent 聚焦组合级回归（真实路由 + 注入式脚本化 provider）：

```text
Flutter test test/integration/agent_composition_flow_test.dart
    test/integration/read_only_agent_flow_test.dart
    test/accessibility/milestone_accessibility_test.dart : 33 passed
```

Task 10 新增的合并验收回归（`agent_composition_flow_test.dart` 单个 testWidgets，
通过真实路由 + 注入式组合）一次性覆盖人工验收复测清单的 9 个场景：

1. 自由聊天不调用任何工具；
2. 待确认查询首次漏调 → 一次受限纠错成功（`tool_choice=any` + 收窄声明）；
3. 历史标题查询 → overlay 写目标，聊天无 `ref_*` 输出；
4. 两个历史事件 → 关系写入，`get_conflicts` 从不作为参与者查找器（可观察的工具
   执行序列断言：get_conflicts 只出现在冲突场景）；
5. plan_task → accepted PlanBlock 在周视图可见且可点击进入父 Task 详情；
6. 时间重叠默认派生冲突（derivedOverlap）→ 显式 no_conflict 抑制该对；
7. 整日教务课程移动 → 非 JW 事件（晨跑）保持不变 → 手动路径清除 + 一步撤回恢复；
8. `查看日程`/`查看任务` chip 精确打开周视图/任务分区；
9. 账号切换隔离移动、引用、Task 与 Agent 历史。

同时新增：`read_only_agent_flow_test.dart` 真实工具层"首次漏调 → 一次纠错成功"
测试，`milestone_accessibility_test.dart` 写确认卡语义（确认/取消可访问、critical
卡不提供"以后不再确认"）测试。

安全/配置扫描（Task 10 Step 3）：

```text
rg semesterId/2026spring/2026fall app/lib/features/{agent,schedule} : 无匹配
    （生产代码无硬编码学期）
rg ref_[A-Za-z0-9_-]+ app/lib/features/agent/presentation app/test/fixtures : 无匹配
    （无具体用户可见 ref fixture）
git diff --check   : 干净
git status --short : 仅本任务测试/文档文件 + 受保护生成文件 + 两个未跟踪用户文档
```

**Python 校园与 iCourse UX 未改变**：本轮没有任何 `src/` 修改；
`docs/agent-testing.md` 第 13-15 项（校园目录、iCourse 授权引导、公开引用 chip）
仍等待 Flutter 来源迁移，不能在本轮标为已修复；真实学校模型/API 复测（`tool_choice`
兼容、自由聊天、跨学期查找、整日移动/清除/撤回、两个本地 chip）仍待用户在真实
校园网 / Panabit iWAN / 真实 API Key 环境下按
`docs/agent-manual-acceptance-retest-2026-08-01.md` 执行；自动测试 ≠ 人工验收。
`docs/agent-testing.md` 与 `docs/agent-manual-acceptance-retest-2026-08-01.md`
是未跟踪用户文件，未修改、未暂存、未提交。

## 7.3 审查修复轮验证（feature/write-tools，2026-08-02）

审查修复里程碑（2026-08-02-agent-manual-acceptance-review-repairs，Tasks 1–5）在
`feature/write-tools` 分支上推进，修正实现审查（handoff
`docs/agent-manual-acceptance-review-handoff-2026-08-02.md`）发现的四类缺陷。完整
自动验证运行在最终 HEAD `bc1a69b`（`test(agent): close review repair regressions`）。
后续若再提交，需重跑本节命令并刷新 HEAD 与测试计数。

提交序列（基线 `d789283` → HEAD `bc1a69b`，共 6 提交）：

```text
8db72b4  fix(agent): ground mutation results on terminal outcomes     Task 1
bdc899c  fix(agent): narrow grounding intent classification           Task 2
debaeb1  fix(agent): bound tool choice compatibility fallback         Task 3
1ad6790  perf(schedule): bound conflict projection to query ranges    Task 4
80b9508  fix(schedule): preserve explicit cross-window conflicts      Task 4 fix wave
bc1a69b  test(agent): close review repair regressions                 Task 5
```

每 Task 均经独立审查（spec compliance + code quality）通过；Task 4 修复波经 scoped
重审通过（补齐 `get_conflicts` 对跨窗口显式冲突的 under-report）。整分支最终独立审查
无 MUST-FIX / Important。

修复内容概要：

- **Task 1 终端写结果权威化**：`agent_session_service.dart` 以结构化 `_TerminalMutationAttempt`
  记录写工具结果，非 success 的 terminal write（`user_declined`/`permission_denied`/
  `target_not_found`/`invalid_write_arguments`/`write_commit_failed`/`cancelled`）覆盖模型
  文本为本地固定“没有修改数据”说明、运行以非 success 结束、不再重试该写工具；成功则
  保留模型完成话术。判断只看 `AgentToolResult.status`，不看模型措辞。
- **Task 2 Grounding 意图精确化**：删除全局否决词 `能不能`/`帮我看看`/`解释`，改为有序
  窄守卫（硬 no-tool → 结构清晰的能力/建议 → 高置信写 → 高置信读 → null）；`move_jw_course_day`
  必须同时有日期语境与集合语义（当天/整日/全部/所有/调休），裸 `课程` 不再是集合标记；
  `plan_task` 必须出现任务实体，删除裸 `给.*安排`；通用“安排日程”归 `create_event`。
  `create_schedule_relation` 采用 `allOfLookupTools` + `anyOfLookupToolGroups`，事件-事件
  关系不强制 `get_plan_blocks`，PlanBlock 关系不强制 `get_schedule`。
- **Task 3 兼容回退限定**：forced-`any` 的回退仅对 `protocol_error` 生效（
  `_isForcedChoiceCompatibilityError`），且要求尚未回退、错误发生在内容前、run 未取消；
  `auth_failed`/限流/传输/服务器/流中断错误保留原错误结束，绝不做 auto 回退，无无限调用。
- **Task 4 冲突投影范围界定**：`watchDisplayEvents()` 只加载 effective events、不再做全局
  O(n²) 投影；周视图与 Agent 工具改为对消费范围内 events + 有效 PlanBlocks 做一次有界投影
  （`conflictsForItems` / `resolveCandidates`：timed overlap 活动窗口 sweep + 显式关系 +
  series 成员，只为可能冲突/被显式覆盖的候选生成 pair，不为无关历史构造 noConflict）；
  `get_free_time` 不触发冲突投影。`get_conflicts`/`get_schedule` 通过
  `includeExplicitOutOfWindow` 保留跨窗口显式冲突（不 under-report），周视图保持仅选中周。
  语义不变：overlap 默认冲突、occurrence no_conflict 覆盖、非重叠显式 conflict 成立、
  series 生效窗口、账号隔离、全天不自动冲突。
- **Task 5 组合回归**：修正 Task-1 遗留的 declined 写测试（改为非 success + “没有修改数据”）；
  新增 5 个贯通场景（礼貌查询漏调一次纠错、失败写+虚假成功不在业务表产生行、forced-any
  auth 错误不回退、单课程移动 vs 整日集合路由、多学期历史只投影当前结果集）。

本轮（最终 HEAD `bc1a69b`）实测完整自动验证（2026-08-02，worktree
`E:/107/.worktrees/write-tools`；Python 用 PowerShell 运行，`PYTHONPATH` 指向
worktree 的 `src`）：

```text
Python unittest discover -s tests -v   : Ran 394 tests, OK
Python compileall -q src tests          : exit 0
Flutter analyze (whole app)             : No issues found
Flutter test (whole suite)              : 824 passed
Flutter build windows --release         : Built build\windows\x64\runner\Release\ustc_assistant_app.exe
git diff --check                        : 干净（仅生成的 Windows 文件 CRLF 提示）
```

Agent / 日程聚焦套件（8 文件组合回归）：

```text
Flutter test
  test/features/agent/agent_grounding_policy_test.dart
  test/features/agent/agent_session_service_test.dart
  test/features/agent/anthropic_llm_provider_test.dart
  test/features/agent/local_agent_tools_test.dart
  test/features/schedule/overlay_conflict_test.dart
  test/features/schedule/schedule_page_test.dart
  test/integration/agent_composition_flow_test.dart
  test/integration/read_only_agent_flow_test.dart : 226 passed
```

安全/配置扫描（Task 5 Step 3）：

```text
rg semesterId/2026spring/2026fall app/lib/features/{agent,schedule} : 无匹配
    （生产代码无硬编码学期；仅 config/source-defaults.json 保持 461 / 2026fall，未改动）
git diff --check   : 干净
git status --short : 仅 3 个受保护 Windows 生成文件 + 4 个未跟踪用户文档
```

**真实人工验收待办（尚未执行）**：真实 Release、学校 Anthropic 兼容 API Key 与
校园网 / Panabit iWAN 下需由主人复测（见 `docs/agent-manual-acceptance-retest-2026-08-01.md`
与计划“Manual Retest Focus”）：

1. “能不能帮我看看明天有什么课？”会真实查询，而“你能不能修改日程？”仍可自由回答；
2. 拒绝确认、权限拒绝、目标消失和本地提交失败时，聊天绝不显示“已完成”；
3. 学校 Anthropic 网关支持与不支持 `tool_choice=any` 的真实行为；
4. 单课程调整与“某天全部教务课程移动”不会互相误路由；
5. 保留多个学期历史后切换周视图，页面响应与冲突图标正常；
6. 原验收文档中仍未通过或空白的项目继续复测；Python 校园目录迁移项（
   `docs/agent-testing.md` 第 13-15 项）不在本轮伪修复，仍等待 Flutter 来源迁移。

自动测试全绿 ≠ 上述人工验收通过。`docs/agent-testing.md` 与
`docs/agent-manual-acceptance-retest-2026-08-01.md` 是未跟踪用户文件，未修改、
未暂存、未提交。

## 7.4 Agent 关系收尾修复轮验证（feature/write-tools，2026-08-02）

关系收尾修复里程碑（2026-08-02-agent-relation-closure-repairs，Tasks 1–8）在
`feature/write-tools` 分支上推进，闭合持久工具调用生命周期（schema 6）、会话/聊天恢复、
有界关系落地与“用户决策即对错”、统一事件与 PlanBlock 关系、混合关系 UI、日程页本地
六秒撤销提示、学期 Task 摘要优先 + 澄清，以及本轮的集成回归 + 复测文档 + 全量验证。

提交序列（基线 `029b794` → HEAD `9950ea1`，Task 1–7）：

```text
4108ca4  feat(agent): persist tool invocation lifecycle            Task 1
3436c6c  feat(agent): restore persistent tool diagnostics          Task 2
0d292c7  fix(agent): bound relation decisions and settlement       Task 3
10b04c1  fix(agent): direction-aware relation mismatch guidance    Task 3 fix wave
9cc4aeb  feat(schedule): unify event and plan block relations      Task 4
c75a385  fix(schedule): restore plan block FK columns on relation undo  Task 4 fix wave
febccdc  feat(schedule): manage mixed overlap relations            Task 5
930e2b0  fix(schedule): scope day move undo feedback               Task 6
9950ea1  fix(agent): prefer summaries for semester workflows       Task 7
```

每 Task 均经独立审查（spec compliance + code quality）通过；Task 4 修复波经 scoped 重审
通过（关系撤销恢复 PlanBlock FK 列）。

Task 8（本轮，收尾）新增组合级回归 + 复测文档 + 全量验证，最终 HEAD 见第 7.4 节末尾
（Task 8 提交后刷新；最后一个代码提交为 `9950ea1`）。

**Task 8 聚焦测试（15 文件完整聚焦套件）**：

```text
Flutter test
  test/core/database/migration_test.dart
  test/features/agent/chat_repository_test.dart
  test/features/agent/agent_grounding_policy_test.dart
  test/features/agent/agent_session_service_test.dart
  test/features/agent/agent_context_builder_test.dart
  test/features/agent/local_agent_tools_test.dart
  test/features/agent/write_tools_test.dart
  test/features/agent/agent_chat_page_test.dart
  test/features/schedule/overlay_conflict_test.dart
  test/features/schedule/event_detail_flow_test.dart
  test/features/schedule/week_timetable_test.dart
  test/features/schedule/schedule_page_test.dart
  test/integration/agent_composition_flow_test.dart
  test/integration/read_only_agent_flow_test.dart
  test/accessibility/milestone_accessibility_test.dart : 440 passed
```

**Task 8 最终完整自动验证**（worktree `E:/107/.worktrees/write-tools`，Python 用
PowerShell 从主仓库根 `E:/107` 运行，conda env `ustc_assistant`，`-s tests` 指向主仓库）：

```text
Python unittest discover -s tests   : Ran 388 tests, OK
Python compileall -q src tests      : exit 0
Flutter analyze (whole app)         : No issues found
Flutter test (whole suite)          : 896 passed
Flutter build windows --release     : Built build\windows\x64\runner\Release\ustc_assistant_app.exe
                                        （app\build\windows\x64\runner\Release\ustc_assistant_app.exe）
git diff --check                    : 干净（仅受保护 Windows 生成文件 CRLF 提示）
```

Task 8 新增组合级回归：

- `agent_composition_flow_test.dart`：持久工具诊断跨“重启”（同一 DB 上新建组合）仍按执行
  顺序恢复，且只含安全摘要（无 DB id、完整账号、`ref_*`、外部作业句柄或密钥）；账号乙
  看不到账号甲的诊断行；账号重置/清除会移除该账号的持久诊断。
- `read_only_agent_flow_test.dart`：整学期“我这学期有什么课”先被过宽 `events` 读取以
  `schedule_summary_required` 拒绝（不先整学期 dump），再以 `course_summary` 成功落地，
  最终回答有数据支撑，出站请求无硬编码学期。
- `milestone_accessibility_test.dart`：混合关系编辑器暴露 pair 标题与关系状态控制语义，
  含 PlanBlock 的 pair 不暴露“优先显示”前景单选。

**Task 8 复测清单**：`docs/agent-relation-closure-retest-2026-08-02.md`（新建，未执行，
`完成：` 留空待主人填写）。它按下述 6 项真实人工验收待办逐项复测：
(1) 2026 春 电路/量子 二选一保存 `no_conflict`；(2) 课程内部 PlanBlock 显式
`no_conflict` 且两者保持可见、警告消失；(3) 六秒本地撤销提示不遮挡聊天、可撤销；
(4) 确认后 Agent 整日移动以成功终态结束、无尾随 `grounding_failed`；(5) 重启后工具诊断
重建且只含安全摘要；(6) 学期 Task 请求先摘要、问未决细节、保留多次 `create_task` 能力。

**真实人工验收待办（尚未执行，等待主人）**：真实 Release、学校 Anthropic 兼容 API Key 与
校园网 / Panabit iWAN 下，按 `docs/agent-relation-closure-retest-2026-08-02.md` 逐项
复测上述 6 项；以及沿用 `docs/agent-manual-acceptance-retest-2026-08-01.md` 中仍未通过
或空白的项目。自动测试全绿 ≠ 人工验收。`docs/agent-manual-acceptance-retest-2026-08-01.md`、
`docs/agent-manual-acceptance-review-handoff-2026-08-02.md`、`docs/agent-testing.md`、
`docs/superpowers/plans/2026-08-02-agent-manual-acceptance-review-repairs.md` 是未跟踪
用户文件，未修改、未暂存、未提交；`docs/agent-relation-closure-retest-2026-08-02.md`
为本里程碑新建的未执行复测清单。

## 8. 已知文档边界

- `docs/acceptance/windows-first-milestone.md` 是第一轮人工结果归档，不是修复后
  的最终验收结论；其中仍有旧的 `461 / 2026fall` 测试文字；
- `docs/acceptance/read-only-agent.md` 是只读 Agent 的人工验收清单，`完成：`留空
  待用户在真实验收后填写；自动测试通过不等于人工验收通过；
- 当前教务默认配置以 `config/source-defaults.json` 为准：
  `461 / 2026fall / 2026 秋季学期`；
- `docs/agent-testing.md` 是未跟踪的用户文件。写工具里程碑（Task 7）未获得用户许可，
  因此**未修改、未暂存、未提交**该文件，完整保留其内容待用户授权后再处理；
- 历史 implementation plan 中的复选框不是实时状态；
- 只读 Agent 修复轮各 Task 在 `feature/read-only-agent` 分支上实现并提交；最终修复后
  的精确 HEAD 在第 7 节最终验证时记录，不在本节硬编码（Task 9 等后续提交会改写哈希）；
- 真实 Key、完整账号、私人课表和原始模型请求不得写入验收文档。

### 只读 Agent 已知限制与后续工作

- 本地导航 chip 可交互，公开引用 chip 仍不可交互：本地日程/任务工具返回数据时会话
  生成去重的 `AgentLocalAction`，聊天页渲染为可点击 `ActionChip`（`查看日程`/
  `查看任务`）经 GoRouter 跳转；公开目录引用（`campus_entry`）仍为不可交互 `Chip`，
  因为临时引用（`ref_*`）到来源 URL 的解析尚未实现（引用真实性通过“不启动伪造 URL”
  保证）。真实解析为合并后工作，不在本里程碑范围。
- 查询网关惰性启动：`LazyQuerySourceGateway` 在首次外部来源工具调用时才启动 Python
  Bridge，启动失败归一化为 `bridge_unavailable` 且可重试；Python Bridge 使用显式数据
  根，不在用户主目录隐式写入。
- 报名中二课同作业恢复：需要登录时返回 `needs_user_login` 暂停运行；用户点击
  “打开登录窗口并继续”后会话对同一作业调用 `resumeLogin`，密码从受保护凭据按账号
  读取，仅传给网关，从不写入工具结果、模型请求或持久日志。
- 学校 API Host 固定为 `https://api.llm.ustc.edu.cn`，不在 App 内提供 Host 配置项；
  篡改的 Host 被拒绝（`protocol_error`，不发请求）。
- 默认学期"单一数据源"尚未统一（load-bearing 缺口，迁移手机版时处理）：当前
  `config/source-defaults.json`（Python 采集与 `/capabilities`、CLI 读它）和
  `SettingsService.defaultJwSemester`（Flutter“恢复默认”按钮值）各持一份字面量。本里程碑
  按“测试性 Windows 实现、Python 最终重写”的定位，仅把两侧默认值手动同步为
  `461 / 2026fall / 2026 秋季学期`，未做 Flutter 从共享 JSON 读取的统一（Flutter
  `pubspec` 不允许 `../` 资源路径，统一机制是为即将重写的 Python 共存期服务的临时投资，
  不划算）。因此计划回归场景 4 的“只改 JSON、不改生产代码即可切学期”目前**不成立**：
  切学期仍需同时改 `SettingsService.defaultJwSemester` 与 `SettingsPage` 文案。迁移
  Android/iOS（Python Bridge 重写、Flutter 成为唯一消费者）时，把默认学期改为 app 内
  可配置资源（或远程下发），届时一并满足场景 4。
- 各 Task 暂缓的 Minor 级别发现等待最终整分支审查分类：Task 2（3 项）、Task 3
  （4 项）、Task 4（9 项）、Task 5（5 项）、Task 6（5 项）、Task 7（5 项）、
  Task 8（3 项）、Task 9（5 项）、Task 10（1 项）、Task 11（7 项）、Task 12
  （3 项）。逐项明细见
  `.superpowers/sdd/2026-07-28-read-only-agent/progress.md`（gitignored，仅本机）。
  最终整分支审查由控制器在 Task 13 之后单独执行，决定哪些必须在合并前修复。
- 真实人工验收（Task 13 Step 7）尚未执行，需用户在真实校园网 / Panabit iWAN /
  真实 API Key 环境下按 `docs/acceptance/read-only-agent.md` 逐项执行。
- 学校 API 与学校网站是人工验收依赖，从不进入自动测试。

## 9. 实施完成后的下一阶段

本轮完成并验收后，再按顺序设计和实现：

- ~~Agent 写工具、风险分级、确认和权限设置~~：已完成（写工具里程碑，见第 0 节）。
- 每日简报、“可以赌”出勤询问和待确认事件（下一阶段第 1 项）；
- 图片/文档输入与 `qwen3.6-chat` 视觉路由；
- Android/iOS 安全存储和查询来源适配器；
- 安装发布和可选云同步。
