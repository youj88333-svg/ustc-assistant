import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../domain/agent_models.dart';

/// Persists agent chat conversations on top of [AppDatabase].
///
/// Transaction boundaries are load-bearing: per-account ordinals are allocated
/// inside a transaction to respect the unique `(account_id, ordinal)` key, and
/// `clearConversation` deletes dependent rows in FK-safe order for one account
/// only while preserving `agent_settings` and `agent_secrets`.
class DriftChatRepository {
  DriftChatRepository(this._database);

  final AppDatabase _database;
  static const _uuid = Uuid();

  /// Inserts a new agent run in the `running` state and returns its id.
  Future<String> startRun({
    required String accountId,
    required String model,
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    await _database.into(_database.agentRuns).insert(
      AgentRunsCompanion.insert(
        id: id,
        accountId: accountId,
        model: model,
        status: AgentRunState.running.name,
        startedAt: now,
      ),
    );
    return id;
  }

  /// Appends a chat message, allocating the next per-account ordinal inside a
  /// transaction so concurrent inserts cannot collide on the unique key.
  Future<String> appendMessage({
    required String accountId,
    required String? runId,
    required ChatRole role,
    required ChatMessageState state,
    required String content,
  }) async {
    final id = _uuid.v4();
    await _database.transaction(() async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final maxOrdinalQuery = _database.selectOnly(_database.chatMessages)
        ..addColumns([_database.chatMessages.ordinal.max()])
        ..where(_database.chatMessages.accountId.equals(accountId));
      final maxRow = await maxOrdinalQuery.getSingle();
      final maxOrdinal = maxRow.read(_database.chatMessages.ordinal.max());
      final nextOrdinal = (maxOrdinal ?? 0) + 1;
      await _database.into(_database.chatMessages).insert(
        ChatMessagesCompanion.insert(
          id: id,
          accountId: accountId,
          runId: Value(runId),
          ordinal: nextOrdinal,
          role: role.name,
          state: state.name,
          content: content,
          createdAt: now,
          updatedAt: now,
        ),
      );
    });
    return id;
  }

