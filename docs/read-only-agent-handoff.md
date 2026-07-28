# USTC Assistant 只读 Agent 实施交接

更新时间：2026-07-28

## 1. 交接目标

当前 Windows Flutter 第一版已经基本完善。下一位 Agent 的唯一主要开发目标是执行：

- `docs/superpowers/specs/2026-07-28-read-only-agent-design.md`
- `docs/superpowers/plans/2026-07-28-read-only-agent.md`

本轮只实现只读 Agent，不重新设计需求，不提前实现写工具、每日简报、视觉能力或
移动端来源采集。计划包含 13 个 Task，采用 Subagent-Driven Development 逐项实现、
测试、审查和提交。

Task 1 已在隔离工作区实现并提交，新增了 Agent 数据库表、领域记录和
`DriftChatRepository`。但独立复审发现两项阻断问题，Task 1 当前不能视为验收通过，
下一位 Agent 必须先修复本文件第 3 节列出的问题，再开始 Task 2。Anthropic
Provider、Agent Runtime、只读工具和聊天 UI 仍未实现。

## 2. Git 基线与工作区

关键提交：

```text
46af1f8 docs: plan read-only campus agent
9458486 docs: design read-only campus agent
a62ca27 docs: archive first-round manual acceptance results
325a734 feat: align schedule grid with official periods and add early-morning band
b0a311d fix: auto-submit USTC CAS login after filling credentials
```

当前主工作区基线是本地 `main` 上的 `6212f20` 及本交接文档后续提交。`main` 有大量尚未
推送到 `origin/main` 的提交；开始前运行 `git status --short --branch` 和
`git log -8 --oneline --decorate`，不要拉取、重置或改写本地历史。

主工作区存在以下用户保留状态：

```text
M app/windows/flutter/generated_plugin_registrant.cc
M app/windows/flutter/generated_plugin_registrant.h
M app/windows/flutter/generated_plugins.cmake
```

这些文件当前没有可见内容差异，疑似换行符或文件状态变化。不要还原、暂存或提交。

只读 Agent 已在以下隔离工作区和分支实施：

```text
Worktree: E:/107/.worktrees/read-only-agent
Branch:   feature/read-only-agent
Task 1:   28e351c feat: persist account agent conversations
```

隔离工作区也显示上述三个 Windows Flutter 生成文件为未提交状态，不得还原、暂存
或提交。`.superpowers/sdd/2026-07-28-read-only-agent/` 中有 Task 1 报告、旧审查
和进度 ledger；其中“Task 1 review clean”的结论已经被本次人工复审推翻，不能作为
继续 Task 2 的依据。

`temp.md`、`tmp/`、`.superpowers/`、浏览器 Profile 和本地密钥均被 Git 忽略。
不得把它们加入提交。

## 3. Task 1 当前状态与必修问题

### 已完成部分

提交 `28e351c` 完成了计划 Task 1 的主要文件：

```text
app/lib/core/database/tables/agent_tables.dart
app/lib/core/database/app_database.dart
app/lib/core/database/app_database.g.dart
app/lib/features/agent/domain/agent_models.dart
app/lib/features/agent/data/drift_chat_repository.dart
app/test/core/database/migration_test.dart
app/test/features/agent/chat_repository_test.dart
```

- 数据库版本升至 3，注册并迁移六张 Agent 表；
- 增加账号分区的聊天、Run、工具调用、摘要和加密 Key 元数据结构；
- 增加基本消息追加、草稿更新、Run 完成、摘要替换、清空与异常恢复逻辑；
- Task 1 报告记录聚焦测试 17 项通过。

### 阻断问题

在修复以下两项并补回归测试前，不得开始 Task 2：

1. `DriftChatRepository.recentMessages` 当前按 `ordinal ASC` 后直接 `limit`，返回的
   是最早消息，不是最近消息。资格过滤还发生在 SQL `limit` 之后，会漏掉窗口外的
   有效消息。必须在 SQL 中先筛选可进入上下文的消息，按 `ordinal DESC` 取最近
   `limit` 条，再反转为升序返回。测试必须覆盖消息数量大于 `limit` 且夹有
   failed/cancelled/interrupted 草稿的情况。
2. `chat_messages` 和 `tool_invocations` 只分别外键到 `account_id` 与 `run_id`，
   没有强制两者属于同一账号；`appendMessage` 也不验证 Run 归属。因此账号 A 的
   消息可以引用账号 B 的 Run，清除 B 时还会通过级联误删 A 的消息。应使用
   `(run_id, account_id)` 复合约束，或在同一事务中严格验证 Run 归属，并为消息和
   后续工具记录增加跨账号拒绝测试。

