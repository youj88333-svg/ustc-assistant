import 'dart:async';

import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';

/// `close` initiates teardown; `drained` confirms asynchronous WebKit release
/// and UUID deletion. A false observation is pending, never a successful drain.
Future<void> closeAndDrainI2(
  NativeObservationBrowser browser,
  int session, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final elapsed = Stopwatch()..start();
  await browser.close(session).timeout(timeout);
  while (elapsed.elapsed < timeout) {
    if (await browser.drained(session).timeout(timeout - elapsed.elapsed)) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw TimeoutException('i2_native_drain_not_confirmed', timeout);
}
