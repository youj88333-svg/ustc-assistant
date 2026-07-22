# USTC Assistant Project Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the proven data-collection prototypes into one installable, App-ready Python package while preserving all four live collection/query paths and removing duplicated CLIs, tests, fixtures, and historical documentation.

**Architecture:** A single `ustc_assistant` package exposes source services for JW, Young, and iCourse plus one CLI. Browser lifecycle and local output are shared infrastructure; site-specific endpoint, DOM, parsing, matching, and normalization rules remain isolated. Old implementations remain intact until the new package passes automated parity checks and live acceptance.

**Tech Stack:** Python 3.10, Playwright 1.x with Microsoft Edge, Requests 2.x, Beautiful Soup 4.x, standard-library `unittest`, Git.

## Global Constraints

- Work on branch `refactor/project-cleanup`; do not restructure `main` directly.
- Use Conda environment `ustc_assistant` for all Python commands.
- Preserve the four proven capabilities: JW courses and exams, Young open enrolments, Young signed-up schedules, and public iCourse queries.
- Young enrolment and cancellation remain user-only actions on the official site; this package is read-only.
- Preserve Beijing timezone behavior through `ZoneInfo("Asia/Shanghai")`.
- Never print, commit, or place in normalized output passwords, cookies, tokens, CAS tickets, student IDs, `dataId`, context IDs, encrypted request parameters, or complete private source responses.
- Default collection writes normalized output only. Raw output remains opt-in through `--save-raw` and goes under `tmp/private/` with a terminal warning.
- `temp.md`, `tmp/`, browser profiles, caches, and raw files remain ignored by Git.
- Keep old source files and old tests until the matching new source passes automated parity and live acceptance.
- Stop on partial data, changed response contracts, ambiguous page state, or mismatched record counts.
- Do not use `git reset --hard`, force-push, or destructive bulk deletion.
- Do not change the schedule product model, iCourse caching policy, or rolling-window history semantics in this refactor.

## Final File Map

```text
pyproject.toml
README.md
AGENTS.md
src/ustc_assistant/
  __init__.py
  __main__.py
  cli.py
  common/
    __init__.py
    browser.py
    storage.py
  sources/
    __init__.py
    jw/
      __init__.py
      collector.py
      course.py
      exam.py
      service.py
    young/
      __init__.py
      enrolment.py
      schedule.py
    icourse/
      __init__.py
      client.py
      parser.py
      service.py
tests/
  __init__.py
  test_cli.py
  fixtures/
    jw/course-datum.json
    jw/exam-page.html
    jw/import-bundle.json
    icourse/search.html
    icourse/course.html
    icourse/teacher.html
  jw/
    __init__.py
    test_collector.py
    test_transform.py
  young/
    __init__.py
    test_enrolment.py
    test_schedule.py
  icourse/
    __init__.py
    test_public.py
docs/
  architecture.md
  schedule-data-model.md
  data-sources/jw.md
  data-sources/young.md
  data-sources/icourse.md
```

## Stable Interfaces

The implementation must converge on these public Python interfaces:

```python
# ustc_assistant.common.browser
class CollectionError(RuntimeError): ...
def default_profile_dir() -> Path: ...
def run_in_edge(
    action: Callable[[Any], T],
    *,
    profile_dir: Path | None = None,
    playwright_factory: Callable[[], Any] | None = None,
) -> T: ...

# ustc_assistant.common.storage
def dump_json(path: Path, payload: Any) -> Path: ...
def write_raw_json(raw_dir: Path, filename: str, payload: Any) -> Path: ...
def write_raw_text(raw_dir: Path, filename: str, payload: str) -> Path: ...

# ustc_assistant.sources.jw
def collect_sources(...) -> CollectedSources: ...
def convert_course(data: dict[str, Any], semester_key: str, user_id: str) -> dict[str, Any]: ...
def convert_exam(html_text: str, semester_key: str, user_id: str) -> dict[str, Any]: ...
def build_bundle(course_datum: dict[str, Any], exam_html: str, *, semester_key: str, user_id: str) -> dict[str, Any]: ...
def collect_jw_bundle(...) -> tuple[dict[str, Any], CollectedSources]: ...

# ustc_assistant.sources.young
def collect_enrolments(...) -> CollectedEnrolmentActivities: ...
def normalize_enrolments(collection: CollectedEnrolmentActivities, *, collected_at: str | None = None) -> dict[str, Any]: ...
def collect_enrolment_snapshot(...) -> tuple[dict[str, Any], CollectedEnrolmentActivities]: ...
def collect_schedules(...) -> CollectedSchedules: ...
def normalize_schedules(collection: CollectedSchedules, *, collected_at: str | None = None) -> dict[str, Any]: ...
def collect_schedule_snapshot(...) -> tuple[dict[str, Any], CollectedSchedules]: ...

# ustc_assistant.sources.icourse
class PublicIcourseClient: ...
def group_jw_offerings(bundle: dict[str, Any]) -> list[dict[str, Any]]: ...
def run_query(args: argparse.Namespace, *, client: Any | None = None) -> dict[str, Any]: ...

# ustc_assistant.cli
def build_parser() -> argparse.ArgumentParser: ...
def main(argv: list[str] | None = None) -> int: ...
```

