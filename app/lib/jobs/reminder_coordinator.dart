import 'dart:async';
import 'dart:math';

import '../core/diagnostics_contract.dart';
import '../core/contracts.dart';
import '../core/reminder_contract.dart';

/// C5 composition use case: C3 determines desired business state; P only
/// schedules/cancels its own OS identity. No school/network lease is acquired.
final class ReminderCoordinator {
  ReminderCoordinator({
    required this.data,
    required this.platform,
    this.diagnostics,
    this.clock = const SystemClock(),
  }) {
    _navigation.onListen = _resumeNavigation;
  }
  final ReminderDataPort data;
  final NotificationPlatformPort platform;
  final DiagnosticsPort? diagnostics;
  final AppClock clock;
  final _changes = StreamController<ReminderRuntimeView>.broadcast();
  final _navigation = StreamController<ReminderTarget>.broadcast();
  ReminderRuntimeView _view = const ReminderRuntimeView();
  ReminderRuntimeView get view => _view;
  Stream<ReminderRuntimeView> get changes => _changes.stream;
  Stream<ReminderTarget> get navigation => _navigation.stream;
  StreamSubscription<int>? _subscription;
  StreamSubscription<NotificationActivation>? _activations;
  StreamSubscription<ReminderFailure>? _activationFailures;
  Future<void>? _work;
  bool _again = false,
      _paused = false,
      _closed = false,
      _initialized = false,
      _closing = false;
  int _generation = 0;
  Timer? _timer, _rollTimer, _testRefillTimer;
  DiagnosticNotificationStep _diagnosticStep =
      DiagnosticNotificationStep.preparing;
  int? _diagnosticPending, _diagnosticDesired, _diagnosticAccepted;
  ReminderPublication? _lastPublication;
  NotificationCapability? _capability;
  final _waitingNavigation = <NotificationActivation>[];
  Future<void>? _navigationWork;
  Timer? _navigationRetryTimer;
  int _navigationRetryAttempts = 0;
  bool _navigationBlocked = false;

  void _resumeNavigation() {
    if (_closed || _closing || _paused) return;
    _navigationRetryTimer?.cancel();
    _navigationRetryTimer = null;
    _navigationRetryAttempts = 0;
    _navigationBlocked = false;
    unawaited(_drainNavigation());
  }

  void _cancelNavigationRetry() {
    _navigationRetryTimer?.cancel();
    _navigationRetryTimer = null;
    _navigationRetryAttempts = 0;
    _navigationBlocked = false;
  }

  Future<void> _drainNavigation() async {
    if (_navigationWork != null ||
        !_navigation.hasListener ||
        _closed ||
        _closing ||
        _navigationBlocked ||
        _paused) {
      return;
    }
    final done = Completer<void>();
    _navigationWork = done.future;
    try {
      while (_waitingNavigation.isNotEmpty &&
          _navigation.hasListener &&
          !_closed &&
          !_closing &&
          !_paused) {
        final activation = _waitingNavigation.removeAt(0);
        final generation = _generation;
        try {
          // Revalidate with C3 when the UI can actually receive it; a startup
          // click must not disappear into an unsubscribed broadcast stream.
          final target = await data.resolveNotification(activation);
          if (!_live(generation) || _closing) return;
          if (!_navigation.hasListener) {
            _waitingNavigation.insert(0, activation);
            return;
          }
          if (target != null) _navigation.add(target);
          _navigationRetryAttempts = 0;
        } on Object catch (error) {
          if (!_live(generation) || _closing) return;
          if (error is ReminderFailure &&
              error.code != ReminderFailureCode.storageFailed) {
            // C3 explicitly rejects an obsolete/untrusted target.
            _navigationRetryAttempts = 0;
            continue;
          }
          _waitingNavigation.insert(0, activation);
          _navigationBlocked = true;
          _log(
            DiagnosticEventName.reminderFailed,
            DiagnosticOutcome.failure,
            ReminderFailureCode.storageFailed.name,
          );
          if (_navigationRetryAttempts < 3) {
            final delay = Duration(seconds: 1 << _navigationRetryAttempts++);
            _navigationRetryTimer = Timer(delay, () {
              _navigationRetryTimer = null;
              _navigationBlocked = false;
              unawaited(_drainNavigation());
            });
          }
          return;
        }
      }
    } finally {
      _navigationWork = null;
      done.complete();
      if (_waitingNavigation.isNotEmpty &&
          _navigation.hasListener &&
          !_closed &&
          !_closing &&
          !_navigationBlocked &&
          !_paused) {
        scheduleMicrotask(() => unawaited(_drainNavigation()));
      }
    }
  }

