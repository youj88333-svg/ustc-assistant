// I2 cross-process retention contract: docs/milestones/ios-private/plan.md,
// docs/architecture/07-12, docs/quality/13, and docs/workflow.md. Run exactly
// one phase in each of two independent flutter test processes on the same
// fresh iOS Simulator, terminating the app without uninstalling between them.
import 'dart:convert';
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
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/platform/ios_runtime_platform_factory.dart';
import 'package:ustc_assistant_m0/platform/jw_partition_registry.dart';
import 'package:ustc_assistant_m0/platform/native_database.dart';
import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';
import 'package:ustc_assistant_m0/platform/owned_directory.dart';
import 'package:ustc_assistant_m0/platform/runtime_platform_factory.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';

import 'support/jw_sync_fixture.dart';
import 'support/ios_i2_drain.dart';

const _phaseDefine = String.fromEnvironment(
  'USTC_I2_PERSISTENCE_PHASE',
  defaultValue: '',
);
const _platformChannel = MethodChannel('ustc_assistant/platform_v1');
const _debugChannel = MethodChannel('ustc_assistant/observation_v1');
const _handoffName = 'ios_i2_persistence_handoff_v1.json';
const _handoffPurpose = 'ios-i2-persistence-handoff-v1';
const _handoffKeys = <String>{
  'version',
  'purpose',
  'profileName',
  'profilePath',
  'fixturePort',
};
const _operationTimeout = Duration(seconds: 45);
const _nativeTimeout = Duration(seconds: 20);
const _writeSession = 9301;
const _readSession = 9302;
var _nextCleanupSession = 9302;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, Object>{};
  tearDown(() => binding.reportData = Map<String, Object>.from(report));

  testWidgets(
    'I2 school store survives an app process restart',
    (tester) async {
      final phase = _persistencePhase();
      if (!Platform.isIOS) throw StateError('ios_simulator_required');
      if (!kDebugMode) throw StateError('debug_build_required');
      final platformStatus = await _platformChannel
          .invokeMapMethod<String, Object?>('storageProtectionStatus')
          .timeout(_nativeTimeout);
      if (platformStatus?['isSimulator'] != true) {
        throw StateError('ios_simulator_required');
      }

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.expand())),
      );
      report['persistencePhase'] = phase;
      await tester.runAsync(
        () => HttpOverrides.runZoned(
          () => _runPhase(phase),
          createHttpClient: (context) {
            final client = HttpClient(context: context);
            client.findProxy = (uri) =>
                _isLoopback(uri) ? 'DIRECT' : 'PROXY 127.0.0.1:9';
            return client;
          },
        ),
      );
      report['phaseCompleted'] = true;
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

String _persistencePhase() {
  final environmentPhase = Platform.environment['USTC_I2_PERSISTENCE_PHASE'];
  final phases = <String>[
    if (_phaseDefine.isNotEmpty) _phaseDefine,
    if (environmentPhase != null && environmentPhase.isNotEmpty)
      environmentPhase,
  ];
  if (phases.isEmpty ||
      phases.any((phase) => phase != 'write' && phase != 'read') ||
      phases.toSet().length != 1) {
    throw StateError('ios_i2_persistence_phase_invalid');
  }
  return phases.single;
}

bool _isLoopback(Uri uri) =>
    uri.host == '127.0.0.1' && (uri.scheme == 'http' || uri.scheme == 'https');

