# Agent Relation Closure Repair Design

**Date:** 2026-08-02
**Status:** Approved for planning
**Scope:** `feature/write-tools` Windows Flutter App

## 1. Goal

修复 `docs/agent-manual-acceptance-retest-2026-08-01.md` 中三个真实问题：

1. 第 5 项：关系请求首次长期“正在思考”，随后因整学期查询范围过大失败；
2. 第 12 项：整日调课成功 Snackbar 跨页面长期保留并遮挡聊天输入框；
3. 第 16 项：`move_jw_course_day` 已成功提交，但 run 最终仍以
   `grounding_failed` 结束。

同时补齐这次调查直接暴露的两个闭环缺口：

- 截图可见工具调用，但 `tool_invocations` 表没有任何持久记录，无法诊断真实调用链；
- 周视图可以发现 CalendarEvent 与 PlanBlock 重叠，但手动冲突管理只支持
  CalendarEvent，无法把“课上安排另一门课作业”标为不冲突。

并纳入新增人工测试暴露的高频 Agent 工作流：用户要求按整学期课程范围，在每个指定
星期创建一个独立 Task。该工作流必须先用课程摘要确定边界、主动澄清未明确参数，再通过
现有 `create_task` 多次写入；不得先拉取整学期全部 occurrence，也不新增重复 Task 模型。

## 2. Evidence From The Real Database

只读检查 `ustc_assistant.sqlite` 得到：

- 2026-06-02 的“量子物理 B / 电路基本理论”成功写入一条
  `schedule_relations(conflict_state='conflict')`；
- “选择去量子物理 B，不去电路基本理论”只保存在 `reason` 文本；
- 两节课的 attendance/listening overlay 均未改变；
- 由于二者本来时间重叠，派生状态已经是 conflict，显式再写 conflict 后周视图没有
  用户可感知的变化；
- `tool_invocations` 表为空，截图中的 `get_schedule`、`get_conflicts`、
  `create_schedule_relation` 仅存在于运行时 UI；
- 2026-08-02 16:55:16，`move_jw_course_day` 已成功移动 3 门课程；同一 run 在
  16:55:18 仍以 `grounding_failed` 结束。
- 新增“电磁场与波每周六作业”测试最终已经通过多次 `create_task` 创建成功；实际缺陷是
  Agent 首次错误使用普通 `get_schedule` 查询过大范围，先产生了一次可避免的失败。

这些事实是本设计的回归基线。不得把自动测试替代真实人工复测。

## 3. Product Decisions

### 3.1 Conflict Has Only Two Effective States

本轮继续只使用：

```text
conflict
no_conflict
```

不增加“已解决冲突”、`alternative_choice`、`embedded_work`、`replacement` 或完整
`resolution` 状态机。

### 3.2 A Concrete User Decision Means `no_conflict`

当用户已经给出可执行取舍或明确允许共存时，该 pair 直接保存为 `no_conflict`：

```text
“选择去量子物理 B，不去电路基本理论” -> no_conflict
“这节课不听讲，课上写操作系统作业”   -> no_conflict
“两个时间段我都保留，可以共存”       -> no_conflict
```

只有用户确认这对安排仍需后续决策或调整时保存 `conflict`：

```text
“这两门课撞课了，我还没决定去哪门” -> conflict
“把这两个安排记录为冲突”           -> conflict
```

`reason` 继续保存用户的自由解释。显式 `no_conflict` 优先于时间重叠派生结果，因此：

- 周视图不显示红色冲突警告；
- `get_conflicts` 默认不返回该 pair；
- 删除显式 Relation 后恢复默认重叠 conflict；
- 不自动修改课程的 attendance policy、attendance decision 或 listening mode。

已有历史 `conflict` 行不得自动迁移为 `no_conflict`，因为无法可靠判断当时用户是否已经
作出取舍。用户再次通过 Agent 或手动编辑时正常 upsert 覆盖。

## 4. Bounded Agent Workflows

### 4.1 Participant Lookup

当关系请求包含日期和标题时，Agent 必须先按指定日期分别查询参与者：

