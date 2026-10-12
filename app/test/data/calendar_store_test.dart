import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:ustc_assistant_m0/core/agenda_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/jw_work_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/source/jw_collection_contract.dart';
import 'package:ustc_assistant_m0/source/jw_probe_contract.dart';

import '../support/calendar_legacy_schema.dart';

final _day = DateTime.utc(2026, 10, 12);
final _clock = FixedClock(DateTime.utc(2026, 10, 12, 12));

void main() {
  test(
    'personal plans work before school binding and completion is explicit',
    () async {
      final store = await _open();
      final first = await _window(store);
      expect((await store.readAuthority()).accountBound, isFalse);
      final created = await _write(
        store,
        first.context,
        CreatePersonalEvent(_draft('合成个人安排')),
      );
      expect((await _window(store)).items.single.completed, isFalse);
      final completed = await _write(
        store,
        first.context,
        SetPersonalOccurrenceState(created.target!, completed: true),
      );
      expect((await _window(store)).items.single.completed, isTrue);
      await _importCourse(store);
      final afterBinding = await _window(store);
      expect(afterBinding.context, first.context);
      final personal = afterBinding.items.singleWhere(
        (e) => e.reference.identity.kind == CalendarKind.personal,
      );
      expect(personal.reference, completed.target);
      expect(personal.completed, isTrue);
      expect((await store.readAuthority()).accountBound, isTrue);
    },
  );

  test(
    'committed replay is historical, changed intent and old versions reject',
    () async {
      final store = await _open();
      final context = (await _window(store)).context;
      final command = await store.localCalendar.prepare(
        context,
        CreatePersonalEvent(_draft('合成原安排')),
      );
      final first = await store.localCalendar.commit(command);
      await _write(
        store,
        context,
        UpdatePersonalSeries(first.target!, _draft('合成新安排')),
      );
      final replay = await store.localCalendar.commit(command);
      expect(replay.replayed, isTrue);
      expect(replay.target, first.target);
      expect((await _window(store)).items.single.title, '合成新安排');
      expect(await _count(store, 'agenda_audit'), 2);
      expect(await _count(store, 'agenda_receipts'), 2);
      await _failure(
        store.localCalendar.commit(
          CalendarCommand(
            command.operationId,
            command.context,
            CreatePersonalEvent(_draft('合成变更意图')),
          ),
        ),
        CalendarFailureCode.idempotencyConflict,
      );
      await _failure(
        _write(
          store,
          context,
          UpdatePersonalSeries(first.target!, _draft('合成旧表单')),
        ),
        CalendarFailureCode.staleReference,
      );
      expect(await _count(store, 'agenda_audit'), 2);
    },
  );

  test(
    'series edits preserve far moved occurrence and independent user state',
    () async {
      final store = await _open();
      final context = (await _window(store)).context;
      final original = PersonalEventDraft(
        title: '合成重复',
        start: DateTime.utc(2026, 1, 5, 1),
        end: DateTime.utc(2026, 1, 5, 2),
        weekly: true,
      );
      var receipt = await _write(store, context, CreatePersonalEvent(original));
      final ordinal = CalendarIdentity(
        CalendarKind.personal,
        receipt.target!.identity.localId,
        ordinal: 2,
      );
      var ref = CalendarReference(context, ordinal, receipt.target!.version);
      receipt = await _write(
        store,
        context,
        UpdatePersonalOccurrence(ref, _draft('合成远移例外')),
      );
      receipt = await _write(
        store,
        context,
        SetPersonalOccurrenceState(receipt.target!, completed: true),
      );
      final moved = (await _window(
        store,
      )).items.singleWhere((e) => e.reference.identity == ordinal);
      expect(moved.completed, isTrue);
      expect(moved.startsAtUtc, _draft('x').start);
      ref = moved.reference;
      final shortened = PersonalEventDraft(
        title: '合成改首日',
        start: DateTime.utc(2026, 1, 6, 3),
        end: DateTime.utc(2026, 1, 6, 4),
        weekly: true,
        untilDay: DateTime.utc(2026, 1, 6),
      );
      receipt = await _write(
        store,
        context,
        UpdatePersonalSeries(ref, shortened),
      );
      expect((await _window(store)).items, isEmpty);
      final anchor = CalendarReference(
        context,
        CalendarIdentity(CalendarKind.personal, ordinal.localId),
        receipt.target!.version,
      );
      final extended = PersonalEventDraft(
        title: shortened.title,
        start: shortened.start,
        end: shortened.end,
        weekly: true,
      );
      receipt = await _write(
        store,
        context,
        UpdatePersonalSeries(anchor, extended),
      );
      final restored = (await _window(
        store,
      )).items.singleWhere((e) => e.reference.identity == ordinal);
      expect(restored.title, '合成远移例外');
      expect(restored.completed, isTrue);
      await _write(
        store,
        context,
        SetPersonalOccurrenceState(restored.reference, skipped: true),
      );
      expect(
        (await _window(
          store,
        )).items.any((e) => e.reference.identity == ordinal),
        isFalse,
      );
      final skipped = (await _window(
        store,
        inactive: true,
      )).items.singleWhere((e) => e.reference.identity == ordinal);
      expect(skipped.completed, isTrue);
      await _write(
        store,
        context,
        SetPersonalOccurrenceState(skipped.reference, skipped: false),
      );
      expect(
        (await _window(
          store,
        )).items.any((e) => e.reference.identity == ordinal),
        isTrue,
      );
      expect(await _count(store, 'personal_occurrence_overrides'), 1);
    },
  );

  test(
    'school refresh and missing/reappearance preserve notes decisions and relation',
    () async {
      final store = await _open();
      await _importCourse(store);
      var window = await _window(store);
      final source = window.items.single;
      final firstId = source.reference.identity;
      final person = await _write(
        store,
        window.context,
        CreatePersonalEvent(_draft('合成重叠')),
      );
      final updated = await _write(
        store,
        window.context,
        UpdateSchoolAnnotation(
          source.reference,
          note: '合成个人备注',
          attendance: AttendanceDecision.skip,
          listening: ListeningMode.selfStudy,
        ),
      );
      await _write(
        store,
        window.context,
        SaveCalendarRelation(
          left: updated.target!,
          right: person.target!,
          kind: CalendarRelationKind.coexist,
          note: '合成解释',
        ),
      );
      await _importCourse(store, title: '合成更新课程', endMinute: 630);
      window = await _window(store);
      var current = window.items.singleWhere(
        (e) => e.reference.identity == firstId,
      );
      expect(current.note, '合成个人备注');
      expect(current.attendance, AttendanceDecision.skip);
      expect(current.listening, ListeningMode.selfStudy);
      expect(window.conflicts.single.relation?.note, '合成解释');
      await _importCourse(store, empty: true);
      current = (await _window(
        store,
      )).items.singleWhere((e) => e.reference.identity == firstId);
      expect(current.presence, AgendaPresence.missingWithinScope);
      expect((await _window(store)).conflicts, hasLength(1));
      await _importCourse(store, title: '合成再出现', endMinute: 630);
      current = (await _window(
        store,
      )).items.singleWhere((e) => e.reference.identity == firstId);
      expect(current.presence, AgendaPresence.observed);
      expect(current.note, '合成个人备注');
      await _failure(
        _write(
          store,
          window.context,
          UpdateSchoolAnnotation(updated.target!, hidden: true),
        ),
        CalendarFailureCode.staleReference,
      );
      final hidden = await _write(
        store,
        window.context,
        UpdateSchoolAnnotation(current.reference, hidden: true),
      );
      expect((await _window(store)).conflicts, isEmpty);
      expect(
        (await _window(
          store,
          inactive: true,
        )).items.singleWhere((e) => e.reference.identity == firstId).hidden,
        isTrue,
      );
      await _write(
        store,
        window.context,
        UpdateSchoolAnnotation(hidden.target!, hidden: false),
      );
      expect(
        (await _window(store)).conflicts.single.relation?.kind,
        CalendarRelationKind.coexist,
      );
    },
  );

  test(
    'relation checks both versions and never partly writes a stale pair',
    () async {
      final store = await _open();
      final context = (await _window(store)).context;
      final left = await _write(
        store,
        context,
        CreatePersonalEvent(_draft('合成甲')),
      );
      final right = await _write(
        store,
        context,
        CreatePersonalEvent(_draft('合成乙')),
      );
      final pending = await store.localCalendar.prepare(
        context,
        SaveCalendarRelation(
          left: left.target!,
          right: right.target!,
          kind: CalendarRelationKind.related,
          note: '合成关联',
        ),
      );
      await _write(
        store,
        context,
        SetPersonalOccurrenceState(right.target!, completed: true),
      );
      await _failure(
        store.localCalendar.commit(pending),
        CalendarFailureCode.staleReference,
      );
      expect(await _count(store, 'agenda_relations'), 0);
      expect(await _count(store, 'agenda_audit'), 3);
    },
  );

  test(
    'all-day exclusive end, inactive state, delete confirmation and type applicability',
    () async {
      final store = await _open();
      var window = await _window(store);
      final fullDay = await _write(
        store,
        window.context,
        CreatePersonalEvent(
          PersonalEventDraft(
            title: '合成全天',
            start: _day,
            end: _day.add(const Duration(days: 2)),
            allDay: true,
          ),
        ),
      );
      expect((await _window(store)).segments.single.endMinute, 1440);
      expect(
        (await _window(store, day: _day.add(const Duration(days: 2)))).items,
        isEmpty,
      );
      await _failure(
        _write(
          store,
          window.context,
          DeletePersonalSeries(fullDay.target!, confirmed: false),
        ),
        CalendarFailureCode.invalidInput,
      );
      await _write(
        store,
        window.context,
        DeletePersonalSeries(fullDay.target!, confirmed: true),
      );
      await _failure(
        store.localCalendar.detail(fullDay.target!),
        CalendarFailureCode.staleReference,
      );
      expect((await _window(store)).items, isEmpty);
      await _importCourse(store);
      window = await _window(store);
      final fakeExam = CalendarReference(
        window.context,
        CalendarIdentity(
          CalendarKind.exam,
          window.items.single.reference.identity.localId,
        ),
        window.items.single.reference.version,
      );
      await _failure(
        _write(
          store,
          window.context,
          UpdateSchoolAnnotation(fakeExam, note: 'x'),
        ),
        CalendarFailureCode.staleReference,
      );
      await _failure(
        _write(
          store,
          window.context,
          UpdateSchoolAnnotation(
            fakeExam,
            attendance: AttendanceDecision.attend,
          ),
        ),
        CalendarFailureCode.invalidInput,
      );
    },
  );

  test(
    'ownership or SQL fault rolls business receipt and audit back together',
    () async {
      var reject = true;
      final owner = _Owner();
      final store = await _open(
        owner: owner,
        checkpoint: () async {
          if (reject) throw const AppFailure(FailureCode.storageFailed);
        },
      );
      final context = (await _window(store)).context;
      final command = await store.localCalendar.prepare(
        context,
        CreatePersonalEvent(_draft('合成回滚')),
      );
      await _failure(
        store.localCalendar.commit(command),
        CalendarFailureCode.storageFailed,
      );
      for (final table in [
        'personal_events',
        'agenda_receipts',
        'agenda_audit',
      ]) {
        expect(await _count(store, table), 0);
      }
      reject = false;
      final good = await store.localCalendar.commit(command);
      final staleContext = CalendarContext(
        owner: '${context.owner}x',
        resetEpoch: context.resetEpoch,
        agendaEpoch: context.agendaEpoch,
      );
      await _failure(
        store.localCalendar.prepare(
          staleContext,
          CreatePersonalEvent(_draft('合成外来上下文')),
        ),
        CalendarFailureCode.staleReference,
      );
      owner.held = false;
      await _failure(
        store.localCalendar.detail(good.target!),
        CalendarFailureCode.ownershipLost,
      );
      owner.held = true;
      expect((await _window(store)).items.single.title, '合成回滚');
    },
  );

  test(
    'maintenance accepted during a write rejects the late commit and old context',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final store = await _open(
        checkpoint: () async {
          if (!entered.isCompleted) {
            entered.complete();
            await release.future;
          }
        },
      );
      final context = (await _window(store)).context;
      final command = await store.localCalendar.prepare(
        context,
        CreatePersonalEvent(_draft('合成迟到')),
      );
      final writing = store.localCalendar.commit(command);
      final rejected = _failure(writing, CalendarFailureCode.maintenance);
      await entered.future;
      final maintenance = store.localCalendar.beginMaintenance();
      release.complete();
      await rejected;
      final nextContext = await maintenance;
      await _failure(_window(store), CalendarFailureCode.maintenance);
      expect(await _count(store, 'personal_events'), 0);
      expect(await _count(store, 'agenda_receipts'), 0);
      await store.localCalendar.finishMaintenance(nextContext);
      await _failure(
        store.localCalendar.commit(command),
        CalendarFailureCode.staleReference,
      );
      final next = await _window(store);
      expect(next.context.agendaEpoch, greaterThan(context.agendaEpoch));
      expect(next.items, isEmpty);
    },
  );

  test(
    'native reopen keeps personal and school facts, overlay decisions and epochs',
    () async {
      final file = await _tempFile();
      var store = await _open(file: file);
      final context = (await _window(store)).context;
      final personal = await _write(
        store,
        context,
        CreatePersonalEvent(_draft('合成持久')),
      );
      await _write(
        store,
        context,
        SetPersonalOccurrenceState(personal.target!, completed: true),
      );
      await _importCourse(store);
      final source = (await _window(store)).items.singleWhere(
        (e) => e.reference.identity.kind == CalendarKind.course,
      );
      await _write(
        store,
        context,
        UpdateSchoolAnnotation(source.reference, note: '合成持久备注'),
      );
      final before = await _window(store);
      await store.close();
      store = await _open(file: file);
      final after = await _window(store);
      expect(after.context, context);
      expect(
        after.items
            .map(
              (e) => [
                e.reference.identity.canonical,
                e.reference.version,
                e.title,
                e.note,
                e.completed,
              ],
            )
            .toList(),
        before.items
            .map(
              (e) => [
                e.reference.identity.canonical,
                e.reference.version,
                e.title,
                e.note,
                e.completed,
              ],
            )
            .toList(),
      );
      expect(await _count(store, 'agenda_receipts'), 3);
      final maintenance = await store.localCalendar.beginMaintenance();
      await store.close();
      final reopening = JwStore(
        NativeDatabase(file),
        ownership: _Owner(),
        clock: _clock,
      );
      addTearDown(reopening.close);
      await expectLater(
        reopening.initialize(),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.code,
            'maintenance',
            FailureCode.cleanupPending,
          ),
        ),
      );
      await reopening.localCalendar.finishMaintenance(maintenance);
      await reopening.initialize();
      expect((await _window(reopening)).items, hasLength(2));
    },
  );

  test('old reset context cannot address reused IDs and versions', () async {
    final store = await _open();
    final context = (await _window(store)).context;
    final original = await _write(
      store,
      context,
      CreatePersonalEvent(_draft('合成旧对象')),
    );
    await store.customStatement(
      'UPDATE jw_state SET reset_epoch=reset_epoch+1 WHERE singleton=1',
    );
    await store.customStatement('DELETE FROM personal_events');
    await store.customStatement(
      "DELETE FROM sqlite_sequence WHERE name='personal_events'",
    );
    final nextContext = (await _window(store)).context;
    final newObject = await _write(
      store,
      nextContext,
      CreatePersonalEvent(_draft('合成新对象')),
    );
    expect(newObject.target!.identity, original.target!.identity);
    expect(newObject.target!.version, original.target!.version);
    await _failure(
      store.localCalendar.detail(original.target!),
      CalendarFailureCode.staleReference,
    );
    await _failure(
      _write(
        store,
        context,
        DeletePersonalSeries(original.target!, confirmed: true),
      ),
      CalendarFailureCode.staleReference,
    );
    expect((await _window(store)).items.single.title, '合成新对象');
  });

  test(
    'window reads do not fail on many retained facts outside the requested date',
    () async {
      final store = await _open();
      await store.customStatement(
        "INSERT INTO jw_account VALUES (1,'AB12345')",
      );
      final start = DateTime.utc(2026, 1, 1, 1).microsecondsSinceEpoch;
      final end = DateTime.utc(2026, 1, 1, 2).microsecondsSinceEpoch;
      await store.customStatement(
        "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<5001) "
        "INSERT INTO jw_events(local_id,external_id,kind,semester_id,title,starts_at,ends_at,presence,version) "
        "SELECT x,'synthetic-retained-'||x,'course',202610,'合成窗口外',?,?,'outsideScope',1 FROM n",
        [start, end],
      );
      await store.customStatement(
        'INSERT INTO jw_overlays(local_id,hidden) SELECT local_id,0 FROM jw_events',
      );
      final current = await _window(store);
      expect(current.items, isEmpty);
      await _write(
        store,
        current.context,
        CreatePersonalEvent(_draft('合成仍可创建')),
      );
      expect((await _window(store)).items.single.title, '合成仍可创建');
      await _failure(
        _window(store, day: DateTime.utc(2026, 1, 1)),
        CalendarFailureCode.limitExceeded,
      );
      expect(await _count(store, 'jw_events'), 5001);
    },
  );

  test(
    'failed mid-upgrade leaves schema five and accepted facts intact',
    () async {
      final file = await _tempFile();
      final store = await _open(file: file);
      await _importCourse(store);
      final before = await store.readView();
      await store.close();
      var raw = sqlite3.sqlite3.open(file.path);
      try {
        removeCalendarTablesForLegacyFixture(raw);
        raw.execute('CREATE TABLE agenda_relations(synthetic_marker INTEGER)');
        raw.execute('PRAGMA user_version=5');
      } finally {
        raw.close();
      }
      final failing = JwStore(
        NativeDatabase(file),
        ownership: _Owner(),
        clock: _clock,
      );
      addTearDown(failing.close);
      await expectLater(
        failing.initialize(),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.code,
            'failure',
            FailureCode.storageFailed,
          ),
        ),
      );
      await failing.close();
      raw = sqlite3.sqlite3.open(file.path);
      try {
        expect(raw.select('PRAGMA user_version').single['user_version'], 5);
        expect(
          raw
              .select(
                "SELECT count(*) AS n FROM sqlite_master WHERE name='personal_events'",
              )
              .single['n'],
          0,
        );
        expect(
          raw
              .select('SELECT local_id,version FROM jw_events')
              .single['local_id'],
          before.events.single.localId,
        );
        expect(
          raw.select('SELECT version FROM jw_events').single['version'],
          before.events.single.version,
        );
        expect(
          raw
              .select('PRAGMA table_info(jw_overlays)')
              .any((row) => row['name'] == 'note'),
          isFalse,
        );
        raw.execute('DROP TABLE agenda_relations');
      } finally {
        raw.close();
      }
      final recovered = await _open(file: file);
      expect(
        (await recovered.readView()).events.single.localId,
        before.events.single.localId,
      );
      expect((await _window(recovered)).items, hasLength(1));
    },
  );

  test(
    'schema 5 to 6 preserves original source identity credentials and knowledge',
    () async {
      final file = await _tempFile();
      var store = await _open(file: file);
      await _importCourse(store);
      final source = (await _window(store)).items.single;
      await _write(
        store,
        source.reference.context,
        UpdateSchoolAnnotation(source.reference, hidden: true),
      );
      await store.customStatement(
        'INSERT INTO jw_credentials(account_id,mechanism,ciphertext) VALUES (1,?,?)',
        [
          'synthetic-only',
          Uint8List.fromList([11, 23, 41]),
        ],
      );
      await store.customStatement(
        "INSERT INTO knowledge_materials(material_key,revision,metadata_json,markdown,title_search,provider,topic,audience,source_version,accepted_at,byte_count) VALUES ('synthetic-knowledge','v1','{}','# 合成资料','合成','teach','guide','student','synthetic',0,20)",
      );
      final before = await store.readView();
      final beforePermits = await store.readCommittedPermits();
      final context = (await _window(store, inactive: true)).context;
      await store.close();
      final raw = sqlite3.sqlite3.open(file.path);
      try {
        removeCalendarTablesForLegacyFixture(raw);
        raw.execute('PRAGMA user_version=5');
      } finally {
        raw.close();
      }
      store = await _open(file: file);
      final after = await store.readView();
      expect(after.events.single.localId, before.events.single.localId);
      expect(after.events.single.version, before.events.single.version);
      expect(after.events.single.hidden, isTrue);
      expect(after.credentialSaved, isTrue);
      expect(
        after.cachedSemesters.map((s) => s.id),
        before.cachedSemesters.map((s) => s.id),
      );
      expect(
        (await store.readCommittedPermits()).single.partition.sameAs(
          beforePermits.single.partition,
        ),
        isTrue,
      );
      expect(await _count(store, 'knowledge_materials'), 1);
      expect(
        (await store
                .customSelect('SELECT markdown FROM knowledge_materials')
                .getSingle())
            .read<String>('markdown'),
        '# 合成资料',
      );
      final current = await _window(store, inactive: true);
      expect(current.context.owner, context.owner);
      expect(current.items.single.note, '');
      expect(
        (await store.customSelect('PRAGMA user_version').getSingle()).read<int>(
          'user_version',
        ),
        6,
      );
    },
  );
}

