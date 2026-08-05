# Flutter-Native JW Source Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Windows App's production Python path for USTC JW course and exam synchronization with an in-app WebView2 session, dynamic per-account semester selection, pure-Dart normalization, and the existing SourceBundle 1.0 import path.

**Architecture:** Keep the existing `ImportService`, SourceBundle 1.0 contract, Drift business model, and Python-backed non-JW sources. Add a platform-neutral `JwSourceGateway` above a controlled `AuthenticatedWebSession`; implement the session on Windows with WebView2 and fixed versioned JavaScript messages, while keeping all source parsing and bundle construction in pure Dart. Build and manually validate the native path behind a temporary compile-time preview switch, then remove the switch and route `SyncSource.jw` exclusively to Dart after the acceptance gate.

**Tech Stack:** Flutter 3.44.5 / Dart 3.12, `webview_flutter_windows` 1.1.1, Microsoft Edge WebView2 Runtime, `html` 0.15.6, Drift/SQLite, existing DPAPI credential protection, SourceBundle 1.0, `flutter_test`, Python `ustc_assistant` only as a migration oracle.

## Global Constraints

- Implement only the Windows JW course/exam source in this milestone; Android/iOS receive platform-neutral interfaces but no production WebView adapter.
- `SyncSource.jw` must have no Python fallback after the cutover task. Young, iCourse, campus, and Agent query sources remain on the current Bridge.
- Never infer or hard-code a JW semester ID. Do not fall back to `461`, the page-selected semester, or the current date.
- Persist one complete version-1 semester snapshot per local account in `SourceConfigs(source=ustc_jw).configJson`; changing it must not delete previously imported semesters.
- Keep `dataId`, Cookie, raw page HTML, raw datum, account identifiers, passwords, and SMS codes out of logs, SQLite business tables, SourceBundle, Git fixtures, and error messages.
- Cookies remain inside the per-account WebView2 user-data directory. Do not copy them into Dart HTTP clients.
- The only allowed browser origins are HTTPS `jw.ustc.edu.cn` and `id.ustc.edu.cn`; deny popups, downloads, permissions, non-HTTPS navigation, arbitrary URLs, and arbitrary JavaScript.
- Credentials may be decrypted only for an interactive login attempt. Autofill and click login once per page instance; the user enters SMS verification manually in the visible WebView.
- A 12-hour background sync that lacks a valid session records `needs_login` without opening a WebView.
- Course and exam components form one all-or-nothing complete semester snapshot. Empty course and empty exam results are valid; malformed or partial components never reach `ImportService`.
- Fixed collection limits: course context 4 MiB, get-data 8 MiB, datum 16 MiB, exam HTML 4 MiB, 256 semesters, 20,000 lesson IDs, 50,000 schedule/group rows, 50 participants per event, 30 seconds per navigation/request, 10 seconds per controlled script, 5 minutes interactive login, and 5 minutes post-login collection.
- Continue enforcing SourceBundle limits: 16 MiB, 50,000 events, 5,000 course series, 50,000 relations, and all schema field limits.
- Use `publishLessonIds` for `/datum`. If real Python/Dart comparison reveals a business difference from legacy `lessonIds`, stop at the acceptance gate and classify it with the owner before cutover.
- All automatic tests use sanitized fixtures and never access school sites. Real login validation is a separate owner-run acceptance checkpoint.
- Do not delete Python JW, Bridge, CLI, or tests in this milestone; they remain migration-oracle code until the later full-Python-removal project.
- Work in an isolated git worktree. Do not modify `temp.md`, `tmp/`, user acceptance notes, or unrelated dirty generated files.
- Run Flutter commands with the working directory set to `app/`; run Git and Python commands from the repository root unless a step explicitly uses `Push-Location`.

---

## File Map

New production units:

```text
app/lib/features/sync/jw/
  domain/
    jw_limits.dart                    fixed input/time/count limits
    jw_semester.dart                  catalog entry and selected snapshot
    jw_snapshot.dart                  typed course/exam capture model
    jw_sync_error.dart                safe stable error codes
    jw_source_gateway.dart            platform-neutral native JW job contract
    authenticated_web_session.dart    controlled browser operation contract
  data/
    jw_semester_catalog_decoder.dart  runtime catalog validation
    jw_course_datum_parser.dart       lesson/group/schedule normalization
    jw_exam_table_parser.dart         table#exams parsing
    jw_source_bundle_builder.dart     canonical SourceBundle 1.0 producer
    jw_web_message_protocol.dart      fixed version-1 command/result envelopes
    jw_web_scripts.dart               fixed on-document WebView script constants
  application/
    jw_semester_selection_store.dart  SourceConfigs version-1 persistence
    jw_collector.dart                 authenticated fixed-endpoint collection
    native_jw_source_gateway.dart     resumable login/semester/collection jobs
  platform/windows/
    webview_controller_port.dart      testable wrapper over plugin controller
    windows_webview_profile_store.dart per-account profile lifecycle
    windows_webview_session.dart      WebView2 implementation
  presentation/
    jw_login_pane.dart                visible CAS/SMS surface
    jw_semester_dialog.dart           single-selection UI

app/lib/features/sync/application/
  sync_composition.dart               owns native JW and legacy Bridge lifetimes
```

Existing files changed together:

```text
app/pubspec.yaml
app/pubspec.lock
app/windows/flutter/generated_plugin_registrant.cc
app/windows/flutter/generated_plugin_registrant.h
app/windows/flutter/generated_plugins.cmake
app/lib/features/sync/domain/sync_state.dart
app/lib/features/sync/data/bridge_client.dart
app/lib/features/sync/application/sync_coordinator.dart
app/lib/features/sync/presentation/sync_page.dart
app/lib/features/accounts/application/account_service.dart
app/lib/features/accounts/presentation/accounts_page.dart
app/lib/features/settings/application/settings_service.dart
app/lib/features/settings/presentation/settings_page.dart
app/lib/app/app.dart
app/lib/app/router.dart
app/lib/core/config/generated_source_defaults.dart   delete after cutover
docs/data-sources/jw.md
docs/architecture.md
docs/acceptance/flutter-native-jw.md
README.md
AGENTS.md
```

---

### Task 1: Freeze Sanitized JW Fixtures and Safe Boundaries

**Files:**
- Create: `app/test/fixtures/jw/course-page-context.json`
- Create: `app/test/fixtures/jw/get-data-published.json`
- Create: `app/test/fixtures/jw/get-data-empty.json`
- Create: `app/test/fixtures/jw/course-datum.json`
- Create: `app/test/fixtures/jw/exam-page.html`
- Create: `app/test/fixtures/jw/exam-empty.html`
- Create: `app/lib/features/sync/jw/domain/jw_limits.dart`
- Create: `app/lib/features/sync/jw/domain/jw_sync_error.dart`
- Create: `app/test/features/sync/jw/jw_fixture_safety_test.dart`

**Interfaces:**
- Produces: `JwLimits` constants and `JwSyncException(String code)` used by every later native JW unit.
- Produces: deterministic synthetic fixtures derived from `tests/fixtures/jw/`, never from private `temp.md` at test runtime.

- [ ] **Step 1: Write the failing fixture safety test**

