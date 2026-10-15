import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/young_daily_sync_contract.dart';
import 'package:ustc_assistant_m0/core/young_daily_sync_policy.dart';
import 'package:ustc_assistant_m0/jobs/young_daily_sync_coordinator.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_port.dart';

const _context = YoungDailySyncContext(
  owner: 'synthetic-owner',
  resetEpoch: 2,
  agendaEpoch: 4,
  revision: 1,
);
final _initialTime = DateTime.utc(2026, 10, 14, 22);
const _debounce = Duration(milliseconds: 190);

void main() {
  group('Young daily sync coordinator', () {
    test(
      'automatic work requires opt-in, foreground, and an idle source',
      () async {
        final disabled = _Harness(enabled: false);
        addTearDown(disabled.dispose);
        disabled.start();
        await _settle();
        expect(disabled.data.issuedGrants, 0);
        expect(disabled.source.startCalls, 0);

        final hidden = _Harness();
        addTearDown(hidden.dispose);
        hidden.start(foreground: false);
        await _settle();
        expect(hidden.data.issuedGrants, 0);
        expect(hidden.source.startCalls, 0);

        final busy = _Harness()..foregroundBusy = true;
        addTearDown(busy.dispose);
        busy.start();
        await _settle();
        expect(busy.data.issuedGrants, 0);
        expect(busy.source.startCalls, 0);

        final sourceBusy = _Harness();
        addTearDown(sourceBusy.dispose);
        sourceBusy.source.emit(YoungSyncView(phase: YoungSyncPhase.collecting));
        sourceBusy.start();
        await _settle();
        expect(sourceBusy.data.issuedGrants, 0);
        expect(sourceBusy.source.startCalls, 0);
        sourceBusy.source.emit(YoungSyncView());
        await _eventually(() => sourceBusy.source.startCalls == 1);
        expect(sourceBusy.source.startCalls, 1);
      },
    );

    test(
      'first foreground idle check starts one background job only once',
      () async {
        final harness = _Harness();
        addTearDown(harness.dispose);
        harness.start(foreground: false);
        await _settle();
        expect(harness.source.startCalls, 0);

        harness.coordinator.onForeground(true);
        harness.coordinator.onForeground(true);
        await _eventually(() => harness.source.startCalls == 1);
        expect(harness.source.startCalls, 1);
        expect(harness.source.backgroundValues, <bool>[true]);
        expect(harness.source.firstDay, DateTime.utc(2026, 10, 14));
        expect(harness.source.lastDay, DateTime.utc(2026, 11, 13));

        harness.data.emitChange();
        harness.data.emitChange();
        harness.coordinator.onForeground(true);
        harness.coordinator.onForeground(true);
        await _settle();
        expect(harness.data.issuedGrants, 1);
        expect(harness.source.startCalls, 1);
      },
    );

    test(
      'a job deferred for a competing operation refunds its automatic try',
      () async {
        final harness = _Harness();
        addTearDown(harness.dispose);
        harness.data.onClaim = () => harness.foregroundBusy = true;
        harness.start();

        await _eventually(
          () => harness.data.outcomes.contains(YoungDailySyncOutcome.deferred),
        );
        expect(harness.source.startCalls, 0);
        expect(harness.source.cancelCalls, 0);
        expect(harness.data.attempts, 0);

        harness.foregroundBusy = false;
        harness.data.onClaim = null;
        await _settle();
        await harness.coordinator.check();
        expect(harness.source.startCalls, 1);
      },
    );

    test(
      'automatic login challenge revokes then drains before needs-login',
      () async {
        final harness = _Harness()
          ..source.behavior = _StartBehavior.loginChallenge;
        harness.source.holdCancel();
        addTearDown(harness.dispose);
        harness.start();

        await _eventually(() => harness.source.cancelCalls == 1);
        expect(harness.data.lastIssuedGrant!.revoked, isTrue);
        expect(harness.data.activeGrant, isNull);
        expect(
          harness.data.outcomes,
          contains(YoungDailySyncOutcome.needsLogin),
        );
        expect(harness.source.syncView.busy, isTrue);

        harness.source.releaseCancel();
        await _eventually(
          () =>
              harness.coordinator.view.phase == YoungDailySyncPhase.needsLogin,
        );
        expect(harness.source.syncView.busy, isFalse);
      },
    );

    test(
      'manual sync uses the visible window and survives foreground yield',
      () async {
        final harness = _Harness()
          ..source.behavior = _StartBehavior.loginChallenge;
        addTearDown(harness.dispose);
        harness.start(foreground: false);
        await _settle();

        await harness.coordinator.syncNow();
        expect(harness.source.backgroundValues, <bool>[false]);
        expect(harness.coordinator.view.phase, YoungDailySyncPhase.needsLogin);
        expect(harness.data.activeGrant, isNotNull);

        await harness.coordinator.yieldToForeground();
        expect(harness.source.cancelCalls, 0);
        expect(harness.data.activeGrant, isNotNull);

        await harness.coordinator.continueAfterLogin();
        expect(harness.source.continueCalls, 1);
        expect(harness.source.syncView.phase, YoungSyncPhase.collecting);
        await harness.coordinator.cancel();
        expect(harness.data.outcomes.last, YoungDailySyncOutcome.interrupted);
        expect(harness.source.cancelCalls, 1);
      },
    );

    test('a continuation error fails and drains the manual grant', () async {
      final harness = _Harness()
        ..source.behavior = _StartBehavior.loginChallenge;
      harness.source.holdCancel();
      addTearDown(harness.dispose);
      harness.start(foreground: false);
      await _settle();
      await harness.coordinator.syncNow();
      final grant = harness.data.lastIssuedGrant!;
      final failure = const AppFailure(FailureCode.storageFailed);
      harness.source.continueError = failure;

      final continuing = harness.coordinator.continueAfterLogin();
      var continuationSettled = false;
      final observedContinuation = continuing.then<void>(
        (_) => continuationSettled = true,
      );
      await _eventually(() => harness.source.cancelCalls == 1);
      expect(grant.revoked, isTrue);
      expect(harness.data.activeGrant, isNull);
      expect(harness.data.outcomes.last, YoungDailySyncOutcome.failed);
      expect(harness.source.syncView.busy, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(continuationSettled, isFalse);

      harness.source.releaseCancel();
      await observedContinuation;
      expect(harness.source.syncView.busy, isFalse);
    });

    test(
      'a timed-out continuation fails and drains the manual grant',
      () async {
        final harness = _Harness(jobTimeout: const Duration(milliseconds: 25))
          ..source.behavior = _StartBehavior.loginChallenge;
        harness.source.holdContinue();
        harness.source.holdCancel();
        addTearDown(harness.dispose);
        harness.start(foreground: false);
        await _settle();
        await harness.coordinator.syncNow();
        final grant = harness.data.lastIssuedGrant!;

        final continuing = harness.coordinator.continueAfterLogin();
        var continuationSettled = false;
        final observedContinuation = continuing.then<void>(
          (_) => continuationSettled = true,
        );
        await harness.source.continueStarted;
        await _eventually(() => harness.source.cancelCalls == 1);
        expect(grant.revoked, isTrue);
        expect(harness.data.activeGrant, isNull);
        expect(harness.data.outcomes.last, YoungDailySyncOutcome.failed);

        harness.source.releaseContinue();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(continuationSettled, isFalse);
        harness.source.releaseCancel();
        await observedContinuation;
        expect(harness.source.syncView.busy, isFalse);
      },
    );

    test(
      'concurrent cancel and quiesce share finish failure after delayed drain',
      () async {
        final harness = _Harness();
        harness.source.holdCancel();
        addTearDown(harness.dispose);
        harness.start();
        await _eventually(() => harness.source.startCalls == 1);
        final failure = const AppFailure(FailureCode.storageFailed);
        harness.data.finishError = failure;
        harness.data.finishStarted = Completer<void>();

        final cancel = harness.coordinator.cancel();
        await harness.data.finishStarted!.future;
        await _eventually(() => harness.source.cancelCalls == 1);
        final quiesce = harness.coordinator.quiesceForMaintenance();
        var cancelSettled = false;
        var quiesceSettled = false;
        final cancelObserved = _expectSameFailure(
          cancel,
          failure,
        ).whenComplete(() => cancelSettled = true);
        final quiesceObserved = _expectSameFailure(
          quiesce,
          failure,
        ).whenComplete(() => quiesceSettled = true);

        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(cancelSettled, isFalse);
        expect(quiesceSettled, isFalse);
        expect(harness.data.activeGrant, isNull);

        harness.source.releaseCancel();
        await Future.wait<void>([cancelObserved, quiesceObserved]);
        expect(cancelSettled, isTrue);
        expect(quiesceSettled, isTrue);

        harness.data.finishError = null;
      },
    );

    test('foreground yield cancels an automatic job', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      harness.start();
      await _eventually(() => harness.source.startCalls == 1);

      await harness.coordinator.yieldToForeground();
      expect(harness.data.outcomes.last, YoungDailySyncOutcome.interrupted);
      expect(harness.source.cancelCalls, 1);
      expect(harness.data.activeGrant, isNull);
    });

    test(
      'only a C3 commit fact records success, not the source view flag',
      () async {
        final reportedOnly = _Harness();
        addTearDown(reportedOnly.dispose);
        reportedOnly.start();
        await _eventually(() => reportedOnly.source.startCalls == 1);
        reportedOnly.source.emitTerminal(committed: true);
        await _eventually(
          () =>
              reportedOnly.coordinator.view.phase == YoungDailySyncPhase.failed,
        );
        expect(reportedOnly.data.lastSuccessAtUtc, isNull);
        expect(reportedOnly.coordinator.view.nextAttemptAtUtc, isNotNull);

        final committed = _Harness();
        addTearDown(committed.dispose);
        committed.start();
        await _eventually(() => committed.source.startCalls == 1);
        committed.data.recordCommittedCalendar(committed.data.lastIssuedGrant!);
        committed.source.emitTerminal(committed: false);
        await _eventually(
          () => committed.coordinator.view.phase == YoungDailySyncPhase.done,
        );
        expect(committed.data.lastSuccessAtUtc, _initialTime);
        expect(
          committed.coordinator.view.nextAttemptAtUtc,
          DateTime.utc(2026, 10, 15, 22),
        );
      },
    );

    test(
      'failure backs off, next Beijing day resets, and cancel is not success',
      () async {
        final harness = _Harness();
        addTearDown(harness.dispose);
        harness.start();
        await _eventually(() => harness.source.startCalls == 1);

        harness.source.emitTerminal(failure: FailureCode.storageFailed);
        await _eventually(
          () => harness.coordinator.view.phase == YoungDailySyncPhase.failed,
        );
        final retryAt = DateTime.utc(2026, 10, 14, 22, 15);
        expect(harness.data.lastSuccessAtUtc, isNull);
        expect(harness.data.attempts, 1);
        expect(harness.coordinator.view.nextAttemptAtUtc, retryAt);
        await _settle();

        harness.clock.nowUtc = retryAt.subtract(const Duration(seconds: 1));
        await harness.coordinator.check();
        expect(harness.source.startCalls, 1);

        harness.clock.nowUtc = retryAt;
        await harness.coordinator.check();
        expect(harness.source.startCalls, 2);
        expect(harness.data.attempts, 2);
        harness.source.emitTerminal(failure: FailureCode.storageFailed);
        await _eventually(() => harness.data.outcomes.length == 2);
        await _settle();

        harness.clock.nowUtc = retryAt.add(const Duration(days: 1));
        await harness.coordinator.check();
        expect(harness.source.startCalls, 3);
        expect(harness.data.attemptDay, DateTime.utc(2026, 10, 16));
        expect(harness.data.attempts, 1);
        await harness.coordinator.cancel();
        expect(harness.data.outcomes.last, YoungDailySyncOutcome.interrupted);
        expect(harness.data.lastSuccessAtUtc, isNull);
      },
    );

    test(
      'disabling revokes the grant before its source drain completes',
      () async {
        final harness = _Harness();
        harness.source.holdCancel();
        addTearDown(harness.dispose);
        harness.start();
        await _eventually(() => harness.source.startCalls == 1);
        final grant = harness.data.lastIssuedGrant!;

        final disabling = harness.coordinator.setEnabled(false);
        await _eventually(() => harness.source.cancelCalls == 1);
        expect(harness.data.enabled, isFalse);
        expect(grant.revoked, isTrue);
        expect(harness.data.activeGrant, isNull);
        expect(harness.data.outcomes.last, YoungDailySyncOutcome.interrupted);

        harness.source.releaseCancel();
        await disabling;
        expect(harness.coordinator.view.phase, YoungDailySyncPhase.disabled);
        await _settle();
        expect(harness.source.startCalls, 1);
      },
    );

    test(
      'advice-only transition restricts and cancels its own grant',
      () async {
        final harness = _Harness();
        harness.source.holdCancel();
        addTearDown(harness.dispose);
        harness.start();
        await _eventually(() => harness.source.startCalls == 1);
        final grant = harness.data.lastIssuedGrant!;
        harness.agentAdviceOnly = true;

        harness.coordinator.onAgentStateChanged();
        await _eventually(() => harness.source.cancelCalls == 1);
        expect(harness.data.adviceRestricted, isTrue);
        expect(grant.revoked, isTrue);
        expect(harness.data.activeGrant, isNull);
        expect(harness.data.outcomes.last, YoungDailySyncOutcome.interrupted);

        harness.source.releaseCancel();
        await _eventually(
          () => harness.coordinator.view.phase == YoungDailySyncPhase.paused,
        );
      },
    );

    test('quiesce waits for the owned source drain', () async {
      final harness = _Harness();
      harness.source.holdCancel();
      addTearDown(harness.dispose);
      harness.start();
      await _eventually(() => harness.source.startCalls == 1);

      var quiesced = false;
      final stopping = harness.coordinator.quiesceForMaintenance();
      final observedStop = stopping.then<void>((_) {
        quiesced = true;
      });
      await _eventually(() => harness.source.cancelCalls == 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(quiesced, isFalse);
      expect(harness.data.activeGrant, isNull);

      harness.source.releaseCancel();
      await observedStop;
      expect(quiesced, isTrue);
      expect(harness.source.syncView.busy, isFalse);
    });

    test(
      'quiesce and close wait for drain and leave no active periodic work',
      () async {
        final harness = _Harness(
          checkInterval: const Duration(milliseconds: 250),
        );
        harness.source.holdCancel();
        addTearDown(harness.dispose);
        harness.start();
        await _eventually(() => harness.source.startCalls == 1);

        var didClose = false;
        final closing = harness.coordinator.close();
        final observedClose = closing.then<void>((_) => didClose = true);
        await _eventually(() => harness.source.cancelCalls == 1);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(didClose, isFalse);

        harness.source.releaseCancel();
        await observedClose;
        final inspectionsAfterClose = harness.data.inspectCalls;
        await Future<void>.delayed(const Duration(milliseconds: 450));
        expect(harness.data.inspectCalls, inspectionsAfterClose);
        expect(harness.source.startCalls, 1);
      },
    );
  });
}

Future<void> _settle() => Future<void>.delayed(_debounce);

Future<void> _expectSameFailure(Future<void> operation, Object expected) async {
  try {
    await operation;
  } catch (error) {
    expect(identical(error, expected), isTrue);
    return;
  }
  fail('Expected operation to fail with $expected.');
}

Future<void> _eventually(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final stopwatch = Stopwatch()..start();
  while (!condition() && stopwatch.elapsed < timeout) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

final class _Harness {
  _Harness({
    DateTime? nowUtc,
    bool enabled = true,
    bool accountBound = true,
    bool credentialSaved = true,
    bool adviceOnly = false,
    Duration checkInterval = const Duration(hours: 1),
    Duration jobTimeout = const Duration(seconds: 10),
  }) : clock = _MutableClock(nowUtc ?? _initialTime),
       data = _FakeData(
         enabled: enabled,
         accountBound: accountBound,
         credentialSaved: credentialSaved,
         adviceOnly: adviceOnly,
         clock: _MutableClock(nowUtc ?? _initialTime),
       ),
       source = _FakeYoungSource(),
       agentAdviceOnly = adviceOnly {
    // Share the same controllable clock with C3 and C2.
    data.clock = clock;
    coordinator = YoungDailySyncCoordinator(
      data: data,
      source: source,
      startCalendar: (grant, {required bool background}) =>
          source.startWithGrant(grant, background: background),
      isForegroundBusy: () => foregroundBusy,
      adviceOnly: () => agentAdviceOnly,
      clock: clock,
      checkInterval: checkInterval,
      jobTimeout: jobTimeout,
    );
  }

  final _MutableClock clock;
  final _FakeData data;
  final _FakeYoungSource source;
  late final YoungDailySyncCoordinator coordinator;
  bool foregroundBusy = false;
  bool agentAdviceOnly;
  bool _disposed = false;

  void start({bool foreground = true}) {
    coordinator.start();
    if (foreground) coordinator.onForeground(true);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    source.releaseContinue();
    source.releaseCancel();
    await coordinator.close();
    await source.close();
    await data.close();
  }
}

final class _MutableClock implements AppClock {
  _MutableClock(this.nowUtc);
  @override
  DateTime nowUtc;
}

final class _FakeGrant extends YoungDailySyncGrant {
  _FakeGrant(this.context, this.firstDay, this.endDayExclusive);
  @override
  final YoungDailySyncContext context;
  @override
  final DateTime firstDay;
  @override
  final DateTime endDayExclusive;
  bool revoked = false;
}

final class _AttemptState {
  const _AttemptState(this.day, this.count, this.nextAt, this.login);
  final DateTime? day;
  final int count;
  final DateTime? nextAt;
  final bool login;
}

final class _FakeData implements YoungDailySyncDataPort {
  _FakeData({
    required this.enabled,
    required this.accountBound,
    required this.credentialSaved,
    required this.adviceOnly,
    required this.clock,
  });

  final _changes = StreamController<int>.broadcast(sync: true);
  bool enabled;
  final bool accountBound;
  final bool credentialSaved;
  bool adviceOnly;
  _MutableClock clock;
  bool adviceRestricted = false;
  DateTime? lastSuccessAtUtc;
  DateTime? successFirstDay;
  DateTime? successEndDayExclusive;
  DateTime? attemptDay;
  int attempts = 0;
  DateTime? nextAttemptAtUtc;
  bool needsLogin = false;
  DateTime? suppressedDay;
  int inspectCalls = 0;
  int claimCalls = 0;
  int issuedGrants = 0;
  final outcomes = <YoungDailySyncOutcome>[];
  _FakeGrant? activeGrant;
  _FakeGrant? lastIssuedGrant;
  _AttemptState? _attemptBeforeClaim;
  void Function()? onClaim;
  Object? finishError;
  Completer<void>? finishStarted;

  @override
  Stream<int> get changes => _changes.stream;

  YoungDailySyncSnapshot get snapshot => YoungDailySyncSnapshot(
    context: _context,
    enabled: enabled,
    accountBound: accountBound,
    credentialSaved: credentialSaved,
    adviceOnly: adviceOnly,
    lastSuccessAtUtc: lastSuccessAtUtc,
    successFirstDay: successFirstDay,
    successEndDayExclusive: successEndDayExclusive,
    attemptDay: attemptDay,
    attempts: attempts,
    nextAttemptAtUtc: nextAttemptAtUtc,
    needsLogin: needsLogin,
    suppressedDay: suppressedDay,
  );

  @override
  void restrictToAdvice(bool restricted) {
    if (adviceRestricted == restricted && adviceOnly == restricted) return;
    adviceRestricted = restricted;
    adviceOnly = restricted;
    if (restricted) activeGrant?.revoked = true;
    _emitChange();
  }

  @override
  Future<YoungDailySyncSnapshot> inspect() async {
    inspectCalls++;
    return snapshot;
  }

  @override
  Future<YoungDailySyncSnapshot> setEnabled(
    YoungDailySyncContext context,
    bool enabled,
  ) async {
    if (context != _context) throw const AppFailure(FailureCode.staleResult);
    this.enabled = enabled;
    if (!enabled) activeGrant?.revoked = true;
    _emitChange();
    return snapshot;
  }

  @override
  Future<YoungDailySyncGrant?> claim({bool manual = false}) async {
    claimCalls++;
    onClaim?.call();
    if (activeGrant != null || adviceRestricted) return null;
    final plan = planYoungDailySync(snapshot, clock.nowUtc, manual: manual);
    if (!plan.shouldRun) return null;

    if (!manual) {
      _attemptBeforeClaim = _AttemptState(
        attemptDay,
        attempts,
        nextAttemptAtUtc,
        needsLogin,
      );
      final today = _beijingDay(clock.nowUtc);
      if (attemptDay == today) {
        attempts++;
      } else {
        attemptDay = today;
        attempts = 1;
      }
      nextAttemptAtUtc = null;
      needsLogin = false;
    }
    final grant = _FakeGrant(_context, plan.firstDay, plan.endDayExclusive);
    activeGrant = grant;
    lastIssuedGrant = grant;
    issuedGrants++;
    _emitChange();
    return grant;
  }

  @override
  Future<void> finish(
    YoungDailySyncGrant grant,
    YoungDailySyncOutcome outcome,
  ) async {
    final started = finishStarted;
    if (started != null && !started.isCompleted) started.complete();
    final issued = grant as _FakeGrant;
    issued.revoked = true;
    if (identical(activeGrant, issued)) activeGrant = null;
    outcomes.add(outcome);
    if (outcome == YoungDailySyncOutcome.deferred) {
      final before = _attemptBeforeClaim;
      if (before != null) {
        attemptDay = before.day;
        attempts = before.count;
        nextAttemptAtUtc = before.nextAt;
        needsLogin = before.login;
      }
    } else if (outcome == YoungDailySyncOutcome.failed) {
      nextAttemptAtUtc = clock.nowUtc.add(const Duration(minutes: 15));
      needsLogin = false;
    } else if (outcome == YoungDailySyncOutcome.needsLogin) {
      needsLogin = true;
      nextAttemptAtUtc = null;
    }
    _attemptBeforeClaim = null;
    _emitChange();
    final error = finishError;
    if (error != null) throw error;
  }

  /// Simulates C3's atomic full-calendar commit, independent of the source view.
  void recordCommittedCalendar(YoungDailySyncGrant grant) {
    final issued = grant as _FakeGrant;
    if (!identical(activeGrant, issued) || issued.revoked) {
      throw const AppFailure(FailureCode.staleResult);
    }
    lastSuccessAtUtc = clock.nowUtc;
    successFirstDay = issued.firstDay;
    successEndDayExclusive = issued.endDayExclusive;
    needsLogin = false;
    nextAttemptAtUtc = null;
    _emitChange();
  }

  void emitChange() => _emitChange();

  void _emitChange() {
    if (!_changes.isClosed) _changes.add(_changes.hashCode);
  }

  Future<void> close() => _changes.close();
}

enum _StartBehavior { collecting, loginChallenge }

final class _FakeYoungSource implements YoungSyncPort {
  final _changes = StreamController<YoungSyncView>.broadcast(sync: true);
  YoungSyncView _view = YoungSyncView();
  _StartBehavior behavior = _StartBehavior.collecting;
  int startCalls = 0;
  int cancelCalls = 0;
  int continueCalls = 0;
  final backgroundValues = <bool>[];
  DateTime? firstDay;
  DateTime? lastDay;
  Completer<void>? _cancelGate;
  Completer<void>? _cancelStarted;
  Completer<void>? _continueGate;
  Completer<void>? _continueStarted;
  Object? continueError;
  Future<void> get continueStarted => _continueStarted!.future;

  @override
  YoungSyncView get syncView => _view;

  @override
  Stream<YoungSyncView> get syncChanges => _changes.stream;

  Future<void> startWithGrant(
    YoungDailySyncGrant grant, {
    required bool background,
  }) async {
    startCalls++;
    backgroundValues.add(background);
    firstDay = grant.firstDay;
    lastDay = grant.endDayExclusive.subtract(const Duration(days: 1));
    if (behavior == _StartBehavior.loginChallenge) {
      emit(
        YoungSyncView(
          phase: YoungSyncPhase.login,
          automation: YoungAutomationState.manualRequired,
        ),
      );
    } else {
      emit(
        YoungSyncView(
          phase: YoungSyncPhase.collecting,
          automation: YoungAutomationState.preparing,
        ),
      );
    }
  }

  void holdCancel() {
    _cancelGate = Completer<void>();
    _cancelStarted = Completer<void>();
  }

  void releaseCancel() {
    final gate = _cancelGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  void holdContinue() {
    _continueGate = Completer<void>();
    _continueStarted = Completer<void>();
  }

  void releaseContinue() {
    final gate = _continueGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  void emit(YoungSyncView view) {
    _view = view;
    if (!_changes.isClosed) _changes.add(view);
  }

  void emitTerminal({bool committed = false, FailureCode? failure}) => emit(
    YoungSyncView(
      phase: YoungSyncPhase.idle,
      committed: committed,
      failure: failure,
    ),
  );

  @override
  Future<void> continueAfterLogin() async {
    continueCalls++;
    final started = _continueStarted;
    if (started != null && !started.isCompleted) started.complete();
    await _continueGate?.future;
    final error = continueError;
    if (error != null) throw error;
    emit(
      YoungSyncView(
        phase: YoungSyncPhase.collecting,
        automation: YoungAutomationState.preparing,
      ),
    );
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    final started = _cancelStarted;
    if (started != null && !started.isCompleted) started.complete();
    await _cancelGate?.future;
    emit(YoungSyncView());
  }

  @override
  Future<void> startCalendar({
    String? expectedAccountCode,
    required DateTime firstDay,
    required DateTime lastDay,
    String? password,
    bool savePassword = false,
  }) => throw UnimplementedError();

  @override
  Future<void> startActivities({
    String? expectedAccountCode,
    String? password,
    bool savePassword = false,
  }) => throw UnimplementedError();

  @override
  Future<void> retryRecovery() async {}

  @override
  Future<void> clearSession() async {}

  @override
  Future<void> deleteSavedCredential() async {}

  @override
  Future<void> setHidden({
    required int localId,
    required int expectedVersion,
    required bool hidden,
  }) async {}

  Future<void> close() => _changes.close();
}

DateTime _beijingDay(DateTime nowUtc) {
  final beijing = nowUtc.add(const Duration(hours: 8));
  return DateTime.utc(beijing.year, beijing.month, beijing.day);
}
