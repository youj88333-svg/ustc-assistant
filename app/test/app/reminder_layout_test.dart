import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/m6_settings_panel.dart';
import 'package:ustc_assistant_m0/app/product_app.dart';
import 'package:ustc_assistant_m0/app/reminder_editor.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/morning_brief_contract.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';

const _writePolishPreview = bool.fromEnvironment(
  'USTC_POLISH_PREVIEW',
  defaultValue: false,
);

void main() {
  testWidgets(
    'settings labels and controls stay separated across window sizes',
    (tester) async {
      final data = _LayoutReminderData();
      final briefs = _LayoutBriefData();
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();

      const scenarios = <({Size size, double textScale})>[
        (size: Size(320, 900), textScale: 1),
        (size: Size(320, 900), textScale: 1.5),
        (size: Size(320, 900), textScale: 2),
        (size: Size(960, 900), textScale: 1),
        (size: Size(1440, 900), textScale: 1),
      ];

      try {
        for (final scenario in scenarios) {
          tester.view.physicalSize = scenario.size;
          await tester.pumpWidget(
            _settingsHost(data, briefs, scenario.textScale),
          );
          await tester.pumpAndSettle();

          _expectSectionLayout(
            tester,
            heading: '定时日程',
            keyPrefix: 'm6-timed-default',
            firstKind: 'before',
            secondKind: 'none',
            firstTrailingControl: 'm6-timed-default-slot-1-before-30',
            width: scenario.size.width,
          );
          _expectSectionLayout(
            tester,
            heading: '全天日程',
            keyPrefix: 'm6-all-day-default',
            firstKind: 'dayTime',
            secondKind: 'none',
            firstTrailingControl: 'm6-all-day-default-slot-1-time',
            width: scenario.size.width,
          );
          expect(
            find.bySemanticsLabel(RegExp('第一次提醒')),
            findsWidgets,
            reason: 'The first reminder field should have an accessible label.',
          );
          expect(
            find.bySemanticsLabel(RegExp('第二次提醒')),
            findsWidgets,
            reason:
                'The second reminder field should have an accessible label.',
          );
          expect(tester.takeException(), isNull);
        }
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('both slots remain editable, timed, and disabled as configured', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pair = ValueNotifier<ReminderPair>(ReminderPair.timed);
    addTearDown(pair.dispose);

    await tester.pumpWidget(_pairHost(pair, allDay: false, enabled: true));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('layout-slot-1-kind-before')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('不提醒').last);
    await tester.pumpAndSettle();
    expect(pair.value.first.kind, ReminderRuleKind.none);

    await tester.tap(find.byKey(const ValueKey('layout-slot-2-kind-none')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日程开始前').last);
    await tester.pumpAndSettle();
    expect(pair.value.second.kind, ReminderRuleKind.before);
    expect(pair.value.first.kind, ReminderRuleKind.none);

    await tester.tap(find.byKey(const ValueKey('layout-slot-2-before-30')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('提前 60 分钟').last);
    await tester.pumpAndSettle();
    expect(pair.value.second.minutesBefore, 60);

    pair.value = const ReminderPair(
      ReminderRule.none(),
      ReminderRule.dayTime(dayOffset: 0, minuteOfDay: 540),
    );
    await tester.pumpWidget(_pairHost(pair, allDay: true, enabled: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('layout-slot-2-time')));
    await tester.pumpAndSettle();

    final dialog = find.byType(TimePickerDialog);
    expect(dialog, findsOneWidget);
    expect(MediaQuery.alwaysUse24HourFormatOf(tester.element(dialog)), isTrue);
    await tester.tap(
      find.descendant(
        of: dialog,
        matching: find.byIcon(Icons.keyboard_outlined),
      ),
    );
    await tester.pumpAndSettle();
    final timeFields = find.descendant(
      of: dialog,
      matching: find.byType(TextField),
    );
    await tester.enterText(timeFields.at(0), '10');
    await tester.enterText(timeFields.at(1), '15');
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: dialog,
        matching: find.widgetWithText(TextButton, '确定'),
      ),
    );
    await tester.pumpAndSettle();
    expect(pair.value.second.minuteOfDay, 615);

    await tester.pumpWidget(_pairHost(pair, allDay: true, enabled: false));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownButtonFormField<ReminderRuleKind>>(
            find.byKey(const ValueKey('layout-slot-2-kind-dayTime')),
          )
          .onChanged,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('layout-slot-2-time')),
          )
          .onPressed,
      isNull,
    );
    expect(pair.value.first.kind, ReminderRuleKind.none);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'mobile reminder editor exposes confirm and cancel above keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final data = _LayoutReminderData();
      const target = ReminderTarget(
        _LayoutReminderData._context,
        ReminderKind.taskDeadline,
        7,
        0,
        12,
      );
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: const [Locale('zh', 'CN')],
          locale: const Locale('zh', 'CN'),
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(2)),
              child: Scaffold(
                body: Center(
                  child: TextButton(
                    key: const ValueKey('open-mobile-reminder-editor'),
                    onPressed: () => showReminderEditor(
                      context,
                      data: data,
                      target: target,
                      allDay: false,
                    ),
                    child: const Text('打开提醒'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('open-mobile-reminder-editor')),
      );
      await tester.pumpAndSettle();

      final customChoice = find.byKey(
        const ValueKey('reminder-editor-slot-1-before-30'),
      );
      await tester.ensureVisible(customChoice);
      final choiceRect = tester.getRect(customChoice);
      expect(choiceRect.height, greaterThanOrEqualTo(48));
      expect(choiceRect.left, greaterThanOrEqualTo(0));
      expect(choiceRect.right, lessThanOrEqualTo(320));
      await tester.tap(customChoice);
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定义…').last);
      await tester.pumpAndSettle();

      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      final confirm = find.byKey(const ValueKey('reminder-custom-confirm'));
      final cancelCustom = find.byKey(const ValueKey('reminder-custom-cancel'));
      for (final targetFinder in [confirm, cancelCustom]) {
        final rect = tester.getRect(targetFinder);
        expect(rect.height, greaterThanOrEqualTo(48));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(320));
        expect(rect.bottom, lessThanOrEqualTo(520));
        expect(targetFinder.hitTestable(), findsOneWidget);
      }
      await tester.tap(cancelCustom);
      await tester.pumpAndSettle();
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(find.text('提前 30 分钟'), findsOneWidget);

      await tester.tap(customChoice);
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定义…').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('reminder-custom-minutes')),
        '45',
      );
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(find.text('自定义（45 分钟）'), findsOneWidget);
      expect(
        tester
            .widget<ReminderPairControls>(find.byType(ReminderPairControls))
            .pair
            .first
            .minutesBefore,
        45,
      );

      final saveEditor = find.byKey(const ValueKey('reminder-editor-save'));
      final cancelEditor = find.byKey(const ValueKey('reminder-editor-cancel'));
      for (final targetFinder in [saveEditor, cancelEditor]) {
        await tester.ensureVisible(targetFinder);
        final rect = tester.getRect(targetFinder);
        expect(rect.height, greaterThanOrEqualTo(48));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(320));
        expect(rect.bottom, lessThanOrEqualTo(800));
        expect(targetFinder.hitTestable(), findsOneWidget);
      }
      await tester.tap(cancelEditor);
      await tester.pumpAndSettle();
      expect(data.savePairCalls, 0);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('optional synthetic reminder preview', (tester) async {
    if (!_writePolishPreview) return;

    final fontBytes = File('C:/Windows/Fonts/msyh.ttc').readAsBytesSync();
    await tester.runAsync(() async {
      final loader = FontLoader('PolishPreviewChinese')
        ..addFont(Future<ByteData>.value(ByteData.sublistView(fontBytes)));
      await loader.load();
      final icons = File(
        'E:/flutter/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ).readAsBytesSync();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(Future<ByteData>.value(ByteData.sublistView(icons)))).load();
    });

    tester.view.physicalSize = const Size(960, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: productTheme.copyWith(
          textTheme: productTheme.textTheme.apply(
            fontFamily: 'PolishPreviewChinese',
          ),
          primaryTextTheme: productTheme.primaryTextTheme.apply(
            fontFamily: 'PolishPreviewChinese',
          ),
        ),
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('zh', 'CN')],
        locale: const Locale('zh', 'CN'),
        home: Scaffold(
          body: Center(child: SizedBox(width: 640, child: _syntheticPreview())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('reminder-polish-preview')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1.5);
      try {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        if (png == null) throw StateError('PNG encoding returned no bytes.');
        final outputDirectory = Directory('build/windows-polish-preview');
        await outputDirectory.create(recursive: true);
        await File(
          'build/windows-polish-preview/reminder-layout.png',
        ).writeAsBytes(png.buffer.asUint8List(), flush: true);
      } finally {
        image.dispose();
      }
    });
  });
}

