import 'dart:convert';
import 'dart:io';

/// Synthetic school contract served only on loopback. It has no authentication
/// asset access; its page helper retains the publicly verified GET signature.
final class YoungBusinessFixture {
  YoungBusinessFixture._(
    this.server, {
    required this.requireAuthentication,
    required this.realisticLoginRedirects,
    required this.homeHasReader,
    required this.delayBusinessReadiness,
    required this.businessReadinessDelay,
    required this.keepTargetRouteWhilePreparing,
    required this.cacheBustedRequests,
    required this.useXhr,
  });

  static const syntheticPassword = 'young-fixture-only-\\"-42';
  static const _youngNamespacePath = '/login/sc-wisdom-group-learning/';
  static const _youngActivitiesPath =
      '/login/sc-wisdom-group-learning/myproject/SignUp';
  static const _youngCalendarPath =
      '/login/sc-wisdom-group-learning/personalInformation/mySchedule';

  final HttpServer server;
  final bool requireAuthentication;
  final bool realisticLoginRedirects;
  final bool homeHasReader;
  final bool delayBusinessReadiness;
  final Duration businessReadinessDelay;
  final bool keepTargetRouteWhilePreparing;
  final bool cacheBustedRequests;
  final bool useXhr;
  String mode = 'good';
  String username = 'FIXTURE_ACCOUNT';
  int profiles = 0;
  int activityRequests = 0;
  int calendarRequests = 0;
  int authenticationPages = 0;
  int authenticationSubmissions = 0;
  int auxiliaryFieldObservations = 0;
  int auxiliaryFieldsPreservedObservations = 0;
  int unexpectedAuthenticationSubmissions = 0;
  int successfulAuthenticationSubmissions = 0;
  int prematureBusinessNavigations = 0;
  int prematureModuleEvaluations = 0;
  int bootstrapCompletions = 0;
  bool bootstrapQueryCleared = false;
  int frameRequests = 0;
  bool credentialsMatched = false;
  Uri get initialUri {
    final path = realisticLoginRedirects ? '/login/' : _youngCalendarPath;
    return Uri.parse('http://127.0.0.1:${server.port}$path');
  }

  Uri get authenticationUri =>
      Uri.parse('http://127.0.0.1:${server.port}/cas/login');

