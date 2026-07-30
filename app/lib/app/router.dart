import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/database/app_database.dart';
import '../core/security/windows_dpapi_protector.dart';
import '../features/accounts/application/account_service.dart';
import '../features/accounts/presentation/accounts_page.dart';
import '../features/agent/application/agent_composition.dart';
import '../features/agent/application/agent_configuration_service.dart';
import '../features/agent/data/anthropic_llm_provider.dart';
import '../features/agent/data/drift_chat_repository.dart';
import '../features/agent/data/protected_agent_secret_store.dart';
import '../features/agent/data/windows_python_query_gateway.dart';
import '../features/agent/presentation/agent_chat_page.dart';
import '../features/agent/presentation/agent_settings_page.dart';
import '../features/calendar/application/calendar_event_service.dart';
import '../features/calendar/presentation/calendar_event_form.dart';
import '../features/calendar/presentation/personal_event_management_page.dart';
import '../features/import/application/reminder_reconciler.dart';
import '../features/history/application/history_repository.dart';
import '../features/history/presentation/history_page.dart';
import '../features/schedule/presentation/schedule_page.dart';
import '../features/schedule/presentation/event_detail_loader.dart';
import '../features/schedule/presentation/conflict_management_page.dart';
import '../features/settings/presentation/official_websites_page.dart';
import '../features/settings/application/settings_service.dart';
import '../features/settings/presentation/settings_page.dart';
import '../features/sync/data/python_locator.dart';
import '../features/sync/presentation/sync_page.dart';
import '../features/tasks/application/task_lifecycle_service.dart';
import '../features/tasks/application/undo_service.dart';
import '../features/tasks/presentation/task_form.dart';
import '../features/tasks/presentation/task_detail_loader.dart';
import 'app_drawer.dart';

GoRouter buildRouter(
  OfficialWebsiteLauncher websiteLauncher,
  AppDatabase database, [
  ReminderReconciler reminderReconciler = const NoopReminderReconciler(),
]) {
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
                builder: (context, state) => _AgentChatLoader(
                  database: database,
                  websiteLauncher: websiteLauncher,
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/schedule',
                builder: (context, state) => SchedulePage(
                  database: database,
                  onEventSelected: (eventId) =>
                      context.push('/events/$eventId'),
                  onTaskSelected: (taskId) => context.push('/tasks/$taskId'),
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
        path: '/tasks/:taskId',
        builder: (context, state) => TaskDetailLoader(
          database: database,
          taskId: state.pathParameters['taskId']!,
        ),
      ),
      GoRoute(
        path: '/calendar-event/new',
        builder: (context, state) => _CalendarEventCreatePage(
          database: database,
          prefill: state.extra as CalendarEventPrefill?,
        ),
      ),
      GoRoute(
        path: '/events/:eventId',
        builder: (context, state) => EventDetailLoader(
          database: database,
          eventId: state.pathParameters['eventId']!,
          onManageOverlaps: (eventId) =>
              context.push('/events/$eventId/conflicts'),
        ),
      ),
      GoRoute(
        path: '/events/:eventId/conflicts',
        builder: (context, state) => ConflictManagementLoader(
          database: database,
          eventId: state.pathParameters['eventId']!,
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
          onLoginAgain: (accountId) =>
              context.push('/accounts/$accountId/reauthenticate'),
          onOpenOfficialPage: () => context.go('/official-websites'),
        ),
      ),
      GoRoute(
        path: '/accounts/:accountId/reauthenticate',
        builder: (context, state) => SyncPageLoader(
          database: database,
          reminderReconciler: reminderReconciler,
          reauthenticateAccountId: state.pathParameters['accountId']!,
          onReauthenticated: () => context.go('/accounts'),
        ),
      ),
      GoRoute(
        path: '/sync',
        builder: (context, state) => SyncPageLoader(
          database: database,
          reminderReconciler: reminderReconciler,
          onExit: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/chat');
            }
          },
          onReauthenticationRequired: (accountId) =>
              context.push('/accounts/$accountId/reauthenticate'),
        ),
      ),
      GoRoute(
        path: '/history',
        builder: (context, state) =>
            _HistoryLoader(database: database),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => _SettingsLoader(database: database),
      ),
      GoRoute(
        path: '/settings/agent',
        builder: (context, state) =>
            _AgentSettingsLoader(database: database),
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

class _SettingsLoader extends StatelessWidget {
  const _SettingsLoader({required this.database});

  final AppDatabase database;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<LocalAccount?>(
      future: _activeAccount(database),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final account = snapshot.data;
        if (account == null) {
          return const Scaffold(body: Center(child: Text('请先配置学校账号')));
        }
        final accounts = AccountService(
          database: database,
          protector: WindowsDpapiProtector(),
        );
        return SettingsPage(
          service: SettingsService(
            database: database,
            accounts: accounts,
            accountId: account.id,
          ),
          onCompleteReset: () => context.go('/sync'),
        );
      },
    );
  }
}

