# Agent Date-Bounded Relation Lookup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让关系请求能够按明确单日取得具体日程事件，并在用户同时要求安排已有 Task 时，由 LLM 顺序调用现有工具创建 PlanBlock 和 `no_conflict` Relation。

**Architecture:** 保留现有 `AgentGroundingPolicy`、工具循环、确认卡和 Relation 写工具。关系查询保护从“必须有标题”改为“标题或精确单日二选一”；只有同时命中关系和任务规划语义时，声明五个现有工具供模型自主编排。会话层对支持性 `plan_task` 写入记录真实结果，确保后续 Relation 失败时不会错误声称“没有修改数据”。

**Tech Stack:** Flutter/Dart、Drift/SQLite、Anthropic Messages SSE、`flutter_test`、Windows Flutter。

**Design authority:** `docs/superpowers/specs/2026-08-03-agent-date-bounded-relation-lookup-design.md`（commit `dd73551`）。实现与设计冲突时停止并向主人报告，不得自行扩大范围。

## Global Constraints

- 工作区固定为 `E:/107/.worktrees/write-tools`，分支固定为 `feature/write-tools`。
- 计划编写基线为 `dd73551`；开始实现前记录实际 HEAD，并确认本计划仍位于该分支历史中。
- Python 仅使用 Conda 环境 `ustc_assistant`，不得安装依赖或修改 `base`。
- 时间统一使用 `Asia/Shanghai`；不得推算或硬编码 `semesterId`、`421`、`461`、`2026spring` 或 `2026fall`。
- 不新增复合写工具、复合状态机、TaskSeries、重复 Task、批量 Task 或数据库字段。
- 不修改 Python、Bridge、SourceBundle、默认学期、移动端来源适配或学校外部写边界。
- 所有 Agent 写操作继续经过现有风险策略、用户确认、事务和 ActionLog。
- 不允许 LLM 在找不到已有 Task 时静默创建 Task；本轮不向关系流程开放 `create_task`。
- 不向模型或持久日志暴露 API Key、Cookie、Token、完整学号、数据库 ID、原始 `ref_*` 或完整课表。
- 自动测试不得访问学校 API 或学校网站；真实模型验收必须使用新构建的 Windows Release App。
- 每个 Task 使用 TDD，单独提交；完成一个 Task 后向主人同步提交哈希和聚焦测试结果。
- 手工编辑使用 `apply_patch`；不得覆盖用户填写的任何 `完成：` 内容。
- 开始时已有的 Windows 生成文件、人工测试文档和其他未跟踪用户文件必须保留，不得暂存、覆盖或删除。

## File Structure

**No new production files.** 本轮只修改现有 Agent 策略、会话、提示词和测试。

**Primary modifications:**

- `app/lib/features/agent/application/agent_session_service.dart`：单日关系查询边界、支持性写结果和部分成功终态。
- `app/lib/features/agent/application/agent_grounding_policy.dart`：条件开放五个工具、显式 `不冲突` 状态和 supporting tools 元数据。
- `app/lib/features/agent/application/agent_system_prompt.dart`：新增 version 6 的单日查询和顺序工具规则。
- `app/lib/features/agent/application/agent_context_builder.dart`：运行时改用 prompt version 6。
- `app/test/features/agent/agent_session_service_test.dart`：查询拦截、连续确认和部分成功回归。
- `app/test/features/agent/agent_grounding_policy_test.dart`：原始句子的分类、状态和工具声明。
- `app/test/features/agent/agent_context_builder_test.dart`：prompt version 6 规则。
- `app/test/integration/agent_composition_flow_test.dart`：真实本地工具组合的完整五工具流程。
- `docs/agent-relation-closure-retest-2026-08-02.md`：追加主人可填写的新人工复测项，保留已有结果。
- `docs/superpowers/plans/2026-08-03-agent-date-bounded-relation-lookup.md`：最终 Task 写入实施证据和接手状态，不另建交接文档。

---

### Task 1: Allow Exact-Day Event Lookup In Relation Runs

