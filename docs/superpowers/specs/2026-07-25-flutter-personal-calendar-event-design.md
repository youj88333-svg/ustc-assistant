# Flutter Personal CalendarEvent Design

## 1. Purpose

This document defines personal `CalendarEvent` behavior for the first Windows
Flutter milestone. It covers one-off, all-day, multi-day, and basic recurring
events; completion semantics; schedule presentation; overlap handling;
reminders; undo; and the bounded interfaces reserved for later LLM use.

It extends the application-shell, weekly-schedule, Task, and reminder designs.
No behavior in this document requires an LLM. LLM-driven creation and
completion conversations remain disabled until the later Agent milestone.

## 2. Scope

The first milestone includes:

- one-off timed personal events;
- one-off all-day and multi-day all-day events;
- daily, weekly, and monthly recurrence;
- recurrence intervals, multiple weekdays, and an optional inclusive end date;
- one-occurrence, this-and-future, and whole-series editing;
- per-occurrence exceptions and soft deletion;
- deterministic color, completion, reminder, overlap, and conflict behavior;
- direct creation from the App bar, timetable, all-day band, Task detail, and
  event detail;
- one-step undo and action-history records.

The first milestone excludes:

- LLM-created events;
- natural-language editing;
- LLM completion prompts;
- arbitrary recurrence expressions such as the last Friday of each month;
- bidirectional operating-system calendar sync;
- automatic conflict classification.

After LLM integration, complex recurrence can be represented by multiple
bounded tool calls that create one-off events or multiple simple series.

## 3. Domain Objects

Personal events use three persistence concepts:

```text
CalendarEvent
  source-owned concrete events and user-created one-off events

CalendarEventSeries
  a personal-event template and a basic recurrence rule

CalendarEventOccurrenceException
  one occurrence's field, status, or deletion override
```

`EffectiveCalendarEvent` is a query result composed from a series and an
optional exception. It is not an unbounded database table.

### 3.1 Personal Event Types

The user-selectable types are:

```text
personal
entertainment
meal
campus_affair
travel
study
```

The default is `personal`. `course`, `exam`, and `second_class` are
source-owned and cannot be created through the personal-event form.

`assignment_block` is removed from `CalendarEvent`; Task execution time belongs
only to `PlanBlock`. User-defined classification uses tags rather than
unbounded event-type strings.

### 3.2 Stored and Effective Status

Personal event status uses:

```text
active
tentative
completed
skipped
cancelled
hidden
```

Soft deletion uses `deletedAt` and is not a status value.

`cancelled` means an event was planned and cancelled before it occurred.
`skipped` means its time passed and the user confirmed it did not occur.
`hidden` removes it from the normal view without deleting it.

## 4. Time Representation

A timed event stores:

```text
startAt
endAt
timezone = Asia/Shanghai
```

`endAt` may be on a later date, so timed events can cross midnight.

An all-day event stores:

```text
startDate
endDateExclusive
timezone = Asia/Shanghai
```

It does not use fabricated midnight instants as its primary meaning. A
one-day event on July 25 uses `[2026-07-25, 2026-07-26)`. A three-day event
from July 25 through July 27 uses `[2026-07-25, 2026-07-28)`.

A record uses exactly one of the timed and all-day field sets.

## 5. Completion Policy

Personal events add:

```text
completionPolicy
  auto_after_end
  manual_confirmation
```

`auto_after_end` is the default. Its effective status becomes `completed` when
the current time passes `endAt`, or when the Beijing date reaches
`endDateExclusive` for an all-day event.

Automatic completion is derived rather than written for every elapsed
occurrence. This avoids unbounded writes for recurring series. A user's
explicit correction creates a stored event update or occurrence exception.

For `manual_confirmation`, an elapsed `active` event derives
`awaitingCompletion=true`. The first milestone stores and queries this state
but sends no completion notification and opens no automatic prompt.

After LLM integration, Chat may query ended events awaiting confirmation and
ask:

```text
completed
skipped
reschedule
```

The LLM must use bounded tools to record the answer. The user can always
perform the same actions from event detail.

