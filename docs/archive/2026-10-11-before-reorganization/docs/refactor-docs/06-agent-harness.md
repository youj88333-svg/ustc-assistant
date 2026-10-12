# agent/harness 技术文档

> 模块编号：06 ｜ 产出日期：2026-08-12 ｜ 覆盖分支：main ｜ 探索者：subagent-06

## 1. 职责边界

本模块是「校园学习生活助手」的 Agent 全部能力：聊天推理循环、工具系统（只读 + 写 + 生命周期 + 管理）、上下文构建与滚动摘要、权限审批门、隐私过滤、持久化（会话/消息/运行/工具调用/摘要/密钥/策略）、对外部学校数据源的查询（经 Python Bridge）、Windows 平台适配（DPAPI 密钥保护、Bridge 查询网关）。

**做什么**（全部路径经 grep/glob 验证，目录为 `app/lib/features/agent/`）：

- 六子结构完整映射：上下文管理、工具系统、执行编排、状态与记忆、评估与观测、约束与恢复（详见第 2 节）。
- 接入学校 Anthropic 兼容模型服务：`AnthropicLlmProvider` 固定网关 `https://api.llm.ustc.edu.cn`（`app/lib/features/agent/data/anthropic_llm_provider.dart:38`），默认模型 `deepseek-v4-flash`（`app/lib/features/agent/application/agent_configuration_service.dart:38`），SSE 流式 + tool_use/tool_result 协议。
- 按学校账号隔离：所有表以 `accountId` 为键，运行/消息/工具调用归属校验（`RunOwnershipException`，`app/lib/features/agent/domain/agent_models.dart:172`）。

**不做什么**：

- 不实现 Bridge 服务端（Query Protocol 1.0 服务端在 Python 侧 `src/ustc_assistant/bridge/`，本模块只消费，见第 4 节）。
- 不做数据同步/抓取（属 sync 模块）；只通过只读工具 `get_sync_status` 读取同步状态。
- 不做日历/任务/日程领域的业务服务；通过网关接口（`AgentWriteGateway`、`AgentLocalDataGateway`）调用其他模块的 Application Service。
- 不做账号认证存储；通过 `AccountService.passwordForInteractiveLogin` 恢复二课登录（`app/lib/features/agent/application/agent_composition.dart:216-231`）。

**依赖谁（上游）**：`app/lib/core/database/app_database.dart`（Drift 表与 `actionLogsRepository`）、`app/lib/core/time/beijing_clock.dart`、`app/lib/core/security/credential_protector.dart`（DPAPI 保护器）、`app/lib/features/accounts/`（账号）、`app/lib/features/calendar/`、`app/lib/features/tasks/`、`app/lib/features/schedule/`、`app/lib/features/reminders/`（写网关/本地数据网关的后端服务）、`app/lib/features/sync/data/bridge_client.dart`（Bridge 进程与 HTTP 客户端）、`app/lib/features/settings/`（pythonPath 设置）。

**被谁依赖（下游）**：`app/lib/app/router.dart` 的 `_AgentChatLoader` 与 `_AgentSettingsLoader`（页面装配，见第 7 节）；无其他 feature 消费本模块。

**范围事实**：本模块共 46 个 Dart 源文件（domain 8、application 23、data 8、presentation 7），约 21.5k 行；测试目录 `app/test/features/agent/` 共 29 个测试文件（已 glob 验证）。

## 2. 现状·核心组件

目录树（仅本模块，46 个文件）：

```
app/lib/features/agent/
├── domain/                    # 纯 Dart 领域类型（不依赖 Drift/IO，供共享核心导入）
│   ├── agent_models.dart      # 运行/消息/工具调用/摘要记录模型 + RunOwnershipException
│   ├── agent_tool.dart        # AgentTool 接口、AgentToolContext、结果/引用/视图状态
│   ├── agent_permission_policy.dart  # ConfirmationMode/RiskLevel/策略记录模型
│   ├── agent_write_gateway.dart      # 写网关接口（包装日历/任务等 Application Service）
│   ├── agent_write_proposal.dart     # 写提案（propose 产出，commitParams 不出领域层）
│   ├── agent_write_unit_of_work.dart # 原子写事务接口
│   ├── llm_protocol.dart      # LlmProvider 接口、LlmRequest/LlmEvent/LlmMessage
│   └── query_source.dart      # SourceQuery/QueryResultEnvelope/QuerySourceGateway
├── application/               # 平台无关共享核心（除 composition 外均无 dart:io）
│   ├── agent_session_service.dart    # 执行编排：有界推理循环（8×12）
│   ├── agent_context_builder.dart    # 上下文组装 + token 预算 + 滚动摘要决策
│   ├── agent_system_prompt.dart      # 版本化系统提示词 v8
│   ├── agent_grounding_policy.dart   # 显式操作分类器（读写意图 + 纠错要求）
│   ├── agent_tool_budget.dart        # 工具预算（12 普通 + 32 突发）+ CreateTaskBurstLease
│   ├── agent_tool_registry.dart      # 工具注册/分发/净化边界
│   ├── agent_tools.dart              # 15 个只读工具 + payload builders + 装配工厂
│   ├── agent_management_tools.dart   # 4 个管理只读工具（关系/提醒/标注/撤回预览）
│   ├── agent_write_tool.dart         # 写工具基类：审批门 + WriteConfirmationStore + 原子提交
│   ├── agent_write_tools.dart        # 11 个写工具（create_event 等）
│   ├── agent_lifecycle_tools.dart    # 9 个生命周期写工具 + guardCommit/mapLifecycleError
│   ├── agent_composition.dart        # 组装根：AgentComposition.build + LazyQuerySourceGateway
│   ├── agent_configuration_service.dart   # 设置（模型/启用/icourse 同意）增删改查
│   ├── agent_local_data_gateway.dart # 本地数据网关接口 + Drift 实现
│   ├── agent_mutation_ledger.dart    # 生命周期写结果顺序聚合（成功/拒绝/失败/未处理）
│   ├── agent_permission_policy_service.dart # 动作注册表 + 策略决议/审计/变更
│   ├── agent_tool_invocation_summary.dart   # 安全参数/结果摘要（唯一落库来源）
│   ├── assistant_text_filter.dart    # 流式文本过滤（时间戳前缀/ref_ 令牌）
│   ├── cancellation_signal.dart      # 取消原语（广播流 + isCancelled）
│   ├── outbound_privacy_filter.dart  # 出站隐私过滤（用户文本 + 工具 payload allowlist）
│   ├── run_reference_store.dart      # run 内 ref_* 绑定/解析
│   ├── tool_call_fingerprint.dart    # 工具调用指纹（防重复调用）
│   └── write_argument_reader.dart    # 写参数严格校验（白名单 + 类型）
├── data/                      # 持久化 + 平台适配
│   ├── drift_chat_repository.dart    # 会话/消息/运行/调用/摘要 Drift 落库 + 启动恢复
│   ├── drift_agent_write_gateway.dart # 写网关 Drift 实现（NoopUndoRecorder）
│   ├── drift_agent_write_unit_of_work.dart # 原子写事务（Drift.transaction 包装）
│   ├── protected_agent_secret_store.dart   # [Windows 适配] DPAPI 密钥存储
│   ├── windows_python_query_gateway.dart   # [Windows 适配] Bridge 查询网关（轮询）
│   ├── anthropic_llm_provider.dart  # LLM 网关客户端（SSE + 重试 + 探针）
│   └── sse_decoder.dart             # SSE 解码器（跨 chunk UTF-8/行缓冲）
└── presentation/             # Flutter UI
    ├── agent_chat_page.dart            # 聊天页（会话状态机 + 确认卡 + 登录恢复）
    ├── agent_settings_page.dart        # Agent 设置页
    ├── agent_setup_panel.dart          # 首次配置面板（API Key + 双探针）
    ├── agent_permission_section.dart   # 权限策略设置分区
    ├── agent_write_confirmation_card.dart # 写确认卡（预览 + 风险 + 四个动作）
    ├── agent_tool_run_tile.dart        # 工具运行折叠条（展开显示安全摘要）
    └── safe_markdown_message.dart      # 安全 Markdown 渲染（链接不可点 + 本地导航 chip）
```

