// Design basis: navigate from docs/README.md to current 07–15: 07 read-only,
// single-account, continuity, ordinary WebView and Young shared-password
// authorization boundaries; 08 C1/C2/C3/C5 duties and one source/one channel;
// 09 K-01–06 and the user-approved rule that only activity-linked calendar
// rows sync; 10 document/job invalidation, seal, drain, claim and recovery; 11
// safe projections; 12 identity/partition duties; 13 V-01/02/03/05; 14 overall
// review; and 15's current M2.3 busy-navigation admission repair and acceptance
// matrix. Tests use synthetic data and temporary owned directories. Activity
// association is not proof of personal registration success or cancellation.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/jw_academic_details.dart';
import 'package:ustc_assistant_m0/core/jw_credentials.dart';
import 'package:ustc_assistant_m0/core/jw_work_contract.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/core/young_work_contract.dart';
import 'package:ustc_assistant_m0/data/demo_store.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/jobs/coordinator_contract.dart';
import 'package:ustc_assistant_m0/jobs/job_coordinator.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_coordinator.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_port.dart';
import 'package:ustc_assistant_m0/platform/demo_directory.dart';
import 'package:ustc_assistant_m0/platform/jw_partition_registry.dart';
import 'package:ustc_assistant_m0/platform/young_partition_registry.dart';
import 'package:ustc_assistant_m0/source/jw_authentication_contract.dart';
import 'package:ustc_assistant_m0/source/jw_collection_contract.dart';
import 'package:ustc_assistant_m0/source/jw_data_probe_contract.dart';
import 'package:ustc_assistant_m0/source/jw_probe_contract.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';
import 'package:ustc_assistant_m0/source/source_contract.dart';
import 'package:ustc_assistant_m0/source/synthetic_source.dart';
import 'package:ustc_assistant_m0/source/young_active_contract.dart';

const _account = 'SYNTH92814';
const _otherAccount = 'OTHER92814';
const _firstDay = '2026-10-01';
const _secondDay = '2026-10-02';
const _calendarTitle = 'Synthetic linked activity schedule';
const _jwCourseTitle = 'Synthetic preserved JW course';

Future<int> _youngJobCount(JwStore store) async =>
    (await store
            .customSelect('SELECT COUNT(*) AS count FROM young_jobs')
            .getSingle())
        .read<int>('count');

