# USTC Assistant Windows First Milestone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Status (2026-07-28):** This historical plan has been implemented. Its
> unchecked boxes are not live task tracking. See `docs/read-only-agent-handoff.md` for
> the current baseline and remaining manual acceptance work.

**Goal:** Build the first Windows Flutter development version that imports and synchronizes JW plus registered second-classroom schedules, preserves local overlays, and provides the confirmed seven-day schedule, personal CalendarEvent, Task, PlanBlock, account, history, settings, and process-lifetime reminder workflows without an LLM.

**Architecture:** Migrate the existing Python collectors to the canonical SourceBundle 1.0 contract, expose those source services through a temporary authenticated loopback Bridge, and consume complete bundles through one transactional Flutter `ImportService`. Flutter owns account-partitioned Drift persistence, domain services, projections, undo, reminder records, and presentation; Python remains a Windows-only source adapter.

**Tech Stack:** Python 3.10.20, Playwright, `jsonschema` Draft 2020-12 validation, Flutter 3.44.5, Dart 3.12.2, Riverpod 3.3.2, GoRouter 17.3.0, Drift 2.34.x with `drift_flutter`, `json_schema` 5.2.x through a generated Draft 7-compatible contract asset, `win32` 6.3.x for DPAPI, `http` 1.6.x, `file_selector` 1.1.x, `url_launcher` 6.3.x for allowlisted official pages, and `flutter_local_notifications` 22.2.x for notifications while the unpackaged App process is running.

## Global Constraints

- Python commands run in Conda environment `ustc_assistant`; minimum supported Python is 3.10.
- Flutter commands use `E:\flutter\flutter\bin\flutter.bat` or `$env:Flutter_Path\flutter.bat`; verified SDK is Flutter 3.44.5 with Dart 3.12.2.
- Time calculations use `Asia/Shanghai`; stored timed instants use UTC epoch milliseconds and all-day values use `YYYY-MM-DD`.
- JW defaults come only from `config/source-defaults.json`: `semesterId=421`, `semesterKey=2026spring`, `displayName=2026 春季学期`.
- Never derive a JW numeric semester ID from year, label, or adjacent IDs.
- School account names are always DPAPI-protected locally; passwords are optional and never stored in plaintext.
- SourceBundle contains local opaque `accountId`, never school username, student number, remote user ID, JW context ID, cookie, token, raw HTML, browser path, or arbitrary metadata.
- JW and registered second-classroom schedule bundles are complete snapshots; any uncertain component/date fails without a partial bundle.
- Second-classroom registration and cancellation always remain user actions on the official page.
- Active-enrolment, iCourse, and campus services retain their existing CLI capabilities and tests but receive no first-milestone Flutter screens.
- The unpackaged Windows milestone guarantees Reminder persistence, in-App reminder state, and Windows notifications only while the App process is running; it does not claim closed-App delivery or cancellation.
- Chat is a disabled shell: no LLM, fake reply, daily briefing, chat persistence, or Agent write path.
- Existing source tests never access school websites; real Edge acceptance is manual.
- Use `apply_patch` for manual edits, preserve unrelated user changes, and do not commit `tmp/`, `temp.md`, browser profiles, caches, credentials, or raw responses.
- Every implementation task follows red-green TDD and ends with an independently reviewable commit.
- Every absolute repository path in command-location guidance means the active Git worktree root, not a particular checkout. Conda, Git, and Python commands run from that root; after Task 9, Flutter and Dart commands run from that worktree's `app/` unless a command block explicitly changes location.

## Target Repository Structure

```text
config/
  source-defaults.json

src/ustc_assistant/
  config.py
  contracts/
    __init__.py
    source_bundle.py
    source_bundle_validation.py
    schema_export.py
  bridge/
    __init__.py
    __main__.py
    protocol.py
    jobs.py
    server.py
  common/
    browser.py
    auth.py
  sources/
    jw/source_bundle.py
    young/source_bundle.py

tests/
  contracts/
  bridge/
  config/

app/
  pubspec.yaml
  assets/schemas/source-bundle-1.0.draft7.schema.json
  lib/
    main.dart
    app/
    core/
      database/
      security/
      time/
    features/
      accounts/
      import/
      sync/
      schedule/
      calendar/
      tasks/
      reminders/
      history/
      settings/
  test/
  integration_test/
```

## Normative References

Read these before Task 1 and keep them open while executing later tasks:

```text
AGENTS.md
docs/superpowers/specs/2026-07-26-first-windows-milestone-closure-design.md
docs/data-sources/source-bundle-v1.md
schemas/source-bundle-1.0.schema.json
docs/schedule-data-model.md
docs/superpowers/specs/2026-07-23-flutter-app-shell-schedule-design.md
docs/superpowers/specs/2026-07-24-flutter-auth-sync-design.md
docs/superpowers/specs/2026-07-24-flutter-task-planning-design.md
docs/superpowers/specs/2026-07-25-flutter-personal-calendar-event-design.md
```

---

### Task 1: Shared JW Semester Configuration

**Files:**
- Create: `config/source-defaults.json`
- Create: `src/ustc_assistant/config.py`
- Create: `tests/config/test_source_config.py`
- Modify: `src/ustc_assistant/cli.py`
- Modify: `tests/test_cli.py`
- Modify: `README.md`

**Interfaces:**
- Produces: `JwSemesterConfig(semester_id: int, semester_key: str, display_name: str)`
- Produces: `load_default_jw_semester(path: Path | None = None) -> JwSemesterConfig`
- Produces: `resolve_jw_semester(default, *, semester_id, semester_key, display_name) -> JwSemesterConfig`
- Consumed by: CLI collection, Bridge capabilities, and JW SourceBundle producer.

- [ ] **Step 1: Write failing configuration tests**

```python
class SourceConfigTests(unittest.TestCase):
    def test_repository_default_is_2026_fall(self):
        config = load_default_jw_semester(ROOT / "config/source-defaults.json")
        self.assertEqual(config.semester_id, 421)
        self.assertEqual(config.semester_key, "2026spring")
        self.assertEqual(config.display_name, "2026 春季学期")

    def test_debug_override_requires_the_complete_triple(self):
        with self.assertRaisesRegex(SourceConfigError, "complete semester override"):
            resolve_jw_semester(DEFAULT, semester_id=421)
```

- [ ] **Step 2: Run the tests and observe the missing module failure**

Run: `conda run -n ustc_assistant python -m unittest tests.config.test_source_config -v`

Expected: import failure for `ustc_assistant.config`.

- [ ] **Step 3: Implement strict shared configuration loading**

```python
@dataclass(frozen=True)
class JwSemesterConfig:
    semester_id: int
    semester_key: str
    display_name: str

def resolve_jw_semester(
    default: JwSemesterConfig,
    *,
    semester_id: int | None = None,
    semester_key: str | None = None,
    display_name: str | None = None,
) -> JwSemesterConfig:
    values = (semester_id, semester_key, display_name)
    if any(value is not None for value in values) and not all(
        value is not None for value in values
    ):
        raise SourceConfigError("complete semester override is required")
    return default if all(value is None for value in values) else JwSemesterConfig(
        semester_id=semester_id,
        semester_key=semester_key,
        display_name=display_name,
    )
```

Load UTF-8 JSON from the repository configuration, reject unknown keys, booleans as integer IDs, blank text, and IDs below 1. Change CLI defaults to call this module and add `--semester-name`; preserve explicit `421 / 2026spring` tests by passing the complete triple.

- [ ] **Step 4: Run configuration and CLI tests**

Run: `conda run -n ustc_assistant python -m unittest tests.config.test_source_config tests.test_cli -v`

Expected: all selected tests pass and parser defaults report 421/2026spring/2026 春季学期.

- [ ] **Step 5: Run the full Python gate and commit**

```powershell
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
git add config src/ustc_assistant/config.py src/ustc_assistant/cli.py tests/config tests/test_cli.py README.md
git commit -m "feat: centralize JW semester configuration"
```

### Task 2: Canonical SourceBundle Validation and Flutter Schema Export

**Files:**
- Create: `src/ustc_assistant/contracts/__init__.py`
- Create: `src/ustc_assistant/contracts/source_bundle.py`
- Create: `src/ustc_assistant/contracts/source_bundle_validation.py`
- Create: `src/ustc_assistant/contracts/schema_export.py`
- Create: `tests/contracts/test_source_bundle.py`
- Create: `tests/contracts/test_schema_export.py`
- Move positive fixtures into: `tests/fixtures/source-bundle/positive/`
- Create negative fixtures only under: `tests/fixtures/source-bundle/negative/`
- Modify: `pyproject.toml`

**Interfaces:**
- Produces: `validate_source_bundle(bundle: Mapping[str, Any]) -> None`
- Produces: `canonical_bundle_digest(bundle: Mapping[str, Any]) -> str`
- Produces: `make_bundle_envelope(...) -> dict[str, Any]`
- Produces: `build_draft7_compat_schema(canonical: Mapping[str, Any]) -> dict[str, Any]`
- Produces CLI: `python -m ustc_assistant.contracts.schema_export --output <path>`
- Raises: `SourceBundleValidationError(code: str, safe_message: str)`

- [ ] **Step 1: Add failing acceptance and rejection tests**

```python
class SourceBundleContractTests(unittest.TestCase):
    def test_all_four_shared_fixtures_validate(self):
        for path in POSITIVE_FIXTURE_DIR.glob("*.json"):
            validate_source_bundle(json.loads(path.read_text(encoding="utf-8")))

    def test_duplicate_external_identity_is_rejected_safely(self):
        bundle = load_fixture("jw-with-exam.json")
        bundle["data"]["calendarEvents"].append(
            copy.deepcopy(bundle["data"]["calendarEvents"][0])
        )
        with self.assertRaises(SourceBundleValidationError) as caught:
            validate_source_bundle(bundle)
        self.assertEqual(caught.exception.code, "duplicate_identity")
        self.assertNotIn(bundle["data"]["calendarEvents"][0]["externalId"], str(caught.exception))
```

Add tests for manifest mismatch, dangling references, invalid `+08:00` time,
incomplete snapshots, hard limits, unknown fields, subject mismatch helper
behavior, unsupported higher minor/major versions, and deterministic SHA-256
digest from canonical UTF-8 JSON. Positive and negative fixtures must remain in
their distinct directories; no glob may treat rejection fixtures as valid
examples.

- [ ] **Step 2: Run tests and confirm failure**

Run: `conda run -n ustc_assistant python -m unittest tests.contracts.test_source_bundle -v`

Expected: import failure for `ustc_assistant.contracts`.

- [ ] **Step 3: Add Draft 2020-12 schema validation and semantic checks**

Add `jsonschema>=4.23,<5` to `pyproject.toml`. Use
`jsonschema.Draft202012Validator` for the canonical schema, followed by explicit
checks for counts, unique identities, exactly-one SourceRecord mappings,
references, scope counts, date windows, time ordering, source/event compatibility,
and forbidden sensitive keys.

```python
def canonical_bundle_digest(bundle: Mapping[str, Any]) -> str:
    encoded = json.dumps(
        bundle, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()
```

- [ ] **Step 4: Implement deterministic Draft 7 asset conversion**

