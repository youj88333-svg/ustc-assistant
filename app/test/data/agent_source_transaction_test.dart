import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/agent_action_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/jw_academic_details.dart';
import 'package:ustc_assistant_m0/core/jw_work_contract.dart';
import 'package:ustc_assistant_m0/core/young_work_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/source/jw_collection_contract.dart';
import 'package:ustc_assistant_m0/source/jw_probe_contract.dart';
import 'package:ustc_assistant_m0/source/young_business_contract.dart';
import 'package:ustc_assistant_m0/source/young_collection_contract.dart';

const _account = 'SYNTHETIC001';
final _clock = FixedClock(DateTime.utc(2026, 10, 13, 8));
final _key = Uint8List.fromList('synthetic-source-transaction-key'.codeUnits);
final _youngDay = DateTime.utc(2026, 6, 10);
int _jwPartitionSequence = 0;
int _youngPartitionSequence = 0;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  test(
    'source binding rejects a fabricated action and another store ticket',
    () async {
      final store = await _openStore();
      final foreign = await _openStore();
      final run = await _beginRun(store);
      final issuedAction = await _sourceAction(store, run);
      final (sourceTicket, _, _) = await _prepareJwImport(store);
      final fabricated = AgentActionView(
        id: 'agent-action-fabricated',
        kind: AgentActionKind.sourceRefresh,
        status: AgentActionStatus.proposed,
        title: '伪造合成刷新卡',
        details: const ['没有由 C3 签发'],
      );

      await expectLater(
        store.agent.bindSourceAction(run, fabricated, sourceTicket),
        throwsA(
          isA<AgentFailure>().having(
            (failure) => failure.code,
            'code',
            AgentFailureCode.staleContext,
          ),
        ),
      );

      await expectLater(
        store.agent.bindSourceAction(run, issuedAction, sourceTicket),
        throwsA(
          isA<AgentFailure>().having(
            (failure) => failure.code,
            'code',
            AgentFailureCode.consentRequired,
          ),
        ),
      );
      final unapprovedYoungTicket = (await _prepareYoungImport(store)).$1;
      await expectLater(
        store.agent.bindSourceAction(run, issuedAction, unapprovedYoungTicket),
        throwsA(
          isA<AgentFailure>().having(
            (failure) => failure.code,
            'code',
            AgentFailureCode.consentRequired,
          ),
        ),
      );
      await store.agent.approveSourceAction(run, issuedAction);
      final foreignTicket = (await _prepareJwImport(foreign)).$1;
      await expectLater(
        store.agent.bindSourceAction(run, issuedAction, foreignTicket),
        throwsA(isA<AgentFailure>()),
      );
      await store.cancelJob(sourceTicket);
      await store.cancelYoungJob(unapprovedYoungTicket);
      await foreign.cancelJob(foreignTicket);
      await store.agent.cancelRun(run);
    },
  );

  test(
    'JW and Young source commits bind their real receipts to the same revision',
    () async {
      final store = await _openStore();
      final run = await _beginRun(store);
      final planPort = store.localCalendar as AgentLocalPlanPort;

      final jwAction = await _sourceAction(store, run);
      await store.agent.approveSourceAction(run, jwAction);
      final jwBefore = (await planPort.readPlanContext()).$2;
      final (jwTicket, _, jwArtifact) = await _prepareJwImport(store);
      await store.agent.bindSourceAction(run, jwAction, jwTicket);
      final jwReceipt = await store.importSnapshot(jwTicket, jwArtifact);
      expect(jwReceipt.replayed, isFalse);
      expect((await planPort.readPlanContext()).$2, jwBefore + 1);
      expect((await store.readView()).events, hasLength(2));
      _expectAction(
        await _readAction(store, run, jwAction.id),
        status: AgentActionStatus.committed,
        count: 2,
      );
      await store.agent.settleActionRecord(
        run,
        jwAction,
        AgentActionStatus.failed,
      );
      _expectAction(
        await _readAction(store, run, jwAction.id),
        status: AgentActionStatus.committed,
        count: 2,
      );

      final youngAction = await _sourceAction(store, run);
      await store.agent.approveSourceAction(run, youngAction);
      final youngBefore = (await planPort.readPlanContext()).$2;
      final (youngTicket, _, youngArtifact) = await _prepareYoungImport(store);
      await store.agent.bindSourceAction(run, youngAction, youngTicket);
      final youngReceipt = await store.importYoungCalendar(
        youngTicket,
        youngArtifact,
      );
      expect(youngReceipt.replayed, isFalse);
      expect((await planPort.readPlanContext()).$2, youngBefore + 1);
      expect((await store.readYoungView()).events, hasLength(1));
      _expectAction(
        await _readAction(store, run, youngAction.id),
        status: AgentActionStatus.committed,
        count: 1,
      );
      await store.agent.cancelRun(run);
      _expectAction(
        await _readAction(store, run, jwAction.id),
        status: AgentActionStatus.committed,
        count: 2,
      );
      _expectAction(
        await _readAction(store, run, youngAction.id),
        status: AgentActionStatus.committed,
        count: 1,
      );
    },
  );

  test(
    'Young activity queries do not require a source refresh approval',
    () async {
      final store = await _openStore();
      final run = await _beginRun(store);
      final action = await _sourceAction(store, run);
      final revision =
          (await (store.localCalendar as AgentLocalPlanPort).readPlanContext())
              .$2;
      final (sourceTicket, _, artifact) = await _prepareYoungActivityQuery(
        store,
      );

      await store.agent.bindSourceAction(run, action, sourceTicket);
      final receipt = await store.completeYoungQuery(sourceTicket, artifact);

      expect(receipt.itemCount, 1);
      await store.agent.ensureYoungAgentDelivery(run, sourceTicket);
      expect((await store.readYoungView()).queryCount, 1);
      expect(
        (await (store.localCalendar as AgentLocalPlanPort).readPlanContext())
            .$2,
        revision,
      );
      _expectAction(
        await _readAction(store, run, action.id),
        status: AgentActionStatus.committed,
        count: 1,
      );
      await store.agent.cancelRun(run);
    },
  );

  test('Young read delivery is revoked with the source generation', () async {
    final store = await _openStore();
    final run = await _beginRun(store);
    final action = await _sourceAction(store, run);
    final (ticket, _, artifact) = await _prepareYoungActivityQuery(store);
    await store.agent.bindSourceAction(run, action, ticket);
    await store.completeYoungQuery(ticket, artifact);
    await store.agent.ensureYoungAgentDelivery(run, ticket);

    await store.revokeYoungPermits();

    await expectLater(
      store.agent.ensureYoungAgentDelivery(run, ticket),
      throwsA(
        isA<AgentFailure>().having(
          (failure) => failure.code,
          'code',
          AgentFailureCode.staleContext,
        ),
      ),
    );
    _expectAction(
      await _readAction(store, run, action.id),
      status: AgentActionStatus.committed,
      count: 1,
    );
    await store.agent.cancelRun(run);
  });

  test(
    'a failed final Agent checkpoint rolls back Young business, action and revision',
    () async {
      var failCheckpoint = false;
      final store = await _openStore(
        onAgentCheckpoint: () async {
          if (failCheckpoint) {
            throw StateError('synthetic Agent checkpoint');
          }
        },
      );
      final run = await _beginRun(store);
      final action = await _sourceAction(store, run);
      final (sourceTicket, _, artifact) = await _prepareYoungImport(store);
      await store.agent.approveSourceAction(run, action);
      await store.agent.bindSourceAction(run, action, sourceTicket);
      final planPort = store.localCalendar as AgentLocalPlanPort;
      final revision = (await planPort.readPlanContext()).$2;
      failCheckpoint = true;

      await expectLater(
        store.importYoungCalendar(sourceTicket, artifact),
        throwsA(
          isA<AppFailure>().having(
            (failure) => failure.code,
            'code',
            FailureCode.storageFailed,
          ),
        ),
      );

      expect((await planPort.readPlanContext()).$2, revision);
      expect((await store.readYoungView()).events, isEmpty);
      expect((await store.readYoungView()).importCount, 0);
      expect((await store.readYoungAuthority()).accountBound, isFalse);
      _expectAction(
        await _readAction(store, run, action.id),
        status: AgentActionStatus.proposed,
        count: 0,
      );
      await store.agent.cancelRun(run);
    },
  );

  test(
    'synchronous local-plan revocation rejects the queued source transaction',
    () async {
      var revokeAtCheckpoint = false;
      late AgentRunTicket run;
      late JwStore store;
      store = await _openStore(
        onAgentCheckpoint: () async {
          if (revokeAtCheckpoint) store.localCalendar.revokeLocalPlans(run);
        },
      );
      run = await _beginRun(store);
      final action = await _sourceAction(store, run);
      final (sourceTicket, _, artifact) = await _prepareJwImport(store);
      await store.agent.approveSourceAction(run, action);
      await store.agent.bindSourceAction(run, action, sourceTicket);
      final planPort = store.localCalendar as AgentLocalPlanPort;
      final revision = (await planPort.readPlanContext()).$2;
      revokeAtCheckpoint = true;

      await expectLater(
        store.importSnapshot(sourceTicket, artifact),
        throwsA(
          isA<AgentFailure>().having(
            (failure) => failure.code,
            'code',
            AgentFailureCode.cancelled,
          ),
        ),
      );

      expect((await planPort.readPlanContext()).$2, revision);
      expect((await store.readView()).events, isEmpty);
      expect((await store.readView()).importCount, 0);
      _expectAction(
        await _readAction(store, run, action.id),
        status: AgentActionStatus.proposed,
        count: 0,
      );
      await store.agent.cancelRun(run);
    },
  );

  test(
    'a committed source survives Agent answer storage failure and cancellation',
    () async {
      var failAgentCheckpoint = false;
      final store = await _openStore(
        onAgentCheckpoint: () async {
          if (failAgentCheckpoint) {
            throw StateError('synthetic answer storage failure');
          }
        },
      );
      final run = await _beginRun(store);
      final action = await _sourceAction(store, run);
      final (sourceTicket, _, artifact) = await _prepareYoungImport(store);
      await store.agent.approveSourceAction(run, action);
      await store.agent.bindSourceAction(run, action, sourceTicket);
      final receipt = await store.importYoungCalendar(sourceTicket, artifact);
      expect(receipt.replayed, isFalse);
      failAgentCheckpoint = true;

      await expectLater(
        store.agent.saveAssistant(run, '合成回答写入故障'),
        throwsA(
          isA<AgentFailure>().having(
            (failure) => failure.code,
            'code',
            AgentFailureCode.storageFailed,
          ),
        ),
      );
      failAgentCheckpoint = false;
      await store.agent.cancelRun(run);

      expect((await store.readYoungView()).events, hasLength(1));
      expect((await store.readYoungView()).importCount, 1);
      _expectAction(
        await _readAction(store, run, action.id),
        status: AgentActionStatus.committed,
        count: 1,
      );
    },
  );

  test(
    'an unbound source keeps its original behavior and invalidates an old plan',
    () async {
      final store = await _openStore();
      final run = await _beginRun(store);
      final planPort = store.localCalendar as AgentLocalPlanPort;
      final (context, revision) = await planPort.readPlanContext();
      final plan = await planPort.prepareLocalPlan(run, context, revision, [
        AgentCalendarChange(
          CreatePersonalEvent(
            PersonalEventDraft(
              title: '过期合成计划',
              start: DateTime.utc(2026, 6, 10, 11),
              end: DateTime.utc(2026, 6, 10, 12),
            ),
          ),
        ),
      ]);
      final approval = await planPort.approveLocalPlan(plan);
      final (sourceTicket, _, artifact) = await _prepareYoungImport(store);

      final receipt = await store.importYoungCalendar(sourceTicket, artifact);
      expect(receipt.replayed, isFalse);
      expect((await planPort.readPlanContext()).$2, revision + 1);
      expect((await store.readYoungView()).events, hasLength(1));
      await expectLater(
        planPort.commitLocalPlan(approval),
        throwsA(
          isA<CalendarFailure>().having(
            (failure) => failure.code,
            'code',
            CalendarFailureCode.staleReference,
          ),
        ),
      );
      final messages = await store.agent.messages(run.conversationId);
      expect(
        messages
            .singleWhere(
              (message) => message.role == AgentMessageRole.assistant,
            )
            .actions
            .where((action) => action.kind == AgentActionKind.sourceRefresh),
        isEmpty,
      );
      final view = await store.localCalendar.query(
        CalendarQuery(
          firstDay: DateTime.utc(2026, 6, 10),
          endDayExclusive: DateTime.utc(2026, 6, 11),
          filter: CalendarFilter.all,
        ),
      );
      expect(view.items.map((item) => item.title), [
        'Synthetic linked schedule',
      ]);
      await store.agent.cancelRun(run);
    },
  );
}