```dart
test('JW fixtures are present, synthetic, and free of private fields', () {
  const paths = [
    'test/fixtures/jw/course-page-context.json',
    'test/fixtures/jw/get-data-published.json',
    'test/fixtures/jw/get-data-empty.json',
    'test/fixtures/jw/course-datum.json',
    'test/fixtures/jw/exam-page.html',
    'test/fixtures/jw/exam-empty.html',
  ];
  for (final path in paths) {
    final text = File(path).readAsStringSync();
    expect(text, isNotEmpty, reason: path);
    expect(text.toLowerCase(), isNot(contains('cookie')));
    expect(text.toLowerCase(), isNot(contains('password')));
    expect(text, isNot(contains('489951')));
    expect(text, isNot(matches(RegExp(r'PB\d{8}'))));
  }
});

test('fixed limits match the approved design', () {
  expect(JwLimits.courseContextBytes, 4 * 1024 * 1024);
  expect(JwLimits.getDataBytes, 8 * 1024 * 1024);
  expect(JwLimits.datumBytes, 16 * 1024 * 1024);
  expect(JwLimits.maxSemesters, 256);
  expect(JwLimits.maxLessonIds, 20000);
});
```

- [ ] **Step 2: Run the test and verify missing files/types fail**

Run: `E:\flutter\flutter\bin\flutter.bat test test/features/sync/jw/jw_fixture_safety_test.dart`

Expected: FAIL because the fixtures and `JwLimits` do not exist.

- [ ] **Step 3: Add the fixtures, limits, and safe exception**

Use synthetic IDs such as `900001`, keep the existing complex multi-teacher datum structure, and define:

```dart
abstract final class JwLimits {
  static const courseContextBytes = 4 * 1024 * 1024;
  static const getDataBytes = 8 * 1024 * 1024;
  static const datumBytes = 16 * 1024 * 1024;
  static const examHtmlBytes = 4 * 1024 * 1024;
  static const maxSemesters = 256;
  static const maxLessonIds = 20000;
  static const maxScheduleRows = 50000;
  static const maxParticipants = 50;
  static const navigationTimeout = Duration(seconds: 30);
  static const scriptTimeout = Duration(seconds: 10);
  static const interactiveLoginTimeout = Duration(minutes: 5);
  static const collectionTimeout = Duration(minutes: 5);
}

class JwSyncException implements Exception {
  const JwSyncException(this.code);
  final String code;
  @override
  String toString() => 'JwSyncException: $code';
}
```

Only these codes may leave the JW subsystem: `needs_login`, `needs_sms_verification`, `semester_selection_required`, `semester_catalog_changed`, `account_mismatch`, `page_contract_changed`, `request_failed`, `response_too_large`, `incomplete_snapshot`, `import_failed`, and `cancelled`.

- [ ] **Step 4: Run the focused test**

Run: `E:\flutter\flutter\bin\flutter.bat test test/features/sync/jw/jw_fixture_safety_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add app/test/fixtures/jw app/lib/features/sync/jw/domain app/test/features/sync/jw/jw_fixture_safety_test.dart
git commit -m "test: freeze sanitized JW source fixtures"
```

---

### Task 2: Decode Dynamic Semesters and Persist Per-Account Selection

**Files:**
- Create: `app/lib/features/sync/jw/domain/jw_semester.dart`
- Create: `app/lib/features/sync/jw/data/jw_semester_catalog_decoder.dart`
- Create: `app/lib/features/sync/jw/application/jw_semester_selection_store.dart`
- Create: `app/test/features/sync/jw/jw_semester_catalog_decoder_test.dart`
- Create: `app/test/features/sync/jw/jw_semester_selection_store_test.dart`

**Interfaces:**
- Produces: `JwSemesterCatalogDecoder.decode(Map<String, Object?>) -> JwCoursePageContext`.
- Produces: `JwSemesterSelectionStore.load/save/reconcile/clear` over existing `SourceConfigs`.
- Persistence envelope: `{"version":1,"selectedSemester":{...all fields...}}`.

- [ ] **Step 1: Write decoder failures and normalization tests**

```dart
test('normalizes source seasons without inferring semester ids', () {
  final context = decoder.decode(loadJson('course-page-context.json'));
  expect(context.dataId, 'synthetic-data-context');
  expect(context.semesters.map((e) => e.semesterKey),
      containsAll(['2026spring', '2026summer', '2026fall']));
  expect(context.semesters.singleWhere((e) => e.semesterKey == '2026spring').semesterId, 421);
});

test('rejects duplicate id, duplicate product key, unknown season, and DOM mismatch', () {
  for (final fixture in invalidCatalogCases) {
    expect(() => decoder.decode(fixture),
        throwsA(isA<JwSyncException>().having((e) => e.code, 'code', 'page_contract_changed')));
  }
});
```

Define `JwSemester` with exactly: `semesterId`, `sourceCode`, `semesterKey`, `displayName`, `schoolYear`, `season`, `startDate`, `endDate`, and `enabled`. Map `SPRING`, `SUMMER`, and `AUTUMN` to `spring`, `summer`, and `fall` using source `currentYear` only.

- [ ] **Step 2: Run decoder tests and verify failure**

Run: `E:\flutter\flutter\bin\flutter.bat test test/features/sync/jw/jw_semester_catalog_decoder_test.dart`

Expected: FAIL because the decoder/model do not exist.

- [ ] **Step 3: Implement strict catalog decoding**

The decoder must require a positive integer `dataId` or bounded nonblank context token, compare the runtime `semesters` IDs with `select#allSemesters` option IDs, reject more than 256 entries, reject invalid inclusive date ranges, and ignore the DOM's selected flag for product selection.

```dart
class JwCoursePageContext {
  const JwCoursePageContext({required this.dataId, required this.semesters});
  final String dataId;
  final List<JwSemester> semesters;
}
```

- [ ] **Step 4: Write selection-store account isolation tests**

```dart
test('selection is versioned and isolated by account', () async {
  await store.save('account-a', spring);
  await store.save('account-b', fall);
  expect(await store.load('account-a'), spring);
  expect(await store.load('account-b'), fall);
});

test('reconcile requires reselection when id disappears or identity changes', () async {
  await store.save('account-a', spring);
  await expectLater(store.reconcile('account-a', changedCatalog),
      throwsA(isA<JwSyncException>().having((e) => e.code, 'code', 'semester_catalog_changed')));
});
```

- [ ] **Step 5: Implement the SourceConfigs store**

`save` uses `insertOnConflictUpdate`, preserves `enabled`, `lastSuccessAt`, and `retryAfter`, and updates only the `ustc_jw` row for the supplied account. `load` rejects unknown versions and incomplete fields. `reconcile` matches both `semesterId` and all identity fields; it never guesses another catalog item.

- [ ] **Step 6: Run focused database and decoder tests**

Run: `E:\flutter\flutter\bin\flutter.bat test test/features/sync/jw/jw_semester_catalog_decoder_test.dart test/features/sync/jw/jw_semester_selection_store_test.dart`

Expected: PASS.

- [ ] **Step 7: Commit**

```powershell
git add app/lib/features/sync/jw app/test/features/sync/jw
git commit -m "feat: add dynamic JW semester selection"
```

