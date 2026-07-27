import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});

  static const destinations = [
    (label: '账号', icon: Icons.badge_outlined, path: '/accounts'),
    (label: '同步', icon: Icons.sync, path: '/sync'),
    (label: '操作历史', icon: Icons.history, path: '/history'),
    (
      label: '已隐藏日程',
      icon: Icons.event_busy_outlined,
      path: '/calendar-events/manage',
    ),
    (label: '设置', icon: Icons.settings_outlined, path: '/settings'),
    (label: '学校官方网站', icon: Icons.open_in_browser, path: '/official-websites'),
  ];

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 12),
              child: Text(
                'USTC Assistant',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
            ),
            const Divider(),
            for (final destination in destinations)
              ListTile(
                leading: Icon(destination.icon),
                title: Text(destination.label),
                onTap: () => context.push(destination.path),
              ),
          ],
        ),
      ),
    );
  }
}
