import '../source/young_read_only_contract.dart';
import 'observation_port.dart';

abstract interface class YoungReadOnlyObservationPort
    implements YoungObservationPort {
  YoungReadOnlyInspection? get readOnlyInspection;
  Stream<YoungReadOnlyInspection?> get readOnlyChanges;
  Future<void> startReadOnlyInspection();
  Future<void> refreshReadOnlyInspection();
  Future<void> stopReadOnlyInspection();
}
