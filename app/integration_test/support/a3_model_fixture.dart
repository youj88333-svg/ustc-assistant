import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Synthetic loopback OpenAI-compatible endpoint for A3 Agent integration
/// tests. It never forwards requests to an external service.
final class A3ModelFixture {
  A3ModelFixture._(this._server)
    : baseUri = Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: _server.port,
      );

  static const String syntheticKey = 'a3-synthetic-only-key';
  static const String _modelId = 'a3-synthetic-model';
  static const int _requestBodyLimit = 1024 * 1024;
  static const Duration _bodyIdleTimeout = Duration(seconds: 5);
  static const Duration _bodyTotalTimeout = Duration(seconds: 20);

  final HttpServer _server;
  final Uri baseUri;
  final List<Map<String, dynamic>> chatRequests = <Map<String, dynamic>>[];
  final List<Future<void> Function(HttpRequest, Map<String, dynamic>)> replies =
      <Future<void> Function(HttpRequest, Map<String, dynamic>)>[];

  late final StreamSubscription<HttpRequest> _subscription;
  final Set<HttpResponse> _openResponses = <HttpResponse>{};
  final Set<Future<void>> _handlers = <Future<void>>{};
  final Set<void Function()> _bodyReadAborters = <void Function()>{};
  Future<void>? _closeFuture;
  int _listRequests = 0;
  int _summaryRequests = 0;
  bool _unexpectedRequest = false;
  bool _closed = false;

  int get listRequests => _listRequests;
  int get summaryRequests => _summaryRequests;

  bool get unexpectedRequest => _unexpectedRequest;

  static Future<A3ModelFixture> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = A3ModelFixture._(server);
    fixture._subscription = server.listen(
      fixture._accept,
      onError: (Object _, StackTrace _) {
        if (!fixture._closed) fixture._unexpectedRequest = true;
      },
    );
    return fixture;
  }

  void _accept(HttpRequest request) {
    final response = request.response;
    _openResponses.add(response);
    unawaited(
      response.done.then<void>(
        (_) {
          _openResponses.remove(response);
        },
        onError: (Object _, StackTrace _) {
          _openResponses.remove(response);
        },
      ),
    );

    late final Future<void> handler;
    handler = _serve(request)
        .then<void>(
          (_) {},
          onError: (Object _, StackTrace _) async {
            if (!_closed) _unexpectedRequest = true;
            await _respondError(response, HttpStatus.internalServerError);
          },
        )
        .whenComplete(() {
          _handlers.remove(handler);
        });
    _handlers.add(handler);
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    try {
      if (_closed) {
        await _respondError(response, HttpStatus.serviceUnavailable);
        return;
      }
      if (request.headers.value(HttpHeaders.authorizationHeader) !=
          'Bearer $syntheticKey') {
        _unexpectedRequest = true;
        await _respondError(response, HttpStatus.unauthorized);
        return;
      }

      if (request.method == 'GET' && request.uri.path == '/v1/models') {
        _listRequests++;
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode({
            'data': [
              {'id': _modelId},
            ],
          }),
        );
        await response.close();
        return;
      }

      if (request.method != 'POST' ||
          request.uri.path != '/v1/chat/completions') {
        _unexpectedRequest = true;
        await _respondError(response, HttpStatus.notFound);
        return;
      }

      final body = await _readRequestMap(request);
      if (_isTextProbe(body)) {
        await text(request, 'USTC_TEXT_PROBE');
        return;
      }
      if (_isEchoToolProbe(body)) {
        await tool(request, 'echo_probe', const {'value': 'ustc_probe'});
        return;
      }
      final proof = _echoProof(body);
      if (proof != null) {
        await text(request, proof);
        return;
      }
      final messages = body['messages'];
      if (body['tools'] == null &&
          messages is List &&
          messages.isNotEmpty &&
          messages.first is Map &&
          (messages.first as Map)['role'] == 'system' &&
          ((messages.first as Map)['content'] as String? ?? '').startsWith(
            '把所提供的完整历史交互整理为简体中文会话摘要',
          )) {
        _summaryRequests++;
        await text(request, 'A3合成摘要：此前查询过日程，复习安排以真实提交回执为准。');
        return;
      }

      chatRequests.add(_copyJsonMap(body));
      if (replies.isEmpty) {
        _unexpectedRequest = true;
        await _respondError(response, HttpStatus.internalServerError);
        return;
      }
      final reply = replies.removeAt(0);
      await reply(request, body);
    } on _RequestBodyTooLarge {
      _unexpectedRequest = true;
      await _respondError(response, HttpStatus.requestEntityTooLarge);
    } on _RequestBodyTimeout {
      _unexpectedRequest = true;
      await _respondError(response, HttpStatus.requestTimeout);
    } on _InvalidRequestBody {
      _unexpectedRequest = true;
      await _respondError(response, HttpStatus.badRequest);
    } on _FixtureClosed {
      if (!_closed) {
        _unexpectedRequest = true;
        await _respondError(response, HttpStatus.badRequest);
      }
    } on HttpException {
      if (!_closed) {
        await _respondError(response, HttpStatus.internalServerError);
      }
    } on SocketException {
      if (!_closed) {
        await _respondError(response, HttpStatus.internalServerError);
      }
    } on Object {
      if (!_closed) _unexpectedRequest = true;
      await _respondError(response, HttpStatus.internalServerError);
    }
  }

  Future<Map<String, dynamic>> _readRequestMap(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    final complete = Completer<Uint8List>();
    StreamSubscription<List<int>>? subscription;
    Timer? idleTimer;
    Timer? totalTimer;
    Future<void>? cancelFuture;
    var length = 0;

    void cancelRead() {
      if (complete.isCompleted) return;
      idleTimer?.cancel();
      totalTimer?.cancel();
      final current = subscription;
      if (current != null) cancelFuture ??= current.cancel();
      complete.completeError(const _FixtureClosed());
    }

    void fail(Object error) {
      if (complete.isCompleted) return;
      idleTimer?.cancel();
      totalTimer?.cancel();
      final current = subscription;
      if (current != null) cancelFuture ??= current.cancel();
      complete.completeError(error, StackTrace.current);
    }

    void resetIdleTimer() {
      idleTimer?.cancel();
      idleTimer = Timer(
        _bodyIdleTimeout,
        () => fail(const _RequestBodyTimeout()),
      );
    }

    _bodyReadAborters.add(cancelRead);
    subscription = request.listen(
      (chunk) {
        if (complete.isCompleted) return;
        if (length + chunk.length > _requestBodyLimit) {
          fail(const _RequestBodyTooLarge());
          return;
        }
        length += chunk.length;
        builder.add(chunk);
        resetIdleTimer();
      },
      onError: (Object _, StackTrace _) {
        fail(_closed ? const _FixtureClosed() : const _InvalidRequestBody());
      },
      onDone: () {
        if (complete.isCompleted) return;
        idleTimer?.cancel();
        totalTimer?.cancel();
        complete.complete(builder.takeBytes());
      },
      cancelOnError: true,
    );
    resetIdleTimer();
    totalTimer = Timer(
      _bodyTotalTimeout,
      () => fail(const _RequestBodyTimeout()),
    );

    Uint8List bytes;
    try {
      bytes = await complete.future;
    } finally {
      idleTimer?.cancel();
      totalTimer.cancel();
      _bodyReadAborters.remove(cancelRead);
      try {
        await (cancelFuture ?? subscription.cancel());
      } on Object {
        // Request cancellation is expected when a fixture or client closes.
      }
    }

    try {
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      if (decoded is! Map<String, dynamic>) {
        throw const _InvalidRequestBody();
      }
      return decoded;
    } on FormatException {
      throw const _InvalidRequestBody();
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  bool _isTextProbe(Map<String, dynamic> body) {
    final tools = body['tools'];
    final noTools = tools == null || (tools is List && tools.isEmpty);
    if (!noTools) return false;
    final messages = body['messages'];
    if (messages is! List) return false;
    for (final value in messages) {
      if (value is! Map) continue;
      final content = value['content'];
      if (content is String && content.contains('USTC_TEXT_PROBE')) {
        return true;
      }
      if (content is List) {
        for (final part in content) {
          if (part is Map &&
              part['text'] is String &&
              (part['text'] as String).contains('USTC_TEXT_PROBE')) {
            return true;
          }
        }
      }
    }
    return false;
  }

  bool _isEchoToolProbe(Map<String, dynamic> body) {
    if (!_hasOnlyEchoProbeTool(body)) return false;
    final choice = body['tool_choice'];
    if (choice is! Map) return false;
    final function = choice['function'];
    return function is Map && function['name'] == 'echo_probe';
  }

  String? _echoProof(Map<String, dynamic> body) {
    if (body['tool_choice'] != 'none' || !_hasOnlyEchoProbeTool(body)) {
      return null;
    }
    final messages = body['messages'];
    if (messages is! List) return null;

    final callIds = <String>{};
    for (final value in messages) {
      if (value is! Map || value['role'] != 'assistant') continue;
      final calls = value['tool_calls'];
      if (calls is! List) continue;
      for (final call in calls) {
        if (call is! Map || call['id'] is! String) continue;
        final function = call['function'];
        if (function is! Map || function['name'] != 'echo_probe') continue;
        final arguments = function['arguments'];
        if (arguments is! String) continue;
        try {
          final decoded = jsonDecode(arguments);
          if (decoded is Map && decoded['value'] == 'ustc_probe') {
            callIds.add(call['id'] as String);
          }
        } on FormatException {
          // A malformed model tool call is not the fixed capability probe.
        }
      }
    }
    if (callIds.length != 1) return null;

    for (final value in messages) {
      if (value is! Map || value['role'] != 'tool') continue;
      if (value['tool_call_id'] != callIds.single ||
          value['content'] is! String) {
        continue;
      }
      try {
        final payload = jsonDecode(value['content'] as String);
        if (payload is Map &&
            payload['value'] == 'ustc_probe' &&
            payload['proof'] is String &&
            (payload['proof'] as String).isNotEmpty) {
          return payload['proof'] as String;
        }
      } on FormatException {
        // A malformed tool result is not the fixed capability probe.
      }
    }
    return null;
  }

  bool _hasOnlyEchoProbeTool(Map<String, dynamic> body) {
    final tools = body['tools'];
    if (tools is! List || tools.length != 1) return false;
    final tool = tools.single;
    if (tool is! Map) return false;
    final function = tool['function'];
    return function is Map && function['name'] == 'echo_probe';
  }

  static Map<String, dynamic> _copyJsonMap(Map<String, dynamic> source) =>
      jsonDecode(jsonEncode(source)) as Map<String, dynamic>;

  static Future<void> text(
    HttpRequest request,
    String text, {
    String? reasoning,
  }) async {
    final response = request.response;
    response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    if (reasoning != null) {
      await _writeEvent(response, {
        'choices': [
          {
            'index': 0,
            'delta': {'reasoning_content': reasoning},
            'finish_reason': null,
          },
        ],
      });
    }
    final runes = text.runes.toList(growable: false);
    final splitAt = (runes.length + 1) ~/ 2;
    final first = String.fromCharCodes(runes.take(splitAt));
    final second = String.fromCharCodes(runes.skip(splitAt));
    await _writeEvent(response, {
      'choices': [
        {
          'index': 0,
          'delta': {'content': first},
          'finish_reason': null,
        },
      ],
    });
    await _writeEvent(response, {
      'choices': [
        {
          'index': 0,
          'delta': {'content': second},
          'finish_reason': null,
        },
      ],
    });
    await _writeEvent(response, {
      'choices': [
        {'index': 0, 'delta': <String, Object?>{}, 'finish_reason': 'stop'},
      ],
    });
    await _writeDone(response);
  }

  static Future<void> tool(
    HttpRequest request,
    String name,
    Map<String, Object?> args, {
    String id = 'a3-call',
  }) async {
    final response = request.response;
    response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    await _writeEvent(response, {
      'choices': [
        {
          'index': 0,
          'delta': {
            'tool_calls': [
              {
                'index': 0,
                'id': id,
                'type': 'function',
                'function': {'name': name, 'arguments': jsonEncode(args)},
              },
            ],
          },
          'finish_reason': null,
        },
      ],
    });
    await _writeEvent(response, {
      'choices': [
        {
          'index': 0,
          'delta': <String, Object?>{},
          'finish_reason': 'tool_calls',
        },
      ],
    });
    await _writeDone(response);
  }

  static Future<void> _writeEvent(
    HttpResponse response,
    Map<String, Object?> event,
  ) async {
    response.write('data: ${jsonEncode(event)}\n\n');
    await response.flush();
  }

  static Future<void> _writeDone(HttpResponse response) async {
    response.write('data: [DONE]\n\n');
    await response.close();
  }

  Future<void> _respondError(HttpResponse response, int status) async {
    try {
      response.statusCode = status;
      response.headers.contentType = ContentType.json;
      response.write(
        jsonEncode({'error': 'synthetic fixture request rejected'}),
      );
      await response.close();
    } on Object {
      // A peer may already have closed the connection.
    }
  }

  Future<void> close() {
    return _closeFuture ??= _close();
  }

  Future<void> _close() async {
    _closed = true;
    for (final abort in List<void Function()>.of(_bodyReadAborters)) {
      abort();
    }
    await _subscription.cancel();

    final responses = List<HttpResponse>.of(_openResponses);
    await Future.wait<void>(responses.map(_closeResponse));
    await _server.close(force: true);

    chatRequests.clear();
    replies.clear();
    _listRequests = 0;
    _openResponses.clear();
    _handlers.clear();
    _bodyReadAborters.clear();
  }

  Future<void> _closeResponse(HttpResponse response) async {
    try {
      await response.close();
    } on Object {
      // It may have completed or been aborted at the same time as close().
    }
  }
}

final class _RequestBodyTooLarge implements Exception {
  const _RequestBodyTooLarge();
}

final class _RequestBodyTimeout implements Exception {
  const _RequestBodyTimeout();
}

final class _InvalidRequestBody implements Exception {
  const _InvalidRequestBody();
}

final class _FixtureClosed implements Exception {
  const _FixtureClosed();
}
