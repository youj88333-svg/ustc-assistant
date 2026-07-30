# Read-only Agent Review Repairs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repair the reviewed read-only Agent so the real Python sources, Bridge, Flutter runtime and Windows UI work together without weakening local-first privacy or read-only safety.

**Architecture:** Preserve the existing Flutter-owned Agent and Python-owned source adapters. Establish one canonical Query Result 1.0 shape per external source, keep a paused Young query alive through explicit UI resume, make the Bridge a lazy disposable platform dependency, and close the reviewed session/provider/lifecycle gaps with regression tests at their real public boundaries.

**Tech Stack:** Python 3.10+, `unittest`, Playwright source adapters, localhost Bridge HTTP protocol, Flutter/Dart, Drift/SQLite, `package:http`, `flutter_markdown`, GoRouter, Windows DPAPI.

## Global Constraints

- Work only in `E:/107/.worktrees/read-only-agent` on `feature/read-only-agent`.
- Python commands use Conda environment `ustc_assistant` with `PYTHONPATH=E:/107/.worktrees/read-only-agent/src`; do not install or upgrade packages.
- Time semantics use `Asia/Shanghai`.
- Do not access school websites or the school model API from automated tests.
- Do not persist or send passwords, API Keys, cookies, tokens, verification codes, complete school accounts, raw responses, browser profile paths, or internal database IDs.
- Young enrolment and cancellation remain user-only actions on official pages.
- The Agent remains read-only and retains the 8-model-call and 12-tool-call hard limits.
- Preserve the three existing dirty Windows generated plugin files; never stage them.
- Every production behavior change starts with a regression test that is observed failing for the expected reason.
- Commit each task separately with explicit paths.

---

### Task 1: Canonical Python Query Result Producers

**Files:**
- Modify: `src/ustc_assistant/bridge/query_jobs.py`
- Modify: `src/ustc_assistant/bridge/query_contracts.py`
- Modify: `src/ustc_assistant/sources/young/enrolment.py`
- Modify: `src/ustc_assistant/sources/icourse/query.py`
- Create: `tests/fixtures/query-results/young-enrolment.json`
- Create: `tests/fixtures/query-results/icourse.json`
- Create: `tests/fixtures/query-results/campus-search.json`
- Create: `tests/fixtures/query-results/campus-detail.json`
- Modify: `tests/bridge/test_query_jobs.py`
- Modify: `tests/bridge/test_query_contracts.py`
- Modify: `tests/young/test_enrolment.py`
- Modify: `tests/icourse/test_query_api.py`

**Interfaces:**
- Consumes: existing normalized Young snapshot, iCourse aggregate, `search_catalog`, and `read_detail`.
- Produces: `build_young_query_result(snapshot)`, strict Query Result 1.0 fixtures, and production wrappers used by `ReadQueryJobManager`.

- [ ] **Step 1: Add failing production-wrapper tests**

Add tests that pass real source-shaped dictionaries through the actual Bridge
runner and `validate_query_result`:

```python
def test_real_young_snapshot_is_wrapped_as_query_result():
    snapshot = normalize_enrolments(SAMPLE_COLLECTION, collected_at=BEIJING_TIME)
    envelope = build_young_query_result(snapshot)
    validate_query_result(envelope)
    assert envelope["data"]["activities"][0]["name"] == "志愿活动"

def test_campus_search_keeps_canonical_catalog_id():
    envelope = _wrap_campus_search({"query": "选课", "results": [CATALOG_ENTRY]})
    assert envelope["data"]["results"][0]["id"].startswith("campus_")
```

Add validator regressions for `http://`, protocol-relative URLs, and URLs
embedded in surrounding text.

- [ ] **Step 2: Run focused Python tests and verify RED**

Run:

```powershell
$env:PYTHONPATH='E:/107/.worktrees/read-only-agent/src'
conda run -n ustc_assistant python -m unittest tests.bridge.test_query_jobs tests.bridge.test_query_contracts tests.young.test_enrolment tests.icourse.test_query_api -v
```

