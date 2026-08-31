import 'dart:convert';

import 'package:crypto/crypto.dart';
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

/// In-memory state for a first-login attempt.
///
/// A provisional account id is only a partition key for the active browser
/// session.  It is deliberately not persisted until the verified identity and
/// the complete source bundle are committed together.
final class ProvisionalFirstLogin extends ProvisionalAccount {
  ProvisionalFirstLogin({
    required String accountId,
    required this.expectedUsername,
    this.passwordBytes,
    this.savePassword = false,
  }) : super(accountId);

  final String expectedUsername;
  Uint8List? passwordBytes;
  final bool savePassword;

  /// Clears the only mutable plaintext secret owned by this object.
  void discard() {
    final bytes = passwordBytes;
    if (bytes != null) {
      bytes.fillRange(0, bytes.length, 0);
      passwordBytes = null;
    }
  }
}

class AccountSummary {
  const AccountSummary({
    required this.id,
    required this.maskedHint,
    required this.active,
    required this.hasCredentials,
    required this.hasSavedPassword,
    this.jwLastSuccessAt,
  });

  final String id;
  final String maskedHint;
  final bool active;
  final bool hasCredentials;
  final bool hasSavedPassword;
  final int? jwLastSuccessAt;
}

class _StagedLogin {
  _StagedLogin({
    required this.accountId,
    required this.username,
    required this.password,
    required this.savePassword,
    this.fixedAccount = false,
  });

  final String accountId;
  String? username;
  String? password;
  final bool savePassword;
  final bool fixedAccount;

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
  ProvisionalFirstLogin? _stagedFirstLogin;

  ProvisionalFirstLogin beginFirstLogin({
    String expectedUsername = '',
    Uint8List? passwordBytes,
    bool savePassword = false,
  }) => ProvisionalFirstLogin(
    accountId: _uuid.v4(),
    expectedUsername: expectedUsername,
    passwordBytes: passwordBytes,
    savePassword: savePassword,
  );

