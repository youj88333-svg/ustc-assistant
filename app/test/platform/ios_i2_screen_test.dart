import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/demo_runtime.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/ios_i2_entry.dart';

void main() {
  testWidgets(
    'startup failure uses a safe code and a pending open is single-flight',
    (tester) async {
      const platformChannel = MethodChannel('ustc_assistant/platform_v1');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platformChannel, (call) async {
            if (call.method != 'i2BuildInfo') return null;
            return <String, Object?>{
              'revision': '0123456789abcdef',
              'bundleId': 'cn.ustcassistant.ios.private',
              'authentication': 'manual',
              'schoolStore': 'wk-uuid-v1',
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(platformChannel, null),
      );

      final first = Completer<RuntimeBootstrap>();
      final second = Completer<RuntimeBootstrap>();
      var openCount = 0;

      await tester.pumpWidget(
        IOSI2App(
          openBootstrap: (_) {
            openCount++;
            return openCount == 1 ? first.future : second.future;
          },
        ),
      );
      expect(openCount, 1);
      expect(find.byKey(const ValueKey('ios-i2-opening')), findsOneWidget);

      await tester.pump();
      expect(openCount, 1, reason: 'a rebuild must not open another owner');

      first.completeError(const AppFailure(FailureCode.storageFailed));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('安全错误码：storageFailed'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('ios-i2-retry')));
      await tester.pump();
      expect(openCount, 2);
      expect(find.byKey(const ValueKey('ios-i2-opening')), findsOneWidget);

      await tester.pump();
      expect(openCount, 2, reason: 'a pending retry must not open twice');

      second.completeError(const AppFailure(FailureCode.unsupportedPlatform));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('安全错误码：unsupportedPlatform'), findsOneWidget);
    },
  );
}
