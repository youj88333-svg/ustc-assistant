import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

const _assistantPreviewLimit = 12000;
const _assistantStreamingVisibleCharacters = 4000;

/// Shared, inert presentation for assistant prose. Source navigation remains
/// an explicit action in the evidence UI; Markdown cannot fetch remote assets.
final class AssistantMarkdown extends StatefulWidget {
  const AssistantMarkdown({
    super.key,
    required this.data,
    this.streaming = false,
  });

  final String data;
  final bool streaming;

  @override
  State<AssistantMarkdown> createState() => _AssistantMarkdownState();
}

final class _AssistantMarkdownState extends State<AssistantMarkdown> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final body = theme.textTheme.bodyLarge!.copyWith(
      fontSize: 15,
      height: 1.55,
      color: colors.onSurface,
    );

    if (widget.streaming) {
      final text = widget.data;
      final bounded = text.length <= _assistantStreamingVisibleCharacters
          ? text
          : '…生成期间仅显示最近 $_assistantStreamingVisibleCharacters 个字符；完成后可查看完整回复…\n\n'
                '${text.substring(text.length - _assistantStreamingVisibleCharacters)}';
      return Text(
        bounded,
        key: const ValueKey('assistant-streaming-text'),
        style: body,
      );
    }

    final truncated = widget.data.length > _assistantPreviewLimit && !_expanded;
    final visible = truncated
        ? '${widget.data.substring(0, _assistantPreviewLimit)}\n\n…已显示前 $_assistantPreviewLimit 个字符…'
        : widget.data;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _markdownBody(context, visible, body, colors),
        if (widget.data.length > _assistantPreviewLimit)
          TextButton.icon(
            key: const ValueKey('assistant-markdown-expand'),
            style: TextButton.styleFrom(
              alignment: Alignment.centerLeft,
              minimumSize: const Size(0, 48),
              padding: EdgeInsets.zero,
            ),
            onPressed: () => setState(() => _expanded = !_expanded),
            icon: Icon(
              _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
              size: 18,
            ),
            label: Text(_expanded ? '收起长回复' : '显示完整回复'),
          ),
      ],
    );
  }

  Widget _markdownBody(
    BuildContext context,
    String data,
    TextStyle body,
    ColorScheme colors,
  ) => MarkdownBody(
    data: data.replaceAll('<', r'\<'),
    softLineBreak: true,
    fitContent: true,
    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: body,
      strong: const TextStyle(fontWeight: FontWeight.w700),
      h1: body.copyWith(fontSize: 22, fontWeight: FontWeight.w700, height: 1.3),
      h2: body.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        height: 1.35,
      ),
      h3: body.copyWith(fontSize: 17, fontWeight: FontWeight.w700, height: 1.4),
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

final class _InertAnchorBuilder extends MarkdownElementBuilder {
  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => Text(element.textContent, style: parentStyle);
}
