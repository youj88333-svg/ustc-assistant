import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/observation_assets.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/jobs/observation_coordinator.dart';
import 'package:ustc_assistant_m0/jobs/observation_port.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';
import 'package:ustc_assistant_m0/source/young_active_contract.dart';

const _account = 'SYNTHETIC_ACCOUNT_92814';
const _privateJsonMarker = 'SYNTHETIC_PRIVATE_RESPONSE_741';
const _firstDay = '2026-10-01';
const _secondDay = '2026-10-02';

void main() {
  test(
    'validates identity around a complete activity query and permits new totals per job',
    () async {
      final browser = _BusinessBrowser(
        activityPlans: [
          [
            _page(
              List<Map<String, Object?>>.generate(
                10,
                (index) => _activity('activity-${index + 1}'),
              ),
              11,
              current: 1,
            ),
            _page([_activity('activity-11')], 11, current: 1),
          ],
          [_page(const <Map<String, Object?>>[], 0, current: 1)],
        ],
      );
      final assets = _Assets();
      final leases = WorkLeasePool();
      final coordinator = _coordinator(browser, assets, leases);
      addTearDown(() => _dispose(coordinator, browser));

      await coordinator.open();
      await coordinator.probeYoungActivities(_account);

      final first = coordinator.businessView;
      expect(first.phase, YoungBusinessPhase.done);
      expect(first.identity, YoungBusinessIdentity.candidateMatches);
      expect(first.identityReads, 2);
      expect(first.activities, 11);
      expect(first.activityPages, 2);
      expect(first.safeSummary()['sourceAvailable'], isFalse);
      final firstSummaryJson = jsonEncode(first.safeSummary());
      expect(firstSummaryJson, isNot(contains(_account)));
      expect(firstSummaryJson, isNot(contains(_privateJsonMarker)));
      expect(firstSummaryJson, isNot(contains('itemName')));
      expect(browser.profileReads, 2);
      expect(browser.activityRequests.map((call) => call.page), [1, 2]);
      expect(
        browser.activityRequests.every(
          (call) => call.operation == browser.operations.first,
        ),
        isTrue,
      );

      await coordinator.probeYoungActivities(_account);
      final second = coordinator.businessView;
      expect(second.phase, YoungBusinessPhase.done);
      expect(second.identity, YoungBusinessIdentity.candidateMatches);
      expect(second.identityReads, 2);
      expect(second.activities, 0);
      expect(second.activityPages, 1);
      expect(browser.activityRequests.map((call) => call.page), [1, 2, 1]);
      expect(browser.operations.toSet().length, 2);
    },
  );

  test(
    'rejects changed totals, repeated identifiers, malformed rows, native failure, and identity drift',
    () async {
      final plans = <_FailurePlan>[
        _FailurePlan(
          name: 'total changed',
          expectedFailure: FailureCode.invalidSnapshot,
          browser: _BusinessBrowser(
            activityPlans: [
              [
                _page(
                  List<Map<String, Object?>>.generate(
                    10,
                    (index) => _activity('total-$index'),
                  ),
                  11,
                ),
                _page([_activity('total-last')], 10),
              ],
            ],
          ),
        ),
        _FailurePlan(
          name: 'repeated ID across pages',
          expectedFailure: FailureCode.invalidSnapshot,
          browser: _BusinessBrowser(
            activityPlans: [
              [
                _page(
                  List<Map<String, Object?>>.generate(
                    10,
                    (index) => _activity('repeat-$index'),
                  ),
                  11,
                ),
                _page([_activity('repeat-0')], 11),
              ],
            ],
          ),
        ),
        _FailurePlan(
          name: 'malformed required activity field',
          expectedFailure: FailureCode.invalidSnapshot,
          browser: _BusinessBrowser(
            activityPlans: [
              [
                _page([
                  <String, Object?>{
                    'id': 'bad-row',
                    'itemName': 'private title',
                    'et': '2026-10-01 11:00:00',
                  },
                ], 1),
              ],
            ],
          ),
        ),
        _FailurePlan(
          name: 'native step failure',
          expectedFailure: FailureCode.sourceFailed,
          browser: _BusinessBrowser(failAtMethod: 'poll'),
        ),
        _FailurePlan(
          name: 'identity changes after the data read',
          expectedFailure: FailureCode.invalidSnapshot,
          browser: _BusinessBrowser(
            afterUsername: 'SYNTHETIC_DIFFERENT_ACCOUNT',
          ),
        ),
      ];

      for (final plan in plans) {
        final assets = _Assets();
        final leases = WorkLeasePool();
        final coordinator = _coordinator(plan.browser, assets, leases);
        try {
          await coordinator.open();
          await coordinator.probeYoungActivities(_account);

          final view = coordinator.businessView;
          expect(view.phase, YoungBusinessPhase.failed, reason: plan.name);
          expect(view.failure, plan.expectedFailure, reason: plan.name);
          expect(
            view.safeSummary()['sourceAvailable'],
            isFalse,
            reason: plan.name,
          );
          expect(assets.cleanupCalls, 1, reason: plan.name);
          expect(
            plan.browser.drainedCalls,
            greaterThanOrEqualTo(1),
            reason: plan.name,
          );
          expect(leases.isBusy, isFalse, reason: plan.name);
          final summary = jsonEncode(view.safeSummary());
          expect(summary, isNot(contains(_account)), reason: plan.name);
          expect(
            summary,
            isNot(contains(_privateJsonMarker)),
            reason: plan.name,
          );
          if (plan.name == 'identity changes after the data read') {
            expect(view.identity, YoungBusinessIdentity.accountMismatch);
            expect(view.identityReads, 2);
          } else {
            expect(view.identity, YoungBusinessIdentity.unverified);
          }
        } finally {
          await _dispose(coordinator, plan.browser);
        }
      }
    },
  );

  test(
    'reads a full 10 plus 1 day and a complete empty day, filtering unlinked rows',
    () async {
      final dayOneRows = List<Map<String, Object?>>.generate(
        10,
        (index) => _calendarEntry(
          'calendar-${index + 1}',
          day: _firstDay,
          itemId: index == 9 ? null : 'activity-${index + 1}',
        ),
      );
      final browser = _BusinessBrowser(
        calendarResponses: <String, List<Object?>>{
          _firstDay: [
            _page(dayOneRows, 11, current: 1),
            _page(
              [
                _calendarEntry(
                  'calendar-11',
                  day: _firstDay,
                  itemId: 'activity-11',
                ),
              ],
              11,
              current: 1,
            ),
          ],
          _secondDay: [_page(const <Map<String, Object?>>[], 0, current: 1)],
        },
      );
      final assets = _Assets();
      final leases = WorkLeasePool();
      final coordinator = _coordinator(browser, assets, leases);
      addTearDown(() => _dispose(coordinator, browser));

      await coordinator.open();
      await coordinator.probeYoungCalendar(
        expectedAccountCode: _account,
        firstDay: DateTime.utc(2026, 10, 1),
        lastDay: DateTime.utc(2026, 10, 2),
      );

      final view = coordinator.businessView;
      expect(view.phase, YoungBusinessPhase.done);
      expect(view.identity, YoungBusinessIdentity.candidateMatches);
      expect(view.identityReads, 2);
      expect(view.calendarRows, 11);
      expect(view.linkedSchedules, 10);
      expect(view.excludedSchedules, 1);
      expect(view.days, 2);
      expect(view.calendarPages, 3);
      expect(browser.calendarRequests.map((call) => call.day), [
        _firstDay,
        _firstDay,
        _secondDay,
      ]);
      expect(browser.calendarRequests.map((call) => call.page), [1, 2, 1]);
      expect(view.safeSummary()['sourceAvailable'], isFalse);
      expect(jsonEncode(view.safeSummary()), isNot(contains(_account)));
    },
  );

  test(
    'deduplicates an identical cross-day record and rejects conflicting duplicates',
    () async {
      final sharedRecord = _calendarEntry(
        'cross-day-id',
        day: _firstDay,
        startTime: '2026-10-01 23:30:00',
        endTime: '2026-10-02 00:30:00',
        itemId: 'activity-cross',
      );
      final identical = _BusinessBrowser(
        calendarResponses: <String, List<Object?>>{
          _firstDay: [
            _page([sharedRecord], 1),
          ],
          _secondDay: [
            _page([sharedRecord], 1),
          ],
        },
      );
      final assets = _Assets();
      final leases = WorkLeasePool();
      final coordinator = _coordinator(identical, assets, leases);
      addTearDown(() => _dispose(coordinator, identical));

      await coordinator.open();
      await coordinator.probeYoungCalendar(
        expectedAccountCode: _account,
        firstDay: DateTime.utc(2026, 10, 1),
        lastDay: DateTime.utc(2026, 10, 2),
      );
      expect(coordinator.businessView.phase, YoungBusinessPhase.done);
      expect(coordinator.businessView.calendarRows, 2);
      expect(coordinator.businessView.linkedSchedules, 1);

      await _dispose(coordinator, identical);

      final conflicting = _BusinessBrowser(
        calendarResponses: <String, List<Object?>>{
          _firstDay: [
            _page([sharedRecord], 1),
          ],
          _secondDay: [
            _page([
              <String, Object?>{...sharedRecord, 'title': 'different title'},
            ], 1),
          ],
        },
      );
      final conflictAssets = _Assets();
      final conflictLeases = WorkLeasePool();
      final conflictCoordinator = _coordinator(
        conflicting,
        conflictAssets,
        conflictLeases,
      );
      addTearDown(() => _dispose(conflictCoordinator, conflicting));
      await conflictCoordinator.open();
      await conflictCoordinator.probeYoungCalendar(
        expectedAccountCode: _account,
        firstDay: DateTime.utc(2026, 10, 1),
        lastDay: DateTime.utc(2026, 10, 2),
      );

      expect(conflictCoordinator.businessView.phase, YoungBusinessPhase.failed);
      expect(
        conflictCoordinator.businessView.failure,
        FailureCode.invalidSnapshot,
      );
      expect(
        conflictCoordinator.businessView.safeSummary()['sourceAvailable'],
        false,
      );
      expect(conflictAssets.cleanupCalls, 1);
      expect(conflictLeases.isBusy, false);
    },
  );

  test(
    'rejects a cross-day duplicate whose activity link disappears',
    () async {
      final linked = _calendarEntry(
        'link-drift-id',
        day: _firstDay,
        startTime: '2026-10-01 23:30:00',
        endTime: '2026-10-02 00:30:00',
        itemId: 'activity-linked',
      );
      final unlinked = <String, Object?>{...linked}..remove('itemId');
      final browser = _BusinessBrowser(
        calendarResponses: <String, List<Object?>>{
          _firstDay: [
            _page([linked], 1),
          ],
          _secondDay: [
            _page([unlinked], 1),
          ],
        },
      );
      final assets = _Assets();
      final leases = WorkLeasePool();
      final coordinator = _coordinator(browser, assets, leases);
      addTearDown(() => _dispose(coordinator, browser));

      await coordinator.open();
      await coordinator.probeYoungCalendar(
        expectedAccountCode: _account,
        firstDay: DateTime.utc(2026, 10, 1),
        lastDay: DateTime.utc(2026, 10, 2),
      );

      expect(coordinator.businessView.phase, YoungBusinessPhase.failed);
      expect(coordinator.businessView.failure, FailureCode.invalidSnapshot);
      expect(
        coordinator.businessView.safeSummary()['sourceAvailable'],
        isFalse,
      );
      expect(assets.cleanupCalls, 1);
      expect(browser.drainedCalls, greaterThanOrEqualTo(1));
      expect(leases.isBusy, isFalse);
    },
  );

  test('rejects calendar rows outside the requested coverage', () async {
    final browser = _BusinessBrowser(
      calendarResponses: <String, List<Object?>>{
        _firstDay: [
          _page([
            _calendarEntry(
              'outside-range',
              day: _secondDay,
              itemId: 'activity-outside',
            ),
          ], 1),
        ],
      },
    );
    final assets = _Assets();
    final leases = WorkLeasePool();
    final coordinator = _coordinator(browser, assets, leases);
    addTearDown(() => _dispose(coordinator, browser));

    await coordinator.open();
    await coordinator.probeYoungCalendar(
      expectedAccountCode: _account,
      firstDay: DateTime.utc(2026, 10, 1),
      lastDay: DateTime.utc(2026, 10, 1),
    );

    expect(coordinator.businessView.phase, YoungBusinessPhase.failed);
    expect(coordinator.businessView.failure, FailureCode.invalidSnapshot);
    expect(coordinator.businessView.calendarRows, 0);
    expect(assets.cleanupCalls, 1);
    expect(leases.isBusy, false);
  });

  test(
    'rejects a range longer than 62 days before starting native work',
    () async {
      final browser = _BusinessBrowser();
      final assets = _Assets();
      final leases = WorkLeasePool();
      final coordinator = _coordinator(browser, assets, leases);
      addTearDown(() => _dispose(coordinator, browser));

      await coordinator.open();
      await expectLater(
        coordinator.probeYoungCalendar(
          expectedAccountCode: _account,
          firstDay: DateTime.utc(2026, 1, 1),
          lastDay: DateTime.utc(2026, 3, 4),
        ),
        _failure(FailureCode.invalidSnapshot),
      );
      expect(browser.startCalls, 0);
      expect(browser.dispatchCalls, 0);
      expect(leases.isBusy, isTrue);
    },
  );

  test(
    'rejects an old document result after a route change and closes the session',
    () async {
      final browser = _BusinessBrowser(
        navigateOnPollEndpoint: YoungBusinessEndpoint.activities,
      );
      final assets = _Assets();
      final leases = WorkLeasePool();
      final coordinator = _coordinator(browser, assets, leases);
      addTearDown(() => _dispose(coordinator, browser));

      await coordinator.open();
      await coordinator.probeYoungActivities(_account);

      expect(browser.routeChanges, 1);
      expect(browser.oldDocumentPollReplies, 1);
      expect(coordinator.businessView.phase, YoungBusinessPhase.failed);
      expect(coordinator.businessView.activityPages, 0);
      expect(
        coordinator.businessView.safeSummary()['sourceAvailable'],
        isFalse,
      );
      expect(assets.cleanupCalls, 1);
      expect(leases.isBusy, isFalse);
    },
  );

  test(
    'busy probe rejects a second operation and user cancellation drains without deadlock',
    () async {
      final browser = _BusinessBrowser(holdPollUntilClose: true);
      final assets = _Assets();
      final leases = WorkLeasePool();
      final coordinator = _coordinator(browser, assets, leases);
      addTearDown(() => _dispose(coordinator, browser));

      await coordinator.open();
      final first = coordinator.probeYoungActivities(_account);
      await browser.pollEntered.future.timeout(const Duration(seconds: 1));
      await expectLater(
        coordinator.probeYoungActivities(_account),
        _failure(FailureCode.busy),
      );
      await expectLater(
        coordinator.navigateYoungPage(YoungBusinessPage.activities),
        _failure(FailureCode.busy),
      );
      expect(browser.routeChanges, 0);
      expect(coordinator.businessView.busy, isTrue);
      await coordinator.cancelYoungBusinessProbe().timeout(
        const Duration(seconds: 1),
      );
      await first.timeout(const Duration(seconds: 1));

      expect(coordinator.view.phase, ObservationPhase.idle);
      expect(assets.cleanupCalls, 1);
      expect(browser.drainedCalls, greaterThanOrEqualTo(1));
      expect(leases.isBusy, isFalse);
    },
  );

  test(
    'retains the global lease until a failed step is fully drained',
    () async {
      final browser = _BusinessBrowser(failAtMethod: 'poll', holdDrain: true);
      final assets = _Assets();
      final leases = WorkLeasePool();
      final coordinator = _coordinator(browser, assets, leases);
      addTearDown(() => _dispose(coordinator, browser));

      await coordinator.open();
      final probe = coordinator.probeYoungActivities(_account);
      await browser.drainEntered.future.timeout(const Duration(seconds: 1));
      expect(leases.isBusy, isTrue);
      expect(assets.cleanupCalls, 0);

      browser.allowDrain();
      await probe.timeout(const Duration(seconds: 1));
      expect(coordinator.businessView.phase, YoungBusinessPhase.failed);
      expect(assets.cleanupCalls, 1);
      expect(leases.isBusy, isFalse);
    },
  );

  test(
    'native start, dispatch, poll, finish failures and poll timeout clean the profile',
    () async {
      for (final failedMethod in const [
        'start',
        'dispatch',
        'poll',
        'finish',
        'timeoutPoll',
      ]) {
        final browser = _BusinessBrowser(
          activityPlans: [
            [_page(const <Map<String, Object?>>[], 0)],
          ],
          failAtMethod: failedMethod == 'timeoutPoll' ? null : failedMethod,
          holdPollUntilClose: failedMethod == 'timeoutPoll',
        );
        final assets = _Assets();
        final leases = WorkLeasePool();
        final coordinator = _coordinator(
          browser,
          assets,
          leases,
          drainTimeout: const Duration(milliseconds: 40),
        );
        try {
          await coordinator.open();
          final probe = coordinator.probeYoungActivities(_account);
          if (failedMethod == 'timeoutPoll') {
            await browser.pollEntered.future.timeout(
              const Duration(seconds: 1),
            );
            await probe.timeout(const Duration(seconds: 1));
          } else {
            await probe.timeout(const Duration(seconds: 1));
          }
          expect(
            coordinator.businessView.phase,
            YoungBusinessPhase.failed,
            reason: failedMethod,
          );
          expect(
            coordinator.businessView.safeSummary()['sourceAvailable'],
            isFalse,
            reason: failedMethod,
          );
          expect(
            browser.closeCalls,
            greaterThanOrEqualTo(1),
            reason: failedMethod,
          );
          expect(assets.cleanupCalls, 1, reason: failedMethod);
          expect(leases.isBusy, isFalse, reason: failedMethod);
        } finally {
          await _dispose(coordinator, browser);
        }
      }
    },
  );
}