  void _publish({
    bool busy = false,
    int accepted = 0,
    int desired = 0,
    bool complete = false,
    DateTime? through,
    DateTime? registeredThroughUtc,
    ReminderFailureCode? failure,
  }) {
    _view = ReminderRuntimeView(
      busy: busy,
      accepted: accepted,
      desired: desired,
      complete: complete,
      throughDay: through,
      registeredThroughUtc: registeredThroughUtc,
      failure: failure,
      capability: _capability,
    );
    if (!_closed) _changes.add(_view);
  }

  void start() {
    if (_closed || _subscription != null) return;
    _subscription = data.changes.listen((_) => _scheduleRefresh());
    _activations = platform.activations.listen((activation) {
      if (_closed || _paused) return;
      if (_waitingNavigation.length == 32) _waitingNavigation.removeAt(0);
      _waitingNavigation.add(activation);
      _resumeNavigation();
    });
    final status = platform;
    if (status is NotificationActivationStatusPort) {
      _activationFailures = (status as NotificationActivationStatusPort)
          .activationFailures
          .listen((failure) {
            _publish(
              accepted: _view.accepted,
              desired: _view.desired,
              complete: _view.complete,
              through: _view.throughDay,
              registeredThroughUtc: _view.registeredThroughUtc,
              failure: failure.code,
            );
            _log(
              DiagnosticEventName.reminderFailed,
              DiagnosticOutcome.failure,
              failure.code.name,
            );
          });
    }
    _scheduleRefresh();
  }

  void _scheduleRefresh() {
    if (_paused || _closed || _closing) return;
    _timer?.cancel();
    _timer = Timer(
      const Duration(milliseconds: 200),
      () => unawaited(refresh()),
    );
  }

  /// Windows delivery frees queue slots without a C3 change notification.
  /// Keep the same bounded projection moving while this process is alive.
  void _scheduleRollingRefresh() {
    _rollTimer?.cancel();
    _rollTimer = null;
    final publication = _lastPublication;
    if (_subscription == null ||
        _paused ||
        _closed ||
        _closing ||
        publication?.enabled != true) {
      return;
    }
    final now = clock.nowUtc.toUtc();
    var next = now.add(const Duration(minutes: 30));
    if (_view.failure == null) {
      for (final mapping in publication!.desired) {
        final delivered = mapping.request.deliveryAtUtc.add(
          const Duration(seconds: 1),
        );
        if (delivered.isAfter(now) && delivered.isBefore(next)) {
          next = delivered;
        }
      }
    }
    _rollTimer = Timer(next.difference(now), () {
      _rollTimer = null;
      unawaited(refresh());
    });
  }

  void onForeground() {
    _resumeNavigation();
    _scheduleRefresh();
  }

  bool get supportsSystemAccess => platform is NotificationSystemControlPort;

  Future<void> configureSystemAccess(NotificationAccessAction action) async {
    if (_closed || _paused || _closing || _work != null) {
      throw const ReminderFailure(ReminderFailureCode.maintenance);
    }
    final control = platform;
    if (control is! NotificationSystemControlPort) return;
    final done = Completer<void>();
    _work = done.future;
    try {
      switch (action) {
        case NotificationAccessAction.inspect:
          await _ensurePlatform();
        case NotificationAccessAction.notifications:
          _capability = await (control as NotificationSystemControlPort)
              .requestNotifications();
        case NotificationAccessAction.exactAlarms:
          _capability = await (control as NotificationSystemControlPort)
              .requestExactAlarms();
        case NotificationAccessAction.settings:
          await (control as NotificationSystemControlPort).openSystemSettings();
      }
      _publish(
        accepted: _view.accepted,
        desired: _view.desired,
        complete: _view.complete,
        through: _view.throughDay,
        registeredThroughUtc: _view.registeredThroughUtc,
      );
    } finally {
      _work = null;
      done.complete();
      _scheduleRefresh();
    }
  }

