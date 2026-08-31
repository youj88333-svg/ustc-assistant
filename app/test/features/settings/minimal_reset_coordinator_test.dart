import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/security/credential_protector.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/accounts/application/account_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_context_builder.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_session_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_tool_registry.dart';
import 'package:ustc_assistant_app/features/agent/application/cancellation_signal.dart';
import 'package:ustc_assistant_app/features/agent/application/outbound_privacy_filter.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_tool.dart';
import 'package:ustc_assistant_app/features/agent/domain/llm_protocol.dart';
import 'package:ustc_assistant_app/features/agent/data/drift_chat_repository.dart';
import 'package:ustc_assistant_app/features/reminders/application/reminder_service.dart';
import 'package:ustc_assistant_app/features/reminders/application/windows_reminder_reconciler.dart';
import 'package:ustc_assistant_app/features/reminders/data/foreground_notification_adapter.dart';
import 'package:ustc_assistant_app/features/settings/application/minimal_reset_coordinator.dart';
import 'package:ustc_assistant_app/features/settings/application/settings_service.dart';
import 'package:ustc_assistant_app/features/sync/domain/sync_state.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_browser_session_admin.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_webview_surface_host.dart';
import 'package:ustc_assistant_app/features/sync/native/windows_jw_udf_store.dart';
import 'package:ustc_assistant_app/features/sync/runtime/minimal_jw_runtime.dart';
import 'package:ustc_assistant_app/features/sync/runtime/source_job_gateway.dart';

