import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'agent_workspace_contract.dart';
import '../core/agent_action_contract.dart';
import '../core/agent_contract.dart';

const _settingsMuted = Color(0xFF66736C);
const _settingsGreen = Color(0xFF1F6B45);

/// Settings for the fixed school model service. The controller is externally
/// owned; this widget only holds an unsaved key in its text field.
final class AgentSettingsPanel extends StatefulWidget {
  const AgentSettingsPanel({super.key, required this.controller});

  final AgentWorkspacePort controller;

  @override
  State<AgentSettingsPanel> createState() => _AgentSettingsPanelState();
}

final class _AgentSettingsPanelState extends State<AgentSettingsPanel> {
  final TextEditingController _key = TextEditingController();
  int _generation = 0;
  bool _pending = false;
  bool _showKey = false;
  bool _messageIsError = false;
  bool? _consentDraft;
  String? _message;

  @override
  void initState() {
    super.initState();
    _scheduleRefresh();
  }

  @override
  void didUpdateWidget(covariant AgentSettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _generation++;
      _pending = false;
      _consentDraft = null;
      _selectedModel = null;
      _messageIsError = false;
      _message = null;
      _key.clear();
      _scheduleRefresh();
    }
  }

  @override
  void dispose() {
    _generation++;
    _key.clear();
    _key.dispose();
    super.dispose();
  }

  void _scheduleRefresh() {
    final port = widget.controller;
    final generation = _generation;
    scheduleMicrotask(() {
      if (_isCurrent(port, generation)) unawaited(_refresh(port, generation));
    });
  }

  bool _isCurrent(AgentWorkspacePort port, int generation) =>
      mounted &&
      identical(widget.controller, port) &&
      _generation == generation;

  Future<void> _refresh(AgentWorkspacePort port, int generation) async {
    try {
      await port.refresh();
    } on Object {
      if (_isCurrent(port, generation)) {
        setState(() {
          _message = '暂时无法读取 Agent 设置，请稍后重试。';
          _messageIsError = true;
        });
      }
    }
  }

  Future<void> _setConsent(bool consent) async {
    final port = widget.controller;
    final generation = _generation;
    if (port.view.settings?.keySaved != true) {
      setState(() => _consentDraft = consent);
      return;
    }
    await _perform(
      port,
      generation,
      () => port.setModelConsent(consent),
      success: consent ? '已开启模型联网授权。' : '已关闭模型联网授权，Key 和对话仍保留。',
    );
    if (_isCurrent(port, generation)) setState(() => _consentDraft = null);
  }

  Future<void> _perform(
    AgentWorkspacePort port,
    int generation,
    Future<void> Function() action, {
    required String success,
  }) async {
    if (!_isCurrent(port, generation) || _pending) return;
    setState(() {
      _pending = true;
      _message = null;
      _messageIsError = false;
    });
    try {
      await action();
      if (_isCurrent(port, generation)) {
        final failure = port.view.failure;
        setState(() {
          _message = failure == null ? success : _failureText(failure);
          _messageIsError = failure != null;
        });
      }
    } on Object {
      if (_isCurrent(port, generation)) {
        setState(() {
          _message = '操作暂未完成，请检查网络或稍后重试。';
          _messageIsError = true;
        });
      }
    } finally {
      if (_isCurrent(port, generation)) setState(() => _pending = false);
    }
  }

  Future<void> _loadModels(bool consent) async {
    final port = widget.controller;
    final generation = _generation;
    final key = _key.text;
    _key.clear();
    await _perform(
      port,
      generation,
      () => port.loadModels(key: key, consent: consent),
      success: '模型列表已更新。',
    );
  }

  Future<void> _verifyAndSave(bool consent, String? modelId) async {
    if (modelId == null) return;
    final port = widget.controller;
    final generation = _generation;
    final key = _key.text;
    _key.clear();
    await _perform(
      port,
      generation,
      () => port.verifyAndSave(key: key, modelId: modelId, consent: consent),
      success: '模型验证与设置已完成。',
    );
  }

  Future<void> _deleteKey() async {
    final port = widget.controller;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除已保存的模型 Key？'),
        content: const Text('这只会删除本机保存的模型 Key。学校账号密码、业务数据和对话历史会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('agent-settings-delete-key-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除 Key'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _perform(
      port,
      _generation,
      () => port.deleteKey(confirmed: true),
      success: '已删除本机保存的模型 Key。',
    );
  }

  Future<void> _copySummary() async {
    final port = widget.controller;
    final generation = _generation;
    try {
      await Clipboard.setData(
        ClipboardData(text: port.safeValidationSummary()),
      );
      if (_isCurrent(port, generation)) {
        setState(() {
          _message = '已复制安全能力摘要。';
          _messageIsError = false;
        });
      }
    } on Object {
      if (_isCurrent(port, generation)) {
        setState(() {
          _message = '暂时无法复制安全能力摘要。';
          _messageIsError = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final view = widget.controller.view;
      final settings = view.settings;
      final report = settings?.report ?? view.report;
      final consent = _consentDraft ?? settings?.consent ?? false;
      final models = <String>{
        ...view.availableModels,
        ...?settings?.modelIds,
        if (settings?.modelId != null) settings!.modelId!,
      }.where((model) => model.trim().isNotEmpty).toList()..sort();
      final selectedModel = models.contains(_selectedModel)
          ? _selectedModel
          : models.contains(settings?.modelId)
          ? settings?.modelId
          : null;
      final keySaved = settings?.keySaved ?? false;
      final portBusy = view.busy || view.phase == AgentPhase.closed || _pending;
      final preferencesPort = widget.controller is AgentPreferencesWorkspacePort
          ? widget.controller as AgentPreferencesWorkspacePort
          : null;
      final canLoad =
          !portBusy && consent && (keySaved || _key.text.isNotEmpty);
      final canVerify =
          !portBusy &&
          consent &&
          selectedModel != null &&
          (keySaved || view.pendingKeyProvided || _key.text.isNotEmpty);

      return ListView(
        key: const ValueKey('agent-settings-panel'),
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 20),
        children: [
          _SettingsCard(
            title: '学校模型服务',
            subtitle: '服务地址由应用固定管理；只读查询按本次问题需要调用。',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _FixedServiceRow(),
                const SizedBox(height: 14),
                TextField(
                  key: const ValueKey('agent-settings-key'),
                  controller: _key,
                  obscureText: !_showKey,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: '模型 Key',
                    hintText: keySaved ? '留空以使用已保存的 Key' : '输入模型 Key',
                    helperText: keySaved
                        ? '已保存的 Key 不会回填到此处。'
                        : '输入内容只在本次页面操作中暂存。',
                    suffixIcon: IconButton(
                      tooltip: _showKey ? '隐藏 Key' : '显示 Key',
                      onPressed: () => setState(() => _showKey = !_showKey),
                      icon: Icon(
                        _showKey ? Icons.visibility_off : Icons.visibility,
                      ),
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F7F6),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE3E9E5)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '发送前说明',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        '发起模型请求时，本次问题、你主动选择并附加的图片、相关对话历史，以及回答所需的业务字段和已核验资料片段会按需发送到学校模型服务。图片输入能力尚未核验；若模型拒绝图片，应用不会移除图片后自动重发。只有明确勾选同意后，才会获取模型列表或验证并保存设置。',
                        style: TextStyle(color: _settingsMuted, height: 1.45),
                      ),
                      Material(
                        color: Colors.transparent,
                        child: CheckboxListTile(
                          key: const ValueKey('agent-settings-consent'),
                          contentPadding: EdgeInsets.zero,
                          value: consent,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: const Text('我已了解并同意按上述说明发送必要内容'),
                          onChanged: portBusy
                              ? null
                              : (value) =>
                                    unawaited(_setConsent(value ?? false)),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey('agent-settings-load-models'),
                      onPressed: canLoad ? () => _loadModels(consent) : null,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('获取模型'),
                    ),
                    FilledButton.icon(
                      key: const ValueKey('agent-settings-verify-save'),
                      onPressed: canVerify
                          ? () => _verifyAndSave(consent, selectedModel)
                          : null,
                      icon: const Icon(Icons.verified_outlined),
                      label: const Text('验证并保存'),
                    ),
                    if (keySaved)
                      TextButton.icon(
                        key: const ValueKey('agent-settings-delete-key'),
                        onPressed: portBusy ? null : _deleteKey,
                        icon: const Icon(Icons.delete_outline_rounded),
                        label: const Text('删除 Key'),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const ValueKey('agent-settings-model'),
                  isExpanded: true,
                  initialValue: selectedModel,
                  decoration: const InputDecoration(
                    labelText: '模型',
                    helperText: '从服务返回或本机已保存的模型中选择。',
                  ),
                  items: [
                    for (final model in models)
                      DropdownMenuItem(
                        value: model,
                        child: Text(
                          model,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: portBusy || models.isEmpty
                      ? null
                      : (value) => setState(() => _selectedModel = value),
                ),
                if (view.phase != AgentPhase.idle &&
                    view.phase != AgentPhase.closed) ...[
                  const SizedBox(height: 10),
                  _PhaseNotice(phase: view.phase),
                ],
                if (view.pendingKeyProvided) ...[
                  const SizedBox(height: 8),
                  const Text(
                    '模型目录已获取，可以继续选择模型并验证设置。',
                    style: TextStyle(color: _settingsMuted),
                  ),
                ],
                if (_message != null || view.failure != null) ...[
                  const SizedBox(height: 10),
                  _SettingsNotice(
                    message: _message ?? _failureText(view.failure!),
                    isError:
                        _messageIsError ||
                        (_message == null && view.failure != null),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (preferencesPort != null) ...[
            _SettingsCard(
              title: '时间规划偏好',
              subtitle: '只按你明确保存的条件辅助后续规划，不会根据聊天内容自动调整。',
              child: _PlanningPreferencesEditor(port: preferencesPort),
            ),
            const SizedBox(height: 14),
          ],
          _SettingsCard(
            title: '能力状态',
            subtitle: '能力验核只发送合成测试文本；实际只读查询会按需发送必要字段与已核验资料片段。',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _CapabilityChip(label: '文本', enabled: report.text),
                    _CapabilityChip(label: '流式', enabled: report.streaming),
                    _CapabilityChip(label: '工具调用', enabled: report.toolCall),
                    _CapabilityChip(label: '工具结果', enabled: report.toolResult),
                  ],
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const ValueKey('agent-settings-copy-summary'),
                  onPressed: _pending ? null : _copySummary,
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('复制安全能力摘要'),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );

  String? _selectedModel;
}

final class _FixedServiceRow extends StatelessWidget {
  const _FixedServiceRow();

  @override
  Widget build(BuildContext context) => const Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(Icons.school_outlined, size: 20, color: _settingsGreen),
      SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('学校模型服务', style: TextStyle(fontWeight: FontWeight.w600)),
            SizedBox(height: 3),
            Text(
              '连接信息由应用管理，不在此页面编辑。',
              style: TextStyle(color: _settingsMuted, height: 1.4),
            ),
          ],
        ),
      ),
    ],
  );
}

final class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(subtitle, style: const TextStyle(color: _settingsMuted)),
          const SizedBox(height: 14),
          child,
        ],
      ),
    ),
  );
}

