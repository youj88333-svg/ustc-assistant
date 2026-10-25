import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/jw_academic_details.dart';
import 'package:ustc_assistant_m0/core/jw_credentials.dart';
import 'package:ustc_assistant_m0/core/jw_work_contract.dart';
import 'package:ustc_assistant_m0/core/morning_brief_contract.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/core/young_work_contract.dart';
import 'package:ustc_assistant_m0/data/jw_import_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/data/young_import_contract.dart';
import 'package:ustc_assistant_m0/source/jw_collection_contract.dart';
import 'package:ustc_assistant_m0/source/jw_probe_contract.dart';
import 'package:ustc_assistant_m0/source/young_business_contract.dart';
import 'package:ustc_assistant_m0/source/young_collection_contract.dart';

// M6 / K-09 and the source-preservation promise: exercise the actual C3 import
// and command boundaries with sealed synthetic artifacts, never school IO.
final _day = DateTime.utc(2026, 10, 15);
const _account = 'AB12345';
int _sequence = 0;

void main() {
  test(
    'mixed personal occurrence exposes the correct series and occurrence kind',
    () async {
      final store = await _open();
      await _preferences(store, reminders: true);
      final created = await _write(
        store,
        CreatePersonalEvent(
          PersonalEventDraft(
            title: 'Synthetic mixed series',
            start: _day,
            end: _day.add(const Duration(days: 1)),
            allDay: true,
            weekly: true,
          ),
        ),
      );
      await _write(
        store,
        UpdatePersonalOccurrence(
          created.target!,
          _timed('Synthetic timed exception', 2),
        ),
      );
      final current = (await _occurrence(
        store,
        created.target!.identity,
      )).reference;
      final target = ReminderTarget.calendar(current);
      expect(await store.features.reminderAllDay(target), isFalse);
      expect(await store.features.reminderAllDay(target, series: true), isTrue);
      await store.features.saveReminderPair(
        target,
        ReminderPair.allDay,
        series: true,
      );
      await store.features.saveReminderPair(
        target,
        const ReminderPair(ReminderRule.before(15), ReminderRule.none()),
      );
      expect(
        (await store.features.prepareReminderPublication())
            .desired
            .first
            .request
            .deliveryAtUtc,
        DateTime.utc(2026, 10, 15, 1, 45),
      );
    },
  );
  test(
    'JW and Young imports update durable reminder input and retain overlays',
    () async {
      final store = await _open();
      await _preferences(store, reminders: true);
      final before = await _expected(store);

      await _importJw(store);
      final afterJw = await _expected(store);
      expect(afterJw.$1, greaterThan(before.$1));
      expect(afterJw.$2, contains('Synthetic JW course'));
      final jwPublication = await store.features.prepareReminderPublication();
      expect(jwPublication.desired.single.target.kind, ReminderKind.course);

      await _importYoung(store);
      final afterYoung = await _expected(store);
      expect(afterYoung.$1, greaterThan(afterJw.$1));
      expect(afterYoung.$2, contains('Synthetic Young activity'));
      var publication = await store.features.prepareReminderPublication();
      expect(publication.desired.map((m) => m.target.kind).toSet(), {
        ReminderKind.course,
        ReminderKind.young,
      });
      const coursePair = ReminderPair(
        ReminderRule.before(15),
        ReminderRule.none(),
      );
      const youngPair = ReminderPair(
        ReminderRule.before(45),
        ReminderRule.none(),
      );
      await store.features.saveReminderPair(
        _kind(publication, ReminderKind.course).target,
        coursePair,
      );
      await store.features.saveReminderPair(
        _kind(publication, ReminderKind.young).target,
        youngPair,
      );
      publication = await store.features.prepareReminderPublication();
      final originals = {for (final m in publication.desired) m.target.kind: m};
      await _accept(store, publication);

      await _importJw(store, title: 'Synthetic JW updated');
      await _importYoung(store, title: 'Synthetic Young updated');
      publication = await store.features.prepareReminderPublication();
      expect(publication.desired, hasLength(2));
      for (final current in publication.desired) {
        final original = originals[current.target.kind]!;
        expect(current.logicalKey, original.logicalKey);
        expect(current.request.id, original.request.id);
        expect(current.request.token, original.request.token);
        expect(current.request.deliveryAtUtc, original.request.deliveryAtUtc);
        expect(current.request.digest, isNot(original.request.digest));
        expect(current.accepted, isFalse);
      }
      expect(
        (await store.features.readReminderPair(
          _kind(publication, ReminderKind.course).target,
        ))?.canonical,
        coursePair.canonical,
      );
      expect(
        (await store.features.readReminderPair(
          _kind(publication, ReminderKind.young).target,
        ))?.canonical,
        youngPair.canonical,
      );
      expect(
        _kind(publication, ReminderKind.course).request.deliveryAtUtc,
        DateTime.utc(2026, 10, 15, 1, 45),
      );
      expect(
        _kind(publication, ReminderKind.young).request.deliveryAtUtc,
        DateTime.utc(2026, 10, 15, 2, 15),
      );
      await _accept(store, publication);

      // Direct source overlay commands must update expected state without a UI
      // save callback or a source reimport repairing it later.
      await _hideJw(store, true);
      await _hideYoung(store, true);
      final hidden = await store.features.prepareReminderPublication();
      expect(hidden.desired, isEmpty);
      expect(
        hidden.invalidPriorIds.toSet(),
        originals.values.map((m) => m.request.id).toSet(),
      );
      for (final old in publication.desired) {
        expect(
          await store.features.resolveNotification(_activation(old)),
          isNull,
        );
        await store.features.recordReminderCancelled(old.request.id);
      }

      await _hideJw(store, false);
      await _hideYoung(store, false);
      publication = await store.features.prepareReminderPublication();
      expect(publication.desired, hasLength(2));
      for (final current in publication.desired) {
        expect(current.logicalKey, originals[current.target.kind]!.logicalKey);
        expect(current.request.id, originals[current.target.kind]!.request.id);
      }
      await _accept(store, publication);
      final beforeMissing = publication;

      // Complete selected course scope / selected Young day now contains no
      // source rows. Retain history and overlays, but withdraw effective slots.
      await _importJw(store, omitted: true);
      await _importYoung(store, omitted: true);
      expect(
        (await store.readView()).events.single.presence,
        JwPresence.missingWithinScope,
      );
      expect(
        (await store.readYoungView()).events.single.presence,
        YoungPresence.missingWithinScope,
      );
      final missing = await store.features.prepareReminderPublication();
      expect(missing.desired, isEmpty);
      expect(
        missing.invalidPriorIds.toSet(),
        beforeMissing.desired.map((m) => m.request.id).toSet(),
      );
      expect((await store.readView()).events.single.sourceRetired, isTrue);
      expect((await store.readYoungView()).events.single.sourceRetired, isTrue);
      for (final original in beforeMissing.desired) {
        expect(
          await store.features.resolveNotification(_activation(original)),
          isNull,
        );
      }
    },
  );

  test(
    'failed source transactions do not advance durable reminder input',
    () async {
      var failJw = true;
      var failYoung = true;
      final store = await _open(
        onJw: (checkpoint) async {
          if (failJw && checkpoint == JwImportCheckpoint.beforeCommit) {
            throw const AppFailure(FailureCode.storageFailed);
          }
        },
        onYoung: (checkpoint) async {
          if (failYoung && checkpoint == YoungStoreCheckpoint.beforeCommit) {
            throw const AppFailure(FailureCode.storageFailed);
          }
        },
      );
      await _preferences(store, reminders: true);
      final empty = await _expected(store);
      await expectLater(_importJw(store), throwsA(isA<AppFailure>()));
      expect(await _expected(store), empty);
      expect((await store.readView()).events, isEmpty);
      expect(
        (await store.features.prepareReminderPublication()).desired,
        isEmpty,
      );

      failJw = false;
      await _importJw(store);
      final withCourse = await _expected(store);
      final course = await store.features.prepareReminderPublication();
      await expectLater(_importYoung(store), throwsA(isA<AppFailure>()));
      expect(await _expected(store), withCourse);
      expect((await store.readYoungView()).events, isEmpty);
      final afterFailure = await store.features.prepareReminderPublication();
      expect(
        afterFailure.desired.single.request.digest,
        course.desired.single.request.digest,
      );
      expect(
        afterFailure.desired.single.logicalKey,
        course.desired.single.logicalKey,
      );
      failYoung = false;
      await _importYoung(store);
      expect(
        (await store.features.prepareReminderPublication()).desired,
        hasLength(2),
      );
    },
  );

  test(
    'time-kind changes inherit compatible defaults without losing saved override',
    () async {
      final store = await _open();
      await _preferences(store, reminders: true);
      final created = await _write(
        store,
        CreatePersonalEvent(_timed('Synthetic changing event', 2)),
      );
      await _write(
        store,
        CreatePersonalEvent(_timed('Synthetic unaffected event', 4)),
      );
      const custom = ReminderPair(ReminderRule.before(15), ReminderRule.none());
      await store.features.saveReminderPair(
        ReminderTarget.calendar(created.target!),
        custom,
      );
      final timed = await store.features.prepareReminderPublication();
      final old = timed.desired.singleWhere(
        (m) => m.target.localId == created.target!.identity.localId,
      );
      expect(old.request.deliveryAtUtc, DateTime.utc(2026, 10, 15, 1, 45));

      await _write(
        store,
        UpdatePersonalSeries(
          (await _occurrence(store, created.target!.identity)).reference,
          PersonalEventDraft(
            title: 'Synthetic changing event',
            start: _day,
            end: _day.add(const Duration(days: 1)),
            allDay: true,
          ),
        ),
      );
      final allDay = await store.features.prepareReminderPublication();
      expect(allDay.desired, hasLength(2));
      final switched = allDay.desired.singleWhere(
        (m) => m.target.localId == old.target.localId,
      );
      expect(switched.logicalKey, old.logicalKey);
      expect(switched.request.deliveryAtUtc, DateTime.utc(2026, 10, 15, 1));
      expect(await store.features.readReminderPair(switched.target), isNull);
      expect(
        allDay.desired
            .singleWhere((m) => m.target.localId != old.target.localId)
            .request
            .deliveryAtUtc,
        DateTime.utc(2026, 10, 15, 3, 30),
      );

      await _write(
        store,
        UpdatePersonalSeries(
          (await _occurrence(store, created.target!.identity)).reference,
          _timed('Synthetic changing event', 2),
        ),
      );
      final restored = await store.features.prepareReminderPublication();
      expect(restored.desired, hasLength(2));
      final restoredTarget = restored.desired.singleWhere(
        (m) => m.target.localId == old.target.localId,
      );
      expect(restoredTarget.logicalKey, old.logicalKey);
      expect(restoredTarget.request.deliveryAtUtc, old.request.deliveryAtUtc);
      expect(
        (await store.features.readReminderPair(
          restoredTarget.target,
        ))?.canonical,
        custom.canonical,
      );
    },
  );

  test(
    'morning disable and re-enable invalidate old claim without blocking retry',
    () async {
      final store = await _open();
      await _preferences(store, morning: true);
      final first = (await store.briefs.beginMorningBrief(_day))!;
      expect(await store.briefs.beginMorningModelAttempt(first), isTrue);
      await _preferences(store, morning: false);
      await expectLater(
        store.briefs.ensureMorningTicket(first),
        _staleReminder,
      );
      expect(await store.briefs.beginMorningBrief(_day, manual: true), isNull);
      await _preferences(store, morning: true);
      final second = await store.briefs.beginMorningBrief(_day);
      expect(second, isNotNull);
      expect(second!.id, isNot(first.id));
      expect(second.epoch, greaterThan(first.epoch));
      await expectLater(
        store.briefs.saveMorningBrief(
          first,
          phase: MorningBriefPhase.ready,
          summary: 'Synthetic obsolete summary',
        ),
        _staleReminder,
      );
      await store.briefs.ensureMorningTicket(second);
      await store.briefs.saveMorningBrief(
        second,
        phase: MorningBriefPhase.interrupted,
        failure: 'foreground',
      );
      final manual = await store.briefs.beginMorningBrief(_day, manual: true);
      expect(manual, isNotNull);
      expect(manual!.id, isNot(second.id));
      expect(await store.briefs.beginMorningModelAttempt(manual), isTrue);
      await store.briefs.saveMorningBrief(
        manual,
        phase: MorningBriefPhase.ready,
        summary: 'Synthetic current summary',
      );
      expect(
        (await store.briefs.readMorningBrief(_day))?.summary,
        'Synthetic current summary',
      );
    },
  );

  test(
    'delivered reminder still resolves after reconciliation but not after move or deletion',
    () async {
      final clock = _MutableClock(_day);
      final store = await _open(clock: clock);
      await _preferences(store, reminders: true);
      final event = await _write(
        store,
        CreatePersonalEvent(_timed('Synthetic click target', 2)),
      );
      var publication = await store.features.prepareReminderPublication();
      final first = publication.desired.single;
      await _accept(store, publication);
      clock.nowUtc = DateTime.utc(2026, 10, 15, 1, 31);
      final delivered = await store.features.prepareReminderPublication();
      expect(delivered.desired, isEmpty);
      expect(delivered.invalidPriorIds, isEmpty);
      expect(
        await store.features.resolveNotification(_activation(first)),
        isNotNull,
      );

      await _write(
        store,
        UpdatePersonalSeries(
          (await _occurrence(store, event.target!.identity)).reference,
          _timed('Synthetic click target', 3),
        ),
      );
      expect(
        await store.features.resolveNotification(_activation(first)),
        isNull,
      );
      publication = await store.features.prepareReminderPublication();
      expect(publication.invalidPriorIds, contains(first.request.id));
      final moved = publication.desired.single;
      await _accept(store, publication);
      clock.nowUtc = DateTime.utc(2026, 10, 15, 2, 31);
      expect(
        (await store.features.prepareReminderPublication()).invalidPriorIds,
        isEmpty,
      );
      expect(
        await store.features.resolveNotification(_activation(moved)),
        isNotNull,
      );
      await _write(
        store,
        DeletePersonalSeries(
          (await _occurrence(store, event.target!.identity)).reference,
          confirmed: true,
        ),
      );
      expect(
        await store.features.resolveNotification(_activation(moved)),
        isNull,
      );
      expect(
        (await store.features.prepareReminderPublication()).invalidPriorIds,
        contains(moved.request.id),
      );
    },
  );

  test(
    'a delivered school reminder rejects navigation after choosing not to attend',
    () async {
      final clock = _MutableClock(_day);
      final store = await _open(clock: clock);
      await _preferences(store, reminders: true);
      await _importJw(store);
      final publication = await store.features.prepareReminderPublication();
      final mapping = publication.desired.single;
      await _accept(store, publication);
      clock.nowUtc = DateTime.utc(2026, 10, 15, 1, 31);
      expect(
        (await store.features.prepareReminderPublication()).invalidPriorIds,
        isEmpty,
      );
      expect(
        await store.features.resolveNotification(_activation(mapping)),
        isNotNull,
      );
      final identity = CalendarIdentity(
        CalendarKind.course,
        mapping.target.localId,
      );
      await _write(
        store,
        UpdateSchoolAnnotation(
          (await _occurrence(store, identity)).reference,
          attendance: AttendanceDecision.skip,
        ),
      );
      expect(
        await store.features.resolveNotification(_activation(mapping)),
        isNull,
      );
      expect(
        (await store.features.prepareReminderPublication()).invalidPriorIds,
        contains(mapping.request.id),
      );
    },
  );
}

