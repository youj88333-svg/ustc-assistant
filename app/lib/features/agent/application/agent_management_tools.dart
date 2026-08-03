import '../../schedule/application/conflict_service.dart';
import '../../schedule/application/schedule_conflict_projection.dart';
import '../../schedule/domain/schedule_grid_item.dart';
import '../domain/agent_tool.dart';
import 'agent_local_data_gateway.dart';

/// The run-local reference kinds a `ref_target` may resolve to for the
/// management read tools. Note the RunReferenceStore binds events as `event`,
/// tasks as `task`, and plan blocks as `planblock`.
const Set<String> _managedTargetKinds = {'event', 'task', 'planblock'};

/// The conflict-participant kinds accepted by `get_schedule_relations`
/// `ref_left`/`ref_right`. These use the storage convention (`event`,
/// `plan_block`) matching `schedule_relations` rows.
const Set<String> _relationLeftKinds = {'event', 'planblock'};

// ===========================================================================
// Tool: get_schedule_relations
// ===========================================================================

/// Lists the account's `source=user` explicit conflict relations and series
/// rules that involve a given participant, so the model can inspect what a
/// later `delete_schedule_relation` would remove and what would take over.
///
/// Derived overlaps are not stored relations and therefore never get a
/// `ref_relation`; `exam_for_course` (imported, source != user) relations are
/// never returned.
class GetScheduleRelationsTool implements AgentTool {
  const GetScheduleRelationsTool(this._gateway);

  final AgentLocalDataGateway _gateway;

  @override
  String get name => 'get_schedule_relations';