void _expectSectionLayout(
  WidgetTester tester, {
  required String heading,
  required String keyPrefix,
  required String firstKind,
  required String secondKind,
  required String firstTrailingControl,
  required double width,
}) {
  final headingRect = tester.getRect(find.text(heading));
  final firstLabel = find.byKey(ValueKey('$keyPrefix-slot-1-label'));
  final firstControl = find.byKey(
    ValueKey('$keyPrefix-slot-1-kind-$firstKind'),
  );
  final secondLabel = find.byKey(ValueKey('$keyPrefix-slot-2-label'));
  final secondControl = find.byKey(
    ValueKey('$keyPrefix-slot-2-kind-$secondKind'),
  );
  final firstTrailingRect = tester.getRect(
    find.byKey(ValueKey(firstTrailingControl)),
  );
  final firstLabelRect = tester.getRect(firstLabel);
  final firstControlRect = tester.getRect(firstControl);
  final secondLabelRect = tester.getRect(secondLabel);
  final secondControlRect = tester.getRect(secondControl);

  expect(firstLabelRect.top - headingRect.bottom, greaterThanOrEqualTo(8));
  expect(firstControlRect.top - firstLabelRect.bottom, greaterThanOrEqualTo(8));
  expect(
    secondLabelRect.top - firstTrailingRect.bottom,
    greaterThanOrEqualTo(16),
  );
  expect(
    secondControlRect.top - secondLabelRect.bottom,
    greaterThanOrEqualTo(8),
  );
  for (final rect in [firstControlRect, firstTrailingRect, secondControlRect]) {
    expect(rect.left, greaterThanOrEqualTo(14));
    expect(rect.right, lessThanOrEqualTo(width - 14));
  }
}

