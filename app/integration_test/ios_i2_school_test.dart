// I2 contract: docs/milestones/ios-private/plan.md and docs/architecture/07-12,
// docs/quality/13, docs/workflow.md. These cases use only fresh loopback
// fixtures and synthetic TEST0001 data. No school, model, or credential is used.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/jw_work_contract.dart';
import 'package:ustc_assistant_m0/core/settings_contract.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/data/jw_import_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/jobs/jw_sync_coordinator.dart';
import 'package:ustc_assistant_m0/jobs/jw_sync_port.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_coordinator.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_port.dart';
import 'package:ustc_assistant_m0/platform/ios_runtime_platform_factory.dart';
import 'package:ustc_assistant_m0/platform/jw_partition_registry.dart';
import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';
import 'package:ustc_assistant_m0/platform/native_database.dart';
import 'package:ustc_assistant_m0/platform/observation_assets.dart';
import 'package:ustc_assistant_m0/platform/owned_directory.dart';
import 'package:ustc_assistant_m0/platform/runtime_platform_factory.dart';
import 'package:ustc_assistant_m0/platform/young_partition_registry.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';
import 'package:ustc_assistant_m0/app/demo_runtime.dart';

import 'support/jw_sync_fixture.dart';
import 'support/ios_i2_drain.dart';
import 'support/young_business_fixture.dart';

const _account = 'TEST0001';
const _startupTimeout = Duration(seconds: 45);
const _operationTimeout = Duration(seconds: 45);
const _nativeTimeout = Duration(seconds: 20);
const _platformChannel = MethodChannel('ustc_assistant/platform_v1');
const _debugChannel = MethodChannel('ustc_assistant/observation_v1');
var _nextSession = 7000;
final _report = <String, Object>{};

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUp(_report.clear);
  tearDown(() {
    // The report contains only fixed phase names and booleans, never paths,
    // source rows, account values, responses, or authentication material.
    binding.reportData = Map<String, Object>.from(_report);
  });

  testWidgets(
    'iOS I2 loopback transactions, native stores, cancellation, and cleanup',
    (tester) async {
      expect(kDebugMode, isTrue);
      final platformStatus = await _platformChannel
          .invokeMapMethod<String, Object?>('storageProtectionStatus')
          .timeout(_nativeTimeout);
      expect(
        platformStatus?['isSimulator'],
        isTrue,
        reason: 'I2 automatic checks must run on an iOS Simulator',
      );
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.expand())),
      );

      await tester.runAsync(
        () => HttpOverrides.runZoned(
          () => _runI2Scenario(),
          createHttpClient: (context) {
            final client = HttpClient(context: context);
            client.findProxy = (uri) =>
                _isLoopback(uri) ? 'DIRECT' : 'PROXY 127.0.0.1:9';
            return client;
          },
        ),
      );
    },
    skip: !Platform.isIOS,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

bool _isLoopback(Uri uri) =>
    uri.host == '127.0.0.1' && (uri.scheme == 'http' || uri.scheme == 'https');

