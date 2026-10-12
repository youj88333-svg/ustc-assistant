import 'dart:convert';

import '../core/contracts.dart';
import '../core/jw_work_contract.dart';
import '../data/jw_import_contract.dart';
import 'jw_collection_failure.dart';
import 'jw_data_probe_contract.dart';
import 'jw_probe_contract.dart';

/// Safe counts of fully validated rows and their unique normalized events.
final class JwCollectionNormalization {
  const JwCollectionNormalization._({
    required this.courseRows,
    required this.courseEvents,
    required this.examRows,
    required this.examEvents,
  });
  final int courseRows;
  final int courseEvents;
  final int examRows;
  final int examEvents;
  int get duplicateCourses => courseRows - courseEvents;
  int get duplicateExams => examRows - examEvents;
  bool get hasDuplicates => duplicateCourses > 0 || duplicateExams > 0;
  Map<String, int> get safeProjection => {
    'courseRows': courseRows,
    'courseEvents': courseEvents,
    'duplicateCourses': duplicateCourses,
    'examRows': examRows,
    'examEvents': examEvents,
    'duplicateExams': duplicateExams,
  };

  @override
  String toString() => 'JwCollectionNormalization';
}

/// Private C1 terminal data. Never place this reply on a public progress stream.
final class JwCollectionReply {
  JwCollectionReply._(
    this.probe,
    this.semesterId,
    List<JwEventDraft> events, {
    this.normalization,
  }) : events = List.unmodifiable(events);
  final JwDataProbeReply probe;
  final int? semesterId;
  final List<JwEventDraft> events;
  final JwCollectionNormalization? normalization;

