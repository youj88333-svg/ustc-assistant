import 'dart:async';

import 'package:flutter/material.dart';

import '../core/agent_contract.dart';
import '../core/reminder_contract.dart';
import 'agent_workspace_contract.dart';
import 'app_design.dart';
import 'settings_contract.dart';

/// The final onboarding page for individually opted-in permissions.
///
/// This widget only projects local settings and sends explicit user actions to
/// the existing C3/C4 ports. Its parent owns scrolling, wizard navigation, and
/// foreground scheduling lifecycle.
final class OnboardingPermissionsStep extends StatefulWidget {
  const OnboardingPermissionsStep({
    super.key,
    required this.settings,
    required this.agent,
    required this.reminders,
    required this.reminderChanges,
    required this.initialReminderView,
    this.configureSystemAccess,
    this.onBusyChanged,
  });

  final ApplicationSettingsPort settings;
  final AgentWorkspacePort agent;
  final ReminderDataPort reminders;
  final Stream<ReminderRuntimeView> reminderChanges;
  final ReminderRuntimeView initialReminderView;
  final Future<void> Function(NotificationAccessAction action)?
  configureSystemAccess;
  final ValueChanged<bool>? onBusyChanged;

  @override
  State<OnboardingPermissionsStep> createState() =>
      _OnboardingPermissionsStepState();
}

