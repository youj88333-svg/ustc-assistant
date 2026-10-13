import '../core/calendar_contract.dart';
import '../core/calendar_validation.dart';

/// A half-open daily interval, expressed as minutes after Beijing midnight.
///
/// The service validates the bounds at run time so malformed model/tool input
/// produces a rejected result instead of relying on debug-only assertions.
final class AgentFreeMinuteRange {
  const AgentFreeMinuteRange(this.startMinute, this.endMinute);

  final int startMinute;
  final int endMinute;
}

/// Availability repeated on one ISO weekday (Monday is 1, Sunday is 7).
final class AgentFreeWeekdayAvailability {
  AgentFreeWeekdayAvailability({
    required this.weekday,
    required List<AgentFreeMinuteRange> intervals,
  }) : intervals = List<AgentFreeMinuteRange>.unmodifiable(intervals);

  final int weekday;
  final List<AgentFreeMinuteRange> intervals;
}

/// Bounded conditions for deterministic free-slot enumeration.
///
/// [firstDay] and [endDayExclusive] are UTC date-only values whose date
/// components denote Beijing calendar days. Availability repeats by weekday.
/// Daily ranges are half-open and must fit in 0..1440. The requested range is
/// required to match the supplied [CalendarWindow] exactly.
final class AgentFreeSlotConditions {
  AgentFreeSlotConditions({
    required this.firstDay,
    required this.endDayExclusive,
    required List<AgentFreeWeekdayAvailability> availability,
    required this.blockMinutes,
    this.maxCandidates = 20,
    this.breakMinutes = 0,
    this.includeHidden = false,
    this.includeSkipped = false,
    this.deadlineUtc,
  }) : availability = List<AgentFreeWeekdayAvailability>.unmodifiable(
         availability,
       );

  final DateTime firstDay;
  final DateTime endDayExclusive;
  final List<AgentFreeWeekdayAvailability> availability;
  final int blockMinutes;
  final int maxCandidates;
  final int breakMinutes;
  final bool includeHidden;
  final bool includeSkipped;
  final DateTime? deadlineUtc;
}

enum AgentFreeSlotsStatus { complete, limited, rejected }

final class AgentFreeSlotCandidate {
  const AgentFreeSlotCandidate({
    required this.startsAtUtc,
    required this.endsAtUtc,
  });

  final DateTime startsAtUtc;
  final DateTime endsAtUtc;
}

/// Result metadata distinguishes a complete empty answer from an incomplete
/// calendar window and from a candidate list stopped at its configured cap.
final class AgentFreeSlotsResult {
  AgentFreeSlotsResult({
    required this.status,
    required List<AgentFreeSlotCandidate> candidates,
    required this.actualFirstDay,
    required this.actualEndDayExclusive,
    required this.actualFilter,
    required this.includeHidden,
    required this.includeSkipped,
    required this.queryIncludedHidden,
    required this.queryIncludedSkipped,
    required this.windowComplete,
    required this.windowTruncated,
    required this.conflictsTruncated,
    required this.candidatesTruncated,
    required List<String> notices,
  }) : candidates = List<AgentFreeSlotCandidate>.unmodifiable(candidates),
       notices = List<String>.unmodifiable(notices);

  final AgentFreeSlotsStatus status;
  final List<AgentFreeSlotCandidate> candidates;
  final DateTime actualFirstDay;
  final DateTime actualEndDayExclusive;
  final CalendarFilter actualFilter;
  final bool includeHidden;
  final bool includeSkipped;
  final bool queryIncludedHidden;
  final bool queryIncludedSkipped;
  final bool windowComplete;
  final bool windowTruncated;
  final bool conflictsTruncated;
  final bool candidatesTruncated;
  final List<String> notices;
}

