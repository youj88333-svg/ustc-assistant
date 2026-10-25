import 'dart:collection';

import '../core/agenda_contract.dart';
import '../core/calendar_contract.dart';
import '../core/contracts.dart';
import '../core/reminder_contract.dart';
import 'calendar_projection.dart';

/// Pure, bounded projection of C3 calendar and task state into reminder
/// candidates. It never publishes notifications or changes persistent state.
final class ReminderProjection {
  const ReminderProjection();

  static const int _planningDays = 180;
  static const int _maxCandidates = 512;
  static const int _maxQueryDays = 62;
  static const int _maxQueryItems = 500;
  static const int _maxRuleOffsetDays = 7;
  static const int _dayMilliseconds = 24 * 60 * 60 * 1000;
  static const Duration _beijingOffset = Duration(hours: 8);
  static const CalendarProjection _calendar = CalendarProjection();

  /// Projects reminder fire times in [nowUtc, nowUtc + 180 days), retaining
  /// the nearest 512 known candidates. The query extends by seven local days
  /// on each side because a rule may fire up to seven days from its object.
  ReminderProjectionResult project(ReminderInput input, DateTime nowUtc) {
    if (!nowUtc.isUtc) {
      throw const ReminderFailure(ReminderFailureCode.invalidInput);
    }
    final nowMs = nowUtc.millisecondsSinceEpoch;
    final horizonEndMs = nowMs + _planningDays * _dayMilliseconds;
    final horizonEnd = DateTime.fromMillisecondsSinceEpoch(
      horizonEndMs,
      isUtc: true,
    );
    final throughHorizon = _beijingDay(
      DateTime.fromMillisecondsSinceEpoch(horizonEndMs - 1, isUtc: true),
    );
    if (!input.preferences.enabled) {
      return ReminderProjectionResult(
        items: const [],
        complete: true,
        throughDay: throughHorizon,
        candidateCount: 0,
      );
    }

    final overrides = _indexOverrides(input.overrides);
    final collector = _CandidateCollector();
    final firstFutureFireDay = _beijingDay(nowUtc);
    final firstScheduleDay = firstFutureFireDay.subtract(
      const Duration(days: _maxRuleOffsetDays),
    );
    final endScheduleDay = _beijingDay(
      horizonEnd,
    ).add(const Duration(days: _maxRuleOffsetDays + 1));

    void collectOccurrence(CalendarOccurrence occurrence) {
      _collectOccurrence(
        input,
        overrides,
        occurrence,
        collector,
        nowMs,
        horizonEndMs,
      );
    }

    var cursor = firstScheduleDay;
    while (cursor.isBefore(endScheduleDay)) {
      final remainingDays = endScheduleDay.difference(cursor).inDays;
      final chunkDays = remainingDays < _maxQueryDays
          ? remainingDays
          : _maxQueryDays;
      final end = cursor.add(Duration(days: chunkDays));
      _readCalendarRange(
        input,
        cursor,
        end,
        firstFutureFireDay,
        collectOccurrence,
        collector,
      );
      cursor = end;
    }

    final seenDeadlineIds = <int>{};
    for (final deadline in input.deadlines) {
      if (deadline.reference.context != input.snapshot.context ||
          deadline.reference.localId < 1 ||
          deadline.reference.version < 1 ||
          !deadline.deadlineAtUtc.isUtc ||
          !seenDeadlineIds.add(deadline.reference.localId)) {
        throw const ReminderFailure(ReminderFailureCode.invalidInput);
      }
      _collectDeadline(
        input,
        overrides,
        deadline,
        collector,
        nowMs,
        horizonEndMs,
      );
    }

    final earliestUnknown = collector.earliestUnknownFireDay;
    final earliestOmitted = collector.earliestOmittedFireAt;
    var throughDay = throughHorizon;
    if (earliestUnknown != null) {
      final lastKnownDay = earliestUnknown.subtract(const Duration(days: 1));
      if (lastKnownDay.isBefore(throughDay)) throughDay = lastKnownDay;
    }
    if (earliestOmitted != null) {
      final lastKnownDay = _beijingDay(
        earliestOmitted,
      ).subtract(const Duration(days: 1));
      if (lastKnownDay.isBefore(throughDay)) throughDay = lastKnownDay;
    }

    return ReminderProjectionResult(
      items: collector.items,
      complete:
          collector.earliestUnknownFireDay == null &&
          collector.candidateCount <= _maxCandidates,
      throughDay: throughDay,
      candidateCount: collector.candidateCount,
    );
  }

