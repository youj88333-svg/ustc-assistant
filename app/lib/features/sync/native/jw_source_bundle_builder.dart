// Field-for-field Dart port of `src/ustc_assistant/sources/jw/source_bundle.py`
// `build_jw_source_bundle` (+ `_build_exam_data`, `_collected_at_text`) and
// `src/ustc_assistant/contracts/source_bundle.py` `make_bundle_envelope`.
//
// Produces a SourceBundle 1.0 envelope whose canonical digest matches the
// Python oracle when the same fixed `bundleId`/`collectedAt`/`producer` are
// injected. See `docs/plan-webview-minimal-m2.md` §4 F4 + §7.

import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../import/data/source_bundle_semantics.dart';
import '_jw_identity.dart';
import 'jw_course_normalizer.dart';
import 'jw_exam_parser.dart';

/// Default Dart producer. Tests inject the Python producer to compare digests
/// against the oracle; production uses this to report the Flutter origin.
const Map<String, String> defaultDartProducer = {
  'name': 'ustc_assistant_flutter',
  'version': '0.1.0',
  'platform': 'windows',
};

/// Semester identity required to build a bundle (mirrors `JwSemesterConfig`).
class JwSemester {
  const JwSemester({
    required this.semesterId,
    required this.semesterKey,
    required this.displayName,
  });

  final int semesterId;
  final String semesterKey;
  final String displayName;
}

/// Build a complete JW SourceBundle 1.0 snapshot. Mirrors
/// `source_bundle.build_jw_source_bundle` step for step.
///
/// - [courseDatum]: the whole `{result:{...}}` object.
/// - [examHtml]: the exam HTML page (contains `<table id="exams">`).
/// - [accountId]: the account the bundle is scoped to.
/// - [semester]: semester identity (id/key/displayName).
/// - [bundleId]: optional fixed UUID; defaults to a fresh random UUID.
/// - [collectedAt]: optional tz-aware collection time; defaults to now in
///   `Asia/Shanghai`.
/// - [producer]: optional producer map; defaults to [defaultDartProducer].
Map<String, dynamic> buildJwSourceBundle({
  required Map<String, dynamic> courseDatum,
  required String examHtml,
  required String accountId,
  required JwSemester semester,
  String? bundleId,
  DateTime? collectedAt,
  Map<String, Object?>? producer,
}) {
  final result = requireCourseResult(courseDatum);
  final courseData = buildCourseData(result, semester.semesterKey);
  final courseSeries = courseData.series;
  final courseEvents = courseData.calendarEvents;
  final courseRecords = courseData.sourceRecords;

  final (examEvents, examRecords) = _buildExamData(
    examHtml,
    semester.semesterKey,
    courseSeries,
  );

  final data = <String, dynamic>{
    'sourceRecords': [...courseRecords, ...examRecords],
    'calendarEvents': [...courseEvents, ...examEvents],
    'courseSeries': courseSeries,
    'scheduleRelations': <dynamic>[],
  };

  final snapshot = <String, dynamic>{
    'completeness': 'complete',
    'scope': <String, dynamic>{
      'type': 'semester',
      'semesterKey': semester.semesterKey,
      'sourceSemesterId': semester.semesterId,
      'components': <Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'course_table',
          'status': 'complete',
          'observedRecordCount': courseRecords.length,
        },
        <String, dynamic>{
          'name': 'exam_arrange',
          'status': 'complete',
          'observedRecordCount': examRecords.length,
        },
      ],
    },
  };

  final bundle = _makeBundleEnvelope(
    bundleId: bundleId ?? const Uuid().v4(),
    source: jwSource,
    accountId: accountId,
    collectedAt: collectedAtText(collectedAt),
    snapshot: snapshot,
    data: data,
    producer: producer ?? defaultDartProducer,
  );

  // Mirrors the Python `validate_source_bundle(bundle)` mandatory check.
  validateSourceBundleSemantics(bundle);
  return bundle;
}