**Files:**
- Modify: `app/lib/features/agent/application/agent_session_service.dart:1060-1074,1748-1763`
- Test: `app/test/features/agent/agent_session_service_test.dart:3200-3253`

**Interfaces:**
- Consumes: existing `AgentGroundingRequirement` and `GetScheduleTool` input schema.
- Produces: `_isBoundedRelationScheduleLookup(Map<String, Object?> input) -> bool` and error code `relation_lookup_requires_bound`.

- [ ] **Step 1: Replace the title-only test helper with a counting schedule fake**

In `agent_session_service_test.dart`, keep a fake named `get_schedule` that records actual executions and returns one event ref when called. Add table-driven relation-run cases:

```dart
final cases = <({Map<String, Object?> input, bool executes, String? error})>[
  (
    input: {'from': '2026-09-01', 'through': '2026-09-01'},
    executes: true,
    error: null,
  ),
  (
    input: {'query': '计算机网络', 'view': 'events'},
    executes: true,
    error: null,
  ),
  (
    input: const {},
    executes: false,
    error: 'relation_lookup_requires_bound',
  ),
  (
    input: {'from': '2026-09-01'},
    executes: false,
    error: 'relation_lookup_requires_bound',
  ),
  (
    input: {'from': '2026-09-01', 'through': '2026-09-02'},
    executes: false,
    error: 'relation_lookup_requires_bound',
  ),
  (
    input: {
      'from': '2026-09-01',
      'through': '2026-09-01',
      'view': 'course_summary',
    },
    executes: false,
    error: 'relation_lookup_requires_bound',
  ),
];
```

Assert rejected calls never reach the registry and the error is persisted in the same invocation row.

- [ ] **Step 2: Run the focused session tests and verify RED**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_session_service_test.dart --plain-name "relation lookup bound"
Pop-Location
```

Expected: same-day no-query case fails with `relation_lookup_requires_title`; new error-code cases fail because the code does not exist.

- [ ] **Step 3: Implement the bounded predicate**

Replace `_noNonblankQuery` with:

```dart
static bool _isBoundedRelationScheduleLookup(
  Map<String, Object?> input,
) {
  final view = input['view'];
  if (view != null && view != 'events') return false;

  final query = input['query'];
  if (query is String && query.trim().isNotEmpty) return true;

  final from = input['from'];
  final through = input['through'];
  return from is String &&
      through is String &&
      from.trim().isNotEmpty &&
      from == through;
}
```

The session guard becomes:

```dart
} else if (_isRelationLookup(tu.name, grounding) &&
    tu.name == 'get_schedule' &&
    !_isBoundedRelationScheduleLookup(tu.input)) {
  result = const AgentToolResult(
    status: AgentToolStatus.error,
    errorCode: 'relation_lookup_requires_bound',
    payload: {
      'guidance': '关系参与方需要具体事件引用。请提供事件标题，或把 '
          'from/through 限定为同一天并使用 view=events；不要读取整学期详细事件后再过滤。',
    },
  );
  forcedLifecycle = ToolInvocationLifecycleState.error;
}
```

Do not parse dates in the session layer. Invalid date strings pass to `GetScheduleTool`, which remains the single date-validation authority.

- [ ] **Step 4: Update every old error-code assertion**

Search only current source/tests:

```powershell
rg -n "relation_lookup_requires_title" app/lib app/test
```

Update active behavior tests to `relation_lookup_requires_bound`. Do not migrate or rewrite persisted historical invocation rows and do not edit archived user test results.

- [ ] **Step 5: Run Task 1 tests and verify GREEN**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_session_service_test.dart
Pop-Location
git diff --check
```

Expected: session suite passes; exact-day no-query executes once; rejected inputs execute zero times.

- [ ] **Step 6: Commit Task 1**

```powershell
git add app/lib/features/agent/application/agent_session_service.dart app/test/features/agent/agent_session_service_test.dart
git commit -m "fix(agent): allow exact-day relation lookups"
```

### Task 2: Conditionally Expose Task Planning Tools And Prompt Version 6

