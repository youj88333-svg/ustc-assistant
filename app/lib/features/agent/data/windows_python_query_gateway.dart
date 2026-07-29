import 'dart:async';

import 'package:http/http.dart' as http;

import '../application/cancellation_signal.dart';
import '../domain/query_source.dart';
import '../../sync/data/bridge_client.dart';

/// The poll interval for query-job events.
const Duration _pollInterval = Duration(milliseconds: 200);

/// The long-poll wait passed to the Bridge (ms). The Bridge holds the request
/// open until a new event arrives or this timeout elapses.
const int _pollWaitMs = 2000;

/// The maximum total time a single [execute] stream will wait for a terminal
/// event before giving up (defensive backstop; the Bridge normally completes).
const Duration _maxWait = Duration(minutes: 10);

/// Windows-specific [QuerySourceGateway] backed by the Python Bridge.
///
/// This gateway does NOT spawn its own Python process: it wraps a [BridgeClient]
/// (which already started the Bridge and holds the loopback port + bearer
/// token), reusing the same process as collection jobs. It translates Bridge
/// Query Protocol 1.0 requests/responses into the shared-core [SourceQuery]
/// domain types.
///
/// Young login pause: when a `young_enrolment` job enters `needs_user_login`,
/// the stream emits [SourceQueryNeedsLogin] and pauses (stops polling, does not
/// close). The UI calls [resumeLogin] for that jobId; the stream then resumes
/// polling and emits the terminal [SourceQueryCompleted]/[SourceQueryFailed].
/// Only an explicit UI resume may call [resumeLogin]; the tool never auto-
/// resumes and never receives a password or verification code.
///
/// SECURITY:
/// - The gateway NEVER sends the model API Key. Only `young_enrolment` carries
///   account identity (accountId + expectedUsername); the other query kinds
///   carry none.
/// - The gateway NEVER accepts a URL from a tool argument. Campus detail uses
///   entry ids only; the Dart [CampusDetailQueryRequest] has no URL field.
/// - `resumeLogin` is the only path that may carry a password (the account's
///   protected school password), and only for a paused `young_enrolment` job.
///
/// This is the one place in the Agent stack that may import `dart:io`/process
/// APIs (via [BridgeClient]); the shared-core domain types and tools depend
/// only on [QuerySourceGateway].
class WindowsPythonQueryGateway implements QuerySourceGateway {
  WindowsPythonQueryGateway._(this._client);

  final BridgeClient _client;

  /// Completers keyed by jobId, completed when [resumeLogin] is called for a
  /// paused job. The [execute] stream awaits this before resuming polling.
  final Map<String, Completer<void>> _resumeCompleters = {};

  /// Starts the Bridge (if not already running) and returns a gateway backed
  /// by it. Mirrors [BridgeClient.start] so tests can inject a fake launcher
  /// and HTTP client.
  static Future<WindowsPythonQueryGateway> start({
    required String pythonExecutable,
    BridgeProcessLauncher launcher = const IoBridgeProcessLauncher(),
    http.Client? httpClient,
    int? parentPid,
    Duration handshakeTimeout = const Duration(seconds: 10),
  }) async {
    final client = await BridgeClient.start(
      pythonExecutable: pythonExecutable,
      launcher: launcher,
      httpClient: httpClient,
      parentPid: parentPid,
      handshakeTimeout: handshakeTimeout,
    );
    return WindowsPythonQueryGateway._(client);
  }

