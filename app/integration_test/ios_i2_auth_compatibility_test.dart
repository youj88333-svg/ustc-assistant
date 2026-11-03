// I2 manual browsing contract: 07/09/12, V-07, workflow15 and the approved
// ios-private plan. Fresh Simulator, three loopback origins, synthetic only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ustc_assistant_m0/platform/ios_runtime_platform_factory.dart';
import 'package:ustc_assistant_m0/platform/observation_assets.dart';
import 'package:ustc_assistant_m0/platform/runtime_platform_factory.dart';

import 'support/ios_i2_http.dart';

const _native = MethodChannel('ustc_assistant/observation_v1');
const _platform = MethodChannel('ustc_assistant/platform_v1');
const _timeout = Duration(seconds: 25);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'I2 manual navigation, dialogs, and value-free policy diagnostics',
    (tester) async {
      expect(kDebugMode, isTrue);
      final status = await _platform.invokeMapMethod<String, Object?>(
        'storageProtectionStatus',
      );
      expect(status?['isSimulator'], isTrue);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.expand())),
      );
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(
          () => _run(binding),
          IOSI2LoopbackHttpOverrides(),
        ),
      );
    },
    skip: !Platform.isIOS,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

Future<void> _run(IntegrationTestWidgetsFlutterBinding binding) async {
  RuntimeDirectories? directories;
  ObservationAssets? assets;
  _Sites? sites;
  final flow = _Flow();
  var primaryFailure = false;
  try {
    directories = await IOSRuntimePlatformFactory().acquireDirectories();
    assets = ObservationAssets(directories.demo);
    sites = await _Sites.start();
    final profile = await assets.register();
    await flow.open(profile, sites);

    debugPrint('I2 compatibility phase: navigation-only identity page');
    var before = flow.document;
    await flow.exercise('compatLink');
    await flow.readyAfter(before, origin: null);
    final inspection = await flow.call('inspect') as Map;
    expect(inspection['origin'], isNull);
    expect(inspection['ready'], isFalse);
    expect(inspection['windowVisible'], isTrue);
    expect(
      await flow.call('advanceJwLogin', {'operation': 1}),
      'manualRequired',
    );
    expect(await flow.exercise('authHistoryUnmodified'), isTrue);
    expect(sites.frameRequests, greaterThan(0));
    await expectLater(
      flow.call('readJwProbe', {'operation': 1}),
      throwsA(
        isA<PlatformException>().having((e) => e.details, 'failure', 'busy'),
      ),
    );
    final oldIdentityDocument = flow.document;

    debugPrint('I2 compatibility phase: policy rejection survives retry');
    before = flow.document;
    await flow.exercise('compatDeniedLink');
    await flow.waitKind('blocked', after: before);
    expect(sites.deniedRequests, 0);
    var diagnostics = await _diagnostics();
    expect(diagnostics['policyAction'], 'topNavigationBlocked');
    expect(diagnostics['policyTarget'], 'localFixture');
    expect(diagnostics['lastEvent'], 'policyBlocked');
    expect(diagnostics['policyReason'], 'fixtureOrigin');
    expect(diagnostics['policyScheme'], 'http');
    expect(diagnostics['policyMethod'], 'get');
    expect(diagnostics['policyURLForm'], 'absolute');
    expect(await flow.exercise('hasSyntheticRecovery'), isTrue);
    final rejectedDocument = flow.document;
    await flow.exercise('iosRetiredNavigationFinished');
    await flow.exercise('iosRetiredNavigationFailed');
    expect(flow.document, rejectedDocument);
    expect(await flow.exercise('hasSyntheticRecovery'), isTrue);
    expect((await _diagnostics())['lastEvent'], 'policyBlocked');
    expect((await _diagnostics())['errorDomain'], 'none');
    await flow.exercise('iosReturnToApp');
    expect(
      await flow.call('advanceJwLogin', {'operation': 1}),
      'manualRequired',
    );
    expect((await flow.call('inspect') as Map)['windowVisible'], isTrue);
    expect(await flow.exercise('hasSyntheticRecovery'), isTrue);
    await flow.toStart(sites.businessOrigin);
    diagnostics = await _diagnostics();
    expect(diagnostics['lastEvent'], 'ready');
    expect(diagnostics['policyAction'], 'topNavigationBlocked');
    expect(diagnostics['policyTarget'], 'localFixture');
    expect(
      sites.formPosts,
      0,
      reason: 'fixed GET retry must not replay a POST',
    );
    await expectLater(
      flow.call('inspect', {}, oldIdentityDocument),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.details,
          'failure',
          'staleResult',
        ),
      ),
    );

    debugPrint('I2 compatibility phase: GET blank link and POST rejection');
    before = flow.document;
    await flow.exercise('compatBlankLink');
    await flow.readyAfter(before, origin: null);
    expect((await flow.call('inspect') as Map)['ready'], isFalse);
    await flow.toStart(sites.businessOrigin);
    final priorEventCount = flow.events.length;
    await flow.exercise('compatPostBlank');
    await _until(
      () => flow.events
          .skip(priorEventCount)
          .any(
            (e) =>
                e['kind'] == 'diagnostic' &&
                (e['diagnostic'] as Map?)?['code'] == 'popupBlocked',
          ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(sites.formPosts, 0);
    expect((await _diagnostics())['policyAction'], 'popupBlocked');

    debugPrint('I2 compatibility phase: submit and return to fixed business');
    before = flow.document;
    await flow.exercise('compatLink');
    await flow.readyAfter(before, origin: null);
    before = flow.document;
    await flow.exercise('compatSubmit');
    await flow.readyAfter(before, origin: sites.businessOrigin);
    expect(sites.formPosts, 1);
    expect((await flow.call('inspect') as Map)['ready'], isTrue);
    expect(
      await flow.call('advanceJwLogin', {'operation': 2}),
      'businessReady',
    );
    await flow.toStart(sites.businessOrigin);
    expect(
      sites.formPosts,
      1,
      reason: 'retry after a POST must still be GET only',
    );

    debugPrint('I2 compatibility phase: insecure POST is never transferred');
    before = flow.document;
    await flow.exercise('compatTLSPost');
    await flow.waitKind('blocked', after: before);
    diagnostics = await _diagnostics();
    expect(diagnostics['policyReason'], 'insecureMethod');
    expect(diagnostics['policyMethod'], 'post');
    expect(sites.tlsProbe.tlsHandshakes, 0);
    expect(sites.tlsProbe.plaintextRequests, 0);
    expect(sites.tlsProbe.connections, 0);
    expect(
      await flow.call('advanceJwLogin', {'operation': 3}),
      'manualRequired',
    );
    await flow.toStart(sites.businessOrigin);

    debugPrint(
      'I2 compatibility phase: explicit retry revokes a queued upgrade',
    );
    await flow.exercise('holdSyntheticGET');
    await flow.exercise('compatTLSRedirect');
    await _untilAsync(() async {
      try {
        return await flow.exercise('hasPendingSyntheticGET') == true;
      } on PlatformException catch (error) {
        if (error.details == 'staleResult') return false;
        rethrow;
      }
    });
    expect(sites.tlsProbe.connections, 0);
    expect(sites.legacyFormPosts, 1);
    await flow.toStart(sites.businessOrigin);
    await flow.exercise('releaseSyntheticGET');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(sites.tlsProbe.connections, 0);
    expect(sites.legacyFormPosts, 1);
    expect(await flow.exercise('syntheticUpgradeCount'), 0);

    debugPrint(
      'I2 compatibility phase: POST redirect GET upgrades without TLS fallback',
    );
    final legacyBefore = sites.legacyFormPosts;
    before = flow.document;
    await flow.exercise('compatTLSRedirect');
    await _untilAsync(() async {
      final current = await _diagnostics();
      return flow.document > before &&
          current['lastEvent'] == 'navigationFailed';
    });
    expect(sites.legacyFormPosts, legacyBefore + 1);
    expect(sites.tlsProbe.tlsHandshakes, greaterThan(0));
    expect(sites.tlsProbe.plaintextRequests, 0);
    expect(await flow.exercise('syntheticUpgradeCount'), 1);
    expect(await flow.exercise('hasSyntheticRecovery'), isTrue);
    expect(
      await flow.call('advanceJwLogin', {'operation': 4}),
      'manualRequired',
    );
    diagnostics = await _diagnostics();
    expect({
      'provisionalNavigation',
      'navigation',
    }, contains(diagnostics['failureStage']));
    expect(diagnostics['errorDomain'], isNot('none'));
    await flow.toStart(sites.businessOrigin);
    expect(await flow.exercise('syntheticUpgradeCount'), 0);
    expect(
      sites.legacyFormPosts,
      legacyBefore + 1,
      reason: 'fixed retry cannot replay the original POST',
    );
    expect(sites.tlsProbe.plaintextRequests, 0);

    debugPrint('I2 compatibility phase: native confirm and alert');
    await flow.exercise('useLightAppearance');
    final confirm = flow.startDialog('compatConfirm');
    await flow.waitDialog(confirm);
    final light = await binding.takeScreenshot('i2-confirm-light');
    expect(light.length, greaterThan(1000));
    await File(
      directories.demo.checkedChildPath(
        'i2-confirm-light.png',
        directory: false,
      ),
    ).writeAsBytes(light, flush: true);
    expect(await flow.exercise('acceptSyntheticDialog'), isTrue);
    await confirm.finish();
    expect(await flow.exercise('checkConfirmationAccepted'), isTrue);

    await flow.exercise('useDarkAppearance');
    final alert = flow.startDialog('compatAlert');
    await flow.waitDialog(alert);
    final dark = await binding.takeScreenshot('i2-alert-dark');
    expect(dark.length, greaterThan(1000));
    await File(
      directories.demo.checkedChildPath('i2-alert-dark.png', directory: false),
    ).writeAsBytes(dark, flush: true);
    expect(await flow.exercise('dismissSyntheticAlert'), isTrue);
    await alert.finish();

    debugPrint(
      'I2 compatibility phase: cancel while native panel is presenting',
    );
    await flow.startDialog('compatConfirmCancelDuringPresentation').finish();
    expect(await flow.exercise('checkConfirmationRejected'), isTrue);

    debugPrint('I2 compatibility phase: pending confirm cancelled on return');
    final cancelledConfirm = flow.startDialog('compatConfirm');
    await flow.waitDialog(cancelledConfirm);
    await flow.exercise('iosReturnToApp');
    await cancelledConfirm.finish();
    expect(await flow.exercise('checkConfirmationRejected'), isTrue);
    expect((await flow.call('inspect') as Map)['windowVisible'], isFalse);
    final dialogStatus = await flow.exercise('syntheticDialogStatus') as Map;
    final trace = dialogStatus['trace'] as List;
    expect(trace.where((e) => e == 'presentCompleted').length, 4);
    expect(trace.where((e) => e == 'dismissCompleted').length, 4);
    expect(trace.where((e) => e == 'completionDelivered').length, 4);
    expect(trace, contains('dismissWaitingForPresentation'));
    expect(dialogStatus['pending'], isFalse);
    expect(dialogStatus['hiding'], isFalse);
    expect(await flow.exercise('showSyntheticWindow'), isTrue);
    await flow.close();
    await assets.cleanup();
    binding.reportData = <String, Object>{
      'navigationOnlyHasNoBusinessAuthority': true,
      'policyEvidenceSurvivesRetry': true,
      'retryDoesNotReplayPost': true,
      'safeGetBlankLinkWorks': true,
      'postBlankRejected': true,
      'authHistoryUnmodified': true,
      'nativeDialogsAndCancellation': true,
      'policyBlockReturnsToManualRecovery': true,
      'insecurePostNotTransferred': true,
      'redirectGetUpgradeNoPlaintextFallback': true,
      'queuedUpgradeRevokedByRetry': true,
      'retiredCallbacksCannotRestorePolicyBlockedPage': true,
    };
  } catch (_) {
    primaryFailure = true;
    rethrow;
  } finally {
    var clean = true;
    Future<void> attempt(String stage, Future<void> Function() action) async {
      try {
        await action().timeout(_timeout);
      } on Object {
        clean = false;
        debugPrint('I2 compatibility cleanup pending: $stage');
      }
    }

    await attempt('native', flow.close);
    if (assets != null) {
      await attempt('profiles', assets.cleanup);
      await attempt('registry', assets.close);
    }
    await flow.dispose();
    if (sites != null) await attempt('servers', sites.close);
    if (directories != null) {
      await attempt('formal-owner', directories.formal.release);
      await attempt('demo-owner', directories.demo.release);
    }
    if (!clean && !primaryFailure) {
      throw StateError('i2_auth_compatibility_cleanup_pending');
    }
  }
}

