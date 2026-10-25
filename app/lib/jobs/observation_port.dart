import '../core/contracts.dart';
import '../source/observation_contract.dart';
import '../source/young_observation_contract.dart';

enum ObservationPhase { idle, opening, open, closing, recovery, closed }

final class ObservationView {
  const ObservationView({
    required this.phase,
    this.origin,
    this.ready = false,
    this.blocked = false,
    this.failure,
    this.diagnostics = const [],
    this.youngInspection,
  });
  final ObservationPhase phase;
  final String? origin;
  final bool ready;
  final bool blocked;
  final FailureCode? failure;
  final List<BrowserDiagnostic> diagnostics;
  final YoungPageInspection? youngInspection;
  bool get isBusy =>
      phase != ObservationPhase.idle && phase != ObservationPhase.closed;
}

abstract interface class ObservationPort {
  ObservationView get view;
  Stream<ObservationView> get changes;
  Future<void> open();
  Future<void> inspect();
  Future<void> navigateInitial();
  Future<void> navigateJwPage(JwObservationPage page);
  Future<void> closeSession();
  Future<void> retryCleanup();
}

abstract interface class YoungObservationPort implements ObservationPort {
  Future<void> inspectYoungPage();
}
