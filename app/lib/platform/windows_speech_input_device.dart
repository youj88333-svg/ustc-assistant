import 'dart:io';

import 'package:flutter/services.dart';
import 'package:record/record.dart';

import '../core/speech_input_contract.dart';

/// Resolves only the ordinary Windows default input after an explicit start.
/// It does not enumerate devices, read their labels, or open the microphone.
Future<InputDevice?> resolveSpeechInputDevice({
  MethodChannel channel = const MethodChannel(
    'ustc_assistant/default_audio_input',
  ),
}) async {
  if (!Platform.isWindows) return null;
  try {
    final value = await channel.invokeMethod<Object?>('getDefaultInputId');
    // record_windows 2.3.0 widens input IDs byte by byte. Reject an ID that
    // cannot make that round trip rather than silently selecting another mic.
    if (value is! String ||
        value.isEmpty ||
        value.length > 1024 ||
        value.codeUnits.any((unit) => unit < 0x21 || unit > 0x7e)) {
      throw const SpeechInputFailure(
        SpeechInputFailureCode.microphoneUnavailable,
      );
    }
    return InputDevice(id: value, label: '系统默认输入');
  } on Object {
    throw const SpeechInputFailure(
      SpeechInputFailureCode.microphoneUnavailable,
    );
  }
}
