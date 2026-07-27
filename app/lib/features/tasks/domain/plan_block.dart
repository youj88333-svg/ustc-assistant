import '../../../core/database/app_database.dart';

enum PlanBlockStatus {
  suggested,
  accepted,
  done,
  skipped,
  rescheduled,
  cancelled;

  String get storage => name;

  static PlanBlockStatus fromStorage(String value) =>
      PlanBlockStatus.values.firstWhere((status) => status.storage == value);
}

class PlanBlockValidationError implements Exception {
  const PlanBlockValidationError(this.message);

  final String message;

  @override
  String toString() => 'PlanBlockValidationError: $message';
}

class PlanBlockItem {
  PlanBlockItem({
    required this.id,
    required this.taskId,
    required this.startAt,
    required this.endAt,
    required this.status,
    required this.locked,
    required this.createdAt,
    required this.updatedAt,
    this.title,
    this.reviewNote,
    this.reviewedAt,
    this.rescheduledToPlanBlockId,
    this.deletedAt,
  }) {
    if (!endAt.isAfter(startAt)) {
      throw const PlanBlockValidationError('end must be after start');
    }
  }

  factory PlanBlockItem.fromRow(PlanBlock row) => PlanBlockItem(
    id: row.id,
    taskId: row.taskId,
    title: row.title,
    startAt: DateTime.fromMillisecondsSinceEpoch(row.startAt),
    endAt: DateTime.fromMillisecondsSinceEpoch(row.endAt),
    status: PlanBlockStatus.fromStorage(row.status),
    locked: row.locked,
    reviewNote: row.reviewNote,
    reviewedAt: row.reviewedAt,
    rescheduledToPlanBlockId: row.rescheduledToPlanBlockId,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    deletedAt: row.deletedAt,
  );

  final String id;
  final String taskId;
  final String? title;
  final DateTime startAt;
  final DateTime endAt;
  final PlanBlockStatus status;
  final bool locked;
  final String? reviewNote;
  final int? reviewedAt;
  final String? rescheduledToPlanBlockId;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
}

class PlanBlockProjection {
  const PlanBlockProjection({required this.awaitingReview});

  final bool awaitingReview;
}

PlanBlockProjection projectPlanBlock(PlanBlockItem block, DateTime now) =>
    PlanBlockProjection(
      awaitingReview:
          block.deletedAt == null &&
          block.status == PlanBlockStatus.accepted &&
          !block.endAt.isAfter(now),
    );
