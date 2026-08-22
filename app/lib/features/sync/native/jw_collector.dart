// M3: `JwCollector` — the platform-agnostic JW collection state machine.
//
// Drives an injected [JwWebPage] through the authenticate → course → exam →
// normalize pipeline, emitting a monotonic [SourceCollectionEvent] stream.
// The bundle is produced by the M2 `buildJwSourceBundle` builder (single
// source of truth for normalization); this collector never re-implements
// normalization.
//
// Mirrors the Python `collector.py` event order, phases and error codes so
// the native channel is comparable to the Bridge channel during M6
// acceptance. No `dart:io` / `webview_flutter` / platform plugins.
//
// See `docs/plan-webview-minimal-m3.md` §2.2 (job state machine), §2.4
// (collector implementation), §4 (key constraints).

import 'dart:async';

import 'package:uuid/uuid.dart';

import 'jw_source_bundle_builder.dart';
import 'jw_web_page.dart';
import 'source_collection_gateway.dart';

/// Error code for rejecting a second concurrent job (mirrors the Bridge
/// `bridge_busy` gate).
const String bridgeBusyCode = 'bridge_busy';

/// A cancellation sentinel checked at every state-machine checkpoint (mirrors
/// Python `raise_if_cancelled`). The collector checks this between phases.
class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// Mutable per-job state held by the collector while a job is active.
class _Job {
  _Job({required this.id, required this.accountId, required this.semester});

  final String id;
  final String accountId;
  final JwSemesterConfig semester;

  /// Monotonic event sequence counter (mirrors Python job events).
  int nextSequence = 0;

  /// Set by [JwCollector.cancel]; checked at checkpoints.
  final CancelToken cancelToken = CancelToken();

  /// Completes when [JwCollector.resumeLogin] is called, carrying the
  /// injected password (or null). The state machine awaits this while paused
  /// at `needs_user_login`.
  final Completer<String?> loginResume = Completer<String?>();

  /// True once the job has reached a terminal state.
  bool terminal = false;
}

/// `JwCollector` drives the JW collection state machine against an injected
/// [JwWebPage] factory. Each [startJwCollection] gets a fresh page from the
/// factory (mirrors Python's per-job browser page).
///
/// The collector enforces single-active-job: a second concurrent
/// [startJwCollection] is rejected synchronously with [bridgeBusyCode].
class JwCollector implements SourceCollectionGateway {
  /// Builds a collector.
  ///
  /// - [_pageFactory]: returns a fresh [JwWebPage] for each job (so each job
  ///   gets an isolated page, mirroring the Python per-job Playwright page).
  /// - [_producer]: the SourceBundle producer map reported in the bundle. For
  ///   parity tests inject the Python producer
  ///   `{name:ustc_assistant_python, version:0.1.0, platform:windows}` so the
  ///   digest matches the oracle; production passes [defaultDartProducer].
  /// - [_bundleId]: fixed bundle UUID for tests; defaults to a fresh random
  ///   UUID (mirrors the Python `uuid.uuid4()` default).
  /// - [_collectedAt]: fixed tz-aware collection instant for tests; defaults
  ///   to now (rendered in Asia/Shanghai by the builder).
  /// - [_loginTimeout]: wait for `/home` after login (default 5 min).
  /// - [_responseTimeout]: wait for course get-data / exam table (default 30s).
  /// - [_jobId]: fixed job id for tests; defaults to a fresh random UUID.
  JwCollector({
    required this._pageFactory,
    this._producer,
    this._bundleId,
    this._collectedAt,
    this._loginTimeout = defaultLoginTimeout,
    this._responseTimeout = defaultResponseTimeout,
    this._jobId,
  });
  final JwWebPage Function() _pageFactory;
  final Map<String, Object?>? _producer;
  final String? _bundleId;
  final DateTime? _collectedAt;
  final Duration _loginTimeout;
  final Duration _responseTimeout;
  final String? _jobId;

  _Job? _activeJob;

