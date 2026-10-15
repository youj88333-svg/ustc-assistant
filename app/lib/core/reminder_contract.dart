import 'dart:async';

import 'calendar_contract.dart';

enum ReminderKind { course, exam, young, personal, planBlock, taskDeadline }

enum ReminderRuleKind { none, before, dayTime }

enum ReminderFailureCode {
  invalidInput,
  stale,
  maintenance,
  platformUnavailable,
  disabledBySystem,
  publishFailed,
  cancelFailed,
  cleanupPending,
  storageFailed,
  closed,
}

final class ReminderFailure implements Exception {
  const ReminderFailure(this.code);
  final ReminderFailureCode code;
  @override
  String toString() => 'ReminderFailure(${code.name})';
}

final class ReminderRule {
  const ReminderRule.none()
    : kind = ReminderRuleKind.none,
      minutesBefore = 0,
      dayOffset = 0,
      minuteOfDay = 0;
  const ReminderRule.before(this.minutesBefore)
    : kind = ReminderRuleKind.before,
      dayOffset = 0,
      minuteOfDay = 0;
  const ReminderRule.dayTime({this.dayOffset = 0, this.minuteOfDay = 540})
    : kind = ReminderRuleKind.dayTime,
      minutesBefore = 0;
  final ReminderRuleKind kind;
  final int minutesBefore, dayOffset, minuteOfDay;
  List<Object> get canonical => [
    kind.name,
    minutesBefore,
    dayOffset,
    minuteOfDay,
  ];
  void validate({required bool allDay}) {
    if (kind == ReminderRuleKind.before &&
            (allDay || minutesBefore < 0 || minutesBefore > 10080) ||
        kind == ReminderRuleKind.dayTime &&
            (!allDay ||
                dayOffset < -7 ||
                dayOffset > 7 ||
                minuteOfDay < 0 ||
                minuteOfDay > 1439)) {
      throw const ReminderFailure(ReminderFailureCode.invalidInput);
    }
  }

  @override
  String toString() => 'ReminderRule';
}

final class ReminderPair {
  const ReminderPair(this.first, this.second);
  static const timed = ReminderPair(
    ReminderRule.before(30),
    ReminderRule.none(),
  );
  static const allDay = ReminderPair(
    ReminderRule.dayTime(),
    ReminderRule.none(),
  );
  final ReminderRule first, second;
  List<Object> get canonical => [first.canonical, second.canonical];
  bool supports({required bool allDay}) => [first, second].every(
    (rule) =>
        rule.kind == ReminderRuleKind.none ||
        rule.kind ==
            (allDay ? ReminderRuleKind.dayTime : ReminderRuleKind.before),
  );
  void validate({required bool allDay}) {
    first.validate(allDay: allDay);
    second.validate(allDay: allDay);
  }

  @override
  String toString() => 'ReminderPair';
}

final class ReminderTarget {
  const ReminderTarget(
    this.context,
    this.kind,
    this.localId,
    this.ordinal,
    this.version,
  );
  factory ReminderTarget.calendar(CalendarReference reference) =>
      ReminderTarget(
        reference.context,
        ReminderKind.values.byName(reference.identity.kind.name),
        reference.identity.localId,
        reference.identity.ordinal,
        reference.version,
      );
  factory ReminderTarget.task(TaskReference reference) => ReminderTarget(
    reference.context,
    ReminderKind.taskDeadline,
    reference.localId,
    0,
    reference.version,
  );
  final CalendarContext context;
  final ReminderKind kind;
  final int localId, ordinal, version;
  List<Object> get identity => [kind.name, localId, ordinal];
  List<Object> get canonical => [
    context.owner,
    context.resetEpoch,
    context.agendaEpoch,
    ...identity,
    version,
  ];
  @override
  String toString() => 'ReminderTarget';
}

final class ReminderOverride {
  const ReminderOverride({
    required this.kind,
    required this.localId,
    required this.ordinal,
    required this.pair,
  });
  final ReminderKind kind;
  final int localId;

  /// -1 means the personal series; otherwise an exact stable ordinal.
  final int ordinal;
  final ReminderPair pair;
}