  /// Re-resolves one persisted target against the current snapshot. The old
  /// version is deliberately ignored after context and identity match: this
  /// is a read for publication reconciliation, not an authorization to write.
  List<ReminderCandidate> resolve(ReminderInput input, ReminderTarget target) {
    if (target.context != input.snapshot.context) {
      throw const ReminderFailure(ReminderFailureCode.stale);
    }
    if (target.localId < 1 ||
        target.version < 1 ||
        !input.preferences.enabled) {
      return const [];
    }

    final overrides = _indexOverrides(input.overrides);
    if (target.kind == ReminderKind.taskDeadline) {
      if (target.ordinal != 0) {
        throw const ReminderFailure(ReminderFailureCode.invalidInput);
      }
      final matches = input.deadlines
          .where((value) => value.reference.localId == target.localId)
          .toList();
      if (matches.length > 1) {
        throw const ReminderFailure(ReminderFailureCode.invalidInput);
      }
      if (matches.isEmpty) return const [];
      final deadline = matches.single;
      if (deadline.reference.context != input.snapshot.context ||
          deadline.reference.version < 1 ||
          !deadline.deadlineAtUtc.isUtc) {
        throw const ReminderFailure(ReminderFailureCode.invalidInput);
      }
      return _deadlineCandidates(input, overrides, deadline);
    }

    final kind = _calendarKind(target.kind);
    if (target.ordinal < 0 ||
        target.ordinal > 521700 ||
        (kind != CalendarKind.personal && target.ordinal != 0)) {
      throw const ReminderFailure(ReminderFailureCode.invalidInput);
    }
    final identity = CalendarIdentity(
      kind,
      target.localId,
      ordinal: target.ordinal,
    );
    final occurrence = _calendar.occurrence(input.snapshot, identity);
    if (occurrence == null) return const [];
    return _occurrenceCandidates(input, overrides, occurrence);
  }

  void _readCalendarRange(
    ReminderInput input,
    DateTime firstDay,
    DateTime endDayExclusive,
    DateTime firstFutureFireDay,
    void Function(CalendarOccurrence) collect,
    _CandidateCollector collector,
  ) {
    final dayCount = endDayExclusive.difference(firstDay).inDays;
    late final CalendarWindow window;
    try {
      window = _calendar.query(
        input.snapshot,
        CalendarQuery(
          firstDay: firstDay,
          endDayExclusive: endDayExclusive,
          includeHidden: false,
          includeSkipped: false,
          limit: _maxQueryItems,
        ),
      );
    } on CalendarFailure catch (failure) {
      if (failure.code != CalendarFailureCode.limitExceeded) rethrow;
      if (dayCount > 1) {
        _splitAndRead(
          input,
          firstDay,
          endDayExclusive,
          firstFutureFireDay,
          collect,
          collector,
        );
      } else {
        collector.markUnknownFireDay(
          _firstPossibleMissingFireDay(firstDay, firstFutureFireDay),
        );
      }
      return;
    }

    if (window.truncated) {
      if (dayCount > 1) {
        _splitAndRead(
          input,
          firstDay,
          endDayExclusive,
          firstFutureFireDay,
          collect,
          collector,
        );
      } else {
        for (final occurrence in window.items) {
          collect(occurrence);
        }
        collector.markUnknownFireDay(
          _firstPossibleMissingFireDay(firstDay, firstFutureFireDay),
        );
      }
      return;
    }
    for (final occurrence in window.items) {
      collect(occurrence);
    }
  }

  void _splitAndRead(
    ReminderInput input,
    DateTime firstDay,
    DateTime endDayExclusive,
    DateTime firstFutureFireDay,
    void Function(CalendarOccurrence) collect,
    _CandidateCollector collector,
  ) {
    final days = endDayExclusive.difference(firstDay).inDays;
    final leftDays = days ~/ 2;
    final middle = firstDay.add(Duration(days: leftDays));
    _readCalendarRange(
      input,
      firstDay,
      middle,
      firstFutureFireDay,
      collect,
      collector,
    );
    _readCalendarRange(
      input,
      middle,
      endDayExclusive,
      firstFutureFireDay,
      collect,
      collector,
    );
  }

