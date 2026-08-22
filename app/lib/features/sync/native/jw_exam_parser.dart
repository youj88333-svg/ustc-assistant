// Field-for-field Dart port of `src/ustc_assistant/sources/jw/exam.py`.
//
// Ports `ExamRow`, `ExamTableParser` (a hand-written state machine mirroring
// Python's `html.parser.HTMLParser` — no `package:html` dependency), and
// `parse_exam_rows` / `parse_exam_time`. The legacy `convert_row`/`convert`
// path (with `digest`/`object_id`/`id`/`fingerprint`) is intentionally NOT
// ported: the SourceBundle 1.0 builder uses `stableHash` only.

import '_jw_identity.dart';

/// Matches Python `TZ_OFFSET` / `TIMEZONE` (exam.py:14-15).
// (Re-exported via _jw_identity for bundle builder use.)

/// Matches Python `EXPECTED_HEADERS` (exam.py:18-27).
const List<String> expectedHeaders = [
  '课程号',
  '考试类型',
  '课程名称',
  '日期时间',
  '考场',
  '教学楼',
  '考场所在校区',
  '考试说明',
];

/// Matches Python `VALID_HEADERS` (exam.py:28-31): two accepted header rows.
final List<List<String>> validHeaders = [
  expectedHeaders,
  ['课堂号', '考试类型', '课程名称', '日期时间', '考场', '教学楼', '考场所在校区', '考试说明'],
];

/// Matches Python `TIME_PATTERN` (exam.py:32-34).
final RegExp _timePattern =
    RegExp(r'^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2})~(\d{2}:\d{2})$');

/// Port of the `ExamRow` dataclass (exam.py:41-67). Field order matches the
/// Python dataclass declaration order exactly (consumed positionally by
/// `fromCells`).
class ExamRow {
  ExamRow({
    required this.courseCode,
    required this.examType,
    required this.courseName,
    required this.dateTime,
    required this.room,
    required this.building,
    required this.campus,
    required this.note,
  });

  final String courseCode;
  final String examType;
  final String courseName;
  final String dateTime;
  final String room;
  final String building;
  final String campus;
  final String note;

  /// Port of `ExamRow.from_cells` (exam.py:52-64): 8 cells, normalize each,
  /// require every non-`note` field to be non-empty.
  factory ExamRow.fromCells(List<String> cells, int rowNumber) {
    if (cells.length != 8) {
      throw ArgumentError(
        'exam row $rowNumber: expected 8 cells, got ${cells.length}',
      );
    }
    final normalized = cells.map(normalizeText).toList(growable: false);
    const fieldNames = [
      'courseCode',
      'examType',
      'courseName',
      'dateTime',
      'room',
      'building',
      'campus',
      'note',
    ];
    for (var i = 0; i < normalized.length; i++) {
      if (fieldNames[i] != 'note' && normalized[i].isEmpty) {
        throw ArgumentError(
          'exam row $rowNumber: required field ${fieldNames[i]} is empty',
        );
      }
    }
    return ExamRow(
      courseCode: normalized[0],
      examType: normalized[1],
      courseName: normalized[2],
      dateTime: normalized[3],
      room: normalized[4],
      building: normalized[5],
      campus: normalized[6],
      note: normalized[7],
    );
  }
}

/// Port of `ExamTableParser` (exam.py:70-140): a hand-written state machine
/// that finds `<table id="exams">`, tracks table nesting depth, forbids mixing
/// `th`/`td` within a row, normalizes cell text, and collects one header row
/// plus any number of data rows.
class ExamTableParser {
  ExamTableParser();

  bool foundTable = false;
  bool inExamTable = false;
  int tableDepth = 0;
  bool inRow = false;
  String? rowKind;
  String? cellKind;
  final List<String> _cellParts = [];
  List<String> currentCells = [];
  List<String>? headers;
  final List<List<String>> rawRows = [];