Future<JwStore> _openStore({Future<void> Function()? onAgentCheckpoint}) async {
  final store = JwStore(
    NativeDatabase.memory(),
    ownership: _TestOwnership(),
    clock: _clock,
    modelCredentialProtector: _SyntheticProtector(),
    onAgentCheckpoint: onAgentCheckpoint,
  );
  addTearDown(store.close);
  await store.initialize();
  await store.agent.initializeAgent();
  final settings = await store.agent.inspectAgent();
  await store.agent.saveModelConfiguration(
    settings.authority,
    modelId: 'synthetic-source-transaction-model',
    modelIds: const ['synthetic-source-transaction-model'],
    report: const AgentCapabilityReport(text: true, streaming: true),
    consent: true,
    key: _key,
  );
  return store;
}

Future<AgentRunTicket> _beginRun(JwStore store) async {
  final settings = await store.agent.inspectAgent();
  final conversation = await store.agent.createConversation();
  return store.agent.beginRun(
    settings.authority,
    conversation,
    '仅用于本地合成来源事务回归',
  );
}

Future<AgentActionView> _sourceAction(JwStore store, AgentRunTicket run) =>
    store.agent.prepareActionRecord(
      run,
      AgentActionKind.sourceRefresh,
      '合成来源刷新',
      const ['合成fixture，不访问学校'],
    );

