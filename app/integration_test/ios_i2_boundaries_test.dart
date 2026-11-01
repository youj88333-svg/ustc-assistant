// I2 native WebKit boundary contract: docs/milestones/ios-private/plan.md,
// docs/architecture/07-12, docs/quality/13, and docs/workflow.md. This suite
// uses only a fresh loopback page and disposable demo browser profiles.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/platform/ios_runtime_platform_factory.dart';
import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';
import 'package:ustc_assistant_m0/platform/observation_assets.dart';
import 'package:ustc_assistant_m0/platform/owned_directory.dart';
import 'package:ustc_assistant_m0/platform/runtime_platform_factory.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';

import 'support/ios_i2_drain.dart';
import 'support/ios_i2_http.dart';

const _nativeTimeout = Duration(seconds: 25);
const _operationTimeout = Duration(seconds: 35);
const _platformChannel = MethodChannel('ustc_assistant/platform_v1');
const _observationChannel = MethodChannel('ustc_assistant/observation_v1');
var _nextSession = 12000;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'iOS I2 native WebKit navigation and profile recovery boundaries',
    (tester) async {
      expect(kDebugMode, isTrue, reason: 'I2 fixture actions are Debug only');
      expect(Platform.isIOS, isTrue, reason: 'I2 suite requires iOS');
      final status = await _platformChannel
          .invokeMapMethod<String, Object?>('storageProtectionStatus')
          .timeout(_nativeTimeout);
      expect(
        status?['isSimulator'],
        isTrue,
        reason: 'I2 automatic checks must run on an iOS Simulator',
      );

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.expand())),
      );
      await tester.runAsync(_runWithLoopbackAndDenyProxy);
    },
    skip: !Platform.isIOS,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Future<void> _runWithLoopbackAndDenyProxy() async {
  final fixture = await _LoopbackFixture.start();
  final denyProxy = await _DenyProxy.start();
  try {
    await HttpOverrides.runWithHttpOverrides(() async {
      await _verifyDartHttpFence(fixture, denyProxy);
      await _runBoundarySuite(fixture);
      expect(denyProxy.requestCount, 1);
      expect(fixture.paths, isNot(contains('/i2-denied')));
      expect(
        fixture.paths.every(
          (path) =>
              path == '/i2-start' ||
              path == '/i2-redirect' ||
              path == '/i2-attachment',
        ),
        isTrue,
      );
    }, IOSI2LoopbackHttpOverrides(denyProxyPort: denyProxy.port));
  } finally {
    await fixture.close();
    await denyProxy.close();
  }
}

Future<void> _verifyDartHttpFence(
  _LoopbackFixture fixture,
  _DenyProxy proxy,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final localRequest = await client
        .getUrl(fixture.uri('/i2-start'))
        .timeout(_nativeTimeout);
    final localResponse = await localRequest.close().timeout(_nativeTimeout);
    expect(localResponse.statusCode, HttpStatus.ok);
    await localResponse.drain<void>();

    final outsideRequest = await client
        .getUrl(Uri.parse('http://example.invalid/i2-blocked'))
        .timeout(_nativeTimeout);
    final outsideResponse = await outsideRequest.close().timeout(
      _nativeTimeout,
    );
    expect(outsideResponse.statusCode, HttpStatus.badGateway);
    await outsideResponse.drain<void>();
    expect(proxy.requestCount, 1);
  } finally {
    client.close(force: true);
  }
}

