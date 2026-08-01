# Agent Manual Acceptance Debug Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复真实模型验收暴露的 Agent 工具落地、重复调用、文本泄露、历史事件定位、PlanBlock 周视图、冲突派生和本地导航问题，并新增受确认保护的整日教务课程移动。

**Architecture:** 会话层以保守意图策略和一次受限 `tool_choice` 纠错保证明确事实/写请求落到工具，同时用增量文本过滤器和 fingerprint 熔断保持自由聊天与流式体验。日程层新增统一 `ScheduleGridItem`、pair-level 冲突投影和账户隔离 `JwDayMove` 覆盖表；来源事件保持不可变，移动、PlanBlock 和 CalendarEvent 在同一周网格与冲突引擎中展示。

**Tech Stack:** Dart/Flutter 3.44.5、Drift/SQLite、Anthropic Messages SSE、现有 Python 3.10+ 测试基线；不新增第三方依赖，不修改 Python 校园来源实现。

## Global Constraints

- 设计依据：`docs/superpowers/specs/2026-08-01-agent-manual-acceptance-debug-design.md`，提交 `aaef1cf`。Plan 与 Spec 冲突时以 Spec 为准并先报告用户。
- 只在 `E:/107/.worktrees/write-tools` 的 `feature/write-tools` 分支实施；开始 HEAD 至少包含 `aaef1cf`，完成后不得自行合并 `main`。
- 不修改、暂存或提交用户文件 `docs/agent-testing.md`，也不得回退现有脏文件 `app/windows/flutter/generated_plugin_registrant.*` 与 `generated_plugins.cmake`。
- Python 只使用 Conda 环境 `ustc_assistant`；禁止安装依赖、禁止修改 base 环境。自动测试不得访问学校网站、学校 API 或真实 Edge。
- 本计划不修改 `src/ustc_assistant/sources/campus/`、Python Query Result/Bridge 校园契约、校园公开引用 chip 或 iCourse 授权体验。
- 时间统一为 `Asia/Shanghai`；不得在 Agent、日程移动或测试中硬编码 `421`、`461`、`2026spring`、`2026fall`。
- `ref_*` 只在当前 run 的模型/工具协议中存在，不得进入 UI、ChatRepository、摘要、确认卡或 ActionLog。
- 所有写工具继续经过 AgentPermissionPolicy、确认卡、原子 `AgentWriteUnitOfWork` 和审计；`move_jw_course_day` 为 critical 且永远确认。
- 二课报名/取消、教务系统和其他外部写操作永久禁止；整日调课只改本地覆盖记录。
- 每个 Task 先新增失败测试并实际确认红灯，再最小实现、绿灯、精确 `git add` 和独立提交；禁止 `git add .`。
- Drift 表变化必须在 `app/` 下运行现有 build_runner，并提交生成的 `app_database.g.dart`；不得手改生成文件。

## File Map

- Create `app/lib/features/agent/application/agent_grounding_policy.dart`: 保守识别必须查询/写入的受支持意图。
- Create `app/lib/features/agent/application/assistant_text_filter.dart`: SSE 增量过滤历史时间戳与 refs。
- Create `app/lib/features/agent/application/tool_call_fingerprint.dart`: 规范化参数、熔断同 run 重复调用。
- Modify `app/lib/features/agent/domain/llm_protocol.dart`, `data/anthropic_llm_provider.dart`: `tool_choice` 协议和兼容回退。
- Modify `app/lib/features/agent/application/agent_session_service.dart`: grounded-tool 纠错、写成功证据、文本与重复调用保护。
- Modify `app/lib/features/agent/application/agent_tools.dart`: `get_schedule(query=...)` 与 pair-level `get_conflicts`。
- Modify `app/lib/features/agent/application/agent_system_prompt.dart`: 最终一次升级到 version 4。
- Create `app/lib/features/schedule/domain/schedule_grid_item.dart`: CalendarEvent/PlanBlock 周视图统一类型。
- Create `app/lib/features/schedule/application/schedule_conflict_projection.dart`: 显式关系优先的冲突派生。
- Create `app/lib/features/schedule/domain/jw_day_move.dart`: 整日教务移动领域类型和日期平移。
- Create `app/lib/features/schedule/application/jw_day_move_service.dart`: preview/move/clear/undo 的账户隔离服务。
- Create `app/lib/features/schedule/presentation/jw_day_move_dialog.dart`: 日程页手动预览和确认界面。
- Modify `app/lib/core/database/tables/schedule_tables.dart`, `app_database.dart`, generated file: `JwDayMoves` schema 5。
- Modify schedule repositories/projection/presentation: 应用移动、显示 PlanBlock、统一冲突与详情时间。
- Modify Agent write gateway/tools/composition/permission policy: 第 11 个写工具 `move_jw_course_day`。
- Modify router/chat/schedule page: 导航 chip 选择明确分区。
- Modify maintained docs and acceptance checklist at final closure; never edit the user's result file.

---

### Task 1: Ground Explicit Operational Requests While Preserving Free Chat

