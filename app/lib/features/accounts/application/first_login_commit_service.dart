import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/security/credential_protector.dart';
import 'account_service.dart';
import '../../import/application/import_service.dart';
import '../../import/application/reminder_reconciler.dart';
import '../../import/domain/import_result.dart';

export 'account_service.dart' show ProvisionalFirstLogin;
export '../../import/application/import_service.dart' show PreparedSourceBundle;

// Constructor aliases intentionally resolve dependencies from either the
// account facade or explicit test seams.
// ignore_for_file: prefer_initializing_formals

typedef PreparedBundlePersist =
    Future<ImportResult> Function(
      PreparedSourceBundle prepared, {
      required String accountId,
      required ImportOrigin origin,
    });

final class FirstLoginCommitResult {
  const FirstLoginCommitResult({
    required this.accountId,
    required this.importResult,
  });

  final String accountId;
  final ImportResult importResult;

  /// Short aliases keep the result convenient for sync and acceptance code
  /// without exposing any credential or source payload.
  ImportResult get result => importResult;
  ImportStatus get status => importResult.status;
  String get bundleId => importResult.bundleId;
  String get source => importResult.source;
  int get importedEntityCount => importResult.importedEntityCount;
  bool get reminderReconciliationPending =>
      importResult.reminderReconciliationPending;
}

/// Atomically commits a verified first-login identity and its complete JW
/// snapshot.  The supplied persistence callback must use the transaction
/// already opened here; it must not open a nested transaction.
final class FirstLoginCommitService {
  FirstLoginCommitService({
    AppDatabase? database,
    CredentialProtector? protector,
    AccountService? accounts,
    AccountService? accountService,
    PreparedBundlePersist? persistPrepared,
    PreparedBundlePersist? preparedBundlePersist,
    ImportService? importService,
    ReminderReconciler? reminderReconciler,
    Future<void> Function({required String accountId, required String source})?
    reconcileReminders,
    int Function()? now,
  }) : _database = database ?? accounts?.database ?? accountService?.database,
       _protector =
           protector ?? accounts?.protector ?? accountService?.protector,
       _persistPrepared =
           persistPrepared ??
           preparedBundlePersist ??
           importService?.persistPrepared,
       _accounts = accounts ?? accountService,
       _importService = importService,
       _reminderReconciler = reminderReconciler,
       _reconcileReminders = reconcileReminders,
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final AppDatabase? _database;
  final CredentialProtector? _protector;
  final PreparedBundlePersist? _persistPrepared;
  final AccountService? _accounts;
  final ImportService? _importService;
  final ReminderReconciler? _reminderReconciler;
  final Future<void> Function({
    required String accountId,
    required String source,
  })?
  _reconcileReminders;
  final int Function() _now;

