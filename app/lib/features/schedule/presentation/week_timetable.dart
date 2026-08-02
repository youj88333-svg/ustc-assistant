import 'dart:ui';

import 'package:flutter/material.dart';

import '../../tasks/domain/task.dart';
import '../../tasks/presentation/task_filters.dart';
import '../domain/overlap_engine.dart';
import '../domain/schedule_grid_item.dart';
import '../domain/schedule_projection.dart';
import '../domain/ustc_periods.dart';
import 'all_day_band.dart';
import 'early_morning_band.dart';
import 'event_block.dart';
import 'overlap_expansion.dart';
import 'time_axis.dart';

class WeekTimetable extends StatelessWidget {
  const WeekTimetable({
    required this.projection,
    required this.onEventSelected,
    this.tasks = const [],
    this.now,
    this.hideCompletedTasks = false,
    this.onTaskSelected,
    this.onDayMove,
    this.onManageRelations,
    super.key,
  });

  final ScheduleProjection projection;

  /// The single selection callback for timed grid items. Calendar events and
  /// planning blocks are discriminated by [ScheduleGridItem.kind]; events
  /// route to the event detail and plan blocks route to the parent task.
  final ValueChanged<ScheduleGridItem> onEventSelected;
  final List<TaskItem> tasks;
  final DateTime? now;
  final bool hideCompletedTasks;
  final ValueChanged<TaskItem>? onTaskSelected;

  /// Opens the whole-day course move dialog (spec section 10.3). When null
  /// the "整日调课" entry button is not rendered.
  final VoidCallback? onDayMove;

  /// Exposes the "处理重叠关系" command from every overlap expansion. When
  /// non-null, the expansion shows the command which hands the active
  /// [OverlapGroup] to the caller for routing to the mixed relation editor.
  final ValueChanged<OverlapGroup>? onManageRelations;

  static const axisWidth = 56.0;
  static const minimumDayWidth = 142.0;
  static const pixelsPerMinute = 0.72;

