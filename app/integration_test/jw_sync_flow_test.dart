import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/data/jw_import_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/jobs/jw_sync_coordinator.dart';
import 'package:ustc_assistant_m0/jobs/jw_sync_port.dart';
import 'package:ustc_assistant_m0/platform/demo_directory.dart';
import 'package:ustc_assistant_m0/platform/jw_partition_registry.dart';
import 'package:ustc_assistant_m0/platform/native_database.dart';
import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';
import 'package:ustc_assistant_m0/platform/windows_jw_credential_protector.dart';
import 'package:ustc_assistant_m0/source/jw_collection_failure.dart';
import 'package:ustc_assistant_m0/source/jw_data_probe_contract.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';

import 'support/jw_sync_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native encrypted login selects the current semester, persists its catalog and supports preselection after reopen',
    (tester) async {
      await tester.runAsync(() async {
        final fixture = await JwSyncFixture.start(requireLogin: true);
        final root = await _createTempRoot();
        final harnesses = <_Harness>[];
        try {
          final first = await _Harness.create(
            p.windows.join(root.path, 'owned'),
            fixture,
          );
          harnesses.add(first);
          await first.coordinator
              .startSync(
                expectedAccountCode: 'TEST0001',
                password: 'synthetic-password',
                savePassword: true,
              )
              .timeout(const Duration(seconds: 90));
          expect(
            first.coordinator.syncView.phase,
            JwSyncPhase.idle,
            reason: first.coordinator.syncView.safeSummary,
          );
          expect(fixture.authenticationSubmissions, 1);
          final before = first.coordinator.syncView.data!;
          expect(before.credentialSaved, isTrue);
          expect(before.lastSemesterId, 20261);
          expect(before.cachedSemesters, hasLength(2));
          expect(before.events, hasLength(2));
          expect(
            before.events
                .singleWhere((event) => event.kind == JwEventKind.course)
                .semesterId,
            20261,
          );
          expect(
            before.events
                .singleWhere((event) => event.kind == JwEventKind.exam)
                .semesterId,
            isNull,
          );
          expect(before.importCount, 1);
          final ids = before.events.map((event) => event.localId).toList();
          await first.dispose();
          final reopened = await _Harness.create(
            p.windows.join(root.path, 'owned'),
            fixture,
          );
          harnesses.add(reopened);
          expect(reopened.coordinator.syncView.data!.credentialSaved, isTrue);
          expect(
            reopened.coordinator.syncView.data!.cachedSemesters,
            hasLength(2),
          );
          await reopened.coordinator.startSync().timeout(
            const Duration(seconds: 90),
          );
          final view = reopened.coordinator.syncView;
          expect(view.phase, JwSyncPhase.idle, reason: view.safeSummary);
          expect(view.importCommitted, isTrue, reason: view.safeSummary);
          expect(fixture.authenticationSubmissions, 2);
          expect(view.data!.events.map((event) => event.localId), ids);
          expect(view.data!.importCount, 2);
          expect(view.data!.credentialSaved, isTrue);
          expect(view.data!.lastSemesterId, 20261);
          expect(fixture.acceptedIndexSemesters, [20261, 20261]);
          await reopened.coordinator
              .startSync(semesterId: 20262)
              .timeout(const Duration(seconds: 90));
          expect(reopened.coordinator.syncView.importCommitted, isTrue);
          expect(reopened.coordinator.syncView.data!.lastSemesterId, 20262);
          expect(reopened.coordinator.syncView.data!.importCount, 3);
          expect(
            reopened.coordinator.syncView.data!.events
                .where((event) => event.kind == JwEventKind.course)
                .map((event) => event.semesterId),
            unorderedEquals([20261, 20262]),
          );
          expect(
            reopened.coordinator.syncView.data!.events
                .where((event) => event.kind == JwEventKind.exam)
                .every((event) => event.semesterId == null),
            isTrue,
          );
          expect(fixture.authenticationSubmissions, 3);
          expect(fixture.acceptedIndexSemesters, [20261, 20261, 20262]);
          fixture.hideSpringSemester = true;
          await reopened.coordinator
              .startSync(semesterId: 20262)
              .timeout(const Duration(seconds: 90));
          expect(
            reopened.coordinator.syncView.automation,
            JwAutomationState.choosingSemester,
          );
          expect(reopened.coordinator.syncView.semesters.single.id, 20261);
          expect(
            reopened.coordinator.syncView.data!.cachedSemesters,
            hasLength(2),
          );
          expect(reopened.coordinator.syncView.data!.importCount, 3);
          expect(fixture.authenticationSubmissions, 4);
          expect(fixture.acceptedIndexSemesters, [20261, 20261, 20262]);
          await reopened.coordinator.cancel();
          expect(fixture.rejectedRequestCount, 0);
          expect(view.safeSummary, isNot(contains('synthetic-password')));
          expect(view.safeSummary, isNot(contains('TEST0001')));
        } finally {
          await _cleanup(fixture, root, harnesses);
        }
      });
    },
  );

  testWidgets(
    'native JW import persists, projects scope, and reuses its profile',
    (tester) async {
      await tester.runAsync(() async {
        final fixture = await JwSyncFixture.start();
        final root = await _createTempRoot();
        final harnesses = <_Harness>[];
        try {
          final first = await _Harness.create(
            p.windows.join(root.path, 'owned'),
            fixture,
          );
          harnesses.add(first);

          final firstPage = await _openReady(
            first,
            fixture,
            expectedAccountCode: 'TEST0001',
            expectedProfileReused: false,
            expectedPersistentMarker: false,
            expectedSessionMarker: false,
          );
          await _verifyDirectory(first);
          final directory = first.coordinator.syncView.semesters;
          expect(directory.map((option) => option.id).toList(), [20261, 20262]);
          expect(directory.map((option) => option.name).toList(), [
            '2026 秋季学期（合成）',
            '2026 春季学期（合成）',
          ]);
          expect(directory.where((option) => option.selected).single.id, 20261);

          final rawChannel = const MethodChannel(
            'ustc_assistant/observation_v1',
          );
          final rejected = throwsA(
            isA<PlatformException>()
                .having((error) => error.code, 'code', 'app_failure')
                .having((error) => error.details, 'details', 'invalidSnapshot'),
          );
          final fixedExtras = <Map<String, Object>>[
            {'url': 'http://127.0.0.1:1/forbidden'},
            {
              'lessonIds': <int>[11],
            },
          ];
          for (var index = 0; index < fixedExtras.length; index++) {
            await expectLater(
              rawChannel.invokeMethod<Object>('readJwCollection', {
                'session': firstPage.session,
                'document': firstPage.document,
                'operation': 900000000 + index,
                'semesterId': 20261,
                ...fixedExtras[index],
              }),
              rejected,
            );
          }
          expect(fixture.acceptedIndexSemesters, isEmpty);
          expect(fixture.acceptedDatumLessonIds, isEmpty);
          expect(
            fixture.requests.where(
              (path) => path.endsWith('/get-data') || path.endsWith('/datum'),
            ),
            isEmpty,
          );

          await first.coordinator
              .collect(20261)
              .timeout(const Duration(seconds: 75));
          final firstView = first.coordinator.syncView;
          expect(firstView.phase, JwSyncPhase.idle);
          expect(firstView.importCommitted, isTrue);
          expect(firstView.sessionRetained, isTrue);
          expect(firstView.profileRetained, isTrue);
          expect(firstView.profileReused, isFalse);
          expect(firstView.courseCount, 1);
          expect(firstView.examCount, 1);
          final firstData = _data(firstView);
          expect(firstData.accountBound, isTrue);
          expect(firstData.events, hasLength(2));
          expect(firstData.importCount, 1);
          expect(firstData.auditCount, 1);
          expect(fixture.acceptedIndexSemesters, [20261]);
          expect(fixture.acceptedDatumLessonIds, [
            const [11],
          ]);

          final course = firstData.events.singleWhere(
            (event) => event.kind == JwEventKind.course,
          );
          final exam = firstData.events.singleWhere(
            (event) => event.kind == JwEventKind.exam,
          );
          expect(course.title, '合成课程');
          expect(course.semesterId, 20261);
          expect(course.presence, JwPresence.observed);
          expect(
            course.academicDetails!.locationLabel,
            '合成教室 5304 · 合成教学楼 · 合成东校区',
          );
          expect(course.academicDetails!.teachers, ['合成教师甲']);
          expect(course.academicDetails!.courseCode, 'SYN-C101.01');
          expect(course.academicDetails!.weekIndex, 6);
          expect(formatBeijing(course.startsAtUtc), '2026-10-12 08:00');
          expect(formatBeijing(course.endsAtUtc), '2026-10-12 09:50');
          expect(exam.title, '合成考试课程');
          expect(exam.semesterId, isNull);
          expect(exam.presence, JwPresence.observed);
          expect(exam.academicDetails!.locationLabel, '合成考场 · 合成教学楼 · 合成校区');
          expect(exam.academicDetails!.examNote, '合成考试说明');
          expect(exam.academicDetails!.teachers, isEmpty);
          expect(exam.academicDetails!.semesterName, isEmpty);
          expect(formatBeijing(exam.startsAtUtc), '2026-10-15 09:00');
          expect(formatBeijing(exam.endsAtUtc), '2026-10-15 11:00');

          await first.coordinator.setHidden(
            localId: course.localId,
            expectedVersion: course.version,
            hidden: true,
          );
          final hiddenCourse = _eventById(
            _data(first.coordinator.syncView),
            course.localId,
          );
          expect(hiddenCourse.hidden, isTrue);
          expect(hiddenCourse.version, course.version + 1);
          expect(_data(first.coordinator.syncView).auditCount, 2);

          final initialPermit =
              (await first.store.readCommittedPermits()).single;
          final initialProfilePath = await first.registry.openClaimed(
            initialPermit,
            ownerId: initialPermit.partition.ownerId,
            resetEpoch: initialPermit.partition.resetEpoch,
          );
          await _openReady(
            first,
            fixture,
            expectedProfileReused: true,
            expectedPersistentMarker: true,
            expectedSessionMarker: false,
          );
          expect(first.coordinator.syncView.accountBound, isTrue);
          final reusedPermit =
              (await first.store.readCommittedPermits()).single;
          expect(
            reusedPermit.partition.sameAs(initialPermit.partition),
            isTrue,
          );
          expect(
            await first.registry.openClaimed(
              reusedPermit,
              ownerId: reusedPermit.partition.ownerId,
              resetEpoch: reusedPermit.partition.resetEpoch,
            ),
            initialProfilePath,
          );
          await _verifyDirectory(first);
          fixture.courseRoom = '合成教室 5401';
          fixture.courseTeacher = '合成教师乙';
          await first.coordinator
              .collect(20261)
              .timeout(const Duration(seconds: 75));
          var data = _data(first.coordinator.syncView);
          expect(data.events, hasLength(2));
          expect(data.importCount, 2);
          expect(data.auditCount, 3);
          expect(_eventById(data, course.localId).hidden, isTrue);
          expect(
            _eventById(data, course.localId).academicDetails!.room,
            '合成教室 5401',
          );
          expect(_eventById(data, course.localId).academicDetails!.teachers, [
            '合成教师乙',
          ]);

          fixture
            ..emptyCourse = true
            ..emptyExams = true;
          await _openReady(
            first,
            fixture,
            expectedProfileReused: true,
            expectedPersistentMarker: true,
            expectedSessionMarker: false,
          );
          await _verifyDirectory(first);
          await first.coordinator
              .collect(20261)
              .timeout(const Duration(seconds: 75));
          final emptyView = first.coordinator.syncView;
          expect(emptyView.phase, JwSyncPhase.idle);
          expect(emptyView.importCommitted, isTrue);
          expect(emptyView.emptyExams, isTrue);
          expect(emptyView.courseCount, 0);
          expect(emptyView.examCount, 0);
          data = _data(emptyView);
          expect(data.events, hasLength(2));
          expect(
            _eventById(data, course.localId).presence,
            JwPresence.missingWithinScope,
          );
          expect(_eventById(data, course.localId).hidden, isTrue);
          expect(
            _eventById(data, exam.localId).presence,
            JwPresence.outsideScope,
          );
          expect(data.importCount, 3);

          fixture
            ..emptyCourse = false
            ..emptyExams = false;
          await _openReady(
            first,
            fixture,
            expectedProfileReused: true,
            expectedPersistentMarker: true,
            expectedSessionMarker: false,
          );
          await _verifyDirectory(first);
          await first.coordinator
              .collect(20262)
              .timeout(const Duration(seconds: 75));
          data = _data(first.coordinator.syncView);
          expect(first.coordinator.syncView.importCommitted, isTrue);
          expect(data.events, hasLength(3));
          expect(data.courseCount, 2);
          expect(data.examCount, 1);
          expect(data.importCount, 4);
          expect(data.auditCount, 5);
          expect(
            _eventById(data, course.localId).presence,
            JwPresence.outsideScope,
          );
          expect(_eventById(data, course.localId).hidden, isTrue);
          expect(_eventById(data, exam.localId).presence, JwPresence.observed);
          expect(fixture.acceptedIndexSemesters, [20261, 20261, 20261, 20262]);

          // Rebuilds this test harness in the same host process; this is not
          // evidence of an application-process restart.
          await first.dispose();
          final reopened = await _Harness.create(
            p.windows.join(root.path, 'owned'),
            fixture,
          );
          harnesses.add(reopened);
          final persisted = _data(reopened.coordinator.syncView);
          expect(reopened.coordinator.syncView.phase, JwSyncPhase.idle);
          expect(reopened.coordinator.syncView.accountBound, isTrue);
          expect(reopened.coordinator.syncView.sessionRetained, isTrue);
          expect(reopened.coordinator.syncView.profileRetained, isTrue);
          expect(persisted.events, hasLength(3));
          expect(persisted.importCount, 4);
          expect(_eventById(persisted, course.localId).hidden, isTrue);
          expect(
            _eventById(persisted, course.localId).academicDetails!.room,
            '合成教室 5401',
          );
          expect(
            _eventById(persisted, course.localId).academicDetails!.teachers,
            ['合成教师乙'],
          );
          expect(
            _eventById(persisted, course.localId).presence,
            JwPresence.outsideScope,
          );

          await _openReady(
            reopened,
            fixture,
            expectedProfileReused: true,
            expectedPersistentMarker: true,
            expectedSessionMarker: false,
          );
          final permitAfterHarnessRecreation =
              (await reopened.store.readCommittedPermits()).single;
          expect(
            permitAfterHarnessRecreation.partition.sameAs(
              initialPermit.partition,
            ),
            isTrue,
          );
          expect(
            await reopened.registry.openClaimed(
              permitAfterHarnessRecreation,
              ownerId: permitAfterHarnessRecreation.partition.ownerId,
              resetEpoch: permitAfterHarnessRecreation.partition.resetEpoch,
            ),
            initialProfilePath,
          );
          await reopened.coordinator.cancel().timeout(
            const Duration(seconds: 45),
          );
          expect(reopened.coordinator.syncView.phase, JwSyncPhase.idle);
          await reopened.coordinator.clearSession().timeout(
            const Duration(seconds: 45),
          );
          final afterClear = _data(reopened.coordinator.syncView);
          expect(reopened.coordinator.syncView.phase, JwSyncPhase.idle);
          expect(reopened.coordinator.syncView.importCommitted, isFalse);
          expect(reopened.coordinator.syncView.sessionRetained, isFalse);
          expect(afterClear.accountBound, isTrue);
          expect(afterClear.events, hasLength(3));
          expect(afterClear.importCount, 4);
          expect(await reopened.store.readCommittedPermits(), isEmpty);
          expect(await _partitionEntryNames(reopened), isEmpty);

          final issueCountAfterClear = fixture.launcherCookieIssueCount;
          expect(issueCountAfterClear, 1);
          await _openReady(
            reopened,
            fixture,
            expectedProfileReused: false,
            expectedPersistentMarker: false,
            expectedSessionMarker: false,
          );
          expect(fixture.launcherCookieIssueCount, issueCountAfterClear);
          await reopened.coordinator.cancel().timeout(
            const Duration(seconds: 45),
          );
          expect(await _partitionEntryNames(reopened), isEmpty);
        } finally {
          await _cleanup(fixture, root, harnesses);
        }
      });
    },
  );

  testWidgets(
    'canceling initial setup and paused collection releases the lease',
    (tester) async {
      await tester.runAsync(() async {
        final fixture = await JwSyncFixture.start();
        final root = await _createTempRoot();
        final harnesses = <_Harness>[];
        try {
          final harness = await _Harness.create(
            p.windows.join(root.path, 'owned'),
            fixture,
          );
          harnesses.add(harness);

          final opening = harness.coordinator.open(
            expectedAccountCode: 'TEST0001',
          );
          final openingCancellation = harness.coordinator.cancel();
          await Future.wait([
            opening,
            openingCancellation,
          ]).timeout(const Duration(seconds: 45));
          expect(harness.coordinator.syncView.phase, JwSyncPhase.idle);
          expect(harness.coordinator.syncView.accountBound, isFalse);
          expect(harness.leases.isBusy, isFalse);
          expect(await harness.store.readCommittedPermits(), isEmpty);
          expect(_data(harness.coordinator.syncView).events, isEmpty);
          expect(await _partitionEntryNames(harness), isEmpty);

          fixture.pauseIndex = true;
          await _openReady(
            harness,
            fixture,
            expectedAccountCode: 'TEST0001',
            expectedProfileReused: false,
            expectedPersistentMarker: false,
            expectedSessionMarker: false,
          );
          await _verifyDirectory(harness);
          final collection = harness.coordinator.collect(20261);
          await fixture.indexEntered.future.timeout(
            const Duration(seconds: 45),
          );
          expect(harness.leases.isBusy, isTrue);
          final cancellation = harness.coordinator.cancel();
          await fixture.close();
          await Future.wait([
            collection,
            cancellation,
          ]).timeout(const Duration(seconds: 60));

          expect(harness.coordinator.syncView.phase, JwSyncPhase.idle);
          expect(harness.coordinator.syncView.importCommitted, isFalse);
          expect(harness.coordinator.syncView.accountBound, isFalse);
          expect(harness.coordinator.syncView.sessionRetained, isFalse);
          expect(harness.leases.isBusy, isFalse);
          final data = _data(harness.coordinator.syncView);
          expect(data.accountBound, isFalse);
          expect(data.events, isEmpty);
          expect(data.importCount, 0);
          expect(data.auditCount, 0);
          expect(await harness.store.readCommittedPermits(), isEmpty);
          expect(await _partitionEntryNames(harness), isEmpty);
        } finally {
          await _cleanup(fixture, root, harnesses);
        }
      });
    },
  );

  testWidgets(
    'native teacher-only duplicate rows import once and retain names and local identity',
    (tester) async {
      await tester.runAsync(() async {
        final fixture = await JwSyncFixture.start();
        fixture
          ..duplicateSchedule = JwDuplicateScheduleMode.differentTeachers
          ..emptyExams = true;
        final root = await _createTempRoot();
        final harnesses = <_Harness>[];
        try {
          final harness = await _Harness.create(
            p.windows.join(root.path, 'owned'),
            fixture,
          );
          harnesses.add(harness);
          await _openReady(
            harness,
            fixture,
            expectedAccountCode: 'TEST0001',
            expectedProfileReused: false,
            expectedPersistentMarker: false,
            expectedSessionMarker: false,
          );
          await _verifyDirectory(harness);
          await harness.coordinator
              .collect(20261)
              .timeout(const Duration(seconds: 75));

          final first = harness.coordinator.syncView;
          expect(first.phase, JwSyncPhase.idle);
          expect(first.failure, isNull);
          expect(first.collectionValidation, isNull);
          expect(first.importCommitted, isTrue);
          expect(first.accountBound, isTrue);
          expect(first.sessionRetained, isTrue);
          expect(first.courseCount, 1);
          expect(first.examCount, 0);
          expect(first.normalization?.safeProjection, {
            'courseRows': 2,
            'courseEvents': 1,
            'duplicateCourses': 1,
            'examRows': 0,
            'examEvents': 0,
            'duplicateExams': 0,
          });
          expect(harness.leases.isBusy, isFalse);
          final firstData = _data(first);
          expect(firstData.accountBound, isTrue);
          expect(firstData.events, hasLength(1));
          expect(firstData.importCount, 1);
          final original = firstData.events.single;
          expect(original.kind, JwEventKind.course);
          expect(original.academicDetails!.teachers, ['合成教师乙', '合成教师甲']);
          expect(formatBeijing(original.startsAtUtc), '2026-10-12 08:00');
          expect(formatBeijing(original.endsAtUtc), '2026-10-12 09:50');
          final permit = (await harness.store.readCommittedPermits()).single;
          final originalProfilePath = await harness.registry.openClaimed(
            permit,
            ownerId: permit.partition.ownerId,
            resetEpoch: permit.partition.resetEpoch,
          );
          expect(
            originalProfilePath,
            harness.registry.profilePath(permit.partition),
          );
          final summary = jsonDecode(first.safeSummary) as Map<String, dynamic>;
          expect(summary['normalization'], first.normalization!.safeProjection);
          expect(summary['courseCount'], 1);
          expect(summary['localEvents'], 1);
          _expectSafeSummary(first);

          await _openReady(
            harness,
            fixture,
            expectedProfileReused: true,
            expectedPersistentMarker: true,
            expectedSessionMarker: false,
          );
          expect(harness.coordinator.syncView.normalization, isNull);
          final repeatedPermit =
              (await harness.store.readCommittedPermits()).single;
          expect(repeatedPermit.partition.sameAs(permit.partition), isTrue);
          expect(
            await harness.registry.openClaimed(
              repeatedPermit,
              ownerId: repeatedPermit.partition.ownerId,
              resetEpoch: repeatedPermit.partition.resetEpoch,
            ),
            originalProfilePath,
          );
          await _verifyDirectory(harness);
          await harness.coordinator
              .collect(20261)
              .timeout(const Duration(seconds: 75));
          final repeated = harness.coordinator.syncView;
          expect(repeated.phase, JwSyncPhase.idle);
          expect(repeated.importCommitted, isTrue);
          expect(repeated.accountBound, isTrue);
          expect(repeated.sessionRetained, isTrue);
          expect(repeated.courseCount, 1);
          expect(
            repeated.normalization?.safeProjection,
            first.normalization!.safeProjection,
          );
          final repeatedData = _data(repeated);
          expect(repeatedData.events, hasLength(1));
          expect(repeatedData.events.single.localId, original.localId);
          expect(repeatedData.events.single.academicDetails!.teachers, [
            '合成教师乙',
            '合成教师甲',
          ]);
          expect(repeatedData.importCount, 2);
          expect(await harness.store.readCommittedPermits(), hasLength(1));
          expect(fixture.acceptedIndexSemesters, [20261, 20261]);
          expect(fixture.acceptedDatumLessonIds, [
            const [11],
            const [11],
          ]);
          expect(fixture.rejectedRequestCount, 0);
          _expectSafeSummary(repeated);

          await harness.coordinator.clearSession().timeout(
            const Duration(seconds: 45),
          );
          final cleared = harness.coordinator.syncView;
          expect(cleared.phase, JwSyncPhase.idle);
          expect(cleared.normalization, isNull);
          expect(
            jsonDecode(cleared.safeSummary),
            isNot(contains('normalization')),
          );
          expect(cleared.sessionRetained, isFalse);
          expect(_data(cleared).events.single.localId, original.localId);
          expect(_data(cleared).importCount, 2);
          expect(await harness.store.readCommittedPermits(), isEmpty);
          expect(await _partitionEntryNames(harness), isEmpty);
        } finally {
          await _cleanup(fixture, root, harnesses);
        }
      });
    },
  );

  testWidgets(
    'native conflicting course rows cannot import despite valid source checks',
    (tester) async {
      await tester.runAsync(() async {
        for (final mode in [
          JwDuplicateScheduleMode.differentEnd,
          JwDuplicateScheduleMode.differentRoom,
        ]) {
          final fixture = await JwSyncFixture.start();
          fixture
            ..duplicateSchedule = mode
            ..emptyExams = true;
          final root = await _createTempRoot();
          final harnesses = <_Harness>[];
          try {
            final harness = await _Harness.create(
              p.windows.join(root.path, 'owned'),
              fixture,
            );
            harnesses.add(harness);
            await _openReady(
              harness,
              fixture,
              expectedAccountCode: 'TEST0001',
              expectedProfileReused: false,
              expectedPersistentMarker: false,
              expectedSessionMarker: false,
            );
            await _verifyDirectory(harness);
            await harness.coordinator
                .collect(20261)
                .timeout(const Duration(seconds: 75));

            final view = harness.coordinator.syncView;
            final validation = view.collectionValidation;
            expect(validation, isNotNull);
            expect(
              validation!.reason,
              JwCollectionRejectionReason.duplicateCourseKey,
            );
            final identical = mode == JwDuplicateScheduleMode.identical;
            expect(validation.duplicateIdentical, identical);
            final diagnostics = validation.diagnostics;
            expect(diagnostics, isNotNull);
            expect(diagnostics!.checks, {
              'identityBefore': 'ok',
              'course': 'ok',
              'index': 'ok',
              'datum': 'ok',
              'exams': 'ok',
              'identityAfter': 'ok',
            });
            expect(diagnostics.reason, 'none');
            expect(diagnostics.selfRouteBound, isTrue);
            expect(diagnostics.identityStable, isTrue);
            expect(diagnostics.semesterAccepted, isTrue);
            expect(diagnostics.identityReads, 2);
            expect(diagnostics.lessonIds, 1);
            expect(diagnostics.lessons, 1);
            expect(diagnostics.groups, 1);
            expect(diagnostics.schedules, 2);
            expect(diagnostics.datedSchedules, 2);
            expect(diagnostics.timedSchedules, 2);
            expect(diagnostics.linkedSchedules, 2);
            expect(diagnostics.examRows, 0);
            expect(diagnostics.datedExams, 0);
            expect(diagnostics.emptyCourse, isFalse);
            expect(diagnostics.emptyExams, isTrue);
            expect(diagnostics.pagination, isFalse);

            expect(view.phase, JwSyncPhase.idle);
            expect(view.failureStage, JwSyncPhase.collecting);
            expect(view.failure, FailureCode.invalidSnapshot);
            expect(view.normalization, isNull);
            expect(view.sourceFailure, isNull);
            expect(view.identityFailure, isNull);
            expect(view.importCommitted, isFalse);
            expect(view.accountBound, isFalse);
            expect(view.sessionRetained, isFalse);
            expect(view.courseCount, 0);
            expect(view.examCount, 0);
            expect(harness.leases.isBusy, isFalse);
            final data = _data(view);
            expect(data.accountBound, isFalse);
            expect(data.events, isEmpty);
            expect(data.importCount, 0);
            expect(data.auditCount, 0);
            expect(await harness.store.readCommittedPermits(), isEmpty);
            expect(await _partitionEntryNames(harness), isEmpty);
            expect(fixture.acceptedIndexSemesters, [20261]);
            expect(fixture.acceptedDatumLessonIds, [
              const [11],
            ]);
            expect(fixture.rejectedRequestCount, 0);

            final summary =
                jsonDecode(view.safeSummary) as Map<String, dynamic>;
            expect(summary.keys.toSet(), {
              'kind',
              'phase',
              'accountBound',
              'sessionRetained',
              'profileRetained',
              'profileReused',
              'importCommitted',
              'courseCount',
              'examCount',
              'emptyExams',
              'failure',
              'failureStage',
              'collectionValidation',
              'localEvents',
              'imports',
              'credentialSaved',
              'semesterRemembered',
              'cachedSemesterCount',
              'automation',
            });
            expect(summary['kind'], 'jw-import-v1');
            expect(summary['phase'], 'idle');
            expect(summary['failure'], 'invalidSnapshot');
            expect(summary['failureStage'], 'collecting');
            expect(summary['profileRetained'], isFalse);
            expect(summary['profileReused'], isFalse);
            expect(summary['localEvents'], 0);
            expect(summary['imports'], 0);
            expect(summary['cachedSemesterCount'], 0);
            final rejection =
                summary['collectionValidation'] as Map<String, dynamic>;
            expect(rejection.keys.toSet(), {
              'reason',
              'dataChecks',
              'duplicateIdentical',
            });
            expect(rejection['reason'], 'duplicateCourseKey');
            expect(rejection['duplicateIdentical'], identical);
            expect(rejection['dataChecks'], diagnostics.safeProjection);
            _expectSafeSummary(view);
          } finally {
            await _cleanup(fixture, root, harnesses);
          }
        }
      });
    },
  );

  testWidgets('malformed academic fields cannot import or retain a profile', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final fixture = await JwSyncFixture.start();
      fixture.malformedAcademicDetails = true;
      final root = await _createTempRoot();
      final harnesses = <_Harness>[];
      try {
        final harness = await _Harness.create(
          p.windows.join(root.path, 'owned'),
          fixture,
        );
        harnesses.add(harness);
        await _openReady(
          harness,
          fixture,
          expectedAccountCode: 'TEST0001',
          expectedProfileReused: false,
          expectedPersistentMarker: false,
          expectedSessionMarker: false,
        );
        await _verifyDirectory(harness);
        await harness.coordinator
            .collect(20261)
            .timeout(const Duration(seconds: 75));
        final view = harness.coordinator.syncView;
        expect(view.phase, JwSyncPhase.idle);
        expect(view.importCommitted, isFalse);
        expect(view.sourceFailure, JwDataProbeCode.datumSchema);
        expect(view.accountBound, isFalse);
        expect(view.sessionRetained, isFalse);
        expect(_data(view).events, isEmpty);
        expect(_data(view).importCount, 0);
        expect(await harness.store.readCommittedPermits(), isEmpty);
        expect(await _partitionEntryNames(harness), isEmpty);
        expect(view.safeSummary, isNot(contains('invalid-room-object')));
        _expectSafeSummary(view);
      } finally {
        await _cleanup(fixture, root, harnesses);
      }
    });
  });

  testWidgets(
    'identity changing during collection cannot commit or retain a profile',
    (tester) async {
      await tester.runAsync(() async {
        final fixture = await JwSyncFixture.start();
        fixture.identityChangedAfterIndex = true;
        final root = await _createTempRoot();
        final harnesses = <_Harness>[];
        try {
          final harness = await _Harness.create(
            p.windows.join(root.path, 'owned'),
            fixture,
          );
          harnesses.add(harness);
          await _openReady(
            harness,
            fixture,
            expectedAccountCode: 'TEST0001',
            expectedProfileReused: false,
            expectedPersistentMarker: false,
            expectedSessionMarker: false,
          );
          await _verifyDirectory(harness);
          await harness.coordinator
              .collect(20261)
              .timeout(const Duration(seconds: 75));

          final view = harness.coordinator.syncView;
          final data = _data(view);
          expect(view.phase, JwSyncPhase.idle);
          expect(view.importCommitted, isFalse);
          expect(view.accountBound, isFalse);
          expect(view.sessionRetained, isFalse);
          expect(harness.leases.isBusy, isFalse);
          expect(data.accountBound, isFalse);
          expect(data.events, isEmpty);
          expect(data.importCount, 0);
          expect(data.auditCount, 0);
          expect(await harness.store.readCommittedPermits(), isEmpty);
          expect(await _partitionEntryNames(harness), isEmpty);
        } finally {
          await _cleanup(fixture, root, harnesses);
        }
      });
    },
  );
}

