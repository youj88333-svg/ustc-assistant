import 'dart:async';

import '../core/agenda_contract.dart';
import '../core/contracts.dart';
import '../core/young_daily_sync_contract.dart';
import '../core/young_daily_sync_policy.dart';
import 'young_sync_port.dart';

/// Lower-priority scheduling over the existing C2 source, with no model or OS
/// background process. Every actual admission is still authorized by C3.
final class YoungDailySyncCoordinator implements YoungDailySyncControlPort {
  YoungDailySyncCoordinator({
    required this.data,
    required this.source,
    required this.startCalendar,
    required this.isForegroundBusy,
    required this.adviceOnly,
    this.clock = const SystemClock(),
    this.checkInterval = const Duration(minutes: 1),
    this.jobTimeout = const Duration(minutes: 5),
    this.cancelOnBackground = false,
    this.automaticAvailable = true,
  }) : _view = YoungDailySyncView(automaticAvailable: automaticAvailable);
  final YoungDailySyncDataPort data;
  final YoungSyncPort source;
  final Future<void> Function(
    YoungDailySyncGrant grant, {
    required bool background,
  })
  startCalendar;
  final bool Function() isForegroundBusy, adviceOnly;
  final AppClock clock;
  final Duration checkInterval, jobTimeout;
  final bool cancelOnBackground, automaticAvailable;
  final _changes = StreamController<YoungDailySyncView>.broadcast();
  bool get isClosed => _closed;
  @override
  YoungDailySyncView get view => _view;
  YoungDailySyncView _view;
  @override
  Stream<YoungDailySyncView> get changes => _changes.stream;
  YoungDailySyncSnapshot? _snapshot;
  YoungDailySyncGrant? _grant;
  YoungSyncView? _terminal;
  StreamSubscription<int>? _dataSubscription;
  StreamSubscription<YoungSyncView>? _sourceSubscription;
  Timer? _timer, _refresh;
  Future<void>? _checking, _stopping;
  bool _foreground = false,
      _paused = false,
      _closed = false,
      _interactive = false,
      _launching = false,
      _ownsSource = false;

  void start() {
    if (_closed || _dataSubscription != null) return;
    _dataSubscription = data.changes.listen((_) => _schedule());
    _sourceSubscription = source.syncChanges.listen(_onSource);
    _timer = Timer.periodic(checkInterval, (_) => _schedule());
    _schedule();
  }

  void _schedule() {
    if (_closed || _paused) return;
    _refresh?.cancel();
    _refresh = Timer(
      const Duration(milliseconds: 150),
      () => unawaited(check()),
    );
  }

  void onForeground(bool foreground) {
    _foreground = foreground;
    if (!foreground && cancelOnBackground && _grant != null) {
      unawaited(
        _stop(YoungDailySyncOutcome.interrupted).catchError((Object _) {}),
      );
    } else if (foreground) {
      _schedule();
    }
  }

  void onAgentStateChanged() {
    data.restrictToAdvice(adviceOnly());
    if (adviceOnly() && _grant != null) {
      unawaited(
        _stop(YoungDailySyncOutcome.interrupted).catchError((Object _) {}),
      );
    } else {
      _schedule();
    }
  }

  void _publish(YoungDailySyncPhase phase, {FailureCode? failure}) {
    if (_closed) return;
    final snapshot = _snapshot;
    final decision = snapshot == null ? null : _decisionForView(snapshot);
    _view = YoungDailySyncView(
      enabled: snapshot?.enabled ?? false,
      phase: phase,
      lastSuccessAtUtc: snapshot?.lastSuccessAtUtc,
      firstDay: decision?.firstDay,
      endDayExclusive: decision?.endDayExclusive,
      nextAttemptAtUtc: decision?.nextAttemptAtUtc,
      attempts: snapshot?.attempts ?? 0,
      adviceOnly: snapshot?.adviceOnly ?? false,
      configured: snapshot?.accountBound ?? false,
      suppressedToday: snapshot?.suppressedDay == beijingDay(clock.nowUtc),
      interactive: _interactive && _ownsSource,
      automaticAvailable: automaticAvailable,
      failure: failure,
    );
    _changes.add(_view);
  }

