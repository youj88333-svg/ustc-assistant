part of 'jw_store.dart';

final class _AgentPolicyPermit {
  const _AgentPolicyPermit(
    this.authority,
    this.scope,
    this.revision,
    this.grants,
  );
  final AgentAuthority authority;
  final String scope;
  final int revision;
  final Map<AgentPermissionCategory, int> grants;
}

/// Safe protocol copies and locator aliases share C3's existing lifecycle and
/// transaction queue. They confer neither approval nor model control of SQL.
final class _AgentContextState {
  _AgentContextState(this.owner);
  final AgentStore owner;
  JwStore get db => owner._db;
  final _policies = Expando<_AgentPolicyPermit>();
  final _withdrawn = <String>{};
  final _runPolicies = <String, (String, int, bool)>{};
  static const schema = <String>[
    'ALTER TABLE agent_actions ADD COLUMN invocation_fingerprint TEXT CHECK(invocation_fingerprint IS NULL OR length(invocation_fingerprint)=64)',
    'CREATE INDEX agent_action_invocation ON agent_actions(invocation_fingerprint,run_id) WHERE invocation_fingerprint IS NOT NULL',
    'ALTER TABLE agent_messages ADD COLUMN context_private INTEGER NOT NULL DEFAULT 0 CHECK(context_private IN (0,1))',
    'ALTER TABLE agent_chat_state ADD COLUMN summary_private INTEGER NOT NULL DEFAULT 0 CHECK(summary_private IN (0,1))',
    '''CREATE TABLE agent_use_policy (
      scope TEXT PRIMARY KEY, revision INTEGER NOT NULL CHECK(revision>0),
      configured INTEGER NOT NULL CHECK(configured IN (0,1)),
      personal_allowed INTEGER NOT NULL CHECK(personal_allowed IN (0,1)),
      budget_json TEXT NOT NULL DEFAULT '[16000,2048,16,48,300]')''',
    '''CREATE TABLE agent_context_turns (
      assistant_message_id INTEGER PRIMARY KEY,
      conversation_id TEXT NOT NULL, items_json TEXT NOT NULL,
      personal INTEGER NOT NULL CHECK(personal IN (0,1)),
      selection_text TEXT NOT NULL DEFAULT '' CHECK(length(selection_text)<=6000))''',
    'CREATE INDEX agent_context_conversation ON agent_context_turns(conversation_id,assistant_message_id)',
    '''CREATE TABLE agent_target_aliases (
      conversation_id TEXT NOT NULL, alias TEXT NOT NULL, kind TEXT NOT NULL,
      target_json TEXT NOT NULL, starts_at INTEGER, ends_at INTEGER,
      created_at INTEGER NOT NULL, PRIMARY KEY(conversation_id,alias))''',
    // Legacy private detail output cannot be classified precisely. Preserve
    // visible history but conservatively withhold potentially derived text.
    "UPDATE agent_messages SET context_private=1 WHERE role='assistant' AND (instr(steps_json,'read_event')>0 OR instr(steps_json,'read_task')>0)",
  ];

  String _policyKey(String scope, int revision) => '$scope/$revision';
  Future<AgentUsePolicySnapshot> _policy(String scope) async {
    final row = await db
        .customSelect(
          'SELECT * FROM agent_use_policy WHERE scope=?',
          variables: [Variable.withString(scope)],
        )
        .getSingleOrNull();
    final grants = await db
        .customSelect(
          'SELECT category,revision FROM agent_permissions WHERE scope=? AND enabled=1',
          variables: [Variable.withString(scope)],
        )
        .get();
    final revision = row?.read<int>('revision') ?? 0;
    return AgentUsePolicySnapshot(
      configured: row?.read<int>('configured') == 1,
      revision: revision,
      contextOptions: row == null
          ? const AgentContextOptions()
          : _decodeContextOptions(row.read<String>('budget_json')),
      personalContentAllowed:
          row?.read<int>('personal_allowed') == 1 &&
          !_withdrawn.contains(_policyKey(scope, revision)),
      granted: {
        for (final grant in grants)
          if (!owner._permissions._revoked.contains(
            owner._permissions._key(
              scope,
              AgentPermissionCategory.values.byName(
                grant.read<String>('category'),
              ),
              grant.read<int>('revision'),
            ),
          ))
            AgentPermissionCategory.values.byName(
              grant.read<String>('category'),
            ),
      },
    );
  }