Future<Directory> _createTempRoot() async {
  final root = await Directory.systemTemp.createTemp('ustc_jw_sync_flow_');
  final system = p.windows.normalize(
    p.windows.absolute(Directory.systemTemp.path),
  );
  final child = p.windows.normalize(p.windows.absolute(root.path));
  if (p.windows.equals(system, child) || !p.windows.isWithin(system, child)) {
    await root.delete(recursive: true);
    fail('synthetic data root is outside the system temporary directory');
  }
  return root;
}

Future<BrowserEvent> _openReady(
  _Harness harness,
  JwSyncFixture fixture, {
  String? expectedAccountCode,
  required bool expectedProfileReused,
  required bool expectedPersistentMarker,
  required bool expectedSessionMarker,
}) async {
  final observationOffset = fixture.launcherCookieObservations.length;
  final eventOffset = harness.events.length;
  await harness.coordinator
      .open(expectedAccountCode: expectedAccountCode)
      .timeout(const Duration(seconds: 45));
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsed < const Duration(seconds: 60)) {
    final readyEvents = harness.events
        .skip(eventOffset)
        .where(
          (event) =>
              event.kind == BrowserEventKind.ready &&
              event.origin == fixture.initialUri.origin,
        )
        .toList();
    if (harness.coordinator.syncView.phase == JwSyncPhase.login &&
        harness.coordinator.syncView.ready &&
        readyEvents.isNotEmpty) {
      final view = harness.coordinator.syncView;
      expect(view.profileReused, expectedProfileReused);
      final summary = jsonDecode(view.safeSummary) as Map<String, dynamic>;
      expect(summary.containsKey('profileRetained'), isTrue);
      expect(summary.containsKey('profileReused'), isTrue);
      expect(summary['profileReused'], expectedProfileReused);
      final observations = fixture.launcherCookieObservations;
      expect(observations, hasLength(observationOffset + 1));
      expect(
        observations.last.persistentMarkerPresent,
        expectedPersistentMarker,
      );
      expect(observations.last.sessionMarkerPresent, expectedSessionMarker);
      return readyEvents.last;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('synthetic browser did not reach a ready login page');
}

Future<void> _verifyDirectory(_Harness harness) async {
  await harness.coordinator.verifyDirectory().timeout(
    const Duration(seconds: 60),
  );
  expect(harness.coordinator.syncView.phase, JwSyncPhase.login);
  expect(harness.coordinator.syncView.semesters, hasLength(2));
  expect(harness.coordinator.syncView.ready, isTrue);
}

JwDataView _data(JwSyncView view) {
  final data = view.data;
  if (data == null) fail('local JW projection is unavailable');
  return data;
}

void _expectSafeSummary(JwSyncView view) {
  for (final forbidden in [
    'TEST0001',
    'TEST0002',
    '合成课程',
    '合成考试课程',
    '2026-10-12',
    '2026-10-15',
    '/for-std',
    '127.0.0.1',
    '20261',
    '20262',
    '571',
    'bizTypeId',
    'dataId',
    'scheduleGroupId',
    'courseName',
    '"lessonId":',
    '"groupId":',
    '"semesterId":',
    '"startMinute":',
    '"endMinute":',
  ]) {
    expect(view.safeSummary, isNot(contains(forbidden)));
  }
}

JwStoredEvent _eventById(JwDataView data, int localId) =>
    data.events.singleWhere((event) => event.localId == localId);

Future<List<String>> _partitionEntryNames(_Harness harness) async {
  final root = Directory(
    p.windows.join(harness.owner.path, 'jw_partitions_v1'),
  );
  if (!await root.exists()) return const [];
  final entries = await root.list(followLinks: false).toList();
  final names = entries.map((entry) => p.windows.basename(entry.path)).toList()
    ..sort();
  return names;
}

Future<void> _cleanup(
  JwSyncFixture fixture,
  Directory root,
  List<_Harness> harnesses,
) async {
  await fixture.close();
  for (final harness in harnesses.reversed) {
    try {
      await harness.dispose();
    } on Object {
      // Preserve an undeleted temporary root if the native drain did not end.
    }
  }
  final system = p.windows.normalize(
    p.windows.absolute(Directory.systemTemp.path),
  );
  final child = p.windows.normalize(p.windows.absolute(root.path));
  final safeRoot =
      !p.windows.equals(system, child) && p.windows.isWithin(system, child);
  if (safeRoot && harnesses.every((harness) => harness.disposed)) {
    await root.delete(recursive: true);
  }
}

final class _Harness {
  _Harness._({
    required this.owner,
    required this.store,
    required this.registry,
    required this.browser,
    required this.leases,
    required this.coordinator,
    required this.eventsSubscription,
    required this.events,
  });

  final DemoDirectory owner;
  final JwStore store;
  final JwPartitionRegistry registry;
  final NativeObservationBrowser browser;
  final WorkLeasePool leases;
  final JwSyncCoordinator coordinator;
  final StreamSubscription<BrowserEvent> eventsSubscription;
  final List<BrowserEvent> events;
  bool disposed = false;

  static Future<_Harness> create(
    String ownedPath,
    JwSyncFixture fixture,
  ) async {
    final owner = await DemoDirectory.acquire(ownedPath);
    JwStore? store;
    NativeObservationBrowser? browser;
    StreamSubscription<BrowserEvent>? eventsSubscription;
    JwSyncCoordinator? coordinator;
    try {
      final clock = FixedClock(DateTime.utc(2026, 10, 10, 0));
      store = JwStore(
        openJwDatabase(owner),
        ownership: owner,
        clock: clock,
        credentialProtector: const WindowsJwCredentialProtector(),
      );
      await store.initialize();
      final registry = JwPartitionRegistry(owner);
      browser = NativeObservationBrowser();
      final events = <BrowserEvent>[];
      eventsSubscription = browser.events.listen(events.add);
      final leases = WorkLeasePool();
      coordinator = JwSyncCoordinator(
        store: store,
        registry: registry,
        browser: browser,
        leases: leases,
        clock: clock,
        target: ObservationTarget.fixture(fixture.initialUri),
      );
      await coordinator.initialize().timeout(const Duration(seconds: 45));
      return _Harness._(
        owner: owner,
        store: store,
        registry: registry,
        browser: browser,
        leases: leases,
        coordinator: coordinator,
        eventsSubscription: eventsSubscription,
        events: events,
      );
    } on Object {
      if (coordinator != null) {
        try {
          await coordinator.shutdown();
        } on Object {
          // A failed initialization must not mask its original failure.
        }
      }
      if (browser != null) await browser.dispose();
      await eventsSubscription?.cancel();
      if (store != null) await store.close();
      await owner.release();
      rethrow;
    }
  }

  Future<void> dispose() async {
    if (disposed) return;
    await coordinator.shutdown();
    await browser.dispose();
    await eventsSubscription.cancel();
    await store.close();
    await owner.release();
    disposed = true;
  }
}
