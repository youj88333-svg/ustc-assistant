// Constructor parameters intentionally retain descriptive public names while
// this helper keeps its backing fields private.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ustc_assistant_app/features/sync/native/jw_web_session.dart';

/// A credential-free JW/CAS-shaped server for the real Windows WebView2 gate.
///
/// The native plugin's Debug-only loopback policy intentionally admits the
/// route families `/portal`, `/passport`, `/course`, and `/exam`.  Keeping the
/// fixture inside those families lets this test exercise the same native
/// allowlist that product code uses, while all response data remains local and
/// synthetic.
final class MinimalJwWebViewFixtureServer {
  MinimalJwWebViewFixtureServer._({
    required HttpServer server,
    required String courseDatum,
    required String examHtml,
  }) : _server = server,
       _courseDatum = courseDatum,
       _examHtml = examHtml,
       policy = JwWebRuntimePolicy.loopback(server.port);

  final HttpServer _server;
  final String _courseDatum;
  final String _examHtml;

  late final JwWebRuntimePolicy policy;

  final List<_RequestShape> _requests = <_RequestShape>[];

  int get port => _server.port;

  /// Safe request summaries used by the integration assertion.  Query
  /// strings, request bodies, and credential values are deliberately omitted.
  List<String> get requestShapes =>
      List<String>.unmodifiable(_requests.map((request) => request.summary));

  List<String> get requestDetails =>
      List<String>.unmodifiable(_requests.map((request) => request.detail));

  static Future<MinimalJwWebViewFixtureServer> start({
    required String courseDatum,
    required String examHtml,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = MinimalJwWebViewFixtureServer._(
      server: server,
      courseDatum: courseDatum,
      examHtml: examHtml,
    );
    server.listen(fixture._handleRequest);
    return fixture;
  }

  Future<void> close() async {
    await _server.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final contentType = request.headers.contentType?.mimeType;
    final requestedWith = request.headers.value('x-requested-with');
    String? bodyShape;
    if (request.method == 'POST') {
      bodyShape = await _readBodyShape(request);
    }
    _requests.add(
      _RequestShape(
        method: request.method,
        path: request.uri.path,
        contentType: contentType,
        requestedWith: requestedWith,
        bodyShape: bodyShape,
      ),
    );

    final path = request.uri.path;
    if (request.method == 'GET' &&
        (path == '/portal/root' || path == '/portal/login')) {
      return _writeHtml(request, _portalHtml());
    }
    if (request.method == 'GET' && path == '/passport/cas/login') {
      return _writeHtml(request, _casHtml());
    }
    if ((request.method == 'GET' || request.method == 'POST') &&
        path == '/portal/home') {
      if (request.method == 'GET' || request.method == 'POST') {
        return _writeHtml(request, _homeHtml());
      }
    }
    if (request.method == 'GET' && path == '/portal/identity') {
      return _writeText(
        request,
        'window.__minimalJwFixtureIdentityLoaded = true;',
        contentType: ContentType('application', 'javascript', charset: 'utf-8'),
      );
    }
    if (request.method == 'GET' && path == '/course/table') {
      return _writeHtml(request, _courseHtml());
    }
    if (request.method == 'GET' && path == '/course/get-data') {
      return _writeText(
        request,
        '{"lessonIds":[101,102]}',
        contentType: ContentType.json,
      );
    }
    if (request.method == 'POST' && path == '/course/datum') {
      return _writeText(request, _courseDatum, contentType: ContentType.json);
    }
    if (request.method == 'GET' && path == '/exam/arrange') {
      return _writeHtml(request, _examHtml);
    }
    request.response
      ..statusCode = HttpStatus.notFound
      ..headers.contentType = ContentType.text
      ..write('not found');
    await request.response.close();
  }

  Future<String> _readBodyShape(HttpRequest request) async {
    final chunks = <int>[];
    await for (final chunk in request) {
      chunks.addAll(chunk);
    }
    if (chunks.isEmpty) return 'empty';
    try {
      final decoded = jsonDecode(utf8.decode(chunks));
      if (decoded is Map) {
        final keys = decoded.keys.whereType<String>().toList()..sort();
        return 'object:${keys.join(',')}';
      }
      if (decoded is List) return 'array';
    } on Object {
      return 'non_json';
    }
    return 'json_scalar';
  }

  Future<void> _writeHtml(HttpRequest request, String html) async {
    await _writeText(request, html, contentType: ContentType.html);
  }

  Future<void> _writeText(
    HttpRequest request,
    String body, {
    required ContentType contentType,
  }) async {
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = contentType
      ..headers.set('Cache-Control', 'no-store')
      ..write(body);
    await request.response.close();
  }

  String _portalHtml() => '''<!doctype html>
<html><head><meta charset="utf-8"><title>JW fixture portal</title></head>
<body>
  <main style="padding:24px">
    <h1>JW fixture portal</h1>
    <a id="login-unified-wrapper" href="/passport/cas/login"
       style="display:block;width:240px;height:48px;line-height:48px;text-align:center">
      统一身份认证
    </a>
  </main>
</body></html>''';

  String _casHtml() => '''<!doctype html>
<html><head><meta charset="utf-8"><title>CAS fixture</title></head>
<body>
  <main style="padding:24px">
    <form method="post" action="/portal/home">
      <label>Username <input id="username" name="username" type="text"></label>
      <label>Password <input name="password" type="password"></label>
      <button id="submitBtn" class="login-button" type="submit">登录</button>
    </form>
  </main>
</body></html>''';

  String _homeHtml() => '''<!doctype html>
<html><head><meta charset="utf-8"><title>JW fixture home</title>
<script src="/portal/identity?fine_username=PB00000000"></script>
</head>
<body data-jw-ready="authenticated" data-ustc-account="PB00000000">
  <main><h1>JW fixture home</h1><p>authenticated fixture session</p></main>
</body></html>''';

  String _courseHtml() => '''<!doctype html>
<html><head><meta charset="utf-8"><title>JW fixture course table</title></head>
<body>
  <select id="allSemesters"><option value="461">2026 秋季学期</option></select>
  <img hidden src="/course/get-data?bizTypeId=2&semesterId=461&dataId=loopback-data">
  <script>
    fetch('/course/get-data?bizTypeId=2&semesterId=461&dataId=loopback-data', {
      credentials: 'same-origin',
      headers: {'X-Requested-With': 'XMLHttpRequest'}
    });
  </script>
</body></html>''';
}

final class _RequestShape {
  const _RequestShape({
    required this.method,
    required this.path,
    required this.contentType,
    required this.requestedWith,
    required this.bodyShape,
  });

  final String method;
  final String path;
  final String? contentType;
  final String? requestedWith;
  final String? bodyShape;

  String get summary {
    final parts = <String>[method, path];
    if (contentType != null) parts.add(contentType!);
    if (requestedWith != null) parts.add(requestedWith!);
    return parts.join(' ');
  }

  String get detail {
    final shape = summary;
    return bodyShape == null ? shape : '$shape body:$bodyShape';
  }
}
