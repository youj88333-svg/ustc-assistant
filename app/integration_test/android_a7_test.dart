// A7 / architecture07-12, quality13 V-08, workflow15. Explicitly seeds only
// the new API34 QA sandbox, so a later ordinary-main cold launch can resolve
// actual OS notification clicks against C3. No school/model/microphone IO.
import 'dart:io';

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
          // Retain A1's synthetic upgrade baseline. Refuse an unknown sandbox
          // or a repeated A7 seed instead of clearing or duplicating records.
          final existing = await calendar.query(
            CalendarQuery(
              firstDay: day.subtract(const Duration(days: 1)),
              endDayExclusive: day.add(const Duration(days: 2)),
            ),
          );
          expect(
            existing.items.every(
              (item) => item.title == 'A1 synthetic local event',
            ),
            isTrue,
          );
          final tasks = await calendar.queryTasks(const TaskQuery());
          expect(
            tasks.items.every(
              (item) => item.draft.title == 'A1 synthetic local task',
            ),
            isTrue,
          );
          final context = (await calendar.readPlanContext()).$1;
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
