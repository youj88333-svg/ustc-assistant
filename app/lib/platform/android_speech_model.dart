import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/speech_input_contract.dart';
import 'speech_model_bundle.dart';

/// Public bundled assets only. No recorder, credential or network operation.
final class AndroidSpeechModel {
  const AndroidSpeechModel({
    this.channel = const MethodChannel('ustc_assistant/android_speech_v1'),
  });
  final MethodChannel channel;

  Future<SpeechModelBundle> prepare() async {
    try {
      final value = await channel.invokeMethod<Object?>('prepareModel');
      if (value is! Map ||
          value.length != 2 ||
          value['version'] != speechModelVersion ||
          value['directory'] is! String) {
        throw const FormatException('speech_assets');
      }
      final directory = value['directory'] as String;
      if (directory.length > 4096 ||
          !p.posix.isAbsolute(directory) ||
          p.posix.normalize(directory) != directory ||
          directory.contains('\\') ||
          directory.contains('\u0000') ||
          !directory.endsWith('/speech_v1/$speechModelVersion')) {
        throw const FormatException('speech_assets');
      }
      return SpeechModelBundle.android(directory: directory);
    } on Object {
      throw const SpeechInputFailure(SpeechInputFailureCode.modelUnavailable);
    }
  }
}