  YoungDailySyncDecision _decisionForView(YoungDailySyncSnapshot snapshot) {
    final now = clock.nowUtc;
    final policy = planYoungDailySync(snapshot, now);
    if (automaticAvailable ||
        !snapshot.enabled ||
        snapshot.adviceOnly ||
        !snapshot.accountBound) {
      return policy;
    }

    final beijingNow = now.add(const Duration(hours: 8));
    final today = DateTime.utc(
      beijingNow.year,
      beijingNow.month,
      beijingNow.day,
    );
    final firstDay = today.subtract(const Duration(days: 1));
    final endDayExclusive = firstDay.add(const Duration(days: 31));
    final todayAtSixUtc = DateTime.utc(
      today.year,
      today.month,
      today.day,
    ).subtract(const Duration(hours: 2));
    final tomorrowAtSixUtc = todayAtSixUtc.add(const Duration(days: 1));

    YoungDailySyncDecision decision(
      YoungDailySyncPhase phase, {
      DateTime? nextAttemptAtUtc,
    }) => YoungDailySyncDecision(
      firstDay: firstDay,
      endDayExclusive: endDayExclusive,
      phase: phase,
      shouldRun: false,
      nextAttemptAtUtc: nextAttemptAtUtc,
    );

    // The shared policy checks saved credentials before today's success. On
    // iOS the daily check never uses those credentials, so preserve C3's
    // persisted full-success fact independently of the credential flag.
    if (_hasCurrentFullSuccess(snapshot, today, firstDay, endDayExclusive)) {
      return decision(
        YoungDailySyncPhase.done,
        nextAttemptAtUtc: tomorrowAtSixUtc,
      );
    }
    if (_sameDay(snapshot.suppressedDay, today)) {
      return decision(
        YoungDailySyncPhase.paused,
        nextAttemptAtUtc: tomorrowAtSixUtc,
      );
    }
    if (now.isBefore(todayAtSixUtc)) {
      return decision(
        YoungDailySyncPhase.scheduled,
        nextAttemptAtUtc: todayAtSixUtc,
      );
    }
    if (!_foreground) return decision(YoungDailySyncPhase.paused);
    return decision(YoungDailySyncPhase.needsLogin);
  }

  bool _hasCurrentFullSuccess(
    YoungDailySyncSnapshot snapshot,
    DateTime today,
    DateTime firstDay,
    DateTime endDayExclusive,
  ) {
    final successAt = snapshot.lastSuccessAtUtc;
    final successFirst = snapshot.successFirstDay;
    final successEnd = snapshot.successEndDayExclusive;
    if (successAt == null || successFirst == null || successEnd == null) {
      return false;
    }
    final beijingSuccess = successAt.add(const Duration(hours: 8));
    final successDay = DateTime.utc(
      beijingSuccess.year,
      beijingSuccess.month,
      beijingSuccess.day,
    );
    return successDay == today &&
        !_dateOnly(successFirst).isAfter(firstDay) &&
        !_dateOnly(successEnd).isBefore(endDayExclusive);
  }

  bool _sameDay(DateTime? value, DateTime date) =>
      value != null && _dateOnly(value) == date;

  DateTime _dateOnly(DateTime value) =>
      DateTime.utc(value.year, value.month, value.day);

  Future<void> check({bool manual = false}) async {
    if (_closed || _paused || _checking != null) return;
    if (_grant != null) return;
    final done = Completer<void>();
    _checking = done.future;
    try {
      data.restrictToAdvice(adviceOnly());
      final snapshot = await data.inspect();
      if (_closed || _paused) return;
      _snapshot = snapshot;
      final decision = manual
          ? planYoungDailySync(snapshot, clock.nowUtc, manual: true)
          : _decisionForView(snapshot);
      if (!manual && !automaticAvailable) {
        _publish(decision.phase);
        return;
      }
      if (!decision.shouldRun) {
        _publish(decision.phase);
        return;
      }
      if (((!manual || cancelOnBackground) && !_foreground) ||
          isForegroundBusy() ||
          source.syncView.busy) {
        _publish(
          !_foreground && (!manual || cancelOnBackground)
              ? YoungDailySyncPhase.paused
              : YoungDailySyncPhase.waitingForIdle,
        );
        return;
      }
      final grant = await data.claim(manual: manual);
      if (grant == null) {
        _snapshot = await data.inspect();
        _publish(_decisionForView(_snapshot!).phase);
        return;
      }
      _grant = grant;
      _interactive = manual;
      _terminal = null;
      if (cancelOnBackground && !_foreground) {
        await _stop(YoungDailySyncOutcome.interrupted);
        return;
      }
      if (_closed ||
          _paused ||
          (!manual && !_foreground) ||
          isForegroundBusy()) {
        await _stop(YoungDailySyncOutcome.deferred);
        return;
      }
      _launching = true;
      _ownsSource = true;
      _publish(YoungDailySyncPhase.syncing);
      try {
        await startCalendar(grant, background: !manual).timeout(jobTimeout);
      } on Object catch (error) {
        if (error is AppFailure && error.code == FailureCode.busy) {
          _ownsSource = false;
          await _stop(YoungDailySyncOutcome.deferred);
        } else {
          await _stop(YoungDailySyncOutcome.failed);
        }
      } finally {
        _launching = false;
      }
      if (_grant == null) return;
      if (source.syncView.automation == YoungAutomationState.manualRequired) {
        if (manual) {
          _publish(YoungDailySyncPhase.needsLogin);
        } else {
          await _stop(YoungDailySyncOutcome.needsLogin);
        }
      } else if (!source.syncView.busy || _terminal != null) {
        await _stop(YoungDailySyncOutcome.failed);
      }
    } on Object catch (error) {
      _publish(
        YoungDailySyncPhase.failed,
        failure: error is AppFailure ? error.code : FailureCode.storageFailed,
      );
    } finally {
      _checking = null;
      done.complete();
    }
  }

