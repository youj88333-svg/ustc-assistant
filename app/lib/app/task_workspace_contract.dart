import 'package:flutter/foundation.dart';

import '../core/calendar_contract.dart';

final class TaskWorkspaceView {
  const TaskWorkspaceView({
    this.window,
    this.detail,
    this.query = const TaskQuery(),
    this.undo = const CalendarUndoView(),
    this.loading = false,
    this.detailLoading = false,
    this.actionPending = false,
    this.sourceBusy = false,
    this.failure,
  });
  final TaskWindow? window;
  final TaskDetail? detail;
  final TaskQuery query;
  final CalendarUndoView undo;
  final bool loading;
  final bool detailLoading;
  final bool actionPending;
  final bool sourceBusy;
  final CalendarFailureCode? failure;
  bool get canWrite =>
      window != null &&
      !loading &&
      !actionPending &&
      !sourceBusy &&
      failure != CalendarFailureCode.maintenance &&
      failure != CalendarFailureCode.ownershipLost &&
      failure != CalendarFailureCode.storageFailed &&
      failure != CalendarFailureCode.closed;
}

abstract interface class TaskWorkspacePort implements Listenable {
  TaskWorkspaceView get taskView;
  DateTime get today;
  Future<void> loadTasks({TaskQuery? query});
  Future<void> selectTask(TaskReference? reference);
  Future<CalendarWriteReceipt> executeTask(
    CalendarIntent intent, {
    required CalendarContext expectedContext,
  });
}