  DateTime _firstPossibleMissingFireDay(
    DateTime scheduleDay,
    DateTime firstFutureFireDay,
  ) {
    final possible = scheduleDay.subtract(
      const Duration(days: _maxRuleOffsetDays),
    );
    return possible.isBefore(firstFutureFireDay)
        ? firstFutureFireDay
        : possible;
  }

  void _collectOccurrence(
    ReminderInput input,
    Map<_OverrideKey, ReminderPair> overrides,
    CalendarOccurrence occurrence,
    _CandidateCollector collector,
    int nowMs,
    int horizonEndMs,
  ) {
    for (final candidate in _occurrenceCandidates(
      input,
      overrides,
      occurrence,
    )) {
      final fireMs = candidate.fireAtUtc.millisecondsSinceEpoch;
      if (fireMs > nowMs && fireMs < horizonEndMs) collector.add(candidate);
    }
  }

  List<ReminderCandidate> _occurrenceCandidates(
    ReminderInput input,
    Map<_OverrideKey, ReminderPair> overrides,
    CalendarOccurrence occurrence,
  ) {
    final identity = occurrence.reference.identity;
    final kind = ReminderKind.values.byName(identity.kind.name);
    if (!_eligibleOccurrence(occurrence)) return const [];
    if (occurrence.reference.context != input.snapshot.context) {
      throw const ReminderFailure(ReminderFailureCode.invalidInput);
    }
    final target = ReminderTarget.calendar(occurrence.reference);
    final pair = _pairFor(
      input.preferences,
      overrides,
      kind,
      identity.localId,
      identity.ordinal,
      occurrence.allDay,
    );
    return _buildCandidates(
      target: target,
      kind: kind,
      pair: pair,
      allDay: occurrence.allDay,
      startsAtUtc: occurrence.startsAtUtc,
      displayTitle: occurrence.title,
      location: occurrence.location,
      privateDisplay: input.preferences.privateDisplay,
    );
  }

  void _collectDeadline(
    ReminderInput input,
    Map<_OverrideKey, ReminderPair> overrides,
    ReminderDeadline deadline,
    _CandidateCollector collector,
    int nowMs,
    int horizonEndMs,
  ) {
    for (final candidate in _deadlineCandidates(input, overrides, deadline)) {
      final fireMs = candidate.fireAtUtc.millisecondsSinceEpoch;
      if (fireMs > nowMs && fireMs < horizonEndMs) collector.add(candidate);
    }
  }

  List<ReminderCandidate> _deadlineCandidates(
    ReminderInput input,
    Map<_OverrideKey, ReminderPair> overrides,
    ReminderDeadline deadline,
  ) {
    if (deadline.reference.context != input.snapshot.context ||
        deadline.reference.localId < 1 ||
        deadline.reference.version < 1 ||
        !deadline.deadlineAtUtc.isUtc ||
        (deadline.status != TaskStatus.active &&
            deadline.status != TaskStatus.blocked)) {
      return const [];
    }
    final target = ReminderTarget.task(deadline.reference);
    final pair = _pairFor(
      input.preferences,
      overrides,
      ReminderKind.taskDeadline,
      deadline.reference.localId,
      0,
      false,
    );
    return _buildCandidates(
      target: target,
      kind: ReminderKind.taskDeadline,
      pair: pair,
      allDay: false,
      startsAtUtc: deadline.deadlineAtUtc,
      displayTitle: deadline.title,
      location: '',
      privateDisplay: input.preferences.privateDisplay,
    );
  }

  bool _eligibleOccurrence(CalendarOccurrence occurrence) {
    if (occurrence.sourceRetired) return false;
    final kind = occurrence.reference.identity.kind;
    if (kind == CalendarKind.planBlock) {
      // A block's own planning status is authoritative. Parent task status is
      // independent and must not suppress an otherwise planned block.
      return occurrence.planBlockStatus == PlanBlockStatus.planned;
    }
    return !occurrence.hidden &&
        !occurrence.skipped &&
        !occurrence.completed &&
        occurrence.attendance != AttendanceDecision.skip;
  }

