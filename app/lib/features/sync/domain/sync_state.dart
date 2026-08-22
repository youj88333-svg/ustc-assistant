enum SyncSource {
  jw('ustc_jw');

  const SyncSource(this.storage);

  final String storage;
}

enum SyncTrigger { automatic, manual }

enum SyncPhase {
  idle,
  due,
  running,
  needsUserAction,
  succeeded,
  failed,
  cancelled,
}

class SyncSourceState {
  const SyncSourceState({
    required this.source,
    required this.phase,
    this.progressPhase,
    this.lastAttemptAt,
    this.lastSuccessfulAt,
    this.resultCode,
    this.jobId,
  });

  final SyncSource source;
  final SyncPhase phase;
  final String? progressPhase;
  final DateTime? lastAttemptAt;
  final DateTime? lastSuccessfulAt;
  final String? resultCode;
  final String? jobId;
}

sealed class SyncOutcome {
  const SyncOutcome(this.source);

  final SyncSource source;
}

class SyncStarted extends SyncOutcome {
  const SyncStarted(super.source, {required this.state});

  final SyncSourceState state;
}

class SyncSkipped extends SyncOutcome {
  const SyncSkipped(super.source, {required this.reason});

  final String reason;
}

class SyncNeedsUserAction extends SyncOutcome {
  const SyncNeedsUserAction(super.source, {required this.jobId});

  final String jobId;
}

class SyncSucceeded extends SyncOutcome {
  const SyncSucceeded(super.source, {required this.importedEntityCount});

  final int importedEntityCount;
}

class SyncFailed extends SyncOutcome {
  const SyncFailed(super.source, {required this.code});

  final String code;
}

class SyncCancelled extends SyncOutcome {
  const SyncCancelled(super.source);
}
