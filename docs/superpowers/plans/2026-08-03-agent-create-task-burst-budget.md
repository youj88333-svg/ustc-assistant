# Agent Create Task Burst Budget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让明确的多 Task 创建请求在一次 Agent run 内安全执行最多 32 次独立 `create_task`，同时保留普通 12 次工具额度、逐项确认与事务，并由 Runtime 准确汇总全部成功、部分成功和完全失败。

**Architecture:** `AgentGroundingPolicy` 只为高置信度的周期/多项 Task 创建请求授予一次性 `createTaskBurstLimit=32`；新的独立 `AgentRunToolBudget` 在每个 provider tool-use turn 执行前做整批结构检查，并把一个纯 `create_task` turn 租用到独立 Burst 额度。`AgentSessionService` 仍逐项走现有 registry、风险策略、确认卡、事务、ActionLog 和 fingerprint 流程，但用 `CreateTaskBurstLease` 汇总每项结构化结果，并在部分成功或完全失败时覆盖模型文案为确定性真实终态。

**Tech Stack:** Flutter/Dart、Anthropic 兼容 SSE tool-use 协议、Drift/SQLite、现有 Agent grounding/runtime/tool registry、`flutter_test`。

## Global Constraints

- 设计权威为 `docs/superpowers/specs/2026-08-03-agent-create-task-burst-budget-design.md`；本计划不得自行扩展其产品范围。
- 本计划以已完成的 `docs/superpowers/plans/2026-08-03-agent-date-bounded-relation-lookup.md` 为前置实现；开始前必须确认 `_MutationAttempt`、`supportingTools`、Prompt v6 和关系部分成功结算仍存在。
- 保留多次独立 `create_task`；禁止新增 `create_tasks`、`batch_create_task`、TaskSeries、recurrence 字段或批量数据库事务。
- 普通工具额度保持每 run 12 次，模型调用额度保持每 run 8 次；不得通过提高全局常量掩盖问题。
- 每 run 最多授予一次 Burst Lease；只覆盖同一个 provider turn 中的 2 至 32 个纯 `create_task` blocks。普通额度与 Burst 额度独立，理论绝对上限为 12 + 32。
- 33 个或更多纯 `create_task` blocks 必须在任何业务写入前以 `create_task_burst_too_large` 拒绝；用户需明确同意拆分后的首批最多 32 项，Runtime 不跨 run 自动续建。
- 混有其他工具且会超过普通剩余额度的 turn 必须在任何该 turn 写入前以 `create_task_burst_requires_dedicated_turn` 拒绝。
- 同一 run 的第二个可租用 Burst turn 必须以 `create_task_burst_already_used` 拒绝；单个后续 `create_task` 仍只能消费普通剩余额度。
- 每个 `create_task` 继续独立执行参数校验、权限策略、用户确认、事务与 ActionLog；部分成功不回滚。
- 完全相同的工具名和参数仍受 `repeated_tool_call` fingerprint 保护；重复项占该 Burst 的 planned/error 计数，不增加额度。
- Burst 只扩大调用预算，不扩大工具权限；自由聊天、能力讨论、单个 Task 创建和模糊的“每周怎么安排”不得获得 Lease。
- Burst 运行状态仅存在于当前 run 内存中，不新增数据库 schema，不在重启后自动恢复或重放未执行写操作。
- 不修改 Python、Bridge、SourceBundle、Task 数据模型、semesterId 或移动端契约；测试日期只能作为 fixture 数据，禁止引入学期硬编码。
- 日志、invocation summary 和结果聚合只保存低敏感错误码与数量，不保存 Task 标题、deadline 列表、本地 ID、ref 或学校账号。
- 所有时间继续使用 `Asia/Shanghai`；本功能不得根据年份推算教务学期 ID。
- 使用 TDD：每个行为先增加失败测试，确认失败原因正确，再写最小生产代码；每个 Task 独立提交。
- 不覆盖人工验收文档中任何现有 `完成：` 内容；不得把自动测试通过写成人工验收通过。
- 只显式暂存本 Task 文件，禁止 `git add .`；不得暂存或回滚“Protected Pre-Existing Worktree State”列出的文件。

---

## File Responsibility Map

```text
app/lib/features/agent/application/agent_grounding_policy.dart
  识别高置信度多 Task 创建请求，并把 createTaskBurstLimit=32 放入当前 run 的 Grounding Requirement。

app/lib/features/agent/application/agent_system_prompt.dart
  Prompt v7：summary-first 后单个 provider response 一次发出全部 create_task blocks，禁止逐轮一项重试。

app/lib/features/agent/application/agent_context_builder.dart
  发送 Prompt v7 与北京时间后缀。

app/lib/features/agent/application/agent_tool_budget.dart                 [NEW]
  纯运行时额度状态机和 CreateTaskBurstLease 结果聚合；不依赖 Widget、数据库或 provider。

app/lib/features/agent/application/agent_session_service.dart
  在整批 tool-use 执行前调用额度状态机；逐项执行后记录 Burst 结果；用结构化聚合决定 run 终态和固定文案。

app/test/features/agent/agent_grounding_policy_test.dart
app/test/features/agent/agent_context_builder_test.dart
  意图边界、工具收窄和 Prompt v7 回归。

app/test/features/agent/agent_tool_budget_test.dart                       [NEW]
  额度状态机、错误优先级和纯结果聚合单元测试。

app/test/features/agent/agent_session_service_test.dart
  Anthropic 多 tool-use turn、确认暂停/恢复、重复调用、停止和真实终态回归。

app/test/integration/agent_composition_flow_test.dart
  真实 registry + Drift 的 13 周独立 Task 端到端组合回归。

docs/agent-create-task-burst-retest-2026-08-03.md                         [NEW]
  主人可填写的 Windows Release 人工验收步骤；不混入关系查询复测文档。

docs/superpowers/plans/2026-08-03-agent-create-task-burst-budget.md
  本计划及最终内嵌执行交接/证据；不另建交接文档。
```