Expected: failures show the raw Young snapshot is not an envelope and embedded
or non-HTTPS URLs are not rejected.

- [ ] **Step 3: Implement canonical production wrappers**

Add a Young wrapper with the exact production source fields:

```python
def build_young_query_result(snapshot: Mapping[str, Any]) -> dict[str, Any]:
    activities = [
        {
            "name": item.get("name"),
            "category": item.get("category"),
            "status": item.get("status"),
            "capacity": item.get("capacity"),
            "appliedCount": item.get("appliedCount"),
        }
        for item in snapshot.get("activities", [])
    ]
    return build_young_enrolment_envelope(
        data={"activities": activities},
        metadata={
            "reportedTotal": snapshot.get("metadata", {}).get("reportedTotal", 0),
            "activityCount": len(activities),
        },
        generated_at=snapshot.get("collectedAt"),
    )
```

Call it from `_run_young_enrolment`. Keep iCourse's existing
`data.query/data.results` shape. Keep campus catalog `id` and campus detail
`content`. Strengthen URL extraction with a URL-token regex and reject every
non-declared URL regardless of its position in a string.

- [ ] **Step 4: Export canonical fixtures from production builders**

Write deterministic fixture builders in tests, then commit their UTF-8 JSON
outputs. Fixtures must contain no real user or school-session data.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: PASS.

- [ ] **Step 6: Commit**

```powershell
git add src/ustc_assistant/bridge/query_jobs.py src/ustc_assistant/bridge/query_contracts.py src/ustc_assistant/sources/young/enrolment.py src/ustc_assistant/sources/icourse/query.py tests/bridge tests/young/test_enrolment.py tests/icourse/test_query_api.py tests/fixtures/query-results
git commit -m "fix: align production query result contracts"
```

---

### Task 2: Flutter Query Consumers And Query-capable Bridge Runtime

**Files:**
- Modify: `app/lib/features/agent/application/agent_tools.dart`
- Modify: `app/lib/features/agent/domain/query_source.dart`
- Modify: `app/lib/features/agent/data/windows_python_query_gateway.dart`
- Modify: `app/lib/features/sync/data/bridge_client.dart`
- Modify: `app/lib/features/sync/data/python_locator.dart`
- Modify: `app/lib/app/router.dart`
- Create: `app/test/fixtures/query_results/young_enrolment.json`
- Create: `app/test/fixtures/query_results/icourse.json`
- Create: `app/test/fixtures/query_results/campus_search.json`
- Create: `app/test/fixtures/query_results/campus_detail.json`
- Modify: `app/test/features/agent/external_agent_tools_test.dart`
- Modify: `app/test/features/agent/windows_python_query_gateway_test.dart`
- Modify: `app/test/features/sync/bridge_client_test.dart`

**Interfaces:**
- Consumes: Task 1 canonical fixtures and Query Result 1.0 field names.
- Produces: exact Flutter mappers, `PythonLocator.locate(requiredModule:)`, safe Bridge protocol errors, and explicit Bridge launch options.

- [ ] **Step 1: Copy canonical fixtures and add failing mapper tests**

Copy the four Task 1 fixtures byte-for-byte into
`app/test/fixtures/query_results/`. Load them in Flutter tests and assert:

```dart
expect(young.payload['activities'][0]['name'], '志愿活动');
expect(icourse.payload['results'], isNotEmpty);
expect(campusSearch.payload['results'][0]['ref'], startsWith('ref_'));
expect(campusDetail.payload['details'][0]['content'], contains('正文'));
```

Add a test proving a legacy Bridge that imports `ustc_assistant.bridge` but
cannot import `ustc_assistant.bridge.query_jobs` is rejected for Agent use.
Add 409/404/malformed-response tests expecting bounded
`SourceQueryFailed` codes.

- [ ] **Step 2: Run focused Flutter tests and verify RED**

Run:

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/external_agent_tools_test.dart test/features/agent/windows_python_query_gateway_test.dart test/features/sync/bridge_client_test.dart
Pop-Location
```

Expected: field-mapping and query-capability tests fail.

- [ ] **Step 3: Align Flutter mappers**

Map the canonical shapes only:

```dart
// young
{'name': raw['name'], 'category': raw['category'], 'status': raw['status']}

