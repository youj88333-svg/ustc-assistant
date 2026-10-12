import 'dart:async';
import 'dart:io';

/// A process-local HTTP fixture for browser observation tests.
///
/// It serves only fixed synthetic pages and counts fixed endpoint names. It
/// never retains request URLs beyond their path classification, headers, or
/// bodies.
final class ObservationFixture {
  ObservationFixture._(
    this._server,
    this._deniedServer,
    this._identityServer,
    this._gatewayServer,
  ) {
    _server.listen((request) => _accept(request, _FixtureServer.business));
    _deniedServer.listen((request) => _accept(request, _FixtureServer.denied));
    _identityServer.listen(
      (request) => _accept(request, _FixtureServer.identity),
    );
    _gatewayServer.listen(
      (request) => _accept(request, _FixtureServer.gateway),
    );
  }

  static const List<String> _counterNames = <String>[
    'fixture',
    'next',
    'slow',
    'download',
    'denied',
    'frame',
    'frameNext',
    'frameLate',
    'sso',
    'authLogin',
    'gateway',
    'authReady',
    'redirectDenied',
    'unknown',
  ];

  static const Duration _gracefulDrainTimeout = Duration(milliseconds: 250);
  static const Duration _forcedDrainTimeout = Duration(seconds: 2);

  static const String _fixtureHtml = '''<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"><title>本机合成教务页面</title></head>
<body>
  <h1>本机合成教务页面</h1>
  <p id="fixture-status">仅用于本机浏览器观测，不含真实账号或学校数据。</p>
  <dl>
    <dt>课程</dt><dd>合成课程：数据结构</dd>
    <dt>时间</dt><dd>周一 09:00–10:35</dd>
  </dl>
  <nav>
    <a id="next-link" href="/next">打开第二个合成文档</a>
    <a id="slow-link" href="/slow">打开受控慢响应</a>
    <a id="download-link" href="/download" download="fixture.txt">下载合成文本</a>
    <a id="auth-link" href="/sso">打开合成认证跳转</a>
  </nav>
  <iframe id="fixture-frame" name="fixture-frame" src="/frame" title="同源合成 frame"></iframe>
</body>
</html>''';

  static const String _authReadyHtml = '''<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"><title>合成认证完成</title></head>
<body>
  <h1>合成认证已完成</h1>
  <p>这是本机合成认证页面，不代表真实身份。</p>
  <a id="return-link" href="__BUSINESS_NEXT_URI__">返回合成教务页</a>
</body>
</html>''';

  static const String _nextHtml = '''<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"><title>第二个合成文档</title></head>
<body><h1>第二个合成文档</h1><p>本机合成页面。</p></body>
</html>''';

  static const String _frameHtml = '''<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"><title>同源合成 frame</title></head>
<body><p id="frame-status">同源合成 frame 已加载。</p></body>
</html>''';

  static const String _slowHtml = '''<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"><title>受控慢响应</title></head>
<body><h1>受控慢响应已释放</h1></body>
</html>''';

  static const String _downloadBody = 'M1 loopback fixture download\n';

  final HttpServer _server;
  final HttpServer _deniedServer;
  final HttpServer _identityServer;
  final HttpServer _gatewayServer;
  final Map<String, int> _hitCounts = <String, int>{
    for (final name in _counterNames) name: 0,
  };
  final Set<Future<void>> _activeHandlers = <Future<void>>{};
  final Completer<void> _slowGate = Completer<void>();
  final Completer<void> _forceCloseRequested = Completer<void>();
  Future<void>? _closeFuture;

