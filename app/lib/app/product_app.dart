import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/agenda_contract.dart';
import '../jobs/jw_sync_port.dart';
import '../jobs/young_sync_port.dart';
import 'app_shell_contract.dart';

const _green = Color(0xFF1F6B45);
const _canvas = Color(0xFFF5F7F6);
const _line = Color(0xFFE3E9E5);
const _muted = Color(0xFF66736C);
const _blockedWriteMessage = '当前来源作业或恢复尚未完成，暂不能修改显示状态。';
const _failedWriteMessage = '未能更新显示状态，请稍后重试。';

/// The M4.1 application shell. The controller remains owned by the caller.
final class ProductApp extends StatelessWidget {
  const ProductApp({
    super.key,
    required this.controller,
    required this.settingsBuilder,
    this.agendaBuilder,
  });

  final AppShellPort controller;
  final WidgetBuilder settingsBuilder;
  final WidgetBuilder? agendaBuilder;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: _productTheme,
    home: _ProductShell(
      controller: controller,
      settingsBuilder: settingsBuilder,
      agendaBuilder: agendaBuilder,
    ),
  );
}

final ThemeData _productTheme = ThemeData(
  useMaterial3: true,
  colorScheme:
      ColorScheme.fromSeed(
        seedColor: _green,
        brightness: Brightness.light,
        surface: Colors.white,
      ).copyWith(
        primary: _green,
        onPrimary: Colors.white,
        surface: Colors.white,
        onSurface: const Color(0xFF1D2922),
        outline: _line,
        surfaceContainerHighest: const Color(0xFFF0F3F1),
      ),
  scaffoldBackgroundColor: _canvas,
  dividerColor: _line,
  appBarTheme: const AppBarTheme(
    backgroundColor: _canvas,
    foregroundColor: Color(0xFF1D2922),
    elevation: 0,
    centerTitle: false,
  ),
  cardTheme: CardThemeData(
    color: Colors.white,
    elevation: 0,
    margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: const BorderSide(color: _line),
    ),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: const Color(0xFFF5F7F6),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: _line),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: _line),
    ),
    disabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: _line),
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
  ),
  chipTheme: ChipThemeData(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    side: const BorderSide(color: _line),
    labelStyle: const TextStyle(fontSize: 13, color: Color(0xFF1D2922)),
    secondaryLabelStyle: const TextStyle(fontSize: 13, color: _green),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      disabledBackgroundColor: const Color(0xFFE8ECE9),
      disabledForegroundColor: const Color(0xFF87928B),
      minimumSize: const Size(44, 44),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  ),
);

final class _ProductShell extends StatefulWidget {
  const _ProductShell({
    required this.controller,
    required this.settingsBuilder,
    this.agendaBuilder,
  });

  final AppShellPort controller;
  final WidgetBuilder settingsBuilder;
  final WidgetBuilder? agendaBuilder;

  @override
  State<_ProductShell> createState() => _ProductShellState();
}

final class _ProductShellState extends State<_ProductShell> {
  ShellDestination _destination = ShellDestination.agent;
  AgendaSection _agendaSection = AgendaSection.schedule;
  AgendaFilter _filter = AgendaFilter.all;
  DateTime? _selectedDay;
  AgendaReference? _selectedReference;
  bool _includeHidden = false;
  bool _localActionPending = false;
  String? _actionMessage;
  int _actionGeneration = 0;
  bool _detailSheetOpen = false;
  int _detailSheetGeneration = 0;

  DateTime get _activeDay =>
      _selectedDay ?? calendarDay(widget.controller.today);

