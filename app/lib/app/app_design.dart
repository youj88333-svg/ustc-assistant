import 'package:flutter/material.dart';

/// Shared presentation values. Business state continues to belong to its ports.
abstract final class AppUi {
  static const canvas = Color(0xFFFFFFFF);
  static const navigation = Color(0xFFF7F8F7);
  static const ink = Color(0xFF202825);
  static const muted = Color(0xFF65706B);
  static const accent = Color(0xFF1F6B45);
  static const line = Color(0xFFE1E7E3);
  static const controlLine = Color(0xFF87948D);
  static const subtle = Color(0xFFF5F7F6);
  static const selection = Color(0xFFEAF2ED);
  static const warning = Color(0xFF805900);
  static const error = Color(0xFFAE302D);
  static const double radius = 8;
  static const double dialogRadius = 12;
  static const double readingWidth = 920;
  static const double formWidth = 760;
}

/// A flat, transparent section. Reserve contained surfaces for actionable alerts
/// and dialogs rather than wrapping every section in another card.
class WorkspaceSection extends StatelessWidget {
  const WorkspaceSection({
    super.key,
    required this.child,
    this.title,
    this.description,
    this.trailing,
    this.padding = const EdgeInsets.symmetric(vertical: 16),
    this.divider = true,
  });

  final Widget child;
  final String? title;
  final String? description;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;
  final bool divider;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: divider
          ? const Border(bottom: BorderSide(color: AppUi.line))
          : null,
    ),
    child: Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null || trailing != null) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: title == null
                      ? const SizedBox.shrink()
                      : Text(
                          title!,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 8),
          ],
          if (description != null) ...[
            Text(description!, style: const TextStyle(color: AppUi.muted)),
            const SizedBox(height: 12),
          ],
          child,
        ],
      ),
    ),
  );
}