---

### Task 3: Parse and Normalize Course Datum in Pure Dart

**Files:**
- Create: `app/lib/features/sync/jw/domain/jw_snapshot.dart`
- Create: `app/lib/features/sync/jw/data/jw_course_datum_parser.dart`
- Create: `app/test/features/sync/jw/jw_course_datum_parser_test.dart`

**Interfaces:**
- Consumes: decoded `/datum` object and `JwLimits`.
- Produces: `JwCourseSnapshot(lessons, occurrences)` with public teacher names only.

- [ ] **Step 1: Port the Python regression matrix into failing Dart tests**

Cover the checked-in complex fixture plus synthetic mutations:

```dart
test('merges participant-only duplicate rows into one occurrence', () {
  final snapshot = parser.parse(loadDatum());
  final occurrence = snapshot.occurrences.singleWhere((e) => e.lessonId == 173667);
  expect(occurrence.participants.map((e) => e.name), containsAll(['教师甲', '教师乙']));
  expect(snapshot.occurrences.where((e) => e.identity == occurrence.identity), hasLength(1));
});

test('keeps same-time rows separate when place or exercise class differs', () {
  final snapshot = parser.parse(collisionDatum);
  expect(snapshot.occurrences, hasLength(2));
  expect(snapshot.occurrences.map((e) => e.identity).toSet(), hasLength(2));
});
```

Also assert explicit `page_contract_changed` or `response_too_large` for duplicate lesson/group IDs, dangling group references, mismatched non-participant row fields, invalid HHmm/date, more than 50,000 rows, and more than 50 participants.

- [ ] **Step 2: Run the parser test and verify failure**

Run: `E:\flutter\flutter\bin\flutter.bat test test/features/sync/jw/jw_course_datum_parser_test.dart`

Expected: FAIL because `JwCourseDatumParser` is absent.

- [ ] **Step 3: Implement typed parsing and stable occurrence identity inputs**

```dart
class JwCourseSnapshot {
  const JwCourseSnapshot({required this.lessons, required this.occurrences});
  final List<JwLesson> lessons;
  final List<JwCourseOccurrence> occurrences;
}

class JwExam {
  const JwExam({
    required this.courseCode,
    required this.examType,
    required this.courseName,
    required this.startAt,
    required this.endAt,
    required this.room,
    required this.building,
    required this.campus,
    required this.note,
  });
  final String courseCode;
  final String examType;
  final String courseName;
  final DateTime startAt;
  final DateTime endAt;
  final String room;
  final String building;
  final String campus;
  final String? note;
}

class JwCourseOccurrence {
  const JwCourseOccurrence({
    required this.lessonId,
    required this.scheduleGroupId,
    required this.date,
    required this.startTime,
    required this.endTime,
    required this.location,
    required this.exerciseClass,
    required this.weekIndex,
    required this.periods,
    required this.participants,
  });
  String get identity => '$lessonId:$scheduleGroupId:${date.toIso8601String()}:$startTime:$endTime:${location.identity}:$exerciseClass';
}
```

Match the direct Python SourceBundle builder semantics, not the obsolete legacy import package. Strip `teacherId` and `personId` after deduplication; retain only `{role: teacher, name}`.

- [ ] **Step 4: Run focused parser tests**

Run: `E:\flutter\flutter\bin\flutter.bat test test/features/sync/jw/jw_course_datum_parser_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add app/lib/features/sync/jw/domain/jw_snapshot.dart app/lib/features/sync/jw/data/jw_course_datum_parser.dart app/test/features/sync/jw/jw_course_datum_parser_test.dart
git commit -m "feat: parse JW course datum in Dart"
```

---

### Task 4: Parse the Exam Table in Pure Dart

**Files:**
- Modify: `app/pubspec.yaml`
- Modify: `app/pubspec.lock`
- Create: `app/lib/features/sync/jw/data/jw_exam_table_parser.dart`
- Create: `app/test/features/sync/jw/jw_exam_table_parser_test.dart`

**Interfaces:**
- Consumes: bounded necessary HTML containing exactly one `table#exams`.
- Produces: `List<JwExam>` with validated Beijing local start/end.

- [ ] **Step 1: Add `html: 0.15.6` and fetch dependencies**

Run: `E:\flutter\flutter\bin\flutter.bat pub get`

Expected: `pubspec.lock` resolves `html 0.15.6` without changing unrelated direct dependency versions.

- [ ] **Step 2: Write failing exam contract tests**

```dart
test('accepts both known first-column headers', () {
  expect(parser.parse(loadHtml('exam-page.html')), isNotEmpty);
  expect(parser.parse(examPageWithCourseNumberHeader), isNotEmpty);
});

test('a structurally valid empty exam table is complete', () {
  expect(parser.parse(loadHtml('exam-empty.html')), isEmpty);
});

test('rejects missing table, duplicate table, bad headers, cells, and time', () {
  for (final html in malformedExamPages) {
    expect(() => parser.parse(html),
        throwsA(isA<JwSyncException>().having((e) => e.code, 'code', 'page_contract_changed')));
  }
});
```

- [ ] **Step 3: Run the test and verify failure**

Run: `E:\flutter\flutter\bin\flutter.bat test test/features/sync/jw/jw_exam_table_parser_test.dart`

Expected: FAIL because the parser is absent.

- [ ] **Step 4: Implement table-scoped HTML parsing**

Use `package:html/parser.dart`, normalize whitespace, require eight columns, allow first header `课程号` or `课堂号`, and require all fields except notes. Parse only `YYYY-MM-DD HH:MM~HH:MM`; reject `end <= start`. Never parse a visually similar table outside `#exams`.

- [ ] **Step 5: Run focused tests**

Run: `E:\flutter\flutter\bin\flutter.bat test test/features/sync/jw/jw_exam_table_parser_test.dart`

Expected: PASS.

- [ ] **Step 6: Commit**

```powershell
git add app/pubspec.yaml app/pubspec.lock app/lib/features/sync/jw/data/jw_exam_table_parser.dart app/test/features/sync/jw/jw_exam_table_parser_test.dart
git commit -m "feat: parse JW exam tables in Dart"
```

---

### Task 5: Build Canonical SourceBundle 1.0 and Compare the Python Oracle

**Files:**
- Create: `app/lib/features/sync/jw/data/jw_source_bundle_builder.dart`
- Create: `app/test/fixtures/jw/python-oracle-bundle.json`
- Create: `app/test/features/sync/jw/jw_source_bundle_builder_test.dart`
- Create: `app/tool/compare_jw_bundles.dart`
- Create: `tests/jw/generate_flutter_oracle_fixture.py`
- Test against: `app/lib/features/import/data/source_bundle_decoder.dart`

**Interfaces:**
- Consumes: `JwCourseSnapshot`, `List<JwExam>`, account ID, selected semester, injected bundle ID, and injected Beijing clock.
- Produces: UTF-8 `Uint8List` accepted by the existing `SourceBundleDecoder`.

- [ ] **Step 1: Generate and commit one sanitized Python oracle**

