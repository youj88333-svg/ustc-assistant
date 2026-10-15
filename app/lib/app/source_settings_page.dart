import 'package:flutter/material.dart';

import '../core/young_daily_sync_contract.dart';
import '../core/young_work_contract.dart';
import '../jobs/jw_sync_port.dart';
import '../jobs/young_sync_port.dart';
import 'app_shell_contract.dart';
import 'jw_sync_panel.dart';
import 'young_daily_sync_panel.dart';
import 'young_sync_panel.dart';

enum _SelectedSource { jw, young }

/// Product projection for the existing JW and Young source ports.
///
/// Switching sources only changes which form is mounted. Each panel clears
/// unsubmitted secret input when it is disposed, while the source controllers
/// remain owned by the application shell and continue to publish current work.
final class SourceSettingsPage extends StatefulWidget {
  const SourceSettingsPage({
    super.key,
    required this.controller,
    this.diagnosticsBuilder,
    this.dailySync,
  });

  final AppShellPort controller;
  final WidgetBuilder? diagnosticsBuilder;
  final YoungDailySyncControlPort? dailySync;

  @override
  State<SourceSettingsPage> createState() => _SourceSettingsPageState();
}

final class _SourceSettingsPageState extends State<SourceSettingsPage> {
  _SelectedSource _selectedSource = _SelectedSource.jw;
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final view = widget.controller.view;
      final locked =
          view.globallyBusy || view.actionPending || view.progressUnavailable;
      final currentSourceIdle = _selectedSource == _SelectedSource.jw
          ? !view.jw.busy
          : !view.young.busy;

