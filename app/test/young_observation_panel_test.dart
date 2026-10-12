import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/young_observation_panel.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/jobs/observation_port.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';
import 'package:ustc_assistant_m0/source/young_observation_contract.dart';

void main() {
  testWidgets(
    'opens, checks structure, returns, and keeps identity unavailable',
    (tester) async {
      final port = _FakeYoungObservationPort();
      addTearDown(port.dispose);

      await tester.pumpWidget(_host(port));
      expect(find.text('二课接入验证'), findsOneWidget);
      expect(find.textContaining('业务身份、已报名日程采集和活动查询尚未启用'), findsOneWidget);
      expect(find.textContaining('不使用教务已保存的密码'), findsOneWidget);
      expect(find.text('打开二课观测窗口'), findsOneWidget);
      expect(port.closeCalls, 0);

      await tester.tap(find.text('打开二课观测窗口'));
      await tester.pumpAndSettle();
      expect(port.openCalls, 1);
      expect(find.text('检查二课页面结构'), findsOneWidget);
      expect(find.text('回到二课入口'), findsOneWidget);
      expect(find.text('取消并清理二课窗口'), findsOneWidget);

      port.inspectionOnInspect = _inspection();
      await tester.tap(find.text('检查二课页面结构'));
      await tester.pumpAndSettle();
      expect(port.inspectYoungCalls, 1);
      expect(find.text('当前文档结构：二课业务页面'), findsOneWidget);
      expect(find.text('业务身份未验证；此结果不启用日程同步或活动查询。'), findsOneWidget);
      expect(find.text('表格：2'), findsOneWidget);
      expect(find.text('日历根节点：3'), findsOneWidget);
      expect(find.text('页面已就绪，业务身份仍未验证，来源能力仍不可用。'), findsOneWidget);

      await tester.tap(find.text('回到二课入口'));
      await tester.pumpAndSettle();
      expect(port.navigateCalls, 1);
      expect(port.view.youngInspection, isNull);
      expect(find.text('当前文档结构：二课业务页面'), findsNothing);
      expect(find.text('复制二课脱敏摘要'), findsNothing);

      await tester.tap(find.text('取消并清理二课窗口'));
      await tester.pumpAndSettle();
      expect(port.closeCalls, 1);
      expect(port.view.phase, ObservationPhase.closing);
    },
  );

  testWidgets('keeps cancellation available while a structure check waits', (
    tester,
  ) async {
    final port = _FakeYoungObservationPort()
      ..holdNextInspection = true
      ..emit(const ObservationView(phase: ObservationPhase.open));
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.tap(find.text('检查二课页面结构'));
    await tester.pump();

    expect(port.inspectYoungCalls, 1);
    expect(_button(tester, '取消并清理二课窗口').onPressed, isNotNull);
    await tester.tap(find.text('取消并清理二课窗口'));
    await tester.pump();
    expect(port.closeCalls, 1);
    expect(port.view.phase, ObservationPhase.closing);
    expect(tester.takeException(), isNull);

    port.completeHeldInspection();
    await tester.pump();
    expect(port.view.phase, ObservationPhase.closing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('copies only the exact safe summary for the displayed inspection', (
    tester,
  ) async {
    final port = _FakeYoungObservationPort()
      ..emit(
        ObservationView(
          phase: ObservationPhase.open,
          youngInspection: _inspection(),
        ),
      );
    final copied = <String>[];
    _captureClipboard(tester, copied);
    addTearDown(() => _resetClipboard(tester));
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.tap(find.text('复制二课脱敏摘要'));
    await tester.pumpAndSettle();

    expect(copied, [
      '{"kind":"young-observation-v1","ready":true,"surface":"application","identity":"notValidated","sourceAvailable":false,"structure":{"tables":2,"calendarRoots":3,"paginationControls":4,"passwordInputs":0}}',
    ]);
    expect(find.text('已复制二课脱敏摘要。'), findsOneWidget);
  });

  testWidgets('refuses to copy a stale inspection after its document clears', (
    tester,
  ) async {
    final port = _FakeYoungObservationPort()
      ..emit(
        ObservationView(
          phase: ObservationPhase.open,
          youngInspection: _inspection(),
        ),
      );
    final copied = <String>[];
    _captureClipboard(tester, copied);
    addTearDown(() => _resetClipboard(tester));
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    final staleCopyButton = _button(tester, '复制二课脱敏摘要');
    port.emit(const ObservationView(phase: ObservationPhase.open));
    // Invoke the callback from the previous frame; it must consult the current
    // document before touching the clipboard.
    staleCopyButton.onPressed!();
    await tester.pump();

    expect(copied, isEmpty);
    expect(find.text('页面已变化，请重新检查后复制摘要。'), findsNothing);
    await tester.pump();
    expect(find.text('复制二课脱敏摘要'), findsNothing);
  });

  testWidgets('maps only exact approved origins and closed diagnostic labels', (
    tester,
  ) async {
    final port = _FakeYoungObservationPort()
      ..emit(
        const ObservationView(
          phase: ObservationPhase.open,
          origin: 'https://young.ustc.edu.cn/login/?ticket=private',
          diagnostics: [
            BrowserDiagnostic(
              code: BrowserDiagnosticCode.popupBlocked,
              site: BrowserDiagnosticSite.unknown,
              scheme: BrowserDiagnosticScheme.other,
            ),
            BrowserDiagnostic(
              code: BrowserDiagnosticCode.documentRequestBlocked,
              site: BrowserDiagnosticSite.young,
              scheme: BrowserDiagnosticScheme.https,
            ),
            BrowserDiagnostic(
              code: BrowserDiagnosticCode.frameNavigationBlocked,
              site: BrowserDiagnosticSite.ucas,
              scheme: BrowserDiagnosticScheme.http,
            ),
            BrowserDiagnostic(
              code: BrowserDiagnosticCode.downloadBlocked,
              site: BrowserDiagnosticSite.passport,
              scheme: BrowserDiagnosticScheme.https,
            ),
            BrowserDiagnostic(
              code: BrowserDiagnosticCode.permissionBlocked,
              site: BrowserDiagnosticSite.identity,
              scheme: BrowserDiagnosticScheme.https,
            ),
            BrowserDiagnostic(
              code: BrowserDiagnosticCode.externalProtocolBlocked,
              site: BrowserDiagnosticSite.gateway,
              scheme: BrowserDiagnosticScheme.https,
            ),
          ],
        ),
      );
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    expect(find.textContaining('当前白名单站点：'), findsNothing);
    expect(find.textContaining('young.ustc.edu.cn'), findsNothing);
    expect(find.textContaining('ticket'), findsNothing);
    expect(find.text('新窗口被阻止 · 未登记目标 · 其它协议'), findsNothing);
    expect(find.text('页面文档请求被阻止 · 二课 · HTTPS'), findsOneWidget);
    expect(find.text('内嵌页面跳转被阻止 · UCAS · HTTP'), findsOneWidget);
    expect(find.text('下载被阻止 · Passport · HTTPS'), findsOneWidget);
    expect(find.text('页面权限申请被拒绝 · 统一身份认证 · HTTPS'), findsOneWidget);
    expect(find.text('外部应用跳转被阻止 · 认证网关 · HTTPS'), findsOneWidget);

    for (final (origin, label) in const [
      ('https://young.ustc.edu.cn', '二课'),
      ('https://passport.ustc.edu.cn', 'Passport'),
      ('https://id.ustc.edu.cn', '统一身份认证'),
      ('https://ucas.ustc.edu.cn', 'UCAS'),
      ('https://analytics.ustc.edu.cn', 'Analytics'),
    ]) {
      port.emit(ObservationView(phase: ObservationPhase.open, origin: origin));
      await tester.pump();
      expect(find.text('当前白名单站点：$label'), findsOneWidget);
      expect(find.textContaining(origin), findsNothing);
    }

    for (final origin in const [
      'https://young.ustc.edu.cn/',
      'https://young.ustc.edu.cn/login',
      'https://young.ustc.edu.cn?ticket=private',
      'https://unknown.ustc.edu.cn',
    ]) {
      port.emit(ObservationView(phase: ObservationPhase.open, origin: origin));
      await tester.pump();
      expect(find.textContaining('当前白名单站点：'), findsNothing);
      expect(find.textContaining('young.ustc.edu.cn'), findsNothing);
      expect(find.textContaining('ticket'), findsNothing);
    }
  });

  testWidgets(
    'normalizes unexpected errors and keeps cleanup recovery visible',
    (tester) async {
      final port = _FakeYoungObservationPort()
        ..emit(const ObservationView(phase: ObservationPhase.open))
        ..nextInspectionError = StateError(
          'https://secret.invalid/private?ticket=123',
        );
      addTearDown(port.dispose);

      await tester.pumpWidget(_host(port));
      await tester.tap(find.text('检查二课页面结构'));
      await tester.pumpAndSettle();
      expect(find.text('二课页面操作失败，请检查页面后重试。'), findsOneWidget);
      expect(find.textContaining('secret.invalid'), findsNothing);
      expect(find.textContaining('ticket'), findsNothing);
      expect(find.textContaining('StateError'), findsNothing);

      port.emit(
        const ObservationView(
          phase: ObservationPhase.recovery,
          failure: FailureCode.cleanupPending,
        ),
      );
      await tester.pump();
      expect(find.text('重试二课清理'), findsOneWidget);
      expect(find.textContaining('清理未完成'), findsOneWidget);
      await tester.tap(find.text('重试二课清理'));
      await tester.pumpAndSettle();
      expect(port.retryCalls, 1);
      expect(find.text('清理未完成，请重试二课清理。'), findsOneWidget);
    },
  );

  testWidgets('does not reopen a permanently closed observation port', (
    tester,
  ) async {
    final port = _FakeYoungObservationPort()
      ..emit(const ObservationView(phase: ObservationPhase.closed));
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    expect(find.text('二课观测端口已关闭，不能再次打开。来源能力仍不可用。'), findsOneWidget);
    expect(find.text('打开二课观测窗口'), findsNothing);
    expect(port.openCalls, 0);
  });

  testWidgets('disposing the panel leaves port lifecycle with its owner', (
    tester,
  ) async {
    final port = _FakeYoungObservationPort()..holdNextOpen = true;
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.tap(find.text('打开二课观测窗口'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    port.completeHeldOpen();
    await tester.pump();
    expect(port.closeCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late copy completion cannot mark a new inspection copied', (
    tester,
  ) async {
    final port = _FakeYoungObservationPort()
      ..emit(
        ObservationView(
          phase: ObservationPhase.open,
          youngInspection: _inspection(),
        ),
      );
    final copied = <String>[];
    final pendingClipboardWrites = <Completer<void>>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add(
            (call.arguments as Map<Object?, Object?>)['text'] as String,
          );
          final pendingWrite = Completer<void>();
          pendingClipboardWrites.add(pendingWrite);
          await pendingWrite.future;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.tap(find.text('复制二课脱敏摘要'));
    await tester.pump();
    expect(pendingClipboardWrites, hasLength(1));

    port.emit(
      ObservationView(
        phase: ObservationPhase.open,
        youngInspection: _inspection(document: 13, tables: 9),
      ),
    );
    await tester.pump();
    expect(_button(tester, '复制二课脱敏摘要').onPressed, isNotNull);
    await tester.tap(find.text('复制二课脱敏摘要'));
    await tester.pump();
    expect(pendingClipboardWrites, hasLength(2));

    pendingClipboardWrites.first.complete();
    await tester.pump();
    expect(find.text('正在复制摘要'), findsOneWidget);
    expect(find.text('已复制二课脱敏摘要。'), findsNothing);

    pendingClipboardWrites.last.complete();
    await tester.pumpAndSettle();
    expect(find.text('已复制二课脱敏摘要。'), findsOneWidget);
    expect(copied, hasLength(2));
  });

  testWidgets('ignores completion from the previous controller', (
    tester,
  ) async {
    final oldPort = _FakeYoungObservationPort()..holdNextOpen = true;
    final newPort = _FakeYoungObservationPort();
    addTearDown(oldPort.dispose);
    addTearDown(newPort.dispose);

    await tester.pumpWidget(_host(oldPort));
    await tester.tap(find.text('打开二课观测窗口'));
    await tester.pump();
    expect(_button(tester, '取消并清理二课窗口').onPressed, isNotNull);

    await tester.pumpWidget(_host(newPort));
    expect(find.text('二课观测窗口未打开或已清理。来源能力仍不可用。'), findsOneWidget);
    oldPort.failHeldOpen = true;
    oldPort.completeHeldOpen();
    await tester.pump();
    await tester.pump();

    expect(newPort.openCalls, 0);
    expect(find.text('打开二课观测窗口'), findsOneWidget);
    expect(find.textContaining('secret.invalid'), findsNothing);
    expect(find.textContaining('操作失败'), findsNothing);
    expect(oldPort.closeCalls, 0);
  });

  for (final size in const [Size(800, 600), Size(320, 560)]) {
    testWidgets('has no overflow at ${size.width}x${size.height}', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final port = _FakeYoungObservationPort()
        ..emit(
          ObservationView(
            phase: ObservationPhase.open,
            origin: 'https://analytics.ustc.edu.cn',
            diagnostics: List<BrowserDiagnostic>.filled(
              6,
              const BrowserDiagnostic(
                code: BrowserDiagnosticCode.frameNavigationBlocked,
                site: BrowserDiagnosticSite.ucas,
                scheme: BrowserDiagnosticScheme.https,
              ),
            ),
            youngInspection: _inspection(),
          ),
        );
      addTearDown(port.dispose);

      await tester.pumpWidget(_host(port));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expect(find.text('内嵌页面跳转被阻止 · UCAS · HTTPS'), findsNWidgets(5));
    });
  }
}

YoungPageInspection _inspection({int document = 12, int tables = 2}) =>
    YoungPageInspection(
      session: 7,
      document: document,
      ready: true,
      surface: YoungSurface.application,
      tables: tables,
      calendarRoots: 3,
      paginationControls: 4,
      passwordInputs: 0,
    );

Widget _host(YoungObservationPort port) =>
    MaterialApp(home: YoungObservationPanel(controller: port));

ButtonStyleButton _button(WidgetTester tester, String label) => tester.widget(
  find.ancestor(
    of: find.text(label),
    matching: find.bySubtype<ButtonStyleButton>(),
  ),
);

void _captureClipboard(WidgetTester tester, List<String> copied) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map<Object?, Object?>)['text'] as String);
      }
      return null;
    },
  );
}