// iCourse
{'query': data['query'], 'results': data['results'], 'generatedAt': envelope.generatedAt}

// campus
final entryId = raw['id'];
if (data['content'] != null) dto['content'] = data['content'];
```

Apply nested per-item field selection before returning any DTO to the registry.

- [ ] **Step 4: Require a query-capable Python package**

Extend `PythonLocator.locate`:

```dart
Future<String> locate({
  String? savedExecutable,
  String requiredModule = 'ustc_assistant.bridge',
})
```

Use `importlib.import_module(requiredModule)` in `_canImport`. The Agent route
passes `ustc_assistant.bridge.query_jobs`; sync keeps the default module.

Extend `BridgeProtocolError` with a safe `code` getter and translate Bridge
start/poll failures to `SourceQueryFailed` without body text.

- [ ] **Step 5: Add explicit Bridge source/data-root launch options**

Extend the process launcher without exposing model input:

```dart
class BridgeLaunchOptions {
  const BridgeLaunchOptions({this.workingDirectory, this.environment});
  final String? workingDirectory;
  final Map<String, String>? environment;
}
```

`IoBridgeProcessLauncher` passes these to `Process.start`. In development,
resolve the current worktree root only when it contains
`src/ustc_assistant/bridge/query_jobs.py`, prepend that `src` to `PYTHONPATH`,
and use the worktree root as Bridge data root. Installed execution uses the
installed module and a writable application-data root.

- [ ] **Step 6: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: PASS.

- [ ] **Step 7: Commit**

```powershell
git add app/lib/features/agent/application/agent_tools.dart app/lib/features/agent/domain/query_source.dart app/lib/features/agent/data/windows_python_query_gateway.dart app/lib/features/sync/data/bridge_client.dart app/lib/features/sync/data/python_locator.dart app/lib/app/router.dart app/test/features/agent app/test/features/sync/bridge_client_test.dart app/test/fixtures/query_results
git commit -m "fix: consume canonical query results"
```

---

### Task 3: Young Query Pause And Resume End To End

**Files:**
- Modify: `src/ustc_assistant/bridge/query_jobs.py`
- Modify: `src/ustc_assistant/bridge/server.py`
- Modify: `tests/bridge/test_query_jobs.py`
- Modify: `tests/bridge/test_query_api.py`
- Modify: `app/lib/features/agent/domain/agent_tool.dart`
- Modify: `app/lib/features/agent/domain/agent_models.dart`
- Modify: `app/lib/features/agent/application/agent_tools.dart`
- Modify: `app/lib/features/agent/application/agent_session_service.dart`
- Modify: `app/lib/features/agent/data/windows_python_query_gateway.dart`
- Modify: `app/lib/features/agent/application/agent_composition.dart`
- Modify: `app/lib/features/agent/presentation/agent_chat_page.dart`
- Modify: `app/test/features/agent/agent_session_service_test.dart`
- Modify: `app/test/features/agent/external_agent_tools_test.dart`
- Modify: `app/test/features/agent/agent_chat_page_test.dart`
- Modify: `app/test/integration/read_only_agent_flow_test.dart`

**Interfaces:**
- Consumes: Task 2 `QuerySourceGateway`.
- Produces: `AgentToolStatus.needsUserAction`, a paused `AgentRunViewState`
  carrying only safe action metadata, and `resumeUserAction` that resumes the
  same Bridge job and same Agent run.

- [ ] **Step 1: Replace the fake resume test with a failing real flow test**

The integration test must:

```dart
final states = <AgentRunViewState>[];
final subscription = service
    .send(accountId: account, userText: '查询报名中的二课')
    .listen(states.add);
await gateway.paused.future;
expect(states.last.state, AgentRunState.waitingForUser);
await service.resumeUserAction(accountId: account, runId: states.last.runId)
    .drain<void>();
