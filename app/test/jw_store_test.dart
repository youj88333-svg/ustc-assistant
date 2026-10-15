import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/jw_academic_details.dart';
import 'package:ustc_assistant_m0/core/jw_credentials.dart';
import 'package:ustc_assistant_m0/core/jw_work_contract.dart';
import 'package:ustc_assistant_m0/data/jw_import_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/source/jw_collection_contract.dart';
import 'package:ustc_assistant_m0/source/jw_probe_contract.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'support/calendar_legacy_schema.dart';

void main() {
  test(
    'first binding and import roll back together, then commit a permit',
    () async {
      var failOnce = true;
      final store = await _openStore(
        onCheckpoint: (checkpoint) async {
          if (checkpoint == JwImportCheckpoint.afterFirstWrite && failOnce) {
            failOnce = false;
            throw const AppFailure(FailureCode.storageFailed);
          }
        },
      );
      final ticket = await store.beginJob(expectedAccountCode: ' ab12345 ');
      expect(ticket.expectedAccountCode, 'AB12345');
      final partition = _partition(ticket);
      await _stagePartitionAndDefaultCatalog(store, ticket, partition);

      await _expectAppFailure(
        store.importSnapshot(ticket, _artifact(ticket, partition)),
        FailureCode.storageFailed,
      );
      final rolledBack = await store.readView();
      expect(rolledBack.accountBound, isFalse);
      expect(rolledBack.events, isEmpty);
      expect(rolledBack.importCount, 0);
      expect(rolledBack.auditCount, 0);
      expect(await store.readCommittedPermits(), isEmpty);

      final receipt = await store.importSnapshot(
        ticket,
        _artifact(ticket, partition),
      );
      final committed = await store.readView();
      expect(receipt.replayed, isFalse);
      expect(receipt.permit.accountId, 1);
      expect(committed.accountBound, isTrue);
      expect(committed.courseCount, 1);
      expect(committed.examCount, 1);
      expect(
        committed.events
            .singleWhere((event) => event.kind == JwEventKind.course)
            .semesterId,
        202610,
      );
      expect(
        committed.events
            .singleWhere((event) => event.kind == JwEventKind.exam)
            .semesterId,
        isNull,
      );
      expect(committed.importCount, 1);
      expect(committed.auditCount, 1);
      final permits = await store.readCommittedPermits();
      expect(permits, hasLength(1));
      expect(permits.single.partition.sameAs(receipt.permit.partition), isTrue);
      expect(permits.single.accountId, 1);
    },
  );

  test(
    'unverified first login and a later explicit identity mismatch stop before work',
    () async {
      final store = await _openStore();
      await expectLater(
        store.beginJob(),
        throwsA(
          isA<JwIdentityException>().having(
            (error) => error.code,
            'identity failure',
            JwIdentityFailure.identityUnverified,
          ),
        ),
      );

      final ticket = await store.beginJob(expectedAccountCode: 'AB12345');
      final partition = _partition(ticket);
      await _stagePartitionAndDefaultCatalog(store, ticket, partition);
      await expectLater(
        store.importSnapshot(
          ticket,
          _artifact(ticket, partition, accountCode: 'CD67890'),
        ),
        throwsA(
          isA<JwIdentityException>().having(
            (error) => error.code,
            'identity failure',
            JwIdentityFailure.accountMismatch,
          ),
        ),
      );
      expect((await store.readView()).accountBound, isFalse);
      expect((await store.readView()).events, isEmpty);
      expect(await store.readCommittedPermits(), isEmpty);

      await store.importSnapshot(ticket, _artifact(ticket, partition));
      final beforeWrongIdentity = await store.readView();
      final originalPermit = (await store.readCommittedPermits()).single;
      final nextTicket = await store.beginJob();
      final nextPartition = _partition(nextTicket);
      await _stagePartitionAndDefaultCatalog(store, nextTicket, nextPartition);
      await expectLater(
        store.importSnapshot(
          nextTicket,
          _artifact(nextTicket, nextPartition, accountCode: 'CD67890'),
        ),
        throwsA(
          isA<JwIdentityException>().having(
            (error) => error.code,
            'identity failure',
            JwIdentityFailure.accountMismatch,
          ),
        ),
      );
      final afterWrongIdentity = await store.readView();
      expect(
        afterWrongIdentity.events.map((event) => event.localId),
        beforeWrongIdentity.events.map((event) => event.localId),
      );
      expect(
        afterWrongIdentity.events.map((event) => event.version),
        beforeWrongIdentity.events.map((event) => event.version),
      );
      expect(afterWrongIdentity.importCount, beforeWrongIdentity.importCount);
      expect(afterWrongIdentity.auditCount, beforeWrongIdentity.auditCount);
      expect(
        (await store.readCommittedPermits()).single.partition.sameAs(
          originalPermit.partition,
        ),
        isTrue,
      );
      await store.importSnapshot(
        nextTicket,
        _artifact(nextTicket, nextPartition),
      );

      final beforeMismatch = await store.readAuthority();
      await expectLater(
        store.beginJob(expectedAccountCode: 'zz99999'),
        throwsA(
          isA<JwIdentityException>().having(
            (error) => error.code,
            'identity failure',
            JwIdentityFailure.identityMismatch,
          ),
        ),
      );
      final afterMismatch = await store.readAuthority();
      expect(afterMismatch.ownerId, beforeMismatch.ownerId);
      expect(afterMismatch.generation, beforeMismatch.generation);
      expect(afterMismatch.resetEpoch, beforeMismatch.resetEpoch);
      expect(afterMismatch.accountBound, beforeMismatch.accountBound);
    },
  );

  test(
    'same operation replays only identical content and the same partition',
    () async {
      final store = await _openStore();
      final ticket = await store.beginJob(expectedAccountCode: 'AB12345');
      final partition = _partition(ticket);
      await _stagePartitionAndDefaultCatalog(store, ticket, partition);
      final artifact = _artifact(ticket, partition);
      final first = await store.importSnapshot(ticket, artifact);
      final replay = await store.importSnapshot(ticket, artifact);
      expect(replay.replayed, isTrue);
      expect(replay.operationId, first.operationId);
      expect(replay.permit.partition.sameAs(first.permit.partition), isTrue);

      await expectLater(
        store.importSnapshot(
          ticket,
          _artifact(ticket, partition, courseTitle: '合成课程：改动内容'),
        ),
        throwsA(
          isA<AppFailure>().having(
            (error) => error.code,
            'failure code',
            FailureCode.idempotencyConflict,
          ),
        ),
      );
      final view = await store.readView();
      expect(view.courseCount, 1);
      expect(view.examCount, 1);
      expect(view.importCount, 1);
      expect(view.auditCount, 1);
    },
  );

  test(
    'cancel first rejects import while a commit that wins makes cancel return false',
    () async {
      final cancelledStore = await _openStore();
      final cancelledTicket = await cancelledStore.beginJob(
        expectedAccountCode: 'AB12345',
      );
      final cancelledPartition = _partition(cancelledTicket);
      await _stagePartitionAndDefaultCatalog(
        cancelledStore,
        cancelledTicket,
        cancelledPartition,
      );
      expect(await cancelledStore.cancelJob(cancelledTicket), isTrue);
      await _expectAppFailure(
        cancelledStore.importSnapshot(
          cancelledTicket,
          _artifact(cancelledTicket, cancelledPartition),
        ),
        FailureCode.cancelled,
      );
      expect((await cancelledStore.readView()).events, isEmpty);

      final reachedCommit = Completer<void>();
      final allowCommit = Completer<void>();
      final committingStore = await _openStore(
        onCheckpoint: (checkpoint) async {
          if (checkpoint == JwImportCheckpoint.beforeCommit) {
            reachedCommit.complete();
            await allowCommit.future;
          }
        },
      );
      final ticket = await committingStore.beginJob(
        expectedAccountCode: 'AB12345',
      );
      final partition = _partition(ticket);
      await _stagePartitionAndDefaultCatalog(
        committingStore,
        ticket,
        partition,
      );
      final import = committingStore.importSnapshot(
        ticket,
        _artifact(ticket, partition),
      );
      try {
        await reachedCommit.future.timeout(const Duration(seconds: 5));
        final cancellation = committingStore.cancelJob(ticket);
        allowCommit.complete();
        expect((await import).replayed, isFalse);
        expect(await cancellation, isFalse);
        expect((await committingStore.readView()).importCount, 1);
      } finally {
        if (!allowCommit.isCompleted) allowCommit.complete();
      }
    },
  );

  test(
    'reuses the exact claimed partition and keeps overlay state across imports',
    () async {
      final store = await _openStore();
      final firstTicket = await store.beginJob(expectedAccountCode: 'AB12345');
      final claimed = _partition(firstTicket);
      await _stagePartitionAndDefaultCatalog(store, firstTicket, claimed);
      await store.importSnapshot(firstTicket, _artifact(firstTicket, claimed));

      final before = await store.readView();
      final course = before.events.singleWhere(
        (event) => event.kind == JwEventKind.course,
      );
      final authority = await store.readAuthority();
      final hiddenReceipt = await store.setHidden(
        _hiddenCommand(
          authority,
          localId: course.localId,
          expectedVersion: course.version,
          hidden: true,
        ),
      );
      expect(hiddenReceipt.resultVersion, course.version + 1);
      final hidden = (await store.readView()).events.singleWhere(
        (event) => event.localId == course.localId,
      );

      final nextTicket = await store.beginJob();
      await _stagePartitionAndDefaultCatalog(store, nextTicket, claimed);
      await store.importSnapshot(nextTicket, _artifact(nextTicket, claimed));
      final after = await store.readView();
      final repeatedCourse = after.events.singleWhere(
        (event) => event.localId == course.localId,
      );
      expect(repeatedCourse.hidden, isTrue);
      expect(repeatedCourse.version, hidden.version);
      expect(repeatedCourse.presence, JwPresence.observed);
      expect(after.events, hasLength(2));
      expect(await store.readCommittedPermits(), hasLength(1));
      expect(
        (await store.readCommittedPermits()).single.partition.attempt,
        firstTicket.stamp.jobId,
      );
    },
  );

  test(
    'hidden command receipts replay original intent without reverting later writes',
    () async {
      final store = await _openStore();
      final ticket = await store.beginJob(expectedAccountCode: 'AB12345');
      final partition = _partition(ticket);
      await _stagePartitionAndDefaultCatalog(store, ticket, partition);
      await store.importSnapshot(ticket, _artifact(ticket, partition));
      final authority = await store.readAuthority();
      final course = (await store.readView()).events.singleWhere(
        (event) => event.kind == JwEventKind.course,
      );

      final hide = _hiddenCommand(
        authority,
        localId: course.localId,
        expectedVersion: course.version,
        hidden: true,
      );
      final first = await store.setHidden(hide);
      expect(first.replayed, isFalse);
      expect(first.hidden, isTrue);
      expect(first.resultVersion, course.version + 1);
      final duplicate = await store.setHidden(hide);
      expect(duplicate.replayed, isTrue);
      expect(duplicate.resultVersion, first.resultVersion);
      expect((await store.readView()).auditCount, 2);

      final unhide = _hiddenCommand(
        authority,
        localId: course.localId,
        expectedVersion: first.resultVersion,
        hidden: false,
      );
      final reverse = await store.setHidden(unhide);
      expect(reverse.hidden, isFalse);
      expect(reverse.resultVersion, first.resultVersion + 1);
      final oldReplay = await store.setHidden(hide);
      expect(oldReplay.replayed, isTrue);
      expect(oldReplay.resultVersion, first.resultVersion);
      final current = (await store.readView()).events.singleWhere(
        (event) => event.localId == course.localId,
      );
      expect(current.hidden, isFalse);
      expect(current.version, reverse.resultVersion);
      expect((await store.readView()).auditCount, 3);

      await _expectAppFailure(
        store.setHidden(
          _hiddenCommand(
            authority,
            operationId: hide.operationId,
            localId: course.localId,
            expectedVersion: reverse.resultVersion,
            hidden: false,
          ),
        ),
        FailureCode.idempotencyConflict,
      );
      final noOp = _hiddenCommand(
        authority,
        localId: course.localId,
        expectedVersion: reverse.resultVersion,
        hidden: false,
      );
      final noOpReceipt = await store.setHidden(noOp);
      expect(noOpReceipt.replayed, isFalse);
      expect(noOpReceipt.resultVersion, reverse.resultVersion);
      expect(noOpReceipt.hidden, isFalse);
      expect((await store.readView()).auditCount, 4);
      expect((await store.setHidden(noOp)).replayed, isTrue);
      expect((await store.readView()).auditCount, 4);
    },
  );

  test(
    'hidden commands reject stale or unbound authority before writes',
    () async {
      final store = await _openStore();
      var authority = await store.readAuthority();
      await expectLater(
        store.setHidden(
          _hiddenCommand(
            authority,
            localId: 1,
            expectedVersion: 1,
            hidden: true,
          ),
        ),
        throwsA(
          isA<JwIdentityException>().having(
            (error) => error.code,
            'identity failure',
            JwIdentityFailure.identityUnverified,
          ),
        ),
      );

      final ticket = await store.beginJob(expectedAccountCode: 'AB12345');
      final partition = _partition(ticket);
      await _stagePartitionAndDefaultCatalog(store, ticket, partition);
      await store.importSnapshot(ticket, _artifact(ticket, partition));
      authority = await store.readAuthority();
      final course = (await store.readView()).events.singleWhere(
        (event) => event.kind == JwEventKind.course,
      );
      await _expectAppFailure(
        store.setHidden(
          _hiddenCommand(
            authority,
            operationId: 'jw-local-invalid',
            localId: course.localId,
            expectedVersion: course.version,
            hidden: true,
          ),
        ),
        FailureCode.invalidSnapshot,
      );
      await _expectAppFailure(
        store.setHidden(
          _hiddenCommand(
            authority,
            ownerId: 'malformed',
            localId: course.localId,
            expectedVersion: course.version,
            hidden: true,
          ),
        ),
        FailureCode.invalidSnapshot,
      );
      final otherOwner = authority.ownerId.endsWith('0')
          ? '${authority.ownerId.substring(0, authority.ownerId.length - 1)}1'
          : '${authority.ownerId.substring(0, authority.ownerId.length - 1)}0';
      await _expectAppFailure(
        store.setHidden(
          _hiddenCommand(
            authority,
            ownerId: otherOwner,
            localId: course.localId,
            expectedVersion: course.version,
            hidden: true,
          ),
        ),
        FailureCode.ownershipLost,
      );
      await _expectAppFailure(
        store.setHidden(
          _hiddenCommand(
            authority,
            accountId: 2,
            localId: course.localId,
            expectedVersion: course.version,
            hidden: true,
          ),
        ),
        FailureCode.invalidSnapshot,
      );
      await _expectAppFailure(
        store.setHidden(
          _hiddenCommand(
            authority,
            resetEpoch: authority.resetEpoch + 1,
            localId: course.localId,
            expectedVersion: course.version,
            hidden: true,
          ),
        ),
        FailureCode.staleResult,
      );
      await _expectAppFailure(
        store.setHidden(
          _hiddenCommand(
            authority,
            localId: course.localId,
            expectedVersion: course.version + 1,
            hidden: true,
          ),
        ),
        FailureCode.staleResult,
      );
      final unchanged = (await store.readView()).events.singleWhere(
        (event) => event.localId == course.localId,
      );
      expect(unchanged.hidden, isFalse);
      expect(unchanged.version, course.version);
      expect((await store.readView()).auditCount, 1);
    },
  );

  test(
    'hidden overlay and audit roll back when durable receipt write fails',
    () async {
      final store = await _openStore();
      final ticket = await store.beginJob(expectedAccountCode: 'AB12345');
      final partition = _partition(ticket);
      await _stagePartitionAndDefaultCatalog(store, ticket, partition);
      await store.importSnapshot(ticket, _artifact(ticket, partition));
      final authority = await store.readAuthority();
      final course = (await store.readView()).events.singleWhere(
        (event) => event.kind == JwEventKind.course,
      );
      final command = _hiddenCommand(
        authority,
        localId: course.localId,
        expectedVersion: course.version,
        hidden: true,
      );

      await store.customStatement('''
      CREATE TRIGGER reject_jw_local_receipt
      BEFORE INSERT ON jw_local_receipts
      BEGIN SELECT RAISE(ABORT, 'synthetic receipt failure'); END
    ''');
      await _expectAppFailure(
        store.setHidden(command),
        FailureCode.storageFailed,
      );
      var afterFailure = await store.readView();
      var unchanged = afterFailure.events.singleWhere(
        (event) => event.localId == course.localId,
      );
      expect(unchanged.hidden, isFalse);
      expect(unchanged.version, course.version);
      expect(afterFailure.auditCount, 1);

      await store.customStatement('DROP TRIGGER reject_jw_local_receipt');
      final receipt = await store.setHidden(command);
      expect(receipt.replayed, isFalse);
      expect(receipt.resultVersion, course.version + 1);
      afterFailure = await store.readView();
      unchanged = afterFailure.events.singleWhere(
        (event) => event.localId == course.localId,
      );
      expect(unchanged.hidden, isTrue);
      expect(unchanged.version, course.version + 1);
      expect(afterFailure.auditCount, 2);
    },
  );

  test(
    'semester completeness updates presence while empty exams preserve prior rows',
    () async {
      final store = await _openStore();
      final firstTicket = await store.beginJob(expectedAccountCode: 'AB12345');
      final firstPartition = _partition(firstTicket);
      await _stagePartitionAndDefaultCatalog(
        store,
        firstTicket,
        firstPartition,
      );
      await store.importSnapshot(
        firstTicket,
        _artifact(firstTicket, firstPartition, semesterId: 202610),
      );
      final firstView = await store.readView();
      final firstCourse = firstView.events.singleWhere(
        (event) => event.kind == JwEventKind.course,
      );
      final exam = firstView.events.singleWhere(
        (event) => event.kind == JwEventKind.exam,
      );
      expect(firstCourse.semesterId, 202610);
      expect(exam.semesterId, isNull);
      await store.setHidden(
        _hiddenCommand(
          await store.readAuthority(),
          localId: exam.localId,
          expectedVersion: exam.version,
          hidden: true,
        ),
      );

      final secondTicket = await store.beginJob();
      final secondPartition = _partition(secondTicket);
      await _stagePartitionAndDefaultCatalog(
        store,
        secondTicket,
        secondPartition,
      );
      await store.importSnapshot(
        secondTicket,
        _artifact(
          secondTicket,
          secondPartition,
          semesterId: 202620,
          courses: [_course(202, 20261020, '合成课程：第二学期')],
          exams: const [],
        ),
      );
      final secondView = await store.readView();
      final oldCourse = secondView.events.singleWhere(
        (event) => event.localId == firstCourse.localId,
      );
      final keptExam = secondView.events.singleWhere(
        (event) => event.localId == exam.localId,
      );
      expect(oldCourse.presence, JwPresence.outsideScope);
      expect(oldCourse.semesterId, 202610);
      expect(
        secondView.events
            .singleWhere(
              (event) =>
                  event.kind == JwEventKind.course &&
                  event.localId != firstCourse.localId,
            )
            .semesterId,
        202620,
      );
      expect(keptExam.presence, JwPresence.outsideScope);
      expect(keptExam.semesterId, isNull);
      expect(keptExam.hidden, isTrue);
      expect(secondView.courseCount, 2);
      expect(secondView.examCount, 1);

      final thirdTicket = await store.beginJob();
      final thirdPartition = _partition(thirdTicket);
      await _stagePartitionAndDefaultCatalog(
        store,
        thirdTicket,
        thirdPartition,
      );
      await store.importSnapshot(
        thirdTicket,
        _artifact(
          thirdTicket,
          thirdPartition,
          semesterId: 202610,
          courses: const [],
          exams: const [],
        ),
      );
      final finalEvents = (await store.readView()).events;
      expect(
        finalEvents
            .singleWhere((event) => event.localId == firstCourse.localId)
            .presence,
        JwPresence.missingWithinScope,
      );
      expect(
        finalEvents
            .singleWhere((event) => event.kind == JwEventKind.exam)
            .hidden,
        isTrue,
      );
      expect(finalEvents, hasLength(3));
      expect(
        finalEvents
            .where((event) => event.kind == JwEventKind.course)
            .map((event) => event.semesterId),
        unorderedEquals([202610, 202620]),
      );
    },
  );

  test('local course membership rejects corrupt stored semester IDs', () async {
    final store = await _openStore();
    final ticket = await store.beginJob(expectedAccountCode: 'AB12345');
    final partition = _partition(ticket);
    await _stagePartitionAndDefaultCatalog(store, ticket, partition);
    await store.importSnapshot(ticket, _artifact(ticket, partition));
    for (final invalidId in [0, -1, 2147483648]) {
      await store.customStatement(
        "UPDATE jw_events SET semester_id = ? WHERE kind = 'course'",
        [invalidId],
      );
      await _expectAppFailure(store.readView(), FailureCode.storageFailed);
    }
    await store.customStatement(
      "UPDATE jw_events SET semester_id = 202610 WHERE kind = 'course'",
    );
    final view = await store.readView();
    expect(view.events, hasLength(2));
    expect(view.importCount, 1);
    expect(
      view.events
          .singleWhere((event) => event.kind == JwEventKind.exam)
          .semesterId,
      isNull,
    );
  });

  test(
    'restart abandons active work, preserves committed data and rejects stale overlay versions',
    () async {
      final directory = await Directory.systemTemp.createTemp('jw-store-test-');
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final file = File('${directory.path}${Platform.pathSeparator}jw.sqlite');
      final owner = _SwitchableOwnership();
      final firstStore = JwStore(
        NativeDatabase(file, logStatements: false),
        ownership: owner,
        clock: FixedClock(DateTime.utc(2026, 10, 10, 12)),
      );
      await firstStore.initialize();
      final boundTicket = await firstStore.beginJob(
        expectedAccountCode: 'AB12345',
      );
      final partition = _partition(boundTicket);
      await _stagePartitionAndDefaultCatalog(
        firstStore,
        boundTicket,
        partition,
      );
      await firstStore.importSnapshot(
        boundTicket,
        _artifact(boundTicket, partition),
      );
      var view = await firstStore.readView();
      final course = view.events.singleWhere(
        (event) => event.kind == JwEventKind.course,
      );
      final hiddenCommand = _hiddenCommand(
        await firstStore.readAuthority(),
        localId: course.localId,
        expectedVersion: course.version,
        hidden: true,
      );
      final hiddenReceipt = await firstStore.setHidden(hiddenCommand);
      view = await firstStore.readView();
      final updatedCourse = view.events.singleWhere(
        (event) => event.localId == course.localId,
      );
      final activeTicket = await firstStore.beginJob();
      final abandonedPartition = _partition(activeTicket);
      await _stagePartitionAndDefaultCatalog(
        firstStore,
        activeTicket,
        abandonedPartition,
      );
      final oldAuthority = await firstStore.readAuthority();
      await firstStore.close();

      final restarted = JwStore(
        NativeDatabase(file, logStatements: false),
        ownership: owner,
        clock: FixedClock(DateTime.utc(2026, 10, 10, 13)),
      );
      await restarted.initialize();
      final authority = await restarted.readAuthority();
      final restored = await restarted.readView();
      expect(authority.ownerId, oldAuthority.ownerId);
      expect(authority.generation, greaterThan(oldAuthority.generation));
      expect(authority.accountBound, isTrue);
      expect(await restarted.readCommittedPermits(), hasLength(1));
      final restoredCourse = restored.events.singleWhere(
        (event) => event.localId == course.localId,
      );
      expect(restoredCourse.hidden, isTrue);
      expect(restoredCourse.version, updatedCourse.version);
      final auditCountBeforeReplay = restored.auditCount;
      final replayedHidden = await restarted.setHidden(hiddenCommand);
      expect(replayedHidden.replayed, isTrue);
      expect(replayedHidden.resultVersion, hiddenReceipt.resultVersion);
      expect(replayedHidden.hidden, isTrue);
      expect((await restarted.readView()).auditCount, auditCountBeforeReplay);
      await _expectAppFailure(
        restarted.importSnapshot(
          activeTicket,
          _artifact(activeTicket, abandonedPartition),
        ),
        FailureCode.staleResult,
      );
      await restarted.failJob(activeTicket);
      await _expectAppFailure(
        restarted.setHidden(
          _hiddenCommand(
            authority,
            localId: course.localId,
            expectedVersion: course.version,
            hidden: false,
          ),
        ),
        FailureCode.staleResult,
      );
      owner.held = false;
      await _expectAppFailure(
        restarted.setHidden(
          _hiddenCommand(
            authority,
            localId: course.localId,
            expectedVersion: updatedCourse.version,
            hidden: false,
          ),
        ),
        FailureCode.ownershipLost,
      );
      owner.held = true;
      final pendingRevocation = await restarted.beginJob();
      await restarted.revokePermits();
      await restarted.failJob(pendingRevocation);
      expect(await restarted.readCommittedPermits(), isEmpty);
      final afterRevocation = await restarted.readView();
      expect(afterRevocation.events, hasLength(restored.events.length));
      expect(afterRevocation.importCount, restored.importCount);
      expect(afterRevocation.auditCount, restored.auditCount);
      await restarted.close();
      await directory.delete(recursive: true);
    },
  );

  test(
    'credentials stay temporary until verified import and leases are one use',
    () async {
      final protector = _SyntheticCredentialProtector();
      final store = await _openStore(credentialProtector: protector);
      final ticket = await store.beginJob(expectedAccountCode: 'AB12345');
      final partition = _partition(ticket);
      await _stagePartitionAndDefaultCatalog(store, ticket, partition);

      await store.stageCredentials(ticket, 'synthetic-pass-one', save: true);
      expect(protector.lastProtectInput!.every((byte) => byte == 0), isTrue);
      expect((await store.readView()).credentialSaved, isFalse);
      expect((await store.readView()).lastSemesterId, isNull);
      expect(await _credentialCiphertext(store), isNull);

      final lease = await store.leaseCredentials(ticket);
      expect(lease, isNotNull);
      final bytes = lease!.take();
      try {
        _expectCredentialPayload(
          bytes,
          username: 'AB12345',
          password: 'synthetic-pass-one',
        );
      } finally {
        bytes.fillRange(0, bytes.length, 0);
      }
      expect(
        () => lease.take(),
        throwsA(
          isA<JwCredentialException>().having(
            (error) => error.code,
            'credential failure',
            JwCredentialFailure.invalidCredential,
          ),
        ),
      );
      expect(await store.leaseCredentials(ticket), isNull);

      await store.importSnapshot(
        ticket,
        _artifact(ticket, partition, semesterId: 202620),
      );
      final view = await store.readView();
      expect(view.credentialSaved, isTrue);
      expect(view.lastSemesterId, 202620);
      final ciphertext = (await _credentialCiphertext(store))!;
      expect(_containsBytes(ciphertext, utf8.encode('AB12345')), isFalse);
      expect(
        _containsBytes(ciphertext, utf8.encode('synthetic-pass-one')),
        isFalse,
      );
      expect(await _credentialAuditCount(store, 'saved'), 1);
    },
  );

  test(
    'protect failure leaves the previously committed credential and facts intact',
    () async {
      final protector = _SyntheticCredentialProtector();
      final store = await _openStore(credentialProtector: protector);
      final firstTicket = await store.beginJob(expectedAccountCode: 'AB12345');
      final firstPartition = _partition(firstTicket);
      await _stagePartitionAndDefaultCatalog(
        store,
        firstTicket,
        firstPartition,
      );
      await store.stageCredentials(
        firstTicket,
        'synthetic-old-pass',
        save: true,
      );
      await store.importSnapshot(
        firstTicket,
        _artifact(firstTicket, firstPartition, semesterId: 202610),
      );

      final before = await store.readView();
      final beforeCiphertext = await _credentialCiphertext(store);
      final beforePermits = await store.readCommittedPermits();
      final beforeCredentialAudits = await _credentialAuditCount(store);
      final failedTicket = await store.beginJob();
      protector.failProtect = true;
      await expectLater(
        store.stageCredentials(failedTicket, 'synthetic-new-pass', save: true),
        throwsA(
          isA<JwCredentialException>().having(
            (error) => error.code,
            'credential failure',
            JwCredentialFailure.protectionFailed,
          ),
        ),
      );
      expect(protector.lastProtectInput!.every((byte) => byte == 0), isTrue);

      final after = await store.readView();
      expect(after.accountBound, before.accountBound);
      expect(after.importCount, before.importCount);
      expect(after.auditCount, before.auditCount);
      expect(after.credentialSaved, before.credentialSaved);
      expect(after.lastSemesterId, before.lastSemesterId);
      expect(
        after.events.map(
          (event) => (event.localId, event.version, event.hidden),
        ),
        orderedEquals(
          before.events.map(
            (event) => (event.localId, event.version, event.hidden),
          ),
        ),
      );
      expect(
        _sameBytes(await _credentialCiphertext(store), beforeCiphertext),
        isTrue,
      );
      expect(await _credentialAuditCount(store), beforeCredentialAudits);
      final afterPermits = await store.readCommittedPermits();
      expect(afterPermits, hasLength(beforePermits.length));
      expect(
        afterPermits.single.partition.sameAs(beforePermits.single.partition),
        isTrue,
      );
      await store.failJob(failedTicket);
    },
  );

  test('identity mismatch cannot save staged credentials', () async {
    final protector = _SyntheticCredentialProtector();
    final store = await _openStore(credentialProtector: protector);
    final ticket = await store.beginJob(expectedAccountCode: 'AB12345');
    final partition = _partition(ticket);
    await _stagePartitionAndDefaultCatalog(store, ticket, partition);
    await store.stageCredentials(
      ticket,
      'synthetic-wrong-account-pass',
      save: true,
    );

    await expectLater(
      store.importSnapshot(
        ticket,
        _artifact(ticket, partition, accountCode: 'CD67890'),
      ),
      throwsA(
        isA<JwIdentityException>().having(
          (error) => error.code,
          'identity failure',
          JwIdentityFailure.accountMismatch,
        ),
      ),
    );
    final view = await store.readView();
    expect(view.accountBound, isFalse);
    expect(view.credentialSaved, isFalse);
    expect(view.lastSemesterId, isNull);
    expect(view.importCount, 0);
    expect(await _credentialCiphertext(store), isNull);
    expect(await store.readCommittedPermits(), isEmpty);
    expect(await _credentialAuditCount(store), 0);
    await store.failJob(ticket);
  });

  test(
    'pre-commit failure preserves old credential and semester, then retry commits both',
    () async {
      var failBeforeCommit = false;
      final protector = _SyntheticCredentialProtector();
      final store = await _openStore(
        credentialProtector: protector,
        onCheckpoint: (checkpoint) async {
          if (checkpoint == JwImportCheckpoint.beforeCommit &&
              failBeforeCommit) {
            failBeforeCommit = false;
            throw const AppFailure(FailureCode.storageFailed);
          }
        },
      );
      final firstTicket = await store.beginJob(expectedAccountCode: 'AB12345');
      final firstPartition = _partition(firstTicket);
      await _stagePartitionAndDefaultCatalog(
        store,
        firstTicket,
        firstPartition,
      );
      await store.stageCredentials(
        firstTicket,
        'synthetic-old-pass',
        save: true,
      );
      await store.importSnapshot(
        firstTicket,
        _artifact(firstTicket, firstPartition, semesterId: 202610),
      );
      final oldCiphertext = await _credentialCiphertext(store);

      final retryTicket = await store.beginJob();
      final retryPartition = _partition(retryTicket);
      await _stagePartitionAndDefaultCatalog(
        store,
        retryTicket,
        retryPartition,
      );
      await store.stageCredentials(
        retryTicket,
        'synthetic-new-pass',
        save: true,
      );
      final nextArtifact = _artifact(
        retryTicket,
        retryPartition,
        semesterId: 202620,
      );
      failBeforeCommit = true;
      await _expectAppFailure(
        store.importSnapshot(retryTicket, nextArtifact),
        FailureCode.storageFailed,
      );

      final rolledBack = await store.readView();
      expect(rolledBack.credentialSaved, isTrue);
      expect(rolledBack.lastSemesterId, 202610);
      expect(rolledBack.importCount, 1);
      expect(
        _sameBytes(await _credentialCiphertext(store), oldCiphertext),
        isTrue,
      );

      await store.importSnapshot(retryTicket, nextArtifact);
      final committed = await store.readView();
      expect(committed.credentialSaved, isTrue);
      expect(committed.lastSemesterId, 202620);
      expect(committed.importCount, 2);
      expect(
        _sameBytes(await _credentialCiphertext(store), oldCiphertext),
        isFalse,
      );
      expect(await _credentialAuditCount(store, 'saved'), 2);
    },
  );

  test(
    'save false remains temporary and cancel, fail and revoke clear leases',
    () async {
      final protector = _SyntheticCredentialProtector();
      final store = await _openStore(credentialProtector: protector);
      final savedTicket = await store.beginJob(expectedAccountCode: 'AB12345');
      final savedPartition = _partition(savedTicket);
      await _stagePartitionAndDefaultCatalog(
        store,
        savedTicket,
        savedPartition,
      );
      await store.stageCredentials(
        savedTicket,
        'synthetic-saved-pass',
        save: true,
      );
      await store.importSnapshot(
        savedTicket,
        _artifact(savedTicket, savedPartition, semesterId: 202610),
      );
      final savedCiphertext = await _credentialCiphertext(store);

      final temporaryTicket = await store.beginJob();
      final temporaryPartition = _partition(temporaryTicket);
      await _stagePartitionAndDefaultCatalog(
        store,
        temporaryTicket,
        temporaryPartition,
      );
      await store.stageCredentials(
        temporaryTicket,
        'synthetic-temporary-pass',
        save: false,
      );
      expect(
        _sameBytes(await _credentialCiphertext(store), savedCiphertext),
        isTrue,
      );
      await store.importSnapshot(
        temporaryTicket,
        _artifact(temporaryTicket, temporaryPartition, semesterId: 202620),
      );
      expect(
        _sameBytes(await _credentialCiphertext(store), savedCiphertext),
        isTrue,
      );
      expect((await store.readView()).lastSemesterId, 202620);

      final cancelled = await store.beginJob();
      await store.stageCredentials(
        cancelled,
        'synthetic-cancel-pass',
        save: false,
      );
      final cancelledLease = (await store.leaseCredentials(cancelled))!;
      final cancelledCipher = protector.lastProtectOutput!;
      final cancellation = store.cancelJob(cancelled);
      expect(
        () => cancelledLease.take(),
        throwsA(
          isA<JwCredentialException>().having(
            (error) => error.code,
            'credential failure',
            JwCredentialFailure.invalidCredential,
          ),
        ),
      );
      expect(await cancellation, isTrue);
      expect(cancelledCipher.every((byte) => byte == 0), isTrue);

      final failed = await store.beginJob();
      await store.stageCredentials(failed, 'synthetic-fail-pass', save: false);
      final failedLease = (await store.leaseCredentials(failed))!;
      final failedCipher = protector.lastProtectOutput!;
      await store.failJob(failed);
      expect(() => failedLease.take(), throwsA(isA<JwCredentialException>()));
      expect(failedCipher.every((byte) => byte == 0), isTrue);

      final abandoned = await store.beginJob();
      await store.stageCredentials(
        abandoned,
        'synthetic-abandoned-pass',
        save: false,
      );
      final abandonedLease = (await store.leaseCredentials(abandoned))!;
      final abandonedCipher = protector.lastProtectOutput!;
      final revoked = await store.beginJob();
      expect(
        () => abandonedLease.take(),
        throwsA(isA<JwCredentialException>()),
      );
      expect(abandonedCipher.every((byte) => byte == 0), isTrue);
      await store.stageCredentials(
        revoked,
        'synthetic-revoke-pass',
        save: false,
      );
      final revokedLease = (await store.leaseCredentials(revoked))!;
      final revokedCipher = protector.lastProtectOutput!;
      await store.revokePermits();
      expect(() => revokedLease.take(), throwsA(isA<JwCredentialException>()));
      expect(revokedCipher.every((byte) => byte == 0), isTrue);

      final view = await store.readView();
      expect(view.credentialSaved, isTrue);
      expect(
        _sameBytes(await _credentialCiphertext(store), savedCiphertext),
        isTrue,
      );
      expect(view.lastSemesterId, 202620);
    },
  );

  test(
    'deleting the saved credential preserves events, overlays, imports, permits and semester',
    () async {
      final protector = _SyntheticCredentialProtector();
      final store = await _openStore(credentialProtector: protector);
      final ticket = await store.beginJob(expectedAccountCode: 'AB12345');
      final partition = _partition(ticket);
      await _stagePartitionAndDefaultCatalog(store, ticket, partition);
      await store.stageCredentials(ticket, 'synthetic-delete-pass', save: true);
      await store.importSnapshot(
        ticket,
        _artifact(ticket, partition, semesterId: 202630),
      );
      final viewBefore = await store.readView();
      final course = viewBefore.events.singleWhere(
        (event) => event.kind == JwEventKind.course,
      );
      await store.setHidden(
        _hiddenCommand(
          await store.readAuthority(),
          localId: course.localId,
          expectedVersion: course.version,
          hidden: true,
        ),
      );
      final beforeDelete = await store.readView();
      final active = await store.beginJob();
      await _expectAppFailure(store.deleteSavedCredential(), FailureCode.busy);
      await store.failJob(active);

      await store.deleteSavedCredential();
      final afterDelete = await store.readView();
      expect(afterDelete.credentialSaved, isFalse);
      expect(afterDelete.lastSemesterId, beforeDelete.lastSemesterId);
      expect(
        _semesterOptionsEqual(
          afterDelete.cachedSemesters,
          beforeDelete.cachedSemesters,
        ),
        isTrue,
      );
      expect(
        afterDelete.semesterCatalogUpdatedAtUtc,
        beforeDelete.semesterCatalogUpdatedAtUtc,
      );
      expect(afterDelete.importCount, beforeDelete.importCount);
      expect(afterDelete.auditCount, beforeDelete.auditCount);
      expect(
        afterDelete.events.map(
          (event) => (event.localId, event.version, event.hidden),
        ),
        orderedEquals(
          beforeDelete.events.map(
            (event) => (event.localId, event.version, event.hidden),
          ),
        ),
      );
      expect(await _credentialCiphertext(store), isNull);
      expect(await _credentialAuditCount(store, 'saved'), 1);
      expect(await _credentialAuditCount(store, 'deleted'), 1);
      final permits = await store.readCommittedPermits();
      expect(permits, hasLength(1));
      expect(permits.single.partition.sameAs(partition), isTrue);

      await store.revokePermits();
      final afterSessionClear = await store.readView();
      expect(afterSessionClear.credentialSaved, isFalse);
      expect(
        _semesterOptionsEqual(
          afterSessionClear.cachedSemesters,
          beforeDelete.cachedSemesters,
        ),
        isTrue,
      );
      expect(
        afterSessionClear.semesterCatalogUpdatedAtUtc,
        beforeDelete.semesterCatalogUpdatedAtUtc,
      );
    },
  );

  test(
    'synthetic database reopen restores saved credential and semester',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'jw-credential-reopen-test-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final file = File('${directory.path}${Platform.pathSeparator}jw.sqlite');
      final protector = _SyntheticCredentialProtector();
      final firstStore = await _openPersistentStore(
        file,
        credentialProtector: protector,
      );
      final ticket = await firstStore.beginJob(expectedAccountCode: 'AB12345');
      final partition = _partition(ticket);
      await _stagePartitionAndDefaultCatalog(firstStore, ticket, partition);
      await firstStore.stageCredentials(
        ticket,
        'synthetic-persistent-pass',
        save: true,
      );
      await firstStore.importSnapshot(
        ticket,
        _artifact(ticket, partition, semesterId: 202640),
      );
      final before = await firstStore.readView();
      await firstStore.close();

      final reopened = await _openPersistentStore(
        file,
        credentialProtector: protector,
      );
      final restored = await reopened.readView();
      expect(restored.credentialSaved, isTrue);
      expect(restored.lastSemesterId, 202640);
      expect(restored.importCount, before.importCount);
      expect(
        _semesterOptionsEqual(restored.cachedSemesters, before.cachedSemesters),
        isTrue,
      );
      expect(
        restored.semesterCatalogUpdatedAtUtc,
        before.semesterCatalogUpdatedAtUtc,
      );
      final nextTicket = await reopened.beginJob();
      final lease = (await reopened.leaseCredentials(nextTicket))!;
      final plaintext = lease.take();
      try {
        _expectCredentialPayload(
          plaintext,
          username: 'AB12345',
          password: 'synthetic-persistent-pass',
        );
      } finally {
        plaintext.fillRange(0, plaintext.length, 0);
      }
      await reopened.failJob(nextTicket);
    },
  );

  test(
    'semester directory is temporary until a successful import commits it',
    () async {
      var failOnce = true;
      final clock = _MutableClock(DateTime.utc(2026, 10, 10, 12));
      final store = await _openStore(
        clock: clock,
        onCheckpoint: (checkpoint) async {
          if (checkpoint == JwImportCheckpoint.afterFirstWrite && failOnce) {
            failOnce = false;
            throw const AppFailure(FailureCode.storageFailed);
          }
        },
      );
      final options = [
        _option(731, '2026-2027 秋季学期'),
        _option(942, '2026-2027 春季学期', selected: true),
      ];
      final ticket = await store.beginJob(expectedAccountCode: 'AB12345');
      final partition = _partition(ticket);
      await store.stagePartition(ticket, partition);
      await store.stageSemesterCatalog(ticket, options);

      await _expectAppFailure(
        store.importSnapshot(
          ticket,
          _artifact(ticket, partition, semesterId: 942),
        ),
        FailureCode.storageFailed,
      );
      final beforeCommit = await store.readView();
      expect(beforeCommit.accountBound, isFalse);
      expect(beforeCommit.cachedSemesters, isEmpty);
      expect(beforeCommit.semesterCatalogUpdatedAtUtc, isNull);

      await store.importSnapshot(
        ticket,
        _artifact(ticket, partition, semesterId: 942),
      );
      final committed = await store.readView();
      expect(_semesterOptionsEqual(committed.cachedSemesters, options), isTrue);
      expect(
        committed.semesterCatalogUpdatedAtUtc,
        DateTime.utc(2026, 10, 10, 12),
      );
      expect(committed.lastSemesterId, 942);
    },
  );

  test(
    'catalog update rollback retains the previous directory, semester, credential and events',
    () async {
      var failBeforeCommit = false;
      final clock = _MutableClock(DateTime.utc(2026, 10, 10, 12));
      final protector = _SyntheticCredentialProtector();
      final store = await _openStore(
        clock: clock,
        credentialProtector: protector,
        onCheckpoint: (checkpoint) async {
          if (checkpoint == JwImportCheckpoint.beforeCommit &&
              failBeforeCommit) {
            failBeforeCommit = false;
            throw const AppFailure(FailureCode.storageFailed);
          }
        },
      );
      final oldOptions = [
        _option(551, '2025-2026 秋季学期'),
        _option(552, '2025-2026 春季学期', selected: true),
      ];
      final firstTicket = await store.beginJob(expectedAccountCode: 'AB12345');
      final firstPartition = _partition(firstTicket);
      await store.stagePartition(firstTicket, firstPartition);
      await store.stageSemesterCatalog(firstTicket, oldOptions);
      await store.stageCredentials(
        firstTicket,
        'synthetic-old-directory-pass',
        save: true,
      );
      await store.importSnapshot(
        firstTicket,
        _artifact(firstTicket, firstPartition, semesterId: 552),
      );
      final oldView = await store.readView();
      final oldCiphertext = await _credentialCiphertext(store);
      final oldCredentialAudits = await _credentialAuditCount(store);

      clock.nowUtc = DateTime.utc(2026, 10, 11, 12);
      final nextOptions = [
        _option(661, '2026-2027 秋季学期'),
        _option(662, '2026-2027 春季学期', selected: true),
      ];
      final nextTicket = await store.beginJob();
      final nextPartition = _partition(nextTicket);
      await store.stagePartition(nextTicket, nextPartition);
      await store.stageSemesterCatalog(nextTicket, nextOptions);
      await store.stageCredentials(
        nextTicket,
        'synthetic-new-directory-pass',
        save: true,
      );
      failBeforeCommit = true;
      await _expectAppFailure(
        store.importSnapshot(
          nextTicket,
          _artifact(
            nextTicket,
            nextPartition,
            semesterId: 662,
            courseTitle: '合成课程：事务回滚检查',
          ),
        ),
        FailureCode.storageFailed,
      );

      final afterFailure = await store.readView();
      expect(
        _semesterOptionsEqual(afterFailure.cachedSemesters, oldOptions),
        isTrue,
      );
      expect(
        afterFailure.semesterCatalogUpdatedAtUtc,
        oldView.semesterCatalogUpdatedAtUtc,
      );
      expect(afterFailure.lastSemesterId, oldView.lastSemesterId);
      expect(afterFailure.importCount, oldView.importCount);
      expect(afterFailure.auditCount, oldView.auditCount);
      expect(
        afterFailure.events.map(_eventFact),
        orderedEquals(oldView.events.map(_eventFact)),
      );
      expect(afterFailure.credentialSaved, isTrue);
      expect(
        _sameBytes(await _credentialCiphertext(store), oldCiphertext),
        isTrue,
      );
      expect(await _credentialAuditCount(store), oldCredentialAudits);

      await store.importSnapshot(
        nextTicket,
        _artifact(
          nextTicket,
          nextPartition,
          semesterId: 662,
          courseTitle: '合成课程：事务重试提交',
        ),
      );
      final afterRetry = await store.readView();
      expect(
        _semesterOptionsEqual(afterRetry.cachedSemesters, nextOptions),
        isTrue,
      );
      expect(afterRetry.semesterCatalogUpdatedAtUtc, clock.nowUtc);
      expect(afterRetry.lastSemesterId, 662);
      expect(afterRetry.credentialSaved, isTrue);
      expect(await _credentialAuditCount(store, 'saved'), 2);
    },
  );

  test(
    'cancel, identity mismatch, and an absent snapshot semester leave cached facts alone',
    () async {
      final protector = _SyntheticCredentialProtector();
      final store = await _openStore(credentialProtector: protector);
      final oldOptions = [
        _option(811, '2026-2027 秋季学期'),
        _option(812, '2026-2027 春季学期', selected: true),
      ];
      final firstTicket = await store.beginJob(expectedAccountCode: 'AB12345');
      final firstPartition = _partition(firstTicket);
      await store.stagePartition(firstTicket, firstPartition);
      await store.stageSemesterCatalog(firstTicket, oldOptions);
      await store.stageCredentials(
        firstTicket,
        'synthetic-retained-pass',
        save: true,
      );
      await store.importSnapshot(
        firstTicket,
        _artifact(firstTicket, firstPartition, semesterId: 812),
      );
      final originalView = await store.readView();
      final originalCiphertext = await _credentialCiphertext(store);

      final canceled = await store.beginJob();
      final canceledPartition = _partition(canceled);
      await store.stagePartition(canceled, canceledPartition);
      await store.stageSemesterCatalog(canceled, [
        _option(991, '2030-2031 秋季学期'),
      ]);
      await store.stageCredentials(
        canceled,
        'synthetic-canceled-pass',
        save: true,
      );
      expect(await store.cancelJob(canceled), isTrue);
      await _expectAppFailure(
        store.importSnapshot(
          canceled,
          _artifact(canceled, canceledPartition, semesterId: 991),
        ),
        FailureCode.cancelled,
      );

      final mismatch = await store.beginJob();
      final mismatchPartition = _partition(mismatch);
      await store.stagePartition(mismatch, mismatchPartition);
      await store.stageSemesterCatalog(mismatch, [
        _option(992, '2030-2031 秋季学期'),
      ]);
      await store.stageCredentials(
        mismatch,
        'synthetic-mismatch-pass',
        save: true,
      );
      await expectLater(
        store.importSnapshot(
          mismatch,
          _artifact(mismatch, mismatchPartition, accountCode: 'CD67890'),
        ),
        throwsA(isA<JwIdentityException>()),
      );

      final absent = await store.beginJob();
      final absentPartition = _partition(absent);
      await store.stagePartition(absent, absentPartition);
      await store.stageSemesterCatalog(absent, [
        _option(993, '2030-2031 秋季学期'),
      ]);
      await store.stageCredentials(absent, 'synthetic-absent-pass', save: true);
      await _expectAppFailure(
        store.importSnapshot(
          absent,
          _artifact(absent, absentPartition, semesterId: 994),
        ),
        FailureCode.invalidSnapshot,
      );

      final missingDirectory = await store.beginJob();
      final missingPartition = _partition(missingDirectory);
      await store.stagePartition(missingDirectory, missingPartition);
      await _expectAppFailure(
        store.importSnapshot(
          missingDirectory,
          _artifact(missingDirectory, missingPartition, semesterId: 812),
        ),
        FailureCode.invalidSnapshot,
      );

      final afterFailures = await store.readView();
      expect(
        _semesterOptionsEqual(afterFailures.cachedSemesters, oldOptions),
        isTrue,
      );
      expect(
        afterFailures.semesterCatalogUpdatedAtUtc,
        originalView.semesterCatalogUpdatedAtUtc,
      );
      expect(afterFailures.lastSemesterId, originalView.lastSemesterId);
      expect(afterFailures.importCount, originalView.importCount);
      expect(afterFailures.auditCount, originalView.auditCount);
      expect(
        afterFailures.events.map(_eventFact),
        orderedEquals(originalView.events.map(_eventFact)),
      );
      expect(
        _sameBytes(await _credentialCiphertext(store), originalCiphertext),
        isTrue,
      );
      expect(await _credentialAuditCount(store), 1);
    },
  );

  test(
    'v2 upgrade retains encrypted credentials and business facts, then replaces the staged catalog',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'jw-semester-v2-migration-test-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final file = File('${directory.path}${Platform.pathSeparator}jw.sqlite');
      final protector = _SyntheticCredentialProtector();
      final v3Store = await _openPersistentStore(
        file,
        credentialProtector: protector,
      );
      final oldOptions = [
        _option(821, '2026-2027 秋季学期'),
        _option(822, '2026-2027 春季学期', selected: true),
      ];
      final firstTicket = await v3Store.beginJob(
        expectedAccountCode: 'AB12345',
      );
      final firstPartition = _partition(firstTicket);
      await v3Store.stagePartition(firstTicket, firstPartition);
      await v3Store.stageSemesterCatalog(firstTicket, oldOptions);
      await v3Store.stageCredentials(
        firstTicket,
        'synthetic-v2-migration-pass',
        save: true,
      );
      await v3Store.importSnapshot(
        firstTicket,
        _artifact(firstTicket, firstPartition, semesterId: 822),
      );
      final initialView = await v3Store.readView();
      final originalCiphertext = await _credentialCiphertext(v3Store);
      final course = initialView.events.singleWhere(
        (event) => event.kind == JwEventKind.course,
      );
      await v3Store.setHidden(
        _hiddenCommand(
          await v3Store.readAuthority(),
          localId: course.localId,
          expectedVersion: course.version,
          hidden: true,
        ),
      );
      final beforeMigration = await v3Store.readView();
      await v3Store.close();

      final raw = sqlite3.sqlite3.open(file.path);
      try {
        _removeYoungTablesForLegacyFixture(raw);
        raw.execute('DROP TABLE jw_semester_catalog');
        raw.execute('PRAGMA user_version = 2');
      } finally {
        raw.close();
      }

      final upgraded = await _openPersistentStore(
        file,
        credentialProtector: protector,
      );
      final migrated = await upgraded.readView();
      expect(migrated.accountBound, isTrue);
      expect(migrated.credentialSaved, isTrue);
      expect(migrated.lastSemesterId, 822);
      expect(migrated.cachedSemesters, isEmpty);
      expect(migrated.semesterCatalogUpdatedAtUtc, isNull);
      expect(migrated.importCount, beforeMigration.importCount);
      expect(migrated.auditCount, beforeMigration.auditCount);
      expect(
        migrated.events.map(_eventFact),
        orderedEquals(beforeMigration.events.map(_eventFact)),
      );
      expect(
        _sameBytes(await _credentialCiphertext(upgraded), originalCiphertext),
        isTrue,
      );
      final retainedPermits = await upgraded.readCommittedPermits();
      expect(retainedPermits, hasLength(1));
      expect(retainedPermits.single.partition.sameAs(firstPartition), isTrue);

      final newOptions = [
        _option(831, '2027-2028 秋季学期'),
        _option(832, '2027-2028 春季学期', selected: true),
      ];
      final nextTicket = await upgraded.beginJob();
      final nextPartition = _partition(nextTicket);
      await upgraded.stagePartition(nextTicket, nextPartition);
      await upgraded.stageSemesterCatalog(nextTicket, newOptions);
      await upgraded.importSnapshot(
        nextTicket,
        _artifact(nextTicket, nextPartition, semesterId: 832),
      );
      final afterImport = await upgraded.readView();
      expect(
        _semesterOptionsEqual(afterImport.cachedSemesters, newOptions),
        isTrue,
      );
      expect(afterImport.lastSemesterId, 832);
      expect(afterImport.credentialSaved, isTrue);
      expect(afterImport.importCount, 2);
      expect(
        afterImport.events
            .singleWhere((event) => event.localId == course.localId)
            .hidden,
        isTrue,
      );
      final newCourse = afterImport.events.singleWhere(
        (event) =>
            event.kind == JwEventKind.course && event.localId != course.localId,
      );
      expect(newCourse.hidden, isFalse);
      expect(
        _sameBytes(await _credentialCiphertext(upgraded), originalCiphertext),
        isTrue,
      );
    },
  );

  test(
    'v1 upgrade preserves synthetic business facts and allows a new saved credential',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'jw-credential-migration-test-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final file = File('${directory.path}${Platform.pathSeparator}jw.sqlite');
      final protector = _SyntheticCredentialProtector();
      final currentStore = await _openPersistentStore(
        file,
        credentialProtector: protector,
      );
      final firstTicket = await currentStore.beginJob(
        expectedAccountCode: 'AB12345',
      );
      final firstPartition = _partition(firstTicket);
      await _stagePartitionAndDefaultCatalog(
        currentStore,
        firstTicket,
        firstPartition,
      );
      await currentStore.importSnapshot(
        firstTicket,
        _artifact(firstTicket, firstPartition, semesterId: 202610),
      );
      final firstCourse = (await currentStore.readView()).events.singleWhere(
        (event) => event.kind == JwEventKind.course,
      );
      final hiddenCommand = _hiddenCommand(
        await currentStore.readAuthority(),
        localId: firstCourse.localId,
        expectedVersion: firstCourse.version,
        hidden: true,
      );
      final hiddenReceipt = await currentStore.setHidden(hiddenCommand);
      final secondTicket = await currentStore.beginJob();
      final secondPartition = _partition(secondTicket);
      await _stagePartitionAndDefaultCatalog(
        currentStore,
        secondTicket,
        secondPartition,
      );
      await currentStore.importSnapshot(
        secondTicket,
        _artifact(secondTicket, secondPartition, semesterId: 202620),
      );
      final beforeUpgrade = await currentStore.readView();
      expect(beforeUpgrade.importCount, 2);
      expect(
        beforeUpgrade.events
            .singleWhere((event) => event.localId == firstCourse.localId)
            .hidden,
        isTrue,
      );
      await currentStore.close();

      final raw = sqlite3.sqlite3.open(file.path);
      try {
        _removeYoungTablesForLegacyFixture(raw);
        raw.execute('DROP TABLE jw_credentials');
        raw.execute('DROP TABLE jw_preferences');
        raw.execute('DROP TABLE jw_credential_audit');
        raw.execute('DROP TABLE jw_semester_catalog');
        raw.execute('PRAGMA user_version = 1');
      } finally {
        raw.close();
      }

      final upgraded = await _openPersistentStore(
        file,
        credentialProtector: protector,
      );
      final migrated = await upgraded.readView();
      expect(migrated.accountBound, isTrue);
      expect(migrated.importCount, 2);
      expect(migrated.auditCount, beforeUpgrade.auditCount);
      expect(migrated.credentialSaved, isFalse);
      expect(migrated.lastSemesterId, isNull);
      expect(migrated.cachedSemesters, isEmpty);
      expect(migrated.semesterCatalogUpdatedAtUtc, isNull);
      expect(
        migrated.events.map((event) => (event.localId, event.hidden)),
        orderedEquals(
          beforeUpgrade.events.map((event) => (event.localId, event.hidden)),
        ),
      );
      final permits = await upgraded.readCommittedPermits();
      expect(permits, hasLength(1));
      expect(permits.single.partition.sameAs(secondPartition), isTrue);
      expect(await _credentialAuditCount(upgraded), 0);
      expect(await _databaseCount(upgraded, 'jw_local_receipts'), 1);
      final replay = await upgraded.setHidden(hiddenCommand);
      expect(replay.replayed, isTrue);
      expect(replay.resultVersion, hiddenReceipt.resultVersion);

      final nextTicket = await upgraded.beginJob();
      final nextPartition = _partition(nextTicket);
      await _stagePartitionAndDefaultCatalog(
        upgraded,
        nextTicket,
        nextPartition,
      );
      await upgraded.stageCredentials(
        nextTicket,
        'synthetic-after-upgrade-pass',
        save: true,
      );
      await upgraded.importSnapshot(
        nextTicket,
        _artifact(nextTicket, nextPartition, semesterId: 202630),
      );
      final afterNextImport = await upgraded.readView();
      expect(afterNextImport.credentialSaved, isTrue);
      expect(afterNextImport.lastSemesterId, 202630);
      expect(afterNextImport.cachedSemesters, isNotEmpty);
      expect(afterNextImport.importCount, 3);
      expect(await _credentialAuditCount(upgraded, 'saved'), 1);
    },
  );
}

