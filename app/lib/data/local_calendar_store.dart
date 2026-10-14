part of 'jw_store.dart';

/// Local business uses the same database, transaction queue and owner as the
/// accepted school/knowledge stores. It never starts a source or reads secrets.
final class LocalCalendarStore
    implements
        LocalCalendarPort,
        LocalTaskPort,
        CalendarReadGuardPort,
        AgentLocalPlanPort,
        AgentLocalPermissionPort {
  LocalCalendarStore._(this._db);
  final JwStore _db;
  final _changes = StreamController<int>.broadcast();
  final _prepared = <String, String>{};
  final _agentPlans = <String, _PreparedAgentPlan>{};
  final _agentApprovals = Expando<_PreparedAgentPlan>();
  bool _closed = false;
  bool _maintenanceRequested = false;
  static const _projection = CalendarProjection();

  static const taskSchema = _taskSchema;

  @override
  Future<(CalendarContext, int)> readPlanContext() => _serial(
    () async =>
        (await _context(), (await _agendaState()).read<int>('revision')),
  );
  @override
  Future<AgentLocalPlan> prepareLocalPlan(
    AgentRunTicket ticket,
    CalendarContext context,
    int revision,
    List<AgentLocalChange> changes, {
    bool requireFree = false,
    int? preferencesRevision,
  }) => _prepareAgentPlan(
    ticket,
    context,
    revision,
    changes,
    requireFree: requireFree,
    preferencesRevision: preferencesRevision,
  );
  @override
  Future<AgentPlanApproval> approveLocalPlan(AgentLocalPlan plan) =>
      _approveAgentPlan(plan);
  @override
  Future<AgentPlanApproval?> authorizeLocalPlan(
    AgentLocalPlan plan, {
    required AgentAuthorizationMode mode,
    bool remember = false,
  }) => _authorizeAgentPlan(plan, mode: mode, remember: remember);
  @override
  Future<void> rejectLocalPlan(AgentLocalPlan plan) => _rejectAgentPlan(plan);
  @override
  Future<AgentLocalPlanReceipt> commitLocalPlan(AgentPlanApproval approval) =>
      _commitAgentPlan(approval);
  @override
  void revokeLocalPlans(AgentRunTicket ticket) {
    if (identical(_db.agent._tickets[ticket.runId], ticket)) {
      _db.agent._revokedActionRuns.add(ticket.runId);
    }
    for (final prepared in _agentPlans.values) {
      if (identical(prepared.plan.ticket, ticket)) prepared.revoked = true;
    }
  }

  @override
  Future<TaskWindow> queryTasks(TaskQuery query) => _queryTasks(query);
  @override
  Future<TaskDetail> taskDetail(TaskReference reference) =>
      _taskDetail(reference);
  @override
  Future<CalendarUndoView> queryUndo(CalendarContext context) =>
      _queryUndo(context);

  @override
  Stream<int> get changes => _changes.stream;

  @override
  Future<void> ensureCalendarRead(CalendarContext context, int revision) =>
      _serial(() async {
        await _guard(context);
        if ((await _agendaState()).read<int>('revision') != revision) {
          throw const CalendarFailure(CalendarFailureCode.staleReference);
        }
        _db._ownership.ensureHeld();
      });

  static const _relationDefinition = '''(
      local_id INTEGER PRIMARY KEY AUTOINCREMENT,
      left_identity TEXT NOT NULL, right_identity TEXT NOT NULL,
      kind TEXT NOT NULL CHECK(kind IN ('conflict','notConflict','legacyUndecided')),
      note TEXT NOT NULL CHECK(length(note)<=4000),
      version INTEGER NOT NULL CHECK(version>0),
      UNIQUE(left_identity,right_identity)
    )''';

  static const schema = [
    '''CREATE TABLE agenda_state (
      singleton INTEGER PRIMARY KEY CHECK(singleton=1),
      epoch INTEGER NOT NULL CHECK(epoch>=0),
      revision INTEGER NOT NULL CHECK(revision>=0),
      maintenance INTEGER NOT NULL CHECK(maintenance IN (0,1))
    )''',
    'INSERT INTO agenda_state VALUES (1,0,0,0)',
    '''CREATE TABLE personal_events (
      local_id INTEGER PRIMARY KEY AUTOINCREMENT,
      version INTEGER NOT NULL CHECK(version>0),
      draft_json TEXT NOT NULL CHECK(length(draft_json)<=32768),
      deleted INTEGER NOT NULL CHECK(deleted IN (0,1))
    )''',
    '''CREATE TABLE personal_occurrence_overrides (
      local_id INTEGER NOT NULL REFERENCES personal_events(local_id),
      ordinal INTEGER NOT NULL CHECK(ordinal>=0), replacement_json TEXT,
      completed INTEGER NOT NULL CHECK(completed IN (0,1)),
      skipped INTEGER NOT NULL CHECK(skipped IN (0,1)),
      PRIMARY KEY(local_id,ordinal)
    )''',
    'CREATE TABLE agenda_relations $_relationDefinition',
    '''CREATE TABLE agenda_receipts (
      operation_id TEXT PRIMARY KEY, intent_fingerprint TEXT NOT NULL,
      revision INTEGER NOT NULL CHECK(revision>0),
      target_json TEXT, relation_json TEXT, committed_at INTEGER NOT NULL
    )''',
    '''CREATE TABLE agenda_audit (
      sequence INTEGER PRIMARY KEY AUTOINCREMENT,
      action TEXT NOT NULL CHECK(action IN
        ('create','series','occurrence','state','delete','annotation','relation','remove-relation')),
      item_count INTEGER NOT NULL CHECK(item_count>=0), committed_at INTEGER NOT NULL
    )''',
    "ALTER TABLE jw_overlays ADD COLUMN note TEXT NOT NULL DEFAULT '' CHECK(length(note)<=4000)",
    "ALTER TABLE jw_overlays ADD COLUMN attendance TEXT NOT NULL DEFAULT 'undecided' CHECK(attendance IN ('undecided','attend','skip'))",
    "ALTER TABLE jw_overlays ADD COLUMN listening TEXT NOT NULL DEFAULT 'undecided' CHECK(listening IN ('undecided','listening','selfStudy'))",
    "ALTER TABLE young_overlays ADD COLUMN note TEXT NOT NULL DEFAULT '' CHECK(length(note)<=4000)",
    "ALTER TABLE young_overlays ADD COLUMN attendance TEXT NOT NULL DEFAULT 'undecided' CHECK(attendance IN ('undecided','attend','skip'))",
  ];

  static const upgradeFrom6 = [
    'CREATE TABLE agenda_relations_v7 $_relationDefinition',
    '''INSERT INTO agenda_relations_v7(local_id,left_identity,right_identity,kind,note,version)
       SELECT local_id,left_identity,right_identity,
       CASE kind WHEN 'coexist' THEN 'notConflict' WHEN 'related' THEN 'legacyUndecided' ELSE kind END,
       note,version FROM agenda_relations''',
    '''INSERT INTO sqlite_sequence(name,seq)
       SELECT 'agenda_relations_v7',COALESCE((SELECT seq FROM sqlite_sequence WHERE name='agenda_relations'),0)
       WHERE NOT EXISTS(SELECT 1 FROM sqlite_sequence WHERE name='agenda_relations_v7')''',
    '''UPDATE sqlite_sequence SET seq=MAX(seq,COALESCE((SELECT seq FROM sqlite_sequence WHERE name='agenda_relations'),0))
       WHERE name='agenda_relations_v7' ''',
    'DROP TABLE agenda_relations',
    'ALTER TABLE agenda_relations_v7 RENAME TO agenda_relations',
    'UPDATE agenda_state SET epoch=epoch+1,revision=revision+1 WHERE singleton=1',
  ];

  Future<T> _serial<T>(Future<T> Function() action) async {
    if (_closed) throw const CalendarFailure(CalendarFailureCode.closed);
    try {
      return await _db._serialized(action);
    } on AppFailure catch (error) {
      throw CalendarFailure(switch (error.code) {
        FailureCode.closed => CalendarFailureCode.closed,
        FailureCode.ownershipLost ||
        FailureCode.ownerConflict => CalendarFailureCode.ownershipLost,
        FailureCode.cleanupPending => CalendarFailureCode.maintenance,
        _ => CalendarFailureCode.storageFailed,
      });
    }
  }

  Future<QueryRow> _agendaState() => _db
      .customSelect('SELECT * FROM agenda_state WHERE singleton=1')
      .getSingle();

  Future<CalendarContext> _context({bool allowMaintenance = false}) async {
    if (_closed) throw const CalendarFailure(CalendarFailureCode.closed);
    _db._ownership.ensureHeld();
    final canonical = await _db._state();
    final state = await _agendaState();
    final owner = canonical.read<String>('owner_id');
    _db._validateOwner(owner);
    if (!allowMaintenance &&
        (_maintenanceRequested || state.read<int>('maintenance') != 0)) {
      throw const CalendarFailure(CalendarFailureCode.maintenance);
    }
    return CalendarContext(
      owner: owner,
      resetEpoch: canonical.read<int>('reset_epoch'),
      agendaEpoch: state.read<int>('epoch'),
    );
  }

  Future<void> _guard(CalendarContext expected) async {
    final actual = await _context();
    if (actual != expected) {
      throw const CalendarFailure(CalendarFailureCode.staleReference);
    }
  }

  void _invalidateMemory() {
    _closed = true;
    _prepared.clear();
    for (final prepared in _agentPlans.values) {
      prepared.revoked = true;
    }
  }

  /// Internal maintenance entry for the later C5 maintenance workflow. It
  /// invalidates old commands before draining and persists the barrier/epoch.
  /// No deletion is performed here; M4.4 defines the confirmed deletion scope.
  Future<CalendarContext> beginMaintenance() {
    _maintenanceRequested = true;
    _prepared.clear();
    for (final prepared in _agentPlans.values) {
      prepared.revoked = true;
    }
    return _serial(() async {
      final result = await _db.transaction(() async {
        final state = await _agendaState();
        if (state.read<int>('maintenance') == 0) {
          await _db.customStatement(
            'UPDATE agenda_state SET maintenance=1,epoch=epoch+1,revision=revision+1 WHERE singleton=1',
          );
        }
        return _context(allowMaintenance: true);
      });
      _signal((await _agendaState()).read<int>('revision'));
      return result;
    });
  }

  Future<void> finishMaintenance(CalendarContext expected) => _serial(() async {
    await _db.transaction(() async {
      if (await _context(allowMaintenance: true) != expected) {
        throw const CalendarFailure(CalendarFailureCode.staleReference);
      }
      await _db.customStatement(
        'UPDATE agenda_state SET maintenance=0,revision=revision+1 WHERE singleton=1',
      );
      _db._ownership.ensureHeld();
    });
    _maintenanceRequested = false;
    _signal((await _agendaState()).read<int>('revision'));
  });

  void _signal(int revision) {
    if (!_closed) _changes.add(revision);
  }

  @override
  Future<CalendarWindow> query(CalendarQuery query) => _serial(() async {
    validateCalendarQuery(query);
    return _db.transaction(() async {
      final snapshot = await _snapshot(query: query);
      final result = _projection.query(snapshot, query);
      await _guard(snapshot.context);
      return result;
    });
  });

  @override
  Future<CalendarDetail> detail(CalendarReference reference) => _serial(
    () => _db.transaction(() async {
      var snapshot = await _snapshot(targets: {reference.identity});
      final related = snapshot.relations
          .where(
            (r) =>
                r.left == reference.identity || r.right == reference.identity,
          )
          .toList();
      if (related.isNotEmpty && !_target(snapshot, reference).allDay) {
        snapshot = await _snapshot(
          targets: {
            reference.identity,
            for (final relation in related) relation.left,
            for (final relation in related) relation.right,
          },
        );
      }
      final item = _target(snapshot, reference);
      final series = snapshot.personal.where(
        (s) => s.localId == reference.identity.localId,
      );
      final result = CalendarDetail(
        occurrence: item,
        personalDraft: reference.identity.kind == CalendarKind.personal
            ? series.single.draft
            : null,
        hasOccurrenceReplacement:
            reference.identity.kind == CalendarKind.personal &&
            snapshot.overrides.any(
              (override) =>
                  override.localId == reference.identity.localId &&
                  override.ordinal == reference.identity.ordinal &&
                  override.replacement != null,
            ),
        planBlock: reference.identity.kind == CalendarKind.planBlock
            ? await _blockByRef(reference)
            : null,
        relations: item.allDay
            ? const []
            : snapshot.relations
                  .where(
                    (r) =>
                        (r.left == reference.identity ||
                            r.right == reference.identity) &&
                        _projection
                                .occurrence(
                                  snapshot,
                                  r.left == reference.identity
                                      ? r.right
                                      : r.left,
                                )
                                ?.allDay !=
                            true,
                  )
                  .toList(),
      );
      await _guard(reference.context);
      return result;
    }),
  );

  Future<CalendarSnapshot> _snapshot({
    CalendarQuery? query,
    Set<CalendarIdentity>? targets,
  }) async {
    final context = await _context();
    (String, List<Variable>) schoolSelection(bool young) {
      if (query != null) {
        final start = query.firstDay.subtract(const Duration(hours: 8));
        final end = query.endDayExclusive.subtract(const Duration(hours: 8));
        return (
          ' WHERE e.starts_at<? AND e.ends_at>? ',
          [
            Variable.withInt(end.microsecondsSinceEpoch),
            Variable.withInt(start.microsecondsSinceEpoch),
          ],
        );
      }
      if (targets == null) return (' ', []);
      final ids = targets
          .where(
            (id) => young
                ? id.kind == CalendarKind.young
                : id.kind == CalendarKind.course ||
                      id.kind == CalendarKind.exam,
          )
          .map((id) => id.localId)
          .toSet()
          .toList();
      if (ids.isEmpty) return (' WHERE 0 ', []);
      return (
        ' WHERE e.local_id IN (${List.filled(ids.length, '?').join(',')}) ',
        ids.map(Variable.withInt).toList(),
      );
    }

    final (jwWhere, jwVariables) = schoolSelection(false);
    final (youngWhere, youngVariables) = schoolSelection(true);
    final jw = await _db
        .customSelect(
          'SELECT e.local_id,e.version,e.kind,e.title,e.academic_json,e.starts_at,e.ends_at,e.presence,'
          'o.hidden,o.note,o.attendance,o.listening FROM jw_events e '
          'JOIN jw_overlays o ON o.local_id=e.local_id $jwWhere ORDER BY e.local_id LIMIT 5001',
          variables: jwVariables,
        )
        .get();
    final young = await _db
        .customSelect(
          'SELECT e.local_id,e.version,e.title,e.place,e.starts_at,e.ends_at,e.presence,'
          'o.hidden,o.note,o.attendance FROM young_events e '
          'JOIN young_overlays o ON o.local_id=e.local_id $youngWhere ORDER BY e.local_id LIMIT 5001',
          variables: youngVariables,
        )
        .get();
    final personalIds = targets
        ?.where((id) => id.kind == CalendarKind.personal)
        .map((id) => id.localId)
        .toSet()
        .toList();
    final personalWhere = personalIds == null
        ? ''
        : personalIds.isEmpty
        ? ' AND 0 '
        : ' AND local_id IN (${List.filled(personalIds.length, '?').join(',')}) ';
    final overrideWhere = personalIds == null
        ? ''
        : personalIds.isEmpty
        ? ' AND 0 '
        : ' AND e.local_id IN (${List.filled(personalIds.length, '?').join(',')}) ';
    final personalVariables =
        personalIds?.map(Variable.withInt).toList() ?? <Variable>[];
    final personal = await _db
        .customSelect(
          'SELECT local_id,version,draft_json FROM personal_events WHERE deleted=0 '
          '$personalWhere ORDER BY local_id LIMIT 5001',
          variables: personalVariables,
        )
        .get();
    final overrides = await _db
        .customSelect(
          'SELECT o.* FROM personal_occurrence_overrides o JOIN personal_events e '
          'ON e.local_id=o.local_id WHERE e.deleted=0 $overrideWhere ORDER BY o.local_id,o.ordinal LIMIT 5001',
          variables: personalVariables,
        )
        .get();
    final relations = await _db
        .customSelect(
          'SELECT * FROM agenda_relations ORDER BY local_id LIMIT 5001',
        )
        .get();
    if ([
      jw,
      young,
      personal,
      overrides,
      relations,
    ].any((v) => v.length > 5000)) {
      throw const CalendarFailure(CalendarFailureCode.limitExceeded);
    }
    if ((jw.isNotEmpty || young.isNotEmpty) && await _db._account() == null) {
      throw const CalendarFailure(CalendarFailureCode.storageFailed);
    }
    return CalendarSnapshot(
      context: context,
      revision: (await _agendaState()).read<int>('revision'),
      school: [
        for (final row in jw) _schoolOccurrence(row, context, young: false),
        for (final row in young) _schoolOccurrence(row, context, young: true),
      ],
      personal: [
        for (final row in personal)
          PersonalSeries(
            localId: row.read<int>('local_id'),
            version: row.read<int>('version'),
            draft: _decodeDraft(row.read<String>('draft_json')),
          ),
      ],
      overrides: [
        for (final row in overrides)
          PersonalOccurrenceOverride(
            localId: row.read<int>('local_id'),
            ordinal: row.read<int>('ordinal'),
            replacement: row.read<String?>('replacement_json') == null
                ? null
                : _decodeDraft(row.read<String>('replacement_json')),
            completed: row.read<int>('completed') == 1,
            skipped: row.read<int>('skipped') == 1,
          ),
      ],
      relations: [for (final row in relations) _relation(row, context)],
      planBlocks: await _blockOccurrences(context, query, targets),
    );
  }

  CalendarOccurrence _schoolOccurrence(
    QueryRow row,
    CalendarContext context, {
    required bool young,
  }) {
    final kind = young
        ? CalendarKind.young
        : _enum(CalendarKind.values, row.read<String>('kind'));
    if (!young && kind != CalendarKind.course && kind != CalendarKind.exam) {
      throw const CalendarFailure(CalendarFailureCode.storageFailed);
    }
    final start = _time(row.read<int>('starts_at'));
    final end = _time(row.read<int>('ends_at'));
    if (!end.isAfter(start)) {
      throw const CalendarFailure(CalendarFailureCode.storageFailed);
    }
    final academicJson = young ? null : row.read<String?>('academic_json');
    final academic = academicJson == null
        ? null
        : JwAcademicDetails.decode(academicJson);
    return CalendarOccurrence(
      reference: CalendarReference(
        context,
        CalendarIdentity(kind, row.read<int>('local_id')),
        row.read<int>('version'),
      ),
      title: row.read<String>('title'),
      startsAtUtc: start,
      endsAtUtc: end,
      location: young
          ? row.read<String>('place')
          : academic?.locationLabel ?? '',
      academicDetails: academic,
      presence: _enum(AgendaPresence.values, row.read<String>('presence')),
      hidden: row.read<int>('hidden') == 1,
      note: row.read<String>('note'),
      attendance: _enum(
        AttendanceDecision.values,
        row.read<String>('attendance'),
      ),
      listening: young
          ? ListeningMode.undecided
          : _enum(ListeningMode.values, row.read<String>('listening')),
    );
  }

  T _enum<T extends Enum>(List<T> values, String name) {
    final found = values.where((value) => value.name == name);
    if (found.length != 1) {
      throw const CalendarFailure(CalendarFailureCode.storageFailed);
    }
    return found.single;
  }

  DateTime _time(int microseconds) =>
      DateTime.fromMicrosecondsSinceEpoch(microseconds, isUtc: true);

  PersonalEventDraft _decodeDraft(String encoded) {
    try {
      final v = jsonDecode(encoded);
      if (v is! List ||
          v.length != 8 ||
          v[0] is! String ||
          v[1] is! int ||
          v[2] is! int ||
          v[3] is! bool ||
          v[4] is! bool ||
          (v[5] != null && v[5] is! int) ||
          v[6] is! String ||
          v[7] is! String) {
        throw const CalendarFailure(CalendarFailureCode.storageFailed);
      }
      final result = PersonalEventDraft(
        title: v[0] as String,
        start: _time(v[1] as int),
        end: _time(v[2] as int),
        allDay: v[3] as bool,
        weekly: v[4] as bool,
        untilDay: v[5] == null ? null : _time(v[5] as int),
        location: v[6] as String,
        note: v[7] as String,
      );
      validatePersonalDraft(result);
      return result;
    } on Object {
      throw const CalendarFailure(CalendarFailureCode.storageFailed);
    }
  }

  CalendarIdentity _decodeIdentity(String encoded) {
    try {
      final values = jsonDecode(encoded);
      if (values is! List ||
          values.length != 3 ||
          values[0] is! String ||
          values[1] is! int ||
          values[2] is! int) {
        throw const CalendarFailure(CalendarFailureCode.storageFailed);
      }
      final result = CalendarIdentity(
        _enum(CalendarKind.values, values[0] as String),
        values[1] as int,
        ordinal: values[2] as int,
      );
      validateCalendarIdentity(result);
      return result;
    } on Object {
      throw const CalendarFailure(CalendarFailureCode.storageFailed);
    }
  }

  CalendarRelation _relation(QueryRow row, CalendarContext context) =>
      CalendarRelation(
        reference: CalendarRelationReference(
          context,
          row.read<int>('local_id'),
          row.read<int>('version'),
        ),
        left: _decodeIdentity(row.read<String>('left_identity')),
        right: _decodeIdentity(row.read<String>('right_identity')),
        kind: _enum(CalendarRelationKind.values, row.read<String>('kind')),
        note: row.read<String>('note'),
      );

  CalendarOccurrence _target(CalendarSnapshot snapshot, CalendarReference ref) {
    validateCalendarIdentity(ref.identity);
    if (snapshot.context != ref.context || ref.version <= 0) {
      throw const CalendarFailure(CalendarFailureCode.staleReference);
    }
    final result = _projection.occurrence(snapshot, ref.identity);
    if (result == null || result.reference.version != ref.version) {
      throw const CalendarFailure(CalendarFailureCode.staleReference);
    }
    return result;
  }

  String _fingerprint(CalendarCommand command) => fingerprint([
    'local-calendar-command-v1',
    command.operationId,
    command.context.owner,
    command.context.resetEpoch,
    command.context.agendaEpoch,
    command.intent.canonical,
  ]);

  @override
  Future<CalendarCommand> prepare(
    CalendarContext context,
    CalendarIntent intent,
  ) => _serial(() async {
    await _guard(context);
    _validateIntent(context, intent);
    if (_prepared.length >= 1024) {
      throw const CalendarFailure(CalendarFailureCode.limitExceeded);
    }
    final command = CalendarCommand(
      JwStore._randomHexId('calendar-local-'),
      context,
      intent,
    );
    _prepared[command.operationId] = _fingerprint(command);
    return command;
  });

  void _validateIntent(CalendarContext context, CalendarIntent intent) {
    switch (intent) {
      case CreatePersonalEvent(:final draft):
        validatePersonalDraft(draft);
      case UpdatePersonalSeries(:final target, :final draft):
        validatePersonalDraft(draft);
        validateCalendarIdentity(target.identity);
        if (target.context != context ||
            target.identity.kind != CalendarKind.personal) {
          throw const CalendarFailure(CalendarFailureCode.invalidInput);
        }
      case UpdatePersonalOccurrence(:final target, :final replacement):
        validatePersonalDraft(replacement);
        if (replacement.weekly ||
            replacement.untilDay != null ||
            target.identity.kind != CalendarKind.personal ||
            target.context != context) {
          throw const CalendarFailure(CalendarFailureCode.invalidInput);
        }
      case SetPersonalOccurrenceState(
        :final target,
        :final completed,
        :final skipped,
      ):
        if (target.identity.kind != CalendarKind.personal ||
            target.context != context ||
            (completed == null && skipped == null)) {
          throw const CalendarFailure(CalendarFailureCode.invalidInput);
        }
      case DeletePersonalSeries(:final target, :final confirmed):
        if (!confirmed ||
            target.identity.kind != CalendarKind.personal ||
            target.context != context) {
          throw const CalendarFailure(CalendarFailureCode.invalidInput);
        }
      case UpdateSchoolAnnotation(
        :final target,
        :final note,
        :final attendance,
        :final listening,
        :final hidden,
      ):
        if (target.context != context ||
            ![
              CalendarKind.course,
              CalendarKind.exam,
              CalendarKind.young,
            ].contains(target.identity.kind) ||
            (note == null &&
                attendance == null &&
                listening == null &&
                hidden == null) ||
            (note != null && (note.length > 4000 || note.contains('\u0000'))) ||
            (attendance != null && target.identity.kind == CalendarKind.exam) ||
            (listening != null &&
                target.identity.kind != CalendarKind.course)) {
          throw const CalendarFailure(CalendarFailureCode.invalidInput);
        }
      case SaveCalendarRelation(
        :final left,
        :final right,
        :final existing,
        :final note,
        :final kind,
      ):
        if (kind == CalendarRelationKind.legacyUndecided ||
            left.context != context ||
            right.context != context ||
            left.identity == right.identity ||
            note.length > 4000 ||
            note.contains('\u0000') ||
            (existing != null &&
                (existing.context != context ||
                    existing.localId <= 0 ||
                    existing.version <= 0))) {
          throw const CalendarFailure(CalendarFailureCode.invalidInput);
        }
        validateCalendarIdentity(left.identity);
        validateCalendarIdentity(right.identity);
      case DeleteCalendarRelation(:final target):
        if (target.context != context ||
            target.localId <= 0 ||
            target.version <= 0) {
          throw const CalendarFailure(CalendarFailureCode.invalidInput);
        }
      case CreateTask(:final draft):
        _validateTaskDraft(draft);
      case UpdateTask(:final target, :final draft):
        _validateTaskRef(context, target);
        _validateTaskDraft(draft);
      case SetTaskStatus(:final target):
        _validateTaskRef(context, target);
      case DeleteTask(:final target, :final confirmed):
        _validateTaskRef(context, target);
        if (!confirmed) {
          throw const CalendarFailure(CalendarFailureCode.invalidInput);
        }
      case CreatePlanBlock(:final task, :final draft):
        _validateTaskRef(context, task);
        _validateBlockDraft(draft);
      case UpdatePlanBlock(:final target, :final draft):
        _validateBlockRef(context, target);
        _validateBlockDraft(draft);
      case SetPlanBlockStatus(:final target):
        _validateBlockRef(context, target);
      case DeletePlanBlock(:final target, :final confirmed):
        _validateBlockRef(context, target);
        if (!confirmed) {
          throw const CalendarFailure(CalendarFailureCode.invalidInput);
        }
      case UndoCalendarWrite(:final target):
        if (target.context != context ||
            !RegExp(r'^calendar-undo-[0-9a-f]{32}$').hasMatch(target.undoId)) {
          throw const CalendarFailure(CalendarFailureCode.invalidInput);
        }
    }
  }

  void _validateBlockRef(CalendarContext context, CalendarReference ref) {
    validateCalendarIdentity(ref.identity);
    if (ref.context != context ||
        ref.identity.kind != CalendarKind.planBlock ||
        ref.version < 1) {
      throw const CalendarFailure(CalendarFailureCode.invalidInput);
    }
  }

  @override
  Future<CalendarWriteReceipt> commit(CalendarCommand command) =>
      _serial(() async {
        final receipt = await _db.transaction(() => _commitBody(command));
        _prepared.remove(command.operationId);
        if (!receipt.replayed) _signal(receipt.revision);
        return receipt;
      });

  /// Internal transaction body; batch caller owns the one outer transaction,
  /// approval, receipt, revision, undo slot and post-commit notification.
  Future<CalendarWriteReceipt> _commitBody(
    CalendarCommand command, {
    bool batch = false,
    void Function(Map<String, dynamic>)? captureUndo,
  }) async {
    await _guard(command.context);
    _validateIntent(command.context, command.intent);
    if (!RegExp(
      r'^calendar-local-[0-9a-f]{32}$',
    ).hasMatch(command.operationId)) {
      throw const CalendarFailure(CalendarFailureCode.invalidInput);
    }
    final intentFingerprint = _fingerprint(command);
    final prior = batch
        ? null
        : await _db
              .customSelect(
                'SELECT * FROM agenda_receipts WHERE operation_id=?',
                variables: [Variable.withString(command.operationId)],
              )
              .getSingleOrNull();
    if (prior != null) {
      if (prior.read<String>('intent_fingerprint') != intentFingerprint) {
        throw const CalendarFailure(CalendarFailureCode.idempotencyConflict);
      }
      await _guard(command.context);
      return _receipt(prior, command, replayed: true);
    }
    final issued = _prepared[command.operationId];
    if (!batch && (issued == null || issued != intentFingerprint)) {
      throw CalendarFailure(
        issued == null
            ? CalendarFailureCode.staleReference
            : CalendarFailureCode.idempotencyConflict,
      );
    }
    final identities = switch (command.intent) {
      UpdatePersonalSeries(:final target) ||
      UpdatePersonalOccurrence(:final target) ||
      SetPersonalOccurrenceState(:final target) ||
      DeletePersonalSeries(:final target) ||
      UpdateSchoolAnnotation(:final target) => {target.identity},
      SaveCalendarRelation(:final left, :final right) => {
        left.identity,
        right.identity,
      },
      _ => <CalendarIdentity>{},
    };
    final snapshot = await _snapshot(targets: identities);
    CalendarReference? target;
    CalendarRelationReference? relation;
    TaskReference? task;
    CalendarUndoReference? undo;
    final intent = command.intent;
    final originalTarget = switch (intent) {
      UpdatePersonalSeries(:final target) ||
      UpdatePersonalOccurrence(:final target) ||
      SetPersonalOccurrenceState(:final target) ||
      DeletePersonalSeries(:final target) ||
      UpdateSchoolAnnotation(:final target) => target,
      _ => null,
    };
    if (originalTarget != null) _target(snapshot, originalTarget);
    final before = intent is UndoCalendarWrite
        ? <Object?>[]
        : await _beforeUndo(intent);
    switch (intent) {
      case CreatePersonalEvent(:final draft):
        if (await _db._count(
              'SELECT COUNT(*) AS count FROM personal_events WHERE deleted=0',
            ) >=
            5000) {
          throw const CalendarFailure(CalendarFailureCode.limitExceeded);
        }
        await _db.customStatement(
          'INSERT INTO personal_events(version,draft_json,deleted) VALUES (1,?,0)',
          [jsonEncode(draft.canonical)],
        );
        final id =
            (await _db
                    .customSelect('SELECT last_insert_rowid() AS id')
                    .getSingle())
                .read<int>('id');
        target = CalendarReference(
          command.context,
          CalendarIdentity(CalendarKind.personal, id),
          1,
        );
      case UpdatePersonalSeries(:final target, :final draft):
        _target(snapshot, target);
        await _db.customStatement(
          'UPDATE personal_events SET draft_json=?,version=version+1 WHERE local_id=?',
          [jsonEncode(draft.canonical), target.identity.localId],
        );
      case UpdatePersonalOccurrence(:final target, :final replacement):
        _target(snapshot, target);
        await _writeOverride(target.identity, replacement: replacement);
      case SetPersonalOccurrenceState(
        :final target,
        :final completed,
        :final skipped,
      ):
        _target(snapshot, target);
        await _writeOverride(
          target.identity,
          completed: completed,
          skipped: skipped,
        );
      case DeletePersonalSeries(:final target):
        _target(snapshot, target);
        await _db.customStatement(
          'UPDATE personal_events SET deleted=1,version=version+1 WHERE local_id=?',
          [target.identity.localId],
        );
      case UpdateSchoolAnnotation(:final target):
        final current = _target(snapshot, target);
        if (await _db._account() == null) {
          throw const CalendarFailure(CalendarFailureCode.staleReference);
        }
        await _updateSchool(current, intent);
      case SaveCalendarRelation(
        :final left,
        :final right,
        :final existing,
        :final kind,
        :final note,
      ):
        if (_target(snapshot, left).allDay || _target(snapshot, right).allDay) {
          throw const CalendarFailure(CalendarFailureCode.invalidInput);
        }
        final pair = [
          jsonEncode(left.identity.canonical),
          jsonEncode(right.identity.canonical),
        ]..sort();
        final priorRelation = await _db
            .customSelect(
              'SELECT * FROM agenda_relations WHERE left_identity=? AND right_identity=?',
              variables: pair.map(Variable.withString).toList(),
            )
            .getSingleOrNull();
        if (existing == null && priorRelation != null ||
            existing != null &&
                (priorRelation == null ||
                    priorRelation.read<int>('local_id') != existing.localId ||
                    priorRelation.read<int>('version') != existing.version)) {
          throw const CalendarFailure(CalendarFailureCode.staleReference);
        }
        if (existing == null) {
          if (snapshot.relations.length >= 5000) {
            throw const CalendarFailure(CalendarFailureCode.limitExceeded);
          }
          await _db.customStatement(
            'INSERT INTO agenda_relations(left_identity,right_identity,kind,note,version) VALUES (?,?,?,?,1)',
            [...pair, kind.name, note],
          );
          final id =
              (await _db
                      .customSelect('SELECT last_insert_rowid() AS id')
                      .getSingle())
                  .read<int>('id');
          relation = CalendarRelationReference(command.context, id, 1);
        } else {
          await _db.customStatement(
            'UPDATE agenda_relations SET kind=?,note=?,version=version+1 WHERE local_id=?',
            [kind.name, note, existing.localId],
          );
          relation = CalendarRelationReference(
            command.context,
            existing.localId,
            existing.version + 1,
          );
        }
        await _touchEndpoints(left.identity, right.identity);
      case DeleteCalendarRelation(:final target):
        final row = await _db
            .customSelect(
              'SELECT * FROM agenda_relations WHERE local_id=?',
              variables: [Variable.withInt(target.localId)],
            )
            .getSingleOrNull();
        if (row == null || row.read<int>('version') != target.version) {
          throw const CalendarFailure(CalendarFailureCode.staleReference);
        }
        await _db.customStatement(
          'DELETE FROM agenda_relations WHERE local_id=?',
          [target.localId],
        );
        await _touchEndpoints(
          _decodeIdentity(row.read<String>('left_identity')),
          _decodeIdentity(row.read<String>('right_identity')),
        );
      case CreateTask() ||
          UpdateTask() ||
          SetTaskStatus() ||
          DeleteTask() ||
          CreatePlanBlock() ||
          UpdatePlanBlock() ||
          SetPlanBlockStatus() ||
          DeletePlanBlock():
        (task, target) = await _applyTask(command);
      case UndoCalendarWrite(target: final slot):
        (target, task, relation) = await _applyUndo(slot);
    }
    // Avoid deriving targets from UI: every result refers to the C3-verified
    // identity above. An edit to one occurrence increments the whole series.
    final changedRef = switch (intent) {
      UpdatePersonalSeries(:final target) ||
      UpdatePersonalOccurrence(:final target) ||
      SetPersonalOccurrenceState(:final target) ||
      DeletePersonalSeries(:final target) ||
      UpdateSchoolAnnotation(:final target) => target,
      _ => null,
    };
    if (changedRef != null) {
      target = CalendarReference(
        command.context,
        changedRef.identity,
        changedRef.version + 1,
      );
    }
    if (intent is! UndoCalendarWrite) {
      if (batch) {
        captureUndo?.call(
          await _buildUndoPayload(command, before, target, task, relation),
        );
      } else {
        undo = await _recordUndo(command, before, target, task, relation);
      }
    }
    if (_db.onCalendarCheckpoint != null) await _db.onCalendarCheckpoint!();
    await _guard(command.context);
    final at = _db._clock.nowUtc;
    if (!at.isUtc) {
      throw const CalendarFailure(CalendarFailureCode.storageFailed);
    }
    if (batch) {
      return CalendarWriteReceipt(
        operationId: command.operationId,
        revision: (await _agendaState()).read<int>('revision'),
        replayed: false,
        target: target,
        relation: relation,
        task: task,
      );
    }
    await _db.customStatement(
      'UPDATE agenda_state SET revision=revision+1 WHERE singleton=1',
    );
    final revision = (await _agendaState()).read<int>('revision');
    await _db.customStatement(
      'INSERT INTO agenda_audit(action,item_count,committed_at) VALUES (?,?,?)',
      [
        intent.canonical.first as String,
        intent is SaveCalendarRelation ? 2 : 1,
        at.microsecondsSinceEpoch,
      ],
    );
    await _db.customStatement(
      'INSERT INTO agenda_receipts(operation_id,intent_fingerprint,revision,target_json,relation_json,committed_at,task_json,undo_id) VALUES (?,?,?,?,?,?,?,?)',
      [
        command.operationId,
        intentFingerprint,
        revision,
        target == null
            ? null
            : jsonEncode([...target.identity.canonical, target.version]),
        relation == null
            ? null
            : jsonEncode([relation.localId, relation.version]),
        at.microsecondsSinceEpoch,
        task == null ? null : jsonEncode([task.localId, task.version]),
        undo?.undoId,
      ],
    );
    await _guard(command.context);
    return CalendarWriteReceipt(
      operationId: command.operationId,
      revision: revision,
      replayed: false,
      target: target,
      relation: relation,
      task: task,
      undo: undo,
    );
  }

  Future<void> _writeOverride(
    CalendarIdentity identity, {
    PersonalEventDraft? replacement,
    bool? completed,
    bool? skipped,
  }) async {
    final prior = await _db
        .customSelect(
          'SELECT * FROM personal_occurrence_overrides WHERE local_id=? AND ordinal=?',
          variables: [
            Variable.withInt(identity.localId),
            Variable.withInt(identity.ordinal),
          ],
        )
        .getSingleOrNull();
    if (prior == null &&
        await _db._count(
              'SELECT COUNT(*) AS count FROM personal_occurrence_overrides',
            ) >=
            5000) {
      throw const CalendarFailure(CalendarFailureCode.limitExceeded);
    }
    await _db.customStatement(
      'INSERT INTO personal_occurrence_overrides(local_id,ordinal,replacement_json,completed,skipped) VALUES (?,?,?,?,?) '
      'ON CONFLICT(local_id,ordinal) DO UPDATE SET replacement_json=excluded.replacement_json,completed=excluded.completed,skipped=excluded.skipped',
      [
        identity.localId,
        identity.ordinal,
        replacement == null
            ? prior?.read<String?>('replacement_json')
            : jsonEncode(replacement.canonical),
        completed == null
            ? (prior?.read<int>('completed') ?? 0)
            : (completed ? 1 : 0),
        skipped == null
            ? (prior?.read<int>('skipped') ?? 0)
            : (skipped ? 1 : 0),
      ],
    );
    await _db.customStatement(
      'UPDATE personal_events SET version=version+1 WHERE local_id=?',
      [identity.localId],
    );
  }

  Future<void> _updateSchool(
    CalendarOccurrence item,
    UpdateSchoolAnnotation intent,
  ) async {
    final young = item.reference.identity.kind == CalendarKind.young;
    final id = item.reference.identity.localId;
    final overlay = young ? 'young_overlays' : 'jw_overlays';
    final events = young ? 'young_events' : 'jw_events';
    await _db.customStatement(
      young
          ? 'UPDATE $overlay SET hidden=?,note=?,attendance=? WHERE local_id=?'
          : 'UPDATE $overlay SET hidden=?,note=?,attendance=?,listening=? WHERE local_id=?',
      [
        (intent.hidden ?? item.hidden) ? 1 : 0,
        intent.note ?? item.note,
        (intent.attendance ?? item.attendance).name,
        if (!young) (intent.listening ?? item.listening).name,
        id,
      ],
    );
    await _db.customStatement(
      'UPDATE $events SET version=version+1 WHERE local_id=?',
      [id],
    );
  }

  CalendarWriteReceipt _receipt(
    QueryRow row,
    CalendarCommand command, {
    required bool replayed,
  }) {
    try {
      final targetText = row.read<String?>('target_json');
      CalendarReference? target;
      if (targetText != null) {
        final v = jsonDecode(targetText);
        if (v is! List ||
            v.length != 4 ||
            v[0] is! String ||
            v[1] is! int ||
            v[2] is! int ||
            v[3] is! int ||
            v[3] <= 0) {
          throw const CalendarFailure(CalendarFailureCode.storageFailed);
        }
        final identity = _decodeIdentity(jsonEncode(v.take(3).toList()));
        target = CalendarReference(command.context, identity, v[3] as int);
      }
      final relationText = row.read<String?>('relation_json');
      CalendarRelationReference? relation;
      if (relationText != null) {
        final v = jsonDecode(relationText);
        if (v is! List ||
            v.length != 2 ||
            v[0] is! int ||
            v[1] is! int ||
            v[0] <= 0 ||
            v[1] <= 0) {
          throw const CalendarFailure(CalendarFailureCode.storageFailed);
        }
        relation = CalendarRelationReference(
          command.context,
          v[0] as int,
          v[1] as int,
        );
      }
      final taskText = row.read<String?>('task_json');
      TaskReference? task;
      if (taskText != null) {
        final v = jsonDecode(taskText);
        if (v is! List ||
            v.length != 2 ||
            v[0] is! int ||
            v[1] is! int ||
            v[0] <= 0 ||
            v[1] <= 0) {
          throw const CalendarFailure(CalendarFailureCode.storageFailed);
        }
        task = TaskReference(command.context, v[0] as int, v[1] as int);
      }
      final undoId = row.read<String?>('undo_id');
      return CalendarWriteReceipt(
        operationId: command.operationId,
        revision: row.read<int>('revision'),
        replayed: replayed,
        target: target,
        relation: relation,
        task: task,
        undo: undoId == null
            ? null
            : CalendarUndoReference(command.context, undoId),
      );
    } on Object {
      throw const CalendarFailure(CalendarFailureCode.storageFailed);
    }
  }
}
