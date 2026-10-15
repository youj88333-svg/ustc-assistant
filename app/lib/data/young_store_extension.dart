part of 'jw_store.dart';

enum YoungStoreCheckpoint { afterFirstWrite, beforeCommit }

/// Issued by C3 and held only by the controlled source job chain.
final class YoungJobTicket extends _SchoolCredentialTicket {
  YoungJobTicket._(
    this.stamp,
    String expectedAccountCode,
    this.firstDay,
    this.lastDay,
  ) : super(expectedAccountCode);
  final YoungWorkStamp stamp;
  final DateTime? firstDay;
  final DateTime? lastDay;

  @override
  String get _credentialOwnerId => stamp.ownerId;
  @override
  String toString() => 'YoungJobTicket';
}

/// Young shares the canonical account and SQL queue with JW. Its facts,
/// generations and browser permits are separate from the JW source.
extension YoungStoreOperations on JwStore {
  Future<QueryRow> _youngState() =>
      customSelect('SELECT * FROM young_state WHERE singleton = 1').getSingle();

  Future<QueryRow?> _youngJob(String id) => customSelect(
    'SELECT * FROM young_jobs WHERE job_id = ?',
    variables: [Variable.withString(id)],
  ).getSingleOrNull();

  Future<void> _initializeYoungState() async {
    final state = await _youngState();
    final active = state.read<String?>('active_job_id');
    if (active != null) {
      await customStatement(
        "UPDATE young_jobs SET status = 'abandoned' WHERE job_id = ? AND status = 'active'",
        [active],
      );
    }
    await customStatement(
      'UPDATE young_state SET generation = generation + 1, active_job_id = NULL WHERE singleton = 1',
    );
  }

  Future<YoungAuthority> readYoungAuthority() => _serialized(() async {
    final canonical = await _state();
    final state = await _youngState();
    final owner = canonical.read<String>('owner_id');
    _validateOwner(owner);
    final account = await _account();
    if (account != null) {
      _validateAccountCode(account.read<String>('expected_account_code'));
    }
    return YoungAuthority(
      ownerId: owner,
      generation: state.read<int>('generation'),
      resetEpoch: canonical.read<int>('reset_epoch'),
      accountBound: account != null,
    );
  });

  Future<List<YoungClaimPermit>> readYoungPermits() => _serialized(() async {
    final canonical = await _state();
    final owner = canonical.read<String>('owner_id');
    _validateOwner(owner);
    final rows = await customSelect(
      'SELECT * FROM young_permits ORDER BY partition_id',
    ).get();
    if (rows.isNotEmpty && await _account() == null) {
      throw const AppFailure(FailureCode.storageFailed);
    }
    return List.unmodifiable(
      rows.map((row) {
        final ref = _decodeYoungPartition(
          row.read<String>('partition_metadata'),
        );
        if (ref.id != row.read<String>('partition_id') ||
            ref.ownerId != owner ||
            ref.resetEpoch != canonical.read<int>('reset_epoch') ||
            row.read<int>('account_id') != 1) {
          throw const AppFailure(FailureCode.storageFailed);
        }
        return YoungClaimPermit(partition: ref, accountId: 1);
      }),
    );
  });

  Future<YoungJobTicket> beginYoungJob({
    required YoungJobKind kind,
    String? expectedAccountCode,
    DateTime? firstDay,
    DateTime? lastDay,
  }) async {
    if (kind == YoungJobKind.calendar) {
      _validateYoungDays(firstDay, lastDay);
    } else if (firstDay != null || lastDay != null) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    final ticket = await _serialized(
      () => transaction(() async {
        final canonical = await _state();
        final state = await _youngState();
        final owner = canonical.read<String>('owner_id');
        _validateOwner(owner);
        final account = await _account();
        String expected;
        if (account == null) {
          if (expectedAccountCode == null) {
            throw const YoungIdentityException(
              YoungIdentityFailure.identityUnverified,
            );
          }
          expected = _normalizeAccountCode(expectedAccountCode);
        } else {
          final bound = account.read<String>('expected_account_code');
          _validateAccountCode(bound);
          expected = expectedAccountCode == null
              ? bound
              : _normalizeAccountCode(expectedAccountCode);
          if (expected != bound) {
            throw const YoungIdentityException(
              YoungIdentityFailure.identityMismatch,
            );
          }
        }
        final epoch = canonical.read<int>('reset_epoch');
        final generation = state.read<int>('generation') + 1;
        final active = state.read<String?>('active_job_id');
        if (active != null) {
          await customStatement(
            "UPDATE young_jobs SET status = 'abandoned' WHERE job_id = ? AND status = 'active'",
            [active],
          );
        }
        final stamp = YoungWorkStamp(
          jobId: 'young-$epoch-$generation',
          ownerId: owner,
          generation: generation,
          resetEpoch: epoch,
          kind: kind,
          accountId: account == null ? null : 1,
        );
        await customStatement(
          'INSERT INTO young_jobs (job_id,generation,reset_epoch,account_id,kind,status,staged_partition) '
          "VALUES (?,?,?,?,?,'active',NULL)",
          [stamp.jobId, generation, epoch, stamp.accountId, kind.name],
        );
        await customStatement(
          'UPDATE young_state SET generation = ?, active_job_id = ? WHERE singleton = 1',
          [generation, stamp.jobId],
        );
        await _guard();
        return YoungJobTicket._(stamp, expected, firstDay, lastDay);
      }),
    );
    for (final previous in _youngTickets.values) {
      previous._credentialsRevoked = true;
      previous._revokeSecrets();
    }
    _youngTickets.clear();
    _youngTickets[ticket.stamp.jobId] = ticket;
    return ticket;
  }