void main() {
  group('Young C2 coordinator', () {
    test(
      'unsupported availability preflight creates no Young work and a later retry succeeds',
      () async {
        final browser = _AutomatedBrowser(
          activityPlans: <List<Object?>>[
            <Object?>[
              _page(<Map<String, Object?>>[_activity('preflight-retry-1')], 1),
            ],
          ],
        )..checkAvailability = true;
        browser.availabilityFailure = const AppFailure(
          FailureCode.unsupportedPlatform,
        );
        final harness = await _Harness.create(
          browser: browser,
          businessStability: const Duration(milliseconds: 2),
        );
        addTearDown(harness.dispose);

        await harness.sync.startActivities(
          expectedAccountCode: _account,
          password: 'synthetic-password',
          savePassword: true,
        );

        expect(harness.sync.syncView.phase, YoungSyncPhase.idle);
        expect(harness.sync.syncView.failure, FailureCode.unsupportedPlatform);
        expect((await harness.store.readYoungView()).credentialSaved, isFalse);
        expect(await _youngJobCount(harness.store), 0);
        expect(await harness.store.readYoungPermits(), isEmpty);
        expect(
          await harness.youngLedger.list(followLinks: false).toList(),
          isEmpty,
        );
        expect(browser.openCalls, 0);
        expect(browser.profilePaths, isEmpty);
        expect(browser.availabilityCalls, 1);
        expect(harness.leases.isBusy, isFalse);

        final otherJob = harness.leases.acquire();
        expect(harness.leases.isBusy, isTrue);
        otherJob.release();

        browser.availabilityFailure = null;
        await harness.sync.startActivities(expectedAccountCode: _account);

        expect(harness.sync.syncView.phase, YoungSyncPhase.idle);
        expect(harness.sync.syncView.failure, isNull);
        expect(harness.sync.syncView.committed, isTrue);
        expect(harness.sync.syncView.activityResults, hasLength(1));
        expect(browser.availabilityCalls, greaterThan(1));
        expect(browser.openCalls, 1);
        expect(await _youngJobCount(harness.store), 1);
      },
      skip: !Platform.isWindows,
    );

    test(
      'stale Young backend is revoked before a new job, drains only Young, and reuses saved credentials',
      () async {
        final browser = _AutomatedBrowser(
          loginStates: <JwLoginState>[
            JwLoginState.businessReady,
            JwLoginState.formReady,
            JwLoginState.businessReady,
          ],
          loginSubmitState: JwLoginState.submitted,
          calendarByDay: <String, List<Map<String, Object?>>>{
            _firstDay: <Map<String, Object?>>[
              _calendarEntry('backend-migration-1', itemId: 'activity-1'),
            ],
          },
        )..expectedSyntheticPassword = 'synthetic-password';
        final harness = await _Harness.create(browser: browser);
        addTearDown(harness.dispose);
        final jw = await harness.seedJw();

        await harness.sync.startCalendar(
          expectedAccountCode: _account,
          firstDay: DateTime.utc(2026, 10, 1),
          lastDay: DateTime.utc(2026, 10, 1),
          password: 'synthetic-password',
          savePassword: true,
        );
        expect(harness.sync.syncView.phase, YoungSyncPhase.idle);
        expect(harness.sync.syncView.committed, isTrue);
        expect(harness.sync.syncView.data!.credentialSaved, isTrue);
        final originalEvent = harness.sync.syncView.data!.events.single;
        await harness.sync.setHidden(
          localId: originalEvent.localId,
          expectedVersion: originalEvent.version,
          hidden: true,
        );
        final oldPermit = (await harness.store.readYoungPermits()).single;
        final oldPath = browser.businessProfilePaths.single;
        final originalJwPermit =
            (await harness.store.readCommittedPermits()).single;

        browser.checkPartitionBackend = true;
        browser.backendCurrent = false;
        browser.resetPartitionBackendCheckWaiter();
        browser.holdPartitionBackendCheck = true;
        browser.onRecoveryOpen = (path) async {
          expect(path, oldPath);
          expect(await harness.store.readYoungPermits(), isEmpty);
          final jwPermits = await harness.store.readCommittedPermits();
          expect(jwPermits, hasLength(1));
          expect(jwPermits.single.partition.sameAs(jw.partition), isTrue);
        };
        final jobsBeforeMigration = await _youngJobCount(harness.store);
        final migration = harness.sync.startCalendar(
          firstDay: DateTime.utc(2026, 10, 1),
          lastDay: DateTime.utc(2026, 10, 1),
        );
        await browser.partitionBackendCheckEntered.future.timeout(
          const Duration(seconds: 2),
        );
        expect(await _youngJobCount(harness.store), jobsBeforeMigration);
        final checksWhileBusy = browser.backendCheckPaths.length;
        expect(
          () => harness.sync.startActivities(),
          throwsA(
            isA<AppFailure>().having(
              (failure) => failure.code,
              'code',
              FailureCode.busy,
            ),
          ),
        );
        expect(browser.backendCheckPaths, hasLength(checksWhileBusy));
        expect(await _youngJobCount(harness.store), jobsBeforeMigration);
        browser.releasePartitionBackendCheck();
        await migration;

        final freshPermit = (await harness.store.readYoungPermits()).single;
        final freshPath = browser.businessProfilePaths.last;
        expect(freshPermit.partition.sameAs(oldPermit.partition), isFalse);
        expect(freshPath, isNot(oldPath));
        expect(browser.recoveryOnlyPaths, contains(oldPath));
        expect(await Directory(oldPath).exists(), isFalse);
        expect(await Directory(freshPath).exists(), isTrue);
        expect(browser.loginSubmissions, hasLength(1));
        expect(browser.verifiedSyntheticPassword, isTrue);
        expect(harness.sync.syncView.committed, isTrue);
        final youngData = await harness.store.readYoungView();
        expect(youngData.importCount, 2);
        expect(youngData.events.single.localId, originalEvent.localId);
        expect(youngData.events.single.hidden, isTrue);
        expect(
          (await harness.store.readCommittedPermits()).single.partition.sameAs(
            originalJwPermit.partition,
          ),
          isTrue,
        );
        final jwData = await harness.store.readView();
        expect(jwData.events.single.title, _jwCourseTitle);
        expect(jwData.credentialSaved, isTrue);
        final currentJob = await harness.store
            .customSelect(
              'SELECT status FROM young_jobs ORDER BY rowid DESC LIMIT 1',
            )
            .getSingle();
        expect(currentJob.read<String>('status'), 'committed');
        expect(
          browser.backendSources.every(
            (source) => source == ObservationSource.young,
          ),
          isTrue,
        );
        expect(browser.backendFixtures.every((fixture) => !fixture), isTrue);

        browser.backendCurrent = true;
        browser.backendFailure = const AppFailure(FailureCode.storageFailed);
        final jobsBeforeBackendError = await _youngJobCount(harness.store);
        await harness.sync.startCalendar(
          firstDay: DateTime.utc(2026, 10, 1),
          lastDay: DateTime.utc(2026, 10, 1),
        );
        expect(harness.sync.syncView.phase, YoungSyncPhase.recovery);
        expect(await _youngJobCount(harness.store), jobsBeforeBackendError);
        expect(
          (await harness.store.readYoungPermits()).single.partition.sameAs(
            freshPermit.partition,
          ),
          isTrue,
        );
        expect(
          (await harness.store.readYoungView()).events.single.hidden,
          isTrue,
        );
        expect(
          (await harness.store.readCommittedPermits()).single.partition.sameAs(
            originalJwPermit.partition,
          ),
          isTrue,
        );
        browser.backendFailure = null;
        await harness.sync.retryRecovery();
        expect(harness.sync.syncView.phase, YoungSyncPhase.idle);
        expect(
          (await harness.store.readYoungPermits()).single.partition.sameAs(
            freshPermit.partition,
          ),
          isTrue,
        );
        expect((await harness.store.readYoungView()).importCount, 2);
      },
      skip: !Platform.isWindows,
    );

    test(
      'shutdown during a pending preflight prevents its late result from creating work',
      () async {
        final browser = _AutomatedBrowser()
          ..checkAvailability = true
          ..holdAvailability = true
          ..availabilityFailure = const AppFailure(
            FailureCode.unsupportedPlatform,
          );
        final harness = await _Harness.create(browser: browser);
        addTearDown(harness.dispose);

        final opening = harness.sync.startActivities(
          expectedAccountCode: _account,
        );
        await browser.availabilityEntered.future.timeout(
          const Duration(seconds: 2),
        );
        var shutdownDone = false;
        final shutdown = harness.sync.shutdown().then((_) {
          shutdownDone = true;
        });
        await Future<void>.delayed(Duration.zero);
        expect(shutdownDone, isFalse);
        expect(harness.sync.syncView.phase, YoungSyncPhase.closing);
        expect(harness.leases.isBusy, isTrue);

        browser.releaseAvailability();
        await Future.wait([opening, shutdown]);

        expect(harness.sync.syncView.phase, YoungSyncPhase.closed);
        expect(harness.sync.syncView.failure, FailureCode.cancelled);
        expect(await _youngJobCount(harness.store), 0);
        expect((await harness.store.readYoungView()).credentialSaved, isFalse);
        expect(await harness.store.readYoungPermits(), isEmpty);
        expect(
          await harness.youngLedger.list(followLinks: false).toList(),
          isEmpty,
        );
        expect(browser.openCalls, 0);
        expect(browser.profilePaths, isEmpty);
        expect(harness.leases.isBusy, isFalse);
      },
      skip: !Platform.isWindows,
    );

    test(
      'automated query waits for the ready helper on the final document before starting reads',
      () async {
        final browser = _AutomatedBrowser(
          activityPlans: <List<Object?>>[
            <Object?>[
              _page(<Map<String, Object?>>[_activity('prepared-query-1')], 1),
            ],
          ],
          holdNavigation: true,
          changeDocumentOnFirstPreparation: true,
        );
        final harness = await _Harness.create(
          browser: browser,
          businessStability: const Duration(milliseconds: 8),
        );
        addTearDown(harness.dispose);

        final work = harness.sync.startActivities(
          expectedAccountCode: _account,
        );
        await browser.navigationEntered.future.timeout(
          const Duration(seconds: 2),
        );

        expect(harness.sync.syncView.phase, YoungSyncPhase.login);
        expect(browser.startCalls, 0);
        expect(browser.dispatched, isEmpty);
        browser.releaseNavigation();
        await work.timeout(const Duration(seconds: 5));

        expect(harness.sync.syncView.phase, YoungSyncPhase.idle);
        expect(harness.sync.syncView.committed, isTrue);
        expect(harness.sync.syncView.activityResults, hasLength(1));
        expect(browser.preparationDocuments, containsAll(<int>[2, 3]));
        expect(browser.startedDocuments, <int>[browser.document]);
        expect(browser.openCalls, 1);
        expect(browser.businessProfilePaths, hasLength(1));
        final profileReads = browser.dispatched
            .where((call) => call.endpoint == YoungBusinessEndpoint.profile)
            .toList();
        expect(profileReads, hasLength(2));
        expect(
          profileReads.every((call) => call.document == browser.document),
          isTrue,
        );
        expect(browser.startCalls, 1);
      },
      skip: !Platform.isWindows,
    );

    test(
      'businessReady waits for the initial ready event before navigating or reading',
      () async {
        final browser = _AutomatedBrowser(
          activityPlans: <List<Object?>>[
            <Object?>[
              _page(<Map<String, Object?>>[_activity('delayed-ready-1')], 1),
            ],
          ],
          holdInitialReady: true,
          holdNavigation: true,
        );
        final harness = await _Harness.create(
          browser: browser,
          businessStability: const Duration(milliseconds: 2),
        );
        addTearDown(harness.dispose);

        final work = harness.sync.startActivities(
          expectedAccountCode: _account,
        );
        await browser.loginAdvanceEntered.future.timeout(
          const Duration(seconds: 2),
        );

        expect(harness.sync.syncView.ready, isFalse);
        expect(browser.loginAdvances, hasLength(1));
        expect(browser.navigationAttempts, 0);
        expect(browser.acceptedNavigationCalls, 0);
        expect(browser.startCalls, 0);
        expect(browser.dispatched, isEmpty);

        browser.releaseInitialReady();
        await browser.navigationEntered.future.timeout(
          const Duration(seconds: 2),
        );
        expect(browser.acceptedNavigationCalls, 1);
        // Initial document admission plus the single accepted business route.
        expect(browser.navigationEventCount, 2);
        expect(browser.startCalls, 0);
        expect(browser.dispatched, isEmpty);

        browser.releaseNavigation();
        await work.timeout(const Duration(seconds: 5));

        expect(harness.sync.syncView.phase, YoungSyncPhase.idle);
        expect(harness.sync.syncView.committed, isTrue);
        expect(browser.navigationAttempts, 1);
        expect(browser.acceptedNavigationCalls, 1);
        expect(browser.startCalls, 1);
      },
      skip: !Platform.isWindows,
    );

    test(
      'explicit native navigation busy retries without closing and issues one navigation',
      () async {
        final browser = _AutomatedBrowser(
          busyNavigationAttempts: 1,
          holdNavigation: true,
          activityPlans: <List<Object?>>[
            <Object?>[
              _page(<Map<String, Object?>>[_activity('busy-retry-1')], 1),
            ],
          ],
        );
        final harness = await _Harness.create(
          browser: browser,
          businessStability: const Duration(milliseconds: 2),
        );
        addTearDown(harness.dispose);

        final work = harness.sync.startActivities(
          expectedAccountCode: _account,
        );
        await browser.navigationEntered.future.timeout(
          const Duration(seconds: 2),
        );
        expect(browser.navigationAttempts, 2);
        expect(browser.acceptedNavigationCalls, 1);
        expect(browser.navigationEventCount, 1);
        expect(browser.closeCalls, 0);
        expect(browser.startCalls, 0);
        expect(browser.dispatched, isEmpty);

        browser.releaseNavigation();
        await work.timeout(const Duration(seconds: 5));
        expect(harness.sync.syncView.committed, isTrue);
        expect(browser.navigationAttempts, 2);
        expect(browser.acceptedNavigationCalls, 1);
        expect(browser.startCalls, 1);
      },
      skip: !Platform.isWindows,
    );

    test(
      'a CAS origin before business navigation returns to the authentication driver without duplicate navigation',
      () async {
        final browser = _AutomatedBrowser(
          visitCasBeforeBusinessPage: true,
          holdNavigation: true,
          activityPlans: <List<Object?>>[
            <Object?>[
              _page(<Map<String, Object?>>[_activity('cas-return-1')], 1),
            ],
          ],
        );
        final harness = await _Harness.create(
          browser: browser,
          businessStability: const Duration(milliseconds: 2),
        );
        addTearDown(harness.dispose);

        final work = harness.sync.startActivities(
          expectedAccountCode: _account,
        );
        await browser.navigationEntered.future.timeout(
          const Duration(seconds: 2),
        );

        expect(browser.originTransitions, <String>[
          'https://passport.ustc.edu.cn',
          'https://young.ustc.edu.cn',
        ]);
        expect(browser.loginAdvances.length, greaterThanOrEqualTo(3));
        expect(browser.navigationAttempts, 1);
        expect(browser.acceptedNavigationCalls, 1);
        expect(browser.startCalls, 0);
        expect(browser.dispatched, isEmpty);
        expect(browser.closeCalls, 0);

        browser.releaseNavigation();
        await work.timeout(const Duration(seconds: 5));
        expect(harness.sync.syncView.committed, isTrue);
        expect(browser.navigationAttempts, 1);
        expect(browser.acceptedNavigationCalls, 1);
        expect(browser.startCalls, 1);
      },
      skip: !Platform.isWindows,
    );

    test(
      'preparation timeout before initial readiness closes without commit and preserves JW facts and password',
      () async {
        final browser = _AutomatedBrowser(holdInitialReady: true);
        final harness = await _Harness.create(
          browser: browser,
          navigationTimeout: const Duration(milliseconds: 40),
          loginWaitTimeout: const Duration(milliseconds: 500),
          businessStability: const Duration(milliseconds: 1),
        );
        addTearDown(harness.dispose);
        final jw = await harness.seedJw();

        await harness.sync
            .startActivities(expectedAccountCode: _account)
            .timeout(const Duration(seconds: 3));

        final view = harness.sync.syncView;
        final young = await harness.store.readYoungView();
        final jwData = await harness.store.readView();
        expect(view.phase, YoungSyncPhase.idle);
        expect(view.failure, FailureCode.sourceFailed);
        expect(view.failureStage, YoungSyncPhase.login);
        expect(
          view.collectionReason,
          YoungBusinessRejection.preparationTimedOut,
        );
        expect(view.committed, isFalse);
        expect(young.queryCount, 0);
        expect(young.importCount, 0);
        expect(young.events, isEmpty);
        expect(browser.navigationAttempts, 0);
        expect(browser.startCalls, 0);
        expect(browser.dispatched, isEmpty);
        expect(browser.closeCalls, greaterThan(0));
        expect(browser.trueDrainCount, greaterThan(0));
        expect(jwData.events, hasLength(1));
        expect(jwData.events.single.title, _jwCourseTitle);
        expect(jwData.credentialSaved, isTrue);
        expect(await harness.store.readCommittedPermits(), hasLength(1));
        expect(
          (await harness.store.readCommittedPermits()).single.partition.sameAs(
            jw.permit.partition,
          ),
          isTrue,
        );
      },
      skip: !Platform.isWindows,
    );

    test(
      'lost navigation confirmation after navigating closes and never resends navigation',
      () async {
        final browser = _AutomatedBrowser(failNavigationAfterEvent: true);
        final harness = await _Harness.create(
          browser: browser,
          businessStability: const Duration(milliseconds: 1),
        );
        addTearDown(harness.dispose);

        await harness.sync
            .startActivities(expectedAccountCode: _account)
            .timeout(const Duration(seconds: 5));

        final view = harness.sync.syncView;
        final young = await harness.store.readYoungView();
        expect(view.phase, YoungSyncPhase.idle);
        expect(view.failure, FailureCode.sourceFailed);
        expect(view.committed, isFalse);
        expect(young.queryCount, 0);
        expect(young.importCount, 0);
        expect(browser.navigationAttempts, 1);
        expect(browser.acceptedNavigationCalls, 1);
        expect(browser.navigationEventCount, 1);
        expect(browser.startCalls, 0);
        expect(browser.dispatched, isEmpty);
        expect(browser.closeCalls, greaterThan(0));
        expect(browser.trueDrainCount, greaterThan(0));
      },
      skip: !Platform.isWindows,
    );

    test(
      'missing helper fails closed before any business read and returns to idle with closed diagnostics',
      () async {
        final browser = _AutomatedBrowser(helperAvailable: false);
        final harness = await _Harness.create(
          browser: browser,
          navigationTimeout: const Duration(milliseconds: 80),
          businessStability: const Duration(milliseconds: 1),
        );
        addTearDown(harness.dispose);

        await harness.sync
            .startActivities(expectedAccountCode: _account)
            .timeout(const Duration(seconds: 3));

        final view = harness.sync.syncView;
        expect(view.phase, YoungSyncPhase.idle);
        expect(view.busy, isFalse);
        expect(view.failure, FailureCode.sourceFailed);
        expect(view.failureStage, YoungSyncPhase.login);
        expect(view.collectionReason, YoungBusinessRejection.helperUnavailable);
        expect(view.committed, isFalse);
        expect(browser.preparationCalls, greaterThan(0));
        expect(browser.startCalls, 0);
        expect(browser.dispatched, isEmpty);
        expect((await harness.store.readYoungView()).queryCount, 0);
      },
      skip: !Platform.isWindows,
    );

    test(
      'cancel during business preparation preserves prior Young facts and creates no receipt',
      () async {
        final browser = _AutomatedBrowser(holdPreparation: true);
        final harness = await _Harness.create(browser: browser);
        addTearDown(harness.dispose);
        await _seedDeferredYoungEvent(harness.store);

        final work = harness.sync.startActivities(
          expectedAccountCode: _account,
        );
        await browser.preparationEntered.future.timeout(
          const Duration(seconds: 2),
        );
        expect(browser.startCalls, 0);
        final cancel = harness.sync.cancel();
        browser.releasePreparation();
        await Future.wait<void>(<Future<void>>[
          work,
          cancel,
        ]).timeout(const Duration(seconds: 5));

        final data = await harness.store.readYoungView();
        expect(harness.sync.syncView.phase, YoungSyncPhase.idle);
        expect(data.events, hasLength(1));
        expect(data.events.single.localId, 77);
        expect(data.events.single.title, 'Synthetic deferred calendar event');
        expect(data.importCount, 0);
        expect(data.queryCount, 0);
        expect(
          await harness.store
              .customSelect('SELECT * FROM young_local_receipts')
              .get(),
          isEmpty,
        );
        expect(browser.startCalls, 0);
        expect(browser.dispatched, isEmpty);
      },
      skip: !Platform.isWindows,
    );

    test(
      'ambiguous stale credential submission pauses for the same job and never resubmits after manual challenge handling',
      () async {
        final browser = _AutomatedBrowser(
          loginStates: const <JwLoginState>[
            JwLoginState.formReady,
            JwLoginState.challengeRequired,
            JwLoginState.businessReady,
          ],
          ambiguousSubmission: true,
          activityPlans: <List<Object?>>[
            <Object?>[
              _page(<Map<String, Object?>>[_activity('resumed-query-1')], 1),
            ],
          ],
        );
        final harness = await _Harness.create(browser: browser);
        addTearDown(harness.dispose);
        await harness.seedJw();

        await harness.sync.startActivities(expectedAccountCode: _account);
        expect(harness.sync.syncView.phase, YoungSyncPhase.login);
        expect(
          harness.sync.syncView.loginPauseReason,
          JwLoginPauseReason.challengeRequired,
        );
        expect(browser.loginSubmissions, hasLength(1));
        expect(browser.startCalls, 0);
        expect(browser.openCalls, 1);
        expect(browser.businessProfilePaths, hasLength(1));
        expect(browser.lastSubmittedLease, isNotNull);
        expect(
          () => browser.lastSubmittedLease!.take(),
          throwsA(isA<JwCredentialException>()),
        );

        final loginSession = browser.loginAdvances.first.session;
        final loginDocument = browser.loginAdvances.first.document;
        expect(
          browser.loginAdvances.every(
            (call) =>
                call.session == loginSession && call.document == loginDocument,
          ),
          isTrue,
        );
        expect(browser.loginSubmissions.single.session, loginSession);
        expect(browser.loginSubmissions.single.document, loginDocument);
        expect(
          browser.loginSubmissions.single.operation,
          browser.loginAdvances.first.operation,
        );

        await harness.sync.continueAfterLogin();

        expect(harness.sync.syncView.phase, YoungSyncPhase.idle);
        expect(harness.sync.syncView.committed, isTrue);
        expect(harness.sync.syncView.activityResults, hasLength(1));
        expect((await harness.store.readYoungView()).queryCount, 1);
        expect(browser.loginSubmissions, hasLength(1));
        expect(browser.startCalls, 1);
        expect(browser.openCalls, 1);
        final profileReads = browser.dispatched
            .where((call) => call.endpoint == YoungBusinessEndpoint.profile)
            .toList();
        expect(profileReads, hasLength(2));
      },
      skip: !Platform.isWindows,
    );

    test(
      'cancelling a pending native login revokes its one-use credential lease immediately',
      () async {
        final browser = _AutomatedBrowser(
          loginStates: const <JwLoginState>[JwLoginState.formReady],
          holdSubmission: true,
        );
        final harness = await _Harness.create(browser: browser);
        addTearDown(harness.dispose);
        await harness.seedJw();

        final work = harness.sync.startActivities(
          expectedAccountCode: _account,
        );
        await browser.submissionEntered.future.timeout(
          const Duration(seconds: 2),
        );
        final cancel = harness.sync.cancel();
        expect(browser.lastSubmittedLease, isNotNull);
        expect(
          () => browser.lastSubmittedLease!.take(),
          throwsA(isA<JwCredentialException>()),
        );
        browser.releaseSubmission();
        await Future.wait<void>(<Future<void>>[
          work,
          cancel,
        ]).timeout(const Duration(seconds: 5));

        expect(harness.sync.syncView.phase, YoungSyncPhase.idle);
        expect((await harness.store.readYoungView()).queryCount, 0);
        expect(browser.startCalls, 0);
        expect(browser.loginSubmissions, hasLength(1));
      },
      skip: !Platform.isWindows,
    );

    test(
      'keeps query separate, drains before commit, claims before delivery, and reuses one Young partition',
      () async {
        final browser = _SyntheticBrowser(
          activityPlans: <List<Object?>>[
            <Object?>[
              _page(
                List<Map<String, Object?>>.generate(
                  10,
                  (index) => _activity('activity-${index + 1}'),
                ),
                11,
              ),
              _page(<Map<String, Object?>>[_activity('activity-11')], 11),
            ],
            <Object?>[_page(const <Map<String, Object?>>[], 0)],
            <Object?>[
              _page(<Map<String, Object?>>[_activity('activity-later')], 1),
            ],
          ],
          calendarPagesByDay: <String, List<Map<String, Object?>>>{
            _firstDay: <Map<String, Object?>>[
              _page(
                List<Map<String, Object?>>.generate(
                  10,
                  (index) => _calendarEntry(
                    'linked-${index + 1}',
                    itemId: 'activity-${index + 1}',
                  ),
                ),
                11,
              ),
              _page(<Map<String, Object?>>[
                _calendarEntry('unlinked-1', itemId: null),
              ], 11),
            ],
            _secondDay: <Map<String, Object?>>[
              _page(const <Map<String, Object?>>[], 0),
            ],
          },
        );
        final drainCountsAtCommit = <int>[];
        final harness = await _Harness.create(
          browser: browser,
          onYoungCheckpoint: (checkpoint, _, _) async {
            if (checkpoint == YoungStoreCheckpoint.beforeCommit) {
              drainCountsAtCommit.add(browser.trueDrainCount);
            }
          },
        );
        addTearDown(harness.dispose);

        final deliveredClaimChecks = <Future<bool>>[];
        final subscription = harness.sync.syncChanges.listen((view) {
          final deliveredQuery = view.activityResults.isNotEmpty;
          final deliveredCalendar =
              view.phase == YoungSyncPhase.idle &&
              view.data?.events.any((event) => event.title == _calendarTitle) ==
                  true;
          if (deliveredQuery || deliveredCalendar) {
            deliveredClaimChecks.add(
              _ledgerIsClaimed(
                harness.owner,
                browser.businessProfilePaths.last,
              ),
            );
          }
        });

        await harness.sync.startActivities(expectedAccountCode: _account);
        expect(harness.sync.syncView.phase, YoungSyncPhase.login);
        expect(harness.leases.isBusy, isTrue);
        expect(() => harness.leases.acquire(), throwsA(isA<AppFailure>()));
        await harness.sync.continueAfterLogin();

        final queryView = harness.sync.syncView;
        expect(queryView.phase, YoungSyncPhase.idle);
        expect(queryView.committed, isTrue);
        expect(queryView.accountBound, isTrue);
        expect(queryView.activityResults, hasLength(11));
        expect(queryView.data!.queryCount, 1);
        expect(queryView.data!.importCount, 0);
        expect(queryView.data!.events, isEmpty);
        expect(harness.leases.isBusy, isFalse);
        final firstPermit = (await harness.store.readYoungPermits()).single;
        final firstAttempt = firstPermit.partition.attempt;

        await harness.sync.startCalendar(
          firstDay: DateTime.utc(2026, 10, 1),
          lastDay: DateTime.utc(2026, 10, 2),
        );
        expect(harness.sync.syncView.phase, YoungSyncPhase.login);
        expect(harness.sync.syncView.profileReused, isTrue);
        await harness.sync.continueAfterLogin();

        final calendarView = harness.sync.syncView;
        expect(calendarView.data!.events, hasLength(10));
        expect(
          calendarView.data!.events.any(
            (event) => event.title == _calendarTitle,
          ),
          isTrue,
        );
        expect(calendarView.data!.importCount, 1);
        expect(calendarView.data!.queryCount, 1);
        expect(calendarView.normalization!.calendarRows, 11);
        expect(calendarView.normalization!.events, 10);
        expect(calendarView.normalization!.excludedSchedules, 1);
        expect(calendarView.normalization!.days, 2);
        expect(calendarView.normalization!.calendarPages, 3);

        await harness.sync.startActivities();
        expect(harness.sync.syncView.phase, YoungSyncPhase.login);
        expect(harness.sync.syncView.profileReused, isTrue);
        await harness.sync.continueAfterLogin();
        expect(harness.sync.syncView.activityResults, hasLength(1));
        expect(harness.sync.syncView.data!.queryCount, 2);
        expect(harness.sync.syncView.data!.importCount, 1);
        expect(harness.sync.syncView.data!.events, hasLength(10));
        expect(harness.sync.syncView.safeSummary, contains('young-import-v1'));
        expect(harness.sync.syncView.safeSummary, isNot(contains(_account)));
        expect(
          harness.sync.syncView.safeSummary,
          isNot(contains(_calendarTitle)),
        );
        expect(
          harness.sync.syncView.safeSummary,
          isNot(contains('activity-later')),
        );
        expect(
          browser.dispatched
              .where((call) => call.endpoint == YoungBusinessEndpoint.schedule)
              .map((call) => call.day)
              .toSet(),
          <String?>{_firstDay, _secondDay},
        );
        expect(browser.businessProfilePaths, hasLength(3));
        expect(browser.businessProfilePaths.toSet(), hasLength(1));
        final finalPermit = (await harness.store.readYoungPermits()).single;
        expect(finalPermit.partition.sameAs(firstPermit.partition), isTrue);
        expect(finalPermit.partition.attempt, firstAttempt);
        expect(drainCountsAtCommit, hasLength(3));
        expect(drainCountsAtCommit.every((count) => count > 0), isTrue);
        expect(await Future.wait(deliveredClaimChecks), everyElement(isTrue));
        await subscription.cancel();
      },
      skip: !Platform.isWindows,
    );

    test(
      'manual cancellation waits for a late read and a true drain before releasing the global lease',
      () async {
        final browser = _SyntheticBrowser(holdFirstPoll: true, holdDrain: true);
        final harness = await _Harness.create(browser: browser);
        addTearDown(harness.dispose);

        await harness.sync.startActivities(expectedAccountCode: _account);
        final read = harness.sync.continueAfterLogin();
        await browser.pollEntered.future.timeout(const Duration(seconds: 2));
        final cancel = harness.sync.cancel();
        await browser.drainEntered.future.timeout(const Duration(seconds: 2));

        expect(harness.leases.isBusy, isTrue);
        expect(() => harness.leases.acquire(), throwsA(isA<AppFailure>()));
        browser.releaseDrain();
        await Future.wait(<Future<void>>[
          read,
          cancel,
        ]).timeout(const Duration(seconds: 5));

        expect(harness.sync.syncView.phase, YoungSyncPhase.idle);
        expect(harness.sync.syncView.activityResults, isEmpty);
        expect(harness.sync.syncView.data!.queryCount, 0);
        expect(await harness.store.readYoungPermits(), isEmpty);
        expect(harness.leases.isBusy, isFalse);
        expect(browser.trueDrainCount, greaterThan(0));
      },
      skip: !Platform.isWindows,
    );

    test(
      'closing during a read rejects the late old-document reply and commits nothing',
      () async {
        final browser = _SyntheticBrowser(holdFirstPoll: true);
        final harness = await _Harness.create(browser: browser);
        addTearDown(harness.dispose);

        await harness.sync.startActivities(expectedAccountCode: _account);
        final read = harness.sync.continueAfterLogin();
        await browser.pollEntered.future.timeout(const Duration(seconds: 2));
        final shutdown = harness.sync.shutdown();
        await Future.wait(<Future<void>>[
          read,
          shutdown,
        ]).timeout(const Duration(seconds: 5));

        expect(harness.sync.syncView.phase, YoungSyncPhase.closed);
        expect(harness.sync.syncView.activityResults, isEmpty);
        expect((await harness.store.readYoungView()).queryCount, 0);
        expect(await harness.store.readYoungPermits(), isEmpty);
        expect(harness.leases.isBusy, isFalse);
      },
      skip: !Platform.isWindows,
    );

    test(
      'cancel racing a committed query preserves its receipt and permit but suppresses delivery',
      () async {
        final checkpointEntered = Completer<void>();
        final releaseCommit = Completer<void>();
        final browser = _SyntheticBrowser(
          activityPlans: <List<Object?>>[
            <Object?>[
              _page(<Map<String, Object?>>[_activity('race-1')], 1),
            ],
          ],
        );
        final harness = await _Harness.create(
          browser: browser,
          onYoungCheckpoint: (checkpoint, _, _) async {
            if (checkpoint == YoungStoreCheckpoint.beforeCommit &&
                !checkpointEntered.isCompleted) {
              checkpointEntered.complete();
              await releaseCommit.future;
            }
          },
        );
        addTearDown(harness.dispose);

        await harness.sync.startActivities(expectedAccountCode: _account);
        final work = harness.sync.continueAfterLogin();
        await checkpointEntered.future.timeout(const Duration(seconds: 3));
        final cancel = harness.sync.cancel();
        releaseCommit.complete();
        await Future.wait(<Future<void>>[
          work,
          cancel,
        ]).timeout(const Duration(seconds: 5));

        final view = await harness.store.readYoungView();
        expect(harness.sync.syncView.committed, isTrue);
        expect(harness.sync.syncView.activityResults, isEmpty);
        expect(view.queryCount, 1);
        expect(await harness.store.readYoungPermits(), hasLength(1));
        expect(harness.leases.isBusy, isFalse);
      },
      skip: !Platform.isWindows,
    );

    test(
      'unknown source failure keeps the existing Young claim and old local facts',
      () async {
        final browser = _SyntheticBrowser(
          calendarByDay: <String, List<Map<String, Object?>>>{
            _firstDay: <Map<String, Object?>>[
              _calendarEntry('stable-1', itemId: 'activity-1'),
            ],
          },
        );
        final harness = await _Harness.create(browser: browser);
        addTearDown(harness.dispose);

        await _runCalendar(harness, DateTime.utc(2026, 10, 1));
        final priorPermit = (await harness.store.readYoungPermits()).single;
        final priorPath = browser.businessProfilePaths.single;
        browser.failEndpoint = YoungBusinessEndpoint.profile;

        await harness.sync.startActivities();
        await harness.sync.continueAfterLogin();

        expect(harness.sync.syncView.failure, FailureCode.sourceFailed);
        expect(harness.sync.syncView.activityResults, isEmpty);
        expect(harness.sync.syncView.data!.events, hasLength(1));
        expect(harness.sync.syncView.data!.queryCount, 0);
        final retained = (await harness.store.readYoungPermits()).single;
        expect(retained.partition.sameAs(priorPermit.partition), isTrue);
        expect(browser.businessProfilePaths.last, priorPath);
        expect(await Directory(priorPath).exists(), isTrue);
      },
      skip: !Platform.isWindows,
    );

    test(
      'a route change rejects a complete reply from the old document without replacing the prior claim',
      () async {
        final browser = _SyntheticBrowser(
          calendarByDay: <String, List<Map<String, Object?>>>{
            _firstDay: <Map<String, Object?>>[
              _calendarEntry('route-stable-1', itemId: 'activity-1'),
            ],
          },
        );
        final harness = await _Harness.create(browser: browser);
        addTearDown(harness.dispose);

        await _runCalendar(harness, DateTime.utc(2026, 10, 1));
        final priorPermit = (await harness.store.readYoungPermits()).single;
        final priorPath = browser.businessProfilePaths.single;
        browser.routeOnPollEndpoint = YoungBusinessEndpoint.profile;

        await harness.sync.startActivities();
        await harness.sync.continueAfterLogin();

        expect(harness.sync.syncView.failure, isNotNull);
        expect(harness.sync.syncView.activityResults, isEmpty);
        expect(harness.sync.syncView.data!.queryCount, 0);
        expect(harness.sync.syncView.data!.events, hasLength(1));
        final retained = (await harness.store.readYoungPermits()).single;
        expect(retained.partition.sameAs(priorPermit.partition), isTrue);
        expect(browser.businessProfilePaths.last, priorPath);
        expect(await Directory(priorPath).exists(), isTrue);
      },
      skip: !Platform.isWindows,
    );

    test(
      'identity evidence drift rejects the job and retains the previously claimed Young profile',
      () async {
        final browser = _SyntheticBrowser(
          calendarByDay: <String, List<Map<String, Object?>>>{
            _firstDay: <Map<String, Object?>>[
              _calendarEntry('drift-stable-1', itemId: 'activity-1'),
            ],
          },
        );
        final harness = await _Harness.create(browser: browser);
        addTearDown(harness.dispose);

        await _runCalendar(harness, DateTime.utc(2026, 10, 1));
        final priorPermit = (await harness.store.readYoungPermits()).single;
        final priorPath = browser.businessProfilePaths.single;
        browser.afterUsername = _otherAccount;

        await harness.sync.startActivities();
        await harness.sync.continueAfterLogin();

        expect(
          harness.sync.syncView.identityFailure,
          YoungIdentityFailure.evidenceConflict,
        );
        expect(harness.sync.syncView.activityResults, isEmpty);
        expect(harness.sync.syncView.data!.queryCount, 0);
        expect(harness.sync.syncView.data!.events, hasLength(1));
        final retained = (await harness.store.readYoungPermits()).single;
        expect(retained.partition.sameAs(priorPermit.partition), isTrue);
        expect(browser.businessProfilePaths.last, priorPath);
        expect(await Directory(priorPath).exists(), isTrue);
      },
      skip: !Platform.isWindows,
    );

    test(
      'confirmed account mismatch revokes only Young while preserving JW facts, credential, and permit',
      () async {
        final browser = _SyntheticBrowser(
          calendarByDay: <String, List<Map<String, Object?>>>{
            _firstDay: <Map<String, Object?>>[
              _calendarEntry('young-stable-1', itemId: 'activity-1'),
            ],
          },
        );
        final harness = await _Harness.create(browser: browser);
        addTearDown(harness.dispose);

        await _runCalendar(harness, DateTime.utc(2026, 10, 1));
        final youngPath = browser.businessProfilePaths.single;
        final jw = await harness.seedJw();
        browser.beforeUsername = _otherAccount;
        browser.afterUsername = _otherAccount;

        await harness.sync.startActivities();
        await harness.sync.continueAfterLogin();

        expect(
          harness.sync.syncView.identityFailure,
          YoungIdentityFailure.accountMismatch,
        );
        expect(await harness.store.readYoungPermits(), isEmpty);
        expect(await Directory(youngPath).exists(), isFalse);
        final youngData = await harness.store.readYoungView();
        expect(youngData.events, hasLength(1));
        expect(youngData.importCount, 1);

        final jwPermits = await harness.store.readCommittedPermits();
        expect(jwPermits, hasLength(1));
        expect(jwPermits.single.partition.sameAs(jw.permit.partition), isTrue);
        final jwAuthority = await harness.store.readAuthority();
        await harness.jwRegistry.openClaimed(
          jw.permit,
          ownerId: jwAuthority.ownerId,
          resetEpoch: jwAuthority.resetEpoch,
        );
        final jwData = await harness.store.readView();
        expect(jwData.events.single.title, _jwCourseTitle);
        expect(jwData.credentialSaved, isTrue);
      },
      skip: !Platform.isWindows,
    );

    test(
      'postcommit claim failure recovers without re-reading or delivering the stale query list',
      () async {
        final browser = _SyntheticBrowser(
          activityPlans: <List<Object?>>[
            <Object?>[
              _page(<Map<String, Object?>>[_activity('recovery-1')], 1),
            ],
          ],
        );
        final harness = await _Harness.create(
          browser: browser,
          onYoungCheckpoint: (checkpoint, owner, activeBrowser) async {
            if (checkpoint == YoungStoreCheckpoint.beforeCommit) {
              final profile = activeBrowser.businessProfilePaths.last;
              final partitionId = p.windows.basename(profile);
              final obstruction = File(
                p.windows.join(
                  owner.path,
                  'young_partitions_v1',
                  '$partitionId.updating',
                ),
              );
              await obstruction.writeAsString('{ synthetic malformed ledger');
              activeBrowser.injectedLedgerFault = obstruction;
            }
          },
        );
        addTearDown(harness.dispose);

        await harness.sync.startActivities(expectedAccountCode: _account);
        await harness.sync.continueAfterLogin();
        expect(harness.sync.syncView.phase, YoungSyncPhase.recovery);
        expect(harness.sync.syncView.committed, isTrue);
        expect(harness.sync.syncView.activityResults, isEmpty);
        expect((await harness.store.readYoungView()).queryCount, 1);
        expect(await harness.store.readYoungPermits(), hasLength(1));
        final dispatchesAtFailure = browser.dispatchCalls;
        final startsAtFailure = browser.startCalls;

        await browser.injectedLedgerFault!.delete();
        await harness.sync.retryRecovery();

        expect(harness.sync.syncView.phase, YoungSyncPhase.idle);
        expect(harness.sync.syncView.committed, isTrue);
        expect(harness.sync.syncView.activityResults, isEmpty);
        expect((await harness.store.readYoungView()).queryCount, 1);
        expect(await harness.store.readYoungPermits(), hasLength(1));
        expect(browser.dispatchCalls, dispatchesAtFailure);
        expect(browser.startCalls, startsAtFailure);
      },
      skip: !Platform.isWindows,
    );

    test(
      'clearing Young login data retains Young calendar facts and JW local data, saved credential, and claim',
      () async {
        final browser = _SyntheticBrowser(
          calendarByDay: <String, List<Map<String, Object?>>>{
            _firstDay: <Map<String, Object?>>[
              _calendarEntry('young-preserve-1', itemId: 'activity-1'),
            ],
          },
        );
        final harness = await _Harness.create(browser: browser);
        addTearDown(harness.dispose);

        await _runCalendar(harness, DateTime.utc(2026, 10, 1));
        final youngPath = browser.businessProfilePaths.single;
        final jw = await harness.seedJw();
        await harness.sync.clearSession();

        expect(await harness.store.readYoungPermits(), isEmpty);
        expect(await Directory(youngPath).exists(), isFalse);
        final youngData = await harness.store.readYoungView();
        expect(youngData.events.single.title, _calendarTitle);
        expect(youngData.importCount, 1);
        final jwData = await harness.store.readView();
        expect(jwData.events.single.title, _jwCourseTitle);
        expect(jwData.credentialSaved, isTrue);
        expect(await harness.store.readCommittedPermits(), hasLength(1));
        final jwAuthority = await harness.store.readAuthority();
        await harness.jwRegistry.openClaimed(
          jw.permit,
          ownerId: jwAuthority.ownerId,
          resetEpoch: jwAuthority.resetEpoch,
        );
      },
      skip: !Platform.isWindows,
    );

    test(
      'deferred initialization can be shut down after the shared lease becomes free without opening a source',
      () async {
        final browser = _SyntheticBrowser();
        final harness = await _Harness.create(
          browser: browser,
          initialize: false,
        );
        addTearDown(harness.dispose);

        final otherSourceLease = harness.leases.acquire();
        await harness.sync.initialize();
        expect(harness.sync.syncView.phase, YoungSyncPhase.idle);
        expect(browser.openCalls, 0);
        otherSourceLease.release();

        await harness.sync.shutdown();

        expect(harness.sync.syncView.phase, YoungSyncPhase.closed);
        expect(harness.leases.isBusy, isFalse);
        expect(browser.openCalls, 0);
        expect(browser.startCalls, 0);
      },
      skip: !Platform.isWindows,
    );

    test(
      'shutdown after a deferred local hide waits for the write and reconciles before closing',
      () async {
        final browser = _SyntheticBrowser();
        final harness = await _Harness.create(
          browser: browser,
          initialize: false,
        );
        addTearDown(harness.dispose);
        await _seedDeferredYoungEvent(harness.store);
        final event = (await harness.store.readYoungView()).events.single;

        final hiddenWrite = harness.sync.setHidden(
          localId: event.localId,
          expectedVersion: event.version,
          hidden: true,
        );
        expect(harness.leases.isBusy, isTrue);
        final shutdown = harness.sync.shutdown();

        await Future.wait<void>(<Future<void>>[
          hiddenWrite,
          shutdown,
        ]).timeout(const Duration(seconds: 5));

        expect(harness.sync.syncView.phase, YoungSyncPhase.closed);
        expect(harness.sync.syncView.data!.events.single.hidden, isTrue);
        expect(harness.sync.syncView.data!.events.single.version, 2);
        expect(
          await harness.store
              .customSelect('SELECT * FROM young_local_receipts')
              .get(),
          hasLength(1),
        );
        expect(harness.leases.isBusy, isFalse);
        expect(browser.openCalls, 0);
        expect(browser.startCalls, 0);
      },
      skip: !Platform.isWindows,
    );

    test(
      'shutdown refuses another source lease, then retries cleanly after the M0 job closes',
      () async {
        final browser = _SyntheticBrowser();
        final harness = await _Harness.create(
          browser: browser,
          initialize: false,
        );
        addTearDown(harness.dispose);

        final demoStore = DemoStore(
          NativeDatabase.memory(),
          ownership: const _SyntheticOwnership(),
          clock: FixedClock(DateTime.utc(2026, 10, 11, 12)),
        );
        await demoStore.initialize();
        final m0 = JobCoordinator(
          store: demoStore,
          source: SyntheticSource(
            clock: FixedClock(DateTime.utc(2026, 10, 11, 12)),
            delay: const Duration(seconds: 1),
          ),
          leases: harness.leases,
        );
        try {
          final m0Work = m0.run(DemoScenario.normal);
          expect(harness.leases.isBusy, isTrue);
          await expectLater(
            harness.sync.shutdown(),
            throwsA(
              isA<AppFailure>().having(
                (failure) => failure.code,
                'code',
                FailureCode.cleanupPending,
              ),
            ),
          );
          expect(harness.sync.syncView.phase, YoungSyncPhase.idle);
          expect(browser.openCalls, 0);

          await m0.close();
          await m0Work.timeout(const Duration(seconds: 5));
          expect(m0.view.phase, JobPhase.closed);
          expect(harness.leases.isBusy, isFalse);

          await harness.sync.shutdown();
          expect(harness.sync.syncView.phase, YoungSyncPhase.closed);
          expect(browser.openCalls, 0);
          expect(browser.startCalls, 0);
        } finally {
          if (m0.view.phase != JobPhase.closed) await m0.close();
          await demoStore.close();
        }
      },
      skip: !Platform.isWindows,
    );
  });
}