int _partitionSequence = 0;
int _localOperationSequence = 0;

Future<JwStore> _openStore({
  Future<void> Function(JwImportCheckpoint)? onCheckpoint,
  JwCredentialProtector? credentialProtector,
  AppClock? clock,
}) async {
  final store = JwStore(
    NativeDatabase.memory(),
    ownership: _SwitchableOwnership(),
    clock: clock ?? FixedClock(DateTime.utc(2026, 10, 10, 12)),
    onCheckpoint: onCheckpoint,
    credentialProtector: credentialProtector,
  );
  try {
    await store.initialize();
  } catch (_) {
    await store.close();
    rethrow;
  }
  addTearDown(store.close);
  return store;
}

JwSemesterOption _option(int id, String name, {bool selected = false}) =>
    JwSemesterOption(id: id, name: name, selected: selected);

bool _semesterOptionsEqual(
  List<JwSemesterOption> actual,
  List<JwSemesterOption> expected,
) {
  if (actual.length != expected.length) return false;
  for (var index = 0; index < actual.length; index++) {
    final left = actual[index];
    final right = expected[index];
    if (left.id != right.id ||
        left.name != right.name ||
        left.selected != right.selected) {
      return false;
    }
  }
  return true;
}

Object _eventFact(JwStoredEvent event) => (
  event.localId,
  event.version,
  event.kind,
  event.title,
  event.startsAtUtc,
  event.endsAtUtc,
  event.presence,
  event.hidden,
);

