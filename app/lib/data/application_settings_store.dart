part of 'jw_store.dart';

/// Only this store defines the confirmed physical SQL deletion scopes.
final class ApplicationSettingsStore implements ApplicationSettingsDataPort {
  ApplicationSettingsStore._(this._db);
  final JwStore _db;
  final _changes = StreamController<int>.broadcast();
  final Map<String, String> _requests = {};
  bool _closed = false;

  static const schema = <String>[
    '''CREATE TABLE app_settings (
      singleton INTEGER PRIMARY KEY CHECK(singleton=1),
      revision INTEGER NOT NULL CHECK(revision>0),
      calendar_view TEXT NOT NULL CHECK(calendar_view IN ('day','week')),
      include_inactive INTEGER NOT NULL CHECK(include_inactive IN (0,1)))''',
    "INSERT INTO app_settings VALUES (1,1,'week',0)",
    '''CREATE TABLE app_maintenance_intent (
      singleton INTEGER PRIMARY KEY CHECK(singleton=1),
      operation_id TEXT NOT NULL UNIQUE, scope_version INTEGER NOT NULL CHECK(scope_version=1),
      kind TEXT NOT NULL CHECK(kind IN ('agenda','reset')), fingerprint TEXT NOT NULL,
      owner TEXT NOT NULL, original_reset INTEGER NOT NULL CHECK(original_reset>=0),
      original_agenda INTEGER NOT NULL CHECK(original_agenda>=0),
      original_revision INTEGER NOT NULL CHECK(original_revision>0),
      target_reset INTEGER NOT NULL CHECK(target_reset>=0),
      target_agenda INTEGER NOT NULL CHECK(target_agenda>=0),
      requested_at INTEGER NOT NULL)''',
    '''CREATE TABLE app_settings_receipts (
      operation_id TEXT PRIMARY KEY, action TEXT NOT NULL CHECK(action IN ('preferences','agenda','reset')),
      fingerprint TEXT NOT NULL, result_reset INTEGER NOT NULL CHECK(result_reset>=0),
      result_agenda INTEGER NOT NULL CHECK(result_agenda>=0),
      result_revision INTEGER NOT NULL CHECK(result_revision>0), committed_at INTEGER NOT NULL)''',
    '''CREATE TABLE app_settings_audit (
      sequence INTEGER PRIMARY KEY AUTOINCREMENT,
      action TEXT NOT NULL CHECK(action IN ('preferences','agenda','reset')),
      item_count INTEGER NOT NULL CHECK(item_count>=0), committed_at INTEGER NOT NULL)''',
  ];

  @override
  Stream<int> get changes => _changes.stream;

  Future<T> _serial<T>(Future<T> Function() action) async {
    if (_closed) throw const SettingsFailure(SettingsFailureCode.closed);
    try {
      return await _db._serialized(action);
    } on AppFailure catch (error) {
      throw SettingsFailure(switch (error.code) {
        FailureCode.closed => SettingsFailureCode.closed,
        FailureCode.busy => SettingsFailureCode.busy,
        FailureCode.cleanupPending => SettingsFailureCode.cleanupPending,
        FailureCode.ownershipLost ||
        FailureCode.ownerConflict => SettingsFailureCode.ownershipLost,
        _ => SettingsFailureCode.storageFailed,
      });
    }
  }

  Future<SettingsContext> _context() async {
    final canonical = await _db._state();
    final agenda = await _db.localCalendar._agendaState();
    final settings = await _db
        .customSelect('SELECT * FROM app_settings WHERE singleton=1')
        .getSingle();
    final owner = canonical.read<String>('owner_id');
    _db._validateOwner(owner);
    final context = SettingsContext(
      owner: owner,
      resetEpoch: canonical.read<int>('reset_epoch'),
      agendaEpoch: agenda.read<int>('epoch'),
      revision: settings.read<int>('revision'),
    );
    if (context.resetEpoch < 0 ||
        context.agendaEpoch < 0 ||
        context.revision < 1) {
      throw const SettingsFailure(SettingsFailureCode.invalidIntent);
    }
    return context;
  }

