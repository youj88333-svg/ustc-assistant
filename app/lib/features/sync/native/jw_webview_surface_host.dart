import 'dart:async';

import 'package:flutter/material.dart';

import 'jw_web_session.dart';

/// Keeps a native JW WebView surface mounted for exactly one controller at a
/// time, and exposes completion only after Flutter has rendered its
/// placeholder during detach.
final class JwWebViewSurfaceHost {
  JwWebViewSurfaceHost({this.onDetachRequested}) {
    widget = _JwSurfaceWidget(host: this);
  }

  /// Optional privacy-safe test/diagnostic seam invoked synchronously after
  /// the source is cleared and before the detach acknowledgement is awaited.
  /// It carries the controller object only so tests can identify the source;
  /// callers must not inspect or log controller internals.
  final void Function(JwWebviewController controller)? onDetachRequested;

  late final Widget widget;
  JwWebviewController? _controller;
  VoidCallback? _notify;
  Completer<void>? _pendingUnmount;
  JwWebviewController? _pendingSource;
  int _generation = 0;
  int? _pendingGeneration;
  int? _scheduledUnmountGeneration;

  bool get isAttached => _controller != null;

  Future<void> attach(JwWebviewController controller) async {
    final pending = _pendingUnmount;
    if (pending != null) await pending.future;
    if (_controller != null && !identical(_controller, controller)) {
      throw StateError('A WebView surface is already attached.');
    }
    _generation++;
    _controller = controller;
    _notify?.call();
  }

  Future<void> detachAndAwaitUnmount(JwWebviewController controller) async {
    final pending = _pendingUnmount;
    if (pending != null && identical(_pendingSource, controller)) {
      return pending.future;
    }
    if (!identical(_controller, controller)) return;
    _generation++;
    _controller = null;
    if (_notify == null) return;
    final completer = Completer<void>();
    _pendingUnmount = completer;
    _pendingSource = controller;
    _pendingGeneration = _generation;
    try {
      onDetachRequested?.call(controller);
      _notify!.call();
    } on Object catch (error, stackTrace) {
      // The source was already removed before the callback. Complete and
      // clear the pending state on callback/notification failure so a later
      // attach/detach can retry without a stranded host.
      _completePendingUnmount();
      Error.throwWithStackTrace(error, stackTrace);
    }
    return completer.future;
  }

  Widget _buildSurface() {
    final controller = _controller;
    if (controller != null) return controller.surface;

    final pendingGeneration = _pendingGeneration;
    if (pendingGeneration != null &&
        _scheduledUnmountGeneration != pendingGeneration) {
      _scheduledUnmountGeneration = pendingGeneration;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pendingGeneration == pendingGeneration) {
          _completePendingUnmount();
        }
      });
    }
    return const SizedBox(key: Key('jw-webview-surface-placeholder'));
  }

  void _completePendingUnmount() {
    final completer = _pendingUnmount;
    _pendingUnmount = null;
    _pendingSource = null;
    _pendingGeneration = null;
    _scheduledUnmountGeneration = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }
}

final class _JwSurfaceWidget extends StatefulWidget {
  const _JwSurfaceWidget({required this.host});

  final JwWebViewSurfaceHost host;

  @override
  State<_JwSurfaceWidget> createState() => _JwSurfaceWidgetState();
}

final class _JwSurfaceWidgetState extends State<_JwSurfaceWidget> {
  late final VoidCallback _listener = _notify;

  @override
  void initState() {
    super.initState();
    widget.host._notify = _listener;
  }

  void _notify() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => widget.host._buildSurface();

  @override
  void dispose() {
    if (identical(widget.host._notify, _listener)) {
      widget.host._notify = null;
    }
    widget.host._completePendingUnmount();
    super.dispose();
  }
}
