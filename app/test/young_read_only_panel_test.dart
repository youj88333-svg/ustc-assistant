import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/young_read_only_panel.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/jobs/observation_port.dart';
import 'package:ustc_assistant_m0/jobs/young_read_only_port.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';
import 'package:ustc_assistant_m0/source/young_observation_contract.dart';
import 'package:ustc_assistant_m0/source/young_read_only_contract.dart';

void main() {
  testWidgets('gates start, refresh, and stop on the ready listening state', (
    tester,
  ) async {
    final port = _FakeYoungReadOnlyPort();
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    expect(find.text('二课只读接口观测'), findsOneWidget);
    expect(find.textContaining('不授予采集或导入许可'), findsOneWidget);
    expect(find.textContaining('页面导航会停止本次观测'), findsOneWidget);
    expect(_button(tester, '开始接口观测').onPressed, isNull);
    expect(_button(tester, '更新接口摘要').onPressed, isNull);
    expect(_button(tester, '停止接口观测').onPressed, isNull);
    expect(port.startCalls, 0);

    port.emitView(_view(phase: ObservationPhase.open, ready: true));
    await tester.pump();
    expect(_button(tester, '开始接口观测').onPressed, isNotNull);
    expect(_button(tester, '更新接口摘要').onPressed, isNull);
    expect(_button(tester, '停止接口观测').onPressed, isNull);

    await tester.tap(find.text('开始接口观测'));
    await tester.pumpAndSettle();
    expect(port.startCalls, 1);
    expect(port.readOnlyInspection?.listening, isTrue);
    expect(_button(tester, '开始接口观测').onPressed, isNull);
    expect(_button(tester, '更新接口摘要').onPressed, isNotNull);
    expect(_button(tester, '停止接口观测').onPressed, isNotNull);
    expect(_button(tester, '复制接口脱敏摘要').onPressed, isNotNull);

    await tester.tap(find.text('停止接口观测'));
    await tester.pumpAndSettle();
    expect(port.stopCalls, 1);
    expect(port.readOnlyInspection?.listening, isFalse);
    expect(_button(tester, '开始接口观测').onPressed, isNotNull);
    expect(_button(tester, '更新接口摘要').onPressed, isNull);
    expect(_button(tester, '停止接口观测').onPressed, isNull);
    // A stopped but current DTO is still an eligible safe summary.
    expect(_button(tester, '复制接口脱敏摘要').onPressed, isNotNull);
  });

  testWidgets('ready observation does not require a structure inspection', (
    tester,
  ) async {
    final port = _FakeYoungReadOnlyPort(
      view: const ObservationView(phase: ObservationPhase.open, ready: true),
    );
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    expect(find.text('检查二课页面结构'), findsNothing);
    expect(_button(tester, '开始接口观测').onPressed, isNotNull);

    await tester.tap(find.text('开始接口观测'));
    await tester.pumpAndSettle();
    expect(port.startCalls, 1);
    expect(_button(tester, '更新接口摘要').onPressed, isNotNull);
    expect(_button(tester, '停止接口观测').onPressed, isNotNull);
    expect(_button(tester, '复制接口脱敏摘要').onPressed, isNotNull);
  });

  testWidgets('all actions share one in-flight gate', (tester) async {
    final port = _FakeYoungReadOnlyPort()
      ..emitView(_view(phase: ObservationPhase.open, ready: true))
      ..holdNextStart = true;
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.tap(find.text('开始接口观测'));
    await tester.pump();

    expect(port.startCalls, 1);
    expect(_button(tester, '开始接口观测').onPressed, isNull);
    expect(_button(tester, '更新接口摘要').onPressed, isNull);
    expect(_button(tester, '停止接口观测').onPressed, isNull);
    // The first operation invalidates any prior summary; no copy action is
    // offered until the new operation has produced a current DTO.
    expect(find.text('复制接口脱敏摘要'), findsNothing);

    port.completeHeldStart();
    await tester.pumpAndSettle();
    expect(_button(tester, '更新接口摘要').onPressed, isNotNull);

    port.holdNextRefresh = true;
    await tester.tap(find.text('更新接口摘要'));
    await tester.pump();
    expect(port.refreshCalls, 1);
    expect(_button(tester, '开始接口观测').onPressed, isNull);
    expect(_button(tester, '更新接口摘要').onPressed, isNull);
    expect(_button(tester, '停止接口观测').onPressed, isNull);
    expect(find.text('复制接口脱敏摘要'), findsOneWidget);
    expect(_button(tester, '复制接口脱敏摘要').onPressed, isNull);

    port.completeHeldRefresh();
    await tester.pumpAndSettle();
    expect(_button(tester, '停止接口观测').onPressed, isNotNull);
  });

  testWidgets('copies only the DTO safe summary, without bindings or values', (
    tester,
  ) async {
    final inspection = _makeInspection(operation: 3, listening: true);
    final port = _FakeYoungReadOnlyPort()
      ..emitView(_view(phase: ObservationPhase.open, ready: true))
      ..emitInspection(inspection);
    final copied = <String>[];
    _captureClipboard(tester, copied);
    addTearDown(() => _resetClipboard(tester));
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    expect(find.text('已接受候选：3'), findsOneWidget);
    expect(find.text('已拒绝候选：1'), findsOneWidget);
    expect(find.text('个人资料响应：1'), findsOneWidget);
    expect(find.text('个人日程响应：1'), findsOneWidget);
    expect(find.text('活动列表响应：1'), findsOneWidget);
    expect(find.textContaining('field-secret'), findsNothing);
    expect(find.textContaining('operation'), findsNothing);

    await tester.tap(find.text('复制接口脱敏摘要'));
    await tester.pumpAndSettle();

    expect(copied, [jsonEncode(inspection.safeSummary())]);
    expect(copied.single, contains('young-readonly-observation-v1'));
    expect(copied.single, isNot(contains('session')));
    expect(copied.single, isNot(contains('document')));
    expect(copied.single, isNot(contains('operation')));
    expect(copied.single, isNot(contains('field-secret')));
    expect(find.text('已复制接口脱敏摘要。'), findsOneWidget);
  });

  testWidgets('copy has its own progress label and shares the action gate', (
    tester,
  ) async {
    final inspection = _makeInspection(operation: 3, listening: false);
    final port = _FakeYoungReadOnlyPort(
      view: _view(phase: ObservationPhase.open, ready: true),
      inspection: inspection,
    );
    final copied = <String>[];
    final clipboardWrite = Completer<void>();
    var clipboardWriteStarted = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add(
            (call.arguments as Map<Object?, Object?>)['text'] as String,
          );
          clipboardWriteStarted = true;
          await clipboardWrite.future;
        }
        return null;
      },
    );
    addTearDown(() => _resetClipboard(tester));
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.tap(find.text('复制接口脱敏摘要'));
    await tester.pump();

    expect(clipboardWriteStarted, isTrue);
    expect(find.text('正在复制接口摘要'), findsOneWidget);
    expect(find.text('复制接口脱敏摘要'), findsNothing);
    expect(_button(tester, '开始接口观测').onPressed, isNull);
    expect(_button(tester, '更新接口摘要').onPressed, isNull);
    expect(_button(tester, '停止接口观测').onPressed, isNull);
    expect(copied, [jsonEncode(inspection.safeSummary())]);

    clipboardWrite.complete();
    await tester.pumpAndSettle();
    expect(find.text('已复制接口脱敏摘要。'), findsOneWidget);
    expect(_button(tester, '开始接口观测').onPressed, isNotNull);
  });

  testWidgets('operation changes invalidate old copy callbacks', (
    tester,
  ) async {
    final port = _FakeYoungReadOnlyPort()
      ..emitView(_view(phase: ObservationPhase.open, ready: true))
      ..emitInspection(_makeInspection(operation: 4));
    final copied = <String>[];
    _captureClipboard(tester, copied);
    addTearDown(() => _resetClipboard(tester));
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    final staleCopy = _button(tester, '复制接口脱敏摘要').onPressed!;
    final current = _makeInspection(operation: 5, scheduleCount: 27);
    port.emitInspection(current);
    staleCopy();
    await tester.pump();

    expect(copied, isEmpty);
    port.emitInspection(_makeInspection(operation: 5, scheduleCount: 27));
    await tester.pump();
    expect(find.text('个人日程响应：1'), findsOneWidget);
    await tester.tap(find.text('复制接口脱敏摘要'));
    await tester.pumpAndSettle();
    expect(copied, [jsonEncode(current.safeSummary())]);
  });

  testWidgets('navigation and shutdown clear a stale summary from the panel', (
    tester,
  ) async {
    final port = _FakeYoungReadOnlyPort()
      ..emitView(_view(phase: ObservationPhase.open, ready: true))
      ..emitInspection(_makeInspection(operation: 6));
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    expect(find.text('当前只读结构摘要'), findsOneWidget);

    port.emitView(
      _view(phase: ObservationPhase.open, ready: true, document: 2),
    );
    await tester.pump();
    expect(find.text('当前只读结构摘要'), findsNothing);
    expect(find.text('复制接口脱敏摘要'), findsNothing);
    expect(_button(tester, '开始接口观测').onPressed, isNotNull);
    expect(_button(tester, '更新接口摘要').onPressed, isNull);

    port.emitView(_view(phase: ObservationPhase.closing, ready: true));
    await tester.pump();
    expect(find.text('复制接口脱敏摘要'), findsNothing);
    expect(_button(tester, '开始接口观测').onPressed, isNull);
    expect(_button(tester, '更新接口摘要').onPressed, isNull);
    expect(_button(tester, '停止接口观测').onPressed, isNull);
    expect(port.startCalls, 0);
    expect(port.refreshCalls, 0);
    expect(port.stopCalls, 0);
  });

  testWidgets('non-open phases cannot start, refresh, stop, or copy', (
    tester,
  ) async {
    for (final phase in const [
      ObservationPhase.idle,
      ObservationPhase.opening,
      ObservationPhase.closing,
      ObservationPhase.recovery,
      ObservationPhase.closed,
    ]) {
      final port = _FakeYoungReadOnlyPort(
        view: _view(phase: phase, ready: true),
        inspection: _makeInspection(operation: 7, listening: true),
      );
      await tester.pumpWidget(_host(port));

      expect(_button(tester, '开始接口观测').onPressed, isNull);
      expect(_button(tester, '更新接口摘要').onPressed, isNull);
      expect(_button(tester, '停止接口观测').onPressed, isNull);
      expect(find.text('复制接口脱敏摘要'), findsNothing);
      expect(find.textContaining('请先打开既有二课观测窗口'), findsOneWidget);
      expect(port.startCalls + port.refreshCalls + port.stopCalls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await port.dispose();
    }
  });

  testWidgets('normalizes AppFailure and unexpected errors without details', (
    tester,
  ) async {
    final port = _FakeYoungReadOnlyPort()
      ..emitView(_view(phase: ObservationPhase.open, ready: true))
      ..nextStartError = StateError(
        'https://private.invalid/path?ticket=field-secret',
      );
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.tap(find.text('开始接口观测'));
    await tester.pumpAndSettle();
    expect(find.text('二课只读接口观测未能开始，请确认当前页面后重试。'), findsOneWidget);
    expect(find.textContaining('private.invalid'), findsNothing);
    expect(find.textContaining('ticket'), findsNothing);
    expect(find.textContaining('field-secret'), findsNothing);
    expect(find.textContaining('StateError'), findsNothing);

    port.nextStartError = const AppFailure(FailureCode.staleResult);
    await tester.tap(find.text('开始接口观测'));
    await tester.pumpAndSettle();
    expect(find.text('页面或观测已变化，本次结果已丢弃，请在当前目标页面重新开始。'), findsOneWidget);
  });

  testWidgets('late operation completion is ignored after page navigation', (
    tester,
  ) async {
    final port = _FakeYoungReadOnlyPort()
      ..emitView(_view(phase: ObservationPhase.open, ready: true))
      ..emitInspection(_makeInspection(operation: 8, listening: true))
      ..holdNextRefresh = true;
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.tap(find.text('更新接口摘要'));
    await tester.pump();
    expect(port.refreshCalls, 1);

    port.emitView(
      _view(phase: ObservationPhase.open, ready: true, document: 2),
    );
    await tester.pump();
    port.refreshFailure = StateError('late secret.invalid response');
    port.completeHeldRefresh();
    await tester.pumpAndSettle();

    expect(find.textContaining('late secret.invalid'), findsNothing);
    expect(find.textContaining('更新失败'), findsNothing);
    expect(find.text('当前只读结构摘要'), findsNothing);
  });

  testWidgets('dispose cancels both subscriptions and ignores pending work', (
    tester,
  ) async {
    final port = _FakeYoungReadOnlyPort()
      ..emitView(_view(phase: ObservationPhase.open, ready: true))
      ..holdNextStart = true;

    await tester.pumpWidget(_host(port));
    await tester.tap(find.text('开始接口观测'));
    await tester.pump();
    expect(port.hasViewListener, isTrue);
    expect(port.hasReadOnlyListener, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    port.completeHeldStart();
    await tester.pump();
    await tester.pump();

    expect(port.hasViewListener, isFalse);
    expect(port.hasReadOnlyListener, isFalse);
    expect(tester.takeException(), isNull);
    await port.dispose();
  });

  for (final size in const [Size(800, 600), Size(320, 560)]) {
    testWidgets('has no overflow at ${size.width}x${size.height}', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final port = _FakeYoungReadOnlyPort(
        view: _view(phase: ObservationPhase.open, ready: true),
        inspection: _makeInspection(operation: 9, listening: true),
      );
      addTearDown(port.dispose);

      await tester.pumpWidget(_host(port));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expect(find.text('复制接口脱敏摘要'), findsOneWidget);
    });
  }
}