  Future<void> _requireContext(SettingsContext expected) async {
    await _db._guard();
    if (await _context() != expected) {
      throw const SettingsFailure(SettingsFailureCode.staleContext);
    }
  }

  String _maintenanceFingerprint(
    SettingsContext context,
    MaintenanceKind kind,
  ) => fingerprint([
    'maintenance',
    1,
    context.owner,
    context.resetEpoch,
    context.agendaEpoch,
    context.revision,
    kind.name,
  ]);

  void _operation(String id) {
    if (!RegExp(r'^(maintenance|preferences)-[0-9a-f]{32}$').hasMatch(id)) {
      throw const SettingsFailure(SettingsFailureCode.invalidIntent);
    }
  }

  Future<MaintenanceIntent?> _pending() async {
    final row = await _db
        .customSelect('SELECT * FROM app_maintenance_intent WHERE singleton=1')
        .getSingleOrNull();
    final barrier = (await _db.localCalendar._agendaState()).read<int>(
      'maintenance',
    );
    if (row == null) {
      if (barrier != 0) {
        throw const SettingsFailure(SettingsFailureCode.invalidIntent);
      }
      return null;
    }
    if (barrier != 1 || row.read<int>('scope_version') != 1) {
      throw const SettingsFailure(SettingsFailureCode.invalidIntent);
    }
    final current = await _context();
    final original = SettingsContext(
      owner: row.read<String>('owner'),
      resetEpoch: row.read<int>('original_reset'),
      agendaEpoch: row.read<int>('original_agenda'),
      revision: row.read<int>('original_revision'),
    );
    final kindName = row.read<String>('kind');
    final kinds = MaintenanceKind.values.where((kind) => kind.name == kindName);
    if (kinds.length != 1) {
      throw const SettingsFailure(SettingsFailureCode.invalidIntent);
    }
    final kind = kinds.single;
    final request = MaintenanceRequest(
      operationId: row.read<String>('operation_id'),
      context: original,
      kind: kind,
      intentFingerprint: row.read<String>('fingerprint'),
    );
    _operation(request.operationId);
    if (!request.operationId.startsWith('maintenance-') ||
        original.owner != current.owner ||
        original.resetEpoch < 0 ||
        original.agendaEpoch < 0 ||
        original.revision < 1 ||
        row.read<int>('target_reset') !=
            original.resetEpoch + (kind == MaintenanceKind.reset ? 1 : 0) ||
        row.read<int>('target_agenda') != original.agendaEpoch + 1 ||
        row.read<int>('target_reset') != current.resetEpoch ||
        row.read<int>('target_agenda') != current.agendaEpoch ||
        current.revision != original.revision ||
        request.intentFingerprint != _maintenanceFingerprint(original, kind)) {
      throw const SettingsFailure(SettingsFailureCode.invalidIntent);
    }
    return MaintenanceIntent(request: request, targetContext: current);
  }

  @override
  Future<MaintenanceIntent?> bootstrapMaintenance() => _serial(() async {
    // Ownership-only metadata bootstrap. No ordinary initialize/guard bypass.
    await _context();
    return _pending();
  });

  @override
  Future<SettingsSnapshot> inspectSettings() => _serial(
    () => _db.transaction(() async {
      final context = await _context();
      final prefs = await _db
          .customSelect('SELECT * FROM app_settings WHERE singleton=1')
          .getSingle();
      return SettingsSnapshot(
        context: context,
        preferences: DisplayPreferences(
          calendarView: DefaultCalendarView.values.byName(
            prefs.read<String>('calendar_view'),
          ),
          includeInactive: prefs.read<int>('include_inactive') == 1,
        ),
        counts: LocalDataCounts(
          jwCourses: await _db._count(
            "SELECT COUNT(*) AS count FROM jw_events WHERE kind='course'",
          ),
          jwExams: await _db._count(
            "SELECT COUNT(*) AS count FROM jw_events WHERE kind='exam'",
          ),
          young: await _db._count('SELECT COUNT(*) AS count FROM young_events'),
          personal: await _db._count(
            'SELECT COUNT(*) AS count FROM personal_events',
          ),
          tasks: await _db._count('SELECT COUNT(*) AS count FROM local_tasks'),
          blocks: await _db._count(
            'SELECT COUNT(*) AS count FROM local_plan_blocks',
          ),
          materials: await _db._count(
            'SELECT COUNT(*) AS count FROM knowledge_materials',
          ),
        ),
        accountBound: await _db._account() != null,
        credentialSaved:
            await _db._count('SELECT COUNT(*) AS count FROM jw_credentials') >
            0,
        icourseConsent:
            (await _db.publicStore._knowledgeState()).read<int>(
              'icourse_consent',
            ) ==
            1,
      );
    }),
  );