Widget _settingsHost(
  _LayoutReminderData data,
  _LayoutBriefData briefs,
  double textScale,
) => MaterialApp(
  theme: productTheme,
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  supportedLocales: const [Locale('zh', 'CN')],
  locale: const Locale('zh', 'CN'),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: M6SettingsPanel(
          data: data,
          briefs: briefs,
          reminderChanges: const Stream<ReminderRuntimeView>.empty(),
          initialReminderView: const ReminderRuntimeView(),
          retryReminders: () async {},
          regenerateMorning: () async {},
        ),
      ),
    ),
  ),
);

Widget _pairHost(
  ValueNotifier<ReminderPair> pair, {
  required bool allDay,
  required bool enabled,
}) => MaterialApp(
  theme: productTheme,
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  supportedLocales: const [Locale('zh', 'CN')],
  locale: const Locale('zh', 'CN'),
  home: Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(14),
      child: ValueListenableBuilder<ReminderPair>(
        valueListenable: pair,
        builder: (context, value, _) => ReminderPairControls(
          pair: value,
          allDay: allDay,
          enabled: enabled,
          keyPrefix: 'layout',
          onChanged: (next) => pair.value = next,
        ),
      ),
    ),
  ),
);

Widget _syntheticPreview() => RepaintBoundary(
  key: const ValueKey('reminder-polish-preview'),
  child: Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Builder(
            builder: (context) =>
                Text('全局默认提醒', style: Theme.of(context).textTheme.titleMedium),
          ),
          const SizedBox(height: 4),
          const Text('单条日程可单独覆盖；恢复默认会重新继承这里的规则。'),
          const SizedBox(height: 12),
          Builder(
            builder: (context) =>
                Text('定时日程', style: Theme.of(context).textTheme.titleSmall),
          ),
          const SizedBox(height: 8),
          ReminderPairControls(
            pair: ReminderPair.timed,
            allDay: false,
            enabled: true,
            keyPrefix: 'preview-timed',
            onChanged: (_) {},
          ),
          const SizedBox(height: 16),
          Builder(
            builder: (context) =>
                Text('全天日程', style: Theme.of(context).textTheme.titleSmall),
          ),
          const SizedBox(height: 8),
          ReminderPairControls(
            pair: ReminderPair.allDay,
            allDay: true,
            enabled: true,
            keyPrefix: 'preview-all-day',
            onChanged: (_) {},
          ),
        ],
      ),
    ),
  ),
);

final class _LayoutReminderData implements ReminderDataPort {
  static const _context = CalendarContext(
    owner: 'synthetic-owner',
    resetEpoch: 1,
    agendaEpoch: 2,
  );

  final ReminderSettings _settings = const ReminderSettings(
    context: _context,
    revision: 1,
    briefEpoch: 1,
    preferences: ReminderPreferences(enabled: true),
  );
  int savePairCalls = 0;

  @override
  Stream<int> get changes => const Stream<int>.empty();

  @override
  Future<ReminderSettings> inspectReminders() async => _settings;

  @override
  Future<ReminderPair?> readReminderPair(
    ReminderTarget target, {
    bool series = false,
  }) async => null;

  @override
  Future<void> saveReminderPair(
    ReminderTarget target,
    ReminderPair? pair, {
    bool series = false,
  }) async {
    savePairCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected reminder data call: ${invocation.memberName}',
  );
}

final class _LayoutBriefData implements MorningBriefDataPort {
  @override
  Stream<int> get changes => const Stream<int>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected morning brief call: ${invocation.memberName}',
  );
}