Future<(JwJobTicket, JwPartitionRef, JwCollectedArtifact)> _prepareJwImport(
  JwStore store,
) async {
  final ticket = await store.beginJob(expectedAccountCode: _account);
  final partition = JwPartitionRef(
    id: 'jwp-${(++_jwPartitionSequence).toRadixString(16).padLeft(32, '0')}',
    ownerId: ticket.stamp.ownerId,
    purpose: ticket.stamp.accountId == null
        ? JwPartitionPurpose.initial
        : JwPartitionPurpose.recovery,
    attempt: ticket.stamp.jobId,
    resetEpoch: ticket.stamp.resetEpoch,
  );
  await store.stagePartition(ticket, partition);
  await store.stageSemesterCatalog(ticket, const [
    JwSemesterOption(id: 202610, name: '合成学期', selected: true),
  ]);
  return (ticket, partition, _jwArtifact(ticket, partition));
}

JwCollectedArtifact _jwArtifact(JwJobTicket ticket, JwPartitionRef partition) {
  final diagnostics = <String, Object>{
    'checks': {
      'identityBefore': 'ok',
      'course': 'ok',
      'index': 'ok',
      'datum': 'ok',
      'exams': 'ok',
      'identityAfter': 'ok',
    },
    'reason': 'none',
    'identityReads': 2,
    'lessonIds': 1,
    'lessons': 1,
    'groups': 1,
    'schedules': 1,
    'datedSchedules': 1,
    'timedSchedules': 1,
    'linkedSchedules': 1,
    'examRows': 1,
    'datedExams': 1,
    'semesterAccepted': true,
    'selfRouteBound': true,
    'identityStable': true,
    'emptyCourse': false,
    'emptyExams': false,
    'pagination': false,
    'types': {
      'lessonIds': 'array',
      'lessonList': 'array',
      'scheduleGroupList': 'array',
      'scheduleList': 'array',
      'date': 'string',
      'startTime': 'string',
      'endTime': 'string',
    },
  };
  final reply = JwCollectionReply.decode(
    jsonEncode({
      'operation': 31,
      'phase': 'done',
      'code': 'ok',
      'identity': {
        'candidateCount': 1,
        'method': 'table',
        'accountCode': _account,
      },
      'diagnostics': diagnostics,
      'snapshot': {
        'version': jwContractVersion,
        'semesterId': 202610,
        'courses': [
          {
            'lessonId': 101,
            'groupId': 1101,
            'date': '2026-10-12',
            'startMinute': 540,
            'endMinute': 600,
            'title': '合成课程',
            'academicDetails': JwAcademicDetails(
              lessonId: 101,
              groupId: 1101,
            ).toMap(),
          },
        ],
        'exams': [
          {
            'courseCode': 'SYNTH-101',
            'examType': 'final',
            'date': '2026-12-20',
            'startMinute': 540,
            'endMinute': 600,
            'title': '合成考试',
            'academicDetails': JwAcademicDetails(
              courseCode: 'SYNTH-101',
              examType: 'final',
            ).toMap(),
          },
        ],
      },
    }),
    operation: 31,
  );
  return JwCollectedArtifact.seal(
    reply: reply,
    stamp: ticket.stamp,
    partition: partition,
    session: 1,
    document: 2,
    semesterId: 202610,
    collectedAtUtc: _clock.nowUtc,
  );
}