Source-owned courses, exams, and registered second-classroom events do not
inherit the personal-event automatic-completion default.

## 6. Recurrence

### 6.1 Basic Rule

The first recurrence rule contains:

```text
frequency: daily | weekly | monthly
interval: positive integer, default 1
weekdays: non-empty set for weekly recurrence
untilDate: optional inclusive Beijing date
timezone: Asia/Shanghai
anchorLocalDate
```

An absent `untilDate` means the series continues indefinitely.

Monthly recurrence retains the original day-of-month anchor. If the anchor is
not present in a month, that occurrence uses the month's final day. A
31st-of-the-month series therefore produces February 28 or 29 and then returns
to March 31.

### 6.2 Occurrence Identity

Schedule queries expand only the requested range. Each occurrence has a
deterministic identity derived from:

```text
seriesId + original scheduled local date/time
```

Moving one occurrence does not change its occurrence identity because the key
uses the original recurrence position.

Reminder and relationship records may target this stable occurrence key.

### 6.3 Occurrence Exceptions

An exception can override:

- timed or all-day range;
- title, description, location, type, importance, color, tags, and notes;
- completion policy;
- reminder rules;
- status;
- soft deletion.

The exception records which fields are explicitly overridden so an intentional
null value can be distinguished from an inherited value.

### 6.4 Edit Scope

`only_this` writes an exception.

`this_and_future` ends the old series before the selected occurrence and
creates a new series beginning at that occurrence. Compatible future
exceptions, reminders, and relationships are migrated transactionally.

`whole_series` changes the series template or recurrence rule. Existing
exceptions retain priority. If a recurrence-rule change removes the occurrence
that an exception referenced, the exception becomes `orphaned`; it remains in
history and the edit summary but does not enter the active schedule.

Before saving a series edit, the App shows retained exceptions, newly orphaned
exceptions, and the number of generated occurrences affected in the next 366
days. A series without `untilDate` is explicitly labelled as continuing beyond
that impact horizon. The complete edit is one transaction and one reversible
action.

## 7. Creation and Editing

The App-bar add command offers:

```text
Task | Calendar event
```

Creation entry points are:

- the App-bar command, which opens an empty form;
- selecting an empty timed-grid area, which pre-fills a one-hour event;
- pointer-dragging an empty range on Windows;
- optional long-press dragging on mobile, with form editing always available;
- selecting an empty all-day-band area, which pre-fills that date;
- Task or event detail, which pre-fills a relationship that can be removed
  before saving.

The form requires a non-empty title and one valid time representation. It
supports description, location, personal event type, importance,
active/tentative state, completion policy, color, tags, reminders, recurrence,
and Task/event relationships.

Recurring-event creation previews the first five occurrences. Editing an
occurrence asks for `only_this`, `this_and_future`, or `whole_series` before
applying the change.

## 8. Weekly Schedule Presentation

The weekly schedule layers are:

```text
date headers
all-day event band
undated Task band
dated Task deadline band
official-period and real-minute time grid
```

The all-day band hides when the selected week has no all-day events. A one-day
event occupies one day column; a multi-day event spans the corresponding date
columns. All-day events do not occupy hour geometry and do not overlap every
timed event merely because they share a date.

The collapsed band shows at most three rows. Additional events use a `+N`
indicator on the affected date; selecting it expands the complete all-day
group without changing the timetable's horizontal day geometry.

Selecting a non-overlapping personal event opens detail. Selecting an
overlapping timed area preserves the established two-step interaction: expand
the overlap group, then select an event.

Event detail supports edit, complete, skip, reschedule, cancel, hide, soft
delete, restore, reminders, and relationship management.

Schedule filters can reveal hidden and soft-deleted personal events in a
management list. This is separate from read-only operation history and gives
the user a durable restore path after the one-step undo slot expires.

## 9. Color and Visual State

All occurrences of a series share a stable base color. A one-off event also
receives a deterministic color that survives restart.

