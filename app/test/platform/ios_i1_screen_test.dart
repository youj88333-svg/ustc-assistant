import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/demo_runtime.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/ios_i1_entry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ustc_assistant/platform_v1');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'i1BuildInfo');
      expect(call.arguments, isNull);
      return {'bundleId': 'synthetic.ios.i1', 'revision': 'unknown'};
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  testWidgets('failed startup shows identity, safe stage and working retry', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      IOSI1App(
        openBootstrap: (platform) async {
          attempts++;
          platform.onStartupStage?.call('container');
          throw const AppFailure(FailureCode.unsafeDirectory);
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('应用身份：synthetic.ios.i1'), findsOneWidget);
    expect(find.text('检查阶段：container'), findsOneWidget);
    expect(find.text('检查失败：unsafeDirectory'), findsOneWidget);
    expect(find.textContaining('读取中'), findsNothing);
    expect(attempts, 1);
    final retry = find.widgetWithText(TextButton, '重试启动');
    expect(tester.widget<TextButton>(retry).onPressed, isNotNull);
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });

  testWidgets('native details stay private when showing a fixed failure', (
    tester,
  ) async {
    await tester.pumpWidget(
      IOSI1App(
        openBootstrap: (platform) async {
          platform.onStartupStage?.call('privateRoot');
          throw PlatformException(
            code: 'unsafe_directory',
            message: '/synthetic-private-container/never-show',
            details: 'synthetic-private-detail',
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('检查失败：unsafe_directory'), findsOneWidget);
    expect(find.textContaining('never-show'), findsNothing);
    expect(find.textContaining('synthetic-private-detail'), findsNothing);
  });

  testWidgets('pending open cannot start another owner acquisition', (
    tester,
  ) async {
    final pending = Completer<RuntimeBootstrap>();
    var attempts = 0;
    await tester.pumpWidget(
      IOSI1App(
        openBootstrap: (_) {
          attempts++;
          return pending.future;
        },
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(attempts, 1);
    expect(
      tester.widget<TextButton>(find.byType(TextButton)).onPressed,
      isNull,
    );
    pending.completeError(const AppFailure(FailureCode.unsafeDirectory));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextButton>(find.byType(TextButton)).onPressed,
      isNotNull,
    );
    expect(attempts, 1);
  });
}
