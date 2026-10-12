import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/demo_controller.dart';
import 'package:ustc_assistant_m0/app/m0_app.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/data/import_contract.dart';
import 'package:ustc_assistant_m0/jobs/coordinator_contract.dart';
import 'package:ustc_assistant_m0/source/source_contract.dart';

void main() {
  testWidgets('startup failures show fixed application data messages', (
    tester,
  ) async {
    const messages = <FailureCode, String>{
      FailureCode.unsafeDirectory: '应用数据目录检查未通过。',
      FailureCode.ownerConflict: '应用数据目录正被另一个应用实例使用。',
      FailureCode.ownershipLost: '应用数据目录所有权已失效。',
      FailureCode.storageFailed: '本地应用数据操作失败。',
    };

    for (final entry in messages.entries) {
      await tester.pumpWidget(M0StartupFailureApp(code: entry.key));

      expect(find.text('应用无法启动。'), findsOneWidget);
      expect(find.text(entry.value), findsOneWidget);
      expect(find.textContaining('演示目录'), findsNothing);
    }
  });

  group('M0 synthetic demo UI', () {
    testWidgets(
      'shows schedule, Beijing time, safe counts, and missing marker',
      (tester) async {
        final data = _FakeReadPort(_sampleData());
        final coordinator = _FakeCoordinator(data);
        final controller = DemoController(coordinator: coordinator, data: data);
        addTearDown(controller.dispose);

        await tester.pumpWidget(M0App(controller: controller));
        await tester.pumpAndSettle();

        expect(find.text('USTC Assistant'), findsWidgets);
        expect(find.text('M0 合成演示'), findsOneWidget);
        expect(
          find.text('教务、二课日程、二课报名、评课、校园信息和 Agent 尚未接入；演示不联网、不使用学校账号。'),
          findsOneWidget,
        );
        expect(find.text('算法导论'), findsOneWidget);
        expect(find.text('来源缺失，记录保留'), findsOneWidget);
        expect(
          find.text('2026-10-12 09:00 – 2026-10-12 10:00'),
          findsOneWidget,
        );
        expect(find.text('已提交导入'), findsOneWidget);
        expect(find.text('4'), findsOneWidget);
        expect(find.text('3'), findsWidgets);
      },
    );

    testWidgets('blocks a second run while busy and allows cancellation', (
      tester,
    ) async {
      final data = _FakeReadPort(_emptyData());
      final coordinator = _FakeCoordinator(data)..holdNextRun = true;
      final controller = DemoController(coordinator: coordinator, data: data);
      addTearDown(controller.dispose);

      await tester.pumpWidget(M0App(controller: controller));
      await tester.pumpAndSettle();

      await tester.tap(find.text('开始合成采集'));
      await tester.pump();
      expect(coordinator.view.phase, JobPhase.collecting);
      expect(_button(tester, '开始合成采集').onPressed, isNull);
      expect(_button(tester, '取消当前作业').onPressed, isNotNull);

      await tester.tap(find.text('取消当前作业'));
      await tester.pumpAndSettle();
      expect(coordinator.view.outcome?.kind, OutcomeKind.cancelled);
      expect(find.text('已取消 · 本次未提交'), findsOneWidget);
      expect(coordinator.runCalls, 1);
    });

    testWidgets('offers recovery retry and reports eventual committed result', (
      tester,
    ) async {
      final data = _FakeReadPort(_emptyData());
      final coordinator = _FakeCoordinator(data);
      final controller = DemoController(coordinator: coordinator, data: data);
      addTearDown(controller.dispose);

      await tester.pumpWidget(M0App(controller: controller));
      await tester.pumpAndSettle();
      await _chooseScenario(tester, '收口失败');
      await tester.tap(find.text('开始合成采集'));
      await tester.pumpAndSettle();

      expect(coordinator.view.phase, JobPhase.recovery);
      expect(find.text('收口失败 · 本次尚未提交'), findsOneWidget);
      expect(find.text('重试收口'), findsOneWidget);
      expect(find.text('收口失败 · 本次尚未提交'), findsOneWidget);

      await tester.tap(find.text('重试收口'));
      await tester.pumpAndSettle();
      expect(coordinator.view.outcome?.kind, OutcomeKind.committed);
      expect(find.text('已提交'), findsOneWidget);
      expect(find.text('收口失败 · 本次尚未提交'), findsNothing);
    });

    testWidgets('keeps committed status visible when follow-up retry fails', (
      tester,
    ) async {
      final data = _FakeReadPort(_emptyData());
      final coordinator = _FakeCoordinator(data)..failFollowUpRetry = true;
      final controller = DemoController(coordinator: coordinator, data: data);
      addTearDown(controller.dispose);

      await tester.pumpWidget(M0App(controller: controller));
      await tester.pumpAndSettle();
      await _chooseScenario(tester, '待办失败');
      await tester.tap(find.text('开始合成采集'));
      await tester.pumpAndSettle();

      expect(find.text('已提交 · 后续待办未完成'), findsOneWidget);
      expect(find.text('导入已提交；仍有后续待办等待处理。'), findsOneWidget);
      expect(find.text('已提交导入'), findsOneWidget);
      expect(find.text('1'), findsWidgets);

      await tester.tap(find.text('重试待办'));
      await tester.pumpAndSettle();
      expect(coordinator.followUpRetryCalls, 1);
      expect(find.text('已提交 · 后续待办未完成'), findsOneWidget);
      expect(find.textContaining('已提交状态仍保留'), findsOneWidget);
      expect(find.textContaining('本次未提交'), findsNothing);

      coordinator.failFollowUpRetry = false;
      await tester.tap(find.text('重试待办'));
      await tester.pumpAndSettle();
      expect(find.text('已提交'), findsOneWidget);
      expect(find.textContaining('后续待办等待处理'), findsNothing);
      expect(_button(tester, '重试待办').onPressed, isNull);
    });

    testWidgets('replays only after an import exists', (tester) async {
      final data = _FakeReadPort(_sampleData());
      final coordinator = _FakeCoordinator(data);
      final controller = DemoController(coordinator: coordinator, data: data);
      addTearDown(controller.dispose);

      await tester.pumpWidget(M0App(controller: controller));
      await tester.pumpAndSettle();
      expect(_button(tester, '重复上一导入').onPressed, isNotNull);

      await tester.tap(find.text('重复上一导入'));
      await tester.pumpAndSettle();
      expect(coordinator.lastScenario, DemoScenario.replay);
      expect(find.text('已提交 · 重放上一导入'), findsOneWidget);
      expect(find.text('本次为重复上一导入，沿用已提交结果。'), findsOneWidget);

      final emptyData = _FakeReadPort(_emptyData());
      final emptyController = DemoController(
        coordinator: _FakeCoordinator(emptyData),
        data: emptyData,
      );
      addTearDown(emptyController.dispose);
      await tester.pumpWidget(M0App(controller: emptyController));
      await tester.pumpAndSettle();
      expect(_button(tester, '重复上一导入').onPressed, isNull);
    });

    testWidgets('keeps the newest view when data reads finish out of order', (
      tester,
    ) async {
      final data = _FakeReadPort(_emptyData());
      final firstRead = Completer<DemoDataView>();
      final secondRead = Completer<DemoDataView>();
      final newestRead = Completer<DemoDataView>();
      data.delayedReads
        ..add(firstRead)
        ..add(secondRead)
        ..add(newestRead);
      final coordinator = _FakeCoordinator(data);
      final controller = DemoController(coordinator: coordinator, data: data);
      addTearDown(controller.dispose);

      await tester.pumpWidget(M0App(controller: controller));
      await tester.pump();
      coordinator.emitForTest(
        const CoordinatorView(
          phase: JobPhase.recovery,
          sequence: 1,
          outcome: JobOutcome(
            kind: OutcomeKind.failed,
            failure: FailureCode.cleanupPending,
          ),
        ),
      );
      coordinator.emitForTest(
        const CoordinatorView(
          phase: JobPhase.idle,
          sequence: 2,
          outcome: JobOutcome(kind: OutcomeKind.committed, recordCount: 3),
        ),
      );

      newestRead.complete(_sampleData());
      await tester.pump();
      expect(controller.dataView?.importCount, 2);

      secondRead.complete(_emptyData());
      firstRead.complete(_emptyData());
      await tester.pump();
      expect(controller.dataView?.importCount, 2);
    });

    for (final size in const [Size(1280, 800), Size(800, 600)]) {
      testWidgets('fits a scrollable layout at ${size.width}x${size.height}', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final data = _FakeReadPort(_sampleData());
        final controller = DemoController(
          coordinator: _FakeCoordinator(data),
          data: data,
        );
        addTearDown(controller.dispose);

        await tester.pumpWidget(M0App(controller: controller));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(SingleChildScrollView), findsOneWidget);
      });
    }
  });

  group('formal home with offline demo', () {
    testWidgets('leads with teaching affairs and keeps the demo collapsed', (
      tester,
    ) async {
      final data = _FakeReadPort(_sampleData());
      final controller = DemoController(
        coordinator: _FakeCoordinator(data),
        data: data,
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        M0App(controller: controller, observationPanel: const Text('正式教务入口')),
      );
      await tester.pumpAndSettle();

      expect(find.text('教务与本地日程'), findsOneWidget);
      expect(
        find.text('教务登录与采集会自动进行，课程和考试会导入本地日程。遇到验证码、通行密钥或学校额外授权时，需要你在学校页面完成操作。'),
        findsOneWidget,
      );
      expect(find.text('正式教务入口'), findsOneWidget);
      expect(find.textContaining('手动登录'), findsNothing);
      expect(find.text('离线 M0 合成演示'), findsOneWidget);
      expect(find.text('离线合成周日程'), findsNothing);
      expect(find.text('开始合成采集'), findsNothing);

      await _tapDemoTile(tester);
      expect(find.text('离线演示操作'), findsOneWidget);
      expect(find.text('离线演示计数'), findsOneWidget);
      expect(find.text('离线合成周日程'), findsOneWidget);
      expect(find.text('算法导论'), findsOneWidget);
    });

    testWidgets('keeps active demo status and cancellation reachable', (
      tester,
    ) async {
      final data = _FakeReadPort(_emptyData());
      final coordinator = _FakeCoordinator(data)..holdNextRun = true;
      final controller = DemoController(coordinator: coordinator, data: data);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        M0App(controller: controller, observationPanel: const Text('正式教务入口')),
      );
      await tester.pumpAndSettle();
      await _tapDemoTile(tester);

      await tester.ensureVisible(find.text('开始合成采集'));
      await tester.pump();
      await tester.tap(find.text('开始合成采集'));
      await tester.pump();
      final attention = find.byKey(const ValueKey('offline-m0-attention'));
      await tester.ensureVisible(attention);
      expect(
        find.descendant(of: attention, matching: find.text('离线演示正在运行')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: attention, matching: find.text('正在采集')),
        findsOneWidget,
      );

      // The attention card is inserted above the tile while the demo runs.
      // Re-locate its title before collapsing the tile.
      await _tapDemoTile(tester);
      await tester.ensureVisible(attention);
      expect(find.text('开始合成采集'), findsNothing);
      expect(find.text('取消当前作业'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('offline-m0-demo')),
          matching: find.text('正在采集'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(of: attention, matching: find.text('离线演示正在运行')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: attention, matching: find.text('正在采集')),
        findsOneWidget,
      );
      expect(_button(tester, '取消演示采集').onPressed, isNotNull);

      await tester.ensureVisible(find.text('取消演示采集'));
      await tester.pump();
      await tester.tap(find.text('取消演示采集'));
      await tester.pumpAndSettle();
      expect(coordinator.view.outcome?.kind, OutcomeKind.cancelled);
      await _tapDemoTile(tester);
      expect(find.text('已取消 · 本次未提交'), findsOneWidget);
    });

    testWidgets('keeps recovery status and retry reachable when collapsed', (
      tester,
    ) async {
      final data = _FakeReadPort(_emptyData());
      final controller = DemoController(
        coordinator: _FakeCoordinator(data),
        data: data,
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        M0App(controller: controller, observationPanel: const Text('正式教务入口')),
      );
      await tester.pumpAndSettle();
      await _tapDemoTile(tester);
      await _chooseScenario(tester, '收口失败');
      await tester.ensureVisible(find.text('开始合成采集'));
      await tester.pump();
      await tester.tap(find.text('开始合成采集'));
      await tester.pumpAndSettle();

      final attention = find.byKey(const ValueKey('offline-m0-attention'));
      await tester.ensureVisible(attention);
      expect(
        find.descendant(of: attention, matching: find.text('离线演示需要恢复')),
        findsOneWidget,
      );
      expect(_button(tester, '重试演示收口').onPressed, isNotNull);
      await _tapDemoTile(tester);
      await tester.ensureVisible(attention);
      expect(find.text('开始合成采集'), findsNothing);
      expect(find.text('重试收口'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('offline-m0-demo')),
          matching: find.text('收口失败 · 本次尚未提交'),
        ),
        findsNothing,
      );
      expect(find.text('收口失败 · 本次尚未提交'), findsOneWidget);
      expect(
        find.descendant(of: attention, matching: find.text('收口失败 · 本次尚未提交')),
        findsOneWidget,
      );
      expect(_button(tester, '重试演示收口').onPressed, isNotNull);

      await tester.ensureVisible(find.text('重试演示收口'));
      await tester.pump();
      await tester.tap(find.text('重试演示收口'));
      await tester.pumpAndSettle();
      expect(controller.view.outcome?.kind, OutcomeKind.committed);
    });

    testWidgets('formal home scrolls without overflow in a narrow window', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final data = _FakeReadPort(_sampleData());
      final controller = DemoController(
        coordinator: _FakeCoordinator(data),
        data: data,
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        M0App(
          controller: controller,
          observationPanel: const SizedBox(
            height: 160,
            child: ColoredBox(
              color: Colors.white,
              child: Center(child: Text('正式教务入口')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(SingleChildScrollView), findsOneWidget);

      await _tapDemoTile(tester);
      await tester.ensureVisible(find.text('离线合成周日程'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('算法导论'), findsOneWidget);
    });
  });
}

ButtonStyleButton _button(WidgetTester tester, String label) => tester.widget(
  find.ancestor(
    of: find.text(label),
    matching: find.bySubtype<ButtonStyleButton>(),
  ),
);

Future<void> _chooseScenario(WidgetTester tester, String label) async {
  final dropdown = find.byType(DropdownButtonFormField<DemoScenario>);
  await tester.ensureVisible(dropdown);
  await tester.pump();
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _tapDemoTile(WidgetTester tester) async {
  final title = find.text('离线 M0 合成演示');
  await tester.ensureVisible(title);
  await tester.pump();
  await tester.tap(title);
  // An active demo keeps an indeterminate progress animation alive, so only
  // advance enough time for the ExpansionTile's transition to finish.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

DemoDataView _sampleData() => DemoDataView(
  events: [
    StoredEvent(
      localId: 1,
      externalId: 'synth-1',
      title: '算法导论',
      startsAtUtc: DateTime.utc(2026, 10, 12, 1),
      endsAtUtc: DateTime.utc(2026, 10, 12, 2),
      sourceMissing: true,
    ),
    StoredEvent(
      localId: 2,
      externalId: 'synth-2',
      title: '实验室讨论',
      startsAtUtc: DateTime.utc(2026, 10, 13, 6),
      endsAtUtc: DateTime.utc(2026, 10, 13, 7),
      sourceMissing: false,
    ),
    StoredEvent(
      localId: 3,
      externalId: 'synth-3',
      title: '项目答疑',
      startsAtUtc: DateTime.utc(2026, 10, 15, 8),
      endsAtUtc: DateTime.utc(2026, 10, 15, 9),
      sourceMissing: false,
    ),
  ],
  importCount: 2,
  auditCount: 4,
  pendingFollowUps: 0,
);

DemoDataView _emptyData() => DemoDataView(
  events: const [],
  importCount: 0,
  auditCount: 0,
  pendingFollowUps: 0,
);

class _FakeReadPort implements DemoReadPort {
  _FakeReadPort(this.value);

  DemoDataView value;
  final List<Completer<DemoDataView>> delayedReads = [];
  int readCalls = 0;

  @override
  Future<DemoDataView> readView() {
    readCalls++;
    if (delayedReads.isNotEmpty) return delayedReads.removeAt(0).future;
    return Future.value(value);
  }
}

class _FakeCoordinator implements CoordinatorPort {
  _FakeCoordinator(this.data);

  final _FakeReadPort data;
  final StreamController<CoordinatorView> _changes =
      StreamController<CoordinatorView>.broadcast(sync: true);
  CoordinatorView _view = const CoordinatorView(
    phase: JobPhase.idle,
    sequence: 0,
  );
  bool holdNextRun = false;
  bool failFollowUpRetry = false;
  Completer<JobOutcome>? _heldRun;
  DemoScenario? lastScenario;
  int runCalls = 0;
  int followUpRetryCalls = 0;
  int closeCalls = 0;

  @override
  CoordinatorView get view => _view;

  @override
  Stream<CoordinatorView> get changes => _changes.stream;

  @override
  Future<JobOutcome> run(DemoScenario scenario) {
    runCalls++;
    lastScenario = scenario;
    if (holdNextRun) {
      holdNextRun = false;
      _heldRun = Completer<JobOutcome>();
      _emit(const CoordinatorView(phase: JobPhase.collecting, sequence: 1));
      return _heldRun!.future;
    }

    final JobOutcome outcome;
    switch (scenario) {
      case DemoScenario.cleanupFailure:
        outcome = const JobOutcome(
          kind: OutcomeKind.failed,
          failure: FailureCode.cleanupPending,
        );
        _emit(
          CoordinatorView(
            phase: JobPhase.recovery,
            sequence: runCalls,
            outcome: outcome,
          ),
        );
        break;
      case DemoScenario.followUpFailure:
        data.value = DemoDataView(
          events: data.value.events,
          importCount: data.value.importCount + 1,
          auditCount: data.value.auditCount + 1,
          pendingFollowUps: 1,
        );
        outcome = const JobOutcome(
          kind: OutcomeKind.committed,
          recordCount: 3,
          followUpPending: true,
        );
        _emit(
          CoordinatorView(
            phase: JobPhase.idle,
            sequence: runCalls,
            outcome: outcome,
          ),
        );
        break;
      case DemoScenario.replay:
        outcome = const JobOutcome(
          kind: OutcomeKind.committed,
          recordCount: 3,
          replayed: true,
        );
        _emit(
          CoordinatorView(
            phase: JobPhase.idle,
            sequence: runCalls,
            outcome: outcome,
          ),
        );
        break;
      case DemoScenario.incomplete:
        outcome = const JobOutcome(
          kind: OutcomeKind.failed,
          failure: FailureCode.incompleteSnapshot,
        );
        _emit(
          CoordinatorView(
            phase: JobPhase.idle,
            sequence: runCalls,
            outcome: outcome,
          ),
        );
        break;
      case DemoScenario.sourceFailure:
        outcome = const JobOutcome(
          kind: OutcomeKind.failed,
          failure: FailureCode.sourceFailed,
        );
        _emit(
          CoordinatorView(
            phase: JobPhase.idle,
            sequence: runCalls,
            outcome: outcome,
          ),
        );
        break;
      case DemoScenario.storageFailure:
        outcome = const JobOutcome(
          kind: OutcomeKind.failed,
          failure: FailureCode.storageFailed,
        );
        _emit(
          CoordinatorView(
            phase: JobPhase.idle,
            sequence: runCalls,
            outcome: outcome,
          ),
        );
        break;
      case DemoScenario.empty:
      case DemoScenario.normal:
        data.value = DemoDataView(
          events: scenario == DemoScenario.empty
              ? const []
              : _sampleData().events,
          importCount: data.value.importCount + 1,
          auditCount: data.value.auditCount + 1,
          pendingFollowUps: 0,
        );
        outcome = JobOutcome(
          kind: OutcomeKind.committed,
          recordCount: data.value.events.length,
        );
        _emit(
          CoordinatorView(
            phase: JobPhase.idle,
            sequence: runCalls,
            outcome: outcome,
          ),
        );
        break;
    }
    return Future.value(outcome);
  }

  @override
  Future<CancellationDisposition> cancel() async {
    const outcome = JobOutcome(kind: OutcomeKind.cancelled);
    _emit(
      CoordinatorView(
        phase: JobPhase.idle,
        sequence: _view.sequence,
        outcome: outcome,
      ),
    );
    _heldRun?.complete(outcome);
    _heldRun = null;
    return CancellationDisposition.cancelled;
  }

  @override
  Future<JobOutcome> retryRecovery() async {
    data.value = _sampleData();
    const outcome = JobOutcome(kind: OutcomeKind.committed, recordCount: 3);
    _emit(
      CoordinatorView(
        phase: JobPhase.idle,
        sequence: _view.sequence + 1,
        outcome: outcome,
      ),
    );
    return outcome;
  }

  @override
  Future<void> retryFollowUps() async {
    followUpRetryCalls++;
    if (failFollowUpRetry) {
      throw const AppFailure(FailureCode.followUpPending);
    }
    data.value = DemoDataView(
      events: data.value.events,
      importCount: data.value.importCount,
      auditCount: data.value.auditCount + 1,
      pendingFollowUps: 0,
    );
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }

  void emitForTest(CoordinatorView next) => _emit(next);

  void _emit(CoordinatorView next) {
    _view = next;
    _changes.add(next);
  }
}
