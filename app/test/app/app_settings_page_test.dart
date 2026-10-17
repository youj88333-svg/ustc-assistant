import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/app_settings_page.dart';
import 'package:ustc_assistant_m0/app/diagnostics_panel.dart';
import 'package:ustc_assistant_m0/app/app_shell_contract.dart';
import 'package:ustc_assistant_m0/app/maintenance_recovery_page.dart';
import 'package:ustc_assistant_m0/app/settings_contract.dart';
import 'package:ustc_assistant_m0/core/agenda_contract.dart';
import 'package:ustc_assistant_m0/core/diagnostics_contract.dart';
import 'package:ustc_assistant_m0/core/knowledge_contract.dart';
import 'package:ustc_assistant_m0/core/public_query_contract.dart';
import 'package:ustc_assistant_m0/jobs/jw_sync_port.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_port.dart';
import 'package:ustc_assistant_m0/platform/transient_diagnostics.dart';

void main() {
  for (final outcome in ['saved', 'cancelled', 'failed']) {
    testWidgets('maintenance recovery diagnostics remain usable: $outcome', (
      tester,
    ) async {
      final settings = _FakeSettings(
        maintenance: const MaintenanceProgress(
          phase: MaintenancePhase.recovery,
          failure: SettingsFailureCode.cleanupPending,
        ),
      );
      final diagnostics = TransientDiagnostics();
      addTearDown(diagnostics.close);
      diagnostics.record(
        const DiagnosticEvent(
          name: DiagnosticEventName.applicationFailed,
          code: DiagnosticCode.unsupportedPlatform,
          outcome: DiagnosticOutcome.failure,
        ),
      );
      var saves = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: MaintenanceRecoveryPage(
            settings: settings,
            diagnosticsBuilder: (_) => DiagnosticsExportButton(
              diagnostics: diagnostics,
              save: (contents) async {
                saves++;
                expect(contents, contains('unsupportedPlatform'));
                if (outcome == 'failed') throw StateError('private-sentinel');
                return outcome == 'saved';
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('diagnostics-export-button')),
      );
      await tester.tap(find.byKey(const ValueKey('diagnostics-export-button')));
      await tester.pumpAndSettle();
      expect(saves, 1);
      expect(settings.retryCalls, 0);
      expect(
        find.text('日志已导出，请自行发送给维护者。'),
        outcome == 'saved' ? findsOneWidget : findsNothing,
      );
      expect(
        find.text('未能导出日志，请稍后重试。'),
        outcome == 'failed' ? findsOneWidget : findsNothing,
      );
      expect(find.textContaining('private-sentinel'), findsNothing);
    });
  }
  group('ApplicationSettingsPage', () {
    testWidgets('shows four sections and saves display defaults immediately', (
      tester,
    ) async {
      final settings = _FakeSettings();
      final shell = _FakeShell();
      await _pumpSettings(tester, settings, shell);

      for (final section in const ['来源', '显示', '数据与隐私', '关于']) {
        expect(find.text(section), findsOneWidget);
      }

      await _tap(
        tester,
        find.byKey(const ValueKey('settings-section-display')),
      );
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(const ValueKey('settings-calendar-view-week')),
            )
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('settings-include-inactive')),
            )
            .value,
        isFalse,
      );

      await _tap(
        tester,
        find.byKey(const ValueKey('settings-calendar-view-day')),
      );
      expect(settings.preferenceWrites, hasLength(1));
      expect(settings.preferenceWrites.single.$1, settings.context);
      expect(
        settings.preferenceWrites.single.$2.calendarView,
        DefaultCalendarView.day,
      );
      expect(settings.preferenceWrites.single.$2.includeInactive, isFalse);
      await _tap(
        tester,
        find.byKey(const ValueKey('settings-include-inactive')),
      );
      expect(settings.preferenceWrites, hasLength(2));
      expect(settings.preferenceWrites.last.$2.includeInactive, isTrue);
      expect(find.textContaining('北京时间'), findsOneWidget);
      expect(find.textContaining('周一开始'), findsOneWidget);

      await _tap(tester, find.byKey(const ValueKey('settings-section-about')));
      expect(find.text('USTC Assistant · 1.00'), findsOneWidget);
      expect(find.textContaining('1.0.0+1'), findsOneWidget);
      expect(find.textContaining('管理个人安排'), findsOneWidget);
      expect(find.textContaining('正在接入'), findsNothing);
    });

    testWidgets(
      'mobile settings categories scroll horizontally and stay tappable',
      (tester) async {
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final settings = _FakeSettings();
        final shell = _FakeShell();
        var logsActionCalls = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(2)),
                child: Scaffold(
                  body: ApplicationSettingsPage(
                    settings: settings,
                    controller: shell,
                    logsActionBuilder: (_) => OutlinedButton.icon(
                      key: const ValueKey('settings-logs-action'),
                      onPressed: () => logsActionCalls++,
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('导出最近运行诊断日志'),
                    ),
                    agentBuilder: (_) => const Text('Agent 设置内容'),
                    remindersBuilder: (_) => const Text('提醒设置内容'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final logsAction = find.byKey(const ValueKey('settings-logs-action'));
        final logsActionRect = tester.getRect(logsAction);
        expect(logsActionRect.left, greaterThanOrEqualTo(0));
        expect(logsActionRect.right, lessThanOrEqualTo(320));
        expect(logsAction.hitTestable(), findsOneWidget);
        await tester.tap(logsAction);
        await tester.pumpAndSettle();
        expect(logsActionCalls, 1);

        final strip = find.byKey(const ValueKey('settings-sections-scroll'));
        final source = find.byKey(const ValueKey('settings-section-sources'));
        final sourceRect = tester.getRect(source);
        expect(sourceRect.height, greaterThanOrEqualTo(48));
        expect(sourceRect.left, greaterThanOrEqualTo(0));
        expect(sourceRect.right, lessThanOrEqualTo(320));
        expect(source.hitTestable(), findsOneWidget);

        await tester.drag(strip, const Offset(-900, 0));
        await tester.pumpAndSettle();
        final about = find.byKey(const ValueKey('settings-section-about'));
        final aboutRect = tester.getRect(about);
        expect(aboutRect.height, greaterThanOrEqualTo(48));
        expect(aboutRect.left, greaterThanOrEqualTo(0));
        expect(aboutRect.right, lessThanOrEqualTo(320));
        expect(about.hitTestable(), findsOneWidget);
        await tester.tap(about);
        await tester.pumpAndSettle();
        expect(find.text('USTC Assistant · 1.00'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'diagnostics action and privacy log remain available without a snapshot and after recovery',
      (tester) async {
        final settings = _FakeSettings(
          snapshotAvailable: false,
          failure: SettingsFailureCode.storageFailed,
        );
        final shell = _FakeShell();
        var logsActionCalls = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ApplicationSettingsPage(
                settings: settings,
                controller: shell,
                logsActionBuilder: (_) => OutlinedButton.icon(
                  key: const ValueKey('settings-logs-action'),
                  onPressed: () => logsActionCalls++,
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('导出运行日志'),
                ),
                logsBuilder: (_) => const Card(
                  key: ValueKey('settings-logs-card'),
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('运行诊断日志'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final logsAction = find.byKey(const ValueKey('settings-logs-action'));
        expect(logsAction.hitTestable(), findsOneWidget);
        await tester.tap(logsAction);
        await tester.pumpAndSettle();
        expect(logsActionCalls, 1);

        await _tap(
          tester,
          find.byKey(const ValueKey('settings-section-dataPrivacy')),
        );
        expect(
          find.byKey(const ValueKey('settings-logs-card')).hitTestable(),
          findsOneWidget,
        );
        expect(find.text('运行诊断日志'), findsOneWidget);
        expect(find.textContaining('数据计数和维护操作暂不可用'), findsOneWidget);
        expect(find.text('本机数据计数'), findsNothing);
        expect(
          find.byKey(const ValueKey('settings-clear-agenda')),
          findsNothing,
        );

        settings.recoverSnapshot();
        await tester.pumpAndSettle();
        expect(logsAction.hitTestable(), findsOneWidget);
        await tester.tap(logsAction);
        await tester.pumpAndSettle();
        expect(logsActionCalls, 2);
        expect(
          find.byKey(const ValueKey('settings-logs-card')).hitTestable(),
          findsOneWidget,
        );
        expect(find.text('本机数据计数'), findsOneWidget);
        expect(find.textContaining('数据计数和维护操作暂不可用'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('privacy logs remain the first reachable content item', (
      tester,
    ) async {
      final settings = _FakeSettings();
      final shell = _FakeShell();
      await _pumpSettings(
        tester,
        settings,
        shell,
        logsBuilder: (_) => const Card(
          key: ValueKey('settings-logs-card'),
          child: Padding(padding: EdgeInsets.all(16), child: Text('运行诊断日志')),
        ),
      );
      await _tap(
        tester,
        find.byKey(const ValueKey('settings-section-dataPrivacy')),
      );

      final logsCard = find.byKey(const ValueKey('settings-logs-card'));
      final accountTitle = find.text('账号与本机凭据');
      expect(logsCard.hitTestable(), findsOneWidget);
      expect(
        tester.getRect(logsCard).top,
        lessThan(tester.getRect(accountTitle).top),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('maintenance uses fixed scopes and two confirmations', (
      tester,
    ) async {
      final settings = _FakeSettings();
      final shell = _FakeShell();
      await _openData(tester, settings, shell);

      final agendaAction = find.byKey(const ValueKey('settings-clear-agenda'));
      await _tap(tester, agendaAction);
      expect(find.text('清空日程与任务？'), findsOneWidget);
      expect(find.textContaining('共享密码'), findsOneWidget);
      expect(find.textContaining('清空日程不会删除密码'), findsOneWidget);
      await _tap(tester, find.text('取消'));
      expect(settings.maintenanceWrites, isEmpty);

      await _tap(tester, agendaAction);
      await _tap(tester, find.text('继续确认'));
      expect(find.text('再次确认清空日程与任务'), findsOneWidget);
      expect(settings.maintenanceWrites, isEmpty);
      await _tap(tester, find.text('确认清空日程与任务'));
      expect(settings.maintenanceWrites, hasLength(1));
      expect(settings.maintenanceWrites.single.$1, settings.context);
      expect(settings.maintenanceWrites.single.$2, MaintenanceKind.agenda);
      expect(settings.maintenanceWrites.single.$3, isTrue);

      final resetAction = find.byKey(const ValueKey('settings-reset'));
      await _tap(tester, resetAction);
      expect(find.text('完全重置本应用数据？'), findsOneWidget);
      expect(find.textContaining('不会删除旧工程、系统浏览器或任意目录'), findsOneWidget);
      await _tap(tester, find.text('继续确认'));
      expect(find.text('再次确认完全重置'), findsOneWidget);
      await _tap(tester, find.text('确认完全重置'));
      expect(settings.maintenanceWrites, hasLength(2));
      expect(settings.maintenanceWrites.last.$1, settings.context);
      expect(settings.maintenanceWrites.last.$2, MaintenanceKind.reset);
    });

    testWidgets(
      'knowledge status uses snapshot counts and never calls failure success',
      (tester) async {
        final settings = _FakeSettings(materials: 3);
        final shell = _FakeShell();
        await _openData(tester, settings, shell);
        final knowledgeCard = find
            .ancestor(
              of: find.byKey(const ValueKey('settings-clear-knowledge')),
              matching: find.byType(Card),
            )
            .first;
        expect(
          find.descendant(of: knowledgeCard, matching: find.text('3')),
          findsOneWidget,
        );
        expect(find.textContaining('固定载入 7 项'), findsOneWidget);
        expect(find.textContaining('没有搜索或阅读入口'), findsOneWidget);

        settings.emit(
          loadOutcome: const KnowledgeLoadOutcome(
            state: KnowledgeLoadState.failed,
            accepted: 1,
            unchanged: 2,
            total: 7,
            failure: PublicFailureCode.storageFailed,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('载入未完成'), findsOneWidget);
        expect(find.textContaining('载入完成'), findsNothing);

        await _tap(
          tester,
          find.byKey(const ValueKey('settings-load-knowledge')),
        );
        expect(settings.loadCalls, 1);
        expect(find.textContaining('载入未完成'), findsOneWidget);
        expect(find.textContaining('载入完成'), findsNothing);

        final clear = find.byKey(const ValueKey('settings-clear-knowledge'));
        await _tap(tester, clear);
        expect(find.text('清空本地资料库？'), findsOneWidget);
        expect(find.textContaining('学校与个人日程、任务'), findsOneWidget);
        await _tap(tester, find.text('取消'));
        expect(settings.clearKnowledgeCalls, 0);

        await _tap(tester, clear);
        await _tap(tester, find.text('继续确认'));
        await _tap(tester, find.text('确认清空资料'));
        expect(settings.clearKnowledgeCalls, 1);
        expect(settings.clearContexts.single, settings.context);
        expect(settings.clearConfirmations.single, isTrue);
      },
    );

    testWidgets(
      'course review consent requires explicit keyword-scope confirmation',
      (tester) async {
        final settings = _FakeSettings();
        final shell = _FakeShell();
        await _openData(tester, settings, shell);
        final consent = find.byKey(const ValueKey('settings-icourse-consent'));

        await _tap(tester, consent);
        expect(find.text('开启评课联网授权？'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('settings-consent-confirmation')),
            matching: find.textContaining('课程或教师关键词'),
          ),
          findsOneWidget,
        );
        await _tap(tester, find.text('取消'));
        expect(settings.consentWrites, isEmpty);

        await _tap(tester, consent);
        await _tap(tester, find.text('开启授权'));
        expect(settings.consentWrites, hasLength(1));
        expect(settings.consentWrites.single.$1, settings.context);
        expect(settings.consentWrites.single.$2, isTrue);
        expect(settings.consentWrites.single.$3, isTrue);
      },
    );

    testWidgets(
      'global busy blocks new writes but keeps active load cancellation',
      (tester) async {
        final settings = _FakeSettings(knowledgeLoading: true);
        final shell = _FakeShell()..globallyBusy = true;
        await _openData(tester, settings, shell);

        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('settings-load-knowledge')),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const ValueKey('settings-clear-knowledge')),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const ValueKey('settings-clear-agenda')),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const ValueKey('settings-cancel-knowledge')),
              )
              .onPressed,
          isNotNull,
        );

        await _tap(
          tester,
          find.byKey(const ValueKey('settings-cancel-knowledge')),
        );
        expect(settings.cancelCalls, 1);
      },
    );

    testWidgets(
      'unavailable source progress blocks writes while load cancellation remains enabled',
      (tester) async {
        final settings = _FakeSettings(knowledgeLoading: true);
        final shell = _FakeShell()..progressUnavailable = true;
        await _openData(tester, settings, shell);

        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('settings-load-knowledge')),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const ValueKey('settings-clear-agenda')),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const ValueKey('settings-cancel-knowledge')),
              )
              .onPressed,
          isNotNull,
        );
        await _tap(
          tester,
          find.byKey(const ValueKey('settings-cancel-knowledge')),
        );
        expect(settings.cancelCalls, 1);
      },
    );

    testWidgets('360 by 620 layout remains scrollable and usable at 2x text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 620);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final settings = _FakeSettings();
      final shell = _FakeShell();
      var logsActionCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(2)),
              child: Scaffold(
                body: ApplicationSettingsPage(
                  settings: settings,
                  controller: shell,
                  logsActionBuilder: (_) => OutlinedButton.icon(
                    key: const ValueKey('settings-logs-action'),
                    onPressed: () => logsActionCalls++,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('导出运行日志'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final logsAction = find.byKey(const ValueKey('settings-logs-action'));
      final logsActionRect = tester.getRect(logsAction);
      expect(logsActionRect.left, greaterThanOrEqualTo(0));
      expect(logsActionRect.right, lessThanOrEqualTo(360));
      expect(logsAction.hitTestable(), findsOneWidget);
      await tester.tap(logsAction);
      await tester.pumpAndSettle();
      expect(logsActionCalls, 1);
      await _tap(
        tester,
        find.byKey(const ValueKey('settings-section-display')),
      );
      final include = find.byKey(const ValueKey('settings-include-inactive'));
      await tester.ensureVisible(include);
      await tester.pumpAndSettle();
      expect(include.hitTestable(), findsOneWidget);
      await tester.tap(include);
      await tester.pumpAndSettle();
      expect(settings.preferenceWrites, hasLength(1));
      expect(settings.preferenceWrites.single.$2.includeInactive, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'stale context, replaced port, and unmounted dialog cannot write',
      (tester) async {
        final settings = _FakeSettings();
        final shell = _FakeShell();
        await _openData(tester, settings, shell);

        await _tap(
          tester,
          find.byKey(const ValueKey('settings-clear-knowledge')),
        );
        settings.replaceContext();
        await _tap(tester, find.text('继续确认'));
        expect(
          find.byKey(const ValueKey('settings-confirm-final')),
          findsNothing,
        );
        expect(settings.clearKnowledgeCalls, 0);

        settings.replaceContext();
        await _tap(
          tester,
          find.byKey(const ValueKey('settings-clear-knowledge')),
        );
        final replacement = _FakeSettings();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ApplicationSettingsPage(
                settings: replacement,
                controller: shell,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('清空本地资料库？'), findsOneWidget);
        await _tap(tester, find.text('继续确认'));
        expect(
          find.byKey(const ValueKey('settings-confirm-final')),
          findsNothing,
        );
        expect(settings.clearKnowledgeCalls, 0);
        expect(replacement.clearKnowledgeCalls, 0);

        final visible = ValueNotifier<bool>(true);
        addTearDown(visible.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: visible,
                builder: (context, show, _) => show
                    ? ApplicationSettingsPage(
                        settings: replacement,
                        controller: shell,
                      )
                    : const Text('settings removed'),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _tap(
          tester,
          find.byKey(const ValueKey('settings-section-dataPrivacy')),
        );
        await _tap(
          tester,
          find.byKey(const ValueKey('settings-clear-knowledge')),
        );
        visible.value = false;
        await tester.pumpAndSettle();
        await _tap(tester, find.text('继续确认'));
        expect(find.text('settings removed'), findsOneWidget);
        expect(replacement.clearKnowledgeCalls, 0);
      },
    );

    testWidgets('source section delegates to existing source settings page', (
      tester,
    ) async {
      final settings = _FakeSettings();
      final shell = _FakeShell();
      await _pumpSettings(tester, settings, shell);
      expect(find.byKey(const ValueKey('source-settings-jw')), findsOneWidget);
      await _tap(
        tester,
        find.byKey(const ValueKey('settings-section-dataPrivacy')),
      );
      await _tap(tester, find.byKey(const ValueKey('settings-open-sources')));
      expect(find.byKey(const ValueKey('source-settings-jw')), findsOneWidget);
    });
  });

  testWidgets(
    'recovery retries only in recovery phase and shows fixed guidance',
    (tester) async {
      final settings = _FakeSettings(
        maintenance: const MaintenanceProgress(
          phase: MaintenancePhase.cleaning,
          kind: MaintenanceKind.agenda,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(home: MaintenanceRecoveryPage(settings: settings)),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('maintenance-recovery-retry')),
            )
            .onPressed,
        isNull,
      );

      settings.emit(
        maintenance: const MaintenanceProgress(
          phase: MaintenancePhase.recovery,
          kind: MaintenanceKind.agenda,
          failure: SettingsFailureCode.cleanupPending,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('账号、密码和资料库'), findsOneWidget);
      expect(find.textContaining('系统窗口关闭按钮'), findsOneWidget);
      expect(find.textContaining('cleanup-operation'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('maintenance-recovery-retry')),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(
        find.byKey(const ValueKey('maintenance-recovery-retry')),
      );
      await tester.pumpAndSettle();
      expect(settings.retryCalls, 1);
    },
  );
}

Future<void> _pumpSettings(
  WidgetTester tester,
  _FakeSettings settings,
  _FakeShell shell, {
  WidgetBuilder? logsBuilder,
  WidgetBuilder? logsActionBuilder,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ApplicationSettingsPage(
          settings: settings,
          controller: shell,
          logsBuilder: logsBuilder,
          logsActionBuilder: logsActionBuilder,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openData(
  WidgetTester tester,
  _FakeSettings settings,
  _FakeShell shell,
) async {
  await _pumpSettings(tester, settings, shell);
  await _tap(
    tester,
    find.byKey(const ValueKey('settings-section-dataPrivacy')),
  );
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  expect(finder.hitTestable(), findsOneWidget);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

final class _FakeSettings extends ChangeNotifier
    implements ApplicationSettingsPort {
  _FakeSettings({
    int materials = 0,
    bool knowledgeLoading = false,
    MaintenanceProgress maintenance = const MaintenanceProgress(),
    bool snapshotAvailable = true,
    SettingsFailureCode? failure,
  }) : _view = ApplicationSettingsView(
         snapshot: snapshotAvailable ? _snapshot(materials: materials) : null,
         knowledgeLoading: knowledgeLoading,
         maintenance: maintenance,
         failure: failure,
       );

  SettingsContext context = const SettingsContext(
    owner: 'synthetic-owner',
    resetEpoch: 1,
    agendaEpoch: 2,
    revision: 3,
  );
  ApplicationSettingsView _view;
  int refreshCalls = 0;
  int loadCalls = 0;
  int cancelCalls = 0;
  int clearKnowledgeCalls = 0;
  int retryCalls = 0;
  final List<(SettingsContext, DisplayPreferences)> preferenceWrites = [];
  final List<(SettingsContext, MaintenanceKind, bool)> maintenanceWrites = [];
  final List<(SettingsContext, bool, bool)> consentWrites = [];
  final List<SettingsContext> clearContexts = [];
  final List<bool> clearConfirmations = [];

  @override
  ApplicationSettingsView get settingsView => _view;

  @override
  Future<void> refreshSettings() async {
    refreshCalls++;
  }

  @override
  Future<void> saveDisplayPreferences(
    SettingsContext context,
    DisplayPreferences preferences,
  ) async {
    preferenceWrites.add((context, preferences));
    final old = _view.snapshot!;
    _view = ApplicationSettingsView(
      snapshot: _withSnapshot(old, preferences: preferences),
      maintenance: _view.maintenance,
      loadOutcome: _view.loadOutcome,
      knowledgeLoading: _view.knowledgeLoading,
    );
    notifyListeners();
  }

  @override
  Future<void> runMaintenance(
    SettingsContext context,
    MaintenanceKind kind, {
    required bool confirmed,
  }) async {
    maintenanceWrites.add((context, kind, confirmed));
  }

  @override
  Future<void> clearKnowledge(
    SettingsContext context, {
    required bool confirmed,
  }) async {
    clearKnowledgeCalls++;
    clearContexts.add(context);
    clearConfirmations.add(confirmed);
  }

  @override
  Future<void> loadKnowledge() async {
    loadCalls++;
    _view = ApplicationSettingsView(
      snapshot: _view.snapshot,
      knowledgeLoading: false,
      maintenance: _view.maintenance,
      loadOutcome: const KnowledgeLoadOutcome(
        state: KnowledgeLoadState.failed,
        accepted: 1,
        unchanged: 2,
        total: 7,
        failure: PublicFailureCode.storageFailed,
      ),
    );
    notifyListeners();
  }

  @override
  Future<void> cancelKnowledgeLoad() async {
    cancelCalls++;
    _view = ApplicationSettingsView(
      snapshot: _view.snapshot,
      knowledgeLoading: false,
      maintenance: _view.maintenance,
      loadOutcome: const KnowledgeLoadOutcome(
        state: KnowledgeLoadState.cancelled,
        accepted: 1,
        unchanged: 1,
        total: 7,
      ),
    );
    notifyListeners();
  }

  @override
  Future<void> setIcourseConsent(
    SettingsContext context, {
    required bool allowed,
    required bool confirmed,
  }) async {
    consentWrites.add((context, allowed, confirmed));
    final old = _view.snapshot!;
    _view = ApplicationSettingsView(
      snapshot: SettingsSnapshot(
        context: old.context,
        preferences: old.preferences,
        counts: old.counts,
        accountBound: old.accountBound,
        credentialSaved: old.credentialSaved,
        icourseConsent: allowed,
      ),
      maintenance: _view.maintenance,
      knowledgeLoading: _view.knowledgeLoading,
      loadOutcome: _view.loadOutcome,
    );
    notifyListeners();
  }

  @override
  Future<void> retryMaintenance() async {
    retryCalls++;
    _view = ApplicationSettingsView(
      snapshot: _view.snapshot,
      maintenance: const MaintenanceProgress(phase: MaintenancePhase.cleaning),
    );
    notifyListeners();
  }

  void replaceContext() {
    context = SettingsContext(
      owner: context.owner,
      resetEpoch: context.resetEpoch,
      agendaEpoch: context.agendaEpoch,
      revision: context.revision + 1,
    );
    final old = _view.snapshot!;
    _view = ApplicationSettingsView(
      snapshot: SettingsSnapshot(
        context: context,
        preferences: old.preferences,
        counts: old.counts,
        accountBound: old.accountBound,
        credentialSaved: old.credentialSaved,
        icourseConsent: old.icourseConsent,
      ),
      maintenance: _view.maintenance,
      knowledgeLoading: _view.knowledgeLoading,
      loadOutcome: _view.loadOutcome,
    );
    notifyListeners();
  }

  void recoverSnapshot() {
    _view = ApplicationSettingsView(
      snapshot: _snapshot(),
      maintenance: _view.maintenance,
      knowledgeLoading: _view.knowledgeLoading,
      loadOutcome: _view.loadOutcome,
    );
    notifyListeners();
  }

  void emit({
    KnowledgeLoadOutcome? loadOutcome,
    MaintenanceProgress? maintenance,
  }) {
    _view = ApplicationSettingsView(
      snapshot: _view.snapshot,
      knowledgeLoading: _view.knowledgeLoading,
      maintenance: maintenance ?? _view.maintenance,
      loadOutcome: loadOutcome ?? _view.loadOutcome,
    );
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SettingsSnapshot _snapshot({
  int materials = 0,
  DisplayPreferences preferences = const DisplayPreferences(),
}) => SettingsSnapshot(
  context: const SettingsContext(
    owner: 'synthetic-owner',
    resetEpoch: 1,
    agendaEpoch: 2,
    revision: 3,
  ),
  preferences: preferences,
  counts: LocalDataCounts(materials: materials),
  accountBound: false,
  credentialSaved: false,
  icourseConsent: false,
);

SettingsSnapshot _withSnapshot(
  SettingsSnapshot snapshot, {
  required DisplayPreferences preferences,
}) => SettingsSnapshot(
  context: snapshot.context,
  preferences: preferences,
  counts: snapshot.counts,
  accountBound: snapshot.accountBound,
  credentialSaved: snapshot.credentialSaved,
  icourseConsent: snapshot.icourseConsent,
);

final class _FakeShell extends ChangeNotifier implements AppShellPort {
  final _FakeJwPort _jw = _FakeJwPort();
  final _FakeYoungPort _young = _FakeYoungPort();
  bool globallyBusy = false;
  bool actionPending = false;
  bool progressUnavailable = false;

  @override
  JwSyncPort get jw => _jw;
  @override
  YoungSyncPort get young => _young;
  @override
  DateTime get today => DateTime.utc(2026, 10, 13);
  @override
  AppShellView get view => AppShellView(
    jw: _jw.syncView,
    young: _young.syncView,
    globallyBusy: globallyBusy,
    actionPending: actionPending,
    progressUnavailable: progressUnavailable,
  );

  @override
  AgendaSlice readAgenda({
    required DateTime day,
    AgendaFilter filter = AgendaFilter.all,
    bool includeHidden = false,
  }) => AgendaSlice(
    day: day,
    filter: filter,
    includeHidden: includeHidden,
    items: const [],
    matched: 0,
    totalStored: 0,
    ready: true,
    truncated: false,
  );

  @override
  Future<void> setHidden(
    AgendaReference reference, {
    required bool hidden,
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeJwPort implements JwSyncPort {
  @override
  JwSyncView get syncView => JwSyncView();
  @override
  Stream<JwSyncView> get syncChanges => const Stream<JwSyncView>.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeYoungPort implements YoungSyncPort {
  @override
  YoungSyncView get syncView => YoungSyncView();
  @override
  Stream<YoungSyncView> get syncChanges => const Stream<YoungSyncView>.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
