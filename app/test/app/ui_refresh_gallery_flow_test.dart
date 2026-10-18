import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/ui_refresh_gallery_test.dart' as gallery;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  gallery.uiRefreshGalleryScenarios(phoneLayout: false);
  gallery.uiRefreshGalleryScenarios(phoneLayout: true);
}