  Future<void> _bind(ReminderPublication publication) async {
    final control = platform;
    if (control is NotificationPublicationControlPort) {
      await (control as NotificationPublicationControlPort).bindPublication(
        publication,
      );
    }
  }

  Future<void> _ensurePlatform() async {
    _capability = await platform.initialize();
    if (_capability?.available != true) {
      throw const ReminderFailure(ReminderFailureCode.platformUnavailable);
    }
    _initialized = true;
  }

  Future<void> refresh() async {
    if (_closed || _paused || _closing) return;
    if (_work != null) {
      _again = true;
      return;
    }
    final done = Completer<void>();
    _work = done.future;
    _rollTimer?.cancel();
    try {
      do {
        _again = false;
        final generation = _generation;
        try {
          await _reconcile(generation);
        } on Object catch (error) {
          final failure = error is ReminderFailure
              ? error.code
              : ReminderFailureCode.publishFailed;
          _publish(
            failure: failure,
            desired: _view.desired,
            accepted: _view.accepted,
            complete: false,
            through: _view.throughDay,
            registeredThroughUtc: _view.registeredThroughUtc,
          );
          _log(
            DiagnosticEventName.reminderFailed,
            DiagnosticOutcome.failure,
            failure.name,
            operation: DiagnosticNotificationOperation.reconcile,
            failure: error is ReminderFailure ? error : null,
          );
          _again = false;
        }
      } while (_again && !_paused && !_closed && !_closing);
    } finally {
      _work = null;
      done.complete();
      _scheduleRollingRefresh();
    }
  }

