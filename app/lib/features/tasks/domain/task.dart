import 'dart:convert';

import '../../../core/database/app_database.dart';

enum TaskState {
  active,
  blocked,
  completed,
  cancelled;

  String get storage => name;

  static TaskState fromStorage(String value) =>
      TaskState.values.firstWhere((state) => state.storage == value);
}

enum TaskImportance {
  low,
  normal,
  high,
  critical;

  String get storage => name;

  static TaskImportance fromStorage(String value) =>
      TaskImportance.values.firstWhere((item) => item.storage == value);
}

class TaskValidationError implements Exception {
  const TaskValidationError(this.message);

  final String message;

  @override
  String toString() => 'TaskValidationError: $message';
}

class TaskItem {
  TaskItem({
    required this.id,
    required String title,
    required this.state,
    required this.importance,
    required this.createdAt,
    required this.updatedAt,
    this.description,
    this.userNotes,
    this.blockedReason,
    this.deadlineAt,
    this.estimatedMinutes,
    this.tags = const [],
    this.completedAt,
    this.cancelledAt,
    this.deletedAt,
  }) : title = title.trim() {
    if (this.title.isEmpty) {
      throw const TaskValidationError('title must not be blank');
    }
    if (estimatedMinutes != null && estimatedMinutes! <= 0) {
      throw const TaskValidationError('estimated minutes must be positive');
    }
  }

  factory TaskItem.fromRow(Task row) => TaskItem(
    id: row.id,
    title: row.title,
    description: row.description,
    userNotes: row.userNotes,
    state: TaskState.fromStorage(row.state),
    blockedReason: row.blockedReason,
    importance: TaskImportance.fromStorage(row.importance),
    deadlineAt: row.deadlineAt == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row.deadlineAt!),
    estimatedMinutes: row.estimatedMinutes,
    tags: (jsonDecode(row.tagsJson) as List<dynamic>).cast<String>(),
    completedAt: row.completedAt,
    cancelledAt: row.cancelledAt,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    deletedAt: row.deletedAt,
  );

  final String id;
  final String title;
  final String? description;
  final String? userNotes;
  final TaskState state;
  final String? blockedReason;
  final TaskImportance importance;
  final DateTime? deadlineAt;
  final int? estimatedMinutes;
  final List<String> tags;
  final int? completedAt;
  final int? cancelledAt;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;

  bool get isTerminal =>
      state == TaskState.completed || state == TaskState.cancelled;
}
