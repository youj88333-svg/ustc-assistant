import 'package:path/path.dart' as p;

import '../core/contracts.dart';

/// Keeps formal data outside AppData, which a packaged launch host can redirect.
/// The returned path must still pass the native directory ownership checks.
String defaultJwDirectoryPath(Map<String, String> environment) {
  final userProfile = environment['USERPROFILE'];
  final profile = userProfile == null ? null : p.windows.normalize(userProfile);
  if (profile == null ||
      !RegExp(r'^[A-Za-z]:\\').hasMatch(profile) ||
      profile.contains('\u0000') ||
      p.windows.split(profile).length < 2) {
    throw const AppFailure(FailureCode.unsafeDirectory);
  }
  return p.windows.join(profile, '.ustc-assistant', 'local_v1');
}
