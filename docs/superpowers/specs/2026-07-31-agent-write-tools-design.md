# USTC Assistant Agent 写工具设计

日期：2026-07-31
状态：已确认，待实施

## 1. 目标

在现有只读校园 Agent 基础上，为模型增加受控的本地写能力：新建/修改/删除个人日程、
Task、PlanBlock、出勤与听讲标注、日程关系、提醒，以及权限策略调整。所有写操作
通过"审批门"分级确认，用户可在聊天内联确认卡上批准、拒绝或放宽同类操作，并可在
设置页统一管理。写能力只作用于本地业务数据，不新增任何学校或外部系统写通道。

本设计延续 `docs/schedule-data-model.md` 第 10、11、15 节的概念模型，并在
`docs/superpowers/specs/2026-07-28-read-only-agent-design.md` 的架构基础上增量实现。

## 2. 已确认范围

### 2.1 包含

- 全部 10 个写工具（数据模型 §15.2）：
  `create_event`、`update_event`、`create_task`、`plan_task`、
  `create_user_overlay`、`record_attendance_decision`、
  `record_listening_mode`、`create_schedule_relation`、
  `set_reminder`、`update_permission_policy`；
- 聊天内联确认卡：预览写操作、风险徽标、确认/取消/此类型以后不再确认/去权限设置；
- 风险分级（low/medium/high/critical）与可配置确认策略（
  `always_ask / ask_first_time / always_allow / always_deny`）；
- `AgentPermissionPolicy` 表迁移到完整形态并接入运行时决策；
- 设置页新增「Agent 权限」管理区；
- 每个写提交写 `ActionLog`，确认/拒绝/放宽均有独立记录；
- 写目标使用 `ref_*` 稳定身份，模型不接触 DB 主键。

### 2.2 不包含

- 二课报名/取消报名及任何学校/外部系统写操作（永久边界，策略不可放宽）；
- Agent 发起教务或已报名二课同步；
- 系列编辑的 `this_and_future` 粒度（只支持 `only_this` + `whole_series`）；
- 跨 run 持久化待确认提案（待确认提案只存活于当前 run）；
- 批量写队列、批量确认；
- 物理删除记录（仅 `cancelled` 状态与软删除 `deletedAt`）；
- 每日简报、视觉、附件等只读 Agent 已排除的能力。

## 3. 风险分级与确认映射

风险等级沿用数据模型 §10.3：

```text
low       读取、普通提醒
medium    新增或移动日程
high      删除、大范围修改
critical  涉及账号、安全、不可逆提交
```

默认策略（已确认，含用户调整项）：

```text
create_event / create_task / plan_task /
create_schedule_relation / set_reminder /
record_attendance_decision / record_listening_mode
                                        → ask_first_time, medium
update_event 的 whole_series 系列编辑
  （影响多个 occurrence，属大范围修改）     → always_ask, high
delete（取消/软删除日程或任务）           → always_ask, high
update_permission_policy                 → always_ask, critical
```

说明：移动/改期 PlanBlock 不在本轮 10 个写工具范围内（无对应工具），策略表仍
种子 `move_plan_block → always_ask` 作为未来预留默认项；用户锁定时间块（
`PlanBlock.locked`）永不放行确认。

补充规则：

- `update_permission_policy` 永不进入 `always_allow / ask_first_time` 放行分支；
  即使策略已放宽也强制确认；确认卡上无「此类型以后不再确认」；
- `ask_first_time` 首次确认后，同 `(actionType, targetType)` 后续直接放行；
- 每次权限放宽（用户选「以后不再确认」或设置页调整）写 `ActionLog`；
- critical 风险动作保留二次确认，设置页不允许完全免确认。

## 4. 架构与新增组件

沿用只读 Agent 分层（domain 平台无关 / application 编排 / data 平台 / presentation
UI）。新增：

