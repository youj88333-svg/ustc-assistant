import 'dart:async';

import 'package:flutter/material.dart';

import '../core/morning_brief_contract.dart';
import '../core/reminder_contract.dart';
import 'reminder_editor.dart';

final class M6SettingsPanel extends StatefulWidget {
  const M6SettingsPanel({
    super.key,
    required this.data,
    required this.briefs,
    required this.reminderChanges,
    required this.initialReminderView,
    required this.retryReminders,
    required this.regenerateMorning,
    this.testNotification,
  });

  final ReminderDataPort data;
  final MorningBriefDataPort briefs;
  final Stream<ReminderRuntimeView> reminderChanges;
  final ReminderRuntimeView initialReminderView;
  final Future<void> Function() retryReminders;
  final Future<void> Function() regenerateMorning;
  final Future<void> Function()? testNotification;

  @override
  State<M6SettingsPanel> createState() => _M6SettingsPanelState();
}

final class _M6SettingsPanelState extends State<M6SettingsPanel> {
  ReminderSettings? _settings;
  ReminderRuntimeView _runtime = const ReminderRuntimeView();
  StreamSubscription<ReminderRuntimeView>? _runtimeSubscription;
  StreamSubscription<int>? _settingsSubscription;
  int _generation = 0;
  int _settingsReadGeneration = 0;
  bool _loading = true;
  bool _mutationBusy = false;
  bool _settingsRefreshPending = false;
  bool _retryBusy = false;
  String? _settingsMessage;
  bool _settingsMessageIsError = false;
  String? _runtimeMessage;

  @override
  void initState() {
    super.initState();
    _runtime = widget.initialReminderView;
    _watchReminderChanges();
    _watchSettingsChanges();
    unawaited(_readSettings());
  }