Recursively transform `$defs` to `definitions`, `#/$defs/` references to
`#/definitions/`, and the metaschema URL to Draft 7. Draft 7 export removes
`minContains` and `maxContains` only for the JW component array where its fixed
array size and the two distinct `contains` constraints make both bounds
redundant. Reject those keywords everywhere else, along with any future
canonical keyword outside the explicit compatibility allowlist.

```python
def build_draft7_compat_schema(canonical: Mapping[str, Any]) -> dict[str, Any]:
    converted = _rewrite(copy.deepcopy(canonical))
    converted["$schema"] = "http://json-schema.org/draft-07/schema#"
    return converted
```

The module CLI resolves the canonical root schema, writes UTF-8 JSON with a
trailing newline, and refuses an output path outside the explicitly supplied
file. It performs no networking. Add explicit equivalence tests that validate
the positive corpus and focused component-array mutations with both Draft
2020-12 and the converted Draft 7 schema and assert identical accept/reject
results.

- [ ] **Step 5: Verify canonical and converted schemas against fixtures**

Run:

```powershell
conda run -n ustc_assistant python -m unittest tests.contracts -v
conda run -n ustc_assistant python -m compileall -q src tests
```

Expected: both contract suites pass; positive and negative fixture locations
remain distinct, malformed fixtures fail with the same stable error category,
and canonical/Draft 7 equivalence cases have identical outcomes.

- [ ] **Step 6: Commit**

```powershell
git add pyproject.toml src/ustc_assistant/contracts tests/contracts tests/fixtures/source-bundle
git commit -m "feat: validate SourceBundle 1.0 contracts"
```

### Task 3: JW SourceBundle 1.0 Producer

**Files:**
- Create: `src/ustc_assistant/sources/jw/source_bundle.py`
- Create: `tests/jw/test_source_bundle.py`
- Modify: `src/ustc_assistant/sources/jw/service.py`
- Modify: `tests/jw/test_service_regressions.py`
- Modify: `tests/jw/test_transform.py`

**Interfaces:**
- Consumes: course datum, exam HTML, `JwSemesterConfig`, local `account_id`
- Produces: `build_jw_source_bundle(...) -> dict[str, Any]`
- Produces: `collect_jw_source_bundle(...) -> tuple[dict[str, Any], CollectedSources]`
- Preserves: `collect_sources()` and all current page/response contracts.

- [ ] **Step 1: Write failing producer tests**

```python
def test_jw_bundle_has_complete_components_and_course_series(self):
    bundle = build_jw_source_bundle(
        COURSE_DATUM,
        EXAM_HTML,
        account_id="acct_test",
        semester=JwSemesterConfig(421, "2026spring", "2026 春季学期"),
        bundle_id=UUID("00000000-0000-4000-8000-000000000111"),
        collected_at=datetime(2026, 7, 26, 12, 0, tzinfo=BEIJING_TZ),
    )
    validate_source_bundle(bundle)
    self.assertEqual(bundle["source"], "ustc_jw")
    self.assertEqual(
        {item["name"] for item in bundle["snapshot"]["scope"]["components"]},
        {"course_table", "exam_arrange"},
    )
    self.assertGreater(len(bundle["data"]["courseSeries"]), 0)
```

Add cases for empty exam, multiple teachers on one occurrence, different teachers
by week, duplicate legacy rows merging, same-time different-place identity, and
proof that no overlap relation is emitted.

- [ ] **Step 2: Run the targeted tests and confirm the producer is absent**

Run: `conda run -n ustc_assistant python -m unittest tests.jw.test_source_bundle -v`

Expected: import failure for `sources.jw.source_bundle`.

- [ ] **Step 3: Build canonical CourseSeries and CalendarEvent records**

Reuse `course.build_maps`, `group_schedule_rows`, `unique_participants`,
`room_parts`, and `exam.parse_exam_rows`; do not duplicate page collection.
Generate external identities from semester key plus stable source lesson,
schedule group, date, time, place, and normalized exercise-class identity.

```python
def build_jw_source_bundle(
    course_datum: dict[str, Any],
    exam_html: str,
    *,
    account_id: str,
    semester: JwSemesterConfig,
    bundle_id: UUID | None = None,
    collected_at: datetime | None = None,
) -> dict[str, Any]:
    ...
```

Every CourseSeries, CalendarEvent, and source relation receives exactly one
SourceRecord. Exam defaults are `critical/must_go/unknown`; course defaults are
`normal/unknown/unknown`. Run `validate_source_bundle` before returning.

- [ ] **Step 4: Keep the legacy builder explicitly named during migration**

Rename the old implementation to `build_legacy_import_package` and retain a
deprecated `build_bundle` wrapper only until Task 5 moves all internal consumers.
No new code may call the wrapper.

- [ ] **Step 5: Run JW and full Python tests**

```powershell
conda run -n ustc_assistant python -m unittest tests.jw -v
conda run -n ustc_assistant python -m unittest discover -s tests -v
```

Expected: all tests pass and the formal producer accepts both JW fixtures.

- [ ] **Step 6: Commit**

```powershell
git add src/ustc_assistant/sources/jw tests/jw
git commit -m "feat: produce JW SourceBundle snapshots"
```

### Task 4: Registered Second-Classroom SourceBundle Producer

**Files:**
- Create: `src/ustc_assistant/sources/young/source_bundle.py`
- Create: `tests/young/test_source_bundle.py`
- Modify: `src/ustc_assistant/sources/young/schedule.py`
- Modify: `tests/young/test_schedule.py`

**Interfaces:**
- Consumes: `CollectedSchedules`, local `account_id`, Beijing collection time
- Produces: `build_young_schedule_source_bundle(...) -> dict[str, Any]`
- Produces: `collect_young_schedule_source_bundle(...) -> tuple[dict, CollectedSchedules]`

- [ ] **Step 1: Write failing complete-window tests**

```python
def test_empty_complete_window_is_a_valid_bundle(self):
    bundle = build_young_schedule_source_bundle(
        CollectedSchedules(
            queried_from=date(2026, 7, 19),
            queried_through=date(2026, 8, 26),
            queried_dates=39,
            empty_dates=39,
            records=(),
        ),
        account_id="acct_test",
        bundle_id=UUID("00000000-0000-4000-8000-000000000222"),
        collected_at=datetime(2026, 7, 26, 12, 0, tzinfo=BEIJING_TZ),
    )
    validate_source_bundle(bundle)
    self.assertEqual(bundle["manifest"]["calendarEventCount"], 0)
```

Add tests for one schedule, multi-day/all-day source values when present, HTML
description text stripping, count mismatch, an unchecked date, duplicate source
ID, record outside selected date, and forbidden remote user identity.

- [ ] **Step 2: Run and confirm failure**

Run: `conda run -n ustc_assistant python -m unittest tests.young.test_source_bundle -v`

Expected: import failure for `sources.young.source_bundle`.

- [ ] **Step 3: Implement the producer**

Create one CalendarEvent and one SourceRecord per registered schedule. Use
`eventType=second_class`, defaults `normal/must_go/unknown`, and
`sourceDetails.kind=young_registered_schedule`. Populate the complete inclusive
date-window scope and validate `expectedDateCount == checkedDateCount`.

- [ ] **Step 4: Preserve active-enrolment behavior and run tests**

```powershell
conda run -n ustc_assistant python -m unittest tests.young -v
conda run -n ustc_assistant python -m unittest discover -s tests -v
```

Expected: enrolment tests are unchanged; schedule SourceBundle tests pass.

- [ ] **Step 5: Commit**

```powershell
git add src/ustc_assistant/sources/young tests/young
git commit -m "feat: produce second-classroom schedule bundles"
```

### Task 5: CLI and iCourse Migration to SourceBundle

**Files:**
- Modify: `src/ustc_assistant/cli.py`
- Modify: `src/ustc_assistant/sources/icourse/service.py`
- Create: `src/ustc_assistant/sources/icourse/jw_input.py`
- Modify: `tests/test_cli.py`
- Modify: `tests/icourse/test_service_regressions.py`
- Modify: `tests/icourse/test_orchestration.py`
- Modify: `README.md`
- Modify: `docs/data-sources/jw.md`
- Modify: `docs/data-sources/young.md`

**Interfaces:**
- CLI `collect jw` and `collect young-schedule` default to SourceBundle 1.0.
- `load_jw_course_groups(path: Path) -> list[JwCourseGroup]` accepts formal SourceBundle.
- A single read-only legacy adapter remains for old local files.

- [ ] **Step 1: Change tests to require formal CLI output**

```python
def test_jw_command_writes_source_bundle_1_0(self):
    code = main(["collect", "jw", "--account-id", "acct_cli", "--output", str(OUT)])
    payload = json.loads(OUT.read_text(encoding="utf-8"))
    self.assertEqual(code, 0)
    self.assertEqual(payload["schemaVersion"], "1.0")
    self.assertEqual(payload["subject"]["accountId"], "acct_cli")
    self.assertIn("data", payload)
    self.assertNotIn("metadata", payload)
```

Add matching young-schedule tests and iCourse grouping tests using
`jw-with-exam.json`. Keep one legacy fixture test proving the compatibility
reader works without networking. Add rejection tests proving both formal
commands fail safely when `--account-id` is absent.

- [ ] **Step 2: Run selected tests and observe legacy-shape failures**

Run: `conda run -n ustc_assistant python -m unittest tests.test_cli tests.icourse.test_service_regressions -v`

Expected: assertions fail because CLI still writes legacy envelopes.

- [ ] **Step 3: Switch CLI services and adapt iCourse grouping**

Require `--account-id` for formal `collect jw` and `collect young-schedule`
SourceBundle output; there is no production or developer default.
`acct_cli_local` is fixture/test-only. Group formal JW input from
`data.courseSeries`; ignore exams and occurrence duplication. Legacy parsing is
isolated in `jw_input.py` and emits the same internal `JwCourseGroup` values.

- [ ] **Step 4: Update docs and remove ambiguous claims**

Document that the two importable CLI outputs now implement SourceBundle 1.0.
Keep active enrolment, iCourse, and campus output descriptions unchanged.

- [ ] **Step 5: Run all Python tests and commit**

```powershell
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
git add src/ustc_assistant tests README.md docs/data-sources
git commit -m "feat: migrate CLI import outputs to SourceBundle"
```

### Task 6: Browser Session Modes, Login Assistance, and Cancellation

**Files:**
- Create: `src/ustc_assistant/common/auth.py`
- Modify: `src/ustc_assistant/common/browser.py`
- Modify: `src/ustc_assistant/sources/jw/collector.py`
- Modify: `src/ustc_assistant/sources/young/schedule.py`
- Create: `tests/test_auth.py`
- Modify: `tests/jw/test_collector_regressions.py`
- Modify: `tests/young/test_schedule_regressions.py`

**Interfaces:**
- Produces: `UserActionRequired`, `AccountMismatch`, `CollectionCancelled`
- Produces: `LoginCredentials(username: str, password: str | None)`
- Extends: `run_in_edge(..., headless: bool, profile_dir: Path)`
- Extends collectors with `allow_interactive_login`, `credentials`, and `cancel_check`.

- [ ] **Step 1: Write failing session-mode tests**

