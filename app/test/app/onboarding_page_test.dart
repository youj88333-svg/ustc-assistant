import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_contract.dart';
import 'package:ustc_assistant_m0/app/app_shell_contract.dart';
import 'package:ustc_assistant_m0/app/onboarding_controller.dart';
import 'package:ustc_assistant_m0/app/onboarding_page.dart';
import 'package:ustc_assistant_m0/app/product_app.dart';
import 'package:ustc_assistant_m0/app/settings_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/onboarding_contract.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/jobs/jw_sync_port.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_port.dart';

void main() {
  testWidgets('model operation has a reachable stop while navigation waits', (
    tester,
  ) async {
    final fixture = _Fixture();
    addTearDown(fixture.close);
    await tester.pumpWidget(fixture.widget());
    await tester.pumpAndSettle();
    await fixture.progress.navigate(OnboardingStep.model);
    await tester.pumpAndSettle();
    fixture.agent.phase = AgentPhase.loadingModels;
    fixture.agent.notifyListeners();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('setup-next')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('setup-stop-model')));
    await tester.pumpAndSettle();
    expect(fixture.agent.stops, 1);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('setup-next')))
          .onPressed,
      isNotNull,
    );
  });
  testWidgets(
    'existing bound account is not silently replaced by a new candidate',
    (tester) async {
      final fixture = _Fixture();
      fixture.jw.bound = true;
      addTearDown(fixture.close);
      await tester.pumpWidget(fixture.widget());
      await tester.pumpAndSettle();
      final field = tester.widget<TextFormField>(
        find.byKey(const ValueKey('setup-account')),
      );
      expect(field.enabled, isFalse);
      expect(field.controller!.text, isEmpty);
      await tester.tap(find.byKey(const ValueKey('setup-next')));
      await tester.pumpAndSettle();
      expect(fixture.progress.snapshot!.step, OnboardingStep.sync);
      expect(fixture.jw.calls, 0);
    },
  );
  testWidgets(
    'all steps can skip without school, model, or permission writes',
    (tester) async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      await tester.pumpWidget(fixture.widget());
      await tester.pumpAndSettle();
      expect(find.text('先连上你的学校账号'), findsOneWidget);
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.byKey(const ValueKey('setup-skip')));
        await tester.pumpAndSettle();
      }
      expect(fixture.progress.snapshot!.status, OnboardingStatus.done);
      expect(fixture.jw.calls, 0);
      expect(fixture.young.calls, 0);
      expect(fixture.agent.externalCalls, 0);
      expect(fixture.settings.writes, 0);
      expect(fixture.reminders.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'account validates on Next, password stays masked and source busy holds navigation',
    (tester) async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      await tester.pumpWidget(fixture.widget());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('setup-next')));
      await tester.pumpAndSettle();
      expect(find.text('请输入学号或工号，也可以跳过这步。'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('setup-account')),
        'TEST001',
      );
      await tester.enterText(
        find.byKey(const ValueKey('setup-password')),
        'synthetic-only',
      );
      final password = tester.widget<TextField>(
        find.byKey(const ValueKey('setup-password')),
      );
      expect(password.obscureText, isTrue);
      await tester.tap(find.byKey(const ValueKey('setup-next')));
      await tester.pumpAndSettle();
      fixture.shell.busy = true;
      fixture.shell.notifyListeners();
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('setup-next')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('setup-defer')))
            .onPressed,
        isNull,
      );
      fixture.shell.busy = false;
      fixture.shell.notifyListeners();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('setup-next')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('setup-back')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('setup-back')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('setup-password')))
            .controller!
            .text,
        isEmpty,
      );
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('setup-account')))
            .controller!
            .text,
        isEmpty,
      );
    },
  );

  testWidgets(
    'deferred progress resumes, finished guide restarts from account, stale controller stops',
    (tester) async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      await tester.pumpWidget(fixture.widget());
      await tester.pumpAndSettle();
      await fixture.progress.navigate(OnboardingStep.model);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('setup-defer')));
      await tester.pumpAndSettle();
      expect(fixture.progress.snapshot!.status, OnboardingStatus.deferred);
      await fixture.progress.reopen();
      await tester.pumpAndSettle();
      expect(fixture.progress.snapshot!.step, OnboardingStep.model);
      await fixture.progress.complete();
      await fixture.progress.reopen();
      await tester.pumpAndSettle();
      expect(fixture.progress.snapshot!.step, OnboardingStep.account);
      final lateData = _Progress();
      lateData.readGate = Completer<OnboardingSnapshot>();
      final obsolete = OnboardingController(lateData);
      await tester.pump();
      obsolete.dispose();
      lateData.readGate!.complete(lateData.current);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await lateData.close();
    },
  );

  testWidgets(
    'failed progress write is recoverable without claiming completion',
    (tester) async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      await tester.pumpWidget(fixture.widget());
      await tester.pumpAndSettle();
      fixture.data.failSave = true;
      await tester.tap(find.byKey(const ValueKey('setup-defer')));
      await tester.pumpAndSettle();
      expect(fixture.progress.failure, isTrue);
      expect(fixture.data.current.status, OnboardingStatus.active);
      fixture.data.failSave = false;
      await tester.tap(find.text('重试读取进度'));
      await tester.pumpAndSettle();
      expect(find.text('先连上你的学校账号'), findsOneWidget);
    },
  );

  for (final width in [320.0, 360.0, 412.0, 1100.0]) {
    testWidgets('four forms fit width $width with large text and keyboard', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final fixture = _Fixture();
      addTearDown(fixture.close);
      await tester.pumpWidget(fixture.widget());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('setup-password')));
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      tester.view.viewInsets = const FakeViewPadding();
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.byKey(const ValueKey('setup-skip')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  }
}