  Future<SettingsWriteReceipt?> _receipt(
    String id,
    String action,
    String digest,
  ) async {
    final row = await _db
        .customSelect(
          'SELECT * FROM app_settings_receipts WHERE operation_id=?',
          variables: [Variable.withString(id)],
        )
        .getSingleOrNull();
    if (row == null) return null;
    if (row.read<String>('action') != action ||
        row.read<String>('fingerprint') != digest) {
      throw const SettingsFailure(SettingsFailureCode.invalidIntent);
    }
    final owner = (await _context()).owner;
    return SettingsWriteReceipt(
      operationId: id,
      context: SettingsContext(
        owner: owner,
        resetEpoch: row.read<int>('result_reset'),
        agendaEpoch: row.read<int>('result_agenda'),
        revision: row.read<int>('result_revision'),
      ),
      replayed: true,
    );
  }

  Future<SettingsWriteReceipt> _record(
    String id,
    String action,
    String digest,
    int count,
  ) async {
    final context = await _context();
    final now = _db._clock.nowUtc.microsecondsSinceEpoch;
    await _db.customStatement(
      'INSERT INTO app_settings_receipts VALUES (?,?,?,?,?,?,?)',
      [
        id,
        action,
        digest,
        context.resetEpoch,
        context.agendaEpoch,
        context.revision,
        now,
      ],
    );
    await _db.customStatement(
      'INSERT INTO app_settings_audit(action,item_count,committed_at) VALUES (?,?,?)',
      [action, count, now],
    );
    return SettingsWriteReceipt(operationId: id, context: context);
  }

  @override
  Future<SettingsWriteReceipt> savePreferences(
    PreferencesWrite write,
  ) => _serial(() async {
    _operation(write.operationId);
    if (!write.operationId.startsWith('preferences-')) {
      throw const SettingsFailure(SettingsFailureCode.invalidIntent);
    }
    final digest = fingerprint([
      'preferences',
      1,
      write.context.owner,
      write.context.resetEpoch,
      write.context.agendaEpoch,
      write.context.revision,
      write.preferences.calendarView.name,
      write.preferences.includeInactive,
    ]);
    final receipt = await _db.transaction(() async {
      await _db._guard();
      final prior = await _receipt(write.operationId, 'preferences', digest);
      if (prior != null) return prior;
      await _requireContext(write.context);
      await _db.customStatement(
        'UPDATE app_settings SET revision=revision+1,calendar_view=?,include_inactive=? WHERE singleton=1',
        [
          write.preferences.calendarView.name,
          write.preferences.includeInactive ? 1 : 0,
        ],
      );
      await _db.onSettingsCheckpoint?.call();
      await _db._guard();
      return _record(write.operationId, 'preferences', digest, 0);
    });
    _signal(receipt.context.revision);
    return receipt;
  });

  @override
  Future<MaintenanceRequest> prepareMaintenance(
    SettingsContext context,
    MaintenanceKind kind, {
    required bool confirmed,
  }) => _serial(() async {
    if (!confirmed) {
      throw const SettingsFailure(SettingsFailureCode.confirmationRequired);
    }
    await _requireContext(context);
    if (await _pending() != null) {
      throw const SettingsFailure(SettingsFailureCode.busy);
    }
    final request = MaintenanceRequest(
      operationId: JwStore._randomHexId('maintenance-'),
      context: context,
      kind: kind,
      intentFingerprint: _maintenanceFingerprint(context, kind),
    );
    _requests[request.operationId] = request.intentFingerprint;
    return request;
  });

