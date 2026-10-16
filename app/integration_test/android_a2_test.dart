// Design basis: docs/milestones/android-apk/plan.md A2; docs/architecture/07,
// 09 K-01-K-06, 10-13; and docs/workflow.md (15). All source pages, accounts,
// credentials, events, and exams below are loopback fixtures. These tests use
// the formal coordinators and Android credential protection in the isolated
// QA no-backup root; they do not contact a school or model.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/core/young_work_contract.dart';
import 'package:ustc_assistant_m0/data/jw_import_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/jobs/jw_sync_coordinator.dart';
import 'package:ustc_assistant_m0/jobs/jw_sync_port.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_coordinator.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_port.dart';
import 'package:ustc_assistant_m0/platform/android_credential_protector.dart';
import 'package:ustc_assistant_m0/platform/android_directory.dart';
import 'package:ustc_assistant_m0/platform/jw_partition_registry.dart';
import 'package:ustc_assistant_m0/platform/native_database.dart';
import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';
import 'package:ustc_assistant_m0/platform/owned_directory.dart';
import 'package:ustc_assistant_m0/platform/young_partition_registry.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';
import 'package:ustc_assistant_m0/source/young_active_contract.dart';

import 'support/jw_sync_fixture.dart';
import 'support/young_business_fixture.dart';

