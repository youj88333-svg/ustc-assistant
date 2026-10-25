import 'package:flutter_test/flutter_test.dart';

import 'package:ustc_assistant_m0/agent/agent_free_slots.dart';
import 'package:ustc_assistant_m0/core/agenda_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';

const _context = CalendarContext(
  owner: 'synthetic',
  resetEpoch: 1,
  agendaEpoch: 1,
);

void main() {
  group('findAgentFreeSlots', () {
    test(
      'keeps source-missing timed items busy, ignores all-day, and honors half-open bounds',
      () {
        final day = _date(2026, 10, 12);
        final first = _event(
          id: 1,
          kind: CalendarKind.course,
          start: _minute(day, 570),
          end: _minute(day, 600),
        );
        final second = _event(
          id: 2,
          kind: CalendarKind.personal,
          start: _minute(day, 585),
          end: _minute(day, 615),
        );
        final missing = _event(
          id: 3,
          kind: CalendarKind.exam,
          start: _minute(day, 690),
          end: _minute(day, 720),
          presence: AgendaPresence.missingWithinScope,
        );
        final allDay = _event(
          id: 4,
          kind: CalendarKind.young,
          start: _minute(day, 540),
          end: _minute(day, 780),
          allDay: true,
        );
        final notConflict = CalendarRelation(
          reference: CalendarRelationReference(_context, 7, 1),
          left: first.reference.identity,
          right: second.reference.identity,
          kind: CalendarRelationKind.notConflict,
        );
        final window = _window(
          day,
          day.add(const Duration(days: 1)),
          items: [first, second, missing, allDay],
          conflicts: [CalendarConflict(first, second, relation: notConflict)],
        );

        final result = findAgentFreeSlots(
          window,
          _conditions(
            day,
            day.add(const Duration(days: 1)),
            availability: {
              day.weekday: [AgentFreeMinuteRange(540, 780)],
            },
            blockMinutes: 60,
          ),
        );

        expect(result.status, AgentFreeSlotsStatus.complete);
        expect(
          result.candidates
              .map((candidate) => (candidate.startsAtUtc, candidate.endsAtUtc))
              .toList(),
          [
            (_minute(day, 615), _minute(day, 675)),
            (_minute(day, 720), _minute(day, 780)),
          ],
        );
        expect(result.windowComplete, isTrue);
        expect(result.includeHidden, isFalse);
        expect(result.includeSkipped, isFalse);
      },
    );

    test(
      'splits a cross-Beijing-midnight event at the actual UTC boundary',
      () {
        final monday = _date(2026, 10, 12);
        final tuesday = monday.add(const Duration(days: 1));
        final event = _event(
          id: 5,
          kind: CalendarKind.personal,
          start: _minute(monday, 1410),
          end: _minute(tuesday, 60),
        );

        final result = findAgentFreeSlots(
          _window(monday, monday.add(const Duration(days: 2)), items: [event]),
          _conditions(
            monday,
            monday.add(const Duration(days: 2)),
            availability: {
              monday.weekday: [AgentFreeMinuteRange(1380, 1440)],
              tuesday.weekday: [AgentFreeMinuteRange(60, 180)],
            },
            blockMinutes: 60,
          ),
        );

        expect(result.status, AgentFreeSlotsStatus.complete);
        expect(result.candidates, hasLength(2));
        expect(result.candidates.first.startsAtUtc, _minute(tuesday, 60));
        expect(result.candidates.first.endsAtUtc, _minute(tuesday, 120));
        expect(result.candidates.last.startsAtUtc, _minute(tuesday, 120));
        expect(result.candidates.last.endsAtUtc, _minute(tuesday, 180));
      },
    );

    test('hidden and skipped items are controlled by explicit filters', () {
      final day = _date(2026, 10, 13);
      final hidden = _event(
        id: 6,
        kind: CalendarKind.course,
        start: _minute(day, 540),
        end: _minute(day, 600),
        hidden: true,
      );
      final skipped = _event(
        id: 7,
        kind: CalendarKind.personal,
        start: _minute(day, 540),
        end: _minute(day, 600),
        skipped: true,
      );
      final window = _window(
        day,
        day.add(const Duration(days: 1)),
        items: [hidden, skipped],
        includeHidden: true,
        includeSkipped: true,
      );
      final base = {
        day.weekday: [AgentFreeMinuteRange(540, 600)],
      };

      final excluded = findAgentFreeSlots(
        window,
        _conditions(
          day,
          day.add(const Duration(days: 1)),
          availability: base,
          blockMinutes: 60,
        ),
      );
      final includeHidden = findAgentFreeSlots(
        window,
        _conditions(
          day,
          day.add(const Duration(days: 1)),
          availability: base,
          blockMinutes: 60,
          includeHidden: true,
        ),
      );
      final includeSkipped = findAgentFreeSlots(
        window,
        _conditions(
          day,
          day.add(const Duration(days: 1)),
          availability: base,
          blockMinutes: 60,
          includeSkipped: true,
        ),
      );

      expect(excluded.status, AgentFreeSlotsStatus.complete);
      expect(excluded.candidates, hasLength(1));
      expect(includeHidden.candidates, isEmpty);
      expect(includeSkipped.candidates, isEmpty);
    });

    test(
      'keeps the requested rest gap and allows a block ending at the UTC deadline',
      () {
        final day = _date(2026, 10, 13);
        final end = day.add(const Duration(days: 1));
        final result = findAgentFreeSlots(
          _window(day, end),
          _conditions(
            day,
            end,
            availability: {
              day.weekday: [AgentFreeMinuteRange(540, 780)],
            },
            blockMinutes: 60,
            breakMinutes: 30,
            deadlineUtc: _minute(day, 690),
          ),
        );

        expect(result.status, AgentFreeSlotsStatus.complete);
        expect(
          result.candidates
              .map((candidate) => (candidate.startsAtUtc, candidate.endsAtUtc))
              .toList(),
          [
            (_minute(day, 540), _minute(day, 600)),
            (_minute(day, 630), _minute(day, 690)),
          ],
        );
      },
    );

    test(
      'distinguishes complete empty, candidate-cap limited, and window limited',
      () {
        final day = _date(2026, 10, 14);
        final end = day.add(const Duration(days: 1));
        final availability = {
          day.weekday: [AgentFreeMinuteRange(540, 720)],
        };
        final fullWindow = _window(day, end);

        final noAvailability = findAgentFreeSlots(
          fullWindow,
          _conditions(day, end, availability: const {}, blockMinutes: 60),
        );
        expect(noAvailability.status, AgentFreeSlotsStatus.complete);
        expect(noAvailability.candidates, isEmpty);
        expect(noAvailability.windowComplete, isTrue);

        final capped = findAgentFreeSlots(
          fullWindow,
          _conditions(
            day,
            end,
            availability: availability,
            blockMinutes: 60,
            maxCandidates: 1,
          ),
        );
        expect(capped.status, AgentFreeSlotsStatus.limited);
        expect(capped.candidates, hasLength(1));
        expect(capped.candidatesTruncated, isTrue);
        expect(capped.windowComplete, isTrue);

        final truncatedWindow = _window(day, end, truncated: true, matched: 1);
        final limited = findAgentFreeSlots(
          truncatedWindow,
          _conditions(day, end, availability: availability, blockMinutes: 60),
        );
        expect(limited.status, AgentFreeSlotsStatus.limited);
        expect(limited.candidates, isEmpty);
        expect(limited.windowComplete, isFalse);
        expect(limited.windowTruncated, isTrue);
      },
    );

    test(
      'rejects unsafe bounds, non-UTC deadlines, and mismatched windows',
      () {
        final day = _date(2026, 10, 14);
        final end = day.add(const Duration(days: 1));
        final window = _window(day, end);
        final availability = {
          day.weekday: [AgentFreeMinuteRange(540, 600)],
        };

        AgentFreeSlotsResult run({
          int blockMinutes = 60,
          int maxCandidates = 20,
          int breakMinutes = 0,
          DateTime? deadlineUtc,
          DateTime? firstDay,
          bool includeHidden = false,
        }) => findAgentFreeSlots(
          window,
          _conditions(
            firstDay ?? day,
            end,
            availability: availability,
            blockMinutes: blockMinutes,
            maxCandidates: maxCandidates,
            breakMinutes: breakMinutes,
            deadlineUtc: deadlineUtc,
            includeHidden: includeHidden,
          ),
        );

        expect(run(blockMinutes: -1).status, AgentFreeSlotsStatus.rejected);
        expect(run(maxCandidates: 21).status, AgentFreeSlotsStatus.rejected);
        expect(run(breakMinutes: -1).status, AgentFreeSlotsStatus.rejected);
        expect(
          findAgentFreeSlots(
            window,
            _conditions(
              day,
              day.add(const Duration(days: 32)),
              availability: availability,
              blockMinutes: 60,
            ),
          ).status,
          AgentFreeSlotsStatus.rejected,
        );
        expect(
          findAgentFreeSlots(
            window,
            _conditions(
              day,
              end,
              availability: {
                day.weekday: [AgentFreeMinuteRange(-1, 600)],
              },
              blockMinutes: 60,
            ),
          ).status,
          AgentFreeSlotsStatus.rejected,
        );
        expect(
          run(deadlineUtc: DateTime(2026, 10, 14, 10)).status,
          AgentFreeSlotsStatus.rejected,
        );
        expect(
          run(firstDay: day.subtract(const Duration(days: 1))).status,
          AgentFreeSlotsStatus.rejected,
        );
        expect(run(includeHidden: true).status, AgentFreeSlotsStatus.rejected);
      },
    );
  });
}

