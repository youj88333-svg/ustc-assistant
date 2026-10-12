import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/observation_assets.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/jobs/observation_coordinator.dart';
import 'package:ustc_assistant_m0/jobs/observation_port.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';

const _timeout = Duration(seconds: 3);

void main() {
  test(
    'diagnostics retain bounded current-session facts without changing readiness',
    () async {
      final browser = _FakeBrowser();
      final coordinator = _coordinator(browser, _FakeAssets(), WorkLeasePool());
      addTearDown(() => _dispose(coordinator, browser));
      await coordinator.open();
      final session = browser.openCalls.single.session;
      browser.emit(
        BrowserEvent(
          session: session,
          document: 1,
          kind: BrowserEventKind.ready,
          origin: coordinator.target.initialUri.origin,
        ),
      );
      const diagnostic = BrowserDiagnostic(
        code: BrowserDiagnosticCode.insecureDocumentUpgraded,
        site: BrowserDiagnosticSite.identity,
        scheme: BrowserDiagnosticScheme.http,
      );
      for (var i = 0; i < 25; i++) {
        browser.emit(
          BrowserEvent(
            session: session,
            document: 1,
            kind: BrowserEventKind.diagnostic,
            diagnostic: diagnostic,
          ),
        );
      }
      expect(coordinator.view.ready, isTrue);
      expect(coordinator.view.blocked, isFalse);
      expect(coordinator.view.diagnostics, hasLength(20));
      expect(
        () => coordinator.view.diagnostics.clear(),
        throwsUnsupportedError,
      );
      await coordinator.closeSession();
      expect(coordinator.view.diagnostics, hasLength(20));
      await coordinator.open();
      browser.emit(
        BrowserEvent(
          session: session,
          document: 99,
          kind: BrowserEventKind.diagnostic,
          diagnostic: diagnostic,
        ),
      );
      expect(coordinator.view.diagnostics, isEmpty);
    },
  );

  test(
    'a shared work lease rejects observation before registering assets',
    () async {
      final leases = WorkLeasePool();
      final holder = leases.acquire();
      final browser = _FakeBrowser();
      final assets = _FakeAssets();
      final coordinator = _coordinator(browser, assets, leases);
      addTearDown(() async {
        holder.release();
        await _dispose(coordinator, browser);
      });

      await expectLater(coordinator.open(), _failure(FailureCode.busy));

      expect(leases.isBusy, isTrue);
      expect(assets.recoverCalls, 0);
      expect(assets.registerCalls, 0);
      expect(browser.openCalls, isEmpty);
    },
  );

  test(
    'cancellation waits for registration and native open, then retains the lease until drain retry',
    () async {
      final lifecycle = <String>[];
      final browser = _FakeBrowser(timeline: lifecycle)
        ..nextOpenGate = Completer<void>()
        ..drainComplete = false;
      final assets = _FakeAssets(timeline: lifecycle)
        ..registerGate = Completer<void>();
      final leases = WorkLeasePool();
      final coordinator = _coordinator(
        browser,
        assets,
        leases,
        drainTimeout: const Duration(milliseconds: 50),
        pollInterval: const Duration(milliseconds: 2),
      );
      addTearDown(() async {
        assets.releaseRegister();
        browser.releaseOpen();
        browser.drainComplete = true;
        await _dispose(coordinator, browser);
      });

      final opening = coordinator.open();
      await assets.registerEntered.future.timeout(_timeout);
      expect(browser.openCalls, isEmpty);

      assets.releaseRegister();
      await browser.openEntered.future.timeout(_timeout);
      expect(browser.openCalls.single.recoveryOnly, isFalse);

      final closing = coordinator.closeSession();
      expect(coordinator.view.phase, ObservationPhase.closing);
      expect(leases.isBusy, isTrue);
      expect(browser.closeCalls, contains(browser.openCalls.single.session));
      expect(assets.cleanupCalls, 0);

      browser.releaseOpen();
      await opening.timeout(_timeout);
      await expectLater(
        closing.timeout(_timeout),
        _failure(FailureCode.cleanupPending),
      );
      expect(browser.closeCalls, contains(browser.openCalls.single.session));
      expect(assets.cleanupCalls, 0);
      expect(coordinator.view.phase, ObservationPhase.recovery);
      expect(leases.isBusy, isTrue);

      browser.drainComplete = true;
      await coordinator.retryCleanup().timeout(_timeout);

      final session = browser.openCalls.single.session;
      expect(lifecycle, contains('close:$session'));
      expect(lifecycle, contains('drained:$session'));
      expect(
        lifecycle.indexOf('cleanup'),
        greaterThan(lifecycle.indexOf('drained:$session')),
      );
      expect(assets.cleanupCalls, 1);
      expect(coordinator.view.phase, ObservationPhase.idle);
      expect(leases.isBusy, isFalse);
    },
  );

  test(
    'cancellation while open is pending retains its profile and lease until retry drains',
    () async {
      final lifecycle = <String>[];
      final browser = _FakeBrowser(timeline: lifecycle)
        ..nextOpenGate = Completer<void>()
        ..drainComplete = false;
      final assets = _FakeAssets(timeline: lifecycle);
      final leases = WorkLeasePool();
      final coordinator = _coordinator(
        browser,
        assets,
        leases,
        drainTimeout: const Duration(milliseconds: 50),
        pollInterval: const Duration(milliseconds: 2),
      );
      addTearDown(() async {
        browser.releaseOpen();
        browser.drainComplete = true;
        await _dispose(coordinator, browser);
      });

      final opening = coordinator.open();
      final openingFailure = expectLater(
        opening,
        _failure(FailureCode.cleanupPending),
      );
      await browser.openEntered.future.timeout(_timeout);
      final session = browser.openCalls.single.session;
      expect(assets.registeredProfilePath, _FakeAssets.profilePath);

      final closing = coordinator.closeSession();
      expect(browser.closeCalls, contains(session));
      await expectLater(
        closing.timeout(_timeout),
        _failure(FailureCode.cleanupPending),
      );
      await openingFailure;

      expect(coordinator.view.phase, ObservationPhase.recovery);
      expect(leases.isBusy, isTrue);
      expect(assets.cleanupCalls, 0);
      expect(assets.registeredProfilePath, _FakeAssets.profilePath);
      expect(lifecycle, isNot(contains('drained:$session')));
      expect(lifecycle, isNot(contains('cleanup')));

      browser.releaseOpen();
      await browser.openCalls.single.completion.future.timeout(_timeout);
      browser.drainComplete = true;
      await coordinator.retryCleanup().timeout(_timeout);

      expect(lifecycle, contains('close:$session'));
      expect(lifecycle, contains('drained:$session'));
      expect(
        lifecycle.indexOf('cleanup'),
        greaterThan(lifecycle.indexOf('drained:$session')),
      );
      expect(assets.cleanupCalls, 1);
      expect(assets.registeredProfilePath, isNull);
      expect(coordinator.view.phase, ObservationPhase.idle);
      expect(leases.isBusy, isFalse);
    },
  );

  test(
    'a hanging native close times out into recovery and retains the profile and lease',
    () async {
      final lifecycle = <String>[];
      final browser = _FakeBrowser(timeline: lifecycle)
        ..closeGate = Completer<void>();
      final assets = _FakeAssets(timeline: lifecycle);
      final leases = WorkLeasePool();
      final coordinator = _coordinator(
        browser,
        assets,
        leases,
        drainTimeout: const Duration(milliseconds: 50),
        pollInterval: const Duration(milliseconds: 2),
      );
      addTearDown(() => _dispose(coordinator, browser));

      await coordinator.open().timeout(_timeout);
      final session = browser.openCalls.single.session;
      final closing = coordinator.closeSession();
      await browser.closeEntered.future.timeout(_timeout);
      await expectLater(
        closing.timeout(_timeout),
        _failure(FailureCode.cleanupPending),
      );

      expect(coordinator.view.phase, ObservationPhase.recovery);
      expect(leases.isBusy, isTrue);
      expect(assets.cleanupCalls, 0);
      expect(assets.registeredProfilePath, _FakeAssets.profilePath);
      expect(lifecycle, contains('close:$session'));
      expect(lifecycle, isNot(contains('drained:$session')));
      expect(lifecycle, isNot(contains('cleanup')));

      browser.releaseClose();
      browser.drainComplete = true;
      await coordinator.retryCleanup().timeout(_timeout);

      expect(lifecycle, contains('drained:$session'));
      expect(
        lifecycle.indexOf('cleanup'),
        greaterThan(lifecycle.indexOf('drained:$session')),
      );
      expect(assets.cleanupCalls, 1);
      expect(assets.registeredProfilePath, isNull);
      expect(coordinator.view.phase, ObservationPhase.idle);
      expect(leases.isBusy, isFalse);
    },
  );

  test(
    'a hanging drained check times out into recovery and retains the profile and lease',
    () async {
      final lifecycle = <String>[];
      final browser = _FakeBrowser(timeline: lifecycle)
        ..drainedGate = Completer<bool>();
      final assets = _FakeAssets(timeline: lifecycle);
      final leases = WorkLeasePool();
      final coordinator = _coordinator(
        browser,
        assets,
        leases,
        drainTimeout: const Duration(milliseconds: 50),
        pollInterval: const Duration(milliseconds: 2),
      );
      addTearDown(() => _dispose(coordinator, browser));

      await coordinator.open().timeout(_timeout);
      final session = browser.openCalls.single.session;
      final closing = coordinator.closeSession();
      await browser.drainedEntered.future.timeout(_timeout);
      await expectLater(
        closing.timeout(_timeout),
        _failure(FailureCode.cleanupPending),
      );

      expect(coordinator.view.phase, ObservationPhase.recovery);
      expect(leases.isBusy, isTrue);
      expect(assets.cleanupCalls, 0);
      expect(assets.registeredProfilePath, _FakeAssets.profilePath);
      expect(lifecycle, contains('close:$session'));
      expect(lifecycle, isNot(contains('drained:$session')));
      expect(lifecycle, isNot(contains('cleanup')));

      browser.releaseDrained();
      await coordinator.retryCleanup().timeout(_timeout);

      expect(lifecycle, contains('drained:$session'));
      expect(
        lifecycle.indexOf('cleanup'),
        greaterThan(lifecycle.indexOf('drained:$session')),
      );
      expect(assets.cleanupCalls, 1);
      expect(assets.registeredProfilePath, isNull);
      expect(coordinator.view.phase, ObservationPhase.idle);
      expect(leases.isBusy, isFalse);
    },
  );

  test(
    'initialization is serialized by the shared lease and can be repeated',
    () async {
      final browser = _FakeBrowser()..drainComplete = false;
      final assets = _FakeAssets()..pendingRecoveryPath = 'stale-profile';
      final leases = WorkLeasePool();
      final coordinator = _coordinator(
        browser,
        assets,
        leases,
        drainTimeout: const Duration(seconds: 1),
        pollInterval: const Duration(milliseconds: 2),
      );
      addTearDown(() => _dispose(coordinator, browser));

      final firstInitialization = coordinator.initialize();
      await browser.openEntered.future.timeout(_timeout);
      await browser.closeEntered.future.timeout(_timeout);
      await expectLater(coordinator.initialize(), _failure(FailureCode.busy));

      expect(leases.isBusy, isTrue);
      expect(assets.recoverCalls, 1);
      expect(browser.openCalls, hasLength(1));

      browser.drainComplete = true;
      await firstInitialization.timeout(_timeout);
      await coordinator.initialize().timeout(_timeout);

      expect(assets.recoverCalls, 2);
      expect(browser.openCalls, hasLength(1));
      expect(coordinator.view.phase, ObservationPhase.idle);
      expect(leases.isBusy, isFalse);
    },
  );

  test(
    'a timed out opening retains its profile and lease for cleanup retry',
    () async {
      final lifecycle = <String>[];
      final browser = _FakeBrowser(timeline: lifecycle)
        ..nextOpenGate = Completer<void>();
      final assets = _FakeAssets(timeline: lifecycle);
      final leases = WorkLeasePool();
      final coordinator = _coordinator(
        browser,
        assets,
        leases,
        drainTimeout: const Duration(milliseconds: 50),
        pollInterval: const Duration(milliseconds: 2),
      );
      addTearDown(() => _dispose(coordinator, browser));

      final opening = coordinator.open();
      await browser.openEntered.future.timeout(_timeout);
      final session = browser.openCalls.single.session;
      await expectLater(
        opening.timeout(_timeout),
        _failure(FailureCode.cleanupPending),
      );

      expect(coordinator.view.phase, ObservationPhase.recovery);
      expect(leases.isBusy, isTrue);
      expect(assets.cleanupCalls, 0);
      expect(assets.registeredProfilePath, _FakeAssets.profilePath);

      browser.releaseOpen();
      await browser.openCalls.single.completion.future.timeout(_timeout);
      browser.drainComplete = true;
      await coordinator.retryCleanup().timeout(_timeout);

      expect(lifecycle, contains('close:$session'));
      expect(lifecycle, contains('drained:$session'));
      expect(
        lifecycle.indexOf('cleanup'),
        greaterThan(lifecycle.indexOf('drained:$session')),
      );
      expect(assets.cleanupCalls, 1);
      expect(assets.registeredProfilePath, isNull);
      expect(coordinator.view.phase, ObservationPhase.idle);
      expect(leases.isBusy, isFalse);
    },
  );

  test(
    'inspect timeout returns sourceFailed and late results cannot ready a newer document',
    () async {
      final lifecycle = <String>[];
      final browser = _FakeBrowser(timeline: lifecycle)
        ..drainedGate = Completer<bool>();
      final assets = _FakeAssets(timeline: lifecycle);
      final leases = WorkLeasePool();
      final coordinator = _coordinator(
        browser,
        assets,
        leases,
        drainTimeout: const Duration(milliseconds: 50),
        pollInterval: const Duration(milliseconds: 2),
      );
      addTearDown(() => _dispose(coordinator, browser));

      await coordinator.open().timeout(_timeout);
      final session = browser.openCalls.single.session;
      final origin = coordinator.target.initialUri.origin;
      browser.emit(
        BrowserEvent(
          session: session,
          document: 1,
          kind: BrowserEventKind.ready,
          origin: origin,
        ),
      );
      final inspecting = coordinator.inspect();

      await expectLater(inspecting, _failure(FailureCode.sourceFailed));
      expect(coordinator.view.phase, ObservationPhase.open);
      expect(leases.isBusy, isTrue);
      expect(assets.cleanupCalls, 0);
      expect(assets.registeredProfilePath, _FakeAssets.profilePath);

      browser.emit(
        BrowserEvent(
          session: session,
          document: 2,
          kind: BrowserEventKind.navigating,
          origin: origin,
        ),
      );
      browser.completeInspection(
        0,
        BrowserInspection(
          session: session,
          document: 1,
          ready: true,
          origin: origin,
        ),
      );
      browser.emit(
        BrowserEvent(
          session: session,
          document: 1,
          kind: BrowserEventKind.ready,
          origin: origin,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(coordinator.view.ready, isFalse);
      expect(coordinator.view.origin, origin);

      final closing = coordinator.closeSession();
      await browser.drainedEntered.future.timeout(_timeout);
      await expectLater(
        closing.timeout(_timeout),
        _failure(FailureCode.cleanupPending),
      );
      expect(leases.isBusy, isTrue);
      expect(assets.cleanupCalls, 0);
      expect(assets.registeredProfilePath, _FakeAssets.profilePath);

      browser.releaseDrained();
      await coordinator.retryCleanup().timeout(_timeout);

      expect(lifecycle, contains('drained:$session'));
      expect(
        lifecycle.indexOf('cleanup'),
        greaterThan(lifecycle.indexOf('drained:$session')),
      );
      expect(assets.registeredProfilePath, isNull);
      expect(leases.isBusy, isFalse);
    },
  );

  test(
    'navigate timeout returns sourceFailed and an old ready event cannot authorize a newer document',
    () async {
      final lifecycle = <String>[];
      final browser = _FakeBrowser(timeline: lifecycle)
        ..navigateGate = Completer<void>()
        ..drainedGate = Completer<bool>();
      final assets = _FakeAssets(timeline: lifecycle);
      final leases = WorkLeasePool();
      final coordinator = _coordinator(
        browser,
        assets,
        leases,
        drainTimeout: const Duration(milliseconds: 50),
        pollInterval: const Duration(milliseconds: 2),
      );
      addTearDown(() => _dispose(coordinator, browser));

      await coordinator.open().timeout(_timeout);
      final session = browser.openCalls.single.session;
      final origin = coordinator.target.initialUri.origin;
      browser.emit(
        BrowserEvent(
          session: session,
          document: 1,
          kind: BrowserEventKind.ready,
          origin: origin,
        ),
      );
      expect(coordinator.view.ready, isTrue);

      final navigating = coordinator.navigateInitial();
      await browser.navigateEntered.future.timeout(_timeout);
      await expectLater(navigating, _failure(FailureCode.sourceFailed));
      expect(coordinator.view.phase, ObservationPhase.open);
      expect(coordinator.view.ready, isFalse);
      expect(leases.isBusy, isTrue);
      expect(assets.cleanupCalls, 0);
      expect(assets.registeredProfilePath, _FakeAssets.profilePath);

      browser.emit(
        BrowserEvent(
          session: session,
          document: 2,
          kind: BrowserEventKind.navigating,
          origin: origin,
        ),
      );
      browser.emit(
        BrowserEvent(
          session: session,
          document: 1,
          kind: BrowserEventKind.ready,
          origin: origin,
        ),
      );
      browser.releaseNavigate();
      await browser.navigateCompletion.future.timeout(_timeout);
      expect(coordinator.view.ready, isFalse);

      final closing = coordinator.closeSession();
      await browser.drainedEntered.future.timeout(_timeout);
      await expectLater(
        closing.timeout(_timeout),
        _failure(FailureCode.cleanupPending),
      );
      expect(leases.isBusy, isTrue);
      expect(assets.cleanupCalls, 0);
      expect(assets.registeredProfilePath, _FakeAssets.profilePath);

      browser.releaseDrained();
      await coordinator.retryCleanup().timeout(_timeout);

      expect(lifecycle, contains('drained:$session'));
      expect(
        lifecycle.indexOf('cleanup'),
        greaterThan(lifecycle.indexOf('drained:$session')),
      );
      expect(assets.registeredProfilePath, isNull);
      expect(leases.isBusy, isFalse);
    },
  );

  test('an inspection result from a previous document is rejected', () async {
    final browser = _FakeBrowser();
    final assets = _FakeAssets();
    final leases = WorkLeasePool();
    final coordinator = _coordinator(browser, assets, leases);
    addTearDown(() => _dispose(coordinator, browser));

    await coordinator.open().timeout(_timeout);
    final session = browser.openCalls.single.session;
    browser.emit(
      BrowserEvent(
        session: session,
        document: 1,
        kind: BrowserEventKind.navigating,
        origin: coordinator.target.initialUri.origin,
      ),
    );

    final inspecting = coordinator.inspect();
    expect(browser.inspectCalls, hasLength(1));
    browser.emit(
      BrowserEvent(
        session: session,
        document: 2,
        kind: BrowserEventKind.navigating,
        origin: coordinator.target.initialUri.origin,
      ),
    );
    browser.completeInspection(
      0,
      BrowserInspection(
        session: session,
        document: 1,
        ready: true,
        origin: coordinator.target.initialUri.origin,
      ),
    );

    await expectLater(inspecting, _failure(FailureCode.staleResult));
    expect(coordinator.view.ready, isFalse);
  });

  test('an inspection result arriving after close is rejected', () async {
    final browser = _FakeBrowser();
    final assets = _FakeAssets();
    final leases = WorkLeasePool();
    final coordinator = _coordinator(browser, assets, leases);
    addTearDown(() => _dispose(coordinator, browser));

    await coordinator.open().timeout(_timeout);
    final session = browser.openCalls.single.session;
    browser.emit(
      BrowserEvent(
        session: session,
        document: 1,
        kind: BrowserEventKind.ready,
        origin: coordinator.target.initialUri.origin,
      ),
    );

    final inspecting = coordinator.inspect();
    await coordinator.closeSession().timeout(_timeout);
    browser.completeInspection(
      0,
      BrowserInspection(
        session: session,
        document: 1,
        ready: true,
        origin: coordinator.target.initialUri.origin,
      ),
    );

    await expectLater(inspecting, _failure(FailureCode.staleResult));
    expect(coordinator.view.phase, ObservationPhase.idle);
  });

  test('events from a closed session cannot alter a later session', () async {
    final browser = _FakeBrowser();
    final assets = _FakeAssets();
    final leases = WorkLeasePool();
    final coordinator = _coordinator(browser, assets, leases);
    addTearDown(() => _dispose(coordinator, browser));

    await coordinator.open().timeout(_timeout);
    final oldSession = browser.openCalls.single.session;
    await coordinator.closeSession().timeout(_timeout);
    await coordinator.open().timeout(_timeout);
    final newSession = browser.openCalls.last.session;
    browser.emit(
      BrowserEvent(
        session: newSession,
        document: 4,
        kind: BrowserEventKind.ready,
        origin: coordinator.target.initialUri.origin,
      ),
    );
    final currentView = coordinator.view;

    browser.emit(
      BrowserEvent(
        session: oldSession,
        document: 99,
        kind: BrowserEventKind.blocked,
        origin: 'https://outside.invalid',
      ),
    );

    expect(coordinator.view, same(currentView));
    expect(coordinator.view.ready, isTrue);
    expect(coordinator.view.blocked, isFalse);
    expect(browser.openCalls, hasLength(2));
  });

  test(
    'startup recovery completes only after drain and never navigates',
    () async {
      final browser = _FakeBrowser()..drainComplete = false;
      final assets = _FakeAssets()..pendingRecoveryPath = 'stale-profile';
      final leases = WorkLeasePool();
      final coordinator = _coordinator(
        browser,
        assets,
        leases,
        drainTimeout: const Duration(seconds: 1),
        pollInterval: const Duration(milliseconds: 2),
      );
      addTearDown(() async {
        browser.drainComplete = true;
        await _dispose(coordinator, browser);
      });

      var initialized = false;
      final initializing = coordinator.initialize().then((_) {
        initialized = true;
      });
      await browser.openEntered.future.timeout(_timeout);
      await browser.closeEntered.future.timeout(_timeout);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(browser.openCalls, hasLength(1));
      expect(browser.openCalls.single.recoveryOnly, isTrue);
      expect(browser.navigateCalls, 0);
      expect(initialized, isFalse);
      expect(leases.isBusy, isTrue);
      expect(assets.pendingRecoveryPath, 'stale-profile');

      browser.drainComplete = true;
      await initializing.timeout(_timeout);

      expect(initialized, isTrue);
      expect(assets.pendingRecoveryPath, isNull);
      expect(coordinator.view.phase, ObservationPhase.idle);
      expect(leases.isBusy, isFalse);
      expect(browser.navigateCalls, 0);
    },
  );

  test('a native userClosed event triggers the normal cleanup path', () async {
    final browser = _FakeBrowser();
    final assets = _FakeAssets();
    final leases = WorkLeasePool();
    final coordinator = _coordinator(browser, assets, leases);
    addTearDown(() => _dispose(coordinator, browser));

    await coordinator.open().timeout(_timeout);
    final session = browser.openCalls.single.session;
    browser.emit(
      BrowserEvent(
        session: session,
        document: 0,
        kind: BrowserEventKind.userClosed,
      ),
    );
    await _waitUntil(
      () =>
          coordinator.view.phase == ObservationPhase.idle &&
          assets.cleanupCalls == 1,
    );

    expect(browser.closeCalls, contains(session));
    expect(assets.cleanupCalls, 1);
    expect(leases.isBusy, isFalse);
    expect(coordinator.view.phase, ObservationPhase.idle);
  });
}

ObservationCoordinator _coordinator(
  _FakeBrowser browser,
  _FakeAssets assets,
  WorkLeasePool leases, {
  Duration drainTimeout = const Duration(milliseconds: 100),
  Duration pollInterval = const Duration(milliseconds: 2),
}) => ObservationCoordinator(
  browser: browser,
  assets: assets,
  leases: leases,
  target: ObservationTarget.fixture(
    Uri.parse('http://127.0.0.1:43210/fixture'),
  ),
  drainTimeout: drainTimeout,
  pollInterval: pollInterval,
);

Future<void> _dispose(
  ObservationCoordinator coordinator,
  _FakeBrowser browser,
) async {
  browser.releaseOpen();
  browser.releaseClose();
  browser.releaseDrained();
  browser.releaseNavigate();
  browser.drainComplete = true;
  await coordinator.shutdown().timeout(_timeout);
  await browser.dispose();
}

Future<void> _waitUntil(bool Function() condition) async {
  final elapsed = Stopwatch()..start();
  while (!condition()) {
    if (elapsed.elapsed >= _timeout) {
      fail('Timed out waiting for the observation coordinator state.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

Matcher _failure(FailureCode code) => throwsA(
  isA<AppFailure>().having((failure) => failure.code, 'failure code', code),
);

final class _FakeAssets implements ObservationAssetsPort {
  _FakeAssets({List<String>? timeline}) : timeline = timeline ?? <String>[];

  static const String profilePath = 'synthetic-observation-profile';
  final List<String> timeline;

  Completer<void> registerEntered = Completer<void>();
  Completer<void>? registerGate;
  String? pendingRecoveryPath;
  String? registeredProfilePath;
  int recoverCalls = 0;
  int registerCalls = 0;
  int cleanupCalls = 0;
  int closeCalls = 0;

  @override
  Future<void> recoverPending(
    Future<void> Function(String profilePath) drain,
  ) async {
    recoverCalls++;
    final path = pendingRecoveryPath;
    if (path == null) return;
    await drain(path);
    if (pendingRecoveryPath == path) pendingRecoveryPath = null;
  }

  @override
  Future<String> register() async {
    registerCalls++;
    if (!registerEntered.isCompleted) registerEntered.complete();
    final gate = registerGate;
    if (gate != null) await gate.future;
    registeredProfilePath = profilePath;
    return profilePath;
  }

  void releaseRegister() {
    final gate = registerGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<void> cleanup() async {
    cleanupCalls++;
    timeline.add('cleanup');
    registeredProfilePath = null;
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }
}

final class _FakeBrowser implements ObservationBrowserPort {
  _FakeBrowser({List<String>? timeline}) : timeline = timeline ?? <String>[];

  final List<String> timeline;
  final StreamController<BrowserEvent> _events =
      StreamController<BrowserEvent>.broadcast(sync: true);
  final List<_OpenCall> openCalls = <_OpenCall>[];
  final List<int> closeCalls = <int>[];
  final List<_InspectionCall> inspectCalls = <_InspectionCall>[];
  Completer<void> openEntered = Completer<void>();
  Completer<void> closeEntered = Completer<void>();
  Completer<void>? nextOpenGate;
  Completer<void>? closeGate;
  Completer<bool>? drainedGate;
  Completer<void>? navigateGate;
  Completer<void> drainedEntered = Completer<void>();
  Completer<void> navigateEntered = Completer<void>();
  Completer<void> navigateCompletion = Completer<void>();
  bool drainComplete = true;
  int navigateCalls = 0;

  @override
  Stream<BrowserEvent> get events => _events.stream;

  @override
  Future<void> open({
    required int session,
    required String profilePath,
    required ObservationTarget target,
    bool recoveryOnly = false,
  }) async {
    final call = _OpenCall(session, profilePath, target, recoveryOnly);
    openCalls.add(call);
    if (!openEntered.isCompleted) openEntered.complete();
    final gate = nextOpenGate;
    if (gate != null) await gate.future;
    call.completion.complete();
  }

  void releaseOpen() {
    final gate = nextOpenGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  void releaseClose() {
    final gate = closeGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  void releaseDrained() {
    final gate = drainedGate;
    if (gate != null && !gate.isCompleted) gate.complete(true);
  }

  void releaseNavigate() {
    final gate = navigateGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<BrowserInspection> inspect({
    required int session,
    required int document,
  }) {
    final call = _InspectionCall(session, document);
    inspectCalls.add(call);
    return call.result.future;
  }

  void completeInspection(int index, BrowserInspection inspection) {
    inspectCalls[index].result.complete(inspection);
  }

  @override
  Future<void> navigateInitial(int session) async {
    navigateCalls++;
    if (!navigateEntered.isCompleted) navigateEntered.complete();
    final gate = navigateGate;
    if (gate != null) await gate.future;
    if (!navigateCompletion.isCompleted) navigateCompletion.complete();
  }

  @override
  Future<void> navigateJwPage({
    required int session,
    required int document,
    required JwObservationPage page,
  }) => navigateInitial(session);

  @override
  Future<void> close(int session) async {
    closeCalls.add(session);
    timeline.add('close:$session');
    if (!closeEntered.isCompleted) closeEntered.complete();
    final gate = closeGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<bool> drained(int session) async {
    if (!drainedEntered.isCompleted) drainedEntered.complete();
    final gate = drainedGate;
    final result = gate == null ? drainComplete : await gate.future;
    if (result) timeline.add('drained:$session');
    return result;
  }

  void emit(BrowserEvent event) => _events.add(event);

  Future<void> dispose() => _events.close();
}

final class _OpenCall {
  _OpenCall(this.session, this.profilePath, this.target, this.recoveryOnly);

  final int session;
  final String profilePath;
  final ObservationTarget target;
  final bool recoveryOnly;
  final Completer<void> completion = Completer<void>();
}

final class _InspectionCall {
  _InspectionCall(this.session, this.document);

  final int session;
  final int document;
  final Completer<BrowserInspection> result = Completer<BrowserInspection>();
}
