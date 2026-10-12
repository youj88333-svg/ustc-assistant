import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/source/source_contract.dart';
import 'package:ustc_assistant_m0/source/synthetic_source.dart';

void main() {
  test('open enforces the synthetic source and contract identity', () async {
    final source = SyntheticSource(delay: Duration.zero);

    await _expectFailure(
      source.open(_stamp(sourceKey: 'another-source'), DemoScenario.normal),
      FailureCode.invalidSnapshot,
    );
    await _expectFailure(
      source.open(_stamp(contractVersion: 'old-contract'), DemoScenario.normal),
      FailureCode.invalidSnapshot,
    );
  });

  test(
    'uses explicit Beijing Monday boundaries and deterministic records',
    () async {
      final beforeBoundary = await _collectAt(
        DateTime.utc(2026, 10, 11, 15, 59),
        stamp: _stamp(jobId: 'job-before', generation: 1),
      );
      final atBoundary = await _collectAt(
        DateTime.utc(2026, 10, 11, 16),
        stamp: _stamp(jobId: 'job-at', generation: 8, resetEpoch: 2),
      );
      final sameWeek = await _collectAt(
        DateTime.utc(2026, 10, 8, 3),
        stamp: _stamp(jobId: 'job-same-week', generation: 3),
      );

      expect(beforeBoundary.rangeStartUtc, DateTime.utc(2026, 10, 4, 16));
      expect(beforeBoundary.rangeEndUtc, DateTime.utc(2026, 10, 11, 16));
      expect(atBoundary.rangeStartUtc, DateTime.utc(2026, 10, 11, 16));
      expect(atBoundary.rangeEndUtc, DateTime.utc(2026, 10, 18, 16));
      expect(beforeBoundary.events, hasLength(3));
      expect(beforeBoundary.events.map((event) => event.externalId), [
        'synthetic-course-20261005-01',
        'synthetic-exam-20261005-01',
        'synthetic-course-20261005-02',
      ]);
      expect(
        beforeBoundary.events.map((event) => event.title),
        everyElement(contains('合成')),
      );
      expect(
        beforeBoundary.events.every(
          (event) => event.startsAtUtc.isUtc && event.endsAtUtc.isUtc,
        ),
        isTrue,
      );
      expect(
        beforeBoundary.events.first.startsAtUtc,
        DateTime.utc(2026, 10, 5, 1),
      );
      expect(
        beforeBoundary.events[1].startsAtUtc,
        DateTime.utc(2026, 10, 7, 6),
      );
      expect(
        beforeBoundary.events[2].startsAtUtc,
        DateTime.utc(2026, 10, 9, 1),
      );
      expect(sameWeek.contentFingerprint, beforeBoundary.contentFingerprint);
      expect(
        atBoundary.contentFingerprint,
        isNot(beforeBoundary.contentFingerprint),
      );
    },
  );

  test(
    'complete empty snapshots seal while incomplete and source failures do not',
    () async {
      final source = SyntheticSource(
        clock: FixedClock(DateTime.utc(2026, 10, 6)),
        delay: Duration.zero,
      );
      final emptySession = await source.open(_stamp(), DemoScenario.empty);
      final empty = await emptySession.collect();
      expect(empty.events, isEmpty);
      await emptySession.close();

      final incompleteSession = await source.open(
        _stamp(jobId: 'incomplete'),
        DemoScenario.incomplete,
      );
      await _expectFailure(
        incompleteSession.collect(),
        FailureCode.incompleteSnapshot,
      );

      final failedSession = await source.open(
        _stamp(jobId: 'failed'),
        DemoScenario.sourceFailure,
      );
      await _expectFailure(failedSession.collect(), FailureCode.sourceFailed);
    },
  );

  test(
    'downstream failure and replay scenarios retain the fixed source records',
    () async {
      for (final scenario in [
        DemoScenario.replay,
        DemoScenario.storageFailure,
        DemoScenario.followUpFailure,
      ]) {
        final session = await SyntheticSource(
          clock: FixedClock(DateTime.utc(2026, 10, 6)),
          delay: Duration.zero,
        ).open(_stamp(jobId: scenario.name), scenario);
        final artifact = await session.collect();
        expect(artifact.events, hasLength(3));
        expect(
          artifact.events.first.externalId,
          'synthetic-course-20261005-01',
        );
        await session.close();
      }
    },
  );

  test(
    'sealing rejects duplicate identities, invalid times, and count mismatch',
    () {
      final start = DateTime.utc(2026, 10, 4, 16);
      final end = start.add(const Duration(days: 7));
      final event = _event(
        id: 'duplicate',
        start: DateTime.utc(2026, 10, 5, 1),
        finish: DateTime.utc(2026, 10, 5, 2),
      );

      expect(
        () => _seal(rangeStart: start, rangeEnd: end, events: [event, event]),
        _throwsCode(FailureCode.invalidSnapshot),
      );
      expect(
        () => _seal(
          rangeStart: start,
          rangeEnd: end,
          events: [
            _event(
              id: 'local-time',
              start: DateTime(2026, 10, 5, 9),
              finish: DateTime(2026, 10, 5, 10),
            ),
          ],
        ),
        _throwsCode(FailureCode.invalidSnapshot),
      );
      expect(
        () => _seal(
          rangeStart: start,
          rangeEnd: end,
          events: [
            _event(
              id: 'zero-duration',
              start: DateTime.utc(2026, 10, 5, 1),
              finish: DateTime.utc(2026, 10, 5, 1),
            ),
          ],
        ),
        _throwsCode(FailureCode.invalidSnapshot),
      );
      expect(
        () => _seal(
          rangeStart: start,
          rangeEnd: end,
          events: [event],
          declaredCount: 2,
        ),
        _throwsCode(FailureCode.invalidSnapshot),
      );
    },
  );

  test(
    'sealed events are copied and cannot be changed through the input list',
    () {
      final sourceEvents = <CollectedEvent>[
        _event(
          id: 'copied',
          start: DateTime.utc(2026, 10, 5, 1),
          finish: DateTime.utc(2026, 10, 5, 2),
        ),
      ];
      final artifact = _seal(
        rangeStart: DateTime.utc(2026, 10, 4, 16),
        rangeEnd: DateTime.utc(2026, 10, 11, 16),
        events: sourceEvents,
      );

      sourceEvents.clear();
      expect(artifact.events, hasLength(1));
      expect(artifact.events.single.externalId, 'copied');
      expect(() => artifact.events.clear(), throwsUnsupportedError);
    },
  );

  test(
    'close preserves a sealed artifact and makes later actions fail',
    () async {
      final session = await SyntheticSource(
        clock: FixedClock(DateTime.utc(2026, 10, 6)),
        delay: Duration.zero,
      ).open(_stamp(), DemoScenario.normal);
      final artifact = await session.collect();
      final fingerprintBeforeClose = artifact.contentFingerprint;

      await session.close();
      await session.close();
      expect(artifact.events, hasLength(3));
      expect(artifact.contentFingerprint, fingerprintBeforeClose);
      await _expectFailure(session.collect(), FailureCode.closed);
    },
  );

  test(
    'a closed waiting session cannot seal late after a new session opens',
    () async {
      final enteredSeal = Completer<void>();
      final releaseSeal = Completer<void>();
      final oldSession = await SyntheticSource(
        clock: FixedClock(DateTime.utc(2026, 10, 6)),
        delay: Duration.zero,
        beforeSeal: () {
          enteredSeal.complete();
          return releaseSeal.future;
        },
      ).open(_stamp(jobId: 'old-session'), DemoScenario.normal);

      final pendingCollection = oldSession.collect();
      await enteredSeal.future;
      await oldSession.close();
      final newSession = await SyntheticSource(
        clock: FixedClock(DateTime.utc(2026, 10, 6)),
        delay: Duration.zero,
      ).open(_stamp(jobId: 'new-session'), DemoScenario.normal);

      releaseSeal.complete();
      await _expectFailure(pendingCollection, FailureCode.closed);
      expect((await newSession.collect()).events, hasLength(3));
      await newSession.close();
    },
  );

  test('cleanup failure can be retried and then closes idempotently', () async {
    final session = await SyntheticSource(
      clock: FixedClock(DateTime.utc(2026, 10, 6)),
      delay: Duration.zero,
    ).open(_stamp(), DemoScenario.cleanupFailure);
    final artifact = await session.collect();

    await _expectFailure(session.close(), FailureCode.cleanupPending);
    await session.close();
    await session.close();
    expect(artifact.events, hasLength(3));
    await _expectFailure(session.collect(), FailureCode.closed);
  });
}