DateTime _date(int year, int month, int day) => DateTime.utc(year, month, day);

DateTime _minute(DateTime day, int minute) => DateTime.utc(
  day.year,
  day.month,
  day.day,
).subtract(const Duration(hours: 8)).add(Duration(minutes: minute));

CalendarWindow _window(
  DateTime firstDay,
  DateTime endDayExclusive, {
  List<CalendarOccurrence> items = const [],
  List<CalendarConflict> conflicts = const [],
  bool includeHidden = false,
  bool includeSkipped = false,
  bool truncated = false,
  int? matched,
}) {
  final query = CalendarQuery(
    firstDay: firstDay,
    endDayExclusive: endDayExclusive,
    filter: CalendarFilter.all,
    includeHidden: includeHidden,
    includeSkipped: includeSkipped,
    limit: 500,
  );
  return CalendarWindow(
    context: _context,
    revision: 1,
    query: query,
    items: items,
    segments: const [],
    conflicts: conflicts,
    matched: matched ?? items.length,
    truncated: truncated,
    conflictsTruncated: false,
  );
}

AgentFreeSlotConditions _conditions(
  DateTime firstDay,
  DateTime endDayExclusive, {
  required Map<int, List<AgentFreeMinuteRange>> availability,
  required int blockMinutes,
  int maxCandidates = 20,
  int breakMinutes = 0,
  bool includeHidden = false,
  bool includeSkipped = false,
  DateTime? deadlineUtc,
}) => AgentFreeSlotConditions(
  firstDay: firstDay,
  endDayExclusive: endDayExclusive,
  availability: availability.entries
      .map(
        (entry) => AgentFreeWeekdayAvailability(
          weekday: entry.key,
          intervals: entry.value,
        ),
      )
      .toList(),
  blockMinutes: blockMinutes,
  maxCandidates: maxCandidates,
  breakMinutes: breakMinutes,
  includeHidden: includeHidden,
  includeSkipped: includeSkipped,
  deadlineUtc: deadlineUtc,
);

CalendarOccurrence _event({
  required int id,
  required CalendarKind kind,
  required DateTime start,
  required DateTime end,
  bool allDay = false,
  bool hidden = false,
  bool skipped = false,
  AgendaPresence presence = AgendaPresence.observed,
}) => CalendarOccurrence(
  reference: CalendarReference(_context, CalendarIdentity(kind, id), 1),
  title: 'synthetic $id',
  startsAtUtc: start,
  endsAtUtc: end,
  allDay: allDay,
  presence: presence,
  hidden: hidden,
  skipped: skipped,
);
