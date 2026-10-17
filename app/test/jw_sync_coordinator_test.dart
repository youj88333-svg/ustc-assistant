import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/jw_academic_details.dart';
import 'package:ustc_assistant_m0/core/jw_work_contract.dart';
import 'package:ustc_assistant_m0/core/jw_credentials.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/data/jw_import_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/jobs/jw_sync_coordinator.dart';
import 'package:ustc_assistant_m0/jobs/jw_sync_port.dart';
import 'package:ustc_assistant_m0/platform/demo_directory.dart';
import 'package:ustc_assistant_m0/platform/jw_partition_registry.dart';
import 'package:ustc_assistant_m0/source/jw_collection_contract.dart';
import 'package:ustc_assistant_m0/source/jw_collection_failure.dart';
import 'package:ustc_assistant_m0/source/jw_data_probe_contract.dart';
import 'package:ustc_assistant_m0/source/jw_probe_contract.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';
import 'package:ustc_assistant_m0/source/jw_authentication_contract.dart';

const _account = 'TEST0001';
const _semester = 20261;
const _duplicateNormalization = {
  'courseRows': 2,
  'courseEvents': 1,
  'duplicateCourses': 1,
  'examRows': 1,
  'examEvents': 1,
  'duplicateExams': 0,
};

Future<int> _jwJobCount(JwStore store) async =>
    (await store
            .customSelect('SELECT COUNT(*) AS count FROM jw_jobs')
            .getSingle())
        .read<int>('count');