/// Enumerates earliest-first, non-overlapping candidate blocks from one
/// complete calendar projection. It performs no reads or writes itself.
AgentFreeSlotsResult findAgentFreeSlots(
  CalendarWindow window,
  AgentFreeSlotConditions conditions,
) {
  final query = window.query;
  final base = _resultBase(window, conditions);

  final invalidCondition = _invalidConditions(conditions);
  if (invalidCondition != null) {
    return _result(
      base,
      status: AgentFreeSlotsStatus.rejected,
      windowComplete: false,
      notices: [invalidCondition],
    );
  }

  if (!isCalendarDate(query.firstDay) ||
      !isCalendarDate(query.endDayExclusive) ||
      query.limit < 1 ||
      query.limit > 500 ||
      window.matched < 0) {
    return _result(
      base,
      status: AgentFreeSlotsStatus.rejected,
      windowComplete: false,
      notices: const ['日程窗口结构无效，未生成候选。'],
    );
  }

  final datesMatch =
      query.firstDay == conditions.firstDay &&
      query.endDayExclusive == conditions.endDayExclusive;
  if (!datesMatch ||
      query.filter != CalendarFilter.all ||
      (conditions.includeHidden && !query.includeHidden) ||
      (conditions.includeSkipped && !query.includeSkipped)) {
    return _result(
      base,
      status: AgentFreeSlotsStatus.rejected,
      windowComplete: false,
      notices: const ['日程窗口与规划范围或过滤条件不一致，未生成候选。'],
    );
  }

  if (window.truncated) {
    return _result(
      base,
      status: AgentFreeSlotsStatus.limited,
      windowComplete: false,
      windowTruncated: true,
      notices: const ['日程窗口已截断，不能确认完整空闲时段；未生成候选。'],
    );
  }
  if (window.matched != window.items.length) {
    return _result(
      base,
      status: AgentFreeSlotsStatus.rejected,
      windowComplete: false,
      notices: const ['日程窗口计数不一致，未生成候选。'],
    );
  }

  final timedItems = <_BusyInterval>[];
  final windowStartUtc = _beijingMidnight(query.firstDay);
  final windowEndUtc = _beijingMidnight(query.endDayExclusive);
  for (final item in window.items) {
    if (item.allDay) continue;
    if (!item.startsAtUtc.isUtc ||
        !item.endsAtUtc.isUtc ||
        !item.endsAtUtc.isAfter(item.startsAtUtc) ||
        !item.startsAtUtc.isBefore(windowEndUtc) ||
        !item.endsAtUtc.isAfter(windowStartUtc)) {
      return _result(
        base,
        status: AgentFreeSlotsStatus.rejected,
        windowComplete: false,
        notices: const ['日程窗口含无效定时记录，未生成候选。'],
      );
    }
    if ((!conditions.includeHidden && item.hidden) ||
        (!conditions.includeSkipped && item.skipped)) {
      continue;
    }
    // Presence and relation decisions intentionally do not affect occupancy:
    // missing source rows remain scheduled, and notConflict is not free time.
    timedItems.add(_BusyInterval(item.startsAtUtc, item.endsAtUtc));
  }

  final busy = _mergeBusyIntervals(timedItems);
  final intervalsByWeekday = _normalizeAvailability(conditions.availability);
  final candidates = <AgentFreeSlotCandidate>[];
  DateTime? earliestNextStartUtc;
  var candidatesTruncated = false;

  outer:
  for (
    var day = conditions.firstDay;
    day.isBefore(conditions.endDayExclusive);
    day = day.add(const Duration(days: 1))
  ) {
    final dayStartUtc = _beijingMidnight(day);
    final ranges = intervalsByWeekday[day.weekday] ?? const [];
    for (final range in ranges) {
      var candidateMinute = range.startMinute;
      final earliest = earliestNextStartUtc;
      if (earliest != null) {
        final minute = _ceilMinuteAfter(dayStartUtc, earliest);
        if (minute > candidateMinute) candidateMinute = minute;
      }

      while (candidateMinute + conditions.blockMinutes <= range.endMinute) {
        final startsAtUtc = dayStartUtc.add(Duration(minutes: candidateMinute));
        final endsAtUtc = startsAtUtc.add(
          Duration(minutes: conditions.blockMinutes),
        );
        final deadline = conditions.deadlineUtc;
        if (deadline != null && endsAtUtc.isAfter(deadline)) break;

        DateTime? lastOverlappingBusyEnd;
        for (final occupied in busy) {
          if (!occupied.startsAtUtc.isBefore(endsAtUtc)) break;
          if (occupied.endsAtUtc.isAfter(startsAtUtc)) {
            lastOverlappingBusyEnd = occupied.endsAtUtc;
          }
        }
        if (lastOverlappingBusyEnd != null) {
          final nextMinute = _ceilMinuteAfter(
            dayStartUtc,
            lastOverlappingBusyEnd,
          );
          candidateMinute = nextMinute > candidateMinute
              ? nextMinute
              : candidateMinute + 1;
          continue;
        }

        if (candidates.length == conditions.maxCandidates) {
          candidatesTruncated = true;
          break outer;
        }
        candidates.add(
          AgentFreeSlotCandidate(
            startsAtUtc: startsAtUtc,
            endsAtUtc: endsAtUtc,
          ),
        );
        final nextStartUtc = endsAtUtc.add(
          Duration(minutes: conditions.breakMinutes),
        );
        earliestNextStartUtc = nextStartUtc;
        candidateMinute = _ceilMinuteAfter(dayStartUtc, nextStartUtc);
      }
    }
  }

  final notices = <String>[
    '候选按北京时间日期和可用区间升序枚举；日程缺失标记仍占用，全天不占定时区间，显式“不冲突”不释放时间。',
    if (window.conflictsTruncated) '冲突关系明细已截断；空闲判断仍基于完整日程项。',
    if (candidatesTruncated) '候选已达到上限，结果为稳定顺序前缀，仍有更多候选。',
    if (!candidatesTruncated && candidates.isEmpty) '窗口完整，但没有满足条件的候选。',
    if (!candidatesTruncated && candidates.isNotEmpty)
      '候选采用最早可行时间的确定性贪心顺序，不代表全局最优。',
  ];
  return _result(
    base,
    status: candidatesTruncated
        ? AgentFreeSlotsStatus.limited
        : AgentFreeSlotsStatus.complete,
    candidates: candidates,
    windowComplete: true,
    candidatesTruncated: candidatesTruncated,
    notices: notices,
  );
}

