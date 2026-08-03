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
import '../application/jw_day_move_service.dart';
import '../application/schedule_conflict_projection.dart';
import '../domain/overlap_engine.dart';
import '../domain/schedule_grid_item.dart';
import '../domain/schedule_projection.dart';
import '../domain/week_range.dart';
import 'jw_day_move_dialog.dart';
import 'schedule_undo_notice.dart';
import 'week_timetable.dart';

enum ScheduleSection { week, tasks }

class SchedulePage extends StatefulWidget {
  const SchedulePage({
    required this.database,
    this.onEventSelected,
    this.onTaskSelected,
    this.onManageRelations,
    this.initialSection = ScheduleSection.week,
    this.clock = const SystemBeijingClock(),
    super.key,
  });

  final AppDatabase database;
  final ValueChanged<String>? onEventSelected;
  final ValueChanged<String>? onTaskSelected;

  /// Handles the "处理重叠关系" command from an overlap expansion in the week
  /// grid, receiving the overlap group's items so the caller can route them to
  /// the mixed relation editor.
  final ValueChanged<OverlapGroup>? onManageRelations;

  /// The section to show when the page is first displayed, and whenever this
  /// widget is rebuilt with a different value (e.g. a route rebuild from
  /// `?section=week` to `?section=tasks`). Defaults to the week view.
  final ScheduleSection initialSection;

  final BeijingClock clock;

  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage>
    with AutomaticKeepAliveClientMixin {
  ScheduleSection selected = ScheduleSection.week;
  late DateTime selectedDate;

  /// Presentation state for the schedule-page-local undo notice. A non-null
  /// value means the notice is currently displayed. Dismissal (hide or
  /// timeout) changes ONLY this presentation — it never clears the persisted
  /// DB one-step undo slot.
  _UndoNoticeState? _undoNotice;

  /// The single countdown driving [ScheduleUndoNotice]. Starting a new notice
  /// cancels any in-flight timer so only the latest notice is ever shown.
  Timer? _undoNoticeTimer;

  @override
  void initState() {
    super.initState();
    selected = widget.initialSection;
    selectedDate = widget.clock.now();
  }

  @override
  void dispose() {
    _undoNoticeTimer?.cancel();
    super.dispose();
  }

  /// Shows (or replaces) the page-local undo notice and restarts its EXACTLY
  /// six-second countdown. A previous notice is closed immediately — there is
  /// never a queue. This is presentation-only: the DB undo slot recorded by
  /// [UndoService] is untouched by the timer or by dismissal.
  void _showUndoNotice({required String message, required VoidCallback onUndo}) {
    _undoNoticeTimer?.cancel();
    setState(() {
      _undoNotice = _UndoNoticeState(message: message, onUndo: onUndo);
    });
    _undoNoticeTimer = Timer(const Duration(seconds: 6), () {
      if (!mounted) return;
      setState(() => _undoNotice = null);
    });
  }

  void _hideUndoNotice() {
    _undoNoticeTimer?.cancel();
    _undoNoticeTimer = null;
    if (_undoNotice != null) {
      setState(() => _undoNotice = null);
    }
  }

  @override
  void didUpdateWidget(SchedulePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The shell (StatefulShellRoute.indexedStack) keeps this State alive across
    // route changes, so a new `initialSection` must update `selected` here —
    // otherwise a re-route (e.g. back to `/schedule?section=week`) would
    // preserve the stale section from the retained shell State.
    if (oldWidget.initialSection != widget.initialSection) {
      setState(() => selected = widget.initialSection);
    }
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Stack(
      children: [
        Column(
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
                  onManageRelations: widget.onManageRelations,
                  onDayMove: () => unawaited(_openDayMoveDialog()),
                ),
                ScheduleSection.tasks => _ScheduleData(
                  database: widget.database,
                  section: selected,
                  selectedDate: selectedDate,
                  onEventSelected: widget.onEventSelected,
                  onTaskSelected: widget.onTaskSelected,
                  onManageRelations: widget.onManageRelations,
                  onDayMove: () => unawaited(_openDayMoveDialog()),
                ),
              },
            ),
          ],
        ),
        if (_undoNotice != null) ...[
          ScheduleUndoNotice(
            message: _undoNotice!.message,
            onUndo: () {
              final onUndo = _undoNotice!.onUndo;
              _hideUndoNotice();
              onUndo();
            },
          ),
        ],
      ],
    );
  }

  /// Opens the whole-day course move dialog for the currently selected week
  /// (Spec section 10.3). On success the page selects the week of the target
  /// date (move/retarget) or of the source date (clear) and offers a one-step
  /// undo backed by the account-scoped [UndoService] that also recorded the
  /// move.
  Future<void> _openDayMoveDialog() async {
    final account = await (widget.database.select(
      widget.database.localAccounts,
    )..where((row) => row.isActive.equals(true))).getSingleOrNull();
    if (account == null || !mounted) return;
    final undo = UndoService(database: widget.database, accountId: account.id);
    final service = JwDayMoveService(
      database: widget.database,
      accountId: account.id,
      undoRecorder: undo,
    );
    final result = await showDialog<JwDayMoveDialogResult>(
      context: context,
      builder: (_) => JwDayMoveDialog(
        service: service,
        initialSourceDate: selectedDate,
        clock: widget.clock,
      ),
    );
    if (result == null || !mounted) return;
    switch (result) {
      case JwDayMovePerformed(:final targetDate):
        setState(() => selectedDate = DateTime.parse(targetDate));
      case JwDayMoveCleared(:final sourceDate):
        setState(() => selectedDate = DateTime.parse(sourceDate));
    }
    final message = switch (result) {
      JwDayMovePerformed() => '已移动整日课程',
      JwDayMoveCleared() => '已恢复原日期',
    };
    // Present the one-step undo as a schedule-page-local floating notice (not
    // a root/global ScaffoldMessenger snackbar) so it never covers chat and
    // never lingers across pages. The six-second countdown, replacement of a
    // prior notice, and dismissal are page-local and presentation-only — the
    // DB one-step undo slot stays intact until undo() actually consumes it.
    _showUndoNotice(message: message, onUndo: () => unawaited(undo.undo()));
  }
}

