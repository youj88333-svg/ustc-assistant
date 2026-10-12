import 'jw_data_probe_contract.dart';

enum JwCollectionRejectionReason {
  projectionInvalid,
  proofInvalid,
  selfRouteUnbound,
  snapshotShape,
  eventCount,
  courseFields,
  duplicateCourseKey,
  examFields,
  duplicateExamKey,
  sealMetadataMismatch,
}

/// A closed diagnostic projection: no identity, event value or response text.
final class JwCollectionValidationFailure implements Exception {
  const JwCollectionValidationFailure(
    this.reason, {
    this.diagnostics,
    this.duplicateIdentical,
  });

  final JwCollectionRejectionReason reason;
  final JwDataDiagnostics? diagnostics;
  final bool? duplicateIdentical;

  Map<String, Object> get safeProjection => {
    'reason': reason.name,
    if (diagnostics != null) 'dataChecks': diagnostics!.safeProjection,
    'duplicateIdentical': ?duplicateIdentical,
  };

  @override
  String toString() => 'JwCollectionValidationFailure(${reason.name})';
}
