import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/app/calendar_teaching_axis.dart';
import 'package:ustc_assistant_m0/app/calendar_workspace_contract.dart';
import 'package:ustc_assistant_m0/app/calendar_workspace_page.dart';
import 'package:ustc_assistant_m0/app/demo_runtime.dart';
import 'package:ustc_assistant_m0/app/product_app.dart';
import 'package:ustc_assistant_m0/core/agenda_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets(
    'native workspace creates and edits personal events through C5 and retains decisions after reopen',
    (tester) async {
      final workspace = await _createWorkspace();
      final runtimes = <DemoRuntime>[];
      DemoRuntime? active;
      try {
        active = await _openRuntime(tester, workspace);
        runtimes.add(active);
        expect(active.directory.isHeld, isTrue);
        expect(active.jwDirectory.isHeld, isTrue);
        expect(
          (await _runNative(tester, active.jwStore.readAuthority)).accountBound,
          isFalse,
          reason:
              'Personal arrangements must work before a school account exists.',
        );

        await tester.pumpWidget(_productApp(active));
        await tester.pumpAndSettle();
        await _tapKey(tester, 'shell-nav-agenda');
        expect(
          find.byKey(const ValueKey('calendar-personal-create')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('calendar-workspace-view-mode')),
          findsOneWidget,
        );

        // Create a past-due one-time event. The explicit completion fact must
        // remain false until the user presses the detail action.
        await _createEvent(
          tester,
          title: 'M42 one-time UI event',
          startDay: '2026-10-12',
          startTime: '08:30',
          endDay: '2026-10-12',
          endTime: '09:15',
          note: 'single event note',
        );
        var window = await _query(
          tester,
          active,
          DateTime.utc(2026, 10, 12),
          DateTime.utc(2026, 10, 13),
        );
        var single = _oneItem(window, 'M42 one-time UI event');
        expect(single.startsAtUtc, _beijingTime(2026, 10, 12, 8, 30));
        expect(single.endsAtUtc, _beijingTime(2026, 10, 12, 9, 15));
        expect(single.completed, isFalse);
        expect(single.note, 'single event note');
        expect(
          active.calendar.view.window!.items.any(
            (item) => item.reference.identity == single.reference.identity,
          ),
          isTrue,
          reason: 'The C5 workspace must refresh from the committed C3 result.',
        );
        await _selectViewMode(tester, CalendarViewMode.day);
        expect(find.byKey(const ValueKey('calendar-day-list')), findsOneWidget);
        expect(find.text('M42 one-time UI event'), findsOneWidget);
        await _selectViewMode(tester, CalendarViewMode.week);
        expect(
          find.byKey(const ValueKey('calendar-week-horizontal-scroll')),
          findsOneWidget,
        );
        final weekEvent = find.byKey(
          ValueKey<CalendarReference>(single.reference),
        );
        expect(weekEvent, findsOneWidget);
        expect(
          find.descendant(
            of: weekEvent,
            matching: find.textContaining('M42 one-time UI event'),
          ),
          findsOneWidget,
        );
        await _captureSyntheticUi(tester, 'week');
        await _selectViewMode(tester, CalendarViewMode.day);
        expect(
          (await _runNative(tester, active.jwStore.readAuthority)).accountBound,
          isFalse,
          reason: 'Creating a personal event must not invent a school account.',
        );

        // Beijing all-day end dates are entered inclusively and persisted as
        // an exclusive next-day boundary.
        await _createEvent(
          tester,
          title: 'M42 all-day span',
          startDay: '2026-10-12',
          endDay: '2026-10-14',
          allDay: true,
        );
        final allDayWindow = await _query(
          tester,
          active,
          DateTime.utc(2026, 10, 12),
          DateTime.utc(2026, 10, 15),
        );
        final allDay = _oneItem(allDayWindow, 'M42 all-day span');
        expect(allDay.allDay, isTrue);
        expect(allDay.startsAtUtc, DateTime.utc(2026, 10, 11, 16));
        expect(allDay.endsAtUtc, DateTime.utc(2026, 10, 14, 16));
        expect(
          allDayWindow.segments
              .where(
                (segment) => segment.occurrence.reference == allDay.reference,
              )
              .map((segment) => segment.day)
              .toList(),
          [
            DateTime.utc(2026, 10, 12),
            DateTime.utc(2026, 10, 13),
            DateTime.utc(2026, 10, 14),
          ],
        );

        await _createEvent(
          tester,
          title: 'M42 weekly UI series',
          startDay: '2026-09-07',
          startTime: '08:00',
          endDay: '2026-09-07',
          endTime: '09:00',
          weekly: true,
          untilDay: '2026-10-26',
        );
        final earlyWindow = await _query(
          tester,
          active,
          DateTime.utc(2026, 9, 7),
          DateTime.utc(2026, 9, 8),
        );
        final early = _oneItem(earlyWindow, 'M42 weekly UI series');
        expect(early.reference.identity.ordinal, 0);

        // Move the first occurrence from five weeks ago into the current week
        // through the page editor. The series and occurrence keep stable IDs.
        await _loadWorkspace(
          tester,
          active,
          DateTime.utc(2026, 9, 7),
          CalendarViewMode.day,
        );
        await _selectOccurrence(tester, early.reference);
        await _tapKey(tester, 'calendar-personal-edit-occurrence');
        await _fillEventEditor(
          tester,
          title: 'M42 weekly UI series',
          startDay: '2026-10-12',
          startTime: '15:00',
          endDay: '2026-10-12',
          endTime: '16:00',
        );
        await _tapKey(tester, 'calendar-event-save');
        await tester.pumpAndSettle();
        await _closeDetail(tester);

        final oldWeek = await _query(
          tester,
          active,
          DateTime.utc(2026, 9, 7),
          DateTime.utc(2026, 9, 14),
        );
        expect(
          oldWeek.items.where((item) => item.title == 'M42 weekly UI series'),
          isEmpty,
          reason: 'A moved exception must no longer project at its old date.',
        );
        window = await _query(
          tester,
          active,
          DateTime.utc(2026, 10, 12),
          DateTime.utc(2026, 10, 19),
        );
        var weeklyItems = window.items
            .where((item) => item.title == 'M42 weekly UI series')
            .toList();
        expect(
          weeklyItems.map((item) => item.reference.identity.ordinal),
          containsAll([0, 5]),
        );
        final exception = weeklyItems.singleWhere(
          (item) => item.reference.identity.ordinal == 0,
        );
        expect(exception.startsAtUtc, _beijingTime(2026, 10, 12, 15));

        // Edit the entire series from its in-range ordinal 5 occurrence. Moving
        // the series' first day and time must leave ordinal 0's absolute edit.
        final regularOccurrence = weeklyItems.singleWhere(
          (item) => item.reference.identity.ordinal == 5,
        );
        await _loadWorkspace(
          tester,
          active,
          DateTime.utc(2026, 10, 12),
          CalendarViewMode.day,
        );
        final currentWindow = await _query(
          tester,
          active,
          DateTime.utc(2026, 10, 12),
          DateTime.utc(2026, 10, 13),
        );
        final currentRegular = currentWindow.items.singleWhere(
          (item) =>
              item.title == 'M42 weekly UI series' &&
              item.reference.identity.ordinal == 5,
        );
        expect(currentRegular.reference, regularOccurrence.reference);
        await _selectOccurrence(tester, currentRegular.reference);
        await _tapKey(tester, 'calendar-personal-edit-series');
        await _fillEventEditor(
          tester,
          title: 'M42 weekly UI series',
          startDay: '2026-09-08',
          startTime: '10:00',
          endDay: '2026-09-08',
          endTime: '11:00',
          weekly: true,
          untilDay: '2026-10-26',
        );
        await _tapKey(tester, 'calendar-event-save');
        await tester.pumpAndSettle();
        await _closeDetail(tester);

        window = await _query(
          tester,
          active,
          DateTime.utc(2026, 10, 12),
          DateTime.utc(2026, 10, 19),
        );
        weeklyItems = window.items
            .where((item) => item.title == 'M42 weekly UI series')
            .toList();
        expect(weeklyItems, hasLength(2));
        final preservedException = weeklyItems.singleWhere(
          (item) => item.reference.identity.ordinal == 0,
        );
        final shiftedRegular = weeklyItems.singleWhere(
          (item) => item.reference.identity.ordinal == 5,
        );
        expect(preservedException.startsAtUtc, _beijingTime(2026, 10, 12, 15));
        expect(shiftedRegular.startsAtUtc, _beijingTime(2026, 10, 13, 10));

        // The event's old clock time has passed, yet it remains unfinished
        // until the user confirms completion in its detail view.
        final latestSingle = _oneItem(window, 'M42 one-time UI event');
        await _loadWorkspace(
          tester,
          active,
          DateTime.utc(2026, 10, 12),
          CalendarViewMode.day,
        );
        final singleWindow = await _query(
          tester,
          active,
          DateTime.utc(2026, 10, 12),
          DateTime.utc(2026, 10, 13),
        );
        single = _oneItem(singleWindow, 'M42 one-time UI event');
        expect(single.completed, isFalse);
        expect(latestSingle.reference.identity, single.reference.identity);
        await _selectOccurrence(tester, single.reference);
        await _tapKey(tester, 'calendar-personal-toggle-completed');
        await tester.pumpAndSettle();
        await _closeDetail(tester);
        final completed = _oneItem(
          await _query(
            tester,
            active,
            DateTime.utc(2026, 10, 12),
            DateTime.utc(2026, 10, 13),
          ),
          'M42 one-time UI event',
        );
        expect(completed.completed, isTrue);
        expect(completed.reference.version, single.reference.version + 1);
        await expectLater(
          _runNative(
            tester,
            () => active!.jwStore.localCalendar
                .prepare(
                  single.reference.context,
                  UpdatePersonalOccurrence(
                    single.reference,
                    PersonalEventDraft(
                      title: single.title,
                      start: single.startsAtUtc,
                      end: single.endsAtUtc,
                    ),
                  ),
                )
                .then(active.jwStore.localCalendar.commit),
          ),
          throwsA(
            isA<CalendarFailure>().having(
              (failure) => failure.code,
              'code',
              CalendarFailureCode.staleReference,
            ),
          ),
        );

        // Exercise skip, restore, cutoff changes and the weekly/single switch.
        // The final skipped choice must survive temporarily inactive ranges.
        final beforeSkip = _oneWeekly(
          await _query(
            tester,
            active,
            DateTime.utc(2026, 10, 12),
            DateTime.utc(2026, 10, 19),
          ),
          5,
        );
        await _loadWorkspace(
          tester,
          active,
          DateTime.utc(2026, 10, 13),
          CalendarViewMode.day,
        );
        await _selectOccurrence(tester, beforeSkip.reference);
        await _tapKey(tester, 'calendar-personal-toggle-skipped');
        await tester.pumpAndSettle();
        await _closeDetail(tester);
        var skippedWindow = await _query(
          tester,
          active,
          DateTime.utc(2026, 10, 13),
          DateTime.utc(2026, 10, 14),
        );
        expect(
          skippedWindow.items.where(
            (item) => item.title == 'M42 weekly UI series',
          ),
          isEmpty,
        );
        skippedWindow = await _query(
          tester,
          active,
          DateTime.utc(2026, 10, 13),
          DateTime.utc(2026, 10, 14),
          includeSkipped: true,
        );
        var skipped = _oneItem(skippedWindow, 'M42 weekly UI series');
        expect(skipped.skipped, isTrue);
        expect(skipped.reference.version, beforeSkip.reference.version + 1);

        await _loadWorkspace(
          tester,
          active,
          DateTime.utc(2026, 10, 13),
          CalendarViewMode.day,
          includeInactive: true,
        );
        await _selectOccurrence(tester, skipped.reference);
        await _tapKey(tester, 'calendar-personal-toggle-skipped');
        await tester.pumpAndSettle();
        await _closeDetail(tester);
        final restored = _oneWeekly(
          await _query(
            tester,
            active,
            DateTime.utc(2026, 10, 13),
            DateTime.utc(2026, 10, 14),
          ),
          5,
        );
        expect(restored.skipped, isFalse);
        expect(restored.reference.version, skipped.reference.version + 1);

        var seriesDetail = await _runNative(
          tester,
          () => active!.jwStore.localCalendar.detail(restored.reference),
        );
        var seriesDraft = seriesDetail.personalDraft!;
        final context = restored.reference.context;

        // Keep a skipped decision, then make its ordinal temporarily fall past
        // the inclusive deadline and temporarily turn the series into a single.
        await _commit(
          tester,
          active,
          context,
          SetPersonalOccurrenceState(restored.reference, skipped: true),
        );
        var seriesWindow = await _query(
          tester,
          active,
          DateTime.utc(2026, 10, 12),
          DateTime.utc(2026, 10, 19),
          includeSkipped: true,
        );
        var seriesTarget = _oneWeekly(seriesWindow, 0).reference;
        seriesDetail = await _runNative(
          tester,
          () => active!.jwStore.localCalendar.detail(seriesTarget),
        );
        seriesDraft = seriesDetail.personalDraft!;
        await _commit(
          tester,
          active,
          context,
          UpdatePersonalSeries(
            seriesTarget,
            _withSeries(
              seriesDraft,
              weekly: true,
              untilDay: DateTime.utc(2026, 10, 6),
            ),
          ),
        );
        seriesWindow = await _query(
          tester,
          active,
          DateTime.utc(2026, 10, 12),
          DateTime.utc(2026, 10, 19),
          includeSkipped: true,
        );
        expect(
          seriesWindow.items.where(
            (item) =>
                item.title == 'M42 weekly UI series' &&
                item.reference.identity.ordinal == 5,
          ),
          isEmpty,
        );
        expect(
          _oneWeekly(seriesWindow, 0).startsAtUtc,
          _beijingTime(2026, 10, 12, 15),
        );

        seriesTarget = _oneWeekly(seriesWindow, 0).reference;
        seriesDetail = await _runNative(
          tester,
          () => active!.jwStore.localCalendar.detail(seriesTarget),
        );
        await _commit(
          tester,
          active,
          context,
          UpdatePersonalSeries(
            seriesTarget,
            _withSeries(
              seriesDetail.personalDraft!,
              weekly: true,
              untilDay: DateTime.utc(2026, 10, 26),
            ),
          ),
        );
        seriesWindow = await _query(
          tester,
          active,
          DateTime.utc(2026, 10, 12),
          DateTime.utc(2026, 10, 19),
          includeSkipped: true,
        );
        expect(_oneWeekly(seriesWindow, 5).skipped, isTrue);

        seriesTarget = _oneWeekly(seriesWindow, 0).reference;
        seriesDetail = await _runNative(
          tester,
          () => active!.jwStore.localCalendar.detail(seriesTarget),
        );
        await _commit(
          tester,
          active,
          context,
          UpdatePersonalSeries(
            seriesTarget,
            _withSeries(
              seriesDetail.personalDraft!,
              weekly: false,
              untilDay: null,
            ),
          ),
        );
        seriesWindow = await _query(
          tester,
          active,
          DateTime.utc(2026, 10, 12),
          DateTime.utc(2026, 10, 19),
          includeSkipped: true,
        );
        expect(
          seriesWindow.items.where(
            (item) => item.title == 'M42 weekly UI series',
          ),
          hasLength(1),
        );
        expect(
          _oneWeekly(seriesWindow, 0).startsAtUtc,
          _beijingTime(2026, 10, 12, 15),
        );

        // Editing a retained replacement after switching to single must
        // update the displayed occurrence, rather than just its base draft.
        var retained = _oneWeekly(seriesWindow, 0);
        final retainedDetail = await _runNative(
          tester,
          () => active!.jwStore.localCalendar.detail(retained.reference),
        );
        expect(retainedDetail.personalDraft!.weekly, isFalse);
        expect(retainedDetail.hasOccurrenceReplacement, isTrue);
        await _loadWorkspace(
          tester,
          active,
          DateTime.utc(2026, 10, 12),
          CalendarViewMode.day,
        );
        await _selectOccurrence(tester, retained.reference);
        await _tapKey(tester, 'calendar-personal-edit-occurrence');
        await _fillEventEditor(
          tester,
          title: 'M42 retained replacement adjusted',
          startDay: '2026-10-12',
          startTime: '15:30',
          endDay: '2026-10-12',
          endTime: '16:30',
        );
        await _tapKey(tester, 'calendar-event-save');
        await _closeDetail(tester);
        final editedWindow = await _query(
          tester,
          active,
          DateTime.utc(2026, 10, 12),
          DateTime.utc(2026, 10, 13),
        );
        retained = _oneItem(editedWindow, 'M42 retained replacement adjusted');
        expect(retained.startsAtUtc, _beijingTime(2026, 10, 12, 15, 30));
        expect(retained.reference.identity.ordinal, 0);
        await _selectOccurrence(tester, retained.reference);
        await _tapKey(tester, 'calendar-personal-edit-occurrence');
        await _fillEventEditor(
          tester,
          title: 'M42 weekly UI series',
          startDay: '2026-10-12',
          startTime: '15:00',
          endDay: '2026-10-12',
          endTime: '16:00',
        );
        await _tapKey(tester, 'calendar-event-save');
        await _closeDetail(tester);
        seriesWindow = await _query(
          tester,
          active,
          DateTime.utc(2026, 10, 12),
          DateTime.utc(2026, 10, 19),
          includeSkipped: true,
        );

        seriesTarget = _oneWeekly(seriesWindow, 0).reference;
        seriesDetail = await _runNative(
          tester,
          () => active!.jwStore.localCalendar.detail(seriesTarget),
        );
        await _commit(
          tester,
          active,
          context,
          UpdatePersonalSeries(
            seriesTarget,
            _withSeries(
              seriesDetail.personalDraft!,
              weekly: true,
              untilDay: DateTime.utc(2026, 10, 26),
            ),
          ),
        );
        seriesWindow = await _query(
          tester,
          active,
          DateTime.utc(2026, 10, 12),
          DateTime.utc(2026, 10, 19),
          includeSkipped: true,
        );
        expect(
          _oneWeekly(seriesWindow, 0).startsAtUtc,
          _beijingTime(2026, 10, 12, 15),
        );
        expect(_oneWeekly(seriesWindow, 5).skipped, isTrue);

        // Replaying one operation returns its receipt without another audit;
        // changing that operation's intent is rejected.
        final replayContext = seriesWindow.context;
        final auditBefore = await _auditCount(tester, active);
        final replayIntent = CreatePersonalEvent(
          PersonalEventDraft(
            title: 'M42 idempotent command',
            start: _beijingTime(2026, 10, 12, 17),
            end: _beijingTime(2026, 10, 12, 18),
          ),
        );
        final command = await _runNative(
          tester,
          () => active!.jwStore.localCalendar.prepare(
            replayContext,
            replayIntent,
          ),
        );
        final firstReceipt = await _runNative(
          tester,
          () => active!.jwStore.localCalendar.commit(command),
        );
        final replayedReceipt = await _runNative(
          tester,
          () => active!.jwStore.localCalendar.commit(command),
        );
        expect(firstReceipt.replayed, isFalse);
        expect(replayedReceipt.replayed, isTrue);
        expect(replayedReceipt.revision, firstReceipt.revision);
        expect(await _auditCount(tester, active), auditBefore + 1);
        final changedCommand = CalendarCommand(
          command.operationId,
          command.context,
          CreatePersonalEvent(
            PersonalEventDraft(
              title: 'M42 changed idempotent intent',
              start: _beijingTime(2026, 10, 12, 19),
              end: _beijingTime(2026, 10, 12, 20),
            ),
          ),
        );
        await expectLater(
          _runNative(
            tester,
            () => active!.jwStore.localCalendar.commit(changedCommand),
          ),
          throwsA(
            isA<CalendarFailure>().having(
              (failure) => failure.code,
              'code',
              CalendarFailureCode.idempotencyConflict,
            ),
          ),
        );
        expect(await _auditCount(tester, active), auditBefore + 1);

        // A command prepared under the old agenda epoch stays stale after a
        // maintenance barrier completes. The barrier changes no event facts.
        final staleContextCommand = await _runNative(
          tester,
          () => active!.jwStore.localCalendar.prepare(
            replayContext,
            CreatePersonalEvent(
              PersonalEventDraft(
                title: 'M42 stale context must not write',
                start: _beijingTime(2026, 10, 12, 20),
                end: _beijingTime(2026, 10, 12, 21),
              ),
            ),
          ),
        );
        final maintenanceContext = await _runNative(
          tester,
          active.jwStore.localCalendar.beginMaintenance,
        );
        await _runNative(
          tester,
          () => active!.jwStore.localCalendar.finishMaintenance(
            maintenanceContext,
          ),
        );
        await expectLater(
          _runNative(
            tester,
            () => active!.jwStore.localCalendar.commit(staleContextCommand),
          ),
          throwsA(
            isA<CalendarFailure>().having(
              (failure) => failure.code,
              'code',
              CalendarFailureCode.staleReference,
            ),
          ),
        );
        expect(await _auditCount(tester, active), auditBefore + 1);
        await _loadWorkspace(
          tester,
          active,
          DateTime.utc(2026, 10, 12),
          CalendarViewMode.day,
        );
        final persistedBeforeClose = await _query(
          tester,
          active,
          DateTime.utc(2026, 10, 12),
          DateTime.utc(2026, 10, 19),
          includeSkipped: true,
        );
        expect(
          _oneItem(persistedBeforeClose, 'M42 idempotent command').title,
          'M42 idempotent command',
        );
        expect(
          persistedBeforeClose.items.where(
            (item) => item.title == 'M42 stale context must not write',
          ),
          isEmpty,
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await _closeRuntime(tester, active);
        active = null;

        active = await _openRuntime(tester, workspace);
        runtimes.add(active);
        expect(active.directory.isHeld, isTrue);
        expect(active.jwDirectory.isHeld, isTrue);
        expect(
          (await _runNative(tester, active.jwStore.readAuthority)).accountBound,
          isFalse,
        );
        await tester.pumpWidget(_productApp(active));
        await tester.pumpAndSettle();
        await _tapKey(tester, 'shell-nav-agenda');
        final afterReopen = await _query(
          tester,
          active,
          DateTime.utc(2026, 10, 12),
          DateTime.utc(2026, 10, 19),
          includeSkipped: true,
        );
        expect(
          _oneItem(afterReopen, 'M42 one-time UI event').completed,
          isTrue,
        );
        expect(
          _oneItem(afterReopen, 'M42 one-time UI event').note,
          'single event note',
        );
        expect(_oneItem(afterReopen, 'M42 all-day span').allDay, isTrue);
        await _captureSyntheticUi(tester, 'personal');
        expect(
          _oneItem(afterReopen, 'M42 all-day span').endsAtUtc,
          DateTime.utc(2026, 10, 14, 16),
        );
        expect(
          _oneItem(afterReopen, 'M42 idempotent command').title,
          'M42 idempotent command',
        );
        expect(
          _oneWeekly(afterReopen, 0).startsAtUtc,
          _beijingTime(2026, 10, 12, 15),
        );
        expect(_oneWeekly(afterReopen, 5).skipped, isTrue);
        expect(
          (await _runNative(tester, active.jwStore.readCommittedPermits)),
          isEmpty,
          reason: 'The local calendar flow must not create a school partition.',
        );
      } finally {
        await _disposeAndClean(tester, workspace, runtimes);
      }
    },
  );

  testWidgets(
    'synthetic missing school records keep independent overlays and relations across native reopen',
    (tester) async {
      final workspace = await _createWorkspace();
      final runtimes = <DemoRuntime>[];
      DemoRuntime? active;
      try {
        active = await _openRuntime(tester, workspace);
        runtimes.add(active);
        expect(
          (await _runNative(tester, active.jwStore.readAuthority)).accountBound,
          isFalse,
        );
        await tester.pumpWidget(_productApp(active));
        await tester.pumpAndSettle();
        await _tapKey(tester, 'shell-nav-agenda');

        // This is explicit synthetic data inserted only into this test's
        // nonce TEMP database. No source coordinator or school endpoint runs.
        await _seedSyntheticMissingSources(tester, active);
        await _loadWorkspace(
          tester,
          active,
          DateTime.utc(2026, 10, 12),
          CalendarViewMode.day,
        );
        var window = await _query(
          tester,
          active,
          DateTime.utc(2026, 10, 12),
          DateTime.utc(2026, 10, 13),
        );
        var course = _oneItem(window, 'M42 synthetic course');
        var young = _oneItem(window, 'M42 synthetic Young activity');
        expect(course.presence, AgendaPresence.missingWithinScope);
        expect(young.presence, AgendaPresence.missingWithinScope);
        expect(
          course.reference.identity.localId,
          young.reference.identity.localId,
        );
        expect(course.reference.identity.kind, CalendarKind.course);
        expect(young.reference.identity.kind, CalendarKind.young);
        expect(course.hidden, isFalse);
        expect(young.hidden, isFalse);
        await _captureSyntheticUi(tester, 'day');

        // Save a relation through the conflict detail UI. Same numeric IDs
        // remain separate because relation identities include their source kind.
        await _selectOccurrence(tester, course.reference);
        expect(find.text('来源当前缺少这条记录，本地日程仍予以保留。'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('calendar-relation-edit-young-0')),
          200,
          scrollable: find.descendant(
            of: find.byKey(const ValueKey('calendar-detail-content')),
            matching: find.byType(Scrollable),
          ),
        );
        await tester.pumpAndSettle();
        await _tapKey(tester, 'calendar-relation-edit-young-0');
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('calendar-relation-kind')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('冲突').last);
        await tester.pumpAndSettle();
        await _enterText(tester, 'calendar-relation-note', '同一时段，共存说明');
        await _tapKey(tester, 'calendar-relation-save');
        await tester.pumpAndSettle();
        await _closeDetail(tester);

        window = await _query(
          tester,
          active,
          DateTime.utc(2026, 10, 12),
          DateTime.utc(2026, 10, 13),
        );
        course = _oneItem(window, 'M42 synthetic course');
        young = _oneItem(window, 'M42 synthetic Young activity');
        var courseDetail = await _runNative(
          tester,
          () => active!.jwStore.localCalendar.detail(course.reference),
        );
        expect(courseDetail.relations, hasLength(1));
        final relation = courseDetail.relations.single;
        expect(relation.kind, CalendarRelationKind.conflict);
        expect(relation.reference.version, 1);
        expect(relation.note, '同一时段，共存说明');
        expect(
          {relation.left.kind, relation.right.kind},
          {CalendarKind.course, CalendarKind.young},
        );
        expect(relation.left.localId, relation.right.localId);
        expect(
          window.conflicts.any(
            (candidate) =>
                candidate.relation?.reference.localId ==
                relation.reference.localId,
          ),
          isTrue,
        );

        // The school detail editor changes only the local overlay. Source
        // absence, attendance, listening and note remain independent facts.
        await _selectOccurrence(tester, course.reference);
        await _captureSyntheticUi(tester, 'source-details');
        await _tapKey(tester, 'calendar-school-edit-annotation');
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('calendar-school-attendance')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('计划参加').last);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('calendar-school-listening')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('自主学习').last);
        await tester.pumpAndSettle();
        await _enterText(tester, 'calendar-school-note', 'M42 合成用户备注');
        await _tapKey(tester, 'calendar-school-save');
        await tester.pumpAndSettle();
        await _closeDetail(tester);

        window = await _query(
          tester,
          active,
          DateTime.utc(2026, 10, 12),
          DateTime.utc(2026, 10, 13),
        );
        course = _oneItem(window, 'M42 synthetic course');
        expect(course.presence, AgendaPresence.missingWithinScope);
        expect(course.note, 'M42 合成用户备注');
        expect(course.attendance, AttendanceDecision.attend);
        expect(course.listening, ListeningMode.selfStudy);
        expect(course.reference.version, 2);
        expect(
          active.calendar.view.window!.items
              .singleWhere(
                (item) => item.reference.identity == course.reference.identity,
              )
              .reference
              .version,
          2,
        );
        expect(_oneItem(window, 'M42 synthetic Young activity').note, isEmpty);

        await _selectOccurrence(tester, course.reference);
        await _tapKey(tester, 'calendar-school-toggle-hidden');
        await tester.pumpAndSettle();
        await _closeDetail(tester);
        final hiddenWindow = await _query(
          tester,
          active,
          DateTime.utc(2026, 10, 12),
          DateTime.utc(2026, 10, 13),
          includeHidden: true,
        );
        final hiddenCourse = _oneItem(hiddenWindow, 'M42 synthetic course');
        expect(hiddenCourse.hidden, isTrue);
        expect(hiddenCourse.reference.version, 3);
        expect(hiddenCourse.presence, AgendaPresence.missingWithinScope);

        await _loadWorkspace(
          tester,
          active,
          DateTime.utc(2026, 10, 12),
          CalendarViewMode.day,
          includeInactive: true,
        );
        await _selectOccurrence(tester, hiddenCourse.reference);
        await _tapKey(tester, 'calendar-school-toggle-hidden');
        await tester.pumpAndSettle();
        await _closeDetail(tester);
        window = await _query(
          tester,
          active,
          DateTime.utc(2026, 10, 12),
          DateTime.utc(2026, 10, 13),
          includeHidden: true,
        );
        course = _oneItem(window, 'M42 synthetic course');
        expect(course.hidden, isFalse);
        expect(course.reference.version, 4);
        expect(course.presence, AgendaPresence.missingWithinScope);
        expect(course.note, 'M42 合成用户备注');
        expect(course.attendance, AttendanceDecision.attend);
        expect(course.listening, ListeningMode.selfStudy);
        expect(
          _oneItem(window, 'M42 synthetic Young activity').hidden,
          isFalse,
        );
        courseDetail = await _runNative(
          tester,
          () => active!.jwStore.localCalendar.detail(course.reference),
        );
        expect(courseDetail.relations.single.note, '同一时段，共存说明');

        expect(
          (await _runNative(tester, active.jwStore.readCommittedPermits)),
          isEmpty,
        );
        expect(
          (await _runNative(tester, active.jwStore.readView)).credentialSaved,
          isFalse,
        );
        expect(
          (await _runNative(
            tester,
            active.jwStore.readYoungView,
          )).credentialSaved,
          isFalse,
        );
        expect(
          (await _runNative(tester, active.jwStore.readView)).importCount,
          0,
        );
        expect(
          (await _runNative(tester, active.jwStore.readYoungView)).importCount,
          0,
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await _closeRuntime(tester, active);
        active = null;

        active = await _openRuntime(tester, workspace);
        runtimes.add(active);
        expect(active.directory.isHeld, isTrue);
        expect(active.jwDirectory.isHeld, isTrue);
        await tester.pumpWidget(_productApp(active));
        await tester.pumpAndSettle();
        await _tapKey(tester, 'shell-nav-agenda');
        window = await _query(
          tester,
          active,
          DateTime.utc(2026, 10, 12),
          DateTime.utc(2026, 10, 13),
          includeHidden: true,
        );
        course = _oneItem(window, 'M42 synthetic course');
        young = _oneItem(window, 'M42 synthetic Young activity');
        expect(course.presence, AgendaPresence.missingWithinScope);
        expect(course.hidden, isFalse);
        expect(course.reference.version, 4);
        expect(course.note, 'M42 合成用户备注');
        expect(course.attendance, AttendanceDecision.attend);
        expect(course.listening, ListeningMode.selfStudy);
        expect(young.presence, AgendaPresence.missingWithinScope);
        expect(young.hidden, isFalse);
        courseDetail = await _runNative(
          tester,
          () => active!.jwStore.localCalendar.detail(course.reference),
        );
        expect(courseDetail.relations, hasLength(1));
        expect(courseDetail.relations.single.reference.version, 1);
        expect(courseDetail.relations.single.note, '同一时段，共存说明');
        expect(
          (await _runNative(tester, active.jwStore.readCommittedPermits)),
          isEmpty,
        );
        expect(
          (await _runNative(tester, active.jwStore.readView)).credentialSaved,
          isFalse,
        );
        expect(
          (await _runNative(
            tester,
            active.jwStore.readYoungView,
          )).credentialSaved,
          isFalse,
        );
      } finally {
        await _disposeAndClean(tester, workspace, runtimes);
      }
    },
  );
  testWidgets(
    'native teaching overview renders dense named events and default conflicts without saving decisions',
    (tester) async {
      final workspace = await _createWorkspace();
      final runtimes = <DemoRuntime>[];
      try {
        final runtime = await _openRuntime(tester, workspace);
        runtimes.add(runtime);
        final drafts = <PersonalEventDraft>[
          for (final period in ustcTeachingPeriods)
            PersonalEventDraft(
              title: '教学节次演示 ${period.number}',
              start: _beijingTime(
                2026,
                10,
                12,
                period.startMinute ~/ 60,
                period.startMinute % 60,
              ),
              end: _beijingTime(
                2026,
                10,
                12,
                period.endMinute ~/ 60,
                period.endMinute % 60,
              ),
            ),
          for (final day in [13, 15])
            PersonalEventDraft(
              title: '数学分析与线性代数',
              start: _beijingTime(2026, 10, day, 7, 50),
              end: _beijingTime(2026, 10, day, 9, 25),
              location: '合成教室',
            ),
          PersonalEventDraft(
            title: '重叠的课程讨论',
            start: _beijingTime(2026, 10, 13, 8, 40),
            end: _beijingTime(2026, 10, 13, 9, 25),
          ),
          for (var index = 0; index < 3; index++) ...[
            PersonalEventDraft(
              title: '全天安排 ${index + 1}',
              start: DateTime.utc(2026, 10, 14),
              end: DateTime.utc(2026, 10, 15),
              allDay: true,
            ),
            PersonalEventDraft(
              title: '凌晨安排 ${index + 1}',
              start: _beijingTime(2026, 10, 16, 1 + index),
              end: _beijingTime(2026, 10, 16, 1 + index, 30),
            ),
          ],
        ];
        for (final draft in drafts) {
          final before = await _query(
            tester,
            runtime,
            DateTime.utc(2026, 10, 12),
            DateTime.utc(2026, 10, 19),
          );
          await _commit(
            tester,
            runtime,
            before.context,
            CreatePersonalEvent(draft),
          );
        }
        await tester.pumpWidget(_productApp(runtime));
        await tester.pumpAndSettle();
        await _tapKey(tester, 'shell-nav-agenda');
        await _loadWorkspace(
          tester,
          runtime,
          DateTime.utc(2026, 10, 12),
          CalendarViewMode.week,
        );
        final window = runtime.calendar.view.window!;
        expect(window.items, hasLength(22));
        expect(window.conflicts, hasLength(1));
        expect(window.conflicts.single.status, CalendarConflictStatus.conflict);
        expect(window.conflicts.single.hasExplicitDecision, isFalse);
        expect(find.byIcon(Icons.error_outline_rounded), findsNWidgets(2));
        expect(find.text('合成教室'), findsNWidgets(2));
        final storedDecisions = await _runNative(
          tester,
          () async =>
              (await runtime.jwStore
                      .customSelect(
                        'SELECT COUNT(*) AS count FROM agenda_relations',
                      )
                      .getSingle())
                  .read<int>('count'),
        );
        expect(storedDecisions, 0);
        final period = find.byKey(const ValueKey('calendar-week-period-13'));
        expect(period, findsOneWidget);
        final viewport = tester.getRect(
          find.byKey(const ValueKey('calendar-week-time-scroll')),
        );
        final lastPeriod = tester.getRect(period);
        // If the OS gives the native test a shorter window, bounded scrolling
        // is allowed; a normal desktop canvas must fit all teaching periods.
        final desktopSize = tester.getSize(
          find.byKey(const ValueKey('m42-synthetic-capture')),
        );
        if (desktopSize.width >= 1100 && desktopSize.height >= 680) {
          expect(
            viewport.height,
            greaterThanOrEqualTo(CalendarTeachingAxis.fit(0).height),
          );
          expect(lastPeriod.bottom, lessThanOrEqualTo(viewport.bottom + 1));
          expect(
            tester
                .state<ScrollableState>(
                  find.descendant(
                    of: find.byKey(const ValueKey('calendar-week-time-scroll')),
                    matching: find.byType(Scrollable),
                  ),
                )
                .position
                .maxScrollExtent,
            lessThanOrEqualTo(1),
          );
        }
        await _captureSyntheticUi(tester, 'teaching-overview');
        await _tapKey(tester, 'calendar-week-overflow-all-day-2026-10-14');
        final allDay = _oneItem(window, '全天安排 3');
        await _tapKey(
          tester,
          'calendar-overflow-item-personal-${allDay.reference.identity.localId}-0',
        );
        expect(runtime.calendar.view.detail!.occurrence.allDay, isTrue);
        expect(
          find.byKey(const ValueKey('calendar-relation-save')),
          findsNothing,
        );
      } finally {
        await _disposeAndClean(tester, workspace, runtimes);
      }
    },
  );
}

