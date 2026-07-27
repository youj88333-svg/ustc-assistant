import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/database/app_database.dart';
import '../core/security/windows_dpapi_protector.dart';
import '../features/accounts/application/account_service.dart';
import '../features/accounts/presentation/accounts_page.dart';
import '../features/calendar/application/calendar_event_service.dart';
import '../features/calendar/presentation/calendar_event_form.dart';
import '../features/calendar/presentation/personal_event_management_page.dart';
import '../features/chat/presentation/chat_shell_page.dart';
import '../features/schedule/presentation/schedule_page.dart';
import '../features/settings/presentation/official_websites_page.dart';
import '../features/sync/presentation/sync_page.dart';
import '../features/tasks/application/task_lifecycle_service.dart';
import '../features/tasks/application/undo_service.dart';
import '../features/tasks/presentation/task_form.dart';
import 'app_drawer.dart';

GoRouter buildRouter(
  OfficialWebsiteLauncher websiteLauncher,
  AppDatabase database,
) {
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
                builder: (context, state) => SchedulePage(
                  database: database,
                  onCreateCalendarEvent: (prefill) {
                    context.push('/calendar-event/new', extra: prefill);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/task/new',
        builder: (context, state) => _TaskCreatePage(database: database),
      ),
      GoRoute(
        path: '/calendar-event/new',
        builder: (context, state) => _CalendarEventCreatePage(
          database: database,
          prefill: state.extra as CalendarEventPrefill?,
        ),
      ),
      GoRoute(
        path: '/calendar-events/manage',
        builder: (context, state) =>
            _PersonalEventManagementLoader(database: database),
      ),
      GoRoute(
        path: '/accounts',
        builder: (context, state) => AccountsPage(
          service: AccountService(
            database: database,
            protector: WindowsDpapiProtector(),
          ),
          onLoginAgain: (_) => context.go('/sync'),
          onOpenOfficialPage: () => context.go('/official-websites'),
        ),
      ),
      GoRoute(
        path: '/sync',
        builder: (context, state) => SyncPageLoader(database: database),
      ),
      for (final route in const [
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
        actions: [
          IconButton(
            key: const Key('global-add'),
            tooltip: '新建',
            onPressed: () => _showCreateMenu(context),
            icon: const Icon(Icons.add),
          ),
        ],
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

  Future<void> _showCreateMenu(BuildContext context) async {
    final choice = await showDialog<_CreateChoice>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('新建'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, _CreateChoice.task),
            child: const ListTile(
              leading: Icon(Icons.task_alt),
              title: Text('Task'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () =>
                Navigator.pop(context, _CreateChoice.calendarEvent),
            child: const ListTile(
              leading: Icon(Icons.event),
              title: Text('Calendar event'),
            ),
          ),
        ],
      ),
    );
    if (!context.mounted || choice == null) return;
    if (choice == _CreateChoice.task) {
      context.push('/task/new');
    } else {
      context.push('/calendar-event/new');
    }
  }
}

class _TaskCreatePage extends StatelessWidget {
  const _TaskCreatePage({required this.database});

  final AppDatabase database;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('新建任务')),
      body: TaskForm(
        onSubmit: (submission) async {
          final account = await _activeAccount(database);
          if (account == null) {
            throw StateError('active account required');
          }
          final undo = UndoService(database: database, accountId: account.id);
          await TaskLifecycleService(
            database: database,
            accountId: account.id,
            undoRecorder: undo,
          ).create(
            title: submission.title,
            description: submission.description,
            userNotes: submission.userNotes,
            importance: submission.importance,
            deadlineAt: submission.deadlineAt,
            estimatedMinutes: submission.estimatedMinutes,
            tags: submission.tags,
            eventIds: submission.relatedEventIds,
          );
          if (context.mounted) context.pop();
        },
      ),
    );
  }
}

enum _CreateChoice { task, calendarEvent }

class _CalendarEventCreatePage extends StatelessWidget {
  const _CalendarEventCreatePage({
    required this.database,
    required this.prefill,
  });

  final AppDatabase database;
  final CalendarEventPrefill? prefill;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('新建日程')),
      body: CalendarEventForm(
        initialStart: prefill?.start,
        initialEnd: prefill?.end,
        initialAllDayDate: prefill?.allDayDate,
        relatedTaskIds: prefill?.relatedTaskIds ?? const [],
        onSubmit: (submission) async {
          final account = await _activeAccount(database);
          if (account == null) {
            throw StateError('active account required');
          }
          await CalendarEventService(
            database: database,
            accountId: account.id,
          ).create(
            submission.event,
            reminderOffsetsMinutes: submission.reminderOffsetsMinutes,
            taskIds: submission.taskIds,
          );
          if (context.mounted) context.pop();
        },
      ),
    );
  }
}

class _PersonalEventManagementLoader extends StatelessWidget {
  const _PersonalEventManagementLoader({required this.database});

  final AppDatabase database;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<LocalAccount?>(
      future: _activeAccount(database),
      builder: (context, snapshot) {
        final account = snapshot.data;
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (account == null) {
          return const Scaffold(body: Center(child: Text('请先配置学校账号')));
        }
        return PersonalEventManagementPage(
          service: CalendarEventService(
            database: database,
            accountId: account.id,
          ),
        );
      },
    );
  }
}

Future<LocalAccount?> _activeAccount(AppDatabase database) => (database.select(
  database.localAccounts,
)..where((row) => row.isActive.equals(true))).getSingleOrNull();

class _PlaceholderPage extends StatelessWidget {
  const _PlaceholderPage({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(child: Text('$title 功能将在后续任务中实现')),
    );
  }
}