  @override
  String get description =>
      'List the explicit user-scheduled conflict relations involving an event '
      'or plan-block participant: occurrence relations and series rules. Each '
      'returns a run-local ref_relation, the conflict state, the low-sensitivity '
      'reason, the valid date window, and the predicted state after deleting '
      'that relation (series rule, derived overlap, or no conflict). Derived '
      'timed overlaps have no relation row and are never listed; imported '
      'exam_for_course relations are never listed.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'ref_left': {
            'type': 'string',
            'description': 'Required run-local ref of the participant to '
                'inspect (bound as an event or plan-block).',
          },
          'ref_right': {
            'type': 'string',
            'description': 'Optional run-local ref of a second participant; '
                'when given, only relations BETWEEN the two are returned.',
          },
        },
        'required': ['ref_left'],
        'additionalProperties': false,
      };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    final refLeft = arguments['ref_left'] as String?;
    final refRight = arguments['ref_right'] as String?;
    if (refLeft == null) {
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'invalid_arguments',
      );
    }
    final leftTarget = context.references.resolveTarget(
      refLeft,
      allowedKinds: _relationLeftKinds,
    );
    if (leftTarget == null) {
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'reference_not_found',
      );
    }
    _Participant? left =
        await _participantFor(context, leftTarget.kind, leftTarget.localId);
    if (left == null) {
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'reference_not_found',
      );
    }

    // Optional right participant constrains the pair to left<->right.
    _Participant? right;
    if (refRight != null) {
      final rightTarget = context.references.resolveTarget(
        refRight,
        allowedKinds: _relationLeftKinds,
      );
      if (rightTarget == null) {
        return const AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'reference_not_found',
        );
      }
      right =
          await _participantFor(context, rightTarget.kind, rightTarget.localId);
      if (right == null) {
        return const AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'reference_not_found',
        );
      }
    }

    final participant = left.participant;
    final occurrenceRows =
        await _gateway.userConflictRelationsFor(context.accountId, participant);
    final ruleRows =
        await _gateway.userConflictRulesFor(context.accountId, participant);

    final references = <AgentToolReference>[];
    final relationDtos = <Map<String, Object?>>[];

    // Occurrence relations involving the participant.
    for (final row in occurrenceRows) {
      final partnerKind = row.leftKind == participant.kind &&
              row.leftId == participant.id
          ? row.rightKind
          : row.leftKind;
      final partnerId = row.leftKind == participant.kind &&
              row.leftId == participant.id
          ? row.rightId
          : row.leftId;
      if (partnerKind == null || partnerId == null) continue;
      // Constrain to ref_right when given.
      if (right != null &&
          !(partnerKind == right.participant.kind &&
              partnerId == right.participant.id)) {
        continue;
      }
      final partner = await _participantFor(context, partnerKind, partnerId);
      if (partner == null) continue;
      final occurrenceKey = ScheduleConflictProjection.occurrenceKey(
        participant.kind,
        participant.id,
        partner.participant.kind,
        partner.participant.id,
      );
      final ref = context.references.bind(
        kind: 'schedule_relation',
        localId: row.id,
      );
      final fallback = await _occurrenceFallback(
        context,
        left,
        partner,
        occurrenceKey,
      );
      relationDtos.add(
        _occurrenceRelationDto(
          ref,
          left,
          partner,
          conflictState: row.conflictState ?? 'no_conflict',
          reason: row.reason,
          fallback: fallback,
        ),
      );
      references.add(
        AgentToolReference(
          kind: 'schedule_relation',
          ref: ref,
          localId: row.id,
        ),
      );
    }

    // Series rules involving the participant's series.
    for (final rule in ruleRows) {
      final isLeftSeries = rule.leftSeriesType == (left.participant.seriesType ?? '') &&
          rule.leftSeriesId == (left.participant.seriesId ?? '');
      // Only rules where left's series is one side (rules already filtered by
      // the gateway to involve left's series).
      final rightSeriesType = isLeftSeries
          ? rule.rightSeriesType
          : rule.leftSeriesType;
      final rightSeriesId = isLeftSeries ? rule.rightSeriesId : rule.leftSeriesId;
      final ref = context.references.bind(
        kind: 'schedule_relation_rule',
        localId: rule.id,
      );
      final fallback = await _seriesFallback(context, left);
      relationDtos.add(
        _seriesRuleDto(
          ref,
          left,
          partnerSeriesType: rightSeriesType,
          partnerSeriesId: rightSeriesId,
          conflictState: rule.conflictState,
          reason: rule.reason,
          validFrom: rule.effectiveFrom,
          validThrough: rule.effectiveThrough,
          fallback: fallback,
        ),
      );
      references.add(
        AgentToolReference(
          kind: 'schedule_relation_rule',
          ref: ref,
          localId: rule.id,
        ),
      );
    }

    return AgentToolResult(
      payload: {
        'relations': relationDtos,
        'ref_left': refLeft,
        'ref_right': ?refRight,
      },
      references: references,
    );
  }

  Future<_Participant?> _participantFor(
    AgentToolContext context,
    String kind,
    String localId,
  ) async {
    // Convert a run-reference kind ('planblock') to the storage kind used by
    // the conflict participant ('plan_block').
    final storageKind = _storageKind(kind);
    final item = await _gateway.gridItemForParticipant(
      context.accountId,
      ScheduleConflictParticipant(
        kind: storageKind,
        id: localId,
        title: '',
        occurrenceDate: DateTime(1970),
      ),
    );
    if (item == null) return null;
    return _Participant(
      kind: kind,
      participant: _participantFromItem(item, storageKind),
    );
  }

  Future<String> _occurrenceFallback(
    AgentToolContext context,
    _Participant left,
    _Participant partner,
    String occurrenceKey,
  ) async {
    final resolved = await _gateway.resolvePairIgnoringOccurrence(
      context.accountId,
      left.participant,
      partner.participant,
      occurrenceKey,
    );
    return _fallbackLabel(resolved);
  }

  Future<String> _seriesFallback(
    AgentToolContext context,
    _Participant left,
  ) async {
    // A series-rule deletion preview needs two series participants, but the
    // rule's partner may not be a resolvable participant. Fall back to a
    // conservative "derived_overlap" label when we cannot compute an exact
    // pair, which is safe and never over-promises.
    return 'derived_overlap';
  }

  static String _fallbackLabel(ResolvedConflictPair? resolved) {
    if (resolved == null) return 'unclassified';
    return resolved.origin == ConflictPairOrigin.explicitOccurrence ||
            resolved.origin == ConflictPairOrigin.explicitSeries
        ? _stateName(resolved.state)
        : 'derived_overlap';
  }

  static String _stateName(ConflictPairState state) =>
      state == ConflictPairState.conflict ? 'conflict' : 'no_conflict';

  static String _storageKind(String kind) =>
      kind == 'planblock' ? 'plan_block' : kind;

  static ScheduleConflictParticipant _participantFromItem(
    ScheduleGridItem item,
    String storageKind,
  ) {
    final start = item.startAt;
    final occurrenceDate = start != null
        ? DateTime(start.year, start.month, start.day)
        : item.startDate ?? DateTime(1970);
    return ScheduleConflictParticipant(
      kind: storageKind,
      id: item.id,
      title: item.title,
      occurrenceDate: occurrenceDate,
      startAt: start,
      endAt: item.endAt,
      seriesType: item.seriesType,
      seriesId: item.seriesId,
    );
  }

  Map<String, Object?> _occurrenceRelationDto(
    String ref,
    _Participant left,
    _Participant partner, {
    required String conflictState,
    required String? reason,
    required String fallback,
  }) =>
      {
        'ref': ref,
        'scope': 'occurrence',
        'conflictState': conflictState,
        'reason': _safeReason(reason),
        'validFrom': _dateOf(left.participant),
        'validThrough': null,
        'fallback': fallback,
        'left': _participantDto(left),
        'right': _participantDto(partner),
      };

  Map<String, Object?> _seriesRuleDto(
    String ref,
    _Participant left, {
    required String partnerSeriesType,
    required String partnerSeriesId,
    required String conflictState,
    required String? reason,
    required String? validFrom,
    required String? validThrough,
    required String fallback,
  }) =>
      {
        'ref': ref,
        'scope': 'current_and_future',
        'conflictState': conflictState,
        'reason': _safeReason(reason),
        'validFrom': validFrom ?? _dateOf(left.participant),
        'validThrough': validThrough,
        'fallback': fallback,
        'left': _participantDto(left, includeSeries: true),
        'right': {
          'seriesName': _safeSeriesName(partnerSeriesType, partnerSeriesId),
          'recurring': true,
        },
      };
}