Future<void> _runPhase(String phase) async {
  final platform = IOSRuntimePlatformFactory();
  RuntimeDirectories? directories;
  JwStore? store;
  NativeObservationBrowser? browser;
  JwSyncFixture? fixture;
  JwPartitionRegistry? registry;
  JwPartitionRef? newPartition;
  _PersistenceHandoff? handoff;
  File? handoffFile;
  var profilePath = '';
  var activeSession = 0;
  var retainForReadPhase = false;
  var registryCleaned = false;
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
    final authority = await store.readAuthority().timeout(_operationTimeout);
    final youngAuthority = await store.readYoungAuthority().timeout(
      _operationTimeout,
    );
    final committedJw = await store.readCommittedPermits().timeout(
      _operationTimeout,
    );
    final committedYoung = await store.readYoungPermits().timeout(
      _operationTimeout,
    );
    if (authority.accountBound ||
        youngAuthority.accountBound ||
        committedJw.isNotEmpty ||
        committedYoung.isNotEmpty) {
      throw StateError('fresh_simulator_store_required');
    }

    handoffFile = File(
      directories.demo.checkedChildPath(_handoffName, directory: false),
    );
    if (phase == 'write') {
      if (await handoffFile.exists().timeout(_operationTimeout)) {
        throw StateError('persistence_handoff_already_exists');
      }
      final artifacts = await _jwRegistryArtifacts(directories.formal);
      if (artifacts.isNotEmpty) {
        throw StateError('fresh_simulator_profile_required');
      }
      fixture = await JwSyncFixture.start(requireLogin: false);
      handoff = null;
    } else {
      handoff = await _readHandoff(handoffFile, directories.formal);
      profilePath = handoff.profilePath;
      final artifacts = await _jwRegistryArtifacts(directories.formal);
      if (!artifacts.containsAll({
            handoff.profileName,
            '${handoff.profileName}.json',
          }) ||
          artifacts.difference({
            handoff.profileName,
            '${handoff.profileName}.json',
          }).isNotEmpty) {
        throw StateError('persistence_profile_handoff_mismatch');
      }
      fixture = await JwSyncFixture.start(
        requireLogin: false,
        port: handoff.fixturePort,
      );
    }

    final target = ObservationTarget.fixture(fixture.initialUri);
    browser = platform.createBrowser();
    await browser.ensureAvailable().timeout(_nativeTimeout);

    if (phase == 'write') {
      registry = JwPartitionRegistry(directories.formal);
      await registry
          .reconcile(
            committedJw,
            ownerId: authority.ownerId,
            resetEpoch: authority.resetEpoch,
            drain: (path) =>
                _recoveryDrain(browser!, profilePath: path, target: target),
          )
          .timeout(_operationTimeout);
      newPartition = await registry
          .createProvisional(
            ownerId: authority.ownerId,
            purpose: JwPartitionPurpose.initial,
            attempt: 'jw-950-1',
            resetEpoch: authority.resetEpoch,
          )
          .timeout(_operationTimeout);
      profilePath = registry.profilePath(newPartition);

      final ready = await _openFixture(
        browser,
        session: _writeSession,
        profilePath: profilePath,
        target: target,
      );
      activeSession = _writeSession;
      if (!await _i2Fixture(
        _writeSession,
        ready.document,
        'writeSyntheticMarker',
      )) {
        throw StateError('synthetic_marker_write_failed');
      }
      if (!await _i2Fixture(
        _writeSession,
        ready.document,
        'checkSyntheticMarker',
      )) {
        throw StateError('synthetic_marker_readback_failed');
      }
      await _closeDrained(browser, _writeSession);
      activeSession = 0;
      if (!await _i2StoreExists(profilePath, 'jw')) {
        throw StateError('persistent_store_missing_after_close');
      }

      handoff = _PersistenceHandoff(
        profileName: newPartition.id,
        profilePath: profilePath,
        fixturePort: fixture.initialUri.port,
      );
      await _writeHandoff(handoffFile, handoff);
      await registry.closeForMaintenanceExit().timeout(_operationTimeout);
      registry = null;
      retainForReadPhase = true;
      debugPrint('I2 persistence phase: write complete');
      return;
    }

    final readHandoff = handoff;
    if (readHandoff == null ||
        fixture.initialUri.port != readHandoff.fixturePort ||
        !await Directory(profilePath).exists().timeout(_operationTimeout) ||
        !await _i2StoreExists(profilePath, 'jw')) {
      throw StateError('persistence_handoff_unavailable');
    }
    final ready = await _openFixture(
      browser,
      session: _readSession,
      profilePath: profilePath,
      target: target,
    );
    activeSession = _readSession;
    if (!await _i2Fixture(
      _readSession,
      ready.document,
      'checkSyntheticMarker',
    )) {
      throw StateError('cross_process_marker_not_retained');
    }
    await _closeDrained(browser, _readSession);
    activeSession = 0;
    if (!await _i2StoreExists(profilePath, 'jw')) {
      throw StateError('persistent_store_missing_after_read_close');
    }

    registry = JwPartitionRegistry(directories.formal);
    final beforeCleanupRequests = fixture.requests.length;
    final reconciled = await registry
        .reconcile(
          committedJw,
          ownerId: authority.ownerId,
          resetEpoch: authority.resetEpoch,
          drain: (path) =>
              _recoveryDrain(browser!, profilePath: path, target: target),
        )
        .timeout(_operationTimeout);
    if (reconciled.isNotEmpty) {
      throw StateError('persistence_profile_recovery_incomplete');
    }
    registryCleaned = true;
    if (fixture.requests.length != beforeCleanupRequests) {
      throw StateError('recovery_cleanup_navigated_fixture');
    }
    await registry.close().timeout(_operationTimeout);
    registry = null;
    if (await _i2StoreExists(profilePath, 'jw') ||
        await Directory(profilePath).exists().timeout(_operationTimeout)) {
      throw StateError('persistence_store_cleanup_incomplete');
    }
    await handoffFile.delete().timeout(_operationTimeout);
    debugPrint('I2 persistence phase: read and cleanup complete');
  } finally {
    if (activeSession != 0 && browser != null) {
      cleanupComplete =
          await attempt(() => _closeDrained(browser!, activeSession)) &&
          cleanupComplete;
      activeSession = 0;
    }

    if (!retainForReadPhase &&
        phase == 'write' &&
        newPartition != null &&
        registry != null &&
        fixture != null &&
        browser != null) {
      final partition = newPartition;
      final target = ObservationTarget.fixture(fixture.initialUri);
      cleanupComplete =
          await attempt(
            () => registry!.clear(
              partition,
              (path) =>
                  _recoveryDrain(browser!, profilePath: path, target: target),
            ),
          ) &&
          cleanupComplete;
      final failedPhaseHandoff = handoffFile;
      if (cleanupComplete && failedPhaseHandoff != null) {
        cleanupComplete =
            await attempt(() async {
              if (await failedPhaseHandoff.exists().timeout(
                _operationTimeout,
              )) {
                await failedPhaseHandoff.delete().timeout(_operationTimeout);
              }
            }) &&
            cleanupComplete;
      }
    } else if (phase == 'read' &&
        !registryCleaned &&
        handoff != null &&
        store != null &&
        directories != null &&
        fixture != null &&
        browser != null) {
      try {
        final recoveryRegistry =
            registry ?? JwPartitionRegistry(directories.formal);
        final authority = await store.readAuthority().timeout(
          _operationTimeout,
        );
        await recoveryRegistry
            .reconcile(
              const <JwClaimPermit>[],
              ownerId: authority.ownerId,
              resetEpoch: authority.resetEpoch,
              drain: (path) => _recoveryDrain(
                browser!,
                profilePath: path,
                target: ObservationTarget.fixture(fixture!.initialUri),
              ),
            )
            .timeout(_operationTimeout);
        await recoveryRegistry.close().timeout(_operationTimeout);
        registryCleaned = true;
        if (handoffFile != null &&
            await handoffFile.exists().timeout(_operationTimeout)) {
          await handoffFile.delete().timeout(_operationTimeout);
        }
      } on Object {
        cleanupComplete = false;
      }
    }

    if (registry != null) {
      cleanupComplete =
          await attempt(registry.closeForMaintenanceExit) && cleanupComplete;
    }
    if (fixture != null) {
      cleanupComplete = await attempt(fixture.close) && cleanupComplete;
    }
    if (browser != null) {
      cleanupComplete = await attempt(browser.dispose) && cleanupComplete;
    }
    if (store != null) {
      cleanupComplete = await attempt(store.close) && cleanupComplete;
    }
    if (directories != null) {
      cleanupComplete =
          await attempt(directories.formal.release) && cleanupComplete;
      cleanupComplete =
          await attempt(directories.demo.release) && cleanupComplete;
    }
    if (!cleanupComplete) {
      debugPrint('I2 persistence phase: cleanup incomplete');
      throw StateError('ios_i2_persistence_cleanup_incomplete');
    }
  }
}