void main() {
  for (final state in [
    JwLoginState.pageStructureChanged,
    JwLoginState.challengeRequired,
    JwLoginState.contextUnavailable,
  ]) {
    test(
      'automatic authentication reports ${state.name} without sending a password',
      () async {
        final h = await _Harness.create(credentialProtector: _TestProtector());
        addTearDown(h.dispose);
        h.browser.authenticationRequired = true;
        h.browser.blockedLogin = state;
        await h.sync.startSync(
          expectedAccountCode: _account,
          password: 'synthetic-password',
          savePassword: true,
        );
        expect(h.sync.syncView.automation, JwAutomationState.manualRequired);
        expect(h.sync.syncView.loginPauseReason?.name, state.name);
        expect(h.browser.submitCount, 0);
        expect(h.browser.directoryReadCount, 0);
        expect(h.sync.syncView.data!.credentialSaved, isFalse);
        expect(
          h.sync.syncView.safeSummary,
          isNot(contains('synthetic-password')),
        );
        await h.sync.cancel();
      },
    );
  }

  test(
    'missing supplied and saved credentials pauses with an explicit reason',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.browser.authenticationRequired = true;
      await h.sync.startSync(expectedAccountCode: _account);
      expect(
        h.sync.syncView.loginPauseReason,
        JwLoginPauseReason.noCredentials,
      );
      expect(h.browser.submitCount, 0);
      h.browser.completeManualLogin();
      await h.sync.continueSync();
      expect(h.sync.syncView.importCommitted, isTrue);
      expect(h.sync.syncView.data!.credentialSaved, isFalse);
      expect(
        h.sync.syncView.loginPauseReason,
        JwLoginPauseReason.noCredentials,
      );
    },
  );

  test(
    'unsupported browser preflight admits no job or secret and preserves an old profile',
    () async {
      final h = await _Harness.create(credentialProtector: _TestProtector());
      addTearDown(h.dispose);
      h.browser.checkAvailability = true;
      h.browser.availabilityFailure = const AppFailure(
        FailureCode.unsupportedPlatform,
      );

      await h.sync.startSync(
        expectedAccountCode: _account,
        password: 'synthetic-password',
        savePassword: true,
      );

      expect(h.sync.syncView.phase, JwSyncPhase.idle);
      expect(h.sync.syncView.failure, FailureCode.unsupportedPlatform);
      expect(h.sync.syncView.failureStage, JwSyncPhase.opening);
      expect(h.sync.syncView.data!.credentialSaved, isFalse);
      expect(await _jwJobCount(h.store), 0);
      expect(await h.store.readCommittedPermits(), isEmpty);
      expect(await h.ledger.list(followLinks: false).toList(), isEmpty);
      expect(h.browser.openCalls, 0);
      expect(h.browser.profilePaths, isEmpty);
      expect(h.leases.isBusy, isFalse);

      final otherJob = h.leases.acquire();
      expect(h.leases.isBusy, isTrue);
      otherJob.release();

      h.browser.availabilityFailure = null;
      await h.importOnce();
      final priorPermit = (await h.store.readCommittedPermits()).single;
      final priorPath = h.profile(priorPermit.partition);
      expect(await Directory(priorPath).exists(), isTrue);
      final jobsBeforeRecoveryAttempt = await _jwJobCount(h.store);

      h.browser.availabilityFailure = const AppFailure(
        FailureCode.unsupportedPlatform,
      );
      await h.sync.open();

      expect(h.sync.syncView.phase, JwSyncPhase.idle);
      expect(h.sync.syncView.failure, FailureCode.unsupportedPlatform);
      expect(await _jwJobCount(h.store), jobsBeforeRecoveryAttempt);
      expect(h.browser.openCalls, 1);
      expect(
        (await h.store.readCommittedPermits()).single.partition.sameAs(
          priorPermit.partition,
        ),
        isTrue,
      );
      expect(await Directory(priorPath).exists(), isTrue);
    },
  );

  test(
    'busy preflight rejects a second open, cancellation beats a late result, and retry imports',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.browser.checkAvailability = true;
      h.browser.holdAvailability = true;
      h.browser.availabilityFailure = const AppFailure(
        FailureCode.unsupportedPlatform,
      );

      final firstOpen = h.sync.open(expectedAccountCode: _account);
      await h.browser.availabilityEntered.future.timeout(
        const Duration(seconds: 2),
      );
      expect(h.leases.isBusy, isTrue);
      await expectLater(
        () => h.sync.open(expectedAccountCode: _account),
        throwsA(
          isA<AppFailure>().having(
            (failure) => failure.code,
            'code',
            FailureCode.busy,
          ),
        ),
      );

      final cancellation = h.sync.cancel();
      expect(h.sync.syncView.phase, JwSyncPhase.closing);
      h.browser.releaseAvailability();
      await Future.wait([firstOpen, cancellation]);

      expect(h.sync.syncView.phase, JwSyncPhase.idle);
      expect(h.sync.syncView.failure, FailureCode.cancelled);
      expect(await _jwJobCount(h.store), 0);
      expect(await h.store.readCommittedPermits(), isEmpty);
      expect(await h.ledger.list(followLinks: false).toList(), isEmpty);
      expect(h.browser.openCalls, 0);
      expect(h.browser.profilePaths, isEmpty);
      expect(h.leases.isBusy, isFalse);

      h.browser.availabilityFailure = null;
      await h.importOnce();
      expect(h.sync.syncView.phase, JwSyncPhase.idle);
      expect(h.sync.syncView.importCommitted, isTrue);
      expect(h.browser.openCalls, 1);
      expect(await h.store.readCommittedPermits(), hasLength(1));
    },
  );

  test(
    'first automatic sync selects the current semester and saves its directory with credentials',
    () async {
      final h = await _Harness.create(credentialProtector: _TestProtector());
      addTearDown(h.dispose);
      h.browser.authenticationRequired = true;
      await h.sync.startSync(
        expectedAccountCode: _account,
        password: 'synthetic-password',
        savePassword: true,
      );
      expect(h.sync.syncView.phase, JwSyncPhase.idle);
      expect(h.browser.submitCount, 1);
      expect(h.browser.directoryReadCount, 1);
      final first = h.sync.syncView;
      expect(first.data!.credentialSaved, isTrue);
      expect(first.data!.lastSemesterId, _semester);
      expect(first.data!.cachedSemesters.single.id, _semester);
      expect(first.importCommitted, isTrue);
      final localIds = first.data!.events
          .map((event) => event.localId)
          .toList();
      await h.sync.startSync();
      expect(h.browser.submitCount, 2);
      expect(h.browser.directoryReadCount, 2);
      expect(h.sync.syncView.phase, JwSyncPhase.idle);
      expect(h.sync.syncView.importCommitted, isTrue);
      expect(h.sync.syncView.data!.importCount, 2);
      expect(h.sync.syncView.data!.events.map((e) => e.localId), localIds);
      expect(
        h.sync.syncView.safeSummary,
        isNot(contains('synthetic-password')),
      );
      expect(h.sync.syncView.safeSummary, isNot(contains(_account)));
      await h.sync.clearSession();
      expect(h.sync.syncView.data!.credentialSaved, isTrue);
      expect(h.sync.syncView.data!.lastSemesterId, _semester);
      expect(h.sync.syncView.data!.cachedSemesters.single.id, _semester);
      await h.sync.deleteSavedCredential();
      expect(h.sync.syncView.data!.credentialSaved, isFalse);
      expect(h.sync.syncView.data!.events.map((e) => e.localId), localIds);
      expect(h.sync.syncView.data!.lastSemesterId, _semester);
    },
  );

  test(
    'backend migration revokes and drains stale JW claims before a fresh credentialed job',
    () async {
      final h = await _Harness.create(credentialProtector: _TestProtector());
      addTearDown(h.dispose);
      h.browser.authenticationRequired = true;
      await h.sync.startSync(
        expectedAccountCode: _account,
        password: 'synthetic-password',
        savePassword: true,
      );
      expect(h.sync.syncView.importCommitted, isTrue);
      JwStoredEvent courseEvent() => h.sync.syncView.data!.events.singleWhere(
        (event) => event.kind == JwEventKind.course,
      );
      final originalEvent = courseEvent();
      await h.sync.setHidden(
        localId: originalEvent.localId,
        expectedVersion: originalEvent.version,
        hidden: true,
      );
      final oldPermit = (await h.store.readCommittedPermits()).single;
      final oldPath = h.profile(oldPermit.partition);

      h.browser.checkPartitionBackend = true;
      h.browser.backendCurrent = true;
      await h.restartCoordinator();
      expect(
        (await h.store.readCommittedPermits()).single.partition.sameAs(
          oldPermit.partition,
        ),
        isTrue,
      );
      expect(await Directory(oldPath).exists(), isTrue);
      expect(h.browser.recoveryOnlyPaths, isEmpty);
      expect(h.browser.backendCheckPaths.last, oldPath);

      h.browser.backendCurrent = false;
      h.browser.onRecoveryOpen = (path) async {
        expect(path, oldPath);
        expect(await h.store.readCommittedPermits(), isEmpty);
      };
      await h.restartCoordinator();
      expect(await h.store.readCommittedPermits(), isEmpty);
      expect(h.browser.recoveryOnlyPaths, contains(oldPath));
      expect(await Directory(oldPath).exists(), isFalse);
      expect(h.sync.syncView.data!.credentialSaved, isTrue);
      expect(courseEvent().hidden, isTrue);

      await h.sync.startSync();
      final firstFreshPermit = (await h.store.readCommittedPermits()).single;
      final firstFreshPath = h.profile(firstFreshPermit.partition);
      expect(firstFreshPath, isNot(oldPath));
      expect(h.browser.submitCount, 2);
      expect(h.sync.syncView.importCommitted, isTrue);
      expect(h.sync.syncView.data!.credentialSaved, isTrue);
      expect(courseEvent().localId, originalEvent.localId);
      expect(courseEvent().hidden, isTrue);

      h.browser.backendCurrent = false;
      h.browser.resetPartitionBackendCheckWaiter();
      h.browser.holdPartitionBackendCheck = true;
      h.browser.onRecoveryOpen = (path) async {
        expect(path, firstFreshPath);
        expect(await h.store.readCommittedPermits(), isEmpty);
      };
      final jobsBeforeSecondMigration = await _jwJobCount(h.store);
      final migratingJob = h.sync.startSync();
      await h.browser.partitionBackendCheckEntered.future.timeout(
        const Duration(seconds: 2),
      );
      final checksWhileBusy = h.browser.backendCheckPaths.length;
      await expectLater(
        h.sync.startSync(),
        throwsA(
          isA<AppFailure>().having(
            (failure) => failure.code,
            'code',
            FailureCode.busy,
          ),
        ),
      );
      expect(h.browser.backendCheckPaths, hasLength(checksWhileBusy));
      expect(await _jwJobCount(h.store), jobsBeforeSecondMigration);
      h.browser.releasePartitionBackendCheck();
      await migratingJob;

      final freshPermit = (await h.store.readCommittedPermits()).single;
      final freshPath = h.profile(freshPermit.partition);
      expect(freshPath, isNot(firstFreshPath));
      expect(h.browser.recoveryOnlyPaths, contains(firstFreshPath));
      expect(await Directory(firstFreshPath).exists(), isFalse);
      expect(await Directory(freshPath).exists(), isTrue);
      expect(h.browser.submitCount, 3);
      expect(h.sync.syncView.importCommitted, isTrue);
      expect(h.sync.syncView.data!.importCount, 3);
      expect(courseEvent().localId, originalEvent.localId);
      expect(courseEvent().hidden, isTrue);
      final currentJob = await h.store
          .customSelect(
            'SELECT status FROM jw_jobs ORDER BY rowid DESC LIMIT 1',
          )
          .getSingle();
      expect(currentJob.read<String>('status'), 'committed');
      expect(
        h.browser.backendSources.every(
          (source) => source == ObservationSource.jw,
        ),
        isTrue,
      );
      expect(h.browser.backendFixtures.every((fixture) => !fixture), isTrue);

      h.browser.backendCurrent = true;
      h.browser.backendFailure = const AppFailure(FailureCode.storageFailed);
      final jobsBeforeBackendFailure = await _jwJobCount(h.store);
      await h.sync.startSync();
      expect(h.sync.syncView.phase, JwSyncPhase.recovery);
      expect(await _jwJobCount(h.store), jobsBeforeBackendFailure);
      expect(
        (await h.store.readCommittedPermits()).single.partition.sameAs(
          freshPermit.partition,
        ),
        isTrue,
      );
      expect(courseEvent().hidden, isTrue);
      h.browser.backendFailure = null;
      await h.sync.retryRecovery();
      expect(h.sync.syncView.phase, JwSyncPhase.idle);
      expect(
        (await h.store.readCommittedPermits()).single.partition.sameAs(
          freshPermit.partition,
        ),
        isTrue,
      );
      expect(h.sync.syncView.data!.importCount, 3);
    },
  );

  test('an expired launcher resumes authentication in the same job', () async {
    final h = await _Harness.create(credentialProtector: _TestProtector());
    addTearDown(h.dispose);
    h.browser.automaticNavigation = true;
    h.browser.redirectLauncherToLoginOnce = true;
    final before = (await h.store.readAuthority()).generation;
    await h.sync.startSync(
      expectedAccountCode: _account,
      password: 'synthetic-password',
      savePassword: true,
    );
    expect(h.sync.syncView.phase, JwSyncPhase.idle);
    expect(h.browser.submitCount, 1);
    expect(h.browser.directoryReadCount, 1);
    expect((await h.store.readAuthority()).generation, before + 1);
    expect(h.sync.syncView.importCommitted, isTrue);
    expect(h.sync.syncView.data!.credentialSaved, isTrue);
  });

  test(
    'an automatic challenge resumes the same job without a second submit',
    () async {
      final h = await _Harness.create(credentialProtector: _TestProtector());
      addTearDown(h.dispose);
      h.browser.authenticationRequired = true;
      h.browser.challengeAfterSubmit = true;
      await h.sync.startSync(
        expectedAccountCode: _account,
        password: 'synthetic-password',
        savePassword: true,
      );
      expect(h.sync.syncView.automation, JwAutomationState.manualRequired);
      expect(h.browser.submitCount, 1);
      expect(h.leases.isBusy, isTrue);
      final generation = (await h.store.readAuthority()).generation;
      h.browser.completeManualLogin();
      await h.sync.continueSync();
      expect((await h.store.readAuthority()).generation, generation);
      expect(h.browser.submitCount, 1);
      expect(h.sync.syncView.phase, JwSyncPhase.idle);
      expect(h.sync.syncView.data!.credentialSaved, isTrue);
      expect(h.sync.syncView.data!.importCount, 1);
    },
  );

  test(
    'a preselected cached semester overrides the previous success only after fresh validation',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.browser.extraSemester = _semester + 1;
      h.browser.automaticNavigation = true;
      await h.sync.startSync(expectedAccountCode: _account);
      expect(h.sync.syncView.importCommitted, isTrue);
      expect(h.sync.syncView.data!.lastSemesterId, _semester);
      expect(h.sync.syncView.data!.cachedSemesters, hasLength(2));
      await h.sync.startSync(semesterId: _semester + 1);
      expect(h.browser.collectedSemesters, [_semester, _semester + 1]);
      expect(h.browser.directoryReadCount, 2);
      expect(h.sync.syncView.data!.lastSemesterId, _semester + 1);
      expect(h.sync.syncView.data!.importCount, 2);
    },
  );

  test(
    'a cached preselection missing from the fresh directory never falls back to another semester',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.browser.extraSemester = _semester + 1;
      h.browser.automaticNavigation = true;
      await h.sync.startSync(expectedAccountCode: _account);
      h.browser.extraSemester = null;
      await h.sync.startSync(semesterId: _semester + 1);
      expect(h.sync.syncView.automation, JwAutomationState.choosingSemester);
      expect(h.browser.collectedSemesters, [_semester]);
      expect(h.sync.syncView.data!.cachedSemesters, hasLength(2));
      expect(h.sync.syncView.data!.importCount, 1);
      await h.sync.cancel();
    },
  );

  test(
    'first sync with an unknown label waits rather than guessing from the ID',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.browser.automaticNavigation = true;
      h.browser.directoryName = 'Unknown semester';
      await h.sync.startSync(expectedAccountCode: _account);
      expect(h.sync.syncView.automation, JwAutomationState.choosingSemester);
      expect(h.browser.collectedSemesters, isEmpty);
      expect(h.sync.syncView.data!.cachedSemesters, isEmpty);
      await h.sync.collect(_semester);
      expect(
        h.sync.syncView.data!.cachedSemesters.single.name,
        'Unknown semester',
      );
      expect(h.sync.syncView.importCommitted, isTrue);
    },
  );

  test(
    'a remembered semester absent from a fresh directory pauses without another import',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      await h.importOnce();
      h.browser.automaticNavigation = true;
      h.browser.directorySemester = _semester + 1;
      await h.sync.startSync();
      expect(h.sync.syncView.phase, JwSyncPhase.login);
      expect(h.sync.syncView.automation, JwAutomationState.choosingSemester);
      expect(h.sync.syncView.semesters.single.id, _semester + 1);
      expect(h.sync.syncView.data!.importCount, 1);
      await h.sync.cancel();
      expect(h.sync.syncView.data!.lastSemesterId, _semester);
      expect(h.sync.syncView.data!.importCount, 1);
      expect(h.leases.isBusy, isFalse);
    },
  );

  test(
    'failed protection opens no browser and commits neither credential nor account',
    () async {
      final h = await _Harness.create(
        credentialProtector: _TestProtector(fail: true),
      );
      addTearDown(h.dispose);
      await h.sync.startSync(
        expectedAccountCode: _account,
        password: 'synthetic-password',
        savePassword: true,
      );
      expect(h.sync.syncView.phase, JwSyncPhase.idle);
      expect(
        h.sync.syncView.credentialFailure,
        JwCredentialFailure.protectionFailed,
      );
      expect(h.browser.profilePaths, isEmpty);
      expect(h.sync.syncView.data!.accountBound, isFalse);
      expect(h.sync.syncView.data!.credentialSaved, isFalse);
      expect(h.sync.syncView.data!.importCount, 0);
      expect(h.leases.isBusy, isFalse);
    },
  );
  test(
    'normalization survives import but clears for the next job and session',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.browser.duplicateCourseRows = true;
      final views = <JwSyncView>[];
      final subscription = h.sync.syncChanges.listen(views.add);
      addTearDown(subscription.cancel);
      await h.importOnce();
      final first = h.sync.syncView;
      expect(first.profileRetained, isTrue);
      expect(first.profileReused, isFalse);
      expect(first.normalization?.safeProjection, _duplicateNormalization);
      expect(first.courseCount, 1);
      expect(first.examCount, 1);
      expect(first.data!.events, hasLength(2));
      expect(
        (jsonDecode(first.safeSummary) as Map)['normalization'],
        _duplicateNormalization,
      );
      final originalIds = first.data!.events.map((e) => e.localId).toList();
      final normalized = views
          .where((view) => view.normalization != null)
          .toList();
      expect(normalized, isNotEmpty);
      expect(normalized.first.phase, JwSyncPhase.closing);
      for (final view in normalized) {
        expect(view.normalization!.safeProjection, _duplicateNormalization);
      }

      await h.prepare();
      expect(h.sync.syncView.profileReused, isTrue);
      expect(h.browser.profilePaths.last, h.browser.profilePaths.first);
      expect(h.sync.syncView.normalization, isNull);
      expect(
        (jsonDecode(h.sync.syncView.safeSummary) as Map).containsKey(
          'normalization',
        ),
        isFalse,
      );
      views.clear();
      await h.sync.collect(_semester);
      final collecting = views.where(
        (view) => view.phase == JwSyncPhase.collecting,
      );
      expect(collecting, isNotEmpty);
      expect(collecting.every((view) => view.normalization == null), isTrue);
      final repeated = h.sync.syncView;
      expect(repeated.phase, JwSyncPhase.idle);
      expect(repeated.profileReused, isTrue);
      expect(repeated.normalization?.safeProjection, _duplicateNormalization);
      expect(repeated.data!.events.map((e) => e.localId), originalIds);
      expect(repeated.data!.importCount, 2);

      await h.sync.clearSession();
      final cleared = h.sync.syncView;
      expect(cleared.phase, JwSyncPhase.idle);
      expect(cleared.normalization, isNull);
      expect(cleared.sessionRetained, isFalse);
      expect(cleared.profileRetained, isFalse);
      expect(cleared.profileReused, isNull);
      expect(
        (jsonDecode(cleared.safeSummary) as Map).containsKey('profileReused'),
        isFalse,
      );
      expect(cleared.data!.events.map((e) => e.localId), originalIds);
      expect(cleared.data!.importCount, 2);
      expect(await h.store.readCommittedPermits(), isEmpty);
      expect(
        (jsonDecode(cleared.safeSummary) as Map).containsKey('normalization'),
        isFalse,
      );
    },
  );

  test(
    'failed browser reopen does not report a completed profile reuse',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      expect(h.sync.syncView.profileReused, isNull);
      await h.importOnce();
      final permit = (await h.store.readCommittedPermits()).single;
      h.browser.failOpenOnce = true;
      await h.sync.open();

      final view = h.sync.syncView;
      expect(view.phase, JwSyncPhase.idle);
      expect(view.failure, FailureCode.sourceFailed);
      expect(view.profileRetained, isTrue);
      expect(view.profileReused, isNull);
      expect(view.importCommitted, isFalse);
      final summary = jsonDecode(view.safeSummary) as Map;
      expect(summary['profileRetained'], isTrue);
      expect(summary['sessionRetained'], isTrue);
      expect(summary.containsKey('profileReused'), isFalse);
      expect(view.safeSummary, isNot(contains(permit.partition.id)));
      expect(view.safeSummary, isNot(contains(h.profile(permit.partition))));
      expect((await h.store.readView()).importCount, 1);
      expect(await h.store.readCommittedPermits(), hasLength(1));
    },
  );

  test(
    'collection validation survives cleanup without granting an import',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      await h.prepare();
      h.browser.validationFailure = JwCollectionValidationFailure(
        JwCollectionRejectionReason.duplicateCourseKey,
        duplicateIdentical: false,
        diagnostics: JwDataDiagnostics(
          identityReads: 2,
          schedules: 2,
          datedSchedules: 2,
          timedSchedules: 2,
          linkedSchedules: 2,
          selfRouteBound: true,
          identityStable: true,
        ),
      );
      await h.sync.collect(_semester);
      final view = h.sync.syncView;
      expect(view.phase, JwSyncPhase.idle);
      expect(view.failure, FailureCode.invalidSnapshot);
      expect(view.failureStage, JwSyncPhase.collecting);
      expect(
        view.collectionValidation?.reason,
        JwCollectionRejectionReason.duplicateCourseKey,
      );
      expect(view.collectionValidation?.duplicateIdentical, isFalse);
      expect(view.collectionValidation?.diagnostics?.schedules, 2);
      expect(view.importCommitted, isFalse);
      expect(view.accountBound, isFalse);
      expect(view.sessionRetained, isFalse);
      expect(h.leases.isBusy, isFalse);
      final data = await h.store.readView();
      expect(data.events, isEmpty);
      expect(data.importCount, 0);
      expect(await h.store.readCommittedPermits(), isEmpty);
      final summary = jsonDecode(view.safeSummary) as Map;
      expect(summary['failureStage'], 'collecting');
      expect(
        (summary['collectionValidation'] as Map)['reason'],
        'duplicateCourseKey',
      );
      expect(view.safeSummary, isNot(contains(_account)));
      expect(view.safeSummary, isNot(contains('2026-10-12')));
      await h.sync.open(expectedAccountCode: _account);
      expect(h.sync.syncView.collectionValidation, isNull);
      expect(h.sync.syncView.failureStage, isNull);
    },
  );

  test(
    'committed import recovers its claim without repeating business or audit',
    () async {
      late _Harness h;
      var inject = true;
      h = await _Harness.create(
        onCheckpoint: (checkpoint) async {
          if (checkpoint == JwImportCheckpoint.beforeCommit && inject) {
            inject = false;
            await h.fault.writeAsString(
              'synthetic registry obstruction',
              flush: true,
            );
          }
        },
      );
      addTearDown(h.dispose);
      h.browser.duplicateCourseRows = true;
      await h.prepare();
      await h.sync.collect(_semester);
      expect(h.sync.syncView.phase, JwSyncPhase.recovery);
      expect(h.sync.syncView.importCommitted, isTrue);
      expect(
        h.sync.syncView.normalization?.safeProjection,
        _duplicateNormalization,
      );
      expect(h.leases.isBusy, isTrue);
      final before = await h.store.readView();
      expect(before.importCount, 1);
      expect(before.auditCount, 1);
      expect(before.events, hasLength(2));
      final permit = (await h.store.readCommittedPermits()).single;
      await h.fault.delete();
      await h.sync.retryRecovery();
      expect(h.sync.syncView.phase, JwSyncPhase.idle);
      expect(h.sync.syncView.sessionRetained, isTrue);
      expect(
        h.sync.syncView.normalization?.safeProjection,
        _duplicateNormalization,
      );
      expect(h.leases.isBusy, isFalse);
      final after = await h.store.readView();
      expect(after.importCount, before.importCount);
      expect(after.auditCount, before.auditCount);
      expect(
        after.events.map((e) => e.localId),
        before.events.map((e) => e.localId),
      );
      expect(
        await h.registry.openClaimed(
          permit,
          ownerId: permit.partition.ownerId,
          resetEpoch: permit.partition.resetEpoch,
        ),
        h.profile(permit.partition),
      );
      expect(h.sync.syncView.safeSummary, isNot(contains(_account)));
      expect(h.sync.syncView.safeSummary, isNot(contains(permit.partition.id)));
    },
  );

  test(
    'a missing permitted profile permits a fresh recovery candidate',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      await h.importOnce();
      final oldPermit = (await h.store.readCommittedPermits()).single;
      final oldPath = h.profile(oldPermit.partition);
      // The fake browser created no contents. Delete only this test profile.
      h.owner.checkedChildPath(
        p.windows.relative(oldPath, from: h.owner.path),
        directory: true,
      );
      await Directory(oldPath).delete();
      await h.sync.open();
      expect(h.sync.syncView.phase, JwSyncPhase.login);
      expect(h.sync.syncView.ready, isTrue);
      expect(h.sync.syncView.profileReused, isFalse);
      final recoveryPath = h.browser.profilePaths.last;
      expect(recoveryPath, isNot(oldPath));
      final recovery = JwPartitionRef.decode(
        (jsonDecode(
                  await File(
                    p.windows.join(
                      h.ledger.path,
                      '${p.windows.basename(recoveryPath)}.json',
                    ),
                  ).readAsString(),
                )
                as Map<String, dynamic>)['partition']
            as Map<String, dynamic>,
      );
      expect(recovery.purpose, JwPartitionPurpose.recovery);
      await h.sync.verifyDirectory();
      await h.sync.collect(_semester);
      expect(h.sync.syncView.phase, JwSyncPhase.idle);
      expect(
        (await h.store.readCommittedPermits()).single.partition.sameAs(
          recovery,
        ),
        isTrue,
      );
      final data = await h.store.readView();
      expect(data.events, hasLength(2));
      expect(data.importCount, 2);
      expect(data.auditCount, 2);
    },
  );

  test(
    'failed session revocation remains pending until retry preserves business',
    () async {
      final interceptor = _Faults();
      final h = await _Harness.create(interceptor: interceptor);
      addTearDown(h.dispose);
      await h.importOnce();
      final permit = (await h.store.readCommittedPermits()).single;
      final before = await h.store.readView();
      interceptor.failRevokeOnce = true;
      await h.sync.clearSession();
      expect(h.sync.syncView.phase, JwSyncPhase.recovery);
      expect(h.leases.isBusy, isTrue);
      expect(await h.store.readCommittedPermits(), hasLength(1));
      expect(await Directory(h.profile(permit.partition)).exists(), isTrue);
      await h.sync.retryRecovery();
      expect(h.sync.syncView.phase, JwSyncPhase.idle);
      expect(h.sync.syncView.sessionRetained, isFalse);
      expect(h.leases.isBusy, isFalse);
      expect(await h.store.readCommittedPermits(), isEmpty);
      expect(await Directory(h.profile(permit.partition)).exists(), isFalse);
      final after = await h.store.readView();
      expect(after.accountBound, isTrue);
      expect(
        after.events.map((e) => e.localId),
        before.events.map((e) => e.localId),
      );
      expect(after.importCount, before.importCount);
      expect(after.auditCount, before.auditCount);
    },
  );

  test(
    'missing evidence and identity change preserve claimed assets; stable mismatch revokes only the session',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      await h.importOnce();
      final permit = (await h.store.readCommittedPermits()).single;
      final before = await h.store.readView();
      await h.sync.open();
      h.browser.directoryMissing = true;
      await h.sync.verifyDirectory();
      expect(
        h.sync.syncView.identityFailure,
        JwIdentityFailure.identityUnverified,
      );
      expect(h.sync.syncView.phase, JwSyncPhase.idle);
      expect(
        (await h.store.readCommittedPermits()).single.partition.sameAs(
          permit.partition,
        ),
        isTrue,
      );
      expect(await Directory(h.profile(permit.partition)).exists(), isTrue);

      h.browser.directoryMissing = false;
      await h.prepare();
      h.browser.collectionFailure = JwDataProbeCode.identityChanged;
      await h.sync.collect(_semester);
      expect(h.sync.syncView.sourceFailure, JwDataProbeCode.identityChanged);
      expect(
        (await h.store.readCommittedPermits()).single.partition.sameAs(
          permit.partition,
        ),
        isTrue,
      );
      expect(await Directory(h.profile(permit.partition)).exists(), isTrue);

      h.browser.collectionFailure = null;
      h.browser.directoryAccount = 'TEST0002';
      await h.prepare();
      // A weak directory mismatch alone neither imports nor revokes a permit.
      expect(h.sync.syncView.phase, JwSyncPhase.login);
      expect(await h.store.readCommittedPermits(), hasLength(1));
      expect(await Directory(h.profile(permit.partition)).exists(), isTrue);
      h.browser.collectedAccount = 'TEST0002';
      await h.sync.collect(_semester);
      expect(
        h.sync.syncView.identityFailure,
        JwIdentityFailure.accountMismatch,
      );
      expect(h.sync.syncView.phase, JwSyncPhase.idle);
      expect(h.sync.syncView.sessionRetained, isFalse);
      expect(await h.store.readCommittedPermits(), isEmpty);
      expect(await Directory(h.profile(permit.partition)).exists(), isFalse);
      final after = await h.store.readView();
      expect(after.accountBound, isTrue);
      expect(
        after.events.map((e) => e.localId),
        before.events.map((e) => e.localId),
      );
      expect(after.importCount, before.importCount);
      expect(after.auditCount, before.auditCount);
      expect(h.leases.isBusy, isFalse);
    },
  );

  test(
    'accepted cancellation discards a late collection and cleans its candidate',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      await h.prepare();
      final path = h.browser.profilePaths.last;
      final before = await h.store.readAuthority();
      h.browser.holdCollection = true;
      final collection = h.sync.collect(_semester);
      await h.browser.collectionEntered.future;
      final cancellation = h.sync.cancel();
      final cancelled = await h.store.readAuthority();
      expect(cancelled.generation, greaterThan(before.generation));
      expect(h.leases.isBusy, isTrue);
      h.browser.releaseCollection();
      await Future.wait([collection, cancellation]);
      expect(h.sync.syncView.phase, JwSyncPhase.idle);
      expect(h.sync.syncView.importCommitted, isFalse);
      expect((await h.store.readView()).events, isEmpty);
      expect((await h.store.readView()).importCount, 0);
      expect((await h.store.readView()).auditCount, 0);
      expect(await h.store.readCommittedPermits(), isEmpty);
      expect(await Directory(path).exists(), isFalse);
      expect(h.leases.isBusy, isFalse);
    },
  );

  test(
    'shutdown waits for an in-flight hidden write and completes once',
    () async {
      final interceptor = _Faults();
      final h = await _Harness.create(interceptor: interceptor);
      addTearDown(h.dispose);
      await h.importOnce();
      final event = (await h.store.readView()).events.first;
      interceptor.holdHidden = true;
      final write = h.sync.setHidden(
        localId: event.localId,
        expectedVersion: event.version,
        hidden: true,
      );
      await interceptor.hiddenEntered.future;
      var shutdownDone = false;
      final shutdown = h.sync.shutdown().then((_) => shutdownDone = true);
      await Future<void>.delayed(Duration.zero);
      expect(shutdownDone, isFalse);
      expect(h.leases.isBusy, isTrue);
      interceptor.releaseHidden();
      await write;
      await shutdown;
      expect(shutdownDone, isTrue);
      expect(h.sync.syncView.phase, JwSyncPhase.closed);
      expect(h.leases.isBusy, isFalse);
      final stored = (await h.store.readView()).events.singleWhere(
        (e) => e.localId == event.localId,
      );
      expect(stored.hidden, isTrue);
      expect(stored.version, event.version + 1);
    },
  );
}