await subscription.asFuture<void>();
expect(gateway.resumedJobIds, ['young-1']);
expect(states.last.state, AgentRunState.completed);
```

Assert no second query job was started and the password/job ID never appears in
captured provider requests.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/integration/read_only_agent_flow_test.dart test/features/agent/agent_session_service_test.dart test/features/agent/external_agent_tools_test.dart test/features/agent/agent_chat_page_test.dart
Pop-Location
```

Expected: `resume_not_implemented` or premature stream completion.

- [ ] **Step 3: Make Bridge pause/cancel/resume transitions atomic**

Guard phase transitions under the job condition. On `UserActionRequired`,
prefer cancellation if `_cancelled` is set. Reject a second resume before
starting another thread. Count `query_jobs.active_jobs` in the Bridge idle
monitor.

- [ ] **Step 4: Preserve the query stream during pause**

Replace `_collectQueryEvents`' list-return contract for Young with a session-
owned pending invocation. A paused tool returns:

```dart
AgentToolResult(
  status: AgentToolStatus.needsUserAction,
  errorCode: 'needs_user_login',
  userAction: AgentUserAction(
    type: AgentUserActionType.youngLogin,
    opaqueHandle: event.jobId,
  ),
);
```

The opaque handle remains local and is not encoded into the tool result sent to
the model.

- [ ] **Step 5: Resume the same run**

Store a `_PausedRun` keyed by `(accountId, runId)` containing the active query
subscription, model conversation, tool-use ID, references, and signal.
`resumeUserAction` invokes an injected resume callback, waits for the original
query terminal event, appends its sanitized tool result, and continues the
bounded model loop. Cancel and disposal cancel both the query and run.

- [ ] **Step 6: Wire UI action and protected password boundary**

`AgentComposition` injects a callback that reads the school password through
`AccountService.passwordForInteractiveLogin`, then calls
`QuerySourceGateway.resumeLogin`. The UI only calls
`sessionService.resumeUserAction` and never handles the password.

- [ ] **Step 7: Run Python and Flutter focused tests**

Run:

```powershell
$env:PYTHONPATH='E:/107/.worktrees/read-only-agent/src'
conda run -n ustc_assistant python -m unittest tests.bridge.test_query_jobs tests.bridge.test_query_api -v
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/integration/read_only_agent_flow_test.dart test/features/agent/agent_session_service_test.dart test/features/agent/external_agent_tools_test.dart test/features/agent/agent_chat_page_test.dart
Pop-Location
```

Expected: PASS.

- [ ] **Step 8: Commit**

```powershell
git add src/ustc_assistant/bridge/query_jobs.py src/ustc_assistant/bridge/server.py tests/bridge app/lib/features/agent app/test/features/agent app/test/integration/read_only_agent_flow_test.dart
git commit -m "fix: resume young queries through the agent"
```

---

### Task 4: Anthropic SSE Correctness And Cancellation

**Files:**
- Modify: `app/lib/features/agent/data/sse_decoder.dart`
- Modify: `app/lib/features/agent/data/anthropic_llm_provider.dart`
- Modify: `app/lib/features/agent/domain/llm_protocol.dart`
- Modify: `app/test/features/agent/sse_decoder_test.dart`
- Modify: `app/test/features/agent/anthropic_llm_provider_test.dart`

**Interfaces:**
- Produces: typed terminal errors for truncated/failed streams, standard usage
  accounting, strict probe success, and cancellation that releases HTTP work.

- [ ] **Step 1: Add failing SSE/provider regressions**

Add separate tests for:

```text
: keepalive\n\n
message_start + partial text + EOF without message_stop
response body stream ClientException after one text delta
message_start.message.usage.input_tokens
tool probe {"ok": false}
tool_use followed by error
cancel while no response chunk ever arrives
```

Remove the tautological `sub.isPaused || !sub.isPaused` assertion and require
the stream to terminate within a short deterministic timeout.

