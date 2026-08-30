import 'package:flutter/widgets.dart';

import 'minimal_jw_runtime.dart';

/// Inherited scope exposing the one app-owned runtime to route descendants.
/// The scope carries no controller, UDF path, or platform object.
final class MinimalJwRuntimeScope extends InheritedWidget {
  const MinimalJwRuntimeScope({
    required this.runtime,
    required super.child,
    super.key,
  });

  final MinimalJwRuntime runtime;

  static MinimalJwRuntime of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<MinimalJwRuntimeScope>();
    if (scope == null) {
      throw FlutterError(
        'MinimalJwRuntimeScope.of() called without an app-owned runtime scope.',
      );
    }
    return scope.runtime;
  }

  @override
  bool updateShouldNotify(MinimalJwRuntimeScope oldWidget) =>
      !identical(runtime, oldWidget.runtime);
}