Future<(YoungJobTicket, YoungPartitionRef, YoungCollectedArtifact)>
_prepareYoungImport(JwStore store) async {
  final ticket = await store.beginYoungJob(
    kind: YoungJobKind.calendar,
    expectedAccountCode: _account,
    firstDay: _youngDay,
    lastDay: _youngDay,
  );
  final partition = YoungPartitionRef(
    id: 'yp-${(++_youngPartitionSequence).toRadixString(16).padLeft(32, '0')}',
    ownerId: ticket.stamp.ownerId,
    purpose: ticket.stamp.accountId == null
        ? YoungPartitionPurpose.initial
        : YoungPartitionPurpose.recovery,
    attempt: ticket.stamp.jobId,
    resetEpoch: ticket.stamp.resetEpoch,
  );
  await store.stageYoungPartition(ticket, partition);
  final rows = [
    <String, Object?>{
      'id': 'synthetic-calendar-event',
      'title': 'Synthetic linked schedule',
      'place': 'Synthetic campus',
      'startTime': '2026-06-10 09:00:00',
      'endTime': '2026-06-10 10:00:00',
      'itemId': 'synthetic-activity-association',
    },
  ];
  final decoded = decodeYoungCalendarPage({
    'success': true,
    'code': 200,
    'result': {'records': rows, 'total': rows.length},
  }).records;
  final entries = decoded.where((entry) => entry.itemId != null).toList();
  final artifact = YoungCollectedArtifact.seal(
    profileBefore: _youngProfile(_account),
    profileAfter: _youngProfile(_account),
    stamp: ticket.stamp,
    partition: partition,
    session: 1,
    document: 2,
    operation: 3,
    collectedAtUtc: _clock.nowUtc,
    activities: const [],
    entries: entries,
    activityPages: 0,
    calendarPages: 1,
    calendarRows: rows.length,
    excludedSchedules: decoded.length - entries.length,
    days: 1,
    firstDay: _youngDay,
    lastDay: _youngDay,
  );
  return (ticket, partition, artifact);
}