final class _OnboardingPermissionsStepState
    extends State<OnboardingPermissionsStep> {
  ReminderSettings? _reminderSettings;
  ReminderRuntimeView _runtime = const ReminderRuntimeView();
  StreamSubscription<ReminderRuntimeView>? _runtimeSubscription;
  StreamSubscription<int>? _reminderSubscription;
  VoidCallback? _settingsListener;
  VoidCallback? _agentListener;
  int _generation = 0;
  int _reminderReadGeneration = 0;
  bool _loading = true;
  bool _operationBusy = false;
  bool _reportedBusy = false;
  bool _settingsLoadFailed = false;
  bool _agentLoadFailed = false;
  bool _reminderLoadFailed = false;
  bool _reminderRefreshPending = false;
  bool _systemMessageIsError = false;
  String? _settingsMessage;
  String? _agentMessage;
  String? _reminderMessage;
  String? _systemMessage;

  @override
  void initState() {
    super.initState();
    _runtime = widget.initialReminderView;
    _attachListenablePorts();
    _watchReminderRuntime();
    _watchReminderData();
    _startInitialLoad();
  }

  @override
  void didUpdateWidget(covariant OnboardingPermissionsStep oldWidget) {
    super.didUpdateWidget(oldWidget);
    final settingsChanged = !identical(oldWidget.settings, widget.settings);
    final agentChanged = !identical(oldWidget.agent, widget.agent);
    final remindersChanged = !identical(oldWidget.reminders, widget.reminders);
    // StreamController.stream may return equal, non-identical wrappers on
    // every read. They are the same subscription source, not a new install.
    final runtimeStreamChanged =
        oldWidget.reminderChanges != widget.reminderChanges;
    if (settingsChanged || agentChanged || remindersChanged) {
      _generation++;
      _reminderReadGeneration++;
      if (settingsChanged || agentChanged) {
        _detachListenablePorts(oldWidget);
      }
      if (remindersChanged || runtimeStreamChanged) {
        unawaited(_runtimeSubscription?.cancel());
      }
      if (remindersChanged) {
        unawaited(_reminderSubscription?.cancel());
      }
      _runtime = widget.initialReminderView;
      if (remindersChanged) _reminderSettings = null;
      _loading = true;
      _operationBusy = false;
      _settingsLoadFailed = false;
      _agentLoadFailed = false;
      _reminderLoadFailed = false;
      _reminderRefreshPending = false;
      _settingsMessage = null;
      _agentMessage = null;
      _reminderMessage = null;
      _systemMessage = null;
      _systemMessageIsError = false;
      if (settingsChanged || agentChanged) _attachListenablePorts();
      if (remindersChanged || runtimeStreamChanged) _watchReminderRuntime();
      if (remindersChanged) _watchReminderData();
      _startInitialLoad();
      return;
    }
    if (runtimeStreamChanged) {
      unawaited(_runtimeSubscription?.cancel());
      _runtime = widget.initialReminderView;
      _systemMessage = null;
      _systemMessageIsError = false;
      _watchReminderRuntime();
    }
    if (oldWidget.initialReminderView != widget.initialReminderView) {
      _runtime = widget.initialReminderView;
      _systemMessage = null;
      _systemMessageIsError = false;
    }
  }

  @override
  void dispose() {
    _generation++;
    _reminderReadGeneration++;
    _detachListenablePorts(widget);
    unawaited(_runtimeSubscription?.cancel());
    unawaited(_reminderSubscription?.cancel());
    // Do not report a parent state change from dispose. The root owns the
    // wizard/lifecycle reset and invalidates any outstanding operation.
    super.dispose();
  }

  void _attachListenablePorts() {
    final settings = widget.settings;
    _settingsListener = () {
      if (!mounted || !identical(widget.settings, settings)) return;
      setState(() {});
    };
    settings.addListener(_settingsListener!);

    final agent = widget.agent;
    _agentListener = () {
      if (!mounted || !identical(widget.agent, agent)) return;
      setState(() {});
    };
    agent.addListener(_agentListener!);
  }

  void _detachListenablePorts(OnboardingPermissionsStep source) {
    final settingsListener = _settingsListener;
    if (settingsListener != null) {
      source.settings.removeListener(settingsListener);
    }
    final agentListener = _agentListener;
    if (agentListener != null) source.agent.removeListener(agentListener);
    _settingsListener = null;
    _agentListener = null;
  }

  void _watchReminderRuntime() {
    final stream = widget.reminderChanges;
    _runtimeSubscription = stream.listen(
      (view) {
        if (!mounted || widget.reminderChanges != stream) return;
        setState(() {
          _runtime = view;
          _systemMessage = null;
        });
      },
      onError: (Object _) {
        if (!mounted || widget.reminderChanges != stream) return;
        setState(() {
          _systemMessage = '系统提醒状态暂不可用；你仍可跳过此项。';
          _systemMessageIsError = true;
        });
      },
    );
  }

  void _watchReminderData() {
    final reminders = widget.reminders;
    _reminderSubscription = reminders.changes.listen(
      (_) {
        if (!mounted || !identical(widget.reminders, reminders)) return;
        if (_operationBusy) {
          _reminderRefreshPending = true;
        } else {
          unawaited(_refreshReminderSnapshot(_generation));
        }
      },
      onError: (Object _) {
        if (!mounted || !identical(widget.reminders, reminders)) return;
        setState(() {
          _reminderLoadFailed = true;
          _reminderMessage = '提醒偏好变更暂不可读取；请重新读取后核对。';
        });
      },
    );
  }

  bool _isCurrent(int generation) => mounted && generation == _generation;

  void _reportBusy(bool busy) {
    if (_reportedBusy == busy) return;
    _reportedBusy = busy;
    widget.onBusyChanged?.call(busy);
  }

  void _startInitialLoad() {
    final generation = _generation;
    _loading = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isCurrent(generation) || !_loading) return;
      _reportBusy(true);
      unawaited(_loadLocalSnapshots(generation));
    });
  }

  Future<void> _loadLocalSnapshots(int generation) async {
    final settings = widget.settings;
    final agent = widget.agent;
    final reminders = widget.reminders;
    var settingsFailed = false;
    var agentFailed = false;
    var reminderSnapshot = _reminderSettings;
    var remindersFailed = false;
    await Future.wait<void>([
      () async {
        try {
          await settings.refreshSettings();
        } on Object {
          settingsFailed = true;
        }
      }(),
      () async {
        try {
          await agent.refresh();
        } on Object {
          agentFailed = true;
        }
      }(),
      () async {
        try {
          reminderSnapshot = await reminders.inspectReminders();
        } on Object {
          remindersFailed = true;
        }
      }(),
    ]);
    if (!_isCurrent(generation) ||
        !identical(widget.settings, settings) ||
        !identical(widget.agent, agent) ||
        !identical(widget.reminders, reminders)) {
      return;
    }
    setState(() {
      _loading = false;
      _settingsLoadFailed = settingsFailed;
      _agentLoadFailed = agentFailed;
      _reminderLoadFailed = remindersFailed;
      if (!remindersFailed) _reminderSettings = reminderSnapshot;
      if (settingsFailed) {
        _settingsMessage = '评课授权状态暂不可读取；没有更改授权。';
      }
      if (agentFailed) {
        _agentMessage = 'Agent 使用权限暂不可读取；没有更改授权。';
      }
      if (remindersFailed) {
        _reminderMessage = '提醒偏好暂不可读取；没有更改提醒设置。';
      }
    });
    _reportBusy(false);
  }

  Future<void> _reloadLocalSnapshots() async {
    if (_operationBusy) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _settingsLoadFailed = false;
      _agentLoadFailed = false;
      _reminderLoadFailed = false;
      _settingsMessage = null;
      _agentMessage = null;
      _reminderMessage = null;
      _systemMessage = null;
      _systemMessageIsError = false;
    });
    _reportBusy(true);
    await _loadLocalSnapshots(generation);
  }

  int? _beginOperation() {
    if (!mounted || _loading || _operationBusy) return null;
    final generation = _generation;
    setState(() {
      _operationBusy = true;
      _settingsMessage = null;
      _agentMessage = null;
      _reminderMessage = null;
      _systemMessage = null;
      _systemMessageIsError = false;
    });
    _reportBusy(true);
    return generation;
  }

  void _finishOperation(int generation) {
    if (!_isCurrent(generation)) return;
    setState(() => _operationBusy = false);
    _reportBusy(_loading);
    if (_reminderRefreshPending) {
      _reminderRefreshPending = false;
      unawaited(_refreshReminderSnapshot(generation));
    }
  }

  Future<void> _refreshReminderSnapshot(int generation) async {
    final port = widget.reminders;
    final readGeneration = ++_reminderReadGeneration;
    try {
      final settings = await port.inspectReminders();
      if (!_isCurrent(generation) ||
          !identical(widget.reminders, port) ||
          readGeneration != _reminderReadGeneration) {
        return;
      }
      setState(() {
        _reminderSettings = settings;
        _reminderLoadFailed = false;
        _reminderMessage = null;
      });
    } on Object {
      if (_isCurrent(generation) &&
          identical(widget.reminders, port) &&
          readGeneration == _reminderReadGeneration) {
        setState(() {
          _reminderLoadFailed = true;
          _reminderMessage = '提醒偏好暂不可读取；请重新读取后核对。';
        });
      }
    }
  }

  bool _sameAgentOwnerReset(AgentAuthority expected) {
    final actual = widget.agent.view.settings?.authority;
    return actual != null &&
        actual.owner == expected.owner &&
        actual.resetEpoch == expected.resetEpoch;
  }

  bool _sameReminderOwnerReset(
    ReminderSettings expected,
    ReminderSettings actual,
  ) =>
      actual.context.owner == expected.context.owner &&
      actual.context.resetEpoch == expected.context.resetEpoch;

  Future<void> _setReminderPreference({
    required bool value,
    required bool morning,
  }) async {
    final generation = _beginOperation();
    if (generation == null) return;
    final port = widget.reminders;
    final prior = _reminderSettings;
    try {
      final current = await port.inspectReminders();
      if (!_isCurrent(generation) || !identical(widget.reminders, port)) {
        return;
      }
      if (prior != null && !_sameReminderOwnerReset(prior, current)) {
        setState(() {
          _reminderSettings = current;
          _reminderMessage = '本地资料上下文已变化，已更新显示；请核对后再调整。';
        });
        return;
      }
      final updated = morning
          ? current.preferences.copyWith(morningEnabled: value)
          : current.preferences.copyWith(enabled: value);
      await port.saveReminderPreferences(current, updated);
      if (!_isCurrent(generation) || !identical(widget.reminders, port)) {
        return;
      }
      final confirmed = await port.inspectReminders();
      if (!_isCurrent(generation) || !identical(widget.reminders, port)) {
        return;
      }
      final sameOwner = _sameReminderOwnerReset(current, confirmed);
      final savedValue = morning
          ? confirmed.preferences.morningEnabled
          : confirmed.preferences.enabled;
      final saved = sameOwner && savedValue == value;
      setState(() {
        _reminderSettings = confirmed;
        _reminderLoadFailed = false;
        _reminderMessage = saved ? '已保存提醒偏好。' : '无法确认本次提醒偏好，请核对当前设置后重试。';
      });
    } on Object {
      if (_isCurrent(generation) && identical(widget.reminders, port)) {
        setState(() {
          _reminderLoadFailed = true;
          _reminderMessage = '提醒偏好未完成，请核对当前设置后重试。';
        });
      }
    } finally {
      _finishOperation(generation);
    }
  }

  Future<void> _setIcourseConsent(bool value) async {
    final port = widget.settings;
    final settingsView = port.settingsView;
    final snapshot = settingsView.snapshot;
    if (snapshot == null || !settingsView.canWrite) return;
    final generation = _beginOperation();
    if (generation == null) return;
    final expected = snapshot.context;
    try {
      if (!_isCurrent(generation) ||
          !identical(widget.settings, port) ||
          port.settingsView.snapshot?.context != expected ||
          !port.settingsView.canWrite) {
        return;
      }
      await port.setIcourseConsent(expected, allowed: value, confirmed: true);
      if (!_isCurrent(generation) || !identical(widget.settings, port)) return;
      final confirmed = port.settingsView.snapshot;
      final saved =
          confirmed != null &&
          confirmed.context.owner == expected.owner &&
          confirmed.context.resetEpoch == expected.resetEpoch &&
          confirmed.icourseConsent == value;
      setState(() {
        _settingsLoadFailed = !saved;
        _settingsMessage = saved ? '评课公开联网授权已保存。' : '无法确认本次评课授权，请核对当前设置后重试。';
      });
    } on Object {
      if (_isCurrent(generation) && identical(widget.settings, port)) {
        setState(() {
          _settingsLoadFailed = true;
          _settingsMessage = '评课公开联网授权未完成，请核对当前设置后重试。';
        });
      }
    } finally {
      _finishOperation(generation);
    }
  }

  Future<void> _setAgentPolicy({
    required bool? personalContentAllowed,
    required bool? dailyOperationsAllowed,
  }) async {
    final port = widget.agent;
    if (port is! AgentWorkspaceUsePolicyPort || port.view.busy) return;
    final authority = port.view.settings?.authority;
    if (authority == null) return;
    final generation = _beginOperation();
    if (generation == null) return;
    try {
      if (!_isCurrent(generation) ||
          !identical(widget.agent, port) ||
          !_sameAgentOwnerReset(authority) ||
          port.view.busy) {
        return;
      }
      final latest = port.view;
      final personal = personalContentAllowed ?? latest.personalContentAllowed;
      final daily = dailyOperationsAllowed ?? latest.dailyOperationsAllowed;
      await (port as AgentWorkspaceUsePolicyPort).saveUsePolicy(
        personalContentAllowed: personal,
        dailyOperationsAllowed: daily,
      );
      if (!_isCurrent(generation) || !identical(widget.agent, port)) return;
      final current = port.view;
      final saved =
          _sameAgentOwnerReset(authority) &&
          current.personalContentAllowed == personal &&
          current.dailyOperationsAllowed == daily;
      setState(() {
        _agentLoadFailed = !saved;
        _agentMessage = saved
            ? 'Agent 使用权限已保存。'
            : '无法确认本次 Agent 授权，请核对当前设置后重试。';
      });
    } on Object {
      if (_isCurrent(generation) && identical(widget.agent, port)) {
        setState(() {
          _agentLoadFailed = true;
          _agentMessage = 'Agent 使用权限未完成，请核对当前设置后重试。';
        });
      }
    } finally {
      _finishOperation(generation);
    }
  }

  Future<void> _configureSystemAccess(NotificationAccessAction action) async {
    final configure = widget.configureSystemAccess;
    if (configure == null || _runtime.busy) return;
    final generation = _beginOperation();
    if (generation == null) return;
    try {
      await configure(action);
      if (_isCurrent(generation) &&
          identical(widget.configureSystemAccess, configure)) {
        setState(() {
          _systemMessage = switch (action) {
            NotificationAccessAction.inspect => '系统权限检查已完成；请以回读状态为准。',
            NotificationAccessAction.notifications => '通知权限操作已完成；请以系统回读状态为准。',
            NotificationAccessAction.exactAlarms => '精确提醒权限操作已完成；请以系统回读状态为准。',
            NotificationAccessAction.settings => '已请求打开系统通知设置；状态以系统回读为准。',
          };
          _systemMessageIsError = false;
        });
      }
    } on Object {
      if (_isCurrent(generation) &&
          identical(widget.configureSystemAccess, configure)) {
        setState(() {
          _systemMessage = _systemAccessFailure(action);
          _systemMessageIsError = true;
        });
      }
    } finally {
      _finishOperation(generation);
    }
  }

  bool get _controlsBusy => _loading || _operationBusy;

  @override
  Widget build(BuildContext context) {
    final settingsView = widget.settings.settingsView;
    final settingsSnapshot = settingsView.snapshot;
    final agentView = widget.agent.view;
    final usePolicyPort = widget.agent is AgentWorkspaceUsePolicyPort;
    final agentAuthority = agentView.settings?.authority;
    final agentAvailable =
        agentAuthority != null && !_agentLoadFailed && usePolicyPort;
    final reminderSettings = _reminderSettings;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_loading)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('正在读取本地授权与提醒偏好…'),
          ),
        WorkspaceSection(
          title: '系统日程提醒',
          description: '默认提前30分钟提醒。还需在下方允许系统通知，可随时修改。',
          child: reminderSettings == null
              ? _unavailable('当前提醒偏好暂不可读取；可以跳过，或稍后重新读取。')
              : SwitchListTile(
                  key: const ValueKey('onboarding-reminder-toggle'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('开启系统日程提醒'),
                  value: reminderSettings.preferences.enabled,
                  onChanged: _controlsBusy || _reminderLoadFailed
                      ? null
                      : (value) => _setReminderPreference(
                          value: value,
                          morning: false,
                        ),
                ),
        ),
        if (_reminderMessage != null)
          _message(_reminderMessage!, error: _reminderLoadFailed),
        WorkspaceSection(
          title: '自动晨报',
          description:
              '每天06:00后首次打开时整理今天安排和昨天公告。基本日程与公告会发给你选择的模型，产生用量；私人备注和聊天不发送。未配置模型时显示基础版。',
          child: reminderSettings == null
              ? _unavailable('当前晨报偏好暂不可读取；没有更改晨报设置。')
              : SwitchListTile(
                  key: const ValueKey('onboarding-morning-toggle'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('开启自动晨报'),
                  value: reminderSettings.preferences.morningEnabled,
                  onChanged: _controlsBusy || _reminderLoadFailed
                      ? null
                      : (value) =>
                            _setReminderPreference(value: value, morning: true),
                ),
        ),
        WorkspaceSection(
          title: '评课公开联网',
          description: '询问课程或教师时，可用必要的检索词查询评课社区公开内容。',
          child: settingsSnapshot == null
              ? _unavailable('当前评课授权状态暂不可读取；没有更改授权。')
              : SwitchListTile(
                  key: const ValueKey('onboarding-icourse-toggle'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('允许评课公开查询联网'),
                  value: settingsSnapshot.icourseConsent,
                  onChanged:
                      _controlsBusy ||
                          _settingsLoadFailed ||
                          !settingsView.canWrite
                      ? null
                      : _setIcourseConsent,
                ),
        ),
        if (_settingsMessage != null)
          _message(_settingsMessage!, error: _settingsLoadFailed),
        WorkspaceSection(
          title: 'Agent 私人内容读取',
          description: '允许助理按你的问题读取备注、任务描述，并发送给当前模型；关闭时这些私人内容留在本机。',
          child: !usePolicyPort
              ? _unavailable('当前运行时不提供 Agent 授权保存能力；可以跳过。')
              : agentAuthority == null
              ? _unavailable('当前 Agent 授权状态暂不可读取；没有更改授权。')
              : SwitchListTile(
                  key: const ValueKey('onboarding-private-content-toggle'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('允许按需读取私人内容'),
                  value: agentView.personalContentAllowed,
                  onChanged: _controlsBusy || !agentAvailable || agentView.busy
                      ? null
                      : (value) => _setAgentPolicy(
                          personalContentAllowed: value,
                          dailyOperationsAllowed: null,
                        ),
                ),
        ),
        WorkspaceSection(
          title: 'Agent 日常本地操作',
          description: '允许助理直接安排日程、任务和时间块，修改出勤与备注。此项不包含删除、学校同步或提醒设置权限。',
          child: !usePolicyPort
              ? _unavailable('当前运行时不提供 Agent 授权保存能力；可以跳过。')
              : agentAuthority == null
              ? _unavailable('当前 Agent 授权状态暂不可读取；没有更改授权。')
              : SwitchListTile(
                  key: const ValueKey('onboarding-daily-operations-toggle'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('允许日常本地操作'),
                  value: agentView.dailyOperationsAllowed,
                  onChanged: _controlsBusy || !agentAvailable || agentView.busy
                      ? null
                      : (value) => _setAgentPolicy(
                          personalContentAllowed: null,
                          dailyOperationsAllowed: value,
                        ),
                ),
        ),
        if (_agentMessage != null)
          _message(_agentMessage!, error: _agentLoadFailed),
        WorkspaceSection(
          title: '系统通知与精确提醒',
          description: '仅在你点击下方按钮时检查或打开系统权限；权限未知或未开启时仍可跳过。',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_systemCapabilityStatus(_runtime)),
              if (widget.configureSystemAccess != null) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _systemAccessButton(
                      '检查系统权限',
                      NotificationAccessAction.inspect,
                      'onboarding-system-inspect',
                    ),
                    _systemAccessButton(
                      '允许通知',
                      NotificationAccessAction.notifications,
                      'onboarding-system-notifications',
                    ),
                    _systemAccessButton(
                      '允许精确提醒',
                      NotificationAccessAction.exactAlarms,
                      'onboarding-system-exact',
                    ),
                    _systemAccessButton(
                      '系统通知设置',
                      NotificationAccessAction.settings,
                      'onboarding-system-settings',
                    ),
                  ],
                ),
              ],
              if (_systemMessage != null) ...[
                const SizedBox(height: 8),
                _message(_systemMessage!, error: _systemMessageIsError),
              ],
            ],
          ),
        ),
        if (_settingsLoadFailed || _agentLoadFailed || _reminderLoadFailed)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const ValueKey('onboarding-permissions-reload'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: _controlsBusy ? null : _reloadLocalSnapshots,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重新读取本地状态'),
              ),
            ),
          ),
      ],
    );
  }

  Widget _unavailable(String message) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(message, style: const TextStyle(color: AppUi.muted)),
  );

  Widget _message(String text, {bool error = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: TextStyle(color: error ? AppUi.error : AppUi.muted),
    ),
  );

  Widget _systemAccessButton(
    String label,
    NotificationAccessAction action,
    String key,
  ) => OutlinedButton(
    key: ValueKey(key),
    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
    onPressed: _controlsBusy || _runtime.busy
        ? null
        : () => _configureSystemAccess(action),
    child: Text(label),
  );
}

