import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;

import '../core/calendar_contract.dart';
import '../core/calendar_validation.dart';

typedef CalendarEventSave = Future<bool> Function(PersonalEventDraft draft);

/// Personal event form. Dates and clocks are entered as Beijing wall time;
/// timed values are converted to UTC before they leave this widget.
final class CalendarEventEditor extends StatefulWidget {
  const CalendarEventEditor({
    super.key,
    required this.initialDraft,
    required this.heading,
    required this.explanation,
    required this.controller,
    required this.feedback,
    required this.allowWeekly,
    required this.canSave,
    required this.isCurrent,
    this.onOverlayChanged,
    required this.onSave,
  });

  final PersonalEventDraft initialDraft;
  final String heading;
  final String explanation;
  final Listenable controller;
  final ValueListenable<String?> feedback;
  final bool allowWeekly;
  final bool Function() canSave;
  final bool Function() isCurrent;
  final ValueChanged<bool>? onOverlayChanged;
  final CalendarEventSave onSave;

  @override
  State<CalendarEventEditor> createState() => _CalendarEventEditorState();
}

final class _CalendarEventEditorState extends State<CalendarEventEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _startDate;
  late final TextEditingController _startTime;
  late final TextEditingController _endDate;
  late final TextEditingController _endTime;
  late final TextEditingController _until;
  late final TextEditingController _location;
  late final TextEditingController _note;
  late bool _allDay;
  late bool _weekly;
  bool _saving = false;
  String? _formMessage;

  @override
  void initState() {
    super.initState();
    final draft = widget.initialDraft;
    final startLocal = draft.allDay
        ? draft.start
        : draft.startsAtUtc.add(const Duration(hours: 8));
    final inclusiveEnd = draft.allDay
        ? draft.end.subtract(const Duration(days: 1))
        : draft.endsAtUtc.add(const Duration(hours: 8));
    _title = TextEditingController(text: draft.title);
    _startDate = TextEditingController(text: _dateText(startLocal));
    _startTime = TextEditingController(
      text: draft.allDay ? '09:00' : _clockText(startLocal),
    );
    _endDate = TextEditingController(text: _dateText(inclusiveEnd));
    _endTime = TextEditingController(
      text: draft.allDay ? '10:00' : _clockText(inclusiveEnd),
    );
    _until = TextEditingController(
      text: draft.untilDay == null ? '' : _dateText(draft.untilDay!),
    );
    _location = TextEditingController(text: draft.location);
    _note = TextEditingController(text: draft.note);
    _allDay = draft.allDay;
    _weekly = draft.weekly;
  }

  @override
  void dispose() {
    _title.dispose();
    _startDate.dispose();
    _startTime.dispose();
    _endDate.dispose();
    _endTime.dispose();
    _until.dispose();
    _location.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: media.size.height * .92),
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 12, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.heading,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('calendar-event-close'),
                        tooltip: '关闭',
                        onPressed: _saving
                            ? null
                            : () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Form(
                    key: _formKey,
                    child: SingleChildScrollView(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            widget.explanation,
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(color: _muted),
                          ),
                          const SizedBox(height: 14),
                          TextFormField(
                            key: const ValueKey('calendar-event-title'),
                            controller: _title,
                            enabled: !_saving,
                            maxLength: 200,
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                              labelText: '标题',
                              hintText: '例如：项目讨论',
                            ),
                            validator: (value) =>
                                value == null || value.trim().isEmpty
                                ? '请填写标题'
                                : value.length > 200
                                ? '标题最多 200 字'
                                : null,
                          ),
                          const SizedBox(height: 6),
                          SwitchListTile(
                            key: const ValueKey('calendar-event-all-day'),
                            contentPadding: EdgeInsets.zero,
                            title: const Text('全天'),
                            subtitle: const Text('按北京时间日期保存'),
                            value: _allDay,
                            onChanged: _saving
                                ? null
                                : (value) => setState(() {
                                    _allDay = value;
                                    _formMessage = null;
                                  }),
                          ),
                          _DateField(
                            controller: _startDate,
                            keyName: 'calendar-event-start-date',
                            label: '开始日期（北京时间 YYYY-MM-DD）',
                            enabled: !_saving,
                            onPick: _pickDate,
                          ),
                          if (!_allDay) ...[
                            const SizedBox(height: 10),
                            _ClockField(
                              controller: _startTime,
                              keyName: 'calendar-event-start-time',
                              enabled: !_saving,
                              onPick: _pickTime,
                            ),
                          ],
                          const SizedBox(height: 10),
                          _DateField(
                            controller: _endDate,
                            keyName: 'calendar-event-end-date',
                            label: '结束日期（含，YYYY-MM-DD）',
                            enabled: !_saving,
                            onPick: _pickDate,
                          ),
                          if (!_allDay) ...[
                            const SizedBox(height: 10),
                            _ClockField(
                              controller: _endTime,
                              keyName: 'calendar-event-end-time',
                              enabled: !_saving,
                              onPick: _pickTime,
                            ),
                          ],
                          const SizedBox(height: 6),
                          if (widget.allowWeekly)
                            SwitchListTile(
                              key: const ValueKey('calendar-event-weekly'),
                              contentPadding: EdgeInsets.zero,
                              title: const Text('每周重复一次'),
                              subtitle: const Text('按开始日期的星期重复'),
                              value: _weekly,
                              onChanged: _saving
                                  ? null
                                  : (value) => setState(() {
                                      _weekly = value;
                                      _formMessage = null;
                                    }),
                            ),
                          if (widget.allowWeekly && _weekly) ...[
                            _DateField(
                              controller: _until,
                              keyName: 'calendar-event-until',
                              label: '重复截止日期（含，可留空）',
                              enabled: !_saving,
                              allowClear: true,
                              onPick: _pickDate,
                            ),
                            const SizedBox(height: 4),
                          ],
                          Text(
                            _allDay
                                ? '全天结束日期包含当天。'
                                : '按北京时间填写起止时刻；跨日安排请调整结束日期。',
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(color: _muted),
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            key: const ValueKey('calendar-event-location'),
                            controller: _location,
                            enabled: !_saving,
                            maxLength: 200,
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                              labelText: '地点（可选）',
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextFormField(
                            key: const ValueKey('calendar-event-note'),
                            controller: _note,
                            enabled: !_saving,
                            maxLength: 4000,
                            minLines: 3,
                            maxLines: 6,
                            decoration: const InputDecoration(
                              labelText: '备注（可选）',
                            ),
                          ),
                          if (_formMessage != null) ...[
                            const SizedBox(height: 10),
                            _InlineFormMessage(message: _formMessage!),
                          ],
                          ValueListenableBuilder<String?>(
                            valueListenable: widget.feedback,
                            builder: (context, message, _) => message == null
                                ? const SizedBox.shrink()
                                : Padding(
                                    padding: const EdgeInsets.only(top: 10),
                                    child: _InlineFormMessage(message: message),
                                  ),
                          ),
                          const SizedBox(height: 12),
                          AnimatedBuilder(
                            animation: widget.controller,
                            builder: (context, _) => FilledButton.icon(
                              key: const ValueKey('calendar-event-save'),
                              onPressed:
                                  _saving ||
                                      !widget.canSave() ||
                                      !widget.isCurrent()
                                  ? null
                                  : _save,
                              icon: _saving
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.save_outlined),
                              label: Text(_saving ? '正在保存…' : '保存安排'),
                              style: FilledButton.styleFrom(
                                minimumSize: const Size(48, 48),
                                tapTargetSize: MaterialTapTargetSize.padded,
                              ),
                            ),
                          ),
                          AnimatedBuilder(
                            animation: widget.controller,
                            builder: (context, _) => !widget.canSave()
                                ? const Padding(
                                    padding: EdgeInsets.only(top: 8),
                                    child: Text(
                                      '当前日程不可写入，请等待加载或来源作业完成。',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: _muted,
                                        fontSize: 12,
                                      ),
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickDate(TextEditingController controller) async {
    if (!mounted || !widget.isCurrent()) return;
    final parsed =
        _tryDate(controller.text.trim()) ??
        _tryDate(_startDate.text.trim()) ??
        DateTime.utc(2000, 1, 1);
    final initial = DateTime(parsed.year, parsed.month, parsed.day);
    widget.onOverlayChanged?.call(true);
    DateTime? picked;
    try {
      picked = await showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: DateTime(1),
        lastDate: DateTime(9998, 12, 31),
        helpText: '选择北京时间日期',
      );
    } finally {
      widget.onOverlayChanged?.call(false);
    }
    if (!mounted || !widget.isCurrent() || picked == null) return;
    controller.text = _dateText(picked);
    setState(() => _formMessage = null);
  }

  Future<void> _pickTime(TextEditingController controller) async {
    if (!mounted || !widget.isCurrent()) return;
    final parsed = _tryClock(controller.text.trim());
    final initial = parsed ?? const TimeOfDay(hour: 9, minute: 0);
    widget.onOverlayChanged?.call(true);
    TimeOfDay? picked;
    try {
      picked = await showTimePicker(
        context: context,
        initialTime: initial,
        helpText: '选择北京时间时刻',
      );
    } finally {
      widget.onOverlayChanged?.call(false);
    }
    if (!mounted || !widget.isCurrent() || picked == null) return;
    controller.text =
        '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    setState(() => _formMessage = null);
  }

  Future<void> _save() async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (!widget.isCurrent() || !mounted) return;
    if (!_formKey.currentState!.validate()) return;

    final startDay = _tryDate(_startDate.text.trim());
    final endDay = _tryDate(_endDate.text.trim());
    final startClock = _allDay ? null : _tryClock(_startTime.text.trim());
    final endClock = _allDay ? null : _tryClock(_endTime.text.trim());
    final untilDay = _weekly && _until.text.trim().isNotEmpty
        ? _tryDate(_until.text.trim())
        : null;
    if (startDay == null ||
        endDay == null ||
        (!_allDay && (startClock == null || endClock == null)) ||
        (_weekly && _until.text.trim().isNotEmpty && untilDay == null)) {
      setState(() => _formMessage = '请检查日期和时刻格式。');
      return;
    }

    final start = _allDay
        ? startDay
        : _beijingClockToUtc(startDay, startClock!);
    final endInclusive = _allDay
        ? endDay
        : _beijingClockToUtc(endDay, endClock!);
    final end = _allDay
        ? endInclusive.add(const Duration(days: 1))
        : endInclusive;
    final draft = PersonalEventDraft(
      title: _title.text.trim(),
      start: start,
      end: end,
      allDay: _allDay,
      weekly: widget.allowWeekly && _weekly,
      untilDay: widget.allowWeekly && _weekly ? untilDay : null,
      location: _location.text.trim(),
      note: _note.text,
    );
    try {
      validatePersonalDraft(draft);
    } on CalendarFailure {
      setState(() => _formMessage = '请检查标题、内容长度、日期范围和结束时间。');
      return;
    }

    setState(() {
      _saving = true;
      _formMessage = null;
    });
    bool saved = false;
    try {
      if (!widget.isCurrent() || !mounted) return;
      saved = await widget.onSave(draft);
    } finally {
      if (mounted && widget.isCurrent()) {
        setState(() => _saving = false);
      }
    }
    if (!mounted || !widget.isCurrent()) return;
    if (saved) Navigator.of(context).pop(true);
  }
}

