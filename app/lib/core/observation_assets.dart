/// The observation ledger contains lifecycle metadata, never browser content.
abstract interface class ObservationAssetsPort {
  Future<void> recoverPending(Future<void> Function(String profilePath) drain);
  Future<String> register();
  Future<void> cleanup();
  Future<void> close();
}
