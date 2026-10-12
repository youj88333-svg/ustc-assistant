import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/app/demo_runtime.dart';
import 'package:ustc_assistant_m0/app/m0_app.dart';
import 'package:ustc_assistant_m0/app/young_observation_panel.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/data/import_contract.dart';
import 'package:ustc_assistant_m0/jobs/coordinator_contract.dart';
import 'package:ustc_assistant_m0/jobs/jw_sync_port.dart';
import 'package:ustc_assistant_m0/jobs/observation_port.dart';
import 'package:ustc_assistant_m0/platform/jw_directory_path.dart';
import 'package:ustc_assistant_m0/source/source_contract.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Windows profile layout starts both stores and can reopen', (
    tester,
  ) async {
    final root = await Directory.systemTemp.createTemp('ustc_m0_e2e_test_');
    final profile = p.windows.join(root.path, 'profile');
    final unusedAppData = p.windows.join(root.path, 'redirected_appdata');
    final jwPath = defaultJwDirectoryPath({
      'USERPROFILE': profile,
      'LOCALAPPDATA': unusedAppData,
    });
    final demoPath = p.windows.join(root.path, 'demo');
    DemoRuntime? runtime;
    try {
      runtime = await DemoRuntime.open(
        directoryPath: demoPath,
        jwDirectoryPath: jwPath,
      );
      expect(p.windows.equals(runtime.jwDirectory.path, jwPath), isTrue);
      expect(runtime.directory.isHeld, isTrue);
      expect(runtime.jwDirectory.isHeld, isTrue);
      expect(runtime.jwSync.syncView.phase, JwSyncPhase.idle);
      expect(runtime.jwSync.syncView.accountBound, isFalse);
      expect(runtime.jwSync.syncView.failure, isNull);
      expect(runtime.youngObservation.view.phase, ObservationPhase.idle);
      expect(runtime.youngObservation.target.source, ObservationSource.young);
      expect(
        identical(runtime.youngObservation.browser, runtime.browser),
        true,
      );
      expect(
        identical(runtime.youngObservation.leases, runtime.observation.leases),
        true,
      );
      expect((await runtime.jwStore.readView()).events, isEmpty);
      expect(await File(p.windows.join(jwPath, 'jw.sqlite')).exists(), isTrue);
      expect(await Directory(unusedAppData).exists(), isFalse);
      await expectLater(
        DemoRuntime.open(
          directoryPath: p.windows.join(root.path, 'second_demo'),
          jwDirectoryPath: jwPath,
        ),
        throwsA(
          isA<AppFailure>().having(
            (error) => error.code,
            'code',
            FailureCode.ownerConflict,
          ),
        ),
      );
      await runtime.close();
      runtime = await DemoRuntime.open(
        directoryPath: demoPath,
        jwDirectoryPath: jwPath,
      );
      expect(runtime.jwDirectory.isHeld, isTrue);
      expect(runtime.jwSync.syncView.phase, JwSyncPhase.idle);
      expect((await runtime.jwStore.readView()).events, isEmpty);
      expect(await Directory(unusedAppData).exists(), isFalse);
    } finally {
      await runtime?.close();
      final resolved = p.windows.normalize(await root.resolveSymbolicLinks());
      final temp = p.windows.normalize(
        await Directory.systemTemp.resolveSymbolicLinks(),
      );
      expect(p.windows.isWithin(temp, resolved), isTrue);
      expect(p.windows.basename(resolved), startsWith('ustc_m0_e2e_test_'));
      await Directory(resolved).delete(recursive: true);
    }
  });
  testWidgets(
    'Windows UI uses real ownership, coordinator and persistent SQLite',
    (tester) async {
      final root = await Directory.systemTemp.createTemp('ustc_m0_e2e_test_');
      final clock = FixedClock(DateTime.utc(2026, 10, 9, 12));
      DemoRuntime? runtime;
      try {
        runtime = await DemoRuntime.open(
          directoryPath: p.join(root.path, 'demo'),
          clock: clock,
        );
        final active = runtime;
        await expectLater(
          DemoRuntime.open(directoryPath: p.join(root.path, 'demo')),
          throwsA(
            isA<AppFailure>().having(
              (error) => error.code,
              'code',
              FailureCode.ownerConflict,
            ),
          ),
        );
        await tester.pumpWidget(
          M0App(
            controller: active.controller,
            observationPanel: Column(
              children: [
                const Text('合成正式面板'),
                YoungObservationPanel(controller: active.youngObservation),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('教务与本地日程'), findsOneWidget);
        expect(find.text('合成正式面板'), findsOneWidget);
        expect(find.text('二课接入验证'), findsOneWidget);
        expect(find.text('打开二课观测窗口'), findsOneWidget);
        expect(find.text('开始合成采集'), findsNothing);
        final demoTile = find.text('离线 M0 合成演示');
        await tester.ensureVisible(demoTile);
        await tester.tap(demoTile);
        await tester.pumpAndSettle();
        expect(find.text('开始合成采集'), findsOneWidget);
        await tester.ensureVisible(demoTile);
        await tester.tap(demoTile);
        await tester.pumpAndSettle();
        expect(find.text('开始合成采集'), findsNothing);

        await tester.pumpWidget(M0App(controller: active.controller));
        await tester.pumpAndSettle();
        expect(find.text('M0 合成演示'), findsOneWidget);

        Future<void> click(String text) async {
          final target = find.text(text);
          await tester.ensureVisible(target);
          await tester.tap(target);
          await tester.pump();
        }

        Future<void> waitFinished() async {
          for (var i = 0; i < 100; i++) {
            await tester.pump(const Duration(milliseconds: 100));
            if (!active.coordinator.view.isBusy && !active.controller.loading) {
              return;
            }
            if (active.coordinator.view.phase == JobPhase.recovery &&
                !active.controller.loading) {
              return;
            }
          }
          fail('local demonstration did not settle');
        }

        Future<void> choose(String label) async {
          final dropdown = find.byType(DropdownButtonFormField<DemoScenario>);
          await tester.ensureVisible(dropdown);
          await tester.tap(dropdown);
          await tester.pumpAndSettle();
          await tester.tap(find.text(label).last);
          await tester.pumpAndSettle();
        }

        Future<void> run(String scenario) async {
          await choose(scenario);
          await click('开始合成采集');
          await waitFinished();
        }

        await click('开始合成采集');
        await waitFinished();
        expect(active.coordinator.view.outcome?.kind, OutcomeKind.committed);
        var data = await active.store.readView();
        expect(data.events.length, 3);
        final identities = data.events.map((event) => event.localId).toList();
        expect(data.importCount, 1);
        expect(data.auditCount, 1);
        expect(data.pendingFollowUps, 0);

        await click('重复上一导入');
        await waitFinished();
        expect(active.coordinator.view.outcome?.replayed, isTrue);
        expect((await active.store.readView()).importCount, 1);
        await run('不完整快照');
        expect(
          active.coordinator.view.outcome?.failure,
          FailureCode.incompleteSnapshot,
        );
        expect((await active.store.readView()).importCount, 1);
        await run('存储失败');
        expect(
          active.coordinator.view.outcome?.failure,
          FailureCode.storageFailed,
        );
        expect((await active.store.readView()).auditCount, 1);

        await choose('正常采集');
        await click('开始合成采集');
        expect(active.coordinator.view.phase, JobPhase.collecting);
        await click('取消当前作业');
        await waitFinished();
        expect(active.coordinator.view.outcome?.kind, OutcomeKind.cancelled);
        expect((await active.store.readView()).importCount, 1);

        await run('收口失败');
        expect(active.coordinator.view.phase, JobPhase.recovery);
        expect((await active.store.readView()).importCount, 1);
        await click('重试收口');
        await waitFinished();
        expect((await active.store.readView()).importCount, 2);
        await run('待办失败');
        data = await active.store.readView();
        expect(data.importCount, 3);
        expect(data.auditCount, 3);
        expect(data.pendingFollowUps, 1);
        expect(data.events.map((event) => event.localId).toList(), identities);
        expect(find.text('已提交 · 后续待办未完成'), findsOneWidget);

        final abandoned = await runtime.store.beginJob();
        await tester.pumpWidget(const SizedBox.shrink());
        await runtime.close();
        runtime = await DemoRuntime.open(
          directoryPath: p.join(root.path, 'demo'),
          clock: clock,
        );
        expect((await runtime.store.readView()).pendingFollowUps, 1);
        expect(
          await runtime.store.cancelJob(abandoned),
          CancellationDisposition.notActive,
        );
        await tester.pumpWidget(M0App(controller: runtime.controller));
        await tester.pumpAndSettle();
        expect(find.text('已有提交 · 后续待办未完成'), findsOneWidget);
        await tester.ensureVisible(find.text('重试待办'));
        await tester.tap(find.text('重试待办'));
        await tester.pumpAndSettle();
        final recovered = await runtime.store.readView();
        expect(recovered.pendingFollowUps, 0);
        expect(recovered.importCount, 3);
        expect(recovered.auditCount, 3);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await runtime?.close();
        final resolved = p.windows.normalize(await root.resolveSymbolicLinks());
        final temp = p.windows.normalize(
          await Directory.systemTemp.resolveSymbolicLinks(),
        );
        expect(p.windows.isWithin(temp, resolved), isTrue);
        expect(p.windows.basename(resolved), startsWith('ustc_m0_e2e_test_'));
        await Directory(resolved).delete(recursive: true);
      }
    },
  );
}