```text
domain/
  agent_write_proposal.dart     写操作提案（不可变数据对象）
  agent_permission_policy.dart  策略领域模型 + confirmationMode 枚举
  agent_write_gateway.dart      AgentWriteGateway 接口（平台无关）
  agent_write_tool.dart         AgentWriteTool 抽象基类（propose + commit）

application/
  agent_write_gateway_impl.dart     写网关实现：包装现有 Application Service
  agent_permission_policy_service.dart  策略查询/决议/变更 + 默认值种子
  agent_write_tools.dart             全部 10 个写工具的具体实现
  agent_session_service.dart（扩展）   审批门 + pending_confirmation 状态机
  agent_tool_registry.dart（扩展）     识别 AgentWriteTool 并路由

data/
  app_database.dart（迁移）           agent_permission_policies 表扩展迁移

presentation/
  agent_write_confirmation_card.dart  聊天内联确认卡
  agent_settings_page.dart（扩展）     「Agent 权限」设置区
```

组件职责：

| 组件 | 职责 |
|---|---|
| `AgentWriteGateway` | 纯写接口，每个方法包装一个现有 Application Service（CalendarEventService.create/edit/softDelete、TaskLifecycleService、PlanBlockService、OverlayService、Reminder 维护）。不包含确认/策略逻辑。 |
| `AgentWriteTool` | 写工具基类：`propose(params) → AgentWriteProposal`（校验+规范化，不碰库）与 `commit(proposal) → AgentToolResult`（经网关执行）。 |
| `AgentWriteProposal` | 一次写操作的草稿：操作名、风险等级、规范化参数、面向用户的预览（标题/时间/目标描述）、目标稳定身份（ref_*，不含 DB 主键）、策略建议。 |
| `AgentPermissionPolicyService` | 查/改确认策略；`resolve(actionType, riskLevel, targetType) → auto/confirm/deny`；更新时写 ActionLog。 |
| 会话审批门 | 写工具的产物是 Proposal 而非结果；会话统一走决议 → 确认则暂停并抛 UI → 确认后 commit + 日志 + 恢复。 |
| 确认卡 | 渲染提案预览 + 风险徽标 + 按钮；权限变更提案无「以后不再确认」。 |

关键边界（沿用并强化只读设计）：

- 写工具不经网关永远不碰 DB；模型收到的永远是脱敏 safe 摘要；
- 模型不获得 DB 主键——写目标用 `ref_*` 临时引用，`RunReferenceStore` 在 run 内解析；
- 写网关只包装本地业务 Service，不新增任何学校/外部写通道；二课报名边界不变。

## 5. 审批门流程与状态机

写工具执行链路：

```text
模型请求 tool_use(写工具, 参数)
  → 1. tool.propose(参数)
        ├─ 参数校验失败/越权 → 返回脱敏 tool 错误，不暂停
        └─ 生成 AgentWriteProposal
  → 2. policyService.resolve(actionType, riskLevel, targetType)
        ├─ always_deny       → 返回脱敏拒绝结果给模型，不暂停
        ├─ always_allow      → 直接 commit + 写 ActionLog → 返回 safe 结果
        ├─ ask_first_time（已首次确认过）→ 同上直接 commit
        └─ 需要确认           → 进入第 3 步
  → 3. 暂停运行：running → pending_confirmation，
       保存 pendingProposal（run 内），向 UI 发出确认卡事件
  → 4. UI 确认卡
        ├─ [确认本次]          → commit(proposal) + 写 ActionLog → 恢复
        ├─ [取消]              → 写 ActionLog(cancelled) → 返回"用户已拒绝"结果 → 恢复
        ├─ [此类型以后不再确认]  → 先放宽策略（写 ActionLog，仅非 critical）→ commit → 恢复
        └─ [去权限设置]        → 跳转设置页；本次提案保留待用户返回后处理
  → 5. 恢复后继续原有模型循环（剩余预算内）
```

状态机变化：

```text
running ──写工具需确认──→ pending_confirmation
pending_confirmation ──确认/取消/拒绝──→ running（预算不重置）
pending_confirmation ──用户停止──→ cancelled（提案不执行）
```

关键规则：

- 一次运行最多一个待确认提案；`pending_confirmation` 与现有 `needsUserAction`
  （二课登录恢复）互斥，同时需要时按到达顺序排队；
