# Agent 只读修复与写工具安全加固设计

日期：2026-08-01  
状态：已确认，待实施计划

## 1. 背景与审查范围

本轮审查覆盖两批已经完成的实现：

1. 已合并到 `main` 的只读 Agent 修复轮，永久状态记录在
   `docs/read-only-agent-handoff.md`；
2. `feature/write-tools` 分支在 `98120be` 之后实现的十个本地写工具、审批门、权限策略、
   确认卡和对应测试，当前审查 HEAD 为 `794270e`。

只读修复轮原先的“重复日程查询产生大量不可点击 chip”“二课与校园目录工具持续失败”
已有实现与回归测试覆盖，本轮静态审查未发现它们仍然成立。真实学校 API、登录恢复和
校园网环境仍须人工验收，自动测试不能替代该结论。

本轮发现的主要风险位于写工具边界：业务写入、审计和权限状态并非原子提交；部分确认卡
没有展示被修改对象；工具 schema 只提供给模型而未在运行时强制执行；权限变更日志还存在
动作类型错误。另有一个已知的只读 Agent 配置债务：教务默认学期在 Python JSON 与 Flutter
代码中重复维护。

## 2. 目标

- 任一 Agent 本地写操作都满足“明确参数、明确目标、明确批准、原子落库、可审计”。
- 用户看到确认卡时能够判断 Agent 选中了哪个日程、任务或执行块，而不仅是看到动作名称。
- 模型即使提交缺字段、错类型、未知枚举、额外字段或互相冲突的参数，也只能得到稳定的
  `invalid_write_arguments`，不会静默改成默认值或进入部分写入。
- 业务变更、成功审计、确认决策以及由该确认产生的权限变化在一个 SQLite 事务中完成；
  任一步失败时业务变更整体回滚，重试不会因“实际成功但返回失败”而制造重复数据。
- 权限历史能够准确区分业务写入、批准、拒绝、自动放宽、显式放宽和恢复默认。
- 教务默认学期只手工维护一份源配置；Flutter 使用生成产物，测试阻止生成产物过期。
- 保持十个工具名称、现有只读工具、`ref_*` 隔离、SourceBundle、Python 五条来源链路以及
  Android/iOS 未来迁移边界不变。

## 3. 非目标

- 不增加学校或外部平台写操作；二课报名和取消仍只能由用户在官方页面完成。
- 不增加批量写、跨 run 待确认提案、离线写队列或云同步。
- 不引入通用 JSON Schema 执行引擎；本轮只为十个写工具建立小而明确的运行时参数读取层。
- 不重构现有 Calendar、Task、Overlay、Reminder 领域服务，也不改变其用户操作语义。
- 不在本轮实现公开引用 chip 跳转、视觉模型、每日简报或移动端采集适配器。
- 不把自动测试通过写成人工验收通过。

## 4. 审查发现与必须修复的行为

### 4.1 写入与审计存在部分提交窗口

`AgentWriteTool._commitAndLog` 当前先调用业务 `commit`，成功后再追加 Agent 日志；确认路径
又在此之后更新 `always_allow` 或 `firstConfirmedAt`。如果后续日志或权限写入失败，业务数据
已经提交，但调用方收到 `write_commit_failed`。模型或用户重试可能重复创建日程、Task 或
PlanBlock。

设计要求新增 `AgentWriteUnitOfWork` 边界。Drift 实现使用同一个 `AppDatabase.transaction`，
在事务中执行：

1. 业务 `commit`；
2. 业务动作成功日志；
3. 如为人工确认，写确认决策日志；
4. 如确认会改变策略，写策略状态及权限变更日志。

`commit` 返回非 success 与抛出异常都必须中止事务。事务失败后可以在独立、尽力而为的
事务中记录失败日志，但不得重新执行业务写入；如果数据库本身不可写，允许失败日志也缺失，
但业务数据必须保持未变。

直接放行路径与人工确认路径共用同一提交协调器，不能各自复制事务逻辑。现有领域 Service
可以继续使用内部事务；测试必须证明它们在外层 Agent 事务中仍服从整体回滚。

### 4.2 工具输入必须在运行时严格校验

`AgentToolRegistry` 只把 schema 发给模型，并不会据此验证 `arguments`。因此写工具增加共享的
`WriteArgumentReader` 小型类型化读取器，每个 `propose` 显式执行以下检查：

- 必填字段存在，类型准确，字符串去除首尾空白后仍非空；
- 枚举值必须是 schema 声明值，未知值不得回退到 `normal`、`accepted`、`undecided`、
  `listen`、`personal` 或 `always_ask`；