  @override
  void didUpdateWidget(covariant _ProductShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      // A port is externally owned. Drop only shell-local selection and stale
      // completion callbacks; source work keeps running on its original port.
      _actionGeneration++;
      _selectedDay = null;
      _selectedReference = null;
      _localActionPending = false;
      _actionMessage = null;
      final shouldCloseDetailSheet = _detailSheetOpen;
      _detailSheetOpen = false;
      final sheetGeneration = ++_detailSheetGeneration;
      if (shouldCloseDetailSheet) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && sheetGeneration == _detailSheetGeneration) {
            unawaited(Navigator.of(context).maybePop());
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final narrow = width < 760;
        final wide = width >= 1100;
        final destination = _destination;
        final calendarCanvas =
            destination == ShellDestination.agenda &&
            widget.agendaBuilder != null;
        return Scaffold(
          backgroundColor: _canvas,
          appBar: narrow
              ? AppBar(
                  leading: Builder(
                    builder: (context) => IconButton(
                      tooltip: '打开导航',
                      icon: const Icon(Icons.menu_rounded),
                      onPressed: () => Scaffold.of(context).openDrawer(),
                    ),
                  ),
                  title: const Text('校园事务'),
                )
              : null,
          drawer: narrow
              ? Drawer(
                  child: SafeArea(
                    child: _NavigationPanel(
                      selected: destination,
                      mode: _NavigationMode.drawer,
                      onSelected: (next) {
                        Navigator.of(context).pop();
                        _selectDestination(next);
                      },
                    ),
                  ),
                )
              : null,
          body: SafeArea(
            top: !narrow,
            child: Row(
              children: [
                if (!narrow)
                  _NavigationPanel(
                    selected: destination,
                    calendarCanvas: calendarCanvas,
                    mode: wide
                        ? _NavigationMode.expanded
                        : _NavigationMode.rail,
                    onSelected: _selectDestination,
                  ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      calendarCanvas
                          ? 12
                          : narrow
                          ? 16
                          : 28,
                      calendarCanvas
                          ? 8
                          : narrow
                          ? 12
                          : 24,
                      calendarCanvas
                          ? 12
                          : narrow
                          ? 16
                          : 28,
                      calendarCanvas
                          ? 12
                          : narrow
                          ? 16
                          : 24,
                    ),
                    child: _buildDestination(context, destination, width),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );

  void _selectDestination(ShellDestination next) {
    setState(() {
      _destination = next;
      _selectedReference = null;
      _actionMessage = null;
    });
  }

  Widget _buildDestination(
    BuildContext context,
    ShellDestination destination,
    double shellWidth,
  ) {
    switch (destination) {
      case ShellDestination.agent:
        return _buildAgentPage(context);
      case ShellDestination.agenda:
        return widget.agendaBuilder?.call(context) ??
            _buildAgendaPage(context, shellWidth);
      case ShellDestination.settings:
        return widget.settingsBuilder(context);
    }
  }

  Widget _buildAgentPage(BuildContext context) {
    final view = widget.controller.view;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _PageHeading(title: 'Agent', subtitle: '你的校园事务助手'),
        const SizedBox(height: 18),
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: _AgentEmptyState(
                  onAgenda: () => _selectDestination(ShellDestination.agenda),
                  onSources: () =>
                      _selectDestination(ShellDestination.settings),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        _SourceStatusStrip(view: view),
        const SizedBox(height: 12),
        const _DisabledComposer(),
      ],
    );
  }

  Widget _buildAgendaPage(BuildContext context, double shellWidth) {
    if (_agendaSection == AgendaSection.tasks) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _AgendaHeading(
            section: _agendaSection,
            onSectionChanged: (section) {
              setState(() {
                _agendaSection = section;
                _selectedReference = null;
                _actionMessage = null;
              });
            },
          ),
          const SizedBox(height: 16),
          const Expanded(child: _TasksPlaceholder()),
        ],
      );
    }

    final port = widget.controller;
    final day = _activeDay;
    final slice = port.readAgenda(
      day: day,
      filter: _filter,
      includeHidden: _includeHidden,
    );
    final visibleItems = slice.items.take(500).toList(growable: false);
    final wideDetail = shellWidth >= 1200;
    final selected = _findSelected(visibleItems);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AgendaHeading(
          section: _agendaSection,
          onSectionChanged: (section) {
            setState(() {
              _agendaSection = section;
              _selectedReference = null;
              _actionMessage = null;
            });
          },
        ),
        const SizedBox(height: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _AgendaToolbar(
                day: day,
                filter: _filter,
                includeHidden: _includeHidden,
                today: calendarDay(port.today),
                onDayChanged: (next) {
                  if (!mounted || !identical(port, widget.controller)) return;
                  setState(() {
                    _selectedDay = calendarDay(next);
                    _selectedReference = null;
                    _actionMessage = null;
                  });
                },
                onFilterChanged: (next) => setState(() {
                  _filter = next;
                  _selectedReference = null;
                  _actionMessage = null;
                }),
                onIncludeHiddenChanged: (next) => setState(() {
                  _includeHidden = next;
                  _selectedReference = null;
                  _actionMessage = null;
                }),
              ),
              const SizedBox(height: 12),
              if (_actionMessage != null) ...[
                _InlineNotice(
                  message: _actionMessage!,
                  icon: Icons.info_outline_rounded,
                ),
                const SizedBox(height: 10),
              ],
              if (port.view.progressUnavailable) ...[
                const _InlineNotice(
                  message: '来源进度暂不可用，当前只允许查看本地记录。',
                  icon: Icons.sync_problem_rounded,
                ),
                const SizedBox(height: 10),
              ],
              if (port.view.actionFailure != null) ...[
                const _InlineNotice(
                  message: _failedWriteMessage,
                  icon: Icons.info_outline_rounded,
                ),
                const SizedBox(height: 10),
              ],
              Expanded(
                child: wideDetail
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: _AgendaListPane(
                              slice: slice,
                              items: visibleItems,
                              selectedReference: _selectedReference,
                              onSelect: (item) => setState(() {
                                _selectedReference = item.reference;
                              }),
                            ),
                          ),
                          if (selected != null) ...[
                            const SizedBox(width: 14),
                            SizedBox(
                              width: 320,
                              child: _AgendaDetailCard(
                                item: selected,
                                writeBlocked: _isWriteBlocked(port.view),
                                blockedMessage: _writeBlockedMessage(port.view),
                                actionPending: _localActionPending,
                                onToggleHidden: () => _toggleHidden(
                                  selected.reference,
                                  hidden: !selected.hidden,
                                ),
                              ),
                            ),
                          ],
                        ],
                      )
                    : _AgendaListPane(
                        slice: slice,
                        items: visibleItems,
                        selectedReference: _selectedReference,
                        onSelect: (item) => _showDetailSheet(item),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  AgendaItem? _findSelected(List<AgendaItem> items) {
    final reference = _selectedReference;
    if (reference == null) return null;
    for (final item in items) {
      if (item.reference == reference) return item;
    }
    return null;
  }

  bool _isWriteBlocked(AppShellView view) =>
      view.globallyBusy ||
      view.jw.busy ||
      view.young.busy ||
      view.actionPending ||
      view.progressUnavailable ||
      _localActionPending;

  String _writeBlockedMessage(AppShellView view) {
    if (view.progressUnavailable) {
      return '来源进度暂不可用，当前只允许查看本地记录。';
    }
    if (view.actionPending) return '已有本地操作正在处理，请稍后再试。';
    return _blockedWriteMessage;
  }

  Future<bool> _toggleHidden(
    AgendaReference reference, {
    required bool hidden,
  }) async {
    final port = widget.controller;
    if (_isWriteBlocked(port.view)) {
      if (mounted) {
        setState(() => _actionMessage = _blockedWriteMessage);
      }
      return false;
    }

    final generation = ++_actionGeneration;
    setState(() {
      _localActionPending = true;
      _actionMessage = null;
    });
    try {
      await port.setHidden(reference, hidden: hidden);
      if (!mounted ||
          generation != _actionGeneration ||
          !identical(port, widget.controller)) {
        return false;
      }
      setState(() {
        _selectedReference = null;
        _actionMessage = null;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(hidden ? '已隐藏这条日程。' : '已恢复显示。')));
      return true;
    } catch (_) {
      if (mounted &&
          generation == _actionGeneration &&
          identical(port, widget.controller)) {
        setState(() => _actionMessage = _failedWriteMessage);
      }
      return false;
    } finally {
      if (mounted &&
          generation == _actionGeneration &&
          identical(port, widget.controller)) {
        setState(() => _localActionPending = false);
      }
    }
  }

  Future<void> _showDetailSheet(AgendaItem item) async {
    setState(() => _selectedReference = item.reference);
    final controllerAtOpen = widget.controller;
    _detailSheetOpen = true;
    final sheetGeneration = ++_detailSheetGeneration;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (sheetContext) => AnimatedBuilder(
          animation: controllerAtOpen,
          builder: (context, _) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: _AgendaDetailCard(
                item: item,
                writeBlocked:
                    !identical(controllerAtOpen, widget.controller) ||
                    _isWriteBlocked(widget.controller.view),
                blockedMessage: _writeBlockedMessage(widget.controller.view),
                actionPending: _localActionPending,
                compact: true,
                onToggleHidden: () async {
                  if (!identical(controllerAtOpen, widget.controller)) return;
                  final updated = await _toggleHidden(
                    item.reference,
                    hidden: !item.hidden,
                  );
                  if (updated && sheetContext.mounted) {
                    Navigator.of(sheetContext).pop();
                  }
                },
              ),
            ),
          ),
        ),
      );
    } finally {
      if (sheetGeneration == _detailSheetGeneration) {
        _detailSheetOpen = false;
      }
    }
    if (mounted) {
      setState(() {
        if (_selectedReference == item.reference) _selectedReference = null;
      });
    }
  }
}

