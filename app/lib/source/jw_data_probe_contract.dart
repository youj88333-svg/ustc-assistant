import 'dart:convert';

import '../core/contracts.dart';
import 'jw_probe_contract.dart';

enum JwDataProbeCode {
  pending,
  ok,
  cancelled,
  studentContextMissing,
  identityHttp,
  identityMime,
  identityTooLarge,
  identitySchema,
  courseHttp,
  courseMime,
  courseTooLarge,
  courseSchema,
  indexHttp,
  indexMime,
  indexTooLarge,
  indexSchema,
  datumHttp,
  datumMime,
  datumTooLarge,
  datumSchema,
  examsHttp,
  examsMime,
  examsTooLarge,
  examsSchema,
  networkFailed,
  timedOut,
  helperUnavailable,
  staleResult,
  serviceWorkerControlled,
  semesterUnknown,
  identityChanged;

  String get wire => switch (this) {
    JwDataProbeCode.pending => 'pending',
    JwDataProbeCode.ok => 'ok',
    JwDataProbeCode.cancelled => 'cancelled',
    JwDataProbeCode.studentContextMissing => 'student_context_missing',
    JwDataProbeCode.identityHttp => 'identity_http',
    JwDataProbeCode.identityMime => 'identity_mime',
    JwDataProbeCode.identityTooLarge => 'identity_too_large',
    JwDataProbeCode.identitySchema => 'identity_schema',
    JwDataProbeCode.courseHttp => 'course_http',
    JwDataProbeCode.courseMime => 'course_mime',
    JwDataProbeCode.courseTooLarge => 'course_too_large',
    JwDataProbeCode.courseSchema => 'course_schema',
    JwDataProbeCode.indexHttp => 'index_http',
    JwDataProbeCode.indexMime => 'index_mime',
    JwDataProbeCode.indexTooLarge => 'index_too_large',
    JwDataProbeCode.indexSchema => 'index_schema',
    JwDataProbeCode.datumHttp => 'datum_http',
    JwDataProbeCode.datumMime => 'datum_mime',
    JwDataProbeCode.datumTooLarge => 'datum_too_large',
    JwDataProbeCode.datumSchema => 'datum_schema',
    JwDataProbeCode.examsHttp => 'exams_http',
    JwDataProbeCode.examsMime => 'exams_mime',
    JwDataProbeCode.examsTooLarge => 'exams_too_large',
    JwDataProbeCode.examsSchema => 'exams_schema',
    JwDataProbeCode.networkFailed => 'network_failed',
    JwDataProbeCode.timedOut => 'timed_out',
    JwDataProbeCode.helperUnavailable => 'helper_unavailable',
    JwDataProbeCode.staleResult => 'stale_result',
    JwDataProbeCode.serviceWorkerControlled => 'service_worker_controlled',
    JwDataProbeCode.semesterUnknown => 'semester_unknown',
    JwDataProbeCode.identityChanged => 'identity_changed',
  };

  static JwDataProbeCode decode(String wire) => switch (wire) {
    'pending' => JwDataProbeCode.pending,
    'ok' => JwDataProbeCode.ok,
    'cancelled' => JwDataProbeCode.cancelled,
    'student_context_missing' => JwDataProbeCode.studentContextMissing,
    'identity_http' => JwDataProbeCode.identityHttp,
    'identity_mime' => JwDataProbeCode.identityMime,
    'identity_too_large' => JwDataProbeCode.identityTooLarge,
    'identity_schema' => JwDataProbeCode.identitySchema,
    'course_http' => JwDataProbeCode.courseHttp,
    'course_mime' => JwDataProbeCode.courseMime,
    'course_too_large' => JwDataProbeCode.courseTooLarge,
    'course_schema' => JwDataProbeCode.courseSchema,
    'index_http' => JwDataProbeCode.indexHttp,
    'index_mime' => JwDataProbeCode.indexMime,
    'index_too_large' => JwDataProbeCode.indexTooLarge,
    'index_schema' => JwDataProbeCode.indexSchema,
    'datum_http' => JwDataProbeCode.datumHttp,
    'datum_mime' => JwDataProbeCode.datumMime,
    'datum_too_large' => JwDataProbeCode.datumTooLarge,
    'datum_schema' => JwDataProbeCode.datumSchema,
    'exams_http' => JwDataProbeCode.examsHttp,
    'exams_mime' => JwDataProbeCode.examsMime,
    'exams_too_large' => JwDataProbeCode.examsTooLarge,
    'exams_schema' => JwDataProbeCode.examsSchema,
    'network_failed' => JwDataProbeCode.networkFailed,
    'timed_out' => JwDataProbeCode.timedOut,
    'helper_unavailable' => JwDataProbeCode.helperUnavailable,
    'stale_result' => JwDataProbeCode.staleResult,
    'service_worker_controlled' => JwDataProbeCode.serviceWorkerControlled,
    'semester_unknown' => JwDataProbeCode.semesterUnknown,
    'identity_changed' => JwDataProbeCode.identityChanged,
    _ => throw const AppFailure(FailureCode.invalidSnapshot),
  };
}

