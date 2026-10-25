import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

import '../core/agent_contract.dart';
import '../core/diagnostics_contract.dart';
import 'android_file_access.dart';

const _maximumOriginalBytes = 10 * 1024 * 1024;
const _maximumPixels = 16 * 1000 * 1000;
const _maximumLongSide = 1536;

const _agentImageTypes = XTypeGroup(
  label: '图片',
  extensions: ['png', 'jpg', 'jpeg', 'webp'],
  mimeTypes: ['image/png', 'image/jpeg', 'image/webp'],
);

/// Opens the native file selector and returns normalized, bounded PNG images.
/// Paths and plugin exceptions stay inside this adapter.
Future<List<AgentImage>> pickAgentImages({DiagnosticsPort? diagnostics}) async {
  if (Platform.isAndroid) {
    final originals = await AndroidFileAccess(
      diagnostics: diagnostics,
    ).pickImages();
    if (originals.isEmpty) return const [];
    return normalizeAndroidImages(originals, diagnostics: diagnostics);
  }
  final List<XFile> files;
  try {
    files = await openFiles(acceptedTypeGroups: const [_agentImageTypes]);
  } on Object {
    throw const AgentFailure(AgentFailureCode.invalidInput);
  }
  if (files.isEmpty) return const [];
  if (files.length > AgentImage.maximumCount) {
    throw const AgentFailure(AgentFailureCode.resourceLimit);
  }

  final normalized = <AgentImage>[];
  try {
    for (final file in files) {
      // Check the native file size before asking the plugin to allocate bytes.
      final length = await file.length();
      if (length > _maximumOriginalBytes) {
        throw const AgentFailure(AgentFailureCode.resourceLimit);
      }
      final builder = BytesBuilder(copy: false);
      var readLength = 0;
      await for (final chunk in file.openRead()) {
        if (chunk.length > _maximumOriginalBytes - readLength) {
          throw const AgentFailure(AgentFailureCode.resourceLimit);
        }
        readLength += chunk.length;
        builder.add(chunk);
      }
      if (readLength != length) {
        throw const AgentFailure(AgentFailureCode.resourceLimit);
      }
      final bytes = builder.takeBytes();
      try {
        normalized.add(await normalizeAgentImage(bytes));
        final normalizedBytes = normalized.fold<int>(
          0,
          (sum, image) => sum + image.bytes.length,
        );
        if (normalizedBytes > AgentImage.maximumTotalBytes) {
          throw const AgentFailure(AgentFailureCode.resourceLimit);
        }
      } finally {
        bytes.fillRange(0, bytes.length, 0);
      }
    }
    return List.unmodifiable(normalized);
  } on AgentFailure {
    _wipe(normalized);
    rethrow;
  } on Object {
    _wipe(normalized);
    throw const AgentFailure(AgentFailureCode.invalidInput);
  }
}

/// Native Android has already bounded provider reads. The common decoder still
/// enforces single-frame input, strips metadata, and bounds the outgoing bytes.
@visibleForTesting
Future<List<AgentImage>> normalizeAndroidImages(
  List<Uint8List> originals, {
  DiagnosticsPort? diagnostics,
}) async {
  _recordImageNormalizationStage(diagnostics, DiagnosticOutcome.started);
  final normalized = <AgentImage>[];
  try {
    if (originals.length > AgentImage.maximumCount) {
      throw const AgentFailure(AgentFailureCode.resourceLimit);
    }
    var total = 0;
    for (final original in originals) {
      final image = await normalizeAgentImage(original);
      normalized.add(image);
      total += image.bytes.length;
      if (total > AgentImage.maximumTotalBytes) {
        throw const AgentFailure(AgentFailureCode.resourceLimit);
      }
    }
    _recordImageNormalizationStage(
      diagnostics,
      DiagnosticOutcome.complete,
      count: normalized.length,
    );
    return List.unmodifiable(normalized);
  } on AgentFailure catch (failure) {
    _recordImageNormalizationStage(
      diagnostics,
      failure.code == AgentFailureCode.cancelled
          ? DiagnosticOutcome.cancelled
          : DiagnosticOutcome.failure,
      code: _normalizationDiagnosticCode(failure.code),
      count: originals.length,
    );
    _wipe(normalized);
    rethrow;
  } on Object {
    _recordImageNormalizationStage(
      diagnostics,
      DiagnosticOutcome.failure,
      code: DiagnosticCode.unknown,
      count: originals.length,
    );
    _wipe(normalized);
    throw const AgentFailure(AgentFailureCode.invalidInput);
  } finally {
    for (final original in originals) {
      try {
        original.fillRange(0, original.length, 0);
      } on UnsupportedError {
        // A borrowed engine buffer may be read-only. Writable owned inputs are
        // still wiped; cleanup must not reject an already normalized image.
      }
    }
  }
}