enum _NavigationMode { expanded, rail, drawer }

final class _NavigationPanel extends StatelessWidget {
  const _NavigationPanel({
    required this.selected,
    required this.mode,
    required this.onSelected,
    this.calendarCanvas = false,
  });

  final ShellDestination selected;
  final _NavigationMode mode;
  final ValueChanged<ShellDestination> onSelected;
  final bool calendarCanvas;

  bool get _expanded => mode != _NavigationMode.rail;
  double get _width => switch (mode) {
    _NavigationMode.expanded => calendarCanvas ? 184 : 216,
    _NavigationMode.rail => 72,
    _NavigationMode.drawer => 264,
  };

  @override
  Widget build(BuildContext context) => Container(
    width: _width,
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(right: BorderSide(color: _line)),
    ),
    child: Padding(
      padding: EdgeInsets.symmetric(
        horizontal: _expanded ? 14 : 8,
        vertical: 18,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BrandMark(expanded: _expanded),
          const SizedBox(height: 26),
          _NavigationButton(
            key: const ValueKey('shell-nav-agent'),
            title: 'Agent',
            icon: Icons.auto_awesome_outlined,
            selected: selected == ShellDestination.agent,
            expanded: _expanded,
            onPressed: () => onSelected(ShellDestination.agent),
          ),
          const SizedBox(height: 6),
          _NavigationButton(
            key: const ValueKey('shell-nav-agenda'),
            title: '日程',
            icon: Icons.calendar_month_outlined,
            selected: selected == ShellDestination.agenda,
            expanded: _expanded,
            onPressed: () => onSelected(ShellDestination.agenda),
          ),
          const Spacer(),
          _NavigationButton(
            key: const ValueKey('shell-nav-settings'),
            title: '设置',
            icon: Icons.tune_rounded,
            selected: selected == ShellDestination.settings,
            expanded: _expanded,
            onPressed: () => onSelected(ShellDestination.settings),
          ),
          if (mode == _NavigationMode.expanded) ...[
            const SizedBox(height: 14),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                '校园事务助手',
                style: TextStyle(color: _muted, fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

final class _BrandMark extends StatelessWidget {
  const _BrandMark({required this.expanded});
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final mark = Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: const Color(0xFFEAF3ED),
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.center,
      child: const Icon(Icons.school_outlined, color: _green, size: 21),
    );
    if (!expanded) return Center(child: mark);
    return Row(
      children: [
        mark,
        const SizedBox(width: 11),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'USTC',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              Text('Assistant', style: TextStyle(fontSize: 12, color: _muted)),
            ],
          ),
        ),
      ],
    );
  }
}

