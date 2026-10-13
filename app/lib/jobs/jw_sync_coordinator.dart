import 'dart:async';
import 'dart:math';

import '../core/contracts.dart';
import '../core/jw_work_contract.dart';
import '../core/jw_credentials.dart';
import '../core/observation_assets.dart';
import '../core/work_lease.dart';
import '../data/jw_candidate_identity.dart';
import '../data/jw_import_contract.dart';
import '../data/jw_store.dart';
import '../platform/jw_partition_registry.dart';
import '../source/jw_collection_contract.dart';
import '../source/jw_collection_failure.dart';
import '../source/jw_probe_contract.dart';
import '../source/jw_semester_default.dart';
import '../source/observation_contract.dart';
import '../source/jw_authentication_contract.dart';
import 'jw_sync_port.dart';
import 'observation_coordinator.dart';
import 'observation_port.dart';
import 'school_authentication_driver.dart';

/// C2 holds one lease from C3 staging through native drain, commit and claim.
final class JwSyncCoordinator implements JwSyncPort {
  JwSyncCoordinator({
    required this.store,
    required this.registry,
    required this.browser,
    required this.leases,
    this.clock = const SystemClock(),
    this.loginWaitTimeout = const Duration(seconds: 90),
    this.automationPollInterval = const Duration(milliseconds: 400),
    this.onJobAdmitted,
    ObservationTarget? target,
  }) : target = target ?? ObservationTarget.jw() {
    _credentialSubscription = store.credentialChanges.listen((_) {
      unawaited(_refreshSharedCredential().catchError((Object _) {}));
    });
  }
  final JwStore store;
  final JwPartitionRegistry registry;
  final ObservationBrowserPort browser;
  final WorkLeasePool leases;
  final AppClock clock;
  final ObservationTarget target;
  final Duration loginWaitTimeout;
  final Duration automationPollInterval;
  final Future<void> Function(JwJobTicket)? onJobAdmitted;
  final _changes = StreamController<JwSyncView>.broadcast();
  late final StreamSubscription<bool> _credentialSubscription;
  JwSyncView _view = JwSyncView();
  WorkLease? _lease;
  ObservationCoordinator? _inner;
  StreamSubscription<ObservationView>? _innerSubscription;
  JwJobTicket? _ticket;
  JwPartitionRef? _partition;
  JwImportReceipt? _receipt;
  Future<void>? _work;
  Future<void>? _finishing;
  bool _cancelled = false;
  bool _closing = false;
  bool _revokeRequired = false;
  Future<void>? _shutdown;
  bool _automatic = false;
  SchoolAuthenticationDriver _authentication = SchoolAuthenticationDriver();
  int? _requestedSemesterId;

  @override
  JwSyncView get syncView => _view;
  @override
  Stream<JwSyncView> get syncChanges => _changes.stream;

  Future<void> _refreshSharedCredential() async {
    if (_closing || _view.phase != JwSyncPhase.idle) return;
    final data = await store.readView();
    if (!_closing && _view.phase == JwSyncPhase.idle) {
      _publish(JwSyncPhase.idle, data: data);
    }
  }

  void _publish(
    JwSyncPhase phase, {
    bool? ready,
    bool? accountBound,
    bool? sessionRetained,
    bool? profileReused,
    bool clearProfileReuse = false,
    List<JwSemesterOption>? semesters,
    JwDataView? data,
    Object? error,
    bool clearError = false,
    bool? importCommitted,
    int? courseCount,
    int? examCount,
    JwCollectionNormalization? normalization,
    bool clearNormalization = false,
    JwAutomationState? automation,
    JwLoginPauseReason? loginPauseReason,
    bool clearLoginReason = false,
  }) {
    _view = JwSyncView(
      phase: phase,
      ready: ready ?? _view.ready,
      accountBound: accountBound ?? _view.accountBound,
      sessionRetained: sessionRetained ?? _view.sessionRetained,
      profileReused:
          profileReused ?? (clearProfileReuse ? null : _view.profileReused),
      semesters: semesters ?? _view.semesters,
      data: data ?? _view.data,
      importCommitted: importCommitted ?? _view.importCommitted,
      courseCount: courseCount ?? _view.courseCount,
      examCount: examCount ?? _view.examCount,
      emptyExams:
          (examCount ?? _view.examCount) == 0 &&
          (importCommitted ?? _view.importCommitted),
      failure: error is AppFailure
          ? error.code
          : error is JwCollectionValidationFailure
          ? FailureCode.invalidSnapshot
          : clearError
          ? null
          : _view.failure,
      identityFailure: error is JwIdentityException
          ? error.code
          : clearError
          ? null
          : _view.identityFailure,
      sourceFailure: error is JwCollectionException
          ? error.code
          : clearError
          ? null
          : _view.sourceFailure,
      collectionValidation: error is JwCollectionValidationFailure
          ? error
          : clearError
          ? null
          : _view.collectionValidation,
      failureStage: error != null
          ? _view.phase
          : clearError
          ? null
          : _view.failureStage,
      normalization:
          normalization ?? (clearNormalization ? null : _view.normalization),
      automation: automation ?? _view.automation,
      loginPauseReason:
          loginPauseReason ??
          (clearLoginReason ? null : _view.loginPauseReason),
      credentialFailure: error is JwCredentialException
          ? error.code
          : clearError
          ? null
          : _view.credentialFailure,
    );
    _changes.add(_view);
  }

