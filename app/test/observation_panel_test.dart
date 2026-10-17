import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/observation_panel.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/jobs/observation_port.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';

void main() {
  testWidgets('shows safe navigation reasons and keeps identity unverified', (
    tester,
  ) async {
    final port = _FakeObservationPort()
      ..emit(
        const ObservationView(
          phase: ObservationPhase.open,
          blocked: true,
          diagnostics: [
            BrowserDiagnostic(
              code: BrowserDiagnosticCode.insecureDocumentUpgraded,
              site: BrowserDiagnosticSite.identity,
              scheme: BrowserDiagnosticScheme.http,
            ),
            BrowserDiagnostic(
              code: BrowserDiagnosticCode.frameNavigationBlocked,
              site: BrowserDiagnosticSite.unknown,
              scheme: BrowserDiagnosticScheme.https,
            ),
          ],
        ),
      );
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));
    expect(find.textContaining('页面操作已被阻止'), findsOneWidget);
    expect(find.text('已将页面请求安全转换为 HTTPS · 统一身份认证 · HTTP'), findsOneWidget);
    expect(find.text('内嵌页面跳转被阻止 · 未登记目标 · HTTPS'), findsOneWidget);
    expect(find.textContaining('业务身份仍未核验'), findsOneWidget);
    expect(find.textContaining('ticket='), findsNothing);
  });

  testWidgets('shows the safe idle state and does not own the port lifecycle', (
    tester,
  ) async {
    final port = _FakeObservationPort();
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));

    expect(find.text('M1 教务观测'), findsOneWidget);
    expect(find.text('页面就绪不等于身份核验；尚未采集或导入真实数据'), findsOneWidget);
    expect(find.text('账号、密码和验证码请在学校窗口中手填'), findsOneWidget);
    expect(find.text('登录后用下面两个入口打开独立页面，无需在学校首页内部切换标签。'), findsOneWidget);
    expect(find.text('观测窗口未打开或已关闭'), findsOneWidget);
    expect(find.text('打开教务观测窗口'), findsOneWidget);
    expect(_button(tester, '打开课表页面').onPressed, isNull);
    expect(_button(tester, '打开考试安排').onPressed, isNull);
    expect(find.byType(Scaffold), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(port.closeCalls, 0);
  });

  testWidgets(
    'opens, checks readiness, and navigates without claiming identity',
    (tester) async {
      final port = _FakeObservationPort();
      addTearDown(port.dispose);

      await tester.pumpWidget(_host(port));
      await tester.tap(find.text('打开教务观测窗口'));
      await tester.pumpAndSettle();

      expect(port.openCalls, 1);
      expect(find.text('检查业务页就绪'), findsOneWidget);
      expect(find.text('重新打开教务入口'), findsOneWidget);
      expect(find.text('取消并清理窗口'), findsOneWidget);

      port.readyOnInspect = true;
      await tester.tap(find.text('检查业务页就绪'));
      await tester.pumpAndSettle();
      expect(port.inspectCalls, 1);
      expect(find.text('页面已就绪，业务身份尚未核验'), findsOneWidget);
      expect(find.text('当前受控来源：jw.ustc.edu.cn'), findsOneWidget);
      expect(find.textContaining('https://'), findsNothing);
      expect(find.textContaining('学号'), findsNothing);
      expect(_button(tester, '打开课表页面').onPressed, isNotNull);
      expect(_button(tester, '打开考试安排').onPressed, isNotNull);

      await tester.ensureVisible(find.text('打开课表页面'));
      await tester.tap(find.text('打开课表页面'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('打开考试安排'));
      await tester.tap(find.text('打开考试安排'));
      await tester.pumpAndSettle();
      expect(port.jwPageCalls, [
        JwObservationPage.courseTable,
        JwObservationPage.examArrange,
      ]);

      await tester.tap(find.text('重新打开教务入口'));
      await tester.pumpAndSettle();
      expect(port.navigateCalls, 1);
      expect(find.text('页面就绪不等于身份核验；尚未采集或导入真实数据'), findsOneWidget);
    },
  );

  testWidgets('fixed page buttons require a ready JW origin and no cleanup', (
    tester,
  ) async {
    final port = _FakeObservationPort()
      ..emit(
        const ObservationView(
          phase: ObservationPhase.open,
          origin: 'https://jw.ustc.edu.cn',
          ready: false,
        ),
      );
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    expect(_button(tester, '打开课表页面').onPressed, isNull);
    expect(_button(tester, '打开考试安排').onPressed, isNull);

    port.emit(
      const ObservationView(
        phase: ObservationPhase.open,
        origin: 'https://passport.ustc.edu.cn/',
        ready: true,
      ),
    );
    await tester.pump();
    expect(_button(tester, '打开课表页面').onPressed, isNull);
    expect(_button(tester, '打开考试安排').onPressed, isNull);

    port.emit(
      const ObservationView(
        phase: ObservationPhase.recovery,
        origin: 'https://jw.ustc.edu.cn',
        ready: true,
      ),
    );
    await tester.pump();
    expect(_button(tester, '打开课表页面').onPressed, isNull);
    expect(_button(tester, '打开考试安排').onPressed, isNull);
  });

  testWidgets(
    'keeps cancellation available while a fixed page navigation waits',
    (tester) async {
      final port = _FakeObservationPort()
        ..holdNextJwPage = true
        ..emit(
          const ObservationView(
            phase: ObservationPhase.open,
            origin: 'jw.ustc.edu.cn',
            ready: true,
          ),
        );
      addTearDown(port.dispose);

      await tester.pumpWidget(_host(port));
      await tester.ensureVisible(find.text('打开课表页面'));
      await tester.tap(find.text('打开课表页面'));
      await tester.pump();

      expect(port.jwPageCalls, [JwObservationPage.courseTable]);
      expect(_button(tester, '打开考试安排').onPressed, isNull);
      expect(_button(tester, '取消并清理窗口').onPressed, isNotNull);
      await tester.ensureVisible(find.text('取消并清理窗口'));
      await tester.tap(find.text('取消并清理窗口'));
      await tester.pump(const Duration(milliseconds: 30));

      expect(port.closeCalls, 1);
      expect(port.view.phase, ObservationPhase.closing);
      expect(_button(tester, '打开课表页面').onPressed, isNull);
      expect(find.textContaining('等待窗口与相关资源释放'), findsOneWidget);
      expect(tester.takeException(), isNull);

      port.completeHeldJwPage();
      await tester.pump();
    },
  );

  testWidgets('allows cancel while open is still pending', (tester) async {
    final port = _FakeObservationPort()..holdNextOpen = true;
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.tap(find.text('打开教务观测窗口'));
    await tester.pump();

    expect(port.view.phase, ObservationPhase.opening);
    expect(_button(tester, '取消并清理窗口').onPressed, isNotNull);
    await tester.tap(find.text('取消并清理窗口'));
    await tester.pump(const Duration(milliseconds: 30));

    expect(port.closeCalls, 1);
    expect(port.view.phase, ObservationPhase.closing);
    expect(find.textContaining('等待窗口与相关资源释放'), findsOneWidget);
    expect(tester.takeException(), isNull);

    port.completeHeldOpen();
    await tester.pump();
  });

  testWidgets(
    'normalizes busy and unexpected failures without exposing details',
    (tester) async {
      final port = _FakeObservationPort()
        ..nextOpenError = const AppFailure(FailureCode.busy);
      addTearDown(port.dispose);

      await tester.pumpWidget(_host(port));
      await tester.tap(find.text('打开教务观测窗口'));
      await tester.pumpAndSettle();
      expect(find.text('当前有其他作业正在处理，请稍后重试。'), findsOneWidget);
      expect(find.textContaining('AppFailure'), findsNothing);

      port.nextOpenError = StateError(
        'https://secret.invalid/private?ticket=123',
      );
      await tester.tap(find.text('打开教务观测窗口'));
      await tester.pumpAndSettle();
      expect(find.text('教务页面操作失败，请检查页面后重试。'), findsOneWidget);
      expect(find.textContaining('secret.invalid'), findsNothing);
      expect(find.textContaining('ticket'), findsNothing);
    },
  );

  testWidgets('keeps cleanup recovery honest when retry throws', (
    tester,
  ) async {
    final port = _FakeObservationPort()
      ..emit(const ObservationView(phase: ObservationPhase.recovery))
      ..nextRetryError = StateError('deleted successfully');
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    expect(find.text('重试清理'), findsOneWidget);
    expect(find.textContaining('清理未完成'), findsOneWidget);
    expect(find.text('观测窗口未打开或已关闭'), findsNothing);

    await tester.tap(find.text('重试清理'));
    await tester.pumpAndSettle();
    expect(port.retryCalls, 1);
    expect(find.text('清理未完成，请重试清理。'), findsOneWidget);
    expect(find.textContaining('deleted successfully'), findsNothing);
    expect(find.textContaining('清理成功'), findsNothing);
  });

  for (final size in const [Size(1280, 800), Size(800, 600)]) {
    testWidgets('has no overflow at ${size.width}x${size.height}', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final port = _FakeObservationPort();
      addTearDown(port.dispose);
      await tester.pumpWidget(_host(port));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
    });
  }
}