/// Immutable presentation payload for the page-local undo notice. Kept out of
/// the widget tree's widget graph as a plain object so the state is trivial to
/// inspect in tests and cheap to replace on consecutive operations.
class _UndoNoticeState {
  const _UndoNoticeState({required this.message, required this.onUndo});

  final String message;
  final VoidCallback onUndo;
}

class _ScheduleData extends StatelessWidget {
  const _ScheduleData({
    required this.database,
    required this.section,
    required this.selectedDate,
    required this.onEventSelected,
    required this.onTaskSelected,
    this.onManageRelations,
    this.onDayMove,
  });

  final AppDatabase database;
  final ScheduleSection section;
  final DateTime selectedDate;
  final ValueChanged<String>? onEventSelected;
  final ValueChanged<String>? onTaskSelected;
  final ValueChanged<OverlapGroup>? onManageRelations;
  final VoidCallback? onDayMove;

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
              ? _week(
                  context,
                  const [],
                  const [],
                  const [],
                  result: const ConflictProjectionResult(
                    pairs: [],
                    candidatePairCount: 0,
                    conflictKeys: {},
                  ),
                )
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
              final repository = EffectiveEventRepository(
                database,
                accountId: account.id,
              );
              final week = WeekRange.forDate(selectedDate);
              return StreamBuilder<List<EffectiveEvent>>(
                stream: repository.watchDisplayEvents(
                  from: week.start,
                  through: week.days.last,
                ),
                builder: (context, eventSnapshot) {
                  final events = eventSnapshot.data ?? const [];
                  // ONE bounded projection over the selected 7-day range. The
                  // repository loads effective events only; the range filter
                  // and candidate generation happen here, once, for both the
                  // event and plan-block sides. This removes the old duplicate
                  // repository-wide projection + widget projection.
                  final conflictFuture = repository.conflictsForItems(
                    events,
                    from: week.start,
                    throughExclusive: week.endExclusive,
                  );
                  return StreamBuilder<List<PlanBlock>>(
                    stream:
                        (database.select(
                              database.planBlocks,
                            )..where((row) => row.accountId.equals(account.id)))
                            .watch(),
                    builder: (context, blockSnapshot) {
                      final blocks = (blockSnapshot.data ?? const [])
                          .map(PlanBlockItem.fromRow)
                          .toList(growable: false);
                      return FutureBuilder<ConflictProjectionResult>(
                        future: conflictFuture,
                        builder: (context, conflictSnapshot) {
                          final result =
                              conflictSnapshot.data ??
                              const ConflictProjectionResult(
                                pairs: [],
                                candidatePairCount: 0,
                                conflictKeys: {},
                              );
                          return _week(
                            context,
                            tasks,
                            events,
                            blocks,
                            result: result,
                          );
                        },
                      );
                    },
                  );
                },
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
    List<TaskItem> tasks,
    List<EffectiveEvent> events,
    List<PlanBlockItem> blocks, {
    required ConflictProjectionResult result,
  }) {
    final tasksById = {for (final task in tasks) task.id: task};
    final items = <ScheduleGridItem>[
      for (final event in events)
        ScheduleGridItem.fromEvent(event).withConflict(
          result.isConflict('event', event.id),
        ),
    ];
    for (final block in blocks) {
      if (!block.showsInWeekGrid) continue;
      final task = tasksById[block.taskId];
      if (task == null) continue;
      items.add(
        ScheduleGridItem.fromPlanBlock(
          block,
          task,
        ).withConflict(result.isConflict('plan_block', block.id)),
      );
    }
    return WeekTimetable(
      projection: buildWeek(
        ScheduleQuery(selectedDate: selectedDate, items: items),
      ),
      tasks: tasks,
      onDayMove: onDayMove,
      onManageRelations: onManageRelations,
      onTaskSelected: (task) {
        onTaskSelected?.call(task.id);
      },
      onEventSelected: (item) {
        switch (item.kind) {
          case ScheduleGridItemKind.event:
            onEventSelected?.call(item.id);
          case ScheduleGridItemKind.planBlock:
            onTaskSelected?.call(item.planBlock!.taskId);
        }
      },
    );
  }

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