  bool _live(int generation) =>
      !_closed && !_paused && generation == _generation;
  Future<void> _reconcile(int generation) async {
    _diagnosticStep = DiagnosticNotificationStep.preparing;
    _diagnosticPending = null;
    _diagnosticDesired = null;
    _diagnosticAccepted = null;
    _publish(
      busy: true,
      accepted: _view.accepted,
      desired: _view.desired,
      complete: _view.complete,
      through: _view.throughDay,
      registeredThroughUtc: _view.registeredThroughUtc,
      failure: _view.failure,
    );
    final publication = await data.prepareReminderPublication();
    _diagnosticDesired = publication.desired.length;
    if (!_live(generation)) return;
    _lastPublication = publication;
    if (!publication.enabled && publication.prior.isEmpty && !_initialized) {
      _publish(complete: true, through: publication.throughDay);
      return;
    }
    _diagnosticStep = DiagnosticNotificationStep.permissions;
    await _ensurePlatform();
    if (!_live(generation) ||
        !await data.reminderPublicationCurrent(publication)) {
      _again = true;
      return;
    }
    _diagnosticStep = DiagnosticNotificationStep.binding;
    await _bind(publication);
    if (!_live(generation)) return;
    _log(
      DiagnosticEventName.reminderReconcileStarted,
      DiagnosticOutcome.started,
      null,
      operation: DiagnosticNotificationOperation.reconcile,
    );
    _diagnosticStep = DiagnosticNotificationStep.readingQueue;
    final actual = await platform.pending();
    _diagnosticPending = actual.length;
    _diagnosticAccepted = confirmedCount(publication.desired, actual);
    final desired = {for (final m in publication.desired) m.request.id: m};
    final preserved = publication.prior.map((m) => m.request.id).toSet()
      ..removeAll(publication.invalidPriorIds);
    final ordered = publication.desired.toList()
      ..sort((left, right) {
        final byTime = left.request.deliveryAtUtc.compareTo(
          right.request.deliveryAtUtc,
        );
        return byTime != 0
            ? byTime
            : left.request.id.compareTo(right.request.id);
      });
    final capacity = (_capability?.maximumPending ?? 512).clamp(1, 512).toInt();
    final retained = actual
        .where(
          (item) =>
              !desired.containsKey(item.id) &&
              (preserved.contains(item.id) ||
                  publication.enabled && _activeTest(item)),
        )
        .length;
    final slotCount = max(0, capacity - retained).toInt();
    final selected = ordered.take(slotCount).toList(growable: false);
    final selectedIds = selected.map((mapping) => mapping.request.id).toSet();
    final remove = actual
        .where(
          (a) =>
              publication.invalidPriorIds.contains(a.id) ||
              !desired.containsKey(a.id) &&
                  !preserved.contains(a.id) &&
                  !(publication.enabled && _activeTest(a)) ||
              desired.containsKey(a.id) &&
                  (!selectedIds.contains(a.id) ||
                      !a.matches(desired[a.id]!.request)),
        )
        .map((a) => a.id)
        .toSet();
    // Explicit invalidation also removes already displayed own items in P.
    remove.addAll(publication.invalidPriorIds);
    for (final id in remove) {
      if (!_live(generation) ||
          !await data.reminderPublicationCurrent(publication)) {
        _again = true;
        return;
      }
      _diagnosticStep = DiagnosticNotificationStep.makingSpace;
      await platform.cancel(id);
      await data.recordReminderCancelled(id);
    }
    // Verify canceled queue entries before using the released slots. A native
    // acknowledgement without readback cannot prove the near-term request fits.
    final afterCancel = await platform.pending();
    _diagnosticPending = afterCancel.length;
    _diagnosticAccepted = confirmedCount(publication.desired, afterCancel);
    for (final test in afterCancel.where(_activeTest)) {
      _scheduleTestRefill(test.deliveryAtUtc);
    }
    if (afterCancel.any((item) => remove.contains(item.id))) {
      throw const ReminderFailure(ReminderFailureCode.cancelFailed);
    }
    for (final mapping in ordered.where(
      (mapping) =>
          !selectedIds.contains(mapping.request.id) &&
          mapping.accepted &&
          !remove.contains(mapping.request.id),
    )) {
      if (!_live(generation) ||
          !await data.reminderPublicationCurrent(publication)) {
        _again = true;
        return;
      }
      await data.recordReminderCancelled(mapping.request.id);
    }
    if (!_live(generation) ||
        !await data.reminderPublicationCurrent(publication)) {
      _again = true;
      return;
    }
    var pending = afterCancel;
    var accepted = confirmedCount(selected, pending);
    var registeredThroughUtc = latestDueTime(pending);
    var complete =
        publication.complete && selected.length == publication.desired.length;
    void publishProgress() => _publish(
      busy: true,
      accepted: accepted,
      desired: publication.desired.length,
      complete: false,
      through: publication.throughDay,
      registeredThroughUtc: registeredThroughUtc,
    );

    publishProgress();
    for (final mapping in selected) {
      if (!_live(generation) ||
          !await data.reminderPublicationCurrent(publication)) {
        _again = true;
        break;
      }
      final matching = pending
          .where((a) => a.id == mapping.request.id)
          .toList();
      if (matching.length == 1 && matching.single.matches(mapping.request)) {
        await data.recordReminderAccepted(publication, mapping.request.id);
        continue;
      }
      if (mapping.accepted && !remove.contains(mapping.request.id)) {
        await data.recordReminderCancelled(mapping.request.id);
      }
      if (_capability?.enabledBySystem != true) {
        throw const ReminderFailure(ReminderFailureCode.disabledBySystem);
      }
      if (pending.length >= capacity) {
        complete = false;
        break;
      }
      _diagnosticStep = DiagnosticNotificationStep.registering;
      await platform.schedule(mapping.request);
      if (!_live(generation) ||
          !await data.reminderPublicationCurrent(publication)) {
        await platform.cancel(mapping.request.id);
        await data.recordReminderCancelled(mapping.request.id);
        _again = true;
        break;
      }
      // Windows reads its OS queue; Android confirms durable local registration
      // plus a successful AlarmManager call. Neither proves actual delivery.
      _diagnosticStep = DiagnosticNotificationStep.verifying;
      final verifiedQueue = await platform.pending();
      _diagnosticPending = verifiedQueue.length;
      _diagnosticAccepted = confirmedCount(publication.desired, verifiedQueue);
      final verified = verifiedQueue
          .where((p) => p.id == mapping.request.id)
          .toList();
      if (verified.length != 1 || !verified.single.matches(mapping.request)) {
        throw const ReminderFailure(ReminderFailureCode.publishFailed);
      }
      if (verifiedQueue.length > capacity) {
        await platform.cancel(mapping.request.id);
        await data.recordReminderCancelled(mapping.request.id);
        throw const ReminderFailure(ReminderFailureCode.publishFailed);
      }
      pending = verifiedQueue;
      accepted = confirmedCount(selected, pending);
      registeredThroughUtc = latestDueTime(pending);
      publishProgress();
      _diagnosticStep = DiagnosticNotificationStep.recording;
      await data.recordReminderAccepted(publication, mapping.request.id);
    }
    if (_live(generation)) {
      _diagnosticStep = DiagnosticNotificationStep.completed;
      final finishedComplete =
          complete && accepted == publication.desired.length;
      _publish(
        accepted: accepted,
        desired: publication.desired.length,
        complete: finishedComplete,
        through: publication.throughDay,
        registeredThroughUtc: registeredThroughUtc,
      );
      _log(
        DiagnosticEventName.reminderReconcileCompleted,
        finishedComplete
            ? DiagnosticOutcome.complete
            : DiagnosticOutcome.truncated,
        null,
        operation: DiagnosticNotificationOperation.reconcile,
      );
    }
  }

