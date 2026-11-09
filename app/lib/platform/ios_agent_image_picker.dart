import 'package:flutter/services.dart';

import '../core/agent_contract.dart';
import '../core/diagnostics_contract.dart';
import 'agent_image_picker.dart';

/// Narrow iOS bridge for PHPicker's already-normalized PNG results.
///
/// Native paths, Photos identifiers, provider UTIs, and metadata never cross
/// this port. The shared Dart normalizer verifies each returned PNG again.
final class IOSAgentImagePicker {
  IOSAgentImagePicker({
    this.channel = const MethodChannel('ustc_assistant/images_v1'),
    IOSAgentImageNormalizer? normalizeImage,
  }) : _normalizeImage = normalizeImage ?? normalizeAgentImage;

  final MethodChannel channel;
  final IOSAgentImageNormalizer _normalizeImage;
  int _generation = 0;

  Future<List<AgentImage>> pickImages({DiagnosticsPort? diagnostics}) async {
    final generation = _generation;
    _recordImageStage(
      diagnostics,
      DiagnosticStage.imagePicker,
      DiagnosticOutcome.started,
    );

    Object? response;
    final borrowed = <Uint8List>[];
    final sourceCopies = <Uint8List>[];
    final normalized = <AgentImage>[];
    var stage = DiagnosticStage.imagePicker;
    try {
      response = await channel.invokeMethod<Object?>('pickImages');
      if (response is List) {
        for (final item in response) {
          if (item is Uint8List) borrowed.add(item);
        }
      }
      _ensureCurrent(generation);
      if (response is! List) {
        throw const AgentFailure(AgentFailureCode.invalidInput);
      }
      if (response.length > AgentImage.maximumCount) {
        throw const AgentFailure(AgentFailureCode.resourceLimit);
      }
      if (response.isEmpty) {
        _recordImageStage(
          diagnostics,
          DiagnosticStage.imagePicker,
          DiagnosticOutcome.cancelled,
          count: 0,
        );
        _ensureCurrent(generation);
        return const [];
      }

      var nativeBytes = 0;
      for (final item in response) {
        if (item is! Uint8List || item.isEmpty) {
          throw const AgentFailure(AgentFailureCode.invalidInput);
        }
        if (item.length > AgentImage.maximumBytes ||
            nativeBytes > AgentImage.maximumTotalBytes - item.length) {
          throw const AgentFailure(AgentFailureCode.resourceLimit);
        }
        nativeBytes += item.length;
        sourceCopies.add(Uint8List.fromList(item));
      }

      _recordImageStage(
        diagnostics,
        DiagnosticStage.imagePicker,
        DiagnosticOutcome.complete,
        count: sourceCopies.length,
      );

      stage = DiagnosticStage.imageNormalization;
      _recordImageStage(diagnostics, stage, DiagnosticOutcome.started);
      var normalizedBytes = 0;
      for (final source in sourceCopies) {
        late final AgentImage image;
        try {
          image = await _normalizeImage(source);
        } on Object {
          _ensureCurrent(generation);
          rethrow;
        }
        if (generation != _generation) {
          image.bytes.fillRange(0, image.bytes.length, 0);
          throw const AgentFailure(AgentFailureCode.cancelled);
        }
        normalized.add(image);
        if (normalizedBytes >
            AgentImage.maximumTotalBytes - image.bytes.length) {
          throw const AgentFailure(AgentFailureCode.resourceLimit);
        }
        normalizedBytes += image.bytes.length;
      }
      _ensureCurrent(generation);
      _recordImageStage(
        diagnostics,
        stage,
        DiagnosticOutcome.complete,
        count: normalized.length,
      );
      _ensureCurrent(generation);
      return List.unmodifiable(normalized);
    } on AgentFailure catch (failure) {
      _recordImageStage(
        diagnostics,
        stage,
        failure.code == AgentFailureCode.cancelled
            ? DiagnosticOutcome.cancelled
            : DiagnosticOutcome.failure,
        code: _diagnosticCodeForFailure(failure.code),
        count: _boundedCount(response),
      );
      _wipeImages(normalized);
      rethrow;
    } on PlatformException catch (error) {
      final failure = AgentFailure(_agentFailureForPlatformCode(error.code));
      _recordImageStage(
        diagnostics,
        stage,
        failure.code == AgentFailureCode.cancelled
            ? DiagnosticOutcome.cancelled
            : DiagnosticOutcome.failure,
        code: _diagnosticCodeForPlatformCode(error.code),
        count: _boundedCount(response),
      );
      _wipeImages(normalized);
      throw failure;
    } on MissingPluginException {
      _recordImageStage(
        diagnostics,
        stage,
        DiagnosticOutcome.failure,
        code: DiagnosticCode.toolUnavailable,
        count: _boundedCount(response),
      );
      _wipeImages(normalized);
      throw const AgentFailure(AgentFailureCode.toolUnavailable);
    } on Object {
      _recordImageStage(
        diagnostics,
        stage,
        DiagnosticOutcome.failure,
        code: DiagnosticCode.unknown,
        count: _boundedCount(response),
      );
      _wipeImages(normalized);
      throw const AgentFailure(AgentFailureCode.imageRejected);
    } finally {
      for (final source in sourceCopies) {
        source.fillRange(0, source.length, 0);
      }
      for (final image in borrowed) {
        try {
          image.fillRange(0, image.length, 0);
        } on UnsupportedError {
          // Method-channel buffers can be borrowed or read-only.
        }
      }
    }
  }

