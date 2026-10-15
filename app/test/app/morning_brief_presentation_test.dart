import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/assistant_markdown.dart';
import 'package:ustc_assistant_m0/app/morning_brief_card.dart';
import 'package:ustc_assistant_m0/app/product_app.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/morning_brief_contract.dart';
import 'package:ustc_assistant_m0/core/morning_notice_contract.dart';
import 'package:ustc_assistant_m0/core/public_query_contract.dart';

const _previewEnabled = bool.fromEnvironment('USTC_POLISH_PREVIEW');
final _day = DateTime.utc(2026, 10, 15);
final _yesterday = DateTime.utc(2026, 10, 14);

void main() {
  testWidgets('summary and attention lead while details remain folded', (
    tester,
  ) async {
    final view = _view(
      conflicts: 2,
      overdue: 1,
      agenda: [
        _agenda(title: '数据库系统实验', state: 'skip'),
        _agenda(title: '线性代数答疑', state: 'planned'),
      ],
    );
    await tester.pumpWidget(_host(view));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(const ValueKey('morning-brief-card'))).height,
      48,
    );
    expect(find.text('数据库系统实验'), findsNothing);
    expect(find.text('skip'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('morning-brief-open')));
    await tester.pumpAndSettle();

    expect(find.text('今天有 2 处时间冲突。'), findsOneWidget);
    expect(find.text('今天有 1 项任务截止。'), findsOneWidget);
    expect(find.text('还有 1 项逾期任务。'), findsOneWidget);
    expect(find.byIcon(Icons.event_busy_outlined), findsOneWidget);
    expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
    expect(
      tester
          .widget<AssistantMarkdown>(
            find.byKey(const ValueKey('morning-brief-full-summary')),
          )
          .data,
      contains('先处理今天的截止任务'),
    );
    expect(
      find.byKey(const ValueKey('morning-brief-agenda-expand')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('morning-brief-source-expand')),
      findsOneWidget,
    );
    expect(find.text('数据库系统实验'), findsNothing);
    expect(
      find.byKey(const ValueKey('morning-brief-notice-status')),
      findsNothing,
    );

    final agendaExpansion = find.byKey(
      const ValueKey('morning-brief-agenda-expand'),
    );
    await tester.ensureVisible(agendaExpansion);
    await tester.tap(agendaExpansion);
    await tester.pumpAndSettle();
    expect(find.text('计划不参加'), findsOneWidget);
    expect(find.text('待进行'), findsOneWidget);
    expect(find.text('skip'), findsNothing);
    expect(find.text('planned'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('morning-brief-details-close')));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('confirmed empty notices appear once and coverage stays folded', (
    tester,
  ) async {
    final view = _view(
      agenda: const [],
      tasks: const [],
      batch: _batch(notices: const []),
      summary: const MorningSummary(
        today: '今天没有已读取到的安排。',
        notices: '昨天没有符合条件的公开通知。\n\n没有公告需要处理。',
      ),
    );
    await tester.pumpWidget(_host(view));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('morning-brief-open')));
    await tester.pumpAndSettle();

    expect(find.text('昨天没有符合条件的公开通知。'), findsOneWidget);
    expect(find.text('没有公告需要处理。'), findsNothing);
    expect(find.text('教务通知'), findsNothing);
    expect(find.textContaining('符合日期'), findsNothing);

    final sourceExpansion = find.byKey(
      const ValueKey('morning-brief-source-expand'),
    );
    await tester.ensureVisible(sourceExpansion);
    await tester.tap(sourceExpansion);
    await tester.pumpAndSettle();
    expect(find.textContaining('昨天没有符合条件的公开通知'), findsOneWidget);
    expect(find.text('本次读取操作 2 次'), findsOneWidget);
  });

  testWidgets('unknown and failed source coverage stays explicit', (
    tester,
  ) async {
    final view = _view(
      factsComplete: false,
      batch: _batch(
        notices: const [],
        coverage: const [
          MorningNoticeCoverage(
            provider: PublicProvider.teach,
            pages: 2,
            matched: 0,
            unknownDates: 1,
            complete: false,
            failure: PublicFailureCode.unavailable,
          ),
          MorningNoticeCoverage(
            provider: PublicProvider.finance,
            pages: 1,
            matched: 0,
            unknownDates: 0,
            complete: true,
          ),
        ],
      ),
    );
    await tester.pumpWidget(_host(view));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('morning-brief-open')));
    await tester.pumpAndSettle();

    expect(find.textContaining('本地日程覆盖不完整'), findsOneWidget);
    expect(find.textContaining('通知覆盖不完整'), findsOneWidget);
    expect(find.text('昨天没有符合条件的公开通知。'), findsNothing);
    expect(find.text('今天没有已读取到的安排或截止任务。'), findsNothing);

    final sourceExpansion = find.byKey(
      const ValueKey('morning-brief-source-expand'),
    );
    await tester.ensureVisible(sourceExpansion);
    await tester.tap(sourceExpansion);
    await tester.pumpAndSettle();
    expect(find.textContaining('来源暂不可用'), findsOneWidget);
    expect(find.textContaining('1 条公告日期未知'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long Chinese agenda text wraps at 320px with magnified text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final longTitle = '数据库系统综合实验与课程设计阶段成果集中检查';
    final longLocation = '东校区信息楼第三教学区域 302 教室，靠近南侧入口与电梯间的实验工位';
    final view = _view(
      agenda: [_agenda(title: longTitle, location: longLocation)],
      tasks: const [],
    );
    await tester.pumpWidget(
      _host(view, textScaler: const TextScaler.linear(1.8)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('morning-brief-open')));
    await tester.pumpAndSettle();

    final agendaExpansion = find.byKey(
      const ValueKey('morning-brief-agenda-expand'),
    );
    await tester.ensureVisible(agendaExpansion);
    await tester.tap(agendaExpansion);
    await tester.pumpAndSettle();
    final titleFinder = find.byKey(
      ValueKey('morning-brief-agenda-title-$longTitle'),
    );
    final locationFinder = find.byKey(
      ValueKey('morning-brief-agenda-location-$longTitle'),
    );
    await tester.ensureVisible(locationFinder);
    expect(find.text(longTitle), findsOneWidget);
    expect(find.text('地点 · $longLocation'), findsOneWidget);
    expect(tester.getSize(titleFinder).width, lessThanOrEqualTo(248));
    expect(tester.getSize(locationFinder).width, lessThanOrEqualTo(248));
    expect(tester.takeException(), isNull);
  });

  testWidgets('preview is generated only when explicitly enabled', (
    tester,
  ) async {
    if (!_previewEnabled) return;

    final fontBytes = File('C:/Windows/Fonts/msyh.ttc').readAsBytesSync();
    await tester.runAsync(() async {
      final loader = FontLoader('WindowsCjkPreview')
        ..addFont(Future<ByteData>.value(ByteData.sublistView(fontBytes)));
      await loader.load();
      final icons = File(
        'E:/flutter/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ).readAsBytesSync();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(Future<ByteData>.value(ByteData.sublistView(icons)))).load();
    });

    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: productTheme.copyWith(
          textTheme: productTheme.textTheme.apply(
            fontFamily: 'WindowsCjkPreview',
          ),
          primaryTextTheme: productTheme.primaryTextTheme.apply(
            fontFamily: 'WindowsCjkPreview',
          ),
        ),
        builder: (context, child) => RepaintBoundary(
          key: const ValueKey('morning-preview-boundary'),
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 460,
              child: MorningBriefCard(
                view: _view(
                  conflicts: 1,
                  overdue: 1,
                  summary: const MorningSummary(
                    today:
                        '今天先留意一处时间冲突和一项逾期任务。\n\n'
                        '下午 14:00 的项目评审与实验安排有重叠，建议先确认时间。',
                    notices: '教务处发布了实验室开放时间调整，请留意本周安排。',
                  ),
                ),
                nowUtc: DateTime.utc(2026, 10, 15, 2),
                onRetry: () {},
                onHideToday: () {},
                openSource: (_) async {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('morning-brief-open')));
    await tester.pumpAndSettle();

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('morning-preview-boundary')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1.5);
      try {
        final pngData = await image.toByteData(format: ui.ImageByteFormat.png);
        if (pngData == null) {
          throw StateError('Could not encode the synthetic morning preview.');
        }
        final output = Directory('build/windows-polish-preview');
        await output.create(recursive: true);
        await File(
          '${output.path}/morning-brief.png',
        ).writeAsBytes(pngData.buffer.asUint8List(), flush: true);
      } finally {
        image.dispose();
      }
    });
  });
}