**Files:**
- Create: `app/lib/features/agent/application/agent_grounding_policy.dart`
- Create: `app/test/features/agent/agent_grounding_policy_test.dart`
- Modify: `app/lib/features/agent/domain/llm_protocol.dart`
- Modify: `app/lib/features/agent/data/anthropic_llm_provider.dart`
- Modify: `app/lib/features/agent/application/agent_session_service.dart`
- Test: `app/test/features/agent/anthropic_llm_provider_test.dart`
- Test: `app/test/features/agent/agent_session_service_test.dart`

**Interfaces:**
- Produces `AgentGroundingRequirement? AgentGroundingPolicy.classify(String userText)`.
- `AgentGroundingRequirement` contains `Set<String> lookupTools`, `Set<String> terminalTools`, and `bool mutationIntent`.
- Adds `enum LlmToolChoice { auto, any }` to `LlmRequest`; provider serializes `tool_choice` only when requested.
- Adds at most one forced retry per run and at most one compatibility fallback without `tool_choice`.

- [ ] **Step 1: Write policy tests using the exact manual phrases**

Cover read intents, write intents, capability questions, explicit no-query instructions and free chat:

```dart
expect(
  policy.classify('有哪些需要我确认的课程出勤或听讲？')!.lookupTools,
  {'get_pending_event_reviews'},
);
expect(
  policy.classify('给完成操作系统大作业安排明天下午两点')!.lookupTools,
  {'get_tasks'},
);
expect(
  policy.classify('给完成操作系统大作业安排明天下午两点')!.terminalTools,
  {'plan_task'},
);
expect(policy.classify('你能不能修改日程？'), isNull);
expect(policy.classify('不要查询，只讨论复习方法'), isNull);
expect(policy.classify('你好，介绍一下自己'), isNull);
```

The policy may use conservative phrase families, but must not classify hypothetical/capability/general-advice text as an operation.

- [ ] **Step 2: Run the new policy test and verify red**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_grounding_policy_test.dart
Pop-Location
```

Expected: FAIL because `AgentGroundingPolicy` is missing.

- [ ] **Step 3: Add typed Anthropic `tool_choice` serialization**

Implement a closed type rather than accepting an arbitrary map:

```dart
enum LlmToolChoice { auto, any }

Map<String, String> get toolChoiceJson => {'type': name};
```

`LlmRequest` defaults to `auto`; normal requests keep current behavior. Corrective requests emit `{"type":"any"}`. Provider tests must inspect the actual POST body and prove no request contains an unknown tool or credential.

- [ ] **Step 4: Add the bounded grounding state machine**

At `send()` start, classify only the current user text. Track successful tool names for the run. When a model call returns without tool use:

1. `requirement == null` -> accept as free chat;
2. required lookup/terminal tool already succeeded -> accept final answer;
3. no required tool succeeded and no corrective call used -> append fixed application correction, narrow declarations to registered required tools, and call once with `any`;
4. `protocol_error` occurs before content on that `any` request -> repeat that same corrective request once with `auto` and mark the provider instance as not supporting forced choice for this session;
5. no legal required tool after correction/fallback -> replace unsupported model text with `我还没有实际查询或执行这项操作，请重试。`, terminal safe code `grounding_failed`.

For mutation intents, lookup success alone is insufficient: a terminal write tool must complete successfully after confirmation before success prose is accepted. User decline/cancel/error remains grounded as an attempted operation but final text must report the actual non-success result.

- [ ] **Step 5: Add session regressions**

Script provider turns for:

- pending event review: plain answer -> forced tool use -> grounded final;
- PlanBlock review: same path;
- plan task hallucination: two success prose responses without `plan_task` -> deterministic `grounding_failed`, no DB write/log;
- free greeting: one `auto` call, no tools, original response preserved;
- capability question: no forced write;
- forced-choice protocol error: one fallback auto request, no infinite retry;
- stop/cancel during corrective request: no subsequent model call.

- [ ] **Step 6: Run focused tests and commit**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_grounding_policy_test.dart test/features/agent/anthropic_llm_provider_test.dart test/features/agent/agent_session_service_test.dart
Pop-Location
git add app/lib/features/agent/application/agent_grounding_policy.dart app/lib/features/agent/domain/llm_protocol.dart app/lib/features/agent/data/anthropic_llm_provider.dart app/lib/features/agent/application/agent_session_service.dart app/test/features/agent/agent_grounding_policy_test.dart app/test/features/agent/anthropic_llm_provider_test.dart app/test/features/agent/agent_session_service_test.dart
git commit -m "fix(agent): ground explicit operational requests"
```

---

### Task 2: Sanitize Streamed Text And Stop Duplicate Tool Loops

**Files:**
- Create: `app/lib/features/agent/application/assistant_text_filter.dart`
- Create: `app/lib/features/agent/application/tool_call_fingerprint.dart`
- Create: `app/test/features/agent/assistant_text_filter_test.dart`
- Create: `app/test/features/agent/tool_call_fingerprint_test.dart`
- Modify: `app/lib/features/agent/application/agent_session_service.dart`
- Test: `app/test/features/agent/agent_session_service_test.dart`
- Test: `app/test/features/agent/chat_repository_test.dart`

