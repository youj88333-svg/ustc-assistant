import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/observation_fixture.dart';

void main() {
  test('serves fixed synthetic documents and a named attachment', () async {
    final fixture = await ObservationFixture.start();
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await fixture.close();
    });

    expect(fixture.initialUri.host, '127.0.0.1');
    expect(fixture.initialUri.path, '/fixture');
    expect(fixture.deniedUri.origin, isNot(fixture.initialUri.origin));

    final initial = await _get(client, fixture.initialUri);
    expect(initial.body, contains('本机合成教务页面'));
    expect(initial.body, contains('合成课程：数据结构'));
    expect(initial.body, contains('id="fixture-frame"'));
    expect(initial.body, contains('href="/next"'));
    expect(initial.body, contains('<a id="auth-link" href="/sso">'));
    expect(initial.headers.value('content-security-policy'), isNull);
    expect(initial.body.toLowerCase(), isNot(contains('cal')));

    final next = await _get(client, fixture.nextUri);
    expect(next.body, contains('第二个合成文档'));

    final frame = await _get(client, fixture.frameUri);
    expect(frame.body, contains('同源合成 frame 已加载'));

    final download = await _get(client, fixture.downloadUri);
    expect(
      download.headers.value('content-disposition'),
      'attachment; filename="m1_fixture.txt"',
    );
    expect(download.body, 'M1 loopback fixture download\n');
  });

  test(
    'serves the fixed three-hop authentication and denied redirect chains',
    () async {
      final fixture = await ObservationFixture.start();
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await fixture.close();
      });

      expect(fixture.authenticationOrigins, hasLength(2));
      expect(fixture.authenticationOrigins.toSet(), hasLength(2));
      for (final origin in fixture.authenticationOrigins) {
        expect(origin.origin, origin.toString());
        expect(origin.scheme, 'http');
        expect(origin.host, '127.0.0.1');
        expect(origin.hasPort, isTrue);
        expect(origin.path, isEmpty);
        expect(origin.hasQuery, isFalse);
        expect(origin.hasFragment, isFalse);
        expect(origin.origin, isNot(fixture.initialUri.origin));
        expect(origin.origin, isNot(fixture.deniedUri.origin));
      }

      final authentication = await _get(client, fixture.ssoUri);
      expect(authentication.body, contains('合成认证已完成'));
      expect(authentication.body, contains('id="return-link"'));
      expect(authentication.body, contains('href="${fixture.nextUri}"'));
      expect(fixture.hits['sso'], greaterThan(0));
      expect(fixture.hits['authLogin'], greaterThan(0));
      expect(fixture.hits['gateway'], greaterThan(0));
      expect(fixture.hits['authReady'], greaterThan(0));

      final denied = await _get(client, fixture.redirectDeniedUri);
      expect(denied.body, contains('out-of-origin navigation probe'));
      expect(fixture.hits['redirectDenied'], 1);
      expect(fixture.hits['denied'], 1);
    },
  );

  test('slow response stays gated until releaseSlow is called', () async {
    final fixture = await ObservationFixture.start();
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await fixture.close();
    });

    var responseCompleted = false;
    final pending = _get(client, fixture.slowUri).then((response) {
      responseCompleted = true;
      return response;
    });
    await _waitForHit(fixture, 'slow');
    expect(responseCompleted, isFalse);

    fixture.releaseSlow();
    fixture.releaseSlow();
    final response = await pending;
    expect(response.body, contains('受控慢响应已释放'));
  });

  test(
    'hit counts expose only fixed endpoint names and immutable snapshots',
    () async {
      final fixture = await ObservationFixture.start();
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await fixture.close();
      });

      final snapshot = fixture.hits;
      await _get(
        client,
        fixture.initialUri.replace(queryParameters: {'q': 'ignored'}),
      );
      await _get(client, fixture.deniedUri);
      await _get(client, fixture.initialUri.resolve('/unlisted?token=ignored'));

      expect(snapshot['fixture'], 0);
      expect(fixture.hits, {
        'fixture': 1,
        'next': 0,
        'slow': 0,
        'download': 0,
        'denied': 1,
        'frame': 0,
        'frameNext': 0,
        'frameLate': 0,
        'sso': 0,
        'authLogin': 0,
        'gateway': 0,
        'authReady': 0,
        'redirectDenied': 0,
        'unknown': 1,
      });
      expect(fixture.hits.keys, {
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
      });
      expect(() => snapshot['fixture'] = 4, throwsUnsupportedError);
    },
  );

  test('close is idempotent and force-drains a waiting slow socket', () async {
    final fixture = await ObservationFixture.start();
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await fixture.close();
    });

    final request = await client.getUrl(fixture.slowUri);
    final unsettledResponse = request.close().then<void>(
      (response) => response.drain<void>(),
      onError: (_) {},
    );
    await _waitForHit(fixture, 'slow');

    await fixture.close();
    await fixture.close();
    await unsettledResponse.timeout(const Duration(seconds: 3));
    expect(fixture.hits['slow'], 1);
  });
}

Future<_HttpResult> _get(HttpClient client, Uri uri) async {
  final request = await client.getUrl(uri);
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  return _HttpResult(response.headers, body);
}

Future<void> _waitForHit(ObservationFixture fixture, String endpoint) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (fixture.hits[endpoint] == 0) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for the fixed $endpoint endpoint.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

final class _HttpResult {
  const _HttpResult(this.headers, this.body);

  final HttpHeaders headers;
  final String body;
}
