import 'young_daily_sync_contract.dart';

final class YoungDailySyncDecision {
  const YoungDailySyncDecision({
    required this.firstDay,
    required this.endDayExclusive,
    required this.phase,
    required this.shouldRun,
    this.nextAttemptAtUtc,
  });

  /// UTC date components representing Beijing dates.
  final DateTime firstDay;
  final DateTime endDayExclusive;
  final YoungDailySyncPhase phase;
  final bool shouldRun;
  final DateTime? nextAttemptAtUtc;
}

const _beijingOffset = Duration(hours: 8);
const _oneDay = Duration(days: 1);

YoungDailySyncDecision planYoungDailySync(
  YoungDailySyncSnapshot snapshot,
  DateTime nowUtc, {
  bool manual = false,
}) {
  _requireUtc(nowUtc, 'nowUtc');
  _requireUtcIfPresent(snapshot.lastSuccessAtUtc, 'lastSuccessAtUtc');
  _requireUtcIfPresent(snapshot.successFirstDay, 'successFirstDay');
  _requireUtcIfPresent(
    snapshot.successEndDayExclusive,
    'successEndDayExclusive',
  );
  _requireUtcIfPresent(snapshot.attemptDay, 'attemptDay');
  _requireUtcIfPresent(snapshot.nextAttemptAtUtc, 'nextAttemptAtUtc');
  _requireUtcIfPresent(snapshot.suppressedDay, 'suppressedDay');

  final beijingNow = nowUtc.add(_beijingOffset);
  final today = DateTime.utc(beijingNow.year, beijingNow.month, beijingNow.day);
  final firstDay = today.subtract(_oneDay);
  final endDayExclusive = firstDay.add(const Duration(days: 31));
  final todayAtSixUtc = _sixBeijingUtc(today);
  final tomorrowAtSixUtc = _sixBeijingUtc(today.add(_oneDay));

  YoungDailySyncDecision decision(
    YoungDailySyncPhase phase, {
    required bool shouldRun,
    DateTime? nextAttemptAtUtc,
  }) => YoungDailySyncDecision(
    firstDay: firstDay,
    endDayExclusive: endDayExclusive,
    phase: phase,
    shouldRun: shouldRun,
    nextAttemptAtUtc: nextAttemptAtUtc,
  );

  if (!snapshot.enabled) {
    return decision(YoungDailySyncPhase.disabled, shouldRun: false);
  }
  if (snapshot.adviceOnly) {
    return decision(YoungDailySyncPhase.paused, shouldRun: false);
  }
  if (!snapshot.accountBound) {
    return decision(YoungDailySyncPhase.needsLogin, shouldRun: false);
  }

  // A manual request is explicit user intent. The visible school window owns
  // any login or challenge that follows; automatic gates do not block it.
  if (manual) {
    return decision(YoungDailySyncPhase.scheduled, shouldRun: true);
  }

  if (!snapshot.credentialSaved) {
    return decision(YoungDailySyncPhase.needsLogin, shouldRun: false);
  }
  if (nowUtc.isBefore(todayAtSixUtc)) {
    return decision(
      YoungDailySyncPhase.scheduled,
      shouldRun: false,
      nextAttemptAtUtc: todayAtSixUtc,
    );
  }
  if (_hasCurrentFullSuccess(snapshot, today, firstDay, endDayExclusive)) {
    return decision(
      YoungDailySyncPhase.done,
      shouldRun: false,
      nextAttemptAtUtc: tomorrowAtSixUtc,
    );
  }

  final attemptIsToday = _sameDate(snapshot.attemptDay, today);
  if (_sameDate(snapshot.suppressedDay, today)) {
    return decision(
      YoungDailySyncPhase.paused,
      shouldRun: false,
      nextAttemptAtUtc: tomorrowAtSixUtc,
    );
  }
  if (attemptIsToday && snapshot.needsLogin) {
    return decision(YoungDailySyncPhase.needsLogin, shouldRun: false);
  }
  if (attemptIsToday && snapshot.attempts >= 3) {
    return decision(
      YoungDailySyncPhase.failed,
      shouldRun: false,
      nextAttemptAtUtc: tomorrowAtSixUtc,
    );
  }
  final retryAt = snapshot.nextAttemptAtUtc;
  if (attemptIsToday && retryAt != null && retryAt.isAfter(nowUtc)) {
    return decision(
      YoungDailySyncPhase.failed,
      shouldRun: false,
      nextAttemptAtUtc: retryAt,
    );
  }

  return decision(YoungDailySyncPhase.scheduled, shouldRun: true);
}

bool _hasCurrentFullSuccess(
  YoungDailySyncSnapshot snapshot,
  DateTime today,
  DateTime firstDay,
  DateTime endDayExclusive,
) {
  final lastSuccessAtUtc = snapshot.lastSuccessAtUtc;
  final successFirstDay = snapshot.successFirstDay;
  final successEndDayExclusive = snapshot.successEndDayExclusive;
  if (lastSuccessAtUtc == null ||
      successFirstDay == null ||
      successEndDayExclusive == null) {
    return false;
  }

  final beijingSuccess = lastSuccessAtUtc.add(_beijingOffset);
  final successDay = DateTime.utc(
    beijingSuccess.year,
    beijingSuccess.month,
    beijingSuccess.day,
  );
  return successDay == today &&
      !_dateOnly(successFirstDay).isAfter(firstDay) &&
      !_dateOnly(successEndDayExclusive).isBefore(endDayExclusive);
}

bool _sameDate(DateTime? value, DateTime date) =>
    value != null && _dateOnly(value) == date;

DateTime _dateOnly(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);

DateTime _sixBeijingUtc(DateTime beijingDay) => DateTime.utc(
  beijingDay.year,
  beijingDay.month,
  beijingDay.day,
).subtract(const Duration(hours: 2));

void _requireUtcIfPresent(DateTime? value, String name) {
  if (value != null) _requireUtc(value, name);
}

void _requireUtc(DateTime value, String name) {
  if (!value.isUtc) {
    throw ArgumentError.value(value, name, 'must be UTC');
  }
}