  Map<_OverrideKey, ReminderPair> _indexOverrides(
    List<ReminderOverride> values,
  ) {
    final result = <_OverrideKey, ReminderPair>{};
    for (final value in values) {
      if (value.localId < 1 ||
          value.ordinal < -1 ||
          value.ordinal > 521700 ||
          (value.ordinal == -1 && value.kind != ReminderKind.personal) ||
          (value.kind != ReminderKind.personal && value.ordinal != 0)) {
        throw const ReminderFailure(ReminderFailureCode.invalidInput);
      }
      final key = (value.kind, value.localId, value.ordinal);
      if (result.containsKey(key)) {
        throw const ReminderFailure(ReminderFailureCode.invalidInput);
      }
      result[key] = value.pair;
    }
    return result;
  }

  ReminderPair _pairFor(
    ReminderPreferences preferences,
    Map<_OverrideKey, ReminderPair> overrides,
    ReminderKind kind,
    int localId,
    int ordinal,
    bool allDay,
  ) {
    var pair = overrides[(kind, localId, ordinal)];
    if (pair == null && kind == ReminderKind.personal) {
      pair = overrides[(kind, localId, -1)];
    }
    if (pair != null && !pair.supports(allDay: allDay)) pair = null;
    pair ??= allDay ? preferences.allDay : preferences.timed;
    pair.validate(allDay: allDay);
    return pair;
  }

  List<ReminderCandidate> _buildCandidates({
    required ReminderTarget target,
    required ReminderKind kind,
    required ReminderPair pair,
    required bool allDay,
    required DateTime startsAtUtc,
    required String displayTitle,
    required String location,
    required bool privateDisplay,
  }) {
    if (!startsAtUtc.isUtc) {
      throw const ReminderFailure(ReminderFailureCode.invalidInput);
    }
    pair.validate(allDay: allDay);
    final title = privateDisplay
        ? _privateTitle(kind)
        : _safeText(displayTitle, 160, fallback: _privateTitle(kind));
    final detail = _safeText(
      _detail(kind, allDay, startsAtUtc),
      240,
      fallback: _privateTitle(kind),
    );
    final safeLocation = privateDisplay ? '' : _safeText(location, 160);
    final seenFireTimes = <int>{};
    final result = <ReminderCandidate>[];
    final rules = [pair.first, pair.second];
    for (var slot = 0; slot < rules.length; slot++) {
      final rule = rules[slot];
      if (rule.kind == ReminderRuleKind.none) continue;
      final fireAt = _ruleFireAt(startsAtUtc, rule);
      final fireMs = fireAt.millisecondsSinceEpoch;
      // Equal slots collapse to the lower (first) slot before key creation.
      if (!seenFireTimes.add(fireMs)) continue;
      final normalizedFireAt = DateTime.fromMillisecondsSinceEpoch(
        fireMs,
        isUtc: true,
      );
      final logicalKey = fingerprint([
        target.context.owner,
        target.context.resetEpoch,
        target.context.agendaEpoch,
        target.kind.name,
        target.localId,
        target.ordinal,
        slot,
      ]);
      final digest = fingerprint([title, detail, safeLocation, fireMs]);
      result.add(
        ReminderCandidate(
          logicalKey: logicalKey,
          target: target,
          slot: slot,
          fireAtUtc: normalizedFireAt,
          digest: digest,
          title: title,
          detail: detail,
          location: safeLocation,
        ),
      );
    }
    return result;
  }

  DateTime _ruleFireAt(DateTime startsAtUtc, ReminderRule rule) {
    return switch (rule.kind) {
      ReminderRuleKind.none => startsAtUtc,
      ReminderRuleKind.before => startsAtUtc.toUtc().subtract(
        Duration(minutes: rule.minutesBefore),
      ),
      ReminderRuleKind.dayTime => _allDayFireAt(startsAtUtc, rule),
    };
  }

  DateTime _allDayFireAt(DateTime startsAtUtc, ReminderRule rule) {
    final beijingStart = startsAtUtc.toUtc().add(_beijingOffset);
    final localDate = DateTime.utc(
      beijingStart.year,
      beijingStart.month,
      beijingStart.day,
    ).add(Duration(days: rule.dayOffset, minutes: rule.minuteOfDay));
    return localDate.subtract(_beijingOffset);
  }

