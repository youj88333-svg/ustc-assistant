import 'dart:convert';
import 'dart:io';

enum JwAuthenticationFixtureMode {
  normal,
  portal,
  deferred,
  publicShape,
  publicShapeDeferred,
  publicShapeChallenge,
  publicShapeActivePasskey,
  publicShapeVisibleDuplicate,
  publicShapeUnknownInput,
  publicShapePasskeyOnUsername,
  publicShapeRevealMirrorOnUsername,
  wrongOrigin,
  wrongPath,
  multipleForms,
  hiddenPassword,
  disabledSubmit,
  challenge,
  ambiguousSubmit,
  replaceOnUsername,
  hideOnUsername,
  routeOnUsername,
  sameUrlOnUsername,
}

/// Fresh loopback pages with synthetic credentials only. Request bodies,
/// headers, URLs and browser assets are never retained or printed. The test
/// observes closed counters and boolean matches for this fixture's own data.
final class JwAuthenticationFixture {
  JwAuthenticationFixture._(this.mode, this._primary, this._relay) {
    _primary.listen((request) => _accept(request, primary: true));
    _relay.listen((request) => _accept(request, primary: false));
  }

  static const syntheticUsername = 'JW_NATIVE_SYNTHETIC_01';
  static const syntheticPassword = 'fixture-only-中-\\"-42';
  final JwAuthenticationFixtureMode mode;
  final HttpServer _primary;
  final HttpServer _relay;
  bool _closing = false;

  int submitCount = 0;
  int unexpectedOriginSubmitCount = 0;
  int passwordEventCount = 0;
  int buttonClickCount = 0;
  int businessPageCount = 0;
  int redirectCount = 0;
  bool credentialsMatched = false;
  bool passwordEventMatched = false;
  bool auxiliaryPasswordChanged = false;

