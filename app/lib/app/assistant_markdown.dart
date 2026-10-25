import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

/// Shared, inert presentation for assistant prose. Source navigation remains
/// an explicit action in the evidence UI; Markdown cannot fetch remote assets.
final class AssistantMarkdown extends StatelessWidget {
  const AssistantMarkdown({super.key, required this.data});
  final String data;

  @override
  Widget build(BuildContext context) {
    const limit = 12000;
    final bounded = data.length <= limit
        ? data
        : '${data.substring(0, limit)}\n\n…内容过长，已截断显示';
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final body = theme.textTheme.bodyLarge!.copyWith(
      fontSize: 15,
      height: 1.55,
      color: colors.onSurface,
    );
    return MarkdownBody(
      data: bounded.replaceAll('<', r'\<'),
      softLineBreak: true,
      fitContent: true,
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: body,
        strong: const TextStyle(fontWeight: FontWeight.w700),
        h1: body.copyWith(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          height: 1.3,
        ),
        h2: body.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          height: 1.35,
        ),
        h3: body.copyWith(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          height: 1.4,
        ),
        blockSpacing: 10,
        listIndent: 22,
        listBullet: body.copyWith(color: colors.onSurfaceVariant),
        listBulletPadding: const EdgeInsets.only(right: 8),
        blockquote: body,
        blockquotePadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        blockquoteDecoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          border: Border(left: BorderSide(color: colors.primary, width: 3)),
        ),
        tableHead: body.copyWith(fontWeight: FontWeight.w700),
        tableBody: body,
        tableCellsPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 8,
        ),
      ),
      builders: {'a': _InertAnchorBuilder()},
      imageBuilder: (uri, title, alt) => Text(
        alt == null || alt.isEmpty ? '（图片已隐藏）' : '（图片已隐藏：$alt）',
        style: body.copyWith(color: colors.onSurfaceVariant),
      ),
    );
  }
}

final class _InertAnchorBuilder extends MarkdownElementBuilder {
  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => Text(element.textContent, style: parentStyle);
}