final class _PlanningPreferencesEditor extends StatefulWidget {
  const _PlanningPreferencesEditor({required this.port});

  final AgentPreferencesWorkspacePort port;

  @override
  State<_PlanningPreferencesEditor> createState() =>
      _PlanningPreferencesEditorState();
}

final class _PlanningPreferencesEditorState
    extends State<_PlanningPreferencesEditor> {
  AgentPlanningPreferences? _preferences;
  int _generation = 0;
  bool _loading = false;
  bool _saving = false;
  bool _dirty = false;
  bool _needsReload = false;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  @override
  void didUpdateWidget(covariant _PlanningPreferencesEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.port, widget.port)) {
      _generation++;
      _preferences = null;
      _loading = false;
      _saving = false;
      _dirty = false;
      _needsReload = false;
      _error = null;
      _notice = null;
      unawaited(_reload());
    }
  }

  bool _isCurrent(AgentPreferencesWorkspacePort port, int generation) =>
      mounted && identical(widget.port, port) && _generation == generation;

  Future<void> _reload() async {
    if (_loading || _saving) return;
    final port = widget.port;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _notice = null;
    });
    try {
      final preferences = await port.readPlanningPreferences();
      if (_isCurrent(port, generation)) {
        setState(() {
          _preferences = preferences;
          _dirty = false;
          _needsReload = false;
        });
      }
    } on Object {
      if (_isCurrent(port, generation)) {
        setState(() {
          _error = '暂时无法读取时间规划偏好，请重试。';
        });
      }
    } finally {
      if (_isCurrent(port, generation)) setState(() => _loading = false);
    }
  }

  void _change({
    List<int>? weekdays,
    int? startMinute,
    int? endMinute,
    int? blockMinutes,
    int? breakMinutes,
    List<(int, int)>? avoid,
  }) {
    final current = _preferences;
    if (current == null || !_canEdit) return;
    setState(() {
      _preferences = AgentPlanningPreferences(
        revision: current.revision,
        weekdays: weekdays ?? current.weekdays,
        startMinute: startMinute ?? current.startMinute,
        endMinute: endMinute ?? current.endMinute,
        blockMinutes: blockMinutes ?? current.blockMinutes,
        breakMinutes: breakMinutes ?? current.breakMinutes,
        avoid: avoid ?? current.avoid,
      );
      _dirty = true;
      _error = null;
      _notice = null;
    });
  }

  bool get _canEdit =>
      !_loading && !_saving && !_needsReload && _preferences != null;

  String? _validationError(AgentPlanningPreferences preferences) {
    if (preferences.weekdays.any((day) => day < 1 || day > 7) ||
        preferences.weekdays.toSet().length != preferences.weekdays.length) {
      return '请选择有效的星期。';
    }
    if (preferences.startMinute < 0 ||
        preferences.startMinute >= 1440 ||
        preferences.endMinute < 0 ||
        preferences.endMinute >= 1440 ||
        preferences.startMinute >= preferences.endMinute) {
      return '可安排时间须在同一天内，且结束时间晚于开始时间。';
    }
    if (preferences.blockMinutes <= 0 ||
        preferences.blockMinutes > 1440 ||
        preferences.breakMinutes < 0 ||
        preferences.breakMinutes > 1440) {
      return '学习块和休息间隔请使用有效时长。';
    }
    if (preferences.avoid.any(
      (range) =>
          range.$1 < 0 ||
          range.$1 >= 1440 ||
          range.$2 < 0 ||
          range.$2 >= 1440 ||
          range.$1 >= range.$2,
    )) {
      return '每日避开时段须有效，且结束时间晚于开始时间。';
    }
    return null;
  }

  String _clock(int minute) {
    if (minute < 0 || minute >= 1440) return '时间无效';
    final hour = (minute ~/ 60).toString().padLeft(2, '0');
    final rest = (minute % 60).toString().padLeft(2, '0');
    return '$hour:$rest';
  }

  Future<TimeOfDay?> _pickTime(int minute, String helpText) => showTimePicker(
    context: context,
    initialTime: TimeOfDay(
      hour: minute >= 0 && minute < 1440 ? minute ~/ 60 : 8,
      minute: minute >= 0 && minute < 1440 ? minute % 60 : 0,
    ),
    helpText: helpText,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
      child: child ?? const SizedBox.shrink(),
    ),
  );

  Future<void> _editTime({required bool start}) async {
    final preferences = _preferences;
    if (preferences == null || !_canEdit) return;
    final picked = await _pickTime(
      start ? preferences.startMinute : preferences.endMinute,
      start ? '选择可安排开始时间' : '选择可安排结束时间',
    );
    if (!mounted || picked == null) return;
    final minute = picked.hour * 60 + picked.minute;
    if (start) {
      _change(startMinute: minute);
    } else {
      _change(endMinute: minute);
    }
  }

  Future<void> _addAvoidRange() async {
    final preferences = _preferences;
    if (preferences == null || !_canEdit) return;
    final start = await _pickTime(12 * 60, '选择避开时段的开始时间');
    if (!mounted || start == null) return;
    final end = await _pickTime(
      start.hour * 60 + start.minute + 60,
      '选择避开时段的结束时间',
    );
    if (!mounted || end == null) return;
    final startMinute = start.hour * 60 + start.minute;
    final endMinute = end.hour * 60 + end.minute;
    if (endMinute <= startMinute) {
      setState(() => _error = '避开时段的结束时间须晚于开始时间。');
      return;
    }
    _change(avoid: [...preferences.avoid, (startMinute, endMinute)]);
  }

  Future<void> _save() async {
    final preferences = _preferences;
    if (preferences == null || !_canEdit || !_dirty) return;
    final validationError = _validationError(preferences);
    if (validationError != null) {
      setState(() => _error = validationError);
      return;
    }
    final port = widget.port;
    final generation = ++_generation;
    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
    });
    try {
      await port.savePlanningPreferences(preferences);
      if (!_isCurrent(port, generation)) return;
      try {
        final saved = await port.readPlanningPreferences();
        if (_isCurrent(port, generation)) {
          setState(() {
            _preferences = saved;
            _dirty = false;
            _needsReload = false;
            _notice = '时间规划偏好已保存。';
          });
        }
      } on Object {
        if (_isCurrent(port, generation)) {
          setState(() {
            _dirty = false;
            _needsReload = true;
            _error = '保存请求已完成，但无法读取新版本；请重新读取后继续编辑。';
          });
        }
      }
    } on Object {
      if (_isCurrent(port, generation)) {
        setState(() => _error = '无法确认偏好已保存，请检查当前设置后重试。');
      }
    } finally {
      if (_isCurrent(port, generation)) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preferences = _preferences;
    final validationError = preferences == null
        ? null
        : _validationError(preferences);
    final canEdit = _canEdit;
    return Column(
      key: const ValueKey('agent-planning-preferences-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '这些条件只在你主动保存后用于规划。',
          style: TextStyle(color: _settingsMuted),
        ),
        if (_loading) ...[
          const SizedBox(height: 8),
          const LinearProgressIndicator(),
          const SizedBox(height: 4),
          const Text('正在读取当前偏好…', style: TextStyle(color: _settingsMuted)),
        ],
        if (preferences != null) ...[
          const SizedBox(height: 12),
          const Text('可安排星期', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 4,
            runSpacing: 2,
            children: [
              for (var day = 1; day <= 7; day++)
                FilterChip(
                  key: ValueKey('agent-planning-weekday-$day'),
                  label: Text(_weekdayLabel(day)),
                  selected: preferences.weekdays.contains(day),
                  onSelected: canEdit
                      ? (selected) {
                          final weekdays = {...preferences.weekdays};
                          if (selected) {
                            weekdays.add(day);
                          } else {
                            weekdays.remove(day);
                          }
                          _change(weekdays: weekdays.toList()..sort());
                        }
                      : null,
                ),
            ],
          ),
          const SizedBox(height: 8),
          const Text('每日可安排时间', style: TextStyle(fontWeight: FontWeight.w600)),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('agent-planning-start-time'),
                onPressed: canEdit ? () => _editTime(start: true) : null,
                icon: const Icon(Icons.schedule_rounded, size: 17),
                label: Text('开始 ${_clock(preferences.startMinute)}'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('agent-planning-end-time'),
                onPressed: canEdit ? () => _editTime(start: false) : null,
                icon: const Icon(Icons.schedule_rounded, size: 17),
                label: Text('结束 ${_clock(preferences.endMinute)}'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<int>(
            key: const ValueKey('agent-planning-block-minutes'),
            initialValue: preferences.blockMinutes,
            decoration: const InputDecoration(labelText: '每个学习块'),
            items: _durationOptions(preferences.blockMinutes)
                .map(
                  (minutes) => DropdownMenuItem(
                    value: minutes,
                    child: Text('$minutes 分钟'),
                  ),
                )
                .toList(),
            onChanged: canEdit
                ? (value) {
                    if (value != null) _change(blockMinutes: value);
                  }
                : null,
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<int>(
            key: const ValueKey('agent-planning-break-minutes'),
            initialValue: preferences.breakMinutes,
            decoration: const InputDecoration(labelText: '学习块之间休息'),
            items:
                _durationOptions(
                      preferences.breakMinutes,
                      options: const [0, 5, 10, 15, 20, 30],
                    )
                    .map(
                      (minutes) => DropdownMenuItem(
                        value: minutes,
                        child: Text('$minutes 分钟'),
                      ),
                    )
                    .toList(),
            onChanged: canEdit
                ? (value) {
                    if (value != null) _change(breakMinutes: value);
                  }
                : null,
          ),
          const SizedBox(height: 10),
          const Text('每日避开时段', style: TextStyle(fontWeight: FontWeight.w600)),
          for (var index = 0; index < preferences.avoid.length; index++)
            Row(
              key: ValueKey('agent-planning-avoid-$index'),
              children: [
                Expanded(
                  child: Text(
                    '${_clock(preferences.avoid[index].$1)}–'
                    '${_clock(preferences.avoid[index].$2)}',
                  ),
                ),
                IconButton(
                  key: ValueKey('agent-planning-avoid-remove-$index'),
                  tooltip: '移除此时段',
                  onPressed: canEdit
                      ? () {
                          final avoid = [...preferences.avoid]..removeAt(index);
                          _change(avoid: avoid);
                        }
                      : null,
                  icon: const Icon(Icons.remove_circle_outline_rounded),
                ),
              ],
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('agent-planning-add-avoid'),
              onPressed: canEdit ? _addAvoidRange : null,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('添加避开时段'),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            key: const ValueKey('agent-planning-error'),
            style: const TextStyle(color: Color(0xFF9B2C2C)),
          ),
        ],
        if (_notice != null) ...[
          const SizedBox(height: 8),
          Text(
            _notice!,
            key: const ValueKey('agent-planning-notice'),
            style: const TextStyle(color: _settingsGreen),
          ),
        ],
        if (validationError != null && _error == null) ...[
          const SizedBox(height: 8),
          Text(
            validationError,
            key: const ValueKey('agent-planning-validation'),
            style: const TextStyle(color: Color(0xFF805500)),
          ),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            if (_error != null || preferences == null)
              OutlinedButton.icon(
                key: const ValueKey('agent-planning-reload'),
                onPressed: _loading || _saving ? null : _reload,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重新读取'),
              ),
            FilledButton.icon(
              key: const ValueKey('agent-planning-save'),
              onPressed: canEdit && _dirty && validationError == null
                  ? _save
                  : null,
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: const Text('保存偏好'),
            ),
          ],
        ),
      ],
    );
  }
}