### 同轮修复项

- `finishRun` 应要求账号作用域，只允许从 `running` 转为终态，拒绝
  `state=running` 和重复覆盖终态，避免清空已有 token/error；
- `updateAssistantDraft` 和 `recoverInterrupted` 应同时限定
  `role=assistant`；
- 增加真实 v2→v3 迁移测试，确认六张新表创建且已有代表性业务数据保留；
- 修复 `chat_repository_test.dart` 两处 `await_only_futures`；
- 对本 Task 手写 Dart 文件运行格式化。当前格式检查报告
  `agent_tables.dart`、`drift_chat_repository.dart` 和
  `chat_repository_test.dart` 需要格式化。

修复后应重新运行聚焦测试、`flutter analyze`，更新 SDD ledger，并新增一个独立
修复提交；不要改写或 squash `28e351c`。

## 4. 当前已实现能力

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
- 聊天页目前仍是禁用外壳。

Android/iOS 目录只有 Flutter 平台脚手架。共享本地模型和 ImportService 可复用，
移动端登录、来源采集和安全存储适配尚未实现。

## 5. 已确认的 Agent 范围

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
- 当前外部代理影响校园路由时，用户自行将学校 API Host 配置为直连；
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

## 6. 实施架构

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

## 7. 新 Agent 执行顺序

1. 阅读 `AGENTS.md`，确认项目安全规则和验证命令。
2. 阅读本文件，确认 Task 1 已提交但复审未通过。
3. 完整阅读只读 Agent design。
4. 完整阅读 13 Task implementation plan。
5. 进入现有 `E:/107/.worktrees/read-only-agent`，检查分支和工作区状态；不要再创建
   同名工作树。
6. 先修复本文件第 3 节的 Task 1 问题，补测试、验证并单独提交。
7. 修正 SDD ledger 中旧的“review clean”结论，再使用
   `superpowers:subagent-driven-development` 从 Task 2 继续。
8. 后续每个 Task 使用新实现者和独立审查者，完成聚焦测试、审查和单独提交后，
   才能进入下一 Task。
9. 全部分支完成后运行整分支审查和完整验证。
10. 用户完成人工 API Key、校园网/iWAN 和学校登录验收后，再决定合并回 `main`。

不要在主工作区直接运行 Drift/Flutter 代码生成；这会混入当前保留的生成文件状态。
不要跳过 Task 7 的报名中二课账号 Profile 和交互登录回归，也不要把现有同步
`CollectionJob` 的 SourceBundle 校验放宽来兼容查询结果。

## 8. 验证基线

隔离工作区 SDD ledger 在 Task 1 前记录的完整基线为：

```text
Python unittest: 269 passed
Python compileall: passed
Flutter tests: 207 passed
Flutter analyze: no issues
```

Task 1 报告记录其两个聚焦测试文件共 17 项通过。本次复审尝试独立重跑时，Flutter
SDK 全局锁被另一个进程占用，未获得新的 Flutter 测试结果；直接运行 Dart 静态分析
成功并发现两处 `await_only_futures`，格式检查发现三个手写文件未格式化。修复
Task 1 后必须先得到新的聚焦测试和静态分析证据。

```powershell
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
Push-Location app
E:\flutter\flutter\bin\flutter.bat analyze
E:\flutter\flutter\bin\flutter.bat test
E:\flutter\flutter\bin\flutter.bat build windows --release
Pop-Location
```

学校 API 和学校网站不能进入自动测试。真实验收由用户在可见 Edge、校园网或
Panabit iWAN环境中执行，API Key 只通过 App 设置界面输入。

## 9. 已知文档边界

- `docs/acceptance/windows-first-milestone.md` 是第一轮人工结果归档，不是修复后
  的最终验收结论；其中仍有旧的 `461 / 2026fall` 测试文字；
- 当前教务默认配置以 `config/source-defaults.json` 为准：
  `421 / 2026spring / 2026 春季学期`；
- 历史 implementation plan 中的复选框不是实时状态；
- 只读 Agent plan 的 Task 1 已有提交，但复审未通过；Task 2～13 尚未执行；
- 真实 Key、完整账号、私人课表和原始模型请求不得写入验收文档。

## 10. 实施完成后的下一阶段

本轮完成并验收后，再按顺序设计和实现：

1. Agent 写工具、风险分级、确认和权限设置；
2. 每日简报、“可以赌”出勤询问和待确认事件；
3. 图片/文档输入与 `qwen3.6-chat` 视觉路由；
4. Android/iOS 安全存储和查询来源适配器；
5. 安装发布和可选云同步。