ObservationCoordinator _coordinator(
  _BusinessBrowser browser,
  _Assets assets,
  WorkLeasePool leases, {
  Duration drainTimeout = const Duration(milliseconds: 200),
}) => ObservationCoordinator(
  browser: browser,
  assets: assets,
  leases: leases,
  target: ObservationTarget.young(),
  drainTimeout: drainTimeout,
  pollInterval: const Duration(milliseconds: 1),
  probeTimeout: const Duration(milliseconds: 80),
  dataProbeTimeout: const Duration(seconds: 2),
);

Future<void> _dispose(
  ObservationCoordinator coordinator,
  _BusinessBrowser browser,
) async {
  browser.allowDrain();
  browser.releasePoll();
  await coordinator.shutdown().timeout(const Duration(seconds: 2));
  await browser.dispose();
}

Matcher _failure(FailureCode code) => throwsA(
  isA<AppFailure>().having((failure) => failure.code, 'failure code', code),
);

Map<String, Object?> _page(
  List<Map<String, Object?>> records,
  int total, {
  int? current,
}) => <String, Object?>{
  'success': true,
  'code': 200,
  'result': <String, Object?>{
    'records': records,
    'total': total,
    'current': ?current,
  },
};

Map<String, Object?> _activity(String id) => <String, Object?>{
  'id': id,
  'itemName': 'Synthetic activity $id',
  'st': '2026-10-01 10:00:00',
  'et': '2026-10-01 11:00:00',
};