### 六子结构映射（关键论断带证据）

**1. 上下文管理**

- `AgentContextBuilder`（`app/lib/features/agent/application/agent_context_builder.dart`）：组装单轮请求 = 滚动摘要（以「不可信上下文」框架注入，:82-91）+ 最近消息（按 token 预算从旧到新裁剪，:303-322）+ 当前消息；token 预算：输入上限 28,000（:31）、摘要触发阈值 18,000（:35）、摘要输出上限 1,024（:47）；估算以真实 provider inputTokens 优先、字符数兜底（:218-237）。
- `AgentSystemPrompt`（`app/lib/features/agent/application/agent_system_prompt.dart`）：固定版本化文本，当前 **version 8**（:57）；v1-v8 逐版本拼接保留（v8 追加生命周期写工具规则，:66-74）；动态时间后缀由 context builder 追加（`agent_context_builder.dart:373-376`），版本号落 `agent_settings.system_prompt_version`（:55-56）。
- 消息可见性规则：`DriftChatRepository.recentMessages` 只返回已完成用户消息与完成/流式/带文本的 interrupted 助手消息（`app/lib/features/agent/data/drift_chat_repository.dart:193-227`）。

**2. 工具系统**

- 注册与 Schema：`AgentToolRegistry`（`app/lib/features/agent/application/agent_tool_registry.dart:22-110`）持有注入的工具集合，向模型暴露 `LlmToolDeclaration`（:32-44），按名分发；未注册工具返回 `tool_not_allowed`（:69-74），任意抛异常兜底 `tool_execution_failed`（:79-85）；执行后经 `OutboundPrivacyFilter.sanitizeToolPayload` 净化（:88-109）。
- 工具清单全量（39 个，全部经 grep 验证）：
  - 本地只读 15：`get_schedule`、`get_event_details`、`get_free_time`、`get_pending_event_reviews`、`get_conflicts`、`get_tasks`、`get_task_details`、`get_plan_blocks`、`get_pending_planblock_reviews`、`get_sync_status`、`get_safe_action_history`（`agent_tools.dart:2673-2689`）+ `get_schedule_relations`、`get_reminders`、`get_user_overlay`、`get_last_undoable_action`（`agent_management_tools.dart:62-568`）。
  - 外部只读 4：`search_current_second_class_activities`、`search_icourse`、`search_campus_catalog`、`read_campus_detail`（`agent_tools.dart:3430-3441`）。
  - 写工具 11：`create_event`、`create_task`、`plan_task`、`update_event`、`create_user_overlay`、`record_attendance_decision`、`record_listening_mode`、`create_schedule_relation`、`set_reminder`、`move_jw_course_day`、`update_permission_policy`（`agent_write_tools.dart:169-1883`）。
  - 生命周期写 9：`update_task`、`update_plan_block`、`delete_schedule_relation`、`clear_reminder`、`clear_user_overlay`、`unlink_task_event`、`reset_permission_policy`、`undo_last_action`（`agent_lifecycle_tools.dart:182-1179`）。
  - 备注：main 分支上写工具齐全（11 + 9），AGENTS.md 中「feature/write-tools 分支未合并」仅是线索，与代码不符——以代码为准。
- 预算：`AgentRunToolBudget`（`app/lib/features/agent/application/agent_tool_budget.dart:35-135`）——普通轮次限额 **12**（:37），create-task 突发单轮上限 **32**（:40，与系统提示词 v7 的「单次最多 32 个」一致，`agent_system_prompt.dart:88`）；突发额度每 run 只授予一次且不占普通额度（:91-101）；整轮预检 `preflightTurn` 拒绝即整轮副作用为零（:69-123）。
- 参数校验：`WriteArgumentReader`（`app/lib/features/agent/application/write_argument_reader.dart:6-93`）——白名单键 + 严格类型，全部失败抛 `FormatException` 由基类映射 `invalid_write_arguments`。
- 参数/结果摘要：`summarizeToolArguments`/`summarizeToolResult`（`app/lib/features/agent/application/agent_tool_invocation_summary.dart:26-54`）是 `safe_arguments_summary`/`safe_result_summary` 两列的唯一允许来源，只保留日期与安全枚举。

