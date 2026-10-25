import '../core/contracts.dart';
import 'source_contract.dart';

const _maxSyntheticEventCount = 1000;
const _maxSyntheticExternalIdLength = 160;
const _maxSyntheticTitleLength = 160;

/// Validates and seals one complete source snapshot.
///
/// The caller supplies the source's completeness claim and declared count so
/// both are checked at the C1 boundary before an artifact can be created.
CollectionArtifact sealSyntheticSnapshot({
  required JobStamp stamp,
  required DateTime rangeStartUtc,
  required DateTime rangeEndUtc,
  required DateTime collectedAtUtc,
  required bool isComplete,
  required int declaredCount,
  required List<CollectedEvent> events,
}) {
  if (!isComplete) {
    throw const AppFailure(FailureCode.incompleteSnapshot);
  }

  if (declaredCount < 0 ||
      declaredCount != events.length ||
      events.length > _maxSyntheticEventCount ||
      !rangeStartUtc.isUtc ||
      !rangeEndUtc.isUtc ||
      !collectedAtUtc.isUtc ||
      !rangeStartUtc.isBefore(rangeEndUtc)) {
    throw const AppFailure(FailureCode.invalidSnapshot);
  }

  final externalIds = <String>{};
  for (final event in events) {
    final externalId = event.externalId;
    final title = event.title;
    if (!event.startsAtUtc.isUtc ||
        !event.endsAtUtc.isUtc ||
        event.startsAtUtc.isBefore(rangeStartUtc) ||
        !event.startsAtUtc.isBefore(rangeEndUtc) ||
        !event.startsAtUtc.isBefore(event.endsAtUtc) ||
        externalId.trim().isEmpty ||
        externalId.length > _maxSyntheticExternalIdLength ||
        title.trim().isEmpty ||
        title.length > _maxSyntheticTitleLength ||
        !externalIds.add(externalId)) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
  }

  return CollectionArtifact(
    stamp: stamp,
    rangeStartUtc: rangeStartUtc,
    rangeEndUtc: rangeEndUtc,
    collectedAtUtc: collectedAtUtc,
    events: events,
  );
}

/// A deterministic local-only source for the M0 walking skeleton.
final class SyntheticSource implements SourcePort {
  SyntheticSource({
    this.clock = const SystemClock(),
    this.delay = const Duration(milliseconds: 450),
    this.beforeSeal,
  });

  final AppClock clock;
  final Duration delay;
  final Future<void> Function()? beforeSeal;

  @override
  Future<SourceSession> open(JobStamp stamp, DemoScenario scenario) async {
    if (stamp.sourceKey != syntheticSourceKey ||
        stamp.contractVersion != syntheticContractVersion) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    return _SyntheticSession(
      stamp: stamp,
      scenario: scenario,
      clock: clock,
      delay: delay,
      beforeSeal: beforeSeal,
    );
  }
}

final class _SyntheticSession implements SourceSession {
  _SyntheticSession({
    required this.stamp,
    required this.scenario,
    required this.clock,
    required this.delay,
    required this.beforeSeal,
  });

  final JobStamp stamp;
  final DemoScenario scenario;
  final AppClock clock;
  final Duration delay;
  final Future<void> Function()? beforeSeal;

  bool _collectStarted = false;
  bool _closeRequested = false;
  bool _closed = false;
  bool _cleanupFailureRaised = false;

