# Flutter Task Planning and Reminder Design

## 1. Purpose

This document defines the non-LLM task, manual planning, local reminder, and
one-step undo capabilities included in the first Windows milestone.

The App later migrates the same Flutter domain and presentation code to Android
and iOS. No behavior in this document requires an LLM.

## 2. Scope

The first milestone includes:

- manual Task creation, editing, completion, cancellation, reopening, and soft
  deletion;
- optional deadlines and estimated effort;
- Task association with a course or event;
- two Task deadline bands between the all-day band and weekly time grid;
- manual creation of one or more PlanBlocks for a Task;
- PlanBlock movement, resizing, splitting, locking, skipping, completion, and
  cancellation;
- explicit post-PlanBlock review and Task completion confirmation;
- deterministic planning, deadline-risk, and pending-review projections;
- deterministic local and in-App reminders;
- one-step undo for reversible local business actions;
- action-history records for all important changes.

It excludes:

- LLM-generated tasks;
- LLM planning and rescheduling;
- LLM daily briefings;
- natural-language task commands;
- LLM reminder wording or priority decisions.

## 3. Creation Entry Points

The primary App-bar add button opens a choice:

```text
Task | Calendar event
```

Task can also be created from a course or event detail screen. In that case the
new Task starts with the relationship populated, but the user can remove or
change it.

Creating a Task requires only a title. The first form supports:

```text
title
description
deadlineAt (optional)
estimatedMinutes (optional)
priority
relatedCourseEventIds
relatedCalendarEventIds
tags
userNotes
reminderOverride
```

The form does not require a deadline or estimated duration. It validates that
an explicit deadline is a real `Asia/Shanghai` instant and that estimated
minutes are positive.

## 4. Task Lifecycle

Task status uses:

```text
active
blocked
completed
cancelled
```

Behavior is:

- a newly created Task starts as `active`;
- `blocked`, shown as "Waiting for a condition", is an explicit user state and
  may carry an optional reason;
- only explicit user confirmation marks a Task `completed`;
- only explicit user action marks a Task `cancelled`;
- time passage and PlanBlock changes never write a Task status;
- completing a Task sets `completedAt`, cancellation sets `cancelledAt`, and
  the two timestamps are mutually exclusive;
- reopening a completed or cancelled Task returns it to `active`, clears both
  terminal timestamps, and does not restore cancelled PlanBlocks;
- deletion is soft deletion and is eligible for one-step undo;
- terminal Tasks must be reopened before they can become `blocked`.

Task status changes never rewrite source-owned CalendarEvent data.

The query layer derives three independent presentation states:

```text
planningState:     unplanned | planned
deadlineState:     not_applicable | no_deadline | upcoming | due_today | overdue
confirmationState: clear | awaiting_planblock_review
```

For an active or blocked Task, `planningState` is `planned` only when a
non-deleted `accepted` PlanBlock has `endAt > now`. An elapsed `accepted`
PlanBlock instead contributes to `awaiting_planblock_review`. Suggested, done,
skipped, rescheduled, and cancelled blocks do not count as future planning.
Completed and cancelled Tasks always project `planningState=unplanned` and
`confirmationState=clear`, even when retained PlanBlocks remain visible as
history or schedule entries.

Completed and cancelled Tasks use `deadlineState=not_applicable`. Active and
blocked Tasks use `Asia/Shanghai`: a missing deadline is `no_deadline`, a
future date is `upcoming`, the current local date before its deadline is
`due_today`, and `now > deadlineAt` is `overdue`. These projections never write
the database, create an ActionLog entry, or consume the undo slot.

## 5. Weekly Schedule Presentation

Task itself has no fixed execution interval and never masquerades as a timed
CalendarEvent.

The weekly schedule places these layers above the time grid:

```text
all-day event band
undated-task band
dated-deadline band
official-period and real-minute time grid
```

### 5.1 Undated Task Band

- Show every incomplete Task without `deadlineAt`.
- Show matching tasks in every selected week.
- Hide the complete band when it has no matching tasks.
- Keep the Task after PlanBlocks are created.
- Remove completed undated tasks from the active band while preserving them in
  task history.

### 5.2 Dated Deadline Band

- Align Task with the Monday-through-Sunday column containing its deadline.
- Keep Task after planning.
- Keep completed Task in its deadline week with reduced contrast.
- Provide a hide-completed filter.
- Keep incomplete overdue Task visible in the current week until it is
  completed, cancelled, or deleted.

Primary band labels and Task content use high-contrast text.

Status warnings are:

```text
due today -> yellow block, yellow circled exclamation, explicit text
overdue   -> red block, red circled exclamation, overdue duration
completed -> reduced contrast and completion mark
```