final class _PersistenceHandoff {
  const _PersistenceHandoff({
    required this.profileName,
    required this.profilePath,
    required this.fixturePort,
  });

  final String profileName;
  final String profilePath;
  final int fixturePort;

  Map<String, Object> toJson() => <String, Object>{
    'version': 1,
    'purpose': _handoffPurpose,
    'profileName': profileName,
    'profilePath': profilePath,
    'fixturePort': fixturePort,
  };
}

Future<_PersistenceHandoff> _readHandoff(
  File file,
  OwnedDirectory formal,
) async {
  if (await FileSystemEntity.type(
            file.path,
            followLinks: false,
          ).timeout(_operationTimeout) !=
          FileSystemEntityType.file ||
      await file.length().timeout(_operationTimeout) > 1024) {
    throw StateError('persistence_handoff_invalid');
  }
  Object? decoded;
  late final String body;
  try {
    body = await file.readAsString().timeout(_operationTimeout);
    decoded = jsonDecode(body);
  } on Object {
    throw StateError('persistence_handoff_invalid');
  }
  if (decoded is! Map ||
      decoded.length != _handoffKeys.length ||
      decoded.keys.any((key) => key is! String) ||
      decoded.keys.toSet().cast<String>().difference(_handoffKeys).isNotEmpty ||
      _handoffKeys.difference(decoded.keys.cast<String>().toSet()).isNotEmpty ||
      decoded['version'] is! int ||
      decoded['version'] != 1 ||
      decoded['purpose'] != _handoffPurpose ||
      decoded['profileName'] is! String ||
      decoded['profilePath'] is! String ||
      decoded['fixturePort'] is! int) {
    throw StateError('persistence_handoff_invalid');
  }
  final name = decoded['profileName'] as String;
  final path = decoded['profilePath'] as String;
  final port = decoded['fixturePort'] as int;
  if (!RegExp(r'^jwp-[0-9a-f]{32}$').hasMatch(name) ||
      port <= 0 ||
      port > 65535) {
    throw StateError('persistence_handoff_invalid');
  }
  final expectedPath = formal.checkedChildPath(
    'jw_partitions_v1/$name',
    directory: true,
  );
  if (path != expectedPath) throw StateError('persistence_handoff_invalid');
  final handoff = _PersistenceHandoff(
    profileName: name,
    profilePath: path,
    fixturePort: port,
  );
  if (body != jsonEncode(handoff.toJson())) {
    throw StateError('persistence_handoff_invalid');
  }
  return handoff;
}

Future<void> _writeHandoff(File file, _PersistenceHandoff handoff) async {
  final body = jsonEncode(handoff.toJson());
  if (utf8.encode(body).length > 1024) {
    throw StateError('persistence_handoff_invalid');
  }
  if (await FileSystemEntity.type(
        file.path,
        followLinks: false,
      ).timeout(_operationTimeout) !=
      FileSystemEntityType.notFound) {
    throw StateError('persistence_handoff_already_exists');
  }
  await file.writeAsString(body, flush: true).timeout(_operationTimeout);
}

Future<Set<String>> _jwRegistryArtifacts(OwnedDirectory formal) async {
  formal.ensureHeld();
  final rootPath = formal.checkedChildPath('jw_partitions_v1', directory: true);
  final root = Directory(rootPath);
  if (!await root.exists().timeout(_operationTimeout)) return <String>{};
  final names = <String>{};
  await for (final entry
      in root.list(followLinks: false).timeout(_operationTimeout)) {
    names.add(p.posix.basename(entry.path));
  }
  return names;
}

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
  final session = ++_nextCleanupSession;
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
