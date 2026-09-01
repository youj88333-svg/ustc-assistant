import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/database/app_database.dart';
import '../core/security/credential_protector_factory.dart';
import '../core/time/beijing_clock.dart';
import '../features/accounts/application/account_service.dart';
import '../features/accounts/presentation/accounts_page.dart';
import '../features/agent/application/agent_composition.dart';
import '../features/agent/application/agent_configuration_service.dart';
import '../features/agent/application/agent_permission_policy_service.dart';
import '../features/agent/data/anthropic_llm_provider.dart';
import '../features/agent/data/drift_chat_repository.dart';
import '../features/agent/data/protected_agent_secret_store.dart';
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
import '../features/settings/application/minimal_reset_coordinator.dart';
import '../features/settings/application/settings_service.dart';
import '../features/settings/presentation/settings_page.dart';
import '../features/sync/presentation/sync_page.dart';
import '../features/sync/runtime/minimal_jw_runtime.dart';
import '../features/sync/runtime/minimal_jw_runtime_scope.dart';
import '../features/tasks/application/task_lifecycle_service.dart';
import '../features/tasks/application/undo_service.dart';
import '../features/tasks/presentation/task_form.dart';
import '../features/tasks/presentation/task_detail_loader.dart';
import 'app_drawer.dart';
import 'minimal_app_state.dart';

export 'minimal_app_state.dart';