- [ ] **Step 2: Run focused tests and verify RED**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/sse_decoder_test.dart test/features/agent/anthropic_llm_provider_test.dart
Pop-Location
```

- [ ] **Step 3: Implement strict SSE terminal handling**

Comments do not start an event. Track `sawMessageStop`; normal EOF without it
emits `ErrorEvent('stream_incomplete')`. Body exceptions emit
`ErrorEvent('stream_transport_error')`. Parse input usage from `message_start`
and output usage from `message_delta`.

- [ ] **Step 4: Abort in-flight HTTP on cancellation**

Create one request-scoped `http.Client` or closeable transport lease. Subscribe
to `CancellationSignal.onCancel`, close the lease, and map the resulting client
exception to cancellation rather than retry. Always cancel the subscription in
`finally`.

- [ ] **Step 5: Tighten tool probe**

Require one completed `agent_probe` tool call with exact input
`{'ok': true}`, a `CompletedEvent`, and no `ErrorEvent`.

- [ ] **Step 6: Run focused tests and commit**

Run Step 2. Expected: PASS.

```powershell
git add app/lib/features/agent/data/sse_decoder.dart app/lib/features/agent/data/anthropic_llm_provider.dart app/lib/features/agent/domain/llm_protocol.dart app/test/features/agent/sse_decoder_test.dart app/test/features/agent/anthropic_llm_provider_test.dart
git commit -m "fix: require complete cancellable model streams"
```

---

### Task 5: Agent Session Lifecycle, Recovery And Cancellation

**Files:**
- Modify: `app/lib/features/agent/application/agent_session_service.dart`
- Modify: `app/lib/features/agent/data/drift_chat_repository.dart`
- Modify: `app/lib/features/agent/application/agent_composition.dart`
- Modify: `app/test/features/agent/agent_session_service_test.dart`
- Modify: `app/test/features/agent/chat_repository_test.dart`
- Modify: `app/test/integration/read_only_agent_flow_test.dart`

**Interfaces:**
- Produces: account/run-scoped active state, guaranteed stream cleanup,
  startup recovery, no post-cancel tool starts, and safe error guidance.

- [ ] **Step 1: Add failing lifecycle tests**

Cover:

```dart
test('cancel for account A cannot cancel account B');
test('finishing summary A cannot clear active run B');
test('cancel between two tool uses prevents tool two');
test('repository start failure closes the stream with runtime_error');
test('result_too_large guidance reaches the next model request');
test('composition recovers interrupted runs before loading history');
test('retry does not duplicate the replayed user message in context');
```

- [ ] **Step 2: Run focused tests and verify RED**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/agent_session_service_test.dart test/features/agent/chat_repository_test.dart test/integration/read_only_agent_flow_test.dart
Pop-Location
```

- [ ] **Step 3: Track active runs by account**

Use:

```dart
final Map<String, _ActiveRun> _activeRuns = {};
```

Reject a second same-account run with `run_already_active`. Clear only when the
stored run ID matches. `cancel(accountId:)` targets that entry.

- [ ] **Step 4: Guarantee stream cleanup**

Wrap every asynchronous driver closure in `try/catch/finally`; emit a bounded
`runtime_error` when possible, close the controller once, and remove only the
matching active run.

- [ ] **Step 5: Stop before every new tool**

Check `signal.isCancelled` immediately before registry execution. Append a
well-formed cancelled tool result for any already-declared but unstarted tool
use, then terminate without another model call.

- [ ] **Step 6: Preserve safe tool guidance**

For error results, encode only:

```dart
{'code': result.errorCode ?? 'tool_error', 'guidance': result.payload['guidance']}
```

after the privacy filter has allowlisted the guidance.

- [ ] **Step 7: Recover before composition becomes ready**

Call `chatRepository.recoverInterrupted()` inside `AgentComposition.build`
before returning the session. Include interrupted assistant messages with
partial text in history loading while excluding them from future model context.

- [ ] **Step 8: Run focused tests and commit**

Run Step 2. Expected: PASS.

```powershell
git add app/lib/features/agent/application/agent_session_service.dart app/lib/features/agent/data/drift_chat_repository.dart app/lib/features/agent/application/agent_composition.dart app/test/features/agent/agent_session_service_test.dart app/test/features/agent/chat_repository_test.dart app/test/integration/read_only_agent_flow_test.dart
git commit -m "fix: harden agent run lifecycle"
```

