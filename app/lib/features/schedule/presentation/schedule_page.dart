import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/database/app_database.dart';
import '../../../core/time/beijing_clock.dart';
import '../../tasks/application/plan_block_service.dart';
import '../../tasks/application/task_lifecycle_service.dart';
import '../../tasks/application/undo_service.dart';
import '../../tasks/domain/plan_block.dart';
import '../../tasks/domain/task.dart';
import '../../tasks/presentation/task_center_page.dart';
import '../application/effective_event_repository.dart';
import '../domain/overlap_engine.dart';
import '../domain/schedule_projection.dart';
import '../domain/week_range.dart';
import 'week_timetable.dart';

enum ScheduleSection { week, tasks }

class SchedulePage extends StatefulWidget {
  const SchedulePage({
    required this.database,
    this.onEventSelected,
    this.onTaskSelected,
    this.clock = const SystemBeijingClock(),
    super.key,
  });

  final AppDatabase database;
  final ValueChanged<String>? onEventSelected;
  final ValueChanged<String>? onTaskSelected;
  final BeijingClock clock;

  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage>
    with AutomaticKeepAliveClientMixin {
  ScheduleSection selected = ScheduleSection.week;
  late DateTime selectedDate;

  @override
  void initState() {
    super.initState();
    selectedDate = widget.clock.now();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: SegmentedButton<ScheduleSection>(
            segments: const [
              ButtonSegment(
                value: ScheduleSection.week,
                icon: Icon(Icons.calendar_view_week),
                label: Text('周视图'),
              ),
              ButtonSegment(
                value: ScheduleSection.tasks,
                icon: Icon(Icons.task_alt),
                label: Text('任务'),
              ),
            ],
            selected: {selected},
            onSelectionChanged: (selection) {
              setState(() => selected = selection.single);
            },
          ),
        ),
        if (selected == ScheduleSection.week)
          _WeekNavigation(
            selectedDate: selectedDate,
            currentDate: widget.clock.now(),
            onPrevious: () {
              setState(() {
                selectedDate = selectedDate.subtract(const Duration(days: 7));
              });
            },
            onCurrent: () {
              setState(() => selectedDate = widget.clock.now());
            },
            onNext: () {
              setState(() {
                selectedDate = selectedDate.add(const Duration(days: 7));
              });
            },
          ),
        Expanded(
          child: switch (selected) {
            ScheduleSection.week => _ScheduleData(
              database: widget.database,
              section: selected,
              selectedDate: selectedDate,
              onEventSelected: widget.onEventSelected,
              onTaskSelected: widget.onTaskSelected,
            ),
            ScheduleSection.tasks => _ScheduleData(
              database: widget.database,
              section: selected,
              selectedDate: selectedDate,
              onEventSelected: widget.onEventSelected,
              onTaskSelected: widget.onTaskSelected,
            ),
          },
        ),
      ],
    );
  }
}

class _ScheduleData extends StatelessWidget {
  const _ScheduleData({
    required this.database,
    required this.section,
    required this.selectedDate,
    required this.onEventSelected,
    required this.onTaskSelected,
  });

  final AppDatabase database;
  final ScheduleSection section;
  final DateTime selectedDate;
  final ValueChanged<String>? onEventSelected;
  final ValueChanged<String>? onTaskSelected;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<LocalAccount?>(
      future: (database.select(
        database.localAccounts,
      )..where((row) => row.isActive.equals(true))).getSingleOrNull(),
      builder: (context, accountSnapshot) {
        if (accountSnapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final account = accountSnapshot.data;
        if (account == null) {
          return section == ScheduleSection.week
              ? _week(context, const [])
              : const TaskCenterPage();
        }
        final query = database.select(database.tasks)
          ..where((row) => row.accountId.equals(account.id));
        return StreamBuilder<List<Task>>(
          stream: query.watch(),
          builder: (context, taskSnapshot) {
            final tasks = (taskSnapshot.data ?? const [])
                .map(TaskItem.fromRow)
                .toList(growable: false);
            if (section == ScheduleSection.week) {
              return StreamBuilder<List<EffectiveEvent>>(
                stream: EffectiveEventRepository(
                  database,
                  accountId: account.id,
                ).watchDisplayEvents(),
                builder: (context, eventSnapshot) =>
                    _week(context, tasks, eventSnapshot.data ?? const []),
              );
            }
            return _taskCenter(context, account.id, tasks);
          },
        );
      },
    );
  }

