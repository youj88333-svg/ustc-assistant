import '../core/contracts.dart';
import '../core/young_work_contract.dart';
import 'young_business_contract.dart';

/// Closed, value-free collection counters for the controlled job chain.
///
/// Constructing stats does not prove that a collection is complete. Only
/// [YoungCollectedArtifact.seal] performs that validation.
final class YoungCollectionStats {
  const YoungCollectionStats({
    required this.calendarRows,
    required this.events,
    required this.excludedSchedules,
    required this.duplicateSchedules,
    required this.days,
    required this.calendarPages,
    required this.activityPages,
    required this.activities,
  });

  final int calendarRows;
  final int events;
  final int excludedSchedules;
  final int duplicateSchedules;
  final int days;
  final int calendarPages;
  final int activityPages;
  final int activities;

  Map<String, Object> get safeProjection => Map<String, Object>.unmodifiable({
    'calendarRows': calendarRows,
    'events': events,
    'excludedSchedules': excludedSchedules,
    'duplicateSchedules': duplicateSchedules,
    'days': days,
    'calendarPages': calendarPages,
    'activityPages': activityPages,
    'activities': activities,
  });

  @override
  String toString() => 'YoungCollectionStats';
}

/// An immutable C1 handoff after identity and the complete fixed read have
/// been rechecked. It is data for C3 and does not grant a permit by itself.
final class YoungCollectedArtifact {
  YoungCollectedArtifact._({
    required String username,
    required this.stamp,
    required this.partition,
    required this.session,
    required this.document,
    required this.operation,
    required this.collectedAtUtc,
    required List<YoungActivity> activities,
    required List<YoungCalendarEntry> entries,
    required this.activityPages,
    required this.calendarPages,
    required this.calendarRows,
    required this.excludedSchedules,
    required this.days,
    required this.firstDay,
    required this.lastDay,
    required this.rangeStartUtc,
    required this.rangeEndUtc,
  }) : _username = username,
       activities = List<YoungActivity>.unmodifiable(activities),
       entries = List<YoungCalendarEntry>.unmodifiable(entries),
       stats = YoungCollectionStats(
         calendarRows: calendarRows,
         events: entries.length,
         excludedSchedules: excludedSchedules,
         duplicateSchedules: calendarRows - excludedSchedules - entries.length,
         days: days,
         calendarPages: calendarPages,
         activityPages: activityPages,
         activities: activities.length,
       ),
       contentFingerprint = _contentFingerprint(
         username: username,
         kind: stamp.kind,
         activities: activities,
         entries: entries,
         firstDay: firstDay,
         lastDay: lastDay,
       );

  /// Seals only a complete, single-kind collection with matching identity
  /// evidence, a valid source stamp, and a linked calendar projection.
  factory YoungCollectedArtifact.seal({
    required YoungProfileCandidate profileBefore,
    required YoungProfileCandidate profileAfter,
    required YoungWorkStamp stamp,
    required YoungPartitionRef partition,
    required int session,
    required int document,
    required int operation,
    required DateTime collectedAtUtc,
    required List<YoungActivity> activities,
    required List<YoungCalendarEntry> entries,
    required int activityPages,
    required int calendarPages,
    required int calendarRows,
    required int excludedSchedules,
    required int days,
    required DateTime? firstDay,
    required DateTime? lastDay,
  }) {
    final before = profileBefore.username;
    final after = profileAfter.username;
    if (!_validAccountText(before) || !_validAccountText(after)) {
      _invalidSnapshot();
    }
    if (before != after) {
      throw const YoungIdentityException(YoungIdentityFailure.evidenceConflict);
    }

    _validateMetadata(
      stamp: stamp,
      partition: partition,
      session: session,
      document: document,
      operation: operation,
      collectedAtUtc: collectedAtUtc,
    );

    final copiedActivities = List<YoungActivity>.of(activities);
    final copiedEntries = List<YoungCalendarEntry>.of(entries);
    DateTime? rangeStartUtc;
    DateTime? rangeEndUtc;

    switch (stamp.kind) {
      case YoungJobKind.activities:
        if (copiedEntries.isNotEmpty ||
            calendarPages != 0 ||
            calendarRows != 0 ||
            excludedSchedules != 0 ||
            days != 0 ||
            firstDay != null ||
            lastDay != null ||
            copiedActivities.length > 10000 ||
            activityPages != _requiredActivityPages(copiedActivities.length)) {
          _invalidSnapshot();
        }
        _validateActivities(copiedActivities);
        break;
      case YoungJobKind.calendar:
        if (copiedActivities.isNotEmpty || activityPages != 0) {
          _invalidSnapshot();
        }
        final range = _validateCalendarScope(firstDay, lastDay, days);
        final scopeStartUtc = range.$1;
        final scopeEndUtc = range.$2;
        rangeStartUtc = scopeStartUtc;
        rangeEndUtc = scopeEndUtc;
        _validateCalendarEntries(
          copiedEntries,
          rangeStartUtc: scopeStartUtc,
          rangeEndUtc: scopeEndUtc,
        );
        if (calendarRows < 0 ||
            calendarRows > 10000 ||
            excludedSchedules < 0 ||
            excludedSchedules > calendarRows ||
            calendarPages < days ||
            calendarPages > 10000 ||
            calendarRows < excludedSchedules + copiedEntries.length) {
          _invalidSnapshot();
        }
        break;
    }

    return YoungCollectedArtifact._(
      username: before,
      stamp: stamp,
      partition: partition,
      session: session,
      document: document,
      operation: operation,
      collectedAtUtc: collectedAtUtc,
      activities: copiedActivities,
      entries: copiedEntries,
      activityPages: activityPages,
      calendarPages: calendarPages,
      calendarRows: calendarRows,
      excludedSchedules: excludedSchedules,
      days: days,
      firstDay: firstDay,
      lastDay: lastDay,
      rangeStartUtc: rangeStartUtc,
      rangeEndUtc: rangeEndUtc,
    );
  }