**Files:**
- Modify: `app/lib/features/agent/application/agent_grounding_policy.dart:20-160,250-300`
- Modify: `app/lib/features/agent/application/agent_system_prompt.dart:1-63`
- Modify: `app/lib/features/agent/application/agent_context_builder.dart:366-370`
- Test: `app/test/features/agent/agent_grounding_policy_test.dart`
- Test: `app/test/features/agent/agent_context_builder_test.dart`

**Interfaces:**
- Produces: `AgentGroundingRequirement.supportingTools` as `Set<String>` with default `{}`.
- Preserves: `terminalTools == {'create_schedule_relation'}` for this workflow.
- Produces prompt `AgentSystemPrompt.version == 6` and `AgentSystemPrompt.version6`.

- [ ] **Step 1: Add failing classifier tests using the exact real request**

```dart
const text = '在9月1号上午第一节课我想再写一门生命科学简史课作业，'
    '你只要帮我安排在这个时间段，具体事件我自己把握，并标记为不冲突';
final req = policy.classify(text)!;

expect(req.expectedConflictState, ExpectedConflictState.noConflict);
expect(req.terminalTools, {'create_schedule_relation'});
expect(req.supportingTools, {'get_tasks', 'plan_task'});
expect(req.initialAllowedTools, [
  'get_tasks',
  'get_schedule',
  'plan_task',
  'get_plan_blocks',
  'create_schedule_relation',
]);
expect(req.initialAllowedTools, isNot(contains('create_task')));
```

Also assert a plain “把这两节课标记为不冲突” keeps exactly the original three relation tools and empty `supportingTools`.

- [ ] **Step 2: Run classifier tests and verify RED**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_grounding_policy_test.dart
Pop-Location
```

Expected: `supportingTools` is undefined, exact text lacks five-tool declarations, or explicit “不冲突” is not classified as `noConflict`.

- [ ] **Step 3: Extract shared plan-task patterns**

Define one top-level `_planTaskPatterns` list and use the same list in the existing `plan_task` `_IntentDef` and secondary relation check:

```dart
final List<RegExp> _planTaskPatterns = [
  RegExp(r'(任务|作业|复习|project|assignment).{0,20}(安排|规划)'),
  RegExp(r'(安排|规划).{0,20}(任务|作业|复习)'),
  RegExp(r'安排.*(时间段|时段)'),
];
```

Do not duplicate these regexes in two locations.

- [ ] **Step 4: Extend the requirement without adding a composite terminal state**

Add:

```dart
final Set<String> supportingTools;

Set<String> get requiredTools => {
  ...lookupTools,
  ...supportingTools,
  ...terminalTools,
};
```

For relation writes, compute `plansTask = _matchesAny(text, _planTaskPatterns)`. When true, set supporting tools to `{'get_tasks', 'plan_task'}` and the ordered five-tool declarations. When false, preserve the original three-tool list.

Add `RegExp(r'不冲突')` to the concrete no-conflict patterns before unresolved-conflict patterns. Do not infer `noConflict` from time overlap alone.

- [ ] **Step 5: Add failing prompt tests**

In `agent_context_builder_test.dart`, assert the built prompt contains all of these rules:

```text
按日期与节次/时间定位关系参与方时，用同一天的 get_schedule(view=events)
不要猜课程名
get_tasks/get_schedule -> plan_task -> get_plan_blocks -> create_schedule_relation
依赖新 PlanBlock 引用的写工具不能并行
Task 不唯一时先询问，不自动 create_task
PlanBlock 成功但 Relation 未成功时报告部分完成
```

Also assert the dynamic Beijing-time suffix remains present exactly once.

- [ ] **Step 6: Implement prompt version 6 and switch the context builder**

Preserve `version5` verbatim and append a version 6 section:

```dart
static const int version = 6;

