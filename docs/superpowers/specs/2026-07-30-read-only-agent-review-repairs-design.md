# Read-only Agent Review Repairs Design

Date: 2026-07-30

## Goal

Repair the merge-blocking defects found by the whole-branch review of
`feature/read-only-agent` while preserving the approved read-only Agent
architecture and safety boundaries.

The repair is complete only when the real Python producers, Bridge protocol,
Flutter consumers, Agent runtime, and production composition agree. Passing
isolated fake-based tests is not sufficient.

## Scope

The repair covers:

1. Query Result 1.0 contracts for Young enrolment, iCourse, campus catalog
   search, and campus detail.
2. Python Bridge discovery, data-root handling, query lifecycle, cancellation,
   and safe error propagation.
3. Young login pause and explicit resume through the same Bridge job.
4. Agent session cancellation, recovery, concurrency, and tool-result guidance.
5. Anthropic SSE completion, heartbeat, transport-error, usage, cancellation,
   and tool-probe handling.
6. Active-account, configuration, Bridge process, and chat-page lifecycle.
7. Local schedule/free-time bounds, nested outbound allowlists, context
   budgeting, and source-reference presentation.
8. Cross-layer tests, operator documentation, and final verification.

The repair does not add write tools, daily briefings, visual input, mobile
collection adapters, or automated second-classroom enrolment.

## Semester Configuration Boundary

The default teaching semester is shared runtime configuration, not an Agent or
Bridge constant. Production code reads the configured `semesterId`, product
key, and display name, or derives display text from returned source event
metadata. It must not branch on or hardcode the current spring or future autumn
values.

Changing the default from `421/2026spring/2026 春季学期` to
`461/2026fall/2026 秋季学期` must require only a configuration edit. Cross-layer
verification covers that switch so future semester changes cannot leave the
Agent, Bridge, query layer, or UI locked to an old semester.

## Canonical Query Contract

Python remains the sole producer of Query Result 1.0 envelopes. Each query type
gets a canonical fixture generated from the real production wrapper and copied
to the Flutter test fixtures. Flutter maps the exact canonical fields and must
not invent a parallel test-only shape.

- `young_enrolment`: the Bridge wraps the normalized enrolment snapshot into an
  envelope. Activities retain the normalized source names used by Python.
- `icourse`: Flutter consumes `data.query` and bounded `data.results`, including
  site summaries, ratings, evidence, relation strength, and cache freshness.
- `campus_search`: catalog identity is `id`; Flutter converts it to a run-local
  `ref_*` and never exposes the raw ID to the model.
- `campus_detail`: Flutter consumes normalized `content`, attachments and
  discovered-link descriptors allowed by the Query Result validator.

The validator rejects arbitrary URLs in any text position, unsupported schemes,
raw HTML, sensitive key fragments, oversized collections, and oversized text.

## Bridge Runtime And Data Root

The Agent must verify query-capable Python support, not merely that the legacy
Bridge package imports. Development execution may resolve the current worktree
source root explicitly; installed execution uses the installed package.

All relative Python cache/catalog paths resolve from an explicit application
data root supplied to the Bridge. They must not depend on Flutter's process
working directory. The current repository `tmp/` remains a development data
root; packaged Windows builds use a writable local application-data directory.

The external query gateway starts lazily on the first external tool call.
Failure to start Python affects only external tools; local schedule and Task
tools remain available. The composition owner shuts down a started gateway when
disposed.

Bridge monitoring treats collection and query jobs as active. Query state
transitions serialize cancel and resume, and non-2xx responses become bounded
`SourceQueryFailed` codes.

## Young Login Resume

`needs_user_login` is a paused run state, not an ordinary failed tool result.

1. The query stream stays subscribed when the Bridge job pauses.
2. The Agent session stores the paused tool call, Bridge job ID, conversation,
   run-local references, and cancellation signal.
