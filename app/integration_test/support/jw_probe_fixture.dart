import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Fresh synthetic server pages. No real school, account or browser assets.
final class JwProbeFixture {
  JwProbeFixture._(this._server, this._denied, this.mode);
  final HttpServer _server;
  final HttpServer _denied;
  final String mode;
  final requests = <String>[];
  final identityEntered = Completer<void>();
  final releaseIdentity = Completer<void>();
  final workerReady = Completer<void>();
  String workerStatus = 'waiting';
  final launcherCookieStates = <bool>[];
  int forbiddenRequests = 0;
  bool _closing = false;

  Uri get initialUri => Uri.parse(
    'http://127.0.0.1:${_server.port}${mode == 'home' ? '/home' : '/for-std/course-table/info/17'}',
  );

  static Future<JwProbeFixture> start(String mode) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final denied = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = JwProbeFixture._(server, denied, mode);
    denied.listen((request) async {
      fixture.forbiddenRequests++;
      request.response.statusCode = 200;
      await request.response.close();
    });
    server.listen((request) => unawaited(fixture._serve(request)));
    return fixture;
  }

  Future<void> _serve(HttpRequest request) async {
    requests.add('${request.method} ${request.uri.path}');
    try {
      request.response.headers.contentType = ContentType.html;
      final path = request.uri.path;
      if (path == '/home') {
        request.response.cookies.add(
          Cookie('synthetic-home-session', 'present')
            ..httpOnly = true
            ..path = '/',
        );
        request.response.write('''<!doctype html><html><body>
<h1>合成教务首页</h1><iframe name="business-tab" src="/for-std/course-table/info/17"></iframe>
<a href="/for-std/exam-arrange/info/17" target="business-tab">合成内部考试标签</a>
</body></html>''');
      } else if (path == '/for-std/course-table' ||
          path == '/for-std/exam-arrange') {
        launcherCookieStates.add(
          request.cookies.any(
            (cookie) =>
                cookie.name == 'synthetic-home-session' &&
                cookie.value == 'present',
          ),
        );
        request.response.statusCode = 302;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          '$path/info/17',
        );
      } else if (path == '/probe-sw.js') {
        request.response.headers.contentType = ContentType(
          'text',
          'javascript',
          charset: 'utf-8',
        );
        final workerScript = utf8.encode('''
self.addEventListener('install', event => event.waitUntil(self.skipWaiting()));
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
self.addEventListener('fetch', event => {
  if (new URL(event.request.url).pathname.includes('/student-info/')) {
    event.respondWith(Promise.resolve(new Response('<dl><dt>学号</dt><dd>SPOOF001</dd></dl>',
      {headers: {'Content-Type': 'text/html'}})));
  }
});''');
        request.response.contentLength = workerScript.length;
        request.response.add(workerScript);
      } else if (path == '/worker-ready') {
        workerStatus = 'ready';
        if (!workerReady.isCompleted) workerReady.complete();
        request.response.write('ready');
      } else if (path.startsWith('/worker-error/')) {
        workerStatus = path.split('/').last;
        if (!workerReady.isCompleted) workerReady.complete();
        request.response.write('failed');
      } else if (path == '/for-std/student-info/info/17') {
        if (!identityEntered.isCompleted) identityEntered.complete();
        if (mode == 'slow' || mode == 'navigation') {
          await releaseIdentity.future;
        }
        if (_closing) return;
        if (mode == 'redirect') {
          request.response.statusCode = 302;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            'http://127.0.0.1:${_denied.port}/login',
          );
        } else if (mode == 'mime') {
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"untrusted":"synthetic"}');
        } else if (mode == 'oversize') {
          request.response.write('x' * (2 * 1024 * 1024 + 100));
        } else if (mode == 'missing') {
          // A login-looking input must never become a business identity.
          request.response.write('<input name="username" value="TEST0001">');
        } else {
          final code = mode == 'mismatch' ? 'TEST0002' : 'TEST0001';
          request.response.write(
            '<!doctype html><dl><dt>学号</dt><dd>$code</dd></dl>'
            '${mode == 'conflict' ? '<table><tr><th>学号</th><td>TEST0002</td></tr></table>' : ''}',
          );
        }
      } else if (path == '/for-std/course-table/info/17') {
        final overLimitCatalog = List<String>.generate(
          257,
          (index) =>
              '{"id":${700 + index},"name":"Synthetic semester ${index + 1}"}',
        ).join(',');
        final jsonBoundaryCatalog = List<String>.generate(
          256,
          (index) =>
              '{"id":${120000 + index},"name":"JSON boundary ${index + 1}"}',
        ).join(',');
        final historyOptions = List<String>.generate(81, (index) {
          final selected = index == 0 ? ' selected' : '';
          return '<option value="${81000 + index}"$selected>'
              'History synthetic semester ${index + 1}</option>';
        }).join('\n');
        // CDP JSON escaping doubles each slash, putting 256 max-length labels
        // above 64 KiB while preserving a 120-character source label.
        final maxOptionName = List<String>.filled(120, '\\').join();
        final boundaryOptions = List<String>.generate(256, (index) {
          final selected = index == 0 ? ' selected' : '';
          return '<option value="${100000 + index}"$selected>'
              '$maxOptionName</option>';
        }).join('\n');
        final staticOverLimitOptions = List<String>.generate(257, (index) {
          final selected = index == 0 ? ' selected' : '';
          return '<option value="${200000 + index}"$selected>'
              'Over limit synthetic semester ${index + 1}</option>';
        }).join('\n');
        if (mode == 'csp') {
          request.response.headers.set(
            'Content-Security-Policy',
            "connect-src 'none'",
          );
        }
        if (mode == 'worker') {
          request.response.write('''<!doctype html><html><body><script>
(async () => {
  let stage = 'register';
  const timeout = setTimeout(() => fetch('/worker-error/timeout-' + stage), 8000);
  try {
    await navigator.serviceWorker.register('/probe-sw.js', {scope: '/'});
    stage = 'ready';
    await navigator.serviceWorker.ready;
    stage = 'controller';
    if (!navigator.serviceWorker.controller) {
      await new Promise(resolve => navigator.serviceWorker.addEventListener('controllerchange', resolve, {once: true}));
    }
    clearTimeout(timeout);
    await fetch('/worker-ready');
  } catch (_) {
    clearTimeout(timeout);
    await fetch('/worker-error/' + stage);
  }
})();
</script></body></html>''');
          await request.response.close();
          return;
        }
        final semesterMarkup = switch (mode) {
          'all_semesters' =>
            '''<select id="allSemesters">
<option value="461" selected>2026 秋季学期（合成）</option>
<option value="441">2026 春季学期（合成）</option></select>''',
          'static_history_81' =>
            '''<select id="allSemesters">$historyOptions</select>''',
          'static_boundary_256' =>
            '''<select id="allSemesters">$boundaryOptions</select>''',
          'static_over_limit_257' =>
            '''<select id="allSemesters">$staticOverLimitOptions</select>''',
          'json_catalog' ||
          'json_null' ||
          'json_boundary_256' ||
          'empty_select' ||
          'literal_context_fake' ||
          'literal_unsupported' ||
          'legacy_comment_catalog' ||
          'function_between_duplicate' ||
          'late_regex_rejects_assignments' ||
          'bad_first_rhs_duplicate' ||
          'escaped_duplicate_key' ||
          'fractional_selection' ||
          'literal_duplicate' ||
          'literal_key_conflict' ||
          'catalog_duplicate' ||
          'catalog_id' ||
          'catalog_name' ||
          'selection_unknown' ||
          'selection_missing' ||
          'literal_map' ||
          'catalog_limit' => '<select id="allSemesters"></select>',
          'invalid_option_json' =>
            '''<select id="allSemesters"><option value="0" selected>无效服务器项（合成）</option></select>''',
          'observed_shape' => '',
          'duplicate_semester_selects' =>
            '''<select id="allSemesters">
<option value="461" selected>2026 秋季学期（合成）</option></select>
<select name="semesterId"><option value="441">2026 春季学期（合成）</option></select>''',
          'invalid_semester_option' =>
            '''<select name="allSemesters">
<option value="461" selected>2026 秋季学期（合成）</option>
<option value="0">无效学期（合成）</option></select>''',
          _ =>
            '''<select name="semesterId" id="semesterId">
<option value="461" selected>2026 秋季学期（合成）</option>
<option value="441">2026 春季学期（合成）</option></select>''',
        };
        final semesterDeclarations = switch (mode) {
          'json_catalog' =>
            '''var semesters = [{"id":461,"nameZh":"2026秋合成"},{"id":441,"code":"2026春合成"}];
var semesterId = 461;''',
          'json_null' =>
            '''var semesters = [{"id":461,"nameZh":"2026秋合成"},{"id":441,"code":"2026春合成"}];
var semesterId = null;''',
          'literal_context_fake' =>
            '''if (false) { var semesters = [{"id":461,"name":"嵌套合成"}]; var semesterId = 461; }
var decoy = "var semesters = [{\\"id\\":461}]; var semesterId = 461;";
/* var semesters = [{"id":461,"name":"注释合成"}]; var semesterId = 461; */
// var semesters = [{"id":461,"name":"行注释合成"}]; var semesterId = 461;''',
          'legacy_comment_catalog' =>
            '''<!-- ;var semesters=[{"id":461,"name":"fake"}];var semesterId=461;
-->''',
          'function_between_duplicate' =>
            '''var semesters=[{"id":461,"name":"有效目录"}]; function f() {} var semesters=[{"id":441,"name":"第二目录"}]; var semesterId=461;''',
          'late_regex_rejects_assignments' =>
            '''var /*comment*/ semesters=[{"id":461,"name":"有效目录"}]; var semesterId=461; const decoy=/x/;''',
          'bad_first_rhs_duplicate' =>
            '''var semesters=make(); var semesters=[{"id":461,"name":"后续目录"}]; var semesterId=461;''',
          'escaped_duplicate_key' =>
            '''var semesters=[{"id":461,"\\u0069d":462,"name":"fake"}]; var semesterId=461;''',
          'fractional_selection' =>
            '''var semesters=[{"id":461,"name":"有效目录"}]; var semesterId=461.0;''',
          'literal_unsupported' =>
            '''const regexDecoy = /var semesters = \\[.*\\]/;
const divisionDecoy = 8 / 2;
const templateDecoy = `var semesterId = 461;`;''',
          'literal_duplicate' =>
            '''var semesters = [{"id":461,"name":"重复合成一"}];
var semesters = [{"id":441,"name":"重复合成二"}];
var semesterId = 461;''',
          'literal_key_conflict' =>
            '''var semesters = [{"id":461,"id":462,"name":"重复键合成"}];
var semesterId = 461;''',
          'catalog_duplicate' =>
            '''var semesters = [{"id":461,"name":"目录合成一"},{"id":461,"name":"目录合成二"}];
var semesterId = 461;''',
          'catalog_id' =>
            '''var semesters = [{"__proto__":{"id":461},"name":"原型合成"}];
var semesterId = 461;''',
          'catalog_name' =>
            '''var semesters = [{"id":461,"nameZh":"","code":"合法回退不得生效"}];
var semesterId = 461;''',
          'selection_unknown' =>
            '''var semesters = [{"id":461,"name":"目录合成"}];
var semesterId = 999;''',
          'selection_missing' =>
            '''var semesters = [{"id":461,"name":"目录合成"}];''',
          'literal_map' =>
            '''var semesters = [{"id":461,"name":"目录合成"}].map(function (semester) { return semester; });
var semesterId = 461;''',
          'catalog_limit' =>
            '''var semesters = [$overLimitCatalog];
var semesterId = 700;''',
          'json_boundary_256' =>
            '''var semesters = [$jsonBoundaryCatalog];
var semesterId = 120000;''',
          'invalid_option_json' =>
            '''var semesters = [{"id":461,"name":"JSON绕过合成"}];
var semesterId = 461;''',
          _ => '',
        };
        final semesterDomFill = switch (mode) {
          'json_catalog' =>
            '''document.getElementById('allSemesters').innerHTML = '<option value="461" selected>客户端合成一</option><option value="441">客户端合成二</option>';''',
          'json_null' =>
            '''document.getElementById('allSemesters').innerHTML = '<option value="461">客户端合成一</option><option value="441">客户端合成二</option>';''',
          'empty_select' =>
            '''document.getElementById('allSemesters').innerHTML = '<option value="731" selected>仅直播合成一</option><option value="732">仅直播合成二</option>';''',
          'static_history_81' =>
            '''(function () {
  var select = document.getElementById('allSemesters');
  for (var index = select.options.length - 1; index >= 0; index--) {
    if (!select.options[index].selected) select.remove(index);
  }
})();''',
          _ => '',
        };
        request.response.write('''<!doctype html><html><body>
$semesterMarkup
<script>$semesterDeclarations</script>
<script>
$semesterDomFill
// The product helper must use a distinct world with native browser primitives.
window.fetch = () => { throw new Error('synthetic replacement'); };
window.DOMParser = function() { throw new Error('synthetic replacement'); };
Function.prototype.call = function() { throw new Error('synthetic call hook'); };
RegExp.prototype.exec = function() { return null; };
RegExp.prototype[Symbol.replace] = function() { return 'synthetic replacement'; };
Object.defineProperty(NodeList.prototype, 'length', {get() { return 0; }});
Document.prototype.then = function() { throw new Error('synthetic document hook'); };
Response.prototype.then = function() { throw new Error('synthetic response hook'); };
</script></body></html>''');
      } else if (path == '/for-std/exam-arrange/info/17') {
        if (mode == 'exam_no_body' || mode == 'exam_bad_row') {
          request.response.write(
            '''<!doctype html><table id="exams"><thead><tr>
<th>课程号</th><th>考试类型</th><th>课程名称</th><th>日期时间</th>
<th>考场</th><th>教学楼</th><th>考场所在校区</th><th>考试说明</th>
</tr></thead>${mode == 'exam_bad_row' ? '<tbody><tr><td>合成错误提示</td></tr></tbody>' : ''}</table>''',
          );
          await request.response.close();
          return;
        }
        request.response.write(
          '''<!doctype html><table id="exams"><thead><tr>
<th>课程号</th><th>考试类型</th><th>课程名称</th><th>日期时间</th>
<th>考场</th><th>教学楼</th><th>考场所在校区</th><th>考试说明</th>
</tr></thead><tbody>${mode == 'empty' || mode == 'observed_shape' ? '' : '<tr><td>SYN001</td><td>期末</td><td>合成课程</td><td>2026-10-20 09:00~11:00</td><td>合成考场</td><td>合成楼</td><td>合成校区</td><td></td></tr>'}
</tbody></table>${mode == 'pagination' ? '<nav class="pagination"><a href="?page=2">2</a></nav>' : ''}''',
        );
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    } on Object {
      // Synthetic aborted connections are expected during cancellation/drain.
      request.response.done.catchError((Object _) {});
    }
  }

  Future<void> close() async {
    _closing = true;
    if (!releaseIdentity.isCompleted) releaseIdentity.complete();
    await _server.close(force: true);
    await _denied.close(force: true);
  }
}
