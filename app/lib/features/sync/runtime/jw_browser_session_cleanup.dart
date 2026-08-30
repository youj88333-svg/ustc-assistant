import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Removes every native JW WebView2 user-data partition owned by this app.
///
/// The browser profiles are account-partitioned below the application-support
/// `browser_sessions` directory. Complete reset is the one operation allowed to clear
/// all of them, and it runs only after any active runtime has been shut down.
/// Refuse a reparse/symlink root so a corrupted path cannot redirect deletion
/// outside the app-support directory.
Future<void> clearNativeJwBrowserSessions() async {
  final support = await getApplicationSupportDirectory();
  final root = Directory(p.join(support.path, 'browser_sessions'));
  final rootType = await FileSystemEntity.type(root.path, followLinks: false);
  if (rootType == FileSystemEntityType.notFound) return;
  if (rootType != FileSystemEntityType.directory) {
    throw StateError('native browser session root is not a directory');
  }
  await for (final entry in root.list(followLinks: false)) {
    final type = await FileSystemEntity.type(entry.path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(entry.path).delete(recursive: true);
    } else {
      await entry.delete();
    }
  }
}