**Interfaces:**
- Produces `AssistantTextFilter.add(String delta) -> String` and `finish() -> String` with bounded carry state.
- Produces `ToolCallFingerprint.of(String toolName, Map<String,Object?> input) -> String` using recursively sorted JSON.
- Session keeps raw per-turn model text separate from filtered display/persistence text.

- [ ] **Step 1: Add filter/fingerprint red tests**

Required examples:

```dart
expect(filterAll(['[2026-08-01T19:', '42] 正文']), '正文');
expect(filterAll(['找到 ref_YCSEZ4aC', 'QvqoVwR6rGyGvw。']), '找到该条目。');
expect(filterAll(['正文时间 [2026-08-01T19:42]']),
    '正文时间 [2026-08-01T19:42]');
expect(fingerprint('get_schedule', {'b': 2, 'a': 1}),
    fingerprint('get_schedule', {'a': 1, 'b': 2}));
```

Also test list order remains significant and nested map order does not.

- [ ] **Step 2: Run tests and verify red**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/assistant_text_filter_test.dart test/features/agent/tool_call_fingerprint_test.dart
Pop-Location
```

- [ ] **Step 3: Integrate an incremental display filter**

Use raw text only in the `LlmMessage` replay. Every UI state and ChatRepository update uses filtered text. Keep enough trailing characters to avoid exposing a split timestamp/ref token. On stream completion flush only safe trailing content.

Maintain `visibleBeforeTurn`. If the turn later emits any tool use, restore the visible draft to `visibleBeforeTurn`; collapsed `AgentToolRunTile` remains the only persisted progress. A final no-tool turn commits its filtered text.

- [ ] **Step 4: Add fingerprint execution guard**

Track per-run outcomes by fingerprint before `AgentToolRegistry.execute`:

- first fingerprint executes;
- exact repeat after success returns `repeated_tool_call` guidance and does not execute;
- exact repeat after `invalid_arguments`, `invalid_write_arguments`, `reference_not_found` or `tool_not_allowed` also does not execute;
- changed arguments execute normally;
- `needsUserAction` pause/resume remains one invocation;
- tool budget still counts the model's attempted duplicate, but not a second registry execution.

- [ ] **Step 5: Add manual-failure regressions**

Reproduce W5 chatter/ref output and W8 repeated `get_conflicts` calls. Assert the completed message has one final answer, no intent-line repetition, no ref/time prefix, one real registry execution per fingerprint and a bounded run.

- [ ] **Step 6: Run focused tests and commit**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/assistant_text_filter_test.dart test/features/agent/tool_call_fingerprint_test.dart test/features/agent/agent_session_service_test.dart test/features/agent/chat_repository_test.dart
Pop-Location
git add app/lib/features/agent/application/assistant_text_filter.dart app/lib/features/agent/application/tool_call_fingerprint.dart app/lib/features/agent/application/agent_session_service.dart app/test/features/agent/assistant_text_filter_test.dart app/test/features/agent/tool_call_fingerprint_test.dart app/test/features/agent/agent_session_service_test.dart app/test/features/agent/chat_repository_test.dart
git commit -m "fix(agent): sanitize output and bound duplicate tools"
```

---

### Task 3: Query Concrete Schedule Targets Across Retained History

**Files:**
- Modify: `app/lib/features/agent/application/agent_tools.dart`
- Modify: `app/test/features/agent/local_agent_tools_test.dart`
- Modify: `app/test/integration/agent_composition_flow_test.dart`

**Interfaces:**
- Extends `get_schedule` with optional `query`.
- `query` without dates searches all retained effective events for the active account and returns at most 20 concrete event refs.
- Existing no-query date defaults and `view=course_summary` remain unchanged.

- [ ] **Step 1: Add failing account/history tests**

Seed March, August and another-account matching events while shared settings use an unrelated default semester. Assert title query returns only same-account valid occurrences and contains no semester key/id in input or payload.

Add same-title candidates with distinct date/time/location, query + summary rejection, 21 matches, hidden/cancelled/missing-source filtering and no-result behavior.

- [ ] **Step 2: Run the focused test and verify red**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/local_agent_tools_test.dart
Pop-Location
```

- [ ] **Step 3: Implement deterministic query mode**

Rules:

```text
query present + no dates  -> all retained effective events
query present + dates     -> title filter inside range
query + course_summary    -> invalid_arguments
no query                  -> current behavior
```

Trim/case-fold title matching. Sort current/future ascending, then past descending. Return concrete occurrence DTOs and refs; 21+ results return `result_too_large` with guidance to provide dates.

- [ ] **Step 4: Add composition regression for historical overlay/relation lookups**

Use a scripted provider that calls `get_schedule(query='计算机网络')` before `create_user_overlay`, and two title queries before `create_schedule_relation`. Assert it never calls `get_conflicts` as a participant finder and no outbound request contains a hardcoded semester.

- [ ] **Step 5: Run focused tests and commit**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/local_agent_tools_test.dart test/integration/agent_composition_flow_test.dart
Pop-Location
git add app/lib/features/agent/application/agent_tools.dart app/test/features/agent/local_agent_tools_test.dart app/test/integration/agent_composition_flow_test.dart
git commit -m "fix(agent): find schedule targets across local history"
```

