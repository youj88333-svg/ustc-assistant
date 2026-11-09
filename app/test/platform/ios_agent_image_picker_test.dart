import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/diagnostics_contract.dart';
import 'package:ustc_assistant_m0/platform/ios_agent_image_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('synthetic/ios_agent_images');
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('loads normalized PNGs through the fixed no-argument method', () async {
    final bytes = _onePixelPng();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) {
      expect(call.method, 'pickImages');
      expect(call.arguments, isNull);
      return Future.value([bytes]);
    });
    final diagnostics = _RecordingDiagnostics();

    final images = await IOSAgentImagePicker(
      channel: channel,
    ).pickImages(diagnostics: diagnostics);

    expect(images, hasLength(1));
    expect(images.single.width, 1);
    expect(images.single.height, 1);
    expect(identical(images.single.bytes, bytes), isFalse);
    expect(
      diagnostics.events.map((event) => (event.stage, event.outcome)).toList(),
      [
        (DiagnosticStage.imagePicker, DiagnosticOutcome.started),
        (DiagnosticStage.imagePicker, DiagnosticOutcome.complete),
        (DiagnosticStage.imageNormalization, DiagnosticOutcome.started),
        (DiagnosticStage.imageNormalization, DiagnosticOutcome.complete),
      ],
    );
  });

  test('user cancellation is an empty result and a fixed diagnostic', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      expect(call.method, 'pickImages');
      expect(call.arguments, isNull);
      return <Uint8List>[];
    });
    final diagnostics = _RecordingDiagnostics();

    expect(
      await IOSAgentImagePicker(
        channel: channel,
      ).pickImages(diagnostics: diagnostics),
      isEmpty,
    );
    expect(diagnostics.events, hasLength(2));
    expect(diagnostics.events.last.stage, DiagnosticStage.imagePicker);
    expect(diagnostics.events.last.outcome, DiagnosticOutcome.cancelled);
    expect(diagnostics.events.last.count, 0);
  });

  test(
    'closed native error codes map without carrying platform details',
    () async {
      const cases = <(String, AgentFailureCode, DiagnosticCode)>[
        ('cancelled', AgentFailureCode.cancelled, DiagnosticCode.cancelled),
        (
          'resource_limit',
          AgentFailureCode.resourceLimit,
          DiagnosticCode.resourceLimit,
        ),
        ('busy', AgentFailureCode.busy, DiagnosticCode.busy),
        (
          'unavailable',
          AgentFailureCode.toolUnavailable,
          DiagnosticCode.toolUnavailable,
        ),
        (
          'invalid_input',
          AgentFailureCode.invalidInput,
          DiagnosticCode.invalidInput,
        ),
        (
          'read_failed',
          AgentFailureCode.imageRejected,
          DiagnosticCode.imageReadFailed,
        ),
        (
          'synthetic-private-code',
          AgentFailureCode.imageRejected,
          DiagnosticCode.unknown,
        ),
      ];

      for (final (code, expectedFailure, expectedDiagnostic) in cases) {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (_) async => throw PlatformException(
            code: code,
            message: 'private://photos/personal.heic',
            details: {'path': r'/private/personal.heic'},
          ),
        );
        final diagnostics = _RecordingDiagnostics();

        await expectLater(
          IOSAgentImagePicker(
            channel: channel,
          ).pickImages(diagnostics: diagnostics),
          throwsA(
            isA<AgentFailure>()
                .having((failure) => failure.code, 'code', expectedFailure)
                .having(
                  (failure) => failure.toString(),
                  'safe failure',
                  isNot(contains('personal.heic')),
                ),
          ),
        );
        final event = diagnostics.events.last;
        expect(
          event.outcome,
          expectedFailure == AgentFailureCode.cancelled
              ? DiagnosticOutcome.cancelled
              : DiagnosticOutcome.failure,
        );
        expect(event.code, expectedDiagnostic);
        final record = DiagnosticRecord(
          atUtc: DateTime.utc(2026, 11, 9),
          event: event,
        ).encode();
        expect(record, isNot(contains('private://')));
        expect(record, isNot(contains('/private/')));
        if (expectedDiagnostic == DiagnosticCode.unknown) {
          expect(record, isNot(contains(code)));
        }
      }
    },
  );

  test('rejects malformed, excessive, and oversized channel results', () async {
    final oversizedTotal = List.generate(
      AgentImage.maximumCount,
      (_) => Uint8List(2 * 1024 * 1024 + 1),
    );
    final cases = <(Object?, AgentFailureCode)>[
      ('/private/photo.heic', AgentFailureCode.invalidInput),
      ([Uint8List(0)], AgentFailureCode.invalidInput),
      (
        List.generate(AgentImage.maximumCount + 1, (_) => Uint8List(1)),
        AgentFailureCode.resourceLimit,
      ),
      (
        [Uint8List(AgentImage.maximumBytes + 1)],
        AgentFailureCode.resourceLimit,
      ),
      (oversizedTotal, AgentFailureCode.resourceLimit),
    ];

    for (final (response, expected) in cases) {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => response,
      );
      await expectLater(
        IOSAgentImagePicker(channel: channel).pickImages(),
        throwsA(
          isA<AgentFailure>().having(
            (failure) => failure.code,
            'code',
            expected,
          ),
        ),
      );
    }
  });

  test(
    'second-source failure drains source copies and partial normalized output',
    () async {
      final borrowed = [_onePixelPng(), _onePixelPng()];
      final sourceCopies = <Uint8List>[];
      final partialImage = AgentImage(_onePixelPng());
      var normalizeCount = 0;
      final picker = IOSAgentImagePicker(
        channel: _DirectIOSImageChannel((method, arguments) async {
          expect(method, 'pickImages');
          expect(arguments, isNull);
          return borrowed;
        }),
        normalizeImage: (source) async {
          sourceCopies.add(source);
          normalizeCount++;
          if (normalizeCount == 1) return partialImage;
          throw const AgentFailure(AgentFailureCode.invalidInput);
        },
      );

      await expectLater(
        picker.pickImages(),
        throwsA(
          isA<AgentFailure>().having(
            (failure) => failure.code,
            'code',
            AgentFailureCode.invalidInput,
          ),
        ),
      );
      expect(
        borrowed.every((buffer) => buffer.every((byte) => byte == 0)),
        isTrue,
      );
      expect(sourceCopies, hasLength(2));
      expect(
        sourceCopies.every((buffer) => buffer.every((byte) => byte == 0)),
        isTrue,
      );
      expect(partialImage.bytes, everyElement(0));
    },
  );

  test('cancel uses its fixed no-argument bridge method', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      expect(call.method, 'cancel');
      expect(call.arguments, isNull);
      return null;
    });

    await IOSAgentImagePicker(channel: channel).cancel();
  });

  test(
    'late cancellation drains copies and both partial normalized images',
    () async {
      final borrowed = [_onePixelPng(), _onePixelPng()];
      final sourceCopies = <Uint8List>[];
      final firstImage = AgentImage(_onePixelPng());
      final normalizationOfSecondStarted = Completer<void>();
      final finishNormalization = Completer<AgentImage>();
      final picker = IOSAgentImagePicker(
        channel: _DirectIOSImageChannel((method, arguments) async {
          expect(arguments, isNull);
          if (method == 'pickImages') return borrowed;
          expect(method, 'cancel');
          return null;
        }),
        normalizeImage: (source) {
          sourceCopies.add(source);
          if (sourceCopies.length == 1) return Future.value(firstImage);
          normalizationOfSecondStarted.complete();
          return finishNormalization.future;
        },
      );
      final lateImage = AgentImage(_onePixelPng());

      final picking = picker.pickImages();
      await normalizationOfSecondStarted.future;
      await picker.cancel();
      finishNormalization.complete(lateImage);

      await expectLater(
        picking,
        throwsA(
          isA<AgentFailure>().having(
            (failure) => failure.code,
            'code',
            AgentFailureCode.cancelled,
          ),
        ),
      );
      expect(
        borrowed.every((buffer) => buffer.every((byte) => byte == 0)),
        isTrue,
      );
      expect(sourceCopies, hasLength(2));
      expect(
        sourceCopies.every((buffer) => buffer.every((byte) => byte == 0)),
        isTrue,
      );
      expect(firstImage.bytes, everyElement(0));
      expect(lateImage.bytes, everyElement(0));
    },
  );
}

