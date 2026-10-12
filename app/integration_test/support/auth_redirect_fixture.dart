import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Local-only HTTPS and redirect fixture for synthetic authentication tests.
///
/// Request URLs, headers, and bodies are never retained. The fixture keeps
/// fixed endpoint counters and boolean classifications for its own synthetic
/// form data and cookie only.
final class AuthRedirectFixture {
  AuthRedirectFixture._({
    required this._certificateDirectory,
    required this._certificatePem,
    required this._secureServer,
    required this._plainServer,
    required this._deniedServer,
  }) {
    _secureServer.listen(_acceptSecure);
    _plainServer.listen(_acceptPlain);
    _deniedServer.listen(_acceptDenied);
  }

  static const String _tempPrefix = 'ustc_m1_tls_test_';
  static const String _formPayload = 'payload=synthetic-only';
  static const String _syntheticCookie = 'm1_synthetic=local-only';
  static const String _syntheticState = 'synthetic+state';
  static const Set<int> _allowedStatuses = <int>{302, 303, 307, 308};
  static const Duration _gracefulDrainTimeout = Duration(seconds: 1);
  static const Duration _forcedDrainTimeout = Duration(seconds: 2);

  static const String _formHtml = '''<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Synthetic HTTPS form</title></head>
<body>
  <h1>Synthetic HTTPS form</h1>
  <p>This local page contains only synthetic test data.</p>
  <form id="auth-form" method="POST" action="__FORM_ACTION__">
    <input type="hidden" name="payload" value="synthetic-only">
    <button type="submit">Continue synthetic flow</button>
  </form>
</body>
</html>''';

  static const String _frameContainerHtml = '''<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Synthetic frame form container</title></head>
<body>
  <h1>Synthetic frame form container</h1>
  <iframe id="fixture-frame" src="__IFRAME_FORM_URI__"
          title="Synthetic form"></iframe>
</body>
</html>''';

  static const String _completeHtml = '''<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Synthetic flow complete</title></head>
<body><h1>Synthetic redirect flow complete</h1></body>
</html>''';

  static const String _notFoundBody = 'Synthetic fixture endpoint not found.';
  static const String _deniedBody = 'Synthetic denied-origin probe.';

  final Directory _certificateDirectory;
  final String _certificatePem;
  final HttpServer _secureServer;
  final HttpServer _plainServer;
  final HttpServer _deniedServer;
  final Set<Future<void>> _activeHandlers = <Future<void>>{};
  Future<void>? _closeFuture;

  int _relayHits = 0;
  int _gatewayHits = 0;
  int _completeHits = 0;
  int _plainHits = 0;
  int _deniedHits = 0;
  String _lastGatewayMethod = 'OTHER';
  String _relayOriginCategory = 'absent';
  String _gatewayOriginCategory = 'absent';
  bool _relayCookiePresent = false;
  bool _gatewayCookiePresent = false;
  bool _payloadPreserved = false;
  bool _gatewayPayloadPreserved = false;
  bool _statePreserved = false;

