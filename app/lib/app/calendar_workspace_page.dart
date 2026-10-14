import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;

import '../core/agenda_contract.dart';
import '../core/agent_discussion_contract.dart';
import '../core/calendar_contract.dart';
import 'calendar_event_editor.dart';
import 'calendar_display_style.dart';
import 'calendar_task_band.dart';
import 'calendar_week_view.dart';
import 'calendar_workspace_contract.dart';
import 'task_workspace_contract.dart';
import 'task_workspace_editor.dart';
import 'task_workspace_page.dart';

/// M4.2 schedule workspace. All projection and write decisions remain in C3.
final class CalendarWorkspacePage extends StatefulWidget {
  const CalendarWorkspacePage({
    super.key,
    required this.controller,
    this.tasks,
    this.calendarTaskNowUtc,
    this.onDiscuss,
    this.initialTasks = false,
    this.initialSelection,
    this.onInitialNavigationConsumed,
  });

  final CalendarWorkspacePort controller;
  final TaskWorkspacePort? tasks;
  final DateTime? calendarTaskNowUtc;
  final ValueChanged<AgentDiscussionSelection>? onDiscuss;
  final bool initialTasks;
  final CalendarReference? initialSelection;
  final VoidCallback? onInitialNavigationConsumed;

  @override
  State<CalendarWorkspacePage> createState() => _CalendarWorkspacePageState();
}

