import 'package:flutter/material.dart';

import '../domain/personal_event.dart';

class CalendarEventSubmission {
  const CalendarEventSubmission({
    required this.event,
    required this.reminderOffsetsMinutes,
    required this.taskIds,
  });

  final PersonalEvent event;
  final List<int> reminderOffsetsMinutes;
  final List<String> taskIds;
}

class CalendarEventPrefill {
  const CalendarEventPrefill({
    this.start,
    this.end,
    this.allDayDate,
    this.relatedTaskIds = const [],
  });

  final DateTime? start;
  final DateTime? end;
  final DateTime? allDayDate;
  final List<String> relatedTaskIds;
}

class CalendarEventForm extends StatefulWidget {
  const CalendarEventForm({
    required this.onSubmit,
    this.initialEvent,
    this.initialStart,
    this.initialEnd,
    this.initialAllDayDate,
    this.relatedTaskIds = const [],
    super.key,
  });

  final PersonalEvent? initialEvent;
  final DateTime? initialStart;
  final DateTime? initialEnd;
  final DateTime? initialAllDayDate;
  final List<String> relatedTaskIds;
  final Future<void> Function(CalendarEventSubmission submission) onSubmit;

  @override
  State<CalendarEventForm> createState() => _CalendarEventFormState();
}

class _CalendarEventFormState extends State<CalendarEventForm> {
  late final TextEditingController title;
  late final TextEditingController description;
  late final TextEditingController location;
  late final TextEditingController tags;
  late bool allDay;
  late DateTime start;
  late DateTime end;
  late PersonalEventType type;
  late CompletionPolicy completionPolicy;
  late String importance;
  late bool tentative;
  late bool reminderEnabled;
  late String? color;
  late final List<String> taskIds;
  String? validationMessage;
  bool saving = false;

  static const colors = ['#2878B5', '#2F855A', '#B7791F', '#C53030', '#6B46C1'];

  @override
  void initState() {
    super.initState();
    final initial = widget.initialEvent;
    title = TextEditingController(text: initial?.title);
    description = TextEditingController(text: initial?.description);
    location = TextEditingController(text: initial?.locationName);
    tags = TextEditingController(text: initial?.tags.join(', '));
    allDay = initial?.allDay ?? widget.initialAllDayDate != null;
    final now = DateTime.now();
    start =
        initial?.startAt ??
        initial?.startDate ??
        widget.initialStart ??
        widget.initialAllDayDate ??
        DateTime(now.year, now.month, now.day, now.hour + 1);
    end =
        initial?.endAt ??
        initial?.endDateExclusive ??
        widget.initialEnd ??
        (allDay
            ? DateTime(start.year, start.month, start.day + 1)
            : start.add(const Duration(hours: 1)));
    type = initial?.type ?? PersonalEventType.personal;
    completionPolicy =
        initial?.completionPolicy ?? CompletionPolicy.autoAfterEnd;
    importance = initial?.importance ?? 'normal';
    tentative = initial?.status == EventStatus.tentative;
    reminderEnabled = !allDay;
    color = initial?.color;
    taskIds = [...widget.relatedTaskIds];
  }

