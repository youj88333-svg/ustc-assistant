import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/agent_discussion_contract.dart';
import '../core/calendar_contract.dart';
import '../core/reminder_contract.dart';
import 'calendar_display_style.dart';
import 'reminder_editor.dart';
import 'task_workspace_contract.dart';
import 'task_workspace_editor.dart';

const _green = Color(0xFF2F6848);
const _muted = Color(0xFF66736C);
const _line = Color(0xFFE3E9E5);

/// Task and PlanBlock UI. The port owns reads, writes, busy state and refresh.
final class TaskWorkspacePage extends StatefulWidget {
  const TaskWorkspacePage({
    super.key,
    required this.port,
    this.onDiscuss,
    this.reminders,
  });

  final TaskWorkspacePort port;
  final ValueChanged<AgentDiscussionSelection>? onDiscuss;
  final ReminderDataPort? reminders;

  @override
  State<TaskWorkspacePage> createState() => _TaskWorkspacePageState();
}

final class _TaskWorkspacePageState extends State<TaskWorkspacePage> {
  late TaskQuery _query;
  late final TextEditingController _search;
  Timer? _searchDebounce;
  TaskReference? _selected;
  String? _notice;
  bool _actionBusy = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _query = widget.port.taskView.query;
    _search = TextEditingController(text: _query.keyword);
    _selected = widget.port.taskView.detail?.task.reference;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load(widget.port, _query));
    });
  }

  @override
  void didUpdateWidget(covariant TaskWorkspacePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.port, widget.port)) {
      _generation++;
      _searchDebounce?.cancel();
      _selected = null;
      _notice = null;
      _query = widget.port.taskView.query;
      _search.text = _query.keyword;
      _actionBusy = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_load(widget.port, _query));
      });
    }
  }

  @override
  void dispose() {
    _generation++;
    _searchDebounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.port,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) => _workspace(
        context,
        widget.port.taskView,
        constraints.maxWidth,
        nowUtc: _nowUtc,
      ),
    ),
  );

  DateTime get _nowUtc {
    final port = widget.port;
    if (port is CalendarTaskWorkspacePort) {
      return (port as CalendarTaskWorkspacePort).nowUtc.toUtc();
    }
    // Standalone task ports have no clock contract; the app's shared calendar
    // and task controller supplies its AppClock through the port above.
    return DateTime.now().toUtc();
  }

  Widget _workspace(
    BuildContext context,
    TaskWorkspaceView view,
    double width, {
    required DateTime nowUtc,
  }) {
    final wide = width >= 820;
    final detail = _detailFor(view);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbarArea(view, width),
        if (!view.undo.canUndo) ...[
          const SizedBox(height: 5),
          _TaskStatusLine(
            icon: Icons.info_outline_rounded,
            text: _taskUndoUnavailableMessage(view.undo),
          ),
        ],
        if (_notice != null) ...[
          const SizedBox(height: 7),
          _messageCard(_notice!, icon: Icons.info_outline_rounded),
        ],
        if (view.failure != null) ...[
          const SizedBox(height: 7),
          _messageCard(
            _taskFailureMessage(view.failure!),
            icon: Icons.sync_problem_rounded,
          ),
        ],
        if (view.sourceBusy) ...[
          const SizedBox(height: 7),
          const _TaskStatusLine(
            icon: Icons.sync_rounded,
            text: '来源操作进行中，仍可查看任务；新写入暂不可用。',
          ),
        ],
        if (view.actionPending || _actionBusy) ...[
          const SizedBox(height: 7),
          const _TaskStatusLine(
            icon: Icons.hourglass_top_rounded,
            text: '本地任务操作正在保存。',
          ),
        ],
        if (view.loading) ...[
          const SizedBox(height: 6),
          const LinearProgressIndicator(minHeight: 2),
        ],
        const SizedBox(height: 8),
        if (wide)
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: math
                      .min(390.0, math.max(300.0, width * .37))
                      .toDouble(),
                  child: _taskList(view, nowUtc),
                ),
                const SizedBox(width: 10),
                Expanded(child: _detailPanel(view, detail, nowUtc: nowUtc)),
              ],
            ),
          )
        else
          Expanded(
            child: _selected == null
                ? _taskList(view, nowUtc)
                : _detailPanel(view, detail, nowUtc: nowUtc, compact: true),
          ),
      ],
    );
  }

  Widget _toolbarArea(TaskWorkspaceView view, double width) {
    final toolbar = _toolbar(view, width);
    if (width >= 620) return toolbar;
    final screenHeight = MediaQuery.sizeOf(context).height;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: math
            .min(width < 390 ? 210.0 : 170.0, screenHeight * .36)
            .toDouble(),
      ),
      child: SingleChildScrollView(
        key: const ValueKey('task-workspace-toolbar-scroll'),
        child: toolbar,
      ),
    );
  }

  Widget _toolbar(TaskWorkspaceView view, double width) {
    final maxSearchWidth = width < 290 ? width : 270.0;
    final queryLoaded = view.window != null;
    final canAdd = _canWrite(view) && queryLoaded;
    return Wrap(
      spacing: 7,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: maxSearchWidth,
          child: TextField(
            key: const ValueKey('task-workspace-search'),
            controller: _search,
            textInputAction: TextInputAction.search,
            onChanged: _onSearchChanged,
            decoration: InputDecoration(
              isDense: true,
              hintText: '按标题搜索',
              prefixIcon: const Icon(Icons.search_rounded, size: 19),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除搜索',
                      onPressed: () {
                        _search.clear();
                        _onSearchChanged('');
                      },
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(9),
                borderSide: const BorderSide(color: _line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(9),
                borderSide: const BorderSide(color: _line),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
            ),
          ),
        ),
        PopupMenuButton<TaskFilter>(
          key: const ValueKey('task-workspace-filter'),
          tooltip: '筛选任务：${_taskFilterLabel(_query.filter)}',
          onSelected: (filter) {
            setState(
              () => _query = TaskQuery(
                filter: filter,
                keyword: _query.keyword,
                limit: _query.limit,
              ),
            );
            unawaited(_load(widget.port, _query));
          },
          itemBuilder: (context) => [
            for (final filter in TaskFilter.values)
              PopupMenuItem<TaskFilter>(
                value: filter,
                child: Row(
                  children: [
                    Icon(
                      _query.filter == filter
                          ? Icons.check_rounded
                          : Icons.circle_outlined,
                      size: 17,
                      color: _query.filter == filter ? _green : _muted,
                    ),
                    const SizedBox(width: 8),
                    Text(_taskFilterLabel(filter)),
                  ],
                ),
              ),
          ],
          child: _ToolbarButton(
            icon: Icons.filter_list_rounded,
            label: width < 390 ? '筛选' : _taskFilterLabel(_query.filter),
          ),
        ),
        OutlinedButton.icon(
          key: const ValueKey('task-workspace-undo'),
          onPressed: view.undo.canUndo && _canWrite(view)
              ? () => _undo(widget.port, view.undo)
              : null,
          icon: const Icon(Icons.undo_rounded, size: 18),
          label: const Text('撤销最近修改'),
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            foregroundColor: _green,
          ),
        ),
        FilledButton.icon(
          key: const ValueKey('task-workspace-create'),
          onPressed: canAdd ? () => _createTask(widget.port, view) : null,
          icon: const Icon(Icons.add_rounded, size: 19),
          label: Text(width < 390 ? '新建' : '新建任务'),
        ),
      ],
    );
  }

  Widget _taskList(TaskWorkspaceView view, DateTime nowUtc) {
    final window = view.window;
    if (window == null) {
      return _EmptyTaskPanel(
        icon: view.loading
            ? Icons.hourglass_empty_rounded
            : Icons.sync_problem_outlined,
        title: view.loading ? '正在读取任务' : '任务尚未读取',
        detail: view.loading
            ? '正在从本地任务服务读取。'
            : view.failure == null
            ? '当前状态还不能判断为空。'
            : _taskFailureMessage(view.failure!),
        busy: view.loading,
      );
    }
    return Card(
      key: const ValueKey('task-workspace-list-card'),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(13, 10, 13, 8),
            child: Row(
              children: [
                const Icon(Icons.checklist_rounded, size: 18, color: _green),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    '任务 · ${window.matched}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (window.truncated)
                  const Tooltip(
                    message: '当前结果已截断，仍有任务未显示。',
                    child: Icon(
                      Icons.warning_amber_rounded,
                      size: 19,
                      color: Color(0xFF9B2C2C),
                    ),
                  ),
              ],
            ),
          ),
          if (window.truncated)
            Container(
              color: const Color(0xFFFFF7E8),
              padding: const EdgeInsets.fromLTRB(13, 7, 10, 7),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '结果已截断，列表没有展示全部匹配任务。',
                      style: TextStyle(fontSize: 12, color: Color(0xFF805900)),
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('task-workspace-load-more'),
                    onPressed: _query.limit >= 500 || view.loading
                        ? null
                        : () {
                            setState(
                              () => _query = TaskQuery(
                                filter: _query.filter,
                                keyword: _query.keyword,
                                limit: math
                                    .min(500, _query.limit + 100)
                                    .toInt(),
                              ),
                            );
                            unawaited(_load(widget.port, _query));
                          },
                    child: const Text('展示更多'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: window.items.isEmpty
                ? _EmptyTaskPanel(
                    icon: Icons.task_alt_rounded,
                    title: _query.keyword.isEmpty ? '当前没有匹配任务' : '没有找到匹配标题',
                    detail: _query.keyword.isEmpty
                        ? '可新建任务，或调整状态筛选。'
                        : '试试缩短关键词或调整状态筛选。',
                  )
                : ListView.separated(
                    key: const ValueKey('task-workspace-list'),
                    padding: const EdgeInsets.fromLTRB(7, 4, 7, 8),
                    itemCount: window.items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 4),
                    itemBuilder: (context, index) => _taskTile(
                      window.items[index],
                      selected:
                          _selected?.localId ==
                          window.items[index].reference.localId,
                      nowUtc: nowUtc,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _taskTile(
    TaskRecord task, {
    required bool selected,
    required DateTime nowUtc,
  }) {
    final deadline = task.draft.deadlineAtUtc;
    final overdue =
        deadline != null &&
        !deadline.toUtc().isAfter(nowUtc.toUtc()) &&
        task.status != TaskStatus.completed &&
        task.status != TaskStatus.cancelled;
    final subtitle = <String>[
      _taskStatusLabel(task.status),
      _priorityLabel(task.draft.priority),
      if (deadline != null)
        '${overdue ? '已过截止 · ' : '截止 '}${_beijingDateTimeLabel(deadline)}',
      if (deadline == null) '无截止',
      '${task.blockCount} 个时间块',
    ].join(' · ');
    return Material(
      color: selected ? const Color(0xFFE8F1EB) : Colors.white,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        key: ValueKey('task-tile-${task.reference.localId}'),
        borderRadius: BorderRadius.circular(9),
        onTap: () => _selectTask(widget.port, task.reference),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: selected ? const Color(0xFF9DB9A6) : _line,
            ),
            borderRadius: BorderRadius.circular(9),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Tooltip(
                message: task.draft.title,
                child: Text(
                  task.draft.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: calendarColorsForTitle(task.draft.title).ink,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: overdue ? const Color(0xFF9B2C2C) : _muted,
                  fontSize: 11,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  TaskDetail? _detailFor(TaskWorkspaceView view) {
    final selected = _selected;
    final detail = view.detail;
    if (selected == null || detail == null) return null;
    return detail.task.reference.context == selected.context &&
            detail.task.reference.localId == selected.localId
        ? detail
        : null;
  }

  Widget _detailPanel(
    TaskWorkspaceView view,
    TaskDetail? detail, {
    required DateTime nowUtc,
    bool compact = false,
  }) {
    if (_selected == null) {
      return const _EmptyTaskPanel(
        icon: Icons.touch_app_outlined,
        title: '选择一项任务',
        detail: '任务详情和时间规划会显示在这里。',
      );
    }
    if (view.detailLoading && detail == null) {
      return const _EmptyTaskPanel(
        icon: Icons.hourglass_empty_rounded,
        title: '正在读取任务详情',
        detail: '正在读取任务及其关联的时间块。',
        busy: true,
      );
    }
    if (detail == null) {
      return _EmptyTaskPanel(
        icon: Icons.sync_problem_outlined,
        title: '任务引用已失效',
        detail: view.failure == null
            ? '请从列表重新选择这项任务。'
            : _taskFailureMessage(view.failure!),
        leading: compact ? _backToListButton() : null,
      );
    }
    final blocks = [...detail.blocks]
      ..sort(
        (left, right) =>
            left.draft.startsAtUtc.compareTo(right.draft.startsAtUtc),
      );
    return Card(
      key: const ValueKey('task-workspace-detail-card'),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          if (compact)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(9, 6, 9, 0),
                child: _backToListButton(),
              ),
            ),
          Expanded(
            child: ListView(
              key: const ValueKey('task-workspace-detail-content'),
              padding: const EdgeInsets.fromLTRB(15, 12, 15, 16),
              children: [
                _taskDetailHeader(view, detail),
                if (widget.onDiscuss != null) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      key: const ValueKey('task-detail-discuss'),
                      onPressed: () => widget.onDiscuss!(
                        AgentDiscussionSelection.task(detail.task.reference),
                      ),
                      icon: const Icon(
                        Icons.chat_bubble_outline_rounded,
                        size: 18,
                      ),
                      label: const Text('交给 Agent 讨论'),
                    ),
                  ),
                ],
                const SizedBox(height: 11),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _TaskTag(
                      label: _taskStatusLabel(detail.task.status),
                      fill: _taskStatusFill(detail.task.status),
                    ),
                    _TaskTag(
                      label: _priorityLabel(detail.task.draft.priority),
                      fill: const Color(0xFFF0F3F1),
                    ),
                    if (detail.task.draft.deadlineAtUtc == null)
                      const _TaskTag(label: '无截止', fill: Color(0xFFF0F3F1))
                    else
                      _TaskTag(
                        label:
                            '截止 ${_beijingDateTimeLabel(detail.task.draft.deadlineAtUtc!)}',
                        fill: _isOverdue(detail.task, nowUtc)
                            ? const Color(0xFFFFF0DA)
                            : const Color(0xFFF0F3F1),
                        textColor: _isOverdue(detail.task, nowUtc)
                            ? const Color(0xFF805900)
                            : _muted,
                      ),
                    if (detail.task.draft.estimatedMinutes != null)
                      _TaskTag(
                        label: '预计 ${detail.task.draft.estimatedMinutes} 分钟',
                        fill: const Color(0xFFF0F3F1),
                      ),
                  ],
                ),
                if (widget.reminders != null) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      key: const ValueKey('task-deadline-reminder'),
                      onPressed: () => unawaited(
                        _editReminder(
                          ReminderTarget.task(detail.task.reference),
                          allDay: false,
                        ),
                      ),
                      icon: const Icon(
                        Icons.notifications_active_outlined,
                        size: 18,
                      ),
                      label: const Text('设置截止提醒'),
                    ),
                  ),
                  if (detail.task.draft.deadlineAtUtc == null)
                    const Padding(
                      padding: EdgeInsets.only(top: 5),
                      child: Text(
                        '当前没有截止时间；规则会暂存，添加截止时间前不会生成提醒。',
                        style: TextStyle(color: _muted, fontSize: 12),
                      ),
                    ),
                ],
                if (detail.task.draft.description.trim().isNotEmpty) ...[
                  const SizedBox(height: 15),
                  _detailText('描述', detail.task.draft.description),
                ],
                if (detail.task.draft.note.trim().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _detailText('备注', detail.task.draft.note),
                ],
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '时间规划 · ${blocks.length}',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('task-block-create'),
                      onPressed: _canWrite(view)
                          ? () => _createBlock(widget.port, detail)
                          : null,
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('新增时间块'),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                if (blocks.isEmpty)
                  const _InlineNote(text: '还没有时间块。手动安排后，时间到只会提示复核，不会自动完成任务。')
                else
                  for (final block in blocks) ...[
                    _blockCard(view, detail, block, nowUtc),
                    const SizedBox(height: 8),
                  ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _taskDetailHeader(TaskWorkspaceView view, TaskDetail detail) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Text(
          detail.task.draft.title,
          key: const ValueKey('task-detail-title'),
          softWrap: true,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: calendarColorsForTitle(detail.task.draft.title).ink,
            fontWeight: FontWeight.w700,
            height: 1.3,
          ),
        ),
      ),
      const SizedBox(width: 8),
      PopupMenuButton<_TaskAction>(
        key: const ValueKey('task-detail-actions'),
        tooltip: '任务操作',
        enabled: _canWrite(view),
        onSelected: (action) {
          switch (action) {
            case _TaskAction.edit:
              unawaited(_editTask(widget.port, detail));
              break;
            case _TaskAction.status:
              break;
            case _TaskAction.delete:
              unawaited(_confirmDeleteTask(widget.port, detail));
              break;
          }
        },
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: _TaskAction.edit,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.edit_outlined),
              title: Text('编辑全部字段'),
            ),
          ),
          for (final status in TaskStatus.values)
            if (status != detail.task.status)
              PopupMenuItem(
                value: _TaskAction.status,
                onTap: () => WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) {
                    unawaited(_setTaskStatus(widget.port, detail, status));
                  }
                }),
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(_taskStatusIcon(status)),
                  title: Text('设为${_taskStatusLabel(status)}'),
                ),
              ),
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: _TaskAction.delete,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.delete_outline_rounded),
              title: Text('删除任务…'),
            ),
          ),
        ],
        icon: const Icon(Icons.more_horiz_rounded),
      ),
    ],
  );

  Widget _blockCard(
    TaskWorkspaceView view,
    TaskDetail detail,
    PlanBlockRecord block,
    DateTime nowUtc,
  ) {
    final awaiting = block.awaitingReview(nowUtc);
    final deadline = detail.task.draft.deadlineAtUtc;
    final afterDeadline =
        deadline != null && block.draft.startsAtUtc.isAfter(deadline);
    final crossesDeadline =
        deadline != null &&
        !block.draft.startsAtUtc.isAfter(deadline) &&
        block.draft.endsAtUtc.isAfter(deadline);
    return Container(
      key: ValueKey('task-block-${block.reference.identity.localId}'),
      padding: const EdgeInsets.fromLTRB(11, 10, 7, 9),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFBFA),
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  _blockTimeLabel(block.draft),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              PopupMenuButton<_BlockAction>(
                key: ValueKey(
                  'task-block-actions-${block.reference.identity.localId}',
                ),
                tooltip: '时间块操作',
                enabled: _canWrite(view),
                onSelected: (action) {
                  switch (action) {
                    case _BlockAction.edit:
                      unawaited(_editBlock(widget.port, detail, block));
                      break;
                    case _BlockAction.delete:
                      unawaited(_confirmDeleteBlock(widget.port, block));
                      break;
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: _BlockAction.edit,
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.edit_calendar_outlined),
                      title: Text('移动或编辑'),
                    ),
                  ),
                  const PopupMenuDivider(),
                  for (final status in PlanBlockStatus.values)
                    if (status != block.status)
                      PopupMenuItem(
                        onTap: () =>
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) {
                                unawaited(
                                  _setBlockStatus(widget.port, block, status),
                                );
                              }
                            }),
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(_blockStatusIcon(status)),
                          title: Text('设为${_blockStatusLabel(status)}'),
                        ),
                      ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: _BlockAction.delete,
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.delete_outline_rounded),
                      title: Text('删除时间块…'),
                    ),
                  ),
                ],
                icon: const Icon(Icons.more_vert_rounded, size: 20),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 42),
              ),
            ],
          ),
          Wrap(
            spacing: 5,
            runSpacing: 5,
            children: [
              _TaskTag(
                label: _blockStatusLabel(block.status),
                fill: _blockStatusFill(block.status),
              ),
              if (awaiting)
                const _TaskTag(
                  label: '已到时间 · 待复核',
                  fill: Color(0xFFFFF0DA),
                  textColor: Color(0xFF805900),
                  icon: Icons.error_outline_rounded,
                ),
              if (afterDeadline)
                const _TaskTag(
                  label: '计划在任务截止后',
                  fill: Color(0xFFFFF0DA),
                  textColor: Color(0xFF805900),
                ),
              if (crossesDeadline)
                const _TaskTag(
                  label: '时间块跨过任务截止',
                  fill: Color(0xFFFFF0DA),
                  textColor: Color(0xFF805900),
                ),
            ],
          ),
          if (widget.reminders != null) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: ValueKey(
                  'task-block-reminder-${block.reference.identity.localId}',
                ),
                onPressed: () => unawaited(
                  _editReminder(
                    ReminderTarget.calendar(block.reference),
                    allDay: false,
                  ),
                ),
                icon: const Icon(Icons.notifications_active_outlined, size: 17),
                label: const Text('时间块提醒'),
              ),
            ),
          ],
          if (block.draft.location.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            _BlockFact(icon: Icons.place_outlined, text: block.draft.location),
          ],
          if (block.draft.note.trim().isNotEmpty) ...[
            const SizedBox(height: 5),
            _BlockFact(icon: Icons.notes_rounded, text: block.draft.note),
          ],
        ],
      ),
    );
  }

  Future<void> _editReminder(
    ReminderTarget target, {
    required bool allDay,
  }) async {
    final data = widget.reminders;
    if (data == null) return;
    await showReminderEditor(
      context,
      data: data,
      target: target,
      allDay: allDay,
    );
  }

  Widget _detailText(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        label,
        style: const TextStyle(
          color: _muted,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 4),
      SelectableText(value, style: const TextStyle(height: 1.45)),
    ],
  );

  Widget _backToListButton() => TextButton.icon(
    key: const ValueKey('task-workspace-back-to-list'),
    onPressed: () {
      setState(() => _selected = null);
      unawaited(widget.port.selectTask(null).catchError((Object _) {}));
    },
    icon: const Icon(Icons.arrow_back_rounded, size: 17),
    label: const Text('任务列表'),
  );

  void _onSearchChanged(String value) {
    setState(() {
      _query = TaskQuery(filter: _query.filter, keyword: value, limit: 100);
    });
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 220), () {
      if (mounted) unawaited(_load(widget.port, _query));
    });
  }

  Future<void> _load(TaskWorkspacePort port, TaskQuery query) async {
    if (!mounted || !identical(port, widget.port)) return;
    final generation = _generation;
    try {
      await port.loadTasks(query: query);
      if (!_current(port, generation)) return;
      final selected = _selected;
      if (selected != null) {
        final window = port.taskView.window;
        final latest = window?.items.where(
          (t) => t.reference.localId == selected.localId,
        );
        if (window == null ||
            selected.context != window.context ||
            latest == null ||
            latest.isEmpty) {
          setState(() => _selected = null);
          await port.selectTask(null);
        } else {
          setState(() => _selected = latest.first.reference);
          await port.selectTask(latest.first.reference);
        }
      }
    } catch (error) {
      if (mounted &&
          generation == _generation &&
          identical(port, widget.port)) {
        setState(() => _notice = _safeTaskError(error));
      }
    }
  }

  Future<void> _selectTask(
    TaskWorkspacePort port,
    TaskReference reference,
  ) async {
    final generation = _generation;
    setState(() {
      _selected = reference;
      _notice = null;
    });
    try {
      await port.selectTask(reference);
    } catch (error) {
      if (mounted &&
          generation == _generation &&
          identical(port, widget.port)) {
        setState(() => _notice = _safeTaskError(error));
      }
    }
  }

  Future<void> _createTask(
    TaskWorkspacePort port,
    TaskWorkspaceView view,
  ) async {
    final window = view.window;
    if (window == null) return;
    final expectedContext = window.context;
    final generation = _generation;
    final draft = await showTaskEditor(
      context,
      heading: '新建任务',
      today: port.today,
    );
    if (draft == null || !_current(port, generation)) return;
    await _write(port, CreateTask(draft), expectedContext);
  }

  Future<void> _editTask(TaskWorkspacePort port, TaskDetail detail) async {
    final task = detail.task;
    final expectedContext = task.reference.context;
    final generation = _generation;
    final draft = await showTaskEditor(
      context,
      heading: '编辑任务',
      today: port.today,
      initial: task.draft,
    );
    if (draft == null || !_current(port, generation)) return;
    await _write(port, UpdateTask(task.reference, draft), expectedContext);
  }

  Future<void> _setTaskStatus(
    TaskWorkspacePort port,
    TaskDetail detail,
    TaskStatus status,
  ) => _write(
    port,
    SetTaskStatus(detail.task.reference, status),
    detail.task.reference.context,
  );

  Future<void> _confirmDeleteTask(
    TaskWorkspacePort port,
    TaskDetail detail,
  ) async {
    final target = detail.task.reference;
    final generation = _generation;
    final confirmed = await _confirm(
      title: '删除任务？',
      message: detail.blocks.isEmpty
          ? '任务会从列表移除。'
          : '任务会从列表和有效日程中移除；其时间块记录会保留，撤销任务删除不会恢复此前已删除的时间块。',
      confirmLabel: '删除任务',
      destructive: true,
    );
    if (!confirmed || !_current(port, generation)) return;
    final saved = await _write(
      port,
      DeleteTask(target, confirmed: true),
      target.context,
    );
    if (saved && mounted) {
      setState(() => _selected = null);
      unawaited(port.selectTask(null).catchError((Object _) {}));
    }
  }

  Future<void> _createBlock(TaskWorkspacePort port, TaskDetail detail) async {
    final task = detail.task;
    final expectedContext = task.reference.context;
    final generation = _generation;
    final draft = await showPlanBlockEditor(
      context,
      heading: '安排时间块',
      today: port.today,
    );
    if (draft == null || !_current(port, generation)) return;
    await _write(port, CreatePlanBlock(task.reference, draft), expectedContext);
  }

  Future<void> _editBlock(
    TaskWorkspacePort port,
    TaskDetail detail,
    PlanBlockRecord block,
  ) async {
    final target = block.reference;
    final expectedContext = target.context;
    final generation = _generation;
    final draft = await showPlanBlockEditor(
      context,
      heading: '移动或编辑时间块',
      today: port.today,
      initial: block.draft,
    );
    if (draft == null || !_current(port, generation)) return;
    await _write(port, UpdatePlanBlock(target, draft), expectedContext);
  }

  Future<void> _setBlockStatus(
    TaskWorkspacePort port,
    PlanBlockRecord block,
    PlanBlockStatus status,
  ) => _write(
    port,
    SetPlanBlockStatus(block.reference, status),
    block.reference.context,
  );

  Future<void> _confirmDeleteBlock(
    TaskWorkspacePort port,
    PlanBlockRecord block,
  ) async {
    final target = block.reference;
    final generation = _generation;
    final confirmed = await _confirm(
      title: '删除时间块？',
      message: '这只会删除当前时间块，不会改变任务状态。',
      confirmLabel: '删除时间块',
      destructive: true,
    );
    if (!confirmed || !_current(port, generation)) return;
    await _write(
      port,
      DeletePlanBlock(target, confirmed: true),
      target.context,
    );
  }

  Future<void> _undo(TaskWorkspacePort port, CalendarUndoView undo) async {
    final reference = undo.reference;
    if (reference == null || !undo.canUndo) return;
    await _write(
      port,
      UndoCalendarWrite(reference),
      reference.context,
      successMessage: '已撤销最近一次本地修改。',
    );
  }

  Future<bool> _write(
    TaskWorkspacePort port,
    CalendarIntent intent,
    CalendarContext expectedContext, {
    String successMessage = '已保存。',
  }) async {
    final generation = _generation;
    if (!_current(port, generation)) return false;
    final view = port.taskView;
    if (!_canWrite(view) || _actionBusy) {
      final message = _writeBlockedMessage(view);
      setState(() => _notice = message);
      return false;
    }
    setState(() {
      _actionBusy = true;
      _notice = null;
    });
    try {
      await port.executeTask(intent, expectedContext: expectedContext);
      if (!mounted || !_current(port, generation)) return false;
      setState(() => _notice = successMessage);
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(successMessage)));
      return true;
    } on CalendarFailure catch (failure) {
      if (!mounted || !_current(port, generation)) return false;
      final message = _taskFailureMessage(failure.code);
      setState(() => _notice = message);
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(message)));
      return false;
    } catch (_) {
      if (!mounted || !_current(port, generation)) return false;
      const message = '保存未完成。请检查当前任务状态后重试。';
      setState(() => _notice = message);
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text(message)));
      return false;
    } finally {
      if (_current(port, generation)) setState(() => _actionBusy = false);
    }
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: destructive
                  ? FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF9B2C2C),
                    )
                  : null,
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(confirmLabel),
            ),
          ],
        ),
      ) ??
      false;

  bool _canWrite(TaskWorkspaceView view) => view.canWrite && !_actionBusy;

  bool _current(TaskWorkspacePort port, int generation) =>
      mounted && identical(port, widget.port) && generation == _generation;

  String _writeBlockedMessage(TaskWorkspaceView view) {
    if (view.sourceBusy) return '来源操作进行中，请稍后再保存任务。';
    if (view.actionPending || _actionBusy) return '已有本地写入正在保存，请稍后再试。';
    return view.failure == null
        ? '当前任务数据尚未就绪，暂时不能保存。'
        : _taskFailureMessage(view.failure!);
  }
}

