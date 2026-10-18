import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/ui_refresh_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets(
    'desktop resizing keeps the conversation draft and both workspaces usable',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = UiRefreshGalleryFixture(startWithApproval: false);
      addTearDown(fixture.dispose);
      tester.view.physicalSize = const Size(1280, 800);
      await tester.pumpWidget(fixture.buildApp());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('agent-composer')),
        '窗口变化后继续写这条消息',
      );

      for (final size in [
        const Size(1024, 768),
        const Size(1280, 800),
        const Size(1440, 900),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('shell-phone-navigation')),
          findsNothing,
        );
        expect(find.text('窗口变化后继续写这条消息'), findsOneWidget);
        await _tapKey(tester, 'shell-nav-agenda');
        expect(
          find.byKey(const ValueKey('calendar-week-horizontal-scroll')),
          findsOneWidget,
        );
        await _tapKey(tester, 'calendar-workspace-tab-tasks');
        expect(find.byKey(const ValueKey('task-detail-title')), findsOneWidget);
        await _tapKey(tester, 'shell-nav-settings');
        expect(
          find.byKey(const ValueKey('source-settings-scroll')),
          findsOneWidget,
        );
        await _tapKey(tester, 'shell-nav-agent');
        expect(find.text('窗口变化后继续写这条消息'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: '$size');
      }
      expect(fixture.unexpectedCalls, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'the shell, week and settings remain usable at phone widths and text scales',
    (tester) async {
      final layoutErrors = <FlutterErrorDetails>[];
      final originalErrorHandler = FlutterError.onError;
      FlutterError.onError = (details) {
        layoutErrors.add(details);
        originalErrorHandler?.call(details);
      };
      addTearDown(() => FlutterError.onError = originalErrorHandler);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      const cases = [
        (size: Size(320, 740), scale: 1.5),
        (size: Size(412, 780), scale: 2.0),
        (size: Size(720, 360), scale: 1.5),
      ];

      for (final item in cases) {
        tester.view.physicalSize = item.size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = item.scale;
        final fixture = UiRefreshGalleryFixture(startWithApproval: false);

        await tester.pumpWidget(fixture.buildApp());
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('shell-phone-navigation')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('agent-composer')), findsOneWidget);
        expect(
          tester.takeException(),
          isNull,
          reason: '${item.size}, scale ${item.scale}',
        );

        await _tapKey(tester, 'shell-nav-agenda');
        expect(
          find.byKey(const ValueKey('calendar-week-horizontal-scroll')),
          findsOneWidget,
        );
        expect(
          tester.takeException(),
          isNull,
          reason:
              'week ${item.size}, scale ${item.scale}\n${layoutErrors.join('\n')}',
        );

        await _tapKey(tester, 'calendar-workspace-tab-tasks');
        expect(find.byKey(const ValueKey('task-detail-title')), findsOneWidget);
        expect(
          tester.takeException(),
          isNull,
          reason: 'tasks ${item.size}, scale ${item.scale}',
        );

        await _tapKey(tester, 'shell-nav-agent');
        await _tapKey(tester, 'shell-nav-settings');
        expect(
          find.byKey(const ValueKey('source-settings-scroll')),
          findsOneWidget,
        );
        expect(
          tester.takeException(),
          isNull,
          reason: 'settings ${item.size}, scale ${item.scale}',
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        fixture.dispose();
      }
    },
  );

  testWidgets('a current phone approval stays reachable above the keyboard', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    const cases = [
      (size: Size(360, 780), scale: 1.0, keyboard: 0.0),
      (size: Size(320, 640), scale: 1.5, keyboard: 220.0),
      (size: Size(412, 780), scale: 2.0, keyboard: 240.0),
      (size: Size(720, 360), scale: 1.5, keyboard: 180.0),
    ];

    for (var index = 0; index < cases.length; index++) {
      final item = cases[index];
      tester.view.physicalSize = item.size;
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = FakeViewPadding(bottom: item.keyboard);
      tester.platformDispatcher.textScaleFactorTestValue = item.scale;
      final fixture = UiRefreshGalleryFixture(startWithApproval: false);

      await tester.pumpWidget(fixture.buildApp());
      await tester.pumpAndSettle();
      final composer = find.byKey(const ValueKey('agent-composer'));
      expect(composer, findsOneWidget);
      await tester.ensureVisible(composer);
      expect(
        tester.getRect(composer).bottom,
        lessThanOrEqualTo(item.size.height - item.keyboard),
        reason: 'composer ${item.size}, scale ${item.scale}',
      );

      final actionId = 'phone-approval-$index';
      fixture.agent.offerApproval(actionId);
      await tester.pumpAndSettle();
      final approve = find.byKey(ValueKey('agent-action-approve-$actionId'));
      final reject = find.byKey(ValueKey('agent-action-reject-$actionId'));
      expect(approve, findsOneWidget);
      expect(reject, findsOneWidget);
      if (item.scale == 1 && item.keyboard == 0) {
        expect(
          tester
              .getSize(
                find.byKey(const ValueKey('agent-current-approval-panel')),
              )
              .height,
          lessThan(item.size.height * .65),
          reason: 'A short plan should not stretch into an almost full sheet.',
        );
      }
      await tester.ensureVisible(approve);
      expect(
        tester.getRect(approve).bottom,
        lessThanOrEqualTo(item.size.height - item.keyboard),
        reason: 'approval ${item.size}, scale ${item.scale}',
      );
      await tester.tap(approve);
      await tester.pumpAndSettle();
      expect(fixture.agent.approvedActionIds, [actionId]);
      expect(fixture.agent.view.pendingAction, isNull);
      expect(
        tester.takeException(),
        isNull,
        reason: '${item.size}, scale ${item.scale}',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      fixture.dispose();
    }
  });
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey<String>(key));
  expect(finder, findsOneWidget, reason: 'Missing responsive UI key: $key');
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}