Future<JwStore> _open({
  File? file,
  _Owner? owner,
  Future<void> Function()? checkpoint,
}) async {
  final store = JwStore(
    file == null ? NativeDatabase.memory() : NativeDatabase(file),
    ownership: owner ?? _Owner(),
    clock: _clock,
    onCalendarCheckpoint: checkpoint,
  );
  addTearDown(store.close);
  await store.initialize();
  return store;
}

Future<File> _tempFile() async {
  final dir = await Directory.systemTemp.createTemp('m42-calendar-store-');
  addTearDown(() async {
    final prefix =
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}';
    if (!dir.absolute.path.toLowerCase().startsWith(prefix.toLowerCase()) ||
        !dir.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('m42-calendar-store-')) {
      throw StateError('Unexpected synthetic temp root');
    }
    await for (final item in dir.list(followLinks: false)) {
      if (item is! File ||
          ![
            'store.sqlite',
            'store.sqlite-wal',
            'store.sqlite-shm',
          ].contains(item.path.split(Platform.pathSeparator).last)) {
        throw StateError('Unexpected synthetic temp entry');
      }
      await item.delete();
    }
    await dir.delete();
  });
  return File('${dir.path}${Platform.pathSeparator}store.sqlite');
}

PersonalEventDraft _draft(String title) => PersonalEventDraft(
  title: title,
  start: DateTime.utc(2026, 10, 12, 1),
  end: DateTime.utc(2026, 10, 12, 2),
);

