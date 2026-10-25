import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/app_shell_contract.dart';
import 'package:ustc_assistant_m0/app/calendar_workspace_contract.dart';
import 'package:ustc_assistant_m0/app/calendar_workspace_controller.dart';
import 'package:ustc_assistant_m0/app/calendar_workspace_page.dart';
import 'package:ustc_assistant_m0/app/product_app.dart';
import 'package:ustc_assistant_m0/core/agenda_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/jobs/jw_sync_port.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_port.dart';

const _context = CalendarContext(
  owner: 'synthetic-source-retirement-owner',
  resetEpoch: 0,
  agendaEpoch: 0,
);
final _day = DateTime.utc(2026, 10, 15);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'retired calendar rows require the history toggle and retain outside-scope state',
    (tester) async {
      await _setSize(tester, const Size(1280, 900));
      final retired = _retiredOccurrence();
      final data = _CalendarData(retired);
      final shell = _Shell();
      final controller = CalendarWorkspaceController(
        calendar: data,
        shell: shell,
        clock: FixedClock(DateTime.utc(2026, 10, 15, 1)),
      );
      await controller.load(day: _day, mode: CalendarViewMode.day);
      Future<void> cleanup() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await controller.shutdown();
          controller.dispose();
          await data.close();
          shell.dispose();
        });
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: CalendarWorkspacePage(controller: controller)),
          ),
        );
        await tester.pumpAndSettle();
        expect(data.lastQuery!.includeRetired, isFalse);
        expect(find.text(retired.title), findsNothing);

        await tester.tap(
          find.byKey(const ValueKey('calendar-workspace-filter')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('显示隐藏/跳过及来源失效历史'));
        await tester.pumpAndSettle();

        expect(data.lastQuery!.includeRetired, isTrue);
        expect(find.text(retired.title), findsOneWidget);
        expect(find.text('来源已不再返回 · 已退出有效日程'), findsOneWidget);
        expect(find.text('当前不在观察范围'), findsOneWidget);
        expect(find.textContaining('学校已取消'), findsNothing);
        expect(find.textContaining('取消报名'), findsNothing);

        await tester.tap(find.text(retired.title));
        await tester.pumpAndSettle();
        expect(find.text('来源已不再返回，已退出有效日程。'), findsOneWidget);
        expect(find.text('这条记录目前不在来源已观察的范围内。'), findsOneWidget);
        expect(find.text('隐藏状态只控制本地显示，不会恢复来源有效性。'), findsOneWidget);
      } finally {
        await cleanup();
      }
    },
  );

  testWidgets(
    'legacy agenda history toggle displays retired rows with a clear state',
    (tester) async {
      await _setSize(tester, const Size(1280, 900));
      final item = _retiredAgendaItem();
      final shell = _Shell(agendaItem: item);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        shell.dispose();
      });

      await tester.pumpWidget(
        ProductApp(
          controller: shell,
          settingsBuilder: (_) => const SizedBox.shrink(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shell-nav-agenda')));
      await tester.pumpAndSettle();
      expect(shell.lastIncludeHidden, isFalse);
      expect(find.text(item.title), findsNothing);

      await tester.tap(find.text('显示隐藏及来源失效历史'));
      await tester.pumpAndSettle();

      expect(shell.lastIncludeHidden, isTrue);
      expect(find.text(item.title), findsOneWidget);
      expect(find.text('来源已不再返回 · 已退出有效日程'), findsOneWidget);

      await tester.tap(find.text(item.title));
      await tester.pumpAndSettle();
      expect(find.text('来源已不再返回，已退出有效日程。'), findsOneWidget);
      expect(find.text('隐藏状态只控制本地显示，不会恢复来源有效性。'), findsOneWidget);
    },
  );
}

Future<void> _setSize(WidgetTester tester, Size size) async {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  await tester.pump();
}

CalendarOccurrence _retiredOccurrence() => CalendarOccurrence(
  reference: CalendarReference(
    _context,
    const CalendarIdentity(CalendarKind.young, 71),
    1,
  ),
  title: '合成来源失效日程',
  startsAtUtc: DateTime.utc(2026, 10, 15, 1),
  endsAtUtc: DateTime.utc(2026, 10, 15, 2),
  presence: AgendaPresence.outsideScope,
  sourceRetired: true,
);

AgendaItem _retiredAgendaItem() => AgendaItem(
  reference: const AgendaReference(
    source: AgendaSource.young,
    localId: 72,
    version: 1,
  ),
  title: '合成旧Agenda失效日程',
  startsAtUtc: DateTime.utc(2026, 10, 15, 1),
  endsAtUtc: DateTime.utc(2026, 10, 15, 2),
  presence: AgendaPresence.outsideScope,
  hidden: false,
  sourceRetired: true,
);

final class _CalendarData implements LocalCalendarPort {
  _CalendarData(this.retired);

  final CalendarOccurrence retired;
  final StreamController<int> _changes = StreamController<int>.broadcast();
  CalendarQuery? lastQuery;

  @override
  Stream<int> get changes => _changes.stream;

  @override
  Future<CalendarWindow> query(CalendarQuery query) async {
    lastQuery = query;
    final items = query.includeRetired
        ? <CalendarOccurrence>[retired]
        : <CalendarOccurrence>[];
    return CalendarWindow(
      context: _context,
      revision: 1,
      query: query,
      items: items,
      segments: const [],
      conflicts: const [],
      matched: items.length,
      truncated: false,
      conflictsTruncated: false,
    );
  }

  @override
  Future<CalendarDetail> detail(CalendarReference reference) async =>
      CalendarDetail(
        occurrence: retired,
        personalDraft: null,
        relations: const [],
      );

  Future<void> close() => _changes.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Shell extends ChangeNotifier implements AppShellPort {
  _Shell({this.agendaItem})
    : _view = AppShellView(
        jw: JwSyncView(),
        young: YoungSyncView(),
        globallyBusy: false,
      );

  final AgendaItem? agendaItem;
  final AppShellView _view;
  bool? lastIncludeHidden;

  @override
  AppShellView get view => _view;

  @override
  DateTime get today => _day;

  @override
  AgendaSlice readAgenda({
    required DateTime day,
    AgendaFilter filter = AgendaFilter.all,
    bool includeHidden = false,
  }) {
    lastIncludeHidden = includeHidden;
    final items = agendaItem == null || !includeHidden
        ? <AgendaItem>[]
        : <AgendaItem>[agendaItem!];
    return AgendaSlice(
      day: day,
      filter: filter,
      includeHidden: includeHidden,
      items: items,
      matched: items.length,
      totalStored: agendaItem == null ? 0 : 1,
      ready: true,
      truncated: false,
    );
  }

  @override
  Future<void> setHidden(AgendaReference reference, {required bool hidden}) =>
      Future<void>.value();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
