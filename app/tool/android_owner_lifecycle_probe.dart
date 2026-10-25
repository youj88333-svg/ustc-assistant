// Dedicated AndroidTest entry only; normal lib/main.dart never imports it.
import 'package:ustc_assistant_m0/testing/android_owner_lifecycle_probe.dart';

Future<void> main() => ownerLifecycleProbe();