  /// Creates a fresh RSA certificate and binds three random loopback ports.
  static Future<AuthRedirectFixture> start() async {
    final certificateDirectory = await Directory.systemTemp.createTemp(
      _tempPrefix,
    );
    final servers = <HttpServer>[];
    try {
      final certificatePath = p.join(
        certificateDirectory.path,
        'fixture-cert.pem',
      );
      final privateKeyPath = p.join(
        certificateDirectory.path,
        'fixture-key.pem',
      );
      await _generateCertificate(
        certificateDirectory,
        certificatePath,
        privateKeyPath,
      );
      final certificatePem = await File(certificatePath).readAsString();
      final securityContext = SecurityContext(withTrustedRoots: false)
        ..useCertificateChain(certificatePath)
        ..usePrivateKey(privateKeyPath);

      final secureServer = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        securityContext,
      );
      servers.add(secureServer);
      final plainServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      servers.add(plainServer);
      final deniedServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      servers.add(deniedServer);

      return AuthRedirectFixture._(
        certificateDirectory: certificateDirectory,
        certificatePem: certificatePem,
        secureServer: secureServer,
        plainServer: plainServer,
        deniedServer: deniedServer,
      );
    } catch (_) {
      await Future.wait<void>(
        servers.map((server) => server.close(force: true)),
      );
      await _deleteCertificateDirectory(certificateDirectory);
      rethrow;
    }
  }

  Uri get initialUri => formUri(307);

  /// The cleartext HTTP origin used by the form action before native upgrade.
  Uri get plainOrigin => _origin('http', _plainServer);

  /// The HTTPS origin whose certificate is exposed by [certificatePem].
  Uri get secureOrigin => _origin('https', _secureServer);

  Uri get deniedUri => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: _deniedServer.port,
    path: '/denied',
  );

  /// Public certificate PEM for exact pinning in the native Debug fixture.
  String get certificatePem => _certificatePem;

  Uri formUri(int status) => _pageUri('/form', status);

  Uri iframeFormUri(int status) => _pageUri('/iframe-form', status);

  Uri frameContainerUri(int status) => _pageUri('/frame-container', status);

  Uri get directFormUri => secureOrigin.replace(path: '/direct-form');

  Uri get directFrameFormUri =>
      secureOrigin.replace(path: '/direct-frame-form');

  Uri get directFrameContainerUri =>
      secureOrigin.replace(path: '/direct-frame-container');

  int get relayHits => _relayHits;
  int get gatewayHits => _gatewayHits;
  int get completeHits => _completeHits;
  int get plainHits => _plainHits;
  int get deniedHits => _deniedHits;
  String get lastGatewayMethod => _lastGatewayMethod;
  String get relayOriginCategory => _relayOriginCategory;
  String get gatewayOriginCategory => _gatewayOriginCategory;
  bool get relayCookiePresent => _relayCookiePresent;
  bool get gatewayCookiePresent => _gatewayCookiePresent;
  bool get payloadPreserved => _payloadPreserved;
  bool get gatewayPayloadPreserved => _gatewayPayloadPreserved;
  bool get statePreserved => _statePreserved;

  /// Resets only fixed counters and classifications for the next synthetic run.
  void resetObservations() {
    _relayHits = 0;
    _gatewayHits = 0;
    _completeHits = 0;
    _plainHits = 0;
    _deniedHits = 0;
    _lastGatewayMethod = 'OTHER';
    _relayOriginCategory = 'absent';
    _gatewayOriginCategory = 'absent';
    _relayCookiePresent = false;
    _gatewayCookiePresent = false;
    _payloadPreserved = false;
    _gatewayPayloadPreserved = false;
    _statePreserved = false;
  }

  /// Stops and drains all three listeners before removing this fixture's key.
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    final closing = _closeServers();
    _closeFuture = closing;
    return closing;
  }

  static Future<void> _generateCertificate(
    Directory workingDirectory,
    String certificatePath,
    String privateKeyPath,
  ) async {
    final configured = Platform.environment['USTC_TEST_OPENSSL'];
    final executable = configured == null || configured.trim().isEmpty
        ? r'E:\conda\envs\basic310\Library\bin\openssl.exe'
        : configured;
    try {
      // Conda's OpenSSL may have a compiled-in config path that isn't present
      // outside its activated shell. Own the tiny test config as well as key.
      final config = File(p.join(workingDirectory.path, 'openssl-test.cnf'));
      await config.writeAsString(
        '[req]\ndistinguished_name = dn\nprompt = no\n[dn]\nCN = 127.0.0.1\n',
        flush: true,
      );
      final result = await Process.run(
        executable,
        <String>[
          'req',
          '-config',
          config.path,
          '-x509',
          '-newkey',
          'rsa:2048',
          '-sha256',
          '-days',
          '1',
          '-nodes',
          '-keyout',
          privateKeyPath,
          '-out',
          certificatePath,
          '-subj',
          '/CN=127.0.0.1',
          '-addext',
          'subjectAltName=IP:127.0.0.1',
        ],
        workingDirectory: workingDirectory.path,
        runInShell: false,
      );
      if (result.exitCode != 0) {
        throw StateError('OpenSSL did not create the local test certificate.');
      }
    } on Object {
      throw StateError('Unable to generate the local test certificate.');
    }
  }

  Uri _pageUri(String path, int status) {
    if (!_allowedStatuses.contains(status)) {
      throw ArgumentError.value(
        status,
        'status',
        'Must be 302, 303, 307, or 308.',
      );
    }
    return secureOrigin.replace(path: '$path-$status');
  }

  Uri _formActionUri(int status) => plainOrigin.replace(
    path: '/relay',
    queryParameters: <String, String>{
      'status': '$status',
      'state': _syntheticState,
    },
  );

  static Uri _origin(String scheme, HttpServer server) => Uri(
    scheme: scheme,
    host: InternetAddress.loopbackIPv4.address,
    port: server.port,
  );

  void _acceptSecure(HttpRequest request) => _track(_serveSecure(request));

  void _acceptPlain(HttpRequest request) => _track(_servePlain(request));

  void _acceptDenied(HttpRequest request) => _track(_serveDenied(request));

  void _track(Future<void> serving) {
    late final Future<void> handler;
    handler = serving.whenComplete(() => _activeHandlers.remove(handler));
    _activeHandlers.add(handler);
    unawaited(handler);
  }

  Future<void> _serveSecure(HttpRequest request) async {
    final response = request.response;
    try {
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      final formStatus = _formStatusFromPath(request.uri.path);
      if (formStatus != null) {
        await _serveForm(request, formStatus);
        return;
      }
      final frameStatus = _frameContainerStatusFromPath(request.uri.path);
      if (frameStatus != null) {
        await _serveFrameContainer(request, frameStatus);
        return;
      }
      switch (request.uri.path) {
        case '/direct-form':
        case '/direct-frame-form':
          await _serveDirectForm(request);
        case '/direct-frame-container':
          await _serveDirectFrameContainer(request);
        case '/relay':
          await _serveRelay(request);
        case '/gateway':
          await _serveGateway(request);
        case '/complete':
          await _serveComplete(request);
        default:
          response.statusCode = HttpStatus.notFound;
          response.write(_notFoundBody);
          await response.close();
      }
    } catch (_) {
      await _closeResponseQuietly(response);
    }
  }

  Future<void> _serveForm(HttpRequest request, int status) async {
    await _servePostForm(request, _formActionUri(status));
  }

  Future<void> _serveDirectForm(HttpRequest request) async {
    await _servePostForm(request, plainOrigin.replace(path: '/complete'));
  }

  Future<void> _servePostForm(HttpRequest request, Uri actionUri) async {
    final response = request.response;
    if (request.method != 'GET') {
      await _methodNotAllowed(request);
      return;
    }
    if (request.uri.hasQuery) {
      response.statusCode = HttpStatus.badRequest;
      await response.close();
      return;
    }
    response.headers.add(
      'set-cookie',
      'm1_synthetic=local-only; Secure; SameSite=Lax; Path=/',
    );
    final action = actionUri.toString().replaceAll('&', '&amp;');
    await _writeHtml(response, _formHtml.replaceAll('__FORM_ACTION__', action));
  }

  Future<void> _serveFrameContainer(HttpRequest request, int status) async {
    await _serveFramePage(request, iframeFormUri(status));
  }

  Future<void> _serveDirectFrameContainer(HttpRequest request) async {
    await _serveFramePage(request, directFrameFormUri);
  }

  Future<void> _serveFramePage(HttpRequest request, Uri iframeUri) async {
    if (request.method != 'GET') {
      await _methodNotAllowed(request);
      return;
    }
    if (request.uri.hasQuery) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    await _writeHtml(
      request.response,
      _frameContainerHtml.replaceAll(
        '__IFRAME_FORM_URI__',
        iframeUri.toString(),
      ),
    );
  }

  Future<void> _serveRelay(HttpRequest request) async {
    _relayHits++;
    _relayOriginCategory = _classifyOrigin(request);
    _relayCookiePresent = _hasSyntheticCookie(request);
    _statePreserved = _hasSyntheticState(request.uri);
    _gatewayPayloadPreserved = false;
    final status = _readStatus(request.uri);
    if (request.method == 'POST') {
      _payloadPreserved = await _matchesFormPayload(request);
    } else {
      _payloadPreserved = false;
      await request.drain<void>();
    }
    if (request.method != 'POST' || status == null) {
      request.response.statusCode = request.method == 'POST'
          ? HttpStatus.badRequest
          : HttpStatus.methodNotAllowed;
      if (request.method != 'POST') {
        request.response.headers.set(HttpHeaders.allowHeader, 'POST');
      }
      await request.response.close();
      return;
    }
    await _redirect(
      request.response,
      status,
      secureOrigin.replace(
        path: '/gateway',
        queryParameters: {'status': '$status'},
      ),
    );
  }

  Future<void> _serveGateway(HttpRequest request) async {
    _gatewayHits++;
    _gatewayOriginCategory = _classifyOrigin(request);
    _gatewayCookiePresent = _hasSyntheticCookie(request);
    _lastGatewayMethod = switch (request.method) {
      'GET' => 'GET',
      'POST' => 'POST',
      _ => 'OTHER',
    };
    if (request.method == 'POST') {
      final gatewayPayloadMatches = await _matchesFormPayload(request);
      _gatewayPayloadPreserved = _payloadPreserved && gatewayPayloadMatches;
    } else {
      _gatewayPayloadPreserved = false;
      await request.drain<void>();
    }
    final status = _readStatus(request.uri);
    if (status == null) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    await _redirect(
      request.response,
      HttpStatus.temporaryRedirect,
      secureOrigin.replace(path: '/complete'),
    );
  }

  Future<void> _serveComplete(HttpRequest request) async {
    _completeHits++;
    await request.drain<void>();
    await _writeHtml(request.response, _completeHtml);
  }

  Future<void> _servePlain(HttpRequest request) async {
    _plainHits++;
    try {
      await request.drain<void>();
      request.response
        ..statusCode = HttpStatus.notFound
        ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
        ..write(_notFoundBody);
      await request.response.close();
    } catch (_) {
      await _closeResponseQuietly(request.response);
    }
  }

  Future<void> _serveDenied(HttpRequest request) async {
    _deniedHits++;
    try {
      await request.drain<void>();
      request.response
        ..statusCode = HttpStatus.forbidden
        ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
        ..write(_deniedBody);
      await request.response.close();
    } catch (_) {
      await _closeResponseQuietly(request.response);
    }
  }

  String _classifyOrigin(HttpRequest request) {
    final values = request.headers['origin'] ?? const <String>[];
    if (values.isEmpty) return 'absent';
    if (values.length != 1) return 'other';
    final value = values.single;
    if (value == 'null') return 'null';
    if (value == secureOrigin.origin) return 'secure';
    if (value == plainOrigin.origin) return 'plain';
    return 'other';
  }

  static bool _hasSyntheticCookie(HttpRequest request) {
    for (final header in request.headers['cookie'] ?? const <String>[]) {
      for (final part in header.split(';')) {
        if (part.trim() == _syntheticCookie) return true;
      }
    }
    return false;
  }

  static bool _hasSyntheticState(Uri uri) {
    final values = uri.queryParametersAll['state'];
    return values?.length == 1 && values!.single == _syntheticState;
  }

  static int? _readStatus(Uri uri) {
    final values = uri.queryParametersAll['status'];
    if (values == null || values.length != 1) return null;
    final status = int.tryParse(values.single);
    return _allowedStatuses.contains(status) ? status : null;
  }

  static int? _formStatusFromPath(String path) {
    for (final prefix in const <String>['/form-', '/iframe-form-']) {
      if (!path.startsWith(prefix)) continue;
      final status = int.tryParse(path.substring(prefix.length));
      return _allowedStatuses.contains(status) ? status : null;
    }
    return null;
  }

  static int? _frameContainerStatusFromPath(String path) {
    const prefix = '/frame-container-';
    if (!path.startsWith(prefix)) return null;
    final status = int.tryParse(path.substring(prefix.length));
    return _allowedStatuses.contains(status) ? status : null;
  }

  static Future<bool> _matchesFormPayload(HttpRequest request) async {
    var offset = 0;
    var matches = true;
    await for (final chunk in request) {
      for (final byte in chunk) {
        if (offset >= _formPayload.length ||
            byte != _formPayload.codeUnitAt(offset)) {
          matches = false;
        }
        offset++;
      }
    }
    return matches && offset == _formPayload.length;
  }

  static Future<void> _methodNotAllowed(HttpRequest request) async {
    await request.drain<void>();
    request.response
      ..statusCode = HttpStatus.methodNotAllowed
      ..headers.set(HttpHeaders.allowHeader, 'GET');
    await request.response.close();
  }

  static Future<void> _redirect(
    HttpResponse response,
    int status,
    Uri destination,
  ) async {
    response.statusCode = status;
    response.headers.set(HttpHeaders.locationHeader, destination.toString());
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

  static Future<void> _closeResponseQuietly(HttpResponse response) async {
    try {
      await response.close();
    } catch (_) {
      // The peer may already have closed the local test socket.
    }
  }

  Future<void> _closeServers() async {
    try {
      await Future.wait<void>([
        _secureServer.close(),
        _plainServer.close(),
        _deniedServer.close(),
        _waitForHandlers(),
      ]).timeout(_gracefulDrainTimeout);
    } on TimeoutException {
      await Future.wait<void>([
        _secureServer.close(force: true),
        _plainServer.close(force: true),
        _deniedServer.close(force: true),
      ]);
      await _waitForHandlers().timeout(_forcedDrainTimeout);
    }
    await _deleteCertificateDirectory(_certificateDirectory);
  }

  Future<void> _waitForHandlers() async {
    while (_activeHandlers.isNotEmpty) {
      await Future.wait<void>(_activeHandlers.toList());
    }
  }

  static Future<void> _deleteCertificateDirectory(Directory directory) async {
    if (!await directory.exists()) return;
    final tempDirectory = await Directory.systemTemp.resolveSymbolicLinks();
    final targetDirectory = await directory.resolveSymbolicLinks();
    final pathContext = Platform.isWindows ? p.windows : p.posix;
    final tempPath = pathContext.normalize(tempDirectory);
    final targetPath = pathContext.normalize(targetDirectory);
    if (!pathContext.isWithin(tempPath, targetPath) ||
        !pathContext.basename(targetPath).startsWith(_tempPrefix)) {
      throw StateError(
        'Refusing to remove an unverified certificate directory.',
      );
    }
    await Directory(targetPath).delete(recursive: true);
  }
}
