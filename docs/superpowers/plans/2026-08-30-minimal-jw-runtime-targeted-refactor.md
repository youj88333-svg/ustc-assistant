# Minimal JW Runtime Targeted Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace page-owned JW WebView/reset lifecycle with one app-owned minimal runtime that supports atomic first login, fail-closed reset, and a truly reachable single-account real-acceptance flow.

**Architecture:** The app composition root owns one `MinimalJwRuntime`; routes borrow its gateway and surface. A synchronous `JwJobArbiter`, a Windows `JwBrowserSessionAdmin`, and a contained `WindowsJwUdfStore` give one owner to jobs, controller/environment release, and browser partitions. A fixed `MinimalResetCoordinator` quiesces the known minimal writers before global deletion and keeps the app in maintenance when physical cleanup is incomplete.

**Tech Stack:** Flutter/Dart, Drift/SQLite, `webview_flutter_windows_secure`, Windows WebView2, SourceBundle 1.0, Flutter test/integration_test, Python unittest oracle.

**Spec:** `docs/superpowers/specs/2026-08-30-minimal-jw-runtime-targeted-refactor-design.md`

## Global Constraints

- Modify only `E:\107\.worktrees\refactor-webview-minimal` and its children; the rewrite worktree is read-only reference.
- Minimal is single-account. Re-login means complete reset followed by first login; never preserve or switch account partitions.
- Keep Python Bridge as an explicit mutually exclusive fallback; Native and Python must share the same job arbiter and never double-write.
- Do not change Drift schema or SourceBundle 1.0.
- Never log username, password, Cookie, CAS ticket, URL query, DOM, response bodies, or private schedule rows.
- Preserve user-owned dirty `app/pubspec.yaml`, `app/pubspec.lock`, `baseline_head.txt`, and `jw-debug.log`; never stage them.
- The user authorized discarding only the paused agent-authored lifecycle/reset working-tree edits after they are copied into the ignored audit directory described below.
- Flutter gates run sequentially in one terminal: `analyze --no-pub` → `test --no-pub --reporter expanded` → `build windows --release --no-pub`; stop on first nonzero result.
- Automated loopback/build evidence is not real-campus acceptance.

## File Map

### New focused units

- `app/lib/features/sync/runtime/jw_job_arbiter.dart` — atomic single-job and maintenance leases.
- `app/lib/features/sync/runtime/source_job_gateway.dart` — UI-facing login/sync/cancel state contract.
- `app/lib/features/sync/runtime/minimal_jw_runtime.dart` — one app-owned runtime and ordered shutdown.
- `app/lib/features/sync/runtime/minimal_jw_runtime_scope.dart` — Flutter scope that exposes the app-owned runtime without route ownership.
- `app/lib/features/sync/native/windows_jw_udf_store.dart` — opaque partition, quarantine, containment, retries, clear-all.
- `app/lib/features/sync/native/jw_browser_session_admin.dart` — controller/surface/session ownership port.
- `app/lib/features/sync/native/windows_jw_browser_session_admin.dart` — Windows implementation over the existing adapter/controller factory.
- `app/lib/features/accounts/application/first_login_commit_service.dart` — provisional identity/credential/bundle atomic commit.
- `app/lib/features/settings/application/minimal_reset_coordinator.dart` — fixed writer quiesce and fail-closed reset state machine.

### Existing units to narrow

- `app/lib/features/sync/native/native_jw_gateway.dart` — remains the low-level `BridgeGateway`; no UI/runtime ownership.
- `app/lib/features/sync/application/sync_coordinator.dart` — consumes the new runtime gateway and prepared-import commit seam.
- `app/lib/features/import/application/import_service.dart` — split validation/preparation from transactional persistence.
- `app/lib/features/accounts/application/account_service.dart` — stage secrets only; delegate first-login commit.
- `app/lib/features/sync/presentation/sync_page.dart` — view/state renderer only; remove gateway/environment factory and UDF deletion.
- `app/lib/app/app.dart`, `app/lib/app/router.dart` — compose one runtime/reset coordinator and route borrowed dependencies.
- Agent/reminder services — expose explicit fixed quiesce/resume ports; do not register dynamically.

---

## Execution Preflight: Preserve and Remove the Paused Agent Patch

This is a controller-owned preflight, not an implementation task and not a commit.

- [ ] **Step 1: Verify the exact paused paths**

Run:

```powershell
git status --short
git diff --name-only
```

Expected agent-authored tracked paths are the app/router, Agent session, reminder, settings, sync coordinator/page, and their tests shown in the 2026-08-30 pause report. `app/pubspec.yaml` and `app/pubspec.lock` are user-owned and excluded.