```python
def test_background_collection_returns_user_action_without_visible_login(self):
    with self.assertRaises(UserActionRequired):
        collect_sources(
            semester_id=461,
            allow_interactive_login=False,
            browser_runner=fake_unauthenticated_runner,
        )
    self.assertFalse(fake_unauthenticated_runner.visible_window_opened)

def test_credentials_fill_only_on_official_cas_origin(self):
    with self.assertRaises(AuthBoundaryError):
        fill_ustc_login(FakePage("https://example.com/login"), CREDS)
```

Add tests for `id.ustc.edu.cn` allowlisting, username/password field fill without
CAPTCHA submission, per-account profile path, cancellation during each young
date iteration, and sanitized account mismatch.

- [ ] **Step 2: Run selected tests and confirm missing behavior**

Run: `conda run -n ustc_assistant python -m unittest tests.test_auth tests.jw.test_collector_regressions tests.young.test_schedule_regressions -v`

Expected: new imports and keyword arguments fail.

- [ ] **Step 3: Implement background and interactive modes**

```python
def run_in_edge(
    action: Callable[[Any], T],
    *,
    profile_dir: Path | None = None,
    headless: bool = False,
    playwright_factory: Callable[[], Any] | None = None,
) -> T:
    ...
```

When interaction is disallowed, collectors raise `UserActionRequired` as soon
as login is detected. Interactive mode opens visible Edge, fills
`input[name="username"], #username` and `input[type="password"]` only on the
official CAS host, and leaves CAPTCHA plus submission to the user.

- [ ] **Step 4: Add account verification and cancellation checkpoints**

Bind each browser profile to local `accountId`. Probe the authenticated JW home
for the current account value exposed by the page; compare in memory with the
expected protected account after Flutter supplies it. Failure to prove a match
returns `AccountMismatch` with stable error code `account_mismatch`. Check
`cancel_check()` before navigation, requests, each selected young date,
normalization, and Bundle creation.

- [ ] **Step 5: Run source and full tests**

```powershell
conda run -n ustc_assistant python -m unittest tests.test_auth tests.jw tests.young -v
conda run -n ustc_assistant python -m unittest discover -s tests -v
```

- [ ] **Step 6: Commit**

```powershell
git add src/ustc_assistant/common src/ustc_assistant/sources/jw/collector.py src/ustc_assistant/sources/young/schedule.py tests
git commit -m "feat: add resumable school browser sessions"
```

### Task 7: Authenticated Bridge Protocol Shell

**Files:**
- Create: `src/ustc_assistant/bridge/__init__.py`
- Create: `src/ustc_assistant/bridge/__main__.py`
- Create: `src/ustc_assistant/bridge/protocol.py`
- Create: `src/ustc_assistant/bridge/server.py`
- Create: `tests/bridge/test_protocol.py`
- Create: `tests/bridge/test_server.py`

**Interfaces:**
- Process entry: `python -m ustc_assistant.bridge`
- Handshake: one JSON line with `protocolVersion`, `port`, `token`, and `pid`
- HTTP: `/health`, `/capabilities`, `/shutdown`
- Authentication: `Authorization: Bearer <process token>`

- [ ] **Step 1: Write failing protocol tests**

```python
def test_handshake_token_is_random_and_not_in_argv(self):
    first = make_handshake(port=12001, pid=10)
    second = make_handshake(port=12002, pid=11)
    self.assertNotEqual(first["token"], second["token"])
    self.assertRegex(first["token"], r"^[A-Za-z0-9_-]{43}$")

def test_unauthenticated_health_is_rejected(self):
    response = request(server, "GET", "/health")
    self.assertEqual(response.status, 401)
    self.assertNotIn(server.token, response.body)
```

Add cases for wrong token, unsupported path, non-loopback bind prevention,
64 KiB request limit, invalid JSON, unsupported protocol version, and redacted
errors.

- [ ] **Step 2: Run and confirm module absence**

Run: `conda run -n ustc_assistant python -m unittest tests.bridge.test_protocol tests.bridge.test_server -v`

- [ ] **Step 3: Implement the fixed stdlib HTTP shell**

Use `ThreadingHTTPServer(("127.0.0.1", 0), Handler)`. Generate 256-bit tokens
with `secrets.token_urlsafe(32)`. Write only the handshake JSON to stdout;
diagnostics go to stderr and never contain the token. `/capabilities` returns
Bridge protocol versions and the shared JW default config.

- [ ] **Step 4: Add parent and idle shutdown**

Exit on authenticated `/shutdown`, parent PID disappearance, or 10 minutes with
no active job and no authenticated request. Unit tests inject a fake monotonic
clock and parent-alive predicate.

- [ ] **Step 5: Run Bridge and full Python tests, then commit**

```powershell
conda run -n ustc_assistant python -m unittest tests.bridge -v
conda run -n ustc_assistant python -m unittest discover -s tests -v
git add src/ustc_assistant/bridge tests/bridge
git commit -m "feat: add authenticated local Bridge shell"
```

### Task 8: Bridge Collection Jobs and Login Resume

**Files:**
- Create: `src/ustc_assistant/bridge/jobs.py`
- Modify: `src/ustc_assistant/bridge/server.py`
- Create: `tests/bridge/test_jobs.py`
- Create: `tests/bridge/test_collection_api.py`

**Interfaces:**
- POST `/collect/jw`
- POST `/collect/young-schedule`
- POST `/login/resume`
- POST `/jobs/{id}/cancel`
- GET `/jobs/{id}/events?after=<sequence>`
- Job states: `starting`, `checking_session`, `needs_user_login`, `waiting_for_user`, `collecting`, `normalizing`, `complete`, `cancelled`, `failed`

- [ ] **Step 1: Write failing job-state tests**

```python
def test_user_action_job_resumes_to_complete_bundle(self):
    job = manager.start_jw(REQUEST, collector=fake_requires_login_then_succeeds)
    self.assertEqual(job.wait_for_terminal_or_pause(), "needs_user_login")
    manager.resume_login(job.id, credentials=CREDS)
    self.assertEqual(job.wait_for_terminal_or_pause(), "complete")
    validate_source_bundle(job.result)

def test_second_job_is_rejected_while_profile_is_owned(self):
    manager.start_jw(REQUEST, collector=blocking_collector)
    with self.assertRaises(BridgeBusy):
        manager.start_young_schedule(YOUNG_REQUEST)
```

Add cancel, source failure, account mismatch, event cursor, safe count, and
complete-bundle-only cases.

- [ ] **Step 2: Run tests and confirm missing job manager**

Run: `conda run -n ustc_assistant python -m unittest tests.bridge.test_jobs tests.bridge.test_collection_api -v`

- [ ] **Step 3: Implement bounded request models and sequential JobManager**

JW requests contain only account ID, expected school username, and the full
semester triple. Young requests contain account ID, expected school username,
and optional Beijing `today` override for development. The expected username is
used only for in-memory account verification and never enters a Bundle, event,
error, or log. Password credentials are accepted only by `/login/resume` for a
paused job and are never retained in job event history.

- [ ] **Step 4: Implement long-poll progress and complete results**

`GET /events` returns:

```json
{
  "events": [{"sequence": 1, "phase": "collecting", "safeCount": 10}],
  "nextSequence": 1,
  "terminal": false,
  "result": null
}
```

Only a terminal `complete` response includes `result`. Failed and cancelled
responses contain a stable error code and safe message.

- [ ] **Step 5: Verify Bridge, source, and full Python suites**

```powershell
conda run -n ustc_assistant python -m unittest tests.bridge tests.jw tests.young -v
conda run -n ustc_assistant python -m unittest discover -s tests -v
```

- [ ] **Step 6: Commit**

```powershell
git add src/ustc_assistant/bridge tests/bridge
git commit -m "feat: expose source collection jobs through Bridge"
```

### Task 9: Flutter Project Scaffold and Dependency Lock

**Files:**
- Create: `app/` through Flutter scaffold
- Modify: `.gitignore`
- Create: `app/assets/schemas/source-bundle-1.0.draft7.schema.json`
- Create: `app/test/scaffold_test.dart`
- Modify: `AGENTS.md`
- Modify: `README.md`

**Interfaces:**
- Flutter package name: `ustc_assistant_app`
- Organization: `io.github.youj88333`
- Platforms scaffolded: Windows, Android, iOS
- First executable target: Windows.

- [ ] **Step 1: Verify Flutter before creating files**

Run:

```powershell
& "$env:Flutter_Path\flutter.bat" --no-version-check --version
& "$env:Flutter_Path\flutter.bat" doctor -v
```

Expected: Flutter 3.44.5 and Dart 3.12.2. Record missing Windows toolchain
components as a blocking environment result; do not weaken the plan or tests.

- [ ] **Step 2: Create the nested Flutter project**

Run:

```powershell
& "$env:Flutter_Path\flutter.bat" create --project-name ustc_assistant_app --org io.github.youj88333 --platforms windows,android,ios app
```

Review generated changes and preserve the repository root README and ignore
rules. Update `AGENTS.md` only to report that the Flutter scaffold now exists;
do not describe later milestone capabilities as completed.

- [ ] **Step 3: Add exact first-milestone dependencies**

From `app/` run:

```powershell
& "$env:Flutter_Path\flutter.bat" pub add flutter_riverpod:^3.3.2 go_router:^17.3.0 drift:^2.34.2 drift_flutter:^0.3.1 path_provider:^2.1.6 json_schema:^5.2.2 uuid:^4.5.2 crypto:^3.0.7 http:^1.6.0 file_selector:^1.1.0 url_launcher:^6.3.2 win32:^6.3.0 flutter_local_notifications:^22.2.0
& "$env:Flutter_Path\flutter.bat" pub add --dev drift_dev:^2.34.5 build_runner:^2.15.2
```

Commit `pubspec.lock`; do not use floating `any` constraints.

- [ ] **Step 4: Export and verify the Flutter schema asset**

Run:

```powershell
conda run -n ustc_assistant python -m ustc_assistant.contracts.schema_export --output app/assets/schemas/source-bundle-1.0.draft7.schema.json
```

Add a Python test that regenerates it in memory and compares exact normalized
JSON so manual edits fail CI.

- [ ] **Step 5: Replace the counter test with a package smoke test**

```dart
testWidgets('application package starts', (tester) async {
  await tester.pumpWidget(const MyApp());
  expect(find.byType(MaterialApp), findsOneWidget);
});
```

- [ ] **Step 6: Run format, analyze, and test**

```powershell
& "$env:Flutter_Path\dart.bat" format --output=none --set-exit-if-changed lib test
& "$env:Flutter_Path\flutter.bat" analyze
& "$env:Flutter_Path\flutter.bat" test
```

- [ ] **Step 7: Commit**

```powershell
git add app .gitignore AGENTS.md README.md tests/contracts
git commit -m "build: scaffold Flutter application"
```

### Task 10: Account, Source, Import, and Operation Drift Tables

**Files:**
- Create: `app/lib/core/database/app_database.dart`
- Create: `app/lib/core/database/connection.dart`
- Create: `app/lib/core/database/tables/account_tables.dart`
- Create: `app/lib/core/database/tables/source_tables.dart`
- Create: `app/lib/core/database/tables/operation_tables.dart`
- Create: `app/test/core/database/account_source_schema_test.dart`