  bool _youngTicketMatches(YoungJobTicket ticket, QueryRow job) =>
      job.read<String>('job_id') == ticket.stamp.jobId &&
      job.read<int>('generation') == ticket.stamp.generation &&
      job.read<int>('reset_epoch') == ticket.stamp.resetEpoch &&
      job.read<int?>('account_id') == ticket.stamp.accountId &&
      job.read<String>('kind') == ticket.stamp.kind.name;

  Future<void> stageYoungCredentials(
    YoungJobTicket ticket,
    String password, {
    required bool save,
  }) => _serialized(
    () => _stageSchoolCredentials(
      ticket,
      password,
      save: save,
      requireCurrent: () => _requireYoungCurrent(ticket),
    ),
  );

  Future<JwSecretLease?> leaseYoungCredentials(YoungJobTicket ticket) =>
      _serialized(
        () => _leaseSchoolCredentials(
          ticket,
          requireCurrent: () => _requireYoungCurrent(ticket),
        ),
      );

  Future<void> _requireYoungCurrent(
    YoungJobTicket ticket, {
    bool allowCommitted = false,
  }) async {
    final stamp = ticket.stamp;
    if (!identical(_youngTickets[stamp.jobId], ticket)) {
      throw const AppFailure(FailureCode.staleResult);
    }
    final canonical = await _state();
    final state = await _youngState();
    final job = await _youngJob(stamp.jobId);
    if (canonical.read<String>('owner_id') != stamp.ownerId) {
      throw const AppFailure(FailureCode.ownershipLost);
    }
    _validateOwner(stamp.ownerId);
    if (job == null) {
      throw const AppFailure(FailureCode.staleResult);
    }
    final status = job.read<String>('status');
    if (status == 'cancelled') {
      throw const AppFailure(FailureCode.cancelled);
    }
    if (stamp.jobId != 'young-${stamp.resetEpoch}-${stamp.generation}' ||
        !_youngTicketMatches(ticket, job) ||
        state.read<int>('generation') != stamp.generation ||
        canonical.read<int>('reset_epoch') != stamp.resetEpoch ||
        state.read<String?>('active_job_id') != stamp.jobId ||
        (status != 'active' && !(allowCommitted && status == 'committed'))) {
      throw const AppFailure(FailureCode.staleResult);
    }
    await _guard();
  }

  Future<void> stageYoungPartition(
    YoungJobTicket ticket,
    YoungPartitionRef ref,
  ) => _serialized(
    () => transaction(() async {
      await _requireYoungCurrent(ticket);
      _validateYoungPartition(ticket, ref);
      final permit = await customSelect(
        'SELECT * FROM young_permits WHERE partition_id = ?',
        variables: [Variable.withString(ref.id)],
      ).getSingleOrNull();
      if (permit == null) {
        if (ref.attempt != ticket.stamp.jobId) {
          throw const AppFailure(FailureCode.staleResult);
        }
      } else if (!_decodeYoungPartition(
            permit.read<String>('partition_metadata'),
          ).sameAs(ref) ||
          permit.read<int>('account_id') != 1) {
        throw const AppFailure(FailureCode.ownerConflict);
      }
      final job = (await _youngJob(ticket.stamp.jobId))!;
      final prior = job.read<String?>('staged_partition');
      if (prior != null && !_decodeYoungPartition(prior).sameAs(ref)) {
        throw const AppFailure(FailureCode.staleResult);
      }
      await customStatement(
        'UPDATE young_jobs SET staged_partition = ? WHERE job_id = ?',
        [jsonEncode(ref.metadata), ticket.stamp.jobId],
      );
      await _requireYoungCurrent(ticket);
    }),
  );

