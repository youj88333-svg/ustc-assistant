# Minimal JW WebView Reachability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the minimal Windows app complete a stable WebView2 JW login, collection, SourceBundle 1.0 import, and safe teardown without native crashes or permissive false readiness.

**Architecture:** Keep the existing minimal `SyncCoordinator -> NativeJwGateway -> JwCollector -> JwWebViewAdapter -> SourceBundle builder -> ImportService` chain. Add a stable surface host and strict lifecycle ownership, align login/readiness/request contracts with the accepted full-branch implementation, and prove the native texture lifecycle with a Debug-only Windows loopback integration test.

**Tech Stack:** Flutter 3.44.5, Dart 3.12.2, Windows WebView2, local `webview_flutter_windows_secure` package, Drift/SQLite, Flutter unit/widget/integration tests, C++23 GoogleTest for the plugin policy.

**Spec:** `docs/superpowers/specs/2026-08-28-minimal-jw-webview-reachability-design.md`

## Global Constraints

- Modify only `E:\107\.worktrees\refactor-webview-minimal` and its children.
- Read `E:\107\.worktrees\rewrite\flutter-native` only as a reference.
- Preserve all pre-existing uncommitted changes; never reset, checkout, or bulk-stage them.
- Stage only the exact files listed in each task.
- Preserve Python Bridge fallback and one-source-one-channel behavior.
- Keep semester `461 / 2026fall / 2026 秋季学期`; never derive the JW semester ID.
- Keep SourceBundle 1.0, `Asia/Shanghai`, existing `ImportService`, and account partitioning.
- Never log URL queries, CAS tickets, cookies, DOM text, usernames, data IDs, raw responses, or course data.
- Use the existing dependencies; do not run `pub get` unless `pubspec.yaml`, the local path package declaration, or a dependency version actually changes.
- Run Flutter commands serially in one terminal from `app/`, with `--no-pub`; stop on the first failed gate.
- Tests follow strict red-green-refactor: run each new test before implementation and confirm the expected behavioral failure.
- Automatic and loopback results must never be reported as real-campus acceptance.

---

### Task 1: Stable WebView Surface Host

**Files:**
- Create: `app/lib/features/sync/native/jw_webview_surface_host.dart`
- Create: `app/test/features/sync/native/jw_webview_surface_host_test.dart`

**Interfaces:**
- Consumes: `JwWebviewController.surface : Widget` from `jw_web_session.dart`.
- Produces: `JwWebViewSurfaceHost.widget`, `attach(JwWebviewController)`, `detachAndAwaitUnmount(JwWebviewController)`, and `isAttached`.

- [ ] **Step 1: Write the failing mounted-detach tests**

Create widget tests that use two fake controllers with distinct keyed surfaces:

```dart
testWidgets('detach completes only after placeholder frame', (tester) async {
  final host = JwWebViewSurfaceHost();
  final controller = _SurfaceController(const Key('surface-a'));
  await tester.pumpWidget(MaterialApp(home: host.widget));
  await host.attach(controller);
  await tester.pump();
  expect(find.byKey(const Key('surface-a')), findsOneWidget);

  var completed = false;
  final detach = host.detachAndAwaitUnmount(controller);
  detach.then((_) => completed = true);
  await Future<void>.microtask(() {});
  expect(completed, isFalse);
  await tester.pump();
  await detach;
  expect(completed, isTrue);
  expect(find.byKey(const Key('jw-webview-surface-placeholder')), findsOneWidget);
});

testWidgets('replacement waits for previous generation to unmount', (tester) async {
  final host = JwWebViewSurfaceHost();
  final first = _SurfaceController(const Key('surface-a'));
  final second = _SurfaceController(const Key('surface-b'));
  await tester.pumpWidget(MaterialApp(home: host.widget));
  await host.attach(first);
  await tester.pump();
  final detach = host.detachAndAwaitUnmount(first);
  final attach = host.attach(second);
  await tester.pump();
  await detach;
  await attach;
  await tester.pump();
  expect(find.byKey(const Key('surface-a')), findsNothing);
  expect(find.byKey(const Key('surface-b')), findsOneWidget);
});

testWidgets('host disposal releases pending detach', (tester) async {
  final host = JwWebViewSurfaceHost();
  final controller = _SurfaceController(const Key('surface-a'));
  await tester.pumpWidget(MaterialApp(home: host.widget));
  await host.attach(controller);
  await tester.pump();
  final detach = host.detachAndAwaitUnmount(controller);
  await tester.pumpWidget(const SizedBox());
  await detach;
  expect(host.isAttached, isFalse);
});
```

The fake implements every `JwWebviewController` member with inert streams and `surface => SizedBox(key: key)`; no mock framework is needed.

- [ ] **Step 2: Run the new test and verify RED**

Run:

```powershell
& 'E:\flutter\flutter\bin\flutter.bat' test --no-pub --reporter expanded test/features/sync/native/jw_webview_surface_host_test.dart
```