Add a deterministic helper that imports `build_jw_source_bundle`, reads only `tests/fixtures/jw/course-datum.json` and `exam-page.html`, uses account `account-fixture`, semester `421 / 2026spring`, UUID `00000000-0000-4000-8000-000000000001`, and Beijing time `2026-03-01 08:00:00+08:00`, then writes UTF-8 JSON to `app/test/fixtures/jw/python-oracle-bundle.json`. Run:

```powershell
conda run -n ustc_assistant python tests/jw/generate_flutter_oracle_fixture.py
```

The helper must validate the result with `validate_source_bundle` before writing. The committed fixture must contain no remote personal context and no raw source response.

- [ ] **Step 2: Write failing canonical bundle tests**

```dart
test('Dart bundle matches Python business payload', () {
  final actual = jsonDecode(utf8.decode(builder.build(
    courses: courseParser.parse(loadDatum()),
    exams: examParser.parse(loadExamHtml()),
    accountId: 'account-fixture',
    semester: spring,
    bundleId: '00000000-0000-4000-8000-000000000001',
    collectedAt: DateTime.parse('2026-03-01T08:00:00+08:00'),
  )));
  final expected = loadJson('python-oracle-bundle.json');
  expect(stripProducerAndCollectionIdentity(actual),
      stripProducerAndCollectionIdentity(expected));
});

test('existing decoder accepts complete and empty native bundles', () {
  expect(() => decoder.decode(nonEmptyBytes), returnsNormally);
  expect(() => decoder.decode(emptyBytes), returnsNormally);
});
```

- [ ] **Step 3: Run the builder test and verify failure**

Run: `E:\flutter\flutter\bin\flutter.bat test test/features/sync/jw/jw_source_bundle_builder_test.dart`

Expected: FAIL because the builder is absent.

- [ ] **Step 4: Implement direct SourceBundle construction**

Use these exact identity prefixes:

```text
ustc_jw:<semesterKey>:series:lesson:<lessonId>
ustc_jw:<semesterKey>:event:course-occurrence:<lessonId>:<groupId>:<YYYYMMDD>:<HHmm>:<HHmm>:<discriminator>
ustc_jw:<semesterKey>:event:exam:<courseCode>:<24-char-sha256-prefix>
```

Set course defaults to `normal/unknown/unknown`, exam defaults to `critical/must_go/unknown`, and emit no source relations. Include both snapshot components with observed record counts. Set producer to `ustc_assistant_flutter`, the app version, and `windows`.

- [ ] **Step 5: Implement the comparison tool**

`compare_jw_bundles.dart <python.json> <dart.json>` decodes both through `SourceBundleDecoder`, removes only `bundleId`, `collectedAt`, and `producer`, canonicalizes map keys, prints a safe path-free mismatch summary, and exits nonzero on a business difference. It must not print bundle bodies.

- [ ] **Step 6: Run bundle, import, and semantic tests**

Run: `E:\flutter\flutter\bin\flutter.bat test test/features/sync/jw/jw_source_bundle_builder_test.dart test/features/import/source_bundle_decoder_test.dart test/features/import/import_service_test.dart`

Expected: PASS.

- [ ] **Step 7: Commit**

```powershell
git add app/lib/features/sync/jw/data/jw_source_bundle_builder.dart app/test/fixtures/jw/python-oracle-bundle.json app/test/features/sync/jw/jw_source_bundle_builder_test.dart app/tool/compare_jw_bundles.dart tests/jw/generate_flutter_oracle_fixture.py
git commit -m "feat: build JW SourceBundle in Dart"
```

---

### Task 6: Define the Controlled Web Session and Collection Workflow

**Files:**
- Create: `app/lib/features/sync/jw/domain/authenticated_web_session.dart`
- Create: `app/lib/features/sync/jw/domain/jw_source_gateway.dart`
- Create: `app/lib/features/sync/jw/data/jw_web_message_protocol.dart`
- Create: `app/lib/features/sync/jw/application/jw_collector.dart`
- Create: `app/test/features/sync/jw/jw_web_message_protocol_test.dart`
- Create: `app/test/features/sync/jw/jw_collector_test.dart`

**Interfaces:**
- Produces: a closed set of browser methods; no `executeScript(String)` or `navigate(String)` appears in shared code.
- Produces: resumable native gateway result types consumed by Tasks 8-10.

- [ ] **Step 1: Write contract tests that forbid arbitrary operations**

The public session surface must be exactly equivalent to:

```dart
abstract interface class AuthenticatedWebSession {
  Stream<WebSessionSignal> get signals;
  Future<WebSessionAuthState> checkAuthentication();
  Future<bool> verifyAccount(String expectedUsername);
  Future<void> beginInteractiveLogin({required String username, String? password});
  Future<Map<String, Object?>> readCoursePageContext();
  Future<Map<String, Object?>> fetchCourseGetData({required int semesterId, required String dataId});
  Future<Map<String, Object?>> fetchCourseDatum(List<int> publishLessonIds);
  Future<String> readExamTableHtml();
  Future<void> stop();
  Future<void> clearCurrentAccountSession();
  Future<void> dispose();
}

enum WebSessionAuthState {
  authenticated,
  needsLogin,
  needsSmsVerification,
  accountUnverified,
}

class WebSessionSignal {
  const WebSessionSignal(this.state);
  final WebSessionAuthState state;
}
```

`WebSessionAuthState` is `authenticated`, `needsLogin`, `needsSmsVerification`, or `accountUnverified`. Signals never carry URLs, DOM, credentials, codes, or response bodies.

Define the gateway request/result contract in this task so every later layer uses the same types:

```dart
class JwCollectionRequest {
  const JwCollectionRequest({
    required this.accountId,
    required this.expectedUsername,
    required this.interactiveAllowed,
    this.selectedSemester,
    this.forceSemesterSelection = false,
    this.onProgress,
  });
  final String accountId;
  final String expectedUsername;
  final bool interactiveAllowed;
  final JwSemester? selectedSemester;
  final bool forceSemesterSelection;
  final void Function(JwProgressPhase phase)? onProgress;
}

enum JwInteractionKind { login, smsVerification, semesterSelection }
enum JwProgressPhase { checkingSession, interactiveLogin, loadingSemesters, collecting, normalizing }

sealed class JwGatewayResult {
  const JwGatewayResult();
}

final class JwGatewayBundle extends JwGatewayResult {
  const JwGatewayBundle(this.bytes, this.semester);
  final Uint8List bytes;
  final JwSemester semester;
}

final class JwGatewayNeedsInteraction extends JwGatewayResult {
  const JwGatewayNeedsInteraction({
    required this.jobId,
    required this.kind,
    this.semesters = const [],
  });
  final String jobId;
  final JwInteractionKind kind;
  final List<JwSemester> semesters;
}

final class JwGatewayFailed extends JwGatewayResult {
  const JwGatewayFailed(this.code);
  final String code;
}

final class JwGatewayCancelled extends JwGatewayResult {
  const JwGatewayCancelled();
}

abstract interface class JwSourceGateway {
  Future<JwGatewayResult> start(JwCollectionRequest request);
  Future<JwGatewayResult> resumeLogin(String jobId, {String? password});
  Future<JwGatewayResult> continueAfterSms(String jobId);
  Future<JwGatewayResult> selectSemester(String jobId, JwSemester semester);
  Future<JwGatewayResult> cancel(String jobId);
  Future<void> dispose();
}

class JwCollectedSnapshot {
  const JwCollectedSnapshot({required this.courses, required this.exams});
  final JwCourseSnapshot courses;
  final List<JwExam> exams;
}
```

