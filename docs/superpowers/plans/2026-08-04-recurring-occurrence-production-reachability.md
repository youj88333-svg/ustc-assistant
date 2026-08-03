# Recurring Occurrence Production Reachability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make personal recurring-event occurrences reachable through the real Flutter schedule and Agent paths, with stable run-local references and persistent targets for reminders, relationships, and Task links, without materializing every occurrence into `calendar_events`.

**Architecture:** `CalendarEventSeries` and `CalendarEventOccurrenceException` remain the source of truth. Queries expand only a bounded Beijing-time range into effective occurrences; an occurrence receives a reversible internal locator for UI and Agent use, while a no-op occurrence exception is created only when a dependent database row needs a foreign-key anchor. Schema 7 extends dependent tables to reference that sparse exception anchor and stores series reminder defaults, after which the existing Task 6 can implement `only_this`, `this_and_future`, and `whole_series` lifecycle actions against real production targets.

**Tech Stack:** Flutter/Dart, Drift/SQLite schema 7, `crypto` 3.0.7, existing recurrence domain services, GoRouter, existing Anthropic-compatible Agent tool framework.

## Global Constraints

- Work only on `feature/delete-tools` in `E:/107/.worktrees/delete-tools-plan`; do not edit or stage the root worktree's generated Windows plugin files or `_merge-pending-docs/`.
- This plan is a prerequisite for Task 6 in `2026-08-03-agent-complete-delete-tools.md`; do not implement Task 6 lifecycle mutations until this plan's final hard gate passes.
- `CalendarEventSeries` plus `CalendarEventOccurrenceException` remain canonical. Never bulk-copy all series occurrences into `calendar_events`.
- All expansion is account-scoped, uses `Asia/Shanghai`, accepts at most 366 inclusive calendar days, and returns at most 1,000 occurrences per expansion call.
- The model sees only opaque `ref_*` values. It must never receive a database ID, series ID, occurrence key, encoded locator, account ID, or full local schedule snapshot.
- A read-only schedule or management query must not create an exception anchor or any other database row.
- Schema 7 migration must preserve every Schema 6 row and must be verified against a real Schema 6 fixture before any Agent integration work begins.
- Recurring `create_event` retains the existing permission action `create_event`; this plan does not add a new permission-policy key.
- `get_schedule(view=course_summary)` and imported JW/Young events retain their existing behavior. No branch may depend on the configured semester, product key, year, or `semesterId`.
- `UserOverlay` is not an occurrence target. A personal recurring occurrence is changed through its exception; imported/source-owned events continue to use overlays.
- Automatic tests must never access school websites or the school LLM endpoint.
- Use TDD for every task: add a focused failing test, verify the expected failure, implement the minimum behavior, rerun the focused suite, then commit only that task's files.

## Execution Context

- Planning baseline: branch `feature/delete-tools`, HEAD `c84434a` (`fix(schedule): deterministic already-deleted on event lifecycle actions`).
- Original delete-tools Tasks 1 through 5 are already committed on this branch. Task 6 is intentionally blocked before implementation; do not discard or rewrite those commits.
- The worktree already contains unrelated generated Windows plugin line-ending changes in `app/windows/flutter/generated_plugin_registrant.cc`, `generated_plugin_registrant.h`, and `generated_plugins.cmake`. Treat them as owner changes and never stage, restore, reformat, or commit them.
- The implementation worker should report completion after every task and stop immediately if the Schema 6 fixture cannot migrate losslessly, a read query writes an anchor, or the production integration test requires a fake gateway.

---

### Task 1: Define Reversible Event Locators

**Files:**
- Create: `app/lib/features/calendar/domain/calendar_event_locator.dart`
- Create: `app/test/features/calendar/calendar_event_locator_test.dart`
- Modify: `app/lib/features/agent/application/run_reference_store.dart`
- Create: `app/test/features/agent/run_reference_store_test.dart`

**Interfaces:**
- Produces: `CalendarEventLocator`, `StoredEventLocator`, `RecurringOccurrenceLocator`, `RecurringSeriesLocator`.
- Produces: `String encodeCalendarEventLocator(CalendarEventLocator locator)` and `CalendarEventLocator decodeCalendarEventLocator(String value)`.
- Preserves: `RunReferenceStore.bind(kind: 'event', localId: encodedLocator)` and `resolve(... kind: 'event')`; the generic reference store remains string-based.

- [ ] **Step 1: Write failing locator round-trip and rejection tests**