final class _NavigationButton extends StatelessWidget {
  const _NavigationButton({
    super.key,
    required this.title,
    required this.icon,
    required this.selected,
    required this.expanded,
    required this.onPressed,
  });

  final String title;
  final IconData icon;
  final bool selected;
  final bool expanded;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: selected ? const Color(0xFFEAF3ED) : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: 48,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: expanded ? 12 : 0),
            child: expanded
                ? Row(
                    children: [
                      Icon(icon, size: 20, color: selected ? _green : _muted),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: selected ? _green : const Color(0xFF35433B),
                            fontSize: 14,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  )
                : Center(
                    child: Icon(
                      icon,
                      size: 21,
                      color: selected ? _green : _muted,
                    ),
                  ),
          ),
        ),
      ),
    );
    return expanded ? button : Tooltip(message: title, child: button);
  }
}

final class _PageHeading extends StatelessWidget {
  const _PageHeading({required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 3),
            Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _muted, fontSize: 13),
            ),
          ],
        ),
      ),
    ],
  );
}

final class _AgentEmptyState extends StatelessWidget {
  const _AgentEmptyState({required this.onAgenda, required this.onSources});
  final VoidCallback onAgenda;
  final VoidCallback onSources;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 34, 24, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: const Color(0xFFEAF3ED),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Icon(Icons.auto_awesome_rounded, color: _green),
          ),
          const SizedBox(height: 18),
          const Text(
            'Agent 尚未接入',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          const Text(
            '当前版本还不能进行 AI 对话。你可以先查看已有日程，或前往设置管理学校来源。',
            textAlign: TextAlign.center,
            style: TextStyle(color: _muted, height: 1.55, fontSize: 14),
          ),
          const SizedBox(height: 22),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: onAgenda,
                icon: const Icon(Icons.calendar_month_outlined, size: 18),
                label: const Text('查看日程'),
              ),
              OutlinedButton.icon(
                onPressed: onSources,
                icon: const Icon(Icons.tune_rounded, size: 18),
                label: const Text('管理来源'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

final class _DisabledComposer extends StatelessWidget {
  const _DisabledComposer();

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
          const Expanded(
            child: TextField(
              enabled: false,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: 'Agent 接入后可在这里提问',
                prefixIcon: Icon(Icons.chat_bubble_outline_rounded),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            key: const ValueKey('agent-disabled-send'),
            tooltip: '发送',
            onPressed: null,
            icon: const Icon(Icons.arrow_upward_rounded),
          ),
        ],
      ),
    ),
  );
}