AgentFreeSlotsResult _resultBase(
  CalendarWindow window,
  AgentFreeSlotConditions conditions,
) => AgentFreeSlotsResult(
  status: AgentFreeSlotsStatus.rejected,
  candidates: const [],
  actualFirstDay: window.query.firstDay,
  actualEndDayExclusive: window.query.endDayExclusive,
  actualFilter: window.query.filter,
  includeHidden: conditions.includeHidden,
  includeSkipped: conditions.includeSkipped,
  queryIncludedHidden: window.query.includeHidden,
  queryIncludedSkipped: window.query.includeSkipped,
  windowComplete: false,
  windowTruncated: window.truncated,
  conflictsTruncated: window.conflictsTruncated,
  candidatesTruncated: false,
  notices: const [],
);

AgentFreeSlotsResult _result(
  AgentFreeSlotsResult base, {
  required AgentFreeSlotsStatus status,
  required bool windowComplete,
  List<AgentFreeSlotCandidate> candidates = const [],
  bool windowTruncated = false,
  bool candidatesTruncated = false,
  required List<String> notices,
}) => AgentFreeSlotsResult(
  status: status,
  candidates: candidates,
  actualFirstDay: base.actualFirstDay,
  actualEndDayExclusive: base.actualEndDayExclusive,
  actualFilter: base.actualFilter,
  includeHidden: base.includeHidden,
  includeSkipped: base.includeSkipped,
  queryIncludedHidden: base.queryIncludedHidden,
  queryIncludedSkipped: base.queryIncludedSkipped,
  windowComplete: windowComplete,
  windowTruncated: windowTruncated || base.windowTruncated,
  conflictsTruncated: base.conflictsTruncated,
  candidatesTruncated: candidatesTruncated,
  notices: notices,
);

