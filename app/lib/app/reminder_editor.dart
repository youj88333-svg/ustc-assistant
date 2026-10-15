import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/reminder_contract.dart';

/// Opens the per-object reminder editor. A null pair means “inherit defaults”.
Future<void> showReminderEditor(
  BuildContext context, {
  required ReminderDataPort data,
  required ReminderTarget target,
  required bool allDay,
  bool supportsSeries = false,
}) async {
  await showDialog<bool>(
    context: context,
    builder: (context) => _ReminderEditorDialog(
      data: data,
      target: target,
      allDay: allDay,
      supportsSeries: supportsSeries,
    ),
  );
}

final class _ReminderEditorDialog extends StatefulWidget {
  const _ReminderEditorDialog({
    required this.data,
    required this.target,
    required this.allDay,
    required this.supportsSeries,
  });

  final ReminderDataPort data;
  final ReminderTarget target;
  final bool allDay, supportsSeries;

  @override
  State<_ReminderEditorDialog> createState() => _ReminderEditorDialogState();
}

final class _ReminderEditorDialogState extends State<_ReminderEditorDialog> {
  late bool _allDay = widget.allDay;
  late ReminderPair _pair = _defaults;
  bool _inherited = true;
  bool _series = false;
  bool _loading = true;
  bool _readFailed = false;
  bool _saving = false;
  String? _message;
  int _operation = 0;

  ReminderPair get _defaults =>
      _allDay ? ReminderPair.allDay : ReminderPair.timed;

  bool get _canChooseSeries =>
      widget.supportsSeries && widget.target.kind == ReminderKind.personal;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _operation++;
    super.dispose();
  }

  bool _isCurrent(int operation) => mounted && _operation == operation;

  Future<void> _reload() async {
    final operation = ++_operation;
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final shape = widget.data;
      final allDay = shape is ReminderTargetShapePort
          ? await (shape as ReminderTargetShapePort).reminderAllDay(
              widget.target,
              series: _series,
            )
          : widget.allDay;
      if (!_isCurrent(operation)) return;
      final pair = await widget.data.readReminderPair(
        widget.target,
        series: _series,
      );
      if (!_isCurrent(operation)) return;
      final inheritedPair = pair == null
          ? await widget.data.inspectReminders().then(
              (settings) => allDay
                  ? settings.preferences.allDay
                  : settings.preferences.timed,
            )
          : null;
      if (!_isCurrent(operation)) return;
      pair?.validate(allDay: allDay);
      inheritedPair?.validate(allDay: allDay);
      setState(() {
        _allDay = allDay;
        _inherited = pair == null;
        _pair = pair ?? inheritedPair ?? _defaults;
        _loading = false;
        _readFailed = false;
      });
    } on Object {
      if (!_isCurrent(operation)) return;
      setState(() {
        _loading = false;
        _readFailed = true;
        _message = '无法读取提醒设置，请稍后重试。';
      });
    }
  }

  Future<void> _chooseScope(bool series) async {
    if (!_canChooseSeries || _saving || _loading || series == _series) return;
    setState(() {
      _series = series;
      _loading = true;
      _message = null;
    });
    await _reload();
  }

  Future<void> _save({bool restoreDefault = false}) async {
    if (_saving || _loading || _readFailed) return;
    final pair = restoreDefault || _inherited ? null : _pair;
    try {
      pair?.validate(allDay: _allDay);
    } on ReminderFailure {
      setState(() => _message = '提醒规则无效，请检查后重试。');
      return;
    }
    final operation = ++_operation;
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      await widget.data.saveReminderPair(widget.target, pair, series: _series);
      if (!_isCurrent(operation) || !mounted) return;
      Navigator.of(context).pop(true);
    } on Object {
      if (_isCurrent(operation)) {
        setState(() {
          _saving = false;
          _message = '保存提醒设置失败，请重试。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('提醒设置'),
    content: SizedBox(
      width: 440,
      child: _loading
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            )
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_canChooseSeries) ...[
                    SegmentedButton<bool>(
                      key: const ValueKey('reminder-editor-scope'),
                      segments: const [
                        ButtonSegment(value: false, label: Text('仅本次')),
                        ButtonSegment(value: true, label: Text('整个系列')),
                      ],
                      selected: {_series},
                      onSelectionChanged: _saving
                          ? null
                          : (selection) => _chooseScope(selection.first),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Text(
                    _inherited ? '当前继承全局默认提醒。' : '此对象使用单独的提醒设置。',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  ReminderPairControls(
                    pair: _pair,
                    allDay: _allDay,
                    enabled: !_saving && !_readFailed,
                    keyPrefix: 'reminder-editor',
                    onChanged: (pair) => setState(() {
                      _pair = pair;
                      _inherited = false;
                      _message = null;
                    }),
                  ),
                  if (_readFailed) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        key: const ValueKey('reminder-editor-retry-read'),
                        onPressed: _saving ? null : _reload,
                        child: const Text('重试读取'),
                      ),
                    ),
                  ],
                  if (_message != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _message!,
                      key: const ValueKey('reminder-editor-error'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
    ),
    actions: [
      TextButton(
        key: const ValueKey('reminder-editor-restore-default'),
        onPressed: _saving || _loading || _readFailed
            ? null
            : () => _save(restoreDefault: true),
        child: const Text('恢复默认'),
      ),
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).pop(false),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('reminder-editor-save'),
        onPressed: _saving || _loading || _readFailed ? null : _save,
        child: Text(_saving ? '正在保存…' : '保存'),
      ),
    ],
  );
}

