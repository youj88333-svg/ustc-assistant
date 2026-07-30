# USTC Assistant 架构

## 目标

`ustc_assistant` Python 包是 Windows App 和后续手机 App 的本地数据源层。
`app/` 是已经实现的共享 Flutter 应用核心。CLI、Windows Bridge 和未来移动端
采集适配器遵守相同的来源契约；CLI 只负责参数、输出和脱敏状态，不承载网站规则。

## 分层

- `common.browser`：专用可见 Edge 持久会话、生命周期和脱敏浏览器错误。
- `common.storage`：UTF-8 JSON 与显式原始文件写入。
- `sources.jw`：课表、考试采集和统一教务导入包。
- `sources.young`：报名中活动和已报名日程两个独立只读来源。
- `sources.icourse`：公开 HTTP、HTML 解析、缓存、匹配与排序。
- `sources.campus`：公开目录索引、本地检索、按 ID 读取详情和附件缓存。
- `bridge`：Windows 临时 loopback 服务、认证回环和可恢复采集作业。
- `cli`：所有采集、查询和读取命令的统一入口。
- `app/lib/features/import`：SourceBundle 解码、语义校验和单事务导入。
- `app/lib/core/database`：账号分区的 Drift/SQLite 本地事实来源。
- `app/lib/features/schedule|calendar|tasks`：共享日程、个人事件、Task 和
  PlanBlock 业务核心。
- `app/lib/features/accounts|sync|reminders`：Windows 账号安全、Bridge 编排和
  平台提醒适配。
- `app/lib/features/agent`：共享只读 Agent 核心（见下文“只读 Agent 架构”）。

来源 service 返回结构化字典和必要的内存原始对象。只有需要导入 Flutter
本地数据库的完整来源快照使用 `SourceBundle`；报名中二课、评课社区、校园目录
查询和详情读取继续使用各自版本化的 `QueryResult` 或 `DetailResult`。

Windows 第一版中，Flutter 不能直接导入 Python 包，因此通过只监听
`127.0.0.1` 的临时 Python Bridge 调用来源能力。Bridge 直接导入
对应的 `ustc_assistant.sources.*` service。JW 与已报名二课日程返回版本化
`SourceBundle`；查询型能力返回各自结构化结果。Bridge 不运行采集 CLI，也不让
Flutter 解析终端文字或中间 JSON 文件。CLI 仅用于开发、调试和独立验收。

迁移到 Android 和 iOS 后，移动端 `SourceGateway` 使用 WebView 登录会话及
移动端 HTTP/页面适配器重新实现采集。移动端适配器仍输出相同的
`SourceBundle`，因此 Flutter 的 `ImportService`、SQLite、用户覆盖层、日程和
Task 逻辑不需要随采集实现重写。Python Bridge 是 Windows 平台适配器，不是
跨平台应用核心。

该 Windows 链路已经实现。Android/iOS 目录目前只有 Flutter 平台脚手架，移动端
`SourceGateway` 仍是后续工作。

## 只读 Agent 架构

只读 Agent 已实现并接入聊天页。Agent 能读取本地日程、Task 和全部查询型来源，通过
可见、可停止的工具调用回答问题，但不能修改本地业务数据、发起账号同步或执行任何外部
写操作。完整设计与范围见
`docs/superpowers/specs/2026-07-28-read-only-agent-design.md`。

### Flutter 共享 Agent 核心

以下代码是平台无关的共享核心，不得依赖 Windows、Python、DPAPI 或 `dart:io`：

- `domain/`：`agent_models.dart`、`agent_tool.dart`、`llm_protocol.dart`、
  `query_source.dart`。定义工具接口、模型协议、查询来源网关接口和引用模型。
- `application/`：`agent_session_service.dart`（有界模型调用/工具调用循环、停止、
  重试、运行状态、摘要调度）、`agent_tool_registry.dart`（工具 Schema 与调用预算
  校验）、`agent_context_builder.dart`（滚动摘要 + 最近消息上下文）、
  `outbound_privacy_filter.dart`（确定性隐私过滤）、`agent_system_prompt.dart`
  （版本化系统规则）、`agent_local_data_gateway.dart`（经 Application Service 读取
  本地业务数据）、`agent_configuration_service.dart`（模型、启用、评课授权、摘要
  位置）、`agent_tools.dart`（15 个只读工具 + 脱敏 payload 构建器）、
  `agent_composition.dart`（组合服务，平台工厂注入）、`cancellation_signal.dart`、
  `run_reference_store.dart`。
