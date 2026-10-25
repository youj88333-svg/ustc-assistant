import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/morning_brief_contract.dart';
import 'package:ustc_assistant_m0/core/morning_notice_contract.dart';
import 'package:ustc_assistant_m0/core/public_query_contract.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';

final _day = DateTime.utc(2026, 10, 15);
final _now = DateTime.utc(2026, 10, 15, 0);
final _syntheticKey = Uint8List.fromList('synthetic-model-key-01'.codeUnits);

void main() {
  test(
    'Chinese notice caches stay within byte retention and expire by day',
    () async {
      final clock = _MutableClock(_now);
      final store = await _open(clock: clock);
      await _enableMorning(store);
      for (var offset = 0; offset < 31; offset++) {
        final day = _day.add(Duration(days: offset));
        clock.nowUtc = day;
        final ticket = (await store.briefs.beginMorningBrief(day))!;
        final yesterday = day.subtract(const Duration(days: 1));
        await store.briefs.saveMorningBrief(
          ticket,
          phase: MorningBriefPhase.ready,
          notices: MorningNoticeBatch(
            day: yesterday,
            operations: 10,
            coverage: const [],
            notices: List.generate(
              200,
              (index) => MorningNotice(
                provider: PublicProvider.teach,
                title: List.filled(390, '文').join(),
                articleUrl: Uri.parse(
                  'https://www.teach.ustc.edu.cn/2026/10/14/retention$index',
                ),
                publishedDay: yesterday,
                observedAtUtc: clock.nowUtc,
              ),
            ),
          ),
          summary: '合成晨报',
        );
      }
      expect(
        await _scalar(
          store,
          "SELECT COALESCE(SUM(length(CAST(COALESCE(notices_json,'')||summary AS BLOB))),0) FROM m6_briefs",
        ),
        lessThanOrEqualTo(5 * 1024 * 1024),
      );
      expect(
        await _scalar(store, 'SELECT COUNT(*) FROM m6_briefs'),
        lessThan(30),
      );
      clock.nowUtc = clock.nowUtc.add(const Duration(days: 31));
      await store.features.initialize();
      expect(await _scalar(store, 'SELECT COUNT(*) FROM m6_briefs'), 0);
    },
  );
  test(
    'facts use Beijing day and status while excluding private notes and descriptions',
    () async {
      final store = await _open();
      await _enableMorning(store);
      final context = await _context(store, _day);
      await _write(
        store,
        context,
        CreatePersonalEvent(
          PersonalEventDraft(
            title: 'synthetic 10 am appointment',
            start: DateTime.utc(2026, 10, 15, 2),
            end: DateTime.utc(2026, 10, 15, 3),
            location: 'synthetic campus room',
            note: 'private agenda note sentinel',
          ),
        ),
      );
      await _write(
        store,
        context,
        CreatePersonalEvent(
          PersonalEventDraft(
            title: 'synthetic all day event',
            start: _day,
            end: _day.add(const Duration(days: 1)),
            allDay: true,
            note: 'private all day note sentinel',
          ),
        ),
      );
      final skippedReceipt = await _write(
        store,
        context,
        CreatePersonalEvent(
          PersonalEventDraft(
            title: 'synthetic skipped event',
            start: DateTime.utc(2026, 10, 15, 6),
            end: DateTime.utc(2026, 10, 15, 7),
            note: 'private skipped note sentinel',
          ),
        ),
      );
      await _write(
        store,
        context,
        SetPersonalOccurrenceState(skippedReceipt.target!, skipped: true),
      );
      await _write(
        store,
        context,
        CreateTask(
          TaskDraft(
            title: 'synthetic same day deadline',
            description: 'private task description sentinel',
            note: 'private task note sentinel',
            deadlineAtUtc: DateTime.utc(2026, 10, 15, 10),
          ),
        ),
      );

      final facts = await store.briefs.morningFacts(_day);
      expect(facts.day, _day);
      expect(facts.complete, isTrue);
      expect(facts.overdueTasks, 0);
      expect(facts.hasSchoolImports, isFalse);
      final timed = facts.agenda.singleWhere(
        (item) => item.title == 'synthetic 10 am appointment',
      );
      expect(timed.start, DateTime.utc(2026, 10, 15, 2));
      expect(timed.kind, 'personal');
      expect(timed.state, 'planned');
      final allDay = facts.agenda.singleWhere(
        (item) => item.title == 'synthetic all day event',
      );
      expect(allDay.allDay, isTrue);
      final skipped = facts.agenda.singleWhere(
        (item) => item.title == 'synthetic skipped event',
      );
      expect(skipped.state, 'skipped');
      expect(facts.tasks, hasLength(1));
      expect(facts.tasks.single.title, 'synthetic same day deadline');
      expect(facts.tasks.single.deadline, DateTime.utc(2026, 10, 15, 10));

      final summaryInput = jsonEncode({
        'agenda': facts.agenda.map((item) => item.canonical).toList(),
        'tasks': facts.tasks.map((item) => item.canonical).toList(),
        'conflicts': facts.conflicts,
        'overdueTasks': facts.overdueTasks,
        'complete': facts.complete,
      });
      for (final privateText in const [
        'private agenda note sentinel',
        'private all day note sentinel',
        'private skipped note sentinel',
        'private task description sentinel',
        'private task note sentinel',
      ]) {
        expect(summaryInput, isNot(contains(privateText)));
        expect(facts.digest, isNot(contains(privateText)));
      }

      final ticket = await store.briefs.beginMorningBrief(_day);
      expect(ticket, isNotNull);
      expect(ticket!.factDigest, facts.digest);
      expect(await store.briefs.beginMorningBrief(_day), isNull);
    },
  );

  test(
    'automatic claims recover interrupted work, cap attempts, and retain cache',
    () async {
      final file = await _temporaryDatabase('morning-brief-cache-');
      final clock = _MutableClock(_now);
      var store = await _open(file: file, clock: clock);
      await _enableMorning(store);
      final context = await _context(store, _day);
      final event = await _write(
        store,
        context,
        CreatePersonalEvent(
          PersonalEventDraft(
            title: 'synthetic persisted agenda asset',
            start: DateTime.utc(2026, 10, 15, 5),
            end: DateTime.utc(2026, 10, 15, 6),
          ),
        ),
      );
      await _write(
        store,
        context,
        const CreateTask(TaskDraft(title: 'synthetic persisted task asset')),
      );
      await _configureSyntheticAgent(store);
      await store.agent.createConversation();

      final first = await store.briefs.beginMorningBrief(_day);
      expect(first, isNotNull);
      expect(await store.briefs.beginMorningBrief(_day), isNull);
      expect(await store.briefs.beginMorningModelAttempt(first!), isTrue);
      expect(await store.briefs.beginMorningModelAttempt(first), isTrue);
      expect(await store.briefs.beginMorningModelAttempt(first), isFalse);
      await store.close();

      store = await _open(file: file, clock: clock);
      final interrupted = await store.briefs.readMorningBrief(_day);
      expect(interrupted?.phase, MorningBriefPhase.interrupted);
      expect(interrupted?.autoAttempts, 2);
      final retry = await store.briefs.beginMorningBrief(_day);
      expect(retry, isNotNull);
      expect(await store.briefs.beginMorningModelAttempt(retry!), isFalse);
      await store.briefs.saveMorningBrief(
        retry,
        phase: MorningBriefPhase.interrupted,
        failure: 'attemptLimit',
      );

      final manual = await store.briefs.beginMorningBrief(_day, manual: true);
      expect(manual, isNotNull);
      expect(await store.briefs.beginMorningModelAttempt(manual!), isTrue);
      await store.briefs.saveMorningBrief(
        manual,
        phase: MorningBriefPhase.ready,
        summary: 'synthetic brief cache',
        inputTokens: 20,
        outputTokens: 12,
      );
      final cached = await store.briefs.readMorningBrief(_day);
      expect(cached?.phase, MorningBriefPhase.ready);
      expect(cached?.summary, 'synthetic brief cache');
      expect(cached?.autoAttempts, 2);
      expect(await store.briefs.beginMorningBrief(_day), isNull);
      await store.close();

      store = await _open(file: file, clock: clock);
      expect(
        (await store.briefs.readMorningBrief(_day))?.summary,
        'synthetic brief cache',
      );
      final invalidated = await store.briefs.beginMorningBrief(
        _day,
        manual: true,
      );
      expect(invalidated, isNotNull);
      await store.briefs.clearMorningBriefs();
      await expectLater(
        store.briefs.ensureMorningTicket(invalidated!),
        throwsA(
          isA<ReminderFailure>().having(
            (failure) => failure.code,
            'code',
            ReminderFailureCode.stale,
          ),
        ),
      );
      expect(
        (await store.briefs.readMorningBrief(_day))?.phase,
        MorningBriefPhase.cleared,
      );
      expect(await store.briefs.beginMorningBrief(_day), isNull);

      final rebuilt = await store.briefs.beginMorningBrief(_day, manual: true);
      expect(rebuilt, isNotNull);
      expect(await store.briefs.beginMorningModelAttempt(rebuilt!), isTrue);
      await store.briefs.saveMorningBrief(
        rebuilt,
        phase: MorningBriefPhase.ready,
        summary: 'synthetic manual rebuild',
      );
      expect(
        (await store.briefs.readMorningBrief(_day))?.summary,
        'synthetic manual rebuild',
      );
      expect(
        (await store.features.inspectReminders()).preferences.morningEnabled,
        isTrue,
      );

      final restoredAgenda = await _window(store, _day);
      expect(
        restoredAgenda.items.any(
          (item) =>
              item.reference.identity.localId == event.target!.identity.localId,
        ),
        isTrue,
      );
      expect(
        (await store.localCalendar.queryTasks(
          const TaskQuery(filter: TaskFilter.all),
        )).items.single.draft.title,
        'synthetic persisted task asset',
      );
      expect((await store.agent.inspectAgent()).keySaved, isTrue);
      expect(
        await _scalar(store, 'SELECT COUNT(*) FROM agent_conversations'),
        1,
      );
    },
  );

  test(
    'ready results reject changed facts and tickets expire with Beijing day',
    () async {
      final clock = _MutableClock(_now);
      final store = await _open(clock: clock);
      await _enableMorning(store);
      final context = await _context(store, _day);
      await _write(
        store,
        context,
        CreatePersonalEvent(
          PersonalEventDraft(
            title: 'before morning generation',
            start: DateTime.utc(2026, 10, 15, 2),
            end: DateTime.utc(2026, 10, 15, 3),
          ),
        ),
      );
      final ticket = await store.briefs.beginMorningBrief(_day);
      expect(ticket, isNotNull);
      final current = (await _window(store, _day)).items.single;
      await _write(
        store,
        context,
        UpdatePersonalSeries(
          current.reference,
          PersonalEventDraft(
            title: 'changed during generation',
            start: DateTime.utc(2026, 10, 15, 4),
            end: DateTime.utc(2026, 10, 15, 5),
          ),
        ),
      );
      await expectLater(
        store.briefs.saveMorningBrief(
          ticket!,
          phase: MorningBriefPhase.ready,
          summary: 'must not commit stale summary',
        ),
        throwsA(
          isA<ReminderFailure>().having(
            (failure) => failure.code,
            'code',
            ReminderFailureCode.stale,
          ),
        ),
      );
      final stale = await store.briefs.readMorningBrief(_day);
      expect(stale?.phase, MorningBriefPhase.facts);
      expect(stale?.summary, isEmpty);

      await store.briefs.clearMorningBriefs();
      final clockTicket = await store.briefs.beginMorningBrief(
        _day,
        manual: true,
      );
      expect(clockTicket, isNotNull);
      clock.nowUtc = DateTime.utc(2026, 10, 16);
      await expectLater(
        store.briefs.ensureMorningTicket(clockTicket!),
        throwsA(
          isA<ReminderFailure>().having(
            (failure) => failure.code,
            'code',
            ReminderFailureCode.stale,
          ),
        ),
      );
      await expectLater(
        store.briefs.beginMorningBrief(_day),
        throwsA(
          isA<ReminderFailure>().having(
            (failure) => failure.code,
            'code',
            ReminderFailureCode.stale,
          ),
        ),
      );
      expect(
        await store.briefs.beginMorningBrief(DateTime.utc(2026, 10, 16)),
        isNotNull,
      );
    },
  );
}

