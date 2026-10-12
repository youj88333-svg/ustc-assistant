import 'dart:async';
import 'dart:convert';
import 'dart:io';

enum JwDuplicateScheduleMode {
  none,
  identical,
  differentEnd,
  differentTeachers,
  differentRoom,
}

final class JwLauncherCookieObservation {
  const JwLauncherCookieObservation({
    required this.persistentMarkerPresent,
    required this.sessionMarkerPresent,
  });

  final bool persistentMarkerPresent;
  final bool sessionMarkerPresent;
}

/// A small, fresh loopback source for the native JW collection flow.
///
/// The cookies below are synthetic profile-continuity evidence only. Identity
/// is served independently by the fixed identity page and checked by the app.
final class JwSyncFixture {
  JwSyncFixture._(this._server, this.requireLogin);

  final HttpServer _server;
  final bool requireLogin;
  int authenticationSubmissions = 0;
  bool emptyCourse = false;
  bool emptyExams = false;
  bool omitAcademicDetails = false;
  bool malformedAcademicDetails = false;
  String courseRoom = '合成教室 5304';
  String courseTeacher = '合成教师甲';
  bool hideSpringSemester = false;
  bool identityChangedAfterIndex = false;
  bool pauseIndex = false;
  JwDuplicateScheduleMode duplicateSchedule = JwDuplicateScheduleMode.none;
  final List<String> requests = <String>[];
  final List<int> acceptedIndexSemesters = <int>[];
  final List<List<int>> acceptedDatumLessonIds = <List<int>>[];
  final List<JwLauncherCookieObservation> _launcherCookieObservations =
      <JwLauncherCookieObservation>[];
  final Completer<void> indexEntered = Completer<void>();
  final Completer<void> releaseIndex = Completer<void>();
  int rejectedRequestCount = 0;
  int _launcherCookieIssueCount = 0;
  int _identityReadCount = 0;
  bool _indexStarted = false;
  bool _launcherCookiesIssued = false;
  bool _closing = false;
  bool _closed = false;

  List<JwLauncherCookieObservation> get launcherCookieObservations =>
      List.unmodifiable(_launcherCookieObservations);

  int get launcherCookieIssueCount => _launcherCookieIssueCount;

  Uri get initialUri =>
      Uri.parse('http://127.0.0.1:${_server.port}/for-std/course-table');

  static Future<JwSyncFixture> start({bool requireLogin = false}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = JwSyncFixture._(server, requireLogin);
    server.listen((request) => unawaited(fixture._serve(request)));
    return fixture;
  }