final class _SourceStatusStrip extends StatelessWidget {
  const _SourceStatusStrip({required this.view});
  final AppShellView view;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      _SourceStatusChip(label: '教务', text: _jwStatus(view.jw)),
      _SourceStatusChip(label: '二课', text: _youngStatus(view.young)),
      if (view.progressUnavailable)
        const _SourceStatusChip(label: '状态', text: '进度暂不可用', warning: true),
    ],
  );
}

String _jwStatus(JwSyncView view) {
  if (view.busy && view.importCommitted) {
    return view.phase == JwSyncPhase.recovery ? '已保存，待恢复收口' : '已保存，仍在收口';
  }
  if (view.phase == JwSyncPhase.recovery) return '等待恢复收口';
  if (view.busy) return '来源作业进行中';
  if (view.data != null) return '本地记录可查看';
  return '本地资料尚未读取';
}

String _youngStatus(YoungSyncView view) {
  if (view.busy && view.committed) {
    return view.phase == YoungSyncPhase.recovery ? '已保存，待恢复收口' : '已保存，仍在收口';
  }
  if (view.phase == YoungSyncPhase.recovery) return '等待恢复收口';
  if (view.busy) return '来源作业进行中';
  if (view.data != null) return '本地记录可查看';
  return '本地资料尚未读取';
}

