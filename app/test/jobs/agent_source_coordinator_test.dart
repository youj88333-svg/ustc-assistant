import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/agent_source_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/jw_academic_details.dart';
import 'package:ustc_assistant_m0/core/jw_work_contract.dart';
import 'package:ustc_assistant_m0/core/young_work_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/data/young_import_contract.dart';
import 'package:ustc_assistant_m0/jobs/agent_source_coordinator.dart';
import 'package:ustc_assistant_m0/jobs/jw_sync_port.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_port.dart';
import 'package:ustc_assistant_m0/source/jw_collection_contract.dart';
import 'package:ustc_assistant_m0/source/jw_probe_contract.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';
import 'package:ustc_assistant_m0/source/young_collection_contract.dart';

const _account = 'SYNTHETIC001';
final _clock = FixedClock(DateTime.utc(2026, 10, 13, 8));
final _key = Uint8List.fromList('synthetic-source-key'.codeUnits);
int _partitionSequence = 0;

void main() {
  test(
    'semester choices are opaque and expire across runs or directory changes',
    () async {
      final store = await _openStore();
      await _commitJwDirectory(store, name: '合成学期甲');
      final jw = _FakeJwSyncPort();
      final young = _FakeYoungSyncPort();
      final source = _coordinator(store, jw, young);

      final firstRun = await _beginRun(store);
      await _sourceAction(store, firstRun);
      final firstOptions = await source.readOptions(firstRun);
      final firstReference = firstOptions.semesters.single.reference;
      expect(firstReference, matches(RegExp(r'^semester_[0-9a-f]{24}$')));
      expect(firstReference, isNot(contains('202610')));
      expect(firstOptions.semesters.single.label, '合成学期甲');
      await store.agent.finishRun(firstRun, AgentMessageStatus.complete);

      final nextRun = await _beginRun(store);
      final nextAction = await _sourceAction(store, nextRun);
      await store.agent.approveSourceAction(nextRun, nextAction);
      await expectLater(
        source.refresh(
          nextRun,
          nextAction,
          AgentSourceRequest(
            AgentRefreshSource.jw,
            semesterReference: firstReference,
          ),
        ),
        throwsA(
          isA<AgentFailure>().having(
            (failure) => failure.code,
            'code',
            AgentFailureCode.staleContext,
          ),
        ),
      );
      expect(jw.startCalls, 0);

      final currentReference = (await source.readOptions(
        nextRun,
      )).semesters.single.reference;
      await _commitJwDirectory(store, name: '合成学期乙');
      await expectLater(
        source.refresh(
          nextRun,
          nextAction,
          AgentSourceRequest(
            AgentRefreshSource.jw,
            semesterReference: currentReference,
          ),
        ),
        throwsA(
          isA<AgentFailure>().having(
            (failure) => failure.code,
            'code',
            AgentFailureCode.staleContext,
          ),
        ),
      );
      expect(jw.startCalls, 0);
      await store.agent.cancelRun(nextRun);
    },
  );

  test(
    'an unapproved refresh card cannot start C2 or import a source',
    () async {
      final store = await _openStore();
      final jw = _FakeJwSyncPort();
      final young = _FakeYoungSyncPort();
      final source = _coordinator(store, jw, young);
      final run = await _beginRun(store);
      final action = await _sourceAction(store, run);

      await expectLater(
        source.refresh(
          run,
          action,
          const AgentSourceRequest(AgentRefreshSource.jw),
        ),
        throwsA(
          isA<AgentFailure>().having(
            (failure) => failure.code,
            'code',
            AgentFailureCode.consentRequired,
          ),
        ),
      );
      expect(jw.startCalls, 0);
      expect(young.calendarStarts, 0);
      expect((await store.readView()).importCount, 0);
      await store.agent.cancelRun(run);
    },
  );

  test(
    'a 31-day half-open window reaches Young as an inclusive last day',
    () async {
      final store = await _openStore();
      final jw = _FakeJwSyncPort();
      final young = _FakeYoungSyncPort();
      final source = _coordinator(store, jw, young);
      final run = await _beginRun(store);
      final action = await _sourceAction(store, run);
      await store.agent.approveSourceAction(run, action);
      final first = DateTime.utc(2026, 1, 1);
      final endExclusive = DateTime.utc(2026, 2, 1);

      final result = await source.refresh(
        run,
        action,
        AgentSourceRequest(
          AgentRefreshSource.youngCalendar,
          firstDay: first,
          endDayExclusive: endExclusive,
        ),
      );
      expect(result.committed, isTrue);
      expect(young.calendarStarts, 1);
      expect(young.firstDay, first);
      expect(young.lastDay, DateTime.utc(2026, 1, 31));

      await expectLater(
        source.refresh(
          run,
          action,
          AgentSourceRequest(
            AgentRefreshSource.youngCalendar,
            firstDay: first,
            endDayExclusive: DateTime.utc(2026, 2, 2),
          ),
        ),
        throwsA(
          isA<AgentFailure>().having(
            (failure) => failure.code,
            'code',
            AgentFailureCode.invalidInput,
          ),
        ),
      );
      expect(young.calendarStarts, 1);
      await store.agent.cancelRun(run);
    },
  );

  test(
    'school challenge continues the same job and cancellation stays source-local',
    () async {
      final store = await _openStore();
      final jw = _FakeJwSyncPort();
      final young = _FakeYoungSyncPort();
      final source = _coordinator(store, jw, young);
      final run = await _beginRun(store);
      final action = await _sourceAction(store, run);
      await store.agent.approveSourceAction(run, action);

      jw.onStart = (_) async {
        jw.emit(
          JwSyncView(
            phase: JwSyncPhase.login,
            automation: JwAutomationState.manualRequired,
          ),
        );
      };
      jw.onContinue = () async => jw.emit(
        JwSyncView(
          phase: JwSyncPhase.idle,
          importCommitted: true,
          courseCount: 2,
          examCount: 1,
        ),
      );
      final pending = source.refresh(
        run,
        action,
        const AgentSourceRequest(AgentRefreshSource.jw),
      );
      await _waitUntil(() => source.waitingForSchool);
      await source.continueSchool();
      final result = await pending;
      expect(result.committed, isTrue);
      expect(jw.startCalls, 1);
      expect(jw.continueCalls, 1);
      expect(source.waitingForSchool, isFalse);

      young.onActivities = () async => young.emit(
        YoungSyncView(
          phase: YoungSyncPhase.login,
          kind: YoungJobKind.activities,
          automation: YoungAutomationState.manualRequired,
        ),
      );
      final waiting = source.queryActivities(run);
      await _waitUntil(() => source.waitingForSchool);
      await source.cancelAndDrain();
      final cancelled = await waiting;
      expect(cancelled.committed, isFalse);
      expect(cancelled.failure, 'cancelled');
      expect(young.cancelCalls, 1);
      expect(jw.cancelCalls, 0);
      await store.agent.cancelRun(run);
    },
  );

  test(
    'empty results differ from unavailable and activity output stays bounded',
    () async {
      final store = await _openStore();
      final jw = _FakeJwSyncPort();
      final young = _FakeYoungSyncPort();
      final source = _coordinator(store, jw, young);
      final run = await _beginRun(store);

      final empty = await source.queryActivities(run);
      expect(empty.committed, isTrue);
      expect(empty.complete, isTrue);
      expect(empty.count, 0);
      expect(empty.activities, isEmpty);
      expect(empty.failure, isNull);

      young.onActivities = () async => young.emit(
        YoungSyncView(
          phase: YoungSyncPhase.idle,
          kind: YoungJobKind.activities,
          committed: false,
        ),
      );
      final unavailable = await source.queryActivities(run);
      expect(unavailable.committed, isFalse);
      expect(unavailable.complete, isFalse);
      expect(unavailable.count, 0);
      expect(unavailable.failure, 'unavailable');

      young.onActivities = () async => young.emit(
        YoungSyncView(
          phase: YoungSyncPhase.idle,
          kind: YoungJobKind.activities,
          committed: true,
          normalization: _stats(activities: 27),
          activityResults: [for (var i = 0; i < 27; i++) _activity(i)],
        ),
      );
      final bounded = await source.queryActivities(run);
      expect(bounded.committed, isTrue);
      expect(bounded.count, 27);
      expect(bounded.activities, hasLength(20));
      expect(bounded.complete, isFalse);
      await store.agent.cancelRun(run);
    },
  );

  test(
    'a committed query with failed delivery is neither complete nor empty',
    () async {
      final store = await _openStore();
      final jw = _FakeJwSyncPort();
      final young = _FakeYoungSyncPort();
      final source = _coordinator(store, jw, young);
      final run = await _beginRun(store);
      for (final count in [0, 3]) {
        young.onActivities = () async => young.emit(
          YoungSyncView(
            phase: YoungSyncPhase.idle,
            kind: YoungJobKind.activities,
            committed: true,
            normalization: _stats(activities: count),
            failure: FailureCode.storageFailed,
            failureStage: YoungSyncPhase.closing,
          ),
        );
        final result = await source.queryActivities(run);
        expect(result.committed, isTrue);
        expect(result.count, count);
        expect(result.failure, 'storageFailed');
        expect(result.complete, isFalse);
        expect(result.activities, isEmpty);
      }
      await store.agent.cancelRun(run);
    },
  );

  test(
    'a busy driver cannot turn its previous success into a fresh result',
    () async {
      final store = await _openStore();
      final jw = _FakeJwSyncPort();
      final young = _FakeYoungSyncPort();
      final source = _coordinator(store, jw, young);
      final run = await _beginRun(store);
      final action = await _sourceAction(store, run);
      await store.agent.approveSourceAction(run, action);
      jw.emit(
        JwSyncView(
          phase: JwSyncPhase.recovery,
          importCommitted: true,
          courseCount: 41,
          examCount: 9,
        ),
      );
      jw.onStart = (_) async {};

      await expectLater(
        source.refresh(
          run,
          action,
          const AgentSourceRequest(AgentRefreshSource.jw),
        ),
        throwsA(
          isA<AgentFailure>().having(
            (failure) => failure.code,
            'code',
            AgentFailureCode.busy,
          ),
        ),
      );
      expect(jw.startCalls, 1);
      jw.emit(JwSyncView(phase: JwSyncPhase.idle));
      await store.agent.cancelRun(run);
    },
  );
  test('real C2 lease admission busy remains a busy result', () async {
    final store = await _openStore();
    final jw = _FakeJwSyncPort();
    final young = _FakeYoungSyncPort();
    final source = _coordinator(store, jw, young);
    final run = await _beginRun(store);
    final record = await _sourceAction(store, run);
    await store.agent.approveSourceAction(run, record);
    jw.onStart = (_) async {
      throw const AppFailure(FailureCode.busy);
    };
    await expectLater(
      source.refresh(
        run,
        record,
        const AgentSourceRequest(AgentRefreshSource.jw),
      ),
      throwsA(
        isA<AgentFailure>().having(
          (e) => e.code,
          'code',
          AgentFailureCode.busy,
        ),
      ),
    );
    expect(young.calendarStarts, 0);
    await store.agent.cancelRun(run);
  });

  test(
    'cancelAndDrain recovers a dedicated source after busy without closing it',
    () async {
      final store = await _openStore();
      final jw = _FakeJwSyncPort();
      final young = _FakeYoungSyncPort();
      final source = _coordinator(store, jw, young);
      final run = await _beginRun(store);
      final action = await _sourceAction(store, run);
      await store.agent.approveSourceAction(run, action);
      var starts = 0;
      jw.onStart = (_) async {
        starts++;
        jw.emit(
          starts == 1
              ? JwSyncView(
                  phase: JwSyncPhase.recovery,
                  importCommitted: true,
                  courseCount: 41,
                  examCount: 9,
                )
              : JwSyncView(
                  phase: JwSyncPhase.idle,
                  importCommitted: true,
                  courseCount: 2,
                  examCount: 1,
                ),
        );
      };
      jw.onCancel = () async => jw.emit(
        JwSyncView(
          phase: JwSyncPhase.recovery,
          importCommitted: true,
          courseCount: 41,
          examCount: 9,
        ),
      );
      jw.onRetryRecovery = () async =>
          jw.emit(JwSyncView(phase: JwSyncPhase.idle));

      await expectLater(
        source.refresh(
          run,
          action,
          const AgentSourceRequest(AgentRefreshSource.jw),
        ),
        throwsA(
          isA<AgentFailure>().having(
            (failure) => failure.code,
            'code',
            AgentFailureCode.busy,
          ),
        ),
      );
      expect(source.waitingForSchool, isFalse);
      expect(jw.startCalls, 1);
      expect(jw.cancelCalls, 0);

      await source.cancelAndDrain();
      expect(jw.cancelCalls, 1);
      expect(jw.retryRecoveryCalls, 1);
      expect(young.cancelCalls, 0);
      expect(young.retryRecoveryCalls, 0);

      final recovered = await source.refresh(
        run,
        action,
        const AgentSourceRequest(AgentRefreshSource.jw),
      );
      expect(recovered.committed, isTrue);
      expect(recovered.count, 3);
      expect(recovered.failure, isNull);
      expect(jw.startCalls, 2);
      expect(source.waitingForSchool, isFalse);
      await store.agent.cancelRun(run);
    },
  );
}

