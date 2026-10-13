part of 'jw_store.dart';

/// C3 owns encrypted model configuration, safe conversations and lifecycle.
/// No provider SDK, gateway traffic or Flutter resource is held here.
final class AgentStore implements AgentDataPort {
  AgentStore._(this._db);
  final JwStore _db;
  final _changes = StreamController<int>.broadcast();
  final Set<ModelSecretLease> _secrets = {};
  final Map<String, AgentRunTicket> _tickets = {};
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
    _tickets.clear();
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
  Future<List<AgentMessage>> messages(
    String conversationId,
  ) => _serial(() async {
    await _db._guard();
    final rows = await _db
        .customSelect(
          'SELECT * FROM (SELECT * FROM agent_messages WHERE conversation_id=? ORDER BY message_id DESC LIMIT 100) ORDER BY message_id',
          variables: [Variable.withString(conversationId)],
        )
        .get();
    return rows
        .map(
          (r) => AgentMessage(
            id: r.read<int>('message_id'),
            role: AgentMessageRole.values.byName(r.read<String>('role')),
            text: r.read<String>('text'),
            status: AgentMessageStatus.values.byName(r.read<String>('status')),
            createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(
              r.read<int>('created_at'),
              isUtc: true,
            ),
          ),
        )
        .toList();
  });
  Future<void> _budget(int extraBytes) async {
    final used = await _db._count(
      'SELECT COALESCE(SUM(length(CAST(text AS BLOB))),0) AS count FROM agent_messages',
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
      if (count.read<int>('count') + 2 > 500) {
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
  Future<void> finishRun(AgentRunTicket ticket, AgentMessageStatus status) =>
      _serial(() async {
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
          _db._ownership.ensureHeld();
        });
        _tickets.remove(ticket.runId);
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
      _db._ownership.ensureHeld();
    });
    _tickets.remove(ticket.runId);
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
    if (await _historyIntent() != null) {
      throw const SettingsFailure(SettingsFailureCode.busy);
    }
    await _invalidateRuns();
    await _db.customStatement(
      'UPDATE agent_state SET request_epoch=request_epoch+1 WHERE singleton=1',
    );
  }

  Future<void> _resetApplication() async {
    for (final table in [
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
      'UPDATE agent_state SET history_epoch=history_epoch+1,config_revision=config_revision+1,request_epoch=request_epoch+1,run_generation=run_generation+1,active_run=NULL WHERE singleton=1',
    );
    _revoke();
  }

  Future<void> close() async {
    _closed = true;
    _revoke();
    await _changes.close();
  }
}
