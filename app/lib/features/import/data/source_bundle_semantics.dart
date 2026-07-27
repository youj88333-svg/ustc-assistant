import '../domain/source_bundle_error.dart';

const _recordEntityTypes = <String, String>{
  'jw_course_series': 'course_series',
  'jw_course_occurrence': 'calendar_event',
  'jw_exam': 'calendar_event',
  'jw_exam_course_relation': 'schedule_relation',
  'young_registered_schedule': 'calendar_event',
};

void validateSourceBundleSemantics(Map<String, dynamic> bundle) {
  final snapshot = bundle['snapshot'] as Map<String, dynamic>;
  if (snapshot['completeness'] != 'complete') {
    throwSourceBundleError('incomplete_snapshot');
  }
  final scope = snapshot['scope'] as Map<String, dynamic>;
  for (final component in (scope['components'] as List<dynamic>? ?? const [])) {
    if ((component as Map<String, dynamic>)['status'] != 'complete') {
      throwSourceBundleError('incomplete_snapshot');
    }
  }

  final data = bundle['data'] as Map<String, dynamic>;
  _checkUniqueIdentities(data);
  _checkManifest(bundle['manifest'] as Map<String, dynamic>, data);
  _checkTimes(data['calendarEvents'] as List<dynamic>);
  _checkReferences(data);
  _checkScope(bundle['source'] as String, scope, data);
}

void inspectSourceBundleStructure(Object? value, [int depth = 0]) {
  if (depth > 64) {
    throwSourceBundleError('limit_exceeded');
  }
  if (value is Map) {
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throwSourceBundleError('invalid_envelope');
      }
      final normalized = (entry.key as String)
          .toLowerCase()
          .replaceAll('_', '')
          .replaceAll('-', '');
      const sensitive = {
        'authorization',
        'browserprofile',
        'contextid',
        'cookie',
        'credential',
        'password',
        'profilepath',
        'sessionid',
        'studentid',
        'token',
        'userid',
      };
      if (sensitive.any(normalized.contains)) {
        throwSourceBundleError('invalid_envelope');
      }
      inspectSourceBundleStructure(entry.value, depth + 1);
    }
  } else if (value is List) {
    for (final child in value) {
      inspectSourceBundleStructure(child, depth + 1);
    }
  } else if (value is double && !value.isFinite) {
    throwSourceBundleError('invalid_envelope');
  }
}

void _checkUniqueIdentities(Map<String, dynamic> data) {
  for (final name in [
    'sourceRecords',
    'calendarEvents',
    'courseSeries',
    'scheduleRelations',
  ]) {
    final identities = (data[name] as List<dynamic>)
        .map((item) => (item as Map<String, dynamic>)['externalId'] as String)
        .toList();
    if (identities.toSet().length != identities.length) {
      throwSourceBundleError('duplicate_identity');
    }
  }
}

void _checkManifest(Map<String, dynamic> manifest, Map<String, dynamic> data) {
  final expected = {
    'sourceRecordCount': (data['sourceRecords'] as List).length,
    'calendarEventCount': (data['calendarEvents'] as List).length,
    'courseSeriesCount': (data['courseSeries'] as List).length,
    'scheduleRelationCount': (data['scheduleRelations'] as List).length,
  };
  if (expected.entries.any((entry) => manifest[entry.key] != entry.value)) {
    throwSourceBundleError('count_mismatch');
  }
}

DateTime _beijingDateTime(String value) {
  if (!RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?\+08:00$',
  ).hasMatch(value)) {
    throwSourceBundleError('invalid_time');
  }
  try {
    return DateTime.parse(value);
  } on FormatException {
    throwSourceBundleError('invalid_time');
  }
}

String _date(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    throwSourceBundleError('invalid_time');
  }
  try {
    final parsed = DateTime.parse(value);
    if (parsed.toIso8601String().substring(0, 10) != value) {
      throwSourceBundleError('invalid_time');
    }
    return value;
  } on FormatException {
    throwSourceBundleError('invalid_time');
  }
}

void _checkTimes(List<dynamic> events) {
  for (final item in events) {
    final event = item as Map<String, dynamic>;
    final time = event['time'] as Map<String, dynamic>;
    if (time['kind'] == 'timed') {
      if (!_beijingDateTime(
        time['startAt'] as String,
      ).isBefore(_beijingDateTime(time['endAt'] as String))) {
        throwSourceBundleError('invalid_time');
      }
    } else if (_date(
          time['startDate'] as String,
        ).compareTo(_date(time['endDateExclusive'] as String)) >=
        0) {
      throwSourceBundleError('invalid_time');
    }
  }
}