Cover all three locator variants, Unicode titles being irrelevant to identity, `@`, `:`, and `/` inside source IDs, malformed Base64URL, unknown locator versions, and empty IDs. Assert that encoded occurrence locators contain neither the literal series ID nor literal occurrence key.

```dart
final locator = RecurringOccurrenceLocator(
  seriesId: 'series/with:separator',
  occurrenceKey: 'series/with:separator@2026-09-01T09:45:00',
);
final encoded = encodeCalendarEventLocator(locator);
expect(encoded, startsWith('occ_v1.'));
expect(encoded, isNot(contains(locator.seriesId)));
expect(decodeCalendarEventLocator(encoded), locator);
```

- [ ] **Step 2: Run the new test and verify failure**

Run:

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/calendar/calendar_event_locator_test.dart
Pop-Location
```

Expected: FAIL because `calendar_event_locator.dart` does not exist.

- [ ] **Step 3: Implement the sealed locator model and versioned codec**

Use UTF-8 plus unpadded Base64URL components. Keep the format explicit and reversible:

```text
event_v1.<base64url(eventId)>
occ_v1.<base64url(seriesId)>.<base64url(occurrenceKey)>
series_v1.<base64url(seriesId)>
```

The decoder must require the exact component count and reject empty decoded values with `FormatException('invalid_event_locator')`.

- [ ] **Step 4: Prove opaque run references still hide locators**

Add a `RunReferenceStore` test binding an encoded occurrence locator under kind `event`. Assert idempotent binding, kind isolation, cross-run expiry, and that the resulting `ref_*` contains none of the encoded locator or its source identifiers. Do not change the public `RunReferenceStore` API.

- [ ] **Step 5: Run focused tests and commit**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/calendar/calendar_event_locator_test.dart test/features/agent/run_reference_store_test.dart
Pop-Location
git diff --check
git add app/lib/features/calendar/domain/calendar_event_locator.dart app/lib/features/agent/application/run_reference_store.dart app/test/features/calendar/calendar_event_locator_test.dart app/test/features/agent/run_reference_store_test.dart
git commit -m "feat(calendar): define recurring occurrence locators"
```

### Task 2: Migrate Dependent Targets to Schema 7

**Files:**
- Modify: `app/lib/core/database/tables/schedule_tables.dart`
- Modify: `app/lib/core/database/tables/task_tables.dart`
- Modify: `app/lib/core/database/app_database.dart`
- Regenerate: `app/lib/core/database/app_database.g.dart`
- Modify: `app/test/core/database/migration_test.dart`
- Modify: `app/test/core/database/schedule_task_schema_test.dart`

**Interfaces:**
- Produces: `CalendarEventSeries.reminderOffsetsJson`.
- Produces: nullable `occurrenceExceptionId` references on reminders and Task links, plus nullable left/right occurrence-exception references on schedule relations.
- Preserves: logical relation participant kind `event`; stored events and recurring occurrences differ only in which backing FK is populated.

- [ ] **Step 1: Add failing current-schema constraint tests**

Write tests that describe the Schema 7 target rules:

```text
TaskEventLink: target_id is required; exactly one of event_id and occurrence_exception_id is non-null.
Reminder target_type=event: target_id equals either event_id or occurrence_exception_id, exclusively.
ScheduleRelation event endpoint: exactly one of event_id and occurrence_exception_id is non-null; plan_block remains exclusive.
Imported exam_for_course rows: every occurrence-exception FK remains null.
```

Also test that timed series store `[15]` and all-day series store `[]` when application code supplies the product defaults.

- [ ] **Step 2: Run schema tests and verify failure**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/core/database/schedule_task_schema_test.dart
Pop-Location
```

Expected: FAIL because the Schema 7 columns and constraints do not exist.

- [ ] **Step 3: Change the Drift table declarations**

Apply these logical shapes:

```text
calendar_event_series.reminder_offsets_json TEXT NOT NULL DEFAULT '[]'

task_event_links:
  target_id TEXT NOT NULL
  event_id TEXT NULL FK calendar_events
  occurrence_exception_id TEXT NULL FK calendar_event_occurrence_exceptions
  PRIMARY KEY(account_id, task_id, target_id)

schedule_relations:
  left_occurrence_exception_id TEXT NULL FK calendar_event_occurrence_exceptions
  right_occurrence_exception_id TEXT NULL FK calendar_event_occurrence_exceptions

reminders:
  occurrence_exception_id TEXT NULL FK calendar_event_occurrence_exceptions