  Future<void> _serve(HttpRequest request) async {
    final path = request.uri.path;
    requests.add('${request.method} $path');

    try {
      if (requireLogin &&
          path.startsWith('/for-std/') &&
          !_hasCookie(request, 'synthetic-auth-marker')) {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, '/login');
        await request.response.close();
        return;
      }
      switch (path) {
        case '/login':
          if (!requireLogin || !_plainGet(request)) {
            await _reject(request, HttpStatus.notFound);
            return;
          }
          await _writeHtml(request, '''<!doctype html><html><body>
<button id="login-unified-wrapper" onclick="location.href='/cas/login'">Synthetic SSO</button>
</body></html>''');
          break;
        case '/cas/login':
          if (!requireLogin || !_plainGet(request)) {
            await _reject(request, HttpStatus.notFound);
            return;
          }
          await _writeHtml(request, '''<!doctype html><html><body>
<form id="autoLoginForm" style="display:none">
<input name="username" type="hidden"><input name="password" type="hidden"></form>
<form id="normalLoginForm"><input name="username" type="text" id="nameInput">
<input name="username" style="display:none" type="text">
<input type="password"><button id="passkey-tab" type="button" role="tab" aria-selected="false">Synthetic passkey tab</button>
<button id="submitBtn" class="login-button" type="submit">Synthetic login</button></form>
<script>document.querySelector('#normalLoginForm').addEventListener('submit', async function(e) {
 e.preventDefault();
 const r = await fetch('/fixture-authenticate', {method:'POST',headers:{'Content-Type':'application/json'},
 body:JSON.stringify({username:this.querySelector('[name=username]').value,password:this.querySelector('[type=password]').value})});
 if(r.ok) location.href='/home';
});</script></body></html>''');
          break;
        case '/fixture-authenticate':
          if (!requireLogin ||
              request.method != 'POST' ||
              request.uri.hasQuery) {
            await _reject(request, HttpStatus.methodNotAllowed);
            return;
          }
          authenticationSubmissions++;
          final raw = await utf8.decoder.bind(request).join();
          final bundle = jsonDecode(raw);
          final accepted =
              bundle is Map &&
              bundle.length == 2 &&
              bundle['username'] == 'TEST0001' &&
              bundle['password'] == 'synthetic-password';
          if (!accepted) {
            await _reject(request, HttpStatus.unauthorized);
            return;
          }
          // The acknowledged click can precede an AJAX login redirect. The
          // coordinator must wait without submitting the same secret again.
          await Future<void>.delayed(const Duration(milliseconds: 700));
          request.response.cookies.add(
            Cookie('synthetic-auth-marker', 'present')
              ..httpOnly = true
              ..path = '/',
          );
          await _writeJson(request, '{"accepted":true}');
          break;
        case '/home':
          if (!requireLogin || !_plainGet(request)) {
            await _reject(request, HttpStatus.notFound);
            return;
          }
          await _writeHtml(
            request,
            '<!doctype html><html><body>Synthetic home</body></html>',
          );
          break;
        case '/favicon.ico':
          if (request.method != 'GET' || request.uri.hasQuery) {
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
          _launcherCookieObservations.add(
            JwLauncherCookieObservation(
              persistentMarkerPresent: _hasCookie(
                request,
                'synthetic-profile-marker',
              ),
              sessionMarkerPresent: _hasCookie(
                request,
                'synthetic-session-marker',
              ),
            ),
          );
          // These synthetic markers only describe cookie-jar continuity. They
          // never affect the identity reply or an import decision.
          if (!_launcherCookiesIssued) {
            _launcherCookiesIssued = true;
            _launcherCookieIssueCount++;
            request.response.cookies.add(
              Cookie('synthetic-profile-marker', 'present')
                ..httpOnly = true
                ..path = '/'
                ..maxAge = 60 * 60 * 24 * 30,
            );
            request.response.cookies.add(
              Cookie('synthetic-session-marker', 'present')
                ..httpOnly = true
                ..path = '/',
            );
          }
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            '/for-std/course-table/info/571',
          );
          await request.response.close();
          break;
        case '/for-std/course-table/info/571':
          if (!_plainGet(request)) {
            await _reject(request, HttpStatus.methodNotAllowed);
            return;
          }
          await _writeHtml(request, '''<!doctype html><html><body>
<select id="allSemesters">
  <option value="20261" selected>2026 秋季学期（合成）</option>
  ${hideSpringSemester ? '' : '<option value="20262">2026 春季学期（合成）</option>'}
</select>
</body></html>''');
          break;
        case '/for-std/student-info/info/571':
          if (!_plainGet(request)) {
            await _reject(request, HttpStatus.methodNotAllowed);
            return;
          }
          _identityReadCount++;
          final identity =
              identityChangedAfterIndex &&
                  _indexStarted &&
                  _identityReadCount > 1
              ? 'TEST0002'
              : 'TEST0001';
          await _writeHtml(
            request,
            '<!doctype html><html><body><dl>'
            '<dt>学号</dt><dd>$identity</dd>'
            '</dl></body></html>',
          );
          break;
        case '/for-std/course-table/get-data':
          await _serveIndex(request);
          break;
        case '/for-std/course-table/datum':
          await _serveDatum(request);
          break;
        case '/for-std/exam-arrange/info/571':
          if (!_plainGet(request)) {
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
      // A native close can cancel an in-flight local request. Do not retain
      // exception text or response content in the fixture.
      request.response.done.catchError((Object _) {});
    }
  }

  bool _hasCookie(HttpRequest request, String name) => request.cookies.any(
    (cookie) => cookie.name == name && cookie.value == 'present',
  );

  Future<void> _serveIndex(HttpRequest request) async {
    final query = request.uri.queryParametersAll;
    final semesterValues = query['semesterId'];
    final validQuery =
        request.method == 'GET' &&
        !request.uri.hasFragment &&
        query.length == 3 &&
        query['bizTypeId']?.length == 1 &&
        query['bizTypeId']?.single == '2' &&
        semesterValues?.length == 1 &&
        const {'20261', '20262'}.contains(semesterValues?.single) &&
        query['dataId']?.length == 1 &&
        query['dataId']?.single == '571';
    if (!validQuery) {
      await _reject(request, HttpStatus.badRequest);
      return;
    }

    acceptedIndexSemesters.add(int.parse(semesterValues!.single));
    _indexStarted = true;
    if (!indexEntered.isCompleted) indexEntered.complete();
    if (pauseIndex) {
      await releaseIndex.future;
      if (_closing) {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }
    }
    await _writeJson(
      request,
      jsonEncode({
        'lessonIds': emptyCourse ? <int>[] : <int>[11],
      }),
    );
  }

  Future<void> _serveDatum(HttpRequest request) async {
    if (request.method != 'POST' ||
        request.uri.hasQuery ||
        request.headers.contentType?.mimeType != ContentType.json.mimeType) {
      await _reject(request, HttpStatus.badRequest);
      return;
    }
    final body = await utf8.decoder.bind(request).join();
    if (body != '{"lessonIds":[11]}' || emptyCourse) {
      await _reject(request, HttpStatus.badRequest);
      return;
    }
    acceptedDatumLessonIds.add(const [11]);
    await _writeJson(
      request,
      jsonEncode({
        'result': {
          'lessonList': [
            {
              'id': 11,
              'courseName': '合成课程',
              if (!omitAcademicDetails) 'code': 'SYN-C101.01',
              if (!omitAcademicDetails) 'courseTypeName': '合成必修课程',
            },
          ],
          'scheduleGroupList': [
            {'id': 21, 'lessonId': 11},
          ],
          'scheduleList': [
            {
              'lessonId': 11,
              'scheduleGroupId': 21,
              'date': '2026-10-12',
              'startTime': 800,
              'endTime': 950,
              if (!omitAcademicDetails) ...{
                'personName': courseTeacher,
                'weekIndex': 6,
                'weekday': 1,
                'periods': 2,
                'exerciseClass': false,
                'room': malformedAcademicDetails
                    ? 'invalid-room-object'
                    : {
                        'nameZh': courseRoom,
                        'code': 'SYN-R5304',
                        'virtual': false,
                        'building': {
                          'nameZh': '合成教学楼',
                          'campus': {'nameZh': '合成东校区'},
                        },
                      },
              },
            },
            if (duplicateSchedule != JwDuplicateScheduleMode.none)
              {
                'lessonId': 11,
                'scheduleGroupId': 21,
                'date': '2026-10-12',
                'startTime': 800,
                'endTime':
                    duplicateSchedule == JwDuplicateScheduleMode.differentEnd
                    ? 1000
                    : 950,
                if (!omitAcademicDetails) ...{
                  'personName':
                      duplicateSchedule ==
                          JwDuplicateScheduleMode.differentTeachers
                      ? '合成教师乙'
                      : courseTeacher,
                  'weekIndex': 6,
                  'weekday': 1,
                  'periods': 2,
                  'exerciseClass': false,
                  'room': {
                    'nameZh':
                        duplicateSchedule ==
                            JwDuplicateScheduleMode.differentRoom
                        ? '不同合成教室'
                        : courseRoom,
                    'code': 'SYN-R5304',
                    'virtual': false,
                    'building': {
                      'nameZh': '合成教学楼',
                      'campus': {'nameZh': '合成东校区'},
                    },
                  },
                },
              },
          ],
        },
      }),
    );
  }

  String _examPage() {
    final rows = emptyExams
        ? ''
        : '''<tr>
<td>TEST-C1</td><td>期末</td><td>合成考试课程</td>
<td>2026-10-15 09:00~11:00</td><td>合成考场</td>
<td>合成教学楼</td><td>合成校区</td><td>合成考试说明</td>
</tr>''';
    return '''<!doctype html><html><body>
<table id="exams">
  <thead><tr>
    <th>课程号</th><th>考试类型</th><th>课程名称</th><th>日期时间</th>
    <th>考场</th><th>教学楼</th><th>考场所在校区</th><th>考试说明</th>
  </tr></thead>
  <tbody>$rows</tbody>
</table>
</body></html>''';
  }

  bool _plainGet(HttpRequest request) =>
      request.method == 'GET' && !request.uri.hasQuery;

  Future<void> _reject(HttpRequest request, int status) async {
    rejectedRequestCount++;
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

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _closing = true;
    if (!releaseIndex.isCompleted) releaseIndex.complete();
    await _server.close();
  }
}
