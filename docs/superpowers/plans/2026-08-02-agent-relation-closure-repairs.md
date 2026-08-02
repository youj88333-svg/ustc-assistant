# Agent Relation Closure Repairs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复真实人工验收中剩余的关系语义、工具日志、整日移动收口、局部撤销提示和整学期课表误查询问题，并让 CalendarEvent 与 PlanBlock 的重叠关系可由 Agent 和手动界面统一管理。

**Architecture:** 保留现有 Flutter 本地业务模型、11 个写工具和确认门。Drift schema v6 为工具调用增加错误码，`AgentSessionService` 持久化每个 `tool_use` 的安全生命周期；关系层以统一参与者处理 event/PlanBlock，Grounding Policy 限定关系请求及用户已表达的 `conflict/no_conflict`。周视图使用页面局部的 6 秒撤销提示，`get_schedule` 用摘要优先提示与确定性跨度保护避免整学期 occurrence 误查询。

**Tech Stack:** Flutter/Dart、Drift/SQLite、GoRouter、Anthropic Messages SSE、`flutter_test`、Windows Flutter。

**Design authority:** `docs/superpowers/specs/2026-08-02-agent-relation-closure-repair-design.md`。发现设计无法满足时先停止并向主人报告。

## Global Constraints

- 工作区固定为 `E:/107/.worktrees/write-tools`，分支为 `feature/write-tools`。
- 起始实现 HEAD 为 `3bdb26eb93bd689672e836cfc87eb6faf58c647b`；执行前再次记录实际 HEAD。
- Python 使用 Conda 环境 `ustc_assistant`；不得安装依赖或修改 `base`。
- 时间统一使用 `Asia/Shanghai`；不得推算或硬编码 `semesterId`、`421`、`461`、`2026spring`、`2026fall`。
- 不修改 Python 来源、Bridge、SourceBundle、二课报名边界、校园目录 Flutter 迁移或移动端契约。
- 不新增重复 Task、`TaskSeries` 或批量 Task 工具；周期请求继续多次调用 `create_task`。
- 所有 Agent 写操作继续经过风险策略、确认卡、原子事务和 ActionLog。
- 工具日志不得保存 API Key、Cookie、Token、完整学号、数据库 ID、原始 `ref_*`、完整课表或外部正文。
- 自动测试不得访问学校网站，也不能替代真实学校模型、校园网/iWAN、Edge 登录和确认卡验收。
- 开始前已有的三份 Windows 生成文件和未跟踪用户文档必须保留，不得暂存、覆盖或删除。
- 手工修改使用 `apply_patch`；`app_database.g.dart` 只由 Drift/build_runner 生成。
- 每个 Task 采用 TDD，单独提交，并向主人同步修改、测试结果和 commit hash。

## File Structure

**Create:**

- `app/lib/features/agent/application/agent_tool_invocation_summary.dart`：生成可持久化的安全参数/结果摘要。
- `app/lib/features/schedule/presentation/schedule_undo_notice.dart`：日程页局部、固定 6 秒的撤销提示。

**Primary modifications:**

- `app/lib/core/database/tables/agent_tables.dart`、`app_database.dart`：schema 6 与 invocation `errorCode`。
- `app/lib/features/agent/domain/agent_models.dart`、`drift_chat_repository.dart`：invocation 生命周期和恢复查询。
- `app/lib/features/agent/application/agent_session_service.dart`：日志接线、初始工具限定、关系状态校验和 terminal settlement。
- `app/lib/features/agent/application/agent_grounding_policy.dart`、`agent_system_prompt.dart`、`agent_tools.dart`：关系语义和摘要优先。
- `app/lib/features/schedule/application/conflict_service.dart`：统一 event/PlanBlock 参与者。
- `app/lib/features/schedule/presentation/` 与 `app/lib/app/router.dart`：混合关系编辑和局部撤销反馈。

---

### Task 1: Persist Tool Invocation Records And Migrate Schema 5 To 6

**Files:**
- Modify: `app/lib/core/database/tables/agent_tables.dart`
- Modify: `app/lib/core/database/app_database.dart`
- Regenerate: `app/lib/core/database/app_database.g.dart`
- Modify: `app/lib/features/agent/domain/agent_models.dart`
- Modify: `app/lib/features/agent/data/drift_chat_repository.dart`
- Test: `app/test/core/database/migration_test.dart`
- Test: `app/test/features/agent/chat_repository_test.dart`