Expected: compile failure because `JwWebViewSurfaceHost` does not exist.

- [ ] **Step 3: Implement the minimal generation-aware host**

Implement one stable `_JwSurfaceWidget` and these state transitions:

```dart
final class JwWebViewSurfaceHost {
  JwWebViewSurfaceHost() { widget = _JwSurfaceWidget(host: this); }

  late final Widget widget;
  JwWebviewController? _controller;
  VoidCallback? _notify;
  Completer<void>? _pendingUnmount;
  JwWebviewController? _pendingSource;
  int _generation = 0;
  int? _pendingGeneration;

  bool get isAttached => _controller != null;

  Future<void> attach(JwWebviewController controller) async {
    final pending = _pendingUnmount;
    if (pending != null) await pending.future;
    if (_controller != null && !identical(_controller, controller)) {
      throw StateError('A WebView surface is already attached.');
    }
    _generation++;
    _controller = controller;
    _notify?.call();
  }

  Future<void> detachAndAwaitUnmount(JwWebviewController controller) {
    final pending = _pendingUnmount;
    if (pending != null && identical(_pendingSource, controller)) {
      return pending.future;
    }
    if (!identical(_controller, controller)) return Future<void>.value();
    _generation++;
    _controller = null;
    if (_notify == null) return Future<void>.value();
    final completer = Completer<void>();
    _pendingUnmount = completer;
    _pendingSource = controller;
    _pendingGeneration = _generation;
    _notify!.call();
    return completer.future;
  }
}
```

`_buildSurface()` returns `controller.surface` when attached; otherwise it returns `SizedBox(key: Key('jw-webview-surface-placeholder'))` and schedules one post-frame callback that completes only the matching pending generation. Widget disposal clears its listener and completes any pending detach.

- [ ] **Step 4: Run the surface-host tests and verify GREEN**

Run the Step 2 command. Expected: all three tests pass.

- [ ] **Step 5: Commit only the host and its test**

```powershell
git add -- app/lib/features/sync/native/jw_webview_surface_host.dart app/test/features/sync/native/jw_webview_surface_host_test.dart
git commit -m "fix(webview-minimal): stabilize native WebView surface"
```

---

### Task 2: Gateway Controller, Account UDF, and Teardown Ownership

**Files:**
- Modify: `app/lib/features/sync/native/native_jw_gateway.dart`
- Modify: `app/lib/features/sync/native/jw_webview_adapter.dart`
- Modify: `app/test/features/sync/native/native_jw_gateway_test.dart`

**Interfaces:**
- Consumes: `JwWebViewSurfaceHost` from Task 1 and the existing `BridgeGateway` API.
- Produces: `NativeJwGateway.surfaceHost`, account-bound controller creation, idempotent `shutdown()`, and per-job settlement futures.

- [ ] **Step 1: Add failing lifecycle-order tests**

Extend the gateway fake controller with a `calls` list. Add:

```dart
testWidgets('shutdown detaches mounted surface before controller disposal', (tester) async {
  final calls = <String>[];
  final controller = FakeJwWebviewController(calls: calls)
    ..authenticatedSession = true
    ..courseDatum = courseDatum
    ..examHtml = examHtml;
  final gateway = NativeJwGateway(controllerFactory: () async => controller);
  await tester.pumpWidget(MaterialApp(home: gateway.surfaceHost.widget));
  final job = await gateway.startCollection(
    source: SyncSource.jw,
    accountId: 'opaque-account-a',
    expectedUsername: 'PB00000000',
    jwSemester: kDefaultJwSemester,
  );
  await tester.pump();
  await _pollUntilTerminal(gateway, job.id);

  final shutdown = gateway.shutdown();
  await Future<void>.microtask(() {});
  expect(calls, isNot(contains('dispose')));
  await tester.pump();
  await shutdown;
  expect(calls.indexOf('stop'), lessThan(calls.indexOf('dispose')));
});

test('controller factory receives one account partition per lifecycle', () async {
  final requestedAccounts = <String>[];
  final gateway = NativeJwGateway(
    userDataPathForAccount: (accountId) async {
      requestedAccounts.add(accountId);
      return 'test-udf/$accountId';
    },
    productionControllerFactory: ({required userDataPath, required safeDiagnostic}) async =>
        FakeJwWebviewController()..authenticatedSession = true
          ..courseDatum = courseDatum..examHtml = examHtml,
  );
  final job = await gateway.startCollection(
    source: SyncSource.jw,
    accountId: 'opaque-account-a',
    expectedUsername: 'PB00000000',
    jwSemester: kDefaultJwSemester,
  );
  await _pollUntilTerminal(gateway, job.id);
  expect(requestedAccounts, ['opaque-account-a']);
  await gateway.shutdown();
});
```

The second test asserts only the opaque account-routing argument, never a physical profile path.

