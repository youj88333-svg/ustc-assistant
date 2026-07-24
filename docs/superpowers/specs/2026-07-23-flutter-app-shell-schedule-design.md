# Flutter App Shell and Schedule Design

## 1. Purpose

This document records the confirmed design for the first Flutter application
shell and its unified weekly schedule. The initial build runs on Windows as a
product test bed, while keeping the reusable application core suitable for a
later Android and iOS migration.

The school login, credential vault, Windows bridge lifecycle, one-click sync,
and operation-history behavior require a separate design before
implementation. This document fixes their navigation placement but does not
invent their internal behavior.

## 2. Product Direction

- The final product is a locally running Android and iOS application.
- Flutter is the shared UI and application platform.
- Windows is the first validation platform, not a disposable prototype.
- The existing Python collectors remain the Windows data-source adapters.
- Flutter owns the local database, import rules, user overlays, schedule
  behavior, and presentation.
- Mobile collection later replaces the Windows adapter without changing the
  Flutter application core.

The intended boundary is:

```text
Python source services
        |
Windows structured bridge
        |
versioned SourceBundle
        |
Flutter ImportService
        |
SQLite + application UI
```

Flutter exposes a source gateway abstraction. The first implementations are a
file gateway for importing generated JSON and a Windows bridge gateway for
one-click collection. Both feed the same `ImportService`. A future mobile
gateway can use a WebView session and mobile HTTP implementation.

The bridge calls Python source services and returns structured data. The App
must not parse CLI status text.

## 3. First Milestone

The first Windows milestone includes:

- import of JW courses and exams;
- import of registered second-classroom schedules;
- local SQLite persistence and transactional upsert;
- historical-record preservation;
- a unified seven-day weekly schedule;
- single-event and course-series user overlays;
- attendance values `must_go`, `gamble`, and `skip`;
- listening values `listen` and `not_listen`;
- free-form user notes;
- manual `Task` creation and lifecycle management;
- manual `PlanBlock` creation, splitting, movement, locking, and completion;
- two deadline bands and task progress presentation;
- deterministic local reminders and system notifications;
- one-step session undo for reversible local changes;
- sync results and redacted failures.

The first milestone explicitly excludes LLM behavior:

- a real LLM Agent;
- a daily briefing;
- free-form chat commands;
- LLM-generated planning, explanation, ranking, and reminders.

The chat page is an application shell in this milestone. It must not pretend
that an Agent or daily briefing is available before the real LLM integration
exists.

Second-classroom registration and cancellation remain user actions on the
official school page. This is a permanent safety boundary rather than an
LLM-related feature deferral.

The active-enrolment list, iCourse content, and campus public information keep
their existing source services, caches, tests, and safety contracts. They do
not receive standalone Flutter screens. A later LLM can call them through
bounded tools and present results in Chat. Until then they remain backend
capabilities and development references rather than user-facing App flows.

## 4. Local Data and Import Semantics

The Flutter App uses Drift to manage SQLite. The initial application model
contains:

```text
source_records
calendar_events
schedule_relations
course_series
user_overlays
tasks
plan_blocks
reminders
sync_runs
action_logs
```

Each imported bundle declares a schema version, source, collection time,
snapshot mode, and collection scope. Import follows these rules:

1. Upsert external records by `source + externalId`.
2. Import one bundle in one SQLite transaction.
3. Roll back the complete bundle if validation or persistence fails.
4. Make repeated import of the same bundle idempotent.
5. Update changed source fields without modifying `user_overlays`.
6. Mark records that leave a rolling query window as `outside_scope`; do not
   delete them.
7. Mark an event `cancelled` only when the source explicitly reports
   cancellation.
8. Never infer deletion from a failed or incomplete source snapshot.
9. Store instants in UTC while preserving the `Asia/Shanghai` time-zone
   meaning.
10. Evolve the database only through versioned migrations.

The effective event view applies overlays in this order:

```text
single-event overlay
    > course-series overlay
    > source default
```

A source refresh may update a classroom or source time, but it must preserve
the user's attendance choice, listening choice, display preference, and notes.

## 5. Application Navigation

The default first screen is Chat. The persistent bottom navigation has exactly
two primary destinations:

```text
Chat | Schedule
```

The Schedule destination opens the weekly timetable.

A drawer opens from the side and contains:

- school websites and login;
- data sync;
- operation history;
- settings.

The bottom navigation and drawer are project-specific. They do not copy the
navigation shown in the user's timetable reference image.

## 6. Seven-Day Weekly Timetable

The weekly timetable always includes Monday through Sunday. Weekend columns
have the same capabilities as weekday columns because second-classroom
activities, exams, and personal events frequently occur on weekends.

- Windows displays all seven days together when space permits.
- A narrow Android or iOS viewport uses horizontal scrolling or an equivalent
  responsive treatment.
- The App must never hide Saturday or Sunday to make the grid fit.
- Returning from a detail view preserves the selected week and scroll
  position.

### 6.1 Time Axis

USTC class periods and their official start and end times form the primary
horizontal grid. Event geometry still uses actual start and end minutes.

This hybrid model provides:

- exact alignment for ordinary courses;
- familiar period numbers on the left;
- correct positioning for second-classroom activities and personal events
  that begin or end between class boundaries;
- support for events that cross one or more period boundaries.

The visual grid must not round a non-course event to the nearest class period.

### 6.2 Event Identity and Color

All occurrences of one course series use one stable color. Different course
series use distinguishable colors. Color identity is derived from a stable
series key and persisted or reproducibly generated so it does not change when
the user switches weeks or restarts the App.

User color overrides can be added without modifying source records.

Color is not the only identity signal. Event blocks also expose readable text
and accessible semantic labels.

