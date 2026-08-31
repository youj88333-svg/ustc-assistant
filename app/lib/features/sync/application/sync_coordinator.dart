import 'dart:async';
import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../accounts/application/account_service.dart';
import '../../accounts/application/first_login_commit_service.dart';
import '../../import/application/import_service.dart';
import '../../import/domain/import_result.dart';
import '../data/bridge_client.dart';
import '../domain/sync_state.dart';
import '../native/jw_web_page.dart' show defaultLoginTimeout;

typedef BundleImport =
    Future<ImportResult> Function(
      Uint8List bytes, {
      required String accountId,
      required ImportOrigin origin,
    });

typedef BundlePrepare = Future<PreparedSourceBundle> Function(Uint8List bytes);

typedef FirstLoginConfigPersist =
    Future<void> Function({
      required String accountId,
      required BridgeCapabilities capabilities,
    });

typedef SyncActionResolver = Future<bool> Function(SyncNeedsUserAction action);

enum _PollProtocolErrorBehavior { mapToSyncFailure, rethrowToCaller }

class _PausedSync {
  const _PausedSync({
    required this.source,
    required this.accountId,
    required this.runId,
    required this.jobId,
    required this.sequence,
    required this.bridge,
    required this.pollProtocolErrorBehavior,
    this.capabilities,
    this.provisional,
    this.verifiedUsername,
  });

  final SyncSource source;
  final String accountId;
  final String runId;
  final String jobId;
  final int sequence;
  final BridgeGateway bridge;
  final _PollProtocolErrorBehavior pollProtocolErrorBehavior;
  final BridgeCapabilities? capabilities;
  final Object? provisional;
  final String? verifiedUsername;
}

class _CurrentSyncJob {
  const _CurrentSyncJob({required this.bridge, required this.jobId});

  final BridgeGateway bridge;
  final String jobId;
}

