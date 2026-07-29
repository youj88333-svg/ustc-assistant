import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../../features/settings/presentation/official_websites_page.dart';
import '../../agent/domain/agent_tool.dart';

/// Renders model-authored markdown text safely.
///
/// Security design:
/// - Raw HTML/script is inert by default (flutter_markdown does not render it).
/// - Model-authored inline links [text](url) are rendered with onTapLink set to
///   a no-op, so they display as styled text but are NOT clickable.
/// - Trusted source references (from tool returns) are rendered separately as
///   NON-INTERACTIVE chips below the answer. The UI only has the opaque `ref`
///   token and `kind`, not the tool-actually-returned source URL, so the chips
///   are inert text until a real ref -> source-URL resolution path exists
///   (Task 12/13). They never launch a hardcoded placeholder URL.
class SafeMarkdownMessage extends StatelessWidget {
  const SafeMarkdownMessage({
    required this.text,
    this.sourceReferences = const [],
    this.launcher,
    super.key,
  });

  /// The markdown text to render.
  final String text;

  /// Trusted source references returned by tools. Only these may be clickable.
  final List<AgentSourceReference> sourceReferences;

  /// Reserved for future trusted citation links. Currently unused: citations
  /// are always non-interactive text until a ref -> real-source-URL resolution
  /// path exists (Task 12/13), so no URL is ever launched from here.
  final OfficialWebsiteLauncher? launcher;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty && sourceReferences.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Model-authored markdown — links are NOT clickable.
        if (text.isNotEmpty)
          MarkdownBody(
            data: text,
            selectable: true,
            onTapLink: (text, href, title) {
              // No-op: model-authored URLs are never clickable.
            },
          ),
        // Trusted source reference citations — rendered as inert text.
        if (sourceReferences.isNotEmpty) ...[
          const SizedBox(height: 8),
          _SourceCitations(references: sourceReferences),
        ],
      ],
    );
  }
}

/// Renders trusted source reference citations as NON-INTERACTIVE chips.
///
/// The UI layer only receives the opaque `ref_*` token and the reference
/// `kind` — NOT the tool-actually-returned source URL (see
/// `AgentSourceReference`). Until a ref -> real-source-URL resolution path
/// exists, the citations are rendered as inert text. They MUST NOT launch a
/// hardcoded placeholder URL pretending to be the tool-returned source: that
/// would break citation authenticity (a "查看日程" chip would always open the
/// JW home page, not the actual source).
class _SourceCitations extends StatelessWidget {
  const _SourceCitations({required this.references});

  final List<AgentSourceReference> references;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final ref in references)
          _buildChip(theme, ref),
      ],
    );
  }

  Widget _buildChip(ThemeData theme, AgentSourceReference ref) {
    final label = _friendlyLabel(ref);
    // Always non-interactive: a plain Chip is not tappable, so no URL is
    // launched. This holds regardless of whether a launcher is supplied.
    return Chip(
      label: Text(
        label,
        style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
      ),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
    );
  }

  /// Builds a friendly label from the reference kind.
  String _friendlyLabel(AgentSourceReference ref) {
    switch (ref.kind) {
      case 'event':
        return '查看日程';
      case 'task':
        return '查看任务';
      case 'campus_entry':
        return '查看校园信息';
      default:
        return '查看来源';
    }
  }
}