import 'package:flutter/material.dart';

import '../core/young_daily_sync_contract.dart';
import '../core/young_work_contract.dart';
import '../jobs/jw_sync_port.dart';
import '../jobs/young_sync_port.dart';
import 'app_design.dart';
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
      final horizontalInset = MediaQuery.sizeOf(context).width < 560
          ? 16.0
          : 24.0;

      return Scrollbar(
        controller: _scrollController,
        thumbVisibility: true,
        child: SingleChildScrollView(
          key: const ValueKey('source-settings-scroll'),
          controller: _scrollController,
          padding: EdgeInsets.fromLTRB(
            horizontalInset,
            16,
            horizontalInset,
            12,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: AppUi.formWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '来源设置',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  _sharedPasswordNote(),
                  const SizedBox(height: 4),
                  Wrap(
                    key: const ValueKey('source-settings-tabs'),
                    spacing: 4,
                    children: [
                      _sourceOption(
                        _SelectedSource.jw,
                        const ValueKey('source-settings-jw'),
                        '教务',
                      ),
                      _sourceOption(
                        _SelectedSource.young,
                        const ValueKey('source-settings-young'),
                        '二课',
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Column(
                    children: [
                      _sourceStatus(
                        context,
                        title: '教务',
                        status: _jwStatus(view.jw),
                        recovery: view.jw.phase == JwSyncPhase.recovery,
                        busy: view.jw.busy,
                      ),
                      _sourceStatus(
                        context,
                        title: '二课',
                        status: _youngStatus(view.young),
                        recovery: view.young.phase == YoungSyncPhase.recovery,
                        busy: view.young.busy,
                      ),
                    ],
                  ),
                  if (_selectedSource == _SelectedSource.young &&
                      widget.dailySync != null) ...[
                    const SizedBox(height: 8),
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

  Widget _sourceOption(_SelectedSource source, Key key, String label) {
    final selected = _selectedSource == source;
    return Semantics(
      selected: selected,
      child: IntrinsicWidth(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              key: key,
              style: TextButton.styleFrom(
                foregroundColor: selected ? AppUi.accent : AppUi.ink,
                minimumSize: const Size(64, 48),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                tapTargetSize: MaterialTapTargetSize.padded,
                textStyle: TextStyle(
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
              onPressed: () => setState(() => _selectedSource = source),
              child: Text(label),
            ),
            Container(
              height: 2,
              width: double.infinity,
              color: selected ? AppUi.accent : Colors.transparent,
            ),
          ],
        ),
      ),
    );
  }

  Widget _sharedPasswordNote() {
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppUi.line)),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.lock_outline, size: 18, color: AppUi.muted),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                '教务和二课共用本机加密学校密码，仅用于学校登录；删除会影响两个来源。',
                style: TextStyle(color: AppUi.muted),
              ),
            ),
          ],
        ),
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
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppUi.line)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
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
            SizedBox(
              width: 52,
              child: Text(title, style: Theme.of(context).textTheme.labelLarge),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(status, softWrap: true)),
          ],
        ),
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
