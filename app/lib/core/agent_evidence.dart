import 'agent_contract.dart';
import 'agent_text.dart';

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
};

Map<String, Object?> agentEvidenceToMap(AgentEvidence value) {
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
  };
}

AgentEvidence agentEvidenceFromMap(Object? value) {
  try {
    if (value is! Map<String, dynamic> || value.length != 15) {
      throw const AgentFailure(AgentFailureCode.storageFailed);
    }
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
    );
    agentEvidenceToMap(result);
    return result;
  } catch (_) {
    throw const AgentFailure(AgentFailureCode.storageFailed);
  }
}

Map<String, Object?> agentStepToMap(AgentToolStep value) {
  if (!agentReadToolNames.contains(value.tool) ||
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
