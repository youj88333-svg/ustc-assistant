import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_local_data_gateway.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_tool_registry.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_tools.dart';
import 'package:ustc_assistant_app/features/agent/application/cancellation_signal.dart';
import 'package:ustc_assistant_app/features/agent/application/outbound_privacy_filter.dart';
import 'package:ustc_assistant_app/features/agent/application/run_reference_store.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_tool.dart';
import 'package:ustc_assistant_app/features/schedule/application/conflict_service.dart';
import 'package:ustc_assistant_app/features/schedule/application/effective_event_repository.dart';
import 'package:ustc_assistant_app/features/schedule/application/overlay_service.dart';
import 'package:ustc_assistant_app/features/sync/domain/sync_state.dart';

/// Fixed "now" for deterministic ranges: 2026-07-29 Beijing.
final _now = DateTime(2026, 7, 29, 9, 0);

/// A registry + context wired for the seeded account, using a FixedBeijingClock
/// and the full local-tool payload builders.
class _Harness {
  _Harness(this.gateway, this.accountId, this.references)
    : privacyFilter = OutboundPrivacyFilter(
        protectedAccount: 'PB12345678',
        toolBuilders: agentToolPayloadBuilders(),
      );

  final AgentLocalDataGateway gateway;
  final String accountId;
  final RunReferenceStore references;
  final OutboundPrivacyFilter privacyFilter;

  AgentToolRegistry registry() => AgentToolRegistry(
        tools: localAgentTools(gateway),
        privacyFilter: privacyFilter,
      );

  AgentToolContext context() => AgentToolContext(
        accountId: accountId,
        runId: 'run-test',
        clock: FixedBeijingClock(_now),
        cancellation: CancellationSignal(),
        references: references,
      );

  Future<AgentToolResult> execute(String tool, Map<String, Object?> args) async {
    final result = await registry().execute(
      toolName: tool,
      arguments: args,
      context: context(),
    );
    return result;
  }
}