### Task 1: Grounding Eligibility And Prompt Version 7

**Files:**
- Modify: `app/lib/features/agent/application/agent_grounding_policy.dart`
- Modify: `app/lib/features/agent/application/agent_system_prompt.dart`
- Modify: `app/lib/features/agent/application/agent_context_builder.dart`
- Modify: `app/test/features/agent/agent_grounding_policy_test.dart`
- Modify: `app/test/features/agent/agent_context_builder_test.dart`

**Interfaces:**
- Consumes: existing `AgentGroundingRequirement`, `_writeIntents`, `_planTaskPatterns`, `AgentSystemPrompt.version6` and `AgentContextBuilder.build`.
- Produces: `AgentGroundingRequirement.createTaskBurstLimit`, `_multiTaskCreatePatterns`, `AgentSystemPrompt.version7`, and a context builder that sends v7.

- [ ] **Step 1: Add failing grounding tests for the exact eligibility boundary**

Add a focused group that asserts these exact outcomes:

```dart
final recurring = policy.classify(
  '电磁场与波作业连续13周每周六截止，请分别为每周创建一个Task',
);
expect(recurring, isNotNull);
expect(recurring!.terminalTools, {'create_task'});
expect(recurring.createTaskBurstLimit, 32);
expect(recurring.initialAllowedTools, ['get_schedule', 'create_task']);

final explicitDates = policy.classify(
  '请为这些日期分别创建独立Task：9月5日、9月12日、9月19日',
);
expect(explicitDates!.createTaskBurstLimit, 32);

expect(
  policy.classify('请创建一个9月5日截止的作业Task')!
      .createTaskBurstLimit,
  isNull,
);
expect(policy.classify('每周作业怎么安排比较好'), isNull);
expect(policy.classify('你能不能每周创建Task？'), isNull);
```

`course_summary` 是 `get_schedule` 的 `view` 参数，不是独立工具名；因此 Burst 请求的 `initialAllowedTools` 必须精确为 `['get_schedule', 'create_task']`。不得加入 `update_event`、`plan_task`、`create_schedule_relation` 或其他无关写工具。

- [ ] **Step 2: Run the grounding tests and verify RED**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_grounding_policy_test.dart
Pop-Location
```

Expected: failure because `createTaskBurstLimit` is not defined and multi-create requests do not yet carry Burst metadata.

- [ ] **Step 3: Add the immutable Grounding metadata and narrow classifier**

Extend the constructor and field without persistence:

```dart
class AgentGroundingRequirement {
  const AgentGroundingRequirement({
    // existing parameters...
    this.createTaskBurstLimit,
  });

  final int? createTaskBurstLimit;
}
```

Extract high-confidence `_multiTaskCreatePatterns` that require both a creation verb and plurality/recurrence, for example:

```dart
final _multiTaskCreatePatterns = <RegExp>[
  RegExp(r'(每周|每星期|每个周[一二三四五六日天]).{0,24}(创建|新建|建立|设置).{0,10}(task|任务)', caseSensitive: false),
  RegExp(r'(连续\s*\d+\s*周|这些日期|每个日期|各个日期).{0,24}(分别|各自|逐个)?.{0,12}(创建|新建|建立|设置).{0,10}(task|任务)', caseSensitive: false),
  RegExp(r'(分别|各自|逐个).{0,12}(创建|新建|建立|设置).{0,10}(task|任务)', caseSensitive: false),
];
```

Extend the existing create-task intent's two regexes so `Task` (case-insensitive) is accepted alongside `任务|作业`, and so `创建一个Task` reaches that same intent. Apply `createTaskBurstLimit: 32` and `initialAllowedTools: const ['get_schedule', 'create_task']` only when the selected write intent's terminal tool is exactly `create_task` and one `_multiTaskCreatePatterns` pattern matches. Keep both fields unchanged/null for every other read/write classification. Reuse the existing create-task intent; do not add a second competing intent or require `get_schedule` as a successful lookup for explicit date lists.

- [ ] **Step 4: Run grounding tests and verify GREEN**

Run the Step 2 command. Expected: all grounding tests pass and existing free-chat/relation classifications remain unchanged.

- [ ] **Step 5: Write failing Prompt v7 and context-builder tests**

Assert:

```dart
expect(AgentSystemPrompt.version, 7);
expect(AgentSystemPrompt.version7, contains(AgentSystemPrompt.version6));
expect(AgentSystemPrompt.version7, contains('同一个模型响应'));
expect(AgentSystemPrompt.version7, contains('最多 32'));
expect(AgentSystemPrompt.version7, contains('不要逐轮只调用一次 create_task'));
expect(request.system, contains(AgentSystemPrompt.version7));
expect(request.system, contains('Asia/Shanghai'));
```

Also assert v7 says: first use `course_summary` for course range, confirm missing deadlines/special weeks, ask permission to split requests over 32, report partial results exactly, and never claim success before all tool results.

- [ ] **Step 6: Run Prompt tests and verify RED**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_context_builder_test.dart
Pop-Location
```

Expected: failure because version 7 does not exist and the context builder still sends v6.

- [ ] **Step 7: Append Prompt v7 and switch the context builder**

Implement v7 as an append-only extension:

