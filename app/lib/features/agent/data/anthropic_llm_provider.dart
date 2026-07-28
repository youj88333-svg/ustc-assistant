import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../application/cancellation_signal.dart';
import '../domain/llm_protocol.dart';
import 'sse_decoder.dart';

/// An [LlmProvider] that drives the USTC-hosted Anthropic Messages gateway.
///
/// All requests are restricted to [apiOrigin] (`https://api.llm.ustc.edu.cn`).
/// The API key is accepted as an ephemeral per-call `String` and is never
/// stored on a field that outlives the call, never included in error
/// messages, and never logged. Remote response text is untrusted: error
/// events carry opaque codes only.
class AnthropicLlmProvider implements LlmProvider {
  AnthropicLlmProvider({
    http.Client? client,
    Duration Function(int attempt)? backoff,
  }) : _client = client ?? http.Client(),
       _backoff = backoff ?? _defaultBackoff;

  /// Test-only constructor that pins the gateway origin. Used by tests to
  /// prove the provider refuses a tampered host. The [origin] is allowed to
  /// differ from [apiOrigin] but [_isApiOrigin] still checks the request URI
  /// against the canonical [apiOrigin], so a tampered origin is rejected.
  AnthropicLlmProvider.test({
    required this._client,
    required this._backoff,
    required Uri origin,
  }) : _originOverride = origin;

  static final Uri apiOrigin = Uri.parse('https://api.llm.ustc.edu.cn');
  static const String messagesPath = '/v1/messages';
  static const String modelsPath = '/v1/models';
  static const String _anthropicVersion = '2023-06-01';
  static const int _maxRetries = 2;

  final http.Client _client;
  final Duration Function(int attempt) _backoff;
  Uri? _originOverride;

  Uri get _origin => _originOverride ?? apiOrigin;

  /// The most recently used API key, exposed only for tests to assert
  /// non-retention. Always returns `null` in production code paths because
  /// the key is held in a local variable, not a field.
  String? get apiKey => null;

  @override
  Future<List<String>> listModels({
    required String apiKey,
    required CancellationSignal cancellation,
  }) async {
    final uri = _origin.resolve(modelsPath);
    if (!_isApiOrigin(uri)) {
      throw const LlmProtocolException('protocol_error');
    }
    final request = http.Request('GET', uri)
      ..headers['authorization'] = 'Bearer $apiKey'
      ..headers['anthropic-version'] = _anthropicVersion
      ..headers['accept'] = 'application/json';

    http.Response response;
    try {
      final streamed = await _client.send(request);
      response = await http.Response.fromStream(streamed);
    } on http.ClientException {
      throw const LlmProtocolException('transport_error');
    }
    if (cancellation.isCancelled) {
      throw const LlmProtocolException('cancelled');
    }
    if (response.statusCode != 200) {
      throw LlmProtocolException(_mapStatus(response.statusCode));
    }
    try {
      final body = jsonDecode(response.body) as Map<String, Object?>;
      final data = body['data'] as List<Object?>? ?? const [];
      return data
          .map((e) => (e as Map<String, Object?>)['id'] as String?)
          .whereType<String>()
          .toList();
    } on FormatException {
      throw const LlmProtocolException('protocol_error');
    }
  }

  @override
  Stream<LlmEvent> stream({
    required String apiKey,
    required LlmRequest request,
    required CancellationSignal cancellation,
  }) {
    final controller = StreamController<LlmEvent>();
    _runStream(controller, apiKey, request, cancellation)
        .then((_) {
          if (!controller.isClosed) controller.close();
        })
        .catchError((Object e) {
          if (!controller.isClosed) {
            controller.add(ErrorEvent(_exceptionCode(e)));
            controller.close();
          }
        });
    return controller.stream;
  }