- [ ] **Step 2: Copy every paused agent-authored file into an ignored audit directory**

Resolve the audit root beneath:

```text
.superpowers/sdd/2026-08-30-minimal-jw-runtime-targeted-refactor/paused-reset-quiesce/
```

Use native PowerShell `Copy-Item -LiteralPath` for each exact tracked/untracked agent file, preserving its repository-relative path. Verify every resolved source and destination remains inside this worktree. Do not copy `pubspec.*`, `baseline_head.txt`, or `jw-debug.log`.

- [ ] **Step 3: Restore only the authorized tracked paths and remove only the authorized untracked paths**

Use `git restore --source=HEAD -- <explicit tracked paths>`; never use `git reset --hard` or a glob. For each agent-created untracked file, resolve its absolute path, verify it is inside this worktree, then remove that exact file/directory with `Remove-Item -LiteralPath`. Keep the audit copy.

- [ ] **Step 4: Prove owner changes survived**

Run:

```powershell
git status --short
git diff -- app/pubspec.yaml app/pubspec.lock
```

Expected: only the four owner items remain dirty before Task 1 starts.

---

### Task 1: Atomic JW Job Arbiter

**Files:**
- Create: `app/lib/features/sync/runtime/jw_job_arbiter.dart`
- Test: `app/test/features/sync/runtime/jw_job_arbiter_test.dart`

**Interfaces:**
- Consumes: stable public error code `bridge_busy`.
- Produces:
  - `enum JwJobKind { firstLogin, sync, pythonFallback, maintenance }`
  - `final class JwJobLease { String jobId; JwJobKind kind; }`
  - `JwJobLease JwJobArbiter.acquire({required String jobId, required JwJobKind kind})`
  - `void JwJobArbiter.release(JwJobLease lease)`
  - `bool get JwJobArbiter.isBusy`

- [ ] **Step 1: Write the failing arbiter tests**

```dart
test('acquire is synchronous and a second job fails with bridge_busy', () {
  final arbiter = JwJobArbiter();
  final first = arbiter.acquire(jobId: 'job-1', kind: JwJobKind.sync);
  expect(
    () => arbiter.acquire(jobId: 'job-2', kind: JwJobKind.firstLogin),
    throwsA(isA<BridgeProtocolError>().having((e) => e.code, 'code', 'bridge_busy')),
  );
  arbiter.release(first);
});

test('foreign release cannot free the held lease', () {
  final arbiter = JwJobArbiter();
  final held = arbiter.acquire(jobId: 'held', kind: JwJobKind.sync);
  final other = JwJobArbiter();
  final foreign = other.acquire(jobId: 'foreign', kind: JwJobKind.sync);
  expect(() => arbiter.release(foreign), throwsStateError);
  expect(arbiter.isBusy, isTrue);
  arbiter.release(held);
  other.release(foreign);
});
```

- [ ] **Step 2: Run RED**

Run:

```powershell
& 'E:\flutter\flutter\bin\flutter.bat' test --no-pub --reporter expanded test/features/sync/runtime/jw_job_arbiter_test.dart
```

Expected: compile failure because `JwJobArbiter` does not exist.

- [ ] **Step 3: Implement the minimal synchronous owner**

```dart
final class JwJobArbiter {
  JwJobLease? _held;

  bool get isBusy => _held != null;

  JwJobLease acquire({required String jobId, required JwJobKind kind}) {
    if (jobId.isEmpty) throw StateError('job id is empty');
    if (_held != null) throw const BridgeProtocolError('bridge_busy');
    return _held = JwJobLease._(jobId: jobId, kind: kind);
  }

  void release(JwJobLease lease) {
    if (lease._released) return;
    if (!identical(_held, lease)) throw StateError('foreign lease');
    lease._released = true;
    _held = null;
  }
}
```

Do not add async mutexes or waiter queues; callers either hold the single lease or receive `bridge_busy`.

- [ ] **Step 4: Run GREEN**

Run the Task 1 test file. Expected: all tests pass.

- [ ] **Step 5: Commit**

```powershell
git add app/lib/features/sync/runtime/jw_job_arbiter.dart app/test/features/sync/runtime/jw_job_arbiter_test.dart
git commit -m "feat(webview-minimal): add atomic JW job arbiter"
```

---

### Task 2: Contained Windows JW UDF Store

**Files:**
- Create: `app/lib/features/sync/native/windows_jw_udf_store.dart`
- Test: `app/test/features/sync/native/windows_jw_udf_store_test.dart`
- Read-only reference: `rewrite/flutter-native/app/lib/containers/platform/windows/webview2/windows_webview_udf_store.dart`