JobStamp _stamp({
  String jobId = 'job',
  String sourceKey = syntheticSourceKey,
  String contractVersion = syntheticContractVersion,
  int generation = 1,
  int resetEpoch = 1,
}) => JobStamp(
  jobId: jobId,
  localContext: 'demo-context',
  sourceKey: sourceKey,
  contractVersion: contractVersion,
  generation: generation,
  resetEpoch: resetEpoch,
);

Future<CollectionArtifact> _collectAt(
  DateTime nowUtc, {
  required JobStamp stamp,
}) async {
  final session = await SyntheticSource(
    clock: FixedClock(nowUtc),
    delay: Duration.zero,
  ).open(stamp, DemoScenario.normal);
  final artifact = await session.collect();
  await session.close();
  return artifact;
}

CollectedEvent _event({
  required String id,
  required DateTime start,
  required DateTime finish,
}) => CollectedEvent(
  externalId: id,
  title: '合成测试事件',
  startsAtUtc: start,
  endsAtUtc: finish,
);

CollectionArtifact _seal({
  required DateTime rangeStart,
  required DateTime rangeEnd,
  required List<CollectedEvent> events,
  int? declaredCount,
}) => sealSyntheticSnapshot(
  stamp: _stamp(),
  rangeStartUtc: rangeStart,
  rangeEndUtc: rangeEnd,
  collectedAtUtc: DateTime.utc(2026, 10, 6),
  isComplete: true,
  declaredCount: declaredCount ?? events.length,
  events: events,
);

Future<void> _expectFailure(Future<dynamic> operation, FailureCode code) async {
  await expectLater(operation, _throwsCode(code));
}

Matcher _throwsCode(FailureCode code) => throwsA(
  isA<AppFailure>().having((failure) => failure.code, 'failure code', code),
);