---

### Task 4: Route Local Action Chips To The Correct Schedule Section

**Files:**
- Modify: `app/lib/app/router.dart`
- Modify: `app/lib/features/schedule/presentation/schedule_page.dart`
- Modify: `app/lib/features/agent/presentation/agent_chat_page.dart`
- Test: `app/test/features/schedule/schedule_page_test.dart`
- Test: `app/test/features/agent/agent_chat_page_test.dart`
- Test: `app/test/integration/agent_composition_flow_test.dart`

**Interfaces:**
- Adds `SchedulePage.initialSection`, default `ScheduleSection.week`.
- Routes schedule action to `/schedule?section=week`; task action to `/schedule?section=tasks`.

- [ ] **Step 1: Add red route/widget tests**

Pump the real router, tap each Agent `ActionChip`, and assert the selected `SegmentedButton` value. Also navigate from tasks back to `?section=week` and prove `didUpdateWidget`/route rebuild changes the visible section rather than preserving stale shell state.

- [ ] **Step 2: Run tests and verify red**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_chat_page_test.dart test/features/schedule/schedule_page_test.dart test/integration/agent_composition_flow_test.dart
Pop-Location
```

- [ ] **Step 3: Implement explicit section routing**

Parse only `week|tasks`; invalid/missing values default to week. Initialize and update `SchedulePage.selected` from `initialSection`. Keep public source Chip and model Markdown links inert.

- [ ] **Step 4: Run focused tests and commit**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_chat_page_test.dart test/features/schedule/schedule_page_test.dart test/integration/agent_composition_flow_test.dart
Pop-Location
git add app/lib/app/router.dart app/lib/features/schedule/presentation/schedule_page.dart app/lib/features/agent/presentation/agent_chat_page.dart app/test/features/schedule/schedule_page_test.dart app/test/features/agent/agent_chat_page_test.dart app/test/integration/agent_composition_flow_test.dart
git commit -m "fix(agent): route local chips to exact sections"
```

---

### Task 5: Project PlanBlocks Into The Week Grid

**Files:**
- Create: `app/lib/features/schedule/domain/schedule_grid_item.dart`
- Modify: `app/lib/features/schedule/domain/schedule_projection.dart`
- Modify: `app/lib/features/schedule/domain/overlap_engine.dart`
- Modify: `app/lib/features/schedule/presentation/schedule_page.dart`
- Modify: `app/lib/features/schedule/presentation/week_timetable.dart`
- Modify: `app/lib/features/schedule/presentation/event_block.dart`
- Modify: `app/lib/features/schedule/presentation/overlap_expansion.dart`
- Test: `app/test/features/schedule/schedule_projection_test.dart`
- Test: `app/test/features/schedule/week_timetable_test.dart`
- Test: `app/test/features/schedule/schedule_page_test.dart`

**Interfaces:**
- Produces `enum ScheduleGridItemKind { event, planBlock }`.
- Produces `ScheduleGridItem.fromEvent(EffectiveEvent)` and `ScheduleGridItem.fromPlanBlock(PlanBlockItem, TaskItem)`.
- Changes `WeekTimetable` selection callback to one discriminated grid item; event routes to event detail, PlanBlock routes to parent Task.

- [ ] **Step 1: Add projection red tests**

Assert accepted and done non-deleted blocks enter the timed grid; suggested/skipped/rescheduled/cancelled/deleted blocks do not. Title falls back to parent Task, color is stable by Task id and accessibility text includes “任务时间段”.

- [ ] **Step 2: Add Drift-backed page/navigation red tests**

Seed a task plus accepted PlanBlock, pump SchedulePage and assert a stable key such as `plan-block-<id>` exists. Tap it and assert `onTaskSelected(parentTaskId)`. Add an event/PlanBlock overlap: first tap opens expansion; second tap chooses the correct detail route.

