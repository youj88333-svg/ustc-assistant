import '../core/contracts.dart';

enum YoungBusinessEndpoint { profile, schedule, activities }

enum YoungBusinessPage { activities, calendar }

enum YoungBusinessRejection {
  stampChanged,
  nativeContext,
  mainRoute,
  historyPushChanged,
  historyReplaceChanged,
  historyTraversal,
  historyHashChanged,
  routeAddressChanged,
  historyNativeChanged,
  contextLost,
  compiledScript,
  helperUnavailable,
  preparationTimedOut,
  sourceFailure,
  requestTarget,
  requestOrigin,
  requestPath,
  requestQueryDuplicate,
  requestQueryUnexpected,
  requestQueryShape,
  requestMethod,
  transportAmbiguous,
  responseTarget,
  responseStatus,
  responseMime,
  responseTooLarge,
  responseFormat,
  transportFailed,
  helperRejected,
  xhrConfiguration,
}

/// Closed diagnostics only; never carries the failed page or response.
final class YoungBusinessException implements Exception {
  const YoungBusinessException(this.code, this.reason);
  final FailureCode code;
  final YoungBusinessRejection reason;
  @override
  String toString() => 'YoungBusinessException(${code.name}, ${reason.name})';
}

/// Checks the fixed business route and existing GET helper without a read.
abstract interface class YoungBusinessPreparationBrowserPort {
  Future<bool> prepareYoungBusinessPage({
    required int session,
    required int document,
    required YoungBusinessPage page,
  });
}

enum YoungBusinessPhase { idle, running, done, failed }

enum YoungBusinessIdentity {
  notValidated,
  candidateMatches,
  accountMismatch,
  unverified,
}

enum YoungBusinessStage {
  starting,
  profileBefore,
  activities,
  calendar,
  profileAfter,
  stopping,
}

/// The closed native reply for one application-driven Young read step.
///
/// The projection is private input to the candidate coordinator. It is never
/// included in diagnostics, summaries, or this value's string representation.
final class YoungBusinessStepReply {
  const YoungBusinessStepReply._({
    required this.session,
    required this.document,
    required this.operation,
    required this.step,
    required this.complete,
    required this.projectedJson,
  });

  static const int maximumProjectionLength = 1024 * 1024;

  static const Set<String> _baseFields = <String>{
    'session',
    'document',
    'operation',
    'step',
    'complete',
  };

  final int session;
  final int document;
  final int operation;
  final int step;
  final bool complete;
  final String? projectedJson;

  static YoungBusinessStepReply decode(
    Object? value, {
    required int session,
    required int document,
    required int operation,
    required int step,
  }) {
    if (session <= 0 ||
        document < 0 ||
        operation <= 0 ||
        step <= 0 ||
        value is! Map ||
        !value.keys.every((Object? key) => key is String)) {
      _invalidSnapshot();
    }

    final rawComplete = value['complete'];
    if (rawComplete is! bool) _invalidSnapshot();

    final expectedFields = rawComplete
        ? <String>{..._baseFields, 'projectedJson'}
        : _baseFields;
    if (value.length != expectedFields.length ||
        !expectedFields.every(value.containsKey)) {
      _invalidSnapshot();
    }

    final snapshotSession = value['session'];
    final snapshotDocument = value['document'];
    final snapshotOperation = value['operation'];
    final snapshotStep = value['step'];
    if (snapshotSession is! int ||
        snapshotSession <= 0 ||
        snapshotDocument is! int ||
        snapshotDocument < 0 ||
        snapshotOperation is! int ||
        snapshotOperation <= 0 ||
        snapshotStep is! int ||
        snapshotStep <= 0) {
      _invalidSnapshot();
    }

    String? projectedJson;
    if (rawComplete) {
      final rawProjection = value['projectedJson'];
      if (rawProjection is! String ||
          rawProjection.length > maximumProjectionLength) {
        _invalidSnapshot();
      }
      projectedJson = rawProjection;
    }

    if (snapshotSession != session ||
        snapshotDocument != document ||
        snapshotOperation != operation ||
        snapshotStep != step) {
      throw const AppFailure(FailureCode.staleResult);
    }

    return YoungBusinessStepReply._(
      session: snapshotSession,
      document: snapshotDocument,
      operation: snapshotOperation,
      step: snapshotStep,
      complete: rawComplete,
      projectedJson: projectedJson,
    );
  }

  @override
  String toString() => 'YoungBusinessStepReply';
}

abstract interface class YoungBusinessBrowserPort {
  Future<void> startYoungBusiness({
    required int session,
    required int document,
    required int operation,
  });

  Future<void> dispatchYoungBusinessStep({
    required int session,
    required int document,
    required int operation,
    required int step,
    required YoungBusinessEndpoint endpoint,
    int page = 0,
    String? day,
  });

  Future<YoungBusinessStepReply> pollYoungBusinessStep({
    required int session,
    required int document,
    required int operation,
    required int step,
  });

  Future<void> finishYoungBusiness({
    required int session,
    required int document,
    required int operation,
  });

  Future<void> navigateYoungBusinessPage({
    required int session,
    required int document,
    required YoungBusinessPage page,
  });
}

final class YoungBusinessView {
  const YoungBusinessView({
    this.phase = YoungBusinessPhase.idle,
    this.identity = YoungBusinessIdentity.notValidated,
    this.stage,
    this.failure,
    this.rejection,
    this.busy = false,
    this.available = false,
    this.activities = 0,
    this.activityPages = 0,
    this.calendarRows = 0,
    this.linkedSchedules = 0,
    this.excludedSchedules = 0,
    this.days = 0,
    this.calendarPages = 0,
    this.identityReads = 0,
  });

  final YoungBusinessPhase phase;
  final YoungBusinessIdentity identity;
  final YoungBusinessStage? stage;
  final FailureCode? failure;
  final YoungBusinessRejection? rejection;
  final bool busy;
  final bool available;
  final int activities;
  final int activityPages;
  final int calendarRows;
  final int linkedSchedules;
  final int excludedSchedules;
  final int days;
  final int calendarPages;
  final int identityReads;

  Map<String, Object?> safeSummary() =>
      Map<String, Object?>.unmodifiable(<String, Object?>{
        'kind': 'young-active-contract-v1',
        'phase': phase.name,
        'identity': identity.name,
        'sourceAvailable': false,
        if (stage != null) 'stage': stage!.name,
        if (failure != null) 'failure': failure!.name,
        if (rejection != null) 'reason': rejection!.name,
        'activities': activities,
        'activityPages': activityPages,
        'calendarRows': calendarRows,
        'linkedSchedules': linkedSchedules,
        'excludedSchedules': excludedSchedules,
        'days': days,
        'calendarPages': calendarPages,
        'identityReads': identityReads,
      });

  @override
  String toString() => 'YoungBusinessView';
}

Never _invalidSnapshot() => throw const AppFailure(FailureCode.invalidSnapshot);
