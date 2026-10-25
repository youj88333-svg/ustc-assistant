import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/agent/configured_model_gateway.dart';
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/agent/ustc_model_gateway.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';

void main() {
  test('provider destinations are the two fixed HTTPS origins', () {
    expect(
      ModelProvider.school.endpoint,
      Uri.parse('https://api.llm.ustc.edu.cn/'),
    );
    expect(
      ModelProvider.deepseek.endpoint,
      Uri.parse('https://api.deepseek.com/'),
    );
  });

  test(
    'configured routing follows the lease provider for the same model ID and never falls back',
    () async {
      final school = _LoopbackServer();
      final deepseek = _LoopbackServer();
      addTearDown(school.close);
      addTearDown(deepseek.close);
      final schoolRequests = <_SeenRequest>[];
      final deepseekRequests = <_SeenRequest>[];

      await school.start((request) async {
        final body = await utf8.decoder.bind(request).join();
        schoolRequests.add(_seen(request, body));
        if (schoolRequests.length == 2) {
          request.response.statusCode = HttpStatus.internalServerError;
          request.response.write('SYNTHETIC_SCHOOL_FAILURE_BODY');
          await request.response.close();
          return;
        }
        await _respondWithText(request.response, 'school loopback');
      });
      await deepseek.start((request) async {
        final body = await utf8.decoder.bind(request).join();
        deepseekRequests.add(_seen(request, body));
        await _respondWithText(request.response, 'official loopback');
      });

      final gateway = ConfiguredModelGateway.forTesting(
        school: UstcModelGateway.loopbackForTesting(school.baseUri),
        deepseek: UstcModelGateway.loopbackForTesting(
          deepseek.baseUri,
          provider: ModelProvider.deepseek,
        ),
      );
      addTearDown(gateway.close);
      final request = ModelRequest(
        modelId: 'deepseek-flash',
        messages: [ModelChatMessage(role: 'user', content: '合成路由测试')],
      );
      final schoolKey = _bytes('synthetic-school-key');
      final deepseekKey = _bytes('synthetic-official-key');

      await gateway
          .generate(
            request,
            ModelSecretLease(schoolKey, provider: ModelProvider.school),
          )
          .drain<void>();
      await gateway
          .generate(
            request,
            ModelSecretLease(deepseekKey, provider: ModelProvider.deepseek),
          )
          .drain<void>();

      expect(schoolRequests, hasLength(1));
      expect(deepseekRequests, hasLength(1));
      expect(schoolRequests.single.path, '/v1/chat/completions');
      expect(deepseekRequests.single.path, '/chat/completions');
      expect(
        schoolRequests.single.authorization,
        'Bearer synthetic-school-key',
      );
      expect(
        deepseekRequests.single.authorization,
        'Bearer synthetic-official-key',
      );
      expect(schoolRequests.single.jsonBody!['model'], 'deepseek-flash');
      expect(deepseekRequests.single.jsonBody!['model'], 'deepseek-flash');
      expect(schoolRequests.single.jsonBody!['reasoning_effort'], 'high');
      expect(deepseekRequests.single.jsonBody!['thinking'], {
        'type': 'disabled',
      });
      expect(
        deepseekRequests.single.jsonBody!.containsKey('reasoning_effort'),
        isFalse,
      );
      expect(schoolKey, everyElement(0));
      expect(deepseekKey, everyElement(0));

      final failedKey = _bytes('synthetic-school-key-no-fallback');
      await expectLater(
        gateway
            .generate(
              request,
              ModelSecretLease(failedKey, provider: ModelProvider.school),
            )
            .drain<void>(),
        throwsA(_failure(AgentFailureCode.networkFailed)),
      );
      expect(failedKey, everyElement(0));
      expect(schoolRequests, hasLength(2));
      expect(deepseekRequests, hasLength(1));
      expect(school.handlerErrors, isEmpty);
      expect(deepseek.handlerErrors, isEmpty);
    },
  );

  test(
    'DeepSeek loopback lists models and carries a tool result in direct-mode continuation',
    () async {
      final server = _LoopbackServer();
      addTearDown(server.close);
      final seen = <_SeenRequest>[];
      await server.start((request) async {
        final body = await utf8.decoder.bind(request).join();
        seen.add(_seen(request, body));
        if (request.method == 'GET' && request.uri.path == '/models') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            '{"data":[{"id":"deepseek-flash"},{"id":"synthetic-model"}]}',
          );
          await request.response.close();
          return;
        }
        if (request.method != 'POST' ||
            request.uri.path != '/chat/completions') {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        if (seen.where((item) => item.method == 'POST').length == 1) {
          await _respondWithSse(
            request.response,
            'data: {"choices":[{"index":0,"delta":{"reasoning_content":"SYNTHETIC_REASONING_NOT_REPLAYED","tool_calls":[{"index":0,"id":"call.deepseek1","type":"function","function":{"name":"read_local","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}\n\n'
            'data: [DONE]\n\n',
          );
          return;
        }
        await _respondWithSse(
          request.response,
          'data: {"choices":[{"index":0,"delta":{"content":"合成结果已续答"},"finish_reason":"stop"}]}\n\n'
          'data: [DONE]\n\n',
        );
      });

      final gateway = UstcModelGateway.loopbackForTesting(
        server.baseUri,
        provider: ModelProvider.deepseek,
        connectTimeout: const Duration(seconds: 2),
        requestTimeout: const Duration(seconds: 5),
        idleTimeout: const Duration(seconds: 2),
      );
      addTearDown(gateway.close);
      final listKey = _bytes('synthetic-list-key');
      expect(
        await gateway.listModels(
          ModelSecretLease(listKey, provider: ModelProvider.deepseek),
        ),
        ['deepseek-flash', 'synthetic-model'],
      );
      expect(listKey, everyElement(0));

      final tool = ModelToolDefinition(
        name: 'read_local',
        description: 'Read a synthetic local value.',
        parameters: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{},
          'additionalProperties': false,
        },
      );
      final firstKey = _bytes('synthetic-first-chat-key');
      final firstEvents = await gateway
          .generate(
            ModelRequest(
              modelId: 'deepseek-flash',
              messages: [ModelChatMessage(role: 'user', content: '读取一个合成值')],
              tools: [tool],
            ),
            ModelSecretLease(firstKey, provider: ModelProvider.deepseek),
          )
          .toList();
      expect(firstKey, everyElement(0));
      expect(
        firstEvents.whereType<ModelReasoningDelta>().single.text,
        'SYNTHETIC_REASONING_NOT_REPLAYED',
      );
      final toolCall = firstEvents
          .whereType<ModelCompleted>()
          .single
          .toolCalls
          .single;
      expect(toolCall.name, 'read_local');
      expect(jsonDecode(toolCall.argumentsJson), isEmpty);

      final continuationKey = _bytes('synthetic-continuation-key');
      final continuationEvents = await gateway
          .generate(
            ModelRequest(
              modelId: 'deepseek-flash',
              messages: [
                ModelChatMessage(role: 'user', content: '读取一个合成值'),
                ModelChatMessage(role: 'assistant', toolCalls: [toolCall]),
                ModelChatMessage(
                  role: 'tool',
                  toolCallId: toolCall.id,
                  content: '{"value":"synthetic"}',
                ),
              ],
              tools: [tool],
            ),
            ModelSecretLease(continuationKey, provider: ModelProvider.deepseek),
          )
          .toList();
      expect(continuationKey, everyElement(0));
      expect(
        continuationEvents
            .whereType<ModelTextDelta>()
            .map((e) => e.text)
            .join(),
        '合成结果已续答',
      );
      expect(
        continuationEvents.whereType<ModelCompleted>().single.finishReason,
        'stop',
      );

      expect(seen.map((item) => '${item.method} ${item.path}').toList(), [
        'GET /models',
        'POST /chat/completions',
        'POST /chat/completions',
      ]);
      expect(seen.map((item) => item.authorization).toList(), [
        'Bearer synthetic-list-key',
        'Bearer synthetic-first-chat-key',
        'Bearer synthetic-continuation-key',
      ]);
      final firstBody = seen[1].jsonBody!;
      final continuationBody = seen[2].jsonBody!;
      for (final body in [firstBody, continuationBody]) {
        expect(body['thinking'], {'type': 'disabled'});
        expect(body.containsKey('reasoning_effort'), isFalse);
        expect(body['stream'], isTrue);
      }
      expect(
        _hasKeyDeep(continuationBody['messages'], 'reasoning_content'),
        isFalse,
      );
      expect(_hasKeyDeep(continuationBody['messages'], 'reasoning'), isFalse);
      expect(
        jsonEncode(continuationBody['messages']),
        isNot(contains('SYNTHETIC_REASONING_NOT_REPLAYED')),
      );
      final continuationMessages = continuationBody['messages'] as List;
      final assistant = continuationMessages
          .cast<Map<String, dynamic>>()
          .singleWhere((message) => message['role'] == 'assistant');
      final toolResult = continuationMessages
          .cast<Map<String, dynamic>>()
          .singleWhere((message) => message['role'] == 'tool');
      expect(
        ((assistant['tool_calls'] as List).single as Map)['id'],
        toolCall.id,
      );
      expect(toolResult['tool_call_id'], toolCall.id);
      expect(toolResult['content'], '{"value":"synthetic"}');
      expect(server.handlerErrors, isEmpty);
    },
  );

  test(
    'provider-bound gateway rejects the other provider and wipes the lease',
    () async {
      final server = _LoopbackServer();
      addTearDown(server.close);
      var requests = 0;
      await server.start((request) async {
        requests++;
        await request.response.close();
      });
      final gateway = UstcModelGateway.loopbackForTesting(
        server.baseUri,
        provider: ModelProvider.deepseek,
      );
      addTearDown(gateway.close);

      final listBytes = _bytes('synthetic-wrong-list-provider-key');
      await expectLater(
        gateway.listModels(
          ModelSecretLease(listBytes, provider: ModelProvider.school),
        ),
        throwsA(_failure(AgentFailureCode.invalidInput)),
      );
      expect(listBytes, everyElement(0));

      final chatBytes = _bytes('synthetic-wrong-chat-provider-key');
      await expectLater(
        gateway
            .generate(
              _request(),
              ModelSecretLease(chatBytes, provider: ModelProvider.school),
            )
            .toList(),
        throwsA(_failure(AgentFailureCode.invalidInput)),
      );
      expect(chatBytes, everyElement(0));
      expect(requests, 0);
      expect(server.handlerErrors, isEmpty);
    },
  );

  test(
    'official HTTP failures map to stable codes without leaking body or key and reject redirects',
    () async {
      final server = _LoopbackServer();
      addTearDown(server.close);
      var redirectTargetRequests = 0;
      final failuresSeen = <(int, String, AgentFailureCode)>[];
      const scenarios = <(int, AgentFailureCode)>[
        (HttpStatus.unauthorized, AgentFailureCode.unauthorized),
        (HttpStatus.paymentRequired, AgentFailureCode.insufficientBalance),
        (HttpStatus.tooManyRequests, AgentFailureCode.rateLimited),
        (HttpStatus.internalServerError, AgentFailureCode.networkFailed),
        (HttpStatus.found, AgentFailureCode.redirectRejected),
      ];
      var scenarioIndex = 0;
      await server.start((request) async {
        if (request.uri.path == '/redirect-target') {
          redirectTargetRequests++;
          await request.response.close();
          return;
        }
        await utf8.decoder.bind(request).join();
        final (statusCode, failureCode) = scenarios[scenarioIndex++];
        failuresSeen.add((statusCode, request.uri.path, failureCode));
        request.response.statusCode = statusCode;
        if (statusCode == HttpStatus.found) {
          request.response.headers.set(
            HttpHeaders.locationHeader,
            '/redirect-target',
          );
        }
        request.response.write('SYNTHETIC_RAW_BODY_$statusCode');
        await request.response.close();
      });

      final gateway = UstcModelGateway.loopbackForTesting(
        server.baseUri,
        provider: ModelProvider.deepseek,
        connectTimeout: const Duration(seconds: 2),
        requestTimeout: const Duration(seconds: 5),
      );
      addTearDown(gateway.close);

      for (final (status, expectedCode) in scenarios) {
        final marker = 'synthetic-error-key-$status';
        final rawBody = 'SYNTHETIC_RAW_BODY_$status';
        final key = _bytes(marker);
        final request = _request();
        await expectLater(
          gateway
              .generate(
                request,
                ModelSecretLease(key, provider: ModelProvider.deepseek),
              )
              .toList(),
          throwsA(
            isA<AgentFailure>()
                .having((failure) => failure.code, 'code', expectedCode)
                .having(
                  (failure) => failure.toString(),
                  'safe error text',
                  isNot(contains(marker)),
                )
                .having(
                  (failure) => failure.toString(),
                  'safe error text',
                  isNot(contains(rawBody)),
                ),
          ),
        );
        expect(key, everyElement(0));
      }
      expect(failuresSeen.map((entry) => entry.$1), scenarios.map((e) => e.$1));
      expect(failuresSeen.map((entry) => entry.$3), scenarios.map((e) => e.$2));
      expect(redirectTargetRequests, 0);
      expect(server.handlerErrors, isEmpty);
    },
  );

  test(
    'configured close and cancelAndDrain wait for both provider gateways',
    () async {
      final school = _DrainProbeGateway();
      final deepseek = _DrainProbeGateway();
      final gateway = ConfiguredModelGateway.forTesting(
        school: school,
        deepseek: deepseek,
      );

      final draining = gateway.cancelAndDrain();
      expect(school.cancelCount, 1);
      expect(deepseek.cancelCount, 1);
      var drainCompleted = false;
      unawaited(
        draining.then((_) {
          drainCompleted = true;
        }),
      );
      school.cancelGate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(drainCompleted, isFalse);
      deepseek.cancelGate.complete();
      await draining;
      expect(drainCompleted, isTrue);

      final closing = gateway.close();
      expect(school.closeCount, 1);
      expect(deepseek.closeCount, 1);
      var closeCompleted = false;
      unawaited(
        closing.then((_) {
          closeCompleted = true;
        }),
      );
      school.closeGate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(closeCompleted, isFalse);
      deepseek.closeGate.complete();
      await closing;
      expect(closeCompleted, isTrue);
    },
  );

  test(
    'DeepSeek loopback cancellation drains and leaves the gateway reusable',
    () async {
      final server = _LoopbackServer();
      addTearDown(server.close);
      final firstRequestSeen = Completer<void>();
      final releaseFirstResponse = Completer<void>();
      var requestCount = 0;
      await server.start((request) async {
        requestCount++;
        if (request.uri.path == '/models') {
          await utf8.decoder.bind(request).join();
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"data":[{"id":"reused-model"}]}');
          await request.response.close();
          return;
        }
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
        firstRequestSeen.complete();
        await releaseFirstResponse.future;
        try {
          await request.response.close();
        } on Object {
          // The gateway has closed the in-flight response during cancellation.
        }
      });

      final gateway = UstcModelGateway.loopbackForTesting(
        server.baseUri,
        provider: ModelProvider.deepseek,
        connectTimeout: const Duration(seconds: 2),
        requestTimeout: const Duration(seconds: 5),
        idleTimeout: const Duration(seconds: 2),
      );
      addTearDown(gateway.close);
      final firstKey = _bytes('synthetic-cancel-key');
      final firstDelta = Completer<void>();
      final streamFailure = Completer<Object>();
      final subscription = gateway
          .generate(
            _request(),
            ModelSecretLease(firstKey, provider: ModelProvider.deepseek),
          )
          .listen(
            (event) {
              if (event is ModelTextDelta && !firstDelta.isCompleted) {
                firstDelta.complete();
              }
            },
            onError: (Object error) {
              if (!streamFailure.isCompleted) streamFailure.complete(error);
            },
          );
      try {
        await firstRequestSeen.future.timeout(const Duration(seconds: 2));
        await firstDelta.future.timeout(const Duration(seconds: 2));
        await gateway.cancelAndDrain().timeout(const Duration(seconds: 2));
        final failure = await streamFailure.future.timeout(
          const Duration(seconds: 2),
        );
        expect(failure, isA<AgentFailure>());
        expect((failure as AgentFailure).code, AgentFailureCode.cancelled);
        expect(firstKey, everyElement(0));

        expect(
          await gateway.listModels(
            ModelSecretLease(
              _bytes('synthetic-reuse-key'),
              provider: ModelProvider.deepseek,
            ),
          ),
          ['reused-model'],
        );
        expect(requestCount, 2);
        expect(server.handlerErrors, isEmpty);
      } finally {
        if (!releaseFirstResponse.isCompleted) releaseFirstResponse.complete();
        await subscription.cancel();
        await gateway.close();
      }
    },
  );
}