final class _CalendarWorkspacePageState extends State<CalendarWorkspacePage> {
  bool _tasksSelected = false;
  CalendarReference? _selectedReference;
  String? _notice;
  final ValueNotifier<String?> _actionFeedback = ValueNotifier(null);
  bool _actionBusy = false;
  bool _calendarTaskLoadFailed = false;
  int _controllerGeneration = 0;
  int _loadGeneration = 0;
  int _actionGeneration = 0;
  int _selectionGeneration = 0;
  bool _hasPendingInitialNavigation = false;
  bool _initialNavigationConsumed = false;
  bool _initialTasksWasConsumed = false;
  int _routeDepth = 0;
  NavigatorState? _navigator;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.maybeOf(context);
  }

  @override
  void initState() {
    super.initState();
    _tasksSelected = widget.initialTasks;
    _hasPendingInitialNavigation =
        widget.initialTasks || widget.initialSelection != null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(
          _load(widget.controller, initialSelection: widget.initialSelection),
        );
        unawaited(_loadCalendarTaskProjection());
        _consumeInitialTasksNavigationIfReady();
      }
    });
  }

  @override
  void didUpdateWidget(covariant CalendarWorkspacePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final portsChanged =
        !identical(oldWidget.controller, widget.controller) ||
        !identical(oldWidget.tasks, widget.tasks);
    final selectionChanged =
        oldWidget.initialSelection != widget.initialSelection;
    final initialTasksChanged = oldWidget.initialTasks != widget.initialTasks;
    if (portsChanged) {
      _controllerGeneration++;
      _loadGeneration++;
      _actionGeneration++;
      _selectionGeneration++;
      _hasPendingInitialNavigation =
          widget.initialTasks || widget.initialSelection != null;
      _initialNavigationConsumed = false;
      _initialTasksWasConsumed = false;
      final routesToClose = _routeDepth;
      _routeDepth = 0;
      _tasksSelected = widget.initialTasks;
      _calendarTaskLoadFailed = false;
      _selectedReference = null;
      _notice = null;
      _actionFeedback.value = null;
      _actionBusy = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_dismissRoutes(routesToClose));
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(
            _load(widget.controller, initialSelection: widget.initialSelection),
          );
          unawaited(_loadCalendarTaskProjection());
          _consumeInitialTasksNavigationIfReady();
        }
      });
      return;
    }
    if (selectionChanged || initialTasksChanged) {
      _selectionGeneration++;
      final clearingConsumedTaskIntent =
          oldWidget.initialTasks &&
          !widget.initialTasks &&
          _initialTasksWasConsumed;
      final newInitialSelection =
          selectionChanged && widget.initialSelection != null;
      final newInitialTaskIntent = initialTasksChanged && widget.initialTasks;
      if (newInitialSelection || newInitialTaskIntent) {
        _hasPendingInitialNavigation = true;
        _initialNavigationConsumed = false;
        _initialTasksWasConsumed = false;
      } else if (selectionChanged || initialTasksChanged) {
        _hasPendingInitialNavigation = false;
      }
      if (newInitialSelection) {
        _tasksSelected = false;
      } else if (newInitialTaskIntent) {
        _tasksSelected = widget.initialTasks;
      } else if (initialTasksChanged &&
          !clearingConsumedTaskIntent &&
          !widget.initialTasks) {
        _tasksSelected = false;
      }
      if (newInitialSelection) {
        final selection = widget.initialSelection!;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || widget.initialSelection != selection) return;
          final view = widget.controller.view;
          if (view.window != null && !view.loading) {
            final selectionGeneration = ++_selectionGeneration;
            unawaited(
              _applyInitialSelection(
                widget.controller,
                _controllerGeneration,
                _loadGeneration,
                selectionGeneration,
                selection,
              ),
            );
          } else {
            unawaited(_load(widget.controller, initialSelection: selection));
          }
        });
      } else if (newInitialTaskIntent && widget.initialSelection == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _consumeInitialTasksNavigationIfReady();
        });
      }
    }
  }

  @override
  void dispose() {
    final routesToClose = _routeDepth;
    if (routesToClose > 0) {
      final navigator = _navigator;
      if (navigator != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (navigator.mounted) {
            unawaited(_dismissRoutes(routesToClose, navigator));
          }
        });
      }
    }
    _controllerGeneration++;
    _loadGeneration++;
    _actionGeneration++;
    _selectionGeneration++;
    _selectedReference = null;
    _notice = null;
    _actionFeedback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.controller,
      if (widget.tasks != null && !identical(widget.tasks, widget.controller))
        widget.tasks!,
    ]),
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) => _buildWorkspace(
        context,
        widget.controller.view,
        constraints.maxWidth,
        constraints.maxHeight,
      ),
    ),
  );

  Widget _buildWorkspace(
    BuildContext context,
    CalendarWorkspaceView view,
    double width,
    double height,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(context),
        const SizedBox(height: 5),
        if (_tasksSelected)
          Expanded(
            child: widget.tasks == null
                ? _tasksPlaceholder(context)
                : TaskWorkspacePage(
                    key: ValueKey<TaskWorkspacePort>(widget.tasks!),
                    port: widget.tasks!,
                    onDiscuss: widget.onDiscuss,
                  ),
          )
        else ...[
          _toolbarArea(view, width, height),
          if (_notice != null) ...[
            const SizedBox(height: 10),
            _noticeCard(_notice!, icon: Icons.info_outline_rounded),
          ],
          if (view.failure != null) ...[
            const SizedBox(height: 10),
            _noticeCard(
              _failureMessage(view.failure!),
              icon: Icons.sync_problem_rounded,
            ),
          ],
          if (view.sourceBusy) ...[
            const SizedBox(height: 8),
            const _StatusLine(
              text: '来源操作进行中，仍可查看日程；新写入暂不可用。',
              icon: Icons.sync_rounded,
            ),
          ],
          if (view.loading) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(minHeight: 2),
          ],
          if (view.actionPending || _actionBusy) ...[
            const SizedBox(height: 8),
            const _StatusLine(
              text: '本地日程操作正在保存。',
              icon: Icons.hourglass_top_rounded,
            ),
          ],
          const SizedBox(height: 10),
          Expanded(child: _calendarBody(context, view, width)),
        ],
      ],
    );
  }

  Widget _toolbarArea(CalendarWorkspaceView view, double width, double height) {
    final toolbar = _toolbar(view, width);
    if (width >= 620) return toolbar;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: width < 380
            ? (height < 460 ? 160 : 220)
            : (height < 640 ? 150 : 170),
      ),
      child: SingleChildScrollView(
        key: const ValueKey('calendar-workspace-toolbar-scroll'),
        child: toolbar,
      ),
    );
  }

  Widget _heading(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 2,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text(
        '日程',
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
      ChoiceChip(
        key: const ValueKey('calendar-workspace-tab-schedule'),
        label: const Text('日程'),
        selected: !_tasksSelected,
        visualDensity: VisualDensity.compact,
        onSelected: (selected) {
          if (selected && _tasksSelected) {
            _selectionGeneration++;
            setState(() => _tasksSelected = false);
          }
        },
      ),
      ChoiceChip(
        key: const ValueKey('calendar-workspace-tab-tasks'),
        label: const Text('任务'),
        selected: _tasksSelected,
        visualDensity: VisualDensity.compact,
        onSelected: (selected) {
          if (selected && !_tasksSelected) {
            _selectionGeneration++;
            setState(() => _tasksSelected = true);
          }
        },
      ),
    ],
  );

  Widget _tasksPlaceholder(BuildContext context) => Card(
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.task_alt_rounded, size: 42, color: _green),
            const SizedBox(height: 12),
            Text(
              '任务服务暂不可用',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            const Text(
              '任务列表和时间规划当前没有可用的本地业务端口。',
              textAlign: TextAlign.center,
              style: TextStyle(color: _muted, height: 1.5),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _toolbar(CalendarWorkspaceView view, double width) {
    final narrow = width < 520;
    final port = widget.controller;
    final generation = _controllerGeneration;
    final day = _dateOnly(view.day);
    return Wrap(
      spacing: 7,
      runSpacing: 5,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SegmentedButton<CalendarViewMode>(
          key: const ValueKey('calendar-workspace-view-mode'),
          segments: const [
            ButtonSegment(
              value: CalendarViewMode.day,
              label: Text('日'),
              icon: Icon(Icons.view_day_outlined),
            ),
            ButtonSegment(
              value: CalendarViewMode.week,
              label: Text('周'),
              icon: Icon(Icons.view_week_outlined),
            ),
          ],
          selected: {view.mode},
          onSelectionChanged: view.loading
              ? null
              : (selection) => _load(widget.controller, mode: selection.first),
        ),
        IconButton(
          key: const ValueKey('calendar-workspace-prev'),
          tooltip: view.mode == CalendarViewMode.week ? '上一周' : '前一天',
          onPressed: () => _moveDay(view, -1),
          icon: const Icon(Icons.chevron_left_rounded),
        ),
        IconButton(
          key: const ValueKey('calendar-workspace-next'),
          tooltip: view.mode == CalendarViewMode.week ? '下一周' : '后一天',
          onPressed: () => _moveDay(view, 1),
          icon: const Icon(Icons.chevron_right_rounded),
        ),
        OutlinedButton.icon(
          key: const ValueKey('calendar-workspace-date-picker'),
          onPressed: () => _pickWorkspaceDate(view),
          icon: const Icon(Icons.calendar_month_outlined, size: 18),
          label: Text(
            view.mode == CalendarViewMode.week && view.window != null
                ? _rangeLabel(view.window!.query.firstDay)
                : _dateLabel(day),
          ),
        ),
        TextButton(
          key: const ValueKey('calendar-workspace-today'),
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 7),
          ),
          onPressed: () =>
              _load(widget.controller, day: _dateOnly(widget.controller.today)),
          child: const Text('今天'),
        ),
        PopupMenuButton<_CalendarToolbarAction>(
          key: const ValueKey('calendar-workspace-filter'),
          tooltip: _filterTooltip(view),
          onOpened: () => _trackTransientRouteOpened(generation),
          onCanceled: () => _trackTransientRouteClosed(generation),
          onSelected: (action) {
            _trackTransientRouteClosed(generation);
            if (!_currentController(port, generation)) return;
            switch (action) {
              case _CalendarToolbarAction.allSources:
                unawaited(_load(port, filter: CalendarFilter.all));
                break;
              case _CalendarToolbarAction.courses:
                unawaited(_load(port, filter: CalendarFilter.course));
                break;
              case _CalendarToolbarAction.exams:
                unawaited(_load(port, filter: CalendarFilter.exam));
                break;
              case _CalendarToolbarAction.young:
                unawaited(_load(port, filter: CalendarFilter.young));
                break;
              case _CalendarToolbarAction.personal:
                unawaited(_load(port, filter: CalendarFilter.personal));
                break;
              case _CalendarToolbarAction.planBlocks:
                unawaited(_load(port, filter: CalendarFilter.planBlock));
                break;
              case _CalendarToolbarAction.toggleInactive:
                unawaited(
                  _load(port, includeInactive: !port.view.includeInactive),
                );
                break;
            }
          },
          itemBuilder: (context) => [
            _filterMenuItem(
              _CalendarToolbarAction.allSources,
              '全部来源',
              view.filter == CalendarFilter.all,
              'calendar-workspace-filter-all',
            ),
            _filterMenuItem(
              _CalendarToolbarAction.courses,
              '课程',
              view.filter == CalendarFilter.course,
              'calendar-workspace-filter-course',
            ),
            _filterMenuItem(
              _CalendarToolbarAction.exams,
              '考试',
              view.filter == CalendarFilter.exam,
              'calendar-workspace-filter-exam',
            ),
            _filterMenuItem(
              _CalendarToolbarAction.young,
              '二课',
              view.filter == CalendarFilter.young,
              'calendar-workspace-filter-young',
            ),
            _filterMenuItem(
              _CalendarToolbarAction.personal,
              '个人安排',
              view.filter == CalendarFilter.personal,
              'calendar-workspace-filter-personal',
            ),
            _filterMenuItem(
              _CalendarToolbarAction.planBlocks,
              '任务时间块',
              view.filter == CalendarFilter.planBlock,
              'calendar-workspace-filter-plan-block',
            ),
            const PopupMenuDivider(height: 8),
            PopupMenuItem<_CalendarToolbarAction>(
              key: const ValueKey('calendar-workspace-include-inactive'),
              value: _CalendarToolbarAction.toggleInactive,
              child: Row(
                children: [
                  Icon(
                    view.includeInactive
                        ? Icons.check_box_rounded
                        : Icons.check_box_outline_blank_rounded,
                    size: 18,
                    color: _green,
                  ),
                  const SizedBox(width: 9),
                  const Text('显示隐藏/跳过记录'),
                ],
              ),
            ),
          ],
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFD4DDD7)),
              borderRadius: BorderRadius.circular(9),
              color: Colors.white,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.filter_list_rounded, size: 17),
                const SizedBox(width: 5),
                const Text('筛选', style: TextStyle(fontSize: 12)),
                if (view.filter != CalendarFilter.all || view.includeInactive)
                  Padding(
                    padding: const EdgeInsets.only(left: 5),
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: _green,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (widget.tasks != null) _undoButton(widget.tasks!),
        FilledButton.icon(
          key: const ValueKey('calendar-personal-create'),
          onPressed: view.canWrite && !_actionBusy
              ? () => _openPersonalEditor(
                  port: widget.controller,
                  expectedContext: view.window!.context,
                  initial: _blankDraft(widget.controller.view.day),
                  heading: '新建个人安排',
                  explanation: '时刻按北京时间输入；保存后由日程查询投影。',
                  allowWeekly: true,
                  intentFor: (draft) => CreatePersonalEvent(draft),
                )
              : null,
          icon: const Icon(Icons.add_rounded),
          label: Text(narrow ? '新建' : '新建个人安排'),
        ),
      ],
    );
  }

  Widget _undoButton(TaskWorkspacePort port) => AnimatedBuilder(
    animation: port,
    builder: (context, _) {
      final taskView = port.taskView;
      final undo = taskView.undo;
      final canUndo = undo.canUndo && taskView.canWrite && !_actionBusy;
      final reason = _undoReason(undo);
      return Tooltip(
        message: undo.canUndo ? '撤销最近一次成功的本地修改。' : reason,
        child: OutlinedButton.icon(
          key: const ValueKey('calendar-workspace-undo'),
          onPressed: canUndo ? () => _undoTaskWrite(port, undo) : null,
          icon: const Icon(Icons.undo_rounded, size: 18),
          label: Text(undo.canUndo ? '撤销最近修改' : '暂无可撤销写入'),
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            foregroundColor: _green,
          ),
        ),
      );
    },
  );

  PopupMenuItem<_CalendarToolbarAction> _filterMenuItem(
    _CalendarToolbarAction action,
    String label,
    bool selected,
    String key,
  ) => PopupMenuItem<_CalendarToolbarAction>(
    key: ValueKey(key),
    value: action,
    child: Row(
      children: [
        Icon(
          selected ? Icons.check_rounded : Icons.circle_outlined,
          size: 17,
          color: selected ? _green : const Color(0xFF9AA59E),
        ),
        const SizedBox(width: 9),
        Text(label),
      ],
    ),
  );

  Widget _calendarBody(
    BuildContext context,
    CalendarWorkspaceView view,
    double width,
  ) {
    final window = view.window;
    if (window == null) {
      if (view.loading) {
        return const _EmptyState(
          icon: Icons.calendar_month_outlined,
          title: '正在读取日程',
          detail: '正在从本地日程服务读取当前范围。',
          busy: true,
        );
      }
      if (view.failure != null) {
        return _EmptyState(
          icon: Icons.sync_problem_outlined,
          title: '暂时无法读取日程',
          detail: _failureMessage(view.failure!),
        );
      }
      return const _EmptyState(
        icon: Icons.hourglass_empty_rounded,
        title: '日程尚未读取',
        detail: '当前状态还不能判断为合法空日程。',
      );
    }

    final wideDetail = width >= 1080;
    final port = widget.controller;
    final generation = _controllerGeneration;
    final conflicts = _windowConflicts(window);
    final taskWindow = _calendarTaskWindow;
    final taskDays = _calendarDays(window);
    final taskNowUtc = _calendarTasksNowUtc;
    final taskProjection = projectCalendarTasks(
      tasks: taskWindow?.items ?? const [],
      days: taskDays,
      nowUtc: taskNowUtc,
    );
    final hasSelected = _selectedReference != null;
    final main = view.mode == CalendarViewMode.week
        ? CalendarWeekView(
            window: window,
            today: port.today,
            tasks: taskWindow?.items ?? const [],
            nowUtc: taskNowUtc,
            onSelect: (occurrence) => _selectOccurrence(
              occurrence,
              showSheet: !wideDetail,
              expectedPort: port,
              expectedGeneration: generation,
            ),
            onOverflow: (heading, occurrences) => _showOverflowList(
              port,
              generation,
              heading,
              occurrences,
              showSheet: !wideDetail,
            ),
            onSelectTask: _openCalendarTask,
            onOpenUnscheduledTasks: _openUnscheduledTasks,
            onTaskOverflow: _showCalendarTaskOverflow,
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (taskProjection.hasVisibleTasks)
                CalendarTaskBand(
                  days: taskDays,
                  tasks: taskWindow?.items ?? const [],
                  nowUtc: taskNowUtc,
                  height: _dayTaskBandHeight(context),
                  gutterWidth: 62,
                  onSelectTask: _openCalendarTask,
                  onOpenUnscheduledTasks: _openUnscheduledTasks,
                  onOverflow: _showCalendarTaskOverflow,
                ),
              Expanded(
                child: _dayList(
                  window,
                  showSheet: !wideDetail,
                  conflicts: conflicts,
                ),
              ),
            ],
          );
    final content = window.items.isEmpty && !taskProjection.hasVisibleTasks
        ? const _EmptyState(
            icon: Icons.event_available_outlined,
            title: '该日期范围暂无日程',
            detail: '本地日程查询已完成；空结果只表示当前范围内没有匹配记录。',
          )
        : main;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (window.truncated)
          const _StatusLine(
            text: '已达到日程显示上限，仍有匹配记录未展示。',
            icon: Icons.warning_amber_rounded,
          ),
        if (window.conflictsTruncated) ...[
          const SizedBox(height: 6),
          const _StatusLine(
            text: '重叠候选数量已截断，当前候选列表可能不完整。',
            icon: Icons.warning_amber_rounded,
          ),
        ],
        if (widget.tasks is CalendarTaskWorkspacePort &&
            (widget.tasks as CalendarTaskWorkspacePort).calendarTasksLoading)
          const _StatusLine(
            text: '正在读取独立任务栏。',
            icon: Icons.hourglass_empty_rounded,
          ),
        if (widget.tasks is CalendarTaskWorkspacePort &&
            ((widget.tasks as CalendarTaskWorkspacePort).calendarTasksFailure !=
                    null ||
                _calendarTaskLoadFailed))
          _StatusLine(
            text:
                '任务栏读取失败：${_taskFailureMessageForPage((widget.tasks as CalendarTaskWorkspacePort).calendarTasksFailure ?? CalendarFailureCode.storageFailed)}',
            icon: Icons.sync_problem_rounded,
          ),
        if (taskWindow?.truncated ?? false)
          _StatusLine(
            text:
                '日历任务栏仅显示前 ${taskWindow!.items.length} 项，'
                '共匹配 ${taskWindow.matched} 项。',
            icon: Icons.warning_amber_rounded,
          ),
        if (window.truncated ||
            window.conflictsTruncated ||
            taskWindow?.truncated == true ||
            (widget.tasks is CalendarTaskWorkspacePort &&
                ((widget.tasks as CalendarTaskWorkspacePort)
                        .calendarTasksLoading ||
                    (widget.tasks as CalendarTaskWorkspacePort)
                            .calendarTasksFailure !=
                        null)) ||
            _calendarTaskLoadFailed)
          const SizedBox(height: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (conflicts.isNotEmpty)
                _globalConflictBrowser(conflicts, port, generation, view),
              Expanded(
                child: wideDetail
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: content),
                          if (hasSelected) ...[
                            const SizedBox(width: 12),
                            SizedBox(
                              width: 350,
                              child: _detailPanel(
                                context,
                                view,
                                compact: false,
                              ),
                            ),
                          ],
                        ],
                      )
                    : content,
              ),
            ],
          ),
        ),
      ],
    );
  }

  TaskWindow? get _calendarTaskWindow {
    final tasks = widget.tasks;
    if (tasks is CalendarTaskWorkspacePort) {
      return (tasks as CalendarTaskWorkspacePort).calendarTasks;
    }
    return tasks?.taskView.window;
  }

  DateTime get _calendarTasksNowUtc {
    final fixed = widget.calendarTaskNowUtc;
    if (fixed != null) return fixed.toUtc();
    final tasks = widget.tasks;
    if (tasks is CalendarTaskWorkspacePort) {
      return (tasks as CalendarTaskWorkspacePort).nowUtc.toUtc();
    }
    final detailNow = tasks?.taskView.detail?.nowUtc;
    if (detailNow != null) return detailNow.toUtc();
    final today = widget.controller.today;
    return DateTime.utc(
      today.year,
      today.month,
      today.day,
    ).subtract(const Duration(hours: 8));
  }

  List<DateTime> _calendarDays(CalendarWindow window) {
    final first = calendarDay(window.query.firstDay);
    final lastExclusive = calendarDay(window.query.endDayExclusive);
    final count = lastExclusive.difference(first).inDays.clamp(1, 7).toInt();
    return List.generate(
      count,
      (index) => DateTime.utc(first.year, first.month, first.day + index),
    );
  }

  double _dayTaskBandHeight(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.8);
    return (38 * scale).clamp(38.0, 68.0).toDouble();
  }

  Future<void> _loadCalendarTaskProjection() async {
    final tasks = widget.tasks;
    if (tasks is! CalendarTaskWorkspacePort) return;
    final generation = _controllerGeneration;
    if (mounted) setState(() => _calendarTaskLoadFailed = false);
    try {
      await (tasks as CalendarTaskWorkspacePort).loadCalendarTasks();
    } catch (_) {
      if (mounted &&
          generation == _controllerGeneration &&
          identical(widget.tasks, tasks)) {
        setState(() => _calendarTaskLoadFailed = true);
      }
    }
  }

  Future<void> _showCalendarTaskOverflow(
    DateTime day,
    List<TaskRecord> tasks,
  ) async {
    if (tasks.isEmpty || widget.tasks == null) return;
    final selected = await _withRoute<TaskRecord>(
      () => showDialog<TaskRecord>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('任务 · ${_dateLabel(day)}'),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 440,
              maxHeight: MediaQuery.sizeOf(dialogContext).height * .68,
            ),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: tasks.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final task = tasks[index];
                final deadline = task.draft.deadlineAtUtc;
                final warning = calendarTaskDeadlineWarning(
                  task,
                  _calendarTasksNowUtc,
                );
                return ListTile(
                  key: ValueKey(
                    'calendar-task-overflow-${task.reference.localId}',
                  ),
                  contentPadding: EdgeInsets.zero,
                  leading: warning == CalendarTaskDeadlineWarning.none
                      ? const Icon(Icons.task_alt_rounded, color: _green)
                      : Icon(
                          Icons.error_outline_rounded,
                          color: warning == CalendarTaskDeadlineWarning.overdue
                              ? const Color(0xFF9B2C2C)
                              : const Color(0xFFB77900),
                        ),
                  title: Text(
                    task.draft.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: calendarColorsForTitle(task.draft.title).ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    deadline == null
                        ? '${_taskStatusLabel(task.status)} · 无截止'
                        : '${warning == CalendarTaskDeadlineWarning.overdue
                              ? '已过截止 · '
                              : warning == CalendarTaskDeadlineWarning.dueToday
                              ? '今天截止 · '
                              : ''}${_beijingDateTimeLabel(deadline)}',
                  ),
                  onTap: () => Navigator.of(dialogContext).pop(task),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
    if (selected != null) await _openCalendarTask(selected);
  }

  Future<void> _openCalendarTask(TaskRecord task) =>
      _openCalendarTasks(task: task);

  Future<void> _openUnscheduledTasks() => _openCalendarTasks();

  Future<void> _openCalendarTasks({TaskRecord? task}) async {
    final tasks = widget.tasks;
    if (tasks == null) return;
    final generation = _controllerGeneration;
    try {
      await tasks.loadTasks(
        query: TaskQuery(
          filter: TaskFilter.all,
          keyword: task == null
              ? ''
              : task.draft.title.length <= 200
              ? task.draft.title
              : task.draft.title.substring(0, 200),
          limit: 500,
        ),
      );
      if (!_currentTaskPort(tasks, generation)) return;
      if (task == null) {
        await tasks.selectTask(null);
      } else {
        final window = tasks.taskView.window;
        final current = window?.items.where(
          (item) => item.reference.localId == task.reference.localId,
        );
        if (window == null ||
            window.context != task.reference.context ||
            current == null ||
            current.isEmpty) {
          setState(() => _notice = '这项任务已更新，请刷新后重新选择。');
          return;
        }
        await tasks.selectTask(current.first.reference);
      }
      if (!_currentTaskPort(tasks, generation)) return;
      if (_routeDepth > 0) await _dismissRoutes(_routeDepth);
      if (!_currentTaskPort(tasks, generation)) return;
      setState(() {
        _tasksSelected = true;
        _notice = null;
      });
    } on CalendarFailure catch (failure) {
      if (_currentTaskPort(tasks, generation)) {
        setState(() => _notice = _taskFailureMessageForPage(failure.code));
      }
    } catch (_) {
      if (_currentTaskPort(tasks, generation)) {
        setState(() => _notice = '无法读取任务，请稍后重试。');
      }
    }
  }

  Widget _globalConflictBrowser(
    List<CalendarConflict> conflicts,
    CalendarWorkspacePort port,
    int generation,
    CalendarWorkspaceView view,
  ) => Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: TextButton.icon(
        key: const ValueKey('calendar-conflict-browser'),
        onPressed: () =>
            _showConflicts(conflicts, port, generation, view.canWrite),
        icon: const Icon(Icons.compare_arrows_rounded, size: 17),
        label: Text('冲突判定 · ${conflicts.length}'),
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 34),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          visualDensity: VisualDensity.compact,
        ),
      ),
    ),
  );

  Future<void> _showConflicts(
    List<CalendarConflict> conflicts,
    CalendarWorkspacePort port,
    int generation,
    bool canWrite,
  ) async {
    if (!_currentController(port, generation)) return;
    await _withRoute<void>(
      () => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('冲突判定'),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: 560,
              maxWidth: 560,
              maxHeight: MediaQuery.sizeOf(context).height * .68,
            ),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: conflicts.length,
              separatorBuilder: (_, _) => const Divider(height: 16),
              itemBuilder: (context, index) {
                final conflict = conflicts[index];
                final relation = conflict.relation;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            conflict.left.title,
                            softWrap: true,
                            style: TextStyle(
                              color: calendarColorsForTitle(
                                conflict.left.title,
                              ).ink,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            '${_kindLabel(conflict.left.reference.identity.kind)} · ${_occurrenceTime(conflict.left)}${_presenceSuffix(conflict.left)}',
                            softWrap: true,
                            style: const TextStyle(color: _muted, fontSize: 11),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            conflict.right.title,
                            softWrap: true,
                            style: TextStyle(
                              color: calendarColorsForTitle(
                                conflict.right.title,
                              ).ink,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            '${_kindLabel(conflict.right.reference.identity.kind)} · ${_occurrenceTime(conflict.right)}${_presenceSuffix(conflict.right)}',
                            softWrap: true,
                            style: const TextStyle(color: _muted, fontSize: 11),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            '判定：${_conflictSummaryLabel(conflict)}',
                            style: TextStyle(
                              color: _conflictStatusColor(conflict.status),
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                            ),
                          ),
                          if (relation?.kind ==
                              CalendarRelationKind.legacyUndecided)
                            const Text(
                              '旧说明已保留；当前按重叠默认显示冲突。',
                              style: TextStyle(color: _muted, fontSize: 11),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      key: ValueKey('calendar-conflict-edit-$index'),
                      onPressed:
                          canWrite &&
                              identical(port, widget.controller) &&
                              generation == _controllerGeneration
                          ? () => _editRelation(conflict, port)
                          : null,
                      child: Text(
                        conflict.hasExplicitDecision ? '修改判定' : '确认冲突',
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showOverflowList(
    CalendarWorkspacePort port,
    int generation,
    String heading,
    List<CalendarOccurrence> occurrences, {
    required bool showSheet,
  }) async {
    if (!_currentController(port, generation) || occurrences.isEmpty) return;
    await _withRoute<void>(
      () => showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(heading),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: 520,
              maxWidth: 520,
              maxHeight: MediaQuery.sizeOf(dialogContext).height * .68,
            ),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: occurrences.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final occurrence = occurrences[index];
                return ListTile(
                  key: ValueKey(
                    'calendar-overflow-item-${occurrence.reference.identity.kind.name}-${occurrence.reference.identity.localId}-${occurrence.reference.identity.ordinal}',
                  ),
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    occurrence.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: calendarColorsForTitle(occurrence.title).ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Tooltip(
                    message: _overflowAcademicTooltip(occurrence),
                    child: Text(
                      '${_kindLabel(occurrence.reference.identity.kind)} · ${_occurrenceTime(occurrence)}'
                      '${_overflowAcademicSummary(occurrence)}'
                      '${occurrence.presence == AgendaPresence.missingWithinScope ? ' · 来源暂缺，仍保留' : ''}'
                      '${occurrence.presence == AgendaPresence.outsideScope ? ' · 当前不在观察范围' : ''}',
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () {
                    if (!_currentController(port, generation)) return;
                    Navigator.of(dialogContext).pop();
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (_currentController(port, generation)) {
                        unawaited(
                          _selectOccurrence(
                            occurrence,
                            showSheet: showSheet,
                            expectedPort: port,
                            expectedGeneration: generation,
                          ),
                        );
                      }
                    });
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dayList(
    CalendarWindow window, {
    required bool showSheet,
    required List<CalendarConflict> conflicts,
  }) {
    final items = [...window.items]
      ..sort((left, right) => left.startsAtUtc.compareTo(right.startsAtUtc));
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }
    return ListView.separated(
      key: const ValueKey('calendar-day-list'),
      padding: const EdgeInsets.only(bottom: 10),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final occurrence = items[index];
        final selected = occurrence.reference == _selectedReference;
        final colors = calendarColorsForTitle(occurrence.title);
        return Card(
          clipBehavior: Clip.antiAlias,
          color: colors.fill,
          shape: RoundedRectangleBorder(
            side: BorderSide(color: colors.edge.withValues(alpha: .28)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: InkWell(
            key: ValueKey<CalendarReference>(occurrence.reference),
            onTap: () => _selectOccurrence(occurrence, showSheet: showSheet),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 4,
                    height: 56,
                    decoration: BoxDecoration(
                      color: colors.edge,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          occurrence.title,
                          softWrap: true,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                color: colors.ink,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          _occurrenceTime(occurrence),
                          style: const TextStyle(color: _muted, fontSize: 13),
                        ),
                        const SizedBox(height: 5),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            _SmallTag(
                              text: _kindLabel(
                                occurrence.reference.identity.kind,
                              ),
                              color: const Color(0xFFF0F3F1),
                            ),
                            ..._occurrenceTags(occurrence, conflicts),
                          ],
                        ),
                        _dayAcademicSummary(occurrence),
                      ],
                    ),
                  ),
                  if (selected)
                    const Icon(Icons.chevron_right_rounded, color: _green),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _detailPanel(
    BuildContext context,
    CalendarWorkspaceView view, {
    required bool compact,
  }) {
    final detail = view.detail;
    final selected = _selectedReference;
    final validDetail =
        detail != null &&
        selected != null &&
        detail.occurrence.reference == selected;
    final content = Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '日程详情',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('calendar-detail-close'),
                tooltip: '关闭详情',
                onPressed: () {
                  _forgetSelection(widget.controller);
                  if (compact) Navigator.of(context).pop();
                },
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          Expanded(
            child: !validDetail
                ? _detailWaiting(view, selected)
                : _detailContent(context, view, detail),
          ),
        ],
      ),
    );

    return Card(
      key: const ValueKey('calendar-detail-card'),
      clipBehavior: Clip.antiAlias,
      child: compact
          ? ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .84,
              ),
              child: SizedBox(
                height: MediaQuery.sizeOf(context).height * .78,
                child: content,
              ),
            )
          : content,
    );
  }

  Widget _detailWaiting(
    CalendarWorkspaceView view,
    CalendarReference? selected,
  ) {
    if (selected == null) {
      return const Center(
        child: Text(
          '已保存。重新选择日程可查看最新详情。',
          textAlign: TextAlign.center,
          style: TextStyle(color: _muted),
        ),
      );
    }
    if (view.detailLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    return const Center(
      child: Text(
        '当前引用已失效，请从日程中重新选择这条记录。',
        textAlign: TextAlign.center,
        style: TextStyle(color: _muted),
      ),
    );
  }

  Widget _detailContent(
    BuildContext context,
    CalendarWorkspaceView view,
    CalendarDetail detail,
  ) {
    final occurrence = detail.occurrence;
    final personal =
        occurrence.reference.identity.kind == CalendarKind.personal;
    final planBlock =
        occurrence.reference.identity.kind == CalendarKind.planBlock;
    final conflicts = _conflictsFor(view.window, occurrence);
    return ListView(
      key: const ValueKey('calendar-detail-content'),
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        Text(
          occurrence.title,
          softWrap: true,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: calendarColorsForTitle(occurrence.title).ink,
            fontWeight: FontWeight.w700,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 6, runSpacing: 6, children: _stateTags(occurrence)),
        if (widget.onDiscuss != null) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('calendar-detail-discuss'),
              onPressed: () => widget.onDiscuss!(
                AgentDiscussionSelection.event(occurrence.reference),
              ),
              icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
              label: const Text('交给 Agent 讨论'),
            ),
          ),
        ],
        const SizedBox(height: 14),
        _DetailLine(
          icon: Icons.schedule_rounded,
          label: '时间（北京时间）',
          value: _occurrenceTime(occurrence),
        ),
        const SizedBox(height: 12),
        _DetailLine(
          icon: Icons.source_outlined,
          label: '来源',
          value: _kindLabel(occurrence.reference.identity.kind),
        ),
        const SizedBox(height: 12),
        _DetailLine(
          icon: Icons.place_outlined,
          label: '地点',
          value: _locationSummary(occurrence),
        ),
        if (_isJwAcademic(occurrence)) ...[
          const SizedBox(height: 12),
          _academicDetailsPanel(occurrence),
        ],
        if (occurrence.presence != AgendaPresence.observed) ...[
          const SizedBox(height: 12),
          _DetailLine(
            icon: Icons.info_outline_rounded,
            label: '来源状态',
            value: occurrence.presence == AgendaPresence.missingWithinScope
                ? '来源当前缺少这条记录，本地日程仍予以保留。'
                : '这条记录目前不在来源已观察的范围内。',
          ),
        ],
        if (occurrence.note.trim().isNotEmpty && !planBlock) ...[
          const SizedBox(height: 12),
          _DetailLine(
            icon: Icons.notes_rounded,
            label: '备注',
            value: occurrence.note,
          ),
        ],
        if (!personal && !planBlock) ...[
          const SizedBox(height: 12),
          _schoolOverlaySummary(occurrence),
        ],
        if (planBlock && detail.planBlock != null) ...[
          const SizedBox(height: 12),
          _DetailLine(
            icon: Icons.task_alt_rounded,
            label: '关联任务',
            value:
                '${detail.planBlock!.taskTitle} · ${_taskStatusLabel(detail.planBlock!.taskStatus)}',
          ),
          if (detail.planBlock!.draft.note.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            _DetailLine(
              icon: Icons.notes_rounded,
              label: '时间块备注',
              value: detail.planBlock!.draft.note,
            ),
          ],
        ],
        if (personal && detail.personalDraft != null) ...[
          const SizedBox(height: 12),
          _DetailLine(
            icon: Icons.repeat_rounded,
            label: '重复',
            value: detail.personalDraft!.weekly ? '每周一次' : '单次安排',
          ),
        ],
        const SizedBox(height: 18),
        if (personal)
          _personalActions(view, detail)
        else if (planBlock)
          _planBlockActions(view, detail)
        else
          _schoolActions(view, detail),
        const SizedBox(height: 18),
        if (conflicts.isNotEmpty) ...[
          _sectionHeading('冲突判定'),
          const SizedBox(height: 6),
          const Text(
            '时间重叠默认按冲突显示；已保存的不冲突判定优先。来源筛选不会缩小这组候选。',
            style: TextStyle(color: _muted, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 8),
          for (final conflict in conflicts) ...[
            _conflictCard(view, occurrence, conflict),
            const SizedBox(height: 8),
          ],
        ],
        if (!occurrence.allDay && detail.relations.isNotEmpty) ...[
          _sectionHeading('已保存的判定说明'),
          const SizedBox(height: 8),
          const Text(
            '已保存的说明会保留；当前是否重叠以本次候选为准。',
            style: TextStyle(color: _muted, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 8),
          for (final relation in detail.relations) ...[
            _relationCard(view, occurrence, relation),
            const SizedBox(height: 8),
          ],
        ],
      ],
    );
  }

  Widget _dayAcademicSummary(CalendarOccurrence occurrence) {
    final kind = occurrence.reference.identity.kind;
    if (!_isJwAcademic(occurrence)) {
      if (occurrence.location.trim().isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 5),
        child: _AcademicFactLine(
          key: _dayAcademicKey(occurrence, 'location'),
          label: '地点',
          value: occurrence.location.trim(),
          maxLines: 2,
        ),
      );
    }

    final details = occurrence.academicDetails;
    if (details == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_displayLocation(occurrence).isNotEmpty)
              _AcademicFactLine(
                key: _dayAcademicKey(occurrence, 'location'),
                label: '地点',
                value: _displayLocation(occurrence),
                maxLines: 2,
              ),
            _AcademicFactLine(
              key: _dayAcademicKey(occurrence, 'uncollected'),
              label: '教务信息',
              value: '尚未采集教务信息，重新同步补充',
              maxLines: 2,
            ),
          ],
        ),
      );
    }

    final location = _displayLocation(occurrence);
    final teachers = details.teachers.isEmpty
        ? '本次来源未提供'
        : details.teachers.join('、');
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AcademicFactLine(
            key: _dayAcademicKey(occurrence, 'location'),
            label: '地点',
            value: location.isEmpty ? '本次来源未提供' : location,
            maxLines: 2,
          ),
          if (kind == CalendarKind.course || details.teachers.isNotEmpty) ...[
            const SizedBox(height: 3),
            _AcademicFactLine(
              key: _dayAcademicKey(occurrence, 'teachers'),
              label: '教师',
              value: teachers,
              maxLines: 2,
              tooltipValue: details.teachers.isEmpty ? null : teachers,
            ),
          ],
        ],
      ),
    );
  }

  Widget _academicDetailsPanel(CalendarOccurrence occurrence) {
    final facts = _academicFacts(occurrence);
    if (occurrence.academicDetails == null) {
      return Container(
        key: const ValueKey('calendar-academic-details-uncollected'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFF5F7F5),
          border: Border.all(color: const Color(0xFFE3E9E5)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text(
          '尚未采集教务信息，重新同步补充',
          style: TextStyle(color: _muted, height: 1.4),
        ),
      );
    }
    return Container(
      key: const ValueKey('calendar-academic-details-panel'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAF9),
        border: Border.all(color: const Color(0xFFE3E9E5)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '已采集的教务信息',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
          ),
          const SizedBox(height: 6),
          for (final fact in facts)
            _AcademicFactLine(
              key: ValueKey('calendar-academic-${fact.key}'),
              label: fact.label,
              value: fact.value,
              maxLines: fact.key == 'teachers' ? 4 : 2,
              tooltipValue: fact.tooltipValue,
            ),
        ],
      ),
    );
  }

  Widget _schoolOverlaySummary(CalendarOccurrence occurrence) {
    final kind = occurrence.reference.identity.kind;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (kind == CalendarKind.course || kind == CalendarKind.young)
          _DetailLine(
            icon: Icons.person_outline_rounded,
            label: '出勤计划',
            value: _attendanceLabel(occurrence.attendance),
          ),
        if (kind == CalendarKind.course) ...[
          const SizedBox(height: 10),
          _DetailLine(
            icon: Icons.school_outlined,
            label: '听讲方式',
            value: _listeningLabel(occurrence.listening),
          ),
        ],
      ],
    );
  }

  Widget _personalActions(CalendarWorkspaceView view, CalendarDetail detail) {
    final occurrence = detail.occurrence;
    final target = occurrence.reference;
    final isWeekly = detail.personalDraft?.weekly ?? false;
    final replacementOnly = !isWeekly && detail.hasOccurrenceReplacement;
    final canWrite = view.canWrite && !_actionBusy;
    final actions = <Widget>[
      OutlinedButton.icon(
        key: ValueKey(
          replacementOnly
              ? 'calendar-personal-edit-occurrence'
              : 'calendar-personal-edit-series',
        ),
        onPressed: !canWrite
            ? null
            : replacementOnly
            ? () => _editOccurrence(detail, widget.controller)
            : () => _editSeries(detail, widget.controller),
        icon: const Icon(Icons.edit_outlined),
        label: Text(isWeekly ? '编辑整组' : '编辑安排'),
      ),
      if (isWeekly)
        OutlinedButton.icon(
          key: const ValueKey('calendar-personal-edit-occurrence'),
          onPressed: canWrite
              ? () => _editOccurrence(detail, widget.controller)
              : null,
          icon: const Icon(Icons.edit_rounded),
          label: const Text('修改本次'),
        ),
      if (replacementOnly)
        OutlinedButton.icon(
          key: const ValueKey('calendar-personal-edit-series'),
          onPressed: canWrite
              ? () => _editSeries(detail, widget.controller)
              : null,
          icon: const Icon(Icons.repeat_rounded),
          label: const Text('设置重复'),
        ),
      OutlinedButton.icon(
        key: const ValueKey('calendar-personal-toggle-completed'),
        onPressed: canWrite
            ? () => _execute(
                SetPersonalOccurrenceState(
                  target,
                  completed: !occurrence.completed,
                ),
                widget.controller,
                expectedContext: target.context,
              )
            : null,
        icon: Icon(
          occurrence.completed
              ? Icons.check_circle_outline_rounded
              : Icons.check_circle_rounded,
        ),
        label: Text(occurrence.completed ? '取消完成' : '标记已完成'),
      ),
      OutlinedButton.icon(
        key: const ValueKey('calendar-personal-toggle-skipped'),
        onPressed: canWrite
            ? () => _execute(
                SetPersonalOccurrenceState(
                  target,
                  skipped: !occurrence.skipped,
                ),
                widget.controller,
                expectedContext: target.context,
              )
            : null,
        icon: Icon(
          occurrence.skipped
              ? Icons.event_available_outlined
              : Icons.event_busy_outlined,
        ),
        label: Text(occurrence.skipped ? '恢复本次' : '跳过本次'),
      ),
      if (isWeekly)
        OutlinedButton.icon(
          key: const ValueKey('calendar-personal-delete-series'),
          onPressed: canWrite
              ? () => _confirmDeleteSeries(detail, widget.controller)
              : null,
          icon: const Icon(Icons.delete_outline_rounded),
          label: const Text('删除整组'),
        )
      else
        OutlinedButton.icon(
          key: const ValueKey('calendar-personal-delete-series'),
          onPressed: canWrite
              ? () => _confirmDeleteSingle(detail, widget.controller)
              : null,
          icon: const Icon(Icons.delete_outline_rounded),
          label: const Text('删除这条安排'),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(spacing: 7, runSpacing: 7, children: actions),
        if (isWeekly) ...[
          const SizedBox(height: 8),
          const Text(
            '整组编辑会保留已修改例外的内容和绝对时间；缩短为单次会暂时停止超出范围的投影，例外记录仍保留。',
            style: TextStyle(color: _muted, fontSize: 12, height: 1.4),
          ),
        ],
        if (replacementOnly) ...[
          const SizedBox(height: 8),
          const Text(
            '当前内容是保留的单次修改。“编辑安排”修改当前内容；“设置重复”调整原始安排的重复方式。',
            style: TextStyle(color: _muted, fontSize: 12, height: 1.4),
          ),
        ],
        if (!isWeekly) ...[
          const SizedBox(height: 8),
          const Text(
            '删除会移除这条单次安排；跳过与恢复是单独操作。最近一次成功的本地修改可在工具栏撤销，最多保留 24 小时。',
            style: TextStyle(color: _muted, fontSize: 12, height: 1.4),
          ),
        ],
        if (!canWrite) ...[
          const SizedBox(height: 8),
          Text(
            _writeBlockedMessage(view),
            textAlign: TextAlign.center,
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Widget _planBlockActions(CalendarWorkspaceView view, CalendarDetail detail) {
    final block = detail.planBlock;
    final tasks = widget.tasks;
    if (block == null || tasks == null) {
      return const _StatusLine(
        text: '关联的任务时间块详情暂不可用。',
        icon: Icons.info_outline_rounded,
      );
    }
    final canWrite = view.canWrite && tasks.taskView.canWrite && !_actionBusy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('calendar-plan-block-edit'),
              onPressed: canWrite ? () => _editPlanBlock(block, tasks) : null,
              icon: const Icon(Icons.edit_calendar_outlined),
              label: const Text('移动或编辑时间块'),
            ),
            PopupMenuButton<PlanBlockStatus>(
              key: const ValueKey('calendar-plan-block-status'),
              tooltip: '调整时间块状态',
              enabled: canWrite,
              onSelected: (status) => unawaited(
                _executeTaskWrite(
                  tasks,
                  SetPlanBlockStatus(block.reference, status),
                  block.task.context,
                ),
              ),
              itemBuilder: (context) => [
                for (final status in PlanBlockStatus.values)
                  if (status != block.status)
                    PopupMenuItem(
                      value: status,
                      child: Text('设为${_planBlockStatusLabel(status)}'),
                    ),
              ],
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFFD4DDD7)),
                  borderRadius: BorderRadius.circular(9),
                  color: Colors.white,
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.sync_alt_rounded, size: 17),
                    SizedBox(width: 5),
                    Text('设置状态', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ),
            OutlinedButton.icon(
              key: const ValueKey('calendar-plan-block-open-task'),
              onPressed: () => _openTaskFromPlanBlock(block, tasks),
              icon: const Icon(Icons.task_alt_rounded),
              label: const Text('打开关联任务'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('calendar-plan-block-delete'),
              onPressed: canWrite
                  ? () => _confirmDeletePlanBlock(block, tasks)
                  : null,
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('删除时间块'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          '任务状态和时间块状态分别由你确认；到时只提示复核，不会自动完成。',
          style: TextStyle(color: _muted, fontSize: 12, height: 1.4),
        ),
        if (!canWrite) ...[
          const SizedBox(height: 8),
          Text(
            tasks.taskView.sourceBusy
                ? '来源操作进行中，当前暂不能修改时间块。'
                : _writeBlockedMessage(view),
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Future<void> _editPlanBlock(
    PlanBlockRecord block,
    TaskWorkspacePort tasks,
  ) async {
    final target = block.reference;
    final expectedContext = target.context;
    final generation = _controllerGeneration;
    final draft = await _withRoute<PlanBlockDraft>(
      () => showPlanBlockEditor(
        context,
        heading: '移动或编辑时间块',
        today: tasks.today,
        initial: block.draft,
      ),
    );
    if (draft == null || !_currentTaskPort(tasks, generation)) return;
    await _executeTaskWrite(
      tasks,
      UpdatePlanBlock(target, draft),
      expectedContext,
    );
  }

  Future<void> _confirmDeletePlanBlock(
    PlanBlockRecord block,
    TaskWorkspacePort tasks,
  ) async {
    final target = block.reference;
    final generation = _controllerGeneration;
    final confirmed = await _withRoute<bool>(
      () => showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除时间块？'),
          content: const Text('这只会删除当前时间块，不会改变关联任务的状态。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF9B2C2C),
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除时间块'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !_currentTaskPort(tasks, generation)) return;
    await _executeTaskWrite(
      tasks,
      DeletePlanBlock(target, confirmed: true),
      target.context,
    );
  }

  Future<void> _openTaskFromPlanBlock(
    PlanBlockRecord block,
    TaskWorkspacePort tasks,
  ) async {
    final generation = _controllerGeneration;
    try {
      // Explicit navigation must include completed/cancelled tasks even when
      // the task list was previously filtered to open work or another title.
      await tasks.loadTasks(
        query: TaskQuery(
          filter: TaskFilter.all,
          keyword: block.taskTitle,
          limit: 500,
        ),
      );
      if (!_currentTaskPort(tasks, generation)) return;
      await tasks.selectTask(block.task);
      if (!_currentTaskPort(tasks, generation)) return;
      if (_routeDepth > 0) await _dismissRoutes(_routeDepth);
      if (!_currentTaskPort(tasks, generation)) return;
      setState(() {
        _tasksSelected = true;
        _notice = null;
      });
    } on CalendarFailure catch (failure) {
      if (_currentTaskPort(tasks, generation)) {
        setState(() => _notice = _taskFailureMessageForPage(failure.code));
      }
    } catch (_) {
      if (_currentTaskPort(tasks, generation)) {
        setState(() => _notice = '无法读取关联任务，请稍后重试。');
      }
    }
  }

  Future<void> _undoTaskWrite(
    TaskWorkspacePort tasks,
    CalendarUndoView undo,
  ) async {
    final target = undo.reference;
    if (target == null || !undo.canUndo) return;
    await _executeTaskWrite(
      tasks,
      UndoCalendarWrite(target),
      target.context,
      successMessage: '已撤销最近一次本地修改。',
    );
  }

  Future<bool> _executeTaskWrite(
    TaskWorkspacePort tasks,
    CalendarIntent intent,
    CalendarContext expectedContext, {
    String successMessage = '已保存。',
  }) async {
    final generation = _controllerGeneration;
    if (!_currentTaskPort(tasks, generation)) return false;
    if (!tasks.taskView.canWrite || _actionBusy) {
      final message = tasks.taskView.sourceBusy
          ? '来源操作进行中，当前暂不能修改任务。'
          : tasks.taskView.failure == null
          ? '当前任务数据尚未就绪，暂时不能保存。'
          : _taskFailureMessageForPage(tasks.taskView.failure!);
      setState(() => _notice = message);
      return false;
    }
    setState(() {
      _actionBusy = true;
      _notice = null;
    });
    try {
      await tasks.executeTask(intent, expectedContext: expectedContext);
      if (!mounted || !_currentTaskPort(tasks, generation)) return false;
      setState(() => _notice = successMessage);
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(successMessage)));
      return true;
    } on CalendarFailure catch (failure) {
      if (!mounted || !_currentTaskPort(tasks, generation)) return false;
      final message = _taskFailureMessageForPage(failure.code);
      setState(() => _notice = message);
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(message)));
      return false;
    } catch (_) {
      if (!mounted || !_currentTaskPort(tasks, generation)) return false;
      const message = '保存未完成。请检查当前任务状态后重试。';
      setState(() => _notice = message);
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text(message)));
      return false;
    } finally {
      if (_currentTaskPort(tasks, generation)) {
        setState(() => _actionBusy = false);
      }
    }
  }

  bool _currentTaskPort(TaskWorkspacePort tasks, int generation) =>
      mounted &&
      identical(widget.tasks, tasks) &&
      generation == _controllerGeneration;

  Widget _schoolActions(CalendarWorkspaceView view, CalendarDetail detail) {
    final occurrence = detail.occurrence;
    final canWrite = view.canWrite && !_actionBusy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('calendar-school-edit-annotation'),
              onPressed: canWrite
                  ? () => _editSchoolAnnotation(detail, widget.controller)
                  : null,
              icon: const Icon(Icons.edit_note_rounded),
              label: const Text('编辑个人备注与计划'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('calendar-school-toggle-hidden'),
              onPressed: canWrite
                  ? () => _execute(
                      UpdateSchoolAnnotation(
                        occurrence.reference,
                        hidden: !occurrence.hidden,
                      ),
                      widget.controller,
                      expectedContext: occurrence.reference.context,
                    )
                  : null,
              icon: Icon(
                occurrence.hidden
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
              label: Text(occurrence.hidden ? '恢复显示' : '隐藏这条日程'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          '这里只保存你的备注和计划，不修改学校记录或学校完成事实。',
          style: TextStyle(color: _muted, fontSize: 12, height: 1.4),
        ),
        if (!canWrite) ...[
          const SizedBox(height: 8),
          Text(
            _writeBlockedMessage(view),
            textAlign: TextAlign.center,
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Widget _conflictCard(
    CalendarWorkspaceView view,
    CalendarOccurrence current,
    CalendarConflict conflict,
  ) {
    final other = conflict.left.reference.identity == current.reference.identity
        ? conflict.right
        : conflict.left;
    final relation = conflict.relation;
    final status = conflict.status;
    return Card(
      color: const Color(0xFFF8FAF9),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              other.title,
              softWrap: true,
              style: TextStyle(
                color: calendarColorsForTitle(other.title).ink,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${_kindLabel(other.reference.identity.kind)} · ${_occurrenceTime(other)}${_presenceSuffix(other)}',
              style: const TextStyle(color: _muted, fontSize: 12),
            ),
            const SizedBox(height: 4),
            Text(
              '判定：${_conflictSummaryLabel(conflict)}',
              style: TextStyle(
                color: _conflictStatusColor(status),
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
            if (relation != null) ...[
              const SizedBox(height: 5),
              Text(
                '${relation.kind == CalendarRelationKind.legacyUndecided ? '旧说明已保留' : '已保存判定：${_relationKindLabel(relation.kind)}'}'
                '${relation.note.trim().isEmpty ? '' : ' · ${relation.note}'}',
                softWrap: true,
                style: const TextStyle(color: _muted, fontSize: 12),
              ),
            ],
            if (relation?.kind == CalendarRelationKind.legacyUndecided) ...[
              const SizedBox(height: 4),
              const Text(
                '旧说明已保留；当前按重叠默认显示冲突。',
                style: TextStyle(color: _muted, fontSize: 11),
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: ValueKey(
                  'calendar-relation-edit-${other.reference.identity.kind.name}-${other.reference.identity.ordinal}',
                ),
                onPressed: view.canWrite && !_actionBusy
                    ? () => _editRelation(conflict, widget.controller)
                    : null,
                icon: const Icon(Icons.link_rounded),
                label: Text(conflict.hasExplicitDecision ? '修改判定' : '确认判定'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _relationCard(
    CalendarWorkspaceView view,
    CalendarOccurrence current,
    CalendarRelation relation,
  ) {
    final other = relation.left == current.reference.identity
        ? relation.right
        : relation.left;
    final canWrite = view.canWrite && !_actionBusy;
    return Card(
      color: const Color(0xFFF8FAF9),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              relation.kind == CalendarRelationKind.legacyUndecided
                  ? '旧说明已保留；未保存明确判断'
                  : '已保存判定：${_relationKindLabel(relation.kind)}',
            ),
            const SizedBox(height: 4),
            Text(
              '另一条${_kindLabel(other.kind)}安排；当前是否重叠以候选列表为准。',
              style: const TextStyle(color: _muted, fontSize: 11),
            ),
            if (relation.note.trim().isNotEmpty) ...[
              const SizedBox(height: 5),
              Text(relation.note, softWrap: true),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('calendar-relation-delete'),
                onPressed: canWrite
                    ? () => _confirmDeleteRelation(relation, widget.controller)
                    : null,
                icon: const Icon(Icons.link_off_rounded),
                label: const Text('删除这条判定说明'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _noticeCard(String message, {required IconData icon}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: const Color(0xFFFFF6E6),
      border: Border.all(color: const Color(0xFFF0D9A8)),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: const Color(0xFF805900)),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            message,
            softWrap: true,
            style: const TextStyle(
              color: Color(0xFF624900),
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ),
      ],
    ),
  );

  Future<void> _moveDay(CalendarWorkspaceView view, int direction) async {
    final days = view.mode == CalendarViewMode.week ? 7 : 1;
    final day = _dateOnly(view.day);
    final next = DateTime.utc(day.year, day.month, day.day + direction * days);
    await _load(widget.controller, day: next);
  }

  Future<void> _pickWorkspaceDate(CalendarWorkspaceView view) async {
    final port = widget.controller;
    final selected = _dateOnly(view.day);
    final result = await _withRoute<DateTime>(
      () => showDatePicker(
        context: context,
        initialDate: DateTime(selected.year, selected.month, selected.day),
        firstDate: DateTime(1),
        lastDate: DateTime(9998, 12, 31),
        helpText: '选择北京时间日期',
      ),
    );
    if (!mounted || !identical(port, widget.controller) || result == null) {
      return;
    }
    await _load(port, day: DateTime.utc(result.year, result.month, result.day));
  }

  Future<void> _load(
    CalendarWorkspacePort port, {
    DateTime? day,
    CalendarViewMode? mode,
    CalendarFilter? filter,
    bool? includeInactive,
    CalendarReference? initialSelection,
  }) async {
    if (!mounted || !identical(port, widget.controller)) return;
    final controllerGeneration = _controllerGeneration;
    final loadGeneration = ++_loadGeneration;
    final selectionGeneration = ++_selectionGeneration;
    setState(() {
      _selectedReference = null;
      _notice = null;
    });
    try {
      try {
        await port.select(null);
      } catch (_) {
        // A query still goes through the C3 workspace port; selection is local.
      }
      if (!mounted ||
          !identical(port, widget.controller) ||
          controllerGeneration != _controllerGeneration ||
          loadGeneration != _loadGeneration) {
        return;
      }
      await port.load(
        day: day,
        mode: mode,
        filter: filter,
        includeInactive: includeInactive,
      );
      if (!_current(port, controllerGeneration, loadGeneration)) return;
      if (initialSelection != null) {
        await _applyInitialSelection(
          port,
          controllerGeneration,
          loadGeneration,
          selectionGeneration,
          initialSelection,
        );
      }
    } on CalendarFailure catch (failure) {
      if (_current(port, controllerGeneration, loadGeneration)) {
        setState(() => _notice = _failureMessage(failure.code));
        if (initialSelection != null) {
          _consumeInitialNavigation(expectedSelection: initialSelection);
        }
      }
    } catch (_) {
      if (_current(port, controllerGeneration, loadGeneration)) {
        setState(
          () => _notice = _failureMessage(CalendarFailureCode.storageFailed),
        );
        if (initialSelection != null) {
          _consumeInitialNavigation(expectedSelection: initialSelection);
        }
      }
    }
  }

  void _consumeInitialTasksNavigationIfReady() {
    if (!widget.initialTasks || widget.initialSelection != null) return;
    _consumeInitialNavigation();
  }

  void _consumeInitialNavigation({CalendarReference? expectedSelection}) {
    if (!_hasPendingInitialNavigation || _initialNavigationConsumed) return;
    if (expectedSelection != null &&
        widget.initialSelection != expectedSelection) {
      return;
    }
    _initialNavigationConsumed = true;
    _hasPendingInitialNavigation = false;
    if (widget.initialTasks && widget.initialSelection == null) {
      _initialTasksWasConsumed = true;
    }
    widget.onInitialNavigationConsumed?.call();
  }

  Future<void> _applyInitialSelection(
    CalendarWorkspacePort port,
    int controllerGeneration,
    int loadGeneration,
    int selectionGeneration,
    CalendarReference reference,
  ) async {
    bool isCurrentRequest() =>
        _current(port, controllerGeneration, loadGeneration) &&
        selectionGeneration == _selectionGeneration &&
        widget.initialSelection == reference;

    if (!isCurrentRequest()) return;
    if (port.view.window == null ||
        port.view.window!.context != reference.context) {
      setState(() {
        _selectedReference = null;
        _notice = '这条日程已更新或当前未能验证，请重新查询后再选择。';
      });
      _consumeInitialNavigation(expectedSelection: reference);
      return;
    }
    try {
      await port.select(reference);
    } on Object {
      if (!isCurrentRequest()) return;
      setState(() {
        _selectedReference = null;
        _notice = '这条日程已更新或当前未能验证，请重新查询后再选择。';
      });
      _consumeInitialNavigation(expectedSelection: reference);
      return;
    }
    if (!isCurrentRequest()) return;
    if (port.view.detail?.occurrence.reference != reference) {
      setState(() {
        _selectedReference = null;
        _notice = '这条日程已更新或当前未能验证，请重新查询后再选择。';
      });
      _consumeInitialNavigation(expectedSelection: reference);
      return;
    }
    setState(() {
      _selectedReference = reference;
      _notice = null;
    });
    _consumeInitialNavigation(expectedSelection: reference);
    if (!mounted) return;
    if (MediaQuery.sizeOf(context).width < 1080) {
      await _showDetailSheet(port);
    }
  }

  Future<void> _selectOccurrence(
    CalendarOccurrence occurrence, {
    required bool showSheet,
    CalendarWorkspacePort? expectedPort,
    int? expectedGeneration,
  }) async {
    final port = expectedPort ?? widget.controller;
    final controllerGeneration = expectedGeneration ?? _controllerGeneration;
    if (!_currentController(port, controllerGeneration)) return;
    final selectionGeneration = ++_selectionGeneration;
    setState(() {
      _selectedReference = occurrence.reference;
      _notice = null;
    });
    try {
      await port.select(occurrence.reference);
    } on CalendarFailure catch (failure) {
      if (_currentController(port, controllerGeneration)) {
        setState(() => _notice = _failureMessage(failure.code));
      }
      return;
    } catch (_) {
      if (_currentController(port, controllerGeneration)) {
        setState(
          () => _notice = _failureMessage(CalendarFailureCode.storageFailed),
        );
      }
      return;
    }
    if (!_currentController(port, controllerGeneration) ||
        selectionGeneration != _selectionGeneration) {
      return;
    }
    if (showSheet) {
      await _showDetailSheet(port);
    }
  }

  Future<void> _showDetailSheet(CalendarWorkspacePort port) => _withRoute<void>(
    () => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AnimatedBuilder(
        animation: port,
        builder: (context, _) =>
            _detailPanel(context, port.view, compact: true),
      ),
    ),
  );

  Future<bool> _execute(
    CalendarIntent intent,
    CalendarWorkspacePort port, {
    required CalendarContext expectedContext,
  }) async {
    if (!mounted || !identical(port, widget.controller)) return false;
    final controllerGeneration = _controllerGeneration;
    final actionGeneration = ++_actionGeneration;
    if (!port.view.canWrite || _actionBusy) {
      final message = _writeBlockedMessage(port.view);
      setState(() => _notice = message);
      _actionFeedback.value = message;
      return false;
    }
    _actionFeedback.value = null;
    setState(() {
      _actionBusy = true;
      _notice = null;
    });
    final previousIdentity = _selectedReference?.identity;
    try {
      await port.execute(intent, expectedContext: expectedContext);
      if (!mounted ||
          !_currentAction(port, controllerGeneration, actionGeneration)) {
        return false;
      }
      final refreshedReference = port.view.detail?.occurrence.reference;
      setState(() {
        _selectedReference =
            previousIdentity != null &&
                refreshedReference?.identity == previousIdentity
            ? refreshedReference
            : null;
        _notice = '已保存。';
      });
      _actionFeedback.value = null;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('已保存。')));
      // C5 resolves execute only after its committed receipt and refresh result.
      // The receipt remains success even when the separate view shows a read
      // failure.
      return true;
    } on CalendarFailure catch (failure) {
      if (mounted &&
          _currentAction(port, controllerGeneration, actionGeneration)) {
        final message = _failureMessage(failure.code);
        setState(() => _notice = message);
        _actionFeedback.value = message;
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(message)));
      }
      return false;
    } catch (_) {
      if (mounted &&
          _currentAction(port, controllerGeneration, actionGeneration)) {
        final message = _failureMessage(CalendarFailureCode.storageFailed);
        setState(() => _notice = message);
        _actionFeedback.value = message;
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(message)));
      }
      return false;
    } finally {
      if (_currentController(port, controllerGeneration) &&
          actionGeneration == _actionGeneration) {
        setState(() => _actionBusy = false);
      }
    }
  }

  Future<void> _openPersonalEditor({
    required CalendarWorkspacePort port,
    required CalendarContext expectedContext,
    required PersonalEventDraft initial,
    required String heading,
    required String explanation,
    required bool allowWeekly,
    required CalendarIntent Function(PersonalEventDraft) intentFor,
  }) async {
    final controllerGeneration = _controllerGeneration;
    await _withRoute<bool>(
      () => showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (_) => CalendarEventEditor(
          key: const ValueKey('calendar-event-editor'),
          initialDraft: initial,
          heading: heading,
          explanation: explanation,
          controller: port,
          feedback: _actionFeedback,
          allowWeekly: allowWeekly,
          canSave: () =>
              identical(port, widget.controller) && port.view.canWrite,
          isCurrent: () =>
              mounted &&
              identical(port, widget.controller) &&
              controllerGeneration == _controllerGeneration,
          onOverlayChanged: (opened) =>
              _trackOverlay(opened, controllerGeneration),
          onSave: (draft) {
            if (!identical(port, widget.controller) ||
                controllerGeneration != _controllerGeneration) {
              return Future.value(false);
            }
            return _execute(
              intentFor(draft),
              port,
              expectedContext: expectedContext,
            );
          },
        ),
      ),
    );
  }

  Future<void> _editSeries(
    CalendarDetail detail,
    CalendarWorkspacePort port,
  ) async {
    final draft = detail.personalDraft;
    if (draft == null) return;
    await _openPersonalEditor(
      port: port,
      expectedContext: detail.occurrence.reference.context,
      initial: draft,
      heading: draft.weekly
          ? '编辑整组个人安排'
          : detail.hasOccurrenceReplacement
          ? '设置重复'
          : '编辑个人安排',
      explanation: draft.weekly
          ? '已修改例外的内容和绝对时间会保留；缩短截止日期或改为单次时，范围外例外会暂时停止投影但仍保留。'
          : detail.hasOccurrenceReplacement
          ? '当前安排保留了单次修改的内容；这里设置原始时间和重复方式，不会覆盖当前内容。'
          : '按北京时间修改这条安排，也可设置为每周重复。',
      allowWeekly: true,
      intentFor: (next) =>
          UpdatePersonalSeries(detail.occurrence.reference, next),
    );
  }

  Future<void> _editOccurrence(
    CalendarDetail detail,
    CalendarWorkspacePort port,
  ) async {
    final occurrence = detail.occurrence;
    final initial = _draftForOccurrence(occurrence);
    await _openPersonalEditor(
      port: port,
      expectedContext: occurrence.reference.context,
      initial: initial,
      heading: '修改本次安排',
      explanation: detail.personalDraft?.weekly == true
          ? '本次改为绝对日期和时刻；下一次仍按原系列继续。'
          : '修改当前这条安排的内容和时间，保留原始重复设置与其他单次决定。',
      allowWeekly: false,
      intentFor: (replacement) => UpdatePersonalOccurrence(
        occurrence.reference,
        PersonalEventDraft(
          title: replacement.title,
          start: replacement.start,
          end: replacement.end,
          allDay: replacement.allDay,
          weekly: false,
          location: replacement.location,
          note: replacement.note,
        ),
      ),
    );
  }

  Future<void> _confirmDeleteSeries(
    CalendarDetail detail,
    CalendarWorkspacePort port,
  ) async {
    final confirmed = await _withRoute<bool>(
      () => showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除整个个人安排？'),
          content: const Text(
            '这会删除整组安排和它的例外。最近一次成功的本地修改可从工具栏撤销，最多保留 24 小时；记录已变化时撤销会拒绝。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('calendar-personal-confirm-delete-series'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除整组'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted || !identical(port, widget.controller)) {
      return;
    }
    await _execute(
      DeletePersonalSeries(detail.occurrence.reference, confirmed: true),
      port,
      expectedContext: detail.occurrence.reference.context,
    );
  }

  Future<void> _confirmDeleteSingle(
    CalendarDetail detail,
    CalendarWorkspacePort port,
  ) async {
    final confirmed = await _withRoute<bool>(
      () => showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除这条个人安排？'),
          content: const Text(
            '这会从本地日程移除这条单次安排。最近一次成功的本地修改可从工具栏撤销，最多保留 24 小时；记录已变化时撤销会拒绝。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('calendar-personal-confirm-delete-single'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除安排'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted || !identical(port, widget.controller)) {
      return;
    }
    await _execute(
      DeletePersonalSeries(detail.occurrence.reference, confirmed: true),
      port,
      expectedContext: detail.occurrence.reference.context,
    );
  }

  Future<void> _editSchoolAnnotation(
    CalendarDetail detail,
    CalendarWorkspacePort port,
  ) async {
    final occurrence = detail.occurrence;
    final generation = _controllerGeneration;
    await _withRoute<void>(
      () => showDialog<void>(
        context: context,
        builder: (context) => _SchoolAnnotationEditor(
          controller: port,
          feedback: _actionFeedback,
          kind: occurrence.reference.identity.kind,
          note: occurrence.note,
          attendance: occurrence.attendance,
          listening: occurrence.listening,
          canSave: () =>
              identical(port, widget.controller) && port.view.canWrite,
          isCurrent: () =>
              mounted &&
              identical(port, widget.controller) &&
              generation == _controllerGeneration,
          onSave: (note, attendance, listening) => _execute(
            UpdateSchoolAnnotation(
              occurrence.reference,
              note: note,
              attendance: attendance,
              listening: listening,
            ),
            port,
            expectedContext: occurrence.reference.context,
          ),
        ),
      ),
    );
  }

  Future<void> _editRelation(
    CalendarConflict conflict,
    CalendarWorkspacePort port,
  ) async {
    final existing = conflict.relation;
    final generation = _controllerGeneration;
    await _withRoute<void>(
      () => showDialog<void>(
        context: context,
        builder: (context) => _CalendarRelationEditor(
          controller: port,
          feedback: _actionFeedback,
          conflict: conflict,
          initialKind: existing?.kind == CalendarRelationKind.notConflict
              ? CalendarRelationKind.notConflict
              : CalendarRelationKind.conflict,
          legacyUndecided:
              existing?.kind == CalendarRelationKind.legacyUndecided,
          initialNote: existing?.note ?? '',
          canSave: () =>
              identical(port, widget.controller) && port.view.canWrite,
          isCurrent: () =>
              mounted &&
              identical(port, widget.controller) &&
              generation == _controllerGeneration,
          onSave: (kind, note) => _execute(
            SaveCalendarRelation(
              left: conflict.left.reference,
              right: conflict.right.reference,
              kind: kind,
              note: note,
              existing: existing?.reference,
            ),
            port,
            expectedContext: conflict.left.reference.context,
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDeleteRelation(
    CalendarRelation relation,
    CalendarWorkspacePort port,
  ) async {
    final confirmed = await _withRoute<bool>(
      () => showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除判定说明？'),
          content: const Text('删除后将移除这条已保存的日程判定说明。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('calendar-relation-confirm-delete'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除判定说明'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted || !identical(port, widget.controller)) {
      return;
    }
    await _execute(
      DeleteCalendarRelation(relation.reference),
      port,
      expectedContext: relation.reference.context,
    );
  }

  Future<T?> _withRoute<T>(Future<T?> Function() show) async {
    final generation = _controllerGeneration;
    _routeDepth++;
    try {
      return await show();
    } finally {
      if (mounted && generation == _controllerGeneration && _routeDepth > 0) {
        _routeDepth--;
      }
    }
  }

  void _trackOverlay(bool opened, int controllerGeneration) {
    if (!mounted || controllerGeneration != _controllerGeneration) return;
    if (opened) {
      _routeDepth++;
    } else if (_routeDepth > 0) {
      _routeDepth--;
    }
  }

  void _trackTransientRouteOpened(int controllerGeneration) {
    if (!mounted || controllerGeneration != _controllerGeneration) return;
    _routeDepth++;
  }

  void _trackTransientRouteClosed(int controllerGeneration) {
    if (!mounted || controllerGeneration != _controllerGeneration) return;
    if (_routeDepth > 0) _routeDepth--;
  }

  Future<void> _dismissRoutes(
    int count, [
    NavigatorState? knownNavigator,
  ]) async {
    if (count <= 0) return;
    final navigator = knownNavigator ?? _navigator;
    if (navigator == null) return;
    for (var index = 0; index < count; index++) {
      if (!navigator.mounted || !navigator.canPop()) return;
      await navigator.maybePop();
    }
  }

  void _forgetSelection(CalendarWorkspacePort port) {
    _selectionGeneration++;
    _selectedReference = null;
    if (mounted) setState(() {});
    unawaited(port.select(null).catchError((Object _) {}));
  }

  bool _current(
    CalendarWorkspacePort port,
    int controllerGeneration,
    int loadGeneration,
  ) =>
      mounted &&
      identical(port, widget.controller) &&
      controllerGeneration == _controllerGeneration &&
      loadGeneration == _loadGeneration;

  bool _currentController(
    CalendarWorkspacePort port,
    int controllerGeneration,
  ) =>
      mounted &&
      identical(port, widget.controller) &&
      controllerGeneration == _controllerGeneration;

  bool _currentAction(
    CalendarWorkspacePort port,
    int controllerGeneration,
    int actionGeneration,
  ) =>
      _currentController(port, controllerGeneration) &&
      actionGeneration == _actionGeneration;

  String _writeBlockedMessage(CalendarWorkspaceView view) {
    if (view.sourceBusy) return '来源操作正在进行，当前只允许浏览日程。';
    if (view.actionPending || _actionBusy) return '已有本地日程操作正在处理，请稍后再试。';
    if (view.failure != null) return _failureMessage(view.failure!);
    if (view.window == null || view.loading) return '日程尚未读取完成，暂不能写入。';
    return '当前日程不可写入，请稍后重试。';
  }
}

final class _SchoolAnnotationEditor extends StatefulWidget {
  const _SchoolAnnotationEditor({
    required this.controller,
    required this.feedback,
    required this.kind,
    required this.note,
    required this.attendance,
    required this.listening,
    required this.canSave,
    required this.isCurrent,
    required this.onSave,
  });

  final CalendarWorkspacePort controller;
  final ValueListenable<String?> feedback;
  final CalendarKind kind;
  final String note;
  final AttendanceDecision attendance;
  final ListeningMode listening;
  final bool Function() canSave;
  final bool Function() isCurrent;
  final Future<bool> Function(
    String note,
    AttendanceDecision? attendance,
    ListeningMode? listening,
  )
  onSave;

  @override
  State<_SchoolAnnotationEditor> createState() =>
      _SchoolAnnotationEditorState();
}

final class _SchoolAnnotationEditorState
    extends State<_SchoolAnnotationEditor> {
  late final TextEditingController _note;
  late AttendanceDecision _attendance;
  late ListeningMode _listening;
  bool _saving = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _note = TextEditingController(text: widget.note);
    _attendance = widget.attendance;
    _listening = widget.listening;
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('编辑个人备注与计划'),
    content: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 480,
        maxHeight: MediaQuery.sizeOf(context).height * .62,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.kind == CalendarKind.course ||
                widget.kind == CalendarKind.young) ...[
              DropdownButtonFormField<AttendanceDecision>(
                key: const ValueKey('calendar-school-attendance'),
                initialValue: _attendance,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '出勤计划'),
                items: AttendanceDecision.values
                    .map(
                      (value) => DropdownMenuItem(
                        value: value,
                        child: Text(_attendanceLabel(value)),
                      ),
                    )
                    .toList(growable: false),
                onChanged: _saving
                    ? null
                    : (value) {
                        if (value != null) setState(() => _attendance = value);
                      },
              ),
              const SizedBox(height: 12),
            ],
            if (widget.kind == CalendarKind.course) ...[
              DropdownButtonFormField<ListeningMode>(
                key: const ValueKey('calendar-school-listening'),
                initialValue: _listening,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '听讲方式'),
                items: ListeningMode.values
                    .map(
                      (value) => DropdownMenuItem(
                        value: value,
                        child: Text(_listeningLabel(value)),
                      ),
                    )
                    .toList(growable: false),
                onChanged: _saving
                    ? null
                    : (value) {
                        if (value != null) setState(() => _listening = value);
                      },
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              key: const ValueKey('calendar-school-note'),
              controller: _note,
              maxLength: 4000,
              minLines: 3,
              maxLines: 7,
              enabled: !_saving,
              decoration: const InputDecoration(labelText: '个人备注'),
            ),
            const Text(
              '这些内容属于你的计划，不会改变学校来源记录。',
              style: TextStyle(color: _muted, fontSize: 12),
            ),
            if (_message != null) ...[
              const SizedBox(height: 8),
              Text(_message!, style: const TextStyle(color: Color(0xFF9B2C2C))),
            ],
            ValueListenableBuilder<String?>(
              valueListenable: widget.feedback,
              builder: (context, message, _) => message == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        message,
                        style: const TextStyle(color: Color(0xFF9B2C2C)),
                      ),
                    ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) => FilledButton(
          key: const ValueKey('calendar-school-save'),
          onPressed: _saving || !widget.canSave() || !widget.isCurrent()
              ? null
              : _save,
          child: Text(_saving ? '正在保存…' : '保存'),
        ),
      ),
    ],
  );

  Future<void> _save() async {
    if (!widget.isCurrent()) return;
    if (_note.text.length > 4000) {
      setState(() => _message = '备注最多 4000 字。');
      return;
    }
    setState(() {
      _saving = true;
      _message = null;
    });
    var saved = false;
    try {
      saved = await widget.onSave(
        _note.text,
        widget.kind == CalendarKind.course || widget.kind == CalendarKind.young
            ? _attendance
            : null,
        widget.kind == CalendarKind.course ? _listening : null,
      );
    } finally {
      if (mounted && widget.isCurrent()) setState(() => _saving = false);
    }
    if (!mounted || !widget.isCurrent()) return;
    if (saved) Navigator.of(context).pop();
  }
}

final class _CalendarRelationEditor extends StatefulWidget {
  const _CalendarRelationEditor({
    required this.controller,
    required this.feedback,
    required this.conflict,
    required this.initialKind,
    required this.legacyUndecided,
    required this.initialNote,
    required this.canSave,
    required this.isCurrent,
    required this.onSave,
  });

  final CalendarWorkspacePort controller;
  final ValueListenable<String?> feedback;
  final CalendarConflict conflict;
  final CalendarRelationKind initialKind;
  final bool legacyUndecided;
  final String initialNote;
  final bool Function() canSave;
  final bool Function() isCurrent;
  final Future<bool> Function(CalendarRelationKind kind, String note) onSave;

  @override
  State<_CalendarRelationEditor> createState() =>
      _CalendarRelationEditorState();
}

final class _CalendarRelationEditorState
    extends State<_CalendarRelationEditor> {
  late final TextEditingController _note;
  late CalendarRelationKind _kind;
  bool _saving = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _note = TextEditingController(text: widget.initialNote);
    _kind = widget.initialKind;
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('冲突判定'),
    content: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 440,
        maxHeight: MediaQuery.sizeOf(context).height * .62,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.conflict.left.title,
              style: TextStyle(
                color: calendarColorsForTitle(widget.conflict.left.title).ink,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              '${_kindLabel(widget.conflict.left.reference.identity.kind)} · ${_occurrenceTime(widget.conflict.left)}${_presenceSuffix(widget.conflict.left)}',
              style: const TextStyle(color: _muted, fontSize: 11),
            ),
            const SizedBox(height: 8),
            Text(
              widget.conflict.right.title,
              style: TextStyle(
                color: calendarColorsForTitle(widget.conflict.right.title).ink,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              '${_kindLabel(widget.conflict.right.reference.identity.kind)} · ${_occurrenceTime(widget.conflict.right)}${_presenceSuffix(widget.conflict.right)}',
              style: const TextStyle(color: _muted, fontSize: 11),
            ),
            const SizedBox(height: 8),
            Text(
              '当前状态：${_conflictSummaryLabel(widget.conflict)}',
              style: TextStyle(
                color: _conflictStatusColor(widget.conflict.status),
                fontWeight: FontWeight.w600,
              ),
            ),
            if (widget.legacyUndecided) ...[
              const SizedBox(height: 4),
              const Text(
                '旧说明已保留；当前按重叠默认显示冲突。可确认冲突或改为不冲突，保存后才记录本次选择。',
                style: TextStyle(color: _muted, height: 1.4),
              ),
            ] else ...[
              const SizedBox(height: 4),
              const Text(
                '当前按时间重叠默认显示冲突；可保留此判定或改为不冲突。保存后才记录本次选择。',
                style: TextStyle(color: _muted, height: 1.4),
              ),
            ],
            const SizedBox(height: 12),
            DropdownButtonFormField<CalendarRelationKind>(
              key: const ValueKey('calendar-relation-kind'),
              initialValue: _kind,
              isExpanded: true,
              hint: const Text('请选择'),
              decoration: const InputDecoration(labelText: '冲突判定'),
              items: const [
                DropdownMenuItem(
                  value: CalendarRelationKind.conflict,
                  child: Text('冲突'),
                ),
                DropdownMenuItem(
                  value: CalendarRelationKind.notConflict,
                  child: Text('不冲突'),
                ),
              ],
              onChanged: _saving
                  ? null
                  : (value) {
                      if (value != null) setState(() => _kind = value);
                    },
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('calendar-relation-note'),
              controller: _note,
              maxLength: 4000,
              minLines: 3,
              maxLines: 6,
              enabled: !_saving,
              decoration: const InputDecoration(labelText: '说明（可选）'),
            ),
            if (_message != null)
              Text(_message!, style: const TextStyle(color: Color(0xFF9B2C2C))),
            ValueListenableBuilder<String?>(
              valueListenable: widget.feedback,
              builder: (context, message, _) => message == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        message,
                        style: const TextStyle(color: Color(0xFF9B2C2C)),
                      ),
                    ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) => FilledButton(
          key: const ValueKey('calendar-relation-save'),
          onPressed: _saving || !widget.canSave() || !widget.isCurrent()
              ? null
              : _save,
          child: Text(_saving ? '正在保存…' : '保存判定'),
        ),
      ),
    ],
  );

  Future<void> _save() async {
    if (!widget.isCurrent()) return;
    if (_note.text.length > 4000) {
      setState(() => _message = '说明最多 4000 字。');
      return;
    }
    setState(() {
      _saving = true;
      _message = null;
    });
    var saved = false;
    try {
      saved = await widget.onSave(_kind, _note.text);
    } finally {
      if (mounted && widget.isCurrent()) setState(() => _saving = false);
    }
    if (!mounted || !widget.isCurrent()) return;
    if (saved) Navigator.of(context).pop();
  }
}

final class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.detail,
    this.busy = false,
  });
  final IconData icon;
  final String title;
  final String detail;
  final bool busy;

  @override
  Widget build(BuildContext context) => Card(
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              const SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              )
            else
              Icon(icon, size: 38, color: _green),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _muted, height: 1.45),
            ),
          ],
        ),
      ),
    ),
  );
}