String _weekdayLabel(int day) => switch (day) {
  1 => '周一',
  2 => '周二',
  3 => '周三',
  4 => '周四',
  5 => '周五',
  6 => '周六',
  7 => '周日',
  _ => '未知',
};

List<int> _durationOptions(
  int current, {
  List<int> options = const [15, 25, 30, 45, 60, 90, 120, 180],
}) => ({...options, current}.toList()..sort());

final class _CapabilityChip extends StatelessWidget {
  const _CapabilityChip({required this.label, required this.enabled});

  final String label;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Chip(
    avatar: Icon(
      enabled ? Icons.check_circle_outline : Icons.remove_circle_outline,
      size: 17,
      color: enabled ? _settingsGreen : _settingsMuted,
    ),
    label: Text('$label ${enabled ? '已验证' : '未验证'}'),
  );
}

final class _PhaseNotice extends StatelessWidget {
  const _PhaseNotice({required this.phase});

  final AgentPhase phase;

  @override
  Widget build(BuildContext context) => Text(
    _phaseText(phase),
    key: const ValueKey('agent-settings-phase'),
    style: const TextStyle(color: _settingsMuted),
  );
}

final class _SettingsNotice extends StatelessWidget {
  const _SettingsNotice({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('agent-settings-notice'),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: isError ? const Color(0xFFFFF0F0) : const Color(0xFFEAF3ED),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(message, style: const TextStyle(height: 1.4)),
  );
}

String _phaseText(AgentPhase phase) => switch (phase) {
  AgentPhase.idle => '空闲',
  AgentPhase.loadingModels => '正在获取模型列表…',
  AgentPhase.verifying => '正在验证模型并保存设置…',
  AgentPhase.generating => '正在生成回复…',
  AgentPhase.executingRead => '正在查询资料…',
  AgentPhase.waitingForApproval => '等待你批准方案…',
  AgentPhase.waitingForSchool => '等待你在学校页面继续…',
  AgentPhase.committing => '正在提交本地修改…',
  AgentPhase.settling => '正在保存回复…',
  AgentPhase.recovery => '正在恢复本地状态…',
  AgentPhase.maintenance => '本地维护中…',
  AgentPhase.closed => 'Agent 服务已关闭。',
};

String _failureText(AgentFailureCode code) => switch (code) {
  AgentFailureCode.invalidInput => '输入不符合要求，请检查后重试。',
  AgentFailureCode.imageRejected => '模型拒绝了附图；请换用支持图片输入的模型后重试。',
  AgentFailureCode.secretDetected => '输入包含受保护内容，请移除后重试。',
  AgentFailureCode.consentRequired => '请先阅读发送说明并明确勾选同意。',
  AgentFailureCode.keyRequired => '请提供模型 Key，或使用本机已保存的 Key。',
  AgentFailureCode.modelRequired => '请先获取并选择有效模型。',
  AgentFailureCode.busy => 'Agent 正在处理其他操作，请稍后重试。',
  AgentFailureCode.staleContext => '设置状态已变化，请刷新后重试。',
  AgentFailureCode.maintenance => '本地维护正在进行，请稍后重试。',
  AgentFailureCode.ownershipLost => '本机数据状态已变化，请重新打开设置。',
  AgentFailureCode.storageFailed => '本机设置保存失败，请稍后重试。',
  AgentFailureCode.protectionFailed => '本机密钥保护未完成，设置没有保存。',
  AgentFailureCode.unauthorized ||
  AgentFailureCode.forbidden => '模型服务未授权此请求，请检查 Key 或服务权限。',
  AgentFailureCode.rateLimited => '模型服务暂时繁忙，请稍后重试。',
  AgentFailureCode.networkFailed ||
  AgentFailureCode.timeout => '暂时无法连接模型服务，请检查网络后重试。',
  AgentFailureCode.protocol ||
  AgentFailureCode.redirectRejected => '模型服务返回内容无法安全验证。',
  AgentFailureCode.resourceLimit => '模型列表或回复超出当前处理上限。',
  AgentFailureCode.cancelled => '操作已取消。',
  AgentFailureCode.closed => 'Agent 服务已关闭，请重新打开页面。',
  AgentFailureCode.toolUnavailable => '请求的工具不在本次可用范围内，已停止本次处理。',
};