Future<void> _runI2Scenario() async {
  final harness = await _I2Harness.create();
  JwSyncFixture? jwFixture;
  YoungBusinessFixture? youngFixture;
  ObservationAssets? temporaryYoungAssets;
  var cleanupComplete = true;
  var primaryFailure = false;
  var jwStorePath = '';
  var secondJwStorePath = '';
  JwPartitionRef? secondJwPartition;
  JwSyncCoordinator? jw;
  YoungSyncCoordinator? young;
  var secondJwSession = 0;
  var temporaryYoungSession = 0;
  var activeNativeSession = 0;

  Future<bool> attempt(Future<void> Function() action) async {
    try {
      await action().timeout(_operationTimeout);
      return true;
    } on Object {
      return false;
    }
  }

  try {
    jwFixture = await JwSyncFixture.start(requireLogin: false);
    final jwTarget = ObservationTarget.fixture(jwFixture.initialUri);
    jw = JwSyncCoordinator(
      store: harness.store,
      registry: harness.jwRegistry,
      browser: harness.browser,
      leases: harness.leases,
      clock: harness.clock,
      loginWaitTimeout: const Duration(seconds: 30),
      automationPollInterval: const Duration(milliseconds: 100),
      target: jwTarget,
    );
    await jw.initialize().timeout(_operationTimeout);
    final priorJwProfiles = await _partitionNames(
      harness.directories.formal,
      root: 'jw_partitions_v1',
      prefix: 'jwp',
    );

    debugPrint('I2 synthetic phase: jw initial collection');
    await jw
        .startSync(expectedAccountCode: _account, semesterId: 20261)
        .timeout(_operationTimeout);
    debugPrint('I2 synthetic JW outcome: ${jw.syncView.safeSummary}');
    expect(jw.syncView.importCommitted, isTrue);
    var jwData = await harness.store.readView().timeout(_operationTimeout);
    expect(
      jwData.events.any((event) => event.kind == JwEventKind.course),
      isTrue,
    );
    expect(
      jwData.events.any((event) => event.kind == JwEventKind.exam),
      isTrue,
    );
    final firstCourse = jwData.events.singleWhere(
      (event) => event.kind == JwEventKind.course,
    );
    await jw
        .setHidden(
          localId: firstCourse.localId,
          expectedVersion: firstCourse.version,
          hidden: true,
        )
        .timeout(_operationTimeout);
    jwData = await harness.store.readView().timeout(_operationTimeout);
    expect(
      jwData.events
          .singleWhere((event) => event.localId == firstCourse.localId)
          .hidden,
      isTrue,
    );

    debugPrint('I2 synthetic phase: jw repeat import');
    await jw
        .startSync(expectedAccountCode: _account, semesterId: 20261)
        .timeout(_operationTimeout);
    final repeatedJwData = await harness.store.readView().timeout(
      _operationTimeout,
    );
    expect(repeatedJwData.courseCount, jwData.courseCount);
    expect(repeatedJwData.examCount, jwData.examCount);
    expect(repeatedJwData.events.length, jwData.events.length);
    expect(
      repeatedJwData.events
          .singleWhere((event) => event.localId == firstCourse.localId)
          .hidden,
      isTrue,
    );

    final currentJwProfiles = await _partitionNames(
      harness.directories.formal,
      root: 'jw_partitions_v1',
      prefix: 'jwp',
    );
    final createdJwProfiles = currentJwProfiles.difference(priorJwProfiles);
    expect(
      createdJwProfiles.length,
      1,
      reason: 'JW creates one owned UUID profile',
    );
    final jwProfileName = createdJwProfiles.single;
    jwStorePath = harness.directories.formal.checkedChildPath(
      'jw_partitions_v1/$jwProfileName',
      directory: true,
    );

    // Native cancellation is exercised while the local fixture is holding its
    // index reply. Releasing the response lets the real browser drain finish.
    final priorIndexCount = jwFixture.acceptedIndexSemesters.length;
    jwFixture.pauseIndex = true;
    final pendingSync = jw
        .startSync(expectedAccountCode: _account, semesterId: 20261)
        .timeout(_operationTimeout);
    await _waitFor(
      () => jwFixture!.acceptedIndexSemesters.length > priorIndexCount,
      message: 'JW fixture did not pause at the index request',
    );
    final cancelling = jw.cancel().timeout(_operationTimeout);
    if (!jwFixture.releaseIndex.isCompleted) jwFixture.releaseIndex.complete();
    await Future.wait<void>([
      pendingSync,
      cancelling,
    ]).timeout(_operationTimeout);
    expect(jw.syncView.importCommitted, isFalse);
    final afterCancel = await harness.store.readView().timeout(
      _operationTimeout,
    );
    expect(afterCancel.courseCount, repeatedJwData.courseCount);
    expect(afterCancel.examCount, repeatedJwData.examCount);
    _report['jwCollectionAndCancel'] = true;

    // A second registry-owned JW UUID uses the same fixture origin. It has no
    // account permit and is removed through the registry's official drain.
    final authority = await harness.store.readAuthority().timeout(
      _operationTimeout,
    );
    secondJwPartition = await harness.jwRegistry
        .createProvisional(
          ownerId: authority.ownerId,
          purpose: JwPartitionPurpose.initial,
          attempt: 'jw-900-1',
          resetEpoch: authority.resetEpoch,
        )
        .timeout(_operationTimeout);
    secondJwStorePath = harness.jwRegistry.profilePath(secondJwPartition);

    // Two independent WKWebsiteDataStore UUIDs, same origin. The i2-only
    // marker probes only a fixed synthetic value in native browser storage.
    await harness.browser.ensureAvailable().timeout(_nativeTimeout);
    final jwSessionA = _session();
    var readyA = await _openFixture(
      harness.browser,
      session: jwSessionA,
      profilePath: jwStorePath,
      target: jwTarget,
    );
    activeNativeSession = jwSessionA;
    expect(
      await _i2Fixture(jwSessionA, readyA.document, 'writeSyntheticMarker'),
      isTrue,
    );
    expect(
      await _i2Fixture(jwSessionA, readyA.document, 'checkSyntheticMarker'),
      isTrue,
    );
    readyA = await _exerciseDocumentChange(
      harness.browser,
      session: jwSessionA,
      document: readyA.document,
      action: 'sameDocument',
    );
    readyA = await _exerciseDocumentChange(
      harness.browser,
      session: jwSessionA,
      document: readyA.document,
      action: 'nextDocument',
    );
    await _closeDrained(harness.browser, jwSessionA);
    activeNativeSession = 0;
    expect(await _i2StoreExists(jwStorePath, 'jw'), isTrue);

    secondJwSession = _session();
    var readyB = await _openFixture(
      harness.browser,
      session: secondJwSession,
      profilePath: secondJwStorePath,
      target: jwTarget,
    );
    activeNativeSession = secondJwSession;
    expect(
      await _i2Fixture(
        secondJwSession,
        readyB.document,
        'checkNoSyntheticMarker',
      ),
      isTrue,
      reason: 'a same-origin UUID store must not inherit A data',
    );
    expect(
      await _i2Fixture(
        secondJwSession,
        readyB.document,
        'writeSyntheticMarker',
      ),
      isTrue,
    );
    final userClosed = harness.browser.events.firstWhere(
      (event) =>
          event.session == secondJwSession &&
          event.kind == BrowserEventKind.userClosed,
    );
    await harness.browser.exerciseFixture(
      session: secondJwSession,
      document: readyB.document,
      action: 'userClose',
    );
    await userClosed.timeout(_nativeTimeout);
    await _closeDrained(harness.browser, secondJwSession);
    activeNativeSession = 0;
    expect(await _i2StoreExists(secondJwStorePath, 'jw'), isTrue);

    readyB = await _openFixture(
      harness.browser,
      session: secondJwSession = _session(),
      profilePath: secondJwStorePath,
      target: jwTarget,
    );
    activeNativeSession = secondJwSession;
    expect(
      await _i2Fixture(
        secondJwSession,
        readyB.document,
        'checkSyntheticMarker',
      ),
      isTrue,
      reason: 'a normal production-profile close must retain its store',
    );
    await _closeDrained(harness.browser, secondJwSession);
    activeNativeSession = 0;

    readyA = await _openFixture(
      harness.browser,
      session: activeNativeSession = _session(),
      profilePath: jwStorePath,
      target: jwTarget,
    );
    final reopenedASession = readyA.session;
    expect(
      await _i2Fixture(
        reopenedASession,
        readyA.document,
        'checkSyntheticMarker',
      ),
      isTrue,
      reason: 'a normal production-profile close must retain its store',
    );
    await _closeDrained(harness.browser, reopenedASession);
    activeNativeSession = 0;

    // Delete provisional B through the real registry while claimed A remains.
    // The product clearSession command intentionally revokes every JW permit
    // and reconciles unpermitted profiles; it must not be used as a one-UUID
    // delete operation and then expected to preserve unpermitted B.
    final beforeRecoveryRequests = jwFixture.requests.length;
    await harness.jwRegistry
        .clear(
          secondJwPartition,
          (path) => _recoveryDrain(
            harness.browser,
            profilePath: path,
            target: jwTarget,
          ),
        )
        .timeout(_operationTimeout);
    secondJwPartition = null;
    expect(jwFixture.requests.length, beforeRecoveryRequests);
    expect(await _i2StoreExists(secondJwStorePath, 'jw'), isFalse);
    expect(await _i2StoreExists(jwStorePath, 'jw'), isTrue);
    readyA = await _openFixture(
      harness.browser,
      session: activeNativeSession = _session(),
      profilePath: jwStorePath,
      target: jwTarget,
    );
    expect(
      await _i2Fixture(readyA.session, readyA.document, 'checkSyntheticMarker'),
      isTrue,
    );
    await _closeDrained(harness.browser, readyA.session);
    activeNativeSession = 0;
    await jw.clearSession().timeout(_operationTimeout);
    expect(jw.syncView.phase, JwSyncPhase.idle);
    expect(await _i2StoreExists(jwStorePath, 'jw'), isFalse);
    _report['sameOriginStoreIsolationAndIndependentDelete'] = true;

    youngFixture = await YoungBusinessFixture.start();
    youngFixture.username = _account;
    final youngTarget = ObservationTarget.youngFixture(youngFixture.initialUri);
    young = YoungSyncCoordinator(
      store: harness.store,
      registry: harness.youngRegistry,
      browser: harness.browser,
      leases: harness.leases,
      clock: harness.clock,
      navigationTimeout: const Duration(seconds: 30),
      pollInterval: const Duration(milliseconds: 100),
      loginWaitTimeout: const Duration(seconds: 30),
      businessStability: const Duration(milliseconds: 250),
      target: youngTarget,
    );
    await young.initialize().timeout(_operationTimeout);
    final priorYoungProfiles = await _partitionNames(
      harness.directories.formal,
      root: 'young_partitions_v1',
      prefix: 'yp',
    );

    debugPrint('I2 synthetic phase: Young activity query');
    await young
        .startActivities(expectedAccountCode: _account)
        .timeout(_operationTimeout);
    expect(young.syncView.activityResults, isNotEmpty);
    final activityCount = young.syncView.activityResults.length;
    expect(activityCount, greaterThan(0));

    debugPrint('I2 synthetic phase: Young date-bounded calendar import');
    final firstDay = DateTime.utc(2026, 10, 10);
    await young
        .startCalendar(
          expectedAccountCode: _account,
          firstDay: firstDay,
          lastDay: firstDay,
        )
        .timeout(_operationTimeout);
    var youngData = await harness.store.readYoungView().timeout(
      _operationTimeout,
    );
    expect(young.syncView.committed, isTrue);
    expect(youngData.events, isNotEmpty);
    final calendarEvent = youngData.events.first;
    await young
        .setHidden(
          localId: calendarEvent.localId,
          expectedVersion: calendarEvent.version,
          hidden: true,
        )
        .timeout(_operationTimeout);
    youngData = await harness.store.readYoungView().timeout(_operationTimeout);
    expect(
      youngData.events
          .singleWhere((event) => event.localId == calendarEvent.localId)
          .hidden,
      isTrue,
    );

    await young
        .startCalendar(
          expectedAccountCode: _account,
          firstDay: firstDay,
          lastDay: firstDay,
        )
        .timeout(_operationTimeout);
    final repeatedYoungData = await harness.store.readYoungView().timeout(
      _operationTimeout,
    );
    expect(repeatedYoungData.events.length, youngData.events.length);
    expect(
      repeatedYoungData.events
          .singleWhere((event) => event.localId == calendarEvent.localId)
          .hidden,
      isTrue,
    );

    final beforeRejectedQuery = repeatedYoungData.events
        .map((event) => event.localId)
        .toSet();
    youngFixture.mode = 'accountMismatch';
    await young
        .startActivities(expectedAccountCode: _account)
        .timeout(_operationTimeout);
    expect(young.syncView.identityFailure, isNotNull);
    final afterRejectedQuery = await harness.store.readYoungView().timeout(
      _operationTimeout,
    );
    expect(
      afterRejectedQuery.events.map((event) => event.localId).toSet(),
      beforeRejectedQuery,
      reason: 'an identity mismatch must not replace committed calendar rows',
    );
    youngFixture.mode = 'good';
    // A positively different account revokes/removes its browser partition,
    // while committed calendar rows remain. Restore the good fixture to
    // exercise reauthentication into a fresh valid profile before clearing it.
    await young
        .startCalendar(
          expectedAccountCode: _account,
          firstDay: firstDay,
          lastDay: firstDay,
        )
        .timeout(_operationTimeout);
    expect(young.syncView.committed, isTrue);

    // Same-URL history changes must invalidate the native document token. This
    // disposable Young observation is removed by a normal native close.
    temporaryYoungAssets = ObservationAssets.young(harness.directories.demo);
    final temporaryYoungPath = await temporaryYoungAssets.register().timeout(
      _operationTimeout,
    );
    temporaryYoungSession = _session();
    var youngReady = await _openFixture(
      harness.browser,
      session: temporaryYoungSession,
      profilePath: temporaryYoungPath,
      target: youngTarget,
    );
    activeNativeSession = temporaryYoungSession;
    youngReady = await _exerciseDocumentChange(
      harness.browser,
      session: temporaryYoungSession,
      document: youngReady.document,
      action: 'youngSameUrlPush',
    );
    youngReady = await _exerciseDocumentChange(
      harness.browser,
      session: temporaryYoungSession,
      document: youngReady.document,
      action: 'youngSameUrlReplace',
    );
    await _closeDrained(harness.browser, temporaryYoungSession);
    activeNativeSession = 0;
    expect(await _i2StoreExists(temporaryYoungPath, 'young'), isFalse);
    await temporaryYoungAssets.cleanup().timeout(_operationTimeout);
    await temporaryYoungAssets.close().timeout(_operationTimeout);
    temporaryYoungAssets = null;

    final currentYoungProfiles = await _partitionNames(
      harness.directories.formal,
      root: 'young_partitions_v1',
      prefix: 'yp',
    );
    final createdYoungProfiles = currentYoungProfiles.difference(
      priorYoungProfiles,
    );
    expect(createdYoungProfiles.length, 1);
    final youngProfilePath = harness.directories.formal.checkedChildPath(
      'young_partitions_v1/${createdYoungProfiles.single}',
      directory: true,
    );
    await young.clearSession().timeout(_operationTimeout);
    expect(young.syncView.phase, YoungSyncPhase.idle);
    expect(await _i2StoreExists(youngProfilePath, 'young'), isFalse);
    _report['youngQueryCalendarRejectAndCleanup'] = true;

    await jw.shutdown().timeout(_operationTimeout);
    jw = null;
    await young.shutdown().timeout(_operationTimeout);
    young = null;
    expect(harness.leases.isBusy, isFalse);
    _report['sourceLeasesIdle'] = true;
  } catch (_) {
    primaryFailure = true;
    if (jw != null) {
      debugPrint('I2 synthetic JW failure: ${jw.syncView.safeSummary}');
    }
    rethrow;
  } finally {
    if (jwFixture != null) {
      // The held fixture reply is always released before asking the native
      // controller to finish a cancellation path.
      if (!jwFixture.releaseIndex.isCompleted) {
        jwFixture.releaseIndex.complete();
      }
    }
    if (activeNativeSession != 0) {
      cleanupComplete =
          await attempt(
            () => _closeDrained(harness.browser, activeNativeSession),
          ) &&
          cleanupComplete;
      activeNativeSession = 0;
    }
    if (jwFixture != null) {
      cleanupComplete = await attempt(jwFixture.close) && cleanupComplete;
    }
    if (youngFixture != null) {
      cleanupComplete = await attempt(youngFixture.close) && cleanupComplete;
    }
    final retainedTemporaryAssets = temporaryYoungAssets;
    if (retainedTemporaryAssets != null) {
      cleanupComplete =
          await attempt(() async {
            await retainedTemporaryAssets.cleanup();
            await retainedTemporaryAssets.close();
          }) &&
          cleanupComplete;
    }
    if (secondJwPartition != null && secondJwStorePath.isNotEmpty) {
      final target = jwFixture == null
          ? null
          : ObservationTarget.fixture(jwFixture.initialUri);
      if (target == null ||
          !await attempt(
            () => harness.jwRegistry.clear(
              secondJwPartition!,
              (path) => _recoveryDrain(
                harness.browser,
                profilePath: path,
                target: target,
              ),
            ),
          )) {
        cleanupComplete = false;
      }
    }
    if (jw != null) {
      if (jw.syncView.busy) {
        cleanupComplete = await attempt(jw.cancel) && cleanupComplete;
      }
      cleanupComplete = await attempt(jw.clearSession) && cleanupComplete;
      cleanupComplete = await attempt(jw.shutdown) && cleanupComplete;
    }
    if (young != null) {
      if (young.syncView.busy) {
        cleanupComplete = await attempt(young.cancel) && cleanupComplete;
      }
      cleanupComplete = await attempt(young.clearSession) && cleanupComplete;
      cleanupComplete = await attempt(young.shutdown) && cleanupComplete;
    }
    cleanupComplete = await attempt(harness.browser.dispose) && cleanupComplete;
    cleanupComplete = await attempt(harness.store.close) && cleanupComplete;
    cleanupComplete =
        await attempt(harness.directories.formal.release) && cleanupComplete;
    cleanupComplete =
        await attempt(harness.directories.demo.release) && cleanupComplete;
    _report['cleanupComplete'] = cleanupComplete;
    if (!cleanupComplete && !primaryFailure) {
      throw StateError('ios_i2_synthetic_cleanup_incomplete');
    }
    if (!cleanupComplete) debugPrint('I2 cleanup after primary failure: false');
  }
}