**Interfaces:**
- Produces `ToolInvocationLifecycleState` and `ToolInvocationRecord`.
- Produces repository methods consumed by Task 2.

- [ ] **Step 1: Add failing fresh-schema and v5 -> v6 tests**

Fresh DB expects schema 6 and `tool_invocations.error_code`. A real v5 fixture must retain one account, run, chat message, invocation, Task, PlanBlock and Relation after upgrade; migrated `errorCode` is null.

```dart
expect(database.schemaVersion, 6);
final columns = await database.customSelect(
  "PRAGMA table_info('tool_invocations')",
).get();
expect(columns.map((r) => r.read<String>('name')), contains('error_code'));
```

Run `E:\flutter\flutter\bin\flutter.bat test test/core/database/migration_test.dart` from `app/`.

Expected: FAIL because current schema is 5.

- [ ] **Step 2: Define schema and domain types**

Add `TextColumn get errorCode => text().nullable()();`, set `schemaVersion => 6`, and add:

```dart
if (from < 6) {
  await migrator.addColumn(toolInvocations, toolInvocations.errorCode);
}
```

Define statuses `running`, `waitingUser` (`waiting_user` in storage), `success`, `error`, `cancelled`, `interrupted`, and this exact record shape:

```dart
class ToolInvocationRecord {
  const ToolInvocationRecord({
    required this.id,
    required this.accountId,
    required this.runId,
    required this.toolName,
    required this.status,
    required this.safeArgumentsSummary,
    required this.safeResultSummary,
    required this.startedAt,
    this.errorCode,
    this.finishedAt,
  });

  final String id;
  final String accountId;
  final String runId;
  final String toolName;
  final ToolInvocationLifecycleState status;
  final String safeArgumentsSummary;
  final String safeResultSummary;
  final String? errorCode;
  final int startedAt;
  final int? finishedAt;
}
```

- [ ] **Step 3: Regenerate Drift code**

```powershell
Push-Location app
E:\flutter\flutter\bin\dart.bat run build_runner build --delete-conflicting-outputs
Pop-Location
```

Expected: only Drift output needed by the schema changes; do not stage unrelated Windows generated files.

- [ ] **Step 4: Add failing repository lifecycle tests**

Cover one-row transitions `running -> waiting_user -> success/error`, cross-account rejection, ordered loading by run IDs, startup recovery to `interrupted`, and account-scoped clear.

```dart
Future<String> startToolInvocation({
  required String accountId,
  required String runId,
  required String toolName,
  required String safeArgumentsSummary,
});
Future<void> markToolInvocationWaiting({
  required String accountId,
  required String invocationId,
});
Future<void> finishToolInvocation({
  required String accountId,
  required String invocationId,
  required ToolInvocationLifecycleState state,
  required String safeResultSummary,
  String? errorCode,
});
Future<List<ToolInvocationRecord>> toolInvocationsForRuns({
  required String accountId,
  required Set<String> runIds,
});
```

- [ ] **Step 5: Implement repository methods transactionally**

Insert verifies run ownership. Updates filter by invocation ID and account, accept only nonterminal rows, and update the existing row. Waiting does not set `finishedAt`; terminal transitions set it once. Recovery includes both `running` and `waiting_user`.