```

For relation participants keep `left_kind/right_kind IN ('event','plan_block')`. When kind is `event`, allow exactly one backing FK and require `left_id/right_id` to equal the selected target's logical ID. For a recurring occurrence the logical ID is its encoded `occ_v1...` locator, while the occurrence-exception FK may be a UUID and therefore must not be compared to `left_id/right_id`.

- [ ] **Step 4: Implement the Schema 6 to 7 migration**

Set `schemaVersion => 7`. Use Drift table migrations/rebuilds so changed CHECK constraints are actually installed. Transform existing rows as follows:

```text
calendar_event_series.reminder_offsets_json = CASE all_day WHEN 1 THEN '[]' ELSE '[15]' END
task_event_links.target_id = old event_id
all new occurrence-exception columns = NULL
```

Do not disable foreign keys outside the migration operation. Regenerate Drift output with the repository toolchain; never hand-edit generated SQL mappings:

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat pub run build_runner build --delete-conflicting-outputs
Pop-Location
```

- [ ] **Step 5: Add a real Schema 6 fixture migration test**

Create a Schema 6 database containing one account, one series, one ordinary event, one TaskEventLink, one conflict relation, and one reminder. Upgrade with the production `AppDatabase`, then assert:

```text
schemaVersion == 7
all old rows and values survive
old event-backed targets have occurrenceExceptionId == null
old TaskEventLink.targetId == old eventId
foreign_key_check returns no rows
invalid dual-backed or unbacked new rows fail
```

- [ ] **Step 6: Run migration and schema tests, then commit**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/core/database/migration_test.dart test/core/database/schedule_task_schema_test.dart
Pop-Location
git diff --check
git add app/lib/core/database/tables/schedule_tables.dart app/lib/core/database/tables/task_tables.dart app/lib/core/database/app_database.dart app/lib/core/database/app_database.g.dart app/test/core/database/migration_test.dart app/test/core/database/schedule_task_schema_test.dart
git commit -m "feat(database): add recurring occurrence targets"
```

### Task 3: Add Sparse Occurrence Anchors and Reminder Inheritance

**Files:**
- Modify: `app/lib/features/calendar/application/recurrence_service.dart`
- Modify: `app/test/features/calendar/recurrence_test.dart`

**Interfaces:**
- Changes: `RecurrenceService.createSeries({required PersonalEvent anchor, required RecurrenceRule rule, List<int>? reminderOffsetsMinutes})`.
- Produces: `Future<CalendarEventOccurrenceException> ensureOccurrenceAnchor(String seriesId, String occurrenceKey)`.
- Produces: `Future<CalendarEventOccurrenceException?> existingOccurrenceAnchor(String seriesId, String occurrenceKey)`.
- Adds: `RecurringOccurrence.reminderOffsetsMinutes`.
- Adds: `OccurrenceOverride.reminderOffsetsMinutes` with the same absent/set semantics as other fields.

- [ ] **Step 1: Write failing sparse-anchor tests**

Cover these exact cases:

1. Calling `occurrences()` performs no inserts.
2. `ensureOccurrenceAnchor()` creates one `kind=override` row with `overriddenFieldsJson='[]'`, `overrideJson='{}'`, correct original start field, and `deletedAt=null`.
3. Calling it twice returns the same row under the unique `(accountId, seriesId, occurrenceKey)` constraint.
4. Unknown series, wrong account, malformed key, and a key outside the rule all fail without writes.
5. An existing real override is returned unchanged rather than replaced with an empty override.

- [ ] **Step 2: Run the recurrence tests and verify failure**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/calendar/recurrence_test.dart
Pop-Location
```

Expected: FAIL because anchor APIs and reminder inheritance are absent.

- [ ] **Step 3: Implement anchor creation inside one transaction**

Resolve and validate the occurrence with the existing recurrence rule before writing. Insert an empty override only after validation, use `insertOnConflictUpdate` only where it cannot overwrite a real override, and reselect the row after a unique-key race. Neither read-only lookup nor anchor creation writes its own ActionLog: the approved parent mutation owns the single user-visible ActionLog and Undo snapshot in the same transaction.

- [ ] **Step 4: Persist and inherit reminder offsets**

Validate offsets as non-negative, unique integers sorted ascending. Defaults are `[15]` for timed recurring events and `[]` for all-day recurring events. Store the series list in `reminder_offsets_json`; an occurrence override may replace it with another list, including an explicit empty list. `RecurringOccurrence` must expose the effective inherited list.

