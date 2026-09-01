import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../storage/minimal_storage.dart';

QueryExecutor openAppDatabase() => driftDatabase(
  name: 'ustc_assistant',
  native: DriftNativeOptions(databaseDirectory: _minimalDatabaseDirectory),
);

Future<Object> _minimalDatabaseDirectory() async =>
    (await resolveMinimalStorageRoot()).path;
