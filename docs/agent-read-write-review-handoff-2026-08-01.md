# Agent 读写能力审查与整改交接

日期：2026-08-01  
交接分支：`feature/write-tools`  
审查代码基线：`794270e`  
设计提交：`a126c90`  
实施计划提交：`5be1a1b`

## 1. 交接目标

下一位 Agent 只在 `E:\107\.worktrees\write-tools` 的 `feature/write-tools` 分支执行
`docs/superpowers/plans/2026-08-01-agent-read-write-hardening.md`。不要在 `main` 上直接修改，
不要在完成后自行合并。

本交接覆盖两批已完成实现的审查：

1. 已合并到 `main` 的只读 Agent 修复轮。原临时交接文件当前工作树已不存在，永久状态以
   `docs/read-only-agent-handoff.md` 和合并后代码为准；
2. 从 `98120be` 分叉、代码完成于 `794270e` 的十个本地写工具里程碑。

整改设计已由用户批准：

- Spec：`docs/superpowers/specs/2026-08-01-agent-read-write-hardening-design.md`
- Plan：`docs/superpowers/plans/2026-08-01-agent-read-write-hardening.md`

执行的是 Plan，Spec 是行为与验收依据。若二者冲突，以 Spec 为准并先向用户说明，不得自行
弱化安全要求。

## 2. 审查结论

### High 1：业务写入与 Agent 审计/权限变化不是原子操作

证据：

- `app/lib/features/agent/application/agent_write_tool.dart:98-109` 先执行业务 `commit`，
  成功后才写 Agent ActionLog；
- 同文件 `:159-181` 在提交及成功日志之后才执行 `markAlwaysAllow` 或
  `recordFirstConfirmation`；
- 同文件 `:186-189` 把任一后续异常统一返回为 `write_commit_failed`。

后果：日程、Task 或 PlanBlock 可能已经写入，但审计或权限落库失败后调用方仍看到失败；重试
会重复创建数据。现有领域 Service 自己使用事务，但这些事务不覆盖随后发生的 Agent 日志和
权限变化。

解决：Plan Task 3 新增 `AgentWriteUnitOfWork`，使用同一个 Drift 外层事务包住业务变更、成功
审计和权限变化；真实 SQLite 故障注入测试证明日志/权限失败会整体回滚。失败后只可尽力记录
失败日志，不得重试业务闭包。

### High 2：Agent 权限工具把审计动作错误记录为被调整动作

证据：

- `app/lib/features/agent/application/agent_write_tools.dart:927-939` 的局部
  `actionType` 读取自模型参数 `action_type`，随后直接写入
  `AgentWriteProposal.actionType`；
- `AgentWriteTool` 使用 proposal.actionType 写 Agent 日志；
- `app/lib/features/agent/application/agent_permission_policy_service.dart:203-214`
  只把 `update_permission_policy` 视为权限历史。

后果：例如 Agent 把 `create_event` 放宽为 always_allow 时，日志会伪装成一次
`create_event`，权限历史看不到这次关键变更。

解决：Plan Task 4 把被调整动作改名为 `targetActionType`，proposal.actionType 永远是
`update_permission_policy`，并新增回归测试检查 ActionLog 和权限页历史。

### High 3：模型 schema 没有运行时执行，多个工具会静默降级或抛错为普通工具故障

证据：

- `app/lib/features/agent/application/agent_tool_registry.dart:59-78` 明确只接收已解析 Map 并
  调用工具，没有 JSON Schema 验证；
- `create_event` schema 在 `agent_write_tools.dart:35-51` 只要求 title，但 timed 分支在
  `:89-90` 强制 cast `start_at/end_at`；缺字段得到 TypeError，绕过
  `AgentWriteTool` 对 FormatException 的 `invalid_write_arguments` 映射；
- `create_task` 在 `:164-168` 把未知 importance 静默改为 normal；`plan_task` 在
  `:246-250` 把未知状态改为 accepted；出勤和听讲在 `:665-685`、`:724-742` 也有默认回退；
- `update_event` schema 在 `:303` 宣布支持 type，但 propose/commit 没有读取 type；代码读取
  importance（`:336`），schema 却没有声明；
