import 'agent_contract.dart';
import 'agent_text.dart';
import 'calendar_contract.dart';

const agentReadToolNames = {
  'query_agenda',
  'read_event',
  'query_tasks',
  'read_task',
  'inspect_conflicts',
  'search_knowledge',
  'read_knowledge',
  'search_courses',
  'read_course',
  'read_reviews',
  'browse_campus',
  'read_campus_article',
};
const agentRegisteredToolNames = {
  ...agentReadToolNames,
  'propose_local_changes',
  'propose_undo',
  'find_free_slots',
  'query_source_options',
  'request_source_refresh',
  'query_young_activities',
  'propose_planning_preferences',
};
const agentToolStatuses = {
  'success',
  'empty',
  'partial',
  'busy',
  'consentRequired',
  'unavailable',
  'accessRestricted',
  'stale',
  'cancelled',
  'resourceLimit',
  'failure',
  'executing',
  'invalidRequest',
  'secretDetected',
  'waitingForApproval',
  'waitingForSchool',
  'committed',
  'rejected',
};

Map<String, Object?> agentEvidenceToMap(AgentEvidence value) {
  final navigation = _localNavigation(value);
  if (!RegExp(r'^e_[a-f0-9]{16,48}$').hasMatch(value.id) ||
      !const {
        'local',
        'icourse',
        'teach',
        'finance',
      }.contains(value.provider) ||
      value.title.trim().isEmpty ||
      !value.observedAtUtc.isUtc ||
      value.applicability != 'unknown') {
    throw const AgentFailure(AgentFailureCode.invalidInput);
  }
  AgentText.requireSafe(value.title, maxCharacters: 500);
  AgentText.requireSafe(value.scope, maxCharacters: 500);
  AgentText.requireSafe(value.snippet, maxCharacters: 400);
  for (final text in [
    value.publishedOn,
    value.updatedOn,
    value.revision,
    value.locator,
    value.sourceVersion,
  ]) {
    if (text != null) AgentText.requireSafe(text, maxCharacters: 500);
  }
  for (final text in [value.articleUrl, value.materialUrl]) {
    if (text == null) continue;
    AgentText.requireSafe(text, maxCharacters: 2048);
    final uri = Uri.tryParse(text);
    final host = switch (value.provider) {
      'icourse' => 'icourse.club',
      'teach' => 'www.teach.ustc.edu.cn',
      'finance' => 'finance.ustc.edu.cn',
      _ => '',
    };
    if (uri == null ||
        uri.host != host ||
        uri.userInfo.isNotEmpty ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.port != (uri.scheme == 'https' ? 443 : 80)) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
  }
  return {
    'id': value.id,
    'provider': value.provider,
    'title': value.title,
    'observedAtUtc': value.observedAtUtc.toIso8601String(),
    'scope': value.scope,
    'complete': value.complete,
    'articleUrl': value.articleUrl,
    'materialUrl': value.materialUrl,
    'publishedOn': value.publishedOn,
    'updatedOn': value.updatedOn,
    'revision': value.revision,
    'locator': value.locator,
    'sourceVersion': value.sourceVersion,
    'snippet': value.snippet,
    'applicability': value.applicability,
    'localNavigation': ?navigation,
  };
}

AgentEvidence agentEvidenceFromMap(Object? value) {
  try {
    if (value is! Map<String, dynamic> ||
        value.length != 15 &&
            (value.length != 16 || !value.containsKey('localNavigation'))) {
      throw const AgentFailure(AgentFailureCode.storageFailed);
    }
    final navigation = _decodeNavigation(value['localNavigation']);
    final result = AgentEvidence(
      id: value['id'] as String,
      provider: value['provider'] as String,
      title: value['title'] as String,
      observedAtUtc: DateTime.parse(value['observedAtUtc'] as String),
      scope: value['scope'] as String,
      complete: value['complete'] as bool,
      articleUrl: value['articleUrl'] as String?,
      materialUrl: value['materialUrl'] as String?,
      publishedOn: value['publishedOn'] as String?,
      updatedOn: value['updatedOn'] as String?,
      revision: value['revision'] as String?,
      locator: value['locator'] as String?,
      sourceVersion: value['sourceVersion'] as String?,
      snippet: value['snippet'] as String,
      applicability: value['applicability'] as String,
      eventReference: navigation.$1,
      taskReference: navigation.$2,
    );
    agentEvidenceToMap(result);
    return result;
  } catch (_) {
    throw const AgentFailure(AgentFailureCode.storageFailed);
  }
}

List<Object>? _localNavigation(AgentEvidence evidence) {
  if (evidence.eventReference == null && evidence.taskReference == null) {
    return null;
  }
  if (evidence.provider != 'local' ||
      evidence.eventReference != null && evidence.taskReference != null) {
    throw const AgentFailure(AgentFailureCode.invalidInput);
  }
  final encoded = evidence.eventReference != null
      ? <Object>['event', ...evidence.eventReference!.canonical]
      : <Object>['task', ...evidence.taskReference!.canonical];
  _decodeNavigation(encoded);
  return encoded;
}

(CalendarReference?, TaskReference?) _decodeNavigation(Object? value) {
  if (value == null) return (null, null);
  if (value is! List ||
      value.isEmpty ||
      value[0] != 'event' && value[0] != 'task' ||
      value.length != (value[0] == 'event' ? 8 : 6) ||
      value[1] is! String ||
      (value[1] as String).isEmpty) {
    throw const AgentFailure(AgentFailureCode.invalidInput);
  }
  AgentText.requireSafe(value[1] as String, maxCharacters: 256);
  if (value[2] is! int ||
      value[3] is! int ||
      (value[2] as int) < 0 ||
      (value[3] as int) < 0) {
    throw const AgentFailure(AgentFailureCode.invalidInput);
  }
  final context = CalendarContext(
    owner: value[1] as String,
    resetEpoch: value[2] as int,
    agendaEpoch: value[3] as int,
  );
  if (value[0] == 'event') {
    if (value[4] is! String ||
        !CalendarKind.values.any((k) => k.name == value[4]) ||
        value[5] is! int ||
        value[6] is! int ||
        value[7] is! int ||
        (value[5] as int) < 1 ||
        (value[6] as int) < 0 ||
        (value[7] as int) < 1) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    return (
      CalendarReference(
        context,
        CalendarIdentity(
          CalendarKind.values.byName(value[4] as String),
          value[5] as int,
          ordinal: value[6] as int,
        ),
        value[7] as int,
      ),
      null,
    );
  }
  if (value[4] is! int ||
      value[5] is! int ||
      (value[4] as int) < 1 ||
      (value[5] as int) < 1) {
    throw const AgentFailure(AgentFailureCode.invalidInput);
  }
  return (null, TaskReference(context, value[4] as int, value[5] as int));
}

Map<String, Object?> agentStepToMap(AgentToolStep value) {
  if (!agentRegisteredToolNames.contains(value.tool) ||
      !agentToolStatuses.contains(value.status)) {
    throw const AgentFailure(AgentFailureCode.invalidInput);
  }
  return {'tool': value.tool, 'status': value.status};
}

AgentToolStep agentStepFromMap(Object? value) {
  try {
    if (value is! Map<String, dynamic> || value.length != 2) {
      throw const AgentFailure(AgentFailureCode.storageFailed);
    }
    final result = AgentToolStep(
      tool: value['tool'] as String,
      status: value['status'] as String,
    );
    agentStepToMap(result);
    return result;
  } catch (_) {
    throw const AgentFailure(AgentFailureCode.storageFailed);
  }
}
