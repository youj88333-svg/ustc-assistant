import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/config/generated_source_defaults.dart';
import '../../../core/database/app_database.dart';
import '../../accounts/application/account_service.dart';

class SettingsValidationError implements Exception {
  const SettingsValidationError(this.code);

  final String code;
}

class BrowserSessionClearAfterResetError implements Exception {
  const BrowserSessionClearAfterResetError(this.cause);

  final Object cause;
}

class SettingsService {
  SettingsService({
    required this.database,
    required this.accounts,
    required this.accountId,
    Future<void> Function()? clearExternalCache,
    int Function()? now,
  }) : clearExternalCache = clearExternalCache ?? _noop,
       now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  static const automaticSyncInterval = Duration(hours: 12);
  static const defaultJwSemester = kDefaultJwSemester;

  final AppDatabase database;
  final AccountService accounts;

  /// The account partition for account-scoped settings. It is nullable for
  /// the unconfigured state so the canonical complete reset can be reached
  /// before the first login.
  final String? accountId;
  final Future<void> Function() clearExternalCache;
  final int Function() now;

  bool get hasAccount => accountId != null;

  String get _requiredAccountId {
    final id = accountId;
    if (id == null) throw StateError('active account required');
    return id;
  }

  Future<bool> sourceEnabled(String source) async {
    if (!hasAccount) return true;
    return (await _source(source))?.enabled ?? true;
  }

  Future<void> setSourceEnabled(String source, bool enabled) async {
    final accountId = _requiredAccountId;
    final existing = await _source(source);
    await database
        .into(database.sourceConfigs)
        .insertOnConflictUpdate(
          SourceConfigsCompanion.insert(
            id: existing?.id ?? '$accountId:$source',
            accountId: accountId,
            source: source,
            enabled: Value(enabled),
            configJson: Value(existing?.configJson ?? '{}'),
            lastSuccessAt: Value(existing?.lastSuccessAt),
            retryAfter: Value(existing?.retryAfter),
            updatedAt: now(),
          ),
        );
    await _log('source_toggle', 'Updated a source refresh setting.');
  }

  Future<void> setPythonPath(String? path) => _updateAppSettings(
    'pythonPath',
    path?.trim().isEmpty == true ? null : path?.trim(),
  );

  Future<String?> pythonPath() async {
    if (!hasAccount) return null;
    return (await _appSettings())['pythonPath'] as String?;
  }

  Future<void> setReminderTypeEnabled(String type, bool enabled) async {
    final settings = await _appSettings();
    final disabled = (settings['disabledReminderTypes'] as List<dynamic>? ?? [])
        .cast<String>()
        .toSet();
    enabled ? disabled.remove(type) : disabled.add(type);
    await _updateAppSettings(
      'disabledReminderTypes',
      disabled.toList()..sort(),
    );
  }

  Future<void> setJwSemesterOverride({
    int? semesterId,
    String? semesterKey,
    String? displayName,
  }) async {
    final values = [semesterId, semesterKey, displayName];
    if (values.any((value) => value == null) ||
        semesterId! < 1 ||
        semesterKey!.trim().isEmpty ||
        displayName!.trim().isEmpty) {
      throw const SettingsValidationError('complete_semester_required');
    }
    await _writeJwConfig({
      'semesterId': semesterId,
      'semesterKey': semesterKey.trim(),
      'displayName': displayName.trim(),
    });
  }

  Future<void> resetJwSemester() => _writeJwConfig(defaultJwSemester);

  Future<void> clearCache() async {
    await clearExternalCache();
    await _log('cache_clear', 'Cleared non-business caches.');
  }

  Future<void> clearCredentials({required bool confirmed}) async {
    if (!confirmed) return;
    await accounts.deleteCredentials(_requiredAccountId);
  }

  Future<void> clearBrowserSession({required bool confirmed}) async {
    if (!confirmed) return;
    await accounts.clearDedicatedBrowserSession();
  }

  Future<void> clearBusinessData({required bool confirmed}) async {
    if (!confirmed) return;
    final accountId = _requiredAccountId;
    await database.transaction(() async {
      await (database.delete(
        database.reminders,
      )..where((row) => row.accountId.equals(accountId))).go();
      await (database.delete(
        database.userOverlays,
      )..where((row) => row.accountId.equals(accountId))).go();
      await (database.delete(
        database.scheduleRelations,
      )..where((row) => row.accountId.equals(accountId))).go();
      await (database.delete(
        database.scheduleRelationRules,
      )..where((row) => row.accountId.equals(accountId))).go();
      await (database.delete(
        database.taskEventLinks,
      )..where((row) => row.accountId.equals(accountId))).go();
      await (database.delete(
        database.planBlocks,
      )..where((row) => row.accountId.equals(accountId))).go();
      await (database.delete(
        database.tasks,
      )..where((row) => row.accountId.equals(accountId))).go();
      await (database.delete(
        database.calendarEventOccurrenceExceptions,
      )..where((row) => row.accountId.equals(accountId))).go();
      await (database.delete(
        database.calendarEvents,
      )..where((row) => row.accountId.equals(accountId))).go();
      await (database.delete(
        database.calendarEventSeries,
      )..where((row) => row.accountId.equals(accountId))).go();
      await (database.delete(
        database.courseSeries,
      )..where((row) => row.accountId.equals(accountId))).go();
      await (database.delete(
        database.sourceRecords,
      )..where((row) => row.accountId.equals(accountId))).go();
      await (database.delete(
        database.syncRuns,
      )..where((row) => row.accountId.equals(accountId))).go();
      await (database.delete(
        database.importBatches,
      )..where((row) => row.accountId.equals(accountId))).go();
      await (database.delete(
        database.jwDayMoves,
      )..where((row) => row.accountId.equals(accountId))).go();
      await _log('business_data_clear', 'Cleared local business data.');
    });
  }