ObservationView _view({
  required ObservationPhase phase,
  required bool ready,
  int session = 1,
  int document = 1,
}) => ObservationView(
  phase: phase,
  ready: ready,
  youngInspection: ready
      ? YoungPageInspection(
          session: session,
          document: document,
          ready: true,
          surface: YoungSurface.application,
          tables: 1,
          calendarRoots: 0,
          paginationControls: 0,
          passwordInputs: 0,
        )
      : null,
);

YoungReadOnlyInspection _makeInspection({
  required int operation,
  bool listening = false,
  int scheduleCount = 12,
}) {
  const profile = <String, Object?>{
    'observations': 1,
    'success': 'true',
    'code': 'number',
    'result': 'object',
    'loginCode': 'string',
    'username': 'string',
  };
  final schedule = <String, Object?>{
    'observations': 1,
    'success': 'true',
    'code': 'number',
    'result': 'array',
    'records': 'array',
    'count': scheduleCount,
    'total': 'number',
    'id': 'string',
    'title': 'string',
    'date': 'string',
    'startTime': 'string',
    'endTime': 'string',
  };
  const activities = <String, Object?>{
    'observations': 1,
    'success': 'true',
    'code': 'number',
    'result': 'array',
    'records': 'array',
    'count': 4,
    'total': 'number',
    'id': 'string',
    'title': 'string',
    'date': 'string',
    'startTime': 'string',
    'endTime': 'string',
  };
  return YoungReadOnlyInspection.decode(
    <String, Object?>{
      'session': 1,
      'document': 1,
      'operation': operation,
      'listening': listening,
      'accepted': 3,
      'rejected': 1,
      'lastRejection': 'target',
      'profile': profile,
      'schedule': schedule,
      'activities': activities,
    },
    session: 1,
    document: 1,
    operation: operation,
  );
}

