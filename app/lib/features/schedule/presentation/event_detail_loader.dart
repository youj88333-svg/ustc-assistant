import 'package:flutter/material.dart';

import '../../../core/database/app_database.dart';
import '../application/effective_event_repository.dart';
import 'event_detail_page.dart';

class EventDetailLoader extends StatefulWidget {
  const EventDetailLoader({
    required this.database,
    required this.eventId,
    super.key,
  });

  final AppDatabase database;
  final String eventId;

  @override
  State<EventDetailLoader> createState() => _EventDetailLoaderState();
}

class _EventDetailLoaderState extends State<EventDetailLoader> {
  late Future<EffectiveEventRecord?> event = _load();

  Future<EffectiveEventRecord?> _load() async {
    final account = await (widget.database.select(
      widget.database.localAccounts,
    )..where((row) => row.isActive.equals(true))).getSingleOrNull();
    if (account == null) return null;
    try {
      return await EffectiveEventRepository(
        widget.database,
        accountId: account.id,
      ).byId(widget.eventId);
    } on StateError {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<EffectiveEventRecord?>(
      future: event,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final value = snapshot.data;
        if (value == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('日程详情')),
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('记录已不存在'),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const Key('missing-event-back'),
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('返回'),
                  ),
                ],
              ),
            ),
          );
        }
        return EventDetailPage(event: value);
      },
    );
  }
}
