import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/jw_sync_panel.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/jw_work_contract.dart';
import 'package:ustc_assistant_m0/data/jw_import_contract.dart';
import 'package:ustc_assistant_m0/jobs/jw_sync_port.dart';
import 'package:ustc_assistant_m0/source/jw_authentication_contract.dart';
import 'package:ustc_assistant_m0/source/jw_collection_failure.dart';
import 'package:ustc_assistant_m0/source/jw_data_probe_contract.dart';
import 'package:ustc_assistant_m0/source/jw_probe_contract.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';

void main() {
  testWidgets(
    'starts collection with one-time credentials and clears controls',
    (tester) async {
      final port = _FakeJwSyncPort();
      addTearDown(port.dispose);
      await tester.pumpWidget(_host(port));
      expect(
        find.byKey(const ValueKey('jw-sync-pre-sync-semester')),
        findsNothing,
      );
      expect(find.textContaining('首次采集会按北京时间当前月份'), findsOneWidget);

      final input = tester.widget<TextField>(
        find.byKey(const ValueKey('jw-sync-expected-account')),
      );
      expect(input.obscureText, isTrue);
      expect(input.autofillHints, isEmpty);
      expect(input.autocorrect, isFalse);
      expect(input.enableSuggestions, isFalse);
      expect(
        find.byKey(const ValueKey('jw-sync-delete-saved-credential')),
        findsNothing,
      );
      final passwordInput = tester.widget<TextField>(
        find.byKey(const ValueKey('jw-sync-password')),
      );
      expect(passwordInput.obscureText, isTrue);
      expect(passwordInput.autofillHints, isEmpty);
      expect(passwordInput.autocorrect, isFalse);
      expect(passwordInput.enableSuggestions, isFalse);
      await tester.enterText(
        find.byKey(const ValueKey('jw-sync-expected-account')),
        '  ab12345  ',
      );
      await tester.enterText(
        find.byKey(const ValueKey('jw-sync-password')),
        'PRIVATE_PASSWORD',
      );
      await tester.pump();
      await tester.tap(find.text('在本机加密保存密码'));
      await tester.ensureVisible(find.text('登录并采集'));
      await tester.tap(find.text('登录并采集'));
      await tester.pump();

      expect(port.startSyncCalls, [
        {
          'expectedAccountCode': 'AB12345',
          'password': 'PRIVATE_PASSWORD',
          'savePassword': true,
          'semesterId': null,
        },
      ]);
      expect(input.controller!.text, isEmpty);
      expect(passwordInput.controller!.text, isEmpty);
      expect(find.textContaining('AB12345'), findsNothing);
      expect(find.textContaining('PRIVATE_PASSWORD'), findsNothing);
    },
  );

  testWidgets('bound saved credential starts without exposing stored values', (
    tester,
  ) async {
    final port = _FakeJwSyncPort(
      view: _view(
        accountBound: true,
        data: _data(const [], credentialSaved: true),
      ),
    );
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));

    expect(
      find.byKey(const ValueKey('jw-sync-expected-account')),
      findsNothing,
    );
    final passwordInput = tester.widget<TextField>(
      find.byKey(const ValueKey('jw-sync-password')),
    );
    expect(passwordInput.controller!.text, isEmpty);
    await tester.tap(find.text('自动采集'));
    await tester.pump();

    expect(port.startSyncCalls, [
      {
        'expectedAccountCode': null,
        'password': null,
        'savePassword': false,
        'semesterId': null,
      },
    ]);
  });

  testWidgets('password is not saved unless entered and explicitly selected', (
    tester,
  ) async {
    final port = _FakeJwSyncPort();
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));
    await tester.enterText(
      find.byKey(const ValueKey('jw-sync-expected-account')),
      'AB12345',
    );
    await tester.enterText(
      find.byKey(const ValueKey('jw-sync-password')),
      'ONE_TIME_PASSWORD',
    );
    await tester.ensureVisible(find.text('登录并采集'));
    await tester.tap(find.text('登录并采集'));
    await tester.pump();

    expect(port.startSyncCalls, [
      {
        'expectedAccountCode': 'AB12345',
        'password': 'ONE_TIME_PASSWORD',
        'savePassword': false,
        'semesterId': null,
      },
    ]);
  });

  testWidgets('password checkbox follows real input and clears with password', (
    tester,
  ) async {
    final port = _FakeJwSyncPort();
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));
    final checkboxFinder = find.byKey(const ValueKey('jw-sync-save-password'));

    var checkbox = tester.widget<CheckboxListTile>(checkboxFinder);
    expect(checkbox.value, isFalse);
    expect(checkbox.onChanged, isNull);

    await tester.enterText(
      find.byKey(const ValueKey('jw-sync-password')),
      'ONE_TIME_PASSWORD',
    );
    await tester.pump();
    checkbox = tester.widget<CheckboxListTile>(checkboxFinder);
    expect(checkbox.value, isFalse);
    expect(checkbox.onChanged, isNotNull);

    await tester.tap(find.text('在本机加密保存密码'));
    await tester.pump();
    checkbox = tester.widget<CheckboxListTile>(checkboxFinder);
    expect(checkbox.value, isTrue);

    await tester.enterText(find.byKey(const ValueKey('jw-sync-password')), '');
    await tester.pump();
    checkbox = tester.widget<CheckboxListTile>(checkboxFinder);
    expect(checkbox.value, isFalse);
    expect(checkbox.onChanged, isNull);
  });

  testWidgets('cached semester defaults to last success and survives rebuild', (
    tester,
  ) async {
    const cached = [
      JwSemesterOption(id: 81, name: '2025 春季学期', selected: false),
      JwSemesterOption(id: 94, name: '2025 秋季学期', selected: false),
    ];
    final port = _FakeJwSyncPort(
      view: _view(
        accountBound: true,
        data: _data(const [], lastSemesterId: 94, cachedSemesters: cached),
      ),
    );
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));

    final picker = find.byKey(const ValueKey('jw-sync-pre-sync-semester'));
    expect(
      tester.widget<DropdownButtonFormField<String>>(picker).initialValue,
      '94',
    );
    await _chooseDropdownOption(tester, picker, '2025 春季学期');

    port.emit(
      _view(
        accountBound: true,
        data: _data(const [], lastSemesterId: 94, cachedSemesters: cached),
      ),
    );
    await tester.pump();
    expect(
      tester.widget<DropdownButtonFormField<String>>(picker).initialValue,
      '81',
    );

    await tester.ensureVisible(find.text('自动采集'));
    await tester.tap(find.text('自动采集'));
    await tester.pump();
    expect(port.startSyncCalls.single['semesterId'], 81);
  });

  testWidgets(
    'cached picker does not invent a default absent from its catalog',
    (tester) async {
      final port = _FakeJwSyncPort(
        view: _view(
          accountBound: true,
          data: _data(
            const [],
            lastSemesterId: 94,
            cachedSemesters: const [
              JwSemesterOption(id: 81, name: '2025 春季学期', selected: false),
            ],
          ),
        ),
      );
      addTearDown(port.dispose);
      await tester.pumpWidget(_host(port));

      final picker = tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const ValueKey('jw-sync-pre-sync-semester')),
      );
      expect(picker.initialValue, isNull);
      expect(find.textContaining('上次成功学期不在已保存目录中，请选择本次学期'), findsOneWidget);
    },
  );

  testWidgets('cached semester picker is disabled while sync is pending', (
    tester,
  ) async {
    const cached = [
      JwSemesterOption(id: 94, name: '2025 秋季学期', selected: false),
    ];
    final pending = Completer<void>();
    final port = _FakeJwSyncPort(
      view: _view(
        accountBound: true,
        data: _data(const [], lastSemesterId: 94, cachedSemesters: cached),
      ),
    );
    port.onStartSync = () => pending.future;
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));
    await tester.ensureVisible(find.text('自动采集'));
    await tester.tap(find.text('自动采集'));
    await tester.pump();

    final picker = tester.widget<DropdownButtonFormField<String>>(
      find.byKey(const ValueKey('jw-sync-pre-sync-semester')),
    );
    expect(picker.onChanged, isNull);
    expect(port.startSyncCalls.single['semesterId'], 94);
    pending.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('controller replacement resets the cached semester choice', (
    tester,
  ) async {
    const firstCatalog = [
      JwSemesterOption(id: 81, name: '2025 春季学期', selected: false),
      JwSemesterOption(id: 94, name: '2025 秋季学期', selected: false),
    ];
    const secondCatalog = [
      JwSemesterOption(id: 81, name: '2025 春季学期', selected: false),
      JwSemesterOption(id: 94, name: '2025 秋季学期', selected: false),
      JwSemesterOption(id: 203, name: '2026 春季学期', selected: false),
    ];
    final first = _FakeJwSyncPort(
      view: _view(
        accountBound: true,
        data: _data(
          const [],
          lastSemesterId: 94,
          cachedSemesters: firstCatalog,
        ),
      ),
    );
    final second = _FakeJwSyncPort(
      view: _view(
        accountBound: true,
        data: _data(
          const [],
          lastSemesterId: 203,
          cachedSemesters: secondCatalog,
        ),
      ),
    );
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await tester.pumpWidget(_host(first));
    final picker = find.byKey(const ValueKey('jw-sync-pre-sync-semester'));
    await _chooseDropdownOption(tester, picker, '2025 春季学期');
    expect(
      tester.widget<DropdownButtonFormField<String>>(picker).initialValue,
      '81',
    );

    await tester.pumpWidget(_host(second));
    expect(
      tester.widget<DropdownButtonFormField<String>>(picker).initialValue,
      '203',
    );
  });

  testWidgets('successful sync updates the cached default semester', (
    tester,
  ) async {
    const oldCatalog = [
      JwSemesterOption(id: 81, name: '2025 春季学期', selected: false),
      JwSemesterOption(id: 94, name: '2025 秋季学期', selected: false),
    ];
    const newCatalog = [
      JwSemesterOption(id: 81, name: '2025 春季学期', selected: false),
      JwSemesterOption(id: 94, name: '2025 秋季学期', selected: false),
      JwSemesterOption(id: 203, name: '2026 春季学期', selected: false),
    ];
    final port = _FakeJwSyncPort(
      view: _view(
        accountBound: true,
        data: _data(const [], lastSemesterId: 94, cachedSemesters: oldCatalog),
      ),
    );
    port.onStartSync = () async {
      port.emit(
        _view(
          accountBound: true,
          importCommitted: true,
          data: _data(
            const [],
            lastSemesterId: 203,
            cachedSemesters: newCatalog,
            semesterCatalogUpdatedAtUtc: DateTime.utc(2026, 10, 10),
          ),
        ),
      );
    };
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));
    await tester.ensureVisible(find.text('自动采集'));
    await tester.tap(find.text('自动采集'));
    await tester.pumpAndSettle();

    expect(port.startSyncCalls.single['semesterId'], 94);
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const ValueKey('jw-sync-pre-sync-semester')),
          )
          .initialValue,
      '203',
    );
  });

  testWidgets('missing cached choice enters fresh directory selection safely', (
    tester,
  ) async {
    const cached = [
      JwSemesterOption(id: 81, name: '2025 春季学期', selected: false),
      JwSemesterOption(id: 94, name: '2025 秋季学期', selected: false),
    ];
    final port = _FakeJwSyncPort(
      view: _view(
        accountBound: true,
        data: _data(const [], lastSemesterId: 94, cachedSemesters: cached),
      ),
    );
    port.onStartSync = () async {
      port.emit(
        _view(
          phase: JwSyncPhase.login,
          ready: true,
          accountBound: true,
          automation: JwAutomationState.choosingSemester,
          semesters: const [
            JwSemesterOption(id: 81, name: '2025 春季学期', selected: false),
            JwSemesterOption(id: 203, name: '2026 春季学期', selected: true),
          ],
          data: _data(const [], lastSemesterId: 94, cachedSemesters: cached),
        ),
      );
    };
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));
    await tester.ensureVisible(find.text('自动采集'));
    await tester.tap(find.text('自动采集'));
    await tester.pumpAndSettle();

    expect(port.startSyncCalls.single['semesterId'], 94);
    expect(find.text('开始前选择的学期不在登录后新目录中，请手动选择；不会自动切换到其他学期。'), findsOneWidget);
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const ValueKey('jw-sync-semester')),
          )
          .initialValue,
      isNull,
    );
    expect(_button(tester, '采集并导入所选学期').onPressed, isNull);
  });

  testWidgets('password over the native 1024 code-unit limit is rejected', (
    tester,
  ) async {
    final port = _FakeJwSyncPort();
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));
    await tester.enterText(
      find.byKey(const ValueKey('jw-sync-expected-account')),
      'AB12345',
    );
    await tester.enterText(
      find.byKey(const ValueKey('jw-sync-password')),
      List<String>.filled(1025, 'x').join(),
    );
    await tester.ensureVisible(find.text('登录并采集'));
    await tester.tap(find.text('登录并采集'));
    await tester.pump();

    expect(port.startSyncCalls, isEmpty);
    expect(find.text('密码不能超过1024个字符。'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('jw-sync-password')))
          .controller!
          .text,
      isEmpty,
    );
  });

  testWidgets(
    'failed start keeps credentials cleared and hides exception text',
    (tester) async {
      final port = _FakeJwSyncPort();
      port.onStartSync = () async {
        throw StateError('PRIVATE_PASSWORD');
      };
      addTearDown(port.dispose);
      await tester.pumpWidget(_host(port));
      final accountController = tester
          .widget<TextField>(
            find.byKey(const ValueKey('jw-sync-expected-account')),
          )
          .controller!;
      final passwordController = tester
          .widget<TextField>(find.byKey(const ValueKey('jw-sync-password')))
          .controller!;
      await tester.enterText(
        find.byKey(const ValueKey('jw-sync-expected-account')),
        'AB12345',
      );
      await tester.enterText(
        find.byKey(const ValueKey('jw-sync-password')),
        'PRIVATE_PASSWORD',
      );
      await tester.ensureVisible(find.text('登录并采集'));
      await tester.tap(find.text('登录并采集'));
      await tester.pumpAndSettle();

      expect(accountController.text, isEmpty);
      expect(passwordController.text, isEmpty);
      expect(find.text('登录或采集未能完成，请检查学校窗口后重试。'), findsOneWidget);
      expect(find.textContaining('PRIVATE_PASSWORD'), findsNothing);
    },
  );

  testWidgets('controller replacement and disposal clear secret controls', (
    tester,
  ) async {
    final firstPort = _FakeJwSyncPort();
    final secondPort = _FakeJwSyncPort();
    addTearDown(firstPort.dispose);
    addTearDown(secondPort.dispose);
    await tester.pumpWidget(_host(firstPort));
    final oldAccountController = tester
        .widget<TextField>(
          find.byKey(const ValueKey('jw-sync-expected-account')),
        )
        .controller!;
    final oldPasswordController = tester
        .widget<TextField>(find.byKey(const ValueKey('jw-sync-password')))
        .controller!;
    await tester.enterText(
      find.byKey(const ValueKey('jw-sync-expected-account')),
      'AB12345',
    );
    await tester.enterText(
      find.byKey(const ValueKey('jw-sync-password')),
      'PRIVATE_PASSWORD',
    );

    await tester.pumpWidget(_host(secondPort));
    expect(oldAccountController.text, isEmpty);
    expect(oldPasswordController.text, isEmpty);
    await tester.enterText(
      find.byKey(const ValueKey('jw-sync-expected-account')),
      'XY98765',
    );
    await tester.enterText(
      find.byKey(const ValueKey('jw-sync-password')),
      'ANOTHER_PASSWORD',
    );
    final replacedAccountController = tester
        .widget<TextField>(
          find.byKey(const ValueKey('jw-sync-expected-account')),
        )
        .controller!;
    final replacedPasswordController = tester
        .widget<TextField>(find.byKey(const ValueKey('jw-sync-password')))
        .controller!;

    await tester.pumpWidget(const SizedBox.shrink());
    expect(replacedAccountController.text, isEmpty);
    expect(replacedPasswordController.text, isEmpty);
  });

  testWidgets('manual login window remains available in diagnostics', (
    tester,
  ) async {
    final port = _FakeJwSyncPort(view: _view(accountBound: true));
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));
    await _openDiagnostics(tester);
    await tester.tap(find.text('仅打开登录窗口'));
    await tester.pump();

    expect(port.openAccounts, [null]);
  });

  testWidgets(
    'manual challenge can continue once after the pending call ends',
    (tester) async {
      final port = _FakeJwSyncPort(
        view: _view(
          phase: JwSyncPhase.login,
          ready: true,
          accountBound: true,
          automation: JwAutomationState.manualRequired,
        ),
      );
      final continued = Completer<void>();
      port.onContinueSync = () => continued.future;
      addTearDown(port.dispose);
      await tester.pumpWidget(_host(port));

      expect(find.text('请在学校窗口完成验证码、额外授权或登录，然后继续采集。'), findsOneWidget);
      await tester.tap(find.text('登录完成，继续采集'));
      await tester.pump();
      expect(port.continueSyncCalls, 1);
      expect(_button(tester, '登录完成，继续采集').onPressed, isNull);
      continued.complete();
      await tester.pump();
      expect(_button(tester, '登录完成，继续采集').onPressed, isNotNull);
    },
  );

  testWidgets('manual login pauses explain safe actionable reasons', (
    tester,
  ) async {
    final port = _FakeJwSyncPort();
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));

    const reasons = <JwLoginPauseReason, String>{
      JwLoginPauseReason.noCredentials: '本机未保存密码且本次未提供密码，请在学校窗口手动登录后继续采集。',
      JwLoginPauseReason.challengeRequired: '学校要求验证码或额外授权，请在学校窗口完成后继续采集。',
      JwLoginPauseReason.pageStructureChanged: '学校登录控件不兼容，请在学校窗口手动登录后继续采集。',
      JwLoginPauseReason.contextUnavailable: '无法确认密码投递目标，请在学校窗口手动登录后继续采集。',
      JwLoginPauseReason.alreadySubmitted: '本次已提交一次登录信息，不会重复发送；请在学校窗口完成后继续采集。',
      JwLoginPauseReason.timedOut: '等待学校响应超时，请在学校窗口检查登录状态后继续采集。',
    };
    for (final entry in reasons.entries) {
      port.emit(
        _view(
          phase: JwSyncPhase.login,
          ready: true,
          accountBound: true,
          automation: JwAutomationState.manualRequired,
          loginPauseReason: entry.key,
        ),
      );
      await tester.pump();
      expect(find.text(entry.value), findsOneWidget);
    }
  });

  testWidgets(
    'saved credential deletion is idle-only and reports a safe error',
    (tester) async {
      final port = _FakeJwSyncPort(
        view: _view(
          accountBound: true,
          data: _data(const [], credentialSaved: true),
        ),
      );
      final deleting = Completer<void>();
      port.onDeleteSavedCredential = () => deleting.future;
      addTearDown(port.dispose);
      await tester.pumpWidget(_host(port));

      final button = find.byKey(
        const ValueKey('jw-sync-delete-saved-credential'),
      );
      expect(_button(tester, '删除保存的密码').onPressed, isNotNull);
      await tester.tap(button);
      await tester.pump();
      expect(port.deleteSavedCredentialCalls, 1);
      expect(_button(tester, '删除保存的密码').onPressed, isNull);
      deleting.completeError(StateError('PRIVATE_PASSWORD must not be shown'));
      await tester.pump();
      expect(find.text('删除本机加密保存的密码失败。'), findsOneWidget);
      expect(find.textContaining('PRIVATE_PASSWORD'), findsNothing);
    },
  );

  testWidgets(
    'remembered semester is selected only when present in fresh directory',
    (tester) async {
      final port = _FakeJwSyncPort(
        view: _view(
          phase: JwSyncPhase.login,
          ready: true,
          accountBound: true,
          automation: JwAutomationState.choosingSemester,
          semesters: const [
            JwSemesterOption(id: 81, name: '2025 春季学期', selected: true),
            JwSemesterOption(id: 94, name: '2025 秋季学期', selected: false),
          ],
          data: _data(const [], lastSemesterId: 94),
        ),
      );
      addTearDown(port.dispose);
      await tester.pumpWidget(_host(port));

      expect(_button(tester, '采集并导入所选学期').onPressed, isNotNull);
      await tester.tap(find.text('采集并导入所选学期'));
      await tester.pump();
      expect(port.collectedSemesters, [94]);
    },
  );

  testWidgets('missing remembered semester requires an explicit choice', (
    tester,
  ) async {
    final port = _FakeJwSyncPort(
      view: _view(
        phase: JwSyncPhase.login,
        ready: true,
        accountBound: true,
        automation: JwAutomationState.choosingSemester,
        semesters: const [
          JwSemesterOption(id: 203, name: '2026 春季学期', selected: true),
        ],
        data: _data(const [], lastSemesterId: 94),
      ),
    );
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));

    expect(find.text('上次成功学期不在本次新目录中，请手动选择；不会自动切换到当前学期。'), findsOneWidget);
    expect(_button(tester, '采集并导入所选学期').onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('jw-sync-semester')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2026 春季学期').last);
    await tester.pumpAndSettle();
    expect(_button(tester, '采集并导入所选学期').onPressed, isNotNull);
    await tester.tap(find.text('采集并导入所选学期'));
    await tester.pump();
    expect(port.collectedSemesters, [203]);
  });

  testWidgets('same-phase progress keeps the semester choice stable', (
    tester,
  ) async {
    final semesters = const [
      JwSemesterOption(id: 81, name: '2025 春季学期', selected: true),
      JwSemesterOption(id: 94, name: '2025 秋季学期', selected: false),
    ];
    final port = _FakeJwSyncPort(
      view: _view(
        phase: JwSyncPhase.login,
        ready: true,
        accountBound: true,
        automation: JwAutomationState.choosingSemester,
        semesters: semesters,
      ),
    );
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));

    await tester.tap(find.byKey(const ValueKey('jw-sync-semester')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2025 秋季学期').last);
    await tester.pumpAndSettle();
    port.emit(
      _view(
        phase: JwSyncPhase.login,
        ready: true,
        accountBound: true,
        automation: JwAutomationState.choosingSemester,
        semesters: semesters,
      ),
    );
    await tester.pump();
    await tester.tap(find.text('采集并导入所选学期'));
    await tester.pump();

    expect(port.collectedSemesters, [94]);
  });

  testWidgets('requires a ready login page for navigation and collection', (
    tester,
  ) async {
    final port = _FakeJwSyncPort(
      view: _view(phase: JwSyncPhase.login, ready: false),
    );
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));
    await _openDiagnostics(tester);

    expect(_button(tester, '打开课表页面').onPressed, isNull);
    expect(_button(tester, '打开考试安排').onPressed, isNull);
    expect(_button(tester, '重新读取学期目录').onPressed, isNull);
    expect(_button(tester, '采集并导入所选学期').onPressed, isNull);
    expect(_button(tester, '关闭本次作业').onPressed, isNotNull);

    port.emit(_view(phase: JwSyncPhase.login, ready: true));
    await tester.pump();
    expect(_button(tester, '打开课表页面').onPressed, isNotNull);
    expect(_button(tester, '重新读取学期目录').onPressed, isNotNull);
  });

  testWidgets('uses the accepted directory option id and clears stale choice', (
    tester,
  ) async {
    final port = _FakeJwSyncPort(
      view: _view(phase: JwSyncPhase.login, ready: true),
    );
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));
    await _openDiagnostics(tester);

    expect(_button(tester, '采集并导入所选学期').onPressed, isNull);
    port.onVerifyDirectory = () async => port.emit(
      _view(
        phase: JwSyncPhase.login,
        ready: true,
        semesters: const [
          JwSemesterOption(id: 81, name: '2025 春季学期', selected: false),
          JwSemesterOption(id: 94, name: '2025 秋季学期', selected: true),
        ],
      ),
    );
    await tester.ensureVisible(find.text('重新读取学期目录'));
    await tester.tap(find.text('重新读取学期目录'));
    await tester.pump();
    expect(port.verifyDirectoryCalls, 1);
    expect(find.text('2025 秋季学期'), findsOneWidget);
    expect(_button(tester, '采集并导入所选学期').onPressed, isNotNull);

    port.emit(_view(phase: JwSyncPhase.login, ready: true));
    await tester.pump();
    expect(_button(tester, '采集并导入所选学期').onPressed, isNull);

    port.emit(
      _view(
        phase: JwSyncPhase.login,
        ready: true,
        semesters: const [
          JwSemesterOption(id: 203, name: '2026 春季学期', selected: true),
        ],
      ),
    );
    await tester.pump();
    await tester.ensureVisible(find.text('采集并导入所选学期'));
    await tester.tap(find.text('采集并导入所选学期'));
    await tester.pump();

    expect(port.collectedSemesters, [203]);
  });

  testWidgets(
    'keeps missing source records visible and filters only hidden rows',
    (tester) async {
      final port = _FakeJwSyncPort(
        view: _view(
          data: _data([
            _event(
              id: 1,
              title: '仍保留的课程',
              presence: JwPresence.missingWithinScope,
            ),
            _event(
              id: 2,
              title: '手动隐藏的考试',
              presence: JwPresence.outsideScope,
              hidden: true,
            ),
          ]),
        ),
      );
      addTearDown(port.dispose);
      await tester.pumpWidget(_host(port));

      expect(find.text('仍保留的课程'), findsOneWidget);
      expect(find.text('来源：本次范围内缺失，仍保留记录'), findsOneWidget);
      expect(find.text('手动隐藏的考试'), findsNothing);
      await tester.ensureVisible(find.text('显示已隐藏'));
      await tester.tap(find.text('显示已隐藏'));
      await tester.pump();

      expect(find.text('手动隐藏的考试'), findsOneWidget);
      expect(find.text('来源：本次范围外，保留历史记录'), findsOneWidget);
    },
  );

  testWidgets(
    'filters courses by stored semester while exams and hidden rules stay independent',
    (tester) async {
      final port = _FakeJwSyncPort(
        view: _view(
          data: _data(
            [
              _event(
                id: 1,
                title: '目录学期课程',
                presence: JwPresence.observed,
                semesterId: 81,
              ),
              _event(
                id: 2,
                title: '历史范围内缺失课程',
                presence: JwPresence.missingWithinScope,
                semesterId: 94,
                startsAtUtc: DateTime.utc(2024, 9, 1, 16),
                endsAtUtc: DateTime.utc(2024, 9, 1, 17),
              ),
              _event(
                id: 3,
                title: '历史范围外隐藏课程',
                presence: JwPresence.outsideScope,
                hidden: true,
                semesterId: 94,
                startsAtUtc: DateTime.utc(2024, 9, 1, 16),
                endsAtUtc: DateTime.utc(2024, 9, 1, 17),
              ),
              _event(
                id: 4,
                title: '没有学期记录的合成课程',
                presence: JwPresence.observed,
              ),
              _event(
                id: 5,
                title: '独立显示的考试',
                presence: JwPresence.outsideScope,
                kind: JwEventKind.exam,
              ),
            ],
            cachedSemesters: const [
              JwSemesterOption(id: 81, name: '目录学期甲', selected: true),
            ],
          ),
        ),
      );
      addTearDown(port.dispose);
      await tester.pumpWidget(_host(port));
      await _chooseDropdownOption(
        tester,
        find.byKey(const ValueKey('jw-sync-date-range')),
        '全部日程',
      );

      expect(find.text('全部已导入学期'), findsOneWidget);
      expect(find.textContaining('课表学期仅筛选课程，考试独立显示。'), findsOneWidget);
      expect(find.text('目录学期课程'), findsOneWidget);
      expect(find.text('历史范围内缺失课程'), findsOneWidget);
      expect(find.text('没有学期记录的合成课程'), findsOneWidget);
      expect(find.text('独立显示的考试'), findsOneWidget);
      expect(find.text('历史范围外隐藏课程'), findsNothing);

      await _chooseDropdownOption(
        tester,
        find.byKey(const ValueKey('jw-sync-display-semester-all')),
        '历史课表（2024年9月2日）',
      );
      expect(find.text('目录学期课程'), findsNothing);
      expect(find.text('历史范围内缺失课程'), findsOneWidget);
      expect(find.text('没有学期记录的合成课程'), findsNothing);
      expect(find.text('独立显示的考试'), findsOneWidget);
      expect(find.textContaining('课表学期：历史课表（'), findsOneWidget);
      expect(find.text('历史范围外隐藏课程'), findsNothing);

      await tester.ensureVisible(find.text('显示已隐藏'));
      await tester.tap(find.text('显示已隐藏'));
      await tester.pump();
      expect(find.text('历史范围外隐藏课程'), findsOneWidget);

      await _chooseDropdownOption(
        tester,
        find.byKey(const ValueKey('jw-sync-display-semester-semester:94')),
        '全部已导入学期',
      );
      expect(find.text('目录学期课程'), findsOneWidget);
      expect(find.text('历史范围内缺失课程'), findsOneWidget);
      expect(find.text('历史范围外隐藏课程'), findsOneWidget);
      final localScroll = find.descendant(
        of: find.byKey(const ValueKey('jw-sync-event-list')),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.text('没有学期记录的合成课程'),
        120,
        scrollable: localScroll,
      );
      expect(find.text('没有学期记录的合成课程'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('独立显示的考试'),
        120,
        scrollable: localScroll,
      );
      expect(find.text('独立显示的考试'), findsOneWidget);
      expect(port.syncView.data!.events, hasLength(5));
      expect(port.openAccounts, isEmpty);
      expect(port.startSyncCalls, isEmpty);
      expect(port.collectedSemesters, isEmpty);
    },
  );

  testWidgets(
    'historical semester option uses its actual local event date span',
    (tester) async {
      final port = _FakeJwSyncPort(
        view: _view(
          data: _data([
            _event(
              id: 1,
              title: '历史学期较早课程',
              presence: JwPresence.outsideScope,
              semesterId: 460,
              startsAtUtc: DateTime.utc(2024, 9, 1, 16),
              endsAtUtc: DateTime.utc(2024, 9, 1, 17),
            ),
            _event(
              id: 2,
              title: '历史学期较晚课程',
              presence: JwPresence.missingWithinScope,
              semesterId: 460,
              startsAtUtc: DateTime.utc(2025, 1, 12, 16),
              endsAtUtc: DateTime.utc(2025, 1, 12, 17),
            ),
          ]),
        ),
      );
      addTearDown(port.dispose);
      await tester.pumpWidget(_host(port));
      await _chooseDropdownOption(
        tester,
        find.byKey(const ValueKey('jw-sync-date-range')),
        '全部日程',
      );

      const label = '历史课表（2024年9月2日—2025年1月13日）';
      await _chooseDropdownOption(
        tester,
        find.byKey(const ValueKey('jw-sync-display-semester-all')),
        label,
      );

      expect(find.text('历史学期较早课程'), findsOneWidget);
      expect(find.text('历史学期较晚课程'), findsOneWidget);
      expect(find.textContaining('课表学期：$label'), findsNWidgets(2));
      expect(find.textContaining('460'), findsNothing);
    },
  );

  testWidgets(
    'keeps a selected local semester by id through catalog changes and resets if it disappears or controller changes',
    (tester) async {
      final firstPort = _FakeJwSyncPort(
        view: _view(
          data: _data(
            [
              _event(
                id: 1,
                title: '第一学期课程',
                presence: JwPresence.observed,
                semesterId: 81,
              ),
              _event(
                id: 2,
                title: '第二学期课程',
                presence: JwPresence.observed,
                semesterId: 94,
              ),
            ],
            cachedSemesters: const [
              JwSemesterOption(id: 81, name: '目录甲', selected: true),
              JwSemesterOption(id: 94, name: '目录乙', selected: false),
            ],
          ),
        ),
      );
      final replacementPort = _FakeJwSyncPort(
        view: _view(
          data: _data(
            [
              _event(
                id: 3,
                title: '新控制器中的历史课程',
                presence: JwPresence.outsideScope,
                semesterId: 94,
              ),
            ],
            cachedSemesters: const [
              JwSemesterOption(id: 94, name: '新目录名称', selected: false),
            ],
          ),
        ),
      );
      addTearDown(firstPort.dispose);
      addTearDown(replacementPort.dispose);
      await tester.pumpWidget(_host(firstPort));
      await _chooseDropdownOption(
        tester,
        find.byKey(const ValueKey('jw-sync-display-semester-all')),
        '目录乙',
      );
      expect(find.text('第一学期课程'), findsNothing);
      expect(find.text('第二学期课程'), findsOneWidget);

      firstPort.emit(
        _view(
          data: _data(
            [
              _event(
                id: 1,
                title: '第一学期课程',
                presence: JwPresence.observed,
                semesterId: 81,
              ),
              _event(
                id: 2,
                title: '第二学期课程',
                presence: JwPresence.observed,
                semesterId: 94,
              ),
            ],
            cachedSemesters: const [
              JwSemesterOption(id: 81, name: '目录甲', selected: true),
              JwSemesterOption(id: 94, name: '目录乙（已更新）', selected: false),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byKey(
                const ValueKey('jw-sync-display-semester-semester:94'),
              ),
            )
            .initialValue,
        'semester:94',
      );
      expect(find.text('第一学期课程'), findsNothing);
      expect(find.text('第二学期课程'), findsOneWidget);
      expect(find.textContaining('课表学期：目录乙（已更新）'), findsOneWidget);

      firstPort.emit(
        _view(
          data: _data([
            _event(
              id: 1,
              title: '第一学期课程',
              presence: JwPresence.observed,
              semesterId: 81,
            ),
          ]),
        ),
      );
      await tester.pump();
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byKey(const ValueKey('jw-sync-display-semester-all')),
            )
            .initialValue,
        'all',
      );
      expect(find.text('第一学期课程'), findsOneWidget);

      await tester.pumpWidget(_host(replacementPort));
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byKey(const ValueKey('jw-sync-display-semester-all')),
            )
            .initialValue,
        'all',
      );
      expect(find.text('新控制器中的历史课程'), findsOneWidget);
    },
  );

  testWidgets('local schedule filters wrap in a narrow window', (tester) async {
    final originalSize = tester.view.physicalSize;
    final originalDevicePixelRatio = tester.view.devicePixelRatio;
    addTearDown(() {
      tester.view.physicalSize = originalSize;
      tester.view.devicePixelRatio = originalDevicePixelRatio;
    });
    tester.view.physicalSize = const Size(280, 720);
    tester.view.devicePixelRatio = 1;

    final port = _FakeJwSyncPort(
      view: _view(
        data: _data([
          _event(
            id: 1,
            title: '窄窗口课程',
            presence: JwPresence.observed,
            semesterId: 81,
          ),
          _event(
            id: 2,
            title: '隐藏历史课程',
            presence: JwPresence.outsideScope,
            hidden: true,
            semesterId: 94,
          ),
        ]),
      ),
    );
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));

    expect(find.byKey(const ValueKey('jw-sync-date-range')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('jw-sync-display-semester-all')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('sends the local event version when hiding an item', (
    tester,
  ) async {
    final port = _FakeJwSyncPort(
      view: _view(
        data: _data([
          _event(
            id: 37,
            version: 6,
            title: '本地课程',
            presence: JwPresence.observed,
          ),
        ]),
      ),
    );
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));
    await tester.ensureVisible(find.text('隐藏').first);
    await tester.tap(find.text('隐藏').first);
    await tester.pump();

    expect(port.hiddenLocalId, 37);
    expect(port.hiddenExpectedVersion, 6);
    expect(port.hiddenValue, isTrue);
  });

  testWidgets('copies only the controller safe summary', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final port = _FakeJwSyncPort(
      view: _view(
        accountBound: false,
        semesters: const [
          JwSemesterOption(
            id: 101,
            name: 'PRIVATE_SEMESTER_LABEL',
            selected: true,
          ),
        ],
        data: _data([
          _event(
            id: 10,
            title: 'PRIVATE_COURSE_TITLE',
            presence: JwPresence.observed,
          ),
        ]),
      ),
    );
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));
    await tester.enterText(
      find.byKey(const ValueKey('jw-sync-expected-account')),
      'AB12345',
    );
    await tester.enterText(
      find.byKey(const ValueKey('jw-sync-password')),
      'PRIVATE_PASSWORD',
    );
    await tester.ensureVisible(find.text('复制导入脱敏摘要'));
    await tester.tap(find.text('复制导入脱敏摘要'));
    await tester.pumpAndSettle();

    expect(copied, isNotNull);
    expect(copied, contains('jw-import-v1'));
    expect(copied, isNot(contains('AB12345')));
    expect(copied, isNot(contains('PRIVATE_PASSWORD')));
    expect(copied, isNot(contains('PRIVATE_COURSE_TITLE')));
    expect(copied, isNot(contains('PRIVATE_SEMESTER_LABEL')));
  });

  testWidgets('committed recovery does not appear fully successful', (
    tester,
  ) async {
    final port = _FakeJwSyncPort(
      view: JwSyncView(
        phase: JwSyncPhase.recovery,
        ready: false,
        accountBound: true,
        sessionRetained: true,
        courseCount: 3,
        examCount: 0,
        importCommitted: true,
        emptyExams: true,
      ),
    );
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));

    expect(find.text('数据已保存，登录资料仍需恢复'), findsOneWidget);
    expect(find.textContaining('本地事务：已提交'), findsNothing);
    expect(find.text('本次未观察到考试，保留已有考试记录。'), findsOneWidget);
    expect(_button(tester, '重试收口/认领').onPressed, isNotNull);
    expect(find.textContaining('全部成功'), findsNothing);
  });

  testWidgets('retained login data does not promise school authentication', (
    tester,
  ) async {
    final port = _FakeJwSyncPort(
      view: JwSyncView(
        accountBound: true,
        sessionRetained: true,
        profileReused: true,
        importCommitted: true,
        courseCount: 3,
      ),
    );
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));

    expect(find.textContaining('登录资料：已保留'), findsOneWidget);
    expect(find.text('已保留登录资料，学校仍可能要求重新登录。'), findsOneWidget);
    expect(_button(tester, '自动采集').onPressed, isNotNull);
    expect(find.textContaining('会话：已保留'), findsNothing);
  });

  testWidgets('explains conflicting duplicate courses with fixed text', (
    tester,
  ) async {
    final port = _FakeJwSyncPort(
      view: JwSyncView(
        failure: FailureCode.invalidSnapshot,
        failureStage: JwSyncPhase.collecting,
        collectionValidation: const JwCollectionValidationFailure(
          JwCollectionRejectionReason.duplicateCourseKey,
          duplicateIdentical: false,
        ),
      ),
    );
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));
    expect(find.text('课表中同一日程的记录内容冲突，本次未导入。'), findsOneWidget);
    expect(find.textContaining('JwCollectionValidationFailure'), findsNothing);
    expect(find.textContaining('duplicateCourseKey'), findsNothing);
  });

  testWidgets('shows fixed safe text for failures', (tester) async {
    final port = _FakeJwSyncPort(
      view: JwSyncView(
        phase: JwSyncPhase.recovery,
        identityFailure: JwIdentityFailure.identityMismatch,
        sourceFailure: JwDataProbeCode.identityChanged,
        failure: FailureCode.cleanupPending,
      ),
    );
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));

    expect(find.text('观测窗口仍需关闭，请重试收口。'), findsOneWidget);
    expect(find.text('本次登录身份发生变化，已停止导入。'), findsOneWidget);
    expect(find.text('采集过程中登录身份发生变化。'), findsOneWidget);
    expect(find.textContaining('AppFailure'), findsNothing);
  });
}