Widget _host(YoungReadOnlyObservationPort port) => MaterialApp(
  home: Scaffold(body: YoungReadOnlyPanel(observation: port)),
);

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

class _FakeYoungReadOnlyPort implements YoungReadOnlyObservationPort {
  _FakeYoungReadOnlyPort({ObservationView? view, this._inspection})
    : _view = view ?? const ObservationView(phase: ObservationPhase.idle) {
    if (_inspection != null) _readOnlyChanges.add(_inspection);
  }

  final StreamController<ObservationView> _viewChanges =
      StreamController<ObservationView>.broadcast(sync: true);
  final StreamController<YoungReadOnlyInspection?> _readOnlyChanges =
      StreamController<YoungReadOnlyInspection?>.broadcast(sync: true);
  ObservationView _view;
  YoungReadOnlyInspection? _inspection;
  bool holdNextStart = false;
  bool holdNextRefresh = false;
  Object? nextStartError;
  Object? refreshFailure;
  Completer<void>? _heldStart;
  Completer<void>? _heldRefresh;
  int startCalls = 0;
  int refreshCalls = 0;
  int stopCalls = 0;

  @override
  ObservationView get view => _view;

  @override
  Stream<ObservationView> get changes => _viewChanges.stream;

  @override
  YoungReadOnlyInspection? get readOnlyInspection => _inspection;

