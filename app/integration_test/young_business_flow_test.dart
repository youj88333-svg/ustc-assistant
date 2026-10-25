import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/jobs/observation_coordinator.dart';
import 'package:ustc_assistant_m0/platform/demo_directory.dart';
import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';
import 'package:ustc_assistant_m0/platform/observation_assets.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';
import 'package:ustc_assistant_m0/source/young_active_contract.dart';

import 'support/young_business_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Young compiled fixed steps, complete pages and date coverage', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final fixture = await YoungBusinessFixture.start();
      final temp = await Directory.systemTemp.createTemp('ustc_m2_active_');
      final owner = await DemoDirectory.acquire(p.join(temp.path, 'owned'));
      final browser = NativeObservationBrowser();
      final leases = WorkLeasePool();
      final young = ObservationCoordinator(
        browser: browser,
        assets: ObservationAssets.young(owner),
        leases: leases,
        target: ObservationTarget.youngFixture(fixture.initialUri),
        probeTimeout: const Duration(seconds: 8),
      );
      Future<void> ready() async {
        final clock = Stopwatch()..start();
        while (!young.view.ready) {
          if (clock.elapsed > const Duration(seconds: 20)) {
            fail('Young fixture not ready');
          }
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
      }

      Future<void> open() async {
        await young.open();
        await ready();
        fixture.profiles = 0;
      }

      Future<void> calendarRequested(int previous) async {
        final deadline = Stopwatch()..start();
        while (fixture.calendarRequests == previous) {
          if (deadline.elapsed > const Duration(seconds: 15)) {
            fail('Calendar request not observed');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      Future<void> idleHistory(int session, String action) async {
        final document = young.documentGeneration;
        await browser.exerciseFixture(
          session: session,
          document: document,
          action: action,
        );
        final deadline = Stopwatch()..start();
        while (young.documentGeneration == document || !young.view.ready) {
          if (deadline.elapsed > const Duration(seconds: 10)) {
            fail('Idle history guard did not advance document');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      var scenario = 'initial pages';
      try {
        await young.initialize();
        await open();
        await young.inspectYoungPage();
        final initial = young.view.youngInspection!;
        expect(
          await const MethodChannel(
            'ustc_assistant/observation_v1',
          ).invokeMethod<bool>('checkYoungProjectionFixture', {
            'session': initial.session,
            'document': initial.document,
          }),
          true,
        );
        await young.probeYoungActivities('FIXTURE_ACCOUNT');
        expect(young.businessView.safeSummary(), containsPair('phase', 'done'));
        expect(
          young.businessView.identity,
          YoungBusinessIdentity.candidateMatches,
        );
        expect(young.businessView.activities, 11);
        expect(young.businessView.activityPages, 2);
        expect(young.businessView.identityReads, 2);
        expect(fixture.activityRequests, 2);
        expect(young.businessView.safeSummary()['sourceAvailable'], false);
        final summary = jsonEncode(young.businessView.safeSummary());
        for (final private in [
          'FIXTURE_ACCOUNT',
          'Synthetic',
          'activity-0',
          'UNSELECTED_PRIVATE',
          '127.0.0.1',
        ]) {
          expect(summary, isNot(contains(private)));
        }
        await young.probeYoungCalendar(
          expectedAccountCode: 'FIXTURE_ACCOUNT',
          firstDay: DateTime.utc(2026, 10, 10),
          lastDay: DateTime.utc(2026, 10, 11),
        );
        expect(young.businessView.phase, YoungBusinessPhase.done);
        expect(young.businessView.calendarRows, 2);
        expect(young.businessView.linkedSchedules, 1);
        expect(young.businessView.excludedSchedules, 1);
        expect(young.businessView.days, 2);
        expect(young.businessView.calendarPages, 2);
        expect(() => leases.acquire(), throwsA(isA<AppFailure>()));

        await young.navigateYoungPage(YoungBusinessPage.activities);
        await ready();
        await young.probeYoungActivities('FIXTURE_ACCOUNT');
        expect(young.businessView.phase, YoungBusinessPhase.done);
        await young.closeSession();
        final free = leases.acquire();
        free.release();
        for (final mode in [
          'identityChange',
          'totalChange',
          'duplicate',
          'secret',
        ]) {
          scenario = mode;
          fixture.mode = mode;
          await open();
          await young.probeYoungActivities('FIXTURE_ACCOUNT');
          expect(
            young.businessView.phase,
            YoungBusinessPhase.failed,
            reason: mode,
          );
          expect(young.businessView.safeSummary()['sourceAvailable'], false);
          expect(young.view.ready, false);
          final free = leases.acquire();
          free.release();
        }
        fixture.mode = 'wrongDay';
        scenario = 'wrongDay';
        await open();
        await young.probeYoungCalendar(
          expectedAccountCode: 'FIXTURE_ACCOUNT',
          firstDay: DateTime.utc(2026, 10, 11),
          lastDay: DateTime.utc(2026, 10, 11),
        );
        expect(young.businessView.phase, YoungBusinessPhase.failed);
        fixture.mode = 'late';
        scenario = 'iframe';
        await open();
        await young.inspectYoungPage();
        final frameSession = young.view.youngInspection!.session;
        final beforeFrameRead = fixture.calendarRequests;
        final frameWork = young.probeYoungCalendar(
          expectedAccountCode: 'FIXTURE_ACCOUNT',
          firstDay: DateTime.utc(2026, 10, 10),
          lastDay: DateTime.utc(2026, 10, 10),
        );
        await calendarRequested(beforeFrameRead);
        await browser.exerciseFixture(
          session: frameSession,
          document: young.documentGeneration,
          action: 'frameNext',
        );
        await frameWork;
        expect(
          young.businessView.phase,
          YoungBusinessPhase.done,
          reason: jsonEncode(young.businessView.safeSummary()),
        );
        await young.closeSession();
        for (final action in [
          'youngSameUrlPush',
          'youngSameUrlReplace',
          'youngHistoryBack',
          'youngHistoryForward',
          'youngRouteAfterBody',
        ]) {
          scenario = action;
          await open();
          await young.inspectYoungPage();
          final session = young.view.youngInspection!.session;
          if (action == 'youngHistoryBack' || action == 'youngHistoryForward') {
            await idleHistory(session, 'youngSameUrlPush');
            if (action == 'youngHistoryForward') {
              await idleHistory(session, 'youngHistoryBack');
            }
          }
          final previous = fixture.calendarRequests;
          final routeWork = young.probeYoungCalendar(
            expectedAccountCode: 'FIXTURE_ACCOUNT',
            firstDay: DateTime.utc(2026, 10, 10),
            lastDay: DateTime.utc(2026, 10, 10),
          );
          await calendarRequested(previous);
          await browser.exerciseFixture(
            session: session,
            document: young.documentGeneration,
            action: action,
          );
          await routeWork;
          expect(
            young.businessView.phase,
            YoungBusinessPhase.failed,
            reason: action,
          );
          expect(young.businessView.safeSummary()['sourceAvailable'], false);
          final released = leases.acquire();
          released.release();
        }
        scenario = 'cancel';
        await open();
        final work = young.probeYoungCalendar(
          expectedAccountCode: 'FIXTURE_ACCOUNT',
          firstDay: DateTime.utc(2026, 10, 10),
          lastDay: DateTime.utc(2026, 10, 10),
        );
        final deadline = Stopwatch()..start();
        while (young.businessView.stage != YoungBusinessStage.calendar) {
          if (deadline.elapsed > const Duration(seconds: 10)) {
            fail('Calendar action not started');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        final cancel = young.cancelYoungBusinessProbe();
        expect(() => leases.acquire(), throwsA(isA<AppFailure>()));
        await cancel;
        await work;
        expect(young.businessView.phase, YoungBusinessPhase.failed);
        expect(young.businessView.failure, FailureCode.cancelled);
        final freeAfterCancel = leases.acquire();
        freeAfterCancel.release();
      } catch (_) {
        // Closed metadata only; preserve the primary scenario before a
        // secondary cleanup error can replace its stack in the test harness.
        debugPrint(
          'Synthetic Young scenario: $scenario; observation: '
          '${young.view.phase.name}; ${jsonEncode(young.businessView.safeSummary())}',
        );
        rethrow;
      } finally {
        await young.shutdown();
        await browser.dispose();
        await owner.release();
        await fixture.close();
        await temp.delete(recursive: true);
      }
    });
  });
}