  Future<AgentUsePolicySnapshot> readPolicy() => owner._serial(() async {
    final authority = await owner._authority();
    await owner._require(authority);
    final scope = await owner._permissions.scope();
    final policy = await _policy(scope);
    final rows = await db
        .customSelect(
          'SELECT category,revision FROM agent_permissions WHERE scope=? AND enabled=1',
          variables: [Variable.withString(scope)],
        )
        .get();
    _policies[policy] = _AgentPolicyPermit(authority, scope, policy.revision, {
      for (final r in rows)
        AgentPermissionCategory.values.byName(r.read<String>('category')): r
            .read<int>('revision'),
    });
    return policy;
  });

  Future<void> savePolicy(
    AgentUsePolicySnapshot expected,
    bool personal,
    bool daily,
    AgentContextOptions? options,
  ) async {
    options?.validate();
    final permit = _policies[expected];
    if (permit == null) {
      return Future.error(const AgentFailure(AgentFailureCode.staleContext));
    }
    // Revoke immediately, including transactions paused at their last guard.
    if (!personal) _withdrawn.add(_policyKey(permit.scope, permit.revision));
    if (!daily && expected.dailyOperationsAllowed) {
      for (final c in agentDailyPermissionCategories) {
        final revision = permit.grants[c];
        if (revision != null) {
          owner._permissions._revoked.add(
            owner._permissions._key(permit.scope, c, revision),
          );
        }
      }
    }
    owner._chat.invalidate();
    return owner._serial(() async {
      await db.transaction(() async {
        await owner._require(permit.authority);
        final scope = await owner._permissions.scope();
        final live = await _policy(scope);
        if (scope != permit.scope || live.revision != permit.revision) {
          throw const AgentFailure(AgentFailureCode.staleContext);
        }
        await db.customStatement(
          'INSERT INTO agent_use_policy VALUES (?,1,1,?,?) ON CONFLICT(scope) DO UPDATE SET '
          'revision=revision+1,configured=1,personal_allowed=excluded.personal_allowed,budget_json=excluded.budget_json',
          [
            scope,
            personal ? 1 : 0,
            jsonEncode((options ?? expected.contextOptions).canonical),
          ],
        );
        for (final c in agentDailyPermissionCategories) {
          if (daily) {
            // Preserve revisions of already effective single-category grants.
            final row = await owner._permissions._row(scope, c);
            if (row?.read<int>('enabled') == 1 &&
                !owner._permissions._revoked.contains(
                  owner._permissions._key(scope, c, row!.read<int>('revision')),
                )) {
              continue;
            }
            await db.customStatement(
              'INSERT INTO agent_permissions VALUES (?,?,?,1,1,?) '
              'ON CONFLICT(scope,tool,category) DO UPDATE SET revision=revision+1,enabled=1,changed_at=excluded.changed_at',
              [scope, c.tool, c.name, db._clock.nowUtc.microsecondsSinceEpoch],
            );
          } else if (expected.dailyOperationsAllowed) {
            await db.customStatement(
              'UPDATE agent_permissions SET enabled=0,revision=revision+1,changed_at=? '
              'WHERE scope=? AND tool=? AND category=? AND enabled=1',
              [db._clock.nowUtc.microsecondsSinceEpoch, scope, c.tool, c.name],
            );
          }
        }
        if (!personal) {
          // Whole derived items are excluded; no claim of semantic scrubbing.
          await db.customStatement(
            "UPDATE agent_chat_state SET summary='',summary_private=0,"
            'covered_message_id=0,revision=revision+1 WHERE singleton=1',
          );
        }
        await db.onAgentCheckpoint?.call();
        await owner._require(permit.authority);
        db._ownership.ensureHeld();
      });
      owner._signal();
    });
  }

  Future<void> ensureSnapshot(AgentUsePolicySnapshot expected) =>
      owner._serial(() async {
        final permit = _policies[expected];
        if (permit == null) {
          throw const AgentFailure(AgentFailureCode.staleContext);
        }
        await owner._require(permit.authority);
        final scope = await owner._permissions.scope();
        final current = await _policy(scope);
        if (scope != permit.scope ||
            current.revision != permit.revision ||
            (expected.personalContentAllowed &&
                _withdrawn.contains(_policyKey(scope, permit.revision)))) {
          throw const AgentFailure(AgentFailureCode.staleContext);
        }
      });