- overlay 未知枚举在 `:565-576` 变成 null，可能产生用户并未批准的空操作或部分操作。

后果：模型输出不严格符合 schema 时，工具行为不可预测，且部分错误会变成
`tool_execution_failed`，模型无法正确修正参数。

解决：Plan Task 1 新增无依赖的 `WriteArgumentReader`，严格检查必填、类型、枚举、未知字段、
条件字段和互斥写法；所有十个工具都通过 execute 测试绕过模型 schema 验证真实运行时边界。

### High 4：确认卡经常无法让用户识别被修改对象

证据：

- `update_event` 的预览在 `agent_write_tools.dart:342-360` 只显示“删除该日程”“状态改为”或
  “时间有改动”，不含目标标题和当前时间；
- 出勤、听讲、关系和提醒分别在 `:661-675`、`:720-735`、`:786-807`、`:856-870`
  只显示决定/模式/关系/偏移，不显示目标；
- `app/lib/features/agent/presentation/agent_write_confirmation_card.dart:57-68` 只渲染
  proposal.previewLines，没有其他目标来源。

后果：即使 Agent 解析错 ref，用户也无法从确认卡判断它准备修改哪节课或哪项日程，确认门
失去关键安全价值。

解决：Plan Task 2 增加账户隔离的事件目标快照，并复用 task/plan block 查询；确认前完成
个人来源、课程系列和目标存在性预检。预览必须包含标题、时间/范围及关系两端，同时断言不含
DB ID 或 ref。

### Important 5：审计语义没有达到原设计要求，权限 reset 也从最近变更中消失

证据：

- 原设计 `docs/superpowers/specs/2026-07-31-agent-write-tools-design.md:161` 和
  `:195-198` 要求确认、拒绝、放宽有独立 actionType；
- 当前批准只留下业务动作 success 日志，拒绝复用业务 actionType + declined，
  `recordFirstConfirmation` 在 `agent_permission_policy_service.dart:121-143` 修改后续放行状态
  却不记权限变更日志；
- `resetDefaults` 在 `:188-200` 写 `reset_permission_policy`，但
  `recentPermissionChanges` 在 `:203-214` 只查询 `update_permission_policy`。

解决：Plan Task 4 固定 `agent_write_confirm`、`agent_write_decline`、`agent_write_cancel`、
`update_permission_policy`、`reset_permission_policy` 的 source/action/result 语义，并让
ask-first-time 的自动放行也留下权限变化记录。

### Important 6：确认 UI 没有本地提交状态，丢失 handle 时存在等待无法收束的路径

证据：

- 确认卡回调是同步 `VoidCallback`，按钮在异步处理期间保持可点：
  `agent_write_confirmation_card.dart:16-20`、`:63-68`；
- Chat page 在 `agent_chat_page.dart:738-755` 调用 `.drain<void>()`，不观察失败状态；
- `WriteConfirmationStore.resolve` 在 handle 缺失时直接返回 `confirmation_not_found`
  （`agent_write_tool.dart:137-141`），但 session 的 resumer 返回 Future<void> 并忽略结果；
- `WriteConfirmationStore.cancel` 在 map 中已无 pending 时不会完成传入的 completer
  （`agent_write_tool.dart:193-197`）。

后果：快速重复点击虽然部分被 session guard 阻止，但没有视觉反馈；更坏情况下 handle 丢失后
原 pending future 仍可能未完成。

解决：Plan Task 5 让 resumer 返回 `AgentToolResult`，修正 cancel completer，卡片进入
submitting 状态并禁用所有动作，Chat page await stream 并显示安全错误。

### Important 7：默认学期仍有两份手写生产值

证据：

- Python 唯一配置源是 `config/source-defaults.json`；
- Flutter 又在 `app/lib/features/settings/application/settings_service.dart:30-35` 手写同组三字段；
- 设置页在 `app/lib/features/settings/presentation/settings_page.dart:106` 再手写显示文本；
- `docs/read-only-agent-handoff.md:329` 已明确“只改 JSON 即生效”的目标尚未实现。

后果：用户切换学期时必须同步改多个生产位置，容易出现 Bridge 与 App 采用不同 semesterId 的
“学期死锁”。当前默认值 461 本身正确，问题是维护方式。

