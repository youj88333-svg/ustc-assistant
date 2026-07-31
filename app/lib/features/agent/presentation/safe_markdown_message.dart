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
/// - Local navigation actions ([AgentLocalAction], e.g. one per data domain
///   used in the run) are rendered as CLICKABLE `ActionChip`s below the answer.
///   The chat page routes these to the relevant management screen via GoRouter
///   (`/schedule`, the task management screen). This fixes the
///   "一堆查看日程 chip 不可点击" defect: local tools no longer spam one inert
///   chip per event; instead there is one deduplicated clickable chip per
///   data domain.
/// - Public citations ([AgentSourceReference], e.g. `campus_entry` from
///   external catalog tools) are rendered separately as NON-INTERACTIVE chips.
///   The UI only has the opaque `ref` token and `kind`, not the
///   tool-actually-returned source URL, so the chips are inert text until a
///   real ref -> source-URL resolution path exists (Task 12/13). They never
///   launch a hardcoded placeholder URL.
class SafeMarkdownMessage extends StatelessWidget {
  const SafeMarkdownMessage({
    required this.text,
    this.sourceReferences = const [],
    this.localActions = const [],
    this.onLocalAction,
    this.launcher,
    super.key,
  });

  /// The markdown text to render.
  final String text;

  /// Public citation references (e.g. `campus_entry` from external tools).
  /// Rendered as NON-INTERACTIVE chips — never clickable until a ref -> real
  /// source-URL resolution path exists.
  final List<AgentSourceReference> sourceReferences;

  /// Deduplicated local navigation actions for the run (e.g. one
  /// [AgentLocalAction.schedule] if schedule tools ran). Rendered as CLICKABLE
  /// `ActionChip`s; [onLocalAction] is invoked on tap.
  final List<AgentLocalAction> localActions;

  /// Invoked when the user taps a local-action chip. The chat page routes to
  /// the relevant management screen via GoRouter. If null, the chips render as
  /// inert `ActionChip`s (still visually distinct from `Chip` citations, but
  /// non-tappable).
  final void Function(AgentLocalActionKind kind)? onLocalAction;

  /// Reserved for future trusted citation links. Currently unused: citations
  /// are always non-interactive text until a ref -> real-source-URL resolution
  /// path exists (Task 12/13), so no URL is ever launched from here.
  final OfficialWebsiteLauncher? launcher;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty && sourceReferences.isEmpty && localActions.isEmpty) {
      return const SizedBox.shrink();
    }

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
        // Local navigation actions — CLICKABLE ActionChips routing to the
        // management screen. These are the fix for the inert-chip defect.
        if (localActions.isNotEmpty) ...[
          const SizedBox(height: 8),
          _LocalActionChips(
            actions: localActions,
            onTap: onLocalAction,
          ),
        ],
        // Public citation references — rendered as inert text.
        if (sourceReferences.isNotEmpty) ...[
          const SizedBox(height: 8),
          _SourceCitations(references: sourceReferences),
        ],
      ],
    );
  }
}

/// Renders deduplicated local navigation actions as CLICKABLE `ActionChip`s.
///
/// Tapping invokes [onLocalAction] with the action kind; the chat page routes
/// to the relevant management screen (`/schedule`, the task management screen).
/// If [onLocalAction] is null the chips are visually ActionChips but do not
/// route (e.g. in an isolated widget test that does not wire a router).
class _LocalActionChips extends StatelessWidget {
  const _LocalActionChips({required this.actions, required this.onTap});

  final List<AgentLocalAction> actions;
  final void Function(AgentLocalActionKind kind)? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final action in actions)
          ActionChip(
            label: Text(
              _localActionLabel(action),
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            onPressed: onTap == null
                ? null
                : () => onTap!(action.kind),
          ),
      ],
    );
  }

  String _localActionLabel(AgentLocalAction action) => switch (action.kind) {
        AgentLocalActionKind.schedule => '查看日程',
        AgentLocalActionKind.tasks => '查看任务',
      };
}

/// Renders trusted source reference citations as NON-INTERACTIVE chips.
///
/// The UI layer only receives the opaque `ref_*` token and the reference
/// `kind` — NOT the tool-actually-returned source URL (see
/// `AgentSourceReference`). Until a ref -> real-source-URL resolution path
/// exists, the citations are rendered as inert text. They MUST NOT launch a
/// hardcoded placeholder URL pretending to be the tool-returned source: that
/// would break citation authenticity (a "查看校园信息" chip would always open a
/// hardcoded page, not the actual source).
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

  /// Builds a friendly label from the reference kind. Local kinds (`event`,
  /// `task`) are no longer forwarded here by the session service (they use
  /// local actions instead), but the labels remain for any legacy ref that
  /// does surface.
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