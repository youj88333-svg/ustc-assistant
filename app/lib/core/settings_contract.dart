/// Fixed local settings and maintenance capabilities. No URL, SQL, path,
/// account code or credential value is accepted by this interface.
library;

enum DefaultCalendarView { day, week }

final class DisplayPreferences {
  const DisplayPreferences({
    this.calendarView = DefaultCalendarView.week,
    this.includeInactive = false,
  });
  final DefaultCalendarView calendarView;
  final bool includeInactive;
  @override
  bool operator ==(Object other) =>
      other is DisplayPreferences &&
      calendarView == other.calendarView &&
      includeInactive == other.includeInactive;
  @override
  int get hashCode => Object.hash(calendarView, includeInactive);
}

/// Opaque local guard carried by confirmations, never a diagnostic payload.
final class SettingsContext {
  const SettingsContext({
    required this.owner,
    required this.resetEpoch,
    required this.agendaEpoch,
    required this.revision,
  });
  final String owner;
  final int resetEpoch, agendaEpoch, revision;
  @override
  bool operator ==(Object other) =>
      other is SettingsContext &&
      owner == other.owner &&
      resetEpoch == other.resetEpoch &&
      agendaEpoch == other.agendaEpoch &&
      revision == other.revision;
  @override
  int get hashCode => Object.hash(owner, resetEpoch, agendaEpoch, revision);
  @override
  String toString() => 'SettingsContext';
}

final class LocalDataCounts {
  const LocalDataCounts({
    this.jwCourses = 0,
    this.jwExams = 0,
    this.young = 0,
    this.personal = 0,
    this.tasks = 0,
    this.blocks = 0,
    this.materials = 0,
  });
  final int jwCourses, jwExams, young, personal, tasks, blocks, materials;
}

final class SettingsSnapshot {
  const SettingsSnapshot({
    required this.context,
    required this.preferences,
    required this.counts,
    required this.accountBound,
    required this.credentialSaved,
    required this.icourseConsent,
  });
  final SettingsContext context;
  final DisplayPreferences preferences;
  final LocalDataCounts counts;
  final bool accountBound, credentialSaved, icourseConsent;
}

enum MaintenanceKind { agenda, reset }

enum MaintenancePhase {
  idle,
  preparing,
  cleaning,
  committing,
  refreshing,
  recovery,
}

enum SettingsFailureCode {
  busy,
  staleContext,
  confirmationRequired,
  invalidIntent,
  storageFailed,
  cleanupPending,
  ownershipLost,
  closed,
}

final class SettingsFailure implements Exception {
  const SettingsFailure(this.code);
  final SettingsFailureCode code;
  @override
  String toString() => 'SettingsFailure(${code.name})';
}

final class MaintenanceProgress {
  const MaintenanceProgress({
    this.phase = MaintenancePhase.idle,
    this.kind,
    this.failure,
    this.committed = false,
    this.activating = false,
  });
  final MaintenancePhase phase;
  final MaintenanceKind? kind;
  final SettingsFailureCode? failure;
  final bool committed, activating;
  bool get blocksProduct => phase != MaintenancePhase.idle;
}

final class PreferencesWrite {
  const PreferencesWrite({
    required this.operationId,
    required this.context,
    required this.preferences,
  });
  final String operationId;
  final SettingsContext context;
  final DisplayPreferences preferences;
  @override
  String toString() => 'PreferencesWrite';
}

/// Issued by C3 after a confirmed, current fixed-scope request.
final class MaintenanceRequest {
  const MaintenanceRequest({
    required this.operationId,
    required this.context,
    required this.kind,
    required this.intentFingerprint,
  });
  final String operationId, intentFingerprint;
  final SettingsContext context;
  final MaintenanceKind kind;
  @override
  String toString() => 'MaintenanceRequest';
}

/// Persisted pending intent; retry does not mint a new operation or epoch.
final class MaintenanceIntent {
  const MaintenanceIntent({required this.request, required this.targetContext});
  final MaintenanceRequest request;
  final SettingsContext targetContext;
  MaintenanceKind get kind => request.kind;
  @override
  String toString() => 'MaintenanceIntent';
}

final class SettingsWriteReceipt {
  const SettingsWriteReceipt({
    required this.operationId,
    required this.context,
    this.replayed = false,
  });
  final String operationId;
  final SettingsContext context;
  final bool replayed;
  @override
  String toString() => 'SettingsWriteReceipt';
}

/// C3 owns preferences, fixed deletion scope, durable intent and SQL receipts.
/// Bootstrap only validates recovery metadata; it grants no ordinary writes.
abstract interface class ApplicationSettingsDataPort {
  Stream<int> get changes;
  Future<MaintenanceIntent?> bootstrapMaintenance();
  Future<SettingsSnapshot> inspectSettings();
  Future<SettingsWriteReceipt> savePreferences(PreferencesWrite write);
  Future<MaintenanceRequest> prepareMaintenance(
    SettingsContext context,
    MaintenanceKind kind, {
    required bool confirmed,
  });
  Future<MaintenanceIntent> beginMaintenance(MaintenanceRequest request);
  Future<SettingsWriteReceipt> completeMaintenance(MaintenanceIntent intent);
}