final class _Faults extends QueryInterceptor {
  bool failRevokeOnce = false;
  bool holdHidden = false;
  final hiddenEntered = Completer<void>();
  final _hiddenAllowed = Completer<void>();

  void releaseHidden() {
    if (!_hiddenAllowed.isCompleted) _hiddenAllowed.complete();
  }

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (failRevokeOnce && statement.trim() == 'DELETE FROM jw_permits') {
      failRevokeOnce = false;
      throw const AppFailure(FailureCode.storageFailed);
    }
    if (holdHidden && statement.startsWith('UPDATE jw_overlays SET hidden =')) {
      if (!hiddenEntered.isCompleted) hiddenEntered.complete();
      await _hiddenAllowed.future;
    }
    await executor.runCustom(statement, args);
  }
}

/// Reversible synthetic protection, never used by production composition.
final class _TestProtector implements JwCredentialProtector {
  _TestProtector({this.fail = false});
  final bool fail;
  @override
  String get mechanism => 'synthetic-only';
  @override
  Future<Uint8List> protect(
    Uint8List plaintext, {
    required String purpose,
  }) async {
    if (fail) {
      throw const JwCredentialException(JwCredentialFailure.protectionFailed);
    }
    return Uint8List.fromList(plaintext.map((byte) => byte ^ 0xa7).toList());
  }

