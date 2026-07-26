enum ImportOrigin { bridge, file }

enum ImportStatus { imported, replayed }

class ImportResult {
  const ImportResult({
    required this.status,
    required this.bundleId,
    required this.source,
    required this.importedEntityCount,
    this.reminderReconciliationPending = false,
  });

  final ImportStatus status;
  final String bundleId;
  final String source;
  final int importedEntityCount;
  final bool reminderReconciliationPending;

  ImportResult copyWith({bool? reminderReconciliationPending}) {
    return ImportResult(
      status: status,
      bundleId: bundleId,
      source: source,
      importedEntityCount: importedEntityCount,
      reminderReconciliationPending:
          reminderReconciliationPending ?? this.reminderReconciliationPending,
    );
  }
}
