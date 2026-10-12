import 'dart:async';
import 'dart:math';

import '../core/contracts.dart';
import '../core/jw_credentials.dart';
import '../core/observation_assets.dart';
import '../core/work_lease.dart';
import '../core/young_work_contract.dart';
import '../data/jw_store.dart';
import '../data/young_import_contract.dart';
import '../platform/young_partition_registry.dart';
import '../source/observation_contract.dart';
import '../source/jw_authentication_contract.dart';
import '../source/young_active_contract.dart';
import '../source/young_collection_contract.dart';
import 'observation_coordinator.dart';
import 'observation_port.dart';
import 'young_sync_port.dart';
import 'school_authentication_driver.dart';

/// One C2 lease covers fixed reads, true native drain, C3 commit and claim.
final class YoungSyncCoordinator implements YoungSyncPort {
  YoungSyncCoordinator({
    required this.store,
    required this.registry,
    required this.browser,
    required this.leases,
    this.clock = const SystemClock(),
    this.navigationTimeout = const Duration(seconds: 30),
    this.pollInterval = const Duration(milliseconds: 100),
    this.drainTimeout = const Duration(seconds: 12),
    this.loginWaitTimeout = const Duration(seconds: 90),
    this.businessStability = const Duration(milliseconds: 500),
    this.automaticAuthentication = true,
    ObservationTarget? target,
  }) : target = target ?? ObservationTarget.young() {
    _credentialSubscription = store.credentialChanges.listen((_) {
      unawaited(_refreshSharedCredential().catchError((Object _) {}));
    });
  }

  final JwStore store;
  final YoungPartitionRegistry registry;
  final ObservationBrowserPort browser;
  final WorkLeasePool leases;
  final AppClock clock;
  final ObservationTarget target;
  final Duration navigationTimeout;
  final Duration pollInterval;
  final Duration drainTimeout;
  final Duration loginWaitTimeout;
  final Duration businessStability;
  final bool automaticAuthentication;
  SchoolAuthenticationDriver _authentication = SchoolAuthenticationDriver();
  final _changes = StreamController<YoungSyncView>.broadcast();
  late final StreamSubscription<bool> _credentialSubscription;
  YoungSyncView _view = YoungSyncView();
  WorkLease? _lease;
  ObservationCoordinator? _inner;
  StreamSubscription<ObservationView>? _innerSubscription;
  YoungJobTicket? _ticket;
  YoungPartitionRef? _partition;
  YoungCompletionReceipt? _receipt;
  YoungCollectedArtifact? _pendingArtifact;
  Future<void>? _work, _finishing, _shutdown;
  bool _cancelled = false, _closing = false, _revokeRequired = false;
  bool _initialized = false;

  @override
  YoungSyncView get syncView => _view;
  @override
  Stream<YoungSyncView> get syncChanges => _changes.stream;

  Future<void> _refreshSharedCredential() async {
    if (_closing || _view.phase != YoungSyncPhase.idle) return;
    final data = await store.readYoungView();
    if (!_closing && _view.phase == YoungSyncPhase.idle) {
      _publish(YoungSyncPhase.idle, data: data);
    }
  }

  void _publish(
    YoungSyncPhase phase, {
    YoungJobKind? kind,
    bool? ready,
    bool? accountBound,
    bool? profileRetained,
    bool? profileReused,
    bool clearProfileReuse = false,
    bool? committed,
    Object? error,
    bool clearError = false,
    YoungCollectionStats? normalization,
    bool clearNormalization = false,
    YoungDataView? data,
    List<YoungActivityView>? activities,
    YoungAutomationState? automation,
    JwLoginPauseReason? loginPauseReason,
    bool clearLoginReason = false,
    YoungSyncPhase? failureStage,
    YoungBusinessStage? collectionStage,
    YoungBusinessRejection? collectionReason,
  }) {
    _view = YoungSyncView(
      phase: phase,
      kind: kind ?? _view.kind,
      ready: ready ?? _view.ready,
      accountBound: accountBound ?? _view.accountBound,
      profileRetained: profileRetained ?? _view.profileRetained,
      profileReused:
          profileReused ?? (clearProfileReuse ? null : _view.profileReused),
      committed: committed ?? _view.committed,
      failure: error is AppFailure
          ? error.code
          : clearError
          ? null
          : _view.failure,
      identityFailure: error is YoungIdentityException
          ? error.code
          : clearError
          ? null
          : _view.identityFailure,
      credentialFailure: error is JwCredentialException
          ? error.code
          : clearError
          ? null
          : _view.credentialFailure,
      automation: automation ?? _view.automation,
      loginPauseReason:
          loginPauseReason ??
          (clearLoginReason ? null : _view.loginPauseReason),
      failureStage: failureStage ?? (clearError ? null : _view.failureStage),
      collectionStage:
          collectionStage ?? (clearError ? null : _view.collectionStage),
      collectionReason:
          collectionReason ?? (clearError ? null : _view.collectionReason),
      normalization:
          normalization ?? (clearNormalization ? null : _view.normalization),
      data: data ?? _view.data,
      activityResults: activities ?? _view.activityResults,
    );
    _changes.add(_view);
  }