Future<CalendarWindow> _window(
  JwStore store, {
  DateTime? day,
  bool inactive = false,
}) => store.localCalendar.query(
  CalendarQuery(
    firstDay: day ?? _day,
    endDayExclusive: (day ?? _day).add(const Duration(days: 1)),
    includeHidden: inactive,
    includeSkipped: inactive,
  ),
);

Future<CalendarWriteReceipt> _write(
  JwStore store,
  CalendarContext context,
  CalendarIntent intent,
) async => store.localCalendar.commit(
  await store.localCalendar.prepare(context, intent),
);

Future<void> _failure(Future<Object?> future, CalendarFailureCode code) =>
    expectLater(
      future,
      throwsA(isA<CalendarFailure>().having((e) => e.code, 'code', code)),
    );

Future<int> _count(JwStore store, String table) async =>
    (await store
            .customSelect('SELECT COUNT(*) AS count FROM $table')
            .getSingle())
        .read<int>('count');

Future<void> _importCourse(
  JwStore store, {
  String title = '合成课程',
  int endMinute = 600,
  bool empty = false,
}) async {
  final ticket = await store.beginJob(expectedAccountCode: 'AB12345');
  final part = JwPartitionRef(
    id: 'jwp-${ticket.stamp.generation.toRadixString(16).padLeft(32, '0')}',
    ownerId: ticket.stamp.ownerId,
    purpose: ticket.stamp.accountId == null
        ? JwPartitionPurpose.initial
        : JwPartitionPurpose.recovery,
    attempt: ticket.stamp.jobId,
    resetEpoch: ticket.stamp.resetEpoch,
  );
  await store.stagePartition(ticket, part);
  await store.stageSemesterCatalog(ticket, const [
    JwSemesterOption(id: 202610, name: '合成学期', selected: true),
  ]);
  final n = empty ? 0 : 1;
  final reply = JwCollectionReply.decode(
    jsonEncode({
      'operation': 41,
      'phase': 'done',
      'code': 'ok',
      'identity': {
        'candidateCount': 1,
        'method': 'table',
        'accountCode': 'AB12345',
      },
      'diagnostics': {
        'checks': {
          'identityBefore': 'ok',
          'course': 'ok',
          'index': 'ok',
          'datum': empty ? 'skipped' : 'ok',
          'exams': 'ok',
          'identityAfter': 'ok',
        },
        'reason': 'none',
        'identityReads': 2,
        'lessonIds': n,
        'lessons': n,
        'groups': n,
        'schedules': n,
        'datedSchedules': n,
        'timedSchedules': n,
        'linkedSchedules': n,
        'examRows': 0,
        'datedExams': 0,
        'semesterAccepted': true,
        'selfRouteBound': true,
        'identityStable': true,
        'emptyCourse': empty,
        'emptyExams': true,
        'pagination': false,
        'types': {
          'lessonIds': 'array',
          'lessonList': 'array',
          'scheduleGroupList': 'array',
          'scheduleList': 'array',
          'date': 'string',
          'startTime': 'number',
          'endTime': 'number',
        },
      },
      'snapshot': {
        'semesterId': 202610,
        'courses': empty
            ? []
            : [
                {
                  'lessonId': 81,
                  'groupId': 91,
                  'date': '2026-10-12',
                  'startMinute': 540,
                  'endMinute': endMinute,
                  'title': title,
                },
              ],
        'exams': [],
      },
    }),
    operation: 41,
  );
  await store.importSnapshot(
    ticket,
    JwCollectedArtifact.seal(
      reply: reply,
      stamp: ticket.stamp,
      partition: part,
      session: 1,
      document: 1,
      semesterId: 202610,
      collectedAtUtc: _clock.nowUtc,
    ),
  );
}

final class _Owner implements AssetOwnership {
  bool held = true;
  @override
  bool get isHeld => held;
  @override
  void ensureHeld() {
    if (!held) throw const AppFailure(FailureCode.ownershipLost);
  }
}