AgentSourceCoordinator _coordinator(
  JwStore store,
  _FakeJwSyncPort jw,
  _FakeYoungSyncPort young,
) {
  final source = AgentSourceCoordinator(
    store: store,
    jw: jw,
    young: young,
    shutdownSources: () async {},
    clock: _clock,
  );
  addTearDown(source.close);
  return source;
}

Future<JwStore> _openStore() async {
  final store = JwStore(
    NativeDatabase.memory(),
    ownership: _TestOwnership(),
    clock: _clock,
    modelCredentialProtector: _SyntheticProtector(),
  );
  addTearDown(store.close);
  await store.initialize();
  await store.agent.initializeAgent();
  final settings = await store.agent.inspectAgent();
  await store.agent.saveModelConfiguration(
    settings.authority,
    modelId: 'synthetic-source-model',
    modelIds: const ['synthetic-source-model'],
    report: const AgentCapabilityReport(text: true, streaming: true),
    consent: true,
    key: _key,
  );
  return store;
}

Future<AgentRunTicket> _beginRun(JwStore store) async {
  final settings = await store.agent.inspectAgent();
  final conversation = await store.agent.createConversation();
  return store.agent.beginRun(settings.authority, conversation, '仅用于合成来源编排回归');
}

Future<AgentActionView> _sourceAction(JwStore store, AgentRunTicket ticket) =>
    store.agent.prepareActionRecord(
      ticket,
      AgentActionKind.sourceRefresh,
      '合成来源刷新',
      const ['只用于本地行为验证'],
    );