  String _detail(ReminderKind kind, bool allDay, DateTime startsAtUtc) {
    final label = switch (kind) {
      ReminderKind.course => '课程',
      ReminderKind.exam => '考试',
      ReminderKind.young => '二课',
      ReminderKind.personal => '个人日程',
      ReminderKind.planBlock => '计划时间块',
      ReminderKind.taskDeadline => '截止时间',
    };
    if (kind == ReminderKind.taskDeadline) {
      return '$label · ${formatBeijing(startsAtUtc)}';
    }
    if (allDay) {
      return '$label · 全天 ${formatBeijing(startsAtUtc).substring(0, 10)}';
    }
    return '$label · ${formatBeijing(startsAtUtc)}';
  }

  String _privateTitle(ReminderKind kind) =>
      kind == ReminderKind.taskDeadline ? '任务截止提醒' : '日程提醒';

  CalendarKind _calendarKind(ReminderKind kind) => switch (kind) {
    ReminderKind.course => CalendarKind.course,
    ReminderKind.exam => CalendarKind.exam,
    ReminderKind.young => CalendarKind.young,
    ReminderKind.personal => CalendarKind.personal,
    ReminderKind.planBlock => CalendarKind.planBlock,
    ReminderKind.taskDeadline => throw const ReminderFailure(
      ReminderFailureCode.invalidInput,
    ),
  };

  String _safeText(String value, int maxCodeUnits, {String fallback = ''}) {
    final normalized = value
        .replaceAll(RegExp(r'[\u0000-\u001F\u007F-\u009F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final buffer = StringBuffer();
    var usedCodeUnits = 0;
    for (final rune in normalized.runes) {
      final units = rune > 0xFFFF ? 2 : 1;
      if (usedCodeUnits + units > maxCodeUnits) break;
      buffer.writeCharCode(rune);
      usedCodeUnits += units;
    }
    final safe = buffer.toString();
    return safe.isEmpty ? fallback : safe;
  }

  DateTime _beijingDay(DateTime instant) => beijingDay(instant);
}

typedef _OverrideKey = (ReminderKind, int, int);

final class _CandidateCollector {
  final Set<String> _seenLogicalKeys = {};
  final SplayTreeMap<_CandidateOrder, ReminderCandidate> _nearest =
      SplayTreeMap<_CandidateOrder, ReminderCandidate>(_compareCandidateOrder);
  DateTime? earliestUnknownFireDay;
  DateTime? earliestOmittedFireAt;
  int candidateCount = 0;

  List<ReminderCandidate> get items => List.unmodifiable(_nearest.values);

  void markUnknownFireDay(DateTime firstPossibleFireDay) {
    final day = DateTime.utc(
      firstPossibleFireDay.year,
      firstPossibleFireDay.month,
      firstPossibleFireDay.day,
    );
    final current = earliestUnknownFireDay;
    if (current == null || day.isBefore(current)) {
      earliestUnknownFireDay = day;
    }
  }

  void add(ReminderCandidate candidate) {
    if (!_seenLogicalKeys.add(candidate.logicalKey)) return;
    candidateCount++;
    final order = _CandidateOrder(candidate.fireAtUtc, candidate.logicalKey);
    if (_nearest.length < ReminderProjection._maxCandidates) {
      _nearest[order] = candidate;
      return;
    }
    final lastOrder = _nearest.keys.last;
    if (_compareCandidateOrder(order, lastOrder) < 0) {
      final omitted = _nearest.remove(lastOrder)!;
      _markOmitted(omitted.fireAtUtc);
      _nearest[order] = candidate;
    } else {
      _markOmitted(candidate.fireAtUtc);
    }
  }

  void _markOmitted(DateTime fireAtUtc) {
    final current = earliestOmittedFireAt;
    if (current == null || fireAtUtc.isBefore(current)) {
      earliestOmittedFireAt = fireAtUtc;
    }
  }
}

final class _CandidateOrder {
  const _CandidateOrder(this.fireAtUtc, this.logicalKey);
  final DateTime fireAtUtc;
  final String logicalKey;
}

int _compareCandidateOrder(_CandidateOrder left, _CandidateOrder right) {
  final time = left.fireAtUtc.compareTo(right.fireAtUtc);
  return time != 0 ? time : left.logicalKey.compareTo(right.logicalKey);
}