final class _I2Harness {
  _I2Harness({
    required this.directories,
    required this.store,
    required this.browser,
    required this.jwRegistry,
    required this.youngRegistry,
    required this.leases,
    required this.clock,
  });

  final RuntimeDirectories directories;
  final JwStore store;
  final NativeObservationBrowser browser;
  final JwPartitionRegistry jwRegistry;
  final YoungPartitionRegistry youngRegistry;
  final WorkLeasePool leases;
  final FixedClock clock;

  static Future<_I2Harness> create() async {
    RuntimeBootstrap? bootstrap;
    RuntimeDirectories? directories;
    JwStore? store;
    NativeObservationBrowser? browser;
    try {
      // Exercise the same bootstrap path as the acceptance entry before
      // acquiring a fresh single owner for fixture-targeted coordinators.
      final bootstrapOpen = RuntimeBootstrap.open(
        platformFactory: IOSRuntimePlatformFactory(),
      );
      try {
        bootstrap = await bootstrapOpen.timeout(_startupTimeout);
      } on TimeoutException {
        unawaited(
          bootstrapOpen.then<void>(
            (lateBootstrap) => lateBootstrap.close(),
            onError: (Object _, StackTrace _) {},
          ),
        );
        rethrow;
      }
      if (bootstrap.runtime == null) {
        throw StateError('bootstrap_runtime_unavailable');
      }
      await bootstrap.close().timeout(_operationTimeout);
      bootstrap = null;

      final platform = IOSRuntimePlatformFactory();
      directories = await platform.acquireDirectories().timeout(
        _operationTimeout,
      );
      final clock = FixedClock(DateTime.utc(2026, 10, 10, 8));
      store = JwStore(
        openJwDatabase(directories.formal),
        ownership: directories.formal,
        clock: clock,
        credentialProtector: platform.schoolCredentials,
        modelCredentialProtector: platform.modelCredentials,
        initialCalendarView: DefaultCalendarView.week,
      );
      await store.initialize().timeout(_operationTimeout);
      final jwAuthority = await store.readAuthority().timeout(
        _operationTimeout,
      );
      final youngAuthority = await store.readYoungAuthority().timeout(
        _operationTimeout,
      );
      if (jwAuthority.accountBound || youngAuthority.accountBound) {
        throw StateError('fresh_simulator_store_required');
      }
      browser = platform.createBrowser();
      return _I2Harness(
        directories: directories,
        store: store,
        browser: browser,
        jwRegistry: JwPartitionRegistry(directories.formal),
        youngRegistry: YoungPartitionRegistry(directories.formal),
        leases: WorkLeasePool(),
        clock: clock,
      );
    } on Object {
      if (browser != null) {
        try {
          await browser.dispose();
        } on Object {
          // Keep setup failure details out of test output and diagnostics.
        }
      }
      if (store != null) {
        try {
          await store.close();
        } on Object {
          // Continue releasing the owner below.
        }
      }
      if (directories != null) {
        try {
          await directories.formal.release();
          await directories.demo.release();
        } on Object {
          // A failed owner release is reported by the original setup failure.
        }
      }
      if (bootstrap != null) {
        try {
          await bootstrap.close();
        } on Object {
          // Keep the native owner rather than attempting a second acquisition.
        }
      }
      debugPrint('I2 synthetic phase: setup failed');
      rethrow;
    }
  }
}