Future<Map<Object?, Object?>> _diagnostics() async {
  final result = await _platform.invokeMapMethod<Object?, Object?>(
    'i2BrowserDiagnostics',
  );
  expect(result?['kind'], 'ios-i2-browser-diagnostics-v3');
  expect(result?.length, 17);
  return result!;
}

final class _Flow {
  final events = <Map<Object?, Object?>>[];
  final int session = 22001;
  int document = 0;
  bool _attempted = false, _closed = false;

  Future<void> open(String profile, _Sites sites) async {
    _native.setMethodCallHandler((call) async {
      if (call.method != 'event' || call.arguments is! Map) return;
      final event = Map<Object?, Object?>.from(call.arguments as Map);
      if (event['session'] != session || event['document'] is! int) return;
      events.add(event);
      final next = event['document'] as int;
      if (next > document) document = next;
    });
    _attempted = true;
    await _native
        .invokeMethod<void>('open', {
          'session': session,
          'profilePath': profile,
          'initialUrl': sites.startUri.toString(),
          'source': 'jw',
          'allowedOrigins': [sites.businessOrigin],
          'testNavigationOrigins': [
            sites.identityOrigin,
            sites.tlsProbe.httpOrigin,
            sites.tlsProbe.httpsOrigin,
          ],
          'testTLSUpgradeOrigin': sites.tlsProbe.httpOrigin,
          'testMode': true,
          'recoveryOnly': false,
          'background': false,
        })
        .timeout(_timeout);
    await readyAfter(-1, origin: sites.businessOrigin);
  }