Future<void> _commitJwDirectory(JwStore store, {required String name}) async {
  final ticket = await store.beginJob(expectedAccountCode: _account);
  final partition = JwPartitionRef(
    id: 'jwp-${(++_partitionSequence).toRadixString(16).padLeft(32, '0')}',
    ownerId: ticket.stamp.ownerId,
    purpose: ticket.stamp.accountId == null
        ? JwPartitionPurpose.initial
        : JwPartitionPurpose.recovery,
    attempt: ticket.stamp.jobId,
    resetEpoch: ticket.stamp.resetEpoch,
  );
  await store.stagePartition(ticket, partition);
  await store.stageSemesterCatalog(ticket, [
    JwSemesterOption(id: 202610, name: name, selected: true),
  ]);
  await store.importSnapshot(ticket, _jwArtifact(ticket, partition));
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

YoungCollectionStats _stats({int activities = 0}) => YoungCollectionStats(
  calendarRows: 0,
  events: 0,
  excludedSchedules: 0,
  duplicateSchedules: 0,
  days: 0,
  calendarPages: 0,
  activityPages: activities == 0 ? 0 : 1,
  activities: activities,
);

YoungActivityView _activity(int index) => YoungActivityView(
  title: '合成活动 $index',
  place: '合成地点',
  startsAtUtc: DateTime.utc(2026, 10, 20, 9),
  endsAtUtc: DateTime.utc(2026, 10, 20, 10),
  registrationStartsAtUtc: null,
  registrationEndsAtUtc: null,
);

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 20 && !condition(); attempt++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}

