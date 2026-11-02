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

    debugPrint('I2 compatibility phase: native confirm and alert');
    await flow.exercise('useLightAppearance');
    final confirm = flow.exercise('compatConfirm');
    await _untilAsync(
      () async => await flow.exercise('hasSyntheticDialog') == true,
    );
    final light = await binding.takeScreenshot('i2-confirm-light');
    expect(light.length, greaterThan(1000));
    await File(
      directories.demo.checkedChildPath(
        'i2-confirm-light.png',
        directory: false,
      ),
    ).writeAsBytes(light, flush: true);
    expect(await flow.exercise('acceptSyntheticDialog'), isTrue);
    await confirm;
    expect(await flow.exercise('checkConfirmationAccepted'), isTrue);

    await flow.exercise('useDarkAppearance');
    final alert = flow.exercise('compatAlert');
    await _untilAsync(
      () async => await flow.exercise('hasSyntheticDialog') == true,
    );
    final dark = await binding.takeScreenshot('i2-alert-dark');
    expect(dark.length, greaterThan(1000));
    await File(
      directories.demo.checkedChildPath('i2-alert-dark.png', directory: false),
    ).writeAsBytes(dark, flush: true);
    expect(await flow.exercise('dismissSyntheticAlert'), isTrue);
    await alert;

    debugPrint('I2 compatibility phase: pending confirm cancelled on return');
    final cancelledConfirm = flow.exercise('compatConfirm');
    await _untilAsync(
      () async => await flow.exercise('hasSyntheticDialog') == true,
    );
    await flow.exercise('iosReturnToApp');
    await cancelledConfirm;
    expect(await flow.exercise('checkConfirmationRejected'), isTrue);
    expect((await flow.call('inspect') as Map)['windowVisible'], isFalse);
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
  expect(result?['kind'], 'ios-i2-browser-diagnostics-v2');
  expect(result?.length, 13);
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
          'testNavigationOrigins': [sites.identityOrigin],
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
  _Sites(this.business, this.identity, this.denied);
  final HttpServer business, identity, denied;
  int formPosts = 0, frameRequests = 0, deniedRequests = 0;
  String get businessOrigin => 'http://127.0.0.1:${business.port}';
  String get identityOrigin => 'http://127.0.0.1:${identity.port}';
  String get deniedOrigin => 'http://127.0.0.1:${denied.port}';
  Uri get startUri => Uri.parse('$businessOrigin/start');

  static Future<_Sites> start() async {
    final business = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final identity = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final denied = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sites = _Sites(business, identity, denied);
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
    ]);
  }
}
