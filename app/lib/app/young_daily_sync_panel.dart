import 'dart:async';

import 'package:flutter/material.dart';

import '../core/contracts.dart';
import '../core/young_daily_sync_contract.dart';
import 'app_design.dart';

/// Compact controls for the separately authorized daily Young calendar sync.
final class YoungDailySyncPanel extends StatefulWidget {
  const YoungDailySyncPanel({super.key, required this.controller});

  final YoungDailySyncControlPort controller;

  @override
  State<YoungDailySyncPanel> createState() => _YoungDailySyncPanelState();
}

final class _YoungDailySyncPanelState extends State<YoungDailySyncPanel> {
  StreamSubscription<YoungDailySyncView>? _subscription;
  late YoungDailySyncView _view;
  int _controllerEpoch = 0;
  bool _settingEnabled = false;
  String? _pendingAction;
  String? _actionError;

  @override
  void initState() {
    super.initState();
    _view = widget.controller.view;
    _listen();
  }

  @override
  void didUpdateWidget(covariant YoungDailySyncPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;

    _controllerEpoch++;
    final oldSubscription = _subscription;
    _subscription = null;
    if (oldSubscription != null) unawaited(oldSubscription.cancel());
    _view = widget.controller.view;
    _settingEnabled = false;
    _pendingAction = null;
    _actionError = null;
    _listen();
  }

  void _listen() {
    final epoch = _controllerEpoch;
    _subscription = widget.controller.changes.listen(
      (next) {
        if (!_isCurrent(epoch)) return;
        setState(() {
          _view = next;
          _actionError = null;
        });
      },
      onError: (_, _) {
        if (!_isCurrent(epoch)) return;
        setState(() => _actionError = '读取每日同步状态失败，请检查应用状态后重试。');
      },
    );
  }

  @override
  void dispose() {
    _controllerEpoch++;
    final subscription = _subscription;
    if (subscription != null) unawaited(subscription.cancel());
    super.dispose();
  }

  bool _isCurrent(int epoch) => mounted && epoch == _controllerEpoch;

  bool _isCurrentPort(int epoch, YoungDailySyncControlPort port) =>
      _isCurrent(epoch) && identical(widget.controller, port);

  Future<void> _setEnabled(bool enabled) async {
    if (_settingEnabled) return;
    final epoch = _controllerEpoch;
    final port = widget.controller;
    setState(() {
      _settingEnabled = true;
      _actionError = null;
    });
    try {
      await port.setEnabled(enabled);
      if (!_isCurrentPort(epoch, port)) return;
      setState(() => _view = port.view);
    } catch (_) {
      if (!_isCurrentPort(epoch, port)) return;
      setState(() => _actionError = '保存每日同步设置失败，请稍后重试。');
    } finally {
      if (_isCurrentPort(epoch, port)) {
        setState(() => _settingEnabled = false);
      }
    }
  }

  Future<void> _runAction(
    String key,
    Future<void> Function(YoungDailySyncControlPort port) action,
  ) async {
    if (_pendingAction != null || _settingEnabled) return;
    final epoch = _controllerEpoch;
    final port = widget.controller;
    setState(() {
      _pendingAction = key;
      _actionError = null;
    });
    try {
      await action(port);
      if (!_isCurrentPort(epoch, port) || _pendingAction != key) return;
      setState(() => _view = port.view);
    } catch (_) {
      if (!_isCurrentPort(epoch, port) || _pendingAction != key) return;
      setState(() => _actionError = _actionFailureLabel(key));
    } finally {
      if (_isCurrentPort(epoch, port) && _pendingAction == key) {
        setState(() => _pendingAction = null);
      }
    }
  }

  Future<void> _cancel() async {
    if (_pendingAction == 'cancel') return;
    final epoch = _controllerEpoch;
    final port = widget.controller;
    setState(() {
      _pendingAction = 'cancel';
      _actionError = null;
    });
    try {
      await port.cancel();
      if (!_isCurrentPort(epoch, port) || _pendingAction != 'cancel') return;
      setState(() => _view = port.view);
    } catch (_) {
      if (!_isCurrentPort(epoch, port) || _pendingAction != 'cancel') return;
      setState(() => _actionError = _actionFailureLabel('cancel'));
    } finally {
      if (_isCurrentPort(epoch, port) && _pendingAction == 'cancel') {
        setState(() => _pendingAction = null);
      }
    }
  }

