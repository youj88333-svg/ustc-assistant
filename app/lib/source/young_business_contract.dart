import '../core/contracts.dart';

/// A private C1 candidate parsed from the Young profile response.
///
/// The username is only a business field. This value is not proof of identity
/// and must not be used as a C3 account-binding permit.
final class YoungProfileCandidate {
  const YoungProfileCandidate._(this.username);

  final String username;

  @override
  String toString() => 'YoungProfileCandidate';
}

/// A validated activity record. Registration bounds are kept separate from
/// the activity interval.
final class YoungActivity {
  const YoungActivity._({
    required this.id,
    required this.itemName,
    required this.startsAtUtc,
    required this.endsAtUtc,
    required this.registrationStartsAtUtc,
    required this.registrationEndsAtUtc,
    required this.placeInfo,
  });

  final String id;
  final String itemName;
  final DateTime startsAtUtc;
  final DateTime endsAtUtc;
  final DateTime? registrationStartsAtUtc;
  final DateTime? registrationEndsAtUtc;
  final String? placeInfo;

  @override
  String toString() => 'YoungActivity';
}

/// A validated calendar record. A null itemId means only that the activity
/// association is absent; it does not establish registration status.
final class YoungCalendarEntry {
  const YoungCalendarEntry._({
    required this.id,
    required this.title,
    required this.place,
    required this.startsAtUtc,
    required this.endsAtUtc,
    required this.itemId,
  });

  final String id;
  final String title;
  final String place;
  final DateTime startsAtUtc;
  final DateTime endsAtUtc;
  final String? itemId;

  @override
  String toString() => 'YoungCalendarEntry';
}

/// One decoded server page. Only records and the total are retained; echoed
/// paging metadata and unknown fields are deliberately ignored.
final class YoungBusinessPage<T> {
  YoungBusinessPage._(List<T> records, this.total)
    : records = List<T>.unmodifiable(records);

  final List<T> records;
  final int total;

  @override
  String toString() => 'YoungBusinessPage';
}

YoungProfileCandidate decodeYoungProfile(Object? response) {
  final result = _successfulResult(response);
  final username = _boundedText(
    result['username'],
    maximum: 64,
    allowEmpty: false,
  );
  if (username.runes.any(_isWhitespace)) _invalidSnapshot();
  return YoungProfileCandidate._(username);
}

YoungBusinessPage<YoungActivity> decodeYoungActivityPage(Object? response) =>
    _decodePage<YoungActivity>(response, _decodeActivity);

YoungBusinessPage<YoungCalendarEntry> decodeYoungCalendarPage(
  Object? response,
) => _decodePage<YoungCalendarEntry>(response, _decodeCalendarEntry);

/// Accumulates the fixed ten-row pages for one query.
///
/// A result becomes visible only after every expected page has been accepted.
/// Any malformed response, transport failure, out-of-order page, or attempted
/// append after completion permanently invalidates this accumulator.
final class YoungPageAccumulator<T> {
  YoungPageAccumulator({
    required YoungBusinessPage<T> Function(Object? response) decodePage,
    required String Function(T record) idOf,
  }) : this._(decodePage, idOf);

  YoungPageAccumulator._(this._decodePage, this._idOf);

  static const int pageSize = 10;

  final YoungBusinessPage<T> Function(Object? response) _decodePage;
  final String Function(T record) _idOf;
  final List<T> _records = <T>[];
  final Set<String> _ids = <String>{};

  int? _total;
  int _nextPage = 1;
  List<T>? _completedRecords;
  bool _failed = false;

  bool get isComplete => !_failed && _completedRecords != null;
  bool get isFailed => _failed;

  /// Returns an immutable copy only after structural completeness is proven.
  ///
  /// An early read is a terminal contract failure so catching the exception
  /// cannot turn a partial query into a later complete result.
  List<T> get completedRecords {
    if (_failed) _invalidSnapshot();
    final completed = _completedRecords;
    if (completed == null) {
      _terminate();
      throw const AppFailure(FailureCode.incompleteSnapshot);
    }
    return completed;
  }