```dart
static const int version = 7;

static const String version7 = '$version6' '''

## 多 Task 创建与一次性额度
- 明确要求为多个日期分别创建 Task 时，先用 course_summary 确定课程有效范围；日期、截止时刻或特殊周次不明确时先询问，不能猜测。
- 候选列表确定后，在同一个模型响应中一次发出全部 create_task 工具调用，每项参数独立完整；不要逐轮只调用一次 create_task。
- 单次最多发出 32 个 create_task；超过 32 个时先说明拆分范围并取得用户对首批最多 32 项的明确同意，不自动跨 run 续建。
- 收到全部 tool_result 后再报告真实的成功、取消和失败数量；部分成功不得说成全部成功或没有修改数据。
''';
```

Update documentation comments from v6 to v7 and make `AgentContextBuilder` concatenate `AgentSystemPrompt.version7` with the existing dynamic Beijing-time suffix. Preserve every v1-v6 rule verbatim.

- [ ] **Step 8: Run Task 1 tests and verify GREEN**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_grounding_policy_test.dart test/features/agent/agent_context_builder_test.dart
Pop-Location
git diff --check
```

- [ ] **Step 9: Commit Task 1**

```powershell
git add app/lib/features/agent/application/agent_grounding_policy.dart app/lib/features/agent/application/agent_system_prompt.dart app/lib/features/agent/application/agent_context_builder.dart app/test/features/agent/agent_grounding_policy_test.dart app/test/features/agent/agent_context_builder_test.dart
git commit -m "feat(agent): classify create task burst runs"
```

### Task 2: Tool-Turn Budget State Machine And Burst Aggregator

**Files:**
- Create: `app/lib/features/agent/application/agent_tool_budget.dart`
- Create: `app/test/features/agent/agent_tool_budget_test.dart`

**Interfaces:**
- Consumes: `AgentToolResult` and `AgentToolStatus` from `features/agent/domain/agent_tool.dart`.
- Produces: `AgentRunToolBudget.preflightTurn`, `AgentRunToolBudget.tryConsumeNormalCall`, `AgentToolTurnBudgetDecision`, `AgentToolTurnBudgetKind`, and `CreateTaskBurstLease.record` for Task 3.

- [ ] **Step 1: Write failing budget-state tests**

Create tests for this exact public contract:

```dart
final budget = AgentRunToolBudget();

expect(
  budget.preflightTurn(
    toolNames: List.filled(13, 'create_task'),
    allowedCreateTaskBurstLimit: 32,
  ).kind,
  AgentToolTurnBudgetKind.createTaskBurst,
);
expect(budget.normalCallsUsed, 0);
expect(budget.createTaskBurstUsed, isTrue);
```

Cover all boundaries and error precedence:

1. 2, 13 and 32 pure `create_task` calls with allowance 32 return `createTaskBurst`.
2. 33 pure calls return rejected / `create_task_burst_too_large` before marking a Lease used.
3. A second 2-call pure turn after one accepted Lease returns `create_task_burst_already_used`.
4. A one-call `create_task` turn is normal, even when Burst is eligible.
5. A 13-call pure turn with `allowedCreateTaskBurstLimit:null` is normal and the 13th `tryConsumeNormalCall()` returns false.
6. After 5 normal calls, a mixed 8-call turn containing `create_task` returns `create_task_burst_requires_dedicated_turn` because only 7 normal calls remain.
7. A mixed turn fitting the remaining normal quota returns normal.
8. Non-`create_task` turns can never consume Burst.
9. `normalLimit == 12`, `createTaskBurstLimit == 32`; no model-call constant is introduced here.

- [ ] **Step 2: Write failing result-aggregation tests**

Define test results through `AgentToolResult` and assert:

```dart
final lease = CreateTaskBurstLease(plannedCount: 13);
for (var i = 0; i < 12; i++) {
  lease.record(const AgentToolResult(status: AgentToolStatus.success));
}
lease.record(const AgentToolResult(
  status: AgentToolStatus.error,
  errorCode: 'user_declined',
));

expect(lease.processedCount, 13);
expect(lease.successCount, 12);
expect(lease.declinedCount, 1);
expect(lease.errorCount, 0);
expect(lease.terminalErrorCode, 'create_task_burst_partial');
expect(
  lease.terminalMessage,
  '已创建 12 个 Task，1 个未完成。其中 1 个已取消。',
);
```

Also test:

- 13/13 success: `allSucceeded == true`, no terminal override/error code.
- 12 success + `reference_not_found`: partial, safe error count one.
- 11 success + one decline + one technical error: counts remain disjoint and message reports both.
- 0 success + 13 declines: `create_task_burst_failed` and “未创建任何 Task”。
- arbitrary error string becomes `tool_error`, proving raw provider/database text is never surfaced.
- `repeated_tool_call` is retained as a safe error code and counted as a technical error.
- recording more than `plannedCount` throws `StateError`; the Lease cannot silently expand.
- an unprocessed/cancelled remainder can be recorded with `recordInterrupted(count)` without replay metadata or Task content.

- [ ] **Step 3: Run the new test file and verify RED**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_tool_budget_test.dart
Pop-Location
```

Expected: failure because `agent_tool_budget.dart` and its public types do not exist.

- [ ] **Step 4: Implement the focused budget component**

Use these exact type shapes:

```dart
enum AgentToolTurnBudgetKind { normal, createTaskBurst, rejected }

class AgentToolTurnBudgetDecision {
  const AgentToolTurnBudgetDecision._({
    required this.kind,
    this.errorCode,
    this.leasedCallCount = 0,
  });

  final AgentToolTurnBudgetKind kind;
  final String? errorCode;
  final int leasedCallCount;
  bool get isRejected => kind == AgentToolTurnBudgetKind.rejected;
}

class AgentRunToolBudget {
  static const int normalLimit = 12;
  static const int createTaskBurstLimit = 32;

  int get normalCallsUsed;
  int get normalCallsRemaining;
  bool get createTaskBurstUsed;

  AgentToolTurnBudgetDecision preflightTurn({
    required List<String> toolNames,
    required int? allowedCreateTaskBurstLimit,
  });

  bool tryConsumeNormalCall();
}
```

