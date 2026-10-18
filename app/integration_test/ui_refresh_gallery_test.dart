import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/core/agent_contract.dart';

import 'support/ui_refresh_fixtures.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  uiRefreshGalleryScenarios();
}

/// The same interaction sequence can be checked quickly by widget tests and
/// then rendered by each native runner with its actual fonts.
void uiRefreshGalleryScenarios({bool? phoneLayout}) {
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets(
    'production shell renders and keeps the synthetic cross-platform gallery reachable (${phoneLayout ?? 'native'})',
    (tester) async {
      final fixture = UiRefreshGalleryFixture(startWithApproval: false);
      addTearDown(fixture.dispose);
      final phone =
          phoneLayout ?? defaultTargetPlatform == TargetPlatform.android;
      final surfaceSize = phone ? const Size(360, 780) : const Size(1280, 800);
      tester.view.physicalSize = surfaceSize;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(fixture.buildApp());
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('agent-message-list')), findsOneWidget);
      expect(find.textContaining('周一上午有两项日程重叠'), findsOneWidget);
      await _captureSyntheticUi(tester, 'agent-default');
      await _tapKey(tester, 'agent-reasoning-toggle-2');
      await _tapKey(
        tester,
        'agent-query-details-toggle-ui-refresh-synthetic-conversation:2',
      );
      expect(find.byKey(const ValueKey('agent-tool-steps')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('agent-evidence-ui-refresh-evidence')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('agent-action-approve-gallery-approval')),
        findsNothing,
      );
      await _closeApprovalSheet(tester);
      await _captureSyntheticUi(tester, 'agent-dialogue');

      await _tapKey(tester, 'morning-brief-open');
      expect(
        find.byKey(const ValueKey('morning-brief-full-summary')),
        findsOneWidget,
      );
      await _captureSyntheticUi(tester, 'morning-default');
      await _tapKey(tester, 'morning-brief-agenda-expand');
      expect(find.text('合成高等数学'), findsWidgets);
      await _captureSyntheticUi(tester, 'morning-details');
      await _tapKey(tester, 'morning-brief-details-close');

      fixture.agent.offerApproval('gallery-approval');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('agent-action-approve-gallery-approval')),
        findsOneWidget,
      );
      if (phone) {
        expect(
          find.byKey(const ValueKey('agent-current-approval-panel')),
          findsOneWidget,
        );
      }
      await _captureSyntheticUi(tester, 'agent-current-approval');
      if (phone) {
        await _tapKey(tester, 'agent-approval-sheet-close');
        expect(
          find.byKey(const ValueKey('agent-current-approval-panel')),
          findsNothing,
        );
        await _tapKey(tester, 'agent-current-approval-open');
        expect(
          find.byKey(const ValueKey('agent-current-approval-panel')),
          findsOneWidget,
        );
      }
      await _tapKey(tester, 'agent-action-approve-gallery-approval');
      expect(fixture.agent.approvedActionIds, ['gallery-approval']);
      expect(fixture.agent.view.pendingAction, isNull);
      expect(
        fixture.agent.view.messages.last.actions.single.status,
        AgentActionStatus.committed,
      );
      expect(
        find.byKey(const ValueKey('agent-action-approve-gallery-approval')),
        findsNothing,
      );

      fixture.agent.offerApproval('gallery-rejection');
      await tester.pumpAndSettle();
      await _tapKey(tester, 'agent-action-reject-gallery-rejection');
      expect(fixture.agent.rejectedActionIds, ['gallery-rejection']);
      expect(fixture.agent.view.pendingAction, isNull);
      expect(
        fixture.agent.view.messages.last.actions.single.status,
        AgentActionStatus.rejected,
      );
      expect(
        find.byKey(const ValueKey('agent-action-reject-gallery-rejection')),
        findsNothing,
      );
      await _closeApprovalSheet(tester);

      fixture.agent.offerApproval('gallery-stale-epoch');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('agent-action-approve-gallery-stale-epoch')),
        findsOneWidget,
      );
      fixture.agent.invalidateApprovalByHistoryEpoch();
      await tester.pumpAndSettle();
      expect(fixture.agent.view.settings!.authority.historyEpoch, 2);
      expect(fixture.agent.view.pendingAction, isNull);
      expect(
        find.byKey(const ValueKey('agent-action-approve-gallery-stale-epoch')),
        findsNothing,
      );
      await _closeApprovalSheet(tester);

      await _tapKey(tester, 'shell-nav-settings');
      expect(
        find.byKey(const ValueKey('source-settings-scroll')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('source-settings-jw')), findsOneWidget);
      await _captureSyntheticUi(tester, 'source-settings');
      if (phone) {
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
      }

      await _tapKey(tester, 'shell-nav-agenda');
      expect(
        find.byKey(const ValueKey('calendar-week-horizontal-scroll')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey(fixture.calendar.course.reference)),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey(fixture.calendar.allDay.reference)),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('calendar-task-2026-10-12-701')),
        findsOneWidget,
      );
      if (!phone) {
        expect(find.text('合成高等数学'), findsWidgets);
        expect(find.textContaining('合成全天安排'), findsWidgets);
        expect(find.text('整理实验报告'), findsWidgets);
      }
      expect(
        find.byKey(const ValueKey('calendar-conflict-browser')),
        findsOneWidget,
      );
      expect(find.text('冲突判定 · 1'), findsOneWidget);
      await _captureSyntheticUi(tester, 'calendar-week');

      final courseTile = find.byKey(
        ValueKey(fixture.calendar.course.reference),
      );
      await tester.ensureVisible(courseTile);
      await tester.tap(courseTile);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('calendar-detail-card')),
        findsOneWidget,
      );
      expect(find.textContaining('5304'), findsWidgets);
      expect(
        find.byKey(const ValueKey('calendar-reminder-settings')),
        findsOneWidget,
      );
      await _captureSyntheticUi(tester, 'calendar-course-detail');

      await _tapKey(tester, 'calendar-reminder-settings');
      expect(
        find.byKey(const ValueKey('reminder-editor-save')),
        findsOneWidget,
      );
      expect(find.text('提醒设置'), findsOneWidget);
      expect(find.textContaining('单独的提醒设置'), findsOneWidget);
      await _captureSyntheticUi(tester, 'reminder-form');
      await _tapKey(tester, 'reminder-editor-cancel');
      expect(fixture.reminders.inspectedTargets, 1);
      await _tapKey(tester, 'calendar-detail-close');

      await _tapKey(tester, 'calendar-workspace-tab-tasks');
      expect(find.byKey(const ValueKey('task-detail-title')), findsOneWidget);
      expect(find.text('整理实验报告'), findsWidgets);
      expect(find.textContaining('合成任务备注'), findsOneWidget);
      await _captureSyntheticUi(tester, 'task-detail');

      expect(fixture.unexpectedCalls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey<String>(key));
  expect(finder, findsOneWidget, reason: 'Missing UI refresh key: $key');
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _closeApprovalSheet(WidgetTester tester) async {
  final close = find.byKey(const ValueKey('agent-approval-sheet-close'));
  if (close.evaluate().isNotEmpty) {
    await tester.tap(close);
    await tester.pumpAndSettle();
  }
}

