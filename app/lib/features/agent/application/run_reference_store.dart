import 'dart:convert';
import 'dart:math';

/// A per-run, in-memory store that binds raw local ids to opaque, unguessable
/// run-local reference tokens (`ref_*`).
///
/// The model never sees a raw DB id: tools hand the model `ref_*` tokens
/// obtained from [bind], and later tools (e.g. `read_campus_detail`,
/// `get_event_details`) resolve them back to the underlying local id within
/// the same run via [resolve].
///
/// References expire with the run: a fresh [RunReferenceStore] is created for
/// every run, so a `ref` bound in run 1 cannot resolve in run 2. Resolution
/// also checks the [kind], so a `ref` bound for `schedule` cannot be resolved
/// as `event`.
///
/// This class is pure Dart (no I/O) and holds only in-memory mappings. It is
/// safe to construct in tests without a database.
class RunReferenceStore {
  RunReferenceStore({required this.runId});

  /// The run this store is scoped to.
  final String runId;

  /// Maps `ref -> (kind, localId)`.
  final Map<String, _BoundRef> _byRef = {};

  /// Maps `(kind, localId) -> ref` so rebinding the same local id returns the
  /// same ref (idempotent), which keeps the model's view stable if a tool is
  /// called twice for the same entity.
  final Map<String, String> _byKindLocal = {};

  static final _random = Random.secure();

  /// Binds [localId] under [kind] and returns an opaque `ref_*` token.
  ///
  /// Idempotent: binding the same `(kind, localId)` twice returns the same
  /// ref. The returned token is unguessable (cryptographically random suffix)
  /// and contains no trace of the local id.
  String bind({required String kind, required String localId}) {
    // Use the ASCII unit separator (\x1f) as the delimiter so that distinct
    // (kind, localId) pairs like ('a','bc') and ('ab','c') cannot collide.
    // A NUL byte would achieve the same but makes the file binary to git (no
    // diff/blame); \x1f is still a control char yet keeps the file text.
    final key = '$kind\x1f$localId';
    final existing = _byKindLocal[key];
    if (existing != null) return existing;

    final ref = _generateRef();
    _byRef[ref] = _BoundRef(kind: kind, localId: localId);
    _byKindLocal[key] = ref;
    return ref;
  }

  /// Resolves [ref] back to the local id it was bound under [kind], or `null`
  /// if the ref is unknown, belongs to a different kind, or was bound in a
  /// different run (a different store instance).
  String? resolve({required String ref, required String kind}) {
    final bound = _byRef[ref];
    if (bound == null) return null;
    if (bound.kind != kind) return null;
    return bound.localId;
  }

  /// Returns whether [ref] is known to this store under any kind.
  bool knows(String ref) => _byRef.containsKey(ref);

  /// Safely resolves [ref] to its INTERNAL `(kind, localId)` binding, without
  /// the caller pre-committing to a single [kind].
  ///
  /// This is the "which kind is this ref really" API used by multi-target tools
  /// (e.g. `ref_target` for `get_reminders`, `ref_left`/`ref_right` for
  /// `get_schedule_relations`) that may bind event, task, or planblock refs.
  /// Unlike [resolve], it does not fail when the caller guesses the wrong kind —
  /// it returns whatever kind the ref was actually bound under, so the caller
  /// can then act on the real target.
  ///
  /// Security is preserved:
  /// - [allowedKinds] (default event/task/planblock) restricts which kinds are
  ///   acceptable. A ref bound under a kind outside this set resolves to null.
  /// - An unknown ref (never bound, or bound in a different run's store)
  ///   resolves to null.
  /// - The returned `(kind, localId)` is an INTERNAL identity. It is read by
  ///   the tool to locate the row; it is never placed in the model payload —
  ///   only the opaque `ref_*` token crosses that boundary.
  ///
  /// Returns null when the ref is unknown, belongs to a disallowed kind, or was
  /// bound in a different run (a different store instance).
  ({String kind, String localId})? resolveTarget(
    String ref, {
    Set<String> allowedKinds = const {'event', 'task', 'planblock'},
  }) {
    final bound = _byRef[ref];
    if (bound == null) return null;
    if (!allowedKinds.contains(bound.kind)) return null;
    return (kind: bound.kind, localId: bound.localId);
  }

  /// Generates an unguessable `ref_<base64url-random>` token. The random
  /// suffix is 16 bytes (128 bits) from [Random.secure].
  String _generateRef() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    // base64Url produces a URL-safe, compact encoding with no padding.
    final encoded = base64Url.encode(bytes).replaceAll('=', '');
    final ref = 'ref_$encoded';
    // Defensive: collision is astronomically unlikely, but guard anyway.
    if (_byRef.containsKey(ref)) return _generateRef();
    return ref;
  }
}

/// Internal record of a bound reference.
class _BoundRef {
  const _BoundRef({required this.kind, required this.localId});

  final String kind;
  final String localId;
}