Map<String, Object?> _calendarEntry(
  String id, {
  required String day,
  required String? itemId,
  String? startTime,
  String? endTime,
}) => <String, Object?>{
  'id': id,
  'title': 'Synthetic calendar $id',
  'place': 'Synthetic place',
  'startTime': startTime ?? '$day 10:00:00',
  'endTime': endTime ?? '$day 11:00:00',
  'itemId': ?itemId,
};

final class _FailurePlan {
  const _FailurePlan({
    required this.name,
    required this.browser,
    required this.expectedFailure,
  });
  final String name;
  final _BusinessBrowser browser;
  final FailureCode expectedFailure;
}

final class _Assets implements ObservationAssetsPort {
  int registrations = 0;
  int cleanupCalls = 0;
  int closeCalls = 0;

  @override
  Future<void> recoverPending(Future<void> Function(String) drain) async {}

  @override
  Future<String> register() async {
    registrations++;
    return r'C:\synthetic-young-observation';
  }

  @override
  Future<void> cleanup() async {
    cleanupCalls++;
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }
}

final class _StepCall {
  const _StepCall({
    required this.session,
    required this.document,
    required this.operation,
    required this.step,
    required this.endpoint,
    required this.page,
    required this.day,
  });

  final int session;
  final int document;
  final int operation;
  final int step;
  final YoungBusinessEndpoint endpoint;
  final int page;
  final String? day;
}

