import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/app_shell_contract.dart';
import 'package:ustc_assistant_m0/app/app_settings_page.dart';
import 'package:ustc_assistant_m0/app/settings_contract.dart';
import 'package:ustc_assistant_m0/app/source_settings_page.dart';
import 'package:ustc_assistant_m0/app/young_daily_sync_panel.dart';
import 'package:ustc_assistant_m0/app/young_sync_panel.dart';
import 'package:ustc_assistant_m0/core/agenda_contract.dart';
import 'package:ustc_assistant_m0/core/young_daily_sync_contract.dart';
import 'package:ustc_assistant_m0/jobs/jw_sync_port.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_port.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('keeps the switch unchanged when saving fails', (tester) async {
    final port = _FakeDailySyncPort();
    addTearDown(port.dispose);
    await _pump(tester, port);

    expect(_toggle(tester).value, isFalse);
    expect(find.text('请先在下方绑定二课账号并保存学校密码，再使用每日自动同步。'), findsOneWidget);
    port.failSetEnabled = true;
    await _tap(tester, find.byKey(const ValueKey('young-daily-sync-toggle')));

    expect(_toggle(tester).value, isFalse);
    expect(port.setEnabledCalls, 1);
    expect(find.text('保存每日同步设置失败，请稍后重试。'), findsOneWidget);
    expect(find.textContaining('synthetic-secret'), findsNothing);

    port.failSetEnabled = false;
    await _tap(tester, find.byKey(const ValueKey('young-daily-sync-toggle')));
    expect(_toggle(tester).value, isTrue);

    port.failSetEnabled = true;
    await _tap(tester, find.byKey(const ValueKey('young-daily-sync-toggle')));
    expect(_toggle(tester).value, isTrue);
    expect(port.view.enabled, isTrue);
  });

  testWidgets('opens a visible login flow and offers continue and cancel', (
    tester,
  ) async {
    final port = _FakeDailySyncPort(
      initial: _snapshot(
        enabled: true,
        configured: true,
        phase: YoungDailySyncPhase.needsLogin,
      ),
    );
    addTearDown(port.dispose);
    await _pump(tester, port);

    await _tap(tester, find.byKey(const ValueKey('young-daily-sync-now')));
    expect(port.syncNowCalls, 1);
    expect(
      find.byKey(const ValueKey('young-daily-sync-continue')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('young-daily-sync-cancel')),
      findsOneWidget,
    );

    await _tap(tester, find.byKey(const ValueKey('young-daily-sync-continue')));
    expect(port.continueCalls, 1);
    expect(find.text('正在同步二课个人日历。'), findsOneWidget);

    await _tap(tester, find.byKey(const ValueKey('young-daily-sync-cancel')));
    expect(port.cancelCalls, 1);
  });

  testWidgets('shows the previous success separately from a failed attempt', (
    tester,
  ) async {
    final port = _FakeDailySyncPort(
      initial: _snapshot(
        enabled: true,
        configured: true,
        phase: YoungDailySyncPhase.failed,
        lastSuccessAtUtc: DateTime.utc(2026, 10, 14, 20),
        firstDay: DateTime.utc(2026, 10, 14),
        endDayExclusive: DateTime.utc(2026, 11, 14),
        nextAttemptAtUtc: DateTime.utc(2026, 10, 15, 0),
      ),
    );
    addTearDown(port.dispose);
    await _pump(tester, port);

    expect(find.text('本轮同步未完成，自动尝试次数有上限。'), findsOneWidget);
    expect(find.text('最近成功：2026-10-15 04:00（北京时间）'), findsOneWidget);
    expect(find.text('下次重试：2026-10-15 08:00（北京时间）'), findsOneWidget);
    expect(find.text('滚动范围：2026-10-14 至 2026-11-13（含）。'), findsOneWidget);
    expect(find.text('本轮同步已完成。'), findsNothing);
  });

  testWidgets('keeps the setting available while a sync is running', (
    tester,
  ) async {
    final port = _FakeDailySyncPort(
      initial: _snapshot(
        enabled: true,
        configured: true,
        phase: YoungDailySyncPhase.syncing,
      ),
    );
    addTearDown(port.dispose);
    await _pump(tester, port);

    expect(_toggle(tester).onChanged, isNotNull);
    await _tap(tester, find.byKey(const ValueKey('young-daily-sync-toggle')));

    expect(port.setEnabledCalls, 1);
    expect(port.view.enabled, isFalse);
    expect(_toggle(tester).value, isFalse);
  });

  testWidgets('blocks immediate sync while the automatic switch is off', (
    tester,
  ) async {
    final port = _FakeDailySyncPort(
      initial: _snapshot(
        enabled: false,
        configured: true,
        phase: YoungDailySyncPhase.disabled,
      ),
    );
    addTearDown(port.dispose);
    await _pump(tester, port);

    expect(_syncNowButton(tester).onPressed, isNull);
    expect(find.text('先开启每日自动同步，才能立即同步。'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('young-daily-sync-now')));
    expect(port.syncNowCalls, 0);
  });

  testWidgets('blocks immediate sync in advice-only mode', (tester) async {
    final port = _FakeDailySyncPort(
      initial: _snapshot(
        enabled: true,
        configured: true,
        adviceOnly: true,
        phase: YoungDailySyncPhase.paused,
      ),
    );
    addTearDown(port.dispose);
    await _pump(tester, port);

    expect(_syncNowButton(tester).onPressed, isNull);
    expect(find.text('仅建议模式下无法立即同步。'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('young-daily-sync-now')));
    expect(port.syncNowCalls, 0);
  });

  testWidgets('fits a narrow panel with enlarged text', (tester) async {
    final port = _FakeDailySyncPort(
      initial: _snapshot(
        enabled: true,
        configured: true,
        phase: YoungDailySyncPhase.needsLogin,
        interactive: true,
      ),
    );
    addTearDown(port.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2.2)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Center(
              child: SizedBox(
                width: 320,
                child: YoungDailySyncPanel(controller: port),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('已登录，继续'), findsOneWidget);
    expect(find.text('取消同步'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('replaces the controller subscription and view', (tester) async {
    final oldPort = _FakeDailySyncPort(
      initial: _snapshot(
        enabled: true,
        configured: true,
        phase: YoungDailySyncPhase.syncing,
      ),
    );
    final newPort = _FakeDailySyncPort();
    addTearDown(oldPort.dispose);
    addTearDown(newPort.dispose);

    await _pump(tester, oldPort);
    expect(find.text('正在同步二课个人日历。'), findsOneWidget);

    await tester.pumpWidget(_host(newPort));
    await tester.pumpAndSettle();
    oldPort.emit(
      _snapshot(
        enabled: true,
        configured: true,
        phase: YoungDailySyncPhase.failed,
      ),
    );
    await tester.pump();

    expect(find.text('每日自动同步已关闭。'), findsOneWidget);
    expect(find.text('本轮同步未完成，自动尝试次数有上限。'), findsNothing);
    expect(oldPort.hasListener, isFalse);
    expect(newPort.hasListener, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the panel only while the Young source is selected', (
    tester,
  ) async {
    final shell = _FakeShell();
    final dailySync = _FakeDailySyncPort();
    addTearDown(shell.dispose);
    addTearDown(dailySync.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SourceSettingsPage(controller: shell, dailySync: dailySync),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('young-daily-sync-panel')), findsNothing);
    await _tap(tester, find.byKey(const ValueKey('source-settings-young')));
    expect(
      find.byKey(const ValueKey('young-daily-sync-panel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('young-sync-start-calendar')),
      findsOneWidget,
    );
    await _tap(tester, find.byKey(const ValueKey('source-settings-jw')));
    expect(find.byKey(const ValueKey('young-daily-sync-panel')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final scenario in <({Size size, double scale})>[
    (size: const Size(1280, 760), scale: 1),
    (size: const Size(900, 600), scale: 1.5),
    (size: const Size(420, 700), scale: 2),
  ]) {
    testWidgets(
      'complete settings keeps daily controls above the manual form ${scenario.size}/${scenario.scale}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = scenario.size;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final shell = _FakeShell();
        final settings = _FakeSettings();
        final daily = _FakeDailySyncPort(
          initial: _snapshot(
            enabled: true,
            configured: true,
            phase: YoungDailySyncPhase.scheduled,
          ),
        );
        addTearDown(shell.dispose);
        addTearDown(settings.dispose);
        addTearDown(daily.dispose);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scenario.scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: ApplicationSettingsPage(
                  settings: settings,
                  controller: shell,
                  dailySync: daily,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _tap(tester, find.byKey(const ValueKey('source-settings-young')));

        final dailyRect = tester.getRect(find.byType(YoungDailySyncPanel));
        final manualRect = tester.getRect(find.byType(YoungSyncPanel));
        expect(
          dailyRect.bottom,
          lessThanOrEqualTo(manualRect.top),
          reason:
              'The manual form must follow the entire daily panel, not clip it into a header viewport.',
        );
        final toggle = find.byKey(const ValueKey('young-daily-sync-toggle'));
        await tester.ensureVisible(toggle);
        await tester.pumpAndSettle();
        expect(toggle.hitTestable(), findsOneWidget);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(daily.setEnabledCalls, 1);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        final syncNow = find.byKey(const ValueKey('young-daily-sync-now'));
        await tester.ensureVisible(syncNow);
        await tester.pumpAndSettle();
        expect(syncNow.hitTestable(), findsOneWidget);
        final password = find.byKey(const ValueKey('young-sync-password'));
        await tester.ensureVisible(password);
        await tester.pumpAndSettle();
        expect(password.hitTestable(), findsOneWidget);
        await tester.enterText(
          password,
          'synthetic-not-retained-after-source-switch',
        );
        await tester.ensureVisible(toggle);
        await tester.pumpAndSettle();
        await tester.ensureVisible(password);
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(password).controller!.text,
          'synthetic-not-retained-after-source-switch',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}

final class _FakeSettings extends ChangeNotifier
    implements ApplicationSettingsPort {
  @override
  ApplicationSettingsView get settingsView => const ApplicationSettingsView();
  @override
  Future<void> refreshSettings() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SwitchListTile _toggle(WidgetTester tester) => tester.widget<SwitchListTile>(
  find.byKey(const ValueKey('young-daily-sync-toggle')),
);

OutlinedButton _syncNowButton(WidgetTester tester) => tester
    .widget<OutlinedButton>(find.byKey(const ValueKey('young-daily-sync-now')));

Future<void> _pump(WidgetTester tester, _FakeDailySyncPort port) async {
  await tester.pumpWidget(_host(port));
  await tester.pumpAndSettle();
}

Widget _host(_FakeDailySyncPort port) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: Center(
        child: SizedBox(
          width: 560,
          child: YoungDailySyncPanel(
            key: const ValueKey('daily-panel'),
            controller: port,
          ),
        ),
      ),
    ),
  ),
);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

YoungDailySyncView _snapshot({
  bool enabled = false,
  bool configured = false,
  bool adviceOnly = false,
  bool suppressedToday = false,
  bool interactive = false,
  YoungDailySyncPhase phase = YoungDailySyncPhase.disabled,
  DateTime? lastSuccessAtUtc,
  DateTime? firstDay,
  DateTime? endDayExclusive,
  DateTime? nextAttemptAtUtc,
}) => YoungDailySyncView(
  enabled: enabled,
  configured: configured,
  adviceOnly: adviceOnly,
  suppressedToday: suppressedToday,
  interactive: interactive,
  phase: phase,
  lastSuccessAtUtc: lastSuccessAtUtc,
  firstDay: firstDay,
  endDayExclusive: endDayExclusive,
  nextAttemptAtUtc: nextAttemptAtUtc,
);

YoungDailySyncView _copyView(
  YoungDailySyncView old, {
  bool? enabled,
  YoungDailySyncPhase? phase,
  bool? interactive,
}) => YoungDailySyncView(
  enabled: enabled ?? old.enabled,
  configured: old.configured,
  adviceOnly: old.adviceOnly,
  suppressedToday: old.suppressedToday,
  interactive: interactive ?? old.interactive,
  phase: phase ?? old.phase,
  lastSuccessAtUtc: old.lastSuccessAtUtc,
  firstDay: old.firstDay,
  endDayExclusive: old.endDayExclusive,
  nextAttemptAtUtc: old.nextAttemptAtUtc,
  attempts: old.attempts,
  failure: old.failure,
);

final class _FakeDailySyncPort implements YoungDailySyncControlPort {
  _FakeDailySyncPort({YoungDailySyncView? initial})
    : _view = initial ?? _snapshot();

  final StreamController<YoungDailySyncView> _changes =
      StreamController<YoungDailySyncView>.broadcast(sync: true);
  YoungDailySyncView _view;
  bool failSetEnabled = false;
  int setEnabledCalls = 0;
  int syncNowCalls = 0;
  int continueCalls = 0;
  int cancelCalls = 0;

  @override
  YoungDailySyncView get view => _view;

  @override
  Stream<YoungDailySyncView> get changes => _changes.stream;

  bool get hasListener => _changes.hasListener;

  void emit(YoungDailySyncView view) {
    _view = view;
    _changes.add(view);
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    setEnabledCalls++;
    if (failSetEnabled) throw StateError('synthetic-secret');
    emit(
      _copyView(
        _view,
        enabled: enabled,
        phase: enabled
            ? YoungDailySyncPhase.scheduled
            : YoungDailySyncPhase.disabled,
      ),
    );
  }

  @override
  Future<void> syncNow() async {
    syncNowCalls++;
    emit(
      _copyView(
        _view,
        phase: YoungDailySyncPhase.needsLogin,
        interactive: true,
      ),
    );
  }

  @override
  Future<void> continueAfterLogin() async {
    continueCalls++;
    emit(
      _copyView(_view, phase: YoungDailySyncPhase.syncing, interactive: true),
    );
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    emit(
      _copyView(_view, phase: YoungDailySyncPhase.paused, interactive: false),
    );
  }

  Future<void> dispose() => _changes.close();
}

final class _FakeShell extends ChangeNotifier implements AppShellPort {
  final _FakeJwPort _jw = _FakeJwPort();
  final _FakeYoungPort _young = _FakeYoungPort();

  @override
  JwSyncPort get jw => _jw;

  @override
  YoungSyncPort get young => _young;

  @override
  AppShellView get view => AppShellView(
    jw: _jw.syncView,
    young: _young.syncView,
    globallyBusy: false,
  );

  @override
  DateTime get today => DateTime.utc(2026, 10, 15);

  @override
  AgendaSlice readAgenda({
    required DateTime day,
    AgendaFilter filter = AgendaFilter.all,
    bool includeHidden = false,
  }) => AgendaSlice(
    day: day,
    filter: filter,
    includeHidden: includeHidden,
    items: const [],
    matched: 0,
    totalStored: 0,
    ready: true,
    truncated: false,
  );

  @override
  Future<void> setHidden(
    AgendaReference reference, {
    required bool hidden,
  }) async {}

  @override
  void dispose() {
    unawaited(_jw.dispose());
    unawaited(_young.dispose());
    super.dispose();
  }
}

final class _FakeJwPort implements JwSyncPort {
  final StreamController<JwSyncView> _changes =
      StreamController<JwSyncView>.broadcast(sync: true);

  @override
  JwSyncView get syncView => JwSyncView();

  @override
  Stream<JwSyncView> get syncChanges => _changes.stream;

  Future<void> dispose() => _changes.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeYoungPort implements YoungSyncPort {
  final StreamController<YoungSyncView> _changes =
      StreamController<YoungSyncView>.broadcast(sync: true);

  @override
  YoungSyncView get syncView => YoungSyncView();

  @override
  Stream<YoungSyncView> get syncChanges => _changes.stream;

  Future<void> dispose() => _changes.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
