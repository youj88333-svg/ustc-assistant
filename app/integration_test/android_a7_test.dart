// A7 / architecture07-12, quality13 V-08, workflow15. Explicitly seeds only
// the new API34 QA sandbox, so a later ordinary-main cold launch can resolve
// actual OS notification clicks against C3. No school/model/microphone IO.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ustc_assistant_m0/app/demo_runtime.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'prepare synthetic C3 calendar and task for ordinary cold notification routing',
    (tester) async {
      await tester.runAsync(() async {
        final previous = HttpOverrides.current;
        final network = _NoNetwork();
        HttpOverrides.global = network;
        RuntimeBootstrap? bootstrap;
        try {
          final root = await const MethodChannel(
            'ustc_assistant/platform_v1',
          ).invokeMethod<String>('privateDataRoot');
          expect(root, contains('/cn.ustcassistant.mobile.qa/no_backup/'));
          bootstrap = await RuntimeBootstrap.open();
          final runtime = bootstrap.runtime!;
          final calendar = runtime.jwStore.localCalendar;
          final now = DateTime.now().toUtc();
          final day = DateTime.utc(now.year, now.month, now.day);
          // Retain A1's upgrade baseline. A launcher can lose its stdout after
          // a successful seed; retry only our exact synthetic A7 C3 objects.
          final existing = await calendar.query(
            CalendarQuery(
              firstDay: day.subtract(const Duration(days: 1)),
              endDayExclusive: day.add(const Duration(days: 2)),
            ),
          );
          final tasks = await calendar.queryTasks(const TaskQuery());
          final oldEvents = existing.items
              .where((item) => item.title == 'A7合成日程定位')
              .toList();
          final oldTasks = tasks.items
              .where((item) => item.draft.title == 'A7合成任务定位')
              .toList();
          debugPrint(
            'a7_seed_existing {events: ${existing.items.length}, a7Events: ${oldEvents.length}, tasks: ${tasks.items.length}, a7Tasks: ${oldTasks.length}}',
          );
          expect(
            existing.items.every(
              (item) =>
                  item.title == 'A1 synthetic local event' ||
                  item.title == 'A7合成日程定位',
            ),
            isTrue,
          );
          expect(
            tasks.items.every(
              (item) =>
                  item.draft.title == 'A1 synthetic local task' ||
                  item.draft.title == 'A7合成任务定位',
            ),
            isTrue,
          );
          final context = (await calendar.readPlanContext()).$1;
          expect(oldEvents.length, lessThanOrEqualTo(1));
          expect(oldTasks.length, lessThanOrEqualTo(1));
          for (final item in oldEvents) {
            expect(item.reference.identity.kind, CalendarKind.personal);
            await calendar.commit(
              await calendar.prepare(
                context,
                DeletePersonalSeries(item.reference, confirmed: true),
              ),
            );
          }
          for (final item in oldTasks) {
            await calendar.commit(
              await calendar.prepare(
                context,
                DeleteTask(item.reference, confirmed: true),
              ),
            );
          }
          final due = now.add(const Duration(seconds: 90));
          await calendar.commit(
            await calendar.prepare(
              context,
              CreatePersonalEvent(
                PersonalEventDraft(
                  title: 'A7合成日程定位',
                  location: 'QA-ONLY',
                  start: due,
                  end: due.add(const Duration(minutes: 30)),
                ),
              ),
            ),
          );
          await calendar.commit(
            await calendar.prepare(
              context,
              CreateTask(TaskDraft(title: 'A7合成任务定位', deadlineAtUtc: due)),
            ),
          );
          final settings = await runtime.jwStore.features.inspectReminders();
          await runtime.jwStore.features.saveReminderPreferences(
            settings,
            settings.preferences.copyWith(
              enabled: true,
              timed: const ReminderPair(
                ReminderRule.before(0),
                ReminderRule.none(),
              ),
            ),
          );
          await runtime.reminders.refresh();
          for (var i = 0; i < 80; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            if (!runtime.reminders.view.busy && i > 5) break;
          }
          expect(runtime.reminders.view.failure, isNull);
          expect(runtime.reminders.view.accepted, 2);
          expect(network.attempts, 0);
          binding.reportData = {
            'kind': 'android-a7-routing-seed-v1',
            'syntheticCalendar': true,
            'syntheticTask': true,
            'nativeRegistrations': 2,
            'networkAttempts': network.attempts,
            'realDevice': false,
          };
        } finally {
          await bootstrap?.close();
          HttpOverrides.global = previous;
        }
      });
    },
    skip:
        !Platform.isAndroid ||
        !const bool.fromEnvironment('USTC_A7_SEED_OS_ROUTE'),
  );
}

final class _NoNetwork extends HttpOverrides {
  int attempts = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('A7 routing cannot access a school or model');
  }
}
