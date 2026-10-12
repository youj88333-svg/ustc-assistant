import 'dart:convert';

import 'package:markdown/markdown.dart' as md;

import '../core/public_query_contract.dart';

const int _maximumMarkdownBytes = 256 * 1024;
const int _maximumKnowledgeSections = 256;

const Set<String> _allowedLinkHosts = {
  'www.teach.ustc.edu.cn',
  'finance.ustc.edu.cn',
  'jw.ustc.edu.cn',
};

const Set<String> _allowedElementTags = {
  'a',
  'blockquote',
  'br',
  'code',
  'del',
  'em',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'hr',
  'i',
  'li',
  'ol',
  'p',
  'pre',
  's',
  'strong',
  'sub',
  'sup',
  'table',
  'tbody',
  'td',
  'th',
  'thead',
  'tr',
  'ul',
};

final RegExp _htmlMarkup = RegExp(
  r'<!--|<!\[CDATA\[|<\?|<![A-Za-z]|</?[A-Za-z][A-Za-z0-9-]*(?:\s|/?>)',
  caseSensitive: false,
);
final RegExp _atxHeading = RegExp(r'^ {0,3}(#{1,6})(?:[ \t]+.*|[ \t]*)$');
final RegExp _setextUnderline = RegExp(r'^ {0,3}(=+|-+)[ \t]*$');
final RegExp _fenceStart = RegExp(r'^ {0,3}(`{3,}|~{3,})');
final RegExp _controlCharacter = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]');

/// One bounded, readable section of a trusted Markdown edition.
final class KnowledgeSection {
  const KnowledgeSection({
    required this.index,
    required this.heading,
    required this.markdown,
    required this.plainText,
  });

  final int index;
  final String heading;
  final String markdown;
  final String plainText;
}

/// Validates and segments one trusted Markdown material.
///
/// This function has no network, filesystem, database, renderer, or execution
/// capability. Links are validated as citation text and are never followed.
List<KnowledgeSection> knowledgeSections(String markdown) {
  _checkInputSize(markdown);
  if (markdown.trim().isEmpty || _controlCharacter.hasMatch(markdown)) {
    _failSchema();
  }

  final normalized = _normalizeMarkdown(markdown);
  if (_htmlMarkup.hasMatch(normalized)) _failSchema();

  final document = md.Document(blockSyntaxes: const [md.TableSyntax()]);
  late final List<md.Node> roots;
  try {
    roots = document.parse(normalized);
  } on Object {
    _failSchema();
  }

  for (final reference in document.linkReferences.values) {
    _validateLink(reference.destination);
  }
  _validateNodes(roots);

  final headingEvents = _findTopLevelHeadings(normalized);
  final astHeadingCount = roots.where(_isHeading).length;
  if (headingEvents.length != astHeadingCount) _failSchema();

  final markdownParts = _splitMarkdown(normalized, headingEvents);
  final astParts = _groupAst(roots);
  if (markdownParts.length != astParts.length) _failSchema();
  if (markdownParts.length > _maximumKnowledgeSections) {
    _failResourceLimit();
  }

  final sections = <KnowledgeSection>[];
  for (var index = 0; index < markdownParts.length; index++) {
    final sourcePart = markdownParts[index];
    final astPart = astParts[index];
    final plainText = _plainText(astPart.nodes);
    if (sourcePart.isEmpty || plainText.isEmpty) _failSchema();
    sections.add(
      KnowledgeSection(
        index: index,
        heading: astPart.heading.isEmpty ? '正文' : astPart.heading,
        markdown: sourcePart,
        plainText: plainText,
      ),
    );
  }

  if (sections.isEmpty) _failSchema();
  return List<KnowledgeSection>.unmodifiable(sections);
}

void _checkInputSize(String markdown) {
  // Avoid allocating a UTF-8 copy for an already oversized string.
  if (markdown.length > _maximumMarkdownBytes) _failResourceLimit();
  try {
    if (utf8.encode(markdown).length > _maximumMarkdownBytes) {
      _failResourceLimit();
    }
  } on FormatException {
    _failSchema();
  } on ArgumentError {
    _failSchema();
  }
}

String _normalizeMarkdown(String markdown) {
  final normalized = markdown
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceFirst('\uFEFF', '');
  return _trimOuterBlankLines(normalized);
}

