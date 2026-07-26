import 'dart:convert';
import 'dart:typed_data';

import 'package:json_schema/json_schema.dart';

import '../domain/source_bundle.dart';
import '../domain/source_bundle_error.dart';
import 'source_bundle_semantics.dart';

class SourceBundleDecoder {
  SourceBundleDecoder(Map<String, dynamic> schema)
    : _schema = JsonSchema.create(schema);

  static const maxBundleBytes = 16 * 1024 * 1024;

  final JsonSchema _schema;

  SourceBundle decode(Uint8List bytes) {
    if (bytes.length > maxBundleBytes) {
      throwSourceBundleError('limit_exceeded');
    }

    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throwSourceBundleError('invalid_envelope');
    }
    if (decoded is! Map<String, dynamic>) {
      throwSourceBundleError('invalid_envelope');
    }
    inspectSourceBundleStructure(decoded);

    if (decoded['schemaVersion'] != '1.0') {
      throwSourceBundleError('unsupported_version');
    }
    final snapshot = decoded['snapshot'];
    if (snapshot is Map &&
        snapshot['completeness'] != null &&
        snapshot['completeness'] != 'complete') {
      throwSourceBundleError('incomplete_snapshot');
    }

    final validation = _schema.validate(decoded, validateFormats: true);
    if (!validation.isValid) {
      final error = validation.errors.first;
      final schemaPath = error.schemaPath.toLowerCase();
      final instancePath = error.instancePath;
      if (schemaPath.contains('maxitems') ||
          schemaPath.contains('maxlength') ||
          schemaPath.contains('maximum')) {
        throwSourceBundleError('limit_exceeded');
      }
      final isTimePath = const [
        'collectedAt',
        'endAt',
        'endDateExclusive',
        'fromDate',
        'sourceUpdatedAt',
        'startAt',
        'startDate',
        'throughDate',
      ].any(instancePath.contains);
      if (isTimePath && !schemaPath.contains('additionalproperties')) {
        throwSourceBundleError('invalid_time');
      }
      throwSourceBundleError('invalid_envelope');
    }

    validateSourceBundleSemantics(decoded);
    return _decodeTyped(decoded);
  }

  SourceBundle _decodeTyped(Map<String, dynamic> raw) {
    final subject = raw['subject'] as Map<String, dynamic>;
    final snapshot = raw['snapshot'] as Map<String, dynamic>;
    final manifest = raw['manifest'] as Map<String, dynamic>;
    final data = raw['data'] as Map<String, dynamic>;
    return SourceBundle(
      schemaVersion: raw['schemaVersion'] as String,
      bundleId: raw['bundleId'] as String,
      source: raw['source'] as String,
      subject: SourceBundleSubject(accountId: subject['accountId'] as String),
      collectedAt: DateTime.parse(raw['collectedAt'] as String),
      snapshot: SourceBundleSnapshot(
        completeness: snapshot['completeness'] as String,
        scope: Map<String, dynamic>.from(
          snapshot['scope'] as Map<String, dynamic>,
        ),
      ),
      manifest: SourceBundleManifest(
        sourceRecordCount: manifest['sourceRecordCount'] as int,
        calendarEventCount: manifest['calendarEventCount'] as int,
        courseSeriesCount: manifest['courseSeriesCount'] as int,
        scheduleRelationCount: manifest['scheduleRelationCount'] as int,
      ),
      data: SourceBundleData(
        sourceRecords: (data['sourceRecords'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .map(_decodeSourceRecord)
            .toList(),
        calendarEvents: (data['calendarEvents'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .map(_decodeCalendarEvent)
            .toList(),
        courseSeries: (data['courseSeries'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .map(_decodeCourseSeries)
            .toList(),
        scheduleRelations: (data['scheduleRelations'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .map(_decodeScheduleRelation)
            .toList(),
      ),
      raw: Map<String, dynamic>.from(raw),
    );
  }

  SourceRecordValue _decodeSourceRecord(Map<String, dynamic> value) {
    return SourceRecordValue(
      externalId: value['externalId'] as String,
      recordType: value['recordType'] as String,
      entityType: value['entityType'] as String,
      entityExternalId: value['entityExternalId'] as String,
      sourceStatus: value['sourceStatus'] as String,
      sourceUpdatedAt: value['sourceUpdatedAt'] == null
          ? null
          : DateTime.parse(value['sourceUpdatedAt'] as String),
    );
  }

  CalendarEventValue _decodeCalendarEvent(Map<String, dynamic> value) {
    final time = value['time'] as Map<String, dynamic>;
    return CalendarEventValue(
      externalId: value['externalId'] as String,
      seriesExternalId: value['seriesExternalId'] as String?,
      title: value['title'] as String,
      descriptionText: value['descriptionText'] as String?,
      eventType: value['eventType'] as String,
      time: time['kind'] == 'timed'
          ? SourceEventTime.timed(
              startAt: DateTime.parse(time['startAt'] as String),
              endAt: DateTime.parse(time['endAt'] as String),
              timezone: time['timezone'] as String,
            )
          : SourceEventTime.allDay(
              startDate: time['startDate'] as String,
              endDateExclusive: time['endDateExclusive'] as String,
              timezone: time['timezone'] as String,
            ),
      location: Map<String, dynamic>.from(
        value['location'] as Map<String, dynamic>,
      ),
      participants: List<dynamic>.from(value['participants'] as List<dynamic>),
      sourceDefaults: Map<String, dynamic>.from(
        value['sourceDefaults'] as Map<String, dynamic>,
      ),
      sourceDetails: Map<String, dynamic>.from(
        value['sourceDetails'] as Map<String, dynamic>,
      ),
    );
  }

  CourseSeriesValue _decodeCourseSeries(Map<String, dynamic> value) {
    return CourseSeriesValue(
      externalId: value['externalId'] as String,
      title: value['title'] as String,
      courseCode: value['courseCode'] as String?,
      semesterKey: value['semesterKey'] as String,
      participants: List<dynamic>.from(value['participants'] as List<dynamic>),
      sourceDetails: Map<String, dynamic>.from(
        value['sourceDetails'] as Map<String, dynamic>,
      ),
    );
  }

  ScheduleRelationValue _decodeScheduleRelation(Map<String, dynamic> value) {
    return ScheduleRelationValue(
      externalId: value['externalId'] as String,
      relationType: value['relationType'] as String,
      primary: Map<String, dynamic>.from(
        value['primary'] as Map<String, dynamic>,
      ),
      related: Map<String, dynamic>.from(
        value['related'] as Map<String, dynamic>,
      ),
    );
  }
}