  @override
  Stream<YoungReadOnlyInspection?> get readOnlyChanges =>
      _readOnlyChanges.stream;

  bool get hasViewListener => _viewChanges.hasListener;

  bool get hasReadOnlyListener => _readOnlyChanges.hasListener;

  @override
  Future<void> startReadOnlyInspection() async {
    startCalls++;
    final error = nextStartError;
    nextStartError = null;
    if (error != null) throw error;
    if (holdNextStart) {
      holdNextStart = false;
      _heldStart = Completer<void>();
      emitInspection(
        _inspection == null
            ? _inspectionForNewOperation(1, listening: true)
            : _inspection!.withListening(true),
      );
      await _heldStart!.future;
      _heldStart = null;
      final current = _inspection;
      if (current != null) {
        emitInspection(
          _inspectionForNewOperation(current.operation, listening: true),
        );
      }
      return;
    }
    final operation = (_inspection?.operation ?? 0) + 1;
    emitInspection(_inspectionForNewOperation(operation, listening: true));
    emitInspection(_inspectionForNewOperation(operation, listening: true));
  }

  @override
  Future<void> refreshReadOnlyInspection() async {
    refreshCalls++;
    if (holdNextRefresh) {
      holdNextRefresh = false;
      _heldRefresh = Completer<void>();
      await _heldRefresh!.future;
      _heldRefresh = null;
    }
    final error = refreshFailure;
    refreshFailure = null;
    if (error != null) throw error;
    final current = _inspection;
    if (current != null) emitInspection(current);
  }

