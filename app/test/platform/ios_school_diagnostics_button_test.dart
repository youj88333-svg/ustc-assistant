import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/ios_school_diagnostics_button.dart';

const _channel = MethodChannel('ustc_assistant/platform_v1');
const _schema = 'ios-i2-browser-diagnostics-v1';

void main() {
  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('copies a validated projection with exactly the fixed schema', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    final clipboard = <String>[];
    var requests = 0;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      requests++;
      expect(call.method, 'i2BrowserDiagnostics');
      expect(call.arguments, isNull);
      return _validResponse();
    });
    _captureClipboard(messenger, clipboard);

    await tester.pumpWidget(_host());
    expect(requests, 0);
    await tester.tap(find.byKey(const ValueKey('ios-i2-copy-diagnostics')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(requests, 1);
    expect(clipboard, hasLength(1));
    final copied = jsonDecode(clipboard.single) as Map<String, dynamic>;
    expect(copied.keys.toSet(), _validResponse().keys.toSet());
    expect(copied, _validResponse());
    expect(find.text('已复制同步诊断，不含账号和网页内容。'), findsOneWidget);
  });

  testWidgets('rejects unknown raw fields without copying or exposing them', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    final clipboard = <String>[];
    const privateUrl = 'https://jw.ustc.edu.cn/path?ticket=private-value';
    messenger.setMockMethodCallHandler(_channel, (call) async {
      return <String, Object?>{
        ..._validResponse(),
        'url': privateUrl,
        'accountCode': 'PRIVATE_ACCOUNT',
      };
    });
    _captureClipboard(messenger, clipboard);

    await tester.pumpWidget(_host());
    await tester.tap(find.byKey(const ValueKey('ios-i2-copy-diagnostics')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(clipboard, isEmpty);
    expect(find.text('未能复制诊断，请重试。'), findsOneWidget);
    expect(find.textContaining(privateUrl), findsNothing);
    expect(find.textContaining('PRIVATE_ACCOUNT'), findsNothing);
  });

  testWidgets('rejects invalid enum values and boolean error codes', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    final clipboard = <String>[];
    final responses = <Map<String, Object?>>[
      <String, Object?>{..._validResponse(), 'source': 'unrecognized'},
      <String, Object?>{..._validResponse(), 'errorCode': true},
    ];
    var requests = 0;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      final response = responses[requests];
      requests++;
      return response;
    });
    _captureClipboard(messenger, clipboard);

    await tester.pumpWidget(_host());
    for (var index = 0; index < responses.length; index++) {
      await tester.tap(find.byKey(const ValueKey('ios-i2-copy-diagnostics')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      if (index + 1 < responses.length) await tester.pumpWidget(_host());
    }

    expect(requests, responses.length);
    expect(clipboard, isEmpty);
    expect(find.text('未能复制诊断，请重试。'), findsOneWidget);
  });

  testWidgets('coalesces concurrent taps into one native request', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    final clipboard = <String>[];
    final response = Completer<Object?>();
    var requests = 0;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      requests++;
      return response.future;
    });
    _captureClipboard(messenger, clipboard);

    await tester.pumpWidget(_host());
    final button = find.byKey(const ValueKey('ios-i2-copy-diagnostics'));
    await tester.tap(button);
    await tester.tap(button);
    await tester.pump();

    expect(requests, 1);
    expect(_diagnosticsButton(tester).onPressed, isNull);

    response.complete(_validResponse());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(requests, 1);
    expect(clipboard, hasLength(1));
  });
}

Map<String, Object?> _validResponse() => <String, Object?>{
  'kind': _schema,
  'source': 'jw',
  'state': 'open',
  'lastEvent': 'ready',
  'failureStage': 'none',
  'errorDomain': 'none',
  'errorCode': null,
  'cleanupStage': 'none',
  'cleanupFailure': 'none',
  'cleanupErrorDomain': 'none',
  'cleanupErrorCode': null,
};

Widget _host() => MaterialApp(
  home: Scaffold(
    appBar: AppBar(actions: [const IOSSchoolDiagnosticsButton()]),
    body: const SizedBox.expand(),
  ),
);

void _captureClipboard(
  TestDefaultBinaryMessenger messenger,
  List<String> clipboard,
) {
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      final arguments = call.arguments as Map<Object?, Object?>;
      clipboard.add(arguments['text'] as String);
    }
    return null;
  });
}

TextButton _diagnosticsButton(WidgetTester tester) =>
    tester.widget(find.byKey(const ValueKey('ios-i2-copy-diagnostics')));
