import '../source/young_active_contract.dart';
import 'observation_port.dart';

abstract interface class YoungBusinessProbePort
    implements YoungObservationPort {
  YoungBusinessView get businessView;

  Stream<YoungBusinessView> get businessChanges;

  Future<void> probeYoungActivities(String expectedAccountCode);

  Future<void> probeYoungCalendar({
    required String expectedAccountCode,
    required DateTime firstDay,
    required DateTime lastDay,
  });

  Future<void> cancelYoungBusinessProbe();

  Future<void> navigateYoungPage(YoungBusinessPage page);
}