---

### Task 6: Account, Configuration And Bridge Composition Lifecycle

**Files:**
- Modify: `app/lib/app/router.dart`
- Modify: `app/lib/features/agent/application/agent_composition.dart`
- Modify: `app/lib/features/agent/application/agent_configuration_service.dart`
- Modify: `app/lib/features/agent/presentation/agent_chat_page.dart`
- Modify: `app/lib/features/agent/presentation/agent_setup_panel.dart`
- Modify: `app/lib/features/agent/presentation/agent_settings_page.dart`
- Modify: `app/test/app/app_shell_test.dart`
- Modify: `app/test/features/agent/agent_chat_page_test.dart`
- Modify: `app/test/features/agent/agent_configuration_service_test.dart`
- Modify: `app/test/features/agent/agent_settings_page_test.dart`

**Interfaces:**
- Produces: active-account observation, disposable/lazy query composition,
  reloadable configuration and transactional settings changes.

- [ ] **Step 1: Add failing production-composition tests**

Use a router test with an in-memory database to activate account A, render its
chat, switch to B, and assert the second composition receives B. Add tests that
save a Key in the inline setup panel and immediately enable the composer,
delete a Key and disable it, and dispose a fake query gateway on account switch.
Add a test proving local chat composition succeeds when external gateway start
fails.

- [ ] **Step 2: Run focused tests and verify RED**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/app/app_shell_test.dart test/features/agent/agent_chat_page_test.dart test/features/agent/agent_configuration_service_test.dart test/features/agent/agent_settings_page_test.dart
Pop-Location
```

- [ ] **Step 3: Observe active account and dispose old composition**

Replace `_AgentChatLoader`'s one-shot account Future with a Drift watch stream.
Key `_AgentChatCompositionBuilder` by account ID. Add
`AgentCompositionResult.dispose()` that shuts down a started external gateway.
Call it from State `dispose()` and before replacing a composition.

- [ ] **Step 4: Make the external gateway lazy**

Inject a `LazyQuerySourceGateway` that starts `WindowsPythonQueryGateway` only
on first `execute`, `resumeLogin`, or `cancel`. Cache successful startup,
surface bounded failure events, and dispose only if started.

- [ ] **Step 5: Reload configuration and model-bound service**

Replace the immutable configured Future with a reload method invoked after
setup save/delete/model change. Rebuild `AgentSessionService` when the persisted
model changes.

- [ ] **Step 6: Make setup persistence atomic**

List available models first, choose the default only when present, run text and
tool probes, then save Key and enable in one success path. Probe failure leaves
the prior Key/settings unchanged. Protect read-modify-upsert settings changes
with a database transaction.

- [ ] **Step 7: Restore latest history and explicit terminal copy**

After history loads, schedule one post-frame jump to max scroll extent. Render
safe text for failed, cancelled and interrupted empty messages instead of
`正在思考...`.

- [ ] **Step 8: Run focused tests and commit**

Run Step 2. Expected: PASS.

```powershell
git add app/lib/app/router.dart app/lib/features/agent app/test/app/app_shell_test.dart app/test/features/agent
git commit -m "fix: rebuild agent composition with account state"
```

---

### Task 7: Local Tool Scale, Context Privacy And Schedule References

**Files:**
- Modify: `app/lib/features/agent/application/agent_tools.dart`
- Modify: `app/lib/features/agent/application/outbound_privacy_filter.dart`
- Modify: `app/lib/features/agent/application/agent_context_builder.dart`
- Modify: `app/lib/features/agent/application/agent_session_service.dart`
- Modify: `app/lib/features/agent/domain/agent_tool.dart`
- Modify: `app/lib/features/agent/presentation/safe_markdown_message.dart`
- Modify: `app/lib/features/agent/presentation/agent_chat_page.dart`
- Modify: `app/test/features/agent/local_agent_tools_test.dart`
- Modify: `app/test/features/agent/outbound_privacy_filter_test.dart`
- Modify: `app/test/features/agent/agent_context_builder_test.dart`
- Modify: `app/test/features/agent/agent_session_service_test.dart`
- Modify: `app/test/features/agent/agent_chat_page_test.dart`

**Interfaces:**
- Produces: nested DTO allowlists, bounded context, grouped course summaries,
  correct free-time overlap, paged pending reviews, and deduplicated local
  navigation actions separate from public citations.

- [ ] **Step 1: Add failing privacy and local-tool tests**

Add regressions for:

```text
nested db_id/Cookie/ProfilePath inside events/tasks/history
system + tool schema + messages exceeding 24k
summary request exceeding its own input budget
201 out-of-range events plus one requested-range event
23:00-08:00 event blocking next-day 07:00-08:00
2026-02-31 rejected
more than 200 pending reviews with page/limit
2026 spring grouped summary returning course groups under 200 items
241 event refs producing one local "查看日程" action
```

- [ ] **Step 2: Run focused tests and verify RED**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/features/agent/local_agent_tools_test.dart test/features/agent/outbound_privacy_filter_test.dart test/features/agent/agent_context_builder_test.dart test/features/agent/agent_session_service_test.dart test/features/agent/agent_chat_page_test.dart
Pop-Location
```

