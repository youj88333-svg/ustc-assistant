import 'package:flutter/foundation.dart';

import '../core/calendar_contract.dart';

enum CalendarViewMode { day, week }

final class CalendarWorkspaceView {
  const CalendarWorkspaceView({
    required this.day,
    required this.mode,
    required this.filter,
    required this.includeInactive,
    this.window,
    this.detail,
    this.loading = false,
    this.detailLoading = false,
    this.actionPending = false,
    this.sourceBusy = false,
    this.failure,
  });
  final DateTime day;
  final CalendarViewMode mode;
  final CalendarFilter filter;
  final bool includeInactive;
  final CalendarWindow? window;
  final CalendarDetail? detail;
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
      failure != CalendarFailureCode.limitExceeded &&
      failure != CalendarFailureCode.ownershipLost &&
      failure != CalendarFailureCode.storageFailed &&
      failure != CalendarFailureCode.closed;
}

/// Session-local display state. The runtime owns this controller; removing a
/// page does not close it, cancel source work or discard a committed result.
abstract interface class CalendarWorkspacePort implements Listenable {
  CalendarWorkspaceView get view;
  DateTime get today;
  Future<void> load({
    DateTime? day,
    CalendarViewMode? mode,
    CalendarFilter? filter,
    bool? includeInactive,
  });
  Future<void> select(CalendarReference? reference);
  Future<CalendarWriteReceipt> execute(
    CalendarIntent intent, {
    required CalendarContext expectedContext,
  });
}