- [ ] **Step 2: Run the gateway tests and verify RED**

```powershell
& 'E:\flutter\flutter\bin\flutter.bat' test --no-pub --reporter expanded test/features/sync/native/native_jw_gateway_test.dart
```

Expected: compile failures for `surfaceHost`, `userDataPathForAccount`, and `productionControllerFactory`.

- [ ] **Step 3: Implement account-bound controller creation and attachment**

Add:

```dart
typedef ProductionJwControllerFactory = Future<JwWebviewController> Function({
  required String? userDataPath,
  required void Function(String) safeDiagnostic,
});
```

`NativeJwGateway` accepts the existing zero-argument `controllerFactory` for tests plus optional `userDataPathForAccount` and `productionControllerFactory`. On the first job it stores `_controllerAccountId = accountId`. `_controller()` resolves the account path, creates/configures the controller, then executes:

```dart
_sharedController = controller;
await surfaceHost.attach(controller);
return controller;
```

Do not notify a raw `Widget`; delete `surfaceListenable`, `_activeAdapter`, `_notifySurface`, and the transient `surface` getter. The adapter remains controller-agnostic and receives a closure returning the gateway-owned controller.

- [ ] **Step 4: Implement ordered, idempotent shutdown**

Track a `Completer<void>` per job and complete it after buffering a terminal event. Shutdown sets `_shutdown`, requests cancellation for non-terminal collectors, stops the controller to interrupt pending navigation, awaits all settlement futures with the existing collection timeout bound, then:

```dart
await surfaceHost.detachAndAwaitUnmount(controller);
await controller.stop();
await controller.clearBrowsingDataAll();
await controller.dispose();
```

Attempt every cleanup step and rethrow the first captured failure after all steps. Close subscriptions and diagnostics last. Remove `disposeControllerOnClose` from `JwWebViewAdapter`; the gateway is the single production controller owner.

- [ ] **Step 5: Run adapter and gateway tests**

```powershell
& 'E:\flutter\flutter\bin\flutter.bat' test --no-pub --reporter expanded test/features/sync/native/jw_webview_adapter_test.dart test/features/sync/native/native_jw_gateway_test.dart
```

Expected: all tests pass.

- [ ] **Step 6: Commit the gateway ownership change**

```powershell
git add -- app/lib/features/sync/native/native_jw_gateway.dart app/lib/features/sync/native/jw_webview_adapter.dart app/test/features/sync/native/native_jw_gateway_test.dart
git commit -m "fix(webview-minimal): order native gateway teardown"
```

---

### Task 3: Mount One Stable Surface in the Sync Page

**Files:**
- Modify: `app/lib/features/sync/presentation/sync_page.dart`
- Modify: `app/test/features/sync/sync_page_test.dart`

**Interfaces:**
- Consumes: `NativeJwGateway.surfaceHost.widget` from Task 2.
- Produces: one always-mounted host subtree whose visibility follows `busy`, plus a single async gateway shutdown path.

- [ ] **Step 1: Add failing widget tests for stable identity and disposal**

Inject a gateway with a keyed fake surface and add:

```dart
testWidgets('native surface host stays mounted when busy visibility changes', (tester) async {
  final host = JwWebViewSurfaceHost();
  final gateway = NativeJwGateway(
    surfaceHost: host,
    controllerFactory: () async => _PageSurfaceController(),
  );
  await tester.pumpWidget(_syncPageFixture(nativeGateway: gateway));
  expect(find.byKey(const Key('jw-webview-surface-host')), findsOneWidget);
  expect(find.byKey(const Key('jw-webview-surface-placeholder')), findsOneWidget);
  // Trigger the existing first-login action and pump once.
  await tester.enterText(find.byType(TextField).first, 'PB00000000');
  await tester.tap(find.byKey(const Key('first-login-submit')));
  await tester.pump();
  expect(find.byKey(const Key('jw-webview-surface-host')), findsOneWidget);
});
```

Add a loader-disposal test with a fake gateway whose `shutdown` records exactly one call.

- [ ] **Step 2: Run the sync-page tests and verify RED**

```powershell
& 'E:\flutter\flutter\bin\flutter.bat' test --no-pub --reporter expanded test/features/sync/sync_page_test.dart
```

Expected: the stable surface key is absent or the injected gateway cannot be mounted through the current conditional builder.

- [ ] **Step 3: Replace conditional raw-widget insertion**

Construct one subtree whenever `nativeGateway != null`:

```dart
Offstage(
  offstage: !busy,
  child: KeyedSubtree(
    key: const Key('jw-webview-surface-host'),
    child: _buildWebViewSurface(widget.nativeGateway!.surfaceHost.widget),
  ),
)
```

`Offstage` keeps the host mounted while removing it from the visible layout. Delete `ValueListenableBuilder<Widget?>` and every `surfaceListenable` reference.