  @override
  void dispose() {
    title.dispose();
    description.dispose();
    location.dispose();
    tags.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextFormField(
            key: const Key('event-title'),
            controller: title,
            decoration: const InputDecoration(labelText: '标题'),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            key: const Key('all-day-toggle'),
            contentPadding: EdgeInsets.zero,
            title: const Text('全天'),
            value: allDay,
            onChanged: (value) {
              setState(() {
                allDay = value;
                if (allDay) {
                  start = _date(start);
                  end = _date(start).add(const Duration(days: 1));
                  reminderEnabled = false;
                } else {
                  start = DateTime(start.year, start.month, start.day, 9);
                  end = start.add(const Duration(hours: 1));
                  reminderEnabled = true;
                }
              });
            },
          ),
          _DateTimeRow(
            label: allDay ? '开始日期' : '开始时间',
            value: start,
            showTime: !allDay,
            onChanged: (value) => setState(() => start = value),
          ),
          _DateTimeRow(
            label: allDay ? '结束日期（不含）' : '结束时间',
            value: end,
            showTime: !allDay,
            onChanged: (value) => setState(() => end = value),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: location,
            decoration: const InputDecoration(
              labelText: '地点',
              prefixIcon: Icon(Icons.location_on_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: description,
            decoration: const InputDecoration(labelText: '描述'),
            maxLines: 3,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<PersonalEventType>(
            initialValue: type,
            decoration: const InputDecoration(labelText: '类型'),
            items: [
              for (final value in PersonalEventType.values)
                DropdownMenuItem(value: value, child: Text(_typeLabel(value))),
            ],
            onChanged: (value) {
              if (value != null) setState(() => type = value);
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: importance,
            decoration: const InputDecoration(labelText: '重要程度'),
            items: const [
              DropdownMenuItem(value: 'low', child: Text('低')),
              DropdownMenuItem(value: 'normal', child: Text('普通')),
              DropdownMenuItem(value: 'high', child: Text('高')),
              DropdownMenuItem(value: 'critical', child: Text('关键')),
            ],
            onChanged: (value) {
              if (value != null) setState(() => importance = value);
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<CompletionPolicy>(
            initialValue: completionPolicy,
            decoration: const InputDecoration(labelText: '结束后的完成方式'),
            items: const [
              DropdownMenuItem(
                value: CompletionPolicy.autoAfterEnd,
                child: Text('自动标记完成'),
              ),
              DropdownMenuItem(
                value: CompletionPolicy.manualConfirmation,
                child: Text('由我确认'),
              ),
            ],
            onChanged: (value) {
              if (value != null) {
                setState(() => completionPolicy = value);
              }
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('暂定'),
            value: tentative,
            onChanged: (value) => setState(() => tentative = value),
          ),
          if (!allDay)
            SwitchListTile(
              key: const Key('event-reminder-toggle'),
              contentPadding: EdgeInsets.zero,
              title: const Text('开始前 15 分钟提醒'),
              value: reminderEnabled,
              onChanged: (value) {
                setState(() => reminderEnabled = value);
              },
            ),
          TextFormField(
            controller: tags,
            decoration: const InputDecoration(labelText: '标签（逗号分隔）'),
          ),
          const SizedBox(height: 16),
          Text('颜色', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            children: [
              for (final value in colors)
                IconButton(
                  tooltip: value,
                  onPressed: () => setState(() => color = value),
                  icon: Icon(
                    color == value ? Icons.check_circle : Icons.circle_outlined,
                    color: _color(value),
                  ),
                ),
            ],
          ),
          if (taskIds.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('关联任务', style: Theme.of(context).textTheme.labelLarge),
            Wrap(
              spacing: 8,
              children: [
                for (final taskId in taskIds)
                  InputChip(
                    label: Text(taskId),
                    onDeleted: () => setState(() => taskIds.remove(taskId)),
                  ),
              ],
            ),
          ],
          if (validationMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                validationMessage!,
                key: const Key('event-validation-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const Key('save-event'),
            onPressed: saving ? null : _submit,
            icon: const Icon(Icons.save_outlined),
            label: Text(saving ? '保存中' : '保存'),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    setState(() {
      validationMessage = null;
      saving = true;
    });
    try {
      final event = allDay
          ? PersonalEvent.allDay(
              id: widget.initialEvent?.id,
              title: title.text,
              startDate: start,
              endDateExclusive: end,
              description: _optional(description.text),
              locationName: _optional(location.text),
              type: type,
              status: tentative ? EventStatus.tentative : EventStatus.active,
              completionPolicy: completionPolicy,
              importance: importance,
              color: color,
              tags: _tags(),
            )
          : PersonalEvent.timed(
              id: widget.initialEvent?.id,
              title: title.text,
              startAt: start,
              endAt: end,
              description: _optional(description.text),
              locationName: _optional(location.text),
              type: type,
              status: tentative ? EventStatus.tentative : EventStatus.active,
              completionPolicy: completionPolicy,
              importance: importance,
              color: color,
              tags: _tags(),
            );
      await widget.onSubmit(
        CalendarEventSubmission(
          event: event,
          reminderOffsetsMinutes: reminderEnabled ? const [15] : const [],
          taskIds: List.unmodifiable(taskIds),
        ),
      );
    } on CalendarValidationError catch (error) {
      setState(() => validationMessage = error.message);
    } on Object {
      setState(() => validationMessage = '暂时无法保存，请检查账号和本地存储设置');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  List<String> _tags() => tags.text
      .split(',')
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList(growable: false);

  String? _optional(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static DateTime _date(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  static Color _color(String value) =>
      Color(int.parse(value.substring(1), radix: 16) | 0xFF000000);

  static String _typeLabel(PersonalEventType value) => switch (value) {
    PersonalEventType.personal => '个人',
    PersonalEventType.entertainment => '娱乐',
    PersonalEventType.meal => '用餐',
    PersonalEventType.campusAffair => '校园事务',
    PersonalEventType.travel => '出行',
    PersonalEventType.study => '学习',
  };
}

class _DateTimeRow extends StatelessWidget {
  const _DateTimeRow({
    required this.label,
    required this.value,
    required this.showTime,
    required this.onChanged,
  });

  final String label;
  final DateTime value;
  final bool showTime;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    final text =
        '${value.year}-${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}'
        '${showTime ? ' ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}' : ''}';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      subtitle: Text(text),
      trailing: IconButton(
        tooltip: '选择$label',
        icon: Icon(showTime ? Icons.event : Icons.calendar_month),
        onPressed: () => _pick(context),
      ),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final date = await showDatePicker(
      context: context,
      initialDate: value,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (date == null || !context.mounted) return;
    if (!showTime) {
      onChanged(date);
      return;
    }
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(value),
    );
    if (time == null) return;
    onChanged(
      DateTime(date.year, date.month, date.day, time.hour, time.minute),
    );
  }
}