  static Future<YoungBusinessFixture> start({
    bool requireAuthentication = false,
    bool realisticLoginRedirects = false,
    bool homeHasReader = true,
    bool delayBusinessReadiness = false,
    Duration businessReadinessDelay = const Duration(milliseconds: 800),
    bool keepTargetRouteWhilePreparing = false,
    bool cacheBustedRequests = false,
    bool useXhr = false,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = YoungBusinessFixture._(
      server,
      requireAuthentication: requireAuthentication,
      realisticLoginRedirects: realisticLoginRedirects,
      homeHasReader: homeHasReader,
      delayBusinessReadiness: delayBusinessReadiness,
      businessReadinessDelay: businessReadinessDelay,
      keepTargetRouteWhilePreparing: keepTargetRouteWhilePreparing,
      cacheBustedRequests: cacheBustedRequests,
      useXhr: useXhr,
    );
    server.listen(fixture._serve);
    return fixture;
  }

  Future<void> close() => server.close(force: true);
  Future<void> _serve(HttpRequest request) async {
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    final path = request.uri.path;

    if (request.method == 'GET' && path == '/fixture-auth-fields') {
      ++auxiliaryFieldObservations;
      if (request.uri.queryParameters['auxiliaryUsernamePreserved'] == 'true' &&
          request.uri.queryParameters['auxiliaryPasswordPreserved'] == 'true' &&
          request.uri.queryParameters['mirrorUsernamePreserved'] == 'true') {
        ++auxiliaryFieldsPreservedObservations;
      }
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }
    if (request.method == 'POST' && path == '/cas/login') {
      await _acceptAuthentication(request);
      return;
    }
    if (request.method == 'POST') {
      ++unexpectedAuthenticationSubmissions;
      request.response.statusCode = HttpStatus.notFound;
    } else if (path == '/fixture/premature-module') {
      ++prematureModuleEvaluations;
      request.response.statusCode = HttpStatus.noContent;
    } else if (realisticLoginRedirects &&
        path == '/fixture/bootstrap-complete') {
      ++bootstrapCompletions;
      bootstrapQueryCleared =
          request.uri.queryParameters['queryCleared'] == 'true';
      request.response.statusCode = HttpStatus.noContent;
    } else if (realisticLoginRedirects && path == '/login/') {
      request.response.headers.contentType = ContentType.html;
      request.response.write(_loginPortalPage());
    } else if (realisticLoginRedirects && path == '/passport/login') {
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        authenticationUri.toString(),
      );
    } else if (path == '/cas/login') {
      ++authenticationPages;
      request.response.headers.contentType = ContentType.html;
      request.response.write(_authenticationPage());
    } else if (realisticLoginRedirects &&
        _isBusinessTarget(path) &&
        bootstrapCompletions == 0) {
      ++prematureBusinessNavigations;
      if (requireAuthentication && !_hasSyntheticSession(request)) {
        request.response.statusCode = HttpStatus.seeOther;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          authenticationUri.toString(),
        );
      } else {
        // A hard deep link before the portal callback finishes has no SPA
        // bootstrap helper, so fixed preparation must fail closed.
        request.response.statusCode = HttpStatus.conflict;
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<!doctype html><html><body>Portal bootstrap incomplete</body></html>',
        );
      }
    } else if (path.startsWith('/login/sc-wisdom-group-learning/') &&
        requireAuthentication &&
        !_hasSyntheticSession(request)) {
      request.response.statusCode = HttpStatus.seeOther;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        authenticationUri.toString(),
      );
    } else if (path.startsWith('/login/sc-wisdom-group-learning/')) {
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        realisticLoginRedirects && path == _youngNamespacePath
            ? _bootstrapPage()
            : _businessPage(path),
      );
    } else if (path.startsWith('/login/wisdom-group-learning-bg/')) {
      request.response.headers.contentType = ContentType.json;
      Object? result;
      if (path.endsWith('/paramdesign/scMyInfo/info')) {
        ++profiles;
        result = {
          'username':
              mode == 'accountMismatch' ||
                  (mode == 'identityChange' && profiles.isEven)
              ? 'OTHER_FIXTURE'
              : username,
          'unused': {'description': r'UNSELECTED_PRIVATE_\u0061'},
        };
      } else if (path.endsWith('/mobile/item/enrolmentList')) {
        if (!request.uri.queryParameters.containsKey('background')) {
          ++activityRequests;
        }
        final page =
            int.tryParse(request.uri.queryParameters['pageNo'] ?? '') ?? 0;
        final records = <Map<String, Object?>>[];
        for (var i = (page - 1) * 10; i >= 0 && i < page * 10 && i < 11; ++i) {
          records.add({
            'id': mode == 'duplicate' && i == 10 ? 'activity-0' : 'activity-$i',
            'itemName': 'Synthetic activity $i',
            'st': '2026-10-10 10:00:00',
            'et': '2026-10-10 11:00:00',
            'applySt': null,
            'applyEt': null,
            'placeInfo': 'Synthetic room',
          });
        }
        result = {
          'records': records,
          'total': mode == 'totalChange' && page == 2 ? 12 : 11,
          'current': 1,
          'pages': 2,
          'size': 10,
        };
      } else if (path.endsWith('/personal/scCalendar/getPageUserList')) {
        ++calendarRequests;
        if (mode == 'late') {
          await Future<void>.delayed(const Duration(seconds: 3));
        }
        final day = request.uri.queryParameters['now'];
        final nonempty =
            (day == '2026-10-10' && mode != 'emptyCalendar') ||
            mode == 'wrongDay';
        final records = nonempty
            ? [
                {
                  'id': 'calendar-linked',
                  'title': 'Synthetic linked event',
                  'place': 'Synthetic room',
                  'startTime': '2026-10-10 10:00:00',
                  'endTime': '2026-10-10 11:00:00',
                  'itemId': 'activity-0',
                },
                {
                  'id': 'calendar-unlinked',
                  'title': 'Synthetic unlinked event',
                  'place': '',
                  'startTime': '2026-10-10 12:00:00',
                  'endTime': '2026-10-10 13:00:00',
                  'itemId': '',
                },
              ]
            : <Map<String, Object?>>[];
        result = {'records': records, 'total': records.length, 'current': 1};
      }
      final response = <String, Object?>{
        'success': true,
        'code': 200,
        'result': result,
      };
      if (mode == 'secret') response['token'] = 'SECRET_SENTINEL';
      request.response.write(jsonEncode(response));
    } else if (path.startsWith('/frame')) {
      ++frameRequests;
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        '<!doctype html><html><body>Frame fixture</body></html>',
      );
    } else {
      request.response.statusCode = HttpStatus.notFound;
    }
    try {
      await request.response.close();
    } catch (_) {
      /* Client may close a cancelled job. */
    }
  }

  bool _hasSyntheticSession(HttpRequest request) => request.cookies.any(
    (cookie) =>
        cookie.name == 'young_fixture_session' && cookie.value == 'accepted',
  );

  bool _isBusinessTarget(String path) =>
      path == _youngActivitiesPath || path == _youngCalendarPath;

  String _loginPortalPage() =>
      '''<!doctype html><html><head><meta charset="utf-8"><title>Synthetic portal</title></head>
<body><script>setTimeout(()=>location.replace('/passport/login'),900);</script></body></html>''';

  String _bootstrapPage() =>
      '''<!doctype html><html><head><meta charset="utf-8"><title>Synthetic Young portal callback</title></head>
<body><script>
const namespace='$_youngNamespacePath';
const defaultChild=namespace+'portal/home';
function installHomeReader(){
  const r={b:${_businessGet()}};
  function l(e,t){return Object(r["b"])({url:e,method:"get",params:t,timeout:36e5})}
  ${_webpackRuntime()}
  installHelper();
}
setTimeout(async()=>{
  history.replaceState(null,'',namespace);
  ${homeHasReader ? 'installHomeReader();' : '// Reader module is lazy-loaded only by the target business page.'}
  await fetch('/fixture/bootstrap-complete?queryCleared='+String(location.search.length===0),{cache:'no-store'});
  history.pushState(null,'',defaultChild);
},900);
</script></body></html>''';

  String _authenticationPage() =>
      '''<!doctype html><html><head><meta charset="utf-8"><title>Synthetic CAS</title></head>
<body><form id="autoLoginForm" method="POST" action="/cas/login">
<input name="username" type="hidden" value="young-aux-user-sentinel">
<input name="password" type="hidden" value="young-aux-password-sentinel">
</form>
<button id="passkey-method" type="button" role="tab" aria-selected="false">Synthetic passkey method</button>
<form id="normalLoginForm" method="POST" action="/cas/login" autocomplete="off">
<input id="nameInput" name="username" type="text" autocomplete="username">
<input id="hidden-name-mirror" name="username" type="text" style="display:none" value="young-mirror-user-sentinel">
<input id="password" name="password" type="password" autocomplete="current-password">
<button id="submitBtn" class="login-button" type="submit">Synthetic sign in</button>
</form>
<script>
const loginForm=document.querySelector('#normalLoginForm');
let submittingAfterObservation=false;
loginForm.addEventListener('submit',function(event){
  if(submittingAfterObservation)return;
  event.preventDefault();
  submittingAfterObservation=true;
  const auxiliary=document.querySelector('#autoLoginForm');
  const mirror=document.querySelector('#hidden-name-mirror');
  const query=new URLSearchParams({
    auxiliaryUsernamePreserved:String(auxiliary.querySelector('[name="username"]').value==='young-aux-user-sentinel'),
    auxiliaryPasswordPreserved:String(auxiliary.querySelector('[name="password"]').value==='young-aux-password-sentinel'),
    mirrorUsernamePreserved:String(mirror.value==='young-mirror-user-sentinel')
  });
  fetch('/fixture-auth-fields?'+query.toString(),{cache:'no-store'})
    .then(()=>loginForm.submit(),()=>loginForm.submit());
});
</script></body></html>''';

  String _businessPage(String path) {
    final delay = delayBusinessReadiness
        ? businessReadinessDelay.inMilliseconds
        : 0;
    final routeAfterBody = mode == 'routeAfterBody';
    final expectedPath = jsonEncode(path);
    return '''<!doctype html><html><body><iframe id="fixture-frame" src="/frame"></iframe><table><tr><td>Fixture</td></tr></table><div class="ant-fullcalendar"></div><script>
      const r={b:${_businessGet()}};
      function l(e,t){return Object(r["b"])({url:e,method:"get",params:t,timeout:36e5})}
      window.__youngRouteAfterBody=$routeAfterBody;
      ${_webpackRuntime()}
      if($delay>0){if(!$keepTargetRouteWhilePreparing){history.replaceState(null,'','/login/sc-wisdom-group-learning/preparing');setTimeout(()=>history.replaceState(null,'',$expectedPath),Math.floor($delay/2));setTimeout(installHelper,$delay)}}else{installHelper()}
      // An unrelated frame also changes history near reader setup. The
      // precise Page/main-frame guard must distinguish it from the route test.
      if($delay>0)setTimeout(()=>{document.getElementById('fixture-frame').src='/frame?late=1'},$delay+600);
      // This earlier independent timer repeatedly fetches the same URL. It
      // never carries the native compiled action script in its initiator chain.
      setInterval(()=>fetch('/login/wisdom-group-learning-bg/mobile/item/enrolmentList?pageNo=1&pageSize=10&background=1'),150);
      </script></body></html>''';
  }

  // A framework-style async interceptor precedes the native request. XHR uses
  // readyState completion like Axios' browser adapter; returned helper objects
  // still cannot replace the reader's own native response projection.
  String _businessGet() =>
      '''function(options){
      return Promise.resolve().then(function(){
        const params=new URLSearchParams(options.params);
        ${cacheBustedRequests ? "params.set('_t','1792396800000');" : ''}
        const target='/login/wisdom-group-learning-bg'+options.url+(params.toString()?'?'+params.toString():'');
        ${useXhr ? '''return new Promise(function(resolve,reject){
          let request=new XMLHttpRequest();
          request.open('GET',target,true);
          request.onreadystatechange=function(){
            if(!request||request.readyState!==4)return;
            if(request.status===0)return;
            const status=request.status, text=request.responseText;
            request=null;
            if(status<200||status>299){reject(new Error('synthetic-http'));return;}
            try{resolve(JSON.parse(text));}catch(error){reject(error);}
          };
          request.onerror=function(){reject(new Error('synthetic-network'));request=null;};
          request.send(null);
        });''' : 'return fetch(target).then(function(response){return response.json();});'}
      }).then(function(value){
        if(window.__youngRouteAfterBody&&options.url==='/personal/scCalendar/getPageUserList')history.pushState(null,'',location.href);
        return value;
      });
      }''';

  // Model Webpack 4's initial module table, JSONP registration and cache. The
  // cache deliberately retains a failed require so premature evaluation is a
  // user-visible failure rather than being hidden by the fixture.
  String _webpackRuntime() =>
      '''
      const fixtureModules=Object.create(null), fixtureCache=Object.create(null);
      function fixtureRequire(id){
        if(fixtureCache[id])return fixtureCache[id].exports;
        const module=fixtureCache[id]={exports:{}};
        if(typeof fixtureModules[id]!=='function'){fetch('/fixture/premature-module');throw new Error('synthetic-module-not-yet-registered')}
        fixtureModules[id](module,module.exports,fixtureRequire);return module.exports;
      }
      fixtureRequire.m=fixtureModules;
      let fixtureReadinessTimer=false;
      window.webpackJsonp=[];
      window.webpackJsonp.push=function(data){
        Object.keys(data[1]).forEach(id=>fixtureModules[id]=data[1][id]);
        if(${keepTargetRouteWhilePreparing && delayBusinessReadiness}&&!fixtureReadinessTimer){fixtureReadinessTimer=true;setTimeout(installHelper,${businessReadinessDelay.inMilliseconds})}
        let value;for(const entry of (data[2]||[]))value=fixtureRequire(entry[0]);return value;
      };
      function installHelper(){fixtureModules['0fea']=function(module){Object.defineProperty(module.exports,'e',{enumerable:true,get:function(){return l}})};}
      ''';

  Future<void> _acceptAuthentication(HttpRequest request) async {
    ++authenticationSubmissions;
    final encoded = await utf8.decoder.bind(request).join();
    // The hidden username mirror is still an HTML successful control. Keep
    // both submitted values explicit instead of collapsing duplicate keys;
    // only the visible field may contain the synthetic account.
    final fields = Uri.parse('?$encoded').queryParametersAll;
    final names = fields['username'];
    final passwords = fields['password'];
    final matched =
        fields.length == 2 &&
        names != null &&
        names.length == 2 &&
        names[0] == username &&
        names[1] == 'young-mirror-user-sentinel' &&
        passwords != null &&
        passwords.length == 1 &&
        passwords.single == syntheticPassword;
    credentialsMatched = credentialsMatched || matched;
    if (matched) {
      ++successfulAuthenticationSubmissions;
      request.response.statusCode = HttpStatus.seeOther;
      request.response.headers.add(
        HttpHeaders.setCookieHeader,
        'young_fixture_session=accepted; Path=/; HttpOnly; SameSite=Strict',
      );
      request.response.headers.set(
        HttpHeaders.locationHeader,
        realisticLoginRedirects
            ? '$_youngNamespacePath?ticket=synthetic-callback'
            : initialUri.path,
      );
    } else {
      request.response.statusCode = HttpStatus.unauthorized;
    }
    try {
      await request.response.close();
    } catch (_) {
      /* A synthetic navigation may abort the loopback response. */
    }
  }
}