DiagnosticCode _normalizationDiagnosticCode(AgentFailureCode code) =>
    switch (code) {
      AgentFailureCode.invalidInput => DiagnosticCode.invalidInput,
      AgentFailureCode.resourceLimit => DiagnosticCode.resourceLimit,
      AgentFailureCode.cancelled => DiagnosticCode.cancelled,
      _ => DiagnosticCode.unknown,
    };

void _recordImageNormalizationStage(
  DiagnosticsPort? diagnostics,
  DiagnosticOutcome outcome, {
  DiagnosticCode? code,
  int? count,
}) {
  if (diagnostics == null) return;
  try {
    diagnostics.record(
      DiagnosticEvent(
        name: DiagnosticEventName.imageInputStage,
        stage: DiagnosticStage.imageNormalization,
        outcome: outcome,
        code: code,
        count: count?.clamp(0, AgentImage.maximumCount).toInt(),
      ),
    );
  } catch (_) {
    // Diagnostics are best-effort and contain no image content or file details.
  }
}

/// Validates and decodes an allowed image, then strips metadata by re-encoding
/// the first (and only) frame as a bounded PNG.
Future<AgentImage> normalizeAgentImage(Uint8List source) async {
  if (source.length > _maximumOriginalBytes) {
    throw const AgentFailure(AgentFailureCode.resourceLimit);
  }
  if (!_hasAllowedSignature(source)) {
    throw const AgentFailure(AgentFailureCode.invalidInput);
  }

  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.FrameInfo? frame;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(source);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final width = descriptor.width;
    final height = descriptor.height;
    if (width < 1 || height < 1 || width * height > _maximumPixels) {
      throw const AgentFailure(AgentFailureCode.resourceLimit);
    }

    final scale = (_maximumLongSide / (width > height ? width : height)).clamp(
      0.0,
      1.0,
    );
    final targetWidth = (width * scale)
        .round()
        .clamp(1, _maximumLongSide)
        .toInt();
    final targetHeight = (height * scale)
        .round()
        .clamp(1, _maximumLongSide)
        .toInt();
    codec = await descriptor.instantiateCodec(
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
    validateAgentImageFrameCount(codec.frameCount);
    frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    if (data.lengthInBytes > AgentImage.maximumBytes) {
      throw const AgentFailure(AgentFailureCode.resourceLimit);
    }
    final encoded = Uint8List.sublistView(
      data.buffer.asUint8List(),
      data.offsetInBytes,
      data.offsetInBytes + data.lengthInBytes,
    );
    try {
      return AgentImage(encoded);
    } finally {
      encoded.fillRange(0, encoded.length, 0);
    }
  } on AgentFailure {
    rethrow;
  } on Object {
    // Decode/plugin diagnostics may contain file details; expose no exception.
    throw const AgentFailure(AgentFailureCode.invalidInput);
  } finally {
    frame?.image.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// Kept separate so the single-frame boundary has a direct synthetic check.
@visibleForTesting
void validateAgentImageFrameCount(int frameCount) {
  if (frameCount != 1) {
    throw const AgentFailure(AgentFailureCode.invalidInput);
  }
}

bool _hasAllowedSignature(Uint8List bytes) {
  const png = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length >= png.length &&
      List.generate(
        png.length,
        (index) => bytes[index] == png[index],
      ).every((match) => match)) {
    return true;
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return true;
  }
  return bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50;
}

void _wipe(List<AgentImage> images) {
  for (final image in images) {
    image.bytes.fillRange(0, image.bytes.length, 0);
  }
}
