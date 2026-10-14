part of 'jw_store.dart';

/// C3 owns the single durable conversation pointer and the bounded model
/// summary. Conversation messages remain the user's complete local history.
final class _AgentChatState {
  _AgentChatState(this.owner);

  final AgentStore owner;
  Expando<_AgentChatPermit> _issued = Expando<_AgentChatPermit>();
  void invalidate() => _issued = Expando<_AgentChatPermit>();

  static const schema = <String>[
    '''CREATE TABLE agent_chat_state (
      singleton INTEGER PRIMARY KEY CHECK(singleton=1),
      primary_conversation TEXT,
      revision INTEGER NOT NULL CHECK(revision>=0),
      covered_message_id INTEGER NOT NULL CHECK(covered_message_id>=0),
      summary TEXT NOT NULL CHECK(length(summary)<=4000)
    )''',
    "INSERT INTO agent_chat_state VALUES (1,NULL,0,0,'')",
  ];

  Future<String> ensurePrimary() => owner._serial(() async {
    final (conversationId, changed) = await owner._db.transaction(() async {
      final authority = await owner._authority();
      await owner._require(authority);
      return _ensurePrimaryInTransaction();
    });
    if (changed) owner._signal();
    return conversationId;
  });

  Future<AgentConversationContext> read() => owner._serial(() async {
    late final AgentConversationContext context;
    late final _AgentChatPermit permit;
    late final bool changed;
    await owner._db.transaction(() async {
      final authority = await owner._authority();
      await owner._require(authority);
      final (conversationId, didChange) = await _ensurePrimaryInTransaction();
      changed = didChange;

      final chat = await _chatRow();
      final conversation = await _conversationRow(conversationId);
      if (conversation == null) {
        throw const AgentFailure(AgentFailureCode.staleContext);
      }
      final lastMessageId = await _lastMessageId(conversationId);
      final coveredMessageId = chat.read<int>('covered_message_id');
      if (coveredMessageId > lastMessageId) {
        throw const AgentFailure(AgentFailureCode.storageFailed);
      }
      final summary = chat.read<String>('summary');
      final messages = await _boundedMessages(conversationId);
      if (messages.isNotEmpty && messages.last.id != lastMessageId) {
        throw const AgentFailure(AgentFailureCode.staleContext);
      }

      context = AgentConversationContext(
        conversationId: conversationId,
        revision: chat.read<int>('revision'),
        coveredMessageId: coveredMessageId,
        lastMessageId: lastMessageId,
        summary: summary,
        messages: messages,
      );
      permit = _AgentChatPermit(
        authority: authority,
        conversationGeneration: conversation.read<int>('generation'),
        conversationId: conversationId,
        revision: context.revision,
        coveredMessageId: coveredMessageId,
        lastMessageId: lastMessageId,
        summary: summary,
      );
      await owner._require(authority);
    });
    _issued[context] = permit;
    if (changed) owner._signal();
    return context;
  });

  Future<void> save(AgentConversationContext expected, String summary) async {
    AgentText.requireSafe(summary, maxCharacters: 4000);
    if (summary.trim().isEmpty) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    final permit = _issued[expected];
    if (permit == null) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    return owner._serial(() async {
      await owner._db.transaction(() async {
        await owner._require(permit.authority);
        final live = await _liveSnapshot(permit.conversationId);
        if (live.activeRun != null) {
          throw const AgentFailure(AgentFailureCode.busy);
        }
        _requireExpected(expected, permit, live);

        await owner._db.customStatement(
          'UPDATE agent_chat_state SET summary=?,covered_message_id=?,revision=revision+1 '
          'WHERE singleton=1',
          [summary, permit.lastMessageId],
        );
        await owner._db.onAgentCheckpoint?.call();
        if (!identical(_issued[expected], permit)) {
          throw const AgentFailure(AgentFailureCode.cancelled);
        }

        await owner._require(permit.authority);
        final after = await _liveSnapshot(permit.conversationId);
        if (after.activeRun != null ||
            after.primaryConversation != permit.conversationId ||
            after.conversationGeneration != permit.conversationGeneration ||
            after.lastMessageId != permit.lastMessageId ||
            after.revision != permit.revision + 1 ||
            after.coveredMessageId != permit.lastMessageId ||
            after.summary != summary) {
          throw const AgentFailure(AgentFailureCode.staleContext);
        }
        owner._db._ownership.ensureHeld();
      });
      owner._signal();
    });
  }

  /// Called by C3 while its history-clear/reset transaction is already open.
  Future<void> clear(String? conversation) async {
    final chat = await _chatRow();
    final primary = chat.read<String?>('primary_conversation');
    if (conversation != null && conversation != primary) return;
    String? replacement;
    if (conversation != null) {
      replacement = JwStore._randomHexId('agent-conversation-');
      final now = owner._db._clock.nowUtc.microsecondsSinceEpoch;
      await owner._db.customStatement(
        "INSERT INTO agent_conversations VALUES (?,0,'对话',?,?)",
        [replacement, now, now],
      );
    }
    await owner._db.customStatement(
      "UPDATE agent_chat_state SET primary_conversation=?,summary='',"
      'covered_message_id=0,revision=revision+1 WHERE singleton=1',
      [replacement],
    );
    invalidate();
  }

