import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../../core/security/credential_protector.dart';

class AccountVerificationError implements Exception {
  const AccountVerificationError(this.code);

  final String code;

  @override
  String toString() => 'AccountVerificationError: $code';
}

class ProvisionalAccount {
  const ProvisionalAccount(this.accountId);

  final String accountId;
}

class AccountSummary {
  const AccountSummary({
    required this.id,
    required this.maskedHint,
    required this.active,
    required this.hasSavedPassword,
    this.jwLastSuccessAt,
    this.youngLastSuccessAt,
  });

  final String id;
  final String maskedHint;
  final bool active;
  final bool hasSavedPassword;
  final int? jwLastSuccessAt;
  final int? youngLastSuccessAt;
}

class _StagedLogin {
  _StagedLogin({
    required this.accountId,
    required this.username,
    required this.password,
    required this.savePassword,
  });

  final String accountId;
  String? username;
  String? password;
  final bool savePassword;

  void discard() {
    username = null;
    password = null;
  }
}

class AccountService {
  AccountService({
    required this.database,
    required this.protector,
    Future<void> Function()? clearBrowserSession,
    int Function()? now,
  }) : clearBrowserSession = clearBrowserSession ?? _noop,
       now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final AppDatabase database;
  final CredentialProtector protector;
  final Future<void> Function() clearBrowserSession;
  final int Function() now;
  static const _uuid = Uuid();
  _StagedLogin? _staged;

  ProvisionalAccount beginFirstLogin() => ProvisionalAccount(_uuid.v4());

  void cancelFirstLogin(ProvisionalAccount provisional) {
    if (_staged?.accountId == provisional.accountId) {
      _staged?.discard();
      _staged = null;
    }
  }

  Future<ProvisionalAccount> stageLogin({
    required String username,
    String? password,
    bool savePassword = false,
    ProvisionalAccount? provisional,
  }) async {
    final normalized = username.trim();
    if (normalized.isEmpty) {
      throw const AccountVerificationError('blank_username');
    }
    _staged?.discard();
    final session = provisional ?? beginFirstLogin();
    _staged = _StagedLogin(
      accountId: session.accountId,
      username: normalized,
      password: password,
      savePassword: savePassword,
    );
    return session;
  }

  Future<String> confirmSuccessfulLogin({
    required String verifiedUsername,
  }) async {
    final staged = _staged;
    if (staged == null || staged.username == null) {
      throw const AccountVerificationError('no_staged_login');
    }
    final verified = verifiedUsername.trim();
    if (verified != staged.username) {
      staged.discard();
      _staged = null;
      throw const AccountVerificationError('identity_mismatch');
    }
    try {
      final existingId = await accountIdFor(verified);
      final accountId = existingId ?? staged.accountId;
      final usernameSecret = await protector.protect(
        Uint8List.fromList(utf8.encode(verified)),
      );
      final passwordSecret = staged.savePassword && staged.password != null
          ? await protector.protect(
              Uint8List.fromList(utf8.encode(staged.password!)),
            )
          : null;
      if (passwordSecret != null &&
          (passwordSecret.scheme != usernameSecret.scheme ||
              passwordSecret.version != usernameSecret.version)) {
        throw const CredentialProtectionException('inconsistent_scheme');
      }
      final timestamp = now();
      await database.transaction(() async {
        await database
            .update(database.localAccounts)
            .write(
              LocalAccountsCompanion(
                isActive: const Value(false),
                updatedAt: Value(timestamp),
              ),
            );
        final existing = await (database.select(
          database.localAccounts,
        )..where((row) => row.id.equals(accountId))).getSingleOrNull();
        await database
            .into(database.localAccounts)
            .insertOnConflictUpdate(
              LocalAccountsCompanion.insert(
                id: accountId,
                maskedHint: _maskedHint(verified),
                isActive: const Value(true),
                createdAt: existing?.createdAt ?? timestamp,
                updatedAt: timestamp,
              ),
            );
        await database
            .into(database.credentialAccounts)
            .insertOnConflictUpdate(
              CredentialAccountsCompanion.insert(
                accountId: accountId,
                usernameCiphertext: usernameSecret.bytes,
                passwordCiphertext: Value(passwordSecret?.bytes),
                scheme: usernameSecret.scheme,
                protectionVersion: Value(usernameSecret.version),
                protectionMetadata: Value(jsonEncode(usernameSecret.metadata)),
                updatedAt: timestamp,
              ),
            );
        await _log(
          existing == null ? 'credential_saved' : 'credential_updated',
          'Stored protected school account credentials.',
          timestamp,
          accountId: accountId,
        );
      });
      return accountId;
    } finally {
      staged.discard();
      _staged = null;
    }
  }

  Future<String> persistVerifiedAccount({
    required String username,
    String? password,
    bool savePassword = false,
  }) async {
    await stageLogin(
      username: username,
      password: password,
      savePassword: savePassword,
    );
    return confirmSuccessfulLogin(verifiedUsername: username);
  }

  Future<String?> accountIdFor(String username) async {
    final normalized = username.trim();
    final expected = Uint8List.fromList(utf8.encode(normalized));
    final rows = await database.select(database.credentialAccounts).get();
    try {
      for (final row in rows) {
        Uint8List? plaintext;
        try {
          plaintext = await protector.unprotect(
            ProtectedSecret(
              bytes: row.usernameCiphertext,
              scheme: row.scheme,
              version: row.protectionVersion,
              metadata: _metadata(row.protectionMetadata),
            ),
          );
          final matches = _equalBytes(plaintext, expected);
          if (matches) return row.accountId;
        } finally {
          plaintext?.fillRange(0, plaintext.length, 0);
        }
      }
      return null;
    } finally {
      expected.fillRange(0, expected.length, 0);
    }
  }