Internal helper names may remain as they are where tests depend on them. Public names above must not drift between tasks.

---

### Task 1: Protect the Baseline and Create the Package Skeleton

**Files:**
- Include: `docs/superpowers/specs/2026-07-22-project-cleanup-design.md`
- Include: `docs/superpowers/plans/2026-07-22-project-cleanup.md`
- Create: `pyproject.toml`
- Create: `src/ustc_assistant/__init__.py`
- Create: `src/ustc_assistant/__main__.py`
- Create: package `__init__.py` files from the final file map
- Create: `tests/test_cli.py`

**Interfaces:**
- Produces an editable Python package importable as `ustc_assistant`.
- Produces `python -m ustc_assistant` delegating to `ustc_assistant.cli.main`.

- [ ] **Step 1: Verify the clean baseline before branching**

Run:

```powershell
conda run -n ustc_assistant python -m unittest discover -s tests -v
git status --short --branch
```

Expected: `Ran 113 tests` and `OK`; only the approved design and plan may be untracked.

- [ ] **Step 2: Create the refactor branch**

Run:

```powershell
git switch -c refactor/project-cleanup
```

Expected: current branch becomes `refactor/project-cleanup`.

- [ ] **Step 3: Write a failing package-entry test**

Create `tests/test_cli.py` with this initial contract:

```python
import unittest

from ustc_assistant import cli


class PackageEntryTests(unittest.TestCase):
    def test_root_parser_exposes_collect_and_query(self):
        parser = cli.build_parser()
        self.assertEqual(parser.parse_args(["collect", "jw"]).command, "collect")
        self.assertEqual(parser.parse_args(["query", "icourse", "--course", "test"]).command, "query")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 4: Run the new test and confirm the package is absent**

Run:

```powershell
conda run -n ustc_assistant python -m unittest tests.test_cli -v
```

Expected: import failure for `ustc_assistant`.

- [ ] **Step 5: Add package metadata and skeleton**

Create `pyproject.toml` with:

```toml
[build-system]
requires = ["setuptools>=68"]
build-backend = "setuptools.build_meta"

[project]
name = "ustc-assistant"
version = "0.1.0"
description = "Local-first USTC campus assistant data collectors"
requires-python = ">=3.10"
dependencies = [
  "playwright>=1.50,<2",
  "requests>=2.31,<3",
  "beautifulsoup4>=4.12,<5",
]

[project.scripts]
ustc-assistant = "ustc_assistant.cli:main"

[tool.setuptools.packages.find]
where = ["src"]
```

Create all package `__init__.py` files as empty ASCII files. Create `src/ustc_assistant/__main__.py`:

```python
from ustc_assistant.cli import main

raise SystemExit(main())
```

Create an initial `src/ustc_assistant/cli.py` whose `build_parser()` defines the final command tree and whose handlers raise a clear `CollectionError("source migration is incomplete")` until later tasks replace them. Do not perform network work at import time.

- [ ] **Step 6: Install editable package and rerun tests**

Run:

```powershell
conda run -n ustc_assistant python -m pip install -e .
conda run -n ustc_assistant python -m unittest tests.test_cli -v
conda run -n ustc_assistant python -m unittest discover -s tests -v
```

Expected: package-entry test passes; all 113 legacy tests still pass.

- [ ] **Step 7: Commit the skeleton and planning artifacts**

```powershell
git add pyproject.toml src tests/test_cli.py docs/superpowers/specs/2026-07-22-project-cleanup-design.md docs/superpowers/plans/2026-07-22-project-cleanup.md
git commit -m "refactor: establish app-ready package skeleton"
```

---

### Task 2: Extract Shared Browser and Storage Infrastructure

**Files:**
- Create: `src/ustc_assistant/common/browser.py`
- Create: `src/ustc_assistant/common/storage.py`
- Modify: `tests/test_cli.py`

**Interfaces:**
- Produces `CollectionError`, `default_profile_dir`, `run_in_edge`, `dump_json`, `write_raw_json`, and `write_raw_text` exactly as listed in Stable Interfaces.
- Does not contain site URLs, DOM selectors, response predicates, or source normalization.

- [ ] **Step 1: Add failing common-layer tests**

Append tests that verify:

```python
def test_dump_json_creates_parent_and_trailing_newline(self):
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "nested" / "value.json"
        returned = storage.dump_json(path, {"text": "课程"})
        self.assertEqual(returned, path)
        self.assertEqual(path.read_text(encoding="utf-8"), '{\n  "text": "课程"\n}\n')