Uint8List _onePixelPng() => Uint8List.fromList(_png(1, 1));

Uint8List _png(int width, int height) {
  final rowBytes = width * 4 + 1;
  final raw = Uint8List(rowBytes * height);
  for (var row = 0; row < height; row++) {
    raw[row * rowBytes] = 0;
    for (var pixel = 0; pixel < width; pixel++) {
      raw[row * rowBytes + 1 + pixel * 4 + 3] = 0xff;
    }
  }

  final header = Uint8List(13);
  final dimensions = ByteData.sublistView(header);
  dimensions.setUint32(0, width, Endian.big);
  dimensions.setUint32(4, height, Endian.big);
  header[8] = 8;
  header[9] = 6;

  final builder = BytesBuilder(copy: false)
    ..add(const [137, 80, 78, 71, 13, 10, 26, 10])
    ..add(_pngChunk('IHDR', header))
    ..add(_pngChunk('IDAT', ZLibCodec().encode(raw)))
    ..add(_pngChunk('IEND', const []));
  return builder.takeBytes();
}

Uint8List _pngChunk(String type, List<int> data) {
  final typeBytes = type.codeUnits;
  final crc = _crc32([...typeBytes, ...data]);
  final output = Uint8List(12 + data.length);
  final bytes = ByteData.sublistView(output);
  bytes.setUint32(0, data.length, Endian.big);
  output.setRange(4, 8, typeBytes);
  output.setRange(8, 8 + data.length, data);
  bytes.setUint32(8 + data.length, crc, Endian.big);
  return output;
}

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

final class _DirectIOSImageChannel extends MethodChannel {
  _DirectIOSImageChannel(this.handler) : super('synthetic/direct_ios_images');

  final Future<Object?> Function(String method, Object? arguments) handler;

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    return await handler(method, arguments) as T?;
  }
}

final class _RecordingDiagnostics implements DiagnosticsPort {
  final events = <DiagnosticEvent>[];

  @override
  DiagnosticsView get diagnosticsView => const DiagnosticsView(available: true);

  @override
  DiagnosticTrace newTrace() =>
      DiagnosticTrace('00000000000000000000000000000000');

  @override
  void record(DiagnosticEvent event) => events.add(event);

  @override
  Future<void> flush() async {}

  @override
  Future<String> exportRecent() async => '';

  @override
  Future<void> clear() async => events.clear();

  @override
  Future<void> close() async {}
}
