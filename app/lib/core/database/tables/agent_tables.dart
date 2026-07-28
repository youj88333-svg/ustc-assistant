import 'package:drift/drift.dart';

import 'account_tables.dart';

class AgentSettings extends Table {
  TextColumn get accountId =>
      text().references(LocalAccounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get model => text().withDefault(const Constant('deepseek-v4-flash'))();
  BoolColumn get enabled => boolean().withDefault(const Constant(false))();
  BoolColumn get icourseConsent => boolean().withDefault(const Constant(false))();
  IntColumn get systemPromptVersion =>
      integer().withDefault(const Constant(1))();
  IntColumn get updatedAt => integer()();

  @override
  String get tableName => 'agent_settings';

  @override
  Set<Column<Object>> get primaryKey => {accountId};
}

class AgentSecrets extends Table {
  TextColumn get accountId =>
      text().references(LocalAccounts, #id, onDelete: KeyAction.cascade)();
  BlobColumn get apiKeyCiphertext => blob()();
  TextColumn get scheme => text()();
  IntColumn get protectionVersion => integer()();
  TextColumn get protectionMetadata =>
      text().withDefault(const Constant('{}'))();
  IntColumn get updatedAt => integer()();

  @override
  String get tableName => 'agent_secrets';

  @override
  Set<Column<Object>> get primaryKey => {accountId};
}

class AgentRuns extends Table {
  TextColumn get id => text()();
  TextColumn get accountId =>
      text().references(LocalAccounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get model => text()();
  TextColumn get status => text()();
  TextColumn get errorCode => text().nullable()();
  IntColumn get inputTokens => integer().nullable()();
  IntColumn get outputTokens => integer().nullable()();
  IntColumn get startedAt => integer()();
  IntColumn get finishedAt => integer().nullable()();

  @override
  String get tableName => 'agent_runs';

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class ChatMessages extends Table {
  TextColumn get id => text()();
  TextColumn get accountId =>
      text().references(LocalAccounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get runId =>
      text().nullable().references(AgentRuns, #id, onDelete: KeyAction.cascade)();
  IntColumn get ordinal => integer()();
  TextColumn get role => text()();
  TextColumn get state => text()();
  TextColumn get content => text()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  String get tableName => 'chat_messages';

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {accountId, ordinal},
  ];
}

class ToolInvocations extends Table {
  TextColumn get id => text()();
  TextColumn get accountId =>
      text().references(LocalAccounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get runId =>
      text().references(AgentRuns, #id, onDelete: KeyAction.cascade)();
  TextColumn get toolName => text()();
  TextColumn get status => text()();
  TextColumn get safeArgumentsSummary => text()();
  TextColumn get safeResultSummary => text()();
  IntColumn get startedAt => integer()();
  IntColumn get finishedAt => integer().nullable()();

  @override
  String get tableName => 'tool_invocations';

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class ConversationSummaries extends Table {
  TextColumn get id => text()();
  TextColumn get accountId =>
      text().references(LocalAccounts, #id, onDelete: KeyAction.cascade)();
  IntColumn get throughOrdinal => integer()();
  TextColumn get content => text()();
  TextColumn get model => text()();
  IntColumn get createdAt => integer()();

  @override
  String get tableName => 'conversation_summaries';

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {accountId},
  ];
}
