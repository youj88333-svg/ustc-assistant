import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/m6_settings_panel.dart';
import 'package:ustc_assistant_m0/app/reminder_editor.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/morning_brief_contract.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets('a one-off editor shows its effective series rule', (
    tester,
  ) async {
    final data = _ReminderData()..seriesOverride = _customPair(10);
    addTearDown(data.dispose);
    await tester.pumpWidget(_editorHost(data, supportsSeries: true));
    await _openEditor(tester, supportsSeries: true);

    expect(find.text('当前继承整个系列的提醒设置。'), findsOneWidget);
    expect(
      tester
          .widget<DropdownButtonFormField<ReminderRuleKind>>(
            find.byKey(const ValueKey('reminder-editor-slot-1-kind-before')),
          )
          .initialValue,
      ReminderRuleKind.before,
    );

    await tester.tap(find.text('整个系列'));
    await tester.pumpAndSettle();
    expect(find.text('整个系列使用单独的提醒设置。'), findsOneWidget);
  });

  testWidgets('saving without edits preserves an incompatible old override', (
    tester,
  ) async {
    final data = _ReminderData()..targetOverride = ReminderPair.allDay;
    addTearDown(data.dispose);
    await tester.pumpWidget(_editorHost(data));
    await _openEditor(tester);

    expect(find.text('已保留的本次设置与当前日程类型不匹配；当前使用全局默认提醒。'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('reminder-editor-save')));
    await tester.pumpAndSettle();

    expect(data.targetOverride, ReminderPair.allDay);
    expect(data.inspectedSaves, 0);
    expect(data.legacySaves, 0);
  });

  testWidgets('an editor opened before an Agent rule change rejects its save', (
    tester,
  ) async {
    final data = _ReminderData();
    addTearDown(data.dispose);
    await tester.pumpWidget(_editorHost(data));
    await _openEditor(tester);

    data.changeTargetOverride(_customPair(5));
    await tester.tap(
      find.byKey(const ValueKey('reminder-editor-slot-1-kind-before')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('不提醒').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reminder-editor-save')));
    await tester.pumpAndSettle();

    expect(find.text('提醒设置已被其他操作修改，请重新读取后再保存。'), findsOneWidget);
    expect(data.targetOverride?.first.minutesBefore, 5);
    expect(data.targetOverride?.second.kind, ReminderRuleKind.none);
    expect(data.inspectedSaves, 0);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('reminder-editor-save')),
          )
          .onPressed,
      isNull,
    );

    await tester.tap(find.byKey(const ValueKey('reminder-editor-retry-read')));
    await tester.pumpAndSettle();
    expect(find.text('本次使用单独的提醒设置。'), findsOneWidget);
  });

  testWidgets('global settings refresh before editing one slot', (
    tester,
  ) async {
    final data = _ReminderData();
    final briefs = _BriefData();
    addTearDown(data.dispose);
    await tester.pumpWidget(_settingsHost(data, briefs));
    await tester.pumpAndSettle();

    data.changePreferences(
      data.settings.preferences.copyWith(timed: _pairWithSecond(5)),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('m6-timed-default-slot-2-kind-before')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('m6-timed-default-slot-1-kind-before')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('不提醒').last);
    await tester.pumpAndSettle();

    expect(data.settings.preferences.timed.first.kind, ReminderRuleKind.none);
    expect(data.settings.preferences.timed.second.minutesBefore, 5);
  });

  testWidgets('a stale global pair cannot erase a newly changed slot', (
    tester,
  ) async {
    final data = _ReminderData();
    final briefs = _BriefData();
    addTearDown(data.dispose);
    await tester.pumpWidget(_settingsHost(data, briefs));
    await tester.pumpAndSettle();

    data.changePreferences(
      data.settings.preferences.copyWith(timed: _pairWithSecond(5)),
      notify: false,
    );
    await tester.tap(
      find.byKey(const ValueKey('m6-timed-default-slot-1-kind-before')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('不提醒').last);
    await tester.pumpAndSettle();

    expect(data.settings.preferences.timed.first.minutesBefore, 30);
    expect(data.settings.preferences.timed.second.minutesBefore, 5);
    expect(find.textContaining('提醒设置已被其他操作修改'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('m6-timed-default-slot-2-kind-before')),
      findsOneWidget,
    );
  });

  testWidgets(
    'changes received while clearing a brief refresh after the action',
    (tester) async {
      final data = _ReminderData();
      final briefs = _BriefData()..clearGate = Completer<void>();
      addTearDown(data.dispose);
      await tester.pumpWidget(_settingsHost(data, briefs));
      await tester.pumpAndSettle();
      final clear = find.byKey(const ValueKey('m6-clear-morning'));
      await tester.ensureVisible(clear);
      await tester.tap(clear);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('m6-clear-morning-confirm')));
      await tester.pumpAndSettle();
      data.changePreferences(
        data.settings.preferences.copyWith(timed: _pairWithSecond(5)),
      );
      await tester.pump();
      briefs.clearGate!.complete();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('m6-timed-default-slot-2-kind-before')),
        findsOneWidget,
      );
      expect(find.text('已清除本地晨报。'), findsOneWidget);
    },
  );
}

