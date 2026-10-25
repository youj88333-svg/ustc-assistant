import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/data/demo_store.dart';
import 'package:ustc_assistant_m0/data/import_contract.dart';

void main() {
  test(
    'an import exposes its receipt and committed projections together',
    () async {
      final store = await _openStore();
      final stamp = await store.beginJob();
      final request = _request(stamp, operationId: 'capture-001');

      final receipt = await store.importSnapshot(request);
      final firstView = await store.readView();
      expect(receipt.operationId, 'capture-001');
      expect(receipt.recordCount, 2);
      expect(receipt.replayed, isFalse);
      expect(receipt.followUpPending, isTrue);
      expect(firstView.events, hasLength(2));
      expect(firstView.importCount, 1);
      expect(firstView.auditCount, 1);
      expect(firstView.pendingFollowUps, 1);

      final replay = await store.replayLatest(stamp);
      final replayView = await store.readView();
      expect(replay.operationId, receipt.operationId);
      expect(replay.recordCount, 2);
      expect(replay.replayed, isTrue);
      expect(replay.followUpPending, isTrue);
      expect(replayView.importCount, 1);
      expect(replayView.auditCount, 1);
      expect(replayView.pendingFollowUps, 1);
      expect(
        replayView.events.map((event) => event.localId),
        firstView.events.map((event) => event.localId),
      );
    },
  );

  test(
    'same operation cannot change content; a new capture can repeat it',
    () async {
      final store = await _openStore();
      final firstStamp = await store.beginJob();
      final original = _request(firstStamp, operationId: 'operation-one');
      await store.importSnapshot(original);

      final changed = _request(
        firstStamp,
        operationId: 'operation-one',
        events: _events(secondTitle: '合成课程：改动后的内容'),
      );
      await _expectFailure(
        store.importSnapshot(changed),
        FailureCode.idempotencyConflict,
      );

      final secondStamp = await store.beginJob();
      final secondReceipt = await store.importSnapshot(
        _request(secondStamp, operationId: 'operation-two'),
      );
      final view = await store.readView();
      expect(secondReceipt.replayed, isFalse);
      expect(secondReceipt.operationId, 'operation-two');
      expect(view.events, hasLength(2));
      expect(view.importCount, 2);
      expect(view.auditCount, 2);
      expect(view.pendingFollowUps, 2);
      expect(view.events.map((event) => event.localId).toSet(), hasLength(2));
    },
  );

  test(
    'complete empty scope marks records missing without deleting local identity',
    () async {
      final store = await _openStore();
      final firstStamp = await store.beginJob();
      await store.importSnapshot(
        _request(firstStamp, operationId: 'initial-capture'),
      );
      final beforeEmpty = await store.readView();
      final localIds = {
        for (final event in beforeEmpty.events) event.externalId: event.localId,
      };

      final emptyStamp = await store.beginJob();
      final emptyReceipt = await store.importSnapshot(
        _request(emptyStamp, operationId: 'complete-empty', events: []),
      );
      expect(emptyReceipt.recordCount, 0);
      final afterEmpty = await store.readView();
      expect(afterEmpty.events, hasLength(2));
      expect(afterEmpty.events.every((event) => event.sourceMissing), isTrue);
      expect({
        for (final event in afterEmpty.events) event.externalId: event.localId,
      }, localIds);

      final incompleteStamp = await store.beginJob();
      await _expectFailure(
        store.importSnapshot(
          _request(
            incompleteStamp,
            operationId: 'incomplete-capture',
            complete: false,
          ),
        ),
        FailureCode.incompleteSnapshot,
      );
      final afterIncomplete = await store.readView();
      expect(
        afterIncomplete.events.map((event) => event.localId),
        afterEmpty.events.map((event) => event.localId),
      );
      expect(
        afterIncomplete.events.every((event) => event.sourceMissing),
        isTrue,
      );
      expect(afterIncomplete.importCount, afterEmpty.importCount);
      expect(afterIncomplete.auditCount, afterEmpty.auditCount);
      expect(afterIncomplete.pendingFollowUps, afterEmpty.pendingFollowUps);
      final restoredStamp = await store.beginJob();
      await store.importSnapshot(
        _request(restoredStamp, operationId: 'reappeared'),
      );
      final restored = await store.readView();
      expect(restored.events.every((event) => !event.sourceMissing), isTrue);
      expect({
        for (final event in restored.events) event.externalId: event.localId,
      }, localIds);
      expect(restored.importCount, 3);
      expect(restored.auditCount, 3);
    },
  );

  test(
    'generation, context, source, contract, and reset changes reject old requests',
    () async {
      final store = await _openStore();
      final staleGeneration = await store.beginJob();
      final current = await store.beginJob();

      final rejected = [
        _request(staleGeneration, operationId: 'stale-generation'),
        _request(
          _copyStamp(current, localContext: 'different-demo-context'),
          operationId: 'stale-context',
        ),
        _request(
          _copyStamp(current, sourceKey: 'different-source'),
          operationId: 'stale-source',
        ),
        _request(
          _copyStamp(current, contractVersion: 'different-contract'),
          operationId: 'stale-contract',
        ),
        _request(
          _copyStamp(current, resetEpoch: current.resetEpoch + 1),
          operationId: 'stale-reset',
        ),
      ];
      for (final request in rejected) {
        await _expectFailure(
          store.importSnapshot(request),
          FailureCode.staleResult,
        );
      }
      final view = await store.readView();
      expect(view.events, isEmpty);
      expect(view.importCount, 0);
      expect(view.auditCount, 0);
      expect(view.pendingFollowUps, 0);
    },
  );

  test('cancel-first refuses the import before it can commit', () async {
    final store = await _openStore();
    final stamp = await store.beginJob();

    expect(await store.cancelJob(stamp), CancellationDisposition.cancelled);
    await _expectFailure(
      store.importSnapshot(_request(stamp, operationId: 'cancelled-op')),
      FailureCode.cancelled,
    );
    final view = await store.readView();
    expect(view.events, isEmpty);
    expect(view.importCount, 0);
    expect(view.auditCount, 0);
    expect(view.pendingFollowUps, 0);
  });

  test(
    'a queued cancellation observes an import that committed first',
    () async {
      final reachedBeforeCommit = Completer<void>();
      final allowCommit = Completer<void>();
      final store = await _openStore(
        onCheckpoint: (checkpoint) async {
          if (checkpoint == ImportCheckpoint.beforeCommit) {
            reachedBeforeCommit.complete();
            await allowCommit.future;
          }
        },
      );
      final stamp = await store.beginJob();
      final import = store.importSnapshot(
        _request(stamp, operationId: 'committed-op'),
      );

      try {
        await reachedBeforeCommit.future.timeout(const Duration(seconds: 5));
        final cancellation = store.cancelJob(stamp);
        allowCommit.complete();

        final receipt = await import;
        expect(receipt.replayed, isFalse);
        expect(await cancellation, CancellationDisposition.alreadyCommitted);
        final view = await store.readView();
        expect(view.events, hasLength(2));
        expect(view.importCount, 1);
        expect(view.auditCount, 1);
        expect(view.pendingFollowUps, 1);
      } finally {
        if (!allowCommit.isCompleted) allowCommit.complete();
      }
    },
  );

  test(
    'a real SQLite NOT NULL violation rolls back the visible import projection',
    () async {
      final store = await _openStore();
      final stamp = await store.beginJob();
      final request = _request(stamp, operationId: 'rollback-op');

      await _expectFailure(
        store.importSnapshot(request, simulateSqlFailure: true),
        FailureCode.storageFailed,
      );
      final rolledBack = await store.readView();
      expect(rolledBack.events, isEmpty);
      expect(rolledBack.importCount, 0);
      expect(rolledBack.auditCount, 0);
      expect(rolledBack.pendingFollowUps, 0);

      final retry = await store.importSnapshot(request);
      expect(retry.operationId, 'rollback-op');
      final committed = await store.readView();
      expect(committed.events, hasLength(2));
      expect(committed.importCount, 1);
      expect(committed.auditCount, 1);
      expect(committed.pendingFollowUps, 1);
    },
  );

  test(
    'ownership loss rejects a write and restoring ownership leaves the store readable',
    () async {
      final owner = _SwitchableOwnership();
      final store = await _openStore(ownership: owner);
      final stamp = await store.beginJob();
      owner.held = false;

      await _expectFailure(
        store.importSnapshot(_request(stamp, operationId: 'no-owner')),
        FailureCode.ownershipLost,
      );
      owner.held = true;
      final view = await store.readView();
      expect(view.events, isEmpty);
      expect(view.importCount, 0);
      expect(view.auditCount, 0);
      expect(view.pendingFollowUps, 0);
    },
  );

  test(
    'maintenance rejects a stamp captured before the maintenance epoch',
    () async {
      final store = await _openStore();
      final stamp = await store.beginJob();
      await store.enterMaintenance();

      await _expectAppFailure(
        store.importSnapshot(
          _request(stamp, operationId: 'during-maintenance'),
        ),
      );
      await store.resumeAfterMaintenance();
      await _expectAppFailure(
        store.importSnapshot(_request(stamp, operationId: 'after-maintenance')),
      );
      final view = await store.readView();
      expect(view.events, isEmpty);
      expect(view.importCount, 0);
      expect(view.auditCount, 0);
      expect(view.pendingFollowUps, 0);
    },
  );
}