- [ ] **Step 6: Verify and commit**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/core/database/migration_test.dart test/features/agent/chat_repository_test.dart
Pop-Location
git diff --check
git add app/lib/core/database/tables/agent_tables.dart app/lib/core/database/app_database.dart app/lib/core/database/app_database.g.dart app/lib/features/agent/domain/agent_models.dart app/lib/features/agent/data/drift_chat_repository.dart app/test/core/database/migration_test.dart app/test/features/agent/chat_repository_test.dart
git commit -m "feat(agent): persist tool invocation lifecycle"
```

### Task 2: Wire Invocation Lifecycle Into Runs And Restore It In Chat

**Files:**
- Create: `app/lib/features/agent/application/agent_tool_invocation_summary.dart`
- Modify: `app/lib/features/agent/domain/agent_tool.dart`
- Modify: `app/lib/features/agent/application/agent_session_service.dart`
- Modify: `app/lib/features/agent/presentation/agent_chat_page.dart`
- Modify: `app/lib/features/agent/presentation/agent_tool_run_tile.dart`
- Test: `app/test/features/agent/agent_session_service_test.dart`
- Test: `app/test/features/agent/agent_chat_page_test.dart`
- Test: `app/test/features/agent/chat_repository_test.dart`

**Interfaces:** Consumes Task 1 repository lifecycle; produces identical live/restored invocation summaries.

- [ ] **Step 1: Add failing session lifecycle/privacy tests**

Script success, deterministic error, duplicate fingerprint, budget rejection, cancellation, confirmation pause/resume and interrupted recovery. Assert one row per model `tool_use`, including calls blocked before registry execution. The same row ID must move through waiting to terminal.

```dart
expect(rows.single.safeArgumentsSummary, isNot(contains('ref_')));
expect(rows.single.safeArgumentsSummary, isNot(contains('PB2408')));
```

- [ ] **Step 2: Implement deterministic safe summaries**

Expose:

```dart
String summarizeToolArguments(String toolName, Map<String, Object?> arguments);
String summarizeToolResult(AgentToolResult result);
```

Allow only tool name, date fields, safe enums and counts. Hide refs; omit key/token/cookie/password/account/username/id keys; never encode arbitrary nested data. Result summary contains lifecycle, safe error code, top-level counts and safe `result` enum.

- [ ] **Step 3: Persist every tool-use branch**

Insert `running` before cancellation/budget/fingerprint/registry branches; mark waiting before confirmation/login UI; finish the same row after resume; finish duplicates/budget as errors and unstarted calls as cancelled. A log persistence failure must never replay or reverse a successful write.

Change `AgentToolSummary` to carry `ToolInvocationLifecycleState`, `errorCode`, safe summaries and timing so live and restored UI share one shape.

- [ ] **Step 4: Add failing chat-restart tests**

Persist a completed assistant message and three invocation rows, rebuild `AgentChatPage`, assert `工具调用 (3)`, then expand and verify names, states, safe error code and duration. Other-account rows remain absent.

- [ ] **Step 5: Restore rows in one grouped query**

`_loadHistory` collects assistant run IDs, calls `toolInvocationsForRuns` once, groups by run, and attaches summaries. Update `AgentToolRunTile` to render waiting/cancelled/interrupted separately and show safe details only when expanded.

- [ ] **Step 6: Verify and commit**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/chat_repository_test.dart test/features/agent/agent_session_service_test.dart test/features/agent/agent_chat_page_test.dart
Pop-Location
git diff --check
git add app/lib/features/agent/application/agent_tool_invocation_summary.dart app/lib/features/agent/domain/agent_tool.dart app/lib/features/agent/application/agent_session_service.dart app/lib/features/agent/presentation/agent_chat_page.dart app/lib/features/agent/presentation/agent_tool_run_tile.dart app/test/features/agent/chat_repository_test.dart app/test/features/agent/agent_session_service_test.dart app/test/features/agent/agent_chat_page_test.dart
git commit -m "feat(agent): restore persistent tool diagnostics"
```

### Task 3: Bound Relation Runs And Make User Decisions Authoritative

**Files:**
- Modify: `app/lib/features/agent/application/agent_grounding_policy.dart`
- Modify: `app/lib/features/agent/application/agent_session_service.dart`
- Modify: `app/lib/features/agent/application/agent_system_prompt.dart`
- Modify: `app/lib/features/agent/application/agent_write_tools.dart`
- Test: `app/test/features/agent/agent_grounding_policy_test.dart`
- Test: `app/test/features/agent/agent_session_service_test.dart`
- Test: `app/test/features/agent/agent_context_builder_test.dart`
- Test: `app/test/features/agent/write_tools_test.dart`

**Interfaces:** Adds optional `initialAllowedTools` and `expectedConflictState` to `AgentGroundingRequirement`; tool names remain unchanged.

- [ ] **Step 1: Add failing intent/first-request tests**

Expected matrix:

```text
选择去量子物理 B，不去电路基本理论 -> no_conflict
课上写操作系统作业                 -> no_conflict
两个安排可以共存                   -> no_conflict
记录为冲突，我还没决定             -> conflict
记录冲突，我选择去量子物理 B       -> no_conflict
ambiguous relation wording          -> unspecified
国庆要调课，请把10月1号的调到9月26号 -> move_jw_course_day
```

Relation first request declarations must be exactly registered members of `get_schedule`, `get_plan_blocks`, `create_schedule_relation`. Free chat keeps normal tools and `auto`.

- [ ] **Step 2: Extend grounding without semester literals**

Define `ExpectedConflictState { conflict, noConflict }`, optional `initialAllowedTools`, and optional expected state. Concrete decisions outrank the word “冲突”. A two-date `调课` request routes to whole-day move; a single-course move remains update/clarification.

- [ ] **Step 3: Narrow initial and autonomous relation requests**

Compute grounding before token estimation/context build. Use narrowed declarations for both token estimate and every model request in that relation run. Intercept relation `get_schedule` without a nonblank `query` and return `relation_lookup_requires_title` without loading events.

- [ ] **Step 4: Enforce expected state with one correction**

Before executing `create_schedule_relation`, compare `conflict_state`. First mismatch returns `relation_state_mismatch` and fixed guidance; allow one changed call. A second mismatch ends safely without confirmation. Never rewrite model input silently.

Prompt/tool text must state: concrete choice/coexistence/nested work is `no_conflict`; unresolved decision is `conflict`; ambiguity asks first.

- [ ] **Step 5: Lock the real move terminal regression**

For the exact national-holiday sentence, confirm `move_jw_course_day` success, then emit a plain final model turn. Assert run completed, null error, one business write and one success ActionLog. Successful terminal write must not become `grounding_failed` because lookup bookkeeping is absent. If the existing settlement passes after classifier repair, keep the regression and avoid churn.

- [ ] **Step 6: Verify and commit**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_grounding_policy_test.dart test/features/agent/agent_session_service_test.dart test/features/agent/agent_context_builder_test.dart test/features/agent/write_tools_test.dart
Pop-Location
git diff --check
git add app/lib/features/agent/application/agent_grounding_policy.dart app/lib/features/agent/application/agent_session_service.dart app/lib/features/agent/application/agent_system_prompt.dart app/lib/features/agent/application/agent_write_tools.dart app/test/features/agent/agent_grounding_policy_test.dart app/test/features/agent/agent_session_service_test.dart app/test/features/agent/agent_context_builder_test.dart app/test/features/agent/write_tools_test.dart
git commit -m "fix(agent): bound relation decisions and settlement"
```

### Task 4: Unify Event And PlanBlock Relation Persistence

**Files:**
- Modify: `app/lib/features/schedule/application/conflict_service.dart`
- Modify: `app/lib/features/schedule/presentation/conflict_editor.dart`
- Modify: `app/lib/features/agent/data/drift_agent_write_gateway.dart`
- Modify: `app/lib/features/agent/application/agent_write_tools.dart`
- Test: `app/test/features/schedule/overlay_conflict_test.dart`
- Test: `app/test/features/schedule/event_detail_flow_test.dart`
- Test: `app/test/features/agent/write_tools_test.dart`

**Interfaces:** Replaces `EventConflictParticipant` with `ScheduleConflictParticipant`; canonical key is `kind:id`.

- [ ] **Step 1: Add failing mixed/reverse-pair tests**

Cover event/event, event/PlanBlock and PlanBlock/PlanBlock under both states; reverse insertion leaves one row. Include account isolation, missing/deleted PlanBlock, and current-and-future rejection whenever either side is a PlanBlock.

- [ ] **Step 2: Define the unified participant**

```dart
class ScheduleConflictParticipant {
  const ScheduleConflictParticipant({
    required this.kind,
    required this.id,
    required this.title,
    required this.occurrenceDate,
    this.startAt,
    this.endAt,
    this.seriesType,
    this.seriesId,
    this.finiteSeriesEnd,
  });
  // kind is event | plan_block; PlanBlock never gets a fake series
}
```

- [ ] **Step 3: Generalize ConflictService**

Load an account-owned event for `event`, or nondeleted PlanBlock plus parent Task for `plan_block`. Canonicalize occurrence writes by `kind:id`, fill exactly the matching FK columns, and include all four FK columns in undo snapshots. Series rules remain event-series only.

- [ ] **Step 4: Canonicalize Agent gateway writes**

Canonicalize before query/upsert and revalidate both targets inside the existing unit of work. Agent ActionLog remains owned by `AgentWriteTool`; do not duplicate the manual service log/undo.

- [ ] **Step 5: Update editor/tool labels and verify**

Use the unified type in drafts/callbacks. Confirmation previews show safe title/time/type and Chinese state, never IDs/refs. Preserve TOCTOU `target_not_found`.

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/schedule/overlay_conflict_test.dart test/features/schedule/event_detail_flow_test.dart test/features/agent/write_tools_test.dart
Pop-Location
git diff --check
git add app/lib/features/schedule/application/conflict_service.dart app/lib/features/schedule/presentation/conflict_editor.dart app/lib/features/agent/data/drift_agent_write_gateway.dart app/lib/features/agent/application/agent_write_tools.dart app/test/features/schedule/overlay_conflict_test.dart app/test/features/schedule/event_detail_flow_test.dart app/test/features/agent/write_tools_test.dart
git commit -m "feat(schedule): unify event and plan block relations"
```

