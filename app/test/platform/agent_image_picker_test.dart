import 'dart:typed_data';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/diagnostics_contract.dart';
import 'package:ustc_assistant_m0/platform/agent_image_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Android normalization wipes every original on success and failure',
    () async {
      final original = _png(2, 2, includeTextMetadata: true);
      final result = await normalizeAndroidImages([original]);
      expect(result.single.width, 2);
      expect(original, everyElement(0));
      expect(_chunkTypes(result.single.bytes), isNot(contains('tEXt')));
      final good = _png(2, 2);
      final bad = Uint8List.fromList([1, 2, 3]);
      await expectLater(
        normalizeAndroidImages([good, bad]),
        _failsWith(AgentFailureCode.invalidInput),
      );
      expect(good, everyElement(0));
      expect(bad, everyElement(0));
    },
  );

  test(
    'rejects an original image larger than 10 MiB before decoding',
    () async {
      final source = Uint8List(10 * 1024 * 1024 + 1);
      await expectLater(
        normalizeAgentImage(source),
        _failsWith(AgentFailureCode.resourceLimit),
      );
    },
  );

  test(
    'rejects unsupported or malformed image bytes with a fixed failure',
    () async {
      await expectLater(
        normalizeAgentImage(Uint8List.fromList([1, 2, 3, 4, 5])),
        _failsWith(AgentFailureCode.invalidInput),
      );
    },
  );

  test('rejects decoded dimensions above 16 million pixels', () async {
    final oversizedDimensions = _png(
      4001,
      4000,
      encodedWidth: 1,
      encodedHeight: 1,
    );
    await expectLater(
      normalizeAgentImage(oversizedDimensions),
      _failsWith(AgentFailureCode.resourceLimit),
    );
  });

  test('resizes the long side and re-encodes a metadata-free PNG', () async {
    final normalized = await normalizeAgentImage(
      _png(2048, 4, includeTextMetadata: true),
    );
    expect(normalized.width, 1536);
    expect(normalized.height, 3);
    expect(normalized.bytes.length, lessThanOrEqualTo(AgentImage.maximumBytes));
    expect(_chunkTypes(normalized.bytes), isNot(contains('tEXt')));
  });

  test('animated image frame counts are rejected', () {
    expect(
      () => validateAgentImageFrameCount(2),
      _throwsWith(AgentFailureCode.invalidInput),
    );
    expect(() => validateAgentImageFrameCount(1), returnsNormally);
  });

  test(
    'Android normalization logs fixed stages and bounded image counts',
    () async {
      final diagnostics = _RecordingDiagnostics();
      final original = _png(2, 2);
      final normalized = await normalizeAndroidImages([
        original,
      ], diagnostics: diagnostics);

      expect(normalized.single.width, 2);
      expect(diagnostics.events.map((event) => event.outcome), [
        DiagnosticOutcome.started,
        DiagnosticOutcome.complete,
      ]);
      expect(
        diagnostics.events.every(
          (event) =>
              event.name == DiagnosticEventName.imageInputStage &&
              event.stage == DiagnosticStage.imageNormalization,
        ),
        isTrue,
      );
      expect(diagnostics.events.last.count, 1);
      expect(original, everyElement(0));

      diagnostics.events.clear();
      final malformed = Uint8List.fromList([1, 2, 3]);
      await expectLater(
        normalizeAndroidImages([malformed], diagnostics: diagnostics),
        _failsWith(AgentFailureCode.invalidInput),
      );
      expect(diagnostics.events.map((event) => event.outcome), [
        DiagnosticOutcome.started,
        DiagnosticOutcome.failure,
      ]);
      expect(diagnostics.events.last.code, DiagnosticCode.invalidInput);
      expect(diagnostics.events.last.count, 1);
      expect(malformed, everyElement(0));

      diagnostics.events.clear();
      final tooMany = List.generate(
        AgentImage.maximumCount + 1,
        (_) => _png(1, 1),
      );
      await expectLater(
        normalizeAndroidImages(tooMany, diagnostics: diagnostics),
        _failsWith(AgentFailureCode.resourceLimit),
      );
      expect(diagnostics.events.last.code, DiagnosticCode.resourceLimit);
      expect(diagnostics.events.last.count, AgentImage.maximumCount);
      expect(
        tooMany.every((bytes) => bytes.every((byte) => byte == 0)),
        isTrue,
      );

      final safeRecords = diagnostics.events.map((event) {
        return DiagnosticRecord(
          atUtc: DateTime.utc(2026, 10, 21),
          event: event,
        ).encode();
      }).join();
      expect(safeRecords, isNot(contains('image bytes')));
    },
  );
}

Matcher _failsWith(AgentFailureCode code) => throwsA(
  isA<AgentFailure>().having((failure) => failure.code, 'code', code),
);

Matcher _throwsWith(AgentFailureCode code) => throwsA(
  isA<AgentFailure>().having((failure) => failure.code, 'code', code),
);

Uint8List _png(
  int width,
  int height, {
  int? encodedWidth,
  int? encodedHeight,
  bool includeTextMetadata = false,
}) {
  final pixelWidth = encodedWidth ?? width;
  final pixelHeight = encodedHeight ?? height;
  final rowBytes = pixelWidth * 4 + 1;
  final raw = Uint8List(rowBytes * pixelHeight);
  for (var row = 0; row < pixelHeight; row++) {
    raw[row * rowBytes] = 0;
    for (var pixel = 0; pixel < pixelWidth; pixel++) {
      raw[row * rowBytes + 1 + pixel * 4 + 3] = 0xff;
    }
  }
  final ihdr = Uint8List(13);
  final dimensions = ByteData.sublistView(ihdr);
  dimensions.setUint32(0, width, Endian.big);
  dimensions.setUint32(4, height, Endian.big);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // RGBA
  ihdr[10] = 0;
  ihdr[11] = 0;
  ihdr[12] = 0;

  final builder = BytesBuilder(copy: false)
    ..add(const [137, 80, 78, 71, 13, 10, 26, 10])
    ..add(_chunk('IHDR', ihdr));
  if (includeTextMetadata) {
    builder.add(
      _chunk('tEXt', [
        0x6e,
        0x6f,
        0x74,
        0x65,
        0x00,
        0x73,
        0x79,
        0x6e,
        0x74,
        0x68,
        0x65,
        0x74,
        0x69,
        0x63,
      ]),
    );
  }
  builder
    ..add(_chunk('IDAT', Uint8List.fromList(ZLibCodec().encode(raw))))
    ..add(_chunk('IEND', const []));
  return builder.takeBytes();
}

Uint8List _chunk(String type, List<int> data) {
  final typeBytes = type.codeUnits;
  final crcBytes = [...typeBytes, ...data];
  final crc = _crc32(crcBytes);
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

List<String> _chunkTypes(Uint8List png) {
  final chunks = <String>[];
  var offset = 8;
  while (offset + 12 <= png.length) {
    final length = ByteData.sublistView(png, offset, offset + 4).getUint32(0);
    if (offset + 12 + length > png.length) break;
    chunks.add(String.fromCharCodes(png.sublist(offset + 4, offset + 8)));
    offset += 12 + length;
  }
  return chunks;
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