GoRouter buildRouter(
  OfficialWebsiteLauncher websiteLauncher,
  AppDatabase database, [
  ReminderReconciler reminderReconciler = const NoopReminderReconciler(),
  AgentCompositionLoader? agentCompositionLoader,
  Future<void> Function()? clearBrowserSession,
  MinimalJwRuntimeOwner? runtimeOwner,
  AgentCompositionOwner? agentCompositionOwner,
  Future<MinimalResetCoordinator> Function()? resetCoordinatorLoader,
  MinimalAppStateController? appStateController,
  Future<void> Function()? requestAppExit,
]) {
  final loadAgentComposition = agentCompositionLoader ?? buildAgentComposition;
  final appState = appStateController;

  Future<void> completeReset() async {
    try {
      final loader = resetCoordinatorLoader;
      if (loader != null) {
        await (await loader()).completeReset();
        return;
      }
      final accounts = AccountService(
        database: database,
        protector: defaultCredentialProtector(),
        clearBrowserSession: clearBrowserSession,
      );
      await SettingsService(
        database: database,
        accounts: accounts,
        accountId: null,
      ).completeReset(firstConfirmation: true, secondConfirmation: true);
      appState?.showUnconfiguredAfterReset();
    } on Object {
      appState?.markResetFailed();
      rethrow;
    }
  }

  Future<void> confirmAndReset(BuildContext context) async {
    final confirmed = await confirmCompleteReset(context);
    if (!context.mounted) return;
    if (!confirmed) {
      showResetCancelledMessage(context);
      return;
    }
    try {
      await completeReset();
      if (context.mounted) context.go('/sync');
    } on Object {
      // The app-owned state controller routes coordinator failures to the
      // fail-closed recovery page. Direct embedded hosts get only a safe
      // generic message and never see an exception string.
      if (context.mounted && appState == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('本地数据重置失败，请重试')));
      }
    }
  }

  return GoRouter(
    initialLocation: '/chat',
    refreshListenable: appState,
    redirect: (context, state) => _minimalRouteRedirect(appState, state),
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
                  compositionLoader: loadAgentComposition,
                  compositionOwner: agentCompositionOwner,
                  onReset: () => confirmAndReset(context),
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
                  // `?section=week|tasks` selects the schedule section. Only
                  // these two values are recognized; any other or missing
                  // value defaults to the week view.
                  initialSection: _scheduleSectionFromRoute(state),
                  onEventSelected: (eventId) =>
                      context.push('/events/$eventId'),
                  onTaskSelected: (taskId) => context.push('/tasks/$taskId'),
                  onManageRelations: (group) => context.push(
                    '/schedule/conflicts',
                    extra: ConflictManagementRequest(group.items),
                  ),
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
        path: '/schedule/conflicts',
        builder: (context, state) => _ScheduleConflictsLoader(
          database: database,
          request: state.extra is ConflictManagementRequest
              ? state.extra! as ConflictManagementRequest
              : null,
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
            protector: defaultCredentialProtector(),
          ),
          onFirstLogin: () => context.go('/sync'),
          onLoginAgain: (accountId) =>
              context.push('/accounts/$accountId/reauthenticate'),
          onOpenOfficialPage: () => context.go('/official-websites'),
          coordinatedReset: completeReset,
          onCompleteReset: () {
            if (context.mounted) context.go('/sync');
          },
        ),
      ),
      GoRoute(
        path: '/accounts/:accountId/reauthenticate',
        builder: (context, state) => _RuntimeSyncRoute(
          owner: runtimeOwner,
          // Direct router hosts do not have the app composition owner. Keep
          // their legacy, side-effect-free form available without creating a
          // native gateway, controller, environment, or UDF path here.
          missingRuntime: SyncPageLoader(
            database: database,
            reminderReconciler: reminderReconciler,
            reauthenticateAccountId: state.pathParameters['accountId']!,
            appStateController: appState,
            clearBrowserSession: clearBrowserSession,
            createNativeGateway: false,
          ),
          builder: (runtime) => SyncPageLoader(
            database: database,
            reminderReconciler: reminderReconciler,
            runtime: runtime,
            appStateController: appState,
            reauthenticateAccountId: state.pathParameters['accountId']!,
            clearBrowserSession: clearBrowserSession,
            coordinatedReset: resetCoordinatorLoader == null
                ? null
                : completeReset,
            onReauthenticated: () {
              if (resetCoordinatorLoader != null) {
                // The coordinated reset has already installed the fresh
                // runtime. Do not call replaceAfterReset a second time.
                context.go('/sync');
              } else {
                _replaceRuntimeAndGo(context, runtimeOwner);
              }
            },
          ),
        ),
      ),
      GoRoute(
        path: '/sync',
        builder: (context, state) => _RuntimeSyncRoute(
          owner: runtimeOwner,
          // See the reauthentication route above. Production app routes
          // always resolve the borrowed runtime; this branch only preserves
          // direct/embedded router hosts that intentionally omit composition.
          missingRuntime: SyncPageLoader(
            database: database,
            reminderReconciler: reminderReconciler,
            appStateController: appState,
            clearBrowserSession: clearBrowserSession,
            createNativeGateway: false,
            onExit: () {
              if (context.canPop()) {
                context.pop();
              } else {
                context.go('/chat');
              }
            },
            onReauthenticationRequired: (accountId) =>
                context.go('/accounts/$accountId/reauthenticate'),
          ),
          builder: (runtime) => SyncPageLoader(
            database: database,
            reminderReconciler: reminderReconciler,
            runtime: runtime,
            appStateController: appState,
            clearBrowserSession: clearBrowserSession,
            onExit: () {
              if (context.canPop()) {
                context.pop();
              } else {
                context.go('/chat');
              }
            },
            onReauthenticationRequired: (accountId) =>
                context.go('/accounts/$accountId/reauthenticate'),
          ),
        ),
      ),
      GoRoute(
        path: '/history',
        builder: (context, state) => _HistoryLoader(database: database),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => _SettingsLoader(
          database: database,
          runtimeOwner: runtimeOwner,
          resetCoordinatorLoader: resetCoordinatorLoader,
          coordinatedReset: appState == null ? null : completeReset,
        ),
      ),
      GoRoute(
        path: '/settings/agent',
        builder: (context, state) => _AgentSettingsLoader(database: database),
      ),
      GoRoute(
        path: '/official-websites',
        builder: (context, state) =>
            OfficialWebsitesPage(launcher: websiteLauncher),
      ),
      GoRoute(
        path: '/reset-recovery',
        builder: (context, state) => ResetRecoveryView(
          safeCode:
              appState?.safeCode ?? MinimalAppStateController.resetFailedCode,
          onRetry: resetCoordinatorLoader == null && appState == null
              ? null
              : () async {
                  try {
                    if (resetCoordinatorLoader != null) {
                      await (await resetCoordinatorLoader()).retryReset();
                    } else {
                      await completeReset();
                    }
                  } on Object {
                    // The retained coordinator publishes failed again. Keep
                    // raw cleanup details out of this route.
                  }
                },
          onExit: requestAppExit,
        ),
      ),
      GoRoute(
        path: '/resetting',
        builder: (context, state) => const _MinimalProgressPage(),
      ),
    ],
  );
}