3. The UI shows the explicit login action without completing the Agent run.
4. Clicking continue asks the gateway to resume the same Bridge job. The
   existing protected school password may be supplied only at this boundary.
5. The original query stream completes, its tool result is appended, and the
   same Agent run continues to the next model call.
6. Cancel, app shutdown, account switch, or resume failure cancels the paused
   Bridge job and leaves a safe terminal run.

No model request receives the Bridge job ID, password, verification code,
school account, browser profile path, or raw response.

## Agent Runtime And Provider

Active runs are tracked by account and run ID. A second send for the same
account is rejected while the first run or its summary task is active. Cancel
targets only the matching account and prevents every not-yet-started model or
tool call.

The stream driver always closes its controller and clears active state in a
`finally` block. Repository failures produce a bounded terminal error when
possible. Startup composition invokes interrupted-run recovery before history
is loaded, and interrupted assistant text remains visible and retryable.

The Anthropic provider accepts only streams that reach `message_stop`.
Independent SSE comments are ignored. Mid-body transport failure and truncated
EOF emit typed errors. Standard `message_start` input usage is recorded.
Tool probing requires the expected tool name, exact `{"ok": true}` input, no
error event, and a completed stream. Cancellation must close the in-flight HTTP
client or response subscription rather than wait indefinitely for another
chunk.

## UI And Account Lifecycle

The chat route observes the active account rather than caching it for the
lifetime of the shell. An account change disposes the old composition and
creates a new account-scoped composition.

Configuration state is reloadable. Saving or deleting a Key and changing the
model invalidates both the configured state and the model-bound session
composition. Setup probes list models first, then probe the selected model;
failed probes do not leave a misleading enabled state.

History restoration initially shows the latest messages. Failed, cancelled and
interrupted messages show explicit safe status text. Local event/task references
are navigation actions, not public citations. They are deduplicated by action
kind and open the corresponding local screen; public citations are clickable
only when backed by a trusted URL returned by the tool.

## Local Tools And Privacy

Local tool payloads use nested per-item allowlists. Passing a top-level list no
longer implicitly trusts every nested key. Summary sanitization and context
construction must not persist or repeatedly resend full tool payloads.

Token budgeting includes the system prompt and tool schemas. Summary requests
are independently bounded. Safe `result_too_large` guidance is returned to the
model so it can narrow the next call.

`get_free_time` filters to the requested range before enforcing bounds and
accounts for events overlapping midnight. Pending-review tools provide a
bounded page or date filter instead of an impossible "try fewer" response.
Invalid calendar dates fail instead of normalizing silently.

For semester course questions, the schedule tool supports a bounded grouped
course-summary result so the model does not need one failed full-semester call
followed by many monthly calls. Occurrence-level detail remains available when
requested.

## Test Strategy

Every production fix starts with a failing regression test.

Required test layers:

1. Python production wrapper to Query Result validator.
2. Canonical Query Result fixtures consumed by Flutter mappers.
3. Real local Bridge subprocess smoke test with an isolated data root and no
   school network access.
4. UI-to-session-to-gateway Young pause/resume flow using the same fake job.
5. Router/composition account switch, setup invalidation, recovery and disposal.
6. SSE heartbeat, truncation, body failure, usage, cancellation and probe tests.
7. Session concurrency, cancellation-between-tools and repository-failure tests.
8. Local tool scale, midnight overlap, invalid date and grouped-course tests.
9. Full Python tests, Flutter analysis, split Flutter suites, Windows Release
   build, secret scan, and `git diff --check`.

School API and school websites remain manual acceptance dependencies. Automated
tests must not access them.

## Completion Gate

The branch is not ready to merge until:

- all Critical and Important review findings are fixed or explicitly rejected
  with code evidence;
- the three user-reported failures are reproduced by regression tests and no
  longer occur;
- full automated verification passes at the repaired HEAD;
- documentation reports the repaired HEAD and does not claim manual acceptance;
- the user completes the real API Key, campus-network/iWAN and Young-login
  acceptance checklist.
