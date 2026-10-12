import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ustc_assistant_m0/app/young_business_probe_panel.dart';
import 'package:ustc_assistant_m0/jobs/observation_port.dart';
import 'package:ustc_assistant_m0/jobs/young_business_probe_port.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';
import 'package:ustc_assistant_m0/source/young_active_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('requires an open ready observation and available candidate', (
    tester,
  ) async {
    final port = _FakeYoungBusinessProbePort();
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));

    expect(find.text('M2 二课身份与数据验证'), findsOneWidget);
    expect(_button(tester, '打开活动列表').onPressed, isNull);
    expect(_button(tester, '验证活动查询').onPressed, isNull);

    port.emitObservation(
      const ObservationView(phase: ObservationPhase.open, ready: true),
    );
    port.emitBusiness(const YoungBusinessView(available: false));
    await tester.pump();
    expect(_button(tester, '打开活动列表').onPressed, isNotNull);
    expect(_button(tester, '验证活动查询').onPressed, isNull);

    port.emitBusiness(const YoungBusinessView(available: true));
    await tester.pump();
    expect(_button(tester, '验证活动查询').onPressed, isNotNull);
  });

  testWidgets(
    'dispatches activities, navigates, and clears the expected code',
    (tester) async {
      final port = _readyPort();
      addTearDown(port.dispose);
      await tester.pumpWidget(_host(port));

      await tester.tap(find.text('打开活动列表'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开个人日程'));
      await tester.pumpAndSettle();
      expect(port.navigatedPages, [
        YoungBusinessPage.activities,
        YoungBusinessPage.calendar,
      ]);

      await tester.enterText(
        find.byKey(const ValueKey<String>('young-business-account')),
        ' 12345678 ',
      );
      await tester.tap(find.text('验证活动查询'));
      await tester.pumpAndSettle();

      expect(port.activityCalls, 1);
      expect(port.lastExpectedAccountCode, '12345678');
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey<String>('young-business-account')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(find.textContaining('private-account'), findsNothing);
    },
  );

  testWidgets('dispatches the selected inclusive date range', (tester) async {
    final port = _readyPort();
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));

    await tester.enterText(
      find.byKey(const ValueKey<String>('young-business-account')),
      '24681357',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('young-business-first-day')),
      '2026-10-01',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('young-business-last-day')),
      '2026-10-31',
    );
    await tester.tap(find.text('验证日程范围'));
    await tester.pumpAndSettle();

    expect(port.calendarCalls, 1);
    expect(port.lastExpectedAccountCode, '24681357');
    expect(port.lastFirstDay, DateTime.utc(2026, 10, 1));
    expect(port.lastLastDay, DateTime.utc(2026, 10, 31));
  });

  testWidgets('disables duplicate probes while running and permits cancel', (
    tester,
  ) async {
    final port = _readyPort()..holdNextProbe = true;
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));

    await tester.enterText(
      find.byKey(const ValueKey<String>('young-business-account')),
      '13572468',
    );
    await tester.tap(find.text('验证活动查询'));
    await tester.pump();

    expect(port.activityCalls, 1);
    expect(_button(tester, '验证活动查询').onPressed, isNull);
    expect(_button(tester, '打开个人日程').onPressed, isNull);
    expect(find.text('取消本次验证'), findsOneWidget);

    await tester.tap(find.text('取消本次验证'));
    await tester.pumpAndSettle();
    expect(port.cancelCalls, 1);
    expect(port.businessView.phase, YoungBusinessPhase.done);
    expect(tester.takeException(), isNull);
  });

  testWidgets('copies only the fixed closed summary fields', (tester) async {
    final port = _readyPort()
      ..emitBusiness(
        const YoungBusinessView(
          phase: YoungBusinessPhase.done,
          identity: YoungBusinessIdentity.candidateMatches,
          activities: 69,
          activityPages: 7,
          calendarRows: 4,
          linkedSchedules: 1,
          excludedSchedules: 3,
          days: 2,
          calendarPages: 2,
          identityReads: 2,
          available: true,
        ),
      );
    final copied = <String>[];
    _captureClipboard(tester, copied);
    addTearDown(() => _resetClipboard(tester));
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));

    await tester.tap(find.text('复制二课验证摘要'));
    await tester.pumpAndSettle();

    expect(copied, [
      '{"kind":"young-active-contract-v1","phase":"done","identity":"candidateMatches","sourceAvailable":false,"activities":69,"activityPages":7,"calendarRows":4,"linkedSchedules":1,"excludedSchedules":3,"days":2,"calendarPages":2,"identityReads":2}',
    ]);
    expect(copied.single, isNot(contains('busy')));
    expect(copied.single, isNot(contains('available')));
    expect(find.text('已复制二课验证摘要。'), findsOneWidget);
  });

  testWidgets('ignores a probe completion after panel disposal', (
    tester,
  ) async {
    final port = _readyPort()..holdNextProbe = true;
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));
    await tester.enterText(
      find.byKey(const ValueKey<String>('young-business-account')),
      '98765432',
    );
    await tester.tap(find.text('验证活动查询'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    port.completeHeldProbe();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}

Widget _host(YoungBusinessProbePort port) => MaterialApp(
  home: Scaffold(body: YoungBusinessProbePanel(observation: port)),
);

_FakeYoungBusinessProbePort _readyPort() => _FakeYoungBusinessProbePort()
  ..emitObservation(
    const ObservationView(phase: ObservationPhase.open, ready: true),
  )
  ..emitBusiness(const YoungBusinessView(available: true));

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

final class _FakeYoungBusinessProbePort implements YoungBusinessProbePort {
  final StreamController<ObservationView> _observationChanges =
      StreamController<ObservationView>.broadcast(sync: true);
  final StreamController<YoungBusinessView> _businessChanges =
      StreamController<YoungBusinessView>.broadcast(sync: true);

  ObservationView _view = const ObservationView(phase: ObservationPhase.idle);
  YoungBusinessView _businessView = const YoungBusinessView();
  bool holdNextProbe = false;
  Completer<void>? _heldProbe;
  int activityCalls = 0;
  int calendarCalls = 0;
  int cancelCalls = 0;
  String? lastExpectedAccountCode;
  DateTime? lastFirstDay;
  DateTime? lastLastDay;
  final List<YoungBusinessPage> navigatedPages = <YoungBusinessPage>[];

  @override
  ObservationView get view => _view;

  @override
  Stream<ObservationView> get changes => _observationChanges.stream;

  @override
  YoungBusinessView get businessView => _businessView;

  @override
  Stream<YoungBusinessView> get businessChanges => _businessChanges.stream;

  @override
  Future<void> open() async {}

  @override
  Future<void> inspect() async {}

  @override
  Future<void> inspectYoungPage() async {}

  @override
  Future<void> navigateInitial() async {}

  @override
  Future<void> navigateJwPage(JwObservationPage page) async {}

  @override
  Future<void> closeSession() async {}

  @override
  Future<void> retryCleanup() async {}

  @override
  Future<void> navigateYoungPage(YoungBusinessPage page) async {
    navigatedPages.add(page);
  }

  @override
  Future<void> probeYoungActivities(String expectedAccountCode) async {
    activityCalls++;
    lastExpectedAccountCode = expectedAccountCode;
    if (holdNextProbe) {
      holdNextProbe = false;
      _heldProbe = Completer<void>();
      emitBusiness(
        const YoungBusinessView(
          phase: YoungBusinessPhase.running,
          stage: YoungBusinessStage.profileBefore,
          busy: true,
          available: true,
        ),
      );
      await _heldProbe!.future;
    }
    emitBusiness(
      const YoungBusinessView(
        phase: YoungBusinessPhase.done,
        identity: YoungBusinessIdentity.candidateMatches,
        activities: 69,
        activityPages: 7,
        identityReads: 2,
        available: true,
      ),
    );
  }

  @override
  Future<void> probeYoungCalendar({
    required String expectedAccountCode,
    required DateTime firstDay,
    required DateTime lastDay,
  }) async {
    calendarCalls++;
    lastExpectedAccountCode = expectedAccountCode;
    lastFirstDay = firstDay;
    lastLastDay = lastDay;
    emitBusiness(
      const YoungBusinessView(
        phase: YoungBusinessPhase.done,
        identity: YoungBusinessIdentity.candidateMatches,
        calendarRows: 4,
        linkedSchedules: 1,
        excludedSchedules: 3,
        days: 31,
        calendarPages: 31,
        identityReads: 2,
        available: true,
      ),
    );
  }

  @override
  Future<void> cancelYoungBusinessProbe() async {
    cancelCalls++;
    completeHeldProbe();
  }

  void emitObservation(ObservationView value) {
    _view = value;
    _observationChanges.add(value);
  }

  void emitBusiness(YoungBusinessView value) {
    _businessView = value;
    _businessChanges.add(value);
  }

  void completeHeldProbe() {
    _heldProbe?.complete();
    _heldProbe = null;
  }

  Future<void> dispose() async {
    completeHeldProbe();
    await _observationChanges.close();
    await _businessChanges.close();
  }
}