  Future<bool> cancelYoungJob(YoungJobTicket ticket) {
    ticket._credentialsRevoked = true;
    ticket._secretLease?.revoke();
    return _serialized(
      () => transaction(() async {
        final canonical = await _state();
        if (canonical.read<String>('owner_id') != ticket.stamp.ownerId) {
          throw const AppFailure(FailureCode.ownershipLost);
        }
        final job = await _youngJob(ticket.stamp.jobId);
        if (job == null || !_youngTicketMatches(ticket, job)) {
          return false;
        }
        final status = job.read<String>('status');
        if (status == 'committed') {
          // The receipt/permit remain committed. Cancel only revokes delivery of
          // an as-yet-undelivered query from this generation.
          final state = await _youngState();
          if (state.read<String?>('active_job_id') == ticket.stamp.jobId) {
            await customStatement(
              'UPDATE young_state SET generation = generation + 1, active_job_id = NULL WHERE singleton = 1',
            );
          }
          await _guard();
          return false;
        }
        if (status != 'active') {
          return true;
        }
        if (!identical(_youngTickets[ticket.stamp.jobId], ticket)) {
          throw const AppFailure(FailureCode.staleResult);
        }
        await customStatement(
          "UPDATE young_jobs SET status = 'cancelled' WHERE job_id = ? AND status = 'active'",
          [ticket.stamp.jobId],
        );
        final state = await _youngState();
        if (state.read<String?>('active_job_id') == ticket.stamp.jobId) {
          await customStatement(
            'UPDATE young_state SET generation = generation + 1, active_job_id = NULL WHERE singleton = 1',
          );
        }
        await _guard();
        return true;
      }),
    ).whenComplete(ticket._revokeSecrets);
  }

  Future<void> failYoungJob(YoungJobTicket ticket) {
    ticket._credentialsRevoked = true;
    ticket._secretLease?.revoke();
    return _serialized(
      () => transaction(() async {
        final canonical = await _state();
        if (canonical.read<String>('owner_id') != ticket.stamp.ownerId) {
          throw const AppFailure(FailureCode.ownershipLost);
        }
        final job = await _youngJob(ticket.stamp.jobId);
        if (job == null ||
            !_youngTicketMatches(ticket, job) ||
            job.read<String>('status') != 'active') {
          return;
        }
        if (!identical(_youngTickets[ticket.stamp.jobId], ticket)) {
          throw const AppFailure(FailureCode.staleResult);
        }
        await customStatement(
          "UPDATE young_jobs SET status = 'failed' WHERE job_id = ? AND status = 'active'",
          [ticket.stamp.jobId],
        );
        final state = await _youngState();
        if (state.read<String?>('active_job_id') == ticket.stamp.jobId) {
          await customStatement(
            'UPDATE young_state SET generation = generation + 1, active_job_id = NULL WHERE singleton = 1',
          );
        }
        await _guard();
      }),
    ).whenComplete(ticket._revokeSecrets);
  }

  Future<YoungCompletionReceipt> importYoungCalendar(
    YoungJobTicket ticket,
    YoungCollectedArtifact artifact,
  ) {
    if (ticket.stamp.kind != YoungJobKind.calendar) {
      return Future.error(const AppFailure(FailureCode.invalidSnapshot));
    }
    return _completeYoung(ticket, artifact);
  }

  Future<YoungCompletionReceipt> completeYoungQuery(
    YoungJobTicket ticket,
    YoungCollectedArtifact artifact,
  ) {
    if (ticket.stamp.kind != YoungJobKind.activities) {
      return Future.error(const AppFailure(FailureCode.invalidSnapshot));
    }
    return _completeYoung(ticket, artifact);
  }

