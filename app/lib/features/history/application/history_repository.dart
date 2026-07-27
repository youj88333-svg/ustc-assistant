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

  Future<List<HistoryEntry>> query([
    HistoryFilter filter = const HistoryFilter(),
  ]) async {
    final rows = await database.actionLogsRepository.selectAll();
    return rows
        .where(
          (row) =>
              (filter.from == null || row.occurredAt >= filter.from!) &&
              (filter.through == null || row.occurredAt <= filter.through!) &&
              (filter.source == null || row.source == filter.source) &&
              (filter.actionType == null ||
                  row.actionType == filter.actionType) &&
              (filter.result == null || row.result == filter.result),
        )
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