Future<void> _runCalendar(_Harness harness, DateTime day) async {
  await harness.sync.startCalendar(
    expectedAccountCode: _account,
    firstDay: day,
    lastDay: day,
  );
  expect(harness.sync.syncView.phase, YoungSyncPhase.login);
  await harness.sync.continueAfterLogin();
  expect(harness.sync.syncView.phase, YoungSyncPhase.idle);
}

Future<void> _seedDeferredYoungEvent(JwStore store) async {
  await store.customStatement(
    'INSERT INTO jw_account (account_id, expected_account_code) VALUES (1, ?)',
    [_account],
  );
  await store.customStatement(
    'INSERT INTO young_events '
    '(local_id,external_id,item_id,title,place,starts_at,ends_at,presence,version) '
    "VALUES (77,'synthetic-young-event','synthetic-activity',?,?,?,?,'observed',1)",
    [
      'Synthetic deferred calendar event',
      'Synthetic room',
      DateTime.utc(2026, 10, 1, 2).microsecondsSinceEpoch,
      DateTime.utc(2026, 10, 1, 3).microsecondsSinceEpoch,
    ],
  );
  await store.customStatement(
    'INSERT INTO young_overlays (local_id,hidden) VALUES (77,0)',
  );
}

Future<bool> _ledgerIsClaimed(DemoDirectory owner, String profilePath) async {
  final id = p.windows.basename(profilePath);
  final file = File(
    p.windows.join(owner.path, 'young_partitions_v1', '$id.json'),
  );
  final record = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  return record['state'] == 'claimed';
}

