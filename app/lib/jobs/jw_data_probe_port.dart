import 'dart:convert';

import '../core/contracts.dart';
import '../data/jw_candidate_identity.dart';
import '../source/jw_data_probe_contract.dart';
import '../source/jw_probe_contract.dart';

/// Public data-probe progress contains only closed status and count metadata.
final class JwDataProbeView {
  const JwDataProbeView({
    this.phase = JwProbePhase.idle,
    this.code = JwDataProbeCode.pending,
    this.identity = JwCandidateIdentity.unavailable,
    this.diagnostics,
    this.stage,
    this.failure,
    this.available = false,
    this.busy = false,
  });

  static const Set<String> _stages = {
    'identityBefore',
    'course',
    'index',
    'datum',
    'exams',
    'identityAfter',
  };

  final JwProbePhase phase;
  final JwDataProbeCode code;
  final JwCandidateIdentity identity;
  final JwDataDiagnostics? diagnostics;
  final String? stage;
  final FailureCode? failure;
  final bool available;
  final bool busy;

  /// The shareable projection contains no account, semester, route, or source values.
  String get safeSummary => jsonEncode({
    'kind': 'jw-data-contract-v1',
    'phase': phase.name,
    'code': code.wire,
    'identity': identity.name,
    if (stage != null && _stages.contains(stage)) 'stage': stage,
    if (failure != null) 'failure': failure!.name,
    'sourceAvailable': false,
    if (diagnostics case final value?) 'diagnostics': value.safeProjection,
  });
}

abstract interface class JwDataProbePort {
  JwDataProbeView get dataProbeView;

  Stream<JwDataProbeView> get dataProbeChanges;

  Future<void> runDataProbe(
    String expectedAccountCode, {
    required int semesterId,
  });

  Future<void> cancelDataProbe();
}