String _systemCapabilityStatus(ReminderRuntimeView view) {
  final capability = view.capability;
  if (capability == null) return '系统权限尚未检查；状态未知，本页不会自动申请。';
  if (!capability.available) return '此设备当前不提供系统提醒能力。';
  final parts = <String>[
    capability.enabledBySystem ? '系统通知已开启。' : '系统通知当前未开启或未获许可。',
  ];
  if (capability.exactScheduling == true) {
    parts.add('系统报告已允许精确提醒；实际投递仍受系统限制。');
  } else if (capability.exactScheduling == false) {
    parts.add('精确提醒未获许可，提醒可能延后。');
  } else {
    parts.add('精确提醒权限状态未知。');
  }
  parts.add(
    capability.schedulesAfterExit ? '系统报告应用退出后仍具备提醒能力。' : '应用退出后的提醒能力尚未确认。',
  );
  return parts.join(' ');
}

String _systemAccessFailure(NotificationAccessAction action) =>
    switch (action) {
      NotificationAccessAction.inspect => '检查系统权限失败；仍可跳过此项。',
      NotificationAccessAction.notifications => '通知权限操作未完成；仍可跳过此项。',
      NotificationAccessAction.exactAlarms => '精确提醒权限操作未完成；仍可跳过此项。',
      NotificationAccessAction.settings => '打开系统通知设置失败；仍可跳过此项。',
    };
