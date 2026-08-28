import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_web_session.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_webview_surface_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('detach completes only after placeholder frame', (tester) async {
    final host = JwWebViewSurfaceHost();
    final controller = _SurfaceController(const Key('surface-a'));
    await tester.pumpWidget(MaterialApp(home: host.widget));
    await host.attach(controller);
    await tester.pump();
    expect(find.byKey(const Key('surface-a')), findsOneWidget);

    var completed = false;
    final detach = host.detachAndAwaitUnmount(controller);
    detach.then((_) => completed = true);
    await Future<void>.microtask(() {});
    expect(completed, isFalse);
    await tester.pump();
    await detach;
    expect(completed, isTrue);
    expect(
      find.byKey(const Key('jw-webview-surface-placeholder')),
      findsOneWidget,
    );
  });

  testWidgets('replacement waits for previous generation to unmount', (
    tester,
  ) async {
    final host = JwWebViewSurfaceHost();
    final first = _SurfaceController(const Key('surface-a'));
    final second = _SurfaceController(const Key('surface-b'));
    await tester.pumpWidget(MaterialApp(home: host.widget));
    await host.attach(first);
    await tester.pump();
    final detach = host.detachAndAwaitUnmount(first);
    final attach = host.attach(second);
    await tester.pump();
    await detach;
    await attach;
    await tester.pump();
    expect(find.byKey(const Key('surface-a')), findsNothing);
    expect(find.byKey(const Key('surface-b')), findsOneWidget);
  });

  testWidgets('host disposal releases pending detach', (tester) async {
    final host = JwWebViewSurfaceHost();
    final controller = _SurfaceController(const Key('surface-a'));
    await tester.pumpWidget(MaterialApp(home: host.widget));
    await host.attach(controller);
    await tester.pump();
    final detach = host.detachAndAwaitUnmount(controller);
    await tester.pumpWidget(const SizedBox());
    await detach;
    expect(host.isAttached, isFalse);
  });
}

class _SurfaceController implements JwWebviewController {
  _SurfaceController(this.key);

  final Key key;

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
  Widget get surface => SizedBox(key: key);

  @override
  Future<void> loadUrl(String url) async {}

  @override
  Future<Object?> executeScript(String source) async => null;

  @override
  Future<void> dispatchPrimaryClick(Offset position) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> clearBrowsingDataAll() async {}

  @override
  Future<void> dispose() async {}
}
