import 'package:drift/drift.dart';

class LocalAccounts extends Table {
  TextColumn get id => text()();
  TextColumn get maskedHint => text()();
  TextColumn get identityDigest => text().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(false))();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  String get tableName => 'local_accounts';

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class CredentialAccounts extends Table {
  TextColumn get accountId =>
      text().references(LocalAccounts, #id, onDelete: KeyAction.cascade)();
  BlobColumn get usernameCiphertext => blob()();
  BlobColumn get passwordCiphertext => blob().nullable()();
  TextColumn get scheme => text()();
  IntColumn get protectionVersion => integer().withDefault(const Constant(1))();
  TextColumn get protectionMetadata =>
      text().withDefault(const Constant('{}'))();
  IntColumn get updatedAt => integer()();

  @override
  String get tableName => 'credential_accounts';

  @override
  Set<Column<Object>> get primaryKey => {accountId};
}