- [ ] **Step 2: Write collector tests with a fake session**

```dart
test('uses publishLessonIds and skips datum for a valid empty semester', () async {
  final session = FakeSession(getData: loadJson('get-data-empty.json'));
  final capture = await collector.collect(session, spring);
  expect(session.datumCalls, isEmpty);
  expect(capture.courses.occurrences, isEmpty);
  expect(session.examReadCount, 1);
});

test('never substitutes legacy lessonIds', () async {
  final session = FakeSession(getData: {
    'lessonIds': [1, 2],
    'publishLessonIds': [2],
  });
  await collector.collect(session, spring);
  expect(session.datumCalls.single, [2]);
});

test('one malformed component prevents a capture result', () async {
  final session = FakeSession(examHtml: '<table id="wrong"></table>');
  await expectLater(collector.collect(session, spring),
      throwsA(isA<JwSyncException>().having((e) => e.code, 'code', 'incomplete_snapshot')));
});
```

- [ ] **Step 3: Run tests and verify failure**

Run: `E:\flutter\flutter\bin\flutter.bat test test/features/sync/jw/jw_web_message_protocol_test.dart test/features/sync/jw/jw_collector_test.dart`

Expected: FAIL because contracts and collector are absent.

- [ ] **Step 4: Implement version-1 envelopes and the fixed workflow**

Commands use `{protocolVersion: 1, requestId, operation, payload}` and results use `{protocolVersion: 1, requestId, status, payload}`. Allowed operations are `check_auth`, `begin_login`, `read_course_context`, `fetch_get_data`, `fetch_datum`, `read_exam_table`, and `verify_account`. Reject unknown keys, duplicate replies, oversized encoded results, and requests completed after cancellation.

The collector executes course context -> get-data -> optional datum -> exam table, wraps parser failures as `incomplete_snapshot`, and applies the total five-minute collection timeout.

- [ ] **Step 5: Run focused tests**

Run: `E:\flutter\flutter\bin\flutter.bat test test/features/sync/jw/jw_web_message_protocol_test.dart test/features/sync/jw/jw_collector_test.dart`

Expected: PASS.

- [ ] **Step 6: Commit**

```powershell
git add app/lib/features/sync/jw app/test/features/sync/jw
git commit -m "feat: define controlled JW web collection"
```

---

### Task 7: Implement the Windows WebView2 Session and Visible Login Pane

**Files:**
- Modify: `app/pubspec.yaml`
- Modify: `app/pubspec.lock`
- Modify: `app/windows/flutter/generated_plugin_registrant.cc`
- Modify: `app/windows/flutter/generated_plugin_registrant.h`
- Modify: `app/windows/flutter/generated_plugins.cmake`
- Create: `app/lib/features/sync/jw/data/jw_web_scripts.dart`
- Create: `app/lib/features/sync/jw/platform/windows/webview_controller_port.dart`
- Create: `app/lib/features/sync/jw/platform/windows/windows_webview_profile_store.dart`
- Create: `app/lib/features/sync/jw/platform/windows/windows_webview_session.dart`
- Create: `app/lib/features/sync/jw/presentation/jw_login_pane.dart`
- Create: `app/test/features/sync/jw/jw_web_scripts_test.dart`
- Create: `app/test/features/sync/jw/windows_webview_session_test.dart`
- Create: `app/test/features/sync/jw/jw_login_pane_test.dart`

**Interfaces:**
- Consumes: Task 6 `AuthenticatedWebSession` protocol.
- Produces: `WindowsWebViewSessionManager.open(accountId)` and `clear(accountId)`; only one controller/environment may live at a time.

- [ ] **Step 1: Add `webview_flutter_windows: 1.1.1` and regenerate plugins**

Run: `E:\flutter\flutter\bin\flutter.bat pub get`

Expected: lockfile and Windows plugin registrant add only the WebView dependency and its transitive packages.

- [ ] **Step 2: Write fixed-script and profile-isolation tests**

```dart
test('scripts are fixed constants and payload travels through web messages', () {
  expect(JwWebScripts.documentBootstrap, contains('protocolVersion'));
  expect(JwWebScripts.documentBootstrap, contains('chrome.webview'));
  expect(JwWebScripts.documentBootstrap, isNot(contains('489951')));
  expect(JwWebScripts.documentBootstrap, isNot(contains('PB12345678')));
});

test('switching account disposes the old controller before environment change', () async {
  await manager.open('account-a');
  await manager.open('account-b');
  expect(driver.calls, ['init:a-hash', 'dispose:a-hash', 'init:b-hash']);
});
```

Also test popup/download/permission denial, HTTP/foreign-host navigation denial, one login submit per document instance, headless `needs_login`, SMS visibility, request/response timeout, stale reply rejection, and cancellation calling `stop`.

- [ ] **Step 3: Run tests and verify failure**

Run: `E:\flutter\flutter\bin\flutter.bat test test/features/sync/jw/jw_web_scripts_test.dart test/features/sync/jw/windows_webview_session_test.dart test/features/sync/jw/jw_login_pane_test.dart`

Expected: FAIL because the Windows adapter is absent.

- [ ] **Step 4: Implement message-only scripts**

Install one versioned on-document script before navigation. Dart sends JSON with `postWebMessage`; JavaScript validates operation and typed payload, checks `location.protocol` and `location.hostname`, performs only the registered action, and returns JSON with `window.chrome.webview.postMessage`. Never interpolate user/page values into source strings.

For login, accept selectors `input[name="username"], #username`, `input[type="password"]`, and `#submitBtn, button.login-button`; mark the document before clicking so it cannot submit twice. On `id.ustc.edu.cn`, an OTP-like input or a post-credential page without the active password form maps to `needs_sms_verification`; an unknown structure maps to `page_contract_changed` while leaving the visible pane available.

- [ ] **Step 5: Implement profile lifecycle and controller wrapper**

Use `<LocalApplicationSupport>/ustc_assistant/webview/jw/<sha256(accountId)[0..24]>`. Before changing `userDataPath`, dispose the existing controller and release the reference-counted environment. `clear(accountId)` verifies the resolved target remains under the JW profile root, closes that profile, and removes only that account directory. Do not include account IDs in directory names or logs.

- [ ] **Step 6: Implement the login pane**

The pane shows the existing controller only for interactive login/SMS, has an AppBar close action that calls cancellation, shows no credentials in Flutter widgets, and keeps the WebView mounted while SMS is entered. Background session checks never construct or display the pane.

- [ ] **Step 7: Run tests, analysis, and Windows build smoke check**

Run:

```powershell
E:\flutter\flutter\bin\flutter.bat test test/features/sync/jw
E:\flutter\flutter\bin\flutter.bat analyze
E:\flutter\flutter\bin\flutter.bat build windows --debug
```

Expected: all commands PASS; generated plugin files compile; WebView2 absence is represented by safe `request_failed`, not a crash.

- [ ] **Step 8: Commit**