Widget _host(ObservationPort port) =>
    MaterialApp(home: ObservationPanel(controller: port));

ButtonStyleButton _button(WidgetTester tester, String label) => tester.widget(
  find.ancestor(
    of: find.text(label),
    matching: find.bySubtype<ButtonStyleButton>(),
  ),
);

class _FakeObservationPort implements ObservationPort {
  final StreamController<ObservationView> _changes =
      StreamController<ObservationView>.broadcast(sync: true);
  ObservationView _view = const ObservationView(phase: ObservationPhase.idle);
  bool holdNextOpen = false;
  bool holdNextJwPage = false;
  bool readyOnInspect = false;
  Object? nextOpenError;
  Object? nextRetryError;
  Completer<void>? _heldOpen;
  Completer<void>? _heldJwPage;
  int openCalls = 0;
  int inspectCalls = 0;
  int navigateCalls = 0;
  final List<JwObservationPage> jwPageCalls = [];
  int closeCalls = 0;
  int retryCalls = 0;

  @override
  ObservationView get view => _view;

  @override
  Stream<ObservationView> get changes => _changes.stream;

  @override
  Future<void> open() async {
    openCalls++;
    final failure = nextOpenError;
    nextOpenError = null;
    if (failure != null) throw failure;
    if (holdNextOpen) {
      holdNextOpen = false;
      _heldOpen = Completer<void>();
      emit(const ObservationView(phase: ObservationPhase.opening));
      await _heldOpen!.future;
      return;
    }
    emit(const ObservationView(phase: ObservationPhase.open));
  }