// ===========================================================================
// Tool: get_reminders
// ===========================================================================

/// Returns a target's Reminder configuration: future desired offsets, whether
/// an explicit-disable marker is present, and the delivered/missed/failed
/// history counts. Never exposes a Reminder DB id.
class GetRemindersTool implements AgentTool {
  const GetRemindersTool(this._gateway);

  final AgentLocalDataGateway _gateway;

  @override
  String get name => 'get_reminders';

  @override
  String get description =>
      'Returns the reminder configuration for one event, task, or plan block: '
      'the future desired offsets (minutes before start), whether the target '
      'has an explicit disable marker, and the delivered/missed/failed history '
      'counts. Existing reminder rows are read; no Reminder database id is '
      'returned.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'ref_target': {
            'type': 'string',
            'description': 'Required run-local ref of the event, task, or '
                'plan block whose reminders to inspect.',
          },
        },
        'required': ['ref_target'],
        'additionalProperties': false,
      };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    final refTarget = arguments['ref_target'] as String?;
    if (refTarget == null) {
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'invalid_arguments',
      );
    }
    final target = context.references.resolveTarget(
      refTarget,
      allowedKinds: _managedTargetKinds,
    );
    if (target == null) {
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'reference_not_found',
      );
    }
    final storageType = switch (target.kind) {
      'planblock' => 'plan_block',
      _ => target.kind,
    };
    final config = await _gateway.reminderConfiguration(
      context.accountId,
      targetType: storageType,
      targetId: target.localId,
    );
    return AgentToolResult(payload: {
      'ref': refTarget,
      'targetType': target.kind,
      'desiredOffsets': config.futureDesiredOffsets,
      'explicitDisabled': config.hasExplicitDisable,
      'deliveredCount': config.deliveredCount,
      'missedCount': config.missedCount,
      'failedCount': config.failedCount,
    });
  }
}

