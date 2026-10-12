import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/jw_academic_details.dart';
import 'package:ustc_assistant_m0/core/jw_work_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/source/jw_collection_contract.dart';
import 'package:ustc_assistant_m0/source/jw_probe_contract.dart';

final _day = DateTime.utc(2026, 10, 12);
final _clock = FixedClock(DateTime.utc(2026, 10, 12, 12));

void main() {
  test(
    'personal create, series, occurrence, state and delete writes undo their business fields',
    () async {
      final store = await _open();
      final context = await _context(store);
      final standalone = await _write(
        store,
        context,
        CreatePersonalEvent(_personalDraft('合成单次安排')),
      );
      final standaloneId = standalone.target!.identity.localId;
      expect(
        _personalItems(
          await _window(store: store, includeHidden: true),
        ).map((item) => item.reference.identity.localId),
        contains(standaloneId),
      );
      await _undoLatest(store, context);
      expect(
        _personalItems(
          await _window(store: store, includeHidden: true),
        ).map((item) => item.reference.identity.localId),
        isNot(contains(standaloneId)),
      );

      final weeklyDraft = PersonalEventDraft(
        title: '合成每周安排',
        start: DateTime.utc(2026, 10, 12, 1),
        end: DateTime.utc(2026, 10, 12, 2),
        weekly: true,
        location: '合成地点',
        note: '合成系列备注',
      );
      final weekly = await _write(
        store,
        context,
        CreatePersonalEvent(weeklyDraft),
      );
      final weeklyId = weekly.target!.identity.localId;

      var occurrence = _occurrence(
        await _window(includeSkipped: true, store: store),
        weeklyId,
        1,
      );
      final replacementOne = PersonalEventDraft(
        title: '合成单次替代一',
        start: DateTime.utc(2026, 10, 19, 4),
        end: DateTime.utc(2026, 10, 19, 5),
        location: '替代地点一',
        note: '替代备注一',
      );
      await _write(
        store,
        context,
        UpdatePersonalOccurrence(occurrence.reference, replacementOne),
      );
      occurrence = _occurrence(
        await _window(includeSkipped: true, store: store),
        weeklyId,
        1,
      );
      await _write(
        store,
        context,
        SetPersonalOccurrenceState(occurrence.reference, completed: true),
      );
      occurrence = _occurrence(
        await _window(includeSkipped: true, store: store),
        weeklyId,
        1,
      );
      await _write(
        store,
        context,
        SetPersonalOccurrenceState(occurrence.reference, skipped: true),
      );
      await _undoLatest(store, context);
      occurrence = _occurrence(
        await _window(includeSkipped: true, store: store),
        weeklyId,
        1,
      );
      var occurrenceDetail = await store.localCalendar.detail(
        occurrence.reference,
      );
      expect(occurrence.title, '合成单次替代一');
      expect(occurrence.completed, isTrue);
      expect(occurrence.skipped, isFalse);
      expect(occurrenceDetail.hasOccurrenceReplacement, isTrue);
      expect(occurrence.note, '替代备注一');

      await _write(
        store,
        context,
        SetPersonalOccurrenceState(occurrence.reference, completed: false),
      );
      await _undoLatest(store, context);
      occurrence = _occurrence(
        await _window(includeSkipped: true, store: store),
        weeklyId,
        1,
      );
      expect(occurrence.completed, isTrue);
      expect(occurrence.skipped, isFalse);
      expect(occurrence.title, '合成单次替代一');

      var sibling = _occurrence(
        await _window(includeSkipped: true, store: store),
        weeklyId,
        2,
      );
      await _write(
        store,
        context,
        SetPersonalOccurrenceState(sibling.reference, skipped: true),
      );
      final editedSeries = PersonalEventDraft(
        title: '合成系列编辑后',
        start: DateTime.utc(2026, 10, 12, 2),
        end: DateTime.utc(2026, 10, 12, 3),
        weekly: true,
        location: '编辑后的地点',
        note: '编辑后的备注',
      );
      final anchor = _occurrence(
        await _window(store: store, includeSkipped: true),
        weeklyId,
        0,
      );
      await _write(
        store,
        context,
        UpdatePersonalSeries(anchor.reference, editedSeries),
      );
      await _undoLatest(store, context);

      var window = await _window(store: store, includeSkipped: true);
      var restoredAnchor = _occurrence(window, weeklyId, 0);
      var seriesDetail = await store.localCalendar.detail(
        restoredAnchor.reference,
      );
      expect(seriesDetail.personalDraft!.title, '合成每周安排');
      expect(seriesDetail.personalDraft!.location, '合成地点');
      occurrence = _occurrence(window, weeklyId, 1);
      occurrenceDetail = await store.localCalendar.detail(occurrence.reference);
      expect(occurrence.title, '合成单次替代一');
      expect(occurrence.completed, isTrue);
      expect(occurrence.skipped, isFalse);
      expect(occurrenceDetail.hasOccurrenceReplacement, isTrue);
      expect(occurrence.note, '替代备注一');
      sibling = _occurrence(window, weeklyId, 2);
      expect(sibling.skipped, isTrue);

      final replacementTwo = PersonalEventDraft(
        title: '合成单次替代二',
        start: DateTime.utc(2026, 10, 19, 6),
        end: DateTime.utc(2026, 10, 19, 7),
        location: '替代地点二',
        note: '替代备注二',
      );
      await _write(
        store,
        context,
        UpdatePersonalOccurrence(occurrence.reference, replacementTwo),
      );
      await _undoLatest(store, context);
      window = await _window(store: store, includeSkipped: true);
      occurrence = _occurrence(window, weeklyId, 1);
      occurrenceDetail = await store.localCalendar.detail(occurrence.reference);
      expect(occurrence.title, '合成单次替代一');
      expect(occurrenceDetail.hasOccurrenceReplacement, isTrue);
      expect(occurrence.note, '替代备注一');
      expect(occurrence.completed, isTrue);
      expect(_occurrence(window, weeklyId, 2).skipped, isTrue);

      restoredAnchor = _occurrence(window, weeklyId, 0);
      await _write(
        store,
        context,
        DeletePersonalSeries(restoredAnchor.reference, confirmed: true),
      );
      expect(
        _personalItems(
          await _window(store: store, includeHidden: true),
        ).where((item) => item.reference.identity.localId == weeklyId),
        isEmpty,
      );
      await _undoLatest(store, context);
      window = await _window(store: store, includeSkipped: true);
      restoredAnchor = _occurrence(window, weeklyId, 0);
      seriesDetail = await store.localCalendar.detail(restoredAnchor.reference);
      expect(seriesDetail.personalDraft!.title, '合成每周安排');
      occurrence = _occurrence(window, weeklyId, 1);
      occurrenceDetail = await store.localCalendar.detail(occurrence.reference);
      expect(occurrence.title, '合成单次替代一');
      expect(occurrence.completed, isTrue);
      expect(occurrenceDetail.hasOccurrenceReplacement, isTrue);
      expect(occurrence.note, '替代备注一');
      expect(_occurrence(window, weeklyId, 2).skipped, isTrue);
    },
  );

  test(
    'school annotation undo restores only touched fields and source changes conflict',
    () async {
      final store = await _open();
      await _importCourse(store);
      var course = _schoolCourse(await _window(store: store));
      await _write(
        store,
        course.reference.context,
        UpdateSchoolAnnotation(
          course.reference,
          note: '保留的合成备注',
          attendance: AttendanceDecision.attend,
          listening: ListeningMode.listening,
        ),
      );
      course = _schoolCourse(await _window(store: store, includeHidden: true));
      await _write(
        store,
        course.reference.context,
        UpdateSchoolAnnotation(
          course.reference,
          hidden: true,
          note: '应撤销的合成备注',
        ),
      );
      final targetVersion = _schoolCourse(
        await _window(store: store, includeHidden: true),
      ).reference.version;

      await _importCourse(store);
      course = _schoolCourse(await _window(store: store, includeHidden: true));
      expect(course.reference.version, targetVersion);
      final stillAvailable = await store.localCalendar.queryUndo(
        course.reference.context,
      );
      expect(stillAvailable.canUndo, isTrue);
      await _undoLatest(store, course.reference.context);

      course = _schoolCourse(await _window(store: store, includeHidden: true));
      expect(course.title, '合成课程');
      expect(course.hidden, isFalse);
      expect(course.note, '保留的合成备注');
      expect(course.attendance, AttendanceDecision.attend);
      expect(course.listening, ListeningMode.listening);

      await _write(
        store,
        course.reference.context,
        UpdateSchoolAnnotation(course.reference, hidden: true, note: '来源变化时保留'),
      );
      await _importCourse(store, title: '合成课程来源更新');
      course = _schoolCourse(await _window(store: store, includeHidden: true));
      final conflictedUndo = await store.localCalendar.queryUndo(
        course.reference.context,
      );
      expect(conflictedUndo.canUndo, isFalse);
      expect(conflictedUndo.failure, CalendarFailureCode.undoConflict);
      await _failure(
        _write(
          store,
          course.reference.context,
          UndoCalendarWrite(conflictedUndo.reference!),
        ),
        CalendarFailureCode.undoConflict,
      );
      course = _schoolCourse(await _window(store: store, includeHidden: true));
      expect(course.title, '合成课程来源更新');
      expect(course.hidden, isTrue);
      expect(course.note, '来源变化时保留');
      expect(course.attendance, AttendanceDecision.attend);
      expect(course.listening, ListeningMode.listening);
    },
  );

  test(
    'relation update and delete undo preserve identity and guard both endpoints',
    () async {
      final store = await _open();
      final context = await _context(store);
      final leftCreated = await _write(
        store,
        context,
        CreatePersonalEvent(
          _personalDraft(
            '合成关系左',
            start: DateTime.utc(2026, 10, 12, 1),
            end: DateTime.utc(2026, 10, 12, 3),
          ),
        ),
      );
      final rightCreated = await _write(
        store,
        context,
        CreatePersonalEvent(
          _personalDraft(
            '合成关系右',
            start: DateTime.utc(2026, 10, 12, 2),
            end: DateTime.utc(2026, 10, 12, 4),
          ),
        ),
      );
      final leftId = leftCreated.target!.identity;
      final rightId = rightCreated.target!.identity;
      await _write(
        store,
        context,
        SaveCalendarRelation(
          left: leftCreated.target!,
          right: rightCreated.target!,
          kind: CalendarRelationKind.conflict,
          note: '原始关系说明',
        ),
      );

      var window = await _window(store: store);
      var left = _item(window, leftId);
      var right = _item(window, rightId);
      var relation = (await store.localCalendar.detail(
        left.reference,
      )).relations.single;
      final firstRelationId = relation.reference.localId;
      await _undoLatest(store, context);
      window = await _window(store: store);
      left = _item(window, leftId);
      right = _item(window, rightId);
      expect(
        (await store.localCalendar.detail(left.reference)).relations,
        isEmpty,
      );
      expect(
        (await store.localCalendar.detail(right.reference)).relations,
        isEmpty,
      );
      await _write(
        store,
        context,
        SaveCalendarRelation(
          left: left.reference,
          right: right.reference,
          kind: CalendarRelationKind.conflict,
          note: '原始关系说明',
        ),
      );

      window = await _window(store: store);
      left = _item(window, leftId);
      right = _item(window, rightId);
      relation = (await store.localCalendar.detail(
        left.reference,
      )).relations.single;
      final relationId = relation.reference.localId;
      expect(relationId, greaterThan(firstRelationId));
      expect(relation.kind, CalendarRelationKind.conflict);
      expect(relation.note, '原始关系说明');

      final staleLeftEdit = await store.localCalendar.prepare(
        context,
        SaveCalendarRelation(
          left: left.reference,
          right: right.reference,
          kind: CalendarRelationKind.notConflict,
          note: '左端过期编辑',
          existing: relation.reference,
        ),
      );
      await _write(
        store,
        context,
        SetPersonalOccurrenceState(left.reference, completed: true),
      );
      await _failure(
        store.localCalendar.commit(staleLeftEdit),
        CalendarFailureCode.staleReference,
      );

      window = await _window(store: store);
      left = _item(window, leftId);
      right = _item(window, rightId);
      relation = (await store.localCalendar.detail(
        left.reference,
      )).relations.single;
      final staleRightEdit = await store.localCalendar.prepare(
        context,
        SaveCalendarRelation(
          left: left.reference,
          right: right.reference,
          kind: CalendarRelationKind.notConflict,
          note: '右端过期编辑',
          existing: relation.reference,
        ),
      );
      await _write(
        store,
        context,
        SetPersonalOccurrenceState(right.reference, completed: true),
      );
      await _failure(
        store.localCalendar.commit(staleRightEdit),
        CalendarFailureCode.staleReference,
      );

      window = await _window(store: store);
      left = _item(window, leftId);
      right = _item(window, rightId);
      relation = (await store.localCalendar.detail(
        left.reference,
      )).relations.single;
      expect(relation.kind, CalendarRelationKind.conflict);
      expect(relation.note, '原始关系说明');
      expect(
        (await store.localCalendar.detail(
          right.reference,
        )).relations.single.reference.localId,
        relation.reference.localId,
      );

      final leftVersionBeforeUpdate = left.reference.version;
      final rightVersionBeforeUpdate = right.reference.version;
      await _write(
        store,
        context,
        SaveCalendarRelation(
          left: left.reference,
          right: right.reference,
          kind: CalendarRelationKind.notConflict,
          note: '更新后的说明',
          existing: relation.reference,
        ),
      );
      window = await _window(store: store);
      left = _item(window, leftId);
      right = _item(window, rightId);
      relation = (await store.localCalendar.detail(
        left.reference,
      )).relations.single;
      expect(relation.reference.localId, relationId);
      expect(relation.reference.version, greaterThan(1));
      expect(relation.kind, CalendarRelationKind.notConflict);
      expect(relation.note, '更新后的说明');
      expect(left.reference.version, leftVersionBeforeUpdate + 1);
      expect(right.reference.version, rightVersionBeforeUpdate + 1);
      final updatedRelationVersion = relation.reference.version;

      await _undoLatest(store, context);
      window = await _window(store: store);
      left = _item(window, leftId);
      right = _item(window, rightId);
      relation = (await store.localCalendar.detail(
        left.reference,
      )).relations.single;
      expect(relation.reference.localId, relationId);
      expect(relation.reference.version, updatedRelationVersion + 1);
      expect(relation.kind, CalendarRelationKind.conflict);
      expect(relation.note, '原始关系说明');
      expect(
        (await store.localCalendar.detail(
          right.reference,
        )).relations.single.reference.localId,
        relationId,
      );

      final leftVersionBeforeDelete = left.reference.version;
      final rightVersionBeforeDelete = right.reference.version;
      final relationVersionBeforeDelete = relation.reference.version;
      await _write(store, context, DeleteCalendarRelation(relation.reference));
      window = await _window(store: store);
      left = _item(window, leftId);
      right = _item(window, rightId);
      expect(
        (await store.localCalendar.detail(left.reference)).relations,
        isEmpty,
      );
      expect(
        (await store.localCalendar.detail(right.reference)).relations,
        isEmpty,
      );
      expect(left.reference.version, leftVersionBeforeDelete + 1);
      expect(right.reference.version, rightVersionBeforeDelete + 1);

      await _undoLatest(store, context);
      window = await _window(store: store);
      left = _item(window, leftId);
      right = _item(window, rightId);
      relation = (await store.localCalendar.detail(
        left.reference,
      )).relations.single;
      expect(relation.reference.localId, relationId);
      expect(
        relation.reference.version,
        greaterThan(relationVersionBeforeDelete),
      );
      expect(relation.kind, CalendarRelationKind.conflict);
      expect(relation.note, '原始关系说明');
      expect(left.reference.version, leftVersionBeforeDelete + 2);
      expect(right.reference.version, rightVersionBeforeDelete + 2);
      expect(
        (await store.localCalendar.detail(
          right.reference,
        )).relations.single.reference.localId,
        relationId,
      );
    },
  );

  test(
    'failed undo rolls back slot, business, receipt and audit; maintenance epoch rejects old undo',
    () async {
      var rejectCheckpoint = false;
      final store = await _open(
        checkpoint: () async {
          if (rejectCheckpoint) {
            throw const AppFailure(FailureCode.storageFailed);
          }
        },
      );
      var context = await _context(store);
      final created = await _write(
        store,
        context,
        CreatePersonalEvent(_personalDraft('合成事务撤销')),
      );
      final eventId = created.target!.identity.localId;
      final undoView = await store.localCalendar.queryUndo(context);
      final undoCommand = await store.localCalendar.prepare(
        context,
        UndoCalendarWrite(undoView.reference!),
      );
      final receiptsBefore = await _count(store, 'agenda_receipts');
      final auditBefore = await _count(store, 'agenda_audit');
      final undoRowsBefore = await _count(store, 'agenda_undo');
      expect(undoRowsBefore, 1);

      rejectCheckpoint = true;
      await _failure(
        store.localCalendar.commit(undoCommand),
        CalendarFailureCode.storageFailed,
      );
      rejectCheckpoint = false;

      expect(await _count(store, 'agenda_receipts'), receiptsBefore);
      expect(await _count(store, 'agenda_audit'), auditBefore);
      expect(await _count(store, 'agenda_undo'), undoRowsBefore);
      expect(
        _personalItems(
          await _window(store: store, includeHidden: true),
        ).map((item) => item.reference.identity.localId),
        contains(eventId),
      );
      final undoAfterFailure = await store.localCalendar.queryUndo(context);
      expect(undoAfterFailure.canUndo, isTrue);
      expect(undoAfterFailure.reference!.undoId, undoView.reference!.undoId);

      final committed = await store.localCalendar.commit(undoCommand);
      expect(committed.replayed, isFalse);
      expect(await _count(store, 'agenda_receipts'), receiptsBefore + 1);
      expect(await _count(store, 'agenda_audit'), auditBefore + 1);
      expect(await _count(store, 'agenda_undo'), 0);
      final replay = await store.localCalendar.commit(undoCommand);
      expect(replay.replayed, isTrue);
      expect(await _count(store, 'agenda_receipts'), receiptsBefore + 1);
      expect(await _count(store, 'agenda_audit'), auditBefore + 1);
      expect(
        _personalItems(
          await _window(store: store, includeHidden: true),
        ).map((item) => item.reference.identity.localId),
        isNot(contains(eventId)),
      );

      final later = await _write(
        store,
        context,
        CreatePersonalEvent(_personalDraft('维护前的合成安排')),
      );
      final oldUndo = await store.localCalendar.queryUndo(context);
      expect(oldUndo.canUndo, isTrue);
      final maintenanceContext = await store.localCalendar.beginMaintenance();
      await _failure(
        _write(store, context, UndoCalendarWrite(oldUndo.reference!)),
        CalendarFailureCode.maintenance,
      );
      await store.localCalendar.finishMaintenance(maintenanceContext);
      await _failure(
        _write(store, context, UndoCalendarWrite(oldUndo.reference!)),
        CalendarFailureCode.staleReference,
      );

      context = await _context(store);
      expect(context.agendaEpoch, maintenanceContext.agendaEpoch);
      final expiredByEpoch = await store.localCalendar.queryUndo(context);
      expect(expiredByEpoch.canUndo, isFalse);
      expect(expiredByEpoch.failure, CalendarFailureCode.undoUnavailable);
      expect(expiredByEpoch.reference!.undoId, oldUndo.reference!.undoId);
      await _failure(
        _write(store, context, UndoCalendarWrite(expiredByEpoch.reference!)),
        CalendarFailureCode.undoUnavailable,
      );
      expect(
        _personalItems(
          await _window(store: store, includeHidden: true),
        ).map((item) => item.reference.identity.localId),
        contains(later.target!.identity.localId),
      );
    },
  );
}