  @override
  Future<void> inspect() async {
    inspectCalls++;
    emit(
      ObservationView(
        phase: ObservationPhase.open,
        origin: 'https://jw.ustc.edu.cn/',
        ready: readyOnInspect,
      ),
    );
  }

  @override
  Future<void> navigateInitial() async {
    navigateCalls++;
    emit(
      const ObservationView(
        phase: ObservationPhase.open,
        origin: 'jw.ustc.edu.cn',
      ),
    );
  }

  @override
  Future<void> navigateJwPage(JwObservationPage page) async {
    jwPageCalls.add(page);
    if (holdNextJwPage) {
      holdNextJwPage = false;
      _heldJwPage = Completer<void>();
      await _heldJwPage!.future;
    }
  }

  @override
  Future<void> closeSession() async {
    closeCalls++;
    emit(const ObservationView(phase: ObservationPhase.closing));
  }

  @override
  Future<void> retryCleanup() async {
    retryCalls++;
    final failure = nextRetryError;
    nextRetryError = null;
    if (failure != null) throw failure;
    emit(const ObservationView(phase: ObservationPhase.idle));
  }

  void emit(ObservationView value) {
    _view = value;
    _changes.add(value);
  }

  void completeHeldOpen() {
    _heldOpen?.complete();
    _heldOpen = null;
  }

  void completeHeldJwPage() {
    _heldJwPage?.complete();
    _heldJwPage = null;
  }

  Future<void> dispose() async {
    completeHeldOpen();
    completeHeldJwPage();
    await _changes.close();
  }
}