  Future<void> completeReset({
    required bool firstConfirmation,
    required bool secondConfirmation,
  }) async {
    if (!firstConfirmation || !secondConfirmation) return;
    // Minimal is deliberately a single-account product. A complete reset is
    // therefore global: stale/inactive partitions must not survive a re-login
    // or an unconfigured-state reset. Delete children explicitly so the
    // invariant also holds for any rows left by an older schema/migration,
    // rather than relying only on SQLite cascading foreign keys.
    await database.transaction(_clearAllLocalData);
    database.notifyActiveAccountChanged();
    try {
      await accounts.clearDedicatedBrowserSession(recordLog: false);
    } catch (error) {
      throw BrowserSessionClearAfterResetError(error);
    }
  }

  Future<void> _clearAllLocalData() async {
    // Referenced rows must be removed before their parent rows. The explicit
    // order keeps this operation valid even when foreign-key enforcement is
    // enabled and also cleans stale rows that no longer have an account row.
    await database.delete(database.reminders).go();
    await database.delete(database.taskEventLinks).go();
    await database.delete(database.scheduleRelations).go();
    await database.delete(database.userOverlays).go();
    await database.delete(database.calendarEventOccurrenceExceptions).go();
    await database.delete(database.calendarEvents).go();
    await database.delete(database.planBlocks).go();
    await database.delete(database.tasks).go();
    await database.delete(database.courseSeries).go();
    await database.delete(database.calendarEventSeries).go();
    await database.delete(database.scheduleRelationRules).go();
    await database.delete(database.jwDayMoves).go();

    await database.delete(database.chatMessages).go();
    await database.delete(database.toolInvocations).go();
    await database.delete(database.conversationSummaries).go();
    await database.delete(database.agentRuns).go();
    await database.delete(database.agentSecrets).go();
    await database.delete(database.agentSettings).go();
    await database.delete(database.agentPermissionPolicies).go();

    await database.delete(database.sourceRecords).go();
    await database.delete(database.syncRuns).go();
    await database.delete(database.importBatches).go();
    await database.delete(database.sourceConfigs).go();
    await database.delete(database.actionLogs).go();
    await database.delete(database.credentialAccounts).go();
    await database.delete(database.localAccounts).go();
    await database.delete(database.undoSlot).go();
  }

  Future<void> _writeJwConfig(Map<String, Object> config) async {
    final accountId = _requiredAccountId;
    final existing = await _source('ustc_jw');
    await database
        .into(database.sourceConfigs)
        .insertOnConflictUpdate(
          SourceConfigsCompanion.insert(
            id: existing?.id ?? '$accountId:ustc_jw',
            accountId: accountId,
            source: 'ustc_jw',
            enabled: Value(existing?.enabled ?? true),
            configJson: Value(jsonEncode(config)),
            lastSuccessAt: Value(existing?.lastSuccessAt),
            retryAfter: Value(existing?.retryAfter),
            updatedAt: now(),
          ),
        );
    await _log(
      'jw_semester_change',
      'Updated the complete JW semester setting.',
    );
  }

  Future<void> _updateAppSettings(String key, Object? value) async {
    final accountId = _requiredAccountId;
    final settings = await _appSettings();
    value == null ? settings.remove(key) : settings[key] = value;
    final existing = await _source('app_settings');
    await database
        .into(database.sourceConfigs)
        .insertOnConflictUpdate(
          SourceConfigsCompanion.insert(
            id: existing?.id ?? '$accountId:app_settings',
            accountId: accountId,
            source: 'app_settings',
            enabled: Value(existing?.enabled ?? true),
            configJson: Value(jsonEncode(settings)),
            updatedAt: now(),
          ),
        );
  }

  Future<Map<String, dynamic>> _appSettings() async {
    final row = await _source('app_settings');
    if (row == null) return {};
    final value = jsonDecode(row.configJson);
    return value is Map<String, dynamic> ? value : {};
  }

  Future<SourceConfig?> _source(String source) =>
      (database.select(database.sourceConfigs)..where(
            (row) =>
                row.accountId.equals(_requiredAccountId) &
                row.source.equals(source),
          ))
          .getSingleOrNull();

  Future<void> _log(String actionType, String summary) =>
      database.actionLogsRepository.append(
        accountId: accountId,
        source: 'system',
        actionType: actionType,
        result: 'success',
        safeSummary: summary,
        occurredAt: now(),
      );

  static Future<void> _noop() async {}
}
