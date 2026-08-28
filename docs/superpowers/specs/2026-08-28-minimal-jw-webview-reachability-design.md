# Minimal JW WebView Reachability Design

**Date:** 2026-08-28

**Branch:** `refactor/webview-minimal`

**Status:** Approved in chat; pending written-spec review

## Goal

Make the Windows native WebView2 JW flow genuinely reachable for routine use:
open the trusted JW login entry, complete CAS authentication, verify the expected
school account, collect the configured semester's course and exam data, build a
complete SourceBundle 1.0, and import it through the existing minimal database
pipeline.

The implementation remains the minimal product: JW + local schedule + local
Agent. It does not transplant the full rewrite branch's C1/C2/C3 container
architecture.

## Scope and constraints

- Modify only files inside the `refactor/webview-minimal` worktree.
- Treat `E:\107\.worktrees\rewrite\flutter-native` as a read-only reference.
- Preserve the Python JW Bridge as a fallback; Native and Python must never run
  concurrently for the same source.
- Keep SourceBundle 1.0 and the existing Flutter `ImportService` contract.
- Keep the configured semester triple exactly
  `461 / 2026fall / 2026 秋季学期`; never derive the JW semester ID.
- Keep `Asia/Shanghai` time semantics.
- Do not log URLs with query strings, CAS tickets, cookies, DOM contents,
  usernames, course data, data IDs, or raw responses.
- Automatic tests and loopback WebView2 tests do not count as real-campus
  acceptance.
- Do not overwrite or discard the pre-existing uncommitted WebView changes;
  integrate them deliberately and preserve unrelated user work.

## Evidence and root causes

### Native process crash

The existing debug log reaches controller initialization, CAS field fill,
submit, and `domReady:jw.portal.home`, then loses the Flutter device connection.
Windows Application events record repeated crashes of
`ustc_assistant_app.exe` at the same `flutter_windows.dll` offset with
`0xc0000005` and `0xc000041d`. This is a native surface/lifecycle failure, not
merely a URL timeout.

### Surface materialization race

`NativeJwGateway._controller()` currently calls `_notifySurface()` before the
awaiting adapter stores the returned controller. Consequently
`_activeAdapter.surface` can still be null, and no later notification is
guaranteed. The first native job can therefore run with no mounted WebView.

The UI also conditionally inserts and removes the raw `Webview` widget according
to `busy`, while shutdown releases the controller asynchronously without a
frame-level acknowledgement that the texture has left the Flutter tree. The
full rewrite branch solved this class of failure with a stable surface host,
explicit detach acknowledgement, and ordered native teardown.

### Readiness and identity are too permissive

The current navigation helper degrades to success after a registered handshake
times out. The current identity verifier also permits collection to continue
when authoritative identity evidence is absent. Both diverge from the verified
full-branch contracts and can turn a stale or wrong document into an apparent
success.

### Browser policy drift

The bundled plugin is almost identical to the final full-branch package, but
its HTTP-to-HTTPS upgrade check omits the final production-policy guard. The
minimal implementation must use the final, tested navigation-policy behavior.

## Chosen architecture

Use the existing minimal `SyncCoordinator`, `JwCollector`, Dart SourceBundle
builder, `ImportService`, and Bridge-compatible gateway surface. Add only the
small lifecycle and browser-protocol units needed to make the native channel
safe and reachable.

```text
SyncPage
  -> stable minimal WebView surface host
  -> NativeJwGateway (single active job/controller)
  -> JwWebViewAdapter (trusted navigation + registered scripts)
  -> JwCollector
  -> existing Dart SourceBundle builder
  -> existing ImportService
  -> Drift/SQLite + UserOverlay
```

The stable surface host is the key ownership boundary. The page receives one
opaque widget and never receives or moves the controller itself.

## Surface and controller lifecycle

Introduce a minimal surface host based on the final full-branch
`WindowsWebViewSurfaceHost` behavior:

1. The host owns one stable widget instance for the lifetime of the sync-page
   dependencies.
2. A controller is attached only after initialization, event-stream readiness,
   and policy configuration succeed.
3. Attaching a replacement waits until the previous surface generation has
   rendered its placeholder.
4. Detaching clears the source, requests one rebuild, and completes only after
   the placeholder frame or host-widget disposal.
5. Controller teardown occurs only after detach acknowledgement.

The sync page mounts the host widget stably. Visibility may change, but the raw
`Webview(controller)` object is not passed through a `ValueNotifier` and is not
reparented between unrelated widget subtrees. When the page is disposed, host
disposal satisfies any pending detach acknowledgement before the gateway
releases native resources.

The gateway owns controller creation, surface attachment, job settlement, and
controller release. Shutdown order is:

```text
reject new work
  -> request cancellation of every non-terminal job
  -> await terminal job settlement
  -> detach surface and await Flutter acknowledgement
  -> stop controller
  -> clear browsing data when the owning scope requires it
  -> dispose controller and await plugin release
  -> close diagnostics and notifiers
```

All steps are idempotent. Failure in one cleanup step does not skip later safe
cleanup steps; the first stable failure remains the reported error.

## Account and UDF ownership

The controller is bound to the opaque local `accountId` passed to
`startCollection`. Its WebView2 UDF lives below the app-support directory in a
sanitized, non-human-readable account partition. The partition path is never
logged.

One gateway runs one account/controller at a time. A request for a different
account first settles the existing job and completes surface/controller
teardown, then configures the new account UDF. No two controllers race the same
plugin environment, and no WebView session is shared across accounts.

The minimal branch does not add cross-process session snapshots. Restarting the
application may require logging in again, as already documented.

## Trusted login and navigation protocol

Use separate, exact targets:

| Target | Navigation URL/pattern | Required DOM |
|---|---|---|
| `jw.portal.login` | `https://jw.ustc.edu.cn/login*` | `#login-unified-wrapper` |
| `jw.cas.login` | natural transition to `https://id.ustc.edu.cn/cas/login*` | one form containing username and visible password inputs |
| `jw.portal.home` | `https://jw.ustc.edu.cn/home*` | `body` |
| `jw.course.home` | `https://jw.ustc.edu.cn/for-std/course-table*` | `select#allSemesters` |
| `jw.exam.list` | `https://jw.ustc.edu.cn/for-std/exam-arrange*` | exactly one `table#exams` |

For the login transition:

1. Arm target URL and DOM waits before dispatching the action.
2. Validate the portal login element's geometry, visibility, viewport bounds,
   and unobscured hit target.
3. Dispatch one native primary click.
4. Wait for the real CAS form before consuming credentials.
5. Fill the proven username and visible-password selectors.
6. Submit once with the proven `#submitBtn, button.login-button` selector.
7. Let the browser follow the CAS service callback naturally.
8. Require home URL, home DOM, and registered handshake before identity proof.

Read-only DOM waits may retry transient `ExecuteScript` failures during a
document replacement. Portal activation, credential submit, CAS ticket use,
and service callbacks are not retried in place. A retry after a failed
side-effecting authentication attempt must start a fresh trusted login flow.

## Navigation policy

The native synchronous policy remains fail-closed. The allowed production
families are the final observed JW graph:

- `jw.ustc.edu.cn`: root, login, home, UCAS SSO, course-table, exam-arrange
- `passport.ustc.edu.cn`: login relay
- `analytics.ustc.edu.cn`: ISG gateway relay
- `id.ustc.edu.cn`: CAS and ISG gateway relay

Unknown schemes, hosts, ports, paths, downloads, new windows, and permissions
remain blocked. An insecure navigation is upgraded only when the upgraded URL
is allowed by both the active policy and the compile-time production policy.
Debug loopback allowances never inherit production upgrade authority.

## Readiness and identity rules

A target becomes ready only after all three signals succeed within one bounded
attempt generation:

1. matching URL;
2. required DOM selector;
3. registered credential-free handshake.

There is no handshake-degraded success. Late signals from an older generation
cannot satisfy a newer attempt.

Authenticated identity succeeds only when:

- authoritative evidence matches the expected username;
- authoritative evidence does not conflict;
- optional DOM evidence, when present, does not conflict;
- optional storage evidence, when present, does not conflict.

The script returns booleans only. Missing authoritative evidence is a failure,
not an uncertain success. Explicit conflict maps to `account_mismatch`; an
unavailable or malformed proof maps to `collection_failed` unless the verified
contract identifies it as a login timeout.

## Course and exam collection

The product semester remains the configured triple. Runtime page data is used
only to prove the page contract and obtain the temporary course data context.

Course collection performs:

1. Navigate to the course page and require `select#allSemesters`.
2. Read the runtime context and a non-empty `dataId` from an exact same-origin
   `/for-std/course-table/get-data` resource shape.
3. Request `get-data` with GET and exactly the required
   `bizTypeId=2`, configured `semesterId=461`, and runtime `dataId` values.
4. Validate `lessonIds` as a non-empty, unique list of positive integers.
5. Request `datum` with POST, `Content-Type: application/json`,
   `X-Requested-With: XMLHttpRequest`, same-origin credentials, and body
   `{"lessonIds":[...]}`.
6. Reject HTTP errors, malformed JSON, oversized responses, and incomplete
   result shapes.

Exam collection navigates to the exam page, requires exactly one
`table#exams`, applies the response-size bound, and returns only that table's
HTML to the existing parser.

Any authentication, page contract, fetch, parse, normalization, or bundle
construction failure terminates the whole snapshot. Partial course or exam
data is never imported as a complete result.

