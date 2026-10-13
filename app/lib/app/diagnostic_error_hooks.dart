import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/diagnostics_contract.dart';
import 'runtime_diagnostics.dart';

/// Captures framework/uncaught error categories, never error text or stacks.
/// Debug/test forwarding preserves the existing Flutter reporting contract.
final class DiagnosticErrorHooks {
  DiagnosticErrorHooks(this.diagnostics, {bool forwardErrors = !kReleaseMode}) {
    _previousFlutter = FlutterError.onError;
    _previousPlatform = PlatformDispatcher.instance.onError;
    _flutter = (details) {
      _record();
      if (forwardErrors) _previousFlutter?.call(details);
    };
    _platform = (error, stack) {
      _record();
      return forwardErrors
          ? _previousPlatform?.call(error, stack) ?? false
          : true;
    };
    FlutterError.onError = _flutter;
    PlatformDispatcher.instance.onError = _platform;
  }
  final DiagnosticsPort diagnostics;
  FlutterExceptionHandler? _previousFlutter;
  bool Function(Object, StackTrace)? _previousPlatform;
  late final FlutterExceptionHandler _flutter;
  late final bool Function(Object, StackTrace) _platform;
  void _record() {
    recordDiagnostic(
      diagnostics,
      const DiagnosticEvent(
        name: DiagnosticEventName.unexpectedFailure,
        stage: DiagnosticStage.ui,
        outcome: DiagnosticOutcome.failure,
        code: DiagnosticCode.unknown,
      ),
    );
    try {
      unawaited(diagnostics.flush().catchError((Object _) {}));
    } catch (_) {
      /* Logging failure is not a second app error. */
    }
  }

  void dispose() {
    if (identical(FlutterError.onError, _flutter)) {
      FlutterError.onError = _previousFlutter;
    }
    if (identical(PlatformDispatcher.instance.onError, _platform)) {
      PlatformDispatcher.instance.onError = _previousPlatform;
    }
  }
}