Future<void> _captureSyntheticUi(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('USTC_UI_QA')) return;
  final output = await _uiRefreshGalleryDirectory();
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('ui-refresh-gallery-capture')),
  );
  final image = await boundary.toImage(pixelRatio: 1);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null || bytes.lengthInBytes == 0) {
      throw StateError('Synthetic UI refresh capture was empty: $name');
    }
    await tester.runAsync(() async {
      final file = File(p.join(output.path, '$name.png'));
      await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    });
  } finally {
    image.dispose();
  }
}

Future<Directory> _uiRefreshGalleryDirectory() async {
  if (Platform.isAndroid) {
    final directory = Directory(
      p.join(Directory.systemTemp.path, 'ui-refresh-gallery'),
    );
    final initialType = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (initialType != FileSystemEntityType.notFound &&
        initialType != FileSystemEntityType.directory) {
      throw StateError('Android QA output must be a plain temp directory.');
    }
    await directory.create(recursive: true);
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        !p.posix.equals(
          p.normalize(await directory.resolveSymbolicLinks()),
          p.normalize(directory.path),
        )) {
      throw StateError('Android QA output must be a plain temp directory.');
    }
    return directory;
  }
  if (!Platform.isWindows) {
    throw StateError(
      'UI refresh gallery captures are supported on Windows and Android.',
    );
  }

  const configured = String.fromEnvironment('USTC_UI_QA_DIR');
  final packageRoot = await _packageRoot(configured);
  final expected = p.windows.normalize(
    p.windows.join(packageRoot, 'build', 'ui-refresh'),
  );
  final supplied = p.windows.normalize(p.windows.absolute(configured));
  if (configured.isEmpty ||
      !p.windows.isAbsolute(configured) ||
      RegExp(r'(^|[\\/])\.\.([\\/]|$)').hasMatch(configured) ||
      !p.windows.equals(supplied, expected)) {
    throw StateError(
      'Set USTC_UI_QA_DIR to this package absolute build/ui-refresh directory.',
    );
  }

  final packageDirectory = Directory(packageRoot);
  if (!p.windows.equals(
    p.windows.normalize(await packageDirectory.resolveSymbolicLinks()),
    packageRoot,
  )) {
    throw StateError('The app package root must not resolve through a link.');
  }
  final buildDirectory = Directory(p.windows.dirname(expected));
  await buildDirectory.create(recursive: true);
  if (await FileSystemEntity.type(buildDirectory.path, followLinks: false) !=
          FileSystemEntityType.directory ||
      !p.windows.equals(
        p.windows.normalize(await buildDirectory.resolveSymbolicLinks()),
        p.windows.normalize(buildDirectory.path),
      )) {
    throw StateError(
      'The UI refresh build directory must be a plain directory.',
    );
  }
  final output = Directory(expected);
  final outputType = await FileSystemEntity.type(
    output.path,
    followLinks: false,
  );
  if (outputType == FileSystemEntityType.link) {
    throw StateError('The UI refresh output must not be a link.');
  }
  await output.create(recursive: true);
  if (await FileSystemEntity.type(output.path, followLinks: false) !=
          FileSystemEntityType.directory ||
      !p.windows.equals(
        p.windows.normalize(await output.resolveSymbolicLinks()),
        expected,
      )) {
    throw StateError(
      'The UI refresh output did not resolve to build/ui-refresh.',
    );
  }
  return output;
}

Future<String> _packageRoot(String configured) async {
  // A native Windows runner starts beside its executable, not in the source
  // package. Derive the package from the explicit QA-only output directory.
  if (configured.isEmpty || !p.windows.isAbsolute(configured)) {
    throw StateError('An absolute app/build/ui-refresh output is required.');
  }
  final output = p.windows.normalize(configured);
  final build = p.windows.dirname(output);
  final packageRoot = p.windows.dirname(build);
  if (p.windows.basename(output) != 'ui-refresh' ||
      p.windows.basename(build) != 'build' ||
      p.windows.basename(packageRoot) != 'app') {
    throw StateError('The output must be the app/build/ui-refresh directory.');
  }
  final manifest = File(p.windows.join(packageRoot, 'pubspec.yaml'));
  if (!await manifest.exists() ||
      !RegExp(
        r'^name:\s*ustc_assistant_m0\s*$',
        multiLine: true,
      ).hasMatch(await manifest.readAsString())) {
    throw StateError('The QA output does not belong to this Flutter package.');
  }
  return packageRoot;
}
