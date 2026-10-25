import 'dart:convert';

import 'package:crypto/crypto.dart';

abstract interface class AppClock {
  DateTime get nowUtc;
}

final class SystemClock implements AppClock {
  const SystemClock();

  @override
  DateTime get nowUtc => DateTime.now().toUtc();
}

final class FixedClock implements AppClock {
  FixedClock(DateTime value) : nowUtc = value.toUtc();

  @override
  final DateTime nowUtc;
}

/// A local demo context, never a school account or authentication proof.
final class JobStamp {
  const JobStamp({
    required this.jobId,
    required this.localContext,
    required this.sourceKey,
    required this.contractVersion,
    required this.generation,
    required this.resetEpoch,
  });

  final String jobId;
  final String localContext;
  final String sourceKey;
  final String contractVersion;
  final int generation;
  final int resetEpoch;
}

enum FailureCode {
  busy,
  cancelled,
  staleResult,
  incompleteSnapshot,
  invalidSnapshot,
  idempotencyConflict,
  sourceFailed,
  storageFailed,
  cleanupPending,
  followUpPending,
  ownerConflict,
  unsafeDirectory,
  ownershipLost,
  unsupportedPlatform,
  closed,
}

final class AppFailure implements Exception {
  const AppFailure(this.code);

  final FailureCode code;

  @override
  String toString() => 'AppFailure(${code.name})';
}

abstract interface class AssetOwnership {
  bool get isHeld;
  void ensureHeld();
}

String fingerprint(Object payload) =>
    sha256.convert(utf8.encode(jsonEncode(payload))).toString();

String formatBeijing(DateTime utc) {
  final value = utc.toUtc().add(const Duration(hours: 8));
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}
