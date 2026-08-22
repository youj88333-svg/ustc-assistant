// Field-for-field Dart port of `src/ustc_assistant/sources/jw/source_bundle.py`
// `_build_course_data` (the SourceBundle 1.0 path — NOT the legacy
// `course.convert`). Produces course series, course-occurrence events and
// course source records whose field shapes match the Python oracle exactly.
//
// See `docs/plan-webview-minimal-m2.md` §7 (field-shape appendix).

import 'dart:collection';
import 'dart:convert';

import '_jw_identity.dart';

/// Row fields that are allowed to differ within a merged schedule group
/// (teacher/person identity). Mirrors `source_bundle._PARTICIPANT_ROW_FIELDS`.
const Set<String> _participantRowFields = {
  'teacherId',
  'personId',
  'personName',
};

/// Result of building course data: the three collections the bundle builder
/// merges with exam data.
class JwCourseData {
  JwCourseData({
    required this.series,
    required this.calendarEvents,
    required this.sourceRecords,
  });

  /// Course series, one per lesson (in `lessonList` order).
  final List<Map<String, Object?>> series;

  /// Course-occurrence events, one per merged schedule group (in merge order).
  final List<Map<String, Object?>> calendarEvents;

  /// Course source records: series records then occurrence records.
  final List<Map<String, Object?>> sourceRecords;
}

/// Port of `course.build_maps` (course.py:97-100): maps keyed by int id,
/// preserving `lessonList`/`scheduleGroupList` insertion order.
LinkedHashMap<int, Map<String, dynamic>> buildLessonMap(
  Map<String, dynamic> result,
) {
  final map = <int, Map<String, dynamic>>{};
  for (final item in result['lessonList'] as List) {
    final entry = item as Map<String, dynamic>;
    map[sourceInteger(entry['id'], 'course datum contains invalid lesson identifiers')] =
        entry;
  }
  return LinkedHashMap.from(map);
}

LinkedHashMap<int, Map<String, dynamic>> buildGroupMap(
  Map<String, dynamic> result,
) {
  final map = <int, Map<String, dynamic>>{};
  for (final item in result['scheduleGroupList'] as List) {
    final entry = item as Map<String, dynamic>;
    map[sourceInteger(
      entry['id'],
      'course datum contains invalid schedule group identifiers',
    )] = entry;
  }
  return LinkedHashMap.from(map);
}

/// Port of `course.group_schedule_rows` (course.py:103-107): group rows by
/// `merge_key`, preserving first-seen order (OrderedDict semantics).
List<List<Map<String, dynamic>>> groupScheduleRows(List<dynamic> rows) {
  final grouped =
      <_MergeKey, List<Map<String, dynamic>>>{};
  for (final raw in rows) {
    final row = raw as Map<String, dynamic>;
    final key = _mergeKey(row);
    (grouped[key] ??= <Map<String, dynamic>>[]).add(row);
  }
  return grouped.values.toList(growable: false);
}

class _MergeKey {
  _MergeKey(
    this.lessonId,
    this.scheduleGroupId,
    this.date,
    this.startTime,
    this.endTime,
    this.placeKey,
    this.exerciseKey,
  );

  final Object? lessonId;
  final Object? scheduleGroupId;
  final Object? date;
  final Object? startTime;
  final Object? endTime;
  final String placeKey;
  final String exerciseKey;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _MergeKey &&
          lessonId == other.lessonId &&
          scheduleGroupId == other.scheduleGroupId &&
          date == other.date &&
          startTime == other.startTime &&
          endTime == other.endTime &&
          placeKey == other.placeKey &&
          exerciseKey == other.exerciseKey;

  @override
  int get hashCode => Object.hash(
        lessonId,
        scheduleGroupId,
        date,
        startTime,
        endTime,
        placeKey,
        exerciseKey,
      );
}

/// Port of `course.merge_key` (course.py:85-94). The participant-independent
/// fields used to merge rows that share a time/place/exercise slot.
_MergeKey _mergeKey(Map<String, dynamic> row) {
  return _MergeKey(
    row['lessonId'],
    row['scheduleGroupId'],
    row['date'],
    row['startTime'],
    row['endTime'],
    placeKey(row),
    exerciseKey(row),
  );
}

/// Port of `course.room_code` (course.py:40-42).
String? _roomCode(Map<String, dynamic> row) {
  final room = row['room'];
  if (room is Map<String, dynamic>) {
    return room['code'] as String?;
  }
  return null;
}

