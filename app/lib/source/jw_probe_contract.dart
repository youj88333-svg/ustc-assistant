import 'dart:convert';

import '../core/contracts.dart';

enum JwProbePhase {
  idle,
  running,
  done,
  failed,
  cancelled;

  String get wire => switch (this) {
    JwProbePhase.idle => 'idle',
    JwProbePhase.running => 'running',
    JwProbePhase.done => 'done',
    JwProbePhase.failed => 'failed',
    JwProbePhase.cancelled => 'cancelled',
  };

  static JwProbePhase decode(String wire) => switch (wire) {
    'idle' => JwProbePhase.idle,
    'running' => JwProbePhase.running,
    'done' => JwProbePhase.done,
    'failed' => JwProbePhase.failed,
    'cancelled' => JwProbePhase.cancelled,
    _ => throw const AppFailure(FailureCode.invalidSnapshot),
  };
}

enum JwProbeCode {
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
  examsHttp,
  examsMime,
  examsTooLarge,
  examsSchema,
  networkFailed,
  timedOut,
  helperUnavailable,
  staleResult,
  serviceWorkerControlled;

  String get wire => switch (this) {
    JwProbeCode.pending => 'pending',
    JwProbeCode.ok => 'ok',
    JwProbeCode.cancelled => 'cancelled',
    JwProbeCode.studentContextMissing => 'student_context_missing',
    JwProbeCode.identityHttp => 'identity_http',
    JwProbeCode.identityMime => 'identity_mime',
    JwProbeCode.identityTooLarge => 'identity_too_large',
    JwProbeCode.identitySchema => 'identity_schema',
    JwProbeCode.courseHttp => 'course_http',
    JwProbeCode.courseMime => 'course_mime',
    JwProbeCode.courseTooLarge => 'course_too_large',
    JwProbeCode.courseSchema => 'course_schema',
    JwProbeCode.examsHttp => 'exams_http',
    JwProbeCode.examsMime => 'exams_mime',
    JwProbeCode.examsTooLarge => 'exams_too_large',
    JwProbeCode.examsSchema => 'exams_schema',
    JwProbeCode.networkFailed => 'network_failed',
    JwProbeCode.timedOut => 'timed_out',
    JwProbeCode.helperUnavailable => 'helper_unavailable',
    JwProbeCode.staleResult => 'stale_result',
    JwProbeCode.serviceWorkerControlled => 'service_worker_controlled',
  };

  static JwProbeCode decode(String wire) => switch (wire) {
    'pending' => JwProbeCode.pending,
    'ok' => JwProbeCode.ok,
    'cancelled' => JwProbeCode.cancelled,
    'student_context_missing' => JwProbeCode.studentContextMissing,
    'identity_http' => JwProbeCode.identityHttp,
    'identity_mime' => JwProbeCode.identityMime,
    'identity_too_large' => JwProbeCode.identityTooLarge,
    'identity_schema' => JwProbeCode.identitySchema,
    'course_http' => JwProbeCode.courseHttp,
    'course_mime' => JwProbeCode.courseMime,
    'course_too_large' => JwProbeCode.courseTooLarge,
    'course_schema' => JwProbeCode.courseSchema,
    'exams_http' => JwProbeCode.examsHttp,
    'exams_mime' => JwProbeCode.examsMime,
    'exams_too_large' => JwProbeCode.examsTooLarge,
    'exams_schema' => JwProbeCode.examsSchema,
    'network_failed' => JwProbeCode.networkFailed,
    'timed_out' => JwProbeCode.timedOut,
    'helper_unavailable' => JwProbeCode.helperUnavailable,
    'stale_result' => JwProbeCode.staleResult,
    'service_worker_controlled' => JwProbeCode.serviceWorkerControlled,
    _ => throw const AppFailure(FailureCode.invalidSnapshot),
  };
}

final class JwSemesterOption {
  const JwSemesterOption({
    required this.id,
    required this.name,
    required this.selected,
  });

  final int id;
  final String name;
  final bool selected;
}