  @override
  Stream<SourceCollectionEvent> startJwCollection({
    required String accountId,
    required JwSemesterConfig semester,
  }) {
    // Single-active-job gate (mirrors Bridge `bridge_busy`): reject a second
    // concurrent job synchronously with a one-event failed stream.
    if (_activeJob != null && !_activeJob!.terminal) {
      final busyJobId = _activeJob!.id;
      return Stream<SourceCollectionEvent>.fromIterable(
        <SourceCollectionEvent>[
          CollectionFailed(
            jobId: busyJobId,
            sequence: 0,
            errorCode: bridgeBusyCode,
          ),
        ],
      );
    }

    final job = _Job(
      id: _jobId ?? const Uuid().v4(),
      accountId: accountId,
      semester: semester,
    );
    _activeJob = job;
    return _runStateMachine(job);
  }

  /// The job id of the active job, or null if none. Exposed for tests.
  String? get activeJobId => _activeJob?.id;

  @override
  Future<void> resumeLogin(String jobId, {String? password}) async {
    final job = _activeJob;
    if (job == null || job.id != jobId) {
      throw StateError('unknown job: $jobId');
    }
    if (job.terminal) {
      throw StateError('job $jobId is already terminal');
    }
    if (job.loginResume.isCompleted) {
      throw StateError('job $jobId login already resumed');
    }
    job.loginResume.complete(password);
  }

  @override
  Future<void> cancel(String jobId) async {
    final job = _activeJob;
    if (job == null || job.id != jobId || job.terminal) {
      return; // no-op for unknown/terminal jobs (mirrors Bridge).
    }
    job.cancelToken.cancel();
    // If the job is paused waiting for login, unblock it so the generator can
    // observe the cancel token and emit CollectionCancelled instead of
    // hanging forever.
    if (!job.loginResume.isCompleted) {
      job.loginResume.complete(null);
    }
  }

  /// Runs the full state machine as a single-subscription stream.
  Stream<SourceCollectionEvent> _runStateMachine(_Job job) async* {
    final controller = StreamController<SourceCollectionEvent>();

    // Drive the machine on a microtask so the stream is returned immediately.
    unawaited(_drive(controller, job));
    yield* controller.stream;
  }