解决：Plan Task 6 保持 JSON 为唯一手写源，通过统一 Python CLI 生成 Flutter 常量，并用
逐字一致性测试阻止陈旧生成文件。实施本 Task 时不得顺便把 461 改成其他学期。

## 3. 只读 Agent 修复轮复核

本轮未发现需要推翻已合并修复的证据：

- 本地导航 chip 已使用可交互 ActionChip/GoRouter；公开引用 chip 仍不可交互是已记录的后续项；
- 日程工具重复调用已有限制、分组摘要和回归测试；
- 二课登录暂停/恢复、校园目录自动刷新、查询 payload 隐私与账号切换有组合测试；
- Python Bridge 查询协议与采集作业保持分离。

仍未完成的边界：真实 Key + 校园网/iWAN + 学校登录的人工验收。不要把当前自动测试或本交接
写成真实学校环境已经通过。

## 4. 本次审查验证

在 `feature/write-tools`、代码 HEAD `794270e` 上执行：

- `PYTHONPATH` 指向 worktree 后，Python `unittest discover -s tests`：388 项通过；
- Python `compileall -q src tests`：通过；
- 直接 Dart analyzer：`No issues found`；
- `git diff --check 98120be..794270e`：通过；
- 本次环境中 `flutter.bat analyze/test` 包装层曾无输出挂起，因此本审查没有重新宣称 Flutter
  全量测试和 Windows build 通过。分支已有文档记录实现者曾得到 581 tests + Release build，
  但下一位 Agent 必须在 Task 7 重新验证并记录自己的结果。

自动测试不访问学校网站或学校模型服务。

## 5. 工作树现状与保护项

交接文档创建前，工作树已有以下非本轮改动：

```text
 M app/windows/flutter/generated_plugin_registrant.cc
 M app/windows/flutter/generated_plugin_registrant.h
 M app/windows/flutter/generated_plugins.cmake
?? docs/agent-testing.md
```

这些文件不得被回退、覆盖或顺手提交。`docs/agent-testing.md` 是用户文件；Plan Task 7 只有在
用户明确允许后才能编辑。每个提交都使用精确 `git add <paths>`，禁止 `git add .`。

本轮只增加三份审查产物：本交接、已批准 Spec、Implementation Plan；没有修改生产代码。

## 6. 下一位 Agent 的启动顺序

1. 确认工作目录为 `E:\107\.worktrees\write-tools`，分支为 `feature/write-tools`。
2. 阅读根目录 `AGENTS.md`、本交接、已批准 Spec、Implementation Plan。
3. 阅读当前实现：`agent_write_tool.dart`、`agent_write_tools.dart`、
   `agent_permission_policy_service.dart`、`drift_agent_write_gateway.dart`、
   `agent_session_service.dart` 和对应 tests。
4. 调用 `superpowers:subagent-driven-development`，按 Plan Task 1 到 Task 7 顺序执行；若当前环境
   不能使用 subagent，则调用 `superpowers:executing-plans` Inline 执行。
5. 每个 Task 严格执行红灯测试、最小实现、绿灯测试、精确提交和独立 review。
6. Task 3 的 SQLite 故障注入和完整回滚是最高优先级，不得用 mock-only 测试替代。
7. Task 7 完成全量验证和安全检查后停止，不合并 `main`，等待用户审查和人工验收。

## 7. 完成判定

只有同时满足以下条件才能声称整改完成：

- Plan 七个 Task 全部有独立提交，且测试先行证据与最终输出相符；
- 业务写入成功日志或权限更新失败时，真实 Drift 数据整体回滚；
- 十个工具都严格拒绝缺字段、错类型、未知枚举、未知字段和冲突参数；
- 确认卡明确展示目标且不含 ID/ref；
- 权限工具、confirm/decline/cancel/remember/ask-first-time/reset 日志语义准确；
- 丢失确认 handle 不会挂起，确认卡不会重复提交；
- 生产默认学期只手工维护 `config/source-defaults.json`，当前值仍为 461；
- Python/Flutter 全量测试、analyze 和 Windows Release build 有本轮实际通过证据；
- 工作树中用户原有改动未被覆盖，真实学校人工验收状态没有被虚构。

