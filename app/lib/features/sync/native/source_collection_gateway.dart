// M3: Frozen `SourceCollectionGateway` interface + `SourceCollectionEvent`
// sealed hierarchy. Platform-agnostic — no `dart:io`, no `webview_flutter`,
// no platform plugins. Real WebView adapters are M5; this file is the
// injection seam tested with fakes.
//
// See `docs/plan-webview-minimal-m3.md` §1 (interface freeze) and §2.3
// (event sealed class). The event sequence is monotonic (mirrors the Python
// job events `sequence` field) so the stream carries the same poll semantics
// as the Bridge.

import 'jw_source_bundle_builder.dart' show JwSemester;

/// Semester identity passed into a collection job.
///
/// The M2 bundle builder consumes [JwSemester] (defined alongside the
/// builder). [JwSemesterConfig] is the public gateway-facing identity: it is
/// structurally identical and converts losslessly via [toSemester]. The plan
/// freezes the gateway signature on `JwSemesterConfig`, so this class is the
/// canonical one callers pass; the collector adapts it to the builder's type.
class JwSemesterConfig {
  const JwSemesterConfig({
    required this.semesterId,
    required this.semesterKey,
    required this.displayName,
  });

  /// JW internal semester id (e.g. `461` for 2026 fall). Never derived from
  /// the calendar year — taken from the JW semester list.
  final int semesterId;

  /// Stable product key (e.g. `2026fall`).
  final String semesterKey;

  /// Human display name (e.g. `2026 秋季学期`).
  final String displayName;

  /// Convert to the M2 builder's [JwSemester] type.
  JwSemester toSemester() => JwSemester(
        semesterId: semesterId,
        semesterKey: semesterKey,
        displayName: displayName,
      );
}

/// Frozen gateway contract for starting/resuming/cancelling a JW source
/// collection job. Mirrors the Bridge gateway surface (`bridge_client.dart`)
/// but is platform-agnostic: the concrete `JwCollector` drives a state
/// machine against an injected [JwWebPage] (M3) / WebView adapter (M5)
/// instead of a Python child process.
///
/// One active job per gateway at a time (mirrors the Bridge `bridge_busy`
/// gate). A second concurrent [startJwCollection] is rejected synchronously.
abstract interface class SourceCollectionGateway {
  /// Start a JW collection job for [accountId] + [semester].
  ///
  /// Emits a monotonic [SourceCollectionEvent] stream. The stream is
  /// single-subscription. Terminal events are [CollectionComplete],
  /// [CollectionFailed], or [CollectionCancelled]. If the session needs the
  /// user to log in, the stream pauses on [CollectionNeedsUserLogin] and
  /// resumes after [resumeLogin].
  Stream<SourceCollectionEvent> startJwCollection({
    required String accountId,
    required JwSemesterConfig semester,
  });

  /// Resume a job paused at [CollectionNeedsUserLogin], optionally injecting
  /// a [password] for the CAS form. Throws if [jobId] is unknown or not
  /// paused.
  Future<void> resumeLogin(String jobId, {String? password});

  /// Request cancellation of [jobId]. The state machine exits as
  /// [CollectionCancelled] at the next checkpoint. No-op (returns) if the
  /// job is unknown or already terminal.
  Future<void> cancel(String jobId);
}

/// Monotonic event emitted by a collection job. Mirrors the Python job
/// events: every event carries the [jobId], a [phase] label, and a
/// strictly-increasing [sequence] starting at 0.
sealed class SourceCollectionEvent {
  const SourceCollectionEvent({
    required this.jobId,
    required this.phase,
    required this.sequence,
  });

  /// Stable job identifier (shared across all events of one job).
  final String jobId;

  /// State-machine phase label (e.g. `starting`, `collecting`,
  /// `needs_user_login`, `complete`, `failed`, `cancelled`).
  final String phase;

  /// Monotonic, zero-based, gap-free event index.
  final int sequence;
}

/// Emitted first. phase = `starting`.
class CollectionStarting extends SourceCollectionEvent {
  const CollectionStarting({
    required super.jobId,
    required super.sequence,
  }) : super(phase: 'starting');
}

/// Progress/status message. phase = `collecting`. Mirrors the Python
/// `status(...)` calls (e.g. "Reused the existing USTC JW browser session.").
class CollectionStatus extends SourceCollectionEvent {
  const CollectionStatus({
    required super.jobId,
    required super.sequence,
    required this.message,
  }) : super(phase: 'collecting');

  /// Human-readable status text aligned with the Python collector.
  final String message;
}

/// The session is not authenticated and needs the user to log in. phase =
/// `needs_user_login`. The stream pauses here until [SourceCollectionGateway.resumeLogin].
class CollectionNeedsUserLogin extends SourceCollectionEvent {
  const CollectionNeedsUserLogin({
    required super.jobId,
    required super.sequence,
  }) : super(phase: 'needs_user_login');
}

/// Terminal success. phase = `complete`. Carries the built SourceBundle as a
/// `Map<String,dynamic>` (the M2 `buildJwSourceBundle` output).
class CollectionComplete extends SourceCollectionEvent {
  const CollectionComplete({
    required super.jobId,
    required super.sequence,
    required this.bundle,
  }) : super(phase: 'complete');

  /// The SourceBundle 1.0 envelope produced by the M2 builder.
  final Map<String, dynamic> bundle;
}

/// Terminal failure. phase = `failed`. Carries an error code mirroring the
/// Python collector: `collection_failed`, `account_mismatch`, `login_timeout`.
class CollectionFailed extends SourceCollectionEvent {
  const CollectionFailed({
    required super.jobId,
    required super.sequence,
    required this.errorCode,
  }) : super(phase: 'failed');

  /// Stable error code (mirrors Python `CollectionError.code`).
  final String errorCode;
}

/// Terminal cancellation. phase = `cancelled`.
class CollectionCancelled extends SourceCollectionEvent {
  const CollectionCancelled({
    required super.jobId,
    required super.sequence,
  }) : super(phase: 'cancelled');
}
