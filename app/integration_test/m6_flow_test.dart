import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/agent/agent_tool_contract.dart';
import 'package:ustc_assistant_m0/app/demo_runtime.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/core/settings_contract.dart';
import 'package:ustc_assistant_m0/core/speech_input_contract.dart';

import 'support/diagnostic_cleanup.dart';

final _now = DateTime.utc(2026, 10, 15);
final _day = DateTime.utc(2026, 10, 16);
final _agendaQuery = CalendarQuery(
  firstDay: _day,
  endDayExclusive: DateTime.utc(2026, 10, 17),
  includeHidden: true,
  includeSkipped: true,
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets(
    'composed Agent reminder tools commit and undo against the native temporary store and reconcile the fake OS queue',
    (tester) async {
      final workspace = await _createWorkspace();
      final bootstraps = <RuntimeBootstrap>[];
      final os = _FakeNotificationQueue();
      final platform = _FakeNotificationPlatform(os);
      final gateway = _NoNetworkGateway();
      AgentToolSession? session;
      try {
        final bootstrap = await _openBootstrap(
          tester,
          workspace,
          platform,
          gateway,
        );
        bootstraps.add(bootstrap);
        final runtime = bootstrap.runtime!;
        final created = await _write(
          tester,
          runtime,
          CreatePersonalEvent(
            PersonalEventDraft(
              title: 'Agent 合成提醒安排',
              start: DateTime.utc(2026, 10, 16, 6),
              end: DateTime.utc(2026, 10, 16, 7),
            ),
          ),
        );
        final data = runtime.jwStore.agent;
        final ticket = await _runNative(tester, () async {
          final settings = await data.inspectAgent();
          await data.saveModelConfiguration(
            settings.authority,
            modelId: 'synthetic-reminder-model',
            modelIds: const ['synthetic-reminder-model'],
            report: const AgentCapabilityReport(
              text: true,
              streaming: true,
              toolCall: true,
              toolResult: true,
            ),
            consent: true,
            key: Uint8List.fromList('m6-agent-synthetic-key-only'.codeUnits),
          );
          final current = await data.inspectAgent();
          final conversation = await data.createConversation();
          return data.beginRun(
            current.authority,
            conversation,
            '开启提醒，将这次安排提前十分钟和两分钟提醒',
          );
        });
        final tools = runtime.agentCoordinator.readTools!;
        expect(tools.definitions.map((d) => d.name).toSet(), hasLength(20));
        expect(
          tools.definitions.any((d) => d.name == 'query_reminders'),
          isTrue,
        );
        session = tools.openSession();
        final interactive = session as AgentInteractiveToolSession;
        interactive.bindRun(ticket, '开启提醒，将这次安排提前十分钟和两分钟提醒');
        Future<dynamic> call(String name, Map<String, Object?> args) =>
            _runNative(
              tester,
              () => session!.execute(
                ModelToolCall(
                  id: 'synthetic-$name',
                  name: name,
                  argumentsJson: jsonEncode(args),
                ),
              ),
            );
        Future<String> eventRef() async {
          final result = await call('query_agenda', {
            'first_day': '2026-10-16',
            'end_day_exclusive': '2026-10-17',
          });
          expect(result.status, 'success');
          return ((result.data['items'] as List).single as Map)['event_ref']
              as String;
        }

        var token = await eventRef();
        final prepared = await call('propose_local_changes', {
          'changes': [
            {'type': 'set_notification_preferences', 'enabled': true},
            {
              'type': 'set_reminders',
              'event_ref': token,
              'reminders': [
                {'kind': 'before', 'minutes_before': 10},
                {'kind': 'before', 'minutes_before': 2},
              ],
            },
          ],
        });
        expect(prepared.status, 'waitingForApproval');
        expect(os.pending, isEmpty);
        expect(
          (await _runNative(
            tester,
            runtime.jwStore.features.inspectReminders,
          )).preferences.enabled,
          isFalse,
        );
        final committed = await _runNative(
          tester,
          () => interactive.decidePending(true),
        );
        expect(committed.status, 'committed');
        expect(committed.data['reminder_effect'], contains('规则已保存'));
        interactive.acknowledgeContextInvalidated();
        await _refreshUntil(
          tester,
          runtime,
          () =>
              !runtime.reminders.view.busy &&
              runtime.reminders.view.accepted == 2 &&
              os.pending.length == 2,
        );
        expect(os.pending.values.map((p) => p.deliveryAtUtc).toSet(), {
          DateTime.utc(2026, 10, 16, 5, 50),
          DateTime.utc(2026, 10, 16, 5, 58),
        });
        token = await eventRef();
        final inspected = await call('query_reminders', {'event_ref': token});
        expect(inspected.status, 'success');
        expect(
          (inspected.data['target'] as Map)['accepted_slots'],
          hasLength(2),
        );
        expect((inspected.data['runtime'] as Map)['system_available'], isTrue);
        expect(
          jsonEncode(inspected.data),
          isNot(contains(os.pending.values.first.token)),
        );
        expect((await call('propose_undo', {})).status, 'waitingForApproval');
        expect(
          (await _runNative(
            tester,
            () => interactive.decidePending(true),
          )).status,
          'committed',
        );
        await _refreshUntil(
          tester,
          runtime,
          () => !runtime.reminders.view.busy && os.pending.isEmpty,
        );
        expect(
          (await _runNative(
            tester,
            runtime.jwStore.features.inspectReminders,
          )).preferences.enabled,
          isFalse,
        );
        expect(
          await _runNative(tester, () async {
            final current = (await runtime.jwStore.localCalendar.query(
              _agendaQuery,
            )).items.single;
            expect(current.reference.identity, created.target!.identity);
            return runtime.jwStore.features.readReminderPair(
              ReminderTarget.calendar(current.reference),
            );
          }),
          isNull,
        );
        expect(gateway.requestCalls, 0);
        await _runNative(
          tester,
          () => data.finishRun(ticket, AgentMessageStatus.complete),
        );
      } finally {
        session?.revoke();
        await _disposeAndClean(tester, workspace, bootstraps);
      }
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'M6 publishes synthetic C3 reminders, reconciles changes, and preserves the fake OS queue on close',
    (tester) async {
      final workspace = await _createWorkspace();
      final os = _FakeNotificationQueue();
      final firstPlatform = _FakeNotificationPlatform(os);
      final firstGateway = _NoNetworkGateway();
      final bootstraps = <RuntimeBootstrap>[];
      try {
        final first = await _openBootstrap(
          tester,
          workspace,
          firstPlatform,
          firstGateway,
        );
        bootstraps.add(first);
        final runtime = first.runtime!;
        final defaults = await _runNative(
          tester,
          runtime.jwStore.features.inspectReminders,
        );
        expect(defaults.preferences.enabled, isFalse);
        expect(defaults.preferences.morningEnabled, isFalse);
        await _refreshUntil(tester, runtime, () {
          final view = runtime.reminders.view;
          return view.complete && !view.busy && view.desired == 0;
        });
        expect(firstPlatform.initializeCalls, 0);
        expect(firstPlatform.scheduleCalls, 0);
        expect(os.pending, isEmpty);

        await _seedSyntheticSchoolEvent(tester, runtime);
        final personal = await _write(
          tester,
          runtime,
          CreatePersonalEvent(
            PersonalEventDraft(
              title: 'M6 合成个人日程',
              start: DateTime.utc(2026, 10, 16, 5),
              end: DateTime.utc(2026, 10, 16, 5, 30),
              location: '合成自习室',
              note: '仅在 TEMP 流程中使用',
            ),
          ),
        );
        final task = await _write(
          tester,
          runtime,
          CreateTask(
            TaskDraft(
              title: 'M6 合成任务',
              deadlineAtUtc: DateTime.utc(2026, 10, 16, 10),
              estimatedMinutes: 60,
            ),
          ),
        );
        final block = await _write(
          tester,
          runtime,
          CreatePlanBlock(
            task.task!,
            PlanBlockDraft(
              startsAtUtc: DateTime.utc(2026, 10, 16, 8),
              endsAtUtc: DateTime.utc(2026, 10, 16, 8, 30),
              location: '合成图书馆',
            ),
          ),
        );
        expect(personal.target, isNotNull);
        expect(block.target, isNotNull);

        await _setRemindersEnabled(tester, runtime, true);
        await _refreshUntil(tester, runtime, () {
          final view = runtime.reminders.view;
          return view.complete &&
              !view.busy &&
              view.desired == 4 &&
              view.accepted == 4 &&
              os.pending.length == 4;
        });
        final initial = await _publication(tester, runtime);
        final initialByKind = _mappingByKind(initial);
        expect(initialByKind.keys.toSet(), {
          ReminderKind.course,
          ReminderKind.personal,
          ReminderKind.planBlock,
          ReminderKind.taskDeadline,
        });
        _expectFullReadback(os, initial.desired.map((item) => item.request));
        expect(firstPlatform.scheduleCalls, 4);
        expect(firstGateway.requestCalls, 0);

        final personalDetail = await _runNative(
          tester,
          () => runtime.jwStore.localCalendar.detail(personal.target!),
        );
        final beforeReschedule = firstPlatform.operations.length;
        final originalDraft = personalDetail.personalDraft!;
        await _write(
          tester,
          runtime,
          UpdatePersonalSeries(
            personalDetail.occurrence.reference,
            PersonalEventDraft(
              title: originalDraft.title,
              start: DateTime.utc(2026, 10, 16, 6),
              end: DateTime.utc(2026, 10, 16, 6, 30),
              location: originalDraft.location,
              note: originalDraft.note,
            ),
          ),
        );
        await _refreshUntil(tester, runtime, () {
          final view = runtime.reminders.view;
          final request =
              os.pending[initialByKind[ReminderKind.personal]!.request.id];
          return view.complete &&
              !view.busy &&
              view.desired == 4 &&
              view.accepted == 4 &&
              request?.deliveryAtUtc == DateTime.utc(2026, 10, 16, 5, 30);
        });
        final updated = await _publication(tester, runtime);
        final updatedPersonal = _mappingByKind(updated)[ReminderKind.personal]!;
        expect(
          updatedPersonal.request.id,
          initialByKind[ReminderKind.personal]!.request.id,
        );
        final changedOperations = firstPlatform.operations
            .skip(beforeReschedule)
            .toList();
        expect(
          changedOperations.indexOf('cancel:${updatedPersonal.request.id}'),
          greaterThanOrEqualTo(0),
        );
        expect(
          changedOperations.indexOf('cancel:${updatedPersonal.request.id}'),
          lessThan(
            changedOperations.indexOf('schedule:${updatedPersonal.request.id}'),
          ),
        );
        _expectFullReadback(os, updated.desired.map((item) => item.request));

        final currentWindow = await _runNative(
          tester,
          () => runtime.jwStore.localCalendar.query(_agendaQuery),
        );
        final currentSchoolEvent = currentWindow.items.singleWhere(
          (item) => item.reference.identity.kind == CalendarKind.course,
        );
        final hiddenId = initialByKind[ReminderKind.course]!.request.id;
        await _write(
          tester,
          runtime,
          UpdateSchoolAnnotation(currentSchoolEvent.reference, hidden: true),
        );
        await _refreshUntil(tester, runtime, () {
          final view = runtime.reminders.view;
          return view.complete &&
              !view.busy &&
              view.desired == 3 &&
              view.accepted == 3 &&
              os.pending.length == 3 &&
              !os.pending.containsKey(hiddenId);
        });
        expect(firstPlatform.cancelledIds, contains(hiddenId));

        final remainingPublication = await _publication(tester, runtime);
        final remainingByKind = _mappingByKind(remainingPublication);
        final persistentIds = {
          for (final item in remainingByKind.entries)
            item.key: item.value.request.id,
        };
        _expectFullReadback(
          os,
          remainingPublication.desired.map((item) => item.request),
        );
        await _closeBootstrap(tester, first);
        expect(firstPlatform.closeCalls, 1);
        expect(os.pending.length, 3);
        expect(
          os.pending.keys.toSet(),
          persistentIds.values.toSet(),
          reason:
              'Normal close releases the port without clearing fake OS plans.',
        );

        final secondPlatform = _FakeNotificationPlatform(os);
        final secondGateway = _NoNetworkGateway();
        final reopened = await _openBootstrap(
          tester,
          workspace,
          secondPlatform,
          secondGateway,
        );
        bootstraps.add(reopened);
        final reopenedRuntime = reopened.runtime!;
        await _refreshUntil(tester, reopenedRuntime, () {
          final view = reopenedRuntime.reminders.view;
          return view.complete &&
              !view.busy &&
              view.desired == 3 &&
              view.accepted == 3 &&
              os.pending.length == 3;
        });
        final reopenedPublication = await _publication(tester, reopenedRuntime);
        final reopenedByKind = _mappingByKind(reopenedPublication);
        expect(reopenedByKind.keys.toSet(), persistentIds.keys.toSet());
        for (final entry in persistentIds.entries) {
          expect(reopenedByKind[entry.key]!.request.id, entry.value);
        }
        expect(secondPlatform.initializeCalls, greaterThan(0));
        expect(secondPlatform.scheduleCalls, 0);
        _expectFullReadback(
          os,
          reopenedPublication.desired.map((item) => item.request),
        );

        await _setRemindersEnabled(tester, reopenedRuntime, false);
        await _refreshUntil(tester, reopenedRuntime, () {
          final view = reopenedRuntime.reminders.view;
          return view.complete &&
              !view.busy &&
              view.desired == 0 &&
              view.accepted == 0 &&
              os.pending.isEmpty;
        });
        expect(
          secondPlatform.cancelledIds.toSet(),
          containsAll(persistentIds.values),
        );
        expect(secondGateway.requestCalls, 0);
      } finally {
        await _disposeAndClean(tester, workspace, bootstraps);
        os.pending.clear();
      }
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'M6 maintenance retains C3 facts and mappings after fake OS cleanup failure, then clears OS before C3 retry',
    (tester) async {
      final workspace = await _createWorkspace();
      final os = _FakeNotificationQueue();
      final platform = _FakeNotificationPlatform(os)
        ..clearFailuresRemaining = 1;
      final gateway = _NoNetworkGateway();
      final bootstraps = <RuntimeBootstrap>[];
      try {
        final bootstrap = await _openBootstrap(
          tester,
          workspace,
          platform,
          gateway,
        );
        bootstraps.add(bootstrap);
        final runtime = bootstrap.runtime!;
        await _write(
          tester,
          runtime,
          CreatePersonalEvent(
            PersonalEventDraft(
              title: 'M6 维护合成日程',
              start: DateTime.utc(2026, 10, 16, 5),
              end: DateTime.utc(2026, 10, 16, 5, 30),
            ),
          ),
        );
        final task = await _write(
          tester,
          runtime,
          CreateTask(
            TaskDraft(
              title: 'M6 维护合成任务',
              deadlineAtUtc: DateTime.utc(2026, 10, 16, 10),
            ),
          ),
        );
        await _write(
          tester,
          runtime,
          CreatePlanBlock(
            task.task!,
            PlanBlockDraft(
              startsAtUtc: DateTime.utc(2026, 10, 16, 8),
              endsAtUtc: DateTime.utc(2026, 10, 16, 8, 30),
            ),
          ),
        );
        await _setRemindersEnabled(tester, runtime, true);
        await _refreshUntil(tester, runtime, () {
          final view = runtime.reminders.view;
          return view.complete &&
              !view.busy &&
              view.desired == 3 &&
              view.accepted == 3 &&
              os.pending.length == 3;
        });
        final publication = await _publication(tester, runtime);
        final idsBeforeMaintenance = publication.desired
            .map((item) => item.request.id)
            .toSet();
        expect(await _tableCount(tester, runtime, 'personal_events'), 1);
        expect(await _tableCount(tester, runtime, 'local_tasks'), 1);
        expect(await _tableCount(tester, runtime, 'local_plan_blocks'), 1);
        expect(await _tableCount(tester, runtime, 'm6_native_map'), 3);

        final settings = await _runNative(
          tester,
          runtime.jwStore.applicationSettings.inspectSettings,
        );
        await _runNative(
          tester,
          () => runtime.settings.runMaintenance(
            settings.context,
            MaintenanceKind.agenda,
            confirmed: true,
          ),
        );
        expect(bootstrap.maintenance.view.phase, MaintenancePhase.recovery);
        expect(
          bootstrap.settings.settingsView.maintenance.blocksProduct,
          isTrue,
        );
        expect(
          await _tableCount(
            tester,
            runtime,
            'agenda_state',
            column: 'maintenance',
          ),
          1,
        );
        expect(await _tableCount(tester, runtime, 'app_maintenance_intent'), 1);
        expect(await _tableCount(tester, runtime, 'personal_events'), 1);
        expect(await _tableCount(tester, runtime, 'local_tasks'), 1);
        expect(await _tableCount(tester, runtime, 'local_plan_blocks'), 1);
        expect(await _tableCount(tester, runtime, 'm6_native_map'), 3);
        expect(os.pending.keys.toSet(), idsBeforeMaintenance);
        expect(platform.clearCalls, 1);
        expect(platform.operations, contains('clear-failed'));

        await _runNative(tester, runtime.settings.retryMaintenance);
        expect(bootstrap.maintenance.view.phase, MaintenancePhase.idle);
        expect(platform.clearCalls, 2);
        expect(os.pending, isEmpty);
        expect(
          await _tableCount(
            tester,
            runtime,
            'agenda_state',
            column: 'maintenance',
          ),
          0,
        );
        expect(await _tableCount(tester, runtime, 'app_maintenance_intent'), 0);
        expect(await _tableCount(tester, runtime, 'personal_events'), 0);
        expect(await _tableCount(tester, runtime, 'local_tasks'), 0);
        expect(await _tableCount(tester, runtime, 'local_plan_blocks'), 0);
        expect(await _tableCount(tester, runtime, 'm6_native_map'), 0);
        expect(gateway.requestCalls, 0);
      } finally {
        await _disposeAndClean(tester, workspace, bootstraps);
        os.pending.clear();
      }
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'M6 maintenance on a never-enabled instance does not initialize notifications',
    (tester) async {
      final workspace = await _createWorkspace();
      final os = _FakeNotificationQueue();
      final platform = _FakeNotificationPlatform(os);
      final gateway = _NoNetworkGateway();
      final bootstraps = <RuntimeBootstrap>[];
      try {
        final bootstrap = await _openBootstrap(
          tester,
          workspace,
          platform,
          gateway,
        );
        bootstraps.add(bootstrap);
        final runtime = bootstrap.runtime!;
        final reminders = await _runNative(
          tester,
          runtime.jwStore.features.inspectReminders,
        );
        expect(reminders.preferences.enabled, isFalse);
        expect(reminders.preferences.morningEnabled, isFalse);
        expect(platform.initializeCalls, 0);

        await _runNative(
          tester,
          () async => runtime.settings.runMaintenance(
            (await runtime.jwStore.applicationSettings.inspectSettings())
                .context,
            MaintenanceKind.agenda,
            confirmed: true,
          ),
        );
        expect(bootstrap.maintenance.view.phase, MaintenancePhase.idle);
        expect(platform.initializeCalls, 0);
        expect(platform.clearCalls, 0);
        expect(platform.scheduleCalls, 0);
        expect(os.pending, isEmpty);
        expect(gateway.requestCalls, 0);
      } finally {
        await _disposeAndClean(tester, workspace, bootstraps);
      }
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'Windows notification debug test host drains an empty activation queue and rejects malformed arguments',
    (tester) async {
      const channel = MethodChannel('ustc_assistant/notifications');
      try {
        final activations = await _runNative(
          tester,
          () => channel.invokeMethod<List<Object?>>('activations'),
        );
        expect(activations, isEmpty);

        final capability = await _runNative(
          tester,
          () => channel.invokeMapMethod<String, Object?>('initialize'),
        );
        expect(capability, <String, Object?>{
          'available': false,
          'enabledBySystem': false,
          'schedulesAfterExit': false,
          'activationAvailable': false,
        });

        await expectLater(
          _runNative(
            tester,
            () => channel.invokeMethod<Object?>(
              'initialize',
              const <String, Object>{'unexpected': true},
            ),
          ),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'invalidInput',
            ),
          ),
        );
      } finally {
        await _runNative(tester, () => channel.invokeMethod<void>('close'));
      }
    },
    skip:
        !Platform.isWindows ||
        !kDebugMode ||
        Platform.environment['USTC_NOTIFICATION_TEST_HOST'] != '1',
  );
}

Future<RuntimeBootstrap> _openBootstrap(
  WidgetTester tester,
  _OwnedWorkspace workspace,
  _FakeNotificationPlatform notificationPlatform,
  _NoNetworkGateway gateway,
) => _runNative(
  tester,
  () => RuntimeBootstrap.open(
    directoryPath: workspace.demoPath,
    jwDirectoryPath: workspace.formalPath,
    clock: FixedClock(_now),
    notificationPlatform: notificationPlatform,
    modelGateway: gateway,
    morningGateway: gateway,
    speechInput: _IdleSpeechInput(),
  ),
);

Future<void> _seedSyntheticSchoolEvent(
  WidgetTester tester,
  DemoRuntime runtime,
) async {
  await _runNative(tester, () async {
    await runtime.jwStore.transaction(() async {
      await runtime.jwStore.customStatement(
        'INSERT INTO jw_account(account_id,expected_account_code) VALUES(1,?)',
        ['M6TEST01'],
      );
      await runtime.jwStore.customStatement(
        'INSERT INTO jw_events(external_id,kind,semester_id,title,starts_at,ends_at,presence,version) VALUES(?,?,?,?,?,?,?,1)',
        [
          'm6-synthetic-course',
          'course',
          202610,
          'M6 合成课程',
          DateTime.utc(2026, 10, 16, 13).microsecondsSinceEpoch,
          DateTime.utc(2026, 10, 16, 14).microsecondsSinceEpoch,
          'observed',
        ],
      );
      await runtime.jwStore.customStatement(
        'INSERT INTO jw_overlays(local_id,hidden) SELECT local_id,0 FROM jw_events WHERE external_id=?',
        ['m6-synthetic-course'],
      );
    });
  });
}

Future<CalendarWriteReceipt> _write(
  WidgetTester tester,
  DemoRuntime runtime,
  CalendarIntent intent,
) async {
  final context = (await _runNative(
    tester,
    runtime.jwStore.features.inspectReminders,
  )).context;
  return _runNative(tester, () async {
    final command = await runtime.jwStore.localCalendar.prepare(
      context,
      intent,
    );
    return runtime.jwStore.localCalendar.commit(command);
  });
}

Future<void> _setRemindersEnabled(
  WidgetTester tester,
  DemoRuntime runtime,
  bool enabled,
) async {
  final settings = await _runNative(
    tester,
    runtime.jwStore.features.inspectReminders,
  );
  await _runNative(
    tester,
    () => runtime.jwStore.features.saveReminderPreferences(
      settings,
      settings.preferences.copyWith(enabled: enabled),
    ),
  );
}

Future<ReminderPublication> _publication(
  WidgetTester tester,
  DemoRuntime runtime,
) => _runNative(tester, runtime.jwStore.features.prepareReminderPublication);

Map<ReminderKind, ReminderMapping> _mappingByKind(
  ReminderPublication publication,
) => {for (final mapping in publication.desired) mapping.target.kind: mapping};

void _expectFullReadback(
  _FakeNotificationQueue os,
  Iterable<NotificationRequest> requests,
) {
  final expected = requests.toList();
  expect(os.pending.length, expected.length);
  for (final request in expected) {
    final rows = os.pending.values
        .where((pending) => pending.id == request.id)
        .toList();
    expect(rows, hasLength(1));
    final pending = rows.single;
    expect(pending.id, request.id);
    expect(pending.deliveryAtUtc, request.deliveryAtUtc);
    expect(pending.digest, request.digest);
    expect(pending.token, request.token);
    expect(pending.title, request.title);
    expect(pending.detail, request.detail);
    expect(pending.location, request.location);
    expect(pending.matches(request), isTrue);
  }
}

Future<void> _refreshUntil(
  WidgetTester tester,
  DemoRuntime runtime,
  bool Function() settled,
) async {
  await _runNative(tester, runtime.reminders.refresh);
  final watch = Stopwatch()..start();
  while (!settled()) {
    if (watch.elapsed > const Duration(seconds: 12)) {
      throw StateError(
        'Synthetic reminder reconciliation did not settle: '
        '${runtime.reminders.view.failure?.name}',
      );
    }
    await _runNative(
      tester,
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump();
  }
}

Future<int> _tableCount(
  WidgetTester tester,
  DemoRuntime runtime,
  String table, {
  String? column,
}) async {
  final query = column == null
      ? 'SELECT COUNT(*) AS count FROM $table'
      : 'SELECT $column AS count FROM $table WHERE singleton=1';
  final row = await _runNative(
    tester,
    () => runtime.jwStore.customSelect(query).getSingle(),
  );
  return row.read<int>('count');
}

Future<void> _closeBootstrap(
  WidgetTester tester,
  RuntimeBootstrap bootstrap,
) async {
  await _runNative(tester, bootstrap.close);
  expect(bootstrap.directory.isHeld, isFalse);
  expect(bootstrap.jwDirectory.isHeld, isFalse);
}

Future<void> _disposeAndClean(
  WidgetTester tester,
  _OwnedWorkspace workspace,
  List<RuntimeBootstrap> bootstraps,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  for (final bootstrap in bootstraps.reversed) {
    await _closeBootstrap(tester, bootstrap);
  }
  await _deleteWorkspace(workspace);
}

Future<T> _runNative<T>(
  WidgetTester tester,
  Future<T> Function() action,
) async {
  late T result;
  Object? failure;
  StackTrace? failureStack;
  await tester.runAsync(() async {
    try {
      result = await action();
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    }
  });
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  return result;
}

Future<_OwnedWorkspace> _createWorkspace() async {
  const prefix = 'ustc_m6_flow_';
  final root = await Directory.systemTemp.createTemp(prefix);
  final rootPath = _normal(root.path);
  final tempPath = _normal(await Directory.systemTemp.resolveSymbolicLinks());
  final rootName = p.windows.basename(rootPath);
  if (!p.windows.equals(p.windows.dirname(rootPath), tempPath) ||
      !rootName.startsWith(prefix) ||
      rootName.length == prefix.length ||
      !RegExp(
        r'^[A-Za-z0-9_-]+$',
      ).hasMatch(rootName.substring(prefix.length)) ||
      !p.windows.equals(rootPath, _normal(await root.resolveSymbolicLinks())) ||
      await FileSystemEntity.type(rootPath, followLinks: false) !=
          FileSystemEntityType.directory) {
    throw StateError('Refusing an M6 workspace outside its nonce TEMP root.');
  }
  final nonce = _nonce();
  final markerName = '.m6-owner-$nonce.marker';
  final marker = File(p.windows.join(rootPath, markerName));
  final handle = await marker.open(mode: FileMode.writeOnly);
  try {
    await handle.writeString('$nonce\n');
    await handle.flush();
  } finally {
    await handle.close();
  }
  return _OwnedWorkspace(
    root: root,
    prefix: prefix,
    nonce: nonce,
    markerName: markerName,
    demoPath: p.windows.join(rootPath, 'demo-$nonce'),
    formalPath: p.windows.join(rootPath, 'formal-$nonce'),
  );
}

Future<void> _deleteWorkspace(_OwnedWorkspace workspace) async {
  final rootPath = _normal(workspace.root.path);
  final tempPath = _normal(await Directory.systemTemp.resolveSymbolicLinks());
  final rootName = p.windows.basename(rootPath);
  if (!p.windows.equals(p.windows.dirname(rootPath), tempPath) ||
      !rootName.startsWith(workspace.prefix) ||
      rootName.length == workspace.prefix.length ||
      !RegExp(
        r'^[A-Za-z0-9_-]+$',
      ).hasMatch(rootName.substring(workspace.prefix.length)) ||
      !p.windows.equals(
        rootPath,
        _normal(await workspace.root.resolveSymbolicLinks()),
      ) ||
      await FileSystemEntity.type(rootPath, followLinks: false) !=
          FileSystemEntityType.directory) {
    throw StateError(
      'Refusing to remove an M6 path outside its nonce TEMP root.',
    );
  }
  final markerPath = p.windows.join(rootPath, workspace.markerName);
  if (await FileSystemEntity.type(markerPath, followLinks: false) !=
          FileSystemEntityType.file ||
      await File(markerPath).readAsString() != '${workspace.nonce}\n') {
    throw StateError('Refusing to remove an M6 TEMP root without its marker.');
  }
  final expectedDemo = _normal(workspace.demoPath);
  final expectedFormal = _normal(workspace.formalPath);
  if (!p.windows.equals(p.windows.dirname(expectedDemo), rootPath) ||
      !p.windows.equals(p.windows.dirname(expectedFormal), rootPath) ||
      p.windows.basename(expectedDemo) != 'demo-${workspace.nonce}' ||
      p.windows.basename(expectedFormal) != 'formal-${workspace.nonce}') {
    throw StateError('Refusing to remove an unrecognized M6 TEMP child.');
  }
  await _assertNoLinks(workspace.root, rootPath);
  final children = await workspace.root.list(followLinks: false).toList();
  final names = {
    workspace.markerName,
    p.windows.basename(expectedDemo),
    p.windows.basename(expectedFormal),
  };
  if (children.length != names.length ||
      !names.containsAll(
        children.map((entry) => p.windows.basename(entry.path)),
      )) {
    throw StateError(
      'Refusing to remove an M6 TEMP root with unknown entries.',
    );
  }
  for (final path in [expectedDemo, expectedFormal]) {
    if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.directory ||
        !p.windows.equals(
          path,
          _normal(await Directory(path).resolveSymbolicLinks()),
        )) {
      throw StateError('An M6 database root is not a plain owned directory.');
    }
    await _assertKnownRuntimeDirectory(
      path,
      formal: p.windows.equals(path, expectedFormal),
    );
  }
  await _assertNoLinks(workspace.root, rootPath);
  await workspace.root.delete(recursive: true);
}

Future<void> _assertKnownRuntimeDirectory(
  String path, {
  required bool formal,
}) async {
  final allowedFiles = formal
      ? {'jw.sqlite', 'jw.sqlite-wal', 'jw.sqlite-shm', 'jw.sqlite-journal'}
      : {
          'm0_demo.sqlite',
          'm0_demo.sqlite-wal',
          'm0_demo.sqlite-shm',
          'm0_demo.sqlite-journal',
        };
  final allowedEmptyDirectories = formal
      ? {'jw_partitions_v1', 'young_partitions_v1'}
      : {'observation_v1', 'young_observation_v1'};
  final root = Directory(path);
  await for (final entry in root.list(followLinks: false)) {
    final name = p.windows.basename(entry.path);
    final type = await FileSystemEntity.type(entry.path, followLinks: false);
    if (allowedFiles.contains(name) && type == FileSystemEntityType.file) {
      continue;
    }
    if (formal &&
        name == 'diagnostics' &&
        type == FileSystemEntityType.directory) {
      await assertKnownFormalDiagnosticsDirectory(root);
      continue;
    }
    if (allowedEmptyDirectories.contains(name) &&
        type == FileSystemEntityType.directory) {
      final directory = Directory(entry.path);
      if (!p.windows.equals(
            _normal(entry.path),
            _normal(await directory.resolveSymbolicLinks()),
          ) ||
          (await directory.list(followLinks: false).take(1).toList())
              .isNotEmpty) {
        throw StateError(
          'Refusing to remove a populated or linked M6 subdirectory.',
        );
      }
      continue;
    }
    throw StateError('Refusing to remove an unknown M6 runtime entry.');
  }
}

Future<void> _assertNoLinks(Directory root, String rootPath) async {
  final pending = <Directory>[root];
  while (pending.isNotEmpty) {
    final current = pending.removeLast();
    await for (final entry in current.list(followLinks: false)) {
      final path = _normal(entry.path);
      if (!p.windows.isWithin(rootPath, path)) {
        throw StateError('Refusing an M6 entry outside TEMP ownership.');
      }
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.link ||
          type == FileSystemEntityType.notFound) {
        throw StateError('Refusing a linked or changing M6 TEMP entry.');
      }
      if (type == FileSystemEntityType.directory) pending.add(Directory(path));
    }
  }
}

String _normal(String path) => p.windows.normalize(p.windows.absolute(path));

String _nonce() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

final class _OwnedWorkspace {
  const _OwnedWorkspace({
    required this.root,
    required this.prefix,
    required this.nonce,
    required this.markerName,
    required this.demoPath,
    required this.formalPath,
  });

  final Directory root;
  final String prefix, nonce, markerName, demoPath, formalPath;
}

final class _FakeNotificationQueue {
  final Map<String, NotificationPending> pending = {};
}

final class _FakeNotificationPlatform implements NotificationPlatformPort {
  _FakeNotificationPlatform(this.os);

  final _FakeNotificationQueue os;
  final _activations = StreamController<NotificationActivation>.broadcast();
  final List<String> operations = [];
  final List<String> cancelledIds = [];
  final List<NotificationRequest> scheduled = [];
  int initializeCalls = 0;
  int scheduleCalls = 0;
  int clearCalls = 0;
  int closeCalls = 0;
  int clearFailuresRemaining = 0;
  bool _closed = false;

  @override
  Stream<NotificationActivation> get activations => _activations.stream;

  @override
  Future<NotificationCapability> initialize() async {
    initializeCalls++;
    operations.add('initialize');
    return const NotificationCapability(
      available: true,
      enabledBySystem: true,
      schedulesAfterExit: true,
      activationAvailable: true,
    );
  }

  @override
  Future<List<NotificationPending>> pending() async =>
      List.unmodifiable(os.pending.values);

  @override
  Future<void> schedule(NotificationRequest request) async {
    scheduleCalls++;
    operations.add('schedule:${request.id}');
    scheduled.add(request);
    os.pending[request.id] = NotificationPending(
      id: request.id,
      deliveryAtUtc: request.deliveryAtUtc,
      digest: request.digest,
      token: request.token,
      title: request.title,
      detail: request.detail,
      location: request.location,
    );
  }

  @override
  Future<void> cancel(String id) async {
    operations.add('cancel:$id');
    cancelledIds.add(id);
    os.pending.remove(id);
  }

  @override
  Future<void> clearOwn() async {
    clearCalls++;
    operations.add('clear');
    if (clearFailuresRemaining > 0) {
      clearFailuresRemaining--;
      operations.add('clear-failed');
      throw StateError('synthetic fake OS clear failure');
    }
    os.pending.clear();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    closeCalls++;
    operations.add('close');
    await _activations.close();
  }
}

final class _NoNetworkGateway implements ModelGatewayPort {
  int requestCalls = 0;

  @override
  Future<List<String>> listModels(ModelSecretLease secret) async {
    requestCalls++;
    throw StateError('No model requests are permitted in the M6 fixture.');
  }

  @override
  Stream<ModelEvent> generate(ModelRequest request, ModelSecretLease secret) {
    requestCalls++;
    return Stream<ModelEvent>.error(
      StateError('No model requests are permitted in the M6 fixture.'),
    );
  }

  @override
  Future<void> cancelAndDrain() async {}

  @override
  Future<void> close() async {}
}

final class _IdleSpeechInput implements SpeechInputPort {
  final _changes = StreamController<SpeechInputView>.broadcast();
  bool _closed = false;

  @override
  SpeechInputView get view => const SpeechInputView();

  @override
  Stream<SpeechInputView> get changes => _changes.stream;

  @override
  Future<void> start() async => throw const SpeechInputFailure(
    SpeechInputFailureCode.unsupportedPlatform,
  );

  @override
  Future<void> finish() async {}

  @override
  Future<void> cancel() async {}

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _changes.close();
  }
}