      return Scrollbar(
        controller: _scrollController,
        thumbVisibility: true,
        child: SingleChildScrollView(
          key: const ValueKey('source-settings-scroll'),
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '来源设置',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _sharedPasswordNote(context),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        key: const ValueKey('source-settings-jw'),
                        selected: _selectedSource == _SelectedSource.jw,
                        avatar: const Icon(Icons.school_outlined, size: 18),
                        label: const Text('教务'),
                        onSelected: (_) => setState(
                          () => _selectedSource = _SelectedSource.jw,
                        ),
                      ),
                      ChoiceChip(
                        key: const ValueKey('source-settings-young'),
                        selected: _selectedSource == _SelectedSource.young,
                        avatar: const Icon(
                          Icons.event_available_outlined,
                          size: 18,
                        ),
                        label: const Text('二课'),
                        onSelected: (_) => setState(
                          () => _selectedSource = _SelectedSource.young,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.maxWidth < 520
                          ? constraints.maxWidth
                          : (constraints.maxWidth - 12) / 2;
                      return Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          SizedBox(
                            width: width,
                            child: _sourceStatus(
                              context,
                              title: '教务',
                              status: _jwStatus(view.jw),
                              recovery: view.jw.phase == JwSyncPhase.recovery,
                              busy: view.jw.busy,
                            ),
                          ),
                          SizedBox(
                            width: width,
                            child: _sourceStatus(
                              context,
                              title: '二课',
                              status: _youngStatus(view.young),
                              recovery:
                                  view.young.phase == YoungSyncPhase.recovery,
                              busy: view.young.busy,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  if (_selectedSource == _SelectedSource.young &&
                      widget.dailySync != null) ...[
                    const SizedBox(height: 10),
                    YoungDailySyncPanel(controller: widget.dailySync!),
                  ],
                  if (view.progressUnavailable ||
                      view.actionPending ||
                      (view.globallyBusy && currentSourceIdle)) ...[
                    const SizedBox(height: 8),
                    _availabilityNote(
                      context,
                      view: view,
                      otherSourceBusy: view.globallyBusy && currentSourceIdle,
                    ),
                  ],
                  if (widget.diagnosticsBuilder != null) ...[
                    const SizedBox(height: 2),
                    _LazyDiagnosticsSection(
                      key: ValueKey(
                        'source-settings-dev-${_selectedSource.name}',
                      ),
                      builder: widget.diagnosticsBuilder!,
                    ),
                  ],
                  const SizedBox(height: 12),
                  _selectedSource == _SelectedSource.jw
                      ? JwSyncPanel(
                          controller: widget.controller.jw,
                          productMode: true,
                          embedded: true,
                          blockNewActions: locked,
                        )
                      : YoungSyncPanel(
                          controller: widget.controller.young,
                          productMode: true,
                          embedded: true,
                          blockNewActions: locked,
                        ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _sharedPasswordNote(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.46),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline, size: 20),
          SizedBox(width: 9),
          Expanded(child: Text('教务和二课共用本机加密学校密码，仅用于学校登录；删除影响两个来源。')),
        ],
      ),
    );
  }

  Widget _sourceStatus(
    BuildContext context, {
    required String title,
    required String status,
    required bool recovery,
    required bool busy,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final color = recovery
        ? scheme.error
        : busy
        ? scheme.tertiary
        : scheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              recovery
                  ? Icons.error_outline
                  : busy
                  ? Icons.sync
                  : Icons.check_circle_outline,
              color: color,
              size: 18,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 2),
                Text(status, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _availabilityNote(
    BuildContext context, {
    required AppShellView view,
    required bool otherSourceBusy,
  }) {
    final message = view.progressUnavailable
        ? '来源进度暂不可用，新的同步、清理和编辑操作已暂停。'
        : view.actionPending
        ? '本机正在处理另一项操作，请稍候再试。'
        : otherSourceBusy
        ? '另一项来源作业正在运行；当前来源的新操作暂不可用。'
        : null;
    if (message == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(message, style: TextStyle(color: scheme.onSurface)),
    );
  }
}

String _jwStatus(JwSyncView view) {
  if (view.phase == JwSyncPhase.recovery && view.importCommitted) {
    return '数据已保存，窗口关闭待恢复';
  }
  if (view.phase == JwSyncPhase.idle && view.importCommitted) {
    return '课表与考试日程已保存';
  }
  if (view.phase == JwSyncPhase.recovery) return '登录窗口待恢复';
  if (view.automation == JwAutomationState.manualRequired) {
    return '需要在学校窗口完成操作';
  }
  if (view.automation == JwAutomationState.choosingSemester) {
    return '等待选择课表学期';
  }
  return switch (view.phase) {
    JwSyncPhase.idle =>
      view.accountBound || (view.data?.accountBound ?? false)
          ? '可同步课表与考试'
          : '等待首次登录',
    JwSyncPhase.opening => '正在打开登录窗口',
    JwSyncPhase.login => '登录窗口已打开',
    JwSyncPhase.verifying => '正在读取学期目录',
    JwSyncPhase.collecting => '正在同步',
    JwSyncPhase.closing => '正在关闭登录窗口',
    JwSyncPhase.committing => '正在保存日程',
    JwSyncPhase.recovery => '登录窗口待恢复',
    JwSyncPhase.closed => '登录窗口已关闭',
  };
}

String _youngStatus(YoungSyncView view) {
  if (view.phase == YoungSyncPhase.recovery && view.committed) {
    return '数据已保存，窗口关闭待恢复';
  }
  if (view.phase == YoungSyncPhase.recovery) return '登录窗口待恢复';
  if (view.automation == YoungAutomationState.manualRequired) {
    return '需要在学校窗口完成操作';
  }
  if (view.phase == YoungSyncPhase.idle && view.committed) {
    return view.kind == YoungJobKind.activities ? '活动查询已完成' : '二课日程已保存';
  }
  return switch (view.phase) {
    YoungSyncPhase.idle =>
      view.accountBound || (view.data?.accountBound ?? false)
          ? '可同步日程或查询活动'
          : '等待首次登录',
    YoungSyncPhase.opening => '正在打开登录窗口',
    YoungSyncPhase.login => '登录窗口已打开',
    YoungSyncPhase.collecting =>
      view.kind == YoungJobKind.activities ? '正在查询活动' : '正在同步日程',
    YoungSyncPhase.closing => '正在关闭登录窗口',
    YoungSyncPhase.committing => '正在保存日程',
    YoungSyncPhase.recovery => '登录窗口待恢复',
    YoungSyncPhase.closed => '登录窗口已关闭',
  };
}

final class _LazyDiagnosticsSection extends StatefulWidget {
  const _LazyDiagnosticsSection({super.key, required this.builder});

  final WidgetBuilder builder;

  @override
  State<_LazyDiagnosticsSection> createState() =>
      _LazyDiagnosticsSectionState();
}

final class _LazyDiagnosticsSectionState
    extends State<_LazyDiagnosticsSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    key: const ValueKey('source-settings-development-diagnostics'),
    tilePadding: EdgeInsets.zero,
    title: const Text('开发诊断'),
    onExpansionChanged: (expanded) => setState(() => _expanded = expanded),
    children: _expanded ? <Widget>[widget.builder(context)] : const <Widget>[],
  );
}