Add `key: const Key('first-login-submit')` to the existing `FilledButton.icon` in `_FirstLoginPanel`; this is a test-only identity on the existing action and does not change login behavior.

In `_SyncPageLoaderState.dispose`, choose exactly one owned gateway (`nativeGateway ?? bridge`), cancel the diagnostic subscription, and invoke its idempotent shutdown once. Do not dispose the same native gateway through both fields.

Supply `userDataPathForAccount` using `getApplicationSupportDirectory()` and an opaque-account sanitizer. The callback accepts `accountId`, returns `support/webview/<sanitized-accountId>`, and never emits the path to diagnostics.

- [ ] **Step 4: Run the sync-page and gateway tests**

Run the Step 2 command followed by the Task 2 Step 5 command. Expected: all pass.

- [ ] **Step 5: Commit the page integration**

```powershell
git add -- app/lib/features/sync/presentation/sync_page.dart app/test/features/sync/sync_page_test.dart
git commit -m "fix(webview-minimal): keep sync WebView surface mounted"
```

---

### Task 4: Strict Navigation Attempts and Fail-Closed Identity

**Files:**
- Modify: `app/lib/features/sync/native/jw_web_session.dart`
- Modify: `app/lib/features/sync/native/jw_webview_adapter.dart`
- Modify: `app/test/features/sync/native/jw_webview_adapter_test.dart`

**Interfaces:**
- Produces: strict `convergeTarget` requiring URL + DOM + handshake; exact login targets; authoritative identity requirement.

- [ ] **Step 1: Add failing readiness and identity regressions**

Add fake-controller switches `suppressUrl`, `selectorPresent`, `suppressWebMessage`, and independent identity booleans. Tests:

```dart
test('home readiness fails when registered handshake is missing', () async {
  controller..setCurrent(_homeUrl)..suppressWebMessage = true;
  await expectLater(
    adapter.waitForAuthenticatedHome(const Duration(milliseconds: 150)),
    throwsA(isA<JwLoginTimeoutException>()),
  );
});

test('missing authoritative identity fails closed', () async {
  controller
    ..setCurrent(_loginEntryUrl)
    ..authoritativeMatched = false
    ..domMatched = true
    ..storageMatched = true;
  await expectLater(
    adapter.fillLogin(const LoginCredentials(username: 'PB00000000')),
    throwsA(isA<JwAccountMismatchException>()),
  );
});

test('login activates exact trusted portal target once', () async {
  controller.setCurrent(_loginEntryUrl);
  controller.authoritativeMatched = true;
  await adapter.fillLogin(const LoginCredentials(username: 'PB00000000'));
  expect(controller.primaryClicks, 1);
  expect(controller.submitCalls, 1);
  expect(controller.selectorProbes, contains('#login-unified-wrapper'));
});
```

Add separate failures for missing URL, missing DOM, authoritative conflict, DOM conflict, and storage conflict.

- [ ] **Step 2: Run the adapter tests and verify RED**

```powershell
& 'E:\flutter\flutter\bin\flutter.bat' test --no-pub --reporter expanded test/features/sync/native/jw_webview_adapter_test.dart
```

Expected: the missing-handshake and missing-authoritative tests currently succeed incorrectly.

- [ ] **Step 3: Make convergence strict**

Remove `handshake_retry`/`handshake_degraded` success. `convergeTarget` must run one registered handshake after URL and DOM complete and propagate timeout/script failures. Add an attempt token that is invalidated in `finally`; callbacks check it before completing their signal. Always cancel URL/loading subscriptions.

For `jw.portal.home`, set `readySelector: 'body'`. Map strict home convergence timeout to `JwLoginTimeoutException`; other target failures remain `JwCollectionException`.

- [ ] **Step 4: Align the trusted login targets and selectors**

Use:

```dart
const JwReadyTarget portalLoginTarget = JwReadyTarget(
  id: 'jw.portal.login',
  url: 'https://jw.ustc.edu.cn/login',
  urlPattern: 'https://jw.ustc.edu.cn/login*',
  readySelector: '#login-unified-wrapper',
  handshakeScriptId: 'jw.cas.inspect',
);
```

CAS readiness uses `form:has(input[name="username"], #username):has(input[type="password"])`. `gotoCasEntry()` prepares the portal login target; `fillLogin()` performs exactly one native click to transition to CAS. Delete stale-form automatic reactivation and any side-effecting retry. Retain retry only in selector polling during document replacement.

- [ ] **Step 5: Require authoritative identity**

`JwIdentityProof.verified` is:

```dart
authoritativeMatched &&
!authoritativeConflicted &&
!domConflicted &&
!storageConflicted
```

If false, throw `JwAccountMismatchException`; never continue on `identity_verification_uncertain`. Diagnostics report only boolean categories.

- [ ] **Step 6: Run adapter and collector tests**