Widget _host(JwSyncPort port) => MaterialApp(
  home: Scaffold(body: JwSyncPanel(controller: port)),
);

Future<void> _openDiagnostics(WidgetTester tester) async {
  final diagnostics = find.text('手动观测与目录诊断');
  await tester.ensureVisible(diagnostics);
  await tester.tap(diagnostics);
  await tester.pumpAndSettle();
}

Future<void> _chooseDropdownOption(
  WidgetTester tester,
  Finder picker,
  String label,
) async {
  await tester.ensureVisible(picker);
  await tester.tap(picker);
  await tester.pumpAndSettle();
  final option = find.text(label).last;
  await tester.ensureVisible(option);
  await tester.tap(option);
  await tester.pumpAndSettle();
}

ButtonStyleButton _button(WidgetTester tester, String label) => tester.widget(
  find.ancestor(
    of: find.text(label),
    matching: find.bySubtype<ButtonStyleButton>(),
  ),
);

JwSyncView _view({
  JwSyncPhase phase = JwSyncPhase.idle,
  bool ready = false,
  bool accountBound = false,
  JwAutomationState automation = JwAutomationState.none,
  List<JwSemesterOption> semesters = const [],
  JwDataView? data,
  bool importCommitted = false,
  JwLoginPauseReason? loginPauseReason,
}) => JwSyncView(
  phase: phase,
  ready: ready,
  accountBound: accountBound,
  automation: automation,
  semesters: semesters,
  data: data,
  importCommitted: importCommitted,
  loginPauseReason: loginPauseReason,
);