  final String _username;
  final YoungWorkStamp stamp;
  final YoungPartitionRef partition;
  final int session;
  final int document;
  final int operation;
  final DateTime collectedAtUtc;
  final List<YoungActivity> activities;
  final List<YoungCalendarEntry> entries;
  final int activityPages;
  final int calendarPages;
  final int calendarRows;
  final int excludedSchedules;
  final int days;

  /// UTC-midnight components representing inclusive Beijing calendar dates.
  final DateTime? firstDay;

  /// UTC-midnight components representing inclusive Beijing calendar dates.
  final DateTime? lastDay;

  /// Inclusive first Beijing date's midnight, represented as a UTC instant.
  final DateTime? rangeStartUtc;

  /// Exclusive midnight after the last Beijing date, represented as UTC.
  final DateTime? rangeEndUtc;
  final YoungCollectionStats stats;
  final String contentFingerprint;

  String get sourceKey => stamp.kind.sourceKey;
  String get contractVersion => stamp.kind.contractVersion;

  /// Compares the private service account evidence to a C3-held expectation.
  bool matchesExpected(String expectedAccount) =>
      _validAccountText(expectedAccount) && _username == expectedAccount;

  @override
  String toString() => 'YoungCollectedArtifact';
}

void _validateMetadata({
  required YoungWorkStamp stamp,
  required YoungPartitionRef partition,
  required int session,
  required int document,
  required int operation,
  required DateTime collectedAtUtc,
}) {
  if (stamp.jobId.isEmpty ||
      stamp.jobId.length > 256 ||
      _hasControlCharacters(stamp.jobId) ||
      stamp.jobId != 'young-${stamp.resetEpoch}-${stamp.generation}' ||
      !_ownerPattern.hasMatch(stamp.ownerId) ||
      stamp.generation < 1 ||
      stamp.resetEpoch < 0 ||
      (stamp.accountId != null && stamp.accountId != 1) ||
      session < 1 ||
      document < 1 ||
      operation < 1 ||
      !collectedAtUtc.isUtc) {
    _invalidSnapshot();
  }

  try {
    final validated = YoungPartitionRef.decode(partition.metadata);
    if (!validated.sameAs(partition) ||
        partition.ownerId != stamp.ownerId ||
        partition.resetEpoch != stamp.resetEpoch) {
      _invalidSnapshot();
    }
  } on AppFailure {
    rethrow;
  } catch (_) {
    _invalidSnapshot();
  }
}

void _validateActivities(List<YoungActivity> activities) {
  final ids = <String>{};
  for (final activity in activities) {
    if (!_boundedText(activity.id, maximum: 256, allowEmpty: false) ||
        !_boundedText(activity.itemName, maximum: 2048, allowEmpty: false) ||
        !_utcInterval(activity.startsAtUtc, activity.endsAtUtc) ||
        !ids.add(activity.id)) {
      _invalidSnapshot();
    }
    final registrationStarts = activity.registrationStartsAtUtc;
    final registrationEnds = activity.registrationEndsAtUtc;
    if ((registrationStarts != null && !registrationStarts.isUtc) ||
        (registrationEnds != null && !registrationEnds.isUtc) ||
        (registrationStarts != null &&
            registrationEnds != null &&
            registrationEnds.isBefore(registrationStarts)) ||
        (activity.placeInfo != null &&
            !_boundedText(
              activity.placeInfo!,
              maximum: 2048,
              allowEmpty: true,
            ))) {
      _invalidSnapshot();
    }
  }
}

