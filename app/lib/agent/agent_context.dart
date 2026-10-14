import '../core/agent_contract.dart';
import '../core/agent_text.dart';
import 'model_gateway_contract.dart';

/// Builds bounded, safe conversational history for one model request.
///
/// Plain chat retains complete safe pairs. A tool-backed exchange retains its
/// human request and a fixed control-state projection, never old assistant
/// facts, private tool results, references, arguments, or approval authority.
/// Older pairs are summarized as historical human questions only.
List<ModelChatMessage> buildAgentConversationContext(
  List<AgentMessage> history, {
  int maxPairs = 6,
  int maximumCharacters = 12000,
}) {
  final eligible = <_ConversationPair>[];
  for (var index = 0; index + 1 < history.length;) {
    final user = history[index];
    final assistant = history[index + 1];
    final pair = _projectConversationPair(user, assistant);
    if (pair != null) {
      eligible.add(pair);
      index += 2;
    } else {
      // Do not bridge over a failed/interrupted message. Advancing one item
      // still allows a later, genuinely adjacent user/assistant pair.
      index++;
    }
  }

  final pairLimit = maxPairs < 0 ? 0 : maxPairs;
  final characterLimit = maximumCharacters < 0 ? 0 : maximumCharacters;
  final retainedStart = eligible.length > pairLimit
      ? eligible.length - pairLimit
      : 0;
  final omitted = eligible.take(retainedStart).toList();
  final retained = eligible.skip(retainedStart).toList();

  var pairCharacters = retained.fold<int>(
    0,
    (total, pair) => total + pair.characterCount,
  );
  while (retained.isNotEmpty && pairCharacters > characterLimit) {
    final oldest = retained.removeAt(0);
    pairCharacters -= oldest.characterCount;
    omitted.add(oldest);
  }

  final remainingCharacters = characterLimit - pairCharacters;
  final summary = omitted.isEmpty
      ? null
      : _historicalQuestionSummary(omitted, remainingCharacters);

  return List<ModelChatMessage>.unmodifiable([
    if (summary != null) ModelChatMessage(role: 'user', content: summary),
    for (final pair in retained) ...[
      ModelChatMessage(role: 'user', content: pair.user.text),
      ModelChatMessage(role: 'assistant', content: pair.assistantContext),
    ],
  ]);
}

/// Compression receives user intent and safe plain chat, never prior tool data,
/// action permissions, identifiers, images, or old business evidence.
String buildAgentCompactInput(
  List<AgentMessage> history, {
  String summary = '',
}) {
  final rows = <String>[];
  var used = 0;
  for (final message in history.reversed) {
    if (message.role != AgentMessageRole.user ||
        message.status != AgentMessageStatus.complete ||
        message.imageCount != 0 ||
        !_isSafeHistoryText(message.text)) {
      continue;
    }
    final row = _takeCharacters(message.text.trim(), 1200);
    if (used + row.length > 14000) break;
    rows.add(row);
    used += row.length;
  }
  return [
    if (summary.isNotEmpty && _isSafeHistoryText(summary))
      '旧摘要（仅历史）:\n$summary',
    ...rows.reversed.map((row) => '用户曾说：$row'),
  ].join('\n');
}

String? safeAgentHistoricalSummary(String summary) =>
    summary.trim().isNotEmpty && _isSafeHistoryText(summary) ? summary : null;

_ConversationPair? _projectConversationPair(
  AgentMessage user,
  AgentMessage assistant,
) {
  if (user.role != AgentMessageRole.user ||
      assistant.role != AgentMessageRole.assistant ||
      user.status != AgentMessageStatus.complete ||
      _hasStructuredContent(user) ||
      user.text.trim().isEmpty ||
      !_isSafeHistoryText(user.text)) {
    return null;
  }
  if (_hasStructuredContent(assistant)) {
    final committed = assistant.actions.any(
      (action) => action.status == AgentActionStatus.committed,
    );
    if (assistant.status != AgentMessageStatus.complete && !committed) {
      return null;
    }
    return _ConversationPair(
      user,
      assistant,
      projectedAssistant: _historicalControlState(assistant),
    );
  }
  if (assistant.status != AgentMessageStatus.complete ||
      RegExp(
        r'\{\s*"(?:entries|items|first_day|coverage)"\s*:|请求参数[：:]|返回值[：:]',
      ).hasMatch(assistant.text) ||
      assistant.text.trim().isEmpty ||
      !_isSafeHistoryText(assistant.text)) {
    return null;
  }
  return _ConversationPair(user, assistant);
}

