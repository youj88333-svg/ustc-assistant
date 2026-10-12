import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/app/app_shell_contract.dart';
import 'package:ustc_assistant_m0/app/app_shell_controller.dart';
import 'package:ustc_assistant_m0/app/product_app.dart';
import 'package:ustc_assistant_m0/app/source_settings_page.dart';
import 'package:ustc_assistant_m0/core/agenda_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/data/jw_import_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/jobs/jw_sync_coordinator.dart';
import 'package:ustc_assistant_m0/jobs/jw_sync_port.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_coordinator.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_port.dart';
import 'package:ustc_assistant_m0/platform/demo_directory.dart';
import 'package:ustc_assistant_m0/platform/jw_partition_registry.dart';
import 'package:ustc_assistant_m0/platform/native_database.dart';
import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';
import 'package:ustc_assistant_m0/platform/windows_jw_credential_protector.dart';
import 'package:ustc_assistant_m0/platform/young_partition_registry.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';

import 'support/jw_sync_fixture.dart';
import 'support/young_business_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native app shell starts both loopback sources, projects local agenda, and preserves state after reopen',
    (tester) async {
      _TempWorkspace? workspace;
      JwSyncFixture? jwFixture;
      YoungBusinessFixture? youngFixture;
      _NativeShellHarness? first;
      _NativeShellHarness? reopened;
      AppShellController? shell;
      AppShellController? reopenedShell;

      try {
        await tester.runAsync(() async {
          workspace = await _createTempWorkspace();
          jwFixture = await JwSyncFixture.start(requireLogin: true);
          youngFixture = await YoungBusinessFixture.start(
            requireAuthentication: true,
          );
          youngFixture!.username = 'TEST0001';
          expect(jwFixture!.initialUri.host, '127.0.0.1');
          expect(youngFixture!.initialUri.host, '127.0.0.1');
          first = await _NativeShellHarness.create(
            ownerPath: workspace!.ownerPath,
            jwFixture: jwFixture!,
            youngFixture: youngFixture!,
            clock: _testClock,
          );
        });

        final active = first!;
        final activeShell = AppShellController(
          jw: active.jw,
          young: active.young,
          clock: _testClock,
          isGloballyBusy: () => active.leases.isBusy,
        );
        shell = activeShell;
        await tester.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('m41-synthetic-capture'),
            child: ProductApp(
              controller: activeShell,
              settingsBuilder: (_) =>
                  SourceSettingsPage(controller: activeShell),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(activeShell.today, DateTime.utc(2026, 10, 10));
        expect(find.text('Agent 尚未接入'), findsOneWidget);
        await _captureSyntheticUi(tester, 'agent');
        expect(find.byKey(const ValueKey('shell-nav-agent')), findsOneWidget);
        expect(find.byKey(const ValueKey('shell-nav-agenda')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('shell-nav-settings')),
          findsOneWidget,
        );
        final sendButton = find.byKey(const ValueKey('agent-disabled-send'));
        expect(tester.widget<IconButton>(sendButton).onPressed, isNull);
        _expectNoLoopbackRequests(jwFixture!, youngFixture!);

        await _tapKey(tester, 'shell-nav-agenda');
        expect(find.byKey(const ValueKey('agenda-day-picker')), findsOneWidget);
        expect(find.textContaining('2026年10月10日'), findsOneWidget);
        final taskTab = find.descendant(
          of: find.byType(SegmentedButton<AgendaSection>),
          matching: find.text('任务'),
        );
        await tester.tap(taskTab);
        await tester.pumpAndSettle();
        expect(find.text('任务管理正在准备'), findsOneWidget);
        final scheduleTab = find.descendant(
          of: find.byType(SegmentedButton<AgendaSection>),
          matching: find.text('日程'),
        );
        await tester.tap(scheduleTab);
        await tester.pumpAndSettle();
        _expectNoLoopbackRequests(jwFixture!, youngFixture!);

        await _tapKey(tester, 'shell-nav-settings');
        expect(
          find.byKey(const ValueKey('source-settings-jw')),
          findsOneWidget,
        );
        final jwBudget = Stopwatch()..start();
        await _enterText(tester, 'jw-sync-expected-account', 'TEST0001');
        await _enterText(tester, 'jw-sync-password', 'synthetic-password');
        await _tapKey(tester, 'jw-sync-save-password');
        await _tapKey(tester, 'jw-sync-start', settle: false);
        await _waitForNative(
          tester,
          () =>
              active.jw.syncView.phase == JwSyncPhase.idle &&
              active.jw.syncView.importCommitted,
          timeout: _remainingSourceBudget(jwBudget),
          context: 'first UI-driven JW sync',
        );
        await tester.pumpAndSettle();
        expect(active.jw.syncView.data?.credentialSaved, isTrue);
        expect(active.jw.syncView.data?.cachedSemesters, hasLength(2));
        expect(active.jw.syncView.data?.lastSemesterId, 20261);
        await _captureSyntheticUi(tester, 'source-settings');
        expect(active.jw.syncView.data?.courseCount, 1);
        expect(active.jw.syncView.data?.examCount, 1);
        expect(jwFixture!.rejectedRequestCount, 0);
        expect(jwFixture!.authenticationSubmissions, 1);
        expect(jwFixture!.acceptedIndexSemesters, [20261]);
        _expectCredentialFieldCleared(tester, 'jw-sync-password');
        _expectSafeSourceSummaries(active);

        // The first import established the persisted semester cache. Re-enter
        // settings and deliberately use that cached selection on the next run.
        await _tapKey(tester, 'shell-nav-agent');
        await _tapKey(tester, 'shell-nav-settings');
        final cachedSemester = tester.widget<DropdownButtonFormField<String>>(
          find.byKey(const ValueKey('jw-sync-pre-sync-semester')),
        );
        expect(cachedSemester.initialValue, '20261');
        expect(active.jw.syncView.data?.lastSemesterId, 20261);
        final cachedSemesterFinder = find.byKey(
          const ValueKey('jw-sync-pre-sync-semester'),
        );
        await tester.ensureVisible(cachedSemesterFinder);
        await tester.tap(cachedSemesterFinder);
        await tester.pumpAndSettle();
        final autumnOption = find.text('2026 秋季学期（合成）');
        expect(autumnOption, findsWidgets);
        await tester.tap(autumnOption.last);
        await tester.pumpAndSettle();

        jwFixture!.pauseIndex = true;
        await _tapKey(tester, 'jw-sync-start', settle: false);
        await _waitForNative(
          tester,
          () =>
              active.jw.syncView.phase == JwSyncPhase.collecting &&
              jwFixture!.requests
                      .where(
                        (request) => request.startsWith(
                          'GET /for-std/course-table/get-data',
                        ),
                      )
                      .length >=
                  2,
          timeout: _remainingSourceBudget(jwBudget),
          context: 'cached-semester JW request reaches the loopback pause',
        );
        expect(active.leases.isBusy, isTrue);

        // Leave Settings and visit the other source while the native JW job
        // owns the shared lease. Page disposal must leave that job running.
        await _tapKey(tester, 'shell-nav-agent', settle: false);
        await tester.pump();
        expect(active.jw.syncView.phase, JwSyncPhase.collecting);
        expect(active.leases.isBusy, isTrue);
        await _tapKey(tester, 'shell-nav-agenda', settle: false);
        await tester.pump();
        await _tapKey(tester, 'shell-nav-settings', settle: false);
        await tester.pump();
        await _tapKey(tester, 'source-settings-young', settle: false);
        await tester.pump();
        final blockedYoungStart = tester.widget<FilledButton>(
          find.byKey(const ValueKey('young-sync-start-calendar')),
        );
        expect(blockedYoungStart.onPressed, isNull);
        expect(active.jw.syncView.phase, JwSyncPhase.collecting);
        expect(active.leases.isBusy, isTrue);

        jwFixture!.releaseIndex.complete();
        await _waitForNative(
          tester,
          () =>
              active.jw.syncView.phase == JwSyncPhase.idle &&
              active.jw.syncView.importCommitted,
          timeout: _remainingSourceBudget(jwBudget),
          context: 'cached-semester JW sync commits after navigation',
        );
        await tester.pumpAndSettle();
        expect(active.leases.isBusy, isFalse);
        expect(jwFixture!.acceptedIndexSemesters, [20261, 20261]);
        expect(active.jw.syncView.data?.importCount, 2);
        expect(active.jw.syncView.data?.events, hasLength(2));
        expect(active.jw.syncView.data?.credentialSaved, isTrue);
        expect(
          active.jw.syncView.data?.events.map((event) => event.kind),
          containsAll([JwEventKind.course, JwEventKind.exam]),
        );
        expect(
          jwBudget.elapsed,
          lessThanOrEqualTo(const Duration(seconds: 90)),
        );

        final youngBudget = Stopwatch()..start();
        await _waitForNative(
          tester,
          () =>
              active.young.syncView.accountBound ||
              active.young.syncView.data?.accountBound == true,
          timeout: _remainingSourceBudget(youngBudget),
          context: 'shared account binding reaches the Young source view',
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('young-sync-expected-account')),
          findsNothing,
          reason: 'Young reuses the already-bound local school account.',
        );
        await _enterText(
          tester,
          'young-sync-password',
          YoungBusinessFixture.syntheticPassword,
        );
        expect(
          tester
              .widget<CheckboxListTile>(
                find.byKey(const ValueKey('young-sync-save-password')),
              )
              .value,
          isFalse,
          reason:
              'The synthetic Young secret must not replace the shared JW secret.',
        );
        await _enterText(tester, 'young-sync-first-day', '2026-10-10');
        await _enterText(tester, 'young-sync-last-day', '2026-10-10');
        await _tapKey(tester, 'young-sync-start-calendar', settle: false);
        await _waitForNative(
          tester,
          () =>
              active.young.syncView.phase == YoungSyncPhase.idle &&
              active.young.syncView.committed &&
              youngFixture!.calendarRequests > 0,
          timeout: _remainingSourceBudget(youngBudget),
          context: 'UI-driven Young calendar sync',
        );
        await tester.pumpAndSettle();
        expect(active.young.syncView.data?.accountBound, isTrue);
        expect(active.young.syncView.data?.credentialSaved, isTrue);
        expect(
          active.young.syncView.data?.firstDay,
          DateTime.utc(2026, 10, 10),
        );
        expect(active.young.syncView.data?.lastDay, DateTime.utc(2026, 10, 10));
        expect(active.young.syncView.data?.events, hasLength(1));
        expect(active.young.syncView.normalization?.calendarRows, 2);
        expect(active.young.syncView.normalization?.events, 1);
        expect(active.young.syncView.normalization?.excludedSchedules, 1);
        expect(youngFixture!.successfulAuthenticationSubmissions, 1);
        expect(youngFixture!.credentialsMatched, isTrue);
        expect(youngFixture!.unexpectedAuthenticationSubmissions, 0);
        expect(youngFixture!.prematureBusinessNavigations, 0);
        expect(youngFixture!.activityRequests, 0);
        expect(
          youngBudget.elapsed,
          lessThanOrEqualTo(const Duration(seconds: 90)),
        );
        _expectCredentialFieldCleared(tester, 'young-sync-password');
        _expectSafeSourceSummaries(active);

        final beforeAgendaRequests = jwFixture!.requests.length;
        final beforeYoungCalendarRequests = youngFixture!.calendarRequests;
        await _tapKey(tester, 'shell-nav-agenda');
        await tester.pumpAndSettle();
        expect(find.textContaining('2026年10月10日'), findsOneWidget);
        expect(find.text('二课日程'), findsOneWidget);
        expect(find.text('Synthetic linked event'), findsOneWidget);
        expect(find.text('10:00 – 11:00'), findsOneWidget);

        final day10 = activeShell.readAgenda(day: DateTime.utc(2026, 10, 10));
        final day12 = activeShell.readAgenda(day: DateTime.utc(2026, 10, 12));
        final day15 = activeShell.readAgenda(day: DateTime.utc(2026, 10, 15));
        expect(day10.ready && day12.ready && day15.ready, isTrue);
        expect(day10.items, hasLength(1));
        expect(day10.items.single.reference.source, AgendaSource.young);
        expect(day10.items.single.title, 'Synthetic linked event');
        expect(day12.items, hasLength(1));
        expect(day12.items.single.reference.source, AgendaSource.course);
        expect(day12.items.single.title, '合成课程');
        expect(
          formatBeijing(day12.items.single.startsAtUtc),
          '2026-10-12 08:00',
        );
        expect(day15.items, hasLength(1));
        expect(day15.items.single.reference.source, AgendaSource.exam);
        expect(day15.items.single.title, '合成考试课程');
        expect(
          formatBeijing(day15.items.single.startsAtUtc),
          '2026-10-15 09:00',
        );
        final youngReference = day10.items.single.reference;
        final courseReference = day12.items.single.reference;
        expect(youngReference.localId, courseReference.localId);
        expect(youngReference.source, isNot(courseReference.source));

        // The date picker selects the cached day and shows its Beijing date;
        // moving to the exam verifies that all three source facts are visible.
        await tester.tap(find.byKey(const ValueKey('agenda-day-picker')));
        await tester.pumpAndSettle();
        expect(find.text('选择日程日期'), findsOneWidget);
        await tester.tap(find.text('12').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('确定'));
        await tester.pumpAndSettle();
        expect(find.textContaining('2026年10月12日'), findsOneWidget);
        expect(find.text('教务课程'), findsOneWidget);
        expect(find.text('合成课程'), findsOneWidget);
        expect(find.text('08:00 – 09:50'), findsOneWidget);
        await _captureSyntheticUi(tester, 'agenda');
        expect(find.text('Synthetic linked event'), findsNothing);
        for (var index = 0; index < 3; index++) {
          await tester.tap(find.byTooltip('后一天'));
          await tester.pump();
        }
        expect(find.textContaining('2026年10月15日'), findsOneWidget);
        expect(find.text('教务考试'), findsOneWidget);
        expect(find.text('合成考试课程'), findsOneWidget);
        expect(find.text('09:00 – 11:00'), findsOneWidget);

        // A collided local ID is scoped by source. Hiding Young must leave the
        // JW course visible and the current version guards the next write.
        await tester.tap(find.byKey(const ValueKey('agenda-day-picker')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('10').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('确定'));
        await tester.pumpAndSettle();
        await activeShell.setHidden(youngReference, hidden: true);
        await tester.pumpAndSettle();
        expect(
          activeShell.readAgenda(day: DateTime.utc(2026, 10, 10)).items,
          isEmpty,
        );
        final hiddenYoung = activeShell.readAgenda(
          day: DateTime.utc(2026, 10, 10),
          includeHidden: true,
        );
        expect(hiddenYoung.items, hasLength(1));
        expect(hiddenYoung.items.single.hidden, isTrue);
        expect(
          hiddenYoung.items.single.reference.version,
          youngReference.version + 1,
        );
        expect(
          activeShell.readAgenda(day: DateTime.utc(2026, 10, 12)).items.single,
          predicate<AgendaItem>(
            (item) =>
                item.reference.source == AgendaSource.course && !item.hidden,
          ),
        );
        await active.young.setHidden(
          localId: youngReference.localId,
          expectedVersion: youngReference.version,
          hidden: false,
        );
        expect(active.young.syncView.failure, FailureCode.staleResult);
        expect(active.young.syncView.data?.events.single.hidden, isTrue);
        expect(
          active.young.syncView.data?.events.single.version,
          youngReference.version + 1,
        );
        await expectLater(
          activeShell.setHidden(youngReference, hidden: false),
          throwsA(
            isA<AppFailure>().having(
              (error) => error.code,
              'code',
              FailureCode.staleResult,
            ),
          ),
        );
        expect(jwFixture!.requests, hasLength(beforeAgendaRequests));
        expect(youngFixture!.calendarRequests, beforeYoungCalendarRequests);
        expect(find.text('这一天没有可显示的日程'), findsOneWidget);

        final jwEventsBeforeReopen = active.jw.syncView.data!.events;
        final youngEventsBeforeReopen = active.young.syncView.data!.events;
        final jwImportCountBeforeReopen = active.jw.syncView.data!.importCount;
        final youngImportCountBeforeReopen =
            active.young.syncView.data!.importCount;
        late String jwPartitionIdBeforeReopen;
        late String youngPartitionIdBeforeReopen;
        expect(jwEventsBeforeReopen, hasLength(2));
        expect(youngEventsBeforeReopen, hasLength(1));
        expect(youngEventsBeforeReopen.single.hidden, isTrue);
        await tester.runAsync(() async {
          jwPartitionIdBeforeReopen =
              (await active.store.readCommittedPermits()).single.partition.id;
          youngPartitionIdBeforeReopen =
              (await active.store.readYoungPermits()).single.partition.id;
        });

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        activeShell.dispose();
        shell = null;
        await tester.runAsync(() => active.dispose());

        await tester.runAsync(() async {
          reopened = await _NativeShellHarness.create(
            ownerPath: workspace!.ownerPath,
            jwFixture: jwFixture!,
            youngFixture: youngFixture!,
            clock: _testClock,
          );
        });
        final reopenedHarness = reopened!;
        reopenedShell = AppShellController(
          jw: reopenedHarness.jw,
          young: reopenedHarness.young,
          clock: _testClock,
          isGloballyBusy: () => reopenedHarness.leases.isBusy,
        );
        await tester.pumpWidget(
          ProductApp(
            controller: reopenedShell,
            settingsBuilder: (_) =>
                SourceSettingsPage(controller: reopenedShell!),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Agent 尚未接入'), findsOneWidget);
        expect(reopenedHarness.jw.syncView.data?.credentialSaved, isTrue);
        expect(reopenedHarness.young.syncView.data?.credentialSaved, isTrue);
        expect(
          reopenedHarness.jw.syncView.data?.importCount,
          jwImportCountBeforeReopen,
        );
        expect(
          reopenedHarness.young.syncView.data?.importCount,
          youngImportCountBeforeReopen,
        );
        expect(reopenedHarness.jw.syncView.data?.events, hasLength(2));
        expect(reopenedHarness.young.syncView.data?.events, hasLength(1));
        expect(
          reopenedHarness.young.syncView.data?.events.single.hidden,
          isTrue,
        );
        expect(
          reopenedHarness.jw.syncView.data?.events.map(
            (event) => event.localId,
          ),
          unorderedEquals(jwEventsBeforeReopen.map((event) => event.localId)),
        );
        expect(
          reopenedHarness.young.syncView.data?.events.single.localId,
          youngEventsBeforeReopen.single.localId,
        );
        expect(
          reopenedHarness.young.syncView.data?.events.single.version,
          youngEventsBeforeReopen.single.version,
        );
        await tester.runAsync(() async {
          final jwPermit =
              (await reopenedHarness.store.readCommittedPermits()).single;
          final youngPermit =
              (await reopenedHarness.store.readYoungPermits()).single;
          expect(jwPermit.partition.id, jwPartitionIdBeforeReopen);
          expect(youngPermit.partition.id, youngPartitionIdBeforeReopen);
          expect(
            await Directory(
              reopenedHarness.jwRegistry.profilePath(jwPermit.partition),
            ).exists(),
            isTrue,
          );
          expect(
            await Directory(
              reopenedHarness.youngRegistry.profilePath(youngPermit.partition),
            ).exists(),
            isTrue,
          );
        });
        await _tapKey(tester, 'shell-nav-agenda');
        expect(find.textContaining('2026年10月10日'), findsOneWidget);
        expect(find.text('这一天没有可显示的日程'), findsOneWidget);
        expect(jwFixture!.requests, hasLength(beforeAgendaRequests));
        expect(youngFixture!.calendarRequests, beforeYoungCalendarRequests);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        shell?.dispose();
        reopenedShell?.dispose();
        await tester.runAsync(() async {
          if (jwFixture != null && !jwFixture!.releaseIndex.isCompleted) {
            jwFixture!.releaseIndex.complete();
          }
          await _disposeAndCleanWorkspace(
            workspace: workspace,
            harnesses: [
              if (first != null) first!,
              if (reopened != null) reopened!,
            ],
            jwFixture: jwFixture,
            youngFixture: youngFixture,
          );
        });
      }
    },
  );
}

final _testClock = FixedClock(DateTime.utc(2026, 10, 9, 16));

void _expectNoLoopbackRequests(JwSyncFixture jw, YoungBusinessFixture young) {
  expect(jw.requests, isEmpty);
  expect(young.authenticationPages, 0);
  expect(young.authenticationSubmissions, 0);
  expect(young.calendarRequests, 0);
  expect(young.activityRequests, 0);
  expect(young.profiles, 0);
}

void _expectSafeSourceSummaries(_NativeShellHarness harness) {
  for (final summary in [
    harness.jw.syncView.safeSummary,
    harness.young.syncView.safeSummary,
  ]) {
    expect(summary, isNot(contains('TEST0001')));
    expect(summary, isNot(contains('synthetic-password')));
    expect(summary, isNot(contains(YoungBusinessFixture.syntheticPassword)));
    expect(summary, isNot(contains('127.0.0.1')));
  }
}

void _expectCredentialFieldCleared(WidgetTester tester, String key) {
  final finder = find.byKey(ValueKey<String>(key));
  expect(finder, findsOneWidget);
  final field = tester.widget<TextField>(finder);
  expect(field.controller?.text, isEmpty);
}

Future<void> _captureSyntheticUi(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('USTC_M4_QA')) return;
  const destination = String.fromEnvironment('USTC_M4_QA_DIR');
  if (destination.isEmpty || !p.windows.isAbsolute(destination)) {
    throw StateError('A dedicated absolute QA output directory is required.');
  }
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('m41-synthetic-capture')),
  );
  final picture = await boundary.toImage(pixelRatio: 1);
  try {
    final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) throw StateError('Synthetic UI capture was empty.');
    await tester.runAsync(() async {
      final folder = Directory(destination);
      await folder.create(recursive: true);
      await File(
        p.windows.join(destination, '$name.png'),
      ).writeAsBytes(bytes.buffer.asUint8List());
    });
  } finally {
    picture.dispose();
  }
}