final class _LoopbackServer {
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;
  final List<Future<void>> _handlers = <Future<void>>[];
  final List<Object> handlerErrors = <Object>[];
  late Uri baseUri;

  Future<void> start(Future<void> Function(HttpRequest) handler) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    baseUri = Uri(scheme: 'http', host: '127.0.0.1', port: server.port);
    _subscription = server.listen((request) {
      _handlers.add(_serve(handler, request));
    });
  }

  Future<void> _serve(
    Future<void> Function(HttpRequest) handler,
    HttpRequest request,
  ) async {
    try {
      await handler(request);
    } on Object catch (error) {
      handlerErrors.add(error);
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } on Object {
        // A cancelled client can already have closed this loopback response.
      }
    }
  }

  Future<void> close() async {
    await _subscription?.cancel();
    await _server?.close(force: true);
    await Future.wait(_handlers, eagerError: false);
  }
}

final class _SeenRequest {
  const _SeenRequest({
    required this.method,
    required this.path,
    required this.authorization,
    required this.body,
  });

  final String method, path, authorization, body;
  Map<String, dynamic>? get jsonBody =>
      body.isEmpty ? null : jsonDecode(body) as Map<String, dynamic>;
}

final class _DrainProbeGateway implements ModelGatewayPort {
  final Completer<void> cancelGate = Completer<void>();
  final Completer<void> closeGate = Completer<void>();
  int cancelCount = 0;
  int closeCount = 0;