  factory JwCollectionReply.decode(String source, {required int operation}) {
    if (source.length > 8 * 1024 * 1024) {
      _reject(JwCollectionRejectionReason.projectionInvalid);
    }
    try {
      final root = jsonDecode(source);
      if (root is! Map<String, dynamic>) {
        _reject(JwCollectionRejectionReason.projectionInvalid);
      }
      final hasSnapshot = root.containsKey('snapshot');
      final snapshot = root.remove('snapshot');
      final probe = JwDataProbeReply.decode(
        jsonEncode(root),
        operation: operation,
      );
      if (probe.phase != JwProbePhase.done ||
          probe.code != JwDataProbeCode.ok) {
        if (hasSnapshot) {
          _reject(
            JwCollectionRejectionReason.projectionInvalid,
            diagnostics: probe.diagnostics,
          );
        }
        return JwCollectionReply._(probe, null, const []);
      }
      final d = probe.diagnostics;
      if (d == null) {
        _reject(JwCollectionRejectionReason.proofInvalid);
      }
      if (!d.selfRouteBound) {
        _reject(JwCollectionRejectionReason.selfRouteUnbound, diagnostics: d);
      }
      if (!d.identityStable ||
          !d.semesterAccepted ||
          d.identityReads != 2 ||
          d.pagination ||
          probe.identityCandidateCount != 1 ||
          probe.accountCode == null ||
          d.reason != 'none' ||
          d.checks.entries.any(
            (e) =>
                e.value != 'ok' &&
                !(e.key == 'datum' && d.emptyCourse && e.value == 'skipped'),
          ) ||
          d.lessonIds != d.lessons ||
          d.schedules != d.datedSchedules ||
          d.schedules != d.timedSchedules ||
          d.schedules != d.linkedSchedules ||
          d.examRows != d.datedExams ||
          d.emptyCourse != (d.lessonIds == 0) ||
          d.emptyExams != (d.examRows == 0)) {
        _reject(JwCollectionRejectionReason.proofInvalid, diagnostics: d);
      }
      if (snapshot is! Map<String, dynamic> ||
          !_keys(snapshot, const {'semesterId', 'courses', 'exams'})) {
        _reject(JwCollectionRejectionReason.snapshotShape, diagnostics: d);
      }
      final semesterValue = snapshot['semesterId'];
      if (!_isPositiveId(semesterValue)) {
        _reject(JwCollectionRejectionReason.snapshotShape, diagnostics: d);
      }
      final semester = semesterValue as int;
      final courses = snapshot['courses'];
      final exams = snapshot['exams'];
      if (courses is! List || exams is! List) {
        _reject(JwCollectionRejectionReason.snapshotShape, diagnostics: d);
      }
      if (courses.length != d.schedules ||
          exams.length != d.examRows ||
          courses.length + exams.length > 10000 ||
          (d.emptyCourse && courses.isNotEmpty)) {
        _reject(JwCollectionRejectionReason.eventCount, diagnostics: d);
      }
      final events = <JwEventDraft>[];
      final seen = <String, JwEventDraft>{};
      for (final value in courses) {
        if (value is! Map<String, dynamic> ||
            !_keys(value, const {
              'lessonId',
              'groupId',
              'date',
              'startMinute',
              'endMinute',
              'title',
            })) {
          _reject(JwCollectionRejectionReason.courseFields, diagnostics: d);
        }
        final lessonValue = value['lessonId'];
        final groupValue = value['groupId'];
        if (!_isPositiveId(lessonValue) || !_isPositiveId(groupValue)) {
          _reject(JwCollectionRejectionReason.courseFields, diagnostics: d);
        }
        final lesson = lessonValue as int;
        final group = groupValue as int;
        final interval = _interval(
          value,
          reason: JwCollectionRejectionReason.courseFields,
          diagnostics: d,
        );
        final key =
            'course-${fingerprint([semester, lesson, group, value['date'], value['startMinute']])}';
        final draft = JwEventDraft(
          externalId: key,
          kind: JwEventKind.course,
          semesterId: semester,
          title: _text(
            value['title'],
            300,
            reason: JwCollectionRejectionReason.courseFields,
            diagnostics: d,
          ),
          startsAtUtc: interval.$1,
          endsAtUtc: interval.$2,
        );
        final previous = seen[key];
        if (previous != null) {
          if (_sameEvent(previous, draft)) continue;
          _reject(
            JwCollectionRejectionReason.duplicateCourseKey,
            diagnostics: d,
            duplicateIdentical: false,
          );
        }
        seen[key] = draft;
        events.add(draft);
      }
      final courseEvents = events.length;
      for (final value in exams) {
        if (value is! Map<String, dynamic> ||
            !_keys(value, const {
              'courseCode',
              'examType',
              'date',
              'startMinute',
              'endMinute',
              'title',
            })) {
          _reject(JwCollectionRejectionReason.examFields, diagnostics: d);
        }
        final course = _text(
          value['courseCode'],
          100,
          reason: JwCollectionRejectionReason.examFields,
          diagnostics: d,
        );
        final type = _text(
          value['examType'],
          100,
          reason: JwCollectionRejectionReason.examFields,
          diagnostics: d,
        );
        final interval = _interval(
          value,
          reason: JwCollectionRejectionReason.examFields,
          diagnostics: d,
        );
        final key =
            'exam-${fingerprint([course, type, value['date'], value['startMinute']])}';
        final draft = JwEventDraft(
          externalId: key,
          kind: JwEventKind.exam,
          title: _text(
            value['title'],
            300,
            reason: JwCollectionRejectionReason.examFields,
            diagnostics: d,
          ),
          startsAtUtc: interval.$1,
          endsAtUtc: interval.$2,
        );
        final previous = seen[key];
        if (previous != null) {
          if (_sameEvent(previous, draft)) continue;
          _reject(
            JwCollectionRejectionReason.duplicateExamKey,
            diagnostics: d,
            duplicateIdentical: false,
          );
        }
        seen[key] = draft;
        events.add(draft);
      }
      return JwCollectionReply._(
        probe,
        semester,
        events,
        normalization: JwCollectionNormalization._(
          courseRows: courses.length,
          courseEvents: courseEvents,
          examRows: exams.length,
          examEvents: events.length - courseEvents,
        ),
      );
    } on JwCollectionValidationFailure {
      rethrow;
    } on AppFailure catch (failure) {
      if (failure.code == FailureCode.invalidSnapshot) {
        _reject(JwCollectionRejectionReason.projectionInvalid);
      }
      rethrow;
    } catch (_) {
      _reject(JwCollectionRejectionReason.projectionInvalid);
    }
  }

  static bool _keys(Map<String, dynamic> value, Set<String> keys) =>
      value.length == keys.length && value.keys.every(keys.contains);
  static bool _isPositiveId(Object? value) =>
      value is int && value > 0 && value <= 2147483647;

  static bool _sameEvent(JwEventDraft left, JwEventDraft right) =>
      left.externalId == right.externalId &&
      left.kind == right.kind &&
      left.semesterId == right.semesterId &&
      left.title == right.title &&
      left.startsAtUtc == right.startsAtUtc &&
      left.endsAtUtc == right.endsAtUtc;

  static String _text(
    Object? value,
    int maximum, {
    required JwCollectionRejectionReason reason,
    required JwDataDiagnostics diagnostics,
  }) {
    if (value is! String ||
        value.trim().isEmpty ||
        value.length > maximum ||
        RegExp(r'[\x00-\x08\x0e-\x1f\x7f-\x9f]').hasMatch(value)) {
      _reject(reason, diagnostics: diagnostics);
    }
    return value.trim();
  }

