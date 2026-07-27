import 'package:flutter/material.dart';

import '../../../core/database/app_database.dart';
import '../application/effective_event_repository.dart';

class EventDetailPage extends StatelessWidget {
  const EventDetailPage({
    required this.event,
    this.onEditPreferences,
    this.onHandleOverlaps,
    this.onHideSourceEvent,
    this.onEditPersonalEvent,
    this.onDeletePersonalEvent,
    super.key,
  });

  final EffectiveEventRecord event;
  final VoidCallback? onEditPreferences;
  final VoidCallback? onHandleOverlaps;
  final VoidCallback? onHideSourceEvent;
  final VoidCallback? onEditPersonalEvent;
  final VoidCallback? onDeletePersonalEvent;

  @override
  Widget build(BuildContext context) {
    final source = event.source;
    return Scaffold(
      appBar: AppBar(
        title: const Text('日程详情'),
        actions: [
          if (onEditPreferences != null)
            IconButton(
              tooltip: '编辑偏好',
              onPressed: onEditPreferences,
              icon: const Icon(Icons.tune),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            event.displayTitle,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          _DetailLine(icon: Icons.schedule, text: _timeText(source)),
          if (event.displayLocation != null)
            _DetailLine(
              icon: Icons.location_on_outlined,
              text: event.displayLocation!,
            ),
          _DetailLine(icon: Icons.link, text: _sourceLabel(source.source)),
          const Divider(height: 32),
          _SettingLine(label: '出勤', value: _attendanceLabel(event.attendance)),
          _SettingLine(
            label: '听讲',
            value: _listeningLabel(event.listeningMode),
          ),
          if (event.attendanceNote != null)
            _SettingLine(label: '出勤备注', value: event.attendanceNote!),
          if (event.listeningNote != null)
            _SettingLine(label: '听讲备注', value: event.listeningNote!),
          if (event.userNotes != null)
            _SettingLine(label: '个人备注', value: event.userNotes!),
          if (onHandleOverlaps != null) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onHandleOverlaps,
              icon: const Icon(Icons.layers_outlined),
              label: const Text('处理重叠日程'),
            ),
          ],
          if (onEditPersonalEvent != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const Key('edit-personal-event'),
              onPressed: onEditPersonalEvent,
              icon: const Icon(Icons.edit_outlined),
              label: const Text('编辑个人日程'),
            ),
          ],
          if (onHideSourceEvent != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const Key('hide-source-event'),
              onPressed: onHideSourceEvent,
              icon: const Icon(Icons.visibility_off_outlined),
              label: const Text('从日程中隐藏'),
            ),
          ],
          if (onDeletePersonalEvent != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const Key('delete-personal-event'),
              onPressed: onDeletePersonalEvent,
              icon: const Icon(Icons.delete_outline),
              label: const Text('删除个人日程'),
            ),
          ],
        ],
      ),
    );
  }

  String _timeText(CalendarEvent event) {
    if (event.allDay) {
      return '${event.startDate} 至 ${event.endDateExclusive}（结束日不含）';
    }
    final start = DateTime.fromMillisecondsSinceEpoch(event.startAt!);
    final end = DateTime.fromMillisecondsSinceEpoch(event.endAt!);
    String value(DateTime date) =>
        '${date.month}月${date.day}日 '
        '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}';
    return '${value(start)} - ${value(end)}';
  }

  String _sourceLabel(String source) => switch (source) {
    'ustc_jw' => '教务系统',
    'ustc_young' => '二课平台',
    'user' => '个人日程',
    _ => source,
  };

  String _attendanceLabel(AttendancePolicy value) => switch (value) {
    AttendancePolicy.unknown => '未设置',
    AttendancePolicy.mustGo => '必去',
    AttendancePolicy.gamble => '可以赌',
    AttendancePolicy.skip => '不去',
  };

  String _listeningLabel(ListeningMode value) => switch (value) {
    ListeningMode.unknown => '未设置',
    ListeningMode.listen => '听讲',
    ListeningMode.notListen => '不听讲',
  };
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _SettingLine extends StatelessWidget {
  const _SettingLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(label, style: Theme.of(context).textTheme.labelLarge),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