  void addResponse({required int requestedPage, required Object? response}) {
    if (_failed || _completedRecords != null) _abort();

    try {
      if (requestedPage != _nextPage || requestedPage < 1) _abort();

      final page = _decodePage(response);
      final knownTotal = _total;
      if (knownTotal != null && page.total != knownTotal) _abort();

      final total = knownTotal ?? page.total;
      if (_records.length > total) _abort();
      final remaining = total - _records.length;
      final expectedLength = remaining < pageSize ? remaining : pageSize;
      if (page.records.length != expectedLength) _abort();

      for (final record in page.records) {
        final id = _boundedText(_idOf(record), maximum: 256, allowEmpty: false);
        if (!_ids.add(id)) _abort();
        _records.add(record);
      }

      _total = total;
      _nextPage++;
      if (_records.length == total) {
        _completedRecords = List<T>.unmodifiable(_records);
        _records.clear();
        _ids.clear();
      }
    } on AppFailure {
      _terminate();
      rethrow;
    } catch (_) {
      _terminate();
      _invalidSnapshot();
    }
  }

  /// Marks an unsuccessful page request as terminal so later pages cannot
  /// salvage a partial or failed query.
  void fail() => _terminate();

  void _abort() {
    _terminate();
    _invalidSnapshot();
  }

  void _terminate() {
    _failed = true;
    _total = null;
    _completedRecords = null;
    _records.clear();
    _ids.clear();
  }
}

YoungBusinessPage<T> _decodePage<T>(
  Object? response,
  T Function(Object? value) decodeRecord,
) {
  final result = _successfulResult(response);
  final rawRecords = result['records'];
  final rawTotal = result['total'];
  if (rawRecords is! List ||
      rawTotal is! int ||
      rawTotal < 0 ||
      rawTotal > 10000 ||
      rawRecords.length > YoungPageAccumulator.pageSize) {
    _invalidSnapshot();
  }

  final records = <T>[];
  for (final value in rawRecords) {
    records.add(decodeRecord(value));
  }
  return YoungBusinessPage<T>._(records, rawTotal);
}

YoungActivity _decodeActivity(Object? value) {
  final record = _asMap(value);
  final id = _boundedText(record['id'], maximum: 256, allowEmpty: false);
  final itemName = _boundedText(
    record['itemName'],
    maximum: 2048,
    allowEmpty: false,
  );
  final startsAt = _parseBeijingTime(record['st']);
  final endsAt = _parseBeijingTime(record['et']);
  if (!endsAt.isAfter(startsAt)) _invalidSnapshot();

  final registrationStartsAt = _optionalBeijingTime(record, 'applySt');
  final registrationEndsAt = _optionalBeijingTime(record, 'applyEt');
  if (registrationStartsAt != null &&
      registrationEndsAt != null &&
      registrationEndsAt.isBefore(registrationStartsAt)) {
    _invalidSnapshot();
  }

  final placeInfo = _optionalText(
    record,
    'placeInfo',
    maximum: 2048,
    allowEmpty: true,
  );
  return YoungActivity._(
    id: id,
    itemName: itemName,
    startsAtUtc: startsAt,
    endsAtUtc: endsAt,
    registrationStartsAtUtc: registrationStartsAt,
    registrationEndsAtUtc: registrationEndsAt,
    placeInfo: placeInfo,
  );
}

