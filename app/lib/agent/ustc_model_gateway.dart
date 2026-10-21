import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/agent_contract.dart';
import 'model_gateway_contract.dart';
import 'model_reasoning_policy.dart';

/// Fixed USTC model gateway. The only non-production destination is the
/// explicit 127.0.0.1 test constructor.
final class UstcModelGateway implements ModelGatewayPort {
  UstcModelGateway({
    Duration connectTimeout = const Duration(seconds: 15),
    Duration requestTimeout = const Duration(seconds: 180),
    Duration idleTimeout = const Duration(seconds: 20),
  }) : _baseUri = Uri.https(_productionHost, '/'),
       _loopback = false,
       _connectTimeout = connectTimeout,
       _requestTimeout = requestTimeout,
       _idleTimeout = idleTimeout {
    _validateTimeouts(connectTimeout, requestTimeout, idleTimeout);
  }

  UstcModelGateway.loopbackForTesting(
    Uri baseUri, {
    Duration connectTimeout = const Duration(seconds: 15),
    Duration requestTimeout = const Duration(seconds: 180),
    Duration idleTimeout = const Duration(seconds: 20),
  }) : _baseUri = _validateLoopbackUri(baseUri),
       _loopback = true,
       _connectTimeout = connectTimeout,
       _requestTimeout = requestTimeout,
       _idleTimeout = idleTimeout {
    _validateTimeouts(connectTimeout, requestTimeout, idleTimeout);
  }

  static const String _productionHost = 'api.llm.ustc.edu.cn';
  static final RegExp _modelIdPattern = RegExp(r'^[A-Za-z0-9._:/-]{1,128}$');
  static final RegExp _toolNamePattern = RegExp(r'^[A-Za-z0-9_.-]{1,64}$');
  static const int _modelsBodyLimit = 1024 * 1024;
  static const int _streamBodyLimit = 2 * 1024 * 1024;
  static const int _sseLineLimit = 64 * 1024;
  static const int _sseEventLimit = 64 * 1024;
  static const int _textLimit = 24000;
  static const int _reasoningLimit = 128 * 1024;
  static const int _toolArgumentsLimit = 16 * 1024;

  final Uri _baseUri;
  final bool _loopback;
  final Duration _connectTimeout;
  final Duration _requestTimeout;
  final Duration _idleTimeout;
  final Set<_OwnedRequest> _owned = <_OwnedRequest>{};

  bool _closed = false;
  bool _draining = false;
  Future<void>? _drainFuture;