  static Future<JwAuthenticationFixture> start(
    JwAuthenticationFixtureMode mode,
  ) async {
    final primary = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final relay = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      return JwAuthenticationFixture._(mode, primary, relay);
    } catch (_) {
      await primary.close(force: true);
      rethrow;
    }
  }

  Uri get origin => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: _primary.port,
  );
  Uri get relayOrigin => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: _relay.port,
  );
  Uri get initialUri => origin.replace(
    path: switch (mode) {
      JwAuthenticationFixtureMode.portal ||
      JwAuthenticationFixtureMode.wrongOrigin => '/login',
      JwAuthenticationFixtureMode.wrongPath => '/cas/not-login',
      _ => '/cas/login',
    },
  );

  String _formMarkup() {
    if (_publicShape) return _publicFormMarkup();
    final passwordHidden = mode == JwAuthenticationFixtureMode.hiddenPassword;
    final disabled = mode == JwAuthenticationFixtureMode.disabledSubmit;
    return '''<form id="jw-auth-form" method="POST" action="${mode == JwAuthenticationFixtureMode.wrongPath ? '/cas/not-login' : '/cas/login'}">
<input id="username" name="username" type="text" autocomplete="off">
<input id="password" name="password" type="password" autocomplete="off" ${passwordHidden ? 'hidden' : ''}>
${mode == JwAuthenticationFixtureMode.challenge ? '<input id="captcha" name="captcha" type="text">' : ''}
<button id="submitBtn" class="login-button" type="submit" ${disabled ? 'disabled' : ''}>Synthetic sign in</button>
${mode == JwAuthenticationFixtureMode.ambiguousSubmit ? '<button class="login-button" type="submit">Second sign in</button>' : ''}
</form>
${mode == JwAuthenticationFixtureMode.multipleForms ? '<form><input name="username" type="text"><input type="password"><button class="login-button">Other form</button></form>' : ''}''';
  }

  bool get _publicShape => switch (mode) {
    JwAuthenticationFixtureMode.publicShape ||
    JwAuthenticationFixtureMode.publicShapeDeferred ||
    JwAuthenticationFixtureMode.publicShapeChallenge ||
    JwAuthenticationFixtureMode.publicShapeActivePasskey ||
    JwAuthenticationFixtureMode.publicShapeVisibleDuplicate ||
    JwAuthenticationFixtureMode.publicShapeUnknownInput ||
    JwAuthenticationFixtureMode.publicShapePasskeyOnUsername ||
    JwAuthenticationFixtureMode.publicShapeRevealMirrorOnUsername => true,
    _ => false,
  };

  String _publicFormMarkup() =>
      '''<app-root>
<form id="autoLoginForm" method="POST" action="/cas/login">
<input name="username" type="hidden"><input name="password" type="hidden">
</form>
<button id="passkey-method" type="button" role="tab" aria-selected="${mode == JwAuthenticationFixtureMode.publicShapeActivePasskey}">Synthetic passkey method</button>
<form id="normalLoginForm" method="POST" action="/cas/login" autocomplete="off">
<input id="nameInput" name="username" type="text" autocomplete="username">
<input id="jw-hidden-name-mirror" name="username" type="text" style="display:none">
<rg-input-password><input name="password" type="password" autocomplete="current-password"></rg-input-password>
<input name="captcha_code" type="hidden">
${mode == JwAuthenticationFixtureMode.publicShapeChallenge ? '<input name="captcha_code" type="text"><img class="captcha-image" alt="Synthetic challenge" src="data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 width=%2290%22 height=%2240%22/%3E">' : ''}
${mode == JwAuthenticationFixtureMode.publicShapeUnknownInput ? '<input name="unclassified" type="text">' : ''}
<button id="submitBtn" class="login-button" type="submit">Synthetic sign in</button>
</form>
${mode == JwAuthenticationFixtureMode.publicShapeVisibleDuplicate ? '<form><input name="username" type="text"><input type="password"><button class="login-button">Second visible password form</button></form>' : ''}
</app-root>''';

  String _formPage() {
    final markup = _formMarkup();
    final deferred =
        mode == JwAuthenticationFixtureMode.deferred ||
        mode == JwAuthenticationFixtureMode.publicShapeDeferred;
    return '''<!doctype html><html><head><meta charset="utf-8"><title>Synthetic CAS form</title></head>
<body><h1>Synthetic CAS fixture</h1><div id="jw-form-container">${deferred ? '<app-root></app-root>' : markup}</div>
<button id="jw-fixture-jwRefresh">Refresh document</button>
<button id="jw-fixture-jwRouteChange">Change route</button>
<button id="jw-fixture-jwSameUrlHistory">Same URL history</button>
<button id="jw-fixture-jwCrossOrigin">Other origin</button>
<button id="jw-fixture-jwReplacePassword">Replace field</button>
<button id="jw-fixture-jwHidePassword">Hide field</button>
<button id="jw-fixture-jwManualContinue">Synthetic manual continuation</button>
<button id="jw-fixture-jwRenderForm">Render form</button>
<script>
'use strict';
const nativeValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
const mode = ${jsonEncode(mode.name)};
function notice(path) { fetch(path).catch(() => {}); }
function installForm() {
  const form = document.querySelector('#jw-auth-form, #normalLoginForm');
  if (!form) return;
  const name = form.querySelector('input[name="username"]');
  const password = form.querySelector('input[type="password"]');
  const button = form.querySelector('#submitBtn');
  name.addEventListener('input', () => {
    if (mode === 'replaceOnUsername') password.replaceWith(password.cloneNode());
    if (mode === 'hideOnUsername') password.hidden = true;
    if (mode === 'routeOnUsername') history.pushState({}, '', '/cas/challenge');
    if (mode === 'sameUrlOnUsername') history.pushState({}, '', location.href);
    if (mode === 'publicShapePasskeyOnUsername') document.querySelector('#passkey-method').setAttribute('aria-selected', 'true');
    // Model the template's hidden username mirror without dispatching its
    // handlers. No hidden auxiliary password is written by this fixture.
    const mirror = form.querySelector('#jw-hidden-name-mirror');
    if (mirror) nativeValue.set.call(mirror, nativeValue.get.call(name));
    if (mode === 'publicShapeRevealMirrorOnUsername') mirror.style.display = 'block';
  }, {once: true});
  password.addEventListener('input', () => {
    const matched = nativeValue.get.call(password) === ${jsonEncode(syntheticPassword)};
    notice('/password-notice?matched=' + (matched ? '1' : '0'));
  });
  button.addEventListener('click', () => {
    const auxiliary = document.querySelector('#autoLoginForm input[name="password"]');
    const changed = auxiliary && nativeValue.get.call(auxiliary) !== '';
    notice('/button-notice?auxiliaryChanged=' + (changed ? '1' : '0'));
  });
  let defaultAllowed = false;
  form.addEventListener('submit', event => {
    if (defaultAllowed) return;
    event.preventDefault();
    // Keep the original school-style DOM handler. The delayed native form
    // submission leaves time to observe the one-shot RPC result separately.
    setTimeout(() => { defaultAllowed = true; form.requestSubmit(button); }, 300);
  });
}
installForm();
document.querySelector('#jw-fixture-jwRefresh').onclick = () => location.reload();
document.querySelector('#jw-fixture-jwRouteChange').onclick = () => history.pushState({}, '', '/cas/challenge');
document.querySelector('#jw-fixture-jwSameUrlHistory').onclick = () => history.pushState({}, '', location.href);
document.querySelector('#jw-fixture-jwCrossOrigin').onclick = () => { location.href = ${jsonEncode('${relayOrigin.origin}/cas/login')}; };
document.querySelector('#jw-fixture-jwReplacePassword').onclick = () => {
  const field = document.querySelector('input[type="password"]'); field.replaceWith(field.cloneNode());
};
document.querySelector('#jw-fixture-jwHidePassword').onclick = () => { document.querySelector('input[type="password"]').hidden = true; };
document.querySelector('#jw-fixture-jwManualContinue').onclick = () => { location.href = '/home'; };
document.querySelector('#jw-fixture-jwRenderForm').onclick = () => {
  document.querySelector('#jw-form-container').innerHTML = ${jsonEncode(markup)}; installForm();
};
</script></body></html>''';
  }

  Future<void> _accept(HttpRequest request, {required bool primary}) async {
    try {
      if (_closing) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
      } else if (request.uri.path == '/password-notice') {
        passwordEventCount++;
        passwordEventMatched =
            passwordEventMatched ||
            request.uri.queryParameters['matched'] == '1';
        request.response.statusCode = HttpStatus.noContent;
      } else if (request.uri.path == '/button-notice') {
        buttonClickCount++;
        auxiliaryPasswordChanged =
            auxiliaryPasswordChanged ||
            request.uri.queryParameters['auxiliaryChanged'] == '1';
        request.response.statusCode = HttpStatus.noContent;
      } else if (request.method == 'POST' &&
          (request.uri.path == '/cas/login' ||
              request.uri.path == '/cas/not-login')) {
        submitCount++;
        if (!primary) unexpectedOriginSubmitCount++;
        final body = await utf8.decoder.bind(request).join();
        final fields = Uri.splitQueryString(body);
        credentialsMatched =
            fields['username'] == syntheticUsername &&
            fields['password'] == syntheticPassword;
        request.response.statusCode = HttpStatus.seeOther;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          '${relayOrigin.origin}/passport/login',
        );
      } else if (request.uri.path == '/passport/login') {
        redirectCount++;
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          '${origin.origin}/cas/gateway',
        );
      } else if (request.uri.path == '/cas/gateway') {
        redirectCount++;
        request.response.statusCode = HttpStatus.temporaryRedirect;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          '${relayOrigin.origin}/gateway/verify',
        );
      } else if (request.uri.path == '/gateway/verify') {
        redirectCount++;
        request.response.statusCode = HttpStatus.seeOther;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          '${origin.origin}/home',
        );
      } else if (request.uri.path == '/login') {
        request.response.headers.contentType = ContentType.html;
        final destination = mode == JwAuthenticationFixtureMode.wrongOrigin
            ? '${relayOrigin.origin}/cas/login'
            : '${origin.origin}/cas/login';
        request.response.write(
          '''<!doctype html><html><head><meta charset="utf-8"></head><body>
<h1>Synthetic JW portal</h1><a id="login-unified-wrapper" href="$destination">Unified sign in</a></body></html>''',
        );
      } else if (request.uri.path == '/cas/login' ||
          request.uri.path == '/cas/not-login' ||
          request.uri.path == '/cas/challenge') {
        request.response.headers.contentType = ContentType.html;
        request.response.write(_formPage());
      } else if (request.uri.path == '/home') {
        businessPageCount++;
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<!doctype html><html><body>Synthetic business page</body></html>',
        );
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    } on Object {
      // Synthetic navigation and cancellation may abort loopback connections.
      request.response.done.catchError((Object _) {});
    }
  }

  Future<void> close() async {
    _closing = true;
    await _primary.close(force: true);
    await _relay.close(force: true);
  }
}