final class _DateField extends StatelessWidget {
  const _DateField({
    required this.controller,
    required this.keyName,
    required this.label,
    required this.enabled,
    required this.onPick,
    this.allowClear = false,
  });

  final TextEditingController controller;
  final String keyName;
  final String label;
  final bool enabled;
  final bool allowClear;
  final Future<void> Function(TextEditingController) onPick;

  @override
  Widget build(BuildContext context) => TextFormField(
    key: ValueKey(keyName),
    controller: controller,
    enabled: enabled,
    keyboardType: TextInputType.datetime,
    textInputAction: TextInputAction.next,
    decoration: InputDecoration(
      labelText: label,
      hintText: 'YYYY-MM-DD',
      suffixIcon: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (allowClear)
            IconButton(
              tooltip: '清除截止日期',
              onPressed: enabled ? () => controller.clear() : null,
              icon: const Icon(Icons.clear_rounded),
            ),
          IconButton(
            tooltip: '选择日期',
            onPressed: enabled ? () => onPick(controller) : null,
            icon: const Icon(Icons.calendar_month_outlined),
          ),
        ],
      ),
    ),
  );
}

final class _ClockField extends StatelessWidget {
  const _ClockField({
    required this.controller,
    required this.keyName,
    required this.enabled,
    required this.onPick,
  });

