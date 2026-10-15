import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/jw_credentials.dart';
import 'package:ustc_assistant_m0/core/settings_contract.dart';
import 'package:ustc_assistant_m0/core/young_daily_sync_contract.dart';
import 'package:ustc_assistant_m0/core/young_work_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/source/young_business_contract.dart';
import 'package:ustc_assistant_m0/source/young_collection_contract.dart';

const _account = 'DAILYFIXTURE001';
final _today = DateTime.utc(2026, 10, 15);
final _first = _today.subtract(const Duration(days: 1));
final _end = _first.add(const Duration(days: 31));
int _sequence = 0;

void main() {
  test(
    'opt-in, saved credentials, exact range and one job bind each grant',
    () async {
      final h = await _Harness.open(seed: false);
      expect((await h.store.youngDaily.inspect()).enabled, isFalse);
      expect(await h.store.youngDaily.claim(), isNull);
      await h.enable();
      expect(await h.store.youngDaily.claim(), isNull);
      await h.seed();
      final grant = (await h.store.youngDaily.claim())!;
      expect(grant.firstDay, _first);
      expect(grant.endDayExclusive, _end);
      expect(await h.store.youngDaily.claim(), isNull);
      await expectLater(
        h.store.beginYoungJob(kind: YoungJobKind.activities, dailyGrant: grant),
        throwsA(isA<AppFailure>()),
      );
      await expectLater(
        h.prepare(first: _today, end: _end, grant: grant),
        throwsA(isA<AppFailure>()),
      );
      final (ticket, _) = await h.prepare(grant: grant);
      await expectLater(h.prepare(grant: grant), throwsA(isA<AppFailure>()));
      await h.store.cancelYoungJob(ticket);
      await h.store.youngDaily.finish(grant, YoungDailySyncOutcome.interrupted);
    },
  );

  test(
    'automatic commit keeps manual range and updates calendar and reminders atomically',
    () async {
      final h = await _Harness.open();
      final history = DateTime.utc(2026, 9, 1);
      await h.import(first: history, end: history.add(const Duration(days: 2)));
      expect((await h.store.youngDaily.inspect()).lastSuccessAtUtc, isNull);
      await h.enable();
      final grant = (await h.store.youngDaily.claim())!;
      final current = await h.store.features.inspectReminders();
      await h.store.features.saveReminderPreferences(
        current,
        current.preferences.copyWith(enabled: true),
      );
      await h.import(grant: grant, withEvent: true);
      final daily = await h.store.youngDaily.inspect();
      expect(daily.lastSuccessAtUtc, h.clock.nowUtc);
      expect(daily.successFirstDay, _first);
      expect(daily.successEndDayExclusive, _end);
      final source = await h.store.readYoungView();
      expect(source.firstDay, history);
      expect(source.lastDay, history.add(const Duration(days: 1)));
      expect(source.importCount, 2);
      final window = await h.store.localCalendar.query(
        CalendarQuery(firstDay: _first, endDayExclusive: _end),
      );
      expect(window.items.single.title, 'Synthetic daily event');
      final publication = await h.store.features.prepareReminderPublication();
      expect(publication.desired, hasLength(1));
      await h.store.youngDaily.finish(grant, YoungDailySyncOutcome.failed);
      expect((await h.store.youngDaily.inspect()).nextAttemptAtUtc, isNull);
      expect(await h.store.youngDaily.claim(), isNull);

      // Explicit historical reads never overwrite the same-day full coverage.
      h.clock.nowUtc = h.clock.nowUtc.add(const Duration(minutes: 1));
      await h.import(first: history, end: history.add(const Duration(days: 1)));
      final afterHistory = await h.store.youngDaily.inspect();
      expect(afterHistory.lastSuccessAtUtc, daily.lastSuccessAtUtc);
      expect(afterHistory.successEndDayExclusive, _end);
    },
  );

  test(
    'a full manual range satisfies the day, but activities and partial dates do not',
    () async {
      final h = await _Harness.open();
      await h.enable();
      final (queryTicket, query) = await h.prepare(activities: true);
      await h.store.completeYoungQuery(queryTicket, query);
      expect((await h.store.youngDaily.inspect()).lastSuccessAtUtc, isNull);
      await h.import(first: _today, end: _end);
      expect((await h.store.youngDaily.inspect()).lastSuccessAtUtc, isNull);
      await h.import();
      expect(await h.store.youngDaily.claim(), isNull);
      expect((await h.store.youngDaily.inspect()).attempts, 0);
    },
  );

  for (final advice in [false, true]) {
    test(
      '${advice ? "advice restriction" : "disable"} revokes secrets before queued SQL and rolls back import',
      () async {
        final entered = Completer<void>(), release = Completer<void>();
        final h = await _Harness.open(
          onCheckpoint: (point) async {
            if (point == YoungStoreCheckpoint.beforeCommit) {
              entered.complete();
              await release.future;
            }
          },
        );
        await h.enable();
        final grant = (await h.store.youngDaily.claim())!;
        final (ticket, artifact) = await h.prepare(
          grant: grant,
          withEvent: true,
        );
        final lease = (await h.store.leaseYoungCredentials(ticket))!;
        final before = await h.store.youngDaily.inspect();
        final rejected = expectLater(
          h.store.importYoungCalendar(ticket, artifact),
          throwsA(isA<AppFailure>()),
        );
        await entered.future;
        Future<void>? saving;
        if (advice) {
          h.store.youngDaily.restrictToAdvice(true);
        } else {
          saving = h.store.youngDaily
              .setEnabled(before.context, false)
              .then((_) {});
        }
        expect(lease.take, throwsA(isA<JwCredentialException>()));
        release.complete();
        await rejected;
        await saving;
        final source = await h.store.readYoungView();
        expect(source.events, isEmpty);
        expect(source.importCount, 0);
        expect(source.auditCount, 0);
        expect((await h.store.youngDaily.inspect()).lastSuccessAtUtc, isNull);
        await h.store.youngDaily.finish(
          grant,
          YoungDailySyncOutcome.interrupted,
        );
      },
    );
  }

  test(
    'revocation during the final ownership/database guard rejects the last write',
    () async {
      // First measure the final guard in this behavior, then revoke inside that
      // guard on an otherwise identical isolated transaction. This exercises a
      // restriction after the grant's earlier asynchronous validation.
      var calls = 0;
      final baselineOwner = _Ownership();
      final baseline = await _Harness.open(
        onCheckpoint: (point) async {
          if (point == YoungStoreCheckpoint.beforeCommit) {
            baselineOwner.onCheck = () => calls++;
          }
        },
        owner: baselineOwner,
      );
      await baseline.enable();
      final baseGrant = (await baseline.store.youngDaily.claim())!;
      await baseline.import(grant: baseGrant, withEvent: true);
      final finalGuard = calls;
      baselineOwner.onCheck = null;
      expect(finalGuard, greaterThan(1));

      final owner = _Ownership();
      late _Harness h;
      var seen = 0;
      h = await _Harness.open(
        owner: owner,
        onCheckpoint: (point) async {
          if (point == YoungStoreCheckpoint.beforeCommit) {
            owner.onCheck = () {
              if (++seen == finalGuard) {
                h.store.youngDaily.restrictToAdvice(true);
              }
            };
          }
        },
      );
      await h.enable();
      final grant = (await h.store.youngDaily.claim())!;
      await expectLater(
        h.import(grant: grant, withEvent: true),
        throwsA(isA<AppFailure>()),
      );
      owner.onCheck = null;
      expect(seen, finalGuard);
      expect((await h.store.readYoungView()).events, isEmpty);
      expect((await h.store.youngDaily.inspect()).lastSuccessAtUtc, isNull);
      await h.store.youngDaily.finish(grant, YoungDailySyncOutcome.interrupted);
    },
  );

  test(
    'SQL failure records no daily success and preserves an existing event',
    () async {
      var fail = false;
      final h = await _Harness.open(
        onCheckpoint: (point) async {
          if (fail && point == YoungStoreCheckpoint.beforeCommit) {
            throw const AppFailure(FailureCode.storageFailed);
          }
        },
      );
      await h.import(
        first: _today,
        end: _today.add(const Duration(days: 2)),
        withEvent: true,
      );
      final before = (await h.store.readYoungView()).events.single;
      await h.enable();
      final grant = (await h.store.youngDaily.claim())!;
      fail = true;
      await expectLater(h.import(grant: grant), throwsA(isA<AppFailure>()));
      final after = (await h.store.readYoungView()).events.single;
      expect(after.localId, before.localId);
      expect(after.sourceRetired, isFalse);
      expect((await h.store.youngDaily.inspect()).lastSuccessAtUtc, isNull);
      await h.store.youngDaily.finish(grant, YoungDailySyncOutcome.failed);
      expect(await h.store.youngDaily.claim(), isNull);
    },
  );

  test(
    'restart recovers an interrupted claim without resetting the persisted daily budget',
    () async {
      final h = await _Harness.open();
      await h.enable();
      final old = (await h.store.youngDaily.claim())!;
      expect((await h.store.youngDaily.inspect()).attempts, 1);
      await h.store.initialize();
      expect(await h.store.youngDaily.claim(), isNull);
      await expectLater(h.prepare(grant: old), throwsA(isA<AppFailure>()));
      h.clock.nowUtc = h.clock.nowUtc.add(const Duration(minutes: 15));
      for (var attempt = 2; attempt <= 3; attempt++) {
        final grant = (await h.store.youngDaily.claim())!;
        expect((await h.store.youngDaily.inspect()).attempts, attempt);
        await h.store.youngDaily.finish(grant, YoungDailySyncOutcome.failed);
        h.clock.nowUtc = h.clock.nowUtc.add(const Duration(minutes: 15));
      }
      expect(await h.store.youngDaily.claim(), isNull);
      h.clock.nowUtc = h.clock.nowUtc.add(const Duration(days: 1));
      final next = (await h.store.youngDaily.claim())!;
      expect((await h.store.youngDaily.inspect()).attempts, 1);
      await h.store.youngDaily.finish(next, YoungDailySyncOutcome.interrupted);
    },
  );

  test(
    'clear agenda retains opt-in and suppresses today; reset disables it',
    () async {
      final h = await _Harness.open();
      await h.enable();
      await h.maintain(MaintenanceKind.agenda);
      var snapshot = await h.store.youngDaily.inspect();
      expect(snapshot.enabled, isTrue);
      expect(snapshot.suppressedDay, _today);
      expect(await h.store.youngDaily.claim(), isNull);
      final manual = (await h.store.youngDaily.claim(manual: true))!;
      await h.store.youngDaily.finish(
        manual,
        YoungDailySyncOutcome.interrupted,
      );
      await h.maintain(MaintenanceKind.reset);
      snapshot = await h.store.youngDaily.inspect();
      expect(snapshot.enabled, isFalse);
      expect(snapshot.suppressedDay, isNull);
      expect(snapshot.lastSuccessAtUtc, isNull);
      expect(await h.store.youngDaily.claim(manual: true), isNull);
    },
  );
}