Map<String, Object?> _page(List<Map<String, Object?>> records, int total) =>
    <String, Object?>{
      'success': true,
      'code': 200,
      'result': <String, Object?>{'records': records, 'total': total},
    };

Map<String, Object?> _activity(String id) => <String, Object?>{
  'id': id,
  'itemName': 'Synthetic activity $id',
  'st': '2026-10-01 10:00:00',
  'et': '2026-10-01 11:00:00',
  'applySt': '2026-09-20 08:00:00',
  'applyEt': '2026-09-30 20:00:00',
  'placeInfo': 'Synthetic activity place',
};

Map<String, Object?> _calendarEntry(String id, {required String? itemId}) =>
    <String, Object?>{
      'id': id,
      'title': id == 'linked-1' || id == 'young-preserve-1'
          ? _calendarTitle
          : 'Synthetic schedule $id',
      'place': 'Synthetic room',
      'startTime': '$_firstDay 10:00:00',
      'endTime': '$_firstDay 11:00:00',
      'itemId': itemId,
    };

final class _Harness {
  _Harness({
    required this.root,
    required this.owner,
    required this.store,
    required this.youngRegistry,
    required this.jwRegistry,
    required this.browser,
    required this.leases,
    required this.sync,
  });

  final Directory root;
  final DemoDirectory owner;
  final JwStore store;
  final YoungPartitionRegistry youngRegistry;
  final JwPartitionRegistry jwRegistry;
  final _SyntheticBrowser browser;
  final WorkLeasePool leases;
  final YoungSyncCoordinator sync;
  Directory get youngLedger =>
      Directory(p.windows.join(owner.path, 'young_partitions_v1'));
  bool _jwRegistryReady = false;
  bool _disposed = false;