  Future<FirstLoginCommitResult> commit({
    required ProvisionalFirstLogin provisional,
    required String verifiedUsername,
    required PreparedSourceBundle prepared,
    bool Function()? cancellationRequested,
  }) async {
    try {
      final verified = verifiedUsername.trim();
      final expected = provisional.expectedUsername.trim();
      if (expected.isEmpty || verified.isEmpty || verified != expected) {
        throw const AccountVerificationError('identity_mismatch');
      }

      final database = _database;
      final protector = _protector;
      final persist = _persistPrepared;
      if (database == null || protector == null || persist == null) {
        throw StateError('first-login commit is not fully configured');
      }

      // Validate the SourceBundle subject before opening the transaction.  It
      // is also checked by persistPrepared, which protects the caller-owned
      // transaction if a custom persistence callback is injected.
      prepared.bundle.requireSubject(provisional.accountId);
      _throwIfCancelled(cancellationRequested);

      final result = await database.transaction(() async {
        final timestamp = _now();
        final digest = _identityDigest(verified);
        final existing =
            await (database.select(database.localAccounts)
                  ..where((row) => row.id.equals(provisional.accountId)))
                .getSingleOrNull();
        if (existing != null &&
            existing.identityDigest != null &&
            existing.identityDigest != digest) {
          throw const AccountVerificationError('identity_mismatch');
        }

        final usernameBytes = Uint8List.fromList(utf8.encode(verified));
        ProtectedSecret? usernameSecret;
        ProtectedSecret? passwordSecret;
        Uint8List? usernameCiphertext;
        Uint8List? passwordCiphertext;
        try {
          usernameSecret = await protector.protect(usernameBytes);
          final passwordBytes = provisional.passwordBytes;
          if (provisional.savePassword && passwordBytes != null) {
            passwordSecret = await protector.protect(passwordBytes);
            if (passwordSecret.scheme != usernameSecret.scheme ||
                passwordSecret.version != usernameSecret.version) {
              throw const CredentialProtectionException('inconsistent_scheme');
            }
          }
          _throwIfCancelled(cancellationRequested);

          usernameCiphertext = Uint8List.fromList(usernameSecret.bytes);
          passwordCiphertext = passwordSecret == null
              ? null
              : Uint8List.fromList(passwordSecret.bytes);

          // First login is the only account admission path in the minimal
          // app.  Deactivate any stale row before publishing this one, while
          // retaining all of the operation inside the same rollback boundary.
          await database
              .update(database.localAccounts)
              .write(
                LocalAccountsCompanion(
                  isActive: const Value(false),
                  updatedAt: Value(timestamp),
                ),
              );
          await database
              .into(database.localAccounts)
              .insertOnConflictUpdate(
                LocalAccountsCompanion.insert(
                  id: provisional.accountId,
                  maskedHint: _maskedHint(verified),
                  identityDigest: Value(digest),
                  isActive: const Value(true),
                  createdAt: existing?.createdAt ?? timestamp,
                  updatedAt: timestamp,
                ),
              );
          await database
              .into(database.credentialAccounts)
              .insertOnConflictUpdate(
                CredentialAccountsCompanion.insert(
                  accountId: provisional.accountId,
                  usernameCiphertext: usernameCiphertext,
                  passwordCiphertext: Value(passwordCiphertext),
                  scheme: usernameSecret.scheme,
                  protectionVersion: Value(usernameSecret.version),
                  protectionMetadata: Value(
                    jsonEncode(usernameSecret.metadata),
                  ),
                  updatedAt: timestamp,
                ),
              );
          await database.actionLogsRepository.append(
            accountId: provisional.accountId,
            source: 'system',
            actionType: 'credential_saved',
            result: 'success',
            safeSummary: 'Stored protected school account credentials.',
            occurredAt: timestamp,
          );
        } finally {
          _zero(usernameBytes);
          _zero(usernameCiphertext);
          _zero(passwordCiphertext);
          _zero(usernameSecret?.bytes);
          _zero(passwordSecret?.bytes);
        }

        final persisted = await persist(
          prepared,
          accountId: provisional.accountId,
          origin: ImportOrigin.bridge,
        );
        _throwIfCancelled(cancellationRequested);
        return persisted;
      });
      database.notifyActiveAccountChanged();

      final reconciled = await _reconcileAfterCommit(
        result,
        accountId: provisional.accountId,
      );
      return FirstLoginCommitResult(
        accountId: provisional.accountId,
        importResult: reconciled,
      );
    } finally {
      provisional.discard();
      _accounts?.cancelFirstLogin(provisional);
    }
  }

  Future<ImportResult> _reconcileAfterCommit(
    ImportResult result, {
    required String accountId,
  }) async {
    try {
      final callback = _reconcileReminders;
      if (callback != null) {
        await callback(accountId: accountId, source: result.source);
      } else if (_reminderReconciler != null) {
        await _reminderReconciler.reconcile(
          accountId: accountId,
          source: result.source,
        );
      } else if (_importService != null) {
        return _importService.reconcileAfterCommit(
          result,
          accountId: accountId,
        );
      }
      return result;
    } catch (_) {
      final database = _database;
      if (database != null) {
        await database.actionLogsRepository.append(
          accountId: accountId,
          source: result.source,
          actionType: 'reminder_reconcile',
          result: 'retryable_failure',
          safeSummary: 'Reminder reconciliation is pending.',
          occurredAt: _now(),
        );
      }
      return result.copyWith(reminderReconciliationPending: true);
    }
  }

  static String _maskedHint(String username) {
    if (username.length <= 4) return '${username[0]}***';
    final prefix = username.substring(0, 2);
    final suffix = username.substring(username.length - 4);
    return '$prefix****$suffix';
  }

  static String _identityDigest(String username) =>
      sha256.convert(utf8.encode(username.trim())).toString();

  static void _zero(Uint8List? bytes) {
    if (bytes != null) bytes.fillRange(0, bytes.length, 0);
  }

  static void _throwIfCancelled(bool Function()? cancellationRequested) {
    if (cancellationRequested?.call() == true) {
      throw StateError('first_login_cancelled');
    }
  }
}
