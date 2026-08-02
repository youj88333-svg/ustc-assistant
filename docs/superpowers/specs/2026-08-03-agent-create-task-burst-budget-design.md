# Agent 多 Task 动态调用额度设计

> 日期：2026-08-03
>
> 状态：待主人审核
>
> 范围：保留多次 `create_task`，为明确的多 Task 请求提供一次性动态调用额度，并准确汇总
> 部分成功结果。不新增批量写工具或 TaskSeries。

## 1. 背景与问题

`AgentSessionService` 当前对每个 run 设置：

```text
maxModelCalls = 8
maxToolCalls = 12
```

该限制的初衷是阻止模型因错误不断重试。但合法任务也可能自然超过 12 次工具调用，例如：

> 电磁场与波作业连续 13 周每周六截止，请分别为每周创建一个 Task。

在继续使用多个独立 Task 和多次 `create_task` 的产品模型下，仅 13 次写工具就超过总工具
额度，还没有计算课程摘要和其他必要读取。当前运行会在合法工作尚未完成时返回
`tool_call_budget_exceeded`。

此外，当前 terminal attempt 主要按工具名称保存结果。连续调用同一个 `create_task` 时，后一次
结果可能覆盖前面的结果，产生以下错误终态：

- 前 12 项成功、最后一项失败，却显示“没有修改数据”；
- 早期某项失败、最后一项成功，却接受模型“全部成功”的描述；
- 已经写入的 Task 数量无法由 Runtime 确定性汇总。

## 2. 已选方案

采用一次性 `create_task` Burst Lease：

- 普通工具调用额度继续是 12；
- 模型调用额度继续是 8；
- 明确的多 Task 创建请求可以在一个 provider tool-use turn 中获得最多 32 次
  `create_task` 专用额度；
- 每个 run 最多激活一次 Lease；
- Lease 只覆盖激活它的这一批 `create_task`，不能被其他工具使用；
- 每个 Task 仍通过一次独立 `create_task` 创建，保留独立完成、取消和删除语义；
- 允许部分成功，不回滚已经成功的独立 Task。

## 3. 实施依赖与顺序

本设计与 `2026-08-03-agent-date-bounded-relation-lookup` 计划都会修改：

- `AgentGroundingPolicy`；
- `AgentSessionService`；
- `AgentSystemPrompt` / `AgentContextBuilder`；
- Agent session、grounding 和 integration tests。

因此必须按以下顺序实施：

1. 先完成并验证 `docs/superpowers/plans/2026-08-03-agent-date-bounded-relation-lookup.md`；
2. 在其最终 HEAD 上为本设计编写实施计划并执行；
3. 不允许两个实现者在不同分支并行修改上述文件后再机械合并。

若前一计划尚未实施，本设计只提交 Spec 和 Plan，不提前修改生产代码。

## 4. 目标

1. 13 个不同日期的合法 `create_task` 可以在一个 run 内完成，不触发普通工具上限。
2. 普通请求仍受 12 次工具调用限制，不能借用 Burst 额度。
3. 同一个 run 只能获得一次、最多 32 次 `create_task` 专用额度。
4. 保留每次 `create_task` 的参数校验、风险策略、确认、事务和 ActionLog。
5. 聚合一批调用的成功、拒绝和错误数量，生成确定性的真实终态。
6. 已成功创建的独立 Task 在同批其他项失败时保留，不做跨 Task 回滚。
7. 不依赖默认学期或任何 `semesterId`。

## 5. 非目标

- 不新增 `create_tasks`、`batch_create_task` 或其他批量写工具。
- 不新增 TaskSeries、recurrence、重复 Task 实体或课程作业模板。
- 不把一批独立 `create_task` 包装进一个数据库事务。
- 不自动跨 run 续建超过 32 项的请求。
- 不让其他读写工具使用 Burst 额度。
- 不取消 `repeated_tool_call` 指纹保护。
- 不提高 `maxModelCalls=8`。
- 不改变现有 Task 数据模型、SourceBundle、Python、Bridge 或移动端契约。

## 6. 预算模型

### 6.1 两类独立额度

每个 run 维护两个计数域：

