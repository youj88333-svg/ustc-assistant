import 'package:path/path.dart' as p;

import '../core/contracts.dart';

/// Metadata-only filesystem operations under an active application owner.
/// The caller closes its databases and journal before releasing this lease.
abstract interface class OwnedDirectory implements AssetOwnership {
  String get path;
  p.Context get paths;
  void ensureDatabaseFilesSafe({String filename = 'm0_demo.sqlite'});
  String checkedChildPath(String relative, {required bool directory});
  String createPlainChildDirectory(String relative);
  Future<void> release();
}
