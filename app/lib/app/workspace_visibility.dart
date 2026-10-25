import 'package:flutter/widgets.dart';

bool isPhoneWorkspace(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return size.shortestSide < 600 && size.width < 900;
}

/// Retained chat state must not keep a microphone active on another page.
final class WorkspaceVisibility extends InheritedWidget {
  const WorkspaceVisibility({
    super.key,
    required this.active,
    required super.child,
  });

  final bool active;

  static bool activeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<WorkspaceVisibility>()
          ?.active ??
      true;

  @override
  bool updateShouldNotify(WorkspaceVisibility oldWidget) =>
      active != oldWidget.active;
}
