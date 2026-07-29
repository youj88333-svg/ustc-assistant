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
///   clickable chips/links below the answer, launching only their https URL
///   via [launcher].
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

  /// The official website launcher for trusted citation links. When null,
  /// citations are displayed as non-interactive text.
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
        // Trusted source reference citations — only these are clickable.
        if (sourceReferences.isNotEmpty) ...[
          const SizedBox(height: 8),
          _SourceCitations(
            references: sourceReferences,
            launcher: launcher,
          ),
        ],
      ],
    );
  }
}

/// Renders trusted source reference citations as clickable chips.
///
/// Only https URLs from tool-returned references are launchable.
class _SourceCitations extends StatelessWidget {
  const _SourceCitations({
    required this.references,
    this.launcher,
  });

  final List<AgentSourceReference> references;
  final OfficialWebsiteLauncher? launcher;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final ref in references)
          _buildChip(context, theme, ref),
      ],
    );
  }

  Widget _buildChip(
    BuildContext context,
    ThemeData theme,
    AgentSourceReference ref,
  ) {
    final label = _friendlyLabel(ref);
    final uri = _uriForRef(ref);

    if (launcher == null || uri == null) {
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

    return ActionChip(
      avatar: const Icon(Icons.open_in_new, size: 14),
      label: Text(
        label,
        style: TextStyle(fontSize: 12, color: theme.colorScheme.primary),
      ),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      onPressed: () => launcher!.launch(uri),
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

  /// Builds a clickable Uri for a trusted reference, or null if the ref kind
  /// has no resolvable URL.
  Uri? _uriForRef(AgentSourceReference ref) {
    // Only known kinds with trusted https URLs are resolved.
    // The raw local id is not available here (sourceReferences carry only
    // kind+ref), so we return a safe https URL that the launcher handles.
    // For now, return the school homepage as a placeholder — Task 12/13
    // will add proper resolution when the run-reference store is available
    // at the UI layer.
    //
    // SECURITY: despite the placeholder, the key invariant holds: only the
    // launcher decides the actual URL, and only https URLs reach the user.
    switch (ref.kind) {
      case 'event':
        return Uri.https('jw.ustc.edu.cn', '/home');
      case 'task':
        return Uri.https('jw.ustc.edu.cn', '/home');
      case 'campus_entry':
        return Uri.https('www.teach.ustc.edu.cn', '/');
      default:
        return Uri.https('www.ustc.edu.cn', '/');
    }
  }
}