void _resetClipboard(WidgetTester tester) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    null,
  );
}

class _FakeYoungObservationPort implements YoungObservationPort {
  final StreamController<ObservationView> _changes =
      StreamController<ObservationView>.broadcast(sync: true);
  ObservationView _view = const ObservationView(phase: ObservationPhase.idle);
  bool holdNextOpen = false;
  bool failHeldOpen = false;
  bool holdNextInspection = false;
  Object? nextInspectionError;
  YoungPageInspection? inspectionOnInspect;
  Completer<void>? _heldOpen;
  Completer<void>? _heldInspection;
  int openCalls = 0;
  int inspectCalls = 0;
  int inspectYoungCalls = 0;
  int navigateCalls = 0;
  int closeCalls = 0;
  int retryCalls = 0;

  @override
  ObservationView get view => _view;

  @override
  Stream<ObservationView> get changes => _changes.stream;

  @override
  Future<void> open() async {
    openCalls++;
    if (holdNextOpen) {
      holdNextOpen = false;
      _heldOpen = Completer<void>();
      emit(const ObservationView(phase: ObservationPhase.opening));
      await _heldOpen!.future;
      if (failHeldOpen) {
        throw StateError('https://secret.invalid/private?ticket=opened');
      }
    }
    emit(const ObservationView(phase: ObservationPhase.open));
  }