/// Closed diagnostic metadata. It never contains a semester value or script.
final class JwCourseDiagnostics {
  const JwCourseDiagnostics({
    this.reason = 'none',
    this.source = 'none',
    this.serverOptions = 0,
    this.liveOptions = 0,
    this.literalAssignments = 0,
    this.literalItems = 0,
    this.literalParsed = false,
  });

  static const reasons = {
    'none',
    'select_missing',
    'select_conflict',
    'options_empty',
    'options_limit',
    'option_value',
    'option_duplicate',
    'option_name',
    'selected_conflict',
    'literal_missing',
    'literal_duplicate',
    'literal_unsupported',
    'literal_invalid',
    'literal_limit',
    'literal_key_conflict',
    'catalog_empty',
    'catalog_limit',
    'catalog_id',
    'catalog_duplicate',
    'catalog_name',
    'selection_missing',
    'selection_invalid',
    'selection_unknown',
  };
  static const sources = {'none', 'serverSelect', 'serverJson'};
  static const _keys = {
    'reason',
    'source',
    'serverOptions',
    'liveOptions',
    'literalAssignments',
    'literalItems',
    'literalParsed',
  };

  final String reason;
  final String source;
  final int serverOptions;
  final int liveOptions;
  final int literalAssignments;
  final int literalItems;
  final bool literalParsed;

  Map<String, Object> get safeProjection => {
    'reason': reasons.contains(reason) ? reason : 'literal_invalid',
    'source': sources.contains(source) ? source : 'none',
    'serverOptions': serverOptions.clamp(0, 10000),
    'liveOptions': liveOptions.clamp(0, 10000),
    'literalAssignments': literalAssignments.clamp(0, 10000),
    'literalItems': literalItems.clamp(0, 10000),
    'literalParsed': literalParsed,
  };

  @override
  String toString() => 'JwCourseDiagnostics';
}

final class JwProbeSummary {
  JwProbeSummary({
    required this.identityLabels,
    required this.semesterOptions,
    required this.examTables,
    required this.examRows,
    required this.semesterSelect,
    required this.examHeader,
    required this.pagination,
    required Map<String, bool> semesterVariables,
    this.courseDiagnostics = const JwCourseDiagnostics(),
    Map<String, JwProbeCode> stageResults = const {
      'identity': JwProbeCode.pending,
      'course': JwProbeCode.pending,
      'exams': JwProbeCode.pending,
    },
  }) : semesterVariables = Map.unmodifiable(semesterVariables),
       stageResults = Map.unmodifiable(stageResults);

  final int identityLabels;
  final int semesterOptions;
  final int examTables;
  final int examRows;
  final bool semesterSelect;
  final bool examHeader;
  final bool pagination;
  final Map<String, bool> semesterVariables;
  final Map<String, JwProbeCode> stageResults;
  final JwCourseDiagnostics courseDiagnostics;

  @override
  String toString() => 'JwProbeSummary';
}

final class JwProbeReply {
  JwProbeReply._({
    required this.phase,
    required this.code,
    required this.operation,
    required this.identityCandidateCount,
    required this._accountCode,
    required this.summary,
    required List<JwSemesterOption>? semesters,
    required this.stage,
  }) : semesters = semesters == null ? null : List.unmodifiable(semesters);

  // Includes escaped labels for a full, bounded semester catalog.
  static const int _maxProjectionChars = 256 * 1024;
  static const int _maxCount = 10000;
  static const int _maxSemesterOptions = 256;
  static const int _maxExamTables = 10;
  static const Set<String> _envelopeKeys = {
    'operation',
    'phase',
    'code',
    'stage',
    'identity',
    'summary',
    'semesters',
  };
  static const Set<String> _identityKeys = {
    'candidateCount',
    'accountCode',
    'method',
  };
  static const Set<String> _summaryKeys = {
    'identityLabels',
    'semesterOptions',
    'examTables',
    'examRows',
    'semesterSelect',
    'examHeader',
    'pagination',
    'semesterVariables',
    'stageResults',
    'courseDiagnostics',
  };
  static const Set<String> _semesterKeys = {'id', 'name', 'selected'};
  static const Set<String> _semesterVariableKeys = {
    'allSemesters',
    'semesters',
    'semesterId',
    'bizTypeId',
  };
  static const Set<String> _identityMethods = {
    'none',
    'table',
    'definitionList',
    'listGroup',
    'label',
    'mixed',
  };
  static const Set<String> _stages = {'identity', 'course', 'exams'};