def test_run_in_edge_uses_visible_persistent_edge_and_closes(self):
    fake = FakePlaywrightFactory()
    result = browser.run_in_edge(lambda page: page.marker, playwright_factory=fake)
    self.assertEqual(result, "page")
    self.assertEqual(fake.launch_kwargs["channel"], "msedge")
    self.assertFalse(fake.launch_kwargs["headless"])
    self.assertTrue(fake.context.closed)
```

Reuse the proven fake Playwright shape from existing collector tests rather than inventing a second incompatible fake protocol.

- [ ] **Step 2: Confirm new tests fail for missing common modules**

Run:

```powershell
conda run -n ustc_assistant python -m unittest tests.test_cli -v
```

Expected: missing `common.browser` or `common.storage`.

- [ ] **Step 3: Implement the common modules**

`run_in_edge` must:

```python
profile = Path(profile_dir) if profile_dir is not None else default_profile_dir()
profile.mkdir(parents=True, exist_ok=True)
factory = playwright_factory or sync_playwright
with factory() as playwright:
    context = playwright.chromium.launch_persistent_context(
        str(profile), channel="msedge", headless=False, no_viewport=True
    )
    try:
        page = context.pages[0] if context.pages else context.new_page()
        return action(page)
    finally:
        context.close()
```

It must re-raise `CollectionError` unchanged and convert Playwright errors to `CollectionError("browser automation failed")` without including source exception text.

Storage helpers must create parents, write UTF-8 with `ensure_ascii=False`, use two-space indentation, and add one terminal newline for JSON.

- [ ] **Step 4: Run common and full legacy tests**

```powershell
conda run -n ustc_assistant python -m unittest tests.test_cli -v
conda run -n ustc_assistant python -m unittest discover -s tests -v
```

Expected: new common tests and all legacy tests pass.

- [ ] **Step 5: Commit shared infrastructure**

```powershell
git add src/ustc_assistant/common tests/test_cli.py
git commit -m "refactor: share browser and storage infrastructure"
```

---

### Task 3: Migrate the Complete JW Course and Exam Path

**Files:**
- Create: `src/ustc_assistant/sources/jw/collector.py`
- Create: `src/ustc_assistant/sources/jw/course.py`
- Create: `src/ustc_assistant/sources/jw/exam.py`
- Create: `src/ustc_assistant/sources/jw/service.py`
- Create: `tests/jw/test_collector.py`
- Create: `tests/jw/test_transform.py`
- Copy fixture: `examples/ustc-jw-datum.sample.json` to `tests/fixtures/jw/course-datum.json`
- Copy fixture: `examples/ustc-jw-exam-page.sample.html` to `tests/fixtures/jw/exam-page.html`
- Copy fixture: `examples/ustc-jw-import-bundle.sample.json` to `tests/fixtures/jw/import-bundle.json`

**Interfaces:**
- Consumes common browser and storage interfaces from Task 2.
- Produces JW stable interfaces from the plan header.
- Keeps `CollectedSources(course_datum, exam_html)` immutable.

- [ ] **Step 1: Copy substantive JW tests to the new test package**

Copy all test methods except `test_*_module_exists` from:

```text
tests/test_ustc_jw_collector.py
tests/test_convert_ustc_jw_datum.py
tests/test_convert_ustc_jw_exam_html.py
tests/test_import_ustc_jw.py
tests/test_collect_ustc_jw.py
```

Update imports to:

```python
from ustc_assistant.sources.jw import collector
from ustc_assistant.sources.jw import course
from ustc_assistant.sources.jw import exam
from ustc_assistant.sources.jw import service
```

Add an explicit parity test:

```python
def test_new_jw_bundle_matches_legacy_fixture(self):
    datum = json.loads(COURSE_FIXTURE.read_text(encoding="utf-8"))
    exam_html = EXAM_FIXTURE.read_text(encoding="utf-8")
    actual = service.build_bundle(
        datum, exam_html, semester_key="2026spring", user_id="user_sample"
    )
    expected = json.loads(BUNDLE_FIXTURE.read_text(encoding="utf-8"))
    actual.pop("generatedAt", None)
    expected.pop("generatedAt", None)
    self.assertEqual(actual, expected)