String _trimOuterBlankLines(String markdown) {
  final lines = markdown.split('\n');
  var start = 0;
  var end = lines.length;
  while (start < end && lines[start].trim().isEmpty) {
    start++;
  }
  while (end > start && lines[end - 1].trim().isEmpty) {
    end--;
  }
  return lines.sublist(start, end).join('\n');
}

void _validateNodes(Iterable<md.Node> nodes) {
  for (final node in nodes) {
    if (node is! md.Element) continue;
    if (node.tag == 'img' || !_allowedElementTags.contains(node.tag)) {
      _failSchema();
    }
    if (node.tag == 'a') {
      final href = node.attributes['href'];
      if (href == null || href.isEmpty) _failSchema();
      _validateLink(href);
    }
    final children = node.children;
    if (children != null) _validateNodes(children);
  }
}

void _validateLink(String rawTarget) {
  if (rawTarget.isEmpty ||
      rawTarget.contains('\\') ||
      RegExp(r'[\s\x00-\x1F\x7F]').hasMatch(rawTarget)) {
    _failSchema();
  }

  late final Uri target;
  try {
    target = Uri.parse(rawTarget);
  } on FormatException {
    _failSchema();
  }

  if (!target.hasScheme ||
      target.scheme.toLowerCase() != 'https' ||
      !target.hasAuthority ||
      target.host.isEmpty ||
      target.userInfo.isNotEmpty ||
      target.authority.contains('@') ||
      target.port != 443 ||
      !_allowedLinkHosts.contains(target.host.toLowerCase())) {
    _failSchema();
  }
}

List<_HeadingEvent> _findTopLevelHeadings(String markdown) {
  final lines = markdown.split('\n');
  final events = <_HeadingEvent>[];
  String? fenceCharacter;
  var fenceLength = 0;

  for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    final line = lines[lineIndex];
    if (fenceCharacter != null) {
      final closing = RegExp(
        '^ {0,3}${RegExp.escape(fenceCharacter)}{$fenceLength,}[ \\t]*\$',
      );
      if (closing.hasMatch(line)) {
        fenceCharacter = null;
        fenceLength = 0;
      }
      continue;
    }

    final fence = _fenceStart.firstMatch(line);
    if (fence != null) {
      final marker = fence.group(1)!;
      fenceCharacter = marker[0];
      fenceLength = marker.length;
      continue;
    }

    final atx = _atxHeading.firstMatch(line);
    if (atx != null) {
      events.add(_HeadingEvent(lineIndex, atx.group(1)!.length));
      continue;
    }

    final setext = _setextUnderline.firstMatch(line);
    if (setext != null && lineIndex > 0) {
      final previous = lines[lineIndex - 1];
      if (_canBeSetextTitle(previous)) {
        events.add(
          _HeadingEvent(
            lineIndex - 1,
            setext.group(1)!.startsWith('=') ? 1 : 2,
          ),
        );
      }
    }
  }

  events.sort((left, right) => left.lineIndex.compareTo(right.lineIndex));
  return events;
}

bool _canBeSetextTitle(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty ||
      line.startsWith('>') ||
      _atxHeading.hasMatch(line) ||
      _setextUnderline.hasMatch(line) ||
      _fenceStart.hasMatch(line)) {
    return false;
  }
  if (RegExp(r'^\s*(?:[-+*]|\d+[.)])\s+').hasMatch(line)) return false;
  return true;
}

List<String> _splitMarkdown(String markdown, List<_HeadingEvent> events) {
  final lines = markdown.split('\n');
  final starts = <int>[0];
  var hasSeenHeading = false;

  for (final event in events) {
    final firstH1 = !hasSeenHeading && event.level == 1;
    hasSeenHeading = true;
    if (firstH1) continue;

    final currentStart = starts.last;
    final hasContentBeforeHeading = lines
        .sublist(currentStart, event.lineIndex)
        .any((line) => line.trim().isNotEmpty);
    if (hasContentBeforeHeading) {
      starts.add(event.lineIndex);
    } else {
      starts[starts.length - 1] = event.lineIndex;
    }
  }

  final parts = <String>[];
  for (var index = 0; index < starts.length; index++) {
    final end = index + 1 < starts.length ? starts[index + 1] : lines.length;
    parts.add(
      _trimOuterBlankLines(lines.sublist(starts[index], end).join('\n')),
    );
  }
  return parts;
}