- schema 统一声明 `additionalProperties: false`，运行时也拒绝未知字段；
- 日期时间必须包含可解析的 ISO-8601 值，并遵守现有 `Asia/Shanghai` 规则；
- timed event 必须同时有 `start_at/end_at`，all-day event 必须同时有
  `start_date/end_date_exclusive`，两组不能混用；
- `update_event` 的 `delete`、`status` 与字段编辑互斥，空修改被拒绝；
- `update_event.type` 要么真正写入，要么从 schema 删除；本轮选择真正支持，同时把代码已读取的
  `importance` 补入 schema；
- `scope`、overlay 枚举、出勤决定、听讲模式、关系状态、权限模式均严格解析；
- 关系两端不能指向同一对象；提醒偏移必须为非负整数，提交前排序并去重；
- ref 必须由本次 run 的 `RunReferenceStore` 解析为正确 kind，最终读取仍由账户隔离网关校验。

所有上述输入错误统一返回 `invalid_write_arguments`。数据库故障和程序缺陷仍返回
`tool_execution_failed` 或 `write_commit_failed`，不得伪装成参数错误。

### 4.3 确认提案必须包含安全的目标快照

为已有对象写入时，`propose` 在进入审批门前通过账户隔离的只读方法取得
`AgentWriteTargetSummary`：

- event：标题、当前起止时间/全天日期、地点、来源类型；
- task：标题、截止时间、当前状态；
- plan block：标题、起止时间及所属任务标题；
- relation：左右两端各自的标题与时间；
- permission：被调整的业务动作、目标类型、当前模式和新模式。

确认卡至少显示目标标题；涉及时间、系列范围、删除、状态变化、提醒或关系时，还要显示当前
时间/范围和拟变更内容。创建类操作继续显示将创建的标题与时间。

摘要只进入本地 UI 和本地安全日志，不包含 DB 主键、远端个人 ID、`ref_*` 原值、Cookie、
Token 或完整学校原始响应。`AgentWriteProposalView` 继续不暴露 `commitParams` 与 `targetId`。

目标存在性、账户归属、个人事件可编辑性、课程系列存在性等能够在确认前判断的条件必须在
`propose` 阶段完成。用户不应先批准一个注定返回 `source_event_not_editable` 或
`no_course_series` 的提案。提交时仍要再次校验，以防确认期间数据变化。

### 4.4 审计事件采用固定语义

ActionLog 使用以下稳定语义：

| 场景 | source | actionType | result |
|---|---|---|---|
| 业务写入成功 | `agent` | 实际工具动作，如 `create_event` | `success` |
| 业务写入回滚 | `agent` | 实际工具动作 | `failed` |
| 用户批准确认卡 | `user` | `agent_write_confirm` | `approved` |
| 用户拒绝确认卡 | `user` | `agent_write_decline` | `declined` |
| run 停止导致提案作废 | `agent` | `agent_write_cancel` | `cancelled` |
| 设置页、remember 或 ask-first-time 改变权限 | `user` | `update_permission_policy` | `success` |
| `update_permission_policy` 工具改变权限 | `agent` | `update_permission_policy` | `success` |
| 恢复默认权限 | `user` | `reset_permission_policy` | `success` |

`ask_first_time` 的首次确认会让后续同类动作自动放行，因此也属于权限模式的有效变化，必须
写一条 `update_permission_policy` 日志。确认、业务写入和权限变化是不同事实，不能只用业务
动作日志代替。

`UpdatePermissionPolicyTool` 的 proposal.actionType 固定为
`update_permission_policy`；被调整的动作使用独立字段 `targetActionType`。不得让局部变量覆盖
工具自身动作类型，否则 Agent 权限变更会被错误记录成 `create_event` 等业务动作。

权限页“最近变更”同时显示 `update_permission_policy` 与 `reset_permission_policy`，按北京时间
倒序排列。日志摘要可包含业务动作名、目标类型和模式变化，不含本地 ID。

### 4.5 确认交互必须防重复提交

确认卡在任一按钮触发后立即进入本地 submitting 状态，禁用“确认本次”“取消”“以后不再
确认”和跳转按钮，并显示处理中状态。恢复成功后卡片由会话状态移除；恢复失败则显示可理解
的错误并允许用户回到聊天，不得静默吞掉第二次点击或无限等待。

`WriteConfirmationStore.resolve` 返回 `confirmation_not_found` 时，会话层必须结束对应等待并
向模型或 UI 返回明确错误，不能继续等待一个永远不会完成的 completer。原有一次 run 最多
一个待确认提案的约束保持不变。