  Future<void> bindPolicy(
    AgentRunTicket ticket,
    AgentUsePolicySnapshot expected,
  ) async {
    await owner._requireTicket(ticket);
    final permit = _policies[expected];
    final scope = await owner._permissions.scope();
    final current = await _policy(scope);
    if (permit == null ||
        permit.scope != scope ||
        permit.revision != current.revision ||
        permit.revision != expected.revision ||
        (expected.personalContentAllowed && !current.personalContentAllowed)) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    _runPolicies[ticket.runId] = (
      scope,
      current.revision,
      expected.personalContentAllowed,
    );
  }

  Future<void> ensurePolicy(AgentRunTicket ticket, int revision) async {
    await owner._requireTicket(ticket);
    final scope = await owner._permissions.scope();
    final live = await _policy(scope);
    final bound = _runPolicies[ticket.runId];
    if ((bound != null && (bound.$1 != scope || bound.$2 != revision)) ||
        live.revision != revision ||
        (_withdrawn.contains(_policyKey(scope, revision)) &&
            bound?.$3 == true)) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
  }

  Future<void> saveTurn(
    AgentRunTicket ticket,
    List<AgentContextItem> items,
    bool personal,
    int policyRevision,
    String applicationSelection,
  ) => owner._serial(() async {
    AgentText.requireSafe(applicationSelection, maxCharacters: 6000);
    final encoded = _encodeItems(items);
    if (utf8.encode(encoded).length > 2 * 1024 * 1024) {
      throw const AgentFailure(AgentFailureCode.resourceLimit);
    }
    await db.transaction(() async {
      await ensurePolicy(ticket, policyRevision);
      if (personal &&
          !(await _policy(
            await owner._permissions.scope(),
          )).personalContentAllowed) {
        throw const AgentFailure(AgentFailureCode.consentRequired);
      }
      await db.customStatement(
        'INSERT INTO agent_context_turns VALUES (?,?,?,?,?) '
        'ON CONFLICT(assistant_message_id) DO UPDATE SET items_json=excluded.items_json,personal=excluded.personal,selection_text=excluded.selection_text',
        [
          ticket.assistantMessageId,
          ticket.conversationId,
          encoded,
          personal ? 1 : 0,
          applicationSelection,
        ],
      );
      await db.customStatement(
        'UPDATE agent_messages SET context_private=? WHERE message_id=?',
        [personal ? 1 : 0, ticket.assistantMessageId],
      );
      // Only rebuildable protocol copies are evicted. Visible history remains.
      while (await db._count(
            'SELECT COALESCE(SUM(length(CAST(items_json AS BLOB))),0) AS count FROM agent_context_turns',
          ) >
          8 * 1024 * 1024) {
        await db.customStatement(
          'DELETE FROM agent_context_turns WHERE assistant_message_id IN '
          '(SELECT assistant_message_id FROM agent_context_turns WHERE assistant_message_id<>? ORDER BY assistant_message_id LIMIT 1)',
          [ticket.assistantMessageId],
        );
      }
      await db.onAgentCheckpoint?.call();
      await ensurePolicy(ticket, policyRevision);
      db._ownership.ensureHeld();
    });
  });