  @override
  void didUpdateWidget(covariant M6SettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.data, widget.data) ||
        !identical(oldWidget.briefs, widget.briefs)) {
      _generation++;
      _settingsReadGeneration++;
      _settingsSubscription?.cancel();
      _settingsRefreshPending = false;
      _settings = null;
      _loading = true;
      _mutationBusy = false;
      _retryBusy = false;
      _settingsMessage = null;
      _settingsMessageIsError = false;
      _watchSettingsChanges();
      unawaited(_readSettings());
    }
    if (!identical(oldWidget.reminderChanges, widget.reminderChanges)) {
      _runtimeSubscription?.cancel();
      _runtime = widget.initialReminderView;
      _runtimeMessage = null;
      _watchReminderChanges();
    }
  }

  @override
  void dispose() {
    _generation++;
    _runtimeSubscription?.cancel();
    _settingsSubscription?.cancel();
    super.dispose();
  }

  void _watchSettingsChanges() {
    _settingsSubscription = widget.data.changes.listen(
      (_) {
        if (!mounted) return;
        if (_mutationBusy) {
          _settingsRefreshPending = true;
        } else {
          unawaited(_readSettings());
        }
      },
      onError: (Object _) {
        if (mounted) {
          setState(() {
            _settingsMessage = '提醒设置变更暂不可用，请重试读取当前设置。';
            _settingsMessageIsError = true;
          });
        }
      },
    );
  }

  void _watchReminderChanges() {
    _runtimeSubscription = widget.reminderChanges.listen(
      (view) {
        if (mounted) {
          setState(() {
            _runtime = view;
            _runtimeMessage = null;
          });
        }
      },
      onError: (Object _) {
        if (mounted) {
          setState(() => _runtimeMessage = '提醒状态暂不可用，请重试。');
        }
      },
    );
  }

  bool _isCurrent(int generation) => mounted && generation == _generation;

  Future<void> _readSettings({bool preserveMessage = false}) async {
    final generation = _generation;
    final readGeneration = ++_settingsReadGeneration;
    if (mounted) setState(() => _loading = true);
    try {
      final settings = await widget.data.inspectReminders();
      if (_isCurrent(generation) && readGeneration == _settingsReadGeneration) {
        if (_mutationBusy) {
          _settingsRefreshPending = true;
          return;
        }
        setState(() {
          _settings = settings;
          _loading = false;
          if (!preserveMessage) {
            _settingsMessage = null;
            _settingsMessageIsError = false;
          }
        });
      }
    } on Object {
      if (_isCurrent(generation) && readGeneration == _settingsReadGeneration) {
        setState(() {
          _loading = false;
          _settingsMessage = '无法读取提醒设置，请重试。';
          _settingsMessageIsError = true;
        });
      }
    }
  }

  Future<void> _updatePreferences(
    ReminderPreferences Function(ReminderPreferences current) update,
  ) async {
    final expected = _settings;
    if (_mutationBusy || expected == null) return;
    final generation = _generation;
    setState(() {
      _mutationBusy = true;
      _settingsMessage = null;
      _settingsMessageIsError = false;
    });
    var saved = false;
    var stale = false;
    try {
      final preferences = update(expected.preferences);
      await widget.data.saveReminderPreferences(expected, preferences);
      saved = true;
      if (!_isCurrent(generation)) return;
      final confirmed = await widget.data.inspectReminders();
      if (!_isCurrent(generation)) return;
      setState(() {
        _settings = confirmed;
        _settingsMessage = '已保存。';
        _settingsMessageIsError = false;
      });
    } on Object catch (error) {
      stale =
          error is ReminderFailure && error.code == ReminderFailureCode.stale;
      if (stale) _settingsRefreshPending = true;
      if (_isCurrent(generation)) {
        setState(() {
          _settingsMessage = stale
              ? '提醒设置已被其他操作修改，正在重新读取；请核对后再调整。'
              : saved
              ? '设置已提交，但无法重新读取确认；请重试读取当前设置。'
              : '保存提醒设置失败，请重试。';
          _settingsMessageIsError = true;
        });
      }
    } finally {
      _finishSettingsMutation(generation);
    }
  }

  void _finishSettingsMutation(int generation) {
    if (!_isCurrent(generation)) return;
    setState(() => _mutationBusy = false);
    if (_settingsRefreshPending) {
      _settingsRefreshPending = false;
      unawaited(_readSettings(preserveMessage: true));
    }
  }

  Future<void> _retryReminderQueue() async {
    if (_retryBusy || _runtime.busy) return;
    final generation = _generation;
    setState(() {
      _retryBusy = true;
      _runtimeMessage = null;
    });
    try {
      await widget.retryReminders();
      if (_isCurrent(generation)) {
        setState(() => _runtimeMessage = '已请求重试提醒队列。');
      }
    } on Object {
      if (_isCurrent(generation)) {
        setState(() => _runtimeMessage = '提醒队列重试失败，请稍后重试。');
      }
    } finally {
      if (_isCurrent(generation)) setState(() => _retryBusy = false);
    }
  }

  Future<void> _testNotification() async {
    if (_retryBusy || _runtime.busy || widget.testNotification == null) return;
    final generation = _generation;
    setState(() {
      _retryBusy = true;
      _runtimeMessage = null;
    });
    try {
      await widget.testNotification!();
      if (_isCurrent(generation)) {
        setState(
          () => _runtimeMessage = '测试提醒已登记，约 5 秒后投递；是否显示仍受 Windows 通知设置影响。',
        );
      }
    } catch (_) {
      if (_isCurrent(generation)) {
        setState(() => _runtimeMessage = '测试提醒未能登记，请查看 Windows 通知开关后重试。');
      }
    } finally {
      if (_isCurrent(generation)) setState(() => _retryBusy = false);
    }
  }

  Future<void> _regenerateMorning() async {
    if (_mutationBusy) return;
    final generation = _generation;
    setState(() {
      _mutationBusy = true;
      _settingsMessage = null;
      _settingsMessageIsError = false;
    });
    try {
      await widget.regenerateMorning();
      if (_isCurrent(generation)) {
        setState(() => _settingsMessage = '已请求重新生成晨报。');
      }
    } on Object {
      if (_isCurrent(generation)) {
        setState(() {
          _settingsMessage = '重新生成晨报失败，请稍后重试。';
          _settingsMessageIsError = true;
        });
      }
    } finally {
      _finishSettingsMutation(generation);
    }
  }

  Future<void> _confirmAndClearMorning() async {
    if (_mutationBusy) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除晨报？'),
        content: const Text('只清除本地晨报缓存，不清除日程、任务或聊天。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('m6-clear-morning-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清除晨报'),
          ),
        ],
      ),
    );
    if (!mounted || approved != true || _mutationBusy) return;
    final generation = _generation;
    setState(() {
      _mutationBusy = true;
      _settingsMessage = null;
      _settingsMessageIsError = false;
    });
    try {
      await widget.briefs.clearMorningBriefs();
      if (_isCurrent(generation)) {
        setState(() => _settingsMessage = '已清除本地晨报。');
      }
    } on Object {
      if (_isCurrent(generation)) {
        setState(() {
          _settingsMessage = '清除晨报失败，请稍后重试。';
          _settingsMessageIsError = true;
        });
      }
    } finally {
      _finishSettingsMutation(generation);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    return SingleChildScrollView(
      key: const ValueKey('m6-settings-scroll'),
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('晨报与提醒', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          if (_loading && settings == null)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (settings == null)
            _errorNotice(
              _settingsMessage ?? '无法读取提醒设置，请重试。',
              onRetry: _readSettings,
            )
          else ...[
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    key: const ValueKey('m6-system-reminders-enabled'),
                    title: const Text('系统日程提醒'),
                    subtitle: const Text('允许提醒显示在系统通知和锁屏中；系统设置仍可随时关闭通知。'),
                    value: settings.preferences.enabled,
                    onChanged: _mutationBusy
                        ? null
                        : (value) => _updatePreferences(
                            (current) => current.copyWith(enabled: value),
                          ),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    key: const ValueKey('m6-morning-enabled'),
                    title: const Text('自动晨报'),
                    subtitle: const Text(
                      '晨报会把昨天的公开通知和今天的基本日程发给你已同意的模型服务并产生用量。开启后不需每天确认；模型 Key 尚未就绪时仍可查看本地事实。',
                    ),
                    value: settings.preferences.morningEnabled,
                    onChanged: _mutationBusy
                        ? null
                        : (value) => _updatePreferences(
                            (current) =>
                                current.copyWith(morningEnabled: value),
                          ),
                  ),
                ],
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '全局默认提醒',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    const Text('单条日程可单独覆盖；恢复默认会重新继承这里的规则。'),
                    const SizedBox(height: 12),
                    Text('定时日程', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    ReminderPairControls(
                      key: const ValueKey('m6-default-timed-pair'),
                      pair: settings.preferences.timed,
                      allDay: false,
                      enabled: !_mutationBusy,
                      keyPrefix: 'm6-timed-default',
                      onChanged: (pair) => _updatePreferences(
                        (current) => current.copyWith(timed: pair),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text('全天日程', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    ReminderPairControls(
                      key: const ValueKey('m6-default-all-day-pair'),
                      pair: settings.preferences.allDay,
                      allDay: true,
                      enabled: !_mutationBusy,
                      keyPrefix: 'm6-all-day-default',
                      onChanged: (pair) => _updatePreferences(
                        (current) => current.copyWith(allDay: pair),
                      ),
                    ),
                    const Divider(height: 24),
                    SwitchListTile(
                      key: const ValueKey('m6-private-display'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('通知中隐藏日程标题'),
                      subtitle: const Text('开启后系统通知不显示日程标题。'),
                      value: settings.preferences.privateDisplay,
                      onChanged: _mutationBusy
                          ? null
                          : (value) => _updatePreferences(
                              (current) =>
                                  current.copyWith(privateDisplay: value),
                            ),
                    ),
                  ],
                ),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '提醒队列',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(_queueStatus(_runtime)),
                    if (widget.testNotification != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const ValueKey('m6-test-notification'),
                          onPressed:
                              settings.preferences.enabled &&
                                  !_mutationBusy &&
                                  !_retryBusy &&
                                  !_runtime.busy
                              ? _testNotification
                              : null,
                          icon: const Icon(Icons.notifications_active_outlined),
                          label: const Text('发送测试通知'),
                        ),
                      ),
                    if (_runtimeMessage != null) ...[
                      const SizedBox(height: 6),
                      Text(_runtimeMessage!),
                    ],
                    if (_runtime.capability case final capability?) ...[
                      const SizedBox(height: 6),
                      Text(_capabilityStatus(capability)),
                    ],
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        key: const ValueKey('m6-retry-reminders'),
                        onPressed: _retryBusy || _runtime.busy
                            ? null
                            : _retryReminderQueue,
                        icon: _retryBusy
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh_rounded),
                        label: Text(_retryBusy ? '正在重试…' : '重试提醒队列'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '晨报维护',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text('重新生成只在你点击后发起；清除晨报不会清除日程或聊天。'),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          key: const ValueKey('m6-regenerate-morning'),
                          onPressed: _mutationBusy ? null : _regenerateMorning,
                          icon: const Icon(Icons.auto_awesome_outlined),
                          label: const Text('重新生成晨报'),
                        ),
                        TextButton.icon(
                          key: const ValueKey('m6-clear-morning'),
                          onPressed: _mutationBusy
                              ? null
                              : _confirmAndClearMorning,
                          icon: const Icon(Icons.delete_outline_rounded),
                          label: const Text('清除晨报'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (_settingsMessage != null)
              _notice(context, _settingsMessage!, _settingsMessageIsError),
          ],
        ],
      ),
    );
  }

  Widget _errorNotice(String message, {required VoidCallback onRetry}) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message),
          const SizedBox(height: 8),
          TextButton(onPressed: onRetry, child: const Text('重试读取')),
        ],
      ),
    ),
  );

  Widget _notice(BuildContext context, String text, bool error) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(
      text,
      key: const ValueKey('m6-settings-message'),
      style: TextStyle(
        color: error ? Theme.of(context).colorScheme.error : null,
      ),
    ),
  );
}