```text
get_schedule(query="电路基本理论", from="2026-06-02", through="2026-06-02")
get_schedule(query="量子物理B", from="2026-06-02", through="2026-06-02")
create_schedule_relation(...)
```

规则：

- `get_conflicts` 只读取已经解析出的冲突 pair，不能用作参与者查找器；
- 用户已给出日期时，禁止先拉取整个学期 occurrence；
- 标题查询必须先过滤再应用结果数量上限；
- 每个标题得到唯一 occurrence 后才能创建关系；
- 0 个结果时说明未找到并请求用户修正；
- 多个结果时立即列出安全候选并询问用户；
- 歧义后不得自动扩大日期范围、按月分批或扫描整个学期；
- 完全相同的失败工具参数继续由 fingerprint 熔断；
- 达到 model/tool call budget 时明确结束，不无限显示“正在思考”。

整个学期课程概览仍使用 `view=course_summary`，不改变现有学期查询能力，也不引入任何
默认学期或 `semesterId` 硬编码。

对于 Grounding Policy 已高置信度识别的 relation mutation，第一次模型请求仍使用
`tool_choice=auto`，但从一开始就只声明关系所需的工具集合：

```text
get_schedule
get_plan_blocks
create_schedule_relation
```

这不会强迫自由聊天调用工具；它只防止明确关系写请求误用 `get_conflicts` 或无关来源工具。
关系 run 中调用 `get_schedule` 时必须提供非空 `query`；缺少标题查询条件时返回安全错误
`relation_lookup_requires_title`，不得读取整学期事件后再过滤。普通日程查询不受这条
intent-specific 约束。

### 4.2 Relation State Selection

系统提示与工具说明必须明确优先级：

1. 用户已经选择一项、允许两项共存或说明嵌套执行方式：`no_conflict`；
2. 用户明确表示尚未决定或只要求登记未解决冲突：`conflict`；
3. 无法高置信度判断：先询问，不生成确认卡。

确认卡必须显示两个安全标题、时间、拟保存状态和 reason。模型说“冲突”不自动覆盖用户
已经表达的取舍；用户的完整意图优先。

Grounding Policy 为高置信度关系措辞提供一个可选的 expected state：

```text
选择去/不去、允许共存、课上完成另一任务 -> no_conflict
尚未决定、仍需调整、明确只登记冲突       -> conflict
其他                                      -> unspecified
```

当 model tool input 与非空 expected state 冲突时，不得静默改写后直接提交；返回
`relation_state_mismatch` 和固定纠错说明，最多允许一次修正调用。用户句子同时出现“冲突”
和明确取舍时，明确取舍优先。例如“记录这两节课的冲突，我选择去量子物理 B”必须得到
`no_conflict` 确认卡。

### 4.3 Semester-backed Repeated Task Creation

典型请求：

> 我下学期电磁场与波这门课的作业每周六交，请给我每周六设置一个 Task。

该请求表示创建多个相互独立、可分别完成或取消的 Task，不表示一个重复 Task 实体。继续
复用现有 `create_task`，不新增 `TaskSeries`、recurrence 字段或批量写工具。

Agent 必须按以下顺序工作：

1. 识别“每周/每天/每月”等周期性多 Task 请求；
2. 若课程学期、起止范围、截止时刻或是否包含特殊周次不足以确定具体 Task 集合，先继续
   查询或向用户追问，不得静默采用默认值；
3. 需要从整学期课程确定边界时，调用
   `get_schedule(view="course_summary", from=..., through=...)`；禁止用普通 `events`
   视图读取整个学期 occurrence；
4. 从目标课程的 `activeFrom`、`activeThrough` 计算候选日期，并向用户说明日期范围、候选
   数量以及仍需确认的参数；
5. 用户明确确认后，对每个日期分别调用一次 `create_task`，每个 Task 拥有自己的
   `deadline_at` 和生命周期；
6. 任一 Task 被拒绝或创建失败时，不得声称整个集合均已创建；必须准确报告成功、失败和
   尚未处理的数量；
7. 不创建课程有效范围之外的 Task，也不得根据默认学期或 `semesterId` 猜测课程范围。

