# USTC Assistant 只读 Agent 设计

日期：2026-07-28
状态：已确认，待实施

## 1. 目标

在现有 Flutter Windows App 中接入学校大模型公共服务平台，建立一个按学校账号隔离
的长期主会话。Agent 能读取本地日程、Task 和全部现有查询型来源，通过可见、可停止
的工具调用回答问题，但不能修改本地业务数据、发起账号同步或执行任何外部写操作。

本里程碑同时建立可迁移到 Android/iOS 的 Flutter Agent 核心。Windows Python
Bridge 只是当前查询来源适配器，不得进入 Agent 核心契约。

## 2. 已确认范围

### 2.1 包含

- 学校 Anthropic 兼容接口；
- `deepseek-v4-flash` 默认文本模型；
- API Key 手动配置和系统安全存储；
- 每个学校账号一个长期主会话；
- 完整聊天记录本地保存；
- 滚动摘要与最近消息上下文；
- SSE 流式回答；
- Anthropic `tool_use/tool_result` 循环；
- 全部本地和按需联网只读工具；
- 工具过程默认折叠、可展开、可停止；
- 本地来源说明和公开来源引用；
- 账号隔离、数据最小化和确定性隐私过滤；
- Windows Python 查询网关；
- 共享 Flutter Agent 核心及移动端适配接口。

### 2.2 不包含

- 创建、修改或删除 CalendarEvent、Task、PlanBlock、冲突、备注或提醒；
- 启用 `AgentPermissionPolicy`；
- Agent 发起教务或已报名二课同步；
- 二课报名或取消报名；
- 每日简报和其他主动消息；
- 图片、文件、语音或视觉模型；
- 多会话、多 Agent 或 MCP 服务端；
- 通用 HTTP、任意 URL、文件、Shell 或 SQL 工具；
- Android/iOS 来源采集实现；
- 云同步。

“只读”表示不修改本地业务事实，也不对学校或外部系统执行写操作。聊天记录、工具
安全摘要、公开查询缓存和滚动摘要属于本功能自身的技术状态，可以写入本地存储。

## 3. 学校模型服务

### 3.1 接口

```text
Host:          api.llm.ustc.edu.cn
Anthropic:     POST /v1/messages
Model list:    GET /v1/models
Default model: deepseek-v4-flash
Streaming:     SSE
Tool calling:  tool_use / tool_result
```

请求使用学校文档要求的 API Key 鉴权，并携带
`anthropic-version: 2023-06-01`。实现不得在日志、异常、数据库或网络诊断结果中
输出鉴权 Header。

首版固定允许访问 `https://api.llm.ustc.edu.cn`，不允许用户配置任意 API Host。
设置页允许从学校模型列表中选择其他文本模型，但视觉模型与附件协议不在本里程碑
启用。切换到非默认模型时，保存前必须重新执行最小文本与 Tool Calling 测试；
不支持工具的模型不能被设为 Agent 当前模型。

### 3.2 首次启用

1. 显示学校模型服务、校园网/iWAN要求和云端数据范围；
2. 用户手动输入 API Key；
3. Key 立即交给当前平台的 `AgentSecretStore`；
4. 获取当前 Key 可用的模型列表；
5. 对选中模型执行不含个人数据的最小文本测试；
6. 使用本地虚拟工具执行一次最小 Tool Calling 测试；
7. 两项通过后启用聊天输入。

测试请求不进入主会话。`deepseek-v4-flash` 是已知支持 Tool Calling 的默认模型；
能力测试用于发现 Key 权限、学校网关协议或配置变化。

### 3.3 网络

- 校内校园网直接访问学校 API；
- 校外由用户自行启动 Panabit iWAN；
- App 不启动、配置或管理系统代理、TUN 或 iWAN；
- 现有全局代理影响校园网路由时，由用户将学校 API Host 配置为直连；
- `127.0.0.1` 和 `localhost` 始终作为本地 Bridge 地址，不经过外部代理；
- 不忽略 TLS 证书错误；
- 不自动切换到其他学校模型或第三方云服务。

设置页提供最小连接诊断，不读取代理配置。错误必须区分：

```text
network_unreachable
campus_network_required
authentication_failed
model_not_allowed
rate_limited
service_unavailable
protocol_mismatch
stream_interrupted
cancelled
```

尚未收到任何响应的临时网络错误及 `429/5xx` 最多自动重试两次，并使用短退避。
一旦已经显示文本或执行工具，不自动重放整轮请求，由用户明确点击重试。

## 4. 架构

```text
Chat UI
  -> AgentSessionService
       -> LlmProvider
       -> AgentToolRegistry
       -> ChatRepository
       -> AgentSecretStore
       -> LocalDataGateway
       -> QuerySourceGateway
```

