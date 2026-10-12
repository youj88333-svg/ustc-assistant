import 'package:flutter/foundation.dart';

import '../core/agenda_contract.dart';
import '../core/contracts.dart';
import '../jobs/jw_sync_port.dart';
import '../jobs/young_sync_port.dart';

enum ShellDestination { agent, agenda, settings }

enum AgendaSection { schedule, tasks }

/// C5 projection only. School account values and credentials are absent.
final class AppShellView {
  const AppShellView({
    required this.jw,
    required this.young,
    required this.globallyBusy,
    this.actionPending = false,
    this.actionFailure,
    this.progressUnavailable = false,
  });
  final JwSyncView jw;
  final YoungSyncView young;
  final bool globallyBusy;
  final bool actionPending;
  final FailureCode? actionFailure;
  final bool progressUnavailable;

  bool get accountBound =>
      jw.accountBound ||
      young.accountBound ||
      (jw.data?.accountBound ?? false) ||
      (young.data?.accountBound ?? false);
  bool get dataReady => jw.data != null && young.data != null;
  bool get credentialSaved =>
      (jw.data?.credentialSaved ?? false) ||
      (young.data?.credentialSaved ?? false);
}

/// Presentation ports reuse existing C2/C3 commands; navigating does not start
/// a job, load knowledge, access credentials, or dispose a running source.
abstract interface class AppShellPort implements Listenable {
  AppShellView get view;
  DateTime get today;
  JwSyncPort get jw;
  YoungSyncPort get young;

  AgendaSlice readAgenda({
    required DateTime day,
    AgendaFilter filter = AgendaFilter.all,
    bool includeHidden = false,
  });

  Future<void> setHidden(AgendaReference reference, {required bool hidden});
}