  @override
  Widget build(BuildContext context) {
    final groupsByItem = {
      for (final group in projection.overlapGroups)
        for (final item in group.items) item.id: group,
    };
    return LayoutBuilder(
      builder: (context, constraints) {
        final fitted = (constraints.maxWidth - axisWidth) / 7;
        final dayWidth = fitted > minimumDayWidth ? fitted : minimumDayWidth;
        final totalWidth = axisWidth + dayWidth * 7;
        // The whole-day move entry sits in a pinned strip above the
        // horizontally scrolling grid, right under the week navigation.
        final stripHeight = onDayMove == null ? 0.0 : 48.0;
        return Column(
          children: [
            if (onDayMove != null)
              SizedBox(
                height: stripHeight,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: IconButton(
                      tooltip: '整日调课',
                      onPressed: onDayMove,
                      icon: const Icon(Icons.event_repeat),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: SingleChildScrollView(
                key: const Key('week-horizontal-scroll'),
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: totalWidth,
                  height: constraints.maxHeight - stripHeight,
                  child: Column(
                    children: [
                      _DayHeaders(
                        days: projection.week.days,
                        dayWidth: dayWidth,
                        axisWidth: axisWidth,
                      ),
                      AllDayBand(
                        eventsByDay: projection.allDayByDay,
                        dayWidth: dayWidth,
                        axisWidth: axisWidth,
                      ),
                      EarlyMorningBand(
                        eventsByDay: projection.earlyMorningByDay,
                        dayWidth: dayWidth,
                        axisWidth: axisWidth,
                      ),
                      _UndatedTaskBand(
                        tasks: undatedBandTasks(tasks),
                        totalWidth: totalWidth,
                        axisWidth: axisWidth,
                        onSelected: onTaskSelected,
                      ),
                      _DatedTaskBand(
                        tasksByDay: datedBandTasks(
                          tasks: tasks,
                          weekStart: projection.week.start,
                          now: now ?? DateTime.now(),
                          hideCompleted: hideCompletedTasks,
                        ),
                        days: projection.week.days,
                        dayWidth: dayWidth,
                        axisWidth: axisWidth,
                        now: now ?? DateTime.now(),
                        onSelected: onTaskSelected,
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: SingleChildScrollView(
                          child: SizedBox(
                            height:
                                (UstcPeriods.dayEndMinutes -
                                    UstcPeriods.dayStartMinutes) *
                                pixelsPerMinute,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const TimeAxis(
                                  pixelsPerMinute: pixelsPerMinute,
                                ),
                                for (final day in projection.week.days)
                                  _DayColumn(
                                    day: day,
                                    width: dayWidth,
                                    items:
                                        projection.timedByDay[day.weekday] ??
                                        const [],
                                    groupsByItem: groupsByItem,
                                    onItemSelected: onEventSelected,
                                    onManageRelations: onManageRelations,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _UndatedTaskBand extends StatelessWidget {
  const _UndatedTaskBand({
    required this.tasks,
    required this.totalWidth,
    required this.axisWidth,
    required this.onSelected,
  });

  final List<TaskItem> tasks;
  final double totalWidth;
  final double axisWidth;
  final ValueChanged<TaskItem>? onSelected;

  @override
  Widget build(BuildContext context) {
    if (tasks.isEmpty) return const SizedBox.shrink();
    return Container(
      key: const Key('undated-task-band'),
      width: totalWidth,
      constraints: const BoxConstraints(minHeight: 48),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: axisWidth,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                '未定截止',
                style: TextStyle(
                  color: Color(0xFF202124),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final task in tasks)
                  ActionChip(
                    avatar: const Icon(Icons.task_outlined, size: 16),
                    label: Text(task.title),
                    onPressed: onSelected == null
                        ? null
                        : () => onSelected!(task),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DatedTaskBand extends StatelessWidget {
  const _DatedTaskBand({
    required this.tasksByDay,
    required this.days,
    required this.dayWidth,
    required this.axisWidth,
    required this.now,
    required this.onSelected,
  });

  final Map<int, List<TaskItem>> tasksByDay;
  final List<DateTime> days;
  final double dayWidth;
  final double axisWidth;
  final DateTime now;
  final ValueChanged<TaskItem>? onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('dated-task-band'),
      height: 72,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: axisWidth,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              child: Text(
                '截止事项',
                style: TextStyle(
                  color: Color(0xFF202124),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          for (final day in days)
            SizedBox(
              width: dayWidth,
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  for (final task in tasksByDay[day.weekday] ?? const [])
                    _DeadlineTaskChip(
                      task: task,
                      now: now,
                      onSelected: onSelected,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _DeadlineTaskChip extends StatelessWidget {
  const _DeadlineTaskChip({
    required this.task,
    required this.now,
    required this.onSelected,
  });

  final TaskItem task;
  final DateTime now;
  final ValueChanged<TaskItem>? onSelected;

  @override
  Widget build(BuildContext context) {
    final deadline = task.deadlineAt!;
    final overdue = task.state != TaskState.completed && now.isAfter(deadline);
    final dueToday =
        !overdue &&
        task.state != TaskState.completed &&
        deadline.year == now.year &&
        deadline.month == now.month &&
        deadline.day == now.day;
    final color = overdue
        ? const Color(0xFFFFDAD6)
        : dueToday
        ? const Color(0xFFFFE8A3)
        : Theme.of(context).colorScheme.surfaceContainerHigh;
    final warning = overdue
        ? '已逾期'
        : dueToday
        ? '今天截止'
        : null;
    return Opacity(
      opacity: task.state == TaskState.completed ? 0.55 : 1,
      child: InkWell(
        key: Key('deadline-task-${task.id}'),
        onTap: onSelected == null ? null : () => onSelected!(task),
        child: Container(
          margin: const EdgeInsets.fromLTRB(3, 3, 3, 0),
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
          color: color,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  task.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF202124),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (warning != null)
                Semantics(
                  label: warning,
                  container: true,
                  excludeSemantics: true,
                  child: Icon(
                    Icons.error_outline,
                    size: 18,
                    color: overdue
                        ? const Color(0xFFBA1A1A)
                        : const Color(0xFF7A5900),
                  ),
                )
              else if (task.state == TaskState.completed)
                const Icon(Icons.check_circle_outline, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class _DayHeaders extends StatelessWidget {
  const _DayHeaders({
    required this.days,
    required this.dayWidth,
    required this.axisWidth,
  });

  final List<DateTime> days;
  final double dayWidth;
  final double axisWidth;

  static const labels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          SizedBox(width: axisWidth),
          for (var index = 0; index < days.length; index++)
            SizedBox(
              width: dayWidth,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    labels[index],
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    '${days[index].month}/${days[index].day}',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _DayColumn extends StatelessWidget {
  const _DayColumn({
    required this.day,
    required this.width,
    required this.items,
    required this.groupsByItem,
    required this.onItemSelected,
    required this.onManageRelations,
  });

  final DateTime day;
  final double width;
  final List<ProjectedEvent> items;
  final Map<String, OverlapGroup> groupsByItem;
  final ValueChanged<ScheduleGridItem> onItemSelected;
  final ValueChanged<OverlapGroup>? onManageRelations;

  @override
  Widget build(BuildContext context) {
    final ordered = [...items]
      ..sort((a, b) {
        final groupA = groupsByItem[a.item.id];
        final groupB = groupsByItem[b.item.id];
        final foregroundA = groupA?.foreground.id == a.item.id ? 1 : 0;
        final foregroundB = groupB?.foreground.id == b.item.id ? 1 : 0;
        return foregroundA.compareTo(foregroundB);
      });
    return Container(
      width: width,
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 画每个节次的起始与结束分隔线，使午休（12:10-14:00）、
          // 晚间隔（18:20-19:30）等大段空白两端都有视觉边界。
          // 用 Set 去重以避免相邻无间隔节次产生重叠线。
          for (final boundary in UstcPeriods.boundaries())
            Positioned(
              top:
                  (boundary - UstcPeriods.dayStartMinutes) *
                  WeekTimetable.pixelsPerMinute,
              left: 0,
              right: 0,
              child: Divider(
                height: 1,
                color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
              ),
            ),
          for (final item in ordered) _eventPosition(context, item),
        ],
      ),
    );
  }

  Widget _eventPosition(BuildContext context, ProjectedEvent projected) {
    final item = projected.item;
    final group = groupsByItem[item.id];
    final foreground = group == null || group.foreground.id == item.id;
    Widget block = EventBlock(
      item: item,
      opacity: foreground ? 0.84 : 0.32,
      onTap: () {
        if (group == null) {
          onItemSelected(item);
        } else {
          showDialog<void>(
            context: context,
            builder: (context) => OverlapExpansion(
              group: group,
              onSelected: onItemSelected,
              onManageRelations: onManageRelations,
            ),
          );
        }
      },
    );
    if (!foreground) {
      block = Transform.translate(
        offset: const Offset(5, 3),
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 0.8, sigmaY: 0.8),
          child: block,
        ),
      );
    }
    return Positioned(
      key: foreground && group != null
          ? Key('overlap-group-${group.id}')
          : null,
      top: projected.topMinutes * WeekTimetable.pixelsPerMinute,
      left: 3,
      right: 3,
      height: (projected.heightMinutes * WeekTimetable.pixelsPerMinute)
          .clamp(32, double.infinity)
          .toDouble(),
      child: block,
    );
  }
}