  static Future<_Harness> create({
    required _SyntheticBrowser browser,
    bool initialize = true,
    Duration navigationTimeout = const Duration(seconds: 2),
    Duration loginWaitTimeout = const Duration(seconds: 90),
    Duration businessStability = const Duration(milliseconds: 500),
    Future<void> Function(
      YoungStoreCheckpoint checkpoint,
      DemoDirectory owner,
      _SyntheticBrowser browser,
    )?
    onYoungCheckpoint,
  }) async {
    final root = await Directory.systemTemp.createTemp('ustc_young_sync_');
    final owner = await DemoDirectory.acquire(
      p.windows.join(root.path, 'owner'),
    );
    final store = JwStore(
      NativeDatabase.memory(),
      ownership: owner,
      clock: FixedClock(DateTime.utc(2026, 10, 11, 12)),
      credentialProtector: const _SyntheticProtector(),
      onYoungCheckpoint: (checkpoint) =>
          onYoungCheckpoint?.call(checkpoint, owner, browser) ??
          Future<void>.value(),
    );
    await store.initialize();
    final youngRegistry = YoungPartitionRegistry(owner);
    final jwRegistry = JwPartitionRegistry(owner);
    final leases = WorkLeasePool();
    final sync = YoungSyncCoordinator(
      store: store,
      registry: youngRegistry,
      browser: browser,
      leases: leases,
      clock: FixedClock(DateTime.utc(2026, 10, 11, 12)),
      navigationTimeout: navigationTimeout,
      pollInterval: const Duration(milliseconds: 1),
      drainTimeout: const Duration(seconds: 5),
      loginWaitTimeout: loginWaitTimeout,
      businessStability: businessStability,
    );
    final harness = _Harness(
      root: root,
      owner: owner,
      store: store,
      youngRegistry: youngRegistry,
      jwRegistry: jwRegistry,
      browser: browser,
      leases: leases,
      sync: sync,
    );
    if (initialize) await sync.initialize();
    return harness;
  }