- 暂停期间不再发起新的模型请求或工具调用（沿用现有停止语义）；
- 用户停止运行 → 提案作废，不执行；
- 确认/拒绝/放宽都写 `ActionLog`（独立 actionType）；
- 权限变更提案永远走确认，无「以后不再确认」；
- `commit` 与 proposal 一一对应，run 内一次性：不跨 run 持久化待确认提案；
- 暂停期间不计入模型调用轮数；确认后恢复不重置已用预算。

## 6. `agent_permission_policies` 表迁移

现有表是只读 Agent 阶段的 DDL 占位（`core/database/tables/operation_tables.dart`，
列 `id/accountId/actionType/policy/updatedAt`，唯一键 `(accountId, actionType)`）。
迁移扩展为数据模型 §11.1 的完整形态：

```text
保留：id, accountId, actionType, updatedAt
映射：policy → confirmationMode
新增：targetType, riskLevel, scope, enabled,
      firstConfirmedAt, lastConfirmedAt, expiresAt, createdAt, updatedBy
唯一键：扩为 (accountId, actionType, targetType)
```

默认策略按第 3 节映射惰性写入（种子逻辑在代码中，不硬编码进迁移 SQL）。

## 7. 设置页「Agent 权限」区

沿用设置页结构，新增分区：

- 列出所有策略项（按风险等级分组/筛选）；
- 每项显示当前 confirmationMode + 最近确认时间；
- 手动切换 `always_ask / ask_first_time / always_allow / always_deny`；
- `update_permission_policy` 项只能设为 `always_ask`；
- 恢复默认 + 最近权限变更记录（读 ActionLog）；
- 每次变更写 `ActionLog`（`actionType=update_permission_policy`，`actorType=user`）。

## 8. 日志与隐私

- 每次写提交写 `ActionLog`：`actionType`（create_event 等）、`riskLevel`、
  `actorType=agent`（含用户确认来源）、`safeSummary`（只含预览，如
  「新建日程 明天 15:00 健身」，不含原始参数/全文）；
- 确认/拒绝/放宽分别有独立 `actionType`；
- 所有写工具结果过现有 `outbound_privacy_filter` allowlist；
- 写目标一律 `ref_*` 稳定身份，模型全程不接触 DB 主键；
- 不新增任何外部写通道；二课报名边界、prompt-injection 防御、工具白名单不变。

## 9. 测试

自动测试不得连接学校模型服务，使用本地假 Provider、捕获 HTTP 客户端和注入式组合
（沿用 Task 8 的组合级测试模式）。

### 9.1 自动测试

- proposal 规范化、策略 `resolve` 三分支、默认值种子；
- 写网关各方法包装 Service 的参数传递与返回值；
- confirm / reject / remember 的 ActionLog 内容与独立 actionType；
- Widget：确认卡三态渲染（待确认/已写入/已取消）、风险徽标、
  权限变更卡无「以后不再确认」；
- 组合级：模型提议新建日程 → 确认卡出现 → 确认 → DB 出现事件 + ActionLog →
  模型收到 safe 结果恢复；拒绝流；「以后不再确认」放行后二次同操作直接执行；
  `always_deny` 直接拒绝；权限变更永远走确认；`pending_confirmation` 与二课登录
  恢复互斥排队；写结果不泄漏 DB 主键/原始参数；
- 写工具 schema、越权参数、预算与既有工具行为不回归。

### 9.2 人工验收

真实模型下连续发起「新建日程 / 标必去 / 删除日程」，检查确认卡、放行、
权限页、操作历史。

## 10. 完成标准

- 全部 10 个写工具经审批门可用，确认卡交互完整；
- `AgentPermissionPolicy` 表迁移完成并接入运行时决策；
- 风险映射与确认模式符合第 3 节，设置页可管理；
- 每次写操作与权限变更均有 ActionLog 记录；
- 隐私、预算、prompt-injection、二课边界等只读 Agent 安全层不回归；
- 自动测试与组合级测试全部通过；Windows 构建通过；
- 真实验收清单由用户在真实模型环境执行后填写。

## 11. 后续顺序

本轮完成后，按 `docs/read-only-agent-handoff.md` 第 9 节顺序继续：每日简报、
「可以赌」出勤询问与待确认事件、图片/文档输入与视觉路由、Android/iOS 安全存储
与查询来源适配器、安装发布与可选云同步。
