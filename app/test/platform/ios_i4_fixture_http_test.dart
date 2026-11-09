import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/ios_i4_product_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'I4 native journey fixture accepts the real gateway directory protocol over fenced loopback',
    fixture.checkIOSI4LoopbackDirectoryForTesting,
  );
}
