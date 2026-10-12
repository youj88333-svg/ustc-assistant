// Design basis: navigate from docs/README.md to current 07–15: 07 read-only and
// shared-credential authorization; 08 C1/C2/C3/C5; 09 K-01–06; 10 natural
// multi-stage authentication and document rejection; 11 safe projections; 12
// partition/credential boundaries; 13 V-01/02/03/05; 14 overall review; and
// 15's M2.3 busy-navigation and manual-chain acceptance. Shared credentials,
// source-specific identity/partitions, complete reads and transaction
// continuity remain distinct. All pages, secrets and data are synthetic.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
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
    'Young automatic CAS shares the saved school credential across restart and profile clearing',
    (tester) async {
      await tester.runAsync(() async {
        final fixture = await YoungBusinessFixture.start(
          requireAuthentication: true,
        );
        fixture.username = 'FIXTURE001';
        final root = await Directory.systemTemp.createTemp(
          'ustc_young_automatic_auth_',
        );
        final harnesses = <_YoungHarness>[];
        const password = YoungBusinessFixture.syntheticPassword;
        const account = 'FIXTURE001';
        late final int jwLocalId;
        try {
          var harness = await _YoungHarness.create(
            p.windows.join(root.path, 'owned'),
            fixture,
          );
          harnesses.add(harness);
          await harness.store.customStatement(
            "INSERT INTO jw_events (external_id,kind,semester_id,title,starts_at,ends_at,presence,version) VALUES ('young-automation-kept-jw','course',202610,'Retained JW fact',1,2,'observed',1)",
          );
          await harness.store.customStatement(
            'INSERT INTO jw_overlays (local_id,hidden) SELECT local_id,0 FROM jw_events',
          );
          jwLocalId = (await harness.store.readView()).events.single.localId;

          await harness.sync
              .startActivities(
                expectedAccountCode: account,
                password: password,
                savePassword: true,
              )
              .timeout(const Duration(seconds: 90));
          final first = harness.sync.syncView;
          expect(first.phase, YoungSyncPhase.idle, reason: first.safeSummary);
          expect(first.committed, isTrue, reason: first.safeSummary);
          expect(first.accountBound, isTrue);
          expect(first.profileRetained, isTrue);
          expect(first.activityResults, hasLength(11));
          expect(first.normalization!.activityPages, 2);
          expect(fixture.activityRequests, 2);
          expect(first.data!.queryCount, 1);
          expect(first.data!.credentialSaved, isTrue);
          expect(await _savedCredentialRows(harness.store), 1);
          expect(await harness.store.readYoungPermits(), hasLength(1));
          expect(fixture.authenticationSubmissions, 1);
          expect(fixture.authenticationPages, greaterThan(0));
          expect(fixture.successfulAuthenticationSubmissions, 1);
          expect(fixture.credentialsMatched, isTrue);
          expect(fixture.unexpectedAuthenticationSubmissions, 0);
          expect(first.safeSummary, isNot(contains(password)));
          expect(first.safeSummary, isNot(contains(account)));

          await harness.dispose();
          harness = await _YoungHarness.create(
            p.windows.join(root.path, 'owned'),
            fixture,
          );
          harnesses.add(harness);
          expect(harness.sync.syncView.data!.credentialSaved, isTrue);
          expect(await _savedCredentialRows(harness.store), 1);
          expect(
            (await harness.store.readView()).events.single.localId,
            jwLocalId,
          );

          await harness.sync.clearSession();
          expect(harness.sync.syncView.profileRetained, isFalse);
          expect(await harness.store.readYoungPermits(), isEmpty);
          expect(harness.sync.syncView.data!.credentialSaved, isTrue);
          expect(await _savedCredentialRows(harness.store), 1);
          expect(
            (await harness.store.readView()).events.single.localId,
            jwLocalId,
          );

          await harness.sync
              .startCalendar(
                expectedAccountCode: account,
                firstDay: DateTime.utc(2026, 10, 10),
                lastDay: DateTime.utc(2026, 10, 10),
              )
              .timeout(const Duration(seconds: 90));
          final calendar = harness.sync.syncView;
          expect(
            calendar.phase,
            YoungSyncPhase.idle,
            reason: calendar.safeSummary,
          );
          expect(calendar.committed, isTrue, reason: calendar.safeSummary);
          expect(calendar.accountBound, isTrue);
          expect(calendar.profileRetained, isTrue);
          expect(calendar.data!.credentialSaved, isTrue);
          expect(calendar.data!.events, hasLength(1));
          expect(calendar.data!.importCount, 1);
          expect(fixture.calendarRequests, 1);
          expect(fixture.activityRequests, 2);
          expect(
            (await harness.store.readView()).events.single.localId,
            jwLocalId,
          );
          expect(await _savedCredentialRows(harness.store), 1);
          expect(fixture.authenticationSubmissions, 2);
          expect(fixture.successfulAuthenticationSubmissions, 2);
          expect(fixture.credentialsMatched, isTrue);
          expect(fixture.unexpectedAuthenticationSubmissions, 0);
          expect(calendar.safeSummary, isNot(contains(password)));

          final importedEventId = calendar.data!.events.single.localId;
          final queryCount = calendar.data!.queryCount;
          final importCount = calendar.data!.importCount;
          final calendarRequests = fixture.calendarRequests;
          fixture.mode = 'routeAfterBody';
          await harness.sync
              .startCalendar(
                expectedAccountCode: account,
                firstDay: DateTime.utc(2026, 10, 10),
                lastDay: DateTime.utc(2026, 10, 10),
              )
              .timeout(const Duration(seconds: 90));
          final rejected = harness.sync.syncView;
          expect(
            rejected.phase,
            YoungSyncPhase.idle,
            reason: rejected.safeSummary,
          );
          expect(rejected.committed, isFalse, reason: rejected.safeSummary);
          expect(rejected.collectionStage, isNotNull);
          expect(rejected.collectionReason, isNotNull);
          expect(rejected.safeSummary, contains('collectionReason'));
          expect(rejected.data!.queryCount, queryCount);
          expect(rejected.data!.importCount, importCount);
          expect(rejected.data!.events, hasLength(1));
          expect(rejected.data!.events.single.localId, importedEventId);
          expect(fixture.calendarRequests, greaterThan(calendarRequests));
          expect(fixture.activityRequests, 2);
          expect(rejected.data!.credentialSaved, isTrue);
          expect(await _savedCredentialRows(harness.store), 1);
          expect(
            (await harness.store.readView()).events.single.localId,
            jwLocalId,
          );
          // The earlier successful job fully closed its browser; this fixture
          // uses a session cookie, so the next job authenticates once again.
          expect(fixture.authenticationSubmissions, 3);
          expect(fixture.successfulAuthenticationSubmissions, 3);
          expect(fixture.unexpectedAuthenticationSubmissions, 0);
        } finally {
          await _cleanup(root, fixture, harnesses);
        }
      });
    },
  );

  testWidgets(
    'Young fixed preparation succeeds after delayed SPA route and helper readiness',
    (tester) async {
      await tester.runAsync(() async {
        final fixture = await YoungBusinessFixture.start(
          delayBusinessReadiness: true,
          businessReadinessDelay: const Duration(milliseconds: 900),
        );
        fixture.username = 'FIXTURE002';
        final root = await Directory.systemTemp.createTemp(
          'ustc_young_spa_readiness_',
        );
        final harnesses = <_YoungHarness>[];
        const account = 'FIXTURE002';
        try {
          final harness = await _YoungHarness.create(
            p.windows.join(root.path, 'owned'),
            fixture,
          );
          harnesses.add(harness);

          await harness.sync
              .startActivities(expectedAccountCode: account)
              .timeout(const Duration(seconds: 90));
          expect(
            harness.sync.syncView.phase,
            YoungSyncPhase.idle,
            reason: harness.sync.syncView.safeSummary,
          );
          expect(harness.sync.syncView.committed, isTrue);
          expect(harness.sync.syncView.activityResults, hasLength(11));
          expect(harness.sync.syncView.normalization!.activityPages, 2);
          expect(harness.sync.syncView.data!.queryCount, 1);
          expect(fixture.activityRequests, 2);
          expect(fixture.calendarRequests, 0);
          expect(fixture.frameRequests, greaterThan(2));
          expect(harness.leases.isBusy, isFalse);
        } finally {
          await _cleanup(root, fixture, harnesses);
        }
      });
    },
  );

  testWidgets(
    'Young follows the natural portal callback before fixed navigation and retains saved data',
    (tester) async {
      await tester.runAsync(() async {
        final fixture = await YoungBusinessFixture.start(
          requireAuthentication: true,
          realisticLoginRedirects: true,
        );
        fixture.username = 'FIXTURE003';
        final root = await Directory.systemTemp.createTemp(
          'ustc_young_realistic_redirects_',
        );
        final harnesses = <_YoungHarness>[];
        const account = 'FIXTURE003';
        const password = YoungBusinessFixture.syntheticPassword;
        late final int jwLocalId;
        try {
          final harness = await _YoungHarness.create(
            p.windows.join(root.path, 'owned'),
            fixture,
          );
          harnesses.add(harness);
          await harness.store.customStatement(
            "INSERT INTO jw_events (external_id,kind,semester_id,title,starts_at,ends_at,presence,version) VALUES ('young-realistic-kept-jw','course',202610,'Retained realistic JW fact',1,2,'observed',1)",
          );
          await harness.store.customStatement(
            'INSERT INTO jw_overlays (local_id,hidden) SELECT local_id,0 FROM jw_events',
          );
          jwLocalId = (await harness.store.readView()).events.single.localId;

          await harness.sync
              .startActivities(
                expectedAccountCode: account,
                password: password,
                savePassword: true,
              )
              .timeout(const Duration(seconds: 90));
          expect(harness.sync.syncView.committed, isTrue);
          expect(harness.sync.syncView.activityResults, hasLength(11));
          expect(harness.sync.syncView.normalization!.activityPages, 2);
          expect(fixture.authenticationSubmissions, 1);
          expect(fixture.bootstrapCompletions, 1);
          expect(fixture.prematureBusinessNavigations, 0);
          expect(fixture.bootstrapQueryCleared, isTrue);
          expect(await _savedCredentialRows(harness.store), 1);
          expect(
            (await harness.store.readView()).events.single.localId,
            jwLocalId,
          );

          await harness.sync.clearSession();
          expect(harness.sync.syncView.profileRetained, isFalse);
          expect(harness.sync.syncView.data!.credentialSaved, isTrue);
          expect(await _savedCredentialRows(harness.store), 1);
          expect(
            (await harness.store.readView()).events.single.localId,
            jwLocalId,
          );

          // Measure the fresh-profile run independently. The page and browser
          // counters contain only closed metadata, never authentication values.
          fixture.activityRequests = 0;
          fixture.authenticationPages = 0;
          fixture.authenticationSubmissions = 0;
          fixture.successfulAuthenticationSubmissions = 0;
          fixture.unexpectedAuthenticationSubmissions = 0;
          fixture.prematureBusinessNavigations = 0;
          fixture.bootstrapCompletions = 0;
          fixture.bootstrapQueryCleared = false;
          fixture.credentialsMatched = false;

          await harness.sync
              .startActivities(expectedAccountCode: account)
              .timeout(const Duration(seconds: 90));

          final result = harness.sync.syncView;
          expect(result.phase, YoungSyncPhase.idle, reason: result.safeSummary);
          expect(result.committed, isTrue, reason: result.safeSummary);
          expect(result.accountBound, isTrue);
          expect(result.activityResults, hasLength(11));
          expect(result.normalization!.activityPages, 2);
          expect(result.data!.queryCount, 2);
          expect(result.data!.credentialSaved, isTrue);
          expect(fixture.activityRequests, 2);
          expect(fixture.authenticationSubmissions, 1);
          expect(fixture.successfulAuthenticationSubmissions, 1);
          expect(fixture.credentialsMatched, isTrue);
          expect(fixture.unexpectedAuthenticationSubmissions, 0);
          expect(fixture.bootstrapCompletions, 1);
          expect(fixture.bootstrapQueryCleared, isTrue);
          expect(fixture.prematureBusinessNavigations, 0);
          expect(await _savedCredentialRows(harness.store), 1);
          expect(
            (await harness.store.readView()).events.single.localId,
            jwLocalId,
          );
          expect(
            (await harness.store.readView()).events.single.title,
            'Retained realistic JW fact',
          );
          expect(result.safeSummary, isNot(contains(password)));
          expect(result.safeSummary, isNot(contains(account)));
        } finally {
          await _cleanup(root, fixture, harnesses);
        }
      });
    },
  );
}