  int confirmedCount(
    List<ReminderMapping> selected,
    List<NotificationPending> pending,
  ) {
    var count = 0;
    for (final mapping in selected) {
      final matching = pending
          .where((item) => item.id == mapping.request.id)
          .toList();
      if (matching.length == 1 && matching.single.matches(mapping.request)) {
        count++;
      }
    }
    return count;
  }

  DateTime? latestDueTime(List<NotificationPending> pending) {
    DateTime? latest;
    for (final item in pending) {
      final due = item.deliveryAtUtc.toUtc();
      if (latest == null || due.isAfter(latest)) latest = due;
    }
    return latest;
  }

  Future<void> clearForMaintenance({bool nativeCleanupRequired = true}) async {
    _paused = true;
    _generation++;
    _waitingNavigation.clear();
    _cancelNavigationRetry();
    _timer?.cancel();
    _rollTimer?.cancel();
    _testRefillTimer?.cancel();
    await _work;
    if (!_initialized && !nativeCleanupRequired) {
      _publish(complete: true);
      return;
    }
    // Normal exit never comes here. Maintenance must cancel before dropping
    // persistent native identities, even if an earlier publish lost its ack.
    await _ensurePlatform();
    await platform.clearOwn();
    if ((await platform.pending()).isNotEmpty) {
      throw const ReminderFailure(ReminderFailureCode.cleanupPending);
    }
    _publish(complete: true);
  }

  /// Android's independent receiver must lose delivery authority durably before
  /// C3 commits a maintenance intent. This is outside the business transaction.
  Future<void> prepareForMaintenance() async {
    _paused = true;
    _generation++;
    _waitingNavigation.clear();
    _cancelNavigationRetry();
    _timer?.cancel();
    _rollTimer?.cancel();
    _testRefillTimer?.cancel();
    await _work;
    final control = platform;
    if (control is NotificationPublicationControlPort) {
      // Even a lost block acknowledgement may have touched an old mirror.
      // A later maintenance clear must not skip native cleanup merely because
      // this process has not previously initialized the notification UI.
      _initialized = true;
      await (control as NotificationPublicationControlPort).blockDelivery();
    }
  }

  Future<void> resumeAfterAbortedMaintenance() async {
    resumeAfterMaintenance();
    await refresh();
    if (_view.failure != null) throw ReminderFailure(_view.failure!);
  }

