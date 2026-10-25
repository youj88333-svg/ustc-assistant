part of 'jw_store.dart';

final class OnboardingStore implements OnboardingDataPort {
  OnboardingStore._(this._db);
  final JwStore _db;
  final _changes = StreamController<int>.broadcast();

  static const schema = [
    '''CREATE TABLE onboarding_state (
      singleton INTEGER PRIMARY KEY CHECK(singleton=1),
      revision INTEGER NOT NULL CHECK(revision>0),
      status TEXT NOT NULL CHECK(status IN ('active','deferred','done')),
      step TEXT NOT NULL CHECK(step IN ('account','sync','model','permissions'))
    )''',
  ];
  static const create = [
    ...schema,
    "INSERT INTO onboarding_state VALUES(1,1,'active','account')",
  ];
  static const upgrade = [
    ...schema,
    "INSERT INTO onboarding_state VALUES(1,1,'done','account')",
  ];

  @override
  Stream<int> get changes => _changes.stream;

  Future<OnboardingSnapshot> _read() async {
    final state = await _db._state();
    final row = await _db
        .customSelect('SELECT * FROM onboarding_state WHERE singleton=1')
        .getSingle();
    final owner = state.read<String>('owner_id');
    final reset = state.read<int>('reset_epoch');
    final revision = row.read<int>('revision');
    _db._validateOwner(owner);
    final status = OnboardingStatus.values.where(
      (value) => value.name == row.read<String>('status'),
    );
    final step = OnboardingStep.values.where(
      (value) => value.name == row.read<String>('step'),
    );
    if (reset < 0 || revision < 1 || status.length != 1 || step.length != 1) {
      throw const AppFailure(FailureCode.storageFailed);
    }
    return OnboardingSnapshot(
      context: OnboardingContext(
        owner: owner,
        resetEpoch: reset,
        revision: revision,
      ),
      status: status.single,
      step: step.single,
    );
  }

  @override
  Future<OnboardingSnapshot> inspect() => _db._serialized(() async {
    await _db._guard();
    return _read();
  });

  @override
  Future<OnboardingSnapshot> save(
    OnboardingContext expected, {
    required OnboardingStatus status,
    required OnboardingStep step,
  }) => _db._serialized(() async {
    final result = await _db.transaction(() async {
      await _db._guard();
      final current = await _read();
      if (current.context != expected) {
        throw const AppFailure(FailureCode.staleResult);
      }
      if (current.status == status && current.step == step) return current;
      await _db.customStatement(
        'UPDATE onboarding_state SET revision=revision+1,status=?,step=? WHERE singleton=1',
        [status.name, step.name],
      );
      _db._ownership.ensureHeld();
      return _read();
    });
    if (result.context != expected) _changes.add(result.context.revision);
    return result;
  });

  Future<void> _reset() => _db.customStatement(
    "UPDATE onboarding_state SET revision=revision+1,status='active',step='account' WHERE singleton=1",
  );

  Future<void> _signal() async =>
      _changes.add((await _read()).context.revision);
}
