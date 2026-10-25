import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_contract.dart';
import 'package:ustc_assistant_m0/app/onboarding_permissions_step.dart';
import 'package:ustc_assistant_m0/app/settings_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'initial load reads local state without writing or opening OS UI',
    (tester) async {
      final settings = _SettingsPort(icourseConsent: true);
      final agent = _AgentPort(personal: true, daily: true);
      final reminders = _ReminderPort(
        preferences: const ReminderPreferences(
          enabled: true,
          morningEnabled: true,
        ),
      );
      final busyChanges = <bool>[];
      var systemAccessCalls = 0;
      addTearDown(settings.dispose);
      addTearDown(agent.dispose);
      addTearDown(reminders.close);

      await tester.pumpWidget(
        _host(
          settings,
          agent,
          reminders,
          configureSystemAccess: (_) async {
            systemAccessCalls++;
          },
          onBusyChanged: busyChanges.add,
        ),
      );
      await tester.pumpAndSettle();

      expect(settings.refreshCalls, 1);
      expect(agent.refreshCalls, 1);
      expect(reminders.inspectCalls, greaterThanOrEqualTo(1));
      expect(settings.consentWrites, isEmpty);
      expect(agent.policyWrites, isEmpty);
      expect(reminders.preferenceWrites, isEmpty);
      expect(systemAccessCalls, 0);
      expect(busyChanges, [true, false]);
      expect(_switch(tester, 'onboarding-icourse-toggle').value, isTrue);
      expect(
        _switch(tester, 'onboarding-private-content-toggle').value,
        isTrue,
      );
      expect(
        _switch(tester, 'onboarding-daily-operations-toggle').value,
        isTrue,
      );
      expect(_switch(tester, 'onboarding-reminder-toggle').value, isTrue);
      expect(_switch(tester, 'onboarding-morning-toggle').value, isTrue);
      expect(find.textContaining('状态未知'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('initial loading callback can update its wizard parent', (
    tester,
  ) async {
    final settings = _SettingsPort();
    final agent = _AgentPort();
    final reminders = _ReminderPort();
    addTearDown(settings.dispose);
    addTearDown(agent.dispose);
    addTearDown(reminders.close);

    await tester.pumpWidget(_BusyWizardHost(settings, agent, reminders));
    await tester.pumpAndSettle();

    expect(find.text('向导空闲'), findsOneWidget);
    expect(settings.refreshCalls, 1);
    expect(agent.refreshCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'each opt-in writes only its field and preserves existing values',
    (tester) async {
      const timed = ReminderPair(
        ReminderRule.before(20),
        ReminderRule.before(5),
      );
      const allDay = ReminderPair(
        ReminderRule.dayTime(dayOffset: -1, minuteOfDay: 480),
        ReminderRule.dayTime(dayOffset: 0, minuteOfDay: 600),
      );
      final settings = _SettingsPort(icourseConsent: false);
      final agent = _AgentPort(personal: true, daily: false);
      final reminders = _ReminderPort(
        preferences: const ReminderPreferences(
          enabled: false,
          privateDisplay: true,
          morningEnabled: true,
          timed: timed,
          allDay: allDay,
        ),
      );
      addTearDown(settings.dispose);
      addTearDown(agent.dispose);
      addTearDown(reminders.close);

      await tester.pumpWidget(_host(settings, agent, reminders));
      await tester.pumpAndSettle();

      await _tap(tester, 'onboarding-reminder-toggle');
      expect(reminders.preferenceWrites, hasLength(1));
      expect(reminders.preferenceWrites.last.enabled, isTrue);
      expect(reminders.preferenceWrites.last.morningEnabled, isTrue);
      expect(reminders.preferenceWrites.last.privateDisplay, isTrue);
      expect(reminders.preferenceWrites.last.timed, timed);
      expect(reminders.preferenceWrites.last.allDay, allDay);

      await _tap(tester, 'onboarding-morning-toggle');
      expect(reminders.preferenceWrites, hasLength(2));
      expect(reminders.preferenceWrites.last.enabled, isTrue);
      expect(reminders.preferenceWrites.last.morningEnabled, isFalse);
      expect(reminders.preferenceWrites.last.privateDisplay, isTrue);
      expect(reminders.preferenceWrites.last.timed, timed);
      expect(reminders.preferenceWrites.last.allDay, allDay);

      await _tap(tester, 'onboarding-icourse-toggle');
      expect(settings.consentWrites, hasLength(1));
      expect(settings.consentWrites.single.allowed, isTrue);
      expect(settings.consentWrites.single.confirmed, isTrue);
      expect(find.text('评课公开联网授权已保存。'), findsOneWidget);

      await _tap(tester, 'onboarding-daily-operations-toggle');
      expect(agent.policyWrites.last.personalContentAllowed, isTrue);
      expect(agent.policyWrites.last.dailyOperationsAllowed, isTrue);
      await _tap(tester, 'onboarding-private-content-toggle');
      expect(agent.policyWrites.last.personalContentAllowed, isFalse);
      expect(agent.policyWrites.last.dailyOperationsAllowed, isTrue);

      expect(find.text('Agent 使用权限已保存。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed consent and system access never report success', (
    tester,
  ) async {
    final settings = _SettingsPort(icourseConsent: false)
      ..consentFailure = StateError('private test detail');
    final agent = _AgentPort();
    final reminders = _ReminderPort();
    final actions = <NotificationAccessAction>[];
    addTearDown(settings.dispose);
    addTearDown(agent.dispose);
    addTearDown(reminders.close);

    await tester.pumpWidget(
      _host(
        settings,
        agent,
        reminders,
        configureSystemAccess: (action) async {
          actions.add(action);
          throw StateError('native detail');
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(settings.consentWrites, isEmpty);
    expect(actions, isEmpty);

    await _tap(tester, 'onboarding-icourse-toggle');
    expect(settings.consentWrites.single.confirmed, isTrue);
    expect(find.text('评课公开联网授权未完成，请核对当前设置后重试。'), findsOneWidget);
    expect(find.textContaining('private test detail'), findsNothing);
    expect(find.text('评课公开联网授权已保存。'), findsNothing);

    await _tap(tester, 'onboarding-system-notifications');
    expect(actions, [NotificationAccessAction.notifications]);
    expect(find.text('通知权限操作未完成；仍可跳过此项。'), findsOneWidget);
    expect(find.textContaining('native detail'), findsNothing);
    expect(find.text('通知权限操作已完成；请以系统回读状态为准。'), findsNothing);
    expect(
      _switch(tester, 'onboarding-daily-operations-toggle').onChanged,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'late completion from a replaced controller cannot report success',
    (tester) async {
      final oldSettings = _SettingsPort(icourseConsent: false)
        ..consentGate = Completer<void>();
      final oldAgent = _AgentPort();
      final oldReminders = _ReminderPort();
      final nextSettings = _SettingsPort(icourseConsent: false);
      final nextAgent = _AgentPort();
      final nextReminders = _ReminderPort();
      addTearDown(oldSettings.dispose);
      addTearDown(oldAgent.dispose);
      addTearDown(oldReminders.close);
      addTearDown(nextSettings.dispose);
      addTearDown(nextAgent.dispose);
      addTearDown(nextReminders.close);

      await tester.pumpWidget(_host(oldSettings, oldAgent, oldReminders));
      await tester.pumpAndSettle();
      await _tap(tester, 'onboarding-icourse-toggle');
      expect(oldSettings.consentWrites, hasLength(1));
      expect(oldSettings.consentGate!.isCompleted, isFalse);

      await tester.pumpWidget(_host(nextSettings, nextAgent, nextReminders));
      await tester.pumpAndSettle();
      oldSettings.consentGate!.complete();
      await tester.pumpAndSettle();

      expect(_switch(tester, 'onboarding-icourse-toggle').value, isFalse);
      expect(find.text('评课公开联网授权已保存。'), findsNothing);
      expect(nextSettings.consentWrites, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('320dp width and large text remain scrollable and tappable', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 720);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = _SettingsPort();
    final agent = _AgentPort();
    final reminders = _ReminderPort();
    addTearDown(settings.dispose);
    addTearDown(agent.dispose);
    addTearDown(reminders.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: Scaffold(
              body: SafeArea(
                child: SingleChildScrollView(
                  child: OnboardingPermissionsStep(
                    settings: settings,
                    agent: agent,
                    reminders: reminders,
                    reminderChanges: const Stream.empty(),
                    initialReminderView: const ReminderRuntimeView(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final key in [
      'onboarding-reminder-toggle',
      'onboarding-morning-toggle',
      'onboarding-icourse-toggle',
      'onboarding-private-content-toggle',
      'onboarding-daily-operations-toggle',
    ]) {
      final finder = find.byKey(ValueKey(key));
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      expect(finder.hitTestable(), findsOneWidget, reason: key);
      expect(tester.getSize(finder).height, greaterThanOrEqualTo(48));
    }
    expect(tester.takeException(), isNull);
  });
}

Widget _host(
  _SettingsPort settings,
  _AgentPort agent,
  _ReminderPort reminders, {
  Future<void> Function(NotificationAccessAction action)? configureSystemAccess,
  ValueChanged<bool>? onBusyChanged,
}) => MaterialApp(
  home: Scaffold(
    body: SafeArea(
      child: SingleChildScrollView(
        child: OnboardingPermissionsStep(
          settings: settings,
          agent: agent,
          reminders: reminders,
          reminderChanges: const Stream.empty(),
          initialReminderView: const ReminderRuntimeView(),
          configureSystemAccess: configureSystemAccess,
          onBusyChanged: onBusyChanged,
        ),
      ),
    ),
  ),
);

final class _BusyWizardHost extends StatefulWidget {
  const _BusyWizardHost(this.settings, this.agent, this.reminders);

  final _SettingsPort settings;
  final _AgentPort agent;
  final _ReminderPort reminders;

  @override
  State<_BusyWizardHost> createState() => _BusyWizardHostState();
}

final class _BusyWizardHostState extends State<_BusyWizardHost> {
  bool _busy = false;
  final _runtime = StreamController<ReminderRuntimeView>.broadcast();

  @override
  void dispose() {
    unawaited(_runtime.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          Text(_busy ? '向导忙碌' : '向导空闲'),
          Expanded(
            child: SafeArea(
              child: SingleChildScrollView(
                child: OnboardingPermissionsStep(
                  settings: widget.settings,
                  agent: widget.agent,
                  reminders: widget.reminders,
                  // Production coordinators return a fresh equal wrapper on
                  // each getter read. Parent rebuilds must not reload setup.
                  reminderChanges: _runtime.stream,
                  initialReminderView: const ReminderRuntimeView(),
                  onBusyChanged: (busy) => setState(() => _busy = busy),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

SwitchListTile _switch(WidgetTester tester, String key) =>
    tester.widget(find.byKey(ValueKey(key)));

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

SettingsContext _settingsContext({int revision = 1}) => SettingsContext(
  owner: 'synthetic-owner',
  resetEpoch: 1,
  agendaEpoch: 2,
  revision: revision,
);

SettingsSnapshot _settingsSnapshot({
  required SettingsContext context,
  required bool icourseConsent,
}) => SettingsSnapshot(
  context: context,
  preferences: const DisplayPreferences(),
  counts: const LocalDataCounts(),
  accountBound: false,
  credentialSaved: false,
  icourseConsent: icourseConsent,
);

final class _SettingsPort extends ChangeNotifier
    implements ApplicationSettingsPort {
  _SettingsPort({bool icourseConsent = false})
    : _view = ApplicationSettingsView(
        snapshot: _settingsSnapshot(
          context: _settingsContext(),
          icourseConsent: icourseConsent,
        ),
      );

  ApplicationSettingsView _view;
  int refreshCalls = 0;
  Object? consentFailure;
  Completer<void>? consentGate;
  final List<({SettingsContext context, bool allowed, bool confirmed})>
  consentWrites = [];

  @override
  ApplicationSettingsView get settingsView => _view;

  @override
  Future<void> refreshSettings() async {
    refreshCalls++;
    notifyListeners();
  }

  @override
  Future<void> setIcourseConsent(
    SettingsContext context, {
    required bool allowed,
    required bool confirmed,
  }) async {
    consentWrites.add((
      context: context,
      allowed: allowed,
      confirmed: confirmed,
    ));
    await consentGate?.future;
    if (consentFailure != null) throw consentFailure!;
    final snapshot = _view.snapshot!;
    _view = ApplicationSettingsView(
      snapshot: _settingsSnapshot(
        context: _settingsContext(revision: snapshot.context.revision + 1),
        icourseConsent: allowed,
      ),
    );
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _PolicyWrite {
  const _PolicyWrite(this.personalContentAllowed, this.dailyOperationsAllowed);

  final bool personalContentAllowed;
  final bool dailyOperationsAllowed;
}

final class _AgentPort extends ChangeNotifier
    implements AgentWorkspacePort, AgentWorkspaceUsePolicyPort {
  _AgentPort({bool personal = false, bool daily = false})
    : _view = _agentView(personal: personal, daily: daily);

  AgentRuntimeView _view;
  int refreshCalls = 0;
  Object? policyFailure;
  Completer<void>? policyGate;
  final List<_PolicyWrite> policyWrites = [];

  @override
  AgentWorkspaceView get view => _view;

  @override
  Future<void> refresh() async {
    refreshCalls++;
    notifyListeners();
  }

  @override
  Future<void> saveUsePolicy({
    required bool personalContentAllowed,
    required bool dailyOperationsAllowed,
  }) async {
    policyWrites.add(
      _PolicyWrite(personalContentAllowed, dailyOperationsAllowed),
    );
    await policyGate?.future;
    if (policyFailure != null) throw policyFailure!;
    _view = _agentView(
      personal: personalContentAllowed,
      daily: dailyOperationsAllowed,
    );
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AgentRuntimeView _agentView({bool personal = false, bool daily = false}) =>
    AgentRuntimeView(
      settings: AgentSettingsSnapshot(
        authority: const AgentAuthority(
          owner: 'synthetic-owner',
          resetEpoch: 1,
          historyEpoch: 1,
          configRevision: 1,
        ),
      ),
      usePolicyConfigured: true,
      personalContentAllowed: personal,
      dailyOperationsAllowed: daily,
    );

final class _ReminderPort extends Fake implements ReminderDataPort {
  _ReminderPort({ReminderPreferences? preferences})
    : current = ReminderSettings(
        context: const CalendarContext(
          owner: 'synthetic-owner',
          resetEpoch: 1,
          agendaEpoch: 2,
        ),
        revision: 1,
        briefEpoch: 1,
        preferences: preferences ?? const ReminderPreferences(),
      );

  final StreamController<int> _changes = StreamController<int>.broadcast();
  ReminderSettings current;
  int inspectCalls = 0;
  final List<ReminderPreferences> preferenceWrites = [];

  @override
  Stream<int> get changes => _changes.stream;

  @override
  Future<ReminderSettings> inspectReminders() async {
    inspectCalls++;
    return current;
  }

  @override
  Future<void> saveReminderPreferences(
    ReminderSettings expected,
    ReminderPreferences preferences,
  ) async {
    preferenceWrites.add(preferences);
    current = ReminderSettings(
      context: expected.context,
      revision: expected.revision + 1,
      briefEpoch: expected.briefEpoch,
      preferences: preferences,
    );
    _changes.add(current.revision);
  }

  Future<void> close() => _changes.close();
}