```text
normalToolCalls: 最大 12
leasedCreateTaskCalls: 最大 32，仅在 Lease 激活后存在
```

行为如下：

- Burst 之前的课程摘要、Task 查询等工具计入 `normalToolCalls`；
- 激活 Burst 的纯 `create_task` turn 计入 `leasedCreateTaskCalls`，不消耗普通额度；
- Burst 完成后的其他工具继续使用尚未消耗的普通额度；
- 总绝对上限因此是 44 个工具块，但只有最多 32 个可以来自唯一的 Lease；
- provider 的最终无工具回答不计入工具额度，但仍计入 8 次模型调用上限。

### 6.2 Lease 仅覆盖一个 tool-use turn

Lease 不是可反复充值的余额。它绑定到模型一次响应中同时发出的 `create_task` tool-use blocks：

```text
course_summary 等普通调用
-> 模型一次发出 N 个 create_task（2 <= N <= 32）
-> Runtime 激活一次 Lease 并顺序执行这 N 项
-> 模型读取 N 个 tool_result 后给出最终回答
```

后续 provider turn 再次发出的 `create_task` 不得激活第二个 Lease，只能使用剩余普通额度。

## 7. Lease 启用条件

以下条件必须全部成立：

1. 当前 Grounding Requirement 明确允许多 Task 创建；
2. 主终端写工具是 `create_task`；
3. 当前 provider turn 的所有工具块都是 `create_task`；
4. 当前 turn 至少包含 2 个、最多包含 32 个工具块；
5. 当前 run 尚未使用 Lease；
6. 每个调用继续通过 `WriteArgumentReader`、权限策略和确认流程。

Grounding Requirement 增加不可持久化的运行时元数据：

```dart
final int? createTaskBurstLimit;
```

普通请求为 `null`；明确的周期/多项 Task 创建请求为 `32`。

推荐识别的高置信文本包括：

```text
每周/每星期/每个周六创建一个 Task
连续 13 周分别创建 Task
这些日期各建一个 Task
为每个候选日期创建独立任务
```

单个 Task、能力询问、建议讨论、删除/修改 Task 和只有“每周”但没有创建意图的句子不获得
Lease。

## 8. 模型调用方式

系统提示要求：

1. 先用 `course_summary` 或其他窄范围读取确定课程有效范围；
2. 日期、截止时间或特殊周次不明确时，先询问或通过现有写确认卡让用户确认候选项；
3. 候选列表确定后，在同一个模型响应中发出全部 `create_task` tool-use blocks；
4. 不能每个 provider turn 只发一个 `create_task`，否则会先撞到 8 次模型调用上限；
5. 每个 Task 参数必须独立、完整，截止日期不同；
6. 收到全部 tool results 后再总结，不能在执行前声称创建成功。

多个 tool-use blocks 仍由 Runtime 顺序处理。需要确认时，确认卡按当前策略逐个出现；用户已
主动放宽该风险类型时沿用现有策略。本设计不新增统一批量确认卡。

## 9. Burst Preflight

Runtime 在执行该 provider turn 的第一个工具块之前检查整批结构。

### 9.1 合法批次

当 2 至 32 个工具块全部是 `create_task` 且 Grounding 允许 Burst 时：

- 创建一个内存 Lease；
- `plannedCount` 等于该 turn 的 `create_task` 数量；
- 按原始顺序执行每项；
- 每项建立独立 invocation lifecycle row；
- 每项生成自己的 `tool_result`。

### 9.2 超过 32 项

当同一 turn 包含 33 项或更多 `create_task`：

- 在任何业务写入前拒绝整批；
- run 返回 `create_task_burst_too_large`；
- guidance 明确“每个 run 最多 32 项，请拆分后由用户继续”；
- 不执行前 32 项后静默丢弃剩余项；
- 为收到的 tool-use blocks 写入安全的 blocked/error invocation 记录，不能把原始标题或 refs
  写入日志；
- 不向 provider 发起无穷纠错或第二次 Lease。

### 9.3 混合工具 turn

当一个超过普通剩余额度的 turn 同时包含 `create_task` 和其他工具：