  void _onSource(YoungSyncView sourceView) {
    if (_closed || _grant == null) {
      _schedule();
      return;
    }
    if (!_ownsSource && !_launching) return;
    if (!sourceView.busy) {
      _terminal = sourceView;
      _ownsSource = false;
      if (!_launching) {
        unawaited(
          _stop(YoungDailySyncOutcome.failed).catchError((Object _) {}),
        );
      }
    } else if (_interactive &&
        sourceView.automation == YoungAutomationState.manualRequired) {
      _publish(YoungDailySyncPhase.needsLogin);
    } else {
      _publish(YoungDailySyncPhase.syncing);
    }
  }

  Future<void> _stop(YoungDailySyncOutcome outcome) {
    if (_stopping != null) return _stopping!;
    final grant = _grant;
    if (grant == null) return Future.value();
    final done = Completer<void>();
    _stopping = done.future;
    unawaited(() async {
      // Calling finish revokes the capability synchronously, before awaiting
      // either the SQL queue or native/source drain.
      try {
        // Attach handlers to both paths immediately, including synchronous
        // port failures. All concurrent stop callers share this same result.
        await Future.wait<void>([
          Future<void>.sync(() => data.finish(grant, outcome)),
          Future<void>.sync(() async {
            if (_ownsSource && source.syncView.busy) await source.cancel();
          }),
        ]);
        if (identical(_grant, grant)) _grant = null;
        _ownsSource = false;
        _interactive = false;
        _snapshot = await data.inspect();
        final decision = _decisionForView(_snapshot!);
        _publish(decision.phase, failure: _terminal?.failure);
        done.complete();
      } catch (error, stack) {
        // A failed drain retains the shared source lease for recovery; the
        // in-memory grant remains revoked even if its SQL finish failed.
        _publish(
          YoungDailySyncPhase.failed,
          failure: error is AppFailure ? error.code : FailureCode.storageFailed,
        );
        done.completeError(error, stack);
      } finally {
        _stopping = null;
      }
    }());
    return done.future;
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    final snapshot = _snapshot ?? await data.inspect();
    final saving = data.setEnabled(snapshot.context, enabled);
    if (!enabled && _grant != null) {
      // The store has already revoked access; drain may proceed concurrently
      // with the queued settings save without waiting for another query.
      final stopping = _stop(YoungDailySyncOutcome.interrupted);
      try {
        await saving;
      } finally {
        await stopping;
      }
    } else {
      await saving;
    }
    _snapshot = await data.inspect();
    _publish(_decisionForView(_snapshot!).phase);
    _schedule();
  }

  @override
  Future<void> syncNow() async {
    if (!automaticAvailable) {
      final checking = _checking;
      if (checking != null) await checking;
    }
    await check(manual: true);
  }

  @override
  Future<void> continueAfterLogin() async {
    if (!_interactive || !_ownsSource || _grant == null) {
      throw const AppFailure(FailureCode.busy);
    }
    _publish(YoungDailySyncPhase.syncing);
    _launching = true;
    try {
      await source.continueAfterLogin().timeout(jobTimeout);
    } on Object {
      await _stop(YoungDailySyncOutcome.failed);
      return;
    } finally {
      _launching = false;
    }
    if (!source.syncView.busy) {
      await _stop(YoungDailySyncOutcome.failed);
    } else if (source.syncView.automation ==
        YoungAutomationState.manualRequired) {
      _publish(YoungDailySyncPhase.needsLogin);
    }
  }

  @override
  Future<void> cancel() => _stop(YoungDailySyncOutcome.interrupted);
  Future<void> yieldToForeground() async {
    if (!_interactive) await _stop(YoungDailySyncOutcome.interrupted);
  }

  Future<void> quiesceForMaintenance() async {
    _paused = true;
    _refresh?.cancel();
    await _stop(YoungDailySyncOutcome.interrupted);
    await _checking;
  }

  void resumeAfterMaintenance() {
    if (!_closed) {
      _paused = false;
      _schedule();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    await quiesceForMaintenance();
    _closed = true;
    _timer?.cancel();
    _refresh?.cancel();
    await _dataSubscription?.cancel();
    await _sourceSubscription?.cancel();
    await _changes.close();
  }
}