// ===========================================================================
// Tool: get_user_overlay
// ===========================================================================

/// Returns the two explicit overlay layers for an event (single_event and
/// course_series) plus what the effective value would be after clearing each
/// layer. Never returns just the merged EffectiveEvent value, so the model can
/// tell which layer owns each field.
class GetUserOverlayTool implements AgentTool {
  const GetUserOverlayTool(this._gateway);

  final AgentLocalDataGateway _gateway;

  @override
  String get name => 'get_user_overlay';

  @override
  String get description =>
      'Returns the explicit overlay layers set on an event: the single_event '
      'layer and the course_series layer, each with only the fields explicitly '
      'set on that layer. Also previews the effective field values after '
      'clearing each layer alone, so the model can tell which layer owns a '
      'field and what would take over.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'ref_event': {
            'type': 'string',
            'description': 'Required run-local event ref whose overlay to '
                'inspect.',
          },
        },
        'required': ['ref_event'],
        'additionalProperties': false,
      };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    final refEvent = arguments['ref_event'] as String?;
    if (refEvent == null) {
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'invalid_arguments',
      );
    }
    final event = context.references.resolveTarget(
      refEvent,
      allowedKinds: const {'event'},
    );
    if (event == null) {
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'reference_not_found',
      );
    }
    final layers =
        await _gateway.eventOverlayLayers(context.accountId, event.localId);
    return AgentToolResult(payload: {
      'ref': refEvent,
      'singleEvent': layers.singleEvent,
      'courseSeries': layers.courseSeries,
      'afterClearingSingle': layers.afterClearingSingle,
      'afterClearingSeries': layers.afterClearingSeries,
      'hasSingleEventLayer': layers.hasSingleEventLayer,
      'hasCourseSeriesLayer': layers.hasCourseSeriesLayer,
    });
  }
}

// ===========================================================================
// Shared helpers
// ===========================================================================

/// A resolved participant plus the run-reference kind it came from.
class _Participant {
  const _Participant({required this.kind, required this.participant});

  final String kind;
  final ScheduleConflictParticipant participant;
}

String _safeReason(String? reason) => reason == null || reason.isEmpty
    ? 'no explicit reason'
    : reason;

String _dateOf(ScheduleConflictParticipant p) {
  final d = p.occurrenceDate;
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

String _safeSeriesName(String seriesType, String seriesId) {
  // Only the series type is a safe, low-sensitivity hint; the series id is an
  // internal identity and is never surfaced. A rule partner without a
  // resolvable grid item shows a generic recurring label.
  if (seriesType == 'course_series') return 'a course series';
  if (seriesType == 'calendar_event_series') return 'a recurring personal series';
  return 'a series';
}

Map<String, Object?> _participantDto(
  _Participant p, {
  bool includeSeries = false,
}) {
  final item = p.participant;
  final dto = <String, Object?>{
    'kind': p.kind,
    'title': item.title,
  };
  final startAt = item.startAt;
  if (startAt != null) {
    dto['startAt'] = _fmtDateTime(startAt);
    if (item.endAt != null) dto['endAt'] = _fmtDateTime(item.endAt!);
  } else if (item.occurrenceDate.year != 1970) {
    dto['startDate'] = _dateOf(item);
  }
  if (includeSeries && item.seriesType != null) {
    dto['recurring'] = true;
  }
  return dto;
}

String _fmtDateTime(DateTime value) => value.toIso8601String().substring(0, 19);