**3. 执行编排**

- `AgentSessionService`（`app/lib/features/agent/application/agent_session_service.dart:111`）：单 run 有界循环。硬限制：**8 次模型调用**（:144 `maxModelCalls = 8`）+ 12 次普通工具调用；两处均有测试锚定（`app/test/features/agent/agent_session_service_test.dart:1472`「8 model calls is a hard limit」、:1503「12 tool calls is a hard limit」）。
- 循环步骤（:505-1573）：隐私检查（:515-527）→ 落库 run + 取历史 + 落库用户消息（:535-552）→ grounding 分类（:566）→ 超限预检 `estimateTurnTokens`（:593-616）→ 首请求构建（:621-631）→ 循环：模型调用（:754-800）→ SSE 事件分发（:802-834）→ 无工具回合结算 `_settleNoToolUse`（:872-973）→ 工具回合逐工具执行（:1057-1487）→ 终态落库 + ActionLog + 摘要调度（:1513-1572）。
- 停止与取消：`CancellationSignal`（`app/lib/features/agent/application/cancellation_signal.dart:13-37`）；取消语义=放行在途流但不再发起新模型调用（`agent_session_service.dart:108-110, 749-752`）；工具回合取消为未执行块补记 `cancelled` 生命周期行（:1065-1101）。
- 重试：LLM 层 `_maxRetries = 2`（`anthropic_llm_provider.dart:42`），指数退避 250ms×2^n（:547-550），一旦发出任何文本/工具事件即禁止重试（:163-165, :186-208）；会话层 `retryLast` 复用最近完成的用户消息开新 run（`agent_session_service.dart:238-316`）。
- SSE 解码：`SseDecoder`（`app/lib/features/agent/data/sse_decoder.dart:32-214`）处理跨 chunk 的 UTF-8 与行缓冲；provider 侧按 content_block 重组 `input_json_delta` 碎片为 `ToolUseCompletedEvent`（`anthropic_llm_provider.dart:260-445`），`message_stop` 才是流完成信号（:435-437）。
- grounding 策略：`AgentGroundingPolicy`（`app/lib/features/agent/application/agent_grounding_policy.dart:109-245`）——先硬性自由聊天/能力咨询模式白名单（:120-127），再写意图（:132-136）后读意图（:139-145）；产出 `AgentGroundingRequirement`（lookup/terminal/supporting 工具、EITHER/OR 查询组、期望冲突状态、create-task 突发上限，:23-97）。纠错：单次强制 `tool_choice=any` 校正（`agent_session_service.dart:914-929`），`protocol_error` 兼容失败降级 `auto` 重试一次（:853-864, :1950-1951）；失败确定性替换模型文本（`_groundingFailedText`，:1956）。
- 工具调用指纹：`ToolCallFingerprint`（`app/lib/features/agent/application/tool_call_fingerprint.dart:15-52`）——规范排序 JSON，run 内完全重复调用返回 `repeated_tool_call` 不二次执行（`agent_session_service.dart:1163-1185`）。

**4. 状态与记忆**

- 表（`app/lib/core/database/tables/agent_tables.dart`）：`agent_settings`（:5）、`agent_secrets`（:24）、`agent_runs`（:41，复合 UNIQUE(id, account_id) :65-67）、`chat_messages`（:70，UNIQUE(account_id, ordinal) :93-95，复合 FK :98-101）、`tool_invocations`（:104，复合 FK :130-133）、`conversation_summaries`（:136，UNIQUE(account_id) :152-154）；另 `agent_permission_policies`（`app/lib/core/database/tables/operation_tables.dart:26-53`，UNIQUE(account_id, actionType, targetType) :50-52）与 `action_logs`（`operation_tables.dart:5-24`）。
- 落库：`DriftChatRepository`（`app/lib/features/agent/data/drift_chat_repository.dart:13-533`）——事务内分配 ordinal（:56-82）、`finishRun` 幂等终态（:138-181）、`recoverInterrupted` 启动恢复（:469-510，running 运行→interrupted、非终态工具调用→interrupted）、`clearConversation` FK 安全删除（:271-288）。
- 密钥：`ProtectedAgentSecretStore`（`app/lib/features/agent/data/protected_agent_secret_store.dart:27-101`）——API Key 只以 `CredentialProtector.protect` 密文落库，读后零化临时缓冲区（:82-88）；Windows 实现 `WindowsDpapiProtector`（注入于 `app/lib/app/router.dart:739-742`）。
- 账号隔离：`RunOwnershipException`（`agent_models.dart:172-184`）+ 复合 FK 双层防护；会话服务活跃运行按 account 唯一（`agent_session_service.dart:152, 182-192`）。
- 运行引用：`RunReferenceStore`（`app/lib/features/agent/application/run_reference_store.dart:19-110`）——run 内 `ref_*` 绑定/解析，跨 run 与跨 kind 均不可解析（:57-63），128 位随机后缀（:99-109）。

**5. 评估与观测**

- 隐私过滤：`OutboundPrivacyFilter`（`app/lib/features/agent/application/outbound_privacy_filter.dart:36-307`）——用户文本前置检查（完整账号/API Key/Bearer/Cookie/密码/验证码，:63-120），拒绝即不落库不发送（`agent_session_service.dart:515-527`）；工具 payload 按 per-tool allowlist builder 净化（:132-147），未知工具返回空 DTO（:136-141）；递归可疑键丢弃兜底（db_id/cookie/password/token/path/url 等，:230-306）；摘要落库前再净化（:156-176）。
- 助手文本过滤：`AssistantTextFilter`（`app/lib/features/agent/application/assistant_text_filter.dart:21-204）——流式增量剥离回合开头的历史时间戳标记与 `ref_*` 令牌（拆分为安全占位符「该条目」，:23），跨 chunk 拆分令牌暂存不闪现（:147-175），流末尾不完整前缀直接丢弃（:163-168）。
- 审计：`action_logs` source 值四类（`user`/来源键/`agent`/`system`）——每次 run 恰好一条 `source='agent'`/`actionType='read_only_run'` 汇总（`agent_session_service.dart:1677-1704`）；写审批流 `agent_write_confirm`/`agent_write_decline`/`agent_write_cancel`/`agent_write_*`（`agent_write_tool.dart:265-337`、`agent_permission_policy_service.dart:549-583`）；用户侧策略变更（`agent_permission_policy_service.dart:472-482`）。
- 聚合观测：`MutationLedger`（`app/lib/features/agent/application/agent_mutation_ledger.dart:25-162）——生命周期写结果按序聚合成功/拒绝/失败/未处理（:137-161），只含计数与白名单错误码；`CreateTaskBurstLease`（`agent_tool_budget.dart:163-291`）同构聚合突发 create_task。
- 指纹：`ToolCallFingerprint`（见子结构 2/3）。

