import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/auth_redirect_fixture.dart';

void main() {
  test(
    'serves a pinned loopback HTTPS form with a cleartext upgrade target',
    () async {
      final fixture = await AuthRedirectFixture.start();
      final client = _clientTrusting(fixture.certificatePem);
      addTearDown(() async {
        client.close(force: true);
        await fixture.close();
        await fixture.close();
      });

      expect(fixture.initialUri, fixture.formUri(307));
      expect(fixture.initialUri.scheme, 'https');
      expect(fixture.initialUri.path, '/form-307');
      expect(fixture.initialUri.hasQuery, isFalse);
      expect(fixture.initialUri.hasFragment, isFalse);
      expect(fixture.plainOrigin.scheme, 'http');
      expect(fixture.plainOrigin.path, isEmpty);
      expect(fixture.plainOrigin.hasQuery, isFalse);
      expect(fixture.plainOrigin.hasFragment, isFalse);
      expect(fixture.secureOrigin.scheme, 'https');
      expect(fixture.secureOrigin.path, isEmpty);
      expect(fixture.secureOrigin.hasQuery, isFalse);
      expect(fixture.secureOrigin.hasFragment, isFalse);
      expect(fixture.plainOrigin.host, '127.0.0.1');
      expect(fixture.secureOrigin.host, '127.0.0.1');
      expect(fixture.plainOrigin.origin, isNot(fixture.secureOrigin.origin));
      expect(fixture.deniedUri.path, '/denied');
      expect(fixture.deniedUri.origin, isNot(fixture.plainOrigin.origin));
      expect(fixture.deniedUri.origin, isNot(fixture.secureOrigin.origin));
      expect(fixture.certificatePem, startsWith('-----BEGIN CERTIFICATE-----'));
      expect(fixture.certificatePem, isNot(contains('PRIVATE KEY')));
      expect(() => fixture.formUri(301), throwsArgumentError);
      expect(() => fixture.iframeFormUri(200), throwsArgumentError);

      final form = await _get(client, fixture.formUri(307));
      expect(form.statusCode, HttpStatus.ok);
      expect(form.body, contains('id="auth-form" method="POST"'));
      expect(form.body, contains('name="payload" value="synthetic-only"'));
      expect(
        form.headers['set-cookie'],
        contains('m1_synthetic=local-only; Secure; SameSite=Lax; Path=/'),
      );
      final expectedAction = _relayUri(
        fixture,
        307,
        scheme: 'http',
      ).toString().replaceAll('&', '&amp;');
      expect(form.body, contains('action="$expectedAction"'));

      expect(fixture.iframeFormUri(303).path, '/iframe-form-303');
      expect(fixture.iframeFormUri(303).hasQuery, isFalse);
      final iframeForm = await _get(client, fixture.iframeFormUri(303));
      expect(iframeForm.statusCode, HttpStatus.ok);
      expect(iframeForm.body, contains('id="auth-form" method="POST"'));
      final iframeAction = _relayUri(
        fixture,
        303,
        scheme: 'http',
      ).toString().replaceAll('&', '&amp;');
      expect(iframeForm.body, contains('action="$iframeAction"'));

      final frameContainer = await _get(client, fixture.frameContainerUri(307));
      expect(fixture.frameContainerUri(307).path, '/frame-container-307');
      expect(fixture.frameContainerUri(307).hasQuery, isFalse);
      expect(frameContainer.statusCode, HttpStatus.ok);
      expect(frameContainer.body, contains('iframe id="fixture-frame"'));
      expect(
        frameContainer.body,
        contains('src="${fixture.iframeFormUri(307)}"'),
      );
      expect(frameContainer.body, isNot(contains('id="auth-form"')));

      expect(fixture.directFormUri.path, '/direct-form');
      expect(fixture.directFormUri.hasQuery, isFalse);
      expect(fixture.directFrameFormUri.path, '/direct-frame-form');
      expect(fixture.directFrameFormUri.hasQuery, isFalse);
      expect(fixture.directFrameContainerUri.path, '/direct-frame-container');
      expect(fixture.directFrameContainerUri.hasQuery, isFalse);

      final directForm = await _get(client, fixture.directFormUri);
      final directAction = fixture.plainOrigin
          .replace(path: '/complete')
          .toString();
      expect(directForm.statusCode, HttpStatus.ok);
      expect(directForm.body, contains('id="auth-form" method="POST"'));
      expect(directForm.body, contains('action="$directAction"'));

      final directFrameForm = await _get(client, fixture.directFrameFormUri);
      expect(directFrameForm.statusCode, HttpStatus.ok);
      expect(directFrameForm.body, contains('id="auth-form" method="POST"'));
      expect(directFrameForm.body, contains('action="$directAction"'));

      final directFrameContainer = await _get(
        client,
        fixture.directFrameContainerUri,
      );
      expect(directFrameContainer.statusCode, HttpStatus.ok);
      expect(directFrameContainer.body, contains('iframe id="fixture-frame"'));
      expect(
        directFrameContainer.body,
        contains('src="${fixture.directFrameFormUri}"'),
      );
      expect(directFrameContainer.body, isNot(contains('id="auth-form"')));

      final plainComplete = await _get(
        client,
        fixture.plainOrigin.replace(path: '/complete'),
      );
      expect(plainComplete.statusCode, HttpStatus.notFound);
      expect(fixture.plainHits, 1);
      final secureComplete = await _get(
        client,
        fixture.secureOrigin.replace(path: '/complete'),
      );
      expect(secureComplete.statusCode, HttpStatus.ok);
      expect(fixture.completeHits, 1);
    },
  );

  test('fixture endpoints support each POST redirect status', () async {
    final fixture = await AuthRedirectFixture.start();
    final client = _clientTrusting(fixture.certificatePem);
    addTearDown(() async {
      client.close(force: true);
      await fixture.close();
    });

    for (final status in <int>[302, 303, 307, 308]) {
      fixture.resetObservations();
      final page = await _get(client, fixture.formUri(status));
      expect(page.statusCode, HttpStatus.ok);

      final request = await client.postUrl(
        _relayUri(fixture, status, scheme: 'https'),
      );
      request.followRedirects = false;
      request.headers
        ..set(
          HttpHeaders.contentTypeHeader,
          'application/x-www-form-urlencoded',
        )
        ..set('origin', 'null')
        ..set('cookie', 'm1_synthetic=local-only');
      request.write('payload=synthetic-only');
      final relayResponse = await request.close();
      final gatewayUri = fixture.secureOrigin.replace(
        path: '/gateway',
        queryParameters: {'status': '$status'},
      );
      expect(relayResponse.statusCode, status);
      expect(
        relayResponse.headers.value(HttpHeaders.locationHeader),
        gatewayUri.toString(),
      );
      await relayResponse.drain<void>();

      // The test names each transition explicitly; HttpClient isn't used as a
      // browser redirect implementation for these method semantics.
      final preservePost = status == 307 || status == 308;
      final gatewayRequest = preservePost
          ? await client.postUrl(gatewayUri)
          : await client.getUrl(gatewayUri);
      gatewayRequest.followRedirects = false;
      gatewayRequest.headers
        ..set('origin', 'null')
        ..set('cookie', 'm1_synthetic=local-only');
      if (preservePost) {
        gatewayRequest.headers.set(
          HttpHeaders.contentTypeHeader,
          'application/x-www-form-urlencoded',
        );
        gatewayRequest.write('payload=synthetic-only');
      }
      final gatewayResponse = await gatewayRequest.close();
      final completeUri = fixture.secureOrigin.replace(path: '/complete');
      expect(gatewayResponse.statusCode, HttpStatus.temporaryRedirect);
      expect(
        gatewayResponse.headers.value(HttpHeaders.locationHeader),
        completeUri.toString(),
      );
      await gatewayResponse.drain<void>();

      final completeRequest = preservePost
          ? await client.postUrl(completeUri)
          : await client.getUrl(completeUri);
      completeRequest.followRedirects = false;
      if (preservePost) {
        completeRequest.headers.set(
          HttpHeaders.contentTypeHeader,
          'application/x-www-form-urlencoded',
        );
        completeRequest.write('payload=synthetic-only');
      }
      final completeResponse = await completeRequest.close();
      final body = await utf8.decoder.bind(completeResponse).join();

      expect(completeResponse.statusCode, HttpStatus.ok);
      expect(body, contains('Synthetic redirect flow complete'));
      expect(fixture.relayHits, 1);
      expect(fixture.gatewayHits, 1);
      expect(fixture.completeHits, 1);
      expect(fixture.plainHits, 0);
      expect(fixture.deniedHits, 0);
      expect(fixture.relayOriginCategory, 'null');
      expect(fixture.relayCookiePresent, isTrue);
      expect(fixture.gatewayOriginCategory, 'null');
      expect(fixture.gatewayCookiePresent, isTrue);
      expect(fixture.statePreserved, isTrue);
      expect(
        fixture.lastGatewayMethod,
        status == 307 || status == 308 ? 'POST' : 'GET',
      );
      expect(fixture.payloadPreserved, isTrue);
      expect(fixture.gatewayPayloadPreserved, status == 307 || status == 308);
    }
  });

  test('headers and cookies reduce to fixed categories', () async {
    final fixture = await AuthRedirectFixture.start();
    final client = _clientTrusting(fixture.certificatePem);
    addTearDown(() async {
      client.close(force: true);
      await fixture.close();
    });

    final categories = <({String? value, String category})>[
      (value: fixture.secureOrigin.origin, category: 'secure'),
      (value: fixture.plainOrigin.origin, category: 'plain'),
      (value: 'null', category: 'null'),
      (value: null, category: 'absent'),
      (value: 'https://synthetic.invalid', category: 'other'),
    ];
    for (final item in categories) {
      fixture.resetObservations();
      final request = await client.postUrl(
        _relayUri(fixture, 302, scheme: 'https'),
      );
      request.followRedirects = false;
      if (item.value != null) request.headers.set('origin', item.value!);
      request.headers.set('cookie', 'm1_synthetic=local-only');
      request.write('payload=synthetic-only');
      final response = await request.close();
      await response.drain<void>();

      expect(response.statusCode, HttpStatus.found);
      expect(fixture.relayOriginCategory, item.category);
      expect(fixture.relayCookiePresent, isTrue);
      expect(fixture.payloadPreserved, isTrue);
      expect(fixture.gatewayPayloadPreserved, isFalse);
    }

    final cookieCases = <({String? value, bool present})>[
      (value: 'm1_synthetic=local-only', present: true),
      (value: 'm1_synthetic=not-local', present: false),
      (value: 'unrelated=synthetic-only', present: false),
      (value: null, present: false),
    ];
    for (final item in cookieCases) {
      fixture.resetObservations();
      final request = await client.getUrl(
        fixture.secureOrigin.replace(
          path: '/gateway',
          queryParameters: const {'status': '307'},
        ),
      );
      request.followRedirects = false;
      request.headers.set('origin', fixture.secureOrigin.origin);
      if (item.value != null) request.headers.set('cookie', item.value!);
      final response = await request.close();
      await response.drain<void>();

      expect(response.statusCode, HttpStatus.temporaryRedirect);
      expect(fixture.gatewayOriginCategory, 'secure');
      expect(fixture.gatewayCookiePresent, item.present);
      expect(fixture.lastGatewayMethod, 'GET');
      expect(fixture.gatewayPayloadPreserved, isFalse);
    }

    fixture.resetObservations();
    expect(fixture.relayHits, 0);
    expect(fixture.gatewayHits, 0);
    expect(fixture.completeHits, 0);
    expect(fixture.plainHits, 0);
    expect(fixture.deniedHits, 0);
    expect(fixture.relayOriginCategory, 'absent');
    expect(fixture.gatewayOriginCategory, 'absent');
    expect(fixture.relayCookiePresent, isFalse);
    expect(fixture.gatewayCookiePresent, isFalse);
    expect(fixture.payloadPreserved, isFalse);
    expect(fixture.gatewayPayloadPreserved, isFalse);
    expect(fixture.statePreserved, isFalse);
  });

  test('plain origin only counts requests', () async {
    final fixture = await AuthRedirectFixture.start();
    final client = _clientTrusting(fixture.certificatePem);
    addTearDown(() async {
      client.close(force: true);
      await fixture.close();
    });

    final request = await client.postUrl(
      _relayUri(fixture, 307, scheme: 'http'),
    );
    request.write('payload=synthetic-only');
    final response = await request.close();
    await response.drain<void>();

    expect(response.statusCode, HttpStatus.notFound);
    expect(fixture.plainHits, 1);
    expect(fixture.relayHits, 0);
    expect(fixture.gatewayHits, 0);
  });
}

HttpClient _clientTrusting(String certificatePem) {
  final context = SecurityContext(withTrustedRoots: false)
    ..setTrustedCertificatesBytes(utf8.encode(certificatePem));
  return HttpClient(context: context)..findProxy = (_) => 'DIRECT';
}

Uri _relayUri(
  AuthRedirectFixture fixture,
  int status, {
  required String scheme,
}) {
  final origin = scheme == 'http' ? fixture.plainOrigin : fixture.secureOrigin;
  return origin.replace(
    path: '/relay',
    queryParameters: <String, String>{
      'status': '$status',
      'state': 'synthetic+state',
    },
  );
}

Future<_Response> _get(HttpClient client, Uri uri) async {
  final request = await client.getUrl(uri);
  final response = await request.close();
  return _Response(
    response.statusCode,
    response.headers,
    await utf8.decoder.bind(response).join(),
  );
}

final class _Response {
  const _Response(this.statusCode, this.headers, this.body);

  final int statusCode;
  final HttpHeaders headers;
  final String body;
}