enum _TaskAction { edit, status, delete }

enum _BlockAction { edit, delete }

final class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(9),
      color: Colors.white,
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 17, color: _green),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    ),
  );
}

final class _TaskTag extends StatelessWidget {
  const _TaskTag({
    required this.label,
    required this.fill,
    this.textColor = _muted,
    this.icon,
  });

  final String label;
  final Color fill;
  final Color textColor;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: fill,
      borderRadius: BorderRadius.circular(99),
      border: Border.all(color: textColor.withValues(alpha: .14)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: textColor),
          const SizedBox(width: 4),
        ],
        Text(
          label,
          style: TextStyle(
            color: textColor,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

final class _BlockFact extends StatelessWidget {
  const _BlockFact({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 15, color: _muted),
      const SizedBox(width: 5),
      Expanded(child: Text(text, style: const TextStyle(height: 1.35))),
    ],
  );
}

final class _InlineNote extends StatelessWidget {
  const _InlineNote({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(11),
    decoration: BoxDecoration(
      color: const Color(0xFFF6F8F6),
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(9),
    ),
    child: Text(text, style: const TextStyle(color: _muted, height: 1.4)),
  );
}

final class _EmptyTaskPanel extends StatelessWidget {
  const _EmptyTaskPanel({
    required this.icon,
    required this.title,
    required this.detail,
    this.busy = false,
    this.leading,
  });
  final IconData icon;
  final String title;
  final String detail;
  final bool busy;
  final Widget? leading;

  @override
  Widget build(BuildContext context) => Card(
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (leading != null) ...[leading!, const SizedBox(height: 8)],
            if (busy)
              const SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              )
            else
              Icon(icon, size: 38, color: _green),
            const SizedBox(height: 11),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 5),
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

final class _TaskStatusLine extends StatelessWidget {
  const _TaskStatusLine({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: const Color(0xFFF5F7F5),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        Icon(icon, size: 15, color: _muted),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
        ),
      ],
    ),
  );
}