final class _Harness {
  _Harness(this.store, this.clock);
  final JwStore store;
  final _Clock clock;
  static Future<_Harness> open({
    bool seed = true,
    _Ownership? owner,
    Future<void> Function(YoungStoreCheckpoint)? onCheckpoint,
  }) async {
    final clock = _Clock(_today);
    final store = JwStore(
      NativeDatabase.memory(),
      ownership: owner ?? _Ownership(),
      clock: clock,
      credentialProtector: _Protector(),
      onYoungCheckpoint: onCheckpoint,
    );
    addTearDown(store.close);
    await store.initialize();
    await store.agent.initializeAgent();
    await store.features.initialize();
    final h = _Harness(store, clock);
    if (seed) await h.seed();
    return h;
  }

  Future<void> seed() async {
    await store.customStatement(
      'INSERT INTO jw_account(account_id,expected_account_code) VALUES(1,?)',
      [_account],
    );
    final cipher = await _Protector().protect(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'username': _account,
            'password': 'synthetic-password-only',
          }),
        ),
      ),
      purpose: 'synthetic',
    );
    await store.customStatement(
      'INSERT INTO jw_credentials(account_id,mechanism,ciphertext) VALUES(1,?,?)',
      [_Protector().mechanism, cipher],
    );
  }

  Future<void> enable() async {
    final current = await store.youngDaily.inspect();
    await store.youngDaily.setEnabled(current.context, true);
  }

  Future<void> maintain(MaintenanceKind kind) async {
    final settings = await store.applicationSettings.inspectSettings();
    final request = await store.applicationSettings.prepareMaintenance(
      settings.context,
      kind,
      confirmed: true,
    );
    final intent = await store.applicationSettings.beginMaintenance(request);
    await store.applicationSettings.completeMaintenance(intent);
  }

  Future<void> import({
    DateTime? first,
    DateTime? end,
    YoungDailySyncGrant? grant,
    bool withEvent = false,
  }) async {
    final (ticket, artifact) = await prepare(
      first: first,
      end: end,
      grant: grant,
      withEvent: withEvent,
    );
    await store.importYoungCalendar(ticket, artifact);
  }

  Future<(YoungJobTicket, YoungCollectedArtifact)> prepare({
    DateTime? first,
    DateTime? end,
    YoungDailySyncGrant? grant,
    bool withEvent = false,
    bool activities = false,
  }) async {
    first ??= _first;
    end ??= _end;
    final ticket = await store.beginYoungJob(
      kind: activities ? YoungJobKind.activities : YoungJobKind.calendar,
      firstDay: activities ? null : first,
      lastDay: activities ? null : end.subtract(const Duration(days: 1)),
      dailyGrant: grant,
    );
    final partition = YoungPartitionRef(
      id: 'yp-${(++_sequence).toRadixString(16).padLeft(32, '0')}',
      ownerId: ticket.stamp.ownerId,
      purpose: YoungPartitionPurpose.recovery,
      attempt: ticket.stamp.jobId,
      resetEpoch: ticket.stamp.resetEpoch,
    );
    await store.stageYoungPartition(ticket, partition);
    final profile = decodeYoungProfile({
      'success': true,
      'code': 200,
      'result': {'username': _account},
    });
    final rows = decodeYoungCalendarPage({
      'success': true,
      'code': 200,
      'result': {
        'records': [
          if (withEvent)
            {
              'id': 'synthetic-daily-event',
              'itemId': 'synthetic-activity',
              'title': 'Synthetic daily event',
              'place': 'Synthetic room',
              'startTime': '2026-10-16 10:00:00',
              'endTime': '2026-10-16 11:00:00',
            },
        ],
        'total': withEvent ? 1 : 0,
      },
    });
    return (
      ticket,
      YoungCollectedArtifact.seal(
        profileBefore: profile,
        profileAfter: profile,
        stamp: ticket.stamp,
        partition: partition,
        session: 1,
        document: 2,
        operation: 3,
        collectedAtUtc: clock.nowUtc,
        activities: const [],
        entries: activities ? const [] : rows.records,
        activityPages: activities ? 1 : 0,
        calendarPages: activities ? 0 : end.difference(first).inDays,
        calendarRows: activities ? 0 : rows.records.length,
        excludedSchedules: 0,
        days: activities ? 0 : end.difference(first).inDays,
        firstDay: activities ? null : first,
        lastDay: activities ? null : end.subtract(const Duration(days: 1)),
      ),
    );
  }
}

final class _Clock implements AppClock {
  _Clock(this.nowUtc);
  @override
  DateTime nowUtc;
}

final class _Ownership implements AssetOwnership {
  void Function()? onCheck;
  @override
  bool get isHeld => true;
  @override
  void ensureHeld() => onCheck?.call();
}

final class _Protector implements JwCredentialProtector {
  @override
  String get mechanism => 'synthetic-daily-test/v1';
  @override
  Future<Uint8List> protect(
    Uint8List plaintext, {
    required String purpose,
  }) async => Uint8List.fromList(plaintext.map((b) => b ^ 0x5A).toList());
  @override
  Future<Uint8List> unprotect(
    Uint8List ciphertext, {
    required String purpose,
  }) => protect(ciphertext, purpose: purpose);
}