Warnings include semantic accessibility labels. Deadline warnings and schedule
conflict warnings may share the circled-exclamation shape, but their text and
semantics distinguish the two meanings.

Selecting a Task opens detail with deadline, persisted status, all three
derived states, priority, optional estimated effort, future PlanBlock count and
duration, notes, reminders, and related PlanBlocks. Future PlanBlock duration
describes schedule occupancy and never claims to measure Task progress.

## 6. Manual Planning

The primary planning path is tap- or click-based:

1. Open Task detail.
2. Choose `Schedule time`.
3. Select date, start time, and duration.
4. Preview the block in the weekly timetable.
5. Save one PlanBlock.
6. Repeat while more time should be planned.

The planner continuously shows:

```text
estimated minutes
future PlanBlock count
future PlanBlock total duration
```

`estimatedMinutes` is an optional initial planning reference. The App does not
derive completion percentage, executed effort, remaining effort, or actual
minutes from PlanBlocks.

Windows supports pointer dragging and resizing as secondary shortcuts. Mobile
supports long-press dragging, but form editing remains available so precise
touch dragging is never required.

Selecting an empty timetable area offers:

```text
Calendar event | Task execution block
```

A Task execution block must reference a Task.

Planning beyond the deadline or into a confirmed conflict shows a warning. The
user may explicitly keep the block. The operation and confirmation are written
to action history.

## 7. PlanBlock Lifecycle

PlanBlock status uses:

```text
suggested
accepted
done
skipped
rescheduled
cancelled
```

The non-LLM first milestone normally creates `accepted` PlanBlocks. The
`suggested` status remains in the model for future Agent proposals and for
imports, but the UI does not fabricate suggestions.

PlanBlock supports:

- edit start, end, and title;
- move and resize;
- split into multiple blocks;
- lock against ordinary movement;
- mark done, skipped, rescheduled, or cancelled;
- soft delete where deletion is exposed;
- navigate to the parent Task.

Visual presentation is:

```text
suggested -> dashed border
accepted  -> solid Task-linked style
done      -> retained with reduced contrast and completion mark
```

An `accepted` PlanBlock whose `endAt <= now` remains persisted as `accepted`
but derives an awaiting-review presentation. The first milestone exposes a
central pending-review list and matching entry points from the weekly schedule
and Task detail. It does not send a system notification merely because a block
ended.

PlanBlock uses actual start and end minutes in the mixed official-period
timeline. It participates in overlap grouping and ScheduleRelation conflict
logic. Task itself does not.

Changing, skipping, cancelling, or deleting a PlanBlock never silently deletes
the parent Task or removes it from a deadline band. A rescheduled block stores
the stable ID of its replacement in `rescheduledToPlanBlockId`.

## 8. Review and Completion

Reviewing an elapsed accepted PlanBlock offers:

```text
done
skipped
rescheduled
review later
```

`done` confirms that the planned session occurred, but records no actual
minutes or completion percentage. The App then asks separately whether the
whole Task is complete. A negative answer leaves the Task unchanged and allows
more planning. `skipped` also leaves the Task unchanged. `rescheduled` marks
the old block and atomically creates a new accepted block. Review can be
deferred without changing either object.

Completing every PlanBlock never completes its parent Task. Only explicit user
confirmation changes Task to `completed`.

Before Task completion, the App summarizes future accepted PlanBlocks. The user
may cancel all or review them individually, including explicitly retaining a
block. A retained block remains linked and is labelled as having a completed
parent. Elapsed unreviewed blocks remain honest historical `accepted` records
but leave the active pending-review queue once the parent Task is terminal.

Cancelling a Task shows an impact summary and atomically cancels every future
accepted PlanBlock. Blocking a Task does not modify PlanBlocks. Reopening a
Task preserves all PlanBlock history but does not restore blocks cancelled by
completion or cancellation.

## 9. One-Step Undo

Undo is global, session-scoped, and stores only the most recent reversible
local mutation.

Supported actions include:

- Task create, edit, status change, cancel, reopen, and soft delete;
- PlanBlock create, edit, move, resize, split, lock, status change, and soft
  delete;
- manual CalendarEvent changes;
- attendance, listening, note, reminder, and conflict-priority changes.

Undo does not cover:

- source sync or file import;
- login, logout, or CAPTCHA;
- credential save, update, or deletion;
- browser-profile clearing;
- complete local-data clearing;
- external website actions.

After a reversible action:

- show a temporary bottom message with an Undo command;
- keep a toolbar undo icon available;
- replace the previous undo record when another reversible action succeeds;
- clear the undo slot on App restart;
- execute undo in one database transaction;
- write both the original action and its undo to `action_logs`.

