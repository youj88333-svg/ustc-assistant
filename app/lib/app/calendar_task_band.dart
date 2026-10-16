import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/agenda_contract.dart';
import '../core/calendar_contract.dart';
import 'calendar_display_style.dart';

enum CalendarTaskDeadlineWarning { none, dueToday, overdue }

CalendarTaskDeadlineWarning calendarTaskDeadlineWarning(
  TaskRecord task,
  DateTime nowUtc,
) {
  if (task.status == TaskStatus.completed ||
      task.status == TaskStatus.cancelled) {
    return CalendarTaskDeadlineWarning.none;
  }
  final deadline = task.draft.deadlineAtUtc;
  if (deadline == null) return CalendarTaskDeadlineWarning.none;
  final now = nowUtc.toUtc();
  if (!deadline.toUtc().isAfter(now)) {
    return CalendarTaskDeadlineWarning.overdue;
  }
  if (beijingDay(deadline) == beijingDay(now)) {
    return CalendarTaskDeadlineWarning.dueToday;
  }
  return CalendarTaskDeadlineWarning.none;
}

final class CalendarTaskProjection {
  CalendarTaskProjection({
    required Map<DateTime, List<TaskRecord>> byDay,
    required List<TaskRecord> unscheduled,
  }) : byDay = Map.unmodifiable({
         for (final entry in byDay.entries)
           entry.key: List<TaskRecord>.unmodifiable(entry.value),
       }),
       unscheduled = List.unmodifiable(unscheduled);

  final Map<DateTime, List<TaskRecord>> byDay;
  final List<TaskRecord> unscheduled;

  bool get hasVisibleTasks =>
      unscheduled.isNotEmpty || byDay.values.any((tasks) => tasks.isNotEmpty);
}

/// Projects TaskRecord deadlines onto visible Beijing calendar dates.
///
/// This projection is only a display lane; it never creates calendar
/// occurrences or participates in the schedule's overlap calculations.
CalendarTaskProjection projectCalendarTasks({
  required List<TaskRecord> tasks,
  required List<DateTime> days,
  required DateTime nowUtc,
}) {
  final visibleDays = days.map(calendarDay).toSet();
  final byDay = <DateTime, List<TaskRecord>>{
    for (final day in visibleDays) day: <TaskRecord>[],
  };
  final unscheduled = <TaskRecord>[];
  final today = beijingDay(nowUtc);
  for (final task in tasks) {
    final deadline = task.draft.deadlineAtUtc;
    if (deadline == null) {
      unscheduled.add(task);
      continue;
    }
    final deadlineDay = beijingDay(deadline);
    final open =
        task.status != TaskStatus.completed &&
        task.status != TaskStatus.cancelled;
    final expired = open && !deadline.toUtc().isAfter(nowUtc.toUtc());
    final displayDay = expired && visibleDays.contains(today)
        ? today
        : deadlineDay;
    final bucket = byDay[displayDay];
    if (bucket != null) bucket.add(task);
  }
  for (final bucket in byDay.values) {
    bucket.sort((left, right) {
      final priority = right.draft.priority.index.compareTo(
        left.draft.priority.index,
      );
      if (priority != 0) return priority;
      final leftDeadline = left.draft.deadlineAtUtc;
      final rightDeadline = right.draft.deadlineAtUtc;
      if (leftDeadline != null && rightDeadline != null) {
        final deadline = leftDeadline.compareTo(rightDeadline);
        if (deadline != 0) return deadline;
      }
      return left.reference.localId.compareTo(right.reference.localId);
    });
  }
  unscheduled.sort((left, right) {
    final priority = right.draft.priority.index.compareTo(
      left.draft.priority.index,
    );
    return priority != 0
        ? priority
        : left.reference.localId.compareTo(right.reference.localId);
  });
  return CalendarTaskProjection(byDay: byDay, unscheduled: unscheduled);
}

final class CalendarTaskBand extends StatelessWidget {
  const CalendarTaskBand({
    super.key,
    required this.days,
    required this.tasks,
    required this.nowUtc,
    required this.height,
    required this.gutterWidth,
    required this.onSelectTask,
    required this.onOpenUnscheduledTasks,
    required this.onOverflow,
    this.dayWidth,
  });

  final List<DateTime> days;
  final List<TaskRecord> tasks;
  final DateTime nowUtc;
  final double height;
  final double gutterWidth;
  final double? dayWidth;
  final ValueChanged<TaskRecord> onSelectTask;
  final VoidCallback onOpenUnscheduledTasks;
  final void Function(DateTime day, List<TaskRecord> tasks) onOverflow;