Future<JwStore> _open({Future<void> Function()? checkpoint}) async {
  final store = JwStore(
    NativeDatabase.memory(),
    ownership: _Owner(),
    clock: _clock,
    onCalendarCheckpoint: checkpoint,
  );
  addTearDown(store.close);
  await store.initialize();
  return store;
}

Future<CalendarContext> _context(JwStore store) async =>
    (await store.localCalendar.query(_calendarQuery())).context;

CalendarQuery _calendarQuery({
  DateTime? firstDay,
  DateTime? endDayExclusive,
  bool includeHidden = false,
  bool includeSkipped = false,
  CalendarFilter filter = CalendarFilter.all,
}) => CalendarQuery(
  firstDay: firstDay ?? _day,
  endDayExclusive: endDayExclusive ?? _day.add(const Duration(days: 35)),
  includeHidden: includeHidden,
  includeSkipped: includeSkipped,
  filter: filter,
);

Future<CalendarWindow> _window({
  required JwStore store,
  bool includeHidden = false,
  bool includeSkipped = false,
  CalendarFilter filter = CalendarFilter.all,
}) => store.localCalendar.query(
  _calendarQuery(
    includeHidden: includeHidden,
    includeSkipped: includeSkipped,
    filter: filter,
  ),
);

PersonalEventDraft _personalDraft(
  String title, {
  DateTime? start,
  DateTime? end,
}) => PersonalEventDraft(
  title: title,
  start: start ?? DateTime.utc(2026, 10, 12, 1),
  end: end ?? DateTime.utc(2026, 10, 12, 2),
);