/// Closed, value-free diagnostics for the fixed read-only data probe.
final class JwDataDiagnostics {
  JwDataDiagnostics({
    Map<String, String> checks = const {},
    this.reason = 'none',
    this.identityReads = 0,
    this.lessonIds = 0,
    this.lessons = 0,
    this.groups = 0,
    this.schedules = 0,
    this.datedSchedules = 0,
    this.timedSchedules = 0,
    this.linkedSchedules = 0,
    this.examRows = 0,
    this.datedExams = 0,
    this.semesterAccepted = false,
    this.selfRouteBound = false,
    this.identityStable = false,
    this.emptyCourse = false,
    this.emptyExams = false,
    this.pagination = false,
    Map<String, String> types = const {},
  }) : checks = Map.unmodifiable(_fixedValues(checks, _checkKeys, 'pending')),
       types = Map.unmodifiable(_fixedValues(types, _typeKeys, 'missing'));

  static const Set<String> reasons = {
    'none',
    'semester_unknown',
    'identity_missing',
    'identity_changed',
    'index_shape',
    'index_ids',
    'index_limit',
    'json_invalid',
    'json_duplicate',
    'json_depth',
    'datum_shape',
    'datum_limit',
    'lesson_id',
    'lesson_set',
    'lesson_title',
    'group_id',
    'group_lesson',
    'schedule_link',
    'schedule_date',
    'schedule_time',
    'exam_structure',
    'exam_pagination',
    'exam_date',
    'exam_time',
    'field_conflict',
  };

  static const Set<String> _checkKeys = {
    'identityBefore',
    'course',
    'index',
    'datum',
    'exams',
    'identityAfter',
  };
  static const Set<String> _typeKeys = {
    'lessonIds',
    'lessonList',
    'scheduleGroupList',
    'scheduleList',
    'date',
    'startTime',
    'endTime',
  };
  static const Set<String> _checkValues = {'pending', 'ok', 'skipped', 'error'};
  static const Set<String> _typeValues = {
    'missing',
    'null',
    'object',
    'array',
    'string',
    'number',
    'boolean',
    'mixed',
  };
  static const Set<String> _keys = {
    'checks',
    'reason',
    'identityReads',
    'lessonIds',
    'lessons',
    'groups',
    'schedules',
    'datedSchedules',
    'timedSchedules',
    'linkedSchedules',
    'examRows',
    'datedExams',
    'semesterAccepted',
    'selfRouteBound',
    'identityStable',
    'emptyCourse',
    'emptyExams',
    'pagination',
    'types',
  };

  final Map<String, String> checks;
  final String reason;
  final int identityReads;
  final int lessonIds;
  final int lessons;
  final int groups;
  final int schedules;
  final int datedSchedules;
  final int timedSchedules;
  final int linkedSchedules;
  final int examRows;
  final int datedExams;
  final bool semesterAccepted;
  final bool selfRouteBound;
  final bool identityStable;
  final bool emptyCourse;
  final bool emptyExams;
  final bool pagination;
  final Map<String, String> types;

  Map<String, Object> get safeProjection => {
    'checks': {
      for (final key in _checkKeys)
        key: _checkValues.contains(checks[key]) ? checks[key]! : 'error',
    },
    'reason': reasons.contains(reason) ? reason : 'field_conflict',
    'identityReads': _count(identityReads),
    'lessonIds': _count(lessonIds),
    'lessons': _count(lessons),
    'groups': _count(groups),
    'schedules': _count(schedules),
    'datedSchedules': _count(datedSchedules),
    'timedSchedules': _count(timedSchedules),
    'linkedSchedules': _count(linkedSchedules),
    'examRows': _count(examRows),
    'datedExams': _count(datedExams),
    'semesterAccepted': semesterAccepted,
    'selfRouteBound': selfRouteBound,
    'identityStable': identityStable,
    'emptyCourse': emptyCourse,
    'emptyExams': emptyExams,
    'pagination': pagination,
    'types': {
      for (final key in _typeKeys)
        key: _typeValues.contains(types[key]) ? types[key]! : 'mixed',
    },
  };