  @override
  Future<Uint8List> unprotect(
    Uint8List ciphertext, {
    required String purpose,
  }) async =>
      Uint8List.fromList(ciphertext.map((byte) => byte ^ 0xa7).toList());
}

final class _Harness {
  _Harness(
    this.root,
    this.owner,
    this.store,
    this.registry,
    this.browser,
    this.leases,
    this.sync,
    this.interceptor,
  );
  final Directory root;
  final DemoDirectory owner;
  final JwStore store;
  JwPartitionRegistry registry;
  final _Browser browser;
  final WorkLeasePool leases;
  JwSyncCoordinator sync;
  final _Faults? interceptor;
  Directory get ledger =>
      Directory(p.windows.join(owner.path, 'jw_partitions_v1'));
  File get fault =>
      File(p.windows.join(ledger.path, 'synthetic-obstruction.txt'));
  String profile(JwPartitionRef ref) => p.windows.join(ledger.path, ref.id);

  static Future<_Harness> create({
    Future<void> Function(JwImportCheckpoint)? onCheckpoint,
    _Faults? interceptor,
    JwCredentialProtector? credentialProtector,
  }) async {
    final root = await Directory.systemTemp.createTemp('ustc_jw_sync_');
    final owner = await DemoDirectory.acquire(
      p.windows.join(root.path, 'owner'),
    );
    final memory = NativeDatabase.memory();
    final store = JwStore(
      interceptor == null ? memory : memory.interceptWith(interceptor),
      ownership: owner,
      clock: FixedClock(DateTime.utc(2026, 10, 10)),
      onCheckpoint: onCheckpoint,
      credentialProtector: credentialProtector,
    );
    await store.initialize();
    final registry = JwPartitionRegistry(owner);
    final browser = _Browser();
    final leases = WorkLeasePool();
    final sync = JwSyncCoordinator(
      store: store,
      registry: registry,
      browser: browser,
      leases: leases,
      clock: FixedClock(DateTime.utc(2026, 10, 10)),
      loginWaitTimeout: const Duration(milliseconds: 100),
      automationPollInterval: const Duration(milliseconds: 1),
    );
    await sync.initialize();
    return _Harness(
      root,
      owner,
      store,
      registry,
      browser,
      leases,
      sync,
      interceptor,
    );
  }

