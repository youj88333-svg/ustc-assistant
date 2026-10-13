import '../core/agent_contract.dart';
import '../core/agent_text.dart';
import 'model_gateway_contract.dart';

/// Builds bounded, safe conversational history for one model request.
///
/// Only adjacent, completed plain-text user/assistant pairs are reusable. Any
/// action, tool step, evidence, image, internal reference, unsafe text, or
/// interrupted message makes that pair ineligible. When older pairs are
/// omitted, a deterministic summary contains only their user questions and is
/// explicitly labeled as historical context.
List<ModelChatMessage> buildAgentConversationContext(
  List<AgentMessage> history, {
  int maxPairs = 6,
  int maximumCharacters = 12000,
}) {
  final eligible = <_ConversationPair>[];
  for (var index = 0; index + 1 < history.length;) {
    final user = history[index];
    final assistant = history[index + 1];
    if (_isEligiblePair(user, assistant)) {
      eligible.add(_ConversationPair(user, assistant));
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
      ModelChatMessage(role: 'assistant', content: pair.assistant.text),
    ],
  ]);
}

bool _isEligiblePair(AgentMessage user, AgentMessage assistant) {
  if (user.role != AgentMessageRole.user ||
      assistant.role != AgentMessageRole.assistant ||
      user.status != AgentMessageStatus.complete ||
      assistant.status != AgentMessageStatus.complete ||
      _hasStructuredContent(user) ||
      _hasStructuredContent(assistant) ||
      user.text.trim().isEmpty ||
      assistant.text.trim().isEmpty) {
    return false;
  }

  return _isSafeHistoryText(user.text) && _isSafeHistoryText(assistant.text);
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
  const _ConversationPair(this.user, this.assistant);

  final AgentMessage user;
  final AgentMessage assistant;

  int get characterCount =>
      _characterCount(user.text) + _characterCount(assistant.text);
}
