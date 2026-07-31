import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_permission_policy_service.dart';
import 'package:ustc_assistant_app/features/agent/data/drift_agent_write_gateway.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_permission_policy.dart';
import 'package:ustc_assistant_app/features/calendar/domain/personal_event.dart';
import 'package:ustc_assistant_app/features/schedule/application/effective_event_repository.dart';
import 'package:ustc_assistant_app/features/schedule/application/overlay_service.dart';
import 'package:ustc_assistant_app/features/tasks/domain/plan_block.dart';

class _FixedClock implements BeijingClock {
  @override
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);
}

void main() {
  late AppDatabase db;
  late AgentPermissionPolicyService policy;
  late DriftAgentWriteGateway gateway;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db.customStatement('PRAGMA foreign_keys = OFF');
    policy = AgentPermissionPolicyService(database: db, clock: _FixedClock());
    gateway = DriftAgentWriteGateway(
      database: db,
      accountId: 'acc-1',
      policy: policy,
      now: () => 1_700_000_000_000,
    );
  });

  tearDown(() => db.close());

  test('createEvent inserts a personal event', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    final row = await (db.select(db.calendarEvents)..where((r) => r.id.equals('ev-1'))).getSingle();
    expect(row.title, '健身');
    expect(row.source, 'user');
  });

  test('createTask and planTask insert rows', () async {
    final taskId = await gateway.createTask(title: '写作业', estimatedMinutes: 60);
    expect(await gateway.taskById(taskId).then((t) => t.title), '写作业');
    final blockId = await gateway.planTask(
      taskId: taskId,
      startAt: DateTime(2026, 8, 2, 20),
      endAt: DateTime(2026, 8, 2, 21),
      status: PlanBlockStatus.accepted,
    );
    expect((await gateway.planBlockById(blockId)).taskId, taskId);
  });

  test('editPersonalEvent updates and cancel/softDelete transition', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    await gateway.editPersonalEvent('ev-1', PersonalEvent.timed(
      id: 'ev-1',
      title: '健身改五点',
      startAt: DateTime(2026, 8, 1, 17),
      endAt: DateTime(2026, 8, 1, 18),
    ));
    var row = await (db.select(db.calendarEvents)..where((r) => r.id.equals('ev-1'))).getSingle();
    expect(row.title, '健身改五点');

    await gateway.cancelEvent('ev-1');
    row = await (db.select(db.calendarEvents)..where((r) => r.id.equals('ev-1'))).getSingle();
    expect(row.status, 'cancelled');

    await gateway.softDeleteEvent('ev-1');
    row = await (db.select(db.calendarEvents)..where((r) => r.id.equals('ev-1'))).getSingle();
    expect(row.deletedAt, isNotNull);
  });

  test('eventIdentity reports personal/recurring', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    final identity = await gateway.eventIdentity('ev-1');
    expect(identity.isPersonal, isTrue);
    expect(identity.isRecurring, isFalse);
  });

  test('recordAttendanceDecision and setEventOverlay write overlays', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    await gateway.recordAttendanceDecision('ev-1', AttendanceDecision.go);
    await gateway.setEventOverlay('ev-1', const OverlayMutation(
      attendancePolicy: AttendancePolicy.mustGo,
      listeningNote: '去占座补作业',
    ));
    final overlay = await db.select(db.userOverlays).getSingle();
    expect(overlay.attendanceDecision, 'go');
    expect(overlay.attendancePolicy, 'must_go');
  });

  test('createConflictRelation writes a conflict relation row', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '课程A',
      startAt: DateTime(2026, 8, 1, 9),
      endAt: DateTime(2026, 8, 1, 10),
    ));
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-2',
      title: '课程B',
      startAt: DateTime(2026, 8, 1, 9),
      endAt: DateTime(2026, 8, 1, 10),
    ));
    await gateway.createConflictRelation(
      leftKind: 'event',
      leftId: 'ev-1',
      rightKind: 'event',
      rightId: 'ev-2',
      conflictState: 'no_conflict',
      reason: '二选一，用户已决定',
    );
    final relation = await db.select(db.scheduleRelations).getSingle();
    expect(relation.relationType, 'conflict');
    expect(relation.conflictState, 'no_conflict');
  });

  test('setReminder writes reminder rows via override service', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    await gateway.setReminder('ev-1', const [15]);
    final reminders = await db.select(db.reminders).get();
    expect(reminders.single.eventId, 'ev-1');
    expect(reminders.single.offsetMinutes, 15);
  });

  test('updatePermissionPolicy delegates to policy service', () async {
    await gateway.updatePermissionPolicy(
      actionType: 'create_event',
      targetType: 'event',
      mode: ConfirmationMode.alwaysAllow,
      riskLevel: RiskLevel.medium,
      enabled: true,
      updatedBy: 'user',
    );
    expect(await policy.resolve(accountId: 'acc-1', actionType: 'create_event',
        targetType: 'event', riskLevel: RiskLevel.medium), PermissionDecision.allow);
  });
}
