import 'contracts.dart';

enum YoungDailySyncPhase {
  disabled,
  scheduled,
  waitingForIdle,
  syncing,
  needsLogin,
  done,
  failed,
  paused,
  closed,
}

enum YoungDailySyncOutcome { failed, needsLogin, interrupted, deferred }

/// Local authority only; never an Agent argument or a diagnostic payload.
final class YoungDailySyncContext {
  const YoungDailySyncContext({
    required this.owner,
    required this.resetEpoch,
    required this.agendaEpoch,
    required this.revision,
  });
  final String owner;
  final int resetEpoch, agendaEpoch, revision;
  @override
  bool operator ==(Object other) =>
      other is YoungDailySyncContext &&
      owner == other.owner &&
      resetEpoch == other.resetEpoch &&
      agendaEpoch == other.agendaEpoch &&
      revision == other.revision;
  @override
  int get hashCode => Object.hash(owner, resetEpoch, agendaEpoch, revision);
  @override
  String toString() => 'YoungDailySyncContext';
}

final class YoungDailySyncSnapshot {
  const YoungDailySyncSnapshot({
    required this.context,
    this.enabled = false,
    this.accountBound = false,
    this.credentialSaved = false,
    this.adviceOnly = false,
    this.lastSuccessAtUtc,
    this.successFirstDay,
    this.successEndDayExclusive,
    this.attemptDay,
    this.attempts = 0,
    this.nextAttemptAtUtc,
    this.needsLogin = false,
    this.suppressedDay,
  });
  final YoungDailySyncContext context;
  final bool enabled, accountBound, credentialSaved, adviceOnly, needsLogin;
  final DateTime? lastSuccessAtUtc;
  // UTC date components representing Beijing dates.
  final DateTime? successFirstDay, successEndDayExclusive, attemptDay;
  final DateTime? nextAttemptAtUtc, suppressedDay;
  final int attempts;
}

/// Issued only by C3. Implementations reject unissued or superseded instances.
abstract class YoungDailySyncGrant {
  YoungDailySyncContext get context;
  DateTime get firstDay;
  DateTime get endDayExclusive;
}

abstract interface class YoungDailySyncDataPort {
  Stream<int> get changes;

  /// Restriction is immediate, including when a database write is in flight.
  void restrictToAdvice(bool restricted);
  Future<YoungDailySyncSnapshot> inspect();
  Future<YoungDailySyncSnapshot> setEnabled(
    YoungDailySyncContext context,
    bool enabled,
  );
  Future<YoungDailySyncGrant?> claim({bool manual = false});
  Future<void> finish(YoungDailySyncGrant grant, YoungDailySyncOutcome outcome);
}

final class YoungDailySyncView {
  const YoungDailySyncView({
    this.enabled = false,
    this.phase = YoungDailySyncPhase.disabled,
    this.lastSuccessAtUtc,
    this.firstDay,
    this.endDayExclusive,
    this.nextAttemptAtUtc,
    this.attempts = 0,
    this.failure,
    this.adviceOnly = false,
    this.configured = false,
    this.suppressedToday = false,
    this.interactive = false,
  });
  final bool enabled, adviceOnly, configured, suppressedToday, interactive;
  final YoungDailySyncPhase phase;
  final DateTime? lastSuccessAtUtc, firstDay, endDayExclusive, nextAttemptAtUtc;
  final int attempts;
  final FailureCode? failure;
  bool get busy => phase == YoungDailySyncPhase.syncing || interactive;
}

/// A user-owned setting; no model, arbitrary URL or periodic OS job is exposed.
abstract interface class YoungDailySyncControlPort {
  YoungDailySyncView get view;
  Stream<YoungDailySyncView> get changes;
  Future<void> setEnabled(bool enabled);
  Future<void> syncNow();
  Future<void> continueAfterLogin();
  Future<void> cancel();
}
