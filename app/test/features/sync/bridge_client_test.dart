import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

class FakePythonRunner implements PythonCommandRunner {
  FakePythonRunner({this.queryJobsImportSucceeds = true});

  final calls = <(String, List<String>, Map<String, String>?)>[];
  final bool queryJobsImportSucceeds;

  @override
  Future<ProcessResultValue> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }
  ) async {
    calls.add((executable, [...arguments], environment));
    if (executable == 'conda') {
      return const ProcessResultValue(
        exitCode: 0,
        stdout: 'C:\\envs\\ustc_assistant\\python.exe\n',
        stderr: '',
      );
    }
    if (arguments.join(' ').contains('query_jobs') && !queryJobsImportSucceeds) {
      return const ProcessResultValue(exitCode: 1, stdout: '', stderr: '');
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
    expect(runner.calls.last.$2.join(' '), contains('ustc_assistant.bridge'));
  });

  test('python locator rejects a legacy Bridge without query jobs', () async {
    final runner = FakePythonRunner(queryJobsImportSucceeds: false);
    final locator = PythonLocator(runner: runner, environment: const {});
    final legacyBridge = await runner.run('legacy-python.exe', const [
      '-c',
      'import ustc_assistant.bridge',
    ]);
    expect(legacyBridge.exitCode, 0);

    await expectLater(
      locator.locate(
        savedExecutable: 'legacy-python.exe',
        requiredModule: 'ustc_assistant.bridge.query_jobs',
      ),
      throwsA(isA<PythonLocationError>().having(
        (error) => error.code,
        'code',
        'bridge_import_failed',
      )),
    );
  });

  test('python locator uses the injected development PYTHONPATH for query probing',
      () async {
    final runner = FakePythonRunner(queryJobsImportSucceeds: true);
    final locator = PythonLocator(runner: runner, environment: const {});

    await locator.locate(
      savedExecutable: 'development-python.exe',
      requiredModule: 'ustc_assistant.bridge.query_jobs',
      importEnvironment: const {'PYTHONPATH': r'C:\worktree\src'},
    );

    expect(runner.calls.last.$3, {'PYTHONPATH': r'C:\worktree\src'});
  });

  test('development bridge options discover the worktree above app', () async {
    final root = await Directory.systemTemp.createTemp('bridge-root-');
    addTearDown(() => root.delete(recursive: true));
    final queryJobs = File(
      '${root.path}${Platform.pathSeparator}src${Platform.pathSeparator}'
      'ustc_assistant${Platform.pathSeparator}bridge${Platform.pathSeparator}'
      'query_jobs.py',
    );
    await queryJobs.parent.create(recursive: true);
    await queryJobs.writeAsString('# fixture');
    final appDirectory = Directory('${root.path}${Platform.pathSeparator}app');
    await appDirectory.create();

    final options = resolveBridgeLaunchOptions(
      startDirectory: appDirectory,
      environment: const {},
    );

    expect(options.workingDirectory, root.path);
    expect(options.environment!['PYTHONPATH'], '${root.path}${Platform.pathSeparator}src');
    expect(options.environment!['USTC_ASSISTANT_DATA_ROOT'],
        '${root.path}${Platform.pathSeparator}tmp${Platform.pathSeparator}bridge-data');
  });

  test('BridgeClient passes explicit working directory and environment', () async {
    final launcher = FakeLauncher(FakeProcess(handshake()));
    final client = await BridgeClient.start(
      pythonExecutable: 'python',
      launcher: launcher,
      httpClient: MockClient((_) async => http.Response('{"ok":true}', 200)),
      launchOptions: const BridgeLaunchOptions(
        workingDirectory: r'C:\worktree',
        environment: {'PYTHONPATH': r'C:\worktree\src'},
      ),
    );
    addTearDown(client.shutdown);

    expect(launcher.options.workingDirectory, r'C:\worktree');
    expect(launcher.options.environment!['PYTHONPATH'], r'C:\worktree\src');
  });
}
