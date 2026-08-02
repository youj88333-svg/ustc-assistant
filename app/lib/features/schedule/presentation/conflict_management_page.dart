import 'package:flutter/material.dart';

import '../../../core/database/app_database.dart';
import '../application/conflict_service.dart';
import '../application/effective_event_repository.dart';
import '../application/overlay_service.dart';
import '../domain/schedule_grid_item.dart';
import 'conflict_editor.dart';

/// Route payload for `/schedule/conflicts`, carrying the exact overlap group
/// being managed. Only [items] is accepted; any other or missing extras render
/// an empty-state page.
class ConflictManagementRequest {
  const ConflictManagementRequest(this.items);

  final List<ScheduleGridItem> items;
}

/// Loader for `/events/:eventId/conflicts`: resolves the event's overlapping
/// records and maps each through the unified [ScheduleGridItem] shape so the
/// same mixed-safe editor handles all pair types.
class ConflictManagementLoader extends StatelessWidget {
  const ConflictManagementLoader({
    required this.database,
    required this.eventId,
    super.key,
  });

  final AppDatabase database;
  final String eventId;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_ConflictData?>(
      future: _load(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final data = snapshot.data;
        if (data == null || data.items.length < 2) {
          return Scaffold(
            appBar: AppBar(title: const Text('重叠日程')),
            body: const Center(child: Text('没有可处理的重叠日程')),
          );
        }
        return ConflictManagementPage(
          database: database,
          accountId: data.accountId,
          items: data.items,
        );
      },
    );
  }

  Future<_ConflictData?> _load() async {
    final account = await (database.select(
      database.localAccounts,
    )..where((row) => row.isActive.equals(true))).getSingleOrNull();
    if (account == null) return null;
    final repository = EffectiveEventRepository(
      database,
      accountId: account.id,
    );
    final records = await repository.overlappingRecords(eventId);
    return _ConflictData(
      accountId: account.id,
      items: [for (final record in records) repository.gridItemFor(record)],
    );
  }
}

class _ConflictData {
  const _ConflictData({required this.accountId, required this.items});

  final String accountId;
  final List<ScheduleGridItem> items;
}

class ConflictManagementPage extends StatefulWidget {
  const ConflictManagementPage({
    required this.database,
    required this.accountId,
    required this.items,
    super.key,
  });

  final AppDatabase database;
  final String accountId;
  final List<ScheduleGridItem> items;

  @override
  State<ConflictManagementPage> createState() => _ConflictManagementPageState();
}

class _ConflictManagementPageState extends State<ConflictManagementPage> {
  /// Foreground radios are only meaningful when every participant is a
  /// calendar event. PlanBlock participants have no overlay priority, so when
  /// any participant is a PlanBlock the foreground strip is wholly omitted.
  late final bool _hasPlanBlock;
  String? foregroundId;
  late Future<List<ConflictPairDraft>> pairs;

  @override
  void initState() {
    super.initState();
    _hasPlanBlock = widget.items.any(
      (item) => item.kind == ScheduleGridItemKind.planBlock,
    );
    foregroundId = _hasPlanBlock ? null : _defaultForeground();
    pairs = _loadPairs();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('处理重叠日程')),
      body: FutureBuilder<List<ConflictPairDraft>>(
        future: pairs,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return Column(
            children: [
              if (!_hasPlanBlock)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '优先显示',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
              if (!_hasPlanBlock)
                RadioGroup<String>(
                  groupValue: foregroundId,
                  onChanged: (value) {
                    if (value != null) setState(() => foregroundId = value);
                  },
                  child: Column(
                    children: [
                      for (final item in widget.items)
                        RadioListTile<String>(
                          key: Key('foreground-${item.id}'),
                          value: item.id,
                          title: Text(item.title),
                        ),
                    ],
                  ),
                ),
              if (!_hasPlanBlock) const Divider(height: 1),
              Expanded(
                child: ConflictEditor(
                  pairs: snapshot.data!,
                  onBeforeSave: _hasPlanBlock ? null : _saveForeground,
                  onClassify: (left, right, state, {required scope, reason}) =>
                      ConflictService(
                        database: widget.database,
                        accountId: widget.accountId,
                      ).classifyPair(
                        left,
                        right,
                        state,
                        scope: scope,
                        reason: reason,
                      ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  String _defaultForeground() =>
      ([...widget.items]..sort(
            (a, b) => (b.foregroundPriority).compareTo(
              a.foregroundPriority,
            ),
          ))
          .first
          .id;

  Future<List<ConflictPairDraft>> _loadPairs() async {
    final service = ConflictService(
      database: widget.database,
      accountId: widget.accountId,
    );
    final result = <ConflictPairDraft>[];
    for (var leftIndex = 0; leftIndex < widget.items.length; leftIndex++) {
      for (
        var rightIndex = leftIndex + 1;
        rightIndex < widget.items.length;
        rightIndex++
      ) {
        final left = widget.items[leftIndex];
        final right = widget.items[rightIndex];
        final leftParticipant = _participant(left);
        final rightParticipant = _participant(right);
        result.add(
          ConflictPairDraft(
            id: '${left.id}|${right.id}',
            left: leftParticipant,
            right: rightParticipant,
            leftTitle: left.title,
            rightTitle: right.title,
            state: await service.stateForPair(
              leftParticipant,
              rightParticipant,
            ),
          ),
        );
      }
    }
    return result;
  }

  Future<void> _saveForeground() async {
    final overlays = OverlayService(
      database: widget.database,
      accountId: widget.accountId,
    );
    for (final item in widget.items) {
      await overlays.setForegroundPreference(
        item.id,
        item.id == foregroundId ? 100 : 0,
      );
    }
  }

  ScheduleConflictParticipant _participant(ScheduleGridItem item) {
    final occurrence = item.allDay
        ? item.startDate ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
        : item.startAt ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return ScheduleConflictParticipant(
      kind: item.relationKind,
      id: item.id,
      title: item.title,
      occurrenceDate: DateTime(
        occurrence.year,
        occurrence.month,
        occurrence.day,
      ),
      seriesType: item.seriesType,
      seriesId: item.seriesId,
    );
  }
}