  @override
  Future<MaintenanceIntent> beginMaintenance(MaintenanceRequest request) async {
    _operation(request.operationId);
    // Reject queued/late local writes immediately; already-running SQL drains.
    final previousBarrier = _db.localCalendar._maintenanceRequested;
    _db.localCalendar._maintenanceRequested = true;
    try {
      final intent = await _serial(
        () => _db.transaction(() async {
          final pending = await _pending();
          if (pending != null) {
            if (pending.request.operationId == request.operationId &&
                pending.request.intentFingerprint ==
                    request.intentFingerprint) {
              return pending;
            }
            throw const SettingsFailure(SettingsFailureCode.busy);
          }
          if (_requests[request.operationId] != request.intentFingerprint ||
              request.intentFingerprint !=
                  _maintenanceFingerprint(request.context, request.kind) ||
              await _context() != request.context) {
            throw const SettingsFailure(SettingsFailureCode.staleContext);
          }
          // A knowledge batch owns no source lease; admission rejects its work.
          if (_db.publicStore._load != null) {
            throw const SettingsFailure(SettingsFailureCode.busy);
          }
          final current = await _db._state();
          final young = await _db._youngState();
          final public = await _db
              .customSelect(
                'SELECT active_job FROM public_sources WHERE active_job IS NOT NULL',
              )
              .get();
          if (current.read<String?>('active_job_id') != null ||
              young.read<String?>('active_job_id') != null ||
              public.isNotEmpty) {
            throw const SettingsFailure(SettingsFailureCode.busy);
          }
          await _db.customStatement(
            'UPDATE agenda_state SET maintenance=1,epoch=epoch+1,revision=revision+1 WHERE singleton=1',
          );
          await _db.customStatement(
            'UPDATE jw_state SET generation=generation+1,active_job_id=NULL,reset_epoch=reset_epoch+? WHERE singleton=1',
            [request.kind == MaintenanceKind.reset ? 1 : 0],
          );
          await _db.customStatement(
            'UPDATE young_state SET generation=generation+1,active_job_id=NULL WHERE singleton=1',
          );
          await _db.customStatement(
            'UPDATE public_sources SET generation=generation+1,active_job=NULL',
          );
          if (request.kind == MaintenanceKind.reset) {
            await _db.customStatement('DELETE FROM jw_permits');
            await _db.customStatement('DELETE FROM young_permits');
            await _db.customStatement(
              'UPDATE knowledge_state SET epoch=epoch+1,sequence=sequence+1 WHERE singleton=1',
            );
          }
          final target = await _context();
          await _db.customStatement(
            'INSERT INTO app_maintenance_intent VALUES (1,?,1,?,?,?,?,?,?,?,?,?)',
            [
              request.operationId,
              request.kind.name,
              request.intentFingerprint,
              request.context.owner,
              request.context.resetEpoch,
              request.context.agendaEpoch,
              request.context.revision,
              target.resetEpoch,
              target.agendaEpoch,
              _db._clock.nowUtc.microsecondsSinceEpoch,
            ],
          );
          await _db.onSettingsCheckpoint?.call();
          _db._ownership.ensureHeld();
          return MaintenanceIntent(request: request, targetContext: target);
        }),
      );
      _requests.clear();
      _invalidateCapabilities();
      _db.localCalendar._signal(
        (await _db.localCalendar._agendaState()).read<int>('revision'),
      );
      _signal(intent.targetContext.revision);
      return intent;
    } catch (error) {
      // Preserve a durable barrier if it exists; never infer a deletion scope.
      _db.localCalendar._maintenanceRequested = previousBarrier;
      rethrow;
    }
  }

  void _invalidateCapabilities() {
    for (final ticket in [
      ..._db._tickets.values,
      ..._db._youngTickets.values,
    ]) {
      ticket._credentialsRevoked = true;
      ticket._revokeSecrets();
    }
    _db._tickets.clear();
    _db._youngTickets.clear();
    _db._firstWriteCheckpoints.clear();
    _db._youngFirstWriteCheckpoints.clear();
    for (final ticket in _db.publicStore._jobs.values) {
      ticket.cancelled = true;
    }
    _db.publicStore._jobs.clear();
    _db.publicStore._references.clear();
    _db.publicStore._pages.clear();
    _db.publicStore._reads.clear();
    _db.localCalendar._prepared.clear();
  }

