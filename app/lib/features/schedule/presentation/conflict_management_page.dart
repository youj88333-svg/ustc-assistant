import 'package:flutter/material.dart';

import '../../../core/database/app_database.dart';
import '../application/conflict_service.dart';
import '../application/effective_event_repository.dart';
import '../application/overlay_service.dart';
import 'conflict_editor.dart';

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
        if (data == null || data.records.length < 2) {
          return Scaffold(
            appBar: AppBar(title: const Text('重叠日程')),
            body: const Center(child: Text('没有可处理的重叠日程')),
          );
        }
        return ConflictManagementPage(
          database: database,
          accountId: data.accountId,
          records: data.records,
        );
      },
    );
  }

  Future<_ConflictData?> _load() async {
    final account = await (database.select(
      database.localAccounts,
    )..where((row) => row.isActive.equals(true))).getSingleOrNull();
    if (account == null) return null;
    final records = await EffectiveEventRepository(
      database,
      accountId: account.id,
    ).overlappingRecords(eventId);
    return _ConflictData(accountId: account.id, records: records);
  }
}

class _ConflictData {
  const _ConflictData({required this.accountId, required this.records});

  final String accountId;
  final List<EffectiveEventRecord> records;
}

class ConflictManagementPage extends StatefulWidget {
  const ConflictManagementPage({
    required this.database,
    required this.accountId,
    required this.records,
    super.key,
  });

  final AppDatabase database;
  final String accountId;
  final List<EffectiveEventRecord> records;

  @override
  State<ConflictManagementPage> createState() => _ConflictManagementPageState();
}

class _ConflictManagementPageState extends State<ConflictManagementPage> {
  late String foregroundId =
      ([...widget.records]..sort(
            (a, b) => (b.foregroundPriority ?? 0).compareTo(
              a.foregroundPriority ?? 0,
            ),
          ))
          .first
          .source
          .id;
  late Future<List<ConflictPairDraft>> pairs = _loadPairs();

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
              RadioGroup<String>(
                groupValue: foregroundId,
                onChanged: (value) {
                  if (value != null) setState(() => foregroundId = value);
                },
                child: Column(
                  children: [
                    for (final record in widget.records)
                      RadioListTile<String>(
                        key: Key('foreground-${record.source.id}'),
                        value: record.source.id,
                        title: Text(record.displayTitle),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ConflictEditor(
                  pairs: snapshot.data!,
                  onBeforeSave: _saveForeground,
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

  Future<List<ConflictPairDraft>> _loadPairs() async {
    final service = ConflictService(
      database: widget.database,
      accountId: widget.accountId,
    );
    final result = <ConflictPairDraft>[];
    for (var leftIndex = 0; leftIndex < widget.records.length; leftIndex++) {
      for (
        var rightIndex = leftIndex + 1;
        rightIndex < widget.records.length;
        rightIndex++
      ) {
        final left = widget.records[leftIndex];
        final right = widget.records[rightIndex];
        final leftParticipant = _participant(left);
        final rightParticipant = _participant(right);
        result.add(
          ConflictPairDraft(
            id: '${left.source.id}|${right.source.id}',
            left: leftParticipant,
            right: rightParticipant,
            leftTitle: left.displayTitle,
            rightTitle: right.displayTitle,
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
    for (final record in widget.records) {
      await overlays.setForegroundPreference(
        record.source.id,
        record.source.id == foregroundId ? 100 : 0,
      );
    }
  }

  ScheduleConflictParticipant _participant(EffectiveEventRecord record) {
    final event = record.source;
    final occurrence = event.allDay
        ? DateTime.parse(event.startDate!)
        : DateTime.fromMillisecondsSinceEpoch(
            event.startAt!,
            isUtc: true,
          ).add(const Duration(hours: 8));
    return ScheduleConflictParticipant(
      kind: 'event',
      id: event.id,
      title: record.displayTitle,
      occurrenceDate: DateTime(
        occurrence.year,
        occurrence.month,
        occurrence.day,
      ),
      seriesType: record.courseSeries == null ? null : 'course_series',
      seriesId: record.courseSeries?.id,
    );
  }
}
