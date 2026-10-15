import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/m6_settings_panel.dart';
import 'package:ustc_assistant_m0/app/morning_brief_card.dart';
import 'package:ustc_assistant_m0/app/reminder_editor.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/morning_brief_contract.dart';
import 'package:ustc_assistant_m0/core/morning_notice_contract.dart';
import 'package:ustc_assistant_m0/core/public_query_contract.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets(
    'setting switches persist independently through fresh snapshots',
    (tester) async {
      final data = _FakeReminderData();
      final briefs = _FakeBriefData();
      addTearDown(data.dispose);
      addTearDown(briefs.dispose);
      await tester.pumpWidget(_settingsHost(data, briefs));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('m6-morning-enabled')));
      await tester.pumpAndSettle();
      expect(data.settings.preferences.morningEnabled, isTrue);
      expect(data.settings.preferences.enabled, isFalse);
      expect(data.preferenceWrites, hasLength(1));
      expect(data.preferenceWriteExpected.single.context, data.context);

      await tester.tap(
        find.byKey(const ValueKey('m6-system-reminders-enabled')),
      );
      await tester.pumpAndSettle();
      expect(data.settings.preferences.enabled, isTrue);
      expect(data.settings.preferences.morningEnabled, isTrue);
      expect(data.preferenceWrites, hasLength(2));
      expect(data.inspectCalls, greaterThanOrEqualTo(5));
    },
  );

  testWidgets('timed reminder slot can be turned off and saved', (
    tester,
  ) async {
    final data = _FakeReminderData();
    addTearDown(data.dispose);
    await tester.pumpWidget(_editorHost(data));
    await _openEditor(tester);

    await tester.tap(
      find.byKey(const ValueKey('reminder-editor-slot-1-kind-before')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('不提醒').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reminder-editor-save')));
    await tester.pumpAndSettle();

    expect(data.savedPairs, hasLength(1));
    expect(data.savedPairs.single.pair?.first.kind, ReminderRuleKind.none);
    expect(data.savedPairs.single.series, isFalse);
  });

  testWidgets('restore default stores inheritance as a null pair', (
    tester,
  ) async {
    final data = _FakeReminderData();
    addTearDown(data.dispose);
    await tester.pumpWidget(_editorHost(data));
    await _openEditor(tester);

    await tester.tap(
      find.byKey(const ValueKey('reminder-editor-slot-1-kind-before')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('不提醒').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('reminder-editor-restore-default')),
    );
    await tester.pumpAndSettle();

    expect(data.savedPairs.single.pair, isNull);
  });

  testWidgets('preference save failure never reports success', (tester) async {
    final data = _FakeReminderData()..failPreferenceSave = true;
    final briefs = _FakeBriefData();
    addTearDown(data.dispose);
    addTearDown(briefs.dispose);
    await tester.pumpWidget(_settingsHost(data, briefs));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('m6-system-reminders-enabled')));
    await tester.pumpAndSettle();

    expect(find.text('保存提醒设置失败，请重试。'), findsOneWidget);
    expect(find.text('已保存。'), findsNothing);
    expect(data.settings.preferences.enabled, isFalse);
  });

  testWidgets('all-day slot uses the 24-hour time picker', (tester) async {
    final data = _FakeReminderData();
    addTearDown(data.dispose);
    await tester.pumpWidget(_editorHost(data, allDay: true));
    await _openEditor(tester, allDay: true);

    await tester.tap(find.byKey(const ValueKey('reminder-editor-slot-1-time')));
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
    final fields = find.descendant(
      of: dialog,
      matching: find.byType(TextField),
    );
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), '10');
    await tester.enterText(fields.at(1), '15');
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: dialog,
        matching: find.widgetWithText(TextButton, '确定'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reminder-editor-save')));
    await tester.pumpAndSettle();

    expect(data.savedPairs.single.pair?.first.kind, ReminderRuleKind.dayTime);
    expect(data.savedPairs.single.pair?.first.minuteOfDay, 615);
  });

  testWidgets('personal series scope is reread and saved explicitly', (
    tester,
  ) async {
    final data = _FakeReminderData();
    addTearDown(data.dispose);
    await tester.pumpWidget(_editorHost(data, supportsSeries: true));
    await _openEditor(tester, supportsSeries: true);

    await tester.tap(find.text('整个系列'));
    await tester.pumpAndSettle();
    expect(data.pairReadsSeries, [false, true]);
    await tester.tap(find.byKey(const ValueKey('reminder-editor-save')));
    await tester.pumpAndSettle();
    expect(data.savedPairs.single.series, isTrue);
  });

  testWidgets('pair save failure stays open and does not claim success', (
    tester,
  ) async {
    final data = _FakeReminderData()..failPairSave = true;
    addTearDown(data.dispose);
    await tester.pumpWidget(_editorHost(data));
    await _openEditor(tester);
    await tester.tap(find.byKey(const ValueKey('reminder-editor-save')));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('保存提醒设置失败，请重试。'), findsOneWidget);
    expect(find.textContaining('synthetic raw failure'), findsNothing);
  });

  testWidgets(
    'card is compact, folds notice body, and invokes callbacks only on tap',
    (tester) async {
      final opened = <Uri>[];
      var discussed = 0;
      final view = _morningView();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: const [Locale('zh', 'CN')],
          locale: const Locale('zh', 'CN'),
          home: Scaffold(
            body: SingleChildScrollView(
              child: MorningBriefCard(
                view: view,
                nowUtc: DateTime.utc(2026, 10, 14, 18),
                onRetry: () {},
                onDiscuss: () => discussed++,
                openSource: (uri) async {
                  opened.add(uri);
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('今日安排 1 项'), findsOneWidget);
      expect(find.textContaining('下一个未开始：实验课'), findsOneWidget);
      expect(find.text('晨报摘要短句。'), findsOneWidget);
      expect(find.text('仅在展开后出现的正文'), findsNothing);
      expect(opened, isEmpty);
      expect(discussed, 0);

      await tester.tap(find.byKey(const ValueKey('morning-brief-details')));
      await tester.pumpAndSettle();
      expect(find.text('仅在展开后出现的正文'), findsOneWidget);
      expect(opened, isEmpty);
      await tester.ensureVisible(
        find.byKey(const ValueKey('morning-brief-discuss')),
      );
      await tester.tap(find.byKey(const ValueKey('morning-brief-discuss')));
      expect(discussed, 1);
      expect(opened, isEmpty);
      await tester.ensureVisible(find.text('打开通知来源'));
      await tester.tap(find.text('打开通知来源'));
      await tester.pumpAndSettle();
      expect(opened, [Uri.parse('https://example.edu/notice/1')]);
    },
  );

  testWidgets('disabled morning brief does not leave an empty placeholder', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MorningBriefCard(
            view: const MorningRuntimeView(enabled: false),
            nowUtc: DateTime.utc(2026, 10, 14, 18),
            onRetry: () {},
            onDiscuss: () {},
            openSource: (_) async {},
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('morning-brief-card')), findsNothing);
  });

  testWidgets('card does not show an older brief as today', (tester) async {
    final current = _morningView();
    final stale = MorningRuntimeView(
      enabled: true,
      facts: current.facts,
      brief: MorningBrief(
        day: DateTime.utc(2026, 10, 14),
        phase: MorningBriefPhase.ready,
        factDigest: 'old-digest',
        autoAttempts: 1,
        summary: '旧日期摘要不能显示为今天。',
      ),
      phase: MorningBriefPhase.ready,
      text: '旧日期摘要不能显示为今天。',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MorningBriefCard(
            view: stale,
            nowUtc: DateTime.utc(2026, 10, 14, 18),
            onRetry: () {},
            onDiscuss: () {},
            openSource: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('晨报 · 2026-10-15'), findsOneWidget);
    expect(find.text('旧日期摘要不能显示为今天。'), findsNothing);
    expect(find.byKey(const ValueKey('morning-brief-details')), findsNothing);
  });

  testWidgets('clear morning requires confirmation and only calls brief port', (
    tester,
  ) async {
    final data = _FakeReminderData();
    final briefs = _FakeBriefData();
    addTearDown(data.dispose);
    addTearDown(briefs.dispose);
    await tester.pumpWidget(_settingsHost(data, briefs));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const ValueKey('m6-clear-morning')));
    await tester.tap(find.byKey(const ValueKey('m6-clear-morning')));
    await tester.pumpAndSettle();
    expect(briefs.clearCalls, 0);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(briefs.clearCalls, 0);

    await tester.ensureVisible(find.byKey(const ValueKey('m6-clear-morning')));
    await tester.tap(find.byKey(const ValueKey('m6-clear-morning')));
    await tester.pumpAndSettle();
    expect(find.textContaining('不清除日程、任务或聊天'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('m6-clear-morning-confirm')));
    await tester.pumpAndSettle();
    expect(briefs.clearCalls, 1);
  });

  testWidgets('regeneration button blocks duplicate callback while busy', (
    tester,
  ) async {
    final data = _FakeReminderData();
    final briefs = _FakeBriefData();
    final gate = Completer<void>();
    var calls = 0;
    addTearDown(data.dispose);
    addTearDown(briefs.dispose);
    await tester.pumpWidget(
      _settingsHost(
        data,
        briefs,
        regenerate: () {
          calls++;
          return gate.future;
        },
      ),
    );
    await tester.pumpAndSettle();

    final button = find.byKey(const ValueKey('m6-regenerate-morning'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    expect(calls, 1);
    expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
    gate.complete();
    await tester.pumpAndSettle();
    expect(calls, 1);
  });
}

Widget _settingsHost(
  _FakeReminderData data,
  _FakeBriefData briefs, {
  Future<void> Function()? regenerate,
}) => MaterialApp(
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  supportedLocales: const [Locale('zh', 'CN')],
  locale: const Locale('zh', 'CN'),
  home: Scaffold(
    body: M6SettingsPanel(
      data: data,
      briefs: briefs,
      reminderChanges: Stream<ReminderRuntimeView>.empty(),
      initialReminderView: ReminderRuntimeView(
        accepted: 3,
        desired: 4,
        complete: false,
        throughDay: DateTime.utc(2026, 10, 20),
        failure: ReminderFailureCode.publishFailed,
      ),
      retryReminders: () async {},
      regenerateMorning: regenerate ?? () async {},
    ),
  ),
);

Widget _editorHost(
  _FakeReminderData data, {
  bool allDay = false,
  bool supportsSeries = false,
}) => MaterialApp(
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
              target: _target(),
              allDay: allDay,
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
  bool allDay = false,
  bool supportsSeries = false,
}) async {
  await tester.tap(find.byKey(const ValueKey('open-reminder-editor')));
  await tester.pumpAndSettle();
  expect(find.byType(AlertDialog), findsOneWidget);
  if (supportsSeries) {
    expect(find.text('仅本次'), findsOneWidget);
  }
  if (allDay) {
    expect(find.text('按相对日期和时刻'), findsOneWidget);
  }
}

