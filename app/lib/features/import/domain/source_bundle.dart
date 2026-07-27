import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'source_bundle_error.dart';

class SourceBundle {
  SourceBundle({
    required this.schemaVersion,
    required this.bundleId,
    required this.source,
    required this.subject,
    required this.collectedAt,
    required this.snapshot,
    required this.manifest,
    required this.data,
    required Map<String, dynamic> raw,
  }) : raw = UnmodifiableMapView(raw);

  final String schemaVersion;
  final String bundleId;
  final String source;
  final SourceBundleSubject subject;
  final DateTime collectedAt;
  final SourceBundleSnapshot snapshot;
  final SourceBundleManifest manifest;
  final SourceBundleData data;
  final Map<String, dynamic> raw;

  String get digest =>
      sha256.convert(utf8.encode(canonicalJson(raw))).toString();

  void requireSubject(String expectedAccountId) {
    if (subject.accountId != expectedAccountId) {
      throwSourceBundleError('subject_mismatch');
    }
  }
}

class SourceBundleSubject {
  const SourceBundleSubject({required this.accountId});

  final String accountId;
}

class SourceBundleSnapshot {
  SourceBundleSnapshot({
    required this.completeness,
    required Map<String, dynamic> scope,
  }) : scope = UnmodifiableMapView(scope);

  final String completeness;
  final Map<String, dynamic> scope;

  String get scopeKey {
    return switch (scope['type']) {
      'semester' => scope['semesterKey'] as String,
      'date_window' =>
        '${scope['fromDate'] as String}:${scope['throughDate'] as String}',
      _ => throw StateError('Validated SourceBundle has an unknown scope.'),
    };
  }
}

class SourceBundleManifest {
  const SourceBundleManifest({
    required this.sourceRecordCount,
    required this.calendarEventCount,
    required this.courseSeriesCount,
    required this.scheduleRelationCount,
  });

  final int sourceRecordCount;
  final int calendarEventCount;
  final int courseSeriesCount;
  final int scheduleRelationCount;
}

class SourceBundleData {
  SourceBundleData({
    required List<SourceRecordValue> sourceRecords,
    required List<CalendarEventValue> calendarEvents,
    required List<CourseSeriesValue> courseSeries,
    required List<ScheduleRelationValue> scheduleRelations,
  }) : sourceRecords = List.unmodifiable(sourceRecords),
       calendarEvents = List.unmodifiable(calendarEvents),
       courseSeries = List.unmodifiable(courseSeries),
       scheduleRelations = List.unmodifiable(scheduleRelations);

  final List<SourceRecordValue> sourceRecords;
  final List<CalendarEventValue> calendarEvents;
  final List<CourseSeriesValue> courseSeries;
  final List<ScheduleRelationValue> scheduleRelations;
}

class SourceRecordValue {
  const SourceRecordValue({
    required this.externalId,
    required this.recordType,
    required this.entityType,
    required this.entityExternalId,
    required this.sourceStatus,
    required this.sourceUpdatedAt,
  });

  final String externalId;
  final String recordType;
  final String entityType;
  final String entityExternalId;
  final String sourceStatus;
  final DateTime? sourceUpdatedAt;
}

class CalendarEventValue {
  CalendarEventValue({
    required this.externalId,
    required this.seriesExternalId,
    required this.title,
    required this.descriptionText,
    required this.eventType,
    required this.time,
    required Map<String, dynamic> location,
    required List<dynamic> participants,
    required Map<String, dynamic> sourceDefaults,
    required Map<String, dynamic> sourceDetails,
  }) : location = UnmodifiableMapView(location),
       participants = List.unmodifiable(participants),
       sourceDefaults = UnmodifiableMapView(sourceDefaults),
       sourceDetails = UnmodifiableMapView(sourceDetails);

  final String externalId;
  final String? seriesExternalId;
  final String title;
  final String? descriptionText;
  final String eventType;
  final SourceEventTime time;
  final Map<String, dynamic> location;
  final List<dynamic> participants;
  final Map<String, dynamic> sourceDefaults;
  final Map<String, dynamic> sourceDetails;
}

class SourceEventTime {
  const SourceEventTime.timed({
    required this.startAt,
    required this.endAt,
    required this.timezone,
  }) : kind = 'timed',
       startDate = null,
       endDateExclusive = null;

  const SourceEventTime.allDay({
    required this.startDate,
    required this.endDateExclusive,
    required this.timezone,
  }) : kind = 'all_day',
       startAt = null,
       endAt = null;

  final String kind;
  final DateTime? startAt;
  final DateTime? endAt;
  final String? startDate;
  final String? endDateExclusive;
  final String timezone;
}

class CourseSeriesValue {
  CourseSeriesValue({
    required this.externalId,
    required this.title,
    required this.courseCode,
    required this.semesterKey,
    required List<dynamic> participants,
    required Map<String, dynamic> sourceDetails,
  }) : participants = List.unmodifiable(participants),
       sourceDetails = UnmodifiableMapView(sourceDetails);

  final String externalId;
  final String title;
  final String? courseCode;
  final String semesterKey;
  final List<dynamic> participants;
  final Map<String, dynamic> sourceDetails;
}

class ScheduleRelationValue {
  ScheduleRelationValue({
    required this.externalId,
    required this.relationType,
    required Map<String, dynamic> primary,
    required Map<String, dynamic> related,
  }) : primary = UnmodifiableMapView(primary),
       related = UnmodifiableMapView(related);

  final String externalId;
  final String relationType;
  final Map<String, dynamic> primary;
  final Map<String, dynamic> related;
}

String canonicalJson(Object? value) {
  Object? normalize(Object? current) {
    if (current is Map) {
      final keys = current.keys.cast<String>().toList()..sort();
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