“进一步确认”属于业务澄清，不等同于写工具确认卡。前者用于让用户确认最终日期集合和
未明确参数；后者仍按既有风险策略逐项出现。若用户在第一张确认卡选择对此类型以后不再
确认，后续 `create_task` 可按既有权限策略继续，但 Agent 不得自行放宽权限。

现有多次 `create_task` 路径已经通过真实人工测试，本轮不修改 model/tool call budget、写
确认恢复流程或 `create_task` 提交机制。完全相同参数仍由 fingerprint 熔断；若未来真实
学期范围触发既有预算上限，再根据持久 invocation 日志单独设计，不在本轮提前扩容。

为避免首次普通大范围查询成为预期失败，`get_schedule` 增加确定性保护：无 `query`、
`view=events` 且请求跨度超过允许的 occurrence 查询窗口时，不读取并序列化整段事件，直接
返回 `schedule_summary_required`，附带改用 `view=course_summary` 或缩小日期范围的固定
指导。具体窗口阈值由一个具名常量维护，不能与默认学期或学期 ID 绑定。系统提示和工具
description 同时明确：整学期课程概览、课程规律分析以及基于课程范围生成多个 Task，都必须
优先使用 `course_summary`。提示用于引导模型，运行时错误负责确定性兜底。

## 5. Terminal Write Settlement

写意图的最终状态只由本 run 对应 terminal tool 的结构化结果决定：

- terminal tool `success`：run 以 `completed` 结束并允许成功说明；
- `user_declined`、`permission_denied`、`cancelled` 或工具 error：不保留成功说明；
- terminal tool 从未调用：最多一次受限纠错，仍无调用则 `grounding_failed`；
- terminal tool 已成功时，不能因为 lookup tool 未被计入、纠错已使用或模型最终没有再调用
  工具而改判 `grounding_failed`；
- 一个成功写操作只写一次业务数据和一次成功 ActionLog。

必须用真实验收句建立回归：

> 国庆要调课，请把 10 月 1 号的调到 9 月 26 号。

确认 `move_jw_course_day` 后，最终应报告“已移动 3 门课程”等安全结果，run 为
`completed`、`errorCode=null`。不得依赖学期 ID。

## 6. Persistent Tool Invocation Logs

### 6.1 Schema

将 App 数据库 schema 从 5 升级到 6，并为 `tool_invocations` 增加：

```text
errorCode TEXT NULL
```

保留现有字段：

```text
id
accountId
runId
toolName
status
safeArgumentsSummary
safeResultSummary
startedAt
finishedAt
```

v5 -> v6 迁移只增加 nullable 列，不改写现有业务数据。新建数据库直接拥有完整 schema。

### 6.2 Lifecycle

每个模型 `tool_use` 对应一条 invocation：

1. 执行前插入 `running`，记录脱敏参数摘要和 `startedAt`；
2. 普通结束时更新为 `success` 或 `error`，记录安全结果摘要、`errorCode`、
   `finishedAt`；
3. 等待登录或写确认时更新为 `waiting_user`，保留同一 invocation；
4. 用户确认、拒绝或取消后更新同一行，不新增一条伪重复调用；
5. App 停止或 run 被中断时，将未结束 invocation 收口为 `cancelled` 或
   `interrupted`；
6. run、消息和 invocation 必须保持相同 account 的组合外键约束。

工具日志只保存：

- 工具名；
- 状态与安全错误码；
- 参数字段名、日期范围、计数等 allowlisted 摘要；
- 安全结果摘要和耗时。

禁止保存 API Key、Cookie、Token、完整学号、数据库 ID、原始 `ref_*`、完整原始课表或
外部页面正文。当前历史运行不回填虚构 invocation。

### 6.3 Presentation

重新打开长期主会话时，按 `runId` 加载 invocation，并在对应 assistant 消息下恢复默认折叠的
“工具调用”区域。展开后只显示：

- 工具名；
- success/error/waiting/cancelled 状态；
- 安全错误码；
- 安全参数和结果摘要；
- 调用耗时。