class _AgentSettingsLoader extends StatelessWidget {
  const _AgentSettingsLoader({required this.database});

  final AppDatabase database;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<LocalAccount?>(
      future: _activeAccount(database),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final account = snapshot.data;
        if (account == null) {
          return const Scaffold(body: Center(child: Text('请先配置学校账号')));
        }
        final chatRepository = DriftChatRepository(database);
        return AgentSettingsPage(
          accountId: account.id,
          config: AgentConfigurationService(
            database: database,
            chatRepository: chatRepository,
          ),
          secrets: ProtectedAgentSecretStore(
            database: database,
            protector: WindowsDpapiProtector(),
          ),
          provider: AnthropicLlmProvider(),
          chatRepository: chatRepository,
        );
      },
    );
  }
}

/// Loader for the Agent chat page: resolves the active account, builds the
/// AgentComposition, and renders AgentChatPage.
///
/// The active-account lookup is cached in [initState] so a rebuild (e.g. from
/// an inset `setState` in a descendant) does NOT re-query the database. The
/// expensive composition (secret store, DPAPI protector, Bridge handshake via
/// `WindowsPythonQueryGateway.start`) is cached one level down in
/// [_AgentChatCompositionBuilder], also in `initState`. Both happen once per
/// route entry, not per rebuild.
class _AgentChatLoader extends StatefulWidget {
  const _AgentChatLoader({
    required this.database,
    required this.websiteLauncher,
  });

  final AppDatabase database;
  final OfficialWebsiteLauncher websiteLauncher;

  @override
  State<_AgentChatLoader> createState() => _AgentChatLoaderState();
}

class _AgentChatLoaderState extends State<_AgentChatLoader> {
  late final Future<LocalAccount?> _accountFuture;

  @override
  void initState() {
    super.initState();
    _accountFuture = _activeAccount(widget.database);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<LocalAccount?>(
      future: _accountFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final account = snapshot.data;
        if (account == null) {
          return const Scaffold(
            body: Center(child: Text('请先配置学校账号')),
          );
        }

        return _AgentChatCompositionBuilder(
          database: widget.database,
          accountId: account.id,
          websiteLauncher: widget.websiteLauncher,
        );
      },
    );
  }
}

/// Builds the AgentComposition for the active account and renders AgentChatPage.
///
/// The composition future (username resolution + `AgentComposition.build`,
/// which constructs the secret store/DPAPI protector and runs the Bridge
/// handshake via `WindowsPythonQueryGateway.start`) is created ONCE in
/// [initState] and reused across rebuilds. This is critical: creating it in
/// `build` would re-run the full composition — including the Bridge handshake
/// and DB queries — on every rebuild.
class _AgentChatCompositionBuilder extends StatefulWidget {
  const _AgentChatCompositionBuilder({
    required this.database,
    required this.accountId,
    required this.websiteLauncher,
  });