Future<Set<String>> _partitionNames(
  OwnedDirectory owner, {
  required String root,
  required String prefix,
}) async {
  owner.ensureHeld();
  final rootPath = owner.checkedChildPath(root, directory: true);
  final rootDirectory = Directory(rootPath);
  if (!await rootDirectory.exists().timeout(_operationTimeout)) {
    return <String>{};
  }
  final pattern = RegExp(r'^' + prefix + r'-[0-9a-f]{32}$');
  final names = <String>{};
  await for (final entry
      in rootDirectory.list(followLinks: false).timeout(_operationTimeout)) {
    if (entry is Directory) {
      final name = p.posix.basename(entry.path);
      if (pattern.hasMatch(name)) names.add(name);
    }
  }
  return names;
}

int _session() => ++_nextSession;

Future<BrowserEvent> _openFixture(
  NativeObservationBrowser browser, {
  required int session,
  required String profilePath,
  required ObservationTarget target,
}) async {
  final ready = browser.events.firstWhere(
    (event) => event.session == session && event.kind == BrowserEventKind.ready,
  );
  await browser
      .open(session: session, profilePath: profilePath, target: target)
      .timeout(_nativeTimeout);
  return ready.timeout(_nativeTimeout);
}

Future<BrowserEvent> _exerciseDocumentChange(
  NativeObservationBrowser browser, {
  required int session,
  required int document,
  required String action,
}) async {
  final nextReady = browser.events.firstWhere(
    (event) =>
        event.session == session &&
        event.kind == BrowserEventKind.ready &&
        event.document > document,
  );
  await browser
      .exerciseFixture(session: session, document: document, action: action)
      .timeout(_nativeTimeout);
  final next = await nextReady.timeout(_nativeTimeout);
  expect(next.document, greaterThan(document));
  await expectLater(
    browser.inspect(session: session, document: document),
    throwsA(
      isA<AppFailure>().having(
        (error) => error.code,
        'code',
        FailureCode.staleResult,
      ),
    ),
  );
  return next;
}

