import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../domain/sync_state.dart';

const bridgeProtocolVersion = '1.0';

const _safeBridgeProtocolCodes = {
  'bridge_query_busy',
  'invalid_capabilities',
  'invalid_handshake',
  'invalid_job_state',
  'invalid_response',
  'query_job_not_found',
  'request_failed',
  'unsupported_version',
};

class BridgeProtocolError implements Exception {
  const BridgeProtocolError(this._reportedCode);

  final String _reportedCode;

  String get code => _safeBridgeProtocolCodes.contains(_reportedCode)
      ? _reportedCode
      : 'request_failed';

  @override
  String toString() => 'BridgeProtocolError: $code';
}

class BridgeSemesterCapability {
  const BridgeSemesterCapability({
    required this.semesterId,
    required this.semesterKey,
    required this.displayName,
  });

  final int semesterId;
  final String semesterKey;
  final String displayName;

  Map<String, Object?> toJson() => {
    'semesterId': semesterId,
    'semesterKey': semesterKey,
    'displayName': displayName,
  };
}

class BridgeCapabilities {
  const BridgeCapabilities({required this.jwSemester});

  final BridgeSemesterCapability jwSemester;
}

class BridgeJob {
  const BridgeJob({required this.id, required this.phase});

  final String id;
  final String phase;
}

class BridgeJobPoll {
  const BridgeJobPoll({
    required this.events,
    required this.nextSequence,
    required this.terminal,
    this.result,
    this.errorCode,
  });

  final List<Map<String, dynamic>> events;
  final int nextSequence;
  final bool terminal;
  final Map<String, dynamic>? result;
  final String? errorCode;

  String? get lastPhase =>
      events.isEmpty ? null : events.last['phase'] as String?;
}

abstract interface class BridgeGateway {
  Future<BridgeCapabilities> capabilities();

  Future<BridgeJob> startCollection({
    required SyncSource source,
    required String accountId,
    required String expectedUsername,
    required BridgeSemesterCapability jwSemester,
  });

  Future<BridgeJobPoll> poll(String jobId, int after);

  Future<void> resumeLogin(String jobId, {String? password});

  Future<void> cancel(String jobId);

  Future<void> shutdown();
}

/// The query side of the Bridge, kept separate from [BridgeGateway] so the
/// collection methods stay stable. [BridgeClient] implements both interfaces
/// over the same process + HTTP transport.
abstract interface class BridgeQueryGateway {
  /// Performs an authenticated GET against the Bridge and returns the decoded
  /// JSON body.
  Future<Map<String, dynamic>> getQuery(String path);

  /// Performs an authenticated POST against the Bridge with [body] and returns
  /// the decoded JSON body.
  Future<Map<String, dynamic>> postQuery(
    String path,
    Map<String, Object?> body,
  );
}

abstract interface class BridgeChildProcess {
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  Future<int> get exitCode;
  bool kill();
}

class BridgeLaunchOptions {
  const BridgeLaunchOptions({this.workingDirectory, this.environment});

  final String? workingDirectory;
  final Map<String, String>? environment;
}

abstract interface class BridgeProcessLauncher {
  Future<BridgeChildProcess> start(
    String executable,
    List<String> arguments, {
    BridgeLaunchOptions options = const BridgeLaunchOptions(),
  });
}

class IoBridgeChildProcess implements BridgeChildProcess {
  IoBridgeChildProcess(this.process);

  final Process process;

  @override
  Future<int> get exitCode => process.exitCode;

  @override
  Stream<List<int>> get stderr => process.stderr;

  @override
  Stream<List<int>> get stdout => process.stdout;

  @override
  bool kill() => process.kill();
}

class IoBridgeProcessLauncher implements BridgeProcessLauncher {
  const IoBridgeProcessLauncher();

  @override
  Future<BridgeChildProcess> start(
    String executable,
    List<String> arguments, {
    BridgeLaunchOptions options = const BridgeLaunchOptions(),
  }) async => IoBridgeChildProcess(
    await Process.start(
      executable,
      arguments,
      runInShell: false,
      workingDirectory: options.workingDirectory,
      environment: options.environment,
    ),
  );
}

class BridgeClient implements BridgeGateway, BridgeQueryGateway {
  BridgeClient._({
    required this.process,
    required this.client,
    required this.baseUri,
    required this._token,
  });

  final BridgeChildProcess process;
  final http.Client client;
  final Uri baseUri;
  final String _token;
  bool _closed = false;