## Gateway, cancellation, and import

Replace microsecond in-memory busy polling with an awaitable job-state signal.
`poll(jobId, after)` waits until a new event, terminal state, cancellation, or
a bounded poll timeout. The coordinator no longer requires a fixed 250 ms
delay to avoid starving Flutter frames.

Every job has:

- monotonic, gap-free event history;
- a settlement future completed after its terminal event is buffered;
- one controller/account generation;
- a cancellation flag checked between all major stages.

Cancellation is accepted before any late result can be imported. Terminal
`cancelled` wins over a result from the cancelled generation. Shutdown waits
for settlement before releasing the WebView.

On success, the exact existing Dart SourceBundle builder creates SourceBundle
1.0. The Bridge-compatible terminal result is encoded and passed to the
existing `ImportService`. Import remains all-or-nothing and account-partitioned.

Stable public error codes remain:

- `login_timeout`
- `account_mismatch`
- `collection_failed`
- `cancelled`
- existing coordinator/gateway lifecycle codes such as `bridge_busy` and
  `job_not_found`

Internal exception text and sensitive context never enter UI messages or logs.

## Testing strategy

Implementation follows strict red-green-refactor cycles. Each production
behavior below receives a failing regression test before its implementation.

### Unit and widget tests

- Surface appears after controller creation and remains the same host widget.
- Replacement attachment waits for the prior placeholder frame.
- Gateway shutdown waits for job settlement and surface detach before dispose.
- Page disposal safely completes a pending detach.
- URL, DOM, and handshake are all required; missing any one fails.
- Old-generation signals cannot satisfy the active navigation attempt.
- Missing authoritative identity and every conflict combination are rejected.
- CAS activation and submit occur once and are never replayed in place.
- Login uses the exact trusted portal, form, password, and submit selectors.
- Fixed semester GET and JSON datum POST have the exact request shape.
- Invalid lesson IDs, malformed/oversized responses, and non-unique exam tables
  fail without producing a Bundle.
- Gateway poll waits for events instead of spinning.
- Cancellation prevents terminal results from reaching import.
- A complete native result passes through `SyncCoordinator` and the existing
  importer under the correct account partition.
- The canonical Dart fixture still matches the existing Python oracle digest.
- Diagnostics contain only the closed safe stage vocabulary.

### Real Windows loopback integration test

Add a Debug-only Windows WebView2 loopback fixture test using the actual plugin
and texture surface. It covers:

- event-stream readiness before first navigation;
- stable surface mounting;
- portal-to-CAS-style transition;
- URL/DOM/web-message convergence in varied event order;
- registered extraction;
- cancellation;
- detach acknowledgement before controller release;
- process survival after teardown.

The loopback port is an explicit Debug-only policy input. It cannot weaken the
Release policy or HTTP upgrade rules. This test is the automated regression for
the observed `flutter_windows.dll` crash class; fake-controller tests alone
cannot prove native lifecycle safety.

### Final verification

No Flutter commands run in parallel. Close any running
`ustc_assistant_app.exe`, then use one PowerShell terminal in
`E:\107\.worktrees\refactor-webview-minimal\app`.

After the dedicated Windows loopback integration test, run the project gates
in this exact order and stop at the first failure:

```powershell
& 'E:\flutter\flutter\bin\flutter.bat' analyze --no-pub
& 'E:\flutter\flutter\bin\flutter.bat' test --no-pub --reporter expanded
& 'E:\flutter\flutter\bin\flutter.bat' build windows --release --no-pub
```

Run `flutter pub get` separately only if the implementation changes
`pubspec.yaml`, a local path package, or dependency versions.

Python oracle verification uses the project Conda environment
`ustc_assistant`; no package installation or environment mutation is allowed.

## Acceptance boundary

Automated completion requires:

- the new unit/widget regressions pass;
- the real Windows loopback WebView2 integration test passes without a process
  crash;
- analyze completes with no errors beyond the documented baseline severities;
- Flutter test results are compared honestly with the documented baseline;
- Windows Release build exits successfully;
- existing SourceBundle oracle parity remains intact.

True school-site reachability still requires owner-run campus-network/iWAN
acceptance with a real account. That acceptance must observe, without recording
private data:

```text
login entry -> CAS -> identity verified -> course context -> get-data
-> datum -> exam table -> bundle built -> imported -> schedule visible
```

The implementation may be described as automatically verified after the
loopback and project gates pass. It must not be described as real-campus
accepted until the owner performs that final run.

## Explicit non-goals

- No full C1/C2/C3 container transplant.
- No dynamic semester catalog or month-based selection.
- No C++/DPAPI cross-process session snapshot.
- No Android or iOS native WebView implementation.
- No Python Bridge removal.
- No unrelated Flutter database cleanup for retired young/iCourse/campus
  columns in this change.
