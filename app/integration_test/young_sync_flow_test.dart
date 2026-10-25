import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/core/young_work_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/data/young_import_contract.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_coordinator.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_port.dart';
import 'package:ustc_assistant_m0/platform/demo_directory.dart';
import 'package:ustc_assistant_m0/platform/native_database.dart';
import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';
import 'package:ustc_assistant_m0/platform/young_partition_registry.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';

import 'support/young_business_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Young query and calendar persist independently through native drain and reopen',
    (tester) async {
      await tester.runAsync(() async {
        final fixture = await YoungBusinessFixture.start();
        fixture.username = 'FIXTURE001';
        final root = await Directory.systemTemp.createTemp('ustc_m2_formal_');
        final harnesses = <_Harness>[];
        try {
          var harness = await _Harness.create(
            p.windows.join(root.path, 'owned'),
            fixture,
          );
          harnesses.add(harness);
          await harness.query(expected: 'FIXTURE001');
          expect(harness.sync.syncView.activityResults, hasLength(11));
          expect(harness.sync.syncView.normalization!.activityPages, 2);
          expect(harness.sync.syncView.data!.events, isEmpty);
          expect(harness.sync.syncView.data!.queryCount, 1);
          // A separate synthetic JW fact is never changed by Young work.
          await harness.store.customStatement(
            "INSERT INTO jw_events (external_id,kind,semester_id,title,starts_at,ends_at,presence,version) VALUES ('synthetic-jw','course',202610,'Retained JW',1,2,'observed',1)",
          );
          await harness.store.customStatement(
            'INSERT INTO jw_overlays (local_id,hidden) SELECT local_id,0 FROM jw_events',
          );
          final jwId = (await harness.store.readView()).events.single.localId;
          await harness.calendar(10, 11);
          var event = harness.sync.syncView.data!.events.single;
          final localId = event.localId;
          expect(event.startsAtUtc, DateTime.utc(2026, 10, 10, 2));
          expect(event.endsAtUtc, DateTime.utc(2026, 10, 10, 3));
          expect(harness.sync.syncView.normalization!.calendarRows, 2);
          expect(harness.sync.syncView.normalization!.excludedSchedules, 1);
          expect(harness.sync.syncView.normalization!.days, 2);
          expect(harness.sync.syncView.activityResults, isEmpty);
          await harness.sync.setHidden(
            localId: localId,
            expectedVersion: event.version,
            hidden: true,
          );
          await harness.calendar(10, 11);
          event = harness.sync.syncView.data!.events.single;
          expect(event.localId, localId);
          expect(event.hidden, isTrue);
          expect(harness.sync.syncView.profileReused, isTrue);
          await harness.calendar(11, 11);
          expect(
            harness.sync.syncView.data!.events.single.presence,
            YoungPresence.outsideScope,
          );
          fixture.mode = 'emptyCalendar';
          await harness.calendar(10, 10);
          expect(
            harness.sync.syncView.data!.events.single.presence,
            YoungPresence.missingWithinScope,
          );
          expect(harness.sync.syncView.data!.events.single.hidden, isTrue);
          fixture.mode = 'good';
          await harness.calendar(10, 10);
          expect(
            harness.sync.syncView.data!.events.single.presence,
            YoungPresence.observed,
          );
          expect(harness.sync.syncView.data!.events.single.localId, localId);
          final permit = (await harness.store.readYoungPermits()).single;
          await harness.dispose();
          harness = await _Harness.create(
            p.windows.join(root.path, 'owned'),
            fixture,
          );
          harnesses.add(harness);
          expect(harness.sync.syncView.data!.events.single.localId, localId);
          expect(harness.sync.syncView.data!.events.single.hidden, isTrue);
          expect(
            harness.sync.syncView.data!.firstDay,
            DateTime.utc(2026, 10, 10),
          );
          expect(
            (await harness.store.readYoungPermits()).single.partition.sameAs(
              permit.partition,
            ),
            isTrue,
          );
          await harness.calendar(10, 10);
          expect(harness.sync.syncView.data!.events, hasLength(1));
          expect(harness.sync.syncView.data!.importCount, 6);
          event = harness.sync.syncView.data!.events.single;
          await harness.sync.setHidden(
            localId: localId,
            expectedVersion: event.version,
            hidden: false,
          );
          await harness.sync.clearSession();
          expect(harness.sync.syncView.data!.events.single.hidden, isFalse);
          expect(harness.sync.syncView.data!.importCount, 6);
          expect(harness.sync.syncView.profileRetained, isFalse);
          expect(await harness.store.readYoungPermits(), isEmpty);
          expect((await harness.store.readView()).events.single.localId, jwId);
          expect(harness.leases.isBusy, isFalse);
          final names = await Directory(
            p.windows.join(harness.owner.path, 'young_partitions_v1'),
          ).list(followLinks: false).toList();
          expect(names, isEmpty);
          for (final value in [
            'FIXTURE001',
            'Synthetic linked event',
            'activity-0',
            'calendar-linked',
            'young-owner',
            'startsAtUtc',
          ]) {
            expect(harness.sync.syncView.safeSummary, isNot(contains(value)));
          }
        } finally {
          await _cleanup(root, fixture, harnesses);
        }
      });
    },
  );

  testWidgets(
    'Young native cancellation and identity handling retain only allowed profiles',
    (tester) async {
      await tester.runAsync(() async {
        final fixture = await YoungBusinessFixture.start();
        fixture.username = 'FIXTURE001';
        final root = await Directory.systemTemp.createTemp('ustc_m2_failure_');
        final harnesses = <_Harness>[];
        try {
          final harness = await _Harness.create(
            p.windows.join(root.path, 'owned'),
            fixture,
          );
          harnesses.add(harness);
          await harness.query(expected: 'FIXTURE001');
          final permit = (await harness.store.readYoungPermits()).single;
          fixture.mode = 'identityChange';
          fixture.profiles = 0;
          await harness.query(success: false);
          expect(
            harness.sync.syncView.identityFailure,
            YoungIdentityFailure.evidenceConflict,
          );
          expect(harness.sync.syncView.activityResults, isEmpty);
          expect(harness.sync.syncView.data!.queryCount, 1);
          expect(
            (await harness.store.readYoungPermits()).single.partition.sameAs(
              permit.partition,
            ),
            isTrue,
          );
          fixture.mode = 'late';
          await harness.beginCalendar(10, 10);
          final previous = fixture.calendarRequests;
          final work = harness.sync.continueAfterLogin();
          await _wait(
            () => fixture.calendarRequests > previous,
            'calendar request',
          );
          await harness.sync.cancel();
          await work;
          expect(harness.sync.syncView.phase, YoungSyncPhase.idle);
          expect(harness.sync.syncView.committed, isFalse);
          expect(harness.sync.syncView.data!.events, isEmpty);
          expect(harness.leases.isBusy, isFalse);
          expect(await harness.store.readYoungPermits(), hasLength(1));
          fixture.mode = 'accountMismatch';
          await harness.query(success: false);
          expect(
            harness.sync.syncView.identityFailure,
            YoungIdentityFailure.accountMismatch,
          );
          expect(harness.sync.syncView.data!.queryCount, 1);
          expect(harness.sync.syncView.accountBound, isTrue);
          expect(await harness.store.readYoungPermits(), isEmpty);
          expect(harness.sync.syncView.profileRetained, isFalse);
        } finally {
          await _cleanup(root, fixture, harnesses);
        }
      });
    },
  );
}