final class _BusinessBrowser
    implements ObservationBrowserPort, YoungBusinessBrowserPort {
  _BusinessBrowser({
    this.activityPlans = const [],
    this.calendarResponses = const {},
    this.afterUsername = _account,
    this.failAtMethod,
    this.navigateOnPollEndpoint,
    this.holdPollUntilClose = false,
    this.holdDrain = false,
  });

  final List<List<Object?>> activityPlans;
  final Map<String, List<Object?>> calendarResponses;
  final String afterUsername;
  final String? failAtMethod;
  final YoungBusinessEndpoint? navigateOnPollEndpoint;
  final bool holdPollUntilClose;
  final bool holdDrain;
  final StreamController<BrowserEvent> _events =
      StreamController<BrowserEvent>.broadcast(sync: true);
  final Map<int, _StepCall> _steps = <int, _StepCall>{};
  final List<_StepCall> activityRequests = <_StepCall>[];
  final List<_StepCall> calendarRequests = <_StepCall>[];
  final List<int> operations = <int>[];
  final Completer<void> pollEntered = Completer<void>();
  final Completer<void> drainEntered = Completer<void>();
  final Completer<bool> _drainGate = Completer<bool>();
  final Completer<void> _pollGate = Completer<void>();
  int session = 0;
  int document = 0;
  int startCalls = 0;
  int dispatchCalls = 0;
  int closeCalls = 0;
  int drainedCalls = 0;
  int _inFlightPolls = 0;
  int profileReads = 0;
  int routeChanges = 0;
  int oldDocumentPollReplies = 0;
  int _activePlanIndex = -1;
  bool _disposed = false;
  ObservationTarget? target;

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
    _emit(
      BrowserEventKind.ready,
      document: document,
      origin: target.initialUri.origin,
    );
  }

  void _emit(BrowserEventKind kind, {required int document, String? origin}) {
    _events.add(
      BrowserEvent(
        session: session,
        document: document,
        kind: kind,
        origin: origin,
      ),
    );
  }

  void _changeRoute() {
    ++routeChanges;
    ++document;
    _emit(
      BrowserEventKind.navigating,
      document: document,
      origin: target?.initialUri.origin,
    );
    _emit(
      BrowserEventKind.ready,
      document: document,
      origin: target?.initialUri.origin,
    );
  }

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
  Future<void> navigateInitial(int session) async => _changeRoute();

  @override
  Future<void> navigateJwPage({
    required int session,
    required int document,
    required JwObservationPage page,
  }) async => _changeRoute();

  @override
  Future<void> close(int session) async {
    closeCalls++;
    releasePoll();
  }

  @override
  Future<bool> drained(int session) async {
    drainedCalls++;
    if (!drainEntered.isCompleted) drainEntered.complete();
    if (holdDrain) await _drainGate.future;
    return _inFlightPolls == 0;
  }

  void allowDrain() {
    if (!_drainGate.isCompleted) _drainGate.complete(true);
  }

  void releasePoll() {
    if (!_pollGate.isCompleted) _pollGate.complete();
  }

  @override
  Future<void> startYoungBusiness({
    required int session,
    required int document,
    required int operation,
  }) async {
    _recordBinding(session, document, operation);
    startCalls++;
    profileReads = 0;
    _activePlanIndex = startCalls - 1;
    if (failAtMethod == 'start') {
      throw const AppFailure(FailureCode.sourceFailed);
    }
  }

  @override
  Future<void> dispatchYoungBusinessStep({
    required int session,
    required int document,
    required int operation,
    required int step,
    required YoungBusinessEndpoint endpoint,
    int page = 0,
    String? day,
  }) async {
    _recordBinding(session, document, operation);
    dispatchCalls++;
    if (failAtMethod == 'dispatch') {
      throw const AppFailure(FailureCode.sourceFailed);
    }
    final call = _StepCall(
      session: session,
      document: document,
      operation: operation,
      step: step,
      endpoint: endpoint,
      page: page,
      day: day,
    );
    _steps[step] = call;
    if (endpoint == YoungBusinessEndpoint.activities) {
      activityRequests.add(call);
    }
    if (endpoint == YoungBusinessEndpoint.schedule) calendarRequests.add(call);
  }

  @override
  Future<YoungBusinessStepReply> pollYoungBusinessStep({
    required int session,
    required int document,
    required int operation,
    required int step,
  }) async {
    _recordBinding(session, document, operation);
    ++_inFlightPolls;
    try {
      final call = _steps[step];
      if (call == null) throw const AppFailure(FailureCode.invalidSnapshot);
      if (failAtMethod == 'poll') {
        throw const AppFailure(FailureCode.sourceFailed);
      }
      if (holdPollUntilClose) {
        if (!pollEntered.isCompleted) pollEntered.complete();
        await _pollGate.future;
        return _reply(call, complete: false);
      }
      if (navigateOnPollEndpoint == call.endpoint) {
        _changeRoute();
        oldDocumentPollReplies++;
      }
      final response = _response(call);
      return _reply(call, projected: jsonEncode(response));
    } finally {
      --_inFlightPolls;
    }
  }

  Object? _response(_StepCall call) {
    switch (call.endpoint) {
      case YoungBusinessEndpoint.profile:
        profileReads++;
        final username = profileReads == 1 ? _account : afterUsername;
        return <String, Object?>{
          'success': true,
          'code': 200,
          'result': <String, Object?>{
            'username': username,
            'diagnostic': _privateJsonMarker,
          },
        };
      case YoungBusinessEndpoint.activities:
        final plans = activityPlans.isEmpty
            ? <List<Object?>>[
                [_page(const <Map<String, Object?>>[], 0)],
              ]
            : activityPlans;
        final planIndex = _activePlanIndex.clamp(0, plans.length - 1).toInt();
        final plan = plans[planIndex];
        if (call.page < 1 || call.page > plan.length) {
          throw const AppFailure(FailureCode.invalidSnapshot);
        }
        return plan[call.page - 1];
      case YoungBusinessEndpoint.schedule:
        final pages =
            calendarResponses[call.day] ??
            <Object?>[_page(const <Map<String, Object?>>[], 0)];
        if (call.page < 1 || call.page > pages.length) {
          throw const AppFailure(FailureCode.invalidSnapshot);
        }
        return pages[call.page - 1];
    }
  }

  YoungBusinessStepReply _reply(
    _StepCall call, {
    bool complete = true,
    String projected = '',
  }) => YoungBusinessStepReply.decode(
    <String, Object?>{
      'session': call.session,
      'document': call.document,
      'operation': call.operation,
      'step': call.step,
      'complete': complete,
      if (complete) 'projectedJson': projected,
    },
    session: call.session,
    document: call.document,
    operation: call.operation,
    step: call.step,
  );

  @override
  Future<void> finishYoungBusiness({
    required int session,
    required int document,
    required int operation,
  }) async {
    _recordBinding(session, document, operation);
    if (failAtMethod == 'finish') {
      throw const AppFailure(FailureCode.sourceFailed);
    }
  }

  @override
  Future<void> navigateYoungBusinessPage({
    required int session,
    required int document,
    required YoungBusinessPage page,
  }) async {
    _recordBinding(session, document, 1);
    _changeRoute();
  }

  void _recordBinding(int session, int document, int operation) {
    if (session != this.session || document < 0 || operation <= 0) {
      throw const AppFailure(FailureCode.staleResult);
    }
    if (!operations.contains(operation)) operations.add(operation);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _events.close();
  }
}