JwDataView _data(
  List<JwStoredEvent> events, {
  bool credentialSaved = false,
  int? lastSemesterId,
  List<JwSemesterOption> cachedSemesters = const [],
  DateTime? semesterCatalogUpdatedAtUtc,
}) => JwDataView(
  accountBound: true,
  courseCount: events.where((event) => event.kind == JwEventKind.course).length,
  examCount: events.where((event) => event.kind == JwEventKind.exam).length,
  importCount: 2,
  auditCount: 2,
  events: events,
  credentialSaved: credentialSaved,
  lastSemesterId: lastSemesterId,
  cachedSemesters: cachedSemesters,
  semesterCatalogUpdatedAtUtc: semesterCatalogUpdatedAtUtc,
);

JwStoredEvent _event({
  required int id,
  int version = 1,
  required String title,
  required JwPresence presence,
  bool hidden = false,
  JwEventKind kind = JwEventKind.course,
  int? semesterId,
  DateTime? startsAtUtc,
  DateTime? endsAtUtc,
}) {
  final starts =
      startsAtUtc ?? DateTime.now().toUtc().add(const Duration(days: 1));
  return JwStoredEvent(
    localId: id,
    version: version,
    kind: kind,
    title: title,
    startsAtUtc: starts,
    endsAtUtc: endsAtUtc ?? starts.add(const Duration(hours: 1)),
    presence: presence,
    hidden: hidden,
    semesterId: semesterId,
  );
}