**Interfaces:**
- Produces: `AppDatabase(QueryExecutor executor)`
- Produces tables: `local_accounts`, `credential_accounts`, `source_configs`, `import_batches`, `source_records`, `sync_runs`, `action_logs`, `agent_permission_policies`
- Uses account UUID text and UTC epoch-millisecond timestamps.

- [ ] **Step 1: Write failing schema and constraint tests**

```dart
test('source identity is unique inside one account', () async {
  final db = testDatabase();
  await db.into(db.sourceRecords).insert(record(accountId: 'a', externalId: 'x'));
  expect(
    db.into(db.sourceRecords).insert(record(accountId: 'a', externalId: 'x')),
    throwsA(isA<SqliteException>()),
  );
});

test('agent permission table starts empty', () async {
  final db = testDatabase();
  expect(await db.select(db.agentPermissionPolicies).get(), isEmpty);
});
```

Add foreign-key cascade/restrict tests, protected-password nullability,
append-only ActionLog repository behavior, and bundle ID plus digest uniqueness.

- [ ] **Step 2: Run and confirm table imports fail**

Run: `& "$env:Flutter_Path\flutter.bat" test test/core/database/account_source_schema_test.dart`

- [ ] **Step 3: Define the tables and database version 1**

`local_accounts` stores local ID, masked hint, active flag, created/updated
times. `credential_accounts` stores DPAPI blobs and nullable password.
`source_records` stores source identity, local entity reference, source status,
presence, scope key, and observed times. `sync_runs` stores per-source
attempt/success state and redacted code. `action_logs` exposes insert/select
only. The Agent permission table has no seed migration.

- [ ] **Step 4: Generate Drift code and run tests**

```powershell
& "$env:Flutter_Path\dart.bat" run build_runner build --delete-conflicting-outputs
& "$env:Flutter_Path\flutter.bat" test test/core/database/account_source_schema_test.dart
& "$env:Flutter_Path\flutter.bat" analyze
```

- [ ] **Step 5: Commit**

```powershell
git add app/lib/core/database app/test/core/database
git commit -m "feat: add account and source database schema"
```

### Task 11: Schedule and User Data Drift Tables

**Files:**
- Create: `app/lib/core/database/tables/schedule_tables.dart`
- Create: `app/lib/core/database/tables/task_tables.dart`
- Modify: `app/lib/core/database/app_database.dart`
- Create: `app/test/core/database/schedule_task_schema_test.dart`

**Interfaces:**
- Produces tables: `course_series`, `calendar_events`, `calendar_event_series`, `calendar_event_occurrence_exceptions`, `user_overlays`, `schedule_relations`, `schedule_relation_rules`, `task_event_links`, `tasks`, `plan_blocks`, `reminders`, `undo_slot`
- Source-owned records and local records share `calendar_events` but differ by `source` and nullable `externalId`.

- [ ] **Step 1: Write failing relation and invariant tests**

```dart
test('task-event links enforce one relation row per pair', () async {
  final db = seededDatabase();
  await db.into(db.taskEventLinks).insert(link(taskId: 't1', eventId: 'e1'));
  expect(
    db.into(db.taskEventLinks).insert(link(taskId: 't1', eventId: 'e1')),
    throwsA(isA<SqliteException>()),
  );
});

test('undo slot contains at most one row', () async {
  final db = testDatabase();
  await db.replaceUndoSlot(commandId: 'one', payload: '{}');
  await db.replaceUndoSlot(commandId: 'two', payload: '{}');
  expect((await db.select(db.undoSlot).get()).single.commandId, 'two');
});
```

Add timed/all-day exclusivity, end-after-start, Task terminal timestamp,
PlanBlock parent, relation pair uniqueness, structured current-and-future
relation-rule identity/effective-date uniqueness, nullable `effectiveThrough`
constraints, occurrence exception identity, Reminder target, and
account-partition tests.

- [ ] **Step 2: Run and confirm failures**

Run: `& "$env:Flutter_Path\flutter.bat" test test/core/database/schedule_task_schema_test.dart`

- [ ] **Step 3: Define exact first-milestone columns**

Use the MVP fields from `docs/schedule-data-model.md`, replacing `userId` with
`accountId`, adding Task `description` and `userNotes`, and representing Task
relations only in `task_event_links`. Store enum values as checked text columns,
sets/tags as normalized JSON arrays, and occurrence override payloads as
versioned JSON with explicit overridden-field names. Persist
`ScheduleRelationRule` in the structured `schedule_relation_rules` table with
typed series references, required `effectiveFrom`, and nullable
`effectiveThrough`. The exact two stable series identities bound the rule;
when either series has a finite end, `effectiveThrough` is the earliest finite
end, otherwise it is null. Never hide current-and-future conflict
classification in JSON or reduce it to occurrence-only `schedule_relations`.

- [ ] **Step 4: Generate, test all database files, and commit**

```powershell
& "$env:Flutter_Path\dart.bat" run build_runner build --delete-conflicting-outputs
& "$env:Flutter_Path\flutter.bat" test test/core/database
& "$env:Flutter_Path\flutter.bat" analyze
git add app/lib/core/database app/test/core/database
git commit -m "feat: add schedule and task database schema"
```

### Task 12: Dart SourceBundle Decoder and Semantic Validator

**Files:**
- Create: `app/lib/features/import/domain/source_bundle.dart`
- Create: `app/lib/features/import/domain/source_bundle_error.dart`
- Create: `app/lib/features/import/data/source_bundle_decoder.dart`
- Create: `app/lib/features/import/data/source_bundle_semantics.dart`
- Create: `app/test/features/import/source_bundle_decoder_test.dart`
- Copy positive fixtures into: `app/test/fixtures/source_bundle/positive/`
- Copy negative fixtures into: `app/test/fixtures/source_bundle/negative/`

**Interfaces:**
- Produces: `SourceBundleDecoder.decode(Uint8List bytes) -> SourceBundle`
- Produces: immutable typed envelope and entity values.
- Raises: `SourceBundleError(code, safeMessage)` using contract error codes.

- [ ] **Step 1: Write fixture parity tests**

```dart
for (final name in [
  'jw-with-exam.json',
  'jw-empty-exam.json',
  'young-with-schedule.json',
  'young-empty-window.json',
]) {
  test('$name decodes', () async {
    final bytes = await positiveFixtureBytes(name);
    expect(decoder.decode(bytes).schemaVersion, '1.0');
  });
}

test('error does not echo an external identity', () {
  final bytes = invalidDuplicateFixture();
  expect(
    () => decoder.decode(bytes),
    throwsA(predicate<SourceBundleError>(
      (error) => error.code == 'duplicate_identity' &&
          !error.safeMessage.contains('ustc_jw:'),
    )),
  );
});
```

- [ ] **Step 2: Run and confirm missing decoder**

Run: `& "$env:Flutter_Path\flutter.bat" test test/features/import/source_bundle_decoder_test.dart`

- [ ] **Step 3: Implement size, Draft 7 schema, and strict typed decoding**

Reject input above 16 MiB before `jsonDecode`. Validate the generated Draft 7
asset with `json_schema`, then construct typed values with exhaustive maps and
enums. Unknown fields and enum values remain errors even if a package default
would ignore them.

- [ ] **Step 4: Implement cross-record semantic parity**

Match Python checks for manifest counts, source/scope compatibility, identity,
exactly-one SourceRecord mappings, references, hard limits, complete windows,
`+08:00`, all-day dates, and forbidden sensitive keys. Add mutated negative
fixtures shared with Python, keeping every rejection fixture under the
dedicated negative fixture directory.

- [ ] **Step 5: Run Dart and Python contract suites, then commit**

```powershell
& "$env:Flutter_Path\flutter.bat" test test/features/import/source_bundle_decoder_test.dart
conda run -n ustc_assistant python -m unittest tests.contracts -v
git add app/lib/features/import app/test/features/import app/test/fixtures tests/fixtures/source-bundle
git commit -m "feat: decode SourceBundle contracts in Flutter"
```

### Task 13: Transactional Flutter ImportService

**Files:**
- Create: `app/lib/features/import/application/import_service.dart`
- Create: `app/lib/features/import/application/reminder_reconciler.dart`
- Create: `app/lib/features/import/data/import_repository.dart`
- Create: `app/lib/features/import/domain/import_result.dart`
- Create: `app/test/features/import/import_service_test.dart`

**Interfaces:**
- Produces: `Future<ImportResult> ImportService.importBytes(Uint8List bytes, {required String accountId, required ImportOrigin origin})`
- Consumes: `SourceBundleDecoder`, `AppDatabase`, stable post-commit `ReminderReconciler` port
- Guarantees: one Bundle equals one Drift transaction.

- [ ] **Step 1: Write failing transaction tests**

```dart
test('reimport is idempotent and preserves overlay', () async {
  await service.importBytes(jwBytes, accountId: 'acct', origin: ImportOrigin.file);
  await overlayRepo.setNotes(eventId, '保留这条备注');
  await service.importBytes(jwBytes, accountId: 'acct', origin: ImportOrigin.file);
  expect(await eventCount(), expectedEventCount);
  expect((await overlayRepo.forEvent(eventId)).notes, '保留这条备注');
});

test('bundle failure rolls back every row', () async {
  expect(
    service.importBytes(danglingBytes, accountId: 'acct', origin: ImportOrigin.file),
    throwsA(isA<SourceBundleError>()),
  );
  expect(await eventCount(), 0);
});
```

Add tests for bundle replay, same ID/different digest, new ID/same content,
subject mismatch, `observed`, `missing_within_scope`, `outside_scope`,
reappearance, explicit cancellation, independent source success, the default
no-op reconciler, and a fake reconciler receiving only committed imports.

- [ ] **Step 2: Run and confirm missing service**

Run: `& "$env:Flutter_Path\flutter.bat" test test/features/import/import_service_test.dart`

- [ ] **Step 3: Implement external-identity upsert and reference resolution**

Resolve local IDs inside the transaction. Update only source-owned fields.
Compute presence only within the declared account/source/scope. Write
`import_batches`, `sync_runs`, and a redacted `action_logs` row in the same
transaction.

- [ ] **Step 4: Trigger Reminder reconciliation only after commit**

Define the stable `ReminderReconciler` port and a no-op/default implementation
in this task so ImportService has no dependency on the later Windows adapter.
Expose a fake reconciler in tests. A reminder error updates retryable reminder
state but does not roll back imported events. Task 25 supplies the Windows
reminder implementation of this port.

- [ ] **Step 5: Run database/import tests and commit**

```powershell
& "$env:Flutter_Path\flutter.bat" test test/core/database test/features/import
& "$env:Flutter_Path\flutter.bat" analyze
git add app/lib/features/import app/test/features/import
git commit -m "feat: import complete source bundles transactionally"
```

### Task 14: App Shell, Routing, and Disabled Chat

**Files:**
- Create: `app/lib/app/app.dart`
- Create: `app/lib/app/router.dart`
- Create: `app/lib/app/theme.dart`
- Create: `app/lib/app/app_drawer.dart`
- Create: `app/lib/features/chat/presentation/chat_shell_page.dart`
- Create: `app/lib/features/settings/presentation/official_websites_page.dart`
- Create: `app/lib/features/schedule/presentation/schedule_page.dart`
- Create: `app/lib/features/tasks/presentation/task_center_page.dart`
- Modify: `app/lib/main.dart`
- Create: `app/test/app/app_shell_test.dart`