Widget _productApp(DemoRuntime runtime) => RepaintBoundary(
  key: const ValueKey('m42-synthetic-capture'),
  child: ProductApp(
    controller: runtime.shell,
    settingsBuilder: (_) => const SizedBox.shrink(),
    agendaBuilder: (_) => CalendarWorkspacePage(controller: runtime.calendar),
  ),
);

Future<void> _captureSyntheticUi(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('USTC_M4_QA')) return;
  const destination = String.fromEnvironment('USTC_M4_QA_DIR');
  if (destination.isEmpty || !p.windows.isAbsolute(destination)) {
    throw StateError(
      'A dedicated absolute synthetic QA directory is required.',
    );
  }
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('m42-synthetic-capture')),
  );
  final picture = await boundary.toImage(pixelRatio: 1);
  try {
    final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) throw StateError('Empty synthetic UI capture');
    await tester.runAsync(() async {
      await Directory(destination).create(recursive: true);
      await File(
        p.windows.join(destination, '$name.png'),
      ).writeAsBytes(bytes.buffer.asUint8List());
    });
  } finally {
    picture.dispose();
  }
}

Future<DemoRuntime> _openRuntime(
  WidgetTester tester,
  _TempWorkspace workspace,
) => _runNative(
  tester,
  () => DemoRuntime.open(
    directoryPath: workspace.demoPath,
    jwDirectoryPath: workspace.formalPath,
    clock: FixedClock(DateTime.utc(2026, 10, 12, 4)),
  ),
);

