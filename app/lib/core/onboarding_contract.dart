/// Installation-local navigation only. This state never grants permission or
/// proves school identity, a completed import, or model readiness.
library;

enum OnboardingStatus { active, deferred, done }

enum OnboardingStep { account, sync, model, permissions }

final class OnboardingContext {
  const OnboardingContext({
    required this.owner,
    required this.resetEpoch,
    required this.revision,
  });
  final String owner;
  final int resetEpoch, revision;

  @override
  bool operator ==(Object other) =>
      other is OnboardingContext &&
      owner == other.owner &&
      resetEpoch == other.resetEpoch &&
      revision == other.revision;
  @override
  int get hashCode => Object.hash(owner, resetEpoch, revision);
  @override
  String toString() => 'OnboardingContext';
}

final class OnboardingSnapshot {
  const OnboardingSnapshot({
    required this.context,
    required this.status,
    required this.step,
  });
  final OnboardingContext context;
  final OnboardingStatus status;
  final OnboardingStep step;
}

abstract interface class OnboardingDataPort {
  Stream<int> get changes;
  Future<OnboardingSnapshot> inspect();

  /// Carries a current local guard. Only this small progress record changes;
  /// business results and consent remain under their existing domain ports.
  Future<OnboardingSnapshot> save(
    OnboardingContext expected, {
    required OnboardingStatus status,
    required OnboardingStep step,
  });
}
