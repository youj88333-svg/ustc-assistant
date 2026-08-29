import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/database/app_database.dart';
import '../core/database/connection.dart';
import '../features/settings/presentation/official_websites_page.dart';
import '../features/reminders/application/reminder_service.dart';
import '../features/reminders/application/windows_reminder_reconciler.dart';
import '../features/reminders/data/foreground_notification_adapter.dart';
import '../features/sync/presentation/sync_page.dart';
import 'router.dart';
import 'theme.dart';

export '../features/schedule/presentation/schedule_page.dart'
    show ScheduleSection;

class UstcAssistantApp extends StatefulWidget {
  const UstcAssistantApp({
    this.websiteLauncher = const UrlLauncherOfficialWebsiteLauncher(),
    this.database,
    this.clearBrowserSession,
    super.key,
  });

  final OfficialWebsiteLauncher websiteLauncher;
  final AppDatabase? database;
  final Future<void> Function()? clearBrowserSession;

  @override
  State<UstcAssistantApp> createState() => _UstcAssistantAppState();
}

class _UstcAssistantAppState extends State<UstcAssistantApp> {
  late final bool ownsDatabase;
  late final AppDatabase database;
  late final GoRouter router;
  late final WindowsReminderReconciler reminderReconciler;

  @override
  void initState() {
    super.initState();
    ownsDatabase = widget.database == null;
    database = widget.database ?? AppDatabase(openAppDatabase());
    reminderReconciler = WindowsReminderReconciler(
      database: database,
      reminderService: ReminderService(database: database),
      notifications: ForegroundNotificationAdapter(),
    );
    final clearBrowser =
        widget.clearBrowserSession ?? clearNativeJwBrowserSessions;
    router = buildRouter(
      widget.websiteLauncher,
      database,
      reminderReconciler,
      null,
      clearBrowser,
    );
    if (ownsDatabase) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_startBackgroundWork());
      });
    }
  }

  Future<void> _startBackgroundWork() async {
    final account = await (database.select(
      database.localAccounts,
    )..where((row) => row.isActive.equals(true))).getSingleOrNull();
    if (account != null) await reminderReconciler.start(account.id);
    await runStartupAutomaticSync(
      database,
      reminderReconciler: reminderReconciler,
    );
  }

  @override
  void dispose() {
    router.dispose();
    unawaited(reminderReconciler.dispose());
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