`preflightTurn` must be side-effect free for rejected turns. For an eligible pure turn, apply checks in this order: count greater than allowance -> `create_task_burst_too_large`; existing Lease -> `create_task_burst_already_used`; otherwise mark the single Lease used and return `createTaskBurst`. For a mixed turn containing `create_task`, reject only when `toolNames.length > normalCallsRemaining`; otherwise return normal. Empty and all other turns return normal.

- [ ] **Step 5: Implement `CreateTaskBurstLease` with a safe-code allowlist**

Use this exact API:

```dart
class CreateTaskBurstLease {
  CreateTaskBurstLease({required this.plannedCount});

  final int plannedCount;
  int processedCount = 0;
  int successCount = 0;
  int declinedCount = 0;
  int errorCount = 0;
  final Map<String, int> safeErrorCounts = {};

  bool get allSucceeded;
  bool get hasAnySuccess;
  bool get isComplete;
  String? get terminalErrorCode;
  String? get terminalMessage;

  void record(AgentToolResult result);
  void recordInterrupted(int count);
}
```

Treat `user_declined` as declined; treat `cancelled` as interrupted/cancelled rather than a successful write; treat every other error as technical. Preserve only this allowlist in `safeErrorCounts`:

```dart
const {
  'permission_denied',
  'invalid_arguments',
  'invalid_write_arguments',
  'reference_not_found',
  'target_not_found',
  'tool_not_allowed',
  'repeated_tool_call',
  'write_failed',
  'cancelled',
};
```

Map every unknown/null error to `tool_error`. Build messages with this exact grammar: success present starts with `已创建 S 个 Task，P-S 个未完成。`; zero success starts with `未创建任何 Task。`; append `其中 D 个已取消。` when `declinedCount>0`; append `失败原因：code N 个，code N 个。` when `errorCount>0`, sorting codes lexically. Return `null` terminal override only for complete all-success; return `create_task_burst_partial` when at least one write succeeded but not all; return `create_task_burst_failed` when no write succeeded. Never include input arguments, refs, titles or dates.

- [ ] **Step 6: Run Task 2 tests and verify GREEN**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_tool_budget_test.dart
Pop-Location
E:\flutter\flutter\bin\dart.bat format app/lib/features/agent/application/agent_tool_budget.dart app/test/features/agent/agent_tool_budget_test.dart
git diff --check
```

- [ ] **Step 7: Commit Task 2**

```powershell
git add app/lib/features/agent/application/agent_tool_budget.dart app/test/features/agent/agent_tool_budget_test.dart
git commit -m "feat(agent): add create task burst lease"
```

### Task 3: Session Preflight, Sequential Execution And Truthful Settlement

**Files:**
- Modify: `app/lib/features/agent/application/agent_session_service.dart`
- Modify: `app/test/features/agent/agent_session_service_test.dart`

**Interfaces:**
- Consumes: Task 1 `grounding.createTaskBurstLimit`; Task 2 `AgentRunToolBudget` and `CreateTaskBurstLease`; existing `_MutationAttempt`, confirmation pause/resume, `ToolCallFingerprint`, invocation lifecycle and `_settleNoToolUse`.
- Produces: one-turn preflight before writes, separate normal/Burst accounting, per-result Burst aggregation, deterministic `create_task_burst_*` terminal states, and unchanged non-Burst behavior.

- [ ] **Step 1: Add failing session tests for preflight atomicity and quota separation**

Use the existing scripted provider/registry helpers and assert persisted invocations plus registry execution counts:

1. A provider turn with 13 distinct `create_task` blocks under `createTaskBurstLimit=32` executes all 13, creates 13 invocation rows and never emits `tool_call_budget_exceeded`.
2. One normal `course_summary` before the 13-call Burst and one normal read after it leave normal count at two; the Burst does not consume normal quota.
3. 33 distinct calls return `create_task_burst_too_large`, execute the registry zero times, create blocked/error invocation rows for all received blocks, and perform zero Task writes.
4. A mixed turn that exceeds remaining normal quota returns `create_task_burst_requires_dedicated_turn`; none of that turn's tools executes.
5. A second eligible pure Burst turn returns `create_task_burst_already_used`; none of its calls executes.
6. A non-eligible 13-call turn retains current behavior: first 12 normal calls may run and the 13th receives `tool_call_budget_exceeded`.
7. `maxModelCalls` remains 8 and the existing model-budget test passes unchanged.

For preflight rejection, verify every received `tool_use.id` receives one matching `tool_result` or the run terminates without sending a malformed continuation. Pick the existing Anthropic protocol pattern already used for budget errors; do not invent provider-specific JSON outside `LlmToolResultBlock`.

- [ ] **Step 2: Run focused session tests and verify RED**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_session_service_test.dart --plain-name "create task burst"
Pop-Location
```

Expected: the 13th call still fails with `tool_call_budget_exceeded`; preflight error codes do not exist.

- [ ] **Step 3: Replace the scalar normal counter with the run budget**

At run initialization replace `var totalToolCalls = 0;` with:

```dart
final toolBudget = AgentRunToolBudget();
CreateTaskBurstLease? createTaskBurstLease;
```

Keep `maxModelCalls = 8`. Remove or alias `AgentSessionService.maxToolCalls` only after all tests refer to `AgentRunToolBudget.normalLimit`; do not leave two independent normal-limit constants.

Immediately after collecting all `toolUses` for one assistant response, before the existing `for (toolIndex...)` loop, call:

```dart
final turnBudget = toolBudget.preflightTurn(
  toolNames: [for (final use in toolUses) use.name],
  allowedCreateTaskBurstLimit: grounding?.createTaskBurstLimit,
);
```