  String _actionFailureLabel(String action) => switch (action) {
    'sync' => '无法开始立即同步，请稍后重试。',
    'continue' => '无法继续二课同步，请检查学校窗口后重试。',
    'cancel' => '取消二课同步失败，请检查应用状态后重试。',
    _ => '每日同步操作未能完成，请检查应用状态后重试。',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final canCancel =
        (_view.phase == YoungDailySyncPhase.syncing || _view.interactive) &&
        _pendingAction != 'cancel';
    final canContinue =
        _view.phase == YoungDailySyncPhase.needsLogin &&
        _view.interactive &&
        _pendingAction == null &&
        !_settingEnabled;
    final canStart =
        _view.enabled &&
        !_view.adviceOnly &&
        _view.configured &&
        !_view.interactive &&
        _view.phase != YoungDailySyncPhase.syncing &&
        _pendingAction == null &&
        !_settingEnabled;
    final showImmediateSync =
        _view.phase != YoungDailySyncPhase.syncing && !_view.interactive;
    final startBlockedReason = showImmediateSync
        ? _syncStartBlockedReason(_view)
        : null;

    return WorkspaceSection(
      key: const ValueKey('young-daily-sync-panel'),
      title: '每日二课自动同步',
      description:
          '开启后，每天北京时间 06:00 后，应用在前台空闲时同步昨天起 31 天的二课个人日历（仅活动关联记录）。可使用已保存的学校密码，不消耗模型额度；应用退出后不会运行。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile.adaptive(
              key: const ValueKey('young-daily-sync-toggle'),
              contentPadding: EdgeInsets.zero,
              visualDensity: VisualDensity.standard,
              title: const Text('开启每日自动同步'),
              value: _view.enabled,
              onChanged: _settingEnabled ? null : _setEnabled,
            ),
          ),
          Text(
            _rangeLabel(_view),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 3),
          Text(
            _view.lastSuccessAtUtc == null
                ? '最近成功：暂无记录。'
                : '最近成功：${formatBeijing(_view.lastSuccessAtUtc!)}（北京时间）',
          ),
          if (_view.nextAttemptAtUtc != null) ...[
            const SizedBox(height: 3),
            Text(
              '${_view.phase == YoungDailySyncPhase.failed ? '下次重试' : '下次自动尝试'}：${formatBeijing(_view.nextAttemptAtUtc!)}（北京时间）',
            ),
          ],
          const SizedBox(height: 4),
          Text(
            _statusLabel(_view),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (!_view.configured) ...[
            const SizedBox(height: 3),
            Text(
              '请先在下方绑定二课账号并保存学校密码，再使用每日自动同步。',
              style: TextStyle(color: scheme.tertiary),
            ),
          ],
          if (_view.adviceOnly) ...[
            const SizedBox(height: 3),
            Text('仅建议模式下自动同步已暂停。', style: TextStyle(color: scheme.tertiary)),
          ],
          if (_view.suppressedToday) ...[
            const SizedBox(height: 3),
            Text(
              '清空日程后，今天不会自动补建；你仍可主动同步。',
              style: TextStyle(color: scheme.tertiary),
            ),
          ],
          if (_actionError case final error?) ...[
            const SizedBox(height: 4),
            Text(error, style: TextStyle(color: scheme.error)),
          ],
          if (startBlockedReason case final reason?) ...[
            const SizedBox(height: 3),
            Text(reason, style: TextStyle(color: scheme.tertiary)),
          ],
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (_view.phase == YoungDailySyncPhase.needsLogin &&
                  _view.interactive) ...[
                OutlinedButton.icon(
                  key: const ValueKey('young-daily-sync-continue'),
                  onPressed: canContinue
                      ? () => _runAction(
                          'continue',
                          (port) => port.continueAfterLogin(),
                        )
                      : null,
                  icon: const Icon(Icons.login, size: 18),
                  label: Text(
                    _pendingAction == 'continue' ? '正在继续…' : '已登录，继续',
                  ),
                ),
              ] else if (_view.phase != YoungDailySyncPhase.syncing &&
                  !_view.interactive) ...[
                OutlinedButton.icon(
                  key: const ValueKey('young-daily-sync-now'),
                  onPressed: canStart
                      ? () => _runAction('sync', (port) => port.syncNow())
                      : null,
                  icon: const Icon(Icons.sync, size: 18),
                  label: Text(_pendingAction == 'sync' ? '正在启动…' : '立即同步'),
                ),
              ],
              if (canCancel || _pendingAction == 'cancel')
                OutlinedButton.icon(
                  key: const ValueKey('young-daily-sync-cancel'),
                  onPressed: canCancel ? _cancel : null,
                  icon: const Icon(Icons.close, size: 18),
                  label: Text(_pendingAction == 'cancel' ? '正在取消…' : '取消同步'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

String _rangeLabel(YoungDailySyncView view) {
  final first = view.firstDay;
  final endExclusive = view.endDayExclusive;
  if (first == null || endExclusive == null || !endExclusive.isAfter(first)) {
    return '滚动范围：每天 06:00 后读取昨天起 31 天（首尾均含）。';
  }
  final lastInclusive = endExclusive.subtract(const Duration(days: 1));
  return '滚动范围：${_formatDate(first)} 至 ${_formatDate(lastInclusive)}（含）。';
}

String? _syncStartBlockedReason(YoungDailySyncView view) {
  if (!view.enabled) return '先开启每日自动同步，才能立即同步。';
  if (view.adviceOnly) return '仅建议模式下无法立即同步。';
  return null;
}

String _formatDate(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)}';
}

String _statusLabel(YoungDailySyncView view) => switch (view.phase) {
  YoungDailySyncPhase.disabled => '每日自动同步已关闭。',
  YoungDailySyncPhase.scheduled => '已开启，等待每天 06:00 后的自动同步时段。',
  YoungDailySyncPhase.waitingForIdle => '已到同步时段，等待应用前台空闲。',
  YoungDailySyncPhase.syncing => '正在同步二课个人日历。',
  YoungDailySyncPhase.needsLogin =>
    view.interactive ? '请在学校窗口完成登录后继续。' : '自动尝试已结束，可打开学校窗口登录后继续。',
  YoungDailySyncPhase.done => '最近一次同步已完成。',
  YoungDailySyncPhase.failed => '本轮同步未完成，自动尝试次数有上限。',
  YoungDailySyncPhase.paused =>
    view.adviceOnly ? '仅建议模式下每日自动同步已暂停。' : '每日自动同步当前已暂停。',
  YoungDailySyncPhase.closed => '每日同步服务当前不可用。',
};
