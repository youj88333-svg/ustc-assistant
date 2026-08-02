/// Deterministic, privacy-safe summaries of a single tool invocation.
///
/// These are the ONLY permitted sources for the `safe_arguments_summary` and
/// `safe_result_summary` columns that [AgentSessionService] persists per
/// `tool_use`. They are intentionally lossy:
///
/// * **Arguments** keep only the tool name, date fields, safe enum tokens and
///   counts. Keys named like `key`/`token`/`cookie`/`password`/`account`/
///   `username`/`id` (or containing those substrings) are omitted; any string
///   value that is not an ISO-like date or a strict lowercase safe token is
///   dropped; nested data is encoded as a bare count (never its contents).
///   A `ref_*` token, a run-local raw id, or a student id can therefore never
///   survive into a summary.
/// * **Results** carry only the lifecycle/result enum, a safe error code and
///   top-level payload counts. No payload VALUES are ever emitted, so raw
///   timetable bodies, external bodies, or other tool results never leak.
///
/// Both functions are pure and deterministic: the same input always yields the
/// same output string.
library;

import '../domain/agent_tool.dart';

/// Builds a safe argument summary for a tool call with [toolName] and
/// [arguments]. See the library doc comment for the redaction rules.
String summarizeToolArguments(String toolName, Map<String, Object?> arguments) {
  final out = <String>[];
  final sortedKeys = arguments.keys.toList()..sort();
  for (final key in sortedKeys) {
    if (_forbiddenKey(key)) continue;
    final encoded = _safeArgumentValue(arguments[key]);
    if (encoded == null) continue; // hidden: secret / ref / opaque / unsupported
    out.add('$key=$encoded');
  }
  final body = out.isEmpty ? '{}' : '{${out.join(', ')}}';
  return '$toolName$body';
}

/// Builds a safe result summary for [result]: the result enum, a safe
/// `errorCode` when present, and top-level payload counts only. No payload
/// values are encoded.
String summarizeToolResult(AgentToolResult result) {
  final sortedKeys = result.payload.keys.toList()..sort();
  final counts = <String>[];
  for (final key in sortedKeys) {
    counts.add('$key=${_countValue(result.payload[key])}');
  }
  final parts = <String>[
    'status=${result.status.name}',
    if (result.errorCode != null) 'error=${result.errorCode}',
    counts.isEmpty ? 'payload{}' : 'payload{${counts.join(',')}}',
  ];
  return parts.join(' ');
}

/// Keys that must never be persisted, matched case-insensitively as a
/// substring: credentials, account identifiers, row ids, and refs.
const _secretKeyMarkers = <String>[
  'key',
  'token',
  'cookie',
  'password',
  'account',
  'username',
  'id',
  'ref',
];

bool _forbiddenKey(String key) {
  final lower = key.toLowerCase();
  for (final marker in _secretKeyMarkers) {
    if (lower.contains(marker)) return true;
  }
  return false;
}

/// Encodes a single argument value into a safe string, or `null` to omit it.
Object? _safeArgumentValue(Object? value) {
  if (value == null) return null;
  if (value is num || value is bool) return value.toString();
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    if (_isDateLike(trimmed)) return trimmed;
    // A strict safe token: lowercase ASCII start, then lowercase/digits/
    // underscore. This excludes titlecase student ids (PB2408), raw refs
    // (ref_*), free text, and any credential-looking value.
    if (_isSafeToken(trimmed)) return trimmed;
    return null;
  }
  if (value is Map) return 'map(${value.length})';
  if (value is List) return 'list(${value.length})';
  return null;
}

/// Matches an ISO-like date or datetime (digits, dash, colon, `T`, `.`, and an
/// optional `+HH:MM`/`Z` timezone suffix — never letters, so it cannot be a
/// student id or ref).
final RegExp _datePattern = RegExp(
  r'^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?([+-]\d{2}:\d{2}|Z)?)?$',
);

bool _isDateLike(String s) => _datePattern.hasMatch(s);

/// A strict, safe, lowercase enum token. Starts with a letter and contains only
/// lowercase letters, digits and underscores (≤ 40 chars). Uppercase/titlecase
/// identifiers and refs do not match, so they are never persisted.
final RegExp _safeTokenPattern = RegExp(r'^[a-z][a-z0-9_]{0,39}$');

bool _isSafeToken(String s) {
  if (!_safeTokenPattern.hasMatch(s)) return false;
  if (s.contains('ref')) return false;
  return true;
}

/// Counts how many elements a top-level payload value contributes, without
/// ever revealing its contents.
String _countValue(Object? value) {
  if (value is List) return 'list(${value.length})';
  if (value is Map) return 'map(${value.length})';
  return 'scalar';
}