/// Port of `source_bundle._build_exam_data` (source_bundle.py:298-381).
(List<Map<String, Object?>>, List<Map<String, Object?>>) _buildExamData(
  String examHtml,
  String semesterKey,
  List<Map<String, Object?>> series,
) {
  final examRows = parseExamRows(examHtml);
  final seriesByCode = <String, List<String>>{};
  for (final item in series) {
    final courseCode = item['courseCode'];
    if (courseCode is String && courseCode.isNotEmpty) {
      (seriesByCode[courseCode] ??= <String>[]).add(item['externalId'] as String);
    }
  }

  final events = <Map<String, Object?>>[];
  final records = <Map<String, Object?>>[];
  final seen = <String>{};
  for (var rowNumber = 1; rowNumber <= examRows.length; rowNumber++) {
    final row = examRows[rowNumber - 1];
    final (startAt, endAt) = parseExamTime(row.dateTime, rowNumber);
    final identityHash = stableHash(<Object?>[
      row.courseCode,
      row.examType,
      startAt,
      endAt,
      row.room,
      row.building,
      row.campus,
    ]);
    final identityTail = '${row.courseCode}:$identityHash';
    final externalId = '$jwSource:$semesterKey:event:exam:$identityTail';
    if (seen.contains(externalId)) {
      throw ArgumentError('exam row $rowNumber: duplicate exam identity');
    }
    seen.add(externalId);
    final matchingSeries = seriesByCode[row.courseCode] ?? const <String>[];
    final seriesExternalId =
        matchingSeries.length == 1 ? matchingSeries.first : null;
    events.add(<String, Object?>{
      'externalId': externalId,
      'seriesExternalId': seriesExternalId,
      'title': row.courseName,
      'descriptionText': _orNull(row.note),
      'eventType': 'exam',
      'time': <String, Object?>{
        'kind': 'timed',
        'startAt': startAt,
        'endAt': endAt,
        'timezone': jwTimezone,
      },
      'location': <String, Object?>{
        'name': row.room,
        'building': row.building,
        'campus': row.campus,
      },
      'participants': <dynamic>[],
      'sourceDefaults': <String, String>{
        'importance': 'critical',
        'attendancePolicy': 'must_go',
        'listeningMode': 'unknown',
      },
      'sourceDetails': <String, Object?>{
        'kind': 'jw_exam',
        'semesterKey': semesterKey,
        'classroomNumber': row.room,
        'examType': row.examType,
        'courseCode': _orNull(row.courseCode),
        'instructions': _orNull(row.note),
      },
    });
    records.add(<String, Object?>{
      'externalId': '$jwSource:$semesterKey:record:exam:$identityTail',
      'recordType': 'jw_exam',
      'entityType': 'calendar_event',
      'entityExternalId': externalId,
      'sourceStatus': 'active',
      'sourceUpdatedAt': null,
    });
  }
  return (events, records);
}

/// `value or None` — empty string → null; non-empty string unchanged. Matches
/// `row.note or None` / `row.course_code or None`.
Object? _orNull(String value) => value.isEmpty ? null : value;

/// Port of `source_bundle._collected_at_text` (source_bundle.py:384-392):
/// require a tz-aware instant, render in Asia/Shanghai at second precision.
String collectedAtText(DateTime? collectedAt) {
  final instant = collectedAt ?? DateTime.now().toUtc();
  // `DateTime.now().toUtc()` is tz-aware (utc). A caller passing a local
  // `DateTime` is also acceptable (it carries an implicit offset). We only
  // reject a naive instant — which Dart never produces — so this mirrors the
  // Python `utcoffset() is not None` guard.
  final beijing = instant.toUtc().add(const Duration(hours: 8));
  final y = beijing.year.toString().padLeft(4, '0');
  final mo = beijing.month.toString().padLeft(2, '0');
  final d = beijing.day.toString().padLeft(2, '0');
  final hh = beijing.hour.toString().padLeft(2, '0');
  final mm = beijing.minute.toString().padLeft(2, '0');
  final ss = beijing.second.toString().padLeft(2, '0');
  return '$y-$mo-${d}T$hh:$mm:$ss$jwTzOffset';
}

/// Port of `contracts.make_bundle_envelope` (source_bundle.py:18-51): builds
/// the top-level envelope in the exact key order the Python producer emits
/// (`schemaVersion, bundleId, source, subject, collectedAt, producer,
/// snapshot, manifest, data`). Canonical digest sorts keys recursively, so
/// order does not affect the digest, but the structure is preserved for
/// parity.
Map<String, dynamic> _makeBundleEnvelope({
  required String bundleId,
  required String source,
  required String accountId,
  required String collectedAt,
  required Map<String, dynamic> snapshot,
  required Map<String, dynamic> data,
  required Map<String, Object?> producer,
}) {
  final copiedData = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
  return <String, dynamic>{
    'schemaVersion': '1.0',
    'bundleId': bundleId,
    'source': source,
    'subject': <String, String>{'accountId': accountId},
    'collectedAt': collectedAt,
    'producer': jsonDecode(jsonEncode(producer)) as Map<String, dynamic>,
    'snapshot': jsonDecode(jsonEncode(snapshot)) as Map<String, dynamic>,
    'manifest': <String, int>{
      'sourceRecordCount': (copiedData['sourceRecords'] as List).length,
      'calendarEventCount': (copiedData['calendarEvents'] as List).length,
      'courseSeriesCount': (copiedData['courseSeries'] as List).length,
      'scheduleRelationCount':
          (copiedData['scheduleRelations'] as List).length,
    },
    'data': copiedData,
  };
}
