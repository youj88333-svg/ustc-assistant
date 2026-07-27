import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/database/app_database.dart';
import '../core/database/connection.dart';
import '../features/settings/presentation/official_websites_page.dart';
import '../features/sync/presentation/sync_page.dart';
import 'router.dart';
import 'theme.dart';

export '../features/schedule/presentation/schedule_page.dart'
    show ScheduleSection;

class UstcAssistantApp extends StatefulWidget {
  const UstcAssistantApp({
    this.websiteLauncher = const UrlLauncherOfficialWebsiteLauncher(),
    this.database,
    super.key,
  });

  final OfficialWebsiteLauncher websiteLauncher;
  final AppDatabase? database;

  @override
  State<UstcAssistantApp> createState() => _UstcAssistantAppState();
}

class _UstcAssistantAppState extends State<UstcAssistantApp> {
  late final bool ownsDatabase;
  late final AppDatabase database;
  late final GoRouter router;

  @override
  void initState() {
    super.initState();
    ownsDatabase = widget.database == null;
    database = widget.database ?? AppDatabase(openAppDatabase());
    router = buildRouter(widget.websiteLauncher, database);
    if (ownsDatabase) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(runStartupAutomaticSync(database));
      });
    }
  }

  @override
  void dispose() {
    router.dispose();
    if (ownsDatabase) database.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'USTC Assistant',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      routerConfig: router,
    );
  }
}
