import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/app_shell_contract.dart';
import 'package:ustc_assistant_m0/app/onboarding_source_step.dart';
import 'package:ustc_assistant_m0/core/agenda_contract.dart';
import 'package:ustc_assistant_m0/core/young_work_contract.dart';
import 'package:ustc_assistant_m0/data/jw_import_contract.dart';
import 'package:ustc_assistant_m0/data/young_import_contract.dart';
import 'package:ustc_assistant_m0/jobs/jw_sync_port.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_port.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';
import 'package:ustc_assistant_m0/source/jw_probe_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'entering starts no source work; explicit tap passes the ephemeral draft',
    (tester) async {
      final jw = _Jw();
      final young = _Young();
      final shell = _Shell(jw, young);
      addTearDown(shell.close);
      var accountReads = 0;
      var passwordReads = 0;
      var savePasswordReads = 0;
      await tester.pumpWidget(
        _host(
          shell,
          account: () {
            accountReads++;
            return 'SYNTHETIC001';
          },
          password: () {
            passwordReads++;
            return 'SYNTHETIC_SECRET';
          },
          savePassword: () {
            savePasswordReads++;
            return true;
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(jw.startCalls, 0);
      expect(young.calendarCalls, 0);
      expect(accountReads, 0);
      expect(passwordReads, 0);
      expect(savePasswordReads, 0);
      expect(find.text('开始：2026-10-01'), findsOneWidget);
      expect(find.text('结束：2026-10-31'), findsOneWidget);

      await _tapVisible(
        tester,
        find.byKey(const ValueKey('onboarding-jw-start')),
      );
      await tester.pumpAndSettle();

      expect(jw.startCalls, 1);
      expect(jw.lastExpectedAccountCode, 'SYNTHETIC001');
      expect(jw.lastPassword, 'SYNTHETIC_SECRET');
      expect(jw.lastSavePassword, isTrue);
      expect(jw.lastSemesterId, isNull);
      expect(accountReads, 1);
      expect(passwordReads, 1);
      expect(savePasswordReads, 1);
      expect(find.textContaining('SYNTHETIC_SECRET'), findsNothing);
    },
  );

  testWidgets(
    'missing unbound candidate returns to account step without starting C2',
    (tester) async {
      final jw = _Jw();
      final young = _Young();
      final shell = _Shell(jw, young);
      addTearDown(shell.close);
      var passwordReads = 0;
      await tester.pumpWidget(
        _host(
          shell,
          account: () => null,
          password: () {
            passwordReads++;
            return 'SHOULD_NOT_BE_READ';
          },
        ),
      );
      await tester.pumpAndSettle();

      await _tapVisible(
        tester,
        find.byKey(const ValueKey('onboarding-jw-start')),
      );
      await tester.pumpAndSettle();

      expect(jw.startCalls, 0);
      expect(passwordReads, 0);
      expect(find.text('请先返回上一步填写学号；也可跳过同步。'), findsOneWidget);
    },
  );

  testWidgets(
    'cached JW last semester is optional and passed only after tapping',
    (tester) async {
      final jw = _Jw(
        initial: JwSyncView(
          accountBound: true,
          data: _jwData(
            accountBound: true,
            lastSemesterId: 12,
            cachedSemesters: const [
              JwSemesterOption(id: 11, name: '2025 Autumn', selected: false),
              JwSemesterOption(id: 12, name: '2026 Spring', selected: true),
            ],
          ),
        ),
      );
      final young = _Young();
      final shell = _Shell(jw, young);
      addTearDown(shell.close);
      await tester.pumpWidget(_host(shell));
      await tester.pumpAndSettle();

      expect(jw.startCalls, 0);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('onboarding-jw-start')),
      );
      await tester.pumpAndSettle();
      expect(jw.startCalls, 1);
      expect(jw.lastExpectedAccountCode, isNull);
      expect(jw.lastSemesterId, 12);
    },
  );

  testWidgets(
    'latest choosing-semester directory requires explicit selection and collect',
    (tester) async {
      final jw = _Jw(
        initial: JwSyncView(
          phase: JwSyncPhase.login,
          ready: true,
          accountBound: true,
          automation: JwAutomationState.choosingSemester,
          semesters: const [
            JwSemesterOption(
              id: 42,
              name: 'Fresh latest semester',
              selected: true,
            ),
          ],
        ),
      );
      final shell = _Shell(jw, _Young());
      addTearDown(shell.close);
      await tester.pumpWidget(_host(shell));
      await tester.pumpAndSettle();

      expect(jw.collectCalls, 0);
      final selector = find.byKey(const ValueKey('onboarding-jw-latest-42'));
      await _tapVisible(tester, selector);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fresh latest semester').last);
      await tester.pumpAndSettle();
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('onboarding-jw-collect')),
      );
      await tester.pumpAndSettle();

      expect(jw.collectCalls, 1);
      expect(jw.lastCollectedSemesterId, 42);
      expect(jw.startCalls, 0);
    },
  );

  testWidgets(
    'manual continuation and cancellation stay with the active source; recovery retries',
    (tester) async {
      final young = _Young(
        initial: YoungSyncView(
          phase: YoungSyncPhase.login,
          kind: YoungJobKind.calendar,
          ready: true,
          accountBound: true,
          automation: YoungAutomationState.manualRequired,
        ),
      );
      final shell = _Shell(_Jw(), young);
      addTearDown(shell.close);
      await tester.pumpWidget(_host(shell));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('onboarding-young-status')))
            .data,
        contains('验证码或额外授权'),
      );
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('onboarding-young-continue')),
      );
      await tester.pumpAndSettle();
      expect(young.continueCalls, 1);

      await _tapVisible(
        tester,
        find.byKey(const ValueKey('onboarding-young-cancel')),
      );
      await tester.pumpAndSettle();
      expect(young.cancelCalls, 1);

      young.emit(
        YoungSyncView(
          phase: YoungSyncPhase.recovery,
          kind: YoungJobKind.calendar,
          accountBound: true,
        ),
      );
      await tester.pumpAndSettle();
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('onboarding-young-recovery')),
      );
      await tester.pumpAndSettle();
      expect(young.retryCalls, 1);
    },
  );

  testWidgets(
    'active source keeps wizard navigation busy after start future pauses early',
    (tester) async {
      final jw = _Jw();
      jw.startGate = Completer<void>();
      jw.onStart = () => jw.emit(
        JwSyncView(
          phase: JwSyncPhase.login,
          ready: true,
          accountBound: true,
          automation: JwAutomationState.manualRequired,
        ),
      );
      final shell = _Shell(jw, _Young());
      addTearDown(shell.close);
      final busyChanges = <bool>[];
      await tester.pumpWidget(_host(shell, onBusyChanged: busyChanges.add));
      await tester.pumpAndSettle();
      expect(busyChanges.last, isFalse);

      await _tapVisible(
        tester,
        find.byKey(const ValueKey('onboarding-jw-start')),
      );
      await tester.pumpAndSettle();
      expect(busyChanges.last, isTrue);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('onboarding-young-start')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('onboarding-jw-continue')),
            )
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);

      jw.startGate!.complete();
      await tester.pumpAndSettle();
      expect(busyChanges.last, isTrue);
    },
  );

  testWidgets(
    'parent rebuild from busy callback preserves a pending start command',
    (tester) async {
      final jw = _Jw()..startGate = Completer<void>();
      final shell = _Shell(jw, _Young());
      addTearDown(shell.close);
      var parentBusy = false;
      final busyChanges = <bool>[];
      late StateSetter parentSetState;
      void onBusyChanged(bool value) {
        busyChanges.add(value);
        parentSetState(() => parentBusy = value);
      }

      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              parentSetState = setState;
              return Scaffold(
                body: SingleChildScrollView(
                  child: OnboardingSourceStep(
                    controller: shell,
                    account: () => 'SYNTHETIC001',
                    password: () => null,
                    savePassword: () => false,
                    today: () => shell.today,
                    onBusyChanged: onBusyChanged,
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(parentBusy, isFalse);

      await _tapVisible(
        tester,
        find.byKey(const ValueKey('onboarding-jw-start')),
      );
      await tester.pumpAndSettle();
      expect(parentBusy, isTrue);
      expect(busyChanges.last, isTrue);
      expect(find.text('正在启动教务同步'), findsOneWidget);

      jw.startGate!.complete();
      await tester.pumpAndSettle();
      expect(parentBusy, isFalse);
      expect(busyChanges.last, isFalse);
    },
  );

  testWidgets('committed zero-row results are shown as saved, not as missing', (
    tester,
  ) async {
    final jw = _Jw(
      initial: JwSyncView(
        importCommitted: true,
        courseCount: 0,
        examCount: 0,
        data: _jwData(accountBound: true),
      ),
    );
    final young = _Young(
      initial: YoungSyncView(
        kind: YoungJobKind.calendar,
        committed: true,
        data: _youngData(accountBound: true),
      ),
    );
    final shell = _Shell(jw, young);
    addTearDown(shell.close);
    await tester.pumpWidget(_host(shell));
    await tester.pumpAndSettle();

    expect(find.text('已提交的教务结果：课程 0 条、考试 0 条。'), findsOneWidget);
    expect(find.text('二课日程结果已提交。'), findsOneWidget);
  });

  testWidgets(
    'date pickers enforce the inclusive 62-day range and keep user dates on refresh',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(420, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final young = _Young(
        initial: YoungSyncView(
          accountBound: true,
          data: _youngData(
            accountBound: true,
            firstDay: DateTime.utc(2026, 10, 1),
            lastDay: DateTime.utc(2026, 10, 31),
          ),
        ),
      );
      final shell = _Shell(_Jw(), young);
      addTearDown(shell.close);
      await tester.pumpWidget(_host(shell));
      await tester.pumpAndSettle();

      await _pickDate(
        tester,
        'onboarding-young-first-day',
        1,
        previousMonths: 1,
      );
      await _pickDate(tester, 'onboarding-young-last-day', 2, nextMonths: 1);
      await tester.pumpAndSettle();

      expect(find.text('开始：2026-09-01'), findsOneWidget);
      expect(find.text('结束：2026-11-02'), findsOneWidget);
      expect(find.text('一次最多同步62天，请缩短日期范围。'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('onboarding-young-start')),
            )
            .onPressed,
        isNull,
      );

      young.emit(
        YoungSyncView(
          accountBound: true,
          data: _youngData(
            accountBound: true,
            firstDay: DateTime.utc(2027, 1, 1),
            lastDay: DateTime.utc(2027, 1, 31),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('结束：2026-11-02'), findsOneWidget);
    },
  );

  testWidgets(
    '320dp window with large text remains scrollable and has no layout exception',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 720);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final shell = _Shell(_Jw(), _Young());
      addTearDown(shell.close);
      await tester.pumpWidget(
        _host(shell, textScaler: const TextScaler.linear(2)),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('onboarding-jw-start')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('onboarding-young-start')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pickDate(
  WidgetTester tester,
  String key,
  int day, {
  int previousMonths = 0,
  int nextMonths = 0,
}) async {
  await _tapVisible(tester, find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  for (var index = 0; index < previousMonths; index++) {
    await tester.tap(find.byTooltip('Previous month'));
    await tester.pumpAndSettle();
  }
  for (var index = 0; index < nextMonths; index++) {
    await tester.tap(find.byTooltip('Next month'));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text('$day').last);
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(TextButton, '确定'));
  await tester.pumpAndSettle();
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
}

Widget _host(
  _Shell shell, {
  String? Function()? account,
  String? Function()? password,
  bool Function()? savePassword,
  ValueChanged<bool>? onBusyChanged,
  TextScaler? textScaler,
}) => MaterialApp(
  builder: (context, child) => textScaler == null
      ? child!
      : MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
  home: Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: OnboardingSourceStep(
        controller: shell,
        account: account ?? () => 'SYNTHETIC001',
        password: password ?? () => null,
        savePassword: savePassword ?? () => false,
        today: () => shell.today,
        onBusyChanged: onBusyChanged,
      ),
    ),
  ),
);

JwDataView _jwData({
  bool accountBound = false,
  int? lastSemesterId,
  List<JwSemesterOption> cachedSemesters = const [],
}) => JwDataView(
  accountBound: accountBound,
  courseCount: 0,
  examCount: 0,
  importCount: 0,
  auditCount: 0,
  events: const [],
  lastSemesterId: lastSemesterId,
  cachedSemesters: cachedSemesters,
);

YoungDataView _youngData({
  bool accountBound = false,
  DateTime? firstDay,
  DateTime? lastDay,
}) => YoungDataView(
  accountBound: accountBound,
  importCount: 0,
  queryCount: 0,
  auditCount: 0,
  events: const [],
  firstDay: firstDay,
  lastDay: lastDay,
);

final class _Shell extends ChangeNotifier implements AppShellPort {
  _Shell(this.jw, this.young) {
    jw.onChanged = notifyListeners;
    young.onChanged = notifyListeners;
  }

  @override
  final _Jw jw;
  @override
  final _Young young;
  bool externalBusy = false;
  bool actionPending = false;
  bool progressUnavailable = false;

  @override
  AppShellView get view => AppShellView(
    jw: jw.syncView,
    young: young.syncView,
    globallyBusy: externalBusy || jw.syncView.busy || young.syncView.busy,
    actionPending: actionPending,
    progressUnavailable: progressUnavailable,
  );

  @override
  DateTime get today => DateTime.utc(2026, 10, 25);

  @override
  AgendaSlice readAgenda({
    required DateTime day,
    AgendaFilter filter = AgendaFilter.all,
    bool includeHidden = false,
  }) => throw UnimplementedError();

  @override
  Future<void> setHidden(
    AgendaReference reference, {
    required bool hidden,
  }) async {}

  Future<void> close() async {
    await jw.close();
    await young.close();
    dispose();
  }
}

final class _Jw implements JwSyncPort {
  _Jw({JwSyncView? initial}) : _view = initial ?? JwSyncView();

  final StreamController<JwSyncView> _changes =
      StreamController<JwSyncView>.broadcast(sync: true);
  JwSyncView _view;
  VoidCallback? onChanged;
  VoidCallback? onStart;
  Completer<void>? startGate;
  int startCalls = 0;
  int continueCalls = 0;
  int collectCalls = 0;
  int cancelCalls = 0;
  int retryCalls = 0;
  String? lastExpectedAccountCode;
  String? lastPassword;
  bool lastSavePassword = false;
  int? lastSemesterId;
  int? lastCollectedSemesterId;

  @override
  JwSyncView get syncView => _view;
  @override
  Stream<JwSyncView> get syncChanges => _changes.stream;

  void emit(JwSyncView value) {
    _view = value;
    _changes.add(value);
    onChanged?.call();
  }

  @override
  Future<void> startSync({
    String? expectedAccountCode,
    String? password,
    bool savePassword = false,
    int? semesterId,
  }) async {
    startCalls++;
    lastExpectedAccountCode = expectedAccountCode;
    lastPassword = password;
    lastSavePassword = savePassword;
    lastSemesterId = semesterId;
    onStart?.call();
    final gate = startGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> continueSync() async {
    continueCalls++;
  }

  @override
  Future<void> collect(int semesterId) async {
    collectCalls++;
    lastCollectedSemesterId = semesterId;
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
  Future<void> open({String? expectedAccountCode}) async {}
  @override
  Future<void> deleteSavedCredential() async {}
  @override
  Future<void> navigateJwPage(JwObservationPage page) async {}
  @override
  Future<void> verifyDirectory() async {}
  @override
  Future<void> clearSession() async {}
  @override
  Future<void> setHidden({
    required int localId,
    required int expectedVersion,
    required bool hidden,
  }) async {}

  Future<void> close() => _changes.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Young implements YoungSyncPort {
  _Young({YoungSyncView? initial}) : _view = initial ?? YoungSyncView();

  final StreamController<YoungSyncView> _changes =
      StreamController<YoungSyncView>.broadcast(sync: true);
  YoungSyncView _view;
  VoidCallback? onChanged;
  int calendarCalls = 0;
  int continueCalls = 0;
  int cancelCalls = 0;
  int retryCalls = 0;
  String? lastExpectedAccountCode;
  String? lastPassword;
  bool lastSavePassword = false;
  DateTime? firstDay;
  DateTime? lastDay;

  @override
  YoungSyncView get syncView => _view;
  @override
  Stream<YoungSyncView> get syncChanges => _changes.stream;

  void emit(YoungSyncView value) {
    _view = value;
    _changes.add(value);
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
    lastExpectedAccountCode = expectedAccountCode;
    this.firstDay = firstDay;
    this.lastDay = lastDay;
    lastPassword = password;
    lastSavePassword = savePassword;
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
  Future<void> startActivities({
    String? expectedAccountCode,
    String? password,
    bool savePassword = false,
  }) async {}
  @override
  Future<void> clearSession() async {}
  @override
  Future<void> deleteSavedCredential() async {}
  @override
  Future<void> setHidden({
    required int localId,
    required int expectedVersion,
    required bool hidden,
  }) async {}

  Future<void> close() => _changes.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