  /// Updates a streaming assistant draft's content. When [state] is provided
  /// the message state is updated as well, but a draft update never alters a
  /// message whose state is already terminal — the update is scoped to rows
  /// whose state is still `streaming`.
  Future<void> updateAssistantDraft({
    required String accountId,
    required String messageId,
    required String content,
    ChatMessageState? state,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final companion = ChatMessagesCompanion(
      content: Value(content),
      updatedAt: Value(now),
      state: state == null ? const Value.absent() : Value(state.name),
    );
    await (_database.update(_database.chatMessages)
          ..where(
            (row) =>
                row.id.equals(messageId) &
                row.accountId.equals(accountId) &
                row.state.equals(ChatMessageState.streaming.name),
          ))
        .write(companion);
  }

  /// Records the terminal state, optional error code, and token counts for a
  /// run. Sets `finished_at` to the current epoch millis.
  Future<void> finishRun({
    required String runId,
    required AgentRunState state,
    String? errorCode,
    int? inputTokens,
    int? outputTokens,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await (_database.update(_database.agentRuns)
          ..where((row) => row.id.equals(runId)))
        .write(
      AgentRunsCompanion(
        status: Value(state.name),
        errorCode: Value(errorCode),
        inputTokens: Value(inputTokens),
        outputTokens: Value(outputTokens),
        finishedAt: Value(now),
      ),
    );
  }

  /// Returns the most recent chat messages for an account, ordered by ordinal
  /// ascending. Includes completed user messages and completed or streaming
  /// assistant messages; excludes failed, cancelled, and interrupted assistant
  /// drafts per design §6.
  Future<List<ChatMessageRecord>> recentMessages(
    String accountId, {
    required int limit,
  }) async {
    final query = _database.select(_database.chatMessages)
      ..where((row) => row.accountId.equals(accountId))
      ..orderBy([(row) => OrderingTerm.asc(row.ordinal)])
      ..limit(limit);
    final rows = await query.get();
    return rows
        .where((row) => _isEligibleForRecent(row.role, row.state))
        .map(_toRecord)
        .toList();
  }

  static bool _isEligibleForRecent(String role, String state) {
    final chatRole = ChatRole.fromName(role);
    final chatState = ChatMessageState.fromName(state);
    if (chatRole == ChatRole.user) {
      return chatState == ChatMessageState.completed;
    }
    // assistant
    return chatState == ChatMessageState.completed ||
        chatState == ChatMessageState.streaming;
  }

  /// Returns the account's current conversation summary, or null if none.
  Future<ConversationSummaryRecord?> latestSummary(String accountId) async {
    final query = _database.select(_database.conversationSummaries)
      ..where((row) => row.accountId.equals(accountId))
      ..orderBy([(row) => OrderingTerm.desc(row.createdAt)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    return row == null ? null : _toSummary(row);
  }

  /// Upserts the account's single summary (account_id is unique). Deletes any
  /// existing summary then inserts the new one.
  Future<void> replaceSummary({
    required String accountId,
    required int throughOrdinal,
    required String content,
    required String model,
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    await _database.transaction(() async {
      await (_database.delete(_database.conversationSummaries)
            ..where((row) => row.accountId.equals(accountId)))
          .go();
      await _database.into(_database.conversationSummaries).insert(
        ConversationSummariesCompanion.insert(
          id: id,
          accountId: accountId,
          throughOrdinal: throughOrdinal,
          content: content,
          model: model,
          createdAt: now,
        ),
      );
    });
  }

  /// Deletes all conversation data for one account only: tool invocations,
  /// chat messages, agent runs, and summaries. `agent_settings` and
  /// `agent_secrets` are preserved — clearing a chat does not reset config.
  Future<void> clearConversation(String accountId) async {
    await _database.transaction(() async {
      // Delete child rows before parent runs to honor foreign keys, even
      // though cascade would also handle it; order is explicit and safe.
      await (_database.delete(_database.toolInvocations)
            ..where((row) => row.accountId.equals(accountId)))
          .go();
      await (_database.delete(_database.chatMessages)
            ..where((row) => row.accountId.equals(accountId)))
          .go();
      await (_database.delete(_database.agentRuns)
            ..where((row) => row.accountId.equals(accountId)))
          .go();
      await (_database.delete(_database.conversationSummaries)
            ..where((row) => row.accountId.equals(accountId)))
          .go();
    });
  }

  /// Startup recovery: marks stale `running` runs as `interrupted` and their
  /// `streaming` assistant messages as `interrupted`. Called by the session
  /// service on app start to reconcile runs that never reached a terminal
  /// state (e.g. process killed mid-stream).
  Future<void> recoverInterrupted() async {
    await _database.transaction(() async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final staleRuns = await (_database.select(_database.agentRuns)
            ..where((row) => row.status.equals(AgentRunState.running.name)))
          .get();
      for (final run in staleRuns) {
        await (_database.update(_database.agentRuns)
              ..where((row) => row.id.equals(run.id)))
            .write(
          AgentRunsCompanion(
            status: Value(AgentRunState.interrupted.name),
            finishedAt: Value(now),
          ),
        );
        await (_database.update(_database.chatMessages)
              ..where(
                (row) =>
                    row.runId.equals(run.id) &
                    row.state.equals(ChatMessageState.streaming.name),
              ))
            .write(
          ChatMessagesCompanion(
            state: Value(ChatMessageState.interrupted.name),
            updatedAt: Value(now),
          ),
        );
      }
    });
  }

  ChatMessageRecord _toRecord(ChatMessage row) => ChatMessageRecord(
        id: row.id,
        accountId: row.accountId,
        runId: row.runId,
        ordinal: row.ordinal,
        role: ChatRole.fromName(row.role),
        state: ChatMessageState.fromName(row.state),
        content: row.content,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
      );

  ConversationSummaryRecord _toSummary(ConversationSummary row) =>
      ConversationSummaryRecord(
        id: row.id,
        accountId: row.accountId,
        throughOrdinal: row.throughOrdinal,
        content: row.content,
        model: row.model,
        createdAt: row.createdAt,
      );
}
