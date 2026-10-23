import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import '../support/calendar_legacy_schema.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/jw_work_contract.dart';
import 'package:ustc_assistant_m0/core/young_work_contract.dart';
import 'package:ustc_assistant_m0/data/jw_import_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/data/young_import_contract.dart';
import 'package:ustc_assistant_m0/source/young_business_contract.dart';
import 'package:ustc_assistant_m0/source/young_collection_contract.dart';

const _account = 'SYNTHETIC001';
const _opaqueEventId = 'synthetic-calendar-private-key';
const _opaqueActivityId = 'synthetic-activity-private-key';
final _startDay = DateTime.utc(2026, 6, 10);
const _ownerOther = 'jw-owner-ffffffffffffffffffffffffffffffff';

int _partitionSequence = 0;
int _hiddenOperationSequence = 0;

void main() {
  // Every harness has its own memory/temp executor, never the formal database.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  group('Young C3 store behavior', () {
    test(
      'an activity query can bind the shared account without importing a calendar',
      () async {
        final store = await _openStore();
        final unboundBefore = await store.readYoungAuthority();
        expect(unboundBefore.accountBound, isFalse);

        final ticket = await store.beginYoungJob(
          kind: YoungJobKind.activities,
          expectedAccountCode: ' synthetic001 ',
        );
        final partition = await _stagePartition(store, ticket);
        final artifact = _activitiesArtifact(ticket, partition);
        final receipt = await store.completeYoungQuery(ticket, artifact);
        await store.validateYoungDelivery(ticket, artifact);

        expect(receipt.kind, YoungJobKind.activities);
        expect(receipt.itemCount, 1);
        expect(receipt.replayed, isFalse);
        expect((await store.readYoungAuthority()).accountBound, isTrue);
        expect(
          (await store.readYoungPermits()).single.partition.sameAs(partition),
          isTrue,
        );

        final young = await store.readYoungView();
        expect(young.accountBound, isTrue);
        expect(young.events, isEmpty);
        expect(young.importCount, 0);
        expect(young.queryCount, 1);
        expect(young.auditCount, 1);
        expect(young.firstDay, isNull);
        expect(young.lastDay, isNull);

        await expectLater(
          store.beginJob(expectedAccountCode: 'OTHERACCOUNT'),
          throwsA(
            isA<JwIdentityException>().having(
              (error) => error.code,
              'identity failure',
              JwIdentityFailure.identityMismatch,
            ),
          ),
        );
        final jwTicket = await store.beginJob(expectedAccountCode: _account);
        expect(jwTicket.stamp.accountId, 1);
        expect((await store.readAuthority()).accountBound, isTrue);
      },
    );

    test(
      'a bound JW account cannot be changed by starting a Young job',
      () async {
        final store = await _openStore();
        await _seedCanonicalAccount(store, _account);
        final before = await store.readYoungAuthority();

        await _expectYoungIdentity(
          store.beginYoungJob(
            kind: YoungJobKind.calendar,
            expectedAccountCode: 'OTHERACCOUNT',
            firstDay: _startDay,
            lastDay: _startDay,
          ),
          YoungIdentityFailure.identityMismatch,
        );

        final after = await store.readYoungAuthority();
        expect(after.ownerId, before.ownerId);
        expect(after.generation, before.generation);
        expect(after.resetEpoch, before.resetEpoch);
        expect(after.accountBound, isTrue);
        expect(await _count(store, 'young_jobs'), 0);
      },
    );

    test(
      'a fixed response for another account commits no Young facts or permit',
      () async {
        final store = await _openStore();
        final ticket = await store.beginYoungJob(
          kind: YoungJobKind.calendar,
          expectedAccountCode: _account,
          firstDay: _startDay,
          lastDay: _startDay,
        );
        final partition = await _stagePartition(store, ticket);
        final wrongAccount = _calendarArtifact(
          ticket,
          partition,
          username: 'OTHERACCOUNT',
          rows: [_calendarRow(_opaqueEventId, itemId: 'activity-17')],
        );

        await _expectYoungIdentity(
          store.importYoungCalendar(ticket, wrongAccount),
          YoungIdentityFailure.accountMismatch,
        );
        final view = await store.readYoungView();
        expect(view.accountBound, isFalse);
        expect(view.events, isEmpty);
        expect(view.importCount, 0);
        expect(view.queryCount, 0);
        expect(view.auditCount, 0);
        expect(view.firstDay, isNull);
        expect(view.lastDay, isNull);
        expect(await store.readYoungPermits(), isEmpty);
      },
    );

    for (final checkpoint in YoungStoreCheckpoint.values) {
      test(
        'a $checkpoint failure rolls back binding, events, permit, receipt, and range',
        () async {
          var failOnce = true;
          final store = await _openStore(
            onYoungCheckpoint: (seen) async {
              if (seen == checkpoint && failOnce) {
                failOnce = false;
                throw const AppFailure(FailureCode.storageFailed);
              }
            },
          );
          final ticket = await store.beginYoungJob(
            kind: YoungJobKind.calendar,
            expectedAccountCode: _account,
            firstDay: _startDay,
            lastDay: _startDay,
          );
          final partition = await _stagePartition(store, ticket);
          final artifact = _calendarArtifact(
            ticket,
            partition,
            rows: [_calendarRow(_opaqueEventId, itemId: 'activity-17')],
          );

          await _expectAppFailure(
            store.importYoungCalendar(ticket, artifact),
            FailureCode.storageFailed,
          );
          final rolledBack = await store.readYoungView();
          expect(rolledBack.accountBound, isFalse);
          expect(rolledBack.events, isEmpty);
          expect(rolledBack.importCount, 0);
          expect(rolledBack.queryCount, 0);
          expect(rolledBack.auditCount, 0);
          expect(rolledBack.firstDay, isNull);
          expect(rolledBack.lastDay, isNull);
          expect(await store.readYoungPermits(), isEmpty);

          final receipt = await store.importYoungCalendar(ticket, artifact);
          expect(receipt.replayed, isFalse);
          final committed = await store.readYoungView();
          expect(committed.accountBound, isTrue);
          expect(committed.events, hasLength(1));
          expect(committed.importCount, 1);
          expect(committed.auditCount, 1);
          expect(committed.firstDay, _startDay);
          expect(committed.lastDay, _startDay);
          expect(await store.readYoungPermits(), hasLength(1));
        },
      );
    }

    test(
      'superseded, reinitialized, reset-epoch, failed, and cancelled tickets are rejected',
      () async {
        final supersededStore = await _openStore();
        final oldTicket = await _beginCalendar(supersededStore);
        final oldPartition = await _stagePartition(supersededStore, oldTicket);
        final oldArtifact = _calendarArtifact(oldTicket, oldPartition);
        final currentTicket = await _beginCalendar(supersededStore);
        await _stagePartition(supersededStore, currentTicket);
        await _expectAppFailure(
          supersededStore.importYoungCalendar(oldTicket, oldArtifact),
          FailureCode.staleResult,
        );

        final reinitializedStore = await _openStore();
        final reinitializedTicket = await _beginCalendar(reinitializedStore);
        final reinitializedPartition = await _stagePartition(
          reinitializedStore,
          reinitializedTicket,
        );
        final reinitializedArtifact = _calendarArtifact(
          reinitializedTicket,
          reinitializedPartition,
        );
        await reinitializedStore.initialize();
        await _expectAppFailure(
          reinitializedStore.importYoungCalendar(
            reinitializedTicket,
            reinitializedArtifact,
          ),
          FailureCode.staleResult,
        );

        final epochStore = await _openStore();
        final epochTicket = await _beginCalendar(epochStore);
        final epochPartition = await _stagePartition(epochStore, epochTicket);
        final epochArtifact = _calendarArtifact(epochTicket, epochPartition);
        await epochStore.customStatement(
          'UPDATE jw_state SET reset_epoch = reset_epoch + 1 WHERE singleton = 1',
        );
        await _expectAppFailure(
          epochStore.importYoungCalendar(epochTicket, epochArtifact),
          FailureCode.staleResult,
        );

        final failedStore = await _openStore();
        final failedTicket = await _beginCalendar(failedStore);
        final failedPartition = await _stagePartition(
          failedStore,
          failedTicket,
        );
        final failedArtifact = _calendarArtifact(failedTicket, failedPartition);
        await failedStore.failYoungJob(failedTicket);
        await _expectAppFailure(
          failedStore.importYoungCalendar(failedTicket, failedArtifact),
          FailureCode.staleResult,
        );

        final cancelledStore = await _openStore();
        final cancelledTicket = await _beginCalendar(cancelledStore);
        final cancelledPartition = await _stagePartition(
          cancelledStore,
          cancelledTicket,
        );
        final cancelledArtifact = _calendarArtifact(
          cancelledTicket,
          cancelledPartition,
        );
        expect(await cancelledStore.cancelYoungJob(cancelledTicket), isTrue);
        await _expectAppFailure(
          cancelledStore.importYoungCalendar(
            cancelledTicket,
            cancelledArtifact,
          ),
          FailureCode.cancelled,
        );
        expect((await cancelledStore.readYoungView()).events, isEmpty);
      },
    );

    test(
      'the same ticket replays only identical query content and never writes calendar events',
      () async {
        final store = await _openStore();
        final ticket = await store.beginYoungJob(
          kind: YoungJobKind.activities,
          expectedAccountCode: _account,
        );
        final partition = await _stagePartition(store, ticket);
        final artifact = _activitiesArtifact(ticket, partition);
        final first = await store.completeYoungQuery(ticket, artifact);
        final beforeReplay = await store.readYoungView();
        final replay = await store.completeYoungQuery(ticket, artifact);

        expect(first.replayed, isFalse);
        expect(replay.replayed, isTrue);
        expect(replay.operationId, first.operationId);
        expect(replay.itemCount, first.itemCount);
        final afterReplay = await store.readYoungView();
        expect(afterReplay.events, isEmpty);
        expect(afterReplay.importCount, 0);
        expect(afterReplay.queryCount, beforeReplay.queryCount);
        expect(afterReplay.auditCount, beforeReplay.auditCount);
        expect(await _count(store, 'young_receipts'), 1);

        final changedArtifact = _activitiesArtifact(
          ticket,
          partition,
          itemName: 'Synthetic activity with changed content',
        );
        await _expectAppFailure(
          store.completeYoungQuery(ticket, changedArtifact),
          FailureCode.idempotencyConflict,
        );
        final unchanged = await store.readYoungView();
        expect(unchanged.events, isEmpty);
        expect(unchanged.queryCount, 1);
        expect(unchanged.auditCount, 1);
        await store.validateYoungDelivery(ticket, artifact);
      },
    );

    test(
      'cancelled or superseded query artifacts cannot be delivered',
      () async {
        final cancelledStore = await _openStore();
        final cancelledTicket = await cancelledStore.beginYoungJob(
          kind: YoungJobKind.activities,
          expectedAccountCode: _account,
        );
        final cancelledPartition = await _stagePartition(
          cancelledStore,
          cancelledTicket,
        );
        final cancelledArtifact = _activitiesArtifact(
          cancelledTicket,
          cancelledPartition,
        );
        expect(await cancelledStore.cancelYoungJob(cancelledTicket), isTrue);
        await _expectAppFailure(
          cancelledStore.validateYoungDelivery(
            cancelledTicket,
            cancelledArtifact,
          ),
          FailureCode.cancelled,
        );
        await _expectAppFailure(
          cancelledStore.completeYoungQuery(cancelledTicket, cancelledArtifact),
          FailureCode.cancelled,
        );

        final nextGenerationStore = await _openStore();
        final firstTicket = await nextGenerationStore.beginYoungJob(
          kind: YoungJobKind.activities,
          expectedAccountCode: _account,
        );
        final firstPartition = await _stagePartition(
          nextGenerationStore,
          firstTicket,
        );
        final firstArtifact = _activitiesArtifact(firstTicket, firstPartition);
        await nextGenerationStore.completeYoungQuery(
          firstTicket,
          firstArtifact,
        );
        await nextGenerationStore.validateYoungDelivery(
          firstTicket,
          firstArtifact,
        );

        final nextTicket = await nextGenerationStore.beginYoungJob(
          kind: YoungJobKind.activities,
        );
        await _stagePartition(nextGenerationStore, nextTicket);
        await _expectAppFailure(
          nextGenerationStore.validateYoungDelivery(firstTicket, firstArtifact),
          FailureCode.staleResult,
        );
      },
    );

    test('cancel and calendar commit follow the SQL queue order', () async {
      final cancelledStore = await _openStore();
      final cancelledTicket = await _beginCalendar(cancelledStore);
      final cancelledPartition = await _stagePartition(
        cancelledStore,
        cancelledTicket,
      );
      final cancelledArtifact = _calendarArtifact(
        cancelledTicket,
        cancelledPartition,
        rows: [_calendarRow(_opaqueEventId, itemId: 'activity-17')],
      );
      expect(await cancelledStore.cancelYoungJob(cancelledTicket), isTrue);
      await _expectAppFailure(
        cancelledStore.importYoungCalendar(cancelledTicket, cancelledArtifact),
        FailureCode.cancelled,
      );
      expect((await cancelledStore.readYoungView()).importCount, 0);

      final reachedCommit = Completer<void>();
      final allowCommit = Completer<void>();
      final committingStore = await _openStore(
        onYoungCheckpoint: (checkpoint) async {
          if (checkpoint == YoungStoreCheckpoint.beforeCommit) {
            if (!reachedCommit.isCompleted) {
              reachedCommit.complete();
            }
            await allowCommit.future;
          }
        },
      );
      final committingTicket = await _beginCalendar(committingStore);
      final committingPartition = await _stagePartition(
        committingStore,
        committingTicket,
      );
      final committingArtifact = _calendarArtifact(
        committingTicket,
        committingPartition,
        rows: [_calendarRow(_opaqueEventId, itemId: 'activity-17')],
      );
      final import = committingStore.importYoungCalendar(
        committingTicket,
        committingArtifact,
      );
      try {
        await reachedCommit.future.timeout(const Duration(seconds: 5));
        final cancellation = committingStore.cancelYoungJob(committingTicket);
        allowCommit.complete();
        expect((await import).replayed, isFalse);
        expect(await cancellation, isFalse);
        expect((await committingStore.readYoungView()).importCount, 1);
      } finally {
        if (!allowCommit.isCompleted) {
          allowCommit.complete();
        }
      }
    });

    test(
      'calendar sync preserves local identity and hidden state through content and association updates',
      () async {
        final store = await _openStore();
        final firstTicket = await _beginCalendar(store);
        final firstPartition = await _stagePartition(store, firstTicket);
        final firstArtifact = _calendarArtifact(
          firstTicket,
          firstPartition,
          rows: [
            _calendarRow(
              _opaqueEventId,
              itemId: 'activity-old',
              title: 'Synthetic event, first version',
            ),
          ],
        );
        await store.importYoungCalendar(firstTicket, firstArtifact);
        final original = (await store.readYoungView()).events.single;
        final hideCommand = await _hiddenCommand(
          store,
          event: original,
          hidden: true,
        );
        final hiddenReceipt = await store.setYoungHidden(hideCommand);
        expect(hiddenReceipt.hidden, isTrue);

        final secondTicket = await _beginCalendar(store);
        final secondPartition = await _stagePartition(store, secondTicket);
        final secondArtifact = _calendarArtifact(
          secondTicket,
          secondPartition,
          rows: [
            _calendarRow(
              _opaqueEventId,
              itemId: 'activity-new',
              title: 'Synthetic event, updated version',
            ),
          ],
        );
        await store.importYoungCalendar(secondTicket, secondArtifact);
        final updated = (await store.readYoungView()).events.single;
        expect(updated.localId, original.localId);
        expect(updated.title, 'Synthetic event, updated version');
        expect(updated.hidden, isTrue);
        expect(updated.version, greaterThan(hiddenReceipt.resultVersion));
        final association = await store
            .customSelect(
              'SELECT item_id FROM young_events WHERE local_id = ?',
              variables: [Variable.withInt(updated.localId)],
            )
            .getSingle();
        expect(association.read<String>('item_id'), 'activity-new');

        final restore = await _hiddenCommand(
          store,
          event: updated,
          hidden: false,
        );
        final restoredReceipt = await store.setYoungHidden(restore);
        final restored = (await store.readYoungView()).events.single;
        expect(restored.localId, original.localId);
        expect(restored.hidden, isFalse);
        expect(restoredReceipt.hidden, isFalse);
      },
    );

    test(
      'scope absence marks intersecting facts missing and retains outside facts until they return',
      () async {
        final store = await _openStore();
        final wideFirst = DateTime.utc(2026, 6, 1);
        final wideLast = DateTime.utc(2026, 6, 3);
        final firstTicket = await _beginCalendar(
          store,
          firstDay: wideFirst,
          lastDay: wideLast,
        );
        final firstPartition = await _stagePartition(store, firstTicket);
        final firstArtifact = _calendarArtifact(
          firstTicket,
          firstPartition,
          firstDay: wideFirst,
          lastDay: wideLast,
          rows: [
            _calendarRow(
              'synthetic-outside-range',
              date: '2026-06-01',
              itemId: 'activity-1',
              title: 'Synthetic event outside',
            ),
            _calendarRow(
              'synthetic-in-range',
              date: '2026-06-02',
              itemId: 'activity-2',
              title: 'Synthetic event',
            ),
          ],
        );
        await store.importYoungCalendar(firstTicket, firstArtifact);
        final before = {
          for (final event in (await store.readYoungView()).events)
            event.title: event,
        };

        final targetDay = DateTime.utc(2026, 6, 2);
        final emptyTicket = await _beginCalendar(
          store,
          firstDay: targetDay,
          lastDay: targetDay,
        );
        final emptyPartition = await _stagePartition(store, emptyTicket);
        await store.importYoungCalendar(
          emptyTicket,
          _calendarArtifact(
            emptyTicket,
            emptyPartition,
            firstDay: targetDay,
            lastDay: targetDay,
            rows: const [],
          ),
        );
        final missing = {
          for (final event in (await store.readYoungView()).events)
            event.title: event,
        };
        expect(missing, hasLength(2));
        expect(
          missing['Synthetic event']?.presence,
          YoungPresence.missingWithinScope,
        );
        expect(
          missing['Synthetic event']?.localId,
          before['Synthetic event']?.localId,
        );
        expect(
          missing['Synthetic event outside']?.presence,
          YoungPresence.outsideScope,
        );
        expect(
          missing['Synthetic event outside']?.localId,
          before['Synthetic event outside']?.localId,
        );

        final returnTicket = await _beginCalendar(
          store,
          firstDay: targetDay,
          lastDay: targetDay,
        );
        final returnPartition = await _stagePartition(store, returnTicket);
        await store.importYoungCalendar(
          returnTicket,
          _calendarArtifact(
            returnTicket,
            returnPartition,
            firstDay: targetDay,
            lastDay: targetDay,
            rows: [
              _calendarRow(
                'synthetic-in-range',
                date: '2026-06-02',
                itemId: 'activity-2',
              ),
            ],
          ),
        );
        final returned = {
          for (final event in (await store.readYoungView()).events)
            event.title: event,
        };
        expect(returned, hasLength(2));
        expect(returned['Synthetic event']?.presence, YoungPresence.observed);
        expect(
          returned['Synthetic event']?.localId,
          before['Synthetic event']?.localId,
        );
        expect(
          returned['Synthetic event outside']?.presence,
          YoungPresence.outsideScope,
        );
      },
    );

    test(
      'C1-excluded unlinked calendar rows are counted but never stored',
      () async {
        final store = await _openStore();
        final ticket = await _beginCalendar(store);
        final partition = await _stagePartition(store, ticket);
        final artifact = _calendarArtifact(
          ticket,
          partition,
          rows: [
            _calendarRow('synthetic-linked', itemId: 'activity-linked'),
            _calendarRow(
              'synthetic-unlinked',
              itemId: null,
              title: 'Synthetic unlinked row',
            ),
          ],
        );
        expect(artifact.stats.calendarRows, 2);
        expect(artifact.stats.excludedSchedules, 1);
        expect(artifact.stats.events, 1);
        await store.importYoungCalendar(ticket, artifact);

        final view = await store.readYoungView();
        expect(view.events, hasLength(1));
        final persisted = await store
            .customSelect('SELECT external_id, item_id FROM young_events')
            .get();
        expect(persisted, hasLength(1));
        expect(
          persisted.single.read<String>('external_id'),
          'synthetic-linked',
        );
        expect(persisted.single.read<String>('item_id'), 'activity-linked');
      },
    );

    test(
      'hidden commands enforce version, intent replay, owner, and reset epoch',
      () async {
        final store = await _openStore();
        final ticket = await _beginCalendar(store);
        final partition = await _stagePartition(store, ticket);
        await store.importYoungCalendar(
          ticket,
          _calendarArtifact(
            ticket,
            partition,
            rows: [_calendarRow(_opaqueEventId, itemId: 'activity-17')],
          ),
        );
        final event = (await store.readYoungView()).events.single;
        final command = await _hiddenCommand(store, event: event, hidden: true);
        final first = await store.setYoungHidden(command);
        final auditAfterWrite = (await store.readYoungView()).auditCount;
        final replay = await store.setYoungHidden(command);
        expect(first.replayed, isFalse);
        expect(replay.replayed, isTrue);
        expect(replay.resultVersion, first.resultVersion);
        expect((await store.readYoungView()).auditCount, auditAfterWrite);

        await _expectAppFailure(
          store.setYoungHidden(
            YoungHiddenCommand(
              operationId: command.operationId,
              ownerId: command.ownerId,
              accountId: command.accountId,
              resetEpoch: command.resetEpoch,
              localId: command.localId,
              expectedVersion: command.expectedVersion,
              hidden: false,
            ),
          ),
          FailureCode.idempotencyConflict,
        );
        await _expectAppFailure(
          store.setYoungHidden(
            await _hiddenCommand(store, event: event, hidden: false),
          ),
          FailureCode.staleResult,
        );
        await _expectAppFailure(
          store.setYoungHidden(
            YoungHiddenCommand(
              operationId: _nextHiddenOperationId(),
              ownerId: _ownerOther,
              accountId: 1,
              resetEpoch: command.resetEpoch,
              localId: event.localId,
              expectedVersion: first.resultVersion,
              hidden: false,
            ),
          ),
          FailureCode.ownershipLost,
        );
        await _expectAppFailure(
          store.setYoungHidden(
            YoungHiddenCommand(
              operationId: _nextHiddenOperationId(),
              ownerId: command.ownerId,
              accountId: 1,
              resetEpoch: command.resetEpoch + 1,
              localId: event.localId,
              expectedVersion: first.resultVersion,
              hidden: false,
            ),
          ),
          FailureCode.staleResult,
        );
        final unchanged = (await store.readYoungView()).events.single;
        expect(unchanged.hidden, isTrue);
        expect(unchanged.version, first.resultVersion);
      },
    );

    test(
      'revoking Young permits leaves JW permit, password, catalog, and events intact',
      () async {
        final store = await _openStore();
        final jw = await _seedJwLedger(store);
        final ticket = await _beginCalendar(store);
        final partition = await _stagePartition(store, ticket);
        await store.importYoungCalendar(
          ticket,
          _calendarArtifact(
            ticket,
            partition,
            rows: [_calendarRow(_opaqueEventId, itemId: 'activity-17')],
          ),
        );
        expect(await store.readYoungPermits(), hasLength(1));
        final beforeView = await store.readView();
        final beforePermits = await store.readCommittedPermits();
        final beforeCiphertext = await _credentialCiphertext(store);
        expect(beforeCiphertext, isNotNull);
        final beforeCatalog = await _catalogJson(store);
        final beforeAuthority = await store.readAuthority();

        await store.revokeYoungPermits();

        expect(await store.readYoungPermits(), isEmpty);
        final youngAfter = await store.readYoungView();
        expect(youngAfter.events, hasLength(1));
        expect(youngAfter.importCount, 1);

        final afterView = await store.readView();
        expect(_jwFacts(afterView), _jwFacts(beforeView));
        final afterPermits = await store.readCommittedPermits();
        expect(afterPermits, hasLength(beforePermits.length));
        expect(afterPermits.single.partition.sameAs(jw.partition), isTrue);
        expect(
          afterPermits.single.partition.sameAs(beforePermits.single.partition),
          isTrue,
        );
        final afterCiphertext = await _credentialCiphertext(store);
        expect(afterCiphertext, isNotNull);
        expect(afterCiphertext!, orderedEquals(beforeCiphertext!));
        expect(await _catalogJson(store), beforeCatalog);
        final afterAuthority = await store.readAuthority();
        expect(afterAuthority.ownerId, beforeAuthority.ownerId);
        expect(afterAuthority.resetEpoch, beforeAuthority.resetEpoch);
      },
    );

    test(
      'v1, v2, and v3 synthetic copies upgrade to v17 and retain their JW facts',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'young-store-migration-',
        );
        addTearDown(() async {
          if (await directory.exists()) {
            await directory.delete(recursive: true);
          }
        });
        final template = File(
          '${directory.path}${Platform.pathSeparator}template.sqlite',
        );
        final templateStore = await _openFileStore(template);
        final jw = await _seedJwLedger(templateStore);
        await templateStore.close();

        for (final version in [1, 2, 3]) {
          final file = File(
            '${directory.path}${Platform.pathSeparator}v$version.sqlite',
          );
          await template.copy(file.path);
          _setSyntheticSchemaVersion(file, version);

          final upgraded = await _openFileStore(file);
          expect(
            (await upgraded.customSelect('PRAGMA user_version').getSingle())
                .read<int>('user_version'),
            JwStore.currentSchemaVersion,
          );
          for (final table in ['jw_events', 'young_events']) {
            expect(
              (await upgraded.customSelect('PRAGMA table_info($table)').get())
                  .where((row) => row.read<String>('name') == 'source_retired'),
              hasLength(1),
            );
          }
          final view = await upgraded.readView();
          expect(view.accountBound, isTrue);
          expect(view.courseCount, 1);
          expect(view.examCount, 0);
          expect(view.importCount, 1);
          expect(view.auditCount, 1);
          expect(view.events, hasLength(1));
          expect(view.events.single.localId, jw.eventLocalId);
          expect(view.events.single.hidden, isTrue);
          expect(view.events.single.sourceRetired, isFalse);
          final storedEvent = await upgraded
              .customSelect(
                'SELECT external_id FROM jw_events WHERE local_id = ?',
                variables: [Variable.withInt(jw.eventLocalId)],
              )
              .getSingle();
          expect(storedEvent.read<String>('external_id'), 'synthetic-jw-event');
          expect(view.credentialSaved, version >= 2);
          expect(view.lastSemesterId, version >= 2 ? 202610 : isNull);
          expect(view.cachedSemesters, version == 3 ? hasLength(1) : isEmpty);
          final authority = await upgraded.readAuthority();
          expect(authority.ownerId, jw.ownerId);
          final permits = await upgraded.readCommittedPermits();
          expect(permits, hasLength(1));
          expect(permits.single.partition.sameAs(jw.partition), isTrue);
          final oldReceipt = await upgraded
              .customSelect(
                'SELECT operation_id,job_id,content_fingerprint,course_count,exam_count '
                'FROM jw_imports',
              )
              .getSingle();
          expect(
            oldReceipt.read<String>('operation_id'),
            'jw-import-synthetic',
          );
          expect(oldReceipt.read<String>('job_id'), 'jw-0-1');
          expect(
            oldReceipt.read<String>('content_fingerprint'),
            List<String>.filled(64, 'a').join(),
          );
          expect(oldReceipt.read<int>('course_count'), 1);
          expect(oldReceipt.read<int>('exam_count'), 0);
          expect(await _count(upgraded, 'jw_local_receipts'), 1);

          final youngAuthority = await upgraded.readYoungAuthority();
          expect(youngAuthority.ownerId, jw.ownerId);
          expect(youngAuthority.accountBound, isTrue);
          expect((await upgraded.readYoungView()).events, isEmpty);
          expect(await upgraded.readYoungPermits(), isEmpty);
          expect(await _tableExists(upgraded, 'young_events'), isTrue);
          expect(
            await _credentialCiphertext(upgraded),
            version >= 2 ? orderedEquals(jw.ciphertext) : isNull,
          );
          await upgraded.close();
        }
      },
    );

    test(
      'tickets, artifacts, receipts, views, and collection summaries do not stringify private values',
      () async {
        final store = await _openStore();
        final ticket = await _beginCalendar(store);
        final partition = await _stagePartition(store, ticket);
        final artifact = _calendarArtifact(
          ticket,
          partition,
          rows: [
            _calendarRow(
              _opaqueEventId,
              itemId: _opaqueActivityId,
              title: 'Synthetic private title',
            ),
          ],
        );
        final receipt = await store.importYoungCalendar(ticket, artifact);
        final view = await store.readYoungView();
        final values = <Object>[
          ticket,
          ticket.stamp,
          partition,
          receipt.permit,
          artifact,
          artifact.stats,
          receipt,
          view,
          view.events.single,
          await store.readYoungAuthority(),
        ];
        for (final value in values) {
          final text = value.toString();
          expect(text, isNot(contains(_account)));
          expect(text, isNot(contains(partition.id)));
          expect(text, isNot(contains(partition.ownerId)));
          expect(text, isNot(contains(_opaqueEventId)));
          expect(text, isNot(contains(_opaqueActivityId)));
        }
        final summary = jsonEncode(artifact.stats.safeProjection);
        expect(summary, isNot(contains(_account)));
        expect(summary, isNot(contains(partition.id)));
        expect(summary, isNot(contains(_opaqueEventId)));
        expect(
          () => jsonEncode(ticket),
          throwsA(isA<JsonUnsupportedObjectError>()),
        );
      },
    );
  });
}

