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

import 'support/auth_redirect_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('HTTPS forms, document upgrades and redirect method semantics', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final fixture = await AuthRedirectFixture.start();
      final root = await Directory.systemTemp.createTemp('ustc_m1_tls_native_');
      final owner = await DemoDirectory.acquire(p.join(root.path, 'owned'));
      final browser = NativeObservationBrowser(
        fixtureDeniedUri: fixture.deniedUri,
        fixtureUpgradeFromOrigin: fixture.plainOrigin,
        fixtureUpgradeToOrigin: fixture.secureOrigin,
        fixtureCertificatePem: fixture.certificatePem,
      );
      final events = <BrowserEvent>[];
      final subscription = browser.events.listen(events.add);
      ObservationCoordinator? coordinator;
      Future<void> waitFor(bool Function() condition, String reason) async {
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (!condition()) {
          if (DateTime.now().isAfter(deadline)) {
            fail(
              '$reason; phase=${coordinator?.view.phase.name}; '
              'failure=${coordinator?.view.failure?.name}',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
      }

      try {
        for (final iframe in [false, true]) {
          fixture.resetObservations();
          events.clear();
          coordinator = ObservationCoordinator(
            browser: browser,
            assets: ObservationAssets(owner),
            leases: WorkLeasePool(),
            target: ObservationTarget.fixture(
              iframe ? fixture.directFrameContainerUri : fixture.directFormUri,
            ),
          );
          final active = coordinator;
          await active.initialize();
          await active.open();
          await waitFor(() => active.view.ready, 'direct HTTPS form not ready');
          if (iframe) {
            await Future<void>.delayed(const Duration(milliseconds: 350));
          }
          final original = events.lastWhere(
            (e) => e.kind == BrowserEventKind.ready,
          );
          await browser.exerciseFixture(
            session: original.session,
            document: original.document,
            action: iframe ? 'submitFrameAuthForm' : 'submitAuthForm',
          );
          await waitFor(
            () => fixture.completeHits > 0,
            'direct upgrade not delivered',
          );
          await Future<void>.delayed(const Duration(milliseconds: 350));
          await active.inspect();
          expect(active.view.origin, fixture.secureOrigin.origin);
          expect(active.view.ready, isTrue);
          expect(fixture.plainHits, 0);
          if (iframe) {
            final current = events.lastWhere(
              (e) => e.kind == BrowserEventKind.ready,
            );
            await browser.exerciseFixture(
              session: current.session,
              document: current.document,
              action: 'frameSecure',
            );
          }
          await active.shutdown();
          coordinator = null;
        }
        for (final iframe in [false, true]) {
          for (final status in [302, 303, 307, 308]) {
            fixture.resetObservations();
            events.clear();
            coordinator = ObservationCoordinator(
              browser: browser,
              assets: ObservationAssets(owner),
              leases: WorkLeasePool(),
              target: ObservationTarget.fixture(
                iframe
                    ? fixture.frameContainerUri(status)
                    : fixture.formUri(status),
              ),
            );
            final active = coordinator;
            await active.initialize();
            await active.open();
            await waitFor(() => active.view.ready, 'HTTPS form not ready');
            // Allow the same-origin child form to finish loading too.
            if (iframe) {
              await Future<void>.delayed(const Duration(milliseconds: 350));
            }
            final original = events.lastWhere(
              (e) => e.kind == BrowserEventKind.ready,
            );
            await browser.exerciseFixture(
              session: original.session,
              document: original.document,
              action: iframe ? 'submitFrameAuthForm' : 'submitAuthForm',
            );
            await waitFor(
              () => fixture.completeHits > 0 && active.view.ready,
              'synthetic authentication redirect did not complete ($status, iframe=$iframe)',
            );
            await active.inspect();
            expect(active.view.origin, fixture.secureOrigin.origin);
            expect(active.view.ready, isTrue);
            expect(
              fixture.plainHits,
              0,
              reason: 'cleartext form request escaped',
            );
            expect(fixture.deniedHits, 0);
            expect(fixture.payloadPreserved, isTrue);
            expect(fixture.statePreserved, isTrue);
            expect(
              fixture.lastGatewayMethod,
              status == 307 || status == 308 ? 'POST' : 'GET',
            );
            if (status == 307 || status == 308) {
              expect(fixture.gatewayPayloadPreserved, isTrue);
            }
            expect(
              active.view.diagnostics.any(
                (d) => d.code == BrowserDiagnosticCode.insecureDocumentUpgraded,
              ),
              isTrue,
            );
            // Emit only categories of this fixture's synthetic headers/cookie.
            // This deliberately distinguishes browser behaviour from the
            // fixture-only HttpClient tests.
            // ignore: avoid_print
            print(
              'synthetic redirect status=$status iframe=$iframe '
              'relayOrigin=${fixture.relayOriginCategory} '
              'gatewayOrigin=${fixture.gatewayOriginCategory} '
              'relayCookie=${fixture.relayCookiePresent} '
              'gatewayCookie=${fixture.gatewayCookiePresent}',
            );
            await active.closeSession();
            expect(active.view.phase, ObservationPhase.idle);
            await active.shutdown();
            coordinator = null;
          }
        }
        // A different fresh certificate must not authorize this TLS endpoint.
        final other = await AuthRedirectFixture.start();
        final rejectedBrowser = NativeObservationBrowser(
          fixtureUpgradeFromOrigin: fixture.plainOrigin,
          fixtureUpgradeToOrigin: fixture.secureOrigin,
          fixtureCertificatePem: other.certificatePem,
        );
        final rejectedEvents = <BrowserEvent>[];
        final rejectedSubscription = rejectedBrowser.events.listen(
          rejectedEvents.add,
        );
        fixture.resetObservations();
        coordinator = ObservationCoordinator(
          browser: rejectedBrowser,
          assets: ObservationAssets(owner),
          leases: WorkLeasePool(),
          target: ObservationTarget.fixture(fixture.initialUri),
        );
        try {
          await coordinator.initialize();
          try {
            await coordinator.open();
          } on AppFailure catch (error) {
            expect(error.code, FailureCode.sourceFailed);
          }
          await waitFor(
            () => rejectedEvents.any((e) => e.kind == BrowserEventKind.failed),
            'wrong certificate was not rejected',
          );
          expect(
            rejectedEvents.any((e) => e.kind == BrowserEventKind.ready),
            isFalse,
          );
          expect(fixture.plainHits, 0);
          expect(fixture.relayHits, 0);
          expect(fixture.completeHits, 0);
          await coordinator.shutdown();
          coordinator = null;
        } finally {
          await rejectedSubscription.cancel();
          await rejectedBrowser.dispose();
          await other.close();
        }
      } finally {
        await coordinator?.shutdown();
        await subscription.cancel();
        await browser.dispose();
        await fixture.close();
        await owner.release();
        await _removeRoot(root);
      }
    });
  });
}

Future<void> _removeRoot(Directory root) async {
  final resolved = p.windows.normalize(await root.resolveSymbolicLinks());
  final temp = p.windows.normalize(
    await Directory.systemTemp.resolveSymbolicLinks(),
  );
  expect(p.windows.isWithin(temp, resolved), isTrue);
  expect(p.basename(resolved), startsWith('ustc_m1_tls_native_'));
  await Directory(resolved).delete(recursive: true);
}
