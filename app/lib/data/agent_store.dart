part of 'jw_store.dart';

/// C3 owns encrypted model configuration, safe conversations and lifecycle.
/// No provider SDK, gateway traffic or Flutter resource is held here.
final class AgentStore
    implements
        AgentDataPort,
        AgentRunJournalPort,
        AgentHistoryPagePort,
        AgentConversationControlPort,
        AgentTranscriptPort,
        AgentReceiptRecoveryPort,
        AgentUsePolicyPort,
        AgentTargetAliasPort,
        AgentPermissionManagementPort,
        AgentRecordPermissionPort,
        AgentPreferencesPort,
        AgentActionRecordPort,
        AgentSourceApprovalPort,
        AgentPreferencesProposalPort {
  AgentStore._(this._db);
  final JwStore _db;
  late final _chat = _AgentChatState(this);
  @override
  void revokeConversationContext() => _chat.invalidate();
  late final _permissions = _AgentPermissionState(this);
  late final _context = _AgentContextState(this);
  final _adviceRuns = <String>{};
  @override
  Future<AgentUsePolicySnapshot> readAgentUsePolicy() => _context.readPolicy();
  @override
  Future<void> ensureAgentUsePolicySnapshot(AgentUsePolicySnapshot expected) =>
      _context.ensureSnapshot(expected);
  @override
  Future<void> saveAgentUsePolicy(
    AgentUsePolicySnapshot expected, {
    required bool personalContentAllowed,
    required bool dailyOperationsAllowed,
    AgentContextOptions? contextOptions,
  }) => _context.savePolicy(
    expected,
    personalContentAllowed,
    dailyOperationsAllowed,
    contextOptions,
  );
  @override
  Future<void> bindAgentRunPolicy(
    AgentRunTicket ticket,
    AgentUsePolicySnapshot expected,
  ) => _serial(() => _context.bindPolicy(ticket, expected));
  @override
  Future<void> ensureAgentUsePolicy(AgentRunTicket ticket, int revision) =>
      _serial(() => _context.ensurePolicy(ticket, revision));
  @override
  void constrainAgentRunToAdvice(AgentRunTicket ticket) {
    if (identical(_tickets[ticket.runId], ticket)) {
      _adviceRuns.add(ticket.runId);
    }
  }

  Future<void> _ensureAgentWritesAllowed(AgentRunTicket ticket) async {
    await _requireTicket(ticket);
    if (_adviceRuns.contains(ticket.runId)) {
      throw const AgentFailure(AgentFailureCode.consentRequired);
    }
  }

  @override
  Future<void> saveAgentTurn(
    AgentRunTicket ticket, {
    required List<AgentContextItem> items,
    required bool includesPersonalContent,
    required int policyRevision,
    String applicationSelection = '',
  }) => _context.saveTurn(
    ticket,
    items,
    includesPersonalContent,
    policyRevision,
    applicationSelection,
  );
  @override
  Future<AgentLocalReceiptRecovery> findUnfinishedAgentLocalReceipt(
    AgentRunTicket current,
    String invocationFingerprint,
  ) => _serial(() async {
    await _requireTicket(current);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(invocationFingerprint)) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    final cutoff =
        (await _db
                .customSelect(
                  "SELECT COALESCE(MAX(message_id),0) AS n FROM agent_messages "
                  "WHERE conversation_id=? AND message_id<? AND role='assistant' "
                  "AND status IN ('complete','streaming')",
                  variables: [
                    Variable.withString(current.conversationId),
                    Variable.withInt(current.assistantMessageId),
                  ],
                )
                .getSingle())
            .read<int>('n');
    const receiptRows =
        'FROM agent_messages m '
        'JOIN agent_actions a ON a.run_id=m.run_id '
        'JOIN agenda_plan_receipts p ON p.operation_id=a.action_id '
        "WHERE m.conversation_id=? AND m.message_id>? AND m.message_id<? "
        "AND m.role='assistant' AND m.status IN ('failed','interrupted','cancelled') "
        "AND a.kind='localPlan' AND a.status='committed' ";
    final variables = [
      Variable.withString(current.conversationId),
      Variable.withInt(cutoff),
      Variable.withInt(current.assistantMessageId),
    ];
    final match = await _db
        .customSelect(
          'SELECT p.committed_count $receiptRows AND a.invocation_fingerprint=? '
          'ORDER BY m.message_id DESC,a.created_at DESC LIMIT 1',
          variables: [...variables, Variable.withString(invocationFingerprint)],
        )
        .getSingleOrNull();
    final unclassified = match == null
        ? (await _db
                      .customSelect(
                        'SELECT COUNT(*) AS n $receiptRows AND a.invocation_fingerprint IS NULL',
                        variables: variables,
                      )
                      .getSingle())
                  .read<int>('n') >
              0
        : false;
    await _requireTicket(current);
    return AgentLocalReceiptRecovery(
      match != null
          ? AgentLocalReceiptRecoveryState.committed
          : unclassified
          ? AgentLocalReceiptRecoveryState.unknown
          : AgentLocalReceiptRecoveryState.absent,
      committedCount: match?.read<int>('committed_count') ?? 0,
    );
  });
  @override
  Future<bool> hasRecoverableAgentLocalReceipt(
    AgentRunTicket current,
    int assistantMessageId,
  ) => _serial(() async {
    await _requireTicket(current);
    final row = await _db
        .customSelect(
          'SELECT COUNT(*) AS n FROM agent_messages m '
          'JOIN agent_actions a ON a.run_id=m.run_id '
          'JOIN agenda_plan_receipts p ON p.operation_id=a.action_id '
          "WHERE m.message_id=? AND m.conversation_id=? AND m.role='assistant' "
          "AND m.status IN ('failed','interrupted','cancelled') "
          "AND a.kind='localPlan' AND a.status='committed'",
          variables: [
            Variable.withInt(assistantMessageId),
            Variable.withString(current.conversationId),
          ],
        )
        .getSingle();
    await _requireTicket(current);
    return row.read<int>('n') > 0;
  });
  @override
  Future<void> rememberAgentEvent(
    AgentRunTicket ticket,
    String alias,
    CalendarReference reference,
    DateTime startsAtUtc,
    DateTime endsAtUtc,
  ) => _context.rememberEvent(ticket, alias, reference, startsAtUtc, endsAtUtc);
  @override
  Future<void> rememberAgentTask(
    AgentRunTicket ticket,
    String alias,
    TaskReference reference,
  ) => _context.rememberTask(ticket, alias, reference);
  @override
  Future<(CalendarReference, int)> resolveAgentEvent(
    AgentRunTicket ticket,
    String alias,
  ) => _context.resolveEvent(ticket, alias);
  @override
  Future<(TaskReference, int)> resolveAgentTask(
    AgentRunTicket ticket,
    String alias,
  ) => _context.resolveTask(ticket, alias);
  final _sourceRequests = Expando<AgentSourceRequest>();
  @override
  Future<List<AgentPermissionReference>> readActionPermissions() =>
      _permissions.read();
  @override
  Future<void> revokeActionPermission(AgentPermissionReference reference) =>
      _permissions.revoke(reference);
  @override
  Future<AgentActionView> prepareSourceAction(
    AgentRunTicket ticket,
    AgentSourceRequest request,
    String title,
    List<String> details,
  ) async {
    final record = await prepareActionRecord(
      ticket,
      AgentActionKind.sourceRefresh,
      title,
      details,
    );
    _sourceRequests[record] = request;
    return record;
  }

  @override
  Future<bool> authorizeAction(
    AgentRunTicket ticket,
    AgentActionView action, {
    required AgentAuthorizationMode mode,
    bool remember = false,
  }) => _serial(() async {
    await _ensureAgentWritesAllowed(ticket);
    if (!identical(_actionPermits[action], ticket) &&
        !identical(_preferencePermits[action]?.$1, ticket)) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    final request = _sourceRequests[action];
    final categories = action.kind == AgentActionKind.planningPreferences
        ? const [AgentPermissionCategory.preferences]
        : request == null
        ? null
        : [
            request.source == AgentRefreshSource.jw
                ? AgentPermissionCategory.refreshJw
                : AgentPermissionCategory.refreshYoung,
          ];
    if (categories == null) {
      if (mode == AgentAuthorizationMode.remembered || remember) {
        throw const AgentFailure(AgentFailureCode.invalidInput);
      }
      await _ensureSourceRecord(ticket, action);
      _sourceApprovals[action] = ticket;
      return true;
    }
    final proof = await _permissions.issue(ticket, categories, mode, remember);
    if (proof == null) return false;
    await _db.transaction(() async {
      await _requireTicket(ticket);
      if (action.kind == AgentActionKind.sourceRefresh) {
        await _ensureSourceRecord(ticket, action);
        await _permissions.validate(proof);
        if (remember) await _permissions.persist(proof);
      }
      await _permissions.validate(proof);
      _db._ownership.ensureHeld();
    });
    _permissions.actions[action] = proof;
    if (action.kind == AgentActionKind.sourceRefresh) {
      _sourceApprovals[action] = ticket;
    }
    return true;
  });
  @override
  Future<String> ensurePrimaryConversation() => _chat.ensurePrimary();
  @override
  Future<AgentConversationContext> readConversationContext() => _chat.read();
  @override
  Future<void> saveConversationSummary(
    AgentConversationContext expected,
    String summary,
  ) => _chat.save(expected, summary);
  final _changes = StreamController<int>.broadcast();
  final Set<ModelSecretLease> _secrets = {};
  final Map<String, AgentRunTicket> _tickets = {};
  final _actionPermits = Expando<AgentRunTicket>();
  final _preferencePermits =
      Expando<(AgentRunTicket, AgentPlanningPreferences)>();
  final _revokedActionRuns = <String>{};
  final _sourceActions = Expando<(AgentRunTicket, AgentActionView)>();
  final _sourceApprovals = Expando<AgentRunTicket>();
  Future<void> ensureYoungAgentDelivery(
    AgentRunTicket ticket,
    YoungJobTicket sourceTicket,
  ) => _serial(() async {
    await _requireTicket(ticket);
    await _db._requireYoungCurrent(sourceTicket, allowCommitted: true);
    final binding = _sourceActions[sourceTicket];
    final receipt = await _db
        .customSelect(
          'SELECT item_count FROM young_receipts WHERE job_id=?',
          variables: [Variable.withString(sourceTicket.stamp.jobId)],
        )
        .getSingleOrNull();
    if (binding == null ||
        !identical(binding.$1, ticket) ||
        sourceTicket.stamp.kind != YoungJobKind.activities ||
        receipt == null) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    await _requireTicket(ticket);
  });
  @override
  Future<void> approveSourceAction(
    AgentRunTicket ticket,
    AgentActionView record,
  ) => _serial(() async {
    await _ensureAgentWritesAllowed(ticket);
    await _ensureSourceRecord(ticket, record);
    _sourceApprovals[record] = ticket;
  });
  Future<void> ensureSourceApproval(
    AgentRunTicket ticket,
    AgentActionView record, [
    AgentSourceRequest? request,
  ]) => _serial(() async {
    await _ensureAgentWritesAllowed(ticket);
    await _ensureSourceRecord(ticket, record);
    if (!identical(_sourceApprovals[record], ticket)) {
      throw const AgentFailure(AgentFailureCode.consentRequired);
    }
    _verifySourceRequest(record, request);
    await _permissions.validateAction(record);
  });
  void _verifySourceRequest(
    AgentActionView record,
    AgentSourceRequest? request,
  ) {
    final expected = _sourceRequests[record];
    if (expected != null && !identical(expected, request)) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
  }

  Future<void> _ensureSourceRecord(
    AgentRunTicket ticket,
    AgentActionView record,
  ) async {
    await _requireTicket(ticket);
    if (!identical(_actionPermits[record], ticket) ||
        record.kind != AgentActionKind.sourceRefresh ||
        _revokedActionRuns.contains(ticket.runId)) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    final row = await _db
        .customSelect(
          'SELECT status FROM agent_actions WHERE action_id=?',
          variables: [Variable.withString(record.id)],
        )
        .getSingleOrNull();
    if (row?.read<String>('status') != 'proposed') {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
  }

  /// Bind only the actual C3 job ticket admitted by this C2 instance.
  Future<void> bindSourceAction(
    AgentRunTicket ticket,
    AgentActionView record,
    Object sourceTicket, [
    AgentSourceRequest? request,
  ]) => _serial(() async {
    await _ensureAgentWritesAllowed(ticket);
    if (!identical(_actionPermits[record], ticket) ||
        record.kind != AgentActionKind.sourceRefresh) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    await _requireTicket(ticket);
    _verifySourceRequest(record, request);
    await _permissions.validateAction(record);
    final expectedSource = _sourceRequests[record]?.source;
    if (expectedSource != null &&
        (expectedSource == AgentRefreshSource.jw
            ? sourceTicket is! JwJobTicket
            : sourceTicket is! YoungJobTicket ||
                  sourceTicket.stamp.kind != YoungJobKind.calendar)) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    if (_revokedActionRuns.contains(ticket.runId)) {
      throw const AgentFailure(AgentFailureCode.cancelled);
    }
    if (sourceTicket is JwJobTicket) {
      if (!identical(_sourceApprovals[record], ticket)) {
        throw const AgentFailure(AgentFailureCode.consentRequired);
      }
      await _db._requireCurrent(sourceTicket);
    } else if (sourceTicket is YoungJobTicket) {
      if (sourceTicket.stamp.kind == YoungJobKind.calendar &&
          !identical(_sourceApprovals[record], ticket)) {
        throw const AgentFailure(AgentFailureCode.consentRequired);
      }
      await _db._requireYoungCurrent(sourceTicket);
    } else {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    _sourceActions[sourceTicket] = (ticket, record);
  });

  Future<void> _commitSourceAction(Object sourceTicket, int count) async {
    final binding = _sourceActions[sourceTicket];
    if (binding == null) return;
    await _ensureAgentWritesAllowed(binding.$1);
    await _permissions.validateAction(binding.$2);
    if (_revokedActionRuns.contains(binding.$1.runId)) {
      throw const AgentFailure(AgentFailureCode.cancelled);
    }
    final current = await _db
        .customSelect(
          'SELECT status FROM agent_actions WHERE action_id=?',
          variables: [Variable.withString(binding.$2.id)],
        )
        .getSingleOrNull();
    if (current?.read<String>('status') != 'proposed') {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    await _saveAction(
      binding.$1,
      _actionWith(
        binding.$2,
        AgentActionStatus.committed,
        count: count,
        authorization:
            _permissions.actions[binding.$2]?.mode ==
                AgentAuthorizationMode.remembered
            ? AgentActionAuthorization.remembered
            : identical(_sourceApprovals[binding.$2], binding.$1)
            ? AgentActionAuthorization.confirmed
            : AgentActionAuthorization.legacy,
      ),
    );
    await _db.customStatement(
      "INSERT INTO agenda_plan_audit(action,item_count,committed_at) VALUES ('source',?,?)",
      [count, _db._clock.nowUtc.microsecondsSinceEpoch],
    );
    await _db.onAgentCheckpoint?.call();
    await _requireTicket(binding.$1);
    await _permissions.validateAction(binding.$2);
    if (_revokedActionRuns.contains(binding.$1.runId)) {
      throw const AgentFailure(AgentFailureCode.cancelled);
    }
  }

  bool _closed = false;
  int _sequence = 0;

  static const schema = <String>[
    '''CREATE TABLE agent_state (singleton INTEGER PRIMARY KEY CHECK(singleton=1),
      history_epoch INTEGER NOT NULL CHECK(history_epoch>=0),
      config_revision INTEGER NOT NULL CHECK(config_revision>0),
      request_epoch INTEGER NOT NULL CHECK(request_epoch>=0),
      run_generation INTEGER NOT NULL CHECK(run_generation>=0), active_run TEXT)''',
    'INSERT INTO agent_state VALUES (1,0,1,0,0,NULL)',
    '''CREATE TABLE agent_config (singleton INTEGER PRIMARY KEY CHECK(singleton=1),
      model_id TEXT NOT NULL CHECK(length(model_id)<=128), model_ids TEXT NOT NULL,
      consent INTEGER NOT NULL CHECK(consent IN (0,1)), key_ciphertext BLOB,
      mechanism TEXT, purpose TEXT, capability TEXT NOT NULL,
      report TEXT NOT NULL, verified_at INTEGER NOT NULL)''',
    '''CREATE TABLE agent_conversations (conversation_id TEXT PRIMARY KEY,
      generation INTEGER NOT NULL CHECK(generation>=0), title TEXT NOT NULL CHECK(length(title)<=80),
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)''',
    '''CREATE TABLE agent_runs (run_id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL,
      conversation_generation INTEGER NOT NULL, reset_epoch INTEGER NOT NULL,
      history_epoch INTEGER NOT NULL, config_revision INTEGER NOT NULL, run_generation INTEGER NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('active','complete','interrupted','cancelled','failed')),
      started_at INTEGER NOT NULL)''',
    '''CREATE TABLE agent_messages (message_id INTEGER PRIMARY KEY AUTOINCREMENT,
      conversation_id TEXT NOT NULL, run_id TEXT NOT NULL,
      role TEXT NOT NULL CHECK(role IN ('user','assistant')),
      text TEXT NOT NULL CHECK(length(text)<=24000),
      status TEXT NOT NULL CHECK(status IN ('streaming','complete','interrupted','cancelled','failed')),
      created_at INTEGER NOT NULL)''',
    'CREATE INDEX agent_messages_conversation ON agent_messages(conversation_id,message_id)',
    '''CREATE TABLE agent_history_intent (singleton INTEGER PRIMARY KEY CHECK(singleton=1),
      operation_id TEXT NOT NULL, conversation_id TEXT, requested_at INTEGER NOT NULL)''',
    '''CREATE TABLE agent_audit (sequence INTEGER PRIMARY KEY AUTOINCREMENT,
      action TEXT NOT NULL CHECK(action IN ('config','key-delete','history-clear')),
      item_count INTEGER NOT NULL CHECK(item_count>=0), committed_at INTEGER NOT NULL)''',
  ];

  static const upgradeFrom11 = <String>[
    "ALTER TABLE agent_messages ADD COLUMN evidence_json TEXT NOT NULL DEFAULT '[]' CHECK(length(evidence_json)<=65536)",
    "ALTER TABLE agent_messages ADD COLUMN steps_json TEXT NOT NULL DEFAULT '[]' CHECK(length(steps_json)<=8192)",
    'ALTER TABLE agent_messages ADD COLUMN image_count INTEGER NOT NULL DEFAULT 0 CHECK(image_count BETWEEN 0 AND 3)',
  ];

  @override
  Future<AgentPlanningPreferences> readPlanningPreferences() =>
      _readPlanningPreferences();
  @override
  Future<void> savePlanningPreferences(AgentPlanningPreferences expected) =>
      _savePlanningPreferences(expected);
  @override
  Future<AgentActionView> preparePreferencesPlan(
    AgentRunTicket ticket,
    AgentPlanningPreferences preferences,
  ) => _preparePreferencesPlan(ticket, preferences);
  @override
  Future<void> commitPreferencesPlan(
    AgentRunTicket ticket,
    AgentActionView record,
  ) => _commitPreferencesPlan(ticket, record);
  @override
  Future<void> rejectPreferencesPlan(
    AgentRunTicket ticket,
    AgentActionView record,
  ) => _rejectPreferencesPlan(ticket, record);
  @override
  Future<AgentActionView> prepareActionRecord(
    AgentRunTicket ticket,
    AgentActionKind kind,
    String title,
    List<String> details, {
    String warning = '',
  }) => _serial(() async {
    final view = AgentActionView(
      id: JwStore._randomHexId('agent-action-'),
      kind: kind,
      status: AgentActionStatus.proposed,
      title: title,
      details: details,
      warning: warning,
    );
    await _db.transaction(() async {
      await _requireTicket(ticket);
      await _saveAction(ticket, view);
    });
    _actionPermits[view] = ticket;
    _signal();
    return view;
  });
  @override
  Future<void> settleActionRecord(
    AgentRunTicket ticket,
    AgentActionView record,
    AgentActionStatus status, {
    int committedCount = 0,
  }) => _serial(() async {
    if (!identical(_actionPermits[record], ticket) ||
        status == AgentActionStatus.proposed ||
        status == AgentActionStatus.committed) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    await _db.transaction(() async {
      await _requireTicket(ticket);
      final current = await _db
          .customSelect(
            'SELECT status FROM agent_actions WHERE action_id=?',
            variables: [Variable.withString(record.id)],
          )
          .getSingleOrNull();
      if (current?.read<String>('status') == 'committed') return;
      if (current?.read<String>('status') != 'proposed') {
        throw const AgentFailure(AgentFailureCode.staleContext);
      }
      _sourceApprovals[record] = null;
      await _saveAction(
        ticket,
        _actionWith(record, status, count: committedCount),
      );
    });
    _signal();
  });

  @override
  Future<void> ensureAgentRun(AgentRunTicket ticket) =>
      _serial(() => _requireTicket(ticket));

  @override
  Future<void> saveRunJournal(
    AgentRunTicket ticket, {
    required List<AgentEvidence> evidence,
    required List<AgentToolStep> steps,
    required int imageCount,
  }) => _serial(
    () => _db.transaction(() async {
      await _requireTicket(ticket);
      if (evidence.length > 64 ||
          steps.length > 256 ||
          imageCount < 0 ||
          imageCount > 3 ||
          evidence.map((e) => e.id).toSet().length != evidence.length) {
        throw const AgentFailure(AgentFailureCode.invalidInput);
      }
      final encodedEvidence = jsonEncode(
        evidence.map(agentEvidenceToMap).toList(),
      );
      final encodedSteps = jsonEncode(steps.map(agentStepToMap).toList());
      if (utf8.encode(encodedEvidence).length > 65536 ||
          utf8.encode(encodedSteps).length > 8192) {
        throw const AgentFailure(AgentFailureCode.resourceLimit);
      }
      final previous = await _db
          .customSelect(
            'SELECT evidence_json,steps_json FROM agent_messages WHERE message_id=?',
            variables: [Variable.withInt(ticket.assistantMessageId)],
          )
          .getSingle();
      await _budget(
        max(
          0,
          utf8.encode(encodedEvidence + encodedSteps).length -
              utf8
                  .encode(
                    previous.read<String>('evidence_json') +
                        previous.read<String>('steps_json'),
                  )
                  .length,
        ),
      );
      await _db.customStatement(
        'UPDATE agent_messages SET evidence_json=?,steps_json=? WHERE message_id=?',
        [encodedEvidence, encodedSteps, ticket.assistantMessageId],
      );
      await _db.customStatement(
        "UPDATE agent_messages SET image_count=? WHERE run_id=? AND role='user'",
        [imageCount, ticket.runId],
      );
      await _db.onAgentCheckpoint?.call();
      _db._ownership.ensureHeld();
    }),
  );

  @override
  Stream<int> get changes => _changes.stream;
  void _signal() {
    if (!_closed) _changes.add(++_sequence);
  }

  void _revoke() {
    for (final secret in _secrets) {
      secret.revoke();
    }
    _secrets.clear();
    for (final ticket in _tickets.values) {
      _revokedActionRuns.add(ticket.runId);
    }
    _tickets.clear();
    _adviceRuns.clear();
    _context._runPolicies.clear();
  }

  Future<T> _serial<T>(Future<T> Function() body) async {
    if (_closed) throw const AgentFailure(AgentFailureCode.closed);
    try {
      return await _db._serialized(body);
    } on AppFailure catch (e) {
      throw AgentFailure(switch (e.code) {
        FailureCode.closed => AgentFailureCode.closed,
        FailureCode.ownershipLost ||
        FailureCode.ownerConflict => AgentFailureCode.ownershipLost,
        FailureCode.cleanupPending => AgentFailureCode.maintenance,
        FailureCode.busy => AgentFailureCode.busy,
        FailureCode.staleResult => AgentFailureCode.staleContext,
        FailureCode.cancelled => AgentFailureCode.cancelled,
        _ => AgentFailureCode.storageFailed,
      });
    }
  }

  Future<QueryRow> _state() => _db
      .customSelect('SELECT * FROM agent_state WHERE singleton=1')
      .getSingle();
  Future<QueryRow?> _config() => _db
      .customSelect('SELECT * FROM agent_config WHERE singleton=1')
      .getSingleOrNull();
  Future<QueryRow?> _historyIntent() => _db
      .customSelect('SELECT * FROM agent_history_intent WHERE singleton=1')
      .getSingleOrNull();
  Future<AgentAuthority> _authority() async {
    final canonical = await _db._state();
    final state = await _state();
    final owner = canonical.read<String>('owner_id');
    _db._validateOwner(owner);
    return AgentAuthority(
      owner: owner,
      resetEpoch: canonical.read<int>('reset_epoch'),
      historyEpoch: state.read<int>('history_epoch'),
      configRevision: state.read<int>('config_revision'),
      requestEpoch: state.read<int>('request_epoch'),
    );
  }

  Future<void> _require(
    AgentAuthority expected, {
    bool allowHistoryPending = false,
  }) async {
    await _db._guard();
    if (await _authority() != expected) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    if (!allowHistoryPending && await _historyIntent() != null) {
      throw const AgentFailure(AgentFailureCode.maintenance);
    }
  }

  Future<void> _invalidateRuns({
    String? conversationId,
    bool cancelled = false,
  }) async {
    final status = cancelled ? 'cancelled' : 'interrupted';
    final variables = <Object?>[];
    final where = conversationId == null ? '' : ' AND conversation_id=?';
    if (conversationId != null) variables.add(conversationId);
    await _db.customStatement(
      "UPDATE agent_messages SET status='$status' WHERE status='streaming'$where",
      variables,
    );
    await _db.customStatement(
      "UPDATE agent_runs SET status='$status' WHERE status='active'$where",
      variables,
    );
    await _db.customStatement(
      "UPDATE agent_actions SET status='interrupted' WHERE status='proposed' AND run_id IN (SELECT run_id FROM agent_runs WHERE status='$status'$where)",
      variables,
    );
    final active = (await _state()).read<String?>('active_run');
    if (active != null) {
      final row = await _db
          .customSelect(
            'SELECT conversation_id FROM agent_runs WHERE run_id=?',
            variables: [Variable.withString(active)],
          )
          .getSingleOrNull();
      if (conversationId == null ||
          row?.read<String>('conversation_id') == conversationId) {
        await _db.customStatement(
          'UPDATE agent_state SET run_generation=run_generation+1,active_run=NULL WHERE singleton=1',
        );
      }
    }
  }

  Future<void> _audit(String action, int count) => _db.customStatement(
    'INSERT INTO agent_audit(action,item_count,committed_at) VALUES (?,?,?)',
    [action, count, _db._clock.nowUtc.microsecondsSinceEpoch],
  );

  @override
  Future<void> initializeAgent() => _serial(() async {
    await _db.transaction(() async {
      await _db._guard();
      final pending = await _historyIntent();
      if (pending != null) await _completeHistory(pending);
      await _invalidateRuns();
      await _db.customStatement(
        'UPDATE agent_state SET run_generation=run_generation+1,request_epoch=request_epoch+1,active_run=NULL WHERE singleton=1',
      );
      _db._ownership.ensureHeld();
    });
    _revoke();
    _signal();
  });

  AgentCapabilityReport _report(QueryRow? row) {
    if (row == null) return const AgentCapabilityReport();
    final value = jsonDecode(row.read<String>('report'));
    if (value is! Map<String, dynamic>) {
      throw const AgentFailure(AgentFailureCode.storageFailed);
    }
    final failureName = value['failure'];
    final failure = AgentFailureCode.values
        .where((code) => code.name == failureName)
        .firstOrNull;
    return AgentCapabilityReport(
      text: value['text'] == true,
      streaming: value['streaming'] == true,
      toolCall: value['toolCall'] == true,
      toolResult: value['toolResult'] == true,
      failure: failure,
    );
  }

  @override
  Future<AgentSettingsSnapshot> inspectAgent() => _serial(() async {
    await _db._guard();
    final row = await _config();
    final ids = row == null
        ? <String>[]
        : (jsonDecode(row.read<String>('model_ids')) as List).cast<String>();
    return AgentSettingsSnapshot(
      authority: await _authority(),
      keySaved: row?.read<Uint8List?>('key_ciphertext') != null,
      consent: row?.read<int>('consent') == 1,
      modelId: row?.read<String>('model_id'),
      modelIds: ids,
      report: _report(row),
    );
  });

  static void validateKey(Uint8List bytes) {
    if (bytes.isEmpty ||
        bytes.length > 4096 ||
        bytes.any((b) => b < 33 || b > 126)) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
  }

  @override
  Future<void> saveModelConfiguration(
    AgentAuthority expected, {
    required String modelId,
    required List<String> modelIds,
    required AgentCapabilityReport report,
    required bool consent,
    Uint8List? key,
  }) async {
    if (!consent) throw const AgentFailure(AgentFailureCode.consentRequired);
    if (!AgentText.validModelId(modelId) ||
        modelIds.isEmpty ||
        modelIds.length > 256 ||
        !modelIds.every(AgentText.validModelId) ||
        !modelIds.contains(modelId) ||
        report.capability == ModelCapability.unverified) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    Uint8List? cipher;
    final protector = _db.modelCredentialProtector;
    final purpose = 'ustc-model-key/v1/${expected.owner}';
    try {
      if (key != null) {
        validateKey(key);
        if (protector == null) {
          throw const AgentFailure(AgentFailureCode.protectionFailed);
        }
        try {
          cipher = await protector.protect(key, purpose: purpose);
        } on Object {
          throw const AgentFailure(AgentFailureCode.protectionFailed);
        }
        if (cipher.isEmpty || cipher.length > 65536) {
          throw const AgentFailure(AgentFailureCode.protectionFailed);
        }
      }
      await _serial(
        () => _db.transaction(() async {
          await _require(expected);
          final old = await _config();
          final stored = cipher ?? old?.read<Uint8List?>('key_ciphertext');
          if (stored == null) {
            throw const AgentFailure(AgentFailureCode.keyRequired);
          }
          await _invalidateRuns();
          await _db.customStatement(
            'INSERT OR REPLACE INTO agent_config VALUES (1,?,?,?,?,?,?,?,?,?)',
            [
              modelId,
              jsonEncode(modelIds.toSet().toList()),
              1,
              stored,
              cipher == null
                  ? old?.read<String?>('mechanism')
                  : protector!.mechanism,
              cipher == null ? old?.read<String?>('purpose') : purpose,
              report.capability.name,
              jsonEncode({
                'text': report.text,
                'streaming': report.streaming,
                'toolCall': report.toolCall,
                'toolResult': report.toolResult,
                if (report.failure != null) 'failure': report.failure!.name,
              }),
              _db._clock.nowUtc.microsecondsSinceEpoch,
            ],
          );
          await _db.customStatement(
            'UPDATE agent_state SET config_revision=config_revision+1 WHERE singleton=1',
          );
          await _audit('config', 1);
          await _db.onAgentCheckpoint?.call();
          _db._ownership.ensureHeld();
        }),
      );
      _revoke();
      _signal();
    } finally {
      cipher?.fillRange(0, cipher.length, 0);
    }
  }

  @override
  Future<ModelSecretLease> leaseModelKey(AgentAuthority expected) =>
      _serial(() async {
        await _require(expected);
        final row = await _config();
        if (row == null) throw const AgentFailure(AgentFailureCode.keyRequired);
        final cipher = row.read<Uint8List?>('key_ciphertext');
        if (cipher == null) {
          throw const AgentFailure(AgentFailureCode.keyRequired);
        }
        if (row.read<int>('consent') != 1) {
          throw const AgentFailure(AgentFailureCode.consentRequired);
        }
        final protector = _db.modelCredentialProtector;
        if (protector == null ||
            row.read<String?>('mechanism') != protector.mechanism ||
            row.read<String?>('purpose') !=
                'ustc-model-key/v1/${expected.owner}') {
          throw const AgentFailure(AgentFailureCode.protectionFailed);
        }
        Uint8List bytes;
        try {
          bytes = await protector.unprotect(
            cipher,
            purpose: row.read<String>('purpose'),
          );
        } on Object {
          throw const AgentFailure(AgentFailureCode.protectionFailed);
        }
        try {
          try {
            validateKey(bytes);
          } on AgentFailure {
            throw const AgentFailure(AgentFailureCode.protectionFailed);
          }
          await _require(expected);
          _secrets.removeWhere((secret) => !secret.isAvailable);
          final secret = ModelSecretLease(bytes);
          _secrets.add(secret);
          return secret;
        } catch (_) {
          bytes.fillRange(0, bytes.length, 0);
          rethrow;
        }
      });
  @override
  Future<void> invalidateModelWork(
    AgentAuthority expected,
  ) => _serial(() async {
    await _db.transaction(() async {
      await _require(expected, allowHistoryPending: true);
      await _invalidateRuns(cancelled: true);
      await _db.customStatement(
        'UPDATE agent_state SET request_epoch=request_epoch+1 WHERE singleton=1',
      );
      _db._ownership.ensureHeld();
    });
    _revoke();
    _signal();
  });
  @override
  Future<void> setModelConsent(
    AgentAuthority expected,
    bool consent,
  ) => _serial(() async {
    await _db.transaction(() async {
      await _require(expected);
      if (await _config() == null) {
        throw const AgentFailure(AgentFailureCode.keyRequired);
      }
      await _invalidateRuns();
      await _db.customStatement(
        'UPDATE agent_config SET consent=? WHERE singleton=1',
        [consent ? 1 : 0],
      );
      await _db.customStatement(
        'UPDATE agent_state SET config_revision=config_revision+1,request_epoch=request_epoch+1 WHERE singleton=1',
      );
      await _audit('config', 1);
      await _db.onAgentCheckpoint?.call();
      _db._ownership.ensureHeld();
    });
    _revoke();
    _signal();
  });
  @override
  Future<void> deleteModelKey(AgentAuthority expected) => _serial(() async {
    await _db.transaction(() async {
      await _require(expected);
      await _invalidateRuns();
      await _db.customStatement(
        'UPDATE agent_config SET key_ciphertext=NULL,mechanism=NULL,purpose=NULL WHERE singleton=1',
      );
      await _db.customStatement(
        'UPDATE agent_state SET config_revision=config_revision+1 WHERE singleton=1',
      );
      await _audit('key-delete', 1);
      await _db.onAgentCheckpoint?.call();
      _db._ownership.ensureHeld();
    });
    _revoke();
    _signal();
  });

  @override
  Future<List<AgentConversation>> conversations() => _serial(() async {
    await _db._guard();
    final rows = await _db
        .customSelect(
          'SELECT * FROM agent_conversations ORDER BY updated_at DESC,conversation_id LIMIT 100',
        )
        .get();
    return rows
        .map(
          (r) => AgentConversation(
            id: r.read<String>('conversation_id'),
            title: r.read<String>('title'),
            updatedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
              r.read<int>('updated_at'),
              isUtc: true,
            ),
          ),
        )
        .toList();
  });
  @override
  Future<String> createConversation() => _serial(() async {
    final id = await _db.transaction(() async {
      await _require(await _authority());
      if (await _db._count(
            'SELECT COUNT(*) AS count FROM agent_conversations',
          ) >=
          100) {
        throw const AgentFailure(AgentFailureCode.resourceLimit);
      }
      final id = JwStore._randomHexId('agent-conversation-');
      final now = _db._clock.nowUtc.microsecondsSinceEpoch;
      await _db.customStatement(
        'INSERT INTO agent_conversations VALUES (?,0,?,?,?)',
        [id, '新对话', now, now],
      );
      _db._ownership.ensureHeld();
      return id;
    });
    _signal();
    return id;
  });
  @override
  Future<List<AgentMessage>> messages(String conversationId) =>
      _serial(() => _messagesPage(conversationId));
  @override
  Future<List<AgentMessage>> messagesBefore(
    String conversationId,
    int beforeId, {
    int limit = 100,
  }) => _serial(
    () => _messagesPage(conversationId, beforeId: beforeId, limit: limit),
  );
  Future<List<AgentMessage>> _messagesPage(
    String conversationId, {
    int? beforeId,
    int limit = 100,
  }) async {
    await _db._guard();
    if (beforeId != null && beforeId < 1 || limit < 1 || limit > 100) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    final rows = await _db
        .customSelect(
          'SELECT * FROM (SELECT * FROM agent_messages WHERE conversation_id=? ${beforeId == null ? "" : "AND message_id<?"} ORDER BY message_id DESC LIMIT ?) ORDER BY message_id',
          variables: [
            Variable.withString(conversationId),
            if (beforeId != null) Variable.withInt(beforeId),
            Variable.withInt(limit),
          ],
        )
        .get();
    return Future.wait(
      rows
          .map(
            (r) async => AgentMessage(
              id: r.read<int>('message_id'),
              role: AgentMessageRole.values.byName(r.read<String>('role')),
              text: r.read<String>('text'),
              status: AgentMessageStatus.values.byName(
                r.read<String>('status'),
              ),
              createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(
                r.read<int>('created_at'),
                isUtc: true,
              ),
              evidence: List.unmodifiable(
                (jsonDecode(r.read<String>('evidence_json')) as List).map(
                  agentEvidenceFromMap,
                ),
              ),
              steps: List.unmodifiable(
                (jsonDecode(r.read<String>('steps_json')) as List).map(
                  agentStepFromMap,
                ),
              ),
              imageCount: r.read<int>('image_count'),
              actions: r.read<String>('role') == 'assistant'
                  ? await _actionViews(r.read<String>('run_id'))
                  : [],
            ),
          )
          .toList(),
    );
  }

  Future<void> _budget(int extraBytes) async {
    final used = await _db._count(
      'SELECT (SELECT COALESCE(SUM(length(CAST(text AS BLOB))+length(CAST(evidence_json AS BLOB))+length(CAST(steps_json AS BLOB))),0) FROM agent_messages)+(SELECT COALESCE(SUM(length(CAST(details_json AS BLOB))+length(CAST(title AS BLOB))+length(CAST(warning AS BLOB))),0) FROM agent_actions) AS count',
    );
    if (used + extraBytes > 20 * 1024 * 1024) {
      throw const AgentFailure(AgentFailureCode.resourceLimit);
    }
  }

  @override
  Future<AgentRunTicket> beginRun(
    AgentAuthority expected,
    String conversationId,
    String text,
  ) => _serial(() async {
    AgentText.requireSafe(text, maxCharacters: 6000);
    if (text.trim().isEmpty) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    final ticket = await _db.transaction(() async {
      await _require(expected);
      final state = await _state();
      if (state.read<String?>('active_run') != null) {
        throw const AgentFailure(AgentFailureCode.busy);
      }
      final config = await _config();
      if (config?.read<Uint8List?>('key_ciphertext') == null) {
        throw const AgentFailure(AgentFailureCode.keyRequired);
      }
      if (config?.read<int>('consent') != 1) {
        throw const AgentFailure(AgentFailureCode.consentRequired);
      }
      if (_report(config).capability == ModelCapability.unverified) {
        throw const AgentFailure(AgentFailureCode.modelRequired);
      }
      final conv = await _db
          .customSelect(
            'SELECT * FROM agent_conversations WHERE conversation_id=?',
            variables: [Variable.withString(conversationId)],
          )
          .getSingleOrNull();
      if (conv == null) throw const AgentFailure(AgentFailureCode.staleContext);
      final count = await _db
          .customSelect(
            'SELECT COUNT(*) AS count FROM agent_messages WHERE conversation_id=?',
            variables: [Variable.withString(conversationId)],
          )
          .getSingle();
      if (count.read<int>('count') + 2 > 20000) {
        throw const AgentFailure(AgentFailureCode.resourceLimit);
      }
      await _budget(utf8.encode(text).length);
      final runId = JwStore._randomHexId('agent-run-');
      final generation = state.read<int>('run_generation') + 1;
      final now = _db._clock.nowUtc.microsecondsSinceEpoch;
      await _db.customStatement(
        'INSERT INTO agent_runs VALUES (?,?,?,?,?,?,?,\'active\',?)',
        [
          runId,
          conversationId,
          conv.read<int>('generation'),
          expected.resetEpoch,
          expected.historyEpoch,
          expected.configRevision,
          generation,
          now,
        ],
      );
      await _db.customStatement(
        'INSERT INTO agent_messages(conversation_id,run_id,role,text,status,created_at) VALUES (?,?,\'user\',?,\'complete\',?)',
        [conversationId, runId, text, now],
      );
      await _db.customStatement(
        'INSERT INTO agent_messages(conversation_id,run_id,role,text,status,created_at) VALUES (?,?,\'assistant\',\'\',\'streaming\',?)',
        [conversationId, runId, now],
      );
      final message = await _db
          .customSelect('SELECT last_insert_rowid() AS id')
          .getSingle();
      await _db.customStatement(
        'UPDATE agent_state SET run_generation=?,active_run=? WHERE singleton=1',
        [generation, runId],
      );
      await _db.customStatement(
        'UPDATE agent_conversations SET title=CASE WHEN title=\'新对话\' THEN ? ELSE title END,updated_at=? WHERE conversation_id=?',
        [text.substring(0, min(text.length, 32)), now, conversationId],
      );
      _db._ownership.ensureHeld();
      return AgentRunTicket(
        authority: expected,
        runId: runId,
        conversationId: conversationId,
        conversationGeneration: conv.read<int>('generation'),
        runGeneration: generation,
        assistantMessageId: message.read<int>('id'),
      );
    });
    _tickets[ticket.runId] = ticket;
    _revokedActionRuns.clear();
    _signal();
    return ticket;
  });
  Future<void> _requireTicket(AgentRunTicket ticket) async {
    await _require(ticket.authority, allowHistoryPending: true);
    final pending = await _historyIntent();
    if (pending != null &&
        (pending.read<String?>('conversation_id') == null ||
            pending.read<String?>('conversation_id') ==
                ticket.conversationId)) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    final state = await _state();
    final conv = await _db
        .customSelect(
          'SELECT generation FROM agent_conversations WHERE conversation_id=?',
          variables: [Variable.withString(ticket.conversationId)],
        )
        .getSingleOrNull();
    if (!identical(_tickets[ticket.runId], ticket) ||
        state.read<String?>('active_run') != ticket.runId ||
        state.read<int>('run_generation') != ticket.runGeneration ||
        conv?.read<int>('generation') != ticket.conversationGeneration) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
  }

  @override
  Future<void> saveAssistant(AgentRunTicket ticket, String text) => _serial(
    () => _db.transaction(() async {
      AgentText.requireSafe(text);
      await _requireTicket(ticket);
      final current = await _db
          .customSelect(
            'SELECT text FROM agent_messages WHERE message_id=?',
            variables: [Variable.withInt(ticket.assistantMessageId)],
          )
          .getSingle();
      await _budget(
        max(
          0,
          utf8.encode(text).length -
              utf8.encode(current.read<String>('text')).length,
        ),
      );
      await _db.customStatement(
        'UPDATE agent_messages SET text=? WHERE message_id=?',
        [text, ticket.assistantMessageId],
      );
      await _db.onAgentCheckpoint?.call();
      _db._ownership.ensureHeld();
    }),
  );
  @override
  Future<void> finishRun(
    AgentRunTicket ticket,
    AgentMessageStatus status,
  ) => _serial(() async {
    if (status == AgentMessageStatus.streaming) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    await _db.transaction(() async {
      await _requireTicket(ticket);
      await _db.customStatement(
        'UPDATE agent_messages SET status=? WHERE message_id=?',
        [status.name, ticket.assistantMessageId],
      );
      await _db.customStatement(
        'UPDATE agent_runs SET status=? WHERE run_id=?',
        [status.name, ticket.runId],
      );
      await _db.customStatement(
        'UPDATE agent_state SET active_run=NULL WHERE singleton=1',
      );
      await _db.customStatement(
        "UPDATE agent_actions SET status='interrupted' WHERE run_id=? AND status='proposed'",
        [ticket.runId],
      );
      _db._ownership.ensureHeld();
    });
    _tickets.remove(ticket.runId);
    _adviceRuns.remove(ticket.runId);
    _context._runPolicies.remove(ticket.runId);
    _revokedActionRuns.remove(ticket.runId);
    _signal();
  });
  @override
  Future<void> cancelRun(AgentRunTicket ticket) => _serial(() async {
    await _db.transaction(() async {
      await _requireTicket(ticket);
      await _db.customStatement(
        "UPDATE agent_messages SET status='cancelled' WHERE message_id=?",
        [ticket.assistantMessageId],
      );
      await _db.customStatement(
        "UPDATE agent_runs SET status='cancelled' WHERE run_id=?",
        [ticket.runId],
      );
      await _db.customStatement(
        'UPDATE agent_state SET active_run=NULL,run_generation=run_generation+1 WHERE singleton=1',
      );
      await _db.customStatement(
        "UPDATE agent_actions SET status='interrupted' WHERE run_id=? AND status='proposed'",
        [ticket.runId],
      );
      _db._ownership.ensureHeld();
    });
    _tickets.remove(ticket.runId);
    _adviceRuns.remove(ticket.runId);
    _context._runPolicies.remove(ticket.runId);
    _revokedActionRuns.remove(ticket.runId);
    _signal();
  });
  @override
  Future<AgentHistoryIntent> beginClearHistory(
    AgentAuthority expected, {
    String? conversationId,
  }) => _serial(() async {
    final result = await _db.transaction(() async {
      await _require(expected);
      if (conversationId == null) {
        await _db.customStatement(
          'UPDATE agent_state SET history_epoch=history_epoch+1 WHERE singleton=1',
        );
      } else {
        final conv = await _db
            .customSelect(
              'SELECT generation FROM agent_conversations WHERE conversation_id=?',
              variables: [Variable.withString(conversationId)],
            )
            .getSingleOrNull();
        if (conv == null) {
          throw const AgentFailure(AgentFailureCode.staleContext);
        }
        await _db.customStatement(
          'UPDATE agent_conversations SET generation=generation+1 WHERE conversation_id=?',
          [conversationId],
        );
      }
      await _invalidateRuns(conversationId: conversationId);
      final id = JwStore._randomHexId('agent-history-');
      await _db.customStatement(
        'INSERT INTO agent_history_intent VALUES (1,?,?,?)',
        [id, conversationId, _db._clock.nowUtc.microsecondsSinceEpoch],
      );
      await _db.onAgentCheckpoint?.call();
      _db._ownership.ensureHeld();
      return AgentHistoryIntent(
        operationId: id,
        conversationId: conversationId,
      );
    });
    if (conversationId == null) {
      _revoke();
    } else {
      _tickets.removeWhere((_, t) => t.conversationId == conversationId);
    }
    _signal();
    return result;
  });
  Future<void> _completeHistory(QueryRow pending) async {
    final conversation = pending.read<String?>('conversation_id');
    final where = conversation == null ? '' : ' WHERE conversation_id=?';
    final args = conversation == null ? <Object?>[] : <Object?>[conversation];
    await _chat.clear(conversation);
    await _context.clearConversation(conversation);
    final count =
        (await _db
                .customSelect(
                  'SELECT COUNT(*) AS count FROM agent_messages$where',
                  variables: conversation == null
                      ? []
                      : [Variable.withString(conversation)],
                )
                .getSingle())
            .read<int>('count');
    await _db.customStatement(
      'DELETE FROM agent_actions WHERE run_id IN (SELECT run_id FROM agent_runs$where)',
      args,
    );
    for (final table in [
      'agent_messages',
      'agent_runs',
      'agent_conversations',
    ]) {
      await _db.customStatement('DELETE FROM $table$where', args);
    }
    await _db.customStatement('DELETE FROM agent_history_intent');
    await _audit('history-clear', count);
  }

  @override
  Future<void> completeClearHistory(AgentHistoryIntent intent) => _serial(
    () async {
      await _db.transaction(() async {
        await _db._guard();
        final pending = await _historyIntent();
        if (pending == null) return;
        if (pending.read<String>('operation_id') != intent.operationId ||
            pending.read<String?>('conversation_id') != intent.conversationId) {
          throw const AgentFailure(AgentFailureCode.staleContext);
        }
        await _completeHistory(pending);
        await _db.onAgentCheckpoint?.call();
        _db._ownership.ensureHeld();
      });
      _signal();
    },
  );

  /// Called in C3's existing durable maintenance transaction, without nested
  /// queue/SQL transactions. The runner subsequently drains C4 before deletion.
  Future<void> _beginApplicationMaintenance() async {
    _chat.invalidate();
    if (await _historyIntent() != null) {
      throw const SettingsFailure(SettingsFailureCode.busy);
    }
    await _invalidateRuns();
    await _db.customStatement(
      'UPDATE agent_state SET request_epoch=request_epoch+1 WHERE singleton=1',
    );
  }

  Future<void> _resetApplication() async {
    await _chat.clear(null);
    await _permissions.reset();
    await _context.reset();
    _adviceRuns.clear();
    for (final table in [
      'agent_actions',
      'agent_messages',
      'agent_runs',
      'agent_conversations',
      'agent_history_intent',
      'agent_config',
      'agent_audit',
    ]) {
      await _db.customStatement('DELETE FROM $table');
    }
    await _db.customStatement(
      "UPDATE agent_preferences SET revision=revision+1,value_json='[[1,2,3,4,5,6,7],420,1439,60,10,[]]' WHERE singleton=1",
    );
    await _db.customStatement(
      'UPDATE agent_state SET history_epoch=history_epoch+1,config_revision=config_revision+1,request_epoch=request_epoch+1,run_generation=run_generation+1,active_run=NULL WHERE singleton=1',
    );
    _revoke();
  }

  Future<void> close() async {
    _chat.invalidate();
    _closed = true;
    _revoke();
    await _changes.close();
  }
}
