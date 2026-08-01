import '../../../core/database/app_database.dart';

/// A whole-day move of `ustc_jw` course events from [sourceDate] to
/// [targetDate] (Beijing calendar dates, YYYY-MM-DD). See Spec section 10.2.
///
/// The record is account-scoped, carries NO semester id, event id list or
/// external identity, and `(accountId, sourceDate)` is unique. Projection
/// matches events by their RAW source date, never by the shifted display
/// date, so A->B followed by B->C only moves B-native courses and a move
/// survives occurrence removal/reappearance.
class JwDayMove {
  const JwDayMove({
    required this.id,
    required this.accountId,
    required this.sourceDate,
    required this.targetDate,
    required this.createdAt,
    required this.updatedAt,
  });

  factory JwDayMove.fromRecord(JwDayMoveRecord record) => JwDayMove(
    id: record.id,
    accountId: record.accountId,
    sourceDate: record.sourceDate,
    targetDate: record.targetDate,
    createdAt: record.createdAt,
    updatedAt: record.updatedAt,
  );

  final String id;
  final String accountId;
  final String sourceDate;
  final String targetDate;
  final int createdAt;
  final int updatedAt;
}

/// The result of a whole-day move preview for one source date: the eligible
/// course titles (never ids) and the existing target date when a move record
/// is already present. `courses` is empty when nothing is eligible.
class JwDayMovePreview {
  const JwDayMovePreview({
    required this.sourceDate,
    this.targetDate,
    required this.courses,
  });

  final String sourceDate;
  final String? targetDate;
  final List<String> courses;
}

/// The source date has no eligible `ustc_jw/course` timed events.
class NoEligibleJwCourses implements Exception {
  const NoEligibleJwCourses(this.sourceDate);

  final String sourceDate;

  @override
  String toString() => 'NoEligibleJwCourses: $sourceDate';
}

/// The source and target dates are the same.
class InvalidDayMoveDates implements Exception {
  const InvalidDayMoveDates();

  @override
  String toString() => 'InvalidDayMoveDates: source date equals target date';
}

/// Clearing a source date that has no move record.
class MissingJwDayMove implements Exception {
  const MissingJwDayMove(this.sourceDate);

  final String sourceDate;

  @override
  String toString() => 'MissingJwDayMove: $sourceDate';
}