- `data/`：`drift_chat_repository.dart`（按账号保存主会话、消息、运行、摘要和脱敏
  工具记录）、`anthropic_llm_provider.dart`（基于 `package:http` 的 SSE 流式
  Provider，无 `dart:io`）、`sse_decoder.dart`。
- `presentation/`：`agent_chat_page.dart`、`agent_tool_run_tile.dart`、
  `safe_markdown_message.dart`、`agent_settings_page.dart`、`agent_setup_panel.dart`。

`AgentComposition.build` 通过注入的 `SecretStoreFactory` 和 `QueryGatewayFactory`
组装全部服务，自身只导入纯 Dart Agent 接口，不持有 `dart:io`、DPAPI 或 Win32 引用。

### Windows 平台适配器

Windows 专属适配器位于 `data/` 层，由 `router.dart` 的 `_AgentChatLoader` /
`_AgentSettingsLoader` 通过工厂注入，不进入共享核心：

- `protected_agent_secret_store.dart` + `WindowsDpapiProtector`：DPAPI 保护 API Key。
- `windows_python_query_gateway.dart` + `BridgeClient` + `PythonLocator`：通过
  `dart:io` 进程启动本机临时 Python Bridge，调用现有 `ustc_assistant.sources.*`
  service 实现按需来源查询。

### Anthropic 端点边界

`AnthropicLlmProvider` 只允许访问 `https://api.llm.ustc.edu.cn`：

- `POST /v1/messages`（SSE 流式）和 `GET /v1/models`。
- 请求头 `anthropic-version: 2023-06-01`，默认模型 `deepseek-v4-flash`。
- SSE 事件含 `tool_use` / `tool_result` 循环。
- API Key 作为每调用的临时局部参数传入，不持久化为字段，不写入日志、异常、数据库或
  网络诊断。篡改的 Host 会被拒绝（`protocol_error`，不发请求）。
- 不忽略 TLS 证书错误，不自动切换到第三方云模型。

### 当前只读工具集（15 个）

本地日程：`get_schedule`、`get_event_details`、`get_free_time`、
`get_pending_event_reviews`、`get_conflicts`。

本地任务：`get_tasks`、`get_task_details`、`get_plan_blocks`、
`get_pending_planblock_reviews`。

本地状态：`get_sync_status`、`get_safe_action_history`。

按需来源（经 Python Bridge Query Protocol 1.0）：
`search_current_second_class_activities`、`search_icourse`、
`search_campus_catalog`、`read_campus_detail`。

工具向模型只返回本轮临时引用（`ref_*`，`Random.secure` 128 位），不返回数据库主键。
单次请求最多 8 轮模型调用、12 次工具调用。结果过大时返回可缩小的条件，不截断冒充
完整结果。

### Python Bridge Query Protocol 1.0

只读 Agent 的按需来源查询复用扩展后的 Windows 临时 Python Bridge，与既有采集作业
分离：

- `POST /queries`：按类型启动查询作业（4 种查询类型）。
- `GET /query-jobs/{id}/events`：轮询作业事件。
- `POST /query-jobs/{id}/resume-login`：恢复需要登录的作业。
- `POST /query-jobs/{id}/cancel`：取消作业。
- `/capabilities` 声明 `queryProtocolVersion: 1.0` 和 4 种查询类型。
- `ReadQueryJobManager` 与既有 `CollectionJob` 分离，独立管理查询作业状态机。
- 每个查询结果经 `validate_query_result` 校验，拒绝未知字段、原始 HTML、无界文本、
  外部 URL 和私有报名字段。公开查询从不接收凭证；密码从不存储在作业上。

### 移动端替换点

未来迁移到 Android/iOS 时保持以下共享核心不变：Chat UI 与 `AgentSessionService`、
`AnthropicLlmProvider` 和 Tool Registry、聊天数据库、上下文、隐私过滤和工具契约、
Flutter 本地日程/Task 工具。移动端只替换：

- `AgentSecretStore`：DPAPI → 平台安全存储（如 `flutter_secure_storage`）。
- `QuerySourceGateway`：`WindowsPythonQueryGateway` → `MobileQuerySourceGateway`
  （WebView 登录会话 + 移动端 HTTP/页面适配器）。
- 登录会话和少量平台生命周期适配器。

