import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/agent/ustc_model_gateway.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';

void main() {
  group('UstcModelGateway', () {
    late _Server server;

    setUp(() {
      server = _Server();
    });

    tearDown(() async {
      await server.close();
    });

    test(
      'only the registered school alias receives high on every request',
      () async {
        final bodies = <Map<String, dynamic>>[];
        await server.start((request) async {
          bodies.add(
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>,
          );
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          request.response.write(
            'data: {"choices":[{"index":0,"delta":{"content":"合成回复"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
          );
          await request.response.close();
        });
        final gateway = server.gateway();
        addTearDown(gateway.close);
        for (final model in [
          'deepseek-flash',
          'deepseek-flash-2',
          'deepseek-v4-flash',
          'synthetic-model',
          'DeepSeek-Flash',
          'deepseek-flash-unverified',
        ]) {
          await gateway
              .generate(
                ModelRequest(
                  modelId: model,
                  messages: [
                    ModelChatMessage(role: 'system', content: '合成任务'),
                    ModelChatMessage(role: 'user', content: '合成输入'),
                  ],
                ),
                _key(),
              )
              .drain<void>();
        }
        expect(bodies.first['reasoning_effort'], 'high');
        expect(
          bodies.skip(1).every((body) => !body.containsKey('reasoning_effort')),
          isTrue,
        );
        for (final body in bodies) {
          expect(
            body.keys.toSet(),
            body['model'] == 'deepseek-flash'
                ? {
                    'model',
                    'messages',
                    'stream',
                    'max_tokens',
                    'reasoning_effort',
                  }
                : {'model', 'messages', 'stream', 'max_tokens'},
          );
          expect(body.containsKey('thinking'), isFalse);
          expect(body.containsKey('chat_template_kwargs'), isFalse);
        }
      },
    );

    test(
      'an explicit effort rejection is visible and is never retried at another level',
      () async {
        var requests = 0;
        await server.start((request) async {
          requests++;
          await utf8.decoder.bind(request).join();
          request.response.statusCode = 400;
          request.response.write(
            jsonEncode({
              'error': {
                'param': 'reasoning_effort',
                'code': 'unsupported_parameter',
                'message': 'PRIVATE_PROVIDER_TEXT',
              },
            }),
          );
          await request.response.close();
        });
        final gateway = server.gateway();
        addTearDown(gateway.close);
        await expectLater(
          gateway
              .generate(
                ModelRequest(
                  modelId: 'deepseek-flash',
                  messages: [ModelChatMessage(role: 'user', content: '合成请求')],
                ),
                _key(),
              )
              .toList(),
          throwsA(_failure(AgentFailureCode.reasoningRejected)),
        );
        expect(requests, 1);
      },
    );

    test(
      'active PNG input uses a data URL in user content without another upload endpoint',
      () async {
        const png =
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZgdwAAAAASUVORK5CYII=';
        Map<String, dynamic>? body;
        await server.start((request) async {
          expect(request.uri.path, '/v1/chat/completions');
          body =
              jsonDecode(await utf8.decoder.bind(request).join())
                  as Map<String, dynamic>;
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          request.response.write(
            'data: {"choices":[{"index":0,"delta":{"content":"合成图片描述"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
          );
          await request.response.close();
        });
        final gateway = server.gateway();
        final request = ModelRequest(
          modelId: 'synthetic-vision',
          messages: [
            ModelChatMessage(
              role: 'user',
              content: '看图',
              images: [AgentImage(Uint8List.fromList(base64Decode(png)))],
            ),
          ],
        );
        final events = await gateway.generate(request, _key()).toList();
        expect(events.whereType<ModelCompleted>().single.finishReason, 'stop');
        final content =
            ((body!['messages'] as List).single as Map)['content'] as List;
        expect(content.first, {'type': 'text', 'text': '看图'});
        expect((content[1] as Map)['image_url'], {
          'url': 'data:image/png;base64,$png',
          'detail': 'auto',
        });
        expect(body!.keys, isNot(contains('files')));
        await gateway.close();
      },
    );

    test(
      'image rejection is explicit and does not silently resend only text',
      () async {
        var requests = 0;
        await server.start((request) async {
          requests++;
          await utf8.decoder.bind(request).join();
          request.response.statusCode = 415;
          request.response.write('synthetic raw error, never surfaced');
          await request.response.close();
        });
        final gateway = server.gateway();
        const png =
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZgdwAAAAASUVORK5CYII=';
        await expectLater(
          gateway
              .generate(
                ModelRequest(
                  modelId: 'synthetic-vision',
                  messages: [
                    ModelChatMessage(
                      role: 'user',
                      content: '看图',
                      images: [
                        AgentImage(Uint8List.fromList(base64Decode(png))),
                      ],
                    ),
                  ],
                ),
                _key(),
              )
              .toList(),
          throwsA(_failure(AgentFailureCode.imageRejected)),
        );
        expect(requests, 1);
        await gateway.close();
      },
    );

    test(
      'uses the fixed models GET endpoint and wipes its one-use key',
      () async {
        late HttpMethodAndPath seen;
        late String authorization;
        late String body;
        await server.start((request) async {
          seen = HttpMethodAndPath(request.method, request.uri.path);
          authorization =
              request.headers.value(HttpHeaders.authorizationHeader) ?? '';
          body = await utf8.decoder.bind(request).join();
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            '{"data":[{"id":"deepseek-v4"},{"id":"model:2"}]}',
          );
          await request.response.close();
        });
        final gateway = server.gateway();
        final keyBytes = Uint8List.fromList(utf8.encode('synthetic-test-key'));

        final models = await gateway.listModels(ModelSecretLease(keyBytes));

        expect(seen, const HttpMethodAndPath('GET', '/v1/models'));
        expect(authorization, 'Bearer synthetic-test-key');
        expect(body, isEmpty);
        expect(models, ['deepseek-v4', 'model:2']);
        expect(keyBytes, everyElement(0));
        await gateway.close();
      },
    );

    test('does not follow redirects to another location', () async {
      var modelRequests = 0;
      var redirectedRequests = 0;
      await server.start((request) async {
        if (request.uri.path == '/v1/models') {
          modelRequests++;
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            '/redirected',
          );
        } else {
          redirectedRequests++;
          request.response.write('{"data":[]}');
        }
        await request.response.close();
      });
      final gateway = server.gateway();

      await expectLater(
        gateway.listModels(_key()),
        throwsA(_failure(AgentFailureCode.redirectRejected)),
      );

      expect(modelRequests, 1);
      expect(redirectedRequests, 0);
      await gateway.close();
    });

    for (final statusAndCode in <(int, AgentFailureCode)>[
      (HttpStatus.unauthorized, AgentFailureCode.unauthorized),
      (HttpStatus.tooManyRequests, AgentFailureCode.rateLimited),
    ]) {
      test(
        'maps HTTP ${statusAndCode.$1} to ${statusAndCode.$2.name}',
        () async {
          await server.start((request) async {
            request.response.statusCode = statusAndCode.$1;
            request.response.write('sensitive server error text');
            await request.response.close();
          });
          final gateway = server.gateway();

          await expectLater(
            gateway.listModels(_key()),
            throwsA(_failure(statusAndCode.$2)),
          );
          await gateway.close();
        },
      );
    }

    test(
      'strictly assembles split UTF-8, tool fields and arguments, then completes',
      () async {
        late String body;
        await server.start((request) async {
          expect(request.method, 'POST');
          expect(request.uri.path, '/v1/chat/completions');
          body = await utf8.decoder.bind(request).join();
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          request.response.headers.set(
            HttpHeaders.transferEncodingHeader,
            'chunked',
          );
          final events = <String>[
            'data: {"choices":[{"index":0,"delta":{"reasoning_content":"先核对","content":null},"finish_reason":null}]}\n\n',
            'data: {"choices":[{"index":0,"delta":{"reasoning":"再查询","reasoning_content":"再查询"},"finish_reason":null}]}\n\n',
            'data: {"choices":[{"index":0,"delta":{"content":"中"},"finish_reason":null}],"usage":null}\n\n',
            'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_","type":"function","function":{"name":"echo_","arguments":"{\\"value\\":"}}]},"finish_reason":null}]}\n\n',
            'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"7","function":{"name":"probe","arguments":"\\"合成\\"}"}}]},"finish_reason":null}]}\n\n',
            'data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}\n\n',
            'data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":4}}\n\n',
            'data: [DONE]\n\n',
          ];
          final bytes = utf8.encode(events.join());
          final chinese = utf8.encode('中').first;
          final splitAt = bytes.indexOf(chinese) + 1;
          request.response.add(bytes.sublist(0, splitAt));
          await request.response.flush();
          request.response.add(bytes.sublist(splitAt));
          await request.response.close();
        });
        final gateway = server.gateway();
        final tool = ModelToolDefinition(
          name: 'echo_probe',
          description: 'synthetic probe',
          parameters: const <String, Object?>{
            'type': 'object',
            'properties': <String, Object?>{
              'value': <String, Object?>{'type': 'string'},
            },
          },
        );
        final events = await gateway.generate(_request(tool), _key()).toList();

        final requestBody = jsonDecode(body) as Map<String, dynamic>;
        expect(requestBody.keys.toSet(), {
          'model',
          'messages',
          'stream',
          'max_tokens',
          'tools',
        });
        expect(requestBody['model'], 'deepseek-v4');
        expect(requestBody['stream'], isTrue);
        expect(requestBody, isNot(contains('reasoning')));
        expect(requestBody['messages'], hasLength(3));
        final messages = requestBody['messages'] as List;
        expect((messages[0] as Map)['tool_calls'], isA<List>());
        expect((messages[1] as Map)['tool_call_id'], 'old_call');
        expect(
          events.whereType<ModelTextDelta>().map((event) => event.text).join(),
          '中',
        );
        final completion = events.whereType<ModelCompleted>().single;
        expect(
          events.whereType<ModelReasoningDelta>().map((e) => e.text).join(),
          '先核对再查询',
        );
        expect(completion.finishReason, 'tool_calls');
        expect(completion.inputTokens, 12);
        expect(completion.outputTokens, 4);
        expect(completion.toolCalls, hasLength(1));
        expect(completion.toolCalls.single.id, 'call_7');
        expect(completion.toolCalls.single.name, 'echo_probe');
        expect(jsonDecode(completion.toolCalls.single.argumentsJson), {
          'value': '合成',
        });
        await gateway.close();
      },
    );

    for (final (status, code) in <(int, String)>[
      (HttpStatus.badRequest, 'context_length_exceeded'),
      (HttpStatus.requestEntityTooLarge, 'context_window_exceeded'),
      (HttpStatus.unprocessableEntity, 'max_context_length_exceeded'),
    ]) {
      test('maps typed HTTP context code $code to contextLimit', () async {
        await server.start((request) async {
          await utf8.decoder.bind(request).join();
          request.response.statusCode = status;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'error': {
                'code': code,
                'message': 'synthetic-provider-error-body-marker',
              },
            }),
          );
          await request.response.close();
        });
        final gateway = server.gateway();
        final keyBytes = Uint8List.fromList(utf8.encode('synthetic-test-key'));

        await expectLater(
          gateway.generate(_request(), ModelSecretLease(keyBytes)).toList(),
          throwsA(_failure(AgentFailureCode.contextLimit)),
        );

        expect(keyBytes, everyElement(0));
        await gateway.close();
      });
    }

    for (final (label, error) in <(String, Map<String, Object?>)>[
      ('message-only', {'message': 'context_length_exceeded'}),
      (
        'unknown-code',
        {
          'code': 'synthetic_unknown_context_code',
          'message': 'synthetic-provider-error-body-marker',
        },
      ),
    ]) {
      test('keeps HTTP context $label as protocol failure', () async {
        await server.start((request) async {
          await utf8.decoder.bind(request).join();
          request.response.statusCode = HttpStatus.badRequest;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': error}));
          await request.response.close();
        });
        final gateway = server.gateway();
        final keyBytes = Uint8List.fromList(utf8.encode('synthetic-test-key'));

        await expectLater(
          gateway.generate(_request(), ModelSecretLease(keyBytes)).toList(),
          throwsA(_failure(AgentFailureCode.protocol)),
        );

        expect(keyBytes, everyElement(0));
        await gateway.close();
      });
    }

    for (final code in const [
      'context_length_exceeded',
      'context_window_exceeded',
      'max_context_length_exceeded',
    ]) {
      test('maps typed SSE context code $code', () async {
        await server.start((request) async {
          await utf8.decoder.bind(request).join();
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          final payload = jsonEncode({
            'error': {
              'code': code,
              'message': 'synthetic-provider-error-body-marker',
            },
          });
          request.response.write('data: $payload\n\n');
          await request.response.close();
        });
        final gateway = server.gateway();
        final keyBytes = Uint8List.fromList(utf8.encode('synthetic-test-key'));

        await expectLater(
          gateway.generate(_request(), ModelSecretLease(keyBytes)).toList(),
          throwsA(_failure(AgentFailureCode.contextLimit)),
        );

        expect(keyBytes, everyElement(0));
        await gateway.close();
      });
    }

    for (final (label, error) in <(String, Map<String, Object?>)>[
      ('message-only', {'message': 'context_length_exceeded'}),
      (
        'unknown-code',
        {
          'code': 'synthetic_unknown_context_code',
          'message': 'synthetic-provider-error-body-marker',
        },
      ),
    ]) {
      test('keeps SSE context $label as protocol failure', () async {
        await server.start((request) async {
          await utf8.decoder.bind(request).join();
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          final payload = jsonEncode({'error': error});
          request.response.write('data: $payload\n\n');
          await request.response.close();
        });
        final gateway = server.gateway();
        final keyBytes = Uint8List.fromList(utf8.encode('synthetic-test-key'));

        await expectLater(
          gateway.generate(_request(), ModelSecretLease(keyBytes)).toList(),
          throwsA(_failure(AgentFailureCode.protocol)),
        );

        expect(keyBytes, everyElement(0));
        await gateway.close();
      });
    }

    test('non-capacity HTTP 400 with an image remains imageRejected', () async {
      var requests = 0;
      await server.start((request) async {
        requests++;
        await utf8.decoder.bind(request).join();
        request.response.statusCode = HttpStatus.badRequest;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'error': {'message': 'context_length_exceeded'},
          }),
        );
        await request.response.close();
      });
      final gateway = server.gateway();
      final keyBytes = Uint8List.fromList(utf8.encode('synthetic-test-key'));
      const png =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8A'
          'AusB9Y9ZgdwAAAAASUVORK5CYII=';

      await expectLater(
        gateway
            .generate(
              ModelRequest(
                modelId: 'synthetic-vision',
                messages: [
                  ModelChatMessage(
                    role: 'user',
                    content: '看图',
                    images: [AgentImage(Uint8List.fromList(base64Decode(png)))],
                  ),
                ],
              ),
              ModelSecretLease(keyBytes),
            )
            .toList(),
        throwsA(_failure(AgentFailureCode.imageRejected)),
      );

      expect(requests, 1);
      expect(keyBytes, everyElement(0));
      await gateway.close();
    });

    test('rejects unpaired request tool calls before sending', () async {
      var requests = 0;
      await server.start((request) async {
        requests++;
        await request.response.close();
      });
      final gateway = server.gateway();
      final tool = ModelToolDefinition(
        name: 'echo_probe',
        description: 'synthetic probe',
        parameters: const <String, Object?>{'type': 'object'},
      );
      final request = ModelRequest(
        modelId: 'deepseek-v4',
        tools: [tool],
        messages: [
          ModelChatMessage(
            role: 'assistant',
            toolCalls: [
              ModelToolCall(
                id: 'call_1',
                name: 'echo_probe',
                argumentsJson: '{}',
              ),
            ],
          ),
        ],
      );

      await expectLater(
        gateway.generate(request, _key()).toList(),
        throwsA(_failure(AgentFailureCode.invalidInput)),
      );
      expect(requests, 0);
      await gateway.close();
    });

    test('EOF without DONE is a protocol failure and never completes', () async {
      await server.start((request) async {
        await utf8.decoder.bind(request).join();
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.write(
          'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n',
        );
        await request.response.close();
      });
      final gateway = server.gateway();
      final events = <ModelEvent>[];
      final stream = gateway.generate(_request(), _key());
      await expectLater(
        stream.listen(events.add).asFuture<void>(),
        throwsA(_failure(AgentFailureCode.protocol)),
      );

      expect(events.whereType<ModelCompleted>(), isEmpty);
      await gateway.close();
    });

    test('enforces the decompressed model response limit', () async {
      await server.start((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.add(List<int>.filled(1024 * 1024 + 1, 0x20));
        await request.response.close();
      });
      final gateway = server.gateway();

      await expectLater(
        gateway.listModels(_key()),
        throwsA(_failure(AgentFailureCode.resourceLimit)),
      );
      await gateway.close();
    });

    test(
      'rejects malformed reasoning without turning it into answer text',
      () async {
        await server.start((request) async {
          await utf8.decoder.bind(request).join();
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          request.response.write(
            'data: {"choices":[{"index":0,"delta":{"reasoning_content":{"text":"wrong shape"}},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
          );
          await request.response.close();
        });
        final gateway = server.gateway();
        await expectLater(
          gateway.generate(_request(), _key()).toList(),
          throwsA(_failure(AgentFailureCode.protocol)),
        );
        await gateway.close();
      },
    );

    test('bounds reasoning separately from final answer text', () async {
      await server.start((request) async {
        await utf8.decoder.bind(request).join();
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        for (var i = 0; i < 9; i++) {
          request.response.write(
            'data: ${jsonEncode({
              'choices': [
                {
                  'index': 0,
                  'delta': {'reasoning': 'x' * (16 * 1024)},
                  'finish_reason': null,
                },
              ],
            })}\n\n',
          );
        }
        await request.response.close();
      });
      final gateway = server.gateway();
      await expectLater(
        gateway.generate(_request(), _key()).toList(),
        throwsA(_failure(AgentFailureCode.resourceLimit)),
      );
      await gateway.close();
    });

    test('enforces the SSE line limit', () async {
      await server.start((request) async {
        await utf8.decoder.bind(request).join();
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.add(utf8.encode('data: ${'x' * (64 * 1024)}\n\n'));
        await request.response.close();
      });
      final gateway = server.gateway();
      await expectLater(
        gateway.generate(_request(), _key()).toList(),
        throwsA(_failure(AgentFailureCode.resourceLimit)),
      );
      await gateway.close();
    });

    test(
      'enforces the aggregate SSE byte limit across bounded comment events',
      () async {
        await server.start((request) async {
          await utf8.decoder.bind(request).join();
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          final comment = ':${'x' * 32760}\n\n';
          for (var i = 0; i < 65; i++) {
            request.response.write(comment);
          }
          await request.response.close();
        });
        final gateway = server.gateway();

        await expectLater(
          gateway.generate(_request(), _key()).toList(),
          throwsA(_failure(AgentFailureCode.resourceLimit)),
        );
        await gateway.close();
      },
    );

    test('enforces the streamed text character limit', () async {
      await server.start((request) async {
        await utf8.decoder.bind(request).join();
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        final event = <String, Object?>{
          'choices': [
            {
              'index': 0,
              'delta': {'content': 'x' * 24001},
              'finish_reason': null,
            },
          ],
        };
        request.response.write('data: ${jsonEncode(event)}\n\n');
        await request.response.close();
      });
      final gateway = server.gateway();

      await expectLater(
        gateway.generate(_request(), _key()).toList(),
        throwsA(_failure(AgentFailureCode.resourceLimit)),
      );
      await gateway.close();
    });

    test('enforces per-call argument and tool-call count limits', () async {
      final tool = ModelToolDefinition(
        name: 'echo_probe',
        description: 'synthetic probe',
        parameters: const <String, Object?>{'type': 'object'},
      );
      await server.start((request) async {
        await utf8.decoder.bind(request).join();
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        final calls = [
          {
            'index': 0,
            'id': 'call_0',
            'type': 'function',
            'function': {
              'name': 'echo_probe',
              'arguments': '{"value":"${'x' * (16 * 1024)}"}',
            },
          },
        ];
        request.response.write(
          'data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': {'tool_calls': calls},
                'finish_reason': null,
              },
            ],
          })}\n\n',
        );
        await request.response.close();
      });
      final gateway = server.gateway();
      await expectLater(
        gateway.generate(_request(tool), _key()).toList(),
        throwsA(_failure(AgentFailureCode.resourceLimit)),
      );
      await gateway.close();

      await server.close();
      server = _Server();
      await server.start((request) async {
        await utf8.decoder.bind(request).join();
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        final calls = List.generate(
          9,
          (index) => {
            'index': index,
            'id': 'call_$index',
            'type': 'function',
            'function': {'name': 'echo_probe', 'arguments': '{}'},
          },
        );
        request.response.write(
          'data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': {'tool_calls': calls},
                'finish_reason': null,
              },
            ],
          })}\n\n',
        );
        await request.response.close();
      });
      final countGateway = server.gateway();
      await expectLater(
        countGateway.generate(_request(tool), _key()).toList(),
        throwsA(_failure(AgentFailureCode.resourceLimit)),
      );
      await countGateway.close();
    });

    test('delivers an SSE text delta while the response is still open', () async {
      final release = Completer<void>();
      await server.start((request) async {
        await utf8.decoder.bind(request).join();
        request.response.bufferOutput = false;
        request.response.headers.chunkedTransferEncoding = true;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.write(
          'data: {"choices":[{"index":0,"delta":{"content":"合成首片段"},"finish_reason":null}]}\n\n',
        );
        await request.response.flush();
        await release.future;
        await request.response.close();
      });
      final gateway = server.gateway();
      final delta = Completer<String>();
      final finished = Completer<void>();
      final subscription = gateway
          .generate(_request(), _key())
          .listen(
            (event) {
              if (event is ModelTextDelta && !delta.isCompleted) {
                delta.complete(event.text);
              }
            },
            onError: (Object _) {},
            onDone: finished.complete,
          );
      try {
        expect(await delta.future.timeout(const Duration(seconds: 3)), '合成首片段');
        expect(finished.isCompleted, isFalse);
        await gateway.cancelAndDrain().timeout(const Duration(seconds: 3));
      } finally {
        if (!release.isCompleted) release.complete();
        await subscription.cancel();
        await gateway.close();
      }
    });

    test(
      'cancel drains an in-flight stream and the same gateway accepts a later request',
      () async {
        final firstSeen = Completer<void>();
        final releaseFirst = Completer<void>();
        var requestNumber = 0;
        await server.start((request) async {
          requestNumber++;
          if (requestNumber == 1) {
            await utf8.decoder.bind(request).join();
            request.response.headers.contentType = ContentType(
              'text',
              'event-stream',
            );
            firstSeen.complete();
            await releaseFirst.future;
            try {
              request.response.write('data: [DONE]\n\n');
              await request.response.close();
            } on Object {
              // The gateway has already closed this client to stop the stale run.
            }
            return;
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"data":[{"id":"reused"}]}');
          await request.response.close();
        });
        final gateway = server.gateway();
        final streamErrors = <Object>[];
        final oldEvents = <ModelEvent>[];
        final firstKey = Uint8List.fromList(utf8.encode('synthetic-test-key'));
        final subscription = gateway
            .generate(_request(), ModelSecretLease(firstKey))
            .listen(
              oldEvents.add,
              onError: (Object error) => streamErrors.add(error),
            );
        await firstSeen.future.timeout(const Duration(seconds: 2));

        await gateway.cancelAndDrain().timeout(const Duration(seconds: 2));
        final models = await gateway
            .listModels(_key())
            .timeout(const Duration(seconds: 2));
        releaseFirst.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(models, ['reused']);
        expect(firstKey, everyElement(0));
        expect(oldEvents.whereType<ModelCompleted>(), isEmpty);
        expect(
          streamErrors,
          contains(
            isA<AgentFailure>().having(
              (failure) => failure.code,
              'code',
              AgentFailureCode.cancelled,
            ),
          ),
        );
        expect(requestNumber, 2);
        await subscription.cancel();
        await gateway.close();
      },
    );

    test('maps a request deadline to timeout', () async {
      await server.start((request) async {
        await utf8.decoder.bind(request).join();
        await Completer<void>().future;
      });
      final gateway = server.gateway(
        requestTimeout: const Duration(milliseconds: 80),
      );

      await expectLater(
        gateway.listModels(_key()),
        throwsA(_failure(AgentFailureCode.timeout)),
      );
      await gateway.close().timeout(const Duration(seconds: 2));
    });

    test(
      'close permanently rejects new calls and revokes their leases',
      () async {
        await server.start((request) async => request.response.close());
        final gateway = server.gateway();
        await gateway.close();
        final key = Uint8List.fromList(utf8.encode('synthetic-test-key'));

        await expectLater(
          gateway.listModels(ModelSecretLease(key)),
          throwsA(_failure(AgentFailureCode.closed)),
        );
        expect(key, everyElement(0));
      },
    );
  });
}