const _platform = MethodChannel('ustc_assistant/platform_v1');
const _account = 'TEST0001';
const _operationTimeout = Duration(seconds: 90);
const _gateOnly = bool.fromEnvironment('USTC_A2_UNSUPPORTED_SOURCE_ONLY');
final _day = DateTime.utc(2026, 10, 10);
var _fixtureSequence = 0;
final _reportData = <String, Object>{};

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUp(_reportData.clear);
  tearDown(() {
    // Keep the device report to booleans and counts only. Never attach a source
    // response, account, path, event title, or credential to the report.
    binding.reportData = Map<String, Object>.from(_reportData);
  });

  testWidgets(
    'an older provider rejects acquisition but can still clear and drain a registered partition',
    (tester) async {
      await tester.runAsync(() async {
        final root = await _createFixtureRoot();
        final owned = await AndroidDirectories.acquire(root.directory.path);
        final fixture = await JwSyncFixture.start();
        final browser = NativeObservationBrowser();
        try {
          owned.formal.createPlainChildDirectory('jw_partitions_v1');
          final path = owned.formal.createPlainChildDirectory(
            'jw_partitions_v1/jwp-${'a' * 32}',
          );
          final target = ObservationTarget.fixture(fixture.initialUri);
          await expectLater(
            browser.open(session: 1, profilePath: path, target: target),
            throwsA(
              isA<AppFailure>().having(
                (e) => e.code,
                'code',
                FailureCode.unsupportedPlatform,
              ),
            ),
          );
          await browser.open(
            session: 2,
            profilePath: path,
            target: target,
            recoveryOnly: true,
          );
          await browser.close(2);
          expect(await browser.drained(2), isTrue);
          _reportData['missingIsolationRejected'] = true;
          _reportData['cleanupWithoutAuthenticationCapability'] = true;
        } finally {
          await fixture.close();
          await browser.dispose();
          await owned.demo.release();
          await owned.formal.release();
          expect(await _removeFixtureRoot(root), isTrue);
        }
      });
    },
    skip: !Platform.isAndroid || !_gateOnly,
  );

  testWidgets(
    'Android top/frame navigation, unsolicited popup and external protocol remain blocked',
    (tester) async {
      await tester.runAsync(() async {
        final harness = await _AndroidA2Harness.create();
        final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final denied = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var deniedRequests = 0;
        var script = '';
        final malformedSent = Completer<void>();
        source.listen((request) async {
          if (request.uri.path == '/fixture-malformed-sent') {
            if (!malformedSent.isCompleted) malformedSent.complete();
            request.response.statusCode = HttpStatus.noContent;
            await request.response.close();
            return;
          }
          if (request.uri.path == '/fixture-download') {
            request.response.headers.contentType = ContentType.binary;
            request.response.headers.set(
              'content-disposition',
              'attachment; filename="synthetic.bin"',
            );
            request.response.write('synthetic-download');
            await request.response.close();
            return;
          }
          request.response.headers.contentType = ContentType.html;
          request.response.write(
            '<!doctype html><body>Synthetic<script>setTimeout(function(){$script},400)</script></body>',
          );
          await request.response.close();
        });
        denied.listen((request) async {
          deniedRequests++;
          request.response.statusCode = HttpStatus.noContent;
          await request.response.close();
        });
        try {
          final origin = 'http://127.0.0.1:${source.port}';
          final rejected = 'http://127.0.0.1:${denied.port}/denied';
          final cases = <BrowserDiagnosticCode, String>{
            BrowserDiagnosticCode.topNavigationBlocked:
                'location.href="$rejected"',
            BrowserDiagnosticCode.frameNavigationBlocked:
                'const f=document.createElement("iframe");f.src="$rejected";document.body.appendChild(f)',
            BrowserDiagnosticCode.popupBlocked: 'window.open("$rejected")',
            BrowserDiagnosticCode.externalProtocolBlocked:
                'location.href="mailto:fixture@example.invalid"',
            BrowserDiagnosticCode.downloadBlocked:
                'location.href="/fixture-download"',
          };
          harness.directories.demo.createPlainChildDirectory('observation_v1');
          var sequence = 1000;
          for (final entry in cases.entries) {
            script = entry.value;
            final session = ++sequence;
            final diagnostics = <String>[];
            final subscription = harness.browser.events.listen((e) {
              if (diagnostics.length < 20) {
                diagnostics.add(
                  '${e.kind.name}:${e.diagnostic?.code.name ?? "none"}',
                );
              }
            });
            final profile = harness.directories.demo.createPlainChildDirectory(
              'observation_v1/obs-${session.toRadixString(16).padLeft(32, '0')}',
            );
            final ready = harness.browser.events.firstWhere(
              (e) => e.kind == BrowserEventKind.ready,
            );
            final blocked = harness.browser.events.firstWhere(
              (e) =>
                  e.kind == BrowserEventKind.diagnostic &&
                  (e.diagnostic?.code == entry.key ||
                      (entry.key ==
                              BrowserDiagnosticCode.frameNavigationBlocked &&
                          e.diagnostic?.code ==
                              BrowserDiagnosticCode.documentRequestBlocked)),
            );
            await harness.browser.openBackground(
              session: session,
              profilePath: profile,
              target: ObservationTarget.fixture(Uri.parse('$origin/sandbox')),
            );
            try {
              final observed = await Future.wait([ready, blocked]).timeout(
                const Duration(seconds: 10),
                onTimeout: () => throw TestFailure(
                  'Control ${entry.key.name}: $diagnostics; rejected requests $deniedRequests',
                ),
              );
              final initial = observed.first;
              final current = await harness.browser.inspect(
                session: session,
                document: initial.document,
              );
              expect(current.ready, isTrue);
              expect(current.origin, origin);
              expect(
                deniedRequests,
                0,
                reason:
                    'Rejected documents must not reach the loopback destination',
              );
            } finally {
              await harness.browser.close(session);
              expect(await harness.browser.drained(session), isTrue);
              await subscription.cancel();
            }
          }
          // The page-visible Young reply object is not an authority. Wrong
          // payload types, malformed JSON and forged capabilities are ignored.
          script = '''
            __ustcSourcePage.postMessage(new ArrayBuffer(8));
            __ustcSourcePage.postMessage('{');
            __ustcSourcePage.postMessage('{"reply":"forged","call":1,"value":{}}');
            fetch('/fixture-malformed-sent');
          ''';
          harness.directories.demo.createPlainChildDirectory(
            'young_observation_v1',
          );
          final youngProfile = harness.directories.demo.createPlainChildDirectory(
            'young_observation_v1/obs-${(++sequence).toRadixString(16).padLeft(32, '0')}',
          );
          final youngReady = harness.browser.events.firstWhere(
            (event) => event.kind == BrowserEventKind.ready,
          );
          await harness.browser.openBackground(
            session: sequence,
            profilePath: youngProfile,
            target: ObservationTarget.youngFixture(
              Uri.parse('$origin/sandbox'),
            ),
          );
          try {
            final stamp = await youngReady.timeout(const Duration(seconds: 10));
            await malformedSent.future.timeout(const Duration(seconds: 10));
            await Future<void>.delayed(const Duration(milliseconds: 100));
            expect(
              (await harness.browser.inspect(
                session: sequence,
                document: stamp.document,
              )).ready,
              isTrue,
            );
          } finally {
            await harness.browser.close(sequence);
            expect(await harness.browser.drained(sequence), isTrue);
          }
          _reportData['documentAndPopupControls'] = true;
          _reportData['malformedPageMessagesIgnored'] = true;
          _reportData['rejectedDestinationRequests'] = deniedRequests;
        } finally {
          await source.close(force: true);
          await denied.close(force: true);
          await harness.dispose();
        }
      });
    },
    skip: !Platform.isAndroid || _gateOnly,
  );

  testWidgets(
    'Android JW cancel and user close drain an in-flight read before a safe retry',
    (tester) async {
      await tester.runAsync(() async {
        for (final userClose in [false, true]) {
          final harness = await _AndroidA2Harness.create();
          JwSyncFixture? fixture;
          BrowserEvent? lastReady;
          final events = harness.browser.events.listen((event) {
            if (event.kind == BrowserEventKind.ready) lastReady = event;
          });
          try {
            fixture = await JwSyncFixture.start();
            fixture.pauseIndex = true;
            final jw = await harness.openJw(fixture);
            final work = jw.startSync(
              expectedAccountCode: _account,
              password: 'synthetic-password',
              savePassword: true,
            );
            final entered = await Future.any([
              fixture.indexEntered.future.then((_) => true),
              work.then((_) => false),
            ]).timeout(_operationTimeout);
            expect(entered, isTrue, reason: jw.syncView.safeSummary);
            final stamp = lastReady!;
            if (userClose) {
              await harness.browser.exerciseFixture(
                session: stamp.session,
                document: stamp.document,
                action: 'userClose',
              );
            } else {
              await jw.cancel().timeout(_operationTimeout);
            }
            await work.timeout(_operationTimeout);
            expect(
              jw.syncView.phase,
              JwSyncPhase.idle,
              reason: jw.syncView.safeSummary,
            );
            expect(jw.syncView.importCommitted, isFalse);
            expect(jw.syncView.data!.importCount, 0);
            expect(jw.syncView.data!.events, isEmpty);
            expect(jw.syncView.data!.credentialSaved, isFalse);
            expect(harness.leases.isBusy, isFalse);
            // C3 may already have opened/closed a cleanup-only session for the
            // provisional partition. The released shared lease and empty
            // permit set are the coordinator's completed drain receipt.
            expect(await harness.store.readCommittedPermits(), isEmpty);
            fixture.pauseIndex = false;
            fixture.releaseIndex.complete();
            // The cancelled first import has deliberately not bound an
            // account or saved its staged password. Retry with a candidate.
            await jw
                .startSync(
                  expectedAccountCode: _account,
                  password: 'synthetic-password',
                  savePassword: true,
                )
                .timeout(_operationTimeout);
            expect(
              jw.syncView.importCommitted,
              isTrue,
              reason: jw.syncView.safeSummary,
            );
            expect(jw.syncView.data!.importCount, 1);
            expect(jw.syncView.data!.events, hasLength(2));
            _expectSafeSummary(jw.syncView.safeSummary, harness);
          } finally {
            await events.cancel();
            await _cleanup(harness: harness, jwFixture: fixture);
          }
        }
        _reportData['cancelAndUserCloseDrainedBeforeRetry'] = true;
      });
    },
    skip: !Platform.isAndroid || _gateOnly,
  );

  testWidgets(
    'Android JW automatic login saves credentials, deduplicates imports, and clears only its partition',
    (tester) async {
      await tester.runAsync(() async {
        final harness = await _AndroidA2Harness.create();
        JwSyncFixture? fixture;
        try {
          fixture = await JwSyncFixture.start(requireLogin: true);
          fixture.duplicateSchedule = JwDuplicateScheduleMode.differentTeachers;
          final jw = await harness.openJw(fixture);

          await jw
              .startSync(
                expectedAccountCode: _account,
                password: 'synthetic-password',
                savePassword: true,
              )
              .timeout(_operationTimeout);
          final first = jw.syncView;
          expect(first.phase, JwSyncPhase.idle, reason: first.safeSummary);
          expect(first.importCommitted, isTrue, reason: first.safeSummary);
          expect(first.data!.credentialSaved, isTrue);
          expect(first.data!.cachedSemesters.map((item) => item.id).toList(), [
            20261,
            20262,
          ]);
          expect(first.data!.lastSemesterId, 20261);
          expect(first.data!.courseCount, 1);
          expect(first.data!.examCount, 1);
          expect(first.data!.events, hasLength(2));
          expect(fixture.authenticationSubmissions, 1);
          expect(fixture.acceptedIndexSemesters, [20261]);

          final firstCourse = first.data!.events.singleWhere(
            (event) => event.kind == JwEventKind.course,
          );
          final firstExam = first.data!.events.singleWhere(
            (event) => event.kind == JwEventKind.exam,
          );
          expect(firstCourse.semesterId, 20261);
          expect(firstCourse.academicDetails!.teachers, ['合成教师乙', '合成教师甲']);
          expect(
            firstCourse.academicDetails!.locationLabel,
            '合成教室 5304 · 合成教学楼 · 合成东校区',
          );
          expect(
            firstCourse.academicDetails!.locationLabel.split(' · ').toSet(),
            hasLength(3),
          );
          expect(firstExam.title, '合成考试课程');
          expect(firstExam.presence, JwPresence.observed);
          _expectSafeSummary(first.safeSummary, harness);

          await jw.clearSession().timeout(_operationTimeout);
          expect(jw.syncView.sessionRetained, isFalse);
          expect(jw.syncView.data!.credentialSaved, isTrue);
          expect(jw.syncView.data!.events, hasLength(2));
          expect(await harness.store.readCommittedPermits(), isEmpty);
          expect(await harness.jwPartitionEntryNames(), isEmpty);
          _expectSafeSummary(jw.syncView.safeSummary, harness);

          await jw.startSync().timeout(_operationTimeout);
          final repeated = jw.syncView;
          expect(
            repeated.phase,
            JwSyncPhase.idle,
            reason: repeated.safeSummary,
          );
          expect(
            repeated.importCommitted,
            isTrue,
            reason: repeated.safeSummary,
          );
          expect(repeated.data!.importCount, 2);
          expect(repeated.data!.events, hasLength(2));
          expect(
            _jwEventById(repeated.data!, firstCourse.localId).localId,
            firstCourse.localId,
          );
          expect(
            _jwEventById(
              repeated.data!,
              firstCourse.localId,
            ).academicDetails!.teachers,
            ['合成教师乙', '合成教师甲'],
          );
          expect(fixture.acceptedIndexSemesters, [20261, 20261]);
          _expectSafeSummary(repeated.safeSummary, harness);

          // Repeat after a second profile clear, without re-entering a password.
          await jw.clearSession().timeout(_operationTimeout);
          expect(jw.syncView.sessionRetained, isFalse);
          expect(jw.syncView.data!.credentialSaved, isTrue);
          expect(jw.syncView.data!.events, hasLength(2));
          expect(await harness.store.readCommittedPermits(), isEmpty);
          expect(await harness.jwPartitionEntryNames(), isEmpty);
          _expectSafeSummary(jw.syncView.safeSummary, harness);

          await jw.startSync(semesterId: 20262).timeout(_operationTimeout);
          final crossSemester = jw.syncView;
          expect(
            crossSemester.phase,
            JwSyncPhase.idle,
            reason: crossSemester.safeSummary,
          );
          expect(
            crossSemester.importCommitted,
            isTrue,
            reason: crossSemester.safeSummary,
          );
          expect(crossSemester.data!.credentialSaved, isTrue);
          expect(crossSemester.data!.lastSemesterId, 20262);
          expect(crossSemester.data!.courseCount, 2);
          expect(crossSemester.data!.examCount, 1);
          expect(crossSemester.data!.events, hasLength(3));
          expect(
            crossSemester.data!.events
                .where((event) => event.kind == JwEventKind.course)
                .map((event) => event.semesterId),
            unorderedEquals([20261, 20262]),
          );
          expect(
            _jwEventById(crossSemester.data!, firstCourse.localId).presence,
            JwPresence.outsideScope,
          );
          expect(
            _jwEventById(crossSemester.data!, firstExam.localId).presence,
            JwPresence.observed,
          );
          expect(crossSemester.data!.importCount, 3);
          expect(fixture.authenticationSubmissions, 3);
          expect(fixture.acceptedIndexSemesters, [20261, 20261, 20262]);
          _expectSafeSummary(crossSemester.safeSummary, harness);

          await jw.clearSession().timeout(_operationTimeout);
          expect(jw.syncView.sessionRetained, isFalse);
          expect(jw.syncView.data!.credentialSaved, isTrue);
          expect(jw.syncView.data!.events, hasLength(3));
          expect(jw.syncView.data!.importCount, 3);
          expect(await harness.store.readCommittedPermits(), isEmpty);
          expect(await harness.jwPartitionEntryNames(), isEmpty);
          _expectSafeSummary(jw.syncView.safeSummary, harness);

          _reportData.addAll({
            'jwAutomaticLoginAndCredentialSave': true,
            'jwCrossSemesterRetention': true,
            'jwImportedEvents': 3,
            'jwImports': 3,
            'jwPartitionEntriesAfterClear': 0,
          });
        } finally {
          await _cleanup(harness: harness, jwFixture: fixture);
        }
      });
    },
    skip: !Platform.isAndroid || _gateOnly,
  );

  testWidgets(
    'Young realistic redirect uses the shared saved credential and imports only linked calendar rows',
    (tester) async {
      await tester.runAsync(() async {
        final harness = await _AndroidA2Harness.create();
        JwSyncFixture? jwFixture;
        YoungBusinessFixture? youngFixture;
        try {
          // The two immutable fixtures accept different synthetic password
          // strings. This JW flow saves Young's synthetic value through the
          // formal coordinator without a login challenge; the previous test
          // covers JW CAS, while this authenticated Young target proves that
          // the same Android-protected C3 credential is automatically used.
          jwFixture = await JwSyncFixture.start();
          final jw = await harness.openJw(jwFixture);
          await jw
              .startSync(
                expectedAccountCode: _account,
                password: YoungBusinessFixture.syntheticPassword,
                savePassword: true,
              )
              .timeout(_operationTimeout);
          expect(
            jw.syncView.importCommitted,
            isTrue,
            reason: jw.syncView.safeSummary,
          );
          expect(jw.syncView.data!.credentialSaved, isTrue);
          _expectSafeSummary(jw.syncView.safeSummary, harness);
          await harness.closeJw();
          expect(harness.leases.isBusy, isFalse);

          youngFixture = await YoungBusinessFixture.start(
            requireAuthentication: true,
            realisticLoginRedirects: true,
          );
          youngFixture.username = _account;
          final young = await harness.openYoung(youngFixture);
          await young
              .startActivities(expectedAccountCode: _account)
              .timeout(_operationTimeout);
          final activities = young.syncView;
          expect(
            activities.phase,
            YoungSyncPhase.idle,
            reason: activities.safeSummary,
          );
          expect(activities.committed, isTrue, reason: activities.safeSummary);
          expect(activities.accountBound, isTrue);
          expect(activities.data!.credentialSaved, isTrue);
          expect(activities.activityResults, hasLength(11));
          expect(activities.normalization!.activityPages, 2);
          expect(youngFixture.activityRequests, 2);
          expect(youngFixture.authenticationSubmissions, 1);
          expect(youngFixture.successfulAuthenticationSubmissions, 1);
          expect(youngFixture.credentialsMatched, isTrue);
          expect(youngFixture.unexpectedAuthenticationSubmissions, 0);
          expect(youngFixture.bootstrapCompletions, greaterThan(0));
          expect(youngFixture.bootstrapQueryCleared, isTrue);
          expect(youngFixture.prematureBusinessNavigations, 0);
          _expectSafeSummary(activities.safeSummary, harness);

          await young.clearSession().timeout(_operationTimeout);
          expect(young.syncView.profileRetained, isFalse);
          expect(young.syncView.data!.credentialSaved, isTrue);
          _expectSafeSummary(young.syncView.safeSummary, harness);
          await young
              .startCalendar(
                expectedAccountCode: _account,
                firstDay: _day,
                lastDay: _day,
              )
              .timeout(_operationTimeout);
          final calendar = young.syncView;
          expect(
            calendar.phase,
            YoungSyncPhase.idle,
            reason: calendar.safeSummary,
          );
          expect(calendar.committed, isTrue, reason: calendar.safeSummary);
          expect(calendar.accountBound, isTrue);
          expect(calendar.data!.credentialSaved, isTrue);
          expect(calendar.data!.queryCount, 1);
          expect(calendar.data!.importCount, 1);
          expect(calendar.data!.events, hasLength(1));
          final linked = calendar.data!.events.single;
          expect(linked.title, 'Synthetic linked event');
          expect(linked.place, 'Synthetic room');
          expect(youngFixture.calendarRequests, 1);
          expect(youngFixture.authenticationSubmissions, 2);
          expect(youngFixture.successfulAuthenticationSubmissions, 2);
          expect(youngFixture.credentialsMatched, isTrue);
          expect(youngFixture.prematureBusinessNavigations, 0);
          _expectSafeSummary(calendar.safeSummary, harness);

          await young.clearSession().timeout(_operationTimeout);
          await young
              .startCalendar(
                expectedAccountCode: _account,
                firstDay: _day,
                lastDay: _day,
              )
              .timeout(_operationTimeout);
          final repeatedCalendar = young.syncView;
          expect(
            repeatedCalendar.phase,
            YoungSyncPhase.idle,
            reason: repeatedCalendar.safeSummary,
          );
          expect(
            repeatedCalendar.committed,
            isTrue,
            reason: repeatedCalendar.safeSummary,
          );
          expect(repeatedCalendar.data!.events, hasLength(1));
          expect(repeatedCalendar.data!.events.single.localId, linked.localId);
          expect(repeatedCalendar.data!.importCount, 2);
          // Calendar imports have their own receipts; activity-query count is unchanged.
          expect(repeatedCalendar.data!.queryCount, 1);
          expect(youngFixture.calendarRequests, 2);
          expect(youngFixture.activityRequests, 2);
          expect(youngFixture.authenticationSubmissions, 3);
          expect(youngFixture.successfulAuthenticationSubmissions, 3);
          expect(youngFixture.unexpectedAuthenticationSubmissions, 0);
          expect(youngFixture.bootstrapQueryCleared, isTrue);
          expect(youngFixture.prematureBusinessNavigations, 0);
          _expectSafeSummary(repeatedCalendar.safeSummary, harness);

          _reportData.addAll({
            'youngAutomaticCasFromSharedCredential': true,
            'youngBootstrapCompleted': true,
            'youngActivityCount': 11,
            'youngActivityPages': 2,
            'youngLinkedCalendarEvents': 1,
            'youngCalendarImports': 2,
          });
        } finally {
          await _cleanup(
            harness: harness,
            jwFixture: jwFixture,
            youngFixture: youngFixture,
          );
        }
      });
    },
    skip: !Platform.isAndroid || _gateOnly,
  );

  testWidgets(
    'Young identity mismatch and incomplete activity pagination preserve prior calendar data',
    (tester) async {
      await tester.runAsync(() async {
        final harness = await _AndroidA2Harness.create();
        YoungBusinessFixture? fixture;
        try {
          fixture = await YoungBusinessFixture.start(
            requireAuthentication: true,
          );
          fixture.username = _account;
          final young = await harness.openYoung(fixture);
          await young
              .startActivities(
                expectedAccountCode: _account,
                password: YoungBusinessFixture.syntheticPassword,
                savePassword: true,
              )
              .timeout(_operationTimeout);
          expect(young.syncView.committed, isTrue);
          expect(young.syncView.activityResults, hasLength(11));
          expect(young.syncView.normalization!.activityPages, 2);
          _expectSafeSummary(young.syncView.safeSummary, harness);

          await young
              .startCalendar(
                expectedAccountCode: _account,
                firstDay: _day,
                lastDay: _day,
              )
              .timeout(_operationTimeout);
          expect(young.syncView.committed, isTrue);
          expect(young.syncView.data!.events, hasLength(1));
          _expectSafeSummary(young.syncView.safeSummary, harness);
          final seeded = young.syncView.data!.events.single;
          await young.setHidden(
            localId: seeded.localId,
            expectedVersion: seeded.version,
            hidden: true,
          );
          final before = young.syncView.data!;
          expect(before.events.single.hidden, isTrue);
          _expectSafeSummary(young.syncView.safeSummary, harness);
          final previousImportCount = before.importCount;
          final previousQueryCount = before.queryCount;

          fixture.mode = 'accountMismatch';
          await young
              .startActivities(expectedAccountCode: _account)
              .timeout(_operationTimeout);
          final mismatch = young.syncView;
          expect(
            mismatch.phase,
            YoungSyncPhase.idle,
            reason: mismatch.safeSummary,
          );
          expect(mismatch.committed, isFalse, reason: mismatch.safeSummary);
          expect(
            mismatch.identityFailure,
            YoungIdentityFailure.accountMismatch,
          );
          expect(mismatch.activityResults, isEmpty);
          expect(mismatch.data!.queryCount, previousQueryCount);
          expect(mismatch.data!.importCount, previousImportCount);
          expect(mismatch.data!.events, hasLength(1));
          expect(mismatch.data!.events.single.localId, seeded.localId);
          expect(mismatch.data!.events.single.hidden, isTrue);
          _expectSafeSummary(mismatch.safeSummary, harness);

          fixture.mode = 'totalChange';
          await young
              .startActivities(expectedAccountCode: _account)
              .timeout(_operationTimeout);
          final incomplete = young.syncView;
          expect(
            incomplete.phase,
            YoungSyncPhase.idle,
            reason: incomplete.safeSummary,
          );
          expect(incomplete.committed, isFalse, reason: incomplete.safeSummary);
          expect(
            incomplete.failure,
            FailureCode.invalidSnapshot,
            reason: incomplete.safeSummary,
          );
          expect(
            incomplete.collectionStage,
            YoungBusinessStage.activities,
            reason: incomplete.safeSummary,
          );
          expect(incomplete.data!.queryCount, previousQueryCount);
          expect(incomplete.data!.importCount, previousImportCount);
          expect(incomplete.data!.events, hasLength(1));
          expect(incomplete.data!.events.single.localId, seeded.localId);
          expect(incomplete.data!.events.single.hidden, isTrue);
          expect(incomplete.data!.credentialSaved, isTrue);
          _expectSafeSummary(incomplete.safeSummary, harness);

          _reportData.addAll({
            'youngIdentityMismatchRejected': true,
            'youngIncompletePaginationRejected': true,
            'youngExistingEventsRetained': 1,
            'youngPriorImportsPreserved': true,
          });
        } finally {
          await _cleanup(harness: harness, youngFixture: fixture);
        }
      });
    },
    skip: !Platform.isAndroid || _gateOnly,
  );

  testWidgets(
    'Young rejects a same-URL route after the response and can safely retry and clear its partition',
    (tester) async {
      await tester.runAsync(() async {
        final harness = await _AndroidA2Harness.create();
        YoungBusinessFixture? fixture;
        try {
          fixture = await YoungBusinessFixture.start(
            requireAuthentication: true,
          );
          fixture.username = _account;
          final young = await harness.openYoung(fixture);
          await young
              .startActivities(
                expectedAccountCode: _account,
                password: YoungBusinessFixture.syntheticPassword,
                savePassword: true,
              )
              .timeout(_operationTimeout);
          await young
              .startCalendar(
                expectedAccountCode: _account,
                firstDay: _day,
                lastDay: _day,
              )
              .timeout(_operationTimeout);
          expect(young.syncView.committed, isTrue);
          expect(young.syncView.data!.events, hasLength(1));
          _expectSafeSummary(young.syncView.safeSummary, harness);

          final initial = young.syncView.data!.events.single;
          await young.setHidden(
            localId: initial.localId,
            expectedVersion: initial.version,
            hidden: true,
          );
          final beforeRoute = young.syncView.data!;
          final beforeImportCount = beforeRoute.importCount;
          final beforeQueryCount = beforeRoute.queryCount;
          _expectSafeSummary(young.syncView.safeSummary, harness);

          fixture.mode = 'routeAfterBody';
          await young
              .startCalendar(
                expectedAccountCode: _account,
                firstDay: _day,
                lastDay: _day,
              )
              .timeout(_operationTimeout);
          final rejected = young.syncView;
          expect(
            rejected.phase,
            YoungSyncPhase.idle,
            reason: rejected.safeSummary,
          );
          expect(rejected.committed, isFalse, reason: rejected.safeSummary);
          expect(rejected.collectionStage, isNotNull);
          expect(rejected.collectionReason, isNotNull);
          expect(rejected.safeSummary, contains('collectionReason'));
          expect(rejected.data!.queryCount, beforeQueryCount);
          expect(rejected.data!.importCount, beforeImportCount);
          expect(rejected.data!.events, hasLength(1));
          expect(rejected.data!.events.single.localId, initial.localId);
          expect(rejected.data!.events.single.hidden, isTrue);
          _expectSafeSummary(rejected.safeSummary, harness);

          fixture.mode = 'good';
          await young
              .startCalendar(
                expectedAccountCode: _account,
                firstDay: _day,
                lastDay: _day,
              )
              .timeout(_operationTimeout);
          final retried = young.syncView;
          expect(retried.committed, isTrue, reason: retried.safeSummary);
          expect(retried.data!.events, hasLength(1));
          expect(retried.data!.events.single.localId, initial.localId);
          expect(retried.data!.events.single.hidden, isTrue);
          expect(retried.data!.importCount, beforeImportCount + 1);
          expect(retried.data!.queryCount, beforeQueryCount);
          _expectSafeSummary(retried.safeSummary, harness);

          await young.clearSession().timeout(_operationTimeout);
          expect(young.syncView.profileRetained, isFalse);
          expect(young.syncView.data!.credentialSaved, isTrue);
          expect(young.syncView.data!.events, hasLength(1));
          expect(young.syncView.data!.events.single.localId, initial.localId);
          expect(young.syncView.data!.events.single.hidden, isTrue);
          expect(await harness.store.readYoungPermits(), isEmpty);
          expect(await harness.youngPartitionEntryNames(), isEmpty);
          _expectSafeSummary(young.syncView.safeSummary, harness);

          _reportData.addAll({
            'youngSameUrlRouteRejected': true,
            'youngRetryCommitted': true,
            'youngExistingEventsRetained': 1,
            'youngPartitionEntriesAfterClear': 0,
          });
        } finally {
          await _cleanup(harness: harness, youngFixture: fixture);
        }
      });
    },
    skip: !Platform.isAndroid || _gateOnly,
  );
}