**Interfaces:**
- Consumes: application-support root and release-complete signal from Task 3.
- Produces:
  - `final class JwSessionPartitionRef { String opaqueToken; }`
  - `JwSessionPartitionRef WindowsJwUdfStore.referenceFor(String accountId)`
  - `Future<Directory> ensurePartition(JwSessionPartitionRef ref)`
  - `Future<void> markQuarantined(JwSessionPartitionRef ref, String safeCode)`
  - `Future<bool> isQuarantined(JwSessionPartitionRef ref)`
  - `Future<void> clearPartition(JwSessionPartitionRef ref)`
  - `Future<void> clearAllPartitions()`

- [ ] **Step 1: Write failing containment and retry tests**

```dart
test('reference uses an opaque jw digest and never account text', () {
  final ref = store.referenceFor('private-account');
  expect(ref.opaqueToken, matches(RegExp(r'^jw_[0-9a-f]{24}$')));
  expect(ref.opaqueToken, isNot(contains('private-account')));
});

test('clear all attempts later partitions after the first deletion fails', () async {
  final attempted = <String>[];
  final store = WindowsJwUdfStore(
    privateRoot: root,
    deleteDirectory: (directory) async {
      attempted.add(directory.path);
      if (attempted.length == 1) throw const FileSystemException('locked');
      await directory.delete(recursive: true);
    },
    releaseDelay: (_) async {},
    releaseAttempts: 1,
  );
  await expectLater(store.clearAllPartitions(), throwsA(isA<JwUdfClearError>()));
  expect(attempted, hasLength(2));
});
```

Also cover root deletion refusal, nested/non-token child refusal, symlink/reparse refusal, Win32 5/32 bounded retry, unknown error single-shot, quarantine marker removal, and retry after partial failure.

- [ ] **Step 2: Run RED**

Run the new test file serially. Expected: compile failure for missing store types.

- [ ] **Step 3: Implement opaque containment and fail-closed clear-all**

```dart
Future<void> clearAllPartitions() async {
  Object? firstFailure;
  StackTrace? firstStack;
  for (final ref in await listOwnedPartitions()) {
    try {
      await clearPartition(ref);
    } on Object catch (error, stack) {
      firstFailure ??= error;
      firstStack ??= stack;
    }
  }
  if (firstFailure != null) {
    Error.throwWithStackTrace(const JwUdfClearError('browser_cleanup_incomplete'), firstStack!);
  }
}
```

`listOwnedPartitions` accepts only direct `jw_[0-9a-f]{24}` children under the canonical root. Unknown entries make the operation fail closed; no path appears in the public error.

- [ ] **Step 4: Run GREEN and Windows-specific focused tests**

Expected: all UDF tests pass without touching a real user profile.

- [ ] **Step 5: Commit**

```powershell
git add app/lib/features/sync/native/windows_jw_udf_store.dart app/test/features/sync/native/windows_jw_udf_store_test.dart
git commit -m "feat(webview-minimal): contain JW browser partitions"
```

---

### Task 3: Browser Session Admin Owns Controller and Release

**Files:**
- Create: `app/lib/features/sync/native/jw_browser_session_admin.dart`
- Create: `app/lib/features/sync/native/windows_jw_browser_session_admin.dart`
- Modify: `app/lib/features/sync/native/jw_webview_adapter.dart`
- Modify: `app/lib/features/sync/native/jw_webview_surface_host.dart`
- Modify: `app/lib/features/sync/data/bridge_client.dart`
- Test: `app/test/features/sync/native/windows_jw_browser_session_admin_test.dart`
- Test: `app/test/features/sync/native/jw_webview_adapter_test.dart`
- Test: `app/test/features/sync/bridge_client_test.dart`

**Interfaces:**
- Consumes: `WindowsJwUdfStore`, existing `JwWebPage`, adapter/controller factory and surface host.
- Produces:

```dart
abstract interface class JwBrowserSessionHandle {
  JwWebPage get page;
  JwSessionPartitionRef get partition;
  Future<void> close();
}

abstract interface class JwBrowserSessionAdmin {
  JwWebViewSurfaceHost get surfaceHost;
  Future<JwBrowserSessionHandle> open(String accountId);
  Future<void> clearAllPartitions();
  Future<void> shutdown();
}
```

- [ ] **Step 1: Write failing ownership tests**

Test exact ordering:

```dart
expect(events, [
  'surface.detach',
  'controller.stop',
  'subscriptions.dispose',
  'controller.dispose_and_release',
]);
```