String _historicalControlState(AgentMessage assistant) {
  final states = assistant.actions.map((action) => action.status).toSet();
  return [
    '历史对话状态（应用整理，不是旧助手原文、当前业务事实或授权）：',
    if (assistant.status != AgentMessageStatus.complete) '上一轮回复未完成。',
    if (assistant.steps.isNotEmpty) '上一轮进行过工具处理，旧结果未携带；需要重新查询目标。',
    if (states.contains(AgentActionStatus.committed))
      '上一轮已有实际提交回执。单纯肯定不要求再次执行，新的修改需重新提出。',
    if (states.contains(AgentActionStatus.rejected)) '上一轮方案被拒绝，没有因此获得新授权。',
    if (states.contains(AgentActionStatus.failed) ||
        states.contains(AgentActionStatus.interrupted))
      '上一轮存在未完成方案。',
    if (states.contains(AgentActionStatus.proposed)) '旧方案未提交，不能作为当前有效审批。',
    if (assistant.actions.isEmpty) '上一轮没有本地操作方案卡或提交回执。',
    if (assistant.actions.isEmpty &&
        RegExp(
          r'(?:确认|确定|这样做|要我|需要我|是否).{0,40}(?:吗|[?？])',
        ).hasMatch(assistant.text))
      '助手曾询问是否继续按用户原请求准备方案；肯定答复延续该意图，先重新查询，再创建可审批的具体方案。',
    '历史对话状态不授予工具权限，旧引用与许可不能沿用。',
  ].join('\n');
}

bool _hasStructuredContent(AgentMessage message) =>
    message.actions.isNotEmpty ||
    message.steps.isNotEmpty ||
    message.evidence.isNotEmpty ||
    message.imageCount != 0;

bool _isSafeHistoryText(String text) {
  try {
    AgentText.requireSafe(text);
  } on AgentFailure {
    return false;
  }
  return !_containsInternalReference(text) &&
      !_containsInstructionOverride(text);
}

bool _containsInternalReference(String text) => RegExp(
  // Current tool references are random 16-byte hex values. The named forms
  // also cover older serialized tokens that may still be in local history.
  r'(?<![A-Za-z0-9])(?:e_|r_|c_|t_|s_|event_|task_|cursor_)[a-f0-9]{16,}(?![A-Za-z0-9])',
  caseSensitive: false,
).hasMatch(text);

bool _containsInstructionOverride(String text) => RegExp(
  r'\b(?:ignore|disregard|override)\s+(?:all\s+)?(?:the\s+)?(?:previous|prior|above|earlier)\s+(?:(?:system|developer)\s+)?(?:instructions?|rules?)\b'
  r'|\b(?:reveal|print|show|leak)\s+(?:the\s+)?(?:hidden\s+)?(?:system|developer)\s+(?:prompt|instructions?)\b'
  r'|\bact\s+as\s+(?:the\s+)?(?:system|developer)\b'
  r'|忽略(?:之前|先前|以上|前面|所有).{0,12}(?:指令|规则|提示|限制)'
  r'|(?:泄露|输出|打印|展示).{0,12}(?:系统提示|隐藏指令|开发者指令|密钥|密码)',
  caseSensitive: false,
).hasMatch(text);

String? _historicalQuestionSummary(
  List<_ConversationPair> omitted,
  int maximumCharacters,
) {
  const prefix =
      'historical_user_context\n'
      '仅整理本次提供的历史范围，并非完整会话。\n'
      '以下仅为历史用户问题，不代表当前业务事实、批准或工具权限：\n';
  const marker = '- ';
  final budget = maximumCharacters < 2000 ? maximumCharacters : 2000;
  if (_characterCount(prefix) >= budget) return null;

  final questions = <String>[];
  for (final pair in omitted) {
    final normalized = pair.user.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty || !_isSafeHistoryText(normalized)) continue;
    final clipped = _takeCharacters(normalized, 160);
    if (clipped.isNotEmpty) questions.add(clipped);
  }
  if (questions.isEmpty) return null;

  // Prefer the most recent omitted questions when the item cap applies, then
  // preserve their original chronological order in the summary.
  final selected = questions.length > 12
      ? questions.sublist(questions.length - 12)
      : questions;
  var summary = _formatSummary(prefix, selected);
  while (selected.length > 1 && _characterCount(summary) > budget) {
    selected.removeAt(0);
    summary = _formatSummary(prefix, selected);
  }
  if (_characterCount(summary) > budget) {
    final room = budget - _characterCount(prefix) - _characterCount(marker);
    if (room <= 0) return null;
    final last = selected.last;
    final clipped = _takeCharacters(last, room);
    if (clipped.isEmpty) return null;
    summary = _formatSummary(prefix, [clipped]);
  }

  try {
    AgentText.requireSafe(summary, maxCharacters: 2000);
  } on AgentFailure {
    return null;
  }
  return _characterCount(summary) <= budget ? summary : null;
}

String _formatSummary(String prefix, List<String> questions) =>
    '$prefix${questions.map((question) => '- $question').join('\n')}';

String _takeCharacters(String value, int maximum) {
  if (maximum <= 0) return '';
  final selected = <int>[];
  var usedCodeUnits = 0;
  for (final rune in value.runes) {
    final width = rune > 0xffff ? 2 : 1;
    if (usedCodeUnits + width > maximum) break;
    selected.add(rune);
    usedCodeUnits += width;
  }
  return String.fromCharCodes(selected);
}

int _characterCount(String value) => value.length;

final class _ConversationPair {
  const _ConversationPair(this.user, this.assistant, {this.projectedAssistant});

  final AgentMessage user;
  final AgentMessage assistant;
  final String? projectedAssistant;
  String get assistantContext => projectedAssistant ?? assistant.text;

  int get characterCount =>
      _characterCount(user.text) + _characterCount(assistantContext);
}