final class _AndroidA2Harness {
  _AndroidA2Harness({
    required this.fixtureRoot,
    required this.directories,
    required this.store,
    required this.browser,
    required this.leases,
    required this.clock,
  });

  final _QaFixtureRoot fixtureRoot;
  final AndroidDirectories directories;
  final JwStore store;
  final NativeObservationBrowser browser;
  final WorkLeasePool leases;
  final FixedClock clock;
  JwSyncCoordinator? _jw;
  YoungSyncCoordinator? _young;
  bool _disposed = false;

  static Future<_AndroidA2Harness> create() async {
    final fixtureRoot = await _createFixtureRoot();
    AndroidDirectories? directories;
    JwStore? store;
    NativeObservationBrowser? browser;
    try {
      directories = await AndroidDirectories.acquire(
        fixtureRoot.directory.path,
      );
      final clock = FixedClock(DateTime.utc(2026, 10, 10));
      store = JwStore(
        openJwDatabase(directories.formal),
        ownership: directories.formal,
        clock: clock,
        credentialProtector: const AndroidJwCredentialProtector(),
      );
      await store.initialize().timeout(const Duration(seconds: 45));
      browser = NativeObservationBrowser();
      return _AndroidA2Harness(
        fixtureRoot: fixtureRoot,
        directories: directories,
        store: store,
        browser: browser,
        leases: WorkLeasePool(),
        clock: clock,
      );
    } on Object {
      var cleanupSucceeded = true;
      Future<bool> attempt(Future<void> Function() action) async {
        try {
          await action();
          return true;
        } on Object {
          return false;
        }
      }

      if (browser != null) {
        cleanupSucceeded = await attempt(browser.dispose);
      }
      if (cleanupSucceeded && store != null) {
        cleanupSucceeded = await attempt(store.close);
      }
      if (cleanupSucceeded && directories != null) {
        cleanupSucceeded = await attempt(directories.formal.release);
        if (cleanupSucceeded) {
          cleanupSucceeded = await attempt(directories.demo.release);
        }
      }
      final removed = cleanupSucceeded && await _removeFixtureRoot(fixtureRoot);
      _reportData['cleanupComplete'] = removed;
      _reportData['fixtureRetained'] = !removed;
      rethrow;
    }
  }