final class ReminderPreferences {
  const ReminderPreferences({
    this.enabled = false,
    this.privateDisplay = false,
    this.morningEnabled = false,
    this.timed = ReminderPair.timed,
    this.allDay = ReminderPair.allDay,
  });
  final bool enabled, privateDisplay, morningEnabled;
  final ReminderPair timed, allDay;
  ReminderPreferences copyWith({
    bool? enabled,
    bool? privateDisplay,
    bool? morningEnabled,
    ReminderPair? timed,
    ReminderPair? allDay,
  }) => ReminderPreferences(
    enabled: enabled ?? this.enabled,
    privateDisplay: privateDisplay ?? this.privateDisplay,
    morningEnabled: morningEnabled ?? this.morningEnabled,
    timed: timed ?? this.timed,
    allDay: allDay ?? this.allDay,
  );
}

final class ReminderSettings {
  const ReminderSettings({
    required this.context,
    required this.revision,
    required this.briefEpoch,
    required this.preferences,
  });
  final CalendarContext context;
  final int revision, briefEpoch;
  final ReminderPreferences preferences;
}

final class ReminderDeadline {
  const ReminderDeadline({
    required this.reference,
    required this.title,
    required this.deadlineAtUtc,
    required this.status,
  });
  final TaskReference reference;
  final String title;
  final DateTime deadlineAtUtc;
  final TaskStatus status;
}

final class ReminderInput {
  ReminderInput({
    required this.snapshot,
    required List<ReminderDeadline> deadlines,
    required List<ReminderOverride> overrides,
    required this.preferences,
  }) : deadlines = List.unmodifiable(deadlines),
       overrides = List.unmodifiable(overrides);
  final CalendarSnapshot snapshot;
  final List<ReminderDeadline> deadlines;
  final List<ReminderOverride> overrides;
  final ReminderPreferences preferences;
}

final class ReminderCandidate {
  const ReminderCandidate({
    required this.logicalKey,
    required this.target,
    required this.slot,
    required this.fireAtUtc,
    required this.digest,
    required this.title,
    required this.detail,
    required this.location,
  });
  final String logicalKey, digest, title, detail, location;
  final ReminderTarget target;
  final int slot;
  final DateTime fireAtUtc;
  @override
  String toString() => 'ReminderCandidate';
}

final class ReminderProjectionResult {
  ReminderProjectionResult({
    required List<ReminderCandidate> items,
    required this.complete,
    required this.throughDay,
    required this.candidateCount,
  }) : items = List.unmodifiable(items);
  final List<ReminderCandidate> items;
  final bool complete;
  final DateTime throughDay;
  final int candidateCount;
}

final class NotificationRequest {
  const NotificationRequest({
    required this.id,
    required this.deliveryAtUtc,
    required this.digest,
    required this.token,
    required this.title,
    required this.detail,
    required this.location,
  });
  final String id, digest, token, title, detail, location;
  final DateTime deliveryAtUtc;
  @override
  String toString() => 'NotificationRequest';
}

final class NotificationPending {
  const NotificationPending({
    required this.id,
    required this.deliveryAtUtc,
    required this.digest,
    required this.token,
    this.title,
    this.detail,
    this.location,
  });
  final String id, digest, token;
  final String? title, detail, location;
  final DateTime deliveryAtUtc;
  bool matches(NotificationRequest request) =>
      id == request.id &&
      digest == request.digest &&
      token == request.token &&
      deliveryAtUtc == request.deliveryAtUtc &&
      title == request.title &&
      detail == request.detail &&
      location == request.location;
  @override
  String toString() => 'NotificationPending';
}

final class NotificationActivation {
  const NotificationActivation(this.id, this.digest, this.token);
  final String id, digest, token;
  @override
  String toString() => 'NotificationActivation';
}

final class NotificationCapability {
  const NotificationCapability({
    required this.available,
    required this.enabledBySystem,
    required this.schedulesAfterExit,
    required this.activationAvailable,
  });
  final bool available,
      enabledBySystem,
      schedulesAfterExit,
      activationAvailable;
}

