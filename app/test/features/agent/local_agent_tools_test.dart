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
  String source = 'user',
  String? seriesExternalId,
  String? externalId,
  String status = 'active',
}) async {
  await database.into(database.calendarEvents).insert(
        CalendarEventsCompanion.insert(
          id: id,
          accountId: accountId,
          source: source,
          externalId: Value(externalId),
          sourceSeriesExternalId: Value(seriesExternalId),
          title: title,
          type: type,
          startAt: Value(start.toUtc().millisecondsSinceEpoch),
          endAt: Value(end.toUtc().millisecondsSinceEpoch),
          allDay: false,
          timezone: 'Asia/Shanghai',
          locationName: Value(location),
          status: Value(status),
          createdAt: 1,
          updatedAt: 1,
        ),
      );
}

/// Inserts a course-series row for [accountId]. The [participantsJson] is a
/// JSON list of `{role, name}` objects (matching the import fixture shape).
Future<void> _insertCourseSeries(
  AppDatabase database,
  String id,
  String accountId, {
  required String source,
  required String externalId,
  required String title,
  String semesterKey = '2026spring',
  String participantsJson = '[]',
}) async {
  await database.into(database.courseSeries).insert(
        CourseSeriesCompanion.insert(
          id: id,
          accountId: accountId,
          source: source,
          externalId: externalId,
          title: title,
          semesterKey: semesterKey,
          participantsJson: Value(participantsJson),
          sourceDetailsJson: '{}',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
}

/// Inserts a `source_records` row marking [localEntityId] as present for
/// [accountId]/[source]. Required for non-`user`-source events to appear in
/// `EffectiveEventRepository.watchDisplayEvents` (which filters out events
/// with no present source record).
Future<void> _insertSourceRecord(
  AppDatabase database,
  String accountId, {
  required String source,
  required String externalId,
  required String localEntityId,
}) async {
  await database.into(database.sourceRecords).insert(
        SourceRecordsCompanion.insert(
          id: 'sr-$localEntityId',
          accountId: accountId,
          source: source,
          entityType: 'calendar_event',
          externalId: externalId,
          localEntityId: localEntityId,
          sourceStatus: 'active',
          presence: 'present',
          scopeKey: 'scope',
          firstObservedAt: 1,
          lastObservedAt: 1,
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

/// Seeds the account-level default JW semester into `source_configs` (the
/// same table [SettingsService.setJwSemesterOverride]) writes to. The query
/// mode must ignore this setting entirely: events are matched by title across
/// ALL retained history, not by the configured default semester.
class SeedSettings {
  static Future<void> defaultJwSemester(
    AppDatabase database,
    String accountId, {
    required int semesterId,
    required String semesterKey,
    required String displayName,
  }) async {
    // Remove any existing ustc_jw config (the shared seed inserts one for 'a'
// with a different id) so the unique (accountId, source) key is free.
await (database.delete(database.sourceConfigs)
      ..where((row) => row.accountId.equals(accountId) &
          row.source.equals('ustc_jw')))
    .go();
await database.into(database.sourceConfigs).insert(
      SourceConfigsCompanion.insert(
        id: '$accountId:ustc_jw',
        accountId: accountId,
        source: 'ustc_jw',
        enabled: const Value(true),
        configJson: Value(
          jsonEncode({
            'semesterId': semesterId,
            'semesterKey': semesterKey,
            'displayName': displayName,
          }),
        ),
        lastSuccessAt: const Value(null),
        retryAfter: const Value(null),
        updatedAt: 1,
      ),
    );
  }
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

    // Regression: 201 out-of-range events plus one requested-range event must
    // NOT return result_too_large. The 200-limit must apply to IN-RANGE events
    // (already post-filter), not to all events.
    test(
      '201 out-of-range events plus one in-range event is not result_too_large',
      () async {
        // 201 events far outside the requested range (August 10).
        for (var i = 0; i < 201; i++) {
          await _insertTimedEvent(
            database,
            'b-far-$i',
            'b',
            'Far$i',
            type: 'personal',
            start: DateTime(2026, 8, 10, 7, 50).add(Duration(minutes: i)),
            end: DateTime(2026, 8, 10, 7, 51).add(Duration(minutes: i)),
          );
        }
        // One event in the requested range.
        await _insertTimedEvent(
          database,
          'b-in',
          'b',
          'InRange',
          type: 'personal',
          start: DateTime(2026, 7, 29, 9, 0),
          end: DateTime(2026, 7, 29, 10, 0),
        );
        final harness = _harness(database, 'b');
        final result = await harness.execute('get_schedule', {
          'from': '2026-07-29',
          'through': '2026-07-29',
        });
        expect(result.status, AgentToolStatus.success);
        final events = result.payload['events']! as List;
        expect(events, hasLength(1));
        expect(
          (events.first! as Map<String, Object?>)['title'],
          'InRange',
        );
      },
    );

    // Regression: 2026-02-31 must be rejected as invalid_range (DateTime
    // normalizes overflow, so round-trip year/month/day must be verified).
    test('rejects 2026-02-31 as invalid_range', () async {
      final harness = _harness(database, 'a');
      final result = await harness.execute('get_schedule', {
        'from': '2026-02-31',
        'through': '2026-02-28',
      });
      expect(result.status, AgentToolStatus.error);
      expect(result.errorCode, 'invalid_range');
    });

    test('rejects 2026-02-30 as invalid_range', () async {
      final harness = _harness(database, 'a');
      final result = await harness.execute('get_schedule', {
        'from': '2026-02-30',
        'through': '2026-02-28',
      });
      expect(result.status, AgentToolStatus.error);
      expect(result.errorCode, 'invalid_range');
    });

    // Regression: a 2026 spring grouped summary must return course groups
    // under 200 items even when there are many occurrences. The 200-limit
    // applies AFTER grouping in summary mode. Semester is derived from the
    // series metadata, never hardcoded.
    test(
      'course_summary mode groups 2026 spring occurrences under 200 items',
      () async {
        // Seed a course series for 2026 spring with two teachers.
        await _insertCourseSeries(
          database,
          'series-math',
          'a',
          source: 'ustc_jw',
          externalId: 'lesson-math',
          title: '线性代数',
          semesterKey: '2026spring',
          participantsJson:
              '[{"role":"teacher","name":"张老师"},{"role":"teacher","name":"李老师"}]',
        );
        // 10 occurrences of the same course within Feb 2026 (Mon/Wed pattern).
        // They should collapse to ONE group.
        final mathDays = [2, 4, 9, 11, 16, 18, 23, 25, 27];
        for (var i = 0; i < mathDays.length; i++) {
          final day = mathDays[i];
          await _insertTimedEvent(
            database,
            'math-occ-$i',
            'a',
            '线性代数',
            source: 'ustc_jw',
            externalId: 'math-occ-$i',
            seriesExternalId: 'lesson-math',
            type: 'course',
            location: '三教101',
            start: DateTime(2026, 2, day, 8, 40),
            end: DateTime(2026, 2, day, 9, 25),
          );
          await _insertSourceRecord(
            database,
            'a',
            source: 'ustc_jw',
            externalId: 'math-occ-$i',
            localEntityId: 'math-occ-$i',
          );
        }
        // A second course series in the same semester → a second group.
        await _insertCourseSeries(
          database,
          'series-phys',
          'a',
          source: 'ustc_jw',
          externalId: 'lesson-phys',
          title: '大学物理',
          semesterKey: '2026spring',
          participantsJson: '[{"role":"teacher","name":"王老师"}]',
        );
        await _insertTimedEvent(
          database,
          'phys-occ-0',
          'a',
          '大学物理',
          source: 'ustc_jw',
          externalId: 'phys-occ-0',
          seriesExternalId: 'lesson-phys',
          type: 'course',
          location: '四教202',
          start: DateTime(2026, 2, 10, 10, 35),
          end: DateTime(2026, 2, 10, 11, 20),
        );
        await _insertSourceRecord(
          database,
          'a',
          source: 'ustc_jw',
          externalId: 'phys-occ-0',
          localEntityId: 'phys-occ-0',
        );

        final harness = _harness(database, 'a');
        final result = await harness.execute('get_schedule', {
          'from': '2026-02-01',
          'through': '2026-02-28',
          'view': 'course_summary',
        });
        expect(result.status, AgentToolStatus.success);
        final groups = result.payload['groups']! as List;
        // Two courses → two groups, well under the 200 limit.
        expect(groups.length, lessThanOrEqualTo(200));
        expect(groups, hasLength(2));
        final byTitle = {
          for (final g in groups)
            (g! as Map<String, Object?>)['title'] as String: g,
        };
        expect(byTitle.keys, containsAll(['线性代数', '大学物理']));
        final math = byTitle['线性代数']! as Map<String, Object?>;
        // Teachers derived from CourseSery.participantsJson.
        expect(math['teachers'], ['张老师', '李老师']);
        // Distinct locations.
        expect(math['locations'], ['三教101']);
        // Occurrence count.
        expect(math['occurrenceCount'], mathDays.length);
        // Active date range over in-range occurrences.
        expect(math['activeFrom'], isNotNull);
        expect(math['activeThrough'], isNotNull);
        // Weekday/period patterns present.
        expect(math['patterns'], isA<List>());
        // SECURITY: no raw local ids or semester literals leak.
        final encoded = jsonEncode(result.payload);
        expect(encoded, isNot(contains('series-math')));
        expect(encoded, isNot(contains('lesson-math')));
        expect(encoded, isNot(contains('2026spring')));
        // The summary contributes NO per-event refs (it is a summary).
        expect(result.references, isEmpty);
      },
    );

    test(
      'course_summary mode with 241 occurrences of one course yields one group',
      () async {
        // 241 occurrences of one course — would blow the 200 limit in events
        // mode, but in summary mode it collapses to a single group. Spread
        // 8 per day across Jan 1-30, 2026 (240) plus one more, all within a
        // 31-day range so the range itself is valid.
        await _insertCourseSeries(
          database,
          'series-big',
          'a',
          source: 'ustc_jw',
          externalId: 'lesson-big',
          title: '大课',
          semesterKey: '2026spring',
        );
        for (var i = 0; i < 241; i++) {
          final id = 'big-occ-$i';
          // 8 occurrences per day, each 30 min apart, across 30 days + 1.
          final day = (i ~/ 8) + 1;
          final slot = i % 8;
          await _insertTimedEvent(
            database,
            id,
            'a',
            '大课',
            source: 'ustc_jw',
            externalId: id,
            seriesExternalId: 'lesson-big',
            type: 'course',
            start: DateTime(2026, 1, day, 8, 0 + slot * 30),
            end: DateTime(2026, 1, day, 8, 25 + slot * 30),
          );
          await _insertSourceRecord(
            database,
            'a',
            source: 'ustc_jw',
            externalId: id,
            localEntityId: id,
          );
        }
        final harness = _harness(database, 'a');
        final result = await harness.execute('get_schedule', {
          'from': '2026-01-01',
          'through': '2026-01-31',
          'view': 'course_summary',
        });
        expect(result.status, AgentToolStatus.success);
        final groups = result.payload['groups']! as List;
        expect(groups, hasLength(1));
        expect(
          (groups.first! as Map<String, Object?>)['occurrenceCount'],
          241,
        );
      },
    );
  });

  group('get_schedule query mode', () {
    // Seeding shared by the query-mode tests: a default-semester setting that
    // is UNRELATED to the event dates, March + August same-title events for
    // account 'a', an other-account match, and hidden/cancelled/missing-source
    // decoys — all concrete schedule locations independent of the default
    // semester.
    Future<void> seed(String account) async {
      // An unrelated default JW semester (421 = 2026spring). The query mode
      // must NOT read, receive, or infer this — the events below are in March
      // (2026spring) and August (2026fall), so a semester-blind title search is
      // required to find them.
      await SeedSettings.defaultJwSemester(database, account,
          semesterId: 421, semesterKey: '2026spring',
          displayName: '2025-2026学年春季学期');
      // Two March (2026spring) occurrences with the SAME title but distinct
      // date/time/location → same-title candidates surfaced for the user.
      await _insertTimedEvent(database, '$account-q-mar-a', account, '计算机网络',
          location: '三教101', type: 'course',
          start: DateTime(2026, 3, 2, 8, 40), end: DateTime(2026, 3, 2, 9, 25));
      await _insertTimedEvent(database, '$account-q-mar-b', account, '计算机网络',
          location: '三教201', type: 'course',
          start: DateTime(2026, 3, 4, 10, 35), end: DateTime(2026, 3, 4, 11, 20));
      // An August (2026fall) occurrence, outside the default semester.
      await _insertTimedEvent(database, '$account-q-aug', account, '计算机网络',
          location: '四教102', type: 'course',
          start: DateTime(2026, 8, 14, 14, 0), end: DateTime(2026, 8, 14, 15, 40));
      // A case-variant + whitespace title: '  计算机 网络  ' won't case-fold
      // matter for CJK but exercises trim matching (this one must NOT match the
      // exact title query '计算机网络' since the space splits it).
      await _insertTimedEvent(database, '$account-q-other', account, '自习安排',
          location: '图书馆', type: 'personal',
          start: DateTime(2026, 7, 30, 9, 0), end: DateTime(2026, 7, 30, 10, 0));
      // Account 'b' match — must NEVER surface for 'a'.
      if (account == 'b') {
        await _insertTimedEvent(database, 'b-q-b', 'b', '计算机网络',
            location: '五教', type: 'course',
            start: DateTime(2026, 3, 6, 8, 0), end: DateTime(2026, 3, 6, 9, 0));
      }
      // Decoys that must be filtered out: hidden, cancelled, and missing-source.
      await database.into(database.calendarEvents).insert(
            CalendarEventsCompanion.insert(
              id: '$account-q-hidden',
              accountId: account,
              source: 'user',
              externalId: Value('$account-q-hidden'),
              title: '计算机网络',
              type: 'course',
              startAt: Value(DateTime(2026, 3, 3, 8, 0).toUtc().millisecondsSinceEpoch),
              endAt: Value(DateTime(2026, 3, 3, 9, 0).toUtc().millisecondsSinceEpoch),
              allDay: false,
              timezone: 'Asia/Shanghai',
              locationName: Value('已隐藏'),
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await database.into(database.userOverlays).insert(
            UserOverlaysCompanion.insert(
              id: '$account-q-hidden-overlay',
              accountId: account,
              eventId: Value('$account-q-hidden'),
              hidden: Value(true),
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await _insertTimedEvent(database, '$account-q-cancelled', account, '计算机网络',
          location: '已取消', type: 'course',
          start: DateTime(2026, 3, 5, 8, 0), end: DateTime(2026, 3, 5, 9, 0),
          status: 'cancelled');
      // A missing-source course event: present in calendar_events but with NO
      // source record → excluded by watchDisplayEvents.
      await _insertTimedEvent(database, '$account-q-missing', account, '计算机网络',
          location: '无来源', type: 'course', source: 'ustc_jw',
          externalId: '$account-q-missing',
          start: DateTime(2026, 3, 7, 8, 0), end: DateTime(2026, 3, 7, 9, 0));
    }

    test(
      'title query returns only same-account valid occurrences with no '
      'semester key/id in input or payload',
      () async {
        await seed('a');
        // Also seed an account-'b' match so we can assert cross-account
        // isolation in the same test.
        await seed('b');
        final harness = _harness(database, 'a');
        final result = await harness.execute('get_schedule', {
          'query': '计算机网络',
        });
        expect(result.status, AgentToolStatus.success);
        final events = result.payload['events']! as List;
        // Only the same-account valid matches: two March + one August.
        expect(events, hasLength(3));
        final titles =
            events.map((e) => (e! as Map<String, Object?>)['title']).toList();
        for (final t in titles) {
          expect(t, '计算机网络');
        }
        // No cross-account 'b' match leaked in.
        for (final e in events) {
          final raw = e! as Map<String, Object?>;
          expect(raw['location'], isNot('五教'));
        }
        // All three carry concrete run-local refs.
        for (final e in events) {
          expect((e! as Map<String, Object?>)['ref'], startsWith('ref_'));
        }
        // SECURITY: no semester key/id in the payload, and no raw local event
        // ids.
        final encoded = jsonEncode(result.payload);
        expect(encoded, isNot(contains('semester')));
        expect(encoded, isNot(contains('2026spring')));
        expect(encoded, isNot(contains('421')));
        expect(encoded, isNot(contains('a-q-mar-a')));
        // The input had no semester parameter (the tool schema has none and the
        // execute path never reads one).
        expect(result.payload.containsKey('semester'), isFalse);
        // Current/future (>= now 2026-07-29) ascending, then past descending:
        // the single August (future) match comes first, then the two past March
        // matches most-recent-first.
        final first = events.first! as Map<String, Object?>;
        expect(first['location'], '四教102');
        final pasts = events.skip(1).map((e) => (e! as Map<String, Object?>)['location']).toList();
        expect(pasts, ['三教201', '三教101']);
      },
    );

    test('title query with dates filters inside the range', () async {
      await seed('a');
      final harness = _harness(database, 'a');
      final result = await harness.execute('get_schedule', {
        'query': '计算机网络',
        'from': '2026-08-01',
        'through': '2026-08-31',
      });
      expect(result.status, AgentToolStatus.success);
      final events = result.payload['events']! as List;
      expect(events, hasLength(1));
      expect((events.first! as Map<String, Object?>)['location'], '四教102');
      expect(result.payload['from'], '2026-08-01');
      expect(result.payload['through'], '2026-08-31');
    });

    test('query + course_summary returns invalid_arguments', () async {
      await seed('a');
      final harness = _harness(database, 'a');
      final result = await harness.execute('get_schedule', {
        'query': '计算机网络',
        'view': 'course_summary',
      });
      expect(result.status, AgentToolStatus.error);
      expect(result.errorCode, 'invalid_arguments');
      expect(result.payload['guidance'], isNotNull);
    });

    test('21+ matches returns result_too_large with date-narrowing guidance',
        () async {
      for (var i = 0; i < 21; i++) {
        await _insertTimedEvent(database, 'b-dup-$i', 'b', '高数$i',
            type: 'personal',
            start: DateTime(2026, 3, 1, 8, 0).add(Duration(minutes: i)),
            end: DateTime(2026, 3, 1, 8, 30).add(Duration(minutes: i)));
      }
      final harness = _harness(database, 'b');
      final result = await harness.execute('get_schedule', {
        'query': '高数',
      });
      expect(result.status, AgentToolStatus.error);
      expect(result.errorCode, 'result_too_large');
      expect(
        result.payload['guidance'],
        contains('provide from/through dates'),
      );
    });

    test('hidden/cancelled/missing-source same-title events are filtered out',
        () async {
      await seed('a');
      final harness = _harness(database, 'a');
      final result = await harness.execute('get_schedule', {
        'query': '计算机网络',
      });
      expect(result.status, AgentToolStatus.success);
      final locations = (result.payload['events']! as List)
          .map((e) => (e! as Map<String, Object?>)['location'])
          .toSet();
      expect(locations, isNot(contains('已隐藏')));
      expect(locations, isNot(contains('已取消')));
      expect(locations, isNot(contains('无来源')));
    });

    test('no matching title returns an empty events list', () async {
      await seed('a');
      final harness = _harness(database, 'a');
      final result = await harness.execute('get_schedule', {
        'query': '不存在的课程',
      });
      expect(result.status, AgentToolStatus.success);
      expect(result.payload['events']! as List, isEmpty);
    });

    test('view=course_summary stays unchanged with no query', () async {
      await seed('a');
      final harness = _harness(database, 'a');
      final result = await harness.execute('get_schedule', {
        'view': 'course_summary',
      });
      expect(result.status, AgentToolStatus.success);
      // Still returns groups (not invalid_arguments), spanning the default
      // range. This confirms no-query course_summary behavior is unchanged.
      expect(result.payload.containsKey('groups'), isTrue);
      expect(result.payload['groups']! as List, isNotEmpty);
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

    // Regression: a 23:00-08:00 event (spanning midnight) must block the
    // next morning's 07:00-08:00 slot. The old per-day logic filtered events
    // by startAt same-day only, missing the overnight overlap.
    test(
      '23:00-08:00 overnight event blocks next-day 07:00-08:00 slot',
      () async {
        // An event from 2026-07-29 23:00 to 2026-07-30 08:00.
        await _insertTimedEvent(
          database,
          'event-overnight',
          'a',
          '夜间活动',
          type: 'personal',
          start: DateTime(2026, 7, 29, 23, 0),
          end: DateTime(2026, 7, 30, 8, 0),
        );
        final harness = _harness(database, 'a');
        final result = await harness.execute('get_free_time', {
          'from': '2026-07-30',
          'through': '2026-07-30',
        });
        expect(result.status, AgentToolStatus.success);
        final gaps = result.payload['gaps']! as List;
        // On 2026-07-30 the overnight event occupies 07:00-08:00 (its
        // intersection with the day grid [07:00, 24:00)). So the first free
        // gap must NOT start at 07:00 — it must start at 08:00.
        final firstGap = gaps.first! as Map<String, Object?>;
        expect(firstGap['startAt'], '2026-07-30T08:00:00');
      },
    );
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

    // Regression: more than 200 pending reviews must be paged via
    // offset/limit instead of returning result_too_large.
    test(
      'more than 200 pending reviews can be paged with offset/limit',
      () async {
        // Seed 202 ended course events with undecided attendance for account
        // 'b' (each ended before `now`).
        for (var i = 0; i < 202; i++) {
          await _insertTimedEvent(
            database,
            'b-pending-$i',
            'b',
            'Pending$i',
            type: 'course',
            start: DateTime(2026, 7, 1, 8, 0).add(Duration(minutes: i)),
            end: DateTime(2026, 7, 1, 9, 0).add(Duration(minutes: i)),
          );
          await OverlayService(database: database, accountId: 'b', now: () => 100)
              .setEventOverlay(
            'b-pending-$i',
            const OverlayMutation(),
          );
        }
        final harness = _harness(database, 'b');
        // First page of 100.
        final page1 = await harness.execute('get_pending_event_reviews', {
          'limit': 100,
          'offset': 0,
        });
        expect(page1.status, AgentToolStatus.success);
        expect(page1.payload['pending']! as List, hasLength(100));
        expect(page1.payload['hasMore'], isTrue);
        // Second page of 100.
        final page2 = await harness.execute('get_pending_event_reviews', {
          'limit': 100,
          'offset': 100,
        });
        expect(page2.status, AgentToolStatus.success);
        expect(page2.payload['pending']! as List, hasLength(100));
        expect(page2.payload['hasMore'], isTrue);
        // Final page of 2.
        final page3 = await harness.execute('get_pending_event_reviews', {
          'limit': 100,
          'offset': 200,
        });
        expect(page3.status, AgentToolStatus.success);
        expect(page3.payload['pending']! as List, hasLength(2));
        expect(page3.payload['hasMore'], isFalse);
      },
    );
  });

  group('get_conflicts', () {
    test('returns pair-level conflict pairs with participant refs and origin',
        () async {
      final harness = _harness(database, 'a');
      final result = await harness.execute('get_conflicts', {
        'from': '2026-07-29',
        'through': '2026-08-04',
      });
      expect(result.status, AgentToolStatus.success);

      // The pair list is authoritative.
      final pairs = result.payload['conflictPairs']! as List;
      expect(pairs, hasLength(1));
      final pair = pairs.first! as Map<String, Object?>;
      expect(pair['origin'], 'explicitOccurrence');
      final left = pair['left']! as Map<String, Object?>;
      final right = pair['right']! as Map<String, Object?>;
      expect(left['ref'], startsWith('ref_'));
      expect(right['ref'], startsWith('ref_'));
      expect(
        {left['title'], right['title']},
        containsAll(['风险课程', '青年活动']),
      );
      expect({left['type'], right['type']}, containsAll(['course', 'personal']));
      expect(left['startAt'], isNotNull);
      expect(right['startAt'], isNotNull);

      // Compatibility event summary: both members are flagged.
      final conflicts = result.payload['conflicts']! as List;
      final titles = conflicts
          .map((c) => (c! as Map<String, Object?>)['title'] as String)
          .toSet();
      expect(titles, containsAll(['风险课程', '青年活动']));
      for (final c in conflicts) {
        expect((c! as Map<String, Object?>)['conflictState'], 'conflict');
      }

      // SECURITY: no raw DB ids anywhere in the payload.
      final encoded = jsonEncode(result.payload);
      expect(encoded, isNot(contains('event-conflict-a')));
      expect(encoded, isNot(contains('event-conflict-b')));
    });

    test('no_conflict relation removes the pair from conflict results',
        () async {
      final harness = _harness(database, 'a');
      // The seeded pair has an explicit conflict; flip it to no_conflict.
      await ConflictService(
        database: database,
        accountId: 'a',
        now: () => 1,
      ).classifyPair(
        EventConflictParticipant(
          eventId: 'event-conflict-a',
          occurrenceDate: DateTime(2026, 7, 29),
        ),
        EventConflictParticipant(
          eventId: 'event-conflict-b',
          occurrenceDate: DateTime(2026, 7, 29),
        ),
        ConflictState.nonConflict,
      );
      final result = await harness.execute('get_conflicts', {
        'from': '2026-07-29',
        'through': '2026-08-04',
      });
      expect(result.status, AgentToolStatus.success);
      expect(result.payload['conflictPairs']! as List, isEmpty);
      expect(result.payload['conflicts']! as List, isEmpty);
    });

    test('explicit conflict on a non-overlapping pair appears', () async {
      final harness = _harness(database, 'a');
      // event-solo (14:00-16:00) does not overlap event-conflict-a
      // (09:00-10:30), so a conflict here must come from the explicit relation.
      await ConflictService(
        database: database,
        accountId: 'a',
        now: () => 1,
      ).classifyPair(
        EventConflictParticipant(
          eventId: 'event-conflict-a',
          occurrenceDate: DateTime(2026, 7, 29),
        ),
        EventConflictParticipant(
          eventId: 'event-solo',
          occurrenceDate: DateTime(2026, 7, 29),
        ),
        ConflictState.conflict,
      );
      final result = await harness.execute('get_conflicts', {
        'from': '2026-07-29',
        'through': '2026-08-04',
      });
      expect(result.status, AgentToolStatus.success);
      final pairs = result.payload['conflictPairs']! as List;
      expect(pairs, hasLength(2));
      // Both the overlapping pair and the new non-overlap pair are conflict by
      // explicit occurrence relation.
      for (final p in pairs) {
        expect((p! as Map<String, Object?>)['origin'], 'explicitOccurrence');
      }
      final titles = pairs.expand((p) {
        final map = p! as Map<String, Object?>;
        return [
          (map['left']! as Map<String, Object?>)['title'],
          (map['right']! as Map<String, Object?>)['title'],
        ];
      }).toSet();
      expect(titles, containsAll(['风险课程', '青年活动', '自习']));
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

    // Regression: more than 200 pending plan-block reviews must be paged via
    // offset/limit instead of returning result_too_large.
    test(
      'more than 200 pending plan-block reviews can be paged',
      () async {
        // Seed a task for account 'b', then 202 expired-accepted plan blocks.
        await _insertTask(database, 'task-b', 'b', '任务B',
            state: 'active', importance: 'normal');
        for (var i = 0; i < 202; i++) {
          await _insertPlanBlock(
            database,
            'b-pb-$i',
            'b',
            'task-b',
            title: 'Block$i',
            start: DateTime(2026, 7, 1, 19, 0).add(Duration(minutes: i)),
            end: DateTime(2026, 7, 1, 21, 0).add(Duration(minutes: i)),
            status: 'accepted',
          );
        }
        final harness = _harness(database, 'b');
        final page1 = await harness.execute('get_pending_planblock_reviews', {
          'limit': 100,
          'offset': 0,
        });
        expect(page1.status, AgentToolStatus.success);
        expect(page1.payload['pending']! as List, hasLength(100));
        expect(page1.payload['hasMore'], isTrue);
        final page3 = await harness.execute('get_pending_planblock_reviews', {
          'limit': 100,
          'offset': 200,
        });
        expect(page3.status, AgentToolStatus.success);
        expect(page3.payload['pending']! as List, hasLength(2));
        expect(page3.payload['hasMore'], isFalse);
      },
    );
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
