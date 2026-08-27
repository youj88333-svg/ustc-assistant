import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_windows_secure/webview_flutter_windows.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const plugin = MethodChannel('io.jns.webview.win');
  const controllerChannel = MethodChannel('io.jns.webview.win/7');
  final calls = <MethodCall>[];
  var disposeFailuresRemaining = 0;

  setUp(() {
    calls.clear();
    disposeFailuresRemaining = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(plugin, (call) async {
      calls.add(call);
      if (call.method == 'initialize') {
        return <String, Object>{'textureId': 7};
      }
      if (call.method == 'dispose' && disposeFailuresRemaining > 0) {
        disposeFailuresRemaining--;
        throw PlatformException(
          code: 'native_dispose_failed',
          message: 'synthetic native dispose failure',
        );
      }
      return null;
    });
    messenger.setMockMethodCallHandler(controllerChannel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(plugin, null);
    messenger.setMockMethodCallHandler(controllerChannel, null);
  });

  test(
    'secure methods cross the intended native channels with no secrets',
    () async {
      final controller = WebviewController();
      await controller.initialize();
      await controller.awaitEventStreamReady();

      await controller.setNavigationPolicy(
        allowedOrigins: const <String>[
          'https://jw.ustc.edu.cn',
          'https://id.ustc.edu.cn',
        ],
        allowedPathPrefixes: const <String, List<String>>{
          'https://jw.ustc.edu.cn': <String>['/home', '/for-std/course-table'],
          'https://id.ustc.edu.cn': <String>['/cas/login'],
        },
        debugLoopbackPort: 43123,
      );
      await controller.denyDownloads();
      await controller.denyNewWindows();
      await controller.denyPermissions();
      await controller.restoreTrustedSessionSnapshot(
        r'C:\private\account\.ustc-session.dpapi',
      );
      await controller.persistTrustedSessionSnapshot(
        r'C:\private\account\.ustc-session.dpapi',
      );
      await controller.clearBrowsingDataAll();
      await controller.disposeControllerAndAwaitRelease();

      expect(
        calls.map((call) => call.method),
        containsAllInOrder(<String>[
          'initialize',
          'awaitEventStreamReady',
          'setNavigationPolicy',
          'denyDownloads',
          'denyNewWindows',
          'denyPermissions',
          'restoreTrustedSessionSnapshot',
          'persistTrustedSessionSnapshot',
          'clearBrowsingDataAll',
          'dispose',
          'awaitEnvironmentReleased',
        ]),
      );
      final policyCall = calls.singleWhere(
        (call) => call.method == 'setNavigationPolicy',
      );
      expect(policyCall.arguments, <String, Object>{
        'allowedOrigins': <String>[
          'https://jw.ustc.edu.cn',
          'https://id.ustc.edu.cn',
        ],
        'allowedPathPrefixes': <String, List<String>>{
          'https://jw.ustc.edu.cn': <String>['/home', '/for-std/course-table'],
          'https://id.ustc.edu.cn': <String>['/cas/login'],
        },
        'debugLoopbackPort': 43123,
      });
      final snapshotCalls = calls.where(
        (call) =>
            call.method == 'restoreTrustedSessionSnapshot' ||
            call.method == 'persistTrustedSessionSnapshot',
      );
      expect(snapshotCalls, hasLength(2));
      for (final call in snapshotCalls) {
        expect(call.arguments, r'C:\private\account\.ustc-session.dpapi');
        expect(call.arguments, isNot(isA<Map<Object?, Object?>>()));
      }
    },
  );

  test(
    'environment release can be awaited without creating a controller',
    () async {
      await WebviewController.awaitEnvironmentReleased();
      expect(calls.single.method, 'awaitEnvironmentReleased');
    },
  );

  test('primary click crosses one atomic native method call', () async {
    final controller = WebviewController();
    await controller.initialize();

    await controller.dispatchPrimaryClick(const Offset(125, 75));

    final click = calls.singleWhere(
      (call) => call.method == 'dispatchPrimaryClick',
    );
    expect(click.arguments, <double>[125, 75]);
    expect(
      calls.where(
        (call) =>
            call.method == 'setCursorPos' || call.method == 'setPointerButton',
      ),
      isEmpty,
    );
  });

  test('primary click rejects invalid coordinates before native dispatch', () {
    final controller = WebviewController();

    expect(
      () => controller.dispatchPrimaryClick(const Offset(-1, 0)),
      throwsArgumentError,
    );
    expect(
      () => controller.dispatchPrimaryClick(const Offset(double.nan, 0)),
      throwsArgumentError,
    );
    expect(calls, isEmpty);
  });

  test(
    'uninitialized disposal does not await a nonexistent environment',
    () async {
      final controller = WebviewController();
      await controller.disposeControllerAndAwaitRelease();
      expect(calls, isEmpty);
    },
  );

  test('native dispose failures propagate to the caller', () async {
    disposeFailuresRemaining = 1;
    final controller = WebviewController();
    await controller.initialize();

    await expectLater(
      controller.disposeControllerAndAwaitRelease(),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'native_dispose_failed',
        ),
      ),
    );
    expect(
      calls.where((call) => call.method == 'awaitEnvironmentReleased'),
      isEmpty,
    );
    expect(controller.value.isInitialized, isTrue);

    // A failed native release must leave the texture disposable. Retrying the
    // same controller succeeds and only then waits for the shared environment.
    await controller.disposeControllerAndAwaitRelease();
    expect(calls.where((call) => call.method == 'dispose'), hasLength(2));
    expect(calls.last.method, 'awaitEnvironmentReleased');
    expect(controller.value.isInitialized, isFalse);

    // Successful teardown remains idempotent: no duplicate native dispose,
    // stream closure, or environment waiter is registered.
    await controller.disposeControllerAndAwaitRelease();
    expect(calls.where((call) => call.method == 'dispose'), hasLength(2));
    expect(
      calls.where((call) => call.method == 'awaitEnvironmentReleased'),
      hasLength(1),
    );
  });

  if (!kDebugMode) {
    test(
      'release API rejects debug loopback before crossing a channel',
      () async {
        final controller = WebviewController();
        expect(
          () => controller.setNavigationPolicy(
            allowedOrigins: const <String>['https://jw.ustc.edu.cn'],
            allowedPathPrefixes: const <String, List<String>>{
              'https://jw.ustc.edu.cn': <String>['/home'],
            },
            debugLoopbackPort: 43123,
          ),
          throwsUnsupportedError,
        );
        expect(calls, isEmpty);
        await controller.dispose();
      },
    );
  }
}