  @override
  Future<CollectionArtifact> collect() async {
    if (_closed || _closeRequested) {
      throw const AppFailure(FailureCode.closed);
    }
    if (_collectStarted) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    _collectStarted = true;

    if (scenario == DemoScenario.incomplete) {
      throw const AppFailure(FailureCode.incompleteSnapshot);
    }
    if (scenario == DemoScenario.sourceFailure) {
      throw const AppFailure(FailureCode.sourceFailed);
    }

    DateTime nowUtc;
    try {
      nowUtc = clock.nowUtc.toUtc();
    } catch (_) {
      throw const AppFailure(FailureCode.sourceFailed);
    }

    final week = _beijingWeek(nowUtc);
    final events = switch (scenario) {
      DemoScenario.normal ||
      DemoScenario.replay ||
      DemoScenario.storageFailure ||
      DemoScenario.followUpFailure ||
      DemoScenario.cleanupFailure => _eventsForWeek(week),
      DemoScenario.empty => <CollectedEvent>[],
      DemoScenario.incomplete || DemoScenario.sourceFailure =>
        throw const AppFailure(FailureCode.sourceFailed),
    };

    await Future<void>.delayed(delay);
    if (_closed || _closeRequested) {
      throw const AppFailure(FailureCode.closed);
    }

    final sealHook = beforeSeal;
    if (sealHook != null) {
      try {
        await sealHook();
      } catch (_) {
        throw const AppFailure(FailureCode.sourceFailed);
      }
    }
    if (_closed || _closeRequested) {
      throw const AppFailure(FailureCode.closed);
    }

    return sealSyntheticSnapshot(
      stamp: stamp,
      rangeStartUtc: week.rangeStartUtc,
      rangeEndUtc: week.rangeEndUtc,
      collectedAtUtc: nowUtc,
      isComplete: true,
      declaredCount: events.length,
      events: events,
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;

    if (scenario == DemoScenario.cleanupFailure && !_cleanupFailureRaised) {
      _cleanupFailureRaised = true;
      _closeRequested = true;
      throw const AppFailure(FailureCode.cleanupPending);
    }

    _closeRequested = true;
    _closed = true;
  }
}

final class _BeijingWeek {
  const _BeijingWeek({
    required this.mondayBeijing,
    required this.rangeStartUtc,
    required this.rangeEndUtc,
  });

  final DateTime mondayBeijing;
  final DateTime rangeStartUtc;
  final DateTime rangeEndUtc;

  String get identifier =>
      '${mondayBeijing.year.toString().padLeft(4, '0')}'
      '${mondayBeijing.month.toString().padLeft(2, '0')}'
      '${mondayBeijing.day.toString().padLeft(2, '0')}';
}

_BeijingWeek _beijingWeek(DateTime nowUtc) {
  final beijingNow = nowUtc.toUtc().add(const Duration(hours: 8));
  final mondayBeijing = DateTime.utc(
    beijingNow.year,
    beijingNow.month,
    beijingNow.day,
  ).subtract(Duration(days: beijingNow.weekday - DateTime.monday));
  final rangeStartUtc = mondayBeijing.subtract(const Duration(hours: 8));
  return _BeijingWeek(
    mondayBeijing: mondayBeijing,
    rangeStartUtc: rangeStartUtc,
    rangeEndUtc: rangeStartUtc.add(const Duration(days: 7)),
  );
}

List<CollectedEvent> _eventsForWeek(_BeijingWeek week) {
  final id = week.identifier;
  final mondayCourseStart = week.rangeStartUtc.add(const Duration(hours: 9));
  final wednesdayExamStart = week.rangeStartUtc.add(
    const Duration(days: 2, hours: 14),
  );
  final fridayCourseStart = week.rangeStartUtc.add(
    const Duration(days: 4, hours: 9),
  );

  return [
    CollectedEvent(
      externalId: 'synthetic-course-$id-01',
      title: '合成课程：线性代数',
      startsAtUtc: mondayCourseStart,
      endsAtUtc: mondayCourseStart.add(const Duration(minutes: 90)),
    ),
    CollectedEvent(
      externalId: 'synthetic-exam-$id-01',
      title: '合成考试：离散数学',
      startsAtUtc: wednesdayExamStart,
      endsAtUtc: wednesdayExamStart.add(const Duration(hours: 2)),
    ),
    CollectedEvent(
      externalId: 'synthetic-course-$id-02',
      title: '合成课程：计算机系统基础',
      startsAtUtc: fridayCourseStart,
      endsAtUtc: fridayCourseStart.add(const Duration(minutes: 90)),
    ),
  ];
}
