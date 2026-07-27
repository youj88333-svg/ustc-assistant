import 'package:flutter/material.dart';

import '../domain/recurrence_expander.dart';
import '../domain/recurrence_rule.dart';

class RecurrenceEditor extends StatefulWidget {
  const RecurrenceEditor({
    required this.anchor,
    required this.onChanged,
    this.initialRule,
    super.key,
  });

  final DateTime anchor;
  final RecurrenceRule? initialRule;
  final ValueChanged<RecurrenceRule> onChanged;

  @override
  State<RecurrenceEditor> createState() => _RecurrenceEditorState();
}

class _RecurrenceEditorState extends State<RecurrenceEditor> {
  late RecurrenceFrequency frequency =
      widget.initialRule?.frequency ?? RecurrenceFrequency.daily;
  late int interval = widget.initialRule?.interval ?? 1;
  late Set<int> weekdays = {
    ...(widget.initialRule?.weekdays ?? {widget.anchor.weekday}),
  };
  late bool hasUntil = widget.initialRule?.untilDate != null;
  late DateTime untilDate =
      widget.initialRule?.untilDate ??
      dateOnly(widget.anchor).add(const Duration(days: 30));

  @override
  Widget build(BuildContext context) {
    final rule = _rule();
    final preview = expandRecurrence(
      rule,
      from: widget.anchor,
      through: widget.anchor.add(const Duration(days: 364)),
    ).take(5);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SegmentedButton<RecurrenceFrequency>(
          segments: const [
            ButtonSegment(value: RecurrenceFrequency.daily, label: Text('每天')),
            ButtonSegment(value: RecurrenceFrequency.weekly, label: Text('每周')),
            ButtonSegment(
              value: RecurrenceFrequency.monthly,
              label: Text('每月'),
            ),
          ],
          selected: {frequency},
          onSelectionChanged: (value) {
            setState(() => frequency = value.single);
            _notify();
          },
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            const Expanded(child: Text('间隔')),
            IconButton(
              tooltip: '减少间隔',
              onPressed: interval == 1
                  ? null
                  : () {
                      setState(() => interval--);
                      _notify();
                    },
              icon: const Icon(Icons.remove),
            ),
            SizedBox(
              width: 42,
              child: Text(
                '$interval',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: '增加间隔',
              onPressed: () {
                setState(() => interval++);
                _notify();
              },
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        if (frequency == RecurrenceFrequency.weekly) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            children: [
              for (var day = DateTime.monday; day <= DateTime.sunday; day++)
                FilterChip(
                  label: Text(_weekdayLabel(day)),
                  selected: weekdays.contains(day),
                  onSelected: (selected) {
                    if (!selected && weekdays.length == 1) return;
                    setState(() {
                      if (selected) {
                        weekdays.add(day);
                      } else {
                        weekdays.remove(day);
                      }
                    });
                    _notify();
                  },
                ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('设置结束日期'),
          value: hasUntil,
          onChanged: (value) {
            setState(() => hasUntil = value);
            _notify();
          },
        ),
        if (hasUntil)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('结束日期（包含）'),
            subtitle: Text(dateText(untilDate)),
            trailing: IconButton(
              tooltip: '选择结束日期',
              icon: const Icon(Icons.calendar_month),
              onPressed: () => _pickUntil(context),
            ),
          ),
        const Divider(height: 28),
        Text('前五次', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        for (final value in preview)
          Text(
            '${dateText(value)} '
            '${value.hour.toString().padLeft(2, '0')}:'
            '${value.minute.toString().padLeft(2, '0')}',
          ),
      ],
    );
  }

  RecurrenceRule _rule() => switch (frequency) {
    RecurrenceFrequency.daily => RecurrenceRule.daily(
      anchor: widget.anchor,
      interval: interval,
      untilDate: hasUntil ? untilDate : null,
    ),
    RecurrenceFrequency.weekly => RecurrenceRule.weekly(
      anchor: widget.anchor,
      weekdays: weekdays,
      interval: interval,
      untilDate: hasUntil ? untilDate : null,
    ),
    RecurrenceFrequency.monthly => RecurrenceRule.monthly(
      anchor: widget.anchor,
      interval: interval,
      untilDate: hasUntil ? untilDate : null,
    ),
  };

  void _notify() => widget.onChanged(_rule());

  Future<void> _pickUntil(BuildContext context) async {
    final selected = await showDatePicker(
      context: context,
      initialDate: untilDate,
      firstDate: dateOnly(widget.anchor),
      lastDate: DateTime(2100),
    );
    if (selected != null) {
      setState(() => untilDate = selected);
      _notify();
    }
  }

  String _weekdayLabel(int day) => const {
    DateTime.monday: '一',
    DateTime.tuesday: '二',
    DateTime.wednesday: '三',
    DateTime.thursday: '四',
    DateTime.friday: '五',
    DateTime.saturday: '六',
    DateTime.sunday: '日',
  }[day]!;
}