Future<DemoStore> _openStore({
  _SwitchableOwnership? ownership,
  Future<void> Function(ImportCheckpoint)? onCheckpoint,
}) async {
  final store = DemoStore(
    NativeDatabase.memory(),
    ownership: ownership ?? _SwitchableOwnership(),
    clock: FixedClock(DateTime.utc(2026, 10, 9, 12)),
    onCheckpoint: onCheckpoint,
  );
  await store.initialize();
  addTearDown(store.close);
  return store;
}

final class _SwitchableOwnership implements AssetOwnership {
  bool held = true;

  @override
  bool get isHeld => held;

  @override
  void ensureHeld() {
    if (!held) throw const AppFailure(FailureCode.ownershipLost);
  }
}

JobStamp _copyStamp(
  JobStamp stamp, {
  String? localContext,
  String? sourceKey,
  String? contractVersion,
  int? generation,
  int? resetEpoch,
}) => JobStamp(
  jobId: stamp.jobId,
  localContext: localContext ?? stamp.localContext,
  sourceKey: sourceKey ?? stamp.sourceKey,
  contractVersion: contractVersion ?? stamp.contractVersion,
  generation: generation ?? stamp.generation,
  resetEpoch: resetEpoch ?? stamp.resetEpoch,
);

ImportRequest _request(
  JobStamp stamp, {
  required String operationId,
  List<EventDraft>? events,
  bool complete = true,
}) {
  final selectedEvents = events ?? _events();
  final provisional = ImportRequest(
    stamp: stamp,
    operationId: operationId,
    rangeStartUtc: _rangeStart,
    rangeEndUtc: _rangeEnd,
    collectedAtUtc: DateTime.utc(2026, 10, 9, 12),
    contentFingerprint: '',
    events: selectedEvents,
    complete: complete,
  );
  return ImportRequest(
    stamp: stamp,
    operationId: operationId,
    rangeStartUtc: _rangeStart,
    rangeEndUtc: _rangeEnd,
    collectedAtUtc: DateTime.utc(2026, 10, 9, 12),
    contentFingerprint: provisional.calculatedFingerprint,
    events: selectedEvents,
    complete: complete,
  );
}

List<EventDraft> _events({String secondTitle = '合成课程：计算机系统基础'}) => [
  EventDraft(
    externalId: 'synthetic-course-20261005-01',
    title: '合成课程：线性代数',
    startsAtUtc: DateTime.utc(2026, 10, 5, 1),
    endsAtUtc: DateTime.utc(2026, 10, 5, 2, 30),
  ),
  EventDraft(
    externalId: 'synthetic-course-20261005-02',
    title: secondTitle,
    startsAtUtc: DateTime.utc(2026, 10, 9, 1),
    endsAtUtc: DateTime.utc(2026, 10, 9, 2, 30),
  ),
];

final _rangeStart = DateTime.utc(2026, 10, 4, 16);
final _rangeEnd = DateTime.utc(2026, 10, 11, 16);

Future<void> _expectFailure(Future<dynamic> operation, FailureCode code) async {
  await expectLater(
    operation,
    throwsA(
      isA<AppFailure>().having((failure) => failure.code, 'failure code', code),
    ),
  );
}

Future<void> _expectAppFailure(Future<dynamic> operation) async {
  await expectLater(operation, throwsA(isA<AppFailure>()));
}