Future<void> _closeRuntime(WidgetTester tester, DemoRuntime runtime) async {
  await _runNative(tester, runtime.close);
  expect(runtime.directory.isHeld, isFalse);
  expect(runtime.jwDirectory.isHeld, isFalse);
}

Future<T> _runNative<T>(
  WidgetTester tester,
  Future<T> Function() action,
) async {
  late T result;
  Object? failure;
  StackTrace? failureStack;
  await tester.runAsync(() async {
    try {
      result = await action();
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    }
  });
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  return result;
}

Future<void> _selectViewMode(WidgetTester tester, CalendarViewMode mode) async {
  final label = mode == CalendarViewMode.day ? '日' : '周';
  final finder = find.descendant(
    of: find.byKey(const ValueKey('calendar-workspace-view-mode')),
    matching: find.text(label),
  );
  expect(finder, findsOneWidget);
  await tester.tap(finder);
  await tester.pumpAndSettle();
  final selector = tester.widget<SegmentedButton<CalendarViewMode>>(
    find.byKey(const ValueKey('calendar-workspace-view-mode')),
  );
  expect(selector.selected, hasLength(1));
  expect(selector.selected, contains(mode));
}

Future<void> _createEvent(
  WidgetTester tester, {
  required String title,
  required String startDay,
  String? startTime,
  required String endDay,
  String? endTime,
  bool allDay = false,
  bool weekly = false,
  String? untilDay,
  String note = '',
}) async {
  await _tapKey(tester, 'calendar-personal-create');
  await _fillEventEditor(
    tester,
    title: title,
    startDay: startDay,
    startTime: startTime,
    endDay: endDay,
    endTime: endTime,
    allDay: allDay,
    weekly: weekly,
    untilDay: untilDay,
    note: note,
  );
  await _tapKey(tester, 'calendar-event-save');
  await tester.pumpAndSettle();
}

