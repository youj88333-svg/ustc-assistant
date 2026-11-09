import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/ios_i4_entry.dart';
import 'package:ustc_assistant_m0/platform/ios_agent_host_lifecycle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final revision = List.filled(40, 'a').join();
  Map<String, Object?> metadata() => {
    'revision': revision,
    'bundleId': 'cn.ustcassistant.ios.private.SYNTHETIC',
    'version': '0.4.0',
    'buildNumber': '4001',
    'authentication': 'manual',
    'notificationBackend': 'user-notifications-v1',
    'imagePicker': 'photosui-imageio-v1',
  };
  test(
    'private build metadata preserves the resigned identity and actual version',
    () {
      final text = iosI4BuildInformation(
        metadata(),
        expectedRevision: revision,
      );
      expect(text, contains('0.4.0 (4001)'));
      expect(text, contains('private.SYNTHETIC'));
      expect(text, contains('一致'));
    },
  );
  test(
    'stale or unexpected native metadata cannot open an ordinary product runtime',
    () {
      final examples = <Object?>[
        null,
        {...metadata(), 'revision': List.filled(40, 'b').join()},
        {...metadata(), 'path': '/untrusted'},
        {...metadata(), 'imagePicker': 'unbounded-library'},
        {...metadata(), 'authentication': 'automatic'},
        {...metadata(), 'notificationBackend': 'unknown'},
        {...metadata(), 'bundleId': ''},
        {...metadata(), 'version': 'malformed'},
        {...metadata(), 'buildNumber': 4001},
        {...metadata(), 'revision': 'unknown'},
      ];
      for (final example in examples) {
        expect(
          () => iosI4BuildInformation(example, expectedRevision: revision),
          throwsA(
            isA<AppFailure>().having(
              (failure) => failure.code,
              'code',
              FailureCode.invalidSnapshot,
            ),
          ),
        );
      }
    },
  );

  test(
    'UIKit activity is a closed protocol and distinguishes modal inactivity from revocation',
    () async {
      const channelName = 'ustc_assistant/ios_host_lifecycle_v1';
      const methods = MethodChannel(channelName);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(methods, (call) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(methods, null));
      final values = <IOSAgentHostState>[];
      final failures = <Object>[];
      final subscription = const IOSAgentHostLifecycle().changes.listen(
        values.add,
        onError: failures.add,
      );
      await Future<void>.delayed(Duration.zero);
      Future<void> push(Object? value) async {
        final completed = Completer<void>();
        messenger.handlePlatformMessage(
          channelName,
          const StandardMethodCodec().encodeSuccessEnvelope(value),
          (_) => completed.complete(),
        );
        await completed.future;
        await Future<void>.delayed(Duration.zero);
      }

      await push('active');
      await push('inactive');
      await push('revoked');
      await push('unexpected-state');
      expect(values, [
        IOSAgentHostState.active,
        IOSAgentHostState.inactive,
        IOSAgentHostState.revoked,
      ]);
      expect(failures, hasLength(1));
      expect(failures.single, isA<FormatException>());
      await subscription.cancel();
    },
  );
}