  Object _safeError(Object error) =>
      error is AppFailure ||
          error is JwIdentityException ||
          error is JwCollectionException ||
          error is JwCollectionValidationFailure ||
          error is JwCredentialException
      ? error
      : const AppFailure(FailureCode.storageFailed);

  Future<void> _track(Future<void> Function() body) {
    final done = Completer<void>();
    _work = done.future;
    return () async {
      try {
        await body();
      } finally {
        if (identical(_work, done.future)) _work = null;
        done.complete();
        if (_lease != null &&
            _view.phase == JwSyncPhase.login &&
            (_inner?.view.phase == ObservationPhase.idle ||
                _inner?.view.phase == ObservationPhase.recovery)) {
          unawaited(cancel().catchError((Object _) {}));
        }
      }
    }();
  }

  void _acquire() {
    if (_closing || _view.phase == JwSyncPhase.closed) {
      throw const AppFailure(FailureCode.closed);
    }
    if (_lease != null || _view.phase != JwSyncPhase.idle) {
      throw const AppFailure(FailureCode.busy);
    }
    _lease = leases.acquire();
  }

  Future<void> initialize() {
    _acquire();
    _publish(JwSyncPhase.opening);
    return _track(() async {
      try {
        await _finish();
      } catch (error) {
        _publish(JwSyncPhase.recovery, error: _safeError(error), ready: false);
      }
    });
  }

  ObservationCoordinator _newInner(ObservationAssetsPort assets) =>
      ObservationCoordinator(
        browser: browser,
        assets: assets,
        leases: leases,
        borrowedLease: _lease,
        target: target,
      );

  Future<void> _disposeInner() async {
    final inner = _inner;
    if (inner == null) return;
    await inner.shutdown();
    await _innerSubscription?.cancel();
    _innerSubscription = null;
    _inner = null;
  }

  Future<void> _drain(String path) async {
    await _disposeInner();
    final inner = _newInner(const _RetainedAssets());
    _inner = inner;
    await inner.drainRegisteredProfile(path);
    await _disposeInner();
  }

  Future<List<JwPartitionRef>> _reconcile() async {
    final authority = await store.readAuthority();
    return registry.reconcile(
      await store.readCommittedPermits(),
      ownerId: authority.ownerId,
      resetEpoch: authority.resetEpoch,
      drain: _drain,
    );
  }

  @override
  Future<void> open({String? expectedAccountCode}) =>
      _open(expectedAccountCode: expectedAccountCode);

  @override
  Future<void> startSync({
    String? expectedAccountCode,
    String? password,
    bool savePassword = false,
    int? semesterId,
  }) async {
    final opening = _open(
      expectedAccountCode: expectedAccountCode,
      password: password,
      savePassword: savePassword,
      automatic: true,
      semesterId: semesterId,
    );
    password = null;
    expectedAccountCode = null;
    await opening;
    if (_automatic && !_cancelled && _view.phase == JwSyncPhase.login) {
      await continueSync();
    }
  }