  Future<YoungCompletionReceipt> _completeYoung(
    YoungJobTicket ticket,
    YoungCollectedArtifact artifact,
  ) => _serialized(() async {
    _youngFirstWriteCheckpoints.remove(ticket.stamp.jobId);
    var succeeded = false;
    try {
      final receipt = await transaction(() async {
        await _requireYoungCurrent(ticket, allowCommitted: true);
        _validateYoungArtifact(ticket, artifact);
        final job = (await _youngJob(ticket.stamp.jobId))!;
        final staged = job.read<String?>('staged_partition');
        if (staged == null ||
            !_decodeYoungPartition(staged).sameAs(artifact.partition)) {
          throw const AppFailure(FailureCode.staleResult);
        }
        final prior = await customSelect(
          'SELECT * FROM young_receipts WHERE job_id = ?',
          variables: [Variable.withString(ticket.stamp.jobId)],
        ).getSingleOrNull();
        if (prior != null) {
          if (prior.read<String>('content_fingerprint') !=
                  artifact.contentFingerprint ||
              prior.read<String>('kind') != ticket.stamp.kind.name ||
              !_decodeYoungPartition(
                prior.read<String>('partition_metadata'),
              ).sameAs(artifact.partition)) {
            throw const AppFailure(FailureCode.idempotencyConflict);
          }
          if (job.read<String>('status') != 'committed' ||
              prior.read<int>('account_id') != 1) {
            throw const AppFailure(FailureCode.storageFailed);
          }
          await _guard();
          return YoungCompletionReceipt(
            operationId: ticket.stamp.jobId,
            kind: ticket.stamp.kind,
            itemCount: prior.read<int>('item_count'),
            replayed: true,
            permit: YoungClaimPermit(
              partition: artifact.partition,
              accountId: 1,
            ),
          );
        }
        if (job.read<String>('status') != 'active') {
          throw const AppFailure(FailureCode.staleResult);
        }
        final account = await _account();
        if (!artifact.matchesExpected(ticket.expectedAccountCode)) {
          throw const YoungIdentityException(
            YoungIdentityFailure.accountMismatch,
          );
        }
        if (account == null) {
          if (ticket.stamp.accountId != null) {
            throw const AppFailure(FailureCode.storageFailed);
          }
          await customStatement(
            'INSERT INTO jw_account (account_id, expected_account_code) VALUES (1, ?)',
            [ticket.expectedAccountCode],
          );
          await _youngNoteWrite(ticket);
        } else {
          final bound = account.read<String>('expected_account_code');
          _validateAccountCode(bound);
          if (ticket.stamp.accountId != 1 ||
              ticket.expectedAccountCode != bound ||
              !artifact.matchesExpected(bound)) {
            throw const YoungIdentityException(
              YoungIdentityFailure.accountMismatch,
            );
          }
        }
        if (ticket.stamp.kind == YoungJobKind.calendar) {
          await _applyYoungProjection(ticket, artifact);
          await customStatement(
            'INSERT INTO young_preferences (account_id,first_day,last_day) VALUES (1,?,?) '
            'ON CONFLICT(account_id) DO UPDATE SET first_day=excluded.first_day,last_day=excluded.last_day',
            [
              _youngDayString(ticket.firstDay!),
              _youngDayString(ticket.lastDay!),
            ],
          );
          await _youngNoteWrite(ticket);
        }
        final at = _clock.nowUtc;
        if (!at.isUtc) {
          throw const AppFailure(FailureCode.storageFailed);
        }
        final count = ticket.stamp.kind == YoungJobKind.calendar
            ? artifact.entries.length
            : artifact.activities.length;
        await customStatement(
          'INSERT INTO young_receipts (operation_id,job_id,kind,content_fingerprint,partition_metadata,item_count,account_id,committed_at) VALUES (?,?,?,?,?,?,1,?)',
          [
            ticket.stamp.jobId,
            ticket.stamp.jobId,
            ticket.stamp.kind.name,
            artifact.contentFingerprint,
            jsonEncode(artifact.partition.metadata),
            count,
            at.microsecondsSinceEpoch,
          ],
        );
        await _youngNoteWrite(ticket);
        await customStatement(
          'INSERT INTO young_audit (action,item_count,committed_at) VALUES (?,?,?)',
          [
            ticket.stamp.kind == YoungJobKind.calendar ? 'import' : 'query',
            count,
            at.microsecondsSinceEpoch,
          ],
        );
        final permit = await customSelect(
          'SELECT * FROM young_permits WHERE partition_id = ?',
          variables: [Variable.withString(artifact.partition.id)],
        ).getSingleOrNull();
        if (permit != null &&
            (!_decodeYoungPartition(
                  permit.read<String>('partition_metadata'),
                ).sameAs(artifact.partition) ||
                permit.read<int>('account_id') != 1)) {
          throw const AppFailure(FailureCode.ownerConflict);
        }
        await customStatement(
          'DELETE FROM young_permits WHERE partition_id != ?',
          [artifact.partition.id],
        );
        if (permit == null) {
          await customStatement(
            'INSERT INTO young_permits (partition_id,partition_metadata,account_id) VALUES (?,?,1)',
            [artifact.partition.id, jsonEncode(artifact.partition.metadata)],
          );
        }
        await customStatement(
          "UPDATE young_jobs SET status = 'committed' WHERE job_id = ? AND status = 'active'",
          [ticket.stamp.jobId],
        );
        await _commitSchoolCredentials(ticket, at);
        await onYoungCheckpoint?.call(YoungStoreCheckpoint.beforeCommit);
        await _requireYoungCurrent(ticket, allowCommitted: true);
        if (ticket.stamp.kind == YoungJobKind.calendar) {
          await customStatement(
            'UPDATE agenda_state SET revision=revision+1 WHERE singleton=1',
          );
          await features._captureExpected();
        }
        await agent._commitSourceAction(ticket, count);
        return YoungCompletionReceipt(
          operationId: ticket.stamp.jobId,
          kind: ticket.stamp.kind,
          itemCount: count,
          replayed: false,
          permit: YoungClaimPermit(partition: artifact.partition, accountId: 1),
        );
      });
      succeeded = true;
      if (!receipt.replayed) {
        if (receipt.kind == YoungJobKind.calendar) {
          localCalendar._signal(
            (await localCalendar._agendaState()).read<int>('revision'),
          );
        }
        agent._signal();
      }
      if (!receipt.replayed &&
          ticket._saveCredential &&
          ticket._pendingCredential != null) {
        _credentialChanges.add(true);
      }
      return receipt;
    } finally {
      if (succeeded) ticket._revokeSecrets();
      _youngFirstWriteCheckpoints.remove(ticket.stamp.jobId);
    }
  });