Future<JwStore> _openStore({
  Future<void> Function(YoungStoreCheckpoint)? onYoungCheckpoint,
}) => _openDatabase(
  NativeDatabase.memory(),
  onYoungCheckpoint: onYoungCheckpoint,
);

Future<JwStore> _openFileStore(
  File file, {
  Future<void> Function(YoungStoreCheckpoint)? onYoungCheckpoint,
}) => _openDatabase(
  NativeDatabase(file, logStatements: false),
  onYoungCheckpoint: onYoungCheckpoint,
);

Future<JwStore> _openDatabase(
  QueryExecutor executor, {
  Future<void> Function(YoungStoreCheckpoint)? onYoungCheckpoint,
}) async {
  final store = JwStore(
    executor,
    ownership: _TestOwnership(),
    clock: FixedClock(DateTime.utc(2026, 10, 11, 12)),
    onYoungCheckpoint: onYoungCheckpoint,
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

Future<YoungJobTicket> _beginCalendar(
  JwStore store, {
  DateTime? firstDay,
  DateTime? lastDay,
}) => store.beginYoungJob(
  kind: YoungJobKind.calendar,
  expectedAccountCode: _account,
  firstDay: firstDay ?? _startDay,
  lastDay: lastDay ?? _startDay,
);

Future<YoungPartitionRef> _stagePartition(
  JwStore store,
  YoungJobTicket ticket,
) async {
  final sequence = ++_partitionSequence;
  final ref = YoungPartitionRef(
    id: 'yp-${sequence.toRadixString(16).padLeft(32, '0')}',
    ownerId: ticket.stamp.ownerId,
    purpose: ticket.stamp.accountId == null
        ? YoungPartitionPurpose.initial
        : YoungPartitionPurpose.recovery,
    attempt: ticket.stamp.jobId,
    resetEpoch: ticket.stamp.resetEpoch,
  );
  await store.stageYoungPartition(ticket, ref);
  return ref;
}

YoungCollectedArtifact _calendarArtifact(
  YoungJobTicket ticket,
  YoungPartitionRef partition, {
  String username = _account,
  DateTime? firstDay,
  DateTime? lastDay,
  List<Map<String, Object?>> rows = const [],
}) {
  final first = firstDay ?? ticket.firstDay!;
  final last = lastDay ?? ticket.lastDay!;
  final days = last.difference(first).inDays + 1;
  final decoded = decodeYoungCalendarPage({
    'success': true,
    'code': 200,
    'result': {'records': rows, 'total': rows.length},
  }).records;
  final linked = decoded.where((entry) => entry.itemId != null).toList();
  return YoungCollectedArtifact.seal(
    profileBefore: _profile(username),
    profileAfter: _profile(username),
    stamp: ticket.stamp,
    partition: partition,
    session: 1,
    document: 2,
    operation: 3,
    collectedAtUtc: DateTime.utc(2026, 10, 11, 12),
    activities: const [],
    entries: linked,
    activityPages: 0,
    calendarPages: days,
    calendarRows: rows.length,
    excludedSchedules: decoded.length - linked.length,
    days: days,
    firstDay: first,
    lastDay: last,
  );
}

YoungCollectedArtifact _activitiesArtifact(
  YoungJobTicket ticket,
  YoungPartitionRef partition, {
  String username = _account,
  String itemName = 'Synthetic activity',
}) {
  final activities = decodeYoungActivityPage({
    'success': true,
    'code': 200,
    'result': {
      'records': [
        {
          'id': 'synthetic-activity-19',
          'itemName': itemName,
          'st': '2026-06-10 09:00:00',
          'et': '2026-06-10 10:00:00',
          'applySt': '2026-06-01 08:00:00',
          'applyEt': '2026-06-09 20:00:00',
          'placeInfo': 'Synthetic room',
        },
      ],
      'total': 1,
    },
  }).records;
  return YoungCollectedArtifact.seal(
    profileBefore: _profile(username),
    profileAfter: _profile(username),
    stamp: ticket.stamp,
    partition: partition,
    session: 1,
    document: 2,
    operation: 3,
    collectedAtUtc: DateTime.utc(2026, 10, 11, 12),
    activities: activities,
    entries: const [],
    activityPages: 1,
    calendarPages: 0,
    calendarRows: 0,
    excludedSchedules: 0,
    days: 0,
    firstDay: null,
    lastDay: null,
  );
}

YoungProfileCandidate _profile(String username) => decodeYoungProfile({
  'success': true,
  'code': 200,
  'result': {'username': username},
});

Map<String, Object?> _calendarRow(
  String id, {
  String date = '2026-06-10',
  String? itemId,
  String title = 'Synthetic event',
}) => {
  'id': id,
  'title': title,
  'place': 'Synthetic campus',
  'startTime': '$date 09:00:00',
  'endTime': '$date 10:00:00',
  'itemId': itemId,
};

Future<YoungHiddenCommand> _hiddenCommand(
  JwStore store, {
  required YoungStoredEvent event,
  required bool hidden,
}) async {
  final authority = await store.readYoungAuthority();
  return YoungHiddenCommand(
    operationId: _nextHiddenOperationId(),
    ownerId: authority.ownerId,
    accountId: 1,
    resetEpoch: authority.resetEpoch,
    localId: event.localId,
    expectedVersion: event.version,
    hidden: hidden,
  );
}

String _nextHiddenOperationId() =>
    'young-local-${(++_hiddenOperationSequence).toRadixString(16).padLeft(32, '0')}';

Future<void> _seedCanonicalAccount(JwStore store, String account) async {
  await store.customStatement(
    'INSERT INTO jw_account (account_id, expected_account_code) VALUES (1, ?)',
    [account],
  );
}

final class _SyntheticJwFacts {
  const _SyntheticJwFacts({
    required this.ownerId,
    required this.partition,
    required this.eventLocalId,
    required this.ciphertext,
  });

  final String ownerId;
  final JwPartitionRef partition;
  final int eventLocalId;
  final Uint8List ciphertext;
}

Future<_SyntheticJwFacts> _seedJwLedger(JwStore store) async {
  final authority = await store.readAuthority();
  await _seedCanonicalAccount(store, _account);
  final partition = JwPartitionRef(
    id: 'jwp-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    ownerId: authority.ownerId,
    purpose: JwPartitionPurpose.initial,
    attempt: 'jw-${authority.resetEpoch}-${authority.generation}',
    resetEpoch: authority.resetEpoch,
  );
  final committedAt = DateTime.utc(2026, 10, 11, 12).microsecondsSinceEpoch;
  const eventLocalId = 41;
  final ciphertext = Uint8List.fromList([0x31, 0x92, 0x05, 0xE7]);
  await store.customStatement(
    'INSERT INTO jw_events '
    '(local_id,external_id,kind,semester_id,title,starts_at,ends_at,presence,version) '
    "VALUES (?,?,'course',202610,?,?,?,'observed',1)",
    [
      eventLocalId,
      'synthetic-jw-event',
      'Synthetic retained JW event',
      DateTime.utc(2026, 6, 10, 1).microsecondsSinceEpoch,
      DateTime.utc(2026, 6, 10, 2).microsecondsSinceEpoch,
    ],
  );
  await store.customStatement(
    'INSERT INTO jw_overlays (local_id,hidden) VALUES (?,1)',
    [eventLocalId],
  );
  await store.customStatement(
    'INSERT INTO jw_imports '
    '(operation_id,job_id,content_fingerprint,partition_metadata,course_count,exam_count,account_id,committed_at) '
    'VALUES (?,?,?,?,1,0,1,?)',
    [
      'jw-import-synthetic',
      'jw-0-1',
      List<String>.filled(64, 'a').join(),
      jsonEncode(partition.metadata),
      committedAt,
    ],
  );
  await store.customStatement(
    'INSERT INTO jw_audit (action,course_count,exam_count,committed_at) '
    "VALUES ('import',1,0,?)",
    [committedAt],
  );
  await store.customStatement(
    'INSERT INTO jw_permits (partition_id,partition_metadata,account_id) VALUES (?,?,1)',
    [partition.id, jsonEncode(partition.metadata)],
  );
  await store.customStatement(
    'INSERT INTO jw_local_receipts (operation_id,fingerprint,result_version,hidden,committed_at) '
    'VALUES (?,?,?,?,?)',
    [
      'jw-local-00000000000000000000000000000001',
      List<String>.filled(64, 'b').join(),
      2,
      1,
      committedAt,
    ],
  );
  await store.customStatement(
    'INSERT INTO jw_credentials (account_id,mechanism,ciphertext) VALUES (1,?,?)',
    ['synthetic-test-protector', ciphertext],
  );
  await store.customStatement(
    'INSERT INTO jw_preferences (account_id,semester_id) VALUES (1,202610)',
  );
  await store.customStatement(
    'INSERT INTO jw_semester_catalog (account_id,options_json,updated_at) VALUES (1,?,?)',
    [
      jsonEncode([
        {'id': 202610, 'name': 'Synthetic 2026 autumn', 'selected': true},
      ]),
      committedAt,
    ],
  );
  return _SyntheticJwFacts(
    ownerId: authority.ownerId,
    partition: partition,
    eventLocalId: eventLocalId,
    ciphertext: ciphertext,
  );
}

void _setSyntheticSchemaVersion(File file, int version) {
  final database = sqlite3.sqlite3.open(file.path);
  try {
    _dropM6TablesForLegacyFixture(database);
    removeCalendarTablesForLegacyFixture(database);
    _removeSchema14AgentObjectsForLegacyFixture(database);
    for (final table in [
      'knowledge_load_items',
      'knowledge_sections',
      'knowledge_audit',
      'knowledge_loads',
      'knowledge_materials',
      'knowledge_state',
      'public_sources',
    ]) {
      database.execute('DROP TABLE $table');
    }
    for (final table in [
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
    if (version == 1) {
      database.execute('DROP TABLE jw_semester_catalog');
      database.execute('DROP TABLE jw_credentials');
      database.execute('DROP TABLE jw_preferences');
      database.execute('DROP TABLE jw_credential_audit');
    } else if (version == 2) {
      database.execute('DROP TABLE jw_semester_catalog');
    }
    database.execute('PRAGMA user_version = $version');
  } finally {
    database.close();
  }
}

void _dropM6TablesForLegacyFixture(sqlite3.Database database) {
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

Future<bool> _tableExists(JwStore store, String name) async {
  final row = await store
      .customSelect(
        "SELECT COUNT(*) AS count FROM sqlite_master WHERE type='table' AND name=?",
        variables: [Variable.withString(name)],
      )
      .getSingle();
  return row.read<int>('count') == 1;
}

Future<int> _count(JwStore store, String table) async {
  if (!RegExp(r'^[a-z_]+$').hasMatch(table)) {
    throw ArgumentError.value(table);
  }
  final row = await store
      .customSelect('SELECT COUNT(*) AS count FROM $table')
      .getSingle();
  return row.read<int>('count');
}

Future<Uint8List?> _credentialCiphertext(JwStore store) async {
  final row = await store
      .customSelect('SELECT ciphertext FROM jw_credentials WHERE account_id=1')
      .getSingleOrNull();
  final value = row?.read<Uint8List>('ciphertext');
  return value == null ? null : Uint8List.fromList(value);
}

Future<String?> _catalogJson(JwStore store) async =>
    (await store
            .customSelect(
              'SELECT options_json FROM jw_semester_catalog WHERE account_id=1',
            )
            .getSingleOrNull())
        ?.read<String>('options_json');

Object _jwFacts(JwDataView view) => [
  view.accountBound,
  view.courseCount,
  view.examCount,
  view.importCount,
  view.auditCount,
  view.credentialSaved,
  view.lastSemesterId,
  view.cachedSemesters
      .map((option) => (option.id, option.name, option.selected))
      .toList(),
  view.semesterCatalogUpdatedAtUtc,
  view.events
      .map(
        (event) => (
          event.localId,
          event.version,
          event.kind,
          event.semesterId,
          event.title,
          event.startsAtUtc,
          event.endsAtUtc,
          event.presence,
          event.hidden,
        ),
      )
      .toList(),
];

Future<void> _expectAppFailure(
  Future<dynamic> operation,
  FailureCode code,
) async {
  await expectLater(
    operation,
    throwsA(
      isA<AppFailure>().having((error) => error.code, 'failure code', code),
    ),
  );
}

Future<void> _expectYoungIdentity(
  Future<dynamic> operation,
  YoungIdentityFailure code,
) async {
  await expectLater(
    operation,
    throwsA(
      isA<YoungIdentityException>().having(
        (error) => error.code,
        'identity failure',
        code,
      ),
    ),
  );
}

final class _TestOwnership implements AssetOwnership {
  @override
  bool get isHeld => true;

  @override
  void ensureHeld() {}
}