- [ ] **Step 5: Re-run focused tests and commit**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/calendar/recurrence_test.dart
Pop-Location
git diff --check
git add app/lib/features/calendar/application/recurrence_service.dart app/test/features/calendar/recurrence_test.dart
git commit -m "feat(calendar): add sparse occurrence anchors"
```

### Task 4: Build the Bounded Recurring Projection

**Files:**
- Create: `app/lib/features/calendar/application/recurring_event_projection.dart`
- Create: `app/test/features/calendar/recurring_event_projection_test.dart`
- Modify: `app/lib/features/calendar/application/recurrence_service.dart`

**Interfaces:**
- Produces: `enum RecurringProjectionMode { display, management }`.
- Produces: sealed `ProjectedRecurringTarget` with common `CalendarEventLocator locator`, `String title`, `String lifecycleState`, and `List<String> availableScopes`.
- Produces: `ProjectedRecurringOccurrence extends ProjectedRecurringTarget` with `RecurringOccurrence occurrence` and `int? deletedAt`.
- Produces: `ProjectedRecurringSeries extends ProjectedRecurringTarget` with the series row and no fabricated occurrence time.
- Produces: `Future<List<ProjectedRecurringOccurrence>> projectRange({required DateTime from, required DateTime through, required RecurringProjectionMode mode, Set<String> lifecycleStates = const {}})`.
- Produces: `Future<List<ProjectedRecurringSeries>> searchSeries({required String query, Set<String> lifecycleStates = const {}})` with `availableScopes == ['whole_series']`.

- [ ] **Step 1: Write failing range-projection tests**

Use real in-memory Drift rows and `RecurrenceService.createSeries`. Cover timed/all-day daily, weekly multi-weekday, and monthly month-end series; moved overrides; cancelled exceptions; deleted exceptions; cancelled/deleted whole series; series effective bounds; account isolation; and zero writes during projection.

- [ ] **Step 2: Add explicit bound tests**

Assert reversed ranges fail, 367 inclusive days fail with `RecurrenceLimitError`, and more than 1,000 generated occurrences fail rather than returning a partial list.

- [ ] **Step 3: Run the new tests and verify failure**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/calendar/recurring_event_projection_test.dart
Pop-Location
```

- [ ] **Step 4: Implement projection without `calendar_events` writes**

For each account-owned series whose bounds can intersect the query, decode its rule, call the existing expander for the requested range, merge exceptions, and construct an `occ_v1...` locator. `display` excludes cancelled, hidden, skipped, and deleted targets. `management` includes only requested lifecycle states and must retain the original occurrence identity after a time override.

For query-only management search, return one series result per matching title with a `series_v1...` locator. Never choose an arbitrary occurrence when no date was supplied.

- [ ] **Step 5: Run projection tests and commit**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/calendar/recurring_event_projection_test.dart test/features/calendar/recurrence_test.dart
Pop-Location
git diff --check
git add app/lib/features/calendar/application/recurring_event_projection.dart app/lib/features/calendar/application/recurrence_service.dart app/test/features/calendar/recurring_event_projection_test.dart app/test/features/calendar/recurrence_test.dart
git commit -m "feat(calendar): project recurring events by range"
```

### Task 5: Integrate Recurrence into the Weekly Schedule

**Files:**
- Modify: `app/lib/features/schedule/domain/overlap_engine.dart`
- Modify: `app/lib/features/schedule/application/effective_event_repository.dart`
- Modify: `app/lib/features/schedule/application/conflict_service.dart`
- Modify: `app/lib/features/schedule/presentation/schedule_page.dart`
- Modify: `app/lib/features/schedule/presentation/event_detail_loader.dart`
- Modify: `app/test/features/schedule/schedule_projection_test.dart`
- Modify: `app/test/features/schedule/schedule_page_test.dart`
- Modify: `app/test/features/schedule/event_detail_loader_test.dart`

**Interfaces:**
- Changes: `watchDisplayEvents({required DateTime from, required DateTime through})` expands personal series only for that range.
- Produces: locator-aware event detail lookup for both stored events and recurring occurrences.
- Preserves: `EffectiveEvent.id` remains the local interaction ID; recurring events use encoded `occ_v1...` locators.

- [ ] **Step 1: Write failing repository and widget tests**

Assert that a real series occurrence appears in the selected seven-day grid, carries its title/location/color, participates in overlap grouping, opens a detail view, and disappears when the week changes outside its range. Assert no occurrence appears twice when an exception anchor exists.

- [ ] **Step 2: Add watch invalidation tests**

The stream must emit after changes to `calendar_event_series` or `calendar_event_occurrence_exceptions`, in addition to the tables already watched. Editing a single exception must update only the effective occurrence while preserving its locator.

- [ ] **Step 3: Run focused tests and verify failure**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/schedule/schedule_projection_test.dart test/features/schedule/schedule_page_test.dart test/features/schedule/event_detail_loader_test.dart
Pop-Location
```