  Future<void> cancel() async {
    _generation++;
    try {
      await channel.invokeMethod<void>('cancel');
    } on PlatformException catch (error) {
      throw AgentFailure(_agentFailureForPlatformCode(error.code));
    } on MissingPluginException {
      throw const AgentFailure(AgentFailureCode.toolUnavailable);
    } on Object {
      throw const AgentFailure(AgentFailureCode.imageRejected);
    }
  }

  void _ensureCurrent(int generation) {
    if (generation != _generation) {
      throw const AgentFailure(AgentFailureCode.cancelled);
    }
  }
}

typedef IOSAgentImageNormalizer = Future<AgentImage> Function(Uint8List source);

final IOSAgentImagePicker _defaultIOSAgentImagePicker = IOSAgentImagePicker();

Future<List<AgentImage>> pickIOSAgentImages({DiagnosticsPort? diagnostics}) =>
    _defaultIOSAgentImagePicker.pickImages(diagnostics: diagnostics);

Future<void> cancelIOSAgentImages() => _defaultIOSAgentImagePicker.cancel();

int? _boundedCount(Object? response) => response is List
    ? response.length.clamp(0, AgentImage.maximumCount).toInt()
    : null;

void _recordImageStage(
  DiagnosticsPort? diagnostics,
  DiagnosticStage stage,
  DiagnosticOutcome outcome, {
  DiagnosticCode? code,
  int? count,
}) {
  if (diagnostics == null) return;
  try {
    diagnostics.record(
      DiagnosticEvent(
        name: DiagnosticEventName.imageInputStage,
        stage: stage,
        outcome: outcome,
        code: code,
        count: count?.clamp(0, AgentImage.maximumCount).toInt(),
      ),
    );
  } catch (_) {
    // Diagnostics are best-effort and contain only fixed enums and counts.
  }
}

AgentFailureCode _agentFailureForPlatformCode(String code) => switch (code) {
  'resource_limit' => AgentFailureCode.resourceLimit,
  'busy' => AgentFailureCode.busy,
  'timeout' => AgentFailureCode.timeout,
  'cancelled' => AgentFailureCode.cancelled,
  'unavailable' || 'closed' => AgentFailureCode.toolUnavailable,
  'invalid_input' ||
  'invalid_request' ||
  'image_rejected' => AgentFailureCode.invalidInput,
  'read_failed' || 'io_failed' => AgentFailureCode.imageRejected,
  _ => AgentFailureCode.imageRejected,
};

DiagnosticCode _diagnosticCodeForPlatformCode(String code) => switch (code) {
  'resource_limit' => DiagnosticCode.resourceLimit,
  'busy' => DiagnosticCode.busy,
  'timeout' => DiagnosticCode.timeout,
  'cancelled' => DiagnosticCode.cancelled,
  'unavailable' || 'closed' => DiagnosticCode.toolUnavailable,
  'invalid_input' ||
  'invalid_request' ||
  'image_rejected' => DiagnosticCode.invalidInput,
  'read_failed' || 'io_failed' => DiagnosticCode.imageReadFailed,
  _ => DiagnosticCode.unknown,
};

DiagnosticCode _diagnosticCodeForFailure(AgentFailureCode code) =>
    switch (code) {
      AgentFailureCode.invalidInput => DiagnosticCode.invalidInput,
      AgentFailureCode.busy => DiagnosticCode.busy,
      AgentFailureCode.timeout => DiagnosticCode.timeout,
      AgentFailureCode.resourceLimit => DiagnosticCode.resourceLimit,
      AgentFailureCode.cancelled => DiagnosticCode.cancelled,
      AgentFailureCode.toolUnavailable => DiagnosticCode.toolUnavailable,
      AgentFailureCode.imageRejected => DiagnosticCode.imageRejected,
      _ => DiagnosticCode.unknown,
    };

void _wipeImages(List<AgentImage> images) {
  for (final image in images) {
    image.bytes.fillRange(0, image.bytes.length, 0);
  }
}