String _queueStatus(ReminderRuntimeView view) {
  final coverage = view.throughDay == null
      ? '尚无覆盖日期'
      : '实际覆盖至 ${_dateOnly(view.throughDay!)}';
  if (view.busy) {
    return '提醒队列正在同步；系统已接受 ${view.accepted}/${view.desired} 项。$coverage';
  }
  final state = view.complete && view.failure == null ? '队列完整' : '覆盖尚未完整';
  final failure = view.failure == null
      ? ''
      : '失败：${_reminderFailureLabel(view.failure!)}。';
  return '$state；系统已接受 ${view.accepted}/${view.desired} 项；$coverage。$failure';
}

String _reminderFailureLabel(ReminderFailureCode code) => switch (code) {
  ReminderFailureCode.invalidInput => '提醒规则无效',
  ReminderFailureCode.stale => '日程已变化，请重新同步',
  ReminderFailureCode.maintenance => '本地维护正在进行',
  ReminderFailureCode.platformUnavailable => '系统提醒暂不可用',
  ReminderFailureCode.disabledBySystem => '系统通知未开启',
  ReminderFailureCode.publishFailed => '系统未接受部分提醒',
  ReminderFailureCode.cancelFailed => '部分旧提醒尚未撤销',
  ReminderFailureCode.cleanupPending => '仍有提醒清理待办',
  ReminderFailureCode.storageFailed => '本地记录保存失败',
  ReminderFailureCode.closed => '提醒服务已关闭',
};

String _capabilityStatus(NotificationCapability capability) {
  if (!capability.available) return '此设备暂不支持系统提醒。';
  if (!capability.enabledBySystem) return '系统通知当前未开启。';
  if (!capability.schedulesAfterExit) return '系统退出后投递能力尚未确认。';
  return '系统通知已开启。';
}

String _dateOnly(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
