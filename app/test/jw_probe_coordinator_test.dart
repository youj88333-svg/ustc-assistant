import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/observation_assets.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/data/jw_candidate_identity.dart';
import 'package:ustc_assistant_m0/jobs/observation_coordinator.dart';
import 'package:ustc_assistant_m0/jobs/observation_port.dart';
import 'package:ustc_assistant_m0/source/jw_probe_contract.dart';
import 'package:ustc_assistant_m0/source/jw_data_probe_contract.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';

void main() {
  late _Browser browser;
  late _Assets assets;
  late WorkLeasePool leases;
  late ObservationCoordinator coordinator;
  setUp(() async {
    browser = _Browser();
    assets = _Assets();
    leases = WorkLeasePool();
    coordinator = ObservationCoordinator(
      browser: browser,
      assets: assets,
      leases: leases,
      drainTimeout: const Duration(milliseconds: 60),
      pollInterval: const Duration(milliseconds: 2),
    );
    await coordinator.open();
    browser.emit(1, BrowserEventKind.ready, 'https://jw.ustc.edu.cn');
  });
  tearDown(() async {
    browser.drain = true;
    await coordinator.shutdown();
    await browser.eventsController.close();
  });

  test(
    'private expected identity is compared without being passed to P or promoted',
    () async {
      await expectLater(
        coordinator.runProbe('invalid secret!'),
        throwsA(isA<AppFailure>()),
      );
      expect(browser.starts, 0);
      await coordinator.runProbe('TEST0001');
      expect(browser.starts, 1);
      expect(
        coordinator.probeView.identity,
        JwCandidateIdentity.candidateMatches,
      );
      expect(coordinator.probeView.safeSummary, isNot(contains('TEST0001')));
      expect(
        coordinator.probeView.safeSummary,
        contains('"sourceAvailable":false'),
      );
      expect(leases.isBusy, isTrue);
      await coordinator.closeSession();
      expect(coordinator.probeView.identity, JwCandidateIdentity.unavailable);
      expect(leases.isBusy, isFalse);
    },
  );

  test(
    'fixed launcher binds current document and clears prior candidate',
    () async {
      await coordinator.runProbe('TEST0001');
      await coordinator.navigateJwPage(JwObservationPage.courseTable);
      expect(browser.pageCalls.single, (
        session: browser.session,
        document: 1,
        page: JwObservationPage.courseTable,
      ));
      expect(coordinator.probeView.identity, JwCandidateIdentity.unavailable);
      expect(coordinator.view.ready, isFalse);
      await expectLater(
        coordinator.navigateJwPage(JwObservationPage.examArrange),
        throwsA(isA<AppFailure>()),
      );
      browser.emit(2, BrowserEventKind.ready, 'https://id.ustc.edu.cn');
      await expectLater(
        coordinator.navigateJwPage(JwObservationPage.examArrange),
        throwsA(isA<AppFailure>()),
      );
      expect(browser.pageCalls, hasLength(1));
      browser.emit(3, BrowserEventKind.ready, 'https://jw.ustc.edu.cn');
      await coordinator.navigateJwPage(JwObservationPage.examArrange);
      expect(browser.pageCalls.last, (
        session: browser.session,
        document: 3,
        page: JwObservationPage.examArrange,
      ));
    },
  );

  for (final eventKind in [
    BrowserEventKind.navigating,
    BrowserEventKind.diagnostic,
  ]) {
    test(
      '$eventKind with new document rejects late identity and retains drain lease',
      () async {
        browser.holdPoll = true;
        browser.drain = false;
        final probe = coordinator.runProbe('TEST0001');
        await browser.pollEntered.future;
        await expectLater(
          coordinator.runProbe('TEST0001'),
          throwsA(isA<AppFailure>()),
        );
        await expectLater(
          coordinator.navigateJwPage(JwObservationPage.courseTable),
          throwsA(isA<AppFailure>()),
        );
        expect(browser.pageCalls, isEmpty);
        browser.emit(2, eventKind, 'https://jw.ustc.edu.cn');
        await probe;
        final elapsed = Stopwatch()..start();
        while (coordinator.view.phase != ObservationPhase.recovery) {
          if (elapsed.elapsed > const Duration(seconds: 2)) {
            fail('cleanup did not retain recovery');
          }
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        expect(coordinator.probeView.identity, JwCandidateIdentity.unavailable);
        expect(coordinator.probeView.summary, isNull);
        expect(assets.cleaned, isFalse);
        expect(leases.isBusy, isTrue);
        browser.drain = true;
        await coordinator.retryCleanup();
        expect(assets.cleaned, isTrue);
        expect(leases.isBusy, isFalse);
      },
    );
  }

  test(
    'data scope comes from the current accepted catalog; identity stays private',
    () async {
      await expectLater(
        coordinator.runDataProbe('TEST0001', semesterId: 20261),
        throwsA(isA<AppFailure>()),
      );
      await coordinator.runProbe('TEST0001');
      await expectLater(
        coordinator.runDataProbe('TEST0001', semesterId: 20263),
        throwsA(isA<AppFailure>()),
      );
      expect(browser.dataCalls, isEmpty);
      await coordinator.runDataProbe('TEST0002', semesterId: 20261);
      expect(browser.dataCalls.single.semesterId, 20261);
      expect(browser.dataCalls.single.document, 1);
      expect(
        coordinator.dataProbeView.identity,
        JwCandidateIdentity.candidateMismatch,
      );
      expect(coordinator.dataProbeView.diagnostics!.identityStable, isTrue);
      expect(coordinator.dataProbeView.safeSummary, isNot(contains('TEST000')));
      expect(coordinator.dataProbeView.safeSummary, isNot(contains('20261')));
      expect(
        coordinator.dataProbeView.safeSummary,
        contains('"sourceAvailable":false'),
      );
      expect(leases.isBusy, isTrue);
    },
  );

  test(
    'data reads share the lease and cancellation discards late evidence',
    () async {
      await coordinator.runProbe('TEST0001');
      browser.holdDataPoll = true;
      final work = coordinator.runDataProbe('TEST0001', semesterId: 20261);
      await browser.dataPollEntered.future;
      expect(coordinator.probeView.busy, isTrue);
      expect(coordinator.dataProbeView.busy, isTrue);
      await expectLater(
        coordinator.runProbe('TEST0001'),
        throwsA(isA<AppFailure>()),
      );
      await expectLater(
        coordinator.navigateJwPage(JwObservationPage.examArrange),
        throwsA(isA<AppFailure>()),
      );
      await coordinator.cancelDataProbe();
      await work;
      expect(
        coordinator.dataProbeView.identity,
        JwCandidateIdentity.unavailable,
      );
      expect(coordinator.dataProbeView.diagnostics, isNull);
      expect(coordinator.dataProbeView.busy, isFalse);
      expect(assets.cleaned, isTrue);
      expect(leases.isBusy, isFalse);
    },
  );

  test(
    'a new document invalidates data before late replies and keeps failed drain busy',
    () async {
      await coordinator.runProbe('TEST0001');
      browser.holdDataPoll = true;
      browser.drain = false;
      final work = coordinator.runDataProbe('TEST0001', semesterId: 20261);
      await browser.dataPollEntered.future;
      browser.emit(2, BrowserEventKind.diagnostic, 'https://jw.ustc.edu.cn');
      await work;
      final elapsed = Stopwatch()..start();
      while (coordinator.view.phase != ObservationPhase.recovery) {
        if (elapsed.elapsed > const Duration(seconds: 2)) {
          fail('drain was not retained');
        }
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(
        coordinator.dataProbeView.identity,
        JwCandidateIdentity.unavailable,
      );
      expect(coordinator.dataProbeView.diagnostics, isNull);
      expect(leases.isBusy, isTrue);
      expect(assets.cleaned, isFalse);
      browser.drain = true;
      await coordinator.retryCleanup();
      expect(leases.isBusy, isFalse);
      expect(assets.cleaned, isTrue);
    },
  );
}

final class _Assets implements ObservationAssetsPort {
  bool cleaned = false;
  @override
  Future<void> recoverPending(Future<void> Function(String) drain) async {}
  @override
  Future<String> register() async => 'synthetic-profile';
  @override
  Future<void> cleanup() async {
    cleaned = true;
  }

  @override
  Future<void> close() async {}
}

final class _Browser
    implements
        ObservationBrowserPort,
        JwProbeBrowserPort,
        JwDataProbeBrowserPort {
  final eventsController = StreamController<BrowserEvent>.broadcast(sync: true);
  final pollEntered = Completer<void>();
  final pollResult = Completer<JwProbeReply>();
  int session = 0;
  int operation = 0;
  int starts = 0;
  bool holdPoll = false;
  bool drain = true;
  bool holdDataPoll = false;
  int dataOperation = 0;
  final dataPollEntered = Completer<void>();
  final dataPollResult = Completer<JwDataProbeReply>();
  final dataCalls =
      <({int session, int document, int operation, int semesterId})>[];
  final pageCalls = <({int session, int document, JwObservationPage page})>[];
  @override
  Stream<BrowserEvent> get events => eventsController.stream;
  void emit(int document, BrowserEventKind kind, String origin) =>
      eventsController.add(
        BrowserEvent(
          session: session,
          document: document,
          kind: kind,
          origin: origin,
        ),
      );
  @override
  Future<void> open({
    required int session,
    required String profilePath,
    required ObservationTarget target,
    bool recoveryOnly = false,
  }) async {
    this.session = session;
  }

  @override
  Future<BrowserInspection> inspect({
    required int session,
    required int document,
  }) async => BrowserInspection(
    session: session,
    document: document,
    ready: true,
    origin: 'https://jw.ustc.edu.cn',
  );
  @override
  Future<void> navigateInitial(int session) async {}
  @override
  Future<void> navigateJwPage({
    required int session,
    required int document,
    required JwObservationPage page,
  }) async {
    pageCalls.add((session: session, document: document, page: page));
  }

  @override
  Future<void> close(int session) async {
    if (holdPoll && !pollResult.isCompleted) {
      pollResult.complete(_reply(operation, false));
    }
    if (holdDataPoll && !dataPollResult.isCompleted) {
      dataPollResult.complete(_dataReply(dataOperation, false));
    }
  }

  @override
  Future<bool> drained(int session) async => drain;
  @override
  Future<JwProbeReply> startJwProbe({
    required int session,
    required int document,
    required int operation,
  }) async {
    starts++;
    this.operation = operation;
    return _reply(operation, holdPoll);
  }

  @override
  Future<JwProbeReply> pollJwProbe({
    required int session,
    required int document,
    required int operation,
  }) async {
    if (!pollEntered.isCompleted) pollEntered.complete();
    return pollResult.future;
  }

  @override
  Future<JwProbeReply> cancelJwProbe({
    required int session,
    required int document,
    required int operation,
  }) async => _reply(operation, false);

  @override
  Future<JwDataProbeReply> startJwDataProbe({
    required int session,
    required int document,
    required int operation,
    required int semesterId,
  }) async {
    dataOperation = operation;
    dataCalls.add((
      session: session,
      document: document,
      operation: operation,
      semesterId: semesterId,
    ));
    return _dataReply(operation, holdDataPoll);
  }

  @override
  Future<JwDataProbeReply> pollJwDataProbe({
    required int session,
    required int document,
    required int operation,
  }) async {
    if (!dataPollEntered.isCompleted) dataPollEntered.complete();
    return dataPollResult.future;
  }

  @override
  Future<JwDataProbeReply> cancelJwDataProbe({
    required int session,
    required int document,
    required int operation,
  }) async => _dataReply(operation, false);
}

JwProbeReply _reply(int operation, bool running) => JwProbeReply.decode(
  jsonEncode({
    'operation': operation,
    'phase': running ? 'running' : 'done',
    'code': running ? 'pending' : 'ok',
    if (!running)
      'identity': {
        'candidateCount': 1,
        'accountCode': 'TEST0001',
        'method': 'definitionList',
      },
    if (!running)
      'semesters': [
        {'id': 20261, 'name': 'Synthetic semester', 'selected': true},
      ],
    if (!running)
      'summary': {
        'identityLabels': 1,
        'semesterOptions': 1,
        'semesterSelect': true,
        'examTables': 1,
        'examHeader': true,
        'examRows': 0,
        'pagination': false,
        'semesterVariables': {
          'allSemesters': false,
          'semesters': true,
          'semesterId': true,
          'bizTypeId': false,
        },
        'stageResults': {'identity': 'ok', 'course': 'ok', 'exams': 'ok'},
        'courseDiagnostics': const JwCourseDiagnostics().safeProjection,
      },
  }),
  operation: operation,
);

JwDataProbeReply _dataReply(int operation, bool running) =>
    JwDataProbeReply.decode(
      jsonEncode({
        'operation': operation,
        'phase': running ? 'running' : 'done',
        'code': running ? 'pending' : 'ok',
        if (!running)
          'identity': {
            'candidateCount': 1,
            'method': 'table',
            'accountCode': 'TEST0001',
          },
        if (!running)
          'diagnostics': JwDataDiagnostics(
            checks: {
              for (final stage in const [
                'identityBefore',
                'course',
                'index',
                'datum',
                'exams',
                'identityAfter',
              ])
                stage: 'ok',
            },
            identityReads: 2,
            semesterAccepted: true,
            selfRouteBound: true,
            identityStable: true,
            lessonIds: 1,
            lessons: 1,
            groups: 1,
            schedules: 1,
            linkedSchedules: 1,
            datedSchedules: 1,
            timedSchedules: 1,
          ).safeProjection,
      }),
      operation: operation,
    );