  Future<void> _open({
    String? expectedAccountCode,
    String? password,
    bool savePassword = false,
    bool automatic = false,
    int? semesterId,
  }) {
    if (semesterId != null && (semesterId <= 0 || semesterId > 2147483647)) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    _acquire(); // Before C3 or any other asynchronous staging.
    _cancelled = false;
    _automatic = automatic;
    _requestedSemesterId = semesterId;
    _authentication = SchoolAuthenticationDriver();
    _publish(
      JwSyncPhase.opening,
      ready: false,
      semesters: const [],
      clearError: true,
      importCommitted: false,
      courseCount: 0,
      examCount: 0,
      clearNormalization: true,
      clearProfileReuse: true,
      clearLoginReason: true,
      automation: automatic
          ? JwAutomationState.waitingForLogin
          : JwAutomationState.none,
    );
    return _track(() async {
      try {
        _ticket = await store.beginJob(
          expectedAccountCode: expectedAccountCode,
        );
        await onJobAdmitted?.call(_ticket!);
        if (savePassword && (password?.isEmpty ?? true)) {
          throw const JwCredentialException(
            JwCredentialFailure.invalidCredential,
          );
        }
        var supplied = password;
        password = null;
        if (supplied != null) {
          try {
            await store.stageCredentials(
              _ticket!,
              supplied,
              save: savePassword,
            );
          } finally {
            supplied = null;
          }
        }
        if (_cancelled) throw const AppFailure(FailureCode.cancelled);
        final retained = await _reconcile();
        if (_cancelled) throw const AppFailure(FailureCode.cancelled);
        final authority = await store.readAuthority();
        final permits = (await store.readCommittedPermits())
            .where(
              (permit) => retained.any((ref) => ref.sameAs(permit.partition)),
            )
            .toList();
        String path;
        if (permits.isNotEmpty) {
          if (permits.length != 1) {
            throw const AppFailure(FailureCode.invalidSnapshot);
          }
          _partition = permits.single.partition;
          path = await registry.openClaimed(
            permits.single,
            ownerId: authority.ownerId,
            resetEpoch: authority.resetEpoch,
          );
        } else {
          _partition = await registry.createProvisional(
            ownerId: authority.ownerId,
            purpose: authority.accountBound
                ? JwPartitionPurpose.recovery
                : JwPartitionPurpose.initial,
            attempt: _ticket!.stamp.jobId,
            resetEpoch: authority.resetEpoch,
          );
          path = registry.profilePath(_partition!);
        }
        await store.stagePartition(_ticket!, _partition!);
        if (_cancelled) throw const AppFailure(FailureCode.cancelled);
        _inner = _newInner(_RetainedAssets(path));
        _innerSubscription = _inner!.changes.listen(_onInner);
        await _inner!.open();
        if (_cancelled) throw const AppFailure(FailureCode.cancelled);
        _publish(
          JwSyncPhase.login,
          ready: _inner!.view.ready,
          accountBound: authority.accountBound,
          profileReused: permits.isNotEmpty,
        );
      } catch (error) {
        await _fail(error);
      }
    });
  }

  @override
  Future<void> continueSync() {
    if (_view.phase != JwSyncPhase.login ||
        _work != null ||
        _ticket == null ||
        _inner == null ||
        _lease?.isHeld != true) {
      throw const AppFailure(FailureCode.busy);
    }
    _automatic = true;
    return _track(() async {
      try {
        await _runAutomatic();
      } catch (error) {
        await _fail(error);
      }
    });
  }

  void _requireAutomaticCurrent() {
    if (_cancelled ||
        _ticket == null ||
        _inner?.view.phase != ObservationPhase.open ||
        _lease?.isHeld != true) {
      throw const AppFailure(FailureCode.cancelled);
    }
  }

  void _pauseAutomatic([
    JwLoginPauseReason reason = JwLoginPauseReason.manualRequired,
  ]) => _publish(
    JwSyncPhase.login,
    ready: _inner?.view.ready ?? false,
    automation: JwAutomationState.manualRequired,
    loginPauseReason: reason,
  );

