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
import 'package:ustc_assistant_app/features/reminders/application/reminder_override_service.dart';
import 'package:ustc_assistant_app/features/schedule/application/conflict_service.dart';
import 'package:ustc_assistant_app/features/schedule/application/effective_event_repository.dart';
import 'package:ustc_assistant_app/features/schedule/application/overlay_service.dart';
import 'package:ustc_assistant_app/features/tasks/application/undo_recorder.dart';
import 'package:ustc_assistant_app/features/tasks/application/undo_service.dart';

final _now = DateTime(2026, 7, 29, 9, 0);

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
    return registry().execute(
      toolName: tool,
      arguments: args,
      context: context(),
    );
  }
}

Future<AppDatabase> _seed() async {
  final database = AppDatabase(NativeDatabase.memory());
  await database.into(database.localAccounts).insert(
        LocalAccountsCompanion.insert(
          id: 'a',
          maskedHint: 'PB****0000',
          createdAt: 1,
          updatedAt: 1,
        ),
      );

  Future<void> event(
    String id,
    String title, {
    DateTime? start,
    DateTime? end,
    String status = 'active',
    String source = 'user',
    String? sourceSeriesExternalId,
  }) => database.into(database.calendarEvents).insert(
        CalendarEventsCompanion.insert(
          id: id,
          accountId: 'a',
          source: source,
          sourceSeriesExternalId: Value(sourceSeriesExternalId),
          title: title,
          type: 'personal',
          startAt: Value(start?.toUtc().millisecondsSinceEpoch),
          endAt: Value(end?.toUtc().millisecondsSinceEpoch),
          allDay: false,
          timezone: 'Asia/Shanghai',
          status: Value(status),
          createdAt: 1,
          updatedAt: 1,
        ),
      );

  Future<void> task(String id, String title) => database.into(database.tasks)
      .insert(
        TasksCompanion.insert(
          id: id,
          accountId: 'a',
          title: title,
          state: 'active',
          importance: 'normal',
          tagsJson: '[]',
          createdAt: 1,
          updatedAt: 1,
        ),
      );

  Future<void> planBlock(
    String id,
    String taskId,
    DateTime start,
    DateTime end,
  ) => database.into(database.planBlocks).insert(
        PlanBlocksCompanion.insert(
          id: id,
          accountId: 'a',
          taskId: taskId,
          startAt: start.toUtc().millisecondsSinceEpoch,
          endAt: end.toUtc().millisecondsSinceEpoch,
          status: 'accepted',
          createdAt: 1,
          updatedAt: 1,
        ),
      );

  // Two timed personal events.
  await event('ev-a', '事件A',
      start: DateTime(2026, 7, 29, 9, 0), end: DateTime(2026, 7, 29, 10, 0));
  await event('ev-b', '事件B',
      start: DateTime(2026, 7, 29, 9, 30), end: DateTime(2026, 7, 29, 10, 30));
  // A task + accepted plan block for a plan_block participant.
  await task('task-1', '任务1');
  await planBlock('pb-1', 'task-1', DateTime(2026, 7, 29, 11, 0),
      DateTime(2026, 7, 29, 12, 0));

  // An explicit event<->event occurrence relation (source=user conflict).
  final conflict = ConflictService(database: database, accountId: 'a', now: () => 1);
  await conflict.classifyPair(
    ScheduleConflictParticipant(
      kind: 'event',
      id: 'ev-a',
      title: '事件A',
      occurrenceDate: DateTime(2026, 7, 29),
    ),
    ScheduleConflictParticipant(
      kind: 'event',
      id: 'ev-b',
      title: '事件B',
      occurrenceDate: DateTime(2026, 7, 29),
    ),
    ConflictState.conflict,
    reason: 'time overlap',
  );

  // A reminder config for the event: two future desired offsets + a delivered
  // history row.
  final reminders = ReminderOverrideService(
    database: database,
    accountId: 'a',
    undoRecorder: NoopUndoRecorder(),
    now: () => DateTime(2026, 7, 29, 0, 0).millisecondsSinceEpoch,
  );
  await reminders.setEventOffsets('ev-a', [10, 30]);

  // A single_event overlay layer on ev-a plus a course-series backed event so we
  // can exercise the course_series layer.
  await OverlayService(database: database, accountId: 'a', now: () => 100)
      .setEventOverlay(
        'ev-a',
        const OverlayMutation(
          attendancePolicy: AttendancePolicy.gamble,
          listeningMode: ListeningMode.listen,
          displayTitle: '用户标题A',
          attendanceNote: '节假日前风险高',
        ),
      );
  // A course-series event (sourceSeriesExternalId set) with a series overlay.
  await database.into(database.courseSeries).insert(
        CourseSeriesCompanion.insert(
          id: 'series-1',
          accountId: 'a',
          source: 'user',
          externalId: 'ext-1',
          title: '系列课程',
          semesterKey: '2026spring',
          participantsJson: const Value('[]'),
          sourceDetailsJson: '{}',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
  await event('ev-series', '系列事件',
      start: DateTime(2026, 7, 30, 9, 0),
      end: DateTime(2026, 7, 30, 10, 0),
      sourceSeriesExternalId: 'ext-1');
  await OverlayService(database: database, accountId: 'a', now: () => 200)
      .setSeriesOverlay(
        'series-1',
        const OverlayMutation(
          attendancePolicy: AttendancePolicy.mustGo,
          displayLocation: '东区教室',
        ),
      );

  return database;
}

_Harness _harness(AppDatabase database, String accountId) {
  final gateway = DriftAgentLocalDataGateway(database);
  final references = RunReferenceStore(runId: 'run-$accountId');
  return _Harness(gateway, accountId, references);
}

void main() {
  late AppDatabase database;
  late _Harness harness;

  setUp(() async {
    database = await _seed();
    harness = _harness(database, 'a');
  });
  tearDown(() async => database.close());

  group('RunReferenceStore.resolveTarget', () {
    test('resolves event/task/planblock refs to (kind, localId)', () {
      final store = RunReferenceStore(runId: 'run-test');
      final evRef = store.bind(kind: 'event', localId: 'ev-1');
      final taskRef = store.bind(kind: 'task', localId: 'task-1');
      final pbRef = store.bind(kind: 'planblock', localId: 'pb-1');

      expect(store.resolveTarget(evRef), (kind: 'event', localId: 'ev-1'));
      expect(store.resolveTarget(taskRef), (kind: 'task', localId: 'task-1'));
      expect(store.resolveTarget(pbRef), (kind: 'planblock', localId: 'pb-1'));
    });

    test('cross-run ref resolves to null (a different store)', () {
      final store = RunReferenceStore(runId: 'run-test');
      final evRef = store.bind(kind: 'event', localId: 'ev-1');
      final otherStore = RunReferenceStore(runId: 'run-other');
      expect(otherStore.resolveTarget(evRef), isNull);
    });

    test('kind outside the allowed set resolves to null', () {
      final store = RunReferenceStore(runId: 'run-test');
      final scheduleRef = store.bind(kind: 'schedule', localId: 's-1');
      expect(
        store.resolveTarget(scheduleRef),
        isNull,
      );
      // A schedule ref is rejected by the default managed-target kinds.
      expect(store.resolveTarget(scheduleRef), isNull);
    });

    test('unknown ref resolves to null', () {
      final store = RunReferenceStore(runId: 'run-test');
      expect(store.resolveTarget('ref_does_not_exist'), isNull);
    });
  });

  group('get_schedule_relations', () {
    test('lists an explicit event occurrence conflict relation with safe DTO',
        () async {
      final evRef = harness.references.bind(kind: 'event', localId: 'ev-a');
      final result = await harness.execute('get_schedule_relations', {
        'ref_left': evRef,
      });

      expect(result.status, AgentToolStatus.success);
      final relations = result.payload['relations']! as List;
      expect(relations, isNotEmpty);

      final first = relations.first! as Map<String, Object?>;
      expect(first['ref'], startsWith('ref_'));
      expect(first['scope'], 'occurrence');
      expect(first['conflictState'], 'conflict');
      expect(first['fallback'], isNotNull);
      expect(first['reason'], isNotNull);
      expect(first['validFrom'], '2026-07-29');

      // The left and right participant DTOs are safe.
      final left = first['left']! as Map<String, Object?>;
      expect(left['kind'], 'event');
      expect(left['title'], '事件A');
      expect(left.containsKey('db_id'), isFalse);

      // SECURITY: no raw DB ids anywhere in the payload.
      final encoded = jsonEncode(result.payload);
      expect(encoded, isNot(contains('ev-a')));
      expect(encoded, isNot(contains('ev-b')));
      expect(encoded, isNot(contains('rightId')));
    });

    test('binds a run-local ref_relation and returns it in references', () async {
      final evRef = harness.references.bind(kind: 'event', localId: 'ev-a');
      final result = await harness.execute('get_schedule_relations', {
        'ref_left': evRef,
      });
      expect(result.references, isNotEmpty);
      expect(
        result.references.any((r) => r.kind == 'schedule_relation'),
        isTrue,
      );
    });

    test('ref_right narrows the relation list to the given pair', () async {
      // Add a second relation ev-a <-> the plan block so there are two.
      final conflict = ConflictService(
        database: database,
        accountId: 'a',
        now: () => 2,
      );
      await conflict.classifyPair(
        ScheduleConflictParticipant(
          kind: 'event',
          id: 'ev-a',
          title: '事件A',
          occurrenceDate: DateTime(2026, 7, 29),
        ),
        ScheduleConflictParticipant(
          kind: 'plan_block',
          id: 'pb-1',
          title: '复习',
          occurrenceDate: DateTime(2026, 7, 29),
        ),
        ConflictState.nonConflict,
      );
      final evRef = harness.references.bind(kind: 'event', localId: 'ev-a');
      final pbRef = harness.references.bind(kind: 'planblock', localId: 'pb-1');
      final allResult = await harness.execute('get_schedule_relations', {
        'ref_left': evRef,
      });
      expect((allResult.payload['relations']! as List).length, 2);

      final narrowResult = await harness.execute('get_schedule_relations', {
        'ref_left': evRef,
        'ref_right': pbRef,
      });
      final narrow = narrowResult.payload['relations']! as List;
      expect(narrow.length, 1);
      final item = narrow.first! as Map<String, Object?>;
      final right = item['right']! as Map<String, Object?>;
      expect(right, containsPair('kind', 'plan_block'));
    });

    test('unknown ref_left resolves to reference_not_found', () async {
      final result = await harness.execute('get_schedule_relations', {
        'ref_left': 'ref_bogus',
      });
      expect(result.status, AgentToolStatus.error);
      expect(result.errorCode, 'reference_not_found');
    });

    test('missing ref_left resolves to invalid_arguments', () async {
      final result = await harness.execute('get_schedule_relations', {});
      expect(result.status, AgentToolStatus.error);
      expect(result.errorCode, 'invalid_arguments');
    });

    test('a derived overlap is not returned (no relation row exists)', () async {
      // ev-a and a brand-new overlapping solo event have NO explicit relation,
      // so the solo event is not listed as a relation.
      await database.into(database.calendarEvents).insert(
            CalendarEventsCompanion.insert(
              id: 'ev-solo',
              accountId: 'a',
              source: 'user',
              title: '独奏',
              type: 'personal',
              startAt: Value(
                DateTime(2026, 7, 29, 9, 10).toUtc().millisecondsSinceEpoch,
              ),
              endAt: Value(
                DateTime(2026, 7, 29, 10, 0).toUtc().millisecondsSinceEpoch,
              ),
              allDay: false,
              timezone: 'Asia/Shanghai',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      final evRef = harness.references.bind(kind: 'event', localId: 'ev-a');
      final result = await harness.execute('get_schedule_relations', {
        'ref_left': evRef,
      });
      final relations = result.payload['relations']! as List;
      // Only the explicit relation partner (ev-b) appears; the overlapping
      // derived solo event does not create a relation row.
      expect(relations, hasLength(1));
    });
  });

  group('get_reminders', () {
    test('returns future desired offsets and no reminder DB id', () async {
      final evRef = harness.references.bind(kind: 'event', localId: 'ev-a');
      final result = await harness.execute('get_reminders', {
        'ref_target': evRef,
      });
      expect(result.status, AgentToolStatus.success);
      expect(result.payload['desiredOffsets'], [10, 30]);
      expect(result.payload['explicitDisabled'], isFalse);
      // SECURITY: no reminder DB id (the ids contain 'reminder:event:ev-a').
      final encoded = jsonEncode(result.payload);
      expect(encoded, isNot(contains('reminder:')));
      expect(encoded, isNot(contains('ev-a')));
    });

    test('accepts a planblock ref_target', () async {
      final pbRef = harness.references.bind(kind: 'planblock', localId: 'pb-1');
      final result = await harness.execute('get_reminders', {
        'ref_target': pbRef,
      });
      expect(result.status, AgentToolStatus.success);
      expect(result.payload['targetType'], 'planblock');
      expect(result.payload['desiredOffsets'], isEmpty);
    });

    test('unknown ref_target resolves to reference_not_found', () async {
      final result = await harness.execute('get_reminders', {
        'ref_target': 'ref_bogus',
      });
      expect(result.status, AgentToolStatus.error);
      expect(result.errorCode, 'reference_not_found');
    });

    test('missing ref_target resolves to invalid_arguments', () async {
      final result = await harness.execute('get_reminders', {});
      expect(result.status, AgentToolStatus.error);
      expect(result.errorCode, 'invalid_arguments');
    });
  });

  group('get_user_overlay', () {
    test('returns single_event layer separate from course_series', () async {
      final evRef = harness.references.bind(kind: 'event', localId: 'ev-a');
      final result = await harness.execute('get_user_overlay', {
        'ref_event': evRef,
      });
      expect(result.status, AgentToolStatus.success);
      final payload = result.payload;
      expect(payload['hasSingleEventLayer'], isTrue);
      final single = payload['singleEvent']! as Map<String, Object?>;
      expect(single['displayTitle'], '用户标题A');
      expect(single['attendancePolicy'], 'gamble');
      expect(single['attendanceNote'], '节假日前风险高');
      // SECURITY: no DB id / event id leak.
      final encoded = jsonEncode(result.payload);
      expect(encoded, isNot(contains('ev-a')));
      expect(encoded, isNot(contains('overlayId')));
      expect(encoded, isNot(contains('eventId')));
    });

    test('returns course_series layer and clear-single preview for a series event',
        () async {
      final evSeriesRef =
          harness.references.bind(kind: 'event', localId: 'ev-series');
      final result = await harness.execute('get_user_overlay', {
        'ref_event': evSeriesRef,
      });
      expect(result.status, AgentToolStatus.success);
      final payload = result.payload;
      expect(payload['hasCourseSeriesLayer'], isTrue);
      final series = payload['courseSeries']! as Map<String, Object?>;
      expect(series['attendancePolicy'], 'must_go');
      expect(series['displayLocation'], '东区教室');
      // After clearing the single layer, the series layer still applies.
      final afterSingle = payload['afterClearingSingle']! as Map<String, Object?>;
      expect(afterSingle['attendancePolicy'], 'must_go');
      expect(afterSingle['displayLocation'], '东区教室');
    });

    test('does not return the raw EffectiveEvent merged value', () async {
      // ev-a has a single_event overlay; the course_series layer is absent.
      final evRef = harness.references.bind(kind: 'event', localId: 'ev-a');
      final result = await harness.execute('get_user_overlay', {
        'ref_event': evRef,
      });
      final payload = result.payload;
      expect(payload['hasCourseSeriesLayer'], isFalse);
      expect(payload['courseSeries'], isEmpty);
      // The single layer carries only the explicitly-set fields.
      final single = payload['singleEvent']! as Map<String, Object?>;
      expect(single, contains('displayTitle'));
    });

    test('unknown ref_event resolves to reference_not_found', () async {
      final result = await harness.execute('get_user_overlay', {
        'ref_event': 'ref_bogus',
      });
      expect(result.status, AgentToolStatus.error);
      expect(result.errorCode, 'reference_not_found');
    });

    test('missing ref_event resolves to invalid_arguments', () async {
      final result = await harness.execute('get_user_overlay', {});
      expect(result.status, AgentToolStatus.error);
      expect(result.errorCode, 'invalid_arguments');
    });
  });

  group('get_last_undoable_action', () {
    test('returns a safe Chinese summary and never the payload/id/ref',
        () async {
      // Record a real undoable action for account 'a'.
      final undo = UndoService(database: database, accountId: 'a', now: () => 1000);
      await undo.record(
        UndoCommand(
          kind: 'task_create',
          accountId: 'a',
          safeSummary: '创建了一条任务',
          payload: {
            'entity': 'task',
            'id': 'task-hidden-id',
            'before': null,
          },
        ),
      );

      final result = await harness.execute('get_last_undoable_action', {});
      expect(result.status, AgentToolStatus.success);
      expect(result.payload['available'], isTrue);
      expect(result.payload['summary'], '创建了一条任务');
      expect(result.payload['actionType'], 'task_create');
      expect(result.payload['beijingAt'], isNotEmpty);
      // SECURITY: no payload / DB id / ref in the DTO.
      final encoded = jsonEncode(result.payload);
      expect(encoded, isNot(contains('task-hidden-id')));
      expect(encoded, isNot(contains('payload')));
      expect(encoded, isNot(contains('ref_')));

      // The tool only previews; it never consumes the slot.
      expect(await undo.canUndo(), isTrue);
    });

    test('returns available:false when no slot exists (and does not error)',
        () async {
      final result = await harness.execute('get_last_undoable_action', {});
      expect(result.status, AgentToolStatus.success);
      expect(result.payload['available'], isFalse);
      expect(result.payload['summary'], '');
      expect(result.payload['actionType'], '');
    });

    test('another account cannot read the summary', () async {
      final undo = UndoService(database: database, accountId: 'a', now: () => 1000);
      await undo.record(
        UndoCommand(
          kind: 'task_create',
          accountId: 'a',
          safeSummary: '创建了一条任务',
          payload: {
            'entity': 'task',
            'id': 'task-hidden-id',
            'before': null,
          },
        ),
      );
      await database.into(database.localAccounts).insert(
            LocalAccountsCompanion.insert(
              id: 'other',
              maskedHint: 'PB****9999',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      final otherHarness = _harness(database, 'other');
      final bytes = await otherHarness.execute('get_last_undoable_action', {});
      expect(bytes.status, AgentToolStatus.success);
      expect(bytes.payload['available'], isFalse);
      expect(bytes.payload['summary'], '');
      expect(bytes.payload['actionType'], '');
      final encoded = jsonEncode(bytes.payload);
      expect(encoded, isNot(contains('task-hidden-id')));
      expect(encoded, isNot(contains('创建了一条任务')));
    });
  });
}