### Task 5: Expose Mixed Relation Editing From Overlap Expansion

**Files:**
- Modify: `app/lib/features/schedule/presentation/conflict_management_page.dart`
- Modify: `app/lib/features/schedule/presentation/overlap_expansion.dart`
- Modify: `app/lib/features/schedule/presentation/week_timetable.dart`
- Modify: `app/lib/features/schedule/presentation/schedule_page.dart`
- Modify: `app/lib/app/router.dart`
- Test: `app/test/features/schedule/week_timetable_test.dart`
- Test: `app/test/features/schedule/schedule_page_test.dart`
- Test: `app/test/features/schedule/event_detail_flow_test.dart`
- Test: `app/test/accessibility/milestone_accessibility_test.dart`

**Interfaces:** Consumes Task 4 participant; produces `OverlapExpansion.onManageRelations(OverlapGroup)` and a mixed relation route payload.

- [ ] **Step 1: Add failing widget tests**

For all three pair types, first tap opens overlap expansion, which contains `处理重叠关系`; invoking it lists every unordered pair. A three-item group has three pairs. Saving event/PlanBlock as `no_conflict` removes warnings after rebuild while both cards remain visible/selectable.

- [ ] **Step 2: Define a route payload**

```dart
class ConflictManagementRequest {
  const ConflictManagementRequest(this.items);
  final List<ScheduleGridItem> items;
}
```

`/schedule/conflicts` accepts only this payload; missing/invalid extras render an empty-state page. Keep `/events/:eventId/conflicts` and map its loaded event records through the same participant builder.

- [ ] **Step 3: Wire the overlap command**

Pass callbacks `SchedulePage -> _ScheduleData -> WeekTimetable -> OverlapExpansion`. The command closes the dialog and routes with the current group. Existing item selection stays event -> event detail, PlanBlock -> parent Task.

- [ ] **Step 4: Make the editor mixed-safe**

Keep state/reason controls and disable current-and-future if either side lacks stable series identity. If any participant is a PlanBlock, omit foreground radios because PlanBlock has no overlay priority; retain current deterministic ordering and add no persistence field.