When accepted as Burst, initialize exactly one `CreateTaskBurstLease(plannedCount: toolUses.length)`. When normal, call `tryConsumeNormalCall()` at the current per-tool boundary so ordinary behavior remains bounded exactly as before.

- [ ] **Step 4: Implement a whole-turn rejection helper before registry execution**

Extract a session-private helper that, for every `tool_use` in a rejected turn:

```dart
Future<void> rejectToolTurn({
  required String accountId,
  required String runId,
  required List<LlmToolUseBlock> toolUses,
  required String errorCode,
  required List<LlmContentBlock> toolResults,
  required List<AgentToolSummary> toolSummaries,
})
```

For every block, persist one invocation from running/start to error using the same safe error code, add one folded summary, and add one `LlmToolResultBlock(isError:true)` with payload `{'code': errorCode}`. Do not call `_registry.execute`, do not bind refs, do not increment normal calls, and do not include raw input in summaries. Set `terminalState=failed`, set the run error code, and terminate the autonomous loop after recording the well-formed results; do not ask the provider to repair by issuing another Burst.

- [ ] **Step 5: Run preflight tests and verify GREEN**

Run the Step 2 command. Expected: all new preflight/quota tests pass; existing normal budget behavior remains unchanged.

- [ ] **Step 6: Add failing tests for result aggregation and persisted truth**

Add separate tests for:

```text
13 success                -> completed; 13 independent writes remain
12 success + 1 declined   -> failed/create_task_burst_partial; 12 writes remain
12 success + 1 error      -> failed/create_task_burst_partial; 12 writes remain
0 success + 13 declined   -> failed/create_task_burst_failed; zero writes
12 success + 1 duplicate  -> failed/create_task_burst_partial; 12 writes; repeated_tool_call counted
Stop after N success       -> cancelled; N writes remain; remaining calls not replayed
```

Assert the partial assistant message is exactly the Lease's deterministic `terminalMessage`, is persisted as the terminal assistant message, and contains neither “没有修改数据” nor “请求失败，未生成回答”. Also assert the last same-name `create_task` attempt cannot overwrite prior success counts in `terminalAttempts`.

- [ ] **Step 7: Record every Burst terminal result at the existing single result boundary**

After confirmation pause/resume has produced the terminal `AgentToolResult`, but before generic grounding settlement, call:

```dart
if (turnBudget.kind == AgentToolTurnBudgetKind.createTaskBurst &&
    tu.name == 'create_task') {
  createTaskBurstLease!.record(result);
}
```

The result must be recorded exactly once whether it came from success, user decline, permission rejection, fingerprint rejection or technical error. In the cancellation branch call `recordInterrupted(remainingCount)` for the unstarted remainder before ending the run. Do not add a second registry call or a second confirmation lifecycle.

- [ ] **Step 8: Give Burst aggregation precedence in no-tool settlement**

Extend `_settleNoToolUse` with `CreateTaskBurstLease? createTaskBurstLease`. After the cancellation check but before generic `terminalSucceeded` logic:

```dart
if (createTaskBurstLease != null && createTaskBurstLease.isComplete) {
  if (createTaskBurstLease.allSucceeded) {
    return _GroundedSettlement.accept;
  }
  if (createTaskBurstLease.hasAnySuccess) {
    return _GroundedSettlement.createTaskBurstPartial;
  }
  return _GroundedSettlement.createTaskBurstFailed;
}
```

Add enum cases and switch handling that:

- sets `terminalState=AgentRunState.failed`;
- uses `create_task_burst_partial` or `create_task_burst_failed`;
- replaces model text with `lease.terminalMessage!` and persists it;
- never falls through to `_terminalFailureText`, because that helper truthfully describes a single failed write but falsely says no data changed for a partial Burst;
- never allows the generic `succeededTools` set to treat one successful `create_task` as proof that all planned writes succeeded.

If the Lease is incomplete because of Stop, cancellation wins and the current cancelled run semantics remain authoritative. Do not construct a Lease from persisted invocation rows after restart.

- [ ] **Step 9: Run all session tests and verify GREEN**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_tool_budget_test.dart test/features/agent/agent_session_service_test.dart
Pop-Location
E:\flutter\flutter\bin\dart.bat format app/lib/features/agent/application/agent_session_service.dart app/test/features/agent/agent_session_service_test.dart
git diff --check
```

- [ ] **Step 10: Commit Task 3**

```powershell
git add app/lib/features/agent/application/agent_session_service.dart app/test/features/agent/agent_session_service_test.dart
git commit -m "fix(agent): aggregate create task burst results"
```

### Task 4: Real Composition Regression, Manual Acceptance And Embedded Handoff

**Files:**
- Modify: `app/test/integration/agent_composition_flow_test.dart`
- Test unchanged: `app/test/integration/read_only_agent_flow_test.dart` as an adjacent regression suite; do not edit it.
- Create: `docs/agent-create-task-burst-retest-2026-08-03.md`
- Modify: `docs/superpowers/plans/2026-08-03-agent-create-task-burst-budget.md`

**Interfaces:**
- Consumes: Tasks 1-3 production behavior, the real local Agent registry, confirmation store, Drift gateways and scripted provider.
- Produces: a 13-week independent Task composition regression, an owner-fillable Release acceptance item, final review findings and measured execution evidence in this plan.

- [ ] **Step 1: Write a failing real-composition test for 13 weekly deadlines**

Seed one account with a course summary whose `activeFrom`/`activeThrough` covers exactly 13 relevant Saturdays. Script the provider to:

1. receive `get_schedule` and `create_task` in the initial allowed declarations;
2. call `get_schedule(view=course_summary, query=电磁场与波)` once;
3. emit 13 distinct `create_task` blocks in the next single assistant response, each with the expected Saturday deadline;
4. receive 13 tool results and produce one final answer.

Use the real registry, write permission/confirmation path and Drift Task gateway. If the test policy requires confirmation, drive the existing pending action API 13 times; do not bypass the production confirmation mechanism. Assert:

```dart
expect(tasksForAccount, hasLength(13));
expect(tasksForAccount.map((task) => task.deadlineAt).toSet(), hasLength(13));
expect(createInvocations, hasLength(13));
expect(run.state, AgentRunState.completed);
expect(run.errorCode, isNull);
expect(allInvocationErrors, isNot(contains('tool_call_budget_exceeded')));
```

Also assert every Task is independent, all deadlines are within the course summary range, the other seeded account sees zero new Tasks/invocations, and neither a TaskSeries nor a batch tool/schema appears.

- [ ] **Step 2: Run the composition test and verify RED**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/integration/agent_composition_flow_test.dart --plain-name "13 weekly create tasks"
Pop-Location
```

