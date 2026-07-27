import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../accounts/application/account_service.dart';

class SettingsValidationError implements Exception {
  const SettingsValidationError(this.code);

  final String code;
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
  static const defaultJwSemester = {
    'semesterId': 421,
    'semesterKey': '2026spring',
    'displayName': '2026 春季学期',
  };

  final AppDatabase database;
  final AccountService accounts;
  final String accountId;
  final Future<void> Function() clearExternalCache;
  final int Function() now;

  Future<bool> sourceEnabled(String source) async =>
      (await _source(source))?.enabled ?? true;

  Future<void> setSourceEnabled(String source, bool enabled) async {
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

  Future<String?> pythonPath() async =>
      (await _appSettings())['pythonPath'] as String?;

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
    await accounts.deleteCredentials(accountId);
  }

  Future<void> clearBrowserSession({required bool confirmed}) async {
    if (!confirmed) return;
    await accounts.clearDedicatedBrowserSession();
  }

  Future<void> clearBusinessData({required bool confirmed}) async {
    if (!confirmed) return;
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
      await _log('business_data_clear', 'Cleared local business data.');
    });
  }

  Future<void> completeReset({
    required bool firstConfirmation,
    required bool secondConfirmation,
  }) async {
    if (!firstConfirmation || !secondConfirmation) return;
    await clearBusinessData(confirmed: true);
    await clearCredentials(confirmed: true);
    await clearBrowserSession(confirmed: true);
  }

  Future<void> _writeJwConfig(Map<String, Object> config) async {
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
                row.accountId.equals(accountId) & row.source.equals(source),
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
