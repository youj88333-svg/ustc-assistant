import 'package:flutter/material.dart';

import '../features/settings/presentation/official_websites_page.dart';
import 'router.dart';
import 'theme.dart';

export '../features/schedule/presentation/schedule_page.dart'
    show ScheduleSection;

class UstcAssistantApp extends StatefulWidget {
  const UstcAssistantApp({
    this.websiteLauncher = const UrlLauncherOfficialWebsiteLauncher(),
    super.key,
  });

  final OfficialWebsiteLauncher websiteLauncher;

  @override
  State<UstcAssistantApp> createState() => _UstcAssistantAppState();
}

class _UstcAssistantAppState extends State<UstcAssistantApp> {
  late final router = buildRouter(widget.websiteLauncher);

  @override
  void dispose() {
    router.dispose();
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