Future<void> _stagePartitionAndDefaultCatalog(
  JwStore store,
  JwJobTicket ticket,
  JwPartitionRef partition,
) async {
  await store.stagePartition(ticket, partition);
  await store.stageSemesterCatalog(ticket, const [
    JwSemesterOption(id: 202610, name: '2026-2027 秋季学期', selected: false),
    JwSemesterOption(id: 202620, name: '2026-2027 春季学期', selected: false),
    JwSemesterOption(id: 202630, name: '2026-2027 夏季学期', selected: false),
    JwSemesterOption(id: 202640, name: '2027-2028 秋季学期', selected: false),
  ]);
}

Future<JwStore> _openPersistentStore(
  File file, {
  Future<void> Function(JwImportCheckpoint)? onCheckpoint,
  JwCredentialProtector? credentialProtector,
}) async {
  final store = JwStore(
    NativeDatabase(file, logStatements: false),
    ownership: _SwitchableOwnership(),
    clock: FixedClock(DateTime.utc(2026, 10, 10, 12)),
    onCheckpoint: onCheckpoint,
    credentialProtector: credentialProtector,
  );
  try {
    await store.initialize();
  } catch (_) {
    await store.close();
    rethrow;
  }
  addTearDown(store.close);
  return store;
}

Future<Uint8List?> _credentialCiphertext(JwStore store) async {
  final row = await store
      .customSelect(
        'SELECT ciphertext FROM jw_credentials WHERE account_id = 1',
      )
      .getSingleOrNull();
  final ciphertext = row?.read<Uint8List>('ciphertext');
  return ciphertext == null ? null : Uint8List.fromList(ciphertext);
}