- 不激活 Lease；
- 在任何该 turn 的写入前返回 `create_task_burst_requires_dedicated_turn`；
- guidance 要求先完成读取，再在下一模型响应中只发 `create_task`；
- 防止先执行部分 Task 后才因混合工具撞到普通上限。

### 9.4 不符合 Grounding

没有明确多 Task 创建意图时，多个 `create_task` 继续消耗普通额度。模型不能仅通过一次发出
多个工具块自行获得权限扩张。

## 10. 重复调用保护

Burst 不替代 fingerprint 防护：

- 完全相同的 `create_task` 参数仍返回 `repeated_tool_call`；
- 标题相同但截止日期不同属于不同 Task，不视为重复；
- 重复调用仍占用该批的 `plannedCount`，并计入 errorCount；
- Lease 不因重复错误增加额度；
- 同一 run 不允许通过第二批修正重复项，用户可在下一次请求中只补建失败项。

## 11. 内存状态与结果聚合

Lease 只在当前 run 内存在，不写入数据库：

```dart
class _CreateTaskBurstLease {
  _CreateTaskBurstLease({required this.plannedCount});

  final int plannedCount;
  int processedCount = 0;
  int successCount = 0;
  int declinedCount = 0;
  int errorCount = 0;
  final Map<String, int> safeErrorCounts = {};
}
```

每个 `create_task` 结束后，根据结构化 `AgentToolResult` 更新计数。`safeErrorCounts` 只保存
低敏感错误码及数量，不保存 Task 标题、描述、日期列表、数据库 ID 或 ref。

现有 terminal mutation attempt 不能继续只按工具名覆盖最后一次调用。Burst 的完整结算以
Lease 聚合值为权威；普通单次写工具仍使用现有 terminal attempt 语义。

## 12. 终态规则

### 12.1 全部成功

```text
plannedCount == successCount
declinedCount == 0
errorCount == 0
```

Runtime 接受模型最终回答，run 状态为 `completed`。模型必须准确报告创建数量。

### 12.2 部分成功

至少一个 Task 成功，同时至少一个被拒绝或失败：

- 保留成功写入和每项 ActionLog；
- 不回滚；
- run 使用现有 `AgentRunState.failed`，安全错误码为 `create_task_burst_partial`；聊天中必须
  持久化并显示下面的确定性部分成功消息，不能退化为“请求失败，未生成回答”；
- Runtime 使用结构化计数覆盖可能虚假的模型结论；
- 固定消息示例：

```text
已创建 12 个 Task，1 个未完成。其中 1 个已取消。
```

或：

```text
已创建 11 个 Task，2 个未完成。失败原因：target_not_found 1 个，repeated_tool_call 1 个。
```

不得显示“没有修改数据”或“全部创建成功”。

### 12.3 全部未成功

`successCount == 0` 时：

- run 为失败；
- 错误码为 `create_task_burst_failed`，或在整批 preflight 阶段使用更具体的安全错误码；
- 明确报告“未创建任何 Task”及取消/失败数量；
- 不根据模型文字推断是否成功。

### 12.4 结果不完整

如果 run 被用户 Stop、应用退出或上游协议错误中断：

- 已提交的独立 Task 保留；
- 已完成 invocation lifecycle 不改写；
- 尚未开始的工具块记为 cancelled/interrupted；
- 重启后可从逐项工具诊断和本地 Task 查看已完成结果，但本轮不新增跨重启的 Lease 汇总
  重建器；
- 不自动重放未执行的写工具，用户通过新请求明确补建剩余项。

## 13. 额度耗尽后的行为

- 合法 Burst 内的第 13 至第 32 个 `create_task` 不触发 `tool_call_budget_exceeded`；
- 普通额度耗尽仍使用现有 `tool_call_budget_exceeded`；
- Lease 用完后不得自动续租；
- 第二个 Burst turn 返回 `create_task_burst_already_used`；
- 用户需要创建超过 32 项时，Agent 先说明拆分范围并取得用户对首批最多 32 项的明确同意；
  当前 run 只处理该首批，剩余项必须由用户发起新的明确请求；
- Runtime 不自动跨 run 继续写入。

## 14. 自动测试要求

### 14.1 Grounding