void _validateCalendarEntries(
  List<YoungCalendarEntry> entries, {
  required DateTime rangeStartUtc,
  required DateTime rangeEndUtc,
}) {
  final ids = <String>{};
  for (final entry in entries) {
    final itemId = entry.itemId;
    if (!_boundedText(entry.id, maximum: 256, allowEmpty: false) ||
        !_boundedText(entry.title, maximum: 2048, allowEmpty: false) ||
        !_boundedText(entry.place, maximum: 2048, allowEmpty: true) ||
        !_utcInterval(entry.startsAtUtc, entry.endsAtUtc) ||
        itemId == null ||
        !_boundedText(itemId, maximum: 256, allowEmpty: false) ||
        !ids.add(entry.id) ||
        !entry.startsAtUtc.isBefore(rangeEndUtc) ||
        !entry.endsAtUtc.isAfter(rangeStartUtc)) {
      _invalidSnapshot();
    }
  }
}

(DateTime, DateTime) _validateCalendarScope(
  DateTime? firstDay,
  DateTime? lastDay,
  int days,
) {
  if (firstDay == null ||
      lastDay == null ||
      !_isUtcMidnight(firstDay) ||
      !_isUtcMidnight(lastDay) ||
      lastDay.isBefore(firstDay)) {
    _invalidSnapshot();
  }
  final spanDays = lastDay.difference(firstDay).inDays + 1;
  if (spanDays < 1 || spanDays > 62 || days != spanDays) {
    _invalidSnapshot();
  }
  return (
    firstDay.subtract(const Duration(hours: 8)),
    lastDay.add(const Duration(days: 1)).subtract(const Duration(hours: 8)),
  );
}

int _requiredActivityPages(int count) => count == 0 ? 1 : (count + 9) ~/ 10;

bool _validAccountText(String value) =>
    value.length <= 64 &&
    value.trim().isNotEmpty &&
    !_hasControlCharacters(value) &&
    !value.runes.any(_isWhitespace);

bool _boundedText(
  String value, {
  required int maximum,
  required bool allowEmpty,
}) =>
    value.length <= maximum &&
    !_hasControlCharacters(value) &&
    (allowEmpty || value.trim().isNotEmpty);

bool _utcInterval(DateTime start, DateTime end) =>
    start.isUtc && end.isUtc && end.isAfter(start);

bool _isUtcMidnight(DateTime value) =>
    value.isUtc &&
    value.hour == 0 &&
    value.minute == 0 &&
    value.second == 0 &&
    value.millisecond == 0 &&
    value.microsecond == 0;

String _contentFingerprint({
  required String username,
  required YoungJobKind kind,
  required List<YoungActivity> activities,
  required List<YoungCalendarEntry> entries,
  required DateTime? firstDay,
  required DateTime? lastDay,
}) => fingerprint(<String, Object?>{
  'account': username,
  'kind': kind.name,
  'firstDay': firstDay?.toIso8601String(),
  'lastDay': lastDay?.toIso8601String(),
  'activities':
      activities
          .map(
            (activity) => <String, Object?>{
              'id': activity.id,
              'itemName': activity.itemName,
              'startsAtUtc': activity.startsAtUtc.toIso8601String(),
              'endsAtUtc': activity.endsAtUtc.toIso8601String(),
              'registrationStartsAtUtc': activity.registrationStartsAtUtc
                  ?.toIso8601String(),
              'registrationEndsAtUtc': activity.registrationEndsAtUtc
                  ?.toIso8601String(),
              'placeInfo': activity.placeInfo,
            },
          )
          .toList()
        ..sort(
          (left, right) =>
              (left['id']! as String).compareTo(right['id']! as String),
        ),
  'entries':
      entries
          .map(
            (entry) => <String, Object?>{
              'id': entry.id,
              'title': entry.title,
              'place': entry.place,
              'startsAtUtc': entry.startsAtUtc.toIso8601String(),
              'endsAtUtc': entry.endsAtUtc.toIso8601String(),
              'itemId': entry.itemId,
            },
          )
          .toList()
        ..sort(
          (left, right) =>
              (left['id']! as String).compareTo(right['id']! as String),
        ),
});

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

final RegExp _ownerPattern = RegExp(r'^jw-owner-[0-9a-f]{32}$');

Never _invalidSnapshot() => throw const AppFailure(FailureCode.invalidSnapshot);
