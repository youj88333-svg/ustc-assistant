import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/app_shell_contract.dart';
import 'package:ustc_assistant_m0/app/product_app.dart';
import 'package:ustc_assistant_m0/core/agenda_contract.dart';
import 'package:ustc_assistant_m0/jobs/jw_sync_port.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_port.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('opens on Agent and keeps tasks inside the agenda page', (
    tester,
  ) async {
    await _setSize(tester, const Size(1280, 900));
    final port = _FakeShellPort();
    addTearDown(port.dispose);

    await tester.pumpWidget(_app(port));
    await tester.pumpAndSettle();

    expect(find.text('Agent 尚未接入'), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-nav-agent')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-nav-agenda')), findsOneWidget);
    expect(find.byKey(const ValueKey('shell-nav-settings')), findsOneWidget);
    expect(find.text('任务管理正在准备'), findsNothing);
    expect(port.readAgendaCalls, 0);
    expect(port.setHiddenCalls, 0);

    await tester.tap(find.byKey(const ValueKey('shell-nav-agenda')));
    await tester.pumpAndSettle();
    expect(find.text('日程'), findsWidgets);
    expect(find.text('任务'), findsOneWidget);
    expect(find.text('任务管理正在准备'), findsNothing);

    await tester.tap(find.text('任务'));
    await tester.pumpAndSettle();
    expect(find.text('任务管理正在准备'), findsOneWidget);
    expect(port.setHiddenCalls, 0);

    await tester.tap(find.byKey(const ValueKey('shell-nav-agent')));
    await tester.pumpAndSettle();
    final readsBeforeSettings = port.readAgendaCalls;
    await tester.tap(find.text('管理来源'));
    await tester.pumpAndSettle();
    expect(find.text('来源设置'), findsOneWidget);
    expect(port.readAgendaCalls, readsBeforeSettings);
  });

  testWidgets('Agent composer is disabled and never calls a source port', (
    tester,
  ) async {
    final port = _FakeShellPort();
    addTearDown(port.dispose);

    await tester.pumpWidget(_app(port));
    await tester.pumpAndSettle();

    final send = tester.widget<IconButton>(
      find.byKey(const ValueKey('agent-disabled-send')),
    );
    expect(send.onPressed, isNull);
    await tester.tap(find.byTooltip('发送'), warnIfMissed: false);
    await tester.pump();
    expect(port.readAgendaCalls, 0);
    expect(port.setHiddenCalls, 0);
  });

  testWidgets(
    'shows missing records and detail times in Beijing without writes',
    (tester) async {
      await _setSize(tester, const Size(1280, 900));
      final item = _item(
        id: 17,
        title: '合成课程 · 周一实验',
        startsAtUtc: DateTime.utc(2026, 10, 12, 1),
        endsAtUtc: DateTime.utc(2026, 10, 12, 2),
        presence: AgendaPresence.missingWithinScope,
      );
      final port = _FakeShellPort(items: [item]);
      addTearDown(port.dispose);

      await tester.pumpWidget(_app(port));
      await tester.tap(find.byKey(const ValueKey('shell-nav-agenda')));
      await tester.pumpAndSettle();

      expect(find.text('来源缺失，已保留'), findsOneWidget);
      expect(find.text('09:00 – 10:00'), findsOneWidget);
      await tester.tap(find.text(item.title));
      await tester.pumpAndSettle();

      expect(find.text('时间（北京时间）'), findsOneWidget);
      expect(find.text('2026-10-12 09:00 – 2026-10-12 10:00'), findsOneWidget);
      expect(find.text('地点未提供'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('agenda-detail-card')),
          matching: find.text('教务课程'),
        ),
        findsOneWidget,
      );
      expect(port.setHiddenCalls, 0);
    },
  );

  testWidgets('does not allow hiding while the global source lease is busy', (
    tester,
  ) async {
    await _setSize(tester, const Size(1280, 900));
    final port = _FakeShellPort(items: [_item(id: 18)], globallyBusy: true);
    addTearDown(port.dispose);

    await tester.pumpWidget(_app(port));
    await tester.tap(find.byKey(const ValueKey('shell-nav-agenda')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('课程事项'));
    await tester.pumpAndSettle();

    final hide = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '隐藏这条日程'),
    );
    expect(hide.onPressed, isNull);
    expect(find.text('当前来源作业或恢复尚未完成，暂不能修改显示状态。'), findsOneWidget);
    expect(port.setHiddenCalls, 0);
  });

  testWidgets('keeps matching local IDs from separate sources distinct', (
    tester,
  ) async {
    await _setSize(tester, const Size(1280, 900));
    final course = _item(id: 77, title: '教务来源事项');
    final young = _item(id: 77, title: '二课来源事项', source: AgendaSource.young);
    final port = _FakeShellPort(items: [course, young]);
    addTearDown(port.dispose);

    await tester.pumpWidget(_app(port));
    await tester.tap(find.byKey(const ValueKey('shell-nav-agenda')));
    await tester.pumpAndSettle();
    expect(find.text(course.title), findsOneWidget);
    expect(find.text(young.title), findsOneWidget);

    await tester.tap(find.text(young.title));
    await tester.pumpAndSettle();
    expect(find.text('二课日程'), findsWidgets);
    await tester.tap(find.text('隐藏这条日程'));
    await tester.pumpAndSettle();
    expect(port.setHiddenCalls, 1);
    expect(port.lastHiddenReference, young.reference);
    expect(port.lastHiddenValue, isTrue);
  });

  testWidgets('distinguishes an unready local view from a ready empty day', (
    tester,
  ) async {
    await _setSize(tester, const Size(1280, 900));
    final unready = _FakeShellPort(ready: false);
    final empty = _FakeShellPort();
    addTearDown(unready.dispose);
    addTearDown(empty.dispose);

    await tester.pumpWidget(_app(unready));
    await tester.tap(find.byKey(const ValueKey('shell-nav-agenda')));
    await tester.pumpAndSettle();
    expect(find.text('本地日程尚未就绪'), findsOneWidget);
    expect(find.text('这一天没有可显示的日程'), findsNothing);

    await tester.pumpWidget(_app(empty));
    await tester.pumpAndSettle();
    expect(find.text('这一天没有可显示的日程'), findsOneWidget);
    expect(find.text('本地日程尚未就绪'), findsNothing);
  });

  testWidgets('moves its listener and actions to a replacement controller', (
    tester,
  ) async {
    await _setSize(tester, const Size(1280, 900));
    final first = _FakeShellPort(items: [_item(id: 21)]);
    final second = _FakeShellPort(items: [_item(id: 22)]);
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    await tester.pumpWidget(_app(first));
    await tester.tap(find.byKey(const ValueKey('shell-nav-agenda')));
    await tester.pumpAndSettle();
    expect(first.readAgendaCalls, greaterThan(0));
    first.hideGate = Completer<void>();
    await tester.tap(find.text('课程事项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('隐藏这条日程'));
    await tester.pumpAndSettle();
    expect(first.setHiddenCalls, 1);

    await tester.pumpWidget(_app(second));
    await tester.pumpAndSettle();
    final secondReadsAfterReplacement = second.readAgendaCalls;
    expect(secondReadsAfterReplacement, greaterThan(0));
    expect(find.text('课程事项'), findsOneWidget);

    first.notifyListeners();
    await tester.pump();
    expect(second.readAgendaCalls, secondReadsAfterReplacement);

    second.notifyListeners();
    await tester.pump();
    expect(second.readAgendaCalls, greaterThan(secondReadsAfterReplacement));
    first.hideGate!.complete();
    await tester.pumpAndSettle();
    expect(second.setHiddenCalls, 0);

    await tester.tap(find.text('课程事项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('隐藏这条日程'));
    await tester.pumpAndSettle();
    expect(second.setHiddenCalls, 1);
    expect(first.setHiddenCalls, 1);
    expect(second.lastHiddenReference, _item(id: 22).reference);
    expect(second.lastHiddenValue, isTrue);
  });

  testWidgets(
    'a date picker from an old controller cannot change the new view',
    (tester) async {
      await _setSize(tester, const Size(1280, 900));
      final first = _FakeShellPort();
      final second = _FakeShellPort();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await tester.pumpWidget(_app(first));
      await tester.tap(find.byKey(const ValueKey('shell-nav-agenda')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('agenda-day-picker')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(_app(second));
      await tester.pumpAndSettle();
      await tester.tap(find.text('13').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.textContaining('2026年10月12日'), findsOneWidget);
      expect(find.textContaining('2026年10月13日'), findsNothing);
      expect(second.setHiddenCalls, 0);
    },
  );

  testWidgets('fits 320, 600, and 1280 pixel windows with long event text', (
    tester,
  ) async {
    final title = List<String>.filled(22, '合成日程标题').join('，');
    for (final size in const [
      Size(320, 800),
      Size(600, 800),
      Size(1280, 900),
    ]) {
      await _setSize(tester, size);
      final port = _FakeShellPort(
        items: [
          _item(
            id: size.width.toInt(),
            title: title,
            startsAtUtc: DateTime.utc(2026, 10, 12, 1),
            endsAtUtc: DateTime.utc(2026, 10, 12, 2),
          ),
        ],
      );
      await tester.pumpWidget(_app(port));
      await tester.pumpAndSettle();
      await _tapAgenda(tester);
      expect(tester.takeException(), isNull, reason: 'agenda at $size');

      await tester.ensureVisible(find.text(title));
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(find.text('地点未提供'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'details at $size');
      await tester.pumpWidget(const SizedBox.shrink());
      port.dispose();
    }
  });
}

ProductApp _app(AppShellPort port) => ProductApp(
  controller: port,
  settingsBuilder: (_) => const Center(child: Text('来源设置')),
);

Future<void> _setSize(WidgetTester tester, Size size) async {
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  await tester.pump();
}

Future<void> _tapAgenda(WidgetTester tester) async {
  if (tester.view.physicalSize.width < 760) {
    await tester.tap(find.byTooltip('打开导航'));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const ValueKey('shell-nav-agenda')));
  await tester.pumpAndSettle();
}

AgendaItem _item({
  required int id,
  String title = '课程事项',
  DateTime? startsAtUtc,
  DateTime? endsAtUtc,
  AgendaPresence presence = AgendaPresence.observed,
  bool hidden = false,
  AgendaSource source = AgendaSource.course,
}) => AgendaItem(
  reference: AgendaReference(source: source, localId: id, version: 1),
  title: title,
  startsAtUtc: startsAtUtc ?? DateTime.utc(2026, 10, 12, 1),
  endsAtUtc: endsAtUtc ?? DateTime.utc(2026, 10, 12, 2),
  presence: presence,
  hidden: hidden,
);

final class _FakeShellPort extends ChangeNotifier implements AppShellPort {
  _FakeShellPort({
    this.items = const [],
    this.ready = true,
    bool globallyBusy = false,
  }) : _view = AppShellView(
         jw: JwSyncView(),
         young: YoungSyncView(),
         globallyBusy: globallyBusy,
       ),
       jwPort = _FakeJwSyncPort(),
       youngPort = _FakeYoungSyncPort();

  final List<AgendaItem> items;
  final AppShellView _view;
  final bool ready;
  final _FakeJwSyncPort jwPort;
  final _FakeYoungSyncPort youngPort;
  int readAgendaCalls = 0;
  int setHiddenCalls = 0;
  AgendaReference? lastHiddenReference;
  bool? lastHiddenValue;
  Completer<void>? hideGate;

  @override
  AppShellView get view => _view;

  @override
  DateTime get today => DateTime.utc(2026, 10, 12);

  @override
  JwSyncPort get jw => jwPort;

  @override
  YoungSyncPort get young => youngPort;

  @override
  AgendaSlice readAgenda({
    required DateTime day,
    AgendaFilter filter = AgendaFilter.all,
    bool includeHidden = false,
  }) {
    readAgendaCalls++;
    final matching = items
        .where((item) {
          if (!includeHidden && item.hidden) return false;
          return switch (filter) {
            AgendaFilter.all => true,
            AgendaFilter.course => item.reference.source == AgendaSource.course,
            AgendaFilter.exam => item.reference.source == AgendaSource.exam,
            AgendaFilter.young => item.reference.source == AgendaSource.young,
          };
        })
        .toList(growable: false);
    return AgendaSlice(
      day: day,
      filter: filter,
      includeHidden: includeHidden,
      items: matching,
      matched: matching.length,
      totalStored: items.length,
      ready: ready,
      truncated: false,
    );
  }

  @override
  Future<void> setHidden(AgendaReference reference, {required bool hidden}) {
    setHiddenCalls++;
    lastHiddenReference = reference;
    lastHiddenValue = hidden;
    final gate = hideGate;
    return gate?.future ?? Future<void>.value();
  }
}

final class _FakeJwSyncPort implements JwSyncPort {
  @override
  JwSyncView get syncView => JwSyncView();

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeYoungSyncPort implements YoungSyncPort {
  @override
  YoungSyncView get syncView => YoungSyncView();

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