- [ ] **Step 5: Verify and commit**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/schedule/week_timetable_test.dart test/features/schedule/schedule_page_test.dart test/features/schedule/event_detail_flow_test.dart test/accessibility/milestone_accessibility_test.dart
Pop-Location
git diff --check
git add app/lib/features/schedule/presentation/conflict_management_page.dart app/lib/features/schedule/presentation/overlap_expansion.dart app/lib/features/schedule/presentation/week_timetable.dart app/lib/features/schedule/presentation/schedule_page.dart app/lib/app/router.dart app/test/features/schedule/week_timetable_test.dart app/test/features/schedule/schedule_page_test.dart app/test/features/schedule/event_detail_flow_test.dart app/test/accessibility/milestone_accessibility_test.dart
git commit -m "feat(schedule): manage mixed overlap relations"
```

### Task 6: Replace Global Day-move Snackbar With A Local Notice

**Files:**
- Create: `app/lib/features/schedule/presentation/schedule_undo_notice.dart`
- Modify: `app/lib/features/schedule/presentation/schedule_page.dart`
- Test: `app/test/features/schedule/schedule_page_test.dart`

**Interfaces:** Produces `ScheduleUndoNotice(message, onUndo)`; does not alter `UndoService` or `JwDayMoveService`.

- [ ] **Step 1: Add failing timing/navigation tests**

Prove the notice disappears at 6 seconds even with `accessibleNavigation: true`, never appears over chat, a second operation replaces the first, undo fires once and hides it, and timeout leaves `undo_slot` intact.

- [ ] **Step 2: Implement page-local timer state**

Render a compact Material notice in a Stack owned by `SchedulePage`. `_showUndoNotice` cancels the old timer, replaces the notice and starts exactly six seconds; `dispose` cancels the timer. Do not use root/global `ScaffoldMessenger`.

- [ ] **Step 3: Preserve one-step undo and verify**

Dismissal changes presentation only. Consecutive operations continue replacing the existing DB undo slot.

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/schedule/schedule_page_test.dart
Pop-Location
git diff --check
git add app/lib/features/schedule/presentation/schedule_undo_notice.dart app/lib/features/schedule/presentation/schedule_page.dart app/test/features/schedule/schedule_page_test.dart
git commit -m "fix(schedule): scope day move undo feedback"
```

### Task 7: Guard Detailed Semester Queries And Clarify Repeated Tasks

**Files:**
- Modify: `app/lib/features/agent/application/agent_tools.dart`
- Modify: `app/lib/features/agent/application/agent_system_prompt.dart`
- Modify: `app/lib/features/agent/application/agent_context_builder.dart`
- Test: `app/test/features/agent/local_agent_tools_test.dart`
- Test: `app/test/features/agent/agent_context_builder_test.dart`
- Test: `app/test/features/agent/agent_session_service_test.dart`

**Interfaces:** Produces `maxDetailedScheduleSpanDays = 31` and `schedule_summary_required`; schemas for `get_schedule` and `create_task` remain unchanged.

- [ ] **Step 1: Add failing range tests**

Cases: no-query events 32 inclusive days rejects before `displayEvents`; 31 days succeeds; semester `course_summary` succeeds; title query with/without dates remains unchanged; default no-date request remains today + 6 days.

- [ ] **Step 2: Implement the named guard**

```dart
const int maxDetailedScheduleSpanDays = 31;
final inclusiveDays = range.through.difference(range.from).inDays + 1;
if (!hasQuery && view == 'events' && inclusiveDays > maxDetailedScheduleSpanDays) {
  return const AgentToolResult(
    status: AgentToolStatus.error,
    errorCode: 'schedule_summary_required',
    payload: {'guidance': '日期范围较大，请改用 view=course_summary；若需要具体课次，请缩小日期范围。'},
  );
}
```

- [ ] **Step 3: Add prompt version 5**

Preserve every v4 rule. Add summary-first for semester overview/course-pattern/task-range requests; recurring Task requests represent independent Tasks; missing date range/deadline/special-week detail must be confirmed; only then call `create_task` repeatedly and report partial outcomes accurately. No hidden default or semester literal.

- [ ] **Step 4: Add session guidance regression**

A scripted wrong semester-wide events call gets `schedule_summary_required`; guidance reaches the next request; a changed `course_summary` succeeds and is not duplicate-blocked. Assert the “电磁场与波每周六作业” prompt rules exist while current multiple-create behavior remains unchanged.