```

- [ ] **Step 2: Confirm new JW tests fail before implementation**

```powershell
conda run -n ustc_assistant python -m unittest discover -s tests/jw -v
```

Expected: imports fail for missing JW modules.

- [ ] **Step 3: Copy course and exam pure logic without behavioral edits**

Copy the implementation bodies from `convert_ustc_jw_datum.py` and `convert_ustc_jw_exam_html.py`. Remove only standalone argument parsing, direct file I/O, and `if __name__ == "__main__"` blocks. Export aliases:

```python
convert_course = convert
convert_exam = convert
```

Preserve teacher merging, `exerciseClass` normalization, collision suffixes, classroom-header aliasing, event identity, source fingerprints, and relation generation exactly.

- [ ] **Step 4: Copy collector logic and delegate only Edge lifecycle**

Copy endpoint predicates, authentication waits, `dataId` parsing, configured-semester requests, exam-page collection, and sanitized errors from `ustc_jw_collector.py`. Replace only the repeated Playwright context wrapper with:

```python
return run_in_edge(
    lambda page: _collect_from_authenticated_context(...),
    profile_dir=profile_dir,
    playwright_factory=playwright_factory,
)
```

- [ ] **Step 5: Implement service aggregation**

Move package validation and duplicate-ID checks from `import_ustc_jw.py`. `build_bundle` must call `convert_course`, `convert_exam`, and `merge_packages`. `collect_jw_bundle` must return both normalized bundle and raw in-memory `CollectedSources` so CLI raw writing remains explicit.

- [ ] **Step 6: Run JW tests and old full suite**

```powershell
conda run -n ustc_assistant python -m unittest discover -s tests/jw -v
conda run -n ustc_assistant python -m unittest discover -s tests -v
```

Expected: all new JW contract tests pass and all 113 legacy tests still pass.

- [ ] **Step 7: Commit JW migration without deleting legacy files**

```powershell
git add src/ustc_assistant/sources/jw tests/jw tests/fixtures/jw
git commit -m "refactor: migrate jw collection and transforms"
```

---

### Task 4: Migrate Young Open-Enrolment Collection

**Files:**
- Create: `src/ustc_assistant/sources/young/enrolment.py`
- Create: `tests/young/test_enrolment.py`

**Interfaces:**
- Produces `collect_enrolments`, `normalize_enrolments`, and `collect_enrolment_snapshot`.
- Preserves front-end-generated encrypted requests; never constructs or logs `requestParams`.

- [ ] **Step 1: Create failing migrated tests**

Copy all substantive methods from `test_ustc_young_collector.py` and `test_collect_ustc_young.py`, excluding module-existence checks. Update imports to `ustc_assistant.sources.young.enrolment`.

Add service composition coverage:

```python
def test_snapshot_collects_then_normalizes(self):
    raw = CollectedEnrolmentActivities(records=(ACTIVITY,), reported_total=1, pages=1)
    normalized, returned = enrolment.collect_enrolment_snapshot(
        collect_fn=lambda **kwargs: raw,
        collected_at="2026-07-22T08:00:00+08:00",
    )
    self.assertIs(returned, raw)
    self.assertEqual(normalized["metadata"]["activityCount"], 1)
    self.assertNotIn("userId", normalized["activities"][0])
```

- [ ] **Step 2: Verify failure before source creation**

```powershell
conda run -n ustc_assistant python -m unittest tests.young.test_enrolment -v
```

Expected: missing Young enrolment module.

- [ ] **Step 3: Merge collector and normalization implementations**

Copy endpoint matching, login recovery, Ant Design pagination, response validation, duplicate checks, and activity count checks from `ustc_young_collector.py`. Copy `NORMALIZED_FIELDS`, normalization, and raw-return behavior from `collect_ustc_young.py`. Remove both old CLI parsers from the new module.

Use `run_in_edge` for browser lifecycle and common storage only at the CLI boundary. Keep status messages free of activity names and IDs.

- [ ] **Step 4: Run Young enrolment and full suites**

```powershell
conda run -n ustc_assistant python -m unittest tests.young.test_enrolment -v
conda run -n ustc_assistant python -m unittest discover -s tests -v
```

Expected: all migrated enrolment behavior and all legacy tests pass.

- [ ] **Step 5: Commit enrolment migration**

```powershell
git add src/ustc_assistant/sources/young/enrolment.py tests/young/test_enrolment.py
git commit -m "refactor: migrate young enrolment collection"
```

---

### Task 5: Migrate Young Signed-Up Schedule Collection

**Files:**
- Create: `src/ustc_assistant/sources/young/schedule.py`
- Create: `tests/young/test_schedule.py`

**Interfaces:**
- Produces `collect_schedules`, `normalize_schedules`, and `collect_schedule_snapshot`.
- Preserves inclusive Beijing window `[today - 7 days, today + one calendar month]`.

- [ ] **Step 1: Create failing migrated schedule tests**

Copy all substantive methods from `test_ustc_young_schedule_collector.py` and `test_collect_ustc_young_schedule.py`, excluding module-existence checks. Update imports to `ustc_assistant.sources.young.schedule`.

Add this explicit privacy assertion:

```python
def test_normalized_snapshot_has_only_public_schedule_fields(self):
    normalized = schedule.normalize_schedules(COLLECTION, collected_at=FIXED_TIME)
    self.assertEqual(
        set(normalized["schedules"][0]),
        {"sourceScheduleId", "sourceActivityId", "title", "startsAt", "endsAt", "location", "descriptionText"},
    )
