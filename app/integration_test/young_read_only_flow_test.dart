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

import 'support/young_read_only_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ustc_assistant/observation_v1');

  testWidgets(
    'Young native projection and fresh fixed GET response association',
    (tester) async {
      await tester.runAsync(() async {
        final fixture = await YoungReadOnlyFixture.start();
        final temp = await Directory.systemTemp.createTemp('ustc_m2_readonly_');
        final owner = await DemoDirectory.acquire(p.join(temp.path, 'owned'));
        final browser = NativeObservationBrowser();
      final events = <BrowserEvent>[];
      final subscription = browser.events.listen(events.add);
        final leases = WorkLeasePool();
        final young = ObservationCoordinator(
          browser: browser,
          assets: ObservationAssets.young(owner),
          leases: leases,
          target: ObservationTarget.youngFixture(fixture.initialUri),
        );
        Future<void> waitReady() async {
          final elapsed = Stopwatch()..start();
          while (!young.view.ready) {
            if (elapsed.elapsed > const Duration(seconds: 25)) {
              fail('Young fixture readiness timed out');
            }
            await Future<void>.delayed(const Duration(milliseconds: 40));
          }
        }

        Future<void> action(String action) => browser.exerciseFixture(
          session: young.readOnlyInspection!.session,
          document: young.documentGeneration,
          action: action,
        );
        Future<void> waitSummary(bool Function() condition) async {
          final elapsed = Stopwatch()..start();
          while (true) {
            await young.refreshReadOnlyInspection();
            if (condition()) return;
            if (elapsed.elapsed > const Duration(seconds: 15)) {
              fail(
                'Young response association timed out; '
                'accepted=${young.readOnlyInspection?.accepted}, '
                'rejected=${young.readOnlyInspection?.rejected}, '
                'reason=${young.readOnlyInspection?.lastRejection}',
              );
            }
            await Future<void>.delayed(const Duration(milliseconds: 40));
          }
        }

        try {
          await young.initialize();
          await young.open();
          await waitReady();
        final initial = events.lastWhere((event) => event.kind == BrowserEventKind.ready);
        await browser.exerciseFixture(
          session: initial.session,
          document: young.documentGeneration,
          action: 'youngLate',
        );
        await Future<void>.delayed(const Duration(milliseconds: 80));
          await young.startReadOnlyInspection();
          final stamp = young.readOnlyInspection!;
          expect(
            await channel.invokeMethod<bool>('checkYoungProjectionFixture', {
              'session': stamp.session,
              'document': stamp.document,
            }),
            true,
          );
          expect(young.readOnlyInspection!.accepted, 0);
        await Future<void>.delayed(const Duration(seconds: 3));
        await young.refreshReadOnlyInspection();
        expect(young.readOnlyInspection!.accepted, 0);
          expect(() => leases.acquire(), throwsA(isA<AppFailure>()));

          for (final item in [
            ('youngReadProfile', 1),
            ('youngReadSchedule', 2),
            ('youngReadActivities', 3),
            ('youngConcurrent', 5),
          ]) {
            await action(item.$1);
            await waitSummary(
              () => young.readOnlyInspection!.accepted == item.$2,
            );
          }
          final dto = young.readOnlyInspection!;
          expect(dto.profile.loginCode, 'string');
          expect(dto.profile.username, 'string');
          expect(dto.schedule.count, 2);
          expect(dto.schedule.observations, 3);
          expect(dto.activities.count, 1);
          final summary = jsonEncode(dto.safeSummary());
          for (final secret in [
            'SYNTHETIC_',
            '127.0.0.1',
            'X-Access-Token',
            'session',
            'operation',
            '2026-10-11',
          ]) {
            expect(summary, isNot(contains(secret)));
          }
          expect(dto.safeSummary()['identity'], 'notValidated');
          expect(dto.safeSummary()['sourceAvailable'], false);

          for (final item in [
            ('youngWrongMethod', 'method'),
            ('youngRedirect', 'redirect'),
            ('youngFrame', 'frame'),
            ('youngMalformed', 'body'),
            ('youngSecret', 'body'),
            ('youngOversizedRedirect', 'limit'),
          ]) {
            final prior = young.readOnlyInspection!.rejected;
            await action(item.$1);
            await waitSummary(() => young.readOnlyInspection!.rejected > prior);
            expect(young.readOnlyInspection!.lastRejection, item.$2);
            expect(young.readOnlyInspection!.accepted, 5);
          }

          await action('youngCache');
          await waitSummary(
            () =>
                young.readOnlyInspection!.accepted == 6 &&
                young.readOnlyInspection!.lastRejection == 'cache',
          );
          final beforeWorker = young.readOnlyInspection!.accepted;
          await action('youngWorker');
          await Future<void>.delayed(const Duration(milliseconds: 400));
          await young.refreshReadOnlyInspection();
          expect(young.readOnlyInspection!.accepted, beforeWorker);
          await action('youngServiceWorker');
          await waitSummary(
            () => young.readOnlyInspection!.lastRejection == 'worker',
          );
          expect(young.readOnlyInspection!.accepted, beforeWorker);

          await action('youngLate');
          await young.stopReadOnlyInspection();
          expect(young.readOnlyInspection!.listening, false);
          await young.startReadOnlyInspection();
          final next = young.readOnlyInspection!;
          expect(next.operation, greaterThan(stamp.operation));
          await Future<void>.delayed(const Duration(seconds: 3));
          await young.refreshReadOnlyInspection();
          expect(young.readOnlyInspection!.accepted, 0);
          expect(young.readOnlyInspection!.schedule.observations, 0);

          await action('sameDocument');
          final deadline = Stopwatch()..start();
          while (young.readOnlyInspection != null || !young.view.ready) {
          if (deadline.elapsed > const Duration(seconds: 25)) {
              fail('route invalidation timed out');
          }
            await Future<void>.delayed(const Duration(milliseconds: 40));
          }
          await expectLater(
            browser.readYoungReadOnly(
              session: next.session,
              document: next.document,
              operation: next.operation,
            ),
            throwsA(
              isA<AppFailure>().having(
                (e) => e.code,
                'code',
                FailureCode.staleResult,
              ),
            ),
          );
          await young.startReadOnlyInspection();
          await action('youngReadSchedule');
          await waitSummary(() => young.readOnlyInspection!.accepted == 1);
        await action('youngLate');
          await young.closeSession();
          expect(young.view.phase, ObservationPhase.idle);
          expect(young.readOnlyInspection, isNull);
          expect(leases.isBusy, false);
          final ledger = Directory(p.join(owner.path, 'young_observation_v1'));
          expect(await ledger.list().isEmpty, true);
        } finally {
          await young.shutdown();
        await subscription.cancel();
          await browser.dispose();
          await owner.release();
          await fixture.close();
          if (await temp.exists()) await temp.delete(recursive: true);
        }
      });
    },
  );
}