- [ ] **Step 4: Make the repository range-aware**

Keep the existing SQL path for `calendar_events`, merge `RecurringEventProjection.projectRange(... display)`, sort the combined output deterministically, and run conflict projection once over the bounded consumer range. Update every caller to pass its actual range; do not retain an unbounded compatibility overload.

- [ ] **Step 5: Resolve recurring event details and conflicts**

When an ID decodes as an occurrence locator, load the series plus effective occurrence instead of querying `calendar_events.id`. For occurrence-level explicit relations, use the locator as the logical participant ID and resolve the backing exception through `existingOccurrenceAnchor`; absence means there is no explicit occurrence relation. Series rules continue to use `calendar_event_series` identity.

- [ ] **Step 6: Run focused tests and commit**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/schedule/schedule_projection_test.dart test/features/schedule/schedule_page_test.dart test/features/schedule/event_detail_loader_test.dart test/features/schedule/overlay_conflict_test.dart
Pop-Location
git diff --check
git add app/lib/features/schedule/domain/overlap_engine.dart app/lib/features/schedule/application/effective_event_repository.dart app/lib/features/schedule/application/conflict_service.dart app/lib/features/schedule/presentation/schedule_page.dart app/lib/features/schedule/presentation/event_detail_loader.dart app/test/features/schedule/schedule_projection_test.dart app/test/features/schedule/schedule_page_test.dart app/test/features/schedule/event_detail_loader_test.dart
git commit -m "feat(schedule): display recurring occurrences"
```

### Task 6: Bind Production Agent Queries to Recurring Targets

**Files:**
- Modify: `app/lib/features/agent/application/agent_local_data_gateway.dart`
- Modify: `app/lib/features/agent/application/agent_tools.dart`
- Modify: `app/lib/features/agent/application/agent_management_tools.dart`
- Modify: `app/lib/features/agent/domain/agent_write_gateway.dart`
- Modify: `app/lib/features/agent/data/drift_agent_write_gateway.dart`
- Modify: `app/test/features/agent/local_agent_tools_test.dart`
- Modify: `app/test/features/agent/agent_management_tools_test.dart`
- Modify: `app/test/features/agent/drift_agent_write_gateway_test.dart`

**Interfaces:**
- Changes: `displayEvents(String accountId, {required DateTime from, required DateTime through})`.
- Produces: locator-aware `eventSnapshotByLocator`, `personalEventByLocator`, and recurring target resolution in the Drift write gateway.
- Produces: management results that can represent a stored event, concrete recurring occurrence, or series-only target without manufacturing a `CalendarEvent` row.

- [ ] **Step 1: Write failing real-gateway query tests**

Create a series with `RecurrenceService`, invoke the real `DriftAgentLocalDataGateway`, and assert `get_schedule(from, through)` returns the occurrence and binds an event ref. Resolve that ref and decode it to the exact series ID and occurrence key. No fake gateway may supply `personalSeriesId` or `occurrenceKey` in this test.

- [ ] **Step 2: Add management-query tests**

Cover:

```text
date range + lifecycle state -> concrete occurrence ref, all three scopes
query only -> series ref, whole_series only
query + date range -> concrete matching occurrence refs
wrong account -> no result
ordinary event refs -> unchanged
```

DTO allowlists may expose `isRecurring`, `availableScopes`, safe title/time, and lifecycle state. They must not expose locator text, series ID, occurrence key, exception ID, or database ID.

- [ ] **Step 3: Run tests and verify failure**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/local_agent_tools_test.dart test/features/agent/agent_management_tools_test.dart test/features/agent/drift_agent_write_gateway_test.dart
Pop-Location
```

- [ ] **Step 4: Pass parsed ranges into the gateway before reading events**

Remove the current `displayEvents(accountId)` then Dart-filter-all-history pattern. Parse and enforce the view's date bound first, then ask the gateway for exactly that range. Keep query-only ordinary-event historical search, but return series summaries rather than expanding unbounded recurring history.

- [ ] **Step 5: Make write preflight locator-aware**

Decode event ref bindings at the write-gateway boundary. Stored locators continue to call `CalendarEventService`; occurrence locators call `RecurrenceService.occurrence`; series locators permit only whole-series preflight. Return deterministic `reference_not_found`, `source_event_not_editable`, or `occurrence_not_found` errors without database changes.

