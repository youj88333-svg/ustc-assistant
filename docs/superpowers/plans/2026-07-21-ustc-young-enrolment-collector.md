# USTC Young Enrolment Collector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a read-only Playwright CLI that collects every USTC second-classroom activity currently open for enrolment.

**Architecture:** A browser-bound collector owns authentication, stable response matching, UI pagination, validation, and deduplication. A separate CLI normalizes the in-memory records and controls standard versus explicitly requested raw output, following the existing USTC JW prototype boundaries.

**Tech Stack:** Python 3.10, Playwright sync API, standard-library `argparse`, `json`, `unittest`.

## Global Constraints

- Use a visible persistent Microsoft Edge context and the existing dedicated profile by default.
- Do not construct encrypted `requestParams` or persist authentication secrets.
- Match `enrolmentList` by exact host and path; ignore its query string.
- Ignore the unreliable response field `result.current`.
- Automated tests must not access the school website.
- The workspace is not a Git repository, so commit steps are intentionally omitted.

---

### Task 1: Endpoint And Payload Contract

**Files:**
- Create: `tests/test_ustc_young_collector.py`
- Create: `scripts/ustc_young_collector.py`

**Interfaces:**
- Produces: `CollectionError`, `is_enrolment_list_response(response) -> bool`, and `parse_enrolment_page(response) -> EnrolmentPage`.

- [ ] Write failing tests for exact HTTPS host/path/method matching and rejection of query-sensitive or foreign endpoints.
- [ ] Run `conda run -n basic310 python -m unittest tests.test_ustc_young_collector -v` and verify failure because the module is absent.
- [ ] Implement constants, the sanitized exception, response predicate, page dataclass, and strict JSON/page validation.
- [ ] Re-run the focused test module and verify it passes.

### Task 2: Browser Pagination And Authentication

**Files:**
- Modify: `tests/test_ustc_young_collector.py`
- Modify: `scripts/ustc_young_collector.py`

**Interfaces:**
- Produces: `CollectedEnrolmentActivities` and `collect_activities(...)`.
- Consumes: validated `EnrolmentPage` objects from Task 1.

- [ ] Add failing fake-browser tests for visible persistent Edge, the shared profile, manual-login waiting, the first `报名中` response, next-page responses, and context closure.
- [ ] Add failing tests proving `current` is ignored, duplicate identical IDs are deduplicated, conflicting duplicates fail, and final count must equal `total`.
- [ ] Run the focused tests and verify the expected failures.
- [ ] Implement login/app readiness, response waits, next-button pagination, deterministic record merging, count validation, and Playwright error sanitization.
- [ ] Re-run the focused tests and verify they pass.

### Task 3: Normalized CLI And Storage Policy

**Files:**
- Create: `tests/test_collect_ustc_young.py`
- Create: `scripts/collect_ustc_young.py`

**Interfaces:**
- Consumes: `ustc_young_collector.collect_activities()`.
- Produces: `normalize_collection(...)`, `write_collection_outputs(...)`, `parse_args(...)`, and `run_collection(...)`.

- [ ] Write failing tests for stable normalized fields, default output only, optional raw output, CLI defaults, collector injection, and count/status reporting.
- [ ] Run `conda run -n basic310 python -m unittest tests.test_collect_ustc_young -v` and verify failure because the CLI module is absent.
- [ ] Implement normalization, JSON writing, `--profile-dir`, `--output`, `--save-raw`, `--raw-dir`, and login-timeout arguments.
- [ ] Re-run the CLI tests and verify they pass.

### Task 4: Documentation And Full Verification

**Files:**
- Modify: `AGENTS.md`

**Interfaces:**
- Documents: command, output locations, endpoint conclusions, security boundary, and manual acceptance criteria.

- [ ] Update project structure and progress with the two new scripts and tests.
- [ ] Run `conda run -n basic310 python -m unittest discover -s tests -v` and verify zero failures.
- [ ] Run `conda run -n basic310 python -m py_compile scripts\ustc_young_collector.py scripts\collect_ustc_young.py` and verify exit code zero.
- [ ] Review generated code for accidental logging or persistence of `requestParams`, `X-Access-Token`, Cookie, and response bodies.
- [ ] Provide the real acceptance command without claiming that the school website was exercised by automated tests.