abstract interface class NotificationPlatformPort {
  Stream<NotificationActivation> get activations;
  Future<NotificationCapability> initialize();
  Future<List<NotificationPending>> pending();
  Future<void> schedule(NotificationRequest request);
  Future<void> cancel(String id);
  Future<void> clearOwn();
  Future<void> close();
}

abstract interface class NotificationActivationStatusPort {
  Stream<ReminderFailure> get activationFailures;
}

final class ReminderMapping {
  const ReminderMapping({
    required this.logicalKey,
    required this.target,
    required this.slot,
    required this.request,
    required this.accepted,
  });
  final String logicalKey;
  final ReminderTarget target;
  final int slot;
  final NotificationRequest request;
  final bool accepted;
}

final class ReminderPublication {
  ReminderPublication({
    required this.context,
    required this.revision,
    required this.enabled,
    required List<ReminderMapping> desired,
    required List<ReminderMapping> prior,
    required List<String> invalidPriorIds,
    required this.complete,
    required this.throughDay,
  }) : desired = List.unmodifiable(desired),
       prior = List.unmodifiable(prior),
       invalidPriorIds = List.unmodifiable(invalidPriorIds);
  final CalendarContext context;
  final int revision;
  final bool enabled, complete;
  final List<ReminderMapping> desired, prior;
  final List<String> invalidPriorIds;
  final DateTime throughDay;
}

abstract interface class ReminderDataPort {
  Stream<int> get changes;
  Future<ReminderSettings> inspectReminders();
  Future<void> saveReminderPreferences(
    ReminderSettings expected,
    ReminderPreferences preferences,
  );
  Future<ReminderPair?> readReminderPair(
    ReminderTarget target, {
    bool series = false,
  });
  Future<void> saveReminderPair(
    ReminderTarget target,
    ReminderPair? pair, {
    bool series = false,
  });
  Future<ReminderPublication> prepareReminderPublication();
  Future<bool> reminderPublicationCurrent(ReminderPublication publication);
  Future<void> recordReminderAccepted(
    ReminderPublication publication,
    String id,
  );
  Future<void> recordReminderCancelled(String id);
  Future<ReminderTarget?> resolveNotification(
    NotificationActivation activation,
  );
}

/// The series may have a different time kind from one replaced occurrence.
abstract interface class ReminderTargetShapePort {
  Future<bool> reminderAllDay(ReminderTarget target, {bool series = false});
}

enum ReminderPairOrigin { defaults, series, target }

/// One atomic local read. No native notification identifiers or tokens leave C3.
final class ReminderInspection {
  const ReminderInspection({
    required this.settings,
    required this.target,
    required this.allDay,
    required this.pair,
    required this.origin,
    required this.eligible,
    required this.reason,
    required this.hasTime,
    required this.acceptedSlots,
    this.series = false,
    this.overridePresent = false,
  });
  final ReminderSettings settings;
  final ReminderTarget target;
  final bool allDay, eligible, hasTime;
  final ReminderPair pair;
  final ReminderPairOrigin origin;
  final String reason;
  final List<int> acceptedSlots;

  /// The inspected editing scope, independent of where the effective rule came from.
  final bool series;

  /// Includes a retained override whose time kind currently does not apply.
  final bool overridePresent;
}

abstract interface class ReminderInspectionPort {
  Future<ReminderInspection> inspectReminder(
    ReminderTarget target, {
    bool series = false,
  });
}

/// Manual editors and Agent plans both guard against concurrent reminder edits.
abstract interface class ReminderEditingPort implements ReminderInspectionPort {
  Future<void> saveInspectedReminder(
    ReminderInspection expected,
    ReminderPair? pair,
  );
}

final class ReminderRuntimeView {
  const ReminderRuntimeView({
    this.busy = false,
    this.accepted = 0,
    this.desired = 0,
    this.complete = false,
    this.throughDay,
    this.failure,
    this.capability,
  });
  final bool busy, complete;
  final int accepted, desired;
  final DateTime? throughDay;
  final ReminderFailureCode? failure;
  final NotificationCapability? capability;
}