Widget _editorHost(_ReminderData data, {bool supportsSeries = false}) =>
    MaterialApp(
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('zh', 'CN')],
      locale: const Locale('zh', 'CN'),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              key: const ValueKey('open-reminder-editor'),
              onPressed: () => unawaited(
                showReminderEditor(
                  context,
                  data: data,
                  target: _target,
                  allDay: false,
                  supportsSeries: supportsSeries,
                ),
              ),
              child: const Text('提醒'),
            ),
          ),
        ),
      ),
    );

Future<void> _openEditor(
  WidgetTester tester, {
  bool supportsSeries = false,
}) async {
  await tester.tap(find.byKey(const ValueKey('open-reminder-editor')));
  await tester.pumpAndSettle();
  expect(find.byType(AlertDialog), findsOneWidget);
  if (supportsSeries) expect(find.text('仅本次'), findsOneWidget);
}

Widget _settingsHost(_ReminderData data, _BriefData briefs) => MaterialApp(
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  supportedLocales: const [Locale('zh', 'CN')],
  locale: const Locale('zh', 'CN'),
  home: Scaffold(
    body: M6SettingsPanel(
      data: data,
      briefs: briefs,
      reminderChanges: const Stream<ReminderRuntimeView>.empty(),
      initialReminderView: const ReminderRuntimeView(),
      retryReminders: () async {},
      regenerateMorning: () async {},
    ),
  ),
);

const _context = CalendarContext(
  owner: 'synthetic-owner',
  resetEpoch: 2,
  agendaEpoch: 3,
);
const _target = ReminderTarget(_context, ReminderKind.personal, 9, 2, 4);

ReminderPair _customPair(int minutes) =>
    ReminderPair(ReminderRule.before(minutes), const ReminderRule.none());

ReminderPair _pairWithSecond(int minutes) =>
    ReminderPair(const ReminderRule.before(30), ReminderRule.before(minutes));

final class _ReminderData extends Fake
    implements ReminderDataPort, ReminderEditingPort {
  final StreamController<int> _changes = StreamController<int>.broadcast();
  ReminderSettings settings = const ReminderSettings(
    context: _context,
    revision: 1,
    briefEpoch: 1,
    preferences: ReminderPreferences(enabled: true),
  );
  ReminderPair? targetOverride;
  ReminderPair? seriesOverride;
  int inspectedSaves = 0, legacySaves = 0;

  @override
  Stream<int> get changes => _changes.stream;

  @override
  Future<ReminderSettings> inspectReminders() async => settings;

  @override
  Future<ReminderInspection> inspectReminder(
    ReminderTarget target, {
    bool series = false,
  }) async {
    final allDay = false;
    final exact = series ? seriesOverride : targetOverride;
    final overridePresent = exact != null;
    var origin = series
        ? (exact == null
              ? ReminderPairOrigin.defaults
              : ReminderPairOrigin.series)
        : (exact == null
              ? ReminderPairOrigin.defaults
              : ReminderPairOrigin.target);
    var pair = exact;
    if (!series && pair == null && seriesOverride != null) {
      pair = seriesOverride;
      origin = ReminderPairOrigin.series;
    }
    if (pair != null && !pair.supports(allDay: allDay)) {
      pair = null;
      origin = ReminderPairOrigin.defaults;
    }
    pair ??= settings.preferences.timed;
    return ReminderInspection(
      settings: settings,
      target: target,
      allDay: allDay,
      pair: pair,
      origin: origin,
      eligible: true,
      reason: 'ready',
      hasTime: true,
      acceptedSlots: const [],
      series: series,
      overridePresent: overridePresent,
    );
  }

  @override
  Future<void> saveInspectedReminder(
    ReminderInspection expected,
    ReminderPair? pair,
  ) async {
    if (expected.settings.revision != settings.revision ||
        expected.settings.context != settings.context) {
      throw const ReminderFailure(ReminderFailureCode.stale);
    }
    inspectedSaves++;
    if (expected.series) {
      seriesOverride = pair;
    } else {
      targetOverride = pair;
    }
    _bumpSettings(settings.preferences);
  }

  @override
  Future<ReminderPair?> readReminderPair(
    ReminderTarget target, {
    bool series = false,
  }) async => series ? seriesOverride : targetOverride;

  @override
  Future<void> saveReminderPair(
    ReminderTarget target,
    ReminderPair? pair, {
    bool series = false,
  }) async {
    legacySaves++;
    if (series) {
      seriesOverride = pair;
    } else {
      targetOverride = pair;
    }
  }

  @override
  Future<void> saveReminderPreferences(
    ReminderSettings expected,
    ReminderPreferences preferences,
  ) async {
    if (expected.revision != settings.revision ||
        expected.context != settings.context) {
      throw const ReminderFailure(ReminderFailureCode.stale);
    }
    _bumpSettings(preferences);
  }

  void changeTargetOverride(ReminderPair pair) {
    targetOverride = pair;
    _bumpSettings(settings.preferences);
  }

  void changePreferences(
    ReminderPreferences preferences, {
    bool notify = true,
  }) => _bumpSettings(preferences, notify: notify);

  void _bumpSettings(ReminderPreferences preferences, {bool notify = true}) {
    settings = ReminderSettings(
      context: settings.context,
      revision: settings.revision + 1,
      briefEpoch: settings.briefEpoch,
      preferences: preferences,
    );
    if (notify) _changes.add(settings.revision);
  }

  Future<void> dispose() => _changes.close();
}

final class _BriefData extends Fake implements MorningBriefDataPort {
  Completer<void>? clearGate;
  @override
  Future<void> clearMorningBriefs() async {
    await clearGate?.future;
  }
}