  /// Explicit user-operated OS check. It contains no business data and grants
  /// no navigable target. Its short-lived OS slot is refilled after it expires.
  Future<void> testNotification() async {
    if (_closed || _paused || _closing || _work != null) {
      throw const ReminderFailure(ReminderFailureCode.maintenance);
    }
    final done = Completer<void>();
    _work = done.future;
    var releasedSlot = false;
    var testRegistered = false;
    _diagnosticStep = DiagnosticNotificationStep.preparing;
    _diagnosticPending = null;
    _diagnosticDesired = null;
    _diagnosticAccepted = null;
    _log(
      DiagnosticEventName.reminderTestStarted,
      DiagnosticOutcome.started,
      null,
      operation: DiagnosticNotificationOperation.test,
    );
    try {
      if (!(await data.inspectReminders()).preferences.enabled) {
        throw const ReminderFailure(ReminderFailureCode.disabledBySystem);
      }
      _diagnosticStep = DiagnosticNotificationStep.permissions;
      await _ensurePlatform();
      final publication = await data.prepareReminderPublication();
      _diagnosticDesired = publication.desired.length;
      if (_paused || !await data.reminderPublicationCurrent(publication)) {
        throw const ReminderFailure(ReminderFailureCode.stale);
      }
      _diagnosticStep = DiagnosticNotificationStep.binding;
      await _bind(publication);
      if (_capability?.enabledBySystem != true) {
        throw const ReminderFailure(ReminderFailureCode.disabledBySystem);
      }
      _diagnosticStep = DiagnosticNotificationStep.readingQueue;
      await platform.cancel('m6-check');
      var pending = await platform.pending();
      _diagnosticPending = pending.length;
      _diagnosticAccepted = confirmedCount(publication.desired, pending);
      final capacity = (_capability?.maximumPending ?? 512)
          .clamp(1, 512)
          .toInt();
      if (pending.length >= capacity) {
        final known = {
          for (final mapping in publication.desired)
            mapping.request.id: mapping.request,
        };
        final candidates =
            pending
                .where(
                  (item) =>
                      known[item.id] != null &&
                      item.matches(known[item.id]!) &&
                      item.deliveryAtUtc.isAfter(
                        clock.nowUtc.add(const Duration(seconds: 15)),
                      ) &&
                      !publication.invalidPriorIds.contains(item.id),
                )
                .toList()
              ..sort(
                (left, right) =>
                    right.deliveryAtUtc.compareTo(left.deliveryAtUtc),
              );
        if (pending.length != capacity || candidates.isEmpty) {
          throw const ReminderFailure(ReminderFailureCode.capacityReached);
        }
        if (_paused ||
            _closing ||
            !await data.reminderPublicationCurrent(publication)) {
          throw const ReminderFailure(ReminderFailureCode.stale);
        }
        final victim = candidates.first;
        _diagnosticStep = DiagnosticNotificationStep.makingSpace;
        releasedSlot = true;
        await platform.cancel(victim.id);
        await data.recordReminderCancelled(victim.id);
        pending = await platform.pending();
        _diagnosticPending = pending.length;
        _diagnosticAccepted = confirmedCount(publication.desired, pending);
        if (pending.any((item) => item.id == victim.id) ||
            pending.length >= capacity) {
          throw const ReminderFailure(ReminderFailureCode.cancelFailed);
        }
      }
      if (_paused ||
          _closing ||
          !await data.reminderPublicationCurrent(publication)) {
        throw const ReminderFailure(ReminderFailureCode.stale);
      }
      final due = DateTime.fromMillisecondsSinceEpoch(
        clock.nowUtc.millisecondsSinceEpoch + 5000,
        isUtc: true,
      );
      final request = NotificationRequest(
        id: 'm6-check',
        deliveryAtUtc: due,
        digest: fingerprint(['notification-check', due.millisecondsSinceEpoch]),
        token: fingerprint([
          Random.secure().nextInt(0x7fffffff),
          due.microsecondsSinceEpoch,
        ]),
        title: 'USTC Assistant 测试提醒',
        detail: '这是一条系统通知测试，没有修改任何日程。',
        location: '',
      );
      _diagnosticStep = DiagnosticNotificationStep.registering;
      await platform.schedule(request);
      testRegistered = true;
      _diagnosticStep = DiagnosticNotificationStep.verifying;
      final verified = await platform.pending();
      _diagnosticPending = verified.length;
      _diagnosticAccepted = confirmedCount(publication.desired, verified);
      final matches = verified.where((p) => p.id == request.id).toList();
      if (matches.length != 1 || !matches.single.matches(request)) {
        throw const ReminderFailure(ReminderFailureCode.publishFailed);
      }
      if (!(await data.inspectReminders()).preferences.enabled ||
          _paused ||
          _closing ||
          !await data.reminderPublicationCurrent(publication)) {
        await platform.cancel(request.id);
        testRegistered = false;
        throw const ReminderFailure(ReminderFailureCode.stale);
      }
      _scheduleTestRefill(due);
      _again = true;
      _diagnosticStep = DiagnosticNotificationStep.completed;
      _log(
        DiagnosticEventName.reminderTestCompleted,
        DiagnosticOutcome.complete,
        null,
        operation: DiagnosticNotificationOperation.test,
      );
    } on Object catch (error) {
      _log(
        DiagnosticEventName.reminderTestFailed,
        DiagnosticOutcome.failure,
        error is ReminderFailure ? error.code.name : 'publishFailed',
        operation: DiagnosticNotificationOperation.test,
        failure: error is ReminderFailure ? error : null,
      );
      if (testRegistered) {
        try {
          await platform.cancel('m6-check');
          testRegistered = false;
        } on Object {
          _again = true;
        }
      }
      rethrow;
    } finally {
      _work = null;
      done.complete();
      if (releasedSlot && !testRegistered && !_paused && !_closing) {
        await refresh();
      } else if (_again) {
        _scheduleRefresh();
      }
    }
  }

