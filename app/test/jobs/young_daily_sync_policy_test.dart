import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/young_daily_sync_contract.dart';
import 'package:ustc_assistant_m0/core/young_daily_sync_policy.dart';

void main() {
  group('Young daily sync policy', () {
    test('waits until 06:00 Beijing and runs at the boundary', () {
      final before = planYoungDailySync(
        _snapshot(),
        DateTime.utc(2026, 10, 14, 21, 59, 59),
      );
      expect(before.phase, YoungDailySyncPhase.scheduled);
      expect(before.shouldRun, isFalse);
      expect(before.nextAttemptAtUtc, DateTime.utc(2026, 10, 14, 22));

      final at = planYoungDailySync(
        _snapshot(),
        DateTime.utc(2026, 10, 14, 22),
      );
      expect(at.phase, YoungDailySyncPhase.scheduled);
      expect(at.shouldRun, isTrue);
      expect(at.firstDay, DateTime.utc(2026, 10, 14));
      expect(at.endDayExclusive, DateTime.utc(2026, 11, 14));
    });

    test('uses Beijing dates across UTC midnight', () {
      final beforeUtcMidnight = planYoungDailySync(
        _snapshot(),
        DateTime.utc(2026, 10, 14, 23, 30),
      );
      expect(beforeUtcMidnight.firstDay, DateTime.utc(2026, 10, 14));
      expect(beforeUtcMidnight.endDayExclusive, DateTime.utc(2026, 11, 14));

      final afterUtcMidnight = planYoungDailySync(
        _snapshot(),
        DateTime.utc(2026, 10, 15, 17),
      );
      expect(afterUtcMidnight.firstDay, DateTime.utc(2026, 10, 15));
      expect(afterUtcMidnight.endDayExclusive, DateTime.utc(2026, 11, 15));
      expect(afterUtcMidnight.nextAttemptAtUtc, DateTime.utc(2026, 10, 15, 22));
    });

    test('only a full same-Beijing-day calendar success is done', () {
      final now = DateTime.utc(2026, 10, 15, 4);
      final complete = planYoungDailySync(
        _snapshot(
          lastSuccessAtUtc: DateTime.utc(2026, 10, 15, 2),
          successFirstDay: DateTime.utc(2026, 10, 13),
          successEndDayExclusive: DateTime.utc(2026, 11, 14),
        ),
        now,
      );
      expect(complete.phase, YoungDailySyncPhase.done);
      expect(complete.shouldRun, isFalse);
      expect(complete.nextAttemptAtUtc, DateTime.utc(2026, 10, 15, 22));

      final yesterday = planYoungDailySync(
        _snapshot(
          lastSuccessAtUtc: DateTime.utc(2026, 10, 14, 10),
          successFirstDay: DateTime.utc(2026, 10, 13),
          successEndDayExclusive: DateTime.utc(2026, 11, 15),
        ),
        now,
      );
      expect(yesterday.shouldRun, isTrue);

      final partialAtStart = planYoungDailySync(
        _snapshot(
          lastSuccessAtUtc: DateTime.utc(2026, 10, 15, 2),
          successFirstDay: DateTime.utc(2026, 10, 15),
          successEndDayExclusive: DateTime.utc(2026, 11, 14),
        ),
        now,
      );
      expect(partialAtStart.shouldRun, isTrue);

      final partialAtEnd = planYoungDailySync(
        _snapshot(
          lastSuccessAtUtc: DateTime.utc(2026, 10, 15, 2),
          successFirstDay: DateTime.utc(2026, 10, 13),
          successEndDayExclusive: DateTime.utc(2026, 11, 13),
        ),
        now,
      );
      expect(partialAtEnd.shouldRun, isTrue);

      final disjointHistory = planYoungDailySync(
        _snapshot(
          lastSuccessAtUtc: DateTime.utc(2026, 10, 15, 2),
          successFirstDay: DateTime.utc(2020, 1, 1),
          successEndDayExclusive: DateTime.utc(2020, 2, 1),
        ),
        now,
      );
      expect(disjointHistory.shouldRun, isTrue);
    });

    test('manual run uses the rolling range and bypasses automatic gates', () {
      final decision = planYoungDailySync(
        _snapshot(
          credentialSaved: false,
          attempts: 9,
          attemptDay: DateTime.utc(2026, 10, 15),
          suppressedDay: DateTime.utc(2026, 10, 15),
          lastSuccessAtUtc: DateTime.utc(2026, 10, 15, 2),
          successFirstDay: DateTime.utc(2020, 1, 1),
          successEndDayExclusive: DateTime.utc(2020, 2, 1),
        ),
        DateTime.utc(2026, 10, 15, 4),
        manual: true,
      );
      expect(decision.phase, YoungDailySyncPhase.scheduled);
      expect(decision.shouldRun, isTrue);
      expect(decision.nextAttemptAtUtc, isNull);
      expect(decision.firstDay, DateTime.utc(2026, 10, 14));
      expect(decision.endDayExclusive, DateTime.utc(2026, 11, 14));
    });

    test('automatic retries wait strictly until the stored retry time', () {
      final retryAt = DateTime.utc(2026, 10, 15, 4, 15);
      final waiting = planYoungDailySync(
        _snapshot(
          attemptDay: DateTime.utc(2026, 10, 15),
          attempts: 1,
          nextAttemptAtUtc: retryAt,
        ),
        DateTime.utc(2026, 10, 15, 4),
      );
      expect(waiting.phase, YoungDailySyncPhase.failed);
      expect(waiting.shouldRun, isFalse);
      expect(waiting.nextAttemptAtUtc, retryAt);

      final atBoundary = planYoungDailySync(
        _snapshot(
          attemptDay: DateTime.utc(2026, 10, 15),
          attempts: 1,
          nextAttemptAtUtc: retryAt,
        ),
        retryAt,
      );
      expect(atBoundary.phase, YoungDailySyncPhase.scheduled);
      expect(atBoundary.shouldRun, isTrue);
    });

    test('three attempts pause until tomorrow and yesterday state resets', () {
      final exhausted = planYoungDailySync(
        _snapshot(
          attemptDay: DateTime.utc(2026, 10, 15),
          attempts: 3,
          nextAttemptAtUtc: DateTime.utc(2026, 10, 15, 5),
        ),
        DateTime.utc(2026, 10, 15, 4),
      );
      expect(exhausted.phase, YoungDailySyncPhase.failed);
      expect(exhausted.shouldRun, isFalse);
      expect(exhausted.nextAttemptAtUtc, DateTime.utc(2026, 10, 15, 22));

      final nextDay = planYoungDailySync(
        _snapshot(
          attemptDay: DateTime.utc(2026, 10, 15),
          attempts: 3,
          needsLogin: true,
          nextAttemptAtUtc: DateTime.utc(2026, 10, 15, 5),
        ),
        DateTime.utc(2026, 10, 15, 22),
      );
      expect(nextDay.firstDay, DateTime.utc(2026, 10, 15));
      expect(nextDay.phase, YoungDailySyncPhase.scheduled);
      expect(nextDay.shouldRun, isTrue);
    });

    test('automatic run needs saved credentials and a bound account', () {
      final noCredential = planYoungDailySync(
        _snapshot(credentialSaved: false),
        DateTime.utc(2026, 10, 14, 22),
      );
      expect(noCredential.phase, YoungDailySyncPhase.needsLogin);
      expect(noCredential.shouldRun, isFalse);

      final noAccount = planYoungDailySync(
        _snapshot(accountBound: false),
        DateTime.utc(2026, 10, 14, 22),
        manual: true,
      );
      expect(noAccount.phase, YoungDailySyncPhase.needsLogin);
      expect(noAccount.shouldRun, isFalse);
    });

    test('disabled and advice-only settings independently block auto runs', () {
      final disabled = planYoungDailySync(
        _snapshot(enabled: false),
        DateTime.utc(2026, 10, 14, 22),
      );
      expect(disabled.phase, YoungDailySyncPhase.disabled);
      expect(disabled.shouldRun, isFalse);

      final adviceOnly = planYoungDailySync(
        _snapshot(adviceOnly: true),
        DateTime.utc(2026, 10, 14, 22),
      );
      expect(adviceOnly.phase, YoungDailySyncPhase.paused);
      expect(adviceOnly.shouldRun, isFalse);
    });

    test('today suppression pauses automatic sync and expires next day', () {
      final suppressed = planYoungDailySync(
        _snapshot(suppressedDay: DateTime.utc(2026, 10, 15)),
        DateTime.utc(2026, 10, 15, 4),
      );
      expect(suppressed.phase, YoungDailySyncPhase.paused);
      expect(suppressed.shouldRun, isFalse);

      final previousDaySuppression = planYoungDailySync(
        _snapshot(suppressedDay: DateTime.utc(2026, 10, 14)),
        DateTime.utc(2026, 10, 15, 4),
      );
      expect(previousDaySuppression.shouldRun, isTrue);

      final clearedSuppression = planYoungDailySync(
        _snapshot(suppressedDay: null),
        DateTime.utc(2026, 10, 15, 4),
      );
      expect(clearedSuppression.shouldRun, isTrue);

      final manual = planYoungDailySync(
        _snapshot(suppressedDay: DateTime.utc(2026, 10, 15)),
        DateTime.utc(2026, 10, 15, 4),
        manual: true,
      );
      expect(manual.phase, YoungDailySyncPhase.scheduled);
      expect(manual.shouldRun, isTrue);
    });

    test('rejects every non-UTC date or instant input', () {
      final localNow = DateTime(2026, 10, 15, 12);
      expect(
        () => planYoungDailySync(_snapshot(), localNow),
        throwsArgumentError,
      );
      final localValue = DateTime(2026, 10, 15);
      final snapshots = <YoungDailySyncSnapshot>[
        _snapshot(lastSuccessAtUtc: localValue),
        _snapshot(successFirstDay: localValue),
        _snapshot(successEndDayExclusive: localValue),
        _snapshot(attemptDay: localValue),
        _snapshot(nextAttemptAtUtc: localValue),
        _snapshot(suppressedDay: localValue),
      ];
      for (final snapshot in snapshots) {
        expect(
          () => planYoungDailySync(snapshot, DateTime.utc(2026, 10, 15, 4)),
          throwsArgumentError,
        );
      }
    });
  });
}

YoungDailySyncSnapshot _snapshot({
  bool enabled = true,
  bool accountBound = true,
  bool credentialSaved = true,
  bool adviceOnly = false,
  DateTime? lastSuccessAtUtc,
  DateTime? successFirstDay,
  DateTime? successEndDayExclusive,
  DateTime? attemptDay,
  int attempts = 0,
  DateTime? nextAttemptAtUtc,
  bool needsLogin = false,
  DateTime? suppressedDay,
}) => YoungDailySyncSnapshot(
  context: const YoungDailySyncContext(
    owner: 'synthetic-owner',
    resetEpoch: 1,
    agendaEpoch: 1,
    revision: 1,
  ),
  enabled: enabled,
  accountBound: accountBound,
  credentialSaved: credentialSaved,
  adviceOnly: adviceOnly,
  lastSuccessAtUtc: lastSuccessAtUtc,
  successFirstDay: successFirstDay,
  successEndDayExclusive: successEndDayExclusive,
  attemptDay: attemptDay,
  attempts: attempts,
  nextAttemptAtUtc: nextAttemptAtUtc,
  needsLogin: needsLogin,
  suppressedDay: suppressedDay,
);