```powershell
& 'E:\flutter\flutter\bin\flutter.bat' test --no-pub --reporter expanded test/features/sync/native/jw_webview_adapter_test.dart test/features/sync/native/jw_collector_test.dart
```

Expected: all pass.

- [ ] **Step 7: Commit strict login/readiness**

```powershell
git add -- app/lib/features/sync/native/jw_web_session.dart app/lib/features/sync/native/jw_webview_adapter.dart app/test/features/sync/native/jw_webview_adapter_test.dart
git commit -m "fix(webview-minimal): enforce trusted JW login readiness"
```

---

### Task 5: Exact Course and Exam Contracts

**Files:**
- Modify: `app/lib/features/sync/native/jw_web_session.dart`
- Modify: `app/lib/features/sync/native/jw_webview_adapter.dart`
- Modify: `app/test/features/sync/native/jw_webview_adapter_test.dart`
- Verify: `app/test/features/sync/native/jw_oracle_equality_test.dart`

**Interfaces:**
- Consumes: configured semester passed to `fetchCourseDatum`.
- Produces: exact same-origin GET/JSON POST request validation and unique exam-table extraction.

- [ ] **Step 1: Add failing request-shape and validation tests**

Add tests asserting:

```dart
expect(controller.lastGetDataArgs, {
  'semesterId': 461,
  'dataId': 'data-ctx-1',
});
expect(controller.lastDatumLessonIds, [101, 102]);
```

Add table-driven invalid `lessonIds` cases: `[]`, `[0]`, `[1, 1]`, `['1']`, and more than 20,000 IDs. Each must throw `JwCollectionException` before the datum script runs. Add an exam response with two `table#exams` elements and assert failure.

- [ ] **Step 2: Run the adapter tests and verify RED**

```powershell
& 'E:\flutter\flutter\bin\flutter.bat' test --no-pub --reporter expanded test/features/sync/native/jw_webview_adapter_test.dart
```

Expected: duplicate/non-positive IDs and non-unique exam tables are not all rejected by the current Dart boundary.

- [ ] **Step 3: Tighten registered scripts and Dart validation**

Course readiness changes from `body` to `select#allSemesters`. `jw.course.readContext` accepts only exact same-origin get-data resource entries with sorted keys `bizTypeId,dataId,semesterId` and a non-empty `dataId`.

Before `jw.course.fetchDatum`, convert and validate the lesson IDs in Dart:

```dart
final ids = lessonIds.whereType<int>().toList(growable: false);
if (ids.isEmpty || ids.length != lessonIds.length || ids.length > 20000 ||
    ids.any((id) => id < 1) || ids.toSet().length != ids.length) {
  throw const JwCollectionException('invalid lessonIds');
}
```

Keep the script request shapes exactly as specified in the design. The exam script requires `document.querySelectorAll('table#exams').length == 1`.

- [ ] **Step 4: Run adapter and oracle tests**

```powershell
& 'E:\flutter\flutter\bin\flutter.bat' test --no-pub --reporter expanded test/features/sync/native/jw_webview_adapter_test.dart test/features/sync/native/jw_oracle_equality_test.dart
```

Expected: both pass; oracle digest remains unchanged.

- [ ] **Step 5: Commit collection-contract hardening**

```powershell
git add -- app/lib/features/sync/native/jw_web_session.dart app/lib/features/sync/native/jw_webview_adapter.dart app/test/features/sync/native/jw_webview_adapter_test.dart
git commit -m "fix(webview-minimal): enforce JW collection contracts"
```

---

### Task 6: Awaitable Polling, Cancellation, and No Late Import

**Files:**
- Modify: `app/lib/features/sync/native/native_jw_gateway.dart`
- Modify: `app/lib/features/sync/native/jw_collector.dart`
- Modify: `app/lib/features/sync/application/sync_coordinator.dart`
- Modify: `app/test/features/sync/native/native_jw_gateway_test.dart`
- Modify: `app/test/features/sync/native/jw_collector_test.dart`
- Modify: `app/test/features/sync/sync_coordinator_test.dart`

**Interfaces:**
- Produces: event-driven `poll`, cancellation-dominant collector terminal behavior, and coordinator consumption without a fixed delay.

- [ ] **Step 1: Add failing poll and cancellation tests**

```dart
test('poll waits until an event arrives instead of returning an empty spin', () async {
  final pending = gateway.poll(job.id, currentSequence);
  var completed = false;
  pending.then((_) => completed = true);
  await Future<void>.microtask(() {});
  expect(completed, isFalse);
  controller.releaseBlockedNavigation();
  final poll = await pending;
  expect(poll.events, isNotEmpty);
});

test('cancel during page failure emits cancelled instead of failed', () async {
  final events = <SourceCollectionEvent>[];
  final subscription = collector.startJwCollection(
    accountId: 'account',
    expectedUsername: 'PB00000000',
    semester: const JwSemesterConfig(
      semesterId: 461,
      semesterKey: '2026fall',
      displayName: '2026 秋季学期',
    ),
  ).listen(events.add);
  await page.courseStarted.future;
  await collector.cancel(collector.activeJobId!);
  page.failCourse();
  await subscription.asFuture<void>();
  expect(events.last, isA<CollectionCancelled>());
  expect(events.whereType<CollectionComplete>(), isEmpty);
});
```

