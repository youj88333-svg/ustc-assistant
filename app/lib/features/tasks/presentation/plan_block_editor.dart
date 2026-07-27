import 'package:flutter/material.dart';

class PlanBlockDraft {
  const PlanBlockDraft({required this.startAt, required this.durationMinutes});

  final DateTime startAt;
  final int durationMinutes;

  DateTime get endAt => startAt.add(Duration(minutes: durationMinutes));
}

class PlanBlockEditor extends StatefulWidget {
  const PlanBlockEditor({
    required this.initialStart,
    required this.onSubmit,
    this.estimatedMinutes,
    super.key,
  });

  final DateTime initialStart;
  final int? estimatedMinutes;
  final Future<void> Function(PlanBlockDraft draft) onSubmit;

  @override
  State<PlanBlockEditor> createState() => _PlanBlockEditorState();
}

class _PlanBlockEditorState extends State<PlanBlockEditor> {
  late final TextEditingController start;
  late final TextEditingController duration;

  @override
  void initState() {
    super.initState();
    start = TextEditingController(text: _format(widget.initialStart));
    duration = TextEditingController(
      text: (widget.estimatedMinutes ?? 60).toString(),
    );
  }

  @override
  void dispose() {
    start.dispose();
    duration.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
        FilledButton(onPressed: _submit, child: const Text('安排时间')),
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
      PlanBlockDraft(startAt: parsedStart, durationMinutes: parsedDuration),
    );
  }

  String _format(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')} '
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';
}
