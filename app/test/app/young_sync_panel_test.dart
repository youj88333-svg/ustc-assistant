import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/young_sync_panel.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/jw_credentials.dart';
import 'package:ustc_assistant_m0/core/young_work_contract.dart';
import 'package:ustc_assistant_m0/data/young_import_contract.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_port.dart';
import 'package:ustc_assistant_m0/source/young_collection_contract.dart';
import 'package:ustc_assistant_m0/source/jw_authentication_contract.dart';
import 'package:ustc_assistant_m0/source/young_active_contract.dart';

const _account = 'SYNTHETIC_ACCOUNT_92814';
const _eventTitle = 'SYNTHETIC_PRIVATE_EVENT_TITLE_741';
const _eventPlace = 'SYNTHETIC_PRIVATE_EVENT_PLACE_852';
const _activityTitle = 'SYNTHETIC_PRIVATE_ACTIVITY_TITLE_963';
const _schoolPassword = 'SYNTHETIC_SCHOOL_PASSWORD_SECRET_174';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('uses Beijing month defaults and a remembered successful range', (
    tester,
  ) async {
    final monthPort = _FakeYoungSyncPort();
    addTearDown(monthPort.dispose);
    await _pump(tester, monthPort, clock: () => DateTime.utc(2026, 9, 30, 18));
    expect(
      _textField(tester, 'young-sync-first-day').controller!.text,
      '2026-10-01',
    );
    expect(
      _textField(tester, 'young-sync-last-day').controller!.text,
      '2026-10-31',
    );

    final savedRangePort = _FakeYoungSyncPort(
      initial: YoungSyncView(
        accountBound: true,
        data: _data(
          firstDay: DateTime.utc(2026, 5, 4),
          lastDay: DateTime.utc(2026, 5, 17),
        ),
      ),
    );
    addTearDown(savedRangePort.dispose);
    await _pump(
      tester,
      savedRangePort,
      clock: () => DateTime.utc(2026, 10, 11, 1),
    );
    expect(
      _textField(tester, 'young-sync-first-day').controller!.text,
      '2026-05-04',
    );
    expect(
      _textField(tester, 'young-sync-last-day').controller!.text,
      '2026-05-17',
    );
  });

  testWidgets(
    'calendar sync keeps edited dates, clears expected account, and captures the range',
    (tester) async {
      final jobGate = Completer<void>();
      final port = _FakeYoungSyncPort(
        initial: YoungSyncView(
          data: _data(
            firstDay: DateTime.utc(2026, 5, 1),
            lastDay: DateTime.utc(2026, 5, 31),
          ),
        ),
      )..nextJobGate = jobGate;
      addTearDown(port.dispose);
      await _pump(tester, port, clock: () => DateTime.utc(2026, 10, 11));

      await tester.enterText(
        find.byKey(const ValueKey('young-sync-expected-account')),
        _account,
      );
      await tester.enterText(
        find.byKey(const ValueKey('young-sync-password')),
        _schoolPassword,
      );
      final passwordField = _textField(tester, 'young-sync-password');
      expect(passwordField.obscureText, isTrue);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('young-sync-save-password')),
            )
            .value,
        isFalse,
      );
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('young-sync-save-password')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('young-sync-first-day')),
        '2026-06-02',
      );
      await tester.enterText(
        find.byKey(const ValueKey('young-sync-last-day')),
        '2026-06-04',
      );
      final accountField = _textField(tester, 'young-sync-expected-account');
      expect(accountField.obscureText, isTrue);

      await _tapVisible(
        tester,
        find.byKey(const ValueKey('young-sync-start-calendar')),
      );
      await tester.pump();
      expect(port.calendarCalls, 1);
      expect(port.activityCalls, 0);
      expect(port.lastExpectedAccount, _account);
      expect(port.lastPassword, _schoolPassword);
      expect(port.lastSavePassword, isTrue);
      expect(port.lastFirstDay, DateTime.utc(2026, 6, 2));
      expect(port.lastLastDay, DateTime.utc(2026, 6, 4));
      expect(
        _textField(tester, 'young-sync-expected-account').controller!.text,
        isEmpty,
      );
      expect(
        _textField(tester, 'young-sync-password').controller!.text,
        isEmpty,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('young-sync-save-password')),
            )
            .value,
        isFalse,
      );
      expect(
        _textField(tester, 'young-sync-first-day').controller!.text,
        '2026-06-02',
      );
      expect(
        _textField(tester, 'young-sync-last-day').controller!.text,
        '2026-06-04',
      );
      expect(find.text('取消本次二课作业'), findsOneWidget);

      jobGate.complete();
      await tester.pumpAndSettle();
      expect(port.syncView.committed, isTrue);
      expect(port.syncView.kind, YoungJobKind.calendar);
      expect(port.syncView.data?.credentialSaved, isTrue);
      expect(
        _textField(tester, 'young-sync-first-day').controller!.text,
        '2026-06-02',
      );
      expect(
        _textField(tester, 'young-sync-last-day').controller!.text,
        '2026-06-04',
      );
    },
  );

  testWidgets(
    'activity query is independent and omits account entry when already bound',
    (tester) async {
      final port = _FakeYoungSyncPort(
        initial: YoungSyncView(
          accountBound: true,
          data: _data(accountBound: true),
        ),
      );
      addTearDown(port.dispose);
      await _pump(tester, port);

      expect(
        find.byKey(const ValueKey('young-sync-expected-account')),
        findsNothing,
      );
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('young-sync-start-activities')),
      );
      await tester.pumpAndSettle();

      expect(port.activityCalls, 1);
      expect(port.calendarCalls, 0);
      expect(port.lastExpectedAccount, isNull);
      expect(port.syncView.kind, YoungJobKind.activities);
      expect(port.syncView.data?.queryCount, 1);
    },
  );

  testWidgets(
    'saved school password can be used with an empty password field',
    (tester) async {
      final port = _FakeYoungSyncPort(
        initial: YoungSyncView(
          accountBound: true,
          data: _data(accountBound: true, credentialSaved: true),
        ),
      );
      addTearDown(port.dispose);
      await _pump(tester, port);

      expect(find.textContaining('本机已保存，可留空使用'), findsOneWidget);
      expect(
        _textField(tester, 'young-sync-password').controller!.text,
        isEmpty,
      );
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('young-sync-start-activities')),
      );
      await tester.pumpAndSettle();

      expect(port.lastPassword, isNull);
      expect(port.lastSavePassword, isFalse);
    },
  );

  testWidgets('clears an in-flight password when the controller is replaced', (
    tester,
  ) async {
    final jobGate = Completer<void>();
    final oldPort = _FakeYoungSyncPort(
      initial: YoungSyncView(
        accountBound: true,
        data: _data(accountBound: true),
      ),
    )..nextJobGate = jobGate;
    final newPort = _FakeYoungSyncPort();
    addTearDown(oldPort.dispose);
    addTearDown(newPort.dispose);
    await _pump(tester, oldPort);
    await tester.enterText(
      find.byKey(const ValueKey('young-sync-password')),
      _schoolPassword,
    );
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('young-sync-start-activities')),
    );
    await tester.pump();
    expect(_textField(tester, 'young-sync-password').controller!.text, isEmpty);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: YoungSyncPanel(controller: newPort)),
      ),
    );
    await tester.pump();
    expect(_textField(tester, 'young-sync-password').controller!.text, isEmpty);
    expect(tester.takeException(), isNull);
    jobGate.complete();
    await tester.pump();
  });

  testWidgets('rejects an invalid or overlong range before calling the port', (
    tester,
  ) async {
    final port = _FakeYoungSyncPort();
    addTearDown(port.dispose);
    await _pump(tester, port);
    await tester.enterText(
      find.byKey(const ValueKey('young-sync-expected-account')),
      _account,
    );
    await tester.enterText(
      find.byKey(const ValueKey('young-sync-first-day')),
      '2026-01-01',
    );
    await tester.enterText(
      find.byKey(const ValueKey('young-sync-last-day')),
      '2026-03-04',
    );
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('young-sync-start-calendar')),
          )
          .onPressed,
      isNull,
    );

    await tester.enterText(
      find.byKey(const ValueKey('young-sync-first-day')),
      '2026-01-01',
    );
    await tester.enterText(
      find.byKey(const ValueKey('young-sync-last-day')),
      '2026-03-03',
    );
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('young-sync-start-calendar')),
          )
          .onPressed,
      isNotNull,
    );
    expect(port.calendarCalls, 0);

    await tester.enterText(
      find.byKey(const ValueKey('young-sync-last-day')),
      '2026-02-30',
    );
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('young-sync-start-calendar')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets(
    'continues a ready login and exposes busy cancel and recovery retry',
    (tester) async {
      final loginPort = _FakeYoungSyncPort(
        initial: YoungSyncView(
          phase: YoungSyncPhase.login,
          ready: true,
          automation: YoungAutomationState.submitting,
        ),
      );
      addTearDown(loginPort.dispose);
      await _pump(tester, loginPort);
      expect(find.text('登录完成，继续'), findsNothing);
      expect(find.textContaining('账号身份尚未核验'), findsWidgets);
      loginPort.emit(
        YoungSyncView(
          phase: YoungSyncPhase.login,
          ready: true,
          automation: YoungAutomationState.manualRequired,
          loginPauseReason: JwLoginPauseReason.challengeRequired,
        ),
      );
      await tester.pump();
      expect(find.text('登录完成，继续'), findsOneWidget);
      expect(find.textContaining('学校要求验证码或额外授权'), findsOneWidget);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('young-sync-continue-login')),
      );
      await tester.pumpAndSettle();
      expect(loginPort.continueCalls, 1);

      final busyPort = _FakeYoungSyncPort(
        initial: YoungSyncView(
          accountBound: true,
          profileRetained: true,
          data: _data(accountBound: true),
        ),
      )..nextJobGate = Completer<void>();
      addTearDown(busyPort.dispose);
      await _pump(tester, busyPort, productMode: true);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('young-sync-start-activities')),
      );
      await tester.pump();
      expect(find.text('取消本次操作'), findsOneWidget);
      final cancelFinder = find.byKey(const ValueKey('young-sync-cancel'));
      final primaryActionsFinder = find.byKey(
        const ValueKey('young-sync-primary-actions'),
      );
      await tester.ensureVisible(cancelFinder);
      await tester.pumpAndSettle();
      final busyCancelRect = tester.getRect(cancelFinder);
      final busyPrimaryRect = tester.getRect(primaryActionsFinder);
      final cancelOffsetInPrimary =
          busyCancelRect.topLeft - busyPrimaryRect.topLeft;
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('young-sync-start-activities')),
            )
            .onPressed,
        isNull,
      );
      expect(cancelFinder.hitTestable(), findsOneWidget);
      await tester.tapAt(busyCancelRect.center);
      await tester.pumpAndSettle();
      expect(busyPort.cancelCalls, 1);
      expect(busyPort.syncView.phase, YoungSyncPhase.idle);
      expect(busyPort.syncView.profileRetained, isTrue);

      final idleCancelRect = tester.getRect(cancelFinder);
      final idlePrimaryRect = tester.getRect(primaryActionsFinder);
      expect(idleCancelRect.size, busyCancelRect.size);
      expect(
        idleCancelRect.topLeft - idlePrimaryRect.topLeft,
        cancelOffsetInPrimary,
      );
      expect(tester.widget<OutlinedButton>(cancelFinder).onPressed, isNull);
      await tester.tapAt(busyCancelRect.center);
      await tester.pumpAndSettle();
      expect(busyPort.cancelCalls, 1);
      expect(busyPort.activityCalls, 1);
      expect(busyPort.clearCalls, 0);
      expect(busyPort.deleteCredentialCalls, 0);
      await tester.tapAt(idleCancelRect.center);
      await tester.pumpAndSettle();
      expect(busyPort.clearCalls, 0);
      expect(find.byType(AlertDialog), findsNothing);
      final clearSessionFinder = find.byKey(
        const ValueKey('young-sync-clear-session'),
      );
      expect(
        tester.widget<OutlinedButton>(clearSessionFinder).onPressed,
        isNotNull,
      );
      await _tapVisible(tester, clearSessionFinder);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(busyPort.clearCalls, 0);

      // Recovery labels below exercise the pre-existing diagnostic-mode UI.
      await _pump(tester, busyPort);
      busyPort.emit(
        YoungSyncView(
          phase: YoungSyncPhase.recovery,
          kind: YoungJobKind.calendar,
          committed: true,
          failure: FailureCode.incompleteSnapshot,
        ),
      );
      await tester.pump();
      expect(find.text('重试二课收口'), findsOneWidget);
      expect(find.text('结果已保存，后续处理未完成，请重试二课收口。'), findsOneWidget);
      expect(find.textContaining('结果未提交'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('young-sync-start-calendar')),
            )
            .onPressed,
        isNull,
      );
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('young-sync-retry-recovery')),
      );
      await tester.pumpAndSettle();
      expect(busyPort.retryCalls, 1);

      busyPort.emit(
        YoungSyncView(
          phase: YoungSyncPhase.closing,
          failure: FailureCode.cancelled,
        ),
      );
      await tester.pump();
      expect(find.textContaining('已取消'), findsWidgets);
      expect(find.text('正在关闭并排空二课窗口。'), findsNothing);

      busyPort.emit(
        YoungSyncView(
          phase: YoungSyncPhase.closing,
          committed: true,
          failure: FailureCode.followUpPending,
        ),
      );
      await tester.pump();
      expect(find.text('正在关闭并排空二课窗口。'), findsNothing);
      expect(find.textContaining('结果已保存，后续处理未完成'), findsOneWidget);
      expect(find.textContaining('结果未提交'), findsNothing);
    },
  );

  testWidgets('clears only Young login session from idle state', (
    tester,
  ) async {
    final port = _FakeYoungSyncPort(
      initial: YoungSyncView(
        accountBound: true,
        profileRetained: true,
        data: _data(accountBound: true, credentialSaved: true, importCount: 3),
      ),
    );
    addTearDown(port.dispose);
    await _pump(tester, port);

    await _tapVisible(
      tester,
      find.byKey(const ValueKey('young-sync-clear-session')),
    );
    await tester.pumpAndSettle();

    expect(port.clearCalls, 1);
    expect(port.syncView.data?.importCount, 3);
    expect(port.syncView.accountBound, isTrue);
    expect(port.syncView.data?.credentialSaved, isTrue);
  });

  testWidgets(
    'shared credential deletion keeps account, Young data and session',
    (tester) async {
      final event = _event(localId: 41, version: 3);
      final port = _FakeYoungSyncPort(
        initial: YoungSyncView(
          accountBound: true,
          profileRetained: true,
          data: _data(
            accountBound: true,
            credentialSaved: true,
            events: [event],
            importCount: 2,
          ),
        ),
      );
      addTearDown(port.dispose);
      await _pump(tester, port);

      expect(find.textContaining('教务和二课共用这份加密学校密码'), findsOneWidget);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('young-sync-delete-saved-credential')),
      );
      await tester.pumpAndSettle();

      expect(port.deleteCredentialCalls, 1);
      expect(port.syncView.data?.credentialSaved, isFalse);
      expect(port.syncView.accountBound, isTrue);
      expect(port.syncView.profileRetained, isTrue);
      expect(port.syncView.data?.importCount, 2);
      expect(port.syncView.data?.events.single.localId, 41);
    },
  );

  testWidgets(
    'shows hidden records on request and sends Young localId/version toggles',
    (tester) async {
      final visible = _event(localId: 31, version: 4);
      final hidden = _event(
        localId: 32,
        version: 7,
        title: 'Hidden synthetic item',
        hidden: true,
        presence: YoungPresence.missingWithinScope,
      );
      final port = _FakeYoungSyncPort(
        initial: YoungSyncView(data: _data(events: [visible, hidden])),
      );
      addTearDown(port.dispose);
      await _pump(tester, port);

      expect(find.text(visible.title), findsOneWidget);
      expect(find.text(hidden.title), findsNothing);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('young-sync-show-hidden')),
      );
      await tester.pumpAndSettle();
      expect(find.text(hidden.title), findsOneWidget);
      expect(find.text('来源：本次范围内未观察到，本地记录仍保留'), findsOneWidget);

      await _tapVisible(
        tester,
        find.byKey(const ValueKey('young-local-event-toggle-32')),
      );
      await tester.pumpAndSettle();
      expect(port.hiddenChanges, [(32, 7, false)]);
      expect(
        port.syncView.data!.events
            .singleWhere((event) => event.localId == 32)
            .hidden,
        false,
      );

      await _tapVisible(
        tester,
        find.byKey(const ValueKey('young-local-event-toggle-31')),
      );
      await tester.pumpAndSettle();
      expect(port.hiddenChanges.last, (31, 4, true));
    },
  );

  testWidgets(
    'renders Beijing time and keeps activity and registration windows separate',
    (tester) async {
      final activity = YoungActivityView(
        title: _activityTitle,
        place: 'Synthetic activity place',
        startsAtUtc: DateTime.utc(2026, 1, 1, 3),
        endsAtUtc: DateTime.utc(2026, 1, 1, 4),
        registrationStartsAtUtc: DateTime.utc(2026, 1, 2, 12),
        registrationEndsAtUtc: DateTime.utc(2026, 1, 3, 12),
      );
      final port = _FakeYoungSyncPort(
        initial: YoungSyncView(
          kind: YoungJobKind.activities,
          committed: true,
          activityResults: [activity],
        ),
      );
      addTearDown(port.dispose);
      await _pump(tester, port);

      expect(find.text(_activityTitle), findsOneWidget);
      expect(
        find.textContaining('活动时间：2026-01-01 11:00 — 2026-01-01 12:00'),
        findsOneWidget,
      );
      await _tapVisible(tester, find.text(_activityTitle));
      await tester.pumpAndSettle();
      expect(find.text('地点：Synthetic activity place'), findsOneWidget);
      expect(
        find.text('报名时段：2026-01-02 20:00 — 2026-01-03 20:00'),
        findsOneWidget,
      );
      expect(find.text('活动关联不代表已独立验证本人报名成功或取消。'), findsNothing);
      expect(find.textContaining('不代表已独立验证本人报名成功或取消'), findsOneWidget);
      expect(find.textContaining('已报名成功'), findsNothing);
    },
  );

  testWidgets(
    'empty successful results do not claim the source is unavailable',
    (tester) async {
      final port = _FakeYoungSyncPort(
        initial: YoungSyncView(
          kind: YoungJobKind.activities,
          committed: true,
          data: _data(accountBound: true, queryCount: 1),
        ),
      );
      addTearDown(port.dispose);
      await _pump(tester, port);
      expect(find.text('本次活动查询未返回记录。'), findsOneWidget);
      expect(find.text('本地暂无活动关联日程。'), findsOneWidget);
      expect(find.textContaining('来源不可用'), findsNothing);

      port.emit(
        YoungSyncView(
          kind: YoungJobKind.calendar,
          committed: true,
          accountBound: true,
          normalization: _emptyStats,
          data: _data(accountBound: true, importCount: 1),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('二课日程已保存。'), findsOneWidget);
      expect(find.text('本地暂无活动关联日程。'), findsOneWidget);
      expect(find.textContaining('来源不可用'), findsNothing);
    },
  );

  testWidgets(
    'copies only the closed safe summary and guards completion after disposal',
    (tester) async {
      final messenger = TestDefaultBinaryMessengerBinding.instance;
      final clipboardCalls = <MethodCall>[];
      messenger.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          clipboardCalls.add(call);
          return null;
        },
      );
      addTearDown(
        () => messenger.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      final event = _event(localId: 78123, version: 5, title: _eventTitle);
      final view = YoungSyncView(
        kind: YoungJobKind.calendar,
        accountBound: true,
        profileRetained: true,
        profileReused: true,
        committed: true,
        normalization: _emptyStats,
        data: _data(accountBound: true, events: [event], importCount: 2),
        automation: YoungAutomationState.manualRequired,
        credentialFailure: JwCredentialFailure.protectionFailed,
        loginPauseReason: JwLoginPauseReason.challengeRequired,
        failureStage: YoungSyncPhase.collecting,
        collectionStage: YoungBusinessStage.stopping,
        collectionReason: YoungBusinessRejection.stampChanged,
        activityResults: [
          YoungActivityView(
            title: _activityTitle,
            place: _eventPlace,
            startsAtUtc: DateTime.utc(2026, 6, 1, 1),
            endsAtUtc: DateTime.utc(2026, 6, 1, 2),
            registrationStartsAtUtc: null,
            registrationEndsAtUtc: null,
          ),
        ],
      );
      final port = _FakeYoungSyncPort(initial: view);
      addTearDown(port.dispose);
      await _pump(tester, port);

      final summary = jsonDecode(view.safeSummary) as Map<String, dynamic>;
      expect(summary.keys.toSet(), {
        'kind',
        'phase',
        'action',
        'accountBound',
        'profileRetained',
        'profileReused',
        'committed',
        'failure',
        'identityFailure',
        'automation',
        'credentialSaved',
        'credentialFailure',
        'loginReason',
        'failureStage',
        'collectionStage',
        'collectionReason',
        'normalization',
        'localEvents',
        'importCount',
        'queryCount',
      });
      expect(view.safeSummary, isNot(contains(_account)));
      expect(view.safeSummary, isNot(contains(_eventTitle)));
      expect(view.safeSummary, isNot(contains(_eventPlace)));
      expect(view.safeSummary, isNot(contains(_activityTitle)));
      expect(view.safeSummary, isNot(contains(_schoolPassword)));
      expect(view.safeSummary, isNot(contains('78123')));
      expect(view.safeSummary, isNot(contains('2026-06-01')));
      expect(view.safeSummary, isNot(contains('https://')));
      expect(
        jsonEncode(summary['normalization']),
        jsonEncode(_emptyStats.safeProjection),
      );
      expect(summary['automation'], YoungAutomationState.manualRequired.name);
      expect(summary['credentialSaved'], isFalse);
      expect(
        summary['credentialFailure'],
        JwCredentialFailure.protectionFailed.name,
      );
      expect(summary['loginReason'], JwLoginPauseReason.challengeRequired.name);
      expect(summary['failureStage'], YoungSyncPhase.collecting.name);
      expect(summary['collectionStage'], YoungBusinessStage.stopping.name);
      expect(
        summary['collectionReason'],
        YoungBusinessRejection.stampChanged.name,
      );

      await _tapVisible(
        tester,
        find.byKey(const ValueKey('young-sync-copy-summary')),
      );
      await tester.pumpAndSettle();
      final setDataCalls = clipboardCalls
          .where((call) => call.method == 'Clipboard.setData')
          .toList();
      expect(setDataCalls, hasLength(1));
      final copied = (setDataCalls.single.arguments as Map)['text'] as String;
      expect(jsonDecode(copied), summary);
      expect(copied, isNot(contains(_eventTitle)));
      expect(find.text('已复制二课同步摘要。'), findsOneWidget);

      final gate = Completer<void>();
      port.nextJobGate = gate;
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('young-sync-start-activities')),
      );
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      port.emit(YoungSyncView(phase: YoungSyncPhase.closed));
      gate.complete();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'does not report a stale clipboard completion after the view changes',
    (tester) async {
      final messenger = TestDefaultBinaryMessengerBinding.instance;
      final clipboardGate = Completer<void>();
      messenger.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') await clipboardGate.future;
          return null;
        },
      );
      addTearDown(
        () => messenger.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      final port = _FakeYoungSyncPort();
      addTearDown(port.dispose);
      await _pump(tester, port);

      await _tapVisible(
        tester,
        find.byKey(const ValueKey('young-sync-copy-summary')),
      );
      await tester.pump();
      expect(find.text('正在复制摘要'), findsOneWidget);
      port.emit(YoungSyncView(phase: YoungSyncPhase.closed));
      await tester.pump();
      clipboardGate.complete();
      await tester.pumpAndSettle();

      expect(find.text('已复制二课同步摘要。'), findsNothing);
      expect(find.text('正在复制摘要'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'fits a narrow panel and keeps primary and secondary actions reachable',
    (tester) async {
      final port = _FakeYoungSyncPort(
        initial: YoungSyncView(
          accountBound: true,
          profileRetained: true,
          data: _data(
            accountBound: true,
            credentialSaved: true,
            importCount: 3,
          ),
        ),
      );
      addTearDown(port.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                height: 720,
                child: YoungSyncPanel(controller: port),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      for (final key in <String>[
        'young-sync-start-calendar',
        'young-sync-start-activities',
        'young-sync-clear-session',
        'young-sync-delete-saved-credential',
      ]) {
        final finder = find.byKey(ValueKey(key));
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        expect(finder.hitTestable(), findsOneWidget, reason: key);
        expect(tester.takeException(), isNull);
      }
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  _FakeYoungSyncPort port, {
  DateTime Function()? clock,
  bool productMode = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: YoungSyncPanel(
          controller: port,
          clock: clock,
          productMode: productMode,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

TextField _textField(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key)));

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  expect(finder.hitTestable(), findsOneWidget);
  await tester.tap(finder);
}

const YoungCollectionStats _emptyStats = YoungCollectionStats(
  calendarRows: 0,
  events: 0,
  excludedSchedules: 0,
  duplicateSchedules: 0,
  days: 1,
  calendarPages: 1,
  activityPages: 0,
  activities: 0,
);

YoungDataView _data({
  bool accountBound = false,
  int importCount = 0,
  int queryCount = 0,
  bool credentialSaved = false,
  List<YoungStoredEvent> events = const <YoungStoredEvent>[],
  DateTime? firstDay,
  DateTime? lastDay,
}) => YoungDataView(
  accountBound: accountBound,
  importCount: importCount,
  queryCount: queryCount,
  auditCount: 0,
  credentialSaved: credentialSaved,
  events: events,
  firstDay: firstDay,
  lastDay: lastDay,
);

YoungStoredEvent _event({
  required int localId,
  required int version,
  String title = 'Synthetic local event',
  bool hidden = false,
  YoungPresence presence = YoungPresence.observed,
}) => YoungStoredEvent(
  localId: localId,
  version: version,
  title: title,
  place: 'Synthetic event place',
  startsAtUtc: DateTime.utc(2026, 1, 1, 0, 15),
  endsAtUtc: DateTime.utc(2026, 1, 1, 1, 15),
  presence: presence,
  hidden: hidden,
);

final class _FakeYoungSyncPort implements YoungSyncPort {
  _FakeYoungSyncPort({YoungSyncView? initial})
    : _view = initial ?? YoungSyncView();

  final StreamController<YoungSyncView> _changes =
      StreamController<YoungSyncView>.broadcast(sync: true);
  YoungSyncView _view;
  Completer<void>? nextJobGate;
  Completer<void>? _activeJobGate;
  int _jobGeneration = 0;
  int calendarCalls = 0;
  int activityCalls = 0;
  int continueCalls = 0;
  int cancelCalls = 0;
  int retryCalls = 0;
  int clearCalls = 0;
  int deleteCredentialCalls = 0;
  String? lastExpectedAccount;
  String? lastPassword;
  bool? lastSavePassword;
  DateTime? lastFirstDay;
  DateTime? lastLastDay;
  final List<(int localId, int version, bool hidden)> hiddenChanges =
      <(int, int, bool)>[];

  @override
  YoungSyncView get syncView => _view;

  @override
  Stream<YoungSyncView> get syncChanges => _changes.stream;

  void emit(YoungSyncView view) {
    _view = view;
    _changes.add(view);
  }

  @override
  Future<void> startCalendar({
    String? expectedAccountCode,
    required DateTime firstDay,
    required DateTime lastDay,
    String? password,
    bool savePassword = false,
  }) async {
    calendarCalls++;
    lastExpectedAccount = expectedAccountCode;
    lastPassword = password;
    lastSavePassword = savePassword;
    lastFirstDay = firstDay;
    lastLastDay = lastDay;
    await _runJob(YoungJobKind.calendar);
  }

  @override
  Future<void> startActivities({
    String? expectedAccountCode,
    String? password,
    bool savePassword = false,
  }) async {
    activityCalls++;
    lastExpectedAccount = expectedAccountCode;
    lastPassword = password;
    lastSavePassword = savePassword;
    await _runJob(YoungJobKind.activities);
  }

  Future<void> _runJob(YoungJobKind kind) async {
    final generation = ++_jobGeneration;
    emit(
      _copyView(
        _view,
        phase: YoungSyncPhase.collecting,
        kind: kind,
        committed: false,
        ready: true,
      ),
    );
    final gate = nextJobGate;
    nextJobGate = null;
    _activeJobGate = gate;
    if (gate != null) await gate.future;
    if (identical(_activeJobGate, gate)) _activeJobGate = null;
    if (generation != _jobGeneration) return;
    final data = _view.data ?? _data();
    emit(
      _copyView(
        _view,
        phase: YoungSyncPhase.idle,
        committed: true,
        accountBound: true,
        data: YoungDataView(
          accountBound: true,
          importCount:
              data.importCount + (kind == YoungJobKind.calendar ? 1 : 0),
          queryCount:
              data.queryCount + (kind == YoungJobKind.activities ? 1 : 0),
          auditCount: data.auditCount,
          credentialSaved: data.credentialSaved || lastSavePassword == true,
          events: data.events,
          firstDay: kind == YoungJobKind.calendar
              ? lastFirstDay
              : data.firstDay,
          lastDay: kind == YoungJobKind.calendar ? lastLastDay : data.lastDay,
        ),
      ),
    );
  }

  @override
  Future<void> continueAfterLogin() async {
    continueCalls++;
    final kind = _view.kind ?? YoungJobKind.activities;
    emit(
      _copyView(
        _view,
        phase: YoungSyncPhase.collecting,
        kind: kind,
        ready: true,
      ),
    );
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    ++_jobGeneration;
    final gate = _activeJobGate ?? nextJobGate;
    _activeJobGate = null;
    nextJobGate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
    emit(_copyView(_view, phase: YoungSyncPhase.idle, committed: false));
  }

  @override
  Future<void> retryRecovery() async {
    retryCalls++;
    emit(_copyView(_view, phase: YoungSyncPhase.idle));
  }

  @override
  Future<void> clearSession() async {
    clearCalls++;
    emit(_copyView(_view, phase: YoungSyncPhase.idle, profileRetained: false));
  }

  @override
  Future<void> deleteSavedCredential() async {
    deleteCredentialCalls++;
    final data = _view.data;
    if (data != null) {
      emit(
        _copyView(
          _view,
          data: YoungDataView(
            accountBound: data.accountBound,
            importCount: data.importCount,
            queryCount: data.queryCount,
            auditCount: data.auditCount,
            credentialSaved: false,
            events: data.events,
            firstDay: data.firstDay,
            lastDay: data.lastDay,
          ),
        ),
      );
    }
  }

  @override
  Future<void> setHidden({
    required int localId,
    required int expectedVersion,
    required bool hidden,
  }) async {
    hiddenChanges.add((localId, expectedVersion, hidden));
    final data = _view.data;
    if (data == null) throw const AppFailure(FailureCode.invalidSnapshot);
    final index = data.events.indexWhere((event) => event.localId == localId);
    if (index < 0 || data.events[index].version != expectedVersion) {
      throw const AppFailure(FailureCode.staleResult);
    }
    final events = data.events.toList();
    final old = events[index];
    events[index] = YoungStoredEvent(
      localId: old.localId,
      version: old.version + 1,
      title: old.title,
      place: old.place,
      startsAtUtc: old.startsAtUtc,
      endsAtUtc: old.endsAtUtc,
      presence: old.presence,
      hidden: hidden,
    );
    emit(
      _copyView(
        _view,
        data: YoungDataView(
          accountBound: data.accountBound,
          importCount: data.importCount,
          queryCount: data.queryCount,
          auditCount: data.auditCount + 1,
          credentialSaved: data.credentialSaved,
          events: events,
          firstDay: data.firstDay,
          lastDay: data.lastDay,
        ),
      ),
    );
  }

  Future<void> dispose() => _changes.close();
}

YoungSyncView _copyView(
  YoungSyncView old, {
  YoungSyncPhase? phase,
  YoungJobKind? kind,
  bool? ready,
  bool? accountBound,
  bool? profileRetained,
  bool? committed,
  YoungAutomationState? automation,
  YoungCollectionStats? normalization,
  YoungDataView? data,
}) => YoungSyncView(
  phase: phase ?? old.phase,
  kind: kind ?? old.kind,
  ready: ready ?? old.ready,
  accountBound: accountBound ?? old.accountBound,
  profileRetained: profileRetained ?? old.profileRetained,
  profileReused: old.profileReused,
  committed: committed ?? old.committed,
  failure: old.failure,
  identityFailure: old.identityFailure,
  automation: automation ?? old.automation,
  credentialFailure: old.credentialFailure,
  loginPauseReason: old.loginPauseReason,
  failureStage: old.failureStage,
  collectionStage: old.collectionStage,
  collectionReason: old.collectionReason,
  normalization: normalization ?? old.normalization,
  data: data ?? old.data,
  activityResults: old.activityResults,
);