UI 显示数量必须与该 run 的持久 invocation 数一致。`ActionLog` 继续只记录业务/权限操作，
不把只读工具调用混入操作历史；工具诊断入口属于聊天 run。

## 7. Unified Event And PlanBlock Relations

### 7.1 Participant Type

将只支持事件的 `EventConflictParticipant` 泛化为内部统一参与者：

```text
ScheduleConflictParticipant
  kind: event | plan_block
  id
  title
  startAt/endAt
  occurrenceDate
  seriesType/seriesId (optional)
```

数据库继续使用现有 `leftKind/leftId/rightKind/rightId` 和对应外键列，不新增 Relation
类型字段。

### 7.2 Supported Pairs

手动管理和 Agent 写工具统一支持：

- CalendarEvent <-> CalendarEvent
- CalendarEvent <-> PlanBlock
- PlanBlock <-> PlanBlock

pair 必须 canonicalize，反向传入不能产生第二条重复 Relation。账号隔离和目标存在性必须在
提交前再次验证。

### 7.3 Scope

- 两侧都是具有稳定系列身份的 CalendarEvent 时，可选择“本次及未来”；
- 任一侧为 PlanBlock 时，只能保存 occurrence Relation；
- PlanBlock 不伪造成 CalendarEvent，也不获得虚假的系列身份；
- Task 本身不参与时间冲突，只有进入周网格的 accepted/done PlanBlock 参与。

### 7.4 UI Entry

重叠展开窗口增加“处理重叠关系”命令。进入统一关系编辑页后：

- 列出组内每一个 pair；
- 每对可选“冲突 / 不冲突 / 暂不分类”；
- 可填写原因；
- 涉及 PlanBlock 时禁用“当前及未来”；
- 保存后立即重新投影当前周；
- `no_conflict` pair 的红色警告消失，但两个安排仍按原时间重叠展示；
- 点击课程仍进入事件详情，点击 PlanBlock 仍进入父 Task 详情。

本轮不为 PlanBlock 新增 foreground priority 持久字段。重叠组的前景项继续使用现有确定性
排序；本轮目标是能分类关系，而不是重新设计前景优先级。

## 8. Schedule-local Undo Feedback

整日课程移动成功反馈改为日程页局部浮动 Snackbar：

- 固定显示 6 秒；
- 位于底部导航栏上方；
- 在显示期间提供“撤销”；
- 离开日程页时立即关闭，不能进入聊天页；
- 连续操作先关闭旧 Snackbar，再显示最新一条，不排队；
- 不因系统 accessible-navigation 配置永久占据界面；
- Snackbar 消失不清除数据库的一步撤回快照。

失败信息使用同一局部反馈边界，但不提供伪撤销动作。

## 9. Error Handling

- `result_too_large`：保留安全错误码和建议缩小范围；关系请求已经有日期时不得扩大范围；
- `schedule_summary_required`：普通事件视图请求跨度过大；改用 `course_summary` 或缩小
  日期范围，不把这次可预防的拒绝当作来源故障；
- `reference_not_found` / `target_not_found`：要求重新查询，不写悬挂 Relation；
- `ambiguous_target`：返回安全候选并等待用户选择；
- `repeated_tool_call`：记录日志并停止相同参数循环；
- `grounding_failed`：只用于 terminal tool 从未成功执行；
- terminal write 已成功后出现模型/协议尾部异常：业务结果不得被改写为“未执行”，run 应保留
  可追踪的完成状态和已成功 ActionLog；
- 日志持久化失败不能导致业务写操作重复执行。该 run 应记录本地诊断错误，但不能重放已经成功
  的写工具。

## 10. Testing

### 10.1 Unit And Database

- v5 -> v6 迁移保留账号、事件、Relation、Task、PlanBlock、Agent 历史并新增 nullable
  `error_code`；
- invocation 从 running -> waiting_user -> success/error 使用同一行；
- invocation 账号组合外键、重置清理和中断恢复正确；
- 日志摘要不包含 `ref_*`、内部 ID、API Key 或账号；
- event/event、event/PlanBlock、PlanBlock/PlanBlock 的 conflict/no_conflict 投影；
- reverse pair upsert 不产生重复行；
- PlanBlock pair 拒绝 current-and-future。

