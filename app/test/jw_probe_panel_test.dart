import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/jw_probe_panel.dart';
import 'package:ustc_assistant_m0/data/jw_candidate_identity.dart';
import 'package:ustc_assistant_m0/jobs/jw_probe_port.dart';
import 'package:ustc_assistant_m0/source/jw_probe_contract.dart';

void main() {
  testWidgets('validates privately, clears on submit, and never echoes input', (
    tester,
  ) async {
    final port = _FakeJwProbePort(available: true)..holdRun = true;
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));
    expect(_field(tester).obscureText, isTrue);
    expect(_field(tester).autocorrect, isFalse);
    expect(_field(tester).enableSuggestions, isFalse);
    expect(_field(tester).autofillHints, isEmpty);

    await tester.enterText(_accountField, 'abc123');
    await tester.tap(find.text('验证只读契约'));
    await tester.pump();
    expect(port.runCalls, 0);
    expect(_field(tester).controller!.text, isEmpty);
    expect(find.text('请输入5至24位大写英文字母或数字。'), findsOneWidget);

    const privateAccountCode = 'AB12345';
    await tester.enterText(_accountField, '  $privateAccountCode  ');
    await tester.tap(find.text('验证只读契约'));
    await tester.pump();

    expect(port.runCalls, 1);
    expect(port.receivedAccountCode, privateAccountCode);
    expect(_field(tester).controller!.text, isEmpty);
    expect(find.textContaining(privateAccountCode), findsNothing);

    port.completeHeldRun();
    await tester.pump();
  });

  testWidgets(
    'keeps a matching candidate unverified and shows structural counts and pagination',
    (tester) async {
      final port = _FakeJwProbePort(
        view: _doneView(
          identity: JwCandidateIdentity.candidateMatches,
          summary: _summary(pagination: true),
          semesters: const [
            JwSemesterOption(id: 1, name: '2026-2027 第一学期', selected: true),
          ],
        ),
      );
      addTearDown(port.dispose);
      await tester.pumpWidget(_host(port));

      expect(find.text('候选状态：候选匹配'), findsOneWidget);
      expect(find.textContaining('当前固定阶段'), findsNothing);
      expect(
        find.text('结构检查通过不代表身份可信或正式来源可用；候选匹配仍需确认与当前登录会话的绑定。'),
        findsOneWidget,
      );
      expect(find.textContaining('身份核验通过'), findsNothing);
      expect(find.textContaining('来源已可用'), findsNothing);
      expect(find.text('候选数：1'), findsOneWidget);
      expect(find.text('学期选项数：1'), findsOneWidget);
      expect(find.text('考试表/行数：2 / 7'), findsOneWidget);
      expect(find.text('已识别八列表头：是'), findsOneWidget);
      expect(find.text('发现分页：是'), findsOneWidget);
      expect(find.text('发现分页结构；当前摘要不代表已读取所有分页。'), findsOneWidget);
      expect(find.text('2026-2027 第一学期'), findsOneWidget);
      expect(find.text('复制脱敏摘要'), findsOneWidget);
    },
  );

  testWidgets(
    'shows course schema failure beside successful zero-row exam check',
    (tester) async {
      final port = _FakeJwProbePort(
        view: _doneView(
          phase: JwProbePhase.failed,
          code: JwProbeCode.courseSchema,
          identity: JwCandidateIdentity.candidateMatches,
          stage: 'course',
          summary: _summary(
            semesterOptions: 0,
            examTables: 1,
            examRows: 0,
            semesterSelect: false,
            examHeader: true,
            courseDiagnostics: _courseDiagnostics(
              reason: 'option_duplicate',
              serverOptions: 2,
              liveOptions: 2,
            ),
            stageResults: const {
              'identity': JwProbeCode.ok,
              'course': JwProbeCode.courseSchema,
              'exams': JwProbeCode.ok,
            },
          ),
        ),
      );
      addTearDown(port.dispose);
      await tester.pumpWidget(_host(port));

      expect(find.text('首个失败项：课表学期'), findsOneWidget);
      expect(find.text('身份页结构检查：通过'), findsOneWidget);
      expect(find.text('课表学期检查：未通过：来源结构不符合固定契约，该结果已拒绝。'), findsOneWidget);
      expect(find.text('课表拒绝原因：学期选项值重复。'), findsOneWidget);
      expect(find.text('考试表格检查：通过'), findsOneWidget);
      expect(find.text('考试表/行数：1 / 0'), findsOneWidget);
      expect(find.textContaining('当前固定阶段'), findsNothing);
      expect(find.textContaining('身份可信'), findsOneWidget);
      expect(find.textContaining('来源已可用'), findsNothing);
    },
  );

  testWidgets(
    'treats live semester options as a hint when no directory is accepted',
    (tester) async {
      final port = _FakeJwProbePort(
        view: _doneView(
          phase: JwProbePhase.failed,
          code: JwProbeCode.courseSchema,
          identity: JwCandidateIdentity.candidateMatches,
          stage: 'course',
          summary: _summary(
            semesterOptions: 0,
            semesterSelect: true,
            courseDiagnostics: _courseDiagnostics(
              reason: 'literal_missing',
              source: 'none',
              serverOptions: 0,
              liveOptions: 2,
              literalAssignments: 3,
            ),
            stageResults: const {
              'identity': JwProbeCode.ok,
              'course': JwProbeCode.courseSchema,
              'exams': JwProbeCode.ok,
            },
          ),
        ),
      );
      addTearDown(port.dispose);
      await tester.pumpWidget(_host(port));

      expect(find.text('服务端选项数：0'), findsOneWidget);
      expect(find.text('当前页面选项数（仅诊断）：2'), findsOneWidget);
      expect(find.text('脚本字面赋值数：3'), findsOneWidget);
      expect(find.text('服务端 JSON 目录项数：0'), findsOneWidget);
      expect(find.text('服务端 JSON 目录解析：否'), findsOneWidget);
      expect(find.text('学期目录读取来源：未接受'), findsOneWidget);
      expect(find.text('课表拒绝原因：未找到符合固定契约的服务端学期目录数据。'), findsOneWidget);
      expect(find.text('课表学期检查：未通过：来源结构不符合固定契约，该结果已拒绝。'), findsOneWidget);
      expect(find.text('课表学期检查：通过'), findsNothing);
    },
  );

  testWidgets(
    'shows an accepted server JSON directory as the semester source',
    (tester) async {
      final port = _FakeJwProbePort(
        view: _doneView(
          summary: _summary(
            semesterOptions: 2,
            semesterSelect: false,
            courseDiagnostics: _courseDiagnostics(
              reason: 'none',
              source: 'serverJson',
              serverOptions: 0,
              liveOptions: 2,
              literalAssignments: 1,
              literalItems: 2,
              literalParsed: true,
            ),
            stageResults: const {
              'identity': JwProbeCode.ok,
              'course': JwProbeCode.ok,
              'exams': JwProbeCode.ok,
            },
          ),
        ),
      );
      addTearDown(port.dispose);
      await tester.pumpWidget(_host(port));

      expect(find.text('学期选项数：2'), findsOneWidget);
      expect(find.text('服务端 JSON 目录项数：2'), findsOneWidget);
      expect(find.text('服务端 JSON 目录解析：是'), findsOneWidget);
      expect(find.text('学期目录读取来源：服务器 JSON 数据'), findsOneWidget);
      expect(find.text('课表学期检查：通过'), findsOneWidget);
      expect(find.textContaining('课表拒绝原因：'), findsNothing);
    },
  );

  testWidgets('keeps unknown course diagnostic reasons fixed and private', (
    tester,
  ) async {
    const privateReason = 'private response fragment';
    final port = _FakeJwProbePort(
      view: _doneView(
        summary: _summary(
          courseDiagnostics: _courseDiagnostics(reason: privateReason),
        ),
      ),
    );
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));

    expect(find.text('课表拒绝原因：课表诊断原因无法识别，已安全拒绝。'), findsOneWidget);
    expect(find.textContaining(privateReason), findsNothing);
  });

  testWidgets('shows each sequential check and its active step while running', (
    tester,
  ) async {
    final port = _FakeJwProbePort(available: true)..holdRun = true;
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));
    expect(
      find.text(
        '请先在观测窗口手动登录并填写预期学号。上方入口按钮只用于打开业务页；点击“验证只读契约”后，会依次检查身份页、课表学期和考试表格。',
      ),
      findsOneWidget,
    );
    await tester.enterText(_accountField, 'AB12345');
    await tester.tap(find.text('验证只读契约'));
    await tester.pump();

    expect(find.text('正在检查：身份页'), findsOneWidget);
    expect(find.text('身份页结构检查：进行中'), findsOneWidget);
    expect(find.text('课表学期检查：未检查'), findsOneWidget);
    expect(find.text('考试表格检查：未检查'), findsOneWidget);

    await tester.tap(find.text('取消并清理观测窗口'));
    await tester.pump();
    port.completeHeldRun();
    await tester.pump();
  });

  testWidgets(
    'prevents duplicate run calls and allows cancel during a held run',
    (tester) async {
      final port = _FakeJwProbePort(available: true)..holdRun = true;
      addTearDown(port.dispose);
      await tester.pumpWidget(_host(port));
      await tester.enterText(_accountField, 'AB12345');
      await tester.tap(find.text('验证只读契约'));
      await tester.pump();

      expect(port.runCalls, 1);
      expect(_button(tester, '验证只读契约').onPressed, isNull);
      expect(_button(tester, '取消并清理观测窗口').onPressed, isNotNull);

      await tester.tap(find.text('取消并清理观测窗口'));
      await tester.pump();
      expect(port.cancelCalls, 1);
      expect(find.text('验证已取消，临时会话已请求排空。'), findsOneWidget);

      port.completeHeldRun();
      await tester.pump();
    },
  );

  testWidgets('replaces unsafe async errors with fixed copy', (tester) async {
    final port = _FakeJwProbePort(available: true)
      ..nextRunError = StateError('ticket=private-session-value');
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));
    await tester.enterText(_accountField, 'AB12345');
    await tester.tap(find.text('验证只读契约'));
    await tester.pumpAndSettle();

    expect(find.text('验证请求失败，请检查观测页面后重试。'), findsOneWidget);
    expect(find.textContaining('ticket='), findsNothing);
    expect(find.textContaining('private-session-value'), findsNothing);
    expect(find.textContaining('StateError'), findsNothing);
  });

  testWidgets('ignores a late failure from the replaced controller', (
    tester,
  ) async {
    final oldPort = _FakeJwProbePort(available: true)..holdRun = true;
    final newPort = _FakeJwProbePort(available: true);
    addTearDown(oldPort.dispose);
    addTearDown(newPort.dispose);
    await tester.pumpWidget(_host(oldPort));
    await tester.enterText(_accountField, 'AB12345');
    await tester.tap(find.text('验证只读契约'));
    await tester.pump();
    expect(oldPort.runCalls, 1);

    await tester.pumpWidget(_host(newPort));
    oldPort.failHeldRun(StateError('secret=old-controller-value'));
    await tester.pump();

    expect(find.text('尚未运行只读契约验证。'), findsOneWidget);
    expect(find.text('验证请求失败，请检查观测页面后重试。'), findsNothing);
    expect(find.textContaining('old-controller-value'), findsNothing);
    expect(newPort.runCalls, 0);
  });

  testWidgets('copies only the fixed safe summary after a result', (
    tester,
  ) async {
    String? copiedText;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copiedText =
            (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final port = _FakeJwProbePort(
      view: _doneView(
        summary: _summary(
          courseDiagnostics: _courseDiagnostics(
            reason: 'none',
            source: 'serverJson',
            serverOptions: 0,
            liveOptions: 2,
            literalAssignments: 1,
            literalItems: 2,
            literalParsed: true,
          ),
        ),
        semesters: const [
          JwSemesterOption(
            id: 42424242,
            name: 'SENSITIVE_SEMESTER_VALUE',
            selected: true,
          ),
        ],
      ),
    );
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));
    await tester.ensureVisible(find.text('复制脱敏摘要'));
    await tester.tap(find.text('复制脱敏摘要'));
    await tester.pumpAndSettle();

    expect(find.text('已复制脱敏摘要'), findsOneWidget);
    expect(copiedText, port.probeView.safeSummary);
    expect(copiedText, isNot(contains('2026-2027')));
    expect(copiedText, isNot(contains('AB12345')));
    expect(copiedText, isNot(contains('42424242')));
    expect(copiedText, isNot(contains('SENSITIVE_SEMESTER_VALUE')));
    final root = jsonDecode(copiedText!) as Map<String, dynamic>;
    final structure = root['structure'] as Map<String, dynamic>;
    final diagnostics = structure['courseDiagnostics'] as Map<String, dynamic>;
    expect(diagnostics.keys.toSet(), {
      'reason',
      'source',
      'serverOptions',
      'liveOptions',
      'literalAssignments',
      'literalItems',
      'literalParsed',
    });
  });

  testWidgets('keeps separate result rows within a narrow viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final port = _FakeJwProbePort(
      view: _doneView(
        phase: JwProbePhase.failed,
        code: JwProbeCode.courseSchema,
        stage: 'course',
        summary: _summary(
          examRows: 0,
          courseDiagnostics: _courseDiagnostics(
            reason: 'catalog_duplicate',
            serverOptions: 0,
            liveOptions: 2,
          ),
          stageResults: const {
            'identity': JwProbeCode.ok,
            'course': JwProbeCode.courseSchema,
            'exams': JwProbeCode.ok,
          },
        ),
      ),
    );
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));

    expect(tester.takeException(), isNull);
    expect(find.text('考试表格检查：通过'), findsOneWidget);
  });
}