  bool _activeTest(NotificationPending item) {
    final remaining = item.deliveryAtUtc.difference(clock.nowUtc);
    return item.id == 'm6-check' &&
        remaining > Duration.zero &&
        remaining <= const Duration(seconds: 15);
  }

  void _scheduleTestRefill(DateTime due) {
    _testRefillTimer?.cancel();
    final delay = due.add(const Duration(seconds: 1)).difference(clock.nowUtc);
    _testRefillTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      _testRefillTimer = null;
      unawaited(refresh());
    });
  }

  void resumeAfterMaintenance() {
    if (!_closed) {
      _closing = false;
      _paused = false;
      unawaited(_drainNavigation());
      _scheduleRefresh();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closing = true;
    _cancelNavigationRetry();
    _again = false;
    _timer?.cancel();
    _rollTimer?.cancel();
    _testRefillTimer?.cancel();
    await _work;
    _paused = true;
    _generation++;
    await _subscription?.cancel();
    await _activations?.cancel();
    await _activationFailures?.cancel();
    await _navigationWork;
    _waitingNavigation.clear();
    await platform.close();
    _closed = true;
    await _changes.close();
    await _navigation.close();
  }

  void _log(
    DiagnosticEventName event,
    DiagnosticOutcome outcome,
    String? code, {
    DiagnosticNotificationOperation? operation,
    ReminderFailure? failure,
  }) {
    try {
      diagnostics?.record(
        DiagnosticEvent(
          name: event,
          stage: DiagnosticStage.notifications,
          outcome: outcome,
          code: code == null ? null : diagnosticCode(code),
          notification: operation == null
              ? null
              : DiagnosticNotificationMetadata(
                  operation: operation,
                  step: _diagnosticStep,
                  desired: _diagnosticDesired,
                  accepted: _diagnosticAccepted,
                  pending: _diagnosticPending,
                  capacity: _capability?.maximumPending,
                  errorDomain: failure?.nativeFailure?.domain,
                  errorCode: failure?.nativeFailure?.code,
                ),
        ),
      );
    } catch (_) {
      /* Diagnostics never owns business availability. */
    }
  }
}
