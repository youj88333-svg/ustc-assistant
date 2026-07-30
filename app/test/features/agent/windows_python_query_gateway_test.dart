import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ustc_assistant_app/features/agent/application/cancellation_signal.dart';
import 'package:ustc_assistant_app/features/agent/data/windows_python_query_gateway.dart';
import 'package:ustc_assistant_app/features/agent/domain/query_source.dart';
import 'package:ustc_assistant_app/features/sync/data/bridge_client.dart';

/// A fake Bridge child process that emits a handshake line on stdout.
class FakeProcess implements BridgeChildProcess {
  FakeProcess(String handshake)
    : _stdout = Stream.value(utf8.encode('$handshake\n'));

  final Stream<List<int>> _stdout;
  var killed = false;

  @override
  Future<int> get exitCode async => 0;

  @override
  bool kill() => killed = true;

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  Stream<List<int>> get stdout => _stdout;
}

class FakeLauncher implements BridgeProcessLauncher {
  FakeLauncher(this.process);

  final FakeProcess process;
  String? executable;
  List<String> arguments = [];
  BridgeLaunchOptions options = const BridgeLaunchOptions();

  @override
  Future<BridgeChildProcess> start(
    String executable,
    List<String> arguments, {
    BridgeLaunchOptions options = const BridgeLaunchOptions(),
  }) async {
    this.executable = executable;
    this.arguments = [...arguments];
    this.options = options;
    return process;
  }
}

String handshake({
  String version = '1.0',
  String token = 'secret-token-that-is-long',
}) => jsonEncode({
  'protocolVersion': version,
  'port': 18080,
  'token': token,
  'pid': 42,
});

/// A scripted query-events responder. Returns successive poll batches.
class _PollScript {
  _PollScript(this._batches);
  final List<Map<String, Object?>> _batches;
  int _index = 0;

  Map<String, Object?> next() {
    if (_index >= _batches.length) {
      // Hold at the last (terminal) batch for any extra polls.
      return _batches.last;
    }
    return _batches[_index++];
  }
}

/// Helper: a poll batch with a single phase event.
Map<String, Object?> _batch({
  required int sequence,
  required String phase,
  int? safeCount,
  bool terminal = false,
  Map<String, dynamic>? result,
  Map<String, dynamic>? error,
  int nextSequence = -1,
}) => {
  'events': [
    {'sequence': sequence, 'phase': phase, 'safeCount': ?safeCount},
  ],
  'nextSequence': nextSequence < 0 ? sequence : nextSequence,
  'terminal': terminal,
  'result': result,
  'error': error,
};

const _envelope = <String, dynamic>{
  'schemaVersion': '1.0',
  'queryType': 'campus_search',
  'generatedAt': '2026-07-29T09:00:00+08:00',
  'data': {'query': 'lib', 'results': <Map<String, Object?>>[]},
  'metadata': {'resultCount': 0},
  'references': <String>[],
};