String? _minimalRouteRedirect(
  MinimalAppStateController? appState,
  GoRouterState state,
) {
  final phase = appState?.viewState.phase;
  final location = state.matchedLocation;
  if (phase == MinimalAppPhase.resetFailed) {
    return location == '/reset-recovery' ? null : '/reset-recovery';
  }
  if (phase == MinimalAppPhase.resetting) {
    return location == '/resetting' ? null : '/resetting';
  }
  if (location == '/reset-recovery' || location == '/resetting') {
    return '/sync';
  }
  return null;
}

final class ResetRecoveryView extends StatelessWidget {
  const ResetRecoveryView({
    required this.safeCode,
    required this.onRetry,
    required this.onExit,
    super.key,
  });

  final String? safeCode;
  final Future<void> Function()? onRetry;
  final Future<void> Function()? onExit;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('恢复本地状态'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 16),
              Text('重置失败', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                '错误代码：${safeCode ?? MinimalAppStateController.resetFailedCode}',
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                key: const Key('retry-reset'),
                onPressed: onRetry == null
                    ? null
                    : () async {
                        try {
                          await onRetry!();
                        } on Object {
                          // The controller remains in the safe recovery
                          // state and exposes another retry.
                        }
                      },
                icon: const Icon(Icons.refresh),
                label: const Text('重试清除全部数据'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('exit-app'),
                onPressed: onExit == null
                    ? null
                    : () async {
                        try {
                          await onExit!();
                        } on Object {
                          // Exit is best effort; no raw platform error is
                          // allowed to escape into the recovery UI.
                        }
                      },
                icon: const Icon(Icons.exit_to_app),
                label: const Text('退出应用'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _MinimalProgressPage extends StatelessWidget {
  const _MinimalProgressPage();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

/// Resolves the one app-owned runtime for a source route. Direct router
/// construction in embedded/test hosts remains side-effect free and renders
/// [missingRuntime] rather than constructing a page-owned gateway.
final class _RuntimeSyncRoute extends StatelessWidget {
  const _RuntimeSyncRoute({
    required this.owner,
    required this.builder,
    required this.missingRuntime,
  });

  final MinimalJwRuntimeOwner? owner;
  final Widget Function(MinimalJwRuntime runtime) builder;
  final Widget missingRuntime;

  @override
  Widget build(BuildContext context) {
    final runtimeOwner = owner;
    if (runtimeOwner == null) return missingRuntime;
    return FutureBuilder<MinimalJwRuntime>(
      future: runtimeOwner.current,
      builder: (context, snapshot) {
        if (snapshot.hasError) return missingRuntime;
        final runtime = snapshot.data;
        if (runtime == null) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return MinimalJwRuntimeScope(runtime: runtime, child: builder(runtime));
      },
    );
  }
}

void _replaceRuntimeAndGo(BuildContext context, MinimalJwRuntimeOwner? owner) {
  final runtimeOwner = owner;
  if (runtimeOwner == null) {
    context.go('/sync');
    return;
  }
  unawaited(
    runtimeOwner.replaceAfterReset().then<void>(
      (_) {
        if (context.mounted) context.go('/sync');
      },
      onError: (Object _, StackTrace _) {
        // Keep the current route visible on a failed teardown; no fresh
        // browser environment may be created while the old one is uncertain.
      },
    ),
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

class _ScheduleConflictsLoader extends StatelessWidget {
  const _ScheduleConflictsLoader({
    required this.database,
    required this.request,
  });

  final AppDatabase database;
  final ConflictManagementRequest? request;

  @override
  Widget build(BuildContext context) {
    // Only a ConflictManagementRequest with at least two items is accepted.
    // Missing or invalid extras render an empty-state page.
    final items = request?.items;
    if (items == null || items.length < 2) {
      return Scaffold(
        appBar: AppBar(title: const Text('处理重叠日程')),
        body: const Center(child: Text('没有可处理的重叠日程')),
      );
    }
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
          return Scaffold(
            appBar: AppBar(title: const Text('处理重叠日程')),
            body: const Center(child: Text('请先配置学校账号')),
          );
        }
        return ConflictManagementPage(
          database: database,
          accountId: account.id,
          items: items,
        );
      },
    );
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
  const _SettingsLoader({
    required this.database,
    this.runtimeOwner,
    this.resetCoordinatorLoader,
    this.coordinatedReset,
  });

  final AppDatabase database;
  final MinimalJwRuntimeOwner? runtimeOwner;
  final Future<MinimalResetCoordinator> Function()? resetCoordinatorLoader;
  final Future<void> Function()? coordinatedReset;

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
        final runtimeOwner = this.runtimeOwner;
        final accounts = AccountService(
          database: database,
          protector: defaultCredentialProtector(),
        );
        final resetLoader = resetCoordinatorLoader;
        return SettingsPage(
          service: SettingsService(
            database: database,
            accounts: accounts,
            accountId: account?.id,
          ),
          onFirstLogin: account == null ? () => context.go('/sync') : null,
          coordinatedReset: coordinatedReset ??
              (resetLoader == null
                  ? null
                  : () async => (await resetLoader()).completeReset()),
          onCompleteReset: () {
            if (resetLoader != null) {
              context.go('/sync');
            } else {
              _replaceRuntimeAndGo(context, runtimeOwner);
            }
          },
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
            protector: defaultCredentialProtector(),
          ),
          provider: AnthropicLlmProvider(),
          chatRepository: chatRepository,
          policyService: AgentPermissionPolicyService(
            database: database,
            clock: const SystemBeijingClock(),
          ),
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
/// expensive composition (secret store, DPAPI protector) is cached one level
/// down in [_AgentChatCompositionBuilder], also in `initState`. Both happen
/// once per route entry, not per rebuild.
class _AgentChatLoader extends StatefulWidget {
  const _AgentChatLoader({
    required this.database,
    required this.websiteLauncher,
    required this.compositionLoader,
    this.compositionOwner,
    this.onReset,
  });

  final AppDatabase database;
  final OfficialWebsiteLauncher websiteLauncher;
  final AgentCompositionLoader compositionLoader;
  final AgentCompositionOwner? compositionOwner;
  final VoidCallback? onReset;

  @override
  State<_AgentChatLoader> createState() => _AgentChatLoaderState();
}

class _AgentChatLoaderState extends State<_AgentChatLoader> {
  late Future<LocalAccount?> _accountFuture;
  StreamSubscription<void>? _accountSubscription;

  @override
  void initState() {
    super.initState();
    _accountFuture = _activeAccount(widget.database);
    _accountSubscription = widget.database.activeAccountChanges.listen((_) {
      if (mounted) {
        setState(() {
          _accountFuture = _activeAccount(widget.database);
        });
      }
    });
  }

  @override
  void dispose() {
    unawaited(_accountSubscription?.cancel());
    super.dispose();
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
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('请先配置学校账号'),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const Key('first-login-entry'),
                    onPressed: () => context.go('/sync'),
                    icon: const Icon(Icons.login),
                    label: const Text('登录教务'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const Key('complete-reset'),
                    onPressed: widget.onReset,
                    icon: const Icon(Icons.delete_forever_outlined),
                    label: const Text('清除全部数据'),
                  ),
                ],
              ),
            ),
          );
        }

        return _AgentChatCompositionBuilder(
          key: ValueKey(account.id),
          database: widget.database,
          accountId: account.id,
          websiteLauncher: widget.websiteLauncher,
          compositionLoader: widget.compositionLoader,
          compositionOwner: widget.compositionOwner,
        );
      },
    );
  }
}