  Future<JwSyncCoordinator> openJw(JwSyncFixture fixture) async {
    if (_jw != null || _young != null) {
      throw StateError('Only one source coordinator may be open at a time');
    }
    final coordinator = JwSyncCoordinator(
      store: store,
      registry: JwPartitionRegistry(directories.formal),
      browser: browser,
      leases: leases,
      clock: clock,
      target: ObservationTarget.fixture(fixture.initialUri),
    );
    _jw = coordinator;
    await coordinator.initialize().timeout(const Duration(seconds: 45));
    return coordinator;
  }

  Future<YoungSyncCoordinator> openYoung(YoungBusinessFixture fixture) async {
    if (_jw != null || _young != null) {
      throw StateError('Only one source coordinator may be open at a time');
    }
    final coordinator = YoungSyncCoordinator(
      store: store,
      registry: YoungPartitionRegistry(directories.formal),
      browser: browser,
      leases: leases,
      clock: clock,
      target: ObservationTarget.youngFixture(fixture.initialUri),
    );
    _young = coordinator;
    await coordinator.initialize().timeout(const Duration(seconds: 45));
    return coordinator;
  }

  Future<void> closeJw() async {
    final coordinator = _jw;
    if (coordinator == null) return;
    await coordinator.clearSession().timeout(_operationTimeout);
    await coordinator.shutdown().timeout(_operationTimeout);
    _jw = null;
  }