**Interfaces:**
- Bottom destinations: Chat and Schedule only.
- Schedule internal destinations: Week and Tasks.
- Drawer routes: Accounts, Sync, History, Settings, Official Websites.

- [ ] **Step 1: Write failing navigation tests**

```dart
testWidgets('bottom navigation has exactly chat and schedule', (tester) async {
  await tester.pumpWidget(testApp());
  expect(find.text('聊天'), findsOneWidget);
  expect(find.text('日程'), findsOneWidget);
  expect(find.byType(NavigationDestination), findsNWidgets(2));
});

testWidgets('chat composer is disabled without fake messages', (tester) async {
  await tester.pumpWidget(testApp());
  expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
  expect(find.text('智能体尚未接入'), findsOneWidget);
});

testWidgets('official website page exposes only allowlisted HTTPS targets', (tester) async {
  await tester.pumpWidget(testApp());
  await openDrawerRoute(tester, '学校官方网站');
  expect(find.text('教务系统'), findsOneWidget);
  expect(fakeLauncher.launched, isEmpty);
  await tester.tap(find.text('教务系统'));
  expect(fakeLauncher.launched.single.host, 'jw.ustc.edu.cn');
});
```

- [ ] **Step 2: Run and confirm missing shell**

Run: `& "$env:Flutter_Path\flutter.bat" test test/app/app_shell_test.dart`

- [ ] **Step 3: Implement GoRouter shell and responsive navigation**

Use `StatefulShellRoute` for the two bottom destinations. Preserve selected week
and scroll state in Schedule. Use Material 3, Lucide-equivalent Material icons
already in Flutter, tooltips on unfamiliar icon buttons, cards at no more than
8 px radius, and no nested cards or marketing hero.

The official-websites page uses fixed HTTPS `Uri` constants for JW, registered
second-classroom, teaching affairs, and finance. It opens them through
`url_launcher` and never accepts a URL from Bridge, imported data, or user text.

- [ ] **Step 4: Implement disabled Chat and Schedule tabs**

Chat has message canvas and disabled composer but no database/provider for
messages. Schedule uses a two-option tab/segmented control for `周视图 | 任务`.

- [ ] **Step 5: Run widget tests, analyze, and commit**

```powershell
& "$env:Flutter_Path\flutter.bat" test test/app
& "$env:Flutter_Path\flutter.bat" analyze
git add app/lib/app app/lib/features/chat app/lib/features/settings/presentation/official_websites_page.dart app/lib/features/schedule/presentation app/lib/features/tasks/presentation app/lib/main.dart app/test/app
git commit -m "feat: add Flutter application shell"
```

### Task 15: Seven-Day Schedule Projection Engine

**Files:**
- Create: `app/lib/core/time/beijing_clock.dart`
- Create: `app/lib/features/schedule/domain/week_range.dart`
- Create: `app/lib/features/schedule/domain/ustc_periods.dart`
- Create: `app/lib/features/schedule/domain/schedule_projection.dart`
- Create: `app/lib/features/schedule/domain/overlap_engine.dart`
- Create: `app/lib/features/schedule/domain/course_color.dart`
- Create: `app/test/features/schedule/schedule_projection_test.dart`

**Interfaces:**
- Produces: `WeekRange.forDate(DateTime beijingDate)`
- Produces: `ScheduleProjection buildWeek(ScheduleQuery query)`
- Produces: `List<OverlapGroup> groupOverlaps(List<EffectiveEvent>)`
- Produces deterministic course-series color.

- [ ] **Step 1: Write failing geometry and identity tests**

```dart
test('week always spans Monday through Sunday', () {
  final week = WeekRange.forDate(DateTime(2026, 7, 26));
  expect(week.days.length, 7);
  expect(week.days.first.weekday, DateTime.monday);
  expect(week.days.last.weekday, DateTime.sunday);
});

test('overlap does not imply conflict', () {
  final projection = buildProjection([event(9, 0, 10, 0), event(9, 30, 11, 0)]);
  expect(projection.overlapGroups.single.events.length, 2);
  expect(projection.overlapGroups.single.hasConfirmedConflict, isFalse);
});
```

Add official-period boundary, real-minute geometry, stable colors, foreground
priority, deterministic ties, all-day spans, and odd/even inactive preview
tests using imported `weekIndex` occurrences.

- [ ] **Step 2: Run and confirm missing domain files**

Run: `& "$env:Flutter_Path\flutter.bat" test test/features/schedule/schedule_projection_test.dart`

- [ ] **Step 3: Implement pure deterministic projection**

Keep no Flutter widgets in this layer. Course periods form horizontal guides;
event top/height use actual minute offsets. Derive inactive previews from the
CourseSeries' semester occurrences and week indices; exclude previews from
overlap and reminders.

- [ ] **Step 4: Run projection tests and commit**

```powershell
& "$env:Flutter_Path\flutter.bat" test test/features/schedule/schedule_projection_test.dart
git add app/lib/core/time app/lib/features/schedule/domain app/test/features/schedule
git commit -m "feat: project seven-day schedules"
```

### Task 16: Weekly Timetable and Overlap Interaction

**Files:**
- Create: `app/lib/features/schedule/presentation/week_timetable.dart`
- Create: `app/lib/features/schedule/presentation/time_axis.dart`
- Create: `app/lib/features/schedule/presentation/event_block.dart`
- Create: `app/lib/features/schedule/presentation/overlap_expansion.dart`
- Create: `app/lib/features/schedule/presentation/all_day_band.dart`
- Modify: `app/lib/features/schedule/presentation/schedule_page.dart`
- Create: `app/test/features/schedule/week_timetable_test.dart`

**Interfaces:**
- Consumes: `ScheduleProjection`
- Emits: event selection, overlap expansion, week navigation, empty-range creation.

- [ ] **Step 1: Write failing widget tests**

```dart
testWidgets('Saturday and Sunday remain reachable on phone width', (tester) async {
  tester.view.physicalSize = const Size(390, 844);
  await tester.pumpWidget(timetableFixture(withSeededSundayEvent: true));
  await tester.drag(find.byType(Scrollable).first, const Offset(-1200, 0));
  await tester.pumpAndSettle();
  expect(find.text('周日').hitTestable(), findsOneWidget);
  expect(find.byKey(const Key('event-sunday')).hitTestable(), findsOneWidget);
});

testWidgets('first overlap tap expands and second opens detail', (tester) async {
  await tester.pumpWidget(overlapFixture());
  await tester.tap(find.byKey(const Key('overlap-group-g1')));
  await tester.pumpAndSettle();
  expect(find.byType(OverlapExpansion), findsOneWidget);
  await tester.tap(find.text('量子物理 B'));
  expect(find.byKey(const Key('event-detail')), findsOneWidget);
});
```

Add foreground translucency, background blur/offset, `+N`, confirmed-conflict
semantics, inactive preview, title/location priority, all-day three-row cap,
and layout-stability tests.

- [ ] **Step 2: Run and confirm failures**

Run: `& "$env:Flutter_Path\flutter.bat" test test/features/schedule/week_timetable_test.dart`

- [ ] **Step 3: Implement responsive fixed-geometry timetable**

Windows displays seven columns together when width permits. Narrow widths use
horizontal scrolling without hiding weekends. Use stable constraints so labels,
warnings, and hover states never resize the grid.

- [ ] **Step 4: Run widget tests and commit**

```powershell
& "$env:Flutter_Path\flutter.bat" test test/features/schedule
& "$env:Flutter_Path\flutter.bat" analyze
git add app/lib/features/schedule/presentation app/test/features/schedule
git commit -m "feat: render interactive weekly timetable"
```

### Task 17: UserOverlay, Event Detail, and Conflict Classification

**Files:**
- Create: `app/lib/features/schedule/application/effective_event_repository.dart`
- Create: `app/lib/features/schedule/application/overlay_service.dart`
- Create: `app/lib/features/schedule/application/conflict_service.dart`
- Create: `app/lib/features/schedule/presentation/event_detail_page.dart`
- Create: `app/lib/features/schedule/presentation/conflict_editor.dart`
- Create: `app/test/features/schedule/overlay_conflict_test.dart`

**Interfaces:**
- Produces: `EffectiveEvent = event overlay > series overlay > source default`
- Produces: `setEventOverlay`, `setSeriesOverlay`, `recordAttendanceDecision`, `recordAttendanceOutcome`, `classifyPair`, `setForegroundPreference`
- Conflict states: `unclassified`, `conflict`, `non_conflict`.
- Conflict scopes: one occurrence or compatible current-and-future occurrences.

- [ ] **Step 1: Write failing precedence and classification tests**

```dart
test('event overlay wins over series and source defaults', () async {
  await service.setSeriesAttendance(seriesId, AttendancePolicy.skip);
  await service.setEventAttendance(eventId, AttendancePolicy.mustGo);
  expect((await repository.byId(eventId)).attendance, AttendancePolicy.mustGo);
});

test('only explicit conflict gets warning semantics', () async {
  await conflictService.classifyPair(a, b, ConflictState.nonConflict);
  expect((await repository.overlap(a)).showConflictWarning, isFalse);
  await conflictService.classifyPair(a, b, ConflictState.conflict);
  expect((await repository.overlap(a)).showConflictWarning, isTrue);
});

test('attendance decision remains occurrence-specific', () async {
  await overlayService.recordAttendanceDecision(eventA, AttendanceDecision.notGoing);
  expect((await repository.byId(eventA)).attendanceDecision, AttendanceDecision.notGoing);
  expect((await repository.byId(eventB)).attendanceDecision, AttendanceDecision.undecided);
});

test('current-and-future classification persists a structured rule', () async {
  await conflictService.classifyPair(
    a,
    b,
    ConflictState.nonConflict,
    scope: ConflictScope.currentAndFuture,
  );
  final rule = (await relationRuleRows()).single;
  expect(rule.primarySeriesId, a.seriesId);
  expect(rule.relatedSeriesId, b.seriesId);
  expect(rule.effectiveFrom, selectedOccurrenceDate);
  expect(rule.effectiveThrough, isNull);
  expect((await relationRows()).where((row) => row.isSynthetic), isEmpty);
});
```

Add cases proving a finite participant sets `effectiveThrough` to the earliest
finite series end, two unbounded series leave it null, and a missing stable
series identity rejects `currentAndFuture` without writing any rule.

- [ ] **Step 2: Run and confirm missing services**

Run: `& "$env:Flutter_Path\flutter.bat" test test/features/schedule/overlay_conflict_test.dart`

- [ ] **Step 3: Implement transactional services and redacted logs**