List<_AstSection> _groupAst(List<md.Node> roots) {
  final sections = <_AstSection>[];
  var current = _AstSection('正文');
  var hasSeenHeading = false;

  for (final node in roots) {
    final level = _headingLevel(node);
    if (level != null) {
      final title = _inlineText(node).trim().replaceAll(RegExp(r'\s+'), ' ');
      if (!hasSeenHeading && level == 1) {
        current.heading = title;
      } else if (current.nodes.isEmpty) {
        current.heading = title;
      } else {
        sections.add(current);
        current = _AstSection(title);
      }
      hasSeenHeading = true;
    }
    current.nodes.add(node);
  }

  if (current.nodes.isNotEmpty) sections.add(current);
  return sections;
}

bool _isHeading(md.Node node) => _headingLevel(node) != null;

int? _headingLevel(md.Node node) {
  if (node is! md.Element) return null;
  final match = RegExp(r'^h([1-6])$').firstMatch(node.tag);
  return match == null ? null : int.parse(match.group(1)!);
}

String _plainText(List<md.Node> nodes) {
  final blocks = <String>[];
  for (final node in nodes) {
    final text = _blockText(node).trim();
    if (text.isNotEmpty) blocks.add(text);
  }
  return blocks
      .join('\n\n')
      .replaceAll(RegExp(r'[ \t]+\n'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

String _blockText(md.Node node) {
  if (node is! md.Element) return _inlineText(node);
  switch (node.tag) {
    case 'table':
      return _tableText(node);
    case 'ul':
    case 'ol':
      return (node.children ?? const <md.Node>[])
          .map(_blockText)
          .where((text) => text.trim().isNotEmpty)
          .join('\n');
    case 'li':
      final body = (node.children ?? const <md.Node>[])
          .map(_blockText)
          .where((text) => text.trim().isNotEmpty)
          .join('\n');
      return body.isEmpty ? '' : '• $body';
    case 'blockquote':
      return (node.children ?? const <md.Node>[])
          .map(_blockText)
          .where((text) => text.trim().isNotEmpty)
          .join('\n');
    case 'hr':
      return '';
    default:
      return _inlineText(node);
  }
}

String _inlineText(md.Node node) {
  if (node is md.Text) return node.text;
  if (node is md.UnparsedContent) return node.textContent;
  if (node is! md.Element) return '';
  if (node.tag == 'img') _failSchema();
  if (node.tag == 'br') return '\n';
  if (node.tag == 'table') return _tableText(node);
  return (node.children ?? const <md.Node>[]).map(_inlineText).join();
}

String _tableText(md.Element table) {
  final headerRows = <md.Element>[];
  final bodyRows = <md.Element>[];
  for (final child in table.children ?? const <md.Node>[]) {
    if (child is! md.Element) continue;
    if (child.tag == 'thead') headerRows.addAll(_rows(child));
    if (child.tag == 'tbody') bodyRows.addAll(_rows(child));
  }

  final headers = headerRows.isEmpty ? <String>[] : _cells(headerRows.first);
  final lines = <String>[];
  if (headers.isNotEmpty) lines.add('表头：${headers.join(' | ')}');
  for (var rowIndex = 0; rowIndex < bodyRows.length; rowIndex++) {
    final values = _cells(bodyRows[rowIndex]);
    final count = values.length > headers.length
        ? values.length
        : headers.length;
    final fields = <String>[];
    for (var column = 0; column < count; column++) {
      final header = column < headers.length && headers[column].isNotEmpty
          ? headers[column]
          : '第${column + 1}列';
      final value = column < values.length ? values[column] : '';
      fields.add('$header：$value');
    }
    if (fields.isNotEmpty) lines.add(fields.join('；'));
  }
  return lines.join('\n');
}

List<md.Element> _rows(md.Element section) => [
  for (final child in section.children ?? const <md.Node>[])
    if (child is md.Element && child.tag == 'tr') child,
];

List<String> _cells(md.Element row) => [
  for (final child in row.children ?? const <md.Node>[])
    if (child is md.Element && (child.tag == 'th' || child.tag == 'td'))
      _inlineText(child).replaceAll(RegExp(r'\s+'), ' ').trim(),
];

Never _failSchema() =>
    throw const PublicFailure(PublicFailureCode.sourceSchema);

Never _failResourceLimit() =>
    throw const PublicFailure(PublicFailureCode.resourceLimit);

final class _HeadingEvent {
  const _HeadingEvent(this.lineIndex, this.level);
  final int lineIndex;
  final int level;
}

final class _AstSection {
  _AstSection(this.heading);
  String heading;
  final List<md.Node> nodes = [];
}