The personal event type selects an initial color family, while a stable event
identity differentiates nearby events. A user override wins over generated
color. An occurrence may override the series color by using `only_this`;
future or whole-series changes use the corresponding edit scope.

Color does not encode conflict or completion. Completed, skipped, cancelled,
hidden, tentative, and conflict states use opacity, border, icons, text, and
accessibility semantics.

## 10. Overlap and Conflict

Saving an overlapping personal event is always allowed. The form presents a
non-blocking overlap summary.

Time geometry creates an overlap group but does not automatically create a
`ScheduleRelation`. A relationship is stored only after the user explicitly
classifies the pair as `conflict` or `non_conflict`.

Only a confirmed conflict displays the red circled-exclamation warning. A
non-conflict relation may record embedded work, replacement, an alternative
choice, or another user explanation.

A classification may target one occurrence or compatible future occurrences.
The first milestone does not let deterministic code classify overlap on the
user's behalf. A later LLM may suggest a classification but must not save it
without the applicable permission and confirmation flow.

## 11. Reminders

Defaults are:

```text
timed personal event  15 minutes before start
all-day event         no reminder
completion check      no system notification
```

Users may override a timed event or explicitly add reminders to an all-day
event. A series stores default reminder rules and an occurrence may override
them.

Moving an occurrence reschedules its future reminders. Completing, skipping,
cancelling, hiding, or deleting an occurrence cancels reminders that no longer
apply.

Future LLM daily briefings may mention all-day and awaiting-completion events.
That behavior is not present in the first milestone.

## 12. Persistence and Transactions

The Drift schema adds:

```text
calendar_event_series
calendar_event_occurrence_exceptions
```

One-off and source-owned events remain in `calendar_events`.

Creation, series splitting, series-rule editing, exception migration,
relationship updates, and reminder updates are transactional. Invalid input
does not write partial records.

All reversible personal-event mutations use the global one-step session undo
slot. The original action and its undo are written to `action_logs`.

## 13. Validation and Failure Handling

- A trimmed title must not be empty.
- Timed events require `endAt > startAt`.
- All-day events require `endDateExclusive > startDate`.
- Timed and all-day field sets are mutually exclusive.
- Recurrence interval must be positive.
- Weekly recurrence requires at least one weekday.
- `untilDate` cannot precede the first occurrence.
- One recurrence-expansion request covers at most 366 calendar days and 1,000
  effective occurrences; longer views query consecutive bounded ranges.
- A future LLM mutation request may create at most 20 one-off events or five
  simple series. Larger changes require multiple separately logged calls and
  the applicable confirmation policy.
- An invalid or orphaned exception never causes the base series to disappear.
- Reminder scheduling failure does not roll back a valid event; it records a
  retryable reminder failure.
- Source-owned fields are never modified through personal-event editing;
  source changes still use `UserOverlay`.

## 14. Verification

Domain and database tests cover:

- one-off timed, all-day, and multi-day events;
- mutually exclusive time representations;
- daily, multi-weekday weekly, and monthly recurrence;
- interval and inclusive-end behavior;
- month-end clamping while preserving the original anchor;
- deterministic occurrence identity after movement;
- all three edit scopes;
- exception inheritance and intentional null override;
- compatible exception migration and orphan preservation;
- effective automatic completion and manual awaiting-confirmation state;
- completed, skipped, cancelled, hidden, and soft-deleted behavior;
- deterministic series and one-off colors;
- reminder inheritance, override, rescheduling, and cancellation;
- overlap without a relationship;
- explicit conflict and non-conflict relationships;
- transactional series edits and one-step undo.

Widget tests cover:

- App-bar, timed-grid, all-day-band, Task-detail, and event-detail creation;
- the one-hour timed default;
- recurring-event preview;
- edit-scope selection and affected-count summary;
- all-day band hiding, multi-day span, three-row cap, and expansion;
- event detail actions;
- hidden/deleted management and durable restore;
- overlap expansion and confirmed-conflict warning semantics;
- no automatic completion notification;
- no default all-day reminder.

Responsive screenshot checks cover Windows and representative phone widths,
with all seven days remaining reachable.