  Future<List<String>> jwPartitionEntryNames() =>
      _partitionEntryNames(directories.formal, 'jw_partitions_v1');

  Future<List<String>> youngPartitionEntryNames() =>
      _partitionEntryNames(directories.formal, 'young_partitions_v1');

  Future<bool> dispose({bool allowDeleteFixture = true}) async {
    if (_disposed) return true;
    var cleanupSucceeded = true;
    Future<bool> attempt(Future<void> Function() action) async {
      try {
        await action();
        return true;
      } on Object {
        return false;
      }
    }

    final jw = _jw;
    if (jw != null) {
      await attempt(() async {
        if (leases.isBusy) await jw.cancel().timeout(_operationTimeout);
        await jw.clearSession().timeout(_operationTimeout);
        await jw.shutdown().timeout(_operationTimeout);
        _jw = null;
      });
      if (_jw != null) cleanupSucceeded = false;
    }
    final young = _young;
    if (young != null) {
      await attempt(() async {
        if (leases.isBusy) await young.cancel().timeout(_operationTimeout);
        await young.clearSession().timeout(_operationTimeout);
        await young.shutdown().timeout(_operationTimeout);
        _young = null;
      });
      if (_young != null) cleanupSucceeded = false;
    }
    if (leases.isBusy) cleanupSucceeded = false;
    if (cleanupSucceeded) cleanupSucceeded = await attempt(browser.dispose);
    if (cleanupSucceeded) cleanupSucceeded = await attempt(store.close);
    if (cleanupSucceeded) {
      cleanupSucceeded = await attempt(directories.formal.release);
    }
    if (cleanupSucceeded) {
      cleanupSucceeded = await attempt(directories.demo.release);
    }

    final removed =
        allowDeleteFixture &&
        cleanupSucceeded &&
        await _removeFixtureRoot(fixtureRoot);
    final complete = allowDeleteFixture && cleanupSucceeded && removed;
    _disposed = complete;
    _reportData['resourceCleanupComplete'] = cleanupSucceeded;
    _reportData['cleanupComplete'] = complete;
    _reportData['fixtureRetained'] = !complete;
    return complete;
  }
}

