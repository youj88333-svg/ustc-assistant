import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';

import '../core/contracts.dart';
import 'import_contract.dart';

enum ImportCheckpoint { afterFirstWrite, beforeCommit }

/// The only writer for the disposable M0 database. No school account exists.
final class DemoStore extends GeneratedDatabase implements DemoReadPort {
  DemoStore(
    super.executor, {
    required AssetOwnership ownership,
    required AppClock clock,
    this.sourceKey = 'synthetic-demo',
    this.contractVersion = 'm0-synthetic-v1',
    this.onCheckpoint,
    // Public capability names keep platform internals out of the constructor.
    // ignore: prefer_initializing_formals
  }) : _ownership = ownership,
       // ignore: prefer_initializing_formals
       _clock = clock;

  static const localContext = 'm0-synthetic-context-v1';
  final AssetOwnership _ownership;
  final AppClock _clock;
  final String sourceKey;
  final String contractVersion;
  final Future<void> Function(ImportCheckpoint)? onCheckpoint;
  Future<void> _queue = Future.value();
  bool _closing = false;
  Future<void>? _closeFuture;

  @override
  int get schemaVersion => 1;

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) => transaction(() async {
      _ownership.ensureHeld();
      for (final statement in _schema) {
        await customStatement(statement);
      }
      await customStatement(
        'INSERT INTO demo_state VALUES (1, ?, ?, ?, 0, 0, 0)',
        [localContext, sourceKey, contractVersion],
      );
      _ownership.ensureHeld();
    }),
    onUpgrade: (_, _, _) async =>
        throw const AppFailure(FailureCode.storageFailed),
  );

  Future<T> _serialized<T>(Future<T> Function() action) {
    if (_closing) return Future.error(const AppFailure(FailureCode.closed));
    final result = Completer<T>();
    final previous = _queue;
    _queue = () async {
      await previous;
      try {
        _ownership.ensureHeld();
        result.complete(await action());
      } on AppFailure catch (error) {
        result.completeError(error);
      } on Object {
        result.completeError(const AppFailure(FailureCode.storageFailed));
      }
    }();
    return result.future;
  }

  Future<QueryRow> _state() =>
      customSelect('SELECT * FROM demo_state WHERE singleton = 1').getSingle();

  Future<void> initialize() => _serialized(
    () => transaction(() async {
      final state = await _state();
      if (state.read<String>('local_context') != localContext ||
          state.read<String>('source_key') != sourceKey ||
          state.read<String>('contract_version') != contractVersion) {
        throw const AppFailure(FailureCode.storageFailed);
      }
      // An interrupted in-memory job is never resumed as an authorized action.
      await customStatement(
        "UPDATE demo_jobs SET status = 'abandoned' WHERE status = 'active'",
      );
      await customStatement(
        'UPDATE demo_state SET generation = generation + 1 WHERE singleton = 1',
      );
      _ownership.ensureHeld();
    }),
  );

  Future<JobStamp> beginJob() => _serialized(
    () => transaction(() async {
      final state = await _state();
      if (state.read<int>('maintenance') != 0) {
        throw const AppFailure(FailureCode.staleResult);
      }
      final generation = state.read<int>('generation') + 1;
      final epoch = state.read<int>('reset_epoch');
      final stamp = JobStamp(
        jobId: 'demo-$epoch-$generation',
        localContext: localContext,
        sourceKey: sourceKey,
        contractVersion: contractVersion,
        generation: generation,
        resetEpoch: epoch,
      );
      await customStatement(
        'UPDATE demo_state SET generation = ? WHERE singleton = 1',
        [generation],
      );
      await customStatement(
        "INSERT INTO demo_jobs VALUES (?, ?, ?, 'active', NULL)",
        [stamp.jobId, generation, epoch],
      );
      _ownership.ensureHeld();
      return stamp;
    }),
  );

  Future<QueryRow?> _job(String id) => customSelect(
    'SELECT * FROM demo_jobs WHERE job_id = ?',
    variables: [Variable.withString(id)],
  ).getSingleOrNull();

  Future<void> _requireCurrent(JobStamp stamp) async {
    final state = await _state();
    final job = await _job(stamp.jobId);
    if (job?.read<String>('status') == 'cancelled') {
      throw const AppFailure(FailureCode.cancelled);
    }
    if (stamp.localContext != state.read<String>('local_context') ||
        stamp.sourceKey != state.read<String>('source_key') ||
        stamp.contractVersion != state.read<String>('contract_version') ||
        stamp.generation != state.read<int>('generation') ||
        stamp.resetEpoch != state.read<int>('reset_epoch') ||
        state.read<int>('maintenance') != 0 ||
        job == null ||
        job.read<int>('generation') != stamp.generation ||
        job.read<int>('reset_epoch') != stamp.resetEpoch ||
        !['active', 'committed'].contains(job.read<String>('status'))) {
      throw const AppFailure(FailureCode.staleResult);
    }
    _ownership.ensureHeld();
  }

  Future<CancellationDisposition> cancelJob(JobStamp stamp) => _serialized(
    () => transaction(() async {
      final job = await _job(stamp.jobId);
      final state = await _state();
      if (stamp.localContext != localContext ||
          stamp.sourceKey != sourceKey ||
          stamp.contractVersion != contractVersion ||
          job == null ||
          job.read<int>('generation') != stamp.generation ||
          job.read<int>('reset_epoch') != stamp.resetEpoch) {
        return CancellationDisposition.notActive;
      }
      if (job.read<String>('status') == 'committed') {
        return CancellationDisposition.alreadyCommitted;
      }
      if (job.read<String>('status') == 'cancelled') {
        return CancellationDisposition.cancelled;
      }
      if (job.read<String>('status') != 'active' ||
          stamp.generation != state.read<int>('generation') ||
          stamp.resetEpoch != state.read<int>('reset_epoch')) {
        return CancellationDisposition.notActive;
      }
      await customStatement(
        "UPDATE demo_jobs SET status = 'cancelled' WHERE job_id = ?",
        [stamp.jobId],
      );
      await customStatement(
        'UPDATE demo_state SET generation = generation + 1 '
        'WHERE singleton = 1',
      );
      _ownership.ensureHeld();
      return CancellationDisposition.cancelled;
    }),
  );

  Future<void> finishFailed(JobStamp stamp) => _serialized(() async {
    await customStatement(
      "UPDATE demo_jobs SET status = 'failed' WHERE job_id = ? "
      "AND generation = ? AND reset_epoch = ? AND status = 'active'",
      [stamp.jobId, stamp.generation, stamp.resetEpoch],
    );
  });

  void _validate(ImportRequest request) {
    if (!request.complete) {
      throw const AppFailure(FailureCode.incompleteSnapshot);
    }
    if (request.operationId.isEmpty ||
        request.operationId.length > 160 ||
        !request.rangeStartUtc.isUtc ||
        !request.rangeEndUtc.isUtc ||
        !request.collectedAtUtc.isUtc ||
        !request.rangeStartUtc.isBefore(request.rangeEndUtc) ||
        request.events.length > 1000 ||
        request.contentFingerprint != request.calculatedFingerprint) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    final identities = <String>{};
    for (final event in request.events) {
      if (event.externalId.isEmpty ||
          event.externalId.length > 160 ||
          event.title.trim().isEmpty ||
          event.title.length > 160 ||
          !event.startsAtUtc.isUtc ||
          !event.endsAtUtc.isUtc ||
          !event.startsAtUtc.isBefore(event.endsAtUtc) ||
          event.startsAtUtc.isBefore(request.rangeStartUtc) ||
          !event.startsAtUtc.isBefore(request.rangeEndUtc) ||
          !identities.add(event.externalId)) {
        throw const AppFailure(FailureCode.invalidSnapshot);
      }
    }
  }

  Future<ImportReceipt> importSnapshot(
    ImportRequest request, {
    bool simulateSqlFailure = false,
  }) async {
    final result = await _serialized(
      () => transaction(() async {
        await _requireCurrent(request.stamp);
        final receipt = await _import(request, simulateSqlFailure);
        _ownership.ensureHeld();
        await onCheckpoint?.call(ImportCheckpoint.beforeCommit);
        _ownership.ensureHeld();
        return receipt;
      }),
    );
    return result;
  }

  Future<ImportReceipt> _import(
    ImportRequest request,
    bool simulateSqlFailure,
  ) async {
    _validate(request);
    final prior = await customSelect(
      'SELECT * FROM demo_imports WHERE operation_id = ?',
      variables: [Variable.withString(request.operationId)],
    ).getSingleOrNull();
    if (prior != null) {
      if (prior.read<String>('content_fingerprint') !=
          request.contentFingerprint) {
        throw const AppFailure(FailureCode.idempotencyConflict);
      }
      await _markCommitted(request.stamp, request.operationId);
      return _receipt(prior, replayed: true);
    }
    final job = await _job(request.stamp.jobId);
    if (job?.read<String>('status') == 'committed') {
      throw const AppFailure(FailureCode.staleResult);
    }

    // Scope membership is evaluated before upsert. Old identities stay local.
    await customStatement(
      'UPDATE demo_events SET source_missing = 1 '
      'WHERE starts_at >= ? AND starts_at < ?',
      [
        request.rangeStartUtc.microsecondsSinceEpoch,
        request.rangeEndUtc.microsecondsSinceEpoch,
      ],
    );
    var writes = 0;
    for (final event in request.events) {
      await customStatement(
        'INSERT INTO demo_events '
        '(external_id, title, starts_at, ends_at, source_missing) '
        'VALUES (?, ?, ?, ?, 0) ON CONFLICT(external_id) DO UPDATE SET '
        'title = excluded.title, starts_at = excluded.starts_at, '
        'ends_at = excluded.ends_at, source_missing = 0',
        [
          event.externalId,
          event.title,
          event.startsAtUtc.microsecondsSinceEpoch,
          event.endsAtUtc.microsecondsSinceEpoch,
        ],
      );
      if (++writes == 1) {
        await onCheckpoint?.call(ImportCheckpoint.afterFirstWrite);
        if (simulateSqlFailure) {
          // A real SQLite NOT NULL violation, never a fabricated rollback.
          await customStatement(
            'INSERT INTO demo_events '
            '(external_id, title, starts_at, ends_at) VALUES (NULL, NULL, 0, 0)',
          );
        }
      }
    }
    final encoded = jsonEncode([
      request.rangeStartUtc.microsecondsSinceEpoch,
      request.rangeEndUtc.microsecondsSinceEpoch,
      request.collectedAtUtc.microsecondsSinceEpoch,
      request.events.map((event) => event.canonicalFields).toList(),
    ]);
    await customStatement(
      'INSERT INTO demo_imports '
      '(operation_id, content_fingerprint, record_count, normalized_payload, '
      'committed_at) VALUES (?, ?, ?, ?, ?)',
      [
        request.operationId,
        request.contentFingerprint,
        request.events.length,
        encoded,
        _clock.nowUtc.microsecondsSinceEpoch,
      ],
    );
    // Audit stores safe counts only; no account/job/operation id or payload.
    await customStatement(
      'INSERT INTO demo_audit (record_count, committed_at) VALUES (?, ?)',
      [request.events.length, _clock.nowUtc.microsecondsSinceEpoch],
    );
    await customStatement(
      'INSERT INTO demo_followups (operation_id, pending) VALUES (?, 1)',
      [request.operationId],
    );
    await _markCommitted(request.stamp, request.operationId);
    return ImportReceipt(
      operationId: request.operationId,
      recordCount: request.events.length,
      replayed: false,
      followUpPending: true,
    );
  }

  Future<void> _markCommitted(JobStamp stamp, String operationId) =>
      customStatement(
        "UPDATE demo_jobs SET status = 'committed', operation_id = ? "
        'WHERE job_id = ?',
        [operationId, stamp.jobId],
      );

  Future<ImportReceipt> _receipt(QueryRow row, {required bool replayed}) async {
    final operation = row.read<String>('operation_id');
    final pending = await customSelect(
      'SELECT pending FROM demo_followups WHERE operation_id = ?',
      variables: [Variable.withString(operation)],
    ).getSingle();
    return ImportReceipt(
      operationId: operation,
      recordCount: row.read<int>('record_count'),
      replayed: replayed,
      followUpPending: pending.read<int>('pending') != 0,
    );
  }

  Future<ImportReceipt> replayLatest(JobStamp stamp) => _serialized(
    () => transaction(() async {
      await _requireCurrent(stamp);
      final row = await customSelect(
        'SELECT * FROM demo_imports ORDER BY import_sequence DESC LIMIT 1',
      ).getSingleOrNull();
      if (row == null) throw const AppFailure(FailureCode.invalidSnapshot);
      final payload =
          jsonDecode(row.read<String>('normalized_payload')) as List<dynamic>;
      final events = (payload[3] as List<dynamic>).map((item) {
        final fields = item as List<dynamic>;
        return EventDraft(
          externalId: fields[0] as String,
          title: fields[1] as String,
          startsAtUtc: DateTime.fromMicrosecondsSinceEpoch(
            fields[2] as int,
            isUtc: true,
          ),
          endsAtUtc: DateTime.fromMicrosecondsSinceEpoch(
            fields[3] as int,
            isUtc: true,
          ),
        );
      }).toList();
      final result = await _import(
        ImportRequest(
          stamp: stamp,
          operationId: row.read<String>('operation_id'),
          rangeStartUtc: DateTime.fromMicrosecondsSinceEpoch(
            payload[0] as int,
            isUtc: true,
          ),
          rangeEndUtc: DateTime.fromMicrosecondsSinceEpoch(
            payload[1] as int,
            isUtc: true,
          ),
          collectedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
            payload[2] as int,
            isUtc: true,
          ),
          contentFingerprint: row.read<String>('content_fingerprint'),
          events: events,
        ),
        false,
      );
      _ownership.ensureHeld();
      return result;
    }),
  );

  Future<void> completeFollowUp(String operationId) => _serialized(
    () => transaction(() async {
      // The demonstration follow-up actually reads the committed projection.
      await customSelect(
        'SELECT COUNT(*) AS count FROM demo_events',
      ).getSingle();
      await customStatement(
        'UPDATE demo_followups SET pending = 0 WHERE operation_id = ?',
        [operationId],
      );
      _ownership.ensureHeld();
    }),
  );

  Future<void> completePendingFollowUps() => _serialized(
    () => transaction(() async {
      await customSelect(
        'SELECT COUNT(*) AS count FROM demo_events',
      ).getSingle();
      await customStatement(
        'UPDATE demo_followups SET pending = 0 WHERE pending = 1',
      );
      _ownership.ensureHeld();
    }),
  );

  Future<void> enterMaintenance() => _serialized(
    () => transaction(() async {
      await customStatement(
        'UPDATE demo_state SET reset_epoch = reset_epoch + 1, '
        'generation = generation + 1, maintenance = 1 WHERE singleton = 1',
      );
      await customStatement(
        "UPDATE demo_jobs SET status = 'cancelled' WHERE status = 'active'",
      );
      _ownership.ensureHeld();
    }),
  );

  Future<void> resumeAfterMaintenance() => _serialized(() async {
    await customStatement(
      'UPDATE demo_state SET maintenance = 0 WHERE singleton = 1',
    );
    _ownership.ensureHeld();
  });

  @override
  Future<DemoDataView> readView() => _serialized(() async {
    final rows = await customSelect(
      'SELECT * FROM demo_events ORDER BY starts_at, external_id',
    ).get();
    Future<int> count(String table) async => (await customSelect(
      'SELECT COUNT(*) AS count FROM $table',
    ).getSingle()).read<int>('count');
    final pending = (await customSelect(
      'SELECT COUNT(*) AS count FROM demo_followups WHERE pending = 1',
    ).getSingle()).read<int>('count');
    return DemoDataView(
      events: rows
          .map(
            (row) => StoredEvent(
              localId: row.read<int>('local_id'),
              externalId: row.read<String>('external_id'),
              title: row.read<String>('title'),
              startsAtUtc: DateTime.fromMicrosecondsSinceEpoch(
                row.read<int>('starts_at'),
                isUtc: true,
              ),
              endsAtUtc: DateTime.fromMicrosecondsSinceEpoch(
                row.read<int>('ends_at'),
                isUtc: true,
              ),
              sourceMissing: row.read<int>('source_missing') != 0,
            ),
          )
          .toList(),
      importCount: await count('demo_imports'),
      auditCount: await count('demo_audit'),
      pendingFollowUps: pending,
    );
  });

  @override
  Future<void> close() {
    return _closeFuture ??= _drainAndClose();
  }

  Future<void> _drainAndClose() async {
    _closing = true;
    await _queue;
    await super.close();
  }

  static const _schema = [
    '''CREATE TABLE demo_state (
      singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
      local_context TEXT NOT NULL, source_key TEXT NOT NULL,
      contract_version TEXT NOT NULL, generation INTEGER NOT NULL,
      reset_epoch INTEGER NOT NULL, maintenance INTEGER NOT NULL
    )''',
    '''CREATE TABLE demo_jobs (
      job_id TEXT PRIMARY KEY, generation INTEGER NOT NULL,
      reset_epoch INTEGER NOT NULL,
      status TEXT NOT NULL CHECK(status IN
        ('active','cancelled','abandoned','failed','committed')),
      operation_id TEXT
    )''',
    '''CREATE TABLE demo_events (
      local_id INTEGER PRIMARY KEY AUTOINCREMENT,
      external_id TEXT NOT NULL UNIQUE, title TEXT NOT NULL,
      starts_at INTEGER NOT NULL, ends_at INTEGER NOT NULL,
      source_missing INTEGER NOT NULL DEFAULT 0 CHECK(source_missing IN (0,1)),
      CHECK(starts_at < ends_at)
    )''',
    '''CREATE TABLE demo_imports (
      import_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
      operation_id TEXT NOT NULL UNIQUE, content_fingerprint TEXT NOT NULL,
      record_count INTEGER NOT NULL, normalized_payload TEXT NOT NULL,
      committed_at INTEGER NOT NULL
    )''',
    '''CREATE TABLE demo_audit (
      audit_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
      record_count INTEGER NOT NULL, committed_at INTEGER NOT NULL
    )''',
    '''CREATE TABLE demo_followups (
      operation_id TEXT PRIMARY KEY REFERENCES demo_imports(operation_id),
      pending INTEGER NOT NULL CHECK(pending IN (0,1))
    )''',
  ];
}