Also prove one live session only, factory failure quarantines the partition, detach/release failure retains the handle for retry, close is idempotent, and `clearAllPartitions` refuses to call the store until every live handle releases successfully.

- [ ] **Step 2: Run RED**

Run admin and adapter tests. Expected: missing admin interfaces/classes.

- [ ] **Step 3: Implement admin and narrow adapter ownership**

```dart
Future<JwBrowserSessionHandle> open(String accountId) async {
  if (_live != null) throw const BridgeProtocolError('bridge_busy');
  final ref = udfStore.referenceFor(accountId);
  if (await udfStore.isQuarantined(ref)) {
    throw const BridgeProtocolError('browser_session_quarantined');
  }
  final directory = await udfStore.ensurePartition(ref);
  final handle = await _openAndAttach(ref, directory.path);
  return _live = handle;
}
```

On close, keep `_live` until `disposeControllerAndAwaitRelease` succeeds. Attempt all cleanup stages and rethrow the first privacy-safe failure.
Add `browser_session_quarantined` to the allow-list in `bridge_client.dart`, so
the public code in the example remains stable instead of being normalized to
`request_failed`.

- [ ] **Step 4: Run GREEN**

Run admin, adapter and surface-host focused suites. Expected: all pass.

- [ ] **Step 5: Commit**

```powershell
git add app/lib/features/sync/native/jw_browser_session_admin.dart app/lib/features/sync/native/windows_jw_browser_session_admin.dart app/lib/features/sync/native/jw_webview_adapter.dart app/lib/features/sync/native/jw_webview_surface_host.dart app/lib/features/sync/data/bridge_client.dart app/test/features/sync/native app/test/features/sync/bridge_client_test.dart
git commit -m "refactor(webview-minimal): centralize browser session ownership"
```

---

### Task 4: App-Owned Minimal JW Runtime

**Files:**
- Create: `app/lib/features/sync/runtime/minimal_jw_runtime.dart`
- Create: `app/lib/features/sync/runtime/minimal_jw_runtime_scope.dart`
- Modify: `app/lib/app/app.dart`
- Modify: `app/lib/app/router.dart`
- Test: `app/test/features/sync/runtime/minimal_jw_runtime_test.dart`
- Test: `app/test/app/app_shell_test.dart`

**Interfaces:**
- Consumes: Task 1 arbiter and Task 3 session admin.
- Produces:

```dart
final class MinimalJwRuntime {
  MinimalJwRuntime({required this.gateway, required this.browserSessions});
  final SourceJobGateway gateway;
  final JwBrowserSessionAdmin browserSessions;
  JwWebViewSurfaceHost get surfaceHost => browserSessions.surfaceHost;
  Future<void> shutdown();
}

final class MinimalJwRuntimeOwner {
  MinimalJwRuntimeOwner(Future<MinimalJwRuntime> Function() loader);
  Future<MinimalJwRuntime> get current;
  Future<void> beginShutdown();
  Future<void> replaceAfterReset();
}

final class MinimalJwRuntimeScope extends InheritedWidget {
  static MinimalJwRuntime of(BuildContext context);
}
```

- [ ] **Step 1: Write failing app-ownership tests**

Prove `/sync` push/pop/reopen and `/sync/reauthenticate` reuse the same runtime identity and never invoke a second runtime loader. Prove app disposal starts exactly one shutdown, exposes that future to the composition owner for test/exit awaiting, and immediately shuts down a runtime whose loader completes late.

- [ ] **Step 2: Run RED**

Expected: no runtime scope exists and the route still constructs page-owned gateways.

- [ ] **Step 3: Implement the app composition owner**

```dart
class _UstcAssistantAppState extends State<UstcAssistantApp> {
  late final MinimalJwRuntimeOwner _runtimeOwner =
      MinimalJwRuntimeOwner(widget.runtimeLoader);

  @override
  void dispose() {
    unawaited(_runtimeOwner.beginShutdown());
    super.dispose();
  }
}
```

The production root must observe shutdown errors through a privacy-safe sink,
and the Windows exit/reset path must await the owner's `beginShutdown`.
`replaceAfterReset` first awaits the old runtime shutdown, then installs exactly
one newly loaded runtime; it is callable only after reset cleanup succeeds.
Router builders
receive the borrowed runtime/scope only; remove route-local `NativeJwGateway`
factories.

- [ ] **Step 4: Run GREEN**

Run runtime and app shell tests. Expected: one runtime load and one shutdown across navigation.

- [ ] **Step 5: Commit**

