import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/agent/agent_coordinator.dart';
import 'package:ustc_assistant_m0/agent/agent_read_tools.dart';
import 'package:ustc_assistant_m0/agent/agent_tool_contract.dart';
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/agent/ustc_model_gateway.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/jobs/public_query_coordinator.dart';

void main() {
  test(
    'loopback SSE tool IDs survive capability verification and C3 read pairing',
    () async {
      final service = _LoopbackModelService();
      await service.start();
      final store = JwStore(
        NativeDatabase.memory(),
        ownership: _TestOwnership(),
        clock: FixedClock(DateTime.utc(2026, 10, 14, 2)),
        modelCredentialProtector: _SyntheticProtector(),
      );
      await store.initialize();
      await store.agent.initializeAgent();

      final context = (await store.localCalendar.readPlanContext()).$1;
      final task = await store.localCalendar.prepare(
        context,
        const CreateTask(TaskDraft(title: '网关集成合成任务')),
      );
      await store.localCalendar.commit(task);

      final publicQueries = PublicQueryCoordinator(
        store: store.publicStore,
        leases: WorkLeasePool(),
        clock: FixedClock(DateTime.utc(2026, 10, 14, 2)),
        sessionFactory: (source) =>
            throw StateError('Synthetic public HTTP is disabled.'),
      );
      final baseReadTools = AgentReadTools(
        calendar: store.localCalendar,
        tasks: store.localCalendar,
        calendarGuard: store.localCalendar,
        knowledge: store.publicStore,
        knowledgeGuard: store.publicStore,
        publicQueries: publicQueries,
        publicGuard: publicQueries,
        clock: FixedClock(DateTime.utc(2026, 10, 14, 2)),
      );
      final readTools = _CountingReadTools(baseReadTools);
      final gateway = UstcModelGateway.loopbackForTesting(
        service.baseUri,
        connectTimeout: const Duration(seconds: 2),
        requestTimeout: const Duration(seconds: 5),
        idleTimeout: const Duration(seconds: 2),
      );
      final coordinator = AgentCoordinator(
        data: store.agent,
        gateway: gateway,
        readTools: readTools,
        clock: FixedClock(DateTime.utc(2026, 10, 14, 2)),
        runTimeout: const Duration(seconds: 15),
      );

      addTearDown(() async {
        await coordinator.close();
        await publicQueries.close();
        await store.close();
        await service.close();
      });

      await coordinator.initialize();
      await coordinator
          .verifyAndSave(
            key: 'synthetic-model-key-loopback',
            modelId: _LoopbackModelService.modelId,
            consent: true,
          )
          .timeout(const Duration(seconds: 8));

      final saved = await store.agent.inspectAgent();
      expect(saved.modelId, _LoopbackModelService.modelId);
      expect(saved.keySaved, isTrue);
      expect(saved.consent, isTrue);
      expect(saved.report.capability, ModelCapability.toolReady);
      expect(coordinator.view.report.capability, ModelCapability.toolReady);

      final verificationResultRequest = service.chatBodies[2];
      final verificationMessages =
          verificationResultRequest['messages'] as List<dynamic>;
      final verificationAssistant = verificationMessages
          .whereType<Map<String, dynamic>>()
          .singleWhere((message) => message['role'] == 'assistant');
      final verificationCalls =
          verificationAssistant['tool_calls'] as List<dynamic>;
      expect((verificationCalls.single as Map)['id'], 'call:1');
      final verificationTool = verificationMessages
          .whereType<Map<String, dynamic>>()
          .singleWhere((message) => message['role'] == 'tool');
      expect(verificationTool['tool_call_id'], 'call:1');
      final verificationPayload =
          jsonDecode(verificationTool['content'] as String)
              as Map<String, dynamic>;
      expect(verificationPayload['value'], 'ustc_probe');
      expect(verificationPayload['proof'], isA<String>());
      expect(service.forwardedProof, verificationPayload['proof']);

      await coordinator.send('查询我的本地任务列表').timeout(const Duration(seconds: 8));
      expect(coordinator.view.failure, isNull);
      expect(
        coordinator.view.messages.last.status,
        AgentMessageStatus.complete,
      );
      expect(coordinator.view.messages.last.text, '已读取合成任务列表。');
      expect(readTools.executeCount, 1);

      final queryRequest = service.chatBodies[3];
      final queryTools = _toolNames(queryRequest);
      expect(queryTools, contains('query_tasks'));
      expect(queryRequest, isNot(contains('tool_choice')));
      final resultRequest = service.chatBodies[4];
      final queryMessages = resultRequest['messages'] as List<dynamic>;
      final queryAssistant = queryMessages
          .whereType<Map<String, dynamic>>()
          .singleWhere((message) => message['role'] == 'assistant');
      final queryCalls = queryAssistant['tool_calls'] as List<dynamic>;
      expect((queryCalls.single as Map)['id'], 'call.1');
      expect(
        jsonDecode(
          (queryCalls.single as Map)['function']['arguments'] as String,
        ),
        isEmpty,
      );
      final queryResult = queryMessages
          .whereType<Map<String, dynamic>>()
          .singleWhere((message) => message['role'] == 'tool');
      expect(queryResult['tool_call_id'], 'call.1');
      final queryPayload =
          jsonDecode(queryResult['content'] as String) as Map<String, dynamic>;
      expect(queryPayload['status'], 'success');
      final queryData = queryPayload['data'] as Map<String, dynamic>;
      final returnedTasks = queryData['items'] as List<dynamic>;
      expect(returnedTasks, hasLength(1));
      expect((returnedTasks.single as Map)['title'], '网关集成合成任务');

      await coordinator.newConversation();
      service.duplicateNextTaskCall = true;
      final executionsBeforeDuplicate = readTools.executeCount;
      await coordinator
          .send('再次查询本地任务列表，验证重复 ID。')
          .timeout(const Duration(seconds: 8));

      expect(coordinator.view.failure, AgentFailureCode.protocol);
      expect(coordinator.view.messages.last.status, AgentMessageStatus.failed);
      expect(coordinator.view.messages.last.text, isEmpty);
      expect(readTools.executeCount, executionsBeforeDuplicate);
      expect(service.chatBodies, hasLength(6));
      expect(service.failures, isEmpty);
      expect(await _activeRun(store), isNull);
    },
  );
}

