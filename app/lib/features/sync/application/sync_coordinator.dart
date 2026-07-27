import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../accounts/application/account_service.dart';
import '../../import/domain/import_result.dart';
import '../data/bridge_client.dart';
import '../domain/sync_state.dart';

typedef BundleImport =
    Future<ImportResult> Function(
      Uint8List bytes, {
      required String accountId,
      required ImportOrigin origin,
    });

typedef SyncActionResolver = Future<bool> Function(SyncNeedsUserAction action);

class _PausedSync {
  const _PausedSync({
    required this.source,
    required this.accountId,
    required this.runId,
    required this.jobId,
    required this.sequence,
    required this.bridge,
    this.provisional,
    this.verifiedUsername,
  });

  final SyncSource source;
  final String accountId;
  final String runId;
  final String jobId;
  final int sequence;
  final BridgeGateway bridge;
  final ProvisionalAccount? provisional;
  final String? verifiedUsername;
}

class SyncCoordinator {
  SyncCoordinator({
    required this.database,
    required this.accounts,
    required this.bridgeFactory,
    required this.importBundle,
    int Function()? now,
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final AppDatabase database;
  final AccountService accounts;
  final Future<BridgeGateway> Function() bridgeFactory;
  final BundleImport importBundle;
  final int Function() now;
  static const freshness = Duration(hours: 12);
  static const retryBackoff = Duration(hours: 1);
  static const _uuid = Uuid();
  bool _busy = false;
  final Map<String, _PausedSync> _paused = {};

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
    final account = accountId == null
        ? await accounts.activeAccount()
        : await (database.select(
            database.localAccounts,
          )..where((row) => row.id.equals(accountId))).getSingleOrNull();
    if (account == null) return SyncSkipped(source, reason: 'no_account');
    if (trigger == SyncTrigger.automatic &&
        !await isAutomaticDue(source, account.id)) {
      return SyncSkipped(source, reason: 'fresh_or_backoff');
    }
    if (!await accounts.hasCredentials(account.id)) {
      await recordFailure(
        source,
        account.id,
        code: 'reauthentication_required',
      );
      return SyncFailed(source, code: 'reauthentication_required');
    }
    _busy = true;
    try {
      final bridge = await bridgeFactory();
      final capabilities = await bridge.capabilities();
      await _persistCapabilities(account.id, capabilities);
      final username = await accounts.usernameForSync(account.id);
      final runId = await _startRun(account.id, source, trigger);
      final job = await bridge.startCollection(
        source: source,
        accountId: account.id,
        expectedUsername: username,
        jwSemester: semesterOverride ?? capabilities.jwSemester,
      );
      return await _consume(
        bridge: bridge,
        source: source,
        accountId: account.id,
        runId: runId,
        jobId: job.id,
        sequence: 0,
      );
    } on AccountVerificationError catch (error) {
      final code = error.code == 'credentials_not_found'
          ? 'reauthentication_required'
          : error.code;
      await recordFailure(source, account.id, code: code);
      return SyncFailed(source, code: code);
    } on BridgeProtocolError catch (error) {
      final code = error.code == 'busy' ? 'bridge_busy' : error.code;
      await recordFailure(source, account.id, code: code);
      return SyncFailed(source, code: code);
    } on Object {
      await recordFailure(source, account.id, code: 'sync_failed');
      return SyncFailed(source, code: 'sync_failed');
    } finally {
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
    ProvisionalAccount? provisional;
    try {
      final existingId = await accounts.accountIdFor(username);
      provisional = ProvisionalAccount(existingId ?? _uuid.v4());
      await accounts.stageLogin(
        username: username,
        password: password,
        savePassword: savePassword,
        provisional: provisional,
      );
      final bridge = await bridgeFactory();
      final capabilities = await bridge.capabilities();
      final runId = 'provisional:${_uuid.v4()}';
      final job = await bridge.startCollection(
        source: source,
        accountId: provisional.accountId,
        expectedUsername: accounts.stagedUsernameForSync(provisional),
        jwSemester: semesterOverride ?? capabilities.jwSemester,
      );
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
    } on Object {
      if (provisional != null) accounts.cancelFirstLogin(provisional);
      return SyncFailed(source, code: 'first_login_failed');
    } finally {
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
    ProvisionalAccount? provisional;
    try {
      provisional = await accounts.stageReauthentication(
        accountId: accountId,
        username: username,
        password: password,
        savePassword: savePassword,
      );
      final bridge = await bridgeFactory();
      final capabilities = await bridge.capabilities();
      final runId = 'provisional:${_uuid.v4()}';
      final job = await bridge.startCollection(
        source: source,
        accountId: provisional.accountId,
        expectedUsername: accounts.stagedUsernameForSync(provisional),
        jwSemester: semesterOverride ?? capabilities.jwSemester,
      );
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
    } on AccountVerificationError catch (error) {
      if (provisional != null) accounts.cancelFirstLogin(provisional);
      return SyncFailed(source, code: error.code);
    } on BridgeProtocolError catch (error) {
      if (provisional != null) accounts.cancelFirstLogin(provisional);
      final code = error.code == 'busy' ? 'bridge_busy' : error.code;
      return SyncFailed(source, code: code);
    } on Object {
      if (provisional != null) accounts.cancelFirstLogin(provisional);
      return SyncFailed(source, code: 'reauthentication_failed');
    } finally {
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
      await paused.bridge.cancel(jobId);
      if (paused.provisional == null) {
        await _finishRun(paused.runId, 'cancelled', 'cancelled');
      } else {
        accounts.cancelFirstLogin(paused.provisional!);
      }
      return SyncCancelled(paused.source);
    }
    final password = paused.provisional == null
        ? await accounts.passwordForInteractiveLogin(paused.accountId)
        : accounts.stagedPasswordForInteractiveLogin(paused.provisional!);
    await paused.bridge.resumeLogin(jobId, password: password);
    return _consume(
      bridge: paused.bridge,
      source: paused.source,
      accountId: paused.accountId,
      runId: paused.runId,
      jobId: paused.jobId,
      sequence: paused.sequence,
      provisional: paused.provisional,
      verifiedUsername: paused.verifiedUsername,
    );
  }

  Future<SyncOutcome> _consume({
    required BridgeGateway bridge,
    required SyncSource source,
    required String accountId,
    required String runId,
    required String jobId,
    required int sequence,
    ProvisionalAccount? provisional,
    String? verifiedUsername,
  }) async {
    var cursor = sequence;
    while (true) {
      final poll = await bridge.poll(jobId, cursor);
      cursor = poll.nextSequence;
      if (poll.lastPhase == 'needs_user_login') {
        _paused[jobId] = _PausedSync(
          source: source,
          accountId: accountId,
          runId: runId,
          jobId: jobId,
          sequence: cursor,
          bridge: bridge,
          provisional: provisional,
          verifiedUsername: verifiedUsername,
        );
        if (provisional == null) {
          await _setRunState(runId, 'needs_user_action');
        }
        return SyncNeedsUserAction(source, jobId: jobId);
      }
      if (!poll.terminal) continue;
      if (poll.result != null) {
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
          Uint8List.fromList(utf8.encode(jsonEncode(poll.result))),
          accountId: importAccountId,
          origin: ImportOrigin.bridge,
        );
        await _recordSuccess(source, importAccountId, persistedRunId);
        return SyncSucceeded(
          source,
          importedEntityCount: result.importedEntityCount,
        );
      }
      final code = poll.errorCode ?? 'collection_failed';
      if (code == 'cancelled') {
        if (provisional != null) accounts.cancelFirstLogin(provisional);
        if (provisional == null) {
          await _finishRun(runId, 'cancelled', code);
        }
        return SyncCancelled(source);
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
    BridgeCapabilities capabilities,
  ) async {
    final timestamp = now();
    await _ensureConfig(
      SyncSource.jw,
      accountId,
      timestamp: timestamp,
      config: capabilities.jwSemester.toJson(),
    );
    await _ensureConfig(
      SyncSource.youngSchedule,
      accountId,
      timestamp: timestamp,
    );
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