class _Fixture {
  _Fixture() {
    shell = _Shell(jw, young);
    progress = OnboardingController(data);
  }
  final data = _Progress();
  late final OnboardingController progress;
  final jw = _Jw();
  final young = _Young();
  late final _Shell shell;
  final settings = _Settings();
  final agent = _Agent();
  final reminders = _Reminders();
  Widget widget() => MaterialApp(
    theme: productTheme,
    home: OnboardingPage(
      progress: progress,
      shell: shell,
      settings: settings,
      agent: agent,
      reminders: reminders,
      reminderChanges: const Stream.empty(),
      initialReminderView: const ReminderRuntimeView(),
    ),
  );
  Future<void> close() async {
    progress.dispose();
    shell.dispose();
    settings.dispose();
    agent.dispose();
    await data.close();
  }
}

class _Progress implements OnboardingDataPort {
  OnboardingSnapshot current = const OnboardingSnapshot(
    context: OnboardingContext(
      owner: 'synthetic-owner',
      resetEpoch: 0,
      revision: 1,
    ),
    status: OnboardingStatus.active,
    step: OnboardingStep.account,
  );
  final events = StreamController<int>.broadcast();
  bool failSave = false;
  Completer<OnboardingSnapshot>? readGate;
  @override
  Stream<int> get changes => events.stream;
  @override
  Future<OnboardingSnapshot> inspect() async =>
      readGate == null ? current : readGate!.future;
  @override
  Future<OnboardingSnapshot> save(
    OnboardingContext expected, {
    required OnboardingStatus status,
    required OnboardingStep step,
  }) async {
    if (failSave || current.context != expected) {
      throw StateError('synthetic progress failure');
    }
    current = OnboardingSnapshot(
      context: OnboardingContext(
        owner: expected.owner,
        resetEpoch: expected.resetEpoch,
        revision: expected.revision + 1,
      ),
      status: status,
      step: step,
    );
    events.add(current.context.revision);
    return current;
  }

  Future<void> close() => events.close();
}

class _Shell extends ChangeNotifier implements AppShellPort {
  _Shell(this.jw, this.young);
  bool busy = false;
  @override
  final JwSyncPort jw;
  @override
  final YoungSyncPort young;
  @override
  DateTime get today => DateTime.utc(2026, 10, 25);
  @override
  AppShellView get view =>
      AppShellView(jw: jw.syncView, young: young.syncView, globallyBusy: busy);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Jw extends Fake implements JwSyncPort {
  int calls = 0;
  bool bound = false;
  @override
  JwSyncView get syncView => JwSyncView(accountBound: bound);
  @override
  Stream<JwSyncView> get syncChanges => const Stream.empty();
  @override
  Future<void> startSync({
    String? expectedAccountCode,
    String? password,
    bool savePassword = false,
    int? semesterId,
  }) async {
    calls++;
  }
}

class _Young extends Fake implements YoungSyncPort {
  int calls = 0;
  @override
  YoungSyncView get syncView => YoungSyncView();
  @override
  Stream<YoungSyncView> get syncChanges => const Stream.empty();
  @override
  Future<void> startCalendar({
    String? expectedAccountCode,
    required DateTime firstDay,
    required DateTime lastDay,
    String? password,
    bool savePassword = false,
  }) async {
    calls++;
  }
}

class _Settings extends ChangeNotifier implements ApplicationSettingsPort {
  int writes = 0;
  @override
  ApplicationSettingsView get settingsView => const ApplicationSettingsView(
    snapshot: SettingsSnapshot(
      context: SettingsContext(
        owner: 'synthetic-owner',
        resetEpoch: 0,
        agendaEpoch: 0,
        revision: 1,
      ),
      preferences: DisplayPreferences(),
      counts: LocalDataCounts(),
      accountBound: false,
      credentialSaved: false,
      icourseConsent: false,
    ),
  );
  @override
  Future<void> refreshSettings() async {}
  @override
  Future<void> setIcourseConsent(
    SettingsContext context, {
    required bool allowed,
    required bool confirmed,
  }) async {
    writes++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Agent extends ChangeNotifier implements AgentWorkspacePort {
  int externalCalls = 0;
  int stops = 0;
  AgentPhase phase = AgentPhase.idle;
  @override
  AgentWorkspaceView get view => AgentRuntimeView(
    phase: phase,
    settings: AgentSettingsSnapshot(
      authority: const AgentAuthority(
        owner: 'synthetic-owner',
        resetEpoch: 0,
        historyEpoch: 0,
        configRevision: 1,
      ),
    ),
  );
  @override
  Future<void> refresh() async {}
  @override
  Future<void> stop() async {
    stops++;
    phase = AgentPhase.idle;
    notifyListeners();
  }

  @override
  Future<void> loadModels({String key = '', required bool consent}) async {
    externalCalls++;
  }

  @override
  Future<void> verifyAndSave({
    String key = '',
    required String modelId,
    required bool consent,
  }) async {
    externalCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Reminders extends Fake implements ReminderDataPort {
  int writes = 0;
  @override
  Stream<int> get changes => const Stream.empty();
  @override
  Future<ReminderSettings> inspectReminders() async => const ReminderSettings(
    context: CalendarContext(
      owner: 'synthetic-owner',
      resetEpoch: 0,
      agendaEpoch: 0,
    ),
    revision: 1,
    briefEpoch: 1,
    preferences: ReminderPreferences(),
  );
  @override
  Future<void> saveReminderPreferences(
    ReminderSettings expected,
    ReminderPreferences preferences,
  ) async {
    writes++;
  }
}