Future<void> _wait(bool Function() condition, String context) async {
  final elapsed = Stopwatch()..start();
  while (!condition()) {
    if (elapsed.elapsed > const Duration(seconds: 25)) {
      fail('Timeout: $context');
    }
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

final class _Harness {
  _Harness(this.owner, this.store, this.browser, this.leases, this.sync);
  final DemoDirectory owner;
  final JwStore store;
  final NativeObservationBrowser browser;
  final WorkLeasePool leases;
  final YoungSyncCoordinator sync;
  bool disposed = false;
  static Future<_Harness> create(
    String path,
    YoungBusinessFixture fixture,
  ) async {
    final owner = await DemoDirectory.acquire(path);
    final clock = FixedClock(DateTime.utc(2026, 10, 11));
    final store = JwStore(
      openJwDatabase(owner),
      ownership: owner,
      clock: clock,
    );
    await store.initialize();
    final browser = NativeObservationBrowser();
    final leases = WorkLeasePool();
    final sync = YoungSyncCoordinator(
      store: store,
      registry: YoungPartitionRegistry(owner),
      automaticAuthentication: false,
      browser: browser,
      leases: leases,
      clock: clock,
      target: ObservationTarget.youngFixture(fixture.initialUri),
    );
    final harness = _Harness(owner, store, browser, leases, sync);
    await sync.initialize();
    return harness;
  }

  Future<void> query({String? expected, bool success = true}) async {
    await sync.startActivities(expectedAccountCode: expected);
    expect(
      sync.syncView.phase,
      YoungSyncPhase.login,
      reason: sync.syncView.safeSummary,
    );
    await _wait(() => sync.syncView.ready, 'query ready');
    await sync.continueAfterLogin();
    expect(
      sync.syncView.phase,
      YoungSyncPhase.idle,
      reason: sync.syncView.safeSummary,
    );
    expect(sync.syncView.committed, success, reason: sync.syncView.safeSummary);
    expect(leases.isBusy, isFalse);
  }

  Future<void> beginCalendar(int first, int last) async {
    await sync.startCalendar(
      firstDay: DateTime.utc(2026, 10, first),
      lastDay: DateTime.utc(2026, 10, last),
    );
    expect(
      sync.syncView.phase,
      YoungSyncPhase.login,
      reason: sync.syncView.safeSummary,
    );
    await _wait(() => sync.syncView.ready, 'calendar ready');
  }

  Future<void> calendar(int first, int last) async {
    await beginCalendar(first, last);
    await sync.continueAfterLogin();
    expect(
      sync.syncView.phase,
      YoungSyncPhase.idle,
      reason: sync.syncView.safeSummary,
    );
    expect(sync.syncView.committed, isTrue, reason: sync.syncView.safeSummary);
    expect(leases.isBusy, isFalse);
  }

  Future<void> dispose() async {
    if (disposed) return;
    await sync.shutdown();
    await browser.dispose();
    await store.close();
    await owner.release();
    disposed = true;
  }
}

Future<void> _cleanup(
  Directory root,
  YoungBusinessFixture fixture,
  List<_Harness> harnesses,
) async {
  await fixture.close();
  for (final harness in harnesses.reversed) {
    try {
      await harness.dispose();
    } on Object {
      /* Preserve the root if drain failed. */
    }
  }
  final path = p.windows.normalize(p.windows.absolute(root.path));
  final temporary = p.windows.normalize(
    p.windows.absolute(Directory.systemTemp.path),
  );
  if (p.windows.isWithin(temporary, path) &&
      harnesses.every((h) => h.disposed)) {
    await root.delete(recursive: true);
  }
}