final class _SourceStatusChip extends StatelessWidget {
  const _SourceStatusChip({
    required this.label,
    required this.text,
    this.warning = false,
  });
  final String label;
  final String text;
  final bool warning;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(maxWidth: 300),
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
    decoration: BoxDecoration(
      color: warning ? const Color(0xFFFFF6E6) : Colors.white,
      border: Border.all(color: warning ? const Color(0xFFF0D9A8) : _line),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label · ',
          style: const TextStyle(
            color: _muted,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        Flexible(
          child: Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: warning
                  ? const Color(0xFF805900)
                  : const Color(0xFF35433B),
              fontSize: 12,
            ),
          ),
        ),
      ],
    ),
  );
}

final class _AgendaHeading extends StatelessWidget {
  const _AgendaHeading({required this.section, required this.onSectionChanged});
  final AgendaSection section;
  final ValueChanged<AgendaSection> onSectionChanged;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 500;
      final title = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '日程',
            style: TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 3),
          Text(
            section == AgendaSection.schedule ? '查看已保存的来源活动' : '任务安排功能正在准备',
            style: const TextStyle(color: _muted, fontSize: 13),
          ),
        ],
      );
      final selector = SegmentedButton<AgendaSection>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
            value: AgendaSection.schedule,
            label: Text('日程'),
            icon: Icon(Icons.event_note_outlined, size: 17),
          ),
          ButtonSegment(
            value: AgendaSection.tasks,
            label: Text('任务'),
            icon: Icon(Icons.checklist_rounded, size: 17),
          ),
        ],
        selected: {section},
        onSelectionChanged: (value) => onSectionChanged(value.first),
      );
      return compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [title, const SizedBox(height: 12), selector],
            )
          : Row(
              children: [
                Expanded(child: title),
                const SizedBox(width: 16),
                Flexible(child: selector),
              ],
            );
    },
  );
}