**6. 约束与恢复**

- 审批门：`AgentWriteTool.execute`（`app/lib/features/agent/application/agent_write_tool.dart:137-219`）——propose（不碰库）→ allowlist 校验（:165-176，伪造策略组合拒绝）→ `AgentPermissionPolicyService.resolve`（`agent_permission_policy_service.dart:393-410`，ask_first_time 首次确认后放行 :405-407）→ allow 直接原子提交 / deny 拒绝 / confirm 进确认卡暂停（:194-217）。
- 确认卡：`AgentWriteConfirmationCard`（`app/lib/features/agent/presentation/agent_write_confirmation_card.dart:10-137`）——预览 + 风险徽标 + 确认/取消/此类型以后不再确认/去权限设置，提交防重（:35-45）；恢复经 `confirmWriteProposal`（`agent_session_service.dart:383-457`）→ `WriteConfirmationStore.resolve`（`agent_write_tool.dart:265-308`）。
- 原子提交：`commitAgentWriteAtomically`（`agent_write_tool.dart:371-436`）——业务 commit → 用户确认日志 → agent 审计 → 提交后权限变更，同一 `DriftAgentWriteUnitOfWork` 事务（`app/lib/features/agent/data/drift_agent_write_unit_of_work.dart:9-15`），任一步失败整体回滚。
- grounding 受限纠错与 tool_choice 降级（见子结构 3）；预算熔断（见子结构 2）；关系写期望状态强校验（首次 `relation_state_mismatch` 固定指引、二次直接安全终止，`agent_session_service.dart:1206-1248`）。
- 撤回槽约束：**main 上已实现**——`DriftAgentWriteGateway` 以 `NoopUndoRecorder` 构造全部底层服务（`app/lib/features/agent/data/drift_agent_write_gateway.dart:44-76`），即 Agent 写入不占用一步撤回槽；撤回能力由 `undo_last_action` 工具经 `UndoService` 提供（`drift_agent_write_gateway.dart:774-779`），系统提示词 v8 要求撤回前先预览（`agent_system_prompt.dart:74`）。

**7. 平台适配边界**

- 平台无关（纯 Dart，无 `dart:io`/DPAPI/Win32）：domain 全部、application 全部（含 `AgentComposition`，其注释明确「imports only pure-Dart agent interfaces」，`agent_composition.dart:115-120`）；`AgentTool` 契约强制实现纯 Dart（`agent_tool.dart:120-121`）。
- Windows 专属：`ProtectedAgentSecretStore`（DPAPI，`protected_agent_secret_store.dart`）、`WindowsPythonQueryGateway`（唯一可触及 `dart:io` 的 agent 代码，`windows_python_query_gateway.dart:47-49`）。
- 注入点：`app/lib/app/router.dart`——`_AgentChatLoader`/`_AgentChatCompositionBuilder`（:517-695）→ `_buildWindowsAgentComposition`（:705-745）构造 `LazyQuerySourceGateway`（Bridge 惰性启动，:716-732）、`ProtectedAgentSecretStore(database, WindowsDpapiProtector())`（:739-742），经 `AgentComposition.build`（`agent_composition.dart:128-253`）注入 `SecretStoreFactory`/`QueryGatewayFactory` typedef（:29-36）；Android/iOS 测试可注入替代实现（:127-128）。

## 3. 现状·关键数据流

### 3.1 有界推理循环（Agent 查询主链路）

```
用户输入
  → AgentChatPage._send (presentation/agent_chat_page.dart:259)
  → AgentSessionService.send (agent_session_service.dart:160)
  → OutboundPrivacyFilter.inspectUserText 拒绝则 privacy_rejected 不落库 (515-527)
  → DriftChatRepository.startRun + recentMessages(200) + appendMessage (535-552)
  → AgentGroundingPolicy.classify 产出 grounding 要求（可为 null）(566)
  → AgentContextBuilder.estimateTurnTokens 超 28k 则 question_too_large (593-616)
  → AgentContextBuilder.build 组装 LlmRequest（摘要 + 历史 + 当前 + 工具声明 + system v8）(621-631)
  → [循环 ≤ 8 次模型调用]
     → AnthropicLlmProvider.stream → SseDecoder → LlmEvent 流 (754-834)
     → TextDelta → AssistantTextFilter → 草稿落库 + 视图状态 (803-816)
     → ToolUseCompletedEvent → 逐工具: 预算预检 → 指纹去重 → registry.execute
         → 结果净化 → tool_result 入对话 → 调用行落库 (1057-1487)
     → 无工具回合 → _settleNoToolUse 结算（接受/纠错/确定性失败）(872-973)
  → finishRun + 单条 ActionLog + 摘要调度 (1513-1572)
```

起点：`agent_chat_page.dart:259`；终点：`drift_chat_repository.dart:138`、`action_logs` 表。预算边界：8 模型调用（`agent_session_service.dart:144`）/ 12 工具调用（`agent_tool_budget.dart:37`）。

### 3.2 写操作确认流（约束与恢复）