static const String version6 = '$version5' '''

## 单日关系参与方与已有任务规划
- 用户用日期与节次或时间指明关系参与方但未给标题时，使用同一天的 get_schedule（view=events），根据返回开始/结束时间选择事件，不猜课程名。
- 同一时段有多个候选事件且用户未指定全部对象时，先列出安全标题和时间并询问，不任意选择或批量写关系。
- 同一句话要求安排已有 Task 并建立关系时，先用 get_tasks/get_schedule 定位目标，再顺序调用 plan_task；提交成功后用 get_plan_blocks 取得新引用，最后调用 create_schedule_relation。依赖新 PlanBlock 引用的两个写工具不能并行。
- 找不到唯一 Task 时先询问，不自动调用 create_task。PlanBlock 已创建但 Relation 未成功时，准确报告部分完成。
''';
```

Update `AgentContextBuilder` to append time to `version6`, and update comments/tests that still claim runtime uses version 5. Do not change `AgentConfigurationService.defaultSystemPromptVersion`; that stored compatibility field is outside this runtime prompt-text change.

- [ ] **Step 7: Run Task 2 tests and verify GREEN**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_grounding_policy_test.dart test/features/agent/agent_context_builder_test.dart
Pop-Location
git diff --check
```

- [ ] **Step 8: Commit Task 2**

```powershell
git add app/lib/features/agent/application/agent_grounding_policy.dart app/lib/features/agent/application/agent_system_prompt.dart app/lib/features/agent/application/agent_context_builder.dart app/test/features/agent/agent_grounding_policy_test.dart app/test/features/agent/agent_context_builder_test.dart
git commit -m "feat(agent): expose task planning for relation runs"
```

### Task 3: Preserve Sequential Write And Partial-Completion Truth

**Files:**
- Modify: `app/lib/features/agent/application/agent_session_service.dart:674-692,837-889,1217-1236,1826-1953`
- Test: `app/test/features/agent/agent_session_service_test.dart`

**Interfaces:**
- Consumes: `AgentGroundingRequirement.supportingTools` from Task 2.
- Produces: structured supporting mutation attempts for `plan_task` and deterministic partial-result messages.
- Keeps: `create_schedule_relation` as the only terminal write for full success.

- [ ] **Step 1: Add failing sequential confirmation tests**

Script a run with these provider turns:

```text
1. get_tasks + get_schedule(single day)
2. plan_task
3. get_plan_blocks(taskRef from turn 1)
4. create_schedule_relation(conflict_state=no_conflict)
5. final text
```

Use the existing confirmation resumer. Assert `plan_task` reaches success before `get_plan_blocks` executes, Relation confirmation appears only after the new PlanBlock ref is bound, and the run completes only after Relation success.

- [ ] **Step 2: Add failing cancellation and partial-success tests**

Cover these exact outcomes:

| PlanBlock | Relation | Expected run/message |
| --- | --- | --- |
| declined | not called | failed with `user_declined`; “未创建执行时间段，也未保存关系” |
| success | declined | failed with `user_declined`; “执行时间段已创建，但不冲突关系未保存” |
| success | technical error | failed with safe relation error; same partial-success fact |
| success | model omits Relation after correction | failed with `relation_not_grounded_after_plan`; PlanBlock remains recorded |
| success | success | completed; model final text accepted |

Assert no partial-success branch says “没有修改数据” and no branch calls `plan_task` twice.