Future<void> _runBoundarySuite(_LoopbackFixture fixture) async {
  final platform = IOSRuntimePlatformFactory();
  RuntimeDirectories? directories;
  ObservationAssets? assets;
  NativeObservationBrowser? browser;
  var primaryFailure = false;
  try {
    directories = await platform.acquireDirectories().timeout(
      _operationTimeout,
    );
    assets = ObservationAssets(directories.demo);
    final activeBrowser = platform.createBrowser();
    browser = activeBrowser;
    await activeBrowser.ensureAvailable().timeout(_nativeTimeout);

    final startTarget = ObservationTarget.fixture(fixture.uri('/i2-start'));
    final redirectTarget = ObservationTarget.fixture(
      fixture.uri('/i2-redirect'),
    );
    await assets.recoverPending((profilePath) async {
      final session = _session();
      try {
        await activeBrowser.open(
          session: session,
          profilePath: profilePath,
          target: startTarget,
          recoveryOnly: true,
        );
      } finally {
        await closeAndDrainI2(activeBrowser, session, timeout: _nativeTimeout);
      }
    });

    debugPrint('I2 boundary phase: rejected open and recovery');
    await _unsafeOpenAndRecovery(
      directories.demo,
      assets,
      activeBrowser,
      redirectTarget,
      fixture,
    );

    const boundaries = <String, BrowserDiagnosticCode>{
      'topDenied': BrowserDiagnosticCode.topNavigationBlocked,
      'frameDenied': BrowserDiagnosticCode.frameNavigationBlocked,
      'popup': BrowserDiagnosticCode.popupBlocked,
      'external': BrowserDiagnosticCode.externalProtocolBlocked,
      'download': BrowserDiagnosticCode.downloadBlocked,
    };
    for (final entry in boundaries.entries) {
      debugPrint('I2 boundary phase: ${entry.key}');
      await _exerciseBoundary(
        assets,
        activeBrowser,
        fixture,
        entry.key,
        entry.value,
      );
    }
  } catch (_) {
    primaryFailure = true;
    rethrow;
  } finally {
    await _cleanupAll(primaryFailure, {
      'asset-registry': () async {
        if (assets != null) await assets.close();
      },
      'browser': () async {
        if (browser != null) await browser.dispose();
      },
      'formal-owner': () async {
        if (directories != null) await directories.formal.release();
      },
      'demo-owner': () async {
        if (directories != null) await directories.demo.release();
      },
    });
  }
}

Future<void> _unsafeOpenAndRecovery(
  OwnedDirectory demo,
  ObservationAssets assets,
  NativeObservationBrowser browser,
  ObservationTarget target,
  _LoopbackFixture fixture,
) async {
  final validProfile = await assets.register().timeout(_nativeTimeout);
  final badSession = _session();
  var badOpenAttempted = false;
  var badDrained = false;
  var validSession = 0;
  var validOpenAttempted = false;
  var validDrained = false;
  var primaryFailure = false;
  try {
    var missingProfile = '';
    for (var candidate = 0; candidate < 100; candidate++) {
      final missingId = 'obs-${candidate.toRadixString(16).padLeft(32, '0')}';
      final path = p.posix.join(demo.path, 'observation_v1', missingId);
      if (!await Directory(path).exists()) {
        missingProfile = path;
        break;
      }
    }
    if (missingProfile.isEmpty) throw StateError('missing_profile_unavailable');
    expect(p.posix.isWithin(demo.path, missingProfile), isTrue);

    // Keep this raw open to prove the native method contract is exactly eight
    // fields, including when the rejected path is already ledger-shaped.
    final openArguments = <String, Object>{
      'session': badSession,
      'profilePath': missingProfile,
      'initialUrl': target.initialUri.toString(),
      'source': target.source.name,
      'allowedOrigins': target.allowedOrigins,
      'testMode': target.isFixture,
      'recoveryOnly': false,
      'background': false,
    };
    expect(openArguments.keys.toSet(), <String>{
      'session',
      'profilePath',
      'initialUrl',
      'source',
      'allowedOrigins',
      'testMode',
      'recoveryOnly',
      'background',
    });
    badOpenAttempted = true;
    await expectLater(
      _observationChannel.invokeMethod<void>('open', openArguments),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.details,
          'details',
          FailureCode.unsafeDirectory.name,
        ),
      ),
    );
    await _observationChannel
        .invokeMethod<void>('close', {'session': badSession})
        .timeout(_nativeTimeout);
    badDrained =
        await _observationChannel
            .invokeMethod<bool>('drained', {'session': badSession})
            .timeout(_nativeTimeout) ??
        false;
    expect(badDrained, isTrue);

    validSession = _session();
    validOpenAttempted = true;
    final ready = await _openReady(
      browser,
      session: validSession,
      profilePath: validProfile,
      target: target,
    );
    expect(fixture.paths, contains('/i2-redirect'));
    expect(fixture.paths, contains('/i2-start'));
    final inspection = await browser.inspect(
      session: ready.session,
      document: ready.document,
    );
    expect(inspection.ready, isTrue);
    expect(inspection.origin, target.allowedOrigins.single);

    // A nonce or loopback URL does not authorize a fixed operation belonging
    // to the other source. Ask native directly to exercise its source guard.
    await expectLater(
      _observationChannel.invokeMethod<void>('navigateYoungBusinessPage', {
        'session': ready.session,
        'document': ready.document,
        'page': 'activities',
      }),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.details,
          'details',
          FailureCode.invalidSnapshot.name,
        ),
      ),
    );
    expect(
      (await browser.inspect(
        session: ready.session,
        document: ready.document,
      )).ready,
      isTrue,
    );
    await closeAndDrainI2(browser, validSession, timeout: _nativeTimeout);
    validDrained = true;
  } catch (_) {
    primaryFailure = true;
    rethrow;
  } finally {
    await _cleanupAll(primaryFailure, {
      'open-recovery': () async {
        if (badOpenAttempted && !badDrained) {
          await _observationChannel
              .invokeMethod<void>('close', {'session': badSession})
              .timeout(_nativeTimeout);
          badDrained =
              await _observationChannel
                  .invokeMethod<bool>('drained', {'session': badSession})
                  .timeout(_nativeTimeout) ??
              false;
          expect(badDrained, isTrue);
        }
        if (validOpenAttempted) {
          if (!validDrained) {
            final session = validSession;
            await closeAndDrainI2(browser, session, timeout: _nativeTimeout);
            validDrained = true;
          }
        }
        if ((!badOpenAttempted || badDrained) &&
            (!validOpenAttempted || validDrained)) {
          await assets.cleanup().timeout(_nativeTimeout);
        }
      },
    });
  }
}