  Future<Object?> call(
    String method, [
    Map<String, Object?> extra = const {},
    int? oldDocument,
  ]) => _native
      .invokeMethod<Object?>(method, {
        'session': session,
        'document': oldDocument ?? document,
        ...extra,
      })
      .timeout(_timeout);

  Future<Object?> exercise(String action) =>
      call('exerciseFixture', {'action': action});

  _DialogRun startDialog(String action) {
    final run = _DialogRun();
    run.completed = exercise(action).then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        run.error = error;
        run.stack = stack;
      },
    );
    return run;
  }

  Future<void> waitDialog(_DialogRun run) async {
    try {
      await _untilAsync(() async {
        run.rethrowFailure();
        return await exercise('hasSyntheticDialog') == true;
      });
    } on Object {
      // Both native projections are closed, synthetic-only state. Never dump
      // a URL, page content, WebKit error text or authentication asset.
      debugPrint('I2 dialog diagnostic: ${await _diagnostics()}');
      debugPrint(
        'I2 dialog lifecycle: ${await exercise('syntheticDialogStatus')}',
      );
      rethrow;
    }
  }

  Future<void> readyAfter(int after, {required String? origin}) async {
    await _until(
      () => events.any(
        (event) =>
            event['kind'] == 'ready' &&
            (event['document'] as int) > after &&
            event['origin'] == origin,
      ),
    );
  }

  Future<void> waitKind(String kind, {required int after}) => _until(
    () => events.any(
      (event) => event['kind'] == kind && (event['document'] as int) > after,
    ),
  );

  Future<void> toStart(String origin) async {
    final prior = document;
    await _native.invokeMethod<void>('navigateInitial', {'session': session});
    await readyAfter(prior, origin: origin);
  }

  Future<void> close() async {
    if (!_attempted || _closed) return;
    await _native.invokeMethod<void>('close', {'session': session});
    await _untilAsync(
      () async =>
          await _native.invokeMethod<bool>('drained', {'session': session}) ==
          true,
    );
    _closed = true;
  }

  Future<void> dispose() async => _native.setMethodCallHandler(null);
}