```powershell
git add app/pubspec.yaml app/pubspec.lock app/windows/flutter app/lib/features/sync/jw app/test/features/sync/jw
git commit -m "feat: add Windows JW WebView session"
```

---

### Task 8: Implement Resumable Native JW Jobs

**Files:**
- Create: `app/lib/features/sync/jw/application/native_jw_source_gateway.dart`
- Create: `app/test/features/sync/jw/native_jw_source_gateway_test.dart`

**Interfaces:**
- Consumes: session manager, collector, bundle builder, and a selected-semester snapshot supplied by the coordinator.
- Produces: `JwGatewayBundle`, `JwGatewayNeedsInteraction`, `JwGatewayFailed`, and `JwGatewayCancelled`.

- [ ] **Step 1: Write the state-machine tests**

```dart
test('background expired session pauses without showing login', () async {
  final result = await gateway.start(JwCollectionRequest(
    accountId: 'account-a',
    expectedUsername: 'synthetic-user',
    interactiveAllowed: false,
  ));
  expect(result, isA<JwGatewayNeedsInteraction>()
      .having((e) => e.kind, 'kind', JwInteractionKind.login));
  expect(session.visibleRequests, isEmpty);
});

test('first authenticated run asks for an explicit semester', () async {
  final result = await gateway.start(request);
  expect(result, isA<JwGatewayNeedsInteraction>()
      .having((e) => e.kind, 'kind', JwInteractionKind.semesterSelection));
  expect((result as JwGatewayNeedsInteraction).semesters, isNotEmpty);
});

test('cancel discards capture and never builds a bundle', () async {
  final pending = await gateway.start(request);
  final result = await gateway.cancel(pending.jobId);
  expect(result, isA<JwGatewayCancelled>());
  expect(builder.callCount, 0);
});
```

Also test successful session reuse, login -> SMS -> authenticated continuation, exact account verification before any course request, account mismatch, changed catalog, response too large, total timeout, same-account single-flight, progress ordering, and password release after the first login message.

- [ ] **Step 2: Run the test and verify failure**

Run: `E:\flutter\flutter\bin\flutter.bat test test/features/sync/jw/native_jw_source_gateway_test.dart`

Expected: FAIL because the gateway is absent.

- [ ] **Step 3: Implement job ownership and transitions**

Jobs retain only safe IDs and state. `resumeLogin` sends its password argument once to `beginInteractiveLogin` and never stores it in the job. When it returns `needsSmsVerification`, the UI keeps the same pane visible and immediately awaits `continueAfterSms`; the user still enters and submits the SMS code manually. Verify the authenticated account before catalog read. Re-read the catalog on every collection and reconcile the request's selection against that catalog; a user choice is retained in the in-memory job and returned in `JwGatewayBundle`, but this layer never writes `SourceConfigs`. Build a bundle only after both components parse completely.

- [ ] **Step 4: Run native gateway tests**

Run: `E:\flutter\flutter\bin\flutter.bat test test/features/sync/jw/native_jw_source_gateway_test.dart test/features/sync/jw/jw_collector_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add app/lib/features/sync/jw/application/native_jw_source_gateway.dart app/test/features/sync/jw/native_jw_source_gateway_test.dart
git commit -m "feat: orchestrate native JW collection jobs"
```

---

### Task 9: Route JW Through the Native Gateway While Keeping Young on Bridge

**Files:**
- Modify: `app/lib/features/sync/domain/sync_state.dart`
- Modify: `app/lib/features/sync/data/bridge_client.dart`
- Modify: `app/lib/features/sync/application/sync_coordinator.dart`
- Modify: `app/lib/features/sync/presentation/sync_page.dart`
- Modify: `app/test/features/sync/bridge_client_test.dart`
- Modify: `app/test/features/sync/sync_coordinator_test.dart`

**Interfaces:**
- `SyncCoordinator` consumes both `Future<JwSourceGateway> Function()` and `Future<BridgeGateway> Function()`, plus an explicit temporary `JwSyncBackend` migration policy.
- `SyncCoordinator` also consumes `JwSemesterSelectionStore`; it loads before native collection and saves against the resolved real account before import.
- `SyncNeedsUserAction` carries `kind`, `jobId`, and optional validated semester options.
- Bridge collection no longer requires JW capabilities for `SyncSource.youngSchedule`.

Add these temporary migration/domain enums in `sync_state.dart`:

```dart
enum JwSyncBackend { legacyBridge, native }
enum SyncUserActionKind { login, smsVerification, semesterSelection }
```

`JwSyncBackend` exists only through Task 11; Task 12 removes it when native JW becomes unconditional.

- [ ] **Step 1: Write production-routing regressions first**

```dart
test('native-configured JW sync never starts Bridge collection', () async {
  final coordinator = buildCoordinator(jwBackend: JwSyncBackend.native);
  final outcome = await coordinator.sync(SyncSource.jw,
      trigger: SyncTrigger.manual, accountId: account.id);
  expect(outcome, isA<SyncSucceeded>());
  expect(nativeJw.startCount, 1);
  expect(bridge.startCount, 0);
});

test('Young schedule still uses Bridge without a semester capability', () async {
  final coordinator = buildCoordinator(jwBackend: JwSyncBackend.native);
  await coordinator.sync(SyncSource.youngSchedule,
      trigger: SyncTrigger.manual, accountId: account.id);
  expect(bridge.sources, [SyncSource.youngSchedule]);
  expect(nativeJw.startCount, 0);
});

test('native partial failure does not call ImportService or update last success', () async {
  nativeJw.result = const JwGatewayFailed('incomplete_snapshot');
  final outcome = await coordinator.sync(SyncSource.jw,
      trigger: SyncTrigger.manual, accountId: account.id);
  expect(outcome, isA<SyncFailed>());
  expect(importCalls, 0);
  expect((await coordinator.stateFor(SyncSource.jw, account.id)).lastSuccessfulAt, isNull);
});

test('native phases are persisted as safe progress names', () async {
  await coordinator.sync(SyncSource.jw,
      trigger: SyncTrigger.manual, accountId: account.id);
  expect(recordedRunStates, containsAllInOrder([
    'checking_session',
    'loading_semesters',
    'collecting',
    'normalizing',
    'importing',
    'success',
  ]));
});

test('first login confirms the account before saving semester and importing', () async {
  final outcome = await coordinator.firstLoginSync(
    SyncSource.jw,
    username: 'synthetic-user',
    password: 'synthetic-password',
    savePassword: true,
  );
  expect(outcome, isA<SyncSucceeded>());
  expect(await semesterStore.load(confirmedAccountId), spring);
  expect(callOrder, [
    'confirm:$provisionalAccountId',
    'save:$confirmedAccountId',
    'import:$confirmedAccountId',
  ]);
});
```

- [ ] **Step 2: Run coordinator tests and verify failure**

Run: `E:\flutter\flutter\bin\flutter.bat test test/features/sync/sync_coordinator_test.dart test/features/sync/bridge_client_test.dart`

Expected: FAIL because the coordinator has no explicit native JW backend.

- [ ] **Step 3: Refactor source-specific branches without changing import semantics**

