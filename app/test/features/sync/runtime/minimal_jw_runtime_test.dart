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

  test('initial loader failure clears construction ownership for retry', () async {
    final runtime = _FakeRuntime();
    final loadError = StateError('initial construction failed');
    var loadCalls = 0;
    final owner = MinimalJwRuntimeOwner(() async {
      loadCalls++;
      if (loadCalls == 1) throw loadError;
      return runtime.runtime;
    });

    await expectLater(owner.current, throwsA(same(loadError)));
    await Future<void>.microtask(() {});
    expect(await owner.current, same(runtime.runtime));
    expect(loadCalls, 2);

    await owner.beginShutdown();
  });

  test('replacement loader failure can recover without another live runtime', () async {
    final old = _FakeRuntime();
    final fresh = _FakeRuntime();
    final replacementError = StateError('replacement construction failed');
    var loadCalls = 0;
    final owner = MinimalJwRuntimeOwner(() async {
      loadCalls++;
      if (loadCalls == 1) return old.runtime;
      if (loadCalls == 2) throw replacementError;
      return fresh.runtime;
    });

    expect(await owner.current, same(old.runtime));
    await expectLater(owner.replaceAfterReset(), throwsA(same(replacementError)));
    await Future<void>.microtask(() {});

    await owner.replaceAfterReset();
    expect(loadCalls, 3);
    expect(await owner.current, same(fresh.runtime));
    expect(old.gateway.shutdownCalls, 1);

    await owner.beginShutdown();
  });

  test('terminal shutdown treats a late loader failure as no runtime to release', () async {
    final loaderGate = Completer<MinimalJwRuntime>();
    final loadError = StateError('late construction failed');
    var loadCalls = 0;
    final owner = MinimalJwRuntimeOwner(() {
      loadCalls++;
      return loaderGate.future;
    });

    final loading = owner.current;
    final shutdown = owner.beginShutdown();
    loaderGate.completeError(loadError);

    await shutdown;
    await expectLater(loading, throwsA(same(loadError)));
    expect(loadCalls, 1);
    await expectLater(owner.current, throwsA(isA<StateError>()));
  });

  test('shutdown failure retains the live runtime for a later retry', () async {
    final old = _FakeRuntime(failShutdown: true);
    final fresh = _FakeRuntime();
    var loadCalls = 0;
    final owner = MinimalJwRuntimeOwner(() async {
      loadCalls++;
      return loadCalls == 1 ? old.runtime : fresh.runtime;
    });

    await owner.current;
    await expectLater(owner.replaceAfterReset(), throwsA(isA<StateError>()));
    expect(loadCalls, 1);
    expect(old.gateway.shutdownCalls, 1);

    old.gateway.failShutdown = false;
    await owner.replaceAfterReset();
    expect(loadCalls, 2);
    expect(old.gateway.shutdownCalls, 2);
    expect(await owner.current, same(fresh.runtime));

    await owner.beginShutdown();
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

  test(
    'reset teardown remains replaceable before terminal app shutdown',
    () async {
      final old = _FakeRuntime();
      final fresh = _FakeRuntime();
      var loadCalls = 0;
      final owner = MinimalJwRuntimeOwner(() async {
        loadCalls++;
        return loadCalls == 1 ? old.runtime : fresh.runtime;
      });
      await owner.current;

      await owner.prepareForReset();
      await owner.replaceAfterReset();
      expect(await owner.current, same(fresh.runtime));
      expect(loadCalls, 2);
    },
  );

  test('current rejects access after terminal shutdown starts', () async {
    final runtime = _FakeRuntime();
    final owner = MinimalJwRuntimeOwner(() async => runtime.runtime);
    await owner.current;

    final shutdown = owner.beginShutdown();
    await expectLater(owner.current, throwsA(isA<StateError>()));
    await shutdown;
  });

  test('terminal app shutdown wins a concurrent reset replacement', () async {
    final oldShutdownGate = Completer<void>();
    final old = _FakeRuntime(shutdownGate: oldShutdownGate);
    final fresh = _FakeRuntime();
    var loadCalls = 0;
    final owner = MinimalJwRuntimeOwner(() async {
      loadCalls++;
      return loadCalls == 1 ? old.runtime : fresh.runtime;
    });
    await owner.current;

    final replacement = owner.replaceAfterReset();
    await Future<void>.microtask(() {});
    final terminalShutdown = owner.beginShutdown();
    oldShutdownGate.complete();

    await expectLater(replacement, throwsA(isA<StateError>()));
    await terminalShutdown;
    expect(loadCalls, 1);
    expect(fresh.shutdownCalls, 0);
    await expectLater(owner.current, throwsA(isA<StateError>()));
  });

  test(
    'terminal shutdown drains a fresh runtime admitted by a racing reset',
    () async {
      final oldShutdownGate = Completer<void>();
      final freshLoadGate = Completer<MinimalJwRuntime>();
      final freshLoadStarted = Completer<void>();
      final old = _FakeRuntime(shutdownGate: oldShutdownGate);
      final fresh = _FakeRuntime();
      var loadCalls = 0;
      final owner = MinimalJwRuntimeOwner(() async {
        loadCalls++;
        if (loadCalls == 1) return old.runtime;
        if (!freshLoadStarted.isCompleted) freshLoadStarted.complete();
        return freshLoadGate.future;
      });
      await owner.current;

      final replacement = owner.replaceAfterReset();
      await Future<void>.microtask(() {});
      oldShutdownGate.complete();
      await freshLoadStarted.future;

      final terminalShutdown = owner.beginShutdown();
      freshLoadGate.complete(fresh.runtime);

      await expectLater(replacement, throwsA(isA<StateError>()));
      await terminalShutdown;
      expect(fresh.shutdownCalls, 2);
      await expectLater(owner.current, throwsA(isA<StateError>()));
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
  _FakeRuntime({Completer<void>? shutdownGate, bool failShutdown = false}) {
    gateway = _FakeGateway(shutdownGate, failShutdown: failShutdown);
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
  _FakeGateway(this.shutdownGate, {this.failShutdown = false});

  final Completer<void>? shutdownGate;
  bool failShutdown;
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
    if (failShutdown) throw StateError('gateway shutdown failed');
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
