import 'package:flutter/material.dart';

import '../../../core/time/beijing_clock.dart';
import '../application/jw_day_move_service.dart';
import '../domain/jw_day_move.dart';

/// The outcome of a finished whole-day move dialog session.
sealed class JwDayMoveDialogResult {
  const JwDayMoveDialogResult();
}

/// A move (or retarget) succeeded: the eligible courses of [sourceDate] now
/// show on [targetDate]. The caller selects the target week and can undo.
class JwDayMovePerformed extends JwDayMoveDialogResult {
  const JwDayMovePerformed({
    required this.sourceDate,
    required this.targetDate,
  });

  final String sourceDate;
  final String targetDate;
}

/// The move record of [sourceDate] was cleared; its courses show again on the
/// original date. The caller selects the source week and can undo.
class JwDayMoveCleared extends JwDayMoveDialogResult {
  const JwDayMoveCleared(this.sourceDate);

  final String sourceDate;
}

/// The manual whole-day course move dialog (Spec section 10.3).
///
/// Lets the user pick a source and a target Beijing date and previews the
/// eligible `ustc_jw/course` titles before confirming. The confirmation is
/// only enabled once a preview with at least one course is loaded and the two
/// dates differ. When the source date already carries a move the confirm
/// action reads "更新移动" and a "恢复原日期" action clears the record. On
/// success the dialog pops with a [JwDayMoveDialogResult]; cancel pops null.
/// All mutations go through the account-scoped [JwDayMoveService]; the dialog
/// never touches database rows directly.
class JwDayMoveDialog extends StatefulWidget {
  const JwDayMoveDialog({
    required this.service,
    required this.initialSourceDate,
    this.clock = const SystemBeijingClock(),
    super.key,
  });

  final JwDayMoveService service;
  final DateTime initialSourceDate;
  final BeijingClock clock;

  @override
  State<JwDayMoveDialog> createState() => _JwDayMoveDialogState();
}

class _JwDayMoveDialogState extends State<JwDayMoveDialog> {
  static const _weekdayLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  late DateTime _sourceDate;
  late DateTime _targetDate;
  JwDayMovePreview? _preview;
  int _previewGeneration = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _sourceDate = widget.initialSourceDate;
    _targetDate = widget.initialSourceDate.add(const Duration(days: 1));
    _reloadPreview();
  }

  bool get _sourceEqualsTarget =>
      _sourceDate.year == _targetDate.year &&
      _sourceDate.month == _targetDate.month &&
      _sourceDate.day == _targetDate.day;

  bool get _canConfirm =>
      !_busy &&
      _preview != null &&
      _preview!.courses.isNotEmpty &&
      !_sourceEqualsTarget;

  Future<void> _reloadPreview() async {
    final generation = ++_previewGeneration;
    final preview = await widget.service.preview(_dateKey(_sourceDate));
    if (!mounted || generation != _previewGeneration) return;
    setState(() => _preview = preview);
  }

  Future<void> _pickSourceDate() async {
    final picked = await _pickDate(_sourceDate);
    if (picked == null) return;
    setState(() => _sourceDate = picked);
    _reloadPreview();
  }

  Future<void> _pickTargetDate() async {
    final picked = await _pickDate(_targetDate);
    if (picked == null) return;
    setState(() => _targetDate = picked);
  }

  Future<DateTime?> _pickDate(DateTime current) async {
    final now = widget.clock.now();
    return showDatePicker(
      context: context,
      initialDate: current,
      firstDate: now.subtract(const Duration(days: 730)),
      lastDate: now.add(const Duration(days: 730)),
    );
  }

  Future<void> _move() async {
    setState(() => _busy = true);
    try {
      final sourceDate = _dateKey(_sourceDate);
      final targetDate = _dateKey(_targetDate);
      await widget.service.move(sourceDate, targetDate);
      if (!mounted) return;
      Navigator.of(
        context,
      ).pop(JwDayMovePerformed(sourceDate: sourceDate, targetDate: targetDate));
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('移动失败：$error')));
    }
  }

  Future<void> _clear() async {
    setState(() => _busy = true);
    try {
      final sourceDate = _dateKey(_sourceDate);
      await widget.service.clear(sourceDate);
      if (!mounted) return;
      Navigator.of(context).pop(JwDayMoveCleared(sourceDate));
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('恢复失败：$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final hasMove = preview?.targetDate != null;
    return AlertDialog(
      key: const Key('day-move-dialog'),
      title: const Text('整日调课'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DateField(
                key: const Key('day-move-source-field'),
                label: '源日期',
                value: _sourceDate,
                onTap: _busy ? null : _pickSourceDate,
              ),
              _DateField(
                key: const Key('day-move-target-field'),
                label: '目标日期',
                value: _targetDate,
                onTap: _busy ? null : _pickTargetDate,
              ),
              if (_sourceEqualsTarget)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '源日期与目标日期相同',
                    key: const Key('day-move-error'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                '符合条件课程：${preview?.courses.length ?? 0} 门',
                key: const Key('day-move-preview-count'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              if (preview == null)
                const Text('加载中…')
              else if (preview.courses.isEmpty)
                const Text('没有符合条件的课程')
              else
                for (final title in preview.courses)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        if (hasMove)
          TextButton(
            key: const Key('day-move-clear'),
            onPressed: _busy ? null : _clear,
            child: const Text('恢复原日期'),
          ),
        FilledButton(
          key: const Key('day-move-confirm'),
          onPressed: _canConfirm ? _move : null,
          child: Text(hasMove ? '更新移动' : '确认移动'),
        ),
      ],
    );
  }

  static String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onTap,
    super.key,
  });

  final String label;
  final DateTime value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 72,
              child: Text(label, style: Theme.of(context).textTheme.labelLarge),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${_JwDayMoveDialogState._dateKey(value)} '
                '${_JwDayMoveDialogState._weekdayLabels[value.weekday - 1]}',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
            const Icon(Icons.calendar_today_outlined, size: 16),
          ],
        ),
      ),
    );
  }
}
