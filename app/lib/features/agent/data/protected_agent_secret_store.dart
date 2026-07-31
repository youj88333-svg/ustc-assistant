import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/security/credential_protector.dart';

/// Read/write surface for the per-account Agent API Key.
///
/// The store never persists or logs the raw key. Only the protected bytes
/// returned by [CredentialProtector.protect] and the scheme / version /
/// metadata / timestamp are written to `agent_secrets`. `readKey` decodes the
/// key only for the lifetime of the request and zeroes the temporary buffer
/// in a `finally` block, mirroring the pattern in `AccountService`.
abstract interface class AgentSecretStore {
  Future<bool> hasKey(String accountId);

  Future<void> saveKey(String accountId, String apiKey);

  /// Returns the decoded API Key for [accountId], or `null` if no key is
  /// stored. The decoded bytes live only for the request lifetime.
  Future<String?> readKey(String accountId);

  Future<void> deleteKey(String accountId);
}

class ProtectedAgentSecretStore implements AgentSecretStore {
  ProtectedAgentSecretStore({
    required this.database,
    required this.protector,
    int Function()? now,
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final AppDatabase database;
  final CredentialProtector protector;
  final int Function() now;

  @override
  Future<bool> hasKey(String accountId) async =>
      await (database.select(
        database.agentSecrets,
      )..where((row) => row.accountId.equals(accountId))).getSingleOrNull() !=
      null;

  @override
  Future<void> saveKey(String accountId, String apiKey) async {
    // Encode immediately before protection; the plaintext buffer is zeroed in
    // `finally` so the raw key bytes never outlive the request.
    final plaintext = Uint8List.fromList(utf8.encode(apiKey));
    try {
      final secret = await protector.protect(plaintext);
      final timestamp = now();
      await database
          .into(database.agentSecrets)
          .insertOnConflictUpdate(
            AgentSecretsCompanion.insert(
              accountId: accountId,
              apiKeyCiphertext: secret.bytes,
              scheme: secret.scheme,
              protectionVersion: secret.version,
              protectionMetadata: Value(jsonEncode(secret.metadata)),
              updatedAt: timestamp,
            ),
          );
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
    }
  }

  @override
  Future<String?> readKey(String accountId) async {
    final row = await (database.select(
      database.agentSecrets,
    )..where((row) => row.accountId.equals(accountId))).getSingleOrNull();
    if (row == null) return null;
    final secret = ProtectedSecret(
      bytes: row.apiKeyCiphertext,
      scheme: row.scheme,
      version: row.protectionVersion,
      metadata: _metadata(row.protectionMetadata),
    );
    final plaintext = await protector.unprotect(secret);
    try {
      return utf8.decode(plaintext);
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
    }
  }

  @override
  Future<void> deleteKey(String accountId) async {
    await (database.delete(
      database.agentSecrets,
    )..where((row) => row.accountId.equals(accountId))).go();
  }

  Map<String, Object?> _metadata(String value) {
    final decoded = jsonDecode(value);
    return decoded is Map<String, dynamic> ? decoded : const {};
  }
}