Support attendance `must_go/gamble/skip`, listening `listen/not_listen`, notes,
color, foreground preference, occurrence-specific
`going/not_going/undecided` decisions, attendance outcomes, attendance notes,
and listening notes. Pair identities are canonicalized so `(a,b)` and `(b,a)`
cannot duplicate. A current-and-future conflict classification requires exact
stable identities for both participating series and stores them with
`effectiveFrom`. Set nullable `effectiveThrough` to the earliest finite end of
the two series when either has one; leave it null when both series are
unbounded. Reject current-and-future classification when either stable series
identity is unavailable. The rule is not stored as JSON and is not eagerly
expanded into occurrence rows. Task 25 adds reminder-override mutations after
the reminder feature exists.

- [ ] **Step 4: Implement event detail and “处理重叠”**

The overlap editor classifies every pair independently, accepts an optional
reason, and never blocks save merely because a pair remains unclassified.

- [ ] **Step 5: Run tests and commit**

```powershell
& "$env:Flutter_Path\flutter.bat" test test/features/schedule
git add app/lib/features/schedule app/test/features/schedule
git commit -m "feat: preserve overlays and classify conflicts"
```

### Task 18: Personal CalendarEvent CRUD and All-Day Behavior

**Files:**
- Create: `app/lib/features/calendar/domain/personal_event.dart`
- Create: `app/lib/features/calendar/application/calendar_event_service.dart`
- Create: `app/lib/features/calendar/presentation/calendar_event_form.dart`
- Create: `app/lib/features/calendar/presentation/personal_event_management_page.dart`
- Create: `app/test/features/calendar/calendar_event_service_test.dart`
- Create: `app/test/features/calendar/calendar_event_form_test.dart`

**Interfaces:**
- Produces commands for create, edit, complete, skip, reschedule, cancel, hide, soft-delete, restore.
- Time forms are exactly timed or all-day, never both.
- Default completion policy is `auto_after_end`.

- [ ] **Step 1: Write failing domain tests**

```dart
test('timed event requires end after start', () {
  expect(
    () => PersonalEvent.timed(title: 'x', startAt: instant(10), endAt: instant(9)),
    throwsA(isA<CalendarValidationError>()),
  );
});

test('manual event derives awaiting completion after end', () {
  final event = manualEvent(endAt: instant(10));
  expect(event.effectiveState(clockAt(11)).awaitingCompletion, isTrue);
  expect(event.effectiveState(clockAt(11)).status, EventStatus.active);
});
```

Add all-day exclusive end, cross-midnight, automatic derived completion,
hidden/deleted restore, source-owned edit rejection, and ActionLog tests.

- [ ] **Step 2: Run and confirm missing feature**

Run: `& "$env:Flutter_Path\flutter.bat" test test/features/calendar`

- [ ] **Step 3: Implement service and forms**

Creation requires title and one valid time representation. Support the six
personal types, importance, tentative state, completion policy, color, tags,
reminders, and removable Task/event relations. Source-owned fields remain
read-only and use overlays.

- [ ] **Step 4: Connect schedule creation entry points**

Global add offers `Task | Calendar event`; empty timed range prefills one hour;
all-day band prefills one date; detail entry points prefill removable relations.

- [ ] **Step 5: Run tests and commit**

```powershell
& "$env:Flutter_Path\flutter.bat" test test/features/calendar test/features/schedule
git add app/lib/features/calendar app/test/features/calendar app/lib/features/schedule
git commit -m "feat: manage personal calendar events"
```

### Task 19: Personal Recurrence and Occurrence Exceptions

**Files:**
- Create: `app/lib/features/calendar/domain/recurrence_rule.dart`
- Create: `app/lib/features/calendar/domain/recurrence_expander.dart`
- Create: `app/lib/features/calendar/application/recurrence_service.dart`
- Create: `app/lib/features/calendar/presentation/recurrence_editor.dart`
- Create: `app/test/features/calendar/recurrence_test.dart`

**Interfaces:**
- Frequencies: daily, weekly, monthly.
- Edit scopes: `only_this`, `this_and_future`, `whole_series`.
- Expansion limit: 366 days and 1,000 occurrences per query.

- [ ] **Step 1: Write failing recurrence tests**

```dart
test('monthly day 31 clamps and returns to original anchor', () {
  final dates = expand(monthly(anchor: DateTime(2026, 1, 31)), through: DateTime(2026, 3, 31));
  expect(dates, [DateTime(2026, 1, 31), DateTime(2026, 2, 28), DateTime(2026, 3, 31)]);
});

test('moving occurrence keeps original occurrence key', () async {
  final before = occurrenceKey(seriesId, originalStart);
  await service.editOnlyThis(before, startAt: movedStart);
  expect((await service.occurrence(before)).occurrenceKey, before);
});
```

Add interval, multiple weekdays, inclusive end date, deterministic identity,
override-null distinction, split-series migration, orphaned exception, impact
horizon, and transaction rollback tests.

- [ ] **Step 2: Run and confirm missing recurrence layer**

Run: `& "$env:Flutter_Path\flutter.bat" test test/features/calendar/recurrence_test.dart`

- [ ] **Step 3: Implement pure bounded expansion**

Use original local anchor date/time for identity. Never materialize unbounded
history. Monthly clamping retains the original day-of-month anchor.

- [ ] **Step 4: Implement all three edit scopes transactionally**

`only_this` writes an exception. `this_and_future` closes the old series and
creates a new one while migrating compatible future records. `whole_series`
retains exceptions and marks removed positions orphaned.

- [ ] **Step 5: Run tests and commit**

```powershell
& "$env:Flutter_Path\flutter.bat" test test/features/calendar
git add app/lib/features/calendar app/test/features/calendar
git commit -m "feat: support recurring personal events"
```

### Task 20: Task Lifecycle and Derived State

**Files:**
- Create: `app/lib/features/tasks/domain/task.dart`
- Create: `app/lib/features/tasks/domain/task_projection.dart`
- Create: `app/lib/features/tasks/application/undo_recorder.dart`
- Create: `app/lib/features/tasks/application/plan_block_lifecycle_port.dart`
- Create: `app/lib/features/tasks/application/task_lifecycle_service.dart`
- Create: `app/test/features/tasks/task_lifecycle_test.dart`

**Interfaces:**
- Persisted statuses: `active`, `blocked`, `completed`, `cancelled`.
- Derived: planning, deadline, and confirmation states.
- Produces: stable `UndoRecorder` port consumed by reversible mutation services.
- Produces: stable `PlanBlockLifecyclePort` with no-op/default behavior for Task terminal commands.
- No persisted in-progress state, percentage, actual minutes, or automatic status writes.

- [ ] **Step 1: Write failing lifecycle tests**

```dart
test('clock passage changes projection without a database write', () async {
  final before = await actionLogCount();
  expect(project(task, clockAt(deadlineMinusOneMinute)).deadline, DeadlineState.dueToday);
  expect(project(task, clockAt(deadlinePlusOneMinute)).deadline, DeadlineState.overdue);
  expect(await actionLogCount(), before);
});

test('completed task must be reopened before blocking', () async {
  await service.complete(taskId);
  expect(service.block(taskId, reason: '等待材料'), throwsA(isA<IllegalTaskTransition>()));
});
```

Add blocked-reason clearing, terminal timestamps, reopen behavior, no automatic
completion, soft delete, stale command, Task-event link, and fake
`UndoRecorder` invocation tests. Add tests proving Task completion and
cancellation compile and commit with the default no-op
`PlanBlockLifecyclePort`, plus fake-port tests for impact summaries and
post-transition calls.

- [ ] **Step 2: Run and confirm missing lifecycle service**

Run: `& "$env:Flutter_Path\flutter.bat" test test/features/tasks/task_lifecycle_test.dart`

- [ ] **Step 3: Implement command service and projections**

All mutations include expected `updatedAt` for stale-write rejection and append
a redacted ActionLog. Define the stable undo-recording port in this task and
make reversible Task mutations call it only after their business write
succeeds; Task 21 supplies the global one-step implementation. Also define the
stable `PlanBlockLifecyclePort` and a no-op/default implementation in this task,
so completion and cancellation can summarize and update linked future
PlanBlocks without depending on later files. Task 21 supplies the concrete
PlanBlock implementation of this port.

- [ ] **Step 4: Run tests and commit**

```powershell
& "$env:Flutter_Path\flutter.bat" test test/features/tasks/task_lifecycle_test.dart
git add app/lib/features/tasks app/test/features/tasks
git commit -m "feat: implement task lifecycle"
```

### Task 21: PlanBlock Lifecycle and Global One-Step Undo

**Files:**
- Create: `app/lib/features/tasks/domain/plan_block.dart`
- Create: `app/lib/features/tasks/application/plan_block_service.dart`
- Create: `app/lib/features/tasks/application/undo_service.dart`
- Modify: `app/lib/features/tasks/application/task_lifecycle_service.dart`
- Modify: `app/lib/features/calendar/application/calendar_event_service.dart`
- Modify: `app/lib/features/schedule/application/overlay_service.dart`
- Modify: `app/lib/features/schedule/application/conflict_service.dart`
- Create: `app/test/features/tasks/plan_block_undo_test.dart`
- Modify: `app/test/features/tasks/task_lifecycle_test.dart`
- Modify: `app/test/features/calendar/calendar_event_service_test.dart`
- Modify: `app/test/features/schedule/overlay_conflict_test.dart`

**Interfaces:**
- PlanBlock statuses: `suggested`, `accepted`, `done`, `skipped`, `rescheduled`, `cancelled`.
- Produces one global session undo slot for the most recent reversible local command.
- `PlanBlockService` implements Task 20's stable `PlanBlockLifecyclePort`.

- [ ] **Step 1: Write failing PlanBlock and undo tests**

```dart
test('elapsed accepted block awaits review without status write', () async {
  final block = await repo.insert(acceptedBlock(endAt: instant(10)));
  expect(project(block, clockAt(11)).awaitingReview, isTrue);
  expect((await repo.byId(block.id)).status, PlanBlockStatus.accepted);
});

test('new reversible action replaces previous undo', () async {
  await taskService.rename(taskId, 'one');
  await taskService.rename(taskId, 'two');
  await undoService.undo();
  expect((await taskRepo.byId(taskId)).title, 'one');
  expect(await undoService.canUndo(), isFalse);
});
```

Add split, move, resize, lock, done/skipped/rescheduled, atomic replacement,
startup expiry, excluded operations, failure rollback, and original-plus-undo
ActionLog tests. Add one test each proving the same global undo slot reverses a
personal CalendarEvent edit, UserOverlay edit, and conflict-priority edit.

- [ ] **Step 2: Run and confirm missing services**

Run: `& "$env:Flutter_Path\flutter.bat" test test/features/tasks/plan_block_undo_test.dart`

- [ ] **Step 3: Implement PlanBlock transactions**

Reschedule atomically marks the old block and creates a replacement. Task
cancellation cancels future accepted blocks; blocked Task changes none.
Completing all PlanBlocks never completes the Task. Supply the concrete
`PlanBlockLifecyclePort` implementation used by `TaskLifecycleService`.

- [ ] **Step 4: Implement versioned undo commands**

Store minimal before-state and command kind. Clear at normal startup. Do not
allow sync, file import, credentials, browser session clearing, or complete
data clearing in undo. Register reversible commands from Task, PlanBlock,
personal CalendarEvent, UserOverlay, and conflict services that exist by this
task through the Task 20 `UndoRecorder` port with this one `UndoService`; none
of those features owns a private undo stack. Reminder override joins the same
global port when its service is created in Task 25.