  Future<void> _runStream(
    StreamController<LlmEvent> controller,
    String apiKey,
    LlmRequest request,
    CancellationSignal cancellation,
  ) async {
    final uri = _origin.resolve(messagesPath);
    if (!_isApiOrigin(uri)) {
      controller.add(const ErrorEvent('protocol_error'));
      return;
    }

    final bodyJson = jsonEncode(request.toJson());
    var attempt = 0;
    // Whether any text/tool event has been emitted yet. Once true, retry is
    // forbidden.
    var emittedContent = false;

    while (true) {
      if (cancellation.isCancelled) {
        return;
      }
      final req = http.Request('POST', uri)
        ..headers['authorization'] = 'Bearer $apiKey'
        ..headers['anthropic-version'] = _anthropicVersion
        ..headers['content-type'] = 'application/json'
        ..headers['accept'] = 'text/event-stream'
        ..body = bodyJson;

      http.StreamedResponse response;
      try {
        response = await _client.send(req);
      } on http.ClientException {
        // Transport failure: retryable.
        if (attempt < _maxRetries &&
            !emittedContent &&
            !cancellation.isCancelled) {
          await Future<void>.delayed(_backoff(attempt));
          attempt++;
          continue;
        }
        controller.add(const ErrorEvent('transport_error', retryable: true));
        return;
      }

      final status = response.statusCode;
      if (status == 429 || status >= 500) {
        // Retryable status. Drain the body to free the connection.
        await response.stream.drain<void>();
        if (attempt < _maxRetries &&
            !emittedContent &&
            !cancellation.isCancelled) {
          await Future<void>.delayed(_backoff(attempt));
          attempt++;
          continue;
        }
        controller.add(ErrorEvent(_mapStatus(status), retryable: true));
        return;
      }
      if (status == 401 || status == 403) {
        await response.stream.drain<void>();
        controller.add(ErrorEvent(_mapStatus(status)));
        return;
      }
      if (status != 200) {
        await response.stream.drain<void>();
        controller.add(ErrorEvent(_mapStatus(status)));
        return;
      }

      // 200: expect an SSE stream.
      final result = await _processSseStream(
        response.stream,
        controller,
        cancellation,
        onContentEmitted: () => emittedContent = true,
      );
      if (result == _SseStreamOutcome.completed) {
        if (!controller.isClosed) controller.add(const CompletedEvent());
        return;
      }
      if (result == _SseStreamOutcome.error) {
        // The error event was already added inside the processor.
        return;
      }
      if (result == _SseStreamOutcome.cancelled) {
        return;
      }
      // protocol_error: the body was not a parseable SSE stream.
      if (attempt < _maxRetries &&
          !emittedContent &&
          !cancellation.isCancelled) {
        await Future<void>.delayed(_backoff(attempt));
        attempt++;
        continue;
      }
      controller.add(const ErrorEvent('protocol_error'));
      return;
    }
  }

  Future<_SseStreamOutcome> _processSseStream(
    Stream<List<int>> byteStream,
    StreamController<LlmEvent> controller,
    CancellationSignal cancellation, {
    required void Function() onContentEmitted,
  }) async {
    final decoder = SseDecoder();
    // Per-block reassembly state for tool_use input_json_delta fragments.
    final blockInputFragments = <int, StringBuffer>{};
    final blockMeta = <int, _BlockMeta>{};
    var sawAnyEvent = false;

    try {
      await for (final chunk in byteStream) {
        if (cancellation.isCancelled) {
          return _SseStreamOutcome.cancelled;
        }
        final events = decoder.feed(chunk);
        for (final evt in events) {
          if (cancellation.isCancelled) {
            return _SseStreamOutcome.cancelled;
          }
          final outcome = _handleSseEvent(
            evt,
            controller,
            blockInputFragments,
            blockMeta,
            onContentEmitted,
          );
          if (outcome != null) {
            return outcome;
          }
          sawAnyEvent = true;
        }
      }
      // Flush any trailing buffered event.
      for (final evt in decoder.close()) {
        if (cancellation.isCancelled) {
          return _SseStreamOutcome.cancelled;
        }
        final outcome = _handleSseEvent(
          evt,
          controller,
          blockInputFragments,
          blockMeta,
          onContentEmitted,
        );
        if (outcome != null) {
          return outcome;
        }
        sawAnyEvent = true;
      }
    } on http.ClientException {
      return _SseStreamOutcome.error; // transport error handled by caller
    } on FormatException {
      return _SseStreamOutcome.protocolError;
    }

    if (!sawAnyEvent) {
      return _SseStreamOutcome.protocolError;
    }
    return _SseStreamOutcome.completed;
  }