- [ ] **Step 3: Implement nested allowlists**

Each payload builder maps every list item to an explicit field map. No builder
returns a raw nested list or map from tool output. Add recursive suspicious-key
rejection as defense in depth.

- [ ] **Step 4: Include fixed request overhead in token budgets**

Estimate system prompt and JSON-encoded tool declarations before history
trimming. Bound summary history independently. Reject or locally truncate an
oversized current question before provider invocation with a safe error.

- [ ] **Step 5: Repair local query boundaries**

Validate date components by round-tripping year/month/day. Filter events to the
requested interval before the 200-event limit. Treat occupancy as interval
intersection:

```dart
eventStart.isBefore(dayEnd) && eventEnd.isAfter(dayStart)
```

Add `offset`/`limit` or date bounds to both pending-review tools.

- [ ] **Step 6: Add grouped course-summary mode**

Extend `get_schedule` schema with:

```json
{"view":{"type":"string","enum":["events","course_summary"],"default":"events"}}
```

Group by stable course/offering identity, returning course name, teachers,
locations, active date range, weekday/period patterns and occurrence count.
The 200-item limit applies after grouping in summary mode.

- [ ] **Step 7: Separate local navigation actions from citations**

Do not add every local event ref to `sourceReferences`. Add one deduplicated
`AgentLocalAction.schedule` when schedule data was used and one
`AgentLocalAction.tasks` when task data was used. The chat page routes these to
`/schedule` or the corresponding management screen. Public citations remain
clickable only when they carry a trusted tool-returned HTTPS URL.

- [ ] **Step 8: Run focused tests and commit**

Run Step 2. Expected: PASS.

```powershell
git add app/lib/features/agent app/test/features/agent
git commit -m "fix: bound local agent context and schedule queries"
```

---

### Task 8: Real Composition Coverage And Documentation

**Files:**
- Modify: `app/test/integration/read_only_agent_flow_test.dart`
- Create: `app/test/integration/agent_composition_flow_test.dart`
- Modify: `app/test/accessibility/milestone_accessibility_test.dart`
- Modify: `docs/acceptance/read-only-agent.md`
- Modify: `docs/architecture.md`
- Modify: `docs/read-only-agent-handoff.md`
- Modify: `README.md`
- Modify: `app/README.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: Tasks 1-7 repaired production composition.
- Produces: integration tests that include Router, composition ownership,
  SecretStore seam, account switching, Young resume, and documented operator
  behavior.

- [ ] **Step 1: Add a failing composition-level integration test**

The test must pump the real chat route with injected platform factories and
exercise:

```text
account A -> configure -> local schedule -> grouped semester summary
-> Young pause -> explicit resume same job -> final answer
-> switch to B -> empty account-scoped chat
-> switch back to A -> recovered conversation
-> dispose -> query gateway shutdown exactly once
```

Capture provider requests and assert no password, job ID, raw catalog ID,
complete account or API Key appears.

- [ ] **Step 2: Run integration tests and verify RED**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/integration/agent_composition_flow_test.dart test/integration/read_only_agent_flow_test.dart test/accessibility/milestone_accessibility_test.dart
Pop-Location
```

