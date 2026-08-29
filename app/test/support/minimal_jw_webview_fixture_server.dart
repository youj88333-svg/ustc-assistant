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
    required String expectedDataId,
  }) : _server = server,
       _courseDatum = courseDatum,
       _examHtml = examHtml,
       _expectedDataId = expectedDataId,
       policy = JwWebRuntimePolicy.loopback(server.port);

  final HttpServer _server;
  final String _courseDatum;
  final String _examHtml;
  final String _expectedDataId;

  late final JwWebRuntimePolicy policy;

  final List<_RequestShape> _requests = <_RequestShape>[];
  var _validCourseGetDataXhrRequests = 0;
  var _bootstrapCourseGetDataRequests = 0;
  var _invalidCourseGetDataRequests = 0;
  var _validHomeSubmitRequests = 0;
  var _invalidHomeSubmitRequests = 0;
  var _validCourseDatumRequests = 0;
  var _invalidCourseDatumRequests = 0;
  var _courseGetDataCarriedCredentials = false;
  var _courseDatumCarriedCredentials = false;

  int get port => _server.port;

  /// Safe request summaries used by the integration assertion.  Query
  /// strings, request bodies, and credential values are deliberately omitted.
  List<String> get requestShapes =>
      List<String>.unmodifiable(_requests.map((request) => request.summary));

  List<String> get requestDetails =>
      List<String>.unmodifiable(_requests.map((request) => request.detail));

  List<String> get courseGetDataXhrRequestShapes => List<String>.unmodifiable(
    _requests
        .where(
          (request) =>
              request.path == '/course/get-data' &&
              request.requestedWith == 'XMLHttpRequest',
        )
        .map((request) => request.summary),
  );

  List<String> get courseGetDataBootstrapRequestShapes =>
      List<String>.unmodifiable(
        _requests
            .where(
              (request) =>
                  request.path == '/course/get-data' &&
                  request.requestedWith == null,
            )
            .map((request) => request.summary),
      );

  int get validCourseGetDataXhrRequestCount => _validCourseGetDataXhrRequests;

  int get bootstrapCourseGetDataRequestCount => _bootstrapCourseGetDataRequests;

  int get invalidCourseGetDataRequestCount => _invalidCourseGetDataRequests;

  int get validHomeSubmitRequestCount => _validHomeSubmitRequests;

  int get invalidHomeSubmitRequestCount => _invalidHomeSubmitRequests;

  int get validCourseDatumRequestCount => _validCourseDatumRequests;

  int get invalidCourseDatumRequestCount => _invalidCourseDatumRequests;

  bool get courseGetDataCarriedCredentials => _courseGetDataCarriedCredentials;

  bool get courseDatumCarriedCredentials => _courseDatumCarriedCredentials;

  static Future<MinimalJwWebViewFixtureServer> start({
    required String courseDatum,
    required String examHtml,
    String expectedDataId = 'loopback-data',
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = MinimalJwWebViewFixtureServer._(
      server: server,
      courseDatum: courseDatum,
      examHtml: examHtml,
      expectedDataId: expectedDataId,
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
    final carriedFixtureCredentials =
        request.headers.value('cookie')?.contains('minimal_jw_session=1') ??
        false;
    _BodyObservation? bodyObservation;
    if (request.method == 'POST') {
      bodyObservation = await _readBodyObservation(request);
    }
    _requests.add(
      _RequestShape(
        method: request.method,
        path: request.uri.path,
        contentType: contentType,
        requestedWith: requestedWith,
        bodyShape: bodyObservation?.shape,
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
    if (path == '/portal/home') {
      final valid =
          request.method == 'POST' &&
          contentType == 'application/x-www-form-urlencoded' &&
          requestedWith == null &&
          bodyObservation?.hasExactLoginFields == true;
      if (!valid) {
        _invalidHomeSubmitRequests++;
        return _writeBadRequest(request);
      }
      _validHomeSubmitRequests++;
      return _writeHtml(request, _homeHtml(), setFixtureCookie: true);
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
    if (path == '/course/get-data') {
      if (request.method != 'GET') {
        _invalidCourseGetDataRequests++;
        return _writeBadRequest(request);
      }
      final queryValid = _hasExactGetDataQuery(request.uri);
      if (!queryValid) {
        _invalidCourseGetDataRequests++;
        return _writeBadRequest(request);
      }
      if (requestedWith == 'XMLHttpRequest' && carriedFixtureCredentials) {
        _validCourseGetDataXhrRequests++;
        _courseGetDataCarriedCredentials = true;
      } else if (requestedWith == null) {
        // The page's bootstrap resource is deliberately tracked separately;
        // it must not satisfy the adapter's XHR assertion.
        _bootstrapCourseGetDataRequests++;
      } else {
        _invalidCourseGetDataRequests++;
        return _writeBadRequest(request);
      }
      return _writeText(
        request,
        '{"lessonIds":[101,102]}',
        contentType: ContentType.json,
      );
    }
    if (path == '/course/datum') {
      if (request.method != 'POST') {
        _invalidCourseDatumRequests++;
        return _writeBadRequest(request);
      }
      final valid =
          contentType == 'application/json' &&
          requestedWith == 'XMLHttpRequest' &&
          bodyObservation?.hasExactLessonIds == true &&
          carriedFixtureCredentials;
      if (!valid) {
        _invalidCourseDatumRequests++;
        return _writeBadRequest(request);
      }
      _validCourseDatumRequests++;
      _courseDatumCarriedCredentials = true;
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

  bool _hasExactGetDataQuery(Uri uri) {
    final all = uri.queryParametersAll;
    final keys = all.keys.toList()..sort();
    if (keys.length != 3 || keys.join(',') != 'bizTypeId,dataId,semesterId') {
      return false;
    }
    final bizTypeIds = all['bizTypeId'];
    final semesterIds = all['semesterId'];
    final dataIds = all['dataId'];
    return bizTypeIds?.length == 1 &&
        bizTypeIds!.first == '2' &&
        semesterIds?.length == 1 &&
        semesterIds!.first == '461' &&
        dataIds?.length == 1 &&
        dataIds!.first == _expectedDataId;
  }

  Future<_BodyObservation> _readBodyObservation(HttpRequest request) async {
    final chunks = <int>[];
    await for (final chunk in request) {
      chunks.addAll(chunk);
    }
    if (chunks.isEmpty) return const _BodyObservation(shape: 'empty');
    final text = utf8.decode(chunks, allowMalformed: true);
    if (request.headers.contentType?.mimeType ==
        'application/x-www-form-urlencoded') {
      final fields = <String>[];
      for (final part in text.split('&')) {
        if (part.isEmpty) continue;
        final equals = part.indexOf('=');
        final rawKey = equals < 0 ? part : part.substring(0, equals);
        fields.add(Uri.decodeQueryComponent(rawKey));
      }
      final sortedFields = fields.toList()..sort();
      return _BodyObservation(
        shape: 'form:${sortedFields.join(',')}',
        hasExactLoginFields:
            fields.length == 2 &&
            sortedFields.length == 2 &&
            sortedFields[0] == 'password' &&
            sortedFields[1] == 'username',
      );
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        final keys = decoded.keys.whereType<String>().toList()..sort();
        final lessonIds = decoded['lessonIds'];
        return _BodyObservation(
          shape: 'object:${keys.join(',')}',
          hasExactLessonIds:
              keys.length == 1 &&
              keys.single == 'lessonIds' &&
              lessonIds is List &&
              lessonIds.length == 2 &&
              lessonIds[0] == 101 &&
              lessonIds[1] == 102,
        );
      }
      if (decoded is List) return const _BodyObservation(shape: 'array');
    } on Object {
      return const _BodyObservation(shape: 'non_json');
    }
    return const _BodyObservation(shape: 'json_scalar');
  }

  Future<void> _writeHtml(
    HttpRequest request,
    String html, {
    bool setFixtureCookie = false,
  }) async {
    await _writeText(
      request,
      html,
      contentType: ContentType.html,
      setFixtureCookie: setFixtureCookie,
    );
  }

  Future<void> _writeText(
    HttpRequest request,
    String body, {
    required ContentType contentType,
    bool setFixtureCookie = false,
  }) async {
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = contentType
      ..headers.set('Cache-Control', 'no-store');
    if (setFixtureCookie) {
      request.response.headers.add(
        HttpHeaders.setCookieHeader,
        'minimal_jw_session=1; Path=/; HttpOnly',
      );
    }
    request.response.write(body);
    await request.response.close();
  }

  Future<void> _writeBadRequest(HttpRequest request) async {
    request.response
      ..statusCode = HttpStatus.badRequest
      ..headers.contentType = ContentType.text
      ..write('bad request');
    await request.response.close();
  }

  String _portalHtml() => '''<!doctype html>
<html><head><meta charset="utf-8"><title>JW fixture portal</title></head>
<body>
  <main style="padding:24px">
    <h1>JW fixture portal</h1>
    <a id="loopback-login-entry" data-loopback-login="true"
       href="/passport/cas/login"
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
  <script>
    const bootstrap = new Image();
    bootstrap.src = '/course/get-data?bizTypeId=2&semesterId=461&dataId=${Uri.encodeQueryComponent(_expectedDataId)}';
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

final class _BodyObservation {
  const _BodyObservation({
    required this.shape,
    this.hasExactLoginFields = false,
    this.hasExactLessonIds = false,
  });

  final String shape;
  final bool hasExactLoginFields;
  final bool hasExactLessonIds;
}