final class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.text, required this.icon});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 16, color: _muted),
      const SizedBox(width: 7),
      Expanded(
        child: Text(
          text,
          style: const TextStyle(color: _muted, fontSize: 12, height: 1.4),
        ),
      ),
    ],
  );
}

final class _DetailLine extends StatelessWidget {
  const _DetailLine({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 18, color: _muted),
      const SizedBox(width: 9),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: _muted, fontSize: 12)),
            const SizedBox(height: 3),
            Text(value, softWrap: true, style: const TextStyle(height: 1.45)),
          ],
        ),
      ),
    ],
  );
}

final class _AcademicFactLine extends StatelessWidget {
  const _AcademicFactLine({
    super.key,
    required this.label,
    required this.value,
    this.tooltipValue,
    this.maxLines = 2,
  });

  final String label;
  final String value;
  final String? tooltipValue;
  final int maxLines;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: '$label：${tooltipValue ?? value}',
    child: Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        '$label：$value',
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        softWrap: true,
        style: const TextStyle(color: _muted, fontSize: 12, height: 1.4),
      ),
    ),
  );
}

final class _SmallTag extends StatelessWidget {
  const _SmallTag({
    required this.text,
    required this.color,
    this.textColor = _muted,
    this.icon,
  });
  final String text;
  final Color color;
  final Color textColor;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(8),
    ),
    child: icon == null
        ? Text(
            text,
            style: TextStyle(color: textColor, fontSize: 11, height: 1.2),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: textColor, size: 13),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  text,
                  style: TextStyle(color: textColor, fontSize: 11, height: 1.2),
                ),
              ),
            ],
          ),
  );
}