/// Builds the AgentComposition for the active account and renders AgentChatPage.
///
/// The composition future (username resolution + `AgentComposition.build`,
/// which constructs the secret store/DPAPI protector) is created ONCE in
/// [initState] and reused across rebuilds. This is critical: creating it in
/// `build` would re-run the full composition — including DB queries — on
/// every rebuild.
class _AgentChatCompositionBuilder extends StatefulWidget {
  const _AgentChatCompositionBuilder({
    required this.database,
    required this.accountId,
    required this.websiteLauncher,
    required this.compositionLoader,
    this.compositionOwner,
    super.key,
  });

  final AppDatabase database;
  final String accountId;
  final OfficialWebsiteLauncher websiteLauncher;
  final AgentCompositionLoader compositionLoader;
  final AgentCompositionOwner? compositionOwner;

  @override
  State<_AgentChatCompositionBuilder> createState() =>
      _AgentChatCompositionBuilderState();
}

class _AgentChatCompositionBuilderState
    extends State<_AgentChatCompositionBuilder> {
  late Future<AgentCompositionResult> _compositionFuture;
  AgentCompositionResult? _composition;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    final owner = widget.compositionOwner;
    _compositionFuture = _trackComposition(
      owner == null
          ? widget.compositionLoader(widget.database, widget.accountId)
          : owner.load(widget.database, widget.accountId),
    );
  }

  Future<AgentCompositionResult> _trackComposition(
    Future<AgentCompositionResult> future,
  ) async {
    final composition = await future;
    if (_disposed) {
      if (widget.compositionOwner == null) await composition.dispose();
      throw StateError('composition_disposed');
    }
    _composition = composition;
    return composition;
  }

  Future<void> _reloadComposition() async {
    final owner = widget.compositionOwner;
    if (owner != null) {
      await owner.recompose();
      if (!mounted) return;
      setState(() {
        _compositionFuture = _trackComposition(
          owner.load(widget.database, widget.accountId),
        );
      });
      return;
    }
    final previous = _composition;
    _composition = null;
    if (previous != null) await previous.dispose();
    if (!mounted) return;
    setState(() {
      _compositionFuture = _trackComposition(
        widget.compositionLoader(widget.database, widget.accountId),
      );
    });
  }

  @override
  void dispose() {
    _disposed = true;
    final composition = _composition;
    if (widget.compositionOwner == null && composition != null) {
      unawaited(composition.dispose());
    }
    super.dispose();
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
          return const Scaffold(body: Center(child: Text('无法获取学校账号')));
        }
        final composition = snapshot.data;
        if (composition == null) {
          return const Scaffold(body: Center(child: Text('无法加载 Agent 服务')));
        }

        return AgentChatPage(
          accountId: widget.accountId,
          config: composition.configService,
          secrets: composition.secretStore,
          provider: composition.provider,
          sessionService: composition.sessionService,
          chatRepository: composition.chatRepository,
          websiteLauncher: widget.websiteLauncher,
          sessionModel: composition.model,
          onSessionModelChanged: _reloadComposition,
          disposeSessionOnDispose: widget.compositionOwner == null,
        );
      },
    );
  }
}