final class _QaFixtureRoot {
  const _QaFixtureRoot(this.privateRoot, this.directory);
  final String privateRoot;
  final Directory directory;
}

Future<_QaFixtureRoot> _createFixtureRoot() async {
  final privateRoot = await _platform
      .invokeMethod<String>('privateDataRoot')
      .timeout(const Duration(seconds: 5));
  if (privateRoot == null ||
      !p.posix.isAbsolute(privateRoot) ||
      p.posix.normalize(privateRoot) != privateRoot ||
      !privateRoot.contains('/cn.ustcassistant.mobile.qa/') ||
      !privateRoot.endsWith('/no_backup/ustc_assistant_v1')) {
    throw StateError('Only the isolated Android QA no-backup root is allowed');
  }
  final canonicalRoot = await Directory(privateRoot).resolveSymbolicLinks();
  if (canonicalRoot != privateRoot) {
    throw StateError('Android QA root is not canonical');
  }
  final safeId =
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}_${++_fixtureSequence}';
  final directory = Directory(p.posix.join(privateRoot, 'a2_fixture_$safeId'));
  await directory.create().timeout(_operationTimeout);
  if (await directory.resolveSymbolicLinks().timeout(_operationTimeout) !=
      directory.path) {
    _reportData['cleanupComplete'] = false;
    _reportData['fixtureRetained'] = true;
    throw StateError('Android QA fixture path is not canonical');
  }
  return _QaFixtureRoot(privateRoot, directory);
}