- [ ] **Step 6: Run focused tests and commit**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/local_agent_tools_test.dart test/features/agent/agent_management_tools_test.dart test/features/agent/drift_agent_write_gateway_test.dart
Pop-Location
git diff --check
git add app/lib/features/agent/application/agent_local_data_gateway.dart app/lib/features/agent/application/agent_tools.dart app/lib/features/agent/application/agent_management_tools.dart app/lib/features/agent/domain/agent_write_gateway.dart app/lib/features/agent/data/drift_agent_write_gateway.dart app/test/features/agent/local_agent_tools_test.dart app/test/features/agent/agent_management_tools_test.dart app/test/features/agent/drift_agent_write_gateway_test.dart
git commit -m "feat(agent): query recurring event targets"
```

### Task 7: Make Recurring `create_event` a Production Entry Point

**Files:**
- Modify: `app/lib/features/agent/application/agent_write_tools.dart`
- Modify: `app/lib/features/agent/domain/agent_write_gateway.dart`
- Modify: `app/lib/features/agent/data/drift_agent_write_gateway.dart`
- Modify: `app/test/features/agent/write_tools_test.dart`
- Modify: `app/test/features/agent/drift_agent_write_gateway_test.dart`
- Modify: `app/test/integration/agent_composition_flow_test.dart`

**Interfaces:**
- Adds: optional `recurrence` object to `create_event`.
- Produces: `Future<String> createRecurringEvent(PersonalEvent anchor, RecurrenceRule rule, {List<int>? reminderOffsetsMinutes})`.

- [ ] **Step 1: Write failing schema and proposal tests**

Add this exact optional tool shape:

```json
{
  "recurrence": {
    "frequency": "daily|weekly|monthly",
    "interval": 1,
    "weekdays": [1, 3, 5],
    "until_date": "2026-12-31"
  }
}
```

Rules:

- `interval` defaults to 1 and must be positive.
- `weekdays` is required and non-empty only for weekly recurrence; values are ISO weekdays 1 through 7 and deduplicated.
- `until_date` is optional, inclusive, and cannot precede the anchor date.
- The recurrence anchor is taken from `start_at` or `start_date`; the model cannot supply a conflicting anchor.
- `reminder_offsets_minutes` becomes the series default; omitted means `[15]` for timed and `[]` for all-day.
- Confirmation preview shows frequency, interval, weekdays where applicable, inclusive end or “持续重复”, and the first five occurrence dates/times.

- [ ] **Step 2: Run write-tool tests and verify failure**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/write_tools_test.dart test/features/agent/drift_agent_write_gateway_test.dart
Pop-Location
```

- [ ] **Step 3: Implement parsing and gateway dispatch**

Keep one-off behavior byte-for-byte compatible when `recurrence` is absent. When present, construct a validated `RecurrenceRule`, put it in the approved proposal's `commitParams`, and commit through `createRecurringEvent`. The business insert, ActionLog, confirmation log, and permission decision remain inside the existing Agent unit-of-work transaction boundary.

- [ ] **Step 4: Add a real composition test**

Drive the production tool registry and confirmation resume path, approve a weekly recurring event, and assert exactly one `calendar_event_series` row, zero `calendar_events` occurrence rows, and the expected reminder defaults. Rejecting confirmation must leave both tables unchanged.