/// Port of `course.place_key` (course.py:51-70). Used both to merge rows and
/// to build the collision discriminator (externalId tail), so the JSON it
/// emits must be byte-identical to the Python output.
String placeKey(Map<String, dynamic> row) {
  final code = _roomCode(row);
  if (code != null && code.isNotEmpty) {
    return code;
  }
  final room = row['room'];
  if (room is Map<String, dynamic>) {
    final building = (room['building'] as Map<String, dynamic>?) ??
        <String, dynamic>{};
    final campus =
        (building['campus'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final locationParts = <String>[
      normalizedIdentityText(room['nameZh']),
      normalizedIdentityText(building['nameZh']),
      normalizedIdentityText(campus['nameZh']),
    ];
    if (locationParts.any((part) => part.isNotEmpty)) {
      // json.dumps(["room", *parts], ensure_ascii=False, separators=(",",":"))
      return _compactJson(['room', ...locationParts], sortKeys: false);
    }
  }
  final customPlace = row['customPlace'];
  if (customPlace is String && customPlace.isNotEmpty) {
    return customPlace;
  }
  return 'unknown-place';
}

/// Port of `course.exercise_key` (course.py:73-82): None/False/"" → "none";
/// otherwise `json.dumps(value, ensure_ascii=False, sort_keys=True,
/// separators=(",",":"))`. Dict keys are sorted; list order is preserved.
String exerciseKey(Map<String, dynamic> row) {
  final value = row['exerciseClass'];
  if (value == null || identical(value, false) || value == '') {
    return 'none';
  }
  return _compactJson(value, sortKeys: true);
}

/// Compact JSON encoder matching `json.dumps(..., ensure_ascii=False,
/// separators=(",",":"))` (and `sort_keys=True` when requested). Dart's
/// `jsonEncode` is already compact and passes non-ASCII through; for dicts we
/// must first emit a key-sorted map so the output is deterministic.
String _compactJson(Object? value, {required bool sortKeys}) {
  Object? normalize(Object? current) {
    if (current is Map) {
      final keys = current.keys.map((k) => k.toString()).toList();
      if (sortKeys) keys.sort();
      return <String, dynamic>{
        for (final key in keys) key: normalize(current[key]),
      };
    }
    if (current is List) {
      return current.map(normalize).toList(growable: false);
    }
    return current;
  }

  return jsonEncode(normalize(value));
}

/// Port of `course.room_parts` (course.py:132-146). Returns
/// `(name, building, campus, virtual)` — `name` is `room.nameZh or room.code`.
List<Object?> roomParts(Map<String, dynamic> row) {
  final room = row['room'];
  if (room is Map<String, dynamic>) {
    final building =
        (room['building'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final campus =
        (building['campus'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final nameZh = room['nameZh'] as String?;
    final name = (nameZh != null && nameZh.isNotEmpty)
        ? nameZh
        : room['code'] as String?;
    return [name, building['nameZh'], campus['nameZh'], room['virtual']];
  }
  final customPlace = row['customPlace'];
  if (customPlace is String && customPlace.isNotEmpty) {
    return [customPlace, null, null, null];
  }
  return [null, null, null, null];
}

/// Port of `course.unique_participants` (course.py:110-129). Deduplicates by
/// `(teacherId, personId, name)` while preserving order.
List<Map<String, Object?>> uniqueParticipants(List<Map<String, dynamic>> rows) {
  final seen = <_ParticipantKey>{};
  final participants = <Map<String, Object?>>[];
  for (final row in rows) {
    final name = row['personName'];
    if (name == null) continue;
    final key = _ParticipantKey(row['teacherId'], row['personId'], name.toString());
    if (seen.contains(key)) continue;
    seen.add(key);
    participants.add(<String, Object?>{
      'role': 'teacher',
      'name': name,
      'teacherId': row['teacherId'],
      'personId': row['personId'],
    });
  }
  return participants;
}

class _ParticipantKey {
  _ParticipantKey(this.teacherId, this.personId, this.name);

  final Object? teacherId;
  final Object? personId;
  final String name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ParticipantKey &&
          teacherId == other.teacherId &&
          personId == other.personId &&
          name == other.name;

  @override
  int get hashCode => Object.hash(teacherId, personId, name);
}

/// Port of `source_bundle._public_participants` (source_bundle.py:29-40):
/// project `unique_participants` to public `(role, name)` pairs, dedup by
/// `(role, name)`.
List<Map<String, String>> publicParticipants(List<Map<String, dynamic>> rows) {
  final participants = <Map<String, String>>[];
  final seen = <String>{};
  for (final participant in uniqueParticipants(rows)) {
    final name = participant['name']!.toString();
    final publicKey = 'teacher\u0000$name';
    if (seen.contains(publicKey)) continue;
    seen.add(publicKey);
    participants.add(<String, String>{'role': 'teacher', 'name': name});
  }
  return participants;
}

/// Port of `course.collision_discriminator` (course.py:211-212).
String collisionDiscriminator(Map<String, dynamic> row) {
  return stableHash(<Object?>[placeKey(row), exerciseKey(row)]);
}

/// Port of `source_bundle._normalize_schedule_value` (source_bundle.py:104-119):
/// normalizes a schedule-row value for equality comparison within a merged
/// group. dict → sorted (key, normalized) pairs; list → normalized items;
/// str → whitespace-collapsed; everything else unchanged.
Object? normalizeScheduleValue(Object? value) {
  if (value is Map) {
    final entries = <MapEntry<String, Object?>>[];
    for (final entry in value.entries) {
      entries.add(MapEntry(entry.key.toString(), normalizeScheduleValue(entry.value)));
    }
    entries.sort((a, b) => a.key.compareTo(b.key));
    return _NormalizedDict(entries);
  }
  if (value is List) {
    return _NormalizedList(
      value.map(normalizeScheduleValue).toList(growable: false),
    );
  }
  if (value is String) {
    return normalizeText(value);
  }
  return value;
}

/// Port of `source_bundle._merged_row_signature` (source_bundle.py:122-129):
/// the participant-independent signature of a row, with `exerciseClass`
/// replaced by `exercise_key`. Used to assert all rows in a merged group agree
/// outside participant fields.
Object _mergedRowSignature(Map<String, dynamic> row) {
  final normalized = <MapEntry<String, Object?>>[];
  for (final entry in row.entries) {
    if (_participantRowFields.contains(entry.key)) continue;
    normalized.add(MapEntry(entry.key, normalizeScheduleValue(entry.value)));
  }
  normalized.add(MapEntry('exerciseClass', exerciseKey(row)));
  normalized.sort((a, b) => a.key.compareTo(b.key));
  return _NormalizedDict(normalized);
}

/// Port of `source_bundle._source_integer` (source_bundle.py:78-84): reject
/// bool, then coerce to int (str/int). Raises [ArgumentError] on failure.
int sourceInteger(Object? value, String errorMessage) {
  if (value is bool) {
    throw ArgumentError(errorMessage);
  }
  if (value is int) {
    return value;
  }
  if (value is String) {
    final parsed = int.tryParse(value);
    if (parsed == null) {
      throw ArgumentError(errorMessage);
    }
    return parsed;
  }
  if (value is double) {
    // Python `int(float)` truncates toward zero; only accept finite integral
    // doubles to match `_source_integer`'s `int(value)` semantics.
    if (!value.isFinite || value != value.truncateToDouble()) {
      throw ArgumentError(errorMessage);
    }
    return value.truncate();
  }
  throw ArgumentError(errorMessage);
}

/// Port of `source_bundle._validate_unique_map_ids` (source_bundle.py:87-101):
/// every item must be a dict with a unique int `id`.
void validateUniqueMapIds(List<dynamic> items, {required String label}) {
  final seen = <int>{};
  final errorMessage = 'course datum contains invalid $label identifiers';
  final duplicateMessage = 'course datum contains duplicate $label identifiers';
  for (final raw in items) {
    if (raw is! Map<String, dynamic> || !raw.containsKey('id')) {
      throw ArgumentError(errorMessage);
    }
    final itemId = sourceInteger(raw['id'], errorMessage);
    if (seen.contains(itemId)) {
      throw ArgumentError(duplicateMessage);
    }
    seen.add(itemId);
  }
}

/// Port of `source_bundle._require_course_result` (source_bundle.py:64-75).
Map<String, dynamic> requireCourseResult(Map<String, dynamic> courseDatum) {
  // The Python guard `isinstance(course_datum, dict)` is satisfied by the
  // static type here; callers passing non-objects would be rejected at the
  // call site. Validate only the nested `result` shape.
  final result = courseDatum['result'];
  if (result is! Map<String, dynamic>) {
    throw ArgumentError('course datum is missing a complete result');
  }
  for (final name in const ['lessonList', 'scheduleGroupList', 'scheduleList']) {
    if (result[name] is! List) {
      throw ArgumentError(
        "course datum result requires list '$name'",
      );
    }
  }
  return result;
}

/// Port of `source_bundle._build_course_data` (source_bundle.py:132-295).
JwCourseData buildCourseData(
  Map<String, dynamic> result,
  String semesterKey,
) {
  validateUniqueMapIds(
    result['lessonList'] as List,
    label: 'lesson',
  );
  validateUniqueMapIds(
    result['scheduleGroupList'] as List,
    label: 'schedule group',
  );
  final lessonMap = buildLessonMap(result);
  final groupMap = buildGroupMap(result);
  for (final group in (result['scheduleGroupList'] as List)) {
    final groupMap1 = group as Map<String, dynamic>;
    final lessonId = sourceInteger(
      groupMap1['lessonId'],
      'course schedule group has invalid lesson assignment',
    );
    if (!lessonMap.containsKey(lessonId)) {
      throw ArgumentError('course schedule group has invalid lesson assignment');
    }
  }

  final groupedRows = groupScheduleRows(result['scheduleList'] as List);
  final rowsByLesson = <int, List<Map<String, dynamic>>>{};
  for (final rows in groupedRows) {
    final row = rows[0];
    final lessonId = sourceInteger(
      row['lessonId'],
      'course schedule row has invalid lesson assignment',
    );
    final groupId = sourceInteger(
      row['scheduleGroupId'],
      'course schedule row has invalid group assignment',
    );
    if (!lessonMap.containsKey(lessonId)) {
      throw ArgumentError('course schedule row has invalid lesson assignment');
    }
    if (!groupMap.containsKey(groupId)) {
      throw ArgumentError('course schedule row has invalid group assignment');
    }
    final groupLessonId = sourceInteger(
      groupMap[groupId]!['lessonId'],
      'course schedule group has invalid lesson assignment',
    );
    if (groupLessonId != lessonId) {
      throw ArgumentError(
        'course schedule group does not belong to row lesson',
      );
    }
    final signature = _mergedRowSignature(row);
    for (final candidate in rows.sublist(1)) {
      if (_mergedRowSignature(candidate) != signature) {
        throw ArgumentError(
          'course schedule rows disagree outside participant fields',
        );
      }
    }
    (rowsByLesson[lessonId] ??= <Map<String, dynamic>>[]).addAll(rows);
  }

  final series = <Map<String, Object?>>[];
  final records = <Map<String, Object?>>[];
  for (final entry in lessonMap.entries) {
    final lessonId = entry.key;
    final lesson = entry.value;
    final externalId = _seriesExternalId(semesterKey, lessonId);
    series.add(<String, Object?>{
      'externalId': externalId,
      'title': _lessonTitle(lesson, lessonId),
      'courseCode': _lessonCode(lesson),
      'semesterKey': semesterKey,
      'participants': publicParticipants(rowsByLesson[lessonId] ?? const []),
      'sourceDetails': <String, Object?>{
        'kind': 'jw_course_series',
        'lessonId': lessonId.toString(),
      },
    });
    records.add(_record(
      externalId: '$jwSource:$semesterKey:record:course-series:lesson:$lessonId',
      recordType: 'jw_course_series',
      entityType: 'course_series',
      entityExternalId: externalId,
    ));
  }

  final events = <Map<String, Object?>>[];
  for (final rows in groupedRows) {
    final row = rows[0];
    final lessonId = (row['lessonId'] as num).toInt();
    final groupId = (row['scheduleGroupId'] as num).toInt();
    final lesson = lessonMap[lessonId]!;
    final startTime = hhmm(row['startTime']);
    final endTime = hhmm(row['endTime']);
    final dateToken = row['date'].toString().replaceAll('-', '');
    final discriminator = collisionDiscriminator(row);
    final identityTail =
        '$lessonId:$groupId:$dateToken:$startTime:$endTime:$discriminator';
    final externalId =
        '$jwSource:$semesterKey:event:course-occurrence:$identityTail';
    final parts = roomParts(row);
    events.add(<String, Object?>{
      'externalId': externalId,
      'seriesExternalId': _seriesExternalId(semesterKey, lessonId),
      'title': _lessonTitle(lesson, lessonId),
      'descriptionText': null,
      'eventType': 'course',
      'time': <String, Object?>{
        'kind': 'timed',
        'startAt': isoDateTime(row['date'] as String, row['startTime']),
        'endAt': isoDateTime(row['date'] as String, row['endTime']),
        'timezone': jwTimezone,
      },
      'location': <String, Object?>{
        'name': parts[0],
        'building': parts[1],
        'campus': parts[2],
      },
      'participants': publicParticipants(rows),
      'sourceDefaults': <String, String>{
        'importance': 'normal',
        'attendancePolicy': 'unknown',
        'listeningMode': 'unknown',
      },
      'sourceDetails': <String, Object?>{
        'kind': 'jw_course_occurrence',
        'semesterKey': semesterKey,
        'lessonId': lessonId.toString(),
        'scheduleGroupId': groupId.toString(),
        'courseCode': _lessonCode(lesson),
        'courseTypeName': _lessonCourseTypeName(lesson),
        'weekIndex': _rawInt(row['weekIndex']),
        'periods': _rawInt(row['periods']),
        'exerciseClass': _pythonBool(row['exerciseClass']),
      },
    });
    records.add(_record(
      externalId:
          '$jwSource:$semesterKey:record:course-occurrence:$identityTail',
      recordType: 'jw_course_occurrence',
      entityType: 'calendar_event',
      entityExternalId: externalId,
    ));
  }

  return JwCourseData(
    series: series,
    calendarEvents: events,
    sourceRecords: records,
  );
}

String _seriesExternalId(String semesterKey, int lessonId) {
  return '$jwSource:$semesterKey:series:lesson:$lessonId';
}

String _lessonTitle(Map<String, dynamic> lesson, int lessonId) {
  final courseName = lesson['courseName'] as String?;
  if (courseName != null && courseName.isNotEmpty) {
    return courseName;
  }
  return '未知课程 $lessonId';
}

/// `lesson.get("code") or None` → null when missing/empty.
Object? _lessonCode(Map<String, dynamic> lesson) {
  final code = lesson['code'] as String?;
  if (code != null && code.isNotEmpty) {
    return code;
  }
  return null;
}

/// `lesson.get("courseTypeName") or None` → null when missing/empty.
Object? _lessonCourseTypeName(Map<String, dynamic> lesson) {
  final courseTypeName = lesson['courseTypeName'] as String?;
  if (courseTypeName != null && courseTypeName.isNotEmpty) {
    return courseTypeName;
  }
  return null;
}

/// Raw `int(value)` (no bool rejection) as used for `weekIndex`/`periods`.
/// Python `int(True)` == 1; Dart `true` → 1, `false` → 0 to match.
int _rawInt(Object? value) {
  if (value is bool) {
    return value ? 1 : 0;
  }
  if (value is int) {
    return value;
  }
  if (value is double) {
    return value.truncate();
  }
  if (value is String) {
    return int.parse(value);
  }
  throw ArgumentError('cannot coerce to int: $value');
}

/// Python `bool(value)`: None/False/""/{}/0 → false; everything else true.
/// Used for the `exerciseClass` field in event `sourceDetails` (NOT for
/// `exercise_key`, which has different rules).
bool _pythonBool(Object? value) {
  if (value == null) return false;
  if (value is bool) return value;
  if (value is String) return value.isNotEmpty;
  if (value is num) return value != 0;
  if (value is Map) return value.isNotEmpty;
  if (value is List) return value.isNotEmpty;
  return true;
}

/// Port of `source_bundle._record` (source_bundle.py:47-61).
Map<String, Object?> _record({
  required String externalId,
  required String recordType,
  required String entityType,
  required String entityExternalId,
}) {
  return <String, Object?>{
    'externalId': externalId,
    'recordType': recordType,
    'entityType': entityType,
    'entityExternalId': entityExternalId,
    'sourceStatus': 'active',
    'sourceUpdatedAt': null,
  };
}

/// Internal normalized-dict wrapper used only for equality comparison by
/// `_merged_row_signature`. Two normalized dicts are equal iff they have the
/// same sorted (key, value) pairs.
class _NormalizedDict {
  _NormalizedDict(this.entries);

  final List<MapEntry<String, Object?>> entries;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! _NormalizedDict) return false;
    if (entries.length != other.entries.length) return false;
    for (var i = 0; i < entries.length; i++) {
      final a = entries[i];
      final b = other.entries[i];
      if (a.key != b.key) return false;
      if (!_normalizedEquals(a.value, b.value)) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(entries.map((e) => Object.hash(e.key, e.value)));
}

class _NormalizedList {
  _NormalizedList(this.items);

  final List<Object?> items;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! _NormalizedList) return false;
    if (items.length != other.items.length) return false;
    for (var i = 0; i < items.length; i++) {
      if (!_normalizedEquals(items[i], other.items[i])) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(items);
}

bool _normalizedEquals(Object? a, Object? b) {
  // The normalized wrappers (_NormalizedDict/_NormalizedList) define their own
  // `==`; for plain values we fall back to Dart equality. When exactly one
  // side is a wrapper and the other is a plain object, `==` returns false via
  // the wrapper's own `operator ==` (which checks `other is! _NormalizedDict`
  // / `_NormalizedList`), so a single dispatch covers all cases.
  return a == b;
}