  Future<_JwSeed> seedJw() async {
    final authority = await store.readAuthority();
    await jwRegistry.reconcile(
      await store.readCommittedPermits(),
      ownerId: authority.ownerId,
      resetEpoch: authority.resetEpoch,
      drain: (_) async {},
    );
    _jwRegistryReady = true;
    final ticket = await store.beginJob(expectedAccountCode: _account);
    await store.stageSemesterCatalog(ticket, const <JwSemesterOption>[
      JwSemesterOption(id: 20261, name: 'Synthetic term', selected: true),
    ]);
    await store.stageCredentials(ticket, 'synthetic-jw-password', save: true);
    final partition = await jwRegistry.createProvisional(
      ownerId: ticket.stamp.ownerId,
      purpose: ticket.stamp.accountId == null
          ? JwPartitionPurpose.initial
          : JwPartitionPurpose.recovery,
      attempt: ticket.stamp.jobId,
      resetEpoch: ticket.stamp.resetEpoch,
    );
    await store.stagePartition(ticket, partition);
    final reply = _jwReply(operation: 41);
    final artifact = JwCollectedArtifact.seal(
      reply: reply,
      stamp: ticket.stamp,
      partition: partition,
      session: 1,
      document: 2,
      semesterId: 20261,
      collectedAtUtc: DateTime.utc(2026, 10, 11, 12),
    );
    final receipt = await store.importSnapshot(ticket, artifact);
    await jwRegistry.reconcile(
      await store.readCommittedPermits(),
      ownerId: authority.ownerId,
      resetEpoch: authority.resetEpoch,
      drain: (_) async {},
    );
    return _JwSeed(partition: partition, permit: receipt.permit);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    browser.releaseAvailability();
    browser.releasePartitionBackendCheck();
    browser.releasePoll();
    browser.releaseDrain();
    final automatic = browser;
    if (automatic is _AutomatedBrowser) {
      automatic.releaseInitialReady();
      automatic.releaseNavigation();
      automatic.releasePreparation();
      automatic.releaseSubmission();
    }
    final fault = browser.injectedLedgerFault;
    if (fault != null && await fault.exists()) await fault.delete();
    try {
      if (sync.syncView.phase == YoungSyncPhase.recovery) {
        await sync.retryRecovery();
      }
      if (sync.syncView.phase != YoungSyncPhase.closed) {
        if (sync.syncView.busy) await sync.cancel();
        await sync.shutdown();
      }
    } catch (_) {
      // Teardown must still close the in-memory database and release the
      // temporary owned directory if an assertion exposed a product defect.
    }
    if (_jwRegistryReady) {
      try {
        await jwRegistry.close();
      } catch (_) {}
    }
    try {
      await store.close();
    } catch (_) {}
    await browser.dispose();
    await owner.release();
    final temp = p.windows.normalize(
      await Directory.systemTemp.resolveSymbolicLinks(),
    );
    final target = p.windows.normalize(await root.resolveSymbolicLinks());
    if (!p.windows.isWithin(temp, target)) {
      throw StateError('Synthetic cleanup escaped its temporary root.');
    }
    await Directory(target).delete(recursive: true);
  }
}

final class _JwSeed {
  const _JwSeed({required this.partition, required this.permit});
  final JwPartitionRef partition;
  final JwClaimPermit permit;
}

JwCollectionReply _jwReply({required int operation}) =>
    JwCollectionReply.decode(
      jsonEncode(<String, Object?>{
        'operation': operation,
        'phase': 'done',
        'code': 'ok',
        'identity': <String, Object?>{
          'candidateCount': 1,
          'method': 'definitionList',
          'accountCode': _account,
        },
        'diagnostics': JwDataDiagnostics(
          checks: <String, String>{
            for (final name in <String>[
              'identityBefore',
              'course',
              'index',
              'datum',
              'exams',
              'identityAfter',
            ])
              name: 'ok',
          },
          identityReads: 2,
          lessonIds: 1,
          lessons: 1,
          groups: 1,
          schedules: 1,
          datedSchedules: 1,
          timedSchedules: 1,
          linkedSchedules: 1,
          examRows: 0,
          datedExams: 0,
          semesterAccepted: true,
          selfRouteBound: true,
          identityStable: true,
          emptyCourse: false,
          emptyExams: true,
        ).safeProjection,
        'snapshot': <String, Object?>{
          'version': jwContractVersion,
          'semesterId': 20261,
          'courses': <Map<String, Object?>>[
            <String, Object?>{
              'lessonId': 11,
              'groupId': 21,
              'date': '2026-10-12',
              'startMinute': 480,
              'endMinute': 540,
              'title': _jwCourseTitle,
              'academicDetails': JwAcademicDetails(
                lessonId: 11,
                groupId: 21,
              ).toMap(),
            },
          ],
          'exams': const <Object?>[],
        },
      }),
      operation: operation,
    );