```powershell
git add app/lib/features/sync/runtime/minimal_jw_runtime.dart app/lib/features/sync/runtime/minimal_jw_runtime_scope.dart app/lib/app/app.dart app/lib/app/router.dart app/test/features/sync/runtime app/test/app/app_shell_test.dart
git commit -m "refactor(webview-minimal): own JW runtime at app scope"
```

---

### Task 5: One UI-Facing Source Job Gateway

**Files:**
- Create: `app/lib/features/sync/runtime/source_job_gateway.dart`
- Modify: `app/lib/features/sync/runtime/minimal_jw_runtime.dart`
- Modify: `app/lib/features/sync/native/native_jw_gateway.dart`
- Modify: `app/lib/features/sync/application/sync_coordinator.dart`
- Modify: `app/lib/features/sync/presentation/sync_page.dart`
- Test: `app/test/features/sync/runtime/source_job_gateway_test.dart`
- Test: `app/test/features/sync/native/native_jw_gateway_test.dart`
- Test: `app/test/features/sync/sync_page_test.dart`

**Interfaces:**
- Consumes: Task 1 arbiter, Task 3 session admin, existing `SyncOutcome` and `SyncCoordinator`.
- Produces:

```dart
abstract interface class SourceJobGateway {
  Stream<SourceJobSnapshot> get states;
  Future<SyncOutcome> firstLogin(FirstLoginCommand command);
  Future<SyncOutcome> sync({required String accountId, required SyncTrigger trigger});
  Future<void> cancelCurrent();
  Future<void> shutdown();
}
```

`FirstLoginCommand` contains username, optional password and save-password flag. `SourceJobSnapshot` contains only stable phase, safe code and non-negative aggregate count.

- [ ] **Step 1: Write failing gateway tests**

Cover Native/Python mutual exclusion under the same arbiter, overlapping
login/sync returning `bridge_busy`, cancel awaiting terminal settlement,
shutdown attempting cancel/session-close even after an earlier error, and
emitted snapshots containing no request values. Both first login and an
existing-account sync must enforce strict verified-identity equality; an
identity mismatch or a course-only/exam-only partial result returns a stable
failure and writes no bundle rows.

- [ ] **Step 2: Run RED**

Expected: the UI still talks directly to `SyncCoordinator`/route-owned native gateway.

- [ ] **Step 3: Implement the gateway adapter**

```dart
Future<SyncOutcome> sync({required String accountId, required SyncTrigger trigger}) async {
  final lease = arbiter.acquire(jobId: ids.next(), kind: selectedKind);
  try {
    return await coordinator.sync(
      SyncSource.jw,
      trigger: trigger,
      accountId: accountId,
    );
  } finally {
    arbiter.release(lease);
  }
}
```

Move bridge selection into runtime composition by injecting the selected
`BridgeGateway` factory into the one coordinator; `selectedKind` is
`pythonFallback` only for that explicit composition, otherwise `sync`. Remove
gateway creation and UDF path logic from `sync_page.dart`.

- [ ] **Step 4: Run GREEN**

Run gateway, coordinator and SyncPage focused suites. Expected: one runtime gateway and no direct controller/page factory in presentation code.

- [ ] **Step 5: Commit**

```powershell
git add app/lib/features/sync/runtime/source_job_gateway.dart app/lib/features/sync/runtime/minimal_jw_runtime.dart app/lib/features/sync/native/native_jw_gateway.dart app/lib/features/sync/application/sync_coordinator.dart app/lib/features/sync/presentation/sync_page.dart app/test/features/sync
git commit -m "refactor(webview-minimal): route JW work through one gateway"
```

---

### Task 6: Atomic Provisional First-Login Commit

**Files:**
- Create: `app/lib/features/accounts/application/first_login_commit_service.dart`
- Modify: `app/lib/features/accounts/application/account_service.dart`
- Modify: `app/lib/features/import/application/import_service.dart`
- Modify: `app/lib/features/sync/application/sync_coordinator.dart`
- Test: `app/test/features/accounts/first_login_commit_service_test.dart`
- Test: `app/test/features/import/import_service_test.dart`
- Test: `app/test/features/sync/sync_coordinator_test.dart`

**Interfaces:**
- Consumes: verified username and complete bundle bytes from Task 5.
- Produces:

```dart
final class ProvisionalFirstLogin {
  final String accountId;
  final String expectedUsername;
  Uint8List? passwordBytes;
  final bool savePassword;
  void discard();
}

final class PreparedSourceBundle {
  final SourceBundle bundle;
}

Future<PreparedSourceBundle> ImportService.prepare(Uint8List bytes);
Future<ImportResult> ImportService.persistPrepared(
  PreparedSourceBundle prepared, {
  required String accountId,
  required ImportOrigin origin,
});

typedef PreparedBundlePersist = Future<ImportResult> Function(
  PreparedSourceBundle prepared, {
  required String accountId,
  required ImportOrigin origin,
});

Future<FirstLoginCommitResult> FirstLoginCommitService.commit({
  required ProvisionalFirstLogin provisional,
  required String verifiedUsername,
  required PreparedSourceBundle prepared,
});
```

`FirstLoginCommitService` receives `PreparedBundlePersist` in its constructor;
production binds it to `ImportService.persistPrepared`, while rollback tests
inject a closure that throws after the account/credential inserts.

- [ ] **Step 1: Write failing atomicity tests**

Use the existing valid JW fixture for prepared-success cases and `{}` bytes for
prepare failure. After each prepare failure, identity mismatch, injected
repository persistence failure, and cancellation-before-commit case, assert
`localAccounts`, `credentialAccounts`, `calendarEvents`, `importBatches`, and
`syncRuns` are empty. Also cover saved-password false, secret byte zeroing, and
success committing exactly one account, credential metadata row, import batch,
and completed sync run in one transaction. The persistence-failure test injects
a `PreparedBundlePersist` closure that throws `StateError('persist_failed')`
after the earlier transactional inserts; the error is test-only and never
displayed or logged.

- [ ] **Step 2: Run RED**

Expected: current `_consume` calls `confirmSuccessfulLogin` before `importBundle`, leaving account rows if import later fails.

- [ ] **Step 3: Split prepare from persistence and commit in one transaction**

`prepare` performs schema/subject validation without writes.
`persistPrepared` performs no nested `database.transaction` call: its caller
owns the transaction. `FirstLoginCommitService.commit` verifies identity,
protects credentials, and calls `persistPrepared` inside the same Drift
transaction that inserts the single account and sync record. Reminder
reconciliation runs only after commit; a reminder failure records the existing
retryable marker without rolling back imported data. The `finally` block zeroes
protected/plain password buffers and discards provisional state.

- [ ] **Step 4: Run GREEN**

Run account, import and coordinator focused tests. Expected: no partial rows on every failure path.

- [ ] **Step 5: Commit**

```powershell
git add app/lib/features/accounts/application/first_login_commit_service.dart app/lib/features/accounts/application/account_service.dart app/lib/features/import/application/import_service.dart app/lib/features/sync/application/sync_coordinator.dart app/test/features/accounts app/test/features/import/import_service_test.dart app/test/features/sync/sync_coordinator_test.dart
git commit -m "feat(webview-minimal): commit first login atomically"
```

---

### Task 7: Fixed Minimal Reset Coordinator

**Files:**
- Create: `app/lib/features/settings/application/minimal_reset_coordinator.dart`
- Modify: `app/lib/features/settings/application/settings_service.dart`
- Modify: `app/lib/features/agent/application/agent_session_service.dart`
- Modify: `app/lib/features/agent/application/agent_composition.dart`
- Modify: `app/lib/features/reminders/application/windows_reminder_reconciler.dart`
- Modify: `app/lib/features/sync/application/sync_coordinator.dart`
- Modify: `app/lib/features/sync/runtime/minimal_jw_runtime.dart`
- Test: `app/test/features/settings/minimal_reset_coordinator_test.dart`
- Test: existing Agent, reminder and sync lifecycle tests.

**Interfaces:**
- Consumes: fixed runtime/writer dependencies and Task 2 UDF clear-all.
- Produces:

```dart
abstract interface class ResetWriterPort {
  Future<void> quiesce();
  Future<void> resume();
}

enum MinimalResetPhase { idle, quiescing, clearingDatabase, clearingBrowser, failed }

final class MinimalResetCoordinator {
  Stream<MinimalResetPhase> get phases;
  Future<void> completeReset();
  Future<void> retryReset();
}
```

Constructor dependencies are explicit: `MinimalJwRuntime`, `SyncCoordinator`,
`AgentSessionService`, `WindowsReminderReconciler`, `SettingsService`,
`WindowsJwUdfStore`, plus a
`Future<void> Function() recomposeRuntime` callback owned by the app
composition root. Do not add a registration API.

- [ ] **Step 1: Write failing race/failure tests**

Cover active JW, import, Agent and reminder writers; `/sync` exit followed immediately by reset; quiesce failure; database already empty on UDF retry; first UDF failure while later UDF is attempted; no writer resume or fresh runtime on failure; all writers resume only after full success.

