import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:crypto/crypto.dart';

import '../core/contracts.dart';
import '../core/agenda_contract.dart';
import '../core/calendar_contract.dart';
import '../core/calendar_validation.dart';
import '../core/jw_academic_details.dart';
import '../core/public_query_contract.dart';
import '../core/knowledge_contract.dart';
import '../core/settings_contract.dart';
import '../core/jw_work_contract.dart';
import '../core/jw_credentials.dart';
import '../core/young_work_contract.dart';
import '../core/agent_contract.dart';
import '../core/agent_conversation_contract.dart';
import '../core/agent_permission_contract.dart';
import '../core/agent_source_contract.dart';
import '../core/agent_action_contract.dart';
import '../core/agent_evidence.dart';
import '../core/agent_text.dart';
import '../source/young_collection_contract.dart';
import '../source/jw_collection_contract.dart';
import '../source/jw_probe_contract.dart';
import '../source/jw_semester_catalog.dart';
import 'jw_import_contract.dart';
import 'young_import_contract.dart';
import 'knowledge_markdown.dart';
import 'bundled_knowledge_identity.dart';
import 'calendar_projection.dart';
import 'agent_plan_preview.dart';

part 'young_store_extension.dart';
part 'public_store.dart';
part 'local_calendar_store.dart';
part 'local_task_store.dart';
part 'calendar_undo_store.dart';
part 'application_settings_store.dart';
part 'agent_store.dart';
part 'agent_chat_store.dart';
part 'agent_permission_store.dart';
part 'agent_plan_store.dart';

enum JwImportCheckpoint { afterFirstWrite, beforeCommit }

/// A write capability issued by one [JwStore]. It is deliberately not
/// serializable and its string representation never includes its identity.
abstract class _SchoolCredentialTicket {
  _SchoolCredentialTicket(this._expectedAccountCode);
  final String _expectedAccountCode;
  String get _credentialOwnerId;
  Uint8List? _pendingCredential;
  bool _saveCredential = false;
  bool _credentialIssued = false;
  bool _credentialsRevoked = false;
  JwSecretLease? _secretLease;

  void _revokeSecrets() {
    _pendingCredential?.fillRange(0, _pendingCredential!.length, 0);
    _pendingCredential = null;
    _secretLease?.revoke();
    _secretLease = null;
  }

  /// Private C1/C2 handoff only. Product UI should not read this value.
  String get expectedAccountCode => _expectedAccountCode;
}

final class JwJobTicket extends _SchoolCredentialTicket {
  JwJobTicket._(this.stamp, String expected) : super(expected);
  final JwWorkStamp stamp;
  JwSemesterCatalog? _semesterCatalog;

  @override
  String get _credentialOwnerId => stamp.ownerId;

  @override
  String toString() => 'JwJobTicket';
}

/// The normalized, account-bound JW projection. This database is separate
/// from the disposable M0 demonstration store.
final class JwStore extends GeneratedDatabase implements JwReadPort {
  JwStore(
    super.executor, {
    required AssetOwnership ownership,
    required AppClock clock,
    this.onCheckpoint,
    this.credentialProtector,
    this.onYoungCheckpoint,
    this.onKnowledgeCheckpoint,
    this.onCalendarCheckpoint,
    this.onSettingsCheckpoint,
    this.modelCredentialProtector,
    this.onAgentCheckpoint,
    this.knowledgeIdentity = bundledKnowledgeIdentity,
    // Keep the public capability names independent of platform internals.
    // ignore: prefer_initializing_formals
  }) : _ownership = ownership,
       // ignore: prefer_initializing_formals
       _clock = clock,
       _newOwnerId = _randomHexId('jw-owner-');

  final AssetOwnership _ownership;
  final AppClock _clock;
  final Future<void> Function(JwImportCheckpoint)? onCheckpoint;
  final JwCredentialProtector? credentialProtector;
  final Future<void> Function(YoungStoreCheckpoint)? onYoungCheckpoint;
  final Future<void> Function()? onKnowledgeCheckpoint;
  final Future<void> Function()? onCalendarCheckpoint;
  final Future<void> Function()? onSettingsCheckpoint;
  final KnowledgeEditionIdentity knowledgeIdentity;
  final ModelCredentialProtector? modelCredentialProtector;
  final Future<void> Function()? onAgentCheckpoint;
  late final AgentStore agent = AgentStore._(this);
  late final PublicStore publicStore = PublicStore._(this);
  late final LocalCalendarStore localCalendar = LocalCalendarStore._(this);
  late final ApplicationSettingsStore applicationSettings =
      ApplicationSettingsStore._(this);
  final String _newOwnerId;
  final Map<String, JwJobTicket> _tickets = {};
  final Map<String, YoungJobTicket> _youngTickets = {};
  final _credentialChanges = StreamController<bool>.broadcast();

  /// Shared presence only, emitted after a committed save/delete transaction.
  Stream<bool> get credentialChanges => _credentialChanges.stream;
  final Set<String> _youngFirstWriteCheckpoints = {};
  final Set<String> _firstWriteCheckpoints = {};
  Future<void> _queue = Future<void>.value();
  bool _closing = false;
  Future<void>? _closeFuture;

