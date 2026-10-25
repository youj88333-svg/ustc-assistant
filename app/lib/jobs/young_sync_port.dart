import 'dart:convert';

import '../core/contracts.dart';
import '../core/jw_credentials.dart';
import '../core/young_work_contract.dart';
import '../data/young_import_contract.dart';
import '../source/jw_authentication_contract.dart';
import '../source/young_active_contract.dart';
import '../source/young_collection_contract.dart';

enum YoungSyncPhase {
  idle,
  opening,
  login,
  collecting,
  closing,
  committing,
  recovery,
  closed,
}

enum YoungAutomationState {
  none,
  waitingForLogin,
  submitting,
  preparing,
  manualRequired,
}

/// Safe product state for Young queries and linked-calendar synchronization.
///
/// Business rows are delivered through [data] and [activityResults]. They are
/// never included in [safeSummary].
final class YoungSyncView {
  YoungSyncView({
    this.phase = YoungSyncPhase.idle,
    this.kind,
    this.ready = false,
    this.accountBound = false,
    this.profileRetained = false,
    this.profileReused,
    this.committed = false,
    this.failure,
    this.identityFailure,
    this.automation = YoungAutomationState.none,
    this.credentialFailure,
    this.loginPauseReason,
    this.failureStage,
    this.collectionStage,
    this.collectionReason,
    this.normalization,
    this.data,
    List<YoungActivityView> activityResults = const <YoungActivityView>[],
  }) : activityResults = List<YoungActivityView>.unmodifiable(activityResults);

  final YoungSyncPhase phase;
  final YoungJobKind? kind;
  final bool ready;
  final bool accountBound;
  final bool profileRetained;
  final bool? profileReused;
  final bool committed;
  final FailureCode? failure;
  final YoungIdentityFailure? identityFailure;
  final YoungAutomationState automation;
  final JwCredentialFailure? credentialFailure;
  final JwLoginPauseReason? loginPauseReason;
  final YoungSyncPhase? failureStage;
  final YoungBusinessStage? collectionStage;
  final YoungBusinessRejection? collectionReason;
  final YoungCollectionStats? normalization;
  final YoungDataView? data;
  final List<YoungActivityView> activityResults;

  bool get busy =>
      phase != YoungSyncPhase.idle && phase != YoungSyncPhase.closed;

  String get safeSummary => jsonEncode(<String, Object?>{
    'kind': 'young-import-v1',
    'phase': phase.name,
    'action': kind?.name,
    'accountBound': accountBound,
    'profileRetained': profileRetained,
    'profileReused': profileReused,
    'committed': committed,
    'failure': failure?.name,
    'identityFailure': identityFailure?.name,
    'automation': automation.name,
    'credentialSaved': data?.credentialSaved ?? false,
    if (credentialFailure != null) 'credentialFailure': credentialFailure!.name,
    if (loginPauseReason != null) 'loginReason': loginPauseReason!.name,
    if (failureStage != null) 'failureStage': failureStage!.name,
    if (collectionStage != null) 'collectionStage': collectionStage!.name,
    if (collectionReason != null) 'collectionReason': collectionReason!.name,
    'normalization': normalization?.safeProjection,
    'localEvents': data?.events.length ?? 0,
    'importCount': data?.importCount ?? 0,
    'queryCount': data?.queryCount ?? 0,
  });

  @override
  String toString() => 'YoungSyncView';
}

/// User-facing commands for the two independent Young capabilities.
///
/// The caller provides a candidate account and date range only. The
/// implementation must obtain identity authority and transaction permissions
/// from C3 rather than from this UI contract.
abstract interface class YoungSyncPort {
  YoungSyncView get syncView;

  Stream<YoungSyncView> get syncChanges;

  Future<void> startCalendar({
    String? expectedAccountCode,
    required DateTime firstDay,
    required DateTime lastDay,
    String? password,
    bool savePassword = false,
  });

  Future<void> startActivities({
    String? expectedAccountCode,
    String? password,
    bool savePassword = false,
  });

  Future<void> continueAfterLogin();

  Future<void> cancel();

  Future<void> retryRecovery();

  Future<void> clearSession();

  Future<void> deleteSavedCredential();

  Future<void> setHidden({
    required int localId,
    required int expectedVersion,
    required bool hidden,
  });
}
