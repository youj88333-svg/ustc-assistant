# USTC JW Exam Parser Design

## Scope

Build a local, read-only prototype that converts a saved USTC academic-system
exam HTML page into the project's `CalendarEvent` and `SourceRecord` JSON.
Authentication, cookies, redirects, and network requests stay outside this
parser.

## Confirmed Source Behavior

- Authenticated `GET /for-std/exam-arrange` returns HTTP 302 and redirects to
  `/for-std/exam-arrange/info/{contextId}`.
- The final HTML contains the complete exam data in `table#exams`.
- Course-table and exam pages resolve to the same per-student context ID.
- The context ID is session context only. It must not appear in examples,
  generated IDs, logs, or long-term project data.

## Input Contract

The parser accepts a complete, correctly decoded UTF-8 HTML document. It reads
only `table#exams` and ignores student identity and all content outside that
table.

The expected columns, in order, are:

1. course section code
2. exam type
3. course name
4. date and time
5. room
6. building
7. campus
8. exam note

The exam note may be empty. Every other field is required because the system
only publishes an exam row after its arrangement is complete. An empty table is
valid and means no published exams.

## Parsing Rules

- Use Python's standard-library `html.parser.HTMLParser`; add no dependency.
- Match the table by `id="exams"`, not by its position in the document.
- Normalize HTML entities and collapsed whitespace in cell text.
- Parse time only in `YYYY-MM-DD HH:MM~HH:MM` form.
- Validate the calendar values and require the end time to be later than the
  start time.
- Reject a missing table, unexpected header order, non-eight-cell rows,
  missing required values, invalid times, and duplicate exam identities.
- Error messages identify the row and field but never include content outside
  the exam table.

## Output Contract

Each row produces one `CalendarEvent`:

- `type`: `exam`
- `status`: `active`
- `timezone`: `Asia/Shanghai`
- `importance`: `critical`
- `attendancePolicy`: `must_go`
- `attendanceDecision`: `go`
- `listeningMode`: `unknown`
- `title`: `<course name>（<exam type>）`
- `locationName`: room
- `buildingName`: building
- `campusName`: campus
- `tags`: `exam` and the exam type

The stable external identity is
`ustc_jw:exam:{semesterKey}:{courseCode}:{examType}`. A later room or time
change therefore updates the same event. If the source contains two rows with
the same identity, parsing fails instead of guessing.

Each event has a `SourceRecord` with source type `jw_exam`. Its fingerprint is
a SHA-256 digest of all eight normalized source fields. Raw HTML, student
identity, and context ID are not preserved.

The result object contains `calendarEvents`, `sourceRecords`, and an empty
`scheduleRelations` list. Cross-source conflict detection belongs to the
calendar aggregation layer.

## Files

- `examples/ustc-jw-exam-page.sample.html`: fully synthetic source sample.
- `examples/ustc-jw-exam-events.sample.json`: expected converted shape.
- `scripts/convert_ustc_jw_exam_html.py`: parser and command-line converter.
- `tests/test_convert_ustc_jw_exam_html.py`: standard-library unit tests.
- `docs/ustc-jw-exam-transform.md`: source and field-mapping documentation.
- `AGENTS.md`: concise progress record without sensitive values.

## Verification

Tests cover normal rows, empty notes, multiple exams on one day, HTML entities,
empty tables, missing tables, changed headers, missing fields, malformed times,
end-before-start times, and duplicate identities. The converter is also run
against the synthetic sample and compiled with `py_compile` in conda environment
`basic310`.