List<CalendarOccurrence> _personalItems(CalendarWindow window) => window.items
    .where((item) => item.reference.identity.kind == CalendarKind.personal)
    .toList();

CalendarOccurrence _occurrence(
  CalendarWindow window,
  int localId,
  int ordinal,
) => _personalItems(window).singleWhere(
  (item) =>
      item.reference.identity.localId == localId &&
      item.reference.identity.ordinal == ordinal,
);

CalendarOccurrence _item(CalendarWindow window, CalendarIdentity identity) =>
    window.items.singleWhere((item) => item.reference.identity == identity);

CalendarOccurrence _schoolCourse(CalendarWindow window) => window.items
    .singleWhere((item) => item.reference.identity.kind == CalendarKind.course);

Future<CalendarWriteReceipt> _write(
  JwStore store,
  CalendarContext context,
  CalendarIntent intent,
) async => store.localCalendar.commit(
  await store.localCalendar.prepare(context, intent),
);

Future<CalendarWriteReceipt> _undoLatest(
  JwStore store,
  CalendarContext context,
) async {
  final undo = await store.localCalendar.queryUndo(context);
  expect(undo.canUndo, isTrue);
  return store.localCalendar.commit(
    await store.localCalendar.prepare(
      context,
      UndoCalendarWrite(undo.reference!),
    ),
  );
}

Future<void> _failure(Future<Object?> future, CalendarFailureCode code) =>
    expectLater(
      future,
      throwsA(
        isA<CalendarFailure>().having((failure) => failure.code, 'code', code),
      ),
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
        'examRows': 0,
        'datedExams': 0,
        'semesterAccepted': true,
        'selfRouteBound': true,
        'identityStable': true,
        'emptyCourse': false,
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
        'version': jwContractVersion,
        'semesterId': 202610,
        'courses': [
          {
            'lessonId': 81,
            'groupId': 91,
            'date': '2026-10-12',
            'startMinute': 540,
            'endMinute': endMinute,
            'title': title,
            'academicDetails': JwAcademicDetails(
              lessonId: 81,
              groupId: 91,
            ).toMap(),
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
  @override
  bool get isHeld => true;

  @override
  void ensureHeld() {}
}