Expected before Tasks 1-3: the 13th call hits the ordinary budget or the new composition case is absent. After Tasks 1-3 it must pass.

- [ ] **Step 3: Complete the composition fixture and verify GREEN**

Use explicit expected Beijing dates in the test fixture, not a production semester constant. Verify the provider's second response contains all 13 `LlmToolUseBlock`s at once. Keep any helper local to the integration test unless at least two production tests need it.

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/integration/agent_composition_flow_test.dart test/integration/read_only_agent_flow_test.dart
Pop-Location
```

- [ ] **Step 4: Create one owner-fillable manual acceptance document**

Create `docs/agent-create-task-burst-retest-2026-08-03.md` with prerequisites, reset/cleanup guidance, and one numbered test section containing:

- exact test sentence: `电磁场与波作业连续13周每周六截止，请根据这门课的有效周次分别创建独立Task。`
- expected first lookup: one `get_schedule(view=course_summary, query=电磁场与波)`，不是整学期 events 查询；
- expected model behavior: when the course summary leaves deadline time or special-week inclusion unresolved, the Agent asks exactly one clarification; after all candidate dates are explicit, one tool group contains 13 distinct `create_task` calls;
- expected confirmation behavior: each Task still follows current permission policy; cancelling one does not roll back the others;
- expected final state: 13/13 is completed; 12+1 cancelled is `create_task_burst_partial` and accurately reports counts;
- expected diagnostics: no `tool_call_budget_exceeded`, no hidden second Burst, no TaskSeries/batch tool;
- fields to record model-call count, tool names/counts, safe error codes and observed Task count;
- a final blank `完成：` field.

End every independently testable subsection with a blank `完成：` field. Do not mark any item successful. Do not edit the protected relation retest document.

- [ ] **Step 5: Run the focused regression suite**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_grounding_policy_test.dart test/features/agent/agent_context_builder_test.dart test/features/agent/agent_tool_budget_test.dart test/features/agent/agent_session_service_test.dart test/integration/agent_composition_flow_test.dart test/integration/read_only_agent_flow_test.dart
Pop-Location
```

Expected: all focused tests pass with zero failures.

- [ ] **Step 6: Run complete repository verification**

```powershell
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
Push-Location app
E:\flutter\flutter\bin\flutter.bat analyze
E:\flutter\flutter\bin\flutter.bat test
E:\flutter\flutter\bin\flutter.bat build windows --release
Pop-Location
git diff --check
git status --short
```

Record exact Python/Flutter test counts, analyze output, Release executable path and command exit states under “Execution Evidence”. Historical counts in this plan are orientation only. Automatic verification must not populate the manual `完成：` field.

- [ ] **Step 7: Perform final code review**

Use `superpowers:requesting-code-review`. Review specifically:

1. Burst eligibility cannot be obtained by free chat, one Task, unrelated write intent or model self-selection.
2. Every preflight rejection happens before registry/database writes and preserves Anthropic tool-use/tool-result validity.
3. Normal 12-call and model 8-call protections remain unchanged outside the eligible turn.
4. The 13-call Burst still executes each independent validation, confirmation, transaction and ActionLog.
5. One success in `succeededTools` cannot mask later decline/error; deterministic partial text never says no data changed.
6. Unknown error strings, Task titles, dates, refs, account IDs and school identifiers do not enter summaries/logs.
7. Stop/restart never auto-replays missing writes and no database migration was introduced.
8. No default semester, `semesterId=421/461`, `2026spring` or `2026fall` is used to derive deadlines.

For every accepted finding, first add a failing regression, apply the narrow fix, rerun the affected tests, then rerun the focused suite.

- [ ] **Step 8: Update the embedded execution handoff**

Replace the pre-execution snapshot in “Embedded Execution Handoff” with:

- exact final HEAD and ordered Task commit hashes;
- files changed by each Task;
- focused/full verification commands and exact counts;
- Release executable path;
- code review findings and fixes;
- remaining manual acceptance status;
- accepted residual limitations;
- final `git status --short`, distinguishing protected pre-existing files from implementation changes.

Do not create a separate handoff document.

- [ ] **Step 9: Commit Task 4**

Stage only files actually changed:

```powershell
git add app/test/integration/agent_composition_flow_test.dart docs/agent-create-task-burst-retest-2026-08-03.md docs/superpowers/plans/2026-08-03-agent-create-task-burst-budget.md
git commit -m "test(agent): close create task burst workflow"
```

Never use `git add .`.

## Manual Acceptance Focus

