import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ustc_assistant_app/features/sync/data/bridge_client.dart';
import 'package:ustc_assistant_app/features/sync/data/python_locator.dart';
import 'package:ustc_assistant_app/features/sync/domain/sync_state.dart';

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

  @override
  Future<BridgeChildProcess> start(
    String executable,
    List<String> arguments,
  ) async {
    this.executable = executable;
    this.arguments = [...arguments];
    return process;
  }
}

class FakePythonRunner implements PythonCommandRunner {
  final calls = <(String, List<String>)>[];

  @override
  Future<ProcessResultValue> run(
    String executable,
    List<String> arguments,
  ) async {
    calls.add((executable, [...arguments]));
    if (executable == 'conda') {
      return const ProcessResultValue(
        exitCode: 0,
        stdout: 'C:\\envs\\ustc_assistant\\python.exe\n',
        stderr: '',
      );
    }
    return const ProcessResultValue(exitCode: 0, stdout: '', stderr: '');
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

void main() {
  test(
    'token never appears in process arguments and authenticates requests',
    () async {
      final process = FakeProcess(handshake());
      final launcher = FakeLauncher(process);
      String? authorization;
      final httpClient = MockClient((request) async {
        authorization = request.headers['authorization'];
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'protocolVersion': '1.0',
              'supportedProtocolVersions': ['1.0'],
              'jwSemester': {
                'semesterId': 461,
                'semesterKey': '2026fall',
                'displayName': '2026 秋季学期',
              },
            }),
          ),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final client = await BridgeClient.start(
        pythonExecutable: 'python.exe',
        launcher: launcher,
        httpClient: httpClient,
        parentPid: 99,
      );

      final capabilities = await client.capabilities();

      expect(launcher.arguments.join(' '), isNot(contains('secret-token')));
      expect(launcher.arguments, containsAll(['--parent-pid', '99']));
      expect(authorization, 'Bearer secret-token-that-is-long');
      expect(capabilities.jwSemester.semesterId, 461);
    },
  );

  test('invalid and incompatible handshakes kill the child', () async {
    final invalid = FakeProcess('{bad json');
    expect(
      BridgeClient.start(
        pythonExecutable: 'python',
        launcher: FakeLauncher(invalid),
      ),
      throwsA(anything),
    );
    await Future<void>.delayed(Duration.zero);
    expect(invalid.killed, isTrue);

    final incompatible = FakeProcess(handshake(version: '2.0'));
    expect(
      BridgeClient.start(
        pythonExecutable: 'python',
        launcher: FakeLauncher(incompatible),
      ),
      throwsA(isA<BridgeProtocolError>()),
    );
  });

  test(
    'collection polling, resume, cancel and shutdown use fixed routes',
    () async {
      final requests = <http.Request>[];
      final process = FakeProcess(handshake());
      final client = await BridgeClient.start(
        pythonExecutable: 'python',
        launcher: FakeLauncher(process),
        httpClient: MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/collect/jw') {
            return http.Response('{"jobId":"job-1","phase":"starting"}', 202);
          }
          if (request.url.path.endsWith('/events')) {
            return http.Response(
              '{"events":[{"sequence":1,"phase":"needs_user_login"}],'
              '"nextSequence":1,"terminal":false,"result":null,"error":null}',
              200,
            );
          }
          return http.Response(
            '{"ok":true,"jobId":"job-1","phase":"collecting"}',
            202,
          );
        }),
      );
      final job = await client.startCollection(
        source: SyncSource.jw,
        accountId: 'account',
        expectedUsername: 'PB00000000',
        jwSemester: const BridgeSemesterCapability(
          semesterId: 461,
          semesterKey: '2026fall',
          displayName: '2026 秋季学期',
        ),
      );
      expect((await client.poll(job.id, 0)).lastPhase, 'needs_user_login');
      await client.resumeLogin(job.id, password: 'local-only');
      await client.cancel(job.id);
      await client.shutdown();
      expect(
        requests.map((request) => request.url.path),
        containsAll([
          '/collect/jw',
          '/jobs/job-1/events',
          '/login/resume',
          '/jobs/job-1/cancel',
          '/shutdown',
        ]),
      );
      expect(process.killed, isTrue);
    },
  );

  test('python locator verifies resolved conda interpreter', () async {
    final runner = FakePythonRunner();
    final locator = PythonLocator(runner: runner, environment: const {});
    final path = await locator.locate();
    expect(path, r'C:\envs\ustc_assistant\python.exe');
    expect(runner.calls.first.$1, 'conda');
    expect(runner.calls.last.$2, contains('import ustc_assistant.bridge'));
  });

  test('BridgeQueryGateway uses fixed query routes and bearer token', () async {
    final requests = <http.Request>[];
    final process = FakeProcess(handshake());
    final client = await BridgeClient.start(
      pythonExecutable: 'python',
      launcher: FakeLauncher(process),
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/queries') {
          return http.Response(
            '{"jobId":"q-1","phase":"starting"}',
            202,
          );
        }
        if (request.url.path == '/query-jobs/q-1/events') {
          return http.Response(
            '{"events":[{"sequence":1,"phase":"complete"}],'
            '"nextSequence":1,"terminal":true,'
            '"result":{"schemaVersion":"1.0","queryType":"icourse",'
            '"generatedAt":"2026-07-29T09:00:00+08:00","data":{},'
            '"metadata":{},"references":[]},"error":null}',
            200,
          );
        }
        if (request.url.path == '/query-jobs/q-1/resume-login') {
          return http.Response('{"jobId":"q-1","phase":"collecting"}', 202);
        }
        if (request.url.path == '/query-jobs/q-1/cancel') {
          return http.Response('{"jobId":"q-1","phase":"cancelled"}', 202);
        }
        return http.Response('{"ok":true}', 200);
      }),
    );

    // The BridgeClient implements BridgeQueryGateway over the same transport.
    expect(client, isA<BridgeQueryGateway>());
    final queryGateway = client as BridgeQueryGateway;

    final startBody = await queryGateway.postQuery('/queries', {
      'protocolVersion': '1.0',
      'queryProtocolVersion': '1.0',
      'query': {'type': 'icourse', 'course': '数据结构'},
    });
    expect(startBody['jobId'], 'q-1');

    final poll = await queryGateway.getQuery('/query-jobs/q-1/events?after=0');
    expect(poll['terminal'], true);
    final result = poll['result'] as Map<String, dynamic>;
    expect(result['schemaVersion'], '1.0');

    await queryGateway.postQuery('/query-jobs/q-1/resume-login', {
      'protocolVersion': '1.0',
      'password': 'school-pass',
    });
    await queryGateway.postQuery('/query-jobs/q-1/cancel', {
      'protocolVersion': '1.0',
    });
    await client.shutdown();

    expect(
      requests.map((r) => r.url.path),
      containsAll([
        '/queries',
        '/query-jobs/q-1/events',
        '/query-jobs/q-1/resume-login',
        '/query-jobs/q-1/cancel',
        '/shutdown',
      ]),
    );
    // SECURITY: the bearer token authenticates every query request.
    for (final r in requests) {
      expect(r.headers['authorization'], 'Bearer secret-token-that-is-long');
    }
    // SECURITY: the query request body never includes the model API Key.
    final queriesRequest = requests.firstWhere(
      (r) => r.url.path == '/queries',
    );
    expect(queriesRequest.body, isNot(contains('apiKey')));
    expect(queriesRequest.body, isNot(contains('api_key')));
  });
}