Future<JwStore> _open({File? file, _MutableClock? clock}) async {
  final store = JwStore(
    file == null ? NativeDatabase.memory() : NativeDatabase(file),
    ownership: _SyntheticOwnership(),
    clock: clock ?? _MutableClock(_now),
    modelCredentialProtector: _SyntheticProtector(),
  );
  try {
    await store.initialize();
    await store.agent.initializeAgent();
    await store.features.initialize();
  } catch (_) {
    await store.close();
    rethrow;
  }
  addTearDown(store.close);
  return store;
}

Future<void> _enableMorning(JwStore store) async {
  final settings = await store.features.inspectReminders();
  await store.features.saveReminderPreferences(
    settings,
    settings.preferences.copyWith(morningEnabled: true),
  );
}

Future<AgentSettingsSnapshot> _configureSyntheticAgent(JwStore store) async {
  final snapshot = await store.agent.inspectAgent();
  await store.agent.saveModelConfiguration(
    snapshot.authority,
    modelId: 'synthetic-chat-model',
    modelIds: const ['synthetic-chat-model'],
    report: const AgentCapabilityReport(text: true, streaming: true),
    consent: true,
    key: _syntheticKey,
  );
  return store.agent.inspectAgent();
}

Future<CalendarContext> _context(JwStore store, DateTime day) async =>
    (await _window(store, day)).context;