In `sync_coordinator_test.dart`, use a fake gateway that counts empty polls and assert the coordinator does not execute a fixed-delay spin before the next gateway event.

- [ ] **Step 2: Run the three focused test files and verify RED**

```powershell
& 'E:\flutter\flutter\bin\flutter.bat' test --no-pub --reporter expanded --concurrency=1 test/features/sync/native/native_jw_gateway_test.dart test/features/sync/native/jw_collector_test.dart test/features/sync/sync_coordinator_test.dart
```

Expected: current `poll` completes immediately and cancellation during an awaited failure can emit `failed`.

- [ ] **Step 3: Implement event-driven poll notification**

Each gateway job owns a change completer. Buffering any event completes the current completer and replaces it for the next wait. `poll` returns immediately only when it has unseen events or a terminal state; otherwise it awaits either the change completer or a bounded 250 ms long-poll timeout, then snapshots state.

Delete the fixed `Future.delayed(250 ms)` from `SyncCoordinator._consume`; the native gateway now owns waiting, while the HTTP Bridge already blocks on transport.

- [ ] **Step 4: Make cancellation terminal-dominant**

In `JwCollector._drive`, every catch checks `job.cancelToken.isCancelled` first and emits `CollectionCancelled`; only non-cancelled exceptions emit failure. Guard bundle completion with one final cancellation check. The gateway ignores any result buffered after a cancelled terminal generation.

- [ ] **Step 5: Run focused tests and the real import decoder tests**

```powershell
& 'E:\flutter\flutter\bin\flutter.bat' test --no-pub --reporter expanded --concurrency=1 test/features/sync/native/native_jw_gateway_test.dart test/features/sync/native/jw_collector_test.dart test/features/sync/sync_coordinator_test.dart test/features/import/import_service_test.dart test/features/import/source_bundle_decoder_test.dart
```

Expected: all pass and no cancelled job invokes the import callback.

- [ ] **Step 6: Commit polling and cancellation**

```powershell
git add -- app/lib/features/sync/native/native_jw_gateway.dart app/lib/features/sync/native/jw_collector.dart app/lib/features/sync/application/sync_coordinator.dart app/test/features/sync/native/native_jw_gateway_test.dart app/test/features/sync/native/jw_collector_test.dart app/test/features/sync/sync_coordinator_test.dart
git commit -m "fix(webview-minimal): settle native JW jobs safely"
```

---

### Task 7: Restore the Final Native Navigation Policy

**Files:**
- Modify: `app/packages/webview_flutter_windows_secure/windows/navigation_policy.cc`
- Modify: `app/packages/webview_flutter_windows_secure/windows/test/navigation_policy_test.cc`

**Interfaces:**
- Produces: `NavigationPolicy::UpgradeInsecureToAllowedHttps` requiring both the active policy and `Production()` policy.

- [ ] **Step 1: Restore the failing Debug-loopback negative test**

Add to `DebugLoopbackRequiresExactIpv4PortAndExplicitFlag`:

```cpp
EXPECT_FALSE(enabled.UpgradeInsecureToAllowedHttps(
                         L"http://127.0.0.1:43123/fixture")
                 .has_value());
```

- [ ] **Step 2: Configure/build/run the native test and verify RED**

Run serially from the plugin directory:

```powershell
cmake -S windows/test -B build/native_tests
cmake --build build/native_tests --config Release
ctest --test-dir build/native_tests -C Release --output-on-failure
```

Expected: the restored loopback-upgrade assertion fails against the current minimal policy.

- [ ] **Step 3: Restore the production-policy guard**

Change the return condition to:

```cpp
return Allows(upgraded) && Production().Allows(upgraded)
           ? std::optional<std::wstring>(std::move(upgraded))
           : std::nullopt;
```

- [ ] **Step 4: Re-run native tests and verify GREEN**

Run Step 2's build and `ctest` commands. Expected: all native tests pass.

- [ ] **Step 5: Commit only the policy source and test**

```powershell
git add -- app/packages/webview_flutter_windows_secure/windows/navigation_policy.cc app/packages/webview_flutter_windows_secure/windows/test/navigation_policy_test.cc
git commit -m "fix(webview-minimal): restore production HTTPS upgrade guard"
```

---

### Task 8: Real Windows WebView2 Loopback Lifecycle Gate

**Files:**
- Create: `app/integration_test/minimal_jw_webview_loopback_test.dart`
- Create: `app/test/support/minimal_jw_webview_fixture_server.dart`
- Modify: `app/lib/features/sync/native/jw_webview_adapter.dart`
- Modify: `app/lib/features/sync/native/jw_web_session.dart`