  @override
  Widget build(BuildContext context) {
    final projection = projectCalendarTasks(
      tasks: tasks,
      days: days,
      nowUtc: nowUtc,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : gutterWidth + (dayWidth ?? 124) * days.length;
        final resolvedDayWidth =
            dayWidth ??
            math.max(0, contentWidth - gutterWidth) / math.max(1, days.length);
        return SizedBox(
          key: const ValueKey('calendar-task-band'),
          height: height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: gutterWidth,
                child: _gutter(projection.unscheduled),
              ),
              for (final day in days)
                SizedBox(
                  width: resolvedDayWidth,
                  child: _dayCell(
                    day,
                    projection.byDay[calendarDay(day)] ?? const [],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _gutter(List<TaskRecord> unscheduled) {
    final hasUnscheduled = unscheduled.isNotEmpty;
    final cell = InkWell(
      key: hasUnscheduled ? const ValueKey('calendar-task-unscheduled') : null,
      onTap: hasUnscheduled ? onOpenUnscheduledTasks : null,
      child: Container(
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          color: Color(0xFFF8FAF9),
          border: Border(
            right: BorderSide(color: Color(0xFFE3E9E5)),
            bottom: BorderSide(color: Color(0xFFE3E9E5)),
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              '任务',
              maxLines: 1,
              style: TextStyle(
                fontSize: 9,
                color: Color(0xFF66736C),
                fontWeight: FontWeight.w600,
              ),
            ),
            if (hasUnscheduled)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                child: Text(
                  '待安排\n${unscheduled.length} 项',
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 8,
                    height: 1.1,
                    color: Color(0xFF2F6848),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    return hasUnscheduled
        ? Tooltip(message: '待安排：${unscheduled.length} 项无截止任务', child: cell)
        : cell;
  }

  Widget _dayCell(DateTime day, List<TaskRecord> dayTasks) {
    final remaining = dayTasks.length - 1;
    final paddedTarget = height >= 48;
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          right: BorderSide(color: Color(0xFFE3E9E5)),
          bottom: BorderSide(color: Color(0xFFE3E9E5)),
        ),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: 3,
        vertical: paddedTarget ? 0 : 2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (dayTasks.isNotEmpty)
            Expanded(child: _taskTile(day, dayTasks.first))
          else
            const Expanded(child: SizedBox.shrink()),
          if (remaining > 0)
            SizedBox(
              width: paddedTarget ? 48 : 28,
              child: TextButton(
                key: ValueKey('calendar-task-overflow-${_dayKey(day)}'),
                style: TextButton.styleFrom(
                  minimumSize: paddedTarget ? const Size(48, 48) : Size.zero,
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  tapTargetSize: paddedTarget
                      ? MaterialTapTargetSize.padded
                      : MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => onOverflow(day, dayTasks),
                child: Tooltip(
                  message: '查看全部 ${dayTasks.length} 项任务',
                  child: Text(
                    '+$remaining',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _taskTile(DateTime displayDay, TaskRecord task) {
    final colors = calendarColorsForTitle(task.draft.title);
    final warning = calendarTaskDeadlineWarning(task, nowUtc);
    final deadline = task.draft.deadlineAtUtc;
    final shiftedOverdue =
        deadline != null &&
        warning == CalendarTaskDeadlineWarning.overdue &&
        beijingDay(deadline) != calendarDay(displayDay);
    final tooltip = <String>[
      task.draft.title,
      _taskStatus(task.status),
      if (deadline != null)
        '${shiftedOverdue ? '原截止' : '截止'}：${_beijingDateTimeLabel(deadline)}',
      if (task.draft.estimatedMinutes != null)
        '预计 ${task.draft.estimatedMinutes} 分钟',
    ].join('\n');
    return Tooltip(
      message: tooltip,
      child: Material(
        color: colors.fill,
        borderRadius: BorderRadius.circular(5),
        child: InkWell(
          key: ValueKey(
            'calendar-task-${_dayKey(displayDay)}-${task.reference.localId}',
          ),
          onTap: () => onSelectTask(task),
          borderRadius: BorderRadius.circular(5),
          child: Container(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              border: Border.all(color: colors.edge.withValues(alpha: .45)),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Row(
              children: [
                if (warning != CalendarTaskDeadlineWarning.none) ...[
                  Icon(
                    Icons.error_outline_rounded,
                    key: ValueKey(
                      'calendar-task-warning-${task.reference.localId}',
                    ),
                    size: 13,
                    color: warning == CalendarTaskDeadlineWarning.overdue
                        ? const Color(0xFF9B2C2C)
                        : const Color(0xFFB77900),
                  ),
                  const SizedBox(width: 2),
                ],
                Expanded(
                  child: Text(
                    task.draft.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.ink,
                      fontSize: 10,
                      height: 1.05,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (shiftedOverdue) ...[
                  const SizedBox(width: 3),
                  Text(
                    _beijingDate(deadline),
                    maxLines: 1,
                    style: TextStyle(
                      color: colors.ink.withValues(alpha: .8),
                      fontSize: 8,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _taskStatus(TaskStatus status) => switch (status) {
  TaskStatus.active => '进行中',
  TaskStatus.blocked => '受阻',
  TaskStatus.completed => '已完成',
  TaskStatus.cancelled => '已取消',
};

String _beijingDateTimeLabel(DateTime utc) {
  final value = utc.toUtc().add(const Duration(hours: 8));
  return '${_beijingDate(value)} ${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';
}

String _beijingDate(DateTime utc) {
  final value = utc.toUtc().add(const Duration(hours: 8));
  return '${value.month.toString().padLeft(2, '0')}/'
      '${value.day.toString().padLeft(2, '0')}';
}

String _dayKey(DateTime day) =>
    '${day.year}-${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';
