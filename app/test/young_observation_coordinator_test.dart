import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/observation_assets.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/jobs/observation_coordinator.dart';
import 'package:ustc_assistant_m0/jobs/observation_port.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';
import 'package:ustc_assistant_m0/source/young_observation_contract.dart';

Matcher failure(FailureCode code) =>
    throwsA(isA<AppFailure>().having((e) => e.code, 'code', code));

void main() {
  test('Young and JW share the lease before any asset creation', () async {
    final browser = _Browser(), youngAssets = _Assets(), jwAssets = _Assets();
    final leases = WorkLeasePool();
    final young = _coordinator(browser, youngAssets, leases);
    final jw = _coordinator(browser, jwAssets, leases, young: false);
    try {
      await young.open();
      expect(browser.target?.source, ObservationSource.young);
      await expectLater(jw.open(), failure(FailureCode.busy));
      expect(jwAssets.registrations, 0);
      await young.inspectYoungPage();
      expect(young.view.youngInspection?.surface, YoungSurface.application);
      expect(
        young.view.youngInspection?.safeSummary()['sourceAvailable'],
        false,
      );
      expect(young.probeView.available, false);
      await expectLater(
        young.navigateJwPage(JwObservationPage.courseTable),
        failure(FailureCode.invalidSnapshot),
      );
      expect(browser.jwNavigations, 0);
      await young.closeSession();
      expect(youngAssets.deletions, 1);
      expect(young.view.youngInspection, isNull);
      await jw.open();
      await expectLater(
        jw.inspectYoungPage(),
        failure(FailureCode.invalidSnapshot),
      );
      expect(leases.isBusy, true);
    } finally {
      await young.shutdown();
      await jw.shutdown();
      await browser.dispose();
    }
  });

  test(
    'same-origin navigation invalidates an in-flight structure result',
    () async {
      final browser = _Browser(), assets = _Assets();
      final coordinator = _coordinator(browser, assets, WorkLeasePool());
      try {
        await coordinator.open();
        await coordinator.inspectYoungPage();
        final gate = Completer<YoungPageInspection>();
        browser.inspectionGate = gate;
        final previous = browser.reply();
        final inspection = coordinator.inspectYoungPage();
        final rejected = expectLater(
          inspection,
          failure(FailureCode.staleResult),
        );
        await expectLater(
          coordinator.inspectYoungPage(),
          failure(FailureCode.busy),
        );
        browser.navigate();
        expect(coordinator.view.youngInspection, isNull);
        gate.complete(previous);
        await rejected;
        expect(coordinator.view.youngInspection, isNull);
        browser.inspectionGate = null;
        await coordinator.inspectYoungPage();
        expect(coordinator.view.youngInspection?.document, browser.document);
        browser.navigate();
        expect(coordinator.view.youngInspection, isNull);
      } finally {
        await coordinator.shutdown();
        await browser.dispose();
      }
    },
  );

  test('cancelled inspection cannot republish after cleanup', () async {
    final browser = _Browser(), assets = _Assets(), leases = WorkLeasePool();
    final coordinator = _coordinator(browser, assets, leases);
    try {
      await coordinator.open();
      final gate = Completer<YoungPageInspection>();
      browser.inspectionGate = gate;
      final previous = browser.reply();
      final inspection = coordinator.inspectYoungPage();
      final rejected = expectLater(
        inspection,
        failure(FailureCode.staleResult),
      );
      await coordinator.closeSession();
      gate.complete(previous);
      await rejected;
      expect(coordinator.view.phase, ObservationPhase.idle);
      expect(coordinator.view.youngInspection, isNull);
      expect(leases.isBusy, false);
    } finally {
      await coordinator.shutdown();
      await browser.dispose();
    }
  });

  test(
    'an unacknowledged inspection retains the lease until drain is proved',
    () async {
      final browser = _Browser()..canDrain = false;
      final assets = _Assets(), leases = WorkLeasePool();
      final coordinator = _coordinator(browser, assets, leases);
      try {
        await coordinator.open();
        final gate = Completer<YoungPageInspection>();
        browser.inspectionGate = gate;
        final previous = browser.reply();
        await expectLater(
          coordinator.inspectYoungPage(),
          failure(FailureCode.cleanupPending),
        );
        expect(coordinator.view.phase, ObservationPhase.recovery);
        expect(coordinator.view.youngInspection, isNull);
        expect(assets.deletions, 0);
        expect(leases.isBusy, true);
        gate.complete(previous);
        browser.canDrain = true;
        await coordinator.retryCleanup();
        expect(assets.deletions, 1);
        expect(leases.isBusy, false);
        expect(coordinator.view.youngInspection, isNull);
      } finally {
        browser.canDrain = true;
        await coordinator.shutdown();
        await browser.dispose();
      }
    },
  );

  test(
    'drain failure retains the global lease and permits an explicit retry',
    () async {
      final browser = _Browser()..canDrain = false;
      final assets = _Assets(), leases = WorkLeasePool();
      final coordinator = _coordinator(browser, assets, leases);
      try {
        await coordinator.open();
        await coordinator.inspectYoungPage();
        await expectLater(
          coordinator.closeSession(),
          failure(FailureCode.cleanupPending),
        );
        expect(coordinator.view.phase, ObservationPhase.recovery);
        expect(coordinator.view.youngInspection, isNull);
        expect(leases.isBusy, true);
        expect(assets.deletions, 0);
        browser.canDrain = true;
        await coordinator.retryCleanup();
        expect(assets.deletions, 1);
        expect(leases.isBusy, false);
      } finally {
        browser.canDrain = true;
        await coordinator.shutdown();
        await browser.dispose();
      }
    },
  );
}

