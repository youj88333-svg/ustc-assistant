import 'dart:convert';

import '../core/contracts.dart';
import '../core/jw_work_contract.dart';
import '../core/jw_credentials.dart';
import '../data/jw_import_contract.dart';
import '../source/jw_collection_contract.dart';
import '../source/jw_collection_failure.dart';
import '../source/jw_data_probe_contract.dart';
import '../source/jw_probe_contract.dart';
import '../source/jw_authentication_contract.dart';
import '../source/observation_contract.dart';

enum JwSyncPhase {
  idle,
  opening,
  login,
  verifying,
  collecting,
  closing,
  committing,
  recovery,
  closed,
}

enum JwAutomationState {
  none,
  waitingForLogin,
  submitting,
  preparing,
  choosingSemester,
  manualRequired,
}

final class JwSyncView {
  JwSyncView({
    this.phase = JwSyncPhase.idle,
    this.ready = false,
    this.accountBound = false,
    this.sessionRetained = false,
    this.profileReused,
    this.failure,
    this.identityFailure,
    this.sourceFailure,
    this.collectionValidation,
    this.failureStage,
    this.normalization,
    this.courseCount = 0,
    this.examCount = 0,
    this.importCommitted = false,
    this.emptyExams = false,
    List<JwSemesterOption> semesters = const [],
    this.data,
    this.automation = JwAutomationState.none,
    this.credentialFailure,
    this.loginPauseReason,
  }) : semesters = List.unmodifiable(semesters);
  final JwSyncPhase phase;
  final bool ready;
  final bool accountBound;

  /// Legacy name for a retained claimed browser profile, not valid school auth.
  final bool sessionRetained;
  bool get profileRetained => sessionRetained;

  /// Whether this job successfully opened an existing claimed profile.
  /// Null means that no browser open completed in this job; not an auth check.
  final bool? profileReused;
  final FailureCode? failure;
  final JwIdentityFailure? identityFailure;
  final JwDataProbeCode? sourceFailure;
  final JwCollectionValidationFailure? collectionValidation;
  final JwSyncPhase? failureStage;
  final JwCollectionNormalization? normalization;
  final int courseCount;
  final int examCount;
  final bool importCommitted;
  final bool emptyExams;
  final List<JwSemesterOption> semesters;
  final JwDataView? data;
  final JwAutomationState automation;
  final JwCredentialFailure? credentialFailure;
  final JwLoginPauseReason? loginPauseReason;
  bool get busy => phase != JwSyncPhase.idle && phase != JwSyncPhase.closed;
  String get safeSummary => jsonEncode({
    'kind': 'jw-import-v1',
    'phase': phase.name,
    'accountBound': accountBound,
    'sessionRetained': sessionRetained,
    'profileRetained': profileRetained,
    if (profileReused != null) 'profileReused': profileReused,
    'importCommitted': importCommitted,
    'courseCount': courseCount,
    'examCount': examCount,
    'emptyExams': emptyExams,
    if (failure != null) 'failure': failure!.name,
    if (identityFailure != null) 'identityFailure': identityFailure!.name,
    if (sourceFailure != null) 'sourceFailure': sourceFailure!.wire,
    if (collectionValidation != null)
      'collectionValidation': collectionValidation!.safeProjection,
    if (failureStage != null) 'failureStage': failureStage!.name,
    if (normalization != null) 'normalization': normalization!.safeProjection,
    'localEvents': data?.events.length ?? 0,
    'imports': data?.importCount ?? 0,
    'credentialSaved': data?.credentialSaved ?? false,
    'semesterRemembered': data?.lastSemesterId != null,
    'cachedSemesterCount': data?.cachedSemesters.length ?? 0,
    'automation': automation.name,
    if (credentialFailure != null) 'credentialFailure': credentialFailure!.name,
    if (loginPauseReason != null) 'loginReason': loginPauseReason!.name,
  });
}

/// Product commands and safe progress. Business rows stay in the local view;
/// No identity code, route, raw response or browser asset enters public progress.
abstract interface class JwSyncPort {
  JwSyncView get syncView;
  Stream<JwSyncView> get syncChanges;
  Future<void> open({String? expectedAccountCode});
  Future<void> startSync({
    String? expectedAccountCode,
    String? password,
    bool savePassword = false,
    int? semesterId,
  });
  Future<void> continueSync();
  Future<void> deleteSavedCredential();
  Future<void> navigateJwPage(JwObservationPage page);
  Future<void> verifyDirectory();
  Future<void> collect(int semesterId);
  Future<void> cancel();
  Future<void> retryRecovery();
  Future<void> clearSession();
  Future<void> setHidden({
    required int localId,
    required int expectedVersion,
    required bool hidden,
  });
}