Future<void> _fillEventEditor(
  WidgetTester tester, {
  required String title,
  required String startDay,
  String? startTime,
  required String endDay,
  String? endTime,
  bool? allDay,
  bool? weekly,
  String? untilDay,
  String? note,
}) async {
  await _enterText(tester, 'calendar-event-title', title);
  if (allDay != null) {
    final key = const ValueKey<String>('calendar-event-all-day');
    final tile = tester.widget<SwitchListTile>(find.byKey(key));
    if (tile.value != allDay) {
      await _tapKey(tester, 'calendar-event-all-day');
    }
  }
  await _enterText(tester, 'calendar-event-start-date', startDay);
  if (startTime != null &&
      find
          .byKey(const ValueKey('calendar-event-start-time'))
          .evaluate()
          .isNotEmpty) {
    await _enterText(tester, 'calendar-event-start-time', startTime);
  }
  await _enterText(tester, 'calendar-event-end-date', endDay);
  if (endTime != null &&
      find
          .byKey(const ValueKey('calendar-event-end-time'))
          .evaluate()
          .isNotEmpty) {
    await _enterText(tester, 'calendar-event-end-time', endTime);
  }
  if (weekly != null) {
    final key = const ValueKey<String>('calendar-event-weekly');
    final tileFinder = find.byKey(key);
    if (tileFinder.evaluate().isNotEmpty) {
      final tile = tester.widget<SwitchListTile>(tileFinder);
      if (tile.value != weekly) {
        await _tapKey(tester, 'calendar-event-weekly');
      }
    }
  }
  if (untilDay != null &&
      find
          .byKey(const ValueKey('calendar-event-until'))
          .evaluate()
          .isNotEmpty) {
    await _enterText(tester, 'calendar-event-until', untilDay);
  }
  if (note != null &&
      find.byKey(const ValueKey('calendar-event-note')).evaluate().isNotEmpty) {
    await _enterText(tester, 'calendar-event-note', note);
  }
}