Future<int> _credentialAuditCount(JwStore store, [String? action]) async {
  final row = await store
      .customSelect(
        action == null
            ? 'SELECT COUNT(*) AS count FROM jw_credential_audit'
            : 'SELECT COUNT(*) AS count FROM jw_credential_audit WHERE action = ?',
        variables: action == null ? const [] : [Variable.withString(action)],
      )
      .getSingle();
  return row.read<int>('count');
}

Future<int> _databaseCount(JwStore store, String table) async {
  if (!RegExp(r'^[a-z_]+$').hasMatch(table)) {
    throw ArgumentError.value(table, 'table');
  }
  final row = await store
      .customSelect('SELECT COUNT(*) AS count FROM $table')
      .getSingle();
  return row.read<int>('count');
}

bool _containsBytes(Uint8List haystack, List<int> needle) {
  if (needle.isEmpty) return true;
  for (var start = 0; start + needle.length <= haystack.length; start++) {
    var matches = true;
    for (var index = 0; index < needle.length; index++) {
      if (haystack[start + index] != needle[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

bool _sameBytes(Uint8List? left, Uint8List? right) {
  if (left == null || right == null) return left == null && right == null;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

void _expectCredentialPayload(
  Uint8List bytes, {
  required String username,
  required String password,
}) {
  final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  expect(decoded['username'] == username, isTrue);
  expect(decoded['password'] == password, isTrue);
}

JwPartitionRef _partition(
  JwJobTicket ticket, {
  String? attempt,
  JwPartitionPurpose purpose = JwPartitionPurpose.initial,
}) {
  _partitionSequence++;
  return JwPartitionRef(
    id: 'jwp-${_partitionSequence.toRadixString(16).padLeft(32, '0')}',
    ownerId: ticket.stamp.ownerId,
    purpose: purpose,
    attempt: attempt ?? ticket.stamp.jobId,
    resetEpoch: ticket.stamp.resetEpoch,
  );
}

JwHiddenCommand _hiddenCommand(
  JwAuthority authority, {
  String? operationId,
  String? ownerId,
  int accountId = 1,
  int? resetEpoch,
  required int localId,
  required int expectedVersion,
  required bool hidden,
}) {
  _localOperationSequence++;
  return JwHiddenCommand(
    operationId:
        operationId ??
        'jw-local-${_localOperationSequence.toRadixString(16).padLeft(32, '0')}',
    ownerId: ownerId ?? authority.ownerId,
    accountId: accountId,
    resetEpoch: resetEpoch ?? authority.resetEpoch,
    localId: localId,
    expectedVersion: expectedVersion,
    hidden: hidden,
  );
}

JwCollectedArtifact _artifact(
  JwJobTicket ticket,
  JwPartitionRef partition, {
  String accountCode = 'AB12345',
  String? courseTitle,
  int semesterId = 202610,
  List<Map<String, Object>> courses = const [
    {
      'lessonId': 101,
      'groupId': 1101,
      'date': '2026-10-12',
      'startMinute': 540,
      'endMinute': 600,
      'title': '合成课程：线性代数',
    },
  ],
  List<Map<String, Object>> exams = const [
    {
      'courseCode': 'SYNTH-101',
      'examType': 'final',
      'date': '2026-12-20',
      'startMinute': 540,
      'endMinute': 600,
      'title': '合成考试：线性代数',
    },
  ],
}) {
  final selectedCourses = courseTitle == null
      ? courses
      : courses.map((course) => {...course, 'title': courseTitle}).toList();
  final diagnostics = <String, Object>{
    'checks': {
      'identityBefore': 'ok',
      'course': 'ok',
      'index': 'ok',
      'datum': selectedCourses.isEmpty ? 'skipped' : 'ok',
      'exams': 'ok',
      'identityAfter': 'ok',
    },
    'reason': 'none',
    'identityReads': 2,
    'lessonIds': selectedCourses.length,
    'lessons': selectedCourses.length,
    'groups': selectedCourses.length,
    'schedules': selectedCourses.length,
    'datedSchedules': selectedCourses.length,
    'timedSchedules': selectedCourses.length,
    'linkedSchedules': selectedCourses.length,
    'examRows': exams.length,
    'datedExams': exams.length,
    'semesterAccepted': true,
    'selfRouteBound': true,
    'identityStable': true,
    'emptyCourse': selectedCourses.isEmpty,
    'emptyExams': exams.isEmpty,
    'pagination': false,
    'types': {
      'lessonIds': 'array',
      'lessonList': 'array',
      'scheduleGroupList': 'array',
      'scheduleList': 'array',
      'date': 'string',
      'startTime': 'string',
      'endTime': 'string',
    },
  };
  final reply = JwCollectionReply.decode(
    jsonEncode({
      'operation': 31,
      'phase': 'done',
      'code': 'ok',
      'identity': {
        'candidateCount': 1,
        'method': 'table',
        'accountCode': accountCode,
      },
      'diagnostics': diagnostics,
      'snapshot': {
        'version': jwContractVersion,
        'semesterId': semesterId,
        'courses': [
          for (final row in selectedCourses)
            {
              ...row,
              if (!row.containsKey('academicDetails'))
                'academicDetails': JwAcademicDetails(
                  lessonId: row['lessonId'] as int,
                  groupId: row['groupId'] as int,
                ).toMap(),
            },
        ],
        'exams': [
          for (final row in exams)
            {
              ...row,
              if (!row.containsKey('academicDetails'))
                'academicDetails': JwAcademicDetails(
                  courseCode: row['courseCode'] as String,
                  examType: row['examType'] as String,
                ).toMap(),
            },
        ],
      },
    }),
    operation: 31,
  );
  return JwCollectedArtifact.seal(
    reply: reply,
    stamp: ticket.stamp,
    partition: partition,
    session: 1,
    document: 2,
    semesterId: semesterId,
    collectedAtUtc: DateTime.utc(2026, 10, 10, 12),
  );
}

Map<String, Object> _course(int lessonId, int day, String title) => {
  'lessonId': lessonId,
  'groupId': lessonId + 1000,
  'date':
      '${day ~/ 10000}-${((day ~/ 100) % 100).toString().padLeft(2, '0')}-${(day % 100).toString().padLeft(2, '0')}',
  'startMinute': 540,
  'endMinute': 600,
  'title': title,
};

final class _SwitchableOwnership implements AssetOwnership {
  bool held = true;

  @override
  bool get isHeld => held;

  @override
  void ensureHeld() {
    if (!held) throw const AppFailure(FailureCode.ownershipLost);
  }
}

final class _MutableClock implements AppClock {
  _MutableClock(this.nowUtc);

  @override
  DateTime nowUtc;
}

final class _SyntheticCredentialProtector implements JwCredentialProtector {
  bool failProtect = false;
  Uint8List? lastProtectInput;
  Uint8List? lastProtectOutput;

  @override
  String get mechanism => 'synthetic-test-xor-v1';

  @override
  Future<Uint8List> protect(
    Uint8List plaintext, {
    required String purpose,
  }) async {
    lastProtectInput = plaintext;
    if (failProtect) {
      throw const JwCredentialException(JwCredentialFailure.protectionFailed);
    }
    final encrypted = _transform(plaintext, purpose);
    lastProtectOutput = encrypted;
    return encrypted;
  }

  @override
  Future<Uint8List> unprotect(
    Uint8List ciphertext, {
    required String purpose,
  }) async => _transform(ciphertext, purpose);

  Uint8List _transform(Uint8List bytes, String purpose) {
    var seed = 0x69;
    for (final byte in utf8.encode(purpose)) {
      seed = ((seed * 33) ^ byte) & 0xff;
    }
    return Uint8List.fromList(
      List<int>.generate(
        bytes.length,
        (index) => bytes[index] ^ ((seed + index * 29 + 0xA5) & 0xff),
      ),
    );
  }
}

/// The fixture downgrades only an isolated synthetic copy, never real data.
void _removeYoungTablesForLegacyFixture(sqlite3.Database database) {
  database.execute('ALTER TABLE jw_events DROP COLUMN source_retired');
  database.execute('ALTER TABLE young_events DROP COLUMN source_retired');
  for (final table in const [
    'm6_state',
    'm6_expected',
    'm6_reminder_overrides',
    'm6_native_map',
    'm6_briefs',
    'm6_brief_suppressed',
  ]) {
    database.execute('DROP TABLE IF EXISTS $table');
  }
  removeCalendarTablesForLegacyFixture(database);
  _removeSchema14AgentObjectsForLegacyFixture(database);
  for (final table in const [
    'knowledge_load_items',
    'knowledge_sections',
    'knowledge_audit',
    'knowledge_loads',
    'knowledge_materials',
    'knowledge_state',
    'public_sources',
    'young_local_receipts',
    'young_audit',
    'young_preferences',
    'young_permits',
    'young_receipts',
    'young_overlays',
    'young_events',
    'young_jobs',
    'young_state',
  ]) {
    database.execute('DROP TABLE $table');
  }
}

void _removeSchema14AgentObjectsForLegacyFixture(sqlite3.Database database) {
  final tables = database
      .select("SELECT name FROM sqlite_master WHERE type='table'")
      .map((row) => row['name'] as String)
      .toSet();
  for (final table in const ['agent_permissions', 'agent_chat_state']) {
    if (tables.contains(table)) database.execute('DROP TABLE $table');
  }
  if (tables.contains('agent_actions')) {
    final columns = database
        .select('PRAGMA table_info(agent_actions)')
        .map((row) => row['name'] as String)
        .toSet();
    if (columns.contains('authorization')) {
      database.execute('ALTER TABLE agent_actions DROP COLUMN authorization');
    }
  }
}

Future<void> _expectAppFailure(
  Future<dynamic> operation,
  FailureCode code,
) async {
  await expectLater(
    operation,
    throwsA(
      isA<AppFailure>().having((failure) => failure.code, 'failure code', code),
    ),
  );
}