```dart
expect(events, [
  'jw.cancel_and_settle',
  'jw.shutdown_and_release',
  'sync.quiesce',
  'agent.quiesce',
  'reminder.quiesce',
  'database.clear_all',
  'udf.clear_all',
  'runtime.recompose',
]);
```

- [ ] **Step 2: Run RED**

Expected: current reset has no fixed quiesce barrier and can report success after incomplete UDF cleanup.

- [ ] **Step 3: Implement fixed ordering and failed maintenance**

```dart
Future<void> completeReset() async {
  if (_phase == MinimalResetPhase.failed) return retryReset();
  _setPhase(MinimalResetPhase.quiescing);
  await runtime.shutdown();
  await sync.quiesce();
  await agent.quiesce();
  await reminders.quiesce();
  try {
    _setPhase(MinimalResetPhase.clearingDatabase);
    await settings.clearAllLocalData();
    _setPhase(MinimalResetPhase.clearingBrowser);
    await udfStore.clearAllPartitions();
  } on Object {
    _setPhase(MinimalResetPhase.failed);
    rethrow;
  }
  await recomposeRuntime();
  await sync.resume();
  await agent.resume();
  await reminders.resume();
  _setPhase(MinimalResetPhase.idle);
}
```

The app composition callback installs a fresh runtime before writer admission is
reopened. No resume call is reached on failure. Keep DB clear idempotent so
`retryReset` safely repeats after partial success.

- [ ] **Step 4: Run GREEN**

Run reset, Agent, reminder, sync and runtime suites. Expected: deterministic order and no post-delete writes.

- [ ] **Step 5: Commit**

```powershell
git add app/lib/features/settings/application/minimal_reset_coordinator.dart app/lib/features/settings/application/settings_service.dart app/lib/features/agent/application/agent_session_service.dart app/lib/features/agent/application/agent_composition.dart app/lib/features/reminders/application/windows_reminder_reconciler.dart app/lib/features/sync/application/sync_coordinator.dart app/lib/features/sync/runtime/minimal_jw_runtime.dart app/test/features/settings app/test/features/agent app/test/features/reminders app/test/features/sync
git commit -m "feat(webview-minimal): serialize complete reset"
```

---

### Task 8: Explicit UI Recovery State Machine

**Files:**
- Modify: `app/lib/features/sync/presentation/sync_page.dart`
- Modify: `app/lib/features/settings/presentation/settings_page.dart`
- Modify: `app/lib/app/router.dart`
- Modify: chat/accounts unconfigured widgets that currently show only text.
- Test: `app/test/features/sync/sync_page_test.dart`
- Test: `app/test/features/settings/settings_test.dart`
- Test: `app/test/app/app_shell_test.dart`

**Interfaces:**
- Consumes: `SourceJobGateway`, `MinimalResetCoordinator.phases`, and app-owned runtime scope.
- Produces:

```dart
enum MinimalAppPhase {
  preparing,
  unconfigured,
  loginVisible,
  collecting,
  configured,
  resetting,
  resetFailed,
}

final class MinimalAppViewState {
  final MinimalAppPhase phase;
  final String? safeCode;
}
```

- [ ] **Step 1: Write failing route/state tests**

Cover:

- no-account Chat and Settings expose `登录教务` and `清除全部数据`;
- both reset confirmations are required;
- cancelling either confirmation shows `已取消重新登录` and performs no deletion;
- `resetFailed` exposes only safe error/retry/exit and does not create runtime/writers;
- pop during shutdown does not invoke stale navigation or clear a disposed controller;
- successful reset returns to one `unconfigured` state and login opens the borrowed surface.

- [ ] **Step 2: Run RED**

Expected: presentation still owns dependency loaders and lacks a single reset-failed state.

- [ ] **Step 3: Render the state machine without lifecycle ownership**

```dart
switch (viewState.phase) {
  case MinimalAppPhase.unconfigured:
    return UnconfiguredActions(onLogin: openSync, onReset: confirmReset);
  case MinimalAppPhase.resetFailed:
    return ResetRecoveryView(
      safeCode: viewState.safeCode,
      onRetry: resetCoordinator.retryReset,
      onExit: exitApp,
    );
  case MinimalAppPhase.loginVisible || MinimalAppPhase.collecting:
    return SyncView(gateway: runtime.gateway, surface: runtime.surfaceHost);
  default:
    return const ProgressView();
}
```

Every post-await UI mutation checks `mounted`. Password controllers are cleared before dispose or only while mounted.

- [ ] **Step 4: Run GREEN**

