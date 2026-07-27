import 'package:flutter/material.dart';

import '../../../core/database/app_database.dart';
import '../../calendar/application/calendar_event_service.dart';
import '../../calendar/presentation/calendar_event_form.dart';
import '../application/effective_event_repository.dart';
import '../application/overlay_service.dart';
import 'event_detail_page.dart';
import 'event_preferences_sheet.dart';

class EventDetailLoader extends StatefulWidget {
  const EventDetailLoader({
    required this.database,
    required this.eventId,
    this.onManageOverlaps,
    super.key,
  });

  final AppDatabase database;
  final String eventId;
  final ValueChanged<String>? onManageOverlaps;

  @override
  State<EventDetailLoader> createState() => _EventDetailLoaderState();
}

class _EventDetailState {
  const _EventDetailState({
    required this.account,
    required this.event,
    required this.overlaps,
  });

  final LocalAccount account;
  final EffectiveEventRecord event;
  final List<EffectiveEventRecord> overlaps;
}

class _EventDetailLoaderState extends State<EventDetailLoader> {
  late Future<_EventDetailState?> state = _load();

  Future<_EventDetailState?> _load() async {
    final account = await (widget.database.select(
      widget.database.localAccounts,
    )..where((row) => row.isActive.equals(true))).getSingleOrNull();
    if (account == null) return null;
    final repository = EffectiveEventRepository(
      widget.database,
      accountId: account.id,
    );
    try {
      return _EventDetailState(
        account: account,
        event: await repository.byId(widget.eventId),
        overlaps: await repository.overlappingRecords(widget.eventId),
      );
    } on StateError {
      return null;
    }
  }

  void _reload() {
    setState(() {
      state = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_EventDetailState?>(
      future: state,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final value = snapshot.data;
        if (value == null) return const _MissingEventPage();
        final personal = value.event.source.source == 'user';
        return EventDetailPage(
          event: value.event,
          onEditPreferences: () => _editPreferences(value),
          onHandleOverlaps:
              value.overlaps.length > 1 && widget.onManageOverlaps != null
              ? () => widget.onManageOverlaps!(widget.eventId)
              : null,
          onHideSourceEvent: personal ? null : () => _hide(value),
          onEditPersonalEvent: personal ? () => _editPersonal(value) : null,
          onDeletePersonalEvent: personal ? () => _deletePersonal(value) : null,
        );
      },
    );
  }

  Future<void> _editPreferences(_EventDetailState value) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => EventPreferencesSheet(
        event: value.event,
        onSave: (mutation) => OverlayService(
          database: widget.database,
          accountId: value.account.id,
        ).setEventOverlay(widget.eventId, mutation),
      ),
    );
    if (mounted) _reload();
  }

  Future<void> _hide(_EventDetailState value) async {
    final confirmed = await _confirm(
      title: '隐藏这项日程？',
      body: '仅在本地日程中隐藏，学校原始记录仍会保留。',
      confirmLabel: '隐藏',
    );
    if (!confirmed) return;
    await OverlayService(
      database: widget.database,
      accountId: value.account.id,
    ).setEventOverlay(widget.eventId, const OverlayMutation(hidden: true));
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _editPersonal(_EventDetailState value) async {
    final service = CalendarEventService(
      database: widget.database,
      accountId: value.account.id,
    );
    final initial = await service.byId(widget.eventId);
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('编辑个人日程')),
          body: CalendarEventForm(
            initialEvent: initial,
            onSubmit: (submission) async {
              await service.edit(
                widget.eventId,
                submission.event,
                reminderOffsetsMinutes: submission.reminderOffsetsMinutes,
                taskIds: submission.taskIds,
              );
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
        ),
      ),
    );
    if (mounted) _reload();
  }

  Future<void> _deletePersonal(_EventDetailState value) async {
    final confirmed = await _confirm(
      title: '删除这项个人日程？',
      body: '删除后可在个人日程管理中恢复。',
      confirmLabel: '删除',
    );
    if (!confirmed) return;
    await CalendarEventService(
      database: widget.database,
      accountId: value.account.id,
    ).softDelete(widget.eventId);
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(confirmLabel),
            ),
          ],
        ),
      ) ??
      false;
}

class _MissingEventPage extends StatelessWidget {
  const _MissingEventPage();

  @override
  Widget build(BuildContext context) {
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
}