**Interfaces:**
- Adds Debug-only `debugLoopbackPort` and one immutable `JwWebRuntimePolicy` seam used consistently by the production controller factory, adapter navigation targets, registered scripts, and URL checks; defaults remain the immutable production JW policy.
- Produces a real plugin/texture lifecycle test with no school network or credentials.

- [ ] **Step 1: Build the loopback fixture server**

The server binds `InternetAddress.loopbackIPv4` on an ephemeral port and serves only these paths:

```text
/portal/login       -> button id=login-unified-wrapper linking /cas/login
/cas/login          -> username/password form and submit navigation /home
/home               -> body plus credential-free ready marker
/course-table       -> select#allSemesters and scripted get-data performance request
/course/get-data    -> {"lessonIds":[101,102]}
/course/datum       -> fixture course datum JSON
/exam-arrange       -> exactly one table#exams
```

The fixture records method, path, content type, X-Requested-With, and body shape only. It never stores secret field values.

- [ ] **Step 2: Add the failing real-controller integration test**

Use `IntegrationTestWidgetsFlutterBinding`, create a temporary UDF, start the fixture, create a `JwWebViewSurfaceHost`, and mount `host.widget`. Construct the production controller with the fixture port and injected loopback targets/scripts. Exercise navigation, registered extraction, and teardown:

```dart
testWidgets('real WebView2 survives mounted collection and ordered teardown', (tester) async {
  final fixture = await MinimalJwWebViewFixtureServer.start();
  final udf = await Directory.systemTemp.createTemp('minimal-jw-loopback-');
  final host = JwWebViewSurfaceHost();
  final controller = await createProductionJwWebviewController(
    userDataPath: udf.path,
    debugLoopbackPort: fixture.port,
    policy: fixture.policy,
  );
  await tester.pumpWidget(MaterialApp(home: SizedBox(height: 360, child: host.widget)));
  await host.attach(controller);
  await tester.pump();

  final adapter = JwWebViewAdapter(
    controllerFactory: () async => controller,
    runtimePolicy: fixture.policy,
  );
  await adapter.gotoRoot();
  await adapter.gotoCasEntry();
  await adapter.fillLogin(const LoginCredentials(
    username: 'PB00000000',
    password: 'loopback-only',
  ));
  await adapter.waitForAuthenticatedHome(const Duration(seconds: 5));
  await adapter.gotoCourseTable();
  final dataId = await adapter.resolveCourseDataId(const Duration(seconds: 5));
  final datum = await adapter.fetchCourseDatum(
    semesterId: 461,
    dataId: dataId,
    referer: fixture.policy.courseEntryUrl,
  );
  await adapter.gotoExamArrange();
  final examHtml = await adapter.fetchExamHtml(const Duration(seconds: 5));
  final bundle = buildJwSourceBundle(
    courseDatum: datum,
    examHtml: examHtml,
    accountId: 'loopback-account',
    semester: const JwSemester(
      semesterId: 461,
      semesterKey: '2026fall',
      displayName: '2026 秋季学期',
    ),
  );
  expect(bundle['schemaVersion'], '1.0');
  expect(fixture.requestShapes, containsAll(<String>[
    'GET /course/get-data',
    'POST /course/datum application/json XMLHttpRequest',
  ]));

  final detach = host.detachAndAwaitUnmount(controller);
  await tester.pump();
  await detach;
  await controller.stop();
  await controller.dispose();
  await tester.pumpWidget(const SizedBox());
  expect(tester.takeException(), isNull);
});
```

Use `try/finally` to close the server and delete only the resolved temporary UDF after controller release. Do not call a second `pump()` after root unmount.

- [ ] **Step 3: Run the integration test and verify RED**

Close any running app process, then run:

```powershell
& 'E:\flutter\flutter\bin\flutter.bat' test --no-pub --reporter expanded integration_test/minimal_jw_webview_loopback_test.dart -d windows
```

Expected: compile failure until Debug loopback injection is exposed, or a lifecycle failure against the pre-fix integration.

- [ ] **Step 4: Add the narrow Debug-only injection seam**

Define `JwWebRuntimePolicy` in `jw_web_session.dart` with all navigation URLs, ready targets, allowed origins/path prefixes, URL predicates, and the registered-script catalog. Export one `productionJwWebRuntimePolicy` constant that contains the current immutable JW values. `JwWebViewAdapter` accepts `runtimePolicy`, defaults to that production constant, and uses it for every `_navigate`, `convergeTarget`, registered-script invocation, and URL check; no production constant may bypass the object.

`createProductionJwWebviewController` accepts nullable `debugLoopbackPort` plus the same policy so native navigation configuration and Dart behavior cannot diverge. In non-Debug builds, throw before controller initialization unless `debugLoopbackPort == null` and the policy is identical to `productionJwWebRuntimePolicy`; this makes caller-supplied loopback policy unreachable from Release product composition. Configure the plugin with `setNavigationPolicy(..., debugLoopbackPort: debugLoopbackPort)` before navigation. Keep product composition unchanged so it passes neither argument.