Future<AppDatabase> _seedDatabase() async {
  final database = AppDatabase(NativeDatabase.memory());
  for (final account in ['a', 'b']) {
    await database.into(database.localAccounts).insert(
          LocalAccountsCompanion.insert(
            id: account,
            maskedHint: 'PB****0000',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
  }

  // --- Schedule events for account 'a' ---
  // Two timed personal events on 2026-07-29 that overlap (conflict), plus a
  // third non-overlapping event. Times are stored as ms-since-epoch in UTC;
  // 09:00 Beijing = 01:00 UTC.
  await _insertTimedEvent(database, 'event-conflict-a', 'a', '风险课程',
      location: '教一101', type: 'course',
      start: DateTime(2026, 7, 29, 9, 0), end: DateTime(2026, 7, 29, 10, 30));
  await _insertTimedEvent(database, 'event-conflict-b', 'a', '青年活动',
      location: '学生活动中心', type: 'personal',
      start: DateTime(2026, 7, 29, 9, 30), end: DateTime(2026, 7, 29, 11, 0));
  await _insertTimedEvent(database, 'event-solo', 'a', '自习',
      location: '图书馆', type: 'personal',
      start: DateTime(2026, 7, 29, 14, 0), end: DateTime(2026, 7, 29, 16, 0));
  // An event outside the default range (2026-08-10) for free-time/range tests.
  await _insertTimedEvent(database, 'event-far', 'a', '远期考试',
      location: '考场', type: 'exam',
      start: DateTime(2026, 8, 10, 10, 0), end: DateTime(2026, 8, 10, 12, 0));
  // An event that has already ended with undecided attendance (pending review).
  await _insertTimedEvent(database, 'event-ended-pending', 'a', '已结束未决定',
      location: '教室', type: 'course',
      start: DateTime(2026, 7, 28, 8, 0), end: DateTime(2026, 7, 28, 9, 30));

  // Classify the overlapping pair as conflict, and a non-overlapping pair as
  // not_conflict (to exercise the relation table). Note the occurrence date.
  final conflict = ConflictService(database: database, accountId: 'a', now: () => 1);
  await conflict.classifyPair(
    EventConflictParticipant(
      eventId: 'event-conflict-a',
      occurrenceDate: DateTime(2026, 7, 29),
    ),
    EventConflictParticipant(
      eventId: 'event-conflict-b',
      occurrenceDate: DateTime(2026, 7, 29),
    ),
    ConflictState.conflict,
    reason: 'time overlap',
  );
  await conflict.classifyPair(
    EventConflictParticipant(
      eventId: 'event-conflict-a',
      occurrenceDate: DateTime(2026, 7, 29),
    ),
    EventConflictParticipant(
      eventId: 'event-solo',
      occurrenceDate: DateTime(2026, 7, 29),
    ),
    ConflictState.nonConflict,
  );

  // Attendance + listening notes on the conflict event via overlay. The
  // attendance decision defaults to undecided (no decision recorded), which is
  // exactly what we want for the conflict event.
  await OverlayService(database: database, accountId: 'a', now: () => 100)
      .setEventOverlay(
        'event-conflict-a',
        const OverlayMutation(
          attendancePolicy: AttendancePolicy.gamble,
          listeningMode: ListeningMode.listen,
          attendanceNote: '节假日前风险高',
          listeningNote: '认真听讲',
        ),
      );
  // The ended event: no attendance decision recorded → undecided → pending.
  await OverlayService(database: database, accountId: 'a', now: () => 100)
      .setEventOverlay(
        'event-ended-pending',
        const OverlayMutation(),
      );

  // --- Tasks for account 'a': active, blocked, completed ---
  await _insertTask(database, 'task-active', 'a', '准备考试',
      state: 'active', importance: 'high',
      deadlineAt: DateTime(2026, 8, 5, 23, 59));
  await _insertTask(database, 'task-blocked', 'a', '注册实验',
      state: 'blocked', importance: 'normal',
      blockedReason: '等待教务开放');
  await _insertTask(database, 'task-completed', 'a', '交作业',
      state: 'completed', importance: 'normal',
      completedAt: 1000);

  // --- Plan blocks for account 'a': one expired-accepted (pending review),
  // one future-accepted, one done ---
  await _insertPlanBlock(database, 'pb-pending', 'a', 'task-active',
      title: '复习第1章',
      start: DateTime(2026, 7, 28, 19, 0), end: DateTime(2026, 7, 28, 21, 0),
      status: 'accepted');
  await _insertPlanBlock(database, 'pb-future', 'a', 'task-active',
      title: '复习第2章',
      start: DateTime(2026, 8, 1, 19, 0), end: DateTime(2026, 8, 1, 21, 0),
      status: 'accepted');
  await _insertPlanBlock(database, 'pb-done', 'a', 'task-active',
      title: '已完成章节',
      start: DateTime(2026, 7, 27, 19, 0), end: DateTime(2026, 7, 27, 21, 0),
      status: 'done', reviewedAt: 1);

  // --- Sync state for account 'a': a successful jw run + source config ---
  await database.into(database.syncRuns).insert(
        SyncRunsCompanion.insert(
          id: 'run-jw-1',
          accountId: 'a',
          source: SyncSource.jw.storage,
          trigger: 'automatic',
          state: 'success',
          startedAt: DateTime(2026, 7, 29, 6, 0).millisecondsSinceEpoch,
        ),
      );
  await database.into(database.sourceConfigs).insert(
        SourceConfigsCompanion.insert(
          id: 'cfg-jw',
          accountId: 'a',
          source: SyncSource.jw.storage,
          lastSuccessAt: Value(
            DateTime(2026, 7, 29, 6, 0).millisecondsSinceEpoch,
          ),
          updatedAt: 1,
        ),
      );
  // young schedule: failed run with a desensitized code.
  await database.into(database.syncRuns).insert(
        SyncRunsCompanion.insert(
          id: 'run-young-1',
          accountId: 'a',
          source: SyncSource.youngSchedule.storage,
          trigger: 'manual',
          state: 'failed',
          resultCode: const Value('collection_failed'),
          startedAt: DateTime(2026, 7, 29, 7, 0).millisecondsSinceEpoch,
        ),
      );
  await database.into(database.sourceConfigs).insert(
        SourceConfigsCompanion.insert(
          id: 'cfg-young',
          accountId: 'a',
          source: SyncSource.youngSchedule.storage,
          updatedAt: 1,
        ),
      );

  // --- Action logs for account 'a' ---
  await database.actionLogsRepository.append(
    accountId: 'a',
    source: 'user',
    actionType: 'task_create',
    result: 'success',
    safeSummary: 'Created a task.',
    occurredAt: DateTime(2026, 7, 29, 8, 0).millisecondsSinceEpoch,
  );
  await database.actionLogsRepository.append(
    accountId: 'a',
    source: 'ustc_jw',
    actionType: 'source_sync',
    result: 'success',
    safeSummary: 'Synced the schedule.',
    occurredAt: DateTime(2026, 7, 29, 6, 0).millisecondsSinceEpoch,
  );
  // A log for account 'b' that must never surface for 'a'.
  await database.actionLogsRepository.append(
    accountId: 'b',
    source: 'user',
    actionType: 'task_create',
    result: 'success',
    safeSummary: 'Account B private action.',
    occurredAt: DateTime(2026, 7, 29, 8, 0).millisecondsSinceEpoch,
  );

  return database;
}

Future<void> _insertTimedEvent(
  AppDatabase database,
  String id,
  String accountId,
  String title, {
  String? location,
  required String type,
  required DateTime start,
  required DateTime end,
}) async {
  await database.into(database.calendarEvents).insert(
        CalendarEventsCompanion.insert(
          id: id,
          accountId: accountId,
          source: 'user',
          title: title,
          type: type,
          startAt: Value(start.toUtc().millisecondsSinceEpoch),
          endAt: Value(end.toUtc().millisecondsSinceEpoch),
          allDay: false,
          timezone: 'Asia/Shanghai',
          locationName: Value(location),
          createdAt: 1,
          updatedAt: 1,
        ),
      );
}

Future<void> _insertTask(
  AppDatabase database,
  String id,
  String accountId,
  String title, {
  required String state,
  required String importance,
  String? blockedReason,
  DateTime? deadlineAt,
  int? completedAt,
}) async {
  await database.into(database.tasks).insert(
        TasksCompanion.insert(
          id: id,
          accountId: accountId,
          title: title,
          state: state,
          importance: importance,
          blockedReason: Value(blockedReason),
          deadlineAt: Value(deadlineAt?.toUtc().millisecondsSinceEpoch),
          tagsJson: '[]',
          completedAt: Value(completedAt),
          createdAt: 1,
          updatedAt: 1,
        ),
      );
}

Future<void> _insertPlanBlock(
  AppDatabase database,
  String id,
  String accountId,
  String taskId, {
  String? title,
  required DateTime start,
  required DateTime end,
  required String status,
  int? reviewedAt,
}) async {
  await database.into(database.planBlocks).insert(
        PlanBlocksCompanion.insert(
          id: id,
          accountId: accountId,
          taskId: taskId,
          title: Value(title),
          startAt: start.toUtc().millisecondsSinceEpoch,
          endAt: end.toUtc().millisecondsSinceEpoch,
          status: status,
          reviewedAt: Value(reviewedAt),
          createdAt: 1,
          updatedAt: 1,
        ),
      );
}

_Harness _harness(AppDatabase database, String accountId) {
  final gateway = DriftAgentLocalDataGateway(database);
  final references = RunReferenceStore(runId: 'run-$accountId');
  return _Harness(gateway, accountId, references);
}

void main() {
  late AppDatabase database;

  setUp(() async {
    database = await _seedDatabase();
  });
  tearDown(() async => database.close());

  group('get_schedule', () {
    test('returns normalized events, no raw ids, conflict + attendance note',
        () async {
      final harness = _harness(database, 'a');
      // The event DB id that must NEVER appear in the model payload.
      const eventDatabaseId = 'event-conflict-a';

      final result = await harness.execute('get_schedule', {
        'from': '2026-07-29',
        'through': '2026-08-04',
      });

      expect(result.status, AgentToolStatus.success);
      final encoded = jsonEncode(result.payload);
      // SECURITY: the raw event DB id must not leak into the model payload.
      expect(encoded, isNot(contains(eventDatabaseId)));
      // Only ref_* tokens appear as identifiers.
      expect(encoded, contains('ref_'));

      final events = result.payload['events']! as List;
      // The conflict event should be first (starts at 09:00).
      final first = events.first! as Map<String, Object?>;
      expect(first, containsPair('attendanceNote', '节假日前风险高'));
      expect(first, containsPair('conflictState', 'conflict'));
      expect(first['ref'], startsWith('ref_'));
      expect(first['title'], '风险课程');
      expect(first['location'], '教一101');
      expect(first['startAt'], '2026-07-29T09:00:00');
    });

    test('default range is 7 days including today', () async {
      final harness = _harness(database, 'a');
      final result = await harness.execute('get_schedule', {});
      expect(result.status, AgentToolStatus.success);
      expect(result.payload['from'], '2026-07-29');
      expect(result.payload['through'], '2026-08-04');
    });

    test('rejects reversed ranges with invalid_range', () async {
      final harness = _harness(database, 'a');
      final result = await harness.execute('get_schedule', {
        'from': '2026-08-04',
        'through': '2026-07-29',
      });
      expect(result.status, AgentToolStatus.error);
      expect(result.errorCode, 'invalid_range');
    });

    test('rejects ranges over 31 days with range_too_large', () async {
      final harness = _harness(database, 'a');
      final result = await harness.execute('get_schedule', {
        'from': '2026-07-01',
        'through': '2026-08-04',
      });
      expect(result.status, AgentToolStatus.error);
      expect(result.errorCode, 'range_too_large');
    });

    test('account b sees none of account a events', () async {
      final harness = _harness(database, 'b');
      final result = await harness.execute('get_schedule', {
        'from': '2026-07-29',
        'through': '2026-08-04',
      });
      expect(result.status, AgentToolStatus.success);
      final events = result.payload['events']! as List;
      expect(events, isEmpty);
    });

    test('result_too_large when events exceed the limit', () async {
      // Seed > 200 events for account 'b' on the default-range day.
      for (var i = 0; i < 201; i++) {
        await _insertTimedEvent(
          database,
          'b-event-$i',
          'b',
          'E$i',
          type: 'personal',
          start: DateTime(2026, 7, 29, 7, 50).add(Duration(minutes: i)),
          end: DateTime(2026, 7, 29, 7, 51).add(Duration(minutes: i)),
        );
      }
      final harness = _harness(database, 'b');
      final result = await harness.execute('get_schedule', {});
      expect(result.status, AgentToolStatus.error);
      expect(result.errorCode, 'result_too_large');
      expect(result.payload['guidance'], isNotNull);
    });
  });

  group('get_event_details', () {
    test('resolves a ref to full attendance/listening/notes, no raw id',
        () async {
      final harness = _harness(database, 'a');
      // First call get_schedule to bind the ref.
      final schedule = await harness.execute('get_schedule', {
        'from': '2026-07-29',
        'through': '2026-08-04',
      });
      final events = schedule.payload['events']! as List;
      final conflictRef =
          (events.first! as Map<String, Object?>)['ref']! as String;

      final result = await harness.execute('get_event_details', {
        'ref': conflictRef,
      });
      expect(result.status, AgentToolStatus.success);
      final encoded = jsonEncode(result.payload);
      expect(encoded, isNot(contains('event-conflict-a')));
      expect(result.payload['attendanceNote'], '节假日前风险高');
      expect(result.payload['listeningNote'], '认真听讲');
      expect(result.payload['listeningMode'], 'listen');
      expect(result.payload['attendancePolicy'], 'gamble');
      expect(result.payload['attendanceDecision'], 'undecided');
      expect(result.payload['conflictState'], 'conflict');
    });

    test('unknown ref returns reference_not_found', () async {
      final harness = _harness(database, 'a');
      final result = await harness.execute('get_event_details', {
        'ref': 'ref_unknown',
      });
      expect(result.status, AgentToolStatus.error);
      expect(result.errorCode, 'reference_not_found');
    });
  });

  group('get_free_time', () {
    test('unions occupied intervals and reports gaps, no conflict invention',
        () async {
      final harness = _harness(database, 'a');
      final result = await harness.execute('get_free_time', {
        'from': '2026-07-29',
        'through': '2026-07-29',
      });
      expect(result.status, AgentToolStatus.success);
      final gaps = result.payload['gaps']! as List;
      // Day grid 07:00-24:00. Occupied: 09:00-10:30, 09:30-11:00 (union
      // 09:00-11:00), 14:00-16:00. So gaps: 07:00-09:00, 11:00-14:00,
      // 16:00-24:00.
      final starts = gaps
          .map((g) => (g! as Map<String, Object?>)['startAt'] as String)
          .toList();
      expect(starts, containsAll(['2026-07-29T07:00:00', '2026-07-29T11:00:00', '2026-07-29T16:00:00']));
      // No conflict classification on free-time output.
      final encoded = jsonEncode(result.payload);
      expect(encoded, isNot(contains('conflictState')));
      expect(encoded, isNot(contains('"conflict"')));
    });
  });

  group('get_pending_event_reviews', () {
    test('lists ended events with undecided attendance', () async {
      final harness = _harness(database, 'a');
      final result = await harness.execute('get_pending_event_reviews', {});
      expect(result.status, AgentToolStatus.success);
      final pending = result.payload['pending']! as List;
      // The 2026-07-28 event with undecided attendance is pending.
      final titles = pending
          .map((p) => (p! as Map<String, Object?>)['title'] as String)
          .toSet();
      expect(titles, contains('已结束未决定'));
      final encoded = jsonEncode(result.payload);
      expect(encoded, isNot(contains('event-ended-pending')));
    });
  });

  group('get_conflicts', () {
    test('lists only confirmed-conflict events in range', () async {
      final harness = _harness(database, 'a');
      final result = await harness.execute('get_conflicts', {
        'from': '2026-07-29',
        'through': '2026-08-04',
      });
      expect(result.status, AgentToolStatus.success);
      final conflicts = result.payload['conflicts']! as List;
      // Both members of the conflict pair are flagged.
      final titles = conflicts
          .map((c) => (c! as Map<String, Object?>)['title'] as String)
          .toSet();
      expect(titles, containsAll(['风险课程', '青年活动']));
      for (final c in conflicts) {
        expect((c! as Map<String, Object?>)['conflictState'], 'conflict');
      }
      final encoded = jsonEncode(result.payload);
      expect(encoded, isNot(contains('event-conflict-a')));
      expect(encoded, isNot(contains('event-conflict-b')));
    });
  });

  group('get_tasks', () {
    test('returns tasks with projectTask-derived states, no raw ids', () async {
      final harness = _harness(database, 'a');
      final result = await harness.execute('get_tasks', {});
      expect(result.status, AgentToolStatus.success);
      final tasks = result.payload['tasks']! as List;
      final byTitle = {
        for (final t in tasks)
          (t! as Map<String, Object?>)['title'] as String: t,
      };
      expect(byTitle.keys, containsAll(['准备考试', '注册实验', '交作业']));
      final active = byTitle['准备考试']! as Map<String, Object?>;
      expect(active['state'], 'active');
      expect(active['importance'], 'high');
      // projectTask: has future-accepted plan block → planned; deadline
      // 2026-08-05 is upcoming (now 2026-07-29).
      expect(active['planning'], 'planned');
      expect(active['deadline'], 'upcoming');
      // There is an elapsed-accepted block → awaiting review.
      expect(active['confirmation'], 'awaitingPlanBlockReview');
      expect(active['ref'], startsWith('ref_'));
      final blocked = byTitle['注册实验']! as Map<String, Object?>;
      expect(blocked['state'], 'blocked');
      expect(blocked['blockedReason'], '等待教务开放');
      final completed = byTitle['交作业']! as Map<String, Object?>;
      expect(completed['state'], 'completed');
      expect(completed['deadline'], 'notApplicable');
      final encoded = jsonEncode(result.payload);
      expect(encoded, isNot(contains('task-active')));
      expect(encoded, isNot(contains('task-blocked')));
    });

    test('state filter narrows the list', () async {
      final harness = _harness(database, 'a');
      final result = await harness.execute('get_tasks', {'state': 'blocked'});
      final tasks = result.payload['tasks']! as List;
      expect(tasks, hasLength(1));
      expect(
        (tasks.first! as Map<String, Object?>)['title'],
        '注册实验',
      );
    });

    test('account b sees none of account a tasks', () async {
      final harness = _harness(database, 'b');
      final result = await harness.execute('get_tasks', {});
      final tasks = result.payload['tasks']! as List;
      expect(tasks, isEmpty);
    });
  });

  group('get_task_details', () {
    test('resolves a task ref to details + plan blocks', () async {
      final harness = _harness(database, 'a');
      final list = await harness.execute('get_tasks', {});
      final tasks = list.payload['tasks']! as List;
      final activeRef = (tasks
              .firstWhere((t) =>
                  (t! as Map<String, Object?>)['title'] == '准备考试')
              as Map<String, Object?>)['ref']! as String;

      final result = await harness.execute('get_task_details', {
        'ref': activeRef,
      });
      expect(result.status, AgentToolStatus.success);
      final blocks = result.payload['planBlocks']! as List;
      expect(blocks, hasLength(3));
      final encoded = jsonEncode(result.payload);
      expect(encoded, isNot(contains('task-active')));
      expect(encoded, isNot(contains('pb-pending')));
    });

    test('unknown task ref returns reference_not_found', () async {
      final harness = _harness(database, 'a');
      final result = await harness.execute('get_task_details', {
        'ref': 'ref_nope',
      });
      expect(result.status, AgentToolStatus.error);
      expect(result.errorCode, 'reference_not_found');
    });
  });

  group('get_plan_blocks', () {
    test('lists all plan blocks with awaiting-review flags', () async {
      final harness = _harness(database, 'a');
      final result = await harness.execute('get_plan_blocks', {});
      expect(result.status, AgentToolStatus.success);
      final blocks = result.payload['planBlocks']! as List;
      // The expired-accepted block is awaiting review; future-accepted and
      // done are not.
      final byTitle = {
        for (final b in blocks)
          (b! as Map<String, Object?>)['title'] as String: b,
      };
      expect((byTitle['复习第1章']! as Map<String, Object?>)['awaitingReview'],
          true);
      expect((byTitle['复习第2章']! as Map<String, Object?>)['awaitingReview'],
          false);
      expect((byTitle['已完成章节']! as Map<String, Object?>)['awaitingReview'],
          false);
      final encoded = jsonEncode(result.payload);
      expect(encoded, isNot(contains('pb-pending')));
    });
  });

  group('get_pending_planblock_reviews', () {
    test('lists only elapsed accepted blocks', () async {
      final harness = _harness(database, 'a');
      final result = await harness
          .execute('get_pending_planblock_reviews', {});
      expect(result.status, AgentToolStatus.success);
      final pending = result.payload['pending']! as List;
      expect(pending, hasLength(1));
      final block = pending.first! as Map<String, Object?>;
      expect(block['title'], '复习第1章');
      expect(block['status'], 'accepted');
      expect(block['taskRef'], startsWith('ref_'));
      final encoded = jsonEncode(result.payload);
      expect(encoded, isNot(contains('pb-pending')));
    });
  });

  group('get_sync_status', () {
    test('reports per-source phase and desensitized codes, never starts sync',
        () async {
      final harness = _harness(database, 'a');
      final result = await harness.execute('get_sync_status', {});
      expect(result.status, AgentToolStatus.success);
      final sources = result.payload['sources']! as List;
      final bySource = {
        for (final s in sources)
          (s! as Map<String, Object?>)['source'] as String: s,
      };
      expect(bySource.keys, containsAll([SyncSource.jw.storage, SyncSource.youngSchedule.storage]));
      final jw = bySource[SyncSource.jw.storage]! as Map<String, Object?>;
      expect(jw['phase'], 'succeeded');
      expect(jw['lastSuccessfulAt'], '2026-07-29T06:00:00');
      final young =
          bySource[SyncSource.youngSchedule.storage]! as Map<String, Object?>;
      expect(young['phase'], 'failed');
      expect(young['resultCode'], 'collection_failed');
    });

    test('account b sees idle/empty sync state', () async {
      final harness = _harness(database, 'b');
      final result = await harness.execute('get_sync_status', {});
      final sources = result.payload['sources']! as List;
      for (final s in sources) {
        expect((s! as Map<String, Object?>)['phase'], 'idle');
      }
    });
  });

  group('get_safe_action_history', () {
    test('returns only safe summaries, account-scoped, capped at 50', () async {
      final harness = _harness(database, 'a');
      final result = await harness.execute('get_safe_action_history', {});
      expect(result.status, AgentToolStatus.success);
      final history = result.payload['history']! as List;
      // Account 'a' logs include the two we appended plus logs written by the
      // overlay/conflict services during seeding. Account 'b's private log
      // must never surface.
      final summaries = history
          .map((h) => (h! as Map<String, Object?>)['safeSummary'] as String)
          .toList();
      expect(summaries, containsAll(['Created a task.', 'Synced the schedule.']));
      expect(summaries, isNot(contains('Account B private action.')));
      for (final h in history) {
        final entry = h! as Map<String, Object?>;
        // Only the necessary categories + safeSummary, no raw params.
        expect(
          entry.keys,
          containsAll([
            'source',
            'actionType',
            'result',
            'safeSummary',
            'occurredAt',
          ]),
        );
      }
    });

    test('caps at 50 entries', () async {
      for (var i = 0; i < 60; i++) {
        await database.actionLogsRepository.append(
          accountId: 'a',
          source: 'user',
          actionType: 'task_create',
          result: 'success',
          safeSummary: 'Op $i.',
          occurredAt: 1000 + i,
        );
      }
      final harness = _harness(database, 'a');
      final result = await harness.execute('get_safe_action_history', {});
      final history = result.payload['history']! as List;
      expect(history, hasLength(50));
    });
  });
}