String? _invalidConditions(AgentFreeSlotConditions conditions) {
  if (!isCalendarDate(conditions.firstDay) ||
      !isCalendarDate(conditions.endDayExclusive)) {
    return '规划日期必须是 UTC 北京日期。';
  }
  final dayCount = conditions.endDayExclusive
      .difference(conditions.firstDay)
      .inDays;
  if (dayCount < 1 || dayCount > 31) {
    return '规划日期范围必须为 1 至 31 天。';
  }
  if (conditions.blockMinutes < 1 || conditions.blockMinutes > 1440) {
    return '单块时长必须为 1 至 1440 分钟。';
  }
  if (conditions.maxCandidates < 1 || conditions.maxCandidates > 20) {
    return '候选上限必须为 1 至 20。';
  }
  if (conditions.breakMinutes < 0 || conditions.breakMinutes > 1440) {
    return '休息间隔必须为 0 至 1440 分钟。';
  }
  if (conditions.deadlineUtc != null &&
      (!conditions.deadlineUtc!.isUtc ||
          conditions.deadlineUtc!.year < 1 ||
          conditions.deadlineUtc!.year > 9998)) {
    return '截止时间必须是有效 UTC 时间。';
  }
  if (conditions.availability.length > 7) {
    return '每周可用时段最多包含七个星期定义。';
  }
  final weekdays = <int>{};
  for (final day in conditions.availability) {
    if (day.weekday < DateTime.monday ||
        day.weekday > DateTime.sunday ||
        !weekdays.add(day.weekday)) {
      return '星期定义无效或重复。';
    }
    if (day.intervals.length > 24) {
      return '每日可用区间最多为 24 段。';
    }
    for (final range in day.intervals) {
      if (range.startMinute < 0 ||
          range.endMinute > 1440 ||
          range.startMinute >= range.endMinute) {
        return '可用区间必须满足 0 ≤ 开始分钟 < 结束分钟 ≤ 1440。';
      }
    }
  }
  return null;
}

Map<int, List<AgentFreeMinuteRange>> _normalizeAvailability(
  List<AgentFreeWeekdayAvailability> availability,
) {
  final result = <int, List<AgentFreeMinuteRange>>{};
  for (final day in availability) {
    final sorted = day.intervals.toList()
      ..sort((left, right) {
        final start = left.startMinute.compareTo(right.startMinute);
        return start != 0 ? start : left.endMinute.compareTo(right.endMinute);
      });
    final merged = <AgentFreeMinuteRange>[];
    for (final range in sorted) {
      if (merged.isEmpty || range.startMinute > merged.last.endMinute) {
        merged.add(range);
      } else if (range.endMinute > merged.last.endMinute) {
        merged[merged.length - 1] = AgentFreeMinuteRange(
          merged.last.startMinute,
          range.endMinute,
        );
      }
    }
    result[day.weekday] = List<AgentFreeMinuteRange>.unmodifiable(merged);
  }
  return result;
}

List<_BusyInterval> _mergeBusyIntervals(List<_BusyInterval> intervals) {
  final sorted = intervals.toList()
    ..sort((left, right) {
      final start = left.startsAtUtc.compareTo(right.startsAtUtc);
      return start != 0 ? start : left.endsAtUtc.compareTo(right.endsAtUtc);
    });
  final merged = <_BusyInterval>[];
  for (final interval in sorted) {
    if (merged.isEmpty || interval.startsAtUtc.isAfter(merged.last.endsAtUtc)) {
      merged.add(interval);
    } else if (interval.endsAtUtc.isAfter(merged.last.endsAtUtc)) {
      merged[merged.length - 1] = _BusyInterval(
        merged.last.startsAtUtc,
        interval.endsAtUtc,
      );
    }
  }
  return merged;
}

int _ceilMinuteAfter(DateTime dayStartUtc, DateTime instantUtc) {
  final micros = instantUtc.difference(dayStartUtc).inMicroseconds;
  if (micros <= 0) return 0;
  return (micros + Duration.microsecondsPerMinute - 1) ~/
      Duration.microsecondsPerMinute;
}

DateTime _beijingMidnight(DateTime day) => DateTime.utc(
  day.year,
  day.month,
  day.day,
).subtract(const Duration(hours: 8));

final class _BusyInterval {
  const _BusyInterval(this.startsAtUtc, this.endsAtUtc);

  final DateTime startsAtUtc;
  final DateTime endsAtUtc;
}