- [ ] **Step 3: Run tests and verify red**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/schedule/schedule_projection_test.dart test/features/schedule/week_timetable_test.dart test/features/schedule/schedule_page_test.dart
Pop-Location
```

- [ ] **Step 4: Implement the unified presentation type**

Do not manufacture CalendarEvent IDs. Move common display/time/priority/color fields into `ScheduleGridItem`, retaining the original event or PlanBlock/Task identities for callbacks. Refactor `ProjectedEvent` and overlap grouping to consume grid items.

SchedulePage watches account-scoped Tasks, PlanBlocks and effective events. Convert only the approved PlanBlock statuses, preserving existing fixed time-axis dimensions, foreground opacity and blurred background behavior.

- [ ] **Step 5: Run focused tests and commit**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/schedule/schedule_projection_test.dart test/features/schedule/week_timetable_test.dart test/features/schedule/schedule_page_test.dart
Pop-Location
git add app/lib/features/schedule/domain/schedule_grid_item.dart app/lib/features/schedule/domain/schedule_projection.dart app/lib/features/schedule/domain/overlap_engine.dart app/lib/features/schedule/presentation/schedule_page.dart app/lib/features/schedule/presentation/week_timetable.dart app/lib/features/schedule/presentation/event_block.dart app/lib/features/schedule/presentation/overlap_expansion.dart app/test/features/schedule/schedule_projection_test.dart app/test/features/schedule/week_timetable_test.dart app/test/features/schedule/schedule_page_test.dart
git commit -m "fix(schedule): show plan blocks in week view"
```

---

### Task 6: Derive Default Overlap Conflicts With Explicit Overrides

**Files:**
- Create: `app/lib/features/schedule/application/schedule_conflict_projection.dart`
- Modify: `app/lib/features/schedule/application/conflict_service.dart`
- Modify: `app/lib/features/schedule/application/effective_event_repository.dart`
- Modify: `app/lib/features/schedule/domain/schedule_grid_item.dart`
- Modify: `app/lib/features/schedule/presentation/event_block.dart`
- Modify: `app/lib/features/agent/application/agent_local_data_gateway.dart`
- Modify: `app/lib/features/agent/application/agent_tools.dart`
- Test: `app/test/features/schedule/overlay_conflict_test.dart`
- Test: `app/test/features/schedule/week_timetable_test.dart`
- Test: `app/test/features/agent/local_agent_tools_test.dart`
- Test: `app/test/features/agent/write_tools_test.dart`

**Interfaces:**
- Produces `ResolvedConflictPair(left, right, state, origin)`.
- Origins: `derivedOverlap`, `explicitOccurrence`, `explicitSeries`.
- `ScheduleConflictProjection.resolve(items, relationSnapshot)` never persists derived pairs.
- `get_conflicts` adds bounded `conflictPairs` with two run-local participant refs.

- [ ] **Step 1: Add precedence red tests**

Cover:

```text
timed overlap + no row                  -> conflict/derivedOverlap
overlap + occurrence no_conflict        -> noConflict/explicitOccurrence
overlap + effective series no_conflict  -> noConflict/explicitSeries
non-overlap + explicit conflict         -> conflict
same-date all-day only                  -> noConflict
event + PlanBlock overlap               -> conflict
three items + one suppressed pair       -> exactly two conflict pairs
```

- [ ] **Step 2: Run tests and verify red**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/schedule/overlay_conflict_test.dart test/features/agent/local_agent_tools_test.dart
Pop-Location
```

- [ ] **Step 3: Implement account-scoped relation snapshots and resolver**

Canonicalize pair keys. Apply occurrence relation first, then matching series rule, then timed overlap. Explicit conflict remains valid without overlap. Do not insert derived rows. Removing an explicit relation returns to derived behavior.

Replace event-level SQL `has_confirmed_conflict` as the authority with the shared projection; a grid item displays warning when any resolved pair involving it is conflict. Keep storage schema unchanged in this Task.

- [ ] **Step 4: Return pair-level Agent results**

`get_conflicts` returns participant title/time/type/ref and origin. Bind event refs as `event`, PlanBlock refs as `planblock`. Keep a compatibility event summary only if existing privacy/payload tests require it; the pair list is authoritative.

After `create_schedule_relation(no_conflict)` the same pair must disappear from conflict results; explicit non-overlap conflict must appear.

- [ ] **Step 5: Run focused tests and commit**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/schedule/overlay_conflict_test.dart test/features/schedule/week_timetable_test.dart test/features/agent/local_agent_tools_test.dart test/features/agent/write_tools_test.dart
Pop-Location
git add app/lib/features/schedule/application/schedule_conflict_projection.dart app/lib/features/schedule/application/conflict_service.dart app/lib/features/schedule/application/effective_event_repository.dart app/lib/features/schedule/domain/schedule_grid_item.dart app/lib/features/schedule/presentation/event_block.dart app/lib/features/agent/application/agent_local_data_gateway.dart app/lib/features/agent/application/agent_tools.dart app/test/features/schedule/overlay_conflict_test.dart app/test/features/schedule/week_timetable_test.dart app/test/features/agent/local_agent_tools_test.dart app/test/features/agent/write_tools_test.dart
git commit -m "feat(schedule): derive overlap conflicts by default"
```

---

### Task 7: Persist And Project Whole-Day JW Course Moves