void main() {
  test(
    'reset settles all fixed writers before clearing either store',
    () async {
      final events = <String>[];
      final runtime = _runtime(events);
      final sync = _Writer('sync', events);
      final agent = _Writer('agent', events);
      final reminders = _Writer('reminder', events);
      final settings = _SettingsSpy(_database(), events);
      addTearDown(settings.database.close);
      final udf = await _udfStore(events);
      final coordinator = MinimalResetCoordinator(
        runtime: runtime,
        sync: sync,
        agent: agent,
        reminders: reminders,
        settings: settings,
        udfStore: udf,
        recomposeRuntime: () async => events.add('runtime.recompose'),
      );

      final reset = coordinator.completeReset();
      await Future<void>.microtask(() {});
      expect(
        events,
        containsAll(<String>[
          'jw.cancel_and_settle',
          'sync.quiesce',
          'agent.quiesce',
          'reminder.quiesce',
        ]),
      );
      expect(settings.clearCalls, 0);

      sync.allowQuiesce();
      agent.allowQuiesce();
      reminders.allowQuiesce();
      await reset;

      expect(
        events,
        containsAllInOrder(<String>[
          'sync.quiesce',
          'agent.quiesce',
          'reminder.quiesce',
          'database.clear_all',
          'udf.clear_all',
          'runtime.recompose',
          'sync.resume',
          'agent.resume',
          'reminder.resume',
        ]),
      );
    },
  );

  test('a late writer is rejected once reset closes admission', () async {
    final writer = _Writer('sync', <String>[]);
    final reset = _coordinator(
      sync: writer,
      agent: _Writer('agent', <String>[]),
      reminders: _Writer('reminder', <String>[]),
    );

    final future = reset.completeReset();
    expect(writer.admitWrite(), isFalse);
    writer.allowQuiesce();
    // The fixed barrier waits every writer, not only the one under test.
    (reset.agent as _Writer).allowQuiesce();
    (reset.reminders as _Writer).allowQuiesce();
    await future;
    expect(writer.admitWrite(), isTrue);
  });

  test('quiesce failure stays failed and never resumes or clears', () async {
    final events = <String>[];
    final settings = _SettingsSpy(_database(), events);
    addTearDown(settings.database.close);
    final sync = _Writer('sync', events, failure: StateError('sync failed'));
    final agent = _Writer('agent', events);
    final reminders = _Writer('reminder', events);
    final coordinator = MinimalResetCoordinator(
      runtime: _runtime(events),
      sync: sync,
      agent: agent,
      reminders: reminders,
      settings: settings,
      udfStore: await _udfStore(events),
      recomposeRuntime: () async => events.add('runtime.recompose'),
    );

    agent.allowQuiesce();
    reminders.allowQuiesce();
    await expectLater(coordinator.completeReset(), throwsA(isA<StateError>()));
    expect(settings.clearCalls, 0);
    expect(events.where((event) => event.endsWith('.resume')), isEmpty);
    expect(events, contains('agent.quiesce'));
    expect(events, contains('reminder.quiesce'));
  });

  test('resume failure closes every writer gate again', () async {
    final events = <String>[];
    final sync = _Writer('sync', events);
    final agent = _Writer(
      'agent',
      events,
      resumeFailure: StateError('agent resume failed'),
    );
    final reminders = _Writer('reminder', events);
    final coordinator = MinimalResetCoordinator(
      runtime: _runtime(events),
      sync: sync,
      agent: agent,
      reminders: reminders,
      settings: _SettingsSpy(_database(), events),
      udfStore: await _udfStore(events),
      recomposeRuntime: () async => events.add('runtime.recompose'),
    );
    addTearDown(() => (coordinator.settings as _SettingsSpy).database.close());
    sync.allowQuiesce();
    agent.allowQuiesce();
    reminders.allowQuiesce();

    await expectLater(coordinator.completeReset(), throwsA(isA<StateError>()));
    expect(coordinator.phase, MinimalResetPhase.failed);
    expect(sync.admitWrite(), isFalse);
    expect(agent.admitWrite(), isFalse);
    expect(reminders.admitWrite(), isFalse);
  });

  test(
    'UDF failure attempts later partitions and retry works with empty DB',
    () async {
      final events = <String>[];
      final root = await Directory.systemTemp.createTemp('ustc-reset-test-');
      addTearDown(() => root.delete(recursive: true));
      final store = WindowsJwUdfStore(
        privateRoot: root,
        releaseAttempts: 1,
        releaseRetryDelay: Duration.zero,
        deleteDirectory: (directory) async {
          events.add(
            'udf.${directory.path.split(Platform.pathSeparator).last}',
          );
          if (events.where((event) => event.startsWith('udf.')).length == 1) {
            throw const FileSystemException('test failure');
          }
          await directory.delete(recursive: true);
        },
      );
      final first = store.referenceFor('first');
      final second = store.referenceFor('second');
      await store.ensurePartition(first);
      await store.ensurePartition(second);
      final settings = _SettingsSpy(_database(), events);
      addTearDown(settings.database.close);
      final sync = _Writer('sync', events);
      final agent = _Writer('agent', events);
      final reminders = _Writer('reminder', events);
      final retryCoordinator = MinimalResetCoordinator(
        runtime: _runtime(events),
        sync: sync,
        agent: agent,
        reminders: reminders,
        settings: settings,
        udfStore: store,
        recomposeRuntime: () async => events.add('runtime.recompose'),
      );

      sync.allowQuiesce();
      agent.allowQuiesce();
      reminders.allowQuiesce();
      await expectLater(
        retryCoordinator.completeReset(),
        throwsA(isA<StateError>()),
      );
      expect(events.where((event) => event.startsWith('udf.')), hasLength(2));
      expect(events, isNot(contains('runtime.recompose')));
      expect(events.where((event) => event.endsWith('.resume')), isEmpty);

      await retryCoordinator.retryReset();
      expect(settings.clearCalls, 2);
      expect(events, contains('runtime.recompose'));
      expect(events.where((event) => event.endsWith('.resume')), hasLength(3));
    },
  );

  test(
    'real Agent session drains cancellation before reset can continue',
    () async {
      final database = _database();
      addTearDown(database.close);
      await database
          .into(database.localAccounts)
          .insert(
            LocalAccountsCompanion.insert(
              id: 'agent-account',
              maskedHint: 'PB****0000',
              isActive: const Value(true),
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      final provider = _BlockingAgentProvider();
      final privacy = OutboundPrivacyFilter(
        protectedAccount: 'PB12345678',
        toolBuilders: const <String, ToolPayloadBuilder>{},
      );
      final service = AgentSessionService(
        chatRepository: DriftChatRepository(database),
        database: database,
        provider: provider,
        contextBuilder: const AgentContextBuilder(),
        privacyFilter: privacy,
        registry: AgentToolRegistry(
          tools: const <AgentTool>[],
          privacyFilter: privacy,
        ),
        clock: const SystemBeijingClock(),
        model: 'test-model',
        apiKeyProvider: ({required accountId}) async => 'ephemeral-test-key',
      );

      final run = service
          .send(accountId: 'agent-account', userText: '请读取本地日程')
          .toList();
      await provider.started.future;
      final quiesce = service.quiesce();
      final late = await service
          .send(accountId: 'agent-account', userText: 'late')
          .toList();
      expect(late.single.errorCode, 'maintenance_in_progress');
      await provider.cancellationObserved.future;
      var settled = false;
      unawaited(quiesce.then<void>((_) => settled = true));
      await Future<void>.microtask(() {});
      expect(settled, isFalse);
      provider.release();
      await quiesce;
      expect(settled, isTrue);
      await run;
      await service.resume();
      await service.dispose();
    },
  );

  test(
    'real reminder delivery is drained and late writes are refused',
    () async {
      final database = _database();
      addTearDown(database.close);
      const accountId = 'reminder-account';
      const now = 1000;
      await database
          .into(database.localAccounts)
          .insert(
            LocalAccountsCompanion.insert(
              id: accountId,
              maskedHint: 'PB****0000',
              isActive: const Value(true),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await database
          .into(database.calendarEvents)
          .insert(
            CalendarEventsCompanion.insert(
              id: 'event',
              accountId: accountId,
              source: 'user',
              title: 'event',
              type: 'personal',
              startAt: const Value(now + 3_600_000),
              endAt: const Value(now + 7_200_000),
              allDay: false,
              timezone: 'Asia/Shanghai',
              createdAt: now,
              updatedAt: now,
            ),
          );
      final timers = _TestReminderTimers();
      final notifications = _BlockingNotifications();
      final reconciler = WindowsReminderReconciler(
        database: database,
        reminderService: ReminderService(database: database, now: () => now),
        notifications: notifications,
        timers: timers,
        now: () => now,
      );
      await reconciler.reconcile(accountId: accountId, source: 'user');
      final reminder = await database.select(database.reminders).getSingle();
      final delivery = timers.callbacks[reminder.id]!();
      await notifications.started.future;

      final quiesce = reconciler.quiesce();
      final late = reconciler.rebuild(accountId);
      await expectLater(late, throwsA(isA<StateError>()));
      var settled = false;
      unawaited(quiesce.then<void>((_) => settled = true));
      await Future<void>.microtask(() {});
      expect(settled, isFalse);

      notifications.release();
      await delivery;
      await quiesce;
      expect(settled, isTrue);
      await reconciler.resume();
      await reconciler.rebuild(accountId);
      await reconciler.dispose();
    },
  );

  test('runtime owner retries a failed nonterminal reset shutdown', () async {
    final events = <String>[];
    final gateway = _RetryGateway(events);
    var loads = 0;
    final owner = MinimalJwRuntimeOwner(() async {
      loads++;
      return MinimalJwRuntime(
        gateway: gateway,
        browserSessions: _SessionAdmin(events),
      );
    });
    await owner.current;
    await expectLater(owner.prepareForReset(), throwsA(isA<StateError>()));
    expect(gateway.shutdownCalls, 1);

    await owner.prepareForReset();
    expect(gateway.shutdownCalls, 2);
    await owner.replaceAfterReset();
    expect(loads, 2);
    await owner.beginShutdown();
  });
}

MinimalResetCoordinator _coordinator({
  required _Writer sync,
  required _Writer agent,
  required _Writer reminders,
}) {
  final events = <String>[];
  final database = _database();
  addTearDown(database.close);
  final udfRoot = Directory.systemTemp.createTempSync('ustc-reset-empty-');
  addTearDown(() => udfRoot.delete(recursive: true));
  final settings = _SettingsSpy(database, events);
  return MinimalResetCoordinator(
    runtime: _runtime(events),
    sync: sync,
    agent: agent,
    reminders: reminders,
    settings: settings,
    udfStore: WindowsJwUdfStore(privateRoot: udfRoot),
    recomposeRuntime: () async {},
  );
}

MinimalJwRuntime _runtime(List<String> events) => MinimalJwRuntime(
  gateway: _Gateway(events),
  browserSessions: _SessionAdmin(events),
);

AppDatabase _database() => AppDatabase(NativeDatabase.memory());

Future<WindowsJwUdfStore> _udfStore(List<String> events) async {
  final root = await Directory.systemTemp.createTemp('ustc-reset-udf-');
  addTearDown(() => root.delete(recursive: true));
  final store = WindowsJwUdfStore(
    privateRoot: root,
    releaseAttempts: 1,
    releaseRetryDelay: Duration.zero,
    deleteDirectory: (directory) async {
      events.add('udf.clear_all');
      await directory.delete(recursive: true);
    },
  );
  await store.ensurePartition(store.referenceFor('reset-fixture'));
  return store;
}

final class _Writer implements ResetWriterPort {
  _Writer(this.name, this.events, {this.failure, this.resumeFailure});

  final String name;
  final List<String> events;
  final Object? failure;
  final Object? resumeFailure;
  final Completer<void> _quiesceGate = Completer<void>();
  bool _admitted = true;

  @override
  Future<void> quiesce() {
    _admitted = false;
    events.add('$name.quiesce');
    if (failure != null) return Future<void>.error(failure!);
    return _quiesceGate.future;
  }

  @override
  Future<void> resume() async {
    events.add('$name.resume');
    if (resumeFailure != null) throw resumeFailure!;
    _admitted = true;
  }

  bool admitWrite() => _admitted;

  void allowQuiesce() {
    if (!_quiesceGate.isCompleted) _quiesceGate.complete();
  }
}

final class _SettingsSpy extends SettingsService {
  _SettingsSpy(AppDatabase database, this.events)
    : super(
        database: database,
        accounts: AccountService(
          database: database,
          protector: _NoopProtector(),
        ),
        accountId: null,
      );

  final List<String> events;
  var clearCalls = 0;

  @override
  Future<void> clearAllLocalData() async {
    clearCalls++;
    events.add('database.clear_all');
  }
}

final class _NoopProtector implements CredentialProtector {
  @override
  Future<ProtectedSecret> protect(List<int> plaintext) async => ProtectedSecret(
    bytes: Uint8List.fromList(plaintext),
    scheme: 'test',
    version: 1,
  );

  @override
  Future<Uint8List> unprotect(ProtectedSecret protected) async =>
      Uint8List.fromList(protected.bytes);
}

final class _BlockingAgentProvider implements LlmProvider {
  final Completer<void> started = Completer<void>();
  final Completer<void> cancellationObserved = Completer<void>();
  final Completer<void> _release = Completer<void>();

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Future<List<String>> listModels({
    required String apiKey,
    required CancellationSignal cancellation,
  }) async => const ['test-model'];

  @override
  Stream<LlmEvent> stream({
    required String apiKey,
    required LlmRequest request,
    required CancellationSignal cancellation,
  }) async* {
    if (!started.isCompleted) started.complete();
    while (!cancellation.isCancelled) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    if (!cancellationObserved.isCompleted) cancellationObserved.complete();
    await _release.future;
    yield const CompletedEvent();
  }

  @override
  Future<void> probeText({
    required String apiKey,
    required String model,
    required CancellationSignal cancellation,
  }) async {}

  @override
  Future<void> probeTools({
    required String apiKey,
    required String model,
    required CancellationSignal cancellation,
  }) async {}
}

final class _TestReminderTimers implements ReminderTimerScheduler {
  final Map<String, Future<void> Function()> callbacks = {};

  @override
  void cancelAll() => callbacks.clear();

  @override
  void schedule(String id, Duration delay, Future<void> Function() callback) {
    callbacks[id] = callback;
  }
}

final class _BlockingNotifications implements ForegroundNotificationPort {
  final Completer<void> started = Completer<void>();
  final Completer<void> _release = Completer<void>();

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Future<void> deliver(ReminderNotification notification) async {
    if (!started.isCompleted) started.complete();
    await _release.future;
  }
}

final class _RetryGateway implements SourceJobGateway {
  _RetryGateway(this.events);

  final List<String> events;
  var shutdownCalls = 0;

  @override
  Stream<SourceJobSnapshot> get states => const Stream.empty();

  @override
  Future<SyncOutcome> firstLogin(FirstLoginCommand command) =>
      throw UnimplementedError();

  @override
  Future<SyncOutcome> sync({
    required String accountId,
    required SyncTrigger trigger,
  }) => throw UnimplementedError();

  @override
  Future<void> cancelCurrent() async {}

  @override
  Future<void> shutdown() async {
    shutdownCalls++;
    events.add('retry.shutdown.$shutdownCalls');
    if (shutdownCalls == 1) throw StateError('transient shutdown');
  }
}

final class _Gateway implements SourceJobGateway {
  _Gateway(this.events);

  final List<String> events;

  @override
  Stream<SourceJobSnapshot> get states => const Stream.empty();

  @override
  Future<void> cancelCurrent() async => events.add('jw.cancel_and_settle');

  @override
  Future<SyncOutcome> firstLogin(FirstLoginCommand command) =>
      throw UnimplementedError();

  @override
  Future<SyncOutcome> sync({
    required String accountId,
    required SyncTrigger trigger,
  }) => throw UnimplementedError();

  @override
  Future<void> shutdown() async => events.add('jw.cancel_and_settle');
}

final class _SessionAdmin implements JwBrowserSessionAdmin {
  _SessionAdmin(this.events);

  final List<String> events;

  @override
  JwWebViewSurfaceHost get surfaceHost => JwWebViewSurfaceHost();

  @override
  Future<JwBrowserSessionHandle> open(String accountId) =>
      throw UnimplementedError();

  @override
  Future<void> clearAllPartitions() async => events.add('udf.clear_all');

  @override
  Future<void> shutdown() async => events.add('jw.shutdown_and_release');
}
