class UndoCommand {
  const UndoCommand({
    required this.kind,
    required this.accountId,
    required this.payload,
    this.version = 1,
    this.safeSummary,
  });

  final int version;
  final String kind;
  final String accountId;
  final Map<String, Object?> payload;

  /// An optional safe, human-readable (Chinese) summary of the undone action.
  /// Exposed through the account-safe preview path; never carries a DB id, ref,
  /// account identity, or raw exception text.
  final String? safeSummary;
}

abstract interface class UndoRecorder {
  Future<void> record(UndoCommand command);
}

class NoopUndoRecorder implements UndoRecorder {
  const NoopUndoRecorder();

  @override
  Future<void> record(UndoCommand command) async {}
}
