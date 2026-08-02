# Agent 单日关系查询与任务规划工具编排设计

> 日期：2026-08-03
>
> 状态：待主人审核
>
> 范围：只修复关系请求按明确日期取得事件，以及同一句话中由 LLM 顺序调用现有任务规划
> 工具。不新增复合状态机、批量工具或数据库字段。

## 1. 背景与问题

真实请求：

> 在9月1号上午第一节课我想再写一门生命科学简史课作业，你只要帮我安排在这个时间段，
> 具体事件我自己把握，并标记为不冲突。

本地数据中，2026-09-01 实际存在三个课程事件，其中第一节为 07:50-09:25 的“计算机
网络”。本次 Agent run 仍以 `protocol_error` 失败：11 次工具调用中 8 次失败，
`relation_lookup_requires_title` 出现 5 次，且没有调用 `plan_task` 或
`create_schedule_relation`。

根因有两个：

1. 关系运行把所有不含 `query` 的 `get_schedule` 调用提前拒绝，即使 `from` 与
   `through` 已限定为同一天，也无法取得当天事件引用。
2. 关系意图的初始工具声明只有 `get_schedule`、`get_plan_blocks` 和
   `create_schedule_relation`。原请求还明确要求安排已有 Task，但 `get_tasks` 与
   `plan_task` 没有被可靠地提供给模型。

`get_schedule` 的安全调用摘要会隐藏自由文本 `query`。因此日志中显示参数只有日期、结果
却为空的成功调用，表示模型很可能改为猜测课程标题查询；这不能用于判断单日事件查询已经
成功。

## 2. 目标

1. 关系运行可以用“课程标题”或“明确单日范围”取得具体 CalendarEvent 引用。
2. 用户同时要求安排已有 Task 并建立关系时，LLM 可以顺序调用现有工具完成请求。
3. 保留关系查询的范围保护，禁止无标题的大范围详细课次扫描。
4. 保留现有写确认、权限策略、事务、ActionLog、引用隔离和隐私摘要。
5. 保持学期无关，不读取、推算或硬编码任何 `semesterId`。

## 3. 非目标

- 不新增“复合请求”状态机或新的复合写工具。
- 不把 `plan_task` 与 `create_schedule_relation` 合并为一个数据库事务。
- 不新增 TaskSeries、重复 Task、批量 Task 或 PlanBlock recurrence。
- 不为 `get_schedule` 新增节次、开始时间或结束时间参数。
- 不改变 Relation、Task、PlanBlock、SourceBundle 或移动端契约。
- 不允许 LLM 在找不到已有 Task 时静默创建新 Task。
- 不取消关系运行的工具范围限制，也不向其开放全部写工具。

## 4. 单日关系事件查询

### 4.1 可接受的具体事件查询

关系运行中的 `get_schedule` 仅在以下任一条件成立时允许进入现有工具实现：

1. `query` 是非空标题文本，并且 `view` 为 `events` 或省略；
2. `from` 与 `through` 都存在、是同一个日期，并且 `view` 为 `events` 或省略。

第二种形式返回该账号在该日的全部有效事件及 run-local event refs。模型使用返回的
`startAt`、`endAt`、标题和类型识别“第一节课”“上午某节课”或指定时段中的事件，不猜测
课程名。

日期格式、反向范围、事件数量上限和账号隔离仍由现有 `GetScheduleTool` 校验。关系层只判断
查询是否有足够边界，不重复实现日程解析。

### 4.2 继续拒绝的请求

以下关系查询在读取事件前返回 `relation_lookup_requires_bound`：

- 没有标题，也没有同时提供 `from`、`through`；
- 没有标题，且 `from`、`through` 不是同一天；
- 使用 `view=course_summary` 试图取得具体关系参与方。

固定 guidance：

> 关系参与方需要具体事件引用。请提供事件标题，或把 from/through 限定为同一天并使用
> view=events；不要读取整学期详细事件后再过滤。

这取代含义过窄的 `relation_lookup_requires_title`。旧错误码只存在于历史工具日志，不做
数据库迁移或历史改写。

### 4.3 多个同时间事件

如果单日结果中只有一个事件覆盖用户指定时段，模型可以直接使用该 event ref。

如果两个或更多事件都覆盖该时段，且用户没有明确“全部标为不冲突”或指定标题，模型必须
先列出安全标题和时间并询问关系作用对象。不得任意选择其中一个，也不得自动为所有 pair
写关系。

## 5. 条件开放现有任务规划工具

### 5.1 不引入复合状态机

Grounding 的主意图仍是 `create_schedule_relation`，预期关系状态仍按用户话语确定。本例的
“标记为不冲突”产生 `ExpectedConflictState.noConflict`。

分类器额外检查同一消息是否包含明确的已有 Task 规划语义，例如“把某作业安排在这个时间
段”“课上写某作业”。只有关系意图与任务规划语义同时成立时，关系运行的工具声明扩展为：

```text
get_tasks
get_schedule
plan_task
get_plan_blocks
create_schedule_relation
```

普通 event/event、已有 event/PlanBlock 和 PlanBlock/PlanBlock 关系请求继续只声明原来的
三个关系工具。不能因为一句话出现“作业”就开放 `create_task`。

### 5.2 LLM 顺序编排

对本例，模型应执行：

```text
get_tasks
get_schedule(from=2026-09-01, through=2026-09-01, view=events)
plan_task
等待 plan_task 的现有权限/确认流程完成
get_plan_blocks(taskRef=<本轮 get_tasks 返回的引用>)
create_schedule_relation(conflict_state=no_conflict)
等待 relation 的现有权限/确认流程完成
最终总结
```

