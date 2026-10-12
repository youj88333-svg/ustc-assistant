import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/agenda_contract.dart';
import 'package:ustc_assistant_m0/data/agenda_projection.dart';
import 'package:ustc_assistant_m0/data/jw_import_contract.dart';
import 'package:ustc_assistant_m0/data/young_import_contract.dart';

void main() {
  const projection = AgendaProjection();
  final day = DateTime.utc(2026, 10, 12);

  test('Beijing today is independent of the host timezone', () {
    expect(beijingDay(DateTime.utc(2026, 10, 11, 16)), day);
    expect(
      beijingDay(DateTime.utc(2026, 10, 11, 15, 59)),
      DateTime.utc(2026, 10, 11),
    );
  });

  test('cross-midnight records use intersection and exclusive end', () {
    final jw = _jw([
      _course(
        1,
        DateTime.utc(2026, 10, 11, 15),
        DateTime.utc(2026, 10, 11, 16),
      ),
      _course(
        2,
        DateTime.utc(2026, 10, 11, 15, 30),
        DateTime.utc(2026, 10, 11, 16, 30),
      ),
      _course(
        3,
        DateTime.utc(2026, 10, 12, 15, 30),
        DateTime.utc(2026, 10, 12, 16, 30),
      ),
      _course(
        4,
        DateTime.utc(2026, 10, 12, 16),
        DateTime.utc(2026, 10, 12, 17),
      ),
    ]);
    final result = projection.query(day: day, jw: jw, young: _young([]));
    expect(result.items.map((e) => e.reference.localId), [2, 3]);
    expect(result.matched, 2);
    expect(result.totalStored, 4);
    expect(result.ready, isTrue);
  });

  test(
    'missing/outside-scope records remain; only explicit hidden filters',
    () {
      final start = DateTime.utc(2026, 10, 12, 1);
      final end = start.add(const Duration(hours: 1));
      final jw = _jw([
        _course(1, start, end, presence: JwPresence.missingWithinScope),
        _course(2, start, end, presence: JwPresence.outsideScope),
        _course(3, start, end, hidden: true),
      ]);
      final result = projection.query(day: day, jw: jw, young: _young([]));
      expect(result.items.map((e) => e.reference.localId), [1, 2]);
      expect(result.items.first.presence, AgendaPresence.missingWithinScope);
      expect(
        projection
            .query(day: day, jw: jw, young: _young([]), includeHidden: true)
            .items,
        hasLength(3),
      );
    },
  );

  test('JW and Young overlapping local ids are distinct source records', () {
    final start = DateTime.utc(2026, 10, 12, 2);
    final end = start.add(const Duration(hours: 1));
    final result = projection.query(
      day: day,
      jw: _jw([_course(1, start, end)]),
      young: _young([
        YoungStoredEvent(
          localId: 1,
          version: 1,
          title: '合成二课',
          place: '合成地点',
          startsAtUtc: start,
          endsAtUtc: end,
          presence: YoungPresence.observed,
          hidden: false,
        ),
      ]),
    );
    expect(result.items, hasLength(2));
    expect(result.items.map((e) => e.reference).toSet(), hasLength(2));
    expect(result.items.last.location, '合成地点');
    expect(
      projection
          .query(
            day: day,
            jw: _jw([_course(1, start, end)]),
            young: _young([]),
            filter: AgendaFilter.exam,
          )
          .items,
      isEmpty,
    );
  });

  test(
    'unread data is distinct from a valid empty day; coverage is bounded',
    () {
      final unread = projection.query(day: day, jw: null, young: _young([]));
      expect(unread.ready, isFalse);
      final empty = projection.query(day: day, jw: _jw([]), young: _young([]));
      expect(empty.ready, isTrue);
      expect(empty.matched, 0);
      final start = DateTime.utc(2026, 10, 12, 2);
      final large = projection.query(
        day: day,
        jw: _jw(
          List.generate(
            501,
            (i) => _course(i + 1, start, start.add(const Duration(hours: 1))),
          ),
        ),
        young: _young([]),
      );
      expect(large.items, hasLength(500));
      expect(large.matched, 501);
      expect(large.truncated, isTrue);
      expect(() => large.items.clear(), throwsUnsupportedError);
    },
  );
}

JwDataView _jw(List<JwStoredEvent> events) => JwDataView(
  accountBound: true,
  courseCount: events.length,
  examCount: 0,
  importCount: 1,
  auditCount: 1,
  events: events,
);

YoungDataView _young(List<YoungStoredEvent> events) => YoungDataView(
  accountBound: true,
  importCount: 1,
  queryCount: 0,
  auditCount: 1,
  events: events,
);

JwStoredEvent _course(
  int id,
  DateTime start,
  DateTime end, {
  bool hidden = false,
  JwPresence presence = JwPresence.observed,
}) => JwStoredEvent(
  localId: id,
  version: 1,
  kind: JwEventKind.course,
  title: '合成课程 $id',
  startsAtUtc: start,
  endsAtUtc: end,
  presence: presence,
  hidden: hidden,
);