final class _FakeJwSyncPort implements JwSyncPort {
  final _changes = StreamController<JwSyncView>.broadcast();
  JwSyncView _view = JwSyncView();
  Future<void> Function(int? semesterId)? onStart;
  Future<void> Function()? onContinue;
  Future<void> Function()? onCancel;
  Future<void> Function()? onRetryRecovery;
  int startCalls = 0,
      continueCalls = 0,
      cancelCalls = 0,
      retryRecoveryCalls = 0;

  @override
  JwSyncView get syncView => _view;
  @override
  Stream<JwSyncView> get syncChanges => _changes.stream;
  void emit(JwSyncView view) {
    _view = view;
    _changes.add(view);
  }

  @override
  Future<void> startSync({
    String? expectedAccountCode,
    String? password,
    bool savePassword = false,
    int? semesterId,
  }) async {
    startCalls++;
    if (onStart case final start?) {
      await start(semesterId);
    } else {
      emit(
        JwSyncView(
          phase: JwSyncPhase.idle,
          importCommitted: true,
          courseCount: 1,
          examCount: 1,
        ),
      );
    }
  }

  @override
  Future<void> continueSync() async {
    continueCalls++;
    await onContinue?.call();
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    if (onCancel case final cancel?) {
      await cancel();
    } else {
      emit(JwSyncView(phase: JwSyncPhase.idle));
    }
  }