  Future<void> _runAutomatic() async {
    _publish(
      JwSyncPhase.login,
      automation: JwAutomationState.waitingForLogin,
      clearError: true,
    );
    final elapsed = Stopwatch()..start();
    while (elapsed.elapsed < loginWaitTimeout) {
      final reason = await _authentication.authenticate(
        requireCurrent: _requireAutomaticCurrent,
        advance: _inner!.advanceLogin,
        submit: _inner!.submitLogin,
        lease: () => store.leaseCredentials(_ticket!),
        progress: (progress) => _publish(
          JwSyncPhase.login,
          automation: progress == SchoolAuthenticationProgress.submitting
              ? JwAutomationState.submitting
              : JwAutomationState.waitingForLogin,
        ),
        timeout: loginWaitTimeout - elapsed.elapsed,
        pollInterval: automationPollInterval,
        manualBusinessFallback: () =>
            browser is! JwAuthenticationBrowserPort &&
            _inner!.view.ready &&
            _inner!.view.origin == target.initialUri.origin,
      );
      if (reason != null) {
        _pauseAutomatic(reason);
        return;
      }
      if (await _prepareAutomaticDirectory()) return;
      await Future<void>.delayed(automationPollInterval);
    }
    _pauseAutomatic(JwLoginPauseReason.timedOut);
  }

  Future<bool> _prepareAutomaticDirectory() async {
    _publish(
      JwSyncPhase.login,
      automation: JwAutomationState.preparing,
      semesters: const [],
    );
    final before = _inner!.documentGeneration;
    await _inner!.navigateJwPage(JwObservationPage.courseTable);
    final elapsed = Stopwatch()..start();
    while (!_inner!.view.ready || _inner!.documentGeneration <= before) {
      _requireAutomaticCurrent();
      if (_inner!.documentGeneration > before &&
          _inner!.view.origin != null &&
          _inner!.view.origin != target.initialUri.origin) {
        // The business readiness flag intentionally excludes authentication
        // origins. Resume authentication as soon as its new document arrives.
        return false;
      }
      if (elapsed.elapsed > const Duration(seconds: 30)) {
        _pauseAutomatic(JwLoginPauseReason.timedOut);
        return true;
      }
      await Future<void>.delayed(automationPollInterval);
    }
    _requireAutomaticCurrent();
    _publish(JwSyncPhase.verifying, automation: JwAutomationState.preparing);
    await _readDirectory();
    final chosen =
        _requestedSemesterId ??
        _view.data?.lastSemesterId ??
        defaultJwSemester(_view.semesters, clock.nowUtc);
    if (chosen == null || !_view.semesters.any((s) => s.id == chosen)) {
      _publish(
        JwSyncPhase.login,
        automation: JwAutomationState.choosingSemester,
      );
      return true;
    }
    await _collectAndImport(chosen);
    return true;
  }

  @override
  Future<void> deleteSavedCredential() {
    _acquire();
    return _track(() async {
      try {
        await store.deleteSavedCredential();
        _publish(
          JwSyncPhase.idle,
          data: await store.readView(),
          clearError: true,
        );
      } catch (error) {
        _publish(JwSyncPhase.idle, error: _safeError(error));
      } finally {
        _lease?.release();
        _lease = null;
      }
    });
  }

  void _onInner(ObservationView observation) {
    if (_view.phase == JwSyncPhase.login) {
      _publish(
        JwSyncPhase.login,
        ready: observation.ready,
        semesters: _inner?.probeView.semesters ?? const [],
      );
      if (observation.phase == ObservationPhase.idle &&
          _work == null &&
          _finishing == null) {
        unawaited(cancel().catchError((Object _) {}));
      }
    }
  }

  void _requireLogin() {
    if (_view.phase != JwSyncPhase.login ||
        !_view.ready ||
        _work != null ||
        _ticket == null ||
        _inner == null ||
        !_lease!.isHeld) {
      throw const AppFailure(FailureCode.busy);
    }
  }

  @override
  Future<void> navigateJwPage(JwObservationPage page) {
    _requireLogin();
    _publish(JwSyncPhase.login, ready: false, semesters: const []);
    return _track(() async {
      try {
        await _inner!.navigateJwPage(page);
      } catch (error) {
        await _fail(error);
      }
    });
  }

  @override
  Future<void> verifyDirectory() {
    _requireLogin();
    _publish(JwSyncPhase.verifying, semesters: const [], clearError: true);
    return _track(() async {
      try {
        await _readDirectory();
      } catch (error) {
        await _fail(error);
      }
    });
  }

  Future<void> _readDirectory() async {
    await _inner!.runProbe(_ticket!.expectedAccountCode);
    if (_cancelled || _inner!.view.phase != ObservationPhase.open) {
      throw const AppFailure(FailureCode.cancelled);
    }
    final probe = _inner!.probeView;
    if (probe.phase != JwProbePhase.done ||
        probe.code != JwProbeCode.ok ||
        (probe.identity != JwCandidateIdentity.candidateMatches &&
            probe.identity != JwCandidateIdentity.candidateMismatch) ||
        probe.semesters.isEmpty) {
      throw const JwIdentityException(JwIdentityFailure.identityUnverified);
    }
    // The directory grants no account or import authority. Sealing checks self.
    await store.stageSemesterCatalog(_ticket!, probe.semesters);
    _publish(
      JwSyncPhase.login,
      ready: _inner!.view.ready,
      semesters: probe.semesters,
    );
  }