const _green = Color(0xFF1F6B45);
const _muted = Color(0xFF66736C);

enum _CalendarToolbarAction {
  allSources,
  courses,
  exams,
  young,
  personal,
  planBlocks,
  toggleInactive,
}

PersonalEventDraft _blankDraft(DateTime date) {
  final day = _dateOnly(date);
  final start = DateTime.utc(
    day.year,
    day.month,
    day.day,
    10,
  ).subtract(const Duration(hours: 8));
  final end = start.add(const Duration(hours: 1));
  return PersonalEventDraft(title: '', start: start, end: end);
}

PersonalEventDraft _draftForOccurrence(CalendarOccurrence occurrence) {
  if (occurrence.allDay) {
    final startLocal = occurrence.startsAtUtc.toUtc().add(
      const Duration(hours: 8),
    );
    final endLocal = occurrence.endsAtUtc.toUtc().add(const Duration(hours: 8));
    return PersonalEventDraft(
      title: occurrence.title,
      start: DateTime.utc(startLocal.year, startLocal.month, startLocal.day),
      end: DateTime.utc(endLocal.year, endLocal.month, endLocal.day),
      allDay: true,
      weekly: false,
      location: occurrence.location,
      note: occurrence.note,
    );
  }
  return PersonalEventDraft(
    title: occurrence.title,
    start: occurrence.startsAtUtc.toUtc(),
    end: occurrence.endsAtUtc.toUtc(),
    allDay: false,
    weekly: false,
    location: occurrence.location,
    note: occurrence.note,
  );
}

