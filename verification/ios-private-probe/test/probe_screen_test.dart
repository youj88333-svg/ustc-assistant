import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ios_i0_probe/main.dart';

const String _channelName = 'ustc_assistant/ios_i0_v1';
const String _revision = '0123456789abcdef0123456789abcdef01234567';
const String _createdAt = '2026-10-26T03:04:05.006Z';

Map<String, Object?> _response({
  String? kind = 'ios-i0-probe-v1',
  String? sourceRevision = _revision,
  String bundleId = 'cn.ustcassistant.ios.i0',
  bool groupAvailable = true,
  String? groupDigest = '0123456789ab',
  String? marker = 'i0-a1b2c3d4',
  String? markerCreatedAt = _createdAt,
  String? failure,
}) {
  return <String, Object?>{
    'kind': kind,
    'sourceRevision': sourceRevision,
    'bundleId': bundleId,
    'groupAvailable': groupAvailable,
    'groupDigest': groupDigest,
    'marker': marker,
    'markerCreatedAt': markerCreatedAt,
    'failure': failure,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'unknown bridge method is rejected before it reaches the platform',
    () async {
      const MethodChannel channel = MethodChannel(_channelName);
      final List<MethodCall> calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            return _response();
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      const MethodChannelProbeGateway gateway = MethodChannelProbeGateway(
        channel: channel,
      );
      await expectLater(
        gateway.invoke('deleteBusinessData'),
        throwsArgumentError,
      );
      expect(calls, isEmpty);
    },
  );

  testWidgets('unknown response kind fails closed', (
    WidgetTester tester,
  ) async {
    const MethodChannel channel = MethodChannel(_channelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (MethodCall call) async => _response(kind: 'future-kind'),
        );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await tester.pumpWidget(
      I0ProbeApp(gateway: MethodChannelProbeGateway(channel: channel)),
    );
    await tester.pumpAndSettle();

    expect(find.text('探针响应无效'), findsOneWidget);
    expect(find.text('已从共享文件读到该值'), findsNothing);
  });

  testWidgets(
    'missing response field is visible as an invalid probe response',
    (WidgetTester tester) async {
      const MethodChannel channel = MethodChannel(_channelName);
      final Map<String, Object?> response = _response()
        ..remove('markerCreatedAt');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (MethodCall call) async => response,
          );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      await tester.pumpWidget(
        I0ProbeApp(gateway: MethodChannelProbeGateway(channel: channel)),
      );
      await tester.pumpAndSettle();

      expect(find.text('探针响应无效'), findsOneWidget);
      expect(find.byKey(const Key('shared-marker')), findsNothing);
    },
  );

  testWidgets('unavailable App Group never appears successful', (
    WidgetTester tester,
  ) async {
    const MethodChannel channel = MethodChannel(_channelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (MethodCall call) async => _response(
            groupAvailable: false,
            groupDigest: null,
            marker: null,
            markerCreatedAt: null,
            failure: 'shared_group_unavailable',
          ),
        );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await tester.pumpWidget(
      I0ProbeApp(gateway: MethodChannelProbeGateway(channel: channel)),
    );
    await tester.pumpAndSettle();

    expect(find.text('共享不可用'), findsOneWidget);
    expect(find.text('尚未读到有效合成值'), findsOneWidget);
    expect(find.text('共享文件已读取'), findsNothing);
    expect(find.byKey(const Key('write-marker-button')), findsOneWidget);
    final FilledButton button = tester.widget<FilledButton>(
      find.byKey(const Key('write-marker-button')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('valid marker and UTC time are shown as a read shared value', (
    WidgetTester tester,
  ) async {
    const MethodChannel channel = MethodChannel(_channelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (MethodCall call) async => _response(),
        );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await tester.pumpWidget(
      I0ProbeApp(gateway: MethodChannelProbeGateway(channel: channel)),
    );
    await tester.pumpAndSettle();

    expect(find.text('i0-a1b2c3d4'), findsOneWidget);
    expect(find.text('生成时间（UTC）：$_createdAt'), findsOneWidget);
    expect(find.text('已从共享文件读到该值'), findsOneWidget);
    expect(find.text('共享容器可访问'), findsOneWidget);
  });

  testWidgets('write and refresh use only argumentless contract methods', (
    WidgetTester tester,
  ) async {
    const MethodChannel channel = MethodChannel(_channelName);
    final List<MethodCall> calls = <MethodCall>[];
    int inspectCount = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          if (call.method == 'inspect') {
            inspectCount += 1;
            if (inspectCount == 1) {
              return _response(
                marker: null,
                markerCreatedAt: null,
                failure: 'snapshot_missing',
              );
            }
            return _response(
              marker: 'i0-ffffffff',
              markerCreatedAt: _createdAt,
            );
          }
          return _response(marker: 'i0-ffffffff', markerCreatedAt: _createdAt);
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await tester.pumpWidget(
      I0ProbeApp(gateway: MethodChannelProbeGateway(channel: channel)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('write-marker-button')));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -1000));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('refresh-button')));
    await tester.pumpAndSettle();

    expect(calls.map((MethodCall call) => call.method), <String>[
      'inspect',
      'writeSyntheticMarker',
      'inspect',
    ]);
    expect(calls.every((MethodCall call) => call.arguments == null), isTrue);
    expect(find.text('i0-ffffffff'), findsOneWidget);
    expect(find.text('已从共享文件读到该值'), findsOneWidget);
  });
}