  @override
  String toString() => 'JwDataDiagnostics';

  static Map<String, String> _fixedValues(
    Map<String, String> input,
    Set<String> keys,
    String fallback,
  ) => {for (final key in keys) key: input[key] ?? fallback};

  static int _count(int value) => value.clamp(0, 10000).toInt();
}

final class JwDataProbeReply {
  const JwDataProbeReply._({
    required this.phase,
    required this.code,
    required this.operation,
    required this.identityCandidateCount,
    required this.identityMethod,
    required this._accountCode,
    required this.stage,
    required this.diagnostics,
  });

  static const int _maxProjectionChars = 256 * 1024;
  static const int _maxSafeInteger = 9007199254740991;
  static const int _maxIdentityCandidates = 32;
  static const Set<String> _envelopeKeys = {
    'operation',
    'phase',
    'code',
    'stage',
    'identity',
    'diagnostics',
  };
  static const Set<String> _identityKeys = {
    'candidateCount',
    'method',
    'accountCode',
  };
  static const Set<String> _stages = {
    'identityBefore',
    'course',
    'index',
    'datum',
    'exams',
    'identityAfter',
  };
  static const Set<String> _identityMethods = {
    'none',
    'table',
    'definitionList',
    'listGroup',
    'label',
    'mixed',
  };

  final JwProbePhase phase;
  final JwDataProbeCode code;
  final int operation;
  final int identityCandidateCount;
  final String? identityMethod;
  final String? _accountCode;
  final String? stage;
  final JwDataDiagnostics? diagnostics;

  /// The caller may compare this privately; presentation code must not expose it.
  String? get accountCode => _accountCode;