Widget _host(MorningRuntimeView view, {TextScaler? textScaler}) => MaterialApp(
  builder: (context, child) => textScaler == null
      ? child!
      : MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
  home: Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(8),
      child: MorningBriefCard(
        view: view,
        nowUtc: DateTime.utc(2026, 10, 15, 2),
        onRetry: () {},
        onHideToday: () {},
        openSource: (_) async {},
      ),
    ),
  ),
);

MorningRuntimeView _view({
  List<MorningAgendaItem>? agenda,
  List<MorningTaskItem>? tasks,
  int conflicts = 1,
  int overdue = 1,
  bool factsComplete = true,
  MorningNoticeBatch? batch,
  MorningSummary summary = const MorningSummary(
    today: '今天先处理今天的截止任务，再安排其他事项。',
    notices: '昨天有一条公开通知。',
  ),
  MorningBriefPhase phase = MorningBriefPhase.ready,
  bool busy = false,
  String? failure,
}) {
  final facts = MorningFacts(
    context: const CalendarContext(
      owner: 'synthetic-owner',
      resetEpoch: 1,
      agendaEpoch: 2,
    ),
    day: _day,
    digest: 'synthetic-digest',
    agenda: agenda ?? [_agenda()],
    tasks: tasks ?? [MorningTaskItem('课程报告', DateTime.utc(2026, 10, 15, 9))],
    conflicts: conflicts,
    overdueTasks: overdue,
    complete: factsComplete,
    hasSchoolImports: true,
  );
  final notices = batch ?? _batch();
  final brief = MorningBrief(
    day: _day,
    phase: phase,
    factDigest: facts.digest,
    autoAttempts: 1,
    notices: notices,
    summary: summary.encode(),
    failure: failure,
  );
  return MorningRuntimeView(
    enabled: true,
    busy: busy,
    facts: facts,
    brief: brief,
    phase: phase,
    text: brief.summary,
    failure: failure,
  );
}