  @override
  Future<List<String>> listModels(ModelSecretLease secret) {
    final operation = _register();
    if (operation == null) {
      secret.revoke();
      return Future<List<String>>.error(_rejectedFailure());
    }
    return _withSecret(operation, secret, (key) async {
      final response = await _send(
        operation,
        method: 'GET',
        uri: _endpoint('models'),
        key: key,
      );
      _checkStatus(response.statusCode);
      final bytes = await _readLimited(response, _modelsBodyLimit, operation);
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      } on FormatException {
        throw const AgentFailure(AgentFailureCode.protocol);
      }
      if (decoded is! Map<String, dynamic> || decoded['data'] is! List) {
        throw const AgentFailure(AgentFailureCode.protocol);
      }
      final data = decoded['data'] as List;
      if (data.length > 256) {
        throw const AgentFailure(AgentFailureCode.resourceLimit);
      }
      final ids = <String>[];
      final seen = <String>{};
      for (final item in data) {
        if (item is! Map<String, dynamic> || item['id'] is! String) {
          throw const AgentFailure(AgentFailureCode.protocol);
        }
        final id = item['id'] as String;
        if (!_modelIdPattern.hasMatch(id)) {
          throw const AgentFailure(AgentFailureCode.protocol);
        }
        if (seen.add(id)) {
          ids.add(id);
        }
      }
      return List<String>.unmodifiable(ids);
    });
  }

  @override
  Stream<ModelEvent> generate(ModelRequest request, ModelSecretLease secret) {
    late final StreamController<ModelEvent> controller;
    _OwnedRequest? operation;
    controller = StreamController<ModelEvent>(
      onListen: () {
        operation = _register();
        if (operation == null) {
          secret.revoke();
          controller.addError(_rejectedFailure());
          unawaited(controller.close());
          return;
        }
        unawaited(
          _withSecret<void>(operation!, secret, (key) async {
            await _generate(operation!, request, key, controller);
          }).then<void>(
            (_) {
              if (!controller.isClosed) {
                unawaited(controller.close());
              }
            },
            onError: (Object error, StackTrace stack) {
              if (!controller.isClosed) {
                controller.addError(_safeFailure(error));
              }
              if (!controller.isClosed) {
                unawaited(controller.close());
              }
            },
          ),
        );
      },
      onCancel: () {
        final current = operation;
        if (current != null && !current.finished) {
          _abort(current, AgentFailureCode.cancelled);
        } else if (current == null) {
          secret.revoke();
        }
      },
    );
    return controller.stream;
  }

  @override
  Future<void> cancelAndDrain() {
    if (_closed) {
      return _drainFuture ?? Future<void>.value();
    }
    return _beginDrain();
  }

  @override
  Future<void> close() {
    _closed = true;
    return _beginDrain();
  }

  Future<void> _beginDrain() {
    final existing = _drainFuture;
    if (existing != null) {
      return existing;
    }
    _draining = true;
    final current = List<_OwnedRequest>.of(_owned);
    for (final operation in current) {
      _abort(operation, AgentFailureCode.cancelled);
    }
    final drain =
        Future.wait<void>(
          current.map((operation) => operation.done.future),
        ).then<void>((_) {
          _draining = false;
          _drainFuture = null;
        });
    _drainFuture = drain;
    return drain;
  }

  Future<T> _withSecret<T>(
    _OwnedRequest operation,
    ModelSecretLease secret,
    Future<T> Function(String key) action,
  ) async {
    Uint8List? bytes;
    try {
      bytes = secret.take();
      final key = _decodeKey(bytes);
      if (operation.failure != null) {
        throw operation.failure!;
      }
      return await action(key);
    } on AgentFailure {
      rethrow;
    } on Object catch (error) {
      throw _mapFailure(operation, error);
    } finally {
      if (bytes != null) {
        bytes.fillRange(0, bytes.length, 0);
      }
      secret.revoke();
      _finish(operation);
    }
  }

  String _decodeKey(Uint8List bytes) {
    if (bytes.isEmpty ||
        bytes.length > 4096 ||
        bytes.any((byte) => byte < 0x21 || byte > 0x7e)) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
  }

  Future<void> _generate(
    _OwnedRequest operation,
    ModelRequest modelRequest,
    String key,
    StreamController<ModelEvent> output,
  ) async {
    final body = _buildRequestBody(modelRequest);
    final response = await _send(
      operation,
      method: 'POST',
      uri: _endpoint('chat/completions'),
      key: key,
      body: body,
    );
    if (const {400, 413, 422}.contains(response.statusCode)) {
      // Only a closed provider code triggers one capacity retry. Message text
      // and echoed request content are never retained or put in diagnostics.
      final bytes = await _readLimited(response, 8192, operation);
      try {
        final error = jsonDecode(utf8.decode(bytes));
        if (_isContextLimit(error)) {
          throw const AgentFailure(AgentFailureCode.contextLimit);
        }
        if (modelReasoningEffort(modelRequest.modelId) != null &&
            _isReasoningRejection(error)) {
          throw const AgentFailure(AgentFailureCode.reasoningRejected);
        }
      } on FormatException {
        // An unknown error remains a normal image/protocol rejection below.
      } finally {
        bytes.fillRange(0, bytes.length, 0);
      }
    }
    if (modelRequest.messages.any((m) => m.images.isNotEmpty) &&
        const {400, 415, 422}.contains(response.statusCode)) {
      throw const AgentFailure(AgentFailureCode.imageRejected);
    }
    _checkStatus(response.statusCode);
    final mediaType = response.headers.contentType?.mimeType;
    if (mediaType != null && mediaType != 'text/event-stream') {
      throw const AgentFailure(AgentFailureCode.protocol);
    }
    await _readSse(operation, response, modelRequest.tools, output);
  }

  static bool _isContextLimit(Object? value) {
    if (value is! Map<String, dynamic>) return false;
    final error = value['error'];
    return error is Map<String, dynamic> &&
        const {
          'context_length_exceeded',
          'context_window_exceeded',
          'max_context_length_exceeded',
        }.contains(error['code']);
  }

  static bool _isReasoningRejection(Object? value) =>
      value is Map<String, dynamic> &&
      value['error'] is Map<String, dynamic> &&
      (value['error'] as Map<String, dynamic>)['param'] == 'reasoning_effort';

  Future<HttpClientResponse> _send(
    _OwnedRequest operation, {
    required String method,
    required Uri uri,
    required String key,
    List<int>? body,
  }) async {
    if (operation.failure != null) {
      throw operation.failure!;
    }
    operation.connectDeadline = Timer(
      _connectTimeout,
      () => _abort(operation, AgentFailureCode.timeout),
    );
    try {
      final request = await operation.client.openUrl(method, uri);
      operation.connectDeadline?.cancel();
      operation.request = request;
      if (operation.failure != null) {
        request.abort();
        throw operation.failure!;
      }
      request.followRedirects = false;
      request.maxRedirects = 0;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
      request.headers.set(
        HttpHeaders.acceptHeader,
        body == null ? 'application/json' : 'text/event-stream',
      );
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip');
      if (body != null) {
        request.headers.set(
          HttpHeaders.contentTypeHeader,
          'application/json; charset=utf-8',
        );
        request.add(body);
      }
      return await request.close();
    } on AgentFailure {
      rethrow;
    } on Object catch (error) {
      throw _mapFailure(operation, error);
    } finally {
      operation.connectDeadline?.cancel();
    }
  }

  void _checkStatus(int status) {
    if (status == HttpStatus.unauthorized) {
      throw const AgentFailure(AgentFailureCode.unauthorized);
    }
    if (status == HttpStatus.forbidden) {
      throw const AgentFailure(AgentFailureCode.forbidden);
    }
    if (status == HttpStatus.tooManyRequests) {
      throw const AgentFailure(AgentFailureCode.rateLimited);
    }
    if (status >= 300 && status < 400) {
      throw const AgentFailure(AgentFailureCode.redirectRejected);
    }
    if (status != HttpStatus.ok) {
      throw AgentFailure(
        status >= 500
            ? AgentFailureCode.networkFailed
            : AgentFailureCode.protocol,
      );
    }
  }

  Future<Uint8List> _readLimited(
    HttpClientResponse response,
    int maximum,
    _OwnedRequest operation,
  ) async {
    final builder = BytesBuilder(copy: false);
    var length = 0;
    try {
      await for (final chunk in response.timeout(_idleTimeout)) {
        if (operation.failure != null) {
          throw operation.failure!;
        }
        length += chunk.length;
        if (length > maximum) {
          throw const AgentFailure(AgentFailureCode.resourceLimit);
        }
        builder.add(chunk);
      }
    } on AgentFailure {
      rethrow;
    } on Object catch (error) {
      throw _mapFailure(operation, error);
    }
    return builder.takeBytes();
  }

  List<int> _buildRequestBody(ModelRequest request) {
    if (!_modelIdPattern.hasMatch(request.modelId) ||
        request.maxTokens < 1 ||
        request.maxTokens > 32768 ||
        request.messages.isEmpty ||
        request.messages.length > 512 ||
        request.tools.length > 32) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }

    final definitions = <String, ModelToolDefinition>{};
    for (final tool in request.tools) {
      if (!_toolNamePattern.hasMatch(tool.name) ||
          definitions.containsKey(tool.name) ||
          tool.description.runes.length > 4096 ||
          !_isJsonValue(tool.parameters, 0, <Object>{})) {
        throw const AgentFailure(AgentFailureCode.invalidInput);
      }
      final schemaSize = utf8.encode(jsonEncode(tool.parameters)).length;
      if (schemaSize > _sseLineLimit) {
        throw const AgentFailure(AgentFailureCode.resourceLimit);
      }
      definitions[tool.name] = tool;
    }
    if (request.toolChoice != null && request.tools.isEmpty) {
      if (request.toolChoice != 'none' && request.toolChoice != 'auto') {
        throw const AgentFailure(AgentFailureCode.invalidInput);
      }
    } else if (request.toolChoice != null &&
        request.toolChoice != 'none' &&
        request.toolChoice != 'auto' &&
        !definitions.containsKey(request.toolChoice)) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }

    final messages = <Map<String, Object?>>[];
    final pending = <String, String>{};
    final seenCallIds = <String>{};
    var promptChars = 0;
    var imageCount = 0, imageBytes = 0;
    for (final message in request.messages) {
      if (message.images.isNotEmpty) {
        if (message.role != 'user') {
          throw const AgentFailure(AgentFailureCode.invalidInput);
        }
        for (final image in message.images) {
          image.validate();
          imageCount++;
          imageBytes += image.bytes.length;
        }
        if (imageCount > AgentImage.maximumCount ||
            imageBytes > AgentImage.maximumTotalBytes) {
          throw const AgentFailure(AgentFailureCode.resourceLimit);
        }
      }
      if (!const {
        'system',
        'user',
        'assistant',
        'tool',
      }.contains(message.role)) {
        throw const AgentFailure(AgentFailureCode.invalidInput);
      }
      final content = message.content;
      if (content != null) {
        promptChars += content.runes.length;
        if (content.runes.length > 192 * 1024 || promptChars > 256 * 1024) {
          throw const AgentFailure(AgentFailureCode.resourceLimit);
        }
      }
      if (message.role == 'tool') {
        final id = message.toolCallId;
        if (id == null ||
            !modelToolCallIdPattern.hasMatch(id) ||
            content == null ||
            message.toolCalls.isNotEmpty ||
            !pending.containsKey(id)) {
          throw const AgentFailure(AgentFailureCode.invalidInput);
        }
        pending.remove(id);
        messages.add(<String, Object?>{
          'role': 'tool',
          'tool_call_id': id,
          'content': content,
        });
        continue;
      }
      if (message.toolCallId != null ||
          (message.role != 'assistant' && message.toolCalls.isNotEmpty) ||
          (message.role == 'user' && content == null) ||
          (message.role == 'system' &&
              (content == null || message.toolCalls.isNotEmpty)) ||
          (message.role == 'assistant' &&
              content == null &&
              message.toolCalls.isEmpty) ||
          (pending.isNotEmpty && message.role != 'tool')) {
        throw const AgentFailure(AgentFailureCode.invalidInput);
      }
      final encoded = <String, Object?>{'role': message.role};
      if (content != null) {
        encoded['content'] = content;
      }
      if (message.images.isNotEmpty) {
        encoded['content'] = [
          if (content != null) {'type': 'text', 'text': content},
          for (final image in message.images)
            {
              'type': 'image_url',
              'image_url': {
                'url': 'data:image/png;base64,${base64Encode(image.bytes)}',
                'detail': 'auto',
              },
            },
        ];
      }
      if (message.toolCalls.isNotEmpty) {
        final calls = <Map<String, Object?>>[];
        for (final call in message.toolCalls) {
          if (!modelToolCallIdPattern.hasMatch(call.id) ||
              !seenCallIds.add(call.id) ||
              !definitions.containsKey(call.name) ||
              call.argumentsJson.length > _toolArgumentsLimit) {
            throw const AgentFailure(AgentFailureCode.invalidInput);
          }
          _decodeArgumentObject(
            call.argumentsJson,
            AgentFailureCode.invalidInput,
          );
          pending[call.id] = call.name;
          calls.add(<String, Object?>{
            'id': call.id,
            'type': 'function',
            'function': <String, Object?>{
              'name': call.name,
              'arguments': call.argumentsJson,
            },
          });
        }
        encoded['tool_calls'] = calls;
      }
      messages.add(encoded);
    }
    if (pending.isNotEmpty) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }

    final body = <String, Object?>{
      'model': request.modelId,
      'messages': messages,
      'stream': true,
      'max_tokens': request.maxTokens,
      'reasoning_effort': ?modelReasoningEffort(request.modelId),
    };
    if (request.tools.isNotEmpty) {
      body['tools'] = request.tools
          .map(
            (tool) => <String, Object?>{
              'type': 'function',
              'function': <String, Object?>{
                'name': tool.name,
                'description': tool.description,
                'parameters': tool.parameters,
              },
            },
          )
          .toList(growable: false);
      if (request.toolChoice == 'none' || request.toolChoice == 'auto') {
        body['tool_choice'] = request.toolChoice;
      } else if (request.toolChoice != null) {
        body['tool_choice'] = <String, Object?>{
          'type': 'function',
          'function': <String, Object?>{'name': request.toolChoice},
        };
      }
    }
    try {
      final encoded = utf8.encode(jsonEncode(body));
      if (encoded.length >
          (imageCount > 0 ? 10 * 1024 * 1024 : _modelsBodyLimit)) {
        throw const AgentFailure(AgentFailureCode.resourceLimit);
      }
      return encoded;
    } on AgentFailure {
      rethrow;
    } on Object {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
  }

  bool _isJsonValue(Object? value, int depth, Set<Object> seen) {
    if (depth > 32) {
      return false;
    }
    if (value == null || value is String || value is bool || value is int) {
      return true;
    }
    if (value is double) {
      return value.isFinite;
    }
    if (value is List) {
      if (!seen.add(value)) {
        return false;
      }
      final valid = value.every((item) => _isJsonValue(item, depth + 1, seen));
      seen.remove(value);
      return valid;
    }
    if (value is Map) {
      if (!seen.add(value)) {
        return false;
      }
      final valid = value.entries.every(
        (entry) =>
            entry.key is String && _isJsonValue(entry.value, depth + 1, seen),
      );
      seen.remove(value);
      return valid;
    }
    return false;
  }

  Map<String, dynamic> _decodeArgumentObject(
    String source,
    AgentFailureCode failure,
  ) {
    if (source.isEmpty || source.length > _toolArgumentsLimit) {
      throw AgentFailure(
        failure == AgentFailureCode.protocol
            ? AgentFailureCode.resourceLimit
            : failure,
      );
    }
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map<String, dynamic> ||
          !_isJsonValue(decoded, 0, <Object>{})) {
        throw AgentFailure(failure);
      }
      return decoded;
    } on AgentFailure {
      rethrow;
    } on FormatException {
      throw AgentFailure(failure);
    }
  }

  Future<void> _readSse(
    _OwnedRequest operation,
    HttpClientResponse response,
    List<ModelToolDefinition> allowedTools,
    StreamController<ModelEvent> output,
  ) async {
    var totalBytes = 0;
    var eventBytes = 0;
    var textCharacters = 0;
    var reasoningCharacters = 0;
    var finishReason = <String>{};
    var sawDone = false;
    int? inputTokens;
    int? outputTokens;
    ModelCompleted? pendingCompletion;
    var dataLines = <String>[];
    final lineBytes = <int>[];
    final calls = <int, _ToolCallAssembly>{};
    final allowedNames = allowedTools.map((tool) => tool.name).toSet();

    void dispatch() {
      if (dataLines.isEmpty) {
        eventBytes = 0;
        return;
      }
      final data = dataLines.join('\n');
      dataLines = <String>[];
      eventBytes = 0;
      if (sawDone) {
        throw const AgentFailure(AgentFailureCode.protocol);
      }
      if (data == '[DONE]') {
        if (finishReason.isEmpty) {
          throw const AgentFailure(AgentFailureCode.protocol);
        }
        final completedCalls = _completeCalls(
          calls,
          allowedNames,
          finishReason.single,
        );
        pendingCompletion = ModelCompleted(
          finishReason: finishReason.single,
          toolCalls: completedCalls,
          inputTokens: inputTokens,
          outputTokens: outputTokens,
        );
        sawDone = true;
        return;
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(data);
      } on FormatException {
        throw const AgentFailure(AgentFailureCode.protocol);
      }
      if (decoded is! Map<String, dynamic>) {
        throw const AgentFailure(AgentFailureCode.protocol);
      }
      if (_isContextLimit(decoded)) {
        throw const AgentFailure(AgentFailureCode.contextLimit);
      }
      if (decoded['usage'] != null) {
        final usage = decoded['usage'];
        if (usage is! Map<String, dynamic>) {
          throw const AgentFailure(AgentFailureCode.protocol);
        }
        inputTokens = _optionalUsage(usage, 'prompt_tokens');
        outputTokens = _optionalUsage(usage, 'completion_tokens');
      }
      final choicesValue = decoded['choices'];
      if (choicesValue is! List) {
        throw const AgentFailure(AgentFailureCode.protocol);
      }
      if (choicesValue.isEmpty) {
        if (!decoded.containsKey('usage')) {
          throw const AgentFailure(AgentFailureCode.protocol);
        }
        return;
      }
      if (choicesValue.length != 1 ||
          choicesValue.single is! Map<String, dynamic>) {
        throw const AgentFailure(AgentFailureCode.protocol);
      }
      if (finishReason.isNotEmpty) {
        throw const AgentFailure(AgentFailureCode.protocol);
      }
      final choice = choicesValue.single as Map<String, dynamic>;
      if (choice['index'] != 0) {
        throw const AgentFailure(AgentFailureCode.protocol);
      }
      final reasonValue = choice['finish_reason'];
      if (reasonValue != null) {
        if (reasonValue is! String || !_isFinishReason(reasonValue)) {
          throw const AgentFailure(AgentFailureCode.protocol);
        }
        if (finishReason.isNotEmpty && !finishReason.contains(reasonValue)) {
          throw const AgentFailure(AgentFailureCode.protocol);
        }
        finishReason.add(reasonValue);
      }
      final deltaValue = choice['delta'];
      if (deltaValue == null && reasonValue == null) {
        throw const AgentFailure(AgentFailureCode.protocol);
      }
      if (deltaValue != null && deltaValue is! Map<String, dynamic>) {
        throw const AgentFailure(AgentFailureCode.protocol);
      }
      if (deltaValue is Map<String, dynamic>) {
        // Older vLLM/DeepSeek deployments use reasoning_content; newer vLLM
        // uses reasoning. Accept either string, without double-emitting aliases
        // and without inferring thinking from ordinary answer text.
        final reasoning = deltaValue['reasoning'];
        final legacyReasoning = deltaValue['reasoning_content'];
        if ((reasoning != null && reasoning is! String) ||
            (legacyReasoning != null && legacyReasoning is! String)) {
          throw const AgentFailure(AgentFailureCode.protocol);
        }
        final reasoningText = reasoning is String && reasoning.isNotEmpty
            ? reasoning
            : legacyReasoning as String?;
        if (reasoningText != null && reasoningText.isNotEmpty) {
          reasoningCharacters += reasoningText.runes.length;
          if (reasoningCharacters > _reasoningLimit) {
            throw const AgentFailure(AgentFailureCode.resourceLimit);
          }
          output.add(ModelReasoningDelta(reasoningText));
        }
        final contentValue = deltaValue['content'];
        if (contentValue != null) {
          if (contentValue is! String) {
            throw const AgentFailure(AgentFailureCode.protocol);
          }
          textCharacters += contentValue.runes.length;
          if (textCharacters > _textLimit) {
            throw const AgentFailure(AgentFailureCode.resourceLimit);
          }
          if (contentValue.isNotEmpty) {
            output.add(ModelTextDelta(contentValue));
          }
        }
        final refusalValue = deltaValue['refusal'];
        if (refusalValue != null) {
          if (refusalValue is! String) {
            throw const AgentFailure(AgentFailureCode.protocol);
          }
          textCharacters += refusalValue.runes.length;
          if (textCharacters > _textLimit) {
            throw const AgentFailure(AgentFailureCode.resourceLimit);
          }
          if (refusalValue.isNotEmpty) {
            output.add(ModelTextDelta(refusalValue));
          }
        }
        final callsValue = deltaValue['tool_calls'];
        if (callsValue != null) {
          if (callsValue is! List) {
            throw const AgentFailure(AgentFailureCode.protocol);
          }
          for (final value in callsValue) {
            _appendToolCall(calls, value);
          }
        }
      }
    }

    void processLine(List<int> bytes) {
      final line = List<int>.of(bytes);
      if (line.isNotEmpty && line.last == 0x0d) {
        line.removeLast();
      }
      final String value;
      try {
        value = utf8.decode(line, allowMalformed: false);
      } on FormatException {
        throw const AgentFailure(AgentFailureCode.protocol);
      }
      if (value.isEmpty) {
        dispatch();
        return;
      }
      eventBytes += bytes.length + 1;
      if (eventBytes > _sseEventLimit) {
        throw const AgentFailure(AgentFailureCode.resourceLimit);
      }
      if (value.startsWith(':')) {
        return;
      }
      final separator = value.indexOf(':');
      final field = separator < 0 ? value : value.substring(0, separator);
      var fieldValue = separator < 0 ? '' : value.substring(separator + 1);
      if (fieldValue.startsWith(' ')) {
        fieldValue = fieldValue.substring(1);
      }
      if (field == 'data') {
        dataLines.add(fieldValue);
      }
      // SSE event, id, retry, and extension fields have no protocol meaning here.
    }

    try {
      await for (final chunk in response.timeout(_idleTimeout)) {
        if (operation.failure != null) {
          throw operation.failure!;
        }
        totalBytes += chunk.length;
        if (totalBytes > _streamBodyLimit) {
          throw const AgentFailure(AgentFailureCode.resourceLimit);
        }
        for (final byte in chunk) {
          if (byte == 0x0a) {
            processLine(lineBytes);
            lineBytes.clear();
          } else {
            if (lineBytes.length >= _sseLineLimit) {
              throw const AgentFailure(AgentFailureCode.resourceLimit);
            }
            lineBytes.add(byte);
          }
        }
      }
    } on AgentFailure {
      rethrow;
    } on Object catch (error) {
      throw _mapFailure(operation, error);
    }
    if (lineBytes.isNotEmpty ||
        eventBytes != 0 ||
        dataLines.isNotEmpty ||
        !sawDone ||
        pendingCompletion == null) {
      throw const AgentFailure(AgentFailureCode.protocol);
    }
    output.add(pendingCompletion!);
  }

  int? _optionalUsage(Map<String, dynamic> usage, String key) {
    if (!usage.containsKey(key)) {
      return null;
    }
    final value = usage[key];
    if (value is! int || value < 0) {
      throw const AgentFailure(AgentFailureCode.protocol);
    }
    return value;
  }

  bool _isFinishReason(String value) => const {
    'stop',
    'length',
    'tool_calls',
    'function_call',
    'content_filter',
    'refusal',
  }.contains(value);

  void _appendToolCall(Map<int, _ToolCallAssembly> calls, Object? value) {
    if (value is! Map<String, dynamic> || value['index'] is! int) {
      throw const AgentFailure(AgentFailureCode.protocol);
    }
    final index = value['index'] as int;
    if (index < 0 || index >= 8) {
      throw const AgentFailure(AgentFailureCode.resourceLimit);
    }
    final call = calls.putIfAbsent(index, _ToolCallAssembly.new);
    if (calls.length > 8) {
      throw const AgentFailure(AgentFailureCode.resourceLimit);
    }
    final id = value['id'];
    if (id != null) {
      if (id is! String || call.id.length + id.length > 128) {
        throw const AgentFailure(AgentFailureCode.protocol);
      }
      call.id.write(id);
    }
    final type = value['type'];
    if (type != null && type != 'function') {
      throw const AgentFailure(AgentFailureCode.protocol);
    }
    final function = value['function'];
    if (function != null) {
      if (function is! Map<String, dynamic>) {
        throw const AgentFailure(AgentFailureCode.protocol);
      }
      final name = function['name'];
      if (name != null) {
        if (name is! String || call.name.length + name.length > 64) {
          throw const AgentFailure(AgentFailureCode.protocol);
        }
        call.name.write(name);
      }
      final arguments = function['arguments'];
      if (arguments != null) {
        if (arguments is! String ||
            call.arguments.length + arguments.length > _toolArgumentsLimit) {
          throw const AgentFailure(AgentFailureCode.resourceLimit);
        }
        call.arguments.write(arguments);
      }
    }
  }

  List<ModelToolCall> _completeCalls(
    Map<int, _ToolCallAssembly> assemblies,
    Set<String> allowedNames,
    String finishReason,
  ) {
    if (assemblies.isEmpty) {
      if (finishReason == 'tool_calls' || finishReason == 'function_call') {
        throw const AgentFailure(AgentFailureCode.protocol);
      }
      return const <ModelToolCall>[];
    }
    if (finishReason != 'tool_calls' && finishReason != 'function_call') {
      throw const AgentFailure(AgentFailureCode.protocol);
    }
    final indexes = assemblies.keys.toList()..sort();
    if (indexes.length > 8) {
      throw const AgentFailure(AgentFailureCode.resourceLimit);
    }
    final ids = <String>{};
    final result = <ModelToolCall>[];
    for (var i = 0; i < indexes.length; i++) {
      if (indexes[i] != i) {
        throw const AgentFailure(AgentFailureCode.protocol);
      }
      final assembly = assemblies[indexes[i]]!;
      final id = assembly.id.toString();
      final name = assembly.name.toString();
      final arguments = assembly.arguments.toString();
      if (!modelToolCallIdPattern.hasMatch(id) ||
          !ids.add(id) ||
          !_toolNamePattern.hasMatch(name) ||
          !allowedNames.contains(name)) {
        throw const AgentFailure(AgentFailureCode.protocol);
      }
      _decodeArgumentObject(arguments, AgentFailureCode.protocol);
      result.add(ModelToolCall(id: id, name: name, argumentsJson: arguments));
    }
    return List<ModelToolCall>.unmodifiable(result);
  }

  _OwnedRequest? _register() {
    if (_closed || _draining) {
      return null;
    }
    final client = HttpClient()
      ..connectionTimeout = _connectTimeout
      ..idleTimeout = _idleTimeout;
    if (_loopback) {
      client.findProxy = (_) => 'DIRECT';
    } else {
      client.findProxy = HttpClient.findProxyFromEnvironment;
    }
    final operation = _OwnedRequest(client);
    _owned.add(operation);
    operation.deadline = Timer(
      _requestTimeout,
      () => _abort(operation, AgentFailureCode.timeout),
    );
    return operation;
  }

  AgentFailure _rejectedFailure() => AgentFailure(
    _closed ? AgentFailureCode.closed : AgentFailureCode.cancelled,
  );

  void _abort(_OwnedRequest operation, AgentFailureCode code) {
    if (operation.finished || operation.failure != null) {
      return;
    }
    operation.failure = AgentFailure(code);
    operation.deadline?.cancel();
    operation.connectDeadline?.cancel();
    try {
      operation.request?.abort(operation.failure);
    } on Object {
      // Abort errors contain implementation details and are intentionally hidden.
    }
    try {
      operation.client.close(force: true);
    } on Object {
      // Closing an already closed client is harmless.
    }
  }

  void _finish(_OwnedRequest operation) {
    if (operation.finished) {
      return;
    }
    operation.finished = true;
    operation.deadline?.cancel();
    operation.connectDeadline?.cancel();
    try {
      operation.client.close(force: true);
    } on Object {
      // Errors are represented by the request's stable failure code.
    }
    _owned.remove(operation);
    if (!operation.done.isCompleted) {
      operation.done.complete();
    }
  }

  AgentFailure _mapFailure(_OwnedRequest operation, Object error) {
    final forced = operation.failure;
    if (forced != null) {
      return forced;
    }
    return _safeFailure(error);
  }

  AgentFailure _safeFailure(Object error) {
    if (error is AgentFailure) {
      return error;
    }
    if (error is TimeoutException) {
      return const AgentFailure(AgentFailureCode.timeout);
    }
    if (error is FormatException) {
      return const AgentFailure(AgentFailureCode.protocol);
    }
    return const AgentFailure(AgentFailureCode.networkFailed);
  }

  Uri _endpoint(String path) =>
      _baseUri.replace(path: '/v1/$path', query: null, fragment: null);

  static Uri _validateLoopbackUri(Uri uri) {
    if (uri.scheme != 'http' ||
        uri.host != '127.0.0.1' ||
        uri.port == 0 ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw ArgumentError.value(
        uri,
        'baseUri',
        'Test URI must be a plain 127.0.0.1 origin.',
      );
    }
    return uri;
  }

  static void _validateTimeouts(
    Duration connect,
    Duration request,
    Duration idle,
  ) {
    if (connect <= Duration.zero ||
        request <= Duration.zero ||
        idle <= Duration.zero) {
      throw ArgumentError('Gateway timeouts must be positive.');
    }
  }
}

final class _OwnedRequest {
  _OwnedRequest(this.client);
  final HttpClient client;
  final Completer<void> done = Completer<void>();
  HttpClientRequest? request;
  Timer? deadline;
  Timer? connectDeadline;
  AgentFailure? failure;
  bool finished = false;
}

final class _ToolCallAssembly {
  final StringBuffer id = StringBuffer();
  final StringBuffer name = StringBuffer();
  final StringBuffer arguments = StringBuffer();
}