Keep existing run rows, retry backoff, 12-hour freshness, provisional-account confirmation, action logs, and `ImportService` call. Before native collection, load the account's selected snapshot and pass it in `JwCollectionRequest`; after a terminal bundle, resolve/confirm the actual local account, save `result.semester` under that now-persisted account, then import the bundle. Never write a config row before its `LocalAccounts` parent exists. Persist `checking_session`, `loading_semesters`, `collecting`, `normalizing`, and `importing` as safe active run states; `stateFor` maps them to `SyncPhase.running` and returns the exact string in `progressPhase`. `recoverInterruptedRuns` must mark every active state interrupted, not only the old literal `running`. Map native interaction kinds to stable result codes and `needs_user_action`; background results are returned without UI. Remove `BridgeSemesterCapability? semesterOverride` from native call sites. During migration, every constructor must explicitly choose `JwSyncBackend.native` or `JwSyncBackend.legacyBridge`; there is no null/default fallback. Existing App composition chooses `legacyBridge` until Task 11's preview branch, while focused tests choose `native`. Keep legacy Bridge `/collect/jw` methods only for the preview/oracle period.

- [ ] **Step 4: Test interrupted runs, first login, reauthentication, and syncAll**

Run: `E:\flutter\flutter\bin\flutter.bat test test/features/sync/sync_coordinator_test.dart test/features/sync/sync_page_test.dart test/integration/first_milestone_flow_test.dart`

Expected: PASS, including Young behavior and old business import behavior.

- [ ] **Step 5: Commit**

```powershell
git add app/lib/features/sync app/test/features/sync app/test/integration/first_milestone_flow_test.dart
git commit -m "refactor: split native JW from Bridge sync"
```

---

### Task 10: Integrate Login, SMS, Semester Choice, and Account Session Clearing

**Files:**
- Create: `app/lib/features/sync/jw/presentation/jw_semester_dialog.dart`
- Modify: `app/lib/features/sync/presentation/sync_page.dart`
- Modify: `app/lib/features/accounts/application/account_service.dart`
- Modify: `app/lib/features/accounts/presentation/accounts_page.dart`
- Modify: `app/lib/features/settings/application/settings_service.dart`
- Modify: `app/lib/features/settings/presentation/settings_page.dart`
- Modify: `app/lib/app/router.dart`
- Modify: `app/test/features/sync/sync_page_test.dart`
- Modify: `app/test/features/accounts/account_service_test.dart`
- Modify: `app/test/features/accounts/accounts_page_test.dart`
- Modify: `app/test/features/settings/settings_test.dart`

**Interfaces:**
- Sync UI resolves login, SMS, and semester actions by kind.
- Account/session clearing callback becomes `Future<void> Function(String accountId)`.
- Settings reads the persisted dynamic semester and never exposes a compiled default.

- [ ] **Step 1: Write widget tests for all interaction states**

```dart
testWidgets('semester action requires one explicit selection', (tester) async {
  await pumpSyncPage(tester, outcome: semesterRequiredOutcome);
  expect(find.byType(RadioListTile<JwSemester>), findsNWidgets(3));
  expect(find.byKey(const Key('confirm-jw-semester')), findsOneWidget);
});

testWidgets('SMS keeps WebView pane visible and cancel exits synchronization', (tester) async {
  await pumpSyncPage(tester, outcome: smsOutcome);
  expect(find.byKey(const Key('jw-login-pane')), findsOneWidget);
  await tester.tap(find.byKey(const Key('cancel-jw-login')));
  expect(fakeGateway.cancelCount, 1);
});

testWidgets('background needs_login is status only', (tester) async {
  await pumpSyncPage(tester, backgroundResultCode: 'needs_login');
  expect(find.byKey(const Key('jw-login-pane')), findsNothing);
  expect(find.textContaining('需要登录'), findsOneWidget);
});
```

- [ ] **Step 2: Run widget tests and verify failure**

Run: `E:\flutter\flutter\bin\flutter.bat test test/features/sync/sync_page_test.dart test/features/accounts/accounts_page_test.dart test/features/settings/settings_test.dart`

Expected: FAIL because the current UI has one generic external-browser confirmation.

- [ ] **Step 3: Implement the interaction UI**

For JW manual login, show the in-app pane directly after the user invokes login/sync; autofill and submit happen inside the session. Display a short instruction only when SMS is needed. For semester choice, sort catalog entries by start date descending, use a radio list, require explicit confirmation, and resume the same job. Add a `选择同步学期` command beside JW; it starts a catalog refresh with `forceSemesterSelection: true` and triggers sync after selection.

- [ ] **Step 4: Replace hard-coded semester settings**

Remove `SettingsService.defaultJwSemester`, `setJwSemesterOverride`, and `resetJwSemester`. Replace them with `selectedJwSemester()` and `clearJwSemesterSelection(confirmed: true)`. Settings displays the complete persisted selection and receives an `onReselectJwSemester` callback from `router.dart`; that callback routes to Sync with a force-selection intent. Clearing selection does not delete events, source records, overlays, or import batches.

- [ ] **Step 5: Make browser-session clearing account-specific**

Change `AccountService.clearDedicatedBrowserSession(String accountId)` and all callers. Deleting credentials remains independent. Complete reset captures the account ID before deleting its local row, commits database deletion, then clears only that WebView profile; preserve the existing post-commit error wrapper.

- [ ] **Step 6: Run focused UI and account tests**

Run: `E:\flutter\flutter\bin\flutter.bat test test/features/sync/sync_page_test.dart test/features/accounts/account_service_test.dart test/features/accounts/accounts_page_test.dart test/features/settings/settings_test.dart test/features/settings/complete_reset_flow_test.dart`

Expected: PASS.

- [ ] **Step 7: Commit**

```powershell
git add app/lib/features/sync app/lib/features/accounts app/lib/features/settings app/lib/app/router.dart app/test/features/sync app/test/features/accounts app/test/features/settings
git commit -m "feat: add native JW login and semester UI"
```

---

### Task 11: Compose Startup Sync and Run the Native Preview Acceptance Gate

**Files:**
- Create: `app/lib/features/sync/application/sync_composition.dart`
- Modify: `app/lib/app/app.dart`
- Modify: `app/lib/app/router.dart`
- Modify: `app/lib/features/sync/presentation/sync_page.dart`
- Create: `app/test/features/sync/sync_composition_test.dart`
- Modify: `app/test/integration/first_milestone_flow_test.dart`
- Create: `docs/acceptance/flutter-native-jw.md`

**Interfaces:**
- `SyncComposition` owns one native WebView session manager and a lazy Bridge used only by non-JW sources.
- Temporary preview switch: `const bool.fromEnvironment('USTC_NATIVE_JW_PREVIEW', defaultValue: false)`.

- [ ] **Step 1: Write composition lifetime tests**

```dart
test('preview composition routes JW native and Young to Bridge', () async {
  final composition = await buildComposition(nativeJwPreview: true);
  await composition.coordinator.sync(SyncSource.jw, trigger: SyncTrigger.manual, accountId: 'a');
  await composition.coordinator.sync(SyncSource.youngSchedule, trigger: SyncTrigger.manual, accountId: 'a');
  expect(nativeJw.startCount, 1);
  expect(bridge.startCount, 1);
});

test('startup expired JW session records needs_login without visible pane', () async {
  await composition.runStartupSync('a');
  expect(nativeSession.visibleRequests, isEmpty);
  expect((await coordinator.stateFor(SyncSource.jw, 'a')).resultCode, 'needs_login');
});
```

