import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Loopback only, synthetic values. Never visits the school or reads a profile.
final class YoungReadOnlyFixture {
  YoungReadOnlyFixture._(this._server) {
    _server.listen(_serve);
  }
  final HttpServer _server;
  bool _closing = false;
  static const prefix = '/login/wisdom-group-learning-bg/';
  Uri get initialUri => Uri.parse('http://127.0.0.1:${_server.port}/login/');
  static Future<YoungReadOnlyFixture> start() async => YoungReadOnlyFixture._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
  );
  Future<void> close() async {
    _closing = true;
    await _server.close(force: true);
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    final path = request.uri.path;
    if (path == '/young-worker.js') {
      response.headers.contentType = ContentType('application', 'javascript');
      response.write('''
self.onmessage=()=>fetch('${prefix}personal/scCalendar/getPageUserList?case=worker');
''');
    } else if (path == '/young-sw.js') {
      response.headers.contentType = ContentType('application', 'javascript');
      response.headers.set('Service-Worker-Allowed', '/');
      response.write('''
self.addEventListener('install',e=>self.skipWaiting());
self.addEventListener('activate',e=>e.waitUntil(self.clients.claim()));
self.addEventListener('fetch',e=>{
  if(new URL(e.request.url).searchParams.get('case')==='serviceWorker')
    e.respondWith(new Response(JSON.stringify({success:true,code:200,
      result:{records:[],total:0}}),{headers:{'Content-Type':'application/json'}}));
});
''');
    } else if (path.startsWith(prefix)) {
      final mode = request.uri.queryParameters['case'];
      if (mode == 'late') {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (_closing) return;
      }
      if (mode == 'redirect' || mode == 'oversizedRedirect') {
        response.statusCode = HttpStatus.found;
        response.headers.set('Location', '$path?case=valid');
        if (mode == 'oversizedRedirect') {
          for (var index = 0; index < 290; ++index) {
            response.headers.set('X-Young-Fixture-$index', 'opaque');
          }
        }
      } else {
        response.headers.contentType = ContentType.json;
        response.headers.set(
          HttpHeaders.cacheControlHeader,
          mode == 'cache' ? 'public, max-age=600' : 'no-store',
        );
        response.headers.add(
          HttpHeaders.setCookieHeader,
          'young_fixture=SYNTHETIC_COOKIE_VALUE; Path=/; SameSite=Lax',
        );
        if (mode == 'malformed') {
          response.write('{"success":true,"result":[');
        } else if (mode == 'secret') {
          response.write(
            jsonEncode({
              'success': true,
              'result': {'accessToken': 'SYNTHETIC_BODY_SECRET'},
            }),
          );
        } else {
          final Object result;
          if (path == '${prefix}paramdesign/scMyInfo/info') {
            result = {
              'loginCode': 'SYNTHETIC_PRIVATE_ACCOUNT',
              'username': 'SYNTHETIC_PRIVATE_NAME',
            };
          } else {
            result = {
              'records': [
                {
                  'id': 'SYNTHETIC_PRIVATE_ID',
                  'title': 'SYNTHETIC_PRIVATE_TITLE',
                  'date': '2026-10-11',
                  'startTime': '2026-10-11 08:00:00',
                  'endTime': '2026-10-11 09:00:00',
                },
                if (path == '${prefix}personal/scCalendar/getPageUserList')
                  {
                    'id': 'SYNTHETIC_PRIVATE_ID_2',
                    'title': 'SYNTHETIC_PRIVATE_TITLE_2',
                    'date': '2026-10-12',
                    'startTime': '2026-10-12 08:00:00',
                    'endTime': '2026-10-12 09:00:00',
                  },
              ],
              'total': path == '${prefix}personal/scCalendar/getPageUserList'
                  ? 2
                  : 1,
            };
          }
          response.write(
            jsonEncode({'success': true, 'code': 200, 'result': result}),
          );
        }
      }
    } else {
      response.headers.contentType = ContentType.html;
      response.write(_page);
    }
    try {
      await response.close();
    } on HttpException {
      // A deliberately closed WebView may abandon a delayed synthetic reply.
    } on SocketException {
      // The browser group or the fixture server has closed the connection.
    }
  }

  static const _page =
      '''<!doctype html><html><body>
<h1>Synthetic Young readonly fixture</h1><table></table>
<script>
const paths={profile:'${prefix}paramdesign/scMyInfo/info',
schedule:'${prefix}personal/scCalendar/getPageUserList',
activities:'${prefix}mobile/item/enrolmentList'};
const read=(kind,mode='valid',method='GET')=>fetch(paths[kind]+'?case='+mode,
 {method,headers:{'X-Access-Token':'SYNTHETIC_HEADER_SECRET'}}).then(r=>r.text()).catch(()=>{});
window.__youngFixture=async action=>{
 if(action==='youngReadProfile')return read('profile');
 if(action==='youngReadSchedule')return read('schedule');
 if(action==='youngReadActivities')return read('activities');
 if(action==='youngConcurrent')return Promise.all([read('schedule'),read('schedule','concurrent')]);
 if(action==='youngRedirect')return read('schedule','redirect');
 if(action==='youngOversizedRedirect')return read('schedule','oversizedRedirect');
 if(action==='youngWrongMethod')return read('schedule','valid','POST');
 if(action==='youngLate')return read('schedule','late');
 if(action==='youngMalformed')return read('schedule','malformed');
 if(action==='youngSecret')return read('schedule','secret');
 if(action==='youngCache'){await read('schedule','cache');return read('schedule','cache');}
 if(action==='youngFrame'){
   const frame=document.createElement('iframe');
   frame.srcdoc='<script>fetch('+JSON.stringify(paths.schedule+'?case=frame')+')<'+ '/script>';
   document.body.appendChild(frame);return;
 }
 if(action==='youngWorker'){
   const worker=new Worker('/young-worker.js');worker.postMessage('read');return;
 }
 if(action==='youngServiceWorker'){
   await navigator.serviceWorker.register('/young-sw.js',{scope:'/'});
   await navigator.serviceWorker.ready;
   if(!navigator.serviceWorker.controller)await new Promise(resolve=>
     navigator.serviceWorker.addEventListener('controllerchange',resolve,{once:true}));
   return read('schedule','serviceWorker');
 }
};
</script></body></html>''';
}
