import 'dart:async' show Completer, Stream;
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/jobs/observation_coordinator.dart';
import 'package:ustc_assistant_m0/jobs/observation_port.dart';
import 'package:ustc_assistant_m0/platform/demo_directory.dart';
import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';
import 'package:ustc_assistant_m0/platform/observation_assets.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';

import 'support/observation_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'ordinary native observation controls, documents, drain and recovery',
    (tester) async {
      await tester.runAsync(() async {
        final fixture = await ObservationFixture.start();
        final root = await Directory.systemTemp.createTemp(
          'ustc_m1_native_test_',
        );
        final owner = await DemoDirectory.acquire(p.join(root.path, 'owned'));
        final browser = NativeObservationBrowser(
          fixtureDeniedUri: fixture.deniedUri,
        );
        final trackedBrowser = _TrackedBrowser(browser);
        final events = <BrowserEvent>[];
        final subscription = browser.events.listen(events.add);
        final leases = WorkLeasePool();
        ObservationCoordinator? coordinator;
        try {
          coordinator = ObservationCoordinator(
            browser: trackedBrowser,
            assets: ObservationAssets(owner),
            leases: leases,
            target: ObservationTarget.fixture(
              fixture.initialUri,
              additionalOrigins: fixture.authenticationOrigins,
            ),
          );
          final active = coordinator;
          Future<void> waitFor(bool Function() condition, String reason) async {
            final elapsed = Stopwatch()..start();
            while (!condition()) {
              if (elapsed.elapsed > const Duration(seconds: 20)) {
                fail(
                  '$reason; phase=${active.view.phase.name}; failure=${active.view.failure?.name}',
                );
              }
              await Future<void>.delayed(const Duration(milliseconds: 40));
            }
          }

          BrowserEvent getCurrent() => events.lastWhere(
            (event) =>
                event.kind == BrowserEventKind.ready ||
                event.kind == BrowserEventKind.navigating,
          );
          Future<void> action(String action) async {
            final current = getCurrent();
            await browser.exerciseFixture(
              session: current.session,
              document: current.document,
              action: action,
            );
          }

          await active.initialize();
          await active.open();
          await waitFor(
            () => active.view.ready,
            'fixture did not become ready',
          );
          await active.inspect();
          expect(active.view.origin, fixture.initialUri.origin);
          expect(fixture.hits['fixture'], greaterThan(0));
          expect(fixture.hits['frame'], greaterThan(0));
          expect(leases.isBusy, isTrue);

          final businessDocument = getCurrent();
          final identityOrigin = fixture.authenticationOrigins.first.origin;
          final authStart = events.length;
          await action('authentication');
          await waitFor(() {
            final current = getCurrent();
            return events.length > authStart &&
                current.kind == BrowserEventKind.ready &&
                current.origin == identityOrigin &&
                fixture.hits['sso']! > 0 &&
                fixture.hits['authLogin']! > 0 &&
                fixture.hits['gateway']! > 0 &&
                fixture.hits['authReady']! > 0;
          }, 'same-window synthetic authentication did not finish');
          expect(active.view.origin, identityOrigin);
          expect(active.view.ready, isFalse);
          await expectLater(
            browser.inspect(
              session: businessDocument.session,
              document: businessDocument.document,
            ),
            throwsA(
              isA<AppFailure>().having(
                (error) => error.code,
                'code',
                FailureCode.staleResult,
              ),
            ),
          );

          var restoreStart = events.length;
          await active.navigateInitial();
          await waitFor(() {
            final current = getCurrent();
            return active.view.ready &&
                events
                    .skip(restoreStart)
                    .any(
                      (event) =>
                          event.kind == BrowserEventKind.ready &&
                          event.origin == fixture.initialUri.origin,
                    ) &&
                current.kind == BrowserEventKind.ready &&
                current.origin == fixture.initialUri.origin;
          }, 'business document did not recover after authentication');

          final blockedBeforeRedirect = events
              .where((event) => event.kind == BrowserEventKind.blocked)
              .length;
          await action('redirectDenied');
          await waitFor(
            () =>
                events
                        .where(
                          (event) => event.kind == BrowserEventKind.blocked,
                        )
                        .length >
                    blockedBeforeRedirect &&
                fixture.hits['redirectDenied']! > 0,
            'cross-origin redirect did not emit a retained-control denial',
          );
          await Future<void>.delayed(const Duration(milliseconds: 350));
          expect(fixture.hits['denied'], 0);

          // The cancelled redirect did not replace the visible business DOM.
          // Existing and newly created child frames must still work without
          // forcing a reload of that document.
          await waitFor(
            () => active.view.ready,
            'cancelled redirect did not restore the visible document facts',
          );
          final frameNextBefore = fixture.hits['frameNext']!;
          await action('frameNext');
          await waitFor(
            () => fixture.hits['frameNext']! > frameNextBefore,
            'existing frame was invalidated by an uncommitted navigation',
          );
          final nestedBefore = fixture.hits['frameNext']!;
          final lateBefore = fixture.hits['frameLate']!;
          await action('frameLate');
          await waitFor(
            () =>
                fixture.hits['frameLate']! > lateBefore &&
                fixture.hits['frameNext']! > nestedBefore,
            'late root/child frames did not inherit the visible document',
          );
          await active.inspect();
          expect(active.view.ready, isTrue);

          restoreStart = events.length;
          await active.navigateInitial();
          await waitFor(() {
            final current = getCurrent();
            return active.view.ready &&
                events
                    .skip(restoreStart)
                    .any(
                      (event) =>
                          event.kind == BrowserEventKind.ready &&
                          event.origin == fixture.initialUri.origin,
                    ) &&
                current.kind == BrowserEventKind.ready &&
                current.origin == fixture.initialUri.origin;
          }, 'business document did not recover after blocked redirect');

          for (final probe in [
            'frameDenied',
            'popup',
            'permission',
            'external',
            'topDenied',
            'download',
          ]) {
            final before = events
                .where((event) => event.kind == BrowserEventKind.blocked)
                .length;
            await action(probe);
            await waitFor(
              () =>
                  events
                      .where((event) => event.kind == BrowserEventKind.blocked)
                      .length >
                  before,
              '$probe did not emit a retained-control denial',
            );
            await Future<void>.delayed(const Duration(milliseconds: 350));
            expect(
              fixture.hits['denied'],
              0,
              reason: '$probe reached the forbidden origin',
            );
            await active.navigateInitial();
            await waitFor(
              () => active.view.ready,
              'fixture did not recover after $probe',
            );
          }
          expect(fixture.hits['download'], greaterThan(0));

          final previous = getCurrent();
          await action('sameDocument');
          await waitFor(
            () =>
                active.view.ready && getCurrent().document > previous.document,
            'same-document transition retained an old token',
          );
          await expectLater(
            browser.inspect(
              session: previous.session,
              document: previous.document,
            ),
            throwsA(
              isA<AppFailure>().having(
                (e) => e.code,
                'code',
                FailureCode.staleResult,
              ),
            ),
          );
          final sameDocument = getCurrent();
          await action('nextDocument');
          await waitFor(
            () =>
                active.view.ready &&
                getCurrent().document > sameDocument.document,
            'new document did not revoke the previous token',
          );
          expect(fixture.hits['next'], greaterThan(0));

          // Real native WM_CLOSE must join the same C2 drain/delete path.
          final closingSession = getCurrent().session;
          await action('userClose');
          await waitFor(
            () => active.view.phase == ObservationPhase.idle,
            'user window close did not finish actual cleanup',
          );
          expect(await browser.drained(closingSession), isTrue);
          expect(
            await Directory(
              p.join(owner.path, 'observation_v1'),
            ).list().isEmpty,
            isTrue,
          );
          await coordinator.shutdown();
          await _verifyParentCrash(
            root: root,
            browser: browser,
            target: ObservationTarget.fixture(
              fixture.initialUri,
              additionalOrigins: fixture.authenticationOrigins,
            ),
          );
          expect(leases.isBusy, isFalse);

          // A sealed unclaimed observation simulates an interrupted parent.
          // Restart recovery reopens this actual WebView profile without navigating.
          await active.shutdown();
          final abandoned = ObservationAssets(owner);
          final profile = await abandoned.register();
          final fixtureHits = fixture.hits['fixture'];
          coordinator = ObservationCoordinator(
            browser: trackedBrowser,
            assets: ObservationAssets(owner),
            leases: leases,
            target: ObservationTarget.fixture(
              fixture.initialUri,
              additionalOrigins: fixture.authenticationOrigins,
            ),
          );
          await coordinator.initialize();
          expect(coordinator.view.phase, ObservationPhase.idle);
          expect(await Directory(profile).exists(), isFalse);
          expect(
            fixture.hits['fixture'],
            fixtureHits,
            reason: 'startup recovery must remain blank',
          );

          // Cancel immediately while environment/controller creation is pending.
          trackedBrowser.openEntered = Completer<void>();
          final opening = coordinator.open();
          final openingResult = opening.catchError((Object error) {
            if (error is! AppFailure || error.code != FailureCode.closed) {
              throw error;
            }
          });
          await trackedBrowser.openEntered!.future;
          expect(trackedBrowser.openCompleted, isFalse);
          await coordinator.closeSession();
          await openingResult;
          expect(coordinator.view.phase, ObservationPhase.idle);
          expect(
            await Directory(
              p.join(owner.path, 'observation_v1'),
            ).list().isEmpty,
            isTrue,
          );
        } finally {
          await coordinator?.shutdown();
          await subscription.cancel();
          await browser.dispose();
          await fixture.close();
          await owner.release();
          final resolved = p.windows.normalize(
            await root.resolveSymbolicLinks(),
          );
          final temp = p.windows.normalize(
            await Directory.systemTemp.resolveSymbolicLinks(),
          );
          expect(p.windows.isWithin(temp, resolved), isTrue);
          expect(p.basename(resolved), startsWith('ustc_m1_native_test_'));
          await Directory(resolved).delete(recursive: true);
        }
      });
    },
  );
}