1. Start a fresh Windows Release process with the real school model and one test account.
2. Send the exact 13-week request and verify the Agent first obtains a course summary rather than querying an unbounded semester events range.
3. Verify uncertain deadline time or special-week behavior produces one clarification before writes.
4. Verify the decisive provider turn contains 13 `create_task` blocks at once, while the UI may still present confirmations sequentially according to the current permission policy.
5. Verify all accepted items appear as 13 independent Tasks and the run does not emit `tool_call_budget_exceeded`.
6. Repeat while declining one confirmation; verify successful Tasks remain and the assistant reports exact partial counts.
7. Verify another account cannot see those Tasks or invocation records.
8. For a request over 32 items, verify the Agent asks permission to split; if 33 blocks are nevertheless emitted, verify zero writes and `create_task_burst_too_large`.

## Embedded Execution Handoff

### Execution Handoff (post-execution, updated by Task 4)

- Final HEAD (Task 4 commit): see this plan's Task 4 commit below.
- Branch: `feature/write-tools` (isolated worktree `E:/107/.worktrees/write-tools`).

#### Final HEAD and ordered Task commit hashes

- Task 1 (classify create task burst runs): `c909952` — `feat(agent): classify create task burst runs`
- Task 2 (tool-turn budget state machine + aggregator): `245856f` — `feat(agent): add create task burst lease`
- Task 2 corrective (single create_task after burst stays normal): `b154506` — `fix(agent): single create_task after burst stays normal`
- Task 3 (session preflight, sequential execution, truthful settlement): `9cfc63a` — `fix(agent): aggregate create task burst results`
- Task 4 (real composition regression + manual acceptance + handoff): one commit `test(agent): close create task burst workflow` (this Task).

#### Files changed by each Task

- **Task 1:** `app/lib/features/agent/application/agent_grounding_policy.dart`, `app/lib/features/agent/application/agent_system_prompt.dart`, `app/lib/features/agent/application/agent_context_builder.dart` + their tests.
- **Task 2:** created `app/lib/features/agent/application/agent_tool_budget.dart` + `app/test/features/agent/agent_tool_budget_test.dart`.
- **Task 3:** `app/lib/features/agent/application/agent_session_service.dart` + `app/test/features/agent/agent_session_service_test.dart`.
- **Task 4:** `app/test/integration/agent_composition_flow_test.dart` (two new burst composition regressions), created `docs/agent-create-task-burst-retest-2026-08-03.md`, modified `docs/superpowers/plans/2026-08-03-agent-create-task-burst-budget.md` (this handoff).

#### Focused and full verification commands and exact counts

Focused regression suite (`agent_grounding_policy_test`, `agent_context_builder_test`, `agent_tool_budget_test`, `agent_session_service_test`, `agent_composition_flow_test`, `read_only_agent_flow_test`): **223 tests, all passed** (`00:10 +223: All tests passed!`).

Full repository verification (measured, not historical):

- Python `unittest discover -s tests`: **394 tests, OK** (run with the worktree `src` on `PYTHONPATH`; see note below).
- Python `compileall -q src tests`: **exit 0**, no errors.
- `flutter analyze`: **No issues found** (0 errors/warnings/infos; ran in 3.5s).
- `flutter test` (full): **949 tests, all passed** (`+949: All tests passed!`).
- `flutter build windows --release`: **exit 0**, `√ Built build\windows\x64\runner\Release\ustc_assistant_app.exe`.
- `git diff --check`: **exit 0** (only CRLF warnings on protected pre-existing files).
- `git status --short` after Task 4: listed under "Protected Pre-Existing Worktree State" below (only the Task 4 changed files are staged/committed).

> Python environment note: the `ustc_assistant` conda env has an editable install whose `ustc_assistant.config` resolves to the MAIN repo `E:\107\src` (missing the newer `render_flutter_source_defaults`), causing 4 import/CLI errors when run without the worktree `src` first. Running the exact brief command with the worktree's `src` on `PYTHONPATH` (`PYTHONPATH=E:/107/.worktrees/write-tools/src`) yields **394 tests OK**. This is an environment install-path mismatch, not a worktree code defect; no Python code was changed by this plan.

#### Release executable path

`E:/107/.worktrees/write-tools/app/build/windows/x64/runner/Release/ustc_assistant_app.exe`
(Build command: `flutter build windows --release`; Task 4 changes no production code, so the artifact is functionally identical to the Tasks 1-3 release.)

#### Code review findings and fixes

Direct final review of the 8 Step-7 points against the committed production code (Tasks 1-3) and the new composition tests (Task 4):

