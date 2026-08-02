# Agent Relation Closure Repair Handoff (2026-08-02)

## 1. Objective

在 `E:/107/.worktrees/write-tools` 的 `feature/write-tools` 分支执行：

`docs/superpowers/plans/2026-08-02-agent-relation-closure-repairs.md`

设计依据：

`docs/superpowers/specs/2026-08-02-agent-relation-closure-repair-design.md`

推荐使用 `superpowers:subagent-driven-development`，每个 Task 使用新的实现子 Agent，并在每个 Task 后进行 spec compliance 和 code quality 两阶段审查。若不使用子 Agent，则使用 `superpowers:executing-plans` 严格逐项执行。所有行为改动先使用 `superpowers:test-driven-development`，最终声明完成前使用 `superpowers:verification-before-completion`。

## 2. Starting State

- Worktree: `E:/107/.worktrees/write-tools`
- Branch: `feature/write-tools`
- Handoff implementation HEAD: `3bdb26eb93bd689672e836cfc87eb6faf58c647b`
- Latest commits at planning time:

```text
3bdb26e docs: cover semester task query workflow
57f4eb5 docs: design agent relation closure repairs
029b794 docs: refresh read-only-agent handoff with review-repair HEAD
bc1a69b test(agent): close review repair regressions
```

The plan and this handoff are documentation-only additions after the approved Spec. No implementation code for this repair round was changed while writing them.

Before beginning:

```powershell
git branch --show-current
git rev-parse HEAD
git status --short
```

If HEAD is newer only because the plan/handoff documentation was committed, record that document commit and continue. If implementation commits appeared, review them against the Spec before Task 1.

## 3. Preserve Existing Dirty Files

These files existed before this planning turn. Do not stage, overwrite, delete, normalize or rewrite them:

```text
 M app/windows/flutter/generated_plugin_registrant.cc
 M app/windows/flutter/generated_plugin_registrant.h
 M app/windows/flutter/generated_plugins.cmake
?? docs/agent-manual-acceptance-retest-2026-08-01.md
?? docs/agent-manual-acceptance-review-handoff-2026-08-02.md
?? docs/agent-testing.md
?? docs/superpowers/plans/2026-08-02-agent-manual-acceptance-review-repairs.md
```

The untracked retest documents contain user-authored evidence. Never change their `完成：` text or mark failed/blank items successful. Use explicit `git add <paths>`; never use `git add .`.

## 4. What Already Works

- Windows Flutter first milestone, local SQLite model and five Python read-only sources exist.
- The school Anthropic-compatible Agent, local read tools and 11 confirmed write tools exist.
- `create_schedule_relation` already resolves event and PlanBlock refs and writes corresponding FK columns.
- Week projection already renders PlanBlocks and derives event/PlanBlock overlap conflicts.
- Multiple `create_task` calls in the “电磁场与波每周六作业” real test ultimately succeeded.
- `get_schedule(view=course_summary)` returns grouped courses with active range, teachers, locations, patterns and count.
- Duplicate fingerprint, model/tool budgets, `tool_choice` compatibility fallback and terminal mutation outcome structures exist.

Do not replace these systems. Close the remaining gaps around them.

## 5. Confirmed Remaining Problems

### Relation request

- First attempt may call ordinary `get_schedule` over a semester, wait too long and fail before narrowed calls succeed.
- “选择去量子物理 B” was stored as `conflict` with prose in `reason`; overlap already derived conflict, so UI appeared unchanged.
- Approved meaning is `no_conflict` after a concrete choice/coexistence strategy, without automatically changing attendance/listening overlays.

### Mixed overlap management

- Agent persistence supports PlanBlock refs, but manual `ConflictService` and `ConflictManagementPage` are event-only.
- A course with a PlanBlock can show overlap warnings but cannot be classified from overlap UI.
- Reverse relation pairs are not consistently canonicalized in the Agent gateway.

### Diagnostics

- `tool_invocations` exists but is never populated, so screenshots cannot be reconstructed after restart.
- Approved migration is v5 -> v6 with nullable `errorCode`.

### Day move closure

- A confirmed `move_jw_course_day` succeeded in SQLite but the run later displayed `grounding_failed` for the real phrasing.
- Global Snackbar can remain visible and cover chat. It must become a schedule-local six-second notice while retaining one-step undo.

### Semester-backed Task query

- Task creation succeeded; do not redesign it.
- The defect is the preventable first large-range `events` query.
- Add prompt guidance plus deterministic `schedule_summary_required`; preserve course summary and concrete title query modes.

## 6. Product Decisions That Must Not Be Reopened

1. Effective conflict states remain only `conflict` and `no_conflict`.
2. A concrete choice, coexistence decision or “do homework during class” strategy is `no_conflict`.
3. An unresolved decision explicitly recorded as conflict remains `conflict`.
4. Relation writes do not automatically alter attendance/listening overlays.
5. PlanBlock relations are occurrence-only; no fake series identity.
6. No repeated Task model or batch tool; the Agent may call `create_task` repeatedly after clarifying details.
7. Existing successful multi-Task behavior and general tool budget remain unchanged.
8. No new system reminder is added for these Tasks.
9. No default semester or semester ID is embedded in Agent behavior.

## 7. Execution Order And Review Gates

Execute Tasks 1-8 in order:

1. Schema/repository lifecycle.
2. Session persistence and chat restoration.
3. Relation Grounding and terminal settlement.
4. Unified relation participant/persistence.
5. Mixed relation UI.
6. Local day-move notice.
7. Semester summary guard and prompt.
8. Integration, retest document, full verification and handoff refresh.

After every Task, report:

```text
Task N complete
Changed: <high-signal summary>
Tests: <exact commands and actual pass/fail counts>
Commit: <hash>
Next: Task N+1
```

Do not work silently through multiple Tasks. Stop if a required change would modify Python source contracts, SourceBundle, school write behavior, Task recurrence schema, permission semantics or default semester.

## 8. Verification Requirements

Focused commands are listed in each Task. Final verification:

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

Record actual output and counts. A green suite does not mean real school model/API, network, Edge login, confirmation cards or Release UI passed manual acceptance.

## 9. Handoff Back To The Owner

At completion provide:

- each Task commit hash;
- focused red/green evidence;
- final full command outputs and Release path;
- final `git status --short`, separating preserved dirty files;
- updated `docs/read-only-agent-handoff.md` with exact final HEAD;
- new `docs/agent-relation-closure-retest-2026-08-02.md` with blank `完成：` fields;
- remaining manual tests requiring the real school API/network.

Never claim manual acceptance for the owner or overwrite prior test results.
