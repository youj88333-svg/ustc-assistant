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
  const TaskForm({required this.onSubmit, super.key});

  final Future<void> Function(TaskFormSubmission submission) onSubmit;

  @override
  State<TaskForm> createState() => _TaskFormState();
}

class _TaskFormState extends State<TaskForm> {
  final formKey = GlobalKey<FormState>();
  final title = TextEditingController();
  final description = TextEditingController();
  final deadline = TextEditingController();
  final estimate = TextEditingController();
  final tags = TextEditingController();
  final notes = TextEditingController();
  TaskImportance importance = TaskImportance.normal;
  bool submitting = false;

  @override
  void dispose() {
    title.dispose();
    description.dispose();
    deadline.dispose();
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
          TextFormField(
            key: const Key('task-deadline'),
            controller: deadline,
            decoration: const InputDecoration(
              labelText: '截止时间（可选）',
              hintText: '2026-07-27 18:00',
            ),
            validator: _validateDeadline,
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

  String? _validateDeadline(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    return _parseDeadline(value) == null ? '请输入有效的北京时间' : null;
  }

  String? _validateEstimate(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final parsed = int.tryParse(value);
    return parsed == null || parsed <= 0 ? '预计分钟必须大于 0' : null;
  }

  DateTime? _parseDeadline(String value) {
    final normalized = value.trim().replaceFirst(' ', 'T');
    return DateTime.tryParse(normalized);
  }

  Future<void> _submit() async {
    if (!formKey.currentState!.validate()) return;
    setState(() => submitting = true);
    try {
      await widget.onSubmit(
        TaskFormSubmission(
          title: title.text.trim(),
          description: _blankToNull(description.text),
          deadlineAt: deadline.text.trim().isEmpty
              ? null
              : _parseDeadline(deadline.text),
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
}