- [ ] **Step 3: Run the new session tests and verify RED**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_session_service_test.dart --plain-name "task planning relation"
Pop-Location
```

Expected: current settlement either corrects toward a relation after declined planning, reports “没有修改数据” after a successful PlanBlock, or falls through to `grounding_failed`.

- [ ] **Step 4: Track supporting mutation attempts narrowly**

Rename `_TerminalMutationAttempt` to `_MutationAttempt` and maintain two maps:

```dart
final terminalAttempts = <String, _MutationAttempt>{};
final supportingAttempts = <String, _MutationAttempt>{};
```

After every structured tool result:

```dart
if (grounding?.terminalTools.contains(tu.name) ?? false) {
  terminalAttempts[tu.name] = _MutationAttempt.fromResult(tu.name, result);
}
if ((grounding?.supportingTools.contains(tu.name) ?? false) &&
    tu.name == 'plan_task') {
  supportingAttempts[tu.name] = _MutationAttempt.fromResult(tu.name, result);
}
```

Keep the supporting declaration set broad enough for correction, but record only `plan_task` as a supporting mutation attempt. Do not treat successful `get_tasks` reads as writes or emit mutation messages for them.

- [ ] **Step 5: Add deterministic supporting-write settlement**

Pass `supportingAttempts` into `_settleNoToolUse`. Before issuing a correction:

```dart
final planAttempt = supportingAttempts['plan_task'];
if (planAttempt != null && !planAttempt.succeeded &&
    terminalAttempts['create_schedule_relation'] == null) {
  return _GroundedSettlement.overrideSupportingFailure;
}
```

When Relation is non-success after successful `plan_task`, return `_GroundedSettlement.partialFailure`. When correction is exhausted after successful `plan_task` and no Relation attempt exists, also return `partialFailure` with `relation_not_grounded_after_plan`.

Add fixed safe messages:

```dart
static String _supportingFailureText(String? code) => switch (code) {
  'user_declined' => '本次安排已取消，未创建执行时间段，也未保存不冲突关系。',
  'cancelled' => '本次安排已停止，未创建执行时间段，也未保存不冲突关系。',
  _ => '执行时间段未创建，不冲突关系也未保存，请检查信息后重试。',
};

static String _partialRelationFailureText(String? code) => switch (code) {
  'user_declined' => '执行时间段已创建，但不冲突关系已取消、尚未保存。',
  'cancelled' => '执行时间段已创建，但不冲突关系未保存。',
  _ => '执行时间段已创建，但不冲突关系未保存，请检查后重试。',
};
```

Run state remains `failed` when the complete user request is only partially fulfilled. Preserve the successful PlanBlock and its ActionLog; do not roll it back when Relation is declined or fails.

- [ ] **Step 6: Keep retry and tool budgets bounded**

Assert the exact successful workflow stays within 8 model calls and 12 tool calls. The two independent reads may share one provider turn; dependent writes must remain separate. Existing `repeated_tool_call` fingerprints and forced correction limits remain unchanged.

- [ ] **Step 7: Run Task 3 tests and verify GREEN**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_session_service_test.dart
Pop-Location
git diff --check
```

- [ ] **Step 8: Commit Task 3**

```powershell
git add app/lib/features/agent/application/agent_session_service.dart app/test/features/agent/agent_session_service_test.dart
git commit -m "fix(agent): preserve partial relation workflow results"
```

### Task 4: Composition Regression, Manual Retest And Embedded Handoff

**Files:**
- Modify: `app/test/integration/agent_composition_flow_test.dart`
- Modify: `app/test/integration/read_only_agent_flow_test.dart` only if the real composition path needs an assertion; do not duplicate Task 3 unit cases.
- Modify: `docs/agent-relation-closure-retest-2026-08-02.md`
- Modify: `docs/superpowers/plans/2026-08-03-agent-date-bounded-relation-lookup.md`

**Interfaces:**
- Consumes: Tasks 1-3 production behavior.
- Produces: one real local composition regression, one owner-fillable Release test item, and final execution evidence in this plan.

- [ ] **Step 1: Add a real local-tool composition test**

Seed one account with:

```text
Task: 生命科学简史课作业
2026-09-01 07:50-09:25: 计算机网络
2026-09-01 09:45-11:20: 非线性电子线路
2026-09-01 15:55-17:30: 半导体材料与物理
```

Use the exact real user sentence. Script five-tool sequencing through the real registry, confirmation store, Drift gateway and Relation writer. Assert:

```dart
expect(planBlocksForTask, hasLength(1));
expect(relations, hasLength(1));
expect(relations.single.conflictState, 'no_conflict');
expect(run.status, AgentRunState.completed);
expect(invocationErrors, isNot(contains('relation_lookup_requires_bound')));
expect(invocationErrors, isNot(contains('protocol_error')));
```

Also assert the Relation pair is event/PlanBlock, both participants belong to the same account, and no Task or course title was guessed or newly created.