Set<String> _toolNames(Map<String, dynamic> body) =>
    (body['tools'] as List<dynamic>)
        .whereType<Map<String, dynamic>>()
        .map((tool) => (tool['function'] as Map)['name'] as String)
        .toSet();

Future<String?> _activeRun(JwStore store) async =>
    (await store.customSelect('SELECT active_run FROM agent_state').getSingle())
        .read<String?>('active_run');

final class _LoopbackModelService {
  static const modelId = 'synthetic-loopback-agent';

  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;
  final List<Map<String, dynamic>> chatBodies = [];
  final List<String> failures = [];
  bool duplicateNextTaskCall = false;
  String? forwardedProof;

  Uri get baseUri {
    final server = _server;
    if (server == null) throw StateError('Loopback server is not started.');
    return Uri(scheme: 'http', host: '127.0.0.1', port: server.port);
  }

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _subscription = server.listen((request) {
      unawaited(_handle(request));
    });
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.method == 'GET' && request.uri.path == '/v1/models') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {'id': modelId},
            ],
          }),
        );
        await request.response.close();
        return;
      }
      if (request.method != 'POST' ||
          request.uri.path != '/v1/chat/completions') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      chatBodies.add(body);
      final messages = body['messages'] as List<dynamic>;
      final lastMessage = messages.last as Map<String, dynamic>;
      final toolChoice = body['tool_choice'];

      if (body['tools'] == null) {
        await _writeText(request.response, 'USTC_TEXT_PROBE');
        return;
      }
      if (toolChoice is Map<String, dynamic> &&
          (toolChoice['function'] as Map)['name'] == 'echo_probe') {
        await _writeToolCall(
          request.response,
          id: 'call:1',
          name: 'echo_probe',
          arguments: const ['{"value":', '"ustc_probe"', '}'],
        );
        return;
      }
      if (toolChoice == 'none') {
        final tool =
            messages.singleWhere(
                  (message) =>
                      (message as Map<String, dynamic>)['role'] == 'tool',
                )
                as Map<String, dynamic>;
        if (tool['tool_call_id'] != 'call:1') {
          throw StateError('Capability tool result used the wrong call ID.');
        }
        final payload =
            jsonDecode(tool['content'] as String) as Map<String, dynamic>;
        forwardedProof = payload['proof'] as String?;
        await _writeText(request.response, forwardedProof ?? 'missing-proof');
        return;
      }
      if (lastMessage['role'] == 'tool') {
        if (lastMessage['tool_call_id'] != 'call.1') {
          throw StateError('Read tool result used the wrong call ID.');
        }
        final result =
            jsonDecode(lastMessage['content'] as String)
                as Map<String, dynamic>;
        final data = result['data'] as Map<String, dynamic>;
        final items = data['items'] as List<dynamic>;
        if (result['status'] != 'success' ||
            items.length != 1 ||
            (items.single as Map)['title'] != '网关集成合成任务') {
          throw StateError('C3 read tool returned an unexpected result.');
        }
        await _writeText(request.response, '已读取合成任务列表。');
        return;
      }

      final names = _toolNames(body);
      if (!names.contains('query_tasks')) {
        throw StateError('The task query did not expose query_tasks.');
      }
      if (duplicateNextTaskCall) {
        duplicateNextTaskCall = false;
        await _writeDuplicateToolCalls(request.response);
      } else {
        await _writeToolCall(
          request.response,
          id: 'call.1',
          name: 'query_tasks',
          arguments: const ['{', '}'],
        );
      }
    } on Object catch (error) {
      failures.add(error.runtimeType.toString());
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } on Object {
        // The client may already have aborted after a protocol failure.
      }
    }
  }

  Future<void> _writeText(HttpResponse response, String text) =>
      _writeSse(response, [
        {
          'choices': [
            {
              'index': 0,
              'delta': {'content': text},
              'finish_reason': null,
            },
          ],
        },
        {
          'choices': [
            {'index': 0, 'delta': <String, Object?>{}, 'finish_reason': 'stop'},
          ],
        },
      ]);

  Future<void> _writeToolCall(
    HttpResponse response, {
    required String id,
    required String name,
    required List<String> arguments,
  }) => _writeSse(response, [
    {
      'choices': [
        {
          'index': 0,
          'delta': {
            'tool_calls': [
              {
                'index': 0,
                'id': id,
                'type': 'function',
                'function': {'name': name, 'arguments': arguments.first},
              },
            ],
          },
          'finish_reason': null,
        },
      ],
    },
    for (final part in arguments.skip(1))
      {
        'choices': [
          {
            'index': 0,
            'delta': {
              'tool_calls': [
                {
                  'index': 0,
                  'function': {'arguments': part},
                },
              ],
            },
            'finish_reason': null,
          },
        ],
      },
    {
      'choices': [
        {
          'index': 0,
          'delta': <String, Object?>{},
          'finish_reason': 'tool_calls',
        },
      ],
    },
  ]);

  Future<void> _writeDuplicateToolCalls(HttpResponse response) =>
      _writeSse(response, [
        {
          'choices': [
            {
              'index': 0,
              'delta': {
                'tool_calls': [
                  for (var index = 0; index < 2; index++)
                    {
                      'index': index,
                      'id': 'call.1',
                      'type': 'function',
                      'function': {'name': 'query_tasks', 'arguments': '{}'},
                    },
                ],
              },
              'finish_reason': null,
            },
          ],
        },
        {
          'choices': [
            {
              'index': 0,
              'delta': <String, Object?>{},
              'finish_reason': 'tool_calls',
            },
          ],
        },
      ]);

  Future<void> _writeSse(
    HttpResponse response,
    List<Map<String, Object?>> events,
  ) async {
    response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    for (final event in events) {
      response.write('data: ${jsonEncode(event)}\n\n');
      await response.flush();
    }
    response.write('data: [DONE]\n\n');
    await response.close();
  }

  Future<void> close() async {
    await _subscription?.cancel();
    await _server?.close(force: true);
    _subscription = null;
    _server = null;
  }
}