```

- [ ] **Step 2: Verify failure before source creation**

```powershell
conda run -n ustc_assistant python -m unittest tests.young.test_schedule -v
```

Expected: missing Young schedule module.

- [ ] **Step 3: Merge schedule collector and normalizer**

Copy date arithmetic, localized date-cell selector, response predicate, multi-page rejection, month navigation, per-day response capture, duplicate checks, timezone conversion, HTML-to-text conversion, and output metadata. Remove standalone CLI parsing from the source module.

Use `run_in_edge` for browser lifecycle. Preserve exact distinctions between missing calendar cells and response timeouts.

- [ ] **Step 4: Run schedule and full suites**

```powershell
conda run -n ustc_assistant python -m unittest tests.young.test_schedule -v
conda run -n ustc_assistant python -m unittest discover -s tests -v
```

Expected: all migrated schedule behavior and all legacy tests pass.

- [ ] **Step 5: Commit schedule migration**

```powershell
git add src/ustc_assistant/sources/young/schedule.py tests/young/test_schedule.py
git commit -m "refactor: migrate young schedule collection"
```

---

### Task 6: Migrate Public iCourse Query, Cache, and JW Linking

**Files:**
- Create: `src/ustc_assistant/sources/icourse/client.py`
- Create: `src/ustc_assistant/sources/icourse/parser.py`
- Create: `src/ustc_assistant/sources/icourse/service.py`
- Create: `tests/icourse/test_public.py`
- Copy fixtures under: `tests/fixtures/icourse/`

**Interfaces:**
- Produces `PublicIcourseClient`, parser functions, JW grouping/matching/ranking functions, and `run_query`.
- Reads public content only and preserves the 24-hour cache policy.

- [ ] **Step 1: Create failing consolidated iCourse tests**

Copy every substantive test from the four existing iCourse test files except module-existence tests. Group them into test classes `ParserTests`, `ClientTests`, `CacheTests`, `MatchingTests`, `EvidenceTests`, and `ServiceTests`.

Add this fixture privacy contract:

```python
def test_jw_grouping_does_not_return_private_bundle_fields(self):
    bundle = json.loads(JW_FIXTURE.read_text(encoding="utf-8"))
    groups = service.group_jw_offerings(bundle)
    serialized = json.dumps(groups, ensure_ascii=False)
    self.assertNotIn("local_user", serialized)
    self.assertNotIn("sourceRecords", serialized)