final _staleReminder = throwsA(
  isA<ReminderFailure>().having(
    (failure) => failure.code,
    'code',
    ReminderFailureCode.stale,
  ),
);

Future<JwStore> _open({
  _MutableClock? clock,
  Future<void> Function(JwImportCheckpoint)? onJw,
  Future<void> Function(YoungStoreCheckpoint)? onYoung,
}) async {
  final protector = _SyntheticProtector();
  final store = JwStore(
    NativeDatabase.memory(),
    ownership: _SyntheticOwnership(),
    clock: clock ?? _MutableClock(_day),
    credentialProtector: protector,
    modelCredentialProtector: protector,
    onCheckpoint: onJw,
    onYoungCheckpoint: onYoung,
  );
  addTearDown(store.close);
  await store.initialize();
  await store.agent.initializeAgent();
  await store.features.initialize();
  return store;
}

Future<void> _preferences(
  JwStore store, {
  bool? reminders,
  bool? morning,
}) async {
  final current = await store.features.inspectReminders();
  await store.features.saveReminderPreferences(
    current,
    current.preferences.copyWith(enabled: reminders, morningEnabled: morning),
  );
}

Future<(int, String?)> _expected(JwStore store) async {
  final row = await store
      .customSelect(
        'SELECT revision,input_json FROM m6_expected WHERE singleton=1',
      )
      .getSingle();
  return (row.read<int>('revision'), row.read<String?>('input_json'));
}

