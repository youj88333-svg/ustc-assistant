# USTC JW Exam Parser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert a saved USTC exam-arrangement HTML page into validated `CalendarEvent` and `SourceRecord` JSON without retaining student identity.

**Architecture:** A standard-library `HTMLParser` extracts only `table#exams` into normalized rows. A separate conversion layer validates rows, creates stable event identities and fingerprints, and a small CLI reads UTF-8 HTML and writes JSON.

**Tech Stack:** Python 3.10 standard library, `unittest`, JSON, HTMLParser

## Global Constraints

- Run Python through conda environment `basic310`.
- Add no third-party dependency.
- Do not store or emit student identity, cookies, tokens, raw HTML, or context ID.
- Treat all columns except exam note as required.
- Treat an empty exam table as valid.

---

### Task 1: Synthetic Fixture And Parser Contract

**Files:**
- Create: `examples/ustc-jw-exam-page.sample.html`
- Create: `tests/test_convert_ustc_jw_exam_html.py`
- Create: `scripts/convert_ustc_jw_exam_html.py`

**Interfaces:**
- Consumes: UTF-8 HTML string containing `table#exams`
- Produces: `parse_exam_rows(html_text: str) -> list[ExamRow]`

- [ ] **Step 1: Create a synthetic HTML fixture with three complete exam rows**

Include different exam types, two exams on one date, an empty note, and an HTML
entity in a course name. Do not copy a real name, student number, context ID,
course schedule, or room assignment.

- [ ] **Step 2: Write failing extraction and validation tests**

```python
def test_parse_exam_rows_from_sample():
    rows = parser.parse_exam_rows(SAMPLE.read_text(encoding="utf-8"))
    assert len(rows) == 3
    assert rows[0].course_name == "数据结构与算法（示例）"

def test_empty_table_is_valid():
    assert parser.parse_exam_rows(EXAM_TABLE_WITHOUT_ROWS) == []

def test_missing_exam_table_is_rejected():
    with self.assertRaisesRegex(ValueError, "table#exams"):
        parser.parse_exam_rows("<html></html>")
```

- [ ] **Step 3: Run tests and verify failure**

Run: `conda run -n basic310 python -m unittest tests.test_convert_ustc_jw_exam_html -v`

Expected: FAIL because the converter module or parser functions do not exist.

- [ ] **Step 4: Implement minimal `ExamRow` and table extraction**

Implement an immutable dataclass with eight source fields and an `HTMLParser`
subclass that tracks `table#exams`, `thead`, `tbody`, `tr`, `th`, and `td`.
Normalize each cell with `" ".join(text.split())`, verify the exact header list,
and reject rows with other than eight cells.

- [ ] **Step 5: Run extraction tests**

Run: `conda run -n basic310 python -m unittest tests.test_convert_ustc_jw_exam_html -v`

Expected: extraction, empty-table, HTML-entity, and structural-error tests PASS.

### Task 2: Calendar Conversion And CLI

**Files:**
- Modify: `scripts/convert_ustc_jw_exam_html.py`
- Modify: `tests/test_convert_ustc_jw_exam_html.py`
- Create: `examples/ustc-jw-exam-events.sample.json`

**Interfaces:**
- Consumes: `ExamRow`, `semester_key: str`, `user_id: str`
- Produces: `convert(html_text: str, semester_key: str, user_id: str) -> dict[str, Any]`

- [ ] **Step 1: Write failing conversion tests**

```python
def test_convert_builds_exam_event():
    result = parser.convert(SAMPLE_HTML, "2026spring", "user_sample")
    event = result["calendarEvents"][0]
    assert event["type"] == "exam"
    assert event["importance"] == "critical"
    assert event["attendancePolicy"] == "must_go"
    assert event["startAt"].endswith("+08:00")

def test_duplicate_identity_is_rejected():
    with self.assertRaisesRegex(ValueError, "duplicate exam identity"):
        parser.convert(DUPLICATE_HTML, "2026spring", "user_sample")
```

- [ ] **Step 2: Verify conversion tests fail**

Run: `conda run -n basic310 python -m unittest tests.test_convert_ustc_jw_exam_html -v`

Expected: FAIL because `convert` is not implemented.

- [ ] **Step 3: Implement time parsing, event mapping, fingerprints, and CLI**

Use strict regular expression
`^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2})~(\d{2}:\d{2})$`, validate with
`datetime.strptime`, and require `end > start`. Generate stable external IDs
from semester, course code, and exam type. Generate fingerprints from all eight
normalized fields. Add CLI options `--input`, `--output`, `--semester-key`, and
`--user-id`, following the existing course converter style.

- [ ] **Step 4: Run all unit tests**

Run: `conda run -n basic310 python -m unittest tests.test_convert_ustc_jw_exam_html -v`

Expected: all tests PASS.

- [ ] **Step 5: Generate and inspect the sample output**

Run: `conda run -n basic310 python scripts\convert_ustc_jw_exam_html.py --input examples\ustc-jw-exam-page.sample.html --output examples\ustc-jw-exam-events.sample.json --semester-key 2026spring --user-id user_sample`

Expected: 3 events and 3 source records; output contains no personal identifiers.

### Task 3: Integration Documentation And Final Verification

**Files:**
- Create: `docs/ustc-jw-exam-transform.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: confirmed redirect behavior and implemented converter contract
- Produces: durable project integration guidance

- [ ] **Step 1: Document source discovery and conversion rules**

Record the stable `/for-std/exam-arrange` entry, HTTP 302 behavior, HTML table
columns, validation rules, field mapping, ID strategy, security boundary, and
CLI usage. Use `{contextId}` placeholders only.

- [ ] **Step 2: Update project progress**

Append a concise exam-integration progress section to `AGENTS.md`, listing the
new files and verification command without real student data.

- [ ] **Step 3: Run full verification**

Run: `conda run -n basic310 python -m unittest discover -s tests -v`

Expected: all tests PASS.

Run: `conda run -n basic310 python -m py_compile scripts\convert_ustc_jw_exam_html.py`

Expected: exit code 0 and no output.

Run: `conda run -n basic310 python scripts\convert_ustc_jw_exam_html.py --input examples\ustc-jw-exam-page.sample.html --output tmp\exam-events.generated.json --semester-key 2026spring --user-id user_sample`

Expected: 3 events and 3 source records.