  static (DateTime, DateTime) _interval(
    Map<String, dynamic> value, {
    required JwCollectionRejectionReason reason,
    required JwDataDiagnostics diagnostics,
  }) {
    final date = value['date'],
        start = value['startMinute'],
        end = value['endMinute'];
    if (date is! String ||
        !RegExp(r'^[1-9][0-9]{3}-[0-9]{2}-[0-9]{2}$').hasMatch(date) ||
        start is! int ||
        end is! int ||
        start < 0 ||
        end <= start ||
        end > 1439) {
      _reject(reason, diagnostics: diagnostics);
    }
    final parts = date.split('-').map(int.parse).toList();
    final midnight = DateTime.utc(parts[0], parts[1], parts[2]);
    if (midnight.year != parts[0] ||
        midnight.month != parts[1] ||
        midnight.day != parts[2]) {
      _reject(reason, diagnostics: diagnostics);
    }
    return (
      midnight.add(Duration(minutes: start - 480)),
      midnight.add(Duration(minutes: end - 480)),
    );
  }

  static Never _reject(
    JwCollectionRejectionReason reason, {
    JwDataDiagnostics? diagnostics,
    bool? duplicateIdentical,
  }) => throw JwCollectionValidationFailure(
    reason,
    diagnostics: diagnostics,
    duplicateIdentical: duplicateIdentical,
  );
  @override
  String toString() => 'JwCollectionReply';
}

/// Immutable C1 -> C2 -> C3 handoff, sealed while its document is still current.
/// Course scope is complete for the selected semester. Exams are observed rows;
/// their absence does not establish historical completeness.
final class JwCollectedArtifact {
  JwCollectedArtifact._({
    required this.stamp,
    required this.partition,
    required this.session,
    required this.document,
    required this.semesterId,
    required this.collectedAtUtc,
    required this.events,
    required this.normalization,
    required this._accountCode,
  });
  factory JwCollectedArtifact.seal({
    required JwCollectionReply reply,
    required JwWorkStamp stamp,
    required JwPartitionRef partition,
    required int session,
    required int document,
    required int semesterId,
    required DateTime collectedAtUtc,
  }) {
    if (reply.probe.phase != JwProbePhase.done ||
        reply.probe.code != JwDataProbeCode.ok ||
        reply.probe.accountCode == null ||
        reply.normalization == null ||
        reply.semesterId != semesterId ||
        session <= 0 ||
        document <= 0 ||
        partition.ownerId != stamp.ownerId ||
        partition.resetEpoch != stamp.resetEpoch ||
        !collectedAtUtc.isUtc) {
      throw JwCollectionValidationFailure(
        JwCollectionRejectionReason.sealMetadataMismatch,
        diagnostics: reply.probe.diagnostics,
      );
    }
    return JwCollectedArtifact._(
      stamp: stamp,
      partition: partition,
      session: session,
      document: document,
      semesterId: semesterId,
      collectedAtUtc: collectedAtUtc,
      events: reply.events,
      normalization: reply.normalization!,
      accountCode: reply.probe.accountCode!,
    );
  }
  final JwWorkStamp stamp;
  final JwPartitionRef partition;
  final int session;
  final int document;
  final int semesterId;
  final DateTime collectedAtUtc;
  final List<JwEventDraft> events;
  final JwCollectionNormalization normalization;
  final String _accountCode;
  String get sourceKey => jwSourceKey;
  String get contractVersion => jwContractVersion;
  bool matchesExpected(String expected) => _accountCode == expected;
  int get courseCount =>
      events.where((e) => e.kind == JwEventKind.course).length;
  int get examCount => events.length - courseCount;
  String get contentFingerprint {
    final sorted = events.toList()
      ..sort((a, b) => a.externalId.compareTo(b.externalId));
    return fingerprint([
      sourceKey,
      contractVersion,
      _accountCode,
      semesterId,
      'complete-course-observed-exams',
      sorted.map((e) => e.canonicalFields).toList(),
    ]);
  }

  @override
  String toString() => 'JwCollectedArtifact';
}

abstract interface class JwCollectionBrowserPort {
  Future<JwCollectionReply> startJwCollection({
    required int session,
    required int document,
    required int operation,
    required int semesterId,
  });
  Future<JwCollectionReply> pollJwCollection({
    required int session,
    required int document,
    required int operation,
  });
  Future<JwCollectionReply> cancelJwCollection({
    required int session,
    required int document,
    required int operation,
  });
}

final class JwCollectionException implements Exception {
  const JwCollectionException(this.code);
  final JwDataProbeCode code;
  @override
  String toString() => 'JwCollectionException(${code.wire})';
}