  final AppDatabase database;
  final String accountId;
  final OfficialWebsiteLauncher websiteLauncher;

  @override
  State<_AgentChatCompositionBuilder> createState() =>
      _AgentChatCompositionBuilderState();
}

class _AgentChatCompositionBuilderState
    extends State<_AgentChatCompositionBuilder> {
  late final Future<AgentCompositionResult> _compositionFuture;

  @override
  void initState() {
    super.initState();
    // Build the composition once for this route entry. The username and the
    // Python executable are resolved as the first steps of the single cached
    // future so a rebuild never re-runs `_resolveUsername`/`PythonLocator` nor
    // re-issues the Bridge handshake. The Python path mirrors the sync flow
    // (PythonLocator.locate with the saved SettingsService.pythonPath); an
    // empty string here would make `Process.start('')` fail and surface as
    // "无法加载 Agent 服务".
    _compositionFuture = _resolveUsername(widget.database, widget.accountId)
        .then((resolvedUsername) async {
      if (resolvedUsername.isEmpty) {
        // Signals the "无法获取学校账号" branch below; AgentComposition.build
        // would otherwise receive an empty username.
        throw const _NoResolvedUsername();
      }
      final accounts = AccountService(
        database: widget.database,
        protector: WindowsDpapiProtector(),
      );
      final savedPythonPath = await SettingsService(
        database: widget.database,
        accounts: accounts,
        accountId: widget.accountId,
      ).pythonPath();
      final launchOptions = resolveBridgeLaunchOptions();
      final pythonExecutable = await PythonLocator().locate(
        savedExecutable: savedPythonPath,
        requiredModule: 'ustc_assistant.bridge.query_jobs',
        importEnvironment: launchOptions.environment,
      );
      return AgentComposition.build(
        database: widget.database,
        accountId: widget.accountId,
        resolvedUsername: resolvedUsername,
        secretStoreFactory: (db) => ProtectedAgentSecretStore(
          database: db,
          protector: WindowsDpapiProtector(),
        ),
        queryGatewayFactory: (db, _) => WindowsPythonQueryGateway.start(
          pythonExecutable: pythonExecutable,
          launchOptions: launchOptions,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AgentCompositionResult>(
      future: _compositionFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError && snapshot.error is _NoResolvedUsername) {
          return const Scaffold(
            body: Center(child: Text('无法获取学校账号')),
          );
        }
        final composition = snapshot.data;
        if (composition == null) {
          return const Scaffold(
            body: Center(child: Text('无法加载 Agent 服务')),
          );
        }

        return AgentChatPage(
          accountId: widget.accountId,
          config: composition.configService,
          secrets: composition.secretStore,
          provider: composition.provider,
          sessionService: composition.sessionService,
          chatRepository: composition.chatRepository,
          websiteLauncher: widget.websiteLauncher,
        );
      },
    );
  }

  Future<String> _resolveUsername(AppDatabase db, String id) async {
    try {
      final service = AccountService(
        database: db,
        protector: WindowsDpapiProtector(),
      );
      return await service.usernameForSync(id);
    } catch (_) {
      return '';
    }
  }
}

/// Sentinel thrown when the active account's username cannot be resolved, so
/// the composition future fails fast with a recognizable error instead of
/// building a composition with an empty username.
class _NoResolvedUsername implements Exception {
  const _NoResolvedUsername();
}

Future<LocalAccount?> _activeAccount(AppDatabase database) => (database.select(
  database.localAccounts,
)..where((row) => row.isActive.equals(true))).getSingleOrNull();

class _HistoryLoader extends StatelessWidget {
  const _HistoryLoader({required this.database});

  final AppDatabase database;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<LocalAccount?>(
      future: _activeAccount(database),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final account = snapshot.data;
        if (account == null) {
          return const Scaffold(body: Center(child: Text('请先配置学校账号')));
        }
        return HistoryPage(
          repository: HistoryRepository(database),
          accountId: account.id,
        );
      },
    );
  }
}
