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
  });
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
  Timer? _timer, _rollTimer;
  ReminderPublication? _lastPublication;
  NotificationCapability? _capability;

  void _publish({
    bool busy = false,
    int accepted = 0,
    int desired = 0,
    bool complete = false,
    DateTime? through,
    ReminderFailureCode? failure,
  }) {
    _view = ReminderRuntimeView(
      busy: busy,
      accepted: accepted,
      desired: desired,
      complete: complete,
      throughDay: through,
      failure: failure,
      capability: _capability,
    );
    if (!_closed) _changes.add(_view);
  }

  void start() {
    if (_closed || _subscription != null) return;
    _subscription = data.changes.listen((_) => _scheduleRefresh());
    _activations = platform.activations.listen((activation) async {
      if (_closed || _paused) return;
      try {
        final target = await data.resolveNotification(activation);
        if (target != null && !_closed && !_paused) _navigation.add(target);
      } catch (_) {
        /* Untrusted/obsolete navigation never becomes a write. */
      }
    });
    final status = platform;
    if (status is NotificationActivationStatusPort) {
      _activationFailures = (status as NotificationActivationStatusPort)
          .activationFailures
          .listen((failure) {
            _publish(
              accepted: _view.accepted,
              desired: _view.desired,
              through: _view.throughDay,
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

  void onForeground() => _scheduleRefresh();

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
          );
          _log(
            DiagnosticEventName.reminderFailed,
            DiagnosticOutcome.failure,
            failure.name,
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
    _publish(busy: true);
    final publication = await data.prepareReminderPublication();
    if (!_live(generation)) return;
    _lastPublication = publication;
    if (!publication.enabled && publication.prior.isEmpty && !_initialized) {
      _publish(complete: true);
      return;
    }
    await _ensurePlatform();
    _log(
      DiagnosticEventName.reminderReconcileStarted,
      DiagnosticOutcome.started,
      null,
    );
    final actual = await platform.pending();
    final desired = {for (final m in publication.desired) m.request.id: m};
    final preserved = publication.prior.map((m) => m.request.id).toSet()
      ..removeAll(publication.invalidPriorIds);
    final remove = actual
        .where(
          (a) =>
              publication.invalidPriorIds.contains(a.id) ||
              !desired.containsKey(a.id) && !preserved.contains(a.id) ||
              desired.containsKey(a.id) && !a.matches(desired[a.id]!.request),
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
      await platform.cancel(id);
      await data.recordReminderCancelled(id);
    }
    if (!_live(generation) ||
        !await data.reminderPublicationCurrent(publication)) {
      _again = true;
      return;
    }
    var accepted = 0;
    final pending = await platform.pending();
    final retained = pending.where((a) => !desired.containsKey(a.id)).length;
    var complete = publication.complete;
    for (final mapping in publication.desired) {
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
        accepted++;
        continue;
      }
      if (_capability?.enabledBySystem != true) {
        throw const ReminderFailure(ReminderFailureCode.disabledBySystem);
      }
      if (accepted + retained >= 512) {
        complete = false;
        break;
      }
      await platform.schedule(mapping.request);
      if (!_live(generation) ||
          !await data.reminderPublicationCurrent(publication)) {
        await platform.cancel(mapping.request.id);
        await data.recordReminderCancelled(mapping.request.id);
        _again = true;
        break;
      }
      // Readback is the acceptance evidence, not merely method completion.
      final verified = (await platform.pending())
          .where((p) => p.id == mapping.request.id)
          .toList();
      if (verified.length != 1 || !verified.single.matches(mapping.request)) {
        throw const ReminderFailure(ReminderFailureCode.publishFailed);
      }
      await data.recordReminderAccepted(publication, mapping.request.id);
      accepted++;
    }
    if (_live(generation)) {
      _publish(
        accepted: accepted,
        desired: publication.desired.length,
        complete: complete && accepted == publication.desired.length,
        through: publication.throughDay,
      );
      _log(
        DiagnosticEventName.reminderReconcileCompleted,
        complete ? DiagnosticOutcome.complete : DiagnosticOutcome.truncated,
        null,
      );
    }
  }

  Future<void> clearForMaintenance({bool nativeCleanupRequired = true}) async {
    _paused = true;
    _generation++;
    _timer?.cancel();
    _rollTimer?.cancel();
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

  /// Explicit user-operated OS check. It contains no business data and grants
  /// no navigable target; ordinary reconciliation treats it as an orphan.
  Future<void> testNotification() async {
    if (_closed || _paused || _closing || _work != null) {
      throw const ReminderFailure(ReminderFailureCode.maintenance);
    }
    if (!(await data.inspectReminders()).preferences.enabled) {
      throw const ReminderFailure(ReminderFailureCode.disabledBySystem);
    }
    final done = Completer<void>();
    _work = done.future;
    try {
      await _ensurePlatform();
      if (_capability?.enabledBySystem != true) {
        throw const ReminderFailure(ReminderFailureCode.disabledBySystem);
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
      await platform.cancel(request.id);
      await platform.schedule(request);
      final matches = (await platform.pending())
          .where((p) => p.id == request.id)
          .toList();
      if (matches.length != 1 || !matches.single.matches(request)) {
        throw const ReminderFailure(ReminderFailureCode.publishFailed);
      }
      if (!(await data.inspectReminders()).preferences.enabled || _paused) {
        await platform.cancel(request.id);
      }
    } finally {
      _work = null;
      done.complete();
      if (_again) _scheduleRefresh();
    }
  }

  void resumeAfterMaintenance() {
    if (!_closed) {
      _closing = false;
      _paused = false;
      _scheduleRefresh();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closing = true;
    _again = false;
    _timer?.cancel();
    _rollTimer?.cancel();
    await _work;
    _paused = true;
    _generation++;
    await _subscription?.cancel();
    await _activations?.cancel();
    await _activationFailures?.cancel();
    await platform.close();
    _closed = true;
    await _changes.close();
    await _navigation.close();
  }

  void _log(
    DiagnosticEventName event,
    DiagnosticOutcome outcome,
    String? code,
  ) {
    try {
      diagnostics?.record(
        DiagnosticEvent(
          name: event,
          stage: DiagnosticStage.notifications,
          outcome: outcome,
          code: code == null ? null : diagnosticCode(code),
        ),
      );
    } catch (_) {
      /* Diagnostics never owns business availability. */
    }
  }
}