  /// Starts the business, denied, identity, and gateway loopback origins.
  static Future<ObservationFixture> start() async {
    final servers = <HttpServer>[];
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      servers.add(server);
      final deniedServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      servers.add(deniedServer);
      final identityServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      servers.add(identityServer);
      final gatewayServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      servers.add(gatewayServer);
      return ObservationFixture._(
        server,
        deniedServer,
        identityServer,
        gatewayServer,
      );
    } catch (_) {
      await Future.wait<void>(
        servers.map((server) => server.close(force: true)),
      );
      rethrow;
    }
  }

  /// The ordinary synthetic document on the allowed loopback origin.
  Uri get initialUri => _uri(_server, '/fixture');

  Uri get nextUri => _uri(_server, '/next');

  Uri get frameUri => _uri(_server, '/frame');

  Uri get slowUri => _uri(_server, '/slow');

  Uri get downloadUri => _uri(_server, '/download');

  Uri get ssoUri => _uri(_server, '/sso');

  Uri get redirectDeniedUri => _uri(_server, '/redirect-denied');

  /// A fixed endpoint on a different loopback origin from [initialUri].
  Uri get deniedUri => _uri(_deniedServer, '/denied');

  /// The two independent loopback origins traversed by the synthetic SSO.
  List<Uri> get authenticationOrigins => List<Uri>.unmodifiable([
    _origin(_identityServer),
    _origin(_gatewayServer),
  ]);

  /// Returns a read-only snapshot containing only fixed endpoint names.
  Map<String, int> get hits =>
      Map<String, int>.unmodifiable(Map<String, int>.of(_hitCounts));

  /// Releases any request waiting on [slowUri]. Repeated calls are harmless.
  void releaseSlow() {
    if (!_slowGate.isCompleted) {
      _slowGate.complete();
    }
  }

  /// Stops accepting requests, drains active responses, and force-closes
  /// sockets if a controlled response is still waiting.
  Future<void> close() {
    final existingClose = _closeFuture;
    if (existingClose != null) {
      return existingClose;
    }

    final closing = _closeServers();
    _closeFuture = closing;
    return closing;
  }

  static Uri _uri(HttpServer server, String path) => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: server.port,
    path: path,
  );

  static Uri _origin(HttpServer server) => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: server.port,
  );

  void _accept(HttpRequest request, _FixtureServer server) {
    late final Future<void> handler;
    handler = _serve(request, server).whenComplete(() {
      _activeHandlers.remove(handler);
    });
    _activeHandlers.add(handler);
    unawaited(handler);
  }

  Future<void> _serve(HttpRequest request, _FixtureServer server) async {
    final response = request.response;
    try {
      final path = request.uri.path;
      final endpoint = _classify(path, server);
      _hitCounts[endpoint] = _hitCounts[endpoint]! + 1;

      if (request.method != 'GET') {
        response.statusCode = HttpStatus.methodNotAllowed;
        response.headers.set(HttpHeaders.allowHeader, 'GET');
        await response.close();
        return;
      }

      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      switch (endpoint) {
        case 'fixture':
          await _writeHtml(response, _fixtureHtml);
        case 'next':
          await _writeHtml(response, _nextHtml);
        case 'frame':
          await _writeHtml(response, _frameHtml);
        case 'frameNext':
        case 'frameLate':
          await _writeHtml(response, _frameHtml);
        case 'slow':
          await Future.any<void>([
            _slowGate.future,
            _forceCloseRequested.future,
          ]);
          if (!_forceCloseRequested.isCompleted) {
            await _writeHtml(response, _slowHtml);
          }
        case 'download':
          response.headers
            ..set(HttpHeaders.contentTypeHeader, 'text/plain; charset=utf-8')
            ..set(
              'content-disposition',
              'attachment; filename="m1_fixture.txt"',
            )
            ..set(HttpHeaders.contentLengthHeader, _downloadBody.length);
          response.write(_downloadBody);
          await response.close();
        case 'sso':
          await _redirect(response, _uri(_identityServer, '/auth/login'));
        case 'authLogin':
          await _redirect(response, _uri(_gatewayServer, '/gateway'));
        case 'gateway':
          await _redirect(response, _uri(_identityServer, '/auth/ready'));
        case 'authReady':
          final html = _authReadyHtml.replaceAll(
            '__BUSINESS_NEXT_URI__',
            _uri(_server, '/next').toString(),
          );
          await _writeHtml(response, html);
        case 'redirectDenied':
          await _redirect(response, _uri(_deniedServer, '/denied'));
        case 'denied':
          response.statusCode = HttpStatus.forbidden;
          response.headers.set(HttpHeaders.contentTypeHeader, 'text/plain');
          response.write('Synthetic out-of-origin navigation probe.');
          await response.close();
        case 'unknown':
          response.statusCode = HttpStatus.notFound;
          await response.close();
      }
    } catch (_) {
      // A client may close a socket while a controlled response is pending.
      // Keep the fixture silent and avoid retaining request details.
      try {
        await response.close();
      } catch (_) {
        // The socket may already have been closed by forceful teardown.
      }
    }
  }

  static String _classify(String path, _FixtureServer server) =>
      switch (server) {
        _FixtureServer.business => switch (path) {
          '/fixture' => 'fixture',
          '/next' => 'next',
          '/frame' => 'frame',
          '/frame-next' => 'frameNext',
          '/frame-late' => 'frameLate',
          '/slow' => 'slow',
          '/download' => 'download',
          '/sso' => 'sso',
          '/redirect-denied' => 'redirectDenied',
          '/denied' => 'denied',
          _ => 'unknown',
        },
        _FixtureServer.denied => path == '/denied' ? 'denied' : 'unknown',
        _FixtureServer.identity => switch (path) {
          '/auth/login' => 'authLogin',
          '/auth/ready' => 'authReady',
          _ => 'unknown',
        },
        _FixtureServer.gateway => path == '/gateway' ? 'gateway' : 'unknown',
      };

  static Future<void> _redirect(HttpResponse response, Uri destination) async {
    response.statusCode = HttpStatus.found;
    response.headers.set('location', destination.toString());
    await response.close();
  }

  static Future<void> _writeHtml(HttpResponse response, String html) async {
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      'text/html; charset=utf-8',
    );
    response.write(html);
    await response.close();
  }

  Future<void> _closeServers() async {
    final gracefulClose = Future.wait<void>([
      _server.close(),
      _deniedServer.close(),
      _identityServer.close(),
      _gatewayServer.close(),
      _waitForHandlers(),
    ]);
    try {
      await gracefulClose.timeout(_gracefulDrainTimeout);
    } on TimeoutException {
      if (!_forceCloseRequested.isCompleted) {
        _forceCloseRequested.complete();
      }
      await Future.wait<void>([
        _server.close(force: true),
        _deniedServer.close(force: true),
        _identityServer.close(force: true),
        _gatewayServer.close(force: true),
      ]);
      await _waitForHandlers().timeout(_forcedDrainTimeout);
    }
  }

  Future<void> _waitForHandlers() async {
    while (_activeHandlers.isNotEmpty) {
      await Future.wait<void>(_activeHandlers.toList());
    }
  }
}

enum _FixtureServer { business, denied, identity, gateway }