  @override
  Future<void> open({String? expectedAccountCode}) async {}
  @override
  Future<void> deleteSavedCredential() async {}
  @override
  Future<void> navigateJwPage(JwObservationPage page) async {}
  @override
  Future<void> verifyDirectory() async {}
  @override
  Future<void> collect(int semesterId) async {}
  @override
  Future<void> retryRecovery() async {
    retryRecoveryCalls++;
    await onRetryRecovery?.call();
  }

  @override
  Future<void> clearSession() async {}
  @override
  Future<void> setHidden({
    required int localId,
    required int expectedVersion,
    required bool hidden,
  }) async {}
}

final class _FakeYoungSyncPort implements YoungSyncPort {
  final _changes = StreamController<YoungSyncView>.broadcast();
  YoungSyncView _view = YoungSyncView();
  Future<void> Function()? onActivities;
  Future<void> Function()? onContinue;
  int calendarStarts = 0,
      activitiesStarts = 0,
      continueCalls = 0,
      cancelCalls = 0,
      retryRecoveryCalls = 0;
  DateTime? firstDay, lastDay;

  @override
  YoungSyncView get syncView => _view;
  @override
  Stream<YoungSyncView> get syncChanges => _changes.stream;
  void emit(YoungSyncView view) {
    _view = view;
    _changes.add(view);
  }

  @override
  Future<void> startCalendar({
    String? expectedAccountCode,
    required DateTime firstDay,
    required DateTime lastDay,
    String? password,
    bool savePassword = false,
  }) async {
    calendarStarts++;
    this.firstDay = firstDay;
    this.lastDay = lastDay;
    emit(
      YoungSyncView(
        phase: YoungSyncPhase.idle,
        kind: YoungJobKind.calendar,
        committed: true,
        normalization: _stats(),
      ),
    );
  }

  @override
  Future<void> startActivities({
    String? expectedAccountCode,
    String? password,
    bool savePassword = false,
  }) async {
    activitiesStarts++;
    if (onActivities case final start?) {
      await start();
    } else {
      emit(
        YoungSyncView(
          phase: YoungSyncPhase.idle,
          kind: YoungJobKind.activities,
          committed: true,
          normalization: _stats(),
        ),
      );
    }
  }

  @override
  Future<void> continueAfterLogin() async {
    continueCalls++;
    await onContinue?.call();
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    emit(YoungSyncView(phase: YoungSyncPhase.idle, kind: syncView.kind));
  }

  @override
  Future<void> retryRecovery() async {
    retryRecoveryCalls++;
  }

  @override
  Future<void> clearSession() async {}
  @override
  Future<void> deleteSavedCredential() async {}
  @override
  Future<void> setHidden({
    required int localId,
    required int expectedVersion,
    required bool hidden,
  }) async {}
}

final class _SyntheticProtector implements ModelCredentialProtector {
  @override
  String get mechanism => 'synthetic-source-protector/v1';
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