  static Future<BridgeClient> start({
    required String pythonExecutable,
    BridgeProcessLauncher launcher = const IoBridgeProcessLauncher(),
    http.Client? httpClient,
    int? parentPid,
    Duration handshakeTimeout = const Duration(seconds: 10),
    BridgeLaunchOptions launchOptions = const BridgeLaunchOptions(),
  }) async {
    final arguments = [
      '-m',
      'ustc_assistant.bridge',
      '--parent-pid',
      '${parentPid ?? pid}',
    ];
    final process = await launcher.start(
      pythonExecutable,
      arguments,
      options: launchOptions,
    );
    try {
      final line = await utf8.decoder
          .bind(process.stdout)
          .transform(const LineSplitter())
          .first
          .timeout(handshakeTimeout);
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) {
        throw const BridgeProtocolError('invalid_handshake');
      }
      final protocol = decoded['protocolVersion'];
      final port = decoded['port'];
      final token = decoded['token'];
      if (protocol != bridgeProtocolVersion) {
        throw const BridgeProtocolError('unsupported_version');
      }
      if (port is! int || port < 1 || port > 65535) {
        throw const BridgeProtocolError('invalid_handshake');
      }
      if (token is! String || token.length < 20) {
        throw const BridgeProtocolError('invalid_handshake');
      }
      return BridgeClient._(
        process: process,
        client: httpClient ?? http.Client(),
        baseUri: Uri.parse('http://127.0.0.1:$port'),
        token: token,
      );
    } on Object {
      process.kill();
      rethrow;
    }
  }

  @override
  Future<BridgeCapabilities> capabilities() async {
    final value = await _get('/capabilities');
    if (value['protocolVersion'] != bridgeProtocolVersion ||
        value['jwSemester'] is! Map<String, dynamic>) {
      throw const BridgeProtocolError('invalid_capabilities');
    }
    final semester = value['jwSemester'] as Map<String, dynamic>;
    return BridgeCapabilities(
      jwSemester: BridgeSemesterCapability(
        semesterId: semester['semesterId'] as int,
        semesterKey: semester['semesterKey'] as String,
        displayName: semester['displayName'] as String,
      ),
    );
  }

  @override
  Future<BridgeJob> startCollection({
    required SyncSource source,
    required String accountId,
    required String expectedUsername,
    required BridgeSemesterCapability jwSemester,
  }) async {
    final path = source == SyncSource.jw
        ? '/collect/jw'
        : '/collect/young-schedule';
    final body = <String, Object?>{
      'protocolVersion': bridgeProtocolVersion,
      'accountId': accountId,
      'expectedUsername': expectedUsername,
      if (source == SyncSource.jw) 'semester': jwSemester.toJson(),
    };
    final value = await _post(path, body);
    return BridgeJob(
      id: value['jobId'] as String,
      phase: value['phase'] as String,
    );
  }

  @override
  Future<BridgeJobPoll> poll(String jobId, int after) async {
    final value = await _get('/jobs/$jobId/events?after=$after&waitMs=15000');
    final error = value['error'];
    return BridgeJobPoll(
      events: (value['events'] as List<dynamic>).cast<Map<String, dynamic>>(),
      nextSequence: value['nextSequence'] as int,
      terminal: value['terminal'] as bool,
      result: value['result'] as Map<String, dynamic>?,
      errorCode: error is Map<String, dynamic>
          ? error['code'] as String?
          : null,
    );
  }

  @override
  Future<void> resumeLogin(String jobId, {String? password}) async {
    await _post('/login/resume', {
      'protocolVersion': bridgeProtocolVersion,
      'jobId': jobId,
      'password': ?password,
    });
  }

  @override
  Future<void> cancel(String jobId) async {
    await _post('/jobs/$jobId/cancel', {
      'protocolVersion': bridgeProtocolVersion,
    });
  }

  @override
  Future<void> shutdown() async {
    if (_closed) return;
    _closed = true;
    try {
      await _post('/shutdown', {'protocolVersion': bridgeProtocolVersion});
    } finally {
      client.close();
      process.kill();
    }
  }

  // --- BridgeQueryGateway ------------------------------------------------

  @override
  Future<Map<String, dynamic>> getQuery(String path) => _get(path);

  @override
  Future<Map<String, dynamic>> postQuery(
    String path,
    Map<String, Object?> body,
  ) =>
      _post(path, body);

  Future<Map<String, dynamic>> _get(String path) async {
    final response = await client.get(baseUri.resolve(path), headers: _headers);
    return _decode(response);
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, Object?> body,
  ) async {
    final response = await client.post(
      baseUri.resolve(path),
      headers: {..._headers, 'content-type': 'application/json'},
      body: jsonEncode(body),
    );
    return _decode(response);
  }

  Map<String, String> get _headers => {'authorization': 'Bearer $_token'};

  Map<String, dynamic> _decode(http.Response response) {
    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const BridgeProtocolError('invalid_response');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final reported = decoded is Map<String, dynamic>
          ? decoded['error']
          : null;
      final code = reported is String ? reported : null;
      throw BridgeProtocolError(code ?? 'request_failed');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const BridgeProtocolError('invalid_response');
    }
    return decoded;
  }
}