class _FakeJwSyncPort implements JwSyncPort {
  _FakeJwSyncPort({JwSyncView? view}) : _view = view ?? JwSyncView();

  final StreamController<JwSyncView> _changes =
      StreamController<JwSyncView>.broadcast(sync: true);
  JwSyncView _view;
  final List<String?> openAccounts = [];
  final List<Map<String, Object?>> startSyncCalls = [];
  final List<int> collectedSemesters = [];
  Future<void> Function()? onVerifyDirectory;
  Future<void> Function()? onStartSync;
  Future<void> Function()? onContinueSync;
  Future<void> Function()? onDeleteSavedCredential;
  int verifyDirectoryCalls = 0;
  int continueSyncCalls = 0;
  int deleteSavedCredentialCalls = 0;
  int cancelCalls = 0;
  int retryRecoveryCalls = 0;
  int clearSessionCalls = 0;
  JwObservationPage? navigatedPage;
  int? hiddenLocalId;
  int? hiddenExpectedVersion;
  bool? hiddenValue;

  @override
  JwSyncView get syncView => _view;

  @override
  Stream<JwSyncView> get syncChanges => _changes.stream;

  void emit(JwSyncView view) {
    _view = view;
    _changes.add(view);
  }

  @override
  Future<void> open({String? expectedAccountCode}) async {
    openAccounts.add(expectedAccountCode);
  }