Widget _messageCard(String text, {required IconData icon}) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
  decoration: BoxDecoration(
    color: const Color(0xFFFFF0DA),
    border: Border.all(color: const Color(0xFFF0DDB7)),
    borderRadius: BorderRadius.circular(8),
  ),
  child: Row(
    children: [
      Icon(icon, size: 16, color: const Color(0xFF805900)),
      const SizedBox(width: 7),
      Expanded(child: Text(text, style: const TextStyle(height: 1.35))),
    ],
  ),
);

String _taskFilterLabel(TaskFilter filter) => switch (filter) {
  TaskFilter.open => '未完成',
  TaskFilter.all => '全部',
  TaskFilter.active => '进行中',
  TaskFilter.blocked => '受阻',
  TaskFilter.completed => '已完成',
  TaskFilter.cancelled => '已取消',
};

String _taskStatusLabel(TaskStatus status) => switch (status) {
  TaskStatus.active => '进行中',
  TaskStatus.blocked => '受阻',
  TaskStatus.completed => '已完成',
  TaskStatus.cancelled => '已取消',
};

String _priorityLabel(TaskPriority priority) => switch (priority) {
  TaskPriority.low => '低优先级',
  TaskPriority.normal => '普通优先级',
  TaskPriority.high => '高优先级',
};