  Future<void> validateYoungDelivery(
    YoungJobTicket ticket,
    YoungCollectedArtifact artifact,
  ) => _serialized(() async {
    await _requireYoungCurrent(ticket, allowCommitted: true);
    _validateYoungArtifact(ticket, artifact);
    final receipt = await customSelect(
      'SELECT * FROM young_receipts WHERE job_id = ?',
      variables: [Variable.withString(ticket.stamp.jobId)],
    ).getSingleOrNull();
    if (receipt == null ||
        receipt.read<String>('content_fingerprint') !=
            artifact.contentFingerprint) {
      throw const AppFailure(FailureCode.staleResult);
    }
    final account = await _account();
    if (account == null ||
        !artifact.matchesExpected(
          account.read<String>('expected_account_code'),
        )) {
      throw const YoungIdentityException(YoungIdentityFailure.accountMismatch);
    }
    await _guard();
  });

  void _validateYoungPartition(YoungJobTicket ticket, YoungPartitionRef ref) {
    if (!YoungPartitionRef.decode(ref.metadata).sameAs(ref)) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    if (ref.ownerId != ticket.stamp.ownerId) {
      throw const AppFailure(FailureCode.ownershipLost);
    }
    if (ref.resetEpoch != ticket.stamp.resetEpoch) {
      throw const AppFailure(FailureCode.staleResult);
    }
  }

  void _validateYoungArtifact(
    YoungJobTicket ticket,
    YoungCollectedArtifact artifact,
  ) {
    final stamp = artifact.stamp;
    if (stamp.jobId != ticket.stamp.jobId ||
        stamp.ownerId != ticket.stamp.ownerId ||
        stamp.generation != ticket.stamp.generation ||
        stamp.resetEpoch != ticket.stamp.resetEpoch ||
        stamp.accountId != ticket.stamp.accountId ||
        stamp.kind != ticket.stamp.kind ||
        artifact.sourceKey != ticket.stamp.kind.sourceKey ||
        artifact.contractVersion != ticket.stamp.kind.contractVersion ||
        artifact.firstDay != ticket.firstDay ||
        artifact.lastDay != ticket.lastDay ||
        artifact.session <= 0 ||
        artifact.document <= 0 ||
        artifact.operation <= 0 ||
        !artifact.collectedAtUtc.isUtc ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(artifact.contentFingerprint)) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    _validateYoungPartition(ticket, artifact.partition);
  }

  Future<void> _youngNoteWrite(YoungJobTicket ticket) async {
    if (!_youngFirstWriteCheckpoints.add(ticket.stamp.jobId)) {
      return;
    }
    await onYoungCheckpoint?.call(YoungStoreCheckpoint.afterFirstWrite);
    await _requireYoungCurrent(ticket);
  }