  @override
  Future<void> collect(int semesterId) {
    _requireLogin();
    if (!_view.semesters.any((s) => s.id == semesterId)) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    _publish(
      JwSyncPhase.collecting,
      clearError: true,
      clearNormalization: true,
    );
    return _track(() async {
      try {
        await _collectAndImport(semesterId);
      } catch (error) {
        await _fail(error);
      }
    });
  }

  Future<void> _collectAndImport(int semesterId) async {
    _requireAutomaticCurrent();
    _publish(
      JwSyncPhase.collecting,
      clearError: true,
      clearNormalization: true,
    );
    final artifact = await _inner!.collectSealed(
      stamp: _ticket!.stamp,
      partition: _partition!,
      semesterId: semesterId,
      clock: clock,
    );
    _publish(
      JwSyncPhase.closing,
      ready: false,
      semesters: const [],
      normalization: artifact.normalization,
    );
    await _inner!.closeSession();
    if (_cancelled) throw const AppFailure(FailureCode.cancelled);
    _publish(JwSyncPhase.committing);
    _receipt = await store.importSnapshot(_ticket!, artifact);
    _publish(
      JwSyncPhase.closing,
      importCommitted: true,
      courseCount: _receipt!.courseCount,
      examCount: _receipt!.examCount,
    );
    await _finish();
  }

  Future<void> _fail(Object error) async {
    final safe = _safeError(error);
    _publish(
      JwSyncPhase.closing,
      ready: false,
      semesters: const [],
      error: safe,
    );
    try {
      if (safe is JwIdentityException &&
          safe.code == JwIdentityFailure.accountMismatch) {
        // Persistent revocation precedes platform deletion. Business rows stay.
        _revokeRequired = true;
      }
      await _finish();
    } catch (cleanup) {
      _publish(JwSyncPhase.recovery, ready: false, error: _safeError(cleanup));
    }
  }

  Future<void> _finish() => _finishing ??= () async {
    try {
      if (_revokeRequired) {
        await store.revokePermits();
        _revokeRequired = false;
      }
      await _disposeInner(); // Sealed handoff survives this normal drain.
      final receipt = _receipt;
      if (receipt != null) {
        final permits = await store.readCommittedPermits();
        final permit = permits.where(
          (p) => p.partition.sameAs(receipt.permit.partition),
        );
        if (permit.length != 1) throw const AppFailure(FailureCode.staleResult);
        // Reconciliation replays a durable interrupted claim before admission.
        // A failed platform write must remain retryable without another import.
      } else if (_ticket != null) {
        await store.failJob(_ticket!);
      }
      final retained = await _reconcile();
      final data = await store.readView();
      _automatic = false;
      _ticket = null;
      _partition = null;
      _receipt = null;
      _lease?.release();
      _lease = null;
      _publish(
        JwSyncPhase.idle,
        ready: false,
        semesters: const [],
        accountBound: data.accountBound,
        sessionRetained: retained.isNotEmpty,
        data: data,
        automation: JwAutomationState.none,
      );
    } finally {
      _finishing = null;
    }
  }();

  @override
  Future<void> cancel() async {
    if (_view.phase == JwSyncPhase.idle || _view.phase == JwSyncPhase.closed) {
      return;
    }
    _cancelled = true;
    final ticket = _ticket;
    final cancellation = ticket == null
        ? Future<bool>.value(true)
        : store.cancelJob(ticket);
    final drain = _inner?.closeSession();
    _publish(JwSyncPhase.closing, ready: false);
    try {
      await cancellation;
      await drain;
      await _work;
      if (_lease != null) {
        await _finish();
      } else if (_view.phase == JwSyncPhase.closing) {
        _publish(JwSyncPhase.idle, ready: false);
      }
    } catch (error) {
      _publish(JwSyncPhase.recovery, ready: false, error: _safeError(error));
    }
  }

