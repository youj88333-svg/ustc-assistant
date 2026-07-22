# USTC JW Unified Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a local importer that merges saved USTC JW course-table datum JSON and exam-arrangement HTML into one project import bundle.

**Architecture:** Reuse the two existing source converters as leaf modules. Add a thin aggregation script that loads optional local inputs, calls the source converters, validates duplicate IDs, appends metadata, and writes JSON.

**Tech Stack:** Python 3.10 standard library, `unittest`, JSON, existing converter scripts

## Global Constraints

- Run Python through conda environment `basic310`.
- Add no third-party dependency.
- Do not implement login, Cookie handling, network requests, or 302 handling in this importer.
- Do not store or emit password, Cookie, Token, full student number, real name, real context ID, or full raw page.
- Keep source-specific parsing inside the existing course and exam converters.

---

### Task 1: Importer Contract Tests

**Files:**
- Create: `tests/test_import_ustc_jw.py`

**Interfaces:**
- Consumes: `examples/ustc-jw-datum.sample.json`, `examples/ustc-jw-exam-page.sample.html`
- Produces: tests for `import_sources(...)` and `merge_packages(...)`

- [x] **Step 1: Write failing module existence test**

Expected failure: `scripts/import_ustc_jw.py` does not exist.

- [x] **Step 2: Write failing behavior tests**

Covered behavior: importing course + exam, importing only course, rejecting duplicate event IDs, and CLI output.

- [x] **Step 3: Run test to verify red state**

Run: `conda run -n basic310 python -m unittest tests.test_import_ustc_jw -v`

Expected: FAIL because the unified importer module is missing.

### Task 2: Unified Import Script

**Files:**
- Create: `scripts/import_ustc_jw.py`

**Interfaces:**
- Consumes: `import_sources(course_datum_path: Path | None, exam_html_path: Path | None, semester_key: str, user_id: str) -> dict[str, Any]`
- Produces: merged package with `calendarEvents`, `sourceRecords`, `scheduleRelations`, and `metadata`

- [x] **Step 1: Implement local file loading and converter calls**

The script imports `convert_ustc_jw_datum` and `convert_ustc_jw_exam_html` from the `scripts` directory and calls their existing `convert` functions.

- [x] **Step 2: Implement package validation and duplicate checks**

The script requires list values for `calendarEvents`, `sourceRecords`, and `scheduleRelations`, then rejects duplicate IDs.

- [x] **Step 3: Implement CLI**

Options: `--course-datum`, `--exam-html`, `--output`, `--semester-key`, `--user-id`.

- [x] **Step 4: Run tests to verify green state**

Run: `conda run -n basic310 python -m unittest tests.test_import_ustc_jw -v`

Expected: PASS.

### Task 3: Sample Output And Documentation

**Files:**
- Create: `examples/ustc-jw-import-bundle.sample.json`
- Create: `docs/ustc-jw-import-pipeline.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: implemented importer and synthetic examples
- Produces: durable project guidance and a sample merged bundle

- [x] **Step 1: Generate sample import bundle**

Run: `conda run -n basic310 python scripts\import_ustc_jw.py --course-datum examples\ustc-jw-datum.sample.json --exam-html examples\ustc-jw-exam-page.sample.html --output examples\ustc-jw-import-bundle.sample.json --semester-key 2026spring --user-id user_sample`

Expected: 9 events, 9 source records, 1 schedule relation.

- [x] **Step 2: Document importer boundary and commands**

`docs/ustc-jw-import-pipeline.md` explains collection, conversion, aggregation, security constraints, and future second-classroom reuse.

- [ ] **Step 3: Run final verification**

Run: `conda run -n basic310 python -m unittest discover -s tests -v`

Run: `conda run -n basic310 python -m py_compile scripts\import_ustc_jw.py`

Run: `conda run -n basic310 python scripts\import_ustc_jw.py --course-datum examples\ustc-jw-datum.sample.json --exam-html examples\ustc-jw-exam-page.sample.html --output tmp\ustc-jw-import.generated.json --semester-key 2026spring --user-id user_sample`