- [ ] **Step 2: Run composition tests and verify GREEN**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/integration/agent_composition_flow_test.dart test/integration/read_only_agent_flow_test.dart
Pop-Location
```

- [ ] **Step 3: Append one manual acceptance item without overwriting results**

Open `docs/agent-relation-closure-retest-2026-08-02.md`, preserve every existing line after `完成：`, and append a new numbered section containing:

- the exact original sentence;
- expected date-only `get_schedule` result with three candidate events;
- expected `get_tasks -> get_schedule -> plan_task -> get_plan_blocks -> create_schedule_relation` order;
- two sequential confirmation checkpoints when policy requires them;
- final schedule showing course + PlanBlock with no conflict warning;
- failure recording fields for tool names, counts and safe error codes;
- a final blank `完成：`.

- [ ] **Step 4: Run the focused regression suite**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_grounding_policy_test.dart test/features/agent/agent_context_builder_test.dart test/features/agent/agent_session_service_test.dart test/integration/agent_composition_flow_test.dart test/integration/read_only_agent_flow_test.dart
Pop-Location
```

Expected: all focused tests pass with zero failures.

- [ ] **Step 5: Run complete repository verification**

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

Record exact Python test count, Flutter test count, analyze result, Release output path and command exit states in this plan under “Execution Evidence”. Automatic verification does not mark the manual `完成：` field.

- [ ] **Step 6: Perform final code review**

Use `superpowers:requesting-code-review`. Review specifically:

1. same-day no-query reads events, while unbounded/multi-day relation reads do not;
2. plain relation requests do not receive task planning tools;
3. original request receives exactly five tools and never `create_task`;
4. dependent writes cannot be issued against a missing PlanBlock ref;
5. partial-success messages never claim no data changed;
6. no semester literal, raw ref, account ID or sensitive argument enters logs;
7. unrelated free chat and existing relation tests remain valid.

Fix accepted findings with a failing regression first, rerun affected tests, then rerun the focused suite.

- [ ] **Step 7: Update the embedded execution handoff**

In the “Execution Evidence” section at the end of this file, replace the pre-execution snapshot with:

- exact final HEAD and ordered Task commit hashes;
- files changed by each Task;
- exact focused/full verification counts and Release executable path;
- remaining manual acceptance status;
- any accepted residual limitation;
- current `git status --short`, explicitly distinguishing protected pre-existing files from implementation changes.

Do not create another handoff document.

- [ ] **Step 8: Commit Task 4**

Stage explicit files only:

```powershell
git add app/test/integration/agent_composition_flow_test.dart docs/agent-relation-closure-retest-2026-08-02.md docs/superpowers/plans/2026-08-03-agent-date-bounded-relation-lookup.md
git add app/test/integration/read_only_agent_flow_test.dart
git commit -m "test(agent): close date-bounded relation workflow"
```

Omit `read_only_agent_flow_test.dart` from staging if it was not modified. Never use `git add .`.

## Manual Acceptance Focus

1. Send the exact 2026-09-01 request in a new Release process with the real school model.
2. Verify the Agent obtains all three local events through one exact-day query without asking for “计算机网络”.
3. Verify it locates the existing Task and creates exactly one accepted PlanBlock at 07:50-09:25.
4. Verify it queries the newly created PlanBlock ref before proposing the Relation.
5. Verify the final Relation is `no_conflict`, the red warning disappears, and both schedule items remain visible.
6. Verify cancellation at the first confirmation modifies nothing; cancellation at the second retains the PlanBlock and reports partial completion.
7. Verify no `relation_lookup_requires_title`, repeated call storm, `grounding_failed` or `protocol_error` ends the run.

## Embedded Execution Handoff

### Pre-Execution Snapshot

- Workspace: `E:/107/.worktrees/write-tools`
- Branch: `feature/write-tools`
- Plan baseline HEAD: `dd73551` (`docs: design date-bounded relation lookup`)
- Design authority: `docs/superpowers/specs/2026-08-03-agent-date-bounded-relation-lookup-design.md`
- Last recorded full Flutter baseline before this plan: 896 tests passed, analyze clean, Windows Release built; this is historical evidence from `docs/read-only-agent-handoff.md`, not fresh verification for this plan.
- Current defect evidence: exact request ended `failed/protocol_error`; 11 tool invocations, 8 errors, five `relation_lookup_requires_title`; local 2026-09-01 contained three course events; neither `plan_task` nor `create_schedule_relation` ran.