  final TextEditingController controller;
  final String keyName;
  final bool enabled;
  final Future<void> Function(TextEditingController) onPick;

  @override
  Widget build(BuildContext context) => TextFormField(
    key: ValueKey(keyName),
    controller: controller,
    enabled: enabled,
    keyboardType: TextInputType.datetime,
    textInputAction: TextInputAction.next,
    decoration: InputDecoration(
      labelText: '时刻（北京时间 HH:mm）',
      hintText: '09:00',
      suffixIcon: IconButton(
        tooltip: '选择时刻',
        onPressed: enabled ? () => onPick(controller) : null,
        icon: const Icon(Icons.access_time_rounded),
      ),
    ),
  );
}

final class _InlineFormMessage extends StatelessWidget {
  const _InlineFormMessage({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFFFFF6E6),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(message, style: const TextStyle(color: Color(0xFF624900))),
  );
}

const _muted = Color(0xFF66736C);

DateTime? _tryDate(String value) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final date = DateTime.utc(year, month, day);
  if (date.year != year || date.month != month || date.day != day) return null;
  return date;
}

TimeOfDay? _tryClock(String value) {
  final match = RegExp(r'^(\d{2}):(\d{2})$').firstMatch(value);
  if (match == null) return null;
  final hour = int.parse(match.group(1)!);
  final minute = int.parse(match.group(2)!);
  if (hour > 23 || minute > 59) return null;
  return TimeOfDay(hour: hour, minute: minute);
}

DateTime _beijingClockToUtc(DateTime day, TimeOfDay clock) => DateTime.utc(
  day.year,
  day.month,
  day.day,
  clock.hour,
  clock.minute,
).subtract(const Duration(hours: 8));

String _dateText(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

String _clockText(DateTime day) =>
    '${day.hour.toString().padLeft(2, '0')}:'
    '${day.minute.toString().padLeft(2, '0')}';