  static const _agendaTables = <String>[
    'agenda_undo',
    'agenda_relations',
    'personal_occurrence_overrides',
    'local_plan_blocks',
    'local_tasks',
    'personal_events',
    'agenda_receipts',
    'agenda_audit',
    'jw_overlays',
    'jw_events',
    'jw_imports',
    'jw_local_receipts',
    'jw_audit',
    'jw_jobs',
    'young_overlays',
    'young_events',
    'young_receipts',
    'young_local_receipts',
    'young_audit',
    'young_jobs',
  ];
  static const _resetTables = <String>[
    'jw_permits',
    'young_permits',
    'jw_credentials',
    'jw_credential_audit',
    'jw_preferences',
    'jw_semester_catalog',
    'young_preferences',
    'knowledge_sections',
    'knowledge_materials',
    'knowledge_load_items',
    'knowledge_loads',
    'knowledge_audit',
    'jw_account',
    'app_settings_receipts',
    'app_settings_audit',
  ];

  @override
  Future<SettingsWriteReceipt> completeMaintenance(
    MaintenanceIntent intent,
  ) => _serial(() async {
    final request = intent.request;
    _operation(request.operationId);
    if (request.intentFingerprint !=
        _maintenanceFingerprint(request.context, request.kind)) {
      throw const SettingsFailure(SettingsFailureCode.invalidIntent);
    }
    var agendaRevision = 0;
    final receipt = await _db.transaction(() async {
      final pending = await _pending();
      final prior = await _receipt(
        request.operationId,
        request.kind.name,
        request.intentFingerprint,
      );
      if (prior != null) {
        if (pending != null) {
          throw const SettingsFailure(SettingsFailureCode.busy);
        }
        return prior;
      }
      if (pending == null ||
          pending.request.operationId != request.operationId ||
          pending.request.intentFingerprint != request.intentFingerprint ||
          pending.request.kind != request.kind ||
          pending.request.context != request.context ||
          pending.targetContext != intent.targetContext) {
        throw const SettingsFailure(SettingsFailureCode.staleContext);
      }
      var count = 0;
      for (final table in _agendaTables) {
        count += await _db._count('SELECT COUNT(*) AS count FROM $table');
        await _db.customStatement('DELETE FROM $table');
      }
      if (request.kind == MaintenanceKind.reset) {
        for (final table in _resetTables) {
          await _db.customStatement('DELETE FROM $table');
        }
        await _db.customStatement(
          "UPDATE app_settings SET calendar_view='week',include_inactive=0 WHERE singleton=1",
        );
        await _db.customStatement(
          'UPDATE knowledge_state SET sequence=sequence+1,edition=NULL,load_count=0,icourse_consent=0 WHERE singleton=1',
        );
        _db.publicStore._load?.cancelled = true;
      }
      await _db.customStatement(
        'UPDATE app_settings SET revision=revision+1 WHERE singleton=1',
      );
      await _db.customStatement(
        'UPDATE agenda_state SET maintenance=0,revision=revision+1 WHERE singleton=1',
      );
      await _db.customStatement('DELETE FROM app_maintenance_intent');
      await _db.onSettingsCheckpoint?.call();
      _db._ownership.ensureHeld();
      agendaRevision = (await _db.localCalendar._agendaState()).read<int>(
        'revision',
      );
      return _record(
        request.operationId,
        request.kind.name,
        request.intentFingerprint,
        count,
      );
    });
    if (receipt.replayed) {
      return receipt;
    }
    _db.localCalendar._maintenanceRequested = false;
    _invalidateCapabilities();
    _db.localCalendar._signal(agendaRevision);
    _signal(receipt.context.revision);
    return receipt;
  });

  void _signal(int revision) {
    if (!_closed) _changes.add(revision);
  }

  Future<void> _close() async {
    _closed = true;
    _requests.clear();
    await _changes.close();
  }
}