void main() {
  group('WindowsPythonQueryGateway protocol', () {
    test('POST /queries uses fixed route, bearer token, queryProtocolVersion',
        () async {
      final process = FakeProcess(handshake());
      final launcher = FakeLauncher(process);
      final requests = <http.Request>[];
      String? authHeader;
      Map<String, dynamic>? postedBody;
      final poll = _PollScript([
        _batch(sequence: 1, phase: 'complete', terminal: true, result: _envelope),
      ]);
      final httpClient = MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/queries') {
          authHeader = request.headers['authorization'];
          postedBody =
              jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({'jobId': 'qjob-1', 'phase': 'starting'}),
            202,
          );
        }
        if (request.url.path == '/query-jobs/qjob-1/events') {
          return http.Response(jsonEncode(poll.next()), 200);
        }
        if (request.url.path == '/shutdown') {
          return http.Response('{"ok":true}', 200);
        }
        return http.Response('{"error":"not_found"}', 404);
      });

      final gateway = await WindowsPythonQueryGateway.start(
        pythonExecutable: 'python.exe',
        launcher: launcher,
        httpClient: httpClient,
        parentPid: 99,
      );
      addTearDown(gateway.shutdown);

      final events = await gateway
          .execute(
            const CampusSearchQueryRequest(query: 'lib'),
            cancellation: CancellationSignal(),
          )
          .toList();

      expect(postedBody, isNotNull);
      expect(postedBody!['protocolVersion'], '1.0');
      expect(postedBody!['queryProtocolVersion'], '1.0');
      expect(postedBody!['query'], isA<Map<String, dynamic>>());
      expect(
        (postedBody!['query'] as Map)['type'],
        'campus_search',
      );
      // SECURITY: the model API Key never appears in the request body.
      final bodyJson = jsonEncode(postedBody);
      expect(bodyJson, isNot(contains('apiKey')));
      expect(bodyJson, isNot(contains('api_key')));
      expect(bodyJson, isNot(contains('sk-')));
      expect(authHeader, 'Bearer secret-token-that-is-long');
      // The query request for a public search has no account identity.
      expect(postedBody!.containsKey('accountId'), isFalse);
      expect(postedBody!.containsKey('expectedUsername'), isFalse);

      expect(events, isNotEmpty);
      expect(events.last, isA<SourceQueryCompleted>());
      expect(
        requests.map((r) => r.url.path),
        containsAll(['/queries', '/query-jobs/qjob-1/events']),
      );
    });

    test('polls until terminal and emits completed with result version', () async {
      final process = FakeProcess(handshake());
      final launcher = FakeLauncher(process);
      final poll = _PollScript([
        _batch(sequence: 1, phase: 'starting'),
        _batch(sequence: 2, phase: 'collecting', safeCount: 5),
        _batch(sequence: 3, phase: 'complete', terminal: true, result: _envelope),
      ]);
      final httpClient = MockClient((request) async {
        if (request.url.path == '/queries') {
          return http.Response(
            jsonEncode({'jobId': 'qjob-2', 'phase': 'starting'}),
            202,
          );
        }
        if (request.url.path == '/query-jobs/qjob-2/events') {
          return http.Response(jsonEncode(poll.next()), 200);
        }
        if (request.url.path == '/shutdown') {
          return http.Response('{"ok":true}', 200);
        }
        return http.Response('{"error":"not_found"}', 404);
      });
      final gateway = await WindowsPythonQueryGateway.start(
        pythonExecutable: 'python',
        launcher: launcher,
        httpClient: httpClient,
        parentPid: 99,
      );
      addTearDown(gateway.shutdown);

      final events = await gateway
          .execute(
            const CampusSearchQueryRequest(query: 'lib'),
            cancellation: CancellationSignal(),
          )
          .toList();

      // Progress events then a terminal completed.
      expect(events, hasLength(3));
      expect(events[0], isA<SourceQueryProgress>());
      expect((events[0] as SourceQueryProgress).phase, 'starting');
      expect(events[1], isA<SourceQueryProgress>());
      expect((events[1] as SourceQueryProgress).safeCount, 5);
      expect(events[2], isA<SourceQueryCompleted>());
      final completed = events[2] as SourceQueryCompleted;
      expect(completed.result.schemaVersion, '1.0');
      expect(completed.result.queryType, 'campus_search');
    });

    test('maps a 409 Bridge start error to a bounded query failure', () async {
      final gateway = await WindowsPythonQueryGateway.start(
        pythonExecutable: 'python',
        launcher: FakeLauncher(FakeProcess(handshake())),
        httpClient: MockClient((request) async {
          if (request.url.path == '/shutdown') {
            return http.Response('{"ok":true}', 200);
          }
          return http.Response(
            '{"error":"bridge_query_busy","detail":"E:\\\\private"}',
            409,
          );
        }),
      );
      addTearDown(gateway.shutdown);

      final events = await gateway.execute(
        const CampusSearchQueryRequest(query: 'lib'),
        cancellation: CancellationSignal(),
      ).toList();

      expect(events.single, isA<SourceQueryFailed>());
      expect((events.single as SourceQueryFailed).code, 'bridge_query_busy');
    });

    test('maps a 404 Bridge poll error to a bounded query failure', () async {
      final gateway = await WindowsPythonQueryGateway.start(
        pythonExecutable: 'python',
        launcher: FakeLauncher(FakeProcess(handshake())),
        httpClient: MockClient((request) async {
          if (request.url.path == '/queries') {
            return http.Response('{"jobId":"missing-1","phase":"starting"}', 202);
          }
          if (request.url.path == '/query-jobs/missing-1/events') {
            return http.Response(
              '{"error":"query_job_not_found","detail":"E:\\\\private"}',
              404,
            );
          }
          return http.Response('{"ok":true}', 200);
        }),
      );
      addTearDown(gateway.shutdown);

      final events = await gateway.execute(
        const CampusSearchQueryRequest(query: 'lib'),
        cancellation: CancellationSignal(),
      ).toList();

      expect(events.single, isA<SourceQueryFailed>());
      expect((events.single as SourceQueryFailed).code, 'query_job_not_found');
    });

    test('maps a malformed Bridge response to invalid_response', () async {
      final gateway = await WindowsPythonQueryGateway.start(
        pythonExecutable: 'python',
        launcher: FakeLauncher(FakeProcess(handshake())),
        httpClient: MockClient((request) async {
          if (request.url.path == '/shutdown') {
            return http.Response('{"ok":true}', 200);
          }
          return http.Response('<html>E:\\private</html>', 200);
        }),
      );
      addTearDown(gateway.shutdown);

      final events = await gateway.execute(
        const CampusSearchQueryRequest(query: 'lib'),
        cancellation: CancellationSignal(),
      ).toList();

      expect(events.single, isA<SourceQueryFailed>());
      expect((events.single as SourceQueryFailed).code, 'invalid_response');
    });

    test('emits SourceQueryFailed on terminal error with safe code', () async {
      final process = FakeProcess(handshake());
      final launcher = FakeLauncher(process);
      final poll = _PollScript([
        _batch(
          sequence: 1,
          phase: 'failed',
          terminal: true,
          error: {'code': 'query_failed', 'message': 'Query execution failed'},
        ),
      ]);
      final httpClient = MockClient((request) async {
        if (request.url.path == '/queries') {
          return http.Response(
            jsonEncode({'jobId': 'qjob-3', 'phase': 'starting'}),
            202,
          );
        }
        if (request.url.path == '/query-jobs/qjob-3/events') {
          return http.Response(jsonEncode(poll.next()), 200);
        }
        if (request.url.path == '/shutdown') {
          return http.Response('{"ok":true}', 200);
        }
        return http.Response('{"error":"not_found"}', 404);
      });
      final gateway = await WindowsPythonQueryGateway.start(
        pythonExecutable: 'python',
        launcher: launcher,
        httpClient: httpClient,
        parentPid: 99,
      );
      addTearDown(gateway.shutdown);

      final events = await gateway
          .execute(
            const CampusSearchQueryRequest(query: 'lib'),
            cancellation: CancellationSignal(),
          )
          .toList();

      expect(events.last, isA<SourceQueryFailed>());
      expect((events.last as SourceQueryFailed).code, 'query_failed');
    });

    test('maps an unknown terminal error code to query_failed', () async {
      final poll = _PollScript([
        _batch(
          sequence: 1,
          phase: 'failed',
          terminal: true,
          error: {'code': r'database_password=E:\private'},
        ),
      ]);
      final gateway = await WindowsPythonQueryGateway.start(
        pythonExecutable: 'python',
        launcher: FakeLauncher(FakeProcess(handshake())),
        httpClient: MockClient((request) async {
          if (request.url.path == '/queries') {
            return http.Response('{"jobId":"qjob-unsafe","phase":"starting"}', 202);
          }
          if (request.url.path == '/query-jobs/qjob-unsafe/events') {
            return http.Response(jsonEncode(poll.next()), 200);
          }
          return http.Response('{"ok":true}', 200);
        }),
      );
      addTearDown(gateway.shutdown);

      final events = await gateway.execute(
        const CampusSearchQueryRequest(query: 'lib'),
        cancellation: CancellationSignal(),
      ).toList();

      expect((events.single as SourceQueryFailed).code, 'query_failed');
    });

    test('maps legal JSON with malformed start and poll shapes to invalid_response',
        () async {
      final malformedResponses = <Map<String, Object?>>[
        {'jobId': 1, 'phase': 'starting'},
        {
          'events': 'not-a-list',
          'nextSequence': 1,
          'terminal': false,
          'result': null,
          'error': null,
        },
        {
          'events': [
            {'sequence': 1, 'phase': 'starting', 'safeCount': 'one'},
          ],
          'nextSequence': 1,
          'terminal': false,
          'result': null,
          'error': null,
        },
        {
          'events': [],
          'nextSequence': 'one',
          'terminal': false,
          'result': null,
          'error': null,
        },
        {
          'events': [],
          'nextSequence': 1,
          'terminal': 'false',
          'result': null,
          'error': null,
        },
        {
          'events': [],
          'nextSequence': 1,
          'terminal': true,
          'result': [],
          'error': null,
        },
      ];

      for (final malformed in malformedResponses) {
        final gateway = await WindowsPythonQueryGateway.start(
          pythonExecutable: 'python',
          launcher: FakeLauncher(FakeProcess(handshake())),
          httpClient: MockClient((request) async {
            if (request.url.path == '/queries') {
              if (malformed.containsKey('jobId')) {
                return http.Response(jsonEncode(malformed), 202);
              }
              return http.Response('{"jobId":"qjob-malformed","phase":"starting"}', 202);
            }
            if (request.url.path == '/query-jobs/qjob-malformed/events') {
              return http.Response(jsonEncode(malformed), 200);
            }
            return http.Response('{"ok":true}', 200);
          }),
        );
        addTearDown(gateway.shutdown);

        final events = await gateway.execute(
          const CampusSearchQueryRequest(query: 'lib'),
          cancellation: CancellationSignal(),
        ).toList();

        expect((events.single as SourceQueryFailed).code, 'invalid_response');
      }
    });

    test('maps malformed terminal Query Result envelopes to invalid_response',
        () async {
      final malformedResults = <Map<String, dynamic>>[
        {..._envelope, 'data': <Object?>[]},
        {
          'schemaVersion': '1.0',
          'queryType': 'campus_search',
          'generatedAt': '2026-07-29T09:00:00+08:00',
          'data': <String, dynamic>{},
          'references': <String>[],
        },
        {..._envelope, 'schemaVersion': 1},
        {..._envelope, 'queryType': 1},
        {..._envelope, 'generatedAt': 1},
        {..._envelope, 'metadata': <Object?>[]},
        {..._envelope, 'references': <Object?>[1]},
      ];

      for (final malformedResult in malformedResults) {
        final poll = _PollScript([
          _batch(
            sequence: 1,
            phase: 'complete',
            terminal: true,
            result: malformedResult,
          ),
        ]);
        final gateway = await WindowsPythonQueryGateway.start(
          pythonExecutable: 'python',
          launcher: FakeLauncher(FakeProcess(handshake())),
          httpClient: MockClient((request) async {
            if (request.url.path == '/queries') {
              return http.Response(
                '{"jobId":"qjob-invalid-envelope","phase":"starting"}',
                202,
              );
            }
            if (request.url.path ==
                '/query-jobs/qjob-invalid-envelope/events') {
              return http.Response(jsonEncode(poll.next()), 200);
            }
            return http.Response('{"ok":true}', 200);
          }),
        );
        addTearDown(gateway.shutdown);

        final events = await gateway.execute(
          const CampusSearchQueryRequest(query: 'lib'),
          cancellation: CancellationSignal(),
        ).toList();

        expect(events.single, isA<SourceQueryFailed>());
        expect((events.single as SourceQueryFailed).code, 'invalid_response');
      }
    });

    test('needs_user_login pauses the stream, resumeLogin uses fixed route',
        () async {
      final process = FakeProcess(handshake());
      final launcher = FakeLauncher(process);
      final requests = <http.Request>[];
      // First poll returns needs_user_login (non-terminal, pause).
      // After resume, subsequent polls return complete.
      var resumed = false;
      final httpClient = MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/queries') {
          return http.Response(
            jsonEncode({'jobId': 'young-1', 'phase': 'starting'}),
            202,
          );
        }
        if (request.url.path == '/query-jobs/young-1/events') {
          if (!resumed) {
            return http.Response(
              jsonEncode(_batch(
                sequence: 1,
                phase: 'needs_user_login',
              )),
              200,
            );
          }
          return http.Response(
            jsonEncode(_batch(
              sequence: 2,
              phase: 'complete',
              terminal: true,
              result: {
                'schemaVersion': '1.0',
                'queryType': 'young_enrolment',
                'generatedAt': '2026-07-29T09:00:00+08:00',
                'data': <String, dynamic>{'activities': <Map<String, Object?>>[]},
                'metadata': <String, dynamic>{},
                'references': <String>[],
              },
            )),
            200,
          );
        }
        if (request.url.path == '/query-jobs/young-1/resume-login') {
          resumed = true;
          return http.Response(
            jsonEncode({'jobId': 'young-1', 'phase': 'collecting'}),
            202,
          );
        }
        if (request.url.path == '/shutdown') {
          return http.Response('{"ok":true}', 200);
        }
        return http.Response('{"error":"not_found"}', 404);
      });
      final gateway = await WindowsPythonQueryGateway.start(
        pythonExecutable: 'python',
        launcher: launcher,
        httpClient: httpClient,
        parentPid: 99,
      );
      addTearDown(gateway.shutdown);

      final cancellation = CancellationSignal();
      // Collect events but stop consuming after the pause so we can resume
      // explicitly. Use a completer to wait for the needs_user_login event.
      final eventList = <SourceQueryEvent>[];
      final paused = Completer<void>();
      final subscription = gateway
          .execute(
            YoungEnrolmentQueryRequest(
              accountId: 'account',
              expectedUsername: 'PB00000000',
            ),
            cancellation: cancellation,
          )
          .listen(eventList.add, onDone: () {});

      await paused.future.timeout(const Duration(seconds: 5), onTimeout: () {
        // If the pause event hasn't arrived, proceed to check the list.
      });
      // Give the stream a moment to emit the pause event.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // Wait until the needs_user_login event appears (poll loop should emit it).
      for (var i = 0; i < 40 && eventList.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(eventList, isNotEmpty);
      final pauseEvent = eventList.whereType<SourceQueryNeedsLogin>().firstOrNull;
      expect(pauseEvent, isNotNull,
          reason: 'expected a SourceQueryNeedsLogin event');
      expect(pauseEvent!.jobId, 'young-1');

      // SECURITY: the young_enrolment request carries account identity but
      // never the model API Key.
      final startRequest = requests.firstWhere(
        (r) => r.url.path == '/queries',
      );
      final startBody = jsonDecode(startRequest.body) as Map<String, dynamic>;
      expect(startBody['accountId'], 'account');
      expect(startBody['expectedUsername'], 'PB00000000');
      final startJson = jsonEncode(startBody);
      expect(startJson, isNot(contains('apiKey')));
      expect(startJson, isNot(contains('api_key')));

      // Now resume with the protected school password.
      await gateway.resumeLogin('young-1', password: 'school-pass');

      // Wait for the terminal completed event.
      await subscription.asFuture().timeout(const Duration(seconds: 5));
      await subscription.cancel();

      expect(eventList.last, isA<SourceQueryCompleted>());
      // Assert the resume-login fixed route and body shape.
      final resumeRequest = requests.firstWhere(
        (r) => r.url.path == '/query-jobs/young-1/resume-login',
      );
      expect(resumeRequest.headers['authorization'],
          'Bearer secret-token-that-is-long');
      final resumeBody =
          jsonDecode(resumeRequest.body) as Map<String, dynamic>;
      expect(resumeBody['protocolVersion'], '1.0');
      expect(resumeBody['password'], 'school-pass');
    });

    test('cancellation POSTs /cancel and emits failed(cancelled)', () async {
      final process = FakeProcess(handshake());
      final launcher = FakeLauncher(process);
      final requests = <http.Request>[];
      // The poll never becomes terminal on its own; cancellation drives it.
      final httpClient = MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/queries') {
          return http.Response(
            jsonEncode({'jobId': 'cancel-1', 'phase': 'starting'}),
            202,
          );
        }
        if (request.url.path == '/query-jobs/cancel-1/events') {
          // Keep returning a non-terminal starting batch.
          return http.Response(
            jsonEncode(_batch(sequence: 1, phase: 'starting')),
            200,
          );
        }
        if (request.url.path == '/query-jobs/cancel-1/cancel') {
          return http.Response(
            jsonEncode({'jobId': 'cancel-1', 'phase': 'cancelled'}),
            202,
          );
        }
        if (request.url.path == '/shutdown') {
          return http.Response('{"ok":true}', 200);
        }
        return http.Response('{"error":"not_found"}', 404);
      });
      final gateway = await WindowsPythonQueryGateway.start(
        pythonExecutable: 'python',
        launcher: launcher,
        httpClient: httpClient,
        parentPid: 99,
      );
      addTearDown(gateway.shutdown);

      final cancellation = CancellationSignal();
      final events = <SourceQueryEvent>[];
      final done = Completer<void>();
      final subscription = gateway
          .execute(
            const CampusSearchQueryRequest(query: 'lib'),
            cancellation: cancellation,
          )
          .listen(events.add, onDone: done.complete);

      // Let one poll happen, then cancel.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      cancellation.cancel();

      await done.future.timeout(const Duration(seconds: 5));
      await subscription.cancel();

      expect(events.last, isA<SourceQueryFailed>());
      expect((events.last as SourceQueryFailed).code, 'cancelled');
      expect(
        requests.map((r) => r.url.path),
        contains('/query-jobs/cancel-1/cancel'),
      );
      final cancelReq = requests.firstWhere(
        (r) => r.url.path == '/query-jobs/cancel-1/cancel',
      );
      final cancelBody =
          jsonDecode(cancelReq.body) as Map<String, dynamic>;
      expect(cancelBody['protocolVersion'], '1.0');
    });

    test('shutdown POSTs /shutdown then kills the process', () async {
      final process = FakeProcess(handshake());
      final launcher = FakeLauncher(process);
      final requests = <http.Request>[];
      final httpClient = MockClient((request) async {
        requests.add(request);
        return http.Response('{"ok":true}', 200);
      });
      final gateway = await WindowsPythonQueryGateway.start(
        pythonExecutable: 'python',
        launcher: launcher,
        httpClient: httpClient,
        parentPid: 99,
      );

      await gateway.shutdown();

      expect(
        requests.map((r) => r.url.path),
        contains('/shutdown'),
      );
      expect(process.killed, isTrue);
    });

    test('explicit cancel(jobId) uses the fixed cancel route', () async {
      final process = FakeProcess(handshake());
      final launcher = FakeLauncher(process);
      final requests = <http.Request>[];
      final httpClient = MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/query-jobs/explicit-1/cancel') {
          return http.Response(
            jsonEncode({'jobId': 'explicit-1', 'phase': 'cancelled'}),
            202,
          );
        }
        return http.Response('{"ok":true}', 200);
      });
      final gateway = await WindowsPythonQueryGateway.start(
        pythonExecutable: 'python',
        launcher: launcher,
        httpClient: httpClient,
        parentPid: 99,
      );
      addTearDown(gateway.shutdown);

      await gateway.cancel('explicit-1');

      expect(
        requests.map((r) => r.url.path),
        contains('/query-jobs/explicit-1/cancel'),
      );
    });

    test('young_enrolment sends accountId + expectedUsername, no API key',
        () async {
      final process = FakeProcess(handshake());
      final launcher = FakeLauncher(process);
      Map<String, dynamic>? postedBody;
      final poll = _PollScript([
        _batch(sequence: 1, phase: 'complete', terminal: true, result: {
          'schemaVersion': '1.0',
          'queryType': 'young_enrolment',
          'generatedAt': '2026-07-29T09:00:00+08:00',
          'data': <String, dynamic>{'activities': <Map<String, Object?>>[]},
          'metadata': <String, dynamic>{},
          'references': <String>[],
        }),
      ]);
      final httpClient = MockClient((request) async {
        if (request.url.path == '/queries') {
          postedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({'jobId': 'y-1', 'phase': 'starting'}),
            202,
          );
        }
        if (request.url.path == '/query-jobs/y-1/events') {
          return http.Response(jsonEncode(poll.next()), 200);
        }
        if (request.url.path == '/shutdown') {
          return http.Response('{"ok":true}', 200);
        }
        return http.Response('{"error":"not_found"}', 404);
      });
      final gateway = await WindowsPythonQueryGateway.start(
        pythonExecutable: 'python',
        launcher: launcher,
        httpClient: httpClient,
        parentPid: 99,
      );
      addTearDown(gateway.shutdown);

      await gateway
          .execute(
            const YoungEnrolmentQueryRequest(
              accountId: 'acct',
              expectedUsername: 'PB11111111',
            ),
            cancellation: CancellationSignal(),
          )
          .toList();

      expect(postedBody!['accountId'], 'acct');
      expect(postedBody!['expectedUsername'], 'PB11111111');
      final json = jsonEncode(postedBody);
      expect(json, isNot(contains('apiKey')));
      expect(json, isNot(contains('api_key')));
      expect(json, isNot(contains('sk-')));
    });

    test('gateway never accepts a URL from a tool argument', () async {
      final process = FakeProcess(handshake());
      final launcher = FakeLauncher(process);
      Map<String, dynamic>? postedBody;
      final poll = _PollScript([
        _batch(sequence: 1, phase: 'complete', terminal: true, result: _envelope),
      ]);
      final httpClient = MockClient((request) async {
        if (request.url.path == '/queries') {
          postedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({'jobId': 'u-1', 'phase': 'starting'}),
            202,
          );
        }
        if (request.url.path == '/query-jobs/u-1/events') {
          return http.Response(jsonEncode(poll.next()), 200);
        }
        if (request.url.path == '/shutdown') {
          return http.Response('{"ok":true}', 200);
        }
        return http.Response('{"error":"not_found"}', 404);
      });
      final gateway = await WindowsPythonQueryGateway.start(
        pythonExecutable: 'python',
        launcher: launcher,
        httpClient: httpClient,
        parentPid: 99,
      );
      addTearDown(gateway.shutdown);

      // A campus detail request uses entryIds only — no URL field. The Dart
      // request type has no URL property, so a URL cannot be smuggled in.
      await gateway
          .execute(
            const CampusDetailQueryRequest(entryIds: <String>['campus_1']),
            cancellation: CancellationSignal(),
          )
          .toList();

      expect(postedBody, isNotNull);
      final query = postedBody!['query'] as Map<String, dynamic>;
      expect(query['type'], 'campus_detail');
      expect(query['entryId'], 'campus_1');
      // No URL/filesystem field names anywhere in the request.
      final bodyJson = jsonEncode(postedBody);
      expect(bodyJson, isNot(contains('"url"')));
      expect(bodyJson, isNot(contains('"href"')));
      expect(bodyJson, isNot(contains('"path"')));
      expect(bodyJson, isNot(contains('"sourceUrl"')));
    });

    test(
      'deadline (maxWait) cancels the orphaned Bridge job before query_timeout',
      () async {
        // Regression guard: the _maxWait deadline path must cancel the
        // orphaned Bridge job (POST /cancel) before yielding query_timeout,
        // mirroring the cancellation/paused-login/idle exit paths. Without
        // this, a job that never reaches a terminal phase would leak as a
        // zombie consuming Bridge resources until process exit.
        final process = FakeProcess(handshake());
        final launcher = FakeLauncher(process);
        final requests = <http.Request>[];
        final httpClient = MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/queries') {
            return http.Response(
              jsonEncode({'jobId': 'timeout-1', 'phase': 'starting'}),
              202,
            );
          }
          if (request.url.path == '/query-jobs/timeout-1/events') {
            // Never terminal: keeps returning a `starting` phase batch.
            return http.Response(
              jsonEncode(_batch(sequence: 1, phase: 'starting')),
              200,
            );
          }
          if (request.url.path == '/query-jobs/timeout-1/cancel') {
            return http.Response(
              jsonEncode({'jobId': 'timeout-1', 'phase': 'cancelled'}),
              202,
            );
          }
          if (request.url.path == '/shutdown') {
            return http.Response('{"ok":true}', 200);
          }
          return http.Response('{"error":"not_found"}', 404);
        });
        // Inject a tiny deadline so the test is deterministic and does not
        // wait the real 10-minute _defaultMaxWait.
        final gateway = await WindowsPythonQueryGateway.start(
          pythonExecutable: 'python',
          launcher: launcher,
          httpClient: httpClient,
          parentPid: 99,
          maxWait: const Duration(milliseconds: 300),
        );
        addTearDown(gateway.shutdown);

        final events = await gateway
            .execute(
              const CampusSearchQueryRequest(query: 'lib'),
              cancellation: CancellationSignal(),
            )
            .toList();

        // The deadline fired and yielded a query_timeout failure.
        expect(events.last, isA<SourceQueryFailed>());
        expect((events.last as SourceQueryFailed).code, 'query_timeout');
        // The orphaned job was cancelled — the cancel route was hit.
        expect(
          requests.map((r) => r.url.path),
          contains('/query-jobs/timeout-1/cancel'),
          reason: 'deadline path must cancel the orphaned Bridge job, '
              'not leave it as a zombie',
        );
      },
    );
  });
}