  Future<void> _applyYoungProjection(
    YoungJobTicket ticket,
    YoungCollectedArtifact artifact,
  ) async {
    final oldRows = await customSelect(
      'SELECT e.* FROM young_events e JOIN young_overlays o ON o.local_id=e.local_id',
    ).get();
    final incoming = {for (final row in artifact.entries) row.id};
    final byId = {
      for (final row in oldRows) row.read<String>('external_id'): row,
    };
    for (final old in oldRows) {
      if (incoming.contains(old.read<String>('external_id'))) {
        continue;
      }
      final start = DateTime.fromMicrosecondsSinceEpoch(
        old.read<int>('starts_at'),
        isUtc: true,
      );
      final end = DateTime.fromMicrosecondsSinceEpoch(
        old.read<int>('ends_at'),
        isUtc: true,
      );
      final within =
          start.isBefore(artifact.rangeEndUtc!) &&
          end.isAfter(artifact.rangeStartUtc!);
      final desired = within
          ? YoungPresence.missingWithinScope
          : YoungPresence.outsideScope;
      final retired = within ? 1 : old.read<int>('source_retired');
      if (old.read<String>('presence') != desired.name ||
          old.read<int>('source_retired') != retired) {
        await customStatement(
          'UPDATE young_events SET presence=?,source_retired=?,version=version+1 WHERE local_id=?',
          [desired.name, retired, old.read<int>('local_id')],
        );
        await _youngNoteWrite(ticket);
      }
    }
    for (final entry in artifact.entries) {
      final old = byId[entry.id];
      if (old == null) {
        await customStatement(
          'INSERT INTO young_events (external_id,item_id,title,place,starts_at,ends_at,presence,version) VALUES (?,?,?,?,?,?,?,1)',
          [
            entry.id,
            entry.itemId,
            entry.title,
            entry.place,
            entry.startsAtUtc.microsecondsSinceEpoch,
            entry.endsAtUtc.microsecondsSinceEpoch,
            YoungPresence.observed.name,
          ],
        );
        await _youngNoteWrite(ticket);
        await customStatement(
          'INSERT INTO young_overlays (local_id,hidden) SELECT local_id,0 FROM young_events WHERE external_id=?',
          [entry.id],
        );
      } else if (old.read<String>('item_id') != entry.itemId ||
          old.read<String>('title') != entry.title ||
          old.read<String>('place') != entry.place ||
          old.read<int>('starts_at') !=
              entry.startsAtUtc.microsecondsSinceEpoch ||
          old.read<int>('ends_at') != entry.endsAtUtc.microsecondsSinceEpoch ||
          old.read<String>('presence') != YoungPresence.observed.name ||
          old.read<int>('source_retired') != 0) {
        await customStatement(
          'UPDATE young_events SET item_id=?,title=?,place=?,starts_at=?,ends_at=?,presence=?,source_retired=0,version=version+1 WHERE local_id=?',
          [
            entry.itemId,
            entry.title,
            entry.place,
            entry.startsAtUtc.microsecondsSinceEpoch,
            entry.endsAtUtc.microsecondsSinceEpoch,
            YoungPresence.observed.name,
            old.read<int>('local_id'),
          ],
        );
        await _youngNoteWrite(ticket);
      }
    }
  }

  Future<void> revokeYoungPermits() {
    for (final ticket in _youngTickets.values) {
      ticket._credentialsRevoked = true;
      ticket._secretLease?.revoke();
    }
    return _serialized(
      () => transaction(() async {
        final state = await _youngState();
        final active = state.read<String?>('active_job_id');
        if (active != null) {
          await customStatement(
            "UPDATE young_jobs SET status='cancelled' WHERE job_id=? AND status='active'",
            [active],
          );
        }
        await customStatement('DELETE FROM young_permits');
        await customStatement(
          'UPDATE young_state SET generation=generation+1,active_job_id=NULL WHERE singleton=1',
        );
        await _guard();
        for (final ticket in _youngTickets.values) {
          ticket._revokeSecrets();
        }
        _youngTickets.clear();
      }),
    );
  }

