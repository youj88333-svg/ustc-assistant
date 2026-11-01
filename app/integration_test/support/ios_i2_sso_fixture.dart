import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Fixed loopback identity endpoint for the iOS I2 manual SSO exercise.
/// It accepts one exact synthetic form shape and never retains its body.
final class IOSI2SsoFixture {
  IOSI2SsoFixture._(this._server);

  final HttpServer _server;
  Uri? _businessOrigin;
  int loginPageRequestCount = 0;
  int formPostCount = 0;
  int acceptedSubmissionCount = 0;
  int rejectedRequestCount = 0;
  final List<String> requests = <String>[];
  bool _closed = false;

  Uri get origin => Uri.parse('http://127.0.0.1:${_server.port}/');

  static Future<IOSI2SsoFixture> start({int port = 0}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final fixture = IOSI2SsoFixture._(server);
    server.listen((request) => unawaited(fixture._serve(request)));
    return fixture;
  }

  void configureBusinessOrigin(Uri origin) {
    if (_businessOrigin != null ||
        !_isLoopbackOrigin(origin) ||
        origin.port == _server.port) {
      throw StateError('invalid_synthetic_business_origin');
    }
    _businessOrigin = Uri.parse(origin.origin);
  }

  static bool _isLoopbackOrigin(Uri uri) =>
      uri.scheme == 'http' &&
      uri.host == '127.0.0.1' &&
      uri.hasPort &&
      uri.port > 0 &&
      uri.port <= 65535 &&
      uri.userInfo.isEmpty &&
      (uri.path.isEmpty || uri.path == '/') &&
      !uri.hasQuery &&
      !uri.hasFragment;

  Future<void> _serve(HttpRequest request) async {
    final path = request.uri.path;
    requests.add('${request.method} $path');
    try {
      if (path == '/cas/login' &&
          request.method == 'GET' &&
          !request.uri.hasQuery &&
          !request.uri.hasFragment) {
        loginPageRequestCount++;
        final action = origin.resolve('/cas/login');
        request.response.headers.set(
          HttpHeaders.cacheControlHeader,
          'no-store',
        );
        request.response.headers.contentType = ContentType.html;
        request.response.write('''<!doctype html><html><body>
<form id="normalLoginForm" method="post" action="$action">
<input id="nameInput" name="username" type="text">
<input id="passwordInput" name="password" type="password">
<button id="submitBtn" type="submit">Synthetic login</button>
</form></body></html>''');
        await request.response.close();
        return;
      }
      if (path == '/cas/login' && request.method == 'POST') {
        formPostCount++;
        if (request.uri.hasQuery ||
            request.uri.hasFragment ||
            request.headers.contentType?.mimeType !=
                'application/x-www-form-urlencoded') {
          rejectedRequestCount++;
          request.response.statusCode = HttpStatus.badRequest;
          await request.response.close();
          return;
        }
        final body = await utf8.decoder.bind(request).join();
        final accepted =
            _businessOrigin != null &&
            body == 'username=TEST0001&password=synthetic-password';
        if (!accepted) {
          rejectedRequestCount++;
          request.response.statusCode = HttpStatus.unauthorized;
          await request.response.close();
          return;
        }
        acceptedSubmissionCount++;
        request.response.statusCode = HttpStatus.seeOther;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          _businessOrigin!.resolve('/ucas-sso/login').toString(),
        );
        await request.response.close();
        return;
      }
      if (path == '/favicon.ico' &&
          request.method == 'GET' &&
          !request.uri.hasQuery &&
          !request.uri.hasFragment) {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }
      rejectedRequestCount++;
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    } on Object {
      request.response.done.catchError((Object _) {});
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close();
  }
}
