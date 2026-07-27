class UndoCommand {
  const UndoCommand({
    required this.kind,
    required this.accountId,
    required this.payload,
    this.version = 1,
  });

  final int version;
  final String kind;
  final String accountId;
  final Map<String, Object?> payload;
}

abstract interface class UndoRecorder {
  Future<void> record(UndoCommand command);
}

class NoopUndoRecorder implements UndoRecorder {
  const NoopUndoRecorder();

  @override
  Future<void> record(UndoCommand command) async {}
}
