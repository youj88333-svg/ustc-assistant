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
- deterministic effort accounting;
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
todo
planned
in_progress
blocked
completed
cancelled
```

Behavior is:

- a newly created Task starts as `todo`;
- a Task with at least one accepted or active future PlanBlock can be
  `planned`;
- starting or completing execution work can move it to `in_progress`;
- the user can explicitly mark it `blocked`;
- only explicit user confirmation marks it `completed`;
- cancellation preserves history and relations;
- deletion is soft deletion and is eligible for one-step undo;
- a completed or cancelled Task can be reopened.

Task status changes never rewrite source-owned CalendarEvent data.

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

Selecting a Task opens detail with deadline, status, priority, estimated
effort, planned effort, executed effort, remaining effort, notes, reminders,
and related PlanBlocks.

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
planned minutes
unplanned minutes
executed minutes
remaining execution minutes
```

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
active
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
- mark active, done, skipped, rescheduled, or cancelled;
- soft delete where deletion is exposed;
- navigate to the parent Task.

Visual presentation is:

```text
suggested -> dashed border
accepted  -> solid Task-linked style
active    -> solid Task-linked style
done      -> retained with reduced contrast and completion mark
```

PlanBlock uses actual start and end minutes in the mixed official-period
timeline. It participates in overlap grouping and ScheduleRelation conflict
logic. Task itself does not.

Changing, skipping, cancelling, or deleting a PlanBlock never silently deletes
the parent Task or removes it from a deadline band.

## 8. Completion and Effort Accounting

The App tracks these values independently:

```text
estimatedMinutes
plannedMinutes
unplannedMinutes
executedMinutes
remainingExecutionMinutes
```

`plannedMinutes` derives from PlanBlocks in `accepted`, `active`, or `done`
state. `unplannedMinutes` is
`max(estimatedMinutes - plannedMinutes, 0)`.

`executedMinutes` derives from `done` PlanBlocks and any explicit user
adjustment supported later. `remainingExecutionMinutes` is
`max(estimatedMinutes - executedMinutes, 0)`.

Completing a PlanBlock does not complete its parent Task. Completing every
PlanBlock also does not automatically complete the Task.

When executed minutes reach or exceed estimated minutes, the App asks whether
the Task is complete. Only user confirmation changes Task to `completed`.

The user can complete Task early. If future incomplete PlanBlocks remain, the
App asks whether to keep, cancel, or review them individually. It does not
silently delete them.

Reopening Task preserves its historical PlanBlocks and execution records.

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

The first milestone uses local operating-system notifications and in-App
reminders. It does not require remote push or LLM text generation.

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

Time changes reschedule future notifications. Completion, cancellation,
deletion, or hiding cancels notifications that no longer apply.

The first milestone does not schedule a daily notification for due-today or
overdue Tasks. Their deadline bands still show yellow and red warning states.
A future LLM daily briefing owns recurring narrative reminders for those
states.

If system notification permission is denied, the App reports the disabled
channel and continues to show in-App reminder state.

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

## 12. Failure Handling

- Invalid forms do not write partial Task or PlanBlock records.
- Split, move, and resize operations are transactional.
- Reminder scheduling failure does not roll back the business object; it
  records reminder state as failed and presents a retry action.
- Notification permission denial is not treated as data corruption.
- An invalid or stale undo record is discarded with a redacted log entry.
- Deadline and overlap warnings never silently block an explicit user choice.
- Reopening or restoring Task preserves its existing relations.

## 13. Verification

Domain and database tests cover:

- Task lifecycle transitions;
- Task persistence with and without deadlines;
- both deadline-band queries;
- planned Task retention in its deadline band;
- due-today, overdue, and completed states;
- PlanBlock effort accounting;
- no automatic Task completion;
- future PlanBlock handling during Task completion;
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
- pointer and form-based PlanBlock edits;
- completion prompt and future-block handling;
- warning icon semantics and high-contrast labels;
- one-step Undo message and toolbar state.

Platform tests cover Windows system-notification scheduling. Android and iOS
notification adapters follow the same application contract during migration.
