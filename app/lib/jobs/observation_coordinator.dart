import 'dart:async';
import 'dart:convert';

import '../core/contracts.dart';
import '../core/observation_assets.dart';
import '../core/work_lease.dart';
import '../core/young_work_contract.dart';
import '../core/jw_work_contract.dart';
import '../core/jw_credentials.dart';
import '../source/jw_authentication_contract.dart';
import '../data/jw_candidate_identity.dart';
import '../source/jw_data_probe_contract.dart';
import '../source/jw_collection_contract.dart';
import '../source/jw_probe_contract.dart';
import '../source/observation_contract.dart';
import '../source/young_observation_contract.dart';
import '../source/young_read_only_contract.dart';
import '../source/young_active_contract.dart';
import '../source/young_business_contract.dart' hide YoungBusinessPage;
import '../source/young_collection_contract.dart';
import 'jw_probe_port.dart';
import 'jw_data_probe_port.dart';
import 'observation_port.dart';
import 'young_read_only_port.dart';
import 'young_business_probe_port.dart';

/// One source lease covers registration, native lifetime, drain and deletion.
final class ObservationCoordinator
    implements
        YoungReadOnlyObservationPort,
        YoungBusinessProbePort,
        JwProbePort,
        JwDataProbePort {
  ObservationCoordinator({
    required this.browser,
    required this.assets,
    required this.leases,
    this.borrowedLease,
    this.backgroundWindow = false,
    ObservationTarget? target,
    this.drainTimeout = const Duration(seconds: 12),
    this.pollInterval = const Duration(milliseconds: 100),
    this.probeTimeout = const Duration(seconds: 95),
    this.dataProbeTimeout = const Duration(seconds: 195),
  }) : target = target ?? ObservationTarget.jw() {
    _subscription = browser.events.listen(_onEvent);
  }
  final ObservationBrowserPort browser;
  final ObservationAssetsPort assets;
  final WorkLeasePool leases;
  final WorkLease? borrowedLease;
  final bool backgroundWindow;
  final ObservationTarget target;
  final Duration drainTimeout;
  final Duration pollInterval;
  final Duration probeTimeout;
  final Duration dataProbeTimeout;
  late final StreamSubscription<BrowserEvent> _subscription;
  final _changes = StreamController<ObservationView>.broadcast();
  ObservationView _view = const ObservationView(phase: ObservationPhase.idle);
  WorkLease? _lease;
  Future<void>? _work;
  Future<void>? _cleanupFuture;
  Future<void>? _shutdownFuture;
  static int _sequence = 0;
  int? _session;
  int _document = 0;
  int _check = 0;
  bool _nativeStarted = false;
  bool _cancelled = false;
  bool _shuttingDown = false;
  final _diagnostics = <BrowserDiagnostic>[];
  final _probeChanges = StreamController<JwProbeView>.broadcast();
  JwProbeView _probeView = const JwProbeView();
  Future<void>? _probeWork;
  bool _probeActive = false;
  bool _probeCancelled = false;
  int _probeRevision = 0;
  static int _probeSequence = 0;
  final _dataProbeChanges = StreamController<JwDataProbeView>.broadcast();
  JwDataProbeView _dataProbeView = const JwDataProbeView();
  bool _dataActive = false;
  static int _loginSequence = 0;
  int? _loginOperation;
  int? _loginDocument;
  bool _loginPending = false;
  bool _youngInspectPending = false;
  bool _youngPreparePending = false;
  YoungPageInspection? _youngInspection;
  final _readOnlyChanges =
      StreamController<YoungReadOnlyInspection?>.broadcast();
  YoungReadOnlyInspection? _readOnlyInspection;
  int? _readOnlyOperation;
  static int _readOnlySequence = 0;
  bool _readOnlyPending = false;
  int _readOnlyRevision = 0;
  final _businessChanges = StreamController<YoungBusinessView>.broadcast();
  YoungBusinessView _businessView = const YoungBusinessView();
  bool _businessActive = false;
  bool _businessCancelled = false;
  bool _businessRouteChanged = false;
  Future<void>? _businessWork;
  static int _businessSequence = 0;
  int get documentGeneration => _document;

  @override
  YoungBusinessView get businessView => _businessView;
  @override
  Stream<YoungBusinessView> get businessChanges => _businessChanges.stream;
  bool get _businessAvailable =>
      target.source == ObservationSource.young &&
      browser is YoungBusinessBrowserPort &&
      view.phase == ObservationPhase.open &&
      view.ready &&
      view.origin == target.initialUri.origin &&
      !_shuttingDown;

  void _refreshBusiness() {
    final previous = businessView;
    _businessView = YoungBusinessView(
      phase: previous.phase,
      identity: previous.identity,
      stage: previous.stage,
      failure: previous.failure,
      rejection: previous.rejection,
      busy: _businessActive,
      available: _businessAvailable,
      activities: previous.activities,
      activityPages: previous.activityPages,
      calendarRows: previous.calendarRows,
      linkedSchedules: previous.linkedSchedules,
      excludedSchedules: previous.excludedSchedules,
      days: previous.days,
      calendarPages: previous.calendarPages,
      identityReads: previous.identityReads,
    );
    _businessChanges.add(_businessView);
  }

  @override
  YoungReadOnlyInspection? get readOnlyInspection => _readOnlyInspection;
  @override
  Stream<YoungReadOnlyInspection?> get readOnlyChanges =>
      _readOnlyChanges.stream;

  void _clearReadOnly() {
    ++_readOnlyRevision;
    _readOnlyOperation = null;
    _readOnlyInspection = null;
    _readOnlyChanges.add(null);
  }

  @override
  ObservationView get view => _view;
  @override
  Stream<ObservationView> get changes => _changes.stream;
  @override
  JwProbeView get probeView => _probeView;
  @override
  Stream<JwProbeView> get probeChanges => _probeChanges.stream;
  @override
  JwDataProbeView get dataProbeView => _dataProbeView;
  @override
  Stream<JwDataProbeView> get dataProbeChanges => _dataProbeChanges.stream;

  bool get _probeAvailable =>
      target.source == ObservationSource.jw &&
      browser is JwProbeBrowserPort &&
      view.phase == ObservationPhase.open &&
      view.ready &&
      view.origin == target.initialUri.origin &&
      !_shuttingDown;

  void _publishProbe({
    required JwProbePhase phase,
    required JwProbeCode code,
    JwCandidateIdentity identity = JwCandidateIdentity.unavailable,
    JwProbeSummary? summary,
    List<JwSemesterOption> semesters = const [],
    String? stage,
    FailureCode? failure,
  }) {
    _probeView = JwProbeView(
      phase: phase,
      code: code,
      identity: identity,
      summary: summary,
      semesters: List.unmodifiable(semesters),
      stage: stage,
      failure: failure,
      available: _probeAvailable,
      busy: _probeActive,
    );
    _probeChanges.add(_probeView);
  }

  void _refreshProbeAvailability() {
    _publishProbe(
      phase: probeView.phase,
      code: probeView.code,
      identity: probeView.identity,
      summary: probeView.summary,
      semesters: probeView.semesters,
      stage: probeView.stage,
      failure: probeView.failure,
    );
    _publishDataProbe(
      phase: dataProbeView.phase,
      code: dataProbeView.code,
      identity: dataProbeView.identity,
      diagnostics: dataProbeView.diagnostics,
      stage: dataProbeView.stage,
      failure: dataProbeView.failure,
    );
  }

  void _publishDataProbe({
    required JwProbePhase phase,
    required JwDataProbeCode code,
    JwCandidateIdentity identity = JwCandidateIdentity.unavailable,
    JwDataDiagnostics? diagnostics,
    String? stage,
    FailureCode? failure,
  }) {
    _dataProbeView = JwDataProbeView(
      phase: phase,
      code: code,
      identity: identity,
      diagnostics: diagnostics,
      stage: stage,
      failure: failure,
      available: _probeAvailable && browser is JwDataProbeBrowserPort,
      busy: _probeActive,
    );
    _dataProbeChanges.add(_dataProbeView);
  }

  void _clearDataProbe() => _publishDataProbe(
    phase: JwProbePhase.idle,
    code: JwDataProbeCode.pending,
  );

  void _publish(
    ObservationPhase phase, {
    String? origin,
    bool ready = false,
    bool blocked = false,
    FailureCode? failure,
  }) {
    _view = ObservationView(
      phase: phase,
      origin: origin,
      ready: ready,
      blocked: blocked,
      failure: failure,
      diagnostics: List.unmodifiable(_diagnostics),
      youngInspection:
          phase == ObservationPhase.open &&
              _youngInspection?.session == _session &&
              _youngInspection?.document == _document
          ? _youngInspection
          : null,
    );
    _changes.add(_view);
    _refreshProbeAvailability();
    _refreshBusiness();
  }

  Future<void> _track(Future<void> Function() action) {
    final done = Completer<void>();
    _work = done.future;
    return () async {
      try {
        await action();
      } finally {
        if (identical(_work, done.future)) _work = null;
        done.complete();
      }
    }();
  }

  /// Startup recovery never navigates: reconnect blank, close, prove drain.
  Future<void> initialize() async {
    if (_shuttingDown || view.phase == ObservationPhase.closed) {
      throw const AppFailure(FailureCode.closed);
    }
    if (view.phase != ObservationPhase.idle) {
      throw const AppFailure(FailureCode.busy);
    }
    _lease = _acquireLease();
    _publish(ObservationPhase.opening);
    await _track(() async {
      try {
        await assets.recoverPending(_drainCandidate);
        _release();
        _publish(ObservationPhase.idle);
      } catch (error) {
        _publish(ObservationPhase.recovery, failure: _code(error));
      }
    });
  }

  @override
  Future<void> open() {
    try {
      if (_shuttingDown || view.phase == ObservationPhase.closed) {
        throw const AppFailure(FailureCode.closed);
      }
      if (view.phase != ObservationPhase.idle) {
        throw const AppFailure(FailureCode.busy);
      }
      _lease = _acquireLease();
    } on AppFailure catch (error) {
      return Future.error(error);
    }
    _cancelled = false;
    _businessCancelled = false;
    _businessView = const YoungBusinessView();
    _youngInspection = null;
    _clearReadOnly();
    _probeCancelled = false;
    ++_probeRevision;
    _publishProbe(phase: JwProbePhase.idle, code: JwProbeCode.pending);
    _clearDataProbe();
    _diagnostics.clear();
    _publish(ObservationPhase.opening);
    return _track(() async {
      try {
        await assets.recoverPending(_drainCandidate);
        if (_cancelled) return;
        final availability = browser is ObservationAvailabilityBrowserPort
            ? browser as ObservationAvailabilityBrowserPort
            : null;
        if (availability != null && availability.requiresAvailabilityCheck) {
          await availability.ensureAvailable();
          if (_cancelled) return;
        }
        final path = await assets.register();
        if (_cancelled) return;
        _session = ++_sequence;
        _document = 0;
        _nativeStarted = true;
        if (backgroundWindow) {
          if (browser is! BackgroundObservationBrowserPort) {
            throw const AppFailure(FailureCode.unsupportedPlatform);
          }
          await _bounded(
            (browser as BackgroundObservationBrowserPort).openBackground(
              session: _session!,
              profilePath: path,
              target: target,
            ),
          );
        } else {
          await _bounded(
            browser.open(session: _session!, profilePath: path, target: target),
          );
        }
        if (!_cancelled && view.phase == ObservationPhase.opening) {
          _publish(
            ObservationPhase.open,
            origin: view.origin,
            ready: view.ready,
            blocked: view.blocked,
          );
        }
      } catch (error, stack) {
        if (!_cancelled) {
          _publish(ObservationPhase.recovery, failure: _code(error));
        }
        Error.throwWithStackTrace(AppFailure(_code(error)), stack);
      }
    });
  }

  FailureCode _code(Object error) =>
      error is AppFailure ? error.code : FailureCode.sourceFailed;

  Future<T> _bounded<T>(Future<T> call) => call.timeout(
    drainTimeout,
    onTimeout: () => throw const AppFailure(FailureCode.cleanupPending),
  );

  Future<void> _drainCandidate(String path) async {
    // A previous failed recovery can still own its environment.
    if (_nativeStarted) await _closeBrowser();
    _session = ++_sequence;
    _document = 0;
    _nativeStarted = true;
    await _bounded(
      browser.open(
        session: _session!,
        profilePath: path,
        target: target,
        recoveryOnly: true,
      ),
    );
    await _closeBrowser();
  }

  Future<void> _closeBrowser() async {
    if (!_nativeStarted) return;
    final session = _session!;
    await _bounded(browser.close(session));
    final elapsed = Stopwatch()..start();
    while (!await _bounded(browser.drained(session))) {
      if (elapsed.elapsed >= drainTimeout) {
        throw const AppFailure(FailureCode.cleanupPending);
      }
      await Future<void>.delayed(pollInterval);
    }
    _nativeStarted = false;
    _session = null;
  }

  void _onEvent(BrowserEvent event) {
    if (event.session != _session ||
        event.document < _document ||
        (view.phase != ObservationPhase.open &&
            view.phase != ObservationPhase.opening)) {
      return;
    }
    final changedDocument = event.document != _document;
    _document = event.document;
    if (event.diagnostic case final diagnostic?) {
      _diagnostics.add(diagnostic);
      if (_diagnostics.length > 20) _diagnostics.removeAt(0);
    }
    if (changedDocument || event.kind == BrowserEventKind.navigating) {
      _youngInspection = null;
      _clearReadOnly();
      _loginOperation = null;
      _loginDocument = null;
      if (_businessActive) {
        _businessRouteChanged = true;
        _businessCancelled = true;
        unawaited(closeSession().catchError((Object _) {}));
      } else {
        _businessView = const YoungBusinessView();
      }
      ++_probeRevision;
      if (_probeActive) {
        _probeCancelled = true;
        // A new document cannot acknowledge the old document's fetch abort.
        // Close and prove whole-browser drain before another operation.
        unawaited(closeSession().catchError((Object _) {}));
      } else {
        _publishProbe(phase: JwProbePhase.idle, code: JwProbeCode.pending);
        _clearDataProbe();
      }
    }
    if (event.kind == BrowserEventKind.diagnostic) {
      _publish(
        view.phase,
        origin: view.origin,
        ready: view.ready,
        blocked: view.blocked,
        failure: view.failure,
      );
      return;
    }
    ++_check;
    final origin = target.allowedOrigins.contains(event.origin)
        ? event.origin
        : null;
    switch (event.kind) {
      case BrowserEventKind.navigating:
        _publish(view.phase, origin: origin);
      case BrowserEventKind.ready:
        _publish(
          view.phase,
          origin: origin,
          ready: origin == target.initialUri.origin,
        );
      case BrowserEventKind.blocked:
        _publish(view.phase, origin: origin, blocked: true);
      case BrowserEventKind.diagnostic:
        break;
      case BrowserEventKind.userClosed:
      case BrowserEventKind.failed:
        unawaited(closeSession().catchError((Object _) {}));
    }
  }

  void _requireOpen() {
    if (view.phase != ObservationPhase.open || _session == null) {
      throw const AppFailure(FailureCode.busy);
    }
  }

  @override
  Future<void> inspect() async {
    _requireOpen();
    final session = _session!;
    final document = _document;
    final check = ++_check;
    final result = await browser
        .inspect(session: session, document: document)
        .timeout(
          drainTimeout,
          onTimeout: () => throw const AppFailure(FailureCode.sourceFailed),
        );
    if (view.phase != ObservationPhase.open ||
        session != _session ||
        document != _document ||
        check != _check ||
        result.session != session ||
        result.document != document) {
      throw const AppFailure(FailureCode.staleResult);
    }
    final origin = target.allowedOrigins.contains(result.origin)
        ? result.origin
        : null;
    _publish(
      ObservationPhase.open,
      origin: origin,
      ready: result.ready && origin == target.initialUri.origin,
    );
  }

  @override
  Future<void> inspectYoungPage() async {
    _requireOpen();
    final port = browser;
    if (target.source != ObservationSource.young ||
        port is! YoungInspectionBrowserPort) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    if (_youngInspectPending || _readOnlyPending) {
      throw const AppFailure(FailureCode.busy);
    }
    _youngInspectPending = true;
    _youngInspection = null;
    final session = _session!, document = _document, check = ++_check;
    _publish(ObservationPhase.open, origin: view.origin, ready: view.ready);
    try {
      final result = await (port as YoungInspectionBrowserPort)
          .inspectYoungPage(session: session, document: document)
          .timeout(drainTimeout);
      if (view.phase != ObservationPhase.open ||
          _session != session ||
          _document != document ||
          check != _check ||
          result.session != session ||
          result.document != document) {
        throw const AppFailure(FailureCode.staleResult);
      }
      _youngInspection = result;
      _publish(ObservationPhase.open, origin: view.origin, ready: view.ready);
    } on TimeoutException {
      // An unacknowledged native script must drain before the lease is freed.
      await closeSession();
      throw const AppFailure(FailureCode.sourceFailed);
    } finally {
      _youngInspectPending = false;
    }
  }

  @override
  Future<void> startReadOnlyInspection() => _readOnlyCall(starting: true);

  @override
  Future<void> navigateYoungPage(YoungBusinessPage page) async {
    _requireOpen();
    if (!_businessAvailable ||
        _businessActive ||
        _readOnlyPending ||
        _youngInspectPending ||
        _youngPreparePending ||
        _loginPending) {
      throw const AppFailure(FailureCode.busy);
    }
    final native = browser as YoungBusinessBrowserPort;
    final session = _session!, document = _document;
    _clearReadOnly();
    _youngInspection = null;
    _businessView = const YoungBusinessView();
    try {
      await native
          .navigateYoungBusinessPage(
            session: session,
            document: document,
            page: page,
          )
          .timeout(drainTimeout);
      if (_session == session &&
          _document == document &&
          view.phase == ObservationPhase.open) {
        _publish(ObservationPhase.open, origin: view.origin);
      }
    } on AppFailure catch (error) {
      // Both the Dart admission guard and the fixed native endpoint use busy
      // only before issuing Navigate. Keep the session for a bounded wait.
      if (error.code == FailureCode.busy) rethrow;
      await closeSession();
      throw const AppFailure(FailureCode.sourceFailed);
    } catch (_) {
      await closeSession();
      throw const AppFailure(FailureCode.sourceFailed);
    }
  }

  /// Fixed route/helper readiness is separate from document load readiness.
  /// A false result grants no read capability and contains no page values.
  Future<bool> prepareYoungPage(YoungBusinessPage page) async {
    _requireOpen();
    if (!_businessAvailable ||
        _businessActive ||
        _youngPreparePending ||
        _loginPending ||
        _readOnlyPending ||
        _readOnlyInspection?.listening == true) {
      return false;
    }
    final port = browser;
    if (port is! YoungBusinessPreparationBrowserPort) return true;
    final session = _session!, document = _document;
    _youngPreparePending = true;
    try {
      final ready = await (port as YoungBusinessPreparationBrowserPort)
          .prepareYoungBusinessPage(
            session: session,
            document: document,
            page: page,
          )
          .timeout(
            drainTimeout,
            onTimeout: () => throw const YoungBusinessException(
              FailureCode.sourceFailed,
              YoungBusinessRejection.preparationTimedOut,
            ),
          );
      if (_session != session ||
          _document != document ||
          view.phase != ObservationPhase.open) {
        throw const YoungBusinessException(
          FailureCode.staleResult,
          YoungBusinessRejection.stampChanged,
        );
      }
      return ready && _businessAvailable;
    } on YoungBusinessException catch (error) {
      if (error.reason == YoungBusinessRejection.preparationTimedOut) {
        // A native call with no acknowledgement must drain before another
        // preparation/read is admitted. A timeout is a source failure, not SQL.
        await closeSession();
      }
      rethrow;
    } finally {
      _youngPreparePending = false;
    }
  }

  @override
  Future<void> probeYoungActivities(String expectedAccountCode) async {
    await _runYoungBusiness(expectedAccountCode);
  }

  @override
  Future<void> probeYoungCalendar({
    required String expectedAccountCode,
    required DateTime firstDay,
    required DateTime lastDay,
  }) async {
    await _runYoungBusiness(
      expectedAccountCode,
      firstDay: firstDay,
      lastDay: lastDay,
    );
  }

  /// Private C1 handoff. Candidate diagnostics never supply C3 authority.
  Future<YoungCollectedArtifact> collectYoungSealed({
    required YoungWorkStamp stamp,
    required YoungPartitionRef partition,
    required String expectedAccountCode,
    required AppClock clock,
    DateTime? firstDay,
    DateTime? lastDay,
  }) async {
    if ((stamp.kind == YoungJobKind.calendar) != (firstDay != null) ||
        (firstDay == null) != (lastDay == null)) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    final result = await _runYoungBusiness(
      expectedAccountCode,
      firstDay: firstDay,
      lastDay: lastDay,
      sealStamp: stamp,
      sealPartition: partition,
      clock: clock,
    );
    return result ?? (throw const AppFailure(FailureCode.invalidSnapshot));
  }

  @override
  Future<void> cancelYoungBusinessProbe() => closeSession();

  Future<YoungCollectedArtifact?> _runYoungBusiness(
    String expectedAccountCode, {
    DateTime? firstDay,
    DateTime? lastDay,
    YoungWorkStamp? sealStamp,
    YoungPartitionRef? sealPartition,
    AppClock clock = const SystemClock(),
  }) async {
    _requireOpen();
    if (!_businessAvailable ||
        _businessActive ||
        _readOnlyPending ||
        _readOnlyInspection?.listening == true ||
        _youngInspectPending ||
        _youngPreparePending ||
        _loginPending) {
      throw const AppFailure(FailureCode.busy);
    }
    final expected = expectedAccountCode.trim();
    if (expected.isEmpty ||
        expected.length > 64 ||
        expected.runes.any((c) => c <= 32 || (c >= 127 && c <= 159)) ||
        RegExp(r'\s').hasMatch(expected)) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    final start = firstDay == null
        ? null
        : DateTime.utc(firstDay.year, firstDay.month, firstDay.day);
    final end = lastDay == null
        ? null
        : DateTime.utc(lastDay.year, lastDay.month, lastDay.day);
    if ((start == null) != (end == null) ||
        (start != null &&
            end != null &&
            (start.year < 1 ||
                end.year > 9999 ||
                end.isBefore(start) ||
                end.difference(start).inDays >= 62))) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    final native = browser as YoungBusinessBrowserPort;
    final session = _session!,
        document = _document,
        operation = ++_businessSequence;
    final work = Completer<void>();
    _businessWork = work.future;
    _businessActive = true;
    _businessCancelled = false;
    _businessRouteChanged = false;
    var identity = YoungBusinessIdentity.notValidated;
    var stage = YoungBusinessStage.starting;
    var identityReads = 0,
        activities = 0,
        activityPages = 0,
        rows = 0,
        excluded = 0,
        days = 0,
        calendarPages = 0;
    final linked = <String, YoungCalendarEntry>{};
    final allSeen = <String, YoungCalendarEntry>{};
    final activityRecords = <YoungActivity>[];
    YoungProfileCandidate? profileBefore, profileAfter;
    YoungCollectedArtifact? sealed;
    Object? collectionError;
    var step = 0;
    FailureCode? failure;
    YoungBusinessRejection? rejection;
    bool closeRequired = false;
    final elapsed = Stopwatch()..start();
    void publish(YoungBusinessPhase phase) {
      _businessView = YoungBusinessView(
        phase: phase,
        identity: identity,
        stage: stage,
        failure: failure,
        rejection: rejection,
        busy: _businessActive,
        available: _businessAvailable,
        identityReads: identityReads,
        activities: activities,
        activityPages: activityPages,
        calendarRows: rows,
        excludedSchedules: excluded,
        linkedSchedules: linked.length,
        days: days,
        calendarPages: calendarPages,
      );
      _businessChanges.add(_businessView);
    }

    void current() {
      if (_businessCancelled ||
          _shuttingDown ||
          _session != session ||
          _document != document ||
          view.phase != ObservationPhase.open ||
          !view.ready ||
          view.origin != target.initialUri.origin) {
        throw YoungBusinessException(
          FailureCode.staleResult,
          _businessRouteChanged
              ? YoungBusinessRejection.mainRoute
              : YoungBusinessRejection.stampChanged,
        );
      }
      if (elapsed.elapsed > dataProbeTimeout) {
        throw const AppFailure(FailureCode.incompleteSnapshot);
      }
    }

    Future<Object?> read(
      YoungBusinessEndpoint endpoint, {
      int page = 0,
      String? day,
    }) async {
      current();
      final ownStep = ++step;
      await native
          .dispatchYoungBusinessStep(
            session: session,
            document: document,
            operation: operation,
            step: ownStep,
            endpoint: endpoint,
            page: page,
            day: day,
          )
          .timeout(drainTimeout);
      final stepTime = Stopwatch()..start();
      while (true) {
        current();
        final reply = await native
            .pollYoungBusinessStep(
              session: session,
              document: document,
              operation: operation,
              step: ownStep,
            )
            .timeout(drainTimeout);
        current();
        if (reply.session != session ||
            reply.document != document ||
            reply.operation != operation ||
            reply.step != ownStep) {
          throw const AppFailure(FailureCode.staleResult);
        }
        if (reply.complete) return jsonDecode(reply.projectedJson!);
        if (stepTime.elapsed > probeTimeout) {
          throw const AppFailure(FailureCode.incompleteSnapshot);
        }
        await Future<void>.delayed(pollInterval);
      }
    }

    Future<void> profile() async {
      final candidate = decodeYoungProfile(
        await read(YoungBusinessEndpoint.profile),
      );
      ++identityReads;
      if (identityReads == 1) {
        profileBefore = candidate;
      } else {
        profileAfter = candidate;
        if (candidate.username != profileBefore!.username &&
            sealStamp != null) {
          throw const YoungIdentityException(
            YoungIdentityFailure.evidenceConflict,
          );
        }
      }
      if (candidate.username != expected) {
        identity = YoungBusinessIdentity.accountMismatch;
        if (sealStamp != null) {
          throw const YoungIdentityException(
            YoungIdentityFailure.accountMismatch,
          );
        }
        throw const AppFailure(FailureCode.invalidSnapshot);
      }
    }

    publish(YoungBusinessPhase.running);
    try {
      await native
          .startYoungBusiness(
            session: session,
            document: document,
            operation: operation,
          )
          .timeout(drainTimeout);
      current();
      stage = YoungBusinessStage.profileBefore;
      publish(YoungBusinessPhase.running);
      await profile();
      if (start == null) {
        stage = YoungBusinessStage.activities;
        publish(YoungBusinessPhase.running);
        final pages = YoungPageAccumulator<YoungActivity>(
          decodePage: decodeYoungActivityPage,
          idOf: (r) => r.id,
        );
        for (var page = 1; !pages.isComplete; ++page) {
          pages.addResponse(
            requestedPage: page,
            response: await read(YoungBusinessEndpoint.activities, page: page),
          );
          ++activityPages;
          publish(YoungBusinessPhase.running);
        }
        activities = pages.completedRecords.length;
        activityRecords.addAll(pages.completedRecords);
      } else {
        stage = YoungBusinessStage.calendar;
        publish(YoungBusinessPhase.running);
        for (
          var day = start;
          !day.isAfter(end!);
          day = day.add(const Duration(days: 1))
        ) {
          final date =
              '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
          final pages = YoungPageAccumulator<YoungCalendarEntry>(
            decodePage: decodeYoungCalendarPage,
            idOf: (r) => r.id,
          );
          for (var page = 1; !pages.isComplete; ++page) {
            pages.addResponse(
              requestedPage: page,
              response: await read(
                YoungBusinessEndpoint.schedule,
                page: page,
                day: date,
              ),
            );
            ++calendarPages;
          }
          for (final record in pages.completedRecords) {
            final dayStart = day.subtract(const Duration(hours: 8));
            if (!record.startsAtUtc.isBefore(
                  dayStart.add(const Duration(days: 1)),
                ) ||
                !record.endsAtUtc.isAfter(dayStart)) {
              throw const AppFailure(FailureCode.invalidSnapshot);
            }
            if (++rows > 10000) {
              throw const AppFailure(FailureCode.incompleteSnapshot);
            }
            final previous = allSeen[record.id];
            if (previous != null &&
                (previous.itemId != record.itemId ||
                    previous.title != record.title ||
                    previous.place != record.place ||
                    previous.startsAtUtc != record.startsAtUtc ||
                    previous.endsAtUtc != record.endsAtUtc)) {
              throw const AppFailure(FailureCode.invalidSnapshot);
            }
            allSeen[record.id] = record;
            if (record.itemId == null) {
              ++excluded;
              continue;
            }
            linked[record.id] = record;
          }
          ++days;
          publish(YoungBusinessPhase.running);
        }
      }
      stage = YoungBusinessStage.profileAfter;
      publish(YoungBusinessPhase.running);
      await profile();
      current();
      identity = YoungBusinessIdentity.candidateMatches;
      if (sealStamp != null) {
        sealed = YoungCollectedArtifact.seal(
          profileBefore: profileBefore!,
          profileAfter: profileAfter!,
          stamp: sealStamp,
          partition: sealPartition!,
          session: session,
          document: document,
          operation: operation,
          collectedAtUtc: clock.nowUtc,
          activities: activityRecords,
          entries: linked.values.toList(),
          activityPages: activityPages,
          calendarPages: calendarPages,
          calendarRows: rows,
          excludedSchedules: excluded,
          days: days,
          firstDay: start,
          lastDay: end,
        );
      }
      stage = YoungBusinessStage.stopping;
      publish(YoungBusinessPhase.running);
      await native
          .finishYoungBusiness(
            session: session,
            document: document,
            operation: operation,
          )
          .timeout(drainTimeout);
      current();
    } catch (error) {
      collectionError =
          error is AppFailure ||
              error is YoungIdentityException ||
              error is YoungBusinessException
          ? error
          : const AppFailure(FailureCode.sourceFailed);
      failure = error is YoungBusinessException
          ? error.code
          : error is AppFailure
          ? error.code
          : error is YoungIdentityException
          ? FailureCode.invalidSnapshot
          : FailureCode.sourceFailed;
      if (_businessCancelled) failure = FailureCode.cancelled;
      rejection = error is YoungBusinessException ? error.reason : null;
      if (identity != YoungBusinessIdentity.accountMismatch) {
        identity = YoungBusinessIdentity.unverified;
      }
      closeRequired = true;
    } finally {
      _businessActive = false;
      publish(
        failure == null ? YoungBusinessPhase.done : YoungBusinessPhase.failed,
      );
      linked.clear();
      allSeen.clear();
      activityRecords.clear();
      if (identical(_businessWork, work.future)) _businessWork = null;
      work.complete();
    }
    if (closeRequired) {
      try {
        await closeSession();
      } catch (_) {
        failure = FailureCode.cleanupPending;
        publish(YoungBusinessPhase.failed);
        if (collectionError is! YoungIdentityException) {
          collectionError = const AppFailure(FailureCode.cleanupPending);
        }
      }
    }
    if (sealStamp != null && failure != null) {
      throw collectionError ?? AppFailure(failure);
    }
    return failure == null ? sealed : null;
  }

  @override
  Future<void> refreshReadOnlyInspection() => _readOnlyCall();

  @override
  Future<void> stopReadOnlyInspection() => _readOnlyCall(stopping: true);

  Future<void> _readOnlyCall({
    bool starting = false,
    bool stopping = false,
  }) async {
    _requireOpen();
    final port = browser;
    if (_shuttingDown ||
        target.source != ObservationSource.young ||
        port is! YoungReadOnlyBrowserPort) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    if (!view.ready ||
        view.origin != target.initialUri.origin ||
        _youngInspectPending ||
        _readOnlyPending ||
        _businessActive ||
        (starting && _readOnlyInspection?.listening == true) ||
        (!starting && _readOnlyInspection?.listening != true)) {
      throw const AppFailure(FailureCode.busy);
    }
    _readOnlyPending = true;
    final session = _session!, document = _document;
    final revision = _readOnlyRevision;
    final operation = starting ? ++_readOnlySequence : _readOnlyOperation!;
    if (starting) {
      _readOnlyOperation = operation;
      _readOnlyInspection = null;
      _readOnlyChanges.add(null);
    }
    final native = port as YoungReadOnlyBrowserPort;
    void checkCurrent() {
      if (_shuttingDown ||
          view.phase != ObservationPhase.open ||
          !view.ready ||
          _session != session ||
          _document != document ||
          _readOnlyRevision != revision ||
          _readOnlyOperation != operation) {
        throw const AppFailure(FailureCode.staleResult);
      }
    }

    try {
      var result =
          await (starting
                  ? native.startYoungReadOnly(
                      session: session,
                      document: document,
                      operation: operation,
                    )
                  : native.readYoungReadOnly(
                      session: session,
                      document: document,
                      operation: operation,
                    ))
              .timeout(drainTimeout);
      checkCurrent();
      if (result.session != session ||
          result.document != document ||
          result.operation != operation ||
          !result.listening) {
        throw const AppFailure(FailureCode.invalidSnapshot);
      }
      if (stopping) {
        await native
            .stopYoungReadOnly(
              session: session,
              document: document,
              operation: operation,
            )
            .timeout(drainTimeout);
        checkCurrent();
        result = result.withListening(false);
      }
      _readOnlyInspection = result;
      _readOnlyChanges.add(result);
    } on TimeoutException {
      await closeSession();
      throw const AppFailure(FailureCode.sourceFailed);
    } on AppFailure catch (error) {
      // A rejected or unacknowledged observer must not survive a failed RPC.
      // Navigation already revokes its current-document binding natively.
      if (error.code == FailureCode.busy) {
        if (starting && _readOnlyOperation == operation) _clearReadOnly();
      } else if (error.code != FailureCode.staleResult) {
        await closeSession();
      }
      rethrow;
    } catch (_) {
      await closeSession();
      throw const AppFailure(FailureCode.sourceFailed);
    } finally {
      _readOnlyPending = false;
    }
  }

  @override
  Future<void> navigateInitial() async {
    _requireOpen();
    if (_probeActive ||
        _youngInspectPending ||
        _readOnlyPending ||
        _businessActive) {
      throw const AppFailure(FailureCode.busy);
    }
    _youngInspection = null;
    _clearReadOnly();
    ++_probeRevision;
    _publishProbe(phase: JwProbePhase.idle, code: JwProbeCode.pending);
    _clearDataProbe();
    ++_check;
    _publish(ObservationPhase.open);
    await browser
        .navigateInitial(_session!)
        .timeout(
          drainTimeout,
          onTimeout: () => throw const AppFailure(FailureCode.sourceFailed),
        );
  }

  @override
  Future<void> navigateJwPage(JwObservationPage page) async {
    _requireOpen();
    if (target.source != ObservationSource.jw) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    if (!view.ready ||
        view.origin != target.initialUri.origin ||
        _probeActive) {
      throw const AppFailure(FailureCode.busy);
    }
    final session = _session!;
    final document = _document;
    ++_probeRevision;
    _publishProbe(phase: JwProbePhase.idle, code: JwProbeCode.pending);
    _clearDataProbe();
    ++_check;
    _publish(ObservationPhase.open);
    await browser
        .navigateJwPage(session: session, document: document, page: page)
        .timeout(
          drainTimeout,
          onTimeout: () => throw const AppFailure(FailureCode.sourceFailed),
        );
  }

  /// Preparations contain no secret and issue one current-document sink.
  Future<JwLoginState> advanceLogin() async {
    _requireOpen();
    if (_loginPending ||
        _probeActive ||
        _businessActive ||
        _youngPreparePending ||
        _readOnlyPending ||
        _readOnlyInspection?.listening == true) {
      throw const AppFailure(FailureCode.busy);
    }
    final port = browser;
    final young = target.source == ObservationSource.young;
    if (young
        ? port is! YoungAuthenticationBrowserPort
        : port is! JwAuthenticationBrowserPort) {
      return JwLoginState.manualRequired;
    }
    _loginPending = true;
    _loginOperation = null;
    _loginDocument = null;
    final session = _session!;
    final document = _document;
    final operation = ++_loginSequence;
    try {
      final call = young
          ? (port as YoungAuthenticationBrowserPort).advanceYoungLogin(
              session: session,
              document: document,
              operation: operation,
            )
          : (port as JwAuthenticationBrowserPort).advanceJwLogin(
              session: session,
              document: document,
              operation: operation,
            );
      final state = await call.timeout(
        drainTimeout,
        onTimeout: () => throw const AppFailure(FailureCode.sourceFailed),
      );
      if (_session != session ||
          _document != document ||
          view.phase != ObservationPhase.open) {
        throw const AppFailure(FailureCode.staleResult);
      }
      if (state == JwLoginState.formReady) {
        _loginOperation = operation;
        _loginDocument = document;
      }
      return state;
    } finally {
      _loginPending = false;
    }
  }

  Future<JwLoginState> submitLogin(JwSecretLease credentials) async {
    final operation = _loginOperation;
    final document = _loginDocument;
    _loginOperation = null;
    _loginDocument = null;
    final port = browser;
    final young = target.source == ObservationSource.young;
    if (operation == null ||
        document != _document ||
        _session == null ||
        view.phase != ObservationPhase.open ||
        _loginPending ||
        _probeActive ||
        _businessActive ||
        _readOnlyPending ||
        _readOnlyInspection?.listening == true ||
        _youngPreparePending ||
        (young
            ? port is! YoungAuthenticationBrowserPort
            : port is! JwAuthenticationBrowserPort)) {
      credentials.revoke();
      throw const AppFailure(FailureCode.staleResult);
    }
    _loginPending = true;
    try {
      final call = young
          ? (port as YoungAuthenticationBrowserPort).submitYoungLogin(
              session: _session!,
              document: document!,
              operation: operation,
              credentials: credentials,
            )
          : (port as JwAuthenticationBrowserPort).submitJwLogin(
              session: _session!,
              document: document!,
              operation: operation,
              credentials: credentials,
            );
      return await call.timeout(
        drainTimeout,
        onTimeout: () => throw const AppFailure(FailureCode.sourceFailed),
      );
    } finally {
      credentials.revoke();
      _loginPending = false;
    }
  }

  @override
  Future<void> closeSession() {
    if (view.phase == ObservationPhase.closed) return Future.value();
    if (view.phase == ObservationPhase.idle && _lease == null) {
      return Future.value();
    }
    if (_cleanupFuture != null) return _cleanupFuture!;
    _cancelled = true;
    _businessCancelled = true;
    _youngInspection = null;
    _clearReadOnly();
    _loginOperation = null;
    _loginDocument = null;
    _probeCancelled = true;
    ++_probeRevision;
    ++_check;
    _publish(ObservationPhase.closing);
    _publishProbe(
      phase: _probeActive ? JwProbePhase.cancelled : probeView.phase,
      code: _probeActive ? JwProbeCode.cancelled : probeView.code,
      summary: probeView.summary,
      semesters: probeView.semesters,
      stage: probeView.stage,
      failure: probeView.failure,
    );
    _publishDataProbe(
      phase: _dataActive ? JwProbePhase.cancelled : dataProbeView.phase,
      code: _dataActive ? JwDataProbeCode.cancelled : dataProbeView.code,
      diagnostics: _dataActive ? null : dataProbeView.diagnostics,
      stage: dataProbeView.stage,
      failure: dataProbeView.failure,
    );
    return _cleanupFuture = () async {
      try {
        // Cancel a native creation immediately. Its late callbacks must still
        // finish, but they must already see native closing=true.
        if (_nativeStarted) await _bounded(browser.close(_session!));
        await _work?.timeout(
          drainTimeout,
          onTimeout: () {
            throw const AppFailure(FailureCode.cleanupPending);
          },
        );
        await _probeWork?.timeout(
          drainTimeout,
          onTimeout: () => throw const AppFailure(FailureCode.cleanupPending),
        );
        await _businessWork?.timeout(
          drainTimeout,
          onTimeout: () => throw const AppFailure(FailureCode.cleanupPending),
        );
        await _closeBrowser();
        await assets.cleanup();
        await assets.recoverPending(_drainCandidate);
        _release();
        _publish(ObservationPhase.idle);
      } catch (error) {
        _publish(ObservationPhase.recovery, failure: _code(error));
        throw AppFailure(_code(error));
      } finally {
        _cleanupFuture = null;
      }
    }();
  }

  void _release() {
    if (borrowedLease == null) _lease?.release();
    _lease = null;
  }

  WorkLease _acquireLease() {
    final borrowed = borrowedLease;
    if (borrowed == null) return leases.acquire();
    if (!borrowed.isHeld || !borrowed.belongsTo(leases)) {
      throw const AppFailure(FailureCode.staleResult);
    }
    return borrowed;
  }

  /// Internal P recovery for a registered profile; no school navigation occurs.
  Future<void> drainRegisteredProfile(String path) async {
    if (view.phase != ObservationPhase.idle) {
      throw const AppFailure(FailureCode.busy);
    }
    _lease = _acquireLease();
    _publish(ObservationPhase.closing);
    try {
      await _drainCandidate(path);
      _release();
      _publish(ObservationPhase.idle);
    } catch (error) {
      _publish(ObservationPhase.recovery, failure: _code(error));
      rethrow;
    }
  }

  /// Internal C1 handoff. Payload and school identity never enter view streams.
  Future<JwCollectedArtifact> collectSealed({
    required JwWorkStamp stamp,
    required JwPartitionRef partition,
    required int semesterId,
    required AppClock clock,
  }) async {
    _requireOpen();
    final port = browser;
    if (!_probeAvailable ||
        _probeActive ||
        port is! JwCollectionBrowserPort ||
        !probeView.semesters.any((s) => s.id == semesterId)) {
      throw const AppFailure(FailureCode.busy);
    }
    final collection = port as JwCollectionBrowserPort;
    final session = _session!, document = _document, revision = _probeRevision;
    final operation = ++_probeSequence;
    final done = Completer<void>();
    _probeWork = done.future;
    _probeActive = true;
    _probeCancelled = false;
    try {
      final elapsed = Stopwatch()..start();
      var reply = await _bounded(
        collection.startJwCollection(
          session: session,
          document: document,
          operation: operation,
          semesterId: semesterId,
        ),
      );
      while (reply.probe.phase == JwProbePhase.running) {
        if (!_probeCurrent(session, document, revision)) {
          throw const AppFailure(FailureCode.cancelled);
        }
        if (elapsed.elapsed >= dataProbeTimeout) {
          throw const AppFailure(FailureCode.cleanupPending);
        }
        await Future<void>.delayed(pollInterval);
        if (!_probeCurrent(session, document, revision)) {
          throw const AppFailure(FailureCode.cancelled);
        }
        reply = await _bounded(
          collection.pollJwCollection(
            session: session,
            document: document,
            operation: operation,
          ),
        );
      }
      if (!_probeCurrent(session, document, revision)) {
        throw const AppFailure(FailureCode.cancelled);
      }
      if (reply.probe.phase != JwProbePhase.done ||
          reply.probe.code != JwDataProbeCode.ok) {
        throw JwCollectionException(reply.probe.code);
      }
      return JwCollectedArtifact.seal(
        reply: reply,
        stamp: stamp,
        partition: partition,
        session: session,
        document: document,
        semesterId: semesterId,
        collectedAtUtc: clock.nowUtc,
      );
    } finally {
      _probeActive = false;
      _probeWork = null;
      done.complete();
      _refreshProbeAvailability();
    }
  }

  @override
  Future<void> retryCleanup() => closeSession();

  @override
  Future<void> runProbe(String expectedAccountCode) {
    try {
      _requireOpen();
      if (!_probeAvailable || _probeActive) {
        throw const AppFailure(FailureCode.busy);
      }
      // C3 owns the expected value; it is never passed to the browser helper.
      final verifier = JwCandidateIdentityVerifier(expectedAccountCode);
      final session = _session!;
      final document = _document;
      final operation = ++_probeSequence;
      final revision = ++_probeRevision;
      _probeActive = true;
      _probeCancelled = false;
      final done = Completer<void>();
      _probeWork = done.future;
      _publishProbe(phase: JwProbePhase.running, code: JwProbeCode.pending);
      return _runProbe(
        verifier: verifier,
        session: session,
        document: document,
        operation: operation,
        revision: revision,
        done: done,
      );
    } on AppFailure catch (error) {
      return Future.error(error);
    }
  }

  bool _probeCurrent(int session, int document, int revision) =>
      (_lease?.isHeld ?? false) &&
      !_probeCancelled &&
      !_shuttingDown &&
      view.phase == ObservationPhase.open &&
      _session == session &&
      _document == document &&
      _probeRevision == revision;

  Future<void> _runProbe({
    required JwCandidateIdentityVerifier verifier,
    required int session,
    required int document,
    required int operation,
    required int revision,
    required Completer<void> done,
  }) async {
    bool closeRequired = false;
    final port = browser as JwProbeBrowserPort;
    final elapsed = Stopwatch()..start();
    try {
      var reply = await _bounded(
        port.startJwProbe(
          session: session,
          document: document,
          operation: operation,
        ),
      );
      while (reply.phase == JwProbePhase.running) {
        if (!_probeCurrent(session, document, revision)) return;
        if (elapsed.elapsed >= probeTimeout) {
          throw const AppFailure(FailureCode.cleanupPending);
        }
        await Future<void>.delayed(pollInterval);
        if (!_probeCurrent(session, document, revision)) return;
        reply = await _bounded(
          port.pollJwProbe(
            session: session,
            document: document,
            operation: operation,
          ),
        );
      }
      if (!_probeCurrent(session, document, revision)) return;
      _publishProbe(
        phase: reply.phase,
        code: reply.code,
        identity: verifier.evaluate(reply),
        summary: reply.summary,
        semesters: reply.semesters ?? const [],
        stage: reply.stage,
      );
    } catch (error) {
      if (!_probeCancelled) {
        closeRequired = true;
        _publishProbe(
          phase: JwProbePhase.failed,
          code: JwProbeCode.helperUnavailable,
          failure: _code(error),
        );
      }
    } finally {
      _probeActive = false;
      _probeWork = null;
      done.complete();
      _refreshProbeAvailability();
    }
    if (closeRequired) {
      // Failure may leave an unacknowledged native request. Cleanup owns the
      // existing global lease until its process-group proof succeeds.
      await closeSession();
    }
  }

  @override
  Future<void> cancelProbe() => closeSession();

  @override
  Future<void> runDataProbe(
    String expectedAccountCode, {
    required int semesterId,
  }) {
    try {
      _requireOpen();
      if (!_probeAvailable ||
          browser is! JwDataProbeBrowserPort ||
          _probeActive) {
        throw const AppFailure(FailureCode.busy);
      }
      if (probeView.summary?.stageResults['course'] != JwProbeCode.ok ||
          !probeView.semesters.any((semester) => semester.id == semesterId)) {
        throw const AppFailure(FailureCode.invalidSnapshot);
      }
      final verifier = JwCandidateIdentityVerifier(expectedAccountCode);
      final session = _session!, document = _document;
      final operation = ++_probeSequence, revision = ++_probeRevision;
      _probeActive = true;
      _dataActive = true;
      _probeCancelled = false;
      final done = Completer<void>();
      _probeWork = done.future;
      _publishDataProbe(
        phase: JwProbePhase.running,
        code: JwDataProbeCode.pending,
      );
      _refreshProbeAvailability();
      return _runDataProbe(
        verifier: verifier,
        session: session,
        document: document,
        operation: operation,
        revision: revision,
        semesterId: semesterId,
        done: done,
      );
    } on AppFailure catch (error) {
      return Future.error(error);
    }
  }

  Future<void> _runDataProbe({
    required JwCandidateIdentityVerifier verifier,
    required int session,
    required int document,
    required int operation,
    required int revision,
    required int semesterId,
    required Completer<void> done,
  }) async {
    bool closeRequired = false;
    final port = browser as JwDataProbeBrowserPort;
    final elapsed = Stopwatch()..start();
    try {
      var reply = await _bounded(
        port.startJwDataProbe(
          session: session,
          document: document,
          operation: operation,
          semesterId: semesterId,
        ),
      );
      while (reply.phase == JwProbePhase.running) {
        if (!_probeCurrent(session, document, revision)) return;
        _publishDataProbe(
          phase: reply.phase,
          code: reply.code,
          diagnostics: reply.diagnostics,
          stage: reply.stage,
        );
        if (elapsed.elapsed >= dataProbeTimeout) {
          throw const AppFailure(FailureCode.cleanupPending);
        }
        await Future<void>.delayed(pollInterval);
        if (!_probeCurrent(session, document, revision)) return;
        reply = await _bounded(
          port.pollJwDataProbe(
            session: session,
            document: document,
            operation: operation,
          ),
        );
      }
      if (!_probeCurrent(session, document, revision)) return;
      _publishDataProbe(
        phase: reply.phase,
        code: reply.code,
        identity: verifier.evaluateData(reply),
        diagnostics: reply.diagnostics,
        stage: reply.stage,
      );
    } catch (error) {
      if (!_probeCancelled) {
        closeRequired = true;
        _publishDataProbe(
          phase: JwProbePhase.failed,
          code: JwDataProbeCode.helperUnavailable,
          failure: _code(error),
        );
      }
    } finally {
      _dataActive = false;
      _probeActive = false;
      _probeWork = null;
      done.complete();
      _refreshProbeAvailability();
    }
    if (closeRequired) await closeSession();
  }

  @override
  Future<void> cancelDataProbe() => closeSession();

  Future<void> shutdown() => _shutdownFuture ??= () async {
    _shuttingDown = true;
    try {
      await closeSession();
      await assets.close();
      await _subscription.cancel();
      _publish(ObservationPhase.closed);
      await _changes.close();
      await _probeChanges.close();
      await _dataProbeChanges.close();
      await _readOnlyChanges.close();
      await _businessChanges.close();
    } catch (_) {
      _shutdownFuture = null;
      _shuttingDown = false;
      rethrow;
    }
  }();
}