  @override
  Future<void> stopReadOnlyInspection() async {
    stopCalls++;
    final current = _inspection;
    if (current != null) emitInspection(current.withListening(false));
  }

  YoungReadOnlyInspection _inspectionForNewOperation(
    int operation, {
    required bool listening,
  }) => _makeInspection(operation: operation, listening: listening);

  void emitView(ObservationView view) {
    _view = view;
    _viewChanges.add(view);
  }

  void emitInspection(YoungReadOnlyInspection? inspection) {
    _inspection = inspection;
    _readOnlyChanges.add(inspection);
  }

  void completeHeldStart() {
    final held = _heldStart;
    if (held == null || held.isCompleted) return;
    held.complete();
  }

  void completeHeldRefresh() {
    final held = _heldRefresh;
    if (held == null || held.isCompleted) return;
    held.complete();
  }

  @override
  Future<void> open() async {}

  @override
  Future<void> inspect() async {}

  @override
  Future<void> navigateInitial() async {}

  @override
  Future<void> navigateJwPage(JwObservationPage page) async {}

  @override
  Future<void> closeSession() async {}

  @override
  Future<void> retryCleanup() async {}

  @override
  Future<void> inspectYoungPage() async {}

  Future<void> dispose() async {
    completeHeldStart();
    completeHeldRefresh();
    await _viewChanges.close();
    await _readOnlyChanges.close();
  }
}