final class _TasksPlaceholder extends StatelessWidget {
  const _TasksPlaceholder();

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 500),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xFFEAF3ED),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Icon(Icons.checklist_rounded, color: _green),
              ),
              const SizedBox(height: 15),
              const Text(
                '任务管理正在准备',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 7),
              const Text(
                '任务会放在日程页面内管理。当前还不能创建或修改任务。',
                textAlign: TextAlign.center,
                style: TextStyle(color: _muted, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

final class _AgendaToolbar extends StatelessWidget {
  const _AgendaToolbar({
    required this.day,
    required this.today,
    required this.filter,
    required this.includeHidden,
    required this.onDayChanged,
    required this.onFilterChanged,
    required this.onIncludeHiddenChanged,
  });

  final DateTime day;
  final DateTime today;
  final AgendaFilter filter;
  final bool includeHidden;
  final ValueChanged<DateTime> onDayChanged;
  final ValueChanged<AgendaFilter> onFilterChanged;
  final ValueChanged<bool> onIncludeHiddenChanged;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.start,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              IconButton(
                tooltip: '前一天',
                onPressed: () =>
                    onDayChanged(day.subtract(const Duration(days: 1))),
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              OutlinedButton.icon(
                key: const ValueKey('agenda-day-picker'),
                onPressed: () => _pickDay(context),
                icon: const Icon(Icons.calendar_today_outlined, size: 17),
                label: Text(_formatCalendarDay(day)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF27352D),
                  side: const BorderSide(color: _line),
                  minimumSize: const Size(48, 42),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              IconButton(
                tooltip: '后一天',
                onPressed: () => onDayChanged(day.add(const Duration(days: 1))),
                icon: const Icon(Icons.chevron_right_rounded),
              ),
              TextButton(
                onPressed: () => onDayChanged(today),
                child: const Text('今天'),
              ),
              FilterChip(
                selected: includeHidden,
                onSelected: onIncludeHiddenChanged,
                label: const Text('显示隐藏记录'),
                avatar: const Icon(Icons.visibility_outlined, size: 17),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              _filterChip(AgendaFilter.all, '全部'),
              _filterChip(AgendaFilter.course, '课程'),
              _filterChip(AgendaFilter.exam, '考试'),
              _filterChip(AgendaFilter.young, '二课'),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _filterChip(AgendaFilter value, String label) => ChoiceChip(
    label: Text(label),
    selected: filter == value,
    onSelected: (_) => onFilterChanged(value),
  );

  Future<void> _pickDay(BuildContext context) async {
    final localDay = DateTime(day.year, day.month, day.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: localDay,
      firstDate: DateTime(day.year < 1900 ? day.year : 1900),
      lastDate: DateTime(day.year > 2100 ? day.year : 2100, 12, 31),
      helpText: '选择日程日期',
    );
    if (picked != null) onDayChanged(calendarDay(picked));
  }
}

String _formatCalendarDay(DateTime day) {
  const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  final weekday = DateTime.utc(day.year, day.month, day.day).weekday;
  return '${day.year}年${day.month}月${day.day}日  ${weekdays[weekday - 1]}';
}

final class _AgendaListPane extends StatelessWidget {
  const _AgendaListPane({
    required this.slice,
    required this.items,
    required this.selectedReference,
    required this.onSelect,
  });

  final AgendaSlice slice;
  final List<AgendaItem> items;
  final AgendaReference? selectedReference;
  final ValueChanged<AgendaItem> onSelect;

  @override
  Widget build(BuildContext context) {
    if (!slice.ready) {
      return const _AgendaEmptyPane(
        icon: Icons.hourglass_empty_rounded,
        title: '本地日程尚未就绪',
        detail: '本机日程资料尚未载入完成。你可以稍后再查看。',
      );
    }
    if (items.isEmpty) {
      return _AgendaEmptyPane(
        icon: Icons.event_available_outlined,
        title: '这一天没有可显示的日程',
        detail: slice.filter == AgendaFilter.all
            ? '已有来源记录会按北京时间显示在这里。'
            : '当前来源筛选下没有记录。你可以切换来源或日期查看。',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 0, 2, 9),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '符合筛选 ${slice.matched} 条 · 本地共 ${slice.totalStored} 条',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _muted,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (slice.truncated || slice.matched > items.length)
                const Text(
                  '只显示前 500 条',
                  style: TextStyle(color: _muted, fontSize: 12),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: items.length,
            padding: const EdgeInsets.only(bottom: 8),
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final item = items[index];
              final selected = item.reference == selectedReference;
              return _AgendaListTile(
                item: item,
                selected: selected,
                onTap: () => onSelect(item),
              );
            },
          ),
        ),
      ],
    );
  }
}

final class _AgendaEmptyPane extends StatelessWidget {
  const _AgendaEmptyPane({
    required this.icon,
    required this.title,
    required this.detail,
  });
  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: _green, size: 29),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: const TextStyle(color: _muted, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

final class _AgendaListTile extends StatelessWidget {
  const _AgendaListTile({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final AgendaItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final source = _sourceLabel(item.reference.source);
    return Card(
      color: selected ? const Color(0xFFF1F7F3) : Colors.white,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                runSpacing: 6,
                spacing: 8,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _SourceDot(source: item.reference.source),
                      const SizedBox(width: 7),
                      Text(
                        source,
                        style: const TextStyle(
                          color: _muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  if (item.hidden)
                    const _SmallTag(text: '已隐藏', color: Color(0xFFF1F3F2)),
                  if (item.presence == AgendaPresence.missingWithinScope)
                    const _SmallTag(text: '来源缺失，已保留', color: Color(0xFFFFF6E6)),
                  if (item.presence == AgendaPresence.outsideScope)
                    const _SmallTag(text: '当前不在来源范围', color: Color(0xFFF1F3F2)),
                ],
              ),
              const SizedBox(height: 9),
              Text(
                item.title,
                softWrap: true,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  height: 1.42,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                _formatAgendaTime(item),
                softWrap: true,
                style: const TextStyle(color: _muted, fontSize: 13),
              ),
              if (item.location != null &&
                  item.location!.trim().isNotEmpty) ...[
                const SizedBox(height: 5),
                Text(
                  item.location!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _muted, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

final class _SourceDot extends StatelessWidget {
  const _SourceDot({required this.source});
  final AgendaSource source;

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(
      color: switch (source) {
        AgendaSource.course => const Color(0xFF3777B8),
        AgendaSource.exam => const Color(0xFFD47A23),
        AgendaSource.young => _green,
      },
      shape: BoxShape.circle,
    ),
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
      style: const TextStyle(color: _muted, fontSize: 11, height: 1.25),
    ),
  );
}

final class _AgendaDetailCard extends StatelessWidget {
  const _AgendaDetailCard({
    required this.item,
    required this.writeBlocked,
    required this.blockedMessage,
    required this.actionPending,
    required this.onToggleHidden,
    this.compact = false,
  });

  final AgendaItem item;
  final bool writeBlocked;
  final String blockedMessage;
  final bool actionPending;
  final VoidCallback onToggleHidden;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final content = SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
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
                if (compact)
                  IconButton(
                    tooltip: '关闭详情',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              item.title,
              softWrap: true,
              style: const TextStyle(
                fontSize: 19,
                height: 1.4,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 18),
            _DetailLine(
              icon: Icons.schedule_rounded,
              label: '时间（北京时间）',
              value: _formatAgendaTime(item, includeDate: true),
            ),
            const SizedBox(height: 14),
            _DetailLine(
              icon: Icons.place_outlined,
              label: '地点',
              value: item.location == null || item.location!.trim().isEmpty
                  ? '地点未提供'
                  : item.location!,
            ),
            const SizedBox(height: 14),
            _DetailLine(
              icon: Icons.source_outlined,
              label: '来源',
              value: _sourceLabel(item.reference.source),
            ),
            if (item.presence != AgendaPresence.observed) ...[
              const SizedBox(height: 14),
              _DetailLine(
                icon: Icons.info_outline_rounded,
                label: '来源状态',
                value: item.presence == AgendaPresence.missingWithinScope
                    ? '来源当前缺少这条记录，本地日程仍予以保留。'
                    : '这条记录目前不在来源已观察的范围内。',
              ),
            ],
            if (item.hidden) ...[
              const SizedBox(height: 14),
              const _DetailLine(
                icon: Icons.visibility_off_outlined,
                label: '显示状态',
                value: '已隐藏',
              ),
            ],
            const SizedBox(height: 22),
            FilledButton.icon(
              onPressed: writeBlocked || actionPending ? null : onToggleHidden,
              icon: Icon(
                item.hidden
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                size: 18,
              ),
              label: Text(item.hidden ? '恢复显示' : '隐藏这条日程'),
            ),
            if (writeBlocked) ...[
              const SizedBox(height: 8),
              Text(
                blockedMessage,
                textAlign: TextAlign.center,
                style: TextStyle(color: _muted, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
    return Card(
      key: const ValueKey('agenda-detail-card'),
      clipBehavior: Clip.antiAlias,
      child: compact
          ? ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .82,
              ),
              child: content,
            )
          : content,
    );
  }
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
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: _muted, fontSize: 12)),
            const SizedBox(height: 3),
            Text(
              value,
              softWrap: true,
              style: const TextStyle(fontSize: 13, height: 1.45),
            ),
          ],
        ),
      ),
    ],
  );
}

final class _InlineNotice extends StatelessWidget {
  const _InlineNotice({required this.message, required this.icon});
  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
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
}

String _sourceLabel(AgendaSource source) => switch (source) {
  AgendaSource.course => '教务课程',
  AgendaSource.exam => '教务考试',
  AgendaSource.young => '二课日程',
};

String _formatAgendaTime(AgendaItem item, {bool includeDate = false}) {
  final start = item.startsAtUtc.toUtc().add(const Duration(hours: 8));
  final end = item.endsAtUtc.toUtc().add(const Duration(hours: 8));
  final sameDay =
      start.year == end.year &&
      start.month == end.month &&
      start.day == end.day;
  final startText = includeDate || !sameDay
      ? '${_formatDate(start)} ${_formatClock(start)}'
      : _formatClock(start);
  final endText = includeDate || !sameDay
      ? '${_formatDate(end)} ${_formatClock(end)}'
      : _formatClock(end);
  return '$startText – $endText';
}

String _formatDate(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

String _formatClock(DateTime date) =>
    '${date.hour.toString().padLeft(2, '0')}:'
    '${date.minute.toString().padLeft(2, '0')}';