class SyncCoordinator {
  SyncCoordinator({
    required this.database,
    required this.accounts,
    required this.bridgeFactory,
    required this.importBundle,
    this.prepareBundle,
    this.firstLoginCommitService,
    this.firstLoginCommit,
    this.importService,
    this.persistFirstLoginConfig,
    this.invalidateBridge,
    int Function()? now,
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final AppDatabase database;
  final AccountService accounts;
  final Future<BridgeGateway> Function() bridgeFactory;
  final BundleImport importBundle;
  final BundlePrepare? prepareBundle;
  final FirstLoginCommitService? firstLoginCommitService;
  final FirstLoginCommitService? firstLoginCommit;
  final ImportService? importService;
  final FirstLoginConfigPersist? persistFirstLoginConfig;
  final void Function(BridgeGateway bridge)? invalidateBridge;
  final int Function() now;
  static const freshness = Duration(hours: 12);
  static const retryBackoff = Duration(hours: 1);
  static const _uuid = Uuid();
  bool _busy = false;
  final Map<String, _PausedSync> _paused = {};
  _CurrentSyncJob? _currentJob;
  Completer<void>? _currentSettlement;
  bool _cancelRequested = false;
  BridgeGateway? _admissionBridge;
  Completer<void>? _admissionSettlement;
  Future<void>? _cancelFuture;
  bool _admissionCancellationIssued = false;
  String? _cancelIssuedJobId;
  String? _pendingFirstLoginAccountId;

  FirstLoginCommitService? get _atomicFirstLoginCommit =>
      firstLoginCommitService ?? firstLoginCommit;

  BundlePrepare? get _prepareFirstLoginBundle =>
      prepareBundle ?? importService?.prepare;

  /// True when cancellation may be handled by the coordinator's bridge/job
  /// owner. The UI gateway uses this to close a bridge it selected before the
  /// coordinator reached its bridge factory (for example during account
  /// preflight), without shutting down an active job's usable bridge.
  bool get hasCurrentJob => _currentJob != null;

  bool get hasAdmittedBridge => _admissionBridge != null;

  Completer<void> _beginAdmission() {
    _cancelRequested = false;
    _admissionBridge = null;
    _admissionCancellationIssued = false;
    final admission = Completer<void>();
    _admissionSettlement = admission;
    return admission;
  }

  void _completeAdmission([Completer<void>? knownAdmission]) {
    final admission = knownAdmission ?? _admissionSettlement;
    if (admission == null ||
        (_admissionSettlement != null &&
            !identical(_admissionSettlement, admission))) {
      return;
    }
    if (!admission.isCompleted) admission.complete();
    _admissionSettlement = null;
    _admissionBridge = null;
  }

  Future<void> _cancelBridgeAdmission(BridgeGateway bridge) async {
    if (_admissionCancellationIssued) return;
    _admissionCancellationIssued = true;
    if (bridge is BridgeAdmissionCancellation) {
      await (bridge as BridgeAdmissionCancellation).cancelAdmission();
      return;
    }
    // A bridge without the optional admission seam still has an owned
    // process/session. Shutdown is its only safe way to interrupt a
    // capabilities/start request that has not yielded a job id yet.
    try {
      await bridge.shutdown();
    } finally {
      try {
        invalidateBridge?.call(bridge);
      } on Object {
        // Cache invalidation is best effort after the bridge has been closed;
        // teardown must continue to settle the admission.
      }
    }
  }

  Future<void> _cancelBridgeJob(_CurrentSyncJob current) async {
    if (_cancelIssuedJobId == current.jobId) return;
    _cancelIssuedJobId = current.jobId;
    await current.bridge.cancel(current.jobId);
  }

  Future<bool> _cancelIfRequested(BridgeGateway bridge) async {
    if (!_cancelRequested) return false;
    await _cancelBridgeAdmission(bridge);
    return true;
  }

  Future<bool> isAutomaticDue(SyncSource source, String accountId) async {
    final config = await _config(source, accountId);
    if (config != null && !config.enabled) return false;
    final timestamp = now();
    if (config?.retryAfter != null && timestamp < config!.retryAfter!) {
      return false;
    }
    final success = config?.lastSuccessAt;
    return success == null || timestamp - success >= freshness.inMilliseconds;
  }

  Future<SyncOutcome> sync(
    SyncSource source, {
    required SyncTrigger trigger,
    String? accountId,
    BridgeSemesterCapability? semesterOverride,
  }) async {
    if (_busy) return SyncSkipped(source, reason: 'busy');
    _busy = true;
    final admission = _beginAdmission();
    LocalAccount? account;
    String? runId;
    try {
      account = accountId == null
          ? await accounts.activeAccount()
          : await (database.select(
              database.localAccounts,
            )..where((row) => row.id.equals(accountId))).getSingleOrNull();
      if (_cancelRequested) return SyncCancelled(source);
      if (account == null) return SyncSkipped(source, reason: 'no_account');
      if (trigger == SyncTrigger.automatic) {
        final due = await isAutomaticDue(source, account.id);
        if (_cancelRequested) return SyncCancelled(source);
        if (!due) return SyncSkipped(source, reason: 'fresh_or_backoff');
      }
      final hasCredentials = await accounts.hasCredentials(account.id);
      if (_cancelRequested) return SyncCancelled(source);
      if (!hasCredentials) {
        runId = await _startRun(account.id, source, trigger);
        if (_cancelRequested) {
          await _finishRun(runId, 'cancelled', 'cancelled');
          return SyncCancelled(source);
        }
        await recordFailure(
          source,
          account.id,
          code: 'reauthentication_required',
          runId: runId,
        );
        return SyncFailed(source, code: 'reauthentication_required');
      }
      final bridge = await bridgeFactory();
      _admissionBridge = bridge;
      if (await _cancelIfRequested(bridge)) return SyncCancelled(source);
      final capabilities = await bridge.capabilities();
      if (await _cancelIfRequested(bridge)) return SyncCancelled(source);
      await _persistCapabilities(account.id, capabilities);
      if (await _cancelIfRequested(bridge)) return SyncCancelled(source);
      final username = await accounts.usernameForSync(account.id);
      if (await _cancelIfRequested(bridge)) return SyncCancelled(source);
      runId = await _startRun(account.id, source, trigger);
      if (await _cancelIfRequested(bridge)) {
        await _finishRun(runId, 'cancelled', 'cancelled');
        return SyncCancelled(source);
      }
      final job = await bridge.startCollection(
        source: source,
        accountId: account.id,
        expectedUsername: username,
        jwSemester: semesterOverride ?? capabilities.jwSemester,
      );
      final settlement = Completer<void>();
      _currentJob = _CurrentSyncJob(bridge: bridge, jobId: job.id);
      _currentSettlement = settlement;
      _completeAdmission(admission);
      SyncOutcome? outcome;
      try {
        outcome = await _consume(
          bridge: bridge,
          source: source,
          accountId: account.id,
          runId: runId,
          jobId: job.id,
          sequence: 0,
          capabilities: capabilities,
        );
        return outcome;
      } finally {
        if (_paused[job.id] == null && _currentJob?.jobId == job.id) {
          _completeCurrentSettlement(job.id, settlement);
        }
      }
    } on AccountVerificationError catch (error) {
      if (_cancelRequested) {
        if (runId != null) await _finishRun(runId, 'cancelled', 'cancelled');
        return SyncCancelled(source);
      }
      final currentAccount = account;
      if (currentAccount == null) rethrow;
      final code = error.code == 'credentials_not_found'
          ? 'reauthentication_required'
          : error.code;
      await recordFailure(source, currentAccount.id, code: code);
      return SyncFailed(source, code: code);
    } on BridgeProtocolError catch (error) {
      if (_cancelRequested) {
        if (runId != null) await _finishRun(runId, 'cancelled', 'cancelled');
        return SyncCancelled(source);
      }
      final currentAccount = account;
      if (currentAccount == null) rethrow;
      final code = error.code == 'busy' ? 'bridge_busy' : error.code;
      await recordFailure(source, currentAccount.id, code: code);
      return SyncFailed(source, code: code);
    } on Object {
      if (_cancelRequested) {
        if (runId != null) await _finishRun(runId, 'cancelled', 'cancelled');
        return SyncCancelled(source);
      }
      final currentAccount = account;
      if (currentAccount == null) rethrow;
      await recordFailure(source, currentAccount.id, code: 'sync_failed');
      return SyncFailed(source, code: 'sync_failed');
    } finally {
      _completeAdmission(admission);
      _busy = false;
    }
  }

  Future<List<SyncOutcome>> syncAll({
    required SyncTrigger trigger,
    String? accountId,
    SyncActionResolver? resolveUserAction,
  }) async {
    final outcomes = <SyncOutcome>[];
    for (final source in SyncSource.values) {
      var outcome = await sync(source, trigger: trigger, accountId: accountId);
      if (outcome is SyncNeedsUserAction && resolveUserAction != null) {
        final confirmed = await resolveUserAction(outcome);
        outcome = await resumeInteractive(
          outcome.jobId,
          userConfirmed: confirmed,
        );
      }
      outcomes.add(outcome);
    }
    return outcomes;
  }

  Future<SyncOutcome> firstLoginSync(
    SyncSource source, {
    required String username,
    String? password,
    bool savePassword = false,
    BridgeSemesterCapability? semesterOverride,
  }) async {
    if (_busy) return SyncSkipped(source, reason: 'busy');
    _busy = true;
    final admission = _beginAdmission();
    Object? provisional;
    try {
      final existingId = await accounts.accountIdFor(username);
      final atomicCommit = _atomicFirstLoginCommit;
      final prepareBundle = _prepareFirstLoginBundle;
      final provisionalId =
          _pendingFirstLoginAccountId ?? existingId ?? _uuid.v4();
      if (atomicCommit != null && prepareBundle != null) {
        provisional = await accounts.stageFirstLogin(
          username: username,
          password: password,
          savePassword: savePassword,
          provisional: ProvisionalFirstLogin(
            accountId: provisionalId,
            expectedUsername: username.trim(),
            savePassword: savePassword,
          ),
        );
        _pendingFirstLoginAccountId =
            (provisional as ProvisionalFirstLogin).accountId;
      } else {
        provisional = ProvisionalAccount(provisionalId);
        await accounts.stageLogin(
          username: username,
          password: password,
          savePassword: savePassword,
          provisional: provisional as ProvisionalAccount,
        );
      }
      if (_cancelRequested) {
        accounts.cancelFirstLogin(provisional);
        return SyncCancelled(source);
      }
      final bridge = await bridgeFactory();
      _admissionBridge = bridge;
      if (await _cancelIfRequested(bridge)) {
        accounts.cancelFirstLogin(provisional);
        return SyncCancelled(source);
      }
      final capabilities = await bridge.capabilities();
      if (await _cancelIfRequested(bridge)) {
        accounts.cancelFirstLogin(provisional);
        return SyncCancelled(source);
      }
      final runId = 'provisional:${_uuid.v4()}';
      if (await _cancelIfRequested(bridge)) {
        accounts.cancelFirstLogin(provisional);
        return SyncCancelled(source);
      }
      final job = await bridge.startCollection(
        source: source,
        accountId: (provisional as ProvisionalAccount).accountId,
        expectedUsername: accounts.stagedUsernameForSync(provisional),
        jwSemester: semesterOverride ?? capabilities.jwSemester,
      );
      final settlement = Completer<void>();
      _currentJob = _CurrentSyncJob(bridge: bridge, jobId: job.id);
      _currentSettlement = settlement;
      _completeAdmission(admission);
      try {
        final outcome = await _consume(
          bridge: bridge,
          source: source,
          accountId: provisional.accountId,
          runId: runId,
          jobId: job.id,
          sequence: 0,
          capabilities: capabilities,
          pollProtocolErrorBehavior: _PollProtocolErrorBehavior.rethrowToCaller,
          provisional: provisional,
          verifiedUsername: username.trim(),
        );
        if (outcome is SyncSucceeded) _pendingFirstLoginAccountId = null;
        return outcome;
      } finally {
        if (_paused[job.id] == null && _currentJob?.jobId == job.id) {
          _completeCurrentSettlement(job.id, settlement);
        }
      }
    } on Object {
      if (provisional != null) accounts.cancelFirstLogin(provisional);
      if (_cancelRequested) return SyncCancelled(source);
      return SyncFailed(source, code: 'first_login_failed');
    } finally {
      _completeAdmission(admission);
      _busy = false;
    }
  }

  Future<SyncOutcome> reauthenticate(
    SyncSource source, {
    required String accountId,
    required String username,
    String? password,
    bool savePassword = false,
    BridgeSemesterCapability? semesterOverride,
  }) async {
    if (_busy) return SyncSkipped(source, reason: 'busy');
    _busy = true;
    final admission = _beginAdmission();
    ProvisionalAccount? provisional;
    try {
      provisional = await accounts.stageReauthentication(
        accountId: accountId,
        username: username,
        password: password,
        savePassword: savePassword,
      );
      if (_cancelRequested) {
        accounts.cancelFirstLogin(provisional);
        return SyncCancelled(source);
      }
      final bridge = await bridgeFactory();
      _admissionBridge = bridge;
      if (await _cancelIfRequested(bridge)) {
        accounts.cancelFirstLogin(provisional);
        return SyncCancelled(source);
      }
      final capabilities = await bridge.capabilities();
      if (await _cancelIfRequested(bridge)) {
        accounts.cancelFirstLogin(provisional);
        return SyncCancelled(source);
      }
      final runId = 'provisional:${_uuid.v4()}';
      if (await _cancelIfRequested(bridge)) {
        accounts.cancelFirstLogin(provisional);
        return SyncCancelled(source);
      }
      final job = await bridge.startCollection(
        source: source,
        accountId: provisional.accountId,
        expectedUsername: accounts.stagedUsernameForSync(provisional),
        jwSemester: semesterOverride ?? capabilities.jwSemester,
      );
      final settlement = Completer<void>();
      _currentJob = _CurrentSyncJob(bridge: bridge, jobId: job.id);
      _currentSettlement = settlement;
      _completeAdmission(admission);
      try {
        return await _consume(
          bridge: bridge,
          source: source,
          accountId: provisional.accountId,
          runId: runId,
          jobId: job.id,
          sequence: 0,
          provisional: provisional,
          verifiedUsername: username.trim(),
        );
      } finally {
        if (_paused[job.id] == null && _currentJob?.jobId == job.id) {
          _completeCurrentSettlement(job.id, settlement);
        }
      }
    } on AccountVerificationError catch (error) {
      if (provisional != null) accounts.cancelFirstLogin(provisional);
      if (_cancelRequested) return SyncCancelled(source);
      return SyncFailed(source, code: error.code);
    } on BridgeProtocolError catch (error) {
      if (provisional != null) accounts.cancelFirstLogin(provisional);
      if (_cancelRequested) return SyncCancelled(source);
      final code = error.code == 'busy' ? 'bridge_busy' : error.code;
      return SyncFailed(source, code: code);
    } on Object {
      if (provisional != null) accounts.cancelFirstLogin(provisional);
      if (_cancelRequested) return SyncCancelled(source);
      return SyncFailed(source, code: 'reauthentication_failed');
    } finally {
      _completeAdmission(admission);
      _busy = false;
    }
  }

  Future<SyncOutcome> resumeInteractive(
    String jobId, {
    required bool userConfirmed,
  }) async {
    final paused = _paused.remove(jobId);
    if (paused == null) {
      return const SyncFailed(SyncSource.jw, code: 'job_not_found');
    }
    if (!userConfirmed) {
      try {
        await paused.bridge.cancel(jobId);
        if (paused.provisional == null) {
          await _finishRun(paused.runId, 'cancelled', 'cancelled');
        } else {
          accounts.cancelFirstLogin(paused.provisional!);
        }
      } finally {
        _completeCurrentSettlement(jobId);
      }
      return SyncCancelled(paused.source);
    }
    try {
      final password = paused.provisional == null
          ? await accounts.passwordForInteractiveLogin(paused.accountId)
          : accounts.stagedPasswordForInteractiveLogin(paused.provisional!);
      await paused.bridge.resumeLogin(jobId, password: password);
      final outcome = await _consume(
        bridge: paused.bridge,
        source: paused.source,
        accountId: paused.accountId,
        runId: paused.runId,
        jobId: paused.jobId,
        sequence: paused.sequence,
        capabilities: paused.capabilities,
        pollProtocolErrorBehavior: paused.pollProtocolErrorBehavior,
        provisional: paused.provisional,
        verifiedUsername: paused.verifiedUsername,
      );
      if (outcome is! SyncNeedsUserAction && _currentJob?.jobId == jobId) {
        _completeCurrentSettlement(jobId);
      }
      return outcome;
    } on BridgeProtocolError {
      // A resumed first-login flow has no enclosing firstLoginSync call left
      // to provide its stable outer mapping.
      if (paused.pollProtocolErrorBehavior ==
          _PollProtocolErrorBehavior.rethrowToCaller) {
        if (paused.provisional != null) {
          accounts.cancelFirstLogin(paused.provisional!);
        }
        _completeCurrentSettlement(jobId);
        return SyncFailed(paused.source, code: 'first_login_failed');
      }
      _completeCurrentSettlement(jobId);
      rethrow;
    } on Object {
      if (paused.pollProtocolErrorBehavior ==
          _PollProtocolErrorBehavior.rethrowToCaller) {
        if (paused.provisional != null) {
          accounts.cancelFirstLogin(paused.provisional!);
        }
        _completeCurrentSettlement(jobId);
        return SyncFailed(paused.source, code: 'first_login_failed');
      }
      _completeCurrentSettlement(jobId);
      rethrow;
    }
  }

  /// Cancels the one active or paused coordinator job and waits for its
  /// terminal poll/cleanup settlement.  SourceJobGateway uses this method so
  /// UI cancellation never releases its arbiter lease early.
  Future<void> cancelCurrent() {
    final existing = _cancelFuture;
    if (existing != null) return existing;
    final operation = _cancelCurrentImpl();
    _cancelFuture = operation;
    unawaited(
      operation.then<void>(
        (_) {
          if (identical(_cancelFuture, operation)) _cancelFuture = null;
        },
        onError: (Object _, StackTrace _) {
          if (identical(_cancelFuture, operation)) _cancelFuture = null;
        },
      ),
    );
    return operation;
  }

  Future<void> _cancelCurrentImpl() async {
    final admission = _admissionSettlement;
    final admittedJob = _currentJob;
    if (admission == null && admittedJob == null) return;

    // Set this before the first await. Every admission checkpoint and the
    // poll/import boundary then observes the same cancellation generation.
    _cancelRequested = true;
    Object? firstError;
    StackTrace? firstStack;
    Future<void> attempt(Future<void> Function() action) async {
      try {
        await action();
      } on Object catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }

    // If the bridge has not yielded a job yet, cancel its whole admission
    // operation. The late factory/controller/session result is then either
    // explicitly cancelled or shut down by the bridge implementation.
    if (admission != null) {
      final bridge = _admissionBridge;
      if (bridge != null) {
        await attempt(() => _cancelBridgeAdmission(bridge));
      }
      await attempt(() => admission.future.timeout(defaultLoginTimeout));
    }

    // A start operation can return a job just as admission cancellation is
    // settling. Re-read the current job after that handshake and cancel the
    // exact late job before waiting for its terminal poll settlement.
    final current = _currentJob;
    if (current != null) {
      final paused = _paused[current.jobId];
      if (paused != null) {
        await attempt(() async {
          await resumeInteractive(current.jobId, userConfirmed: false);
        });
      } else {
        await attempt(() => _cancelBridgeJob(current));
      }
      final settlement = _currentSettlement;
      if (settlement != null && !settlement.isCompleted) {
        await attempt(() => settlement.future.timeout(defaultLoginTimeout));
      }
      if (_currentJob?.jobId == current.jobId) {
        _completeCurrentSettlement(current.jobId);
      }
    }
    final error = firstError;
    if (error != null) {
      Error.throwWithStackTrace(error, firstStack ?? StackTrace.current);
    }
  }

  void _completeCurrentSettlement(
    String jobId, [
    Completer<void>? knownSettlement,
  ]) {
    if (_currentJob?.jobId != jobId) return;
    final settlement = knownSettlement ?? _currentSettlement;
    if (settlement != null && !settlement.isCompleted) {
      settlement.complete();
    }
    _currentJob = null;
    _currentSettlement = null;
    _cancelIssuedJobId = null;
  }

  Future<SyncOutcome> _consume({
    required BridgeGateway bridge,
    required SyncSource source,
    required String accountId,
    required String runId,
    required String jobId,
    required int sequence,
    BridgeCapabilities? capabilities,
    _PollProtocolErrorBehavior pollProtocolErrorBehavior =
        _PollProtocolErrorBehavior.mapToSyncFailure,
    Object? provisional,
    String? verifiedUsername,
  }) async {
    var cursor = sequence;
    while (true) {
      if (_cancelRequested) {
        await _cancelBridgeJob(_CurrentSyncJob(bridge: bridge, jobId: jobId));
      }
      final BridgeJobPoll poll;
      try {
        poll = await bridge.poll(jobId, cursor);
      } on BridgeProtocolError catch (error) {
        if (pollProtocolErrorBehavior ==
            _PollProtocolErrorBehavior.rethrowToCaller) {
          rethrow;
        }
        if (_cancelRequested) {
          if (provisional != null) {
            accounts.cancelFirstLogin(provisional);
          } else {
            await _finishRun(runId, 'cancelled', 'cancelled');
          }
          return SyncCancelled(source);
        }
        // A concurrent shutdown/cancel can invalidate the job between
        // iterations; that is a failed run, never an unhandled exception.
        if (provisional != null) accounts.cancelFirstLogin(provisional);
        if (provisional == null) {
          await recordFailure(
            source,
            accountId,
            code: error.code,
            runId: runId,
          );
        }
        return SyncFailed(source, code: error.code);
      }
      cursor = poll.nextSequence;
      if (_cancelRequested) {
        // Do not pause or import a generation after its cancellation was
        // requested. A non-terminal poll must continue until the bridge emits
        // its cancellation terminal; an already-terminal stale success has
        // nevertheless settled the resource and is mapped to cancellation.
        await _cancelBridgeJob(_CurrentSyncJob(bridge: bridge, jobId: jobId));
        final terminalCode = poll.errorCode;
        final terminalCancelled =
            poll.lastPhase == 'cancelled' || terminalCode == 'cancelled';
        if (!poll.terminal || !terminalCancelled) {
          if (poll.terminal) {
            if (provisional != null) {
              accounts.cancelFirstLogin(provisional);
            } else {
              await _finishRun(runId, 'cancelled', 'cancelled');
            }
            return SyncCancelled(source);
          }
          continue;
        }
      }
      if (poll.lastPhase == 'needs_user_login') {
        _paused[jobId] = _PausedSync(
          source: source,
          accountId: accountId,
          runId: runId,
          jobId: jobId,
          sequence: cursor,
          bridge: bridge,
          pollProtocolErrorBehavior: pollProtocolErrorBehavior,
          capabilities: capabilities,
          provisional: provisional,
          verifiedUsername: verifiedUsername,
        );
        if (provisional == null) {
          await _setRunState(runId, 'needs_user_action');
        }
        return SyncNeedsUserAction(source, jobId: jobId);
      }
      if (!poll.terminal) continue;
      final code = poll.errorCode ?? 'collection_failed';
      // A cancelled terminal generation wins over any stale result that a
      // gateway may have observed while an in-flight page request settled.
      if (poll.lastPhase == 'cancelled' || code == 'cancelled') {
        if (provisional != null) accounts.cancelFirstLogin(provisional);
        if (provisional == null) {
          await _finishRun(runId, 'cancelled', code);
        }
        return SyncCancelled(source);
      }
      if (poll.result != null) {
        final bytes = Uint8List.fromList(utf8.encode(jsonEncode(poll.result)));
        final atomicCommit = _atomicFirstLoginCommit;
        final prepareBundle = _prepareFirstLoginBundle;
        if (provisional is ProvisionalFirstLogin &&
            atomicCommit != null &&
            prepareBundle != null) {
          // Prepare is deliberately outside the account transaction.  A
          // cancellation observed after preparation still owns no SQLite
          // rows and must not enter the commit boundary.
          if (_cancelRequested) {
            accounts.cancelFirstLogin(provisional);
            return SyncCancelled(source);
          }
          final prepared = await prepareBundle(bytes);
          if (_cancelRequested) {
            accounts.cancelFirstLogin(provisional);
            return SyncCancelled(source);
          }
          final requiredCapabilities =
              capabilities ?? await bridge.capabilities();
          if (_cancelRequested) {
            accounts.cancelFirstLogin(provisional);
            return SyncCancelled(source);
          }
          final persistConfig =
              persistFirstLoginConfig ??
              ({
                required String accountId,
                required BridgeCapabilities capabilities,
              }) => _persistCapabilities(
                accountId,
                capabilities,
                markSuccess: true,
              );
          final committed = await atomicCommit.commit(
            provisional: provisional,
            verifiedUsername: verifiedUsername!,
            prepared: prepared,
            cancellationRequested: () => _cancelRequested,
            persistRequiredConfig: () => persistConfig(
              accountId: provisional.accountId,
              capabilities: requiredCapabilities,
            ),
          );
          return SyncSucceeded(
            source,
            importedEntityCount: committed.importedEntityCount,
          );
        }

        var importAccountId = accountId;
        var persistedRunId = runId;
        if (provisional != null) {
          importAccountId = await accounts.confirmSuccessfulLogin(
            verifiedUsername: verifiedUsername!,
          );
          await _persistCapabilities(
            importAccountId,
            await bridge.capabilities(),
          );
          persistedRunId = await _startRun(
            importAccountId,
            source,
            SyncTrigger.manual,
          );
        }
        final result = await importBundle(
          bytes,
          accountId: importAccountId,
          origin: ImportOrigin.bridge,
        );
        await _recordSuccess(source, importAccountId, persistedRunId);
        return SyncSucceeded(
          source,
          importedEntityCount: result.importedEntityCount,
        );
      }
      if (provisional != null) accounts.cancelFirstLogin(provisional);
      if (provisional == null) {
        await recordFailure(source, accountId, code: code, runId: runId);
      }
      return SyncFailed(source, code: code);
    }
  }

  Future<void> recordFailure(
    SyncSource source,
    String accountId, {
    String code = 'collection_failed',
    String? runId,
  }) async {
    final timestamp = now();
    await database.transaction(() async {
      await _ensureConfig(source, accountId, timestamp: timestamp);
      await (database.update(database.sourceConfigs)..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.source.equals(source.storage),
          ))
          .write(
            SourceConfigsCompanion(
              retryAfter: Value(timestamp + retryBackoff.inMilliseconds),
              updatedAt: Value(timestamp),
            ),
          );
      if (runId != null) await _finishRun(runId, 'failed', code);
      await _log(accountId, source, 'failed', code, timestamp);
    });
  }

  Future<void> recoverInterruptedRuns() async {
    final timestamp = now();
    await (database.update(
      database.syncRuns,
    )..where((row) => row.state.equals('running'))).write(
      SyncRunsCompanion(
        state: const Value('interrupted'),
        resultCode: const Value('app_restarted'),
        finishedAt: Value(timestamp),
      ),
    );
  }

  Future<SyncSourceState> stateFor(SyncSource source, String accountId) async {
    final runs =
        await (database.select(database.syncRuns)
              ..where(
                (row) =>
                    row.accountId.equals(accountId) &
                    row.source.equals(source.storage),
              )
              ..orderBy([(row) => OrderingTerm.desc(row.startedAt)]))
            .get();
    final config = await _config(source, accountId);
    final latest = runs.firstOrNull;
    final phase = switch (latest?.state) {
      'running' => SyncPhase.running,
      'needs_user_action' => SyncPhase.needsUserAction,
      'success' => SyncPhase.succeeded,
      'failed' || 'interrupted' => SyncPhase.failed,
      'cancelled' => SyncPhase.cancelled,
      _ =>
        await isAutomaticDue(source, accountId)
            ? SyncPhase.due
            : SyncPhase.idle,
    };
    return SyncSourceState(
      source: source,
      phase: phase,
      lastAttemptAt: latest == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(latest.startedAt),
      lastSuccessfulAt: config?.lastSuccessAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(config!.lastSuccessAt!),
      resultCode: latest?.resultCode,
    );
  }

  Future<String> _startRun(
    String accountId,
    SyncSource source,
    SyncTrigger trigger,
  ) async {
    final id = _uuid.v4();
    await database
        .into(database.syncRuns)
        .insert(
          SyncRunsCompanion.insert(
            id: id,
            accountId: accountId,
            source: source.storage,
            trigger: trigger.name,
            state: 'running',
            startedAt: now(),
          ),
        );
    return id;
  }

  Future<void> _setRunState(String id, String state) =>
      (database.update(database.syncRuns)..where((row) => row.id.equals(id)))
          .write(SyncRunsCompanion(state: Value(state)));

  Future<void> _finishRun(String id, String state, String code) =>
      (database.update(
        database.syncRuns,
      )..where((row) => row.id.equals(id))).write(
        SyncRunsCompanion(
          state: Value(state),
          resultCode: Value(code),
          finishedAt: Value(now()),
        ),
      );

  Future<void> _recordSuccess(
    SyncSource source,
    String accountId,
    String runId,
  ) async {
    final timestamp = now();
    await database.transaction(() async {
      await _ensureConfig(source, accountId, timestamp: timestamp);
      await (database.update(database.sourceConfigs)..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.source.equals(source.storage),
          ))
          .write(
            SourceConfigsCompanion(
              lastSuccessAt: Value(timestamp),
              retryAfter: const Value(null),
              updatedAt: Value(timestamp),
            ),
          );
      await _finishRun(runId, 'success', 'complete');
      await _log(accountId, source, 'success', 'complete', timestamp);
    });
  }