- [ ] **Step 5: Run tests and commit**

```powershell
& "$env:Flutter_Path\flutter.bat" test test/features/tasks
& "$env:Flutter_Path\flutter.bat" test test/features/calendar test/features/schedule
git add app/lib/features/tasks app/lib/features/calendar/application/calendar_event_service.dart app/lib/features/schedule/application/overlay_service.dart app/lib/features/schedule/application/conflict_service.dart app/test/features/tasks app/test/features/calendar/calendar_event_service_test.dart app/test/features/schedule/overlay_conflict_test.dart
git commit -m "feat: manage planning blocks and one-step undo"
```

### Task 22: Task Center, Deadline Bands, and Pending Review

**Files:**
- Create: `app/lib/features/tasks/presentation/task_form.dart`
- Create: `app/lib/features/tasks/presentation/task_detail_page.dart`
- Create: `app/lib/features/tasks/presentation/task_filters.dart`
- Create: `app/lib/features/tasks/presentation/pending_review_list.dart`
- Create: `app/lib/features/tasks/presentation/plan_block_editor.dart`
- Modify: `app/lib/features/tasks/presentation/task_center_page.dart`
- Modify: `app/lib/features/schedule/presentation/week_timetable.dart`
- Create: `app/test/features/tasks/task_ui_test.dart`

**Interfaces:**
- Task page filters Active, Blocked, Completed, Cancelled.
- Top pending-review list.
- Week bands: all-day, undated Task, dated deadline, timed grid.

- [ ] **Step 1: Write failing UI tests**

```dart
testWidgets('undated band hides when empty', (tester) async {
  await tester.pumpWidget(scheduleWithTasks([]));
  expect(find.text('未定截止'), findsNothing);
});

testWidgets('due today and overdue use distinct warning semantics', (tester) async {
  await tester.pumpWidget(scheduleWithTasks([dueTodayTask(), overdueTask()]));
  expect(find.bySemanticsLabel('今天截止'), findsOneWidget);
  expect(find.bySemanticsLabel('已逾期'), findsOneWidget);
});
```

Add planned-task retention, completed deadline history, hide-completed filter,
pending review actions, two-stage Task completion, future-block summary, form
validation, toolbar undo, soft-deleted Task restore, and high-contrast label
tests.

- [ ] **Step 2: Run and confirm UI failures**

Run: `& "$env:Flutter_Path\flutter.bat" test test/features/tasks/task_ui_test.dart`

- [ ] **Step 3: Implement Task and planning workflows**

Task requires only title; description, deadline, estimate, priority, relations,
tags, notes, and reminder override remain optional. Planning uses form-based
date/start/duration everywhere, with drag/resize as a Windows shortcut.

- [ ] **Step 4: Implement deadline bands and review queue**

Undated Tasks span every selected week while incomplete. Dated Tasks align to
deadline dates; incomplete overdue Tasks appear in the current week. Due-today
uses yellow and overdue uses red, each with text and circled-exclamation
semantics. No daily due/overdue notification is created.

- [ ] **Step 5: Run task/schedule tests and commit**

```powershell
& "$env:Flutter_Path\flutter.bat" test test/features/tasks test/features/schedule
git add app/lib/features/tasks app/lib/features/schedule app/test/features/tasks
git commit -m "feat: add task planning interface"
```

### Task 23: Windows DPAPI and School Account Partitions

**Files:**
- Create: `app/lib/core/security/credential_protector.dart`
- Create: `app/lib/core/security/windows_dpapi_protector.dart`
- Create: `app/lib/features/accounts/application/account_service.dart`
- Create: `app/lib/features/accounts/presentation/accounts_page.dart`
- Create: `app/test/core/security/windows_dpapi_protector_test.dart`
- Create: `app/test/features/accounts/account_service_test.dart`

**Interfaces:**
- `protect(Uint8List plaintext) -> Future<ProtectedSecret>`
- `unprotect(ProtectedSecret blob) -> Future<Uint8List>`
- `deleteCredentials(accountId)`
- One active local account, multiple preserved account partitions.

- [ ] **Step 1: Write failing protector and partition tests**

```dart
test('DPAPI round trip does not persist plaintext', () async {
  final protected = await protector.protect(utf8.encode('PB00000000'));
  expect(utf8.decode(protected.bytes, allowMalformed: true), isNot(contains('PB00000000')));
  expect(utf8.decode(await protector.unprotect(protected)), 'PB00000000');
});

test('switching account preserves the old partition', () async {
  await service.activateSchoolAccount('first');
  await seedEvent(accountId: service.activeId, title: '旧课表');
  await service.activateSchoolAccount('second');
  expect(await eventsFor(service.activeId), isEmpty);
  expect(await eventsFor(service.accountIdFor('first')), hasLength(1));
});

test('password is stored only after successful school login', () async {
  await service.stageLogin(username: 'PB00000000', password: 'secret');
  expect(await credentialRows(), isEmpty);
  await service.confirmSuccessfulLogin();
  expect((await credentialRows()).single.protectedPassword, isNotNull);
});

test('first login keeps a provisional account out of SQLite', () async {
  final provisional = await service.beginFirstLogin();
  expect(provisional.accountId, isNotEmpty);
  expect(await localAccountRows(), isEmpty);
  await service.cancelFirstLogin(provisional);
  expect(await localAccountRows(), isEmpty);
});

test('copied SQLite contains no credential plaintext', () async {
  await service.persistVerifiedAccount(
    username: 'PB00000000',
    password: 'adversarial-secret',
  );
  final bytes = await copyDatabaseBytes();
  expect(databaseBytesContainUtf8(bytes, 'PB00000000'), isFalse);
  expect(databaseBytesContainUtf8(bytes, 'adversarial-secret'), isFalse);
});
```

Keep a Windows-only platform test that exercises the real current-user DPAPI
adapter, in addition to portable fake-protector tests.

- [ ] **Step 2: Run tests and confirm missing adapter**

Run: `& "$env:Flutter_Path\flutter.bat" test test/core/security test/features/accounts`

- [ ] **Step 3: Implement current-user DPAPI**

Use `CryptProtectData` and `CryptUnprotectData` from `package:win32` with no
`CRYPTPROTECT_LOCAL_MACHINE`. Zero native buffers in `finally` blocks. Store
scheme/version metadata and never log Win32 input or protected bytes.

- [ ] **Step 4: Implement account binding and UI**

Account username is always protected; password remains nullable and opt-in.
Show only masked hint, saved-password flag, source connection states, active
account, login again, switch, delete credentials, and clear browser session.
Each destructive action has its own confirmation. Stage plaintext only in
memory during login and persist protected material only after the Bridge reports
successful authentication for the expected school account. First login creates
an in-memory provisional random `accountId`; no account or credential row is
persisted until school identity verification succeeds, and failure or
cancellation discards the provisional identity.

- [ ] **Step 5: Run tests and commit**

```powershell
& "$env:Flutter_Path\flutter.bat" test test/core/security test/features/accounts
git add app/lib/core/security app/lib/features/accounts app/test/core/security app/test/features/accounts
git commit -m "feat: protect and partition school accounts"
```

### Task 24: Flutter Bridge Client, SyncCoordinator, and File Import

**Files:**
- Create: `app/lib/features/sync/data/python_locator.dart`
- Create: `app/lib/features/sync/data/bridge_client.dart`
- Create: `app/lib/features/sync/domain/sync_state.dart`
- Create: `app/lib/features/sync/application/sync_coordinator.dart`
- Create: `app/lib/features/sync/presentation/sync_page.dart`
- Create: `app/lib/features/import/presentation/file_import_action.dart`
- Modify: `app/lib/features/accounts/application/account_service.dart`
- Create: `app/test/features/sync/bridge_client_test.dart`
- Create: `app/test/features/sync/sync_coordinator_test.dart`
- Modify: `app/test/features/accounts/account_service_test.dart`
- Create: `app/test/features/import/file_import_action_test.dart`

**Interfaces:**
- Starts `python -m ustc_assistant.bridge`, reads one handshake line, and authenticates every request.
- Per-source freshness: due at 12 hours, retry backoff 1 hour.
- Manual sync bypasses freshness/backoff.

- [ ] **Step 1: Write failing fake-process and fake-HTTP tests**

```dart
test('token never appears in process arguments or action log', () async {
  final client = await startWithFakeHandshake(token: 'secret-token');
  expect(fakeProcess.arguments.join(' '), isNot(contains('secret-token')));
  expect((await actionLogs()).join(), isNot(contains('secret-token')));
});

test('manual sync bypasses automatic backoff', () async {
  await coordinator.recordFailure(Source.jw, at: clock.now());
  expect(coordinator.isAutomaticDue(Source.jw), isFalse);
  expect(await coordinator.sync(Source.jw, trigger: SyncTrigger.manual), isA<SyncStarted>());
});
```

Add invalid handshake, protocol mismatch, parent shutdown, event polling,
cancel, user-login pause/resume, account mismatch, source-independent result,
interrupted-run recovery, file subject mismatch, `Sync all` sequential order,
capability-to-`source_configs` persistence, per-sync username verification,
password-decryption gating, provisional first-login success/failure/cancellation,
and explicit file-target confirmation tests.

- [ ] **Step 2: Run and confirm missing sync/import orchestration**

Run: `& "$env:Flutter_Path\flutter.bat" test test/features/sync test/features/import test/features/accounts`

- [ ] **Step 3: Implement Python location and Bridge lifecycle**

Resolution order is saved executable path, active matching Conda executable,
then `conda run -n ustc_assistant python -c "import sys; print(sys.executable)"`.
Verify the selected interpreter can import `ustc_assistant.bridge` before
saving it.

- [ ] **Step 4: Implement sync orchestration**

Render local data first. Serialize source jobs. Import only terminal complete
bundles. Every sync may decrypt the school username briefly in memory for local
session/account verification; it never enters logs or SourceBundle. Decrypt the
password only after the Bridge reports `needs_user_action` and the user chooses
to continue, then call resume. For first login, send an in-memory provisional
random `accountId`, persist the verified account and import its Bundle only
after school identity verification, and discard the provisional identity on
failure or cancellation. Keep old data and last-success time on failure. On
Bridge startup, persist its shared JW capability as the default source
configuration. A development override must replace the complete
ID/key/display-name triple and is sent explicitly on each JW request.

- [ ] **Step 5: Implement file import through the same ImportService**

Use `file_selector` for one JSON file, enforce 16 MiB before reading, require
the user to confirm a target account, and require the Bundle subject to match
that confirmed account. The active account may be preselected but is never
silently accepted as the target. Never update freshness from an invalid file.

- [ ] **Step 6: Run Flutter and Bridge tests, then commit**

```powershell
& "$env:Flutter_Path\flutter.bat" test test/features/sync test/features/import test/features/accounts
conda run -n ustc_assistant python -m unittest tests.bridge -v
git add app/lib/features/sync app/lib/features/import/presentation app/lib/features/accounts/application/account_service.dart app/test/features/sync app/test/features/import app/test/features/accounts/account_service_test.dart
git commit -m "feat: synchronize Flutter through Python Bridge"
```

### Task 25: Reminder Engine and Process-Lifetime Windows Notifications

