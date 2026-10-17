import 'package:flutter/foundation.dart';

import '../core/settings_contract.dart';
import '../core/knowledge_contract.dart';

export '../core/settings_contract.dart';

final class ApplicationSettingsView {
  const ApplicationSettingsView({
    this.snapshot,
    this.loading = false,
    this.actionPending = false,
    this.knowledgeLoading = false,
    this.progressUnavailable = false,
    this.maintenance = const MaintenanceProgress(),
    this.browserCleanupPendingCount,
    this.failure,
    this.loadOutcome,
  });
  final SettingsSnapshot? snapshot;
  final bool loading, actionPending, knowledgeLoading, progressUnavailable;
  final MaintenanceProgress maintenance;

  /// Null means this platform has no isolated old-profile cleanup capability.
  final int? browserCleanupPendingCount;
  final SettingsFailureCode? failure;
  final KnowledgeLoadOutcome? loadOutcome;
  bool get canWrite =>
      snapshot != null &&
      !loading &&
      !actionPending &&
      !knowledgeLoading &&
      !progressUnavailable &&
      !maintenance.blocksProduct;
}

/// C5 projects settings and confirmed actions through the same local ports.
abstract interface class ApplicationSettingsPort implements Listenable {
  ApplicationSettingsView get settingsView;
  Future<void> refreshSettings();
  Future<void> saveDisplayPreferences(
    SettingsContext context,
    DisplayPreferences preferences,
  );
  Future<void> runMaintenance(
    SettingsContext context,
    MaintenanceKind kind, {
    required bool confirmed,
  });
  Future<void> retryMaintenance();
  Future<void> retryBrowserCleanup();
  Future<void> loadKnowledge();
  Future<void> cancelKnowledgeLoad();
  Future<void> clearKnowledge(
    SettingsContext context, {
    required bool confirmed,
  });
  Future<void> setIcourseConsent(
    SettingsContext context, {
    required bool allowed,
    required bool confirmed,
  });
}