Future<(YoungJobTicket, YoungPartitionRef, YoungCollectedArtifact)>
_prepareYoungActivityQuery(JwStore store) async {
  final ticket = await store.beginYoungJob(
    kind: YoungJobKind.activities,
    expectedAccountCode: _account,
  );
  final partition = YoungPartitionRef(
    id: 'yp-${(++_youngPartitionSequence).toRadixString(16).padLeft(32, '0')}',
    ownerId: ticket.stamp.ownerId,
    purpose: ticket.stamp.accountId == null
        ? YoungPartitionPurpose.initial
        : YoungPartitionPurpose.recovery,
    attempt: ticket.stamp.jobId,
    resetEpoch: ticket.stamp.resetEpoch,
  );
  await store.stageYoungPartition(ticket, partition);
  final activities = decodeYoungActivityPage({
    'success': true,
    'code': 200,
    'result': {
      'records': [
        {
          'id': 'synthetic-activity-query',
          'itemName': 'Synthetic activity query row',
          'st': '2026-06-10 09:00:00',
          'et': '2026-06-10 10:00:00',
          'applySt': '2026-06-01 08:00:00',
          'applyEt': '2026-06-09 20:00:00',
          'placeInfo': 'Synthetic room',
        },
      ],
      'total': 1,
    },
  }).records;
  final artifact = YoungCollectedArtifact.seal(
    profileBefore: _youngProfile(_account),
    profileAfter: _youngProfile(_account),
    stamp: ticket.stamp,
    partition: partition,
    session: 1,
    document: 2,
    operation: 3,
    collectedAtUtc: _clock.nowUtc,
    activities: activities,
    entries: const [],
    activityPages: 1,
    calendarPages: 0,
    calendarRows: 0,
    excludedSchedules: 0,
    days: 0,
    firstDay: null,
    lastDay: null,
  );
  return (ticket, partition, artifact);
}

YoungProfileCandidate _youngProfile(String username) => decodeYoungProfile({
  'success': true,
  'code': 200,
  'result': {'username': username},
});

Future<AgentActionView> _readAction(
  JwStore store,
  AgentRunTicket run,
  String actionId,
) async {
  final messages = await store.agent.messages(run.conversationId);
  return messages
      .where((message) => message.role == AgentMessageRole.assistant)
      .expand((message) => message.actions)
      .singleWhere((action) => action.id == actionId);
}

void _expectAction(
  AgentActionView action, {
  required AgentActionStatus status,
  required int count,
}) {
  expect(action.status, status);
  expect(action.committedCount, count);
}

final class _SyntheticProtector implements ModelCredentialProtector {
  @override
  String get mechanism => 'synthetic-source-transaction-protector/v1';
  @override
  Future<Uint8List> protect(
    Uint8List plaintext, {
    required String purpose,
  }) async =>
      Uint8List.fromList([0xA7, ...plaintext.map((byte) => byte ^ 0x5A)]);
  @override
  Future<Uint8List> unprotect(
    Uint8List ciphertext, {
    required String purpose,
  }) async => Uint8List.fromList(
    ciphertext.skip(1).map((byte) => byte ^ 0x5A).toList(),
  );
}

final class _TestOwnership implements AssetOwnership {
  @override
  bool get isHeld => true;
  @override
  void ensureHeld() {}
}