  factory JwDataProbeReply.decode(String json, {required int operation}) {
    if (json.length > _maxProjectionChars) _invalid();
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map<String, dynamic>) _invalid();
      return _decodeMap(decoded, expectedOperation: operation);
    } on AppFailure {
      rethrow;
    } catch (_) {
      _invalid();
    }
  }

  static JwDataProbeReply _decodeMap(
    Map<String, dynamic> root, {
    required int expectedOperation,
  }) {
    _onlyKeys(root, _envelopeKeys);
    if (expectedOperation <= 0 || expectedOperation > _maxSafeInteger) {
      _invalid();
    }
    final operation = root['operation'];
    if (operation is! int ||
        operation <= 0 ||
        operation > _maxSafeInteger ||
        operation != expectedOperation) {
      _invalid();
    }

    final phaseWire = root['phase'];
    if (phaseWire is! String || phaseWire == 'idle') _invalid();
    final phase = JwProbePhase.decode(phaseWire);
    final codeWire = root['code'];
    if (codeWire is! String) _invalid();
    final code = JwDataProbeCode.decode(codeWire);
    if (!_phaseCodeMatches(phase, code)) _invalid();

    final stageValue = root['stage'];
    if (stageValue != null &&
        (stageValue is! String || !_stages.contains(stageValue))) {
      _invalid();
    }

    var candidateCount = 0;
    String? identityMethod;
    String? accountCode;
    if (root.containsKey('identity')) {
      final identity = root['identity'];
      if (identity is! Map<String, dynamic>) _invalid();
      _onlyKeys(identity, _identityKeys);
      final count = identity['candidateCount'];
      final method = identity['method'];
      if (count is! int ||
          count < 0 ||
          count > _maxIdentityCandidates ||
          method is! String ||
          !_identityMethods.contains(method)) {
        _invalid();
      }
      candidateCount = count;
      identityMethod = method;
      if (count == 1) {
        if (!_hasExactlyKeys(identity, const {
          'candidateCount',
          'method',
          'accountCode',
        })) {
          _invalid();
        }
        final value = identity['accountCode'];
        if (value is! String || !RegExp(r'^[A-Z0-9]{5,24}$').hasMatch(value)) {
          _invalid();
        }
        accountCode = value;
      } else if (!_hasExactlyKeys(identity, const {
        'candidateCount',
        'method',
      })) {
        _invalid();
      }
    }

    final diagnostics = root.containsKey('diagnostics')
        ? _decodeDiagnostics(root['diagnostics'])
        : null;
    return JwDataProbeReply._(
      phase: phase,
      code: code,
      operation: operation,
      identityCandidateCount: candidateCount,
      identityMethod: identityMethod,
      accountCode: accountCode,
      stage: stageValue as String?,
      diagnostics: diagnostics,
    );
  }

  static JwDataDiagnostics _decodeDiagnostics(Object? value) {
    if (value is! Map<String, dynamic> ||
        !_hasExactlyKeys(value, JwDataDiagnostics._keys)) {
      _invalid();
    }
    final checksValue = value['checks'];
    final typesValue = value['types'];
    if (checksValue is! Map<String, dynamic> ||
        !_hasExactlyKeys(checksValue, JwDataDiagnostics._checkKeys) ||
        typesValue is! Map<String, dynamic> ||
        !_hasExactlyKeys(typesValue, JwDataDiagnostics._typeKeys)) {
      _invalid();
    }
    final checks = <String, String>{};
    for (final key in JwDataDiagnostics._checkKeys) {
      final state = checksValue[key];
      if (state is! String || !JwDataDiagnostics._checkValues.contains(state)) {
        _invalid();
      }
      checks[key] = state;
    }
    final reason = value['reason'];
    if (reason is! String || !JwDataDiagnostics.reasons.contains(reason)) {
      _invalid();
    }
    final types = <String, String>{};
    for (final key in JwDataDiagnostics._typeKeys) {
      final type = typesValue[key];
      if (type is! String || !JwDataDiagnostics._typeValues.contains(type)) {
        _invalid();
      }
      types[key] = type;
    }
    return JwDataDiagnostics(
      checks: checks,
      reason: reason,
      identityReads: _boundedCount(value['identityReads']),
      lessonIds: _boundedCount(value['lessonIds']),
      lessons: _boundedCount(value['lessons']),
      groups: _boundedCount(value['groups']),
      schedules: _boundedCount(value['schedules']),
      datedSchedules: _boundedCount(value['datedSchedules']),
      timedSchedules: _boundedCount(value['timedSchedules']),
      linkedSchedules: _boundedCount(value['linkedSchedules']),
      examRows: _boundedCount(value['examRows']),
      datedExams: _boundedCount(value['datedExams']),
      semesterAccepted: _requiredBool(value['semesterAccepted']),
      selfRouteBound: _requiredBool(value['selfRouteBound']),
      identityStable: _requiredBool(value['identityStable']),
      emptyCourse: _requiredBool(value['emptyCourse']),
      emptyExams: _requiredBool(value['emptyExams']),
      pagination: _requiredBool(value['pagination']),
      types: types,
    );
  }

  static bool _phaseCodeMatches(JwProbePhase phase, JwDataProbeCode code) =>
      switch (phase) {
        JwProbePhase.idle => false,
        JwProbePhase.running =>
          code == JwDataProbeCode.pending ||
              code == JwDataProbeCode.cancelled ||
              code == JwDataProbeCode.serviceWorkerControlled,
        JwProbePhase.done => code == JwDataProbeCode.ok,
        JwProbePhase.cancelled => code == JwDataProbeCode.cancelled,
        JwProbePhase.failed =>
          code != JwDataProbeCode.pending &&
              code != JwDataProbeCode.ok &&
              code != JwDataProbeCode.cancelled,
      };

  static int _boundedCount(Object? value) {
    if (value is! int || value < 0 || value > 10000) _invalid();
    return value;
  }

  static bool _requiredBool(Object? value) {
    if (value is! bool) _invalid();
    return value;
  }

  static void _onlyKeys(Map<String, dynamic> value, Set<String> allowed) {
    if (value.keys.any((key) => !allowed.contains(key))) _invalid();
  }

  static bool _hasExactlyKeys(
    Map<String, dynamic> value,
    Set<String> required,
  ) =>
      value.length == required.length &&
      value.keys.every((key) => required.contains(key));

  static Never _invalid() =>
      throw const AppFailure(FailureCode.invalidSnapshot);

  @override
  String toString() => 'JwDataProbeReply';
}

abstract interface class JwDataProbeBrowserPort {
  Future<JwDataProbeReply> startJwDataProbe({
    required int session,
    required int document,
    required int operation,
    required int semesterId,
  });

  Future<JwDataProbeReply> pollJwDataProbe({
    required int session,
    required int document,
    required int operation,
  });

  Future<JwDataProbeReply> cancelJwDataProbe({
    required int session,
    required int document,
    required int operation,
  });
}