```
模型发出写工具 tool_use
  → AgentWriteTool.execute (agent_write_tool.dart:137)
  → propose 产提案（不碰库；参数错误 → invalid_write_arguments）
  → allowlist 校验 (165-176)
  → policy.resolve (agent_permission_policy_service.dart:393)
     ├─ deny  → permission_denied（fingerprint 记阻断）
     ├─ allow → commitAgentWriteAtomically（业务+审计+权限变更同一事务）(agent_write_tool.dart:225-235)
     └─ confirm → WriteConfirmationStore.register 得 wc_* 句柄 (200-205)
         → AgentToolResult(needsUserAction) 携带 pendingInvocation
  → session_service 进入暂停：行状态 running → waiting_user（agent_session_service.dart:1278-1316）
  → AgentChatPage 渲染确认卡（agent_chat_page.dart:769）
  → 用户选择 → confirmWriteProposal → WriteConfirmationStore.resolve (agent_write_tool.dart:265-308)
     ├─ 批准 → commitAgentWriteAtomically（userConfirmed=true，加 agent_write_confirm 日志）
     └─ 拒绝 → user_declined + agent_write_decline 审计
  → pendingInvocation.result 完成 → 会话循环恢复，调用行落终态
```

句柄丢失路径：`confirmation_not_found` 时立即取消暂停运行而非悬挂（`agent_session_service.dart:434-447`）。

### 3.3 外部数据源查询流（Bridge 消费侧）

```
外部只读工具 execute（search_current_second_class_activities 等，agent_tools.dart:2846-3276）
  → SourceQuery 请求（young_enrolment/icourse/campus_search/campus_detail，domain/query_source.dart:28-89）
  → WindowsPythonQueryGateway.execute（windows_python_query_gateway.dart:87-204）
     → POST /queries 建 job（:94-102）
     → 200ms 轮询 /query-jobs/<id>/events?after=&waitMs=2000（:280-329）
     → needs_user_login 相位 → SourceQueryNeedsLogin → run 暂停（:144-146, :175-191）
     → terminal 相位 → SourceQueryCompleted（QueryResultEnvelope 1.0）或 SourceQueryFailed
  → 工具映射为 AgentToolResult（_mapYoungEnrolmentResult 等，agent_tools.dart:2905+）
  → registry 净化 → tool_result 入对话
```

登录恢复：UI `resumeUserAction` → `userActionResumer`（`agent_composition.dart:216-231`，取学校密码 + `queryGateway.resumeLogin`）；取消/超时/暂停均先 `_safeCancel` 再收尾（`windows_python_query_gateway.dart:116-129, 353-360`）。Bridge 惰性启动由 `LazyQuerySourceGateway` 完成（`agent_composition.dart:41-113`）。

### 3.4 滚动摘要流

```
run 成功完成（agent_session_service.dart:1563-1572）
  → AgentContextBuilder.needsSummary（估算 ≥ 18,000 触发，agent_context_builder.dart:218-237）
  → summaryHistoryFits / trimSummaryHistory 独立预算（:160-192）
  → buildSummaryRequest：无工具、temperature=0、maxTokens=1024（:248-296）
  → provider.stream（不占 8/12 预算，:1818-1820）
  → sanitizeSafeSummary 净化 → replaceSummary（throughOrdinal 单调推进，:1844-1855）
  → 失败吞掉不阻塞聊天（:1856-1858）
```

## 4. 现状·接口契约

**对外接口（本模块提供）**

| 接口 | 位置 | 消费方 |
|---|---|---|
| `LlmProvider`（listModels/stream/probeText/probeTools） | `domain/llm_protocol.dart:246-280` | 装配与设置页（`AgentSetupPanel`，`agent_setup_panel.dart:65-84`） |
| `AgentSecretStore` | `data/protected_agent_secret_store.dart:15-25` | 设置页、`AgentComposition` |
| `AgentConfigurationService` | `application/agent_configuration_service.dart:31` | 设置页、聊天页 |
| `AgentSessionService`（send/cancel/retryLast/resumeUserAction/confirmWriteProposal） | `application/agent_session_service.dart:160-457` | `AgentChatPage` |
| `AgentPermissionPolicyService` | `application/agent_permission_policy_service.dart:52` | 权限分区页、写工具 |
| `AgentCompositionResult` | `application/agent_composition.dart:258-304` | router loader |
| `QuerySourceGateway` | `domain/query_source.dart:218-232` | 外部工具（本模块内部消费） |

**本模块消费的接口（上游）**：`BridgeClient`（`app/lib/features/sync/data/bridge_client.dart`，Bridge 进程/HTTP）、`CredentialProtector`/`WindowsDpapiProtector`（`app/lib/core/security/credential_protector.dart`）、`AccountService`、`CalendarEventService`/`TaskLifecycleService`/`PlanBlockService`/`OverlayService`/`ConflictService`/`JwDayMoveService`/`ReminderOverrideService`/`UndoService` 等（经 `AgentWriteGateway` 与 `AgentLocalDataGateway` 接口解耦）。

**Query Protocol 1.0 消费侧契约**（实现细节归模块 02，本模块只列消费约定）：

- 版本常量：`queryProtocolVersion = '1.0'`、`queryResultSchemaVersion = '1.0'`（`domain/query_source.dart:4,7`）。
- 请求体：`protocolVersion` + `queryProtocolVersion` + 四类 `query` 负载（`windows_python_query_gateway.dart:231-275`）。
- 事件轮询：`?after=<sequence>&waitMs=2000` 长轮询，`nextSequence`/`terminal` 信封（:280-329）。
- 结果信封校验：`_isQueryResultEnvelope`（schemaVersion/queryType/generatedAt/data/metadata/references 全字段，:331-342）；`QueryResultEnvelope` 类型视图（`domain/query_source.dart:99-112`）。
- 失败码白名单：14 个安全码，未知码一律折叠为 `query_failed`（`domain/query_source.dart:181-199`）。
- 边界约定：网关绝不携带模型 API Key；仅 `young_enrolment` 携带账号身份；绝不由工具参数接受 URL（entry id 只来自 run 内 ref 解析）（`domain/query_source.dart:215-217`、`windows_python_query_gateway.dart:38-46`）。

## 5. 现状·错误处理

**错误码体系（均为安全字符串，绝不含密钥/响应原文）**

