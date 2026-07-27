import 'package:flutter/material.dart';

class PlanBlockDraft {
  const PlanBlockDraft({
    required this.startAt,
    required this.durationMinutes,
    this.title,
  });

  final DateTime startAt;
  final int durationMinutes;
  final String? title;

  DateTime get endAt => startAt.add(Duration(minutes: durationMinutes));
}

class PlanBlockEditor extends StatefulWidget {
  const PlanBlockEditor({
    required this.initialStart,
    required this.onSubmit,
    this.estimatedMinutes,
    this.initialTitle,
    this.submitLabel = '安排时间',
    super.key,
  });

  final DateTime initialStart;
  final int? estimatedMinutes;
  final String? initialTitle;
  final String submitLabel;
  final Future<void> Function(PlanBlockDraft draft) onSubmit;

  @override
  State<PlanBlockEditor> createState() => _PlanBlockEditorState();
}

class _PlanBlockEditorState extends State<PlanBlockEditor> {
  late final TextEditingController start;
  late final TextEditingController duration;
  late final TextEditingController title;

  @override
  void initState() {
    super.initState();
    start = TextEditingController(text: _format(widget.initialStart));
    title = TextEditingController(text: widget.initialTitle);
    duration = TextEditingController(
      text: (widget.estimatedMinutes ?? 60).toString(),
    );
  }

  @override
  void dispose() {
    start.dispose();
    duration.dispose();
    title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('plan-title'),
          controller: title,
          decoration: const InputDecoration(labelText: '标题（可选）'),
        ),
        TextField(
          key: const Key('plan-start'),
          controller: start,
          decoration: const InputDecoration(labelText: '开始时间'),
        ),
        TextField(
          key: const Key('plan-duration'),
          controller: duration,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: '时长（分钟）'),
        ),
        const SizedBox(height: 12),
        FilledButton(
          key: const Key('save-plan-block'),
          onPressed: _submit,
          child: Text(widget.submitLabel),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    final parsedStart = DateTime.tryParse(start.text.replaceFirst(' ', 'T'));
    final parsedDuration = int.tryParse(duration.text);
    if (parsedStart == null || parsedDuration == null || parsedDuration <= 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请输入有效的开始时间和时长')));
      return;
    }
    await widget.onSubmit(
      PlanBlockDraft(
        startAt: parsedStart,
        durationMinutes: parsedDuration,
        title: title.text.trim().isEmpty ? null : title.text.trim(),
      ),
    );
  }

  String _format(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')} '
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';
}