**Files:**
- Create: `app/lib/features/reminders/domain/reminder_rule.dart`
- Create: `app/lib/features/reminders/application/reminder_service.dart`
- Create: `app/lib/features/reminders/application/reminder_override_service.dart`
- Create: `app/lib/features/reminders/application/windows_reminder_reconciler.dart`
- Create: `app/lib/features/reminders/data/foreground_notification_adapter.dart`
- Modify: `app/lib/app/app.dart`
- Create: `app/test/features/reminders/reminder_service_test.dart`
- Create: `app/test/features/reminders/reminder_override_undo_test.dart`
- Create: `app/test/features/reminders/foreground_notification_test.dart`

**Interfaces:**
- Computes persisted Reminder records from source defaults and overlays.
- Reminder override mutations consume Task 20's existing `UndoRecorder` port.
- Supplies the Windows implementation of Task 13's stable `ReminderReconciler` port.
- Emits Windows toast only while App process is running.
- Never claims closed-App delivery/cancellation.

- [ ] **Step 1: Write failing default and invalidation tests**

```dart
test('default reminder offsets match the product contract', () {
  expect(defaults.forType(EventType.exam), [const Duration(hours: 24), const Duration(hours: 2)]);
  expect(defaults.forType(EventType.secondClass), [const Duration(hours: 2)]);
  expect(defaults.forPlanBlock(), [const Duration(minutes: 10)]);
});

test('daily due and overdue task reminders are absent', () {
  expect(service.expand(overdueTask()), isNot(contains(isDailyReminder)));
});
```

Add course/personal 15-minute, all-day none, override, type-disable,
reschedule, completion/cancellation/hide invalidation, restart reconciliation,
and foreground adapter failure tests. For Tasks, use parameterized Beijing
deadlines across ordinary, month-boundary, and year-boundary dates and assert
the exact trigger-instant set for the 24-hour and 2-hour offsets, plus the exact
empty set when no deadline or a terminal state suppresses reminders.
Add tests proving a reminder override records through the existing global
`UndoRecorder`, replaces the same one-step undo slot used by earlier mutation
services, and rolls back both the override and its Reminder reconciliation
atomically on undo failure.

- [ ] **Step 2: Run and confirm missing reminder engine**

Run: `& "$env:Flutter_Path\flutter.bat" test test/features/reminders`

- [ ] **Step 3: Implement deterministic records and in-App projection**

Compute all trigger instants with injected Beijing Clock. Persist desired,
delivered, cancelled, missed, and failed states. On startup, mark elapsed
undelivered process-lifetime reminders as missed and expose them in-App; do not
emit a burst of stale Windows toasts. Create `ReminderOverrideService` here and
wire its reversible mutations to Task 20's `UndoRecorder`; do not create a
feature-local undo stack.

- [ ] **Step 4: Implement the running-process notification adapter**

Use `flutter_local_notifications` for immediate toast delivery when an active
timer reaches its trigger. Cancel and rebuild timers from persisted records on
business changes. Surface adapter unavailable/disabled without corrupting the
Reminder row. Wire this adapter-backed reconciler as the production
implementation of Task 13's port; retain the no-op implementation for tests and
non-Windows composition.

- [ ] **Step 5: Run tests and commit**

```powershell
& "$env:Flutter_Path\flutter.bat" test test/features/reminders
git add app/lib/features/reminders app/lib/app/app.dart app/test/features/reminders
git commit -m "feat: add deterministic process-lifetime reminders"
```

### Task 26: Operation History, Settings, and Destructive Boundaries

**Files:**
- Create: `app/lib/features/history/presentation/history_page.dart`
- Create: `app/lib/features/history/application/history_repository.dart`
- Create: `app/lib/features/settings/presentation/settings_page.dart`
- Create: `app/lib/features/settings/application/settings_service.dart`
- Create: `app/test/features/history/history_test.dart`
- Create: `app/test/features/settings/settings_test.dart`

**Interfaces:**
- History filters by time, source, action type, and result.
- Settings cover auto sync, source toggles, Python path, reminder defaults, storage/cache, credentials, browser sessions, and business data.

- [ ] **Step 1: Write failing redaction and clearing tests**

```dart
test('history never exposes protected or authentication material', () async {
  await seedAdversarialHistory(
    username: 'fine_username',
    password: 'password',
    authorization: 'Bearer secret-token',
  );
  final text = (await repository.query()).map((e) => e.safeSummary).join();
  expect(text, isNotEmpty);
  expect(text, isNot(contains('password')));
  expect(text, isNot(contains('Bearer ')));
  expect(text, isNot(contains('fine_username')));
});

test('clear cache preserves schedules and overlays', () async {
  await settings.clearCache();
  expect(await eventCount(), greaterThan(0));
  expect(await overlayCount(), greaterThan(0));
});
```

Add source-disable history preservation, credentials/browser separation,
business-data confirmation, complete-reset second confirmation, fixed 12-hour
interval, and no Agent permission settings tests. Verify that changing the JW
debug semester requires the complete ID/key/display-name triple and that reset
restores the shared Bridge capability value. Seed non-empty adversarial history
through the real logging boundary and verify every rendered/filterable history
field is sanitized, so an empty result cannot satisfy the privacy test.

- [ ] **Step 2: Run and confirm missing pages/services**

Run: `& "$env:Flutter_Path\flutter.bat" test test/features/history test/features/settings`

- [ ] **Step 3: Implement read-only history and scoped settings commands**

Never render before/after payloads containing complete schedules. Cache,
business data, credentials, and browser profiles are four separate targets.
Turning off a source stops refresh without deleting history.

- [ ] **Step 4: Run tests and commit**

```powershell
& "$env:Flutter_Path\flutter.bat" test test/features/history test/features/settings
git add app/lib/features/history app/lib/features/settings app/test/features/history app/test/features/settings
git commit -m "feat: add operation history and settings"
```

### Task 27: Responsive, Accessibility, Migration, and Integration Gates

**Files:**
- Create: `app/test/goldens/`
- Create: `app/test/integration/first_milestone_flow_test.dart`
- Create: `app/integration_test/windows_smoke_test.dart`
- Create: `app/test/core/database/migration_test.dart`
- Modify: affected presentation files after evidence from tests.

**Interfaces:**
- Golden widths: 1440x900 Windows, 390x844 phone, and 412x915 phone.
- Integration uses fixtures and fake Bridge; no school network.

- [ ] **Step 1: Add failing end-to-end fixture test**

```dart
testWidgets('fixture import survives edit, reimport, and restart', (tester) async {
  final harness = await AppHarness.start();
  await harness.importFixture('jw-with-exam.json');
  await harness.setAttendance(firstCourse, AttendancePolicy.skip);
  await harness.reimportFixture('jw-with-exam.json');
  await harness.restart();
  expect(await harness.attendance(firstCourse), AttendancePolicy.skip);
  expect(await harness.visibleDays(), 7);
});
```

Add independent young failure, task planning/review, personal recurrence,
conflict classification, account switch, undo expiry, and interrupted sync.

- [ ] **Step 2: Add migration and accessibility tests**

Verify schema version 1 creates every table, Agent permission table is empty,
`schedule_relation_rules` has structured identity/effective-date columns
including nullable `effectiveThrough`, foreign keys are on, ActionLog is
retained, warning icons have semantic labels, keyboard focus reaches controls,
and color is never the only state signal.

- [ ] **Step 3: Add and inspect responsive goldens**

Capture Chat, seven-day week, overlap expansion, Task center, deadline bands,
event detail, sync, and settings. Confirm text does not overlap, then scroll the
narrow timetable to Sunday and assert that the Sunday header and seeded Sunday
event are actually visible/reachable. Also confirm timetable dimensions do not
shift and compact panels do not use hero-size text.

- [ ] **Step 4: Run the complete automated gate**

```powershell
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
Push-Location app
& "$env:Flutter_Path\dart.bat" format --output=none --set-exit-if-changed lib test integration_test
& "$env:Flutter_Path\flutter.bat" analyze
& "$env:Flutter_Path\flutter.bat" test
& "$env:Flutter_Path\flutter.bat" test integration_test
& "$env:Flutter_Path\flutter.bat" build windows
Pop-Location
git diff --check
```

- [ ] **Step 5: Commit**

```powershell
git add app/test app/integration_test app/lib
git commit -m "test: verify first milestone workflows"
```

### Task 28: Real Edge Acceptance and Documentation Closure

**Files:**
- Create: `docs/acceptance/windows-first-milestone.md`
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: affected source docs only when real behavior differs from their current contract.

**Interfaces:**
- Manual acceptance uses active local account, dedicated Edge profile, shared JW default config, and Beijing young window.
- Raw captures remain outside Git.

- [ ] **Step 1: Prepare a redacted acceptance checklist**

Record only date, app/producer versions, source, configured semester triple,
window dates, normalized counts, result code, and yes/no privacy checks. Do not
record account name, student number, course titles, browser path, URLs with
queries, context IDs, cookies, tokens, or raw payloads.

- [ ] **Step 2: Run file-import acceptance first**

Import each of the four canonical fixtures, repeat each import, edit an overlay,
import a new batch, restart App, and verify counts, presence, history, and
overlay persistence. For each file import, confirm its target account
explicitly and verify the active account is only a preselected choice.

- [ ] **Step 3: Run real JW acceptance**

Start manual sync, complete CAS login and CAPTCHA when prompted, collect the
shared `421 / 2026spring / 2026 春季学期` scope, import it, repeat sync, and verify
course/exam completeness plus no sensitive fields in Bundle or logs.

- [ ] **Step 4: Run real registered second-classroom acceptance**

Collect the inclusive Beijing window `[today - 7 days, today + one calendar
month]`, verify checked/empty date counts, import it, and prove records leaving
the next rolling window become `outside_scope` rather than deleted.

- [ ] **Step 5: Run authentication and failure acceptance**

Verify automatic session reuse, `needs_user_action`, visible Edge only after
confirmation, per-sync in-memory username verification, password decryption only
after that confirmation, optional credential fill without CAPTCHA automation,
first-login provisional identity discard on failure/cancellation, Bridge crash
recovery, independent source failure, account mismatch rejection,
credential/browser separation, and copied SQLite containing no plaintext
username or password.

- [ ] **Step 6: Run final automated verification**

Rerun the complete Task 27 automated gate without omitting format,
integration-test, or build checks:

```powershell
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
Push-Location app
& "$env:Flutter_Path\dart.bat" format --output=none --set-exit-if-changed lib test integration_test
& "$env:Flutter_Path\flutter.bat" analyze
& "$env:Flutter_Path\flutter.bat" test
& "$env:Flutter_Path\flutter.bat" test integration_test
& "$env:Flutter_Path\flutter.bat" build windows
Pop-Location
git diff --check
git status --short --branch
```

- [ ] **Step 7: Update current-capability documentation and commit**

Only after real acceptance, change `AGENTS.md` from “Flutter/Bridge not
implemented” to the verified state and record redacted counts. Document that
closed-App Windows notifications and all LLM behavior remain outside this
milestone.

```powershell
git add README.md AGENTS.md docs/acceptance docs/data-sources
git commit -m "docs: record Windows first milestone acceptance"
```
