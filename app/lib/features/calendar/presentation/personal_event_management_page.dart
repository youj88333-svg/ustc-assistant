import 'package:flutter/material.dart';

import '../application/calendar_event_service.dart';
import '../domain/personal_event.dart';

class PersonalEventManagementPage extends StatefulWidget {
  const PersonalEventManagementPage({required this.service, super.key});

  final CalendarEventService service;

  @override
  State<PersonalEventManagementPage> createState() =>
      _PersonalEventManagementPageState();
}

class _PersonalEventManagementPageState
    extends State<PersonalEventManagementPage> {
  late Future<List<PersonalEvent>> events = widget.service.managementList();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('已隐藏与已删除日程')),
      body: FutureBuilder<List<PersonalEvent>>(
        future: events,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snapshot.data ?? const [];
          if (items.isEmpty) {
            return const Center(child: Text('暂无可恢复日程'));
          }
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final event = items[index];
              return ListTile(
                title: Text(event.title),
                subtitle: Text(event.deletedAt == null ? '已隐藏' : '已删除'),
                trailing: IconButton(
                  tooltip: '恢复',
                  icon: const Icon(Icons.restore),
                  onPressed: () => _restore(event.id!),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _restore(String id) async {
    await widget.service.restore(id);
    if (mounted) {
      setState(() => events = widget.service.managementList());
    }
  }
}