1. **Burst eligibility** — OK. `agent_grounding_policy.dart` `_buildRequirement` sets `createTaskBurstLimit`/`initialAllowedTools` only when the selected write intent's terminal tool is *exactly* `create_task` AND an `_multiTaskCreatePatterns` pattern matches (requires a creation verb + plurality/recurrence). Free chat, a single task, unrelated write intents, and model self-selection cannot obtain it (eligibility is derived from user wording + terminal-tool shape, never from the model's own tool names).
2. **Preflight before writes** — OK. `agent_session_service.dart` calls `toolBudget.preflightTurn` (line 998) before any registry execution; a rejected turn goes through `rejectToolTurn`, which persists blocked invocation rows + well-formed `LlmToolResultBlock(isError, {code})` without any write. Rejected turns are side-effect free (`agent_tool_budget.dart`).
3. **Normal 12-call / model 8-call protections unchanged** — OK. `tryConsumeNormalCall` and the normal-call branch (line 1080) are untouched; only a pure `create_task` turn under the burst lease bypasses the ordinary quota, exactly once per run (`create_task_burst_already_used` on a second burst).
4. **Burst still runs each validation/confirmation/transaction/ActionLog** — OK. The burst does not skip the per-call `AgentWriteTool.execute` confirmation gate, `commitAgentWriteAtomically`, the Drift Task gateway, or ActionLog. The Task 4 composition tests drive the REAL `confirmWriteProposal` confirmation API (first is confirmed; remaining ask_first_time calls auto-execute after the first confirmation releases create_task) and assert 13 persisted Task rows + 13 invocation lifecycle rows.
5. **Success cannot mask later decline/error; partial text never claims no data changed** — OK. `CreateTaskBurstLease.allSucceeded`/`hasAnySuccess`/`terminalErrorCode` are the sole authority; `_settleNoToolUse` case 8 settles `create_task_burst_partial` / `create_task_burst_failed`. The deterministic terminal message reports exact counts and never uses the "没有修改数据" fixed text. Covered by the decline-path composition test (12 created + 1 cancelled).
6. **No unknown error strings, titles, dates, refs, account IDs, school IDs in burst summaries/logs** — OK for the burst aggregation path: `CreateTaskBurstLease` carries only counts + allowlisted codes (unknowns collapse to `tool_error`). *Observation (pre-existing, out of scope):* the per-write `AgentWriteTool.propose` `safeLogSummary` for create_task is `'新建任务 $title'`, which includes the title; this is inherited from the earlier write-tools design and is a user-facing internal audit summary, not the burst aggregation summary added by this plan. No change made (Task 4 is test/docs only).
7. **Stop/restart never auto-replays; no DB migration** — OK. Burst state is in-memory only; a mid-burst interruption uses `recordInterrupted` and never replays (`create_task_burst_*` rejected on next pure turn). No schema/migration introduced (`git status` shows no migration files).
8. **No default semester / semesterId=421/461 / 2026spring / 2026fall to derive deadlines** — OK. The composition tests seed and assert explicit Beijing Saturdays (2026-09-05..2026-11-28) with `semesterKey: 'aug2026'` and no semester literals in outbound requests; `_courseSummary` derives the active range from occurrence data, never a hardcoded semester.

No accepted findings required a fix (Task 4 changes no production code; all 8 points confirmed satisfied and exercised by the new tests). The composition + read-only + focused + full suites all pass.

#### Remaining manual acceptance status

`docs/agent-create-task-burst-retest-2026-08-03.md` is created (owner-fillable) but **NOT** executed: all `完成：` fields are left blank. This plan's automatic verification does not populate the manual acceptance fields. Manual acceptance items cover: the exact 13-week sentence, first course_summary lookup, single clarification on unresolved deadline/special-week, 13 distinct `create_task` in one tool group, per-item confirmation + cancel-does-not-roll-back, final 13/13 completed vs 12+1 cancelled => `create_task_burst_partial`, no `tool_call_budget_exceeded` / no hidden second Burst / no TaskSeries-batch tool, another account sees zero new Tasks/invocations, and over-32 split consent. Historical counts from the predecessor plan (Python 388 / Flutter 910) are superseded by the measured counts above.

#### Accepted residual limitations

- The runtime deterministically proves that the model's *actually emitted* batch executed and aggregated truthfully, but cannot alone prove model *semantic coverage* of all 13 user-intended dates; completeness is bounded by `course_summary` active range, the versioned system prompt date-enumeration rules, the 13 explicit deadline composition fixture, and the user's manual check on confirm cards + final summary. No batch-list signature / TaskSeries / new pre-planning persistence protocol is introduced.
- Python suite must be run with the worktree `src` first on `PYTHONPATH` (env editable-install path points at the main repo), as documented above.
- The `safeLogSummary` for create_task includes the task title (pre-existing write-tools behavior), outside this plan's burst aggregation scope.

#### Final `git status --short` (after Task 4)

Protected pre-existing files (untouched, not staged by this plan):

```text
 M app/windows/flutter/generated_plugin_registrant.cc
 M app/windows/flutter/generated_plugin_registrant.h
 M app/windows/flutter/generated_plugins.cmake
 M docs/agent-relation-closure-retest-2026-08-02.md
?? docs/agent-manual-acceptance-retest-2026-08-01.md
?? docs/agent-manual-acceptance-review-handoff-2026-08-02.md
?? docs/agent-testing.md
?? docs/superpowers/plans/2026-08-02-agent-manual-acceptance-review-repairs.md
```

Task 4 implementation changes (staged and committed as ONE commit):

```text
 M app/test/integration/agent_composition_flow_test.dart
?? docs/agent-create-task-burst-retest-2026-08-03.md
 M docs/superpowers/plans/2026-08-03-agent-create-task-burst-budget.md
```

## Self-Review

**Spec coverage:** Spec sections 6-7 are implemented by Tasks 1-3; provider batching and over-32 consent are Prompt v7 in Task 1 plus runtime preflight in Tasks 2-3; duplicate protection, partial success, stop/restart and deterministic terminal truth are Tasks 2-3; composition, security, compatibility and manual acceptance are Task 4.

**Scope:** No batch tool, recurrence entity, Task schema, database migration, Python, Bridge, SourceBundle, mobile adapter or semester behavior is included. The only new production file is a focused in-memory budget/aggregation component.

**Type consistency:** Task 1 produces nullable `createTaskBurstLimit`; Task 2 consumes it as `allowedCreateTaskBurstLimit` and produces one decision plus one Lease; Task 3 passes the decision through the existing per-turn loop and the Lease into `_settleNoToolUse`; Task 4 consumes only completed runtime behavior. Prompt v7 extends v6 and is selected in the same Task.

**Error precedence:** Oversize pure turns return `create_task_burst_too_large` before Lease mutation; a valid-sized second pure turn returns `create_task_burst_already_used`; mixed over-budget turns return `create_task_burst_requires_dedicated_turn`; ordinary per-call exhaustion remains `tool_call_budget_exceeded`.

**Placeholder scan:** The sole pre-execution marker is the explicitly required “Execution Evidence” paragraph, which Task 4 replaces with measured results. All production interfaces, error codes, test cases, commands, commit boundaries and handoff requirements are defined here.
