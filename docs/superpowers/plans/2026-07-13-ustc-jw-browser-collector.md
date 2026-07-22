# USTC JW Browser Collector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Windows CLI prototype that uses a persistent Edge session to collect the USTC 2026 spring course table and exam page, then produces the existing unified import bundle.

**Architecture:** A focused Playwright module handles login and authenticated collection; a separate CLI module handles conversion, merge, storage, and user-facing status. Pure request helpers and dependency injection keep all automated tests offline.

**Tech Stack:** Python 3.10, Playwright 1.x, Microsoft Edge, standard-library `unittest`.

## Global Constraints

- Conda environment name: `ustc_assistant`.
- Course semester: `semesterKey=2026spring`, `semesterId=421`.
- Browser must be visible because login or CAPTCHA may require the user.
- Passwords remain browser-managed; program code must not read or store them.
- Raw source bodies remain in memory unless `--save-raw` is supplied.
- Automated tests never connect to USTC systems.
- The workspace is not a Git repository, so commit steps are omitted.

---

### Task 1: Authenticated Course Collection

**Files:**
- Create: `scripts/ustc_jw_collector.py`
- Create: `tests/test_ustc_jw_collector.py`

**Interfaces:**
- Produces: `extract_data_id(url: str) -> str`
- Produces: `build_get_data_url(semester_id: int, data_id: str) -> str`
- Produces: `fetch_course_datum(request_context, semester_id: int, data_id: str, referer: str) -> dict[str, Any]`
- Produces: `CollectionError`

- [ ] **Step 1: Write failing URL parsing tests**

Test a valid `get-data` URL, a missing `dataId`, and a different endpoint. Assert
that invalid cases raise `CollectionError` without including the sensitive URL.

- [ ] **Step 2: Run URL tests and verify RED**

Run: `conda run -n ustc_assistant python -m unittest tests.test_ustc_jw_collector -v`

Expected: FAIL because `scripts/ustc_jw_collector.py` does not exist.

- [ ] **Step 3: Implement URL helpers**

Use `urllib.parse.urlsplit` and `parse_qs`; require HTTPS, host
`jw.ustc.edu.cn`, exact course `get-data` path, and one non-empty `dataId`.

- [ ] **Step 4: Run URL tests and verify GREEN**

Run the same test module and expect all URL tests to pass.

- [ ] **Step 5: Write failing authenticated request tests**

Use fake request and response objects. Assert the requested semester is `421`,
the observed `dataId` is reused, the datum body is exactly
`{"lessonIds": [...]}`, and non-2xx or empty lessons raise sanitized errors.

- [ ] **Step 6: Run request tests and verify RED**

Expected: FAIL because `fetch_course_datum` is missing.

- [ ] **Step 7: Implement authenticated request helper**

Call browser-context `get` and `post`, add same-origin referer and
`X-Requested-With`, validate response status and JSON shapes, and return the
datum response dictionary.

- [ ] **Step 8: Run request tests and verify GREEN**

Run the test module and expect all course collection tests to pass.

### Task 2: Browser Login And Exam Collection

**Files:**
- Modify: `scripts/ustc_jw_collector.py`
- Modify: `tests/test_ustc_jw_collector.py`

**Interfaces:**
- Produces: `default_profile_dir() -> Path`
- Produces: `collect_sources(semester_id: int, profile_dir: Path | None = None) -> CollectedSources`
- Produces: `CollectedSources(course_datum: dict[str, Any], exam_html: str)`

- [ ] **Step 1: Write failing tests for profile and response predicates**

Assert the default profile is outside the repository and that only the exact JW
`get-data` endpoint is accepted by the response predicate.

- [ ] **Step 2: Run and verify RED**

Expected: FAIL for missing browser orchestration helpers.

- [ ] **Step 3: Implement persistent Edge orchestration**

Launch Playwright Chromium with `channel="msedge"`, a persistent user-data
directory, and `headless=False`. Wait for authenticated JW navigation, observe
initial `get-data`, call `fetch_course_datum`, navigate to the fixed exam entry,
and return in-memory sources. Always close the context.

- [ ] **Step 4: Run and verify GREEN**

Run the collector tests. No test launches a real browser.

### Task 3: CLI Conversion And Storage

**Files:**
- Create: `scripts/collect_ustc_jw.py`
- Create: `tests/test_collect_ustc_jw.py`

**Interfaces:**
- Produces: `build_bundle(course_datum: dict[str, Any], exam_html: str, semester_key: str, user_id: str) -> dict[str, Any]`
- Produces: `write_collection_outputs(bundle, output_path, save_raw, raw_dir, course_datum, exam_html) -> list[Path]`

- [ ] **Step 1: Write failing in-memory bundle test**

Load the desensitized course and exam samples, call `build_bundle`, and assert 9
events, both included source names, and no personal context identifier.

- [ ] **Step 2: Run and verify RED**

Run: `conda run -n ustc_assistant python -m unittest tests.test_collect_ustc_jw -v`

Expected: FAIL because `scripts/collect_ustc_jw.py` does not exist.

- [ ] **Step 3: Implement in-memory conversion and merge**

Call existing `convert` functions and `import_ustc_jw.merge_packages`; do not
round-trip raw inputs through temporary files.

- [ ] **Step 4: Run and verify GREEN**

Expect the bundle test to pass.

- [ ] **Step 5: Write failing storage tests**

Use `TemporaryDirectory`. Assert normal mode writes only the bundle and that
`save_raw=True` additionally writes course JSON and exam HTML under the supplied
private directory.

- [ ] **Step 6: Run and verify RED**

Expected: FAIL because output writing is missing.

- [ ] **Step 7: Implement output writing and CLI**

Add `--output`, `--profile-dir`, `--save-raw`, `--raw-dir`, `--semester-id`,
`--semester-key`, and `--user-id`. Print high-level progress and sanitized
errors; return a nonzero process status on collection or conversion failure.

- [ ] **Step 8: Run and verify GREEN**

Run both new test modules and expect all tests to pass.

### Task 4: Documentation And Full Verification

**Files:**
- Modify: `docs/ustc-jw-import-pipeline.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Documents the live collection command and privacy behavior.

- [ ] **Step 1: Document environment and command**

Record `ustc_assistant`, installation from root `requirements.txt`, the live
collector command, persistent Edge profile behavior, semester 421, and
`--save-raw` privacy warning.

- [ ] **Step 2: Run the full test suite**

Run: `conda run -n ustc_assistant python -m unittest discover -s tests -v`

Expected: all tests pass with no live network access.

- [ ] **Step 3: Compile all scripts**

Run: `conda run -n ustc_assistant python -m compileall -q scripts tests`

Expected: exit code 0.

- [ ] **Step 4: Check sensitive identifiers and CLI help**

Run the collector with `--help`, and scan committed project files for known real
context IDs. Any match must be confined to a negative test assertion.