An undo failure leaves current data unchanged and records a redacted failure.

## 10. Deterministic Reminders

The first milestone persists deterministic reminder schedules and shows
in-App reminders. While the unpackaged Windows development App is running, it
may also emit Windows toast notifications. It does not require remote push or
LLM text generation.

An unpackaged Windows process has no reliable contract for cancelling or
reconciling notifications after it exits. The first milestone therefore does
not promise background delivery while the App is closed. Reliable closed-App
delivery and cancellation require a later packaged Windows build or the
Android/iOS notification adapters.

Default reminder rules are:

```text
ordinary course             15 minutes before start
exam                        24 hours and 2 hours before start
registered second classroom 2 hours before start
personal CalendarEvent      15 minutes before start
all-day CalendarEvent       no default reminder
Task                        24 hours and 2 hours before deadline
PlanBlock                   10 minutes before start
```

Users can:

- override reminders on one object;
- disable a type default;
- disable all system notifications while keeping in-App reminders;
- remove one of multiple default offsets.

Time changes reschedule persisted reminder records. Completion, cancellation,
deletion, or hiding invalidates reminders that no longer apply. The running
Windows adapter reconciles its process-lifetime notifications from those
records.

The first milestone does not schedule a daily notification for due-today or
overdue Tasks. Their deadline bands still show yellow and red warning states.
A future LLM daily briefing owns recurring narrative reminders for those
states.

If the system-notification adapter is unavailable or disabled, the App reports
the disabled channel and continues to show in-App reminder state.

## 11. Persistence

The first database adds:

```text
tasks
plan_blocks
reminders
undo_slot
```

`undo_slot` contains at most one versioned reversible command and its minimal
before-state. It is deleted during normal startup recovery.

Task and PlanBlock records use stable local IDs. Relations reference IDs rather
than embedding duplicate objects. Timestamps preserve `Asia/Shanghai`
semantics according to the application-wide time policy.

Task persistence includes `blockedReason`, `completedAt`, `cancelledAt`, and
`deletedAt`. Leaving `blocked` clears the current `blockedReason`; ActionLog
retains its history. The model has no progress percentage or actual-execution
minutes. PlanBlock persistence includes optional `rescheduledToPlanBlockId` and
`deletedAt`.

## 12. Failure Handling

- Invalid forms do not write partial Task or PlanBlock records.
- Split, move, and resize operations are transactional.
- Reminder scheduling failure does not roll back the business object; it
  records reminder state as failed and presents a retry action.
- Notification permission denial is not treated as data corruption.
- An invalid or stale undo record is discarded with a redacted log entry.
- Deadline and overlap warnings never silently block an explicit user choice.
- Reopening or restoring Task preserves its existing relations.
- Domain commands reject stale status changes and require the caller to refresh
  before confirming against newer data.
- Task completion, Task cancellation, associated PlanBlock changes, ActionLog,
  and undo-state updates are committed atomically.
- UI and future Agent callers use the same lifecycle service and cannot write
  status fields directly.

## 13. Verification

Domain and database tests cover:

- Task lifecycle transitions;
- rejection of illegal and stale lifecycle transitions;
- Task persistence with and without deadlines;
- both deadline-band queries;
- planned Task retention in its deadline band;
- `Asia/Shanghai` due-today, exact-deadline, overdue, blocked, and terminal
  deadline states;
- planning and pending-review projections for every PlanBlock status;
- proof that advancing the clock changes only projections and performs no
  database write;
- no automatic Task completion;
- two-stage PlanBlock and Task completion confirmation;
- future and elapsed PlanBlock handling during Task completion;
- future PlanBlock cancellation during Task cancellation;
- reopening without automatic PlanBlock restoration;
- absence of progress percentages, actual minutes, and remaining-effort
  calculations;
- split, move, resize, lock, and status transitions;
- overlap and conflict participation;
- one-step undo replacement, transactionality, and startup expiry;
- excluded undo actions;
- reminder default expansion, override, rescheduling, and cancellation;
- absence of daily due-today and overdue notification schedules.

Widget tests cover:

- Task and CalendarEvent add-choice flow;
- Task form and course-linked creation;
- both deadline bands and empty undated-band collapse;
- Task detail and manual planning;
- central pending-PlanBlock review list;
- pointer and form-based PlanBlock edits;
- two-stage completion prompt and future-block handling;
- warning icon semantics and high-contrast labels;
- one-step Undo message and toolbar state.

Platform tests cover Windows notification delivery and cancellation while the
App process is running, plus explicit proof that no closed-App delivery is
claimed. Android, iOS, and a later packaged Windows adapter follow the same
persisted reminder contract.
