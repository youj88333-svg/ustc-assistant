import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/chat/presentation/chat_shell_page.dart';
import '../features/schedule/presentation/schedule_page.dart';
import '../features/settings/presentation/official_websites_page.dart';
import 'app_drawer.dart';

GoRouter buildRouter(OfficialWebsiteLauncher websiteLauncher) {
  return GoRouter(
    initialLocation: '/chat',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            _MainShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/chat',
                builder: (context, state) => const ChatShellPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/schedule',
                builder: (context, state) => const SchedulePage(),
              ),
            ],
          ),
        ],
      ),
      for (final route in const [
        (path: '/accounts', title: '账户'),
        (path: '/sync', title: '同步'),
        (path: '/history', title: '操作历史'),
        (path: '/settings', title: '设置'),
      ])
        GoRoute(
          path: route.path,
          builder: (context, state) => _PlaceholderPage(title: route.title),
        ),
      GoRoute(
        path: '/official-websites',
        builder: (context, state) =>
            OfficialWebsitesPage(launcher: websiteLauncher),
      ),
    ],
  );
}

class _MainShell extends StatelessWidget {
  const _MainShell({required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: Builder(
          builder: (context) => IconButton(
            tooltip: '打开侧边栏',
            onPressed: () => Scaffold.of(context).openDrawer(),
            icon: const Icon(Icons.menu),
          ),
        ),
        title: Text(navigationShell.currentIndex == 0 ? '聊天' : '日程'),
      ),
      drawer: const AppDrawer(),
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: (index) {
          navigationShell.goBranch(
            index,
            initialLocation: index == navigationShell.currentIndex,
          );
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: '聊天',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_today_outlined),
            selectedIcon: Icon(Icons.calendar_today),
            label: '日程',
          ),
        ],
      ),
    );
  }
}

class _PlaceholderPage extends StatelessWidget {
  const _PlaceholderPage({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(child: Text('$title功能将在后续任务中实现')),
    );
  }
}