Future<void> _tapKey(
  WidgetTester tester,
  String key, {
  bool settle = true,
}) async {
  final finder = find.byKey(ValueKey<String>(key));
  expect(finder, findsOneWidget, reason: 'missing UI key: $key');
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pump();
  if (settle) await tester.pumpAndSettle();
}

Future<void> _enterText(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(ValueKey<String>(key));
  expect(finder, findsOneWidget, reason: 'missing input key: $key');
  await tester.ensureVisible(finder);
  await tester.enterText(finder, value);
  await tester.pump();
}

Future<void> _waitForNative(
  WidgetTester tester,
  bool Function() condition, {
  required Duration timeout,
  required String context,
}) async {
  await tester.runAsync(() => _waitUntil(condition, timeout, context));
}

Duration _remainingSourceBudget(Stopwatch budget) {
  const limit = Duration(seconds: 90);
  final remaining = limit - budget.elapsed;
  if (remaining <= Duration.zero) {
    throw TimeoutException('The native source exceeded its 90 second budget.');
  }
  return remaining;
}

Future<void> _waitUntil(
  bool Function() condition,
  Duration timeout,
  String context,
) async {
  final clock = Stopwatch()..start();
  while (!condition()) {
    if (clock.elapsed >= timeout) {
      throw TimeoutException('Timed out waiting for $context', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

String _nonce() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

Future<_TempWorkspace> _createTempWorkspace() async {
  const prefix = 'ustc_m41_app_shell_';
  final root = await Directory.systemTemp.createTemp(prefix);
  final system = _normal(root: Directory.systemTemp.path);
  final target = _normal(root: root.path);
  final name = p.windows.basename(target);
  if (!p.windows.equals(p.windows.dirname(target), system) ||
      !name.startsWith(prefix) ||
      name.length == prefix.length ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(name.substring(prefix.length))) {
    throw StateError('Temporary root did not match the dedicated nonce path.');
  }
  final nonce = _nonce();
  return _TempWorkspace(
    root: root,
    prefix: prefix,
    nonce: nonce,
    ownerPath: p.windows.join(target, 'native-owner-$nonce'),
  );
}

String _normal({required String root}) =>
    p.windows.normalize(p.windows.absolute(root));

Future<void> _disposeAndCleanWorkspace({
  required _TempWorkspace? workspace,
  required List<_NativeShellHarness> harnesses,
  required JwSyncFixture? jwFixture,
  required YoungBusinessFixture? youngFixture,
}) async {
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

  for (final harness in harnesses.reversed) {
    await attempt(harness.dispose);
  }
  if (jwFixture != null) await attempt(jwFixture.close);
  if (youngFixture != null) await attempt(youngFixture.close);

  final allDisposed = harnesses.every((harness) => harness.disposed);
  if (workspace != null && allDisposed && firstError == null) {
    await attempt(() => _deleteOwnedTempWorkspace(workspace, harnesses));
  } else if (workspace != null && allDisposed && firstError != null) {
    // A preceding close failure means we cannot prove the whole tree safe.
    // Preserve it for inspection and report the cleanup failure to the test.
  } else if (workspace != null && !allDisposed) {
    firstError ??= StateError('Native resources did not all close cleanly.');
    firstStack ??= StackTrace.current;
  }

  if (firstError != null) {
    Error.throwWithStackTrace(firstError!, firstStack!);
  }
}

Future<void> _deleteOwnedTempWorkspace(
  _TempWorkspace workspace,
  List<_NativeShellHarness> harnesses,
) async {
  final system = _normal(root: Directory.systemTemp.path);
  final rootPath = _normal(root: workspace.root.path);
  final name = p.windows.basename(rootPath);
  if (!p.windows.equals(p.windows.dirname(rootPath), system) ||
      !name.startsWith(workspace.prefix) ||
      name.length == workspace.prefix.length ||
      !RegExp(
        r'^[A-Za-z0-9_-]+$',
      ).hasMatch(name.substring(workspace.prefix.length))) {
    throw StateError('Refusing to remove a path outside the nonce TEMP root.');
  }
  final ownerPath = _normal(root: workspace.ownerPath);
  if (!p.windows.equals(p.windows.dirname(ownerPath), rootPath) ||
      p.windows.basename(ownerPath) != 'native-owner-${workspace.nonce}') {
    throw StateError('Refusing to remove an unrecognized native owner path.');
  }
  if (await FileSystemEntity.type(rootPath, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw StateError('Refusing to remove a missing or linked TEMP root.');
  }
  await _assertTreeHasNoLinks(workspace.root, rootPath);

  final rootEntries = await workspace.root.list(followLinks: false).toList();
  if (rootEntries.isNotEmpty &&
      (rootEntries.length != 1 ||
          !p.windows.equals(
            _normal(root: rootEntries.single.path),
            ownerPath,
          ) ||
          await FileSystemEntity.type(
                rootEntries.single.path,
                followLinks: false,
              ) !=
              FileSystemEntityType.directory)) {
    throw StateError('Refusing to remove an unknown TEMP child.');
  }
  if (rootEntries.isNotEmpty) {
    await _validateOwnedNativeTree(Directory(ownerPath), harnesses);
  }
  if (await FileSystemEntity.type(rootPath, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw StateError('TEMP root changed during ownership validation.');
  }
  await _assertTreeHasNoLinks(workspace.root, rootPath);
  await workspace.root.delete(recursive: true);
}

Future<void> _assertTreeHasNoLinks(Directory root, String rootPath) async {
  final pending = <Directory>[root];
  while (pending.isNotEmpty) {
    final directory = pending.removeLast();
    await for (final entity in directory.list(followLinks: false)) {
      final path = _normal(root: entity.path);
      if (!p.windows.isWithin(rootPath, path)) {
        throw StateError('Refusing to remove an entry outside the TEMP owner.');
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

Future<void> _validateOwnedNativeTree(
  Directory owner,
  List<_NativeShellHarness> harnesses,
) async {
  final ownerPath = _normal(root: owner.path);
  final expectedJwIds = <String>{
    for (final harness in harnesses) ...harness.jwPartitionIds,
  };
  final expectedYoungIds = <String>{
    for (final harness in harnesses) ...harness.youngPartitionIds,
  };
  final entries = await owner.list(followLinks: false).toList();
  const files = {'jw.sqlite', 'jw.sqlite-wal', 'jw.sqlite-shm'};
  const directories = {'jw_partitions_v1', 'young_partitions_v1'};
  for (final entry in entries) {
    final path = _normal(root: entry.path);
    if (!p.windows.equals(p.windows.dirname(path), ownerPath)) {
      throw StateError('Refusing to remove an unknown native descendant.');
    }
    final name = p.windows.basename(path);
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (files.contains(name)) {
      if (type != FileSystemEntityType.file) {
        throw StateError('Native database file has an unexpected type.');
      }
    } else if (directories.contains(name)) {
      if (type != FileSystemEntityType.directory) {
        throw StateError('Native partition root has an unexpected type.');
      }
      final expectedIds = name == 'jw_partitions_v1'
          ? expectedJwIds
          : expectedYoungIds;
      final pattern = name == 'jw_partitions_v1'
          ? RegExp(r'^jwp-[0-9a-f]{32}$')
          : RegExp(r'^yp-[0-9a-f]{32}$');
      await _validatePartitionRoot(Directory(path), pattern, expectedIds);
    } else {
      throw StateError('Refusing to remove an unknown native owner entry.');
    }
  }
  for (final required in [
    if (expectedJwIds.isNotEmpty) 'jw_partitions_v1',
    if (expectedYoungIds.isNotEmpty) 'young_partitions_v1',
  ]) {
    if (!entries.any((entry) => p.windows.basename(entry.path) == required)) {
      throw StateError('A committed partition root is missing.');
    }
  }
}

Future<void> _validatePartitionRoot(
  Directory root,
  RegExp idPattern,
  Set<String> expectedIds,
) async {
  final folders = <String>{};
  final metadata = <String>{};
  await for (final entry in root.list(followLinks: false)) {
    final name = p.windows.basename(entry.path);
    final type = await FileSystemEntity.type(entry.path, followLinks: false);
    if (idPattern.hasMatch(name) && type == FileSystemEntityType.directory) {
      if (!expectedIds.contains(name)) {
        throw StateError('Found an unregistered browser partition.');
      }
      folders.add(name);
    } else if (name.endsWith('.json') &&
        idPattern.hasMatch(name.substring(0, name.length - '.json'.length)) &&
        type == FileSystemEntityType.file) {
      final id = name.substring(0, name.length - '.json'.length);
      if (!expectedIds.contains(id)) {
        throw StateError('Found unknown partition lifecycle metadata.');
      }
      metadata.add(id);
    } else {
      throw StateError('Found an unknown entry in a partition registry.');
    }
  }
  if (folders.length != expectedIds.length ||
      metadata.length != expectedIds.length ||
      !folders.containsAll(expectedIds) ||
      !metadata.containsAll(expectedIds)) {
    throw StateError('Partition files do not match committed permits.');
  }
}

final class _TempWorkspace {
  const _TempWorkspace({
    required this.root,
    required this.prefix,
    required this.nonce,
    required this.ownerPath,
  });

  final Directory root;
  final String prefix;
  final String nonce;
  final String ownerPath;
}

final class _NativeShellHarness {
  _NativeShellHarness({
    required this.owner,
    required this.store,
    required this.jwRegistry,
    required this.youngRegistry,
    required this.browser,
    required this.leases,
    required this.jw,
    required this.young,
  });

  final DemoDirectory owner;
  final JwStore store;
  final JwPartitionRegistry jwRegistry;
  final YoungPartitionRegistry youngRegistry;
  final NativeObservationBrowser browser;
  final WorkLeasePool leases;
  final JwSyncCoordinator jw;
  final YoungSyncCoordinator young;
  final Set<String> jwPartitionIds = <String>{};
  final Set<String> youngPartitionIds = <String>{};
  bool _disposed = false;

  bool get disposed => _disposed;

  static Future<_NativeShellHarness> create({
    required String ownerPath,
    required JwSyncFixture jwFixture,
    required YoungBusinessFixture youngFixture,
    required AppClock clock,
  }) async {
    final owner = await DemoDirectory.acquire(ownerPath);
    final store = JwStore(
      openJwDatabase(owner),
      ownership: owner,
      clock: clock,
      credentialProtector: const WindowsJwCredentialProtector(),
    );
    final jwRegistry = JwPartitionRegistry(owner);
    final youngRegistry = YoungPartitionRegistry(owner);
    final browser = NativeObservationBrowser();
    final leases = WorkLeasePool();
    final jw = JwSyncCoordinator(
      store: store,
      registry: jwRegistry,
      browser: browser,
      leases: leases,
      clock: clock,
      target: ObservationTarget.fixture(jwFixture.initialUri),
    );
    final young = YoungSyncCoordinator(
      store: store,
      registry: youngRegistry,
      browser: browser,
      leases: leases,
      clock: clock,
      automaticAuthentication: true,
      target: ObservationTarget.youngFixture(youngFixture.initialUri),
    );
    final harness = _NativeShellHarness(
      owner: owner,
      store: store,
      jwRegistry: jwRegistry,
      youngRegistry: youngRegistry,
      browser: browser,
      leases: leases,
      jw: jw,
      young: young,
    );
    try {
      await store.initialize().timeout(const Duration(seconds: 45));
      await jw.initialize().timeout(const Duration(seconds: 45));
      await young.initialize().timeout(const Duration(seconds: 45));
      return harness;
    } on Object {
      await harness.dispose();
      rethrow;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
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

    await attempt(jw.shutdown);
    await attempt(young.shutdown);
    await attempt(() async {
      jwPartitionIds.addAll(
        (await store.readCommittedPermits()).map(
          (permit) => permit.partition.id,
        ),
      );
    });
    await attempt(() async {
      youngPartitionIds.addAll(
        (await store.readYoungPermits()).map((permit) => permit.partition.id),
      );
    });
    await attempt(browser.dispose);
    await attempt(store.close);
    await attempt(owner.release);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStack!);
    }
    _disposed = true;
  }
}