/// Sentinel thrown when the active account's username cannot be resolved, so
/// the composition future fails fast with a recognizable error instead of
/// building a composition with an empty username.
class _NoResolvedUsername implements Exception {
  const _NoResolvedUsername();
}

Future<AgentCompositionResult> buildAgentComposition(
  AppDatabase database,
  String accountId,
) async {
  final accounts = AccountService(
    database: database,
    protector: defaultCredentialProtector(),
  );
  final resolvedUsername = await _resolvedUsername(accounts, accountId);
  if (resolvedUsername.isEmpty) throw const _NoResolvedUsername();

  return AgentComposition.build(
    database: database,
    accountId: accountId,
    resolvedUsername: resolvedUsername,
    accounts: accounts,
    secretStoreFactory: (db) => ProtectedAgentSecretStore(
      database: db,
      protector: defaultCredentialProtector(),
    ),
  );
}

Future<String> _resolvedUsername(
  AccountService accounts,
  String accountId,
) async {
  try {
    return await accounts.usernameForSync(accountId);
  } catch (_) {
    return '';
  }
}

Future<LocalAccount?> _activeAccount(AppDatabase database) => (database.select(
  database.localAccounts,
)..where((row) => row.isActive.equals(true))).getSingleOrNull();

/// Resolves the schedule section from the route's `?section=` query parameter.
/// Only `week` and `tasks` are recognized; any other or missing value (and
/// repeated parameters) default to the week view.
ScheduleSection _scheduleSectionFromRoute(GoRouterState state) {
  final raw = state.uri.queryParameters['section'];
  return switch (raw) {
    'tasks' => ScheduleSection.tasks,
    _ => ScheduleSection.week,
  };
}

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