  Future<(List<AgentConversationTurn>, Set<int>, bool)> readTurns(
    String conversation,
    List<AgentMessage> messages,
  ) async {
    final policy = await _policy(await owner._permissions.scope());
    final withheld = <int>{};
    final turns = <AgentConversationTurn>[];
    final minimum = messages.isEmpty ? 0 : messages.first.id;
    final rows = await db
        .customSelect(
          'SELECT m.message_id,m.context_private,m.created_at,c.items_json,c.personal,c.selection_text '
          'FROM agent_messages m LEFT JOIN agent_context_turns c ON c.assistant_message_id=m.message_id '
          "WHERE m.conversation_id=? AND m.role='assistant' AND m.message_id>=? ORDER BY m.message_id",
          variables: [
            Variable.withString(conversation),
            Variable.withInt(minimum),
          ],
        )
        .get();
    var personal = false;
    for (final row in rows) {
      final private =
          row.read<int>('context_private') == 1 ||
          row.read<int?>('personal') == 1;
      if (private && !policy.personalContentAllowed) {
        withheld.add(row.read<int>('message_id'));
        continue;
      }
      personal |= private;
      final encoded = row.read<String?>('items_json');
      if (encoded == null) continue;
      turns.add(
        AgentConversationTurn(
          assistantMessageId: row.read<int>('message_id'),
          receivedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
            row.read<int>('created_at'),
            isUtc: true,
          ),
          includesPersonalContent: private,
          applicationSelection: row.read<String?>('selection_text') ?? '',
          items: _decodeItems(encoded),
        ),
      );
    }
    return (turns, withheld, personal);
  }

  void _validateAlias(String alias) {
    if (!RegExp(r'^r_[a-f0-9]{32}$').hasMatch(alias)) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
  }

  Future<void> _remember(
    AgentRunTicket ticket,
    String alias,
    String kind,
    List<Object> target,
    int? start,
    int? end,
  ) async {
    _validateAlias(alias);
    await owner._requireTicket(ticket);
    await db.customStatement(
      'INSERT OR IGNORE INTO agent_target_aliases VALUES (?,?,?,?,?,?,?)',
      [
        ticket.conversationId,
        alias,
        kind,
        jsonEncode(target),
        start,
        end,
        db._clock.nowUtc.microsecondsSinceEpoch,
      ],
    );
    await db.customStatement(
      'DELETE FROM agent_target_aliases WHERE conversation_id=? AND alias IN '
      '(SELECT alias FROM agent_target_aliases WHERE conversation_id=? ORDER BY created_at DESC,alias LIMIT -1 OFFSET 4096)',
      [ticket.conversationId, ticket.conversationId],
    );
  }

  Future<void> rememberEvent(
    AgentRunTicket ticket,
    String alias,
    CalendarReference reference,
    DateTime start,
    DateTime end,
  ) => owner._serial(() async {
    await db.transaction(() async {
      await owner._requireTicket(ticket);
      final calendar = db.localCalendar;
      await calendar._guard(reference.context);
      final snapshot = await calendar._snapshot(targets: {reference.identity});
      final item = calendar._target(snapshot, reference);
      if (item.startsAtUtc != start || item.endsAtUtc != end) {
        throw const CalendarFailure(CalendarFailureCode.staleReference);
      }
      await _remember(
        ticket,
        alias,
        'event',
        reference.canonical,
        start.microsecondsSinceEpoch,
        end.microsecondsSinceEpoch,
      );
    });
  });
  Future<void> rememberTask(
    AgentRunTicket ticket,
    String alias,
    TaskReference reference,
  ) => owner._serial(() async {
    await owner._requireTicket(ticket);
    await db.localCalendar._guard(reference.context);
    await db.localCalendar._taskRow(reference);
    await _remember(ticket, alias, 'task', reference.canonical, null, null);
  });
  Future<QueryRow> _alias(
    AgentRunTicket ticket,
    String alias,
    String kind,
  ) async {
    _validateAlias(alias);
    await owner._requireTicket(ticket);
    final row = await db
        .customSelect(
          'SELECT * FROM agent_target_aliases '
          'WHERE conversation_id=? AND alias=? AND kind=?',
          variables: [
            Variable.withString(ticket.conversationId),
            Variable.withString(alias),
            Variable.withString(kind),
          ],
        )
        .getSingleOrNull();
    if (row == null) {
      throw const CalendarFailure(CalendarFailureCode.staleReference);
    }
    return row;
  }

  Future<(CalendarReference, int)> resolveEvent(
    AgentRunTicket ticket,
    String alias,
  ) => owner._serial(
    () => db.transaction(() async {
      final row = await _alias(ticket, alias, 'event');
      final target = jsonDecode(row.read<String>('target_json')) as List;
      final context = CalendarContext(
        owner: target[0] as String,
        resetEpoch: target[1] as int,
        agendaEpoch: target[2] as int,
      );
      await db.localCalendar._guard(context);
      final identity = CalendarIdentity(
        CalendarKind.values.byName(target[3] as String),
        target[4] as int,
        ordinal: target[5] as int,
      );
      final snapshot = await db.localCalendar._snapshot(targets: {identity});
      final item = LocalCalendarStore._projection.occurrence(
        snapshot,
        identity,
      );
      if (item == null ||
          item.startsAtUtc.microsecondsSinceEpoch !=
              row.read<int>('starts_at') ||
          item.endsAtUtc.microsecondsSinceEpoch != row.read<int>('ends_at')) {
        throw const CalendarFailure(CalendarFailureCode.staleReference);
      }
      await owner._requireTicket(ticket);
      return (item.reference, snapshot.revision);
    }),
  );
  Future<(TaskReference, int)> resolveTask(
    AgentRunTicket ticket,
    String alias,
  ) => owner._serial(
    () => db.transaction(() async {
      final row = await _alias(ticket, alias, 'task');
      final target = jsonDecode(row.read<String>('target_json')) as List;
      final context = CalendarContext(
        owner: target[0] as String,
        resetEpoch: target[1] as int,
        agendaEpoch: target[2] as int,
      );
      await db.localCalendar._guard(context);
      final task = await db
          .customSelect(
            'SELECT version FROM local_tasks WHERE local_id=? AND deleted=0',
            variables: [Variable.withInt(target[3] as int)],
          )
          .getSingleOrNull();
      if (task == null) {
        throw const CalendarFailure(CalendarFailureCode.staleReference);
      }
      await owner._requireTicket(ticket);
      return (
        TaskReference(context, target[3] as int, task.read<int>('version')),
        (await db.localCalendar._agendaState()).read<int>('revision'),
      );
    }),
  );

  Future<void> clearConversation(String? conversation) async {
    for (final table in ['agent_context_turns', 'agent_target_aliases']) {
      await db.customStatement(
        'DELETE FROM $table${conversation == null ? '' : ' WHERE conversation_id=?'}',
        conversation == null ? [] : [conversation],
      );
    }
  }

  Future<void> reset() async {
    await clearConversation(null);
    await db.customStatement('DELETE FROM agent_use_policy');
    _withdrawn.clear();
    _runPolicies.clear();
  }
}

