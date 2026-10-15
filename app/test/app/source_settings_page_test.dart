import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/app_shell_contract.dart';
import 'package:ustc_assistant_m0/app/source_settings_page.dart';
import 'package:ustc_assistant_m0/core/agenda_contract.dart';
import 'package:ustc_assistant_m0/core/young_work_contract.dart';
import 'package:ustc_assistant_m0/data/jw_import_contract.dart';
import 'package:ustc_assistant_m0/data/young_import_contract.dart';
import 'package:ustc_assistant_m0/jobs/jw_sync_port.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_port.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('projects both sources without diagnostics or local JW lists', (
    tester,
  ) async {
    final jw = _FakeJwPort(
      initial: _jwView(
        accountBound: true,
        data: _jwData(credentialSaved: true),
      ),
    );
    final young = _FakeYoungPort(
      initial: _youngView(
        kind: YoungJobKind.activities,
        committed: true,
        accountBound: true,
        data: _youngData(credentialSaved: true),
        activityResults: [
          YoungActivityView(
            title: 'Synthetic activity result',
            place: 'Synthetic place',
            startsAtUtc: DateTime.utc(2026, 10, 15, 1),
            endsAtUtc: DateTime.utc(2026, 10, 15, 2),
            registrationStartsAtUtc: null,
            registrationEndsAtUtc: null,
          ),
        ],
      ),
    );
    final shell = _FakeShell(jw, young);
    addTearDown(shell.dispose);

    await _pump(tester, shell);

    expect(find.text('来源设置'), findsOneWidget);
    expect(find.textContaining('教务和二课共用'), findsOneWidget);
    expect(find.text('教务课表与考试'), findsOneWidget);
    expect(find.byKey(const ValueKey('jw-sync-event-list')), findsNothing);
    expect(find.textContaining('M1 '), findsNothing);
    expect(find.textContaining('M2 '), findsNothing);
    expect(find.text('开发诊断'), findsNothing);
    expect(find.text('复制导入脱敏摘要'), findsNothing);
    expect(jw.startCalls, 0);
    expect(young.activityCalls, 0);
    expect(shell.agendaReads, 0);

    await tester.tap(find.byKey(const ValueKey('source-settings-young')));
    await tester.pumpAndSettle();
    expect(find.text('二课日程与活动'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('young-sync-start-calendar')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('young-sync-start-activities')),
      findsOneWidget,
    );
    expect(find.text('Synthetic activity result'), findsOneWidget);
    expect(find.text('本地二课日程'), findsNothing);
    expect(find.byKey(const ValueKey('young-sync-copy-summary')), findsNothing);
    expect(jw.startCalls, 0);
    expect(young.calendarCalls, 0);
    expect(young.activityCalls, 0);
    expect(shell.agendaReads, 0);
  });

  testWidgets(
    'other-source work blocks new actions but permits owner controls',
    (tester) async {
      final jw = _FakeJwPort(
        initial: _jwView(accountBound: true, data: _jwData()),
      );
      final young = _FakeYoungPort();
      final shell = _FakeShell(jw, young);
      addTearDown(shell.dispose);
      await _pump(tester, shell);

      await tester.enterText(
        find.byKey(const ValueKey('jw-sync-password')),
        'SYNTHETIC_PASSWORD',
      );
      young.emit(_youngView(phase: YoungSyncPhase.collecting));
      shell.globallyBusy = true;
      shell.refresh();
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('jw-sync-start')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('jw-sync-password')))
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('jw-sync-password')))
            .controller!
            .text,
        isEmpty,
      );

      young.emit(_youngView());
      jw.emit(
        _jwView(
          phase: JwSyncPhase.login,
          ready: true,
          accountBound: true,
          automation: JwAutomationState.manualRequired,
          data: _jwData(),
        ),
      );
      shell.refresh();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('jw-sync-continue')),
            )
            .onPressed,
        isNotNull,
      );
      await _tapVisible(tester, find.byKey(const ValueKey('jw-sync-continue')));
      expect(jw.continueCalls, 1);
      await _tapVisible(tester, find.text('取消本次同步'));
      expect(jw.cancelCalls, 1);
      expect(jw.startCalls, 0);
    },
  );

  testWidgets('continue, cancel, and recovery use the selected source port', (
    tester,
  ) async {
    final jw = _FakeJwPort(
      initial: _jwView(
        phase: JwSyncPhase.recovery,
        importCommitted: true,
        accountBound: true,
        data: _jwData(),
      ),
    );
    final young = _FakeYoungPort(
      initial: _youngView(
        phase: YoungSyncPhase.recovery,
        committed: true,
        accountBound: true,
        data: _youngData(),
      ),
    );
    final shell = _FakeShell(jw, young);
    addTearDown(shell.dispose);
    await _pump(tester, shell);

    expect(find.text('数据已保存，窗口关闭待恢复。'), findsOneWidget);
    await _tapVisible(tester, find.text('重试关闭窗口'));
    expect(jw.retryCalls, 1);

    await tester.tap(find.byKey(const ValueKey('source-settings-young')));
    await tester.pumpAndSettle();
    expect(find.text('数据已保存，窗口关闭待恢复。'), findsOneWidget);
    await _tapVisible(tester, find.text('重试关闭窗口'));
    expect(young.retryCalls, 1);

    young.emit(
      _youngView(
        phase: YoungSyncPhase.login,
        ready: true,
        accountBound: true,
        automation: YoungAutomationState.manualRequired,
        data: _youngData(),
      ),
    );
    shell.refresh();
    await tester.pumpAndSettle();
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('young-sync-continue-login')),
    );
    await _tapVisible(tester, find.text('取消本次操作'));
    expect(young.continueCalls, 1);
    expect(young.cancelCalls, 1);
    expect(jw.continueCalls, 0);
    expect(jw.cancelCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'source switch clears unsubmitted secrets and does not start work',
    (tester) async {
      final jw = _FakeJwPort(initial: _jwView());
      final young = _FakeYoungPort();
      final shell = _FakeShell(jw, young);
      addTearDown(shell.dispose);
      await _pump(tester, shell);

      await tester.enterText(
        find.byKey(const ValueKey('jw-sync-expected-account')),
        'SYNTHETIC_ACCOUNT',
      );
      await tester.enterText(
        find.byKey(const ValueKey('jw-sync-password')),
        'SYNTHETIC_PASSWORD',
      );
      await tester.tap(find.byKey(const ValueKey('source-settings-young')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-settings-jw')));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('jw-sync-expected-account')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('jw-sync-password')))
            .controller!
            .text,
        isEmpty,
      );
      expect(jw.startCalls, 0);
      expect(young.activityCalls, 0);
    },
  );

  testWidgets(
    'password deletion and session clearing require product confirmation',
    (tester) async {
      final jw = _FakeJwPort(
        initial: _jwView(
          accountBound: true,
          data: _jwData(credentialSaved: true),
        ),
      );
      final young = _FakeYoungPort(
        initial: _youngView(
          accountBound: true,
          data: _youngData(credentialSaved: true),
        ),
      );
      final shell = _FakeShell(jw, young);
      addTearDown(shell.dispose);
      await _pump(tester, shell);

      await _tapVisible(tester, find.text('删除保存的密码'));
      expect(find.text('删除保存的学校密码？'), findsOneWidget);
      expect(find.textContaining('删除后，两来源都不能再自动使用它'), findsOneWidget);
      expect(jw.deleteCredentialCalls, 0);
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(jw.deleteCredentialCalls, 0);

      await _tapVisible(tester, find.text('删除保存的密码'));
      await tester.tap(find.text('删除密码').last);
      await tester.pumpAndSettle();
      expect(jw.deleteCredentialCalls, 1);

      await _tapVisible(tester, find.text('清除浏览器登录资料'));
      expect(find.text('清除教务登录资料？'), findsOneWidget);
      expect(
        find.textContaining('课表与考试日程，以及教务和二课共用的加密学校密码会保留'),
        findsOneWidget,
      );
      expect(jw.clearSessionCalls, 0);
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(jw.clearSessionCalls, 0);

      await _tapVisible(
        tester,
        find.byKey(const ValueKey('source-settings-young')),
      );
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.text('清除二课登录资料'));
      expect(find.text('清除二课登录资料？'), findsOneWidget);
      expect(find.textContaining('教务登录资料和教务与二课共用的加密学校密码会保留'), findsOneWidget);
      expect(young.clearSessionCalls, 0);
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(young.clearSessionCalls, 0);

      await _tapVisible(tester, find.text('删除保存的学校密码'));
      expect(find.text('删除保存的学校密码？'), findsOneWidget);
      expect(find.textContaining('教务和二课账号绑定、已保存日程及浏览器登录资料会保留'), findsOneWidget);
      expect(young.deleteCredentialCalls, 0);
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(young.deleteCredentialCalls, 0);
    },
  );

  testWidgets('controller replacement ignores completion from the old port', (
    tester,
  ) async {
    final oldGate = Completer<void>();
    final oldJw = _FakeJwPort(
      initial: _jwView(accountBound: true, data: _jwData()),
    )..nextGate = oldGate;
    final oldShell = _FakeShell(oldJw, _FakeYoungPort());
    final newJw = _FakeJwPort(
      initial: _jwView(
        accountBound: true,
        importCommitted: true,
        data: _jwData(),
      ),
    );
    final newYoung = _FakeYoungPort();
    final newShell = _FakeShell(newJw, newYoung);
    addTearDown(oldShell.dispose);
    addTearDown(newShell.dispose);
    await _pump(tester, oldShell);

    await _tapVisible(tester, find.byKey(const ValueKey('jw-sync-start')));
    expect(oldJw.startCalls, 1);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SourceSettingsPage(controller: newShell)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('课表与考试日程已保存。'), findsOneWidget);

    oldGate.complete();
    oldJw.emit(_jwView(phase: JwSyncPhase.closed));
    await tester.pumpAndSettle();
    expect(find.text('课表与考试日程已保存。'), findsOneWidget);
    expect(newJw.startCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('optional diagnostics are built only after expansion', (
    tester,
  ) async {
    var builds = 0;
    final shell = _FakeShell(_FakeJwPort(), _FakeYoungPort());
    addTearDown(shell.dispose);
    tester.view.physicalSize = const Size(320, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SourceSettingsPage(
            controller: shell,
            diagnosticsBuilder: (_) {
              builds++;
              return const SizedBox(
                height: 640,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Text('synthetic diagnostics'),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(builds, 0);
    await _tapVisible(tester, find.text('开发诊断'));
    expect(builds, 1);
    expect(find.text('synthetic diagnostics'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('source settings fit narrow, short, scaled, and wide windows', (
    tester,
  ) async {
    final scenarios = <({Size size, double textScale})>[
      (size: const Size(320, 600), textScale: 1),
      (size: const Size(320, 420), textScale: 1),
      (size: const Size(320, 420), textScale: 1.5),
      (size: const Size(1280, 720), textScale: 1),
    ];
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final scenario in scenarios) {
      tester.view.physicalSize = scenario.size;
      final shell = _FakeShell(
        _FakeJwPort(initial: _jwView(accountBound: true, data: _jwData())),
        _FakeYoungPort(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scenario.textScale)),
              child: Scaffold(body: SourceSettingsPage(controller: shell)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final jwSelector = find.byKey(const ValueKey('source-settings-jw'));
      await tester.ensureVisible(jwSelector);
      expect(jwSelector.hitTestable(), findsOneWidget);
      final youngSelector = find.byKey(const ValueKey('source-settings-young'));
      await tester.ensureVisible(youngSelector);
      await tester.tap(youngSelector);
      await tester.pumpAndSettle();

      final account = find.byKey(const ValueKey('young-sync-expected-account'));
      await tester.ensureVisible(account);
      await tester.enterText(account, 'SYNTHETIC_ACCOUNT_92814');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      final activitiesAction = find.byKey(
        const ValueKey('young-sync-start-activities'),
      );
      await tester.ensureVisible(activitiesAction);
      expect(activitiesAction.hitTestable(), findsOneWidget);
      await tester.tap(activitiesAction);
      await tester.pumpAndSettle();
      expect(shell.young.activityCalls, 1);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      shell.dispose();
    }
  });
}

Future<void> _pump(WidgetTester tester, _FakeShell shell) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SourceSettingsPage(controller: shell)),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  expect(finder.hitTestable(), findsOneWidget);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

JwSyncView _jwView({
  JwSyncPhase phase = JwSyncPhase.idle,
  bool ready = false,
  bool accountBound = false,
  JwAutomationState automation = JwAutomationState.none,
  bool importCommitted = false,
  JwDataView? data,
}) => JwSyncView(
  phase: phase,
  ready: ready,
  accountBound: accountBound,
  automation: automation,
  importCommitted: importCommitted,
  data: data,
);

JwDataView _jwData({bool credentialSaved = false}) => JwDataView(
  accountBound: true,
  courseCount: 0,
  examCount: 0,
  importCount: 0,
  auditCount: 0,
  events: const [],
  credentialSaved: credentialSaved,
);

YoungSyncView _youngView({
  YoungSyncPhase phase = YoungSyncPhase.idle,
  bool ready = false,
  bool accountBound = false,
  YoungAutomationState automation = YoungAutomationState.none,
  YoungJobKind? kind,
  bool committed = false,
  YoungDataView? data,
  List<YoungActivityView> activityResults = const [],
}) => YoungSyncView(
  phase: phase,
  ready: ready,
  accountBound: accountBound,
  automation: automation,
  kind: kind,
  committed: committed,
  data: data,
  activityResults: activityResults,
);

YoungDataView _youngData({bool credentialSaved = false}) => YoungDataView(
  accountBound: true,
  importCount: 0,
  queryCount: 0,
  auditCount: 0,
  events: const [],
  credentialSaved: credentialSaved,
);

final class _FakeShell extends ChangeNotifier implements AppShellPort {
  _FakeShell(this.jw, this.young) {
    jw.onChanged = notifyListeners;
    young.onChanged = notifyListeners;
  }

  @override
  final _FakeJwPort jw;
  @override
  final _FakeYoungPort young;
  bool globallyBusy = false;
  bool actionPending = false;
  bool progressUnavailable = false;
  int agendaReads = 0;

  @override
  AppShellView get view => AppShellView(
    jw: jw.syncView,
    young: young.syncView,
    globallyBusy: globallyBusy,
    actionPending: actionPending,
    progressUnavailable: progressUnavailable,
  );

  @override
  DateTime get today => DateTime.utc(2026, 10, 12);

  void refresh() => notifyListeners();

  @override
  void dispose() {
    unawaited(jw.dispose());
    unawaited(young.dispose());
    super.dispose();
  }

  @override
  AgendaSlice readAgenda({
    required DateTime day,
    AgendaFilter filter = AgendaFilter.all,
    bool includeHidden = false,
  }) {
    agendaReads++;
    return AgendaSlice(
      day: day,
      filter: filter,
      includeHidden: includeHidden,
      items: const [],
      matched: 0,
      totalStored: 0,
      ready: true,
      truncated: false,
    );
  }

  @override
  Future<void> setHidden(
    AgendaReference reference, {
    required bool hidden,
  }) async {}
}

final class _FakeJwPort implements JwSyncPort {
  _FakeJwPort({JwSyncView? initial}) : _view = initial ?? JwSyncView();

  final StreamController<JwSyncView> _changes =
      StreamController<JwSyncView>.broadcast(sync: true);
  JwSyncView _view;
  VoidCallback? onChanged;
  Completer<void>? nextGate;
  int startCalls = 0;
  int continueCalls = 0;
  int cancelCalls = 0;
  int retryCalls = 0;
  int clearSessionCalls = 0;
  int deleteCredentialCalls = 0;

  @override
  JwSyncView get syncView => _view;
  @override
  Stream<JwSyncView> get syncChanges => _changes.stream;

  void emit(JwSyncView view) {
    _view = view;
    _changes.add(view);
    onChanged?.call();
  }

  Future<void> _wait() async {
    final gate = nextGate;
    nextGate = null;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> startSync({
    String? expectedAccountCode,
    String? password,
    bool savePassword = false,
    int? semesterId,
  }) async {
    startCalls++;
    await _wait();
  }

  @override
  Future<void> continueSync() async {
    continueCalls++;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }

  @override
  Future<void> retryRecovery() async {
    retryCalls++;
  }

  @override
  Future<void> clearSession() async {
    clearSessionCalls++;
  }

  @override
  Future<void> deleteSavedCredential() async {
    deleteCredentialCalls++;
  }

  Future<void> dispose() => _changes.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeYoungPort implements YoungSyncPort {
  _FakeYoungPort({YoungSyncView? initial}) : _view = initial ?? YoungSyncView();

  final StreamController<YoungSyncView> _changes =
      StreamController<YoungSyncView>.broadcast(sync: true);
  YoungSyncView _view;
  VoidCallback? onChanged;
  int calendarCalls = 0;
  int activityCalls = 0;
  int continueCalls = 0;
  int cancelCalls = 0;
  int retryCalls = 0;
  int clearSessionCalls = 0;
  int deleteCredentialCalls = 0;

  @override
  YoungSyncView get syncView => _view;
  @override
  Stream<YoungSyncView> get syncChanges => _changes.stream;

  void emit(YoungSyncView view) {
    _view = view;
    _changes.add(view);
    onChanged?.call();
  }

  @override
  Future<void> startCalendar({
    String? expectedAccountCode,
    required DateTime firstDay,
    required DateTime lastDay,
    String? password,
    bool savePassword = false,
  }) async {
    calendarCalls++;
  }

  @override
  Future<void> startActivities({
    String? expectedAccountCode,
    String? password,
    bool savePassword = false,
  }) async {
    activityCalls++;
  }

  @override
  Future<void> continueAfterLogin() async {
    continueCalls++;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }

  @override
  Future<void> retryRecovery() async {
    retryCalls++;
  }

  @override
  Future<void> clearSession() async {
    clearSessionCalls++;
  }

  @override
  Future<void> deleteSavedCredential() async {
    deleteCredentialCalls++;
  }

  Future<void> dispose() => _changes.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
