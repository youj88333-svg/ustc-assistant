import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/jw_sync_fixture.dart';

void main() {
  test(
    'I2 opt-in login keeps the form until synthetic authentication',
    () async {
      final identityServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final fixture = await JwSyncFixture.start(
        requireLogin: true,
        syntheticIdentityOrigin: Uri.parse(
          'http://127.0.0.1:${identityServer.port}/',
        ),
      );
      final client = HttpClient();
      try {
        final response = await _request(
          client,
          fixture.initialUri.resolve('/login'),
        );

        expect(response.statusCode, HttpStatus.ok);
        expect(response.body, contains('id="login-unified-wrapper"'));
        expect(
          response.body,
          contains('http://127.0.0.1:${identityServer.port}/cas/login'),
        );
        expect(fixture.authenticatedHomeCount, 0);
      } finally {
        client.close(force: true);
        await fixture.close();
        await identityServer.close(force: true);
      }
    },
  );

  test(
    'I2 opt-in authenticated GET /login redirects to cookie-checked home',
    () async {
      final identityServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final fixture = await JwSyncFixture.start(
        requireLogin: true,
        syntheticIdentityOrigin: Uri.parse(
          'http://127.0.0.1:${identityServer.port}/',
        ),
      );
      final client = HttpClient();
      try {
        final response = await _request(
          client,
          fixture.initialUri.resolve('/login'),
          authenticated: true,
        );

        expect(response.statusCode, HttpStatus.found);
        expect(response.location, '/home');
        expect(fixture.authenticatedHomeCount, 0);

        final home = await _request(
          client,
          fixture.initialUri.resolve('/home'),
          authenticated: true,
        );
        expect(home.statusCode, HttpStatus.ok);
        expect(fixture.authenticatedHomeCount, 1);
      } finally {
        client.close(force: true);
        await fixture.close();
        await identityServer.close(force: true);
      }
    },
  );

  test('default fixture login remains unchanged with an auth marker', () async {
    final fixture = await JwSyncFixture.start(requireLogin: true);
    final client = HttpClient();
    try {
      final login = await _request(
        client,
        fixture.initialUri.resolve('/login'),
        authenticated: true,
      );
      expect(login.statusCode, HttpStatus.ok);
      expect(login.body, contains("location.href='/cas/login'"));

      final cas = await _request(
        client,
        fixture.initialUri.resolve('/cas/login'),
      );
      expect(cas.statusCode, HttpStatus.ok);
      expect(cas.body, contains('id="normalLoginForm"'));
      expect(fixture.authenticatedHomeCount, 0);
    } finally {
      client.close(force: true);
      await fixture.close();
    }
  });

  test('I2 opt-in login rejects non-GET and parameterized requests', () async {
    final identityServer = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final fixture = await JwSyncFixture.start(
      requireLogin: true,
      syntheticIdentityOrigin: Uri.parse(
        'http://127.0.0.1:${identityServer.port}/',
      ),
    );
    final client = HttpClient();
    try {
      final query = await _request(
        client,
        fixture.initialUri.resolve('/login?next=/home'),
        authenticated: true,
      );
      final post = await _request(
        client,
        fixture.initialUri.resolve('/login'),
        method: 'POST',
        authenticated: true,
      );

      expect(query.statusCode, HttpStatus.notFound);
      expect(post.statusCode, HttpStatus.notFound);
      expect(fixture.authenticatedHomeCount, 0);
      expect(fixture.rejectedRequestCount, 2);
    } finally {
      client.close(force: true);
      await fixture.close();
      await identityServer.close(force: true);
    }
  });
}

Future<_FixtureResponse> _request(
  HttpClient client,
  Uri uri, {
  String method = 'GET',
  bool authenticated = false,
}) async {
  final request = await client.openUrl(method, uri);
  request.followRedirects = false;
  if (authenticated) {
    request.cookies.add(Cookie('synthetic-auth-marker', 'present'));
  }
  final response = await request.close();
  return _FixtureResponse(
    statusCode: response.statusCode,
    location: response.headers.value(HttpHeaders.locationHeader),
    body: await utf8.decoder.bind(response).join(),
  );
}

final class _FixtureResponse {
  const _FixtureResponse({
    required this.statusCode,
    required this.location,
    required this.body,
  });

  final int statusCode;
  final String? location;
  final String body;
}
