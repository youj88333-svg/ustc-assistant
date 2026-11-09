import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/ios_i4_product_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'I4 native journey fixture accepts the real gateway directory protocol over fenced loopback',
    fixture.checkIOSI4LoopbackDirectoryForTesting,
  );

  test(
    'I4 HTTP assertions can run while a widget frame scope is pending',
    () async {
      // The socket listener is registered outside the frame's guarded zone,
      // exactly as it is before the native journey starts pumping frames.
      final request = fixture.checkIOSI4LoopbackDirectoryForTesting();
      await TestAsyncUtils.guard(() => request);
    },
  );
}