final class _CountingReadTools implements AgentReadToolsPort {
  _CountingReadTools(this._delegate);

  final AgentReadTools _delegate;
  int executeCount = 0;

  @override
  List<ModelToolDefinition> get definitions => _delegate.definitions;

  @override
  AgentToolSession openSession() =>
      _CountingToolSession(_delegate.openSession(), () => executeCount++);

  @override
  Future<void> cancelAndDrain() => _delegate.cancelAndDrain();

  @override
  Future<void> close() => _delegate.close();
}

final class _CountingToolSession implements AgentToolSession {
  _CountingToolSession(this._delegate, this._onExecute);

  final AgentToolSession _delegate;
  final void Function() _onExecute;

  @override
  List<AgentEvidence> get evidence => _delegate.evidence;

  @override
  Future<AgentToolResult> execute(ModelToolCall call) {
    _onExecute();
    return _delegate.execute(call);
  }

  @override
  Future<void> validateDelivery() => _delegate.validateDelivery();

  @override
  void revoke() => _delegate.revoke();
}

final class _SyntheticProtector implements ModelCredentialProtector {
  @override
  String get mechanism => 'synthetic-loopback-model-key/v1';

  @override
  Future<Uint8List> protect(
    Uint8List plaintext, {
    required String purpose,
  }) async =>
      Uint8List.fromList([0xA7, ...plaintext.map((byte) => byte ^ 0x5A)]);

  @override
  Future<Uint8List> unprotect(
    Uint8List ciphertext, {
    required String purpose,
  }) async {
    if (ciphertext.isEmpty || ciphertext.first != 0xA7) {
      throw StateError('Synthetic ciphertext was invalid.');
    }
    return Uint8List.fromList(
      ciphertext.skip(1).map((byte) => byte ^ 0x5A).toList(),
    );
  }
}

final class _TestOwnership implements AssetOwnership {
  @override
  bool get isHeld => true;

  @override
  void ensureHeld() {}
}
