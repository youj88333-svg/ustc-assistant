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
import 'package:ustc_assistant_m0/source/jw_authentication_contract.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';
import 'package:ustc_assistant_m0/source/young_active_contract.dart';
import 'package:ustc_assistant_m0/app/demo_runtime.dart';

import 'support/jw_sync_fixture.dart';
import 'support/ios_i2_sso_fixture.dart';
import 'support/ios_i2_drain.dart';
import 'support/ios_i2_http.dart';
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
        () => HttpOverrides.runWithHttpOverrides(
          () => _runI2Scenario(),
          IOSI2LoopbackHttpOverrides(),
        ),
      );
    },
    skip: !Platform.isIOS,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

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
    debugPrint('I2 synthetic phase: JW manual SSO and recovery');
    await _runManualI2Sso(harness);

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
    for (var sample = 0; sample < 10; sample++) {
      expect(
        await _i2StoreExists(secondJwStorePath, 'jw'),
        isFalse,
        reason: 'a drained UUID must not reappear after registry cleanup',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
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

    // Young permits metadata-only same-URL push/replace. Real document changes
    // still revoke old calls. This disposable observation is removed on close.
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
    for (final action in ['youngSameUrlPush', 'youngSameUrlReplace']) {
      await harness.browser.exerciseFixture(
        session: temporaryYoungSession,
        document: youngReady.document,
        action: action,
      );
      expect(
        (await harness.browser.inspect(
          session: temporaryYoungSession,
          document: youngReady.document,
        )).ready,
        isTrue,
      );
      expect(
        await harness.browser.prepareYoungBusinessPage(
          session: temporaryYoungSession,
          document: youngReady.document,
          page: YoungBusinessPage.calendar,
        ),
        isTrue,
      );
    }
    youngReady = await _exerciseDocumentChange(
      harness.browser,
      session: temporaryYoungSession,
      document: youngReady.document,
      action: 'nextDocument',
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
    // Recovery-only drains may still need the fixed target's bound port.
    // Keep the fixture alive until all source/partition teardown has finished.
    if (jwFixture != null) {
      cleanupComplete = await attempt(jwFixture.close) && cleanupComplete;
    }
    if (youngFixture != null) {
      cleanupComplete = await attempt(youngFixture.close) && cleanupComplete;
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

Future<void> _runManualI2Sso(_I2Harness harness) async {
  IOSI2SsoFixture? ssoFixture;
  JwSyncFixture? businessFixture;
  JwSyncCoordinator? manualCoordinator;
  var sessionCleared = false;
  var primaryFailure = false;
  var cleanupComplete = true;

  Future<bool> attempt(Future<void> Function() action) async {
    try {
      await action().timeout(_operationTimeout);
      return true;
    } on Object {
      return false;
    }
  }

  try {
    final sso = await IOSI2SsoFixture.start();
    ssoFixture = sso;
    final business = await JwSyncFixture.start(
      requireLogin: true,
      syntheticIdentityOrigin: sso.origin,
    );
    businessFixture = business;
    sso.configureBusinessOrigin(Uri.parse(business.initialUri.origin));
    final target = ObservationTarget.fixture(
      business.initialUri,
      additionalOrigins: [sso.origin],
    );
    final coordinator = JwSyncCoordinator(
      store: harness.store,
      registry: JwPartitionRegistry(harness.directories.formal),
      browser: harness.browser,
      leases: harness.leases,
      clock: harness.clock,
      loginWaitTimeout: const Duration(seconds: 30),
      automationPollInterval: const Duration(milliseconds: 100),
      target: target,
    );
    manualCoordinator = coordinator;
    await coordinator.initialize().timeout(_operationTimeout);

    final startupEvents = <BrowserEvent>[];
    final startupSubscription = harness.browser.events.listen(
      startupEvents.add,
    );
    try {
      await coordinator
          .startSync(expectedAccountCode: _account, semesterId: 20261)
          .timeout(_operationTimeout);
    } finally {
      await startupSubscription.cancel();
    }
    expect(coordinator.syncView.phase, JwSyncPhase.login);
    expect(coordinator.syncView.automation, JwAutomationState.manualRequired);
    expect(
      coordinator.syncView.loginPauseReason,
      JwLoginPauseReason.manualRequired,
    );
    final firstNavigation = startupEvents.firstWhere(
      (event) => event.kind == BrowserEventKind.navigating,
    );
    final session = firstNavigation.session;
    final loginReady = startupEvents.lastWhere(
      (event) =>
          event.session == session &&
          event.kind == BrowserEventKind.ready &&
          event.origin == target.initialUri.origin,
    );
    final loginInspection = await harness.browser.inspect(
      session: session,
      document: loginReady.document,
    );
    expect(loginInspection.ready, isTrue);
    expect(loginInspection.windowVisible, isTrue);
    expect(_jwCatalogReadCount(business), 0);
    expect(sso.loginPageRequestCount, 0);

    debugPrint('I2 synthetic phase: open fixed identity page');
    final firstCasReadyFuture = _nextI2Event(
      harness.browser,
      session: session,
      afterDocument: loginReady.document,
      kind: BrowserEventKind.ready,
      origin: sso.origin.origin,
    );
    await _iosI2Exercise(
      session: session,
      document: loginReady.document,
      action: 'authentication',
    );
    final firstCasReady = await firstCasReadyFuture;
    expect(sso.loginPageRequestCount, 1);
    expect(sso.formPostCount, 0);

    for (final action in const [
      'iosNavigationCancelled',
      'iosPolicyInterrupted',
      'iosRetiredNavigationFailed',
    ]) {
      await _iosI2Exercise(
        session: session,
        document: firstCasReady.document,
        action: action,
      );
      final inspection = await harness.browser.inspect(
        session: session,
        document: firstCasReady.document,
      );
      expect(inspection.ready, isTrue);
      expect(inspection.windowVisible, isTrue);
    }

    debugPrint('I2 synthetic phase: recover current navigation failure');
    final failedNavigationFuture = _nextI2Event(
      harness.browser,
      session: session,
      afterDocument: firstCasReady.document,
      kind: BrowserEventKind.navigating,
    );
    await _iosI2Exercise(
      session: session,
      document: firstCasReady.document,
      action: 'iosNavigationFailed',
    );
    final failedNavigation = await failedNavigationFuture;
    final failedInspection = await harness.browser.inspect(
      session: session,
      document: failedNavigation.document,
    );
    expect(failedInspection.ready, isFalse);
    expect(failedInspection.windowVisible, isTrue);
    final diagnostics = await _platformChannel
        .invokeMapMethod<String, Object?>('i2BrowserDiagnostics')
        .timeout(_nativeTimeout);
    expect(diagnostics, isNotNull);
    expect(diagnostics!.keys.toSet(), const {
      'kind',
      'source',
      'state',
      'lastEvent',
      'failureStage',
      'errorDomain',
      'errorCode',
      'cleanupStage',
      'cleanupFailure',
      'cleanupErrorDomain',
      'cleanupErrorCode',
    });
    expect(diagnostics['kind'], 'ios-i2-browser-diagnostics-v1');
    expect(diagnostics['source'], 'jw');
    expect(diagnostics['state'], 'open');
    expect(diagnostics['lastEvent'], 'navigationFailed');
    expect(diagnostics['failureStage'], 'provisionalNavigation');
    expect(diagnostics['errorDomain'], 'urlLoading');
    expect(diagnostics['errorCode'], -1009);
    expect(diagnostics['cleanupStage'], 'none');
    expect(diagnostics['cleanupFailure'], 'none');
    expect(diagnostics['cleanupErrorDomain'], 'none');
    expect(diagnostics['cleanupErrorCode'], isNull);

    debugPrint('I2 synthetic phase: reopen failed login window');
    await _iosI2Exercise(
      session: session,
      document: failedNavigation.document,
      action: 'iosReturnToApp',
    );
    final hiddenFailedInspection = await harness.browser.inspect(
      session: session,
      document: failedNavigation.document,
    );
    expect(hiddenFailedInspection.ready, isFalse);
    expect(hiddenFailedInspection.windowVisible, isFalse);
    await coordinator.continueSync().timeout(_operationTimeout);
    expect(coordinator.syncView.phase, JwSyncPhase.login);
    expect(coordinator.syncView.automation, JwAutomationState.manualRequired);
    final restoredFailedInspection = await harness.browser.inspect(
      session: session,
      document: failedNavigation.document,
    );
    expect(restoredFailedInspection.ready, isFalse);
    expect(restoredFailedInspection.windowVisible, isTrue);
    await _iosI2Exercise(
      session: session,
      document: failedNavigation.document,
      action: 'iosRetiredNavigationFinished',
    );
    final retiredFinishInspection = await harness.browser.inspect(
      session: session,
      document: failedNavigation.document,
    );
    expect(retiredFinishInspection.ready, isFalse);
    expect(retiredFinishInspection.windowVisible, isTrue);

    debugPrint('I2 synthetic phase: retry registered initial GET');
    final retriedLoginFuture = _nextI2Event(
      harness.browser,
      session: session,
      afterDocument: failedNavigation.document,
      kind: BrowserEventKind.ready,
      origin: target.initialUri.origin,
    );
    await _iosI2Exercise(
      session: session,
      document: failedNavigation.document,
      action: 'iosRetryInitial',
    );
    final retriedLogin = await retriedLoginFuture;
    final secondCasReadyFuture = _nextI2Event(
      harness.browser,
      session: session,
      afterDocument: retriedLogin.document,
      kind: BrowserEventKind.ready,
      origin: sso.origin.origin,
    );
    await _iosI2Exercise(
      session: session,
      document: retriedLogin.document,
      action: 'authentication',
    );
    final secondCasReady = await secondCasReadyFuture;
    expect(sso.loginPageRequestCount, 2);
    expect(sso.formPostCount, 0);

    debugPrint('I2 synthetic phase: submit one fixed synthetic form');
    final callbackReadyFuture = _nextI2Event(
      harness.browser,
      session: session,
      afterDocument: secondCasReady.document,
      kind: BrowserEventKind.ready,
      origin: target.initialUri.origin,
    );
    await _iosI2Exercise(
      session: session,
      document: secondCasReady.document,
      action: 'submitAuthForm',
    );
    await business.callbackEntered.future.timeout(_nativeTimeout);
    final callbackReady = await callbackReadyFuture;
    expect(callbackReady.document, greaterThan(secondCasReady.document));
    expect(callbackReady.origin, target.initialUri.origin);
    expect(sso.acceptedSubmissionCount, 1);
    expect(sso.formPostCount, 1);
    expect(business.syntheticSsoCallbackCount, 1);
    expect(business.authenticationSubmissions, 0);
    expect(_jwCatalogReadCount(business), 0);

    // The callback route is still authentication context. Continuing here
    // must pause again and must not read the fixed business catalog.
    debugPrint('I2 synthetic phase: hold authentication callback');
    await coordinator.continueSync().timeout(_operationTimeout);
    expect(coordinator.syncView.phase, JwSyncPhase.login);
    expect(coordinator.syncView.automation, JwAutomationState.manualRequired);
    expect(_jwCatalogReadCount(business), 0);

    debugPrint('I2 synthetic phase: release callback and return to app');
    final homeReadyFuture = _nextI2Event(
      harness.browser,
      session: session,
      afterDocument: callbackReady.document,
      kind: BrowserEventKind.ready,
      origin: target.initialUri.origin,
    );
    business.releaseCallback.complete();
    await _waitFor(
      () => business.authenticatedHomeCount == 1,
      message: 'synthetic authenticated home was not reached',
    );
    final homeReady = await homeReadyFuture;
    expect(homeReady.document, greaterThan(callbackReady.document));
    await _iosI2Exercise(
      session: session,
      document: homeReady.document,
      action: 'iosReturnToApp',
    );
    final returnedInspection = await harness.browser.inspect(
      session: session,
      document: homeReady.document,
    );
    expect(returnedInspection.ready, isTrue);
    expect(returnedInspection.windowVisible, isFalse);

    debugPrint('I2 synthetic phase: continue and import after return');
    await coordinator.continueSync().timeout(_operationTimeout);
    expect(coordinator.syncView.phase, JwSyncPhase.idle);
    expect(coordinator.syncView.importCommitted, isTrue);
    var imported = await harness.store.readView().timeout(_operationTimeout);
    expect(imported.credentialSaved, isFalse);
    expect(
      imported.events.any((event) => event.kind == JwEventKind.course),
      isTrue,
    );
    expect(
      imported.events.any((event) => event.kind == JwEventKind.exam),
      isTrue,
    );
    expect(_jwCatalogReadCount(business), greaterThan(0));
    expect(sso.acceptedSubmissionCount, 1);

    debugPrint('I2 synthetic phase: repeat import and clear login session');
    final firstLocalIds = imported.events.map((event) => event.localId).toSet();
    final missingAuthBeforeRepeat = business.missingAuthRedirectCount;
    final repeatEvents = <BrowserEvent>[];
    final repeatSubscription = harness.browser.events.listen(repeatEvents.add);
    var repeatRequiredLogin = false;
    try {
      await coordinator
          .startSync(expectedAccountCode: _account, semesterId: 20261)
          .timeout(_operationTimeout);
      expect(coordinator.syncView.profileReused, isTrue);
      if (coordinator.syncView.phase == JwSyncPhase.login) {
        // Observe a missing synthetic auth marker on the retained profile,
        // without inferring its internal cause. Exercise the approved manual
        // reauthentication path without changing Cookie lifetime or row IDs.
        repeatRequiredLogin = true;
        expect(
          coordinator.syncView.automation,
          JwAutomationState.manualRequired,
        );
        expect(
          coordinator.syncView.loginPauseReason,
          JwLoginPauseReason.manualRequired,
        );
        expect(business.missingAuthRedirectCount, missingAuthBeforeRepeat + 1);
        final repeatLogin = repeatEvents.lastWhere(
          (event) =>
              event.kind == BrowserEventKind.ready &&
              event.origin == target.initialUri.origin,
        );
        final repeatCasFuture = _nextI2Event(
          harness.browser,
          session: repeatLogin.session,
          afterDocument: repeatLogin.document,
          kind: BrowserEventKind.ready,
          origin: sso.origin.origin,
        );
        await _iosI2Exercise(
          session: repeatLogin.session,
          document: repeatLogin.document,
          action: 'authentication',
        );
        final repeatCas = await repeatCasFuture;
        final homeCount = business.authenticatedHomeCount;
        await _iosI2Exercise(
          session: repeatCas.session,
          document: repeatCas.document,
          action: 'submitAuthForm',
        );
        await _waitFor(
          () => business.authenticatedHomeCount == homeCount + 1,
          message: 'repeat synthetic authenticated home was not reached',
        );
        // The callback barrier is already released. Poll the actual fixed
        // readiness contract rather than guessing when its redirect finished.
        final repeatHome = await _waitForI2BusinessReady(
          harness.browser,
          repeatEvents,
          session: repeatCas.session,
          afterDocument: repeatCas.document,
          origin: target.initialUri.origin,
        );
        await _iosI2Exercise(
          session: repeatHome.session,
          document: repeatHome.document,
          action: 'iosReturnToApp',
        );
        await coordinator.continueSync().timeout(_operationTimeout);
      } else {
        expect(business.missingAuthRedirectCount, missingAuthBeforeRepeat);
      }
    } finally {
      await repeatSubscription.cancel();
    }
    expect(coordinator.syncView.phase, JwSyncPhase.idle);
    expect(coordinator.syncView.importCommitted, isTrue);
    final repeated = await harness.store.readView().timeout(_operationTimeout);
    expect(repeated.courseCount, imported.courseCount);
    expect(repeated.examCount, imported.examCount);
    expect(repeated.events.length, imported.events.length);
    expect(
      repeated.events.map((event) => event.localId).toSet(),
      firstLocalIds,
    );
    expect(repeated.credentialSaved, isFalse);
    imported = repeated;

    await coordinator.clearSession().timeout(_operationTimeout);
    sessionCleared = true;
    expect(coordinator.syncView.phase, JwSyncPhase.idle);
    expect(coordinator.syncView.sessionRetained, isFalse);
    final afterClear = await harness.store.readView().timeout(
      _operationTimeout,
    );
    expect(afterClear.courseCount, imported.courseCount);
    expect(afterClear.examCount, imported.examCount);
    expect(afterClear.events.length, imported.events.length);
    expect(afterClear.credentialSaved, isFalse);
    expect(sso.acceptedSubmissionCount, repeatRequiredLogin ? 2 : 1);
    expect(sso.formPostCount, repeatRequiredLogin ? 2 : 1);
    await coordinator.shutdown().timeout(_operationTimeout);
    manualCoordinator = null;
    debugPrint(
      'I2 synthetic repeat required manual login: $repeatRequiredLogin',
    );
    _report['jwManualSsoRepeatRequiredLogin'] = repeatRequiredLogin;
    _report['jwManualSsoRecoveryAndImport'] = true;
  } catch (_) {
    primaryFailure = true;
    debugPrint('I2 synthetic phase: JW manual SSO failed');
    rethrow;
  } finally {
    final business = businessFixture;
    if (business != null && !business.releaseCallback.isCompleted) {
      business.releaseCallback.complete();
    }
    final coordinator = manualCoordinator;
    if (coordinator != null) {
      debugPrint('I2 synthetic phase: JW manual SSO cleanup');
      if (coordinator.syncView.busy) {
        cleanupComplete = await attempt(coordinator.cancel) && cleanupComplete;
      }
      if (coordinator.syncView.phase == JwSyncPhase.recovery) {
        cleanupComplete =
            await attempt(coordinator.retryRecovery) && cleanupComplete;
      }
      if (!sessionCleared && coordinator.syncView.phase == JwSyncPhase.idle) {
        cleanupComplete =
            await attempt(coordinator.clearSession) && cleanupComplete;
      }
      cleanupComplete = await attempt(coordinator.shutdown) && cleanupComplete;
    }
    if (business != null) {
      cleanupComplete = await attempt(business.close) && cleanupComplete;
    }
    final sso = ssoFixture;
    if (sso != null) {
      cleanupComplete = await attempt(sso.close) && cleanupComplete;
    }
    if (!cleanupComplete && !primaryFailure) {
      throw StateError('ios_i2_manual_sso_cleanup_incomplete');
    }
    if (!cleanupComplete) {
      debugPrint('I2 synthetic phase: JW manual SSO cleanup incomplete');
    }
  }
}

Future<BrowserEvent> _nextI2Event(
  NativeObservationBrowser browser, {
  required int session,
  required int afterDocument,
  required BrowserEventKind kind,
  String? origin,
}) => browser.events
    .firstWhere(
      (event) =>
          event.session == session &&
          event.document > afterDocument &&
          event.kind == kind &&
          (origin == null || event.origin == origin),
    )
    .timeout(_nativeTimeout);

Future<BrowserEvent> _waitForI2BusinessReady(
  NativeObservationBrowser browser,
  List<BrowserEvent> events, {
  required int session,
  required int afterDocument,
  required String origin,
}) async {
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsed < _nativeTimeout) {
    final readyEvents = events.where(
      (event) =>
          event.session == session &&
          event.document > afterDocument &&
          event.kind == BrowserEventKind.ready &&
          event.origin == origin,
    );
    if (readyEvents.isNotEmpty) {
      final ready = readyEvents.last;
      try {
        final state = await browser.advanceJwLogin(
          session: session,
          document: ready.document,
          operation: 1,
        );
        if (state == JwLoginState.businessReady) return ready;
      } on AppFailure catch (error) {
        if (error.code != FailureCode.staleResult) rethrow;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  throw StateError('synthetic business document was not ready');
}

Future<void> _iosI2Exercise({
  required int session,
  required int document,
  required String action,
}) async {
  await _debugChannel
      .invokeMethod<void>('exerciseFixture', {
        'session': session,
        'document': document,
        'action': action,
      })
      .timeout(_nativeTimeout);
}

int _jwCatalogReadCount(JwSyncFixture fixture) {
  const catalogPaths = {
    '/for-std/course-table/info/571',
    '/for-std/student-info/info/571',
    '/for-std/course-table/get-data',
    '/for-std/course-table/datum',
    '/for-std/exam-arrange/info/571',
  };
  return fixture.requests
      .where((request) => catalogPaths.any((path) => request.endsWith(path)))
      .length;
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
