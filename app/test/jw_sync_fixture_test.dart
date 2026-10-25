import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/jw_sync_fixture.dart';

void main() {
  test(
    'launcher cookie observations only record launcher entry cookies',
    () async {
      final fixture = await JwSyncFixture.start();
      final client = HttpClient();
      try {
        final first = await _get(client, fixture.initialUri);
        expect(first.statusCode, HttpStatus.found);
        final setCookies =
            first.headers[HttpHeaders.setCookieHeader] ?? const <String>[];
        expect(setCookies, hasLength(2));
        final parsed = <String, Cookie>{};
        for (final value in setCookies) {
          final cookie = Cookie.fromSetCookieValue(value);
          parsed[cookie.name] = cookie;
        }
        final persistent = parsed['synthetic-profile-marker'];
        final session = parsed['synthetic-session-marker'];
        expect(persistent, isNotNull);
        expect(persistent!.value, 'present');
        expect(persistent.path, '/');
        expect(persistent.httpOnly, isTrue);
        expect(persistent.maxAge, 60 * 60 * 24 * 30);
        expect(session, isNotNull);
        expect(session!.value, 'present');
        expect(session.path, '/');
        expect(session.httpOnly, isTrue);
        expect(session.maxAge, isNull);
        expect(fixture.launcherCookieIssueCount, 1);
        expect(fixture.launcherCookieObservations, hasLength(1));
        _expectMarkers(fixture.launcherCookieObservations.single, false, false);

        final second = await _get(client, fixture.initialUri);
        expect(second.statusCode, HttpStatus.found);
        expect(
          second.headers[HttpHeaders.setCookieHeader] ?? const <String>[],
          isEmpty,
        );
        expect(fixture.launcherCookieIssueCount, 1);
        expect(fixture.launcherCookieObservations, hasLength(2));
        _expectMarkers(fixture.launcherCookieObservations[0], false, false);
        _expectMarkers(fixture.launcherCookieObservations[1], false, false);

        final third = await _get(
          client,
          fixture.initialUri,
          cookies: [
            Cookie('synthetic-profile-marker', 'present'),
            Cookie('synthetic-session-marker', 'present'),
          ],
        );
        expect(third.statusCode, HttpStatus.found);
        expect(
          third.headers[HttpHeaders.setCookieHeader] ?? const <String>[],
          isEmpty,
        );
        expect(fixture.launcherCookieIssueCount, 1);
        _expectMarkers(fixture.launcherCookieObservations.last, true, true);

        final beforeDetails = fixture.launcherCookieObservations;
        final details = await _get(
          client,
          fixture.initialUri.replace(path: '/for-std/course-table/info/571'),
          cookies: [
            Cookie('synthetic-profile-marker', 'present'),
            Cookie('synthetic-session-marker', 'present'),
          ],
        );
        expect(details.statusCode, HttpStatus.ok);
        expect(fixture.launcherCookieObservations, beforeDetails);
        expect(fixture.launcherCookieObservations, hasLength(3));
        expect(fixture.launcherCookieIssueCount, 1);
      } finally {
        client.close(force: true);
        await fixture.close();
      }
    },
  );
}

void _expectMarkers(
  JwLauncherCookieObservation observation,
  bool persistent,
  bool session,
) {
  expect(observation.persistentMarkerPresent, persistent);
  expect(observation.sessionMarkerPresent, session);
}

Future<HttpClientResponse> _get(
  HttpClient client,
  Uri uri, {
  List<Cookie> cookies = const <Cookie>[],
}) async {
  final request = await client.getUrl(uri);
  request.followRedirects = false;
  request.cookies.addAll(cookies);
  final response = await request.close();
  await response.drain<void>();
  return response;
}