/// Two bounded reminder slots shared by the object editor and global settings.
final class ReminderPairControls extends StatelessWidget {
  const ReminderPairControls({
    super.key,
    required this.pair,
    required this.allDay,
    required this.enabled,
    required this.onChanged,
    this.keyPrefix = 'reminder-pair',
  });

  final ReminderPair pair;
  final bool allDay, enabled;
  final ValueChanged<ReminderPair> onChanged;
  final String keyPrefix;

  static const _timedChoices = <int>[0, 5, 10, 15, 30, 60, 1440];

  ReminderRule _ruleAt(int index) => index == 0 ? pair.first : pair.second;

  void _replace(int index, ReminderRule rule) {
    onChanged(
      index == 0
          ? ReminderPair(rule, pair.second)
          : ReminderPair(pair.first, rule),
    );
  }

  String _slotLabel(int index) => index == 0 ? '第一次提醒' : '第二次提醒';

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _slot(context, 0),
      const SizedBox(height: 16),
      _slot(context, 1),
    ],
  );

  Widget _slot(BuildContext context, int index) {
    final rule = _ruleAt(index);
    final key = '$keyPrefix-slot-${index + 1}';
    final label = _slotLabel(index);
    final kinds = allDay
        ? const [ReminderRuleKind.none, ReminderRuleKind.dayTime]
        : const [ReminderRuleKind.none, ReminderRuleKind.before];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExcludeSemantics(
          child: Text(
            label,
            key: ValueKey('$key-label'),
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        const SizedBox(height: 8),
        Semantics(
          label: label,
          child: DropdownButtonFormField<ReminderRuleKind>(
            key: ValueKey('$key-kind-${rule.kind.name}'),
            isExpanded: true,
            itemHeight: null,
            initialValue: rule.kind,
            decoration: const InputDecoration(),
            items: kinds
                .map(
                  (kind) => DropdownMenuItem(
                    value: kind,
                    child: Text(_kindLabel(kind)),
                  ),
                )
                .toList(),
            onChanged: enabled
                ? (kind) {
                    if (kind == null) return;
                    if (kind == ReminderRuleKind.none) {
                      _replace(index, const ReminderRule.none());
                    } else if (kind == ReminderRuleKind.before) {
                      _replace(
                        index,
                        ReminderRule.before(
                          rule.kind == ReminderRuleKind.before
                              ? rule.minutesBefore
                              : 30,
                        ),
                      );
                    } else {
                      _replace(
                        index,
                        ReminderRule.dayTime(
                          dayOffset: rule.kind == ReminderRuleKind.dayTime
                              ? rule.dayOffset
                              : 0,
                          minuteOfDay: rule.kind == ReminderRuleKind.dayTime
                              ? rule.minuteOfDay
                              : 540,
                        ),
                      );
                    }
                  }
                : null,
          ),
        ),
        if (!allDay && rule.kind == ReminderRuleKind.before) ...[
          const SizedBox(height: 8),
          DropdownButtonFormField<int>(
            key: ValueKey('$key-before-${rule.minutesBefore}'),
            isExpanded: true,
            itemHeight: null,
            initialValue: _timedChoices.contains(rule.minutesBefore)
                ? rule.minutesBefore
                : -1,
            decoration: const InputDecoration(labelText: '提前时间'),
            items: [
              ..._timedChoices.map(
                (minutes) => DropdownMenuItem(
                  value: minutes,
                  child: Text(_timedLabel(minutes)),
                ),
              ),
              DropdownMenuItem(
                value: -1,
                child: Text(
                  _timedChoices.contains(rule.minutesBefore)
                      ? '自定义…'
                      : '自定义（${rule.minutesBefore} 分钟）',
                ),
              ),
            ],
            onChanged: enabled
                ? (minutes) async {
                    if (minutes == null) return;
                    if (minutes == -1) {
                      final custom = await _customMinutesDialog(
                        context,
                        rule.minutesBefore,
                      );
                      if (custom != null && context.mounted) {
                        _replace(index, ReminderRule.before(custom));
                      }
                    } else {
                      _replace(index, ReminderRule.before(minutes));
                    }
                  }
                : null,
          ),
        ],
        if (allDay && rule.kind == ReminderRuleKind.dayTime) ...[
          const SizedBox(height: 8),
          DropdownButtonFormField<int>(
            key: ValueKey('$key-offset-${rule.dayOffset}'),
            isExpanded: true,
            itemHeight: null,
            initialValue: rule.dayOffset,
            decoration: const InputDecoration(labelText: '相对日程日期'),
            items: List.generate(15, (i) => i - 7)
                .map(
                  (offset) => DropdownMenuItem(
                    value: offset,
                    child: Text(_dayOffsetLabel(offset)),
                  ),
                )
                .toList(),
            onChanged: enabled
                ? (offset) {
                    if (offset != null) {
                      _replace(
                        index,
                        ReminderRule.dayTime(
                          dayOffset: offset,
                          minuteOfDay: rule.minuteOfDay,
                        ),
                      );
                    }
                  }
                : null,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: ValueKey('$key-time'),
            onPressed: enabled
                ? () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay(
                        hour: rule.minuteOfDay ~/ 60,
                        minute: rule.minuteOfDay % 60,
                      ),
                      helpText: '选择北京时间时刻',
                      builder: (context, child) => MediaQuery(
                        data: MediaQuery.of(
                          context,
                        ).copyWith(alwaysUse24HourFormat: true),
                        child: child ?? const SizedBox.shrink(),
                      ),
                    );
                    if (picked != null && context.mounted) {
                      _replace(
                        index,
                        ReminderRule.dayTime(
                          dayOffset: rule.dayOffset,
                          minuteOfDay: picked.hour * 60 + picked.minute,
                        ),
                      );
                    }
                  }
                : null,
            icon: const Icon(Icons.access_time_rounded),
            label: Text('选择时刻 ${_minuteClock(rule.minuteOfDay)}'),
          ),
        ],
      ],
    );
  }

  static String _kindLabel(ReminderRuleKind kind) => switch (kind) {
    ReminderRuleKind.none => '不提醒',
    ReminderRuleKind.before => '日程开始前',
    ReminderRuleKind.dayTime => '按相对日期和时刻',
  };

  static String _timedLabel(int minutes) => switch (minutes) {
    0 => '日程开始时',
    1440 => '提前 1 天',
    _ => '提前 $minutes 分钟',
  };

  static String _dayOffsetLabel(int offset) => switch (offset) {
    0 => '当天',
    < 0 => '前 ${-offset} 天',
    _ => '后 $offset 天',
  };

  static String _minuteClock(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:'
      '${(minute % 60).toString().padLeft(2, '0')}';

  Future<int?> _customMinutesDialog(BuildContext context, int current) async {
    final controller = TextEditingController(text: '$current');
    String? error;
    final value = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('自定义提前时间'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('reminder-custom-minutes'),
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                maxLength: 5,
                decoration: InputDecoration(
                  labelText: '分钟',
                  helperText: '范围 0–10080 分钟',
                  errorText: error,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('reminder-custom-confirm'),
              onPressed: () {
                final parsed = int.tryParse(controller.text);
                if (parsed == null || parsed < 0 || parsed > 10080) {
                  setDialogState(() => error = '请输入 0–10080 之间的整数。');
                  return;
                }
                Navigator.of(context).pop(parsed);
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return value;
  }
}
