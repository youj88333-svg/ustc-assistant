import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';

class HistoryFilter {
  const HistoryFilter({
    this.from,
    this.through,
    this.source,
    this.actionType,
    this.result,
  });

  final int? from;
  final int? through;
  final String? source;
  final String? actionType;
  final String? result;
}

/// The maximum number of history entries returned to a read-only Agent tool.
///
/// Enforced inside the database query (not in Dart) so the account-scoped
/// query never fetches more than this many rows before sanitizing.
const int agentHistoryLimit = 50;

class HistoryEntry {
  const HistoryEntry({
    required this.id,
    required this.source,
    required this.actionType,
    required this.result,
    required this.safeSummary,
    required this.occurredAt,
  });

  final String id;
  final String source;
  final String actionType;
  final String result;
  final String safeSummary;
  final int occurredAt;
}

class HistoryRepository {
  const HistoryRepository(this.database);

  final AppDatabase database;

  /// Reads the action log for [accountId], scoped to that account inside the
  /// database query (before sanitizing), capped at [agentHistoryLimit] rows
  /// ordered newest-first.
  ///
  /// [accountId] is required: an unscoped history query would surface other
  /// accounts' safe summaries, which is a privacy bug. Rows with a null
  /// `account_id` (e.g. legacy/anonymous logs) are excluded by the DB filter.
  ///
  /// The optional [filter] further narrows by time range, source, action type
  /// and result; those predicates are also pushed into the DB query. Sanitizing
  /// runs after the fetch, on the already-scoped rows.
  Future<List<HistoryEntry>> query(
    String accountId, {
    HistoryFilter filter = const HistoryFilter(),
  }) async {
    final query = database.select(database.actionLogs)
      ..where((row) => row.accountId.equals(accountId))
      ..orderBy([(row) => OrderingTerm.desc(row.occurredAt)])
      ..limit(agentHistoryLimit);
    if (filter.from != null) {
      query.where((row) => row.occurredAt.isBiggerOrEqualValue(filter.from!));
    }
    if (filter.through != null) {
      query.where((row) => row.occurredAt.isSmallerOrEqualValue(filter.through!));
    }
    if (filter.source != null) {
      query.where((row) => row.source.equals(filter.source!));
    }
    if (filter.actionType != null) {
      query.where((row) => row.actionType.equals(filter.actionType!));
    }
    if (filter.result != null) {
      query.where((row) => row.result.equals(filter.result!));
    }
    final rows = await query.get();
    return rows
        .map(
          (row) => HistoryEntry(
            id: row.id,
            source: _sanitize(row.source),
            actionType: _sanitize(row.actionType),
            result: _sanitize(row.result),
            safeSummary: _sanitize(row.safeSummary, summary: true),
            occurredAt: row.occurredAt,
          ),
        )
        .toList(growable: false);
  }

  static final _sensitive = RegExp(
    r'authorization|bearer\s|password|passwd|cookie|token|username|secret|PB\d{6,}',
    caseSensitive: false,
  );

  static String _sanitize(String value, {bool summary = false}) {
    if (_sensitive.hasMatch(value)) {
      return summary ? 'Sensitive operation details hidden.' : 'redacted';
    }
    return value;
  }
}