**Files:**
- Modify: `app/lib/core/database/tables/schedule_tables.dart`
- Modify: `app/lib/core/database/app_database.dart`
- Regenerate: `app/lib/core/database/app_database.g.dart`
- Create: `app/lib/features/schedule/domain/jw_day_move.dart`
- Create: `app/lib/features/schedule/application/jw_day_move_service.dart`
- Modify: `app/lib/features/schedule/application/effective_event_repository.dart`
- Modify: `app/lib/features/schedule/presentation/event_detail_page.dart`
- Modify: `app/lib/features/tasks/application/undo_service.dart`
- Modify: `app/lib/features/settings/application/settings_service.dart`
- Create: `app/test/features/schedule/jw_day_move_service_test.dart`
- Modify: `app/test/core/database/migration_test.dart`
- Modify: `app/test/features/schedule/event_detail_flow_test.dart`
- Modify: `app/test/features/settings/settings_test.dart`
- Modify: `app/test/features/tasks/plan_block_undo_test.dart`

**Interfaces:**
- Adds Drift `JwDayMoves` and schema version 5, unique `(accountId, sourceDate)`.
- Produces `JwDayMovePreview(sourceDate, targetDate?, courses)` and `JwDayMoveService.preview/move/clear`.
- Adds effective display start/end to `EffectiveEventRecord` while preserving raw `source`.

- [ ] **Step 1: Write migration and domain red tests**

Assert schema 4 -> 5 creates `jw_day_moves`, FK cascades with LocalAccount, unique source date works, source != target check holds, and complete/business-data reset removes rows. Do not seed a default move.

- [ ] **Step 2: Write service red tests**

Seed on source date:

- two `ustc_jw/course` timed events;
- one `ustc_jw/exam`;
- one `ustc_young/second_class`;
- one `user/personal`;
- one all-day event;
- a PlanBlock.

Assert only the two course events are eligible. Test move A->B, retarget A->C, B->C not moving projected A items, clear, no eligible courses, source=target, account isolation, source presence removal/reappearance and one-step undo for insert/update/delete.

- [ ] **Step 3: Run red tests**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/core/database/migration_test.dart test/features/schedule/jw_day_move_service_test.dart
Pop-Location
```

- [ ] **Step 4: Implement table and regenerate Drift**

Table fields and constraints follow Spec section 10.2. Register it in `@DriftDatabase`, bump to 5, and add `if (from < 5) createTable(jwDayMoves)`.

```powershell
Push-Location app
E:\flutter\flutter\bin\dart.bat run build_runner build --delete-conflicting-outputs
Pop-Location
```

- [ ] **Step 5: Implement service and undo snapshots**

`preview` queries original CalendarEvent timestamps and source records; it never consumes already-shifted projection. `move`/`clear` recheck eligibility/target at commit time, write ActionLog and `UndoCommand(kind: 'jw_day_move')` in the caller's transaction pattern. Extend UndoService to restore or delete the exact prior row, account-scoped.

- [ ] **Step 6: Apply moves to every effective read path**

`watchDisplayEvents`, `byId`, `overlappingRecords`, Agent detail DTO, free-time and pending review must use effective moved start/end. Preserve the raw CalendarEvent in `EffectiveEventRecord`; add `effectiveStartAt/effectiveEndAt` so event detail and Agent details display moved time without mutating source identity.

Compute the date delta using Beijing calendar dates, not 24-hour epoch arithmetic. Keep hour/minute/second and duration unchanged.

- [ ] **Step 7: Run focused tests and commit**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/core/database/migration_test.dart test/features/schedule/jw_day_move_service_test.dart test/features/schedule/event_detail_flow_test.dart test/features/settings/settings_test.dart test/features/tasks/plan_block_undo_test.dart
Pop-Location
git add app/lib/core/database/tables/schedule_tables.dart app/lib/core/database/app_database.dart app/lib/core/database/app_database.g.dart app/lib/features/schedule/domain/jw_day_move.dart app/lib/features/schedule/application/jw_day_move_service.dart app/lib/features/schedule/application/effective_event_repository.dart app/lib/features/schedule/presentation/event_detail_page.dart app/lib/features/tasks/application/undo_service.dart app/lib/features/settings/application/settings_service.dart app/test/features/schedule/jw_day_move_service_test.dart app/test/core/database/migration_test.dart app/test/features/schedule/event_detail_flow_test.dart app/test/features/settings/settings_test.dart app/test/features/tasks/plan_block_undo_test.dart
git commit -m "feat(schedule): persist whole-day JW course moves"
```

---

### Task 8: Add The Manual Whole-Day Move UI

**Files:**
- Create: `app/lib/features/schedule/presentation/jw_day_move_dialog.dart`
- Modify: `app/lib/features/schedule/presentation/schedule_page.dart`
- Modify: `app/lib/features/schedule/presentation/week_timetable.dart`
- Create: `app/test/features/schedule/jw_day_move_dialog_test.dart`
- Modify: `app/test/features/schedule/schedule_page_test.dart`

**Interfaces:**
- `JwDayMoveDialog` receives account-scoped service, initial source date and clock.
- Returns a successful target date or clear result; SchedulePage refreshes and navigates to the target week.

- [ ] **Step 1: Add UI red tests**