```

- [ ] **Step 2: Confirm missing-module failure**

```powershell
conda run -n ustc_assistant python -m unittest tests.icourse.test_public -v
```

Expected: missing iCourse package modules.

- [ ] **Step 3: Copy parser and client with import-only changes**

Move parser logic without changing selectors or output keys. Move cache and HTTP behavior without changing token refresh, rate-limit handling, stale fallback, schema version checks, cache TTL, or request pacing. Update imports to package-relative imports.

- [ ] **Step 4: Merge query and orchestration into service**

Move JW grouping, teacher-set relation strength, ranking, evidence selection, course query, teacher query, and JW-bundle query into `service.py`. Remove CLI argument parsing and direct output writes from the service.

- [ ] **Step 5: Run iCourse and full suites**

```powershell
conda run -n ustc_assistant python -m unittest tests.icourse.test_public -v
conda run -n ustc_assistant python -m unittest discover -s tests -v
```

Expected: parser, client, cache, matching, ranking, and orchestration tests pass alongside all legacy tests.

- [ ] **Step 6: Commit iCourse migration**

```powershell
git add src/ustc_assistant/sources/icourse tests/icourse tests/fixtures/icourse
git commit -m "refactor: migrate public icourse queries"
```

---

### Task 7: Complete the Unified CLI and Output Policy

**Files:**
- Modify: `src/ustc_assistant/cli.py`
- Modify: `src/ustc_assistant/__main__.py`
- Modify: `tests/test_cli.py`

**Interfaces:**
- Consumes all source service interfaces.
- Produces the four final commands and the console script declared in `pyproject.toml`.

- [ ] **Step 1: Add failing parser and orchestration tests for every command**

Tests must call `main(argv)` with injected service functions or mocks and assert:

```python
self.assertEqual(main(["collect", "jw", "--semester-id", "421"]), 0)
self.assertEqual(main(["collect", "young-enrolment"]), 0)
self.assertEqual(main(["collect", "young-schedule", "--today", "2026-07-22"]), 0)
self.assertEqual(main(["query", "icourse", "--course", "线性代数"]), 0)
```

Also assert nonzero return codes and sanitized stderr for `CollectionError`, `ValueError`, and `OSError`. Assert that raw files are absent by default and appear only with `--save-raw` for the three authenticated collectors.

- [ ] **Step 2: Run CLI tests and confirm incomplete handlers fail**

```powershell
conda run -n ustc_assistant python -m unittest tests.test_cli -v
```

Expected: orchestration tests fail because placeholder handlers do not call source services.

- [ ] **Step 3: Implement the full parser tree and handlers**

Preserve existing defaults:

```text
JW output: tmp/ustc-jw-import.generated.json
Young enrolment output: tmp/ustc-young-enrolment.generated.json
Young schedule output: tmp/ustc-young-my-schedule.generated.json
iCourse output: tmp/icourse-public-query.generated.json
raw directory: tmp/private
login timeout: 300 seconds
JW semester id: 421
JW semester key: 2026spring
local pseudonymous user id: local_user
iCourse cache: tmp/icourse-cache
```

Handlers call source services, then common storage helpers. CLI status messages report counts and paths only, not event/activity/course titles or source identifiers.

- [ ] **Step 4: Verify help and orchestration**

```powershell
conda run -n ustc_assistant python -m ustc_assistant --help
conda run -n ustc_assistant python -m ustc_assistant collect jw --help
conda run -n ustc_assistant python -m ustc_assistant collect young-enrolment --help
conda run -n ustc_assistant python -m ustc_assistant collect young-schedule --help
conda run -n ustc_assistant python -m ustc_assistant query icourse --help
conda run -n ustc_assistant python -m unittest tests.test_cli -v
conda run -n ustc_assistant python -m unittest discover -s tests -v
```

Expected: all help commands exit 0; all new and legacy tests pass.

- [ ] **Step 5: Commit unified CLI**

```powershell
git add src/ustc_assistant/cli.py src/ustc_assistant/__main__.py tests/test_cli.py
git commit -m "refactor: unify collector command line"
```

---

### Task 8: Build Durable Documentation Before Removing History

**Files:**
- Create: `README.md`
- Create: `docs/architecture.md`
- Create: `docs/data-sources/jw.md`
- Create: `docs/data-sources/young.md`
- Create: `docs/data-sources/icourse.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Documentation is the durable reference for App integration after historical design files are removed.
- No document contains real student data, context IDs, tokens, complete private responses, or private review identities.

- [ ] **Step 1: Write README installation and command contracts**

Include exactly these setup and usage commands:

```powershell
conda activate ustc_assistant
python -m pip install -e .
python -m ustc_assistant collect jw
python -m ustc_assistant collect young-enrolment
python -m ustc_assistant collect young-schedule
python -m ustc_assistant query icourse --jw-bundle tmp/ustc-jw-import.generated.json
```

Explain first-login Edge behavior, output paths, `--save-raw`, private local storage, and user-only Young enrolment/cancellation.

- [ ] **Step 2: Write architecture and source documents**

`architecture.md` documents package boundaries, service return values, CLI/App separation, privacy flow, and why site-specific logic stays isolated.

`jw.md` consolidates stable entry URLs, `get-data`, `datum`, dynamic context behavior, exam table behavior, conversion identities, and known teacher/place edge cases.

`young.md` consolidates the enrolment endpoint, front-end pagination, login redirect recovery, schedule endpoint, Beijing query window, Chinese date selector, and snapshot/upsert boundary.

`icourse.md` consolidates public-only scope, token search, 24-hour cache, stale fallback, course/teacher matching, ranking, and representative-review evidence.

- [ ] **Step 3: Replace AGENTS.md progress log with concise operating context**

Retain project purpose, safety constraints, current package map, four live capabilities, verified commands, Beijing timezone, no automatic Young writes, and future App boundaries. Remove chronological debugging narration already captured by Git history and source docs.

- [ ] **Step 4: Scan documentation for sensitive values and stale commands**