  @override
  Future<void> startSync({
    String? expectedAccountCode,
    String? password,
    bool savePassword = false,
    int? semesterId,
  }) async {
    startSyncCalls.add({
      'expectedAccountCode': expectedAccountCode,
      'password': password,
      'savePassword': savePassword,
      'semesterId': semesterId,
    });
    await onStartSync?.call();
  }

  @override
  Future<void> continueSync() async {
    continueSyncCalls++;
    await onContinueSync?.call();
  }

  @override
  Future<void> deleteSavedCredential() async {
    deleteSavedCredentialCalls++;
    await onDeleteSavedCredential?.call();
  }

  @override
  Future<void> navigateJwPage(JwObservationPage page) async {
    navigatedPage = page;
  }

  @override
  Future<void> verifyDirectory() async {
    verifyDirectoryCalls++;
    await onVerifyDirectory?.call();
  }

  @override
  Future<void> collect(int semesterId) async {
    collectedSemesters.add(semesterId);
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }

  @override
  Future<void> retryRecovery() async {
    retryRecoveryCalls++;
  }

  @override
  Future<void> clearSession() async {
    clearSessionCalls++;
  }

  @override
  Future<void> setHidden({
    required int localId,
    required int expectedVersion,
    required bool hidden,
  }) async {
    hiddenLocalId = localId;
    hiddenExpectedVersion = expectedVersion;
    hiddenValue = hidden;
  }

  Future<void> dispose() => _changes.close();
}