Future<void> _closeDrained(
  NativeObservationBrowser browser,
  int session,
) async {
  await closeAndDrainI2(browser, session, timeout: _nativeTimeout);
}

Future<void> _recoveryDrain(
  NativeObservationBrowser browser, {
  required String profilePath,
  required ObservationTarget target,
}) async {
  final session = _session();
  // Recovery-only open proves the native ledger can drain without navigating.
  await browser
      .open(
        session: session,
        profilePath: profilePath,
        target: target,
        recoveryOnly: true,
      )
      .timeout(_nativeTimeout);
  await _closeDrained(browser, session);
}

Future<bool> _i2Fixture(int session, int document, String action) async {
  final result = await _debugChannel
      .invokeMethod<Object?>('i2Fixture', {
        'session': session,
        'document': document,
        'action': action,
      })
      .timeout(_nativeTimeout);
  if (result is! bool) throw StateError('invalid_i2_fixture_result');
  return result;
}

Future<bool> _i2StoreExists(String profilePath, String source) async {
  final result = await _debugChannel
      .invokeMethod<Object?>('i2StoreExists', {
        'profilePath': profilePath,
        'source': source,
      })
      .timeout(_nativeTimeout);
  if (result is! bool) throw StateError('invalid_i2_store_result');
  return result;
}

Future<void> _waitFor(
  bool Function() condition, {
  required String message,
  Duration timeout = _operationTimeout,
}) async {
  final elapsed = Stopwatch()..start();
  while (!condition()) {
    if (elapsed.elapsed >= timeout) throw StateError(message);
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}