Future<bool> _removeFixtureRoot(_QaFixtureRoot fixtureRoot) async {
  final childPath = fixtureRoot.directory.path;
  final childName = p.posix.basename(childPath);
  if (!RegExp(
        r'^a2_fixture_[A-Za-z0-9][A-Za-z0-9_-]{0,63}$',
      ).hasMatch(childName) ||
      p.posix.dirname(childPath) != fixtureRoot.privateRoot ||
      !p.posix.isWithin(fixtureRoot.privateRoot, childPath) ||
      p.posix.normalize(childPath) != childPath) {
    return false;
  }
  try {
    if (await Directory(
          fixtureRoot.privateRoot,
        ).resolveSymbolicLinks().timeout(_operationTimeout) !=
        fixtureRoot.privateRoot) {
      return false;
    }
    if (!await fixtureRoot.directory.exists().timeout(_operationTimeout)) {
      return true;
    }
    if (await fixtureRoot.directory.resolveSymbolicLinks().timeout(
          _operationTimeout,
        ) !=
        childPath) {
      return false;
    }
    await Directory(
      childPath,
    ).delete(recursive: true).timeout(_operationTimeout);
    return !await Directory(childPath).exists().timeout(_operationTimeout);
  } on Object {
    return false;
  }
}

Future<List<String>> _partitionEntryNames(
  OwnedDirectory owner,
  String child,
) async {
  owner.ensureHeld();
  final path = p.posix.join(owner.path, child);
  final directory = Directory(path);
  if (!await directory.exists()) return const <String>[];
  final entries = await directory.list(followLinks: false).toList();
  final names = entries.map((entry) => p.posix.basename(entry.path)).toList()
    ..sort();
  return names;
}

