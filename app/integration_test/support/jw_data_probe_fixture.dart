import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Fresh loopback-only pages and read responses for the fixed JW data probe.
/// Every page value and business record is synthetic.
final class JwDataProbeFixture {
  JwDataProbeFixture._(this._server, this._redirectTrap, this.mode);

  final HttpServer _server;
  final HttpServer? _redirectTrap;
  final String mode;

  /// Only method and path are retained for every request.
  final requests = <String>[];

  /// Accepted synthetic GET parameters, recorded only after exact validation.
  final acceptedIndexQueries = <Map<String, String>>[];

  /// Accepted synthetic POST values, recorded only after exact validation.
  final acceptedDatumBodies = <List<int>>[];

  final indexEntered = Completer<void>();
  final releaseIndex = Completer<void>();

  int rejectedRequests = 0;
  int redirectTargetRequests = 0;
  int _identityReads = 0;
  bool _dataIndexStarted = false;
  bool _closing = false;

  Uri get initialUri => Uri.parse(
    'http://127.0.0.1:${_server.port}${mode == 'direct_route' ? '/for-std/course-table/info/571' : '/for-std/course-table'}',
  );

  static Future<JwDataProbeFixture> start(String mode) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirectTrap = mode == 'index_redirect'
        ? await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
        : null;
    final fixture = JwDataProbeFixture._(server, redirectTrap, mode);
    server.listen((request) => unawaited(fixture._serve(request)));
    redirectTrap?.listen((request) {
      fixture.redirectTargetRequests++;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"lessonIds":[11,12]}');
      unawaited(request.response.close());
    });
    return fixture;
  }

  Future<void> _serve(HttpRequest request) async {
    final path = request.uri.path;
    requests.add('${request.method} $path');
    try {
      switch (path) {
        case '/favicon.ico':
          if (!_isPlainGet(request)) {
            await _reject(request, HttpStatus.methodNotAllowed);
            return;
          }
          request.response.statusCode = HttpStatus.noContent;
          await request.response.close();
          break;
        case '/for-std/course-table':
          if (request.method != 'GET' || request.uri.hasQuery) {
            await _reject(request, HttpStatus.methodNotAllowed);
            return;
          }
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            '/for-std/course-table/info/571',
          );
          await request.response.close();
          break;
        case '/for-std/student-info/info/571':
          if (!_isPlainGet(request)) {
            await _reject(request, HttpStatus.methodNotAllowed);
            return;
          }
          _identityReads++;
          if (mode == 'identity_nested_label') {
            await _writeHtml(
              request,
              '''<!doctype html><html><body><table><tbody>
<tr><th><label>学号</label></th><td>TEST0001</td></tr>
</tbody></table></body></html>''',
            );
            break;
          }
          if (mode == 'identity_bad_value') {
            await _writeHtml(request, '''<!doctype html><html><body>
<table><tbody><tr><th>学号</th><td>非法值</td></tr></tbody></table>
<table><tbody><tr><th>学号</th><td>TEST0001</td></tr></tbody></table>
</body></html>''');
            break;
          }
          final studentNumber =
              mode == 'identity_changed' &&
                  _dataIndexStarted &&
                  _identityReads >= 2
              ? 'TEST0002'
              : 'TEST0001';
          await _writeHtml(
            request,
            '<!doctype html><html><body><dl>'
            '<dt>学号</dt><dd>$studentNumber</dd>'
            '</dl></body></html>',
          );
          break;
        case '/for-std/course-table/info/571':
          if (!_isPlainGet(request)) {
            await _reject(request, HttpStatus.methodNotAllowed);
            return;
          }
          if (mode == 'csp') {
            request.response.headers.set(
              'Content-Security-Policy',
              "connect-src 'none'",
            );
          }
          await _writeHtml(request, '''<!doctype html><html><body>
<select id="allSemesters" name="semesterId">
<option value="20261" selected>合成学期</option>
<option value="20262">合成备用学期</option>
</select>
</body></html>''');
          break;
        case '/for-std/course-table/get-data':
          await _serveIndex(request);
          break;
        case '/for-std/course-table/datum':
          await _serveDatum(request);
          break;
        case '/for-std/exam-arrange/info/571':
          if (!_isPlainGet(request)) {
            await _reject(request, HttpStatus.methodNotAllowed);
            return;
          }
          await _writeHtml(request, _examPage());
          break;
        default:
          await _reject(request, HttpStatus.notFound);
          break;
      }
    } on Object {
      // Browser cancellation may close a response while the fixture is serving.
      request.response.done.catchError((Object _) {});
    }
  }

  Future<void> _serveIndex(HttpRequest request) async {
    if (request.method != 'GET' || !_hasExactIndexQuery(request.uri)) {
      await _reject(request, HttpStatus.badRequest);
      return;
    }
    acceptedIndexQueries.add(const {
      'bizTypeId': '2',
      'semesterId': '20261',
      'dataId': '571',
    });
    _dataIndexStarted = true;
    if (!indexEntered.isCompleted) indexEntered.complete();
    if (_isSlowIndexMode) {
      await releaseIndex.future;
      if (_closing) return;
    }
    if (mode == 'index_redirect') {
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        'http://127.0.0.1:${_redirectTrap!.port}/redirect-target',
      );
      await request.response.close();
      return;
    }
    if (mode == 'index_mime') {
      await _writeText(request, '{"lessonIds":[11,12]}');
      return;
    }

    final response = switch (mode) {
      'index_duplicate' => '{"lessonIds":[11],"lessonIds":[11,12]}',
      'index_bad_type' => '{"lessonIds":[11,"12"]}',
      'index_wrong_shape' => '{"lessonIds":"11,12"}',
      'empty_index' => '{"lessonIds":[]}',
      _ => '{"lessonIds":[11,12]}',
    };
    await _writeJson(request, response);
  }

  Future<void> _serveDatum(HttpRequest request) async {
    if (request.method != 'POST' || request.uri.hasQuery) {
      await _reject(request, HttpStatus.badRequest);
      return;
    }
    final contentType = request.headers.contentType?.mimeType;
    final body = await utf8.decoder.bind(request).join();
    if (contentType != ContentType.json.mimeType ||
        body != '{"lessonIds":[11,12]}') {
      await _reject(request, HttpStatus.badRequest);
      return;
    }
    acceptedDatumBodies.add(const [11, 12]);

    if (mode == 'datum_oversize') {
      request.response.headers.contentType = ContentType.json;
      request.response.bufferOutput = false;
      request.response.contentLength = 8 * 1024 * 1024 + 1;
      request.response.write('{}');
      await request.response.close();
      return;
    }
    if (mode == 'datum_depth') {
      final nested =
          '${List<String>.filled(25, '[').join()}0${List<String>.filled(25, ']').join()}';
      await _writeJson(request, '{"result":{"unexpected":$nested}}');
      return;
    }
    if (mode == 'datum_mime') {
      await _writeText(request, _datumJson());
      return;
    }
    if (mode == 'datum_duplicate_json') {
      final value = _datumValue();
      final encoded = jsonEncode(value);
      await _writeJson(request, '{"result":$encoded,"result":$encoded}');
      return;
    }
    if (mode == 'datum_missing') {
      await _writeJson(request, '{}');
      return;
    }
    await _writeJson(request, _datumJson());
  }

  bool get _isSlowIndexMode =>
      mode == 'cancel' ||
      mode == 'navigation' ||
      mode == 'slow_index' ||
      mode == 'cancel_slow_index' ||
      mode == 'navigation_slow_index';

  bool _isPlainGet(HttpRequest request) =>
      request.method == 'GET' && !request.uri.hasQuery;

  bool _hasExactIndexQuery(Uri uri) {
    final values = uri.queryParametersAll;
    return values.keys.toSet().length == 3 &&
        values.length == 3 &&
        values['bizTypeId']?.length == 1 &&
        values['bizTypeId']?.single == '2' &&
        values['semesterId']?.length == 1 &&
        values['semesterId']?.single == '20261' &&
        values['dataId']?.length == 1 &&
        values['dataId']?.single == '571';
  }

  Map<String, Object?> _datumValue() {
    final lessons = <Map<String, Object?>>[
      {'id': 11, 'courseName': '合成课程A'},
      {'id': 12, 'courseName': '合成课程B'},
    ];
    final groups = <Map<String, Object?>>[
      {'id': 31, 'lessonId': 11},
      {'id': 32, 'lessonId': 12},
    ];
    final schedules = <Map<String, Object?>>[
      {
        'lessonId': 11,
        'scheduleGroupId': 31,
        'date': mode == 'date_invalid' ? '2026-02-30' : '2026-10-15',
        'startTime': mode == 'time_invalid' ? 1000 : 800,
        'endTime': 945,
      },
      {
        'lessonId': 12,
        'scheduleGroupId': 32,
        'date': '2026-10-16',
        'startTime': 1400,
        'endTime': 1545,
      },
    ];

    if (mode == 'lesson_set' || mode == 'lesson_set_missing') {
      lessons.removeLast();
      groups.removeLast();
      schedules.removeLast();
    } else if (mode == 'lesson_set_extra') {
      lessons.add({'id': 13, 'courseName': '额外合成课程'});
      groups.add({'id': 33, 'lessonId': 13});
      schedules.add({
        'lessonId': 13,
        'scheduleGroupId': 33,
        'date': '2026-10-17',
        'startTime': 1000,
        'endTime': 1145,
      });
    }
    if (mode == 'group_link') {
      groups[0] = {'id': 31, 'lessonId': 99};
    }
    if (mode == 'schedule_link') {
      schedules[0]['scheduleGroupId'] = 32;
    }

    return {
      'result': {
        'lessonList': lessons,
        'scheduleGroupList': groups,
        'scheduleList': schedules,
      },
    };
  }

  String _datumJson() => jsonEncode(_datumValue());

  String _examPage() {
    final examDate = mode == 'exam_bad_date'
        ? '2026-02-30 09:00~11:00'
        : '2026-10-20 09:00~11:00';
    final pagination = mode == 'exam_pagination'
        ? '<nav class="pagination"><a href="?page=2">2</a></nav>'
        : '';
    final rows = mode == 'empty_exams'
        ? ''
        : '''<tr>
<td>SYN001</td><td>期末</td><td>合成课程A</td><td>$examDate</td>
<td>合成考场</td><td>合成楼</td><td>合成校区</td><td>合成说明</td>
</tr>''';
    return '''<!doctype html><html><body>
<table id="exams"><thead><tr>
<th>课程号</th><th>考试类型</th><th>课程名称</th><th>日期时间</th>
<th>考场</th><th>教学楼</th><th>考场所在校区</th><th>考试说明</th>
</tr></thead><tbody>$rows</tbody></table>$pagination
</body></html>''';
  }

  Future<void> _reject(HttpRequest request, int status) async {
    rejectedRequests++;
    request.response.statusCode = status;
    await request.response.close();
  }

  Future<void> _writeHtml(HttpRequest request, String body) async {
    request.response.headers.contentType = ContentType.html;
    request.response.write(body);
    await request.response.close();
  }

  Future<void> _writeJson(HttpRequest request, String body) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write(body);
    await request.response.close();
  }

  Future<void> _writeText(HttpRequest request, String body) async {
    request.response.headers.contentType = ContentType.text;
    request.response.write(body);
    await request.response.close();
  }

  Future<void> close() async {
    _closing = true;
    if (!releaseIndex.isCompleted) releaseIndex.complete();
    await _server.close(force: true);
    await _redirectTrap?.close(force: true);
  }
}