Color _taskStatusFill(TaskStatus status) => switch (status) {
  TaskStatus.active => const Color(0xFFE6F1E9),
  TaskStatus.blocked => const Color(0xFFFFF0DA),
  TaskStatus.completed => const Color(0xFFE4F1E8),
  TaskStatus.cancelled => const Color(0xFFF0F3F1),
};

IconData _taskStatusIcon(TaskStatus status) => switch (status) {
  TaskStatus.active => Icons.play_circle_outline_rounded,
  TaskStatus.blocked => Icons.pause_circle_outline_rounded,
  TaskStatus.completed => Icons.check_circle_outline_rounded,
  TaskStatus.cancelled => Icons.cancel_outlined,
};

String _blockStatusLabel(PlanBlockStatus status) => switch (status) {
  PlanBlockStatus.planned => '待执行',
  PlanBlockStatus.done => '已执行',
  PlanBlockStatus.skipped => '已跳过',
};

Color _blockStatusFill(PlanBlockStatus status) => switch (status) {
  PlanBlockStatus.planned => const Color(0xFFEAF0EB),
  PlanBlockStatus.done => const Color(0xFFE4F1E8),
  PlanBlockStatus.skipped => const Color(0xFFFFF0DA),
};

IconData _blockStatusIcon(PlanBlockStatus status) => switch (status) {
  PlanBlockStatus.planned => Icons.schedule_rounded,
  PlanBlockStatus.done => Icons.check_circle_outline_rounded,
  PlanBlockStatus.skipped => Icons.event_busy_outlined,
};