Run:

```powershell
rg -n "scripts\\collect_|scripts/collect_|temp\.md|requestParams|X-Access-Token|Cookie|CAS ticket|489951" README.md AGENTS.md docs/architecture.md docs/data-sources
```

Expected: only explanatory security references may match; no old run commands, concrete context IDs, tokens, or private values.

- [ ] **Step 5: Commit durable documentation**

```powershell
git add README.md AGENTS.md docs/architecture.md docs/data-sources
git commit -m "docs: consolidate collector references"
```

---

### Task 9: Run Automated Parity and Privacy Acceptance

**Files:**
- Create temporarily under ignored `tmp/`: parity outputs and logs
- Do not modify tracked source unless a failing test exposes a migration defect

**Interfaces:**
- Establishes evidence that the new package preserves old behavior before live testing.

- [ ] **Step 1: Run the entire combined old-and-new test suite**

```powershell
conda run -n ustc_assistant python -m unittest discover -s tests -v
```

Expected: zero failures. The count will exceed 113 because old and migrated tests coexist.

- [ ] **Step 2: Compile every new package module**

```powershell
conda run -n ustc_assistant python -m compileall -q src tests
```

Expected: exit code 0.

- [ ] **Step 3: Compare deterministic JW fixture outputs**

Run a small `python -c` command importing both legacy and package converters, remove generated timestamps, and assert equality for course conversion, exam conversion, and merged bundle. The command must print only aggregate counts:

```text
JW parity: events=<n>, sources=<n>, relations=<n>
```

Expected: no assertion failure and counts match the fixture.

- [ ] **Step 4: Verify ignored private paths**

```powershell
git check-ignore -v temp.md tmp/private/example.raw.json tmp/icourse-cache/example.json
git status --short
```

Expected: all three paths are ignored; no generated data appears in status.

- [ ] **Step 5: Scan tracked candidates for sensitive data patterns**

```powershell
git grep -n -I -E "X-Access-Token|JSESSIONID|CASTGC|requestParams.*[A-Za-z0-9+/=]{24,}|dataId=[0-9]+|/info/[0-9]{5,}"
```

Expected: no actual secrets or concrete personal context IDs. Documentation may mention field names without values.

- [ ] **Step 6: Stop and fix any failure before live acceptance**

Use systematic debugging for any discrepancy. Do not weaken assertions, discard edge-case tests, or proceed to old-file deletion while a parity/privacy check fails.

---

### Task 10: Perform the Four Live Acceptance Runs

**Files:**
- Generate only ignored output under `tmp/`
- Do not save raw source data during acceptance

**Interfaces:**
- Validates the exact new commands against current external sites.
- This is the only phase that may require the user to complete login or CAPTCHA in Edge.

- [ ] **Step 1: Run live JW collection**

```powershell
conda run -n ustc_assistant python -m ustc_assistant collect jw --semester-id 421 --semester-key 2026spring
```

Expected: Edge opens if needed; normalized bundle is written; terminal reports only event/source/relation counts. Validate required top-level keys, unique IDs, valid timestamps, and absence of `dataId`, context ID, Cookie, and Token keys.

- [ ] **Step 2: Run live Young open-enrolment collection**

```powershell
conda run -n ustc_assistant python -m ustc_assistant collect young-enrolment
```

Expected: login recovery and pagination complete; normalized output count equals metadata count; no user identity or encrypted request parameter is stored.

- [ ] **Step 3: Run live Young signed-up schedule collection**

```powershell
conda run -n ustc_assistant python -m ustc_assistant collect young-schedule
```

Expected: inclusive Beijing window is reported; queried and empty date counts are consistent; every record is in-window, deduplicated, and normalized.

- [ ] **Step 4: Run live iCourse query linked to the new JW bundle**

```powershell
conda run -n ustc_assistant python -m ustc_assistant query icourse --jw-bundle tmp/ustc-jw-import.generated.json
```

Expected: grouped offerings are queried from public pages; output contains public structured statistics, site summary when available, and representative reviews without private JW records.

- [ ] **Step 5: Record aggregate acceptance evidence**

Add only aggregate status and date to `AGENTS.md`: command succeeded, record counts, and any known external-site limitation. Do not record course names, teacher names, activity names, personal IDs, or complete output.

- [ ] **Step 6: Commit acceptance note**

```powershell
git add AGENTS.md
git commit -m "test: record live collector acceptance"
```

If login expires and the user is unavailable, stop here with the branch intact. Do not execute Task 11 until all four live runs succeed.

---

### Task 11: Remove Legacy Implementations, Duplicate Tests, and Historical Files