- LLM 层（`anthropic_llm_provider.dart:532-543`）：HTTP 映射 `auth_failed`/`rate_limited`/`server_error`/`protocol_error`；流异常 `transport_error`/`stream_transport_error`/`stream_incomplete`/`tool_input_invalid`/`cancelled`；`ErrorEvent(code, retryable)`（`domain/llm_protocol.dart:67-75`）。
- 查询层（`windows_python_query_gateway.dart:96-102, 133-139`）：Bridge 协议错误直接透传安全码，其余折叠 `invalid_response`；超时 `query_timeout`、取消 `cancelled`；`safeSourceQueryFailureCode` 白名单（`domain/query_source.dart:198-199`）。
- 运行层（`agent_session_service.dart`）：`privacy_rejected`、`run_already_active`、`service_disposed`、`runtime_error`、`model_call_budget_exceeded`（:744-746）、`tool_call_budget_exceeded`（:1110-1112）、`question_too_large`（:598-616）、`grounding_failed`（:968）、`paused_run_not_found`/`resume_already_started`/`resume_unavailable`（:334-363）、`confirmation_not_found`（:434-447）、`nothing_to_retry`（:283）。
- 工具层：`tool_not_allowed`/`tool_execution_failed`（registry）、`repeated_tool_call`（指纹）、`invalid_arguments`/`invalid_write_arguments`（参数）、`relation_lookup_requires_bound`/`relation_state_mismatch`（关系写）、`user_declined`/`permission_denied`/`write_commit_failed`/`confirmation_not_found`（审批门）、`stale_target`/`target_not_found`/`already_active`/`already_deleted`/`invalid_lifecycle_transition`/`relation_not_found`/`no_undo_available` 等（`agent_lifecycle_tools.dart:43-140`，`mapLifecycleError`）。

**重试策略**

- LLM 传输/429/5xx：最多 2 次指数退避（250ms×2^n），发过内容后禁止重试（`anthropic_llm_provider.dart:186-210`）；`protocol_error`（不可解析 SSE 体）同样重试 ≤2 次（:241-249）；`retryable` 标记供上层感知（`ErrorEvent`）。
- 强制 `any` 纠错兼容降级：仅 `protocol_error` 且无任何内容时降级 `auto` 重试一次（`agent_session_service.dart:853-864`）。
- 会话层 `retryLast`：新 run 复用最后完成用户消息（:238-316）。
- 写提交：**不重试**业务 commit；事务失败后仅 best-effort 补一条 `failed` 审计（`agent_write_tool.dart:420-434`）。

**回滚与事务边界**

- 单事务原子写：业务提交 + 审计 + 权限变更，任何失败整体回滚（`agent_write_tool.dart:371-436` + `drift_agent_write_unit_of_work.dart:9-15`，Drift 事务嵌套合并）。
- 业务级非成功：`AgentWriteAborted` 抛出让事务回滚、事务外原样返回安全结果（`agent_write_tool.dart:17-20, 383-387`）。
- 幂等终态：`finishRun`/`finishToolInvocation` 只接受 running 状态行，重复终态调用为 no-op（`drift_chat_repository.dart:138-181, 364-413`）。
- 日志失败不反转业务：ActionLog/摘要/调用行均为 best-effort，失败吞掉（`agent_session_service.dart:1552-1560, 1580-1597, 1651-1675`）。
- 恢复路径：启动 `recoverInterrupted`（`drift_chat_repository.dart:469-510`）；暂停运行取消 `_cancelPausedRun`（`agent_session_service.dart:484-501`）。

**关键位置汇总**：`agent_session_service.dart`（运行/工具错误）、`anthropic_llm_provider.dart`（LLM 错误与重试）、`agent_write_tool.dart`（原子提交与审批错误）、`agent_lifecycle_tools.dart:43-171`（生命周期错误映射）、`windows_python_query_gateway.dart`（Bridge 错误）。

## 6. 现状·观测点

**状态持久化（落库表）**

- 会话/消息：`chat_messages`（ordinal 事务内分配，`drift_chat_repository.dart:56-82`）。
- 运行：`agent_runs`（startRun/finishRun，含 errorCode/token 计数）。
- 工具调用：`tool_invocations`（running → waiting_user → 终态，`ToolInvocationLifecycleState`，`domain/agent_models.dart:89-121`）。
- 摘要：`conversation_summaries`（每账号唯一，replaceSummary）。
- 密钥：`agent_secrets`（DPAPI 密文）。
- 设置：`agent_settings`（model/enabled/icourseConsent/systemPromptVersion）。
- 权限策略：`agent_permission_policies`（actionType+targetType 唯一）。

**日志/审计**

- `action_logs` 表（`operation_tables.dart:5-24`）：run 汇总（`read_only_run`，`agent_session_service.dart:1696-1703`）；写提交 `logAgentWrite`（`agent_permission_policy_service.dart:549-563`）；审批决策 `logAudit`（:568-583）；用户侧策略变更（:472-482, :514-523, :597-605）。
- 摘要安全：`sanitizeSafeSummary` 防止摘要成为密钥的持久存储（`outbound_privacy_filter.dart:156-176`）。

**可恢复性（重启恢复）**

- `AgentComposition.build` 启动即调 `recoverInterrupted`（`agent_composition.dart:138-139`）：跨进程被杀留下的 running run → interrupted、streaming 草稿 → interrupted、非终态工具调用 → interrupted；recentMessages 对「带文本的 interrupted 助手消息」仍可见（`drift_chat_repository.dart:220-227`）。
- 视图恢复：聊天页加载历史 + `toolInvocationsForRuns` 恢复工具摘要（`agent_chat_page.dart:184`；`drift_chat_repository.dart:418-434`）。

## 7. 端到端链路参与