Future<void> _loadWorkspace(
  WidgetTester tester,
  DemoRuntime runtime,
  DateTime day,
  CalendarViewMode mode, {
  bool includeInactive = false,
}) async {
  await _runNative(
    tester,
    () => runtime.calendar.load(
      day: day,
      mode: mode,
      includeInactive: includeInactive,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _selectOccurrence(
  WidgetTester tester,
  CalendarReference reference,
) async {
  final finder = find.byKey(ValueKey<CalendarReference>(reference));
  expect(
    finder,
    findsOneWidget,
    reason: 'Missing C3-projected occurrence $reference.',
  );
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('calendar-detail-card')), findsOneWidget);
}

Future<void> _closeDetail(WidgetTester tester) async {
  final close = find.byKey(const ValueKey('calendar-detail-close'));
  if (close.evaluate().isEmpty) return;
  await tester.ensureVisible(close);
  await tester.pumpAndSettle();
  await tester.tap(close);
  await tester.pumpAndSettle();
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey<String>(key));
  expect(finder, findsOneWidget, reason: 'Missing UI key: $key');
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
  await tester.pumpAndSettle();
}

Future<void> _enterText(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(ValueKey<String>(key));
  expect(finder, findsOneWidget, reason: 'Missing input key: $key');
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.enterText(finder, value);
  await tester.pump();
}

