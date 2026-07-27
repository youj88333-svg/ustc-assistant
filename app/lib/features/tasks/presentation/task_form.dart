import 'package:flutter/material.dart';

import '../domain/task.dart';

class TaskFormSubmission {
  const TaskFormSubmission({
    required this.title,
    required this.importance,
    this.description,
    this.deadlineAt,
    this.estimatedMinutes,
    this.tags = const [],
    this.userNotes,
    this.relatedEventIds = const [],
    this.reminderOffsetsMinutes,
  });

  final String title;
  final String? description;
  final DateTime? deadlineAt;
  final int? estimatedMinutes;
  final TaskImportance importance;
  final List<String> tags;
  final String? userNotes;
  final List<String> relatedEventIds;
  final List<int>? reminderOffsetsMinutes;
}

class TaskForm extends StatefulWidget {
  const TaskForm({required this.onSubmit, this.initialNow, super.key});

  final Future<void> Function(TaskFormSubmission submission) onSubmit;
  final DateTime? initialNow;

  @override
  State<TaskForm> createState() => _TaskFormState();
}

class _TaskFormState extends State<TaskForm> {
  final formKey = GlobalKey<FormState>();
  final title = TextEditingController();
  final description = TextEditingController();
  final estimate = TextEditingController();
  final tags = TextEditingController();
  final notes = TextEditingController();
  TaskImportance importance = TaskImportance.normal;
  DateTime? deadlineAt;
  bool submitting = false;

  @override
  void dispose() {
    title.dispose();
    description.dispose();
    estimate.dispose();
    tags.dispose();
    notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextFormField(
            key: const Key('task-title'),
            controller: title,
            decoration: const InputDecoration(labelText: '标题'),
            validator: (value) =>
                value == null || value.trim().isEmpty ? '请输入标题' : null,
          ),
          TextFormField(
            controller: description,
            decoration: const InputDecoration(labelText: '描述（可选）'),
            maxLines: 3,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: ListTile(
                  key: const Key('task-deadline-date'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('截止日期'),
                  subtitle: Text(
                    deadlineAt == null ? '未设置' : _dateText(deadlineAt!),
                  ),
                  trailing: const Icon(Icons.calendar_month_outlined),
                  onTap: _pickDeadlineDate,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ListTile(
                  key: const Key('task-deadline-time'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('截止时间'),
                  subtitle: Text(
                    deadlineAt == null ? '未设置' : _timeText(deadlineAt!),
                  ),
                  trailing: const Icon(Icons.schedule),
                  onTap: _pickDeadlineTime,
                ),
              ),
              if (deadlineAt != null)
                IconButton(
                  key: const Key('clear-task-deadline'),
                  tooltip: '清除截止时间',
                  onPressed: () => setState(() => deadlineAt = null),
                  icon: const Icon(Icons.clear),
                ),
            ],
          ),
          if (deadlineAt != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '北京时间 ${_dateText(deadlineAt!)} ${_timeText(deadlineAt!)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          TextFormField(
            key: const Key('task-estimate'),
            controller: estimate,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '预计分钟（可选）'),
            validator: _validateEstimate,
          ),
          DropdownButtonFormField<TaskImportance>(
            initialValue: importance,
            decoration: const InputDecoration(labelText: '优先级'),
            items: [
              for (final value in TaskImportance.values)
                DropdownMenuItem(value: value, child: Text(value.name)),
            ],
            onChanged: (value) {
              if (value != null) importance = value;
            },
          ),
          TextFormField(
            controller: tags,
            decoration: const InputDecoration(labelText: '标签（逗号分隔）'),
          ),
          TextFormField(
            controller: notes,
            decoration: const InputDecoration(labelText: '备注（可选）'),
            maxLines: 3,
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const Key('save-task'),
            onPressed: submitting ? null : _submit,
            icon: const Icon(Icons.save_outlined),
            label: const Text('保存'),
          ),
        ],
      ),
    );
  }

  String? _validateEstimate(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final parsed = int.tryParse(value);
    return parsed == null || parsed <= 0 ? '预计分钟必须大于 0' : null;
  }

  Future<void> _submit() async {
    if (!formKey.currentState!.validate()) return;
    setState(() => submitting = true);
    try {
      await widget.onSubmit(
        TaskFormSubmission(
          title: title.text.trim(),
          description: _blankToNull(description.text),
          deadlineAt: deadlineAt,
          estimatedMinutes: estimate.text.trim().isEmpty
              ? null
              : int.parse(estimate.text),
          importance: importance,
          tags: tags.text
              .split(',')
              .map((item) => item.trim())
              .where((item) => item.isNotEmpty)
              .toList(growable: false),
          userNotes: _blankToNull(notes.text),
        ),
      );
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  String? _blankToNull(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<void> _pickDeadlineDate() async {
    final base = deadlineAt ?? widget.initialNow ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(base.year - 1),
      lastDate: DateTime(base.year + 10),
    );
    if (date == null) return;
    final time = deadlineAt == null
        ? const TimeOfDay(hour: 23, minute: 59)
        : TimeOfDay.fromDateTime(deadlineAt!);
    setState(() {
      deadlineAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  Future<void> _pickDeadlineTime() async {
    final base = deadlineAt ?? widget.initialNow ?? DateTime.now();
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
      initialEntryMode: TimePickerEntryMode.input,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (time == null) return;
    setState(() {
      deadlineAt = DateTime(
        base.year,
        base.month,
        base.day,
        time.hour,
        time.minute,
      );
    });
  }

  String _dateText(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  String _timeText(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';
}