  @override
  Future<void> retryRecovery() async {
    if (_view.phase != JwSyncPhase.recovery || _work != null) {
      throw const AppFailure(FailureCode.busy);
    }
    _publish(JwSyncPhase.closing, clearError: true);
    try {
      await _finish();
    } catch (error) {
      _publish(JwSyncPhase.recovery, error: _safeError(error));
    }
  }

  @override
  Future<void> clearSession() {
    _acquire();
    _publish(
      JwSyncPhase.closing,
      ready: false,
      clearError: true,
      importCommitted: false,
      clearNormalization: true,
      clearProfileReuse: true,
    );
    return _track(() async {
      try {
        _revokeRequired = true;
        await _finish();
      } catch (error) {
        _publish(JwSyncPhase.recovery, error: _safeError(error));
      }
    });
  }

  @override
  Future<void> setHidden({
    required int localId,
    required int expectedVersion,
    required bool hidden,
  }) {
    _acquire();
    return _track(() async {
      try {
        final authority = await store.readAuthority();
        final random = Random.secure();
        final operationId =
            'jw-local-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
        final command = JwHiddenCommand(
          operationId: operationId,
          ownerId: authority.ownerId,
          accountId: 1,
          resetEpoch: authority.resetEpoch,
          localId: localId,
          expectedVersion: expectedVersion,
          hidden: hidden,
        );
        await store.setHidden(command);
        final data = await store.readView();
        _publish(JwSyncPhase.idle, data: data, clearError: true);
      } catch (error) {
        _publish(JwSyncPhase.idle, error: _safeError(error));
      } finally {
        _lease?.release();
        _lease = null;
      }
    });
  }

  /// Local refresh after the total maintenance runner committed and drained.
  /// It does not acquire another source lease or navigate a school page.
  Future<void> refreshAfterMaintenance() async {
    if (_closing ||
        _view.phase != JwSyncPhase.idle ||
        _lease != null ||
        _work != null) {
      throw const AppFailure(FailureCode.busy);
    }
    final data = await store.readView();
    final permits = await store.readCommittedPermits();
    _publish(
      JwSyncPhase.idle,
      data: data,
      accountBound: data.accountBound,
      sessionRetained: permits.isNotEmpty,
      ready: false,
      importCommitted: false,
      courseCount: data.courseCount,
      examCount: data.examCount,
      semesters: const [],
      clearProfileReuse: true,
      clearError: true,
      clearNormalization: true,
      clearLoginReason: true,
    );
  }

  /// No source work was admitted during the persistent maintenance barrier.
  /// Native maintenance helpers are drained by the runner before this call.
  Future<void> shutdownForMaintenanceExit() async {
    if (_view.phase == JwSyncPhase.closed) {
      return;
    }
    if (_work != null ||
        _ticket != null ||
        (_view.phase != JwSyncPhase.idle &&
            _view.phase != JwSyncPhase.recovery)) {
      throw const AppFailure(FailureCode.cleanupPending);
    }
    // Partial startup can retain a recovery-only environment. Prove its drain,
    // then leave disk ledgers for next startup rather than infer deletion.
    await _disposeInner();
    _lease?.release();
    _lease = null;
    await registry.closeForMaintenanceExit();
    _closing = true;
    await _credentialSubscription.cancel();
    _publish(JwSyncPhase.closed);
    await _changes.close();
  }

  Future<void> shutdown() => _shutdown ??= () async {
    _closing = true;
    try {
      if (_view.phase == JwSyncPhase.idle) await _work;
      await cancel();
      if (_lease != null || _view.phase == JwSyncPhase.recovery) {
        throw const AppFailure(FailureCode.cleanupPending);
      }
      await registry.close();
      await _credentialSubscription.cancel();
      _publish(JwSyncPhase.closed);
      await _changes.close();
    } catch (_) {
      _closing = false;
      _shutdown = null;
      rethrow;
    }
  }();
}

/// Formal assets are disposed only by C2 after C3's commit decision. The inner
/// browser coordinator owns native drain, without deleting the login profile.
final class _RetainedAssets implements ObservationAssetsPort {
  const _RetainedAssets([this.path]);
  final String? path;
  @override
  Future<String> register() async =>
      path ?? (throw const AppFailure(FailureCode.invalidSnapshot));
  @override
  Future<void> recoverPending(Future<void> Function(String) drain) async {}
  @override
  Future<void> cleanup() async {}
  @override
  Future<void> close() async {}
}