### 4.1 Flutter 共享核心

`LlmProvider`
: 统一模型请求、流式事件、用量和工具内容块接口。首版实现
  `AnthropicLlmProvider`。

`AgentSessionService`
: 负责上下文组装、流式响应、工具循环、停止、重试、运行状态和摘要调度。

`AgentToolRegistry`
: 注册工具 Schema，验证名称、参数、调用预算和结果大小。模型不能动态增加工具。

`ChatRepository`
: 按学校账号保存主会话、消息、运行、滚动摘要和脱敏工具记录。

`AgentSecretStore`
: 按学校账号保存 API Key。Windows 使用 DPAPI；Android/iOS 后续使用各自系统
  安全存储。

`LocalDataGateway`
: 通过现有 Flutter Application Service 读取本地业务数据，不直接向 Agent 暴露
  Drift 表。

`QuerySourceGateway`
: 报名中二课、评课社区和校园公开信息的稳定跨平台查询接口。

### 4.2 平台适配

Windows 首版使用 `WindowsPythonQueryGateway` 扩展本机临时 Python Bridge，调用
现有 `ustc_assistant.sources.*` service。未来移动端实现
`MobileQuerySourceGateway`，但必须保持相同的工具语义和版本化结果。

以下代码不得依赖 Windows、Python、DPAPI 或 `dart:io` 平台细节：

- Chat UI 的业务状态；
- `AgentSessionService`；
- Anthropic 消息与工具内容块模型；
- Tool Registry 和工具 Schema；
- 上下文、隐私和引用策略；
- Drift 聊天 Repository；
- 本地业务工具。

移动端迁移只替换安全存储、查询来源、网络生命周期和少量平台 UI 适配器。

## 5. 主会话与本地数据

每个本地学校账号只有一个长期主会话。切换账号后，API Key、聊天、摘要、运行和
工具记录全部切换到对应分区。

新增以下本地表：

```text
agent_settings
chat_messages
agent_runs
tool_invocations
conversation_summaries
```

`agent_settings`
: 模型、启用状态、评课授权、系统规则版本和当前摘要位置。不得保存 API Key。

`chat_messages`
: 用户/助手角色、正文、状态、请求关联和北京时间。

`agent_runs`
: 一次 Agent 运行的 `running/completed/failed/cancelled/interrupted` 状态、错误码和
  用量摘要。

`tool_invocations`
: 工具名、脱敏参数摘要、状态、数量摘要和耗时。不保存完整工具结果。

`conversation_summaries`
: 滚动摘要、覆盖到的消息位置、生成模型和时间。

完整聊天记录永久保存在本地，直到用户清除当前账号聊天或执行完全重置。清除聊天
不影响日程、Task 或 API Key。完全重置必须清除 Key、聊天、摘要、授权和 Agent
设置。

每次 Agent 运行结束后，还要向现有 `ActionLog` 写入一条聚合安全摘要，供操作历史
统一查看。逐个工具的技术细节保存在 `tool_invocations`，避免操作历史被大量工具步骤
淹没。两处都不得包含用户问题正文、工具原始结果或敏感参数。

## 6. 上下文管理

每次模型请求由以下内容组成：

```text
版本化系统规则
+ 当前账号滚动摘要
+ 最近完整对话轮次
+ 当前用户消息
+ 本轮按需工具结果
```

- 完整历史不重复发送到云端；
- 上下文接近应用配置的保守预算时压缩最早的完整轮次；
- 摘要只记录对话结论、用户偏好和未完成话题；
- 摘要不得复制整段课表、通知正文或评课正文；
- 日程、Task、同步状态和权限等事实必须重新调用工具；
- 摘要不能覆盖本地业务事实；
- 摘要生成禁用工具，使用低随机性和受限输出长度；
- 摘要失败时退回更短的最近消息窗口，不阻塞聊天；
- 用户可以查看和清除摘要，清除摘要不删除完整聊天；
- 已失败、已停止或已中断的助手草稿默认不作为完整回答发送到后续上下文。

流式回答先作为草稿展示并定期持久化。完成后标记 `completed`。App 异常退出后，
下次启动将未终止运行标记为 `interrupted`，保留用户已经看到的部分正文。

## 7. 工具

### 7.1 本地日程

```text
get_schedule
get_event_details
get_free_time
get_pending_event_reviews
get_conflicts
```

工具读取有效事件投影，包含当前问题所需的标题、北京时间、地点、冲突状态、
出勤/听讲设置和用户备注。未指定范围时默认今天起七天；单次查询范围不得超过
31 天。模型使用本轮临时引用继续读取详情，不能获得数据库主键。

### 7.2 本地 Task