ModelSecretLease _key() =>
    ModelSecretLease(Uint8List.fromList(utf8.encode('synthetic-test-key')));

ModelRequest _request([ModelToolDefinition? tool]) {
  final tools = tool == null
      ? const <ModelToolDefinition>[]
      : <ModelToolDefinition>[tool];
  final messages = <ModelChatMessage>[
    ModelChatMessage(role: 'user', content: '请 echo 合成文本'),
  ];
  if (tool != null) {
    messages.insert(
      0,
      ModelChatMessage(
        role: 'assistant',
        toolCalls: [
          ModelToolCall(
            id: 'old_call',
            name: tool.name,
            argumentsJson: '{"value":"old"}',
          ),
        ],
      ),
    );
    messages.insert(
      1,
      ModelChatMessage(
        role: 'tool',
        toolCallId: 'old_call',
        content: 'old result',
      ),
    );
  }
  return ModelRequest(
    modelId: 'deepseek-v4',
    messages: messages,
    tools: tools,
    maxTokens: 128,
  );
}

Matcher _failure(AgentFailureCode code) =>
    isA<AgentFailure>().having((failure) => failure.code, 'code', code);

final class HttpMethodAndPath {
  const HttpMethodAndPath(this.method, this.path);
  final String method;
  final String path;
  @override
  bool operator ==(Object other) =>
      other is HttpMethodAndPath &&
      method == other.method &&
      path == other.path;
  @override
  int get hashCode => Object.hash(method, path);
  @override
  String toString() => '$method $path';
}

final class _Server {
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;

  Future<void> start(Future<void> Function(HttpRequest) handler) async {
    final instance = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = instance;
    _subscription = instance.listen((request) {
      unawaited(handler(request));
    });
  }

  UstcModelGateway gateway({
    Duration requestTimeout = const Duration(seconds: 5),
  }) {
    final instance = _server;
    if (instance == null) throw StateError('Server not started');
    final uri = Uri(scheme: 'http', host: '127.0.0.1', port: instance.port);
    return UstcModelGateway.loopbackForTesting(
      uri,
      requestTimeout: requestTimeout,
    );
  }

  Future<void> close() async {
    await _subscription?.cancel();
    await _server?.close(force: true);
    _subscription = null;
    _server = null;
  }
}