### 显式排除（本里程碑）

“只读”表示不修改本地业务事实，也不对学校或外部系统执行写操作。本里程碑不包含：

- 创建、修改或删除 CalendarEvent、Task、PlanBlock、冲突、备注或提醒的写工具；
- `AgentPermissionPolicy` 风险分级与权限设置；
- Agent 发起教务或已报名二课同步；
- 二课报名或取消报名；
- 每日简报和其他主动消息；
- 图片、文件、语音或视觉模型（`qwen3.6-chat` 视觉路由）；
- 多会话、多 Agent 或 MCP 服务端；
- 通用 HTTP、任意 URL、文件、Shell 或 SQL 工具；
- Android/iOS 来源采集实现；
- 云同步。

### 已知限制与后续工作

- 本地导航 chip 可交互，公开引用 chip 仍不可交互：当本地日程/任务工具实际返回数据时，
  会话为每个数据域去重生成一个 `AgentLocalAction`，聊天页渲染为可点击的 `ActionChip`
  （`查看日程`/`查看任务`），经 GoRouter 跳转到对应管理页；公开目录引用
  （`campus_entry`）仍渲染为不可交互的 `Chip`，因为临时引用到来源 URL 的解析尚未实现
  （引用真实性通过“不启动伪造 URL”保证）。真实解析为合并后工作。
- 各 Task 暂缓的 Minor 级别发现等待最终整分支审查分类（见
  `docs/read-only-agent-handoff.md`）。
- 学校 API 与学校网站是人工验收依赖，从不进入自动测试。自动测试（包括组合级集成测试
  `app/test/integration/agent_composition_flow_test.dart`，通过真实路由 + 注入式组合
  覆盖配置、本地日程分组摘要、同作业二课暂停/恢复、账号切换与网关释放）只验证代码
  行为，不代替人工验收。

### 查询网关与二课登录恢复

- 查询网关采用惰性启动：`LazyQuerySourceGateway` 在首次外部来源工具调用时才启动
  Python Bridge，未触发外部查询时不占用进程资源；启动失败按 `bridge_unavailable` 归一
  化为安全错误码，且允许后续重试。Python Bridge 使用显式数据根，不在用户主目录隐式
  写入。
- 报名中二课查询需要登录时返回 `needs_user_login`，运行暂停；用户在聊天页点击
  “打开登录窗口并继续”后，会话对**同一作业**调用 `resumeLogin`（不启动新查询），密码
  从受保护凭据按账号读取，仅传给网关，从不写入工具结果、模型请求或持久日志。恢复后
  运行继续到最终回答。

## 数据流

```text
Windows:
official/public site
  -> Python collector/client
  -> parser/normalizer
  -> source service
  -> local Python Bridge
  -> versioned SourceBundle
  -> Flutter ImportService

Mobile:
official/public site
  -> WebView session + mobile collector
  -> MobileSourceGateway
  -> versioned SourceBundle
  -> Flutter ImportService

Development:
source service -> CLI -> local normalized JSON
```

SourceBundle 1.0 的规范性契约见
`docs/data-sources/source-bundle-v1.md`，机器可读 Schema 位于
`schemas/source-bundle-1.0.schema.json`。一个 Bundle 只对应一个独立同步来源
和一个完整范围，并由 Flutter 在单个事务中导入。

学校来源数据通过本地 `accountId + source + entityType + externalId` upsert。
来源刷新不得覆盖 `UserOverlay` 中的用户备注、出勤、听讲和提醒设置；窗口外记录
也不等于删除。来源 Bundle 不携带本地数据库主键、学号或远端用户身份。

校园公开信息先把目录元数据写入本地索引，Agent 再根据对话意图选择至多 3 个目录 ID 按需读取。详情读取不接受任意 URL；正文发现的后续链接只能按解析器生成的候选 ID 跟进一层。二进制附件只下载和缓存，文档转换属于独立处理层。

## 错误边界

- 页面、接口或计数契约变化时明确失败，不输出不完整快照。
- 浏览器上下文始终关闭。
- 错误消息不包含请求查询参数、响应体或认证值。
- 原始数据默认只驻留内存。
- 远程页面正文和附件内容均是不可信数据，不得改变工具参数、权限或 Agent 策略。

## 时间

日程统一使用 `Asia/Shanghai`。二课滚动窗口和 `collectedAt` 均按北京时间计算。