### Protected Pre-Existing Worktree State

At plan creation, these paths were already modified or untracked and must not be reverted, overwritten wholesale or staged accidentally:

```text
M  app/windows/flutter/generated_plugin_registrant.cc
M  app/windows/flutter/generated_plugin_registrant.h
M  app/windows/flutter/generated_plugins.cmake
M  docs/agent-relation-closure-retest-2026-08-02.md
?? docs/agent-manual-acceptance-retest-2026-08-01.md
?? docs/agent-manual-acceptance-review-handoff-2026-08-02.md
?? docs/agent-testing.md
?? docs/superpowers/plans/2026-08-02-agent-manual-acceptance-review-repairs.md
```

The retest document is intentionally modified and will be appended in Task 4. Read it first and preserve every existing `完成：` value. The other listed files are outside this plan unless a later explicit user instruction changes scope.

### Executor Start Order

1. Read this plan and the design authority completely.
2. Run `git status --short` and compare it with the protected snapshot.
3. Read current implementations of `AgentGroundingRequirement`, `_settleNoToolUse`, the relation lookup intercept, `AgentSystemPrompt.version5`, and existing Task 3 relation tests.
4. Execute Tasks 1-4 in order with TDD and one commit per Task.
5. Never trust historical test counts; rerun the commands listed in each Task.
6. Stop and report before coding if the branch, protected files, tool names, confirmation protocol or Relation schema differs materially from this plan.

### Execution Evidence

This subsection records the measured final execution evidence collected by Task 4 Step 7. Automatic verification does not mark the manual `完成：` field in the retest document.

**Implementation status: COMPLETED** on branch `feature/write-tools`.

```text
Final HEAD (Task 4 commit): e1e99aa (test(agent): close date-bounded relation workflow)
Ordered Task commit hashes (oldest first):
  Task 1  66c625f fix(agent): allow exact-day relation lookups
  Task 2  92ad76d feat(agent): expose task planning for relation runs
  Task 3  55b7dfe fix(agent): preserve partial relation workflow results
  Task 4  e1e99aa test(agent): close date-bounded relation workflow
Baseline (plan/design): 0d12c37 docs: plan date-bounded relation lookup /
                         dd73551 docs: design date-bounded relation lookup

Files changed by each Task:
  Task 1 (66c625f): app/lib/features/agent/application/agent_session_service.dart
                    app/test/features/agent/agent_session_service_test.dart
  Task 2 (92ad76d): app/lib/features/agent/application/agent_context_builder.dart
                    app/lib/features/agent/application/agent_grounding_policy.dart
                    app/lib/features/agent/application/agent_system_prompt.dart
                    app/test/features/agent/agent_context_builder_test.dart
                    app/test/features/agent/agent_grounding_policy_test.dart
  Task 3 (55b7dfe): app/lib/features/agent/application/agent_session_service.dart
                    app/test/features/agent/agent_session_service_test.dart
  Task 4 (e1e99aa):
    app/lib/features/agent/application/agent_session_service.dart  (production fix)
    app/test/integration/agent_composition_flow_test.dart           (real composition regression)
    docs/agent-relation-closure-retest-2026-08-02.md                 (manual retest item 10)

Focused regression suite (5 files): PASSED — 184 tests, zero failures
  agent_grounding_policy_test, agent_context_builder_test,
  agent_session_service_test, agent_composition_flow_test, read_only_agent_flow_test
Full Flutter test suite: PASSED — 910 tests, zero failures (flutter test)
Flutter analyze: 0 issues found (clean)
Windows Release build: SUCCEEDED
  E:/107/.worktrees/write-tools/app/build/windows/x64/runner/Release/ustc_assistant_app.exe
Python (E:/107, conda env ustc_assistant): 388 tests, OK (unittest discover -s tests -v)
Python compileall (src tests): OK, exit 0
git diff --check: clean (exit 0)
```