Future<void> _cleanup({
  required _AndroidA2Harness? harness,
  JwSyncFixture? jwFixture,
  YoungBusinessFixture? youngFixture,
}) async {
  var fixtureServersClosed = true;
  if (jwFixture != null) {
    try {
      await jwFixture.close().timeout(_operationTimeout);
    } on Object {
      fixtureServersClosed = false;
    }
  }
  if (youngFixture != null) {
    try {
      await youngFixture.close().timeout(_operationTimeout);
    } on Object {
      fixtureServersClosed = false;
    }
  }
  _reportData['fixtureServersClosed'] = fixtureServersClosed;
  if (harness == null) {
    _reportData['cleanupComplete'] = fixtureServersClosed;
    _reportData['fixtureRetained'] = false;
    return;
  }
  await harness.dispose(allowDeleteFixture: fixtureServersClosed);
}

JwStoredEvent _jwEventById(JwDataView data, int localId) =>
    data.events.singleWhere((event) => event.localId == localId);

void _expectSafeSummary(String summary, _AndroidA2Harness harness) {
  for (final forbidden in <String>[
    _account,
    'synthetic-password',
    YoungBusinessFixture.syntheticPassword,
    '127.0.0.1',
    '/for-std',
    '/login/',
    harness.fixtureRoot.privateRoot,
    harness.fixtureRoot.directory.path,
  ]) {
    expect(summary, isNot(contains(forbidden)));
  }
}