  Future<void> prepare() async {
    final bound = (await store.readAuthority()).accountBound;
    await sync.open(expectedAccountCode: bound ? null : _account);
    expect(sync.syncView.phase, JwSyncPhase.login);
    expect(sync.syncView.ready, isTrue);
    await sync.verifyDirectory();
    expect(sync.syncView.semesters.single.id, _semester);
  }

  Future<void> importOnce() async {
    await prepare();
    await sync.collect(_semester);
    expect(sync.syncView.phase, JwSyncPhase.idle);
    expect(sync.syncView.importCommitted, isTrue);
  }

  JwSyncCoordinator _newCoordinator() => JwSyncCoordinator(
    store: store,
    registry: registry,
    browser: browser,
    leases: leases,
    clock: FixedClock(DateTime.utc(2026, 10, 10)),
    loginWaitTimeout: const Duration(milliseconds: 100),
    automationPollInterval: const Duration(milliseconds: 1),
  );

  Future<void> restartCoordinator() async {
    await sync.shutdown();
    registry = JwPartitionRegistry(owner);
    sync = _newCoordinator();
    await sync.initialize();
  }

  Future<void> dispose() async {
    browser.releaseAvailability();
    browser.releaseCollection();
    browser.releasePartitionBackendCheck();
    interceptor?.releaseHidden();
    if (await fault.exists()) await fault.delete();
    if (sync.syncView.phase == JwSyncPhase.recovery) await sync.retryRecovery();
    await sync.shutdown();
    await store.close();
    await browser.eventsController.close();
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

final class _Browser
    implements
        ObservationBrowserPort,
        ObservationAvailabilityBrowserPort,
        JwProbeBrowserPort,
        JwCollectionBrowserPort,
        JwAuthenticationBrowserPort,
        ObservationPartitionBackendBrowserPort {
  final eventsController = StreamController<BrowserEvent>.broadcast(sync: true);
  final profilePaths = <String>[];
  final recoveryOnlyPaths = <String>[];
  final backendCheckPaths = <String>[];
  final backendSources = <ObservationSource>[];
  final backendFixtures = <bool>[];
  bool checkPartitionBackend = false;
  bool backendCurrent = true;
  AppFailure? backendFailure;
  bool holdPartitionBackendCheck = false;
  Completer<void> partitionBackendCheckEntered = Completer<void>();
  final _partitionBackendCheckGate = Completer<void>();
  Future<void> Function(String path)? onRecoveryOpen;
  bool checkAvailability = false;
  bool holdAvailability = false;
  AppFailure? availabilityFailure;
  int availabilityCalls = 0;
  int openCalls = 0;
  final availabilityEntered = Completer<void>();
  final _availabilityGate = Completer<void>();
  final collectionEntered = Completer<void>();
  Completer<JwCollectionReply>? _heldCollection;
  int? _heldOperation;
  bool directoryMissing = false;
  bool failOpenOnce = false;
  bool authenticationRequired = false;
  bool automaticNavigation = false;
  bool redirectLauncherToLoginOnce = false;
  bool challengeAfterSubmit = false;
  JwLoginState? blockedLogin;
  bool _authenticated = true;
  int submitCount = 0;
  int directoryReadCount = 0;
  int directorySemester = _semester;
  int? extraSemester;
  String directoryName = '2026 秋季学期（合成）';
  final collectedSemesters = <int>[];
  int _collectionSemester = _semester;
  int _document = 1;
  String directoryAccount = _account;
  bool holdCollection = false;
  bool duplicateCourseRows = false;
  String collectedAccount = _account;
  JwDataProbeCode? collectionFailure;
  JwCollectionValidationFailure? validationFailure;
  int? _session;
  String _origin = 'https://jw.ustc.edu.cn';

  @override
  Stream<BrowserEvent> get events => eventsController.stream;

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
    openCalls++;
    _session = session;
    _origin = target.initialUri.origin;
    profilePaths.add(profilePath);
    if (recoveryOnly) {
      recoveryOnlyPaths.add(profilePath);
      await onRecoveryOpen?.call(profilePath);
    }
    _document = 1;
    _authenticated = !authenticationRequired;
    if (failOpenOnce) {
      failOpenOnce = false;
      throw const AppFailure(FailureCode.sourceFailed);
    }
    if (!recoveryOnly) {
      eventsController.add(
        BrowserEvent(
          session: session,
          document: 1,
          kind: BrowserEventKind.ready,
          origin: _authenticated ? _origin : 'https://id.ustc.edu.cn',
        ),
      );
    }
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
  Future<void> navigateInitial(int session) async {}
  @override
  Future<void> navigateJwPage({
    required int session,
    required int document,
    required JwObservationPage page,
  }) async {
    if (redirectLauncherToLoginOnce) {
      redirectLauncherToLoginOnce = false;
      _authenticated = false;
      eventsController.add(
        BrowserEvent(
          session: session,
          document: ++_document,
          kind: BrowserEventKind.ready,
          origin: 'https://id.ustc.edu.cn',
        ),
      );
      return;
    }
    if (authenticationRequired || automaticNavigation) {
      eventsController.add(
        BrowserEvent(
          session: session,
          document: ++_document,
          kind: BrowserEventKind.ready,
          origin: _origin,
        ),
      );
    }
  }

  void completeManualLogin() {
    _authenticated = true;
    eventsController.add(
      BrowserEvent(
        session: _session!,
        document: ++_document,
        kind: BrowserEventKind.ready,
        origin: _origin,
      ),
    );
  }

  @override
  Future<JwLoginState> advanceJwLogin({
    required int session,
    required int document,
    required int operation,
  }) async => _authenticated
      ? JwLoginState.businessReady
      : blockedLogin ?? JwLoginState.formReady;

  @override
  Future<JwLoginState> submitJwLogin({
    required int session,
    required int document,
    required int operation,
    required JwSecretLease credentials,
  }) async {
    final plain = credentials.take();
    try {
      final data = jsonDecode(utf8.decode(plain)) as Map;
      expect(data['username'], _account);
      expect(data['password'], 'synthetic-password');
      submitCount++;
      if (challengeAfterSubmit) return JwLoginState.manualRequired;
      completeManualLogin();
      return JwLoginState.submitted;
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }

  @override
  Future<void> close(int session) async {
    expect(session, _session);
  }

  @override
  Future<bool> drained(int session) async => true;
  @override
  Future<JwProbeReply> startJwProbe({
    required int session,
    required int document,
    required int operation,
  }) async {
    directoryReadCount++;
    return _directory(
      operation,
      missing: directoryMissing,
      account: directoryAccount,
      semester: directorySemester,
      extraSemester: extraSemester,
      name: directoryName,
    );
  }

  @override
  Future<JwProbeReply> pollJwProbe({
    required int session,
    required int document,
    required int operation,
  }) async => _directory(
    operation,
    missing: directoryMissing,
    account: directoryAccount,
  );
  @override
  Future<JwProbeReply> cancelJwProbe({
    required int session,
    required int document,
    required int operation,
  }) async => _directory(operation, missing: true);
  @override
  Future<JwCollectionReply> startJwCollection({
    required int session,
    required int document,
    required int operation,
    required int semesterId,
  }) async {
    expect([
      directorySemester,
      if (extraSemester != null) extraSemester,
    ], contains(semesterId));
    collectedSemesters.add(semesterId);
    _collectionSemester = semesterId;
    if (validationFailure case final failure?) throw failure;
    if (!holdCollection) {
      return _collection(
        operation,
        collectedAccount,
        failure: collectionFailure,
        duplicateCourseRows: duplicateCourseRows,
        semester: semesterId,
      );
    }
    _heldOperation = operation;
    _heldCollection = Completer<JwCollectionReply>();
    if (!collectionEntered.isCompleted) collectionEntered.complete();
    return _heldCollection!.future;
  }

  void releaseCollection() {
    final held = _heldCollection;
    if (held != null && !held.isCompleted) {
      held.complete(
        _collection(
          _heldOperation!,
          collectedAccount,
          duplicateCourseRows: duplicateCourseRows,
          semester: _collectionSemester,
        ),
      );
    }
  }

  @override
  Future<JwCollectionReply> pollJwCollection({
    required int session,
    required int document,
    required int operation,
  }) async => _collection(
    operation,
    collectedAccount,
    failure: collectionFailure,
    duplicateCourseRows: duplicateCourseRows,
    semester: _collectionSemester,
  );
  @override
  Future<JwCollectionReply> cancelJwCollection({
    required int session,
    required int document,
    required int operation,
  }) async => _collection(
    operation,
    collectedAccount,
    failure: JwDataProbeCode.cancelled,
  );
}

JwProbeReply _directory(
  int operation, {
  bool missing = false,
  String account = _account,
  int semester = _semester,
  int? extraSemester,
  String name = '2026 秋季学期（合成）',
}) => JwProbeReply.decode(
  jsonEncode({
    'operation': operation,
    'phase': missing ? 'failed' : 'done',
    'code': missing ? 'identity_schema' : 'ok',
    if (!missing)
      'identity': {
        'candidateCount': 1,
        'accountCode': account,
        'method': 'definitionList',
      },
    if (!missing)
      'semesters': [
        {'id': semester, 'name': name, 'selected': true},
        if (extraSemester != null)
          {'id': extraSemester, 'name': '2026 春季学期（合成）', 'selected': false},
      ],
    if (!missing)
      'summary': {
        'identityLabels': 1,
        'semesterOptions': extraSemester == null ? 1 : 2,
        'semesterSelect': true,
        'examTables': 1,
        'examHeader': true,
        'examRows': 1,
        'pagination': false,
        'semesterVariables': {
          'allSemesters': false,
          'semesters': true,
          'semesterId': true,
          'bizTypeId': false,
        },
        'stageResults': {'identity': 'ok', 'course': 'ok', 'exams': 'ok'},
        'courseDiagnostics': const JwCourseDiagnostics().safeProjection,
      },
  }),
  operation: operation,
);

JwCollectionReply _collection(
  int operation,
  String account, {
  JwDataProbeCode? failure,
  bool duplicateCourseRows = false,
  int semester = _semester,
}) => JwCollectionReply.decode(
  jsonEncode({
    'operation': operation,
    'phase': failure == null ? 'done' : 'failed',
    'code': failure?.wire ?? 'ok',
    if (failure == null)
      'identity': {
        'candidateCount': 1,
        'method': 'definitionList',
        'accountCode': account,
      },
    if (failure == null)
      'diagnostics': JwDataDiagnostics(
        checks: {
          for (final stage in [
            'identityBefore',
            'course',
            'index',
            'datum',
            'exams',
            'identityAfter',
          ])
            stage: 'ok',
        },
        identityReads: 2,
        lessonIds: 1,
        lessons: 1,
        groups: 1,
        schedules: duplicateCourseRows ? 2 : 1,
        datedSchedules: duplicateCourseRows ? 2 : 1,
        timedSchedules: duplicateCourseRows ? 2 : 1,
        linkedSchedules: duplicateCourseRows ? 2 : 1,
        examRows: 1,
        datedExams: 1,
        semesterAccepted: true,
        selfRouteBound: true,
        identityStable: true,
      ).safeProjection,
    if (failure == null)
      'snapshot': {
        'version': jwContractVersion,
        'semesterId': semester,
        'courses': [
          {
            'lessonId': 11,
            'groupId': 21,
            'date': '2026-10-12',
            'startMinute': 480,
            'endMinute': 590,
            'title': 'Synthetic course',
            'academicDetails': JwAcademicDetails(
              lessonId: 11,
              groupId: 21,
            ).toMap(),
          },
          if (duplicateCourseRows)
            {
              'lessonId': 11,
              'groupId': 21,
              'date': '2026-10-12',
              'startMinute': 480,
              'endMinute': 590,
              'title': 'Synthetic course',
              'academicDetails': JwAcademicDetails(
                lessonId: 11,
                groupId: 21,
              ).toMap(),
            },
        ],
        'exams': [
          {
            'courseCode': 'SYNTHETIC01',
            'examType': 'Final',
            'date': '2026-10-20',
            'startMinute': 540,
            'endMinute': 660,
            'title': 'Synthetic exam',
            'academicDetails': JwAcademicDetails(
              courseCode: 'SYNTHETIC01',
              examType: 'Final',
            ).toMap(),
          },
        ],
      },
  }),
  operation: operation,
);
