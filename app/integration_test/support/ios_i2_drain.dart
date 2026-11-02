import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';

/// `close` initiates teardown; `drained` confirms asynchronous WebKit release
/// and UUID deletion. A false observation is pending, never a successful drain.
Future<void> closeAndDrainI2(
  NativeObservationBrowser browser,
  int session, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  try {
    final elapsed = Stopwatch()..start();
    await browser.close(session).timeout(timeout);
    while (elapsed.elapsed < timeout) {
      if (await browser.drained(session).timeout(timeout - elapsed.elapsed)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw TimeoutException('i2_native_drain_not_confirmed', timeout);
  } on Object {
    await _logSafeCleanupState();
    rethrow;
  }
}

// Only fresh I2 fixtures call this helper. Copy five closed, value-free fields
// on failure; never print an arbitrary native payload or exception message.
Future<void> _logSafeCleanupState() async {
  try {
    final raw = await const MethodChannel('ustc_assistant/platform_v1')
        .invokeMapMethod<Object?, Object?>('i2BrowserDiagnostics')
        .timeout(const Duration(seconds: 2));
    const vocabulary = <String, Set<String>>{
      'state': {'idle', 'open', 'closing', 'cleanupPending', 'closed'},
      'cleanupStage': {
        'none',
        'waitingForView',
        'metadataDeletePending',
        'removeStore',
        'verifyStoreAbsent',
        'metadataRemoved',
        'complete',
      },
      'cleanupFailure': {
        'none',
        'viewRetained',
        'metadataWrite',
        'removeRejected',
        'storePresent',
        'metadataCompletion',
      },
      'cleanupErrorDomain': {
        'none',
        'urlLoading',
        'webKit',
        'posix',
        'app',
        'other',
      },
    };
    final safe = <String, Object?>{};
    for (final entry in vocabulary.entries) {
      final value = raw?[entry.key];
      if (value is! String || !entry.value.contains(value)) {
        throw StateError('invalid_cleanup_diagnostic');
      }
      safe[entry.key] = value;
    }
    final code = raw?['cleanupErrorCode'];
    if (code != null && (code is! int || code.abs() > 100000)) {
      throw StateError('invalid_cleanup_diagnostic');
    }
    safe['cleanupErrorCode'] = code;
    debugPrint('I2 native cleanup: ${jsonEncode(safe)}');
  } on Object {
    debugPrint('I2 native cleanup: diagnostic_unavailable');
  }
}