- [ ] **Step 5: Run focused tests and commit**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/write_tools_test.dart test/features/agent/drift_agent_write_gateway_test.dart test/integration/agent_composition_flow_test.dart
Pop-Location
git diff --check
git add app/lib/features/agent/application/agent_write_tools.dart app/lib/features/agent/domain/agent_write_gateway.dart app/lib/features/agent/data/drift_agent_write_gateway.dart app/test/features/agent/write_tools_test.dart app/test/features/agent/drift_agent_write_gateway_test.dart app/test/integration/agent_composition_flow_test.dart
git commit -m "feat(agent): create recurring personal events"
```

### Task 8: Persist Occurrence Relationships, Reminders, and Task Links

**Files:**
- Modify: `app/lib/features/schedule/application/conflict_service.dart`
- Modify: `app/lib/features/reminders/application/reminder_override_service.dart`
- Modify: `app/lib/features/reminders/application/reminder_service.dart`
- Modify: `app/lib/features/reminders/application/windows_reminder_reconciler.dart`
- Modify: `app/lib/features/calendar/application/calendar_event_service.dart`
- Modify: `app/lib/features/agent/application/agent_write_tools.dart`
- Modify: `app/lib/features/agent/data/drift_agent_write_gateway.dart`
- Modify: `app/test/features/schedule/overlay_conflict_test.dart`
- Modify: `app/test/features/reminders/reminder_override_undo_test.dart`
- Modify: `app/test/features/reminders/reminder_service_test.dart`
- Modify: `app/test/features/calendar/calendar_event_service_test.dart`
- Modify: `app/test/features/agent/drift_agent_write_gateway_test.dart`

**Interfaces:**
- Produces: locator-aware relation/reminder/Task-link mutation methods that call `ensureOccurrenceAnchor` only inside an approved write transaction.
- Preserves: external Agent refs remain kind `event`; callers do not choose the backing FK.

- [ ] **Step 1: Write failing relation-anchor tests**

Create two overlapping projected occurrences, classify the pair, and assert:

```text
one no-op exception anchor per recurring participant
relation.leftId/rightId use logical locators
left/rightOccurrenceExceptionId point to anchors
left/rightEventId are null for recurring participants
projection resolves the explicit state on the next read
```

Also cover one recurring occurrence paired with a stored event or PlanBlock and reject cross-account pairs atomically.

- [ ] **Step 2: Write failing reminder and Task-link tests**

For a recurring occurrence, setting reminders or linking a Task must create/reuse one anchor. Reminder reconciliation must schedule from the effective overridden occurrence time, cancel desired reminders when the exception is cancelled/deleted, and preserve delivered/missed/failed history. Repeated writes must not duplicate anchors, links, or identical reminder triggers.

- [ ] **Step 3: Run focused tests and verify failure**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/schedule/overlay_conflict_test.dart test/features/reminders/reminder_override_undo_test.dart test/features/reminders/reminder_service_test.dart test/features/calendar/calendar_event_service_test.dart test/features/agent/drift_agent_write_gateway_test.dart
Pop-Location
```

- [ ] **Step 4: Implement logical-target resolution at service boundaries**

Decode the event locator, validate ownership and current occurrence existence, then either populate the existing event FK or call `ensureOccurrenceAnchor` and populate the occurrence-exception FK. Services, not tool code, own this choice. The whole business mutation, anchor insert, ActionLog, confirmation log, and Undo snapshot must share one Drift transaction.

- [ ] **Step 5: Reconcile series reminder defaults in a bounded lookahead**

On app reconciliation, project from the current Beijing date through 31 days ahead. For each effective timed occurrence, calculate triggers from its inherited offsets and create/reuse an anchor only when a future desired reminder must be persisted. All-day series with an empty default create no reminder rows. Never expand beyond 31 days in one reconciliation run.

- [ ] **Step 6: Run focused tests and commit**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/schedule/overlay_conflict_test.dart test/features/reminders/reminder_override_undo_test.dart test/features/reminders/reminder_service_test.dart test/features/calendar/calendar_event_service_test.dart test/features/agent/drift_agent_write_gateway_test.dart
Pop-Location
git diff --check
git add app/lib/features/schedule/application/conflict_service.dart app/lib/features/reminders/application/reminder_override_service.dart app/lib/features/reminders/application/reminder_service.dart app/lib/features/reminders/application/windows_reminder_reconciler.dart app/lib/features/calendar/application/calendar_event_service.dart app/lib/features/agent/application/agent_write_tools.dart app/lib/features/agent/data/drift_agent_write_gateway.dart app/test/features/schedule/overlay_conflict_test.dart app/test/features/reminders/reminder_override_undo_test.dart app/test/features/reminders/reminder_service_test.dart app/test/features/calendar/calendar_event_service_test.dart app/test/features/agent/drift_agent_write_gateway_test.dart
git commit -m "feat(schedule): persist recurring occurrence targets"
```

### Task 9: Pass the Production Reachability Hard Gate

**Files:**
- Modify: `app/test/integration/agent_composition_flow_test.dart`
- Modify: `app/test/integration/read_only_agent_flow_test.dart`
- Modify: `app/test/integration/first_milestone_flow_test.dart`
- Modify: `docs/schedule-data-model.md`
- Modify: `docs/architecture.md`
- Modify: `docs/read-only-agent-handoff.md`
- Modify: `docs/superpowers/plans/2026-08-03-agent-complete-delete-tools.md`

**Interfaces:**
- Produces: verified end-to-end recurrence path and an explicit handoff back to original Task 6.
- Removes: fake-only claims that a `calendar_events` row with manually populated `personalSeriesId/occurrenceKey` proves recurring production behavior.

- [ ] **Step 1: Write the end-to-end hard-gate test before changing documentation**

Use the production database, tool registry, confirmation store, local data gateway, and write gateway:

```text
1. create_event with weekly recurrence and approve it
2. assert one series row and zero calendar_events occurrence rows
3. call get_schedule for a week containing one occurrence
4. resolve returned ref_event and prove seriesId + occurrenceKey
5. call set_reminder and create_schedule_relation against that ref
6. verify sparse anchor and dependent rows
7. restart the composition against the same database
8. query the same week and prove stable occurrence identity and dependencies
9. query another account and prove isolation
```

Do not call Task 6 lifecycle methods in this test; this plan establishes their target path, not their implementation.

- [ ] **Step 2: Run the hard-gate integration tests**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/integration/agent_composition_flow_test.dart test/integration/read_only_agent_flow_test.dart test/integration/first_milestone_flow_test.dart
Pop-Location
```

