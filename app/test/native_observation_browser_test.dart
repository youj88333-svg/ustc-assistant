import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/jw_credentials.dart';
import 'package:ustc_assistant_m0/source/jw_authentication_contract.dart';
import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';
import 'package:ustc_assistant_m0/platform/runtime_platform_factory.dart';
import 'package:ustc_assistant_m0/source/jw_probe_contract.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';
import 'package:ustc_assistant_m0/source/young_observation_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const name = 'ustc_assistant/observation_v1';
  const channel = MethodChannel(name);
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late NativeObservationBrowser browser;
  late List<BrowserEvent> events;
  late StreamSubscription<BrowserEvent> subscription;

  setUp(() {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    browser = NativeObservationBrowser(channel: channel);
    events = [];
    subscription = browser.events.listen(events.add);
  });
  tearDown(() async {
    await subscription.cancel();
    await browser.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });
  Future<void> emit(Map<String, Object?> data) async {
    await messenger.handlePlatformMessage(
      name,
      codec.encodeMethodCall(MethodCall('event', data)),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> open() => browser.open(
    session: 7,
    profilePath: r'C:\synthetic-profile',
    target: ObservationTarget.jw(),
  );
  Matcher code(FailureCode value) =>
      throwsA(isA<AppFailure>().having((e) => e.code, 'code', value));

  test(
    'availability preflight uses the empty fixed RPC and maps platform failures safely',
    () async {
      final calls = <MethodCall>[];
      final android = const AndroidRuntimePlatformFactory().createBrowser();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });

      expect(android.requiresAvailabilityCheck, isTrue);
      expect(android.supportsIsolatedCleanupPending, isTrue);
      expect(android.requiresPartitionBackendCheck, isTrue);
      await android.ensureAvailable();
      expect(calls, hasLength(1));
      expect(calls.single.method, 'checkSupport');
      expect(calls.single.arguments, isEmpty);

      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        throw PlatformException(
          code: 'app_failure',
          details: 'unsupportedPlatform',
          message: 'synthetic unavailable feature',
        );
      });
      await expectLater(
        android.ensureAvailable(),
        code(FailureCode.unsupportedPlatform),
      );

      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        throw PlatformException(
          code: 'app_failure',
          details: 'synthetic private platform text',
          message: 'synthetic private platform text',
        );
      });
      await expectLater(
        android.ensureAvailable(),
        code(FailureCode.sourceFailed),
      );
      expect(
        calls.skip(1).every((call) => call.method == 'checkSupport'),
        isTrue,
      );

      await android.dispose();

      final openOnly = NativeObservationBrowser(
        channel: channel,
        requiresAvailabilityCheck: true,
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        throw PlatformException(
          code: 'app_failure',
          details: 'unsupportedPlatform',
          message: 'synthetic unavailable feature',
        );
      });
      await expectLater(
        openOnly.open(
          session: 7,
          profilePath: r'C:\synthetic-profile',
          target: ObservationTarget.jw(),
        ),
        code(FailureCode.unsupportedPlatform),
      );
      expect(calls.last.method, 'open');
      await openOnly.dispose();
    },
  );

  test(
    'Windows factory keeps the default browser preflight disabled',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      const windowsFactory = WindowsRuntimePlatformFactory();
      final windowsBrowser = windowsFactory.createBrowser();
      expect(windowsBrowser.requiresAvailabilityCheck, isFalse);
      expect(windowsBrowser.supportsIsolatedCleanupPending, isFalse);
      expect(windowsBrowser.requiresPartitionBackendCheck, isFalse);
      await windowsBrowser.ensureAvailable();
      expect(
        await windowsBrowser.isCurrentPartitionBackend(
          profilePath: r'C:\synthetic-profile',
          source: ObservationSource.jw,
          fixture: false,
        ),
        isTrue,
      );
      await expectLater(
        windowsBrowser.getCleanupStatus(),
        code(FailureCode.unsupportedPlatform),
      );
      await expectLater(
        windowsBrowser.retryBrowserCleanup(),
        code(FailureCode.unsupportedPlatform),
      );
      expect(calls, isEmpty);
      await windowsBrowser.dispose();
    },
  );

  test(
    'Android cleanup status and backend checks use fixed metadata RPCs',
    () async {
      final calls = <MethodCall>[];
      final android = const AndroidRuntimePlatformFactory().createBrowser();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'getCleanupStatus' || 'retryBrowserCleanup' => {
            'backend': 'system-directory-v1',
            'pending': true,
            'count': 2,
          },
          'isCurrentPartitionBackend' => true,
          _ => null,
        };
      });

      final status = await android.getCleanupStatus();
      expect(status.pending, isTrue);
      expect(status.count, 2);
      expect(calls.single.method, 'getCleanupStatus');
      expect(calls.single.arguments, isEmpty);

      final retryStatus = await android.retryBrowserCleanup();
      expect(retryStatus.count, 2);
      expect(calls.last.method, 'retryBrowserCleanup');
      expect(calls.last.arguments, isEmpty);

      final current = await android.isCurrentPartitionBackend(
        profilePath: r'C:\synthetic-profile',
        source: ObservationSource.young,
        fixture: true,
      );
      expect(current, isTrue);
      expect(calls.last.method, 'isCurrentPartitionBackend');
      expect(calls.last.arguments, {
        'profilePath': r'C:\synthetic-profile',
        'source': 'young',
        'testMode': true,
      });
      await android.dispose();
    },
  );

  test(
    'cleanup status rejects malformed, inconsistent, and out-of-range values',
    () async {
      final calls = <MethodCall>[];
      final android = const AndroidRuntimePlatformFactory().createBrowser();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return {
          'backend': 'system-directory-v1',
          'pending': true,
          'count': 2050,
        };
      });
      await expectLater(
        android.getCleanupStatus(),
        code(FailureCode.invalidSnapshot),
      );
      expect(calls.single.method, 'getCleanupStatus');
      await android.dispose();
    },
  );

  test(
    'fixed authentication RPC consumes and wipes a one-use secret on success and failure',
    () async {
      await open();
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'advanceJwLogin') return 'formReady';
        expect((call.arguments as Map).keys.toSet(), {
          'session',
          'document',
          'operation',
          'credentialBytes',
        });
        return 'submitted';
      });
      expect(
        await browser.advanceJwLogin(session: 7, document: 2, operation: 51),
        JwLoginState.formReady,
      );
      expect(calls.single.arguments, {
        'session': 7,
        'document': 2,
        'operation': 51,
      });
      final plain = Uint8List.fromList(
        utf8.encode(
          jsonEncode({'username': 'TEST0001', 'password': 'synthetic-secret'}),
        ),
      );
      final lease = JwSecretLease(plain);
      expect(
        await browser.submitJwLogin(
          session: 7,
          document: 2,
          operation: 51,
          credentials: lease,
        ),
        JwLoginState.submitted,
      );
      expect(plain.every((byte) => byte == 0), isTrue);
      expect(() => lease.take(), throwsA(isA<JwCredentialException>()));
      final bad = Uint8List.fromList([1, 2, 3]);
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(
          code: 'raw-synthetic-secret',
          message: 'raw-synthetic-secret',
        ),
      );
      await expectLater(
        browser.submitJwLogin(
          session: 7,
          document: 2,
          operation: 52,
          credentials: JwSecretLease(bad),
        ),
        code(FailureCode.sourceFailed),
      );
      expect(bad, [0, 0, 0]);
    },
  );

  test(
    'a foreign session revokes authentication bytes without making an RPC',
    () async {
      await open();
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        return 'submitted';
      });
      final plain = Uint8List.fromList([1, 2, 3]);
      await expectLater(
        browser.submitJwLogin(
          session: 8,
          document: 2,
          operation: 51,
          credentials: JwSecretLease(plain),
        ),
        code(FailureCode.staleResult),
      );
      expect(calls, 0);
      expect(plain, [0, 0, 0]);
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => 'synthetic-page-text',
      );
      await expectLater(
        browser.advanceJwLogin(session: 7, document: 2, operation: 52),
        code(FailureCode.invalidSnapshot),
      );
    },
  );

  test(
    'authentication pause reasons are closed states without raw page text',
    () async {
      await open();
      for (final state in [
        JwLoginState.pageStructureChanged,
        JwLoginState.challengeRequired,
        JwLoginState.contextUnavailable,
      ]) {
        messenger.setMockMethodCallHandler(channel, (_) async => state.name);
        expect(
          await browser.advanceJwLogin(session: 7, document: 2, operation: 52),
          state,
        );
      }
    },
  );

  test(
    'JW probe RPC contains only context and rejects raw or foreign projections',
    () async {
      await open();
      final calls = <MethodCall>[];
      Object reply = jsonEncode({
        'operation': 9,
        'phase': 'running',
        'code': 'pending',
      });
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return reply;
      });
      final result = await browser.startJwProbe(
        session: 7,
        document: 2,
        operation: 9,
      );
      expect(result.operation, 9);
      expect(calls.single.method, 'readJwProbe');
      expect(calls.single.arguments, {
        'session': 7,
        'document': 2,
        'operation': 9,
      });
      for (final invalid in [
        '<html>synthetic secret</html>',
        jsonEncode({'operation': 8, 'phase': 'done', 'code': 'ok'}),
        jsonEncode({
          'operation': 9,
          'phase': 'done',
          'code': 'ok',
          'cookie': 'synthetic secret',
        }),
        {'operation': 9, 'phase': 'done', 'code': 'ok'},
      ]) {
        reply = invalid;
        await expectLater(
          browser.pollJwProbe(session: 7, document: 2, operation: 9),
          code(FailureCode.invalidSnapshot),
        );
      }
      final count = calls.length;
      await expectLater(
        browser.startJwProbe(session: 8, document: 2, operation: 9),
        code(FailureCode.staleResult),
      );
      expect(calls, hasLength(count));
    },
  );

  test(
    'data probe sends a bounded scope only at start and rejects raw results',
    () async {
      await open();
      final calls = <MethodCall>[];
      Object reply = jsonEncode({
        'operation': 11,
        'phase': 'running',
        'code': 'pending',
      });
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return reply;
      });
      expect(
        (await browser.startJwDataProbe(
          session: 7,
          document: 2,
          operation: 11,
          semesterId: 20261,
        )).phase,
        JwProbePhase.running,
      );
      expect(calls.single.method, 'readJwDataProbe');
      expect(calls.single.arguments, {
        'session': 7,
        'document': 2,
        'operation': 11,
        'semesterId': 20261,
      });
      await browser.pollJwDataProbe(session: 7, document: 2, operation: 11);
      expect(calls.last.method, 'pollJwDataProbe');
      expect(calls.last.arguments, {
        'session': 7,
        'document': 2,
        'operation': 11,
      });
      final count = calls.length;
      await expectLater(
        browser.startJwDataProbe(
          session: 6,
          document: 2,
          operation: 11,
          semesterId: 20261,
        ),
        code(FailureCode.staleResult),
      );
      await expectLater(
        browser.startJwDataProbe(
          session: 7,
          document: 2,
          operation: 11,
          semesterId: -1,
        ),
        code(FailureCode.invalidSnapshot),
      );
      expect(calls, hasLength(count));
      reply = jsonEncode({
        'operation': 11,
        'phase': 'done',
        'code': 'ok',
        'raw': 'private',
      });
      await expectLater(
        browser.pollJwDataProbe(session: 7, document: 2, operation: 11),
        code(FailureCode.invalidSnapshot),
      );
    },
  );

  test(
    'JW launchers expose only closed page choices and current context',
    () async {
      await open();
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      for (final page in JwObservationPage.values) {
        await browser.navigateJwPage(session: 7, document: 2, page: page);
        expect(calls.last.method, 'navigateJwPage');
        expect(calls.last.arguments, {
          'session': 7,
          'document': 2,
          'page': page.name,
        });
      }
      await expectLater(
        browser.navigateJwPage(
          session: 8,
          document: 2,
          page: JwObservationPage.courseTable,
        ),
        code(FailureCode.staleResult),
      );
      expect(calls, hasLength(2));
    },
  );

  test(
    'diagnostics use closed enums and drop malformed or private targets',
    () async {
      await open();
      await emit({
        'session': 7,
        'document': 1,
        'kind': 'diagnostic',
        'diagnostic': {
          'code': 'topNavigationBlocked',
          'site': 'unknown',
          'scheme': 'https',
          'uri': 'https://secret.invalid/?ticket=synthetic',
        },
      });
      expect(
        events.single.diagnostic!.code,
        BrowserDiagnosticCode.topNavigationBlocked,
      );
      expect(events.single.diagnostic!.site, BrowserDiagnosticSite.unknown);
      expect(events.single.origin, isNull);
      for (final invalid in [
        {'code': 'private failure', 'site': 'identity', 'scheme': 'http'},
        {
          'code': 'insecureDocumentUpgraded',
          'site': 'https://id.ustc.edu.cn/?ticket=synthetic',
          'scheme': 'http',
        },
        {
          'code': 'insecureDocumentUpgraded',
          'site': 'identity',
          'scheme': 'private',
        },
      ]) {
        await emit({
          'session': 7,
          'document': 2,
          'kind': 'diagnostic',
          'diagnostic': invalid,
        });
      }
      expect(events, hasLength(1));
    },
  );

  test(
    'JW sends the fixed authentication surface and keeps only origins',
    () async {
      Map<dynamic, dynamic>? opened;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'open') opened = call.arguments as Map;
        return null;
      });
      await open();
      expect(opened!['initialUrl'], 'https://jw.ustc.edu.cn/');
      expect(opened!['testMode'], isFalse);
      expect(
        opened!['allowedOrigins'],
        unorderedEquals([
          'https://jw.ustc.edu.cn',
          'https://passport.ustc.edu.cn',
          'https://id.ustc.edu.cn',
          'https://analytics.ustc.edu.cn',
        ]),
      );
      for (final origin in [
        'https://id.ustc.edu.cn',
        'https://analytics.ustc.edu.cn',
      ]) {
        await emit({
          'session': 7,
          'document': 2,
          'kind': 'ready',
          'origin': origin,
        });
        expect(events.last.origin, origin);
        await emit({
          'session': 7,
          'document': 3,
          'kind': 'ready',
          'origin': '$origin/cas/login?ticket=synthetic',
        });
        expect(events.last.origin, isNull);
      }
    },
  );

  test(
    'fixture authentication origins cannot widen beyond bounded loopback',
    () {
      final initial = Uri.parse('http://127.0.0.1:8100/fixture');
      final allowed = Uri.parse('http://127.0.0.1:8101');
      expect(
        ObservationTarget.fixture(
          initial,
          additionalOrigins: [allowed],
        ).allowedOrigins,
        ['http://127.0.0.1:8100', 'http://127.0.0.1:8101'],
      );
      for (final invalid in [
        [Uri.parse(initial.origin)],
        [allowed, allowed],
        [Uri.parse('http://localhost:8101')],
        [Uri.parse('http://user@127.0.0.1:8101')],
        [Uri.parse('http://127.0.0.1')],
        [Uri.parse('http://127.0.0.1:8101/private')],
        [Uri.parse('http://127.0.0.1:8101?ticket=synthetic')],
        [Uri.parse('http://127.0.0.1:8101#fragment')],
        [Uri.parse('https://id.ustc.edu.cn')],
        [
          for (var port = 8101; port <= 8104; port++)
            Uri.parse('http://127.0.0.1:$port'),
        ],
      ]) {
        expect(
          () => ObservationTarget.fixture(initial, additionalOrigins: invalid),
          throwsA(
            isA<AppFailure>().having(
              (e) => e.code,
              'code',
              FailureCode.invalidSnapshot,
            ),
          ),
        );
      }
    },
  );

  test(
    'malformed, unset and old sessions cannot publish readiness or raw URLs',
    () async {
      await emit({'session': null, 'document': 1, 'kind': 'ready'});
      expect(events, isEmpty);
      await open();
      await emit({'session': 6, 'document': 1, 'kind': 'ready'});
      await emit({'session': 7, 'document': -1, 'kind': 'ready'});
      await emit({'session': 7, 'document': 1, 'kind': 'unknown'});
      expect(events, isEmpty);
      await emit({
        'session': 7,
        'document': 1,
        'kind': 'ready',
        'origin': 'https://jw.ustc.edu.cn/path?private=value',
      });
      expect(events.single.origin, isNull);
      await emit({
        'session': 7,
        'document': 2,
        'kind': 'ready',
        'origin': 'https://jw.ustc.edu.cn',
      });
      expect(events.last.origin, 'https://jw.ustc.edu.cn');
    },
  );
  test('only matching fixed inspection metadata is accepted', () async {
    await open();
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {'session': 7, 'document': 4, 'ready': true},
    );
    await expectLater(
      browser.inspect(session: 7, document: 3),
      code(FailureCode.staleResult),
    );
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {
        'session': 7,
        'document': 3,
        'ready': true,
        'origin': 'https://other.invalid/private',
      },
    );
    expect((await browser.inspect(session: 7, document: 3)).origin, isNull);
  });
  test(
    'Young has its own fixed entry and exact authentication origins',
    () async {
      final target = ObservationTarget.young();
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      await browser.open(
        session: 8,
        profilePath: r'C:\synthetic-young',
        target: target,
      );
      expect(target.source, ObservationSource.young);
      expect(target.isFixture, isFalse);
      expect(target.initialUri.toString(), 'https://young.ustc.edu.cn/login/');
      expect(target.allowedOrigins.toSet(), {
        'https://young.ustc.edu.cn',
        'https://passport.ustc.edu.cn',
        'https://ucas.ustc.edu.cn',
        'https://id.ustc.edu.cn',
        'https://analytics.ustc.edu.cn',
      });
      expect((calls.single.arguments as Map)['source'], 'young');
      expect((calls.single.arguments as Map)['testMode'], false);
      expect(
        () => target.allowedOrigins.add('https://other.invalid'),
        throwsUnsupportedError,
      );
    },
  );
  test(
    'Young rejects JW login, navigation and collection before RPC',
    () async {
      await browser.open(
        session: 8,
        profilePath: r'C:\synthetic-young',
        target: ObservationTarget.young(),
      );
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      await expectLater(
        browser.advanceJwLogin(session: 8, document: 1, operation: 1),
        code(FailureCode.invalidSnapshot),
      );
      final bytes = Uint8List.fromList([1, 2, 3]);
      await expectLater(
        browser.submitJwLogin(
          session: 8,
          document: 1,
          operation: 1,
          credentials: JwSecretLease(bytes),
        ),
        code(FailureCode.invalidSnapshot),
      );
      expect(bytes, [0, 0, 0]);
      await expectLater(
        browser.navigateJwPage(
          session: 8,
          document: 1,
          page: JwObservationPage.courseTable,
        ),
        code(FailureCode.invalidSnapshot),
      );
      await expectLater(
        browser.startJwProbe(session: 8, document: 1, operation: 1),
        code(FailureCode.invalidSnapshot),
      );
      await expectLater(
        browser.startJwCollection(
          session: 8,
          document: 1,
          operation: 1,
          semesterId: 1,
        ),
        code(FailureCode.invalidSnapshot),
      );
      expect(calls, isEmpty);
    },
  );
  test(
    'Young metadata is document-bound and rejects contaminated results',
    () async {
      await open();
      await expectLater(
        browser.inspectYoungPage(session: 7, document: 1),
        code(FailureCode.invalidSnapshot),
      );
      await browser.open(
        session: 8,
        profilePath: r'C:\synthetic-young',
        target: ObservationTarget.young(),
      );
      final snapshot = <String, Object>{
        'session': 8,
        'document': 2,
        'ready': true,
        'surface': 'application',
        'tables': 1,
        'calendarRoots': 2,
        'paginationControls': 3,
        'passwordInputs': 0,
      };
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'inspectYoungPage');
        expect(call.arguments, {'session': 8, 'document': 2});
        return snapshot;
      });
      final result = await browser.inspectYoungPage(session: 8, document: 2);
      expect(result.surface, YoungSurface.application);
      expect(result.safeSummary()['identity'], 'notValidated');
      await expectLater(
        browser.inspectYoungPage(session: 7, document: 2),
        code(FailureCode.staleResult),
      );
      snapshot['document'] = 1;
      await expectLater(
        browser.inspectYoungPage(session: 8, document: 2),
        code(FailureCode.staleResult),
      );
      snapshot['document'] = 2;
      snapshot['cookie'] = 'synthetic-private';
      await expectLater(
        browser.inspectYoungPage(session: 8, document: 2),
        code(FailureCode.invalidSnapshot),
      );
    },
  );
  test(
    'native failures and malformed RPC types expose stable safe failures',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async =>
            throw PlatformException(code: 'unknown', message: 'private error'),
      );
      await expectLater(open(), code(FailureCode.sourceFailed));
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(
          code: 'app_failure',
          details: 'cleanupPending',
        ),
      );
      await expectLater(browser.close(7), code(FailureCode.cleanupPending));
      messenger.setMockMethodCallHandler(channel, (_) async => 'not a bool');
      await expectLater(browser.drained(7), code(FailureCode.sourceFailed));
    },
  );
}