DateTime _dateOnly(DateTime day) => DateTime.utc(day.year, day.month, day.day);

String _dateLabel(DateTime day) =>
    '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

String _beijingDateTimeLabel(DateTime utc) {
  final value = utc.toUtc().add(const Duration(hours: 8));
  return '${_dateLabel(value)} ${_clockLabel(value)}';
}

String _filterLabel(CalendarFilter filter) => switch (filter) {
  CalendarFilter.all => '全部类别',
  CalendarFilter.course => '课程',
  CalendarFilter.exam => '考试',
  CalendarFilter.young => '二课',
  CalendarFilter.personal => '个人安排',
  CalendarFilter.planBlock => '任务时间块',
};

String _filterTooltip(CalendarWorkspaceView view) =>
    '类别：${_filterLabel(view.filter)}'
    '${view.includeInactive ? ' · 包含隐藏/跳过' : ''}';

String _rangeLabel(DateTime first) {
  final end = DateTime.utc(first.year, first.month, first.day + 6);
  return '${_shortDate(first)} – ${_shortDate(end)}';
}

String _shortDate(DateTime day) =>
    '${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

String _occurrenceTime(CalendarOccurrence occurrence) {
  final start = occurrence.startsAtUtc.toUtc().add(const Duration(hours: 8));
  final end = occurrence.endsAtUtc.toUtc().add(const Duration(hours: 8));
  if (occurrence.allDay) {
    final lastDay = end.subtract(const Duration(days: 1));
    final startText = _dateLabel(start);
    final endText = _dateLabel(lastDay);
    return startText == endText
        ? '$startText · 全天'
        : '$startText 至 $endText · 全天';
  }
  final startText = '${_dateLabel(start)} ${_clockLabel(start)}';
  final endText = '${_dateLabel(end)} ${_clockLabel(end)}';
  return '$startText – $endText';
}

