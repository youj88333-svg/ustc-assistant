import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/jw_data_probe_fixture.dart';

void main() {
  test(
    'serves the fixed synthetic navigation and read-only data contract',
    () async {
      final fixture = await JwDataProbeFixture.start('normal');
      final client = HttpClient();
      try {
        final launcher = await _send(client, 'GET', fixture.initialUri);
        expect(launcher.statusCode, HttpStatus.found);
        expect(
          launcher.headers.value(HttpHeaders.locationHeader),
          '/for-std/course-table/info/571',
        );

        final origin = fixture.initialUri;
        final course = await _send(
          client,
          'GET',
          _at(origin, '/for-std/course-table/info/571'),
        );
        expect(course.statusCode, HttpStatus.ok);
        expect(course.headers.contentType?.mimeType, ContentType.html.mimeType);
        expect(course.body, contains('id="allSemesters"'));
        expect(course.body, contains('value="20261" selected>合成学期'));
        expect(course.body, contains('value="20262"'));

        final identity = await _send(
          client,
          'GET',
          _at(origin, '/for-std/student-info/info/571'),
        );
        expect(identity.statusCode, HttpStatus.ok);
        expect(identity.body, contains('<dt>学号</dt><dd>TEST0001</dd>'));

        final index = await _send(
          client,
          'GET',
          _at(
            origin,
            '/for-std/course-table/get-data',
            query: {'semesterId': '20261', 'dataId': '571', 'bizTypeId': '2'},
          ),
        );
        expect(index.statusCode, HttpStatus.ok);
        expect(index.headers.contentType?.mimeType, ContentType.json.mimeType);
        expect(jsonDecode(index.body), {
          'lessonIds': [11, 12],
        });

        final datum = await _send(
          client,
          'POST',
          _at(origin, '/for-std/course-table/datum'),
          body: '{"lessonIds":[11,12]}',
        );
        expect(datum.statusCode, HttpStatus.ok);
        expect(datum.headers.contentType?.mimeType, ContentType.json.mimeType);
        final datumJson = jsonDecode(datum.body) as Map<String, dynamic>;
        expect(datumJson.keys.toSet(), {'result'});
        final result = datumJson['result'] as Map<String, dynamic>;
        expect(result.keys.toSet(), {
          'lessonList',
          'scheduleGroupList',
          'scheduleList',
        });
        expect((result['lessonList'] as List<dynamic>).length, 2);
        expect((result['scheduleGroupList'] as List<dynamic>).length, 2);
        final schedules = result['scheduleList'] as List<dynamic>;
        expect(schedules, hasLength(2));
        expect(schedules.first['date'], '2026-10-15');
        expect(schedules.first['startTime'], 800);
        expect(schedules.last['date'], '2026-10-16');

        final exams = await _send(
          client,
          'GET',
          _at(origin, '/for-std/exam-arrange/info/571'),
        );
        expect(exams.statusCode, HttpStatus.ok);
        expect(exams.body, contains('2026-10-20 09:00~11:00'));
        expect(exams.body, contains('合成课程A'));
        expect(exams.body, contains('合成考场'));
        expect(exams.body, contains('合成楼'));
        expect(exams.body, contains('合成校区'));

        expect(fixture.requests, [
          'GET /for-std/course-table',
          'GET /for-std/course-table/info/571',
          'GET /for-std/student-info/info/571',
          'GET /for-std/course-table/get-data',
          'POST /for-std/course-table/datum',
          'GET /for-std/exam-arrange/info/571',
        ]);
        expect(fixture.acceptedIndexQueries, [
          {'bizTypeId': '2', 'semesterId': '20261', 'dataId': '571'},
        ]);
        expect(fixture.acceptedDatumBodies, [
          <int>[11, 12],
        ]);
        expect(fixture.rejectedRequests, 0);
      } finally {
        client.close(force: true);
        await fixture.close();
      }
    },
  );

  test(
    'rejects other methods, query parameters, and datum request fields',
    () async {
      final fixture = await JwDataProbeFixture.start('normal');
      final client = HttpClient();
      try {
        final validQuery = {
          'bizTypeId': '2',
          'semesterId': '20261',
          'dataId': '571',
        };
        final extraIndexParameter = await _send(
          client,
          'GET',
          _at(
            fixture.initialUri,
            '/for-std/course-table/get-data',
            query: {...validQuery, 'extra': 'synthetic'},
          ),
        );
        expect(extraIndexParameter.statusCode, HttpStatus.badRequest);

        final wrongIndexMethod = await _send(
          client,
          'POST',
          _at(
            fixture.initialUri,
            '/for-std/course-table/get-data',
            query: validQuery,
          ),
        );
        expect(wrongIndexMethod.statusCode, HttpStatus.badRequest);

        final extraDatumField = await _send(
          client,
          'POST',
          _at(fixture.initialUri, '/for-std/course-table/datum'),
          body: '{"lessonIds":[11,12],"extra":"synthetic"}',
        );
        expect(extraDatumField.statusCode, HttpStatus.badRequest);

        expect(fixture.requests, [
          'GET /for-std/course-table/get-data',
          'POST /for-std/course-table/get-data',
          'POST /for-std/course-table/datum',
        ]);
        expect(fixture.acceptedIndexQueries, isEmpty);
        expect(fixture.acceptedDatumBodies, isEmpty);
        expect(fixture.rejectedRequests, 3);
      } finally {
        client.close(force: true);
        await fixture.close();
      }
    },
  );
}

Uri _at(Uri origin, String path, {Map<String, String>? query}) =>
    origin.replace(path: path, queryParameters: query);

Future<_FixtureResponse> _send(
  HttpClient client,
  String method,
  Uri uri, {
  String? body,
}) async {
  final request = await client.openUrl(method, uri);
  request.followRedirects = false;
  if (body != null) {
    request.headers.contentType = ContentType.json;
    request.write(body);
  }
  final response = await request.close();
  final responseBody = await utf8.decoder.bind(response).join();
  return _FixtureResponse(response.statusCode, response.headers, responseBody);
}

final class _FixtureResponse {
  const _FixtureResponse(this.statusCode, this.headers, this.body);

  final int statusCode;
  final HttpHeaders headers;
  final String body;
}
