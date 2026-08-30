import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/features/sync/domain/sync_state.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_browser_session_admin.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_webview_surface_host.dart';
import 'package:ustc_assistant_app/features/sync/runtime/minimal_jw_runtime.dart';
import 'package:ustc_assistant_app/features/sync/runtime/minimal_jw_runtime_scope.dart';
import 'package:ustc_assistant_app/features/sync/runtime/source_job_gateway.dart';

void main() {
  test('current caches one load and shutdown is idempotent', () async {
    final loaderGate = Completer<MinimalJwRuntime>();
    final runtime = _FakeRuntime();
    var loadCalls = 0;
    final owner = MinimalJwRuntimeOwner(() {
      loadCalls++;
      return loaderGate.future;
    });

    final first = owner.current;
    final second = owner.current;
    expect(identical(first, second), isTrue);
    expect(loadCalls, 1);

    loaderGate.complete(runtime.runtime);
    expect(await first, same(runtime.runtime));

    final shutdown = owner.beginShutdown();
    expect(identical(shutdown, owner.beginShutdown()), isTrue);
    await shutdown;
    expect(runtime.gateway.shutdownCalls, 1);
    expect(runtime.browserSessions.shutdownCalls, 1);
  });

  test(
    'shutdown closes a runtime that finishes loading after disposal',
    () async {
      final loaderGate = Completer<MinimalJwRuntime>();
      final runtime = _FakeRuntime();
      final owner = MinimalJwRuntimeOwner(() => loaderGate.future);

      final loading = owner.current;
      final shutdown = owner.beginShutdown();
      expect(owner.beginShutdown(), same(shutdown));
      await Future<void>.microtask(() {});
      expect(runtime.shutdownCalls, 0);

      loaderGate.complete(runtime.runtime);
      await shutdown;
      await loading;
      expect(runtime.gateway.shutdownCalls, 1);
      expect(runtime.browserSessions.shutdownCalls, 1);
    },
  );

  test(
    'replaceAfterReset waits for old shutdown before one fresh load',
    () async {
      final oldShutdownGate = Completer<void>();
      final old = _FakeRuntime(shutdownGate: oldShutdownGate);
      final fresh = _FakeRuntime();
      var loadCalls = 0;
      final owner = MinimalJwRuntimeOwner(() async {
        loadCalls++;
        return loadCalls == 1 ? old.runtime : fresh.runtime;
      });

      expect(await owner.current, same(old.runtime));
      final replacement = owner.replaceAfterReset();
      await Future<void>.microtask(() {});
      expect(old.shutdownCalls, 1);
      expect(loadCalls, 1);

      oldShutdownGate.complete();
      final replacementAgain = owner.replaceAfterReset();
      expect(identical(replacement, replacementAgain), isTrue);
      await replacement;
      expect(loadCalls, 2);
      expect(await owner.current, same(fresh.runtime));
    },
  );

  testWidgets('runtime scope returns the app-owned runtime', (tester) async {
    final runtime = _FakeRuntime().runtime;
    late MinimalJwRuntime resolved;
    await tester.pumpWidget(
      MinimalJwRuntimeScope(
        runtime: runtime,
        child: Builder(
          builder: (context) {
            resolved = MinimalJwRuntimeScope.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(identical(resolved, runtime), isTrue);
  });
}

final class _FakeRuntime {
  _FakeRuntime({Completer<void>? shutdownGate}) {
    gateway = _FakeGateway(shutdownGate);
    browserSessions = _FakeSessionAdmin();
    runtime = MinimalJwRuntime(
      gateway: gateway,
      browserSessions: browserSessions,
    );
  }

  late final _FakeGateway gateway;
  late final _FakeSessionAdmin browserSessions;
  late final MinimalJwRuntime runtime;

  int get shutdownCalls =>
      gateway.shutdownCalls + browserSessions.shutdownCalls;
}

final class _FakeGateway implements SourceJobGateway {
  _FakeGateway(this.shutdownGate);

  final Completer<void>? shutdownGate;
  var shutdownCalls = 0;

  @override
  Stream<SourceJobSnapshot> get states => const Stream.empty();

  @override
  Future<void> cancelCurrent() async {}

  @override
  Future<SyncOutcome> firstLogin(FirstLoginCommand command) =>
      throw UnimplementedError();

  @override
  Future<SyncOutcome> sync({
    required String accountId,
    required SyncTrigger trigger,
  }) => throw UnimplementedError();

  @override
  Future<void> shutdown() async {
    shutdownCalls++;
    await shutdownGate?.future;
  }
}

final class _FakeSessionAdmin implements JwBrowserSessionAdmin {
  var shutdownCalls = 0;

  @override
  JwWebViewSurfaceHost get surfaceHost => JwWebViewSurfaceHost();

  @override
  Future<JwBrowserSessionHandle> open(String accountId) =>
      throw UnimplementedError();

  @override
  Future<void> clearAllPartitions() async {}

  @override
  Future<void> shutdown() async {
    shutdownCalls++;
  }
}
