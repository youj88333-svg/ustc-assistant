import 'package:flutter/material.dart';

import '../core/calendar_contract.dart';

const _editorMuted = Color(0xFF66736C);
const _defaultDeadlineTime = '23:59';

Future<DateTime?> _chooseBeijingDate(
  BuildContext context,
  DateTime initialDate,
) => showDatePicker(
  context: context,
  initialDate: DateTime(initialDate.year, initialDate.month, initialDate.day),
  firstDate: DateTime(1, 1, 1),
  lastDate: DateTime(9999, 12, 31),
  initialEntryMode: DatePickerEntryMode.calendar,
);

Future<TimeOfDay?> _chooseBeijingTime(
  BuildContext context,
  TimeOfDay initialTime,
) => showTimePicker(
  context: context,
  initialTime: initialTime,
  initialEntryMode: TimePickerEntryMode.dial,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
    child: child ?? const SizedBox.shrink(),
  ),
);

Future<TaskDraft?> showTaskEditor(
  BuildContext context, {
  required String heading,
  required DateTime today,
  TaskDraft? initial,
}) => showDialog<TaskDraft>(
  context: context,
  builder: (context) =>
      _TaskEditorDialog(heading: heading, today: today, initial: initial),
);

Future<PlanBlockDraft?> showPlanBlockEditor(
  BuildContext context, {
  required String heading,
  required DateTime today,
  PlanBlockDraft? initial,
}) => showDialog<PlanBlockDraft>(
  context: context,
  builder: (context) =>
      _PlanBlockEditorDialog(heading: heading, today: today, initial: initial),
);

final class _TaskEditorDialog extends StatefulWidget {
  const _TaskEditorDialog({
    required this.heading,
    required this.today,
    this.initial,
  });

  final String heading;
  final DateTime today;
  final TaskDraft? initial;

  @override
  State<_TaskEditorDialog> createState() => _TaskEditorDialogState();
}

final class _TaskEditorDialogState extends State<_TaskEditorDialog> {
  late final TextEditingController _title;
  late final TextEditingController _description;
  late final TextEditingController _note;
  late final TextEditingController _deadlineDay;
  late final TextEditingController _deadlineTime;
  late final TextEditingController _estimate;
  late bool _hasDeadline;
  late TaskPriority _priority;
  String? _message;