**Real production defect found and fixed (Task 4):** When a relation run's `create_schedule_relation`
call matched the expected conflict state (the normal date-bounded no_conflict path), the
`needsUserAction` write confirmation pause was bypassed because the pause handler lived only in the
generic `else` branch, while the matching-state relation call was dispatched by the
`else if (... expectedConflictState != null)` branch. The relation's confirmation card never paused;
the run settled as `relation_not_grounded_after_plan` and the write could not be confirmed. The fix
moved the mismatch branch to fire only on `_relationStateMismatches(...) == true`, so a matching
relation falls through to the generic execute + needsUserAction pause path. Red→green evidence: the
new composition regression (`exact-day relation workflow`) failed with
`relation_not_grounded_after_plan` before the fix and passed after; all 82 pre-existing
agent_session_service tests (including the two expected-state-mismatch cases) still pass unmodified.

**Remaining manual acceptance status:** NOT EXECUTED. The owner-fillable manual acceptance is
documented as section 10 (`完成：` blank) in `docs/agent-relation-closure-retest-2026-08-02.md`.
The final code review (Step 6) is handled separately by the controller after Task 4 per the brief;
it has not been run here.

**Accepted residual limitations:**
- The manual Release acceptance (real school model, new Release process) is not executed; only the
  automatic composition regression ran.
- The production fix to `agent_session_service.dart` was not reviewed through requesting-code-review
  (deferred to the separate Step 6 controller review).
- 2026-09-01 is test DATA, never a semester literal; no `semesterId`, `421`, `461`, `2026spring` or
  `2026fall` literal was introduced.

**Current `git status --short` (post Task 4):** distinguishes protected pre-existing files from the
three implementation files staged/committed by Task 4.

```text
M  app/lib/features/agent/application/agent_session_service.dart   [Task 4 implementation]
M  app/test/integration/agent_composition_flow_test.dart           [Task 4 implementation]
M  docs/agent-relation-closure-retest-2026-08-02.md                [Task 4 append]
M  app/windows/flutter/generated_plugin_registrant.cc              [protected pre-existing]
M  app/windows/flutter/generated_plugin_registrant.h               [protected pre-existing]
M  app/windows/flutter/generated_plugins.cmake                     [protected pre-existing]
?? docs/agent-manual-acceptance-retest-2026-08-01.md               [protected untracked]
?? docs/agent-manual-acceptance-review-handoff-2026-08-02.md       [protected untracked]
?? docs/agent-testing.md                                           [protected untracked]
?? docs/superpowers/plans/2026-08-02-agent-manual-acceptance-review-repairs.md [protected untracked]
```

Protected pre-existing files (3 Windows generated files + the modified retest doc + 4 untracked
user docs) are preserved unchanged except the retest doc, which was appended (item 10) with every
existing `完成：` value intact. Implementation changes are limited to the three Task 4 files above.
```

## Self-Review

**Spec coverage:** Spec §4 single-day query is Task 1; §5 conditional tools is Task 2; §5.2 sequencing and §5.3 terminal truth are Task 3; §6 prompt is Task 2; §7 errors are Tasks 1/3; §8-11 integration, manual acceptance, security and completion are Task 4.

**Scope:** No Python, Bridge, schema, SourceBundle, mobile, Task model or new tool work is included. The only additional runtime state is a structured result for an already executed supporting write, needed to avoid false “没有修改数据” output.

**Type consistency:** `supportingTools` is defined in Task 2 and consumed in Task 3; `requiredTools` includes it for corrective declarations but settlement still treats only `terminalTools` as full-success authority. `_MutationAttempt` replaces `_TerminalMutationAttempt` in Task 3 and is used by both terminal and supporting maps. Prompt version 6 is defined in Task 2 and consumed by `AgentContextBuilder` in the same Task.

**Placeholder scan:** The only pre-execution status text is an explicit measured-state record required by the embedded handoff. It is replaced with actual evidence by Task 4 Step 7; there are no undefined implementation decisions, generic testing instructions or missing interfaces.