  Future<void> _persistCapabilities(
    String accountId,
    BridgeCapabilities capabilities, {
    bool markSuccess = false,
  }) async {
    final timestamp = now();
    await _ensureConfig(
      SyncSource.jw,
      accountId,
      timestamp: timestamp,
      config: capabilities.jwSemester.toJson(),
    );
    if (markSuccess) {
      await (database.update(database.sourceConfigs)..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.source.equals(SyncSource.jw.storage),
          ))
          .write(
            SourceConfigsCompanion(
              lastSuccessAt: Value(timestamp),
              retryAfter: const Value(null),
              updatedAt: Value(timestamp),
            ),
          );
    }
  }

  Future<void> _ensureConfig(
    SyncSource source,
    String accountId, {
    required int timestamp,
    Map<String, Object?>? config,
  }) async {
    final existing = await _config(source, accountId);
    if (existing != null && config == null) return;
    await database
        .into(database.sourceConfigs)
        .insertOnConflictUpdate(
          SourceConfigsCompanion.insert(
            id: existing?.id ?? '$accountId:${source.storage}',
            accountId: accountId,
            source: source.storage,
            enabled: Value(existing?.enabled ?? true),
            configJson: Value(
              config == null
                  ? existing?.configJson ?? '{}'
                  : jsonEncode(config),
            ),
            lastSuccessAt: Value(existing?.lastSuccessAt),
            retryAfter: Value(existing?.retryAfter),
            updatedAt: timestamp,
          ),
        );
  }

  Future<SourceConfig?> _config(SyncSource source, String accountId) =>
      (database.select(database.sourceConfigs)..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.source.equals(source.storage),
          ))
          .getSingleOrNull();

  Future<void> _log(
    String accountId,
    SyncSource source,
    String result,
    String code,
    int timestamp,
  ) => database.actionLogsRepository.append(
    accountId: accountId,
    source: source.storage,
    actionType: 'source_sync',
    result: result,
    safeSummary: 'Source synchronization finished with code $code.',
    occurredAt: timestamp,
  );
}