Future<void> _exerciseBoundary(
  ObservationAssets assets,
  NativeObservationBrowser browser,
  _LoopbackFixture fixture,
  String action,
  BrowserDiagnosticCode expectedCode,
) async {
  final profilePath = await assets.register().timeout(_nativeTimeout);
  final session = _session();
  var closeConfirmed = false;
  var primaryFailure = false;
  try {
    final ready = await _openReady(
      browser,
      session: session,
      profilePath: profilePath,
      target: ObservationTarget.fixture(fixture.uri('/i2-start')),
    );
    final diagnostic = browser.events.firstWhere(
      (event) =>
          event.session == session &&
          event.kind == BrowserEventKind.diagnostic &&
          event.diagnostic?.code == expectedCode,
    );
    final invalidated = (action == 'topDenied' || action == 'external')
        ? browser.events.firstWhere(
            (event) =>
                event.session == session &&
                event.kind == BrowserEventKind.navigating &&
                event.document > ready.document,
          )
        : null;

    await browser
        .exerciseFixture(
          session: session,
          document: ready.document,
          action: action,
        )
        .timeout(_nativeTimeout);
    final blocked = await diagnostic.timeout(_nativeTimeout);
    expect(blocked.diagnostic!.site, BrowserDiagnosticSite.fixture);
    expect(
      blocked.diagnostic!.scheme,
      action == 'external'
          ? BrowserDiagnosticScheme.other
          : BrowserDiagnosticScheme.http,
    );

    if (invalidated != null) {
      final nextDocument = await invalidated.timeout(_nativeTimeout);
      expect(nextDocument.document, greaterThan(ready.document));
      await expectLater(
        browser.inspect(session: session, document: ready.document),
        throwsA(
          isA<AppFailure>().having(
            (error) => error.code,
            'code',
            FailureCode.staleResult,
          ),
        ),
      );
      expect(
        (await browser.inspect(
          session: session,
          document: nextDocument.document,
        )).ready,
        isFalse,
      );
    } else if (action == 'frameDenied' || action == 'popup') {
      final current = await browser.inspect(
        session: session,
        document: ready.document,
      );
      expect(current.ready, isTrue);
    }

    if (action == 'download') {
      expect(fixture.paths, contains('/i2-attachment'));
    }
    expect(fixture.paths, isNot(contains('/i2-denied')));
  } catch (_) {
    primaryFailure = true;
    rethrow;
  } finally {
    await _cleanupAll(primaryFailure, {
      'native-session': () async {
        await closeAndDrainI2(browser, session, timeout: _nativeTimeout);
        closeConfirmed = true;
      },
      'profile': () async {
        if (closeConfirmed) await assets.cleanup().timeout(_nativeTimeout);
      },
    });
  }
}