```text
get_tasks
get_task_details
get_plan_blocks
get_pending_planblock_reviews
```

结果包含必要的标题、截止时间、持久状态、派生截止/规划状态、预计工时和相关
PlanBlock。不得将 Task 摘要或 PlanBlock 时长误写成完成百分比或实际执行时间。

### 7.3 本地状态

```text
get_sync_status
get_safe_action_history
```

同步状态返回来源、最近成功/失败时间、数据范围和脱敏错误码。Agent 只能建议用户
前往同步页，不能启动同步。操作历史只返回已有 `safeSummary` 及必要分类。

### 7.4 按需来源

```text
search_current_second_class_activities
search_icourse
search_campus_catalog
read_campus_detail
```

约束：

- 二课报名和取消报名永远由用户在官方页面执行；
- 报名中二课需要登录且当前会话不可用时，工具返回 `needs_user_login`；UI 提供
  用户明确触发的“打开登录窗口并继续”，模型不能接收密码或验证码；
- 评课社区首次联网前告知会发送必要课程名称，并按账号记录可撤销授权；
- 评课查询只发送课程名称及必要教师条件，不发送课表时间、地点或用户身份；
- 校园信息先查本地目录，再按目录条目临时引用读取详情；
- 校园详情每批最多三条，最多跟进一层解析器发现的候选链接；
- 不接受用户或模型传入任意 URL；
- 二进制附件仍由受控下载和独立转换层处理，不在本里程碑直接发送给模型。

### 7.5 预算和临时引用

- 一次用户请求最多八轮模型调用；
- 一次用户请求最多十二次工具调用；
- 工具限制返回条数和文本长度；
- 结果过大时返回可缩小的条件，而不是截断后冒充完整结果；
- 临时引用只在当前 Agent 运行内有效；
- 达到预算后停止，并要求用户缩小问题；
- 用户停止后不得启动新的模型请求或工具调用；
- 已完成的公开查询缓存可以保留。

## 8. 数据最小化与安全

允许按当前问题发送的规范化字段：

```text
事件：标题、北京时间、地点、用户备注、出勤/听讲设置、冲突状态
Task：标题、截止时间、状态、预计用时、必要 PlanBlock
校园信息：公开标题、日期、必要正文片段和来源
评课信息：公开结构化评分、网站总结和代表性点评
```

始终排除：

```text
API Key、密码、Cookie、Token、验证码
完整学校账号、用户本人姓名和远端个人身份
内部数据库主键和教务上下文 ID
浏览器 Profile 路径
原始网页响应、请求 Header 和异常堆栈
与当前问题无关的完整个人课表原文
```

隐私过滤由本地确定性代码执行，不能只依赖系统提示。用户在聊天中粘贴疑似密钥
时，本轮拒绝发送并提示移除敏感内容。首次启用明确告知用户：其输入和回答问题所需
的最小化数据会发送到学校模型服务。

系统规则固定并版本化。校园通知、评课、二课描述、附件和所有工具结果均是不可信
数据，不能改变工具白名单、调用上限、隐私规则或系统指令。

Agent 不获得：

```text
通用 HTTP
任意 URL
本地文件
Shell
SQL
同步
写业务数据
外部提交
```

模型请求不存在的工具时返回 `tool_not_allowed`。可疑参数、超限、协议错误或停止
请求立即终止当前运行，不影响本地业务数据。

模型输出使用受限 Markdown，不渲染原始 HTML 或脚本。公开链接只有在其 URL
实际来自工具结果时才可点击；模型自行生成的链接显示为未验证文本。

## 9. 引用

- 本地答案标注数据类别和最近同步时间，不显示内部 ID；
- 校园通知、指南和评课答案附实际工具返回的公开来源链接；
- 引用在本轮运行内以临时引用绑定，最终回答只能引用已读取结果；
- 证据不足时明确说明，可以在剩余预算内继续读取下一批候选；
- 不允许模型编造来源标题、URL、日期或本地同步状态。

## 10. Agent 行为

- 默认使用中文，优先简洁回答；
- “今天、明天、本周”统一按 `Asia/Shanghai` 解析；
- 容易混淆时显示具体日期；
- 日程回答同时考虑课程、考试、二课、个人事件、Task 和 PlanBlock；
- 时间重叠不自动等于冲突；
- 冲突解释读取当前冲突状态、出勤/听讲设置和备注；
- 对“可以赌”“不听讲”、翘课和娱乐安排保持中性，只说明已有风险与后果；
- 本地数据过旧时显示最近同步时间并建议用户前往同步页；
- 公共信息显示发布日期、读取时间和来源；
- 证据不足时明确说明不知道；
- 可以提出下一步查询建议，但不能未经用户消息主动发言；
- 不声称已经修改、报名、同步或完成任何事项；
- 首版不允许自定义系统提示，未来风格偏好不得削弱安全层。