Future<CalendarWindow> _window(JwStore store) => store.localCalendar.query(
  CalendarQuery(
    firstDay: _day,
    endDayExclusive: _day.add(const Duration(days: 2)),
    includeHidden: true,
    includeSkipped: true,
  ),
);

Future<CalendarOccurrence> _occurrence(
  JwStore store,
  CalendarIdentity identity,
) async => (await _window(
  store,
)).items.singleWhere((item) => item.reference.identity == identity);

Future<CalendarWriteReceipt> _write(
  JwStore store,
  CalendarIntent intent,
) async => store.localCalendar.commit(
  await store.localCalendar.prepare((await _window(store)).context, intent),
);

PersonalEventDraft _timed(String title, int hour) => PersonalEventDraft(
  title: title,
  start: DateTime.utc(2026, 10, 15, hour),
  end: DateTime.utc(2026, 10, 15, hour + 1),
);

ReminderMapping _kind(ReminderPublication publication, ReminderKind kind) =>
    publication.desired.singleWhere((mapping) => mapping.target.kind == kind);

NotificationActivation _activation(ReminderMapping mapping) =>
    NotificationActivation(
      mapping.request.id,
      mapping.request.digest,
      mapping.request.token,
    );

Future<void> _accept(JwStore store, ReminderPublication publication) async {
  for (final mapping in publication.desired) {
    await store.features.recordReminderAccepted(
      publication,
      mapping.request.id,
    );
  }
}