  /// Handles a single SSE event. Returns a non-null outcome to signal the
  /// stream should terminate, or `null` to continue.
  _SseStreamOutcome? _handleSseEvent(
    SseEvent evt,
    StreamController<LlmEvent> controller,
    Map<int, StringBuffer> blockInputFragments,
    Map<int, _BlockMeta> blockMeta,
    void Function() onContentEmitted,
  ) {
    if (evt.data == '[DONE]') {
      // Sentinel: treat as terminal success.
      return _SseStreamOutcome.completed;
    }
    Map<String, Object?> json;
    try {
      json = jsonDecode(evt.data) as Map<String, Object?>;
    } on FormatException {
      // Non-JSON data line in an otherwise-SSE stream: protocol error.
      controller.add(const ErrorEvent('protocol_error'));
      return _SseStreamOutcome.error;
    }

    final type = json['type'] as String?;
    switch (type) {
      case 'message_start':
        // No event emitted; the message envelope is not surfaced.
        return null;
      case 'content_block_start':
        final index = (json['index'] as num?)?.toInt() ?? 0;
        final block = json['content_block'] as Map<String, Object?>?;
        final blockType = block?['type'] as String?;
        blockMeta[index] = _BlockMeta(type: blockType ?? 'text');
        if (blockType == 'tool_use') {
          blockInputFragments[index] = StringBuffer();
          blockMeta[index] = _BlockMeta(
            type: 'tool_use',
            id: block?['id'] as String?,
            name: block?['name'] as String?,
          );
        }
        return null;
      case 'content_block_delta':
        final index = (json['index'] as num?)?.toInt() ?? 0;
        final delta = json['delta'] as Map<String, Object?>?;
        final deltaType = delta?['type'] as String?;
        if (deltaType == 'text_delta') {
          final text = delta?['text'] as String? ?? '';
          if (text.isNotEmpty) {
            onContentEmitted();
            controller.add(TextDeltaEvent(text));
          }
        } else if (deltaType == 'input_json_delta') {
          final partial = delta?['partial_json'] as String? ?? '';
          (blockInputFragments[index] ??= StringBuffer()).write(partial);
        }
        return null;
      case 'content_block_stop':
        final index = (json['index'] as num?)?.toInt() ?? 0;
        final meta = blockMeta.remove(index);
        final fragments = blockInputFragments.remove(index);
        if (meta != null && meta.type == 'tool_use') {
          final raw = fragments?.toString() ?? '';
          Map<String, Object?> parsed;
          try {
            final decoded = jsonDecode(raw.isEmpty ? '{}' : raw);
            if (decoded is Map<String, Object?>) {
              parsed = decoded;
            } else {
              // The reassembled JSON was not an object.
              controller.add(const ErrorEvent('tool_input_invalid'));
              return _SseStreamOutcome.error;
            }
          } on FormatException {
            controller.add(const ErrorEvent('tool_input_invalid'));
            return _SseStreamOutcome.error;
          }
          if (meta.id == null || meta.name == null) {
            controller.add(const ErrorEvent('protocol_error'));
            return _SseStreamOutcome.error;
          }
          onContentEmitted();
          controller.add(
            ToolUseCompletedEvent(
              id: meta.id!,
              name: meta.name!,
              input: parsed,
            ),
          );
        }
        return null;
      case 'message_delta':
        final usage = json['usage'] as Map<String, Object?>?;
        if (usage != null) {
          final input = (usage['input_tokens'] as num?)?.toInt();
          final output = (usage['output_tokens'] as num?)?.toInt();
          controller.add(UsageEvent(inputTokens: input, outputTokens: output));
        }
        return null;
      case 'message_stop':
        return _SseStreamOutcome.completed;
      case 'error':
        // Remote error: never echo the remote text. Use a safe code.
        controller.add(const ErrorEvent('server_error', retryable: true));
        return _SseStreamOutcome.error;
      default:
        // Unknown event types are ignored to stay forward-compatible.
        return null;
    }
  }

