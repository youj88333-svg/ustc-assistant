import 'dart:async';
import 'dart:io';

/// Fresh loopback origins and synthetic pages only; never contacts a school.
final class YoungObservationFixture {
  YoungObservationFixture._(
    this._business,
    this._gateway,
    this._identity,
    this._denied,
  ) {
    _business.listen((request) => _track(_serveBusiness(request)));
    _gateway.listen((request) => _track(_serveGateway(request)));
    _identity.listen((request) => _track(_serveIdentity(request)));
    _denied.listen((request) => _track(_serveDenied(request)));
  }

  final HttpServer _business, _gateway, _identity, _denied;
  final _pending = <Future<void>>{};
  int gatewayStarts = 0, gatewayFinishes = 0, identityPages = 0;
  int schedulePages = 0, deniedHits = 0;

  static Future<YoungObservationFixture> start() async {
    final servers = <HttpServer>[];
    try {
      for (var i = 0; i < 4; ++i) {
        servers.add(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
      }
      return YoungObservationFixture._(
        servers[0],
        servers[1],
        servers[2],
        servers[3],
      );
    } catch (_) {
      for (final server in servers) {
        await server.close(force: true);
      }
      rethrow;
    }
  }

  Uri _origin(HttpServer server) =>
      Uri(scheme: 'http', host: '127.0.0.1', port: server.port);
  Uri get initialUri => _origin(_business).replace(path: '/login/');
  Uri get gatewayOrigin => _origin(_gateway);
  Uri get identityOrigin => _origin(_identity);
  Uri get deniedUri => _origin(_denied).replace(path: '/denied');

  void _track(Future<void> operation) {
    _pending.add(operation);
    unawaited(
      operation.then<void>(
        (_) => _pending.remove(operation),
        onError: (Object _, StackTrace _) => _pending.remove(operation),
      ),
    );
  }

  Future<void> _html(HttpRequest request, String body) async {
    await request.drain<void>();
    request.response.headers.contentType = ContentType.html;
    request.response.write(
      '<!doctype html><html lang="en">'
      '<head><meta charset="utf-8"><title>Synthetic Young</title></head>'
      '<body>$body</body></html>',
    );
    await request.response.close();
  }

  Future<void> _redirect(HttpRequest request, Uri destination) async {
    await request.drain<void>();
    request.response.statusCode = HttpStatus.found;
    request.response.headers.set(HttpHeaders.locationHeader, '$destination');
    await request.response.close();
  }

  Future<void> _serveBusiness(HttpRequest request) async {
    switch (request.uri.path) {
      case '/login/':
        request.response.cookies.add(
          Cookie('synthetic_young', 'synthetic-cookie'),
        );
        await _html(request, '''
<p>SYNTHETIC_PRIVATE_NAME</p>
<input type="hidden" name="token" value="SYNTHETIC_PRIVATE_TOKEN">
<input value="SYNTHETIC_PRIVATE_ACCOUNT">
<table><tr><td>SYNTHETIC_PRIVATE_BUSINESS_ID</td></tr></table>
<div class="el-calendar"></div><div class="el-pagination"></div>
<a id="auth-link" href="${gatewayOrigin.replace(path: '/start')}">Continue</a>
''');
      case '/login/schedule':
        ++schedulePages;
        await _html(request, '''
<table><tr><td>SYNTHETIC_PRIVATE_NAME</td></tr></table>
<div role="table"></div><div class="el-calendar"></div>
<div role="grid"></div><div class="ant-pagination"></div>
<a id="auth-link" href="${gatewayOrigin.replace(path: '/start')}">Again</a>
''');
      default:
        await _html(request, '<p>Unknown synthetic page</p>');
    }
  }

  Future<void> _serveGateway(HttpRequest request) async {
    switch (request.uri.path) {
      case '/start':
        ++gatewayStarts;
        await _redirect(request, identityOrigin.replace(path: '/form'));
      case '/finish':
        ++gatewayFinishes;
        await _redirect(request, gatewayOrigin.replace(path: '/relay'));
      case '/relay':
        await _redirect(request, initialUri.replace(path: '/login/schedule'));
      default:
        await _html(request, '<p>Unknown synthetic gateway</p>');
    }
  }

  Future<void> _serveIdentity(HttpRequest request) async {
    ++identityPages;
    await _html(request, '''
<table><tr><td>Never inspect this authentication DOM</td></tr></table>
<input type="password" value="SYNTHETIC_PRIVATE_PASSWORD">
<form id="auth-form" method="GET" action="${gatewayOrigin.replace(path: '/finish')}">
<input type="hidden" name="payload" value="synthetic-only">
<button type="submit">Continue synthetic manual login</button></form>
''');
  }

  Future<void> _serveDenied(HttpRequest request) async {
    ++deniedHits;
    await _html(request, '<p>Denied synthetic origin</p>');
  }

  Future<void> close() async {
    for (final server in [_business, _gateway, _identity, _denied]) {
      await server.close(force: true);
    }
    await Future.wait(
      _pending.toList().map((task) => task.catchError((Object _) {})),
    );
  }
}