String _id(String prefix) =>
    '$prefix${(++_sequence).toRadixString(16).padLeft(32, '0')}';

Future<void> _hideJw(JwStore store, bool hidden) async {
  final event = (await store.readView()).events.single;
  final authority = await store.readAuthority();
  await store.setHidden(
    JwHiddenCommand(
      operationId: _id('jw-local-'),
      ownerId: authority.ownerId,
      accountId: 1,
      resetEpoch: authority.resetEpoch,
      localId: event.localId,
      expectedVersion: event.version,
      hidden: hidden,
    ),
  );
}

Future<void> _hideYoung(JwStore store, bool hidden) async {
  final event = (await store.readYoungView()).events.single;
  final authority = await store.readYoungAuthority();
  await store.setYoungHidden(
    YoungHiddenCommand(
      operationId: _id('young-local-'),
      ownerId: authority.ownerId,
      accountId: 1,
      resetEpoch: authority.resetEpoch,
      localId: event.localId,
      expectedVersion: event.version,
      hidden: hidden,
    ),
  );
}

Future<void> _importJw(
  JwStore store, {
  String title = 'Synthetic JW course',
  bool omitted = false,
}) async {
  final ticket = await store.beginJob(expectedAccountCode: _account);
  final partition = JwPartitionRef(
    id: _id('jwp-'),
    ownerId: ticket.stamp.ownerId,
    purpose: JwPartitionPurpose.initial,
    attempt: ticket.stamp.jobId,
    resetEpoch: ticket.stamp.resetEpoch,
  );
  await store.stagePartition(ticket, partition);
  await store.stageSemesterCatalog(ticket, const [
    JwSemesterOption(id: 202610, name: 'Synthetic semester', selected: false),
  ]);
  final count = omitted ? 0 : 1;
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
      'diagnostics': {
        'checks': {
          'identityBefore': 'ok',
          'course': 'ok',
          'index': 'ok',
          'datum': omitted ? 'skipped' : 'ok',
          'exams': 'ok',
          'identityAfter': 'ok',
        },
        'reason': 'none',
        'identityReads': 2,
        'lessonIds': count,
        'lessons': count,
        'groups': count,
        'schedules': count,
        'datedSchedules': count,
        'timedSchedules': count,
        'linkedSchedules': count,
        'examRows': 0,
        'datedExams': 0,
        'semesterAccepted': true,
        'selfRouteBound': true,
        'identityStable': true,
        'emptyCourse': omitted,
        'emptyExams': true,
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
      },
      'snapshot': {
        'version': jwContractVersion,
        'semesterId': 202610,
        'courses': [
          if (!omitted)
            {
              'lessonId': 101,
              'groupId': 1101,
              'date': '2026-10-15',
              'startMinute': 600,
              'endMinute': 660,
              'title': title,
              'academicDetails': JwAcademicDetails(
                lessonId: 101,
                groupId: 1101,
              ).toMap(),
            },
        ],
        'exams': <Object>[],
      },
    }),
    operation: 31,
  );
  await store.importSnapshot(
    ticket,
    JwCollectedArtifact.seal(
      reply: reply,
      stamp: ticket.stamp,
      partition: partition,
      session: 1,
      document: 2,
      semesterId: 202610,
      collectedAtUtc: _day,
    ),
  );
}