Future<void> _cleanupAll(
  bool primaryFailure,
  Map<String, Future<void> Function()> actions,
) async {
  Object? firstError;
  StackTrace? firstStack;
  for (final action in actions.entries) {
    try {
      await action.value();
    } catch (error, stack) {
      firstError ??= error;
      firstStack ??= stack;
      debugPrint('I2 boundary cleanup incomplete: ${action.key}');
    }
  }
  if (!primaryFailure && firstError != null) {
    Error.throwWithStackTrace(firstError, firstStack!);
  }
}

Future<BrowserEvent> _openReady(
  NativeObservationBrowser browser, {
  required int session,
  required String profilePath,
  required ObservationTarget target,
}) async {
  final ready = browser.events.firstWhere(
    (event) => event.session == session && event.kind == BrowserEventKind.ready,
  );
  await browser
      .open(session: session, profilePath: profilePath, target: target)
      .timeout(_nativeTimeout);
  return ready.timeout(_operationTimeout);
}

int _session() => _nextSession++;

final class _LoopbackFixture {
  _LoopbackFixture(this.server) {
    server.listen((request) => unawaited(_serve(request)));
  }

  final HttpServer server;
  final List<String> paths = <String>[];

  static Future<_LoopbackFixture> start() async =>
      _LoopbackFixture(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Uri uri(String path) =>
      Uri(scheme: 'http', host: '127.0.0.1', port: server.port, path: path);

  Future<void> _serve(HttpRequest request) async {
    final path = request.uri.path;
    paths.add(path);
    final response = request.response..persistentConnection = false;
    switch (path) {
      case '/i2-start':
        response.statusCode = HttpStatus.ok;
        response.headers.contentType = ContentType.html;
        response.write(
          '<!doctype html><meta charset="utf-8">'
          '<title>I2 synthetic loopback</title><main>fixture-ready</main>',
        );
        break;
      case '/i2-redirect':
        response.statusCode = HttpStatus.found;
        response.headers.set(
          HttpHeaders.locationHeader,
          uri('/i2-start').toString(),
        );
        break;
      case '/i2-attachment':
        response.statusCode = HttpStatus.ok;
        response.headers.contentType = ContentType(
          'application',
          'octet-stream',
        );
        response.headers.set(
          'Content-Disposition',
          'attachment; filename="i2-synthetic.bin"',
        );
        response.add(const <int>[0x49, 0x32, 0x00, 0x01]);
        break;
      default:
        response.statusCode = HttpStatus.notFound;
        response.write('not-found');
        break;
    }
    await response.close();
  }

  Future<void> close() => server.close(force: true);
}

final class _DenyProxy {
  _DenyProxy(this.server) {
    server.listen((request) => unawaited(_deny(request)));
  }

  final HttpServer server;
  var requestCount = 0;

  static Future<_DenyProxy> start() async =>
      _DenyProxy(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  int get port => server.port;

  Future<void> _deny(HttpRequest request) async {
    requestCount++;
    final response = request.response..persistentConnection = false;
    response.statusCode = HttpStatus.badGateway;
    response.write('blocked-by-loopback-proxy');
    await response.close();
  }

  Future<void> close() => server.close(force: true);
}