  Object _safeError(Object error) =>
      error is AppFailure ||
          error is YoungIdentityException ||
          error is JwCredentialException
      ? error
      : error is YoungBusinessException
      ? AppFailure(error.code)
      : const AppFailure(FailureCode.storageFailed);

  Future<void> _track(Future<void> Function() body) {
    final done = Completer<void>();
    _work = done.future;
    return () async {
      try {
        await body();
      } finally {
        if (identical(_work, done.future)) {
          _work = null;
        }
        done.complete();
        if (_lease != null &&
            _view.phase == YoungSyncPhase.login &&
            (_inner?.view.phase == ObservationPhase.idle ||
                _inner?.view.phase == ObservationPhase.recovery)) {
          unawaited(cancel().catchError((Object _) {}));
        }
      }
    }();
  }

  void _acquire() {
    if (_closing || _view.phase == YoungSyncPhase.closed) {
      throw const AppFailure(FailureCode.closed);
    }
    if (_lease != null || _view.phase != YoungSyncPhase.idle) {
      throw const AppFailure(FailureCode.busy);
    }
    _lease = leases.acquire();
  }

  Future<void> initialize() async {
    // An earlier source can retain the global lease for recovery. Read-only
    // display remains usable; no Young admission occurs before reconciliation.
    if (leases.isBusy) {
      final data = await store.readYoungView();
      _publish(
        YoungSyncPhase.idle,
        data: data,
        accountBound: data.accountBound,
      );
      return;
    }
    _acquire();
    _publish(YoungSyncPhase.opening);
    await _track(() async {
      try {
        await _finish();
      } catch (error) {
        _publish(
          YoungSyncPhase.recovery,
          error: _safeError(error),
          ready: false,
        );
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
        pollInterval: pollInterval,
        drainTimeout: drainTimeout,
      );

  Future<void> _disposeInner() async {
    final inner = _inner;
    if (inner == null) {
      return;
    }
    await inner.shutdown();
    await _innerSubscription?.cancel();
    _innerSubscription = null;
    _inner = null;
  }

  Future<void> _drain(String path) async {
    await _disposeInner();
    _inner = _newInner(const _RetainedYoungAssets());
    await _inner!.drainRegisteredProfile(path);
    await _disposeInner();
  }

  Future<List<YoungPartitionRef>> _reconcile() async {
    final authority = await store.readYoungAuthority();
    final retained = await registry.reconcile(
      await store.readYoungPermits(),
      ownerId: authority.ownerId,
      resetEpoch: authority.resetEpoch,
      drain: _drain,
    );
    _initialized = true;
    return retained;
  }

  @override
  Future<void> startCalendar({
    String? expectedAccountCode,
    required DateTime firstDay,
    required DateTime lastDay,
    String? password,
    bool savePassword = false,
  }) => _open(
    YoungJobKind.calendar,
    expectedAccountCode: expectedAccountCode,
    firstDay: firstDay,
    lastDay: lastDay,
    password: password,
    savePassword: savePassword,
  );

  @override
  Future<void> startActivities({
    String? expectedAccountCode,
    String? password,
    bool savePassword = false,
  }) => _open(
    YoungJobKind.activities,
    expectedAccountCode: expectedAccountCode,
    password: password,
    savePassword: savePassword,
  );

  Future<void> _open(
    YoungJobKind kind, {
    String? expectedAccountCode,
    DateTime? firstDay,
    DateTime? lastDay,
    String? password,
    bool savePassword = false,
  }) {
    _acquire();
    _cancelled = false;
    _authentication = SchoolAuthenticationDriver();
    _publish(
      YoungSyncPhase.opening,
      kind: kind,
      ready: false,
      clearError: true,
      committed: false,
      clearNormalization: true,
      clearProfileReuse: true,
      activities: const [],
      automation: YoungAutomationState.waitingForLogin,
      clearLoginReason: true,
    );
    return _track(() async {
      try {
        _ticket = await store.beginYoungJob(
          kind: kind,
          expectedAccountCode: expectedAccountCode,
          firstDay: firstDay,
          lastDay: lastDay,
        );
        expectedAccountCode = null;
        if (password != null && password!.isNotEmpty) {
          await store.stageYoungCredentials(
            _ticket!,
            password!,
            save: savePassword,
          );
        }
        password = null;
        if (_cancelled) {
          throw const AppFailure(FailureCode.cancelled);
        }
        final retained = await _reconcile();
        if (_cancelled) {
          throw const AppFailure(FailureCode.cancelled);
        }
        final authority = await store.readYoungAuthority();
        final permits = (await store.readYoungPermits())
            .where((p) => retained.any((r) => r.sameAs(p.partition)))
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
                ? YoungPartitionPurpose.recovery
                : YoungPartitionPurpose.initial,
            attempt: _ticket!.stamp.jobId,
            resetEpoch: authority.resetEpoch,
          );
          path = registry.profilePath(_partition!);
        }
        await store.stageYoungPartition(_ticket!, _partition!);
        if (_cancelled) {
          throw const AppFailure(FailureCode.cancelled);
        }
        _inner = _newInner(_RetainedYoungAssets(path));
        _innerSubscription = _inner!.changes.listen(_onInner);
        await _inner!.open();
        if (_cancelled) {
          throw const AppFailure(FailureCode.cancelled);
        }
        _publish(
          YoungSyncPhase.login,
          ready: _inner!.view.ready,
          accountBound: authority.accountBound,
          profileReused: permits.isNotEmpty,
          data: await store.readYoungView(),
        );
        if (automaticAuthentication &&
            browser is YoungAuthenticationBrowserPort) {
          await _runAutomatic();
        } else {
          _pauseAutomatic(JwLoginPauseReason.manualRequired);
        }
      } catch (error) {
        await _fail(error);
      } finally {
        password = null;
      }
    });
  }

  void _onInner(ObservationView observation) {
    if (_view.phase != YoungSyncPhase.login) {
      return;
    }
    _publish(YoungSyncPhase.login, ready: observation.ready);
    if ((observation.phase == ObservationPhase.idle ||
            observation.phase == ObservationPhase.recovery) &&
        _work == null &&
        _finishing == null) {
      unawaited(cancel().catchError((Object _) {}));
    }
  }

  void _requireCurrent() {
    if (_cancelled ||
        _ticket == null ||
        _inner?.view.phase != ObservationPhase.open ||
        _lease?.isHeld != true) {
      throw const AppFailure(FailureCode.cancelled);
    }
  }

  @override
  Future<void> continueAfterLogin() {
    if (_view.phase != YoungSyncPhase.login ||
        _work != null ||
        _inner == null ||
        _ticket == null) {
      throw const AppFailure(FailureCode.busy);
    }
    return _track(() async {
      try {
        if (automaticAuthentication &&
            browser is YoungAuthenticationBrowserPort) {
          await _runAutomatic();
        } else if (await _prepareBusinessPage()) {
          await _collectAndComplete();
        } else {
          _pauseAutomatic(JwLoginPauseReason.manualRequired);
        }
      } catch (error) {
        await _fail(error);
      }
    });
  }

  void _pauseAutomatic(JwLoginPauseReason reason) => _publish(
    YoungSyncPhase.login,
    ready: _inner?.view.ready ?? false,
    automation: YoungAutomationState.manualRequired,
    loginPauseReason: reason,
  );

  Future<void> _runAutomatic() async {
    _publish(YoungSyncPhase.login, clearError: true, clearLoginReason: true);
    final elapsed = Stopwatch()..start();
    while (elapsed.elapsed < loginWaitTimeout) {
      final reason = await _authentication.authenticate(
        requireCurrent: _requireCurrent,
        advance: _inner!.advanceLogin,
        submit: _inner!.submitLogin,
        lease: () => store.leaseYoungCredentials(_ticket!),
        progress: (progress) => _publish(
          YoungSyncPhase.login,
          automation: progress == SchoolAuthenticationProgress.submitting
              ? YoungAutomationState.submitting
              : YoungAutomationState.waitingForLogin,
        ),
        timeout: loginWaitTimeout - elapsed.elapsed,
        pollInterval: pollInterval,
      );
      if (reason != null) {
        _pauseAutomatic(reason);
        return;
      }
      if (await _prepareBusinessPage()) {
        await _collectAndComplete();
        return;
      }
      _publish(YoungSyncPhase.login);
      await Future<void>.delayed(pollInterval);
    }
    _pauseAutomatic(JwLoginPauseReason.timedOut);
  }

  Future<bool> _prepareBusinessPage() async {
    _requireCurrent();
    _publish(
      YoungSyncPhase.login,
      ready: false,
      automation: YoungAutomationState.preparing,
      clearLoginReason: true,
    );
    final page = _ticket!.stamp.kind == YoungJobKind.calendar
        ? YoungBusinessPage.calendar
        : YoungBusinessPage.activities;
    final elapsed = Stopwatch()..start();
    int? before;
    int? stableDocument;
    Stopwatch? stable;
    var helperSeen = false;
    while (elapsed.elapsed < navigationTimeout) {
      _requireCurrent();
      final inner = _inner!;
      if (before == null) {
        // Native login completion may precede the ready event consumed here.
        // Only an explicit busy means this fixed navigation was not issued.
        if (inner.view.origin != null &&
            inner.view.origin != target.initialUri.origin) {
          return false;
        }
        if (inner.view.ready && inner.view.origin == target.initialUri.origin) {
          final candidateDocument = inner.documentGeneration;
          try {
            await inner.navigateYoungPage(page);
            _requireCurrent();
            before = candidateDocument;
          } on AppFailure catch (error) {
            if (error.code != FailureCode.busy) rethrow;
          }
        }
        if (before == null) {
          await Future<void>.delayed(pollInterval);
          continue;
        }
      }
      final document = inner.documentGeneration;
      if (document > before &&
          inner.view.origin != null &&
          inner.view.origin != target.initialUri.origin) {
        return false;
      }
      if (document > before && inner.view.ready) {
        bool prepared;
        try {
          prepared = await inner.prepareYoungPage(page);
        } on AppFailure catch (error) {
          if (error.code != FailureCode.busy &&
              error.code != FailureCode.staleResult) {
            rethrow;
          }
          prepared = false;
        } on YoungBusinessException catch (error) {
          if (error.code != FailureCode.staleResult) rethrow;
          prepared = false;
        }
        _requireCurrent();
        if (prepared &&
            inner.documentGeneration == document &&
            inner.view.ready) {
          helperSeen = true;
          if (stableDocument != document) {
            stableDocument = document;
            stable = Stopwatch()..start();
          }
          // A scheduling delay reduces route races; exact native route/helper
          // checks and the subsequent reader's document guards remain authority.
          if (stable!.elapsed >= businessStability) return true;
        } else {
          stableDocument = null;
          stable = null;
          // The synthetic CAS shares the loopback origin. Production routes
          // can also return to authentication before the app helper exists.
          if (automaticAuthentication &&
              browser is YoungAuthenticationBrowserPort &&
              inner.view.ready) {
            try {
              final login = await inner.advanceLogin();
              if (login == JwLoginState.formReady || login.needsUser) {
                return false;
              }
            } on AppFailure catch (error) {
              if (error.code != FailureCode.busy &&
                  error.code != FailureCode.staleResult) {
                rethrow;
              }
            }
          }
        }
      } else {
        stableDocument = null;
        stable = null;
      }
      await Future<void>.delayed(pollInterval);
    }
    throw YoungBusinessException(
      FailureCode.sourceFailed,
      before == null || helperSeen
          ? YoungBusinessRejection.preparationTimedOut
          : YoungBusinessRejection.helperUnavailable,
    );
  }

  Future<void> _collectAndComplete() async {
    _requireCurrent();
    _publish(
      YoungSyncPhase.collecting,
      ready: false,
      automation: YoungAutomationState.none,
      clearError: true,
      clearLoginReason: true,
    );
    final ticket = _ticket!;
    final artifact = await _inner!.collectYoungSealed(
      stamp: ticket.stamp,
      partition: _partition!,
      expectedAccountCode: ticket.expectedAccountCode,
      clock: clock,
      firstDay: ticket.firstDay,
      lastDay: ticket.lastDay,
    );
    _publish(
      YoungSyncPhase.closing,
      ready: false,
      normalization: artifact.stats,
    );
    await _inner!.closeSession();
    if (_cancelled) throw const AppFailure(FailureCode.cancelled);
    _publish(YoungSyncPhase.committing);
    _receipt = ticket.stamp.kind == YoungJobKind.calendar
        ? await store.importYoungCalendar(ticket, artifact)
        : await store.completeYoungQuery(ticket, artifact);
    _pendingArtifact = artifact;
    _publish(YoungSyncPhase.closing, committed: true);
    await _finish();
  }

  Future<void> _fail(Object error) async {
    // A failed query is not delivered later by a claim-only recovery retry.
    // Its committed receipt and permit remain available for reconciliation.
    _pendingArtifact = null;
    final safe = _safeError(error);
    final failedAt = _view.phase;
    final business = _inner?.businessView;
    _publish(
      YoungSyncPhase.closing,
      ready: false,
      error: safe,
      activities: const [],
      automation: YoungAutomationState.none,
      failureStage: failedAt,
      collectionStage: business?.phase == YoungBusinessPhase.failed
          ? business?.stage
          : null,
      collectionReason: error is YoungBusinessException
          ? error.reason
          : business?.rejection,
    );
    if (safe is YoungIdentityException &&
        safe.code == YoungIdentityFailure.accountMismatch) {
      _revokeRequired = true;
    }
    try {
      await _finish();
    } catch (cleanup) {
      _publish(
        YoungSyncPhase.recovery,
        ready: false,
        error: _safeError(cleanup),
      );
    }
  }

  Future<void> _finish() => _finishing ??= () async {
    try {
      if (_revokeRequired) {
        await store.revokeYoungPermits();
        _revokeRequired = false;
      }
      await _disposeInner();
      final receipt = _receipt;
      if (receipt != null) {
        final permits = await store.readYoungPermits();
        if (permits
                .where((p) => p.partition.sameAs(receipt.permit.partition))
                .length !=
            1) {
          throw const AppFailure(FailureCode.staleResult);
        }
      } else if (_ticket != null) {
        await store.failYoungJob(_ticket!);
      }
      final retained = await _reconcile();
      final data = await store.readYoungView();
      var activities = _view.activityResults;
      final pending = _pendingArtifact;
      if (receipt?.kind == YoungJobKind.activities &&
          pending != null &&
          !_cancelled) {
        await store.validateYoungDelivery(_ticket!, pending);
        // Cancellation may arrive while C3's delivery check is queued.
        if (!_cancelled) {
          activities = pending.activities
              .map(
                (a) => YoungActivityView(
                  title: a.itemName,
                  place: a.placeInfo,
                  startsAtUtc: a.startsAtUtc,
                  endsAtUtc: a.endsAtUtc,
                  registrationStartsAtUtc: a.registrationStartsAtUtc,
                  registrationEndsAtUtc: a.registrationEndsAtUtc,
                ),
              )
              .toList();
        }
      }
      if (_cancelled) {
        activities = const [];
      }
      _ticket = null;
      _partition = null;
      _receipt = null;
      _pendingArtifact = null;
      _lease?.release();
      _lease = null;
      _publish(
        YoungSyncPhase.idle,
        ready: false,
        accountBound: data.accountBound,
        profileRetained: retained.isNotEmpty,
        data: data,
        activities: activities,
        automation: YoungAutomationState.none,
      );
    } finally {
      _finishing = null;
    }
  }();

  @override
  Future<void> cancel() async {
    if (_view.phase == YoungSyncPhase.idle ||
        _view.phase == YoungSyncPhase.closed) {
      return;
    }
    _cancelled = true;
    final ticket = _ticket;
    final cancellation = ticket == null
        ? Future<bool>.value(true)
        : store.cancelYoungJob(ticket);
    final drain = _inner?.closeSession();
    _publish(YoungSyncPhase.closing, ready: false, activities: const []);
    try {
      await cancellation;
      await drain;
      await _work;
      if (_lease != null) {
        await _finish();
      } else if (_view.phase == YoungSyncPhase.closing) {
        _publish(YoungSyncPhase.idle, ready: false);
      }
    } catch (error) {
      _publish(YoungSyncPhase.recovery, ready: false, error: _safeError(error));
    }
  }

  @override
  Future<void> retryRecovery() async {
    if (_view.phase != YoungSyncPhase.recovery || _work != null) {
      throw const AppFailure(FailureCode.busy);
    }
    _publish(YoungSyncPhase.closing, clearError: true);
    try {
      await _finish();
    } catch (error) {
      _publish(YoungSyncPhase.recovery, ready: false, error: _safeError(error));
    }
  }

  @override
  Future<void> clearSession() {
    _acquire();
    _cancelled = false;
    _publish(
      YoungSyncPhase.closing,
      ready: false,
      clearError: true,
      committed: false,
      clearNormalization: true,
      clearProfileReuse: true,
      activities: const [],
    );
    return _track(() async {
      _revokeRequired = true;
      try {
        await _finish();
      } catch (error) {
        _publish(
          YoungSyncPhase.recovery,
          ready: false,
          error: _safeError(error),
        );
      }
    });
  }

  @override
  Future<void> deleteSavedCredential() {
    _acquire();
    return _track(() async {
      try {
        await store.deleteSavedCredential();
        _publish(
          YoungSyncPhase.idle,
          data: await store.readYoungView(),
          clearError: true,
        );
      } catch (error) {
        _publish(YoungSyncPhase.idle, error: _safeError(error));
      } finally {
        _lease?.release();
        _lease = null;
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
        final authority = await store.readYoungAuthority();
        final random = Random.secure();
        final hex = List.generate(
          16,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
        await store.setYoungHidden(
          YoungHiddenCommand(
            operationId: 'young-local-$hex',
            ownerId: authority.ownerId,
            accountId: 1,
            resetEpoch: authority.resetEpoch,
            localId: localId,
            expectedVersion: expectedVersion,
            hidden: hidden,
          ),
        );
        final data = await store.readYoungView();
        _publish(YoungSyncPhase.idle, data: data, clearError: true);
      } catch (error) {
        _publish(YoungSyncPhase.idle, error: _safeError(error));
      } finally {
        _lease?.release();
        _lease = null;
      }
    });
  }

  Future<void> shutdown() => _shutdown ??= () async {
    try {
      _closing = true;
      if (_view.phase == YoungSyncPhase.idle) {
        await _work;
      }
      await cancel();
      // An in-flight local write can own the lease while startup reconciliation
      // is deferred. Recheck only after that write and any source work drain.
      if (!_initialized && _lease == null) {
        if (leases.isBusy) {
          throw const AppFailure(FailureCode.cleanupPending);
        }
        _lease = leases.acquire();
        _publish(YoungSyncPhase.closing);
        try {
          await _finish();
        } catch (error) {
          _publish(
            YoungSyncPhase.recovery,
            ready: false,
            error: _safeError(error),
          );
          rethrow;
        }
      }
      if (_lease != null || _view.phase == YoungSyncPhase.recovery) {
        throw const AppFailure(FailureCode.cleanupPending);
      }
      _pendingArtifact = null;
      await registry.close();
      await _credentialSubscription.cancel();
      _publish(YoungSyncPhase.closed, activities: const []);
      await _changes.close();
    } catch (_) {
      _closing = false;
      _shutdown = null;
      rethrow;
    }
  }();
}

/// Only the C2 registry deletes formal login profiles after C3 adjudication.
final class _RetainedYoungAssets implements ObservationAssetsPort {
  const _RetainedYoungAssets([this.path]);
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
