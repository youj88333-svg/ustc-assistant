import 'dart:async';

/// A framework-free cancellation primitive consumed by the LLM provider.
///
/// The owner of a streaming call constructs a [CancellationSignal], hands it
/// to [LlmProvider.stream], and may call [cancel] at any later point. The
/// provider checks [isCancelled] between emitted events and stops the stream
/// cleanly; if an HTTP request is still in flight it aborts the underlying
/// streamed response so no further bytes are processed.
///
/// This class deliberately avoids Flutter and `dart:io` so it stays usable
/// across Windows and Android hosts and is unit-testable in pure Dart.
class CancellationSignal {
  CancellationSignal();

  final StreamController<void> _controller = StreamController<void>.broadcast(
    sync: true,
  );
  bool _cancelled = false;

  /// Whether [cancel] has been invoked.
  bool get isCancelled => _cancelled;

  /// A broadcast stream that emits a single `null` event when [cancel] is
  /// called. The provider may listen on this in addition to polling
  /// [isCancelled]. The stream completes when [cancel] is invoked.
  Stream<void> get onCancel => _controller.stream;

  /// Mark this signal as cancelled. Idempotent: calling more than once is a
  /// no-op after the first invocation.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _controller.add(null);
    _controller.close();
  }
}