- [ ] **Step 5: Verify and commit**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/local_agent_tools_test.dart test/features/agent/agent_context_builder_test.dart test/features/agent/agent_session_service_test.dart
Pop-Location
git diff --check
git add app/lib/features/agent/application/agent_tools.dart app/lib/features/agent/application/agent_system_prompt.dart app/lib/features/agent/application/agent_context_builder.dart app/test/features/agent/local_agent_tools_test.dart app/test/features/agent/agent_context_builder_test.dart app/test/features/agent/agent_session_service_test.dart
git commit -m "fix(agent): prefer summaries for semester workflows"
```

### Task 8: Integration, Documentation And Verification Closure

**Files:**
- Modify: `app/test/integration/agent_composition_flow_test.dart`
- Modify: `app/test/integration/read_only_agent_flow_test.dart`
- Modify: `app/test/accessibility/milestone_accessibility_test.dart`
- Modify: `docs/read-only-agent-handoff.md`
- Create: `docs/agent-relation-closure-retest-2026-08-02.md`
- Modify only if durable structure changed: `AGENTS.md`

**Interfaces:** Consumes Tasks 1-7; produces final evidence and owner-fillable Release retest checklist.

- [ ] **Step 1: Add composition regressions**

Cover narrowed relation lookup, explicit choice -> `no_conflict`, event/PlanBlock UI relation, successful move -> completed, local notice isolation, persisted diagnostics after restart, over-wide events correction, account switch/reset isolation.

- [ ] **Step 2: Write the manual retest document**

Every item ends in blank `完成：`. Include original relation sentence, course + PlanBlock no-conflict, six-second notice/navigation/undo, Agent move terminal result, restarted diagnostics, and the semester Task summary-first/clarification behavior. Never edit prior user results.

- [ ] **Step 3: Run the complete focused suite**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/core/database/migration_test.dart test/features/agent/chat_repository_test.dart test/features/agent/agent_grounding_policy_test.dart test/features/agent/agent_session_service_test.dart test/features/agent/agent_context_builder_test.dart test/features/agent/local_agent_tools_test.dart test/features/agent/write_tools_test.dart test/features/agent/agent_chat_page_test.dart test/features/schedule/overlay_conflict_test.dart test/features/schedule/event_detail_flow_test.dart test/features/schedule/week_timetable_test.dart test/features/schedule/schedule_page_test.dart test/integration/agent_composition_flow_test.dart test/integration/read_only_agent_flow_test.dart test/accessibility/milestone_accessibility_test.dart
Pop-Location
```

- [ ] **Step 4: Run final full verification**

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

Record exact outputs/counts. Automated success is not manual school/API acceptance.

- [ ] **Step 5: Request final review**

Use `superpowers:requesting-code-review`. Review terminal truth, invocation privacy/lifecycle, expected-state precedence, canonical mixed pairs, PlanBlock scope rejection, notice navigation/timing, and semester independence. Fix accepted findings with regression tests and rerun affected/full checks.

- [ ] **Step 6: Refresh handoff and commit**

Update `docs/read-only-agent-handoff.md` with final HEAD, exact counts, Release result and remaining manual tests. Update `AGENTS.md` only for durable structure changes.

```powershell
git add app/test/integration/agent_composition_flow_test.dart app/test/integration/read_only_agent_flow_test.dart app/test/accessibility/milestone_accessibility_test.dart docs/read-only-agent-handoff.md docs/agent-relation-closure-retest-2026-08-02.md
git commit -m "test(agent): close relation repair regressions"
git status --short
```

Explicitly add any other reviewed file. Never use `git add .`.

## Manual Acceptance Focus

1. The 2026 spring circuit/quantum choice uses bounded title/date lookup and saves `no_conflict`.
2. A PlanBlock inside a course can be marked `no_conflict`; both remain visible and warnings disappear.
3. Day-move feedback disappears after six seconds, never covers chat, and undo works.
4. Confirmed Agent day move ends successfully without trailing `grounding_failed`.
5. Tool calls survive restart and expose no secret, account, ID or raw ref.
6. The semester Task request uses `course_summary`, asks unresolved details and retains working multiple `create_task` behavior.

## Self-Review

**Spec coverage:** §3 relation state -> Task 3; §4 bounded lookup and semester Task -> Tasks 3/7; §5 settlement -> Task 3; §6 logs -> Tasks 1/2; §7 mixed relations -> Tasks 4/5; §8 notice -> Task 6; §9 errors -> Tasks 2/3/7; §10-13 closure -> Task 8.

**Placeholder scan:** No TBD/TODO, deferred implementation instruction, generic “add tests”, or undefined neighboring interface remains.

**Type consistency:** `ToolInvocationLifecycleState` is defined in Task 1 and consumed in Task 2; `ScheduleConflictParticipant` is defined in Task 4 and consumed in Task 5; Grounding fields are defined/consumed in Task 3; summary guard names are defined/tested in Task 7. No task changes SourceBundle, write-tool names, default semester or Task schema.
