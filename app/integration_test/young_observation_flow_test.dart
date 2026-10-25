import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
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
import 'package:ustc_assistant_m0/source/young_observation_contract.dart';

import 'support/young_observation_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ustc_assistant/observation_v1');
  Matcher failure(FailureCode code) =>
      throwsA(isA<AppFailure>().having((e) => e.code, 'code', code));
  Matcher nativeFailure(String code) => throwsA(
    isA<PlatformException>()
        .having((e) => e.code, 'code', 'app_failure')
        .having((e) => e.details, 'details', code),
  );

  testWidgets(
    'Young redirects, closed metadata, shared lease and real deletion',
    (tester) async {
      await tester.runAsync(() async {
        final fixture = await YoungObservationFixture.start();
        final root = await Directory.systemTemp.createTemp(
          'ustc_m2_observation_',
        );
        final owner = await DemoDirectory.acquire(p.join(root.path, 'owned'));
        final browser = NativeObservationBrowser(
          fixtureDeniedUri: fixture.deniedUri,
        );
        final events = <BrowserEvent>[];
        final subscription = browser.events.listen(events.add);
        final leases = WorkLeasePool();
        final young = ObservationCoordinator(
          browser: browser,
          assets: ObservationAssets.young(owner),
          leases: leases,
          target: ObservationTarget.youngFixture(
            fixture.initialUri,
            additionalOrigins: [fixture.gatewayOrigin, fixture.identityOrigin],
          ),
        );
        final jw = ObservationCoordinator(
          browser: browser,
          assets: ObservationAssets(owner),
          leases: leases,
          target: ObservationTarget.fixture(fixture.initialUri),
        );
        final ledger = Directory(p.join(owner.path, 'young_observation_v1'));
        final jwLedger = Directory(p.join(owner.path, 'observation_v1'));
        Future<void> waitFor(bool Function() condition, String reason) async {
          final deadline = DateTime.now().add(const Duration(seconds: 25));
          while (!condition()) {
            if (DateTime.now().isAfter(deadline)) {
              fail(
                '$reason; phase=${young.view.phase.name}; '
                'failure=${young.view.failure?.name}',
              );
            }
            await Future<void>.delayed(const Duration(milliseconds: 40));
          }
        }

        BrowserEvent latestReady() =>
            events.lastWhere((event) => event.kind == BrowserEventKind.ready);
        Future<void> inspectAfterHistoryNotifications() async {
          final deadline = DateTime.now().add(const Duration(seconds: 25));
          while (DateTime.now().isBefore(deadline)) {
            if (young.view.ready) {
              try {
                await young.inspectYoungPage();
                if (young.view.ready &&
                    young.view.youngInspection?.ready == true) {
                  return;
                }
              } on AppFailure catch (error) {
                // WebView2 can emit SourceChanged and then HistoryChanged for
                // one pushState. Keep rejecting stale reads while they settle.
                if (error.code != FailureCode.staleResult) rethrow;
              }
            }
            await Future<void>.delayed(const Duration(milliseconds: 40));
          }
          fail('same document history did not produce a current ready summary');
        }

        try {
          await young.initialize();
          await jw.initialize();
          await young.open();
          await waitFor(
            () => young.view.ready,
            'Young initial document not ready',
          );
          final initial = latestReady();
          await young.inspectYoungPage();
          expect(young.view.youngInspection?.surface, YoungSurface.application);
          expect(young.view.youngInspection?.tables, 1);
          expect(young.view.youngInspection?.calendarRoots, 1);
          expect(young.view.youngInspection?.paginationControls, 1);
          final summary = jsonEncode(young.view.youngInspection!.safeSummary());
          expect(summary, isNot(contains('SYNTHETIC_PRIVATE')));
          expect(summary, isNot(contains('synthetic-cookie')));
          expect(summary, isNot(contains('127.0.0.1')));
          expect(
            young.view.youngInspection!.safeSummary()['sourceAvailable'],
            false,
          );
          expect(young.probeView.available, false);
          final before = await ledger
              .list()
              .map((entry) => entry.path)
              .toList();
          expect(before.length, 2);
          await expectLater(jw.open(), failure(FailureCode.busy));
          expect(await jwLedger.list().isEmpty, true);
          expect(() => leases.acquire(), failure(FailureCode.busy));
          expect(
            await ledger.list().map((entry) => entry.path).toList(),
            unorderedEquals(before),
          );
          for (final call in [
            ('readJwProbe', <String, Object>{'operation': 1}),
            ('advanceJwLogin', <String, Object>{'operation': 1}),
            ('navigateJwPage', <String, Object>{'page': 'courseTable'}),
          ]) {
            await expectLater(
              channel.invokeMethod<void>(call.$1, {
                'session': initial.session,
                'document': initial.document,
                ...call.$2,
              }),
              nativeFailure('invalidSnapshot'),
            );
          }
          await expectLater(
            channel.invokeMethod<Object>('inspectYoungPage', {
              'session': initial.session,
              'document': initial.document,
              'extra': 'synthetic-only',
            }),
            nativeFailure('invalidSnapshot'),
          );
          await browser.exerciseFixture(
            session: initial.session,
            document: initial.document,
            action: 'authentication',
          );
          await waitFor(
            () => events.any(
              (event) =>
                  event.kind == BrowserEventKind.ready &&
                  event.origin == fixture.identityOrigin.origin,
            ),
            'identity hop not ready',
          );
          expect(young.view.youngInspection, isNull);
          expect(young.view.ready, isFalse);
          await young.inspectYoungPage();
          expect(
            young.view.youngInspection?.surface,
            YoungSurface.authentication,
          );
          expect(
            young.view.youngInspection?.tables,
            0,
            reason: 'authentication origin DOM must not be inspected',
          );
          expect(young.view.youngInspection?.passwordInputs, 0);
          final authentication = latestReady();
          await browser.exerciseFixture(
            session: authentication.session,
            document: authentication.document,
            action: 'submitAuthForm',
          );
          await waitFor(
            () => fixture.schedulePages > 0 && young.view.ready,
            'return through gateway and relay not ready',
          );
          expect(fixture.gatewayStarts, 1);
          expect(fixture.gatewayFinishes, 1);
          expect(fixture.identityPages, greaterThanOrEqualTo(1));
          await young.inspectYoungPage();
          expect(young.view.youngInspection?.tables, 2);
          expect(young.view.youngInspection?.calendarRoots, 2);
          final current = latestReady();
          await browser.exerciseFixture(
            session: current.session,
            document: current.document,
            action: 'sameDocument',
          );
          await waitFor(
            () => young.documentGeneration > current.document,
            'same document history did not invalidate result',
          );
          expect(young.view.youngInspection, isNull);
          await expectLater(
            browser.inspectYoungPage(
              session: current.session,
              document: current.document,
            ),
            failure(FailureCode.staleResult),
          );
          await inspectAfterHistoryNotifications();
          final activeDocument = young.documentGeneration;
          await browser.exerciseFixture(
            session: current.session,
            document: activeDocument,
            action: 'topDenied',
          );
          await waitFor(
            () => young.view.diagnostics.any(
              (diagnostic) =>
                  diagnostic.code == BrowserDiagnosticCode.topNavigationBlocked,
            ),
            'denied top navigation was not classified',
          );
          expect(fixture.deniedHits, 0);
          await browser.exerciseFixture(
            session: current.session,
            document: young.documentGeneration,
            action: 'userClose',
          );
          await waitFor(
            () => young.view.phase == ObservationPhase.idle,
            'user close did not drain and clean',
          );
          expect(young.view.youngInspection, isNull);
          expect(leases.isBusy, false);
          expect(await ledger.list().isEmpty, true);
          for (final path in before) {
            expect(
              await FileSystemEntity.type(path),
              FileSystemEntityType.notFound,
            );
          }
          await young.open();
          await waitFor(() => young.view.ready, 'Young second open not ready');
          final after = await ledger.list().map((entry) => entry.path).toList();
          expect(after.toSet().intersection(before.toSet()), isEmpty);
          await young.closeSession();
          expect(await ledger.list().isEmpty, true);
          await jw.open();
          await waitFor(
            () => jw.view.ready,
            'JW fixture after Young not ready',
          );
          await young.shutdown();
          expect(jw.view.phase, ObservationPhase.open);
          expect(leases.isBusy, true);
          expect(await jwLedger.list().isEmpty, false);
          await jw.closeSession();
          expect(await jwLedger.list().isEmpty, true);
        } finally {
          await young.shutdown();
          await jw.shutdown();
          await subscription.cancel();
          await browser.dispose();
          await owner.release();
          await fixture.close();
          // This fixture owns a fresh temp root; no business/profile assets read.
          expect(p.basename(root.path), startsWith('ustc_m2_observation_'));
          expect(
            p.isWithin(Directory.systemTemp.absolute.path, root.absolute.path),
            true,
          );
          await root.delete(recursive: true);
        }
      });
    },
  );

  testWidgets('native Young production targets cannot be broadened', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('ustc_m2_target_');
      final target = ObservationTarget.young();
      final base = <String, Object>{
        'session': 90001,
        'profilePath': p.join(root.path, 'never-opened'),
        'initialUrl': target.initialUri.toString(),
        'allowedOrigins': target.allowedOrigins,
        'source': 'young',
        'testMode': false,
        'recoveryOnly': false,
      };
      try {
        for (final changed in <Map<String, Object>>[
          {
            'allowedOrigins': [
              ...target.allowedOrigins,
              'https://vendor.invalid',
            ],
          },
          {'initialUrl': 'https://young.ustc.edu.cn/main.htm'},
          {'source': 'jw'},
          {'source': 'unknown'},
          {'fixtureDeniedUrl': 'http://127.0.0.1:8100/denied'},
        ]) {
          await expectLater(
            channel.invokeMethod<void>('open', {...base, ...changed}),
            nativeFailure('invalidSnapshot'),
          );
          expect(
            await root.list().isEmpty,
            true,
            reason: 'rejected target must not create a profile or navigate',
          );
        }
      } finally {
        expect(p.basename(root.path), startsWith('ustc_m2_target_'));
        expect(
          p.isWithin(Directory.systemTemp.absolute.path, root.absolute.path),
          true,
        );
        await root.delete(recursive: true);
      }
    });
  });
}
