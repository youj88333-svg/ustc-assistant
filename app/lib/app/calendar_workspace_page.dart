import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;

import '../core/agenda_contract.dart';
import '../core/calendar_contract.dart';
import 'calendar_event_editor.dart';
import 'calendar_week_view.dart';
import 'calendar_workspace_contract.dart';

/// M4.2 schedule workspace. All projection and write decisions remain in C3.
final class CalendarWorkspacePage extends StatefulWidget {
  const CalendarWorkspacePage({super.key, required this.controller});

  final CalendarWorkspacePort controller;

  @override
  State<CalendarWorkspacePage> createState() => _CalendarWorkspacePageState();
}

final class _CalendarWorkspacePageState extends State<CalendarWorkspacePage> {
  bool _tasksSelected = false;
  CalendarReference? _selectedReference;
  String? _notice;
  final ValueNotifier<String?> _actionFeedback = ValueNotifier(null);
  bool _actionBusy = false;
  int _controllerGeneration = 0;
  int _loadGeneration = 0;
  int _actionGeneration = 0;
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load(widget.controller));
    });
  }

  @override
  void didUpdateWidget(covariant CalendarWorkspacePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _controllerGeneration++;
      _loadGeneration++;
      _actionGeneration++;
      final routesToClose = _routeDepth;
      _routeDepth = 0;
      _selectedReference = null;
      _notice = null;
      _actionFeedback.value = null;
      _actionBusy = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_dismissRoutes(routesToClose));
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_load(widget.controller));
      });
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
    _selectedReference = null;
    _notice = null;
    _actionFeedback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
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
        const SizedBox(height: 12),
        if (_tasksSelected)
          Expanded(child: _tasksPlaceholder(context))
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
            ? (height < 560 ? 120 : 220)
            : (height < 640 ? 150 : 170),
      ),
      child: SingleChildScrollView(
        key: const ValueKey('calendar-workspace-toolbar-scroll'),
        child: toolbar,
      ),
    );
  }

  Widget _heading(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        '日程',
        style: Theme.of(
          context,
        ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          ChoiceChip(
            key: const ValueKey('calendar-workspace-tab-schedule'),
            label: const Text('日程'),
            selected: !_tasksSelected,
            onSelected: (selected) {
              if (selected) setState(() => _tasksSelected = false);
            },
          ),
          ChoiceChip(
            key: const ValueKey('calendar-workspace-tab-tasks'),
            label: const Text('任务'),
            selected: _tasksSelected,
            onSelected: (selected) {
              if (selected) setState(() => _tasksSelected = true);
            },
          ),
        ],
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
              '任务安排将在 M4.3 提供',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            const Text(
              '当前可以查看和管理日程。任务及时间规划入口尚未开放。',
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
    final filterWidth = math.min(190.0, math.max(145.0, width - 28));
    final day = _dateOnly(view.day);
    return Wrap(
      spacing: 7,
      runSpacing: 8,
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
          onPressed: () =>
              _load(widget.controller, day: _dateOnly(widget.controller.today)),
          child: const Text('今天'),
        ),
        SizedBox(
          width: filterWidth,
          child: InputDecorator(
            key: const ValueKey('calendar-workspace-filter'),
            decoration: const InputDecoration(
              labelText: '来源',
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<CalendarFilter>(
                value: view.filter,
                isExpanded: true,
                items: CalendarFilter.values
                    .map(
                      (filter) => DropdownMenuItem(
                        value: filter,
                        child: Text(
                          _filterLabel(filter),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (filter) {
                  if (filter != null) {
                    _load(widget.controller, filter: filter);
                  }
                },
              ),
            ),
          ),
        ),
        FilterChip(
          key: const ValueKey('calendar-workspace-include-inactive'),
          label: const Text('显示隐藏/跳过记录'),
          selected: view.includeInactive,
          onSelected: (include) =>
              _load(widget.controller, includeInactive: include),
        ),
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
    final hasSelected = _selectedReference != null;
    final main = view.mode == CalendarViewMode.week
        ? CalendarWeekView(
            window: window,
            today: widget.controller.today,
            onSelect: (occurrence) =>
                _selectOccurrence(occurrence, showSheet: !wideDetail),
          )
        : _dayList(window, showSheet: !wideDetail);
    final content = window.items.isEmpty
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
        if (window.truncated || window.conflictsTruncated)
          const SizedBox(height: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (window.conflicts.isNotEmpty)
                _globalConflictBrowser(window, view),
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

  Widget _globalConflictBrowser(
    CalendarWindow window,
    CalendarWorkspaceView view,
  ) => Card(
    margin: const EdgeInsets.only(bottom: 8),
    child: ListTile(
      key: const ValueKey('calendar-conflict-browser'),
      leading: const Icon(Icons.compare_arrows_rounded),
      title: Text('重叠候选（${window.conflicts.length}）'),
      subtitle: const Text('候选不受来源筛选缩小；是否相关由你判断。'),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => _showConflicts(window, widget.controller, view.canWrite),
    ),
  );

  Future<void> _showConflicts(
    CalendarWindow window,
    CalendarWorkspacePort port,
    bool canWrite,
  ) async {
    final generation = _controllerGeneration;
    await _withRoute<void>(
      () => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('重叠候选'),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 560,
              maxHeight: MediaQuery.sizeOf(context).height * .68,
            ),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: window.conflicts.length,
              separatorBuilder: (_, _) => const Divider(height: 16),
              itemBuilder: (context, index) {
                final conflict = window.conflicts[index];
                final relation = conflict.relation;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${conflict.left.title}  ·  ${conflict.right.title}',
                            softWrap: true,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${_kindLabel(conflict.left.reference.identity.kind)} × '
                            '${_kindLabel(conflict.right.reference.identity.kind)}'
                            '${relation == null ? '' : ' · 已说明：${_relationKindLabel(relation.kind)}'}',
                            style: const TextStyle(color: _muted, fontSize: 11),
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
                      child: Text(relation == null ? '说明' : '修改'),
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

  Widget _dayList(CalendarWindow window, {required bool showSheet}) {
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
        return Card(
          clipBehavior: Clip.antiAlias,
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
                      color: _kindColor(occurrence.reference.identity.kind),
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
                              ?.copyWith(fontWeight: FontWeight.w700),
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
                            ..._stateTags(occurrence),
                          ],
                        ),
                        if (occurrence.location.trim().isNotEmpty) ...[
                          const SizedBox(height: 5),
                          Text(
                            occurrence.location,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: _muted, fontSize: 12),
                          ),
                        ],
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
    final conflicts = _conflictsFor(view.window, occurrence);
    return ListView(
      key: const ValueKey('calendar-detail-content'),
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        Text(
          occurrence.title,
          softWrap: true,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 6, runSpacing: 6, children: _stateTags(occurrence)),
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
          value: occurrence.location.trim().isEmpty
              ? '地点未提供'
              : occurrence.location,
        ),
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
        if (occurrence.note.trim().isNotEmpty) ...[
          const SizedBox(height: 12),
          _DetailLine(
            icon: Icons.notes_rounded,
            label: '备注',
            value: occurrence.note,
          ),
        ],
        if (!personal) ...[
          const SizedBox(height: 12),
          _schoolOverlaySummary(occurrence),
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
        else
          _schoolActions(view, detail),
        const SizedBox(height: 18),
        if (conflicts.isNotEmpty) ...[
          _sectionHeading('重叠候选'),
          const SizedBox(height: 6),
          const Text(
            '时间重叠只是候选，不代表系统已判断冲突；来源筛选不会缩小这组候选。',
            style: TextStyle(color: _muted, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 8),
          for (final conflict in conflicts) ...[
            _conflictCard(view, occurrence, conflict),
            const SizedBox(height: 8),
          ],
        ],
        if (detail.relations.isNotEmpty) ...[
          _sectionHeading('已保存的日程说明'),
          const SizedBox(height: 8),
          for (final relation in detail.relations) ...[
            _relationCard(view, occurrence, relation),
            const SizedBox(height: 8),
          ],
        ],
      ],
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
            '删除会移除这条单次安排；跳过与恢复是单独操作。本期没有撤销入口。',
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
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              '${_kindLabel(other.reference.identity.kind)} · ${_occurrenceTime(other)}',
              style: const TextStyle(color: _muted, fontSize: 12),
            ),
            if (relation != null) ...[
              const SizedBox(height: 5),
              Text(
                '已有说明：${_relationKindLabel(relation.kind)}'
                '${relation.note.trim().isEmpty ? '' : ' · ${relation.note}'}',
                softWrap: true,
                style: const TextStyle(color: _muted, fontSize: 12),
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
                label: Text(relation == null ? '说明两条日程的关系' : '修改关系说明'),
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
              '与另一条${_kindLabel(other.kind)}的说明：${_relationKindLabel(relation.kind)}',
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
                label: const Text('删除这条关系说明'),
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
  }) async {
    if (!mounted || !identical(port, widget.controller)) return;
    final controllerGeneration = _controllerGeneration;
    final loadGeneration = ++_loadGeneration;
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
    } on CalendarFailure catch (failure) {
      if (_current(port, controllerGeneration, loadGeneration)) {
        setState(() => _notice = _failureMessage(failure.code));
      }
    } catch (_) {
      if (_current(port, controllerGeneration, loadGeneration)) {
        setState(
          () => _notice = _failureMessage(CalendarFailureCode.storageFailed),
        );
      }
    }
  }

  Future<void> _selectOccurrence(
    CalendarOccurrence occurrence, {
    required bool showSheet,
  }) async {
    final port = widget.controller;
    final controllerGeneration = _controllerGeneration;
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
    if (!_currentController(port, controllerGeneration)) return;
    if (showSheet) {
      await _withRoute<void>(
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
    }
  }

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
          content: const Text('这会删除整组安排和它的例外。本期没有撤销入口。'),
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
          content: const Text('这会从本地日程移除这条单次安排。本期没有撤销入口。'),
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
          initialKind: existing?.kind ?? CalendarRelationKind.coexist,
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
          title: const Text('删除关系说明？'),
          content: const Text('删除后将移除这条已保存的日程解释。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('calendar-relation-confirm-delete'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除说明'),
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
    required this.initialKind,
    required this.initialNote,
    required this.canSave,
    required this.isCurrent,
    required this.onSave,
  });

  final CalendarWorkspacePort controller;
  final ValueListenable<String?> feedback;
  final CalendarRelationKind initialKind;
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
    title: const Text('说明重叠日程'),
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
            const Text(
              '时间重叠只是候选。选择共存或相关，并留下你的说明。',
              style: TextStyle(color: _muted, height: 1.4),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<CalendarRelationKind>(
              key: const ValueKey('calendar-relation-kind'),
              initialValue: _kind,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '关系'),
              items: CalendarRelationKind.values
                  .map(
                    (value) => DropdownMenuItem(
                      value: value,
                      child: Text(_relationKindLabel(value)),
                    ),
                  )
                  .toList(growable: false),
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
          child: Text(_saving ? '正在保存…' : '保存说明'),
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

final class _SmallTag extends StatelessWidget {
  const _SmallTag({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: const TextStyle(color: _muted, fontSize: 11, height: 1.2),
    ),
  );
}

const _green = Color(0xFF1F6B45);
const _muted = Color(0xFF66736C);

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

String _clockLabel(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

String _filterLabel(CalendarFilter filter) => switch (filter) {
  CalendarFilter.all => '全部来源',
  CalendarFilter.course => '课程',
  CalendarFilter.exam => '考试',
  CalendarFilter.young => '二课',
  CalendarFilter.personal => '个人安排',
};

String _kindLabel(CalendarKind kind) => switch (kind) {
  CalendarKind.course => '课程',
  CalendarKind.exam => '考试',
  CalendarKind.young => '二课',
  CalendarKind.personal => '个人安排',
};

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
  CalendarRelationKind.coexist => '共存',
  CalendarRelationKind.related => '相关',
};

Color _kindColor(CalendarKind kind) => switch (kind) {
  CalendarKind.course => const Color(0xFF3777B8),
  CalendarKind.exam => const Color(0xFFD47A23),
  CalendarKind.young => _green,
  CalendarKind.personal => const Color(0xFF785A9B),
};

List<Widget> _stateTags(CalendarOccurrence occurrence) => [
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

List<CalendarConflict> _conflictsFor(
  CalendarWindow? window,
  CalendarOccurrence occurrence,
) {
  if (window == null) return const [];
  return window.conflicts
      .where(
        (conflict) =>
            conflict.left.reference.identity == occurrence.reference.identity ||
            conflict.right.reference.identity == occurrence.reference.identity,
      )
      .toList(growable: false);
}

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
};

Widget _sectionHeading(String title) => Text(
  title,
  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
);
