import 'public_query_contract.dart';

/// A bounded, date-normalized item for the daily notice brief.
///
/// Publication dates are calendar days, represented at UTC midnight. They are
/// not inferred instants and do not depend on the machine's local time zone.
final class MorningNotice {
  MorningNotice({
    required this.provider,
    required this.title,
    required this.articleUrl,
    required DateTime publishedDay,
    required DateTime observedAtUtc,
    this.excerpt = '',
  }) : publishedDay = _utcDay(publishedDay),
       observedAtUtc = observedAtUtc.toUtc();

  final PublicProvider provider;
  final String title;
  final Uri articleUrl;
  final DateTime publishedDay;
  final DateTime observedAtUtc;
  final String excerpt;
}

final class MorningNoticeCoverage {
  const MorningNoticeCoverage({
    required this.provider,
    required this.pages,
    required this.matched,
    required this.unknownDates,
    required this.complete,
    this.failure,
  });

  final PublicProvider provider;
  final int pages;
  final int matched;
  final int unknownDates;
  final bool complete;
  final PublicFailureCode? failure;
}

final class MorningNoticeBatch {
  MorningNoticeBatch({
    required DateTime day,
    required List<MorningNotice> notices,
    required List<MorningNoticeCoverage> coverage,
    required this.operations,
  }) : day = _utcDay(day),
       notices = List.unmodifiable(notices),
       coverage = List.unmodifiable(coverage);

  final DateTime day;
  final List<MorningNotice> notices;
  final List<MorningNoticeCoverage> coverage;

  /// Number of PublicQueryPort calls, not a count of underlying HTTP requests.
  final int operations;
}

DateTime _utcDay(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);

/// Parses only full, explicitly supplied publication dates.
///
/// Accepted values are YYYY-MM-DD, YYYY/MM/DD, YYYY年M月D日, and those same
/// dates followed by a complete 24-hour time. It never guesses a year or a
/// date from surrounding text.
DateTime? parseMorningPublishedDay(String? value) {
  if (value == null) return null;
  final source = value.trim();
  if (source.isEmpty) return null;

  final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})(.*)$').firstMatch(source);
  if (iso != null && _validDateTimeTail(iso.group(4)!)) {
    return _makeUtcDay(iso.group(1)!, iso.group(2)!, iso.group(3)!);
  }

  final slash = RegExp(r'^(\d{4})/(\d{2})/(\d{2})(.*)$').firstMatch(source);
  if (slash != null && _validDateTimeTail(slash.group(4)!)) {
    return _makeUtcDay(slash.group(1)!, slash.group(2)!, slash.group(3)!);
  }

  final chinese = RegExp(
    r'^(\d{4})年(\d{1,2})月(\d{1,2})日(.*)$',
  ).firstMatch(source);
  if (chinese != null && _validDateTimeTail(chinese.group(4)!)) {
    return _makeUtcDay(chinese.group(1)!, chinese.group(2)!, chinese.group(3)!);
  }

  return null;
}

bool _validDateTimeTail(String tail) {
  if (tail.isEmpty) return true;
  return RegExp(
    r'^[ T](?:[01]\d|2[0-3]):[0-5]\d'
    r'(?::[0-5]\d(?:\.\d{1,9})?)?'
    r'(?:Z|[+-](?:0\d|1[0-3]):?[0-5]\d|[+-]14:?00)?$',
    caseSensitive: false,
  ).hasMatch(tail);
}

DateTime? _makeUtcDay(String yearText, String monthText, String dayText) {
  final year = int.tryParse(yearText);
  final month = int.tryParse(monthText);
  final day = int.tryParse(dayText);
  if (year == null || month == null || day == null || year < 1) return null;

  final result = DateTime.utc(year, month, day);
  if (result.year != year || result.month != month || result.day != day) {
    return null;
  }
  return result;
}
