import 'recurrence_rule.dart';

class RecurrenceLimitError implements Exception {
  const RecurrenceLimitError(this.message);

  final String message;

  @override
  String toString() => 'RecurrenceLimitError: $message';
}

List<DateTime> expandRecurrence(
  RecurrenceRule rule, {
  required DateTime from,
  required DateTime through,
  int maxDays = 366,
  int maxOccurrences = 1000,
}) {
  if (through.isBefore(from)) {
    throw const RecurrenceLimitError('through must not precede from');
  }
  final inclusiveDays = dateOnly(through).difference(dateOnly(from)).inDays + 1;
  if (inclusiveDays > maxDays) {
    throw const RecurrenceLimitError('query exceeds day limit');
  }
  final values = switch (rule.frequency) {
    RecurrenceFrequency.daily => _expandDaily(rule, from, through),
    RecurrenceFrequency.weekly => _expandWeekly(rule, from, through),
    RecurrenceFrequency.monthly => _expandMonthly(rule, from, through),
  };
  if (values.length > maxOccurrences) {
    throw const RecurrenceLimitError('query exceeds occurrence limit');
  }
  return List.unmodifiable(values);
}

List<DateTime> _expandDaily(
  RecurrenceRule rule,
  DateTime from,
  DateTime through,
) {
  final result = <DateTime>[];
  for (
    var value = rule.anchor;
    !value.isAfter(through) && _withinUntil(rule, value);
    value = value.add(Duration(days: rule.interval))
  ) {
    if (!value.isBefore(from)) result.add(value);
  }
  return result;
}

List<DateTime> _expandWeekly(
  RecurrenceRule rule,
  DateTime from,
  DateTime through,
) {
  final result = <DateTime>[];
  final anchorDate = dateOnly(rule.anchor);
  final anchorMonday = anchorDate.subtract(
    Duration(days: anchorDate.weekday - DateTime.monday),
  );
  for (
    var day = dateOnly(from);
    !day.isAfter(dateOnly(through));
    day = day.add(const Duration(days: 1))
  ) {
    if (day.isBefore(anchorDate) || !rule.weekdays.contains(day.weekday)) {
      continue;
    }
    final week = day.difference(anchorMonday).inDays ~/ 7;
    if (week % rule.interval != 0) continue;
    final value = DateTime(
      day.year,
      day.month,
      day.day,
      rule.anchor.hour,
      rule.anchor.minute,
      rule.anchor.second,
    );
    if (!value.isBefore(from) &&
        !value.isAfter(through) &&
        _withinUntil(rule, value)) {
      result.add(value);
    }
  }
  return result;
}

List<DateTime> _expandMonthly(
  RecurrenceRule rule,
  DateTime from,
  DateTime through,
) {
  final result = <DateTime>[];
  for (var index = 0; ; index++) {
    final monthIndex =
        rule.anchor.year * 12 + rule.anchor.month - 1 + index * rule.interval;
    final year = monthIndex ~/ 12;
    final month = monthIndex % 12 + 1;
    final lastDay = DateTime(year, month + 1, 0).day;
    final value = DateTime(
      year,
      month,
      rule.anchor.day.clamp(1, lastDay),
      rule.anchor.hour,
      rule.anchor.minute,
      rule.anchor.second,
    );
    if (value.isAfter(through) || !_withinUntil(rule, value)) break;
    if (!value.isBefore(from)) result.add(value);
  }
  return result;
}

bool _withinUntil(RecurrenceRule rule, DateTime value) =>
    rule.untilDate == null || !dateOnly(value).isAfter(rule.untilDate!);

String occurrenceKey(String seriesId, DateTime originalStart) =>
    '$seriesId@${localDateTimeText(originalStart)}';

DateTime originalStartFromOccurrenceKey(String seriesId, String key) {
  final prefix = '$seriesId@';
  if (!key.startsWith(prefix)) {
    throw const FormatException('occurrence key does not belong to series');
  }
  return DateTime.parse(key.substring(prefix.length));
}