Test source/target date pickers, preview count/title, source=target error, no-courses disabled confirmation, move, retarget, clear and undo snackbar. Verify preview excludes exam/second-class/personal entries and text fits narrow phone width.

- [ ] **Step 2: Run tests and verify red**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/schedule/jw_day_move_dialog_test.dart test/features/schedule/schedule_page_test.dart
Pop-Location
```

- [ ] **Step 3: Implement a command-oriented dialog**

Add an icon button with tooltip “整日调课” near week navigation. Default source date to selectedDate. Show source, target, eligible course count and titles before enabling confirm. Existing move on source date changes button copy to “更新移动” and exposes “恢复原日期”.

After success, select target week for move/retarget and source week for clear. Use one Snackbar undo action backed by existing UndoService. Do not add per-event checkboxes.

- [ ] **Step 4: Run focused tests and commit**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/schedule/jw_day_move_dialog_test.dart test/features/schedule/schedule_page_test.dart
Pop-Location
git add app/lib/features/schedule/presentation/jw_day_move_dialog.dart app/lib/features/schedule/presentation/schedule_page.dart app/lib/features/schedule/presentation/week_timetable.dart app/test/features/schedule/jw_day_move_dialog_test.dart app/test/features/schedule/schedule_page_test.dart
git commit -m "feat(schedule): add whole-day course move controls"
```

---

### Task 9: Add The Critical Agent Day-Move Tool And Final Prompt Version 4

**Files:**
- Modify: `app/lib/features/agent/domain/agent_write_gateway.dart`
- Modify: `app/lib/features/agent/data/drift_agent_write_gateway.dart`
- Modify: `app/lib/features/agent/application/agent_write_tools.dart`
- Modify: `app/lib/features/agent/application/agent_permission_policy_service.dart`
- Modify: `app/lib/features/agent/application/agent_grounding_policy.dart`
- Modify: `app/lib/features/agent/application/agent_system_prompt.dart`
- Modify: `app/lib/features/agent/application/agent_tools.dart`
- Modify: `app/test/features/agent/write_tools_test.dart`
- Modify: `app/test/features/agent/drift_agent_write_gateway_test.dart`
- Modify: `app/test/features/agent/agent_write_permission_domain_test.dart`
- Modify: `app/test/features/agent/agent_context_builder_test.dart`
- Modify: `app/test/integration/agent_composition_flow_test.dart`

**Interfaces:**
- Adds `move_jw_course_day(action, source_date, target_date?)` as the 11th write tool.
- Action type `move_jw_course_day`, target type `jw_day_move`, risk critical, force confirmation true, rememberAllowed false.
- Bumps `AgentSystemPrompt.version` from 3 to 4 exactly once.

- [ ] **Step 1: Add strict tool red tests**

Cover:

- move requires source/target date; clear requires source only;
- unknown fields, wrong types, malformed dates, same dates -> `invalid_write_arguments`;
- no eligible courses -> `no_eligible_jw_courses` before confirmation;
- preview contains source/target/count/titles but no IDs/refs;
- commit rechecks eligible events and returns `target_not_found`/`no_eligible_jw_courses` safely;
- critical confirmation card never offers remember;
- approve writes atomically and logs success; decline/cancel write nothing;
- update_permission_policy cannot set this action to always_allow.

- [ ] **Step 2: Run tests and verify red**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/write_tools_test.dart test/features/agent/drift_agent_write_gateway_test.dart test/features/agent/agent_write_permission_domain_test.dart
Pop-Location
```

- [ ] **Step 3: Extend the write gateway and register the tool**

Expose only preview/move/clear methods backed by `JwDayMoveService`; no raw table access in the tool. Add policy map/default mode/default risk, but exclude the action from `kAgentPolicyActionTypes` so users/models cannot relax it.

Return result values `moved_jw_course_day`, `retargeted_jw_course_day`, or `cleared_jw_course_day_move`.

- [ ] **Step 4: Publish prompt version 4**

Update prompt tests and add the approved rules:

- refs are transport-only and never printed;
- do not repeat identical lookups;
- do not claim success without successful terminal write tool;
- use `get_schedule(query=..., view=events)` for write targets, never `get_conflicts` as a finder;
- timed overlap defaults conflict, explicit conflict/no_conflict overrides;
- whole-day course move affects only `ustc_jw/course`, always requires confirmation;
- free chat and capability discussion need not call tools.

The grounding policy adds move/clear phrases and terminal tool requirement.

- [ ] **Step 5: Add composition flow**

Script user request “把 8 月 3 日的教务课程移到 8 月 9 日”： model tool use -> critical confirmation -> approve -> moved events in target week -> conflict pair with target event -> no ref in chat. Add decline and free discussion “调休功能是怎么工作的” paths.

- [ ] **Step 6: Run focused tests and commit**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/write_tools_test.dart test/features/agent/drift_agent_write_gateway_test.dart test/features/agent/agent_write_permission_domain_test.dart test/features/agent/agent_context_builder_test.dart test/integration/agent_composition_flow_test.dart
Pop-Location
git add app/lib/features/agent/domain/agent_write_gateway.dart app/lib/features/agent/data/drift_agent_write_gateway.dart app/lib/features/agent/application/agent_write_tools.dart app/lib/features/agent/application/agent_permission_policy_service.dart app/lib/features/agent/application/agent_grounding_policy.dart app/lib/features/agent/application/agent_system_prompt.dart app/lib/features/agent/application/agent_tools.dart app/test/features/agent/write_tools_test.dart app/test/features/agent/drift_agent_write_gateway_test.dart app/test/features/agent/agent_write_permission_domain_test.dart app/test/features/agent/agent_context_builder_test.dart app/test/integration/agent_composition_flow_test.dart
git commit -m "feat(agent): add critical whole-day course moves"
```