  Future<YoungLocalWriteReceipt> setYoungHidden(
    YoungHiddenCommand command,
  ) => _serialized(
    () => transaction(() async {
      final canonical = await _state();
      if (!RegExp(
            r'^young-local-[0-9a-f]{32}$',
          ).hasMatch(command.operationId) ||
          command.localId <= 0 ||
          command.expectedVersion <= 0 ||
          command.accountId != 1) {
        throw const AppFailure(FailureCode.invalidSnapshot);
      }
      if (canonical.read<String>('owner_id') != command.ownerId) {
        throw const AppFailure(FailureCode.ownershipLost);
      }
      if (canonical.read<int>('reset_epoch') != command.resetEpoch ||
          await _account() == null) {
        throw const AppFailure(FailureCode.staleResult);
      }
      final intent = fingerprint([
        'young-local-hidden',
        command.ownerId,
        command.accountId,
        command.resetEpoch,
        command.localId,
        command.expectedVersion,
        command.hidden,
      ]);
      final prior = await customSelect(
        'SELECT * FROM young_local_receipts WHERE operation_id=?',
        variables: [Variable.withString(command.operationId)],
      ).getSingleOrNull();
      if (prior != null) {
        if (prior.read<String>('fingerprint') != intent) {
          throw const AppFailure(FailureCode.idempotencyConflict);
        }
        await _guard();
        return YoungLocalWriteReceipt(
          operationId: command.operationId,
          resultVersion: prior.read<int>('result_version'),
          hidden: prior.read<int>('hidden') == 1,
          replayed: true,
        );
      }
      final event = await customSelect(
        'SELECT e.version,o.hidden FROM young_events e JOIN young_overlays o ON o.local_id=e.local_id WHERE e.local_id=?',
        variables: [Variable.withInt(command.localId)],
      ).getSingleOrNull();
      if (event == null ||
          event.read<int>('version') != command.expectedVersion) {
        throw const AppFailure(FailureCode.staleResult);
      }
      final at = _clock.nowUtc;
      if (!at.isUtc) {
        throw const AppFailure(FailureCode.storageFailed);
      }
      var version = command.expectedVersion;
      if ((event.read<int>('hidden') == 1) != command.hidden) {
        await customStatement(
          'UPDATE young_overlays SET hidden=? WHERE local_id=?',
          [command.hidden ? 1 : 0, command.localId],
        );
        await customStatement(
          'UPDATE young_events SET version=version+1 WHERE local_id=?',
          [command.localId],
        );
        ++version;
        await customStatement(
          'UPDATE agenda_state SET revision=revision+1 WHERE singleton=1',
        );
        await features._captureExpected();
        await customStatement(
          "INSERT INTO young_audit (action,item_count,committed_at) VALUES ('overlay',1,?)",
          [at.microsecondsSinceEpoch],
        );
      }
      await customStatement(
        'INSERT INTO young_local_receipts (operation_id,fingerprint,result_version,hidden,committed_at) VALUES (?,?,?,?,?)',
        [
          command.operationId,
          intent,
          version,
          command.hidden ? 1 : 0,
          at.microsecondsSinceEpoch,
        ],
      );
      await _guard();
      return YoungLocalWriteReceipt(
        operationId: command.operationId,
        resultVersion: version,
        hidden: command.hidden,
        replayed: false,
      );
    }),
  );

  Future<YoungDataView> readYoungView() => _serialized(() async {
    final account = await _account();
    if (account != null) {
      _validateAccountCode(account.read<String>('expected_account_code'));
    }
    final rows = await customSelect(
      'SELECT e.*,o.hidden FROM young_events e JOIN young_overlays o ON o.local_id=e.local_id ORDER BY e.starts_at,e.local_id',
    ).get();
    if (account == null && rows.isNotEmpty) {
      throw const AppFailure(FailureCode.storageFailed);
    }
    final events = rows.map((row) {
      final presence = YoungPresence.values.where(
        (p) => p.name == row.read<String>('presence'),
      );
      if (presence.length != 1) {
        throw const AppFailure(FailureCode.storageFailed);
      }
      return YoungStoredEvent(
        localId: row.read<int>('local_id'),
        version: row.read<int>('version'),
        title: row.read<String>('title'),
        place: row.read<String>('place'),
        startsAtUtc: DateTime.fromMicrosecondsSinceEpoch(
          row.read<int>('starts_at'),
          isUtc: true,
        ),
        endsAtUtc: DateTime.fromMicrosecondsSinceEpoch(
          row.read<int>('ends_at'),
          isUtc: true,
        ),
        presence: presence.single,
        sourceRetired: row.read<int>('source_retired') == 1,
        hidden: row.read<int>('hidden') == 1,
      );
    }).toList();
    final preferences = await customSelect(
      'SELECT first_day,last_day FROM young_preferences WHERE account_id=1',
    ).getSingleOrNull();
    final first = preferences == null
        ? null
        : _decodeYoungDay(preferences.read<String>('first_day'));
    final last = preferences == null
        ? null
        : _decodeYoungDay(preferences.read<String>('last_day'));
    if (preferences != null) {
      _validateYoungDays(first, last);
    }
    return YoungDataView(
      accountBound: account != null,
      credentialSaved:
          await _count('SELECT COUNT(*) AS count FROM jw_credentials') != 0,
      importCount: await _count(
        "SELECT COUNT(*) AS count FROM young_receipts WHERE kind='calendar'",
      ),
      queryCount: await _count(
        "SELECT COUNT(*) AS count FROM young_receipts WHERE kind='activities'",
      ),
      auditCount: await _count('SELECT COUNT(*) AS count FROM young_audit'),
      events: events,
      firstDay: first,
      lastDay: last,
    );
  });

