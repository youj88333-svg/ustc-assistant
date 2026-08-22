// Field-for-field Dart port of the Python JW identity helpers used by
// `src/ustc_assistant/sources/jw/course.py` and `source_bundle.py`.
//
// The SourceBundle 1.0 path (source_bundle.py) uses ONLY `stableHash` for
// collision discriminators and exam identity hashes. The legacy `digest` /
// `objectId` / id-prefix machinery in `exam.py`/`course.py` is NOT used by
// the bundle builder and is intentionally NOT ported.

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Matches Python `SOURCE = "ustc_jw"`.
const String jwSource = 'ustc_jw';

/// Matches Python `SOURCE_SYSTEM = "jw.ustc.edu.cn"`.
const String jwSourceSystem = 'jw.ustc.edu.cn';

/// Matches Python `TIMEZONE = "Asia/Shanghai"`.
const String jwTimezone = 'Asia/Shanghai';

/// Matches Python `TZ_OFFSET = "+08:00"`.
const String jwTzOffset = '+08:00';

/// Port of Python `stable_hash(parts)` (course.py:206-208):
///   `sha256("|".join("" if p is None else str(p) for p in parts)).hexdigest()[:24]`
///
/// `None` becomes the empty string; every other part is `str(part)`, joined
/// with `|`, sha256-hex-encoded, truncated to 24 chars.
String stableHash(List<Object?> parts) {
  final payload = parts.map((p) => p?.toString() ?? '').join('|');
  return sha256.convert(utf8.encode(payload)).toString().substring(0, 24);
}

/// Port of Python `hhmm(value)` (course.py:24-28): zero-pad a numeric value to
/// 4 digits. Raises [ArgumentError] if [value] is not a non-negative integer
/// string/int.
String hhmm(Object? value) {
  final text = value?.toString() ?? '';
  if (text.isEmpty || !RegExp(r'^\d+$').hasMatch(text)) {
    throw ArgumentError('Invalid HHmm value: $value');
  }
  return text.padLeft(4, '0');
}

/// Port of Python `iso_datetime(date_text, time_value)` (course.py:31-37):
/// validate `{date} {HH}:{MM}` parses, then return `"{date}T{HH}:{MM}:00+08:00"`.
String isoDateTime(String dateText, Object? timeValue) {
  final time = hhmm(timeValue);
  final hour = time.substring(0, 2);
  final minute = time.substring(2);
  // Validate the date/time combination (mirrors strptime).
  final parsed = DateTime.tryParse('$dateText $hour:$minute');
  if (parsed == null) {
    throw ArgumentError('Invalid date/time: $dateText $hour:$minute');
  }
  // NOTE: the original line was `'$dateTextT$hour:...'` which Dart parses as a
  // single identifier `dateTextT` (compile error). Braces force `dateText` to
  // interpolate, leaving the literal `T` — matching Python
  // `f"{date_text}T{hour}:{minute}:00{TZ_OFFSET}"`.
  return '${dateText}T$hour:$minute:00$jwTzOffset';
}

/// Port of Python `_normalized_identity_text(value)` (course.py:45-48) and
/// `normalize_text(value)` (exam.py:37-38):
///   `" ".join(str(value).split())`
///
/// Python `str.split()` with no args splits on runs of any whitespace
/// (including \t\n\r\f\v and Unicode whitespace) and discards empty strings.
/// Dart `RegExp(r'\s+')` covers ASCII whitespace; `\u3000` (ideographic
/// space) is added to match CJK whitespace handling.
String normalizeText(String value) {
  return value
      .split(RegExp(r'[\s\u3000]+'))
      .where((s) => s.isNotEmpty)
      .join(' ');
}

/// Port of Python `_normalized_identity_text(value)` which tolerates `None`
/// (returns the empty string for null).
String normalizedIdentityText(Object? value) {
  if (value == null) return '';
  return normalizeText(value.toString());
}

/// Canonical JSON encoding mirroring Python `json.dumps(..., ensure_ascii=False,
/// sort_keys=True, separators=(",", ":"))`: recursively sort map keys, then
/// encode with no extra whitespace. Dart `jsonEncode` produces compact output
/// by default and passes non-ASCII through, matching `ensure_ascii=False`.
String canonicalJsonEncode(Object? value) {
  Object? normalize(Object? current) {
    if (current is Map) {
      final keys = current.keys.map((k) => k.toString()).toList()..sort();
      return <String, dynamic>{
        for (final key in keys) key: normalize(current[key]),
      };
    }
    if (current is List) {
      return current.map(normalize).toList(growable: false);
    }
    return current;
  }

  return jsonEncode(normalize(value));
}
