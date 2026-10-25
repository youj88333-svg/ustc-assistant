import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/jw_data_probe_panel.dart';
import 'package:ustc_assistant_m0/data/jw_candidate_identity.dart';
import 'package:ustc_assistant_m0/jobs/jw_data_probe_port.dart';
import 'package:ustc_assistant_m0/jobs/jw_probe_port.dart';
import 'package:ustc_assistant_m0/source/jw_data_probe_contract.dart';
import 'package:ustc_assistant_m0/source/jw_probe_contract.dart';

void main() {
  testWidgets(
    'requires a directory selection and clears private input on run',
    (tester) async {
      final probe = _FakeProbePort(
        _acceptedProbeView(
          semesters: const [
            JwSemesterOption(id: 11, name: '2025 春季', selected: false),
            JwSemesterOption(id: 12, name: '2025 秋季', selected: false),
          ],
        ),
      );
      final data = _FakeDataProbePort(holdRun: true);
      addTearDown(probe.dispose);
      addTearDown(data.dispose);
      await tester.pumpWidget(_host(probe, data));

      expect(_field(tester).obscureText, isTrue);
      expect(_field(tester).autofillHints, isEmpty);
      expect(_button(tester, '验证数据接口').onPressed, isNull);

      await tester.tap(find.byKey(const ValueKey('jw-data-probe-semester')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2025 秋季').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(_accountField), 'AB12345');
      await tester.tap(find.text('验证数据接口'));
      await tester.pump();

      expect(data.runCalls, 1);
      expect(data.receivedAccountCode, 'AB12345');
      expect(data.receivedSemesterId, 12);
      expect(_field(tester).controller!.text, isEmpty);
      expect(find.textContaining('AB12345'), findsNothing);
      data.completeHeldRun();
      await tester.pump();
    },
  );

  testWidgets('defaults only the single accepted selected semester', (
    tester,
  ) async {
    final probe = _FakeProbePort(
      _acceptedProbeView(
        semesters: const [
          JwSemesterOption(id: 31, name: '2026 春季', selected: false),
          JwSemesterOption(id: 32, name: '2026 秋季', selected: true),
        ],
      ),
    );
    final data = _FakeDataProbePort();
    addTearDown(probe.dispose);
    addTearDown(data.dispose);
    await tester.pumpWidget(_host(probe, data));
    await tester.enterText(find.byKey(_accountField), 'AB12345');

    expect(_button(tester, '验证数据接口').onPressed, isNotNull);
    await tester.tap(find.text('验证数据接口'));
    await tester.pump();
    expect(data.receivedSemesterId, 32);
    expect(_field(tester).controller!.text, isEmpty);
  });

  testWidgets('unavailable port disables submission', (tester) async {
    final probe = _FakeProbePort(_acceptedProbeView());
    final data = _FakeDataProbePort(available: false);
    addTearDown(probe.dispose);
    addTearDown(data.dispose);
    await tester.pumpWidget(_host(probe, data));

    expect(_button(tester, '验证数据接口').onPressed, isNull);
  });

  testWidgets('either controller busy disables semester changes and submit', (
    tester,
  ) async {
    final probe = _FakeProbePort(_acceptedProbeView(busy: true));
    final data = _FakeDataProbePort();
    addTearDown(probe.dispose);
    addTearDown(data.dispose);
    await tester.pumpWidget(_host(probe, data));

    final dropdown = tester.widget<DropdownButtonFormField<int>>(
      find.byKey(const ValueKey('jw-data-probe-semester')),
    );
    expect(dropdown.onChanged, isNull);
    expect(_button(tester, '验证数据接口').onPressed, isNull);
  });

  testWidgets('cancels an active check through the data controller', (
    tester,
  ) async {
    final probe = _FakeProbePort(_acceptedProbeView());
    final data = _FakeDataProbePort(holdRun: true);
    addTearDown(probe.dispose);
    addTearDown(data.dispose);
    await tester.pumpWidget(_host(probe, data));
    await tester.enterText(find.byKey(_accountField), 'AB12345');
    await tester.tap(find.text('验证数据接口'));
    await tester.pump();
    expect(find.text('取消并清理观测窗口'), findsOneWidget);

    await tester.tap(find.text('取消并清理观测窗口'));
    await tester.pump();
    expect(data.cancelCalls, 1);
    expect(find.text('检查已取消，临时会话已请求排空。'), findsOneWidget);
    data.completeHeldRun();
    await tester.pump();
  });

  testWidgets('copies only the closed data summary', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
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

    final probe = _FakeProbePort(_acceptedProbeView());
    final data = _FakeDataProbePort(view: _completedDataView());
    addTearDown(probe.dispose);
    addTearDown(data.dispose);
    await tester.pumpWidget(_host(probe, data));
    await tester.ensureVisible(find.text('复制数据脱敏摘要'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制数据脱敏摘要'));
    await tester.pumpAndSettle();

    expect(copied, isNotNull);
    final summary = jsonDecode(copied!) as Map<String, Object?>;
    expect(summary['kind'], 'jw-data-contract-v1');
    expect(summary['sourceAvailable'], false);
    expect(copied, isNot(contains('AB12345')));
    expect(copied, isNot(contains('semesterId')));
    expect(copied, isNot(contains('2026 秋季')));
    expect(find.text('课表为空：是'), findsOneWidget);
    expect(find.text('考试为空：是'), findsOneWidget);
    expect(find.text('发现分页：是'), findsOneWidget);
    expect(find.textContaining('课程原文'), findsNothing);
  });

  testWidgets('late result from replaced controller cannot update the panel', (
    tester,
  ) async {
    final oldProbe = _FakeProbePort(_acceptedProbeView());
    final oldData = _FakeDataProbePort(holdRun: true);
    final newProbe = _FakeProbePort(_acceptedProbeView());
    final newData = _FakeDataProbePort();
    addTearDown(oldProbe.dispose);
    addTearDown(oldData.dispose);
    addTearDown(newProbe.dispose);
    addTearDown(newData.dispose);
    await tester.pumpWidget(_host(oldProbe, oldData));
    await tester.enterText(find.byKey(_accountField), 'AB12345');
    await tester.tap(find.text('验证数据接口'));
    await tester.pump();

    await tester.pumpWidget(_host(newProbe, newData));
    oldData.failHeldRun(StateError('old request completed late'));
    await tester.pump();

    expect(find.text('数据接口检查请求失败，请检查观测页面后重试。'), findsNothing);
    expect(_field(tester).controller!.text, isEmpty);
  });
}

const _accountField = ValueKey('jw-data-probe-expected-account');

Widget _host(JwProbePort probe, JwDataProbePort data) => MaterialApp(
  home: JwDataProbePanel(probeController: probe, controller: data),
);

TextField _field(WidgetTester tester) =>
    tester.widget(find.byKey(_accountField));

ButtonStyleButton _button(WidgetTester tester, String label) => tester.widget(
  find.ancestor(
    of: find.text(label),
    matching: find.bySubtype<ButtonStyleButton>(),
  ),
);

JwProbeView _acceptedProbeView({
  List<JwSemesterOption> semesters = const [
    JwSemesterOption(id: 41, name: '2026 秋季', selected: true),
  ],
  bool busy = false,
}) => JwProbeView(
  phase: JwProbePhase.done,
  code: JwProbeCode.ok,
  identity: JwCandidateIdentity.candidateMatches,
  summary: JwProbeSummary(
    identityLabels: 1,
    semesterOptions: semesters.length,
    examTables: 1,
    examRows: 0,
    semesterSelect: true,
    examHeader: true,
    pagination: false,
    semesterVariables: const {
      'allSemesters': true,
      'semesters': false,
      'semesterId': true,
      'bizTypeId': false,
    },
    stageResults: const {
      'identity': JwProbeCode.ok,
      'course': JwProbeCode.ok,
      'exams': JwProbeCode.ok,
    },
    courseDiagnostics: const JwCourseDiagnostics(
      reason: 'none',
      source: 'serverSelect',
    ),
  ),
  semesters: semesters,
  available: true,
  busy: busy,
);

JwDataProbeView _completedDataView() => JwDataProbeView(
  phase: JwProbePhase.done,
  code: JwDataProbeCode.ok,
  identity: JwCandidateIdentity.candidateMatches,
  diagnostics: JwDataDiagnostics(
    checks: const {
      'identityBefore': 'ok',
      'course': 'ok',
      'index': 'ok',
      'datum': 'ok',
      'exams': 'ok',
      'identityAfter': 'ok',
    },
    reason: 'none',
    identityReads: 2,
    lessonIds: 0,
    lessons: 0,
    groups: 0,
    schedules: 0,
    datedSchedules: 0,
    timedSchedules: 0,
    linkedSchedules: 0,
    examRows: 0,
    datedExams: 0,
    semesterAccepted: true,
    selfRouteBound: true,
    identityStable: true,
    emptyCourse: true,
    emptyExams: true,
    pagination: true,
    types: const {
      'lessonIds': 'array',
      'lessonList': 'array',
      'scheduleGroupList': 'array',
      'scheduleList': 'array',
      'date': 'missing',
      'startTime': 'missing',
      'endTime': 'missing',
    },
  ),
  available: true,
);

class _FakeProbePort implements JwProbePort {
  _FakeProbePort(this._view);

  final StreamController<JwProbeView> _changes =
      StreamController<JwProbeView>.broadcast(sync: true);
  final JwProbeView _view;

  @override
  JwProbeView get probeView => _view;

  @override
  Stream<JwProbeView> get probeChanges => _changes.stream;

  @override
  Future<void> runProbe(String expectedAccountCode) async {}

  @override
  Future<void> cancelProbe() async {}

  Future<void> dispose() => _changes.close();
}

class _FakeDataProbePort implements JwDataProbePort {
  _FakeDataProbePort({
    JwDataProbeView? view,
    bool available = true,
    this.holdRun = false,
  }) : _view = view ?? JwDataProbeView(available: available);

  final StreamController<JwDataProbeView> _changes =
      StreamController<JwDataProbeView>.broadcast(sync: true);
  JwDataProbeView _view;
  Completer<void>? _heldRun;
  final bool holdRun;
  String? receivedAccountCode;
  int? receivedSemesterId;
  int runCalls = 0;
  int cancelCalls = 0;

  @override
  JwDataProbeView get dataProbeView => _view;

  @override
  Stream<JwDataProbeView> get dataProbeChanges => _changes.stream;

  @override
  Future<void> runDataProbe(
    String expectedAccountCode, {
    required int semesterId,
  }) {
    runCalls++;
    receivedAccountCode = expectedAccountCode;
    receivedSemesterId = semesterId;
    _emit(
      JwDataProbeView(
        phase: JwProbePhase.running,
        code: JwDataProbeCode.pending,
        available: true,
        busy: true,
      ),
    );
    if (holdRun) {
      _heldRun = Completer<void>();
      return _heldRun!.future;
    }
    return Future<void>.value();
  }

  @override
  Future<void> cancelDataProbe() async {
    cancelCalls++;
    _emit(
      const JwDataProbeView(
        phase: JwProbePhase.cancelled,
        code: JwDataProbeCode.cancelled,
        available: true,
      ),
    );
  }

  void _emit(JwDataProbeView view) {
    _view = view;
    _changes.add(view);
  }

  void completeHeldRun() {
    final held = _heldRun;
    _heldRun = null;
    if (held != null && !held.isCompleted) held.complete();
  }

  void failHeldRun(Object error) {
    final held = _heldRun;
    _heldRun = null;
    if (held != null && !held.isCompleted) held.completeError(error);
  }

  Future<void> dispose() async {
    completeHeldRun();
    await _changes.close();
  }
}