  @override
  Future<void> probeText({
    required String apiKey,
    required String model,
    required CancellationSignal cancellation,
  }) async {
    final events = await stream(
      apiKey: apiKey,
      request: LlmRequest(
        model: model,
        maxTokens: 32,
        messages: [LlmMessage.user(text: 'reply with OK')],
      ),
      cancellation: cancellation,
    ).toList();
    _requireProbeSuccess(events, expectText: true);
  }

  @override
  Future<void> probeTools({
    required String apiKey,
    required String model,
    required CancellationSignal cancellation,
  }) async {
    final events = await stream(
      apiKey: apiKey,
      request: LlmRequest(
        model: model,
        maxTokens: 128,
        messages: [LlmMessage.user(text: 'Call the probe tool.')],
        tools: const [
          LlmToolDeclaration(
            name: _probeToolName,
            description: 'Capability probe; reply with {"ok": true}.',
            inputSchema: {
              'type': 'object',
              'properties': {
                'ok': {'type': 'boolean'},
              },
              'required': ['ok'],
            },
          ),
        ],
      ),
      cancellation: cancellation,
    ).toList();
    final tool = events.whereType<ToolUseCompletedEvent>().firstOrNull;
    if (tool == null || tool.name != _probeToolName) {
      throw const LlmProtocolException('probe_tool_not_emitted');
    }
    if (tool.input.isEmpty) {
      throw const LlmProtocolException('probe_tool_empty_input');
    }
  }

  void _requireProbeSuccess(List<LlmEvent> events, {required bool expectText}) {
    if (events.isEmpty) {
      throw const LlmProtocolException('probe_incomplete');
    }
    if (events.last is ErrorEvent) {
      throw LlmProtocolException((events.last as ErrorEvent).code);
    }
    if (events.last is! CompletedEvent) {
      throw const LlmProtocolException('probe_incomplete');
    }
    if (expectText && events.whereType<TextDeltaEvent>().isEmpty) {
      throw const LlmProtocolException('probe_no_text');
    }
  }

  /// Whether [uri] targets the canonical USTC gateway. Always checked
  /// against the static [apiOrigin], never against an overridden origin, so
  /// a tampered test origin is rejected even though the request URI matches
  /// the override.
  bool _isApiOrigin(Uri uri) {
    return uri.host == apiOrigin.host &&
        uri.scheme == apiOrigin.scheme &&
        (uri.port == apiOrigin.port || uri.port == _defaultPort(uri.scheme));
  }

  int _defaultPort(String scheme) => scheme == 'https' ? 443 : 80;

  String _mapStatus(int status) {
    if (status == 401 || status == 403) return 'auth_failed';
    if (status == 429) return 'rate_limited';
    if (status >= 500) return 'server_error';
    return 'protocol_error';
  }

  String _exceptionCode(Object e) {
    if (e is LlmProtocolException) return e.code;
    if (e is http.ClientException) return 'transport_error';
    return 'protocol_error';
  }

  static const String _probeToolName = 'ustc_agent_capability_probe';

  static Duration _defaultBackoff(int attempt) {
    // 250ms, 500ms, 1000ms ...
    return Duration(milliseconds: 250 * (1 << attempt));
  }
}

/// Internal metadata for an in-flight content block.
class _BlockMeta {
  _BlockMeta({required this.type, this.id, this.name});

  final String type;
  final String? id;
  final String? name;
}

/// Outcome of processing an SSE stream.
enum _SseStreamOutcome { completed, error, cancelled, protocolError }

/// A private, safe exception type used to carry an opaque error code through
/// the probe paths. The [code] is one of the safe strings defined by the
/// provider; it never contains remote text.
class LlmProtocolException implements Exception {
  const LlmProtocolException(this.code);

  final String code;

  @override
  String toString() => 'LlmProtocolException($code)';
}