Expected: PASS with no fake local gateway in the recurrence scenario.

- [ ] **Step 3: Update durable documentation**

Record all of the following explicitly:

- range-expanded occurrences are effective query objects, not `calendar_events` rows;
- encoded locators are local implementation identities and never model-visible;
- empty occurrence exceptions are sparse FK anchors and have no display effect;
- Schema 7 dependent-target rules and 31-day reminder reconciliation horizon;
- query-only recurring search returns a series target limited to `whole_series`;
- UI `RecurrenceEditor` remains a separate wiring task if it is still not connected after this plan;
- automatic tests prove the local production composition only and do not count as real school-network acceptance.

Change the original Task 6 hard-gate step from “stop if unreachable” to “require the Task 6A hard-gate test and then proceed”. Do not mark Task 6 complete.

- [ ] **Step 4: Run full static and automated verification**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat analyze
E:\flutter\flutter\bin\flutter.bat test
Pop-Location
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
git diff --check
```

Expected:

```text
flutter analyze: no issues
all Flutter tests: pass
all Python tests: pass
compileall: pass
git diff --check: no errors
```

- [ ] **Step 5: Commit the hard gate and documentation**

```powershell
git add app/test/integration/agent_composition_flow_test.dart app/test/integration/read_only_agent_flow_test.dart app/test/integration/first_milestone_flow_test.dart docs/schedule-data-model.md docs/architecture.md docs/read-only-agent-handoff.md docs/superpowers/plans/2026-08-03-agent-complete-delete-tools.md
git commit -m "test(calendar): prove recurring production reachability"
```

### Task 10: Resume Original Delete-Tools Task 6

**Files:**
- Read: `docs/superpowers/plans/2026-08-03-agent-complete-delete-tools.md`
- Read: this plan's Task 9 verification output and commits
- No code changes in this checkpoint task

**Interfaces:**
- Consumes: production occurrence locators, bounded projections, sparse anchors, dependent-target Schema 7, and real Agent refs.
- Unblocks: original Task 6 `only_this`, `this_and_future`, and `whole_series` lifecycle implementation.

- [ ] **Step 1: Review the hard-gate evidence**

Confirm all nine Task 9 end-to-end assertions pass and `git status --short` contains no unexpected implementation changes. A test that inserts a fake `calendar_events` row with `personalSeriesId/occurrenceKey` does not satisfy this gate.

- [ ] **Step 2: Start original Task 6 from its Step 2**

Use the real occurrence locator and sparse-anchor APIs. Keep the original lifecycle semantics:

```text
only_this: exception status/deletedAt
this_and_future: split series and migrate compatible exceptions plus anchored dependencies
whole_series: series status/deletedAt, no occurrence materialization
```

If Task 6 needs to change Schema 7 again, stop and return to the owner with the exact missing representation; do not add another implicit storage convention.

## Plan Completion Criteria

This prerequisite is complete only when:

1. A recurring event can be created through the production Agent `create_event` path.
2. Its occurrence appears in the real seven-day schedule and `get_schedule` without a `calendar_events` occurrence row.
3. The returned opaque ref resolves internally to the stable series/occurrence identity.
4. A read query produces zero database writes.
5. A relation, reminder, or Task link creates exactly one reusable no-op exception anchor.
6. Schema 6 data survives migration to Schema 7 with valid foreign keys.
7. Restart and account-isolation integration tests pass.
8. Full Flutter and Python verification passes.
9. The original Task 6 plan points to this evidence and remains uncompleted until its lifecycle code is implemented.