Future<CalendarWindow> _query(
  WidgetTester tester,
  DemoRuntime runtime,
  DateTime firstDay,
  DateTime endDayExclusive, {
  bool includeHidden = false,
  bool includeSkipped = false,
}) => _runNative(
  tester,
  () => runtime.jwStore.localCalendar.query(
    CalendarQuery(
      firstDay: firstDay,
      endDayExclusive: endDayExclusive,
      includeHidden: includeHidden,
      includeSkipped: includeSkipped,
    ),
  ),
);

Future<CalendarWriteReceipt> _commit(
  WidgetTester tester,
  DemoRuntime runtime,
  CalendarContext context,
  CalendarIntent intent,
) => _runNative(tester, () async {
  final command = await runtime.jwStore.localCalendar.prepare(context, intent);
  return runtime.jwStore.localCalendar.commit(command);
});

CalendarOccurrence _oneItem(CalendarWindow window, String title) =>
    window.items.singleWhere((item) => item.title == title);

CalendarOccurrence _oneWeekly(CalendarWindow window, int ordinal) =>
    window.items.singleWhere(
      (item) =>
          item.title == 'M42 weekly UI series' &&
          item.reference.identity.ordinal == ordinal,
    );

DateTime _beijingTime(
  int year,
  int month,
  int day,
  int hour, [
  int minute = 0,
]) => DateTime.utc(
  year,
  month,
  day,
  hour,
  minute,
).subtract(const Duration(hours: 8));