void _checkReferences(Map<String, dynamic> data) {
  final collections = <String, List<dynamic>>{
    'calendar_event': data['calendarEvents'] as List<dynamic>,
    'course_series': data['courseSeries'] as List<dynamic>,
    'schedule_relation': data['scheduleRelations'] as List<dynamic>,
  };
  final entities = <String, Set<String>>{};
  final kinds = <String, Map<String, String>>{};
  for (final entry in collections.entries) {
    entities[entry.key] = {
      for (final item in entry.value)
        (item as Map<String, dynamic>)['externalId'] as String,
    };
    kinds[entry.key] = {
      for (final item in entry.value)
        (item as Map<String, dynamic>)['externalId']
            as String: entry.key == 'schedule_relation'
            ? 'jw_exam_course_relation'
            : ((item['sourceDetails'] as Map<String, dynamic>)['kind']
                  as String),
    };
  }

  final mappings = <String, int>{};
  for (final item in data['sourceRecords'] as List<dynamic>) {
    final record = item as Map<String, dynamic>;
    final recordType = record['recordType'] as String;
    final entityType = record['entityType'] as String;
    final entityId = record['entityExternalId'] as String;
    if (_recordEntityTypes[recordType] != entityType ||
        !(entities[entityType]?.contains(entityId) ?? false) ||
        kinds[entityType]?[entityId] != recordType) {
      throwSourceBundleError('dangling_reference');
    }
    final key = '$entityType\u0000$entityId';
    mappings[key] = (mappings[key] ?? 0) + 1;
  }
  if (mappings.values.any((count) => count > 1)) {
    throwSourceBundleError('duplicate_identity');
  }
  for (final entry in entities.entries) {
    for (final identity in entry.value) {
      if (mappings['${entry.key}\u0000$identity'] != 1) {
        throwSourceBundleError('dangling_reference');
      }
    }
  }

  final courseSeries = entities['course_series']!;
  for (final item in data['calendarEvents'] as List<dynamic>) {
    final seriesId =
        (item as Map<String, dynamic>)['seriesExternalId'] as String?;
    if (seriesId != null && !courseSeries.contains(seriesId)) {
      throwSourceBundleError('dangling_reference');
    }
  }

  for (final item in data['scheduleRelations'] as List<dynamic>) {
    final relation = item as Map<String, dynamic>;
    final primary = relation['primary'] as Map<String, dynamic>;
    final related = relation['related'] as Map<String, dynamic>;
    final primaryType = primary['entityType'] as String;
    final relatedType = related['entityType'] as String;
    final primaryId = primary['externalId'] as String;
    final relatedId = related['externalId'] as String;
    if (!(entities[primaryType]?.contains(primaryId) ?? false) ||
        !(entities[relatedType]?.contains(relatedId) ?? false) ||
        primaryType != 'calendar_event' ||
        relatedType != 'course_series' ||
        kinds['calendar_event']?[primaryId] != 'jw_exam') {
      throwSourceBundleError('dangling_reference');
    }
  }
}

void _checkScope(
  String source,
  Map<String, dynamic> scope,
  Map<String, dynamic> data,
) {
  if (source == 'ustc_jw') {
    final recordCounts = <String, int>{};
    for (final item in data['sourceRecords'] as List<dynamic>) {
      final type = (item as Map<String, dynamic>)['recordType'] as String;
      recordCounts[type] = (recordCounts[type] ?? 0) + 1;
    }
    final observed = {
      for (final item in scope['components'] as List<dynamic>)
        (item as Map<String, dynamic>)['name'] as String:
            item['observedRecordCount'] as int,
    };
    final courseCount =
        (recordCounts['jw_course_series'] ?? 0) +
        (recordCounts['jw_course_occurrence'] ?? 0);
    final examCount =
        (recordCounts['jw_exam'] ?? 0) +
        (recordCounts['jw_exam_course_relation'] ?? 0);
    if (observed['course_table'] != courseCount ||
        observed['exam_arrange'] != examCount) {
      throwSourceBundleError('count_mismatch');
    }
    final semesterKey = scope['semesterKey'];
    for (final item in data['courseSeries'] as List<dynamic>) {
      if ((item as Map<String, dynamic>)['semesterKey'] != semesterKey) {
        throwSourceBundleError('dangling_reference');
      }
    }
    for (final item in data['calendarEvents'] as List<dynamic>) {
      final details =
          (item as Map<String, dynamic>)['sourceDetails']
              as Map<String, dynamic>;
      if (details['semesterKey'] != semesterKey) {
        throwSourceBundleError('dangling_reference');
      }
    }
    return;
  }

  final from = _date(scope['fromDate'] as String);
  final through = _date(scope['throughDate'] as String);
  if (from.compareTo(through) > 0) {
    throwSourceBundleError('invalid_time');
  }
  final expectedDays =
      DateTime.parse(through).difference(DateTime.parse(from)).inDays + 1;
  if (scope['expectedDateCount'] != expectedDays ||
      scope['checkedDateCount'] != expectedDays ||
      (scope['emptyDateCount'] as int) > (scope['checkedDateCount'] as int)) {
    throwSourceBundleError('count_mismatch');
  }
  for (final item in data['calendarEvents'] as List<dynamic>) {
    final time = (item as Map<String, dynamic>)['time'] as Map<String, dynamic>;
    final eventDate = time['kind'] == 'timed'
        ? (time['startAt'] as String).substring(0, 10)
        : time['startDate'] as String;
    if (eventDate.compareTo(from) < 0 || eventDate.compareTo(through) > 0) {
      throwSourceBundleError('invalid_time');
    }
  }
}