  Future<void> _drive(
    StreamController<SourceCollectionEvent> controller,
    _Job job,
  ) async {
    void emit(SourceCollectionEvent event) {
      if (!controller.isClosed) controller.add(event);
    }

    try {
      emit(CollectionStarting(jobId: job.id, sequence: job.nextSequence++));

      final page = _pageFactory();

      // --- authenticate -----------------------------------------------------
      if (job.cancelToken.isCancelled) {
        emit(CollectionCancelled(jobId: job.id, sequence: job.nextSequence++));
        return;
      }

      await page.gotoRoot();
      if (job.cancelToken.isCancelled) {
        emit(CollectionCancelled(jobId: job.id, sequence: job.nextSequence++));
        return;
      }

      if (await page.isAuthenticatedHome) {
        emit(CollectionStatus(
          jobId: job.id,
          sequence: job.nextSequence++,
          message: 'Reused the existing USTC JW browser session.',
        ));
      } else {
        emit(CollectionStatus(
          jobId: job.id,
          sequence: job.nextSequence++,
          message:
              'Complete USTC CAS login in the Edge window; waiting for /home ...',
        ));
        if (job.cancelToken.isCancelled) {
          emit(
              CollectionCancelled(jobId: job.id, sequence: job.nextSequence++));
          return;
        }
        await page.gotoCasEntry();
        if (job.cancelToken.isCancelled) {
          emit(
              CollectionCancelled(jobId: job.id, sequence: job.nextSequence++));
          return;
        }
        if (await page.isAuthenticatedHome) {
          emit(CollectionStatus(
            jobId: job.id,
            sequence: job.nextSequence++,
            message: 'Reused the existing USTC CAS session.',
          ));
        } else {
          // Needs user login — pause the stream.
          emit(CollectionNeedsUserLogin(
              jobId: job.id, sequence: job.nextSequence++));
          // Wait for resumeLogin (or cancel, which completes with null).
          final password = await job.loginResume.future;
          if (job.cancelToken.isCancelled) {
            emit(CollectionCancelled(
                jobId: job.id, sequence: job.nextSequence++));
            return;
          }
          try {
            await page.fillLogin(
                LoginCredentials(username: job.accountId, password: password));
          } on JwAccountMismatchException {
            emit(CollectionFailed(
              jobId: job.id,
              sequence: job.nextSequence++,
              errorCode: 'account_mismatch',
            ));
            return;
          }
          if (job.cancelToken.isCancelled) {
            emit(CollectionCancelled(
                jobId: job.id, sequence: job.nextSequence++));
            return;
          }
          try {
            await page.waitForAuthenticatedHome(_loginTimeout);
          } on JwLoginTimeoutException {
            emit(CollectionFailed(
              jobId: job.id,
              sequence: job.nextSequence++,
              errorCode: 'login_timeout',
            ));
            return;
          }
          if (job.cancelToken.isCancelled) {
            emit(CollectionCancelled(
                jobId: job.id, sequence: job.nextSequence++));
            return;
          }
          // After reaching home, verify the account matches.
          if (!await page.isAuthenticatedHome) {
            emit(CollectionFailed(
              jobId: job.id,
              sequence: job.nextSequence++,
              errorCode: 'login_timeout',
            ));
            return;
          }
        }
      }

      // --- collect course ---------------------------------------------------
      if (job.cancelToken.isCancelled) {
        emit(CollectionCancelled(jobId: job.id, sequence: job.nextSequence++));
        return;
      }
      emit(CollectionStatus(
        jobId: job.id,
        sequence: job.nextSequence++,
        message:
            'Opening the course table and resolving the current data context ...',
      ));

      final String dataId;
      try {
        dataId = await page.resolveCourseDataId(_responseTimeout);
      } on JwCollectionException {
        emit(CollectionFailed(
          jobId: job.id,
          sequence: job.nextSequence++,
          errorCode: 'collection_failed',
        ));
        return;
      }
      if (job.cancelToken.isCancelled) {
        emit(CollectionCancelled(jobId: job.id, sequence: job.nextSequence++));
        return;
      }

      emit(CollectionStatus(
        jobId: job.id,
        sequence: job.nextSequence++,
        message:
            'Collecting course data for configured semester ${job.semester.semesterId} ...',
      ));

      final Map<String, dynamic> courseDatum;
      try {
        courseDatum = await page.fetchCourseDatum(
          semesterId: job.semester.semesterId,
          dataId: dataId,
          referer: await page.currentUrl,
        );
      } on JwCollectionException {
        emit(CollectionFailed(
          jobId: job.id,
          sequence: job.nextSequence++,
          errorCode: 'collection_failed',
        ));
        return;
      }
      if (job.cancelToken.isCancelled) {
        emit(CollectionCancelled(jobId: job.id, sequence: job.nextSequence++));
        return;
      }

      // --- collect exam -----------------------------------------------------
      emit(CollectionStatus(
        jobId: job.id,
        sequence: job.nextSequence++,
        message: 'Opening the published exam arrangement page ...',
      ));
      if (job.cancelToken.isCancelled) {
        emit(CollectionCancelled(jobId: job.id, sequence: job.nextSequence++));
        return;
      }

      final String examHtml;
      try {
        examHtml = await page.fetchExamHtml(_responseTimeout);
      } on JwCollectionException {
        emit(CollectionFailed(
          jobId: job.id,
          sequence: job.nextSequence++,
          errorCode: 'collection_failed',
        ));
        return;
      }
      if (job.cancelToken.isCancelled) {
        emit(CollectionCancelled(jobId: job.id, sequence: job.nextSequence++));
        return;
      }

      // --- normalize (call the M2 builder) ----------------------------------
      final bundle = buildJwSourceBundle(
        courseDatum: courseDatum,
        examHtml: examHtml,
        accountId: job.accountId,
        semester: job.semester.toSemester(),
        bundleId: _bundleId,
        collectedAt: _collectedAt,
        producer: _producer,
      );

      emit(CollectionComplete(
        jobId: job.id,
        sequence: job.nextSequence++,
        bundle: bundle,
      ));
    } catch (e) {
      // Any unexpected exception is a collection failure.
      emit(CollectionFailed(
        jobId: job.id,
        sequence: job.nextSequence++,
        errorCode: 'collection_failed',
      ));
    } finally {
      job.terminal = true;
      await controller.close();
    }
  }
}