  Widget _week(
    BuildContext context,
    List<TaskItem> tasks, [
    List<EffectiveEvent> events = const [],
  ]) => WeekTimetable(
    projection: buildWeek(
      ScheduleQuery(selectedDate: selectedDate, events: events),
    ),
    tasks: tasks,
    onTaskSelected: (task) {
      onTaskSelected?.call(task.id);
    },
    onEventSelected: (event) => onEventSelected?.call(event.id),
  );

  Widget _taskCenter(
    BuildContext context,
    String accountId,
    List<TaskItem> tasks,
  ) {
    final blocks = database.select(database.planBlocks)
      ..where((row) => row.accountId.equals(accountId));
    final service = PlanBlockService(database: database, accountId: accountId);
    final undo = UndoService(database: database, accountId: accountId);
    final taskService = TaskLifecycleService(
      database: database,
      accountId: accountId,
      undoRecorder: undo,
      planBlocks: service,
    );
    return StreamBuilder<List<PlanBlock>>(
      stream: blocks.watch(),
      builder: (context, blockSnapshot) {
        final now = DateTime.now();
        final pending = (blockSnapshot.data ?? const [])
            .map(PlanBlockItem.fromRow)
            .where((block) => projectPlanBlock(block, now).awaitingReview)
            .toList(growable: false);
        return FutureBuilder<bool>(
          future: undo.canUndo(),
          builder: (context, undoSnapshot) => TaskCenterPage(
            tasks: tasks,
            pendingReview: pending,
            undoAvailable: undoSnapshot.data ?? false,
            onUndo: () => unawaited(undo.undo()),
            onTaskSelected: (task) => onTaskSelected?.call(task.id),
            onRestore: (task) => unawaited(
              taskService.restore(task.id, expectedUpdatedAt: task.updatedAt),
            ),
            onReviewDone: (block) => unawaited(
              service.markDone(block.id, expectedUpdatedAt: block.updatedAt),
            ),
            onReviewSkipped: (block) => unawaited(
              service.markSkipped(block.id, expectedUpdatedAt: block.updatedAt),
            ),
            onReviewReschedule: (block) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('请在计划编辑器中选择新的时间')));
            },
          ),
        );
      },
    );
  }
}

class _WeekNavigation extends StatelessWidget {
  const _WeekNavigation({
    required this.selectedDate,
    required this.currentDate,
    required this.onPrevious,
    required this.onCurrent,
    required this.onNext,
  });

  final DateTime selectedDate;
  final DateTime currentDate;
  final VoidCallback onPrevious;
  final VoidCallback onCurrent;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final week = WeekRange.forDate(selectedDate);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(
        children: [
          IconButton(
            tooltip: '上一周',
            onPressed: onPrevious,
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: Text(
              _rangeLabel(week),
              key: const Key('week-range-label'),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          IconButton(
            tooltip: '回到本周',
            onPressed: week.contains(currentDate) ? null : onCurrent,
            icon: const Icon(Icons.today_outlined),
          ),
          IconButton(
            tooltip: '下一周',
            onPressed: onNext,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }

  String _rangeLabel(WeekRange week) {
    final start = week.start;
    final end = week.days.last;
    if (start.year == end.year) {
      return '${start.year}年${start.month}月${start.day}日'
          ' - ${end.month}月${end.day}日';
    }
    return '${start.year}年${start.month}月${start.day}日'
        ' - ${end.year}年${end.month}月${end.day}日';
  }
}