### 6.3 Event Content

Inside a timetable block, information priority is:

```text
course or event title
location
essential state marker
other metadata when space remains
```

Time is primarily communicated by vertical position, but exact time remains
available in the event detail view.

### 6.4 Inactive-Week Preview

If a course pattern exists but does not meet in the selected week, its expected
slot can appear as a low-opacity, dashed preview. This covers odd/even-week
rules and course segments that occur only in specific weeks.

The preview must:

- state that it is not active in the selected week;
- remain visually subordinate to active events;
- identify the relevant week rule when known;
- remain clickable for course-series details;
- never be included as an active event in reminders or conflict calculations.

### 6.5 Task Deadline Bands and PlanBlocks

`Task` does not enter the time grid because it has no required start and end
time. The weekly schedule places two deadline bands above the official-period
grid:

```text
undated-task band
dated-deadline band
official-period and real-minute time grid
```

The undated-task band:

- shows every incomplete `Task` whose `deadlineAt` is absent;
- spans the complete week instead of assigning a false day;
- appears in every selected week while matching tasks exist;
- hides the complete band when no matching task exists;
- keeps a task after planning creates one or more `PlanBlock` records;
- removes a completed undated task from the active band while preserving it in
  task history.

The dated-deadline band:

- aligns tasks whose `deadlineAt` falls in the selected week with Monday
  through Sunday;
- keeps the `Task` after planning;
- retains completed tasks in their deadline week with reduced contrast;
- supports a hide-completed filter;
- keeps incomplete overdue tasks visible in the current week until completion,
  cancellation, or deletion.

Band titles, task titles, and status text use high-contrast foreground colors
on their backgrounds. Low-opacity text is not acceptable for primary labels.

Deadline warning presentation is:

```text
due today -> yellow task block + yellow circled exclamation + text status
overdue   -> red task block + red circled exclamation + overdue duration
completed -> reduced contrast + completion mark
```

Warnings have semantic accessibility labels and never rely only on color. A
deadline warning and a confirmed-conflict warning may share the circled
exclamation shape, but their detail text and accessibility labels distinguish
deadline risk from schedule conflict.

Planning creates `PlanBlock` records without replacing the parent `Task`.
PlanBlocks enter the time grid at their real `startAt` and `endAt`, participate
in overlap and conflict relationships, and remain linked to the deadline-band
task.

PlanBlock presentation is:

```text
suggested -> dashed border
accepted  -> solid task-linked style
active    -> solid task-linked style
done      -> retained with reduced contrast and completion mark
```

Selecting a task opens task detail with deadline, status, estimated effort,
planned effort, remaining effort, and related PlanBlocks. Selecting a
PlanBlock opens execution-block detail and provides a path to the parent task.
Changing or deleting a PlanBlock does not silently delete its parent Task.

## 7. Overlap and Conflict Presentation

Time overlap and confirmed conflict are different concepts. Overlapping events
share time geometry. A warning appears only when the corresponding
`ScheduleRelation` has `conflictState=conflict`.

### 7.1 Collapsed Weekly View

On a phone, overlapping events are not compressed into unreadable side-by-side
columns.

Instead:

- the highest-priority event is the foreground event;
- the foreground event is slightly translucent;
- other events appear behind it with offsets, lower opacity, and light blur;
- the layers preserve enough color and outline to reveal that multiple events
  exist;
- the foreground block states the number of additional overlapping events.

A confirmed conflict displays a warning in the event block's upper-right
corner: a red exclamation mark inside a red circle. The warning also has a
semantic accessibility label and cannot rely on color alone.

### 7.2 Two-Step Selection

Selecting a non-overlapping event opens its detail directly.

Selecting an overlapping area uses two steps:

1. The first selection expands the overlap group outside the narrow timetable
   cell and lays out every event separately at readable width.
2. The second selection chooses one event and opens its full detail.

The expanded group shows title, exact time, location, conflict warning, and
which event is currently preferred.

### 7.3 Event Detail

Event detail shows:

- title, exact time, location, and source;
- attendance and listening settings;
- user notes;
- related overlapping events;
- confirmed conflict state and current resolution;
- a later control for choosing the preferred foreground event.

The preliminary foreground priority is:

```text
explicit user preference
    > exam or critical event
    > must-go event
    > user importance
    > stable source default
```

Equal-priority events use a deterministic order so the foreground event does
not change between renders.

## 8. Validation Requirements

Implementation must include:

- unit tests for minute-to-grid geometry and official period boundaries;
- unit tests for stable course colors;
- tests for odd/even-week inactive previews;
- tests that repeated imports preserve overlays and do not duplicate events;
- tests for overlap grouping and deterministic foreground selection;
- tests that overlap alone does not create a conflict warning;
- widget tests for the two-step overlap interaction and event detail;
- responsive screenshot checks for Windows and representative phone widths;
- explicit checks that all seven days remain reachable;
- accessibility semantics for conflict warnings and event selection;
- tests for both deadline bands and planned-task retention;
- tests for due-today, overdue, and completed-task presentation;
- tests for Task and PlanBlock lifecycle transitions;
- tests for one-step undo replacement and expiry;
- tests for reminder rescheduling and cancellation.

The implementation plan must keep source collection tests separate from
Flutter database and widget tests.

## 9. Companion Designs

Authentication, credentials, bridge lifecycle, sync, operation history, and
settings are defined in `2026-07-24-flutter-auth-sync-design.md`.

Task lifecycle, manual planning, one-step undo, and deterministic local
reminders are defined in `2026-07-24-flutter-task-planning-design.md`.

Real LLM integration, cloud privacy consent, daily briefings, chat tools, and
Agent permission policy belong to a later Agent design.