  @override
  Future<void> inspect() async {
    inspectCalls++;
  }

  @override
  Future<void> inspectYoungPage() async {
    inspectYoungCalls++;
    final failure = nextInspectionError;
    nextInspectionError = null;
    if (failure != null) throw failure;
    if (holdNextInspection) {
      holdNextInspection = false;
      _heldInspection = Completer<void>();
      await _heldInspection!.future;
      if (_view.phase != ObservationPhase.open) return;
    }
    emit(
      ObservationView(
        phase: ObservationPhase.open,
        origin: _view.origin,
        ready: true,
        youngInspection: inspectionOnInspect ?? _inspection(),
      ),
    );
  }

  @override
  Future<void> navigateInitial() async {
    navigateCalls++;
    emit(const ObservationView(phase: ObservationPhase.open));
  }

  @override
  Future<void> navigateJwPage(JwObservationPage page) async {}

  @override
  Future<void> closeSession() async {
    closeCalls++;
    emit(const ObservationView(phase: ObservationPhase.closing));
  }

  @override
  Future<void> retryCleanup() async {
    retryCalls++;
    emit(
      const ObservationView(
        phase: ObservationPhase.recovery,
        failure: FailureCode.cleanupPending,
      ),
    );
  }

  void emit(ObservationView view) {
    _view = view;
    _changes.add(view);
  }

  void completeHeldOpen() {
    _heldOpen?.complete();
    _heldOpen = null;
  }

  void completeHeldInspection() {
    _heldInspection?.complete();
    _heldInspection = null;
  }

  Future<void> dispose() async {
    completeHeldOpen();
    completeHeldInspection();
    await _changes.close();
  }
}