Finder get _accountField =>
    find.byKey(const ValueKey('jw-probe-expected-account'));

Widget _host(JwProbePort port) =>
    MaterialApp(home: JwProbePanel(controller: port));

TextField _field(WidgetTester tester) => tester.widget(_accountField);

ButtonStyleButton _button(WidgetTester tester, String label) => tester.widget(
  find.ancestor(
    of: find.text(label),
    matching: find.bySubtype<ButtonStyleButton>(),
  ),
);

JwProbeSummary _summary({
  bool pagination = false,
  int semesterOptions = 1,
  int examTables = 2,
  int examRows = 7,
  bool semesterSelect = true,
  bool examHeader = true,
  JwCourseDiagnostics courseDiagnostics = const JwCourseDiagnostics(),
  Map<String, JwProbeCode> stageResults = const {
    'identity': JwProbeCode.pending,
    'course': JwProbeCode.pending,
    'exams': JwProbeCode.pending,
  },
}) => JwProbeSummary(
  identityLabels: 1,
  semesterOptions: semesterOptions,
  examTables: examTables,
  examRows: examRows,
  semesterSelect: semesterSelect,
  examHeader: examHeader,
  pagination: pagination,
  courseDiagnostics: courseDiagnostics,
  stageResults: stageResults,
  semesterVariables: const {
    'allSemesters': true,
    'semesters': false,
    'semesterId': true,
    'bizTypeId': false,
  },
);

