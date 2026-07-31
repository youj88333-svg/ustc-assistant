import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ustc_assistant_app/features/agent/application/cancellation_signal.dart';
import 'package:ustc_assistant_app/features/agent/data/anthropic_llm_provider.dart';
import 'package:ustc_assistant_app/features/agent/domain/llm_protocol.dart';

void main() {
  const apiKey = 'test-key-ephemeral';

  group('AnthropicLlmProvider headers and request body', () {
    test(
      'stream sends required headers and stream:true with model and limits',
      () async {
        final fake = _FakeClient();
        final provider = AnthropicLlmProvider(
          client: fake,
          backoff: (_) => Duration.zero,
        );
        final events = await provider
            .stream(
              apiKey: apiKey,
              request: LlmRequest(
                model: 'deepseek-v4-flash',
                messages: [LlmMessage.user(text: 'hi')],
              ),
              cancellation: CancellationSignal(),
            )
            .toList();

        expect(fake.lastRequest, isNotNull);
        final req = fake.lastRequest as http.Request;
        expect(req.method, 'POST');
        expect(req.url.toString(), 'https://api.llm.ustc.edu.cn/v1/messages');
        expect(req.headers['authorization'], 'Bearer $apiKey');
        expect(req.headers['anthropic-version'], '2023-06-01');
        expect(
          (req.headers['content-type'] ?? '').toLowerCase(),
          'application/json',
        );

        final body = jsonDecode(req.body) as Map<String, Object?>;
        expect(body['stream'], true);
        expect(body['model'], 'deepseek-v4-flash');
        expect(body['temperature'], 0.2);
        expect(body['max_tokens'], 4096);

        // Stream should end with a terminal event.
        expect(events.last, isA<CompletedEvent>());
        // At least one text delta reached us.
        expect(events.whereType<TextDeltaEvent>(), isNotEmpty);
      },
    );

    test(
      'a request with a tampered host is rejected with protocol_error',
      () async {
        final fake = _FakeClient();
        // Tamper with the origin by overriding the base via a subclass that
        // redirects to a different host. We simulate this by giving the fake
        // a response for any URL and checking that the provider itself refuses
        // to talk to a non-api host. We do this by constructing a provider with
        // an overridden origin through a test-only subclass.
        final tampered = _TamperedOriginProvider(
          client: fake,
          backoff: (_) => Duration.zero,
        );
        final events = await tampered
            .stream(
              apiKey: apiKey,
              request: LlmRequest(
                model: 'deepseek-v4-flash',
                messages: [LlmMessage.user(text: 'hi')],
              ),
              cancellation: CancellationSignal(),
            )
            .toList();
        expect(events, isNotEmpty);
        expect(events.last, isA<ErrorEvent>());
        expect((events.last as ErrorEvent).code, 'protocol_error');
        // The tampered provider must not have issued any request.
        expect(fake.lastRequest, isNull);
      },
    );
  });

  group('listModels', () {
    test('parses data[].id from GET /v1/models', () async {
      final fake = _FakeClient(defaultModelsResponse: _modelsJson);
      final provider = AnthropicLlmProvider(
        client: fake,
        backoff: (_) => Duration.zero,
      );
      final models = await provider.listModels(
        apiKey: apiKey,
        cancellation: CancellationSignal(),
      );
      expect(models, ['deepseek-v4-flash', 'deepseek-v4-pro']);
      expect(fake.lastRequest, isNotNull);
      expect(fake.lastRequest!.method, 'GET');
      expect(
        fake.lastRequest!.url.toString(),
        'https://api.llm.ustc.edu.cn/v1/models',
      );
      expect(fake.lastRequest!.headers['authorization'], 'Bearer $apiKey');
    });
  });

  group('error mapping', () {
    test('401 maps to auth_failed and is not retried', () async {
      var calls = 0;
      final fake = _FakeClient(
        responder: (req) {
          calls++;
          return _jsonResponse(401, {
            'type': 'error',
            'error': {'type': 'authentication_error'},
          });
        },
      );
      final provider = AnthropicLlmProvider(
        client: fake,
        backoff: (_) => Duration.zero,
      );
      final events = await provider
          .stream(
            apiKey: apiKey,
            request: LlmRequest(
              model: 'deepseek-v4-flash',
              messages: [LlmMessage.user(text: 'hi')],
            ),
            cancellation: CancellationSignal(),
          )
          .toList();
      expect(events.last, isA<ErrorEvent>());
      expect((events.last as ErrorEvent).code, 'auth_failed');
      expect(calls, 1, reason: '401 must not be retried');
    });

    test('403 maps to auth_failed and is not retried', () async {
      var calls = 0;
      final fake = _FakeClient(
        responder: (req) {
          calls++;
          return _jsonResponse(403, {
            'type': 'error',
            'error': {'type': 'permission_error'},
          });
        },
      );
      final provider = AnthropicLlmProvider(
        client: fake,
        backoff: (_) => Duration.zero,
      );
      final events = await provider
          .stream(
            apiKey: apiKey,
            request: LlmRequest(
              model: 'deepseek-v4-flash',
              messages: [LlmMessage.user(text: 'hi')],
            ),
            cancellation: CancellationSignal(),
          )
          .toList();
      expect((events.last as ErrorEvent).code, 'auth_failed');
      expect(calls, 1);
    });

    test(
      '429 maps to rate_limited and is retried up to twice before failing',
      () async {
        var calls = 0;
        final fake = _FakeClient(
          responder: (req) {
            calls++;
            return _jsonResponse(429, {
              'type': 'error',
              'error': {'type': 'rate_limit_error'},
            });
          },
        );
        final provider = AnthropicLlmProvider(
          client: fake,
          backoff: (_) => Duration.zero,
        );
        final events = await provider
            .stream(
              apiKey: apiKey,
              request: LlmRequest(
                model: 'deepseek-v4-flash',
                messages: [LlmMessage.user(text: 'hi')],
              ),
              cancellation: CancellationSignal(),
            )
            .toList();
        expect((events.last as ErrorEvent).code, 'rate_limited');
        // 1 initial + 2 retries = 3 total attempts.
        expect(calls, 3);
      },
    );

    test('500 maps to server_error and is retried up to twice', () async {
      var calls = 0;
      final fake = _FakeClient(
        responder: (req) {
          calls++;
          return _jsonResponse(500, {
            'type': 'error',
            'error': {'type': 'api_error'},
          });
        },
      );
      final provider = AnthropicLlmProvider(
        client: fake,
        backoff: (_) => Duration.zero,
      );
      final events = await provider
          .stream(
            apiKey: apiKey,
            request: LlmRequest(
              model: 'deepseek-v4-flash',
              messages: [LlmMessage.user(text: 'hi')],
            ),
            cancellation: CancellationSignal(),
          )
          .toList();
      expect((events.last as ErrorEvent).code, 'server_error');
      expect(calls, 3);
    });

    test('429 then success emits text and completes (retry works)', () async {
      var calls = 0;
      final fake = _FakeClient(
        responder: (req) {
          calls++;
          if (calls == 1) {
            return _jsonResponse(429, {
              'type': 'error',
              'error': {'type': 'rate_limit_error'},
            });
          }
          return _sseResponse(_okSse);
        },
      );
      final provider = AnthropicLlmProvider(
        client: fake,
        backoff: (_) => Duration.zero,
      );
      final events = await provider
          .stream(
            apiKey: apiKey,
            request: LlmRequest(
              model: 'deepseek-v4-flash',
              messages: [LlmMessage.user(text: 'hi')],
            ),
            cancellation: CancellationSignal(),
          )
          .toList();
      expect(events.whereType<TextDeltaEvent>(), isNotEmpty);
      expect(events.last, isA<CompletedEvent>());
      expect(calls, 2);
    });

    test('transport failure maps to transport_error and retries', () async {
      var calls = 0;
      final fake = _FakeClient(
        responder: (req) {
          calls++;
          throw http.ClientException('connection refused');
        },
      );
      final provider = AnthropicLlmProvider(
        client: fake,
        backoff: (_) => Duration.zero,
      );
      final events = await provider
          .stream(
            apiKey: apiKey,
            request: LlmRequest(
              model: 'deepseek-v4-flash',
              messages: [LlmMessage.user(text: 'hi')],
            ),
            cancellation: CancellationSignal(),
          )
          .toList();
      expect((events.last as ErrorEvent).code, 'transport_error');
      expect(calls, 3);
    });

    test(
      'non-SSE 200 body that cannot be parsed maps to protocol_error',
      () async {
        final fake = _FakeClient(
          responder: (req) => _buildSseResponse(
            bytes: utf8.encode('not-json-not-sse'),
            headers: {'content-type': 'application/json'},
          ),
        );
        final provider = AnthropicLlmProvider(
          client: fake,
          backoff: (_) => Duration.zero,
        );
        final events = await provider
            .stream(
              apiKey: apiKey,
              request: LlmRequest(
                model: 'deepseek-v4-flash',
                messages: [LlmMessage.user(text: 'hi')],
              ),
              cancellation: CancellationSignal(),
            )
            .toList();
        expect(events.last, isA<ErrorEvent>());
        expect((events.last as ErrorEvent).code, 'protocol_error');
      },
    );

    test('EOF without message_stop emits stream_incomplete', () async {
      final fake = _FakeClient(
        responder: (req) => _sseResponse(
          'event: message_start\n'
          'data: {"type":"message_start","message":{"usage":{"input_tokens":4}}}\n\n'
          'event: content_block_delta\n'
          'data: {"type":"content_block_delta","index":0,'
          '"delta":{"type":"text_delta","text":"partial"}}\n\n',
        ),
      );
      final provider = AnthropicLlmProvider(
        client: fake,
        backoff: (_) => Duration.zero,
      );

      final events = await provider
          .stream(
            apiKey: apiKey,
            request: LlmRequest(
              model: 'deepseek-v4-flash',
              messages: [LlmMessage.user(text: 'hi')],
            ),
            cancellation: CancellationSignal(),
          )
          .toList();

      expect(events.whereType<TextDeltaEvent>().single.text, 'partial');
      expect(events.last, isA<ErrorEvent>());
      expect((events.last as ErrorEvent).code, 'stream_incomplete');
      expect(events.whereType<CompletedEvent>(), isEmpty);
    });

    test(
      'body ClientException after content emits stream_transport_error',
      () async {
        final body = StreamController<List<int>>();
        final fake = _FakeClient(responder: (req) => _controlledResponse(body));
        final provider = AnthropicLlmProvider(
          client: fake,
          backoff: (_) => Duration.zero,
        );
        final eventsFuture = provider
            .stream(
              apiKey: apiKey,
              request: LlmRequest(
                model: 'deepseek-v4-flash',
                messages: [LlmMessage.user(text: 'hi')],
              ),
              cancellation: CancellationSignal(),
            )
            .toList();

        body.add(
          utf8.encode(
            'event: message_start\n'
            'data: {"type":"message_start"}\n\n'
            'event: content_block_delta\n'
            'data: {"type":"content_block_delta","index":0,'
            '"delta":{"type":"text_delta","text":"partial"}}\n\n',
          ),
        );
        await Future<void>.delayed(Duration.zero);
        body.addError(http.ClientException('body disconnected'));
        await body.close();

        final events = await eventsFuture.timeout(const Duration(seconds: 1));
        expect(events.whereType<TextDeltaEvent>().single.text, 'partial');
        expect(events.last, isA<ErrorEvent>());
        expect((events.last as ErrorEvent).code, 'stream_transport_error');
        expect(events.whereType<CompletedEvent>(), isEmpty);
      },
    );
  });

  group('cancellation', () {
    test('cancellation after first text event stops the stream cleanly', () async {
      final controller = StreamController<List<int>>();
      final fake = _FakeClient(
        responder: (req) => _controlledResponse(controller),
      );
      final provider = AnthropicLlmProvider(
        client: fake,
        backoff: (_) => Duration.zero,
      );
      final cancel = CancellationSignal();
      final received = <LlmEvent>[];
      final sub = provider
          .stream(
            apiKey: apiKey,
            request: LlmRequest(
              model: 'deepseek-v4-flash',
              messages: [LlmMessage.user(text: 'hi')],
            ),
            cancellation: cancel,
          )
          .listen(received.add);

      // Push one text delta, then cancel.
      controller.add(
        utf8.encode(
          'event: message_start\ndata: {"type":"message_start"}\n\n'
          'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}\n\n',
        ),
      );
      // Give the stream a turn to deliver.
      await Future<void>.delayed(Duration.zero);
      cancel.cancel();
      // Then push more data that must NOT produce events.
      controller.add(
        utf8.encode(
          'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"after-cancel"}}\n\n',
        ),
      );
      await controller.close();
      await sub
          .asFuture<void>()
          .timeout(const Duration(seconds: 1))
          .catchError((_) {});
      await Future<void>.delayed(Duration.zero);

      expect(received.whereType<TextDeltaEvent>(), isNotEmpty);
      expect(
        received.whereType<TextDeltaEvent>().map((e) => e.text),
        isNot(contains('after-cancel')),
      );
    });

    test('cancellation before any event emits nothing and stops', () async {
      final controller = StreamController<List<int>>();
      final fake = _FakeClient(
        responder: (req) => _controlledResponse(controller),
      );
      final provider = AnthropicLlmProvider(
        client: fake,
        backoff: (_) => Duration.zero,
      );
      final cancel = CancellationSignal();
      final received = <LlmEvent>[];
      final sub = provider
          .stream(
            apiKey: apiKey,
            request: LlmRequest(
              model: 'deepseek-v4-flash',
              messages: [LlmMessage.user(text: 'hi')],
            ),
            cancellation: cancel,
          )
          .listen(received.add);
      cancel.cancel();
      controller.add(
        utf8.encode('event: message_start\ndata: {"type":"message_start"}\n\n'),
      );
      await controller.close();
      await sub.asFuture<void>().catchError((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(received, isEmpty);
    });

    test('cancellation closes an idle response body and terminates', () async {
      final fake = _CloseAwareClient();
      final provider = AnthropicLlmProvider(
        client: fake,
        backoff: (_) => Duration.zero,
      );
      final cancel = CancellationSignal();
      final eventsFuture = provider
          .stream(
            apiKey: apiKey,
            request: LlmRequest(
              model: 'deepseek-v4-flash',
              messages: [LlmMessage.user(text: 'hi')],
            ),
            cancellation: cancel,
          )
          .toList();

      await fake.sent.future.timeout(const Duration(seconds: 1));
      cancel.cancel();
      final events = await eventsFuture.timeout(const Duration(seconds: 1));

      expect(fake.closed, isTrue);
      expect(events, isEmpty);
    });
  });

  group('tool JSON reassembly', () {
    test(
      'input_json_delta fragments are concatenated and parsed on stop',
      () async {
        final fake = _FakeClient(responder: (req) => _sseResponse(_toolUseSse));
        final provider = AnthropicLlmProvider(
          client: fake,
          backoff: (_) => Duration.zero,
        );
        final events = await provider
            .stream(
              apiKey: apiKey,
              request: LlmRequest(
                model: 'deepseek-v4-flash',
                messages: [LlmMessage.user(text: 'weather?')],
              ),
              cancellation: CancellationSignal(),
            )
            .toList();
        final tool = events.whereType<ToolUseCompletedEvent>().toList();
        expect(tool, hasLength(1));
        expect(tool.single.id, 'tool_1');
        expect(tool.single.name, 'get_weather');
        expect(tool.single.input, {'city': 'Hefei'});
        expect(events.last, isA<CompletedEvent>());
      },
    );

    test('invalid reassembled tool JSON maps to tool_input_invalid', () async {
      final fake = _FakeClient(
        responder: (req) => _sseResponse(_invalidToolUseSse),
      );
      final provider = AnthropicLlmProvider(
        client: fake,
        backoff: (_) => Duration.zero,
      );
      final events = await provider
          .stream(
            apiKey: apiKey,
            request: LlmRequest(
              model: 'deepseek-v4-flash',
              messages: [LlmMessage.user(text: 'weather?')],
            ),
            cancellation: CancellationSignal(),
          )
          .toList();
      expect(events.last, isA<ErrorEvent>());
      expect((events.last as ErrorEvent).code, 'tool_input_invalid');
      // The raw fragment text must not leak into the event.
      final err = events.last as ErrorEvent;
      expect(err.code, 'tool_input_invalid');
      expect(err.toString(), isNot(contains('not-json')));
    });

    test(
      'usage follows Anthropic message_start and message_delta fields',
      () async {
        final fake = _FakeClient(
          responder: (req) => _sseResponse(_standardUsageSse),
        );
        final provider = AnthropicLlmProvider(
          client: fake,
          backoff: (_) => Duration.zero,
        );
        final events = await provider
            .stream(
              apiKey: apiKey,
              request: LlmRequest(
                model: 'deepseek-v4-flash',
                messages: [LlmMessage.user(text: 'hi')],
              ),
              cancellation: CancellationSignal(),
            )
            .toList();
        final usage = events.whereType<UsageEvent>().toList();
        expect(usage.any((event) => event.inputTokens == 10), isTrue);
        expect(usage.any((event) => event.outputTokens == 5), isTrue);
      },
    );
  });

  group('probes', () {
    test('probeText succeeds when stream completes with text', () async {
      final fake = _FakeClient(responder: (req) => _sseResponse(_okSse));
      final provider = AnthropicLlmProvider(
        client: fake,
        backoff: (_) => Duration.zero,
      );
      await provider.probeText(
        apiKey: apiKey,
        model: 'deepseek-v4-flash',
        cancellation: CancellationSignal(),
      );
      // Assert the request body used a small max_tokens.
      final req = fake.lastRequest as http.Request;
      final body = jsonDecode(req.body) as Map<String, Object?>;
      expect(body['max_tokens'], lessThan(4096));
      expect(body['stream'], true);
    });

    test('probeText throws on error event', () async {
      final fake = _FakeClient(
        responder: (req) => _jsonResponse(401, {'type': 'error'}),
      );
      final provider = AnthropicLlmProvider(
        client: fake,
        backoff: (_) => Duration.zero,
      );
      await expectLater(
        provider.probeText(
          apiKey: apiKey,
          model: 'deepseek-v4-flash',
          cancellation: CancellationSignal(),
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('probeTools succeeds when the probe tool is emitted', () async {
      final fake = _FakeClient(responder: (req) => _sseResponse(_probeToolSse));
      final provider = AnthropicLlmProvider(
        client: fake,
        backoff: (_) => Duration.zero,
      );
      await provider.probeTools(
        apiKey: apiKey,
        model: 'deepseek-v4-flash',
        cancellation: CancellationSignal(),
      );
      final req = fake.lastRequest as http.Request;
      final body = jsonDecode(req.body) as Map<String, Object?>;
      expect(body['stream'], true);
      final tools = body['tools'] as List<Object?>;
      expect(tools, hasLength(1));
      expect(
        (tools.first as Map<String, Object?>)['name'],
        'ustc_agent_capability_probe',
      );
    });

    test('probeTools throws when the tool is not emitted', () async {
      final fake = _FakeClient(responder: (req) => _sseResponse(_okSse));
      final provider = AnthropicLlmProvider(
        client: fake,
        backoff: (_) => Duration.zero,
      );
      await expectLater(
        provider.probeTools(
          apiKey: apiKey,
          model: 'deepseek-v4-flash',
          cancellation: CancellationSignal(),
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('probeTools rejects an exact probe call with ok false', () async {
      final fake = _FakeClient(
        responder: (req) => _sseResponse(
          _probeToolSse.replaceFirst(r'{\"ok\":true}', r'{\"ok\":false}'),
        ),
      );
      final provider = AnthropicLlmProvider(
        client: fake,
        backoff: (_) => Duration.zero,
      );

      await expectLater(
        provider.probeTools(
          apiKey: apiKey,
          model: 'deepseek-v4-flash',
          cancellation: CancellationSignal(),
        ),
        throwsA(
          isA<LlmProtocolException>().having(
            (e) => e.code,
            'code',
            'probe_tool_invalid_input',
          ),
        ),
      );
    });

    test('probeTools rejects a tool call followed by a stream error', () async {
      final fake = _FakeClient(
        responder: (req) => _sseResponse(
          _probeToolSse.replaceFirst(
            'event: message_stop\n'
                'data: {"type":"message_stop"}',
            'event: error\n'
                'data: {"type":"error","error":{"type":"overloaded_error"}}',
          ),
        ),
      );
      final provider = AnthropicLlmProvider(
        client: fake,
        backoff: (_) => Duration.zero,
      );

      await expectLater(
        provider.probeTools(
          apiKey: apiKey,
          model: 'deepseek-v4-flash',
          cancellation: CancellationSignal(),
        ),
        throwsA(
          isA<LlmProtocolException>().having(
            (e) => e.code,
            'code',
            'server_error',
          ),
        ),
      );
    });

    test(
      'probeText throws LlmProtocolException (not StateError) when the '
      'stream closes empty because cancellation fired before the first event',
      () async {
        // With a pre-cancelled signal the provider's _runStream returns at
        // the top of its loop without ever calling send, so the LlmEvent
        // stream closes empty and the probe sees an empty event list.
        final fake = _FakeClient();
        final provider = AnthropicLlmProvider(
          client: fake,
          backoff: (_) => Duration.zero,
        );
        final cancellation = CancellationSignal()..cancel();
        await expectLater(
          provider.probeText(
            apiKey: apiKey,
            model: 'deepseek-v4-flash',
            cancellation: cancellation,
          ),
          throwsA(
            isA<LlmProtocolException>().having(
              (e) => e.code,
              'code',
              'probe_incomplete',
            ),
          ),
        );
      },
    );
  });

  test('API key is never stored in a field that outlives the call', () async {
    final fake = _FakeClient(responder: (req) => _sseResponse(_okSse));
    final provider = AnthropicLlmProvider(
      client: fake,
      backoff: (_) => Duration.zero,
    );
    await provider
        .stream(
          apiKey: apiKey,
          request: LlmRequest(
            model: 'deepseek-v4-flash',
            messages: [LlmMessage.user(text: 'hi')],
          ),
          cancellation: CancellationSignal(),
        )
        .toList();
    // The provider must not retain the key on any inspectable field. The class
    // has no public apiKey field, so this is a structural assertion: ensure
    // there is no getter that returns the key.
    expect(provider.apiKey, isNull);
  });
}

// ---------------------------------------------------------------------------
// Fake HTTP client and helpers.
// ---------------------------------------------------------------------------

class _FakeClient extends http.BaseClient {
  _FakeClient({this.responder, this.defaultModelsResponse});

  /// Returns a synchronous [http.StreamedResponse]; the fake wraps it in a
  /// future in [send]. This keeps test call sites tidy.
  final http.StreamedResponse Function(http.BaseRequest)? responder;
  final String? defaultModelsResponse;

  http.BaseRequest? lastRequest;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    lastRequest = request;
    if (responder != null) {
      return Future.value(responder!(request));
    }
    // Default: a successful SSE stream for messages, models JSON for models.
    if (request.url.path.endsWith('/v1/models')) {
      return Future.value(
        _modelsStreamedResponse(defaultModelsResponse ?? _modelsJson),
      );
    }
    return Future.value(_sseResponse(_okSse));
  }
}

class _CloseAwareClient extends http.BaseClient {
  final sent = Completer<void>();
  final StreamController<List<int>> _body = StreamController<List<int>>();
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!sent.isCompleted) sent.complete();
    return _controlledResponse(_body);
  }

  @override
  void close() {
    if (closed) return;
    closed = true;
    _body.addError(http.ClientException('cancelled'));
    unawaited(_body.close());
  }
}

/// A provider subclass that points at a tampered host to prove the provider
/// refuses non-api origins.
class _TamperedOriginProvider extends AnthropicLlmProvider {
  _TamperedOriginProvider({required super.client, required super.backoff})
    : super.test(origin: Uri.parse('https://evil.example.com'));
}

http.StreamedResponse _sseResponse(String sse) => _buildSseResponse(
  bytes: utf8.encode(sse),
  headers: {'content-type': 'text/event-stream'},
);

http.StreamedResponse _jsonResponse(int status, Map<String, Object?> body) =>
    _buildSseResponse(
      status: status,
      bytes: utf8.encode(jsonEncode(body)),
      headers: {'content-type': 'application/json'},
    );

http.StreamedResponse _modelsStreamedResponse(String body) => _buildSseResponse(
  bytes: utf8.encode(body),
  headers: {'content-type': 'application/json'},
);

http.StreamedResponse _buildSseResponse({
  int status = 200,
  required List<int> bytes,
  Map<String, String> headers = const {},
  StreamController<List<int>>? streamController,
}) {
  final controller = streamController ?? StreamController<List<int>>();
  final response = http.StreamedResponse(
    controller.stream,
    status,
    headers: headers,
  );
  if (streamController == null) {
    controller.add(bytes);
    controller.close();
  }
  return response;
}

/// Builds a [http.StreamedResponse] whose body is controlled by the supplied
/// controller. The returned future-completed variant is used by cancellation
/// tests that need to push bytes incrementally.
http.StreamedResponse _controlledResponse(
  StreamController<List<int>> controller, {
  int status = 200,
  Map<String, String> headers = const {'content-type': 'text/event-stream'},
}) => http.StreamedResponse(controller.stream, status, headers: headers);

const _modelsJson =
    '{"data":[{"id":"deepseek-v4-flash"},'
    '{"id":"deepseek-v4-pro"}]}';

const _okSse = '''event: message_start
data: {"type":"message_start","message":{"id":"msg_1","model":"deepseek-v4-flash"}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"OK"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":10,"output_tokens":5}}

event: message_stop
data: {"type":"message_stop"}

''';

const _standardUsageSse = '''event: message_start
data: {"type":"message_start","message":{"id":"msg_usage","model":"deepseek-v4-flash","usage":{"input_tokens":10,"output_tokens":0}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"OK"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}

event: message_stop
data: {"type":"message_stop"}

''';

const _toolUseSse = '''event: message_start
data: {"type":"message_start","message":{"id":"msg_2","model":"deepseek-v4-flash"}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool_1","name":"get_weather","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"city\\":"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\\"Hefei\\"}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"input_tokens":3,"output_tokens":7}}

event: message_stop
data: {"type":"message_stop"}

''';

const _invalidToolUseSse = '''event: message_start
data: {"type":"message_start","message":{"id":"msg_3","model":"deepseek-v4-flash"}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool_2","name":"get_weather","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"not-json"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_stop
data: {"type":"message_stop"}

''';

const _probeToolSse = '''event: message_start
data: {"type":"message_start","message":{"id":"msg_4","model":"deepseek-v4-flash"}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool_p","name":"ustc_agent_capability_probe","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"ok\\":true}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"input_tokens":2,"output_tokens":3}}

event: message_stop
data: {"type":"message_stop"}

''';