- “连续13周每周六分别创建Task”得到 `createTaskBurstLimit == 32`；
- 单个 Task 创建的 Burst limit 为 null；
- 仅询问“每周作业怎么安排”不触发写 Grounding；
- `create_task` 仍是唯一 terminal write；
- 不开放其他写工具。

### 14.2 Budget Preflight

- 2、13、32 个纯 `create_task` blocks 可以激活一次 Lease；
- 33 个在任何 gateway write 前返回 `create_task_burst_too_large`；
- 超普通剩余额度的混合 turn 在任何写入前返回
  `create_task_burst_requires_dedicated_turn`；
- 第二批返回 `create_task_burst_already_used`；
- 普通非 Burst run 仍在第 13 个工具块触发原上限；
- 8 次模型调用上限保持不变。

### 14.3 Result Aggregation

- 13/13 success -> completed；
- 12 success + 1 declined -> 保留 12 行，固定部分成功摘要；
- 12 success + 1 error -> 保留 12 行，记录安全错误计数；
- 0 success + 13 declined -> 未创建任何 Task；
- 第 13 次结果不能覆盖前 12 次；
- 相同参数重复调用返回 `repeated_tool_call` 并进入 errorCount；
- Stop/中断后已成功 Task 保留，未开始项不重放。

### 14.4 Composition

使用真实本地 Drift gateway 和脚本化 provider：

1. `course_summary` 取得 13 周候选范围；
2. 下一 provider turn 同时发出 13 个不同 deadline 的 `create_task`；
3. 每项通过现有确认/事务；
4. 数据库最终有 13 个独立 Task；
5. invocation 记录有 13 个独立 `create_task` 生命周期；
6. run 不出现 `tool_call_budget_exceeded`；
7. 账号切换后另一个账号看不到这些 Task 或 invocation。

## 15. 人工验收

在真实 Windows Release、学校模型和校园网/iWAN 环境中发送：

> 电磁场与波作业连续13周每周六截止，请根据这门课的有效周次分别创建独立Task。

预期：

- Agent 先查询课程摘要，不读取整学期详细 occurrences；
- 说明候选日期和数量；
- 在一个工具调用组中出现 13 个 `create_task`；
- 每项仍按当前权限策略确认；
- 最终创建 13 个独立 Task，不出现第 13 项预算错误；
- 工具日志可以看到 13 次独立状态，但不泄露标题参数、账号或内部 ID；
- 人为取消其中一项时，其他成功项保留，最终准确报告数量。

## 16. 安全与兼容

- Burst 只扩大工作预算，不扩大写权限；风险策略和确认流程保持权威。
- 用户曾放宽 `create_task` 确认时沿用现有设置，该选择不扩大到其他工具。
- 所有 invocation 继续使用安全参数/结果摘要。
- Burst 状态不持久化，因此应用重启后不会自动继续未完成写入。
- 不改变数据库 schema、Task 表、ActionLog schema 或 Agent tool schema。
- 不发送完整课表、完整任务列表或用户身份给模型。
- 不根据年份推算教务学期 ID。

## 17. 残余边界

Runtime 能确定性保证“模型实际发出的这一批调用”是否全部执行并准确汇总，但不能仅凭工具
数量证明模型已经覆盖用户语义中的全部 13 个日期。完整性仍由：

- `course_summary` 返回的课程有效范围；
- versioned system prompt 的日期枚举规则；
- 组合测试中的 13 个预期 deadline；
- 用户在确认卡和最终摘要中的人工检查

共同约束。本轮不引入批量清单签名、TaskSeries 或新的预规划持久化协议。

## 18. 完成标准

1. 13 项真实工作流在一个 run 内完成且不触发普通工具额度错误。
2. Burst 最多 32 项、每个 run 一次、仅限纯 `create_task` turn。
3. 33 项和混合超额 turn 均在任何业务写入前失败。
4. 部分成功保留已创建 Task，并由 Runtime 确定性报告计数。
5. 重复指纹、普通 12 次额度和 8 次模型额度均无回归。
6. 完整 Flutter 测试、analyze 和 Windows Release 构建通过；真实人工验收结果由主人填写，
   不以自动测试代替。