Future<int> _savedCredentialRows(JwStore store) async =>
    (await store
            .customSelect('SELECT COUNT(*) AS count FROM jw_credentials')
            .getSingle())
        .read<int>('count');

final class _YoungHarness {
  _YoungHarness(this.owner, this.store, this.browser, this.leases, this.sync);

  final DemoDirectory owner;
  final JwStore store;
  final NativeObservationBrowser browser;
  final WorkLeasePool leases;
  final YoungSyncCoordinator sync;
  bool disposed = false;

  static Future<_YoungHarness> create(
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
    await store.initialize();
    final browser = NativeObservationBrowser();
    final leases = WorkLeasePool();
    final sync = YoungSyncCoordinator(
      store: store,
      registry: YoungPartitionRegistry(owner),
      browser: browser,
      leases: leases,
      clock: clock,
      target: ObservationTarget.youngFixture(fixture.initialUri),
    );
    final harness = _YoungHarness(owner, store, browser, leases, sync);
    await sync.initialize();
    return harness;
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
  List<_YoungHarness> harnesses,
) async {
  await fixture.close();
  for (final harness in harnesses.reversed) {
    try {
      await harness.dispose();
    } on Object {
      /* Preserve the root if native drain is incomplete. */
    }
  }
  final path = p.windows.normalize(p.windows.absolute(root.path));
  final temporary = p.windows.normalize(
    p.windows.absolute(Directory.systemTemp.path),
  );
  if (p.windows.isWithin(temporary, path) &&
      harnesses.every((harness) => harness.disposed)) {
    await root.delete(recursive: true);
  }
}
