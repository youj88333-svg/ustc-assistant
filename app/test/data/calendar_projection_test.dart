import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/agenda_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/data/calendar_projection.dart';

const _context = CalendarContext(
  owner: 'synthetic-owner',
  resetEpoch: 1,
  agendaEpoch: 1,
);
const _projection = CalendarProjection();

void main() {
  test(
    'weekly identities survive series edits while exceptions keep absolute time',
    () {
      final series = _series(
        9,
        _timedDraft(
          DateTime.utc(2026, 10, 12, 2),
          DateTime.utc(2026, 10, 12, 3),
          weekly: true,
        ),
      );
      final exception = PersonalOccurrenceOverride(
        localId: 9,
        ordinal: 2,
        replacement: _timedDraft(
          DateTime.utc(2026, 10, 20, 4),
          DateTime.utc(2026, 10, 20, 5),
          title: '绝对时间例外',
        ),
        completed: true,
      );
      final editedSeries = _series(
        9,
        _timedDraft(
          DateTime.utc(2026, 10, 13, 7),
          DateTime.utc(2026, 10, 13, 8),
          weekly: true,
        ),
        version: 2,
      );
      final snapshot = _snapshot(
        personal: [editedSeries],
        overrides: [exception],
      );

      final movedBase = _projection.occurrence(
        snapshot,
        const CalendarIdentity(CalendarKind.personal, 9, ordinal: 1),
      )!;
      final originalBase = _projection.occurrence(
        _snapshot(personal: [series], overrides: [exception]),
        const CalendarIdentity(CalendarKind.personal, 9, ordinal: 1),
      )!;
      final preservedException = _projection.occurrence(
        snapshot,
        const CalendarIdentity(CalendarKind.personal, 9, ordinal: 2),
      )!;

      expect(movedBase.startsAtUtc, DateTime.utc(2026, 10, 20, 7));
      expect(movedBase.reference.version, 2);
      expect(movedBase.reference.identity, originalBase.reference.identity);
      expect(movedBase.startsAtUtc, isNot(originalBase.startsAtUtc));
      expect(preservedException.title, '绝对时间例外');
      expect(preservedException.startsAtUtc, DateTime.utc(2026, 10, 20, 4));
      expect(preservedException.completed, isTrue);
    },
  );

  test(
    'a far moved exception enters the window once under its stable ordinal',
    () {
      final series = _series(
        4,
        _timedDraft(
          DateTime.utc(2026, 1, 5, 2),
          DateTime.utc(2026, 1, 5, 3),
          weekly: true,
        ),
      );
      final override = PersonalOccurrenceOverride(
        localId: 4,
        ordinal: 40,
        replacement: _timedDraft(
          DateTime.utc(2026, 10, 12, 2),
          DateTime.utc(2026, 10, 12, 3),
          title: '远处移入',
        ),
      );

      final result = _projection.query(
        _snapshot(personal: [series], overrides: [override]),
        _query(DateTime.utc(2026, 10, 12), DateTime.utc(2026, 10, 13)),
      );

      expect(result.items, hasLength(1));
      expect(result.items.single.reference.identity.ordinal, 40);
      expect(result.items.single.title, '远处移入');
      expect(result.items.single.startsAtUtc, DateTime.utc(2026, 10, 12, 2));
    },
  );

  test('inclusive until, reactivation, and conversion to a single event', () {
    final identity = const CalendarIdentity(
      CalendarKind.personal,
      6,
      ordinal: 2,
    );
    final limited = _series(
      6,
      _timedDraft(
        DateTime.utc(2026, 10, 12, 2),
        DateTime.utc(2026, 10, 12, 3),
        weekly: true,
        untilDay: DateTime.utc(2026, 10, 26),
      ),
    );
    expect(_projection.isActiveOrdinal(limited, 0), isTrue);
    expect(_projection.isActiveOrdinal(limited, 2), isTrue);
    expect(
      _projection.occurrence(_snapshot(personal: [limited]), identity),
      isNotNull,
    );

    final shortened = _series(
      6,
      _timedDraft(
        DateTime.utc(2026, 10, 12, 2),
        DateTime.utc(2026, 10, 12, 3),
        weekly: true,
        untilDay: DateTime.utc(2026, 10, 19),
      ),
    );
    final shortenedSnapshot = _snapshot(personal: [shortened]);
    expect(_projection.occurrence(shortenedSnapshot, identity), isNull);

    final restored = _series(
      6,
      _timedDraft(
        DateTime.utc(2026, 10, 12, 2),
        DateTime.utc(2026, 10, 12, 3),
        weekly: true,
        untilDay: DateTime.utc(2026, 10, 26),
      ),
    );
    expect(
      _projection.occurrence(_snapshot(personal: [restored]), identity),
      isNotNull,
    );

    final converted = _series(
      6,
      _timedDraft(DateTime.utc(2026, 10, 12, 2), DateTime.utc(2026, 10, 12, 3)),
    );
    final convertedSnapshot = _snapshot(
      personal: [converted],
      overrides: [
        PersonalOccurrenceOverride(
          localId: 6,
          ordinal: 2,
          replacement: _timedDraft(
            DateTime.utc(2026, 10, 26, 2),
            DateTime.utc(2026, 10, 26, 3),
          ),
        ),
      ],
    );
    expect(_projection.occurrence(convertedSnapshot, identity), isNull);
    expect(
      _projection.occurrence(
        convertedSnapshot,
        const CalendarIdentity(CalendarKind.personal, 6),
      ),
      isNotNull,
    );
  });

  test(
    'all-day end is exclusive and timed overnight events split at Beijing midnight',
    () {
      final snapshot = _snapshot(
        personal: [
          _series(
            1,
            PersonalEventDraft(
              title: '全天',
              start: DateTime.utc(2026, 10, 12),
              end: DateTime.utc(2026, 10, 14),
              allDay: true,
            ),
          ),
        ],
        school: [
          _school(
            CalendarKind.course,
            2,
            DateTime.utc(2026, 10, 12, 15, 30),
            DateTime.utc(2026, 10, 12, 16, 30),
          ),
        ],
      );
      final result = _projection.query(
        snapshot,
        _query(DateTime.utc(2026, 10, 12), DateTime.utc(2026, 10, 14)),
      );
      final allDaySegments = result.segments
          .where(
            (segment) => segment.occurrence.reference.identity.localId == 1,
          )
          .toList();
      final overnightSegments = result.segments
          .where(
            (segment) => segment.occurrence.reference.identity.localId == 2,
          )
          .toList();

      expect(allDaySegments, hasLength(2));
      expect(allDaySegments.map((segment) => segment.startMinute), [0, 0]);
      expect(allDaySegments.map((segment) => segment.endMinute), [1440, 1440]);
      expect(allDaySegments.last.continuesBefore, isTrue);
      expect(allDaySegments.first.continuesAfter, isTrue);
      expect(overnightSegments, hasLength(2));
      expect(overnightSegments[0].startMinute, 1410);
      expect(overnightSegments[0].endMinute, 1440);
      expect(overnightSegments[0].continuesAfter, isTrue);
      expect(overnightSegments[1].startMinute, 0);
      expect(overnightSegments[1].endMinute, 30);
      expect(overnightSegments[1].continuesBefore, isTrue);

      final exclusiveEnd = _projection.query(
        snapshot,
        _query(DateTime.utc(2026, 10, 14), DateTime.utc(2026, 10, 15)),
      );
      expect(exclusiveEnd.items, isEmpty);
    },
  );

  test(
    'source filters do not narrow conflicts; identity includes kind and ordinal',
    () {
      final start = DateTime.utc(2026, 10, 12, 2);
      final end = DateTime.utc(2026, 10, 12, 3);
      final relation = CalendarRelation(
        reference: const CalendarRelationReference(_context, 11, 1),
        left: const CalendarIdentity(CalendarKind.course, 1),
        right: const CalendarIdentity(CalendarKind.personal, 1),
        kind: CalendarRelationKind.notConflict,
        note: '合成关系',
      );
      final snapshot = _snapshot(
        school: [
          _school(
            CalendarKind.course,
            1,
            start,
            end,
            presence: AgendaPresence.missingWithinScope,
            completed: true,
          ),
          _school(CalendarKind.exam, 1, start, end),
          _school(
            CalendarKind.young,
            1,
            start,
            end,
            presence: AgendaPresence.outsideScope,
          ),
          _school(CalendarKind.course, 2, start, end, hidden: true),
        ],
        personal: [
          _series(1, _timedDraft(start, end, title: '个人')),
          _series(2, _timedDraft(start, end, weekly: true)),
        ],
        overrides: [
          const PersonalOccurrenceOverride(
            localId: 2,
            ordinal: 0,
            skipped: true,
          ),
        ],
        relations: [relation],
      );

      final filtered = _projection.query(
        snapshot,
        _query(
          DateTime.utc(2026, 10, 12),
          DateTime.utc(2026, 10, 13),
          filter: CalendarFilter.personal,
          includeHidden: true,
          includeSkipped: true,
        ),
      );

      expect(filtered.items, hasLength(2));
      expect(
        filtered.items.every(
          (item) => item.reference.identity.kind == CalendarKind.personal,
        ),
        isTrue,
      );
      expect(filtered.conflicts, hasLength(6));
      expect(
        filtered.conflicts.where((conflict) => conflict.relation != null),
        hasLength(1),
      );

      final defaultView = _projection.query(
        snapshot,
        _query(DateTime.utc(2026, 10, 12), DateTime.utc(2026, 10, 13)),
      );
      expect(defaultView.items, hasLength(4));
      expect(defaultView.conflicts, hasLength(6));
      expect(
        defaultView.conflicts.where(
          (pair) => pair.status == CalendarConflictStatus.notConflict,
        ),
        hasLength(1),
      );
      expect(
        defaultView.conflicts.where(
          (pair) => pair.status == CalendarConflictStatus.conflict,
        ),
        hasLength(5),
      );

      final unfiltered = _projection.query(
        snapshot,
        _query(
          DateTime.utc(2026, 10, 12),
          DateTime.utc(2026, 10, 13),
          includeHidden: true,
          includeSkipped: true,
        ),
      );
      expect(unfiltered.items, hasLength(6));
      expect(unfiltered.items.where((item) => item.hidden), hasLength(1));
      expect(unfiltered.items.where((item) => item.skipped), hasLength(1));
      expect(
        unfiltered.items.map((item) => item.reference.identity).toSet(),
        hasLength(6),
      );
      expect(
        unfiltered.items.first.presence,
        AgendaPresence.missingWithinScope,
      );
      expect(unfiltered.items.first.completed, isTrue);
    },
  );

  test('all-day items remain visible but never create overlap candidates', () {
    final result = _projection.query(
      _snapshot(
        personal: [
          _series(
            1,
            PersonalEventDraft(
              title: '全天一',
              start: DateTime.utc(2026, 10, 12),
              end: DateTime.utc(2026, 10, 13),
              allDay: true,
            ),
          ),
          _series(
            2,
            PersonalEventDraft(
              title: '全天二',
              start: DateTime.utc(2026, 10, 12),
              end: DateTime.utc(2026, 10, 13),
              allDay: true,
            ),
          ),
          _series(
            3,
            _timedDraft(
              DateTime.utc(2026, 10, 12, 2),
              DateTime.utc(2026, 10, 12, 3),
            ),
          ),
        ],
      ),
      _query(DateTime.utc(2026, 10, 12), DateTime.utc(2026, 10, 13)),
    );
    expect(result.items, hasLength(3));
    expect(
      result.segments.where((segment) => segment.occurrence.allDay),
      hasLength(2),
    );
    expect(result.conflicts, isEmpty);
  });

  test(
    'hidden and skipped records never create conflicts; touching endpoints do not overlap',
    () {
      final start = DateTime.utc(2026, 10, 12, 2);
      final end = DateTime.utc(2026, 10, 12, 3);
      final result = _projection.query(
        _snapshot(
          school: [
            _school(CalendarKind.course, 1, start, end),
            _school(
              CalendarKind.exam,
              2,
              end,
              end.add(const Duration(hours: 1)),
            ),
            _school(CalendarKind.young, 3, start, end, hidden: true),
          ],
          personal: [
            _series(4, _timedDraft(start, end)),
            _series(5, _timedDraft(start, end)),
          ],
          overrides: [
            const PersonalOccurrenceOverride(
              localId: 5,
              ordinal: 0,
              skipped: true,
            ),
          ],
        ),
        _query(
          DateTime.utc(2026, 10, 12),
          DateTime.utc(2026, 10, 13),
          includeHidden: true,
          includeSkipped: true,
        ),
      );

      expect(result.items, hasLength(5));
      expect(result.conflicts, hasLength(1));
      expect(result.conflicts.single.left.reference.identity.localId, 1);
      expect(result.conflicts.single.right.reference.identity.localId, 4);
    },
  );

  test(
    'matched count precedes item truncation and returned collections are immutable',
    () {
      final start = DateTime.utc(2026, 10, 12, 2);
      final result = _projection.query(
        _snapshot(
          school: List.generate(
            3,
            (index) => _school(
              CalendarKind.course,
              index + 1,
              start.add(Duration(minutes: index)),
              start.add(Duration(minutes: index + 30)),
            ),
          ),
        ),
        _query(
          DateTime.utc(2026, 10, 12),
          DateTime.utc(2026, 10, 13),
          limit: 1,
        ),
      );

      expect(result.items, hasLength(1));
      expect(result.matched, 3);
      expect(result.truncated, isTrue);
      expect(() => result.items.clear(), throwsUnsupportedError);
      expect(() => result.segments.clear(), throwsUnsupportedError);
      expect(() => result.conflicts.clear(), throwsUnsupportedError);
    },
  );

  test('input and expansion budgets fail explicitly', () {
    final start = DateTime.utc(2026, 10, 12, 2);
    expect(
      () => _projection.query(
        _snapshot(),
        _query(DateTime.utc(2026, 10, 12), DateTime.utc(2026, 12, 14)),
      ),
      throwsA(
        isA<CalendarFailure>().having(
          (failure) => failure.code,
          'code',
          CalendarFailureCode.invalidInput,
        ),
      ),
    );
    expect(
      () => _projection.query(
        _snapshot(),
        _query(
          DateTime.utc(2026, 10, 12),
          DateTime.utc(2026, 10, 13),
          limit: 0,
        ),
      ),
      throwsA(
        isA<CalendarFailure>().having(
          (failure) => failure.code,
          'code',
          CalendarFailureCode.invalidInput,
        ),
      ),
    );
    final tooManyRows = _snapshot(
      school: List.generate(
        5001,
        (index) => _school(
          CalendarKind.course,
          index + 1,
          start,
          start.add(const Duration(hours: 1)),
        ),
      ),
    );
    expect(
      () => _projection.query(
        tooManyRows,
        _query(DateTime.utc(2026, 10, 12), DateTime.utc(2026, 10, 13)),
      ),
      throwsA(
        isA<CalendarFailure>().having(
          (failure) => failure.code,
          'code',
          CalendarFailureCode.limitExceeded,
        ),
      ),
    );

    final manySeries = List.generate(
      2500,
      (index) => _series(
        index + 1,
        _timedDraft(
          DateTime.utc(2026, 10, 12, 2),
          DateTime.utc(2026, 10, 12, 3),
          weekly: true,
        ),
      ),
    );
    expect(
      () => _projection.query(
        _snapshot(personal: manySeries),
        _query(DateTime.utc(2026, 10, 12), DateTime.utc(2026, 12, 13)),
      ),
      throwsA(
        isA<CalendarFailure>().having(
          (failure) => failure.code,
          'code',
          CalendarFailureCode.limitExceeded,
        ),
      ),
    );
  });

  test('conflict result has its own cap and truncation flag', () {
    final start = DateTime.utc(2026, 10, 12, 2);
    final school = List.generate(
      22,
      (index) => _school(
        CalendarKind.course,
        index + 1,
        start,
        start.add(const Duration(hours: 1)),
      ),
    );
    final result = _projection.query(
      _snapshot(school: school),
      _query(DateTime.utc(2026, 10, 12), DateTime.utc(2026, 10, 13)),
    );

    expect(result.conflicts, hasLength(200));
    expect(result.conflictsTruncated, isTrue);
    expect(result.items, hasLength(22));
  });
}