Configure the plugin with `setNavigationPolicy(..., debugLoopbackPort: debugLoopbackPort)` before navigation. Keep production behavior unchanged when the arguments are absent.

- [ ] **Step 5: Run the integration test repeatedly**

Run the Step 3 command three times sequentially. Expected each time: exit code 0, process remains connected through teardown, and no new Application Error entry for `ustc_assistant_app.exe` appears during the test window.

- [ ] **Step 6: Run the fake-controller regression set**

```powershell
& 'E:\flutter\flutter\bin\flutter.bat' test --no-pub --reporter expanded test/features/sync/native/jw_webview_surface_host_test.dart test/features/sync/native/jw_webview_adapter_test.dart test/features/sync/native/native_jw_gateway_test.dart test/features/sync/sync_page_test.dart
```

Expected: all pass.

- [ ] **Step 7: Commit the loopback gate**

```powershell
git add -- app/integration_test/minimal_jw_webview_loopback_test.dart app/test/support/minimal_jw_webview_fixture_server.dart app/lib/features/sync/native/jw_webview_adapter.dart app/lib/features/sync/native/jw_web_session.dart
git commit -m "test(webview-minimal): gate real WebView2 lifecycle"
```

---

### Task 9: Documentation and Final Serial Verification

**Files:**
- Modify: `docs/m6-external-machine-handoff.md`
- Modify: `docs/plan-webview-minimal-m7-webview2.md`
- Verify only: all files changed by Tasks 1–8

**Interfaces:**
- Produces an honest automated verification record and an owner-run real-campus checklist.

- [ ] **Step 1: Update documentation with the corrected lifecycle**

Record:

- stable host and detach-before-dispose ownership;
- per-account UDF routing without session snapshot persistence;
- strict URL/DOM/handshake and authoritative identity requirements;
- awaitable polling/cancellation semantics;
- loopback integration evidence versus real-campus acceptance boundary;
- exact remaining owner-run stage chain from the spec.

Do not record account data, URLs with queries, data IDs, response bodies, or claim real-campus success.

- [ ] **Step 2: Confirm no Flutter process is already running**

```powershell
Get-Process flutter,dart,ustc_assistant_app -ErrorAction SilentlyContinue |
  Select-Object Id,ProcessName,CPU,StartTime
```

If a process belongs to this task, stop only that exact PID. Do not kill unrelated Flutter/Dart work.

- [ ] **Step 3: Run the real loopback gate once fresh**

```powershell
& 'E:\flutter\flutter\bin\flutter.bat' test --no-pub --reporter expanded integration_test/minimal_jw_webview_loopback_test.dart -d windows
```

Expected: exit code 0 and no device disconnect.

- [ ] **Step 4: Run the Flutter three-piece gate in one terminal**

From `app/`, with the proxy environment configured as supplied by the owner:

```powershell
$ErrorActionPreference = 'Stop'
$FlutterExe = 'E:\flutter\flutter\bin\flutter.bat'
& $FlutterExe analyze --no-pub
if ($LASTEXITCODE -ne 0) { throw "flutter analyze failed: $LASTEXITCODE" }
& $FlutterExe test --no-pub --reporter expanded
if ($LASTEXITCODE -ne 0) { throw "flutter test failed: $LASTEXITCODE" }
& $FlutterExe build windows --release --no-pub
if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed: $LASTEXITCODE" }
```

Expected: analyze has zero errors; test results are reported against the documented baseline with every new test passing; Release build exits 0. Stop immediately if any earlier command fails.

- [ ] **Step 5: Run Python oracle gates in Conda**

From the worktree root:

```powershell
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
```

Expected: existing Python JW/contract suite passes and compileall exits 0. Do not install packages or modify any Conda environment.

- [ ] **Step 6: Review the exact diff and requirements**

```powershell
git status --short
git diff --check
git diff --stat 42ca76e..HEAD
```

Confirm every design requirement has a corresponding test or owner-run acceptance item, and that `baseline_head.txt`, `jw-debug.log`, and unrelated pre-existing changes were never staged accidentally.

- [ ] **Step 7: Commit documentation only**

```powershell
git add -- docs/m6-external-machine-handoff.md docs/plan-webview-minimal-m7-webview2.md
git commit -m "docs(webview-minimal): record reachable WebView2 verification"
```

- [ ] **Step 8: Hand off real-campus acceptance**

Ask the owner to run the privacy-safe stage chain:

```text
login entry -> CAS -> identity verified -> course context -> get-data
-> datum -> exam table -> bundle built -> imported -> schedule visible
```

Report automated loopback and build evidence separately. Do not mark real-campus acceptance complete until the owner confirms it.