  final JwProbePhase phase;
  final JwProbeCode code;
  final int operation;
  final int identityCandidateCount;
  final String? _accountCode;
  final JwProbeSummary? summary;
  final List<JwSemesterOption>? semesters;
  final String? stage;

  /// The C3 verifier consumes this candidate; UI and presentation code should
  /// use only [identityCandidateCount].
  String? get accountCode => _accountCode;

  factory JwProbeReply.decode(String json, {required int operation}) {
    if (json.length > _maxProjectionChars) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map<String, dynamic>) _invalid();
      return _decodeMap(decoded, expectedOperation: operation);
    } on AppFailure {
      rethrow;
    } catch (_) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
  }

  static JwProbeReply _decodeMap(
    Map<String, dynamic> root, {
    required int expectedOperation,
  }) {
    _onlyKeys(root, _envelopeKeys);
    final operation = root['operation'];
    if (expectedOperation <= 0 ||
        operation is! int ||
        operation <= 0 ||
        operation != expectedOperation) {
      _invalid();
    }

    final phaseWire = root['phase'];
    if (phaseWire is! String || phaseWire == 'idle') _invalid();
    final phase = JwProbePhase.decode(phaseWire);
    final codeWire = root['code'];
    if (codeWire is! String) _invalid();
    final code = JwProbeCode.decode(codeWire);

    final stage = root['stage'];
    if (stage != null && (stage is! String || !_stages.contains(stage))) {
      _invalid();
    }

    var candidateCount = 0;
    String? accountCode;
    if (root.containsKey('identity')) {
      final identity = root['identity'];
      if (identity is! Map<String, dynamic>) _invalid();
      _onlyKeys(identity, _identityKeys);
      final count = identity['candidateCount'];
      if (count is! int || count < 0 || count > _maxCount) _invalid();
      final method = identity['method'];
      if (method is! String || !_identityMethods.contains(method)) _invalid();
      candidateCount = count;
      if (identity.containsKey('accountCode')) {
        final value = identity['accountCode'];
        if (count != 1 ||
            value is! String ||
            !RegExp(r'^[A-Z0-9]{5,24}$').hasMatch(value)) {
          _invalid();
        }
        accountCode = value;
      }
    }

    final summary = root.containsKey('summary')
        ? _decodeSummary(root['summary'])
        : null;
    if (summary != null && summary.identityLabels != candidateCount) {
      _invalid();
    }

    final semesters = root.containsKey('semesters')
        ? _decodeSemesters(root['semesters'])
        : null;
    if (semesters != null) {
      if (summary == null || summary.semesterOptions != semesters.length) {
        _invalid();
      }
    }

    return JwProbeReply._(
      phase: phase,
      code: code,
      operation: operation,
      identityCandidateCount: candidateCount,
      accountCode: accountCode,
      summary: summary,
      semesters: semesters,
      stage: stage as String?,
    );
  }

  static JwProbeSummary _decodeSummary(Object? value) {
    if (value is! Map<String, dynamic>) _invalid();
    _onlyKeys(value, _summaryKeys);
    if (!_hasExactlyKeys(value, _summaryKeys)) _invalid();

    final identityLabels = _boundedCount(value['identityLabels']);
    final semesterOptions = _boundedCount(
      value['semesterOptions'],
      maximum: _maxSemesterOptions,
    );
    final examTables = _boundedCount(
      value['examTables'],
      maximum: _maxExamTables,
    );
    final examRows = _boundedCount(value['examRows']);
    final semesterSelect = value['semesterSelect'];
    final examHeader = value['examHeader'];
    final pagination = value['pagination'];
    if (semesterSelect is! bool || examHeader is! bool || pagination is! bool) {
      _invalid();
    }

    final variables = value['semesterVariables'];
    if (variables is! Map<String, dynamic>) _invalid();
    _onlyKeys(variables, _semesterVariableKeys);
    if (!_hasExactlyKeys(variables, _semesterVariableKeys)) _invalid();
    final semesterVariables = <String, bool>{};
    for (final entry in variables.entries) {
      if (entry.value is! bool) _invalid();
      semesterVariables[entry.key] = entry.value as bool;
    }

    final results = value['stageResults'];
    if (results is! Map<String, dynamic> ||
        !_hasExactlyKeys(results, _stages)) {
      _invalid();
    }
    final stageResults = <String, JwProbeCode>{};
    for (final entry in results.entries) {
      final wire = entry.value;
      if (wire is! String) _invalid();
      final code = JwProbeCode.decode(wire);
      if (!{
        'pending',
        'ok',
        'network_failed',
        'timed_out',
        'helper_unavailable',
        '${entry.key}_http',
        '${entry.key}_mime',
        '${entry.key}_too_large',
        '${entry.key}_schema',
      }.contains(wire)) {
        _invalid();
      }
      stageResults[entry.key] = code;
    }

    return JwProbeSummary(
      identityLabels: identityLabels,
      semesterOptions: semesterOptions,
      examTables: examTables,
      examRows: examRows,
      semesterSelect: semesterSelect,
      examHeader: examHeader,
      pagination: pagination,
      semesterVariables: semesterVariables,
      stageResults: stageResults,
      courseDiagnostics: _decodeCourseDiagnostics(value['courseDiagnostics']),
    );
  }

  static JwCourseDiagnostics _decodeCourseDiagnostics(Object? value) {
    if (value is! Map<String, dynamic> ||
        !_hasExactlyKeys(value, JwCourseDiagnostics._keys)) {
      _invalid();
    }
    final reason = value['reason'];
    final source = value['source'];
    final parsed = value['literalParsed'];
    if (reason is! String ||
        !JwCourseDiagnostics.reasons.contains(reason) ||
        source is! String ||
        !JwCourseDiagnostics.sources.contains(source) ||
        parsed is! bool) {
      _invalid();
    }
    return JwCourseDiagnostics(
      reason: reason,
      source: source,
      serverOptions: _boundedCount(value['serverOptions']),
      liveOptions: _boundedCount(value['liveOptions']),
      literalAssignments: _boundedCount(value['literalAssignments']),
      literalItems: _boundedCount(value['literalItems']),
      literalParsed: parsed,
    );
  }

  static List<JwSemesterOption> _decodeSemesters(Object? value) {
    if (value is! List || value.length > _maxSemesterOptions) _invalid();
    final result = <JwSemesterOption>[];
    final ids = <int>{};
    var selectedCount = 0;
    for (final item in value) {
      if (item is! Map<String, dynamic>) _invalid();
      _onlyKeys(item, _semesterKeys);
      if (!_hasExactlyKeys(item, _semesterKeys)) _invalid();
      final id = item['id'];
      final name = item['name'];
      final selected = item['selected'];
      if (id is! int || id <= 0 || id > 2147483647 || !ids.add(id)) {
        _invalid();
      }
      if (name is! String || !_validSemesterName(name)) _invalid();
      if (selected is! bool) _invalid();
      if (selected) selectedCount++;
      result.add(JwSemesterOption(id: id, name: name, selected: selected));
    }
    if (selectedCount > 1) _invalid();
    return result;
  }

  static int _boundedCount(Object? value, {int maximum = _maxCount}) {
    if (value is! int || value < 0 || value > maximum) _invalid();
    return value;
  }

  static bool _validSemesterName(String value) {
    final length = value.runes.length;
    return length >= 1 &&
        length <= 120 &&
        !RegExp(r'[\x00-\x1F\x7F-\x9F<>]').hasMatch(value);
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
  String toString() => 'JwProbeReply';
}

abstract interface class JwProbeBrowserPort {
  Future<JwProbeReply> startJwProbe({
    required int session,
    required int document,
    required int operation,
  });

  Future<JwProbeReply> pollJwProbe({
    required int session,
    required int document,
    required int operation,
  });

  Future<JwProbeReply> cancelJwProbe({
    required int session,
    required int document,
    required int operation,
  });
}
