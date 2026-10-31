import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

import '../core/agent_contract.dart';
import '../core/contracts.dart';
import '../core/diagnostics_contract.dart';
import '../core/jw_credentials.dart';
import '../core/reminder_contract.dart';
import '../core/speech_input_contract.dart';
import 'ios_credential_protector.dart';
import 'ios_directory.dart';
import 'native_observation_browser.dart';
import 'runtime_platform_factory.dart'
    show RuntimeDirectories, RuntimePlatformFactory;
import 'unavailable_mobile_services.dart';

final class IOSRuntimePlatformFactory implements RuntimePlatformFactory {
  const IOSRuntimePlatformFactory()
    : _platformChannel = const MethodChannel('ustc_assistant/platform_v1');

  final MethodChannel _platformChannel;

  @override
  Future<RuntimeDirectories> acquireDirectories({
    String? directoryPath,
    String? jwDirectoryPath,
  }) async {
    if (!Platform.isIOS) {
      throw const AppFailure(FailureCode.unsupportedPlatform);
    }
    if (directoryPath != null || jwDirectoryPath != null) {
      throw const AppFailure(FailureCode.unsafeDirectory);
    }
    final root = await fetchPrivateDataRoot(channel: _platformChannel);
    final directories = await IOSDirectories.acquire(root);
    return RuntimeDirectories(
      demo: directories.demo,
      formal: directories.formal,
    );
  }

  @visibleForTesting
  static Future<String> fetchPrivateDataRoot({
    MethodChannel channel = const MethodChannel('ustc_assistant/platform_v1'),
  }) async {
    try {
      final result = await channel
          .invokeMethod<Object?>('privateDataRoot')
          .timeout(const Duration(seconds: 5));
      if (result is! String) {
        throw const AppFailure(FailureCode.unsafeDirectory);
      }
      return IOSDirectories.validateRootPath(result);
    } on AppFailure {
      rethrow;
    } on MissingPluginException {
      throw const AppFailure(FailureCode.unsupportedPlatform);
    } catch (_) {
      throw const AppFailure(FailureCode.storageFailed);
    }
  }

  @override
  JwCredentialProtector get schoolCredentials =>
      const IOSJwCredentialProtector();

  @override
  ModelCredentialProtector get modelCredentials =>
      const IOSModelCredentialProtector();

  @override
  NativeObservationBrowser createBrowser() => NativeObservationBrowser(
    requiresAvailabilityCheck: true,
    supportsIsolatedCleanupPending: false,
  );

  @override
  NotificationPlatformPort createNotifications() =>
      UnavailableMobileNotifications();

  @override
  SpeechInputPort createSpeech(DiagnosticsPort diagnostics) =>
      UnavailableMobileSpeechInput();
}