Future<void> _verifyParentCrash({
  required Directory root,
  required ObservationBrowserPort browser,
  required ObservationTarget target,
}) async {
  final hostPath = p.join(root.path, 'crash-owned');
  final appRoot = p.normalize(
    p.join(
      p.dirname(Platform.resolvedExecutable),
      '..',
      '..',
      '..',
      '..',
      '..',
    ),
  );
  expect(await File(p.join(appRoot, 'pubspec.yaml')).exists(), isTrue);
  final config =
      jsonDecode(
            await File(
              p.join(appRoot, '.dart_tool', 'package_config.json'),
            ).readAsString(),
          )
          as Map<String, dynamic>;
  final flutterRoot = Directory.fromUri(
    Uri.parse(config['flutterRoot'] as String),
  ).path;
  final compile = await Process.run(
    p.join(flutterRoot, 'bin', 'flutter.bat'),
    [
      'build',
      'windows',
      '--no-pub',
      '--target=tool/observation_crash_host.dart',
    ],
    workingDirectory: appRoot,
    runInShell: true,
  ).timeout(const Duration(minutes: 2));
  expect(
    compile.exitCode,
    0,
    reason: 'independent blank crash host compilation',
  );
  final compiled = Directory(
    p.join(appRoot, 'build', 'windows', 'x64', 'runner', 'Release'),
  );
  final bundle = Directory(p.join(appRoot, 'build', 'm1_crash_host_bundle'));
  expect(p.isWithin(appRoot, compiled.path), isTrue);
  expect(p.isWithin(appRoot, bundle.path), isTrue);
  await bundle.create(recursive: true);
  await for (final entry in compiled.list(
    recursive: true,
    followLinks: false,
  )) {
    final destination = p.join(
      bundle.path,
      p.relative(entry.path, from: compiled.path),
    );
    if (entry is Directory) {
      await Directory(destination).create(recursive: true);
    } else if (entry is File) {
      await File(destination).parent.create(recursive: true);
      await entry.copy(destination);
    } else {
      fail('test build bundle contains an unexpected link');
    }
  }
  final executable = p.join(bundle.path, 'ustc_assistant_m0.exe');
  final child = await Process.start(
    executable,
    const [],
    workingDirectory: p.dirname(executable),
    environment: {'USTC_M1_CRASH_HOST_PATH': hostPath},
  );
  final stdoutDrain = child.stdout.listen((_) {});
  final stderrDrain = child.stderr.listen((_) {});
  var exited = false;
  final exit = child.exitCode.then((code) {
    exited = true;
    return code;
  });
  DemoDirectory? owner;
  ObservationCoordinator? observer;
  try {
    final elapsed = Stopwatch()..start();
    while (!await File(p.join(hostPath, 'probe-ready')).exists()) {
      if (exited || elapsed.elapsed > const Duration(seconds: 30)) {
        fail('synthetic crash host did not publish readiness');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await expectLater(
      DemoDirectory.acquire(hostPath),
      throwsA(
        isA<AppFailure>().having(
          (e) => e.code,
          'code',
          FailureCode.ownerConflict,
        ),
      ),
    );
    expect(child.kill(ProcessSignal.sigkill), isTrue);
    await exit.timeout(const Duration(seconds: 10));
    owner = await DemoDirectory.acquire(hostPath);
    final ledger = Directory(p.join(owner.path, 'observation_v1'));
    final registered = await ledger.list(followLinks: false).toList();
    expect(registered.whereType<Directory>(), hasLength(1));
    expect(
      registered.whereType<File>().where(
        (entry) => entry.path.endsWith('.pending'),
      ),
      hasLength(1),
    );
    observer = ObservationCoordinator(
      browser: browser,
      assets: ObservationAssets(owner),
      leases: WorkLeasePool(),
      target: target,
    );
    await observer.initialize();
    expect(
      observer.view.phase,
      ObservationPhase.idle,
      reason: 'actual killed parent must recover without claiming its profile',
    );
    expect(await ledger.list().isEmpty, isTrue);
  } finally {
    if (!exited) child.kill(ProcessSignal.sigkill);
    await exit.timeout(const Duration(seconds: 10));
    await observer?.shutdown();
    await owner?.release();
    await stdoutDrain.cancel();
    await stderrDrain.cancel();
  }
}

final class _TrackedBrowser implements ObservationBrowserPort {
  _TrackedBrowser(this.delegate);
  final ObservationBrowserPort delegate;
  Completer<void>? openEntered;
  bool openCompleted = false;
  @override
  Stream<BrowserEvent> get events => delegate.events;
  @override
  Future<void> open({
    required int session,
    required String profilePath,
    required ObservationTarget target,
    bool recoveryOnly = false,
  }) async {
    openCompleted = false;
    final opening = delegate.open(
      session: session,
      profilePath: profilePath,
      target: target,
      recoveryOnly: recoveryOnly,
    );
    if (openEntered?.isCompleted == false) openEntered!.complete();
    try {
      await opening;
    } finally {
      openCompleted = true;
    }
  }

  @override
  Future<void> close(int session) => delegate.close(session);
  @override
  Future<bool> drained(int session) => delegate.drained(session);
  @override
  Future<BrowserInspection> inspect({
    required int session,
    required int document,
  }) => delegate.inspect(session: session, document: document);
  @override
  Future<void> navigateInitial(int session) =>
      delegate.navigateInitial(session);
  @override
  Future<void> navigateJwPage({
    required int session,
    required int document,
    required JwObservationPage page,
  }) =>
      delegate.navigateJwPage(session: session, document: document, page: page);
}
