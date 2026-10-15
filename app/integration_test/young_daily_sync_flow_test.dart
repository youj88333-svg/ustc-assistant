// Design basis: docs/README.md navigation to architecture 07/09/10–12,
// quality 13, reviews 14, workflow 15, and the approved daily Young sync scope
// at the end of docs/milestones/windows-polish/plan.md. These tests use only a
// loopback synthetic school, a fresh temporary DemoDirectory, and synthetic
// account/password values; they never contact a real school.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/core/young_daily_sync_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_coordinator.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_port.dart';
import 'package:ustc_assistant_m0/platform/demo_directory.dart';
import 'package:ustc_assistant_m0/platform/native_database.dart';
import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';
import 'package:ustc_assistant_m0/platform/windows_jw_credential_protector.dart';
import 'package:ustc_assistant_m0/platform/young_partition_registry.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';

import 'support/young_business_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Young daily sync imports the full rolling window in a hidden native window and survives reopen',
    (tester) async {
      await tester.runAsync(() async {
        final fixture = await YoungBusinessFixture.start(
          requireAuthentication: true,
          delayBusinessReadiness: true,
        );
        fixture.username = 'FIXTUREDAILY001';
        final root = await Directory.systemTemp.createTemp(
          'ustc_young_daily_hidden_',
        );
        final harnesses = <_DailyHarness>[];
        StreamSubscription<BrowserEvent>? browserEvents;
        const account = 'FIXTUREDAILY001';
        const password = YoungBusinessFixture.syntheticPassword;
        late final int retainedEventId;
        try {
          var harness = await _DailyHarness.create(
            p.windows.join(root.path, 'owned'),
            fixture,
          );
          harnesses.add(harness);
          await harness.saveSyntheticCredential(account, password, fixture);

          await harness.sync
              .startCalendar(
                expectedAccountCode: account,
                firstDay: DateTime.utc(2026, 10, 10),
                lastDay: DateTime.utc(2026, 10, 10),
              )
              .timeout(const Duration(seconds: 90));
          expect(
            harness.sync.syncView.phase,
            YoungSyncPhase.idle,
            reason: harness.sync.syncView.safeSummary,
          );
          expect(harness.sync.syncView.committed, isTrue);
          expect(harness.sync.syncView.data!.events, hasLength(1));
          retainedEventId = harness.sync.syncView.data!.events.single.localId;
          expect(
            harness.sync.syncView.data!.firstDay,
            DateTime.utc(2026, 10, 10),
          );
          expect(
            harness.sync.syncView.data!.lastDay,
            DateTime.utc(2026, 10, 10),
          );

          // Expire the fixture browser session while retaining the C3
          // credential and calendar. The hidden attempt must authenticate
          // afresh rather than succeeding only through a warm cookie.
          final priorLogins = fixture.successfulAuthenticationSubmissions;
          await harness.sync.clearSession();
          expect(harness.sync.syncView.data!.credentialSaved, isTrue);
          expect(
            harness.sync.syncView.data!.events.single.localId,
            retainedEventId,
          );

          final beforeEnable = await harness.store.youngDaily.inspect();
          expect(beforeEnable.lastSuccessAtUtc, isNull);
          await harness.store.youngDaily.setEnabled(beforeEnable.context, true);
          final claimedGrant = await harness.store.youngDaily.claim();
          expect(claimedGrant, isNotNull);
          if (claimedGrant == null) fail('Expected an enabled daily grant');
          final grant = claimedGrant;
          expect(grant.firstDay, DateTime.utc(2026, 10, 10));
          expect(grant.endDayExclusive, DateTime.utc(2026, 11, 10));

          // Hold the first synthetic calendar response briefly so inspection
          // observes the actual in-flight native window. Later fixture reads
          // return normally and still cover all 31 requested dates.
          final requestsBeforeDaily = fixture.calendarRequests;
          fixture.mode = 'late';
          final readyEvents = <BrowserEvent>[];
          browserEvents = harness.browser.events.listen((event) {
            if (event.kind == BrowserEventKind.ready &&
                event.origin == fixture.initialUri.origin) {
              readyEvents.add(event);
            }
          });
          final dailyWork = harness.sync.startDailyCalendar(
            grant,
            background: true,
          );
          await _wait(
            () =>
                fixture.calendarRequests > requestsBeforeDaily &&
                readyEvents.isNotEmpty &&
                harness.sync.syncView.phase == YoungSyncPhase.collecting,
            'hidden daily calendar request',
          );
          final ready = readyEvents.last;
          final hiddenWindow = await harness.browser.inspect(
            session: ready.session,
            document: ready.document,
          );
          expect(harness.sync.syncView.busy, isTrue);
          expect(hiddenWindow.windowVisible, isFalse);
          expect(hiddenWindow.windowForeground, isFalse);
          fixture.mode = 'good';
          await dailyWork.timeout(const Duration(seconds: 120));
          expect(
            harness.sync.syncView.phase,
            YoungSyncPhase.idle,
            reason: harness.sync.syncView.safeSummary,
          );
          expect(
            harness.sync.syncView.committed,
            isTrue,
            reason: harness.sync.syncView.safeSummary,
          );
          expect(harness.sync.syncView.normalization!.days, 31);
          expect(harness.sync.syncView.normalization!.calendarPages, 31);
          expect(fixture.calendarRequests, requestsBeforeDaily + 31);
          expect(fixture.successfulAuthenticationSubmissions, priorLogins + 1);
          expect(fixture.unexpectedAuthenticationSubmissions, 0);
          expect(harness.sync.syncView.data!.events, hasLength(1));
          expect(
            harness.sync.syncView.data!.events.single.localId,
            retainedEventId,
          );
          expect(
            harness.sync.syncView.data!.firstDay,
            DateTime.utc(2026, 10, 10),
          );
          expect(
            harness.sync.syncView.data!.lastDay,
            DateTime.utc(2026, 10, 10),
          );
          expect(harness.sync.syncView.data!.importCount, 2);
          expect(harness.leases.isBusy, isFalse);
          await harness.store.youngDaily.finish(
            grant,
            YoungDailySyncOutcome.failed,
          );
          final success = await harness.store.youngDaily.inspect();
          expect(success.lastSuccessAtUtc, DateTime.utc(2026, 10, 11));
          expect(success.successFirstDay, DateTime.utc(2026, 10, 10));
          expect(success.successEndDayExclusive, DateTime.utc(2026, 11, 10));

          await browserEvents.cancel();
          browserEvents = null;
          await harness.dispose();
          harness = await _DailyHarness.create(
            p.windows.join(root.path, 'owned'),
            fixture,
          );
          harnesses.add(harness);
          expect(harness.sync.syncView.data!.events, hasLength(1));
          expect(
            harness.sync.syncView.data!.events.single.localId,
            retainedEventId,
          );
          expect(
            harness.sync.syncView.data!.firstDay,
            DateTime.utc(2026, 10, 10),
          );
          expect(
            harness.sync.syncView.data!.lastDay,
            DateTime.utc(2026, 10, 10),
          );
          expect(harness.sync.syncView.data!.importCount, 2);
          expect(await harness.store.youngDaily.claim(), isNull);
        } finally {
          await browserEvents?.cancel();
          await _cleanup(root, fixture, harnesses);
        }
      });
    },
  );

  testWidgets(
    'explicit daily sync uses a visible window and cancellation drains without recording success',
    (tester) async {
      await tester.runAsync(() async {
        final fixture = await YoungBusinessFixture.start(
          requireAuthentication: true,
          delayBusinessReadiness: true,
        );
        fixture.username = 'FIXTUREDAILY002';
        final root = await Directory.systemTemp.createTemp(
          'ustc_young_daily_manual_',
        );
        final harnesses = <_DailyHarness>[];
        StreamSubscription<BrowserEvent>? browserEvents;
        const account = 'FIXTUREDAILY002';
        const password = YoungBusinessFixture.syntheticPassword;
        try {
          final harness = await _DailyHarness.create(
            p.windows.join(root.path, 'owned'),
            fixture,
          );
          harnesses.add(harness);
          await harness.saveSyntheticCredential(account, password, fixture);
          final initial = await harness.store.youngDaily.inspect();
          await harness.store.youngDaily.setEnabled(initial.context, true);
          final claimedGrant = await harness.store.youngDaily.claim(
            manual: true,
          );
          expect(claimedGrant, isNotNull);
          if (claimedGrant == null) fail('Expected an explicit daily grant');
          final grant = claimedGrant;
          expect(grant.firstDay, DateTime.utc(2026, 10, 10));
          expect(grant.endDayExclusive, DateTime.utc(2026, 11, 10));

          final requestsBeforeDaily = fixture.calendarRequests;
          fixture.mode = 'late';
          final readyEvents = <BrowserEvent>[];
          browserEvents = harness.browser.events.listen((event) {
            if (event.kind == BrowserEventKind.ready &&
                event.origin == fixture.initialUri.origin) {
              readyEvents.add(event);
            }
          });
          final dailyWork = harness.sync.startDailyCalendar(
            grant,
            background: false,
          );
          await _wait(
            () =>
                fixture.calendarRequests > requestsBeforeDaily &&
                readyEvents.isNotEmpty &&
                harness.sync.syncView.phase == YoungSyncPhase.collecting,
            'visible daily calendar request',
          );
          final ready = readyEvents.last;
          final visibleWindow = await harness.browser.inspect(
            session: ready.session,
            document: ready.document,
          );
          expect(visibleWindow.windowVisible, isTrue);
          expect(harness.sync.syncView.busy, isTrue);

          fixture.mode = 'good';
          await harness.sync.cancel().timeout(const Duration(seconds: 30));
          await dailyWork.timeout(const Duration(seconds: 30));
          expect(harness.sync.syncView.phase, YoungSyncPhase.idle);
          expect(harness.sync.syncView.committed, isFalse);
          expect(harness.sync.syncView.data!.events, isEmpty);
          expect(harness.leases.isBusy, isFalse);
          await harness.store.youngDaily.finish(
            grant,
            YoungDailySyncOutcome.interrupted,
          );
          final cancelled = await harness.store.youngDaily.inspect();
          expect(cancelled.lastSuccessAtUtc, isNull);
          expect(cancelled.successFirstDay, isNull);
          expect(cancelled.successEndDayExclusive, isNull);
        } finally {
          await browserEvents?.cancel();
          await _cleanup(root, fixture, harnesses);
        }
      });
    },
  );
}

