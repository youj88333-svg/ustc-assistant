import 'package:flutter/material.dart';

import '../application/effective_event_repository.dart';
import '../application/overlay_service.dart';

class EventPreferencesSheet extends StatefulWidget {
  const EventPreferencesSheet({
    required this.event,
    required this.onSave,
    super.key,
  });

  final EffectiveEventRecord event;
  final Future<void> Function(OverlayMutation mutation) onSave;

  @override
  State<EventPreferencesSheet> createState() => _EventPreferencesSheetState();
}

class _EventPreferencesSheetState extends State<EventPreferencesSheet> {
  static const colors = [
    '#1565C0',
    '#00897B',
    '#6A1B9A',
    '#EF6C00',
    '#C62828',
    '#455A64',
  ];

  late AttendancePolicy attendance = widget.event.attendance;
  late ListeningMode listening = widget.event.listeningMode;
  late String? color = widget.event.color;
  late final attendanceNote = TextEditingController(
    text: widget.event.attendanceNote,
  );
  late final listeningNote = TextEditingController(
    text: widget.event.listeningNote,
  );
  late final userNotes = TextEditingController(text: widget.event.userNotes);
  bool saving = false;

  @override
  void dispose() {
    attendanceNote.dispose();
    listeningNote.dispose();
    userNotes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('日程偏好', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            DropdownButtonFormField<AttendancePolicy>(
              key: const Key('attendance-policy'),
              initialValue: attendance,
              decoration: const InputDecoration(labelText: '出勤'),
              items: const [
                DropdownMenuItem(
                  value: AttendancePolicy.unknown,
                  child: Text('未设置'),
                ),
                DropdownMenuItem(
                  value: AttendancePolicy.mustGo,
                  child: Text('必去'),
                ),
                DropdownMenuItem(
                  value: AttendancePolicy.gamble,
                  child: Text('可以赌'),
                ),
                DropdownMenuItem(
                  value: AttendancePolicy.skip,
                  child: Text('不去'),
                ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => attendance = value);
              },
            ),
            TextField(
              key: const Key('attendance-note'),
              controller: attendanceNote,
              decoration: const InputDecoration(labelText: '出勤备注'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<ListeningMode>(
              key: const Key('listening-mode'),
              initialValue: listening,
              decoration: const InputDecoration(labelText: '听讲'),
              items: const [
                DropdownMenuItem(
                  value: ListeningMode.unknown,
                  child: Text('未设置'),
                ),
                DropdownMenuItem(
                  value: ListeningMode.listen,
                  child: Text('听讲'),
                ),
                DropdownMenuItem(
                  value: ListeningMode.notListen,
                  child: Text('不听讲'),
                ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => listening = value);
              },
            ),
            TextField(
              key: const Key('listening-note'),
              controller: listeningNote,
              decoration: const InputDecoration(labelText: '听讲备注'),
            ),
            TextField(
              key: const Key('event-user-notes'),
              controller: userNotes,
              decoration: const InputDecoration(labelText: '个人备注'),
              minLines: 2,
              maxLines: 4,
            ),
            const SizedBox(height: 16),
            Text('颜色', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              children: [
                for (final value in colors)
                  Semantics(
                    selected: color == value,
                    label: '颜色 $value',
                    child: InkWell(
                      key: Key('event-color-$value'),
                      customBorder: const CircleBorder(),
                      onTap: () => setState(() => color = value),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _color(value),
                          border: color == value
                              ? Border.all(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface,
                                  width: 3,
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('save-event-preferences'),
                onPressed: saving ? null : _save,
                child: Text(saving ? '保存中' : '保存'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    setState(() => saving = true);
    try {
      await widget.onSave(
        OverlayMutation(
          attendancePolicy: attendance,
          attendanceNote: attendanceNote.text.trim(),
          listeningMode: listening,
          listeningNote: listeningNote.text.trim(),
          color: color,
          userNotes: userNotes.text.trim(),
        ),
      );
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Color _color(String value) =>
      Color(int.parse(value.substring(1), radix: 16) | 0xFF000000);
}