- [ ] **Step 3: Add only the injection seams needed by the real router test**

Expose platform factories through `buildRouter` or an `AgentPlatformFactories`
value. Production defaults remain DPAPI, PythonLocator and the real school
provider. Tests inject memory stores, fake provider and fake query gateway
without constructing a parallel session manually.

- [ ] **Step 4: Correct documentation and acceptance steps**

Remove claims that users configure the fixed Host in-app. Do not require a
stored “last probe time” unless implemented. Record:

- exact repaired HEAD only after final commit;
- lazy Bridge behavior and explicit data root;
- same-job Young pause/resume;
- local actions versus trusted public citations;
- automated test counts as automated evidence only;
- manual acceptance remains blank.

- [ ] **Step 5: Run integration tests and commit**

Run Step 2. Expected: PASS.

```powershell
git add app/test/integration app/test/accessibility README.md AGENTS.md app/README.md docs/acceptance/read-only-agent.md docs/architecture.md docs/read-only-agent-handoff.md
git commit -m "test: cover the repaired agent composition"
```

---

### Task 9: Full Verification And User-reported Regressions

**Files:**
- Modify only when a failing verification exposes a scoped defect.
- Update: `docs/read-only-agent-handoff.md`

**Interfaces:**
- Produces: merge-readiness evidence for the repaired branch.

- [ ] **Step 1: Run the three explicit regression scenarios**

Automated:

1. “2026 春有什么课” uses grouped schedule mode, does not first fail on 241
   occurrences, and yields one clickable local schedule action.
2. Young query succeeds with an existing session and pauses/resumes the same job
   when login is required.
3. Campus catalog search uses the explicit data root and returns canonical
   entries; detail consumes `content`.

- [ ] **Step 2: Run complete Python verification**

```powershell
$env:PYTHONPATH='E:/107/.worktrees/read-only-agent/src'
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
```

Expected: all tests pass and compileall exits 0.

- [ ] **Step 3: Run split Flutter suites**

Avoid the previous opaque 10-minute monolithic timeout:

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat test test/core test/features/agent test/integration
E:\flutter\flutter\bin\flutter.bat test test/features --exclude-tags agent
E:\flutter\flutter\bin\flutter.bat test test/app test/accessibility test/goldens
E:\flutter\flutter\bin\flutter.bat analyze
Pop-Location
```

If the installed Flutter version does not support `--exclude-tags`, enumerate
the non-Agent feature directories explicitly with `rg --files test/features`.
Every suite must terminate and report its test count.

- [ ] **Step 4: Build Windows Release**

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat build windows --release
Pop-Location
```

- [ ] **Step 5: Inspect boundaries**

```powershell
rg -n -i "api[_ -]?key|authorization|bearer|cookie|token|password|PB[0-9]{6,}" app/lib src tests docs --glob "!docs/superpowers/plans/*.md"
rg -n "dart:io|windows_dpapi|Process" app/lib/features/agent/domain app/lib/features/agent/application
git diff --check
git status --short
```

Review every match. Expected: fake canaries, field names and safety
documentation only; shared Agent domain/application has no platform import.

- [ ] **Step 6: Update handoff with actual evidence**

Record exact HEAD, per-suite counts, any deferred Minor findings, and that real
school-service acceptance is still pending.

- [ ] **Step 7: Commit verification documentation**

```powershell
git add docs/read-only-agent-handoff.md
git commit -m "docs: hand off reviewed agent repairs"
```

- [ ] **Step 8: Perform real manual acceptance**

The user runs `docs/acceptance/read-only-agent.md` with the real API Key,
campus network/iWAN and visible Edge. Record only safe pass/fail text after each
`完成：`; never record secrets, complete account identifiers, private schedule
titles or raw responses.