  @override
  Stream<SourceQueryEvent> execute(
    SourceQuery request, {
    required CancellationSignal cancellation,
  }) async* {
    final body = _buildRequestBody(request);
    final startResponse = await _post('/queries', body);
    final jobId = startResponse['jobId'] as String;
    // Do not emit a progress event for the start-response phase: the first
    // poll batch will emit the authoritative starting event. Emitting both
    // would duplicate the `starting` phase.

    final cancelled = Completer<void>();
    final cancelSub = cancellation.onCancel.listen((_) {
      if (!cancelled.isCompleted) cancelled.complete();
    });

    var afterSequence = 0;
    final deadline = DateTime.now().add(_maxWait);
    try {
      while (true) {
        if (cancellation.isCancelled) {
          await _safeCancel(jobId);
          yield SourceQueryFailed(jobId: jobId, code: 'cancelled');
          return;
        }
        if (DateTime.now().isAfter(deadline)) {
          yield SourceQueryFailed(jobId: jobId, code: 'query_timeout');
          return;
        }
        final poll = await _poll(jobId, afterSequence);
        var pausedForLogin = false;
        for (final event in poll.events) {
          final phase = event['phase'] as String?;
          final safeCount = event['safeCount'] as int?;
          if (phase == 'needs_user_login') {
            yield SourceQueryNeedsLogin(jobId: jobId);
            pausedForLogin = true;
          } else if (phase == 'complete' ||
              phase == 'cancelled' ||
              phase == 'failed') {
            // Terminal phases are handled via the poll envelope below.
            continue;
          } else if (phase != null) {
            yield SourceQueryProgress(
              jobId: jobId,
              phase: phase,
              safeCount: safeCount,
            );
          }
        }
        afterSequence = poll.nextSequence;
        if (poll.terminal) {
          if (poll.result != null) {
            yield SourceQueryCompleted(
              jobId: jobId,
              result: QueryResultEnvelope(
                json: poll.result as Map<String, dynamic>,
              ),
            );
          } else {
            yield SourceQueryFailed(
              jobId: jobId,
              code: poll.errorCode ?? 'query_failed',
            );
          }
          return;
        }
        if (pausedForLogin) {
          // Pause: wait for an explicit resumeLogin or cancellation.
          final resumeCompleter = Completer<void>();
          _resumeCompleters[jobId] = resumeCompleter;
          try {
            await Future.any([
              resumeCompleter.future,
              cancelled.future,
            ]);
          } finally {
            _resumeCompleters.remove(jobId);
          }
          if (cancellation.isCancelled) {
            await _safeCancel(jobId);
            yield SourceQueryFailed(jobId: jobId, code: 'cancelled');
            return;
          }
          // Resumed: continue polling.
          continue;
        }
        // Brief wait before the next poll, but bail out if cancelled.
        if (cancelled.isCompleted) {
          await _safeCancel(jobId);
          yield SourceQueryFailed(jobId: jobId, code: 'cancelled');
          return;
        }
        await Future<void>.delayed(_pollInterval);
      }
    } finally {
      await cancelSub.cancel();
      _resumeCompleters.remove(jobId);
    }
  }

  @override
  Future<void> resumeLogin(String jobId, {String? password}) async {
    await _post('/query-jobs/$jobId/resume-login', {
      'protocolVersion': bridgeProtocolVersion,
      'password': ?password,
    });
    final completer = _resumeCompleters[jobId];
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  @override
  Future<void> cancel(String jobId) async {
    await _post('/query-jobs/$jobId/cancel', {
      'protocolVersion': bridgeProtocolVersion,
    });
  }

  /// POSTs /shutdown then kills the Bridge process (delegates to the
  /// underlying [BridgeClient]).
  Future<void> shutdown() => _client.shutdown();

  // --- Bridge Query Protocol 1.0 translation -----------------------------

  Map<String, Object?> _buildRequestBody(SourceQuery request) {
    switch (request) {
      case YoungEnrolmentQueryRequest():
        return {
          'protocolVersion': bridgeProtocolVersion,
          'queryProtocolVersion': queryProtocolVersion,
          'accountId': request.accountId,
          'expectedUsername': request.expectedUsername,
          'query': {'type': request.type},
        };
      case IcourseQueryRequest():
        return {
          'protocolVersion': bridgeProtocolVersion,
          'queryProtocolVersion': queryProtocolVersion,
          'query': {
            'type': request.type,
            'course': request.course,
            if (request.teachers.isNotEmpty) 'teachers': request.teachers,
            if (request.preferences != null) 'preferences': request.preferences,
          },
        };
      case CampusSearchQueryRequest():
        return {
          'protocolVersion': bridgeProtocolVersion,
          'queryProtocolVersion': queryProtocolVersion,
          'query': {
            'type': request.type,
            'query': request.query,
            if (request.filters != null) 'filters': request.filters,
            'limit': request.limit,
          },
        };
      case CampusDetailQueryRequest():
        return {
          'protocolVersion': bridgeProtocolVersion,
          'queryProtocolVersion': queryProtocolVersion,
          'query': {
            'type': request.type,
            'entryId': request.entryIds.first,
            if (request.followLinkIds.isNotEmpty)
              'followLinkIds': request.followLinkIds,
          },
        };
    }
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, Object?> body,
  ) =>
      _client.postQuery(path, body);

  Future<_QueryPoll> _poll(String jobId, int afterSequence) async {
    final result = await _client.getQuery(
      '/query-jobs/$jobId/events?after=$afterSequence&waitMs=$_pollWaitMs',
    );
    final events =
        (result['events'] as List<dynamic>).cast<Map<String, dynamic>>();
    final error = result['error'];
    return _QueryPoll(
      events: events,
      nextSequence: result['nextSequence'] as int,
      terminal: result['terminal'] as bool,
      result: result['result'] as Map<String, dynamic>?,
      errorCode: error is Map<String, dynamic>
          ? error['code'] as String?
          : null,
    );
  }

  Future<void> _safeCancel(String jobId) async {
    try {
      await cancel(jobId);
    } catch (_) {
      // Best-effort: a failed cancel must not break the stream teardown.
    }
  }
}

class _QueryPoll {
  _QueryPoll({
    required this.events,
    required this.nextSequence,
    required this.terminal,
    this.result,
    this.errorCode,
  });

  final List<Map<String, dynamic>> events;
  final int nextSequence;
  final bool terminal;
  final Map<String, dynamic>? result;
  final String? errorCode;
}