PersonalEventDraft _withSeries(
  PersonalEventDraft original, {
  required bool weekly,
  required DateTime? untilDay,
}) => PersonalEventDraft(
  title: original.title,
  start: original.start,
  end: original.end,
  allDay: original.allDay,
  weekly: weekly,
  untilDay: weekly ? untilDay : null,
  location: original.location,
  note: original.note,
);

Future<int> _auditCount(WidgetTester tester, DemoRuntime runtime) => _runNative(
  tester,
  () async =>
      (await runtime.jwStore
              .customSelect('SELECT COUNT(*) AS count FROM agenda_audit')
              .getSingle())
          .read<int>('count'),
);

Future<void> _seedSyntheticMissingSources(
  WidgetTester tester,
  DemoRuntime runtime,
) => _runNative(tester, () async {
  final courseStart = _beijingTime(2026, 10, 12, 10).microsecondsSinceEpoch;
  final courseEnd = _beijingTime(2026, 10, 12, 11).microsecondsSinceEpoch;
  final youngStart = _beijingTime(2026, 10, 12, 10, 30).microsecondsSinceEpoch;
  final youngEnd = _beijingTime(2026, 10, 12, 11, 30).microsecondsSinceEpoch;
  await runtime.jwStore.transaction(() async {
    // The fake account code is a synthetic fixture value, not a saved login.
    await runtime.jwStore.customStatement(
      'INSERT INTO jw_account(account_id,expected_account_code) VALUES(1,?)',
      ['TEST0001'],
    );
    await runtime.jwStore.customStatement(
      'INSERT INTO jw_events(external_id,kind,semester_id,title,starts_at,ends_at,presence,version) '
      'VALUES(?,?,?,?,?,?,?,1)',
      [
        'm42-synthetic-jw-course',
        'course',
        20261,
        'M42 synthetic course',
        courseStart,
        courseEnd,
        'missingWithinScope',
      ],
    );
    await runtime.jwStore.customStatement(
      'INSERT INTO jw_overlays(local_id,hidden) '
      'SELECT local_id,0 FROM jw_events WHERE external_id=?',
      ['m42-synthetic-jw-course'],
    );
    await runtime.jwStore.customStatement(
      'INSERT INTO young_events(external_id,item_id,title,place,starts_at,ends_at,presence,version) '
      'VALUES(?,?,?,?,?,?,?,1)',
      [
        'm42-synthetic-young-event',
        'm42-young-item',
        'M42 synthetic Young activity',
        '合成活动室',
        youngStart,
        youngEnd,
        'missingWithinScope',
      ],
    );
    await runtime.jwStore.customStatement(
      'INSERT INTO young_overlays(local_id,hidden) '
      'SELECT local_id,0 FROM young_events WHERE external_id=?',
      ['m42-synthetic-young-event'],
    );
  });
});

final class _TempWorkspace {
  const _TempWorkspace({
    required this.root,
    required this.prefix,
    required this.nonce,
    required this.demoPath,
    required this.formalPath,
  });