  YoungPartitionRef _decodeYoungPartition(String value) {
    if (value.length > 4096) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic>) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    return YoungPartitionRef.decode(decoded);
  }
}

void _validateYoungDays(DateTime? first, DateTime? last) {
  bool day(DateTime? value) =>
      value != null &&
      value.isUtc &&
      value.year >= 1 &&
      value.year <= 9999 &&
      value == DateTime.utc(value.year, value.month, value.day);
  if (!day(first) ||
      !day(last) ||
      last!.isBefore(first!) ||
      last.difference(first).inDays >= 62) {
    throw const AppFailure(FailureCode.invalidSnapshot);
  }
}

String _youngDayString(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
DateTime _decodeYoungDay(String value) {
  final result = DateTime.tryParse(value);
  if (result == null ||
      _youngDayString(result) != value ||
      value.length != 10) {
    throw const AppFailure(FailureCode.storageFailed);
  }
  return DateTime.utc(result.year, result.month, result.day);
}

const _youngSchema = [
  '''CREATE TABLE young_state (
    singleton INTEGER PRIMARY KEY CHECK(singleton=1), generation INTEGER NOT NULL,
    active_job_id TEXT
  )''',
  'INSERT INTO young_state (singleton,generation,active_job_id) VALUES (1,0,NULL)',
  '''CREATE TABLE young_jobs (
    job_id TEXT PRIMARY KEY, generation INTEGER NOT NULL, reset_epoch INTEGER NOT NULL,
    account_id INTEGER, kind TEXT NOT NULL CHECK(kind IN ('calendar','activities')),
    status TEXT NOT NULL CHECK(status IN ('active','cancelled','abandoned','failed','committed')),
    staged_partition TEXT
  )''',
  '''CREATE TABLE young_events (
    local_id INTEGER PRIMARY KEY AUTOINCREMENT, external_id TEXT NOT NULL UNIQUE,
    item_id TEXT NOT NULL CHECK(length(item_id)>0), title TEXT NOT NULL, place TEXT NOT NULL,
    starts_at INTEGER NOT NULL, ends_at INTEGER NOT NULL CHECK(ends_at>starts_at),
    presence TEXT NOT NULL CHECK(presence IN ('observed','outsideScope','missingWithinScope')),
    version INTEGER NOT NULL CHECK(version>0),
    source_retired INTEGER NOT NULL DEFAULT 0 CHECK(source_retired IN (0,1))
  )''',
  '''CREATE TABLE young_overlays (
    local_id INTEGER PRIMARY KEY, hidden INTEGER NOT NULL CHECK(hidden IN (0,1))
  )''',
  '''CREATE TABLE young_receipts (
    operation_id TEXT PRIMARY KEY, job_id TEXT NOT NULL UNIQUE,
    kind TEXT NOT NULL CHECK(kind IN ('calendar','activities')), content_fingerprint TEXT NOT NULL,
    partition_metadata TEXT NOT NULL, item_count INTEGER NOT NULL CHECK(item_count>=0),
    account_id INTEGER NOT NULL CHECK(account_id=1), committed_at INTEGER NOT NULL
  )''',
  '''CREATE TABLE young_permits (
    partition_id TEXT PRIMARY KEY, partition_metadata TEXT NOT NULL,
    account_id INTEGER NOT NULL CHECK(account_id=1)
  )''',
  '''CREATE TABLE young_preferences (
    account_id INTEGER PRIMARY KEY CHECK(account_id=1), first_day TEXT NOT NULL,last_day TEXT NOT NULL
  )''',
  '''CREATE TABLE young_audit (
    audit_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    action TEXT NOT NULL CHECK(action IN ('import','query','overlay')),
    item_count INTEGER NOT NULL CHECK(item_count>=0), committed_at INTEGER NOT NULL
  )''',
  '''CREATE TABLE young_local_receipts (
    operation_id TEXT PRIMARY KEY,fingerprint TEXT NOT NULL,
    result_version INTEGER NOT NULL CHECK(result_version>0),
    hidden INTEGER NOT NULL CHECK(hidden IN (0,1)),committed_at INTEGER NOT NULL
  )''',
];