ReminderTarget _target() => const ReminderTarget(
  CalendarContext(owner: 'synthetic-owner', resetEpoch: 1, agendaEpoch: 2),
  ReminderKind.personal,
  7,
  2,
  3,
);

MorningRuntimeView _morningView() {
  const context = CalendarContext(
    owner: 'synthetic-owner',
    resetEpoch: 1,
    agendaEpoch: 2,
  );
  final facts = MorningFacts(
    context: context,
    day: DateTime.utc(2026, 10, 15),
    digest: 'safe-digest',
    agenda: [
      MorningAgendaItem(
        title: '实验课',
        location: '实验楼',
        start: DateTime.utc(2026, 10, 15, 1),
        end: DateTime.utc(2026, 10, 15, 3),
        allDay: false,
        kind: 'course',
        state: 'planned',
      ),
    ],
    tasks: const [],
    conflicts: 0,
    overdueTasks: 0,
    complete: true,
    hasSchoolImports: true,
  );
  final notices = MorningNoticeBatch(
    day: DateTime.utc(2026, 10, 14),
    notices: [
      MorningNotice(
        provider: PublicProvider.teach,
        title: '实验室通知',
        articleUrl: Uri.parse('https://example.edu/notice/1'),
        publishedDay: DateTime.utc(2026, 10, 14),
        observedAtUtc: DateTime.utc(2026, 10, 14, 8),
        excerpt: '仅在展开后出现的正文',
      ),
    ],
    coverage: const [
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
    operations: 2,
  );
  final brief = MorningBrief(
    day: DateTime.utc(2026, 10, 15),
    phase: MorningBriefPhase.ready,
    factDigest: 'safe-digest',
    autoAttempts: 1,
    notices: notices,
    summary: '晨报摘要短句。',
  );
  return MorningRuntimeView(
    enabled: true,
    facts: facts,
    brief: brief,
    phase: MorningBriefPhase.ready,
    text: '晨报摘要短句。',
  );
}

final class _FakeReminderData implements ReminderDataPort {
  _FakeReminderData()
    : settings = ReminderSettings(
        context: const CalendarContext(
          owner: 'synthetic-owner',
          resetEpoch: 1,
          agendaEpoch: 2,
        ),
        revision: 1,
        briefEpoch: 1,
        preferences: const ReminderPreferences(),
      );

  final StreamController<int> _changes = StreamController<int>.broadcast();
  final List<({bool series, ReminderTarget target, ReminderPair? pair})>
  savedPairs = [];
  final List<bool> pairReadsSeries = [];
  final List<ReminderSettings> preferenceWriteExpected = [];
  final List<ReminderPreferences> preferenceWrites = [];
  ReminderSettings settings;
  int inspectCalls = 0;
  bool failPairSave = false;
  bool failPreferenceSave = false;

  CalendarContext get context => settings.context;

  @override
  Stream<int> get changes => _changes.stream;

  @override
  Future<ReminderSettings> inspectReminders() async {
    inspectCalls++;
    return settings;
  }

  @override
  Future<void> saveReminderPreferences(
    ReminderSettings expected,
    ReminderPreferences preferences,
  ) async {
    if (failPreferenceSave) throw StateError('synthetic raw failure');
    if (expected.context != settings.context ||
        expected.revision != settings.revision) {
      throw const ReminderFailure(ReminderFailureCode.stale);
    }
    preferenceWriteExpected.add(expected);
    preferenceWrites.add(preferences);
    settings = ReminderSettings(
      context: settings.context,
      revision: settings.revision + 1,
      briefEpoch: settings.briefEpoch,
      preferences: preferences,
    );
    _changes.add(settings.revision);
  }

  @override
  Future<ReminderPair?> readReminderPair(
    ReminderTarget target, {
    bool series = false,
  }) async {
    pairReadsSeries.add(series);
    return null;
  }

  @override
  Future<void> saveReminderPair(
    ReminderTarget target,
    ReminderPair? pair, {
    bool series = false,
  }) async {
    if (failPairSave) throw StateError('synthetic raw failure');
    savedPairs.add((series: series, target: target, pair: pair));
  }

  @override
  Future<ReminderPublication> prepareReminderPublication() async =>
      ReminderPublication(
        context: settings.context,
        revision: settings.revision,
        enabled: settings.preferences.enabled,
        desired: const [],
        prior: const [],
        invalidPriorIds: const [],
        complete: true,
        throughDay: DateTime.utc(2026, 10, 20),
      );

  @override
  Future<bool> reminderPublicationCurrent(
    ReminderPublication publication,
  ) async => true;

  @override
  Future<void> recordReminderAccepted(
    ReminderPublication publication,
    String id,
  ) async {}

  @override
  Future<void> recordReminderCancelled(String id) async {}

  @override
  Future<ReminderTarget?> resolveNotification(
    NotificationActivation activation,
  ) async => null;

  Future<void> dispose() => _changes.close();
}

final class _FakeBriefData implements MorningBriefDataPort {
  final StreamController<int> _changes = StreamController<int>.broadcast();
  int clearCalls = 0;

  @override
  Stream<int> get changes => _changes.stream;

  @override
  Future<MorningFacts> morningFacts(DateTime day) async =>
      throw UnimplementedError();

  @override
  Future<MorningBrief?> readMorningBrief(DateTime day) async => null;

  @override
  Future<MorningBriefTicket?> beginMorningBrief(
    DateTime day, {
    bool manual = false,
  }) async => null;

  @override
  Future<bool> beginMorningModelAttempt(MorningBriefTicket ticket) async =>
      false;

  @override
  Future<void> saveMorningBrief(
    MorningBriefTicket ticket, {
    required MorningBriefPhase phase,
    MorningNoticeBatch? notices,
    String? summary,
    String? failure,
    int? inputTokens,
    int? outputTokens,
  }) async {}

  @override
  Future<void> ensureMorningTicket(MorningBriefTicket ticket) async {}

  @override
  Future<void> clearMorningBriefs() async {
    clearCalls++;
  }

  Future<void> dispose() => _changes.close();
}