Future<CalendarWindow> _window(JwStore store, DateTime day) =>
    store.localCalendar.query(
      CalendarQuery(
        firstDay: day,
        endDayExclusive: day.add(const Duration(days: 1)),
        includeSkipped: true,
      ),
    );

Future<CalendarWriteReceipt> _write(
  JwStore store,
  CalendarContext context,
  CalendarIntent intent,
) async => store.localCalendar.commit(
  await store.localCalendar.prepare(context, intent),
);

Future<Object?> _scalar(JwStore store, String sql) async =>
    (await store.customSelect(sql).getSingle()).data.values.single;

Future<File> _temporaryDatabase(String prefix) async {
  final directory = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    final root =
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}';
    if (!directory.absolute.path.toLowerCase().startsWith(root.toLowerCase()) ||
        !directory.path.split(Platform.pathSeparator).last.startsWith(prefix)) {
      throw StateError('Unexpected synthetic morning database root');
    }
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File ||
          !const {
            'store.sqlite',
            'store.sqlite-wal',
            'store.sqlite-shm',
            'store.sqlite-journal',
          }.contains(entry.uri.pathSegments.last)) {
        throw StateError('Unexpected synthetic morning database asset');
      }
      await entry.delete();
    }
    await directory.delete();
  });
  return File('${directory.path}${Platform.pathSeparator}store.sqlite');
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

final class _SyntheticProtector implements ModelCredentialProtector {
  @override
  String get mechanism => 'synthetic-morning-protector/v1';
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