String _presenceSuffix(CalendarOccurrence occurrence) =>
    switch (occurrence.presence) {
      AgendaPresence.observed => '',
      AgendaPresence.missingWithinScope => ' · 来源暂缺，仍保留',
      AgendaPresence.outsideScope => ' · 当前在来源观察范围外',
    };

String _clockLabel(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

String _kindLabel(CalendarKind kind) => switch (kind) {
  CalendarKind.course => '课程',
  CalendarKind.exam => '考试',
  CalendarKind.young => '二课',
  CalendarKind.personal => '个人安排',
  CalendarKind.planBlock => '任务时间块',
};

String _taskStatusLabel(TaskStatus status) => switch (status) {
  TaskStatus.active => '进行中',
  TaskStatus.blocked => '受阻',
  TaskStatus.completed => '已完成',
  TaskStatus.cancelled => '已取消',
};

String _planBlockStatusLabel(PlanBlockStatus status) => switch (status) {
  PlanBlockStatus.planned => '待执行',
  PlanBlockStatus.done => '已执行',
  PlanBlockStatus.skipped => '已跳过',
};

String _undoReason(CalendarUndoView undo) {
  if (undo.failure == null ||
      undo.failure == CalendarFailureCode.undoUnavailable) {
    return '当前没有可撤销的最近一次本地修改。';
  }
  if (undo.failure == CalendarFailureCode.undoConflict ||
      undo.failure == CalendarFailureCode.staleReference) {
    return '最近一次修改已无法安全撤销。';
  }
  return '当前无法撤销最近一次本地修改。';
}

String _taskFailureMessageForPage(CalendarFailureCode code) => switch (code) {
  CalendarFailureCode.invalidInput => '输入内容不符合任务或时间块要求，请检查后重试。',
  CalendarFailureCode.busy => '已有本地或来源操作正在进行，请稍后重试。',
  CalendarFailureCode.staleReference => '任务或时间块已更新，请重新读取后再操作。',
  CalendarFailureCode.idempotencyConflict => '这次操作已失效，请重新发起。',
  CalendarFailureCode.maintenance => '本地维护正在进行，当前暂不能修改任务。',
  CalendarFailureCode.limitExceeded => '已达到当前数据上限，暂时不能继续添加。',
  CalendarFailureCode.ownershipLost => '本地数据所有权已变化，请重新读取任务。',
  CalendarFailureCode.storageFailed => '本地保存失败，已有数据未确认改变。',
  CalendarFailureCode.closed => '任务服务已关闭，请重新打开页面。',
  CalendarFailureCode.undoUnavailable => '当前没有可撤销的最近一次本地修改。',
  CalendarFailureCode.undoConflict => '最近一次修改已无法安全撤销。',
};

typedef _AcademicFact = ({
  String key,
  String label,
  String value,
  String? tooltipValue,
});

bool _isJwAcademic(CalendarOccurrence occurrence) {
  final kind = occurrence.reference.identity.kind;
  return kind == CalendarKind.course || kind == CalendarKind.exam;
}

String _displayLocation(CalendarOccurrence occurrence) {
  final location = occurrence.location.trim();
  if (location.isNotEmpty) return location;
  return occurrence.academicDetails?.locationLabel.trim() ?? '';
}

String _locationSummary(CalendarOccurrence occurrence) {
  final location = _displayLocation(occurrence);
  if (location.isNotEmpty) return location;
  if (_isJwAcademic(occurrence)) {
    return occurrence.academicDetails == null ? '尚未采集地点' : '本次来源未提供';
  }
  return '地点未提供';
}

Key _dayAcademicKey(CalendarOccurrence occurrence, String field) => ValueKey(
  'calendar-day-academic-${occurrence.reference.identity.kind.name}-'
  '${occurrence.reference.identity.localId}-${occurrence.reference.identity.ordinal}-$field',
);

List<_AcademicFact> _academicFacts(CalendarOccurrence occurrence) {
  final details = occurrence.academicDetails;
  if (details == null || !_isJwAcademic(occurrence)) return const [];
  final kind = occurrence.reference.identity.kind;
  final facts = <_AcademicFact>[];
  void add(String key, String label, String value) {
    if (value.isNotEmpty) {
      facts.add((key: key, label: label, value: value, tooltipValue: null));
    }
  }

  final location = _displayLocation(occurrence);
  add('location', '地点', location.isEmpty ? '本次来源未提供' : location);
  add('campus', '校区', details.campus);
  add('building', '楼宇', details.building);
  add('room', '教室', details.room);
  add('room-code', '教室代码', details.roomCode);
  add('custom-place', '补充地点', details.customPlace);
  if (details.virtual != null) {
    add('virtual', '虚拟教室', details.virtual! ? '是' : '否');
  }

  final teachers = details.teachers.join('、');
  if (kind == CalendarKind.course || details.teachers.isNotEmpty) {
    facts.add((
      key: 'teachers',
      label: '教师',
      value: teachers.isEmpty ? '本次来源未提供' : teachers,
      tooltipValue: teachers.isEmpty ? null : teachers,
    ));
  }

  if (kind == CalendarKind.course) {
    add('semester', '学期', details.semesterName);
  }
  add('course-code', '课程号', details.courseCode);
  add('course-type', '课程类别', details.courseType);
  if (details.weekIndex != null) {
    add('week-index', '周次序号', details.weekIndex!.toString());
  }
  if (details.weekday != null) {
    add('weekday', '星期序号', details.weekday!.toString());
  }
  if (details.periods != null) {
    add('periods', '节数', details.periods!.toString());
  }
  if (details.exerciseClass != null) {
    add('exercise-class', '习题课', details.exerciseClass! ? '是' : '否');
  }
  if (kind == CalendarKind.exam) {
    add(
      'exam-type',
      '考试类型',
      details.examType.isEmpty ? '本次来源未提供' : details.examType,
    );
    add('exam-note', '考试说明', details.examNote);
  }
  return facts;
}

String _overflowAcademicSummary(CalendarOccurrence occurrence) {
  if (!_isJwAcademic(occurrence)) {
    final location = occurrence.location.trim();
    return location.isEmpty ? '' : ' · 地点：$location';
  }
  final details = occurrence.academicDetails;
  if (details == null) {
    final location = occurrence.location.trim();
    return ' · 尚未采集教务信息，重新同步补充'
        '${location.isEmpty ? '' : ' · 地点：$location'}';
  }
  final location = _displayLocation(occurrence);
  final teachers = details.teachers.join('、');
  return ' · 地点：${location.isEmpty ? '本次来源未提供' : location}'
      '${occurrence.reference.identity.kind == CalendarKind.course || teachers.isNotEmpty ? ' · 教师：${teachers.isEmpty ? '本次来源未提供' : teachers}' : ''}';
}

String _overflowAcademicTooltip(CalendarOccurrence occurrence) {
  final lines = <String>[
    occurrence.title,
    '${_kindLabel(occurrence.reference.identity.kind)} · ${_occurrenceTime(occurrence)}',
  ];
  if (_isJwAcademic(occurrence)) {
    if (occurrence.academicDetails == null) {
      if (occurrence.location.trim().isNotEmpty) {
        lines.add('地点：${occurrence.location.trim()}');
      }
      lines.add('尚未采集教务信息，重新同步补充');
    } else {
      lines.addAll(
        _academicFacts(
          occurrence,
        ).map((fact) => '${fact.label}：${fact.tooltipValue ?? fact.value}'),
      );
    }
  } else if (occurrence.location.trim().isNotEmpty) {
    lines.add('地点：${occurrence.location.trim()}');
  }
  return lines.join('\n');
}

String _attendanceLabel(AttendanceDecision decision) => switch (decision) {
  AttendanceDecision.undecided => '未决定',
  AttendanceDecision.attend => '计划参加',
  AttendanceDecision.skip => '不参加',
};

String _listeningLabel(ListeningMode mode) => switch (mode) {
  ListeningMode.undecided => '未设置',
  ListeningMode.listening => '听讲',
  ListeningMode.selfStudy => '自主学习',
};

String _relationKindLabel(CalendarRelationKind kind) => switch (kind) {
  CalendarRelationKind.conflict => '冲突',
  CalendarRelationKind.notConflict => '不冲突',
  CalendarRelationKind.legacyUndecided => '旧说明（未保存明确判断）',
};

String _conflictSummaryLabel(CalendarConflict conflict) {
  if (conflict.status == CalendarConflictStatus.notConflict) {
    return '已判定不冲突';
  }
  if (conflict.hasExplicitDecision) return '已确认冲突';
  if (conflict.relation?.kind == CalendarRelationKind.legacyUndecided) {
    return '默认冲突 · 旧说明已保留';
  }
  return '默认冲突 · 尚未确认';
}

Color _conflictStatusColor(CalendarConflictStatus status) =>
    status == CalendarConflictStatus.conflict
    ? const Color(0xFF9B2C2C)
    : const Color(0xFF2F6848);

List<Widget> _stateTags(CalendarOccurrence occurrence) => [
  if (occurrence.planBlockStatus != null)
    _SmallTag(
      text: '时间块·${_planBlockStatusLabel(occurrence.planBlockStatus!)}',
      color: occurrence.planBlockStatus == PlanBlockStatus.done
          ? const Color(0xFFE4F1E8)
          : occurrence.planBlockStatus == PlanBlockStatus.skipped
          ? const Color(0xFFFFF0DA)
          : const Color(0xFFF0F3F1),
    ),
  if (occurrence.taskStatus != null)
    _SmallTag(
      text: '任务·${_taskStatusLabel(occurrence.taskStatus!)}',
      color: occurrence.taskStatus == TaskStatus.completed
          ? const Color(0xFFE4F1E8)
          : occurrence.taskStatus == TaskStatus.blocked
          ? const Color(0xFFFFF0DA)
          : const Color(0xFFF0F3F1),
    ),
  if (occurrence.presence == AgendaPresence.missingWithinScope)
    const _SmallTag(text: '来源暂缺，仍保留', color: Color(0xFFFFF0DA)),
  if (occurrence.presence == AgendaPresence.outsideScope)
    const _SmallTag(text: '当前不在观察范围', color: Color(0xFFF0F3F1)),
  if (occurrence.hidden) const _SmallTag(text: '已隐藏', color: Color(0xFFF0F3F1)),
  if (occurrence.skipped)
    const _SmallTag(text: '已跳过', color: Color(0xFFFFF0DA)),
  if (occurrence.completed)
    const _SmallTag(text: '已完成', color: Color(0xFFE4F1E8)),
];

List<Widget> _occurrenceTags(
  CalendarOccurrence occurrence,
  List<CalendarConflict> conflicts,
) {
  final matching = conflicts.where(
    (conflict) =>
        conflict.left.reference.identity == occurrence.reference.identity ||
        conflict.right.reference.identity == occurrence.reference.identity,
  );
  final hasConflict = matching.any(
    (conflict) => conflict.status == CalendarConflictStatus.conflict,
  );
  final hasExplicitConflict = matching.any(
    (conflict) =>
        conflict.status == CalendarConflictStatus.conflict &&
        conflict.hasExplicitDecision,
  );
  final hasNotConflict = matching.any(
    (conflict) => conflict.status == CalendarConflictStatus.notConflict,
  );
  final hasDefaultConflict = matching.any(
    (conflict) =>
        conflict.status == CalendarConflictStatus.conflict &&
        !conflict.hasExplicitDecision,
  );
  final hasLegacy = matching.any(
    (conflict) =>
        conflict.relation?.kind == CalendarRelationKind.legacyUndecided,
  );
  return [
    if (hasConflict)
      Tooltip(
        message: hasExplicitConflict && hasDefaultConflict
            ? '含已确认冲突和默认冲突候选'
            : hasExplicitConflict
            ? '已确认冲突'
            : hasLegacy
            ? '默认按冲突展示；旧说明已保留'
            : '默认按冲突展示，尚未确认',
        child: _SmallTag(
          text: hasExplicitConflict && hasDefaultConflict
              ? '冲突（含默认）'
              : hasExplicitConflict
              ? '已确认冲突'
              : '默认冲突',
          color: const Color(0xFFFBEAEA),
          textColor: const Color(0xFF9B2C2C),
          icon: Icons.error_outline_rounded,
        ),
      ),
    if (hasNotConflict)
      const _SmallTag(
        text: '不冲突',
        color: Color(0xFFE6F1E9),
        textColor: Color(0xFF2F6848),
      ),
    ..._stateTags(occurrence),
  ];
}

List<CalendarConflict> _conflictsFor(
  CalendarWindow? window,
  CalendarOccurrence occurrence,
) {
  if (window == null) return const [];
  return window.conflicts
      .where(
        (conflict) =>
            !conflict.left.allDay &&
            !conflict.right.allDay &&
            (conflict.left.reference.identity ==
                    occurrence.reference.identity ||
                conflict.right.reference.identity ==
                    occurrence.reference.identity),
      )
      .toList(growable: false);
}

List<CalendarConflict> _windowConflicts(CalendarWindow window) => window
    .conflicts
    .where((conflict) => !conflict.left.allDay && !conflict.right.allDay)
    .toList(growable: false);

String _failureMessage(CalendarFailureCode code) => switch (code) {
  CalendarFailureCode.invalidInput => '输入内容不符合日程要求，请检查日期和字段长度。',
  CalendarFailureCode.busy => '日程正在处理其他操作，请稍后重试。',
  CalendarFailureCode.staleReference => '这条日程已更新，请重新选择后再操作。',
  CalendarFailureCode.idempotencyConflict => '操作状态已变化，请重新选择并重试。',
  CalendarFailureCode.maintenance => '本地日程维护中，暂时不能读取或修改。',
  CalendarFailureCode.limitExceeded => '当前日期范围超过查询上限，请缩小范围。',
  CalendarFailureCode.ownershipLost => '应用数据目录状态已变化，请重新打开日程。',
  CalendarFailureCode.storageFailed => '本地日程暂时无法完成此操作，请稍后重试。',
  CalendarFailureCode.closed => '日程服务已关闭，请重新打开页面。',
  CalendarFailureCode.undoUnavailable => '当前没有可撤销的最近一次本地修改。',
  CalendarFailureCode.undoConflict => '最近一次修改已无法安全撤销。',
};

Widget _sectionHeading(String title) => Text(
  title,
  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
);
