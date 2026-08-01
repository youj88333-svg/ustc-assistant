import 'dart:convert';

/// Computes a deterministic fingerprint for a tool call so the Agent runtime
/// can detect when the model repeats an EXACT tool call within one run.
///
/// The fingerprint is a canonical, recursively SORTED JSON encoding of the
/// tool name + input arguments:
/// - Nested map key order does NOT matter (keys sorted canonically) — two maps
///   with the same content in different key orders fingerprint identically.
/// - List order DOES matter — reordering an array changes the fingerprint.
///
/// Because the encoding is deterministic, two structurally-identical calls
/// (regardless of how the model ordered object keys) produce the same string,
/// letting the runtime bound duplicate tool loops.
class ToolCallFingerprint {
  ToolCallFingerprint._();

  /// The fingerprint for a single tool call with [toolName] and [input].
  static String of(String toolName, Map<String, Object?> input) =>
      '${_encode(toolName)}(${_encodeMap(input)})';

  static String _encodeMap(Map<Object?, Object?> map) {
    final entries = map.entries.toList()
      ..sort((a, b) => (a.key ?? '').toString().compareTo((b.key ?? '').toString()));
    final parts = <String>[];
    for (final e in entries) {
      parts.add('${_encode(e.key)}:${_encodeValue(e.value)}');
    }
    return '{${parts.join(',')}}';
  }

  static String _encodeList(List<Object?> list) =>
      '[${list.map(_encodeValue).join(',')}]';

  static String _encodeValue(Object? value) {
    if (value is Map) {
      return _encodeMap(value.cast<Object?, Object?>());
    }
    if (value is List) {
      return _encodeList(value.cast<Object?>());
    }
    return _encode(value);
  }

  static String _encode(Object? value) {
    if (value == null) return 'null';
    if (value is num || value is bool || value is String) {
      return jsonEncode(value);
    }
    // Fallback for any other scalar.
    return jsonEncode(value.toString());
  }
}