- **completeReset 链路**：`SettingsService.completeReset`（`app/lib/features/settings/application/settings_service.dart:170-190`）删除 `action_logs`、`undo_slot`、`local_accounts`；本模块所有表经 FK `ON DELETE CASCADE` 随账号级联清除（`agent_tables.dart:6-7, 43-44` 等，全部 `references(LocalAccounts, onDelete: KeyAction.cascade)`）。本模块环节：无主动代码，被动级联。上游/下游：settings 模块（模块编号以 settings 文档为准）。
- **同步链路**：Agent 侧仅 `get_sync_status` 只读工具消费 sync 模块状态（`agent_tools.dart:1974 GetSyncStatusTool`，经 `AgentLocalDataGateway.syncState`，`agent_local_data_gateway.dart:220`）；同步后的数据由本地数据网关/写网关读取。本模块环节：查询消费；上游：sync 模块。
- **Agent 查询链路（重点）**：`AgentChatPage` → `AgentSessionService` 推理循环（第 3.1 节）→ 本地数据经 `DriftAgentLocalDataGateway`（`agent_local_data_gateway.dart:333`）读 Drift；外部数据经 `WindowsPythonQueryGateway` → `BridgeClient`（`app/lib/features/sync/data/bridge_client.dart`）→ Python Bridge（模块 02，`src/ustc_assistant/bridge/`）；登录恢复经 `AccountService.passwordForInteractiveLogin`（accounts 模块）。本模块环节：循环编排 + 工具 + 网关消费；上下游：sync/accounts 模块、模块 02。
- **首次配置链路**：`AgentSetupPanel` → `listModels` + `probeText` + `probeTools` 三探针（`agent_setup_panel.dart:65-84`）→ `configureWithKey` 事务保存（`agent_configuration_service.dart:74-85`）。本模块环节：探针协议 + 密钥存储。

## 8. 原生目标态对照

> 本节全部内容标注【目标态推断】。不引用任何既有 flutter-native 设计文档，只描述方向与开放决策。

**【目标态推断】1. 职责是否保留：**

- 本模块的核心职责（推理循环、工具系统、上下文管理、审批门、隐私过滤、持久化）在「全部数据链路 Flutter 原生化、Bridge 消失」的最终形态中整体保留——这些能力与数据链路无关，是客户端本地助手的固有功能。
- 消失的是平台适配层中的「Bridge 查询网关」：`WindowsPythonQueryGateway`（`windows_python_query_gateway.dart`）与 `LazyQuerySourceGateway` 惰性启动（`agent_composition.dart:41-113`）不再需要。外部数据源（二课/评课/校园通知）若原生化，其查询能力或以 Dart 原生客户端直连数据源、或以本地解析器替代，`QuerySourceGateway` 接口本身可保留为抽象，具体实现替换。
- `ProtectedAgentSecretStore` 的 DPAPI 实现保留（Windows 客户端仍需本地密钥保护），仅当桥接层消失不影响其接口契约。
- `AnthropicLlmProvider` 保留：模型服务是远程 HTTP/SSE 接口，与 Bridge 无关，原生化不改变其契约。

**【目标态推断】2. 会保留的契约：**

- `LlmProvider`（`domain/llm_protocol.dart:246-280`）：SSE + tool_use/tool_result 协议与模型服务直连，必然保留。
- `AgentTool`/`AgentToolRegistry`/`AgentToolContext` 契约（`domain/agent_tool.dart:122-180`）：纯 Dart、无凭证约束天然可跨平台保留。
- `AgentSessionService` 对外 API（send/cancel/retryLast/resumeUserAction/confirmWriteProposal）：UI 消费面保留。
- `QuerySourceGateway` 接口（`domain/query_source.dart:218-232`）：若外部数据源原生化，该接口可作为「外部数据获取」的统一抽象保留，实现从 Bridge 轮询改为原生请求；Query Result 1.0 信封（`queryResultSchemaVersion = '1.0'`，`query_source.dart:7`）是否保留为开放决策——Bridge 消失后信封结构（schemaVersion/generatedAt/references/data/metadata）可能被原生 DTO 取代，或保留为数据交换规范。
- 账号隔离契约（`accountId` 全表键 + `RunOwnershipException` + 复合 FK）：与平台无关，保留。

**【目标态推断】3. 开放决策（待决策，不替重构者做决定）：**

- Query Protocol 1.0 消费侧在 Bridge 消失后的演进方式：Dart 原生实现是否仍保持「轮询 job/事件流」形态，还是改为直接请求-响应/流式结果；协议版本号（`queryProtocolVersion`/`queryResultSchemaVersion`）是否继续演进或废弃——待决策。
- 外部数据源（青年日程/评课/校园目录）原生化后，登录态（young `needs_user_login` 暂停-恢复流）如何实现：`SourceQueryNeedsLogin` → `resumeLogin` 的暂停机制是 Bridge 轮询模型的产物，原生实现可能需要新的登录交互契约——待决策。
- `AgentLocalDataGateway`/`AgentWriteGateway` 背后的 Drift 数据层在「数据链路 Flutter 原生化」后是否改变形态（例如统一数据仓库层），Agent 层接口是否随之调整——待决策。
- 六子结构是否需要拆分为独立包/库（如共享核心跨平台复用），还是保持 feature 内聚合——待决策。
- 工具集的未来扩展方式（MCP 等外部工具协议是否引入）——待决策。

## 9. 开源参考与优化建议

**参考项目**（经 WebSearch/GitHub 检索发现，未直接抓取 github.com 页面）：

1. **OpenHands（All-Hands-AI/OpenHands）**：Agent 采用无状态、事件驱动的单步循环（reasoning-action loop），`AgentContext` 负责注入技能与提示词，`SecurityAnalyzer` 对每个动作做风险分级（低风险直接执行/中风险监控/高风险需确认），`Condenser` 子系统提供历史压缩框架（LLMSummarizingCondenser、RollingCondenser、PipelineCondenser，可链式组合；阈值触发 + 保留头部与尾部、压缩中间）。参考：docs.openhands.dev/sdk/arch/agent、docs.openhands.dev/sdk/arch/condenser。
2. **Dify 工作流引擎**：DAG 编排 + 基础设施级执行上限（500 步/1200 秒）——少数在平台层强制成本/步数上限的框架；Agent 节点内嵌循环形成「DAG 骨架 + 自主推理黑盒」混合模式。
3. **LangGraph**：StateGraph 有环图 + Pregel 运行时（节点返回值是「写提案」，超步结束原子提交，避免竞态）；human-in-the-loop 以 interrupt 节点实现；checkpoint/resume 在任意节点序列化状态（建议只在关键决策点打点）；2026 年 LangGraph 0.4 将状态持久化与人工审批节点作为一等公民。
4. **AutoGPT 等开源 Agent 的循环检测实践**：2026 年指南普遍建议迭代告警（3 次警告、5 次终止）与硬预算（maxCostUsd/maxSteps）从第一天就引入。