  @override
  void initState() {
    super.initState();
    final draft = widget.initial;
    final deadline = draft?.deadlineAtUtc;
    final beijingDeadline = deadline?.toUtc().add(const Duration(hours: 8));
    _title = TextEditingController(text: draft?.title ?? '');
    _description = TextEditingController(text: draft?.description ?? '');
    _note = TextEditingController(text: draft?.note ?? '');
    _deadlineDay = TextEditingController(
      text: beijingDeadline == null ? '' : _dateText(beijingDeadline),
    );
    _deadlineTime = TextEditingController(
      text: beijingDeadline == null
          ? _defaultDeadlineTime
          : _clockText(beijingDeadline),
    );
    _estimate = TextEditingController(
      text: draft?.estimatedMinutes?.toString() ?? '',
    );
    _hasDeadline = deadline != null;
    _priority = draft?.priority ?? TaskPriority.normal;
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _note.dispose();
    _deadlineDay.dispose();
    _deadlineTime.dispose();
    _estimate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 620,
        maxHeight: _dialogAvailableHeight(context),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 8),
              child: Text(
                widget.heading,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 8, 22, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const ValueKey('task-editor-title'),
                    controller: _title,
                    autofocus: true,
                    maxLength: 200,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: '任务标题',
                      hintText: '例如：完成实验报告',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    key: const ValueKey('task-editor-description'),
                    controller: _description,
                    maxLength: 4000,
                    minLines: 2,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      labelText: '描述（可选）',
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    key: const ValueKey('task-editor-note'),
                    controller: _note,
                    maxLength: 4000,
                    minLines: 2,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      labelText: '备注（可选）',
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<TaskPriority>(
                    key: const ValueKey('task-editor-priority'),
                    initialValue: _priority,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '优先级'),
                    items: const [
                      DropdownMenuItem(
                        value: TaskPriority.low,
                        child: Text('低'),
                      ),
                      DropdownMenuItem(
                        value: TaskPriority.normal,
                        child: Text('普通'),
                      ),
                      DropdownMenuItem(
                        value: TaskPriority.high,
                        child: Text('高'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => _priority = value);
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('task-editor-estimate'),
                    controller: _estimate,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '预计用时（分钟，可选）',
                      hintText: '1–527040',
                    ),
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    key: const ValueKey('task-editor-has-deadline'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _hasDeadline,
                    title: const Text('设置截止时间'),
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: (value) {
                      setState(() {
                        _hasDeadline = value ?? false;
                        if (!_hasDeadline) {
                          _deadlineDay.clear();
                          _deadlineTime.text = _defaultDeadlineTime;
                        } else if (_deadlineDay.text.trim().isEmpty) {
                          _deadlineDay.text = _dateText(widget.today);
                          _deadlineTime.text = _defaultDeadlineTime;
                        }
                      });
                    },
                  ),
                  if (_hasDeadline) ...[
                    Text(
                      '按北京时间选择日期和时间；未另选时，截止时间为当天 23:59。',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: _editorMuted),
                    ),
                    const SizedBox(height: 6),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final fields = [
                          TextField(
                            key: const ValueKey('task-editor-deadline-day'),
                            controller: _deadlineDay,
                            readOnly: true,
                            onTap: _pickDeadlineDay,
                            decoration: InputDecoration(
                              labelText: '截止日期',
                              hintText: '选择日期',
                              suffixIcon: IconButton(
                                key: const ValueKey(
                                  'task-editor-deadline-day-picker',
                                ),
                                tooltip: '选择截止日期',
                                onPressed: _pickDeadlineDay,
                                icon: const Icon(Icons.calendar_month_rounded),
                              ),
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              TextField(
                                key: const ValueKey(
                                  'task-editor-deadline-time',
                                ),
                                controller: _deadlineTime,
                                readOnly: true,
                                onTap: _pickDeadlineTime,
                                decoration: InputDecoration(
                                  labelText: '截止时间（北京时间）',
                                  suffixIcon: IconButton(
                                    key: const ValueKey(
                                      'task-editor-deadline-time-picker',
                                    ),
                                    tooltip: '选择截止时间',
                                    onPressed: _pickDeadlineTime,
                                    icon: const Icon(Icons.schedule_rounded),
                                  ),
                                ),
                              ),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton.icon(
                                  key: const ValueKey(
                                    'task-editor-deadline-time-clear',
                                  ),
                                  onPressed: () => setState(
                                    () => _deadlineTime.text =
                                        _defaultDeadlineTime,
                                  ),
                                  icon: const Icon(
                                    Icons.restart_alt_rounded,
                                    size: 17,
                                  ),
                                  label: const Text('恢复默认 23:59'),
                                ),
                              ),
                            ],
                          ),
                        ];
                        if (constraints.maxWidth < 430) {
                          return Column(
                            children: [
                              fields[0],
                              const SizedBox(height: 8),
                              fields[1],
                            ],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: fields[0]),
                            const SizedBox(width: 10),
                            Expanded(child: fields[1]),
                          ],
                        );
                      },
                    ),
                  ],
                  if (_message != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _message!,
                      key: const ValueKey('task-editor-error'),
                      style: const TextStyle(color: Color(0xFF9B2C2C)),
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 6,
                children: [
                  TextButton(
                    key: const ValueKey('task-editor-cancel'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  FilledButton.icon(
                    key: const ValueKey('task-editor-save'),
                    onPressed: _save,
                    icon: const Icon(Icons.save_outlined, size: 18),
                    label: const Text('保存任务'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(64, 48),
                      tapTargetSize: MaterialTapTargetSize.padded,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty || title.length > 200) {
      setState(() => _message = '标题需填写 1–200 个字符。');
      return;
    }
    if (_description.text.length > 4000 || _note.text.length > 4000) {
      setState(() => _message = '描述和备注各最多 4000 个字符。');
      return;
    }
    final estimateText = _estimate.text.trim();
    final estimate = estimateText.isEmpty ? null : int.tryParse(estimateText);
    if (estimateText.isNotEmpty &&
        (estimate == null || estimate < 1 || estimate > 527040)) {
      setState(() => _message = '预计用时须为 1–527040 分钟，或留空。');
      return;
    }
    DateTime? deadline;
    if (_hasDeadline) {
      final day = _parseDate(_deadlineDay.text.trim());
      if (day == null) {
        setState(() => _message = '请选择有效的截止日期。');
        return;
      }
      final clock = _parseClock(_deadlineTime.text.trim());
      if (clock == null) {
        setState(() => _message = '请选择有效的截止时间。');
        return;
      }
      deadline = _beijingToUtc(day, clock.hour, clock.minute);
    }
    Navigator.of(context).pop(
      TaskDraft(
        title: title,
        description: _description.text,
        note: _note.text,
        deadlineAtUtc: deadline,
        estimatedMinutes: estimate,
        priority: _priority,
      ),
    );
  }

  Future<void> _pickDeadlineDay() async {
    final current = _parseDate(_deadlineDay.text.trim()) ?? widget.today;
    final picked = await _chooseBeijingDate(context, current);
    if (!mounted || picked == null) return;
    setState(() => _deadlineDay.text = _dateText(picked));
  }

  Future<void> _pickDeadlineTime() async {
    final current =
        _parseClock(_deadlineTime.text.trim()) ?? (hour: 23, minute: 59);
    final picked = await _chooseBeijingTime(
      context,
      TimeOfDay(hour: current.hour, minute: current.minute),
    );
    if (!mounted || picked == null) return;
    setState(() => _deadlineTime.text = _clockTextFromTime(picked));
  }
}

final class _PlanBlockEditorDialog extends StatefulWidget {
  const _PlanBlockEditorDialog({
    required this.heading,
    required this.today,
    this.initial,
  });

  final String heading;
  final DateTime today;
  final PlanBlockDraft? initial;

  @override
  State<_PlanBlockEditorDialog> createState() => _PlanBlockEditorDialogState();
}

final class _PlanBlockEditorDialogState extends State<_PlanBlockEditorDialog> {
  late final TextEditingController _startDay;
  late final TextEditingController _startTime;
  late final TextEditingController _endDay;
  late final TextEditingController _endTime;
  late final TextEditingController _location;
  late final TextEditingController _note;
  String? _message;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    final startsAt = initial?.startsAtUtc.toUtc().add(const Duration(hours: 8));
    final endsAt = initial?.endsAtUtc.toUtc().add(const Duration(hours: 8));
    final defaultDay = _dateText(widget.today);
    _startDay = TextEditingController(
      text: startsAt == null ? defaultDay : _dateText(startsAt),
    );
    _startTime = TextEditingController(
      text: startsAt == null ? '09:00' : _clockText(startsAt),
    );
    _endDay = TextEditingController(
      text: endsAt == null ? defaultDay : _dateText(endsAt),
    );
    _endTime = TextEditingController(
      text: endsAt == null ? '10:00' : _clockText(endsAt),
    );
    _location = TextEditingController(text: initial?.location ?? '');
    _note = TextEditingController(text: initial?.note ?? '');
  }

  @override
  void dispose() {
    _startDay.dispose();
    _startTime.dispose();
    _endDay.dispose();
    _endTime.dispose();
    _location.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 580,
        maxHeight: _dialogAvailableHeight(context),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 8),
              child: Text(
                widget.heading,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 8, 22, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '按北京时间选择日期和 24 小时时间。计划时间只安排进度，不会自动改变任务或时间块状态。',
                    style: TextStyle(color: _editorMuted, height: 1.4),
                  ),
                  const SizedBox(height: 12),
                  _dateTimeFields(
                    context,
                    label: '开始',
                    date: _startDay,
                    time: _startTime,
                    dateKey: 'plan-block-start-day',
                    timeKey: 'plan-block-start-time',
                  ),
                  const SizedBox(height: 12),
                  _dateTimeFields(
                    context,
                    label: '结束',
                    date: _endDay,
                    time: _endTime,
                    dateKey: 'plan-block-end-day',
                    timeKey: 'plan-block-end-time',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('plan-block-location'),
                    controller: _location,
                    maxLength: 200,
                    decoration: const InputDecoration(labelText: '地点（可选）'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    key: const ValueKey('plan-block-note'),
                    controller: _note,
                    maxLength: 4000,
                    minLines: 2,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      labelText: '备注（可选）',
                      alignLabelWithHint: true,
                    ),
                  ),
                  if (_message != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _message!,
                      key: const ValueKey('plan-block-editor-error'),
                      style: const TextStyle(color: Color(0xFF9B2C2C)),
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 6,
                children: [
                  TextButton(
                    key: const ValueKey('plan-block-editor-cancel'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  FilledButton.icon(
                    key: const ValueKey('plan-block-editor-save'),
                    onPressed: _save,
                    icon: const Icon(Icons.save_outlined, size: 18),
                    label: const Text('保存时间块'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(64, 48),
                      tapTargetSize: MaterialTapTargetSize.padded,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _dateTimeFields(
    BuildContext context, {
    required String label,
    required TextEditingController date,
    required TextEditingController time,
    required String dateKey,
    required String timeKey,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      final fields = [
        TextField(
          key: ValueKey(dateKey),
          controller: date,
          readOnly: true,
          onTap: () => _pickPlanBlockDate(date),
          decoration: InputDecoration(
            labelText: '$label日期（北京时间）',
            hintText: '选择日期',
            suffixIcon: IconButton(
              key: ValueKey('$dateKey-picker'),
              tooltip: '选择$label日期',
              onPressed: () => _pickPlanBlockDate(date),
              icon: const Icon(Icons.calendar_month_rounded),
            ),
          ),
        ),
        TextField(
          key: ValueKey(timeKey),
          controller: time,
          readOnly: true,
          onTap: () => _pickPlanBlockTime(time),
          decoration: InputDecoration(
            labelText: '$label时间（24 小时制）',
            hintText: '选择时间',
            suffixIcon: IconButton(
              key: ValueKey('$timeKey-picker'),
              tooltip: '选择$label时间',
              onPressed: () => _pickPlanBlockTime(time),
              icon: const Icon(Icons.schedule_rounded),
            ),
          ),
        ),
      ];
      if (constraints.maxWidth < 430) {
        return Column(
          children: [fields[0], const SizedBox(height: 8), fields[1]],
        );
      }
      return Row(
        children: [
          Expanded(child: fields[0]),
          const SizedBox(width: 10),
          Expanded(child: fields[1]),
        ],
      );
    },
  );

  Future<void> _pickPlanBlockDate(TextEditingController controller) async {
    final current = _parseDate(controller.text.trim()) ?? widget.today;
    final picked = await _chooseBeijingDate(context, current);
    if (!mounted || picked == null) return;
    setState(() => controller.text = _dateText(picked));
  }

  Future<void> _pickPlanBlockTime(TextEditingController controller) async {
    final current = _parseClock(controller.text.trim()) ?? (hour: 9, minute: 0);
    final picked = await _chooseBeijingTime(
      context,
      TimeOfDay(hour: current.hour, minute: current.minute),
    );
    if (!mounted || picked == null) return;
    setState(() => controller.text = _clockTextFromTime(picked));
  }

  void _save() {
    final startDay = _parseDate(_startDay.text.trim());
    final startClock = _parseClock(_startTime.text.trim());
    final endDay = _parseDate(_endDay.text.trim());
    final endClock = _parseClock(_endTime.text.trim());
    if (startDay == null || endDay == null) {
      setState(() => _message = '请选择有效的开始和结束日期。');
      return;
    }
    if (startClock == null || endClock == null) {
      setState(() => _message = '请选择有效的开始和结束时间。');
      return;
    }
    if (_location.text.length > 200 || _note.text.length > 4000) {
      setState(() => _message = '地点最多 200 个字符，备注最多 4000 个字符。');
      return;
    }
    final start = _beijingToUtc(startDay, startClock.hour, startClock.minute);
    final end = _beijingToUtc(endDay, endClock.hour, endClock.minute);
    final duration = end.difference(start);
    if (duration <= Duration.zero) {
      setState(() => _message = '结束时间必须晚于开始时间。');
      return;
    }
    if (duration > const Duration(days: 366)) {
      setState(() => _message = '单个时间块最长为 366 天。');
      return;
    }
    Navigator.of(context).pop(
      PlanBlockDraft(
        startsAtUtc: start,
        endsAtUtc: end,
        location: _location.text,
        note: _note.text,
      ),
    );
  }
}

double _dialogAvailableHeight(BuildContext context) {
  final media = MediaQuery.of(context);
  final available = media.size.height - media.viewInsets.vertical - 24;
  return available.clamp(0.0, media.size.height * .94).toDouble();
}

DateTime? _parseDate(String value) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
  if (match == null) return null;
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final parsed = DateTime.utc(year, month, day);
  if (parsed.year != year || parsed.month != month || parsed.day != day) {
    return null;
  }
  return parsed;
}

({int hour, int minute})? _parseClock(String value) {
  final match = RegExp(r'^(\d{2}):(\d{2})$').firstMatch(value);
  if (match == null) return null;
  final hour = int.parse(match[1]!);
  final minute = int.parse(match[2]!);
  if (hour > 23 || minute > 59) return null;
  return (hour: hour, minute: minute);
}

DateTime _beijingToUtc(DateTime day, int hour, int minute) => DateTime.utc(
  day.year,
  day.month,
  day.day,
  hour,
  minute,
).subtract(const Duration(hours: 8));

String _dateText(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

String _clockText(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}';

String _clockTextFromTime(TimeOfDay value) =>
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}';