`get_tasks` 与单日 `get_schedule` 是互不依赖的只读调用，可以由模型在同一轮发出。
`plan_task` 与 `create_schedule_relation` 存在引用依赖，禁止并行：新 PlanBlock 只有提交成功
后，才能通过 `get_plan_blocks` 获得本轮有效引用并写关系。

每个写工具独立遵守现有风险策略。需要确认时可出现两张顺序确认卡；已被用户按类型放宽的
普通写操作沿用现有策略。本设计不增加绕过确认的路径。

### 5.3 Grounding 与终态

主终态仍由 `create_schedule_relation` 决定，因此不新增多终端工具状态机。对于“先创建
PlanBlock，再建立其关系”的请求，关系成功天然要求 PlanBlock 已存在并能取得引用。

终态文案必须反映真实部分结果：

- 两次写入均成功：报告已安排 PlanBlock，并已标记为不冲突；
- `plan_task` 被取消或失败：不得继续创建关系，报告未创建 PlanBlock；
- `plan_task` 成功、关系被取消或失败：保留已创建的 PlanBlock，明确报告关系未保存；
- 任何分支都不能用 `grounding_failed` 或笼统 `protocol_error` 覆盖已经成功的业务写入。

## 6. 提示词约束

系统提示增加以下稳定规则：

1. 用户通过日期与节次/时间指明关系参与方但未给标题时，使用精确单日
   `get_schedule(view=events)`，不要猜课程名。
2. 同一时段有多个候选事件时先询问，除非用户明确指定标题或全部对象。
3. “安排已有 Task 并标记关系”使用现有工具顺序完成；依赖后续引用的写工具不能并行。
4. 找不到唯一 Task 时列出候选并询问，不创建新 Task。
5. PlanBlock 成功但 Relation 未成功时必须报告部分完成，不得虚报整句请求完成。

## 7. 错误处理

| 场景 | 行为 |
| --- | --- |
| 缺少标题且不是精确单日 | `relation_lookup_requires_bound` |
| 精确单日没有事件 | 告知该日没有候选事件，停止写入 |
| 指定时段有多个候选事件 | 询问用户选择，不写 Relation |
| Task 无匹配 | 询问 Task 标题或是否另行创建，不自动创建 |
| Task 多匹配 | 展示安全标题/截止时间候选并询问 |
| `plan_task` 取消/失败 | 不调用依赖其结果的关系写工具 |
| PlanBlock 已创建但关系失败 | 保留 PlanBlock，并准确报告部分完成 |
| 模型重复相同失败调用 | 保留现有 `repeated_tool_call` 保护 |

## 8. 自动测试要求

### 8.1 Grounding 与声明

- 原始请求分类为关系写入，expected state 为 `no_conflict`；
- 原始请求的声明恰好包含五个所需工具，不包含 `create_task` 或其他写工具；
- 单纯已有两项关系请求仍只包含三个关系工具；
- 自由聊天与只读查询不受影响。

### 8.2 单日查询保护

- 关系运行的无标题同日 `from/through` 会实际执行 `GetScheduleTool` 并返回 refs；
- 无标题无日期、缺一端日期、多日范围和 `course_summary` 返回
  `relation_lookup_requires_bound`，且不读取事件；
- 标题查询继续工作；
- 普通非关系运行的日期查询和 31 天详细事件上限保持不变。

### 8.3 会话组合流程

使用脚本化 provider 和真实本地工具组合覆盖：

1. 原始请求读取已有 Task 与 2026-09-01 当日三个事件；
2. 通过 07:50-09:25 定位唯一课程，不依赖课程标题查询；
3. `plan_task` 经确认成功；
4. 再查询该 Task 的 PlanBlock；
5. `create_schedule_relation(no_conflict)` 经确认成功；
6. 最终 run 完成，只生成一个 PlanBlock 和一条 canonical Relation；
7. 调用链不出现 `relation_lookup_requires_title`、重复查询或尾随
   `protocol_error`；
8. 分别覆盖第一次确认取消、第二次确认取消和关系写入失败的真实部分结果。

## 9. 人工验收

在新构建的 Windows Release App 中使用真实学校模型发送原始请求，预期：

- Agent 先取得已有“生命科学简史课作业”和 9 月 1 日当天事件；
- 不要求用户补充“计算机网络”名称，也不猜测该名称；
- 第一节课程由返回时间确定；
- 顺序完成 PlanBlock 与 `no_conflict` Relation 的现有确认流程；
- 日程页同时显示课程和 PlanBlock，二者仍重叠但不再显示冲突警告；
- 工具日志次数有限、状态真实，不出现标题限制错误、重复调用风暴或最终协议错误。

如果测试日期同一时段存在多个课程，Agent 应先询问要和哪些课程建立关系，此结果也视为
正确行为。

## 10. 兼容与安全边界

- 不迁移数据库，不修改历史 invocation 错误码。
- 不改变 run-local refs，模型和日志仍不得看到数据库 ID。
- 安全参数摘要继续隐藏标题 `query`、Task ref 和 PlanBlock ref。
- 不向学校模型发送完整课表，只返回该单日、当前账号、当前请求所需的规范化事件。
- 不新增学校或外部写操作；所有写入仍只修改本地数据。
- 不修改 Python、Bridge、SourceBundle、默认学期或移动端适配边界。

## 11. 完成标准

1. 原始请求的自动组合测试通过，并在真实 Release 中完成一次人工验收。
2. 精确单日关系查询可以返回当天事件，缺少充分边界的查询仍在读取前失败。
3. LLM 使用五个现有工具顺序完成复合请求，不新增复合状态机或工具。
4. 取消、失败和部分成功均有真实终态，不产生虚假成功或覆盖已成功写入。
5. Agent、日程、数据库迁移与完整 Flutter 测试无回归；自动测试仍不访问学校 API。