**可借鉴模式与本模块的对应**：

- OpenHands 的 Condenser 模式 ↔ 本模块 `AgentContextBuilder` 的滚动摘要（`agent_context_builder.dart:218-296`）已具备 token 阈值（18,000）触发 + 独立摘要预算 + 无工具 temperature=0 请求，与 RollingCondenser 思路同构。
- OpenHands SecurityAnalyzer 风险分级 ↔ 本模块 `AgentPermissionPolicyService` 的风险/确认模式矩阵（`agent_permission_policy_service.dart:393-410`）与 `AgentWriteAllowance` 组合校验（`agent_write_tool.dart:41-97`）。
- Dify 的平台级执行上限 ↔ 本模块 8×12 硬预算（`agent_session_service.dart:144`、`agent_tool_budget.dart:37`）+ 突发 32 上限（:40）。
- LangGraph 的 interrupt 节点 ↔ 本模块 needsUserAction 暂停/恢复机制（`agent_session_service.dart:1278-1316`）与 `_PausedRun` 状态捕获（:50-71）。

**具体可落地建议**：

1. **上下文预算动态化（参考 OpenHands Condenser 阈值触发 + Dify 成本上限）**：目前 token 估算以「字符数/1.0」兜底（`agent_context_builder.dart:346-349`），可引入按工具声明实际大小触发的压缩决策（类似 Condenser 的 max_size/keep_first/tail 策略），并考虑把「工具声明 + 系统提示词」的固定开销缓存化——每次请求都 `jsonEncode` 全部工具声明（:203-207），39 个工具的声明在 run 内不变，可缓存编码结果。
2. **循环检测显式化**：`ToolCallFingerprint` 已阻断完全重复调用（`tool_call_fingerprint.dart`），可借鉴「迭代告警」语义：在 grounding 纠错之外，对「参数变化但仍无进展」的循环（非精确重复）增加轮次告警/终止阈值，避免消耗 8×12 预算后才被模型调用上限截停。
3. **状态检查点最小化（参考 LangGraph checkpoint 只在关键决策点打点）**：当前 `_PausedRun` 在内存中保存整个 conversation（`agent_session_service.dart:50-71`），重启即丢失。若未来要求跨进程恢复确认流，可考虑只在审批门暂停点持久化最小状态（proposal 视图 + 消息 id 索引），而非整个对话对象——开放决策，需重构者评估必要性。
4. **审批策略可视化与审计联动（参考 OpenHands confirmation_mode 策略族）**：`kPermissionActions` 注册表（`agent_permission_policy_service.dart:66-330`）已统一动作键/风险/默认模式，可进一步为设置页提供「最近放宽」可逆入口（reset 已支持，`agent_permission_policy_service.dart:623-669`），形成策略生命周期闭环。
5. **工具声明瘦身**：39 个工具全量声明占用固定上下文开销（`agent_context_builder.dart:198-208`），grounding 已支持 `initialAllowedTools` 收窄（`agent_grounding_policy.dart:59-64`），可将收窄策略推广到读意图与普通写意图，降低每次请求的固定开销。

## 10. 未验证/存疑事项

**已验证（grep/glob 确认）**：全部 46 个源文件路径与第 2 节目录树；工具名清单（`agent_tools.dart:2673-2689`、`agent_write_tools.dart:169-1883`、`agent_lifecycle_tools.dart:182-1179`、`agent_management_tools.dart:62-568`）；8/12 常量（`agent_session_service.dart:144`、`agent_tool_budget.dart:37`）；系统提示词 v8（`agent_system_prompt.dart:57`）；网关 origin 与重试（`anthropic_llm_provider.dart:38,42`）；默认模型（`agent_configuration_service.dart:38`）；`NoopUndoRecorder` 撤回槽约束（`drift_agent_write_gateway.dart:44-76`）；路由注入点（`router.dart:705-745`）；测试锚定（`agent_session_service_test.dart:1472,1503`）。

**存疑/未验证事项**：

1. **未运行任何测试/构建**（按任务约束静态阅读）：8 轮/12 次的实际执行行为、SSE 解码边界、确认卡恢复流程的正确性均以测试存在为前提推断，未亲自运行验证。
2. `agent_configuration_service.dart:41` 的 `defaultSystemPromptVersion = 3` 与 `agent_system_prompt.dart:57` 的 `version = 8` 不一致（schema 默认 vs 当前提示词版本）；`agent_tables.dart:13-14` 表默认 `systemPromptVersion = 2` 亦与两者不同。三者关系（何时用哪个、是否升级迁移）未在代码中验证，行为存疑。
3. `AgentSettingsSnapshot` 的 `enabled`/`icourseConsent` 字段在聊天页/设置页的消费细节（`agent_chat_page.dart:480-512` 的 `_buildUnconfigured`）未逐行核对。
4. `agent_lifecycle_tools.dart` 中 `UpdateTaskTool`/`UpdatePlanBlockTool` 等工具的具体 propose/commit 参数细节（约 1200 行）未逐行阅读，仅验证了类名、name 与错误映射函数。
5. `agent_tools.dart` 中 `GetScheduleTool` 的日期解析与 `maxDetailedScheduleSpanDays` 等边界常量（:515-532 附近）未确认具体数值。
6. Python 侧 `src/ustc_assistant/bridge/query_contracts.py` 等文件已确认存在（ls 验证），但其内容未阅读（属模块 02 范围），Query Result 1.0 信封的 Python 侧校验细节未验证。
7. `settings_page.dart` 对 `AgentSettingsPage` 的导航入口与 `agent_settings_page.dart` 内部 498 行细节未逐行阅读。
8. 测试文件 29 个（ls 验证）与源文件的对应覆盖关系未逐一核对；部分测试断言（如 grounding 纠错次数、create-task 突发上限）仅通过注释引用。
9. `agent_tools.dart:2283-2310` 附近的写工具 payload builders 剩余条目（`_writeResultKeys` 的具体键集合）未读取确认。
10. 其他模块文档编号（sync/accounts/settings/calendar/tasks/schedule/reminders）未在本仓库 docs 中验证对应编号，第 7 节以描述性引用代替。