- [ ] **Step 2: Run tests and verify failure**

Run: `E:\flutter\flutter\bin\flutter.bat test test/features/sync/sync_composition_test.dart test/integration/first_milestone_flow_test.dart`

Expected: FAIL because startup and routes construct Bridge independently.

- [ ] **Step 3: Implement shared composition and disposal**

Create composition once in `UstcAssistantApp`, pass it to router/loaders, reuse it for post-frame automatic sync, and dispose WebView/Bridge before closing the owned database. The preview switch selects native JW only; non-preview behavior remains the current Bridge path until Task 12. Do not add runtime silent fallback inside either branch.

- [ ] **Step 4: Write the owner-run acceptance document**

Each item ends in `完成：` and includes:

1. WebView2 runtime/startup.
2. First CAS login, automatic username/password submit, manual SMS.
3. Dynamic catalog and mandatory semester choice.
4. 2026 spring (`semesterId=421`) course and exam result inspection.
5. Valid empty course and empty exam scenarios.
6. Session reuse and expired background `needs_login` without popup.
7. Account mismatch and two-account profile isolation.
8. Semester switch preserving old data and `UserOverlay`.
9. Cancellation/network interruption preserving the last successful snapshot.
10. Dart/Python sanitized bundle comparison.
11. Young schedule still synchronizing through Bridge.

- [ ] **Step 5: Run the automated pre-acceptance gate**

Run:

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat analyze
E:\flutter\flutter\bin\flutter.bat test
E:\flutter\flutter\bin\flutter.bat build windows --release
Pop-Location
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
```

Expected: all commands PASS. Record exact counts and HEAD in the acceptance document without marking manual items complete.

- [ ] **Step 6: Launch preview and stop for owner interaction**

Run:

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat run -d windows --dart-define=USTC_NATIVE_JW_PREVIEW=true
Pop-Location
```

Expected: owner completes the checklist with a real school session. Save only normalized/sanitized comparison bundles under `tmp/private/`; do not commit them.

- [ ] **Step 7: Enforce the hard stop**

Do not begin Task 12 until every mandatory item in `docs/acceptance/flutter-native-jw.md` is marked successful by the owner. If `publishLessonIds` differs materially from the Python oracle, document counts and semantic categories without raw data, obtain owner approval, and add a regression fixture before proceeding.

- [ ] **Step 8: Commit preview composition and acceptance artifacts**

```powershell
git add app/lib/app app/lib/features/sync app/test/features/sync app/test/integration/first_milestone_flow_test.dart docs/acceptance/flutter-native-jw.md
git commit -m "test: validate native JW preview path"
```

---

### Task 12: Cut Production JW Over to Dart and Synchronize Documentation

**Files:**
- Modify: `app/lib/features/sync/application/sync_composition.dart`
- Modify: `app/lib/features/sync/application/sync_coordinator.dart`
- Modify: `app/lib/features/sync/data/bridge_client.dart`
- Modify: `app/lib/features/sync/presentation/sync_page.dart`
- Delete: `app/lib/core/config/generated_source_defaults.dart`
- Modify: `app/test/features/sync/sync_composition_test.dart`
- Modify: `app/test/features/sync/sync_coordinator_test.dart`
- Modify: `app/test/features/settings/settings_test.dart`
- Modify: `docs/data-sources/jw.md`
- Modify: `docs/architecture.md`
- Modify: `README.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Production invariant: `SyncSource.jw -> NativeJwSourceGateway` with no feature flag and no Bridge fallback.
- Non-JW Bridge interfaces remain available and unchanged to their callers.

- [ ] **Step 1: Write the final no-Python production regression**

```dart
test('default production composition cannot launch Python for JW', () async {
  final composition = await buildProductionComposition(
    bridgeFactory: () => throw StateError('Python must not start for JW'),
    nativeJwFactory: () async => nativeJw,
  );
  final outcome = await composition.coordinator.sync(
    SyncSource.jw,
    trigger: SyncTrigger.manual,
    accountId: 'account-a',
  );
  expect(outcome, isA<SyncSucceeded>());
});
```

Add a second test proving Young still starts Bridge, so a blanket Bridge deletion cannot pass.

- [ ] **Step 2: Run the regression and verify the preview branch fails the invariant**

Run: `E:\flutter\flutter\bin\flutter.bat test test/features/sync/sync_composition_test.dart test/features/sync/sync_coordinator_test.dart`

Expected: FAIL until the preview switch/default Bridge JW branch is removed.

- [ ] **Step 3: Perform the irreversible production routing change**

Remove `USTC_NATIVE_JW_PREVIEW`, remove Bridge JW capabilities from production composition, and delete all settings/UI references to generated default semesters. Keep legacy Bridge JW request code only if the oracle tool imports it explicitly; annotate it as non-production and ensure no `SyncCoordinator` reference reaches it. Delete `generated_source_defaults.dart` after `rg` proves it has no references.

- [ ] **Step 4: Update stable documentation**

Document:

- WebView2 requirement and in-app CAS/SMS flow.
- Per-account dynamic semester selection and no hard-coded default.
- Native Windows JW data flow and remaining Python-backed sources.
- Controlled operation/host boundary and no Cookie export.
- Error states, 12-hour background behavior, manual acceptance status, and future mobile adapter boundary.
- Current directory responsibilities in `AGENTS.md`; do not claim Android/iOS collection exists.

- [ ] **Step 5: Run repository-wide verification from a clean process**

Run:

```powershell
Push-Location app
E:\flutter\flutter\bin\flutter.bat analyze
E:\flutter\flutter\bin\flutter.bat test
E:\flutter\flutter\bin\flutter.bat build windows --release
Pop-Location
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
git diff --check
git status --short
```

Expected: analysis/build/compilation pass; all tests pass; `git diff --check` is clean; status contains only this task's intended files and pre-existing user files.

- [ ] **Step 6: Re-run the production smoke path**

Launch the Release build without any Dart define. Manually invoke JW sync and verify no Python process starts; invoke Young sync and verify Bridge still starts. Confirm the selected semester shown in Settings matches the dynamic catalog choice.

- [ ] **Step 7: Commit**

```powershell
git add app/lib app/test docs/data-sources/jw.md docs/architecture.md README.md AGENTS.md
git commit -m "feat: cut JW synchronization over to Flutter"
```

---

## Final Review Checklist

- [ ] Every design requirement in `docs/superpowers/specs/2026-08-05-flutter-native-jw-source-design.md` maps to a Task above.
- [ ] No production branch infers a semester or references `461` as a fallback.
- [ ] `rg -n "SyncSource\.jw|collect/jw|BridgeSemesterCapability|kDefaultJwSemester" app/lib` shows no production JW Bridge/default path.
- [ ] Native capture failures do not call `ImportService` and preserve the previous successful data.
- [ ] WebView profile cleanup is account-scoped and credentials remain a separate operation.
- [ ] Manual acceptance is recorded as manual evidence, not inferred from automated tests.
- [ ] Python remains available only where this milestone explicitly retains it.