## 11. UI

聊天页沿用现有首屏、侧边栏和“聊天/日程”底部导航。

状态：

```text
unconfigured  未配置 Key，输入框禁用
ready         可输入和发送
running       流式回答，发送按钮变为停止按钮
failed        显示脱敏错误和重试
cancelled     保留部分回答并标记已停止
interrupted   保留部分回答并标记已中断
```

工具过程默认折叠：

- 已完成时显示“已读取 N 项信息”和类别摘要；
- 运行时显示当前阶段和进度；
- 点击后显示脱敏步骤、数量和耗时；
- 不默认展开；
- 不显示数据库 ID、原始参数或原始响应。

首版支持复制单条回答、重新生成最后一次回答和回到最新消息。不支持编辑历史消息、
分叉会话、附件、语音或视觉输入。

设置新增“模型服务”：

- 配置、替换、删除和测试 API Key；
- 获取并选择学校可用文本模型；
- 显示最近连接测试时间和脱敏结果；
- 显示云端发送字段范围；
- 管理评课社区联网授权；
- 查看/清除滚动摘要；
- 清除当前账号聊天记录。

不向普通用户显示 temperature、max token 或系统提示。首版使用版本化的应用默认
参数，以低随机性优先保证工具选择和事实回答稳定。

## 12. 错误、停止与恢复

- 工具错误只向模型返回固定错误码和安全摘要；
- 不向模型发送异常堆栈、请求头或原始响应；
- 停止信号传递到当前 SSE、Agent 循环和可取消工具；
- 已完成工具的只读结果和公开缓存无需回滚；
- 网络中断保留用户消息和已显示草稿；
- “重试”从原用户消息创建新的 `agent_run`，不覆盖故障记录；
- Key 失效时禁用发送并引导重新配置；
- 学校 API 不可达时提示检查校园网或 iWAN，不擅自诊断或修改系统代理；
- Python 查询网关不可用时只影响对应按需来源，本地日程和 Task 问答仍可继续。

## 13. 测试

自动测试不得连接学校模型服务，必须使用本地假 Provider、捕获 HTTP 客户端和假
Bridge。

### 13.1 自动测试

- Anthropic 普通文本、SSE、Tool Calling、多工具循环和错误事件；
- 取消、限流、重试、流中断和协议不兼容；
- 账号隔离、滚动摘要、最近消息选择、重启恢复；
- Key、完整学号、Cookie、Token、内部 ID 和原始响应不进入模型请求或日志；
- 工具 Schema、范围、数量、临时引用和调用预算；
- 任意 URL、SQL、路径、Shell 和未注册工具被拒绝；
- 本地业务工具只经 Application Service/Gateway 读取；
- Python 查询网关版本化契约与安全错误；
- 首次评课授权和撤销；
- Prompt injection 文本不能改变工具和安全策略；
- 首次配置、流式消息、默认折叠工具条、停止、重试和引用 UI；
- Windows 宽屏及两种手机尺寸 Golden；
- 共享 Agent 核心不依赖 Windows、Python 或 DPAPI 具体实现。

### 13.2 人工验收

1. 校内校园网直接调用；
2. 校外开启 Panabit iWAN 后调用；
3. 当前外部代理与 iWAN 同时开启，学校 API Host 配置直连；
4. 使用真实 Key 完成文本与虚拟工具测试；
5. 连续查询日程、Task、二课报名中活动、评课和校园通知；
6. 中途停止一次多工具运行并正常重试；
7. 重启 App 后恢复主会话和摘要；
8. 切换学校账号后确认 Key、聊天和工具记录不串号；
9. 检查日志和本地数据库，不含 Key、完整学号或工具原始响应。

## 14. 完成标准

- 全部只读工具通过统一 Agent Runtime 可用；
- 学校 Anthropic API 的文本、SSE 和 Tool Calling 真实验收通过；
- 本地消息、摘要、Key 和工具记录按账号隔离；
- 隐私、工具预算、Prompt injection 和错误恢复测试通过；
- Windows UI 可用，手机尺寸测试通过；
- 写工具、同步、每日简报和视觉能力仍不可调用；
- 现有日程、Task、来源采集和 SourceBundle 行为不回归。

## 15. 后续顺序

1. Agent 写工具、风险分级、确认和权限设置；
2. 每日简报、“可以赌”出勤询问和待确认事件；
3. 图片/文档输入与 `qwen3.6-chat` 视觉路由；
4. Android/iOS 安全存储和查询来源适配器；
5. 安装发布和可选云同步。