Run SyncPage, Settings and app shell tests. Expected: all routes use the same runtime and recovery is reachable without an account.

- [ ] **Step 5: Commit**

```powershell
git add app/lib/features/sync/presentation/sync_page.dart app/lib/features/settings/presentation/settings_page.dart app/lib/app/router.dart app/lib/features/accounts app/lib/features/agent/presentation app/test/features/sync/sync_page_test.dart app/test/features/settings/settings_test.dart app/test/app/app_shell_test.dart
git commit -m "feat(webview-minimal): expose recoverable JW runtime states"
```

---

### Task 9: Documentation, Full Gates, and Real-Acceptance Handoff

**Files:**
- Modify: `docs/plan-webview-minimal-m7-webview2.md`
- Modify: `docs/m6-external-machine-handoff.md`
- Modify: `docs/acceptance/read-only-agent.md`
- Test: `app/integration_test/minimal_jw_webview_loopback_test.dart`

**Interfaces:**
- Consumes all Tasks 1–8.
- Produces final automated evidence and a manual stage checklist; it does not claim campus acceptance.

- [ ] **Step 1: Extend the real Windows loopback**

Add assertions for app-owned runtime reuse, atomic first-login commit, reset shutdown/release/UDF clear, reset-failed retry, and no residual process/UDF.

- [ ] **Step 2: Run focused Native/Runtime/Reset suites**

Run serially with `--concurrency=1` when diagnosing lifecycle failures. Expected: all focused tests pass with no privacy-sensitive output.

- [ ] **Step 3: Run the real Windows Debug WebView2 loopback**

```powershell
& 'E:\flutter\flutter\bin\flutter.bat' test --no-pub --reporter expanded integration_test/minimal_jw_webview_loopback_test.dart -d windows
```

Expected: one complete portal/CAS/course/exam/bundle/reset lifecycle, exit 0, no residual target process, UDF child count 0.

- [ ] **Step 4: Run Python oracle from the current worktree**

Set process-only `PYTHONPATH` to `E:\107\.worktrees\refactor-webview-minimal\src`, print/assert `ustc_assistant.__file__` is below that root, then run:

```powershell
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
```

Expected: 140 tests pass and compileall exits 0.

- [ ] **Step 5: Run the exact sequential Flutter gate**

From the minimal worktree `app/`, in one PowerShell terminal:

```powershell
$ErrorActionPreference = 'Stop'
$FlutterExe = 'E:\flutter\flutter\bin\flutter.bat'
$AppDir = 'E:\107\.worktrees\refactor-webview-minimal\app'
$env:HTTP_PROXY = 'http://127.0.0.1:7897'
$env:HTTPS_PROXY = 'http://127.0.0.1:7897'
$env:NO_PROXY = '127.0.0.1,localhost'

Push-Location $AppDir
try {
    & $FlutterExe analyze --no-pub
    if ($LASTEXITCODE -ne 0) { throw "flutter analyze failed: $LASTEXITCODE" }

    & $FlutterExe test --no-pub --reporter expanded
    if ($LASTEXITCODE -ne 0) { throw "flutter test failed: $LASTEXITCODE" }

    & $FlutterExe build windows --release --no-pub
    if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed: $LASTEXITCODE" }
}
finally {
    Pop-Location
}
```

Stop after the first nonzero exit. Before build, verify the worktree Release app is not running. Do not start a second Flutter command because of silence.

- [ ] **Step 6: Update documentation with exact results**

Document runtime ownership, single-account reset, provisional login, failure recovery, exact automated counts, Release artifact, and remaining external boundaries. Do not include credentials, queries, DOM, response bodies, or private schedule content.

- [ ] **Step 7: Commit documentation and integration test**

```powershell
git add app/integration_test/minimal_jw_webview_loopback_test.dart docs/plan-webview-minimal-m7-webview2.md docs/m6-external-machine-handoff.md docs/acceptance/read-only-agent.md
git commit -m "docs(webview-minimal): hand off targeted runtime acceptance"
```

- [ ] **Step 8: Perform final whole-branch review**

Review from the execution base through Task 9. Fix all Critical/Important findings, rerun affected focused tests, and repeat the final serial gate after any code change.

- [ ] **Step 9: Resume real-campus acceptance only after automated GREEN**

The user enters credentials in the visible Release app. Record only:

```text
CAS entry -> identity verified -> course count -> exam count
-> bundle built -> imported -> schedule/exams visible
```

If any stage fails, stop, preserve the safe code/stage, and return to systematic debugging. Do not call this accepted until the entire chain is observed.
