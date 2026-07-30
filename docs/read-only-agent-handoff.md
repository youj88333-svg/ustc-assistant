# USTC Assistant 只读 Agent 实施交接

更新时间：2026-07-29

## 0. 当前状态（2026-07-30 更新）

只读 Agent 的 Task 1–8 已在 `feature/read-only-agent` 分支上实现、审查并提交；Task 9
及最终整分支审查尚未执行，因此本节不硬编码最终 HEAD 哈希——最终修复后的精确 HEAD 在
最终验证时记录于本文件第 7 节，Task 9 之前任何哈希都会被后续提交改写。完整只读 Agent
已落地：Agent 数据库表、DPAPI 保护 API Key 与配置、Anthropic SSE Provider、隐私过滤
与上下文构建、工具注册表与会话运行时、15 个只读工具（11 本地 + 4 按需来源）、Python
稳定查询 API、Bridge Query Protocol 1.0 查询作业、Flutter 查询网关与 4 个外部工具、
设置 UI、聊天 UI 与组合、端到端安全测试，以及 Task 8 新增的组合级集成测试（真实路由
+ 注入式组合覆盖配置、本地日程分组摘要、同作业二课暂停/恢复、账号切换、网关释放与
捕获请求隐私断言）。

**真实人工验收尚未执行**：下文第 9 节的人工验收清单
（`docs/acceptance/read-only-agent.md`）需由用户在真实校园网 / Panabit iWAN / 真实
API Key 环境下逐项执行。自动测试通过不等于人工验收通过——学校 API 与学校网站从不进入
自动测试，组合级集成测试只验证代码行为。

**最终整分支审查尚未执行**：各 Task 暂缓的 Minor 级别发现等待最终整分支审查分类，
由控制器在最终验证后单独执行，不在本交接范围内。

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

只读 Agent 修复轮（Tasks 1–8）在 `feature/read-only-agent` 分支上推进；最终修复后的
精确 HEAD 在最终验证时记录于此（Task 9 之前不硬编码，因为后续提交会改写哈希）。Task 8
新增的组合级集成测试聚焦命令与结果：

```text
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/integration/agent_composition_flow_test.dart test/integration/read_only_agent_flow_test.dart test/accessibility/milestone_accessibility_test.dart
Pop-Location
```

该聚焦套件全部通过（组合级集成测试 + 既有只读 Agent 流程测试 + 里程碑可访问性测试）。
完整自动验证（Python unittest / compileall / Flutter analyze / Flutter test / Windows
Release build）在最终验证时重新运行并记录于此。自动测试只验证代码行为，不代替人工验收。

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

学校 API 和学校网站不能进入自动测试。真实验收由用户在可见 Edge、校园网或
Panabit iWAN 环境中执行，API Key 只通过 App 设置界面输入。人工验收清单见
`docs/acceptance/read-only-agent.md`。

## 8. 已知文档边界

- `docs/acceptance/windows-first-milestone.md` 是第一轮人工结果归档，不是修复后
  的最终验收结论；其中仍有旧的 `461 / 2026fall` 测试文字；
- `docs/acceptance/read-only-agent.md` 是只读 Agent 的人工验收清单，`完成：`留空
  待用户在真实验收后填写；自动测试通过不等于人工验收通过；
- 当前教务默认配置以 `config/source-defaults.json` 为准：
  `421 / 2026spring / 2026 春季学期`；
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

1. Agent 写工具、风险分级、确认和权限设置；
2. 每日简报、“可以赌”出勤询问和待确认事件；
3. 图片/文档输入与 `qwen3.6-chat` 视觉路由；
4. Android/iOS 安全存储和查询来源适配器；
5. 安装发布和可选云同步。
