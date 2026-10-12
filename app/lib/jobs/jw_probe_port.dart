import 'dart:convert';

import '../core/contracts.dart';
import '../data/jw_candidate_identity.dart';
import '../source/jw_probe_contract.dart';

/// Public verification progress contains no account value or response text.
final class JwProbeView {
  const JwProbeView({
    this.phase = JwProbePhase.idle,
    this.code = JwProbeCode.pending,
    this.identity = JwCandidateIdentity.unavailable,
    this.summary,
    this.semesters = const [],
    this.stage,
    this.failure,
    this.available = false,
    this.busy = false,
  });

  final JwProbePhase phase;
  final JwProbeCode code;
  final JwCandidateIdentity identity;
  final JwProbeSummary? summary;
  final List<JwSemesterOption> semesters;
  final String? stage;
  final FailureCode? failure;
  final bool available;
  final bool busy;

  /// User-shareable contract metadata. Actual student values never enter this.
  String get safeSummary => jsonEncode({
    'kind': 'jw-candidate-contract-v3',
    'phase': phase.name,
    'code': code.wire,
    'identity': identity.name,
    if (stage != null) 'stage': stage,
    if (failure != null) 'failure': failure!.name,
    'sourceAvailable': false,
    if (summary case final value?)
      'checks': {
        for (final stage in const ['identity', 'course', 'exams'])
          stage: (value.stageResults[stage] ?? JwProbeCode.pending).wire,
      },
    if (summary case final value?)
      'structure': {
        'identityLabels': value.identityLabels,
        'semesterOptions': value.semesterOptions,
        'semesterSelect': value.semesterSelect,
        'semesterVariables': value.semesterVariables,
        'examTables': value.examTables,
        'examHeader': value.examHeader,
        'examRows': value.examRows,
        'pagination': value.pagination,
        'courseDiagnostics': value.courseDiagnostics.safeProjection,
      },
  });
}

abstract interface class JwProbePort {
  JwProbeView get probeView;
  Stream<JwProbeView> get probeChanges;
  Future<void> runProbe(String expectedAccountCode);
  Future<void> cancelProbe();
}