YoungCalendarEntry _decodeCalendarEntry(Object? value) {
  final record = _asMap(value);
  final id = _boundedText(record['id'], maximum: 256, allowEmpty: false);
  final title = _boundedText(record['title'], maximum: 2048, allowEmpty: false);
  final place = _boundedText(record['place'], maximum: 2048, allowEmpty: true);
  final startsAt = _parseBeijingTime(record['startTime']);
  final endsAt = _parseBeijingTime(record['endTime']);
  if (!endsAt.isAfter(startsAt)) _invalidSnapshot();

  String? itemId;
  if (record.containsKey('itemId') && record['itemId'] != null) {
    final candidate = _boundedText(
      record['itemId'],
      maximum: 256,
      allowEmpty: true,
    );
    if (candidate.isNotEmpty) {
      if (candidate.trim().isEmpty) _invalidSnapshot();
      itemId = candidate;
    }
  }

  return YoungCalendarEntry._(
    id: id,
    title: title,
    place: place,
    startsAtUtc: startsAt,
    endsAtUtc: endsAt,
    itemId: itemId,
  );
}

Map<Object?, Object?> _successfulResult(Object? response) {
  final envelope = _asMap(response);
  final success = envelope['success'];
  final code = envelope['code'];
  if (success is! bool || !success || code is! num || code != 200) {
    _invalidSnapshot();
  }
  return _asMap(envelope['result']);
}

Map<Object?, Object?> _asMap(Object? value) {
  if (value is Map<Object?, Object?>) return value;
  _invalidSnapshot();
}

String? _optionalText(
  Map<Object?, Object?> record,
  String field, {
  required int maximum,
  required bool allowEmpty,
}) {
  if (!record.containsKey(field) || record[field] == null) return null;
  return _boundedText(record[field], maximum: maximum, allowEmpty: allowEmpty);
}

DateTime? _optionalBeijingTime(Map<Object?, Object?> record, String field) {
  if (!record.containsKey(field) || record[field] == null) return null;
  return _parseBeijingTime(record[field]);
}

String _boundedText(
  Object? value, {
  required int maximum,
  required bool allowEmpty,
}) {
  if (value is! String ||
      value.length > maximum ||
      _hasControlCharacters(value) ||
      (!allowEmpty && value.trim().isEmpty)) {
    _invalidSnapshot();
  }
  return value;
}

DateTime _parseBeijingTime(Object? value) {
  if (value is! String || _hasControlCharacters(value)) _invalidSnapshot();
  final match = _beijingDateTimePattern.firstMatch(value);
  if (match == null) _invalidSnapshot();

  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final hour = int.parse(match.group(4)!);
  final minute = int.parse(match.group(5)!);
  final second = int.parse(match.group(6)!);
  if (year < 1 ||
      year > 9999 ||
      month < 1 ||
      month > 12 ||
      day < 1 ||
      day > 31 ||
      hour > 23 ||
      minute > 59 ||
      second > 59) {
    _invalidSnapshot();
  }

  final calendarDate = DateTime.utc(year, month, day);
  if (calendarDate.year != year ||
      calendarDate.month != month ||
      calendarDate.day != day) {
    _invalidSnapshot();
  }

  // The input is wall time in Beijing (UTC+8); constructing UTC components
  // directly avoids parsing or inheriting the machine's local time zone.
  return DateTime.utc(year, month, day, hour - 8, minute, second);
}

bool _hasControlCharacters(String value) => value.runes.any(
  (int rune) => rune <= 0x1f || (rune >= 0x7f && rune <= 0x9f),
);

bool _isWhitespace(int rune) =>
    rune == 0x20 ||
    (rune >= 0x09 && rune <= 0x0d) ||
    rune == 0x85 ||
    rune == 0xa0 ||
    rune == 0x1680 ||
    (rune >= 0x2000 && rune <= 0x200a) ||
    rune == 0x2028 ||
    rune == 0x2029 ||
    rune == 0x202f ||
    rune == 0x205f ||
    rune == 0x3000;

final RegExp _beijingDateTimePattern = RegExp(
  r'^([0-9]{4})-([0-9]{2})-([0-9]{2}) ([0-9]{2}):([0-9]{2}):([0-9]{2})$',
);

Never _invalidSnapshot() => throw const AppFailure(FailureCode.invalidSnapshot);