### 10.2 Agent Session

- 指定日期和两个标题的关系请求只调用日期限定的 title query；
- 多个匹配项后停止并询问，不扩大范围；
- 已明确选择一项时确认卡使用 `no_conflict`；
- 未决定时仍可保存 `conflict`；
- terminal move 成功后 run completed；
- decline/error 后不显示成功；
- 相同失败参数熔断；
- 整学期课程规律和基于课程范围创建 Task 的请求首先使用 `course_summary`，不会先产生一次
  大范围 `events` 失败；
- 周期性多 Task 请求在日期集合或截止时刻不明确时先询问，不调用 `create_task`；
- 用户确认后按每个日期多次调用 `create_task`，每项参数和最终成功/失败计数准确；
- 现有成功的多次 `create_task` 路径保持不变，不为该场景放宽通用工具预算；
- UI 工具调用数量与持久 invocation 数量一致。

### 10.3 Widget And Integration

- CalendarEvent + PlanBlock 重叠展开后存在“处理重叠关系”入口；
- 保存 `no_conflict` 后两侧警告消失，点击详情路由不变；
- PlanBlock 的“当前及未来”控件不可用；
- 日程 Snackbar 6 秒后消失；
- 切换到聊天页时 Snackbar 立即消失且不遮挡 composer；
- 连续整日移动只显示最新反馈；
- 真实组合流程覆盖 `get_schedule -> create_schedule_relation -> no_conflict` 和
  `move_jw_course_day success -> completed`。

## 11. Manual Acceptance

使用新 Windows Release App 重测：

1. 原第 5 项：指定日期两门历史课程，工具不进行整学期扫描；有歧义即询问；
2. 选择量子物理 B 后，关系保存为 no_conflict，两节课不再显示冲突警告；
3. 课程时间内安排 PlanBlock，从重叠展开页将该 pair 标为 no_conflict，警告消失；
4. 原第 12 项：整日移动后 Snackbar 不进入聊天页，6 秒后自动消失；
5. 原第 16 项：确认整日移动后只报告成功，不再出现 grounding_failed；
6. 操作历史和本地工具日志能看到安全的工具名、次数、状态、错误码和耗时；
7. 日志中不包含密钥、账号、内部 ID、原始 ref 或完整课表。
8. 新增周期 Task 测试：询问“下学期电磁场与波作业每周六交”时，Agent 不先读取整学期
   occurrence；它使用课程摘要、说明候选范围并询问缺失参数。用户确认后，为范围内各周六
   创建独立 Task，并准确报告创建结果。

人工结果继续写入用户验收文档的“完成：”字段。自动测试不得代替真实学校 API、校园网、
确认卡和 Release UI 验收。

## 12. Non-goals

- 不实现完整 relationType / resolution 状态机；
- 不自动写课程 attendance/listening overlay；
- 不改变 Task 状态模型或 PlanBlock 生命周期；
- 不新增重复 Task、TaskSeries 或批量 Task 写工具；周期性请求由多个现有 `create_task`
  调用实现；
- 不修改 Python 来源、Bridge、SourceBundle 或校园目录迁移；
- 不实现二课报名/取消；
- 不修改默认学期或硬编码任意 semesterId；
- 不回填历史 invocation；
- 不处理公开引用 chip、iCourse 授权或校园目录第 13-15 项。

## 13. Completion Criteria

- 上述新增测试先失败后通过；
- 全量 Flutter analyze/test 和 Windows Release build 通过；
- 数据库迁移测试覆盖 v5 -> v6；
- Python 未修改时仍运行现有全量测试与 compileall，确认跨层无回归；
- 真实复测第 5、12、16 项及 mixed PlanBlock relation 均有用户填写结果；
- 新增整学期课程驱动的周期 Task 人工测试有用户填写结果；
- 交接文档记录精确 HEAD、真实测试输出、仍未执行的人工验收和未解决边界。
