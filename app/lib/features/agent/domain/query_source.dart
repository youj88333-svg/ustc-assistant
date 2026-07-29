import '../application/cancellation_signal.dart';

/// The version of the Bridge Query Protocol this gateway speaks.
const String queryProtocolVersion = '1.0';

/// The schema version every Query Result 1.0 envelope carries.
const String queryResultSchemaVersion = '1.0';

/// A read-only query against an external school source, routed through the
/// Windows Python Bridge.
///
/// Concrete request kinds are [YoungEnrolmentQueryRequest], [IcourseQueryRequest],
/// [CampusSearchQueryRequest], and [CampusDetailQueryRequest]. The gateway
/// translates each into a Bridge Query Protocol 1.0 `POST /queries` body.
///
/// This type is pure Dart (no `dart:io`, no Windows APIs) so the shared Agent
/// core can depend on it without pulling platform code.
sealed class SourceQuery {
  const SourceQuery();

  /// The Bridge Query Protocol query `type` discriminator.
  String get type;
}

/// Queries the Young (青年日程) second-class-activity enrolment snapshot for the
/// account. This is the only query kind that may enter `needs_user_login` and
/// the only one that carries account identity.
class YoungEnrolmentQueryRequest extends SourceQuery {
  const YoungEnrolmentQueryRequest({
    required this.accountId,
    required this.expectedUsername,
  });

  final String accountId;
  final String expectedUsername;

  @override
  String get type => 'young_enrolment';
}

/// A public iCourse query. Carries only course + necessary teacher terms; never
/// account identity, schedule times, locations, or credentials.
class IcourseQueryRequest extends SourceQuery {
  const IcourseQueryRequest({
    required this.course,
    this.teachers = const <String>[],
    this.preferences,
  });

  final String course;
  final List<String> teachers;
  final Map<String, String>? preferences;

  @override
  String get type => 'icourse';
}

/// A public campus-catalog search. Returns bounded catalog entry references.
class CampusSearchQueryRequest extends SourceQuery {
  const CampusSearchQueryRequest({
    required this.query,
    this.filters,
    this.limit = 20,
  });

  final String query;
  final Map<String, String>? filters;
  final int limit;

  @override
  String get type => 'campus_search';
}

/// Reads the detail of one or more campus catalog entries by their entry ids,
/// optionally following at most one level of discovered links. The entry ids
/// must come from run-local refs resolved by the tool layer, never from a raw
/// URL or model-supplied id.
class CampusDetailQueryRequest extends SourceQuery {
  const CampusDetailQueryRequest({
    required this.entryIds,
    this.followLinkIds = const <String>[],
  });

  final List<String> entryIds;
  final List<String> followLinkIds;

  @override
  String get type => 'campus_detail';
}

/// A bounded Query Result 1.0 envelope returned by a completed query.
///
/// Mirrors the Python `query_contracts.py` envelope exactly: `schemaVersion`
/// is always `"1.0"`, `references` is a list of trusted-host HTTPS URLs that
/// actually appeared in the source results, and `data`/`metadata` are bounded
/// maps. This class is a thin typed view over the decoded JSON map; it does not
/// re-validate (the Python side already validated, and the gateway trusts the
/// Bridge's authenticated loopback channel).
class QueryResultEnvelope {
  const QueryResultEnvelope({required this.json});

  /// The decoded envelope JSON.
  final Map<String, dynamic> json;

  String get schemaVersion => json['schemaVersion'] as String;
  String get queryType => json['queryType'] as String;
  String get generatedAt => json['generatedAt'] as String;
  Map<String, dynamic> get data => json['data'] as Map<String, dynamic>;
  Map<String, dynamic> get metadata => json['metadata'] as Map<String, dynamic>;
  List<String> get references =>
      (json['references'] as List<dynamic>).cast<String>();
}

/// Events emitted by [QuerySourceGateway.execute] as a query job progresses.
///
/// The four concrete kinds are [SourceQueryProgress], [SourceQueryNeedsLogin],
/// [SourceQueryCompleted], and [SourceQueryFailed]. A run is terminal after
/// `SourceQueryCompleted` or `SourceQueryFailed`; `SourceQueryNeedsLogin`
/// pauses the run until the UI explicitly calls [QuerySourceGateway.resumeLogin].
sealed class SourceQueryEvent {
  const SourceQueryEvent();

  /// The Bridge job id, surfaced so the UI/composition can resume or cancel.
  String? get jobId;
}

/// A non-terminal progress update: a phase transition and an optional safe
/// count (e.g. number of entries normalized so far).
class SourceQueryProgress extends SourceQueryEvent {
  const SourceQueryProgress({this.jobId, required this.phase, this.safeCount});

  @override
  final String? jobId;

  /// The current Bridge query phase: `starting`, `waiting_for_user`,
  /// `checking_session`, `collecting`, `normalizing`, `validating`, etc.
  final String phase;

  /// An optional, desensitized count reported by the Bridge (may be null).
  final int? safeCount;
}

/// The query paused awaiting an interactive login. Only `young_enrolment`
/// emits this. The owning Agent run MUST pause until the user explicitly
/// resumes via [QuerySourceGateway.resumeLogin]; the tool never auto-resumes
/// and never receives a password or verification code.
class SourceQueryNeedsLogin extends SourceQueryEvent {
  const SourceQueryNeedsLogin({required this.jobId});

  @override
  final String jobId;
}

/// The query completed successfully, carrying the bounded Query Result 1.0
/// envelope.
class SourceQueryCompleted extends SourceQueryEvent {
  const SourceQueryCompleted({required this.jobId, required this.result});

  @override
  final String jobId;

  final QueryResultEnvelope result;
}

/// The query failed (or was cancelled). [code] is a safe, desensitized error
/// code from the Bridge (e.g. `query_failed`, `cancelled`, `account_mismatch`,
/// `result_validation_failed`).
class SourceQueryFailed extends SourceQueryEvent {
  const SourceQueryFailed({required this.jobId, required this.code});

  @override
  final String jobId;

  final String code;
}

/// The shared-core abstraction over the Windows Python Bridge's query
/// endpoints.
///
/// `execute` starts a query job and returns a stream of [SourceQueryEvent]s:
/// progress updates, a `needs_user_login` pause, a terminal completed event
/// with the Query Result 1.0 envelope, or a terminal failed event. The stream
/// closes after the terminal event. If [cancellation] is cancelled mid-stream,
/// the gateway POSTs `/cancel` for the active job and emits a terminal
/// `SourceQueryFailed` with code `cancelled`.
///
/// `resumeLogin` and `cancel` are explicit out-of-band calls for the UI
/// (Task 11) to use when a run is paused on `needs_user_login` or the user
/// aborts. They are NOT called by tools.
///
/// Implementations of this interface MUST NOT send the model API Key — only
/// account-scoped username/password for `young_enrolment`. They MUST NOT
/// accept a URL from a tool argument; entry ids come from run-local refs.
abstract interface class QuerySourceGateway {
  /// Starts [request] and streams progress events until the job is terminal.
  Stream<SourceQueryEvent> execute(
    SourceQuery request, {
    required CancellationSignal cancellation,
  });

  /// Resumes a paused `young_enrolment` job. Only valid when the job is in
  /// `needs_user_login`. [password] is the account's protected school
  /// password (may be null to resume without a password).
  Future<void> resumeLogin(String jobId, {String? password});

  /// Cancels an active or paused query job.
  Future<void> cancel(String jobId);
}