  void cancelFirstLogin(Object provisional) {
    if (provisional is ProvisionalFirstLogin) {
      provisional.discard();
      if (identical(_stagedFirstLogin, provisional)) {
        _stagedFirstLogin = null;
      }
      return;
    }
    if (provisional is! ProvisionalAccount) return;
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
    bool fixedAccount = false,
  }) async {
    final normalized = username.trim();
    if (normalized.isEmpty) {
      throw const AccountVerificationError('blank_username');
    }
    _stagedFirstLogin?.discard();
    _stagedFirstLogin = null;
    _staged?.discard();
    final session = provisional ?? ProvisionalAccount(_uuid.v4());
    _staged = _StagedLogin(
      accountId: session.accountId,
      username: normalized,
      password: password,
      savePassword: savePassword,
      fixedAccount: fixedAccount,
    );
    return session;
  }

  /// Stages first-login secrets in memory only.  The account row and
  /// credentials are created by [FirstLoginCommitService] after the verified
  /// source bundle is prepared.
  Future<ProvisionalFirstLogin> stageFirstLogin({
    required String username,
    String? password,
    bool savePassword = false,
    ProvisionalFirstLogin? provisional,
  }) async {
    final normalized = username.trim();
    if (normalized.isEmpty) {
      throw const AccountVerificationError('blank_username');
    }
    _staged?.discard();
    _staged = null;
    _stagedFirstLogin?.discard();
    final session =
        provisional ??
        beginFirstLogin(
          expectedUsername: normalized,
          savePassword: savePassword,
        );
    if (session.expectedUsername.trim().isNotEmpty &&
        session.expectedUsername.trim() != normalized) {
      session.discard();
      throw const AccountVerificationError('identity_mismatch');
    }
    if (session.expectedUsername.trim().isEmpty) {
      // The expected username is immutable on the public provisional object;
      // callers should normally let this method create it.  Rejecting an
      // empty externally-created value keeps the commit identity check strict.
      session.discard();
      throw const AccountVerificationError('blank_username');
    }
    if (password != null) {
      session.discard();
      session.passwordBytes = Uint8List.fromList(utf8.encode(password));
    }
    _stagedFirstLogin = session;
    return session;
  }

  Future<ProvisionalAccount> stageReauthentication({
    required String accountId,
    required String username,
    String? password,
    bool savePassword = false,
  }) async {
    final account = await (database.select(
      database.localAccounts,
    )..where((row) => row.id.equals(accountId))).getSingleOrNull();
    if (account == null) {
      throw const AccountVerificationError('account_not_found');
    }
    final normalized = username.trim();
    if (normalized.isEmpty) {
      throw const AccountVerificationError('blank_username');
    }
    final expectedDigest = account.identityDigest;
    if (expectedDigest == null) {
      throw const AccountVerificationError('account_identity_missing');
    }
    if (!_equalText(expectedDigest, _identityDigest(normalized))) {
      throw const AccountVerificationError('identity_mismatch');
    }
    return stageLogin(
      username: normalized,
      password: password,
      savePassword: savePassword,
      provisional: ProvisionalAccount(accountId),
      fixedAccount: true,
    );
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
      final existingId = staged.fixedAccount
          ? staged.accountId
          : await accountIdFor(verified);
      final accountId = existingId ?? staged.accountId;
      if (staged.fixedAccount) {
        final account = await (database.select(
          database.localAccounts,
        )..where((row) => row.id.equals(accountId))).getSingleOrNull();
        if (account == null ||
            account.identityDigest == null ||
            !_equalText(account.identityDigest!, _identityDigest(verified))) {
          throw const AccountVerificationError('identity_mismatch');
        }
      }
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
                identityDigest: Value(_identityDigest(verified)),
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
      database.notifyActiveAccountChanged();
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
    database.notifyActiveAccountChanged();
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
          hasCredentials: byId.containsKey(account.id),
          hasSavedPassword: byId[account.id]?.passwordCiphertext != null,
          jwLastSuccessAt: syncByAccountAndSource['${account.id}\u0000ustc_jw'],
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

  Future<bool> hasCredentials(String accountId) async =>
      await (database.select(
        database.credentialAccounts,
      )..where((row) => row.accountId.equals(accountId))).getSingleOrNull() !=
      null;

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

  String stagedUsernameForSync(Object provisional) {
    if (provisional is ProvisionalFirstLogin) {
      final staged = _stagedFirstLogin;
      if (staged == null ||
          !identical(staged, provisional) ||
          staged.expectedUsername.trim().isEmpty) {
        throw const AccountVerificationError('no_staged_login');
      }
      return staged.expectedUsername.trim();
    }
    if (provisional is! ProvisionalAccount) {
      throw const AccountVerificationError('no_staged_login');
    }
    final staged = _requireStaged(provisional);
    return staged.username!;
  }

  String? stagedPasswordForInteractiveLogin(Object provisional) {
    if (provisional is ProvisionalFirstLogin) {
      final staged = _stagedFirstLogin;
      if (staged == null || !identical(staged, provisional)) {
        throw const AccountVerificationError('no_staged_login');
      }
      final bytes = staged.passwordBytes;
      return bytes == null ? null : utf8.decode(bytes);
    }
    if (provisional is! ProvisionalAccount) {
      throw const AccountVerificationError('no_staged_login');
    }
    return _requireStaged(provisional).password;
  }

  Future<void> deleteCredentials(String accountId) async {
    await _ensureIdentityDigest(accountId);
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

  Future<void> clearDedicatedBrowserSession({bool recordLog = true}) async {
    await clearBrowserSession();
    if (recordLog) {
      await _log(
        'browser_session_cleared',
        'Cleared the dedicated browser session.',
        now(),
      );
    }
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

  Future<void> _ensureIdentityDigest(String accountId) async {
    final account = await (database.select(
      database.localAccounts,
    )..where((row) => row.id.equals(accountId))).getSingleOrNull();
    if (account == null) {
      throw const AccountVerificationError('account_not_found');
    }
    if (account.identityDigest != null) return;
    final credential = await _credential(accountId);
    final plaintext = await protector.unprotect(_usernameSecret(credential));
    try {
      final username = utf8.decode(plaintext);
      await (database.update(
        database.localAccounts,
      )..where((row) => row.id.equals(accountId))).write(
        LocalAccountsCompanion(
          identityDigest: Value(_identityDigest(username)),
          updatedAt: Value(now()),
        ),
      );
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
    }
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

  static bool _equalText(String left, String right) => _equalBytes(
    Uint8List.fromList(utf8.encode(left)),
    Uint8List.fromList(utf8.encode(right)),
  );

  static String _identityDigest(String username) =>
      sha256.convert(utf8.encode(username.trim())).toString();

  static Future<void> _noop() async {}
}
