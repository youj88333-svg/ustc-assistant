import 'dart:io';

import 'package:flutter/services.dart';

import '../core/contracts.dart';
import '../core/agent_contract.dart';
import '../core/diagnostics_contract.dart';
import '../core/jw_credentials.dart';
import '../core/reminder_contract.dart';
import '../core/speech_input_contract.dart';
import 'android_credential_protector.dart';
import 'android_directory.dart';
import 'android_notifications.dart';
import 'demo_directory.dart';
import 'jw_directory_path.dart';
import 'native_observation_browser.dart';
import 'offline_speech_input.dart';
import 'owned_directory.dart';
import 'sense_voice_recognizer.dart';
import 'speech_audio_recorder.dart';
import 'unavailable_mobile_services.dart';
import 'windows_jw_credential_protector.dart';
import 'windows_model_credential_protector.dart';
import 'windows_notifications.dart';

final class RuntimeDirectories {
  const RuntimeDirectories({required this.demo, required this.formal});
  final OwnedDirectory demo, formal;
}

abstract interface class RuntimePlatformFactory {
  Future<RuntimeDirectories> acquireDirectories({
    String? directoryPath,
    String? jwDirectoryPath,
  });
  JwCredentialProtector get schoolCredentials;
  ModelCredentialProtector get modelCredentials;
  NativeObservationBrowser createBrowser();
  NotificationPlatformPort createNotifications();
  SpeechInputPort createSpeech(DiagnosticsPort diagnostics);
}

RuntimePlatformFactory runtimePlatformFactory() {
  if (Platform.isWindows) return const WindowsRuntimePlatformFactory();
  if (Platform.isAndroid) return const AndroidRuntimePlatformFactory();
  throw const AppFailure(FailureCode.unsupportedPlatform);
}

final class WindowsRuntimePlatformFactory implements RuntimePlatformFactory {
  const WindowsRuntimePlatformFactory();
  @override
  Future<RuntimeDirectories> acquireDirectories({
    String? directoryPath,
    String? jwDirectoryPath,
  }) async {
    final demo = await DemoDirectory.acquire(directoryPath);
    try {
      final formal = await DemoDirectory.acquire(
        jwDirectoryPath ??
            (directoryPath == null
                ? defaultJwDirectoryPath(Platform.environment)
                : '${directoryPath}_jw'),
      );
      return RuntimeDirectories(demo: demo, formal: formal);
    } catch (_) {
      await demo.release();
      rethrow;
    }
  }

  @override
  JwCredentialProtector get schoolCredentials =>
      const WindowsJwCredentialProtector();
  @override
  ModelCredentialProtector get modelCredentials =>
      const WindowsModelCredentialProtector();
  @override
  NativeObservationBrowser createBrowser() => NativeObservationBrowser();
  @override
  NotificationPlatformPort createNotifications() => WindowsNotifications();
  @override
  SpeechInputPort createSpeech(DiagnosticsPort diagnostics) =>
      OfflineSpeechInput(
        recorder: SpeechAudioRecorder(),
        recognizer: SenseVoiceRecognizer(),
        diagnostics: diagnostics,
      );
}

final class AndroidRuntimePlatformFactory implements RuntimePlatformFactory {
  const AndroidRuntimePlatformFactory();
  static const _channel = MethodChannel('ustc_assistant/platform_v1');

  @override
  Future<RuntimeDirectories> acquireDirectories({
    String? directoryPath,
    String? jwDirectoryPath,
  }) async {
    if (!Platform.isAndroid) {
      throw const AppFailure(FailureCode.unsupportedPlatform);
    }
    // Mobile storage is chosen by the app sandbox, not a desktop path override.
    if (directoryPath != null || jwDirectoryPath != null) {
      throw const AppFailure(FailureCode.unsafeDirectory);
    }
    final String path;
    try {
      final result = await _channel
          .invokeMethod<Object?>('privateDataRoot')
          .timeout(const Duration(seconds: 5));
      if (result is! String) {
        throw const AppFailure(FailureCode.unsafeDirectory);
      }
      path = result;
    } on AppFailure {
      rethrow;
    } on MissingPluginException {
      throw const AppFailure(FailureCode.unsupportedPlatform);
    } catch (_) {
      throw const AppFailure(FailureCode.storageFailed);
    }
    final directories = await AndroidDirectories.acquire(path);
    return RuntimeDirectories(
      demo: directories.demo,
      formal: directories.formal,
    );
  }

  @override
  JwCredentialProtector get schoolCredentials =>
      const AndroidJwCredentialProtector();
  @override
  ModelCredentialProtector get modelCredentials =>
      const AndroidModelCredentialProtector();
  @override
  NativeObservationBrowser createBrowser() => NativeObservationBrowser();
  @override
  NotificationPlatformPort createNotifications() =>
      AndroidNotifications();
  @override
  SpeechInputPort createSpeech(DiagnosticsPort diagnostics) =>
      UnavailableMobileSpeechInput();
}