AgentContextOptions _decodeContextOptions(String encoded) {
  final values = (jsonDecode(encoded) as List).cast<int>();
  if (values.length != 5) {
    throw const AgentFailure(AgentFailureCode.storageFailed);
  }
  final result = AgentContextOptions(
    inputTokens: values[0],
    outputTokens: values[1],
    modelCalls: values[2],
    toolCalls: values[3],
    activeSeconds: values[4],
  );
  result.validate();
  return result;
}

String _encodeItems(List<AgentContextItem> items) {
  if (items.length > 512) {
    throw const AgentFailure(AgentFailureCode.resourceLimit);
  }
  final pending = <String>{}, seen = <String>{};
  final rows = <Map<String, Object?>>[];
  for (final item in items) {
    AgentText.requireSafe(item.text ?? '');
    if (item.role == 'tool') {
      if (item.text == null ||
          item.calls.isNotEmpty ||
          !pending.remove(item.toolCallId)) {
        throw const AgentFailure(AgentFailureCode.invalidInput);
      }
    } else if (item.role != 'assistant' ||
        item.toolCallId != null ||
        pending.isNotEmpty ||
        (item.text == null && item.calls.isEmpty)) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    for (final call in item.calls) {
      AgentText.requireSafe(call.argumentsJson, maxCharacters: 16384);
      if (!RegExp(r'^[A-Za-z0-9_.:-]{1,128}$').hasMatch(call.id) ||
          !RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(call.name) ||
          !seen.add(call.id) ||
          jsonDecode(call.argumentsJson) is! Map) {
        throw const AgentFailure(AgentFailureCode.invalidInput);
      }
      pending.add(call.id);
    }
    rows.add({
      'role': item.role,
      'text': item.text,
      'tool_call_id': item.toolCallId,
      'calls': [
        for (final call in item.calls)
          {'id': call.id, 'name': call.name, 'arguments': call.argumentsJson},
      ],
    });
  }
  if (pending.isNotEmpty) {
    throw const AgentFailure(AgentFailureCode.invalidInput);
  }
  return jsonEncode(rows);
}

List<AgentContextItem> _decodeItems(String encoded) {
  final items = (jsonDecode(encoded) as List).map((raw) {
    final row = raw as Map;
    return AgentContextItem(
      role: row['role'] as String,
      text: row['text'] as String?,
      toolCallId: row['tool_call_id'] as String?,
      calls: [
        for (final rawCall in row['calls'] as List)
          AgentContextCall(
            id: (rawCall as Map)['id'] as String,
            name: rawCall['name'] as String,
            argumentsJson: rawCall['arguments'] as String,
          ),
      ],
    );
  }).toList();
  _encodeItems(items);
  return List.unmodifiable(items);
}