  @override
  int get schemaVersion => 14;

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) => transaction(() async {
      _ownership.ensureHeld();
      for (final statement in [
        ..._schema,
        ..._credentialSchema,
        ..._catalogSchema,
        ..._youngSchema,
        ...PublicStore.schema,
        ...LocalCalendarStore.schema,
        ...LocalCalendarStore.taskSchema,
        ...ApplicationSettingsStore.schema,
        ...AgentStore.schema,
        ...AgentStore.upgradeFrom11,
        ..._agentActionSchema,
        ..._AgentChatState.schema,
        ..._AgentPermissionState.schema,
      ]) {
        await customStatement(statement);
      }
      await customStatement(
        'INSERT INTO jw_state '
        '(singleton, owner_id, generation, reset_epoch, active_job_id) '
        'VALUES (1, ?, 0, 0, NULL)',
        [_newOwnerId],
      );
      _ownership.ensureHeld();
    }),
    onUpgrade: (_, from, to) async {
      if (from < 1 || from > 13 || to != 14) {
        throw const AppFailure(FailureCode.storageFailed);
      }
      await transaction(() async {
        _ownership.ensureHeld();
        for (final statement in [
          if (from == 1) ..._credentialSchema,
          if (from <= 2) ..._catalogSchema,
          if (from <= 3) ..._youngSchema,
          if (from <= 4) ...PublicStore.schema,
          if (from <= 5) ...LocalCalendarStore.schema,
          if (from == 6) ...LocalCalendarStore.upgradeFrom6,
          if (from <= 7)
            "ALTER TABLE jw_events ADD COLUMN academic_json TEXT CHECK(academic_json IS NULL OR length(academic_json)<=24576)",
          if (from <= 8) ...LocalCalendarStore.taskSchema,
          if (from <= 8)
            'UPDATE agenda_state SET epoch=epoch+1,revision=revision+1 WHERE singleton=1',
          if (from <= 9) ...ApplicationSettingsStore.schema,
          if (from <= 9)
            'UPDATE agenda_state SET epoch=epoch+1,revision=revision+1 WHERE singleton=1',
          if (from <= 10) ...AgentStore.schema,
          if (from <= 11) ...AgentStore.upgradeFrom11,
          if (from <= 12) ..._agentActionSchema,
          ..._AgentChatState.schema,
          ..._AgentPermissionState.schema,
        ]) {
          await customStatement(statement);
        }
        _ownership.ensureHeld();
      });
    },
  );

  Future<T> _serialized<T>(Future<T> Function() action) {
    if (_closing) return Future<T>.error(const AppFailure(FailureCode.closed));
    final result = Completer<T>();
    final previous = _queue;
    _queue = () async {
      await previous;
      try {
        _ownership.ensureHeld();
        result.complete(await action());
      } on AppFailure catch (error) {
        result.completeError(error);
      } on JwIdentityException catch (error) {
        result.completeError(error);
      } on JwCredentialException catch (error) {
        result.completeError(error);
      } on YoungIdentityException catch (error) {
        result.completeError(error);
      } on PublicFailure catch (error) {
        result.completeError(error);
      } on CalendarFailure catch (error) {
        result.completeError(error);
      } on SettingsFailure catch (error) {
        result.completeError(error);
      } on AgentFailure catch (error) {
        result.completeError(error);
      } on Object {
        result.completeError(const AppFailure(FailureCode.storageFailed));
      }
    }();
    return result.future;
  }

  Future<QueryRow> _state() =>
      customSelect('SELECT * FROM jw_state WHERE singleton = 1').getSingle();

  Future<QueryRow?> _job(String jobId) => customSelect(
    'SELECT * FROM jw_jobs WHERE job_id = ?',
    variables: [Variable.withString(jobId)],
  ).getSingleOrNull();

  Future<QueryRow?> _account() => customSelect(
    'SELECT * FROM jw_account WHERE account_id = 1',
  ).getSingleOrNull();

  Future<void> _guard() async {
    _ownership.ensureHeld();
    if (localCalendar._maintenanceRequested ||
        (await localCalendar._agendaState()).read<int>('maintenance') != 0) {
      throw const AppFailure(FailureCode.cleanupPending);
    }
  }

  Future<void> initialize() => _serialized(() async {
    await transaction(() async {
      final state = await _state();
      _validateOwner(state.read<String>('owner_id'));
      final activeJobId = state.read<String?>('active_job_id');
      if (activeJobId != null) {
        await customStatement(
          "UPDATE jw_jobs SET status = 'abandoned' "
          "WHERE job_id = ? AND status = 'active'",
          [activeJobId],
        );
      }
      await customStatement(
        'UPDATE jw_state SET generation = generation + 1, active_job_id = NULL '
        'WHERE singleton = 1',
      );
      await _initializeYoungState();
      await publicStore._initialize();
      await _guard();
    });
    for (final ticket in _tickets.values) {
      ticket._revokeSecrets();
    }
    _tickets.clear();
    _firstWriteCheckpoints.clear();
    for (final ticket in _youngTickets.values) {
      ticket._credentialsRevoked = true;
      ticket._revokeSecrets();
    }
    _youngTickets.clear();
    _youngFirstWriteCheckpoints.clear();
  });

  void _validateOwner(String ownerId) {
    if (!RegExp(r'^jw-owner-[0-9a-f]{32}$').hasMatch(ownerId)) {
      throw const AppFailure(FailureCode.storageFailed);
    }
  }

  Future<JwAuthority> readAuthority() => _serialized(() async {
    final state = await _state();
    final ownerId = state.read<String>('owner_id');
    _validateOwner(ownerId);
    final account = await _account();
    if (account != null) {
      _validateAccountCode(account.read<String>('expected_account_code'));
    }
    return JwAuthority(
      ownerId: ownerId,
      generation: state.read<int>('generation'),
      resetEpoch: state.read<int>('reset_epoch'),
      accountBound: account != null,
    );
  });

  Future<List<JwClaimPermit>> readCommittedPermits() => _serialized(() async {
    final state = await _state();
    final ownerId = state.read<String>('owner_id');
    _validateOwner(ownerId);
    final rows = await customSelect(
      'SELECT partition_id, partition_metadata, account_id '
      'FROM jw_permits ORDER BY partition_id',
    ).get();
    if (rows.isNotEmpty && await _account() == null) {
      throw const AppFailure(FailureCode.storageFailed);
    }
    return List.unmodifiable(
      rows.map((row) {
        final partition = _decodePartition(
          row.read<String>('partition_metadata'),
        );
        if (partition.id != row.read<String>('partition_id') ||
            partition.ownerId != ownerId ||
            row.read<int>('account_id') != 1) {
          throw const AppFailure(FailureCode.storageFailed);
        }
        return JwClaimPermit(
          partition: partition,
          accountId: row.read<int>('account_id'),
        );
      }),
    );
  });

  Future<JwJobTicket> beginJob({String? expectedAccountCode}) async {
    final ticket = await _serialized(
      () => transaction(() async {
        final state = await _state();
        final ownerId = state.read<String>('owner_id');
        _validateOwner(ownerId);
        final epoch = state.read<int>('reset_epoch');
        final account = await _account();
        late final String expected;
        int? accountId;
        if (account == null) {
          if (expectedAccountCode == null) {
            throw const JwIdentityException(
              JwIdentityFailure.identityUnverified,
            );
          }
          expected = _normalizeAccountCode(expectedAccountCode);
        } else {
          final boundCode = account.read<String>('expected_account_code');
          _validateAccountCode(boundCode);
          expected = expectedAccountCode == null
              ? boundCode
              : _normalizeAccountCode(expectedAccountCode);
          if (expected != boundCode) {
            throw const JwIdentityException(JwIdentityFailure.identityMismatch);
          }
          accountId = 1;
        }

        final generation = state.read<int>('generation') + 1;
        final priorActive = state.read<String?>('active_job_id');
        if (priorActive != null) {
          await customStatement(
            "UPDATE jw_jobs SET status = 'abandoned' "
            "WHERE job_id = ? AND status = 'active'",
            [priorActive],
          );
        }
        final jobId = 'jw-$epoch-$generation';
        final stamp = JwWorkStamp(
          jobId: jobId,
          ownerId: ownerId,
          generation: generation,
          resetEpoch: epoch,
          accountId: accountId,
        );
        final result = JwJobTicket._(stamp, expected);
        await customStatement(
          'INSERT INTO jw_jobs '
          '(job_id, generation, reset_epoch, account_id, status, staged_partition) '
          "VALUES (?, ?, ?, ?, 'active', NULL)",
          [jobId, generation, epoch, accountId],
        );
        await customStatement(
          'UPDATE jw_state SET generation = ?, active_job_id = ? '
          'WHERE singleton = 1',
          [generation, jobId],
        );
        await _guard();
        return result;
      }),
    );
    for (final previous in _tickets.values) {
      previous._credentialsRevoked = true;
      previous._revokeSecrets();
    }
    _tickets.clear();
    _tickets[ticket.stamp.jobId] = ticket;
    return ticket;
  }

  // Keep the existing DPAPI purpose to open already-saved school credentials.
  // Source-specific current tickets and CAS sinks govern each authorized use.
  String _credentialPurpose(_SchoolCredentialTicket ticket) =>
      'ustc-assistant/jw/login/v1:${ticket._credentialOwnerId}:${fingerprint(ticket.expectedAccountCode)}';

  /// Staged metadata is durable only with a successful, identity-bound import.
  Future<void> stageSemesterCatalog(
    JwJobTicket ticket,
    List<JwSemesterOption> options,
  ) => _serialized(() async {
    await _requireCurrent(ticket);
    ticket._semesterCatalog = JwSemesterCatalog.fromOptions(options);
  });

  /// New secrets remain private temporary ciphertext until verified import.
  Future<void> stageCredentials(
    JwJobTicket ticket,
    String password, {
    required bool save,
  }) => _serialized(
    () => _stageSchoolCredentials(
      ticket,
      password,
      save: save,
      requireCurrent: () => _requireCurrent(ticket),
    ),
  );

  Future<void> _stageSchoolCredentials(
    _SchoolCredentialTicket ticket,
    String password, {
    required bool save,
    required Future<void> Function() requireCurrent,
  }) async {
    await requireCurrent();
    if (password.isEmpty ||
        password.length > 1024 ||
        password.contains('\u0000') ||
        ticket._credentialIssued ||
        ticket._credentialsRevoked) {
      throw const JwCredentialException(JwCredentialFailure.invalidCredential);
    }
    final protector = credentialProtector;
    if (protector == null) {
      throw const JwCredentialException(JwCredentialFailure.unavailable);
    }
    final plain = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'username': ticket.expectedAccountCode,
          'password': password,
        }),
      ),
    );
    Uint8List? protected;
    try {
      if (plain.length > 16384) {
        throw const JwCredentialException(
          JwCredentialFailure.invalidCredential,
        );
      }
      protected = await protector.protect(
        plain,
        purpose: _credentialPurpose(ticket),
      );
      await requireCurrent();
      if (ticket._credentialsRevoked) {
        throw const AppFailure(FailureCode.cancelled);
      }
      if (protected.isEmpty || protected.length > 65536) {
        throw const JwCredentialException(JwCredentialFailure.protectionFailed);
      }
      ticket._revokeSecrets();
      ticket._pendingCredential = protected;
      ticket._saveCredential = save;
      protected = null;
    } finally {
      plain.fillRange(0, plain.length, 0);
      protected?.fillRange(0, protected.length, 0);
    }
  }

  /// Issued only after C1 has a document-bound, exact-origin credential sink.
  Future<JwSecretLease?> leaseCredentials(JwJobTicket ticket) => _serialized(
    () => _leaseSchoolCredentials(
      ticket,
      requireCurrent: () => _requireCurrent(ticket),
    ),
  );

  Future<JwSecretLease?> _leaseSchoolCredentials(
    _SchoolCredentialTicket ticket, {
    required Future<void> Function() requireCurrent,
  }) async {
    await requireCurrent();
    if (ticket._credentialsRevoked) {
      throw const AppFailure(FailureCode.cancelled);
    }
    if (ticket._credentialIssued) return null;
    ticket._credentialIssued = true;
    final protector = credentialProtector;
    final row = ticket._pendingCredential == null
        ? await customSelect(
            'SELECT mechanism, ciphertext FROM jw_credentials WHERE account_id = 1',
          ).getSingleOrNull()
        : null;
    if (ticket._pendingCredential == null && row == null) return null;
    if (protector == null ||
        (row != null && row.read<String>('mechanism') != protector.mechanism)) {
      throw const JwCredentialException(JwCredentialFailure.unavailable);
    }
    final cipher = Uint8List.fromList(
      ticket._pendingCredential ?? row!.read<Uint8List>('ciphertext'),
    );
    Uint8List? plain;
    try {
      if (cipher.isEmpty || cipher.length > 65536) {
        throw const JwCredentialException(JwCredentialFailure.protectionFailed);
      }
      plain = await protector.unprotect(
        cipher,
        purpose: _credentialPurpose(ticket),
      );
      await requireCurrent();
      if (ticket._credentialsRevoked) {
        throw const AppFailure(FailureCode.cancelled);
      }
      if (plain.isEmpty || plain.length > 16384) {
        throw const JwCredentialException(JwCredentialFailure.protectionFailed);
      }
      final decoded = jsonDecode(utf8.decode(plain));
      if (decoded is! Map ||
          decoded.length != 2 ||
          decoded['username'] != ticket.expectedAccountCode ||
          decoded['password'] is! String ||
          (decoded['password'] as String).isEmpty ||
          (decoded['password'] as String).length > 1024 ||
          (decoded['password'] as String).contains('\u0000')) {
        throw const JwCredentialException(
          JwCredentialFailure.invalidCredential,
        );
      }
      final lease = JwSecretLease(plain);
      ticket._secretLease = lease;
      plain = null;
      return lease;
    } on FormatException {
      throw const JwCredentialException(JwCredentialFailure.invalidCredential);
    } finally {
      cipher.fillRange(0, cipher.length, 0);
      plain?.fillRange(0, plain.length, 0);
    }
  }

  Future<void> _commitSchoolCredentials(
    _SchoolCredentialTicket ticket,
    DateTime at,
  ) async {
    if (!ticket._saveCredential || ticket._pendingCredential == null) return;
    final protector = credentialProtector;
    if (protector == null) {
      throw const JwCredentialException(JwCredentialFailure.unavailable);
    }
    await customStatement(
      'INSERT INTO jw_credentials (account_id, mechanism, ciphertext) VALUES (1, ?, ?) '
      'ON CONFLICT(account_id) DO UPDATE SET mechanism = excluded.mechanism, ciphertext = excluded.ciphertext',
      [protector.mechanism, ticket._pendingCredential],
    );
    await customStatement(
      "INSERT INTO jw_credential_audit (action, committed_at) VALUES ('saved', ?)",
      [at.microsecondsSinceEpoch],
    );
  }

  Future<void> deleteSavedCredential() => _serialized(() async {
    final changed = await transaction(() async {
      final state = await _state();
      _validateOwner(state.read<String>('owner_id'));
      final activeId = state.read<String?>('active_job_id');
      if (activeId != null &&
          (await _job(activeId))?.read<String>('status') == 'active') {
        throw const AppFailure(FailureCode.busy);
      }
      final activeYoung = (await _youngState()).read<String?>('active_job_id');
      if (activeYoung != null &&
          (await _youngJob(activeYoung))?.read<String>('status') == 'active') {
        throw const AppFailure(FailureCode.busy);
      }
      final changed = await customUpdate(
        'DELETE FROM jw_credentials WHERE account_id = 1',
      );
      if (changed != 0) {
        await customStatement(
          "INSERT INTO jw_credential_audit (action, committed_at) VALUES ('deleted', ?)",
          [_clock.nowUtc.microsecondsSinceEpoch],
        );
      }
      await _guard();
      return changed != 0;
    });
    if (changed) _credentialChanges.add(false);
  });

  Future<void> stagePartition(JwJobTicket ticket, JwPartitionRef ref) =>
      _serialized(
        () => transaction(() async {
          await _requireCurrent(ticket);
          _validatePartitionForTicket(ticket, ref);
          final priorPermit = await customSelect(
            'SELECT partition_metadata, account_id FROM jw_permits '
            'WHERE partition_id = ?',
            variables: [Variable.withString(ref.id)],
          ).getSingleOrNull();
          if (priorPermit != null) {
            final claimed = _decodePartition(
              priorPermit.read<String>('partition_metadata'),
            );
            if (!claimed.sameAs(ref) ||
                priorPermit.read<int>('account_id') != 1) {
              throw const AppFailure(FailureCode.ownerConflict);
            }
          } else if (ref.attempt != ticket.stamp.jobId) {
            throw const AppFailure(FailureCode.staleResult);
          }
          final job = (await _job(ticket.stamp.jobId))!;
          final existing = job.read<String?>('staged_partition');
          if (existing != null) {
            final staged = _decodePartition(existing);
            if (!staged.sameAs(ref)) {
              throw const AppFailure(FailureCode.staleResult);
            }
            await _guard();
            return;
          }
          await customStatement(
            'UPDATE jw_jobs SET staged_partition = ? WHERE job_id = ? '
            "AND status = 'active'",
            [jsonEncode(ref.metadata), ticket.stamp.jobId],
          );
          await _requireCurrent(ticket);
          await _guard();
        }),
      );

  void _validatePartitionForTicket(JwJobTicket ticket, JwPartitionRef ref) {
    final normalized = JwPartitionRef.decode(ref.metadata);
    if (!normalized.sameAs(ref)) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    if (ref.ownerId != ticket.stamp.ownerId) {
      throw const AppFailure(FailureCode.ownershipLost);
    }
    if (ref.resetEpoch != ticket.stamp.resetEpoch) {
      throw const AppFailure(FailureCode.staleResult);
    }
  }

  Future<void> _requireCurrent(
    JwJobTicket ticket, {
    bool allowCommitted = false,
  }) async {
    final stamp = ticket.stamp;
    if (!identical(_tickets[stamp.jobId], ticket)) {
      throw const AppFailure(FailureCode.staleResult);
    }
    final state = await _state();
    final job = await _job(stamp.jobId);
    if (state.read<String>('owner_id') != stamp.ownerId) {
      throw const AppFailure(FailureCode.ownershipLost);
    }
    _validateOwner(state.read<String>('owner_id'));
    if (job == null) throw const AppFailure(FailureCode.staleResult);
    final status = job.read<String>('status');
    if (status == 'cancelled') throw const AppFailure(FailureCode.cancelled);
    final storedAccountId = job.read<int?>('account_id');
    if (stamp.jobId != 'jw-${stamp.resetEpoch}-${stamp.generation}' ||
        job.read<int>('generation') != stamp.generation ||
        job.read<int>('reset_epoch') != stamp.resetEpoch ||
        storedAccountId != stamp.accountId ||
        state.read<int>('generation') != stamp.generation ||
        state.read<int>('reset_epoch') != stamp.resetEpoch ||
        state.read<String?>('active_job_id') != stamp.jobId ||
        (status != 'active' && !(allowCommitted && status == 'committed'))) {
      throw const AppFailure(FailureCode.staleResult);
    }
    await _guard();
  }

  Future<bool> cancelJob(JwJobTicket ticket) {
    ticket._credentialsRevoked = true;
    ticket._secretLease?.revoke();
    return _serialized(() async {
      ticket._revokeSecrets();
      await _guard();
      final state = await _state();
      if (state.read<String>('owner_id') != ticket.stamp.ownerId) {
        throw const AppFailure(FailureCode.ownershipLost);
      }
      final job = await _job(ticket.stamp.jobId);
      if (job == null) return false;
      if (!_ticketMatchesJob(ticket, job)) return false;
      final status = job.read<String>('status');
      if (status == 'committed') return false;
      if (status == 'cancelled') return true;
      if (status != 'active') return true;
      if (!identical(_tickets[ticket.stamp.jobId], ticket)) {
        throw const AppFailure(FailureCode.staleResult);
      }
      await transaction(() async {
        final currentState = await _state();
        final currentJob = await _job(ticket.stamp.jobId);
        if (currentJob == null) return;
        if (currentJob.read<String>('status') == 'committed') return;
        if (!_ticketMatchesJob(ticket, currentJob)) return;
        if (currentJob.read<String>('status') != 'active') return;
        await customStatement(
          "UPDATE jw_jobs SET status = 'cancelled' WHERE job_id = ? "
          "AND status = 'active'",
          [ticket.stamp.jobId],
        );
        if (currentState.read<String?>('active_job_id') == ticket.stamp.jobId) {
          await customStatement(
            'UPDATE jw_state SET generation = generation + 1, active_job_id = NULL '
            'WHERE singleton = 1',
          );
        }
        await _guard();
      });
      return true;
    });
  }

  Future<void> failJob(JwJobTicket ticket) => _serialized(() async {
    ticket._credentialsRevoked = true;
    ticket._revokeSecrets();
    await _guard();
    final state = await _state();
    if (state.read<String>('owner_id') != ticket.stamp.ownerId) {
      throw const AppFailure(FailureCode.ownershipLost);
    }
    await transaction(() async {
      final job = await _job(ticket.stamp.jobId);
      if (job == null ||
          job.read<String>('status') != 'active' ||
          !_ticketMatchesJob(ticket, job)) {
        return;
      }
      if (!identical(_tickets[ticket.stamp.jobId], ticket)) {
        throw const AppFailure(FailureCode.staleResult);
      }
      await customStatement(
        "UPDATE jw_jobs SET status = 'failed' WHERE job_id = ? AND status = 'active'",
        [ticket.stamp.jobId],
      );
      final currentState = await _state();
      if (currentState.read<String?>('active_job_id') == ticket.stamp.jobId) {
        await customStatement(
          'UPDATE jw_state SET generation = generation + 1, active_job_id = NULL '
          'WHERE singleton = 1',
        );
      }
      await _guard();
    });
  });

  Future<JwImportReceipt> importSnapshot(
    JwJobTicket ticket,
    JwCollectedArtifact artifact,
  ) => _serialized(() async {
    _firstWriteCheckpoints.remove(ticket.stamp.jobId);
    var succeeded = false;
    try {
      final receipt = await transaction(() async {
        await _requireCurrent(ticket, allowCommitted: true);
        _validateArtifact(ticket, artifact);
        final job = (await _job(ticket.stamp.jobId))!;
        final stagedRaw = job.read<String?>('staged_partition');
        if (stagedRaw == null) throw const AppFailure(FailureCode.staleResult);
        final staged = _decodePartition(stagedRaw);
        if (!staged.sameAs(artifact.partition)) {
          throw const AppFailure(FailureCode.staleResult);
        }

        final prior = await customSelect(
          'SELECT * FROM jw_imports WHERE job_id = ?',
          variables: [Variable.withString(ticket.stamp.jobId)],
        ).getSingleOrNull();
        if (prior != null) {
          final priorPartition = _decodePartition(
            prior.read<String>('partition_metadata'),
          );
          if (prior.read<String>('content_fingerprint') !=
                  artifact.contentFingerprint ||
              !priorPartition.sameAs(artifact.partition) ||
              prior.read<String>('operation_id') != ticket.stamp.jobId) {
            throw const AppFailure(FailureCode.idempotencyConflict);
          }
          if (job.read<String>('status') != 'committed' ||
              prior.read<int>('account_id') != 1) {
            throw const AppFailure(FailureCode.storageFailed);
          }
          await _guard();
          return JwImportReceipt(
            operationId: prior.read<String>('operation_id'),
            courseCount: prior.read<int>('course_count'),
            examCount: prior.read<int>('exam_count'),
            replayed: true,
            permit: JwClaimPermit(
              partition: priorPartition,
              accountId: prior.read<int>('account_id'),
            ),
          );
        }
        if (job.read<String>('status') != 'active') {
          throw const AppFailure(FailureCode.staleResult);
        }
        if (!artifact.matchesExpected(ticket.expectedAccountCode)) {
          throw const JwIdentityException(JwIdentityFailure.accountMismatch);
        }
        final catalog = ticket._semesterCatalog;
        if (catalog == null ||
            !catalog.options.any(
              (option) => option.id == artifact.semesterId,
            )) {
          throw const AppFailure(FailureCode.invalidSnapshot);
        }

        final account = await _account();
        if (account == null) {
          if (ticket.stamp.accountId != null) {
            throw const AppFailure(FailureCode.storageFailed);
          }
          await customStatement(
            'INSERT INTO jw_account (account_id, expected_account_code) VALUES (1, ?)',
            [ticket.expectedAccountCode],
          );
          await _checkpointAfterFirstWrite(ticket);
        } else {
          final boundCode = account.read<String>('expected_account_code');
          _validateAccountCode(boundCode);
          if (ticket.stamp.accountId != 1 ||
              ticket.expectedAccountCode != boundCode ||
              !artifact.matchesExpected(boundCode)) {
            throw const JwIdentityException(JwIdentityFailure.accountMismatch);
          }
        }

        await _applyProjection(ticket, artifact);
        final committedAt = _clock.nowUtc;
        if (!committedAt.isUtc) {
          throw const AppFailure(FailureCode.storageFailed);
        }
        await customStatement(
          'INSERT INTO jw_imports '
          '(operation_id, job_id, content_fingerprint, partition_metadata, '
          'course_count, exam_count, account_id, committed_at) '
          'VALUES (?, ?, ?, ?, ?, ?, 1, ?)',
          [
            ticket.stamp.jobId,
            ticket.stamp.jobId,
            artifact.contentFingerprint,
            jsonEncode(artifact.partition.metadata),
            artifact.courseCount,
            artifact.examCount,
            committedAt.microsecondsSinceEpoch,
          ],
        );
        await _checkpointAfterFirstWrite(ticket);
        await customStatement(
          "INSERT INTO jw_audit (action, course_count, exam_count, committed_at) "
          "VALUES ('import', ?, ?, ?)",
          [
            artifact.courseCount,
            artifact.examCount,
            committedAt.microsecondsSinceEpoch,
          ],
        );
        await _checkpointAfterFirstWrite(ticket);
        final existingPermit = await customSelect(
          'SELECT partition_metadata, account_id FROM jw_permits WHERE partition_id = ?',
          variables: [Variable.withString(artifact.partition.id)],
        ).getSingleOrNull();
        if (existingPermit != null) {
          final priorPartition = _decodePartition(
            existingPermit.read<String>('partition_metadata'),
          );
          if (!priorPartition.sameAs(artifact.partition) ||
              existingPermit.read<int>('account_id') != 1) {
            throw const AppFailure(FailureCode.ownerConflict);
          }
        }
        await customStatement(
          'DELETE FROM jw_permits WHERE partition_id != ?',
          [artifact.partition.id],
        );
        await _checkpointAfterFirstWrite(ticket);
        if (existingPermit == null) {
          await customStatement(
            'INSERT INTO jw_permits (partition_id, partition_metadata, account_id) '
            'VALUES (?, ?, 1)',
            [artifact.partition.id, jsonEncode(artifact.partition.metadata)],
          );
          await _checkpointAfterFirstWrite(ticket);
        }
        await customStatement(
          'INSERT INTO jw_preferences (account_id, semester_id) VALUES (1, ?) '
          'ON CONFLICT(account_id) DO UPDATE SET semester_id = excluded.semester_id',
          [artifact.semesterId],
        );
        await customStatement(
          'INSERT INTO jw_semester_catalog (account_id, options_json, updated_at) VALUES (1, ?, ?) '
          'ON CONFLICT(account_id) DO UPDATE SET options_json = excluded.options_json, updated_at = excluded.updated_at',
          [catalog.encode(), committedAt.microsecondsSinceEpoch],
        );
        await _commitSchoolCredentials(ticket, committedAt);
        await customStatement(
          "UPDATE jw_jobs SET status = 'committed' WHERE job_id = ? AND status = 'active'",
          [ticket.stamp.jobId],
        );
        await _guard();
        await onCheckpoint?.call(JwImportCheckpoint.beforeCommit);
        await _requireCurrent(ticket, allowCommitted: true);
        await customStatement(
          'UPDATE agenda_state SET revision=revision+1 WHERE singleton=1',
        );
        await agent._commitSourceAction(
          ticket,
          artifact.courseCount + artifact.examCount,
        );
        return JwImportReceipt(
          operationId: ticket.stamp.jobId,
          courseCount: artifact.courseCount,
          examCount: artifact.examCount,
          replayed: false,
          permit: JwClaimPermit(partition: artifact.partition, accountId: 1),
        );
      });
      succeeded = true;
      if (!receipt.replayed) {
        localCalendar._signal(
          (await localCalendar._agendaState()).read<int>('revision'),
        );
        agent._signal();
      }
      if (!receipt.replayed &&
          ticket._saveCredential &&
          ticket._pendingCredential != null) {
        _credentialChanges.add(true);
      }
      return receipt;
    } finally {
      _firstWriteCheckpoints.remove(ticket.stamp.jobId);
      if (succeeded) ticket._revokeSecrets();
    }
  });

  void _validateArtifact(JwJobTicket ticket, JwCollectedArtifact artifact) {
    if (!_sameStamp(ticket.stamp, artifact.stamp) ||
        artifact.sourceKey != jwSourceKey ||
        artifact.contractVersion != jwContractVersion ||
        !artifact.collectedAtUtc.isUtc ||
        artifact.semesterId <= 0 ||
        artifact.session <= 0 ||
        artifact.document <= 0 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(artifact.contentFingerprint)) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    _validatePartitionForTicket(ticket, artifact.partition);
    if (artifact.events.length > 10000) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    final seen = <String>{};
    for (final event in artifact.events) {
      if (event.externalId.isEmpty ||
          event.externalId.length > 160 ||
          event.title.trim().isEmpty ||
          event.title.length > 300 ||
          event.title.trim() != event.title ||
          event.academicDetails == null ||
          !event.startsAtUtc.isUtc ||
          !event.endsAtUtc.isUtc ||
          !event.startsAtUtc.isBefore(event.endsAtUtc) ||
          !seen.add(event.externalId)) {
        throw const AppFailure(FailureCode.invalidSnapshot);
      }
      if (event.kind == JwEventKind.course) {
        if (event.semesterId != artifact.semesterId) {
          throw const AppFailure(FailureCode.invalidSnapshot);
        }
      } else if (event.semesterId != null) {
        throw const AppFailure(FailureCode.invalidSnapshot);
      }
    }
    if (artifact.courseCount + artifact.examCount != artifact.events.length) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
  }

  Future<void> _applyProjection(
    JwJobTicket ticket,
    JwCollectedArtifact artifact,
  ) async {
    var checkpointDone = false;
    Future<void> noteWrite() async {
      if (checkpointDone) return;
      checkpointDone = true;
      await _checkpointAfterFirstWrite(ticket);
    }

    final incoming = {for (final event in artifact.events) event.externalId};
    final existingRows = await customSelect(
      'SELECT e.*, o.hidden FROM jw_events e '
      'JOIN jw_overlays o ON o.local_id = e.local_id',
    ).get();
    final byExternalId = <String, Map<String, Object?>>{};
    for (final row in existingRows) {
      final externalId = row.read<String>('external_id');
      final kindName = row.read<String>('kind');
      final kind = JwEventKind.values.where((value) => value.name == kindName);
      if (kind.length != 1) throw const AppFailure(FailureCode.storageFailed);
      final presenceName = row.read<String>('presence');
      final presence = JwPresence.values.where(
        (value) => value.name == presenceName,
      );
      if (presence.length != 1) {
        throw const AppFailure(FailureCode.storageFailed);
      }
      byExternalId[externalId] = {
        'local_id': row.read<int>('local_id'),
        'external_id': externalId,
        'kind': kind.single,
        'semester_id': row.read<int?>('semester_id'),
        'title': row.read<String>('title'),
        'academic_json': row.read<String?>('academic_json'),
        'starts_at': row.read<int>('starts_at'),
        'ends_at': row.read<int>('ends_at'),
        'presence': presence.single,
        'hidden': row.read<int>('hidden'),
        'version': row.read<int>('version'),
      };
    }

    for (final value in byExternalId.values) {
      final event = value;
      if (incoming.contains(event['external_id'])) continue;
      final eventKind = event['kind'] as JwEventKind;
      final isSelectedCourse =
          eventKind == JwEventKind.course &&
          event['semester_id'] == artifact.semesterId;
      final desired = isSelectedCourse
          ? JwPresence.missingWithinScope
          : JwPresence.outsideScope;
      if (event['presence'] != desired) {
        await customStatement(
          'UPDATE jw_events SET presence = ?, version = version + 1 WHERE local_id = ?',
          [desired.name, event['local_id']],
        );
        event['presence'] = desired;
        event['version'] = (event['version'] as int) + 1;
        await noteWrite();
      }
    }

    for (final draft in artifact.events) {
      final old = byExternalId[draft.externalId];
      final desiredPresence = JwPresence.observed;
      final startsAt = draft.startsAtUtc.microsecondsSinceEpoch;
      final endsAt = draft.endsAtUtc.microsecondsSinceEpoch;
      final academicJson = jsonEncode(draft.academicDetails!.toMap());
      if (old == null) {
        await customStatement(
          'INSERT INTO jw_events '
          '(external_id, kind, semester_id, title, starts_at, ends_at, '
          'presence, academic_json, version) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)',
          [
            draft.externalId,
            draft.kind.name,
            draft.semesterId,
            draft.title,
            startsAt,
            endsAt,
            desiredPresence.name,
            academicJson,
          ],
        );
        await noteWrite();
        await customStatement(
          'INSERT INTO jw_overlays (local_id, hidden) '
          'SELECT local_id, 0 FROM jw_events WHERE external_id = ?',
          [draft.externalId],
        );
        continue;
      }
      final changed =
          old['kind'] != draft.kind ||
          old['semester_id'] != draft.semesterId ||
          old['title'] != draft.title ||
          old['academic_json'] != academicJson ||
          old['starts_at'] != startsAt ||
          old['ends_at'] != endsAt ||
          old['presence'] != desiredPresence;
      if (changed) {
        await customStatement(
          'UPDATE jw_events SET kind = ?, semester_id = ?, title = ?, '
          'starts_at = ?, ends_at = ?, presence = ?, academic_json = ?, version = version + 1 '
          'WHERE local_id = ?',
          [
            draft.kind.name,
            draft.semesterId,
            draft.title,
            startsAt,
            endsAt,
            desiredPresence.name,
            academicJson,
            old['local_id'],
          ],
        );
        old['kind'] = draft.kind;
        old['semester_id'] = draft.semesterId;
        old['title'] = draft.title;
        old['academic_json'] = academicJson;
        old['starts_at'] = startsAt;
        old['ends_at'] = endsAt;
        old['presence'] = desiredPresence;
        old['version'] = (old['version'] as int) + 1;
        await noteWrite();
      }
    }
  }

  Future<void> _checkpointAfterFirstWrite(JwJobTicket ticket) async {
    if (!_firstWriteCheckpoints.add(ticket.stamp.jobId)) return;
    try {
      await onCheckpoint?.call(JwImportCheckpoint.afterFirstWrite);
      await _requireCurrent(ticket);
    } on Object {
      _firstWriteCheckpoints.remove(ticket.stamp.jobId);
      rethrow;
    }
  }

  Future<void> revokePermits() => _serialized(() async {
    await transaction(() async {
      final state = await _state();
      _validateOwner(state.read<String>('owner_id'));
      final activeJobId = state.read<String?>('active_job_id');
      if (activeJobId != null) {
        await customStatement(
          "UPDATE jw_jobs SET status = 'cancelled' "
          "WHERE job_id = ? AND status = 'active'",
          [activeJobId],
        );
      }
      await customStatement('DELETE FROM jw_permits');
      await customStatement(
        'UPDATE jw_state SET generation = generation + 1, active_job_id = NULL '
        'WHERE singleton = 1',
      );
      await _guard();
    });
    for (final ticket in _tickets.values) {
      ticket._credentialsRevoked = true;
      ticket._revokeSecrets();
    }
    _tickets.clear();
  });

  Future<JwLocalWriteReceipt> setHidden(JwHiddenCommand command) => _serialized(
    () => transaction(() async {
      if (!RegExp(r'^jw-local-[0-9a-f]{32}$').hasMatch(command.operationId) ||
          command.localId <= 0 ||
          command.expectedVersion <= 0 ||
          command.resetEpoch < 0 ||
          command.accountId != 1 ||
          !RegExp(r'^jw-owner-[0-9a-f]{32}$').hasMatch(command.ownerId)) {
        throw const AppFailure(FailureCode.invalidSnapshot);
      }

      final state = await _state();
      final ownerId = state.read<String>('owner_id');
      _validateOwner(ownerId);
      if (command.ownerId != ownerId) {
        throw const AppFailure(FailureCode.ownershipLost);
      }
      if (command.resetEpoch != state.read<int>('reset_epoch')) {
        throw const AppFailure(FailureCode.staleResult);
      }
      final account = await _account();
      if (account == null) {
        throw const JwIdentityException(JwIdentityFailure.identityUnverified);
      }
      _validateAccountCode(account.read<String>('expected_account_code'));

      final intentFingerprint = fingerprint([
        'jw-hidden-command-v1',
        command.ownerId,
        command.accountId,
        command.resetEpoch,
        command.localId,
        command.expectedVersion,
        command.hidden,
      ]);
      final priorReceipt = await customSelect(
        'SELECT fingerprint, result_version, hidden '
        'FROM jw_local_receipts WHERE operation_id = ?',
        variables: [Variable.withString(command.operationId)],
      ).getSingleOrNull();
      if (priorReceipt != null) {
        final priorFingerprint = priorReceipt.read<String>('fingerprint');
        final priorVersion = priorReceipt.read<int>('result_version');
        final priorHidden = priorReceipt.read<int>('hidden');
        if (priorFingerprint != intentFingerprint) {
          throw const AppFailure(FailureCode.idempotencyConflict);
        }
        if (priorVersion <= 0 ||
            (priorVersion != command.expectedVersion &&
                priorVersion != command.expectedVersion + 1) ||
            priorHidden != 0 && priorHidden != 1 ||
            priorHidden != (command.hidden ? 1 : 0)) {
          throw const AppFailure(FailureCode.storageFailed);
        }
        await _guard();
        return JwLocalWriteReceipt(
          operationId: command.operationId,
          resultVersion: priorVersion,
          hidden: priorHidden != 0,
          replayed: true,
        );
      }

      final row = await customSelect(
        'SELECT e.version, e.kind, o.hidden FROM jw_events e '
        'JOIN jw_overlays o ON o.local_id = e.local_id WHERE e.local_id = ?',
        variables: [Variable.withInt(command.localId)],
      ).getSingleOrNull();
      if (row == null || row.read<int>('version') != command.expectedVersion) {
        throw const AppFailure(FailureCode.staleResult);
      }
      final kind = row.read<String>('kind');
      if (kind != JwEventKind.course.name && kind != JwEventKind.exam.name) {
        throw const AppFailure(FailureCode.storageFailed);
      }
      final currentHiddenValue = row.read<int>('hidden');
      if (currentHiddenValue != 0 && currentHiddenValue != 1) {
        throw const AppFailure(FailureCode.storageFailed);
      }
      final currentHidden = currentHiddenValue != 0;
      final resultVersion =
          command.expectedVersion + (currentHidden == command.hidden ? 0 : 1);
      if (currentHidden != command.hidden) {
        await customStatement(
          'UPDATE jw_overlays SET hidden = ? WHERE local_id = ? AND hidden = ?',
          [command.hidden ? 1 : 0, command.localId, currentHidden ? 1 : 0],
        );
        await customStatement(
          'UPDATE jw_events SET version = version + 1 '
          'WHERE local_id = ? AND version = ?',
          [command.localId, command.expectedVersion],
        );
      }
      final current = await customSelect(
        'SELECT e.version, o.hidden FROM jw_events e '
        'JOIN jw_overlays o ON o.local_id = e.local_id WHERE e.local_id = ?',
        variables: [Variable.withInt(command.localId)],
      ).getSingleOrNull();
      if (current == null ||
          current.read<int>('version') != resultVersion ||
          current.read<int>('hidden') != (command.hidden ? 1 : 0)) {
        throw const AppFailure(FailureCode.staleResult);
      }

      final committedAt = _clock.nowUtc;
      if (!committedAt.isUtc) {
        throw const AppFailure(FailureCode.storageFailed);
      }
      await customStatement(
        "INSERT INTO jw_audit (action, course_count, exam_count, committed_at) "
        "VALUES ('overlay', ?, ?, ?)",
        [
          kind == JwEventKind.course.name ? 1 : 0,
          kind == JwEventKind.exam.name ? 1 : 0,
          committedAt.microsecondsSinceEpoch,
        ],
      );
      await customStatement(
        'INSERT INTO jw_local_receipts '
        '(operation_id, fingerprint, result_version, hidden, committed_at) '
        'VALUES (?, ?, ?, ?, ?)',
        [
          command.operationId,
          intentFingerprint,
          resultVersion,
          command.hidden ? 1 : 0,
          committedAt.microsecondsSinceEpoch,
        ],
      );
      await _guard();
      return JwLocalWriteReceipt(
        operationId: command.operationId,
        resultVersion: resultVersion,
        hidden: command.hidden,
        replayed: false,
      );
    }),
  );

  @override
  Future<JwDataView> readView() => _serialized(() async {
    final state = await _state();
    _validateOwner(state.read<String>('owner_id'));
    final rows = await customSelect(
      'SELECT e.local_id, e.version, e.kind, e.semester_id, e.title, e.starts_at, e.ends_at, '
      'e.presence, e.academic_json, o.hidden FROM jw_events e '
      'JOIN jw_overlays o ON o.local_id = e.local_id '
      'ORDER BY e.starts_at, e.external_id, e.local_id',
    ).get();
    final courseCount = await _count(
      "SELECT COUNT(*) AS count FROM jw_events WHERE kind = 'course'",
    );
    final examCount = await _count(
      "SELECT COUNT(*) AS count FROM jw_events WHERE kind = 'exam'",
    );
    final account = await _account();
    if (account != null) {
      _validateAccountCode(account.read<String>('expected_account_code'));
    }
    final preferences = await customSelect(
      'SELECT semester_id FROM jw_preferences WHERE account_id = 1',
    ).getSingleOrNull();
    final remembered = preferences?.read<int>('semester_id');
    if (remembered != null &&
        (account == null || remembered <= 0 || remembered > 2147483647)) {
      throw const AppFailure(FailureCode.storageFailed);
    }
    final credentialSaved =
        await _count('SELECT COUNT(*) AS count FROM jw_credentials') != 0;
    if (credentialSaved && account == null) {
      throw const AppFailure(FailureCode.storageFailed);
    }
    final catalogRow = await customSelect(
      'SELECT options_json, updated_at FROM jw_semester_catalog WHERE account_id = 1',
    ).getSingleOrNull();
    List<JwSemesterOption> cachedSemesters = const [];
    DateTime? catalogUpdatedAt;
    if (catalogRow != null) {
      if (account == null) throw const AppFailure(FailureCode.storageFailed);
      try {
        cachedSemesters = JwSemesterCatalog.decode(
          catalogRow.read<String>('options_json'),
        ).options;
        catalogUpdatedAt = DateTime.fromMicrosecondsSinceEpoch(
          catalogRow.read<int>('updated_at'),
          isUtc: true,
        );
      } on Object {
        throw const AppFailure(FailureCode.storageFailed);
      }
    }
    return JwDataView(
      accountBound: account != null,
      courseCount: courseCount,
      examCount: examCount,
      importCount: await _count('SELECT COUNT(*) AS count FROM jw_imports'),
      auditCount: await _count('SELECT COUNT(*) AS count FROM jw_audit'),
      credentialSaved: credentialSaved,
      lastSemesterId: remembered,
      cachedSemesters: cachedSemesters,
      semesterCatalogUpdatedAtUtc: catalogUpdatedAt,
      events: rows.map((row) {
        final kind = JwEventKind.values.where(
          (value) => value.name == row.read<String>('kind'),
        );
        final presence = JwPresence.values.where(
          (value) => value.name == row.read<String>('presence'),
        );
        if (kind.length != 1 || presence.length != 1) {
          throw const AppFailure(FailureCode.storageFailed);
        }
        final semesterId = row.read<int?>('semester_id');
        if (kind.single == JwEventKind.course
            ? semesterId == null || semesterId <= 0 || semesterId > 2147483647
            : semesterId != null) {
          throw const AppFailure(FailureCode.storageFailed);
        }
        return JwStoredEvent(
          localId: row.read<int>('local_id'),
          version: row.read<int>('version'),
          kind: kind.single,
          semesterId: semesterId,
          title: row.read<String>('title'),
          academicDetails: row.read<String?>('academic_json') == null
              ? null
              : JwAcademicDetails.decode(row.read<String>('academic_json')),
          startsAtUtc: DateTime.fromMicrosecondsSinceEpoch(
            row.read<int>('starts_at'),
            isUtc: true,
          ),
          endsAtUtc: DateTime.fromMicrosecondsSinceEpoch(
            row.read<int>('ends_at'),
            isUtc: true,
          ),
          presence: presence.single,
          hidden: row.read<int>('hidden') != 0,
        );
      }).toList(),
    );
  });

  Future<int> _count(String sql) async =>
      (await customSelect(sql).getSingle()).read<int>('count');

  String _normalizeAccountCode(String value) {
    final normalized = value.trim().toUpperCase();
    if (!RegExp(r'^[A-Z0-9]{5,24}$').hasMatch(normalized)) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    return normalized;
  }

  void _validateAccountCode(String value) {
    if (!RegExp(r'^[A-Z0-9]{5,24}$').hasMatch(value)) {
      throw const AppFailure(FailureCode.storageFailed);
    }
  }

  bool _ticketMatchesJob(JwJobTicket ticket, QueryRow job) {
    final stamp = ticket.stamp;
    return stamp.jobId == 'jw-${stamp.resetEpoch}-${stamp.generation}' &&
        job.read<int>('generation') == stamp.generation &&
        job.read<int>('reset_epoch') == stamp.resetEpoch &&
        job.read<int?>('account_id') == stamp.accountId;
  }

  JwPartitionRef _decodePartition(String encoded) {
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map<String, dynamic>) {
        throw const AppFailure(FailureCode.storageFailed);
      }
      return JwPartitionRef.decode(decoded);
    } on AppFailure {
      throw const AppFailure(FailureCode.storageFailed);
    } on Object {
      throw const AppFailure(FailureCode.storageFailed);
    }
  }

  bool _sameStamp(JwWorkStamp left, JwWorkStamp right) =>
      left.jobId == right.jobId &&
      left.ownerId == right.ownerId &&
      left.generation == right.generation &&
      left.resetEpoch == right.resetEpoch &&
      left.accountId == right.accountId;

  @override
  Future<void> close() => _closeFuture ??= _drainAndClose();

  Future<void> _drainAndClose() async {
    _closing = true;
    publicStore._invalidateMemory();
    localCalendar._invalidateMemory();
    for (final ticket in [..._tickets.values, ..._youngTickets.values]) {
      ticket._credentialsRevoked = true;
      ticket._secretLease?.revoke();
    }
    await _queue;
    for (final ticket in [..._tickets.values, ..._youngTickets.values]) {
      ticket._revokeSecrets();
    }
    _youngTickets.clear();
    _youngFirstWriteCheckpoints.clear();
    await _credentialChanges.close();
    await localCalendar._changes.close();
    await applicationSettings._close();
    await agent.close();
    await super.close();
  }

  static String _randomHexId(String prefix) {
    final random = Random.secure();
    final hex = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return '$prefix$hex';
  }

  static const _catalogSchema = [
    '''CREATE TABLE jw_semester_catalog (
      account_id INTEGER PRIMARY KEY CHECK(account_id = 1),
      options_json TEXT NOT NULL CHECK(length(options_json) <= 131072),
      updated_at INTEGER NOT NULL
    )''',
  ];

  static const _credentialSchema = [
    '''CREATE TABLE jw_credentials (
      account_id INTEGER PRIMARY KEY CHECK(account_id = 1),
      mechanism TEXT NOT NULL,
      ciphertext BLOB NOT NULL
    )''',
    '''CREATE TABLE jw_preferences (
      account_id INTEGER PRIMARY KEY CHECK(account_id = 1),
      semester_id INTEGER NOT NULL CHECK(semester_id > 0 AND semester_id <= 2147483647)
    )''',
    '''CREATE TABLE jw_credential_audit (
      audit_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
      action TEXT NOT NULL CHECK(action IN ('saved','deleted')),
      committed_at INTEGER NOT NULL
    )''',
  ];

  static const _schema = [
    '''CREATE TABLE jw_state (
      singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
      owner_id TEXT NOT NULL, generation INTEGER NOT NULL,
      reset_epoch INTEGER NOT NULL, active_job_id TEXT
    )''',
    '''CREATE TABLE jw_account (
      account_id INTEGER PRIMARY KEY CHECK(account_id = 1),
      expected_account_code TEXT NOT NULL
    )''',
    '''CREATE TABLE jw_jobs (
      job_id TEXT PRIMARY KEY, generation INTEGER NOT NULL,
      reset_epoch INTEGER NOT NULL, account_id INTEGER,
      status TEXT NOT NULL CHECK(status IN
        ('active','cancelled','abandoned','failed','committed')),
      staged_partition TEXT
    )''',
    '''CREATE TABLE jw_events (
      local_id INTEGER PRIMARY KEY AUTOINCREMENT,
      external_id TEXT NOT NULL UNIQUE,
      kind TEXT NOT NULL CHECK(kind IN ('course','exam')),
      semester_id INTEGER,
      title TEXT NOT NULL,
      academic_json TEXT CHECK(academic_json IS NULL OR length(academic_json)<=24576),
      starts_at INTEGER NOT NULL,
      ends_at INTEGER NOT NULL,
      presence TEXT NOT NULL CHECK(presence IN
        ('observed','outsideScope','missingWithinScope')),
      version INTEGER NOT NULL CHECK(version > 0),
      CHECK(starts_at < ends_at),
      CHECK((kind = 'course' AND semester_id IS NOT NULL) OR
        (kind = 'exam' AND semester_id IS NULL))
    )''',
    '''CREATE TABLE jw_overlays (
      local_id INTEGER PRIMARY KEY,
      hidden INTEGER NOT NULL CHECK(hidden IN (0,1))
    )''',
    '''CREATE TABLE jw_imports (
      import_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
      operation_id TEXT NOT NULL UNIQUE,
      job_id TEXT NOT NULL UNIQUE,
      content_fingerprint TEXT NOT NULL,
      partition_metadata TEXT NOT NULL,
      course_count INTEGER NOT NULL,
      exam_count INTEGER NOT NULL,
      account_id INTEGER NOT NULL CHECK(account_id = 1),
      committed_at INTEGER NOT NULL
    )''',
    '''CREATE TABLE jw_audit (
      audit_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
      action TEXT NOT NULL CHECK(action IN ('import','overlay')),
      course_count INTEGER NOT NULL,
      exam_count INTEGER NOT NULL,
      committed_at INTEGER NOT NULL
    )''',
    '''CREATE TABLE jw_permits (
      partition_id TEXT PRIMARY KEY,
      partition_metadata TEXT NOT NULL,
      account_id INTEGER NOT NULL CHECK(account_id = 1)
    )''',
    '''CREATE TABLE jw_local_receipts (
      operation_id TEXT PRIMARY KEY,
      fingerprint TEXT NOT NULL,
      result_version INTEGER NOT NULL CHECK(result_version > 0),
      hidden INTEGER NOT NULL CHECK(hidden IN (0,1)),
      committed_at INTEGER NOT NULL
    )''',
  ];
}