JwCourseDiagnostics _courseDiagnostics({
  String reason = 'none',
  String source = 'none',
  int serverOptions = 0,
  int liveOptions = 0,
  int literalAssignments = 0,
  int literalItems = 0,
  bool literalParsed = false,
}) => JwCourseDiagnostics(
  reason: reason,
  source: source,
  serverOptions: serverOptions,
  liveOptions: liveOptions,
  literalAssignments: literalAssignments,
  literalItems: literalItems,
  literalParsed: literalParsed,
);

JwProbeView _doneView({
  JwProbePhase phase = JwProbePhase.done,
  JwProbeCode code = JwProbeCode.ok,
  JwCandidateIdentity identity = JwCandidateIdentity.unavailable,
  JwProbeSummary? summary,
  List<JwSemesterOption> semesters = const [],
  String? stage = 'exams',
}) => JwProbeView(
  phase: phase,
  code: code,
  identity: identity,
  summary: summary,
  semesters: semesters,
  stage: stage,
  available: true,
);

class _FakeJwProbePort implements JwProbePort {
  _FakeJwProbePort({JwProbeView? view, bool available = false})
    : _view = view ?? JwProbeView(available: available);

  final StreamController<JwProbeView> _changes =
      StreamController<JwProbeView>.broadcast(sync: true);
  JwProbeView _view;
  Completer<void>? _heldRun;
  Object? nextRunError;
  String? receivedAccountCode;
  int runCalls = 0;
  int cancelCalls = 0;
  bool holdRun = false;

  @override
  JwProbeView get probeView => _view;

  @override
  Stream<JwProbeView> get probeChanges => _changes.stream;

  @override
  Future<void> runProbe(String expectedAccountCode) {
    runCalls++;
    receivedAccountCode = expectedAccountCode;
    final error = nextRunError;
    nextRunError = null;
    if (error != null) return Future<void>.error(error);
    emit(
      JwProbeView(
        phase: JwProbePhase.running,
        code: JwProbeCode.pending,
        identity: JwCandidateIdentity.unavailable,
        available: true,
        busy: true,
      ),
    );
    if (holdRun) {
      holdRun = false;
      _heldRun = Completer<void>();
      return _heldRun!.future;
    }
    return Future<void>.value();
  }

  @override
  Future<void> cancelProbe() async {
    cancelCalls++;
    emit(
      const JwProbeView(
        phase: JwProbePhase.cancelled,
        code: JwProbeCode.cancelled,
        available: false,
        busy: false,
      ),
    );
  }

  void emit(JwProbeView view) {
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