  @override
  Future<List<String>> listModels(ModelSecretLease secret) =>
      Future<List<String>>.error(const AgentFailure(AgentFailureCode.closed));

  @override
  Stream<ModelEvent> generate(ModelRequest request, ModelSecretLease secret) =>
      Stream<ModelEvent>.error(const AgentFailure(AgentFailureCode.closed));

  @override
  Future<void> cancelAndDrain() {
    cancelCount++;
    return cancelGate.future;
  }

  @override
  Future<void> close() {
    closeCount++;
    return closeGate.future;
  }
}

_SeenRequest _seen(HttpRequest request, String body) => _SeenRequest(
  method: request.method,
  path: request.uri.path,
  authorization: request.headers.value(HttpHeaders.authorizationHeader) ?? '',
  body: body,
);

Future<void> _respondWithText(HttpResponse response, String value) async {
  await _respondWithSse(
    response,
    'data: ${jsonEncode({
      'choices': [
        {
          'index': 0,
          'delta': {'content': value},
          'finish_reason': 'stop',
        },
      ],
    })}\n\n'
    'data: [DONE]\n\n',
  );
}

Future<void> _respondWithSse(HttpResponse response, String body) async {
  response.headers.contentType = ContentType(
    'text',
    'event-stream',
    charset: 'utf-8',
  );
  response.write(body);
  await response.close();
}

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

ModelRequest _request() => ModelRequest(
  modelId: 'deepseek-flash',
  messages: [ModelChatMessage(role: 'user', content: '合成请求')],
);

Matcher _failure(AgentFailureCode code) =>
    isA<AgentFailure>().having((failure) => failure.code, 'code', code);

bool _hasKeyDeep(Object? value, String name) {
  if (value is Map) {
    return value.keys.any((key) => key == name) ||
        value.values.any((entry) => _hasKeyDeep(entry, name));
  }
  if (value is Iterable) {
    return value.any((entry) => _hasKeyDeep(entry, name));
  }
  return false;
}