## 5. 权限策略约束

- `update_permission_policy` 始终 `forceConfirmation=true`，且确认卡不显示记住选项。
- critical 动作不得切换为 `always_allow`；设置页和工具层都执行同一规则。
- `actionType/targetType` 组合来自单一白名单。模型不能为不存在的组合创建无效策略行。
- `recordFirstConfirmation`、`markAlwaysAllow`、设置页修改和恢复默认都通过同一策略服务与
  事务协调器记录，不在 UI 或工具中手写数据库操作。
- 权限更新失败时，不得保留业务写入或半更新的 `firstConfirmedAt`。

## 6. 教务默认学期单一来源

`config/source-defaults.json` 保持唯一的手工维护源。Python 运行时继续直接读取它。新增统一
CLI 命令
`python -m ustc_assistant config generate-flutter-defaults --output app/lib/core/config/generated_source_defaults.dart`，
从该 JSON 生成 Flutter 的只读 Dart 常量文件；生成文件带“请勿手改”标记，并由 Flutter 设置、
Bridge 请求和设置页显示共同使用。

生成器必须完成整组三字段校验：`semesterId` 为正整数，`semesterKey` 与 `displayName` 为非空
字符串；不得根据年份推算教务内部 ID。新增校验测试重新生成到内存并与已提交 Dart 产物逐字
比较，JSON 改动但未更新 Flutter 产物时测试明确失败。测试 fixture 中用于特定场景的学期值
不属于生产默认值，无需被全局替换。

切换默认学期的唯一人工流程是：修改 `config/source-defaults.json`，运行生成命令，运行配置
与 Flutter 测试。不得再手工编辑 `SettingsService` 或设置页文案中的学期常量。此设计可直接
服务未来 Android/iOS，因为生成的 Dart 配置属于平台无关 App 核心。

## 7. 测试与验收

### 7.1 自动测试必须新增的场景

- 每个写工具绕过模型 schema 直接传入缺字段、错类型、未知枚举、额外字段和冲突字段；
- `create_event` timed/all-day 条件组合，`update_event` type/importance/no-op/delete 冲突；
- 十个工具的目标快照与确认预览不含 DB ID/ref，但能明确识别目标；关系预览包含两端；
- 人为让 Agent 成功日志或权限写入失败，断言业务表、领域日志、Agent 日志和权限表整体回滚；
- 同一失败调用重试不会留下两个日程、Task 或 PlanBlock；
- 权限工具日志 actionType 为 `update_permission_policy`，不是被调整动作；
- confirm/decline/cancel/ask-first-time/remember/reset 分别产生规定日志；
- 权限最近变更包含 reset，顺序和 limit 正确；
- 确认卡提交时按钮禁用，失败可恢复，`confirmation_not_found` 不挂起；
- 修改一份临时 source-defaults JSON 后生成 Dart 输出，三字段同步且无年份推算；陈旧产物测试失败。

测试优先使用内存 Drift 数据库和故障注入，不访问学校网站或学校 LLM API。事务测试必须使用
真实 `DriftAgentWriteGateway` 与真实 Repository，而不只是假网关计数。

### 7.2 完整自动验证

```powershell
$env:PYTHONPATH = "E:\107\.worktrees\write-tools\src"
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
Push-Location app
E:\flutter\flutter\bin\flutter.bat analyze
E:\flutter\flutter\bin\flutter.bat test
E:\flutter\flutter\bin\flutter.bat build windows --release
Pop-Location
```

### 7.3 人工验收

使用测试账号和真实学校 Key，在校园网/iWAN 环境执行：查询课程与二课、读取校园目录、创建
个人日程、安排 Task、修改出勤/听讲、拒绝一次写入、记住一次非 critical 权限、尝试放宽
critical 权限、切换默认学期后重新同步。逐项核对确认卡目标、实际数据库结果、操作历史与
重启后的权限状态。学校页面契约仍以真实 Edge 登录会话为准。

## 8. 完成标准

- 本文第 4 节所有行为均有失败回归测试与实现；
- 不存在“业务数据已写入但调用返回失败”的可复现 SQLite 路径；
- 所有写工具对无效模型参数确定性失败，不静默使用安全或不安全的默认值；
- 所有确认卡能让用户识别目标，且不泄漏任何本地或远端身份；
- 权限历史与 ActionLog 符合固定事件语义；
- 默认学期只修改 JSON 源并通过生成器同步 Flutter，生产代码无第二份手写值；
- Python、Flutter 全量测试、静态分析和 Windows Release 构建通过；
- 人工验收结果被如实记录，未执行项保持未完成。