  Future<LocalAccount?> activeAccount() => (database.select(
    database.localAccounts,
  )..where((row) => row.isActive.equals(true))).getSingleOrNull();

  Future<void> switchAccount(String accountId) async {
    final target = await (database.select(
      database.localAccounts,
    )..where((row) => row.id.equals(accountId))).getSingleOrNull();
    if (target == null) {
      throw const AccountVerificationError('account_not_found');
    }
    final timestamp = now();
    await database.transaction(() async {
      await database
          .update(database.localAccounts)
          .write(
            LocalAccountsCompanion(
              isActive: const Value(false),
              updatedAt: Value(timestamp),
            ),
          );
      await (database.update(
        database.localAccounts,
      )..where((row) => row.id.equals(accountId))).write(
        LocalAccountsCompanion(
          isActive: const Value(true),
          updatedAt: Value(timestamp),
        ),
      );
      await _log(
        'account_switch',
        'Switched the active account.',
        timestamp,
        accountId: accountId,
      );
    });
  }

  Future<List<AccountSummary>> summaries() async {
    final accounts = await database.select(database.localAccounts).get();
    final credentials = await database
        .select(database.credentialAccounts)
        .get();
    final sourceConfigs = await database.select(database.sourceConfigs).get();
    final byId = {for (final row in credentials) row.accountId: row};
    final syncByAccountAndSource = {
      for (final row in sourceConfigs)
        '${row.accountId}\u0000${row.source}': row.lastSuccessAt,
    };
    return [
      for (final account in accounts)
        AccountSummary(
          id: account.id,
          maskedHint: account.maskedHint,
          active: account.isActive,
          hasSavedPassword: byId[account.id]?.passwordCiphertext != null,
          jwLastSuccessAt: syncByAccountAndSource['${account.id}\u0000ustc_jw'],
          youngLastSuccessAt:
              syncByAccountAndSource['${account.id}'
                  '\u0000ustc_young_schedule'],
        ),
    ];
  }

  Future<String> usernameForSync(String accountId) async {
    final row = await _credential(accountId);
    final plaintext = await protector.unprotect(_usernameSecret(row));
    try {
      return utf8.decode(plaintext);
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
    }
  }

  Future<String?> passwordForInteractiveLogin(String accountId) async {
    final row = await _credential(accountId);
    final ciphertext = row.passwordCiphertext;
    if (ciphertext == null) return null;
    final plaintext = await protector.unprotect(
      ProtectedSecret(
        bytes: ciphertext,
        scheme: row.scheme,
        version: row.protectionVersion,
        metadata: _metadata(row.protectionMetadata),
      ),
    );
    try {
      return utf8.decode(plaintext);
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
    }
  }

  String stagedUsernameForSync(ProvisionalAccount provisional) {
    final staged = _requireStaged(provisional);
    return staged.username!;
  }

  String? stagedPasswordForInteractiveLogin(ProvisionalAccount provisional) {
    return _requireStaged(provisional).password;
  }

  Future<void> deleteCredentials(String accountId) async {
    final timestamp = now();
    await database.transaction(() async {
      await (database.delete(
        database.credentialAccounts,
      )..where((row) => row.accountId.equals(accountId))).go();
      await _log(
        'credential_deleted',
        'Deleted protected school account credentials.',
        timestamp,
        accountId: accountId,
      );
    });
  }

  Future<void> clearDedicatedBrowserSession() async {
    await clearBrowserSession();
    await _log(
      'browser_session_cleared',
      'Cleared the dedicated browser session.',
      now(),
    );
  }

  Future<List<CalendarEvent>> eventsFor(String accountId) => (database.select(
    database.calendarEvents,
  )..where((row) => row.accountId.equals(accountId))).get();

  Future<CredentialAccount> _credential(String accountId) async {
    final row = await (database.select(
      database.credentialAccounts,
    )..where((item) => item.accountId.equals(accountId))).getSingleOrNull();
    if (row == null) {
      throw const AccountVerificationError('credentials_not_found');
    }
    return row;
  }

  _StagedLogin _requireStaged(ProvisionalAccount provisional) {
    final staged = _staged;
    if (staged == null ||
        staged.accountId != provisional.accountId ||
        staged.username == null) {
      throw const AccountVerificationError('no_staged_login');
    }
    return staged;
  }

  ProtectedSecret _usernameSecret(CredentialAccount row) => ProtectedSecret(
    bytes: row.usernameCiphertext,
    scheme: row.scheme,
    version: row.protectionVersion,
    metadata: _metadata(row.protectionMetadata),
  );

  Future<void> _log(
    String type,
    String summary,
    int timestamp, {
    String? accountId,
  }) => database.actionLogsRepository.append(
    accountId: accountId,
    source: 'system',
    actionType: type,
    result: 'success',
    safeSummary: summary,
    occurredAt: timestamp,
  );

  Map<String, Object?> _metadata(String value) {
    final decoded = jsonDecode(value);
    return decoded is Map<String, dynamic> ? decoded : const {};
  }

  static String _maskedHint(String username) {
    if (username.length <= 4) return '${username[0]}***';
    final prefix = username.substring(0, 2);
    final suffix = username.substring(username.length - 4);
    return '$prefix****$suffix';
  }

  static bool _equalBytes(Uint8List left, Uint8List right) {
    var difference = left.length ^ right.length;
    final length = left.length < right.length ? left.length : right.length;
    for (var index = 0; index < length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }

  static Future<void> _noop() async {}
}