  void handleStartTag(String tag, Map<String, String?> attrs) {
    if (tag == 'table') {
      if (inExamTable) {
        tableDepth += 1;
      } else if (attrs['id'] == 'exams') {
        if (foundTable) {
          throw ArgumentError('multiple table#exams elements found');
        }
        foundTable = true;
        inExamTable = true;
        tableDepth = 1;
      }
      return;
    }

    if (!inExamTable || tableDepth != 1) return;
    if (tag == 'tr') {
      inRow = true;
      rowKind = null;
      currentCells = [];
    } else if (inRow && (tag == 'th' || tag == 'td')) {
      if (rowKind != null && rowKind != tag) {
        throw ArgumentError('exam table row mixes header and data cells');
      }
      rowKind = tag;
      cellKind = tag;
      _cellParts.clear();
    }
  }

  void handleData(String data) {
    if (inExamTable && cellKind != null) {
      _cellParts.add(data);
    }
  }

  void handleEndTag(String tag) {
    if (!inExamTable) return;
    if (tag == 'table') {
      tableDepth -= 1;
      if (tableDepth == 0) {
        inExamTable = false;
      }
      return;
    }
    if (tableDepth != 1) return;
    if ((tag == 'th' || tag == 'td') && cellKind == tag) {
      currentCells.add(normalizeText(_cellParts.join('')));
      cellKind = null;
      _cellParts.clear();
    } else if (tag == 'tr' && inRow) {
      if (currentCells.isNotEmpty) {
        if (rowKind == 'th') {
          if (headers != null) {
            throw ArgumentError('exam table contains multiple header rows');
          }
          headers = List<String>.from(currentCells);
        } else if (rowKind == 'td') {
          rawRows.add(List<String>.from(currentCells));
        }
      }
      inRow = false;
      rowKind = null;
      currentCells = [];
    }
  }
}

/// Port of `parse_exam_rows` (exam.py:143-159): feed the HTML, find
/// `table#exams`, validate the header is one of `VALID_HEADERS`, and build one
/// `ExamRow` per data row.
List<ExamRow> parseExamRows(String htmlText) {
  final parser = ExamTableParser();
  _feed(parser, htmlText);
  if (!parser.foundTable) {
    throw ArgumentError('expected table#exams was not found');
  }
  final headers = parser.headers ?? const <String>[];
  if (!_isValidHeaders(headers)) {
    throw ArgumentError(
      'unexpected exam table header: expected one of $validHeaders, '
      'got $headers',
    );
  }
  final rows = <ExamRow>[];
  for (var i = 0; i < parser.rawRows.length; i++) {
    rows.add(ExamRow.fromCells(parser.rawRows[i], i + 1));
  }
  return rows;
}