  final Directory root;
  final String prefix;
  final String nonce;
  final String demoPath;
  final String formalPath;
}

Future<_TempWorkspace> _createWorkspace() async {
  const prefix = 'ustc_m42_calendar_';
  final root = await Directory.systemTemp.createTemp(prefix);
  final rootPath = _normal(root.path);
  final tempPath = _normal(await Directory.systemTemp.resolveSymbolicLinks());
  final name = p.windows.basename(rootPath);
  if (!p.windows.equals(p.windows.dirname(rootPath), tempPath) ||
      !name.startsWith(prefix) ||
      name.length == prefix.length ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(name.substring(prefix.length)) ||
      !p.windows.equals(rootPath, _normal(await root.resolveSymbolicLinks())) ||
      await FileSystemEntity.type(rootPath, followLinks: false) !=
          FileSystemEntityType.directory) {
    throw StateError('Refusing a TEMP root without a plain nonce directory.');
  }
  final nonce = _nonce();
  return _TempWorkspace(
    root: root,
    prefix: prefix,
    nonce: nonce,
    demoPath: p.windows.join(rootPath, 'demo-$nonce'),
    formalPath: p.windows.join(rootPath, 'formal-$nonce'),
  );
}

Future<void> _disposeAndClean(
  WidgetTester tester,
  _TempWorkspace workspace,
  List<DemoRuntime> runtimes,
) async {
  Object? firstError;
  StackTrace? firstStack;
  Future<void> attempt(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (error, stack) {
      firstError ??= error;
      firstStack ??= stack;
    }
  }

  await attempt(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  for (final runtime in runtimes.reversed) {
    await attempt(() => _closeRuntime(tester, runtime));
  }
  if (firstError != null) {
    Error.throwWithStackTrace(firstError!, firstStack!);
  }
  await _deleteOwnedWorkspace(workspace);
}

Future<void> _deleteOwnedWorkspace(_TempWorkspace workspace) async {
  final tempPath = _normal(await Directory.systemTemp.resolveSymbolicLinks());
  final rootPath = _normal(workspace.root.path);
  final name = p.windows.basename(rootPath);
  if (!p.windows.equals(p.windows.dirname(rootPath), tempPath) ||
      !name.startsWith(workspace.prefix) ||
      name.length == workspace.prefix.length ||
      !RegExp(
        r'^[A-Za-z0-9_-]+$',
      ).hasMatch(name.substring(workspace.prefix.length)) ||
      !p.windows.equals(
        rootPath,
        _normal(await workspace.root.resolveSymbolicLinks()),
      ) ||
      await FileSystemEntity.type(rootPath, followLinks: false) !=
          FileSystemEntityType.directory) {
    throw StateError('Refusing to remove a path outside the nonce TEMP root.');
  }
  final expectedDemo = _normal(workspace.demoPath);
  final expectedFormal = _normal(workspace.formalPath);
  if (!p.windows.equals(p.windows.dirname(expectedDemo), rootPath) ||
      !p.windows.equals(p.windows.dirname(expectedFormal), rootPath) ||
      p.windows.basename(expectedDemo) != 'demo-${workspace.nonce}' ||
      p.windows.basename(expectedFormal) != 'formal-${workspace.nonce}') {
    throw StateError('Refusing to remove an unrecognized TEMP child path.');
  }

  await _assertNoLinks(workspace.root, rootPath);
  final children = await workspace.root.list(followLinks: false).toList();
  for (final child in children) {
    final path = _normal(child.path);
    if (!p.windows.equals(path, expectedDemo) &&
        !p.windows.equals(path, expectedFormal)) {
      throw StateError('Refusing to remove an unknown TEMP child.');
    }
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('A known TEMP child is not a plain directory.');
    }
    if (!p.windows.equals(
      path,
      _normal(await Directory(path).resolveSymbolicLinks()),
    )) {
      throw StateError('A known TEMP child resolves outside its owned path.');
    }
    await _assertKnownDatabaseFiles(
      Directory(path),
      formal: p.windows.equals(path, expectedFormal),
    );
  }
  if (!p.windows.equals(
        rootPath,
        _normal(await workspace.root.resolveSymbolicLinks()),
      ) ||
      await FileSystemEntity.type(rootPath, followLinks: false) !=
          FileSystemEntityType.directory) {
    throw StateError('TEMP root changed during ownership validation.');
  }
  await _assertNoLinks(workspace.root, rootPath);
  await workspace.root.delete(recursive: true);
}

Future<void> _assertKnownDatabaseFiles(
  Directory directory, {
  required bool formal,
}) async {
  final name = p.windows.basename(_normal(directory.path));
  final expectedBase = name.startsWith('demo-')
      ? 'm0_demo.sqlite'
      : 'jw.sqlite';
  final allowed = {
    expectedBase,
    '$expectedBase-wal',
    '$expectedBase-shm',
    '$expectedBase-journal',
  };
  final emptyRoots = formal
      ? {'jw_partitions_v1', 'young_partitions_v1'}
      : {'observation_v1', 'young_observation_v1'};
  await for (final entry in directory.list(followLinks: false)) {
    final entryPath = _normal(entry.path);
    final entryName = p.windows.basename(entryPath);
    final type = await FileSystemEntity.type(entryPath, followLinks: false);
    if (allowed.contains(entryName) && type == FileSystemEntityType.file) {
      continue;
    }
    if (emptyRoots.contains(entryName) &&
        type == FileSystemEntityType.directory) {
      final partitionRoot = Directory(entryPath);
      final entries = await partitionRoot
          .list(followLinks: false)
          .take(1)
          .toList();
      if (!p.windows.equals(
            entryPath,
            _normal(await partitionRoot.resolveSymbolicLinks()),
          ) ||
          entries.isNotEmpty) {
        throw StateError(
          'Refusing to remove a populated or linked source root.',
        );
      }
      continue;
    }
    if (!allowed.contains(entryName) || type != FileSystemEntityType.file) {
      throw StateError('Refusing to remove an unknown native database entry.');
    }
  }
}

Future<void> _assertNoLinks(Directory root, String rootPath) async {
  final pending = <Directory>[root];
  while (pending.isNotEmpty) {
    final directory = pending.removeLast();
    await for (final entity in directory.list(followLinks: false)) {
      final path = _normal(entity.path);
      if (!p.windows.isWithin(rootPath, path)) {
        throw StateError('Refusing to remove an entry outside TEMP ownership.');
      }
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.link ||
          type == FileSystemEntityType.notFound) {
        throw StateError('Refusing to remove a link or changing TEMP entry.');
      }
      if (type == FileSystemEntityType.directory) {
        pending.add(Directory(path));
      } else if (type != FileSystemEntityType.file) {
        throw StateError('Refusing to remove an unknown TEMP entry type.');
      }
    }
  }
}

String _normal(String path) => p.windows.normalize(p.windows.absolute(path));

String _nonce() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();