CalendarQuery _query(
  DateTime firstDay,
  DateTime endDayExclusive, {
  CalendarFilter filter = CalendarFilter.all,
  bool includeHidden = false,
  bool includeSkipped = false,
  int limit = 500,
}) => CalendarQuery(
  firstDay: firstDay,
  endDayExclusive: endDayExclusive,
  filter: filter,
  includeHidden: includeHidden,
  includeSkipped: includeSkipped,
  limit: limit,
);

CalendarSnapshot _snapshot({
  List<CalendarOccurrence> school = const [],
  List<PersonalSeries> personal = const [],
  List<PersonalOccurrenceOverride> overrides = const [],
  List<CalendarRelation> relations = const [],
}) => CalendarSnapshot(
  context: _context,
  revision: 12,
  school: school,
  personal: personal,
  overrides: overrides,
  relations: relations,
);

PersonalSeries _series(
  int localId,
  PersonalEventDraft draft, {
  int version = 1,
}) => PersonalSeries(localId: localId, version: version, draft: draft);

PersonalEventDraft _timedDraft(
  DateTime start,
  DateTime end, {
  String title = '合成安排',
  bool weekly = false,
  DateTime? untilDay,
}) => PersonalEventDraft(
  title: title,
  start: start,
  end: end,
  weekly: weekly,
  untilDay: untilDay,
);

CalendarOccurrence _school(
  CalendarKind kind,
  int id,
  DateTime start,
  DateTime end, {
  AgendaPresence presence = AgendaPresence.observed,
  bool hidden = false,
  bool completed = false,
}) => CalendarOccurrence(
  reference: CalendarReference(_context, CalendarIdentity(kind, id), 1),
  title: '合成${kind.name} $id',
  startsAtUtc: start,
  endsAtUtc: end,
  presence: presence,
  hidden: hidden,
  completed: completed,
);