  Future<(String, bool)> _ensurePrimaryInTransaction() async {
    final chat = await _chatRow();
    final current = chat.read<String?>('primary_conversation');
    if (current != null && await _conversationRow(current) != null) {
      return (current, false);
    }

    final latest = await owner._db
        .customSelect(
          'SELECT conversation_id FROM agent_conversations '
          'ORDER BY updated_at DESC,conversation_id LIMIT 1',
        )
        .getSingleOrNull();
    var selected = latest?.read<String>('conversation_id');
    if (selected == null) {
      selected = JwStore._randomHexId('agent-conversation-');
      final now = owner._db._clock.nowUtc.microsecondsSinceEpoch;
      await owner._db.customStatement(
        'INSERT INTO agent_conversations '
        '(conversation_id,generation,title,created_at,updated_at) '
        "VALUES (?,0,'对话',?,?)",
        [selected, now, now],
      );
    }
    await owner._db.customStatement(
      "UPDATE agent_chat_state SET primary_conversation=?,summary='',"
      'covered_message_id=0,revision=revision+1 WHERE singleton=1',
      [selected],
    );
    owner._db._ownership.ensureHeld();
    return (selected, true);
  }

  Future<List<AgentMessage>> _boundedMessages(String conversationId) async {
    const maximumMessages = 500;
    const pageSize = 100;
    final messages = <AgentMessage>[];
    int? beforeId;
    while (messages.length < maximumMessages) {
      final limit = min(pageSize, maximumMessages - messages.length);
      final page = await owner._messagesPage(
        conversationId,
        beforeId: beforeId,
        limit: limit,
      );
      if (page.isEmpty) break;
      messages.insertAll(0, page);
      beforeId = page.first.id;
      if (page.length < limit) break;
    }
    return List.unmodifiable(messages);
  }

  Future<QueryRow> _chatRow() => owner._db
      .customSelect('SELECT * FROM agent_chat_state WHERE singleton=1')
      .getSingle();

  Future<QueryRow?> _conversationRow(String id) => owner._db
      .customSelect(
        'SELECT generation FROM agent_conversations WHERE conversation_id=?',
        variables: [Variable.withString(id)],
      )
      .getSingleOrNull();

  Future<int> _lastMessageId(String conversationId) async =>
      (await owner._db
              .customSelect(
                'SELECT COALESCE(MAX(message_id),0) AS id FROM agent_messages '
                'WHERE conversation_id=?',
                variables: [Variable.withString(conversationId)],
              )
              .getSingle())
          .read<int>('id');

  Future<_AgentChatLiveSnapshot> _liveSnapshot(String conversationId) async {
    final chat = await _chatRow();
    final conversation = await _conversationRow(conversationId);
    final run = await owner._state();
    if (conversation == null) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    return _AgentChatLiveSnapshot(
      primaryConversation: chat.read<String?>('primary_conversation'),
      revision: chat.read<int>('revision'),
      coveredMessageId: chat.read<int>('covered_message_id'),
      summary: chat.read<String>('summary'),
      conversationGeneration: conversation.read<int>('generation'),
      lastMessageId: await _lastMessageId(conversationId),
      activeRun: run.read<String?>('active_run'),
    );
  }

  void _requireExpected(
    AgentConversationContext expected,
    _AgentChatPermit permit,
    _AgentChatLiveSnapshot live,
  ) {
    if (expected.conversationId != permit.conversationId ||
        expected.revision != permit.revision ||
        expected.coveredMessageId != permit.coveredMessageId ||
        expected.lastMessageId != permit.lastMessageId ||
        expected.summary != permit.summary ||
        live.primaryConversation != permit.conversationId ||
        live.revision != permit.revision ||
        live.coveredMessageId != permit.coveredMessageId ||
        live.summary != permit.summary ||
        live.conversationGeneration != permit.conversationGeneration ||
        live.lastMessageId != permit.lastMessageId) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
  }
}

final class _AgentChatPermit {
  const _AgentChatPermit({
    required this.authority,
    required this.conversationGeneration,
    required this.conversationId,
    required this.revision,
    required this.coveredMessageId,
    required this.lastMessageId,
    required this.summary,
  });

  final AgentAuthority authority;
  final String conversationId, summary;
  final int conversationGeneration, revision, coveredMessageId, lastMessageId;
}

final class _AgentChatLiveSnapshot {
  const _AgentChatLiveSnapshot({
    required this.primaryConversation,
    required this.revision,
    required this.coveredMessageId,
    required this.summary,
    required this.conversationGeneration,
    required this.lastMessageId,
    required this.activeRun,
  });

  final String? primaryConversation, activeRun;
  final String summary;
  final int revision, coveredMessageId, conversationGeneration, lastMessageId;
}
