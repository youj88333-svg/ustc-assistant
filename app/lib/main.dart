import 'package:flutter/material.dart';

import 'app/app.dart';
import 'core/database/app_database.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({this.database, super.key});

  final AppDatabase? database;

  @override
  Widget build(BuildContext context) {
    return UstcAssistantApp(database: database);
  }
}