ObservationCoordinator _coordinator(
  _Browser browser,
  _Assets assets,
  WorkLeasePool leases, {
  bool young = true,
}) => ObservationCoordinator(
  browser: browser,
  assets: assets,
  leases: leases,
  target: young ? ObservationTarget.young() : ObservationTarget.jw(),
  drainTimeout: const Duration(milliseconds: 60),
  pollInterval: const Duration(milliseconds: 1),
);

final class _Assets implements ObservationAssetsPort {
  int registrations = 0, deletions = 0;
  @override
  Future<void> recoverPending(Future<void> Function(String) drain) async {}
  @override
  Future<String> register() async {
    ++registrations;
    return r'C:\synthetic-young';
  }

  @override
  Future<void> cleanup() async {
    ++deletions;
  }

  @override
  Future<void> close() async {}
}

final class _Browser
    implements ObservationBrowserPort, YoungInspectionBrowserPort {
  final _events = StreamController<BrowserEvent>.broadcast(sync: true);
  int session = 0, document = 0, jwNavigations = 0;
  ObservationTarget? target;
  bool canDrain = true;
  Completer<YoungPageInspection>? inspectionGate;
  @override
  Stream<BrowserEvent> get events => _events.stream;
  @override
  Future<void> open({
    required int session,
    required String profilePath,
    required ObservationTarget target,
    bool recoveryOnly = false,
  }) async {
    this.session = session;
    this.target = target;
    document = 1;
    _ready();
  }

  void _ready() => _events.add(
    BrowserEvent(
      session: session,
      document: document,
      kind: BrowserEventKind.ready,
      origin: target?.initialUri.origin,
    ),
  );
  void navigate() {
    ++document;
    _events.add(
      BrowserEvent(
        session: session,
        document: document,
        kind: BrowserEventKind.navigating,
        origin: target?.initialUri.origin,
      ),
    );
    _ready();
  }

  YoungPageInspection reply() => YoungPageInspection(
    session: session,
    document: document,
    ready: true,
    surface: YoungSurface.application,
    tables: 2,
    calendarRoots: 1,
    paginationControls: 1,
    passwordInputs: 0,
  );
  @override
  Future<YoungPageInspection> inspectYoungPage({
    required int session,
    required int document,
  }) async => inspectionGate == null ? reply() : inspectionGate!.future;
  @override
  Future<BrowserInspection> inspect({
    required int session,
    required int document,
  }) async => BrowserInspection(
    session: session,
    document: document,
    ready: true,
    origin: target?.initialUri.origin,
  );
  @override
  Future<void> navigateInitial(int session) async => navigate();
  @override
  Future<void> navigateJwPage({
    required int session,
    required int document,
    required JwObservationPage page,
  }) async {
    ++jwNavigations;
  }

  @override
  Future<void> close(int session) async {}
  @override
  Future<bool> drained(int session) async => canDrain;
  Future<void> dispose() => _events.close();
}