Future<void> _importYoung(
  JwStore store, {
  String title = 'Synthetic Young activity',
  bool omitted = false,
}) async {
  final ticket = await store.beginYoungJob(
    kind: YoungJobKind.calendar,
    expectedAccountCode: _account,
    firstDay: _day,
    lastDay: _day,
  );
  final partition = YoungPartitionRef(
    id: _id('yp-'),
    ownerId: ticket.stamp.ownerId,
    purpose: ticket.stamp.accountId == null
        ? YoungPartitionPurpose.initial
        : YoungPartitionPurpose.recovery,
    attempt: ticket.stamp.jobId,
    resetEpoch: ticket.stamp.resetEpoch,
  );
  await store.stageYoungPartition(ticket, partition);
  final records = <Map<String, Object?>>[
    if (!omitted)
      {
        'id': 'synthetic-calendar-01',
        'itemId': 'synthetic-activity-01',
        'title': title,
        'place': 'Synthetic room',
        'startTime': '2026-10-15 11:00:00',
        'endTime': '2026-10-15 12:00:00',
      },
  ];
  final entries = decodeYoungCalendarPage({
    'success': true,
    'code': 200,
    'result': {'records': records, 'total': records.length},
  }).records;
  final profile = decodeYoungProfile({
    'success': true,
    'code': 200,
    'result': {'username': _account},
  });
  await store.importYoungCalendar(
    ticket,
    YoungCollectedArtifact.seal(
      profileBefore: profile,
      profileAfter: profile,
      stamp: ticket.stamp,
      partition: partition,
      session: 1,
      document: 2,
      operation: 3,
      collectedAtUtc: _day,
      activities: const [],
      entries: entries,
      activityPages: 0,
      calendarPages: 1,
      calendarRows: records.length,
      excludedSchedules: 0,
      days: 1,
      firstDay: _day,
      lastDay: _day,
    ),
  );
}

final class _MutableClock implements AppClock {
  _MutableClock(this.nowUtc);
  @override
  DateTime nowUtc;
}

final class _SyntheticOwnership implements AssetOwnership {
  @override
  bool get isHeld => true;
  @override
  void ensureHeld() {}
}

final class _SyntheticProtector
    implements JwCredentialProtector, ModelCredentialProtector {
  @override
  String get mechanism => 'synthetic-m6-source-test/v1';
  @override
  Future<Uint8List> protect(
    Uint8List plaintext, {
    required String purpose,
  }) async => Uint8List.fromList(plaintext.map((byte) => byte ^ 0x5A).toList());
  @override
  Future<Uint8List> unprotect(
    Uint8List ciphertext, {
    required String purpose,
  }) async =>
      Uint8List.fromList(ciphertext.map((byte) => byte ^ 0x5A).toList());
}
