# USTC JW Browser Collector Design

## Goal

Build a Windows command-line prototype that opens a dedicated Microsoft Edge
profile, lets the user complete USTC CAS login when necessary, collects the
2026 spring course table and the published exam page in the authenticated
session, and writes the existing unified import bundle.

## Scope

- Use the installed Microsoft Edge through Playwright.
- Use a dedicated persistent browser profile. The program never reads or writes
  a password itself.
- The first login and any CAPTCHA are completed by the user on the official USTC
  page. Later runs first reuse browser session state and browser-managed
  autofill.
- Collect only the 2026 spring course table in this prototype:
  `semesterKey=2026spring`, `semesterId=421`.
- Collect all rows currently published in `table#exams`.
- Convert in memory with the existing course and exam converters.
- Save only the unified import bundle by default. Raw source data is written
  only when `--save-raw` is explicitly supplied.
- Do not implement second-classroom access, CAS protocol emulation, CAPTCHA
  solving, background scheduling, or a graphical application.

## Architecture

`scripts/ustc_jw_collector.py` owns browser and authenticated HTTP collection.
It exposes small URL parsing and request functions that can be tested without a
real browser, plus one Playwright orchestration function for manual acceptance.

`scripts/collect_ustc_jw.py` owns CLI arguments, invokes the collector, passes
the in-memory sources to the existing converters, merges packages with
`import_ustc_jw.merge_packages`, and writes output files.

The existing converters remain unaware of login, cookies, redirects, or
Playwright.

## Data Flow

1. Launch a persistent Edge context using a dedicated profile under the current
   Windows user's local application-data directory.
2. Open `https://jw.ustc.edu.cn/`. If the browser reaches the login or CAS page,
   print a prompt and wait until it returns to an authenticated JW page.
3. Open `https://jw.ustc.edu.cn/for-std/course-table` and observe its initial
   `get-data` response. Parse `dataId` from the actual request URL; do not infer
   it from the final page URL.
4. In the same browser context, request `get-data` with `semesterId=421` and the
   observed `dataId`. Read `lessonIds`.
5. POST `{ "lessonIds": [...] }` to `/for-std/course-table/datum` in the same
   authenticated context.
6. Open `https://jw.ustc.edu.cn/for-std/exam-arrange`, follow its redirect, and
   retain the resulting HTML in memory.
7. Convert the course JSON and exam HTML, merge the packages, and write
   `tmp/ustc-jw-import.generated.json`.
8. Close the browser context. The dedicated Edge profile remains for later
   sessions; raw source bodies are released when the process exits.

## Security And Storage

- Never print or write passwords, cookies, authorization headers, CAS tickets,
  `dataId`, or `contextId`.
- Error messages name the failed endpoint but omit query strings and response
  bodies.
- The persistent Edge profile is outside the repository and is sensitive.
- The standard import bundle contains private schedule information but no
  authentication material or raw pages.
- With `--save-raw`, write the course datum and exam HTML under `tmp/private/`
  and print an explicit privacy warning.

## Error Handling

- Login timeout: close the browser and report that login was not completed.
- Missing initial `get-data`: report that the course page structure or behavior
  may have changed.
- Missing or invalid `dataId`: reject the URL without printing its query.
- Non-success `get-data` or `datum`: report endpoint and HTTP status only.
- Empty `lessonIds` for this configured test semester: stop with a clear error,
  because the semester was selected specifically to contain courses.
- Invalid exam table or conversion failure: preserve no raw source by default
  and return a nonzero exit code.
- Output is written only after both source conversions and package merge
  succeed, avoiding a misleading partial bundle.

## Testing

- Unit-test URL validation and `dataId` extraction.
- Unit-test authenticated course requests with fake request/response objects,
  including request payloads and sanitized errors.
- Unit-test in-memory conversion and package merge using existing desensitized
  samples.
- Unit-test default output behavior and opt-in raw saving in a temporary
  directory.
- Keep the real CAS login and live JW requests as a manual acceptance test; the
  automated suite must not access school systems or real credentials.

## Acceptance Criteria

- `ustc_assistant` can import the collector modules and run all unit tests.
- Running the CLI opens Edge and allows manual CAS login.
- A successful live run produces a bundle containing both course and exam
  sources for `2026spring`.
- A normal run does not create raw course JSON or exam HTML files.
- Logs and bundle output contain no password, cookie, CAS ticket, `dataId`, or
  `contextId`.