MorningAgendaItem _agenda({
  String title = '数据库系统实验',
  String location = '信息楼 302 教室',
  String state = 'planned',
}) => MorningAgendaItem(
  title: title,
  location: location,
  start: DateTime.utc(2026, 10, 15, 1),
  end: DateTime.utc(2026, 10, 15, 3),
  allDay: false,
  kind: 'course',
  state: state,
);

MorningNoticeBatch _batch({
  List<MorningNotice>? notices,
  List<MorningNoticeCoverage> coverage = const [
    MorningNoticeCoverage(
      provider: PublicProvider.teach,
      pages: 1,
      matched: 1,
      unknownDates: 0,
      complete: true,
    ),
    MorningNoticeCoverage(
      provider: PublicProvider.finance,
      pages: 1,
      matched: 0,
      unknownDates: 0,
      complete: true,
    ),
  ],
}) => MorningNoticeBatch(
  day: _yesterday,
  notices:
      notices ??
      [
        MorningNotice(
          provider: PublicProvider.teach,
          title: '实验室通知',
          articleUrl: Uri.parse('https://example.edu/notice/1'),
          publishedDay: _yesterday,
          observedAtUtc: DateTime.utc(2026, 10, 14, 8),
          excerpt: '合成通知内容',
        ),
      ],
  coverage: coverage,
  operations: 2,
);
