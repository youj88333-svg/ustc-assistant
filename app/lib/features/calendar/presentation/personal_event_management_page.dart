import 'package:flutter/material.dart';

import '../application/calendar_event_service.dart';
import '../domain/personal_event.dart';

/// The management-state categories surfaced in the personal-event management
/// page. Each maps to a [PersonalEvent] lifecycle state (or soft-deletion).
/// Source-owned events (courses/exams/iCourse) are never listed here — the
/// underlying `managementEvents()` query is `source=user` only, so the UI
/// never offers a delete entry for source facts.
enum ManagementFilter {
  cancelled('已取消'),
  hidden('已隐藏'),
  deleted('已删除');

  const ManagementFilter(this.label);

  final String label;
}

class PersonalEventManagementPage extends StatefulWidget {
  const PersonalEventManagementPage({required this.service, super.key});

  final CalendarEventService service;

  @override
  State<PersonalEventManagementPage> createState() =>
      _PersonalEventManagementPageState();
}

class _PersonalEventManagementPageState
    extends State<PersonalEventManagementPage> {
  late Future<List<PersonalEvent>> events = widget.service.managementEvents();
  Set<ManagementFilter> activeFilters = {
    ManagementFilter.cancelled,
    ManagementFilter.hidden,
    ManagementFilter.deleted,
  };

  Future<void> _reload() {
    final next = widget.service.managementEvents();
    if (mounted) {
      setState(() {
        events = next;
      });
    }
    return next;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('日程管理')),
      body: FutureBuilder<List<PersonalEvent>>(
        future: events,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final all = snapshot.data ?? const <PersonalEvent>[];
          final items = all.where(_matchesFilter).toList(growable: false);
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final filter in ManagementFilter.values)
                      FilterChip(
                        key: Key('mgmt-filter-${filter.name}'),
                        label: Text(filter.label),
                        selected: activeFilters.contains(filter),
                        onSelected: (selected) {
                          setState(() {
                            if (selected) {
                              activeFilters = {...activeFilters, filter};
                            } else {
                              activeFilters = activeFilters
                                  .where((f) => f != filter)
                                  .toSet();
                            }
                          });
                        },
                      ),
                  ],
                ),
              ),
              Expanded(
                child: items.isEmpty
                    ? const Center(child: Text('暂无可恢复日程'))
                    : ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final event = items[index];
                          return _ManagementEventRow(
                            event: event,
                            onReopen: event.id == null
                                ? null
                                : () => _reopen(event.id!),
                            onRestore: event.id == null
                                ? null
                                : () => _restore(event.id!),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  bool _matchesFilter(PersonalEvent event) {
    if (event.deletedAt != null) return activeFilters.contains(ManagementFilter.deleted);
    switch (event.status) {
      case EventStatus.cancelled:
        return activeFilters.contains(ManagementFilter.cancelled);
      case EventStatus.hidden:
        return activeFilters.contains(ManagementFilter.hidden);
      case EventStatus.completed:
      case EventStatus.skipped:
        // Completed/skipped events are terminal but not currently surfaced as
        // a recovery category; they stay out of the filtered view.
        return false;
      case EventStatus.active:
      case EventStatus.tentative:
        return false;
    }
  }

  Future<void> _reopen(String id) async {
    await widget.service.reopen(id);
    await _reload();
  }

  Future<void> _restore(String id) async {
    await widget.service.restore(id);
    await _reload();
  }
}

/// A single management row. Renders the event title, a high-contrast status
/// label (cancelled/hidden/deleted), and the single recovery action valid for
/// that state: reopen for cancelled, restore for soft-deleted. Hidden events
/// are restored to active via the same restore path (the service flips a
/// hidden+deleted row back to active on restore), but a plain hidden (not
/// deleted) event has no single-step recovery control here — unhiding is owned
/// by the overlay workflow, not the lifecycle restore tool.
class _ManagementEventRow extends StatelessWidget {
  const _ManagementEventRow({
    required this.event,
    required this.onReopen,
    required this.onRestore,
  });

  final PersonalEvent event;
  final VoidCallback? onReopen;
  final VoidCallback? onRestore;

  @override
  Widget build(BuildContext context) {
    final (label, color) = _statusAppearance(event);
    final action = _action(event);
    return ListTile(
      title: Text(event.title),
      subtitle: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
      trailing: action == null
          ? null
          : action == _RowAction.reopen
              ? IconButton(
                  tooltip: '重新打开',
                  icon: const Icon(Icons.restart_alt),
                  onPressed: onReopen,
                )
              : IconButton(
                  tooltip: '恢复',
                  icon: const Icon(Icons.restore),
                  onPressed: onRestore,
                ),
    );
  }

  (String, Color) _statusAppearance(PersonalEvent event) {
    if (event.deletedAt != null) {
      return ('已删除', const Color(0xFF6A1B1A));
    }
    switch (event.status) {
      case EventStatus.cancelled:
        return ('已取消', const Color(0xFF8E1C00));
      case EventStatus.hidden:
        return ('已隐藏', const Color(0xFF33415C));
      case EventStatus.completed:
        return ('已完成', const Color(0xFF1B5E20));
      case EventStatus.skipped:
        return ('已跳过', const Color(0xFF33415C));
      case EventStatus.active:
      case EventStatus.tentative:
        return ('进行中', const Color(0xFF1B5E20));
    }
  }

  _RowAction? _action(PersonalEvent event) {
    if (event.deletedAt != null) return _RowAction.restore;
    if (event.status == EventStatus.cancelled) return _RowAction.reopen;
    return null;
  }
}

enum _RowAction { reopen, restore }