Future<void> _wait(bool Function() condition, String context) async {
  final elapsed = Stopwatch()..start();
  while (!condition()) {
    if (elapsed.elapsed > const Duration(seconds: 35)) {
      fail('Timeout: $context');
    }
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

final class _DailyHarness {
  _DailyHarness(this.owner, this.store, this.browser, this.leases, this.sync);

  final DemoDirectory owner;
  final JwStore store;
  final NativeObservationBrowser browser;
  final WorkLeasePool leases;
  final YoungSyncCoordinator sync;
  bool disposed = false;

  static Future<_DailyHarness> create(
    String path,
    YoungBusinessFixture fixture,
  ) async {
    final owner = await DemoDirectory.acquire(path);
    final clock = FixedClock(DateTime.utc(2026, 10, 11));
    final store = JwStore(
      openJwDatabase(owner),
      ownership: owner,
      clock: clock,
      credentialProtector: const WindowsJwCredentialProtector(),
    );
    try {
      await store.initialize();
    } catch (_) {
      await store.close();
      await owner.release();
      rethrow;
    }
    final browser = NativeObservationBrowser();
    final leases = WorkLeasePool();
    final sync = YoungSyncCoordinator(
      store: store,
      registry: YoungPartitionRegistry(owner),
      automaticAuthentication: true,
      browser: browser,
      leases: leases,
      clock: clock,
      target: ObservationTarget.youngFixture(fixture.initialUri),
    );
    final harness = _DailyHarness(owner, store, browser, leases, sync);
    try {
      await sync.initialize();
      return harness;
    } catch (_) {
      await harness.dispose();
      rethrow;
    }
  }

  Future<void> saveSyntheticCredential(
    String account,
    String password,
    YoungBusinessFixture fixture,
  ) async {
    await sync
        .startActivities(
          expectedAccountCode: account,
          password: password,
          savePassword: true,
        )
        .timeout(const Duration(seconds: 90));
    expect(
      sync.syncView.phase,
      YoungSyncPhase.idle,
      reason: sync.syncView.safeSummary,
    );
    expect(sync.syncView.committed, isTrue, reason: sync.syncView.safeSummary);
    expect(sync.syncView.data!.credentialSaved, isTrue);
    expect(fixture.credentialsMatched, isTrue);
    expect(fixture.unexpectedAuthenticationSubmissions, 0);
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
  List<_DailyHarness> harnesses,
) async {
  for (final harness in harnesses.reversed) {
    try {
      await harness.dispose();
    } on Object {
      // Preserve the temporary root if native work did not fully drain.
    }
  }
  await fixture.close();
  final path = p.windows.normalize(p.windows.absolute(root.path));
  final temporary = p.windows.normalize(
    p.windows.absolute(Directory.systemTemp.path),
  );
  if (p.windows.isWithin(temporary, path) &&
      harnesses.every((harness) => harness.disposed)) {
    await root.delete(recursive: true);
  }
}
