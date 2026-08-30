import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/features/sync/data/bridge_client.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_web_session.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_webview_adapter.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_webview_surface_host.dart';
import 'package:ustc_assistant_app/features/sync/native/windows_jw_browser_session_admin.dart';
import 'package:ustc_assistant_app/features/sync/native/windows_jw_udf_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ustc-jw-session-admin-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  testWidgets('close detaches before stop, subscriptions, and native release', (
    tester,
  ) async {
    final events = <String>[];
    final controller = _FakeSessionController(events);
    final host = JwWebViewSurfaceHost(
      onDetachRequested: (_) => events.add('surface.detach'),
    );
    final admin = _admin(root: root, controller: controller, surfaceHost: host);

    await tester.pumpWidget(MaterialApp(home: host.widget));
    final handle = await tester.runAsync(() => admin.open('student'));
    await tester.pump();

    final close = handle!.close();
    await Future<void>.microtask(() {});
    expect(events, <String>['surface.detach']);

    await tester.pump();
    await close;
    expect(events, <String>[
      'surface.detach',
      'controller.stop',
      'subscriptions.dispose',
      'controller.dispose_and_release',
    ]);
  });

  test('only one live session is admitted at a time', () async {
    final controller = _FakeSessionController(<String>[]);
    final admin = _admin(root: root, controller: controller);

    final first = await admin.open('student');
    await expectLater(
      admin.open('student'),
      throwsA(
        isA<BridgeProtocolError>().having(
          (error) => error.code,
          'code',
          'bridge_busy',
        ),
      ),
    );
    await first.close();
  });

  test('controller factory failure quarantines the partition', () async {
    final store = WindowsJwUdfStore(privateRoot: root);
    final admin = WindowsJwBrowserSessionAdmin(
      udfStore: store,
      controllerFactory: () async => throw StateError('private path leaked'),
    );

    await expectLater(
      admin.open('student'),
      throwsA(isA<BridgeProtocolError>()),
    );
    final ref = store.referenceFor('student');
    expect(await store.isQuarantined(ref), isTrue);
    await expectLater(
      admin.open('student'),
      throwsA(
        isA<BridgeProtocolError>().having(
          (error) => error.code,
          'code',
          'browser_session_quarantined',
        ),
      ),
    );
  });

  test('release failure retains the exact handle for retry', () async {
    final controller = _FakeSessionController(
      <String>[],
      failReleaseAttempts: 1,
    );
    final admin = _admin(root: root, controller: controller);
    final handle = await admin.open('student');

    await expectLater(
      handle.close(),
      throwsA(
        isA<BridgeProtocolError>().having(
          (error) => error.code,
          'code',
          'browser_cleanup_incomplete',
        ),
      ),
    );
    await expectLater(
      admin.clearAllPartitions(),
      throwsA(
        isA<BridgeProtocolError>().having(
          (error) => error.code,
          'code',
          'bridge_busy',
        ),
      ),
    );
    await expectLater(
      admin.open('student'),
      throwsA(
        isA<BridgeProtocolError>().having(
          (error) => error.code,
          'code',
          'browser_session_quarantined',
        ),
      ),
    );

    await handle.close();
    await admin.clearAllPartitions();
    expect(await root.exists(), isTrue);
  });

  test('close is idempotent after the release barrier succeeds', () async {
    final events = <String>[];
    final controller = _FakeSessionController(events);
    final admin = _admin(root: root, controller: controller);
    final handle = await admin.open('student');

    await handle.close();
    final firstCloseEvents = [...events];
    await handle.close();

    expect(events, firstCloseEvents);
  });

  test(
    'clear-all waits for every live handle before touching the store',
    () async {
      var deleteCalls = 0;
      final controller = _FakeSessionController(<String>[]);
      final store = WindowsJwUdfStore(
        privateRoot: root,
        deleteDirectory: (directory) async {
          deleteCalls++;
          if (await directory.exists()) await directory.delete(recursive: true);
        },
      );
      final admin = WindowsJwBrowserSessionAdmin(
        udfStore: store,
        controllerFactory: () async => controller,
      );
      final handle = await admin.open('student');

      await expectLater(
        admin.clearAllPartitions(),
        throwsA(
          isA<BridgeProtocolError>().having(
            (error) => error.code,
            'code',
            'bridge_busy',
          ),
        ),
      );
      expect(deleteCalls, 0);

      await handle.close();
      await admin.clearAllPartitions();
      expect(deleteCalls, 1);
    },
  );

  test('shutdown waits for an opening controller and releases it', () async {
    final creation = Completer<JwWebviewController>();
    final events = <String>[];
    final controller = _FakeSessionController(events);
    final admin = WindowsJwBrowserSessionAdmin(
      udfStore: WindowsJwUdfStore(privateRoot: root),
      controllerFactory: () => creation.future,
    );

    final opening = admin.open('student');
    final shutdown = admin.shutdown();
    var shutdownCompleted = false;
    unawaited(shutdown.then<void>((_) => shutdownCompleted = true));
    await Future<void>.microtask(() {});
    expect(shutdownCompleted, isFalse);

    creation.complete(controller);
    await expectLater(opening, throwsA(isA<BridgeProtocolError>()));
    await shutdown;
    expect(events, <String>[
      'controller.stop',
      'subscriptions.dispose',
      'controller.dispose_and_release',
    ]);
  });
}

WindowsJwBrowserSessionAdmin _admin({
  required Directory root,
  required _FakeSessionController controller,
  JwWebViewSurfaceHost? surfaceHost,
}) {
  return WindowsJwBrowserSessionAdmin(
    udfStore: WindowsJwUdfStore(privateRoot: root),
    controllerFactory: () async => controller,
    surfaceHost: surfaceHost,
  );
}

final class _FakeSessionController
    implements JwWebviewController, JwWebviewControllerLifecycle {
  _FakeSessionController(this.events, {this.failReleaseAttempts = 0});

  final List<String> events;
  int failReleaseAttempts;

  @override
  Stream<String> get urlChanges => const Stream<String>.empty();

  @override
  String? get currentUrlSnapshot => null;

  @override
  Stream<JwLoadingState> get loadingStateChanges =>
      const Stream<JwLoadingState>.empty();

  @override
  Stream<Object?> get webMessages => const Stream<Object?>.empty();

  @override
  Future<void> awaitEventStreamReady() async {}

  @override
  Widget get surface => const SizedBox();

  @override
  Future<void> loadUrl(String url) async {}

  @override
  Future<Object?> executeScript(String source) async => null;

  @override
  Future<void> dispatchPrimaryClick(Offset position) async {}

  @override
  Future<void> beginSubscriptions() async {}

  @override
  Future<void> stop() async => events.add('controller.stop');

  @override
  Future<void> clearBrowsingDataAll() async {}

  @override
  Future<void> disposeSubscriptions() async =>
      events.add('subscriptions.dispose');

  @override
  Future<void> disposeControllerAndAwaitRelease() async {
    events.add('controller.dispose_and_release');
    if (failReleaseAttempts > 0) {
      failReleaseAttempts--;
      throw StateError('release failed');
    }
  }

  @override
  Future<void> dispose() async => disposeControllerAndAwaitRelease();
}