String _taskFailureMessage(CalendarFailureCode failure) => switch (failure) {
  CalendarFailureCode.invalidInput => '输入不符合当前任务规则，请检查后重试。',
  CalendarFailureCode.busy => '已有本地或来源操作正在进行，请稍后重试。',
  CalendarFailureCode.staleReference => '任务已被其他修改更新，请重新读取后再操作。',
  CalendarFailureCode.idempotencyConflict => '这次操作已失效，请重新发起。',
  CalendarFailureCode.maintenance => '维护操作正在进行，当前暂不可修改任务。',
  CalendarFailureCode.limitExceeded => '已达到当前数据上限，暂时不能继续添加。',
  CalendarFailureCode.ownershipLost => '本地数据所有权已变化，请重新读取任务。',
  CalendarFailureCode.storageFailed => '本地保存失败，已有数据未确认改变。',
  CalendarFailureCode.closed => '应用当前不可写，请重新打开后再试。',
  CalendarFailureCode.undoUnavailable => '当前没有可撤销的最近一次本地修改。',
  CalendarFailureCode.undoConflict => '最近一次修改已无法安全撤销。',
};

String _taskUndoUnavailableMessage(CalendarUndoView undo) {
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

String _safeTaskError(Object error) {
  if (error is CalendarFailure) return _taskFailureMessage(error.code);
  return '读取任务失败，请稍后重试。';
}

bool _isOverdue(TaskRecord task, DateTime nowUtc) {
  final deadline = task.draft.deadlineAtUtc;
  return deadline != null &&
      !deadline.toUtc().isAfter(nowUtc.toUtc()) &&
      task.status != TaskStatus.completed &&
      task.status != TaskStatus.cancelled;
}

String _beijingDateTimeLabel(DateTime utc) {
  final value = utc.toUtc().add(const Duration(hours: 8));
  return '${_dateLabel(value)} ${_clockLabel(value)}';
}

String _blockTimeLabel(PlanBlockDraft draft) =>
    '${_beijingDateTimeLabel(draft.startsAtUtc)} – '
    '${_beijingDateTimeLabel(draft.endsAtUtc)}';

String _dateLabel(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

String _clockLabel(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}';