---

### Task 10: Close Integration, Documentation And Manual Retest Handoff

**Files:**
- Modify: `app/test/integration/agent_composition_flow_test.dart`
- Modify: `app/test/integration/read_only_agent_flow_test.dart`
- Modify: `app/test/integration/milestone_accessibility_test.dart`
- Modify: `docs/architecture.md`
- Modify: `docs/schedule-data-model.md`
- Modify: `docs/read-only-agent-handoff.md`
- Modify: `docs/acceptance/read-only-agent.md`
- Modify: `AGENTS.md`
- Do not modify: `docs/agent-testing.md`

**Interfaces:**
- No new production interface; closes cross-task regressions and records exact evidence.

- [ ] **Step 1: Add one combined acceptance regression**

Through the real router and injected scripted provider, cover:

1. free chat without tools;
2. pending review first response misses tool, one correction succeeds;
3. historical title lookup -> overlay write without ref output;
4. two historical events -> relation write without conflict lookup loop;
5. plan_task -> PlanBlock visible/clickable in week;
6. overlap default conflict -> explicit no_conflict suppresses;
7. whole-day JW move -> non-JW events unchanged -> undo restores;
8. schedule/task chips select exact sections;
9. account switch isolates moves, refs, tasks and Agent history.

- [ ] **Step 2: Run all automatic verification**

```powershell
$env:PYTHONPATH='E:/107/.worktrees/write-tools/src'
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
Push-Location app
E:\flutter\flutter\bin\flutter.bat analyze
E:\flutter\flutter\bin\flutter.bat test
E:\flutter\flutter\bin\flutter.bat build windows --release
Pop-Location
```

Expected: all commands exit 0. Record fresh counts and exact HEAD; do not copy historical counts.

- [ ] **Step 3: Run safety/configuration scans**

```powershell
rg -n "semesterId\s*[=:]\s*(421|461)|2026spring|2026fall" app/lib/features/agent app/lib/features/schedule
rg -n "ref_[A-Za-z0-9_-]+" app/lib/features/agent/presentation app/test/fixtures
git diff --check
git status --short
```

Expected: no new Agent/schedule hardcoded semester; no concrete user-visible ref fixture; diff clean; protected pre-existing dirty files remain untouched.

- [ ] **Step 4: Synchronize maintained docs**

Document prompt version 4, grounded runtime, title query, PlanBlock grid, derived conflict precedence, `JwDayMove`, critical Agent tool, chip routing, schema 5 and exact verification. Explicitly state:

- Python campus and iCourse UX were not changed;
- campus manual items 13-15 remain pending Flutter source migration;
- real school model/API retest remains pending;
- automatic tests are not manual acceptance.

Add blank `完成：` entries to maintained acceptance documentation for repaired paths. Do not alter the user's observations.

- [ ] **Step 5: Require manual retest and stop**

Request real Release testing for `agent-testing.md` items 4, 5, 9, W4, W5, W8, blank 8/W9, free chat, school `tool_choice` compatibility, cross-semester lookup, day move/clear/undo and both local chips. Leave campus 13-15 unchanged.

- [ ] **Step 6: Commit closure**

```powershell
git add app/test/integration/agent_composition_flow_test.dart app/test/integration/read_only_agent_flow_test.dart app/test/integration/milestone_accessibility_test.dart docs/architecture.md docs/schedule-data-model.md docs/read-only-agent-handoff.md docs/acceptance/read-only-agent.md AGENTS.md
git commit -m "test(agent): close manual acceptance repairs"
```

Do not merge `main`. Report exact commits, verification output, protected dirty files and remaining manual checks.

## Self-Review

- Spec coverage: all in-scope approved behavior maps to Tasks 1-10. Campus/Python and iCourse changes are excluded and preserved as migration requirements in the Spec.
- Placeholder scan: no implementation step contains TBD/TODO or an unspecified “add tests” instruction; every task has files, interfaces, red/green commands and commit scope.
- Type consistency: grounding types precede session use; grid items precede conflict and moves; day-move service precedes UI and Agent tool; prompt is bumped once after final tool registration.
- Safety consistency: free chat remains auto, forced retry is bounded, critical day moves cannot be remembered, source events remain immutable, default semester is never consulted by cross-history lookup.