final class _SyntheticProtector implements JwCredentialProtector {
  const _SyntheticProtector();
  @override
  String get mechanism => 'synthetic-test-only';
  @override
  Future<Uint8List> protect(
    Uint8List plaintext, {
    required String purpose,
  }) async => Uint8List.fromList(plaintext.map((byte) => byte ^ 0x5a).toList());
  @override
  Future<Uint8List> unprotect(
    Uint8List ciphertext, {
    required String purpose,
  }) async =>
      Uint8List.fromList(ciphertext.map((byte) => byte ^ 0x5a).toList());
}

final class _SyntheticOwnership implements AssetOwnership {
  const _SyntheticOwnership();

  @override
  bool get isHeld => true;

  @override
  void ensureHeld() {}
}

class _SyntheticBrowser
    implements
        ObservationBrowserPort,
        ObservationAvailabilityBrowserPort,
        YoungBusinessBrowserPort,
        ObservationPartitionBackendBrowserPort {
  _SyntheticBrowser({
    this.activityPlans = const <List<Object?>>[],
    this.calendarByDay = const <String, List<Map<String, Object?>>>{},
    this.calendarPagesByDay = const <String, List<Map<String, Object?>>>{},
    this.holdFirstPoll = false,
    this.holdDrain = false,
  });

  final List<List<Object?>> activityPlans;
  final Map<String, List<Map<String, Object?>>> calendarByDay;
  final Map<String, List<Map<String, Object?>>> calendarPagesByDay;
  final bool holdFirstPoll;
  final bool holdDrain;
  final StreamController<BrowserEvent> _events =
      StreamController<BrowserEvent>.broadcast(sync: true);
  final Completer<void> pollEntered = Completer<void>();
  final Completer<void> drainEntered = Completer<void>();
  bool checkAvailability = false;
  bool holdAvailability = false;
  AppFailure? availabilityFailure;
  int availabilityCalls = 0;
  final Completer<void> availabilityEntered = Completer<void>();
  final Completer<void> _availabilityGate = Completer<void>();
  final Completer<void> _pollGate = Completer<void>();
  final Completer<void> _drainGate = Completer<void>();
  final Map<int, _StepCall> _steps = <int, _StepCall>{};
  final List<String> profilePaths = <String>[];
  final List<String> businessProfilePaths = <String>[];
  final List<String> recoveryOnlyPaths = <String>[];
  final List<String> backendCheckPaths = <String>[];
  final List<ObservationSource> backendSources = <ObservationSource>[];
  final List<bool> backendFixtures = <bool>[];
  final List<_StepCall> dispatched = <_StepCall>[];
  bool checkPartitionBackend = false;
  bool backendCurrent = true;
  AppFailure? backendFailure;
  bool holdPartitionBackendCheck = false;
  Completer<void> partitionBackendCheckEntered = Completer<void>();
  final Completer<void> _partitionBackendCheckGate = Completer<void>();
  Future<void> Function(String path)? onRecoveryOpen;
  int session = 0;
  int document = 0;
  int openCalls = 0;
  int navigationEventCount = 0;
  int startCalls = 0;
  int dispatchCalls = 0;
  int closeCalls = 0;
  int drainedCalls = 0;
  int trueDrainCount = 0;
  int _inFlightPolls = 0;
  int _activePlan = 0;
  int _profileReads = 0;
  int _pollCount = 0;
  int? _operation;
  String _origin = 'https://young.ustc.edu.cn';
  bool _closed = false;
  bool _disposed = false;
  String beforeUsername = _account;
  String afterUsername = _account;
  YoungBusinessEndpoint? failEndpoint;
  YoungBusinessEndpoint? routeOnPollEndpoint;
  File? injectedLedgerFault;

  @override
  Stream<BrowserEvent> get events => _events.stream;

  @override
  bool get requiresAvailabilityCheck => checkAvailability;

  @override
  bool get requiresPartitionBackendCheck => checkPartitionBackend;

  @override
  Future<bool> isCurrentPartitionBackend({
    required String profilePath,
    required ObservationSource source,
    required bool fixture,
  }) async {
    backendCheckPaths.add(profilePath);
    backendSources.add(source);
    backendFixtures.add(fixture);
    if (!partitionBackendCheckEntered.isCompleted) {
      partitionBackendCheckEntered.complete();
    }
    if (holdPartitionBackendCheck) await _partitionBackendCheckGate.future;
    final failure = backendFailure;
    if (failure != null) throw failure;
    return backendCurrent;
  }

  void releasePartitionBackendCheck() {
    if (!_partitionBackendCheckGate.isCompleted) {
      _partitionBackendCheckGate.complete();
    }
  }

  void resetPartitionBackendCheckWaiter() {
    partitionBackendCheckEntered = Completer<void>();
  }

  void releaseAvailability() {
    if (!_availabilityGate.isCompleted) _availabilityGate.complete();
  }

  @override
  Future<void> ensureAvailable() async {
    availabilityCalls++;
    if (!availabilityEntered.isCompleted) availabilityEntered.complete();
    if (holdAvailability) await _availabilityGate.future;
    final failure = availabilityFailure;
    if (failure != null) throw failure;
  }

  @override
  Future<void> open({
    required int session,
    required String profilePath,
    required ObservationTarget target,
    bool recoveryOnly = false,
  }) async {
    this.session = session;
    _origin = target.initialUri.origin;
    document = 1;
    _closed = false;
    ++openCalls;
    profilePaths.add(profilePath);
    if (recoveryOnly) {
      recoveryOnlyPaths.add(profilePath);
      await onRecoveryOpen?.call(profilePath);
    }
    if (!recoveryOnly) {
      businessProfilePaths.add(profilePath);
      _emit(BrowserEventKind.ready, document: document, origin: _origin);
    }
  }

  void _emit(BrowserEventKind kind, {required int document, String? origin}) {
    if (kind == BrowserEventKind.navigating) ++navigationEventCount;
    _events.add(
      BrowserEvent(
        session: session,
        document: document,
        kind: kind,
        origin: origin,
      ),
    );
  }

  void _changeDocument() {
    ++document;
    _emit(BrowserEventKind.navigating, document: document, origin: _origin);
    _emit(BrowserEventKind.ready, document: document, origin: _origin);
  }

  @override
  Future<BrowserInspection> inspect({
    required int session,
    required int document,
  }) async => BrowserInspection(
    session: session,
    document: document,
    ready: true,
    origin: _origin,
  );

  @override
  Future<void> navigateInitial(int session) async => _changeDocument();

  @override
  Future<void> navigateJwPage({
    required int session,
    required int document,
    required JwObservationPage page,
  }) async => _changeDocument();

  @override
  Future<void> navigateYoungBusinessPage({
    required int session,
    required int document,
    required YoungBusinessPage page,
  }) async {
    _requireBinding(session, document);
    _changeDocument();
  }

  @override
  Future<void> close(int session) async {
    if (session != this.session) {
      throw const AppFailure(FailureCode.staleResult);
    }
    ++closeCalls;
    _closed = true;
    releasePoll();
  }

  @override
  Future<bool> drained(int session) async {
    if (session != this.session) {
      throw const AppFailure(FailureCode.staleResult);
    }
    ++drainedCalls;
    if (!drainEntered.isCompleted) drainEntered.complete();
    if (holdDrain) await _drainGate.future;
    final done = _inFlightPolls == 0;
    if (done) ++trueDrainCount;
    return done;
  }

  void releasePoll() {
    if (!_pollGate.isCompleted) _pollGate.complete();
  }

  void releaseDrain() {
    if (!_drainGate.isCompleted) _drainGate.complete();
  }

  @override
  Future<void> startYoungBusiness({
    required int session,
    required int document,
    required int operation,
  }) async {
    _requireBinding(session, document);
    _operation = operation;
    _activePlan = startCalls;
    ++startCalls;
    _profileReads = 0;
  }

  @override
  Future<void> dispatchYoungBusinessStep({
    required int session,
    required int document,
    required int operation,
    required int step,
    required YoungBusinessEndpoint endpoint,
    int page = 0,
    String? day,
  }) async {
    _requireBinding(session, document);
    if (operation != _operation || step <= 0) {
      throw const AppFailure(FailureCode.staleResult);
    }
    ++dispatchCalls;
    if (failEndpoint == endpoint) {
      throw const AppFailure(FailureCode.sourceFailed);
    }
    final call = _StepCall(
      session: session,
      document: document,
      operation: operation,
      step: step,
      endpoint: endpoint,
      page: page,
      day: day,
    );
    _steps[step] = call;
    dispatched.add(call);
  }

  @override
  Future<YoungBusinessStepReply> pollYoungBusinessStep({
    required int session,
    required int document,
    required int operation,
    required int step,
  }) async {
    _requireBinding(session, document);
    final call = _steps[step];
    if (call == null || operation != _operation) {
      throw const AppFailure(FailureCode.staleResult);
    }
    ++_inFlightPolls;
    ++_pollCount;
    try {
      if (holdFirstPoll && _pollCount == 1) {
        if (!pollEntered.isCompleted) pollEntered.complete();
        await _pollGate.future;
      }
      if (routeOnPollEndpoint == call.endpoint) {
        routeOnPollEndpoint = null;
        _changeDocument();
      }
      return _reply(call, jsonEncode(_response(call)));
    } finally {
      --_inFlightPolls;
    }
  }

  Object? _response(_StepCall call) {
    switch (call.endpoint) {
      case YoungBusinessEndpoint.profile:
        ++_profileReads;
        return <String, Object?>{
          'success': true,
          'code': 200,
          'result': <String, Object?>{
            'username': _profileReads == 1 ? beforeUsername : afterUsername,
            'privateMarker': 'synthetic source response only',
          },
        };
      case YoungBusinessEndpoint.activities:
        final plans = activityPlans.isEmpty
            ? <List<Object?>>[
                <Object?>[_page(const <Map<String, Object?>>[], 0)],
              ]
            : activityPlans;
        final planIndex = _activePlan < plans.length
            ? _activePlan
            : plans.length - 1;
        final plan = plans[planIndex];
        if (call.page < 1 || call.page > plan.length) {
          throw const AppFailure(FailureCode.invalidSnapshot);
        }
        return plan[call.page - 1];
      case YoungBusinessEndpoint.schedule:
        final pages = calendarPagesByDay[call.day];
        if (pages != null) {
          if (call.page < 1 || call.page > pages.length) {
            throw const AppFailure(FailureCode.invalidSnapshot);
          }
          return pages[call.page - 1];
        }
        final rows = calendarByDay[call.day] ?? const <Map<String, Object?>>[];
        return _page(rows, rows.length);
    }
  }

  YoungBusinessStepReply _reply(_StepCall call, String projected) =>
      YoungBusinessStepReply.decode(
        <String, Object?>{
          'session': call.session,
          'document': call.document,
          'operation': call.operation,
          'step': call.step,
          'complete': true,
          'projectedJson': projected,
        },
        session: call.session,
        document: call.document,
        operation: call.operation,
        step: call.step,
      );

  @override
  Future<void> finishYoungBusiness({
    required int session,
    required int document,
    required int operation,
  }) async {
    _requireBinding(session, document);
    if (operation != _operation) {
      throw const AppFailure(FailureCode.staleResult);
    }
  }

  void _requireBinding(int session, int document) {
    if (_disposed ||
        session != this.session ||
        document != this.document ||
        _closed) {
      throw const AppFailure(FailureCode.staleResult);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    releasePartitionBackendCheck();
    releasePoll();
    releaseDrain();
    await _events.close();
  }
}

final class _AutomatedBrowser extends _SyntheticBrowser
    implements
        YoungAuthenticationBrowserPort,
        YoungBusinessPreparationBrowserPort {
  _AutomatedBrowser({
    super.activityPlans = const <List<Object?>>[],
    super.calendarByDay = const <String, List<Map<String, Object?>>>{},
    this.loginStates = const <JwLoginState>[JwLoginState.businessReady],
    this.loginSubmitState = JwLoginState.challengeRequired,
    this.helperAvailable = true,
    this.holdInitialReady = false,
    this.changeDocumentOnFirstPreparation = false,
    this.holdNavigation = false,
    this.busyNavigationAttempts = 0,
    this.failNavigationAfterEvent = false,
    this.visitCasBeforeBusinessPage = false,
    this.holdPreparation = false,
    this.holdSubmission = false,
    this.ambiguousSubmission = false,
  });

  final List<JwLoginState> loginStates;
  final JwLoginState loginSubmitState;
  final bool helperAvailable;
  final bool holdInitialReady;
  final bool changeDocumentOnFirstPreparation;
  final bool holdNavigation;
  final int busyNavigationAttempts;
  final bool failNavigationAfterEvent;
  final bool visitCasBeforeBusinessPage;
  final bool holdPreparation;
  final bool holdSubmission;
  final bool ambiguousSubmission;
  final Completer<void> navigationEntered = Completer<void>();
  final Completer<void> loginAdvanceEntered = Completer<void>();
  final Completer<void> preparationEntered = Completer<void>();
  final Completer<void> submissionEntered = Completer<void>();
  final Completer<void> _navigationGate = Completer<void>();
  final Completer<void> _preparationGate = Completer<void>();
  final Completer<void> _submissionGate = Completer<void>();
  final List<int> preparationDocuments = <int>[];
  final List<int> startedDocuments = <int>[];
  final List<_LoginCall> loginAdvances = <_LoginCall>[];
  final List<_LoginCall> loginSubmissions = <_LoginCall>[];
  final List<String> originTransitions = <String>[];
  int _loginStateIndex = 0;
  int _loginAdvanceCount = 0;
  int navigationAttempts = 0;
  int acceptedNavigationCalls = 0;
  bool _initialReadyReleased = false;
  JwSecretLease? lastSubmittedLease;
  String? expectedSyntheticPassword;
  bool verifiedSyntheticPassword = false;

  int get preparationCalls => preparationDocuments.length;

  void releaseNavigation() {
    if (!_navigationGate.isCompleted) _navigationGate.complete();
  }

  void releaseInitialReady() {
    if (!holdInitialReady || _initialReadyReleased || _closed) return;
    _initialReadyReleased = true;
    _emit(BrowserEventKind.ready, document: document, origin: _origin);
  }

  void releasePreparation() {
    if (!_preparationGate.isCompleted) _preparationGate.complete();
  }

  void releaseSubmission() {
    if (!_submissionGate.isCompleted) _submissionGate.complete();
  }

  @override
  Future<void> navigateYoungBusinessPage({
    required int session,
    required int document,
    required YoungBusinessPage page,
  }) async {
    _requireBinding(session, document);
    ++navigationAttempts;
    if (navigationAttempts <= busyNavigationAttempts) {
      // Explicit busy is a pre-navigation refusal: do not change the document
      // and do not emit navigating/ready.
      throw const AppFailure(FailureCode.busy);
    }
    ++acceptedNavigationCalls;
    ++this.document;
    _emit(
      BrowserEventKind.navigating,
      document: this.document,
      origin: _origin,
    );
    if (!navigationEntered.isCompleted) navigationEntered.complete();
    if (failNavigationAfterEvent) {
      // Models a lost native confirmation after Navigate already took effect.
      throw const AppFailure(FailureCode.sourceFailed);
    }
    if (holdNavigation) await _navigationGate.future;
    _emit(BrowserEventKind.ready, document: this.document, origin: _origin);
  }

  @override
  Future<void> open({
    required int session,
    required String profilePath,
    required ObservationTarget target,
    bool recoveryOnly = false,
  }) async {
    this.session = session;
    _origin = target.initialUri.origin;
    document = 1;
    _closed = false;
    ++openCalls;
    profilePaths.add(profilePath);
    if (recoveryOnly) {
      recoveryOnlyPaths.add(profilePath);
      await onRecoveryOpen?.call(profilePath);
    }
    if (!recoveryOnly) {
      businessProfilePaths.add(profilePath);
      if (holdInitialReady) {
        // Bring Dart's document generation to the native document while
        // keeping readiness pending, so tests isolate the ready-event race.
        _emit(BrowserEventKind.navigating, document: document, origin: _origin);
      } else {
        _emit(BrowserEventKind.ready, document: document, origin: _origin);
      }
      if (visitCasBeforeBusinessPage) {
        _transitionOrigin('https://passport.ustc.edu.cn');
      }
    }
  }

  @override
  Future<JwLoginState> advanceYoungLogin({
    required int session,
    required int document,
    required int operation,
  }) async {
    _requireBinding(session, document);
    loginAdvances.add(
      _LoginCall(session: session, document: document, operation: operation),
    );
    if (!loginAdvanceEntered.isCompleted) loginAdvanceEntered.complete();
    ++_loginAdvanceCount;
    if (visitCasBeforeBusinessPage && _loginAdvanceCount == 2) {
      _transitionOrigin('https://young.ustc.edu.cn');
    }
    if (_loginStateIndex >= loginStates.length) {
      return JwLoginState.businessReady;
    }
    return loginStates[_loginStateIndex++];
  }

  void _transitionOrigin(String nextOrigin) {
    _origin = nextOrigin;
    originTransitions.add(nextOrigin);
    ++document;
    _emit(BrowserEventKind.navigating, document: document, origin: _origin);
    _emit(BrowserEventKind.ready, document: document, origin: _origin);
  }

  @override
  Future<JwLoginState> submitYoungLogin({
    required int session,
    required int document,
    required int operation,
    required JwSecretLease credentials,
  }) async {
    _requireBinding(session, document);
    loginSubmissions.add(
      _LoginCall(session: session, document: document, operation: operation),
    );
    lastSubmittedLease = credentials;
    if (!submissionEntered.isCompleted) submissionEntered.complete();
    if (holdSubmission) await _submissionGate.future;
    final expectedPassword = expectedSyntheticPassword;
    if (expectedPassword != null) {
      final plain = credentials.take();
      try {
        final decoded = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
        expect(decoded['username'], _account);
        expect(decoded['password'], expectedPassword);
        verifiedSyntheticPassword = true;
      } finally {
        plain.fillRange(0, plain.length, 0);
      }
    }
    if (ambiguousSubmission) {
      // The fake native boundary accepted a one-shot submit before its reply
      // was lost. The driver must treat stale as ambiguous, never resubmit.
      throw const AppFailure(FailureCode.staleResult);
    }
    return loginSubmitState;
  }

  @override
  Future<bool> prepareYoungBusinessPage({
    required int session,
    required int document,
    required YoungBusinessPage page,
  }) async {
    _requireBinding(session, document);
    preparationDocuments.add(document);
    if (!preparationEntered.isCompleted) preparationEntered.complete();
    if (holdPreparation) await _preparationGate.future;
    if (changeDocumentOnFirstPreparation && preparationDocuments.length == 1) {
      _changeDocument();
    }
    return helperAvailable;
  }

  @override
  Future<void> startYoungBusiness({
    required int session,
    required int document,
    required int operation,
  }) async {
    startedDocuments.add(document);
    await super.startYoungBusiness(
      session: session,
      document: document,
      operation: operation,
    );
  }
}

final class _LoginCall {
  const _LoginCall({
    required this.session,
    required this.document,
    required this.operation,
  });
  final int session;
  final int document;
  final int operation;
}

final class _StepCall {
  const _StepCall({
    required this.session,
    required this.document,
    required this.operation,
    required this.step,
    required this.endpoint,
    required this.page,
    required this.day,
  });
  final int session;
  final int document;
  final int operation;
  final int step;
  final YoungBusinessEndpoint endpoint;
  final int page;
  final String? day;
}