**Files:**
- Delete: `scripts/`
- Delete: old top-level `tests/test_*.py` except final `tests/test_cli.py`
- Delete: `examples/`
- Delete: `requirements.txt`
- Delete: old JW documents listed below
- Delete: historical `docs/superpowers/plans/` and `docs/superpowers/specs/`, including this plan and its design, after all durable conclusions exist elsewhere

**Interfaces:**
- Leaves only the final package, consolidated tests, durable docs, and fixtures.

- [ ] **Step 1: Verify the live-acceptance commit exists**

```powershell
git log -1 --oneline
```

Expected: latest relevant history includes `test: record live collector acceptance`. If absent, do not delete legacy files.

- [ ] **Step 2: Delete legacy scripts and duplicate top-level tests**

Delete all 13 files under `scripts/`. Delete these legacy tests after confirming every substantive method exists in the consolidated suites:

```text
tests/test_collect_icourse_public.py
tests/test_collect_ustc_jw.py
tests/test_collect_ustc_young.py
tests/test_collect_ustc_young_schedule.py
tests/test_convert_ustc_jw_datum.py
tests/test_convert_ustc_jw_exam_html.py
tests/test_icourse_public_client.py
tests/test_icourse_public_parser.py
tests/test_icourse_public_query.py
tests/test_import_ustc_jw.py
tests/test_ustc_jw_collector.py
tests/test_ustc_young_collector.py
tests/test_ustc_young_schedule_collector.py
```

- [ ] **Step 3: Delete duplicate examples and old dependency file**

Delete `examples/` only after all six required fixtures exist under `tests/fixtures/`. Delete `requirements.txt` because `pyproject.toml` is now the single dependency source.

- [ ] **Step 4: Delete superseded documents**

Delete:

```text
docs/ustc-jw-course-source-template.md
docs/ustc-jw-course-table-integration.md
docs/ustc-jw-course-transform.md
docs/ustc-jw-exam-transform.md
docs/ustc-jw-import-pipeline.md
docs/superpowers/plans/
docs/superpowers/specs/
```

Before deletion, verify every stable source fact is represented in `docs/data-sources/` and every run command is represented in `README.md`.

- [ ] **Step 5: Run final tests after deletion**

```powershell
conda run -n ustc_assistant python -m pip install -e .
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
conda run -n ustc_assistant python -m ustc_assistant --help
```

Expected: zero failures, compile exit 0, and CLI help exit 0 without any `scripts/` directory.

- [ ] **Step 6: Verify no stale references remain**

```powershell
rg -n "scripts[\\/]|requirements\.txt|examples[\\/]|convert_ustc|collect_ustc|collect_icourse|import_ustc" README.md AGENTS.md docs src tests pyproject.toml
```

Expected: no references to deleted paths or legacy module names.

- [ ] **Step 7: Commit cleanup**

```powershell
git add -A
git commit -m "refactor: remove legacy collector layout"
```

---

### Task 12: Final Branch Verification and Handoff

**Files:**
- No planned source changes
- Modify only defects found by final verification

**Interfaces:**
- Produces a clean branch ready for review and merge.

- [ ] **Step 1: Run the complete final verification from a fresh process**

```powershell
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
conda run -n ustc_assistant python -m ustc_assistant collect jw --help
conda run -n ustc_assistant python -m ustc_assistant collect young-enrolment --help
conda run -n ustc_assistant python -m ustc_assistant collect young-schedule --help
conda run -n ustc_assistant python -m ustc_assistant query icourse --help
```

Expected: all tests pass and all command help calls exit 0.

- [ ] **Step 2: Inspect repository shape and tracked files**

```powershell
git status --short --branch
git ls-files
```

Expected: clean `refactor/project-cleanup` branch; no `temp.md`, `tmp/`, raw data, caches, browser profile, `scripts/`, `examples/`, or historical process docs are tracked.

- [ ] **Step 3: Review the complete change against the baseline**

```powershell
git diff --stat main...HEAD
git diff --check main...HEAD
git log --oneline main..HEAD
```

Expected: no whitespace errors; commits are source-scoped; deletions occur only after live acceptance.

- [ ] **Step 4: Push the refactor branch**

```powershell
git push -u origin refactor/project-cleanup
```

Expected: remote branch is created without force push. Do not merge to `main` automatically.

## Long-Running Execution Rule

Execute Tasks 1 through 9 continuously without waiting for routine confirmation. Attempt Task 10 using the existing persistent Edge profile. If authentication is still valid, continue through Tasks 11 and 12. If a CAPTCHA, expired login, or external-site contract change blocks Task 10, preserve all old files, report the exact sanitized checkpoint, and wait for the user; do not treat this as permission to weaken live acceptance.