bool _isValidHeaders(List<String> headers) {
  for (final candidate in validHeaders) {
    if (_listEquals(headers, candidate)) return true;
  }
  return false;
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Port of `parse_exam_time` (exam.py:162-184): regex + strptime validation +
/// end>start; returns `(startAt, endAt)` ISO strings with `+08:00`.
(String, String) parseExamTime(String value, int rowNumber) {
  final match = _timePattern.firstMatch(value);
  if (match == null) {
    throw ArgumentError(
      'exam row $rowNumber: invalid date_time \'$value\'; '
      'expected YYYY-MM-DD HH:MM~HH:MM',
    );
  }
  final dateText = match.group(1)!;
  final startText = match.group(2)!;
  final endText = match.group(3)!;
  final start = _parseDateTime(dateText, startText);
  if (start == null) {
    throw ArgumentError("exam row $rowNumber: invalid date_time '$value'");
  }
  final end = _parseDateTime(dateText, endText);
  if (end == null) {
    throw ArgumentError("exam row $rowNumber: invalid date_time '$value'");
  }
  if (!end.isAfter(start)) {
    throw ArgumentError('exam row $rowNumber: exam end must be later than start');
  }
  final startIso = _formatIso(start);
  final endIso = _formatIso(end);
  return (startIso, endIso);
}

DateTime? _parseDateTime(String dateText, String hhmm) {
  // Python `datetime.strptime("%Y-%m-%d %H:%M")`: validate the full string.
  final parsed = DateTime.tryParse('$dateText $hhmm');
  if (parsed == null) return null;
  // `DateTime.tryParse` accepts forms Python strptime would reject (e.g.
  // trailing space); re-check the components to match strict strptime.
  if (!_looksLikeValidDateTime(dateText, hhmm, parsed)) return null;
  return parsed;
}

bool _looksLikeValidDateTime(String dateText, String hhmm, DateTime parsed) {
  final dateMatch = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(dateText);
  if (dateMatch == null) return false;
  final y = int.parse(dateMatch.group(1)!);
  final mo = int.parse(dateMatch.group(2)!);
  final d = int.parse(dateMatch.group(3)!);
  if (parsed.year != y || parsed.month != mo || parsed.day != d) return false;
  final timeMatch = RegExp(r'^(\d{2}):(\d{2})$').firstMatch(hhmm);
  if (timeMatch == null) return false;
  final hh = int.parse(timeMatch.group(1)!);
  final mm = int.parse(timeMatch.group(2)!);
  if (parsed.hour != hh || parsed.minute != mm) return false;
  return true;
}

String _formatIso(DateTime dt) {
  // Python `start.strftime('%Y-%m-%dT%H:%M:%S')` — zero-padded components,
  // seconds always present. Dart's `toIso8601String()` matches this shape for
  // the date/time portion (no fractional seconds when none are set, but we
  // force seconds precision).
  final y = dt.year.toString().padLeft(4, '0');
  final mo = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  return '$y-$mo-${d}T$hh:$mm:00$jwTzOffset';
}

/// Minimal HTML tokenizer feeding `ExamTableParser`, mirroring Python's
/// `HTMLParser` with `convert_charrefs=True` (character references like
/// `&` are decoded and delivered as data).
void _feed(ExamTableParser parser, String html) {
  final scanner = _HtmlScanner(html);
  while (true) {
    final token = scanner.next();
    if (token is _EofToken) break;
    if (token is _StartTagToken) {
      parser.handleStartTag(token.tag, token.attrs);
    } else if (token is _EndTagToken) {
      parser.handleEndTag(token.tag);
    } else if (token is _DataToken) {
      if (token.text.isNotEmpty) {
        parser.handleData(token.text);
      }
    }
  }
}

abstract class _Token {}

class _StartTagToken extends _Token {
  _StartTagToken(this.tag, this.attrs);
  final String tag;
  final Map<String, String?> attrs;
}

class _EndTagToken extends _Token {
  _EndTagToken(this.tag);
  final String tag;
}

class _DataToken extends _Token {
  _DataToken(this.text);
  final String text;
}

class _EofToken extends _Token {}

/// A tiny pull-based HTML scanner. It is deliberately minimal: it recognizes
/// start tags (optionally self-closing), end tags, comments, and character
/// data with named-entity decoding. It is NOT a full HTML parser — only what
/// the exam page fixture (and structurally similar real pages) require.
class _HtmlScanner {
  _HtmlScanner(this.source);

  final String source;
  int _pos = 0;

  _Token next() {
    if (_pos >= source.length) return _EofToken();
    final char = source[_pos];
    if (char == '<') {
      // Comment?
      if (source.startsWith('<!--', _pos)) {
        final end = source.indexOf('-->', _pos + 4);
        if (end == -1) {
          _pos = source.length;
        } else {
          _pos = end + 3;
        }
        return next();
      }
      // End tag?
      if (_pos + 1 < source.length && source[_pos + 1] == '/') {
        final close = source.indexOf('>', _pos + 2);
        if (close == -1) {
          _pos = source.length;
          return _DataToken(source.substring(_pos));
        }
        final tag = _normalizeTagName(source.substring(_pos + 2, close));
        _pos = close + 1;
        return _EndTagToken(tag);
      }
      // Start tag. Find the matching '>'.
      final close = _findTagEnd(_pos + 1);
      if (close == -1) {
        // Unterminated '<' — emit as data (lenient).
        final text = source.substring(_pos);
        _pos = source.length;
        return _DataToken(text);
      }
      final inner = source.substring(_pos + 1, close);
      _pos = close + 1;
      return _parseStartTag(inner);
    }
    // Data up to next '<'.
    final nextLt = source.indexOf('<', _pos);
    if (nextLt == -1) {
      final text = source.substring(_pos);
      _pos = source.length;
      return _DataToken(_decodeEntities(text));
    }
    final text = source.substring(_pos, nextLt);
    _pos = nextLt;
    return _DataToken(_decodeEntities(text));
  }

  int _findTagEnd(int start) {
    // Honor attribute values containing '>' inside quotes.
    var i = start;
    var inQuote = ''; // '' or '"' or '\''
    while (i < source.length) {
      final c = source[i];
      if (inQuote.isNotEmpty) {
        if (c == inQuote) inQuote = '';
      } else {
        if (c == '"' || c == "'") {
          inQuote = c;
        } else if (c == '>') {
          return i;
        }
      }
      i++;
    }
    return -1;
  }

  _Token _parseStartTag(String inner) {
    // Strip a trailing '/' (self-closing) — ignored for our parser's needs.
    var body = inner;
    if (body.endsWith('/')) {
      body = body.substring(0, body.length - 1);
    }
    body = body.trimLeft();
    if (body.isEmpty) {
      return _DataToken('');
    }
    // Tag name ends at whitespace or end.
    var nameEnd = 0;
    while (nameEnd < body.length && !_isWhitespace(body[nameEnd])) {
      nameEnd++;
    }
    final tag = _normalizeTagName(body.substring(0, nameEnd));
    final attrs = <String, String?>{};
    var rest = body.substring(nameEnd);
    var p = 0;
    while (p < rest.length) {
      // Skip whitespace.
      while (p < rest.length && _isWhitespace(rest[p])) {
        p++;
      }
      if (p >= rest.length) break;
      // Attribute name.
      var nameStart = p;
      while (p < rest.length &&
          !_isWhitespace(rest[p]) &&
          rest[p] != '=' &&
          rest[p] != '/' &&
          rest[p] != '>') {
        p++;
      }
      if (p == nameStart) {
        p++;
        continue;
      }
      final attrName = rest.substring(nameStart, p).toLowerCase();
      // Skip whitespace.
      while (p < rest.length && _isWhitespace(rest[p])) {
        p++;
      }
      String? value;
      if (p < rest.length && rest[p] == '=') {
        p++;
        while (p < rest.length && _isWhitespace(rest[p])) {
          p++;
        }
        if (p < rest.length && (rest[p] == '"' || rest[p] == "'")) {
          final quote = rest[p];
          p++;
          final valueStart = p;
          while (p < rest.length && rest[p] != quote) {
            p++;
          }
          value = _decodeEntities(rest.substring(valueStart, p));
          if (p < rest.length) p++; // consume closing quote.
        } else {
          final valueStart = p;
          while (p < rest.length &&
              !_isWhitespace(rest[p]) &&
              rest[p] != '>') {
            p++;
          }
          value = _decodeEntities(rest.substring(valueStart, p));
        }
      }
      attrs[attrName] = value;
    }
    return _StartTagToken(tag, attrs);
  }

  static String _normalizeTagName(String raw) {
    return raw.trim().toLowerCase();
  }

  static bool _isWhitespace(String ch) =>
      ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == '\f';

  static String _decodeEntities(String text) {
    if (!text.contains('&')) return text;
    final buf = StringBuffer();
    var i = 0;
    while (i < text.length) {
      if (text[i] == '&') {
        final semi = text.indexOf(';', i + 1);
        if (semi != -1 && semi - i <= 12) {
          final entity = text.substring(i + 1, semi);
          final decoded = _namedEntities[entity] ?? _numericEntity(entity);
          if (decoded != null) {
            buf.write(decoded);
            i = semi + 1;
            continue;
          }
        }
      }
      buf.write(text[i]);
      i++;
    }
    return buf.toString();
  }

  static String? _numericEntity(String entity) {
    if (entity.startsWith('#')) {
      final hex = entity.startsWith('#x') || entity.startsWith('#X');
      final digits = entity.substring(hex ? 2 : 1);
      final code = int.tryParse(digits, radix: hex ? 16 : 10);
      if (code != null) {
        return String.fromCharCode(code);
      }
    }
    return null;
  }
}

/// The subset of named character references the exam HTML fixture uses (and
/// the common ones real pages rely on). Python's `html.parser` decodes the
/// full HTML5 entity table; for the JW exam page `&` is the only one
/// encountered, but the others are added defensively.
const Map<String, String> _namedEntities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': '\u00A0',
  'copy': '\u00A9',
  'middot': '\u00B7',
};