final class _DialogRun {
  late Future<void> completed;
  Object? error;
  StackTrace? stack;

  void rethrowFailure() {
    if (error != null) Error.throwWithStackTrace(error!, stack!);
  }

  Future<void> finish() async {
    await completed;
    rethrowFailure();
  }
}

Future<void> _until(bool Function() condition) =>
    _untilAsync(() async => condition());

Future<void> _untilAsync(Future<bool> Function() condition) async {
  final watch = Stopwatch()..start();
  while (!await condition()) {
    if (watch.elapsed > _timeout) {
      throw StateError('i2_compatibility_wait_timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

final class _Sites {
  _Sites(this.business, this.identity, this.denied, this.tlsProbe);
  final HttpServer business, identity, denied;
  final _TLSHandshakeProbe tlsProbe;
  int formPosts = 0, frameRequests = 0, deniedRequests = 0;
  int legacyFormPosts = 0;
  String get businessOrigin => 'http://127.0.0.1:${business.port}';
  String get identityOrigin => 'http://127.0.0.1:${identity.port}';
  String get deniedOrigin => 'http://127.0.0.1:${denied.port}';
  Uri get startUri => Uri.parse('$businessOrigin/start');

  static Future<_Sites> start() async {
    final business = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final identity = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final denied = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final _TLSHandshakeProbe probe;
    try {
      probe = await _TLSHandshakeProbe.start();
    } on Object {
      await Future.wait([
        business.close(force: true),
        identity.close(force: true),
        denied.close(force: true),
      ]);
      rethrow;
    }
    final sites = _Sites(business, identity, denied, probe);
    business.listen((request) => unawaited(sites.serve(request, 'business')));
    identity.listen((request) => unawaited(sites.serve(request, 'identity')));
    denied.listen((request) => unawaited(sites.serve(request, 'denied')));
    return sites;
  }

  Future<void> serve(HttpRequest request, String site) async {
    try {
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      if (site == 'denied') {
        deniedRequests++;
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      final path = request.uri.path;
      if (site == 'business' &&
          path == '/legacy-submit' &&
          request.method == 'POST') {
        legacyFormPosts++;
        final body = await utf8.decoder.bind(request).join();
        if (body != 'token=synthetic') {
          request.response.statusCode = HttpStatus.badRequest;
        } else {
          request.response.statusCode = HttpStatus.seeOther;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            '${tlsProbe.httpOrigin}/synthetic-callback',
          );
        }
        await request.response.close();
        return;
      }
      if (site == 'identity' && path == '/submit' && request.method == 'POST') {
        formPosts++;
        final body = await utf8.decoder.bind(request).join();
        if (body != 'token=synthetic') {
          request.response.statusCode = HttpStatus.badRequest;
        } else {
          request.response.statusCode = HttpStatus.seeOther;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            '$businessOrigin/home',
          );
        }
        await request.response.close();
        return;
      }
      if (request.method != 'GET' || request.uri.hasQuery) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType.html;
      if (site == 'business' && path == '/start') {
        request.response.write('''<!doctype html><html><body>
<h1>Synthetic school entry</h1>
<a id="compat-link" href="$identityOrigin/identity">Continue</a>
<a id="compat-blank" target="_blank" href="$identityOrigin/identity">New window link</a>
<form id="compat-post-blank" method="post" target="_blank" action="$identityOrigin/submit">
<input name="token" value="synthetic"><button type="submit">Post</button></form>
<form id="compat-tls-post" method="post" action="${tlsProbe.httpOrigin}/synthetic-callback">
<input name="token" value="synthetic"><button type="submit">Insecure post</button></form>
<form id="compat-tls-redirect" method="post" action="$businessOrigin/legacy-submit">
<input name="token" value="synthetic"><button type="submit">Synthetic redirect</button></form>
<iframe src="$identityOrigin/frame"></iframe>
</body></html>''');
      } else if (site == 'business' && path == '/home') {
        request.response.write(
          '<!doctype html><html><body><h1>Synthetic business home</h1></body></html>',
        );
      } else if (site == 'identity' && path == '/identity') {
        request.response.write('''<!doctype html><html><body>
<h1>Synthetic identity page</h1>
<a id="compat-denied" href="$deniedOrigin/blocked">Blocked link</a>
<form id="compat-form" method="post" action="$identityOrigin/submit">
<input name="token" value="synthetic"><button type="submit">Continue</button></form>
</body></html>''');
      } else if (site == 'identity' && path == '/frame') {
        frameRequests++;
        request.response.write(
          '<!doctype html><html><body>Synthetic frame</body></html>',
        );
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    } on Object {
      request.response.done.catchError((Object _) {});
    }
  }

  Future<void> close() async {
    await Future.wait([
      business.close(force: true),
      identity.close(force: true),
      denied.close(force: true),
      tlsProbe.close(),
    ]);
  }
}

// Fresh loopback socket, not a trusted HTTPS service. Observe only the first
// record type, then close: TLS must fail normally and must never fall back to
// an HTTP request. No certificate exception or raw payload logging is used.
final class _TLSHandshakeProbe {
  _TLSHandshakeProbe(this.server) {
    subscription = server.listen((socket) {
      connections++;
      sockets.add(socket);
      var observed = false;
      socket.listen(
        (bytes) {
          if (observed || bytes.isEmpty) return;
          observed = true;
          if (bytes.first == 0x16) {
            tlsHandshakes++;
          } else {
            plaintextRequests++;
          }
          socket.destroy();
          sockets.remove(socket);
        },
        onError: (Object _) {
          socket.destroy();
          sockets.remove(socket);
        },
        onDone: () => sockets.remove(socket),
      );
    });
  }

  final ServerSocket server;
  late final StreamSubscription<Socket> subscription;
  final sockets = <Socket>{};
  int connections = 0, tlsHandshakes = 0, plaintextRequests = 0;
  String get httpOrigin => 'http://127.0.0.1:${server.port}';
  String get httpsOrigin => 'https://127.0.0.1:${server.port}';

  static Future<_TLSHandshakeProbe> start() async => _TLSHandshakeProbe(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
  );

  Future<void> close() async {
    for (final socket in sockets.toList()) {
      socket.destroy();
    }
    sockets.clear();
    await subscription.cancel();
    await server.close();
  }
}
